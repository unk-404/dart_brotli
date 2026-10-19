@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/io.dart';
import 'package:brotli_neo/src/common/errors.dart';
import 'package:brotli_neo/src/options.dart';
import 'package:test/test.dart';

import '../support/corpus.dart';

void _expectBytes(Uint8List actual, List<int> expected, String reason) {
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

Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 13 + 7) & 0xFF;
  }
  return bytes;
}

void main() {
  final corpus = Corpus.load();
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('brotli_neo_io_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String tempPath(String name) =>
      '${tempDir.path}${Platform.pathSeparator}$name';

  group('brotliDecodeFile', () {
    test('decodes corpus files', () async {
      for (final name in <String>['x', 'monkey', 'zerosukkanooa']) {
        final e = corpus.entries.firstWhere((entry) => entry.name == name);
        final decoded = await brotliDecodeFile(
          '${corpus.directory.path}/${e.compressed}',
        );
        _expectBytes(decoded, corpus.rawBytes(e), name);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('maxOutputSize option is propagated', () async {
      final e = corpus.entries.firstWhere((entry) => entry.name == '10x10y');
      expect(
        () => brotliDecodeFile(
          '${corpus.directory.path}/${e.compressed}',
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

    test('rejects missing files and non-Brotli contents', () async {
      expect(
        () => brotliDecodeFile(tempPath('missing.br')),
        throwsA(isA<Exception>()),
      );
      final junk = tempPath('junk.bin');
      File(junk).writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(100, (i) => (i * 7) & 0xFF)),
      );
      expect(() => brotliDecodeFile(junk), throwsA(isA<BrotliException>()));
      final empty = tempPath('empty.bin');
      File(empty).writeAsBytesSync(Uint8List(0));
      expect(() => brotliDecodeFile(empty), throwsA(isA<BrotliException>()));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('brotliEncodeFile', () {
    test('round-trips several sizes and payload kinds', () async {
      final random = Random(0xBEEF);
      final cases = <({Uint8List bytes, BrotliEncodeOptions options})>[
        (bytes: Uint8List(0), options: const BrotliEncodeOptions()),
        (
          bytes: Uint8List.fromList(<int>[0x42]),
          options: const BrotliEncodeOptions(),
        ),
        (bytes: _pattern(1000), options: const BrotliEncodeOptions()),
        (
          bytes: Uint8List.fromList(
            List<int>.generate(200000, (_) => random.nextInt(256)),
          ),
          options: const BrotliEncodeOptions(quality: 1),
        ),
      ];
      for (var i = 0; i < cases.length; i++) {
        final file = tempPath('roundtrip_$i.br');
        await brotliEncodeFile(file, cases[i].bytes, options: cases[i].options);
        final decoded = await brotliDecodeFile(file);
        _expectBytes(
          decoded,
          cases[i].bytes,
          'round-trip size=${cases[i].bytes.length}',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('overwrites an existing longer file', () async {
      final file = tempPath('overwrite.br');
      await brotliEncodeFile(file, _pattern(10000));
      final short = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await brotliEncodeFile(file, short);
      _expectBytes(await brotliDecodeFile(file), short, 'overwrite');
    });

    test('honours encode options', () async {
      final file = tempPath('options.br');
      final input = _pattern(1000);
      await brotliEncodeFile(
        file,
        input,
        options: const BrotliEncodeOptions(quality: 1, lgwin: 10),
      );
      _expectBytes(await brotliDecodeFile(file), input, 'lgwin 10');
    });

    test('create:false refuses a missing file', () async {
      expect(
        () => brotliEncodeFile(
          tempPath('nope.br'),
          Uint8List.fromList(<int>[1, 2, 3]),
          create: false,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
