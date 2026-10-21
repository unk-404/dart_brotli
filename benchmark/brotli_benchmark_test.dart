/// Core Brotli benchmarks for `package:benchmark_test`.
///
/// Four rows only: decode/encode on 1 MiB text and binary, at the default
/// quality 5. The same operations are timed for the authoritative Rust oracle
/// by `benchmark/bench-svg.toml`, so the card is a like-for-like comparison of
/// implementations, not a quality-level sweep.
///
/// Run through the CLI (assert-free, multiple compile targets):
///
/// ```sh
/// dart run benchmark_test --compile jit,aot,js,wasm \
///   --output jsonl benchmark/brotli_benchmark_test.dart
/// ```
///
/// `js` / `wasm` are executed by the CLI through `dart test -p node`.
library;

import 'package:benchmark_test/benchmark_test.dart';
import 'package:brotli_neo/compat.dart';
import 'package:test/test.dart';

import 'corpus.dart';

void main() {
  final text = makeText();
  final binary = makeBinary();
  const quality = BrotliEncodeOptions(quality: 5);
  final textStream = BrotliEncoderV2.encode(text, options: quality);
  final binaryStream = BrotliEncoderV2.encode(binary, options: quality);

  group('brotli core', () {
    benchmark('decode.text.1024KiB.q5', () {
      BrotliDecoderV2.decode(textStream);
    });
    benchmark('decode.binary.1024KiB.q5', () {
      BrotliDecoderV2.decode(binaryStream);
    });
    benchmark('encode.text.1024KiB.q5', () {
      BrotliEncoderV2.encode(text, options: quality);
    });
    benchmark('encode.binary.1024KiB.q5', () {
      BrotliEncoderV2.encode(binary, options: quality);
    });
  });
}
