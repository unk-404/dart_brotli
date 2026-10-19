/// RFC 7932 literal context modes and lookup helpers.
library;

import 'dart:typed_data';

import 'context_lookup.dart';

const int contextModeLsb6 = 0;
const int contextModeMsb6 = 1;
const int contextModeUtf8 = 2;
const int contextModeSigned = 3;

/// Returns the 6-bit literal context id for [mode].
///
/// [p1] is the previous byte, [p2] the byte before it. Both are 0 at the start
/// of the stream. This is the hot-path accessor; callers should keep
/// [kContextLookupTable] in a local when decoding many literals.
int contextId(int mode, int p1, int p2) {
  final base = mode << 9;
  return kContextLookupTable[base + (p1 & 0xFF)] |
      kContextLookupTable[base + 256 + (p2 & 0xFF)];
}

/// Returns a zero-copy view of the table for a mode; mostly for tests.
Uint8List contextTableForMode(int mode) {
  final base = mode << 9;
  return Uint8List.sublistView(kContextLookupTable, base, base + 512);
}
