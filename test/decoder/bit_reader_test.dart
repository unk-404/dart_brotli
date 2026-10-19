import 'dart:typed_data';

import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/decoder/bit_reader.dart';
import 'package:test/test.dart';

/// A [BitReaderInput] that hands out bytes one small piece at a time and can be
/// refilled with new chunks while the reader is mid-stream.
final class _ChunkedInput implements BitReaderInput {
  _ChunkedInput({this.bytesPerCall = 1});

  final int bytesPerCall;
  final List<Uint8List> _chunks = <Uint8List>[];
  int _index = 0;
  int _chunkOffset = 0;
  bool _closed = false;

  void add(Uint8List bytes) => _chunks.add(bytes);

  void close() => _closed = true;

  @override
  bool get isClosed => _closed;

  @override
  int readInto(Uint8List destination, int offset, int length) {
    if (length <= 0) {
      return 0;
    }
    while (_index < _chunks.length) {
      final chunk = _chunks[_index];
      final available = chunk.length - _chunkOffset;
      if (available <= 0) {
        _index++;
        _chunkOffset = 0;
        continue;
      }
      final limit = length < bytesPerCall ? length : bytesPerCall;
      final count = available < limit ? available : limit;
      destination.setRange(offset, offset + count, chunk, _chunkOffset);
      _chunkOffset += count;
      return count;
    }
    return 0;
  }
}

/// LSB-first bit packer, the mirror image of [BitReader].
final class _BitSink {
  final List<int> _bytes = <int>[];
  int _current = 0;
  int _count = 0;

  int get bitLength => _bytes.length * 8 + _count;

  void writeBits(int value, int count) {
    assert(count >= 0 && count <= 32);
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

  Uint8List toBytes() {
    final bytes = Uint8List(_bytes.length + (_count > 0 ? 1 : 0));
    for (var i = 0; i < _bytes.length; i++) {
      bytes[i] = _bytes[i];
    }
    if (_count > 0) {
      bytes[bytes.length - 1] = _current;
    }
    return bytes;
  }
}

int _mask(int width) => width == 32 ? 0xFFFFFFFF : (1 << width) - 1;

Matcher _throwsBrotli(BrotliErrorCode code) =>
    throwsA(isA<BrotliException>().having((error) => error.code, 'code', code));

int _readByte(BitReader reader) {
  expect(reader.refill(), isTrue);
  reader.fillBitWindow();
  return reader.readFewBits(8);
}

void main() {
  test('fromBytes exposes stream geometry', () {
    final bytes = Uint8List.fromList(List<int>.generate(10, (i) => i * 7));
    final reader = BitReader.fromBytes(bytes);
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, 10);
    expect(reader.filled, 10);
    expect(reader.pos, 0);
    expect(reader.accumulator, 0);
    expect(reader.bitOffset, 32);
    expect(reader.bytesConsumed, 0);
    expect(reader.activeMementoCount, 0);
    expect(reader.refill(), isTrue);
    expect(reader.endOfStreamReached, isTrue);
    reader.checkHealth();
  });

  test('readBits decodes every width 1..32', () {
    final widths = List<int>.generate(32, (i) => i + 1);
    final sink = _BitSink();
    for (final width in widths) {
      final max = _mask(width);
      sink.writeBits(0, width);
      sink.writeBits(max, width);
      sink.writeBits(0xAAAAAAAA & max, width);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final width in widths) {
      final max = _mask(width);
      for (final expected in <int>[0, max, 0xAAAAAAAA & max]) {
        expect(reader.refill(), isTrue);
        reader.fillBitWindow();
        expect(reader.readBits(width), expected, reason: 'width $width');
        expect(reader.accumulator, inInclusiveRange(0, 0xFFFFFFFF));
        expect(reader.bitOffset, inInclusiveRange(0, 32));
      }
    }
    expect(reader.bytesConsumed, sink.bitLength >> 3);
    reader.checkHealth(true);
  });

