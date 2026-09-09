/// Pure-Dart WordPiece tokenizer matching HuggingFace `BertTokenizer`
/// (uncased) exactly on label-like text.
///
/// Used by [TinyClassifier] to feed the Tier-1 transformer. Steps mirror
/// the Python side: clean -> lowercase -> strip accents -> split whitespace
/// -> split ASCII punctuation -> greedy longest-match WordPiece.
///
/// Unknown words / chars fall back to `[UNK]`, so garbled OCR never throws.
library;

import 'package:flutter/services.dart';

class WordPieceTokenizer {
  WordPieceTokenizer(this._vocab);

  /// Loads `vocab.txt` (one piece per line) into token -> id.
  static Future<WordPieceTokenizer> load(String asset) async {
    final raw = await rootBundle.loadString(asset);
    final vocab = <String, int>{};
    var i = 0;
    for (final line in raw.split('\n')) {
      final piece = line.endsWith('\r')
          ? line.substring(0, line.length - 1)
          : line;
      if (piece.isEmpty) continue;
      vocab.putIfAbsent(piece, () => i);
      i++;
    }
    if (vocab.isEmpty) throw const FormatException('empty WordPiece vocab');
    return WordPieceTokenizer(vocab);
  }

  final Map<String, int> _vocab;

  int idOf(String piece, [int fallback = 100]) =>
      _vocab[piece] ?? fallback;

  int get unkId => idOf('[UNK]');
  int get clsId => idOf('[CLS]', 101);
  int get sepId => idOf('[SEP]', 102);
  int get padId => idOf('[PAD]', 0);

  /// Basic tokens: cleaned, lowercased, punctuation-split words.
  List<String> basicTokenize(String text) {
    final cleaned = _clean(text.toLowerCase());
    final stripped = _stripAccents(cleaned);
    final out = <String>[];
    for (final word in stripped.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      out.addAll(_splitPunct(word));
    }
    return out;
  }

  /// Full WordPiece tokenization of one line (no special tokens added).
  List<String> tokenize(String text) {
    final out = <String>[];
    for (final word in basicTokenize(text)) {
      out.addAll(_wordPiece(word));
    }
    return out;
  }

  /// Token ids for one line, with `[CLS]`/`[SEP]`, truncated to [maxLen].
  List<int> encode(String text, {required int maxLen}) {
    final pieces = tokenize(text);
    final budget = maxLen - 2; // room for CLS + SEP
    final kept =
        pieces.length > budget ? pieces.sublist(0, budget) : pieces;
    return [
      clsId,
      for (final p in kept) idOf(p, unkId),
      sepId,
    ];
  }

  /// Batched encode with padding. Returns (ids, mask) row-major.
  ({List<int> ids, List<int> mask}) encodeBatch(
    List<String> texts, {
    required int maxLen,
  }) {
    final rows = [for (final t in texts) encode(t, maxLen: maxLen)];
    var width = 2;
    for (final r in rows) {
      if (r.length > width) width = r.length;
    }
    final ids = <int>[];
    final mask = <int>[];
    for (final r in rows) {
      ids.addAll(r);
      mask.addAll(List.filled(r.length, 1));
      final pad = width - r.length;
      for (var k = 0; k < pad; k++) {
        ids.add(padId);
        mask.add(0);
      }
    }
    return (ids: ids, mask: mask);
  }

  // -- internals ---------------------------------------------------------

  static String _clean(String text) {
    final buf = StringBuffer();
    for (final cp in text.runes) {
      if (cp == 0 || cp == 0xfffd) continue;
      if (cp == 0x09 || cp == 0x0a || cp == 0x0d || cp == 0x20) {
        buf.write(' ');
      } else if (cp < 0x20) {
        continue; // other control chars are dropped (HF behavior)
      } else {
        buf.writeCharCode(cp);
      }
    }
    return buf.toString();
  }

  /// ASCII punctuation split (matches HF on realistic input: currency
  /// signs like ₹ are Sc, not P, so they stay attached on both sides).
  static List<String> _splitPunct(String word) {
    final out = <String>[];
    final cur = StringBuffer();
    void flush() {
      if (cur.isNotEmpty) {
        out.add(cur.toString());
        cur.clear();
      }
    }

    for (final cp in word.runes) {
      final isPunct = (cp >= 33 && cp <= 47) ||
          (cp >= 58 && cp <= 64) ||
          (cp >= 91 && cp <= 96) ||
          (cp >= 123 && cp <= 126);
      if (isPunct) {
        flush();
        out.add(String.fromCharCode(cp));
      } else {
        cur.writeCharCode(cp);
      }
    }
    flush();
    return out;
  }

  List<String> _wordPiece(String word) {
    final chars = word.runes.toList();
    if (chars.length > 100) return const ['[UNK]'];
    final out = <String>[];
    var start = 0;
    while (start < chars.length) {
      var end = chars.length;
      String? cur;
      while (start < end) {
        var sub = String.fromCharCodes(chars.sublist(start, end));
        if (start > 0) sub = '##$sub';
        if (_vocab.containsKey(sub)) {
          cur = sub;
          break;
        }
        end--;
      }
      if (cur == null) return const ['[UNK]'];
      out.add(cur);
      start = end;
    }
    return out;
  }

  /// NFD-free accent strip for the Latin-1/Extended-A range (covers
  /// officer-typed labels; CJK/pictographs pass through to [UNK]).
  static String _stripAccents(String text) {
    const map = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
      'ā': 'a', 'ă': 'a', 'ą': 'a', 'è': 'e', 'é': 'e', 'ê': 'e',
      'ë': 'e', 'ē': 'e', 'ę': 'e', 'ě': 'e', 'ì': 'i', 'í': 'i',
      'î': 'i', 'ï': 'i', 'ī': 'i', 'ò': 'o', 'ó': 'o', 'ô': 'o',
      'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ù': 'u', 'ú': 'u',
      'û': 'u', 'ü': 'u', 'ū': 'u', 'ý': 'y', 'ÿ': 'y', 'ç': 'c',
      'ć': 'c', 'č': 'c', 'ñ': 'n', 'ń': 'n', 'š': 's', 'ś': 's',
      'ž': 'z', 'ź': 'z', 'ż': 'z', 'ß': 'ss', 'ł': 'l', 'đ': 'd',
      'ğ': 'g', 'ı': 'i', 'œ': 'oe', 'æ': 'ae',
    };
    final buf = StringBuffer();
    for (final cp in text.runes) {
      final ch = String.fromCharCode(cp);
      buf.write(map[ch] ?? ch);
    }
    return buf.toString();
  }
}
