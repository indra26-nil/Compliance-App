/// Zero-training line classifier (Option B): prototype kNN over MiniLM.
///
/// Each OCR line is embedded once (batched) and compared by cosine
/// similarity against a bank of prototype lines per field class. The
/// winning class + rescaled similarity becomes the line's vote, which
/// `field_extractor.dart` fuses with spatial/regex evidence.
///
/// Why this beats hand-regex for *classification*: embeddings see meaning
/// through OCR garble — "MPP Rs 15", "C022- 67740100 AND" and
/// "CAPITALFOODSPVT.LTD" still land near their class. Regexes stay as
/// *validators* (does the MRP candidate parse as a price?), never as the
/// sole decider.
///
/// Upgrade path (Option A) without touching callers: replace the prototype
/// bank with a fine-tuned classification head emitting the same
/// [LineLabel] shape — fusion code is unchanged.
///
/// Prototype embeddings are computed once (one batch at warm-up) and cached
/// in memory (~200 × 384 floats ≈ 300 KB).
library;

import 'embedder.dart';

/// Async embedding function (production: `MiniLMEmbedder.embedBatch`;
/// tests inject a stub).
typedef EmbedFn = Future<List<List<double>>> Function(List<String> texts);

/// One line's vote.
class LineLabel {
  const LineLabel({required this.field, required this.confidence});

  /// Field class (see [LineClassifier.classes]).
  final String field;

  /// Rescaled top similarity, 0..1. Not a calibrated probability —
  /// fusion treats it as one vote among spatial/pattern votes.
  final double confidence;
}

class LineClassifier {
  LineClassifier({EmbedFn? embedFn})
      : _embedFn = embedFn ?? MiniLMEmbedder.instance.embedBatch;

  /// Field classes. Keep in sync with `field_extractor.dart` fusion maps.
  static const List<String> classes = [
    'brand',
    'product_name',
    'slogan_other',
    'ingredients',
    'allergen',
    'nutrition',
    'net_qty',
    'mrp',
    'batch',
    'mfg_date',
    'exp_date',
    'manufacturer',
    'care',
    'fssai',
    'origin',
    'barcode',
    'other',
  ];

  final EmbedFn _embedFn;
  Map<String, List<List<double>>>? _prototypes;
  Future<void>? _initFuture;

  /// Reason the prototype bank failed to build (null when healthy).
  String? lastError;

  bool get isReady => _prototypes != null;

  /// Embeds the whole prototype bank in ONE batch (background, idempotent).
  Future<void> warmUp() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  /// Clears cached state and retries the prototype embedding.
  Future<void> retry() {
    _initFuture = null;
    lastError = null;
    return warmUp();
  }

