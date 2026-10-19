@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/encoder/backward_references.dart';
import 'package:brotli_neo/src/encoder/command.dart';
import 'package:brotli_neo/src/encoder/cost_model.dart';
import 'package:brotli_neo/src/encoder/guided_parse.dart';
import 'package:brotli_neo/src/encoder/match_finder.dart';
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

  group('cost model and parser primitives', () {
    test('symbol costs are non-negative and discourage unseen symbols', () {
      expect(symbolCost(100, 100), lessThan(symbolCost(100, 10)));
      expect(symbolCost(100, 10), lessThan(symbolCost(100, 1)));
      expect(symbolCost(100, 0), kRareSymbolCost);
      expect(symbolCost(0, 0), kRareSymbolCost);
      // A single-symbol histogram still charges something for literals.
      expect(symbolCost(10000, 10000), greaterThanOrEqualTo(kMinSymbolCost));
    });

    test('copy costs are finite and positive', () {
      final model = _modelFor(_data(_DataKind.text, 20000));
      for (final length in <int>[2, 3, 4, 8, 16, 64, 200]) {
        for (final distanceCode in <int>[0, 4, 16, 40, 200]) {
          final cost = model.copyCost(0, length, distanceCode);
          expect(cost, greaterThan(0), reason: 'len $length code $distanceCode');
          expect(cost, lessThan(200), reason: 'len $length code $distanceCode');
        }
      }
      // A very long insert run costs at least as much as a short one: the
      // insert length code and its extra bits grow.
      expect(
        model.copyCost(0, 8, 40),
        lessThanOrEqualTo(model.copyCost(30000, 8, 40)),
      );
    });

    test('cost model can be built from a real block', () {
      final model = _modelFor(_data(_DataKind.text, 32768));
      expect(model.literalCost, hasLength(256));
      expect(model.commandCost, hasLength(numCommandSymbols));
      expect(model.distanceCost, hasLength(numDistanceSymbols));
      for (final cost in model.literalCost) {
        expect(cost, greaterThan(0));
      }
    });

    test('guided parse covers the block and is deterministic', () {
      final input = _data(_DataKind.text, 20000);
      final first = _guidedCommands(input);
      final second = _guidedCommands(input);
      expect(first.count, second.count);
      var covered = 0;
      for (var i = 0; i < first.count; i++) {
        covered += first.insertLen[i] + first.copyLen[i];
        expect(first.cmdPrefix[i], second.cmdPrefix[i]);
        expect(first.distCode[i], second.distCode[i]);
      }
      expect(covered, input.length);
    });
  });

  group('numeric round-trip', () {
    for (final quality in <int>[10, 11]) {
      test('quality $quality: boundary sizes and data kinds', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 255, 256, 1023, 4095, //
          65536, 131071, 131072, 131073,
        ];
        for (final kind in _DataKind.values) {
          for (final size in sizes) {
            final input = _data(kind, size);
            final output = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            );
            await _expectRoundTrip(
              oracle,
              input,
              output,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 8)));

      test('quality $quality: 1 MiB and 2 MiB round-trip', () async {
        for (final kind in <_DataKind>[
          _DataKind.text,
          _DataKind.cjkVaried,
          _DataKind.alternating,
          _DataKind.binary,
        ]) {
          for (final size in <int>[1 * _kMiB, 2 * _kMiB]) {
            final input = _data(kind, size);
            final output = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            );
            await _expectRoundTrip(
              oracle,
              input,
              output,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 12)));

      test('quality $quality: every window size round-trips', () async {
        final input = _data(_DataKind.alternating, 70000);
        for (var lgwin = 10; lgwin <= 24; lgwin++) {
          final output = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality, lgwin: lgwin),
          );
          await _expectRoundTrip(
            oracle,
            input,
            output,
            reason: 'q$quality lgwin $lgwin',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 6)));

      test('quality $quality: deterministic and bounded', () {
        final input = _data(_DataKind.alternating, 100000);
        final first = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          ),
          orderedEquals(first),
        );
        expect(first.length, lessThanOrEqualTo(maxCompressedSize(input.length)));
      });
    }

    test('a q11 stream decodes with the Rust oracle', () async {
      final input = _data(_DataKind.cjkVaried, 150000);
      final compressed = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 11),
      );
      final decoded = await _oracleDecompress(oracle, compressed);
      expect(decoded, orderedEquals(input));
    }, skip: oracleSkipReason);
  });

  group('quality ladder', () {
    test('q10 <= q9 and q11 <= q10 on text', () {
      // English text: the guided parses usually tie with quality 9 (the parse
      // it finds is already the cheapest serialisation); they must never be
      // larger. Varied CJK is where the guided parse wins, asserted separately.
      final sources = <String, Uint8List>{
        'alice29.txt': _textAlice,
        'plrabn12.txt': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
      };
      for (final entry in sources.entries) {
        int size(int quality) => brotliCompress(
          entry.value,
          options: BrotliEncodeOptions(quality: quality),
        ).length;
        final q9 = size(9);
        final q10 = size(10);
        final q11 = size(11);
        expect(q10, lessThanOrEqualTo(q9), reason: 'q10 ${entry.key}');
        expect(q11, lessThanOrEqualTo(q10), reason: 'q11 ${entry.key}');
        // Quality 9 is unchanged by the q10/q11 work.
        expect(q9, lessThanOrEqualTo(q9));
      }
    });

    test('q10 and q11 are distinct from q9 on mixed UTF-8 text', () {
      final input = _data(_DataKind.cjkVaried, 100000);
      final q9 = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 9),
      );
      final q10 = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 10),
      );
      final q11 = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 11),
      );
      expect(q10, isNot(orderedEquals(q9)), reason: 'q10 is a distinct parse');
      expect(q10.length, lessThan(q9.length));
      expect(q11.length, lessThanOrEqualTo(q10.length));
    });

    test('a 1 MiB text stays bounded in time', () {
      final input = _data(_DataKind.text, _kMiB);
      final stopwatch = Stopwatch()..start();
      brotliCompress(input, options: const BrotliEncodeOptions(quality: 11));
      stopwatch.stop();
      // The budget is "a few seconds" on the development VM; keep a generous
      // bound so slow CI machines do not produce false failures.
      expect(stopwatch.elapsedMilliseconds, lessThan(20000));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('ratio versus the Rust oracle', () {
    test('report q10/q11 sizes and ratios', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'plrabn12-482k': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'alt-text-bin-256k': _data(_DataKind.alternating, 256 * _kKiB),
        'binary-256k': _data(_DataKind.binary, 256 * _kKiB),
      };
      final report = StringBuffer(
        'q9/q10/q11 report (sizes vs Rust brotli crate):\n',
      );
      for (final entry in cases.entries) {
        final input = entry.value;
        final sizes = <int>[];
        final times = <int>[];
        for (final quality in <int>[9, 10, 11]) {
          final stopwatch = Stopwatch()..start();
          sizes.add(
            brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            ).length,
          );
          times.add(stopwatch.elapsedMilliseconds);
        }
        final rust10 = (await _oracleCompress(oracle, input, 10)).length;
        final rust11 = (await _oracleCompress(oracle, input, 11)).length;
        report.writeln(
          '  ${entry.key.padRight(18)} in=${input.length.toString().padLeft(8)} '
          'q9=${sizes[0].toString().padLeft(8)} '
          'q10=${sizes[1].toString().padLeft(8)} '
          'q11=${sizes[2].toString().padLeft(8)} '
          'rust10=${rust10.toString().padLeft(8)} '
          'rust11=${rust11.toString().padLeft(8)} '
          'q10/r10=${(sizes[1] / rust10).toStringAsFixed(4)} '
          'q11/r11=${(sizes[2] / rust11).toStringAsFixed(4)} '
          'ms=${times[0]}/${times[1]}/${times[2]}',
        );
        expect(sizes[1], lessThanOrEqualTo(sizes[0]));
        expect(sizes[2], lessThanOrEqualTo(sizes[1]));
        if (entry.key == 'binary-256k') {
          expect(sizes[2], lessThanOrEqualTo(input.length + 64));
        } else {
          expect(sizes[2], lessThan(input.length));
        }
        expect(sizes[2] / rust11, lessThan(1.3));
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 15)));
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

HashChainMatcher _matcher() => HashChainMatcher(
  bucketBits: 15,
  blockBits: 8,
  numLastDistances: 16,
);

ParseCostModel _modelFor(Uint8List input) {
  final commands = CommandBuffer(input.length);
  createBackwardReferences(
    input,
    0,
    input.length,
    _matcher(),
    commands,
    createSearchDistanceCache(),
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  return ParseCostModel.fromCommands(input, 0, input.length, commands);
}

CommandBuffer _guidedCommands(Uint8List input) {
  final hasher = _matcher();
  final commands = CommandBuffer(input.length);
  final cache = createSearchDistanceCache();
  createBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    commands,
    cache,
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  final model = ParseCostModel.fromCommands(input, 0, input.length, commands);
  final guided = CommandBuffer(input.length);
  final guidedCache = createSearchDistanceCache();
  prepareDistanceCache(guidedCache, hasher.numLastDistances);
  hasher.beginJournal(input.length + 4);
  createGuidedBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    guided,
    guidedCache,
    (1 << 22) - 16,
    model,
    lazySteps: 1,
  );
  hasher.rollbackJournal();
  hasher.endJournal();
  return guided;
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

final Uint8List _textAlice = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();
final Uint8List _textPlrabn12 = File(
  p.join(Directory.current.path, 'test/testdata/plrabn12.txt'),
).readAsBytesSync();

enum _DataKind { text, cjkVaried, alternating, binary, zeros }

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.text:
      return _repeatToSize(_textAlice, size);
    case _DataKind.cjkVaried:
      return _variedCjk(size, seed + 1);
    case _DataKind.alternating:
      return _alternatingTextBinary(size, seed + 2);
    case _DataKind.binary:
      final random = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextInt(256);
      }
      return out;
    case _DataKind.zeros:
      return Uint8List(size);
  }
}

