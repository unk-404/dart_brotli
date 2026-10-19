@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final oracle = File(_oracleEnv ?? '');

  group('one-shot parity', () {
    test('a single add + finish equals brotliCompress', () {
      final input = _data(70 * _kKiB);
      for (final quality in <int>[0, 1, 2, 5, 8, 11]) {
        for (final lgwin in <int>[10, 16, 22]) {
          final options = BrotliEncodeOptions(quality: quality, lgwin: lgwin);
          final expected = brotliCompress(input, options: options);
          final encoder = BrotliEncoder(options: options)
            ..add(Bytes.fromUint8List(input))
            ..finish();
          expect(
            encoder.takeOutputBytes(),
            orderedEquals(expected),
            reason: 'q$quality lgwin $lgwin',
          );
          expect(encoder.isFinished, isTrue);
          expect(encoder.bytesWritten, expected.length);
        }
      }
    });

    test('empty input + finish is a valid empty stream', () {
      final encoder = BrotliEncoder()..finish();
      final output = encoder.takeOutputBytes();
      expect(output, isNotEmpty);
      expect(encoder.bytesWritten, output.length);
      expect(output.length, lessThanOrEqualTo(maxCompressedSize(0)));
      expect(brotliDecompress(output), isEmpty);
    });

    test('single byte input', () {
      final input = Uint8List.fromList(<int>[0x41]);
      final encoder = BrotliEncoder()..addUint8List(input)..finish();
      final output = encoder.takeOutputBytes();
      expect(output, orderedEquals(brotliCompress(input)));
      expect(brotliDecompress(output), orderedEquals(input));
    });
  });

  group('flush boundaries', () {
    test('flush makes output available without ending the stream', () {
      final input = _data(30000);
      final encoder = BrotliEncoder(options: const BrotliEncodeOptions(quality: 5));
      encoder.add(Bytes.fromUint8List(Uint8List.sublistView(input, 0, 10000)));
      expect(encoder.takeOutputBytes(), isEmpty);
      encoder.flush();
      final firstPart = encoder.takeOutputBytes();
      expect(firstPart, isNotEmpty);
      expect(encoder.isFinished, isFalse);
      // A second flush with no pending data produces nothing.
      encoder.flush();
      expect(encoder.takeOutputBytes(), isEmpty);
      encoder.add(Bytes.fromUint8List(Uint8List.sublistView(input, 10000)));
      encoder.finish();
      final rest = encoder.takeOutputBytes();
      expect(rest, isNotEmpty);
      expect(encoder.isFinished, isTrue);
      final whole = <int>[...firstPart, ...rest];
      expect(brotliDecompress(Uint8List.fromList(whole)), orderedEquals(input));
    });

    test('flush with pending data then continuing keeps one valid stream', () {
      final input = _data(200000);
      final encoder = BrotliEncoder(
        options: const BrotliEncodeOptions(quality: 5),
      );
      final output = <int>[];
      var flushes = 0;
      for (var offset = 0; offset < input.length; offset += 17000) {
        final end = min(offset + 17000, input.length);
        encoder.add(
          Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)),
        );
        if (offset % 34000 == 0) {
          encoder.flush();
          flushes++;
        }
        output.addAll(encoder.takeOutputBytes());
      }
      encoder.finish();
      output.addAll(encoder.takeOutputBytes());
      expect(flushes, greaterThan(1));
      expect(brotliDecompress(Uint8List.fromList(output)), orderedEquals(input));
    });
  });

  group('numeric round-trip', () {
    test('chunk sizes 1/2/3/7/4096 round-trip through the Rust oracle',
        () async {
      final input = _data(60000);
      for (final chunkSize in <int>[1, 2, 3, 7, 4096]) {
        for (final quality in <int>[0, 1, 4, 5, 8, 11]) {
          for (final lgwin in <int>[10, 16, 22, 24]) {
            final options = BrotliEncodeOptions(
              quality: quality,
              lgwin: lgwin,
            );
            final output = _buildChunked(input, options, chunkSize);
            expect(
              output.length,
              lessThanOrEqualTo(maxCompressedSize(input.length)),
              reason: 'bound q$quality lgwin $lgwin chunk $chunkSize',
            );
            final decoded = await _oracleDecompress(oracle, output);
            expect(
              _sha256(decoded),
              orderedEquals(_sha256(input)),
              reason: 'q$quality lgwin $lgwin chunk $chunkSize',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('flushed chunks round-trip (quality 0/1/5/11)', () async {
      final input = _data(120000);
      for (final quality in <int>[0, 1, 5, 11]) {
        final options = BrotliEncodeOptions(quality: quality);
        final encoder = BrotliEncoder(options: options);
        final output = <int>[];
        for (var offset = 0; offset < input.length; offset += 7000) {
          final end = min(offset + 7000, input.length);
          encoder.add(
            Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)),
          );
          encoder.flush();
          output.addAll(encoder.takeOutputBytes());
        }
        encoder.finish();
        output.addAll(encoder.takeOutputBytes());
        final decoded = await _oracleDecompress(
          oracle,
          Uint8List.fromList(output),
        );
        expect(
          _sha256(decoded),
          orderedEquals(_sha256(input)),
          reason: 'q$quality flush per chunk',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('1 MiB, repetitive and random inputs round-trip', () async {
      final cases = <String, Uint8List>{
        'text-1m': _data(_kMiB),
        'zeros-1m': Uint8List(_kMiB),
        'random-256k': Uint8List.fromList(
          List<int>.generate(256 * _kKiB, (i) => Random(7).nextInt(256)),
        ),
      };
      for (final entry in cases.entries) {
        for (final quality in <int>[0, 5, 11]) {
          final output = <int>[];
          final encoder = BrotliEncoder(
            options: BrotliEncodeOptions(quality: quality),
          );
          for (var offset = 0; offset < entry.value.length; offset += 100000) {
            final end = min(offset + 100000, entry.value.length);
            encoder.add(
              Bytes.fromUint8List(
                Uint8List.sublistView(entry.value, offset, end),
              ),
            );
            if (offset % 200000 == 0) encoder.flush();
            output.addAll(encoder.takeOutputBytes());
          }
          encoder.finish();
          output.addAll(encoder.takeOutputBytes());
          final bytes = Uint8List.fromList(output);
          expect(
            bytes.length,
            lessThanOrEqualTo(maxCompressedSize(entry.value.length)),
            reason: '${entry.key} q$quality bound',
          );
          final decoded = await _oracleDecompress(oracle, bytes);
          expect(
            _sha256(decoded),
            orderedEquals(_sha256(entry.value)),
            reason: '${entry.key} q$quality',
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 12)));
  });

  group('API behaviour', () {
    test('deterministic across encoder instances', () {
      final input = _data(80000);
      List<int> run() {
        final encoder = BrotliEncoder(
          options: const BrotliEncodeOptions(quality: 8),
        );
        final output = <int>[];
        for (var offset = 0; offset < input.length; offset += 4096) {
          final end = min(offset + 4096, input.length);
          encoder.add(
            Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)),
          );
          encoder.flush();
          output.addAll(encoder.takeOutputBytes());
        }
        encoder.finish();
        output.addAll(encoder.takeOutputBytes());
        return output;
      }

      expect(run(), orderedEquals(run()));
    });

    test('invalid states throw StateError', () {
      final encoder = BrotliEncoder()..finish();
      expect(
        () => encoder.add(Bytes.fromUint8List(Uint8List(4))),
        throwsStateError,
      );
      expect(encoder.flush, throwsStateError);
      expect(encoder.finish, throwsStateError);
      // The empty stream produced by finish() is still available, once.
      expect(encoder.takeOutputBytes(), isNotEmpty);
      expect(encoder.takeOutputBytes(), isEmpty);
    });

    test('takeOutput drains and bytesWritten counts produced bytes', () {
      final encoder = BrotliEncoder()
        ..addUint8List(
          Uint8List.fromList(List<int>.generate(50000, (i) => i & 0xFF)),
        )
        ..flush()
        ..finish();
      final output = encoder.takeOutputBytes();
      expect(output, isNotEmpty);
      expect(encoder.bytesWritten, output.length);
      expect(encoder.takeOutputBytes(), isEmpty);
      expect(brotliDecompress(output).length, 50000);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _buildChunked(
  Uint8List input,
  BrotliEncodeOptions options,
  int chunkSize,
) {
  final encoder = BrotliEncoder(options: options);
  final output = <int>[];
  for (var offset = 0; offset < input.length; offset += chunkSize) {
    final end = min(offset + chunkSize, input.length);
    encoder.add(Bytes.fromUint8List(Uint8List.sublistView(input, offset, end)));
    output.addAll(encoder.takeOutputBytes());
  }
  encoder.finish();
  output.addAll(encoder.takeOutputBytes());
  return Uint8List.fromList(output);
}

/// 1 MiB of repeated `alice29.txt` (or a fixed pattern for smaller requests).
Uint8List _data(int size) {
  final pattern = File('test/testdata/alice29.txt').readAsBytesSync();
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

Future<Uint8List> _oracleDecompress(File oracle, Uint8List compressed) async {
  final process = await Process.start(oracle.path, <String>[
    'decompress',
    '-i',
    '-',
    '-o',
    '-',
  ]);
  final stdoutFuture = process.stdout.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (builder, chunk) => builder..add(chunk),
  );
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(compressed);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  final output = (await stdoutFuture).takeBytes();
  final errors = await stderrFuture;
  if (exitCode != 0) {
    throw StateError('oracle decompress failed ($exitCode): $errors');
  }
  return output;
}
