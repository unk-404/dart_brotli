/// v2 decoder throughput snapshot against the native baseline in
/// `benchmark/v2_native.json` (Rust `brotli` 9.0.0, strict one-shot decode).
///
/// Reports MB/s and the fraction of native; does not hard-fail on a slow CI
/// host, but fails if decoding is more than 3x slower than native (a clear
/// regression signal).
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:typed_data';

import 'package:brotli_neo/compat.dart';
import 'package:test/test.dart';

import '../../../benchmark/corpus.dart';

// benchmark/v2_native.json: decode q5 on the same 1 MiB payloads.
const double nativeTextDecodeMBps = 1074.975;
const double nativeBinaryDecodeMBps = 602.176;

({double mbps, double ratio}) _measure(
  Uint8List source,
  Uint8List compressed,
  double native,
) {
  final scratch = Uint8List((1 << 21) + 1024);
  for (var i = 0; i < 3; i++) {
    BrotliDecoderV2.decodeInto(scratch, compressed);
  }
  const iterations = 9;
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    BrotliDecoderV2.decodeInto(scratch, compressed);
  }
  watch.stop();
  final mbps =
      (source.length * iterations / (1 << 20)) /
      (watch.elapsedMicroseconds / 1e6);
  return (mbps: mbps, ratio: mbps / native);
}

void main() {
  test('q5 decode throughput vs native baseline', () {
    const quality = BrotliEncodeOptions(quality: 5);
    for (final payload in <String, Uint8List>{
      'text': makeText(),
      'binary': makeBinary(),
    }.entries) {
      final compressed = Uint8List.fromList(
        brotliCompress(payload.value, options: quality),
      );
      final native = payload.key == 'text'
          ? nativeTextDecodeMBps
          : nativeBinaryDecodeMBps;
      final result = _measure(payload.value, compressed, native);
      // ignore: avoid_print
      print(
        'v2 decode.${payload.key}.1024KiB.q5: '
        '${result.mbps.toStringAsFixed(1)} MB/s '
        '(${(result.ratio * 100).toStringAsFixed(1)}% of native '
        '${native.toStringAsFixed(1)} MB/s)',
      );
      expect(
        result.ratio,
        greaterThan(0.05),
        reason: '${payload.key} decode regressed badly',
      );
    }
  });
}
