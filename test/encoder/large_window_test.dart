@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Set `BROTLI_ORACLE` to the authoritative Rust oracle executable.
final String? _oracleEnv = Platform.environment['BROTLI_ORACLE'];

const int _kKiB = 1024;
const int _kMiB = 1 << 20;

void main() {
  final oracle = File(_oracleEnv ?? '');
  final String? oracleSkipReason = _oracleEnv == null || !oracle.existsSync()
      ? 'set BROTLI_ORACLE to the Rust oracle executable'
      : null;

  group('large-window streams', () {
    test('header is the 14-bit large-window extension', () {
      final input = _text(1000);
      for (final lgwin in <int>[25, 26, 30]) {
        final stream = brotliCompress(
          input,
          options: BrotliEncodeOptions(lgwin: lgwin, largeWindow: true),
        );
        expect(_readLargeWindowHeader(stream), lgwin);
        // The same data without the large-window opt-in is a regular stream.
        final regular = brotliCompress(
          input,
          options: const BrotliEncodeOptions(lgwin: 24),
        );
        expect(_readLargeWindowHeader(regular), isNull);
      }
    });

    test('our decoder decodes them only with allowLargeWindow', () {
      final input = _text(200000);
      for (final lgwin in <int>[25, 30]) {
        final stream = brotliCompress(
          input,
          options: BrotliEncodeOptions(lgwin: lgwin, largeWindow: true),
        );
        final decoded = brotliDecompress(
          stream,
          options: const BrotliDecodeOptions(allowLargeWindow: true),
        );
        expect(decoded, orderedEquals(input), reason: 'lgwin $lgwin');
        expect(
          () => brotliDecompress(stream),
          throwsA(isA<BrotliException>()),
          reason: 'lgwin $lgwin must be rejected without the opt-in',
        );
      }
    });

    test('Rust oracle decodes q0/q1/q4/q5/q8/q11 at lgwin 25/26/30', () async {
      final cases = <String, Uint8List>{
        'text-2m': _text(2 * _kMiB),
        'cjk-300k': _variedCjk(300 * _kKiB, 3),
        'binary-300k': _binary(300 * _kKiB, 5),
      };
      for (final entry in cases.entries) {
        for (final quality in <int>[0, 1, 4, 5, 8, 11]) {
          for (final lgwin in <int>[25, 26, 30]) {
            final stream = brotliCompress(
              entry.value,
              options: BrotliEncodeOptions(
                quality: quality,
                lgwin: lgwin,
                largeWindow: true,
              ),
            );
            final decoded = await _oracleDecompress(oracle, stream);
            expect(
              _sha256(decoded),
              orderedEquals(_sha256(entry.value)),
              reason: '${entry.key} q$quality lgwin $lgwin',
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(minutes: 12)));

    test('streaming encoder supports large windows with flushes', () async {
      final input = _text(500000);
      final options = const BrotliEncodeOptions(
        quality: 5,
        lgwin: 30,
        largeWindow: true,
      );
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
      final stream = Uint8List.fromList(output);
      expect(encoder.isFinished, isTrue);
      expect(encoder.bytesWritten, stream.length);
      expect(_readLargeWindowHeader(stream), 30);
      final decoded = await _oracleDecompress(oracle, stream);
      expect(_sha256(decoded), orderedEquals(_sha256(input)));
      expect(
        brotliDecompress(
          stream,
          options: const BrotliDecodeOptions(allowLargeWindow: true),
        ),
        orderedEquals(input),
      );
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('returns the same bytes as a one-shot encode', () {
      final input = _text(150000);
      final options = const BrotliEncodeOptions(
        quality: 5,
        lgwin: 26,
        largeWindow: true,
      );
      final encoder = BrotliEncoder(options: options)
        ..add(Bytes.fromUint8List(input))
        ..finish();
      expect(
        encoder.takeOutputBytes(),
        orderedEquals(brotliCompress(input, options: options)),
      );
    });

    test('invalid combinations throw BrotliException', () {
      final input = _text(1000);
      expect(
        () => brotliCompress(
          input,
          options: const BrotliEncodeOptions(lgwin: 25),
        ),
        throwsA(isA<BrotliException>()),
      );
      expect(
        () => BrotliEncoder(options: const BrotliEncodeOptions(lgwin: 30)),
        throwsA(isA<BrotliException>()),
      );
      // lgwin 22 with the flag still produces a regular (non-large) stream.
      final regular = brotliCompress(
        input,
        options: const BrotliEncodeOptions(lgwin: 22, largeWindow: true),
      );
      expect(_readLargeWindowHeader(regular), isNull);
      expect(brotliDecompress(regular), orderedEquals(input));
    });

    test('deterministic and bounded', () {
      final input = _text(120000);
      final options = const BrotliEncodeOptions(
        quality: 8,
        lgwin: 30,
        largeWindow: true,
      );
      final first = brotliCompress(input, options: options);
      expect(brotliCompress(input, options: options), orderedEquals(first));
      expect(first.length, lessThanOrEqualTo(maxCompressedSize(input.length)));
    });
  });

  group('ratio versus the Rust oracle', () {
    test('report large-window sizes against Rust', () async {
      final input = _text(2 * _kMiB);
      final report = StringBuffer('large-window report (ours / Rust):\n');
      for (final quality in <int>[5, 11]) {
        final ours = brotliCompress(
          input,
          options: BrotliEncodeOptions(
            quality: quality,
            lgwin: 30,
            largeWindow: true,
          ),
        );
        final rust = await _oracleCompress(
          oracle,
          input,
          quality,
          lgwin: 30,
        );
        report.writeln(
          '  q$quality lgwin 30 in=${input.length} ours=${ours.length} '
          'rust=${rust.length} '
          'ratio=${(ours.length / rust.length).toStringAsFixed(4)}',
        );
        expect(ours.length / rust.length, lessThan(1.3));
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the lgwin of a large-window header, or null for a regular stream.
int? _readLargeWindowHeader(Uint8List stream) {
  var bit = 0;
  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= ((stream[bit >> 3] >> (bit & 7)) & 1) << i;
      bit++;
    }
    return value;
  }

  if (readBits(1) == 0) return null; // lgwin 16
  final n1 = readBits(3);
  if (n1 != 0) return null; // regular 17..24
  final n2 = readBits(3);
  if (n2 != 1) return null; // reserved / regular 8+n2
  expect(readBits(1), 0, reason: 'reserved bit after the large-window marker');
  return readBits(6);
}

final Uint8List _alice = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();

Uint8List _text(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = _alice[i % _alice.length];
  }
  return out;
}

Uint8List _binary(int size, int seed) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List _variedCjk(int size, int seed) {
  final random = Random(seed);
  final builder = StringBuffer();
  while (builder.length < size) {
    builder.writeCharCode(0x4E00 + random.nextInt(2000));
    if (random.nextInt(8) == 0) builder.write(' ');
  }
  final bytes = utf8.encode(builder.toString());
  return Uint8List.fromList(bytes.take(size).toList());
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

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
    throw StateError(
      'oracle ${arguments.join(' ')} failed ($exitCode): $errors',
    );
  }
  return output;
}

Future<Uint8List> _oracleDecompress(File oracle, Uint8List compressed) =>
    _oracleRun(oracle, <String>[
      'decompress',
      '--large-window',
      '-i',
      '-',
      '-o',
      '-',
    ], compressed);

Future<Uint8List> _oracleCompress(
  File oracle,
  Uint8List input,
  int quality, {
  required int lgwin,
}) => _oracleRun(oracle, <String>[
  'compress',
  '-q',
  '$quality',
  '-w',
  '$lgwin',
  '--large-window',
  '-i',
  '-',
  '-o',
  '-',
], input);
