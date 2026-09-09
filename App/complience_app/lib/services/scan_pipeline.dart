/// Offline multi-photo scan pipeline: OCR → layout → extract → re-read →
/// rule-check → save.
///
/// Two entry styles:
/// * [ScanPipeline.runProductScan] — one shot (used by tests + legacy callers).
/// * Staged UI flow — [ocrPhotos] → (officer reviews/cleans OCR lines,
///   picks [ExtractionMode]) → [extractWithMode] → (officer reviews/corrects
///   fields) → [checkAndSave]. The review screens keep geometry intact:
///   line edits rebuild layouts with the same boxes, so spatial extraction
///   keeps working.
///
/// Flow per product (all on-device, no network):
/// 1. OCR each photo via [OcrService]. Raw [OcrResult]s (text + confidence +
///    corner points) are converted to [OcrToken]s — bounding boxes are NEVER
///    flattened into one string (the old pipeline's root defect).
/// 2. [buildLayout] groups tokens into lines + blocks per photo using
///    normalized coordinates (resolution independent).
/// 3. [extractProduct] runs label→value spatial association + strict
///    validators + quarantines (barcode/FSSAI/unit-price traps) and merges
///    across photos (best-status-wins). [ExtractionMode] selects how the
///    Option-B MiniLM votes are used.
/// 4. [rereadVariableFields] retries UNVERIFIED dot-matrix fields
///    (batch/MRP/dates) with cropped, enhanced re-OCR variants.
/// 5. [RuleEngine.check] maps observations to PASS/FAIL/UNVERIFIED —
///    an extraction gap on a weak capture is UNVERIFIED, never FAIL.
/// 6. Persist via [OcrStore.insertProductScan] (full report JSON + thumbs).
///
/// ## Backend handoff (D — implement later, see [BackendApi] + docs)
/// When the server exists, step 7 becomes:
/// ```dart
/// // TODO(BACKEND-D): after local save, queue for upload:
/// // await BackendApi.instance.uploadScan(
/// //   productName: productName,
/// //   category: category,
/// //   imagePaths: imagePaths,          // multipart files
/// //   reportJson: report.toJson(),     // POST /api/scans
/// //   ocrText: combinedText,
/// // );
/// // Mark row synced (add `synced` column), retry on connectivity_plus.
/// ```
/// The local report stays the source of truth offline; the server copy
/// powers the dashboard (E) and PDF archive (F).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'embedder.dart';
import 'field_extractor.dart';
import 'line_classifier.dart';
import 'ocr_layout.dart';
import 'ocr_preprocess.dart';
import 'ocr_service.dart';
import 'ocr_store.dart';
import 'ocr_tokens.dart';
import 'rule_engine.dart';
import 'variable_print.dart';

/// Coarse stage for the processing-screen step indicator.
enum ScanStage {
  scanningPhotos,
  extracting,
  checkingRules,
  saving,
}

/// How OCR lines become structured declarations (chosen by the officer on
/// the OCR-review screen).
enum ExtractionMode {
  /// Pure regex/spatial path — no model, deterministic, fastest.
  /// Best when OCR text is clean and labels read verbatim.
  regex,

  /// MiniLM line-vote fusion (Option B): classifier votes rescue garbled
  /// labels (`MPP Rs`, `NETUT 90g`), regexes stay as validators.
  /// Falls back to [regex] when the embedding model isn't ready.
  minilm,

  /// Runs BOTH paths and merges best-status-wins per field
  /// ([ExtractedProduct.merge]). Slowest, most forgiving: a declaration
  /// found clearly by EITHER path counts. Validators still apply, so a
  /// bare barcode can never become MRP in either path.
  ensemble,
}

/// UI copy for the mode picker on the OCR-review screen.
extension ExtractionModeUi on ExtractionMode {
  String get title => switch (this) {
        ExtractionMode.regex => 'Regex formatting',
        ExtractionMode.minilm => 'MiniLM assist',
        ExtractionMode.ensemble => 'Ensemble (both)',
      };

  String get subtitle => switch (this) {
        ExtractionMode.regex =>
          'Auto-format with rules only. Fastest, fully offline, no model.',
        ExtractionMode.minilm =>
          'Small on-device model rescues garbled labels; rules still validate.',
        ExtractionMode.ensemble =>
          'Runs both and keeps the best of each field. Slowest, most forgiving.',
      };
}

