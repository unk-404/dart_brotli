/// Mutable decoder state, buffers and limits.
///
/// This is the Dart counterpart of `java/org/brotli/dec/State.java`. One
/// [DecoderState] lives for the whole stream; the compressed-block layer (D3)
/// keeps its working set here too so that no table or context-map buffer is
/// reallocated per metablock.
///
/// Field names follow the Java reference where the meaning is identical
/// (`pos`, `metaBlockLength`, `inputEnd`, `outputUsed`, ...), which keeps the
/// port auditable. Everything that counts bytes is an absolute value; only
/// [ringBufferSize] and [ringBufferMask] describe the ring buffer geometry.
///
/// Arithmetic stays in the portable 32-bit subset described in
/// `decoder-plan.md` §2: no `>>>`, no `~`, no shift by 32 or more.
library;

import 'dart:typed_data';

import '../common/format_tables.dart';
import 'shared_dictionary.dart';

/// Decoder phases; port of the `RunningState` enum in `Decode.java`.
///
/// Only the frame states are used by the D2 core; the compressed-block states
/// are declared here (and handled by D3) so the loop never has to change shape.
enum DecodePhase {
  /// Before the stream header is parsed.
  uninitialized,

  /// Window bits not read yet.
  initialized,

  /// Reads the next metablock header.
  blockStart,

  /// Reads Huffman codes, context maps and block types (D3).
  compressedBlockStart,

  /// Decodes commands (D3).
  mainLoop,

  /// Skips a metadata payload.
  readMetadata,

  /// Copies a raw (uncompressed) metablock.
  copyUncompressed,

  /// Resolves the distance of the command whose literals were just emitted
  /// (kept separate from [copyLoop] so a suspended distance read is idempotent).
  readDistance,

  /// Emits inserted literals (D3).
  insertLoop,

  /// Executes a backward copy (D3).
  copyLoop,

  /// Resolves a static/compound dictionary reference (D3).
  useDictionary,

  /// The stream ended cleanly.
  finished,

  /// `close()` was called.
  closed,

  /// Prepares a ring-buffer flush.
  initWrite,

  /// Flushes the ring buffer into the caller's output buffer.
  write,

  /// Copies from a compound dictionary (D3, optional).
  copyFromCompoundDictionary,
}

/// Ring-buffer slack: the longest transformed dictionary word.
///
/// The built-in RFC transforms need `5 + 24 + 8 = 37`, but a serialized shared
/// dictionary may define transforms with full-length affixes: 255-byte prefix
/// + 31-byte word (rounded up to 32) + 255-byte suffix = 542, matching
/// `kRingBufferWriteAheadSlack` in the reference C/Rust decoders.
const int maxTransformedWordLength = 542;

/// Hard cap applied to [DecoderState.expectedTotalSize] (Java: `1 << 30`).
const int maxExpectedTotalSize = 1 << 30;

/// RFC 7932 maximum metablock length (`1 << 24`).
const int maxMetaBlockLength = 1 << 24;

/// Minimum ring-buffer size while more metablocks may follow (Java: `16384`).
const int minRingBufferSize = 16384;

/// Reusable decoder state: window geometry, ring buffer, metablock cursor,
/// output cursor and the scalar working set of the compressed-block layer.
final class DecoderState {
  DecoderState({
    this.allowLargeWindow = false,
    this.eagerOutput = true,
    this.maxOutputSize,
    Uint8List? compoundDictionary,
    this.sharedDictionary,
  }) : compoundDictionary = compoundDictionary ?? Uint8List(0) {
    // Most-recent-first distance ring, exactly as Java's State constructor.
    rings[0] = 16;
    rings[1] = 15;
    rings[2] = 11;
    rings[3] = 4;
    // Block-type rings are re-initialised by the compressed header (D3).
    rings[4] = 1;
    rings[6] = 1;
    rings[8] = 1;
  }

  // ---------------------------------------------------------------------------
  // Configuration (immutable for the lifetime of a stream).
  // ---------------------------------------------------------------------------

  /// Accept the non-RFC large-window extension (window bits 25..30).
  final bool allowLargeWindow;

  /// Flush the ring buffer as soon as the caller's output buffer fills.
  ///
  /// Kept here (rather than in the core) because [calculateFence] is consulted
  /// by the D3 hot loops.
  final bool eagerOutput;

  /// Decompression-bomb guard, enforced when bytes leave the ring buffer.
  ///
  /// `null` means unlimited.
  final int? maxOutputSize;

  /// Caller-attached LZ77 compound ("shared") dictionary; never empty when read.
  ///
  /// The bytes are treated as history immediately preceding the stream (the
  /// non-RFC `brotli --dictionary` extension). `Uint8List(0)` means "no
  /// dictionary attached" and is bit-identical to the RFC-only path.
  final Uint8List compoundDictionary;

  /// Number of bytes in [compoundDictionary].
  int get compoundDictionarySize => compoundDictionary.length;

  /// Custom word/transform lists from an attached serialized shared
  /// dictionary; `null` when none is attached (the built-in static dictionary
  /// is used). The embedded LZ77 prefix, if any, has already been merged into
  /// [compoundDictionary].
  final SharedDictionary? sharedDictionary;

