/// Node parity check for the v2 API (same fixed vectors as the Chrome test).
///
/// `test/v2/web_test.dart` is browser-only (`@TestOn('browser')`), so this file
/// exercises the compiled JavaScript backend through `dart test -p node`.
@TestOn('node')
@Timeout(Duration(minutes: 5))
library;

import 'package:brotli_neo/v2.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../benchmark/corpus.dart';
import 'parity_vectors.dart';

void main() {
  test('v2 encoder bytes match the VM on fixed vectors (node)', () {
    for (final vector in parityVectors) {
      final input = vector.input();
      final compressed = BrotliEncoderV2.encode(
        input,
        options: BrotliEncodeOptions(quality: vector.quality),
      );
      expect(
        sha256.convert(compressed).toString(),
        vector.sha256,
        reason:
            'kind=${vector.kind} size=${vector.size} '
            'q=${vector.quality}',
      );
      expect(BrotliDecoderV2.decode(compressed), orderedEquals(input));
    }
  });

  test('1 MiB binary q5 stream decodes on Node', () {
    final input = makeBinary();
    final compressed = BrotliEncoderV2.encode(
      input,
      options: const BrotliEncodeOptions(quality: 5),
    );
    expect(compressed.length, lessThan(input.length));
    final decoded = BrotliDecoderV2.decode(compressed);
    expect(decoded.length, input.length);
    expect(decoded, orderedEquals(input));
  });
}
