/// Public v0.2.0 API smoke test (`package:brotli_neo/v2.dart`).
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_neo/v2.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'parity_vectors.dart';

void main() {
  test('v2 one-shot encode/decode round-trips', () {
    final input = Uint8List.fromList(
      List<int>.generate(4096, (i) => (i * 31 + i ~/ 7) & 0xFF),
    );
    final compressed = BrotliEncoderV2.encode(input);
    expect(compressed, isNotEmpty);
    expect(BrotliDecoderV2.decode(compressed), orderedEquals(input));
  });

  test('v2 encodeInto/decodeInto use caller buffers', () {
    final input = Uint8List.fromList(List<int>.generate(1024, (i) => i & 0xFF));
    final compressed = Uint8List(4096);
    final n = BrotliEncoderV2.encodeInto(compressed, input);
    expect(n, greaterThan(0));

    final output = Uint8List(input.length);
    final decoded = BrotliDecoderV2.decodeInto(
      output,
      Uint8List.sublistView(compressed, 0, n),
      expectedSize: input.length,
    );
    expect(decoded, input.length);
    expect(output, orderedEquals(input));
  });

  test('v2 encoder matches the committed VM parity hashes', () {
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
}
