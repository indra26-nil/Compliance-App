"""Train the Tier-1 on-device transformer line classifier.

Replaces/augments the char n-gram logistic regression
(`tool/train_line_clf.py`) with a fine-tuned `prajjwal1/bert-tiny`
(L=2, H=128, ~4.4M params): real context understanding
("Rs 42" next to a garbled "MPP" label) instead of bag-of-ngrams.

Training data: `tool/prototypes.json` (same single source of truth) +
synthetic OCR garble (same noise model as `train_line_clf.py`).

Writes:
  assets/models/tiny/line_tiny_int8.onnx -- int8-quantized classifier (~5MB)
  assets/models/tiny/vocab.txt            -- WordPiece vocab (Dart tokenizer)
  assets/models/tiny/meta.json            -- classes + max_len + report
  tool/tiny_clf_parity.json               -- predictions for the Dart parity test

The Dart side (`lib/services/tiny_classifier.dart` + `wordpiece.dart`)
replicates the HF BertTokenizer + softmax exactly; this script's parity
set validates field-exact + probability match.

Usage: /tmp/tier1/bin/python tool/train_tiny_clf.py  (from App/complience_app/)
Requires: torch (cpu), transformers, onnx, onnxruntime, scikit-learn, numpy
"""

import json
import os
import random
from datetime import datetime, timezone

import numpy as np

BANK_JSON = "tool/prototypes.json"
OUT_DIR = "assets/models/tiny"
OUT_ONNX_FP32 = os.path.join(OUT_DIR, "line_tiny.onnx")
OUT_ONNX_INT8 = os.path.join(OUT_DIR, "line_tiny_int8.onnx")
OUT_VOCAB = os.path.join(OUT_DIR, "vocab.txt")
OUT_META = os.path.join(OUT_DIR, "meta.json")
PARITY_JSON = "tool/tiny_clf_parity.json"

BASE_MODEL = "prajjwal1/bert-tiny"
MAX_LEN = 48
AUG_PER_PROTO = 40
EPOCHS = 15
BATCH = 32
LR = 5e-5
TRAIN_SEED = 123

# ---------------------------------------------------------------- bank ---
PROTOS = json.load(open(BANK_JSON))
CLASSES = sorted(PROTOS)
NCLASS = len(CLASSES)
CLS_TO_ID = {c: i for i, c in enumerate(CLASSES)}
X_bank = [l for c in CLASSES for l in PROTOS[c]]
y_bank = [CLS_TO_ID[c] for c in CLASSES for l in PROTOS[c]]
print(f"bank: {NCLASS} classes, {len(X_bank)} prototypes")

# --------------------------------------------------------------- noise ---
# Same OCR-noise model as train_line_clf.py so both models see the same world.
CONF = {
    "O": "0", "o": "0", "0": "O", "l": "1", "I": "1", "1": "l",
    "S": "5", "s": "5", "5": "S", "B": "8", "8": "B", "G": "6", "6": "G",
    "Z": "2", "2": "Z", "A": "4", "4": "A", "E": "3", "3": "E",
    "a": "@", "e": "c", "c": "e", "m": "rn", "rn": "m", "w": "vv",
    "vv": "w", "d": "cl", "U": "0", "T": "7",
    ".": "", ",": "", ":": "", "-": "", " ": "",
}


def garble(text, rng, level=1.0):
    t = text
    n_ops = max(1, min(4, int(len(t) / 12 * level) + 1))
    for _ in range(n_ops):
        if not t:
            break
        op = rng.random()
        i = rng.integers(0, len(t))
        ch = t[i]
        if op < 0.55:
            two = t[i : i + 2]
            if two in CONF and len(two) == 2 and rng.random() < 0.5:
                t = t[:i] + CONF[two] + t[i + 2 :]
                continue
            rep = CONF.get(ch, CONF.get(ch.lower(), None))
            if rep is not None and rng.random() < 0.8:
                t = t[:i] + rep + t[i + 1 :]
            elif ch.isalpha():
                t = t[:i] + chr(ord("a") + rng.integers(0, 26)) + t[i + 1 :]
        elif op < 0.70:
            t = t[:i] + t[i + 1 :]
        elif op < 0.80:
            t = t.replace(" ", "", 1) if " " in t else t[:i] + t[i + 1 :]
        elif op < 0.90:
            t = t[:i] + (ch.upper() if ch.islower() else ch.lower()) + t[i + 1 :]
        else:
            t = t[:i] + rng.choice(list(".,:;|!1il ")) + t[i:]
    return t


