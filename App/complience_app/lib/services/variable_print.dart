/// Variable-print re-read branch for dot-matrix/inkjet declarations.
///
/// Problem: batch numbers, manufacturing/expiry dates and sometimes MRP are
/// printed inline at pack-out time as small dot-matrix text
/// (e.g. Smith & Jones: `BATCH NO.: PP6E110015`, `DATE OF MFG.: 11/05/26`,
/// `MRP ₹: 15`). The full-frame standard pass routinely misses or garbles
/// them, and the old pipeline then reported them as compliance FAILs.
///
/// Strategy (no new models, still offline):
/// 1. The main extractor yields UNVERIFIED/label-only observations WITH
///    label bounding boxes for these fields.
/// 2. Here each label box is expanded into a search rect (right + below the
///    label — where the variable value sits), mapped to pixels of the
///    ORIGINAL (un-preprocessed) photo, cropped, and re-OCR'd through 3
///    preprocessing variants (plain upscale / contrast / high-contrast).
/// 3. Strict field patterns pick the winner across variants; scoring is
///    pattern-strength × OCR confidence. Weak/absent output stays
///    UNVERIFIED — never fabricated, never FAIL.
///
/// Pure Dart except `package:image` (via `compute`) and the injected
/// [TokenRecognizer] (implemented by `OcrService.recognizePreparedTokens`,
/// keeping the plugin import out of this file for testability).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'field_extractor.dart';
import 'ocr_tokens.dart';

/// Injected crop recognizer (see `OcrService.recognizePreparedTokens`).
typedef TokenRecognizer = Future<List<OcrToken>> Function(
  Uint8List preparedBytes, {
  int maxSideLen,
  int photoIndex,
});

/// A variable field worth re-reading: search [rect] (normalized coords —
/// identical in prepared and original space since pre-processing scales
/// uniformly) on photo [photoIndex].
class VariableTarget {
  const VariableTarget({
    required this.field,
    required this.rect,
    required this.photoIndex,
  });

  /// One of: batch, mrp, mfg, exp.
  final String field;
  final NormalizedBox rect;
  final int photoIndex;
}

/// Builds re-read targets from UNVERIFIED label-only observations.
/// Returns at most one target per (field, photo).
List<VariableTarget> targetsFromProduct(
    ExtractedProduct product) {
  final out = <VariableTarget>[];
  for (final field in ['batch', 'mrp', 'mfg', 'exp']) {
    final o = product.obs(field);
    if (o.status != FieldStatus.unverified) continue;
    if (o.relationship != 'label_only' || o.bbox == null) continue;
    out.add(VariableTarget(
      field: field,
      rect: _searchRect(o.bbox!),
      photoIndex: o.photoIndex,
    ));
  }
  return out;
}

/// Search area: from the label's left edge to the frame's right edge,
/// slightly above the label to a few lines below (variable values sit
/// right-of or under the label — S&J has both on one row AND wrapped).
NormalizedBox _searchRect(NormalizedBox label) {
  var minX = (label.minX - 0.01).clamp(0.0, 1.0);
  var minY = (label.minY - 0.015).clamp(0.0, 1.0);
  var maxX = 1.0;
  var maxY = (label.maxY + 0.09).clamp(0.0, 1.0);
  if (maxX - minX < 0.12) {
    minX = (maxX - 0.12).clamp(0.0, 1.0);
  }
  if (maxY - minY < 0.04) {
    maxY = (minY + 0.04).clamp(0.0, 1.0);
  }
  return NormalizedBox(minX, minY, maxX, maxY);
}

/// Bottom-strip fallback rect: catches variable print whose LABEL itself
/// was unreadable (dates/batch usually live low on the pack).
NormalizedBox bottomStripRect() =>
    const NormalizedBox(0, 0.55, 1.0, 1.0);

// ---------------------------------------------------------------------------
// Crop variants (run in an isolate via compute)
// ---------------------------------------------------------------------------

enum _Variant { plain, contrast, highContrast }

class _CropJob {
  const _CropJob({
    required this.bytes,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.variant,
  });

  final Uint8List bytes;
  final int left;
  final int top;
  final int width;
  final int height;
  final _Variant variant;
}

