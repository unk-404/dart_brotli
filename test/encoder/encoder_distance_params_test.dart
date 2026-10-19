@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli_neo/brotli_neo.dart';
import 'package:brotli_neo/src/encoder/backward_references.dart';
import 'package:brotli_neo/src/encoder/bit_writer.dart';
import 'package:brotli_neo/src/encoder/block_split.dart';
import 'package:brotli_neo/src/encoder/command.dart';
import 'package:brotli_neo/src/encoder/distance_params.dart';
import 'package:brotli_neo/src/encoder/histogram_optimizer.dart';
import 'package:brotli_neo/src/encoder/match_finder.dart';
import 'package:brotli_neo/src/encoder/split_metablock_writer.dart';
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

  group('distance parameters', () {
    test('alphabet sizes and distance limits follow RFC 7932', () {
      expect(kDefaultDistanceParams.npostfix, 0);
      expect(kDefaultDistanceParams.ndirect, 0);
      expect(kDefaultDistanceParams.alphabetSize, numDistanceSymbols);
      expect(kDefaultDistanceParams.maxDistance, (1 << 26) - 4);
      expect(distanceAlphabetSize(0, 7), 71);
      expect(distanceAlphabetSize(1, 12), 16 + 12 + (24 << 2));
      expect(distanceAlphabetSize(2, 8), 16 + 8 + (24 << 3));
      expect(distanceAlphabetSize(3, 0), 16 + (24 << 4));
      expect(distanceAlphabetSize(3, 120), 16 + 120 + (24 << 4));
      // More postfix bits always widen the alphabet.
      expect(distanceMaxValue(0, 0), 67108860);
      expect(distanceMaxValue(1, 0), (1 << 27) - 8);
      expect(distanceMaxValue(3, 120), 120 + (1 << 29) - (1 << 5));
    });

    test('parameter pairs must have a representable NDIRECT', () {
      // NDIRECT is transmitted as NDIRECT >> NPOSTFIX, so it must be a multiple
      // of 1 << NPOSTFIX.
      expect(() => DistanceParams(2, 3), throwsA(isA<AssertionError>()));
      expect(() => DistanceParams(1, 13), throwsA(isA<AssertionError>()));
      expect(DistanceParams(2, 12).ndirect, 12);
      expect(DistanceParams(3, 120).ndirect, 120);
    });

    test('encoder prefix coding agrees with the decoder distance LUT', () {
      const pairs = <List<int>>[
        <int>[0, 0],
        <int>[0, 1],
        <int>[0, 7],
        <int>[1, 12],
        <int>[2, 8],
        <int>[3, 0],
        <int>[3, 120],
      ];
      final bits = Int32List(1);
      final extra = Int32List(1);
      for (final pair in pairs) {
        final params = DistanceParams(pair[0], pair[1]);
        final lut = _DecoderDistanceLut(params);
        // Short codes pass through unchanged with no extra bits.
        for (var code = 0; code < numDistanceShortCodes; code++) {
          final packed = encodeDistanceCode(code, params, bits, extra);
          expect(packed & 0x3FF, code);
          expect(packed >> 10, 0);
        }
        // Every explicit code round-trips through the decoder formula.
        for (var code = numDistanceShortCodes;
            code < distanceAlphabetSize(0, 0) * 64;
            code += 7) {
          final packed = encodeDistanceCode(code, params, bits, extra);
          final symbol = packed & 0x3FF;
          expect(symbol, lessThan(params.alphabetSize));
          expect(packed >> 10, lut.extraBits[symbol]);
          // The LUT maps a symbol back to a *distance*; explicit distance
          // codes are distance + 15.
          final distance = code - numDistanceShortCodes + 1;
          expect(
            lut.offset[symbol] + (extra[0] << params.npostfix),
            distance,
            reason: 'params ${params.npostfix}/${params.ndirect} code $code',
          );
        }
      }
    });

    test('the search prefers direct codes for small explicit distances', () {
      // 100 copies that all use distance 1 as an explicit code. A direct code
      // saves one extra bit per copy at no entropy cost, so the search must
      // pick a non-default pair.
      final commands = CommandBuffer(128);
      for (var i = 0; i < 100; i++) {
        commands.insertLen[commands.count] = 0;
        commands.copyLen[commands.count] = 4;
        commands.cmdPrefix[commands.count] = 200;
        commands.distCode[commands.count] = numDistanceShortCodes;
        commands.count++;
      }
      final defaultCost = distanceCost(commands, kDefaultDistanceParams);
      final directCost = distanceCost(commands, DistanceParams(0, 8));
      expect(directCost, lessThan(defaultCost));
      final chosen = chooseDistanceParams(commands);
      expect(chosen.isDefault, isFalse);
      expect(distanceCost(commands, chosen), lessThanOrEqualTo(defaultCost));
      expect(distanceCost(commands, chosen), lessThanOrEqualTo(directCost + 1));
    });
  });

  group('RLE histogram optimizer', () {
    test('small histograms are left untouched', () {
      final counts = Uint32List.fromList(<int>[5, 0, 7, 0, 0, 9]);
      final before = counts.sublist(0);
      final scratch = Uint8List(counts.length);
      expect(optimizeHuffmanCountsForRle(counts, counts.length, scratch),
          isFalse);
      expect(counts, orderedEquals(before));
    });

    test('a long noisy plateau is made RLE friendly without zeroing symbols',
        () {
      final random = Random(3);
      final counts = Uint32List(256);
      for (var i = 0; i < 256; i++) {
        counts[i] = 200 + random.nextInt(40);
      }
      final before = counts.sublist(0);
      final scratch = Uint8List(256);
      expect(optimizeHuffmanCountsForRle(counts, 256, scratch), isTrue);
      // The support must not shrink: every symbol still gets a code length.
      for (var i = 0; i < 256; i++) {
        if (before[i] != 0) {
          expect(counts[i], isNonZero, reason: 'symbol $i');
        }
      }
      // At least one long run of equal counts should exist afterwards.
      var longest = 1;
      var run = 1;
      for (var i = 1; i < 256; i++) {
        if (counts[i] == counts[i - 1] && counts[i] != 0) {
          run++;
          if (run > longest) longest = run;
        } else {
          run = 1;
        }
      }
      expect(longest, greaterThanOrEqualTo(4));
      // Deterministic.
      final again = before.sublist(0);
      optimizeHuffmanCountsForRle(again, 256, scratch);
      expect(again, orderedEquals(counts));
    });
  });

  group('forced parameter streams', () {
    final text = Uint8List.sublistView(_textAlice, 0, 65536);
    final alternating = _alternatingTextBinary(64 * _kKiB, 5);
    const pairs = <List<int>>[
      <int>[0, 0],
      <int>[0, 7],
      <int>[1, 12],
      <int>[2, 8],
      <int>[3, 0],
      <int>[3, 120],
    ];
    for (final pair in pairs) {
      for (final rle in <bool>[false, true]) {
        final params = DistanceParams(pair[0], pair[1]);
        final label = 'npostfix=${pair[0]} ndirect=${pair[1]} '
            'rle=$rle';
        test('$label: decodes with the Rust oracle', () async {
          for (final input in <Uint8List>[text, alternating]) {
            final compressed = _compressSingleSplitBlock(
              input,
              params: params,
              optimizeHistograms: rle,
            );
            await _expectDecodes(compressed, input, reason: label);
          }
        }, skip: oracleSkipReason);
      }
    }
  });

  group('metablock header', () {
    test('NPOSTFIX / NDIRECT are written as chosen', () {
      final input = Uint8List.sublistView(_textAlice, 0, 8192);
      for (final pair in <List<int>>[
        <int>[0, 0],
        <int>[0, 7],
        <int>[1, 12],
        <int>[2, 8],
        <int>[3, 120],
      ]) {
        final params = DistanceParams(pair[0], pair[1]);
        final header = _parseHeader(
          _compressSingleSplitBlock(
            input,
            params: params,
            optimizeHistograms: false,
          ),
        );
        expect(header.npostfix, pair[0]);
        expect(header.ndirectField, pair[1] >> pair[0]);
        expect(header.numLiteralBlockTypes, 1);
        expect(header.numCommandBlockTypes, 1);
        expect(header.numDistanceBlockTypes, 1);
        expect(header.numLiteralTrees, 1);
        expect(header.numDistanceTrees, 1);
      }
    });

    test('lower qualities keep the default parameters', () {
      expect(kMinQualityForDistanceParams, 8);
      expect(kMinQualityForOptimizedHistograms, 8);
      final input = Uint8List.sublistView(_textAlice, 0, 8192);
      final q5 = brotliCompress(
        input,
        options: const BrotliEncodeOptions(quality: 5),
      );
      final header = _parseHeader(q5);
      expect(header.npostfix, 0);
      expect(header.ndirectField, 0);
    });
  });

  group('numeric round-trip', () {
    for (final quality in <int>[5, 8, 9]) {
      test('quality $quality: boundary sizes and data kinds', () async {
        const sizes = <int>[
          0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 255, 256, 1023, 4095, //
          65535, 65536, 65537, 131071, 131072, 131073,
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
      }, timeout: const Timeout(Duration(minutes: 6)));

      test('quality $quality: sizes around 1 MiB and 2 MiB', () async {
        for (final kind in <_DataKind>[
          _DataKind.text,
          _DataKind.cjkVaried,
          _DataKind.alternating,
          _DataKind.binary,
        ]) {
          for (final size in <int>[1 * _kMiB, 2 * _kMiB]) {
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
      }, timeout: const Timeout(Duration(minutes: 8)));

      test('quality $quality: every window size round-trips', () async {
        final input = _data(_DataKind.alternating, 70000);
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
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('quality $quality: deterministic and bounded', () {
        final input = _data(_DataKind.alternating, 100000);
        final first = brotliCompress(
          input,
          options: BrotliEncodeOptions(quality: quality),
        );
        expect(
          brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          ),
          orderedEquals(first),
        );
        expect(first.length, lessThanOrEqualTo(maxCompressedSize(input.length)));
      });
    }
  });

  group('ratio versus the Rust oracle', () {
    test('report sizes and feature deltas at quality 8/9', () async {
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'plrabn12-482k': _textPlrabn12,
        'text-1m': _data(_DataKind.text, _kMiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
        'alt-text-bin-256k': _data(_DataKind.alternating, 256 * _kKiB),
        'random-256k': _data(_DataKind.binary, 256 * _kKiB),
      };
      final report = StringBuffer(
        'distance params / RLE report (ours / Rust brotli crate):\n',
      );
      for (final quality in <int>[8, 9]) {
        for (final entry in cases.entries) {
          final input = entry.value;
          final ours = brotliCompress(
            input,
            options: BrotliEncodeOptions(quality: quality),
          );
          final rust = await _oracleCompress(oracle, input, quality);
          final ratio = ours.length / rust.length;
          report.writeln(
            '  q$quality ${entry.key.padRight(18)} '
            'in=${input.length.toString().padLeft(8)} '
            'ours=${ours.length.toString().padLeft(8)} '
            'rust=${rust.length.toString().padLeft(8)} '
            'ratio=${ratio.toStringAsFixed(4)}',
          );
          if (entry.key == 'random-256k') {
            expect(ours.length, lessThanOrEqualTo(input.length + 64));
          } else {
            expect(ratio, lessThan(1.08), reason: 'q$quality ${entry.key}');
            expect(ours.length, lessThan(input.length));
          }
        }
      }
      print(report.toString().trimRight());
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('the candidate comparison never loses to plain defaults', () {
      // Single-block measurements of the four configurations the encoder
      // chooses between: the minimum must never exceed the default one.
      final cases = <String, Uint8List>{
        'alice-152k': _textAlice,
        'text-1m': _data(_DataKind.text, _kMiB),
        'alt-text-bin-256k': _data(_DataKind.alternating, 256 * _kKiB),
        'cjk-varied-256k': _data(_DataKind.cjkVaried, 256 * _kKiB),
      };
      final report = StringBuffer('feature deltas (single block):\n');
      for (final entry in cases.entries) {
        final input = entry.value;
        final commands = _commandsFor(input);
        final searched = chooseDistanceParams(commands);
        final defaultSize = _splitBlockSize(
          input,
          commands,
          kDefaultDistanceParams,
          false,
        );
        final paramsSize = _splitBlockSize(
          input,
          commands,
          searched,
          false,
        );
        final rleSize = _splitBlockSize(
          input,
          commands,
          kDefaultDistanceParams,
          true,
        );
        final bothSize = _splitBlockSize(input, commands, searched, true);
        final best = <int>[defaultSize, paramsSize, rleSize, bothSize]
            .reduce((a, b) => a < b ? a : b);
        report.writeln(
          '  ${entry.key.padRight(18)} default=$defaultSize '
          'params=$paramsSize rle=$rleSize both=$bothSize '
          'chosen=(${searched.npostfix},${searched.ndirect})',
        );
        expect(best, lessThanOrEqualTo(defaultSize));
        // RLE optimisation must win on at least plain text.
        if (entry.key == 'alice-152k' || entry.key == 'text-1m') {
          expect(rleSize, lessThanOrEqualTo(defaultSize));
        }
      }
      print(report.toString().trimRight());
    });
  }, skip: oracleSkipReason);
}

// ---------------------------------------------------------------------------
// Decoder-side distance LUT (mirrors c/dec/decode.c CalculateDistanceLut).
// ---------------------------------------------------------------------------

final class _DecoderDistanceLut {
  _DecoderDistanceLut(this.params)
    : offset = Int32List(params.alphabetSize),
      extraBits = Uint8List(params.alphabetSize) {
    var index = numDistanceShortCodes;
    for (var j = 0; j < params.ndirect; j++) {
      offset[index] = j + 1;
      extraBits[index] = 0;
      index++;
    }
    final postfix = 1 << params.npostfix;
    var bits = 1;
    var half = 0;
    while (index < params.alphabetSize) {
      final base =
          params.ndirect +
          ((((2 + half) << bits) - 4) << params.npostfix) +
          1;
      for (var j = 0; j < postfix; j++) {
        offset[index] = base + j;
        extraBits[index] = bits;
        index++;
      }
      bits += half;
      half ^= 1;
    }
  }

  final DistanceParams params;
  final Int32List offset;
  final Uint8List extraBits;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

CommandBuffer _commandsFor(Uint8List input) {
  final hasher = HashChainMatcher(
    bucketBits: 15,
    blockBits: 8,
    numLastDistances: 16,
  );
  final commands = CommandBuffer(input.length);
  final cache = createSearchDistanceCache();
  createBackwardReferences(
    input,
    0,
    input.length,
    hasher,
    commands,
    cache,
    (1 << 22) - 16,
    extensiveSearch: true,
  );
  return commands;
}

Uint8List _compressSingleSplitBlock(
  Uint8List input, {
  required DistanceParams params,
  required bool optimizeHistograms,
  CommandBuffer? commands,
}) {
  final writer = BitWriter();
  writer.writeBits(4, 0xB); // lgwin 22
  final cmds = commands ?? _commandsFor(input);
  final split = buildMetaBlockSplit(
    input,
    0,
    input.length,
    cmds,
    null,
    distanceParams: params,
  );
  SplitMetaBlockWriter().store(
    writer,
    input,
    0,
    input.length,
    cmds,
    split,
    isLast: true,
    distanceParams: params,
    optimizeHistograms: optimizeHistograms,
  );
  writer.alignToByte();
  return writer.toBytes();
}

int _splitBlockSize(
  Uint8List input,
  CommandBuffer commands,
  DistanceParams params,
  bool optimizeHistograms,
) => _compressSingleSplitBlock(
  input,
  params: params,
  optimizeHistograms: optimizeHistograms,
  commands: commands,
).length;

/// First meta-block header fields needed by these tests.
final class _Header {
  _Header({
    required this.npostfix,
    required this.ndirectField,
    required this.numLiteralBlockTypes,
    required this.numCommandBlockTypes,
    required this.numDistanceBlockTypes,
    required this.numLiteralTrees,
    required this.numDistanceTrees,
  });

  final int npostfix;
  final int ndirectField;
  final int numLiteralBlockTypes;
  final int numCommandBlockTypes;
  final int numDistanceBlockTypes;
  final int numLiteralTrees;
  final int numDistanceTrees;
}

/// Parses a *single-block-last, all-types-1* compressed header (what
/// [_compressSingleSplitBlock] writes with a non-split structure) plus the
/// plain-writer header used by q5.
_Header _parseHeader(Uint8List stream) {
  var bitPosition = 0;
  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = stream[bitPosition >> 3];
      final bit = (byte >> (bitPosition & 7)) & 1;
      value |= bit << i;
      bitPosition++;
    }
    return value;
  }

  int readVarLenUint8() {
    if (readBits(1) == 0) return 0;
    final nbits = readBits(3);
    if (nbits == 0) return 1;
    return (1 << nbits) + readBits(nbits);
  }

  // Window bits.
  if (readBits(1) == 0) {
    // lgwin 16.
  } else {
    final n1 = readBits(3);
    if (n1 == 0) {
      final n2 = readBits(3);
      if (n2 == 0) {
        // lgwin 17.
      }
    }
  }
  final isLast = readBits(1) == 1;
  if (isLast) {
    final isEmpty = readBits(1) == 1;
    expect(isEmpty, isFalse, reason: 'test streams are non-empty');
  }
  final nibbles = readBits(2) + 4;
  for (var i = 0; i < nibbles * 4; i++) {
    readBits(1);
  }
  if (!isLast) {
    expect(readBits(1), 0, reason: 'not uncompressed');
  }
  final literalTypes = readVarLenUint8() + 1;
  final commandTypes = readVarLenUint8() + 1;
  final distanceTypes = readVarLenUint8() + 1;
  final npostfix = readBits(2);
  final ndirectField = readBits(4);
  // Literal context modes.
  for (var i = 0; i < literalTypes; i++) {
    readBits(2);
  }
  final literalTrees = readVarLenUint8() + 1;
  final distanceTrees = readVarLenUint8() + 1;
  return _Header(
    npostfix: npostfix,
    ndirectField: ndirectField,
    numLiteralBlockTypes: literalTypes,
    numCommandBlockTypes: commandTypes,
    numDistanceBlockTypes: distanceTypes,
    numLiteralTrees: literalTrees,
    numDistanceTrees: distanceTrees,
  );
}

// ---------------------------------------------------------------------------
// Data fixtures
// ---------------------------------------------------------------------------

final Uint8List _textAlice = File(
  p.join(Directory.current.path, 'test/testdata/alice29.txt'),
).readAsBytesSync();
final Uint8List _textPlrabn12 = File(
  p.join(Directory.current.path, 'test/testdata/plrabn12.txt'),
).readAsBytesSync();

enum _DataKind { text, cjkVaried, alternating, binary, zeros }

Uint8List _data(_DataKind kind, int size, {int seed = 0}) {
  switch (kind) {
    case _DataKind.text:
      return _repeatToSize(_textAlice, size);
    case _DataKind.cjkVaried:
      return _variedCjk(size, seed + 1);
    case _DataKind.alternating:
      return _alternatingTextBinary(size, seed + 2);
    case _DataKind.binary:
      final random = Random(0xB07 + seed);
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = random.nextInt(256);
      }
      return out;
    case _DataKind.zeros:
      return Uint8List(size);
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

Uint8List _alternatingTextBinary(int size, int seed) {
  final out = Uint8List(size);
  final random = Random(seed);
  var pos = 0;
  var inText = true;
  var left = 32768;
  while (pos < size) {
    if (left == 0) {
      inText = !inText;
      left = 32768;
    }
    out[pos] = inText ? _textAlice[pos % _textAlice.length] : random.nextInt(256);
    pos++;
    left--;
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

Future<void> _expectDecodes(
  Uint8List compressed,
  Uint8List input, {
  required String reason,
}) async {
  final decoded = await _oracleDecompress(File(_oracleEnv!), compressed);
  expect(decoded.length, input.length, reason: '$reason: decoded length');
  expect(
    _sha256(decoded),
    orderedEquals(_sha256(input)),
    reason: '$reason: decoded SHA-256',
  );
}

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
