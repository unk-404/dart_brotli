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
Bytes brotliDecode(
  BytesLike input, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
}) {
  return Bytes.fromUint8List(
    brotliDecompress(input.asUint8List(), options: options),
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
