/// Streaming encoder entry point.
///
/// The implementation lives in `encoder.dart` next to the block writers it
/// shares with [brotliCompress]; this file only re-exports the public class.
library;

export 'encoder.dart' show BrotliEncoder;
