@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/encoder/backward_references.dart';
import 'package:brotli_neo/src/encoder/bit_writer.dart';
import 'package:brotli_neo/src/encoder/command.dart';
import 'package:brotli_neo/src/encoder/match_finder.dart';
import 'package:brotli_neo/src/encoder/metablock_writer.dart';
import 'package:brotli_neo/src/encoder/static_dictionary.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

/// English text built from words that are in the RFC dictionary.
const String _dictionaryHeavy =
    'The information about the transformation of the dictionary and the '
    'compression of the information is available from the server. They were '
    'thinking about the performance of the implementation. ';

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;

  group('dictionary matcher', () {
    test('finds dictionary words at literal positions', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final matcher = StaticDictionaryMatcher.instance;
      // "information" starts at index 4.
      final match = matcher.findMatch(input, 4, input.length - 4);
      expect(match, isNotNull);
      expect(match!.length, greaterThanOrEqualTo(kMinDictionaryMatchLength));
      // The distance is always beyond the backward window.
      expect(match.distance(1000), greaterThan(1000));
      // Random bytes never match.
      final random = _random(4096, 3);
      var hits = 0;
      for (var i = 0; i + 8 < random.length; i++) {
        if (matcher.findMatch(random, i, random.length - i) != null) hits++;
      }
      expect(hits, lessThan(8));
    });

    test('rewrites literal runs into dictionary references', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
      expect(rewritten.count, greaterThan(chain.count));
      var covered = 0;
      for (var i = 0; i < rewritten.count; i++) {
        covered += rewritten.insertLen[i] + rewritten.copyLen[i];
        // Dictionary references use a distance code far beyond the window.
        if (rewritten.copyLen[i] > 0 && rewritten.distCode[i] > 0) {
          final distance = rewritten.distCode[i] - 15;
          if (distance > (1 << 22) - 16) {
            expect(rewritten.copyLen[i], inInclusiveRange(4, 24));
          }
        }
      }
      expect(covered, input.length);
    });

    test('the rewritten parse serialises smaller on dictionary text', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
      final chainBits = _serialisedBits(input, chain);
      final dictionaryBits = _serialisedBits(input, rewritten);
      expect(dictionaryBits, lessThanOrEqualTo(chainBits));
    });
  });

  group('numeric round-trip', () {
    test('oracle and our decoder round-trip at q5/q8/q11', () async {
      final cases = <String, Uint8List>{
        'dictionary-phrase': Uint8List.fromList(
          utf8.encode(_dictionaryHeavy * 40),
        ),
        'short-phrase': Uint8List.fromList(utf8.encode(_dictionaryHeavy)),
        'english-1m': _text(1 * _kMiB),
        'cjk-200k': _cjk(200 * _kKiB, 3),
        'mixed-200k': _mixed(200 * _kKiB, 5),
        'binary-200k': _random(200 * _kKiB, 7),
      };
      for (final entry in cases.entries) {
        for (final quality in <int>[5, 8, 11]) {
          final stream = brotliCompress(
            entry.value,
            options: BrotliEncodeOptions(quality: quality),
          );
          final decoded = await _oracleDecompress(oracle, stream);
          expect(
            _sha256(decoded),
            orderedEquals(_sha256(entry.value)),
            reason: 'oracle ${entry.key} q$quality',
          );
          expect(
            brotliDecompress(stream),
            orderedEquals(entry.value),
            reason: 'our decoder ${entry.key} q$quality',
          );
          expect(
            stream.length,
            lessThanOrEqualTo(maxCompressedSize(entry.value.length)),
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('dictionary-heavy input produces dictionary references', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40));
      final chain = _chainCommands(input);
      final rewritten = CommandBuffer(input.length);
      final references = applyStaticDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
      );
      expect(references, greaterThan(0));
    });

    test('deterministic', () {
      final input = Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40));
      final first = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 5),
      );
      expect(
        brotliCompress(input, options: const BrotliEncodeOptions(quality: 5)),
        orderedEquals(first),
      );
    });
  });

  group('ratio versus the Rust oracle', () {
    test('report small/short text sizes', () async {
      final cases = <String, Uint8List>{
        'phrase': Uint8List.fromList(utf8.encode(_dictionaryHeavy)),
        'phrase-x40': Uint8List.fromList(utf8.encode(_dictionaryHeavy * 40)),
        'english-1m': _text(1 * _kMiB),
      };
      final report = StringBuffer('static dictionary report (ours / Rust):\n');
      for (final entry in cases.entries) {
        for (final quality in <int>[5, 8]) {
          final ours = brotliCompress(
            entry.value,
            options: BrotliEncodeOptions(quality: quality),
          );
          final rust = await _oracleCompress(oracle, entry.value, quality);
          report.writeln(
            '  ${entry.key.padRight(12)} q$quality in='
            '${entry.value.length} ours=${ours.length} rust=${rust.length} '
            'ratio=${(ours.length / rust.length).toStringAsFixed(4)}',
          );
          expect(ours.length / rust.length, lessThan(1.5));
        }
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

CommandBuffer _chainCommands(Uint8List input) {
  final hasher = HashChainMatcher(
    bucketBits: 15,
    blockBits: 5,
    numLastDistances: 4,
  );
  final commands = CommandBuffer(input.length);
  createBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    commands,
    createSearchDistanceCache(),
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  return commands;
}

/// Serialises one parse with the plain writer (single meta-block).
int _serialisedBits(Uint8List input, CommandBuffer commands) {
  final writer = BitWriter();
  writer.writeBits(4, 0xB); // lgwin 22
  MetaBlockWriter().store(
    writer,
    input,
    0,
    input.length,
    commands,
    isLast: true,
  );
  writer.alignToByte();
  return writer.bitPosition;
}

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
