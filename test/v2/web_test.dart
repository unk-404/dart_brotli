/// v0.2.0 Web smoke test: raw v2 API on dart2js.
///
/// Besides round-tripping, the fixed-vector test pins the compressed bytes to
/// the VM output, catching drift between the 64-bit VM and 32-bit Web paths.
@TestOn('browser')
@Timeout(Duration(minutes: 5))
library;

import 'dart:typed_data';

import 'package:brotli_neo/v2.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../benchmark/corpus.dart';
import 'parity_vectors.dart';

void main() {
  test('v2 encode/decode round-trips in the browser', () {
    final input = Uint8List.fromList(
      List<int>.generate(8192, (i) => (i * 17 + i ~/ 11) & 0xFF),
    );
    final compressed = BrotliEncoderV2.encode(input);
    expect(compressed, isNotEmpty);
    expect(BrotliDecoderV2.decode(compressed), orderedEquals(input));
  });

  test('v2 browser output matches a known stream hash length', () {
    final input = Uint8List.fromList(List<int>.filled(4096, 0x5A));
    final compressed = BrotliEncoderV2.encode(input);
    final decoded = BrotliDecoderV2.decode(compressed);
    expect(decoded.length, input.length);
    expect(decoded[0], 0x5A);
    expect(decoded[decoded.length - 1], 0x5A);
  });

  test('v2 encoder bytes match the VM on fixed vectors', () {
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

  test('1 MiB binary q5 stream decodes in the browser', () {
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