  // ---------------------------------------------------------------------------
  // State machine.
  // ---------------------------------------------------------------------------

  DecodePhase phase = DecodePhase.uninitialized;

  /// State to enter after [DecodePhase.write] completes.
  DecodePhase nextPhase = DecodePhase.uninitialized;

  // ---------------------------------------------------------------------------
  // Stream header.
  // ---------------------------------------------------------------------------

  /// Effective window bits (`10..24`, or `10..30` in large-window mode).
  int windowBits = 0;

  /// Whether the stream opted into the large-window extension.
  bool largeWindow = false;

  /// `1 << windowBits`.
  int maxRingBufferSize = 0;

  /// `maxRingBufferSize - 16` (RFC backward-distance limit).
  int maxBackwardDistance = 0;

  // ---------------------------------------------------------------------------
  // Ring buffer.
  // ---------------------------------------------------------------------------

  /// Ring buffer followed by [maxTransformedWordLength] bytes of slack.
  ///
  /// The first [ringBufferSize] bytes are the window proper; the tail is
  /// scratch space for dictionary-word transforms.
  Uint8List ringBuffer = Uint8List(0);

  /// Power-of-two window size in bytes (`0` until the first reallocation).
  int ringBufferSize = 0;

  /// Write cursor inside the window; may exceed [ringBufferSize] by at most
  /// [maxTransformedWordLength] before the next flush.
  int pos = 0;

  /// Mask that maps [pos] back into the window; only valid when
  /// `ringBufferSize > 0`.
  int get ringBufferMask => ringBufferSize - 1;

  /// Extra bytes allocated after the window (should be
  /// [maxTransformedWordLength]).
  int get ringBufferSlack => ringBuffer.length - ringBufferSize;

  // ---------------------------------------------------------------------------
  // Metablock header cursor.
  // ---------------------------------------------------------------------------

  /// Bytes still to decode in the current metablock (`0` between blocks).
  int metaBlockLength = 0;

  /// ISLAST bit of the last metablock header (`0` or `1`).
  int inputEnd = 0;

  /// ISUNCOMPRESSED bit of the last metablock header.
  bool isUncompressed = false;

  /// Whether the current metablock is metadata (MNIBBLES == 7).
  bool isMetadata = false;

  /// Sum of all non-metadata metablock lengths, capped at [maxExpectedTotalSize].
  int expectedTotalSize = 0;

  // ---------------------------------------------------------------------------
  // Output cursor (valid only while a decode call is in progress).
  // ---------------------------------------------------------------------------

  /// Caller-owned output buffer for the current call.
  Uint8List output = Uint8List(0);

  /// First writable index in [output].
  int outputOffset = 0;

  /// One past the last writable index in [output].
  int outputLength = 0;

  /// Next free index in [output]; starts at [outputOffset] on every call.
  int outputUsed = 0;

  /// Bytes of the ring buffer that are ready to be flushed.
  int ringBufferBytesReady = 0;

  /// Bytes already flushed from the current ring-buffer cycle.
  int ringBufferBytesWritten = 0;

  /// Total bytes handed to the caller across all decode calls.
  int totalOutput = 0;

  /// Writable bytes left in the current output buffer.
  int get outputAvailable => outputLength - outputUsed;

  /// Bytes produced by the current decode call (valid after it returns).
  int get bytesWritten => outputUsed - outputOffset;

  // ---------------------------------------------------------------------------
  // Compressed-metablock working set (filled in by D3).
  // ---------------------------------------------------------------------------

  /// Distance ring: indices `0..3` are distances, `4..9` the block-type rings.
  final Int32List rings = Int32List(10);

  /// Current index into the distance ring (Java starts at 3).
  int distRbIdx = 3;

  /// `min(pos, maxBackwardDistance)` as of the last flush (D3).
  int maxDistance = 0;

  /// Number of literal / command / distance block types in this metablock.
  int numLiteralBlockTypes = 0;
  int numCommandBlockTypes = 0;
  int numDistanceBlockTypes = 0;

  /// Remaining symbols in the current literal / command / distance block.
  int literalBlockLength = 0;
  int commandBlockLength = 0;
  int distanceBlockLength = 0;

  /// Huffman block trees: `(type tree, length tree)` pairs, plus one slot.
  ///
  /// Sized by D3 on first use; kept here so it survives metablocks.
  Uint32List blockTrees = Uint32List(0);

  /// Reusable Huffman table groups (D3); grown, never allocated per metablock.
  Uint32List literalTreeGroup = Uint32List(0);
  Uint32List commandTreeGroup = Uint32List(0);
  Uint32List distanceTreeGroup = Uint32List(0);

  /// Number of distance trees for the current metablock (from the context map).
  int numLiteralTrees = 0;
  int numDistTrees = 0;

  /// Distance alphabet limit for the current metablock
  /// (`16 + ndirect + 2 * (24 << npostfix)`; ≤ 544 for RFC streams).
  int distanceAlphabetSizeLimit = 0;

