@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/decoder/bit_reader.dart';
import 'package:brotli_neo/src/decoder/decoder_core.dart';
import 'package:brotli_neo/src/decoder/decoder_state.dart';
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

/// Fully decoded stream plus the decoder state snapshot consulted by the
/// coverage assertions (state keeps the last metablock's header fields).
final class _Decoded {
  _Decoded(this.bytes, this.state);

  final Uint8List bytes;
  final DecoderState state;
}

enum _Kind { random, repeated, text, mixed }

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  group('oracle q0/q1/q5 streams (no static dictionary)', () {
    // The oracle is invoked with `--no-dictionary`, so these streams cannot
    // reference the RFC static dictionary: the compressed path is exercised
    // without help from the D4 word table, and any mis-decode fails the
    // byte-exact assertions.
    final cases = <String, ({_Kind kind, int size})>{
      'random-1k': (kind: _Kind.random, size: 1024),
      'repeated-10k': (kind: _Kind.repeated, size: 10000),
      'text-20k': (kind: _Kind.text, size: 20000),
      'mixed-64k': (kind: _Kind.mixed, size: 65536),
      'text-200k': (kind: _Kind.text, size: 200000),
    };

    for (final testCase in cases.entries) {
      test(
        '${testCase.key} is byte-exact at q0/q1/q5 and lgwin 10/16/22',
        () async {
          final raw = _data(testCase.value.kind, testCase.value.size);
          for (final quality in <int>[0, 1, 5]) {
            for (final lgwin in <int>[10, 16, 22]) {
              final compressed = await _oracleCompress(
                oracle,
                raw,
                quality: quality,
                lgwin: lgwin,
              );
              final decoded = _decode(compressed);
              _expectBytes(
                decoded.bytes,
                raw,
                '${testCase.key} q$quality w$lgwin',
              );
              expect(
                compressed.length,
                greaterThan(0),
                reason: '${testCase.key} q$quality w$lgwin',
              );
            }
          }
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    }

    test('q5 text actually exercises compressed metablocks', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await _oracleCompress(
        oracle,
        raw,
        quality: 5,
        lgwin: 22,
      );
      expect(compressed.length, lessThan(raw.length ~/ 2));
      _expectBytes(_decode(compressed).bytes, raw, 'q5 text-20k');
    });

    test('tiny output buffers and eager/non-eager modes agree', () async {
      final raw = _data(_Kind.repeated, 10000);
      final compressed = await _oracleCompress(
        oracle,
        raw,
        quality: 5,
        lgwin: 10, // 1 KiB window: forces ring-buffer wrap during the copy loop
      );
      for (final eager in <bool>[true, false]) {
        for (final chunkSize in <int>[1, 2, 3, 7, 17, 4096]) {
          final decoded = _decode(
            compressed,
            chunkSize: chunkSize,
            eagerOutput: eager,
          );
          _expectBytes(decoded.bytes, raw, 'chunk=$chunkSize eager=$eager');
        }
      }
    });

    test('maxOutputSize stops a compressed stream at the limit', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await _oracleCompress(
        oracle,
        raw,
        quality: 5,
        lgwin: 22,
      );
      expect(
        () => _decode(compressed, maxOutputSize: raw.length - 1),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
      final decoded = _decode(compressed, maxOutputSize: raw.length);
      _expectBytes(decoded.bytes, raw, 'exact output limit');
    });

    test(
      'transcoding survives a 1-byte output buffer with wrap-around',
      () async {
        final raw = _data(_Kind.mixed, 65536);
        final compressed = await _oracleCompress(
          oracle,
          raw,
          quality: 1,
          lgwin: 10,
        );
        final decoded = _decode(compressed, chunkSize: 1);
        _expectBytes(decoded.bytes, raw, 'mixed-64k w10 chunk=1');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '1-byte input chunks resume header, context map and hot loops',
      () async {
        // D5 feeds input incrementally; the compressed-header step machine and
        // the hot loops must suspend and resume without corrupting state.
        final raw = _data(_Kind.text, 20000);
        final compressed = await _oracleCompress(
          oracle,
          raw,
          quality: 5,
          lgwin: 22,
        );
        for (final inputChunk in <int>[1, 3, 17]) {
          for (final outputChunk in <int>[1, 7, 4096]) {
            final decoded = _decodeStreaming(
              compressed,
              inputChunk: inputChunk,
              outputChunk: outputChunk,
            );
            _expectBytes(decoded, raw, 'input=$inputChunk output=$outputChunk');
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
    test('large-window compressed streams decode when enabled', () async {
      final raw = _data(_Kind.text, 20000);
      final compressed = await _oracleCompress(
        oracle,
        raw,
        quality: 5,
        lgwin: 26,
        largeWindow: true,
      );
      final decoded = _decode(compressed, allowLargeWindow: true);
      _expectBytes(decoded.bytes, raw, 'large-window q5 w26');
      expect(decoded.state.largeWindow, isTrue);
      expect(
        () => _decode(compressed),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidWindowBits,
          ),
        ),
      );
    });
  }, skip: oracleSkipReason);

  group('block switching and context maps (corpus)', () {
    test('mapsdatazrh uses multiple block types, trees and context maps', () {
      final decoded = _decode(corpus.compressedBytes(entry('mapsdatazrh')));
      _expectBytes(
        decoded.bytes,
        corpus.rawBytes(entry('mapsdatazrh')),
        'mapsdatazrh',
      );
      final state = decoded.state;
      expect(state.numLiteralBlockTypes, greaterThan(1));
      expect(state.numCommandBlockTypes, greaterThan(1));
      expect(state.numDistanceBlockTypes, greaterThan(1));
      expect(state.numLiteralTrees, greaterThan(1));
      expect(state.numDistTrees, greaterThan(1));
      expect(state.trivialLiteralContext, isFalse);
    });

    test('zerosukkanooa exercises distance postfix/direct codes', () {
      final decoded = _decode(corpus.compressedBytes(entry('zerosukkanooa')));
      _expectBytes(
        decoded.bytes,
        corpus.rawBytes(entry('zerosukkanooa')),
        'zerosukkanooa',
      );
      expect(decoded.state.numDistTrees, greaterThan(1));
      expect(decoded.state.numDirectDistanceCodes, greaterThan(0));
    });

    test('block-switch heavy streams decode with tiny output buffers', () {
      for (final name in <String>['mapsdatazrh', 'compressed_repeated']) {
        final e = entry(name);
        final raw = corpus.rawBytes(e);
        final compressed = corpus.compressedBytes(e);
        for (final eager in <bool>[true, false]) {
          for (final chunkSize in <int>[7, 4096]) {
            final decoded = _decode(
              compressed,
              chunkSize: chunkSize,
              eagerOutput: eager,
            );
            _expectBytes(
              decoded.bytes,
              raw,
              '$name chunk=$chunkSize eager=$eager',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('chunked input resumes multi-tree headers and block switches', () {
      // compressed_repeated has 2 literal block types and 4 literal trees;
      // mapsdatazrh has 14/6/9 block types and 19/9 trees. Feeding the
      // compressed header a few bytes at a time exercises memento restarts in
      // the tree-group loops and the resumable context-map cursors.
      final repeated = entry('compressed_repeated');
      _expectBytes(
        _decodeStreaming(
          corpus.compressedBytes(repeated),
          inputChunk: 3,
          outputChunk: 7,
        ),
        corpus.rawBytes(repeated),
        'compressed_repeated chunked input',
      );
      final maps = entry('mapsdatazrh');
      _expectBytes(
        _decodeStreaming(
          corpus.compressedBytes(maps),
          inputChunk: 64,
          outputChunk: 4096,
        ),
        corpus.rawBytes(maps),
        'mapsdatazrh chunked input',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('static dictionary (D4)', () {
    // Vectors that reference the RFC static dictionary. D4 decodes them
    // byte-exact; only their dictionary-reference counters prove the path ran.
    const expectedDictionaryVectors = <String>{
      'alice29.txt',
      'asyoulik.txt',
      'cp852-utf8',
      'lcet10.txt',
      'monkey',
      'plrabn12.txt',
      'quickfox_repeated',
    };

    test(
      'corpus vectors decode byte-exact, using the dictionary where expected',
      () {
        final withDictionary = <String>{};
        for (final e in corpus.entries) {
          final decoded = _decode(corpus.compressedBytes(e));
          _expectBytes(decoded.bytes, corpus.rawBytes(e), e.name);
          if (decoded.state.dictionaryReferenceCount > 0) {
            withDictionary.add(e.name);
          }
        }
        expect(withDictionary, expectedDictionaryVectors);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('dictionary-heavy streams decode with tiny output chunks', () {
      const name = 'monkey';
      final raw = corpus.rawBytes(entry(name));
      for (final eager in <bool>[true, false]) {
        for (final chunkSize in <int>[1, 7, 4096]) {
          final decoded = _decode(
            corpus.compressedBytes(entry(name)),
            chunkSize: chunkSize,
            eagerOutput: eager,
          );
          _expectBytes(
            decoded.bytes,
            raw,
            '$name chunk=$chunkSize eager=$eager',
          );
          expect(decoded.state.dictionaryReferenceCount, greaterThan(0));
        }
      }
    });

    test(
      'every corpus vector survives 7-byte input / 13-byte output chunks',
      () {
        for (final e in corpus.entries) {
          final decoded = _decodeStreaming(
            corpus.compressedBytes(e),
            inputChunk: 7,
            outputChunk: 13,
          );
          _expectBytes(decoded, corpus.rawBytes(e), e.name);
        }
      },
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });

  group('malformed and truncated streams', () {
    test(
      'every truncation of a valid stream throws BrotliException',
      () async {
        final raw = _data(_Kind.repeated, 300);
        final compressed = await _oracleCompress(
          oracle,
          raw,
          quality: 5,
          lgwin: 22,
        );
        for (var length = 0; length < compressed.length; length++) {
          final prefix = Uint8List.sublistView(compressed, 0, length);
          try {
            _decode(prefix);
            fail('truncated stream at $length bytes decoded successfully');
          } on BrotliException {
            // Expected: any format/truncation error is fine.
          }
        }
      },
      skip: oracleSkipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'sampled truncations of a larger stream throw BrotliException',
      () async {
        final raw = _data(_Kind.text, 20000);
        final compressed = await _oracleCompress(
          oracle,
          raw,
          quality: 1,
          lgwin: 22,
        );
        final lengths = <int>{
          0,
          1,
          2,
          3,
          4,
          5,
          7,
          11,
          13,
          compressed.length ~/ 4,
          compressed.length ~/ 2,
          compressed.length - 2,
          compressed.length - 1,
        };
        for (final length in lengths) {
          final prefix = Uint8List.sublistView(compressed, 0, length);
          try {
            _decode(prefix);
            fail('truncated stream at $length bytes decoded successfully');
          } on BrotliException {
            // Expected.
          }
        }
      },
      skip: oracleSkipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'bit-flipped streams never escape as non-Brotli exceptions',
      () async {
        final raw = _data(_Kind.text, 5000);
        final compressed = await _oracleCompress(
          oracle,
          raw,
          quality: 5,
          lgwin: 22,
        );
        final random = Random(0xD3);
        for (var i = 0; i < 600; i++) {
          final mutated = Uint8List.fromList(compressed);
          final index = random.nextInt(mutated.length);
          mutated[index] ^= 1 << random.nextInt(8);
          try {
            _decode(mutated);
          } on BrotliException {
            // Expected for most mutations; a mutation that still decodes is a
            // valid stream by definition, so it is not an error either.
          }
        }
      },
      skip: oracleSkipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('corrupt header bytes always raise BrotliException', () {
      // First bytes of a real compressed vector: corrupting the window-bits /
      // metablock header must not reach a Dart RangeError or hang.
      final base = corpus.compressedBytes(entry('zeros'));
      for (var index = 0; index < 8 && index < base.length; index++) {
        for (var bit = 0; bit < 8; bit++) {
          final mutated = Uint8List.fromList(base);
          mutated[index] ^= 1 << bit;
          try {
            _decode(mutated);
          } on BrotliException {
            // Expected.
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// [BitReaderInput] whose bytes are released to the decoder in small pieces,
/// simulating a push/streaming source.
final class _ChunkedInput implements BitReaderInput {
  _ChunkedInput(this.bytes);

  final Uint8List bytes;
  int _released = 0;
  int _offset = 0;
  bool _closed = false;

  bool get releasedAll => _released >= bytes.length;

  void release(int count) {
    _released += count;
    if (_released > bytes.length) {
      _released = bytes.length;
    }
  }

  void close() => _closed = true;

  @override
  bool get isClosed => _closed;

  @override
  int readInto(Uint8List destination, int offset, int length) {
    final available = _released - _offset;
    if (available <= 0 || length <= 0) {
      return 0;
    }
    final count = available < length ? available : length;
    destination.setRange(offset, offset + count, bytes, _offset);
    _offset += count;
    return count;
  }
}

/// Decodes [compressed] while releasing input [inputChunk] bytes at a time.
Uint8List _decodeStreaming(
  Uint8List compressed, {
  required int inputChunk,
  required int outputChunk,
}) {
  final input = _ChunkedInput(compressed);
  final core = BrotliDecoderCore(BitReader(input));
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(outputChunk);
  var guard = 0;
  while (true) {
    final status = core.decode(buffer);
    final written = core.bytesWritten;
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      return builder.takeBytes();
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(input.isClosed, isFalse, reason: 'input demand after close');
      input.release(inputChunk);
      if (input.releasedAll) {
        input.close();
      }
    }
    guard++;
    if (guard > 1 << 20) {
      throw StateError('decoder made no progress while feeding input');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Decodes a complete stream, failing on input suspension (in-memory input is
/// always closed).
_Decoded _decode(
  Uint8List compressed, {
  int chunkSize = 64 * 1024,
  bool eagerOutput = true,
  bool allowLargeWindow = false,
  int? maxOutputSize,
}) {
  final core = BrotliDecoderCore(
    BitReader.fromBytes(compressed),
    eagerOutput: eagerOutput,
    allowLargeWindow: allowLargeWindow,
    maxOutputSize: maxOutputSize,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(chunkSize);
  var stallGuard = 0;
  while (true) {
    final status = core.decode(buffer);
    final written = core.bytesWritten;
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      throw BrotliException(
        BrotliErrorCode.truncatedInput,
        'decoder requested input from a closed stream',
      );
    }
    if (written == 0) {
      stallGuard++;
      if (stallGuard > 1 << 20) {
        throw StateError('decoder made no progress');
      }
    }
  }
  return _Decoded(builder.takeBytes(), core.state);
}

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

/// Compresses [raw] with the Rust oracle, disabling the static dictionary so the
/// output is guaranteed to stay decodable by D3.
Future<Uint8List> _oracleCompress(
  File oracle,
  Uint8List raw, {
  required int quality,
  required int lgwin,
  bool largeWindow = false,
}) async {
  final arguments = <String>[
    'compress',
    '-q',
    '$quality',
    '-w',
    '$lgwin',
    '--no-dictionary',
    '-i',
    '-',
    '-o',
    '-',
  ];
  if (largeWindow) {
    arguments.add('--large-window');
  }
  final process = await Process.start(oracle.path, arguments);
  final stdoutFuture = _collect(process.stdout);
  final stderrFuture = _collect(process.stderr);
  process.stdin.add(raw);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final stderrBytes = await stderrFuture;
  final compressed = await stdoutFuture;
  if (exitCode != 0) {
    throw StateError(
      'oracle compress failed (exit $exitCode): '
      '${utf8.decode(stderrBytes, allowMalformed: true)}',
    );
  }
  return compressed;
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Deterministic test data (no fixtures on disk, no dependency on encoders).
Uint8List _data(_Kind kind, int size) {
  switch (kind) {
    case _Kind.random:
      final random = Random(0xB07 + size);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = random.nextInt(256);
      }
      return bytes;
    case _Kind.repeated:
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = i % 97;
      }
      return bytes;
    case _Kind.text:
      const words = <String>[
        'the ',
        'quick ',
        'brown ',
        'fox ',
        'jumps ',
        'over ',
        'lazy ',
        'dog ',
        'and ',
        'then ',
        'runs ',
        'away. ',
      ];
      final builder = StringBuffer();
      var seed = 12345;
      while (builder.length < size) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        builder.write(words[seed % words.length]);
      }
      final encoded = utf8.encode(builder.toString());
      return Uint8List.fromList(encoded.sublist(0, size));
    case _Kind.mixed:
      final random = Random(99);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = i % 1024 < 512 ? random.nextInt(256) : (i * 7) & 0xFF;
      }
      return bytes;
  }
}