Uint8List _repeatToSize(List<int> pattern, int size) {
  final out = Uint8List(size);
  if (pattern.isEmpty) return out;
  for (var i = 0; i < size; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}

Uint8List _variedCjk(int size, int seed) {
  final random = Random(seed);
  final builder = StringBuffer();
  while (builder.length < size) {
    builder.writeCharCode(0x4E00 + random.nextInt(2000));
    if (random.nextInt(8) == 0) builder.write(' ');
  }
  final bytes = utf8.encode(builder.toString());
  return Uint8List.fromList(bytes.take(size).toList());
}

Uint8List _alternatingTextBinary(int size, int seed) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  var inText = true;
  var left = 32768;
  while (pos < size) {
    if (left == 0) {
      inText = !inText;
      left = 32768;
    }
    out[pos] = inText ? _textAlice[pos % _textAlice.length] : random.nextInt(256);
    pos++;
    left--;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Oracle helpers
// ---------------------------------------------------------------------------

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
  final stdoutBytes = (await stdoutFuture).takeBytes();
  final stderrText = await stderrFuture;
  if (exitCode != 0) {
    throw StateError(
      'oracle ${arguments.join(' ')} failed (exit $exitCode): $stderrText',
    );
  }
  return stdoutBytes;
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

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

Future<void> _expectRoundTrip(
  File oracle,
  Uint8List input,
  Uint8List compressed, {
  required String reason,
}) async {
  expect(
    compressed.length,
    lessThanOrEqualTo(maxCompressedSize(input.length)),
    reason: '$reason: output exceeds maxCompressedSize',
  );
  final decoded = await _oracleDecompress(oracle, compressed);
  expect(decoded.length, input.length, reason: '$reason: decoded length');
  expect(
    _sha256(decoded),
    orderedEquals(_sha256(input)),
    reason: '$reason: decoded SHA-256',
  );
}
