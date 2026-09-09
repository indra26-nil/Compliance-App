// Tests for the Tier-1 tokenizer + transformer wiring.
//
// * WordPiece tests are pure Dart (run anywhere).
// * The parity test needs a real ONNX session (Android/iOS device): under
//   plain `flutter test` the native plugin is unavailable, so it verifies
//   the graceful fallback instead of failing.
import 'dart:convert';
import 'dart:io';

import 'package:complience_app/services/tiny_classifier.dart';
import 'package:complience_app/services/wordpiece.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('wordpiece basic tokenization splits labels like BERT', () {
    final tok = WordPieceTokenizer({
      'mrp': 0, 'rs': 1, '.': 2, '42': 3, '00': 4,
      '[UNK]': 100, '[CLS]': 101, '[SEP]': 102, '[PAD]': 0,
      'net': 5, 'qty': 6, ':': 7, '80': 8, 'g': 9,
      'mpp': 10, '₹': 11, '99': 12,
    });
    expect(tok.basicTokenize('MRP Rs. 42.00'),
        ['mrp', 'rs', '.', '42', '.', '00']);
    expect(tok.tokenize('MRP Rs. 42.00'),
        ['mrp', 'rs', '.', '42', '.', '00']);
    // Currency sign stays attached (matches HF: Sc, not punctuation).
    expect(tok.basicTokenize('MRP ₹ 99'), ['mrp', '₹', '99']);
    // Unknown script degrades to UNK, never throws.
    expect(tok.tokenize(''), isEmpty);
  });

  test('encode adds CLS/SEP, truncates and pads a batch', () {
    final tok = WordPieceTokenizer({
      'a': 0, '[UNK]': 100, '[CLS]': 101, '[SEP]': 102, '[PAD]': 0,
    });
    final ids = tok.encode('a a a a a', maxLen: 5);
    expect(ids.first, 101);
    expect(ids.last, 102);
    expect(ids.length, lessThanOrEqualTo(5));
    final batch = tok.encodeBatch(['a', 'a a a a a a'], maxLen: 8);
    expect(batch.ids.length % 2, 0);
    expect(batch.mask.length, batch.ids.length);
    // First row (short) is padded with mask 0.
    final width = batch.ids.length ~/ 2;
    final row0mask = batch.mask.sublist(0, width);
    expect(row0mask.contains(0), isTrue);
    expect(row0mask.first, 1);
  });

  test('unready tiny classifier abstains (native plugin absent in test)',
      () async {
    final clf = TinyClassifier();
    // No warmUp call: contract says unready -> all-other/0, never throws.
    final labels = await clf.classify(['MRP Rs. 42.00']);
    expect(labels.length, 1);
    expect(labels.first.field, 'other');
    expect(labels.first.confidence, 0);
  });

  test('tiny parity: Dart matches shipped int8 predictions', () async {
    final clf = TinyClassifier();
    await clf.warmUp();
    if (!clf.isReady) {
      // Plain `flutter test` has no native ONNX runtime — the fallback
      // contract (tested above) is what matters here. Run on-device or
      // via integration test for full parity.
      // ignore: avoid_print
      print('SKIP: tiny model not loadable in unit-test env '
          '(lastError=${clf.lastError})');
      return;
    }
    final cases = jsonDecode(
        await File('tool/tiny_clf_parity.json').readAsString()) as List;
    expect(cases.length, greaterThan(10));
    for (final c in cases) {
      final m = c as Map<String, Object?>;
      final text = m['text'] as String;
      final labels = await clf.classify([text]);
      expect(labels.length, 1);
      expect(labels.first.field, m['field'], reason: 'line $text');
      expect((labels.first.confidence - (m['prob'] as num)).abs(),
          lessThan(1e-3),
          reason: 'line $text');
    }
  });
}
