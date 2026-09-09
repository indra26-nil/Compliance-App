/// MiniLM-L6 sentence embeddings on the bundled int8 ONNX model.
///
/// * Model: `assets/models/embeddings/minilm_quantized.onnx` (Xenova
///   all-MiniLM-L6-v2, ~22 MB, 384-dim). Runs on the `onnxruntime` plugin
///   (CPU, multithreaded) — a separate ORT copy from the Paddle plugin's,
///   but only model + a few MB of arena at runtime.
/// * Tokenizer: BERT WordPiece from the bundled `tokenizer.json`
///   (see `wordpiece.dart`), max 32 tokens/line — label lines are short.
/// * Pooling: attention-masked mean + L2 norm (the sentence-transformers
///   recipe), done in Dart.
/// * Batching: ALL lines of a scan go through ONE `runAsync` call, so the
///   per-scan cost is a single inference (typically well under a second
///   even on A53-class CPUs; prototype embeddings are computed once and
///   cached — see `line_classifier.dart`).
///
/// Lifecycle: call [warmUp] once from app start (background, best-effort).
/// Every public method degrades to "not ready" (never throws into the scan
/// pipeline — the caller falls back to regex-only extraction).
///
/// If APK size ever becomes an issue, move the two asset files to a
/// first-launch download into app-support and point [modelAsset]/[vocabAsset]
/// at file paths instead — the rest of this file stays identical.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'wordpiece.dart';

class MiniLMEmbedder {
  MiniLMEmbedder._();
  static final MiniLMEmbedder instance = MiniLMEmbedder._();

  static const String modelAsset =
      'assets/models/embeddings/minilm_quantized.onnx';
  static const String vocabAsset =
      'assets/models/embeddings/tokenizer.json';

  /// Max WordPiece tokens per line (label lines are short; keeps batches tiny).
  static const int maxLen = 32;

  /// Embedding width of MiniLM-L6.
  static const int dim = 384;

  OrtSession? _session;
  WordPieceTokenizer? _tokenizer;
  Future<void>? _initFuture;

  /// Short human-readable reason for the last init/embed failure
  /// (surfaced on the OCR-review screen; null when healthy/never tried).
  String? lastError;

  bool get isReady => _session != null && _tokenizer != null;

  /// Loads model + vocab in the background. Safe to call repeatedly.
  /// Failures are recorded in [lastError] (caller checks [isReady]).
  Future<void> warmUp() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  /// Clears cached state and retries init (OCR-review "Retry" button).
  /// The plain [warmUp] never retries a completed failure.
  Future<void> retry() {
    _initFuture = null;
    lastError = null;
    return warmUp();
  }

  Future<void> _init() async {
    try {
      OrtEnv.instance.init();
      final modelBytes =
          (await rootBundle.load(modelAsset)).buffer.asUint8List();
      _session =
          OrtSession.fromBuffer(modelBytes, OrtSessionOptions());
      final vocabJson = jsonDecode(
          await rootBundle.loadString(vocabAsset)) as Map<String, Object?>;
      _tokenizer = WordPieceTokenizer.fromTokenizerJson(vocabJson,
          maxLen: maxLen);
      lastError = null;
    } catch (e) {
      _session = null;
      _tokenizer = null;
      lastError = _shortError(e);
    }
  }

  static String _shortError(Object e) {
    var s = e.toString();
    // Strip Dart's "Exception: " prefix noise for the officer-facing UI.
    s = s.replaceFirst(RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  /// Embeds [texts] in ONE batched inference → L2-normalized vectors.
  /// Returns [] when the model isn't ready (caller falls back).
  Future<List<Float32List>> embedBatch(List<String> texts) async {
    final session = _session;
    final tokenizer = _tokenizer;
    if (session == null || tokenizer == null || texts.isEmpty) return [];
    try {
      final n = texts.length;
      final ids = Int64List(n * maxLen);
      final mask = Int64List(n * maxLen);
      final typeIds = Int64List(n * maxLen); // all zeros
      for (var i = 0; i < n; i++) {
        final enc = tokenizer.encode(texts[i]);
        for (var j = 0; j < maxLen; j++) {
          ids[i * maxLen + j] = enc.ids[j];
          mask[i * maxLen + j] = enc.mask[j];
        }
      }
      final shape = [n, maxLen];
      final idT =
          OrtValueTensor.createTensorWithDataList(ids, shape);
      final maskT =
          OrtValueTensor.createTensorWithDataList(mask, shape);
      final typeT =
          OrtValueTensor.createTensorWithDataList(typeIds, shape);
      List<OrtValue?>? outputs;
      try {
        outputs = await session.runAsync(
          OrtRunOptions(),
          {
            'input_ids': idT,
            'attention_mask': maskT,
            'token_type_ids': typeT,
          },
        );
        final raw = outputs?.first?.value;
        if (raw is! List || raw.length != n) return [];
        final out = <Float32List>[];
        for (var i = 0; i < n; i++) {
          out.add(_maskedMeanNorm(
              (raw[i] as List), mask.sublist(i * maxLen, (i + 1) * maxLen)));
        }
        return out;
      } finally {
        idT.release();
        maskT.release();
        typeT.release();
        outputs?.forEach((e) => e?.release());
      }
    } catch (e) {
      lastError ??= _shortError(e);
      return [];
    }
  }

  /// Masked mean over sequence dim + L2 normalization.
  static Float32List _maskedMeanNorm(List seq, Int64List mask) {
    final acc = Float64List(dim);
    var count = 0;
    for (var j = 0; j < seq.length && j < mask.length; j++) {
      if (mask[j] == 0) continue;
      final vec = seq[j] as List;
      for (var k = 0; k < dim && k < vec.length; k++) {
        acc[k] += (vec[k] as num).toDouble();
      }
      count++;
    }
    final out = Float32List(dim);
    if (count == 0) return out;
    var norm = 0.0;
    for (var k = 0; k < dim; k++) {
      final v = acc[k] / count;
      out[k] = v;
      norm += v * v;
    }
    norm = norm <= 0 ? 1 : math.sqrt(norm);
    for (var k = 0; k < dim; k++) {
      out[k] = out[k] / norm;
    }
    return out;
  }
}
