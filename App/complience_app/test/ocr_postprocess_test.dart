import 'package:complience_app/services/ocr_postprocess.dart';
import 'package:flutter_paddle_ocr_v5/flutter_paddle_ocr_v5.dart';
import 'package:flutter_test/flutter_test.dart';

OcrResult box(String text, double conf, double x, double y, double w, double h) {
  return OcrResult(
    text: text,
    confidence: conf,
    points: [
      Offset(x, y),
      Offset(x + w, y),
      Offset(x + w, y + h),
      Offset(x, y + h),
    ],
  );
}

void main() {
  test('quote speckle is stripped but Lay apostrophe kept', () {
    expect(OcrPostprocess.cleanToken("'8'"), '8');
    expect(OcrPostprocess.cleanToken("'0'.'1''9'"), '0.19');
    expect(OcrPostprocess.cleanToken('"Pack<"'), 'Pack<');
    expect(OcrPostprocess.cleanToken("Lay's"), "Lay's");
    expect(OcrPostprocess.cleanToken("'5''3''7'kcd"), '537 kcal');
  });

  test('pure punct noise filtered, real tokens kept', () {
    final input = [
      box("'", 0.5, 0, 0, 10, 14),
      box('"', 0.6, 20, 0, 10, 14),
      box('Energy', 0.9, 0, 30, 80, 20),
      box('537 kcal', 0.85, 100, 30, 80, 20),
      box('5%', 0.8, 200, 30, 30, 20),
    ];
    final kept = OcrPostprocess.filterAndSort(input);
    final texts = kept.map((r) => r.text).toList();
    expect(texts, contains('Energy'));
    expect(texts.any((t) => t == "'" || t == '"'), isFalse);
  });

  test('reading order is top-down then left-right', () {
    final input = [
      box('SERVE SIZE 20g', 0.9, 0, 100, 150, 20),
      box('NUTRITIONAL INFORMATION', 0.9, 0, 50, 200, 20),
      box('Energy', 0.9, 0, 150, 80, 20),
      box('537 kcal', 0.9, 100, 150, 80, 20),
    ];
    final kept = OcrPostprocess.filterAndSort(input);
    expect(kept.first.text, 'NUTRITIONAL INFORMATION');
    expect(kept[1].text, 'SERVE SIZE 20g');
    final text = OcrPostprocess.buildCleanText(kept);
    final lines = text.split('\n');
    expect(lines.first, contains('NUTRITIONAL INFORMATION'));
    expect(lines[1], contains('SERVE SIZE'));
    // Same-line left-to-right join.
    expect(lines.last, contains('Energy'));
    expect(lines.last, contains('537'));
  });

  test('digit fragments rejoin without spaces', () {
    final input = [
      box('Energy', 0.9, 0, 0, 80, 20),
      box('5', 0.8, 100, 0, 12, 20),
      box('3', 0.8, 113, 0, 12, 20),
      box('7', 0.8, 126, 0, 12, 20),
    ];
    final kept = OcrPostprocess.filterAndSort(input);
    final text = OcrPostprocess.buildCleanText(kept);
    expect(text, contains('537'));
    expect(text, isNot(contains('5 3 7')));
  });

  test('compliance keyword snapping', () {
    final input = [
      box('Sodum', 0.7, 0, 0, 80, 20),
      box('643 mg', 0.9, 100, 0, 60, 20),
      box('Protoin', 0.7, 0, 30, 80, 20),
      box('Enengy', 0.7, 0, 60, 80, 20),
    ];
    final text = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input),
    );
    expect(text, contains('Sodium'));
    expect(text, contains('Protein'));
    expect(text, contains('Energy'));
  });

  test('confidence floor: below 0.5 discarded, 0.5 kept', () {
    final input = [
      box('Energy', 0.49, 0, 0, 80, 20),
      box('Protein', 0.5, 0, 30, 80, 20),
    ];
    final kept = OcrPostprocess.filterAndSort(input);
    expect(kept.map((r) => r.text), contains('Protein'));
    expect(kept.map((r) => r.text), isNot(contains('Energy')));
  });

  test('hyphenated line wraps merge', () {
    final input = [
      box('Maltodex-', 0.9, 0, 0, 100, 20),
      box('trin', 0.85, 0, 30, 50, 20),
      box('Energy', 0.9, 0, 60, 80, 20),
    ];
    final text = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input),
    );
    expect(text, contains('Maltodextrin'));
    // Uppercase table rows are never glued to the next line.
    final input2 = [
      box('TOTAL-', 0.9, 0, 0, 80, 20),
      box('Energy', 0.9, 0, 30, 80, 20),
    ];
    final text2 = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input2),
    );
    expect(text2.split('\n').length, 2);
  });

  test('whitespace restoration for glued tokens', () {
    final input = [
      box('ALLERGENADVICE:ContainsSoy Mak', 0.9, 0, 0, 250, 20),
      box('Oil(Palm)', 0.9, 0, 30, 100, 20),
    ];
    final text = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input),
    );
    expect(text, contains('ALLERGEN ADVICE: Contains Soy Milk'));
    expect(text, contains('Oil (Palm)'));
  });

  test('unit and percent normalisation', () {
    expect(OcrPostprocess.cleanToken('80g'), '80 g');
    expect(OcrPostprocess.cleanToken('5 %'), '5%');
    final input = [
      box('Per 100g', 0.9, 0, 0, 100, 20),
    ];
    final text = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input),
    );
    // Canonical header spelling preserved.
    expect(text, contains('Per 100g'));
  });

  test('duplicate overlapping detections deduped', () {
    final input = [
      box('Energy', 0.9, 0, 0, 80, 20),
      box('Energy', 0.6, 4, 1, 80, 20),
      box('537 kcal', 0.9, 100, 0, 80, 20),
    ];
    final text = OcrPostprocess.buildCleanText(
      OcrPostprocess.filterAndSort(input),
    );
    expect('Energy'.allMatches(text).length, 1);
  });

  test('lexicon correction is optional', () {
    final input = [
      box('Sodum', 0.9, 0, 0, 80, 20),
    ];
    final kept = OcrPostprocess.filterAndSort(input);
    expect(OcrPostprocess.buildCleanText(kept), contains('Sodium'));
    expect(
      OcrPostprocess.buildCleanText(kept, useLexicon: false),
      contains('Sodum'),
    );
  });
}
