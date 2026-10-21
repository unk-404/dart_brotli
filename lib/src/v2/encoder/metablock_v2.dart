/// Meta-block writer for the v2 encoder speed tier.
///
/// This is a deliberately minimal encoder serializer: one literal tree, one
/// command tree and one distance tree per meta-block, no context modeling, no
/// block splitting and no dictionary references (the v1 encoder owns those
/// features). It writes into the v2 [BitWriterV2]; the Huffman tree
/// serialization reuses the v1 [HuffmanEncoder] through a small bit bridge so
/// the tree format stays byte-exact without duplicating that logic.
library;

import 'dart:typed_data';

import '../../encoder/bit_writer.dart' show BitWriter;
import '../../encoder/command.dart';
import '../../encoder/huffman_encoder.dart';
import 'bit_writer.dart';

/// Number of command symbols in the length-code alphabet.
const int v2NumCommandSymbols = 704;

/// Number of distance symbols for NPOSTFIX = NDIRECT = 0.
const int v2NumDistanceSymbols = 64;

/// Writes single-tree Brotli meta-blocks.
final class V2MetaBlockWriter {
  V2MetaBlockWriter();

  final HuffmanEncoder _huffman = HuffmanEncoder();
  final BitWriter _treeWriter = BitWriter();

  final Uint32List _literalHistogram = Uint32List(256);
  final Uint32List _commandHistogram = Uint32List(v2NumCommandSymbols);
  final Uint32List _distanceHistogram = Uint32List(v2NumDistanceSymbols);

  final Uint8List _literalDepth = Uint8List(256);
  final Uint8List _commandDepth = Uint8List(v2NumCommandSymbols);
  final Uint8List _distanceDepth = Uint8List(v2NumDistanceSymbols);

  final Uint16List _literalBits = Uint16List(256);
  final Uint16List _commandBits = Uint16List(v2NumCommandSymbols);
  final Uint16List _distanceBits = Uint16List(v2NumDistanceSymbols);

  /// Total bits needed by an uncompressed meta-block carrying [length] bytes
  /// that starts at bit position [startBits].
  static int uncompressedBits(int length, int startBits) {
    final mnibbles = _mnibbles(length);
    // ISLAST (1) + MNIBBLES (2) + MLEN (mnibbles * 4) + ISUNCOMPRESSED (1).
    final headerBits = 1 + 2 + mnibbles * 4 + 1;
    final alignedStart = _align(startBits, 8) + headerBits;
    final payloadStart = _align(alignedStart, 8);
    final payloadEnd = payloadStart + length * 8;
    return payloadEnd - startBits;
  }

