import 'dart:math';
import 'dart:ui';

import 'package:flutter_paddle_ocr_v5/flutter_paddle_ocr_v5.dart';

/// Post-processing for packaged-food label OCR.
///
/// Fixes the failure modes seen on dense labels (Lay's back panel,
/// nutrition tables, ingredient blocks):
///  1. stray `'`/`"` speckle from table gridlines + JPEG ringing,
///  2. char-level box fragmentation (`'1''0''0'` instead of `100`),
///  3. scrambled reading order (native returns score order, not top-down),
///  4. missing whitespace / glued tokens (`ADVICE:Contains`, `80g`, `5 %`),
///  5. hyphenated line wraps in ingredient lists (`Maltodex-` + `trin`),
///  6. duplicate overlapping detections of the same line.
///
/// Spell correction against the food-label vocabulary is on by default and
/// can be disabled per call ([buildCleanText] `useLexicon: false`) for
/// non-food packages or raw-text debugging.
class OcrPostprocess {
  /// Hard confidence floor: anything below 0.5 is discarded. Short nutrition
  /// tokens (`5%`, `6.7 g`) still pass when genuinely recognised — PP-OCR
  /// scores clean glyphs well above this; the quote-noise fragments that
  /// plagued the old output sit below it.
  static const double minConfidence = 0.5;

  static final RegExp _purePunct = RegExp(
    r'''^['"`‘’“”.,;:|!*_~^+\-=–—/\\()\[\]{}<>]+$''',
  );

  /// Exact (case-insensitive) fixes for recurrent PP-OCR misreads on Indian
  /// packaged-food labels. Applied before edit-distance snapping so short
  /// tokens like `Mak` can still be rescued in context.
  static const Map<String, String> _exactFixes = {
    'sodum': 'Sodium',
    'sodiumb': 'Sodium',
    'falb': 'Fat',
    'fal': 'Fat',
    'fines': 'FINES',
    'sugas': 'Sugars',
    'sugrs': 'Sugars',
    'sagaswb': 'Sugars',
    'sugrswb': 'Sugars',
    'sagr': 'Sugar',
    'protoin': 'Protein',
    'protien': 'Protein',
    'enengy': 'Energy',
    'enegy': 'Energy',
    'carbohyrate': 'Carbohydrate',
    'carbohydrats': 'Carbohydrate',
    'kcd': 'kcal',
    'kacl': 'kcal',
    'kcad': 'kcal',
    'saturaded': 'Saturated',
    'saturatedf': 'Saturated Fat',
    'transfatb': 'Trans Fat',
    'ntients': 'Nutrients',
    'nutriant': 'Nutrient',
    'rdaperse': 'RDA Per Serve',
    'rdapersee': 'RDA Per Serve',
    'servese': 'Serve Size',
    'servese2wb': 'Serve Size',
    'nutritionalinformation': 'NUTRITIONAL INFORMATION',
    'allergena dvice': 'ALLERGEN ADVICE',
    'allergenadvice': 'ALLERGEN ADVICE',
    'contans': 'Contains',
    'contanssoy': 'Contains Soy',
    'mak': 'Milk',
    'vogetableoi': 'Vegetable Oil',
    'vogetable': 'Vegetable',
    'eosble': 'Edible',
    'ldioedsat': 'Iodised Salt',
    'maltodedin': 'Maltodextrin',
    'ingredIents': 'INGREDIENTS',
    'ingrediants': 'INGREDIENTS',
    'netqty': 'NET QTY',
    'servingperpack': 'Servings per pack',
    'mfg': 'Mfg.',
    'exp': 'Exp.',
    'cholestrol': 'Cholesterol',
    'cholesteroi': 'Cholesterol',
    'fibra': 'Fibre',
    'vitamln': 'Vitamin',
    'vitamins': 'Vitamins',
    'calcum': 'Calcium',
    'potasslum': 'Potassium',
    'niacln': 'Niacin',
    'riboflavln': 'Riboflavin',
    'thiamln': 'Thiamine',
    'presarvative': 'Preservative',
    'emulsifler': 'Emulsifier',
    'stablizer': 'Stabilizer',
    'antioxidant': 'Antioxidant',
    'reguiator': 'Regulator',
    'palmolein': 'Palmolein',
    'lic': 'Lic.',
    'fssai': 'FSSAI',
    'wheat': 'Wheat',
    'gluten': 'Gluten',
    'peanut': 'Peanut',
    'mustard': 'Mustard',
    'sesame': 'Sesame',
  };

