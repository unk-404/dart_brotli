import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:test/test.dart';

void main() {
  test('blit-native one-shot round-trip', () {
    final input = Bytes.fromList(<int>[
      ...List<int>.generate(1024, (i) => i & 0x7F),
    ]);
    final compressed = brotliEncode(
      input,
      options: const BrotliEncodeOptions(quality: 1),
    );
    expect(compressed.length, greaterThan(0));
    final decoded = brotliDecode(compressed);
    expect(decoded.length, input.length);
    for (var i = 0; i < input.length; i++) {
      expect(decoded[i], input[i], reason: 'byte $i');
    }
  });

  test('BytesLike slices are accepted without copying', () {
    final backing = Bytes.fromList(List<int>.generate(4096, (i) => i & 0xFF));
    final slice = backing.slice(1000, 3000);
    final compressed = brotliEncode(slice);
    final decoded = brotliDecode(compressed);
    expect(decoded.length, slice.length);
    for (var i = 0; i < slice.length; i++) {
      expect(decoded[i], slice[i], reason: 'byte $i');
    }
  });

  test('empty input round-trips through the blit API', () {
    final compressed = brotliEncode(Bytes.empty);
    expect(compressed.length, 1);
    expect(brotliDecode(compressed).length, 0);
  });

  test('streaming decoder accepts BytesLike chunks', () {
    final input = Bytes.fromList(List<int>.generate(8192, (i) => i & 0xFF));
    final compressed = brotliEncode(input, options: const BrotliEncodeOptions(quality: 1));
    final decoder = BrotliDecoder();
    decoder.addInput(compressed.slice(0, compressed.length ~/ 2));
    decoder.addInput(compressed.slice(compressed.length ~/ 2));
    decoder.closeInput();
    final out = Uint8List(16384);
    final status = decoder.decode(out);
    expect(status, BrotliStatus.done);
    expect(decoder.bytesWritten, input.length);
  });
}