class ProductScanOutcome {
  const ProductScanOutcome({
    required this.record,
    required this.report,
    required this.perPhotoTexts,
  });

  final ProductScanRecord record;
  final ComplianceReport report;
  final List<String> perPhotoTexts;
}

/// Result of stage 1 (OCR + layout), handed to the OCR-review screen.
/// [originals]/[origSizes] are keyed by photo index (same as [imagePaths]).
class OcrBundle {
  const OcrBundle({
    required this.imagePaths,
    required this.layouts,
    required this.originals,
    required this.origSizes,
    required this.meanConfidence,
    required this.regionSum,
  });

  final List<String> imagePaths;
  final List<PageLayout> layouts;
  final Map<int, Uint8List> originals;
  final Map<int, (int, int)> origSizes;
  final double meanConfidence;
  final int regionSum;
}

/// Result of stage 2 (extraction), handed to the field-review screen.
class PendingScan {
  const PendingScan({
    required this.imagePaths,
    required this.productName,
    required this.category,
    required this.layouts,
    required this.originals,
    required this.origSizes,
    required this.meanConfidence,
    required this.regionSum,
    required this.product,
    required this.combinedText,
    required this.quality,
    required this.mode,
    required this.modeNote,
    required this.perPhotoTexts,
  });

  final List<String> imagePaths;
  final String productName;
  final ProductCategory category;
  final List<PageLayout> layouts;
  final Map<int, Uint8List> originals;
  final Map<int, (int, int)> origSizes;
  final double meanConfidence;
  final int regionSum;
  final ExtractedProduct product;
  final String combinedText;
  final ExtractionQuality quality;
  final ExtractionMode mode;
  final String modeNote;
  final List<String> perPhotoTexts;
}

class ScanPipeline {
  const ScanPipeline();

  /// Shared Option-B classifier (prototype embeddings cached after first
  /// warm-up — one batched inference per scan, never per line).
  static final LineClassifier _lineClassifier = LineClassifier();

  /// Best-effort background warm-up (call from app start; safe to ignore).
  /// Covers both the MiniLM session and the prototype bank.
  static Future<void> warmUpClassifier() async {
    try {
      await MiniLMEmbedder.instance.warmUp();
      await _lineClassifier.warmUp();
    } catch (_) {
      // Offline fallback: extraction runs regex-only.
    }
  }

  /// True when MiniLM votes are actually available on this device.
  /// The OCR-review screen uses this to mark modes available vs fallback.
  static bool get isClassifierReady =>
      MiniLMEmbedder.instance.isReady && _lineClassifier.isReady;

  /// Retries both the MiniLM session and the prototype bank
  /// (plain [warmUpClassifier] never retries a completed failure).
  static Future<void> retryClassifier() async {
    try {
      await MiniLMEmbedder.instance.retry();
      await _lineClassifier.retry();
    } catch (_) {
      // Status strings below carry the reason.
    }
  }

  /// Officer-facing MiniLM status for the OCR-review screen.
  static String classifierStatus() {
    if (isClassifierReady) return 'ready';
    final modelErr = MiniLMEmbedder.instance.lastError;
    final bankErr = _lineClassifier.lastError;
    if (modelErr != null) return 'model load failed: $modelErr';
    if (bankErr != null) return 'prototype build failed: $bankErr';
    return 'still loading — open this screen again in a few seconds '
        'if it persists, use Retry.';
  }

