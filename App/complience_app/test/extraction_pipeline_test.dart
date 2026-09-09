/// Extraction + three-state compliance tests from the two real test cases.
///
/// Fixtures model PaddleOCR token output (text + confidence + pixel box at
/// 1000×1000) for:
///  * Smith & Jones Tomato Ketchup back panel (dot-matrix batch/dates/MRP,
///    glued phone+email line, bottom barcode) — ground truth read from the
///    real photo.
///  * Lay's-style panel (trademark sentence, NET QTY 80g, currency MRP,
///    14-digit FSSAI, 13-digit barcode that must NOT become MRP).
///
/// Plus the "never" invariants and the FAIL-vs-UNVERIFIED gating.
import 'package:complience_app/services/field_extractor.dart';
import 'package:complience_app/services/ocr_layout.dart';
import 'package:complience_app/services/ocr_tokens.dart';
import 'package:complience_app/services/rule_engine.dart';
import 'package:flutter_test/flutter_test.dart';

OcrToken t(String text, double conf, double x, double y, double w, double h,
        [int photo = 0]) =>
    OcrToken(
      text: text,
      ocrConfidence: conf,
      box: PixelBox(x, y, x + w, y + h),
      photoIndex: photo,
    );

PageLayout lay(List<OcrToken> tokens) =>
    buildLayout(tokens, imgW: 1000, imgH: 1000);

const adequate = ExtractionQuality(
    meanConfidence: 0.86, totalChars: 1200, regionCount: 40, photoCount: 1);
const weak = ExtractionQuality(
    meanConfidence: 0.4, totalChars: 50, regionCount: 3, photoCount: 1);

// ---------------------------------------------------------------------------
// Smith & Jones fixture (ground truth from the real back-panel photo)
// ---------------------------------------------------------------------------

List<OcrToken> smithJones() => [
      t('SMITH & JONES', 0.98, 100, 20, 800, 120),
      t('Tomato Ketchup', 0.97, 300, 150, 400, 80),
      t('INGREDIENTS: Water, Tomato Paste (25%), Sugar,', 0.93, 80, 240, 840, 30),
      t('Iodised Salt, Acidity Regulator (INS 260),', 0.90, 80, 275, 520, 25),
      t('ALLERGEN ADVICE: May contain Wheat, Nuts,', 0.92, 80, 310, 840, 25),
      t('BATCH NO.:', 0.90, 80, 420, 220, 25),
      t('PP6E110015', 0.62, 320, 420, 330, 30),
      t('MRP Rs:', 0.90, 80, 455, 170, 25),
      t('15', 0.60, 270, 455, 70, 25),
      t('(Rs. 0.16/g)', 0.70, 350, 455, 200, 25),
      t('DATE OF MFG.:', 0.88, 80, 490, 220, 25),
      t('11/05/26', 0.60, 320, 490, 240, 30),
      t('USE BY:', 0.88, 80, 525, 140, 25),
      t('10/05/27', 0.60, 240, 525, 230, 30),
      t('BRAND OWNED & MARKETED BY:', 0.90, 80, 560, 270, 25),
      t('CAPITAL FOODS PVT. LTD.,', 0.90, 360, 560, 590, 25),
      t('VILLA CAPITAL, SADHANA COMPOUND,', 0.88, 80, 590, 870, 25),
      t('MUMBAI - 400 102.', 0.88, 80, 620, 520, 25),
      t('Lic. No. 10013022001865', 0.88, 620, 588, 330, 24),
      t('FOR ANY COMPLAINT CONTACT MANAGER CONSUMER', 0.85, 80, 650, 870, 25),
      t('C022- 67740100 AND', 0.70, 80, 680, 420, 25),
      t('CUSTOMERCARE@CAPITALFOODS.CO.IN', 0.85, 510, 680, 440, 25),
      t('NET', 0.90, 80, 715, 220, 25),
      t('WEIGHT:', 0.90, 80, 745, 220, 25),
      t('90g', 0.95, 320, 715, 100, 55),
      t('8 901595 863020', 0.97, 80, 800, 870, 30),
      t('Smith & Jones is Registered Trademark of', 0.90, 80, 900, 870, 25),
      t('Capital Foods Pvt. Ltd. India.', 0.90, 80, 930, 520, 25),
    ];

// ---------------------------------------------------------------------------
// Lay's-style fixture
// ---------------------------------------------------------------------------

