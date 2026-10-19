/// Portable 32-bit helpers shared by the decoder and encoder.
///
/// Brotli's bit stream is defined in terms of 32-bit wrap-around arithmetic.
/// These helpers keep every intermediate value in `[0, 2^32)` so the same code
/// is correct on the VM, dart2js and dart2wasm. Do not replace `& 0xFFFFFFFF`
/// with `>>>`.
library;

const int k32Mask = 0xFFFFFFFF;
const int k16Mask = 0xFFFF;

/// Returns the floor of log2 of [x]; [x] must be positive.
int log2Floor(int x) {
  assert(x > 0);
  var result = -1;
  var step = 16;
  var v = x;
  while (step > 0) {
    final next = v >> step;
    if (next != 0) {
      result += step;
      v = next;
    }
    step >>= 1;
  }
  return result + v;
}

/// 32x32 -> low 32 bits multiplication without relying on JS 53-bit numbers.
int mul32(int a, int b) {
  final aLo = a & k16Mask;
  final aHi = (a >> 16) & k16Mask;
  final bLo = b & k16Mask;
  final bHi = (b >> 16) & k16Mask;
  final lo = aLo * bLo;
  final mid = aLo * bHi + aHi * bLo;
  return (lo + ((mid & k16Mask) << 16)) & k32Mask;
}

/// Rotates [value] left by [amount] in 32-bit space.
int rotl32(int value, int amount) {
  final n = amount & 31;
  if (n == 0) return value & k32Mask;
  final v = value & k32Mask;
  return ((v << n) | (v >> (32 - n))) & k32Mask;
}

/// Aligns a bit position up to the next byte boundary.
int alignToByte(int bitPosition) => (bitPosition + 7) & ~7;

/// Number of bytes needed for [bitCount] bits.
int bytesForBits(int bitCount) => (bitCount + 7) >> 3;
