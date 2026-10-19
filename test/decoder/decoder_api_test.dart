@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:blit/bytes.dart' show Bytes;
import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/decoder/decoder.dart';
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// Result of pumping a [BrotliDecoder] to completion.
final class _StreamResult {
  _StreamResult(this.bytes, this.decoder, this.calls);

  final Uint8List bytes;
  final BrotliDecoder decoder;
  final int calls;
}

/// Streams [compressed] through a [BrotliDecoder], feeding [inputChunk] bytes
/// only when the decoder needs input and decoding into [outputChunk]-sized
/// slices (`null` = 1 MiB).
_StreamResult _streamDecode(
  Uint8List compressed, {
  required int inputChunk,
  int? outputChunk,
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
}) {
  final decoder = BrotliDecoder(options: options);
  final builder = BytesBuilder(copy: false);
  final buffer = Uint8List(outputChunk ?? (1 << 20));
  var offset = 0;
  var closed = false;
  var wantInput = true;
  var stall = 0;
  var calls = 0;
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
    calls++;
    final status = decoder.decode(buffer);
    final written = decoder.bytesWritten;
    expect(written, inInclusiveRange(0, buffer.length));
    if (written > 0) {
      builder.add(buffer.sublist(0, written));
    }
    if (status == BrotliStatus.done) {
      break;
    }
    if (status == BrotliStatus.needMoreInput) {
      expect(
        closed,
        isFalse,
        reason: 'decoder requested input after closeInput',
      );
      wantInput = true;
      stall = 0;
      continue;
    }
    // needMoreOutput: continue draining the same input chunk.
    if (written == 0) {
      stall++;
      expect(stall, lessThan(100), reason: 'decoder made no progress');
    } else {
      stall = 0;
    }
    expect(calls, lessThan(1 << 24));
  }
  expect(decoder.consumedInput, compressed.length);
  expect(decoder.isDone, isTrue);
  return _StreamResult(builder.takeBytes(), decoder, calls);
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

