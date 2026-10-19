/// Compressed-metablock decoder (D3).
///
/// Port of the compressed-block parts of `Decode.java`:
/// `readMetablockHuffmanCodesAndContextMaps`, `decodeContextMap`,
/// `decodeBlockTypeAndLength`, the literal/command/distance block switches,
/// `decodeVarLenUnsignedByte`, `calculateDistanceLut`, `doUseDictionary` and the
/// main/insert/copy loops of `decompress`.
///
/// Structure:
///
/// * The header parser is a *resumable step machine* ([DecoderState.headerStep])
///   rather than one big memento. Only a single Huffman code description is
///   ever wrapped in a [BitReaderMemento], because that is the only D1 operation
///   that can consume bits and then fail. Context-map RLE decoding, context
///   modes and the tree-group loops keep their cursors in [DecoderState] and
///   call `refill()` at the top of each loop, so a header of any size can be
///   suspended and restarted.
/// * The hot loops (`mainLoop`, `insertLoop`, `readDistance`, `copyLoop`)
///   follow Java's state machine, but distance resolution lives in its own
///   phase so that suspending there cannot repeat the metablock accounting.
/// * Every loop flushes through [DecodePhase.initWrite] / [DecodePhase.write]
///   when `pos >= fence`, exactly like the reference.
///
/// The static dictionary is D4: a distance larger than `maxDistance` is
/// resolved through the RFC 7932 dictionary and its 121 transforms below
/// ([_applyDictionaryReference]). Compound (caller-attached) dictionaries are
/// not supported.
library;

import 'dart:typed_data';

import '../common/context_lookup.dart';
import '../common/dictionary.dart' as dictionary;
import '../common/dictionary_data.dart'
    show kDictionaryData, kDictionarySizeBitsByLength;
import '../common/errors.dart';
import '../common/format_tables.dart';
import '../common/transforms.dart' as transforms;
import '../options.dart';
import 'bit_reader.dart';
import 'decoder_state.dart';
import 'huffman_decoder.dart';

// ---------------------------------------------------------------------------
// Entry points used by the D2 state machine.
// ---------------------------------------------------------------------------

/// Shortest static-dictionary word (`sizeBits[4] != 0`).
const int minDictionaryWordLength = 4;

/// Longest static-dictionary word.
const int maxDictionaryWordLength = 24;

/// Number of RFC 7932 word transforms.
const int numRfcTransforms = 121;

