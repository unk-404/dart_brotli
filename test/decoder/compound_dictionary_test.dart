/// Compound ("shared" / prepended) dictionary support, D7.
///
/// The committed fixtures under `compound_vectors/` were produced by the
/// authoritative Rust oracle (`brotli` crate 9.0.0) with its
/// `compress --dictionary FILE` path:
///
/// ```sh
/// brotli-oracle compress -i text.raw -o text.br --dictionary text.dict -q 5 -w 22
/// brotli-oracle compress -i window.raw -o window.br --dictionary window.dict -q 5 -w 10
/// ```
///
/// `window` exercises a 6 KiB dictionary with an lgwin 10 stream (the ring
/// window is 1 KiB), so the compound copy and the ring flushes both matter.
/// The Rust encoder disables the built-in static dictionary when a custom
/// dictionary is attached, so the oracle vectors use compound references only;
/// the static-dictionary address shift is covered by the arithmetic unit tests
/// at the bottom of this file.
///
/// The environment-driven tests below re-generate the same kind of stream from
/// `$BROTLI_ORACLE` when it is available; they are skipped otherwise. The
/// oracle path comes from the environment only; no repository-local path is
/// hard-coded here.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart' show Bytes, brotliDecode;
import 'package:brotli_neo/compat.dart';
import 'package:brotli_neo/src/decoder/decoder_metablock.dart'
    show isCompoundDictionaryDistance, staticDictionaryAddress;
import 'package:test/test.dart';

import '../support/corpus.dart';

/// One compressed stream plus the dictionary/plaintext it belongs to.
final class _Vector {
  _Vector({
    required this.name,
    required this.dictionary,
    required this.raw,
    required this.compressed,
  });

  final String name;
  final Uint8List dictionary;
  final Uint8List raw;
  final Uint8List compressed;
}

const String _fixtureRoot = 'test/decoder/compound_vectors';

Uint8List _fixture(String name) =>
    File('$_fixtureRoot/$name').readAsBytesSync();

void _expectBytes(Uint8List actual, Uint8List expected, String reason) {
  expect(actual.length, expected.length, reason: '$reason: length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail(
        '$reason: first difference at byte $i '
        '(${actual[i]} != ${expected[i]})',
      );
    }
  }
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

void _expectBrotliException(
  void Function() action,
  String reason, {
  BrotliErrorCode? code,
}) {
  try {
    action();
    fail('$reason: expected a BrotliException');
  } on BrotliException catch (error) {
    if (code != null) {
      expect(error.code, code, reason: '$reason: error code');
    }
  }
}

/// Result of pumping a [BrotliDecoder] to completion.
final class _StreamResult {
  _StreamResult(this.bytes, this.compoundReferences);

  final Uint8List bytes;
  final int compoundReferences;
}

/// Push-decodes [compressed] with the attached [dictionary], feeding
/// [inputChunk] bytes only when requested and decoding into [outputChunk].
_StreamResult _streamDecode(
  Uint8List compressed,
  Uint8List? dictionary, {
  required int inputChunk,
  required int outputChunk,
}) {
  final decoder = BrotliDecoder(
    options: BrotliDecodeOptions(compoundDictionary: dictionary),
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(outputChunk);
  var offset = 0;
  var closed = false;
  var wantInput = true;
  var calls = 0;
  while (true) {
    if (wantInput) {
      if (offset < compressed.length) {
        final end = offset + inputChunk < compressed.length
            ? offset + inputChunk
            : compressed.length;
        decoder.addInput(Uint8List.sublistView(compressed, offset, end));
        offset = end;
      } else if (!closed) {
        decoder.closeInput();
        closed = true;
      }
      wantInput = false;
    }
    calls++;
    expect(calls, lessThan(1 << 22), reason: 'decoder made no progress');
    final status = decoder.decode(buffer);
    final written = decoder.bytesWritten;
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(closed, isFalse, reason: 'input requested after closeInput');
      wantInput = true;
      continue;
    }
    expect(written, greaterThan(0), reason: 'needMoreOutput made no progress');
  }
  expect(decoder.consumedInput, compressed.length);
  expect(decoder.isDone, isTrue);
  return _StreamResult(
    builder.takeBytes(),
    decoder.compoundDictionaryReferenceCount,
  );
}