  /// Canonical vocabulary for edit-distance snapping (FSSAI / packaged-food
  /// compliance terms + nutrition rows). Only applied to words with length
  /// >= 6 to avoid mangling numbers and units.
  static const List<String> _vocab = [
    'INGREDIENTS',
    'NUTRITIONAL',
    'INFORMATION',
    'Energy',
    'Protein',
    'Carbohydrate',
    'Sugars',
    'Added',
    'Total',
    'Fat',
    'Saturated',
    'Trans',
    'Sodium',
    'Nutrients',
    'Serve',
    'Size',
    'Servings',
    'Contains',
    'Allergen',
    'Advice',
    'Vegetable',
    'Edible',
    'Potato',
    'Chips',
    'Proprietary',
    'Food',
    'Manufacturing',
    'Consumer',
    'Feedback',
    'Batch',
    'Gurugram',
    'Haryana',
    'India',
    'PepsiCo',
    'Hydrolysed',
    'Maltodextrin',
    'Flavour',
    'Seasoning',
    'Condiments',
    'Cheese',
    'Powder',
    'Consumption',
    // Extended nutrients.
    'Cholesterol',
    'Fibre',
    'Calcium',
    'Iron',
    'Potassium',
    'Magnesium',
    'Zinc',
    'Vitamin',
    'Vitamins',
    'Niacin',
    'Riboflavin',
    'Thiamine',
    // FSSAI / pack compliance.
    'FSSAI',
    'Lic',
    'MRP',
    'Inclusive',
    'Taxes',
    'Quantity',
    'Weight',
    'Expiry',
    'Date',
    'Month',
    'Year',
    'Customer',
    'Care',
    'Address',
    'Marketed',
    'Manufactured',
    'Packed',
    // Allergens.
    'Milk',
    'Soy',
    'Wheat',
    'Gluten',
    'Peanut',
    'Mustard',
    'Sesame',
    'Sulphite',
    'Lactose',
    'Casein',
    'Whey',
    // Common ingredients / additives.
    'Sugar',
    'Salt',
    'Palm',
    'Palmolein',
    'Rice',
    'Bran',
    'Corn',
    'Maize',
    'Starch',
    'Spices',
    'Acidity',
    'Regulator',
    'Emulsifier',
    'Stabilizer',
    'Preservative',
    'Antioxidant',
    'Colour',
    'Dextrose',
    'Fructose',
    'Cocoa',
    'Yeast',
    'Onion',
    'Garlic',
    'Tomato',
  ];

  /// Full pipeline: filter noise -> reading-order sort.
  /// Returns the kept regions in read order.
  static List<OcrResult> filterAndSort(List<OcrResult> input) {
    final kept = input.where(_keep).toList(growable: false);
    if (kept.isEmpty) return const [];
    return _sortReadingOrder(kept);
  }

  /// Cleans one OCR line for the review screen ("Auto-clean" action):
  /// same token cleaner + line fixer the display text uses, so what the
  /// officer approves is what extraction will see.
  static String cleanLine(String line, {bool useLexicon = true}) =>
      _fixLine(cleanToken(line), useLexicon: useLexicon);

  /// Builds the final multi-line text from already sorted regions.
  /// Set [useLexicon] to false to skip food-vocabulary spell correction.
  static String buildCleanText(List<OcrResult> sortedKept,
      {bool useLexicon = true}) {    if (sortedKept.isEmpty) return '';
    final lines = _groupLines(sortedKept);
    final out = <String>[];
    for (final line in lines) {
      final joined = _joinLine(line);
      if (joined.trim().isEmpty) continue;
      out.add(_fixLine(joined, useLexicon: useLexicon));
    }
    return _mergeHyphenWraps(out).join('\n').trim();
  }

