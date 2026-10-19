/// Deterministic hardening tests for the decoder plus encoder/decoder
/// round-trip properties.
///
/// Run on the VM only (it reads the corpus from disk):
///
/// ```sh
/// dart test test/fuzz
/// ```
///
/// The fuzz cases are fully seeded and bounded: malformed input may either be
/// rejected with [BrotliException] or (very rarely) decode to a different valid
/// buffer, but it must never surface any other exception type and must respect
/// `maxOutputSize`.
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/compat.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// Output bound for every fuzz input (decompression-bomb guard).
const int _maxFuzzOutput = 1 << 20;

const BrotliDecodeOptions _fuzzOptions = BrotliDecodeOptions(
  maxOutputSize: _maxFuzzOutput,
);

/// Qualities with stable behaviour while the encoder ladder is being extended.
const List<int> _stableQualities = <int>[0, 1, 4, 5];

Uint8List _pattern(int size, {int seed = 3}) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 31 + seed + (i >> 6)) & 0xFF;
  }
  return bytes;
}

void _expectBytes(Uint8List actual, Uint8List expected, String reason) {
  expect(actual.length, expected.length, reason: '$reason: length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail(
        '$reason: first difference at byte $i '
        '(${actual[i]} != ${expected[i]})',
      );
    }
  }
}

/// Runs [input] through the one-shot decoder and asserts that the only possible
/// failure is [BrotliException].
void _expectOnlyBrotliException(Uint8List input, String reason) {
  try {
    final output = brotliDecompress(input, options: _fuzzOptions);
    expect(
      output.length,
      lessThanOrEqualTo(_maxFuzzOutput),
      reason: '$reason: output bound',
    );
  } on BrotliException {
    // The expected outcome for malformed streams.
  }
}

void _expectBrotliException(void Function() action, {BrotliErrorCode? code}) {
  try {
    action();
    fail('expected a BrotliException');
  } on BrotliException catch (error) {
    if (code != null) {
      expect(error.code, code, reason: 'error code');
    }
  }
}

/// Deterministic mutations of one compressed corpus stream.
Iterable<Uint8List> _mutations(Uint8List original, Random random) sync* {
  if (original.isEmpty) {
    return;
  }
  // Random bit flips.
  for (var i = 0; i < 2; i++) {
    final mutated = Uint8List.fromList(original);
    final index = random.nextInt(mutated.length);
    mutated[index] ^= 1 << random.nextInt(8);
    yield mutated;
  }
  // Byte replacement.
  final replaced = Uint8List.fromList(original);
  replaced[random.nextInt(replaced.length)] = random.nextInt(256);
  yield replaced;
  // Single byte deletion.
  if (original.length > 1) {
    final index = random.nextInt(original.length);
    yield Uint8List.fromList(<int>[
      ...original.sublist(0, index),
      ...original.sublist(index + 1),
    ]);
  }
  // Single byte insertion.
  final insertAt = random.nextInt(original.length + 1);
  yield Uint8List.fromList(<int>[
    ...original.sublist(0, insertAt),
    random.nextInt(256),
    ...original.sublist(insertAt),
  ]);
  // Truncation at a few deterministic fractions.
  for (final divisor in <int>[2, 3, 5]) {
    final cut = original.length ~/ divisor;
    if (cut > 0 && cut < original.length) {
      yield Uint8List.sublistView(original, 0, cut);
    }
  }
  // Trailing garbage (strict one-shot must reject it as unused input).
  yield Uint8List.fromList(<int>[...original, 0xDE, 0xAD, 0xBE, 0xEF]);
}

