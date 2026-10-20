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
import 'package:brotli_neo/src/encoder/prepared_dictionary.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;
  final dictionary = _dictionary(64 * _kKiB);
  final prepared = BrotliPreparedDictionary(dictionary);

  group('prepared dictionary', () {
    test('holds the bytes and cache-friendly getters', () {
      expect(prepared.length, dictionary.length);
      expect(prepared.size, dictionary.length);
      expect(prepared.dictionary.length, dictionary.length);
      // A List<int> input is copied; a Uint8List is taken by reference.
      final copied = BrotliPreparedDictionary(<int>[1, 2, 3, 4, 5]);
      expect(copied.length, 5);
      expect(copied.dictionary, orderedEquals(<int>[1, 2, 3, 4, 5]));
      expect(
        () => BrotliPreparedDictionary(Uint8List(kMaxPreparedDictionarySize + 1)),
        throwsArgumentError,
      );
    });

    test('prepared output is byte-identical to compoundDictionary', () {
      final input = _payloadFrom(dictionary, 300000);
      for (final quality in <int>[5, 8, 11]) {
        final viaPrepared = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            preparedDictionary: prepared,
          ),
        );
        final viaRaw = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            compoundDictionary: dictionary,
          ),
        );
        expect(
          viaPrepared,
          orderedEquals(viaRaw),
          reason: 'q$quality prepared vs raw',
        );
        expect(
          brotliDecompress(
            viaPrepared,
            options: BrotliDecodeOptions(compoundDictionary: dictionary),
          ),
          orderedEquals(input),
        );
      }
    });

    test('prepared takes precedence over compoundDictionary', () {
      final input = _payloadFrom(dictionary, 100000);
      final other = _dictionary(16 * _kKiB);
      final viaBoth = brotliCompress(
        input,
        options: BrotliEncodeOptions(
          quality: 5,
          compoundDictionary: other,
          preparedDictionary: prepared,
        ),
      );
      final viaPrepared = brotliCompress(
        input,
        options: BrotliEncodeOptions(
          quality: 5,
          preparedDictionary: prepared,
        ),
      );
      expect(viaBoth, orderedEquals(viaPrepared));
    });

    test('one prepared instance is reusable and stateless', () {
      final inputs = <Uint8List>[
        _payloadFrom(dictionary, 50000),
        _payloadFrom(dictionary, 120000),
        _dictionary(20000),
      ];
      final first = <List<int>>[
        for (final input in inputs)
          brotliCompress(
            input,
            options: BrotliEncodeOptions(
              quality: 8,
              preparedDictionary: prepared,
            ),
          ),
      ];
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < inputs.length; i++) {
          final bytes = brotliCompress(
            inputs[i],
            options: BrotliEncodeOptions(
              quality: 8,
              preparedDictionary: prepared,
            ),
          );
          expect(bytes, orderedEquals(first[i]), reason: 'round $round #$i');
          expect(
            brotliDecompress(
              bytes,
              options: BrotliDecodeOptions(compoundDictionary: dictionary),
            ),
            orderedEquals(inputs[i]),
          );
        }
      }
    });

    test('streaming encoder accepts a prepared dictionary', () {
      final input = _payloadFrom(dictionary, 400000);
      final encoder = BrotliEncoder(
        options: BrotliEncodeOptions(quality: 8, preparedDictionary: prepared),
      );
      final output = <int>[];
      for (var offset = 0; offset < input.length; offset += 50000) {
        final end = min(offset + 50000, input.length);
        encoder.add(
          Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)),
        );
        encoder.flush();
        output.addAll(encoder.takeOutputBytes());
      }
      encoder.finish();
      output.addAll(encoder.takeOutputBytes());
      final stream = Uint8List.fromList(output);
      expect(
        brotliDecompress(
          stream,
          options: BrotliDecodeOptions(compoundDictionary: dictionary),
        ),
        orderedEquals(input),
      );
    });

    test('small and oversized dictionaries behave', () {
      for (final entry in <String, Uint8List>{
        'empty': Uint8List(0),
        'one': Uint8List.fromList(<int>[42]),
        '64k': dictionary,
      }.entries) {
        final preparedCase = BrotliPreparedDictionary(entry.value);
        final input = entry.value.length < 1024
            ? _text(40000)
            : _payloadFrom(entry.value, 150000);
        final stream = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: 5,
            lgwin: 10,
            preparedDictionary: preparedCase,
          ),
        );
        expect(stream.length, lessThan(input.length));
        expect(
          brotliDecompress(
            stream,
            options: BrotliDecodeOptions(compoundDictionary: entry.value),
          ),
          orderedEquals(input),
          reason: entry.key,
        );
      }
    });

    test('dictionary indexes are reused (telemetry)', () {
      final input = _payloadFrom(dictionary, 200000);
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
        prepared.createMatcher(),
        Int32List.fromList(<int>[4, 11, 15, 16]),
      );
      expect(references, greaterThan(0));
      // Two matchers created from one prepared dictionary share the index.
      final a = prepared.createMatcher();
      final b = prepared.createMatcher();
      expect(identical(a.dictionary, b.dictionary), isTrue);
    });

    test('Rust oracle decodes prepared streams with --dictionary', () async {
      final input = _payloadFrom(dictionary, 300000);
      final dictPath = _writeTemp(dictionary, 'prepared_dict.bin');
      for (final quality in <int>[5, 8, 11]) {
        final stream = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            preparedDictionary: prepared,
          ),
        );
        final decoded = await _oracleDecompress(oracle, stream, dictPath);
        expect(
          _sha256(decoded),
          orderedEquals(_sha256(input)),
          reason: 'q$quality',
        );
      }
    }, skip: oracleSkipReason);
  });
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

Uint8List _payloadFrom(Uint8List dictionary, int size) {
  final out = Uint8List(size);
  final random = Random(11);
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
  final file = File(p.join(Directory.systemTemp.path, 'dart_brotli_$name'));
  file.writeAsBytesSync(bytes);
  return file.path;
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
  Uint8List compressed,
  String dictionaryPath,
) => _oracleRun(oracle, <String>[
  'decompress',
  '--dictionary',
  dictionaryPath,
  '-i',
  '-',
  '-o',
  '-',
], compressed);
