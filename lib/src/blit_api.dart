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
///
/// [sharedDictionary] attaches a serialized shared dictionary
/// (`draft-vandevenne-shared-brotli-format`); it overrides
/// [BrotliDecodeOptions.sharedDictionary].
Bytes brotliDecode(
  BytesLike input, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
  BytesLike? compoundDictionary,
  BytesLike? sharedDictionary,
}) {
  final decodeOptions = compoundDictionary == null && sharedDictionary == null
      ? options
      : BrotliDecodeOptions(
          maxOutputSize: options.maxOutputSize,
          eagerOutput: options.eagerOutput,
          allowLargeWindow: options.allowLargeWindow,
          compoundDictionary:
              compoundDictionary?.asUint8List() ?? options.compoundDictionary,
          preparedDictionary: options.preparedDictionary,
          sharedDictionary:
              sharedDictionary?.asUint8List() ?? options.sharedDictionary,
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
