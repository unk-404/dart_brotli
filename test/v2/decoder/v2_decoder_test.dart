/// v2 decoder conformance: corpus, bounded decode, malformed input, large
/// window, compound/shared dictionaries and raw streaming.
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_neo/compat.dart';
import 'package:test/test.dart';

import '../../support/corpus.dart';

void _expectBytes(List<int> actual, List<int> expected, String reason) {
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

Matcher _throwsBrotli(String reason) => throwsA(isA<BrotliException>());

Uint8List _serializedPrefixDictionary(Uint8List dictionary) {
  final out = <int>[0x91, 0x00];
  var remaining = dictionary.length;
  while (remaining >= 128) {
    out.add((remaining & 127) | 128);
    remaining >>= 7;
  }
  out.add(remaining);
  out.addAll(dictionary);
  out.add(0); // NUM_WORD_LISTS
  out.add(0); // NUM_TRANSFORM_LISTS
  return Uint8List.fromList(out);
}

Uint8List _fixtureFile(String name) =>
    File('test/decoder/compound_vectors/$name').readAsBytesSync();

void main() {
  final corpus = Corpus.load();

  group('corpus', () {
    test('all corpus vectors decode byte-exactly', () {
      for (final entry in corpus.entries) {
        final decoded = BrotliDecoderV2.decode(corpus.compressedBytes(entry));
        _expectBytes(decoded, corpus.rawBytes(entry), entry.name);
      }
    });

    test('decodeInto writes exactly into a bounded buffer', () {
      for (final entry in corpus.entries) {
        final raw = corpus.rawBytes(entry);
        if (raw.isEmpty) {
          continue; // zero-length slice is covered by the streaming test
        }
        final dst = Uint8List(raw.length);
        final written = BrotliDecoderV2.decodeInto(
          dst,
          corpus.compressedBytes(entry),
          expectedSize: raw.length,
        );
        expect(written, raw.length, reason: entry.name);
        _expectBytes(dst, raw, '${entry.name} decodeInto');
      }
    });

    test('decodeInto reports a too-small output buffer', () {
      final entry = corpus.entries.firstWhere((e) => e.name == 'alice29.txt');
      final raw = corpus.rawBytes(entry);
      final dst = Uint8List(raw.length ~/ 2);
      expect(
        () => BrotliDecoderV2.decodeInto(dst, corpus.compressedBytes(entry)),
        throwsA(
          isA<BrotliException>().having(
            (e) => e.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
    });
  });

  group('malformed input', () {
    test('empty input throws', () {
      expect(
        () => BrotliDecoderV2.decode(Uint8List(0)),
        _throwsBrotli('empty'),
      );
    });

    test('every proper prefix of a real stream throws', () {
      final entry = corpus.entries.firstWhere((e) => e.name == 'quickfox');
      final compressed = corpus.compressedBytes(entry);
      for (var length = 0; length < compressed.length; length += 7) {
        expect(
          () => BrotliDecoderV2.decode(
            Uint8List.sublistView(compressed, 0, length),
          ),
          _throwsBrotli('prefix $length'),
          reason: 'prefix of $length bytes',
        );
      }
    });

    test('trailing bytes are rejected (strict one-shot semantics)', () {
      final entry = corpus.entries.firstWhere((e) => e.name == 'quickfox');
      final compressed = corpus.compressedBytes(entry);
      final trailing = Uint8List(compressed.length + 1)
        ..setRange(0, compressed.length, compressed);
      expect(() => BrotliDecoderV2.decode(trailing), _throwsBrotli('trailing'));
    });
  });

  group('large window', () {
    test('lgwin 25 round-trip requires and honours allowLargeWindow', () {
      final source = Uint8List(256 * 1024);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 31 + (i >> 8)) & 0xFF;
      }
      final compressed = Uint8List.fromList(
        brotliCompress(
          source,
          options: const BrotliEncodeOptions(
            quality: 5,
            lgwin: 25,
            largeWindow: true,
          ),
        ),
      );
      expect(
        () => BrotliDecoderV2.decode(compressed),
        _throwsBrotli('large window disabled'),
      );
      final decoded = BrotliDecoderV2.decode(
        compressed,
        options: const BrotliDecodeOptions(allowLargeWindow: true),
      );
      _expectBytes(decoded, source, 'lgwin 25');
    });
  });

  group('dictionaries', () {
    test('compound dictionary copy path', () {
      final dictionary = _fixtureFile('text.dict');
      final raw = _fixtureFile('text.raw');
      final compressed = _fixtureFile('text.br');
      final decoded = BrotliDecoderV2.decode(
        compressed,
        options: BrotliDecodeOptions(compoundDictionary: dictionary),
      );
      _expectBytes(decoded, raw, 'compound dictionary');
    });

    test('serialized shared dictionary with an LZ77 prefix', () {
      final dictionary = _fixtureFile('text.dict');
      final raw = _fixtureFile('text.raw');
      final compressed = _fixtureFile('text.br');
      final serialized = _serializedPrefixDictionary(dictionary);
      final decoded = BrotliDecoderV2.decode(
        compressed,
        options: BrotliDecodeOptions(sharedDictionary: serialized),
      );
      _expectBytes(decoded, raw, 'shared prefix dictionary');
    });

    test('invalid serialized shared dictionary throws at construction', () {
      expect(
        () => BrotliDecoderV2.decode(
          Uint8List.fromList(<int>[0x06]),
          options: BrotliDecodeOptions(
            sharedDictionary: Uint8List.fromList(<int>[0x91, 0x00, 0x7F]),
          ),
        ),
        _throwsBrotli('bad shared dictionary'),
      );
    });
  });

  group('streaming', () {
    test('one-byte input chunks and tiny output slices', () {
      final entry = corpus.entries.firstWhere((e) => e.name == 'quickfox');
      final compressed = corpus.compressedBytes(entry);
      final raw = corpus.rawBytes(entry);
      final decoder = BrotliStreamDecoderV2();
      final builder = BytesBuilder(copy: false);
      final output = Uint8List(7);
      var offset = 0;
      var closed = false;
      var wantInput = true;
      while (true) {
        if (wantInput) {
          if (offset < compressed.length) {
            decoder.addInput(
              Uint8List.sublistView(compressed, offset, offset + 1),
            );
            offset++;
          } else if (!closed) {
            decoder.closeInput();
            closed = true;
          }
          wantInput = false;
        }
        final status = decoder.decode(output);
        if (decoder.bytesWritten > 0) {
          builder.add(output.sublist(0, decoder.bytesWritten));
        }
        if (status == BrotliStatus.done) {
          break;
        }
        if (status == BrotliStatus.needMoreInput) {
          expect(closed, isFalse);
          wantInput = true;
        }
      }
      _expectBytes(builder.takeBytes(), raw, 'streaming quickfox');
    });

    test('streaming with a compound dictionary', () {
      final dictionary = _fixtureFile('text.dict');
      final raw = _fixtureFile('text.raw');
      final compressed = _fixtureFile('text.br');
      final decoder = BrotliStreamDecoderV2(
        options: BrotliDecodeOptions(compoundDictionary: dictionary),
      );
      final builder = BytesBuilder(copy: false);
      final output = Uint8List(13);
      for (var i = 0; i < compressed.length; i += 5) {
        final end = i + 5 < compressed.length ? i + 5 : compressed.length;
        decoder.addInput(Uint8List.sublistView(compressed, i, end));
      }
      decoder.closeInput();
      while (true) {
        final status = decoder.decode(output);
        if (decoder.bytesWritten > 0) {
          builder.add(output.sublist(0, decoder.bytesWritten));
        }
        if (status == BrotliStatus.done) {
          break;
        }
        expect(status, isNot(BrotliStatus.needMoreInput));
      }
      _expectBytes(builder.takeBytes(), raw, 'streaming dictionary');
    });
  });
}
