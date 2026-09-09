/// BERT WordPiece tokenizer from a HuggingFace `tokenizer.json` (pure Dart).
///
/// Implements exactly what `all-MiniLM-L6-v2` needs: BertNormalizer
/// (clean_text + lowercase), BertPreTokenizer (whitespace + punctuation
/// split), WordPiece greedy longest-match, `[CLS] … [SEP]` template,
/// truncation + pad-to-[maxLen].
///
/// Pure Dart + testable: feed it the vocab map directly. The production
/// path loads `assets/models/embeddings/tokenizer.json` once (see
/// `MiniLMEmbedder`) and caches the instance.
library;

class WordPieceTokenizer {
  WordPieceTokenizer({
    required Map<String, int> vocab,
    this.unkId = 100,
    this.clsId = 101,
    this.sepId = 102,
    this.padId = 0,
    this.maxLen = 32,
    this.lowercase = true,
  }) : _vocab = vocab;

  /// Builds from a HuggingFace tokenizers JSON map (the `model.vocab`
  /// section plus special-token ids).
  factory WordPieceTokenizer.fromTokenizerJson(
    Map<String, Object?> json, {
    int maxLen = 32,
  }) {
    final model = (json['model'] as Map?) ?? {};
    final vocabRaw = (model['vocab'] as Map?) ?? {};
    final vocab = <String, int>{};
    vocabRaw.forEach((k, v) {
      vocab[k.toString()] = (v as num).toInt();
    });
    int idOf(String token, int fallback) =>
        vocab[token] ?? fallback;
    final normalizer = (json['normalizer'] as Map?) ?? {};
    return WordPieceTokenizer(
      vocab: vocab,
      unkId: idOf('[UNK]', 100),
      clsId: idOf('[CLS]', 101),
      sepId: idOf('[SEP]', 102),
      padId: idOf('[PAD]', 0),
      maxLen: maxLen,
      lowercase: (normalizer['lowercase'] as bool?) ?? true,
    );
  }

  final Map<String, int> _vocab;
  final int unkId;
  final int clsId;
  final int sepId;
  final int padId;
  final int maxLen;
  final bool lowercase;

  int get vocabSize => _vocab.length;

  /// Encodes one line → fixed-length ids + attention mask.
  ({List<int> ids, List<int> mask}) encode(String text) {
    final pieces = <String>[];
    for (final word in _basicTokenize(text)) {
      pieces.addAll(_wordpiece(word));
      if (pieces.length >= maxLen - 2) break;
    }
    final ids = <int>[clsId];
    for (final p in pieces) {
      if (ids.length >= maxLen - 1) break;
      ids.add(_vocab[p] ?? unkId);
    }
    ids.add(sepId);
    final mask = List<int>.filled(ids.length, 1, growable: true);
    while (ids.length < maxLen) {
      ids.add(padId);
      mask.add(0);
    }
    return (ids: ids, mask: mask);
  }

  /// BERT basic tokenization: clean + lowercase + split whitespace, then
  /// split punctuation into separate tokens ("90g" stays one word;
  /// "MRP Rs:" → ["mrp", "rs", ":"] after lowercasing).
  List<String> _basicTokenize(String text) {
    var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (lowercase) t = t.toLowerCase();
    // Strip controls (clean_text), keep it cheap.
    t = t.replaceAll(RegExp(r'[\u0000-\u0008\u000e-\u001f\u007f]'), '');
    final out = <String>[];
    for (final chunk in t.split(' ')) {
      if (chunk.isEmpty) continue;
      final buf = StringBuffer();
      void flush() {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      }

      for (var i = 0; i < chunk.length; i++) {
        final c = chunk[i];
        if (_isPunct(c)) {
          flush();
          out.add(c);
        } else {
          buf.write(c);
        }
      }
      flush();
    }
    return out;
  }

  static bool _isPunct(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 33 && u <= 47) ||
        (u >= 58 && u <= 64) ||
        (u >= 91 && u <= 96) ||
        (u >= 123 && u <= 126);
  }

  /// Greedy longest-match WordPiece. Words > 100 chars → [UNK] (BERT rule).
  List<String> _wordpiece(String word) {
    if (word.length > 100) return ['[UNK]'];
    if (_vocab.containsKey(word)) return [word];
    final out = <String>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      String? cur;
      while (start < end) {
        var sub = word.substring(start, end);
        if (start > 0) sub = '##$sub';
        if (_vocab.containsKey(sub)) {
          cur = sub;
          break;
        }
        end--;
      }
      if (cur == null) return ['[UNK]'];
      out.add(cur);
      start = end;
    }
    return out;
  }
}