Uint8List _cropEntry(_CropJob job) {
  try {
    final decoded = img.decodeImage(job.bytes);
    if (decoded == null) return Uint8List(0);
    final w = decoded.width;
    final h = decoded.height;
    final left = job.left.clamp(0, w - 1);
    final top = job.top.clamp(0, h - 1);
    final width = job.width.clamp(8, w - left);
    final height = job.height.clamp(8, h - top);
    var crop = img.copyCrop(decoded, x: left, y: top, width: width, height: height);
    // Cap final pixels: a half-photo bottom-strip at 4x upscale becomes
    // ~24MP and hangs/OOMs the native OCR (the "Extracting…" forever bug).
    // Keep final output <= ~1.6MP by shrinking the upscale factor.
    int upscaleFor(_Variant v) => v == _Variant.highContrast ? 4 : 3;
    var upscale = upscaleFor(job.variant);
    const maxOutPixels = 1600000;
    while (upscale > 1 &&
        crop.width * upscale * crop.height * upscale > maxOutPixels) {
      upscale--;
    }
    // Large strips: high-contrast 4x buys nothing over plain — downgrade
    // to plain to save one more heavy pass.
    var variant = job.variant;
    if ((job.variant == _Variant.highContrast) && upscale < 3) {
      variant = _Variant.plain;
    }
    switch (variant) {
      case _Variant.plain:
        if (upscale > 1) {
          crop = img.copyResize(crop,
              width: crop.width * upscale,
              height: crop.height * upscale,
              interpolation: img.Interpolation.cubic);
        }
      case _Variant.contrast:
        crop = img.grayscale(crop);
        crop = img.adjustColor(crop, contrast: 1.8);
        if (upscale > 1) {
          crop = img.copyResize(crop,
              width: crop.width * upscale,
              height: crop.height * upscale,
              interpolation: img.Interpolation.cubic);
        }
      case _Variant.highContrast:
        crop = img.grayscale(crop);
        crop = img.adjustColor(crop, contrast: 2.6, brightness: 0.08);
        crop = img.copyResize(crop,
            width: crop.width * upscale,
            height: crop.height * upscale,
            interpolation: img.Interpolation.cubic);
    }
    return Uint8List.fromList(img.encodeJpg(crop, quality: 95));
  } catch (_) {
    return Uint8List(0);
  }
}

Future<Uint8List> _prepareCrop(
  Uint8List original,
  NormalizedBox rect,
  int origW,
  int origH,
  _Variant variant,
) async {
  final left = (rect.minX * origW).round();
  final top = (rect.minY * origH).round();
  final width = ((rect.maxX - rect.minX) * origW).round();
  final height = ((rect.maxY - rect.minY) * origH).round();
  if (width < 8 || height < 8) return Uint8List(0);
  try {
    return await compute(
      _cropEntry,
      _CropJob(
          bytes: original,
          left: left,
          top: top,
          width: width,
          height: height,
          variant: variant),
    );
  } catch (_) {
    return Uint8List(0);
  }
}

// ---------------------------------------------------------------------------
// Strict variant-text parsers (stronger than full-frame: crops are tiny and
// single-purpose, but acceptance still needs pattern + confidence)
// ---------------------------------------------------------------------------

({String value, double strength, Map<String, Object?> data})?
    _parseCropText(String field, String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  switch (field) {
    case 'batch':
      for (final m in RegExp(r'\b([A-Z0-9][A-Z0-9\-/]{3,23})\b',
              caseSensitive: false)
          .allMatches(text)) {
        final cand = m.group(1)!;
        final low = cand.toLowerCase();
        if (low.contains('batch') ||
            low.contains('number') ||
            low == 'no' ||
            low == 'lot') {
          continue;
        }
        if (!RegExp(r'\d').hasMatch(cand)) continue;
        if (cand.contains(RegExp(r'[./]'))) continue;
        if (RegExp(r'^\d{8,}$').hasMatch(cand)) continue;
        final digits = RegExp(r'\d').allMatches(cand).length;
        final strength = digits >= 4 ? 0.95 : 0.75;
        return (
          value: cand,
          strength: strength,
          data: <String, Object?>{}
        );
      }
      return null;
    case 'mrp':
      final scrubbed =
          text.replaceAll(RegExp(r'\([^)]*(/|per)[^)]*\)'), ' ');
      final m = RegExp(
              r'(₹|Rs\.?|INR)?\s*(\d[\d,]*)(?:\.(\d{1,2}))?',
              caseSensitive: false)
          .firstMatch(scrubbed);
      if (m == null) return null;
      final num = (m.group(2) ?? '').replaceAll(',', '');
      if (RegExp(r'^\d{8,}$').hasMatch(num)) return null;
      final v = double.tryParse(
          m.group(3) != null ? '$num.${m.group(3)}' : num);
      if (v == null || v <= 0 || v > 1000000) return null;
      final hasCur = (m.group(1) ?? '').isNotEmpty;
      return (
        value: '₹${v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}',
        strength: hasCur ? 0.95 : 0.7,
        data: <String, Object?>{'value': v, 'raw': m.group(0)?.trim()}
      );
    case 'mfg':
    case 'exp':
      final cleaned = text
          .replaceAll(RegExp(r'\(.*'), '')
          .replaceAll(RegExp(r'[^0-9./\-A-Za-z ]'), ' ');
      final m = RegExp(
              r'\b(0?[1-9]|[12][0-9]|3[01])\s*[./\-]\s*(0?[1-9]|1[0-2])\s*[./\-]\s*(\d{2}|\d{4})\b')
          .firstMatch(cleaned);
      if (m == null) return null;
      final d = int.parse(m.group(1)!);
      final yRaw = int.parse(m.group(3)!);
      // Month range is guaranteed by the strict pattern above
      // ((0?[1-9]|1[0-2])); day + year still need sanity.
      final y = yRaw < 100 ? (yRaw <= 49 ? 2000 + yRaw : 1900 + yRaw) : yRaw;
      if (d < 1 || d > 31 || y < 1990 || y > 2045) return null;
      final fourDigit = m.group(3)!.length == 4;
      return (
        value: m.group(0)!,
        strength: fourDigit ? 0.95 : 0.8,
        data: <String, Object?>{}
      );
  }
  return null;
}

