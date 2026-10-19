@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/decoder/bit_reader.dart';
import 'package:brotli_neo/src/decoder/decoder_core.dart';
import 'package:brotli_neo/src/decoder/decoder_state.dart';
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// LSB-first bit packer; the mirror image of [BitReader].
final class _BitSink {
  final List<int> _bytes = <int>[];
  int _current = 0;
  int _count = 0;

  int get bitLength => _bytes.length * 8 + _count;

  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 32);
    assert(value >= 0);
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

  void writeRawByte(int value) {
    assert(_count == 0, 'raw bytes must be byte aligned');
    _bytes.add(value & 0xFF);
  }

  Uint8List toBytes() {
    alignToByte();
    return Uint8List.fromList(_bytes);
  }
}

/// Result of a full decode plus the final state fields asserted by the tests.
final class _Run {
  _Run({
    required this.bytes,
    required this.windowBits,
    required this.largeWindow,
    required this.ringBufferSize,
    required this.ringBufferCapacity,
    required this.expectedTotalSize,
  });

  final Uint8List bytes;
  final int windowBits;
  final bool largeWindow;
  final int ringBufferSize;
  final int ringBufferCapacity;
  final int expectedTotalSize;
}

/// Decodes [input] completely through small output buffers.
_Run _run(
  Uint8List input, {
  bool allowLargeWindow = false,
  int? maxOutputSize,
  int chunkSize = 64 * 1024,
}) {
  final core = BrotliDecoderCore(
    BitReader.fromBytes(input),
    allowLargeWindow: allowLargeWindow,
    maxOutputSize: maxOutputSize,
  );
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(chunkSize);
  var stalled = 0;
  while (true) {
    final status = core.decode(buffer);
    final written = core.bytesWritten;
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    expect(
      status,
      isNot(BrotliStatus.needMoreInput),
      reason: 'a closed in-memory stream must not request input',
    );
    if (written == 0) {
      stalled++;
      expect(
        stalled,
        lessThan(1000),
        reason: 'decoder stopped making progress',
      );
    }
  }
  return _Run(
    bytes: builder.takeBytes(),
    windowBits: core.state.windowBits,
    largeWindow: core.state.largeWindow,
    ringBufferSize: core.state.ringBufferSize,
    ringBufferCapacity: core.state.ringBuffer.length,
    expectedTotalSize: core.state.expectedTotalSize,
  );
}

Uint8List _u8(List<int> values) => Uint8List.fromList(values);

/// Writes the RFC 7932 stream header for [bits] (10..24), or the large-window
/// encoding when [large] is set.
void _writeWindowBits(_BitSink sink, int bits, {bool large = false}) {
  if (large) {
    sink.writeBits(1, 1); // not the 16-bit shorthand
    sink.writeBits(0, 3); // n == 0
    sink.writeBits(1, 3); // large-window marker
    sink.writeBits(0, 1); // reserved extension bit
    sink.writeBits(bits, 6);
    return;
  }
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
  throw ArgumentError.value(bits, 'bits', 'not an RFC window-bits value');
}

/// Writes an ISLAST + ISLASTEMPTY metablock (the canonical stream terminator).
void _writeLastEmptyMetaBlock(_BitSink sink) {
  sink.writeBits(1, 1); // ISLAST
  sink.writeBits(1, 1); // ISLASTEMPTY
  sink.alignToByte();
}

/// Writes a metadata metablock header for [length] payload bytes.
///
/// A zero-length metadata block is encoded with `sizeBytes == 0`; otherwise the
/// length is transmitted as `length - 1` in the minimal number of bytes.
void _writeMetadataMetaBlock(_BitSink sink, int length) {
  sink.writeBits(0, 1); // ISLAST == 0
  if (length == 0) {
    sink.writeBits(3, 2); // MNIBBLES == 7 (metadata)
    sink.writeBits(0, 1); // reserved
    sink.writeBits(0, 2); // sizeBytes == 0
    sink.alignToByte();
    return;
  }
  var value = length - 1;
  var sizeBytes = 1;
  if (value >= 1 << 16) {
    sizeBytes = 3;
  } else if (value >= 1 << 8) {
    sizeBytes = 2;
  }
  sink.writeBits(3, 2);
  sink.writeBits(0, 1);
  sink.writeBits(sizeBytes, 2);
  for (var i = 0; i < sizeBytes; i++) {
    sink.writeBits(value & 0xFF, 8);
    value >>= 8;
  }
  sink.alignToByte();
}

