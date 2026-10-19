/// `dart:convert` `Codec`/`Converter` wrappers for Brotli.
///
/// This is the Compat layer (no blit types): `List<int>` in, `List<int>` out.
/// The decoder converter uses the push-style [BrotliDecoder] for chunked
/// conversion, so a `Stream<List<int>>.transform(BrotliCodec().decoder)` emits
/// decompressed chunks as they become available instead of buffering the whole
/// compressed stream.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../decoder/decoder.dart';
import '../encoder/encoder.dart';
import '../options.dart';

/// Default output-buffer size used by [BrotliDecoderSink].
const int _decoderChunkSize = 64 * 1024;

/// Brotli [Codec] with configurable encoder/decoder options.
///
/// ```dart
/// const codec = BrotliCodec();
/// final compressed = codec.encode(utf8.encode('hello'));
/// final text = codec.decodeToString(compressed);
/// ```
final class BrotliCodec extends Codec<List<int>, List<int>> {
  const BrotliCodec({
    this.encodeOptions = const BrotliEncodeOptions(),
    this.decodeOptions = const BrotliDecodeOptions(),
  });

  /// Options used by [encode]/[encoder].
  final BrotliEncodeOptions encodeOptions;

  /// Options used by [decode]/[decoder].
  final BrotliDecodeOptions decodeOptions;

  @override
  Converter<List<int>, List<int>> get encoder =>
      BrotliEncoderConverter(encodeOptions);

  @override
  Converter<List<int>, List<int>> get decoder =>
      BrotliDecoderConverter(decodeOptions);

  @override
  List<int> encode(List<int> input) => encoder.convert(input);

  @override
  List<int> decode(List<int> encoded) => decoder.convert(encoded);

  /// Encodes [input] and returns the backing bytes directly.
  Uint8List encodeBytes(Uint8List input) =>
      brotliCompress(input, options: encodeOptions);

  /// Decodes [input] and returns the backing bytes directly.
  Uint8List decodeBytes(Uint8List input) =>
      brotliDecompress(input, options: decodeOptions);

  /// Decodes a Brotli-compressed UTF-8 string.
  String decodeToString(List<int> input, {bool allowMalformed = false}) {
    return utf8.decode(decode(input), allowMalformed: allowMalformed);
  }

  /// UTF-8-encodes [input] and compresses it.
  Uint8List encodeString(String input) {
    return encodeBytes(Uint8List.fromList(utf8.encode(input)));
  }
}

/// One-shot encoder converter (`Converter<List<int>, List<int>>`).
final class BrotliEncoderConverter extends Converter<List<int>, List<int>> {
  const BrotliEncoderConverter([this.options = const BrotliEncodeOptions()]);

  final BrotliEncodeOptions options;

  @override
  List<int> convert(List<int> input) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    return brotliCompress(bytes, options: options);
  }

  @override
  Sink<List<int>> startChunkedConversion(Sink<List<int>> sink) {
    return BrotliEncoderSink(options, sink);
  }
}

/// One-shot decoder converter (`Converter<List<int>, List<int>>`).
final class BrotliDecoderConverter extends Converter<List<int>, List<int>> {
  const BrotliDecoderConverter([this.options = const BrotliDecodeOptions()]);

  final BrotliDecodeOptions options;

  @override
  List<int> convert(List<int> input) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    return brotliDecompress(bytes, options: options);
  }

  @override
  Sink<List<int>> startChunkedConversion(Sink<List<int>> sink) {
    return BrotliDecoderSink(options, sink);
  }
}

/// Chunked encoder sink: accumulates input and emits the compressed stream on
/// [close] (Brotli encoding needs the whole block to make decisions).
final class BrotliEncoderSink implements Sink<List<int>> {
  BrotliEncoderSink(this.options, this._sink);

  final BrotliEncodeOptions options;
  final Sink<List<int>> _sink;
  final BytesBuilder _input = BytesBuilder();
  bool _closed = false;

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('BrotliEncoderSink is closed');
    }
    _input.add(chunk);
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _sink.add(brotliCompress(_input.takeBytes(), options: options));
    _sink.close();
  }
}

/// Chunked decoder sink: feeds each chunk to a [BrotliDecoder] and emits every
/// available decompressed chunk immediately.
///
/// Errors from the decoder are rethrown from [add]/[close] and leave the
/// downstream sink open (the caller decides how to report the failure).
final class BrotliDecoderSink implements Sink<List<int>> {
  BrotliDecoderSink(this.options, this._sink)
    : _decoder = BrotliDecoder(options: options),
      _buffer = Uint8List(_decoderChunkSize);

  final BrotliDecodeOptions options;
  final Sink<List<int>> _sink;
  final BrotliDecoder _decoder;
  final Uint8List _buffer;
  bool _closed = false;
  bool _done = false;

  @override
  void add(List<int> chunk) {
    if (_closed) {
      throw StateError('BrotliDecoderSink is closed');
    }
    if (_done) {
      return; // streaming semantics: extra input after done is ignored
    }
    // The queue takes bytes by reference; copy because a converter input chunk
    // may be reused by the caller after `add` returns.
    _decoder.addInput(Uint8List.fromList(chunk));
    _pump();
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _decoder.closeInput();
    final status = _pump();
    if (status == BrotliStatus.needMoreInput) {
      throw StateError(
        'BrotliDecoder requested input after the stream was closed',
      );
    }
    if (!_done) {
      throw StateError('BrotliDecoder did not finish after closeInput');
    }
    _sink.close();
  }

  /// Pumps the decoder until it needs more input or finishes.
  BrotliStatus _pump() {
    while (true) {
      final status = _decoder.decode(_buffer);
      final written = _decoder.bytesWritten;
      if (written > 0) {
        _sink.add(_buffer.sublist(0, written));
      }
      if (status == BrotliStatus.done) {
        _done = true;
        return status;
      }
      if (status == BrotliStatus.needMoreInput) {
        return status;
      }
      if (written == 0) {
        // needMoreOutput without progress: the output buffer must grow.
        throw StateError('BrotliDecoder made no progress with output space');
      }
    }
  }
}

/// Decodes Brotli-compressed [input] as UTF-8.
String brotliDecompressToString(
  List<int> input, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
  bool allowMalformed = false,
}) {
  final bytes = input is Uint8List ? input : Uint8List.fromList(input);
  return utf8.decode(
    brotliDecompress(bytes, options: options),
    allowMalformed: allowMalformed,
  );
}

/// UTF-8-encodes [input] and compresses it.
Uint8List brotliCompressString(
  String input, {
  BrotliEncodeOptions options = const BrotliEncodeOptions(),
}) {
  return brotliCompress(
    Uint8List.fromList(utf8.encode(input)),
    options: options,
  );
}