  /// Stage 1: OCR each photo → token layouts. Pure capture work, no
  /// extraction — the officer reviews/cleans lines before stage 2.
  Future<OcrBundle> ocrPhotos({
    required List<String> imagePaths,
    void Function(int done, int total)? onPhotoProgress,
  }) async {
    assert(imagePaths.isNotEmpty, 'Need at least one photo per product.');
    final layouts = <PageLayout>[];
    final originals = <int, Uint8List>{};
    final origSizes = <int, (int, int)>{};
    var confSum = 0.0;
    var regionSum = 0;
    for (var i = 0; i < imagePaths.length; i++) {
      final file = File(imagePaths[i]);
      // Original bytes: needed for the variable-print crop pass and as a
      // geometry fallback. Read failure must not kill the whole product —
      // that photo is skipped.
      Uint8List? origBytes;
      try {
        origBytes = await file.readAsBytes();
      } catch (_) {
        onPhotoProgress?.call(i + 1, imagePaths.length);
        continue;
      }
      final output =
          await OcrService.instance.recognizeFile(file);
      confSum += output.meanConfidence;
      regionSum += output.results.length;

      // Geometry space: prepared-image dims when known (token points live
      // in that space); original dims otherwise — identical normalized
      // layout either way since pre-processing scales uniformly.
      var w = output.preparedWidth;
      var h = output.preparedHeight;
      if (w <= 0 || h <= 0) {
        try {
          final dims = await imageBounds(origBytes);
          w = dims.$1;
          h = dims.$2;
        } catch (_) {}
      }
      if (w > 0 && h > 0) {
        originals[i] = origBytes;
        origSizes[i] = (w, h);
        final tokens = <OcrToken>[
          for (final r in output.results)
            OcrToken(
              text: r.text,
              ocrConfidence: r.confidence,
              box: PixelBox.fromQuad(
                [for (final p in r.points) Point(p.dx, p.dy)],
              ),
              photoIndex: i,
            ),
        ];
        layouts.add(buildLayout(tokens,
            imgW: w.toDouble(), imgH: h.toDouble(), photoIndex: i));
      }
      onPhotoProgress?.call(i + 1, imagePaths.length);
    }
    if (layouts.isEmpty) {
      throw StateError(
          'No readable photos — all ${imagePaths.length} image(s) failed to load or decode.');
    }
    return OcrBundle(
      imagePaths: List<String>.from(imagePaths),
      layouts: layouts,
      originals: originals,
      origSizes: origSizes,
      meanConfidence: confSum / imagePaths.length,
      regionSum: regionSum,
    );
  }

  /// Applies officer line edits to layouts, preserving geometry.
  ///
  /// [edits] maps `'photoIndex:lineIndex'` (index into
  /// `layout.lines`) to replacement text. Unedited lines keep their
  /// original token objects. Edited lines become a single token over the
  /// original line box with the line's mean confidence; blocks keep their
  /// grouping and hints, so spatial extraction keeps working.
  static List<PageLayout> applyLineEdits(
      List<PageLayout> layouts, Map<String, String> edits) {
    if (edits.isEmpty) return layouts;
    final out = <PageLayout>[];
    for (final layout in layouts) {
      var changed = false;
      final newLines = <LayoutLine>[];
      for (var li = 0; li < layout.lines.length; li++) {
        final line = layout.lines[li];
        final edit = edits['${layout.photoIndex}:$li'];
        if (edit == null || edit == line.text) {
          newLines.add(line);
          continue;
        }
        changed = true;
        newLines.add(LayoutLine(
          [
            OcrToken(
              text: edit,
              ocrConfidence: line.meanConfidence,
              box: line.box,
              photoIndex: layout.photoIndex,
            ),
          ],
          layout.imgW,
          layout.imgH,
        ));
      }
      if (!changed) {
        out.add(layout);
        continue;
      }
      final indexByOld = <LayoutLine, LayoutLine>{};
      for (var i = 0; i < layout.lines.length; i++) {
        indexByOld[layout.lines[i]] = newLines[i];
      }
      out.add(PageLayout(
        lines: newLines,
        blocks: [
          for (final b in layout.blocks)
            LayoutBlock(
              [for (final l in b.lines) indexByOld[l] ?? l],
              layout.imgW,
              layout.imgH,
              b.hint,
            ),
        ],
        imgW: layout.imgW,
        imgH: layout.imgH,
        photoIndex: layout.photoIndex,
      ));
    }
    return out;
  }

