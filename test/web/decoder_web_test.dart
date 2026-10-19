/// Browser (`dart test -p chrome`) coverage for the web-safe public APIs.
///
/// The compressed vectors are inlined as base64 so the test has no `dart:io`
/// dependency and runs unchanged under dart2js / dart2wasm. They come from the
/// MIT-licensed reference corpus in `test/testdata`.
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/compat.dart';
import 'package:test/test.dart';

/// Empty stream: window 16 + `11` empty last meta-block.
const String _emptyB64 = 'Bg==';

/// `x` (1 byte).
const String _xB64 = 'CwCAWAM=';

/// "The quick brown fox jumps over the lazy dog" (43 bytes).
const String _quickfoxB64 =
    'CxWAVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZwM=';

/// Ten `X` bytes followed by ten `Y` bytes (20 bytes).
const String _tenByTenB64 = 'GxMAAKSwsuqBRwKK';

/// `Xyzzy` (5 bytes, dictionary-heavy).
const String _xyzzyB64 = 'CwKAWHl6enkD';

Uint8List _bytes(String base64Text) => base64.decode(base64Text);

final Uint8List _emptyRaw = Uint8List(0);
final Uint8List _xRaw = Uint8List.fromList(<int>[0x58]);
final Uint8List _quickfoxRaw = Uint8List.fromList(
  utf8.encode('The quick brown fox jumps over the lazy dog'),
);
final Uint8List _tenByTenRaw = Uint8List.fromList(<int>[
  for (var i = 0; i < 10; i++) 0x58,
  for (var i = 0; i < 10; i++) 0x59,
]);
final Uint8List _xyzzyRaw = Uint8List.fromList(utf8.encode('Xyzzy'));

/// Collects chunks from a chunked conversion.
final class _CollectSink implements Sink<List<int>> {
  final List<Uint8List> _chunks = <Uint8List>[];
  bool closed = false;

  @override
  void add(List<int> data) => _chunks.add(Uint8List.fromList(data));

  @override
  void close() => closed = true;