  Future<void> _init() async {
    try {
      final texts = <String>[];
      final owners = <String>[];
      _prototypeBank.forEach((cls, lines) {
        for (final l in lines) {
          texts.add(l);
          owners.add(cls);
        }
      });
      final vecs = await _embedFn(texts);
      if (vecs.length != texts.length) {
        lastError =
            'Embedding returned ${vecs.length} vectors for ${texts.length} prototypes.';
        return;
      }
      final bank = <String, List<List<double>>>{};
      for (var i = 0; i < vecs.length; i++) {
        (bank[owners[i]] ??= []).add(vecs[i]);
      }
      _prototypes = bank;
      lastError = null;
    } catch (e) {
      _prototypes = null;
      var s = e.toString().replaceFirst(
          RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
      lastError = s.length > 220 ? '${s.substring(0, 220)}…' : s;
    }
  }

  /// Classifies [lines] in ONE batch → aligned [LineLabel]s.
  /// Returns all-`other`/0 when the model isn't ready (caller falls back).
  Future<List<LineLabel>> classify(List<String> lines) async {
    final bank = _prototypes;
    if (bank == null || bank.isEmpty || lines.isEmpty) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
    try {
      final vecs = await _embedFn(lines);
      if (vecs.length != lines.length) {
        return List.filled(
            lines.length, const LineLabel(field: 'other', confidence: 0));
      }
      return [for (final v in vecs) _nearest(bank, v)];
    } catch (_) {
      return List.filled(
          lines.length, const LineLabel(field: 'other', confidence: 0));
    }
  }

  LineLabel _nearest(
      Map<String, List<List<double>>> bank, List<double> v) {
    var bestCls = 'other';
    var bestSim = -2.0;
    var second = -2.0;
    bank.forEach((cls, vecs) {
      var clsBest = -2.0;
      for (final p in vecs) {
        final s = _dot(v, p);
        if (s > clsBest) clsBest = s;
      }
      if (clsBest > bestSim) {
        second = bestSim;
        bestSim = clsBest;
        bestCls = cls;
      } else if (clsBest > second) {
        second = clsBest;
      }
    });
    // Rescale: MiniLM cosines for related text sit ~0.5–0.9, unrelated
    // ~0.1–0.4. Small margin requirement breaks near-ties toward caution.
    var conf = ((bestSim - 0.35) / (0.9 - 0.35)).clamp(0.0, 1.0);
    if ((bestSim - second) < 0.03) conf *= 0.7;
    return LineLabel(field: bestCls, confidence: conf);
  }

  static double _dot(List<double> a, List<double> b) {
    var s = 0.0;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  // -------------------------------------------------------------------------
  // Prototype bank — B's "training data". Includes OCR-garble variants
  // observed in the field so classification survives garble.
  // -------------------------------------------------------------------------
  static const Map<String, List<String>> _prototypeBank = {
    'brand': [
      'SMITH & JONES',
      "Lay's",
      'TATA',
      'AMUL',
      'Parle',
      'PepsiCo',
      'CAPITAL FOODS',
      'Nestle',
      'Britannia',
      'Haldiram',
    ],
    'product_name': [
      'Tomato Ketchup',
      'Potato Chips',
      'Glucose Biscuits',
      'Detergent Powder',
      'Shampoo',
      'Whole Wheat Atta',
      'Mustard Oil',
      'Instant Noodles',
      'Green Tea',
      'Toothpaste',
    ],
    'slogan_other': [
      'Very Very Tasty!',
      'New improved taste!',
      'Eat healthy, live healthy!',
      'Taste the best!',
    ],
    'ingredients': [
      'INGREDIENTS: Water, Tomato Paste (25%), Sugar, Salt',
      'Ingredients: Wheat Flour, Sugar, Palm Oil',
      'Contains added flavours and colours',
      'INGREDIENTS Water Sugar Iodised Salt Spices',
      'Made with whole grains and honey',
    ],
    'allergen': [
      'ALLERGEN ADVICE: May contain Wheat, Nuts, Soy',
      'Contains Milk and Soy',
      'Allergy Advice: Contains Gluten',
      'May contain Sesame Seeds and Mustard',
    ],
    'nutrition': [
      'Energy 141 kcal, Protein 0.4g per serve',
      'Per 100g: Carbohydrate 32g, Sugars 30g',
      'Serving Size 15g, Servings per package 6',
      'Nutritional Information per 100 g',
      'Total Fat 1.2 g, Sodium 1049 mg',
      'RDA Per Serve 5%',
    ],
    'net_qty': [
      'NET QTY: 80g',
      'Net Weight: 90g',
      'NET WEIGHT 500 g',
      'Net Qty 1 kg',
      'NET CONTENTS: 200 ml',
      'NETUT 90g',
      'NET WEIGHT',
      'Net Qty: 250ml',
    ],
    'mrp': [
      'MRP Rs. 42.00',
      'MRP Rs: 15',
      'Maximum Retail Price Rs 250',
      'MRP ₹ 99 (inclusive of all taxes)',
      'M.R.P. Rs. 120',
      'MPP Rs 15',
      'MRP Rs',
      'Maximum Retail Price: Rs. 1,299',
    ],
    'batch': [
      'BATCH NO.: PP6E110015',
      'Batch No 44A771',
      'LOT NO: XJ22-09',
      'BATCH NUMBER',
      'B.No. AB1234CD',
      'Code: PKD22A1',
    ],
    'mfg_date': [
      'DATE OF MFG.: 11/05/26',
      'Mfg Date: 01/2024',
      'Manufactured On: Mar 2025',
      'MFD 12-11-2024',
      'DATE OF MFG',
      'PKD: 05/2025',
    ],
    'exp_date': [
      'USE BY: 10/05/27',
      'Best Before 6 Months from Manufacture',
      'Expiry Date: 12/2026',
      'EXP 30-09-25',
      'Best before: Jan 2026',
      'USE 8Y 10/05/27',
      'Use By Date',
    ],
    'manufacturer': [
      'BRAND OWNED & MARKETED BY: CAPITAL FOODS PVT. LTD.',
      'Mfd. by PepsiCo India Holdings Pvt. Ltd.',
      'Manufactured by: Vrinda Agro, Nashik',
      'MKT BY: Tata Consumer Products, Mumbai',
      'Marketed by CAPITAL FOODS PVT LTD',
      'MUMBAI - 400 102.',
      'Packed by: Pan Foods, Panipat (Haryana)',
      'Imported by: Global Imports, Delhi',
      'BRAND OWNED&MARKETEDBY CAPITALFOODSPVT.LTD',
    ],
    'care': [
      'C022- 67740100 AND',
      '022-67740100',
      '1800224020',
      'Toll Free: 1800-419-0000',
      'CUSTOMERCARE@CAPITALFOODS.CO.IN',
      'CONSUMER.FEEDBACK@PEPSICO.COM',
      'For complaints contact Manager Consumer Care',
      'Email: care@brand.co.in, Phone: 18001234567',
    ],
    'fssai': [
      'FSSAI Lic. No. 10013022001865',
      'Lic. No. 10012083000110',
      'FSSAI License Number 10019022001234',
      'FSSL 10012043001234',
    ],
    'origin': [
      'Made in India',
      'Country of Origin: India',
      'Product of Thailand',
      'FOR SALE IN INDIA, NEPAL AND BHUTAN ONLY',
    ],
    'barcode': [
      '8 901595 863020',
      '8901030543210',
      '8 901234 567890',
    ],
    'other': [
      'Store in a cool, dry and hygienic place',
      'Keep refrigerated after opening',
      'Do not consume if packet is bloated',
      'www.capitalfoods.co.in',
      'For sale in India only',
      'Shake well before use',
    ],
  };
}

/// Cosine similarity between L2-normalized vectors (test helper).
double cosineSim(List<double> a, List<double> b) =>
    LineClassifier._dot(a, b);
