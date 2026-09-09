/// Review-flow tests: staged pipeline (modes, line edits, corrections).
import 'package:complience_app/services/field_extractor.dart';
import 'package:complience_app/services/ocr_layout.dart';
import 'package:complience_app/services/ocr_postprocess.dart';
import 'package:complience_app/services/ocr_tokens.dart';
import 'package:complience_app/services/rule_engine.dart';
import 'package:complience_app/services/scan_pipeline.dart';
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

OcrBundle bundle(List<PageLayout> layouts) => OcrBundle(
      imagePaths: const ['p0.jpg'],
      layouts: layouts,
      originals: const {},
      origSizes: const {},
      meanConfidence: 0.9,
      regionSum: 10,
    );

void main() {
  group('staged pipeline', () {
    test('regex mode extracts without classifier', () async {
      final layouts = [
        lay([
          t('NET QTY:', 0.9, 80, 300, 220, 25),
          t('80g', 0.94, 320, 300, 100, 25),
          t('MRP Rs. 42.00', 0.9, 80, 340, 420, 25),
        ])
      ];
      final pending = await const ScanPipeline().extractWithMode(
        ocr: bundle(layouts),
        productName: 'Test',
        category: ProductCategory.general,
        mode: ExtractionMode.regex,
      );
      expect(pending.product.netQty.status, FieldStatus.found);
      expect(pending.product.mrp.status, FieldStatus.found);
      expect(pending.mode, ExtractionMode.regex);
    });

    test('ensemble degrades to regex when MiniLM unavailable', () async {
      final layouts = [
        lay([
          t('NET QTY:', 0.9, 80, 300, 220, 25),
          t('80g', 0.94, 320, 300, 100, 25),
        ])
      ];
      final pending = await const ScanPipeline().extractWithMode(
        ocr: bundle(layouts),
        productName: 'Test',
        category: ProductCategory.general,
        mode: ExtractionMode.ensemble,
      );
      // Test env has no ONNX backend: classifier not ready → regex result.
      expect(pending.product.netQty.status, FieldStatus.found);
      expect(pending.modeNote, contains('regex'));
    });

    test('line edits preserve boxes, change text', () {
      final layouts = [
        lay([
          t('MPP Rs 42.00', 0.7, 80, 340, 420, 25),
          t('80g', 0.94, 320, 300, 100, 25),
        ])
      ];
      final before = layouts.first.lines[1].box;
      final edited =
          ScanPipeline.applyLineEdits(layouts, const {'0:1': 'MRP Rs. 42.00'});
      expect(edited.first.lines[1].text, 'MRP Rs. 42.00');
      // PixelBox has no value equality — compare its debug form.
      expect(edited.first.lines.first.box.toString(), before.toString());
      expect(edited.first.lines[0].text, '80g');
      // Empty edits return identical layouts.
      expect(identical(
          ScanPipeline.applyLineEdits(layouts, const {}), layouts), isTrue);
    });

    test('edited MRP label extracts in regex mode', () async {
      final layouts = [
        lay([t('MPP Rs 42.00', 0.7, 80, 340, 420, 25)])
      ];
      final plain = await const ScanPipeline().extractWithMode(
        ocr: bundle(layouts),
        productName: 'Test',
        category: ProductCategory.general,
        mode: ExtractionMode.regex,
      );
      expect(plain.product.mrp.status, isNot(FieldStatus.found));
      final fixed = await const ScanPipeline().extractWithMode(
        ocr: bundle(layouts),
        productName: 'Test',
        category: ProductCategory.general,
        mode: ExtractionMode.regex,
        lineEdits: const {'0:0': 'MRP Rs. 42.00'},
      );
      expect(fixed.product.mrp.status, FieldStatus.found);
    });
  });

  group('field corrections', () {
    test('officer MRP value re-parsed for rule engine', () {
      final base = extractProduct([
        lay([t('hello', 0.4, 10, 10, 100, 20)])
      ]);
      final corrected =
          applyFieldCorrections(base, const {'mrp': 'Rs. 99'});
      expect(corrected.mrp.status, FieldStatus.found);
      expect(corrected.mrp.value, 'Rs. 99');
      expect((corrected.mrp.data['value'] as num).toDouble(), 99);
      expect(corrected.mrp.method, ExtractMethod.manualEntry);
    });

    test('clearing a field marks it notFound', () {
      final base = extractProduct([
        lay([
          t('MRP Rs. 42.00', 0.9, 80, 340, 420, 25),
        ])
      ]);
      expect(base.mrp.status, FieldStatus.found);
      final cleared = applyFieldCorrections(base, const {'mrp': '  '});
      expect(cleared.mrp.status, FieldStatus.notFound);
    });

    test('manufacturer address edits land in data', () {
      final base = extractProduct([
        lay([
          t('Mfd. by PepsiCo India Holdings Pvt. Ltd.,', 0.9, 80, 380, 870,
              25),
        ])
      ]);
      final corrected = applyFieldCorrections(
          base, const {'manufacturerAddress': 'Chandigarh 160017'});
      expect(corrected.manufacturer.data['address'], 'Chandigarh 160017');
    });
  });

  group('ocr clean helper', () {
    test('cleanLine restores glued label spacing', () {
      expect(OcrPostprocess.cleanLine('ADVICE:Contains Soy'),
          contains('ADVICE: Contains'));
    });
  });
}
