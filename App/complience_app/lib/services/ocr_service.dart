import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_paddle_ocr_v5/flutter_paddle_ocr_v5.dart';

import 'model_bootstrap.dart';
import 'ocr_postprocess.dart';
import 'ocr_preprocess.dart';
import 'ocr_tokens.dart';

/// Joined plain-text plus the kept per-region results from one OCR run.
class OcrOutput {
  const OcrOutput({
    required this.text,
    required this.results,
    this.meanConfidence = 0,
    this.rawRegionCount = 0,
    this.preparedWidth = 0,
    this.preparedHeight = 0,
  });

  final String text;
  final List<OcrResult> results;

  /// Mean recognition confidence over kept regions.
  final double meanConfidence;

  /// Raw region count before noise filtering (diagnostics).
  final int rawRegionCount;

  /// Dimensions of the pre-processed image fed to the engine. Token
  /// [OcrResult.points] are in this space — [scan_pipeline] uses these to
  /// normalize geometry for layout reconstruction and to map label boxes
  /// back to original-image crops for the variable-print re-read pass.
  /// (0, 0) means "geometry unknown" (bounds decode failed).
  final int preparedWidth;
  final int preparedHeight;
}

/// Coarse pipeline stage reported via `onStage` so a loading screen can show
/// the user what is happening instead of appearing frozen.
enum OcrStage {
  /// Reading the file + decode/resize/re-encode (now on a bg isolate).
  preparingImage,

  /// Copying bundled models (first run) + native engine init.
  loadingEngine,

  /// Native PP-OCRv5 detect + recognize (already off the UI thread).
  scanningText,
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
  ///
  /// [onStage] is invoked on the UI thread between pipeline phases so a
  /// loading screen can update its step indicator. Image pre-processing runs
  /// on a background isolate by default ([useBackgroundIsolate]) so the UI
  /// never freezes while "Use This Photo" is handled.
  Future<OcrOutput> recognizeFile(
    File image, {
    int maxSideLen = 2560,
    bool? useLexicon,
    void Function(OcrStage stage)? onStage,
    bool useBackgroundIsolate = true,
  }) async {
    onStage?.call(OcrStage.preparingImage);
    status.value = 'Preparing photo...';
    final bytes = await image.readAsBytes();
    return recognizeBytes(
      bytes,
      maxSideLen: maxSideLen,
      useLexicon: useLexicon,
      onStage: onStage,
      useBackgroundIsolate: useBackgroundIsolate,
      // Bytes already in hand — skip the re-read stage notification.
      skipPreparingStage: true,
    );
  }

  Future<OcrOutput> recognizeBytes(
    Uint8List bytes, {
    int maxSideLen = 2560,
    bool? useLexicon,
    void Function(OcrStage stage)? onStage,
    bool useBackgroundIsolate = true,
    bool skipPreparingStage = false,
  }) async {
    if (!skipPreparingStage) {
      onStage?.call(OcrStage.preparingImage);
      status.value = 'Preparing photo...';
    }
    // 2x upscale + orientation normalisation + high-quality re-encode.
    // Background isolate keeps the loading screen animating (previously this
    // decode/resize/encode ran on the UI thread and froze the app for
    // seconds on a 3000px photo).
    final prepared = useBackgroundIsolate
        ? await prepareLabelImageBytesBackground(bytes)
        : await prepareLabelImageBytes(bytes);

    onStage?.call(OcrStage.loadingEngine);
    final engine = await _ensureEngine();

    onStage?.call(OcrStage.scanningText);
    status.value = 'Scanning text...';
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
    // Bounds for geometry consumers (layout, variable-print crops).
    // Isolate decode; (0,0) on failure — callers treat as unknown.
    var prepW = 0;
    var prepH = 0;
    try {
      final dims = await imageBounds(prepared);
      prepW = dims.$1;
      prepH = dims.$2;
    } catch (_) {}
    return OcrOutput(
      text: text,
      results: kept,
      meanConfidence: OcrPostprocess.meanConfidence(kept),
      rawRegionCount: raw.length,
      preparedWidth: prepW,
      preparedHeight: prepH,
    );
  }

  /// Recognizes ALREADY-PREPARED bytes (e.g. variable-print crops from
  /// [variable_print.dart]) without re-running the standard pipeline, and
  /// returns geometry-preserving [OcrToken]s (raw, unfiltered except empty
  /// text — the caller owns filtering since crops are tiny and dense).
  ///
  /// [photoIndex] tags the tokens for multi-photo merging.
  Future<List<OcrToken>> recognizePreparedTokens(
    Uint8List preparedBytes, {
    int maxSideLen = 1600,
    int photoIndex = 0,
  }) async {
    final engine = await _ensureEngine();
    status.value = 'Re-reading small print...';
    // Bound native re-read: without this a stalled native call hangs the
    // "Extracting…" button forever (no timeout upstream can cancel it).
    final raw = await engine
        .recognize(
      preparedBytes,
      maxSideLen: maxSideLen,
      runDetection: true,
      runClassification: false,
      runRecognition: true,
    )
        .timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
          'Small-print re-read timed out after 15s'),
    );
    final out = <OcrToken>[];
    for (final r in raw) {
      if (r.text.trim().isEmpty) continue;
      out.add(OcrToken(
        text: r.text,
        ocrConfidence: r.confidence,
        box: PixelBox.fromQuad(
          [for (final p in r.points) Point(p.dx, p.dy)],
        ),
        photoIndex: photoIndex,
      ));
    }
    return out;
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _initFuture = null;
  }
}
