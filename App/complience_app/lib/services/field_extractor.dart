/// Field extraction: layout → structured product data (pure Dart).
///
/// This replaces the old flat-text `declaration_extractor.dart`, whose
/// failure modes are documented against the two real test cases
/// (Lay's chips, Smith & Jones ketchup — see file footer):
///
/// * generic name ← longest line (took INGREDIENTS / trademark sentences)
/// * net qty fallback regex grabbed "NO." from "BATCH NO."
/// * barcode digits (13) / FSSAI (14) assigned as MRP
/// * batch = the label word "NUMBER" (no value required)
/// * phone+email fused; manufacturer block polluted by neighboring lines
/// * OCR gaps reported as compliance FAILs instead of UNVERIFIED
///
/// Rules enforced here (the "never" invariants — also unit-tested):
/// 1. A bare number is NEVER a field: MRP needs an MRP label (or currency
///    marker on the same line); FSSAI needs an FSSAI/LIC label; batch needs
///    an adjacent non-label value; a label alone NEVER satisfies its field.
/// 2. Barcode digit runs are quarantined before any numeric candidacy.
/// 3. Unit-prices in parentheses (`(Rs. 0.16/g)`) are NEVER MRP.
/// 4. Ingredients/trademark/slogan lines are NEVER brand/product names.
/// 5. OCR confidence ≠ field confidence — both are stored separately.
/// 6. Every observation carries evidence (label, relationship, bbox, method).
library;

import 'line_classifier.dart';
import 'ocr_layout.dart';
import 'ocr_tokens.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Extraction outcome for one field.
enum FieldStatus {
  /// Confidently found with valid value + evidence.
  found,

  /// Hints exist (label seen, weak pattern, poor OCR) but not provable.
  /// The rule engine must render this as UNVERIFIED, never as FAIL.
  unverified,

  /// No trace found.
  notFound,
}

enum ExtractMethod {
  labelSpatialAssociation,
  candidatePattern,
  blockCapture,
  prominence,
  variablePrintPipeline,
  legacyImport,

  /// Value confirmed or typed by the officer on the field-review screen
  /// (human-in-the-loop stage before the rule engine runs).
  manualEntry,
}

/// One extracted field with full evidence traceability.
class FieldObservation {
  const FieldObservation({
    required this.field,
    required this.status,
    this.value,
    this.data = const {},
    this.ocrConfidence = 0,
    this.fieldConfidence = 0,
    this.evidenceLabel,
    this.evidenceText,
    this.relationship,
    this.bbox,
    this.photoIndex = 0,
    this.method = ExtractMethod.candidatePattern,
    this.note,
  });

  final String field;
  final FieldStatus status;

  /// Display value (e.g. "90 g", "₹15", "11/05/26").
  final String? value;

  /// Normalized extras (e.g. {value: 90, unit: 'g'}).
  final Map<String, Object?> data;

  /// Raw recognizer confidence of the value tokens.
  final double ocrConfidence;

  /// Classification confidence: label strength × pattern × proximity × OCR.
  final double fieldConfidence;

  final String? evidenceLabel;
  final String? evidenceText;

  /// e.g. same_line_right, line_below, same_token, block_capture, prominent.
  final String? relationship;
  final NormalizedBox? bbox;
  final int photoIndex;
  final ExtractMethod method;
  final String? note;

  bool get isFound => status == FieldStatus.found;

  Map<String, Object?> toJson() => {
        'field': field,
        'status': status.name,
        'value': value,
        'data': data,
        'ocrConfidence': ocrConfidence,
        'fieldConfidence': fieldConfidence,
        'evidenceLabel': evidenceLabel,
        'evidenceText': evidenceText,
        'relationship': relationship,
        'bbox': bbox?.toJson(),
        'photoIndex': photoIndex,
        'method': method.name,
        'note': note,
      };

  factory FieldObservation.fromJson(Map<String, Object?> json) {
    NormalizedBox? box;
    try {
      final b = json['bbox'];
      if (b is Map) box = NormalizedBox.fromJson(Map<String, Object?>.from(b));
    } catch (_) {}
    return FieldObservation(
      field: json['field'] as String? ?? '',
      status: FieldStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => FieldStatus.notFound,
      ),
      value: json['value'] as String?,
      data: json['data'] is Map
          ? Map<String, Object?>.from(json['data'] as Map)
          : const {},
      ocrConfidence: (json['ocrConfidence'] as num?)?.toDouble() ?? 0,
      fieldConfidence: (json['fieldConfidence'] as num?)?.toDouble() ?? 0,
      evidenceLabel: json['evidenceLabel'] as String?,
      evidenceText: json['evidenceText'] as String?,
      relationship: json['relationship'] as String?,
      bbox: box,
      photoIndex: (json['photoIndex'] as num?)?.toInt() ?? 0,
      method: ExtractMethod.values.firstWhere(
        (e) => e.name == json['method'],
        orElse: () => ExtractMethod.candidatePattern,
      ),
      note: json['note'] as String?,
    );
  }

  static FieldObservation missing(String field) =>
      FieldObservation(field: field, status: FieldStatus.notFound);
}

/// Whole-product extraction across 1..N photos.
class ExtractedProduct {
  const ExtractedProduct({
    required this.fields,
    this.mergedFromPhotos = 1,
  });

  final Map<String, FieldObservation> fields;
  final int mergedFromPhotos;

  FieldObservation obs(String field) =>
      fields[field] ?? FieldObservation.missing(field);

  // Convenient accessors.
  FieldObservation get brand => obs('brand');
  FieldObservation get productName => obs('productName');
  FieldObservation get genericName => obs('genericName');
  FieldObservation get ingredients => obs('ingredients');
  FieldObservation get allergen => obs('allergen');
  FieldObservation get netQty => obs('netQty');
  FieldObservation get mrp => obs('mrp');
  FieldObservation get batch => obs('batch');
  FieldObservation get mfg => obs('mfg');
  FieldObservation get exp => obs('exp');
  FieldObservation get manufacturer => obs('manufacturer');
  FieldObservation get carePhone => obs('carePhone');
  FieldObservation get careEmail => obs('careEmail');
  FieldObservation get fssai => obs('fssai');
  FieldObservation get origin => obs('origin');
  FieldObservation get barcode => obs('barcode');

