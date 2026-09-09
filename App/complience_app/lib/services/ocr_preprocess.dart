import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Pre-processing tuned for packaged-food label photos (nutrition tables,
/// ingredient lists, MRP / net-qty / FSSAI blocks use 6-9pt print).
///
/// What it does:
///  * bakes EXIF orientation so text is upright for the detector,
///  * applies a 2x upscale to small/mid-size shots so tiny fonts survive
///    (capped so output never exceeds [largeSideCap] on the long side or
///    [maxPixels] total — the native `maxSideLen` (default 2560) discards
///    anything bigger anyway, so uncapped upscaling would only burn memory),
///  * re-encodes at high JPEG quality to avoid the ringing that the recogniser
///    reads as stray `'` / `"` characters.
///
/// Returns bytes ready for [PaddleOcr.recognize]. Falls back to the input on
/// any failure so OCR can still proceed.
///
/// NOTE: this runs the CPU-heavy decode/resize/encode on the calling isolate.
/// For calls from the UI thread prefer [prepareLabelImageBytesBackground],
/// which runs the same work via `compute` so the route transition + loading
/// screen can paint instead of freezing.
Future<Uint8List> prepareLabelImageBytes(
  Uint8List raw, {
  int largeSideCap = 3200,
  double upscaleFactor = 2.0,
  int upscaleBelow = 2400,
  int maxPixels = 12000000,
}) async {
  try {
    return _prepareSync(
      raw,
      largeSideCap: largeSideCap,
      upscaleFactor: upscaleFactor,
      upscaleBelow: upscaleBelow,
      maxPixels: maxPixels,
    );
  } catch (_) {
    return raw;
  }
}

/// Same as [prepareLabelImageBytes] but runs the heavy pixel work on a
/// background isolate. Falls back to the input bytes on any failure so OCR
/// can still proceed.
Future<Uint8List> prepareLabelImageBytesBackground(
  Uint8List raw, {
  int largeSideCap = 3200,
  double upscaleFactor = 2.0,
  int upscaleBelow = 2400,
  int maxPixels = 12000000,
}) async {
  try {
    return await compute(
      _preprocessEntry,
      _PreprocessArgs(
        raw: raw,
        largeSideCap: largeSideCap,
        upscaleFactor: upscaleFactor,
        upscaleBelow: upscaleBelow,
        maxPixels: maxPixels,
      ),
    );
  } catch (_) {
    // compute can fail on very low-memory devices — fall back to inline
    // (may jank one frame) rather than failing the whole scan.
    try {
      return _prepareSync(
        raw,
        largeSideCap: largeSideCap,
        upscaleFactor: upscaleFactor,
        upscaleBelow: upscaleBelow,
        maxPixels: maxPixels,
      );
    } catch (_) {
      return raw;
    }
  }
}

/// Args holder for the `compute` entrypoint (compute takes a single arg).
@immutable
class _PreprocessArgs {
  const _PreprocessArgs({
    required this.raw,
    required this.largeSideCap,
    required this.upscaleFactor,
    required this.upscaleBelow,
    required this.maxPixels,
  });

  final Uint8List raw;
  final int largeSideCap;
  final double upscaleFactor;
  final int upscaleBelow;
  final int maxPixels;
}

/// Top-level entry for `compute` — must stay top-level (no closures).
Uint8List _preprocessEntry(_PreprocessArgs args) {  try {
    return _prepareSync(
      args.raw,
      largeSideCap: args.largeSideCap,
      upscaleFactor: args.upscaleFactor,
      upscaleBelow: args.upscaleBelow,
      maxPixels: args.maxPixels,
    );
  } catch (_) {
    return args.raw;
  }
}

/// Synchronous core: decode → EXIF fix → resize → high-quality re-encode.
Uint8List _prepareSync(
  Uint8List raw, {
  required int largeSideCap,
  required double upscaleFactor,
  required int upscaleBelow,
  required int maxPixels,
}) {
  try {
    final decoded = img.decodeImage(raw);
    if (decoded == null) return raw;

    // Correct rotation / mirroring from EXIF (curved packets are often shot
    // slightly tilted; upside EXIF flags destroy line structure).
    img.Image oriented;
    try {
      oriented = img.bakeOrientation(decoded);
    } catch (_) {
      oriented = decoded;
    }

    final w = oriented.width;
    final h = oriented.height;
    if (w <= 0 || h <= 0) return raw;
    final maxSide = max(w, h);

    img.Image out = oriented;
    if (maxSide > largeSideCap) {
      final scale = largeSideCap / maxSide;
      out = img.copyResize(
        oriented,
        width: (w * scale).round(),
        height: (h * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    } else if (maxSide < upscaleBelow) {
      // 2x upscale for tiny fonts: 6pt nutrition print at ~5px x-height is
      // unreadable; doubled, the detector sees real glyph structure. Caps
      // keep memory bounded on low-end devices.
      var scale = upscaleFactor;
      scale = min(scale, largeSideCap / maxSide);
      scale = min(scale, sqrt(maxPixels / (w * h)));
      if (scale > 1.05) {
        out = img.copyResize(
          oriented,
          width: (w * scale).round(),
          height: (h * scale).round(),
          interpolation: img.Interpolation.cubic,
        );
      }
    }

    // High-quality re-encode. Quality 95 keeps table grid + glyph edges crisp;
    // the old image_picker quality=85 added ringing that PP-OCR read as `'`.
    final encoded = img.encodeJpg(out, quality: 95);
    if (encoded.isEmpty) return raw;
    return Uint8List.fromList(encoded);
  } catch (_) {
    return raw;
  }
}

/// Image dimensions without full processing (background isolate).
///
/// Used to map normalized label boxes back to pixel crops for the
/// variable-print re-read pass, and to normalize OCR token geometry.
/// Returns (0, 0) on failure — callers treat that as "geometry unknown".
Future<(int, int)> imageBounds(Uint8List bytes) async {
  try {
    return await compute(_boundsEntry, bytes);
  } catch (_) {
    return (0, 0);
  }
}

/// Top-level entry for `compute` — must stay top-level (no closures).
(int, int) _boundsEntry(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return (0, 0);
    return (decoded.width, decoded.height);
  } catch (_) {
    return (0, 0);
  }
}
