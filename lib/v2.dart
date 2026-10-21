/// v0.2.0 performance API.
///
/// Raw `Uint8List` entry points with preallocated-output variants:
///
/// ```dart
/// final compressed = BrotliEncoderV2.encode(raw);
/// final roundTrip = BrotliDecoderV2.decode(compressed);
/// ```
///
/// The legacy blit-native and compat APIs remain available from
/// `package:brotli_neo/brotli_neo.dart` and `package:brotli_neo/compat.dart`
/// during the migration; they are not on the v2 hot path.
library;

export 'src/common/errors.dart';
export 'src/options.dart';
export 'src/v2/decoder/decoder_v2.dart';
export 'src/v2/encoder/encoder_v2.dart';
