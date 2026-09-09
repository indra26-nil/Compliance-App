/// OCR token model — the geometry-preserving alternative to flat text.
///
/// The old pipeline called `OcrPostprocess.buildCleanText()` immediately and
/// passed only a `String` downstream, discarding every bounding box. That is
/// what caused cross-line gluing ("USE BY…" + "BRAND OWNED…" in one
/// manufacturer block, phone+email fused into one token) and made
/// label→value association impossible.
///
/// New contract: OCR output travels as [OcrToken]s (text + confidence +
/// pixel box + photo index) until layout reconstruction ([ocr_layout.dart])
/// and field extraction ([field_extractor.dart]) are done. Flat text is only
/// derived *per block/line* for regex work, never as one giant string.
///
/// Pure Dart — no Flutter/plugin imports — so `flutter test` (and plain
/// `dart test`) can exercise the whole extraction stack with fixtures.
library;

/// Axis-aligned box in pixels of the *recognized* image (i.e. the
/// pre-processed bytes handed to the OCR engine). Recognized-space is
/// self-consistent for layout; use [NormalizedBox] for anything that must
/// survive across different photo sizes.
class PixelBox {
  const PixelBox(this.minX, this.minY, this.maxX, this.maxY);

  /// Builds from a detector quad (usually 4 points, any winding/order).
  factory PixelBox.fromQuad(List<Point> quad) {
    if (quad.isEmpty) return const PixelBox(0, 0, 0, 0);
    var minX = quad.first.x;
    var maxX = quad.first.x;
    var minY = quad.first.y;
    var maxY = quad.first.y;
    for (final p in quad.skip(1)) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    return PixelBox(minX, minY, maxX, maxY);
  }

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  double get width => (maxX - minX) < 0 ? 0 : (maxX - minX);
  double get height => (maxY - minY) < 0 ? 0 : (maxY - minY);
  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
  double get area => width * height;

  NormalizedBox normalize(double imgW, double imgH) {
    if (imgW <= 0 || imgH <= 0) {
      return const NormalizedBox(0, 0, 0, 0);
    }
    return NormalizedBox(
      minX / imgW,
      minY / imgH,
      maxX / imgW,
      maxY / imgH,
    );
  }

  /// Horizontal overlap as a fraction of the narrower box (0..1).
  double hOverlapFraction(PixelBox other) {
    final overlap = (maxX < other.maxX ? maxX : other.maxX) -
        (minX > other.minX ? minX : other.minX);
    if (overlap <= 0) return 0;
    final denom = width < other.width ? width : other.width;
    if (denom <= 0) return 0;
    return overlap / denom;
  }

  Map<String, Object?> toJson() => {
        'x1': minX,
        'y1': minY,
        'x2': maxX,
        'y2': maxY,
      };
}

/// Minimal 2D point (avoids `dart:ui` so this file stays pure Dart).
class Point {
  const Point(this.x, this.y);
  final double x;
  final double y;
}

/// Box in 0..1 image coordinates — independent of photo resolution and of
/// whether the image was downscaled before recognition.
class NormalizedBox {
  const NormalizedBox(this.minX, this.minY, this.maxX, this.maxY);

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  double get width => (maxX - minX).clamp(0.0, 1.0);
  double get height => (maxY - minY).clamp(0.0, 1.0);
  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;

  /// Gap between this box's right edge and [other]'s left edge, in widths.
  double gapRightOf(NormalizedBox other) => minX - other.maxX;

  Map<String, Object?> toJson() => {
        'x1': minX,
        'y1': minY,
        'x2': maxX,
        'y2': maxY,
      };

  factory NormalizedBox.fromJson(Map<String, Object?> json) =>
      NormalizedBox(
        (json['x1'] as num?)?.toDouble() ?? 0,
        (json['y1'] as num?)?.toDouble() ?? 0,
        (json['x2'] as num?)?.toDouble() ?? 0,
        (json['y2'] as num?)?.toDouble() ?? 0,
      );
}

/// One OCR text region with its geometry.
///
/// * [text] — raw recognized string (NOT cleaned/glued).
/// * [ocrConfidence] — recognizer confidence 0..1. This is *not* field
///   confidence: 0.95 sure the glyphs read "1001208300010" says nothing
///   about whether that number is an MRP.
/// * [box] — pixel box in recognized-image space.
/// * [photoIndex] — which photo of the multi-photo product this came from.
class OcrToken {
  const OcrToken({
    required this.text,
    required this.ocrConfidence,
    required this.box,
    this.photoIndex = 0,
  });

  final String text;
  final double ocrConfidence;
  final PixelBox box;
  final int photoIndex;

  String get trimmed => text.trim();
  bool get isEmpty => trimmed.isEmpty;

  NormalizedBox normalized(double imgW, double imgH) =>
      box.normalize(imgW, imgH);
}
