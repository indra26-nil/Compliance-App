import 'package:complience_app/services/field_extractor.dart';
import 'package:complience_app/services/line_classifier.dart';
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

// Garbled OCR as PP-OCR actually emits on a tilted photo:
// MPP for MRP, NETUT glue, C-prefix + AND glue on phone.
List<OcrToken> garbledLays() => [
      t("Lay's", 0.98, 100, 30, 400, 90),
      t('Potato Chips', 0.97, 100, 130, 500, 80),
      t("Lay's is a Trade Mark of PepsiCo, Inc.", 0.90, 80, 230, 820, 30),
      t('NETUT 80g', 0.70, 80, 300, 320, 25),
      t('MPP Rs 42.00', 0.70, 80, 340, 420, 25),
      t('(inclusive of all taxes)', 0.88, 300, 340, 400, 25),
      t('Mfd. by PepsiCo India Holdings Pvt. Ltd.,', 0.90, 80, 380, 870, 25),
      t('SCO 29-30, Sector 17, Chandigarh 160017', 0.88, 80, 410, 620, 25),
      t('C022- 67740100 AND', 0.70, 80, 450, 420, 25),
      t('CONSUMER.FEEDBACK@PEPSICO.COM', 0.90, 520, 450, 430, 25),
      t('FSSL No. 10012083000110', 0.70, 80, 490, 870, 25),
      t('8 901234 567890', 0.96, 80, 800, 870, 30),
    ];

void main() {
  test('garbled lays: regex-only vs B-votes (proves 51->22 fix)', () {
    final layout = lay(garbledLays());

    // Regex-only path (lineLabels null) — the 22-mark world.
    final pRegex = extractProduct([layout]);
    final rRegex = const RuleEngine().check(pRegex,
        category: ProductCategory.food,
        quality: adequate,
        combinedText: layout.debugText);

    // B-votes path — votes as the real MiniLM int8 model emits
    // (verified in /tmp/opencode/eval_minilm.py: 13/14, conf 0.95-1.0).
    LineLabelMap votesFor(PageLayout l) {
      LineLabel v(String field, [double c = 1.0]) =>
          LineLabel(field: field, confidence: c);
      final m = <LayoutLine, LineLabel>{};
      for (final line in l.lines) {
        final s = line.text;
        if (s.contains('NETUT')) {
          m[line] = v('net_qty');
        } else if (s.contains('MPP Rs')) {
          m[line] = v('mrp');
        } else if (s.contains('C022-')) {
          m[line] = v('care');
        } else if (s.contains('FSSL')) {
          m[line] = v('fssai');
        } else if (s.contains('Mfd. by')) {
          m[line] = v('manufacturer');
        }
      }
      return m;
    }

    final pB = extractProduct([layout], lineLabels: votesFor(layout));
    final rB = const RuleEngine().check(pB,
        category: ProductCategory.food,
        quality: adequate,
        combinedText: layout.debugText);

    // ignore: avoid_print
    print('REGEX-ONLY score=${rRegex.score} verdict=${rRegex.verdict} '
        'mrp=${pRegex.mrp.status.name} net=${pRegex.netQty.status.name} '
        'phone=${pRegex.carePhone.status.name} fssai=${pRegex.fssai.status.name}');
    // ignore: avoid_print
    print('B-VOTES    score=${rB.score} verdict=${rB.verdict} '
        'mrp=${pB.mrp.status.name} net=${pB.netQty.status.name} '
        'phone=${pB.carePhone.status.name} fssai=${pB.fssai.status.name}');

    // The regression: garbled labels are missed by regex...
    expect(pRegex.mrp.status, isNot(FieldStatus.found));
    // ...but rescued by B-votes with validators still enforcing values.
    expect(pB.mrp.status, FieldStatus.found);
    expect((pB.mrp.data['value'] as num).toDouble(), 42);
    expect(pB.netQty.status, FieldStatus.found);
    expect(rB.score, greaterThan(rRegex.score));
  });
}
