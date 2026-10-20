@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/encoder/backward_references.dart';
import 'package:brotli_neo/src/encoder/command.dart';
import 'package:brotli_neo/src/encoder/compound_dictionary.dart';
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
  final dict = _dictionary(64 * _kKiB);

  group('compound dictionary encoding', () {
    test('payload built from the dictionary round-trips', () async {
      final input = _payloadFrom(dict, 1 * _kMiB);
      for (final quality in <int>[5, 8, 11]) {
        for (final lgwin in <int>[10, 16, 22, 24]) {
          final stream = brotliCompress(
            input,
            options: BrotliEncodeOptions(
              quality: quality,
              lgwin: lgwin,
              compoundDictionary: dict,
            ),
          );
          final decoded = brotliDecompress(
            stream,
            options: BrotliDecodeOptions(compoundDictionary: dict),
          );
          expect(decoded, orderedEquals(input), reason: 'q$quality w$lgwin');
          final oracleDecoded = await _oracleDecompress(
            oracle,
            stream,
            dictionaryPath: _writeTemp(dict, 'dict.bin'),
          );
          expect(
            _sha256(oracleDecoded),
            orderedEquals(_sha256(input)),
            reason: 'oracle q$quality w$lgwin',
          );
          expect(
            stream.length,
            lessThanOrEqualTo(maxCompressedSize(input.length)),
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 12)));

    test('dictionary sizes 0/1/4 KiB/64 KiB and dictionary > window', () async {
      final cases = <String, Uint8List>{
        'empty': Uint8List(0),
        'one': Uint8List.fromList(<int>[7]),
        '4k': _dictionary(4 * _kKiB),
        '64k': dict,
      };
      for (final entry in cases.entries) {
        final input = entry.value.length < 1024
            ? _text(50000)
            : _payloadFrom(entry.value, 200000);
        final stream = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: 5,
            lgwin: 10, // window far smaller than the 64 KiB dictionary
            compoundDictionary: entry.value,
          ),
        );
        final decoded = brotliDecompress(
          stream,
          options: BrotliDecodeOptions(compoundDictionary: entry.value),
        );
        expect(decoded, orderedEquals(input), reason: entry.key);
      }
    });

    test('without the dictionary the stream does not decode to the input', () {
      final input = _payloadFrom(dict, 300000);
      final stream = brotliCompress(
        input,
        options: BrotliEncodeOptions(quality: 5, compoundDictionary: dict),
      );
      var rejectedOrDifferent = false;
      try {
        final decoded = brotliDecompress(stream);
        rejectedOrDifferent =
            decoded.length != input.length || !_equal(decoded, input);
      } catch (_) {
        rejectedOrDifferent = true;
      }
      expect(rejectedOrDifferent, isTrue);
    });

    test('streaming encoder supports a compound dictionary', () {
      final input = _payloadFrom(dict, 500000);
      final encoder = BrotliEncoder(
        options: BrotliEncodeOptions(quality: 8, compoundDictionary: dict),
      );
      final output = <int>[];
      for (var offset = 0; offset < input.length; offset += 40000) {
        final end = min(offset + 40000, input.length);
        encoder.add(
          Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)),
        );
        encoder.flush();
        output.addAll(encoder.takeOutputBytes());
      }
      encoder.finish();
      output.addAll(encoder.takeOutputBytes());
      final stream = Uint8List.fromList(output);
      expect(encoder.isFinished, isTrue);
      expect(
        brotliDecompress(
          stream,
          options: BrotliDecodeOptions(compoundDictionary: dict),
        ),
        orderedEquals(input),
      );
    });

    test('deterministic and produces dictionary references', () {
      final input = _payloadFrom(dict, 300000);
      final options = BrotliEncodeOptions(quality: 5, compoundDictionary: dict);
      final first = brotliCompress(input, options: options);
      expect(brotliCompress(input, options: options), orderedEquals(first));
      // Telemetry through the internal rewrite.
      final hasher = HashChainMatcher(
        bucketBits: 15,
        blockBits: 8,
        numLastDistances: 16,
      );
      final chain = CommandBuffer(input.length);
      createBackwardReferences(
        input,
        0,
        input.length,
        hasher,
        chain,
        createSearchDistanceCache(),
        (1 << 22) - 16,
        extensiveSearch: true,
      );
      final rewritten = CommandBuffer(input.length);
      final references = applyCompoundDictionaryMatches(
        input,
        0,
        input.length,
        chain,
        rewritten,
        (1 << 22) - 16,
        CompoundDictionaryMatcher(dict),
        Int32List.fromList(<int>[4, 11, 15, 16]),
      );
      expect(references, greaterThan(0));
    });

    test('the dictionary payload is smaller than without it', () {
      final input = _payloadFrom(dict, 1 * _kMiB);
      for (final quality in <int>[5, 8]) {
        final withDictionary = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            compoundDictionary: dict,
          ),
        );
        final without = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          withDictionary.length,
          lessThan(without.length),
          reason: 'q$quality should profit from the dictionary',
        );
      }
    });
  });

  group('ratio versus the Rust oracle', () {
    test('report compound-dictionary sizes', () async {
      final input = _payloadFrom(dict, 1 * _kMiB);
      final dictPath = _writeTemp(dict, 'dict.bin');
      final report = StringBuffer('compound dictionary report (ours / Rust):\n');
      for (final quality in <int>[5, 8]) {
        final ours = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            compoundDictionary: dict,
          ),
        );
        final rust = await _oracleCompress(
          oracle,
          input,
          quality,
          dictionaryPath: dictPath,
        );
        report.writeln(
          '  q$quality in=${input.length} ours=${ours.length} '
          'rust=${rust.length} '
          'ratio=${(ours.length / rust.length).toStringAsFixed(4)}',
        );
        // The ratio is reported for information: Rust's compound-dictionary
        // parser finds longer matches on this synthetic payload. The hard
        // requirement is that attaching the dictionary never makes our output
        // larger.
        final without = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(ours.length, lessThan(without.length), reason: 'q$quality');
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Fixtures and oracle helpers
// ---------------------------------------------------------------------------

final Uint8List _alice = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();

Uint8List _dictionary(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = _alice[i % _alice.length];
  }
  return out;
}

Uint8List _text(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = _alice[i % _alice.length];
  }
  return out;
}

/// Builds [size] bytes out of pseudo-random slices of [dictionary].
Uint8List _payloadFrom(Uint8List dictionary, int size) {
  final out = Uint8List(size);
  final random = Random(7);
  var pos = 0;
  while (pos < size) {
    final start = random.nextInt(max(1, dictionary.length - 600));
    final length = 80 + random.nextInt(400);
    for (var i = 0; i < length && pos < size; i++) {
      out[pos++] = dictionary[start + i];
    }
  }
  return out;
}

String _writeTemp(Uint8List bytes, String name) {
  final file = File(
    p.join(Directory.systemTemp.path, 'dart_brotli_$name'),
  );
  file.writeAsBytesSync(bytes);
  return file.path;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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

Future<Uint8List> _oracleDecompress(
  File oracle,
  Uint8List compressed, {
  required String dictionaryPath,
}) => _oracleRun(oracle, <String>[
  'decompress',
  '--dictionary',
  dictionaryPath,
  '-i',
  '-',
  '-o',
  '-',
], compressed);

Future<Uint8List> _oracleCompress(
  File oracle,
  Uint8List input,
  int quality, {
  required String dictionaryPath,
}) => _oracleRun(oracle, <String>[
  'compress',
  '-q',
  '$quality',
  '--dictionary',
  dictionaryPath,
  '-i',
  '-',
  '-o',
  '-',
], input);