void main() {
  final text = _Vector(
    name: 'text',
    dictionary: _fixture('text.dict'),
    raw: _fixture('text.raw'),
    compressed: _fixture('text.br'),
  );
  final windowed = _Vector(
    name: 'window',
    dictionary: _fixture('window.dict'),
    raw: _fixture('window.raw'),
    compressed: _fixture('window.br'),
  );
  final vectors = <_Vector>[text, windowed];

  group('oracle fixtures: one-shot', () {
    for (final vector in vectors) {
      test('${vector.name} decodes byte-exactly with its dictionary', () {
        final decoded = brotliDecompress(
          vector.compressed,
          options: BrotliDecodeOptions(compoundDictionary: vector.dictionary),
        );
        _expectBytes(decoded, vector.raw, vector.name);
      });
    }

    test('dictionary is larger than the lgwin 10 ring window', () {
      expect(windowed.dictionary.length, greaterThan(1 << 10));
      expect(windowed.compressed.length, lessThan(64));
    });

    test('dictionary references are actually exercised', () {
      final oneShot = _streamDecode(
        text.compressed,
        text.dictionary,
        inputChunk: 4096,
        outputChunk: 4096,
      );
      expect(oneShot.compoundReferences, greaterThan(0));
      _expectBytes(oneShot.bytes, text.raw, 'text compound refs');
    });
  });

  group('streaming decoder chunk matrix', () {
    for (final vector in vectors) {
      test('${vector.name}: input 1/2/3/7/4096 x output 1/3/17/4096', () {
        for (final inputChunk in <int>[1, 2, 3, 7, 4096]) {
          for (final outputChunk in <int>[1, 3, 17, 4096]) {
            final result = _streamDecode(
              vector.compressed,
              vector.dictionary,
              inputChunk: inputChunk,
              outputChunk: outputChunk,
            );
            _expectBytes(
              result.bytes,
              vector.raw,
              '${vector.name} in=$inputChunk out=$outputChunk',
            );
            expect(
              result.compoundReferences,
              greaterThan(0),
              reason: '${vector.name} in=$inputChunk out=$outputChunk',
            );
          }
        }
      });
    }
  });

  group('missing / wrong dictionary', () {
    for (final vector in vectors) {
      test('${vector.name}: missing, empty and 1-byte dictionaries throw', () {
        for (final (label, dictionary) in <(String, Uint8List?)>[
          ('missing', null),
          ('empty', Uint8List(0)),
          ('one byte', Uint8List.fromList(<int>[0x42])),
        ]) {
          _expectBrotliException(
            () => brotliDecompress(
              vector.compressed,
              options: BrotliDecodeOptions(compoundDictionary: dictionary),
            ),
            '${vector.name}/$label',
          );
        }
      });
    }

    test('streaming decoder throws for a missing dictionary, not crashes', () {
      final decoder = BrotliDecoder();
      decoder.addInput(text.compressed);
      decoder.closeInput();
      final out = Uint8List(4096);
      _expectBrotliException(() {
        while (true) {
          final status = decoder.decode(out);
          if (status == BrotliStatus.done) {
            break;
          }
          if (status == BrotliStatus.needMoreOutput &&
              decoder.bytesWritten == 0) {
            fail('no progress');
          }
        }
      }, 'streaming missing dictionary');
    });

    test('truncated dictionary with changed addressing throws', () {
      final half = Uint8List.sublistView(
        text.dictionary,
        0,
        text.dictionary.length ~/ 2,
      );
      _expectBrotliException(
        () => brotliDecompress(
          text.compressed,
          options: BrotliDecodeOptions(compoundDictionary: half),
        ),
        'truncated dictionary',
      );
    });

    test('maxOutputSize still caps compound-dictionary output', () {
      _expectBrotliException(
        () => brotliDecompress(
          windowed.compressed,
          options: BrotliDecodeOptions(
            compoundDictionary: windowed.dictionary,
            maxOutputSize: 128,
          ),
        ),
        'compound maxOutputSize',
        code: BrotliErrorCode.outputLimitExceeded,
      );
    });

    test(
      'same-length wrong dictionary changes output (no integrity check)',
      () {
        for (final vector in vectors) {
          final wrong = Uint8List.fromList(
            List<int>.generate(
              vector.dictionary.length,
              (i) => (i * 131 + 29) & 0xFF,
            ),
          );
          final decoded = brotliDecompress(
            vector.compressed,
            options: BrotliDecodeOptions(compoundDictionary: wrong),
          );
          expect(decoded.length, vector.raw.length, reason: vector.name);
          expect(
            _equalBytes(decoded, vector.raw),
            isFalse,
            reason: '${vector.name}: wrong dictionary must change the bytes',
          );
        }
      },
    );
  });

  group('non-dictionary streams are unaffected', () {
    final corpus = Corpus.load();
    final quickfox = corpus.entries.firstWhere((e) => e.name == 'quickfox');

    test('empty dictionary is identical to no dictionary', () {
      final plain = brotliDecompress(corpus.compressedBytes(quickfox));
      final withEmpty = brotliDecompress(
        corpus.compressedBytes(quickfox),
        options: BrotliDecodeOptions(compoundDictionary: Uint8List(0)),
      );
      _expectBytes(withEmpty, plain, 'empty dictionary');
      _expectBytes(withEmpty, corpus.rawBytes(quickfox), 'quickfox');
    });

    test('attached dictionary is harmless for streams that ignore it', () {
      for (final dictionary in <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(<int>[0x42]),
        text.dictionary,
      ]) {
        final decoded = brotliDecompress(
          corpus.compressedBytes(quickfox),
          options: BrotliDecodeOptions(compoundDictionary: dictionary),
        );
        _expectBytes(
          decoded,
          corpus.rawBytes(quickfox),
          'quickfox + ${dictionary.length}-byte dictionary',
        );
      }
    });

    test('our encoder output round-trips with a dictionary attached', () {
      final input = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 17 + 3 + (i >> 4)) & 0xFF),
      );
      final compressed = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 5),
      );
      for (final dictionary in <Uint8List?>[
        null,
        Uint8List(0),
        text.dictionary,
      ]) {
        final decoded = brotliDecompress(
          compressed,
          options: BrotliDecodeOptions(compoundDictionary: dictionary),
        );
        _expectBytes(decoded, input, 'self round-trip');
      }
    });
  });

  group('API plumbing', () {
    test('BrotliCodec one-shot and chunked conversion honour the option', () {
      final codec = BrotliCodec(
        decodeOptions: BrotliDecodeOptions(compoundDictionary: text.dictionary),
      );
      _expectBytes(
        codec.decodeBytes(text.compressed),
        text.raw,
        'codec.decodeBytes',
      );
      _expectBytes(
        Uint8List.fromList(codec.decode(text.compressed)),
        text.raw,
        'codec.decode',
      );

      final chunks = <Uint8List>[];
      final conversion = codec.decoder.startChunkedConversion(
        _CollectSink(chunks),
      );
      for (var i = 0; i < text.compressed.length; i++) {
        conversion.add(<int>[text.compressed[i]]);
      }
      conversion.close();
      final builder = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        builder.add(chunk);
      }
      _expectBytes(builder.takeBytes(), text.raw, 'codec chunked');
    });

    test('blit-native brotliDecode accepts a Bytes dictionary', () {
      final decoded = brotliDecode(
        Bytes.fromList(text.compressed),
        compoundDictionary: Bytes.fromList(text.dictionary),
      );
      _expectBytes(decoded.asUint8List(), text.raw, 'blit brotliDecode');

      final viaOptions = brotliDecode(
        Bytes.fromList(windowed.compressed),
        options: BrotliDecodeOptions(compoundDictionary: windowed.dictionary),
      );
      _expectBytes(
        viaOptions.asUint8List(),
        windowed.raw,
        'blit brotliDecode via options',
      );
    });
  });

  group('oracle-generated streams', () {
    final oracle = Platform.environment['BROTLI_ORACLE'];
    final available = oracle != null && File(oracle).existsSync();
    final skipReason = available
        ? false
        : 'BROTLI_ORACLE is not set (oracle-generated vectors are covered by '
              'the committed fixtures)';
    late Directory temp;

    setUpAll(() {
      if (!available) {
        return;
      }
      // Keep the scratch directory inside the workspace: sandboxed CI runners
      // may deny the oracle child write access to the system temp directory.
      final directory = Directory('build/test/compound_dictionary_oracle')
          .absolute;
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
      temp = directory..createSync(recursive: true);
    });

    tearDownAll(() {
      if (!available) {
        return;
      }
      temp.deleteSync(recursive: true);
    });

    test('compress --dictionary then decode byte-exactly', () {
      final dictionary = _deterministicBytes(3000, seed: 7);
      final raw = Uint8List.fromList(<int>[
        ...dictionary.sublist(800, 2000),
        ...'tail that is not in the dictionary'.codeUnits,
        ...dictionary.sublist(2400, 3000),
      ]);
      final compressed = _oracleCompress(
        oracle!,
        temp,
        raw: raw,
        dictionary: dictionary,
        extraArgs: <String>[],
      );
      // The authoritative decoder must agree with the raw input first.
      _oracleDecompress(
        oracle,
        temp,
        compressed: compressed,
        dictionary: dictionary,
        expected: raw,
      );

      final decoded = brotliDecompress(
        compressed,
        options: BrotliDecodeOptions(compoundDictionary: dictionary),
      );
      _expectBytes(decoded, raw, 'oracle default window');
      _expectBrotliException(
        () => brotliDecompress(compressed),
        'oracle stream without dictionary',
      );
      final streamed = _streamDecode(
        compressed,
        dictionary,
        inputChunk: 3,
        outputChunk: 5,
      );
      _expectBytes(streamed.bytes, raw, 'oracle default window streaming');
      expect(streamed.compoundReferences, greaterThan(0));
    }, skip: skipReason);

    test('lgwin 10 with a dictionary larger than the ring window', () {
      final dictionary = _deterministicBytes(6144, seed: 11);
      final raw = Uint8List.fromList(<int>[
        for (var i = 0; i < 5; i++) ...dictionary.sublist(5244, 6144),
        ...'END'.codeUnits,
      ]);
      final compressed = _oracleCompress(
        oracle!,
        temp,
        raw: raw,
        dictionary: dictionary,
        extraArgs: <String>['-w', '10'],
      );
      _oracleDecompress(
        oracle,
        temp,
        compressed: compressed,
        dictionary: dictionary,
        expected: raw,
      );

      final decoded = brotliDecompress(
        compressed,
        options: BrotliDecodeOptions(compoundDictionary: dictionary),
      );
      _expectBytes(decoded, raw, 'oracle lgwin 10');
      final streamed = _streamDecode(
        compressed,
        dictionary,
        inputChunk: 1,
        outputChunk: 7,
      );
      _expectBytes(streamed.bytes, raw, 'oracle lgwin 10 streaming');
      expect(streamed.compoundReferences, greaterThan(0));
    }, skip: skipReason);
  });

  group('dictionary address arithmetic', () {
    test('compound range is (maxDistance, maxDistance + size]', () {
      expect(isCompoundDictionaryDistance(100, 100, 10), isFalse);
      expect(isCompoundDictionaryDistance(101, 100, 10), isTrue);
      expect(isCompoundDictionaryDistance(110, 100, 10), isTrue);
      expect(isCompoundDictionaryDistance(111, 100, 10), isFalse);
      expect(isCompoundDictionaryDistance(101, 100, 0), isFalse);
      expect(isCompoundDictionaryDistance(101, 99, 2), isTrue);
    });

    test('static word address subtracts the compound size', () {
      expect(staticDictionaryAddress(101, 100, 0), 0);
      expect(staticDictionaryAddress(150, 100, 0), 49);
      expect(staticDictionaryAddress(101, 100, 50), -50);
      expect(staticDictionaryAddress(150, 100, 50), -1);
      expect(staticDictionaryAddress(151, 100, 50), 0);
      expect(staticDictionaryAddress(152, 100, 50), 1);
      expect(staticDictionaryAddress(0x7FFFFFFC, 0, 0), 0x7FFFFFFB);
    });

    test('compound and static regions cannot overlap', () {
      const compoundSize = 4096;
      const maxDistance = 0;
      for (final distance in <int>[1, 2, 100, 4095, 4096]) {
        expect(
          isCompoundDictionaryDistance(distance, maxDistance, compoundSize),
          isTrue,
          reason: 'distance $distance',
        );
        expect(
          staticDictionaryAddress(distance, maxDistance, compoundSize),
          lessThan(0),
          reason: 'distance $distance',
        );
      }
      expect(
        isCompoundDictionaryDistance(4097, maxDistance, compoundSize),
        isFalse,
      );
      expect(staticDictionaryAddress(4097, maxDistance, compoundSize), 0);
      // The vector dictionary has exactly this size.
      expect(text.dictionary.length, compoundSize);
    });
  });
}

