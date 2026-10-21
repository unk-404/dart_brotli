## 0.2.0

- **Breaking**: new performance-first raw API in `package:brotli_neo/v2.dart`
  (`BrotliEncoderV2`/`BrotliDecoderV2`, one-shot and `*Into` buffer variants).
  The v0.1 blit-native and `compat.dart` APIs remain available for migration.
- VM/AOT uses 64-bit bit accumulators and a fused metablock decoder; Web uses a
  correct 32-bit fallback (Chrome/Node 1 MiB parity tests).
- AOT 1 MiB q5 benchmark card: decode text ~1.74 GB/s / binary ~1.11 GB/s;
  encode text ~244 MB/s / binary ~168 MB/s. Relative to the Rust oracle this
  is roughly 158%/215% decode and 138%/140% encode on this machine.
- Hybrid quality routing: q0/q1 use the faster legacy greedy path on text and
  a binary-tuned greedy tier on binary; q2–q5 use the v2 fast path; q6+ keeps
  the quality tiers. Legacy is byte-identical for delegated qualities.
- Web 1 MiB decode underflow fixed by disabling the 64-bit-only fused loop on
  dart2js and using the generic resumable path.
- Benchmark card now exercises the v2 API; native comparison and the
  `tool/v2_bench.dart` gate are part of the repository.

## 0.1.2

- Serialized shared dictionaries are decoded
  (`BrotliDecodeOptions.sharedDictionary`): magic/prefix chunks, custom word
  lists, custom transform lists (prefix/type/suffix, SHIFT parameters,
  identity cutoff), 64-context dictionary maps, multi-dictionary fallback and
  the embedded LZ77 prefix. Invalid dictionaries raise `BrotliException`.
- Q11 performance: 1 MiB text 2.24 s -> ~1.2 s and q10 1.13 s -> ~0.98 s, at
  <=0.13% size cost, by caching/propagating matches between the two optimal
  parse passes and narrowing the search.

## 0.1.1

- Q10/Q11 now run a bounded shortest-path (Zopfli-style) optimal parse:
  strict gains over Q9 on English text (1 MiB 50,939 -> 50,588 -> 50,486),
  CJK 152,473 -> 138,418 (-9.2%), and improved ratios versus the Rust oracle.
- Prepared compound dictionaries: `BrotliPreparedDictionary` builds the
  dictionary index once and can be shared by many one-shot or streaming
  encodes via `BrotliEncodeOptions.preparedDictionary`; output is byte-identical
  to the raw `compoundDictionary` path.
- Benchmark card rendering migrated to `benchcat`, with a linear bar curve and
  the OFL font under `assets/fonts/`.
- CI: the Rust oracle is built and used by the platform matrix; the RFC corpus
  and dictionary fixtures are stored with exact bytes (`-text`); all test jobs
  gate the benchmark and chart commit.

## 0.1.0

- Pure Dart Brotli decoder (RFC 7932): static dictionary, 121 transforms,
  context modeling, large-window decode, streaming and one-shot APIs.
- Encoder quality 0–11: hash chains, lazy matching, 1/2/3 and 13-context
  literal models, block splitting, distance-parameter search, RLE-optimized
  histograms, static-dictionary references, large-window encoding and a
  cost-guided parser for the highest qualities.
- Push-style streaming encoder (`BrotliEncoder`) and decoder, including
  `flush`/`finish` semantics and incremental output.
- Compound dictionary encode + decode (`BrotliEncodeOptions.compoundDictionary`
  / `BrotliDecodeOptions.compoundDictionary`), interoperable with Rust
  `--dictionary` streams in both directions.
- The serialized shared/prepared dictionary format remains the only
  unimplemented extension.
- Blit-native API (`Bytes`/`BytesLike`/`BytesMut`) plus a `compat.dart`
  `Uint8List`/`List<int>` API, `dart:convert` codec and file helpers.
- Web-safe: VM, dart2js and dart2wasm; no `dart:io` in the codec.
- 22/22 reference corpus pairs decode byte-exactly; deterministic fuzz and
  round-trip tests; Rust `brotli` oracle comparisons.
- Four-row benchmark (decode/encode, 1 MiB text/binary, q5) against JIT/AOT/JS/
  WASM and the Rust oracle; one CI workflow from tests to benchmark charts.
- Not included in 0.1.0: the serialized shared/prepared dictionary format
  (planned for 0.1.1).