  /// Merges hyphenated line wraps from ingredient paragraphs:
  /// `Maltodex-` + `trin` -> `Maltodextrin`. Only merges when the next line
  /// starts with a lowercase letter, so uppercase table rows and new
  /// sentences are never glued.
  static List<String> _mergeHyphenWraps(List<String> lines) {
    final merged = <String>[];
    for (final line in lines) {
      if (merged.isNotEmpty &&
          merged.last.endsWith('-') &&
          line.isNotEmpty &&
          RegExp(r'^[a-z]').hasMatch(line)) {
        merged[merged.length - 1] =
            merged.last.substring(0, merged.last.length - 1) + line;
      } else {
        merged.add(line);
      }
    }
    return merged;
  }

  /// Mean recognition confidence of kept regions (0 if empty).
  static double meanConfidence(List<OcrResult> kept) {
    if (kept.isEmpty) return 0;
    var sum = 0.0;
    for (final r in kept) {
      sum += r.confidence;
    }
    return sum / kept.length;
  }

  // ---------------------------------------------------------------- filter

  static bool _keep(OcrResult r) {
    final raw = r.text.trim();
    if (raw.isEmpty) return false;
    if (r.points.isEmpty) return raw.length >= 2;

    final box = _Box.fromPoints(r.points);
    // Specks / gridline slivers the DB detector fires on at low thresholds.
    if (box.width < 6 || box.height < 6) return false;

    final cleanedProbe = _stripQuotes(raw).trim();
    if (cleanedProbe.isEmpty) return false;
    if (_purePunct.hasMatch(raw) || _purePunct.hasMatch(cleanedProbe)) {
      return false;
    }

    // Hard floor: drops low-confidence gridline/JPEG speckle.
    if (r.confidence < minConfidence) return false;
    return true;
  }

  // ------------------------------------------------------------------ sort

  static List<OcrResult> _sortReadingOrder(List<OcrResult> input) {
    final items = input.map((r) => _Item(r, _Box.fromPoints(r.points))).toList();
    items.sort((a, b) => a.box.centerY.compareTo(b.box.centerY));

    final heights = items.map((e) => e.box.height).toList()..sort();
    final medianH = heights[heights.length ~/ 2].clamp(8.0, 80.0);
    final lineTol = max(medianH * 0.6, 8.0);

    final lines = <List<_Item>>[];
    final lineCy = <double>[];
    for (final item in items) {
      var placed = false;
      for (var i = 0; i < lines.length; i++) {
        if ((item.box.centerY - lineCy[i]).abs() < lineTol) {
          lines[i].add(item);
          lineCy[i] = (lineCy[i] * (lines[i].length - 1) + item.box.centerY) /
              lines[i].length;
          placed = true;
          break;
        }
      }
      if (!placed) {
        lines.add([item]);
        lineCy.add(item.box.centerY);
      }
    }

    // Order lines top-to-bottom, tokens left-to-right inside each line.
    final order = List<int>.generate(lines.length, (i) => i)
      ..sort((a, b) => lineCy[a].compareTo(lineCy[b]));
    final out = <OcrResult>[];
    for (final i in order) {
      final line = lines[i];
      line.sort((a, b) => a.box.minX.compareTo(b.box.minX));
      for (final it in line) {
        out.add(it.result);
      }
    }
    return out;
  }

  static List<List<_Item>> _groupLines(List<OcrResult> sorted) {
    final items = sorted.map((r) => _Item(r, _Box.fromPoints(r.points))).toList();
    if (items.isEmpty) return const [];
    final heights = items.map((e) => e.box.height).toList()..sort();
    final medianH = heights[heights.length ~/ 2].clamp(8.0, 80.0);
    final lineTol = max(medianH * 0.6, 8.0);

    // Items arrive y-sorted from _sortReadingOrder, so a single sweep groups.
    final lines = <List<_Item>>[];
    lines.add(<_Item>[]);
    var cy = items.first.box.centerY;
    for (final item in items) {
      final cur = lines.last;
      if (cur.isEmpty || (item.box.centerY - cy).abs() < lineTol) {
        cur.add(item);
        cy = cur.map((e) => e.box.centerY).reduce((a, b) => a + b) / cur.length;
      } else {
        lines.add([item]);
        cy = item.box.centerY;
      }
    }
    return lines;
  }

