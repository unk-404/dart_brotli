import 'package:brotli_neo/brotli_neo.dart';
import 'package:test/test.dart';

void main() {
  test('public options and error types are exported', () {
    const options = BrotliEncodeOptions();
    expect(options.quality, 5);
    expect(options.lgwin, 22);
    expect(BrotliMode.generic, isA<BrotliMode>());

    final error = BrotliException(
      BrotliErrorCode.truncatedInput,
      'truncated',
      inputOffset: 3,
    );
    expect(error.offset, 3);
    expect(error.toString(), contains('truncatedInput'));
  });

  test('blit bytes types are re-exported', () {
    final bytes = Bytes.fromList([1, 2, 3]);
    expect(bytes, isA<BytesLike>());
    expect(bytes.length, 3);
  });
}