  /// Stage 2: extract declarations from (possibly officer-edited) layouts
  /// using [mode], then run the variable-print re-read pass.
  Future<PendingScan> extractWithMode({
    required OcrBundle ocr,
    required String productName,
    required ProductCategory category,
    required ExtractionMode mode,
    Map<String, String> lineEdits = const {},
  }) async {
    final layouts = applyLineEdits(ocr.layouts, lineEdits);
    final combinedText = _joinLayoutTexts(layouts);
    final quality = ExtractionQuality(
      meanConfidence: ocr.meanConfidence,
      totalChars: combinedText.length,
      regionCount: ocr.regionSum,
      photoCount: ocr.imagePaths.length,
    );

    ExtractedProduct product;
    String modeNote;
    switch (mode) {
      case ExtractionMode.regex:
        product = extractProduct(layouts);
        modeNote = 'Regex-only path (MiniLM not used).';
      case ExtractionMode.minilm:
        final lineLabels = await _classifyAllLines(layouts);
        product = extractProduct(layouts, lineLabels: lineLabels);
        modeNote = lineLabels == null
            ? 'MiniLM unavailable on this device — fell back to regex-only.'
            : 'MiniLM votes fused with regex validators.';
      case ExtractionMode.ensemble:
        final lineLabels = await _classifyAllLines(layouts);
        if (lineLabels == null) {
          product = extractProduct(layouts);
          modeNote =
              'MiniLM unavailable — ensemble degraded to regex-only.';
        } else {
          // Best-status-wins per field across both runs; validators hold
          // in both, so quarantines (barcode≠MRP) survive the merge.
          product = ExtractedProduct.merge([
            extractProduct(layouts),
            extractProduct(layouts, lineLabels: lineLabels),
          ]);
          modeNote =
              'Ensemble: best-per-field of regex-only ∪ MiniLM runs.';
        }
    }

    // Variable-print re-read (dot-matrix batch/MRP/dates) — best-effort.
    // Crops come from the ORIGINAL photos, so officer line edits to the
    // main pass don't invalidate this pass; strict patterns, never forced.
    try {
      final targets = targetsFromProduct(product);
      if (targets.isNotEmpty) {
        final improved = await rereadVariableFields(
          originals: ocr.originals,
          origSizes: ocr.origSizes,
          targets: targets,
          recognize: (
            Uint8List preparedBytes, {
            int maxSideLen = 1200,
            int photoIndex = 0,
          }) =>
              OcrService.instance.recognizePreparedTokens(
            preparedBytes,
            maxSideLen: maxSideLen,
            photoIndex: photoIndex,
          ),
        );
        if (improved.isNotEmpty) {
          final fields = Map<String, FieldObservation>.from(product.fields);
          improved.forEach((field, obs) {
            final cur = fields[field];
            if (cur == null ||
                _rank(obs.status) > _rank(cur.status) ||
                (obs.status == cur.status &&
                    obs.fieldConfidence > cur.fieldConfidence)) {
              fields[field] = obs;
            }
          });
          product = ExtractedProduct(
              fields: fields,
              mergedFromPhotos: product.mergedFromPhotos);
        }
      }
    } catch (_) {
      // Re-read is best-effort: any failure keeps the main-pass result.
    }

    return PendingScan(
      imagePaths: ocr.imagePaths,
      productName: productName,
      category: category,
      layouts: layouts,
      originals: ocr.originals,
      origSizes: ocr.origSizes,
      meanConfidence: ocr.meanConfidence,
      regionSum: ocr.regionSum,
      product: product,
      combinedText: combinedText,
      quality: quality,
      mode: mode,
      modeNote: modeNote,
      perPhotoTexts: [for (final l in layouts) l.debugText],
    );
  }

