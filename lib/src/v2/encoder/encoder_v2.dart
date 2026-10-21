/// `BrotliEncoderV2` - the v0.2.0 fast encoder entry point.
///
/// The v2 hot path covers the plain raw-data case at qualities 0, 1 and 2..5
/// with a new matcher/parser and a single-parse, single-serialization
/// meta-block writer (no context modeling, no block splitting, no dictionary
/// candidates). Everything else - quality 6 and up, compound/prepared
/// dictionaries, large-window streams and non-default window sizes - is
/// delegated to the mature v1 encoder, so every option keeps producing valid
/// RFC 7932 / extension streams.
///
/// Output is a `Uint8List`; `encodeInto` writes into a caller supplied buffer
/// and returns the number of bytes written.
library;

import 'dart:typed_data';

import 'package:blit/bytes.dart';

import '../../encoder/command.dart';
import '../../encoder/encoder.dart' as v1;
import '../../options.dart';
import 'bit_writer.dart';
import 'metablock_v2.dart';
import 'parse_v2.dart';

/// Highest quality served by the v2 fast path. Qualities 2..5 use it; quality
/// 0 and 1 are routed to the v1 greedy encoder, which is measurably faster
/// there, and quality 6+ keeps the v1 quality tiers.
const int v2MaxFastQuality = 5;

/// Lowest quality served by the v2 fast path.
const int v2MinFastQuality = 2;

/// Window bits used by the v2 fast path.
const int v2Lgwin = 22;

/// The v0.2.0 encoder API.
abstract final class BrotliEncoderV2 {
  /// Encodes [input] and returns the compressed bytes.
  ///
  /// Quality routing:
  ///
  /// * 2..5 - v2 fast path (single-tree meta-blocks, lazy parse).
  /// * 0 / 1 on binary-looking input - v2 greedy binary tier (single-slot hash,
  ///   greedy, no recent-distance probes); q0 and q1 share it because its
  ///   output is smaller than v1's at both levels.
  /// * 0 / 1 on text - v1 greedy encoder, which has the better ratio/speed on
  ///   text, as do 6+ and every dictionary / large-window / non-default-window
  ///   option.
  ///
  /// [options] is the same [BrotliEncodeOptions] the v1 encoder uses.
  static Uint8List encode(
    Uint8List input, {
    BrotliEncodeOptions options = const BrotliEncodeOptions(),
  }) {
    if (_canUseFastPath(options)) {
      if (options.quality == 5 && _looksBinary(input)) {
        return _fastEncode(input, V2ParseParams.q5Binary);
      }
      return _fastEncode(input, V2ParseParams.q5);
    }
    if (_canUseGreedyBinary(options) && _looksBinary(input)) {
      // Binary q0 and q1 share one greedy tier: it is the fastest pipeline and
      // its output is already smaller than v1's q0/q1.
      return _fastEncode(input, V2ParseParams.greedyBinary);
    }
    return v1.brotliCompress(input, options: options);
  }

  /// Encodes [input] and returns a zero-copy [Bytes] view of the output.
  static Bytes encodeBytes(
    BytesLike input, {
    BrotliEncodeOptions options = const BrotliEncodeOptions(),
  }) => Bytes.fromUint8List(encode(input.asUint8List(), options: options));

  static Uint8List _fastEncode(Uint8List input, V2ParseParams params) {
    final writer = BitWriterV2(initialCapacity: input.length >> 2);
    _writeFastStream(writer, input, params);
    return writer.toBytes();
  }

  /// Encodes [input] into [destination] and returns the byte count.
  ///
  /// Throws [ArgumentError] when [destination] is too small.
  static int encodeInto(
    Uint8List destination,
    Uint8List input, {
    BrotliEncodeOptions options = const BrotliEncodeOptions(),
  }) {
    final encoded = encode(input, options: options);
    if (encoded.length > destination.length) {
      throw ArgumentError.value(
        destination.length,
        'destination',
        'needs at least ${encoded.length} bytes',
      );
    }
    destination.setRange(0, encoded.length, encoded);
    return encoded.length;
  }

