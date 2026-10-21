/// Pure Dart Brotli (RFC 7932) encoder and decoder.
///
/// The legacy API is blit-native. The v0.2.0 performance API
/// ([BrotliEncoderV2]/[BrotliDecoderV2]) is exported here as well and uses raw
/// `Uint8List` buffers; `compat.dart` exposes both surfaces.
library;

export 'package:blit/bytes.dart' show Bytes, BytesLike, BytesMut;

export 'src/blit_api.dart';
export 'src/common/errors.dart';
export 'src/decoder/decoder.dart';
export 'src/encoder/encoder.dart';
export 'src/encoder/prepared_dictionary.dart' show BrotliPreparedDictionary;
export 'src/encoder/streaming_encoder.dart' show BrotliEncoder;
export 'src/options.dart';
export 'src/v2/decoder/decoder_v2.dart';
export 'src/v2/encoder/encoder_v2.dart';