/// Writes an uncompressed metablock header for [length] payload bytes.
void _writeUncompressedHeader(_BitSink sink, int length) {
  assert(length > 0 && length <= maxMetaBlockLength);
  var value = length - 1;
  var nibbles = 4;
  if (value >= 1 << 20) {
    nibbles = 6;
  } else if (value >= 1 << 16) {
    nibbles = 5;
  }
  sink.writeBits(0, 1); // ISLAST == 0
  sink.writeBits(nibbles - 4, 2);
  for (var i = 0; i < nibbles; i++) {
    sink.writeBits(value & 0xF, 4);
    value >>= 4;
  }
  sink.writeBits(1, 1); // ISUNCOMPRESSED
  sink.alignToByte();
}

/// Writes a complete uncompressed metablock (header + payload).
void _writeUncompressedMetaBlock(_BitSink sink, Uint8List payload) {
  _writeUncompressedHeader(sink, payload.length);
  for (final byte in payload) {
    sink.writeRawByte(byte);
  }
}

/// Builds `window bits + uncompressed block + ISLASTEMPTY`.
Uint8List _buildRawStream(
  int windowBits,
  Uint8List payload, {
  bool largeWindow = false,
}) {
  final sink = _BitSink();
  _writeWindowBits(sink, windowBits, large: largeWindow);
  _writeUncompressedMetaBlock(sink, payload);
  _writeLastEmptyMetaBlock(sink);
  return sink.toBytes();
}

Uint8List _pattern(int length, {int seed = 7}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed) & 0xFF;
  }
  return bytes;
}