  Uint8List take() {
    final builder = BytesBuilder(copy: false);
    for (final chunk in _chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

void _expectBytes(List<int> actual, Uint8List expected, String reason) {
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

/// Pumps [compressed] through the push decoder, feeding [inputChunk] bytes only
/// when the decoder asks for input and writing into [outputChunk]-byte slices.
Uint8List _streamDecode(
  Uint8List compressed, {
  int inputChunk = 1,
  int outputChunk = 64,
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

void main() {
  group('one-shot brotliDecompress', () {
    test('decodes empty and tiny inline vectors', () {
      _expectBytes(brotliDecompress(_bytes(_emptyB64)), _emptyRaw, 'empty');
      _expectBytes(brotliDecompress(_bytes(_xB64)), _xRaw, 'x');
      _expectBytes(
        brotliDecompress(_bytes(_quickfoxB64)),
        _quickfoxRaw,
        'quickfox',
      );
      _expectBytes(
        brotliDecompress(_bytes(_tenByTenB64)),
        _tenByTenRaw,
        '10x10y',
      );
      _expectBytes(brotliDecompress(_bytes(_xyzzyB64)), _xyzzyRaw, 'xyzzy');
    });

    test('strict one-shot rejects trailing bytes', () {
      final withTrailing = Uint8List.fromList(<int>[
        ..._bytes(_emptyB64),
        0x00,
      ]);
      _expectBrotliException(
        () => brotliDecompress(withTrailing),
        code: BrotliErrorCode.unusedBytesAfterEnd,
      );
    });

    test('malformed and truncated headers throw typed errors', () {
      _expectBrotliException(
        () => brotliDecompress(Uint8List.fromList(<int>[0x11])),
        code: BrotliErrorCode.invalidWindowBits,
      );
      _expectBrotliException(
        () =>
            brotliDecompress(Uint8List.sublistView(_bytes(_quickfoxB64), 0, 8)),
      );
      _expectBrotliException(() => brotliDecompress(Uint8List(0)));
    });
  });

  group('streaming BrotliDecoder', () {
    test('decodes with 1-byte input and 3-byte output chunks', () {
      for (final vector in <(Uint8List, Uint8List, String)>[
        (_bytes(_xB64), _xRaw, 'x'),
        (_bytes(_quickfoxB64), _quickfoxRaw, 'quickfox'),
        (_bytes(_tenByTenB64), _tenByTenRaw, '10x10y'),
      ]) {
        final decoded = _streamDecode(vector.$1, inputChunk: 1, outputChunk: 3);
        _expectBytes(decoded, vector.$2, 'streaming ${vector.$3}');
      }
    });

    test('decodes with whole-stream input and large output chunks', () {
      final decoded = _streamDecode(
        _bytes(_quickfoxB64),
        inputChunk: 1024,
        outputChunk: 4096,
      );
      _expectBytes(decoded, _quickfoxRaw, 'streaming whole stream');
    });

    test('extra input added after done is ignored', () {
      final decoder = BrotliDecoder();
      decoder.addInput(_bytes(_xB64));
      decoder.closeInput();
      final out = Uint8List(16);
      var status = decoder.decode(out);
      while (status == BrotliStatus.needMoreOutput) {
        status = decoder.decode(out);
      }
      expect(status, BrotliStatus.done);
      expect(decoder.bytesWritten, 1);
      _expectBytes(
        Uint8List.sublistView(out, 0, decoder.bytesWritten),
        _xRaw,
        'streaming x',
      );

      // Streaming API: bytes offered after `done` are ignored.
      decoder.addInput(Uint8List.fromList(<int>[0xDE, 0xAD]));
      expect(decoder.decode(out), BrotliStatus.done);
      expect(decoder.bytesWritten, 0);
    });

    test('trailing bytes queued before done are rejected', () {
      // The streaming core still validates that the stream consumed its input
      // exactly; bytes queued before `done` surface as unusedBytesAfterEnd.
      final decoder = BrotliDecoder();
      decoder.addInput(_bytes(_xB64));
      decoder.addInput(Uint8List.fromList(<int>[0xDE, 0xAD]));
      decoder.closeInput();
      final out = Uint8List(16);
      _expectBrotliException(
        () => decoder.decode(out),
        code: BrotliErrorCode.unusedBytesAfterEnd,
      );
    });
  });

  group('BrotliCodec', () {
    test('one-shot codec decodes vectors and round-trips text', () {
      const codec = BrotliCodec();
      _expectBytes(codec.decode(_bytes(_quickfoxB64)), _quickfoxRaw, 'codec');
      expect(
        codec.decodeToString(_bytes(_quickfoxB64)),
        'The quick brown fox jumps over the lazy dog',
      );
      final raw = Uint8List.fromList(utf8.encode('browser round-trip'));
      _expectBytes(
        codec.decodeBytes(codec.encodeBytes(raw)),
        raw,
        'round-trip',
      );
    });

    test('chunked decoder conversion emits the full stream', () {
      final sink = _CollectSink();
      final conversion = const BrotliCodec().decoder.startChunkedConversion(
        sink,
      );
      final compressed = _bytes(_tenByTenB64);
      for (var i = 0; i < compressed.length; i++) {
        conversion.add(<int>[compressed[i]]);
      }
      conversion.close();
      expect(sink.closed, isTrue);
      _expectBytes(sink.take(), _tenByTenRaw, 'chunked decoder');
    });

    test('chunked encoder conversion round-trips', () {
      final raw = Uint8List.fromList(utf8.encode('chunked encoder on the web'));
      final sink = _CollectSink();
      final conversion = const BrotliCodec(
        encodeOptions: BrotliEncodeOptions(quality: 5),
      ).encoder.startChunkedConversion(sink);
      conversion.add(Uint8List.sublistView(raw, 0, 7));
      conversion.add(Uint8List.sublistView(raw, 7));
      conversion.close();
      expect(sink.closed, isTrue);
      final decoded = const BrotliCodec().decodeBytes(sink.take());
      _expectBytes(decoded, raw, 'chunked encoder');
    });
  });

  group('blit-native API', () {
    test('brotliEncode/brotliDecode round-trip on BytesLike input', () {
      final raw = Uint8List.fromList(
        List<int>.generate(512, (i) => (i * 17 + 3) & 0xFF),
      );
      final compressed = brotliEncode(
        Bytes.fromList(raw),
        options: const BrotliEncodeOptions(quality: 5),
      );
      final decoded = brotliDecode(compressed);
      _expectBytes(decoded.asUint8List(), raw, 'blit round-trip');
    });
  });
}