import torch
from torch.utils.data import DataLoader, Dataset
from huggingface_hub import snapshot_download
from tokenizers import Tokenizer as RustTokenizer, decoders, models, \
    normalizers, pre_tokenizers, processors
from transformers import BertConfig, BertForSequenceClassification, \
    PreTrainedTokenizerFast

torch.manual_seed(TRAIN_SEED)
np.random.seed(TRAIN_SEED)
random.seed(TRAIN_SEED)
torch.set_num_threads(max(1, os.cpu_count() or 4))

print(f"loading base {BASE_MODEL} ...")
snap = snapshot_download(BASE_MODEL)


def build_tokenizer(vocab_file):
    # Fast WordPiece built straight from vocab.txt (transformers 5.x only
    # ships fast tokenizers and this vintage repo has no tokenizer.json).
    # Rules == classic BertTokenizer uncased, which wordpiece.dart mirrors.
    with open(vocab_file, encoding="utf-8") as f:
        vocab = {line.rstrip("\n"): i for i, line in enumerate(f)}
    rt = RustTokenizer(models.WordPiece(vocab=vocab, unk_token="[UNK]"))
    rt.normalizer = normalizers.BertNormalizer(
        clean_text=True, handle_chinese_chars=True,
        strip_accents=True, lowercase=True)
    rt.pre_tokenizer = pre_tokenizers.BertPreTokenizer()
    rt.post_processor = processors.TemplateProcessing(
        single="[CLS] $A [SEP]",
        pair="[CLS] $A [SEP] $B:1 [SEP]:1",
        special_tokens=[("[CLS]", vocab["[CLS]"]), ("[SEP]", vocab["[SEP]"])],
    )
    rt.decoder = decoders.WordPiece(prefix="##", cleanup=True)
    return PreTrainedTokenizerFast(
        tokenizer_object=rt, unk_token="[UNK]", sep_token="[SEP]",
        pad_token="[PAD]", cls_token="[CLS]", mask_token="[MASK]")


tok = build_tokenizer(os.path.join(snap, "vocab.txt"))

rng_train = np.random.default_rng(TRAIN_SEED)
X_aug, y_aug = list(X_bank), list(y_bank)
for c in CLASSES:
    for line in PROTOS[c]:
        for _ in range(AUG_PER_PROTO):
            X_aug.append(garble(line, rng_train, level=1.2))
            y_aug.append(CLS_TO_ID[c])
print(f"train docs: {len(X_aug)} (clean {len(X_bank)} + garble)")


class LineDS(Dataset):
    def __init__(self, texts, labels):
        self.enc = tok(
            texts, truncation=True, padding="max_length", max_length=MAX_LEN
        )
        self.labels = labels

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, i):
        return {
            "input_ids": torch.tensor(self.enc["input_ids"][i]),
            "attention_mask": torch.tensor(self.enc["attention_mask"][i]),
            "labels": torch.tensor(self.labels[i]),
        }


# Stratified 90/10 split for early-stopping selection.
from collections import defaultdict

by_cls = defaultdict(list)
for i, y in enumerate(y_aug):
    by_cls[y].append(i)
tr_idx, va_idx = [], []
rs = random.Random(TRAIN_SEED)
for y, idxs in by_cls.items():
    rs.shuffle(idxs)
    n_va = max(1, int(len(idxs) * 0.10))
    va_idx += idxs[:n_va]
    tr_idx += idxs[n_va:]

cfg = BertConfig.from_pretrained(snap, num_labels=NCLASS)
model = BertForSequenceClassification.from_pretrained(snap, config=cfg)
model.config.label2id = CLS_TO_ID
model.config.id2label = {i: c for c, i in CLS_TO_ID.items()}
model.train()

opt = torch.optim.AdamW(model.parameters(), lr=LR)
train_dl = DataLoader(
    LineDS([X_aug[i] for i in tr_idx], [y_aug[i] for i in tr_idx]),
    batch_size=BATCH,
    shuffle=True,
)
val_dl = DataLoader(
    LineDS([X_aug[i] for i in va_idx], [y_aug[i] for i in va_idx]),
    batch_size=128,
)