/// Push-decodes [compressed] with [inputChunk]-byte feeds and
/// [outputChunk]-byte output slices.
Uint8List _streamDecode(
  Uint8List compressed, {
  required int inputChunk,
  required int outputChunk,
}) {
  final decoder = BrotliDecoder();
  final builder = BytesBuilder(copy: false);
  final output = Uint8List(outputChunk);
  var offset = 0;
  var closed = false;
  var wantInput = true;
  while (true) {
    if (wantInput) {
      if (offset < compressed.length) {
        final end = offset + inputChunk < compressed.length
            ? offset + inputChunk
            : compressed.length;
        decoder.addInput(Uint8List.sublistView(compressed, offset, end));
        offset = end;
      } else if (!closed) {
        decoder.closeInput();
        closed = true;
      }
      wantInput = false;
    }
    final status = decoder.decode(output);
    final written = decoder.bytesWritten;
    if (written > 0) {
      builder.add(output.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(closed, isFalse, reason: 'input requested after closeInput');
      wantInput = true;
      continue;
    }
    expect(written, greaterThan(0), reason: 'needMoreOutput made no progress');
  }
  return builder.takeBytes();
}

void main() {
  final corpus = Corpus.load();

  group('fuzz: malformed streams', () {
    test('mutated corpus streams only raise BrotliException', () {
      final random = Random(0xB70B11);
      for (final entry in corpus.entries) {
        final compressed = corpus.compressedBytes(entry);
        for (final mutated in _mutations(compressed, random)) {
          _expectOnlyBrotliException(mutated, 'mutation of ${entry.name}');
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('truncated corpus streams only raise BrotliException', () {
      for (final entry in corpus.entries) {
        final compressed = corpus.compressedBytes(entry);
        final cuts = <int>{0, 1, compressed.length ~/ 2, compressed.length - 1};
        for (final cut in cuts) {
          if (cut < 0 || cut >= compressed.length) {
            continue;
          }
          _expectOnlyBrotliException(
            Uint8List.sublistView(compressed, 0, cut),
            'truncation of ${entry.name} at $cut',
          );
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('random byte streams only raise BrotliException', () {
      final random = Random(0xDEC0DE);
      for (var i = 0; i < 250; i++) {
        final length = 1 + random.nextInt(96);
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        _expectOnlyBrotliException(bytes, 'random stream $i');
      }
    });

    test('empty input is reported as truncated', () {
      _expectBrotliException(
        () => brotliDecompress(Uint8List(0)),
        code: BrotliErrorCode.truncatedInput,
      );
    });

    test('strict one-shot rejects trailing bytes', () {
      final compressed = brotliCompress(_pattern(64));
      _expectBrotliException(
        () => brotliDecompress(Uint8List.fromList(<int>[...compressed, 0x00])),
        code: BrotliErrorCode.unusedBytesAfterEnd,
      );
    });

    test('maxOutputSize is enforced', () {
      final input = _pattern(2048);
      final compressed = brotliCompress(input);
      _expectBrotliException(
        () => brotliDecompress(
          compressed,
          options: const BrotliDecodeOptions(maxOutputSize: 1024),
        ),
        code: BrotliErrorCode.outputLimitExceeded,
      );
    });
  });

  group('property: encoder/decoder round-trip', () {
    test('all sizes x qualities x lgwin values', () {
      const sizes = <int>[0, 1, 2, 3, 7, 64, 1023, 4096, 65537];
      const lgwins = <int>[10, 16, 22, 24];
      for (final size in sizes) {
        final input = _pattern(size, seed: size + 11);
        for (final quality in _stableQualities) {
          for (final lgwin in lgwins) {
            final compressed = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality, lgwin: lgwin),
            );
            expect(
              compressed.length,
              lessThanOrEqualTo(maxCompressedSize(input.length)),
              reason: 'size=$size q=$quality lgwin=$lgwin bound',
            );
            final decoded = brotliDecompress(
              compressed,
              options: BrotliDecodeOptions(maxOutputSize: size + 64),
            );
            _expectBytes(decoded, input, 'size=$size q=$quality lgwin=$lgwin');
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('incompressible random data round-trips', () {
      final random = Random(0x51EED);
      for (final size in <int>[0, 1, 31, 1024, 4096]) {
        final input = Uint8List.fromList(
          List<int>.generate(size, (_) => random.nextInt(256)),
        );
        for (final quality in _stableQualities) {
          final compressed = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          final decoded = brotliDecompress(compressed);
          _expectBytes(decoded, input, 'random size=$size q=$quality');
        }
      }
    });

    test('repetitive data round-trips', () {
      final input = Uint8List(1 << 15);
      for (var i = 0; i < input.length; i++) {
        input[i] = (i >> 7) & 0x07;
      }
      for (final quality in _stableQualities) {
        final compressed = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(compressed.length, lessThan(input.length));
        _expectBytes(
          brotliDecompress(compressed),
          input,
          'repetitive q=$quality',
        );
      }
    });

    test('encoder output is deterministic', () {
      final input = _pattern(4096);
      for (final quality in _stableQualities) {
        final first = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        final second = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        _expectBytes(second, first, 'determinism q=$quality');
      }
    });

    test('streaming decode matches one-shot for several input chunks', () {
      final input = _pattern(8192);
      final compressed = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 5),
      );
      for (final chunk in <int>[1, 2, 3, 7, 4096]) {
        final decoded = _streamDecode(
          compressed,
          inputChunk: chunk,
          outputChunk: 13,
        );
        _expectBytes(decoded, input, 'streaming chunk=$chunk');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
