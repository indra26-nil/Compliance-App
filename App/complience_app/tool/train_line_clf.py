"""Train the on-device line classifier (candidate D from eval_accuracy.py).

Reads the prototype bank from tool/prototypes.json (single source of
truth — the officer-observed label lines + garble variants), trains a
char n-gram TF-IDF + logistic regression on clean prototypes + synthetic
OCR garble, and writes:

  assets/models/ngram/line_clf.json  -- weights + vectorizer (app asset)
  tool/line_clf_parity.json          -- predictions for the Dart parity test

Reproducible: fixed seeds. Re-run after editing tool/prototypes.json,
then run `flutter test test/ngram_classifier_test.dart` to verify the
pure-Dart inference in lib/services/ngram_classifier.dart still matches
sklearn (field + probability per probe line).

Usage: python3 tool/train_line_clf.py   (run from App/complience_app/)
Requires: scikit-learn, numpy
"""
import json
import os
from datetime import datetime, timezone

import numpy as np

BANK_JSON = 'tool/prototypes.json'
OUT_JSON = 'assets/models/ngram/line_clf.json'
PARITY_JSON = 'tool/line_clf_parity.json'

C = 4.0
NGRAM_MIN, NGRAM_MAX = 3, 5
AUG_PER_PROTO = 15
TRAIN_SEED = 123
TEST_SEED = 999

# ---------------------------------------------------------------- bank ---
PROTOS = json.load(open(BANK_JSON))
CLASSES = sorted(PROTOS)
X_bank = [l for c in CLASSES for l in PROTOS[c]]
y_bank = [c for c in CLASSES for l in PROTOS[c]]
print(f'bank: {len(CLASSES)} classes, {len(X_bank)} prototypes')

