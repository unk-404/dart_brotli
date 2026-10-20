/// Public Brotli decoder API: one-shot decompression and the push/streaming
/// [BrotliDecoder].
///
/// The heavy lifting lives in `decoder_core.dart` (frame + state machine) and
/// `decoder_metablock.dart` (compressed metablocks, dictionary). This file is
/// the thin public surface:
///
/// * `BrotliDecoderCore.decompressAll` is the one-shot path used by
///   [brotliDecompress];
/// * [BytesInputQueue] is the [BitReaderInput] fed by [BrotliDecoder.addInput];
/// * [BrotliDecoder] exposes the push API (`addInput` / `closeInput` /
///   `decode`), matching the contract in `decoder-plan.md` §5.4:
///   `needMoreInput` means every added byte was taken, `needMoreOutput` means
///   the caller's slice is full, and `done` is idempotent.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:blit/bytes.dart' show BytesLike;

import '../common/errors.dart';
import '../options.dart';
import 'bit_reader.dart';
import 'decoder_core.dart';

/// Decompresses one complete Brotli stream.
///
/// This is the Compat/Uint8List entry point. The blit-native `Bytes` entry
/// point lives in `brotli_neo.dart` and wraps this function.
///
/// Set [BrotliDecodeOptions.compoundDictionary] to attach the non-RFC
/// caller-provided LZ77 dictionary (`brotli --dictionary`) that was used to
/// produce the stream.
///
/// Throws [BrotliException] for malformed input,
/// [BrotliErrorCode.outputLimitExceeded] when `options.maxOutputSize` is
/// exceeded, and [BrotliErrorCode.unusedBytesAfterEnd] for trailing bytes
/// (strict one-shot semantics).
Uint8List brotliDecompress(
  Uint8List input, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
}) {
  return BrotliDecoderCore.decompressAll(
    input,
    allowLargeWindow: options.allowLargeWindow,
    maxOutputSize: options.maxOutputSize,
    eagerOutput: options.eagerOutput,
    compoundDictionary: options.compoundDictionary,
    sharedDictionary: options.sharedDictionary,
  );
}

/// FIFO of byte chunks handed to the decoder as a [BitReaderInput].
///
/// The queue is deliberately narrow and copy-free: chunks added as
/// `Uint8List`/`BytesLike` are taken by reference (a `Bytes` view is resolved
/// with [BytesLike.asUint8List] once), and the [BitReader] copies from the
/// queue into its own 4 KiB window on demand. Callers must therefore not
/// modify a buffer after adding it until [consumedBytes] has passed it.
///
/// This class is public because custom drivers (for example file decoders)
/// may want to feed a [BitReader] directly; [BrotliDecoder] is the friendly
/// wrapper.
final class BytesInputQueue implements BitReaderInput {
  final ListQueue<Uint8List> _chunks = ListQueue<Uint8List>();
  int _headOffset = 0;
  int _addedBytes = 0;
  int _consumedBytes = 0;
  bool _closed = false;

  /// Total bytes ever added to the queue.
  int get addedBytes => _addedBytes;

  /// Total bytes handed to the decoder so far.
  int get consumedBytes => _consumedBytes;

  /// Bytes added but not yet handed to the decoder.
  int get availableBytes => _addedBytes - _consumedBytes;

  /// Adds a chunk (ownership of the backing bytes stays with the caller).
  void addBytes(BytesLike bytes) {
    addUint8List(bytes.asUint8List());
  }

  /// Adds a chunk by reference; do not modify it until it is consumed.
  void addUint8List(Uint8List bytes) {
    if (_closed) {
      throw StateError('cannot add input to a closed BytesInputQueue');
    }
    if (bytes.isEmpty) {
      return;
    }
    _chunks.add(bytes);
    _addedBytes += bytes.length;
  }

  /// Signals that no more bytes will be added.
  void close() {
    _closed = true;
  }

  @override
  bool get isClosed => _closed;

  @override
  int readInto(Uint8List destination, int offset, int length) {
    if (length <= 0) {
      return 0;
    }
    var written = 0;
    while (written < length && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final available = chunk.length - _headOffset;
      if (available <= 0) {
        _chunks.removeFirst();
        _headOffset = 0;
        continue;
      }
      final remaining = length - written;
      final count = available < remaining ? available : remaining;
      destination.setRange(
        offset + written,
        offset + written + count,
        chunk,
        _headOffset,
      );
      _headOffset += count;
      written += count;
      _consumedBytes += count;
      if (_headOffset == chunk.length) {
        _chunks.removeFirst();
        _headOffset = 0;
      }
    }
    return written;
  }
}