def evaluate(m):
    m.eval()
    correct, total, loss_sum = 0, 0, 0.0
    with torch.no_grad():
        for b in val_dl:
            out = m(
                input_ids=b["input_ids"], attention_mask=b["attention_mask"],
                labels=b["labels"],
            )
            loss_sum += out.loss.item() * len(b["labels"])
            correct += (out.logits.argmax(-1) == b["labels"]).sum().item()
            total += len(b["labels"])
    m.train()
    return loss_sum / total, correct / total


best_va, best_state, patience, wait = 0.0, None, 4, 0
for ep in range(EPOCHS):
    tot = 0.0
    for b in train_dl:
        opt.zero_grad()
        out = model(
            input_ids=b["input_ids"], attention_mask=b["attention_mask"],
            labels=b["labels"],
        )
        out.loss.backward()
        opt.step()
        tot += out.loss.item()
    va_loss, va_acc = evaluate(model)
    print(f"ep {ep + 1:>2}/{EPOCHS} loss {tot / len(train_dl):.4f} "
          f"val_loss {va_loss:.4f} val_acc {va_acc:.4f}", flush=True)
    if va_acc > best_va + 1e-4:
        best_va = va_acc
        best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        wait = 0
    else:
        wait += 1
        if wait >= patience:
            print("early stop")
            break
model.load_state_dict(best_state)
model.eval()
print(f"best val_acc {best_va:.4f}")

# ---------------------------------------------------------------- eval ---
REAL = [
    ("Lay's", "brand"), ("Potato Chips", "product_name"),
    ("NETUT 80g", "net_qty"), ("MPP Rs 42.00", "mrp"),
    ("(inclusive of all taxes)", "mrp"),
    ("Mfd. by PepsiCo India Holdings Pvt. Ltd.,", "manufacturer"),
    ("SCO 29-30, Sector 17, Chandigarh 160017", "manufacturer"),
    ("C022- 67740100 AND", "care"),
    ("CONSUMER.FEEDBACK@PEPSICO.COM", "care"),
    ("FSSL No. 10012083000110", "fssai"),
    ("8 901234 567890", "barcode"),
    ("Lay's is a Trade Mark of PepsiCo, Inc.", "other"),
]
PARA = [
    ("Coca-Cola", "brand"), ("Mango Pickle", "product_name"),
    ("Tastes great every day!", "slogan_other"),
    ("INGREDIENTS: Rice Flour, Salt, Palm Oil", "ingredients"),
    ("Contains Peanuts", "allergen"),
    ("Protein 5g per 100g serving", "nutrition"),
    ("Net Quantity 250 g", "net_qty"), ("Price Rs 75 only", "mrp"),
    ("Lot Number B2210", "batch"), ("Packed in June 2025", "mfg_date"),
    ("Expires December 2026", "exp_date"),
    ("Made by ITC Limited, Kolkata", "manufacturer"),
    ("Helpline 1800 3000 1234", "care"),
    ("FSSAI 10019099001122", "fssai"),
    ("Manufactured in Sri Lanka", "origin"),
    ("6 789012 345678", "barcode"),
    ("Best stored away from sunlight", "other"),
]


@torch.no_grad()
def predict(texts):
    enc = tok(texts, truncation=True, padding=True,
              max_length=MAX_LEN, return_tensors="pt")
    logits = model(**enc).logits
    probs = torch.softmax(logits, -1)
    conf, pred = probs.max(-1)
    return [CLASSES[i] for i in pred.tolist()], conf.tolist()


def acc(pairs):
    pred, _ = predict([t for t, _ in pairs])
    return sum(p == g for p, (_, g) in zip(pred, pairs)) / len(pairs)


rng_test = np.random.default_rng(999)
synth = [(garble(l, rng_test, 1.0), c) for c in CLASSES
         for l in PROTOS[c] for _ in range(3)]
heavy = [(garble(l, np.random.default_rng(555), 1.6), c) for c in CLASSES
         for l in PROTOS[c] for _ in range(2)]
print("acc real %.4f para %.4f synth %.4f heavy %.4f" % (
    acc(REAL), acc(PARA), acc(synth), acc(heavy)))

# --------------------------------------------------------------- export ---
os.makedirs(OUT_DIR, exist_ok=True)


class Wrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        return self.m(input_ids=input_ids,
                      attention_mask=attention_mask).logits


