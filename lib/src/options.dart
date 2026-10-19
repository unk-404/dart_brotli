/// Public options and status types.
library;

/// Brotli encoder mode.
enum BrotliMode { generic, text, font }

/// Streaming decoder status.
enum BrotliStatus {
  /// The decoder needs more input; all provided input has been consumed.
  needMoreInput,

  /// The output buffer is full; call again with more space.
  needMoreOutput,

  /// The stream ended cleanly.
  done,
}

/// Encoder options.
///
/// [quality] is `0..11`; [lgwin] is `10..24` for RFC 7932 streams. [lgblock]
/// is `0` (auto) or `16..24`. The encoder normalizes out-of-range values.
final class BrotliEncodeOptions {
  const BrotliEncodeOptions({
    this.quality = 5,
    this.lgwin = 22,
    this.lgblock = 0,
    this.mode = BrotliMode.generic,
    this.sizeHint,
    this.largeWindow = false,
  });

  final int quality;
  final int lgwin;
  final int lgblock;
  final BrotliMode mode;
  final int? sizeHint;

  /// Non-RFC large-window streams (lgwin 25..30). Off by default.
  final bool largeWindow;
}

/// Decoder options.
final class BrotliDecodeOptions {
  const BrotliDecodeOptions({
    this.maxOutputSize = 1 << 30,
    this.eagerOutput = true,
    this.allowLargeWindow = false,
  });

  /// Decompression-bomb guard; `null` means unlimited.
  final int? maxOutputSize;

  /// Flush output as soon as possible instead of waiting for the ring buffer.
  final bool eagerOutput;

  /// Accept the non-RFC large-window extension (lgwin 25..30).
  final bool allowLargeWindow;
}