/// Deterministic pseudo-random fixture bytes (dictionary contents).
Uint8List _deterministicBytes(int length, {required int seed}) {
  final bytes = Uint8List(length);
  var state = (seed * 2654435761 + 1) & 0xFFFFFFFF;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0xFFFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

int _oracleFileId = 0;

Uint8List _oracleCompress(
  String oracle,
  Directory temp, {
  required Uint8List raw,
  required Uint8List dictionary,
  required List<String> extraArgs,
}) {
  final id = _oracleFileId++;
  final rawPath = '${temp.path}/raw_$id.bin';
  final dictPath = '${temp.path}/dict_$id.bin';
  final brPath = '${temp.path}/out_$id.br';
  File(rawPath).writeAsBytesSync(raw);
  File(dictPath).writeAsBytesSync(dictionary);
  final result = Process.runSync(oracle, <String>[
    'compress',
    '-i',
    rawPath,
    '-o',
    brPath,
    '-q',
    '5',
    '--dictionary',
    dictPath,
    ...extraArgs,
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'oracle compress failed: ${result.stdout}${result.stderr}',
  );
  return File(brPath).readAsBytesSync();
}

void _oracleDecompress(
  String oracle,
  Directory temp, {
  required Uint8List compressed,
  required Uint8List dictionary,
  required Uint8List expected,
}) {
  final id = _oracleFileId++;
  final brPath = '${temp.path}/verify_$id.br';
  final dictPath = '${temp.path}/verify_dict_$id.bin';
  final outPath = '${temp.path}/verify_$id.out';
  File(brPath).writeAsBytesSync(compressed);
  File(dictPath).writeAsBytesSync(dictionary);
  final result = Process.runSync(oracle, <String>[
    'decompress',
    '-i',
    brPath,
    '-o',
    outPath,
    '--dictionary',
    dictPath,
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'oracle decompress failed: ${result.stdout}${result.stderr}',
  );
  _expectBytes(File(outPath).readAsBytesSync(), expected, 'oracle decompress');
}

/// Collects chunks from a chunked conversion.
final class _CollectSink implements Sink<List<int>> {
  _CollectSink(this.chunks);

  final List<Uint8List> chunks;

  @override
  void add(List<int> data) => chunks.add(Uint8List.fromList(data));

  @override
  void close() {}
}
