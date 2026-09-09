/// Tier-1 on-device line classifier: fine-tuned `bert-tiny` (L=2, H=128)
/// exported to int8 ONNX, run with `flutter_onnxruntime` (CPU).
///
/// Same job as [NgramClassifier] — one vote per OCR line so the fusion in
/// `field_extractor.dart` can rescue garbled labels — but with real context
/// understanding instead of bag-of-ngrams. Same lifecycle and contract:
///
/// * [warmUp] once (background, best-effort), [retry] to reload,
///   [isReady]/[lastError] for status.
/// * [classify] never throws: unready/empty input yields `other`/0 votes and
///   the caller falls back (first to [NgramClassifier], then regex-only).
///
/// Model: `assets/models/tiny/line_tiny_int8.onnx`, trained by
/// `tool/train_tiny_clf.py` from `tool/prototypes.json`. Tokenization here
/// replicates the HF BertTokenizer exactly (see `wordpiece.dart`); the
/// parity set `tool/tiny_clf_parity.json` pins field + probability.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'ngram_classifier.dart' show LineLabel;
import 'wordpiece.dart';

class TinyClassifier {
  TinyClassifier();

  static const String modelAsset = 'assets/models/tiny/line_tiny_int8.onnx';
  static const String vocabAsset = 'assets/models/tiny/vocab.txt';
  static const String metaAsset = 'assets/models/tiny/meta.json';

  /// Lines per ONNX run (one batched run per chunk, padded to the chunk's
  /// longest line — keeps native round-trips near one per scan).
  static const int batchSize = 64;

  WordPieceTokenizer? _tok;
  OrtSession? _session;
  List<String> _classes = const [];
  int _maxLen = 48;
  Future<void>? _initFuture;

  /// Reason the model failed to load (null when healthy/never tried).
  String? lastError;

  bool get isReady =>
      _session != null && _tok != null && _classes.isNotEmpty;

  List<String> get classes => _classes;

  /// Loads vocab + weights (background, best-effort, idempotent).
  Future<void> warmUp() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  /// Clears cached state and reloads (Retry button).
  Future<void> retry() async {
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
    _tok = null;
    _classes = const [];
    _initFuture = null;
    lastError = null;
    return warmUp();
  }

  Future<void> _init() async {
    try {
      final metaRaw = await rootBundle.loadString(metaAsset);
      final meta = jsonDecode(metaRaw) as Map<String, Object?>;
      final classes =
          (meta['classes'] as List).map((e) => e.toString()).toList();
      final maxLen = (meta['max_len'] as num?)?.toInt() ?? 48;
      if (classes.isEmpty) throw const FormatException('no classes');
      final tok = await WordPieceTokenizer.load(vocabAsset);
      final session = await OnnxRuntime()
          .createSessionFromAsset(modelAsset);
      _classes = classes;
      _maxLen = maxLen;
      _tok = tok;
      _session = session;
      lastError = null;
    } catch (e) {
      try {
        await _session?.close();
      } catch (_) {}
      _session = null;
      _tok = null;
      _classes = const [];
      lastError = _shortError(e);
    }
  }

  static String _shortError(Object e) {
    var s = e.toString();
    s = s.replaceFirst(RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  /// Classifies [lines] → aligned [LineLabel]s. Batched single-run per
  /// chunk; falls back to all-`other`/0 when not ready (caller then tries
  /// the keyword model, then regex-only).
  Future<List<LineLabel>> classify(List<String> lines) async {
    final session = _session;
    final tok = _tok;
    final classes = _classes;
    if (session == null ||
        tok == null ||
        classes.isEmpty ||
        lines.isEmpty) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
    try {
      final out = List<LineLabel>.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
      for (var start = 0; start < lines.length; start += batchSize) {
        final end = (start + batchSize).clamp(0, lines.length);
        final chunk = lines.sublist(start, end);
        final votes = await _runChunk(session, tok, classes, chunk);
        out.setRange(start, end, votes);
      }
      return out;
    } catch (_) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
  }

  Future<List<LineLabel>> _runChunk(
    OrtSession session,
    WordPieceTokenizer tok,
    List<String> classes,
    List<String> chunk,
  ) async {
    final enc = tok.encodeBatch(chunk, maxLen: _maxLen);
    final rows = chunk.length;
    final cols = enc.ids.length ~/ rows;
    final ids = OrtValue.fromList(Int64List.fromList(enc.ids), [rows, cols]);
    final mask =
        OrtValue.fromList(Int64List.fromList(enc.mask), [rows, cols]);
    OrtValue? idsV;
    OrtValue? maskV;
    try {
      idsV = await ids;
      maskV = await mask;
      final results = await session.run({
        'input_ids': idsV,
        'attention_mask': maskV,
      });
      try {
        final entry = results['logits'] ?? results.values.first;
        final nested = await entry.asList();
        return [
          for (final row in nested)
            _argmaxSoftmax(
                [for (final v in (row as List)) (v as num).toDouble()],
                classes)
        ];
      } finally {
        for (final v in results.values) {
          try {
            await v.dispose();
          } catch (_) {}
        }
      }
    } finally {
      try {
        await idsV?.dispose();
      } catch (_) {}
      try {
        await maskV?.dispose();
      } catch (_) {}
    }
  }

  static LineLabel _argmaxSoftmax(List<double> logits, List<String> classes) {
    var best = 0;
    var bestLogit = logits[0];
    for (var i = 1; i < logits.length; i++) {
      if (logits[i] > bestLogit) {
        bestLogit = logits[i];
        best = i;
      }
    }
    var sumExp = 0.0;
    var bestExp = 0.0;
    for (var i = 0; i < logits.length; i++) {
      final e = math.exp(logits[i] - bestLogit);
      sumExp += e;
      if (i == best) bestExp = e;
    }
    return LineLabel(
        field: classes[best], confidence: bestExp / sumExp);
  }
}
