import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_paddle_ocr_v5/flutter_paddle_ocr_v5.dart';

import 'model_bootstrap.dart';
import 'ocr_postprocess.dart';
import 'ocr_preprocess.dart';

/// Joined plain-text plus the kept per-region results from one OCR run.
class OcrOutput {
  const OcrOutput({
    required this.text,
    required this.results,
    this.meanConfidence = 0,
    this.rawRegionCount = 0,
  });

  final String text;
  final List<OcrResult> results;

  /// Mean recognition confidence over kept regions.
  final double meanConfidence;

  /// Raw region count before noise filtering (diagnostics).
  final int rawRegionCount;
}

/// Singleton wrapper around the native PP-OCRv5 engine, tuned for packaged
/// food labels (nutrition tables / ingredients / MRP / net-qty use tiny print
/// that the old 960px + low-threshold setup destroyed).
///
/// Usage:
/// ```dart
/// final output = await OcrService.instance.recognizeFile(File(path));
/// ```
///
/// The engine is created lazily on first use (model copy + native init takes
/// ~1-2s) and reused afterwards. Native inference already runs off the UI
/// thread, so no extra Dart isolate is needed.
class OcrService {
  OcrService._();
  static final OcrService instance = OcrService._();

  PaddleOcr? _engine;
  Future<PaddleOcr>? _initFuture;

  bool get isReady => _engine != null;

  /// Status stream text for scaffolding UIs (model copy / init progress).
  final ValueNotifier<String> status = ValueNotifier<String>('Idle');

  /// Food-label vocabulary spell correction. On by default; turn off to get
  /// raw OCR text (useful for non-food packages or debugging).
  bool lexiconEnabled = true;

  Future<PaddleOcr> _ensureEngine() {
    if (_engine != null) return Future.value(_engine!);
    _initFuture ??= _init();
    return _initFuture!;
  }

  Future<PaddleOcr> _init() async {
    status.value = 'Preparing OCR models...';
    final source = await prepareBundledModelSource(
      onStatus: (s) => status.value = s,
    );
    status.value = 'Loading OCR engine...';
    final engine = await PaddleOcr.create(
      source: source,
      cpuThreadNum: 4,
      useSpaceChar: true,
      // Label-tuned detection: the old (0.2 / 0.4 / 1.4 / dilation=true)
      // over-segmented table gridlines into char boxes, which the recogniser
      // then read as the `'`/`"` speckle in the bug report. These values
      // match PaddleOCR mobile defaults for dense document text: fewer false
      // boxes, wider unclip so one line stays one box.
      detDbThresh: 0.3,
      detDbBoxThresh: 0.5,
      detDbUnclipRatio: 2.0,
      useDilation: false,
    );
    _engine = engine;
    status.value = 'Ready';
    return engine;
  }

  /// Warm up the engine (e.g. from app start) so the first scan is fast.
  Future<void> warmUp() async {
    try {
      await _ensureEngine();
    } catch (e) {
      status.value = 'OCR init failed: $e';
      _initFuture = null;
      rethrow;
    }
  }

  /// High-accuracy default: 2560px + 2x pre-upscale keeps 6-9pt nutrition
  /// print legible. (The original 960px default downscaled a 4000px label
  /// photo ~4x and was the single biggest accuracy loss.)
  Future<OcrOutput> recognizeFile(File image,
      {int maxSideLen = 2560, bool? useLexicon}) async {
    final bytes = await image.readAsBytes();
    return recognizeBytes(bytes,
        maxSideLen: maxSideLen, useLexicon: useLexicon);
  }

  Future<OcrOutput> recognizeBytes(Uint8List bytes,
      {int maxSideLen = 2560, bool? useLexicon}) async {
    final engine = await _ensureEngine();
    // 2x upscale + orientation normalisation + high-quality re-encode.
    final prepared = await prepareLabelImageBytes(bytes);
    final raw = await engine.recognize(
      prepared,
      maxSideLen: maxSideLen,
      runDetection: true,
      // No cls model is bundled (det+rec+dict only); enabling this without a
      // cls .onnx crashes native init. Tilted shots are handled by the
      // detector's rotation-aware crop instead.
      runClassification: false,
      runRecognition: true,
    );
    // Filter <0.5-confidence speckle, restore top-to-bottom reading order,
    // de-fragment char boxes, merge table rows and snap compliance keywords.
    final kept = OcrPostprocess.filterAndSort(raw);
    final text = OcrPostprocess.buildCleanText(kept,
        useLexicon: useLexicon ?? lexiconEnabled);
    return OcrOutput(
      text: text,
      results: kept,
      meanConfidence: OcrPostprocess.meanConfidence(kept),
      rawRegionCount: raw.length,
    );
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _initFuture = null;
  }
}
