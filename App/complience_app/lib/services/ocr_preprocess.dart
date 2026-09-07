import 'dart:math';
import 'dart:typed_data';

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
Future<Uint8List> prepareLabelImageBytes(
  Uint8List raw, {
  int largeSideCap = 3200,
  double upscaleFactor = 2.0,
  int upscaleBelow = 2400,
  int maxPixels = 12000000,
}) async {
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