  // ------------------------------------------------------------------ join

  /// Joins one visual line (one nutrition-table row or label line).
  /// Digit fragments with tiny gaps (`1`+`0`+`0`) merge without spaces;
  /// everything else gets a normal word space so table rows read
  /// `Energy 537 kcal 5%`. Overlapping duplicate detections of the same
  /// glyphs are dropped in favour of the higher-confidence box.
  static String _joinLine(List<_Item> line) {
    line.sort((a, b) => a.box.minX.compareTo(b.box.minX));
    final tokens = <String>[];
    final boxes = <_Box>[];
    final confs = <double>[];
    for (final it in line) {
      final t = cleanToken(it.result.text);
      if (t.isEmpty) continue;
      // Skip tokens that became pure punctuation after cleaning.
      if (_purePunct.hasMatch(t)) continue;
      // Duplicate detection: same text, heavily overlapping box — keep the
      // higher-confidence one.
      if (tokens.isNotEmpty &&
          t.toLowerCase() == tokens.last.toLowerCase() &&
          _hOverlapFraction(boxes.last, it.box) > 0.5) {
        if (it.result.confidence > confs.last) {
          tokens[tokens.length - 1] = t;
          boxes[boxes.length - 1] = it.box;
          confs[confs.length - 1] = it.result.confidence;
        }
        continue;
      }
      tokens.add(t);
      boxes.add(it.box);
      confs.add(it.result.confidence);
    }
    if (tokens.isEmpty) return '';
    final sb = StringBuffer(tokens.first);
    for (var i = 1; i < tokens.length; i++) {
      final prev = tokens[i - 1];
      final cur = tokens[i];
      final gap = boxes[i].minX - boxes[i - 1].maxX;
      final prevW = boxes[i - 1].width / max(prev.length, 1);
      final curW = boxes[i].width / max(cur.length, 1);
      final charW = max(max(prevW, curW), 4.0);
      final bothNumeric =
          RegExp(r'^[\d.,%]+$').hasMatch(prev) && RegExp(r'^[\d.,%]+$').hasMatch(cur);
      final tinyGap = gap < charW * 0.45;
      if (bothNumeric && tinyGap) {
        sb.write(cur); // 1+0+0 -> 100, 33+.+1 -> 33.1 (spaced dots fixed later)
      } else if (tinyGap &&
          prev.length <= 2 &&
          cur.length <= 2 &&
          RegExp(r'^[A-Za-z0-9%]+$').hasMatch(prev + cur)) {
        sb.write(cur);
      } else {
        sb.write(' ');
        sb.write(cur);
      }
    }
    return sb.toString();
  }

  static double _hOverlapFraction(_Box a, _Box b) {
    final overlap = max(0.0, min(a.maxX, b.maxX) - max(a.minX, b.minX));
    final denom = min(a.width, b.width);
    if (denom <= 0) return 0;
    return overlap / denom;
  }

  /// Cleans one raw recognised token.
  static String cleanToken(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return '';
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    t = _stripIntraNoiseQuotes(t);
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Re-attach decimals split across boxes: `33 . 1` -> `33.1`.
    t = t.replaceAllMapped(
      RegExp(r'(\d)\s*([.,])\s*(\d)'),
      (m) => '${m[1]}${m[2]}${m[3]}',
    );
    // Recurrent unit misread on nutrition tables: `kcd`/`kacl` -> `kcal`,
    // including digit-glued forms like `537kcd`.
    t = t.replaceAllMapped(
      RegExp(r'(\d)\s*(kcd|kacl|kcad)\b', caseSensitive: false),
      (m) => '${m[1]} kcal',
    );
    t = t.replaceAllMapped(
      RegExp(r'\b(kcd|kacl|kcad)\b', caseSensitive: false),
      (_) => 'kcal',
    );
    // Normalise missing space before units: `537kcal` -> `537 kcal`,
    // `80g` -> `80 g` (parses better for compliance checks; the canonical
    // `Per 100g` header is restored in _fixLine).
    t = t.replaceAllMapped(
      RegExp(r'(\d)(kcal|mg|ml|kg)\b', caseSensitive: false),
      (m) => '${m[1]} ${m[2]}',
    );
    t = t.replaceAllMapped(
      RegExp(r'(\d)g\b'),
      (m) => '${m[1]} g',
    );
    // Normalise spaced percentages from split boxes: `5 %` -> `5%`.
    t = t.replaceAllMapped(
      RegExp(r'(\d)\s+%'),
      (m) => '${m[1]}%',
    );
    return t.trim();
  }

