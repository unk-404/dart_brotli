@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/v2/encoder/bit_writer_js.dart' as js;
import 'package:brotli_neo/src/v2/encoder/bit_writer_vm.dart' as vm;
import 'package:test/test.dart';

import '../../../benchmark/corpus.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;
  final text = makeText(_kMiB);
  final binary = makeBinary(_kMiB);

  group('BrotliEncoderV2 round-trip', () {
    test('small and boundary sizes at q0/q1/q5', () {
      for (final size in <int>[0, 1, 4, 100, 4095, 65535, 65536, 65537]) {
        final input = size <= text.length
            ? Uint8List.sublistView(text, 0, size)
            : text;
        for (final quality in <int>[0, 1, 5]) {
          final stream = BrotliEncoderV2.encode(
            Uint8List.fromList(input),
            options: BrotliEncodeOptions(quality: quality),
          );
          expect(
            brotliDecompress(stream),
            orderedEquals(input),
            reason: 'size=$size q$quality',
          );
          expect(
            stream.length,
            lessThanOrEqualTo(BrotliEncoderV2.maxCompressedSize(size)),
          );
        }
      }
    });

    test('1 MiB text and binary at q0/q1/q5', () {
      for (final entry in <String, Uint8List>{
        'text': text,
        'binary': binary,
      }.entries) {
        for (final quality in <int>[0, 1, 5]) {
          final stream = BrotliEncoderV2.encode(
            entry.value,
            options: BrotliEncodeOptions(quality: quality),
          );
          expect(
            brotliDecompress(stream),
            orderedEquals(entry.value),
            reason: '${entry.key} q$quality',
          );
          expect(stream.length, lessThan(entry.value.length));
        }
      }
    });

    test('deterministic output', () {
      for (final quality in <int>[0, 1, 5]) {
        final first = BrotliEncoderV2.encode(
          text,
          options: BrotliEncodeOptions(quality: quality),
        );
        final second = BrotliEncoderV2.encode(
          text,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(second, orderedEquals(first), reason: 'q$quality');
      }
    });

    test('encodeInto matches encode and rejects short buffers', () {
      final expected = BrotliEncoderV2.encode(text);
      final destination = Uint8List(expected.length);
      final written = BrotliEncoderV2.encodeInto(destination, text);
      expect(written, expected.length);
      expect(destination, orderedEquals(expected));
      expect(
        () => BrotliEncoderV2.encodeInto(Uint8List(8), text),
        throwsArgumentError,
      );
    });

    test('q0/q1 route to the v1 encoder byte-for-byte', () {
      for (final quality in <int>[0, 1]) {
        final viaV2 = BrotliEncoderV2.encode(
          text,
          options: BrotliEncodeOptions(quality: quality),
        );
        final viaV1 = brotliCompress(
          text,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(viaV2, orderedEquals(viaV1), reason: 'q$quality delegation');
      }
      // Qualities 2..5 stay on the v2 fast path: on the 1 MiB text corpus the
      // v2 tier produces fewer bytes than v1 at q5.
      final v2q5 = BrotliEncoderV2.encode(text);
      final v1q5 = brotliCompress(text);
      expect(v2q5.length, lessThan(v1q5.length));
      expect(v2q5, isNot(orderedEquals(v1q5)));
    });

    test('binary q0/q1 use the v2 greedy binary tier', () {
      for (final quality in <int>[0, 1]) {
        final viaV2 = BrotliEncoderV2.encode(
          binary,
          options: BrotliEncodeOptions(quality: quality),
        );
        final viaV1 = brotliCompress(
          binary,
          options: BrotliEncodeOptions(quality: quality),
        );
        // The binary tier is a different (smaller) parse than v1's greedy one.
        expect(viaV2, isNot(orderedEquals(viaV1)), reason: 'q$quality');
        expect(
          viaV2.length,
          lessThanOrEqualTo(viaV1.length),
          reason: 'q$quality size',
        );
        expect(
          brotliDecompress(viaV2),
          orderedEquals(binary),
          reason: 'q$quality round-trip',
        );
      }
    });

    test('q2..q5 use the fast path and q6+ still round-trip', () {
      for (final quality in <int>[2, 3, 4, 5, 6, 9]) {
        final stream = BrotliEncoderV2.encode(
          text,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          brotliDecompress(stream),
          orderedEquals(text),
          reason: 'q$quality',
        );
      }
    });
  });

  group('BrotliEncoderV2 options', () {
    test('prepared/compound dictionaries keep working (v1 delegation)', () {
      final dictionary = Uint8List(16 * _kKiB);
      for (var i = 0; i < dictionary.length; i++) {
        dictionary[i] = text[i];
      }
      final input = Uint8List(60000);
      for (var i = 0; i < input.length; i++) {
        input[i] = dictionary[i % dictionary.length];
      }
      final prepared = BrotliPreparedDictionary(dictionary);
      for (final options in <BrotliEncodeOptions>[
        BrotliEncodeOptions(quality: 5, compoundDictionary: dictionary),
        BrotliEncodeOptions(quality: 5, preparedDictionary: prepared),
      ]) {
        final stream = BrotliEncoderV2.encode(input, options: options);
        expect(
          brotliDecompress(
            stream,
            options: BrotliDecodeOptions(compoundDictionary: dictionary),
          ),
          orderedEquals(input),
        );
      }
    });

    test('large window streams decode (v1 delegation)', () {
      final stream = BrotliEncoderV2.encode(
        text,
        options: const BrotliEncodeOptions(
          quality: 5,
          lgwin: 26,
          largeWindow: true,
        ),
      );
      expect(
        brotliDecompress(
          stream,
          options: const BrotliDecodeOptions(allowLargeWindow: true),
        ),
        orderedEquals(text),
      );
    });
  });

  group('v2 bit writers', () {
    test('64-bit VM and 32-bit Web writers produce identical bytes', () {
      final bits = <List<int>>[
        <int>[1, 1],
        <int>[2, 3],
        <int>[4, 11],
        <int>[16, 0xFFFF],
        <int>[20, 0xABCDE],
        <int>[24, 0xFEDCBA],
        <int>[32, 0x89ABCDEF],
        <int>[3, 5],
        <int>[7, 0x7F],
        <int>[0, 0],
      ];
      final vmWriter = vm.BitWriterV2();
      final jsWriter = js.BitWriterV2();
      for (final pair in bits) {
        vmWriter.writeBits(pair[0], pair[1]);
        jsWriter.writeBits(pair[0], pair[1]);
      }
      expect(jsWriter.bitPosition, vmWriter.bitPosition);
      expect(jsWriter.toBytes(), orderedEquals(vmWriter.toBytes()));
      // mark/rewind parity.
      final markVm = vmWriter.mark;
      final markJs = jsWriter.mark;
      vmWriter.writeBits(13, 0x1234);
      jsWriter.writeBits(13, 0x1234);
      vmWriter.rewind(markVm);
      jsWriter.rewind(markJs);
      expect(jsWriter.toBytes(), orderedEquals(vmWriter.toBytes()));
    });
  });

  group('v2 conformance with the Rust oracle', () {
    test(
      'q0/q1/q5 streams decode with the oracle',
      () async {
        for (final entry in <String, Uint8List>{
          'text': text,
          'binary': binary,
        }.entries) {
          for (final quality in <int>[0, 1, 5]) {
            final stream = BrotliEncoderV2.encode(
              entry.value,
              options: BrotliEncodeOptions(quality: quality),
            );
            final decoded = await _oracleRun(oracle, <String>[
              'decompress',
              '-i',
              '-',
              '-o',
              '-',
            ], stream);
            expect(
              decoded,
              orderedEquals(entry.value),
              reason: '${entry.key} q$quality',
            );
          }
        }
      },
      skip: oracleSkipReason,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

Future<Uint8List> _oracleRun(
  File oracle,
  List<String> arguments,
  Uint8List input,
) async {
  final process = await Process.start(oracle.path, arguments);
  final stdoutFuture = process.stdout.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(input);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final output = (await stdoutFuture).takeBytes();
  final errors = await stderrFuture;
  if (exitCode != 0) {
    throw StateError('oracle ${arguments.join(' ')} failed: $errors');
  }
  return output;
}
