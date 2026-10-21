# Benchmarks

The benchmark is deliberately small: **four core operations** measured for five
implementations on exactly the same data. The Dart rows use the v0.2.0
`BrotliEncoderV2`/`BrotliDecoderV2` API; Rust is the authoritative oracle.

| operation | payload | quality |
|---|---|---|
| `decode.text.1024KiB.q5` | 1 MiB text | q5 stream |
| `decode.binary.1024KiB.q5` | 1 MiB binary | q5 stream |
| `encode.text.1024KiB.q5` | 1 MiB text | q5 |
| `encode.binary.1024KiB.q5` | 1 MiB binary | q5 |

Implementations: Dart JIT, Dart AOT, Dart JS, Dart WASM, and the authoritative
Rust `brotli` crate. Every series is normalized to bytes/second before rendering,
so bars are directly comparable.

## Files

```
benchmark/corpus.dart                  deterministic 1 MiB corpus (web-safe)
benchmark/gen_corpus.dart              writes the corpus for the Rust oracle
benchmark/brotli_benchmark_test.dart   four benchmark_test rows
benchmark/normalize_bench.dart         benchmark_test + Rust -> canonical B/s JSONL
benchmark/benchcat.toml                four rows x five implementations
benchmark/codec_smoke.dart             dart compile exe/js/wasm smoke
```

## Reproduce locally

Prerequisites: Dart 3.13+, Node.js >= 22 on `PATH` (the `benchmark_test` CLI
runs `--compile js/wasm` through `dart test -p node`), Rust/cargo, and a
`benchcat` binary. The repository font is `assets/fonts/quicksand.ttf`.

```sh
# 1. corpus for the Rust oracle
dart run benchmark/gen_corpus.dart build/benchmark_test/corpus

# 2. authoritative Rust numbers
cargo build --release --locked --manifest-path tool/oracle_rust/Cargo.toml
tool/oracle_rust/target/release/brotli-oracle bench \
  -i build/benchmark_test/corpus/text.bin --label text \
  -i build/benchmark_test/corpus/binary.bin --label binary \
  -q 5 -w 22 --rounds 5 --jsonl build/benchmark_test/rust.jsonl

# 3. Dart numbers for all compile targets
mkdir -p build/benchmark_test
for target in jit aot js wasm; do
  dart run benchmark_test --compile "$target" --output jsonl \
    benchmark/brotli_benchmark_test.dart 2>/dev/null \
    | grep '^{' > "build/benchmark_test/brotli_$target.jsonl"
done

# 4. put every implementation on the same B/s scale
dart run benchmark/normalize_bench.dart \
  --dart-dir build/benchmark_test \
  --rust build/benchmark_test/rust.jsonl \
  --out-dir build/benchmark_test/normalized

# 5. render the card
benchcat render --config benchmark/benchcat.toml \
  --font-file assets/fonts/quicksand.ttf -o assets/benchmarks.svg
```

The PowerShell equivalent for the compile loop above:

```powershell
foreach ($target in 'jit','aot','js','wasm') {
  dart run benchmark_test --compile $target --output jsonl `
    benchmark/brotli_benchmark_test.dart 1> "build/benchmark_test/raw_$target.txt"
  Get-Content "build/benchmark_test/raw_$target.txt" |
    Where-Object { $_ -match '^\{' } |
    Set-Content "build/benchmark_test/brotli_$target.jsonl"
}
```

## CI

One workflow: `.github/workflows/ci.yml`.

1. platform tests, browser tests and the Rust-oracle suite must pass;
2. the benchmark job builds the corpus and oracle, runs all four Dart targets,
   normalizes the data and renders `assets/benchmarks.svg`;
3. on `master`, a final job commits the changed SVG with `[skip ci]`, so the
   chart refresh does not retrigger CI.

The README image is the absolute URL of the committed card:

`https://raw.githubusercontent.com/unk-404/dart_brotli/master/assets/benchmarks.svg`
