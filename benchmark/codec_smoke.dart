/// Minimal, web-safe codec smoke test for `dart compile` targets.
///
/// This program covers the public compat API (one-shot encode/decode plus the
/// push streaming decoder) and throws on any mismatch, so it is useful as:
///
/// ```sh
/// dart run benchmark/codec_smoke.dart
/// dart compile exe benchmark/codec_smoke.dart -o build/benchmark_test/smoke/codec_smoke.exe
/// dart compile js  benchmark/codec_smoke.dart -o build/benchmark_test/smoke/codec_smoke.js
/// dart compile wasm benchmark/codec_smoke.dart -o build/benchmark_test/smoke/codec_smoke.wasm
/// node build/benchmark_test/smoke/codec_smoke.js
/// ```
///
/// It imports no `dart:io`, so the same entry point compiles for VM, JS and
/// Wasm.
library;

import 'dart:typed_data';

import 'package:brotli_neo/compat.dart';

void main() {
  final input = Uint8List(1 << 14);
  for (var i = 0; i < input.length; i++) {
    input[i] = (i * 31 + (i >> 5) + 7) & 0xFF;
  }

  final compressed = brotliCompress(
    input,
    options: const BrotliEncodeOptions(quality: 5),
  );
  final decoded = brotliDecompress(compressed);
  _expectEqual(decoded, input, 'one-shot round-trip');

  // Streaming decode in small chunks, small output slices: exercises
  // needMoreInput / needMoreOutput on the compiled target.
  final decoder = BrotliDecoder();
  final builder = BytesBuilder(copy: false);
  final output = Uint8List(97);
  var offset = 0;
  var closed = false;
  var wantInput = true;
  while (true) {
    if (wantInput) {
      if (offset < compressed.length) {
        final end = offset + 3 < compressed.length
            ? offset + 3
            : compressed.length;
        decoder.addInput(Uint8List.sublistView(compressed, offset, end));
        offset = end;
      } else if (!closed) {
        decoder.closeInput();
        closed = true;
      }
      wantInput = false;
    }
    final status = decoder.decode(output);
    if (decoder.bytesWritten > 0) {
      builder.add(output.sublist(0, decoder.bytesWritten));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      if (closed) {
        throw StateError('decoder requested input after closeInput');
      }
      wantInput = true;
    }
  }
  _expectEqual(builder.takeBytes(), input, 'streaming round-trip');

  print(
    'codec smoke OK: ${input.length} -> ${compressed.length} -> '
    '${decoded.length} bytes',
  );
}

void _expectEqual(Uint8List actual, Uint8List expected, String what) {
  if (actual.length != expected.length) {
    throw StateError('$what: length ${actual.length} != ${expected.length}');
  }
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      throw StateError('$what: byte $i ${actual[i]} != ${expected[i]}');
    }
  }
}
