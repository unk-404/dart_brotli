/// 64-bit LSB-first bit writer for VM/AOT (v2 encoder).
///
/// The pending accumulator is a native 64-bit `int`; the public API is shared
/// with the Web fallback (`bit_writer_js.dart`) and both produce byte-identical
/// output. Bytes are only appended to the buffer when complete, so [mark] and
/// [rewind] are exact.
library;

import 'dart:typed_data';

/// LSB-first bit writer with a 64-bit pending accumulator.
final class BitWriterV2 {
  /// Creates a writer with room for [initialCapacity] bytes.
  BitWriterV2({int initialCapacity = 256})
    : _buffer = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buffer;
  int _length = 0; // complete bytes stored
  int _acc = 0; // pending bits, bit 0 = oldest (always < 2^(bits))
  int _accBits = 0; // pending bit count, always 0..7 after writeBits

  /// Total number of bits written so far.
  int get bitPosition => _length * 8 + _accBits;

  /// Number of bytes [toBytes] returns (the final partial byte included).
  int get lengthInBytes => _length + (_accBits == 0 ? 0 : 1);

  /// Whether the writer is on a byte boundary.
  bool get isByteAligned => _accBits == 0;

  /// Current mark for [rewind].
  int get mark => bitPosition;

  /// Discards everything.
  void reset() {
    _length = 0;
    _acc = 0;
    _accBits = 0;
  }

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity)..setRange(0, _length, _buffer);
    _buffer = grown;
  }

  /// Writes the low [count] bits of [value], least significant bit first.
  ///
  /// [count] must be `0..32`; [value] must fit in [count] bits.
  void writeBits(int count, int value) {
    if (count == 0) return;
    final mask = count >= 32 ? 0xFFFFFFFF : (1 << count) - 1;
    _acc |= (value & mask) << _accBits;
    _accBits += count;
    while (_accBits >= 8) {
      _ensure(1);
      _buffer[_length++] = _acc & 0xFF;
      _acc >>= 8;
      _accBits -= 8;
    }
  }

  /// Pads with zero bits to the next byte boundary.
  void alignToByte() {
    if (_accBits == 0) return;
    _ensure(1);
    _buffer[_length++] = _acc & 0xFF;
    _acc = 0;
    _accBits = 0;
  }

  /// Appends [count] raw bytes from [data] at [offset]; requires byte alignment.
  void writeAlignedBytes(Uint8List data, int offset, int count) {
    assert(_accBits == 0, 'writeAlignedBytes needs a byte boundary');
    if (count <= 0) return;
    _ensure(count);
    _buffer.setRange(_length, _length + count, data, offset);
    _length += count;
  }

  /// Rewinds to [position] (a previous [mark]).
  void rewind(int position) {
    assert(position <= bitPosition, 'rewind past the end');
    final byteIndex = position >> 3;
    final bits = position & 7;
    _length = byteIndex;
    if (bits == 0) {
      _acc = 0;
      _accBits = 0;
      return;
    }
    _acc = _buffer[byteIndex] & ((1 << bits) - 1);
    _accBits = bits;
  }

  /// Returns a copy of the written bytes (padded with zero bits).
  Uint8List toBytes() {
    if (_accBits == 0) {
      // No copy: the writer buffer is never reused after this call.
      return Uint8List.sublistView(_buffer, 0, _length);
    }
    final out = Uint8List(_length + 1);
    out.setRange(0, _length, _buffer);
    out[_length] = _acc & 0xFF;
    return out;
  }

  /// Returns the complete bytes written so far and drops them (streaming).
  Uint8List takeCompleteBytes() {
    if (_length == 0) return Uint8List(0);
    final out = Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));
    _length = 0;
    return out;
  }
}
