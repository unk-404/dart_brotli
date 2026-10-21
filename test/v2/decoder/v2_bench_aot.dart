/// AOT benchmark entry point for the v2 decoder (not a `_test.dart` file).
///
/// Replicates the official `tool/v2_bench.dart --api v2` decode measurement:
/// the 1 MiB gate corpus decoded from `build/benchmark_test/native_streams`
/// (Rust-oracle q5 streams), one decode per round, median of 15 rounds after
/// 3 warmups, compared with `benchmark/v2_native.json`.
///
/// ```sh
/// dart compile exe test/v2/decoder/v2_bench_aot.dart -o build/v2_bench.exe
/// build/v2_bench.exe
/// ```
///
/// Exits 1 when the decoder gate (binary or text q5 decode >= 0.80 native)
/// fails. The encoder is out of scope here.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_neo/compat.dart';

import '../../../benchmark/corpus.dart';

// benchmark/v2_native.json, decode q5 (1 MiB).
const double _nativeTextDecodeMBps = 1074.975;
const double _nativeBinaryDecodeMBps = 602.176;

Uint8List _readOrEncode(String name, Uint8List raw) {
  final file = File('build/benchmark_test/native_streams/$name.q5.br');
  if (file.existsSync()) {
    final bytes = file.readAsBytesSync();
    final decoded = BrotliDecoderV2.decode(bytes);
    if (decoded.length == raw.length) {
      return bytes;
    }
  }
  return Uint8List.fromList(
    brotliCompress(raw, options: const BrotliEncodeOptions(quality: 5)),
  );
}

({double mbps, double ratio}) _measure(
  Uint8List raw,
  Uint8List compressed,
  double native,
) {
  for (var i = 0; i < 3; i++) {
    BrotliDecoderV2.decode(compressed);
  }
  final samples = <double>[];
  for (var round = 0; round < 15; round++) {
    final watch = Stopwatch()..start();
    BrotliDecoderV2.decode(compressed);
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1e6);
  }
  samples.sort();
  final median = samples[samples.length ~/ 2];
  final mbps = (raw.length / (1 << 20)) / median;
  return (mbps: mbps, ratio: mbps / native);
}

void main() {
  final payloads = <String, Uint8List>{
    'text': makeText(),
    'binary': makeBinary(),
  };
  var failed = false;
  for (final entry in payloads.entries) {
    final compressed = _readOrEncode(entry.key, entry.value);
    final native = entry.key == 'text'
        ? _nativeTextDecodeMBps
        : _nativeBinaryDecodeMBps;
    final result = _measure(entry.value, compressed, native);
    final gate = result.ratio >= 0.8;
    failed |= !gate;
    // ignore: avoid_print
    print(
      'decode.${entry.key}.1024KiB.q5: '
      '${result.mbps.toStringAsFixed(1)} MB/s '
      '(${(result.ratio * 100).toStringAsFixed(1)}% of native '
      '${native.toStringAsFixed(1)} MB/s) ${gate ? 'PASS' : 'FAIL'}',
    );
  }
  if (failed) {
    exitCode = 1;
  }
}
