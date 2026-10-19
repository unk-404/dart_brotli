/// Pure Dart Brotli (RFC 7932) encoder and decoder.
///
/// The primary API is blit-native: inputs are [BytesLike] and outputs are
/// [Bytes]. For a `Uint8List`/`List<int>` API, import `compat.dart`.
library;

export 'package:blit/bytes.dart' show Bytes, BytesLike, BytesMut;

export 'src/blit_api.dart';
export 'src/common/errors.dart';
export 'src/decoder/decoder.dart';
export 'src/encoder/encoder.dart';
export 'src/encoder/streaming_encoder.dart' show BrotliEncoder;
export 'src/options.dart';
