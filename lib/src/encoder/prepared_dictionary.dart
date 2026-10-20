/// A reusable, pre-indexed compound (caller provided) dictionary.
///
/// The compound-dictionary extension lets a stream copy raw bytes from a
/// dictionary supplied to both encoder and decoder. Building the match index for
/// a large dictionary is the expensive part of that feature, so callers that
/// encode many streams with the same dictionary can build it once:
///
/// ```dart
/// final prepared = BrotliPreparedDictionary(dictionaryBytes);
/// final a = brotliCompress(inputA, options: BrotliEncodeOptions(
///   preparedDictionary: prepared));
/// final b = brotliCompress(inputB, options: BrotliEncodeOptions(
///   preparedDictionary: prepared));
/// ```
///
/// The object is immutable and can be shared between streams; the encoder never
/// modifies it. The decoder still has to be given the same raw bytes through
/// `BrotliDecodeOptions.compoundDictionary`.
library;

import 'dart:typed_data';

import 'compound_dictionary.dart';

/// Largest accepted prepared dictionary (the distance field must stay in the
/// decoder's `maxAllowedDistance` range).
const int kMaxPreparedDictionarySize = 1 << 30;

/// A compound dictionary with its four-byte-prefix index built once.
final class BrotliPreparedDictionary {
  /// Prepares [dictionary].
  ///
  /// A [Uint8List] is taken by reference (do not modify it afterwards); any
  /// other list is copied. Throws [ArgumentError] when the dictionary is larger
  /// than [kMaxPreparedDictionarySize].
  factory BrotliPreparedDictionary(List<int> dictionary) {
    final bytes = dictionary is Uint8List
        ? dictionary
        : Uint8List.fromList(dictionary);
    if (bytes.length > kMaxPreparedDictionarySize) {
      throw ArgumentError.value(
        bytes.length,
        'dictionary',
        'compound dictionary exceeds $kMaxPreparedDictionarySize bytes',
      );
    }
    return BrotliPreparedDictionary._(bytes);
  }

  BrotliPreparedDictionary._(this.dictionary)
    : _index = CompoundDictionaryMatcher.buildIndex(dictionary);

  /// The dictionary bytes. Shared with the stream; must not be modified.
  final Uint8List dictionary;

  final Map<int, List<int>> _index;

  /// Number of dictionary bytes.
  int get length => dictionary.length;

  /// Number of dictionary bytes (alias of [length]).
  int get size => dictionary.length;

  /// Creates a matcher over this dictionary that reuses the cached index.
  CompoundDictionaryMatcher createMatcher() =>
      CompoundDictionaryMatcher(dictionary, index: _index);
}