  /// Removes quote/bracket speckle around and inside tokens while preserving
  /// real apostrophes (`Lay's`, `don't`).
  static String _stripIntraNoiseQuotes(String t) {
    final chars = t.split('');
    final buf = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      if (c == "'" ||
          c == '"' ||
          c == '`' ||
          c == '‘' ||
          c == '’' ||
          c == '“' ||
          c == '”') {
        final prev = i > 0 ? chars[i - 1] : '';
        final next = i + 1 < chars.length ? chars[i + 1] : '';
        final prevIsLetter = RegExp(r'[A-Za-z]').hasMatch(prev);
        final nextIsLetter = RegExp(r'[A-Za-z]').hasMatch(next);
        // Keep only true intra-word apostrophes.
        if (prevIsLetter && nextIsLetter) {
          buf.write("'");
        }
        // else: speckle from gridlines / ringing -> drop.
      } else {
        buf.write(c);
      }
    }
    var out = buf.toString();
    // Peel wrapper brackets the detector sometimes includes — but only when
    // unbalanced, so legitimate `(Palm)` / `[15.1]` groups survive.
    out = _peelUnbalanced(out);
    // Collapse quote-adjacent dots from table leaders: `' . '` -> `.`
    out = out.replaceAll(RegExp(r'\s*"\s*'), '');
    return out.trim();
  }

  /// Strips leading openers / trailing closers only when they have no
  /// matching counterpart in the token.
  static String _peelUnbalanced(String s) {
    const pairs = {'(': ')', '[': ']', '{': '}', '<': '>'};
    var out = s.trim();
    var changed = true;
    while (changed && out.length > 1) {
      changed = false;
      final first = out[0];
      final last = out[out.length - 1];
      if (pairs.containsKey(first) &&
          _countOf(out, first) > _countOf(out, pairs[first]!)) {
        out = out.substring(1).trimLeft();
        changed = true;
        continue;
      }
      if (pairs.containsValue(last)) {
        final opener =
            pairs.entries.firstWhere((e) => e.value == last).key;
        if (_countOf(out, last) > _countOf(out, opener)) {
          out = out.substring(0, out.length - 1).trimRight();
          changed = true;
        }
      }
    }
    return out;
  }

  static int _countOf(String s, String c) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == c) n++;
    }
    return n;
  }

  static String _stripQuotes(String t) {
    return _stripIntraNoiseQuotes(t);
  }

  // ---------------------------------------------------------------- lexicon

  static String _fixLine(String line, {bool useLexicon = true}) {
    var out = line;
    // Whitespace restoration for glued tokens: `ADVICE:Contains` missing its
    // space, `Oil(Palm)` missing its gap. Applied before word-level
    // correction so each word is clean. (Case-boundary splits like
    // `ContainsSoy` are handled per-word in _fixWord, after exact-match
    // lookup, so glued keys such as `RDAPerSee` still hit the fix map.)
    out = out.replaceAllMapped(
      RegExp(r'([:;])(?=[A-Za-z0-9])'),
      (m) => '${m[1]} ',
    );
    out = out.replaceAllMapped(
      RegExp(r',(?=[A-Za-z])'),
      (_) => ', ',
    );
    out = out.replaceAllMapped(
      RegExp(r'([A-Za-z])(\()'),
      (m) => '${m[1]} ${m[2]}',
    );
    // Split glued compliance headers: `NUTRITIONALINFORMATION` etc.
    out = out.replaceAllMapped(
      RegExp(r'NUTRITIONAL\s?INFORMATION', caseSensitive: false),
      (_) => 'NUTRITIONAL INFORMATION',
    );
    out = out.replaceAllMapped(
      RegExp(r'([A-Za-z])(INFORMATION)\b', caseSensitive: false),
      (m) => '${m[1]} ${m[2]}',
    );
    out = out.replaceAllMapped(
      RegExp(r'\bSERVE\s?SIZE\b', caseSensitive: false),
      (_) => 'SERVE SIZE',
    );
    out = out.replaceAllMapped(
      RegExp(r'\bALLERGEN\s?ADVICE\b', caseSensitive: false),
      (_) => 'ALLERGEN ADVICE',
    );
    out = out.replaceAllMapped(
      RegExp(r'\bPer\s?100\s?g\b', caseSensitive: false),
      (_) => 'Per 100g',
    );

    if (!useLexicon) {
      return out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    }
    final words = out.split(' ');
    for (var i = 0; i < words.length; i++) {
      words[i] = _fixWord(words[i]);
    }
    out = words.join(' ');
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ');
    return out.trim();
  }

  static String _fixWord(String w) {
    if (w.isEmpty) return w;
    // Preserve numbers / units / percentages verbatim.
    if (RegExp(r'^[\d.,/%\-+()gmlkach]+$', caseSensitive: false).hasMatch(w) &&
        RegExp(r'\d').hasMatch(w)) {
      return w;
    }
    final lower = w.toLowerCase().replaceAll(RegExp(r'^[^a-z]+|[^a-z]+$'), '');
    if (lower.isEmpty) return w;
    final trailing = RegExp(r'[^A-Za-z]+$').firstMatch(w)?.group(0) ?? '';
    final leading = RegExp(r'^[^A-Za-z]+').firstMatch(w)?.group(0) ?? '';

    final exact = _exactFixes[lower];
    if (exact != null) {
      // Preserve ALL-CAPS headers (INGREDIENTS) vs Title case rows.
      if (w == w.toUpperCase()) return '$leading${exact.toUpperCase()}$trailing';
      return '$leading$exact$trailing';
    }
    if (lower.length >= 6) {
      final snap = _snapToVocab(lower);
      if (snap != null) {
        if (w == w.toUpperCase()) return '$leading${snap.toUpperCase()}$trailing';
        if (RegExp(r'^[A-Z]').hasMatch(w)) {
          return '$leading${snap[0].toUpperCase()}${snap.substring(1)}$trailing';
        }
        return '$leading$snap$trailing';
      }
    }
    // Last resort: split case-glued tokens (`ContainsSoy` -> `Contains Soy`)
    // and fix each part. Only reached when the whole token matched neither
    // the exact map nor the vocabulary, so keys like `RDAPerSee` are safe.
    if (RegExp(r'[a-z][A-Z]').hasMatch(w)) {
      final split = w.replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      );
      if (split != w) {
        return split
            .split(' ')
            .map(_fixWord)
            .join(' ');
      }
    }
    return w;
  }

  static String? _snapToVocab(String lower) {
    int? best;
    String? bestWord;
    for (final v in _vocab) {
      final vl = v.toLowerCase();
      if ((vl.length - lower.length).abs() > 2) continue;
      final d = _lev(lower, vl);
      final threshold = lower.length >= 9 ? 2 : 1;
      if (d <= threshold && (best == null || d < best)) {
        best = d;
        bestWord = v;
        if (d == 0) break;
      }
    }
    // Avoid aggressive rewrites: first letters must agree for distance-2.
    if (bestWord != null &&
        best == 2 &&
        lower[0] != bestWord.toLowerCase()[0]) {
      return null;
    }
    return bestWord;
  }

  static int _lev(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = min(
          min(cur[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[b.length];
  }
}

class _Box {
  const _Box(this.minX, this.maxX, this.minY, this.maxY);

  factory _Box.fromPoints(List<Offset> points) {
    if (points.isEmpty) return const _Box(0, 0, 0, 0);
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final p in points.skip(1)) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return _Box(minX, maxX, minY, maxY);
  }

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  double get width => max(maxX - minX, 0);
  double get height => max(maxY - minY, 0);
  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
}

class _Item {
  const _Item(this.result, this.box);

  final OcrResult result;
  final _Box box;
}