void main() {
  final corpus = Corpus.load();
  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  group('brotliDecompress (one-shot)', () {
    test('22/22 corpus pairs are byte-exact', () {
      for (final e in corpus.entries) {
        final decoded = brotliDecompress(corpus.compressedBytes(e));
        _expectBytes(decoded, corpus.rawBytes(e), e.name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('non-eager output mode decodes identically', () {
      final e = entry('alice29.txt');
      final decoded = brotliDecompress(
        corpus.compressedBytes(e),
        options: const BrotliDecodeOptions(eagerOutput: false),
      );
      _expectBytes(decoded, corpus.rawBytes(e), 'alice29 non-eager');
    });

    test('trailing bytes are rejected by the strict one-shot API', () {
      final compressed = corpus.compressedBytes(entry('empty'));
      final withGarbage = Uint8List(compressed.length + 1)
        ..setRange(0, compressed.length, compressed);
      expect(
        () => brotliDecompress(withGarbage),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.unusedBytesAfterEnd,
          ),
        ),
      );
    });

    test('maxOutputSize is enforced by the one-shot API', () {
      final e = entry('10x10y');
      final rawLength = e.rawBytes;
      expect(
        () => brotliDecompress(
          corpus.compressedBytes(e),
          options: BrotliDecodeOptions(maxOutputSize: rawLength - 1),
        ),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
      final exact = brotliDecompress(
        corpus.compressedBytes(e),
        options: BrotliDecodeOptions(maxOutputSize: rawLength),
      );
      _expectBytes(exact, corpus.rawBytes(e), 'exact output limit');
    });
  });

  group('BrotliDecoder (streaming)', () {
    const matrixVectors = <String>[
      'empty',
      'x',
      '10x10y',
      'quickfox',
      'monkey',
      'zerosukkanooa',
      'alice29.txt',
    ];
    const chunkSizes = <int>[1, 2, 3, 7, 17, 4095, 4096, 4097, 65536];
    const outputSizes = <int?>[1, 7, 65536, null];

    test('chunk 脳 output-size matrix on representative vectors', () {
      for (final name in matrixVectors) {
        final e = entry(name);
        final compressed = corpus.compressedBytes(e);
        final raw = corpus.rawBytes(e);
        for (final inputChunk in chunkSizes) {
          for (final outputChunk in outputSizes) {
            final result = _streamDecode(
              compressed,
              inputChunk: inputChunk,
              outputChunk: outputChunk,
            );
            _expectBytes(
              result.bytes,
              raw,
              '$name input=$inputChunk output=$outputChunk',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('matrix on the remaining vectors', () {
      const done = <String>{
        'empty',
        'x',
        '10x10y',
        'quickfox',
        'monkey',
        'zerosukkanooa',
        'alice29.txt',
      };
      for (final e in corpus.entries) {
        if (done.contains(e.name)) {
          continue;
        }
        final compressed = corpus.compressedBytes(e);
        final raw = corpus.rawBytes(e);
        for (final inputChunk in <int>[1, 4096, 65536]) {
          for (final outputChunk in <int>[7, 65536]) {
            final result = _streamDecode(
              compressed,
              inputChunk: inputChunk,
              outputChunk: outputChunk,
            );
            _expectBytes(
              result.bytes,
              raw,
              '${e.name} input=$inputChunk output=$outputChunk',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('estimatedTotalSize matches the decompressed size', () {
      for (final e in corpus.entries) {
        final result = _streamDecode(
          corpus.compressedBytes(e),
          inputChunk: 4096,
          outputChunk: 65536,
        );
        _expectBytes(result.bytes, corpus.rawBytes(e), e.name);
        expect(result.decoder.estimatedTotalSize, e.rawBytes, reason: e.name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('non-eager mode with tiny slices', () {
      for (final name in <String>['x', '10x10y', 'monkey']) {
        final e = entry(name);
        for (final inputChunk in <int>[1, 4096]) {
          final result = _streamDecode(
            corpus.compressedBytes(e),
            inputChunk: inputChunk,
            outputChunk: 7,
            options: const BrotliDecodeOptions(eagerOutput: false),
          );
          _expectBytes(result.bytes, corpus.rawBytes(e), '$name non-eager');
        }
      }
    });

    test('addInput accepts BytesLike and List<int>', () {
      final compressed = corpus.compressedBytes(entry('x'));
      for (final input in <Object>[
        Bytes.fromUint8List(compressed),
        compressed.toList(),
      ]) {
        final decoder = BrotliDecoder()..addInput(input);
        decoder.closeInput();
        final out = Uint8List(16);
        expect(decoder.decode(out), BrotliStatus.done);
        expect(decoder.bytesWritten, 1);
        expect(out[0], 0x58);
      }
      expect(() => BrotliDecoder().addInput(42), throwsA(isA<ArgumentError>()));
    });

    test('maxOutputSize is enforced while streaming', () {
      final e = entry('zeros');
      expect(
        () => _streamDecode(
          corpus.compressedBytes(e),
          inputChunk: 4096,
          outputChunk: 1024,
          options: BrotliDecodeOptions(maxOutputSize: e.rawBytes - 1),
        ),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
    });

    test('done is idempotent and extra input is ignored', () {
      final decoder = BrotliDecoder()
        ..addInput(corpus.compressedBytes(entry('x')))
        ..closeInput();
      final out = Uint8List(8);
      expect(decoder.decode(out), BrotliStatus.done);
      expect(decoder.bytesWritten, 1);
      final consumedAfterDone = decoder.consumedInput;
      for (var i = 0; i < 3; i++) {
        expect(decoder.decode(out), BrotliStatus.done);
        expect(decoder.bytesWritten, 0);
      }
      decoder.addInput(Uint8List.fromList(<int>[1, 2, 3]));
      expect(decoder.consumedInput, consumedAfterDone);
      expect(decoder.decode(out), BrotliStatus.done);
      decoder.closeInput();
      expect(decoder.decode(out), BrotliStatus.done);
    });

    test('close() is idempotent and further calls throw StateError', () {
      final decoder = BrotliDecoder();
      decoder.close();
      decoder.close();
      expect(() => decoder.decode(Uint8List(8)), throwsStateError);
      expect(
        () => decoder.addInput(Uint8List.fromList(<int>[0])),
        throwsStateError,
      );
    });

    test('decode validates the output slice', () {
      final decoder = BrotliDecoder();
      expect(() => decoder.decode(Uint8List(8), 5, 2), throwsRangeError);
      expect(() => decoder.decode(Uint8List(8), -1), throwsRangeError);
    });

    test('a decoder error is sticky', () {
      final corrupted = Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF]);
      final decoder = BrotliDecoder()..addInput(corrupted);
      decoder.closeInput();
      final out = Uint8List(16);
      BrotliException? first;
      try {
        decoder.decode(out);
      } on BrotliException catch (error) {
        first = error;
      }
      expect(first, isNotNull);
      expect(() => decoder.decode(out), throwsA(same(first)));
      expect(() => decoder.decode(out), throwsA(same(first)));
    });
  });

  group('BytesInputQueue', () {
    test('serves chunks in order across chunk boundaries', () {
      final queue = BytesInputQueue()
        ..addUint8List(Uint8List.fromList(<int>[1, 2, 3]))
        ..addBytes(Bytes.fromUint8List(Uint8List.fromList(<int>[4, 5])));
      expect(queue.addedBytes, 5);
      expect(queue.availableBytes, 5);
      final buffer = Uint8List(4);
      expect(queue.readInto(buffer, 0, 4), 4);
      expect(buffer, orderedEquals(<int>[1, 2, 3, 4]));
      expect(queue.consumedBytes, 4);
      expect(queue.availableBytes, 1);
      expect(queue.readInto(buffer, 0, 4), 1);
      expect(buffer[0], 5);
      expect(queue.readInto(buffer, 0, 4), 0);
      expect(queue.isClosed, isFalse);
      queue.close();
      expect(queue.isClosed, isTrue);
      expect(
        () => queue.addUint8List(Uint8List.fromList(<int>[6])),
        throwsStateError,
      );
    });
  });
}
