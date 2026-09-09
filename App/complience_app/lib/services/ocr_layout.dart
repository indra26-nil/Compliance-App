/// Layout reconstruction: tokens → lines → blocks (pure Dart).
///
/// Fixes Problem 7 (cross-section line merging) at its root. The old
/// post-processor grouped regions by raw y-proximity only, so on a tilted
/// photo "USE BY: 10.05.27…" and "BRAND OWNED & MARKETED BY…" collapsed into
/// one manufacturer blob. Here grouping uses *normalized* coordinates plus
/// block separation, and line identity is preserved end-to-end so phone and
/// email on adjacent lines can never fuse (Problem 8).
///
/// Output:
/// * [LayoutLine] — tokens sharing a visual row, left-to-right.
/// * [LayoutBlock] — adjacent lines forming one declaration section, with a
///   [BlockHint] guessed from label keywords (identity, ingredients,
///   nutrition, manufacturer, care, variable, barcode, unknown).
/// * [PageLayout] — lines + blocks for one photo, with image size for
///   normalization.
///
/// Thresholds are fractions of image height/width (plus median glyph height),
/// never absolute pixels, so different photo resolutions behave the same.
library;

import 'ocr_tokens.dart';

/// Rough section guess for a block, used to route extraction
/// (e.g. never take a product name out of an ingredients block).
enum BlockHint {
  identity,
  ingredients,
  nutrition,
  manufacturer,
  consumerCare,
  variable,
  barcode,
  unknown,
}

/// One visual row of tokens, left-to-right.
class LayoutLine {
  LayoutLine(this.tokens, this.imgW, this.imgH);

  final List<OcrToken> tokens;
  final double imgW;
  final double imgH;

  late final PixelBox box = _union(tokens.map((t) => t.box).toList());
  late final NormalizedBox nbox = box.normalize(imgW, imgH);

  /// Line text joined with single spaces — the ONLY place tokens are joined,
  /// and only within a true visual row.
  late final String text =
      tokens.map((t) => t.trimmed).where((s) => s.isNotEmpty).join(' ');

  double get meanConfidence => tokens.isEmpty
      ? 0
      : tokens.map((t) => t.ocrConfidence).reduce((a, b) => a + b) /
          tokens.length;
}

/// Adjacent lines forming one declaration section.
class LayoutBlock {
  LayoutBlock(this.lines, this.imgW, this.imgH, this.hint);

  final List<LayoutLine> lines;
  final double imgW;
  final double imgH;
  final BlockHint hint;

  late final PixelBox box = _union(lines.map((l) => l.box).toList());
  late final NormalizedBox nbox = box.normalize(imgW, imgH);

  late final String text = lines.map((l) => l.text).join('\n');
}

/// Full layout for one photo.
class PageLayout {
  PageLayout({
    required this.lines,
    required this.blocks,
    required this.imgW,
    required this.imgH,
    required this.photoIndex,
  });

  final List<LayoutLine> lines;
  final List<LayoutBlock> blocks;
  final double imgW;
  final double imgH;
  final int photoIndex;

  /// All raw text, block-separated (debug/audit only — NOT extraction input).
  String get debugText => blocks.map((b) => b.text).join('\n\n');

  int get tokenCount =>
      lines.fold(0, (sum, line) => sum + line.tokens.length);
}