  /// Stage 3: rule-check (optionally over officer-corrected fields) + save.
  Future<ProductScanOutcome> checkAndSave(
    PendingScan pending, {
    ExtractedProduct? productOverride,
    void Function(ScanStage stage)? onStage,
  }) async {
    final product = productOverride ?? pending.product;
    onStage?.call(ScanStage.checkingRules);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final report = const RuleEngine().check(
      product,
      category: pending.category,
      quality: pending.quality,
      combinedText: pending.combinedText,
    );

    onStage?.call(ScanStage.saving);
    final cleanName = pending.productName.trim().isEmpty
        ? 'Unnamed product'
        : pending.productName.trim();
    final id = await OcrStore.instance.insertProductScan(
      productName: cleanName,
      category: pending.category.name,
      imagePaths: List<String>.from(pending.imagePaths),
      ocrText: pending.combinedText,
      reportJson: report.toJson(),
      verdict: report.verdict.name,
      score: report.score,
      meanConfidence: pending.meanConfidence,
      regionCount: pending.regionSum,
    );
    final record = await OcrStore.instance.getProductScan(id);
    final stored = record ??
        ProductScanRecord(
          id: id,
          productName: cleanName,
          category: pending.category.name,
          imagePaths: List<String>.from(pending.imagePaths),
          ocrText: pending.combinedText,
          reportJson: report.toJson(),
          verdict: report.verdict.name,
          score: report.score,
          photoCount: pending.imagePaths.length,
          meanConfidence: pending.meanConfidence,
          regionCount: pending.regionSum,
          createdAt: DateTime.now(),
        );

    // TODO(BACKEND-D): enqueue server upload here (see library docs above).
    // Do NOT block the report screen on upload — fire-and-forget the queue.

    return ProductScanOutcome(
      record: stored,
      report: report,
      perPhotoTexts: pending.perPhotoTexts,
    );
  }

  /// One-shot scan (tests + legacy callers). Staged UI screens call
  /// [ocrPhotos] → [extractWithMode] → [checkAndSave] directly so the
  /// officer can review between stages.
  Future<ProductScanOutcome> runProductScan({
    required List<String> imagePaths,
    required String productName,
    ProductCategory category = ProductCategory.general,
    ExtractionMode mode = ExtractionMode.minilm,
    void Function(ScanStage stage)? onStage,
    void Function(int done, int total)? onPhotoProgress,
  }) async {
    assert(imagePaths.isNotEmpty, 'Need at least one photo per product.');
    onStage?.call(ScanStage.scanningPhotos);
    final ocr = await ocrPhotos(
        imagePaths: imagePaths, onPhotoProgress: onPhotoProgress);
    onStage?.call(ScanStage.extracting);
    // Yield so the step indicator repaints before the CPU work.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final pending = await extractWithMode(
      ocr: ocr,
      productName: productName,
      category: category,
      mode: mode,
    );
    return checkAndSave(pending, onStage: onStage);
  }

  static int _rank(FieldStatus s) => switch (s) {
        FieldStatus.found => 2,
        FieldStatus.unverified => 1,
        FieldStatus.notFound => 0,
      };

  /// Builds Option-B classifier votes for every OCR line in one batch.
  /// Returns null when the embedding model isn't ready — the caller then
  /// uses the regex/spatial-only extraction path (fully tested fallback).
  ///
  /// The whole vote step (warm-up + batched inference) is bounded by
  /// [_classifyBudget]: on-device inference is seconds, so a stall (slow
  /// first load, wedged isolate) degrades to regex-only instead of spinning
  /// the "Extracting…" indicator forever.
  static const Duration _classifyBudget = Duration(seconds: 60);

  static Future<LineLabelMap?> _classifyAllLines(
      List<PageLayout> layouts) async {
    try {
      return await _classifyAllLinesInner(layouts).timeout(_classifyBudget);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<LineLabelMap?> _classifyAllLinesInner(
      List<PageLayout> layouts) async {
    try {
      await MiniLMEmbedder.instance.warmUp();
      await _lineClassifier.warmUp();
      if (!_lineClassifier.isReady) return null;
      final allLines = <LayoutLine>[
        for (final layout in layouts) ...layout.lines,
      ];
      if (allLines.isEmpty) return null;
      final votes = await _lineClassifier
          .classify([for (final l in allLines) l.text]);
      if (votes.length != allLines.length) return null;
      return {for (var i = 0; i < allLines.length; i++) allLines[i]: votes[i]};
    } catch (_) {
      return null;
    }
  }

  /// Block-separated audit text (NOT extraction input — extraction works
  /// from tokens). Used for tax-phrase/MRP-mention/import-hint detection,
  /// CSV audit, and the report card's expandable section.
  static String _joinLayoutTexts(List<PageLayout> layouts) {
    if (layouts.length == 1) return layouts.first.debugText;
    final buf = StringBuffer();
    for (var i = 0; i < layouts.length; i++) {
      buf.writeln('===== PHOTO ${i + 1} =====');
      buf.writeln(layouts[i].debugText.trim());
      if (i < layouts.length - 1) buf.writeln();
    }
    return buf.toString().trim();
  }
}
