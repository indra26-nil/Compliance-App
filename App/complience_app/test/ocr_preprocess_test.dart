import 'dart:typed_data';

import 'package:complience_app/services/ocr_preprocess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Future<Uint8List> makeJpg(int w, int h) async {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  // A dark bar so the image is not degenerate.
  img.fillRect(image, x1: 10, y1: 10, x2: w - 10, y2: h - 10,
      color: img.ColorRgb8(0, 0, 0));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

Future<img.Image> decode(Uint8List bytes) async => img.decodeImage(bytes)!;

void main() {
  test('small label photo gets 2x upscale', () async {
    final raw = await makeJpg(600, 400);
    final out = await prepareLabelImageBytes(raw);
    final decoded = await decode(out);
    expect(decoded.width, 1200);
    expect(decoded.height, 800);
  });

  test('mid-size shot doubles but respects the cap', () async {
    final raw = await makeJpg(1500, 1000);
    final out = await prepareLabelImageBytes(raw);
    final decoded = await decode(out);
    // 2x would be 3000px; capped at 3200 on the long side.
    expect(decoded.width, 3000);
    expect(decoded.height, 2000);
  });

  test('large photo is downscaled, never upscaled', () async {
    final raw = await makeJpg(4000, 3000);
    final out = await prepareLabelImageBytes(raw);
    final decoded = await decode(out);
    expect(decoded.width, lessThanOrEqualTo(3200));
    expect(decoded.width, lessThan(4000));
  });

  test('garbage bytes fall back to input', () async {
    final raw = Uint8List.fromList([0, 1, 2, 3, 4]);
    expect(await prepareLabelImageBytes(raw), raw);
  });
}