  Map<String, Object?> toJson() => {
        'v': 2,
        'mergedFromPhotos': mergedFromPhotos,
        'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// Reads v2 payloads AND legacy v1 `DeclarationSet` payloads (stored
  /// reports from before this refactor keep rendering).
  factory ExtractedProduct.fromJson(Map<String, Object?> json) {
    if ((json['v'] as num?)?.toInt() == 2 && json['fields'] is Map) {
      final out = <String, FieldObservation>{};
      (json['fields'] as Map).forEach((k, v) {
        try {
          out[k.toString()] = FieldObservation.fromJson(
              Map<String, Object?>.from(v as Map));
        } catch (_) {}
      });
      return ExtractedProduct(
        fields: out,
        mergedFromPhotos:
            (json['mergedFromPhotos'] as num?)?.toInt() ?? 1,
      );
    }
    return _fromLegacyV1(json);
  }

  /// Best-status-wins merge across photos (found > unverified > notFound,
  /// then higher fieldConfidence). Evidence + photo index follow the winner.
  static ExtractedProduct merge(List<ExtractedProduct> parts) {
    if (parts.isEmpty) return const ExtractedProduct(fields: {});
    if (parts.length == 1) return parts.first;
    final keys = <String>{};
    for (final p in parts) {
      keys.addAll(p.fields.keys);
    }
    int rank(FieldStatus s) => switch (s) {
          FieldStatus.found => 2,
          FieldStatus.unverified => 1,
          FieldStatus.notFound => 0,
        };
    final out = <String, FieldObservation>{};
    for (final k in keys) {
      FieldObservation? best;
      for (final p in parts) {
        final cur = p.fields[k];
        if (cur == null) continue;
        if (best == null ||
            rank(cur.status) > rank(best.status) ||
            (cur.status == best.status &&
                cur.fieldConfidence > best.fieldConfidence)) {
          best = cur;
        }
      }
      if (best != null) out[k] = best;
    }
    return ExtractedProduct(fields: out, mergedFromPhotos: parts.length);
  }

  // -- legacy v1 import (old DeclarationSet JSON) ---------------------------
  static ExtractedProduct _fromLegacyV1(Map<String, Object?> json) {
    Map<String, double> conf = {};
    (json['fieldConfidence'] as Map? ?? {}).forEach((k, v) {
      conf[k.toString()] = (v as num?)?.toDouble() ?? 0;
    });
    Map<String, String> ev = {};
    (json['evidence'] as Map? ?? {}).forEach((k, v) {
      ev[k.toString()] = v?.toString() ?? '';
    });
    Map<String, int> src = {};
    (json['sourcePhoto'] as Map? ?? {}).forEach((k, v) {
      src[k.toString()] = (v as num?)?.toInt() ?? 0;
    });

    FieldObservation imp(
      String field,
      String? value, {
      String legacyConfKey = '',
      Map<String, Object?> data = const {},
    }) {
      if (value == null || value.trim().isEmpty) {
        return FieldObservation.missing(field);
      }
      return FieldObservation(
        field: field,
        status: FieldStatus.found,
        value: value,
        data: data,
        fieldConfidence: conf[legacyConfKey] ?? 0.5,
        evidenceText: ev[legacyConfKey],
        photoIndex: src[legacyConfKey] ?? 0,
        method: ExtractMethod.legacyImport,
        note: 'Imported from pre-layout report; no bbox evidence.',
      );
    }

    return ExtractedProduct(
      fields: {
        'genericName': imp('genericName', json['genericName'] as String?,
            legacyConfKey: 'genericName'),
        'brand': imp('brand', json['brand'] as String?,
            legacyConfKey: 'brand'),
        'netQty': imp('netQty', json['netQuantityRaw'] as String?,
            legacyConfKey: 'netQuantity',
            data: {
              'value': json['netQuantityValue'],
              'unit': json['netQuantityUnit'],
            }),
        'mrp': imp('mrp', json['mrpRaw'] as String?,
            legacyConfKey: 'mrp',
            data: {
              'value': json['mrpValue'],
              'taxPhrase': json['mrpHasTaxPhrase'] == true,
            }),
        'mfg': imp('mfg', json['mfgRaw'] as String?,
            legacyConfKey: 'mfgDate'),
        'exp': imp('exp', json['expRaw'] as String?,
            legacyConfKey: 'expDate'),
        'manufacturer': imp(
            'manufacturer', json['manufacturerName'] as String?,
            legacyConfKey: 'manufacturer',
            data: {'address': json['manufacturerAddress']}),
        'carePhone': imp('carePhone', json['carePhone'] as String?,
            legacyConfKey: 'carePhone'),
        'careEmail': imp('careEmail', json['careEmail'] as String?,
            legacyConfKey: 'careEmail'),
        'origin': imp('origin', json['countryOfOrigin'] as String?,
            legacyConfKey: 'countryOfOrigin'),
        'batch': imp('batch', json['batchNo'] as String?,
            legacyConfKey: 'batchNo'),
        'fssai': imp('fssai', json['fssaiLic'] as String?,
            legacyConfKey: 'fssaiLic'),
      },
      mergedFromPhotos: (json['mergedFromPhotos'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Officer corrections from the field-review screen (human-in-the-loop
/// stage before the rule engine runs).
///
/// [values] maps field names to officer-confirmed text (`brand`,
/// `productName`, `netQty`, `mrp`, `batch`, `mfg`, `exp`, `manufacturer`,
/// `manufacturerAddress`, `carePhone`, `careEmail`, `fssai`, `origin`).
/// Empty text clears the field to notFound. Non-empty text marks it found
/// with [ExtractMethod.manualEntry]; `mrp`/`netQty` values are re-parsed so
/// `data['value']` (which the rule engine scores) matches the typed text.
ExtractedProduct applyFieldCorrections(
    ExtractedProduct base, Map<String, String> values) {
  final fields = Map<String, FieldObservation>.from(base.fields);
  values.forEach((field, raw) {
    final v = raw.trim();
    if (field == 'manufacturerAddress') {
      final cur = fields['manufacturer'];
      final addr = v;
      if (cur == null) {
        if (addr.isEmpty) return;
        fields['manufacturer'] = FieldObservation(
          field: 'manufacturer',
          status: FieldStatus.found,
          value: addr,
          data: {'name': addr, 'address': addr, 'role': 'manufacturer'},
          fieldConfidence: 0.95,
          relationship: 'officer_correction',
          method: ExtractMethod.manualEntry,
          note: 'Address typed by officer on field-review screen.',
        );
        return;
      }
      final data = Map<String, Object?>.from(cur.data);
      if (addr.isEmpty) {
        data.remove('address');
      } else {
        data['address'] = addr;
      }
      fields['manufacturer'] = FieldObservation(
        field: 'manufacturer',
        status: cur.status,
        value: cur.value,
        data: data,
        ocrConfidence: cur.ocrConfidence,
        fieldConfidence: cur.fieldConfidence,
        evidenceLabel: cur.evidenceLabel,
        evidenceText: cur.evidenceText,
        relationship: cur.relationship,
        bbox: cur.bbox,
        photoIndex: cur.photoIndex,
        method: cur.method == ExtractMethod.manualEntry
            ? ExtractMethod.manualEntry
            : cur.method,
        note: addr.isEmpty
            ? 'Address cleared by officer on field-review screen.'
            : 'Address confirmed/corrected by officer before rule check.',
      );
      return;
    }
    if (v.isEmpty) {
      fields[field] = FieldObservation(
        field: field,
        status: FieldStatus.notFound,
        note: 'Cleared by officer on field-review screen.',
      );
      return;
    }
    final cur = fields[field];
    final data = Map<String, Object?>.from(cur?.data ?? const {});
    if (field == 'mrp') {
      final m =
          RegExp(r'(\d[\d,]*)(?:\.(\d{1,2}))?').firstMatch(v);
      if (m != null) {
        final num = double.tryParse(
            '${m.group(1)!.replaceAll(',', '')}.${m.group(2) ?? '0'}');
        if (num != null && num > 0) data['value'] = num;
      }
    } else if (field == 'netQty') {
      final m = RegExp(
              r'(\d+(?:[.,]\d+)?)\s*(mg|g\b|gms?|grams?|kilograms?|kgs?|ml|cl|dl|litres?|liters?|l\b|pcs|pieces?|tablets?|capsules?)\b',
              caseSensitive: false)
          .firstMatch(v);
      if (m != null) {
        final num =
            double.tryParse(m.group(1)!.replaceAll(',', '.'));
        if (num != null && num > 0) {
          data['value'] = num;
          data['unit'] = m.group(2)!.toLowerCase();
        }
      }
    }
    fields[field] = FieldObservation(
      field: field,
      status: FieldStatus.found,
      value: v,
      data: data,
      ocrConfidence: cur?.ocrConfidence ?? 0,
      fieldConfidence: 0.95,
      evidenceLabel: cur?.evidenceLabel,
      evidenceText: cur?.evidenceText,
      relationship: cur?.relationship ?? 'officer_correction',
      bbox: cur?.bbox,
      photoIndex: cur?.photoIndex ?? 0,
      method: ExtractMethod.manualEntry,
      note: 'Value confirmed/corrected by officer before rule check.',
    );
  });
  return ExtractedProduct(
      fields: fields, mergedFromPhotos: base.mergedFromPhotos);
}

/// Overall OCR quality for one product scan — gates FAIL vs UNVERIFIED
/// (an extraction gap on a blurry 40-char capture is UNVERIFIED, not proof
/// of a missing declaration).
class ExtractionQuality {
  const ExtractionQuality({
    required this.meanConfidence,
    required this.totalChars,
    required this.regionCount,
    required this.photoCount,
  });

  final double meanConfidence;
  final int totalChars;
  final int regionCount;
  final int photoCount;

  /// Adequate = confident enough + enough text that a truly absent label
  /// would be meaningful. Tuned so the Smith & Jones capture (86% conf,
  /// dense text) counts as adequate — its date/MRP gaps then resolve via
  /// label-seen→UNVERIFIED + variable-print retry, not via this gate.
  bool get adequate =>
      meanConfidence >= 0.55 && totalChars >= 150 && regionCount >= 8;

  Map<String, Object?> toJson() => {
        'meanConfidence': meanConfidence,
        'totalChars': totalChars,
        'regionCount': regionCount,
        'photoCount': photoCount,
        'adequate': adequate,
      };
}

// ---------------------------------------------------------------------------
// Label dictionaries
// ---------------------------------------------------------------------------

class _Label {
  const _Label(this.pattern, this.strength);
  final RegExp pattern;
  final double strength; // 1.0 canonical, ~0.7 abbreviation/OCR-variant
}

final _netQtyLabels = [
  _Label(_Rx(r'net\s*wt\.?'), 0.9),
  _Label(_Rx(r'net\s*weight'), 1.0),
  _Label(_Rx(r'net\s*qty\.?'), 1.0),
  _Label(_Rx(r'net\s*quantity'), 1.0),
  _Label(_Rx(r'net\s*contents?'), 0.8),
];

final _mrpLabels = [
  _Label(_Rx(r'maximum\s*retail\s*price'), 1.0),
  _Label(_Rx(r'\bmrp\b'), 1.0),
  _Label(_Rx(r'm\s*\.\s*r\s*\.\s*p\s*\.?'), 0.9),
];

final _batchLabels = [
  _Label(_Rx(r'batch\s*no\.?'), 1.0),
  _Label(_Rx(r'batch\s*number'), 1.0),
  _Label(_Rx(r'\bbatch\b'), 0.8),
  _Label(_Rx(r'lot\s*no\.?'), 0.9),
  _Label(_Rx(r'\blot\b'), 0.6),
  _Label(_Rx(r'\bb\.?\s*no\.?'), 0.7),
  _Label(_Rx(r'\bcode\b'), 0.5),
];

final _mfgLabels = [
  _Label(_Rx(r'date\s*of\s*mfg\.?'), 1.0),
  _Label(_Rx(r'date\s*of\s*manufacture'), 1.0),
  _Label(_Rx(r'mfg\.?\s*date'), 1.0),
  _Label(_Rx(r'mfd\.?\s*(date|on)?'), 0.9),
  _Label(_Rx(r'manufactured\s*(on|date)?'), 0.8),
  _Label(_Rx(r'pkd\.?\s*(date|on)?'), 0.8),
  _Label(_Rx(r'packed\s*(on|date)?'), 0.7),
  _Label(_Rx(r'\bmfg\b'), 0.8),
  _Label(_Rx(r'\bmfd\b'), 0.8),
];

final _expLabels = [
  _Label(_Rx(r'use\s*by'), 1.0),
  _Label(_Rx(r'best\s*before'), 1.0),
  _Label(_Rx(r'date\s*of\s*expiry'), 1.0),
  _Label(_Rx(r'\bexp\b\.?\s*(date|dt)?'), 0.9),
  _Label(_Rx(r'expir(y|es|ation)'), 0.9),
];

final _mfrLabels = [
  _Label(_Rx(r'brand\s*owned\s*(&|and)\s*marketed\s*by'), 1.0),
  _Label(_Rx(r'manufactured\s*(&|and)\s*marketed\s*by'), 1.0),
  _Label(_Rx(r'manufactured\s*by'), 1.0),
  _Label(_Rx(r'marketed\s*by'), 1.0),
  _Label(_Rx(r'mktd?\s*\.?\s*by'), 0.8),
  _Label(_Rx(r'mfd\s*\.?\s*by'), 0.8),
  _Label(_Rx(r'packed\s*by'), 0.9),
  _Label(_Rx(r'pkd\s*\.?\s*by'), 0.8),
  _Label(_Rx(r'imported\s*by'), 1.0),
];

final _careLabels = [
  _Label(_Rx(r'consumer\s*care'), 1.0),
  _Label(_Rx(r'customer\s*care'), 1.0),
  _Label(_Rx(r'for\s*any\s*complaint'), 0.9),
  _Label(_Rx(r'helpline'), 0.9),
  _Label(_Rx(r'toll\s*free'), 0.9),
  _Label(_Rx(r'contact\s*(manager\s*)?consumer'), 0.8),
];

final _fssaiLabels = [
  _Label(_Rx(r'fssai'), 1.0),
  _Label(_Rx(r'lic\.?\s*no\.?'), 0.7),
  _Label(_Rx(r'license\s*no\.?'), 0.7),
  _Label(_Rx(r'licence\s*no\.?'), 0.7),
];

final _originLabels = [
  _Label(_Rx(r'country\s*of\s*origin'), 1.0),
  _Label(_Rx(r'made\s*in'), 0.9),
  _Label(_Rx(r'product\s*of'), 0.8),
];

RegExp _Rx(String src) => RegExp(src, caseSensitive: false);

// ---------------------------------------------------------------------------
// Validators (strict, OCR-tolerant, context-aware)
// ---------------------------------------------------------------------------

const _units = {
  'mg': 'mg',
  'g': 'g',
  'gm': 'g',
  'gms': 'g',
  'gram': 'g',
  'grams': 'g',
  'kg': 'kg',
  'kgs': 'kg',
  'kilogram': 'kg',
  'kilograms': 'kg',
  'ml': 'mL',
  'cl': 'cL',
  'dl': 'dL',
  'l': 'L',
  'litre': 'L',
  'litres': 'L',
  'liter': 'L',
  'liters': 'L',
  'pcs': 'pcs',
  'piece': 'pcs',
  'pieces': 'pcs',
};

/// Serving/nutrition context — a quantity here is NOT net quantity.
final _servingCtx = _Rx(r'serving|per 100|rda|/serve|nutrition');

/// Label-ish words that can never BE a batch value.
const _batchStoplist = {
  'batch',
  'number',
  'no',
  'lot',
  'code',
  'mfg',
  'mrp',
  'india',
  'pack',
};

/// Normalizes a phone match: drops stray spaces ("022- 67740100" →
/// "022-67740100"), keeps hyphens for readability.
String _normPhone(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'\.+'), '-');

/// Long digit runs (barcode/FSSAI fragments) must not seed phone matches.
bool _insideLongDigitRun(String line, int start, int end) {  var digits = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c.contains(RegExp(r'\d'))) {
      digits++;
    } else if (c != ' ' && c != '-') {
      if (i >= start && i <= end) return digits >= 12;
      digits = 0;
    }
  }
  return digits >= 12;
}

// ---------------------------------------------------------------------------
// Core engine
// ---------------------------------------------------------------------------

class _LabelHit {
  _LabelHit({
    required this.layout,
    required this.blockIndex,
    required this.lineIndex,
    required this.line,
    required this.label,
    required this.strength,
    this.voted = false,
  });

  final PageLayout layout;
  final int blockIndex;
  final int lineIndex;
  final LayoutLine line;
  final String label;
  final double strength;

  /// True when this hit comes from the classifier vote alone (no keyword).
  /// Callers then search the FULL line text for the value instead of only
  /// the text after the label.
  final bool voted;
}

List<_LabelHit> _findLabels(
  List<PageLayout> layouts,
  List<_Label> labels, {
  String? fieldClass,
  LineLabelMap? lineLabels,
}) {
  final hits = <_LabelHit>[];
  for (final layout in layouts) {
    for (var bi = 0; bi < layout.blocks.length; bi++) {
      final block = layout.blocks[bi];
      for (var li = 0; li < block.lines.length; li++) {
        final line = block.lines[li];
        var bestStrength = -1.0;
        String? bestLabel;
        for (final label in labels) {
          final m = label.pattern.firstMatch(line.text);
          if (m != null && label.strength > bestStrength) {
            bestStrength = label.strength;
            bestLabel = m.group(0)!;
          }
        }
        // Classifier vote: the line *means* this field even when no
        // keyword regex fires ("MPP Rs 15", garbled labels). Strength is
        // the classifier confidence; regex still wins ties.
        if (fieldClass != null) {
          final vote = lineLabels?[line];
          if (vote != null &&
              vote.field == fieldClass &&
              vote.confidence >= clfVoteThreshold &&
              vote.confidence > bestStrength) {
            bestStrength = vote.confidence;
            bestLabel = line.text.trim();
            hits.add(_LabelHit(
              layout: layout,
              blockIndex: bi,
              lineIndex: li,
              line: line,
              label: bestLabel,
              strength: bestStrength,
              voted: true,
            ));
            continue;
          }
        }
        if (bestLabel != null) {
          hits.add(_LabelHit(
            layout: layout,
            blockIndex: bi,
            lineIndex: li,
            line: line,
            label: bestLabel,
            strength: bestStrength,
          ));
        }
      }
    }
  }
  return hits;
}

/// Text of [line] after (to the right of) the label occurrence.
String _afterLabel(String lineText, String label) {
  final i = lineText.toLowerCase().indexOf(label.toLowerCase());
  if (i < 0) return '';
  return lineText.substring(i + label.length);
}

/// Text to search for the value given a label hit: the full line for
/// classifier-voted hits (value sits on the same line), otherwise the text
/// after the label keyword (with last-word fallback for synthetic
/// multi-word labels like "NET WEIGHT:").
String _searchAfter(_LabelHit hit) {
  if (hit.voted) return hit.line.text;
  final full = _afterLabel(hit.line.text, hit.label);
  if (full.trim().isNotEmpty) return full;
  return _afterLabel(hit.line.text, hit.label.split(' ').last);
}

double _blend(double strength, double ocrConf) =>
    (strength * (0.55 + 0.45 * ocrConf.clamp(0, 1)) * 100).round() / 100;

/// Nearby-line pool for value search, across block boundaries.
///
/// Rationale: declarations are often two-column mini-tables ("NET WEIGHT:"
/// left, "90g" right) that the block splitter correctly separates (blocks
/// prevent *text* contamination) — but a valid *value pattern* in the same
/// visual row as an explicit label is almost certainly the value. Tiers:
/// same visual row (|dy| < 3% height) scores near same-line; looser
/// neighborhood (±7%) scores lower. Block scoping is intentionally NOT
/// applied here; it stays on manufacturer/ingredients capture where
/// contamination actually happens.
List<({LayoutLine line, String rel, double prox})> _nearbyLines(
    PageLayout layout, LayoutLine ref) {
  final out = <({LayoutLine line, String rel, double prox})>[];
  for (final line in layout.lines) {
    if (identical(line, ref)) continue;
    if (line.text.trim().isEmpty) continue;
    final dy = (line.nbox.centerY - ref.nbox.centerY).abs();
    if (dy < 0.03) {
      out.add((line: line, rel: 'same_row', prox: 0.95));
    } else if (dy < 0.07) {
      out.add((line: line, rel: 'nearby', prox: 0.75));
    }
  }
  return out;
}

/// Line-level classifier votes, keyed by line identity. Null (or missing
/// entries) = classifier unavailable → pure regex/spatial path, exactly the
/// pre-B behavior. The pipeline builds this once per scan (one batched
/// inference for ALL lines of ALL photos) via `LineClassifier`.
typedef LineLabelMap = Map<LayoutLine, LineLabel>;

/// Minimum classifier confidence to count as a vote.
const double clfVoteThreshold = 0.45;

/// True when the classifier votes [fieldClass] for [line].
bool _voted(LineLabelMap? map, LayoutLine line, String fieldClass,
    [double threshold = clfVoteThreshold]) {
  final l = map?[line];
  return l != null && l.field == fieldClass && l.confidence >= threshold;
}

FieldStatus _toStatus(double conf) {
  if (conf >= 0.7) return FieldStatus.found;
  if (conf >= 0.45) return FieldStatus.unverified;
  return FieldStatus.notFound;
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Extracts all fields from 1..N photo layouts.
///
/// [quality] is computed by the caller (see [ScanPipeline]); it is stored
/// for the rule engine's FAIL-vs-UNVERIFIED gating.
///
/// [lineLabels] carries the Option-B classifier votes keyed by line
/// identity (built once per scan by the pipeline). Null = classifier
/// unavailable → pure regex/spatial path (pre-B behavior, fully tested).
ExtractedProduct extractProduct(
  List<PageLayout> layouts, {
  ExtractionQuality quality = const ExtractionQuality(
      meanConfidence: 0, totalChars: 0, regionCount: 0, photoCount: 1),
  LineLabelMap? lineLabels,
}) {
  if (layouts.isEmpty) {
    return const ExtractedProduct(fields: {});
  }
  final perPhoto = <ExtractedProduct>[];
  for (final layout in layouts) {
    perPhoto.add(_extractSingle(layout, lineLabels: lineLabels));
  }
  final merged = ExtractedProduct.merge(perPhoto);
  return ExtractedProduct(
    fields: merged.fields,
    mergedFromPhotos: layouts.length,
  );
}

ExtractedProduct _extractSingle(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  final f = <String, FieldObservation>{
    'brand': _extractBrand(layout, lineLabels: lineLabels),
    'productName': _extractProductName(layout, lineLabels: lineLabels),
    'netQty': _extractNetQty(layout, lineLabels: lineLabels),
    'mrp': _extractMrp(layout, lineLabels: lineLabels),
    'batch': _extractBatch(layout, lineLabels: lineLabels),
    'mfg': _extractDate(layout, _mfgLabels, 'mfg', lineLabels: lineLabels),
    'exp': _extractDate(layout, _expLabels, 'exp', lineLabels: lineLabels),
    'manufacturer':
        _extractManufacturer(layout, lineLabels: lineLabels),
    'carePhone': _extractPhone(layout, lineLabels: lineLabels),
    'careEmail': _extractEmail(layout, lineLabels: lineLabels),
    'fssai': _extractFssai(layout, lineLabels: lineLabels),
    'origin': _extractOrigin(layout, lineLabels: lineLabels),
    'barcode': _extractBarcode(layout),
    'ingredients': _extractBlockField(
        layout, _Rx(r'^\s*ingredients?\b'), 'ingredients',
        lineLabels: lineLabels, labelClass: 'ingredients'),
    'allergen': _extractBlockField(
        layout, _Rx(r'allergen|contains:'), 'allergen',
        lineLabels: lineLabels, labelClass: 'allergen'),
  };
  // genericName mirrors productName (PCR "common name") when confident;
  // never ingredients — invariant #4.
  final product = f['productName']!;
  f['genericName'] = product.status == FieldStatus.found &&
          product.fieldConfidence >= 0.6
      ? FieldObservation(
          field: 'genericName',
          status: FieldStatus.found,
          value: product.value,
          data: const {'source': 'productName'},
          ocrConfidence: product.ocrConfidence,
          fieldConfidence: product.fieldConfidence,
          evidenceText: product.evidenceText,
          relationship: product.relationship,
          bbox: product.bbox,
          photoIndex: product.photoIndex,
          method: product.method,
        )
      : FieldObservation(
          field: 'genericName',
          status: product.status == FieldStatus.unverified
              ? FieldStatus.unverified
              : FieldStatus.notFound,
          value: product.value,
          ocrConfidence: product.ocrConfidence,
          fieldConfidence: product.fieldConfidence,
          evidenceText: product.evidenceText,
          photoIndex: product.photoIndex,
          method: product.method,
          note: product.status == FieldStatus.unverified
              ? 'Candidate product name needs confirmation on pack.'
              : 'No confident common/product name on this photo.',
        );
  return ExtractedProduct(fields: f, mergedFromPhotos: 1);
}

// ---------------------------------------------------------------------------
// Brand / product name (prominence + exclusions)
// ---------------------------------------------------------------------------

final _nameExclusions = _Rx(
    r'trade\s*mark|registered|©|®.*(ltd|inc|pvt)|ingredients?|nutrition|'
    r'manufactured|marketed|packed|imported|consumer|care|fssai|lic\.?\s*no|'
    r'mrp|batch|mfg|exp|use\s*by|best\s*before|country\s*of\s*origin|made\s*in');

/// Classifier classes that disqualify an identity candidate even when the
/// line looks prominent (a tall "INGREDIENTS" header is not a brand).
const _identityVetoClasses = {
  'ingredients',
  'nutrition',
  'manufacturer',
  'care',
  'barcode',
  'slogan_other',
};

/// Classifier confidence boost when the line is voted brand/product_name.
double _identityBoost(LineLabelMap? map, LayoutLine line) {
  final l = map?[line];
  if (l == null) return 0;
  if ((l.field == 'brand' || l.field == 'product_name') &&
      l.confidence >= clfVoteThreshold) {
    return 0.15;
  }
  return 0;
}

List<LayoutLine> _identityCandidates(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  if (layout.imgH <= 0) return [];
  return layout.lines.where((line) {
    final s = line.text.trim();
    if (s.length < 2 || s.length > 60) return false;
    if (line.nbox.minY > 0.42) return false; // top area only
    if (line.box.height / layout.imgH < 0.008) return false; // prominent
    if (_nameExclusions.hasMatch(s)) return false;
    if (s.endsWith('!')) return false; // slogans ("Very Very Tasty!")
    final vote = lineLabels?[line];
    if (vote != null &&
        _identityVetoClasses.contains(vote.field) &&
        vote.confidence > 0.6) {
      return false;
    }
    if (RegExp(r'\d').allMatches(s).length > s.length / 2) return false;
    final words = s.split(RegExp(r'\s+'));
    if (words.length > 8) return false;
    return true;
  }).toList()
    ..sort((a, b) => b.box.height.compareTo(a.box.height));
}

FieldObservation _extractBrand(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  final cands = _identityCandidates(layout, lineLabels: lineLabels);
  if (cands.isEmpty) {
    return const FieldObservation(
        field: 'brand', status: FieldStatus.notFound);
  }
  final top = cands.first;
  final conf =
      (_blend(0.75, top.meanConfidence) + _identityBoost(lineLabels, top))
          .clamp(0.0, 0.95);
  return FieldObservation(
    field: 'brand',
    status: _toStatus(conf),
    value: top.text.trim(),
    ocrConfidence: top.meanConfidence,
    fieldConfidence: conf,
    evidenceText: top.text.trim(),
    relationship: 'prominent',
    bbox: top.nbox,
    photoIndex: layout.photoIndex,
    method: ExtractMethod.prominence,
    note: 'Tallest identity-area line.',
  );
}

FieldObservation _extractProductName(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  final cands = _identityCandidates(layout, lineLabels: lineLabels);
  if (cands.isEmpty) {
    return const FieldObservation(
        field: 'productName', status: FieldStatus.notFound);
  }
  // Second distinct prominent line; if the top line holds both
  // ("SMITH & JONES" brand vs "Tomato Ketchup" product) the second wins.
  LayoutLine? pick;
  if (cands.length >= 2) {
    pick = cands[1];
  } else {
    // Single candidate: accept as product only if it reads like a food
    // name (2+ words) rather than a lone brand shout.
    final words = cands.first.text.trim().split(RegExp(r'\s+'));
    if (words.length < 2) {
      final conf = _blend(0.5, cands.first.meanConfidence);
      return FieldObservation(
        field: 'productName',
        status: FieldStatus.unverified,
        value: cands.first.text.trim(),
        ocrConfidence: cands.first.meanConfidence,
        fieldConfidence: conf,
        evidenceText: cands.first.text.trim(),
        relationship: 'prominent',
        bbox: cands.first.nbox,
        photoIndex: layout.photoIndex,
        method: ExtractMethod.prominence,
        note: 'Only one prominent line — confirm brand vs product name.',
      );
    }
    pick = cands.first;
  }
  final conf =
      (_blend(0.8, pick.meanConfidence) + _identityBoost(lineLabels, pick))
          .clamp(0.0, 0.95);
  return FieldObservation(
    field: 'productName',
    status: _toStatus(conf),
    value: pick.text.trim(),
    ocrConfidence: pick.meanConfidence,
    fieldConfidence: conf,
    evidenceText: pick.text.trim(),
    relationship: 'prominent',
    bbox: pick.nbox,
    photoIndex: layout.photoIndex,
    method: ExtractMethod.prominence,
  );
}

// ---------------------------------------------------------------------------
// Net quantity
// ---------------------------------------------------------------------------

final _qtyValue =
    // NOTE: bare `g` (`g\b`) must precede `gms?` — alternation order matters:
    // "80g" matches `g\b`; "gms" skips it (no boundary) and matches `gms?`.
    RegExp(r'(\d+(?:[.,]\d+)?)\s*(mg|g\b|gms?|grams?|kilograms?|kgs?|ml|cl|dl|litres?|liters?|l\b|pcs|pieces?|tablets?|capsules?)\b', caseSensitive: false);

FieldObservation _extractNetQty(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  // Label hits: single-line ("NET QTY: 80g") AND split ("NET" / "WEIGHT:"
  // on consecutive lines — common when the label wraps).
  final hits = <_LabelHit>[
    ..._findLabels([layout], _netQtyLabels,
        fieldClass: 'net_qty', lineLabels: lineLabels)
  ];
  for (var bi = 0; bi < layout.blocks.length; bi++) {
    final block = layout.blocks[bi];
    for (var li = 0; li < block.lines.length; li++) {
      final t = block.lines[li].text;
      // Wrapped label, contiguous ("NET" / "WEIGHT:" on consecutive rows).
      if (RegExp(r'^\s*net\s*$', caseSensitive: false).hasMatch(t) &&
          li + 1 < block.lines.length &&
          RegExp(r'^\s*(weight|wt\.?|qty\.?|quantity|contents?)\b',
                  caseSensitive: false)
              .hasMatch(block.lines[li + 1].text)) {
        hits.add(_LabelHit(
          layout: layout,
          blockIndex: bi,
          lineIndex: li + 1,
          line: block.lines[li + 1],
          label: 'NET ${block.lines[li + 1].text.trim()}',
          strength: 0.9,
        ));
      } else if (RegExp(r'^\s*net\s*$', caseSensitive: false).hasMatch(t)) {
        // Lone "NET" (value column interleaves between the wrapped label
        // rows, e.g. NET | 90g / WEIGHT:). The nearby-line pool below
        // supplies the value; the regex still requires a valid quantity.
        hits.add(_LabelHit(
          layout: layout,
          blockIndex: bi,
          lineIndex: li,
          line: block.lines[li],
          label: 'NET',
          strength: 0.85,
        ));
      }
    }
  }

  // Value pool: text right of the label + tiered nearby lines
  // (same-row columns included — see _nearbyLines).
  var bestConf = -1.0;
  FieldObservation? best;
  for (final hit in hits) {
    final attempts = <({String text, String rel, double prox, double ocr, NormalizedBox box})>[];
    final after = _searchAfter(hit);
    if (after.trim().isNotEmpty && !_servingCtx.hasMatch(after)) {
      attempts.add((
        text: after,
        rel: 'same_line_right',
        prox: 1.0,
        ocr: hit.line.meanConfidence,
        box: hit.line.nbox
      ));
    }
    for (final n in _nearbyLines(layout, hit.line)) {
      if (_servingCtx.hasMatch(n.line.text)) continue;
      attempts.add((
        text: n.line.text,
        rel: n.rel,
        prox: n.prox,
        ocr: n.line.meanConfidence,
        box: n.line.nbox
      ));
    }
    for (final a in attempts) {
      final m = _qtyValue.firstMatch(a.text);
      if (m == null) continue;
      final parsed = _normQty(m.group(1)!, m.group(2)!);
      if (parsed == null) continue;
      final conf = _blend(hit.strength * a.prox, a.ocr);
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: 'netQty',
          status: _toStatus(conf),
          value: '${parsed.$1} ${parsed.$2}',
          data: {'value': parsed.$1, 'unit': parsed.$2, 'raw': m.group(0)},
          ocrConfidence: a.ocr,
          fieldConfidence: conf,
          evidenceLabel: hit.label,
          evidenceText: a.text.trim(),
          relationship: a.rel,
          bbox: a.box,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.labelSpatialAssociation,
        );
      }
    }
  }
  if (best != null) return best;

  // Pass 2: NO unlabelled fallback. The old fallback (".. No." from
  // "BATCH NO.") is exactly what produced garbage — a quantity without a
  // Net label is unverified at best, and only when the pattern is strong.
  // (Kept deliberately strict: return notFound and let the rule engine
  // decide FAIL vs UNVERIFIED from OCR quality.)
  return const FieldObservation(
      field: 'netQty',
      status: FieldStatus.notFound,
      note: 'No Net-quantity label with a valid value on this photo.');
}

(double, String)? _normQty(String num, String unit) {
  final v = double.tryParse(num.replaceAll(',', '.'));
  final u = _units[unit.toLowerCase()];
  if (v == null || u == null || v <= 0 || v >= 1000000) return null;
  return (v, u);
}

// ---------------------------------------------------------------------------
// MRP — label association mandatory; unit-price trap excluded
// ---------------------------------------------------------------------------

final _priceValue =
    RegExp(r'(₹|Rs\.?|INR)?\s*(\d[\d,]*)(?:\.(\d{1,2}))?', caseSensitive: false);

FieldObservation _extractMrp(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  for (final hit in _findLabels([layout], _mrpLabels,
      fieldClass: 'mrp', lineLabels: lineLabels)) {
    // Candidate pool: same-line text after label + tiered nearby lines
    // (wrapped variable print often drops the value beside/below).
    final attempts = <({String text, String rel, double prox, double ocr, NormalizedBox? box})>[];
    final after = _searchAfter(hit);
    if (after.trim().isNotEmpty) {
      attempts.add((
        text: after,
        rel: 'same_line_right',
        prox: 1.0,
        ocr: hit.line.meanConfidence,
        box: hit.line.nbox
      ));
    }
    for (final n in _nearbyLines(layout, hit.line)) {
      attempts.add((
        text: n.line.text,
        rel: n.rel,
        prox: n.prox,
        ocr: n.line.meanConfidence,
        box: n.line.nbox
      ));
    }
    for (final a in attempts) {
      // Strip parenthesized unit-prices FIRST: "(Rs. 0.16/g)" must never
      // supply the MRP value (Smith & Jones trap).
      final scrubbed =
          a.text.replaceAll(RegExp(r'\([^)]*(/|per)[^)]*\)'), ' ');
      final m = _priceValue.firstMatch(scrubbed);
      if (m == null) continue;
      final rawNum = (m.group(2) ?? '').replaceAll(',', '');
      if (rawNum.isEmpty) continue;
      // Barcode/FSSAI guard: bare runs of 8+ digits are not prices.
      if (RegExp(r'^\d{8,}$').hasMatch(rawNum)) continue;
      final hasCurrency = (m.group(1) ?? '').isNotEmpty;
      final hasDecimal = m.group(3) != null;
      final v = double.tryParse(
          hasDecimal ? '$rawNum.${m.group(3)}' : rawNum);
      if (v == null || v <= 0 || v > 1000000) continue;
      // Strength: an MRP label on the same line makes even a bare integer
      // strong ("MRP Rs: 15" — the Smith & Jones ground truth). Currency
      // markers or decimals raise it further; values below the label lose
      // a little (wrapped variable print).
      final labelLineHasCurrency =
          RegExp(r'₹|Rs\.?|INR', caseSensitive: false)
              .hasMatch(hit.line.text);
      var pattern = 0.8;
      if (hasCurrency) pattern = 0.95;
      if (hasDecimal && pattern < 0.9) pattern = 0.9;
      if (labelLineHasCurrency && pattern < 0.9) pattern = 0.9;
      pattern *= a.prox;
      final conf = _blend(hit.strength * pattern, a.ocr);
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: 'mrp',
          status: _toStatus(conf),
          value: '₹${v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}',
          data: {'value': v, 'raw': m.group(0)?.trim()},
          ocrConfidence: a.ocr,
          fieldConfidence: conf,
          evidenceLabel: hit.label,
          evidenceText: a.text.trim(),
          relationship: a.rel,
          bbox: a.box,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.labelSpatialAssociation,
        );
      }
    }
  }
  if (best != null) return best;
  // Label seen but no value (dot-matrix unread) → unverified, NOT missing.
  final labels = _findLabels([layout], _mrpLabels,
      fieldClass: 'mrp', lineLabels: lineLabels);
  if (labels.isNotEmpty) {
    return FieldObservation(
      field: 'mrp',
      status: FieldStatus.unverified,
      ocrConfidence: labels.first.line.meanConfidence,
      fieldConfidence: 0.5,
      evidenceLabel: labels.first.label,
      evidenceText: labels.first.line.text.trim(),
      relationship: 'label_only',
      bbox: labels.first.line.nbox,
      photoIndex: layout.photoIndex,
      method: ExtractMethod.labelSpatialAssociation,
      note: 'MRP label seen but no readable value — variable print may '
          'need the re-read pass or a closer photo.',
    );
  }
  return const FieldObservation(field: 'mrp', status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// Batch — value required; the label word is never the value
// ---------------------------------------------------------------------------

final _batchValue =
    RegExp(r'\b([A-Z0-9][A-Z0-9\-/]{2,23})\b', caseSensitive: false);

FieldObservation _extractBatch(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  for (final hit in _findLabels([layout], _batchLabels,
      fieldClass: 'batch', lineLabels: lineLabels)) {
    final pool = <({String text, String rel, double prox, double ocr, NormalizedBox? box})>[
      (text: _searchAfter(hit), rel: 'same_line_right', prox: 1.0, ocr: hit.line.meanConfidence, box: hit.line.nbox),
    ];
    for (final n in _nearbyLines(layout, hit.line)) {
      pool.add((text: n.line.text, rel: n.rel, prox: n.prox, ocr: n.line.meanConfidence, box: n.line.nbox));
    }
    for (final a in pool) {
      for (final m in _batchValue.allMatches(a.text)) {
        final cand = m.group(1)!;
        final low = cand.toLowerCase().replaceAll(RegExp(r'[\-/]'), '');
        if (_batchStoplist.contains(low)) continue; // label word, not value
        if (!RegExp(r'\d').hasMatch(cand)) continue; // need digits
        if (RegExp(r'\d').allMatches(cand).length < 2 &&
            cand.length < 5) {
          continue;
        }
        if (cand.contains(RegExp(r'[./]'))) continue; // dates, not batches
        if (RegExp(r'^\d{8,}$').hasMatch(cand)) continue; // barcode digits
        final conf = _blend(
            hit.strength * a.prox * (a.rel == 'same_line_right' ? 1.0 : 0.95),
            a.ocr);
        if (conf > bestConf) {
          bestConf = conf;
          best = FieldObservation(
            field: 'batch',
            status: _toStatus(conf),
            value: cand,
            ocrConfidence: a.ocr,
            fieldConfidence: conf,
            evidenceLabel: hit.label,
            evidenceText: a.text.trim(),
            relationship: a.rel,
            bbox: a.box,
            photoIndex: layout.photoIndex,
            method: ExtractMethod.labelSpatialAssociation,
          );
        }
      }
    }
  }
  if (best != null) return best;
  final labelHits = _findLabels([layout], _batchLabels,
      fieldClass: 'batch', lineLabels: lineLabels);
  if (labelHits.isNotEmpty) {
    final hit = labelHits.first;
    return FieldObservation(
      field: 'batch',
      status: FieldStatus.unverified,
      fieldConfidence: 0.5,
      ocrConfidence: hit.line.meanConfidence,
      evidenceLabel: hit.label,
      evidenceText: hit.line.text.trim(),
      relationship: 'label_only',
      bbox: hit.line.nbox,
      photoIndex: layout.photoIndex,
      method: ExtractMethod.labelSpatialAssociation,
      note: 'Batch label seen but no identifier value adjacent — '
          'variable print may need the re-read pass.',
    );
  }
  return const FieldObservation(field: 'batch', status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// Dates — label-classified, dot-matrix tolerant
// ---------------------------------------------------------------------------

String _cleanDateToken(String s) {
  // "11/05/26(16:07)" → "11/05/26"; "10.05.27c" → "10.05.27"
  var t = s.replaceAll(RegExp(r'\(.*'), '');
  t = t.replaceAll(RegExp(r'[^0-9./\-A-Za-z ]'), ' ').trim();
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

final _dateNum = RegExp(
    r'\b(0?[1-9]|[12][0-9]|3[01])\s*[./\-]\s*(0?[1-9]|1[0-2])\s*[./\-]\s*(\d{2}|\d{4})\b');
final _dateWord = RegExp(
    r'\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[\s,.\-]*(\d{4})\b',
    caseSensitive: false);

bool _saneDate(int d, int m, int yFull) {
  if (d < 1 || d > 31 || m < 1 || m > 12) return false;
  if (yFull < 1990 || yFull > 2045) return false;
  return true;
}

int _expandYear(int y) => y < 100 ? (y <= 49 ? 2000 + y : 1900 + y) : y;

FieldObservation _extractDate(
    PageLayout layout, List<_Label> labels, String field,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  _LabelHit? firstLabelHit;
  final dateClass = field == 'mfg' ? 'mfg_date' : 'exp_date';
  for (final hit in _findLabels([layout], labels,
      fieldClass: dateClass, lineLabels: lineLabels)) {
    firstLabelHit ??= hit;
    final pool = <({String text, String rel, double prox, double ocr, NormalizedBox? box})>[
      (text: _searchAfter(hit), rel: 'same_line_right', prox: 1.0, ocr: hit.line.meanConfidence, box: hit.line.nbox),
    ];
    for (final n in _nearbyLines(layout, hit.line)) {
      pool.add((text: n.line.text, rel: n.rel, prox: n.prox, ocr: n.line.meanConfidence, box: n.line.nbox));
    }
    for (final a in pool) {
      final cleaned = _cleanDateToken(a.text);
      var matched = _dateNum.firstMatch(cleaned)?.group(0);
      matched ??= _dateWord.firstMatch(cleaned)?.group(0);
      if (matched == null) continue;
      // Sanity on numeric dates.
      final nm = _dateNum.firstMatch(matched);
      if (nm != null) {
        final d = int.parse(nm.group(1)!);
        final m = int.parse(nm.group(2)!);
        final y = _expandYear(int.parse(nm.group(3)!));
        if (!_saneDate(d, m, y)) continue;
      }
      final conf =
          _blend(hit.strength * a.prox, a.ocr);
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: field,
          status: _toStatus(conf),
          value: matched,
          ocrConfidence: a.ocr,
          fieldConfidence: conf,
          evidenceLabel: hit.label,
          evidenceText: a.text.trim(),
          relationship: a.rel,
          bbox: a.box,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.labelSpatialAssociation,
        );
      }
    }
  }
  if (best != null) return best;
  if (firstLabelHit != null) {
    final hit = firstLabelHit;
    return FieldObservation(
      field: field,
      status: FieldStatus.unverified,
      fieldConfidence: 0.5,
      ocrConfidence: hit.line.meanConfidence,
      evidenceLabel: hit.label,
      evidenceText: hit.line.text.trim(),
      relationship: 'label_only',
      bbox: hit.line.nbox,
      photoIndex: layout.photoIndex,
      method: ExtractMethod.labelSpatialAssociation,
      note: 'Date label seen but no readable date — dot-matrix print may '
          'need the re-read pass or a closer photo.',
    );
  }
  return FieldObservation(field: field, status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// Manufacturer — block-scoped capture (never crosses block boundary)
// ---------------------------------------------------------------------------

final _nextLabelLine =
    RegExp(r'^[A-Z][A-Z .&()/\-]{4,}:', caseSensitive: false);

String _roleFromLabel(String label) {
  final l = label.toLowerCase();
  if (l.contains('import')) return 'importer';
  if (l.contains('market')) return 'marketer';
  if (l.contains('pack') || l.contains('pkd')) return 'packer';
  return 'manufacturer';
}

FieldObservation _extractManufacturer(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  for (final hit in _findLabels([layout], _mfrLabels,
      fieldClass: 'manufacturer', lineLabels: lineLabels)) {
    final block = layout.blocks[hit.blockIndex];
    final rest = _afterLabel(hit.line.text, hit.label).trim();
    final captured = <String>[];
    if (rest.isNotEmpty &&
        !rest.toLowerCase().contains('address above')) {
      captured.add(rest);
    }
    for (var li = hit.lineIndex + 1;
        li < block.lines.length && captured.length < 4;
        li++) {
      final t = block.lines[li].text.trim();
      if (t.isEmpty) continue;
      // Stop at the next declaration label — same-block contamination
      // (the USE-BY-into-manufacturer bug) can no longer cross blocks,
      // and this stops it even within a block.
      if (_nextLabelLine.hasMatch(t) && captured.isNotEmpty) break;
      captured.add(t);
    }
    if (captured.isEmpty) continue;
    final name = captured.first
        .replaceAll(RegExp(r'^[\s:,\-]+'), '')
        .trim();
    final address =
        captured.length > 1 ? captured.sublist(1).join(', ') : '';
    if (name.isEmpty || name.length < 3) continue;
    final strong = RegExp(r'\b[1-9]\d{5}\b').hasMatch(captured.join(' ')) ||
        captured.length >= 3;
    final conf = _blend(hit.strength * (strong ? 0.95 : 0.7),
        hit.line.meanConfidence);
    if (conf > bestConf) {
      bestConf = conf;
      best = FieldObservation(
        field: 'manufacturer',
        status: _toStatus(conf),
        value: name,
        data: {
          'name': name,
          'address': address,
          'role': _roleFromLabel(hit.label),
        },
        ocrConfidence: hit.line.meanConfidence,
        fieldConfidence: conf,
        evidenceLabel: hit.label,
        evidenceText: captured.join(' / '),
        relationship: 'block_capture',
        bbox: block.nbox,
        photoIndex: layout.photoIndex,
        method: ExtractMethod.blockCapture,
      );
    }
  }
  return best ??
      const FieldObservation(
          field: 'manufacturer', status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// Phone / email — independent detection on line scope (never glued)
// ---------------------------------------------------------------------------

final _phoneLandline =
    // Separators loosened to {0,2}: real OCR emits "022- 67740100" /
    // "022 6774 0100". Value is re-normalized to digits+hyphen below.
    RegExp(r'(?<!\d)(0\d{2,4}[\s\-.]{0,2}\d{6,8})(?!\d)');
final _phoneTollfree =
    RegExp(r'(?<!\d)((?:1800|1860)[\s\-]?\d{3,4}[\s\-]?\d{3,4}|1800\d{6})(?!\d)');
final _phoneMobile = RegExp(r'(?<!\d)([6-9]\d{9})(?!\d)');
final _emailRx = RegExp(
    r'([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})');

FieldObservation _extractPhone(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  var careContext = false;
  for (final block in layout.blocks) {
    final hasCare = _careLabels.any(
            (l) => l.pattern.hasMatch(block.text)) ||
        block.lines.any((line) => _voted(lineLabels, line, 'care'));
    for (final line in block.lines) {
      final t = line.text;
      final votedCare = _voted(lineLabels, line, 'care');
      final cands = <({String v, double s})>[];
      final lf = _phoneLandline.firstMatch(t);
      if (lf != null && !_insideLongDigitRun(t, lf.start, lf.end)) {
        cands.add((v: _normPhone(lf.group(1)!), s: 0.95));
      }
      final tf = _phoneTollfree.firstMatch(t);
      if (tf != null) cands.add((v: _normPhone(tf.group(1)!), s: 0.95));
      final mb = _phoneMobile.firstMatch(t);
      if (mb != null && !_insideLongDigitRun(t, mb.start, mb.end)) {
        // Bare 10-digit needs care context or separators; landline/
        // toll-free patterns are self-evidencing. A classifier 'care'
        // vote counts as context (garbled "C022- 67740100 AND" case).
        cands.add((v: mb.group(1)!, s: (hasCare || votedCare) ? 0.8 : 0.55));
      }
      for (final c in cands) {
        final boost = votedCare ? 1.0 : (hasCare ? 1.0 : 0.85);
        final conf = _blend(c.s * boost, line.meanConfidence);
        if (conf > bestConf) {
          bestConf = conf;
          careContext = hasCare;
          best = FieldObservation(
            field: 'carePhone',
            status: _toStatus(conf),
            value: c.v,
            ocrConfidence: line.meanConfidence,
            fieldConfidence: conf,
            evidenceText: t.trim(),
            relationship: 'line_pattern',
            bbox: line.nbox,
            photoIndex: layout.photoIndex,
            method: ExtractMethod.candidatePattern,
          );
        }
      }
    }
  }
  if (best != null) return best;
  if (careContext) {
    return const FieldObservation(
      field: 'carePhone',
      status: FieldStatus.unverified,
      fieldConfidence: 0.5,
      method: ExtractMethod.candidatePattern,
      note: 'Consumer-care section seen but no readable phone number.',
    );
  }
  return const FieldObservation(
      field: 'carePhone', status: FieldStatus.notFound);
}

FieldObservation _extractEmail(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  for (final block in layout.blocks) {
    final hasCare =
        _careLabels.any((l) => l.pattern.hasMatch(block.text)) ||
            block.lines.any((line) => _voted(lineLabels, line, 'care'));
    for (final line in block.lines) {
      final m = _emailRx.firstMatch(line.text);
      if (m == null) continue;
      var local = m.group(0)!;
      // De-glue: "40100ANDCUSTOMERCARE@…" → "CUSTOMERCARE@…" (phone digits
      // + AND fused onto the local part by tight print).
      final deglued = RegExp(r'^\d+(AND)?([A-Za-z][A-Za-z0-9._%+\-]+@.*)')
          .firstMatch(local);
      if (deglued != null) local = deglued.group(2)!;
      local = local.replaceAll(RegExp(r'^[^A-Za-z0-9]+'), '');
      if (!local.contains('@')) continue;
      final votedCare = _voted(lineLabels, line, 'care');
      final conf = _blend(
          (hasCare || votedCare) ? 0.95 : 0.7, line.meanConfidence);
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: 'careEmail',
          status: _toStatus(conf),
          value: local,
          ocrConfidence: line.meanConfidence,
          fieldConfidence: conf,
          evidenceText: line.text.trim(),
          relationship: 'line_pattern',
          bbox: line.nbox,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.candidatePattern,
        );
      }
    }
  }
  return best ??
      const FieldObservation(
          field: 'careEmail', status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// FSSAI (label-gated), origin, barcode (quarantine + record)
// ---------------------------------------------------------------------------

final _fssaiNum = RegExp(r'(?<!\d)(\d{14})(?!\d)');

FieldObservation _extractFssai(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  var bestConf = -1.0;
  FieldObservation? best;
  for (final block in layout.blocks) {
    final labelHit = _fssaiLabels.any((l) => l.pattern.hasMatch(block.text)) ||
        block.lines.any((line) => _voted(lineLabels, line, 'fssai'));
    if (!labelHit) continue;
    for (final line in block.lines) {
      final m = _fssaiNum.firstMatch(line.text);
      if (m == null) continue;
      final conf = _blend(0.95, line.meanConfidence);
      if (conf > bestConf) {
        bestConf = conf;
        best = FieldObservation(
          field: 'fssai',
          status: _toStatus(conf),
          value: m.group(1),
          ocrConfidence: line.meanConfidence,
          fieldConfidence: conf,
          evidenceText: line.text.trim(),
          relationship: 'block_gated',
          bbox: line.nbox,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.labelSpatialAssociation,
        );
      }
    }
  }
  // No label-gated 14-digit number → not found. Bare 14-digit runs stay
  // quarantined: they must NEVER become MRP/batch (Lay's invariant).
  return best ??
      const FieldObservation(field: 'fssai', status: FieldStatus.notFound);
}

FieldObservation _extractOrigin(PageLayout layout,
    {LineLabelMap? lineLabels}) {
  for (final hit in _findLabels([layout], _originLabels,
      fieldClass: 'origin', lineLabels: lineLabels)) {
    final after = _afterLabel(hit.line.text, hit.label).trim();
    final val = after.isNotEmpty ? after.split(RegExp(r'[.,;]')).first : '';
    if (val.trim().length >= 3) {
      final conf = _blend(hit.strength, hit.line.meanConfidence);
      return FieldObservation(
        field: 'origin',
        status: _toStatus(conf),
        value: _titleCase(val.trim()),
        ocrConfidence: hit.line.meanConfidence,
        fieldConfidence: conf,
        evidenceLabel: hit.label,
        evidenceText: hit.line.text.trim(),
        relationship: 'same_line_right',
        bbox: hit.line.nbox,
        photoIndex: layout.photoIndex,
        method: ExtractMethod.labelSpatialAssociation,
      );
    }
  }
  return const FieldObservation(
      field: 'origin', status: FieldStatus.notFound);
}

/// Long digit runs (barcode / FSSAI-shaped) are recorded here and excluded
/// everywhere else. A 13-digit run is a barcode, never an MRP.
FieldObservation _extractBarcode(PageLayout layout) {
  for (final block in layout.blocks) {
    for (final line in block.lines) {
      final digits = line.text.replaceAll(RegExp(r'[^\d]'), '');
      final rest = line.text.replaceAll(RegExp(r'[\d\s]'), '');
      if (digits.length >= 8 && rest.trim().length <= 2) {
        final inBottom = line.nbox.minY > 0.55;
        final conf = _blend(inBottom ? 0.9 : 0.6, line.meanConfidence);
        return FieldObservation(
          field: 'barcode',
          status: _toStatus(conf),
          value: digits,
          ocrConfidence: line.meanConfidence,
          fieldConfidence: conf,
          evidenceText: line.text.trim(),
          relationship: 'digit_run',
          bbox: line.nbox,
          photoIndex: layout.photoIndex,
          method: ExtractMethod.candidatePattern,
        );
      }
    }
  }
  return const FieldObservation(
      field: 'barcode', status: FieldStatus.notFound);
}

// ---------------------------------------------------------------------------
// Ingredients / allergen block capture
// ---------------------------------------------------------------------------

FieldObservation _extractBlockField(
    PageLayout layout, RegExp label, String field,
    {LineLabelMap? lineLabels, String? labelClass}) {
  for (final block in layout.blocks) {
    for (var li = 0; li < block.lines.length; li++) {
      final line = block.lines[li];
      final m = label.firstMatch(line.text);
      final voted = labelClass != null &&
          _voted(lineLabels, line, labelClass, 0.6);
      if (m == null && !voted) continue;
      final start = m != null ? m.start : 0;
      final buf = StringBuffer(line.text.substring(start).trim());
      for (var j = li + 1;
          j < block.lines.length && buf.length < 1200;
          j++) {
        final t = block.lines[j].text.trim();
        if (_nextLabelLine.hasMatch(t)) break;
        buf.write(' ');
        buf.write(t);
      }
      final text = buf.toString().trim();
      if (text.length < 12) continue;
      final conf = _blend(0.9, line.meanConfidence);
      return FieldObservation(
        field: field,
        status: _toStatus(conf),
        value: text.length > 600 ? '${text.substring(0, 600)}…' : text,
        ocrConfidence: line.meanConfidence,
        fieldConfidence: conf,
        evidenceLabel: m?.group(0),
        evidenceText: line.text.trim(),
        relationship: voted ? 'classifier_block_capture' : 'block_capture',
        bbox: block.nbox,
        photoIndex: layout.photoIndex,
        method: ExtractMethod.blockCapture,
      );
    }
  }
  return FieldObservation(field: field, status: FieldStatus.notFound);
}

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s.split(' ').map((w) {
    if (w.isEmpty) return w;
    return w[0].toUpperCase() + w.substring(1).toLowerCase();
  }).join(' ');
}
