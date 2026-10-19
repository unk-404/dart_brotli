@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_neo/src/common/dictionary.dart';
import 'package:brotli_neo/src/common/dictionary_data.dart';
import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/common/format_tables.dart';
import 'package:brotli_neo/src/common/transforms.dart';
import 'package:brotli_neo/src/decoder/bit_reader.dart';
import 'package:brotli_neo/src/decoder/decoder_core.dart';
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// Fully decoded stream plus the diagnostics consulted by the assertions.
final class _Decoded {
  _Decoded(this.bytes, this.dictionaryReferences, this.ringBufferSize);

  final Uint8List bytes;
  final int dictionaryReferences;
  final int ringBufferSize;
}

/// Deterministic data used by the synthetic streams and the robustness tests.
const List<int> _wordTime = <int>[116, 105, 109, 101]; // dictionary word "time"

/// Transform 73 applied to dictionary word 0 of length 24:
/// `" the " + <script type="text/javas + " of the "` (37 bytes).
const List<int> _overflowWord = <int>[
  32,
  116,
  104,
  101,
  32,
  60,
  115,
  99,
  114,
  105,
  112,
  116,
  32,
  116,
  121,
  112,
  101,
  61,
  34,
  116,
  101,
  120,
  116,
  47,
  106,
  97,
  118,
  97,
  115,
  32,
  111,
  102,
  32,
  116,
  104,
  101,
  32,
];

