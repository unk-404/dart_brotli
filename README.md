# brotli_neo

Pure Dart Brotli (RFC 7932) encoder and decoder.

![brotli_neo vs Rust brotli: decode/encode, 1 MiB, Q5](https://raw.githubusercontent.com/unk-404/dart_brotli/master/assets/benchmarks.svg)

- **v0.2.0 performance core**: a new raw `Uint8List` API with 64-bit
  accumulators on VM/AOT and a safe 32-bit Web fallback. AOT q5 throughput is
  ~90–160% of the Rust `brotli` oracle on the 1 MiB benchmark corpus.
- **Bold rewrite, legacy retained**: `package:brotli_neo/v2.dart` is the new
  primary API; the v0.1 blit-native and compat APIs remain available during
  migration.
- **Format coverage**: RFC 7932, large window, compound + prepared compound
  dictionaries, serialized shared dictionaries, streaming, qualities 0–11.
- **Pure Dart**: no native assets, no FFI in the codec; VM and Web (dart2js /
  dart2wasm) are supported.

> Status: 0.2.0. The decoder is byte-exact on all 22 RFC corpus pairs. The v2
> encoder/decoder pass the VM/AOT performance gate on the core corpus; Web
> correctness is covered by Chrome/Node 1 MiB tests.

## Quick start (v2)

```dart
import 'dart:typed_data';
import 'package:brotli_neo/v2.dart';

final compressed = BrotliEncoderV2.encode(raw);   // Uint8List
final restored = BrotliDecoderV2.decode(compressed);
```

`encodeInto` / `decodeInto` write into caller buffers:

```dart
final dst = Uint8List(estimatedSize);
final n = BrotliEncoderV2.encodeInto(dst, raw);
```

### Performance (AOT, 1 MiB, q5, this machine)

| operation | brotli_neo v2 | Rust oracle | ratio |
|---|---:|---:|---:|
| decode text | ~1.74 GB/s | ~1.10 GB/s | 158% |
| decode binary | ~1.11 GB/s | ~529 MB/s | 215% |
| encode text | ~244 MB/s | ~176 MB/s | 138% |
| encode binary | ~168 MB/s | ~120 MB/s | 140% |

Q0/Q1 are routed through the legacy greedy implementation where it is faster;
Q9/Q11 retain the quality tiers. The official gate is in
`benchmark/v2_native.json` + `tool/v2_bench.dart`; it can swing with host load,
so run it on an idle machine.

The legacy blit-native API remains available:

```dart
import 'package:brotli_neo/brotli_neo.dart';

final compressed = brotliEncode(Bytes.fromList([1, 2, 3, 4]));
final raw = brotliDecode(compressed);
```

## Installation

```yaml
dependencies:
  brotli_neo: ^0.2.0
```

For a legacy `Uint8List` API:

```dart
import 'package:brotli_neo/compat.dart';

final compressed = brotliCompress(Uint8List.fromList([1, 2, 3, 4]));
final raw = brotliDecompress(compressed);
```

A stream produced with a Rust-style compound dictionary can be decoded by
attaching the same bytes, and the encoder can produce one:

```dart
final raw = brotliDecompress(
  compressed,
  options: BrotliDecodeOptions(compoundDictionary: dictionary),
);
final compressed = brotliCompress(
  raw,
  options: BrotliEncodeOptions(compoundDictionary: dictionary),
);
```

Serialized shared dictionaries (`shared-brotli` format) are attached on decode:

```dart
final raw = brotliDecompress(
  compressed,
  options: BrotliDecodeOptions(sharedDictionary: serializedDictionary),
);
```

Streaming in both directions:

```dart
final encoder = BrotliEncoder();
encoder.add(Bytes.fromList([1, 2, 3, 4]));
encoder.flush();          // optional: emit the pending block, keep the stream open
encoder.finish();
final compressed = encoder.takeOutput();

final decoder = BrotliDecoder();
decoder.addInput(compressed);
decoder.closeInput();
final out = Uint8List(64 * 1024);
while (decoder.decode(out) != BrotliStatus.done) {
  // consume decoder.bytesWritten bytes of `out`
}
```

## Development

```sh
dart pub get
dart analyze
dart test
```

CI runs Ubuntu/Windows/macOS, Chrome browser tests, the JS/Wasm compiles and the
full suite against the Rust oracle (`tool/oracle_rust`). For the full local
suite build it and point `BROTLI_ORACLE` at the executable:

```sh
cargo build --release --locked --manifest-path tool/oracle_rust/Cargo.toml
BROTLI_ORACLE=tool/oracle_rust/target/release/brotli-oracle dart test
```

### Conformance data

`test/testdata` contains the 22 raw/compressed pairs and 23 malformed variants
from [google/brotli](https://github.com/google/brotli) `tests/testdata` (MIT).
`manifest.json` records sizes and SHA-256 hashes. See `NOTICE` for attribution.

### Benchmarks

Four core operations (decode/encode on 1 MiB text and binary at quality 5) are
measured with [`benchmark_test`](https://pub.dev/packages/benchmark_test) for
Dart JIT/AOT/JS/WASM and for the authoritative Rust `brotli` crate. The five
series are normalized to bytes/second and rendered with
[`benchcat`](https://github.com/unk-404/benchcat) into the card above.
The single CI workflow runs the tests first, then the benchmark, then commits
the changed SVG to `assets/` with `[skip ci]`.

## License

MIT. The static dictionary, context table and test corpus are derived from
Google's Brotli reference implementation (MIT); see `LICENSE` and `NOTICE`.