/// Re-reads [targets] from the ORIGINAL photo bytes.
///
/// [originals] maps photoIndex → original (un-preprocessed) file bytes;
/// [origSizes] maps photoIndex → (width, height) of those bytes.
/// Returns field → improved observation (only for targets that produced a
/// strong-enough candidate; everything else stays UNVERIFIED upstream).
Future<Map<String, FieldObservation>> rereadVariableFields({
  required Map<int, Uint8List> originals,
  required Map<int, (int, int)> origSizes,
  required List<VariableTarget> targets,
  required TokenRecognizer recognize,
  bool bottomStripFallback = true,
}) async {
  final out = <String, FieldObservation>{};
  final jobs = <VariableTarget>[...targets];
  if (bottomStripFallback) {
    // One strip job per photo that has any date/batch target — the label
    // itself may have been unreadable. Strict patterns only (see below).
    final photos = targets.map((t) => t.photoIndex).toSet();
    for (final p in photos) {
      for (final field in ['mfg', 'exp']) {
        if (out.containsKey('$field@$p')) continue;
        jobs.add(VariableTarget(
            field: field, rect: bottomStripRect(), photoIndex: p));
      }
    }
  }
  // Hard cap: without this, multi-photo + several UNVERIFIED fields fan out
  // to dozens of sequential native OCRs with no progress UI ("stuck at
  // Extracting…" for minutes). Small label-adjacent rects first; giant
  // bottom-strips last so the cap drops the expensive jobs first.
  jobs.sort((a, b) {
    double area(NormalizedBox r) =>
        (r.maxX - r.minX).abs() * (r.maxY - r.minY).abs();
    return area(a.rect).compareTo(area(b.rect));
  });
  const maxJobs = 4;
  final cappedJobs =
      jobs.length > maxJobs ? jobs.sublist(0, maxJobs) : jobs;

  for (final job in cappedJobs) {
    final original = originals[job.photoIndex];
    final size = origSizes[job.photoIndex];
    if (original == null || original.isEmpty || size == null) continue;
    if (size.$1 <= 0 || size.$2 <= 0) continue;

    var bestConf = -1.0;
    FieldObservation? best;
    for (final variant in _Variant.values) {
      Uint8List crop;
      try {
        crop = await _prepareCrop(
                original, job.rect, size.$1, size.$2, variant)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        continue;
      }
      if (crop.isEmpty) continue;
      // Skip pathological crops (still huge even after capped upscale).
      if (crop.lengthInBytes > 3500000) continue;
      List<OcrToken> tokens;
      try {
        tokens = await recognize(crop,
                maxSideLen: 1200, photoIndex: job.photoIndex)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // Timeout / native failure: skip variant, keep main-pass result.
        continue;
      }
      if (tokens.isEmpty) continue;
      final joined = tokens.map((t) => t.text).join(' ');
      final meanConf = tokens.map((t) => t.ocrConfidence).reduce((a, b) => a + b) /
          tokens.length;
      final parsed = _parseCropText(job.field, joined);
      if (parsed == null) continue;
      // Strip jobs are label-less: demand currency/4-digit strength.
      if (job.rect.minY >= 0.55 &&
          job.rect.minX == 0 &&
          parsed.strength < 0.9 &&
          job.field != 'batch') {
        continue;
      }
      final conf =
          (parsed.strength * (0.55 + 0.45 * meanConf.clamp(0, 1)) * 100)
                  .round() /
              100;
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: job.field,
          status: conf >= 0.7
              ? FieldStatus.found
              : FieldStatus.unverified,
          value: parsed.value,
          data: parsed.data,
          ocrConfidence: meanConf,
          fieldConfidence: conf,
          evidenceText:
              '"${joined.length > 80 ? '${joined.substring(0, 80)}…' : joined}" (${variant.name})',
          relationship: 'variable_crop',
          bbox: job.rect,
          photoIndex: job.photoIndex,
          method: ExtractMethod.variablePrintPipeline,
          note: conf >= 0.7
              ? 'Re-read from dot-matrix re-scan (${variant.name}).'
              : 'Weak re-read candidate — needs a closer photo.',
        );
      }
    }
    final key = '${job.field}@${job.photoIndex}';
    if (best != null && !out.containsKey(job.field)) {
      out[job.field] = best;
    } else if (best != null && best.fieldConfidence > (out[job.field]?.fieldConfidence ?? -1)) {
      out[job.field] = best;
    }
    out.putIfAbsent(key, () => best ?? FieldObservation.missing(job.field));
  }

  // Return only real improvements keyed by field.
  final result = <String, FieldObservation>{};
  out.forEach((k, v) {
    if (!k.contains('@') && v.status != FieldStatus.notFound) {
      result[k] = v;
    }
  });
  return result;
}
