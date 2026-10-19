@TestOn('vm')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/compat/codec.dart';
import 'package:brotli_neo/src/decoder/decoder.dart' show brotliDecompress;
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

/// Collects chunks emitted by a chunked conversion.
final class _CollectSink implements Sink<List<int>> {
  final List<Uint8List> _chunks = <Uint8List>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    _chunks.add(Uint8List.fromList(data));
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List take() {
    final builder = BytesBuilder(copy: false);
    for (final chunk in _chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

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

Uint8List _pattern(int length, {int seed = 3}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed) & 0xFF;
  }
  return bytes;
}

void main() {
  final corpus = Corpus.load();
  CorpusEntry entry(String name) =>
      corpus.entries.firstWhere((e) => e.name == name);

  group('BrotliCodec one-shot', () {
    test('encode/decode round-trips text, patterns and random data', () {
      const codec = BrotliCodec();
      final random = Random(0xC0DEC);
      final inputs = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(utf8.encode('hello brotli')),
        _pattern(10000),
        Uint8List.fromList(
          List<int>.generate(5000, (_) => random.nextInt(256)),
        ),
      ];
      for (final input in inputs) {
        final compressed = codec.encode(input);
        expect(compressed, isNotEmpty);
        _expectBytes(codec.decode(compressed), input, 'round-trip');
      }
    });

    test('converter getters match encode/decode', () {
      const codec = BrotliCodec();
      final input = _pattern(4000);
      final viaEncoder = codec.encoder.convert(input);
      _expectBytes(viaEncoder, codec.encode(input), 'encoder.convert');
      _expectBytes(codec.decoder.convert(viaEncoder), input, 'decoder.convert');
      _expectBytes(
        codec.decodeBytes(codec.encodeBytes(input)),
        input,
        'codec bytes helpers',
      );
    });

    test('decodes corpus vectors', () {
      const codec = BrotliCodec();
      for (final name in <String>[
        'x',
        '10x10y',
        'quickfox',
        'monkey',
        'alice29.txt',
      ]) {
        final e = entry(name);
        final decoded = codec.decode(corpus.compressedBytes(e).toList());
        _expectBytes(Uint8List.fromList(decoded), corpus.rawBytes(e), name);
      }
    });

    test('decodeToString and encodeString use UTF-8', () {
      const codec = BrotliCodec();
      final e = entry('quickfox');
      expect(
        codec.decodeToString(corpus.compressedBytes(e)),
        utf8.decode(corpus.rawBytes(e)),
      );
      const text = 'The quick brown fox jumps over the lazy dog';
      final compressed = codec.encodeString(text);
      expect(brotliDecompressToString(compressed), text);
      _expectBytes(
        brotliDecompress(brotliCompressString(text)),
        utf8.encode(text),
        'top-level string helpers',
      );
    });

    test('options are honoured', () {
      const codec = BrotliCodec(
        encodeOptions: BrotliEncodeOptions(lgwin: 10),
        decodeOptions: BrotliDecodeOptions(maxOutputSize: 5),
      );
      final input = _pattern(100);
      final compressed = codec.encode(input);
      expect(
        () => codec.decode(compressed),
        throwsA(
          isA<BrotliException>().having(
            (BrotliException ex) => ex.code,
            'code',
            BrotliErrorCode.outputLimitExceeded,
          ),
        ),
      );
      const wideCodec = BrotliCodec(
        decodeOptions: BrotliDecodeOptions(maxOutputSize: 1 << 20),
      );
      _expectBytes(wideCodec.decode(compressed), input, 'lgwin 10 stream');
    });
  });

  group('chunked conversion', () {
    test('decoder emits decompressed chunks before close', () {
      const codec = BrotliCodec();
      // alice29 decompresses to 152 KiB, so the 64 KiB sink buffer forces at
      // least one flushed chunk while the input is still open.
      final e = entry('alice29.txt');
      final compressed = corpus.compressedBytes(e);
      final sink = _CollectSink();
      final input = codec.decoder.startChunkedConversion(sink);
      for (var offset = 0; offset < compressed.length; offset += 4096) {
        final end = offset + 4096 < compressed.length
            ? offset + 4096
            : compressed.length;
        input.add(Uint8List.sublistView(compressed, offset, end));
      }
      expect(sink.closed, isFalse);
      expect(sink.take(), isNotEmpty, reason: 'some output before close');
      input.close();
      expect(sink.closed, isTrue);
      _expectBytes(sink.take(), corpus.rawBytes(e), 'chunked decoder');
    });

    test('decoder handles chunk sizes 1/2/3/7/4096', () {
      const codec = BrotliCodec();
      for (final name in <String>['quickfox', 'monkey', 'alice29.txt']) {
        final e = entry(name);
        final compressed = corpus.compressedBytes(e);
        final raw = corpus.rawBytes(e);
        for (final chunkSize in <int>[1, 2, 3, 7, 4096]) {
          final sink = _CollectSink();
          final input = codec.decoder.startChunkedConversion(sink);
          for (
            var offset = 0;
            offset < compressed.length;
            offset += chunkSize
          ) {
            final end = offset + chunkSize < compressed.length
                ? offset + chunkSize
                : compressed.length;
            input.add(Uint8List.sublistView(compressed, offset, end));
          }
          input.close();
          _expectBytes(sink.take(), raw, '$name chunk=$chunkSize');
        }
      }
    });

    test('decoder sink reports malformed streams on close', () {
      const codec = BrotliCodec();
      final sink = _CollectSink();
      final input = codec.decoder.startChunkedConversion(sink);
      input.add(Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF]));
      expect(() => input.close(), throwsA(isA<BrotliException>()));
      expect(sink.closed, isFalse);
    });

    test('decoder sink rejects truncated streams on close', () {
      const codec = BrotliCodec();
      final compressed = corpus.compressedBytes(entry('x'));
      final sink = _CollectSink();
      final input = codec.decoder.startChunkedConversion(sink);
      input.add(Uint8List.sublistView(compressed, 0, 2));
      expect(() => input.close(), throwsA(isA<BrotliException>()));
      expect(sink.closed, isFalse);
    });

    test('encoder sink compresses chunks and rejects use after close', () {
      const codec = BrotliCodec();
      final raw = _pattern(5000);
      final sink = _CollectSink();
      final input = codec.encoder.startChunkedConversion(sink);
      for (var offset = 0; offset < raw.length; offset += 7) {
        final end = offset + 7 < raw.length ? offset + 7 : raw.length;
        input.add(Uint8List.sublistView(raw, offset, end));
      }
      input.close();
      expect(sink.closed, isTrue);
      final compressed = sink.take();
      _expectBytes(codec.decode(compressed), raw, 'chunked encoder');
      expect(() => input.add(Uint8List.fromList(<int>[1])), throwsStateError);
    });

    test('decoder sink close is idempotent and add-after-close throws', () {
      const codec = BrotliCodec();
      final sink = _CollectSink();
      final input = codec.decoder.startChunkedConversion(sink);
      input.add(corpus.compressedBytes(entry('quickfox')));
      input.close();
      input.close();
      expect(sink.closed, isTrue);
      expect(() => input.add(Uint8List.fromList(<int>[1])), throwsStateError);
    });
  });
}
