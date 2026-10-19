/// Compat API: `Uint8List`/`List<int>` entry points.
///
/// This layer does not expose blit types, so callers can migrate from
/// `package:brotli`-style APIs without importing `package:blit`.
library;

export 'src/common/errors.dart';
export 'src/compat/codec.dart';
export 'src/decoder/decoder.dart'
    show BrotliDecoder, BytesInputQueue, brotliDecompress;
export 'src/encoder/encoder.dart' show brotliCompress, maxCompressedSize;
export 'src/options.dart';
