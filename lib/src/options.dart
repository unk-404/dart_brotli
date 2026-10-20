/// Public options and status types.
library;

import 'dart:typed_data';

import 'encoder/prepared_dictionary.dart';

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
    this.compoundDictionary,
    this.preparedDictionary,
  });

  final int quality;
  final int lgwin;
  final int lgblock;
  final BrotliMode mode;
  final int? sizeHint;

  /// Non-RFC large-window streams (lgwin 25..30). Off by default.
  final bool largeWindow;

  /// Caller-provided LZ77 dictionary (the `brotli --dictionary` extension).
  ///
  /// The encoder may encode input spans that occur in this buffer as
  /// dictionary references; the decoder must be given the same bytes through
  /// [BrotliDecodeOptions.compoundDictionary] to decode the stream.
  /// `null` (the default) disables compound-dictionary matching.
  final Uint8List? compoundDictionary;

  /// A pre-indexed compound dictionary (takes precedence over
  /// [compoundDictionary]).
  final BrotliPreparedDictionary? preparedDictionary;
}

/// Decoder options.
final class BrotliDecodeOptions {
  const BrotliDecodeOptions({
    this.maxOutputSize = 1 << 30,
    this.eagerOutput = true,
    this.allowLargeWindow = false,
    this.compoundDictionary,
    this.preparedDictionary,
    this.sharedDictionary,
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

  /// A pre-indexed compound dictionary (takes precedence over
  /// [compoundDictionary]).
  ///
  /// Only meaningful to the encoder; the decoder ignores it (give the raw bytes
  /// through [compoundDictionary]). Kept here so one options object can be
  /// shared by both directions.
  final BrotliPreparedDictionary? preparedDictionary;

  /// Optional serialized shared dictionary
  /// (`draft-vandevenne-shared-brotli-format`, magic `0x91 0x00`).
  ///
  /// This is the non-RFC extension consumed by `brotli --dictionary` shared
  /// dictionaries. The container may carry:
  ///
  /// * an LZ77 prefix chunk, which is appended to the compound-dictionary
  ///   address space (after [compoundDictionary]); and/or
  /// * custom word lists and transform lists, which replace the built-in
  ///   RFC 7932 static dictionary, optionally selected per literal context
  ///   through a 64-entry context map.
  ///
  /// Malformed bytes raise [BrotliException] when the decoder is created.
  /// The bytes are read-only and not copied; word/transform views point into
  /// this buffer for the whole decode, so do not modify it. `null` (the
  /// default) disables serialized shared dictionaries.
  final Uint8List? sharedDictionary;
}