  /// Distance alphabet size before limiting. Larger than
  /// [distanceAlphabetSizeLimit] only for large-window streams (62 distance
  /// extra bits); used purely as the simple-code field width.
  int distanceAlphabetSizeMax = 0;

  /// Distance prefix-code parameters and lookup tables.
  int distancePostfixBits = 0;
  int numDirectDistanceCodes = 0;
  Uint8List distExtraBits = Uint8List(0);
  Int32List distOffset = Int32List(0);

  /// Per-literal-block-type context modes and the two context maps.
  Uint8List contextModes = Uint8List(0);
  Uint8List contextMap = Uint8List(0);
  Uint8List distContextMap = Uint8List(0);

  /// Scratch Huffman table for context-map symbol decoding, plus MTF scratch.
  Uint32List contextMapTable = Uint32List(0);
  Int32List mtf = Int32List(256);

  /// Active block / tree cursors for the hot loops.
  int literalTreeIdx = 0;
  int commandTreeIdx = 0;
  int contextMapSlice = 0;
  int distContextMapSlice = 0;
  int contextLookupOffset1 = 0;
  int contextLookupOffset2 = 0;

  /// True when the literal context map degenerates to "tree == block type".
  bool trivialLiteralContext = false;

  /// Command cursor: insert/copy lengths and progress.
  int insertLength = 0;
  int copyLength = 0;
  int j = 0;

  /// Resolved copy distance and how it was encoded.
  int distance = 0;

  /// `true` when the command carries no explicit distance symbol (the most
  /// recent ring-buffer distance is reused). Replaces Java's negative
  /// `distanceCode` sentinel so no negative value is ever shifted or masked.
  bool implicitDistance = false;

  /// Distance context (`0..3`) of the current command; selects the distance
  /// tree through [distContextMap].
  int distanceContext = 0;

  /// Number of static-dictionary references decoded so far (diagnostics,
  /// dictionary-coverage assertions and the D5 summary).
  int dictionaryReferenceCount = 0;

  /// Number of compound-dictionary references decoded so far (diagnostics).
  int compoundDictionaryReferenceCount = 0;

  /// Next byte of [compoundDictionary] for the active reference, or `-1` when
  /// no compound copy is in progress.
  int compoundDictionaryOffset = -1;

  /// Bytes still to copy from [compoundDictionary] for the active reference.
  int compoundDictionaryRemaining = 0;

  /// Compressed-metablock header parser state (resumable across input refills).
  int headerStep = 0;
  int headerIndex = 0;
  int headerNext = 0;

  /// Context-map parser state (resumable across input refills).
  int contextMapSize = 0;
  int contextMapNumTrees = 0;
  int contextMapIndex = 0;
  int contextMapMaxRunPrefix = 0;
  int contextMapTableIndex = 0;

  /// Ensures [blockTrees] is large enough for all three block-tree pairs.
  ///
  /// The pool is allocated once (Java's `7 + 3 * (632 + 396)` with the
  /// conservative per-alphabet table bound) and reused by every metablock.
  void ensureBlockTrees() {
    final required =
        7 + 3 * (huffmanTableSizeLimit(258) + huffmanTableSizeLimit(26));
    if (blockTrees.length >= required) {
      return;
    }
    blockTrees = Uint32List(required);
    blockTrees[0] = 7;
  }

  // ---------------------------------------------------------------------------
  // Ring-buffer management.
  // ---------------------------------------------------------------------------

  /// Grows the ring buffer for the current [expectedTotalSize].
  ///
  /// This is a literal port of `Decode.maybeReallocateRingBuffer`: the Java
  /// decoder may pick a window *smaller* than `1 << windowBits`, which is safe
  /// because [expectedTotalSize] is a lower bound on the bytes that will be
  /// written before the buffer would wrap. The allocation is only ever grown,
  /// so a metablock never reallocates it; [maxTransformedWordLength] bytes of
  /// slack are always appended.
  void maybeReallocateRingBuffer() {
    var newSize = maxRingBufferSize;
    if (newSize > expectedTotalSize) {
      final minimalNewSize = expectedTotalSize;
      while ((newSize >> 1) > minimalNewSize) {
        newSize = newSize >> 1;
      }
      if (inputEnd == 0 &&
          newSize < minRingBufferSize &&
          maxRingBufferSize >= minRingBufferSize) {
        newSize = minRingBufferSize;
      }
    }
    if (newSize <= ringBufferSize) {
      return;
    }
    final buffer = Uint8List(newSize + maxTransformedWordLength);
    if (ringBufferSize > 0) {
      buffer.setRange(0, ringBufferSize, ringBuffer);
    }
    ringBuffer = buffer;
    ringBufferSize = newSize;
  }

  /// Ring-buffer position that should trigger a flush.
  ///
  /// Port of `Decode.calculateFence`. Non-eager mode fills the whole window;
  /// eager mode stops as soon as the caller's current output buffer would
  /// fill, so decoded bytes reach the caller sooner.
  int calculateFence() {
    var fence = ringBufferSize;
    if (eagerOutput) {
      final eager = ringBufferBytesWritten + outputLength - outputUsed;
      if (eager < fence) {
        fence = eager;
      }
    }
    return fence;
  }
}
