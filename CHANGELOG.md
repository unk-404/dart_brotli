## 0.1.0

- Pure Dart Brotli decoder (RFC 7932): static dictionary, 121 transforms,
  context modeling, large-window decode, streaming and one-shot APIs.
- Encoder quality 0–11: hash chains, lazy matching, 1/2/3 and 13-context
  literal models, block splitting, distance-parameter search, RLE-optimized
  histograms, static-dictionary references, large-window encoding and a
  cost-guided parser for the highest qualities.
- Push-style streaming encoder (`BrotliEncoder`) and decoder, including
  `flush`/`finish` semantics and incremental output.
- Compound-dictionary decoding (`BrotliDecodeOptions.compoundDictionary`) for
  Rust `--dictionary` streams; the encoder-side attachment is the remaining
  extension.
- Blit-native API (`Bytes`/`BytesLike`/`BytesMut`) plus a `compat.dart`
  `Uint8List`/`List<int>` API, `dart:convert` codec and file helpers.
- Web-safe: VM, dart2js and dart2wasm; no `dart:io` in the codec.
- 22/22 reference corpus pairs decode byte-exactly; deterministic fuzz and
  round-trip tests; Rust `brotli` oracle comparisons.
- Four-row benchmark (decode/encode, 1 MiB text/binary, q5) against JIT/AOT/JS/
  WASM and the Rust oracle; one CI workflow from tests to benchmark charts.
- Remaining extensions: large-window encoding, compound/shared dictionaries,
  encoder-side static-dictionary matching.
