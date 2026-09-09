/// On-device line classifier: char n-gram logistic regression (pure Dart).
///
/// Each OCR line is classified into a field class (brand, mrp, …) in
/// microseconds with no model download, no native plugin and no warm-up
/// beyond parsing one ~220 KB JSON asset. It replaces the MiniLM prototype
/// kNN and beats it on OCR garble (1.00 vs 0.86 on 324 synthetic noisy
/// lines; tied elsewhere) because character n-grams degrade gracefully
/// under substitutions/deletions while WordPiece shatters.
///
/// Model: `assets/models/ngram/line_clf.json`, trained offline by
/// `tool/train_line_clf.py` from `tool/prototypes.json` (officer-observed
/// label lines + garble variants) as char (3,5)-gram TF-IDF +
/// multinomial logistic regression on clean + synthetic OCR noise.
/// Inference here replicates scikit-learn exactly:
/// lowercase → whitespace split → space-padded char n-grams → tf·idf
/// (smooth, L2-normalized) → linear scores → softmax argmax.
///
/// Retraining (e.g. after collecting officer corrections): edit
/// `tool/prototypes.json`, run the trainer, then run
/// `test/ngram_classifier_test.dart` — it checks every probe line in
/// `tool/line_clf_parity.json` against the trainer's own predictions.
///
/// Lifecycle mirrors the old classifier: [warmUp] once (background,
/// best-effort), [retry] to reload, [isReady]/[lastError] for status.
/// [classify] never throws: unready/empty input yields `other`/0 votes and
/// the caller falls back to regex-only extraction.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// One line's vote (same shape the fusion code consumes).
class LineLabel {
  const LineLabel({required this.field, required this.confidence});

  /// Field class (see [NgramClassifier.classes]).
  final String field;

  /// Softmax probability of the winning class, 0..1. Decisive matches sit
  /// near 0.9+, garbage/ambiguous lines near uniform (~0.06-0.3) — below
  /// the fusion vote threshold, so they safely abstain.
  final double confidence;
}

class NgramClassifier {
  NgramClassifier();

  static const String modelAsset = 'assets/models/ngram/line_clf.json';

  static const int ngramMin = 3;
  static const int ngramMax = 5;

  _NgramModel? _model;
  Future<void>? _initFuture;

  /// Reason the model failed to load (null when healthy/never tried).
  String? lastError;

  bool get isReady => _model != null;

  /// Field classes, in model order. Keep in sync with `tool/prototypes.json`
  /// keys and `field_extractor.dart` fusion maps.
  List<String> get classes => _model?.classes ?? const [];

  /// Loads the weights JSON (background, best-effort, idempotent).
  Future<void> warmUp() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  /// Clears cached state and reloads (Retry button).
  Future<void> retry() {
    _model = null;
    _initFuture = null;
    lastError = null;
    return warmUp();
  }

  Future<void> _init() async {
    try {
      final raw = await rootBundle.loadString(modelAsset);
      _model = _NgramModel.fromJson(
          jsonDecode(raw) as Map<String, Object?>);
      lastError = null;
    } catch (e) {
      _model = null;
      lastError = _shortError(e);
    }
  }

  static String _shortError(Object e) {
    var s = e.toString();
    s = s.replaceFirst(RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  /// Classifies [lines] → aligned [LineLabel]s (microseconds per line).
  /// Returns all-`other`/0 when the model isn't ready (caller falls back).
  Future<List<LineLabel>> classify(List<String> lines) async {
    final model = _model;
    if (model == null || lines.isEmpty) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
    try {
      return [for (final l in lines) model.classifyOne(l)];
    } catch (_) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
  }
}

/// Parsed weights + scikit-learn-compatible inference.
class _NgramModel {
  _NgramModel({
    required this.classes,
    required this.vocab,
    required this.idf,
    required this.coef,
    required this.intercept,
  });

  factory _NgramModel.fromJson(Map<String, Object?> json) {
    final format = (json['format'] as num?)?.toInt();
    if (format != 1) {
      throw FormatException('unsupported line_clf.json format: $format');
    }
    final classes =
        (json['classes'] as List).map((e) => e.toString()).toList();
    final vocabList = (json['vocab'] as List).map((e) => e.toString());
    final vocab = <String, int>{};
    var i = 0;
    for (final w in vocabList) {
      vocab[w] = i++;
    }
    final idf = [
      for (final v in json['idf'] as List) (v as num).toDouble()
    ];
    final coef = <List<(int, double)>>[
      for (final row in json['coef'] as List)
        [
          for (final p in row as List)
            ((p[0] as num).toInt(), (p[1] as num).toDouble()),
        ],
    ];
    final intercept = [
      for (final v in json['intercept'] as List) (v as num).toDouble()
    ];
    if (classes.length != coef.length ||
        classes.length != intercept.length ||
        idf.length != vocab.length) {
      throw const FormatException('line_clf.json has inconsistent shapes');
    }
    return _NgramModel(
      classes: classes,
      vocab: vocab,
      idf: idf,
      coef: coef,
      intercept: intercept,
    );
  }

  final List<String> classes;
  final Map<String, int> vocab;
  final List<double> idf;

  /// Per-class sparse weights, ascending feature index (same accumulation
  /// order as the trainer's sparse dot — keeps parity bit-close).
  final List<List<(int, double)>> coef;
  final List<double> intercept;

  LineLabel classifyOne(String text) {
    // TF-IDF features (mirrors TfidfVectorizer(analyzer='char_wb',
    // ngram_range=(3,5), lowercase, smooth_idf, l2 norm)).
    final counts = <int, int>{};
    for (final word in text.toLowerCase().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final w = ' $word ';
      for (var n = NgramClassifier.ngramMin;
          n <= NgramClassifier.ngramMax;
          n++) {
        for (var k = 0; k + n <= w.length; k++) {
          final idx = vocab[w.substring(k, k + n)];
          if (idx != null) counts[idx] = (counts[idx] ?? 0) + 1;
        }
      }
    }
    var normSq = 0.0;
    counts.forEach((idx, c) {
      final v = c * idf[idx];
      normSq += v * v;
    });
    final norm = normSq > 0 ? math.sqrt(normSq) : 1.0;

    // Linear scores + softmax (argmax == sklearn predict).
    var best = 0;
    var bestScore = double.negativeInfinity;
    final scores = List<double>.filled(classes.length, 0);
    for (var c = 0; c < classes.length; c++) {
      var s = intercept[c];
      for (final (idx, weight) in coef[c]) {
        final count = counts[idx];
        if (count != null) s += (count * idf[idx] / norm) * weight;
      }
      scores[c] = s;
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    var sumExp = 0.0;
    for (var c = 0; c < scores.length; c++) {
      scores[c] = math.exp(scores[c] - bestScore);
      sumExp += scores[c];
    }
    return LineLabel(
        field: classes[best], confidence: scores[best] / sumExp);
  }
}