# --------------------------------------------------------------- noise ---
CONF = {
    'O': '0', 'o': '0', '0': 'O', 'l': '1', 'I': '1', '1': 'l',
    'S': '5', 's': '5', '5': 'S', 'B': '8', '8': 'B', 'G': '6', '6': 'G',
    'Z': '2', '2': 'Z', 'A': '4', '4': 'A', 'E': '3', '3': 'E',
    'a': '@', 'e': 'c', 'c': 'e', 'm': 'rn', 'rn': 'm', 'w': 'vv',
    'vv': 'w', 'd': 'cl', 'U': '0', 'T': '7',
    '.': '', ',': '', ':': '', '-': '', ' ': '',
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
            two = t[i:i + 2]
            if two in CONF and len(two) == 2 and rng.random() < 0.5:
                t = t[:i] + CONF[two] + t[i + 2:]
                continue
            rep = CONF.get(ch, CONF.get(ch.lower(), None))
            if rep is not None and rng.random() < 0.8:
                t = t[:i] + rep + t[i + 1:]
            elif ch.isalpha():
                t = t[:i] + chr(ord('a') + rng.integers(0, 26)) + t[i + 1:]
        elif op < 0.70:
            t = t[:i] + t[i + 1:]
        elif op < 0.80:
            t = t.replace(' ', '', 1) if ' ' in t else t[:i] + t[i + 1:]
        elif op < 0.90:
            t = t[:i] + (ch.upper() if ch.islower() else ch.lower()) + t[i + 1:]
        else:
            t = t[:i] + rng.choice(list('.,:;|!1il ')) + t[i:]
    return t


# --------------------------------------------------------------- train ---
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression

vec = TfidfVectorizer(analyzer='char_wb', ngram_range=(NGRAM_MIN, NGRAM_MAX),
                      lowercase=True, min_df=1)
vec.fit(X_bank)
vocab = vec.vocabulary_  # ngram -> index
idf = vec.idf_
print(f'features: {len(vocab)}')

rng_train = np.random.default_rng(TRAIN_SEED)
X_aug, y_aug = list(X_bank), list(y_bank)
for c in CLASSES:
    for l in PROTOS[c]:
        for _ in range(AUG_PER_PROTO):
            X_aug.append(garble(l, rng_train, level=1.2))
            y_aug.append(c)
Xtr = vec.transform(X_aug)
clf = LogisticRegression(max_iter=2000, C=C).fit(Xtr, y_aug)
assert list(clf.classes_) == CLASSES
print(f'train docs: {len(X_aug)}')

# ---------------------------------------------------------------- eval ---
REAL = [
    ("Lay's", 'brand'), ('Potato Chips', 'product_name'),
    ('NETUT 80g', 'net_qty'), ('MPP Rs 42.00', 'mrp'),
    ('(inclusive of all taxes)', 'mrp'),
    ('Mfd. by PepsiCo India Holdings Pvt. Ltd.,', 'manufacturer'),
    ('SCO 29-30, Sector 17, Chandigarh 160017', 'manufacturer'),
    ('C022- 67740100 AND', 'care'),
    ('CONSUMER.FEEDBACK@PEPSICO.COM', 'care'),
    ('FSSL No. 10012083000110', 'fssai'),
    ('8 901234 567890', 'barcode'),
    ("Lay's is a Trade Mark of PepsiCo, Inc.", 'other'),
]
PARA = [
    ('Coca-Cola', 'brand'), ('Mango Pickle', 'product_name'),
    ('Tastes great every day!', 'slogan_other'),
    ('INGREDIENTS: Rice Flour, Salt, Palm Oil', 'ingredients'),
    ('Contains Peanuts', 'allergen'),
    ('Protein 5g per 100g serving', 'nutrition'),
    ('Net Quantity 250 g', 'net_qty'), ('Price Rs 75 only', 'mrp'),
    ('Lot Number B2210', 'batch'), ('Packed in June 2025', 'mfg_date'),
    ('Expires December 2026', 'exp_date'),
    ('Made by ITC Limited, Kolkata', 'manufacturer'),
    ('Helpline 1800 3000 1234', 'care'),
    ('FSSAI 10019099001122', 'fssai'),
    ('Manufactured in Sri Lanka', 'origin'),
    ('6 789012 345678', 'barcode'),
    ('Best stored away from sunlight', 'other'),
]


def synth(rng, per_proto=3, level=1.0):
    X, y = [], []
    for c in CLASSES:
        for l in PROTOS[c]:
            for _ in range(per_proto):
                X.append(garble(l, rng, level))
                y.append(c)
    return X, y


rng_test = np.random.default_rng(TEST_SEED)
SETS = {
    'real': ([t for t, _ in REAL], [y for _, y in REAL]),
    'para': ([t for t, _ in PARA], [y for _, y in PARA]),
}
Xs, ys = synth(rng_test, 3, 1.0)
SETS['synth'] = (Xs, ys)
Xh, yh = synth(np.random.default_rng(555), 2, 1.6)
SETS['synth_heavy'] = (Xh, yh)


def acc_of(predict, sets=SETS):
    return {k: sum(p == g for p, g in zip(predict(T), G)) / len(G)
            for k, (T, G) in sets.items()}


base = acc_of(lambda T: clf.predict(vec.transform(T)))
print('unpruned:', {k: round(v, 4) for k, v in base.items()})

# -------------------------------------------------------------- prune ---
coef = clf.coef_.copy()
best_thr, best_nonzero = 0.0, coef.size
for thr in (0.10, 0.05, 0.03, 0.02, 0.01, 0.005, 0.0):
    pruned = np.where(np.abs(coef) < thr, 0.0, coef)
    keep = int((pruned != 0).sum())

    # manual argmax (predict uses softmax argmax == logit argmax)
    def predict_logits(T):
        S = vec.transform(T) @ pruned.T + clf.intercept_
        return [CLASSES[i] for i in np.asarray(S).argmax(1)]

    a = acc_of(predict_logits,
               {k: v for k, v in SETS.items() if k != 'synth_heavy'})
    same = all(abs(a[k] - base[k]) < 1e-12 for k in a)
    print(f'thr={thr:<6} nonzero={keep:>6} '
          f'acc={[round(a[k], 4) for k in ("real", "para", "synth")]} '
          f'{"KEEP" if same else "drop"}')
    if same:
        best_thr, best_nonzero = thr, keep
        coef = pruned

ah = acc_of(lambda T: clf.predict(vec.transform(T)),
            {'synth_heavy': SETS['synth_heavy']})
print(f'synth_heavy pruned: {ah["synth_heavy"]:.4f} '
      f'(unpruned {base["synth_heavy"]:.4f})')

# -------------------------------------------------------------- write ---
os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
V = len(vocab)
inv = [None] * V
for w, j in vocab.items():
    inv[j] = w
payload = {
    'format': 1,
    'generated': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    'classes': CLASSES,
    'lowercase': True,
    'analyzer': 'char_wb',
    'ngram_min': NGRAM_MIN,
    'ngram_max': NGRAM_MAX,
    'vocab': inv,
    'idf': [round(float(x), 5) for x in idf],
    # Sparse per-class weights: [[featureIdx, weight], ...]. Zeros omitted.
    'coef': [[[j, round(float(w), 4)] for j, w in enumerate(row) if w != 0]
             for row in coef],
    'intercept': [round(float(x), 5) for x in clf.intercept_],
    'train': {'docs': len(X_aug), 'clean': len(X_bank),
              'aug_per_proto': AUG_PER_PROTO, 'noise_level': 1.2,
              'seed': TRAIN_SEED, 'C': C},
    'report': {k: round(v, 4) for k, v in base.items()} | {
        'synth_heavy': round(ah['synth_heavy'], 4),
        'prune_threshold': best_thr, 'nonzero_weights': best_nonzero},
}
json.dump(payload, open(OUT_JSON, 'w'))
print(f'wrote {OUT_JSON} '
      f'({os.path.getsize(OUT_JSON) / 1024:.0f} KB, '
      f'{best_nonzero}/{coef.size} weights)')

# ------------------------------------------------------------- parity ---
# NOTE: recomputed from the reloaded JSON (rounded weights/idf) so the
# Dart test validates exactly what ships, not full-precision values.
ship = json.load(open(OUT_JSON))
s_vocab = {w: j for j, w in enumerate(ship['vocab'])}
s_idf = np.array(ship['idf'])
s_n = len(s_vocab)
s_coef = np.zeros((len(CLASSES), s_n))
for i, row in enumerate(ship['coef']):
    for j, w in row:
        s_coef[i, j] = w
s_inter = np.array(ship['intercept'])
s_vec = TfidfVectorizer(analyzer='char_wb', ngram_range=(NGRAM_MIN, NGRAM_MAX),
                        lowercase=True, min_df=1)
s_vec.fit(X_bank)
assert s_vec.vocabulary_ == s_vocab, 'vocab mismatch after reload'

Idx = {w: j for j, w in enumerate(ship['vocab'])}
probes = ([t for t, _ in REAL] + [
    '', '   ', '!!!', 'MRP', 'Rs. 1,299',
    'MRP ₹ 99 (inclusive of all taxes)',
    'NET QTY: 80g ' * 20,  # long line (truncation-free by design)
    'mfd by pepsico india',  # lowercase variant
])
import math

S = s_vec.transform(probes) @ s_coef.T + s_inter
S = np.asarray(S)
P = np.exp(S - S.max(1, keepdims=True))
P /= P.sum(1, keepdims=True)
cases = [{'text': t, 'field': CLASSES[int(i)], 'prob': round(float(p), 6)}
         for t, i, p in zip(probes, S.argmax(1), P.max(1))]
json.dump(cases, open(PARITY_JSON, 'w'), indent=1, ensure_ascii=False)
print(f'wrote {PARITY_JSON} ({len(cases)} cases)')
for c in cases:
    print(f"  {c['text'][:44]!r:48} -> {c['field']:13} {c['prob']:.4f}")
