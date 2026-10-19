@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/common/format_tables.dart'
    hide numDistanceShortCodes;
import 'package:brotli_neo/src/encoder/bit_writer.dart';
import 'package:brotli_neo/src/encoder/command.dart';
import 'package:brotli_neo/src/encoder/huffman_encoder.dart';
import 'package:brotli_neo/src/encoder/match_finder.dart';
import 'package:brotli_neo/src/encoder/metablock_writer.dart';
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

  group('length and distance coding', () {
    test('insert length codes cover their bases', () {
      for (var code = 0; code < kInsBase.length; code++) {
        final base = kInsBase[code];
        final extra = kInsExtra[code];
        expect(
          getInsertLengthCode(base),
          code,
          reason: 'insert base $base -> code $code',
        );
        final top = base + (1 << extra) - 1;
        expect(
          getInsertLengthCode(top),
          code,
          reason: 'insert top $top -> code $code',
        );
      }
      // Large inserts fall into the three wide codes.
      expect(getInsertLengthCode(6210), 22);
      expect(getInsertLengthCode(22593), 22);
      expect(getInsertLengthCode(22594), 23);
      expect(getInsertLengthCode(1 << 20), 23);
    });

    test('copy length codes cover their bases', () {
      for (var code = 0; code < kCopyBase.length; code++) {
        final base = kCopyBase[code];
        final extra = kCopyExtra[code];
        expect(
          getCopyLengthCode(base),
          code,
          reason: 'copy base $base -> code $code',
        );
        final top = base + (1 << extra) - 1;
        expect(
          getCopyLengthCode(top),
          code,
          reason: 'copy top $top -> code $code',
        );
      }
      expect(getCopyLengthCode(2118), 23);
      expect(getCopyLengthCode(1 << 20), 23);
    });

    test('command prefixes round-trip through the decoder command table', () {
      const insertLengths = <int>[
        1, 2, 5, 6, 7, 10, 20, 50, 100, 129, 130, 200, 1000, 2113, 2114, //
        6210, 22594, 70000,
      ];
      const copyLengths = <int>[
        2,
        3,
        4,
        5,
        9,
        10,
        50,
        133,
        134,
        1000,
        2117,
        2118,
        50000,
        131072,
      ];
      for (final useLast in <bool>[false, true]) {
        for (final insertLen in insertLengths) {
          for (final copyLen in copyLengths) {
            final cmd = getLengthCode(insertLen, copyLen, useLast);
            expect(cmd, inInclusiveRange(0, numCommandSymbols - 1));
            final base = cmd * 4;
            final extraBits = commandLookup[base] & 0xFF; // insert extra bits
            final copyExtraBits = (commandLookup[base] >> 8) & 0xFF;
            final insertBase = commandLookup[base + 1];
            final copyBase = commandLookup[base + 2];
            expect(
              insertLen - insertBase,
              inInclusiveRange(0, (1 << extraBits) - 1),
              reason: 'insert $insertLen code $cmd',
            );
            expect(
              copyLen - copyBase,
              inInclusiveRange(0, (1 << copyExtraBits) - 1),
              reason: 'copy $copyLen code $cmd',
            );
            // The implicit-distance form is only used for short codes; the
            // explicit form must always ask for a distance symbol.
            if (!useLast) {
              expect(cmd, greaterThanOrEqualTo(128));
            }
          }
        }
      }
      // The trailing insert-only command of a block: copy length 4 (code 2),
      // explicit distance group, but no copy, so no distance symbol is read.
      for (final insertLen in <int>[1, 5, 100, 70000, 1 << 20]) {
        final cmd = getLengthCode(insertLen, 4, false);
        expect(cmd, greaterThanOrEqualTo(128));
        final insertBase = commandLookup[cmd * 4 + 1];
        final extraBits = commandLookup[cmd * 4] & 0xFF;
        expect(
          insertLen - insertBase,
          inInclusiveRange(0, (1 << extraBits) - 1),
        );
      }
    });

    test('distance prefix codes decode back to the same distance', () {
      final lut = buildDistanceLut(0, 0, numDistanceSymbols);
      final cache = Int32List.fromList(<int>[4, 11, 15, 16]);
      final bits = Int32List(1);
      final extraOut = Int32List(1);
      for (var distance = 1; distance <= 70000; distance++) {
        final code = computeDistanceCode(distance, 1 << 24, cache);
        expect(code, greaterThanOrEqualTo(0));
        if (code >= numDistanceShortCodes) {
          final packed = prefixEncodeCopyDistance(code, 0, 0, bits, extraOut);
          final symbol = packed & 0x3FF;
          expect(packed >> 10, bits[0]);
          expect(symbol, inInclusiveRange(16, numDistanceSymbols - 1));
          expect(lut.extraBits[symbol], bits[0]);
          expect(
            lut.offset[symbol] + extraOut[0],
            distance,
            reason: 'distance $distance symbol $symbol',
          );
        }
      }
      // The short-code distances (cache hits and cache +- 1..3) are covered by
      // the oracle round-trips; spot-check the encoding of one of them.
      expect(computeDistanceCode(4, 1 << 24, cache), 0);
      expect(computeDistanceCode(11, 1 << 24, cache), 1);
      expect(computeDistanceCode(15, 1 << 24, cache), 2);
      expect(computeDistanceCode(16, 1 << 24, cache), 3);
      expect(computeDistanceCode(3, 1 << 24, cache), isNot(0));
      expect(computeDistanceCode(50, 1 << 24, cache), 50 + 15);
      // Distances above the window limit are never short codes.
      expect(computeDistanceCode(5000, 1000, cache), 5000 + 15);
    });

    test('distance cache cycling matches the decoder ring buffer', () {
      final cache = createInitialDistanceCache();
      // Distance 7 is `cache[0] + 3`, which the reference encodes as short code
      // 9 (the two 28-bit nibble tables cover cache[i] +- 1..3).
      expect(computeDistanceCode(4, 1 << 20, cache), 0);
      expect(computeDistanceCode(7, 1 << 20, cache), 9);
      expect(computeDistanceCode(3, 1 << 20, cache), 4);
      expect(computeDistanceCode(11, 1 << 20, cache), 1);
      expect(computeDistanceCode(15, 1 << 20, cache), 2);
      expect(computeDistanceCode(16, 1 << 20, cache), 3);
      // Pushing 7 to the front of the cache makes it short code 0.
      cache[3] = cache[2];
      cache[2] = cache[1];
      cache[1] = cache[0];
      cache[0] = 7;
      expect(computeDistanceCode(7, 1 << 20, cache), 0);
      expect(computeDistanceCode(4, 1 << 20, cache), 1);
      expect(cache, orderedEquals(<int>[7, 4, 11, 15]));
      // Distances above the window limit are never short codes.
      expect(computeDistanceCode(50, 1000, cache), 50 + 15);
    });
  });

  group('Huffman encoder invariants', () {
    test('random histograms build complete, depth-limited trees', () {
      final random = Random(20261020);
      final encoder = HuffmanEncoder();
      final histogram = Uint32List(numCommandSymbols);
      final depth = Uint8List(numCommandSymbols);
      final bits = Uint16List(numCommandSymbols);
      for (var iteration = 0; iteration < 200; iteration++) {
        histogram.fillRange(0, histogram.length, 0);
        final used = 2 + random.nextInt(numCommandSymbols - 2);
        for (var i = 0; i < used; i++) {
          histogram[random.nextInt(numCommandSymbols)] +=
              1 + random.nextInt(1 << 16);
        }
        var distinct = 0;
        for (final value in histogram) {
          if (value != 0) distinct++;
        }
        if (distinct < 2) continue;
        final writer = _BitWriterProbe();
        encoder.buildAndStore(
          histogram,
          histogram.length,
          numCommandSymbols,
          writer.writer,
          depth,
          bits,
        );
        var kraft = 0;
        var maxDepth = 0;
        for (var symbol = 0; symbol < histogram.length; symbol++) {
          if (histogram[symbol] == 0) {
            expect(depth[symbol], 0, reason: 'unused symbol has a depth');
            continue;
          }
          expect(depth[symbol], inInclusiveRange(1, 15));
          if (depth[symbol] > maxDepth) maxDepth = depth[symbol];
          kraft += 1 << (15 - depth[symbol]);
        }
        expect(kraft, 1 << 15, reason: 'Huffman code is not complete');
        expect(maxDepth, lessThanOrEqualTo(15));
        for (var symbol = 0; symbol < histogram.length; symbol++) {
          if (histogram[symbol] != 0) {
            expect(bits[symbol], lessThan(1 << depth[symbol]));
          }
        }
        // For a complete canonical code, distinct code values per depth plus a
        // full Kraft sum imply a prefix-free (uniquely decodable) code.
        final codesByDepth = <int, List<int>>{};
        for (var symbol = 0; symbol < histogram.length; symbol++) {
          final d = depth[symbol];
          if (d == 0) continue;
          (codesByDepth[d] ??= <int>[]).add(bits[symbol]);
        }
        for (final entry in codesByDepth.entries) {
          expect(
            entry.value.toSet().length,
            entry.value.length,
            reason: 'duplicate canonical code at depth ${entry.key}',
          );
        }
      }
    });

    test('code-length codes stay at depth 5 or less', () {
      final random = Random(7);
      final encoder = HuffmanEncoder();
      final histogram = Uint32List(kNumCodeLengthCodes);
      final depth = Uint8List(kNumCodeLengthCodes);
      for (var iteration = 0; iteration < 300; iteration++) {
        histogram.fillRange(0, histogram.length, 0);
        depth.fillRange(0, depth.length, 0);
        for (var i = 0; i < kNumCodeLengthCodes; i++) {
          if (random.nextInt(3) == 0) histogram[i] = 1 + random.nextInt(50);
        }
        encoder.createHuffmanTree(histogram, kNumCodeLengthCodes, 5, depth);
        var used = 0;
        for (var i = 0; i < histogram.length; i++) {
          if (histogram[i] == 0) continue;
          used++;
          expect(depth[i], inInclusiveRange(1, 5));
        }
        if (used <= 1) {
          // A single-symbol tree is never serialised through this path (the
          // encoder writes a simple code instead) and is not "complete".
          continue;
        }
        var kraft = 0;
        for (var i = 0; i < histogram.length; i++) {
          if (depth[i] != 0) kraft += 1 << (5 - depth[i]);
        }
        expect(kraft, 1 << 5);
      }
    });
  });

  group('quality 0/1 oracle round-trip', () {
    for (final quality in <int>[0, 1]) {
      test('quality $quality: boundary sizes up to 1 MiB', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, //
          255, 256, 257, 1023, 1024, 1025, 4095, 4096, 65535, 65536, 65537,
          131071, 131072, 131073,
        ];
        for (final kind in _DataKind.values) {
          for (final size in sizes) {
            final input = _data(kind, size);
            final output = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            );
            await _expectRoundTrip(
              oracle,
              input,
              output,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('quality $quality: sizes around 1 MiB', () async {
        for (final kind in _DataKind.values) {
          for (final size in <int>[_kMiB - 1, _kMiB, _kMiB + 1]) {
            final input = _data(kind, size);
            final output = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            );
            await _expectRoundTrip(
              oracle,
              input,
              output,
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('quality $quality: mixed compressible/incompressible blocks', () async {
        // Middle block is random: it is stored uncompressed, which must not
        // disturb the distance cache state for the following compressed block.
        final mixed = Uint8List.fromList(<int>[
          ..._data(_DataKind.text, 64 * _kKiB),
          ..._data(_DataKind.random, 64 * _kKiB),
          ..._data(_DataKind.text, 64 * _kKiB),
        ]);
        final output = brotliCompress(
          mixed,
          options: BrotliEncodeOptions(quality: quality),
        );
        await _expectRoundTrip(oracle, mixed, output, reason: 'mixed blocks');

        final mixedLarge = Uint8List.fromList(<int>[
          ..._data(_DataKind.text, 128 * _kKiB),
          ..._data(_DataKind.random, 128 * _kKiB),
          ..._data(_DataKind.text, 128 * _kKiB),
          ..._data(_DataKind.zeros, 96 * _kKiB),
        ]);
        final outputLarge = brotliCompress(
          mixedLarge,
          options: BrotliEncodeOptions(quality: quality),
        );
        await _expectRoundTrip(
          oracle,
          mixedLarge,
          outputLarge,
          reason: 'mixed blocks (large)',
        );
      });

      test('quality $quality: adversarial payloads round-trip', () async {
        final cases = <String, Uint8List>{
          'small alphabet': _smallAlphabet(50000, 4, 1),
          'small alphabet 16': _smallAlphabet(200000, 16, 2),
          'word soup': _wordSoup(120000, 3),
          'long literal run': _longLiteralRun(),
          'copy-from-history': _copyFromHistory(200000, 1),
          'copy-from-history wide': _copyFromHistory(
            180000,
            2,
            maxDistance: 120000,
          ),
          'rle runs': _rleRuns(150000, 4),
          'block boundary text': _data(_DataKind.text, 2 * 65536 + 333),
        };
        for (final entry in cases.entries) {
          final output = brotliCompress(
            entry.value,
            options: BrotliEncodeOptions(quality: quality),
          );
          await _expectRoundTrip(
            oracle,
            entry.value,
            output,
            reason: 'q$quality ${entry.key}',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('quality $quality: every window size round-trips', () async {
        final input = _data(_DataKind.text, 70000);
        for (var lgwin = 10; lgwin <= 24; lgwin++) {
          final output = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality, lgwin: lgwin),
          );
          await _expectRoundTrip(
            oracle,
            input,
            output,
            reason: 'q$quality lgwin $lgwin',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('quality $quality: deterministic output', () {
        final input = _data(_DataKind.text, 100000);
        final first = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        final second = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(second, orderedEquals(first));
        // A different window setting must not yield the same stream (the
        // header differs), and must still be deterministic.
        final other = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality, lgwin: 20),
        );
        expect(other, isNot(orderedEquals(first)));
        expect(
          brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality, lgwin: 20),
          ),
          orderedEquals(other),
        );
      });
    }
  });

  group('quality 0/1 size behaviour', () {
    test('empty input is the canonical [0x06] for every quality', () {
      for (final quality in <int>[0, 1, 2, 5, 11]) {
        expect(
          brotliCompress(
            Uint8List(0),
            options: BrotliEncodeOptions(quality: quality),
          ),
          orderedEquals(<int>[0x06]),
        );
      }
    });

    test('output never exceeds maxCompressedSize', () {
      for (final quality in <int>[0, 1]) {
        for (final kind in _DataKind.values) {
          for (final size in <int>[1, 2, 17, 1000, 65536, _kMiB]) {
            final input = _data(kind, size);
            final output = brotliCompress(
              input,
              options: BrotliEncodeOptions(quality: quality),
            );
            expect(
              output.length,
              lessThanOrEqualTo(maxCompressedSize(input.length)),
              reason: 'q$quality ${kind.name} $size',
            );
          }
        }
      }
    });

    test('incompressible input stays within a few bytes of the input', () {
      for (final quality in <int>[0, 1]) {
        for (final size in <int>[1, 1000, 65536, 262144]) {
          final input = _data(_DataKind.random, size);
          final output = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          expect(
            output.length,
            lessThanOrEqualTo(size + 4 * (size ~/ 16384) + 8),
          );
        }
      }
    });

    test('compressible input gets much smaller', () {
      for (final quality in <int>[0, 1]) {
        final zeros = brotliCompress(
          _data(_DataKind.zeros, _kMiB),
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(zeros.length, lessThan(1000), reason: 'q$quality zeros');
        final repetitive = brotliCompress(
          _data(_DataKind.repetitive, 256 * _kKiB),
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          repetitive.length,
          lessThan(4096),
          reason: 'q$quality repetitive',
        );
        final text = brotliCompress(
          _data(_DataKind.text, 256 * _kKiB),
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          text.length,
          lessThan(256 * _kKiB ~/ 2),
          reason: 'q$quality text',
        );
      }
    });

    test('single-byte inputs round-trip', () async {
      for (final quality in <int>[0, 1]) {
        for (final value in <int>[0x00, 0x01, 0x61, 0x7F, 0x80, 0xFF]) {
          final input = Uint8List.fromList(<int>[value]);
          final output = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          await _expectRoundTrip(
            oracle,
            input,
            output,
            reason: 'q$quality byte 0x${value.toRadixString(16)}',
          );
        }
      }
    });

    test('input larger than 2^24 round-trips', () async {
      final input = _data(_DataKind.repetitive, (1 << 24) + 1);
      for (final quality in <int>[0, 1]) {
        final output = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          output.length,
          lessThanOrEqualTo(maxCompressedSize(input.length)),
        );
        final decoded = await _oracleDecompress(oracle, output);
        expect(decoded.length, input.length, reason: 'q$quality 2^24+1');
        expect(_sha256(decoded), orderedEquals(_sha256(input)));
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: oracleSkipReason);

  group('ratio versus the Rust oracle', () {
    test('report size ratios at quality 0 and 1', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textSource,
        'text-256k': _data(_DataKind.text, 256 * _kKiB),
        'text-1m': _data(_DataKind.text, _kMiB),
        'repetitive-256k': _data(_DataKind.repetitive, 256 * _kKiB),
        'zeros-1m': _data(_DataKind.zeros, _kMiB),
        'random-256k': _data(_DataKind.random, 256 * _kKiB),
        'utf8-cjk-256k': _data(_DataKind.cjk, 256 * _kKiB),
      };
      final report = StringBuffer('ratio report (ours / Rust brotli crate):\n');
      for (final quality in <int>[0, 1]) {
        for (final entry in cases.entries) {
          final input = entry.value;
          final ours = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          final rust = await _oracleCompress(oracle, input, quality);
          final ratio = ours.length / rust.length;
          report.writeln(
            '  q$quality ${entry.key.padRight(15)} '
            'in=${input.length.toString().padLeft(8)} '
            'ours=${ours.length.toString().padLeft(8)} '
            'rust=${rust.length.toString().padLeft(8)} '
            'ratio=${ratio.toStringAsFixed(4)}',
          );
          if (entry.key == 'random-256k') {
            // Incompressible data: both fall back to ~uncompressed framing.
            expect(ours.length, lessThanOrEqualTo(input.length + 64));
          } else {
            // Loose bound only; the greedy path should be at least in the same
            // league as the reference fast path (usually better on repetitive
            // input because our hash table is persistent across blocks).
            expect(
              ours.length,
              lessThanOrEqualTo(rust.length * 1.6 + 128),
              reason: 'q$quality ${entry.key} is unexpectedly large',
            );
            expect(ours.length, lessThan(input.length));
          }
        }
      }
      // Show the table in `dart test` output for the task report.
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: oracleSkipReason);

  group('helper edge cases', () {
    test('uncompressed meta-block size matches what is written', () {
      for (final length in <int>[1, 2, 16, 65535, 65536, 65537, 1 << 20]) {
        final writer = _BitWriterProbe();
        final start = writer.writer.bitPosition;
        writeUncompressedMetaBlock(writer.writer, Uint8List(length), 0, length);
        expect(
          writer.writer.bitPosition - start,
          uncompressedMetaBlockBits(length, start),
          reason: 'length $length',
        );
        expect(writer.writer.isByteAligned, isTrue);
      }
      // A non-byte-aligned start pads to the next byte boundary.
      final writer = _BitWriterProbe()..writer.writeBits(3, 0x5);
      final start = writer.writer.bitPosition;
      writeUncompressedMetaBlock(writer.writer, Uint8List(10), 0, 10);
      expect(
        writer.writer.bitPosition - start,
        uncompressedMetaBlockBits(10, start),
      );
    });

    test('match finder hashes stay inside the table', () {
      final input = _data(_DataKind.text, 4096);
      for (final bits in <int>[8, 12, 16, 17]) {
        final finder = MatchFinder(tableBits: bits, minMatch: 4);
        for (var pos = 0; pos + 4 <= input.length; pos++) {
          expect(
            finder.hashAt(input, pos),
            inInclusiveRange(0, (1 << bits) - 1),
          );
        }
        final finder6 = MatchFinder(tableBits: bits, minMatch: 6);
        for (var pos = 0; pos + 6 <= input.length; pos++) {
          expect(
            finder6.hashAt(input, pos),
            inInclusiveRange(0, (1 << bits) - 1),
          );
        }
      }
    });

    test('match length compares overlapping ranges correctly', () {
      final input = Uint8List.fromList(<int>[...List<int>.filled(10, 7), 1, 2]);
      // Comparing offset 1 against offset 0 matches 9 bytes (the 10th differs).
      expect(findMatchLength(input, 1, 0, input.length - 1), 9);
      expect(read32le(input, 0), 0x07070707);
      expect(isMatch(input, 0, 1, 4), isTrue);
      expect(isMatch(input, 7, 8, 4), isFalse);
      // Copying distance 1 across an overlap stays byte-identical.
      final run = Uint8List.fromList(List<int>.filled(64, 0xAB));
      expect(findMatchLength(run, 1, 0, run.length - 1), 63);
    });
  });
}

// ---------------------------------------------------------------------------
// BitWriter probe
// ---------------------------------------------------------------------------

final class _BitWriterProbe {
  final BitWriter writer = BitWriter();
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

enum _DataKind { text, repetitive, random, zeros, cjk, all256 }

final Uint8List _textSource = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.zeros:
      return Uint8List(size);
    case _DataKind.all256:
      final pattern = Uint8List.fromList(List<int>.generate(256, (i) => i));
      return _repeatToSize(pattern, size);
    case _DataKind.cjk:
      final pattern = utf8.encode('绾?Dart 瀹炵幇鐨?Brotli 缂栫爜鍣紝浣撶Н涓庨€熷害鐨勫钩琛?0123456789 ');
      return _repeatToSize(pattern, size);
    case _DataKind.repetitive:
      final pattern = utf8.encode(
        'brotli_neo stage-1 greedy lz77 + dynamic huffman 0123456789 abcdefghij ',
      );
      return _repeatToSize(pattern, size);
    case _DataKind.text:
      return _repeatToSize(_textSource, size);
    case _DataKind.random:
      final random = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextInt(256);
      }
      return out;
  }
}

Uint8List _repeatToSize(List<int> pattern, int size) {
  final out = Uint8List(size);
  if (pattern.isEmpty) return out;
  for (var i = 0; i < size; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}

/// Random bytes from a small alphabet: many short matches at varied distances.
Uint8List _smallAlphabet(int size, int alphabetSize, int seed) {
  final random = Random(seed);
  const source =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = source.codeUnitAt(random.nextInt(alphabetSize));
  }
  return out;
}

/// Random words from a tiny dictionary: long-range matches across blocks.
Uint8List _wordSoup(int size, int seed) {
  final random = Random(seed);
  const words = <String>[
    'brotli', 'dart', 'encoder', 'huffman', 'window', 'greedy', 'match', //
    'dictionary', 'compression', 'stream', 'meta', 'block', 'literal',
  ];
  final builder = BytesBuilder();
  while (builder.length < size) {
    builder.add(utf8.encode(words[random.nextInt(words.length)]));
    builder.addByte(0x20);
  }
  return Uint8List.sublistView(builder.takeBytes(), 0, size);
}

/// A long incompressible literal prefix followed by a long copy run: exercises
/// insert-length code 23 (24 extra bits) together with a huge copy.
Uint8List _longLiteralRun() {
  final random = Random(99);
  final out = Uint8List(70000);
  for (var i = 0; i < 38000; i++) {
    out[i] = random.nextInt(200) + 40;
  }
  return out;
}

/// Builds data by copying random chunks from earlier output; [maxDistance]
/// bounds the copy distances so different distance-code groups are exercised.
Uint8List _copyFromHistory(int size, int seed, {int maxDistance = 1 << 18}) {
  final random = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    if (i > 16 && random.nextInt(10) != 0) {
      final limit = i < maxDistance ? i : maxDistance;
      final distance = 1 + random.nextInt(limit);
      out[i] = out[i - distance];
    } else {
      out[i] = random.nextInt(256);
    }
  }
  return out;
}

/// Alternating runs of distinct bytes, like simple binary images.
Uint8List _rleRuns(int size, int seed) {
  final random = Random(seed);
  final out = Uint8List(size);
  var pos = 0;
  while (pos < size) {
    final value = random.nextInt(256);
    final length = 1 + random.nextInt(300);
    final end = pos + length < size ? pos + length : size;
    out.fillRange(pos, end, value);
    pos = end;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Oracle helpers
// ---------------------------------------------------------------------------

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
  final stdoutBytes = (await stdoutFuture).takeBytes();
  final stderrText = await stderrFuture;
  if (exitCode != 0) {
    throw StateError(
      'oracle ${arguments.join(' ')} failed (exit $exitCode): $stderrText',
    );
  }
  return stdoutBytes;
}

Future<Uint8List> _oracleDecompress(File oracle, Uint8List compressed) =>
    _oracleRun(oracle, <String>[
      'decompress',
      '-i',
      '-',
      '-o',
      '-',
    ], compressed);

Future<Uint8List> _oracleCompress(File oracle, Uint8List input, int quality) =>
    _oracleRun(oracle, <String>[
      'compress',
      '-q',
      '$quality',
      '-i',
      '-',
      '-o',
      '-',
    ], input);

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

Future<void> _expectRoundTrip(
  File oracle,
  Uint8List input,
  Uint8List compressed, {
  required String reason,
}) async {
  expect(
    compressed.length,
    lessThanOrEqualTo(maxCompressedSize(input.length)),
    reason: '$reason: output exceeds maxCompressedSize',
  );
  final decoded = await _oracleDecompress(oracle, compressed);
  expect(decoded.length, input.length, reason: '$reason: decoded length');
  expect(
    _sha256(decoded),
    orderedEquals(_sha256(input)),
    reason: '$reason: decoded SHA-256',
  );
}
