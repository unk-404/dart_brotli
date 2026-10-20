/// blit-native public API.
///
/// Inputs accept any [BytesLike] (including [Bytes] and [BytesMut]); outputs
/// are zero-copy [Bytes] views. The actual encode/decode implementations are
/// reached through the Compat core for now and will use `BytesMutSink` once
/// the codec lands.
library;

import 'package:blit/bytes.dart';

import 'decoder/decoder.dart';
import 'encoder/encoder.dart';
import 'options.dart';

/// Decodes one complete Brotli stream, returning a zero-copy [Bytes] view.
///
/// [compoundDictionary] attaches the non-RFC caller-provided LZ77 dictionary
/// (`brotli --dictionary`) that was used to produce the stream; it overrides
/// [BrotliDecodeOptions.compoundDictionary] when both are given.
Bytes brotliDecode(
  BytesLike input, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
  BytesLike? compoundDictionary,
}) {
  final decodeOptions = compoundDictionary == null
      ? options
      : BrotliDecodeOptions(
          maxOutputSize: options.maxOutputSize,
          eagerOutput: options.eagerOutput,
          allowLargeWindow: options.allowLargeWindow,
          compoundDictionary: compoundDictionary.asUint8List(),
        );
  return Bytes.fromUint8List(
    brotliDecompress(input.asUint8List(), options: decodeOptions),
  );
}

/// Encodes one complete buffer, returning a zero-copy [Bytes] view.
Bytes brotliEncode(
  BytesLike input, {
  BrotliEncodeOptions options = const BrotliEncodeOptions(),
}) {
  return Bytes.fromUint8List(
    brotliCompress(input.asUint8List(), options: options),
  );
}