/// Groups [tokens] (one photo) into lines then blocks.
///
/// Drops pure-speckle tokens (tiny boxes that are pure punctuation) the same
/// way the old filter did, but keeps everything else with geometry intact.
PageLayout buildLayout(
  List<OcrToken> tokens, {
  required double imgW,
  required double imgH,
  int photoIndex = 0,
}) {
  final kept = tokens.where((t) {
    final s = t.trimmed;
    if (s.isEmpty) return false;
    // Speckle: sub-6px boxes (in recognized space) that are pure punctuation.
    if (t.box.width < 6 || t.box.height < 6) {
      if (RegExp(r'''^['"`‘’“”.,;:|!*_~^+\-=–—/\\()\[\]{}<>]+$''')
          .hasMatch(s)) {
        return false;
      }
    }
    return true;
  }).toList();

  if (kept.isEmpty || imgW <= 0 || imgH <= 0) {
    return PageLayout(
        lines: [], blocks: [], imgW: imgW, imgH: imgH, photoIndex: photoIndex);
  }

  kept.sort((a, b) => a.box.centerY.compareTo(b.box.centerY));

  final heights = kept.map((t) => t.box.height).toList()..sort();
  final medianH = heights[heights.length ~/ 2].clamp(8.0, 80.0);
  // Normalized line tolerance: glyph-relative, resolution independent.
  final lineTol = (medianH * 0.6).clamp(8.0, imgH * 0.05);

  // ---- lines: single sweep over y-sorted tokens ----
  final lines = <LayoutLine>[];
  final lineCy = <double>[];
  for (final token in kept) {
    var placed = false;
    for (var i = 0; i < lines.length; i++) {
      if ((token.box.centerY - lineCy[i]).abs() < lineTol) {
        lines[i].tokens.add(token);
        final n = lines[i].tokens.length;
        lineCy[i] = (lineCy[i] * (n - 1) + token.box.centerY) / n;
        placed = true;
        break;
      }
    }
    if (!placed) {
      lines.add(LayoutLine([token], imgW, imgH));
      lineCy.add(token.box.centerY);
    }
  }
  // Order lines top-to-bottom, tokens left-to-right.
  final order = List<int>.generate(lines.length, (i) => i)
    ..sort((a, b) => lineCy[a].compareTo(lineCy[b]));
  final ordered = [for (final i in order) lines[i]];
  for (final line in ordered) {
    line.tokens.sort((a, b) => a.box.minX.compareTo(b.box.minX));
  }

  // ---- blocks: split on large vertical gaps or horizontal disjointness ----
  final blocks = <LayoutBlock>[];
  var current = <LayoutLine>[ordered.first];
  for (var i = 1; i < ordered.length; i++) {
    final prev = ordered[i - 1];
    final cur = ordered[i];
    final gap = cur.box.minY - prev.box.maxY;
    final gapTol = (medianH * 1.6).clamp(10.0, imgH * 0.08);
    final overlaps = cur.box.hOverlapFraction(prev.box) > 0.15;
    if (gap > gapTol || !overlaps) {
      blocks.add(_makeBlock(current, imgW, imgH));
      current = [cur];
    } else {
      current.add(cur);
    }
  }
  blocks.add(_makeBlock(current, imgW, imgH));

  return PageLayout(
      lines: ordered,
      blocks: blocks,
      imgW: imgW,
      imgH: imgH,
      photoIndex: photoIndex);
}

LayoutBlock _makeBlock(List<LayoutLine> lines, double imgW, double imgH) {
  final text = lines.map((l) => l.text).join('\n').toLowerCase();
  BlockHint hint = BlockHint.unknown;
  if (RegExp(r'ingred').hasMatch(text)) {
    hint = BlockHint.ingredients;
  } else if (RegExp(r'nutrition|per 100 ?g|kcal|protein').hasMatch(text)) {
    hint = BlockHint.nutrition;
  } else if (RegExp(
          r'manufactured|marketed|packed|imported|mfd |mkt |brand owned')
      .hasMatch(text)) {
    hint = BlockHint.manufacturer;
  } else if (RegExp(
          r'consumer care|customer care|complaint|helpline|toll free|customercare')
      .hasMatch(text)) {
    hint = BlockHint.consumerCare;
  } else if (RegExp(
          r'batch|lot no|date of mfg|use by|best before|\bmrp\b|maximum retail')
      .hasMatch(text)) {
    hint = BlockHint.variable;
  } else if (RegExp(r'^\s*[\d ]{8,}\s*$').hasMatch(text) &&
      lines.length <= 2) {
    hint = BlockHint.barcode;
  } else if (lines.first.box.minY / (imgH <= 0 ? 1 : imgH) < 0.35) {
    hint = BlockHint.identity;
  }
  return LayoutBlock(lines, imgW, imgH, hint);
}

PixelBox _union(List<PixelBox> boxes) {
  if (boxes.isEmpty) return const PixelBox(0, 0, 0, 0);
  var minX = boxes.first.minX;
  var minY = boxes.first.minY;
  var maxX = boxes.first.maxX;
  var maxY = boxes.first.maxY;
  for (final b in boxes.skip(1)) {
    if (b.minX < minX) minX = b.minX;
    if (b.minY < minY) minY = b.minY;
    if (b.maxX > maxX) maxX = b.maxX;
    if (b.maxY > maxY) maxY = b.maxY;
  }
  return PixelBox(minX, minY, maxX, maxY);
}
