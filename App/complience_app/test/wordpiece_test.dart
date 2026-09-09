import 'package:complience_app/services/wordpiece.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WordPieceTokenizer tok() => WordPieceTokenizer(
        vocab: {
          '[PAD]': 0,
          '[UNK]': 100,
          '[CLS]': 101,
          '[SEP]': 102,
          'hello': 1,
          'world': 2,
          'mrp': 3,
          'rs': 4,
          '##s': 5,
        },
        maxLen: 8,
      );

  test('encode pads ids and mask to maxLen', () {
    final enc = tok().encode('hello world');
    expect(enc.ids.length, 8);
    expect(enc.mask.length, 8);
    // [CLS] hello world [SEP] + 4x [PAD]
    expect(enc.ids.sublist(0, 4), [101, 1, 2, 102]);
    expect(enc.mask, [1, 1, 1, 1, 0, 0, 0, 0]);
  });

  test('encode handles empty and punctuation-only lines', () {
    final empty = tok().encode('   ');
    expect(empty.ids.length, 8);
    expect(empty.mask, [1, 1, 0, 0, 0, 0, 0, 0]);
    final punct = tok().encode('MRP Rs:');
    expect(punct.ids.length, 8);
    expect(punct.mask.length, 8);
  });

  test('encode truncates long lines to maxLen', () {
    final enc = tok().encode(List.filled(50, 'hello').join(' '));
    expect(enc.ids.length, 8);
    expect(enc.mask.length, 8);
    expect(enc.mask, everyElement(1));
  });
}