wrapped = Wrap(model).eval()
dummy_ids = torch.ones(1, MAX_LEN, dtype=torch.long)
dummy_mask = torch.ones(1, MAX_LEN, dtype=torch.long)
torch.onnx.export(
    wrapped, (dummy_ids, dummy_mask), OUT_ONNX_FP32,
    input_names=["input_ids", "attention_mask"], output_names=["logits"],
    dynamic_axes={"input_ids": {0: "batch", 1: "seq"},
                  "attention_mask": {0: "batch", 1: "seq"},
                  "logits": {0: "batch"}},
    opset_version=14, do_constant_folding=True,
    # Classic exporter: single self-contained file + clean shapes (the
    # dynamo path splits weights into .data and breaks ORT shape-infer).
    dynamo=False,
)
print(f"wrote {OUT_ONNX_FP32} "
      f"({os.path.getsize(OUT_ONNX_FP32) / 1024:.0f} KB)")

import onnxruntime as ort

sess = ort.InferenceSession(OUT_ONNX_FP32,
                            providers=["CPUExecutionProvider"])
enc = tok(["MRP Rs. 42.00", "NETUT 80g"], padding="max_length",
          max_length=MAX_LEN, return_tensors="np")
ref = model(torch.tensor(enc["input_ids"]),
            torch.tensor(enc["attention_mask"])).logits.detach().numpy()
got = sess.run(["logits"], {"input_ids": enc["input_ids"].astype(np.int64),
                            "attention_mask": enc["attention_mask"].astype(np.int64)})[0]
print(f"torch-vs-ort max diff: {np.abs(ref - got).max():.2e}")

from onnxruntime.quantization import QuantType, quantize_dynamic

quantize_dynamic(OUT_ONNX_FP32, OUT_ONNX_INT8,
                 weight_type=QuantType.QInt8)
print(f"wrote {OUT_ONNX_INT8} "
      f"({os.path.getsize(OUT_ONNX_INT8) / 1024:.0f} KB)")

# int8 must agree with fp32 argmax on probes + samples.
sess8 = ort.InferenceSession(OUT_ONNX_INT8,
                             providers=["CPUExecutionProvider"])
probe_texts = [t for t, _ in REAL] + [
    "", "   ", "!!!", "MRP", "Rs. 1,299",
    "MRP ₹ 99 (inclusive of all taxes)",
    "NET QTY: 80g " * 20,
    "mfd by pepsico india",
] + [t for t, _ in PARA]
enc8 = tok(probe_texts, truncation=True, padding=True,
           max_length=MAX_LEN, return_tensors="np")
feed = {"input_ids": enc8["input_ids"].astype(np.int64),
        "attention_mask": enc8["attention_mask"].astype(np.int64)}
p8 = sess8.run(["logits"], feed)[0]
p32 = sess.run(["logits"], feed)[0]
agree = (p8.argmax(-1) == p32.argmax(-1)).mean()
print(f"int8-vs-fp32 argmax agreement: {agree:.4f}")
assert agree >= 0.95, "quantization degraded too much"

probs8 = torch.softmax(torch.tensor(p8), -1).numpy()
cases = [{"text": t, "field": CLASSES[int(i)], "prob": round(float(p), 6)}
         for t, i, p in zip(probe_texts, p8.argmax(-1), probs8.max(-1))]
json.dump(cases, open(PARITY_JSON, "w"), indent=1, ensure_ascii=False)
print(f"wrote {PARITY_JSON} ({len(cases)} cases)")

# Vocab for the Dart WordPiece tokenizer (same file HF uses).
import shutil

shutil.copy(os.path.join(snap, "vocab.txt"), OUT_VOCAB)
with open(OUT_VOCAB, encoding="utf-8") as f:
    vocab_lines = f.read().splitlines()
print(f"wrote {OUT_VOCAB} ({len(vocab_lines)} pieces)")

meta = {
    "format": 1,
    "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "base": BASE_MODEL,
    "classes": CLASSES,
    "max_len": MAX_LEN,
    "quant": "int8-dynamic",
    "report": {
        "real": round(acc(REAL), 4),
        "para": round(acc(PARA), 4),
        "synth": round(sum(p == g for p, (_, g) in
                           zip(predict([t for t, _ in synth])[0], synth))
                       / len(synth), 4),
        "val_acc": round(best_va, 4),
        "int8_agreement": round(float(agree), 4),
    },
}
json.dump(meta, open(OUT_META, "w"), indent=1)
print(f"wrote {OUT_META}")
for c in cases[:12]:
    print(f"  {c['text'][:44]!r:48} -> {c['field']:13} {c['prob']:.4f}")