void main() {
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  const dictionaryVectors = <String>{
    'alice29.txt',
    'asyoulik.txt',
    'cp852-utf8',
    'lcet10.txt',
    'monkey',
    'plrabn12.txt',
    'quickfox_repeated',
  };

  group('corpus 22/22', () {
    test('all corpus pairs decode byte-exact (eager output)', () {
      for (final e in corpus.entries) {
        final decoded = _decode(corpus.compressedBytes(e));
        _expectBytes(decoded.bytes, corpus.rawBytes(e), e.name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('all corpus pairs decode byte-exact (non-eager output)', () {
      for (final e in corpus.entries) {
        final decoded = _decode(
          corpus.compressedBytes(e),
          eagerOutput: false,
          chunkSize: 4096,
        );
        _expectBytes(decoded.bytes, corpus.rawBytes(e), e.name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('dictionary references are used by exactly the expected vectors', () {
      final withDictionary = <String>{};
      for (final e in corpus.entries) {
        final decoded = _decode(corpus.compressedBytes(e));
        expect(decoded.bytes.length, e.rawBytes, reason: e.name);
        if (decoded.dictionaryReferences > 0) {
          withDictionary.add(e.name);
        }
      }
      expect(withDictionary, dictionaryVectors);
      expect(
        _decode(corpus.compressedBytes(entry('monkey'))).dictionaryReferences,
        greaterThan(0),
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the seven dictionary vectors stream with 1-byte chunks', () {
      for (final name in dictionaryVectors) {
        final decoded = _decodeStreaming(
          corpus.compressedBytes(entry(name)),
          inputChunk: 1,
          outputChunk: 1,
        );
        _expectBytes(decoded, corpus.rawBytes(entry(name)), name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('all 22 vectors stream with 7-byte input / 13-byte output', () {
      for (final e in corpus.entries) {
        final decoded = _decodeStreaming(
          corpus.compressedBytes(e),
          inputChunk: 7,
          outputChunk: 13,
        );
        _expectBytes(decoded, corpus.rawBytes(e), e.name);
      }
    }, timeout: const Timeout(Duration(seconds: 180)));
  });

  group('synthetic dictionary boundary', () {
    test('a dictionary word ending exactly at the ring end is flushed', () {
      final stream = _buildDictionaryStream(
        insertLength: 1020,
        copyLength: 4,
        wordIndex: 0,
        transformIndex: 0,
      );
      final expected = <int>[..._fill(1020, 0x41), ..._wordTime];
      for (final eager in <bool>[true, false]) {
        for (final chunkSize in <int>[64 * 1024, 7, 1]) {
          final decoded = _decode(
            stream,
            eagerOutput: eager,
            chunkSize: chunkSize,
          );
          _expectBytes(
            decoded.bytes,
            Uint8List.fromList(expected),
            'ring-end chunk=$chunkSize eager=$eager',
          );
          expect(decoded.ringBufferSize, 1024);
          expect(decoded.dictionaryReferences, 1);
        }
      }
    });

    test('a transformed word overflowing the ring window wraps correctly', () {
      final stream = _buildDictionaryStream(
        insertLength: 1020,
        copyLength: 24,
        wordIndex: 0,
        transformIndex: 73,
      );
      final expected = <int>[..._fill(1020, 0x41), ..._overflowWord];
      for (final eager in <bool>[true, false]) {
        for (final chunkSize in <int>[64 * 1024, 7, 1]) {
          final decoded = _decode(
            stream,
            eagerOutput: eager,
            chunkSize: chunkSize,
          );
          _expectBytes(
            decoded.bytes,
            Uint8List.fromList(expected),
            'overflow chunk=$chunkSize eager=$eager',
          );
          expect(decoded.ringBufferSize, 1024);
          expect(decoded.dictionaryReferences, 1);
        }
      }
    });

    test('transformed-word overflow also works with a 64 KiB window', () {
      final stream = _buildDictionaryStream(
        insertLength: 65530,
        copyLength: 24,
        wordIndex: 0,
        transformIndex: 73,
        windowBits: 16,
      );
      final expected = <int>[..._fill(65530, 0x41), ..._overflowWord];
      for (final chunkSize in <int>[64 * 1024, 7]) {
        final decoded = _decode(stream, chunkSize: chunkSize);
        _expectBytes(
          decoded.bytes,
          Uint8List.fromList(expected),
          'w16 overflow chunk=$chunkSize',
        );
        expect(decoded.ringBufferSize, 65536);
        expect(decoded.dictionaryReferences, 1);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('invalid dictionary word lengths are rejected', () {
      for (final copyLength in <int>[3, 25]) {
        final stream = _buildDictionaryStream(
          insertLength: 0,
          copyLength: copyLength,
          wordIndex: 0,
          transformIndex: 0,
        );
        expect(
          () => _decode(stream),
          throwsA(
            isA<BrotliException>().having(
              (BrotliException ex) => ex.code,
              'code',
              BrotliErrorCode.invalidDictionaryWord,
            ),
          ),
          reason: 'copyLength=$copyLength',
        );
      }
    });

    test('transform index 121 is rejected', () {
      final stream = _buildDictionaryStream(
        insertLength: 0,
        copyLength: 4,
        wordIndex: 0,
        transformIndex: 121,
      );
      expect(
        () => _decode(stream),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidTransform,
          ),
        ),
      );
    });
  });

  group('transform goldens', () {
    test('dictionary word 0 of length 4 is "time"', () {
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(
        out,
        0,
        kDictionaryData,
        dictionaryWordOffset(4, 0),
        4,
        0,
      );
      expect(out.sublist(0, n), _wordTime);
    });

    test('transform 73 grows the length-24 word to 37 bytes', () {
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(
        out,
        0,
        kDictionaryData,
        dictionaryWordOffset(24, 0),
        24,
        73,
      );
      expect(n, 37);
      expect(out.sublist(0, n), _overflowWord);
    });

    test('all 121 transforms fit the documented 2259-byte aggregate', () {
      final input = Uint8List.fromList(<int>[
        111,
        49,
        50,
        51,
        52,
        53,
        54,
        55,
        56,
        57,
        97,
        98,
        99,
        100,
        101,
        102,
      ]);
      final out = Uint8List(2259);
      var offset = 0;
      for (var i = 0; i < 121; i++) {
        offset += transformDictionaryWord(
          out,
          offset,
          input,
          0,
          input.length,
          i,
        );
        out[offset++] = 0xFF;
      }
      expect(offset, 2259);
    });

    test('transform 44 capitalizes multibyte UTF-8', () {
      final input = Uint8List.fromList(<int>[113, 195, 166, 224, 164, 170]);
      final out = Uint8List(maxTransformedWordLength);
      final n = transformDictionaryWord(out, 0, input, 0, input.length, 44);
      expect(out.sublist(0, n), <int>[81, 195, 134, 224, 164, 175]);
    });
  });

  group('robustness', () {
    test('every truncation of a dictionary-heavy stream throws', () {
      final compressed = corpus.compressedBytes(entry('monkey'));
      for (var length = 0; length < compressed.length; length++) {
        final prefix = Uint8List.sublistView(compressed, 0, length);
        try {
          _decode(prefix);
          fail('truncated stream at $length bytes decoded successfully');
        } on BrotliException {
          // Expected.
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('sampled truncations of alice29.txt throw BrotliException', () {
      final compressed = corpus.compressedBytes(entry('alice29.txt'));
      final lengths = <int>{
        0,
        1,
        2,
        3,
        5,
        8,
        13,
        21,
        34,
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
    }, timeout: const Timeout(Duration(seconds: 120)));

    test(
      'bit-flipped dictionary streams never escape as non-Brotli errors',
      () {
        final compressed = corpus.compressedBytes(entry('monkey'));
        var seed = 0xD4;
        for (var i = 0; i < 600; i++) {
          final mutated = Uint8List.fromList(compressed);
          seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
          final index = seed % mutated.length;
          mutated[index] ^= 1 << ((seed >> 16) & 7);
          try {
            _decode(mutated);
          } on BrotliException {
            // Expected for most mutations; some mutations decode to a different
            // valid stream, which is not an error.
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}

// ---------------------------------------------------------------------------
// Decode helpers.
// ---------------------------------------------------------------------------

/// Decodes a complete stream, failing on input suspension (input is closed).
_Decoded _decode(
  Uint8List compressed, {
  int chunkSize = 64 * 1024,
  bool eagerOutput = true,
}) {
  final core = BrotliDecoderCore(
    BitReader.fromBytes(compressed),
    eagerOutput: eagerOutput,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(chunkSize);
  var guard = 0;
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
      guard++;
      if (guard > 1 << 20) {
        throw StateError('decoder made no progress');
      }
    }
  }
  return _Decoded(
    builder.takeBytes(),
    core.state.dictionaryReferenceCount,
    core.state.ringBufferSize,
  );
}

/// [BitReaderInput] that releases bytes to the decoder in small pieces.
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
      input.release(inputChunk);
      if (input.releasedAll) {
        input.close();
      }
    }
    guard++;
    if (guard > 1 << 21) {
      throw StateError('decoder made no progress while feeding input');
    }
  }
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

List<int> _fill(int length, int byte) => List<int>.filled(length, byte);

// ---------------------------------------------------------------------------
// Hand-built compressed metablock containing a single dictionary reference.
// ---------------------------------------------------------------------------

/// LSB-first bit packer.
final class _BitSink {
  final List<int> _bytes = <int>[];
  int _current = 0;
  int _count = 0;

  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 32);
    assert(count == 32 || value < (1 << count));
    for (var i = 0; i < count; i++) {
      if (((value >> i) & 1) != 0) {
        _current |= 1 << _count;
      }
      _count++;
      if (_count == 8) {
        _bytes.add(_current);
        _current = 0;
        _count = 0;
      }
    }
  }

  void alignToByte() {
    if (_count > 0) {
      _bytes.add(_current);
      _current = 0;
      _count = 0;
    }
  }

  Uint8List toBytes() {
    alignToByte();
    return Uint8List.fromList(_bytes);
  }
}

void _writeWindowBits(_BitSink sink, int bits) {
  if (bits == 16) {
    sink.writeBits(0, 1);
    return;
  }
  if (bits == 17) {
    sink.writeBits(1, 1);
    sink.writeBits(0, 3);
    sink.writeBits(0, 3);
    return;
  }
  if (bits >= 18 && bits <= 24) {
    sink.writeBits(1, 1);
    sink.writeBits(bits - 17, 3);
    return;
  }
  if (bits >= 10 && bits <= 15) {
    sink.writeBits(1, 1);
    sink.writeBits(0, 3);
    sink.writeBits(bits - 8, 3);
    return;
  }
  throw ArgumentError.value(bits, 'bits');
}

int _log2Floor(int x) {
  var result = 0;
  while ((x >> (result + 1)) != 0) {
    result++;
  }
  return result;
}

/// Finds an explicit-distance command whose insert/copy codes can encode
/// [insertLength] / [copyLength] exactly.
({int code, int insertBits, int insertOffset, int copyBits, int copyOffset})
_findCommand(int insertLength, int copyLength) {
  for (var code = 128; code < numCommandCodes; code++) {
    final packed = commandLookup[code * 4];
    final insertBits = packed & 0xFF;
    final copyBits = packed >> 8;
    final insertOffset = commandLookup[code * 4 + 1];
    final copyOffset = commandLookup[code * 4 + 2];
    if (commandLookup[code * 4 + 3] < 0) {
      continue; // implicit distance: cannot be a dictionary reference
    }
    if (insertLength >= insertOffset &&
        insertLength - insertOffset < (1 << insertBits) &&
        copyLength >= copyOffset &&
        copyLength - copyOffset < (1 << copyBits)) {
      return (
        code: code,
        insertBits: insertBits,
        insertOffset: insertOffset,
        copyBits: copyBits,
        copyOffset: copyOffset,
      );
    }
  }
  throw StateError(
    'no explicit-distance command for insert=$insertLength copy=$copyLength',
  );
}

/// Builds a one-metablock stream that emits [insertLength] copies of `'A'` and
/// then a single static-dictionary reference selected by [wordIndex] /
/// [transformIndex].
///
/// The dictionary address is `transformIndex * (1 << sizeBits) + wordIndex`;
/// the transmitted distance is `address + maxDistance + 1`, so the decoder must
/// reconstruct exactly this address from its own `maxDistance`.
Uint8List _buildDictionaryStream({
  required int insertLength,
  required int copyLength,
  required int wordIndex,
  required int transformIndex,
  int windowBits = 10,
  int literalByte = 0x41,
}) {
  final shift = kDictionarySizeBitsByLength[copyLength];
  final address = transformIndex * (1 << shift) + wordIndex;
  final maxBackward = (1 << windowBits) - 16;
  final maxDistance = insertLength < maxBackward ? insertLength : maxBackward;
  final distance = address + maxDistance + 1;

  final command = _findCommand(insertLength, copyLength);
  final distanceLimit = distanceAlphabetSize(0, 0, maxDistanceBits);
  final lut = buildDistanceLut(0, 0, distanceLimit);
  var distanceCode = -1;
  var distanceExtraBits = 0;
  var distanceOffset = 0;
  for (var code = numDistanceShortCodes; code < distanceLimit; code++) {
    final extraBits = lut.extraBits[code];
    final offset = lut.offset[code];
    if (distance >= offset && distance - offset < (1 << extraBits)) {
      distanceCode = code;
      distanceExtraBits = extraBits;
      distanceOffset = offset;
      break;
    }
  }
  if (distanceCode < 0) {
    throw StateError('no distance code for distance $distance');
  }

  // Invalid word lengths / transform indices are used by the negative tests:
  // keep the framing valid (a positive metablock length) without calling into
  // the transform tables out of range.
  final validWord = copyLength >= 4 && copyLength <= 24 && transformIndex < 121;
  final transformedLength = validWord
      ? transformDictionaryWord(
          Uint8List(maxTransformedWordLength),
          0,
          kDictionaryData,
          dictionaryWordOffset(copyLength, wordIndex),
          copyLength,
          transformIndex,
        )
      : copyLength;
  final metaBlockLength = insertLength + transformedLength;

  final sink = _BitSink();
  _writeWindowBits(sink, windowBits);

  // Metablock header (compressed, not last).
  sink.writeBits(0, 1); // ISLAST
  var value = metaBlockLength - 1;
  var nibbles = 4;
  if (value >= 1 << 20) {
    nibbles = 6;
  } else if (value >= 1 << 16) {
    nibbles = 5;
  }
  sink.writeBits(nibbles - 4, 2);
  for (var i = 0; i < nibbles; i++) {
    sink.writeBits(value & 0xF, 4);
    value >>= 4;
  }
  sink.writeBits(0, 1); // ISUNCOMPRESSED

  // One block type per category (decodeVarLenUnsignedByte == 0).
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);
  sink.writeBits(0, 2); // NPOSTFIX
  sink.writeBits(0, 4); // NDIRECT
  sink.writeBits(0, 2); // context mode LSB6

  // Single-tree context maps: decodeVarLenUnsignedByte == 0.
  sink.writeBits(0, 1);
  sink.writeBits(0, 1);

  // Literal tree: one-symbol simple code.
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(literalByte, 8);

  // Command tree: one-symbol simple code.
  final commandMaxBits = 1 + _log2Floor(numCommandCodes - 1);
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(command.code, commandMaxBits);

  // Distance tree: one-symbol simple code.
  final distanceMaxBits = 1 + _log2Floor(distanceLimit - 1);
  sink.writeBits(1, 2);
  sink.writeBits(0, 2);
  sink.writeBits(distanceCode, distanceMaxBits);

  // Command extras, then (after the implicit inserted literals) the distance
  // extra bits.
  sink.writeBits(insertLength - command.insertOffset, command.insertBits);
  sink.writeBits(copyLength - command.copyOffset, command.copyBits);
  sink.writeBits(distance - distanceOffset, distanceExtraBits);

  // Final empty metablock.
  sink.writeBits(1, 1);
  sink.writeBits(1, 1);
  return sink.toBytes();
}
