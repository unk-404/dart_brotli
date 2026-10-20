/// Public options and status types.
library;

import 'dart:typed_data';

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
/// [quality] is `0..11`; [lgwin] is `10..24` for RFC 7932 streams and `25..30`
/// when [largeWindow] is set (non-RFC large-window extension). Values outside
/// the accepted range are clamped, except `lgwin > 24` without [largeWindow],
/// which throws. [lgblock] is `0` (auto) or `16..24`.
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
    this.compoundDictionary,
  });

  /// Decompression-bomb guard; `null` means unlimited.
  final int? maxOutputSize;

  /// Flush output as soon as possible instead of waiting for the ring buffer.
  final bool eagerOutput;

  /// Accept the non-RFC large-window extension (lgwin 25..30).
  final bool allowLargeWindow;

  /// Optional caller-attached LZ77 compound ("shared" or "prepended")
  /// dictionary.
  ///
  /// This implements the non-RFC extension used by `brotli --dictionary` and
  /// the Rust `brotli`/`brotli-decompressor` crates: the dictionary bytes are
  /// treated as history immediately preceding the compressed stream. Distances
  /// in `(maxDistance, maxDistance + dictionary.length]` address it, furthest
  /// byte first; larger distances keep addressing the built-in RFC static
  /// dictionary, shifted by `dictionary.length`.
  ///
  /// The exact same dictionary the encoder used must be supplied. Brotli
  /// streams carry no dictionary identifier or checksum, so a wrong dictionary
  /// of the *same length* decodes successfully to different bytes; a dictionary
  /// of a different length (or a missing one) normally raises
  /// `BrotliException`. Streams that never use the dictionary decode
  /// identically with or without it.
  ///
  /// The bytes are read-only and not copied; do not mutate the buffer while a
  /// decode is in progress. `null` (the default) disables compound references.
  final Uint8List? compoundDictionary;
}