/// Push-style streaming Brotli decoder.
///
/// ```dart
/// final decoder = BrotliDecoder();
/// final out = Uint8List(64 * 1024);
/// var offset = 0;
/// while (offset < compressed.length) {
///   final end = min(offset + 4096, compressed.length);
///   decoder.addInput(compressed.sublist(offset, end));
///   offset = end;
/// }
/// decoder.closeInput();
/// while (decoder.decode(out) != BrotliStatus.done) {
///   // consume decoder.bytesWritten bytes of `out`
/// }
/// ```
///
/// Contract (mirrors the C decoder):
///
/// * [decode] fills `out[start..end)` and never rewinds it;
/// * [bytesWritten] is the number of bytes produced by the latest call;
/// * [BrotliStatus.needMoreInput] implies every added byte has been consumed
///   and [consumedInput] equals the number of bytes passed to [addInput];
/// * [BrotliStatus.needMoreOutput] means the caller's slice is full;
/// * [BrotliStatus.done] is idempotent, and input added after `done` is
///   ignored (streaming semantics; the strict one-shot API reports trailing
///   bytes instead);
/// * after a [BrotliException] the decoder is dead and every call rethrows it;
/// * [close] is idempotent and makes further calls invalid.
final class BrotliDecoder {
  BrotliDecoder({BrotliDecodeOptions options = const BrotliDecodeOptions()})
    : _input = BytesInputQueue() {
    _core = BrotliDecoderCore(
      BitReader(_input),
      allowLargeWindow: options.allowLargeWindow,
      eagerOutput: options.eagerOutput,
      maxOutputSize: options.maxOutputSize,
      compoundDictionary: options.compoundDictionary,
      sharedDictionary: options.sharedDictionary,
    );
  }

  final BytesInputQueue _input;
  late final BrotliDecoderCore _core;

  int _bytesWritten = 0;
  bool _done = false;
  bool _closed = false;
  BrotliException? _failure;

  /// Bytes produced by the most recent [decode] call.
  int get bytesWritten => _bytesWritten;

  /// Bytes taken from the input queue so far.
  int get consumedInput => _input.consumedBytes;

  /// Bytes added with [addInput] but not yet taken by the decoder.
  int get availableInput => _input.availableBytes;

  /// Sum of the metablock lengths seen so far, capped at 1 GiB.
  ///
  /// Useful as a first output-buffer size hint; it is a lower bound, not a
  /// promise (a stream can lie about its metablock lengths).
  int get estimatedTotalSize => _core.state.expectedTotalSize;

  /// Number of static-dictionary references decoded so far (telemetry).
  int get dictionaryReferenceCount => _core.state.dictionaryReferenceCount;

  /// Number of compound-dictionary references decoded so far (telemetry).
  int get compoundDictionaryReferenceCount =>
      _core.state.compoundDictionaryReferenceCount;

  /// Whether the stream ended successfully.
  bool get isDone => _done;

  /// Adds compressed bytes.
  ///
  /// Accepts `Uint8List` or any `BytesLike` (the blit `Bytes` type implements
  /// it); a `List<int>` is accepted for compatibility and copied. The bytes
  /// are taken by reference, so do not modify them until they are consumed
  /// ([availableInput] drops accordingly) or until [closeInput] is called.
  ///
  /// Input added after [BrotliStatus.done] is ignored.
  void addInput(Object input) {
    _checkUsable();
    if (_done) {
      return;
    }
    final Uint8List bytes;
    if (input is Uint8List) {
      bytes = input;
    } else if (input is BytesLike) {
      bytes = input.asUint8List();
    } else if (input is List<int>) {
      bytes = Uint8List.fromList(input);
    } else {
      throw ArgumentError.value(
        input,
        'input',
        'expected a Uint8List or BytesLike',
      );
    }
    _input.addUint8List(bytes);
  }

  /// Signals the end of the compressed stream.
  ///
  /// Idempotent; may be called before all data was decoded (a truncated
  /// stream then throws [BrotliErrorCode.truncatedInput] on the next decode).
  void closeInput() {
    _input.close();
  }

  /// Decodes into `out[start..end)` (`end` defaults to `out.length`).
  ///
  /// Returns the next [BrotliStatus]. See the class docs for the contract.
  BrotliStatus decode(Uint8List out, [int start = 0, int? end]) {
    _checkUsable();
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    if (_done) {
      _bytesWritten = 0;
      return BrotliStatus.done;
    }
    try {
      final status = _core.decode(out, start, end);
      _bytesWritten = _core.bytesWritten;
      if (status == BrotliStatus.done) {
        _done = true;
      }
      return status;
    } on BrotliException catch (error) {
      _failure = error;
      rethrow;
    }
  }

  /// Releases the decoder. Idempotent; further calls throw [StateError].
  void close() {
    _closed = true;
    _input.close();
  }

  void _checkUsable() {
    if (_closed) {
      throw StateError('BrotliDecoder is closed');
    }
  }
}