List<OcrToken> laysStyle() => [
      t("Lay's", 0.98, 100, 30, 400, 90),
      t('Potato Chips', 0.97, 100, 130, 500, 80),
      t("Lay's is a Trade Mark of PepsiCo, Inc.", 0.90, 80, 230, 820, 30),
      t('NET QTY:', 0.90, 80, 300, 220, 25),
      t('80g', 0.94, 320, 300, 100, 25),
      t('MRP Rs. 42.00', 0.90, 80, 340, 420, 25),
      t('(inclusive of all taxes)', 0.88, 300, 340, 400, 25),
      t('Mfd. by PepsiCo India Holdings Pvt. Ltd.,', 0.90, 80, 380, 870, 25),
      t('SCO 29-30, Sector 17, Chandigarh 160017', 0.88, 80, 410, 620, 25),
      t('1800224020', 0.85, 80, 450, 420, 25),
      t('CONSUMER.FEEDBACK@PEPSICO.COM', 0.90, 520, 450, 430, 25),
      t('FSSAI Lic. No. 10012083000110', 0.90, 80, 490, 870, 25),
      t('1001208300010', 0.96, 80, 800, 870, 30),
    ];

void main() {
  group('Smith & Jones back panel', () {
    late ExtractedProduct p;
    setUp(() => p = extractProduct([lay(smithJones())]));

    test('brand + product name from prominence, not ingredients', () {
      expect(p.brand.value, 'SMITH & JONES');
      expect(p.productName.value, 'Tomato Ketchup');
      expect(p.genericName.value, 'Tomato Ketchup');
    });

    test('net quantity 90 g (not BATCH NO. garbage)', () {
      expect(p.netQty.status, FieldStatus.found);
      expect(p.netQty.data['value'], 90);
      expect(p.netQty.data['unit'], 'g');
    });

    test('MRP is 15, not the 0.16 unit-price in parentheses', () {
      expect(p.mrp.status, FieldStatus.found);
      expect((p.mrp.data['value'] as num).toDouble(), 15);
    });

    test('batch value, not the label word', () {
      expect(p.batch.status, FieldStatus.found);
      expect(p.batch.value, 'PP6E110015');
    });

    test('dot-matrix dates with label classification', () {
      expect(p.mfg.status, FieldStatus.found);
      expect(p.mfg.value, contains('11/05/26'));
      expect(p.exp.status, FieldStatus.found);
      expect(p.exp.value, contains('10/05/27'));
    });

    test('manufacturer block excludes the USE BY line', () {
      expect(p.manufacturer.status, FieldStatus.found);
      expect(p.manufacturer.value, contains('CAPITAL FOODS'));
      expect(p.manufacturer.evidenceText, isNot(contains('USE')));
    });

    test('phone + email detected independently on a glued line', () {
      expect(p.carePhone.status, FieldStatus.found);
      expect(p.carePhone.value, '022-67740100');
      expect(p.careEmail.status, FieldStatus.found);
      expect(p.careEmail.value, 'CUSTOMERCARE@CAPITALFOODS.CO.IN');
    });

    test('FSSAI label-gated; barcode recorded separately', () {
      expect(p.fssai.status, FieldStatus.found);
      expect(p.fssai.value, '10013022001865');
      expect(p.barcode.value, '8901595863020');
    });

    test('rules: no FAILs on an adequate capture', () {
      final report = const RuleEngine().check(p,
          category: ProductCategory.food,
          quality: adequate,
          combinedText: lay(smithJones()).debugText);
      final fails = report.results.where((r) => r.isFail).toList();
      expect(fails, isEmpty,
          reason: 'failed: ${fails.map((f) => f.code).join(', ')}');
      expect(report.verdict != Verdict.nonCompliant, isTrue);
    });
  });

  group('Lay\'s-style panel', () {
    late ExtractedProduct p;
    setUp(() => p = extractProduct([lay(laysStyle())]));

    test('trademark sentence is never the product name', () {
      expect(p.productName.value, 'Potato Chips');
      expect(p.brand.value, "Lay's");
    });

    test('net qty 80 g; MRP 42 with currency (never the barcode)', () {
      expect(p.netQty.data['value'], 80);
      expect((p.mrp.data['value'] as num).toDouble(), 42);
    });

    test('barcode quarantined: recorded, never MRP/FSSAI', () {
      expect(p.barcode.value, '1001208300010');
      expect(p.mrp.value, isNot(contains('1001208300010')));
      expect(p.fssai.value, '10012083000110');
    });

    test('toll-free-style phone + email without care label', () {
      expect(p.carePhone.value, '1800224020');
      expect(p.careEmail.value, 'CONSUMER.FEEDBACK@PEPSICO.COM');
    });
  });

  group('never-invariants', () {
    test('bare long digits are never MRP', () {
      final p = extractProduct([
        lay([t('8901595863020', 0.96, 80, 800, 870, 30)])
      ]);
      expect(p.mrp.status, isNot(FieldStatus.found));
      expect(p.barcode.status, FieldStatus.found);
    });

    test('batch label alone is unverified-or-missing, never found', () {
      final p = extractProduct([
        lay([t('BATCH NUMBER', 0.9, 80, 420, 300, 25)])
      ]);
      expect(p.batch.status, isNot(FieldStatus.found));
    });

    test('ingredients block is never the product name', () {
      final p = extractProduct([
        lay([
          t('INGREDIENTS: Water, Sugar, Salt, Spices and Condiments.', 0.92,
              80, 240, 840, 60),
        ])
      ]);
      expect(p.productName.status, isNot(FieldStatus.found));
    });
  });

  group('three-state gating', () {
    test('weak capture gap is UNVERIFIED, not FAIL', () {
      final p = extractProduct([lay([t('hello', 0.4, 10, 10, 100, 20)])]);
      final report = const RuleEngine()
          .check(p, quality: weak, combinedText: 'hello');
      final mfg = report.results
          .firstWhere((r) => r.code == 'LM-R6-DATE-MFG');
      expect(mfg.status, RuleStatus.unverified);
      expect(mfg.action, isNotNull);
      expect(report.verdict, Verdict.needsReview);
    });

    test('adequate capture gap is FAIL', () {
      final p = extractProduct([
        lay([
          t('Just some marketing text here today', 0.9, 80, 100, 600, 30),
          t('More tasty words about snacks and joy', 0.9, 80, 140, 600, 30),
          t('Even more words filling the panel nicely', 0.9, 80, 180, 600, 30),
          t('Words words words for adequate coverage', 0.9, 80, 220, 600, 30),
          t('Another line of perfectly readable text', 0.9, 80, 260, 600, 30),
          t('Yet another line with many characters', 0.9, 80, 300, 600, 30),
          t('Continuing the wall of readable words', 0.9, 80, 340, 600, 30),
          t('Almost done with this readable panel', 0.9, 80, 380, 600, 30),
          t('Final line of the readable capture test', 0.9, 80, 420, 600, 30),
        ])
      ]);
      final report = const RuleEngine().check(p,
          quality: adequate, combinedText: 'wall of text');
      final mfg = report.results
          .firstWhere((r) => r.code == 'LM-R6-DATE-MFG');
      expect(mfg.status, RuleStatus.fail);
    });

    test('label-seen-but-unread date is UNVERIFIED even when adequate', () {
      final p = extractProduct([
        lay([
          t('DATE OF MFG.:', 0.88, 80, 490, 220, 25),
          t('xx/yy/zz', 0.3, 320, 490, 200, 25),
          t('Some other readable declaration text here', 0.9, 80, 100, 600, 30),
          t('More filler text to pad the capture quality', 0.9, 80, 140, 600, 30),
          t('Additional filler words for coverage length', 0.9, 80, 180, 600, 30),
          t('Further filler to reach adequate thresholds', 0.9, 80, 220, 600, 30),
          t('Last filler line of readable characters ok', 0.9, 80, 260, 600, 30),
        ])
      ]);
      final report = const RuleEngine().check(p,
          quality: adequate, combinedText: 'DATE OF MFG.: xx/yy/zz');
      final mfg = report.results
          .firstWhere((r) => r.code == 'LM-R6-DATE-MFG');
      expect(mfg.status, RuleStatus.unverified);
    });
  });

  group('layout', () {
    test('adjacent lines keep separate identity (no gluing)', () {
      final layout = lay([
        t('USE BY:', 0.88, 80, 525, 140, 25),
        t('BRAND OWNED & MARKETED BY:', 0.9, 80, 560, 270, 25),
      ]);
      expect(layout.lines.length, 2);
      expect(layout.lines[0].text, 'USE BY:');
    });

    test('legacy v1 reports still parse', () {
      final legacy = ExtractedProduct.fromJson({
        'genericName': 'Potato Chips',
        'mrpRaw': 'Rs. 42',
        'mrpValue': 42,
        'fieldConfidence': {'genericName': 0.8},
        'evidence': {'genericName': 'Potato Chips'},
        'sourcePhoto': {'genericName': 0},
      });
      expect(legacy.genericName.value, 'Potato Chips');
      expect(legacy.mrp.data['value'], 42);
    });
  });
}