void main() {
  final corpus = Corpus.load();

  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  MalformedVector variant(String name) =>
      corpus.malformed.firstWhere((m) => m.name == name);

  group('corpus frame-only vectors', () {
    test('empty.compressed decodes to empty', () {
      final run = _run(corpus.compressedBytes(entry('empty')));
      expect(run.bytes, isEmpty);
      expect(run.windowBits, 16);
      expect(run.largeWindow, isFalse);
      expect(run.ringBufferSize, 0);
    });

    test('x.compressed decodes to its single byte', () {
      final run = _run(corpus.compressedBytes(entry('x')));
      expect(run.bytes, orderedEquals(corpus.rawBytes(entry('x'))));
      expect(run.bytes, orderedEquals(_u8(<int>[0x58])));
      expect(run.windowBits, 22);
    });

    test('all-uncompressed corpus pairs decode byte-exact', () {
      // These vectors contain only metadata / uncompressed metablocks, so the
      // frame layer alone must reproduce them exactly. The remaining corpus
      // files are compressed metablocks and belong to D3.
      const names = <String>[
        'empty',
        'x',
        'xyzzy',
        'quickfox',
        'random_org_10k.bin',
        'compressed_file',
      ];
      for (final name in names) {
        final e = entry(name);
        final run = _run(corpus.compressedBytes(e));
        expect(run.bytes.length, e.rawBytes, reason: name);
        expect(run.bytes, orderedEquals(corpus.rawBytes(e)), reason: name);
      }
    });

    test('decompressAll convenience wrapper matches the streaming loop', () {
      final raw = corpus.rawBytes(entry('random_org_10k.bin'));
      final out = BrotliDecoderCore.decompressAll(
        corpus.compressedBytes(entry('random_org_10k.bin')),
      );
      expect(out, orderedEquals(raw));
      expect(
        BrotliDecoderCore.decompressAll(corpus.compressedBytes(entry('empty'))),
        isEmpty,
      );
      expect(
        BrotliDecoderCore.decompressAll(
          corpus.malformedBytes(variant('empty.compressed.18')),
          outputChunkSize: 3,
        ),
        isEmpty,
      );
      expect(
        () => BrotliDecoderCore.decompressAll(
          corpus.compressedBytes(entry('random_org_10k.bin')),
          maxOutputSize: 100,
        ),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
    });

    test('compressed corpus vectors decode or stop at the D4 boundary', () {
      // D3 decodes compressed metablocks. Vectors that reference the RFC static
      // dictionary still raise a tagged unsupportedFeature until D4; every
      // other vector must be byte-exact.
      const frameOnly = <String>{
        'empty',
        'x',
        'xyzzy',
        'quickfox',
        'random_org_10k.bin',
        'compressed_file',
      };
      var decoded = 0;
      var dictionaryBoundary = 0;
      for (final e in corpus.entries) {
        if (frameOnly.contains(e.name)) {
          continue;
        }
        final raw = corpus.rawBytes(e);
        try {
          final run = _run(corpus.compressedBytes(e));
          expect(run.bytes, orderedEquals(raw), reason: e.name);
          decoded++;
        } on BrotliException catch (error) {
          expect(
            error.code,
            BrotliErrorCode.unsupportedFeature,
            reason: e.name,
          );
          expect(error.message, contains('D4'), reason: e.name);
          dictionaryBoundary++;
        }
      }
      expect(
        decoded + dictionaryBoundary,
        corpus.entries.length - frameOnly.length,
      );
      expect(decoded, greaterThan(0));
    });
  });

  group('variant corpus (coverage streams, not errors)', () {
    test('empty.compressed.00-.14 cover window bits 10..24', () {
      // These files are a window-bits coverage corpus: .00 is byte-identical
      // to empty.compressed (16 bits), .01-.14 encode the remaining sizes.
      const expectedWindowBits = <int>[
        16, 17, 10, 11, 12, 13, 14, 15, 18, 19, 20, 21, 22, 23, 24, //
      ];
      for (var i = 0; i < expectedWindowBits.length; i++) {
        final name = 'empty.compressed.${i.toString().padLeft(2, '0')}';
        final run = _run(corpus.malformedBytes(variant(name)));
        expect(run.bytes, isEmpty, reason: name);
        expect(run.windowBits, expectedWindowBits[i], reason: name);
        expect(run.largeWindow, isFalse, reason: name);
        expect(run.ringBufferSize, 0, reason: name);
      }
    });

    test('empty.compressed.15-.18 are empty metadata/plain streams', () {
      const expectedWindowBits = <String, int>{
        'empty.compressed.15': 16,
        'empty.compressed.16': 17,
        'empty.compressed.17': 17,
        'empty.compressed.18': 17,
      };
      for (final testCase in expectedWindowBits.entries) {
        final run = _run(corpus.malformedBytes(variant(testCase.key)));
        expect(run.bytes, isEmpty, reason: testCase.key);
        expect(run.windowBits, testCase.value, reason: testCase.key);
        expect(run.ringBufferSize, 0, reason: testCase.key);
      }
    });

    test('x.compressed.00-.02 decode to X', () {
      for (final name in <String>[
        'x.compressed.00',
        'x.compressed.01',
        'x.compressed.02',
      ]) {
        final run = _run(corpus.malformedBytes(variant(name)));
        expect(run.bytes, orderedEquals(_u8(<int>[0x58])), reason: name);
      }
    });

    test('x.compressed.03 decodes to X (compressed metablock, D3)', () {
      final run = _run(corpus.malformedBytes(variant('x.compressed.03')));
      expect(run.bytes, orderedEquals(_u8(<int>[0x58])));
    });

    test(
      'every variant decodes or fails with BrotliException (no crash/hang)',
      () {
        for (final vector in corpus.malformed) {
          try {
            final run = _run(corpus.malformedBytes(vector));
            // All variants are empty or single-byte streams.
            expect(run.bytes.length, anyOf(0, 1), reason: vector.name);
          } on BrotliException catch (error) {
            // No variant of this corpus needs the static dictionary.
            fail('${vector.name} raised ${error.code.name}: ${error.message}');
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('synthetic frame streams', () {
    test('window bits 10/16/17/22/24 round-trip uncompressed data', () {
      final payload = _pattern(300);
      for (final windowBits in <int>[10, 16, 17, 22, 24]) {
        final run = _run(_buildRawStream(windowBits, payload));
        expect(run.windowBits, windowBits, reason: 'wbits=$windowBits');
        expect(run.bytes, orderedEquals(payload), reason: 'wbits=$windowBits');
        expect(
          run.ringBufferSize,
          lessThanOrEqualTo(1 << windowBits),
          reason: 'wbits=$windowBits',
        );
      }
    });

    test('large-window encoding is accepted only when enabled', () {
      final payload = _u8(<int>[0xDE, 0xAD, 0xBE, 0xEF]);
      final stream = _buildRawStream(10, payload, largeWindow: true);
      final run = _run(stream, allowLargeWindow: true);
      expect(run.windowBits, 10);
      expect(run.largeWindow, isTrue);
      expect(run.bytes, orderedEquals(payload));
      expect(
        () => _run(stream),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidWindowBits,
          ),
        ),
      );
    });

    test('metadata payloads are skipped and interleave with raw blocks', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      _writeMetadataMetaBlock(sink, 9);
      for (var i = 0; i < 9; i++) {
        sink.writeRawByte(0xA0 + i);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[1, 2, 3]));
      _writeMetadataMetaBlock(sink, 0);
      _writeMetadataMetaBlock(sink, 300);
      for (var i = 0; i < 300; i++) {
        sink.writeRawByte(i & 0xFF);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[4, 5]));
      _writeLastEmptyMetaBlock(sink);

      final run = _run(sink.toBytes());
      expect(run.bytes, orderedEquals(_u8(<int>[1, 2, 3, 4, 5])));
      // Metadata never contributes to the expected output size.
      expect(run.expectedTotalSize, 5);
    });

    test('metadata larger than the input window is skipped', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 22);
      _writeMetadataMetaBlock(sink, 70000);
      for (var i = 0; i < 70000; i++) {
        sink.writeRawByte((i * 13 + 1) & 0xFF);
      }
      _writeUncompressedMetaBlock(sink, _u8(<int>[0x42]));
      _writeLastEmptyMetaBlock(sink);

      final run = _run(sink.toBytes(), chunkSize: 4096);
      expect(run.bytes, orderedEquals(_u8(<int>[0x42])));
      expect(run.expectedTotalSize, 1);
    });

    test('ring buffer wraps for > 64 KiB of uncompressed output', () {
      final payload = _pattern(200000);
      final stream = _buildRawStream(16, payload);
      final run = _run(stream, chunkSize: 1000);
      expect(run.ringBufferSize, 65536);
      expect(run.bytes.length, payload.length);
      expect(run.bytes, orderedEquals(payload));
    });

    test('uncompressed block ending exactly at the ring end flushes', () {
      // 2 * 65536: the last copy fills the window exactly, so the flush and the
      // metablock end coincide (a documented tricky path in the reference).
      final payload = _pattern(131072);
      final run = _run(_buildRawStream(16, payload), chunkSize: 7000);
      expect(run.ringBufferSize, 65536);
      expect(run.bytes, orderedEquals(payload));
    });

    test('ring buffer grows only as much as expectedTotalSize needs', () {
      final run = _run(_buildRawStream(24, _pattern(5)));
      expect(run.bytes, orderedEquals(_pattern(5)));
      expect(run.ringBufferSize, lessThan(1 << 24));
      expect(run.ringBufferSize, greaterThanOrEqualTo(5));
      expect(
        run.ringBufferCapacity - run.ringBufferSize,
        maxTransformedWordLength,
      );
    });

    test('tiny output buffers flush without losing bytes', () {
      final payload = _u8(<int>[10, 20, 30, 40, 50]);
      for (final chunkSize in <int>[1, 2, 3, 7]) {
        final run = _run(_buildRawStream(16, payload), chunkSize: chunkSize);
        expect(run.bytes, orderedEquals(payload), reason: 'chunk=$chunkSize');
      }
    });

    test('decode honours the output start offset', () {
      final core = BrotliDecoderCore(
        BitReader.fromBytes(_buildRawStream(16, _u8(<int>[1, 2, 3]))),
      );
      final buffer = Uint8List(10)..fillRange(0, 10, 0xEE);
      final status = core.decode(buffer, 3, 7);
      expect(status, BrotliStatus.done);
      expect(core.bytesWritten, 3);
      expect(buffer.sublist(3, 6), orderedEquals(_u8(<int>[1, 2, 3])));
      expect(buffer[0], 0xEE);
      expect(buffer[2], 0xEE);
      expect(buffer[6], 0xEE);
      expect(buffer[9], 0xEE);
    });

    test('done is idempotent', () {
      final core = BrotliDecoderCore(
        BitReader.fromBytes(_buildRawStream(16, _u8(<int>[1, 2, 3]))),
      );
      final buffer = Uint8List(16);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 3);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 0);
      expect(core.decode(buffer), BrotliStatus.done);
      expect(core.bytesWritten, 0);
    });

    test('maxOutputSize guards decompression bombs', () {
      final payload = Uint8List(200000);
      final stream = _buildRawStream(16, payload);
      expect(
        () => _run(stream, maxOutputSize: 199999, chunkSize: 1000),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
      final run = _run(stream, maxOutputSize: 200000, chunkSize: 1000);
      expect(run.bytes.length, 200000);
    });
  });

  group('malformed synthetic streams', () {
    test('empty input is reported as truncated', () {
      expect(
        () => _run(Uint8List(0)),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.truncatedInput,
          ),
        ),
      );
    });

    test('reserved window-bits value is rejected', () {
      final sink = _BitSink();
      sink.writeBits(1, 1);
      sink.writeBits(0, 3);
      sink.writeBits(1, 3); // large-window marker: reserved for RFC streams
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidWindowBits,
          ),
        ),
      );
    });

    test('large-window reserved bit is rejected', () {
      final sink = _BitSink();
      sink.writeBits(1, 1);
      sink.writeBits(0, 3);
      sink.writeBits(1, 3);
      sink.writeBits(1, 1); // reserved extension bit must be zero
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes(), allowLargeWindow: true),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidWindowBits,
          ),
        ),
      );
    });

    test('large-window bits outside 10..30 are rejected', () {
      final sink = _BitSink();
      sink.writeBits(1, 1);
      sink.writeBits(0, 3);
      sink.writeBits(1, 3);
      sink.writeBits(0, 1);
      sink.writeBits(9, 6); // below MIN_LARGE_WINDOW_BITS
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes(), allowLargeWindow: true),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidWindowBits,
          ),
        ),
      );
    });

    test('metadata reserved bit is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(3, 2); // MNIBBLES == 7
      sink.writeBits(1, 1); // reserved bit set
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidMetaBlockLength,
          ),
        ),
      );
    });

    test('metadata exuberant last length byte is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      sink.writeBits(0, 1);
      sink.writeBits(3, 2);
      sink.writeBits(0, 1);
      sink.writeBits(2, 2); // sizeBytes == 2
      sink.writeBits(0, 8); // both bytes zero: last byte is exuberant
      sink.writeBits(0, 8);
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidMetaBlockLength,
          ),
        ),
      );
    });

    test('metablock exuberant last length nibble is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(1, 2); // MNIBBLES == 5
      sink.writeBits(0, 4); // nibble 0
      sink.writeBits(0, 4); // nibble 1
      sink.writeBits(0, 4); // nibble 2
      sink.writeBits(0, 4); // nibble 3
      sink.writeBits(0, 4); // last nibble zero => exuberant
      sink.writeBits(1, 1); // ISUNCOMPRESSED
      sink.alignToByte();
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.invalidMetaBlockLength,
          ),
        ),
      );
    });

    test('non-zero padding before an uncompressed payload is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      sink.writeBits(0, 1); // ISLAST
      sink.writeBits(0, 2); // MNIBBLES == 4
      sink.writeBits(0, 16); // length - 1 == 0
      sink.writeBits(1, 1); // ISUNCOMPRESSED
      // 21 bits written so far: three padding bits follow.
      sink.writeBits(1, 1); // padding bit must be zero
      sink.writeBits(0, 2);
      sink.writeRawByte(0xAA);
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.corruptPadding,
          ),
        ),
      );
    });

    test('truncated metadata payload is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      _writeMetadataMetaBlock(sink, 10);
      sink.writeRawByte(1);
      sink.writeRawByte(2);
      sink.writeRawByte(3);
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.truncatedInput,
          ),
        ),
      );
    });

    test('truncated uncompressed payload is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      _writeUncompressedHeader(sink, 10);
      sink.writeRawByte(1);
      sink.writeRawByte(2);
      sink.writeRawByte(3);
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.truncatedInput,
          ),
        ),
      );
    });

    test('trailing garbage after a complete stream is rejected', () {
      final sink = _BitSink();
      _writeWindowBits(sink, 16);
      _writeLastEmptyMetaBlock(sink);
      sink.writeRawByte(0x00);
      expect(
        () => _run(sink.toBytes()),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.unusedBytesAfterEnd,
          ),
        ),
      );
    });
  });
}
