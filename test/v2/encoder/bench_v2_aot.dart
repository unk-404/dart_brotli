/// AOT benchmark for the v0.2.0 encoder fast path.
///
/// Not a `package:test` suite: compile and run it to report throughput.
///
/// ```powershell
/// dart compile exe test/v2/encoder/bench_v2_aot.dart -o .agents/tmp/bench_v2.exe
/// .agents/tmp/bench_v2.exe
/// ```
///
/// It compares `BrotliEncoderV2` against the v1 encoder on the shared 1 MiB
/// `benchmark/corpus.dart` payloads and prints the ratio against the native
/// (Rust) numbers from `.agents/notes/v0.2.0-plan.md`. When
/// `benchmark/v2_native.json` exists (or `BENCH_NATIVE_JSON` points at one), its
/// numbers override the built-in ones; the file maps `"<corpus>_q<quality>"`
/// or `"<corpus>"` keys to MB/s.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';

import '../../../benchmark/corpus.dart';

/// Native reference throughput (MB/s) from the v0.2.0 plan baseline table.
const Map<String, double> _planNative = <String, double>{
  'text_q0': 341,
  'text_q1': 407,
  'text_q5': 169,
  'binary_q0': 112,
  'binary_q1': 112,
  'binary_q5': 112,
};

void main(List<String> args) {
  final text = makeText();
  final binary = makeBinary();
  final native = _loadNative();
  final rounds = args.isNotEmpty ? int.parse(args.first) : 5;
  final report = StringBuffer()
    ..writeln('v2 encoder AOT benchmark (1 MiB, best of $rounds)')
    ..writeln(
      'corpus q  v1 MB/s  v2 MB/s  speedup  v1 size  v2 size  '
      'native MB/s  v2/native',
    );
  for (final entry in <String, Uint8List>{
    'text': text,
    'binary': binary,
  }.entries) {
    for (final quality in <int>[0, 1, 5]) {
      var v1Size = 0;
      var v2Size = 0;
      final v1Micros = _best(rounds, () {
        v1Size = brotliCompress(
          entry.value,
          options: BrotliEncodeOptions(quality: quality),
        ).length;
      });
      final v2Micros = _best(rounds, () {
        v2Size = BrotliEncoderV2.encode(
          entry.value,
          options: BrotliEncodeOptions(quality: quality),
        ).length;
      });
      final v1Mbps = _mbps(entry.value.length, v1Micros);
      final v2Mbps = _mbps(entry.value.length, v2Micros);
      final nativeMbps =
          native['${entry.key}_q$quality'] ??
          native[entry.key] ??
          _planNative['${entry.key}_q$quality'] ??
          0.0;
      report.writeln(
        '${entry.key.padRight(6)} q$quality  '
        '${v1Mbps.toStringAsFixed(1).padLeft(7)}  '
        '${v2Mbps.toStringAsFixed(1).padLeft(7)}  '
        '${(v1Micros / v2Micros).toStringAsFixed(2).padLeft(6)}x  '
        '${v1Size.toString().padLeft(8)}  ${v2Size.toString().padLeft(8)}  '
        '${nativeMbps.toStringAsFixed(0).padLeft(10)}  '
        '${(v2Mbps / nativeMbps * 100).toStringAsFixed(0).padLeft(8)}%',
      );
    }
  }
  stdout.write(report.toString());
}

/// Reads `benchmark/v2_native.json`: either the flat corpus-quality MB/s form
/// or the oracle tool `results` / `encode` / `mb_per_second` layout.
Map<String, double> _loadNative() {
  final path = Platform.environment['BENCH_NATIVE_JSON'];
  final file = File(path ?? 'benchmark/v2_native.json');
  if (!file.existsSync()) return const <String, double>{};
  final decoded = jsonDecode(file.readAsStringSync());
  final out = <String, double>{};
  if (decoded is! Map) return out;
  void add(String key, Object? value) {
    if (value is num) out[key] = value.toDouble();
  }

  for (final entry in decoded.entries) {
    add('${entry.key}', entry.value);
  }
  final results = decoded['results'];
  if (results is Map) {
    for (final corpus in results.entries) {
      final encode = corpus.value is Map
          ? (corpus.value as Map)['encode']
          : null;
      if (encode is! Map) continue;
      for (final quality in encode.entries) {
        final row = quality.value;
        if (row is Map) {
          add('${corpus.key}_${quality.key}', row['mb_per_second']);
        }
      }
    }
  }
  stderr.writeln('native baseline: ${file.path} (${out.length} entries)');
  return out;
}

int _best(int rounds, void Function() body) {
  var best = 1 << 30;
  for (var i = 0; i < rounds + 1; i++) {
    final stopwatch = Stopwatch()..start();
    body();
    final micros = stopwatch.elapsedMicroseconds;
    if (i > 0 && micros < best) best = micros;
  }
  return best;
}

double _mbps(int bytes, int micros) =>
    micros <= 0 ? 0 : bytes / 1e6 / (micros / 1e6);
