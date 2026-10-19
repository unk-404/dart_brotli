@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/encoder/context_modeling.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;

  group('complex static context map', () {
    test('the 64-entry map uses 13 trees', () {
      expect(kStaticContextMapComplexUtf8, hasLength(kNumLiteralContexts));
      final seen = <int>{...kStaticContextMapComplexUtf8};
      expect(seen.length, kMaxStaticContexts);
      for (final tree in kStaticContextMapComplexUtf8) {
        expect(tree, inInclusiveRange(0, kMaxStaticContexts - 1));
      }
      expect(kComplexUtf8Contexts.numClusters, kMaxStaticContexts);
      expect(kComplexUtf8Contexts.contextMap, hasLength(kNumLiteralContexts));
    });

    test('the heuristic triggers for long compressible text only', () {
      final big = _text(1 * _kMiB);
      final small = _text(100 * _kKiB);
      expect(
        shouldUseComplexStaticContextMap(
          big,
          0,
          big.length,
          sizeHint: big.length,
          quality: 5,
        ),
        isTrue,
        reason: '1 MiB English text',
      );
      expect(
        shouldUseComplexStaticContextMap(
          small,
          0,
          small.length,
          sizeHint: small.length,
          quality: 5,
        ),
        isFalse,
        reason: 'below the 1 MiB size hint',
      );
      // Long but incompressible input must not trigger.
      final random = _random(1 * _kMiB, 3);
      expect(
        shouldUseComplexStaticContextMap(
          random,
          0,
          random.length,
          sizeHint: random.length,
          quality: 5,
        ),
        isFalse,
        reason: 'random data',
      );
      // Quality below the context-modeling threshold must not trigger.
      expect(
        shouldUseComplexStaticContextMap(
          big,
          0,
          big.length,
          sizeHint: big.length,
          quality: 4,
        ),
        isFalse,
        reason: 'quality 4',
      );
      // The chosen model is the 13-context one.
      final model = chooseLiteralContextModel(
        big,
        0,
        big.length,
        5,
        sizeHint: big.length,
      );
      expect(model?.numClusters, kMaxStaticContexts);
    });

    test('short inputs keep the 1/2/3 context behaviour', () {
      for (final size in <int>[400, 5000, 100 * _kKiB]) {
        final model = chooseLiteralContextModel(
          _text(size),
          0,
          size,
          6,
          sizeHint: size,
        );
        if (model != null) {
          expect(model.numClusters, lessThanOrEqualTo(3));
        }
      }
    });

    test('oracle round-trips at q5/q6/q7/q8', () async {
      final cases = <String, Uint8List>{
        'text-2m': _text(2 * _kMiB),
        'cjk-300k': _cjk(300 * _kKiB, 3),
        'mixed-300k': _mixed(300 * _kKiB, 5),
        'binary-300k': _random(300 * _kKiB, 7),
      };
      for (final entry in cases.entries) {
        for (final quality in <int>[5, 6, 7, 8]) {
          final stream = brotliCompress(
            entry.value,
            options: BrotliEncodeOptions(quality: quality),
          );
          final decoded = await _oracleDecompress(oracle, stream);
          expect(
            _sha256(decoded),
            orderedEquals(_sha256(entry.value)),
            reason: '${entry.key} q$quality',
          );
          expect(stream.length, lessThanOrEqualTo(maxCompressedSize(entry.value.length)));
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('complex context modeling never enlarges the output', () {
      final input = _text(1 * _kMiB);
      for (final quality in <int>[6, 7, 8]) {
        final withComplex = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        final without = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality, sizeHint: 0),
        );
        // With the complex map the encoder picks the smaller candidate, so the
        // result must not be larger; on English text it wins by ~1%.
        expect(
          withComplex.length,
          lessThanOrEqualTo(without.length),
          reason: 'q$quality',
        );
        expect(
          brotliDecompress(withComplex),
          orderedEquals(input),
          reason: 'q$quality',
        );
      }
    });

    test('deterministic', () {
      final input = _text(1 * _kMiB);
      final first = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 6),
      );
      expect(
        brotliCompress(input, options: const BrotliEncodeOptions(quality: 6)),
        orderedEquals(first),
      );
    });
  });

  group('ratio versus the Rust oracle', () {
    test('report q5/q6/q7 sizes on 1 MiB and 2 MiB English text', () async {
      final report = StringBuffer('complex-context report (ours / Rust):\n');
      for (final size in <int>[1 * _kMiB, 2 * _kMiB]) {
        final input = _text(size);
        final without = <int>[];
        for (final quality in <int>[5, 6, 7]) {
          final ours = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          final old = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality, sizeHint: 0),
          );
          final rust = await _oracleCompress(oracle, input, quality);
          without.add(ours.length);
          report.writeln(
            '  ${size ~/ _kMiB}MiB q$quality ours=${ours.length} '
            'without=${old.length} delta=${ours.length - old.length} '
            'rust=${rust.length} '
            'ratio=${(ours.length / rust.length).toStringAsFixed(4)}',
          );
          expect(ours.length / rust.length, lessThan(1.25));
        }
        expect(without, isNotEmpty);
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 12)));
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Fixtures and oracle helpers
// ---------------------------------------------------------------------------

final Uint8List _alice = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();

Uint8List _text(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = _alice[i % _alice.length];
  }
  return out;
}

Uint8List _random(int size, int seed) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List _cjk(int size, int seed) {
  final random = Random(seed);
  final builder = StringBuffer();
  while (builder.length < size) {
    builder.writeCharCode(0x4E00 + random.nextInt(2000));
    if (random.nextInt(8) == 0) builder.write(' ');
  }
  final bytes = utf8.encode(builder.toString());
  return Uint8List.fromList(bytes.take(size).toList());
}

Uint8List _mixed(int size, int seed) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  var inText = true;
  var left = 8192;
  while (pos < size) {
    if (left == 0) {
      inText = !inText;
      left = 8192;
    }
    out[pos] = inText ? _alice[pos % _alice.length] : random.nextInt(256);
    pos++;
    left--;
  }
  return out;
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

Future<Uint8List> _oracleRun(
  File oracle,
  List<String> arguments,
  Uint8List input,
) async {
  final process = await Process.start(oracle.path, arguments);
  final stdoutFuture = process.stdout.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(input);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final output = (await stdoutFuture).takeBytes();
  final errors = await stderrFuture;
  if (exitCode != 0) {
    throw StateError('oracle ${arguments.join(' ')} failed: $errors');
  }
  return output;
}

Future<Uint8List> _oracleDecompress(File oracle, Uint8List compressed) =>
    _oracleRun(oracle, <String>[
      'decompress',
      '-i',
      '-',
      '-o',
      '-',
    ], compressed);

Future<Uint8List> _oracleCompress(File oracle, Uint8List input, int quality) =>
    _oracleRun(oracle, <String>[
      'compress',
      '-q',
      '$quality',
      '-i',
      '-',
      '-o',
      '-',
    ], input);
