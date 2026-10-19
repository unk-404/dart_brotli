/// LSB-first bit writer for RFC 7932 streams.
///
/// Brotli writes bits into increasing byte addresses, least-significant bit
/// first within each byte (see `c/enc/write_bits.h`). This implementation uses
/// a plain [Uint8List] output buffer plus a small pending-bit accumulator, so
/// every intermediate value stays far below 2^31 and the code behaves
/// identically on the VM, dart2js and dart2wasm:
///
/// * no `>>>`, no shifts of 32 bits or more, no 64-bit stores;
/// * `value` is consumed with masks and exact integer division, never a
///   32-bit right shift of a value that may be >= 2^31;
/// * no shift count exceeds 16 bits, and wide masks are built from 16-bit
///   halves so `1 << 31` is never evaluated.
///
/// Layout invariant: `_buffer` holds only complete bytes; bits that do not yet
/// fill a byte live in `_acc` (bit 0 = oldest), `_accBits` counts them. This
/// keeps [rewind] exact and makes [alignToByte] a single append.
library;

import 'dart:typed_data';

/// Mask for `bitCount` low bits; [bitCount] must be in `0..32`.
int _lowMask(int bitCount) {
  if (bitCount >= 32) return 0xFFFFFFFF;
  // Build wide masks from 16-bit halves: `1 << 31` is signed in JS.
  if (bitCount <= 16) return (1 << bitCount) - 1;
  return 0xFFFF | (((1 << (bitCount - 16)) - 1) << 16);
}

/// Writes bits (LSB-first) into an in-memory byte buffer.
///
/// Typical use:
///
/// ```dart
/// final w = BitWriter();
/// w.writeBits(3, 0b101);
/// w.alignToByte();
/// final bytes = w.toBytes();
/// ```
final class BitWriter {
  /// Creates a writer with room for [initialCapacity] bytes.
  BitWriter({int initialCapacity = 64})
    : _buffer = Uint8List(initialCapacity < 8 ? 8 : initialCapacity);

  Uint8List _buffer;
  int _length = 0; // number of complete bytes stored in _buffer
  int _acc = 0; // pending bits, oldest at bit 0
  int _accBits = 0; // number of pending bits in _acc (0..7)

  /// Total number of bits written so far.
  ///
  /// Uses multiplication (not `<<`) so the value stays correct on the web for
  /// buffers larger than 2^29 bytes.
  int get bitPosition => _length * 8 + _accBits;

  /// Number of bytes [toBytes] will return (the final partial byte is included).
  int get lengthInBytes => _length + (_accBits == 0 ? 0 : 1);

  /// Whether the writer is currently on a byte boundary.
  bool get isByteAligned => _accBits == 0;

  /// Discards all written data and resets the writer.
  void reset() {
    _length = 0;
    _acc = 0;
    _accBits = 0;
  }

  /// Writes the low [bitCount] bits of [value], least significant bit first.
  ///
  /// [bitCount] must be in `0..32`; [value] must be in `[0, 2^bitCount)`.
  /// Any higher bits of [value] are ignored (debug builds assert them clear).
  void writeBits(int bitCount, int value) {
    RangeError.checkValueInInterval(bitCount, 0, 32, 'bitCount');
    if (bitCount == 0) return;
    assert(value >= 0, 'value must be non-negative');
    assert(
      bitCount >= 32 ? value <= 0xFFFFFFFF : value <= _lowMask(bitCount),
      'value does not fit in $bitCount bits',
    );
    var remaining = bitCount;
    var rest = value;
    while (remaining > 0) {
      final space = 8 - _accBits;
      final take = remaining < space ? remaining : space;
      // take <= 8, accBits <= 7 => shifted piece < 2^16 (web-safe).
      _acc |= (rest & _lowMask(take)) << _accBits;
      _accBits += take;
      remaining -= take;
      if (_accBits == 8) {
        _append(_acc);
        _acc = 0;
        _accBits = 0;
      }
      if (remaining > 0) {
        // Exact integer division; `rest` is at most 2^32 - 1 (< 2^53).
        rest = rest ~/ (1 << take);
      }
    }
  }

  /// Writes a single bit, 0 or 1.
  void writeBit(int value) => writeBits(1, value);

  /// Pads the current partial byte with zero bits.
  void alignToByte() {
    if (_accBits == 0) return;
    _append(_acc); // high bits of _acc are zero by construction
    _acc = 0;
    _accBits = 0;
  }

  /// Returns a snapshot of the current bit position for [rewind].
  int mark() => bitPosition;

  /// Discards every bit written after [markPosition] (a value from [mark]).
  ///
  /// Raises [RangeError] if [markPosition] is outside `[0, bitPosition]`.
  void rewind(int markPosition) {
    RangeError.checkValueInInterval(
      markPosition,
      0,
      bitPosition,
      'markPosition',
    );
    final byteIndex = markPosition ~/ 8;
    final bitOffset = markPosition % 8;
    if (bitOffset == 0) {
      _length = byteIndex;
      _acc = 0;
      _accBits = 0;
    } else if (byteIndex < _length) {
      // The partial byte was already emitted; pull back its low bits.
      _acc = _buffer[byteIndex] & _lowMask(bitOffset);
      _accBits = bitOffset;
      _length = byteIndex;
    } else {
      // The partial byte never left the accumulator.
      _acc &= _lowMask(bitOffset);
      _accBits = bitOffset;
    }
    // No stale-byte cleanup is needed: `_buffer` stores only complete bytes,
    // `_append` overwrites from `_length` and `toBytes` never reads past it.
    // (This is where the C writer masks a partial 64-bit store; our invariant
    // removes the hazard entirely, and rewind stays O(1).)
  }

  /// Appends one byte; the writer must be byte-aligned.
  void writeByte(int value) {
    if (_accBits != 0) {
      throw StateError('writeByte requires a byte-aligned bit position');
    }
    RangeError.checkValueInInterval(value, 0, 255, 'value');
    _append(value);
  }

  /// Appends raw bytes; the writer must be byte-aligned.
  ///
  /// This is the fast path used for uncompressed meta-block payloads.
  void writeBytes(Uint8List data, [int start = 0, int? end]) {
    if (_accBits != 0) {
      throw StateError('writeBytes requires a byte-aligned bit position');
    }
    final stop = end ?? data.length;
    RangeError.checkValueInInterval(start, 0, data.length, 'start');
    RangeError.checkValueInInterval(stop, start, data.length, 'end');
    final count = stop - start;
    if (count == 0) return;
    _ensureCapacity(_length + count);
    _buffer.setRange(_length, _length + count, data, start);
    _length += count;
  }

  /// Returns the stream bytes written so far.
  ///
  /// A trailing partial byte (if any) is zero-padded. The writer is not
  /// modified, so more bits may be written afterwards.
  Uint8List toBytes() {
    final out = Uint8List(lengthInBytes);
    out.setRange(0, _length, _buffer);
    if (_accBits != 0) out[_length] = _acc;
    return out;
  }

  void _append(int byte) {
    _ensureCapacity(_length + 1);
    _buffer[_length++] = byte & 0xFF;
  }

  void _ensureCapacity(int required) {
    if (required <= _buffer.length) return;
    var capacity = _buffer.length < 8 ? 8 : _buffer.length;
    while (capacity < required) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
  }
}