/// Parses the compressed-metablock header and sets [DecoderState.phase] to
/// [DecodePhase.mainLoop] on success.
///
/// Returns [BrotliStatus.needMoreInput] when the reader must be refilled; the
/// parser is fully resumable, so the caller can simply call again later.
BrotliStatus? decodeCompressedMetablockHeader(
  BitReader reader,
  DecoderState state,
) {
  for (;;) {
    switch (state.headerStep) {
      // -- NBLTYPES / block type + block length trees (three partitions) -----
      case 0:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.ensureBlockTrees();
        state.blockTrees[0] = 7;
        state.numLiteralBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerNext = 7;
        state.headerStep = 1;
        break;

      case 1:
        if (state.numLiteralBlockTypes <= 1) {
          state.blockTrees[1] = state.blockTrees[0];
          state.blockTrees[2] = state.blockTrees[0];
          state.literalBlockLength = 1 << 28;
          state.headerStep = 4;
          break;
        }
        final literalAlphabet = state.numLiteralBlockTypes + 2;
        final literalTypeUsed = _tryHuffmanCode(
          reader,
          literalAlphabet,
          literalAlphabet,
          state.blockTrees,
          0,
        );
        if (literalTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalTypeUsed;
        state.blockTrees[1] = state.headerNext;
        state.headerStep = 2;
        break;

      case 2:
        final literalLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          1,
        );
        if (literalLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalLengthUsed;
        state.blockTrees[2] = state.headerNext;
        state.headerStep = 3;
        break;

      case 3:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.literalBlockLength = readBlockLength(state.blockTrees, 1, reader);
        state.headerStep = 4;
        break;

      case 4:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.numCommandBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerStep = 5;
        break;

      case 5:
        if (state.numCommandBlockTypes <= 1) {
          state.blockTrees[3] = state.blockTrees[2];
          state.blockTrees[4] = state.blockTrees[2];
          state.commandBlockLength = 1 << 28;
          state.headerStep = 8;
          break;
        }
        final commandAlphabet = state.numCommandBlockTypes + 2;
        final commandTypeUsed = _tryHuffmanCode(
          reader,
          commandAlphabet,
          commandAlphabet,
          state.blockTrees,
          2,
        );
        if (commandTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext = state.blockTrees[2] + commandTypeUsed;
        state.blockTrees[3] = state.headerNext;
        state.headerStep = 6;
        break;

      case 6:
        final commandLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          3,
        );
        if (commandLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += commandLengthUsed;
        state.blockTrees[4] = state.headerNext;
        state.headerStep = 7;
        break;

      case 7:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.commandBlockLength = readBlockLength(state.blockTrees, 3, reader);
        state.headerStep = 8;
        break;

      case 8:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.numDistanceBlockTypes = _readVarLenUnsignedByte(reader) + 1;
        state.headerStep = 9;
        break;

      case 9:
        if (state.numDistanceBlockTypes <= 1) {
          state.blockTrees[5] = state.blockTrees[4];
          state.blockTrees[6] = state.blockTrees[4];
          state.distanceBlockLength = 1 << 28;
          state.headerStep = 12;
          break;
        }
        final distanceAlphabet = state.numDistanceBlockTypes + 2;
        final distanceTypeUsed = _tryHuffmanCode(
          reader,
          distanceAlphabet,
          distanceAlphabet,
          state.blockTrees,
          4,
        );
        if (distanceTypeUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext = state.blockTrees[4] + distanceTypeUsed;
        state.blockTrees[5] = state.headerNext;
        state.headerStep = 10;
        break;

      case 10:
        final distanceLengthUsed = _tryHuffmanCode(
          reader,
          numBlockLengthCodes,
          numBlockLengthCodes,
          state.blockTrees,
          5,
        );
        if (distanceLengthUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += distanceLengthUsed;
        state.blockTrees[6] = state.headerNext;
        state.headerStep = 11;
        break;

      case 11:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        state.distanceBlockLength = readBlockLength(
          state.blockTrees,
          5,
          reader,
        );
        state.headerStep = 12;
        break;

      // -- distance parameters ----------------------------------------------
      case 12:
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        reader.fillBitWindow();
        state.distancePostfixBits = reader.readFewBits(2);
        state.numDirectDistanceCodes =
            reader.readFewBits(4) << state.distancePostfixBits;
        state.headerStep = 13;
        break;

      // -- literal context modes --------------------------------------------
      case 13:
        final contextModeCount = state.numLiteralBlockTypes;
        if (state.contextModes.length < contextModeCount) {
          state.contextModes = Uint8List(contextModeCount);
        }
        state.headerIndex = 0;
        state.headerStep = 14;
        break;

      case 14:
        if (state.headerIndex >= state.numLiteralBlockTypes) {
          state.headerStep = 15;
          break;
        }
        if (!reader.refill()) {
          return BrotliStatus.needMoreInput;
        }
        final modeLimit = _min(
          state.headerIndex + 96,
          state.numLiteralBlockTypes,
        );
        while (state.headerIndex < modeLimit) {
          reader.fillBitWindow();
          state.contextModes[state.headerIndex] = reader.readFewBits(2);
          state.headerIndex++;
        }
        break;

      // -- literal context map ----------------------------------------------
      case 15:
        final startStatus = _startContextMap(reader, state, false);
        if (startStatus != null) {
          return startStatus;
        }
        if (state.contextMapNumTrees == 1) {
          state.numLiteralTrees = 1;
          state.headerStep = 20;
        } else {
          state.headerStep = 19;
        }
        break;

      case 19:
        // Zero-RLE parameters are read in their own step so a suspension while
        // reading the context-map Huffman code (step 16) can be retried without
        // re-reading these bits.
        final rleStatus = _readContextMapRleParams(reader, state);
        if (rleStatus != null) {
          return rleStatus;
        }
        state.headerStep = 16;
        break;

      case 16:
        final treeStatus = _readContextMapTree(reader, state);
        if (treeStatus != null) {
          return treeStatus;
        }
        state.headerStep = 17;
        break;

      case 17:
        final symbolStatus = _readContextMapSymbols(reader, state, false);
        if (symbolStatus != null) {
          return symbolStatus;
        }
        state.headerStep = 18;
        break;

      case 18:
        final finishStatus = _finishContextMap(reader, state, false);
        if (finishStatus != null) {
          return finishStatus;
        }
        state.numLiteralTrees = state.contextMapNumTrees;
        state.trivialLiteralContext = true;
        final literalMapSize = state.contextMapSize;
        for (var i = 0; i < literalMapSize; i++) {
          if ((state.contextMap[i] & 0xFF) != (i >> numLiteralContextBits)) {
            state.trivialLiteralContext = false;
            break;
          }
        }
        state.headerStep = 20;
        break;

      // -- distance context map ---------------------------------------------
      case 20:
        final startStatus = _startContextMap(reader, state, true);
        if (startStatus != null) {
          return startStatus;
        }
        if (state.contextMapNumTrees == 1) {
          state.numDistTrees = 1;
          state.headerStep = 25;
        } else {
          state.headerStep = 24;
        }
        break;

      case 24:
        final rleStatus = _readContextMapRleParams(reader, state);
        if (rleStatus != null) {
          return rleStatus;
        }
        state.headerStep = 21;
        break;

      case 21:
        final treeStatus = _readContextMapTree(reader, state);
        if (treeStatus != null) {
          return treeStatus;
        }
        state.headerStep = 22;
        break;

      case 22:
        final symbolStatus = _readContextMapSymbols(reader, state, true);
        if (symbolStatus != null) {
          return symbolStatus;
        }
        state.headerStep = 23;
        break;

      case 23:
        final finishStatus = _finishContextMap(reader, state, true);
        if (finishStatus != null) {
          return finishStatus;
        }
        state.numDistTrees = state.contextMapNumTrees;
        state.headerStep = 25;
        break;

      // -- three Huffman tree groups ----------------------------------------
      case 25:
        var distanceAlphabetSizeMax = distanceAlphabetSize(
          state.distancePostfixBits,
          state.numDirectDistanceCodes,
          maxDistanceBits,
        );
        var distanceLimit = distanceAlphabetSizeMax;
        if (state.largeWindow) {
          // Large-window streams may encode up to 62 distance extra bits; only
          // the codes that MAX_ALLOWED_DISTANCE can reach are actually used.
          distanceAlphabetSizeMax = distanceAlphabetSize(
            state.distancePostfixBits,
            state.numDirectDistanceCodes,
            maxLargeWindowDistanceBits,
          );
          final computed = distanceAlphabetLimit(
            maxAllowedDistance,
            state.distancePostfixBits,
            state.numDirectDistanceCodes,
          );
          if (computed < 0) {
            throw BrotliException(
              BrotliErrorCode.internalError,
              'maximum backward distance is too small for the distance alphabet',
            );
          }
          distanceLimit = computed;
        }
        state.distanceAlphabetSizeMax = distanceAlphabetSizeMax;
        state.distanceAlphabetSizeLimit = distanceLimit;
        state.distExtraBits = _ensureBytes(
          state.distExtraBits,
          state.distanceAlphabetSizeLimit,
        );
        state.distOffset = _ensureInt32(
          state.distOffset,
          state.distanceAlphabetSizeLimit,
        );
        state.literalTreeGroup = _ensureUint32(
          state.literalTreeGroup,
          _treeGroupLength(numLiteralCodes, state.numLiteralTrees),
        );
        state.headerIndex = 0;
        state.headerNext = state.numLiteralTrees;
        state.headerStep = 26;
        break;

      case 26:
        if (state.headerIndex >= state.numLiteralTrees) {
          state.commandTreeGroup = _ensureUint32(
            state.commandTreeGroup,
            _treeGroupLength(numCommandCodes, state.numCommandBlockTypes),
          );
          state.headerIndex = 0;
          state.headerNext = state.numCommandBlockTypes;
          state.headerStep = 27;
          break;
        }
        final literalIndex = state.headerIndex;
        state.literalTreeGroup[literalIndex] = state.headerNext;
        final literalUsed = _tryHuffmanCode(
          reader,
          numLiteralCodes,
          numLiteralCodes,
          state.literalTreeGroup,
          literalIndex,
        );
        if (literalUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += literalUsed;
        state.headerIndex = literalIndex + 1;
        break;

      case 27:
        if (state.headerIndex >= state.numCommandBlockTypes) {
          state.distanceTreeGroup = _ensureUint32(
            state.distanceTreeGroup,
            _treeGroupLength(
              state.distanceAlphabetSizeLimit,
              state.numDistTrees,
            ),
          );
          state.headerIndex = 0;
          state.headerNext = state.numDistTrees;
          state.headerStep = 28;
          break;
        }
        final commandIndex = state.headerIndex;
        state.commandTreeGroup[commandIndex] = state.headerNext;
        final commandUsed = _tryHuffmanCode(
          reader,
          numCommandCodes,
          numCommandCodes,
          state.commandTreeGroup,
          commandIndex,
        );
        if (commandUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += commandUsed;
        state.headerIndex = commandIndex + 1;
        break;

      case 28:
        if (state.headerIndex >= state.numDistTrees) {
          state.headerStep = 29;
          break;
        }
        final distanceIndex = state.headerIndex;
        state.distanceTreeGroup[distanceIndex] = state.headerNext;
        final distanceUsed = _tryHuffmanCode(
          reader,
          state.distanceAlphabetSizeMax,
          state.distanceAlphabetSizeLimit,
          state.distanceTreeGroup,
          distanceIndex,
        );
        if (distanceUsed == null) {
          return BrotliStatus.needMoreInput;
        }
        state.headerNext += distanceUsed;
        state.headerIndex = distanceIndex + 1;
        break;

      case 29:
        _fillDistanceLut(state);
        state.contextMapSlice = 0;
        state.distContextMapSlice = 0;
        state.contextLookupOffset1 = (state.contextModes[0] & 0xFF) << 9;
        state.contextLookupOffset2 = state.contextLookupOffset1 + 256;
        state.literalTreeIdx = 0;
        state.commandTreeIdx = 0;
        state.rings[4] = 1;
        state.rings[5] = 0;
        state.rings[6] = 1;
        state.rings[7] = 0;
        state.rings[8] = 1;
        state.rings[9] = 0;
        state.headerStep = 0;
        state.phase = DecodePhase.mainLoop;
        return null;

      default:
        throw BrotliException(
          BrotliErrorCode.internalError,
          'unexpected compressed-header step ${state.headerStep}',
        );
    }
  }
}

/// Decodes one command and switches to the literal insertion phase.
BrotliStatus? decodeMainLoop(BitReader reader, DecoderState state) {
  if (state.metaBlockLength <= 0) {
    state.phase = DecodePhase.blockStart;
    return null;
  }
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  if (state.commandBlockLength == 0) {
    state.commandBlockLength = _decodeBlockTypeAndLength(
      reader,
      state,
      1,
      state.numCommandBlockTypes,
    );
    state.commandTreeIdx = state.rings[7];
  }
  state.commandBlockLength--;

  reader.fillBitWindow();
  final commandCode =
      readSymbol(state.commandTreeGroup, state.commandTreeIdx, reader) << 2;
  final extraBitsPacked = commandLookup[commandCode];
  final insertLengthOffset = commandLookup[commandCode + 1];
  final copyLengthOffset = commandLookup[commandCode + 2];
  final distanceContext = commandLookup[commandCode + 3];

  reader.fillBitWindow();
  state.insertLength =
      insertLengthOffset + reader.readBits(extraBitsPacked & 0xFF);
  reader.fillBitWindow();
  state.copyLength = copyLengthOffset + reader.readBits(extraBitsPacked >> 8);

  state.implicitDistance = distanceContext < 0;
  state.distanceContext = state.implicitDistance ? 0 : distanceContext;
  state.j = 0;
  state.phase = DecodePhase.insertLoop;
  return null;
}

/// Emits the inserted literals of the current command.
BrotliStatus? decodeInsertLoop(BitReader reader, DecoderState state) {
  final fence = state.calculateFence();
  if (state.trivialLiteralContext) {
    while (state.j < state.insertLength) {
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (state.literalBlockLength == 0) {
        _literalBlockSwitch(reader, state);
      }
      state.literalBlockLength--;
      reader.fillBitWindow();
      state.ringBuffer[state.pos] = readSymbol(
        state.literalTreeGroup,
        state.literalTreeIdx,
        reader,
      );
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.insertLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  } else {
    final ring = state.ringBuffer;
    final mask = state.ringBufferMask;
    var prevByte1 = ring[(state.pos - 1) & mask] & 0xFF;
    var prevByte2 = ring[(state.pos - 2) & mask] & 0xFF;
    while (state.j < state.insertLength) {
      if (!reader.refill()) {
        return BrotliStatus.needMoreInput;
      }
      if (state.literalBlockLength == 0) {
        _literalBlockSwitch(reader, state);
      }
      final literalContext =
          kContextLookupTable[state.contextLookupOffset1 + prevByte1] |
          kContextLookupTable[state.contextLookupOffset2 + prevByte2];
      final literalTreeIdx =
          state.contextMap[state.contextMapSlice + literalContext] & 0xFF;
      state.literalBlockLength--;
      prevByte2 = prevByte1;
      reader.fillBitWindow();
      prevByte1 = readSymbol(state.literalTreeGroup, literalTreeIdx, reader);
      ring[state.pos] = prevByte1;
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.insertLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  }

  state.metaBlockLength -= state.insertLength;
  if (state.metaBlockLength <= 0) {
    state.phase = DecodePhase.mainLoop;
    return null;
  }
  state.phase = DecodePhase.readDistance;
  return null;
}

/// Resolves the distance of the current command (idempotent on suspension).
BrotliStatus? decodeDistance(BitReader reader, DecoderState state) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  var distanceSymbol = 0;
  if (state.implicitDistance) {
    state.distance = state.rings[state.distRbIdx];
  } else {
    if (state.distanceBlockLength == 0) {
      state.distanceBlockLength = _decodeBlockTypeAndLength(
        reader,
        state,
        2,
        state.numDistanceBlockTypes,
      );
      state.distContextMapSlice = state.rings[9] << numDistanceContextBits;
    }
    state.distanceBlockLength--;

    final distanceTreeIdx =
        state.distContextMap[state.distContextMapSlice +
            state.distanceContext] &
        0xFF;
    reader.fillBitWindow();
    distanceSymbol = readSymbol(
      state.distanceTreeGroup,
      distanceTreeIdx,
      reader,
    );
    if (distanceSymbol < numDistanceShortCodes) {
      final ringIndex =
          (state.distRbIdx + distanceShortCodeIndexOffset[distanceSymbol]) & 3;
      state.distance =
          state.rings[ringIndex] + distanceShortCodeValueOffset[distanceSymbol];
    } else {
      final extraBits = state.distExtraBits[distanceSymbol];
      reader.fillBitWindow();
      final bits = reader.readBits(extraBits);
      state.distance =
          state.distOffset[distanceSymbol] +
          (bits << state.distancePostfixBits);
    }
  }

  if (state.distance <= 0 || state.distance > maxAllowedDistance) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'invalid backward reference distance ${state.distance}',
      inputOffset: reader.bytesConsumed,
    );
  }

  if (state.maxDistance != state.maxBackwardDistance &&
      state.pos < state.maxBackwardDistance) {
    state.maxDistance = state.pos;
  } else {
    state.maxDistance = state.maxBackwardDistance;
  }

  if (state.distance > state.maxDistance) {
    // Static dictionary reference. The distance ring is intentionally not
    // rolled for dictionary copies (Java model; RFC sec. 8).
    _applyDictionaryReference(reader, state);
    return null;
  }

  if (distanceSymbol > 0) {
    state.distRbIdx = (state.distRbIdx + 1) & 3;
    state.rings[state.distRbIdx] = state.distance;
  }
  if (state.copyLength > state.metaBlockLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDistance,
      'copy length ${state.copyLength} overruns the metablock '
      '(${state.metaBlockLength} bytes left)',
      inputOffset: reader.bytesConsumed,
    );
  }
  state.j = 0;
  state.phase = DecodePhase.copyLoop;
  return null;
}

/// Resolves and writes one static-dictionary reference (port of
/// `Decode.doUseDictionary` + `Transform.transformDictionaryWord`).
///
/// Encoding (RFC 7932 §8):
/// * `address = distance - maxDistance - 1` (no compound dictionary attached);
/// * `wordLength = command copy length` must be `4..24`;
/// * `shift = sizeBits[wordLength]`;
/// * `wordIndex = address & ((1 << shift) - 1)`, `transformIndex = address >> shift`;
/// * the word is the transformed dictionary word, written at `pos`.
///
/// The metablock is charged with the **transformed** length, which may differ
/// from the copy length, and the write may extend up to 37 bytes past the ring
/// window into the slack region (the flush path wraps it afterwards).
void _applyDictionaryReference(BitReader reader, DecoderState state) {
  final fence = state.calculateFence();
  final wordLength = state.copyLength;
  if (wordLength < minDictionaryWordLength ||
      wordLength > maxDictionaryWordLength) {
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary word length $wordLength is outside '
      '[$minDictionaryWordLength, $maxDictionaryWordLength]',
      inputOffset: reader.bytesConsumed,
    );
  }
  final shift = kDictionarySizeBitsByLength[wordLength];
  if (shift == 0) {
    // Unreachable for 4..24; kept as a guard against a table change.
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary has no words of length $wordLength',
      inputOffset: reader.bytesConsumed,
    );
  }
  final address = state.distance - state.maxDistance - 1;
  if (address < 0) {
    // A compound dictionary would live here; caller-attached dictionaries are
    // not part of the RFC static-dictionary path.
    throw BrotliException(
      BrotliErrorCode.unsupportedFeature,
      'compound dictionary reference (address $address) is not supported',
      inputOffset: reader.bytesConsumed,
    );
  }
  final mask = (1 << shift) - 1;
  final wordIndex = address & mask;
  final transformIndex = address >> shift;
  if (transformIndex >= numRfcTransforms) {
    throw BrotliException(
      BrotliErrorCode.invalidTransform,
      'dictionary transform index $transformIndex is out of range '
      '(max ${numRfcTransforms - 1})',
      inputOffset: reader.bytesConsumed,
    );
  }
  final sourceOffset = dictionary.dictionaryWordOffset(wordLength, wordIndex);
  final transformedLength = transforms.transformDictionaryWord(
    state.ringBuffer,
    state.pos,
    kDictionaryData,
    sourceOffset,
    wordLength,
    transformIndex,
  );
  if (transformedLength <= 0) {
    // Java accepts empty results; C rejects them. Match C: an empty dictionary
    // word cannot make progress and is a format error.
    throw BrotliException(
      BrotliErrorCode.invalidDictionaryWord,
      'dictionary transform $transformIndex produced an empty word',
      inputOffset: reader.bytesConsumed,
    );
  }
  assert(
    transformedLength <= maxTransformedWordLength,
    'transformed word of $transformedLength bytes exceeds the ring slack',
  );
  state.pos += transformedLength;
  state.metaBlockLength -= transformedLength;
  state.dictionaryReferenceCount++;
  if (state.pos >= fence) {
    state.nextPhase = DecodePhase.mainLoop;
    state.phase = DecodePhase.initWrite;
  } else {
    state.phase = DecodePhase.mainLoop;
  }
}

/// Executes the backward copy of the current command.
BrotliStatus? decodeCopyLoop(BitReader reader, DecoderState state) {
  final fence = state.calculateFence();
  final ring = state.ringBuffer;
  final mask = state.ringBufferMask;
  final src = (state.pos - state.distance) & mask;
  final dst = state.pos;
  final remaining = state.copyLength - state.j;
  final srcEnd = src + remaining;
  final dstEnd = dst + remaining;

  // Java takes the bulk path only when both ends stay strictly inside the
  // window; the byte path is the only one that may trigger a flush.
  if (srcEnd < mask && dstEnd < mask) {
    if (state.distance >= remaining) {
      ring.setRange(dst, dst + remaining, ring, src);
    } else {
      for (var k = 0; k < remaining; k++) {
        ring[dst + k] = ring[src + k];
      }
    }
    state.j += remaining;
    state.metaBlockLength -= remaining;
    state.pos += remaining;
  } else {
    while (state.j < state.copyLength) {
      ring[state.pos] = ring[(state.pos - state.distance) & mask];
      state.metaBlockLength--;
      state.pos++;
      state.j++;
      if (state.pos >= fence) {
        state.nextPhase = DecodePhase.copyLoop;
        state.phase = DecodePhase.initWrite;
        return null;
      }
    }
  }
  state.phase = DecodePhase.mainLoop;
  return null;
}

// ---------------------------------------------------------------------------
// Block switching.
// ---------------------------------------------------------------------------

/// Port of `Decode.decodeBlockTypeAndLength`; caller must have refilled.
int _decodeBlockTypeAndLength(
  BitReader reader,
  DecoderState state,
  int treeType,
  int numBlockTypes,
) {
  final ringOffset = 4 + treeType * 2;
  reader.fillBitWindow();
  var blockType = readSymbol(state.blockTrees, 2 * treeType, reader);
  final blockLength = readBlockLength(
    state.blockTrees,
    2 * treeType + 1,
    reader,
  );
  if (blockType == 1) {
    blockType = state.rings[ringOffset + 1] + 1;
  } else if (blockType == 0) {
    blockType = state.rings[ringOffset];
  } else {
    blockType -= 2;
  }
  if (blockType >= numBlockTypes) {
    blockType -= numBlockTypes;
  }
  if (blockType < 0 || blockType >= numBlockTypes) {
    throw BrotliException(
      BrotliErrorCode.invalidBlockType,
      'block type $blockType is out of range [0, $numBlockTypes)',
      inputOffset: reader.bytesConsumed,
    );
  }
  state.rings[ringOffset] = state.rings[ringOffset + 1];
  state.rings[ringOffset + 1] = blockType;
  return blockLength;
}

void _literalBlockSwitch(BitReader reader, DecoderState state) {
  state.literalBlockLength = _decodeBlockTypeAndLength(
    reader,
    state,
    0,
    state.numLiteralBlockTypes,
  );
  final literalBlockType = state.rings[5];
  state.contextMapSlice = literalBlockType << numLiteralContextBits;
  state.literalTreeIdx = state.contextMap[state.contextMapSlice] & 0xFF;
  final contextMode = state.contextModes[literalBlockType] & 0xFF;
  state.contextLookupOffset1 = contextMode << 9;
  state.contextLookupOffset2 = state.contextLookupOffset1 + 256;
}

// ---------------------------------------------------------------------------
// Header parsing helpers.
// ---------------------------------------------------------------------------

/// Port of `Decode.decodeVarLenUnsignedByte`; caller must have refilled.
int _readVarLenUnsignedByte(BitReader reader) {
  reader.fillBitWindow();
  if (reader.readFewBits(1) != 0) {
    final n = reader.readFewBits(3);
    if (n == 0) {
      return 1;
    }
    return reader.readFewBits(n) + (1 << n);
  }
  return 0;
}

/// Reads one Huffman code description, restoring the reader on input shortage.
int? _tryHuffmanCode(
  BitReader reader,
  int alphabetSizeMax,
  int alphabetSizeLimit,
  Uint32List group,
  int tableIndex,
) {
  final memento = reader.save();
  final used = readHuffmanCode(
    alphabetSizeMax,
    alphabetSizeLimit,
    group,
    tableIndex,
    reader,
  );
  if (used == null) {
    reader.restore(memento);
    return null;
  }
  reader.discard(memento);
  return used;
}

/// Starts a context map: decodes the tree count and handles the one-tree case.
///
/// Returns `null` on success (check [DecoderState.contextMapNumTrees]) or a
/// suspension status.
BrotliStatus? _startContextMap(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  final size = distanceMap
      ? state.numDistanceBlockTypes << numDistanceContextBits
      : state.numLiteralBlockTypes << numLiteralContextBits;
  if (distanceMap) {
    state.distContextMap = _ensureBytes(state.distContextMap, size);
  } else {
    state.contextMap = _ensureBytes(state.contextMap, size);
  }
  state.contextMapSize = size;
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  state.contextMapNumTrees = _readVarLenUnsignedByte(reader) + 1;
  state.contextMapIndex = 0;
  if (state.contextMapNumTrees == 1) {
    final map = distanceMap ? state.distContextMap : state.contextMap;
    map.fillRange(0, size, 0);
  }
  return null;
}

/// Reads the zero-RLE parameters for a context map.
///
/// This is a separate resumable step from the tree read: the tree read may
/// suspend (and be retried), and retrying must not re-read these bits.
BrotliStatus? _readContextMapRleParams(BitReader reader, DecoderState state) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  reader.fillBitWindow();
  final useRleForZeros = reader.readFewBits(1);
  state.contextMapMaxRunPrefix = useRleForZeros != 0
      ? reader.readFewBits(4) + 1
      : 0;
  final alphabetSize = state.contextMapNumTrees + state.contextMapMaxRunPrefix;
  final tableSize = huffmanTableSizeLimit(alphabetSize);
  state.contextMapTable = _ensureUint32(state.contextMapTable, tableSize + 1);
  state.contextMapTableIndex = tableSize;
  // The scratch table starts at slot 0; the last slot holds the base offset.
  state.contextMapTable[tableSize] = 0;
  return null;
}

/// Reads the context-map Huffman code description.
BrotliStatus? _readContextMapTree(BitReader reader, DecoderState state) {
  final alphabetSize = state.contextMapNumTrees + state.contextMapMaxRunPrefix;
  final tableSize = state.contextMapTableIndex;
  final used = _tryHuffmanCode(
    reader,
    alphabetSize,
    alphabetSize,
    state.contextMapTable,
    tableSize,
  );
  if (used == null) {
    return BrotliStatus.needMoreInput;
  }
  if (used > tableSize) {
    throw BrotliException(
      BrotliErrorCode.internalError,
      'context-map Huffman table grew past its bound',
    );
  }
  return null;
}

/// Decodes the context-map symbols (including zero runs), resumably.
BrotliStatus? _readContextMapSymbols(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  final map = distanceMap ? state.distContextMap : state.contextMap;
  final size = state.contextMapSize;
  final table = state.contextMapTable;
  final tableIndex = state.contextMapTableIndex;
  final maxRunPrefix = state.contextMapMaxRunPrefix;
  while (state.contextMapIndex < size) {
    if (!reader.refill()) {
      return BrotliStatus.needMoreInput;
    }
    reader.fillBitWindow();
    final code = readSymbol(table, tableIndex, reader);
    if (code == 0) {
      map[state.contextMapIndex++] = 0;
    } else if (code <= maxRunPrefix) {
      reader.fillBitWindow();
      var repetitions = (1 << code) + reader.readFewBits(code);
      while (repetitions > 0) {
        if (state.contextMapIndex >= size) {
          throw BrotliException(
            BrotliErrorCode.invalidContextMap,
            'context-map zero run overruns the map',
            inputOffset: reader.bytesConsumed,
          );
        }
        map[state.contextMapIndex++] = 0;
        repetitions--;
      }
    } else {
      map[state.contextMapIndex++] = code - maxRunPrefix;
    }
  }
  return null;
}

/// Reads the MTF flag and inverse-transforms the context map if requested.
BrotliStatus? _finishContextMap(
  BitReader reader,
  DecoderState state,
  bool distanceMap,
) {
  if (!reader.refill()) {
    return BrotliStatus.needMoreInput;
  }
  reader.fillBitWindow();
  if (reader.readFewBits(1) != 0) {
    final map = distanceMap ? state.distContextMap : state.contextMap;
    final mtf = state.mtf;
    for (var i = 0; i < 256; i++) {
      mtf[i] = i;
    }
    for (var i = 0; i < state.contextMapSize; i++) {
      final index = map[i] & 0xFF;
      map[i] = mtf[index];
      if (index != 0) {
        final value = mtf[index];
        for (var j = index; j > 0; j--) {
          mtf[j] = mtf[j - 1];
        }
        mtf[0] = value;
      }
    }
  }
  return null;
}

/// Port of `Decode.calculateDistanceLut`, filling the reusable state arrays.
void _fillDistanceLut(DecoderState state) {
  final extraBits = state.distExtraBits;
  final offsets = state.distOffset;
  final npostfix = state.distancePostfixBits;
  final ndirect = state.numDirectDistanceCodes;
  final postfix = 1 << npostfix;
  final limit = state.distanceAlphabetSizeLimit;
  var bits = 1;
  var half = 0;
  var i = numDistanceShortCodes;
  for (var j = 0; j < ndirect && i < limit; j++, i++) {
    extraBits[i] = 0;
    offsets[i] = j + 1;
  }
  while (i < limit) {
    final base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1;
    for (var j = 0; j < postfix && i < limit; j++, i++) {
      extraBits[i] = bits;
      offsets[i] = base + j;
    }
    bits = bits + half;
    half = half ^ 1;
  }
}

// ---------------------------------------------------------------------------
// Small allocation helpers: grow, never shrink, so metablocks reuse buffers.
// ---------------------------------------------------------------------------

int _treeGroupLength(int alphabetSizeLimit, int treeCount) =>
    treeCount + treeCount * huffmanTableSizeLimit(alphabetSizeLimit);

Uint8List _ensureBytes(Uint8List buffer, int size) =>
    buffer.length >= size ? buffer : Uint8List(size);

Uint32List _ensureUint32(Uint32List buffer, int size) =>
    buffer.length >= size ? buffer : Uint32List(size);

Int32List _ensureInt32(Int32List buffer, int size) =>
    buffer.length >= size ? buffer : Int32List(size);

int _min(int a, int b) => a < b ? a : b;
