/// Parity tests: the pure-Dart inference in `ngram_classifier.dart` must
/// match scikit-learn exactly on every probe line in
/// `tool/line_clf_parity.json` (written by `tool/train_line_clf.py`).
///
/// Run the trainer first after editing `tool/prototypes.json`; this test
/// then verifies the shipped asset + Dart math against the trainer's own
/// predictions (field exact, probability within 1e-6 — the JSON rounds to
/// 6 decimals).
import 'dart:convert';
import 'dart:io';

import 'package:complience_app/services/field_extractor.dart';
import 'package:complience_app/services/ngram_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('weights asset loads and covers 17 classes', () async {
    final clf = NgramClassifier();
    await clf.warmUp();
    expect(clf.isReady, isTrue, reason: 'lastError=${clf.lastError}');
    expect(clf.lastError, isNull);
    expect(clf.classes.length, 17);
  });

  test('dart inference matches sklearn on all probe lines', () async {
    final clf = NgramClassifier();
    await clf.warmUp();
    expect(clf.isReady, isTrue);

    final cases = jsonDecode(
        await File('tool/line_clf_parity.json').readAsString()) as List;
    expect(cases.length, greaterThan(10));
    for (final c in cases) {
      final m = c as Map<String, Object?>;
      final text = m['text'] as String;
      final labels = await clf.classify([text]);
      expect(labels.length, 1);
      expect(labels.first.field, m['field'],
          reason: 'line ${text.debugBox}');
      expect((labels.first.confidence - (m['prob'] as num)).abs(),
          lessThan(1e-6),
          reason: 'line $text');
    }
  });

  test('unready classifier abstains; garbage stays below vote threshold',
      () async {
    // Never warmed up → all-other/0 (regex fallback path).
    final cold = NgramClassifier();
    final labels = await cold.classify(['MRP Rs. 42.00']);
    expect(labels.single.field, 'other');
    expect(labels.single.confidence, 0);

    // Ready but garbage/empty → low confidence, never a counted vote.
    final clf = NgramClassifier();
    await clf.warmUp();
    for (final t in ['', '   ', '!!!']) {
      final l = (await clf.classify([t])).single;
      expect(l.confidence, lessThan(clfVoteThreshold),
          reason: 'line ${t.debugBox} voted ${l.field}@${l.confidence}');
    }
    // A clear line votes decisively.
    final mrp = (await clf.classify(['MPP Rs 42.00'])).single;
    expect(mrp.field, 'mrp');
    expect(mrp.confidence, greaterThan(clfVoteThreshold));
  });
}

extension on String {
  String get debugBox => length > 48 ? '${substring(0, 48)}…' : this;
}
