// WASM benchmark for the v0.2 API.
//
// `benchmark_test`'s Node wasm driver currently crashes in its own test
// framework on 1 MiB payloads, so this small entry point measures the same
// four rows directly and prints canonical JSONL for benchcat.
//
//   dart compile wasm tool/v2_wasm_bench.dart -o build/benchmark_test/v2_wasm_bench.wasm
//   cp tool/v2_wasm_run.mjs build/benchmark_test/
//   node build/benchmark_test/v2_wasm_run.mjs > build/benchmark_test/brotli_wasm.jsonl
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_neo/v2.dart';

import '../benchmark/corpus.dart';

const int _kRounds = 7;
const int _kWarmups = 2;

void main() {
  final payloads = <String, Uint8List>{
    'text': makeText(),
    'binary': makeBinary(),
  };
  for (final entry in payloads.entries) {
    final name = entry.key;
    final input = entry.value;
    const options = BrotliEncodeOptions(quality: 5);

    for (var i = 0; i < _kWarmups; i++) {
      BrotliEncoderV2.encode(input, options: options);
    }
    var compressed = Uint8List(0);
    final enc = Stopwatch()..start();
    for (var i = 0; i < _kRounds; i++) {
      compressed = BrotliEncoderV2.encode(input, options: options);
    }
    enc.stop();
    _emit('encode.$name.1024KiB.q5', 'Encode', input.length, enc, _kRounds);

    for (var i = 0; i < _kWarmups; i++) {
      BrotliDecoderV2.decode(compressed);
    }
    final dec = Stopwatch()..start();
    for (var i = 0; i < _kRounds; i++) {
      BrotliDecoderV2.decode(compressed);
    }
    dec.stop();
    _emit('decode.$name.1024KiB.q5', 'Decode', input.length, dec, _kRounds);
  }
}

void _emit(
  String id,
  String group,
  int bytes,
  Stopwatch stopwatch,
  int rounds,
) {
  final seconds = stopwatch.elapsedMicroseconds / 1e6 / rounds;
  final value = bytes / seconds;
  final payload = id.split('.')[1];
  final label =
      '$group ${payload[0].toUpperCase()}${payload.substring(1)} - Q5';
  print(
    jsonEncode(<String, Object?>{
      'id': id,
      'group': group,
      'label': label,
      'unit': 'B/s',
      'direction': 'higher',
      'value': value,
    }),
  );
}