  test('peekBits does not consume and readFewBits handles widths 1..16', () {
    final widths = List<int>.generate(16, (i) => i + 1);
    final sink = _BitSink();
    for (final width in widths) {
      final max = _mask(width);
      sink.writeBits(max, width);
      sink.writeBits(0x55555555 & max, width);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final width in widths) {
      final max = _mask(width);
      for (final expected in <int>[max, 0x55555555 & max]) {
        expect(reader.refill(), isTrue);
        reader.fillBitWindow();
        final bitOffset = reader.bitOffset;
        final consumed = reader.bytesConsumed;
        expect(reader.peekBits(width), expected, reason: 'peek width $width');
        expect(reader.bitOffset, bitOffset);
        expect(reader.bytesConsumed, consumed);
        expect(
          reader.readFewBits(width),
          expected,
          reason: 'read width $width',
        );
      }
    }
    reader.checkHealth(true);
  });

  test('readBitsUpTo32 matches readBits for wide widths', () {
    final sink = _BitSink();
    const values = <int>[
      0x00000001,
      0x00018000,
      0x00ABCDEF,
      0x80000001,
      0xFFFFFFFF,
      0x00000000,
    ];
    for (final value in values) {
      sink.writeBits(value, 32);
    }
    final reader = BitReader.fromBytes(sink.toBytes());
    for (final value in values) {
      expect(reader.refill(), isTrue);
      reader.fillBitWindow();
      expect(reader.readBitsUpTo32(32), value);
    }
    reader.checkHealth(true);
  });