  /// Bytes needed to encode [inputLength] bytes at the given [quality]
  /// (the same bound the v1 encoder documents).
  static int maxCompressedSize(int inputLength) =>
      v1.maxCompressedSize(inputLength);

  /// Whether quality 0/1 may use the v2 greedy binary tier (plain options
  /// only, same gate as the fast path).
  static bool _canUseGreedyBinary(BrotliEncodeOptions options) {
    if (options.quality > 1) return false;
    if (options.compoundDictionary != null) return false;
    if (options.preparedDictionary != null) return false;
    if (options.largeWindow) return false;
    if (options.lgwin != 22) return false;
    return true;
  }

  /// Conservative content probe for the binary greedy tier: a small sample is
  /// classified as binary when under 90% of its bytes are printable ASCII
  /// (plus tab/CR/LF). UTF-8 text is 100% printable, the binary corpus ~68%.
  static bool _looksBinary(Uint8List input) {
    if (input.isEmpty) return false;
    final sample = input.length < 4096 ? input.length : 4096;
    var printable = 0;
    for (var i = 0; i < sample; i++) {
      final byte = input[i];
      if ((byte >= 0x20 && byte <= 0x7E) ||
          byte == 9 ||
          byte == 10 ||
          byte == 13) {
        printable++;
      }
    }
    return printable * 10 < sample * 9;
  }

  static bool _canUseFastPath(BrotliEncodeOptions options) {
    if (options.quality < v2MinFastQuality) return false;
    if (options.quality > v2MaxFastQuality) return false;
    if (options.compoundDictionary != null) return false;
    if (options.preparedDictionary != null) return false;
    if (options.largeWindow) return false;
    if (options.lgwin != 22) return false;
    return true;
  }

  static void _writeFastStream(
    BitWriterV2 writer,
    Uint8List input,
    V2ParseParams params,
  ) {
    _writeWindowBits(writer, v2Lgwin);
    if (input.isEmpty) {
      _writeFinalEmptyBlock(writer);
      writer.alignToByte();
      return;
    }
    final hasher = FastHasher(
      input,
      params.bucketBits,
      trackChain: params.maxCandidates > 0,
    );
    // Copies are at least [minMatch] == 4 bytes, so a block needs at most
    // blockSize / 4  commands; sizing the buffer that way (instead of the
    // worst-case 2 bytes per command) avoids a multi-megabyte zeroed
    // allocation on every encode.
    final commands = CommandBuffer(params.blockSize ~/ 4 + 16);
    final distanceCache = createInitialDistanceCache();
    final metaBlockWriter = V2MetaBlockWriter();
    final maxBackwardLimit = (1 << v2Lgwin) - 16;
    final blockSize = params.blockSize;
    for (var offset = 0; offset < input.length; offset += blockSize) {
      final length = offset + blockSize <= input.length
          ? blockSize
          : input.length - offset;
      final startBits = writer.bitPosition;
      parseV2(
        input,
        offset,
        length,
        hasher,
        commands,
        distanceCache,
        maxBackwardLimit,
        params,
      );
      final mark = writer.mark;
      metaBlockWriter.store(writer, input, offset, length, commands);
      final uncompressedBits = V2MetaBlockWriter.uncompressedBits(
        length,
        startBits,
      );
      if (writer.bitPosition - startBits > uncompressedBits) {
        writer.rewind(mark);
        V2MetaBlockWriter.storeUncompressed(writer, input, offset, length);
      }
    }
    _writeFinalEmptyBlock(writer);
    writer.alignToByte();
  }

  static void _writeFinalEmptyBlock(BitWriterV2 writer) {
    writer.writeBits(1, 1); // ISLAST
    writer.writeBits(1, 1); // ISLASTEMPTY
  }

  static void _writeWindowBits(BitWriterV2 writer, int lgwin) {
    if (lgwin == 16) {
      writer.writeBits(1, 0);
    } else if (lgwin == 17) {
      writer.writeBits(7, 1);
    } else if (lgwin > 17) {
      writer.writeBits(4, ((lgwin - 17) << 1) | 1);
    } else {
      writer.writeBits(7, ((lgwin - 8) << 4) | 1);
    }
  }
}