  /// Writes one compressed meta-block without the ISLAST flag.
  void store(
    BitWriterV2 writer,
    Uint8List input,
    int start,
    int length,
    CommandBuffer commands,
  ) {
    final literalHistogram = _literalHistogram;
    final commandHistogram = _commandHistogram;
    final distanceHistogram = _distanceHistogram;
    literalHistogram.fillRange(0, 256, 0);
    commandHistogram.fillRange(0, v2NumCommandSymbols, 0);
    distanceHistogram.fillRange(0, v2NumDistanceSymbols, 0);

    var pos = start;
    for (var i = 0; i < commands.count; i++) {
      final insertLen = commands.insertLen[i];
      for (var j = 0; j < insertLen; j++) {
        literalHistogram[input[pos + j]]++;
      }
      pos += insertLen;
      final cmdPrefix = commands.cmdPrefix[i];
      commandHistogram[cmdPrefix]++;
      final copyLen = commands.copyLen[i];
      if (copyLen != 0 && cmdPrefix >= 128) {
        distanceHistogram[commands.distPrefix[i] & 0x3FF]++;
      }
      pos += copyLen;
    }

    // Header first: not last, compressed, one block type each, NPOSTFIX =
    // NDIRECT = 0, context mode = LSB6, trivial literal/distance context maps.
    final mnibbles = _mnibbles(length);
    writer.writeBits(1, 0); // ISLAST
    writer.writeBits(2, mnibbles - 4);
    writer.writeBits(mnibbles * 4, length - 1);
    writer.writeBits(1, 0); // ISUNCOMPRESSED
    writer.writeBits(1, 0); // NBLTYPESL = 1
    writer.writeBits(1, 0); // NBLTYPESI = 1
    writer.writeBits(1, 0); // NBLTYPESD = 1
    writer.writeBits(2, 0); // NPOSTFIX
    writer.writeBits(4, 0); // NDIRECT
    writer.writeBits(2, 0); // context mode: LSB6
    writer.writeBits(1, 0); // literal context map (trivial)
    writer.writeBits(1, 0); // distance context map (trivial)

    _storeTree(
      literalHistogram,
      256,
      256,
      writer,
      _literalDepth,
      _literalBits,
    );
    _storeTree(
      commandHistogram,
      v2NumCommandSymbols,
      v2NumCommandSymbols,
      writer,
      _commandDepth,
      _commandBits,
    );
    _storeTree(
      distanceHistogram,
      v2NumDistanceSymbols,
      v2NumDistanceSymbols,
      writer,
      _distanceDepth,
      _distanceBits,
    );

    // Command stream.
    final literalDepth = _literalDepth;
    final literalBits = _literalBits;
    final commandDepth = _commandDepth;
    final commandBits = _commandBits;
    final distanceDepth = _distanceDepth;
    final distanceBits = _distanceBits;
    pos = start;
    for (var i = 0; i < commands.count; i++) {
      final insertLen = commands.insertLen[i];
      final copyLen = commands.copyLen[i];
      final command = commands.cmdPrefix[i];
      // The command symbol and its insert/copy extra bits are usually short
      // enough to emit as one write; the bits are identical either way.
      final commandDepthBits = commandDepth[command];
      final insCode = getInsertLengthCode(insertLen);
      final insExtraBits = kInsExtra[insCode];
      final insExtraValue = commandInsertExtraValue(insertLen, insCode);
      var copyExtraBits = 0;
      var copyExtraValue = 0;
      if (copyLen != 0) {
        final copyCode = getCopyLengthCode(copyLen);
        copyExtraBits = kCopyExtra[copyCode];
        copyExtraValue = commandCopyExtraValue(copyLen, copyCode);
      }
      final totalBits = commandDepthBits + insExtraBits + copyExtraBits;
      if (totalBits <= 32) {
        writer.writeBits(
          totalBits,
          commandBits[command] |
              (insExtraValue << commandDepthBits) |
              (copyExtraValue << (commandDepthBits + insExtraBits)),
        );
      } else {
        writer.writeBits(commandDepthBits, commandBits[command]);
        writer.writeBits(insExtraBits, insExtraValue);
        writer.writeBits(copyExtraBits, copyExtraValue);
      }
      // Literals dominate binary meta-blocks. Four consecutive literals that
      // share a code length are packed into a single write (up to 32 bits),
      // cutting the per-literal call overhead without changing the bit stream.
      var j = 0;
      while (j < insertLen) {
        if (insertLen - j >= 4) {
          final a = input[pos + j];
          final b = input[pos + j + 1];
          final c = input[pos + j + 2];
          final d = input[pos + j + 3];
          final depth = literalDepth[a];
          if (depth == literalDepth[b] &&
              depth == literalDepth[c] &&
              depth == literalDepth[d] &&
              depth <= 8) {
            final packed =
                literalBits[a] |
                (literalBits[b] << depth) |
                (literalBits[c] << (depth * 2)) |
                (literalBits[d] << (depth * 3));
            writer.writeBits(depth * 4, packed);
            j += 4;
            continue;
          }
        }
        final literal = input[pos + j];
        writer.writeBits(literalDepth[literal], literalBits[literal]);
        j++;
      }
      pos += insertLen;
      if (copyLen != 0) {
        pos += copyLen;
        if (command >= 128) {
          final distancePrefix = commands.distPrefix[i];
          final symbol = distancePrefix & 0x3FF;
          final symbolDepth = distanceDepth[symbol];
          final extraBits = distancePrefix >> 10;
          if (symbolDepth + extraBits <= 32) {
            writer.writeBits(
              symbolDepth + extraBits,
              distanceBits[symbol] |
                  (commands.distExtra[i] << symbolDepth),
            );
          } else {
            writer.writeBits(symbolDepth, distanceBits[symbol]);
            if (extraBits != 0) {
              writer.writeBits(extraBits, commands.distExtra[i]);
            }
          }
        }
      }
    }
  }

  /// Writes an uncompressed meta-block (USLAST = false).
  static void storeUncompressed(
    BitWriterV2 writer,
    Uint8List input,
    int start,
    int length,
  ) {
    final mnibbles = _mnibbles(length);
    writer.writeBits(1, 0); // ISLAST
    writer.writeBits(2, mnibbles - 4);
    writer.writeBits(mnibbles * 4, length - 1);
    writer.writeBits(1, 1); // ISUNCOMPRESSED
    writer.alignToByte();
    writer.writeAlignedBytes(input, start, length);
  }

  void _storeTree(
    Uint32List histogram,
    int histogramLength,
    int alphabetSize,
    BitWriterV2 writer,
    Uint8List depth,
    Uint16List bits,
  ) {
    _treeWriter.reset();
    _huffman.buildAndStore(
      histogram,
      histogramLength,
      alphabetSize,
      _treeWriter,
      depth,
      bits,
    );
    final bitCount = _treeWriter.bitPosition;
    if (bitCount == 0) return;
    final bytes = _treeWriter.toBytes();
    final fullBytes = bitCount >> 3;
    for (var i = 0; i < fullBytes; i++) {
      writer.writeBits(8, bytes[i]);
    }
    final remainder = bitCount & 7;
    if (remainder != 0) {
      writer.writeBits(remainder, bytes[fullBytes] & ((1 << remainder) - 1));
    }
  }

  static int _mnibbles(int length) {
    // MLEN = length - 1 is written with 4, 5 or 6 nibbles; choose the smallest
    // that represents it (a non-canonical longer form is rejected).
    final value = length - 1;
    if (value < (1 << 16)) return 4;
    if (value < (1 << 20)) return 5;
    return 6;
  }

  static int _align(int bits, int alignment) =>
      (bits + alignment - 1) & ~(alignment - 1);
}