  test('readBits splits wide reads at the accumulator boundary', () {
    // 0b0111_1111_1010_1010_0101_0101 ... read as 5 + 9 + 4 + 14 bits.
    final sink = _BitSink();
    sink.writeBits(0x1F, 5);
    sink.writeBits(0x1AB, 9);
    sink.writeBits(0xF, 4);
    sink.writeBits(0x2A5A, 14);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readBits(5), 0x1F);
    expect(reader.readBits(9), 0x1AB);
    expect(reader.readBits(4), 0xF);
    expect(reader.readBits(14), 0x2A5A);
  });

  test('jumpToByteBoundary aligns to the next byte', () {
    final sink = _BitSink();
    sink.writeBits(0x5, 3); // 101, upper 5 bits stay zero
    sink.writeBits(0x0, 5);
    sink.writeBits(0x5A, 8);
    sink.writeBits(0x1234, 16);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    reader.jumpToByteBoundary();
    expect(reader.bytesConsumed, 1);
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(8), 0x5A);
    reader.fillBitWindow();
    expect(reader.readFewBits(16), 0x1234);
    reader.checkHealth(true);
  });

  test('jumpToByteBoundary rejects non-zero padding', () {
    final sink = _BitSink();
    sink.writeBits(0x5, 3);
    sink.writeBits(0x10, 5); // one padding bit set
    sink.writeBits(0x5A, 8);
    final reader = BitReader.fromBytes(sink.toBytes());
    expect(reader.refill(), isTrue);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    expect(
      reader.jumpToByteBoundary,
      _throwsBrotli(BrotliErrorCode.corruptPadding),
    );
  });

  test('refill works with one-byte chunks and late input', () {
    final data = Uint8List.fromList(
      List<int>.generate(500, (i) => (i * 31 + 7) & 0xFF),
    );
    final input = _ChunkedInput(bytesPerCall: 1);
    var fed = 0;
    void feed(int count) {
      final end = fed + count > data.length ? data.length : fed + count;
      input.add(data.sublist(fed, end));
      fed = end;
    }

    feed(10);
    final reader = BitReader(input);
    var index = 0;
    var starved = 0;
    while (index < data.length) {
      if (!reader.refill()) {
        starved++;
        if (fed < data.length) {
          feed(7);
        } else {
          input.close();
        }
        continue;
      }
      reader.fillBitWindow();
      expect(reader.readFewBits(8), data[index], reason: 'byte $index');
      index++;
    }
    expect(starved, greaterThan(3));
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, data.length);
    expect(reader.bytesConsumed, data.length);
    expect(reader.filled, 0);
    reader.checkHealth(true);
  });

  test('tailBytes becomes available only once the stream ends', () {
    final data = Uint8List(5000);
    final reader = BitReader.fromBytes(data);
    expect(reader.endOfStreamReached, isFalse);
    expect(reader.tailBytes, -1);
    expect(reader.filled, BitReader.capacity);
    for (var i = 0; i < data.length; i++) {
      expect(_readByte(reader), 0);
    }
    expect(reader.endOfStreamReached, isTrue);
    expect(reader.tailBytes, data.length);
    expect(reader.bytesConsumed, data.length);
    reader.checkHealth(true);
  });

  test('copyRawBytes and skipRawBytes respect byte alignment', () {
    final bytes = Uint8List.fromList(<int>[0x05, 0x11, 0x22, 0x33, 0x44]);
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0x5);
    reader.jumpToByteBoundary();
    final destination = Uint8List(4);
    expect(reader.copyRawBytes(destination, 0, 2), 2);
    expect(destination.sublist(0, 2), <int>[0x11, 0x22]);
    expect(reader.skipRawBytes(2), 2);
    expect(reader.filled, 0);
    expect(reader.copyRawBytes(destination, 0, 1), 0);
    expect(reader.bytesConsumed, 5);
    reader.checkHealth(true);
  });

  test('copyRawBytes makes staged progress at end of stream', () {
    final bytes = Uint8List.fromList(<int>[0x00, 0x11]);
    final reader = BitReader.fromBytes(bytes);
    reader.fillBitWindow();
    expect(reader.readFewBits(8), 0x00);
    final destination = Uint8List(4);
    expect(reader.copyRawBytes(destination, 0, 4), 1);
    expect(destination[0], 0x11);
    expect(reader.copyRawBytes(destination, 0, 1), 0);
    expect(reader.bytesConsumed, 2);
    reader.checkHealth(true);
  });

  test('copyRawBytes rejects unaligned readers', () {
    final reader = BitReader.fromBytes(Uint8List(8));
    reader.fillBitWindow();
    expect(reader.readFewBits(3), 0);
    expect(
      () => reader.copyRawBytes(Uint8List(4), 0, 1),
      _throwsBrotli(BrotliErrorCode.internalError),
    );
    expect(
      () => reader.skipRawBytes(1),
      _throwsBrotli(BrotliErrorCode.internalError),
    );
  });

  test('checkHealth rejects reads after the end and unused bytes', () {
    final oneByte = BitReader.fromBytes(Uint8List.fromList(<int>[0xAB]));
    oneByte.fillBitWindow();
    expect(oneByte.readFewBits(8), 0xAB);
    oneByte.fillBitWindow();
    oneByte.readFewBits(8);
    expect(
      () => oneByte.checkHealth(),
      _throwsBrotli(BrotliErrorCode.readAfterEnd),
    );
    expect(
      () => oneByte.refill(),
      _throwsBrotli(BrotliErrorCode.truncatedInput),
    );

    final unused = BitReader.fromBytes(
      Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
    );
    unused.fillBitWindow();
    expect(unused.readFewBits(8), 0x01);
    expect(
      () => unused.checkHealth(true),
      _throwsBrotli(BrotliErrorCode.unusedBytesAfterEnd),
    );

    final exact = BitReader.fromBytes(
      Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
    );
    exact.fillBitWindow();
    expect(exact.readBits(24), 0x030201);
    exact.checkHealth();
    exact.checkHealth(true);
  });

  test('zero-width reads do not advance the cursor', () {
    final reader = BitReader.fromBytes(Uint8List.fromList(<int>[0xAB, 0xCD]));
    reader.fillBitWindow();
    final consumed = reader.bytesConsumed;
    expect(reader.peekBits(0), 0);
    expect(reader.readFewBits(0), 0);
    expect(reader.readBits(0), 0);
    expect(reader.readBitsUpTo32(0), 0);
    expect(reader.bytesConsumed, consumed);
    expect(reader.readFewBits(8), 0xAB);
  });

  test('fromBytes honours offset and end', () {
    final bytes = Uint8List.fromList(<int>[0x11, 0x22, 0x33, 0x44]);
    final reader = BitReader.fromBytes(bytes, offset: 1, end: 3);
    expect(reader.tailBytes, 2);
    reader.fillBitWindow();
    expect(reader.readBits(16), 0x3322);
    reader.checkHealth(true);
  });

  test('reload warms the accumulator after it is drained', () {
    final reader = BitReader.fromBytes(
      Uint8List.fromList(<int>[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
    );
    reader.fillBitWindow();
    expect(reader.readBits(16), 0x0201);
    expect(reader.readBits(16), 0x0403);
    expect(reader.bitOffset, 32);
    expect(reader.reload(), isTrue);
    expect(reader.readBits(16), 0x0605);
    expect(reader.readBits(16), 0x0807);
    reader.checkHealth(true);
  });

  test('memento/restore survives compaction of the input window', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(12000, (i) => (i * 37 + 11) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    final reference = BitReader.fromBytes(bytes);
    for (var i = 0; i < 3000; i++) {
      final expected = _readByte(reference);
      expect(_readByte(reader), expected);
    }
    final savedPos = reader.pos;
    final savedConsumed = reader.bytesConsumed;
    final memento = reader.save();
    expect(memento.absolutePosition, savedPos);
    expect(reader.activeMementoCount, 1);

    for (var i = 0; i < 1200; i++) {
      _readByte(reader);
    }
    // The window was compacted while the memento was alive.
    expect(reader.pos, greaterThan(BitReader.capacity));

    reader.restore(memento);
    expect(reader.activeMementoCount, 0);
    expect(reader.pos, savedPos);
    expect(reader.bytesConsumed, savedConsumed);

    for (var i = 0; i < 1200; i++) {
      expect(_readByte(reader), _readByte(reference), reason: 'replay $i');
    }
  });

  test('memento restore without compaction replays the same bits', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(2000, (i) => (i * 13 + 5) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    final memento = reader.save();
    final replay = <int>[];
    for (var i = 0; i < 10; i++) {
      replay.add(_readByte(reader));
    }
    reader.restore(memento);
    for (final value in replay) {
      expect(_readByte(reader), value);
    }
  });

  test('nested mementos restore independently', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(9000, (i) => (i * 91 + 3) & 0xFF),
    );
    final reader = BitReader.fromBytes(bytes);
    final reference = BitReader.fromBytes(bytes);
    for (var i = 0; i < 6000; i++) {
      final expected = _readByte(reference);
      expect(_readByte(reader), expected);
    }
    final outer = reader.save();
    final outerPos = reader.pos;
    final first = <int>[];
    for (var i = 0; i < 300; i++) {
      first.add(_readByte(reader));
    }
    final inner = reader.save();
    final innerPos = reader.pos;
    final second = <int>[];
    for (var i = 0; i < 500; i++) {
      second.add(_readByte(reader));
    }
    reader.restore(inner);
    expect(reader.pos, innerPos);
    expect(reader.activeMementoCount, 1);
    for (final value in second) {
      expect(_readByte(reader), value);
    }
    reader.restore(outer);
    expect(reader.pos, outerPos);
    expect(reader.activeMementoCount, 0);
    for (final value in first) {
      expect(_readByte(reader), value);
    }
  });

  test('discard releases a memento and keeps the reader usable', () {
    final reader = BitReader.fromBytes(
      Uint8List.fromList(List<int>.generate(500, (i) => i & 0xFF)),
    );
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    final memento = reader.save();
    expect(reader.activeMementoCount, 1);
    for (var i = 0; i < 10; i++) {
      _readByte(reader);
    }
    reader.discard(memento);
    expect(reader.activeMementoCount, 0);
    expect(() => reader.restore(memento), throwsStateError);
    reader.discard(memento); // idempotent
    final next = _readByte(reader);
    expect(next, inInclusiveRange(0, 255));
  });
}
