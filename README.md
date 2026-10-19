# brotli_neo

Pure Dart Brotli (RFC 7932) encoder and decoder.

![brotli_neo vs Rust brotli: decode/encode, 1 MiB, Q5](https://raw.githubusercontent.com/unk-404/dart_brotli/master/assets/benchmarks.svg)

- **Pure Dart**: no native assets, no FFI in the codec, works on the VM and on
  the web (dart2js / dart2wasm).
- **Zero-copy bytes**: first-class [`blit`](https://pub.dev/packages/blit)
  integration (`Bytes`, `BytesLike`, `BytesMut`, `BytesFile`).
- **Implemented**: RFC 7932 decoder (static dictionary, 121 transforms,
  large-window decode), encoder quality 0–11, streaming decoder, and both the
  blit-native and compat APIs. Compound/shared dictionaries and large-window
  encoding are the remaining extensions (see `CHANGELOG.md`).
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

## Development

```sh
dart pub get
dart analyze
dart test
```

CI runs Ubuntu/Windows/macOS, Chrome browser tests, the JS/Wasm compiles and the
full suite against the Rust oracle (`tool/oracle_rust`). The oracle-backed tests
read its executable path from `BROTLI_ORACLE` and skip when it is unset.

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
