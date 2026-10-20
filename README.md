# brotli_neo

Pure Dart Brotli (RFC 7932) encoder and decoder.

![brotli_neo vs Rust brotli: decode/encode, 1 MiB, Q5](https://raw.githubusercontent.com/unk-404/dart_brotli/master/assets/benchmarks.svg)

- **Pure Dart**: no native assets, no FFI in the codec, works on the VM and on
  the web (dart2js / dart2wasm).
- **Zero-copy bytes**: first-class [`blit`](https://pub.dev/packages/blit)
  integration (`Bytes`, `BytesLike`, `BytesMut`, `BytesFile`).
- **Implemented**: RFC 7932 decoder (static dictionary, 121 transforms,
  compound-dictionary decode, large-window decode), encoder quality 0–11 with
  block splitting, 13-context modeling, static-dictionary matching, RLE
  histograms, guided parsing and large-window encoding; streaming encoder and
  decoder; blit-native, compat and file APIs.
- **Remaining**: encoder-side compound/shared dictionary attachment (the
  decoder already accepts Rust `--dictionary` streams).
- **Two API layers**:
  - `brotli_neo.dart`: blit-native (`BytesLike` in, `Bytes` out);
  - `compat.dart`: `Uint8List`/`List<int>`, `dart:convert` codec and
    `package:brotli`-style functions.

> Status: 0.1.0. The decoder is byte-exact on all 22 RFC corpus pairs; the
> encoder covers quality 0–11 and the public streaming/compat/file APIs are
> usable. CI runs the VM, browser, Wasm and Rust-oracle suites.

## Getting started

```yaml
dependencies:
  brotli_neo: ^0.1.0
```

```dart
import 'package:brotli_neo/brotli_neo.dart';

final compressed = brotliEncode(Bytes.fromList([1, 2, 3, 4]));
final raw = brotliDecode(compressed);
```

For a `Uint8List` API:

```dart
import 'package:brotli_neo/compat.dart';

final compressed = brotliCompress(Uint8List.fromList([1, 2, 3, 4]));
final raw = brotliDecompress(compressed);
```

A stream produced with a Rust-style compound dictionary can be decoded by
attaching the same bytes:

```dart
final raw = brotliDecompress(
  compressed,
  options: BrotliDecodeOptions(compoundDictionary: dictionary),
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
[`benchmark_svg`](https://github.com/unk-404/benchmark_svg) into the card above.
The single CI workflow runs the tests first, then the benchmark, then commits
the changed SVG to `assets/` with `[skip ci]`.

## License

MIT. The static dictionary, context table and test corpus are derived from
Google's Brotli reference implementation (MIT); see `LICENSE` and `NOTICE`.
