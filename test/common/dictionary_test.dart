import 'package:brotli_neo/src/common/dictionary.dart';
import 'package:brotli_neo/src/common/dictionary_data.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('dictionary payload size and hash', () {
    expect(kDictionaryData.length, dictionarySize);
    expect(
      sha256.convert(kDictionaryData).toString(),
      '20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70',
    );
  });

  test('size bits and offsets cover the payload', () {
    expect(kDictionarySizeBitsByLength.length, 32);
    expect(dictionaryOffsets[4], 0);
    expect(dictionaryOffsets[5], 4096);
    expect(dictionaryOffsets[6], 9216);
    expect(dictionaryOffsets[25], dictionarySize);
  });

  test('dictionary word views are zero-copy and in range', () {
    final word = dictionaryWord(4, 0);
    expect(word.length, 4);
    expect(word.asUint8List().length, 4);
    expect(word[0], kDictionaryData[0]);
    expect(dictionaryWordOffset(24, 0), dictionaryOffsets[24]);
  });
}
