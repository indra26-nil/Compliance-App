import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_paddle_ocr_v5/flutter_paddle_ocr_v5.dart';
import 'package:path_provider/path_provider.dart';

/// Copies the bundled PP-OCRv5 ONNX assets into an on-device directory and
/// returns a [ModelSource.filePaths] the native backend can consume.
///
/// The native OCR engine needs absolute file paths — it cannot read Flutter
/// assets directly — so on first launch we copy:
///   assets/models/PP-OCRv5_mobile_det.onnx
///   assets/models/PP-OCRv5_mobile_rec.onnx
///   assets/models/ppocr_keys_v5_utf8.txt
/// into `<app-support>/paddle_ocr/`. Subsequent launches reuse the copies
/// (fully offline, no download needed).
Future<ModelSource> prepareBundledModelSource({
  void Function(String status)? onStatus,
}) async {
  const detAsset = 'assets/models/PP-OCRv5_mobile_det.onnx';
  const recAsset = 'assets/models/PP-OCRv5_mobile_rec.onnx';
  const dictAsset = 'assets/models/ppocr_keys_v5_utf8.txt';

  final supportDir = await getApplicationSupportDirectory();
  final modelsDir = Directory('${supportDir.path}/paddle_ocr')
    ..createSync(recursive: true);

  final detFile = File('${modelsDir.path}/PP-OCRv5_mobile_det.onnx');
  final recFile = File('${modelsDir.path}/PP-OCRv5_mobile_rec.onnx');
  final dictFile = File('${modelsDir.path}/ppocr_keys_v5_utf8.txt');

  Future<void> copyIfMissing(String asset, File target) async {
    if (target.existsSync() && await target.length() > 0) return;
    onStatus?.call('Preparing ${target.path.split('/').last}...');
    final data = await rootBundle.load(asset);
    await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  await copyIfMissing(detAsset, detFile);
  await copyIfMissing(recAsset, recFile);
  await copyIfMissing(dictAsset, dictFile);

  return ModelSource.filePaths(
    det: detFile.path,
    rec: recFile.path,
    dict: dictFile.path,
  );
}
