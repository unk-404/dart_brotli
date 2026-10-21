/// v2 decoder API: raw `Uint8List` one-shot/into/streaming entry points.
///
/// The v2 hot path lives in [BrotliDecoderCore] + `decoder_metablock.dart`;
/// this file only adapts the public option surface and adds a bounded-output
/// `decodeInto` that never allocates on the output side.
library;

import 'dart:typed_data';

import 'package:blit/bytes.dart';

import '../../common/errors.dart';
import '../../options.dart';
import 'bit_reader.dart';
import 'decoder_core.dart';
import 'decoder_state.dart' show maxTransformedWordLength;

/// Fast Brotli decoder (v2).
abstract final class BrotliDecoderV2 {
  /// One-shot decode of [input] into a fresh buffer.
  ///
  /// Uses a single large output allocation so the whole-metablock fast path
  /// can run without a mid-metablock ring flush. If the stream is larger than
  /// the initial guess, the allocation doubles and decoding restarts.
  static Uint8List decode(
    Uint8List input, {
    BrotliDecodeOptions options = const BrotliDecodeOptions(),
  }) {
    final limit = options.maxOutputSize;
    var capacity = (1 << 20) + maxTransformedWordLength;
    if (limit != null && capacity > limit) {
      capacity = limit;
    }
    while (true) {
      final buffer = Uint8List(capacity);
      try {
        final used = decodeInto(buffer, input, options: options);
        return Uint8List.sublistView(buffer, 0, used);
      } on BrotliException catch (error) {
        if (error.code != BrotliErrorCode.outputLimitExceeded) {
          rethrow;
        }
        final next = capacity * 2;
        if (limit != null && next > limit) {
          rethrow;
        }
        if (next > (1 << 30)) {
          rethrow;
        }
        capacity = next;
      }
    }
  }

  /// Decodes [input] and returns a zero-copy [Bytes] view of the output.
  static Bytes decodeBytes(
    BytesLike input, {
    BrotliDecodeOptions options = const BrotliDecodeOptions(),
  }) => Bytes.fromUint8List(decode(input.asUint8List(), options: options));

  /// Decodes [input] into [dst] and returns the number of bytes written.
  ///
  /// [dst] bounds the output: if the stream produces more bytes the decoder
  /// raises [BrotliErrorCode.outputLimitExceeded]. [expectedSize] is an
  /// optional hint (it does not preallocate; [dst] is caller-owned).
  static int decodeInto(
    Uint8List dst,
    Uint8List input, {
    BrotliDecodeOptions options = const BrotliDecodeOptions(),
    int? expectedSize,
  }) {
    if (expectedSize != null && expectedSize < 0) {
      throw ArgumentError.value(expectedSize, 'expectedSize');
    }
    final core = BrotliDecoderCore(
      BitReader.fromBytes(input),
      allowLargeWindow: options.allowLargeWindow,
      maxOutputSize: options.maxOutputSize,
      eagerOutput: options.eagerOutput,
      compoundDictionary: options.compoundDictionary,
      sharedDictionary: options.sharedDictionary,
    );
    var used = 0;
    while (true) {
      final status = core.decode(dst, used, dst.length);
      used += core.bytesWritten;
      switch (status) {
        case BrotliStatus.done:
          return used;
        case BrotliStatus.needMoreOutput:
          throw BrotliException(
            BrotliErrorCode.outputLimitExceeded,
            'output buffer of ${dst.length} bytes is too small',
            inputOffset: core.reader.bytesConsumed,
          );
        case BrotliStatus.needMoreInput:
          throw BrotliException(
            BrotliErrorCode.truncatedInput,
            'decoder requested more input from a closed stream',
            inputOffset: core.reader.bytesConsumed,
          );
      }
    }
  }
}

/// Streaming v2 decoder over raw `Uint8List` chunks (no blit types).
///
/// The hot loop is byte-identical to [BrotliDecoderV2]; streaming only changes
/// how input arrives and when output is flushed.
final class BrotliStreamDecoderV2 {
  BrotliStreamDecoderV2({
    BrotliDecodeOptions options = const BrotliDecodeOptions(),
  }) : _queue = _V2InputQueue() {
    _core = BrotliDecoderCore(
      BitReader(_queue),
      allowLargeWindow: options.allowLargeWindow,
      eagerOutput: options.eagerOutput,
      maxOutputSize: options.maxOutputSize,
      compoundDictionary: options.compoundDictionary,
      sharedDictionary: options.sharedDictionary,
    );
  }

  final _V2InputQueue _queue;
  late final BrotliDecoderCore _core;
  bool _inputClosed = false;

  /// Queues [bytes] (copied; callers may reuse the buffer afterwards).
  void addInput(Uint8List bytes) {
    if (_inputClosed) {
      throw StateError('input is already closed');
    }
    _queue.add(bytes);
  }

  /// Declares that no further input will be added.
  void closeInput() {
    _inputClosed = true;
    _queue.close();
  }

  /// Bytes produced by the most recent [decode] call.
  int get bytesWritten => _core.bytesWritten;

  /// Input bytes consumed so far.
  int get consumedInput => _core.reader.bytesConsumed;

  /// Decodes into `output[start..end)` and returns the next status.
  BrotliStatus decode(Uint8List output, [int start = 0, int? end]) {
    return _core.decode(output, start, end);
  }
}

final class _V2InputQueue implements BitReaderInput {
  final List<Uint8List> _chunks = <Uint8List>[];
  int _index = 0;
  int _offset = 0;
  bool _closed = false;

  void add(Uint8List bytes) {
    if (bytes.isNotEmpty) {
      _chunks.add(Uint8List.fromList(bytes));
    }
  }

  void close() {
    _closed = true;
  }

  @override
  int readInto(Uint8List destination, int offset, int length) {
    var written = 0;
    while (written < length && _index < _chunks.length) {
      final chunk = _chunks[_index];
      final available = chunk.length - _offset;
      if (available == 0) {
        _index++;
        _offset = 0;
        continue;
      }
      final count = available < length - written ? available : length - written;
      destination.setRange(
        offset + written,
        offset + written + count,
        chunk,
        _offset,
      );
      _offset += count;
      written += count;
    }
    return written;
  }

  @override
  bool get isClosed => _closed;
}
