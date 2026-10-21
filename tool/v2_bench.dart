/// v0.2.0 performance gate harness.
///
/// Measures the v1 (current) and v2 Brotli implementations against the
/// authoritative Rust baseline in `benchmark/v2_native.json`, prints a
/// MB/s + ratio table and exits non-zero when a gated operation falls below
/// `--gate` (default 0.80).
///
/// Gated by default: the core q5 encode/decode rows (the rows in the README
/// benchmark card). q0/q1/q9 are report-only speed tiers; they are sensitive
/// to host frequency/load and are not part of the release gate.
/// The corpus is the deterministic 1 MiB text/binary pair from
/// `benchmark/corpus.dart`, loaded from `build/benchmark_test/corpus`.
///
/// Usage (JIT; counters/report):
///   dart run tool/v2_bench.dart --api v1 --gate-api none
///
/// Usage (AOT):
///   dart compile exe tool/v2_bench.dart -o build/benchmark_test/v2_bench.exe
///   build/benchmark_test/v2_bench.exe --api v2
///
/// Refresh the committed native baseline (needs the Rust oracle):
///   dart run tool/v2_bench.dart --refresh-native
///
/// This tool is measurement infrastructure only: it never changes the codec.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:brotli_neo/compat.dart' as v1;
import 'package:brotli_neo/src/v2/decoder/decoder_v2.dart' as v2d;
import 'package:brotli_neo/src/v2/encoder/encoder_v2.dart' as v2e;
import 'package:crypto/crypto.dart' as crypto;

import '../benchmark/corpus.dart' as corpus;

const String benchSchema = 'brotli_neo/v2_bench@1';
const String nativeSchema = 'brotli_neo/v2_native@1';
const List<int> defaultQualities = <int>[0, 1, 5, 9];
const List<String> corpusNames = <String>['text', 'binary'];
const int defaultRounds = 15;
const int defaultWarmup = 3;
const int defaultNativeRuns = 3;
const int defaultNativeRounds = 31;
const int defaultNativeWarmup = 5;
const int nativeLgwin = 22;

/// Keeps benchmark outputs observable so AOT/dart2js cannot elide the work.
int _sink = 0;

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on _UsageException catch (error) {
    stderr.writeln('v2_bench: ${error.message}');
    stderr.writeln(_usage);
    exit(64);
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final Directory root;
  final _CorpusSet corpora;
  try {
    root = _findRepoRoot(options.root);
    corpora = _loadCorpus(root, options.corpusDir);
  } on _UsageException catch (error) {
    stderr.writeln('v2_bench: ${error.message}');
    exit(2);
  }

  if (options.refreshNative) {
    try {
      await _refreshNative(root, options, corpora);
    } on _UsageException catch (error) {
      stderr.writeln('v2_bench: ${error.message}');
      exit(2);
    }
    return;
  }

  final _NativeBaseline native;
  try {
    native = _loadNative(root, options.nativePath, corpora);
  } on _UsageException catch (error) {
    stderr.writeln('v2_bench: ${error.message}');
    exit(2);
  }

  final Map<String, _Codec> codecs = <String, _Codec>{
    'v1': _V1Codec(),
    'v2': _V2Codec(),
  };
  final List<_Codec> selected;
  try {
    selected = _selectCodecs(options, codecs);
  } on _UsageException catch (error) {
    stderr.writeln('v2_bench: ${error.message}');
    exit(2);
  }

  final String gateApi = _resolveGateApi(options, selected, codecs);
  final String compileLabel =
      options.compileLabel ??
      (const bool.fromEnvironment('dart.vm.product') ? 'aot' : 'jit');
  final _DecodeStreams decodeStreams = _DecodeStreams(
    root: root,
    corpora: corpora,
    oraclePath: _oraclePath(root, options.oracle),
    mode: options.decodeStreams,
  );

  stdout.writeln(
    'native: ${options.nativePath} '
    '(${native.hostSummary}, runs=${native.runs}, rounds=${native.rounds}, '
    'warmup=${native.warmup}, ${native.statistic})',
  );
  stdout.writeln(
    'host: ${Platform.operatingSystem}/${Platform.version.split(' ').first} '
    '${Platform.numberOfProcessors} cpus · compile=$compileLabel · '
    'gate=${options.gate.toStringAsFixed(2)} (${gateApi == 'none' ? 'off' : gateApi})',
  );
  stdout.writeln('');

  final List<_Result> results = <_Result>[];
  for (final _Codec codec in selected) {
    if (!codec.supportsEncode || !codec.supportsDecode) {
      stderr.writeln(
        'skipping ${codec.id}: ${codec.unavailableReason ?? 'partial API'}',
      );
      continue;
    }
    for (final String corpusName in corpusNames) {
      final _Corpus data = corpora[corpusName];
      for (final int quality in options.qualities) {
        try {
          final Uint8List encoded = codec.encode(data.bytes, quality);
          _sink += encoded.length;
          final Uint8List decoded = codec.decode(encoded);
          if (!_bytesEqual(decoded, data.bytes)) {
            throw _UsageException(
              '${codec.id} $corpusName q$quality round-trip mismatch '
              '(${decoded.length} != ${data.bytes.length})',
            );
          }
          final _Measurement enc = _measure(
            () => codec.encode(data.bytes, quality),
            warmup: options.warmup,
            rounds: options.rounds,
          );
          results.add(
            _Result.build(
              api: codec.id,
              compile: compileLabel,
              corpusName: corpusName,
              op: 'encode',
              quality: quality,
              measurement: enc,
              rawBytes: data.bytes.length,
              outputBytes: encoded.length,
              native: native.lookup(corpusName, 'encode', quality),
              gated: _isGated('encode', quality) && _isGateApi(codec.id, gateApi),
              gate: options.gate,
              streamSource: null,
            ),
          );

          final _Stream stream = decodeStreams.stream(data, quality);
          final Uint8List decodedStream = codec.decode(stream.bytes);
          if (!_bytesEqual(decodedStream, data.bytes)) {
            throw _UsageException(
              '${codec.id} $corpusName q$quality decode stream mismatch '
              '(${decodedStream.length} != ${data.bytes.length}, '
              'source=${stream.source})',
            );
          }
          final _Measurement dec = _measure(
            () => codec.decode(stream.bytes),
            warmup: options.warmup,
            rounds: options.rounds,
          );
          results.add(
            _Result.build(
              api: codec.id,
              compile: compileLabel,
              corpusName: corpusName,
              op: 'decode',
              quality: quality,
              measurement: dec,
              rawBytes: data.bytes.length,
              outputBytes: decodedStream.length,
              native: native.lookup(corpusName, 'decode', quality),
              gated: _isGated('decode', quality) && _isGateApi(codec.id, gateApi),
              gate: options.gate,
              streamSource: stream.source,
            ),
          );
        } on _UsageException catch (error) {
          stderr.writeln('v2_bench: ${error.message}');
          exit(2);
        } on Object catch (error, stack) {
          stderr.writeln(
            'v2_bench: ${codec.id} $corpusName q$quality failed: $error',
          );
          if (options.verbose) stderr.writeln(stack);
          exit(2);
        }
      }
    }
  }

  _printTable(results, gate: options.gate, gateApi: gateApi);
  stdout.writeln('sink=$_sink');

  try {
    if (options.markdownPath != null) {
      final String markdown = _markdown(results, gate: options.gate, gateApi: gateApi);
      _writeFile(root, options.markdownPath!, markdown);
      stdout.writeln('markdown: ${options.markdownPath}');
    }
    if (options.jsonlPath != null) {
      final String jsonl = results.map((r) => jsonEncode(r.toJson())).join('\n');
      _writeFile(root, options.jsonlPath!, '$jsonl\n');
      stdout.writeln('jsonl: ${options.jsonlPath}');
    }
  } on FileSystemException catch (error) {
    stderr.writeln('v2_bench: write output: ${error.message}: ${error.path}');
    exit(2);
  }

  if (options.format == 'markdown') {
    stdout.writeln('');
    stdout.writeln(_markdown(results, gate: options.gate, gateApi: gateApi));
  }

  final List<_Result> gated = results.where((r) => r.gated).toList();
  final List<_Result> failed = gated.where((r) => !r.pass).toList();
  exit(failed.isEmpty ? 0 : 1);
}

bool _isGated(String op, int quality) => quality == 5;

bool _isGateApi(String api, String gateApi) {
  return gateApi == 'all' || gateApi == api;
}

String _resolveGateApi(
  _Options options,
  List<_Codec> selected,
  Map<String, _Codec> codecs,
) {
  if (options.gateApi == 'none') return 'none';
  if (options.gateApi == 'auto') {
    final bool hasV2 = selected.any((c) => c.id == 'v2');
    return hasV2 ? 'v2' : 'v1';
  }
  if (options.gateApi == 'all') {
    for (final _Codec codec in selected) {
      if (!codec.supportsEncode) {
        throw _UsageException(
          'cannot gate all: ${codec.id} is not available',
        );
      }
    }
    return 'all';
  }
  final _Codec? codec = codecs[options.gateApi];
  if (codec == null) {
    throw _UsageException('unknown --gate-api ${options.gateApi}');
  }
  if (!codec.supportsEncode || !selected.contains(codec)) {
    throw _UsageException(
      '--gate-api ${options.gateApi} was not selected by --api '
      '${options.api} (or is unavailable)',
    );
  }
  return options.gateApi;
}

List<_Codec> _selectCodecs(_Options options, Map<String, _Codec> codecs) {
  final _Codec v1Codec = codecs['v1']!;
  final _Codec v2Codec = codecs['v2']!;
  switch (options.api) {
    case 'v1':
      return <_Codec>[v1Codec];
    case 'v2':
      if (!v2Codec.supportsEncode || !v2Codec.supportsDecode) {
        throw _UsageException(
          'v2 API is not wired into tool/v2_bench.dart yet '
          '(${v2Codec.unavailableReason}); use --api v1 or both',
        );
      }
      return <_Codec>[v2Codec];
    case 'auto':
    case 'both':
      final List<_Codec> out = <_Codec>[v1Codec];
      if (v2Codec.supportsEncode && v2Codec.supportsDecode) {
        out.add(v2Codec);
      } else {
        stderr.writeln(
          'v2 unavailable (${v2Codec.unavailableReason}); measuring v1 only',
        );
      }
      return out;
    default:
      throw _UsageException('unknown --api ${options.api}');
  }
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

abstract interface class _Codec {
  String get id;
  String get label;
  bool get supportsEncode;
  bool get supportsDecode;
  String? get unavailableReason;
  Uint8List encode(Uint8List input, int quality);
  Uint8List decode(Uint8List input);
}

final class _V1Codec implements _Codec {
  @override
  String get id => 'v1';

  @override
  String get label => 'v1 (compat.dart)';

  @override
  bool get supportsEncode => true;

  @override
  bool get supportsDecode => true;

  @override
  String? get unavailableReason => null;

  @override
  Uint8List encode(Uint8List input, int quality) => v1.brotliCompress(
    input,
    options: v1.BrotliEncodeOptions(quality: quality),
  );

  @override
  Uint8List decode(Uint8List input) => v1.brotliDecompress(input);
}

/// v2 adapter.
///
/// V2D (`lib/src/v2/decoder/decoder_v2.dart`) and V2E
/// (`lib/src/v2/encoder/encoder_v2.dart`) expose the fast entry points used
/// here. Qualities > 5 and non-default option combinations fall back to v1
/// inside `BrotliEncoderV2`, so q9 is still report-only for the gate.
final class _V2Codec implements _Codec {
  static const bool _wired = true;

  @override
  String get id => 'v2';

  @override
  String get label => 'v2 (lib/src/v2)';

  @override
  bool get supportsEncode => _wired;

  @override
  bool get supportsDecode => _wired;

  @override
  String? get unavailableReason =>
      _wired ? null : 'lib/src/v2 encoder/decoder are not wired yet';

  @override
  Uint8List encode(Uint8List input, int quality) => v2e.BrotliEncoderV2.encode(
    input,
    options: v1.BrotliEncodeOptions(quality: quality),
  );

  @override
  Uint8List decode(Uint8List input) => v2d.BrotliDecoderV2.decode(input);
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

final class _Measurement {
  const _Measurement(
    this.meanSeconds,
    this.medianSeconds,
    this.rmePct,
    this.samples,
  );

  final double meanSeconds;
  final double medianSeconds;
  final double rmePct;
  final int samples;
}

_Measurement _measure(
  Uint8List Function() body, {
  required int warmup,
  required int rounds,
}) {
  for (var i = 0; i < warmup; i++) {
    _sink += body().length;
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < rounds; i++) {
    final Stopwatch stopwatch = Stopwatch()..start();
    final Uint8List out = body();
    stopwatch.stop();
    _sink += out.length;
    samples.add(stopwatch.elapsedTicks / stopwatch.frequency);
  }
  final double mean =
      samples.isEmpty
      ? 0
      : samples.reduce((double a, double b) => a + b) / samples.length;
  final List<double> sorted = List<double>.of(samples)..sort();
  final double median =
      sorted.isEmpty
      ? 0
      : (sorted.length.isOdd
            ? sorted[sorted.length ~/ 2]
            : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) /
                  2);
  double rme = 0;
  if (samples.length > 1 && mean > 0) {
    final double variance =
        samples
            .map((double x) => (x - mean) * (x - mean))
            .reduce((double a, double b) => a + b) /
        (samples.length - 1);
    final double sd = math.sqrt(variance);
    rme = 1.96 * sd / math.sqrt(samples.length) / mean * 100;
  }
  return _Measurement(mean, median, rme, samples.length);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

final class _Result {
  const _Result({
    required this.api,
    required this.compile,
    required this.corpusName,
    required this.op,
    required this.quality,
    required this.measurement,
    required this.mbPerSecond,
    required this.rawBytes,
    required this.outputBytes,
    required this.native,
    required this.gated,
    required this.gate,
    required this.streamSource,
    required this.ratio,
    required this.pass,
  });

  factory _Result.build({
    required String api,
    required String compile,
    required String corpusName,
    required String op,
    required int quality,
    required _Measurement measurement,
    required int rawBytes,
    required int outputBytes,
    required _NativeEntry? native,
    required bool gated,
    required double gate,
    required String? streamSource,
  }) {
    final double mbPerSecond =
        rawBytes / measurement.medianSeconds / (1000 * 1000);
    final double? ratio =
        native == null || native.mbPerSecond <= 0
            ? null
            : mbPerSecond / native.mbPerSecond;
    final bool pass = !gated || (ratio != null && ratio >= gate);
    return _Result(
      api: api,
      compile: compile,
      corpusName: corpusName,
      op: op,
      quality: quality,
      measurement: measurement,
      mbPerSecond: mbPerSecond,
      rawBytes: rawBytes,
      outputBytes: outputBytes,
      native: native,
      gated: gated,
      gate: gate,
      streamSource: streamSource,
      ratio: ratio,
      pass: pass,
    );
  }

  final String api;
  final String compile;
  final String corpusName;
  final String op;
  final int quality;
  final _Measurement measurement;
  final double mbPerSecond;
  final int rawBytes;
  final int outputBytes;
  final _NativeEntry? native;
  final bool gated;
  final double gate;
  final String? streamSource;
  final double? ratio;
  final bool pass;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': benchSchema,
    'api': api,
    'compile': compile,
    'corpus': corpusName,
    'op': op,
    'quality': quality,
    'mb_per_second': _round(mbPerSecond, 3),
    'statistic': 'median',
    'rme_pct': _round(measurement.rmePct, 3),
    'samples': measurement.samples,
    'raw_bytes': rawBytes,
    'output_bytes': outputBytes,
    'native_mb_per_second':
        native == null ? null : _round(native!.mbPerSecond, 3),
    'native_rme_pct': native == null ? null : _round(native!.rmePct, 3),
    'ratio': ratio == null ? null : _round(ratio!, 4),
    'gated': gated,
    'gate': gate,
    if (gated) 'pass': pass,
    if (streamSource != null) 'decode_stream_source': streamSource,
  };
}

double _round(double value, int digits) {
  final num factor = math.pow(10, digits);
  return (value * factor).round() / factor;
}

double _medianOf(List<double> values) {
  if (values.isEmpty) return 0;
  final List<double> sorted = List<double>.of(values)..sort();
  return sorted.length.isOdd
      ? sorted[sorted.length ~/ 2]
      : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
}

void _printTable(
  List<_Result> results, {
  required double gate,
  required String gateApi,
}) {
  stdout.writeln(
    'api  compile  corpus  op      q   MB/s       native     ratio  gate',
  );
  stdout.writeln('-' * 72);
  for (final _Result r in results) {
    final String native =
        r.native == null ? '-' : r.native!.mbPerSecond.toStringAsFixed(1);
    final String ratio =
        r.ratio == null ? '-' : '${r.ratio!.toStringAsFixed(3)}x';
    final String gateText = !r.gated ? '-' : (r.pass ? 'pass' : 'FAIL');
    stdout.writeln(
      '${r.api.padRight(4)} ${r.compile.padRight(8)} '
      '${r.corpusName.padRight(7)} ${r.op.padRight(7)} '
      '${r.quality.toString().padRight(3)} '
      '${r.mbPerSecond.toStringAsFixed(1).padLeft(9)}  '
      '${native.padLeft(8)}  ${ratio.padLeft(7)}  $gateText',
    );
  }
  final List<_Result> gatedRows = results.where((r) => r.gated).toList();
  final int failed = gatedRows.where((r) => !r.pass).length;
  stdout.writeln('');
  if (gateApi == 'none') {
    stdout.writeln('Gate: disabled (report only)');
  } else if (gatedRows.isEmpty) {
    stdout.writeln('Gate @ ${gate.toStringAsFixed(2)}: no gated rows');
  } else {
    stdout.writeln(
      'Gate @ ${gate.toStringAsFixed(2)} ($gateApi): '
      '${failed == 0 ? 'PASS' : 'FAIL'} '
      '(${gatedRows.length} gated, $failed below)',
    );
  }
}

String _markdown(
  List<_Result> results, {
  required double gate,
  required String gateApi,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('| api | compile | corpus | op | q | MB/s | native MB/s | ratio | gate |')
    ..writeln('|---|---|---|---|---:|---:|---:|---:|---|');
  for (final _Result r in results) {
    final String native =
        r.native == null ? '—' : r.native!.mbPerSecond.toStringAsFixed(1);
    final String ratio =
        r.ratio == null ? '—' : '${r.ratio!.toStringAsFixed(3)}×';
    final String gateText = !r.gated ? 'report' : (r.pass ? 'pass' : 'FAIL');
    out.writeln(
      '| ${r.api} | ${r.compile} | ${r.corpusName} | ${r.op} | '
      '${r.quality} | ${r.mbPerSecond.toStringAsFixed(1)} | '
      '$native | $ratio | $gateText |',
    );
  }
  final List<_Result> gatedRows = results.where((r) => r.gated).toList();
  final int failed = gatedRows.where((r) => !r.pass).length;
  out
    ..writeln()
    ..writeln(
      gateApi == 'none'
          ? '**Gate: disabled (report only).**'
          : '**Gate: ${failed == 0 ? 'PASS' : 'FAIL'}** — '
                '${gate.toStringAsFixed(2)}× native, '
                '$failed of ${gatedRows.length} gated rows below.',
    );
  return out.toString();
}

// ---------------------------------------------------------------------------
// Native baseline
// ---------------------------------------------------------------------------

final class _NativeEntry {
  const _NativeEntry({
    required this.mbPerSecond,
    required this.rmePct,
    required this.rawBytes,
    required this.compressedBytes,
    required this.ratio,
  });

  final double mbPerSecond;
  final double rmePct;
  final int rawBytes;
  final int compressedBytes;
  final double ratio;
}

final class _NativeBaseline {
  const _NativeBaseline({
    required this.path,
    required this.entries,
    required this.runs,
    required this.rounds,
    required this.warmup,
    required this.statistic,
    required this.hostSummary,
    required this.corpusHashes,
  });

  final String path;
  final Map<String, _NativeEntry> entries;
  final int runs;
  final int rounds;
  final int warmup;
  final String statistic;
  final String hostSummary;
  final Map<String, ({int bytes, String sha256})> corpusHashes;

  _NativeEntry? lookup(String corpus, String op, int quality) =>
      entries['$corpus/$op/q$quality'];
}

_NativeBaseline _loadNative(
  Directory root,
  String pathArg,
  _CorpusSet corpora,
) {
  final File file = File(_resolve(root, pathArg));
  if (!file.existsSync()) {
    throw _UsageException(
      'native baseline not found: $pathArg\n'
      'Generate it with: dart run tool/v2_bench.dart --refresh-native',
    );
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw _UsageException('native baseline is not valid JSON: ${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw _UsageException('native baseline must be a JSON object');
  }
  final String? schema = decoded['schema'] as String?;
  if (schema == nativeSchema) {
    return _fromCompactNative(pathArg, decoded, corpora);
  }
  if (schema == 'bench-svg/report@1') {
    return _fromOracleReport(pathArg, decoded, corpora);
  }
  throw _UsageException(
    'unsupported native baseline schema ${schema ?? '<missing>'}; '
    'expected $nativeSchema',
  );
}

_NativeBaseline _fromCompactNative(
  String path,
  Map<String, dynamic> json,
  _CorpusSet corpora,
) {
  final dynamic resultsRaw = json['results'];
  if (resultsRaw is! Map<String, dynamic>) {
    throw _UsageException('native baseline has no results object');
  }
  final Map<String, _NativeEntry> entries = <String, _NativeEntry>{};
  final Map<String, ({int bytes, String sha256})> hashes =
      <String, ({int bytes, String sha256})>{};
  final dynamic corpusRaw = json['corpus'];
  if (corpusRaw is Map<String, dynamic>) {
    for (final String name in corpusNames) {
      final dynamic entry = corpusRaw[name];
      if (entry is Map<String, dynamic>) {
        final int bytes = (entry['bytes'] as num?)?.toInt() ?? 0;
        final String sha = entry['sha256'] as String? ?? '';
        if (bytes > 0 && sha.isNotEmpty) {
          hashes[name] = (bytes: bytes, sha256: sha);
          final _Corpus actual = corpora[name];
          if (actual.bytes.length != bytes ||
              actual.sha256.toLowerCase() != sha.toLowerCase()) {
            throw _UsageException(
              'corpus mismatch for $name: baseline '
              '${bytes}B/${sha.substring(0, math.min(12, sha.length))}..., '
              'local ${actual.bytes.length}B/'
              '${actual.sha256.substring(0, 12)}...; '
              'regenerate the corpus or the native baseline',
            );
          }
        }
      }
    }
  }
  for (final String corpusName in corpusNames) {
    final dynamic corpusNode = resultsRaw[corpusName];
    if (corpusNode is! Map<String, dynamic>) {
      throw _UsageException('native baseline missing corpus $corpusName');
    }
    for (final String op in <String>['encode', 'decode']) {
      final dynamic opNode = corpusNode[op];
      if (opNode is! Map<String, dynamic>) {
        throw _UsageException('native baseline missing $corpusName/$op');
      }
      for (final MapEntry<String, dynamic> qEntry in opNode.entries) {
        final int? quality = int.tryParse(qEntry.key.replaceFirst('q', ''));
        final dynamic value = qEntry.value;
        if (quality == null || value is! Map<String, dynamic>) continue;
        final dynamic mb = value['mb_per_second'];
        if (mb is! num) continue;
        entries['$corpusName/$op/q$quality'] = _NativeEntry(
          mbPerSecond: mb.toDouble(),
          rmePct: (value['rme_pct'] as num?)?.toDouble() ?? 0,
          rawBytes: (value['raw_bytes'] as num?)?.toInt() ?? 0,
          compressedBytes:
              (value['compressed_bytes'] as num?)?.toInt() ?? 0,
          ratio: (value['ratio'] as num?)?.toDouble() ?? 0,
        );
      }
    }
  }
  if (entries.isEmpty) {
    throw _UsageException('native baseline has no benchmark entries');
  }
  final dynamic host = json['host'];
  final String hostSummary;
  if (host is Map<String, dynamic>) {
    hostSummary = <String>[
      host['os']?.toString() ?? '?',
      host['arch']?.toString() ?? '?',
      host['cpu']?.toString() ?? '?',
    ].join(' ');
  } else {
    hostSummary = 'unknown host';
  }
  final String currentOs = Platform.operatingSystem;
  final String baselineOs = host is Map<String, dynamic>
      ? (host['os']?.toString() ?? '')
      : '';
  if (baselineOs.isNotEmpty && baselineOs != currentOs) {
    stderr.writeln(
      'warning: native baseline was measured on $baselineOs, '
      'this run is $currentOs; ratios are machine-specific. '
      'Regenerate with --refresh-native on the target machine.',
    );
  }
  return _NativeBaseline(
    path: path,
    entries: entries,
    runs: (json['runs'] as num?)?.toInt() ?? 1,
    rounds: (json['rounds'] as num?)?.toInt() ?? 0,
    warmup: (json['warmup'] as num?)?.toInt() ?? 0,
    statistic: json['statistic']?.toString() ?? 'mean',
    hostSummary: hostSummary,
    corpusHashes: hashes,
  );
}

_NativeBaseline _fromOracleReport(
  String path,
  Map<String, dynamic> json,
  _CorpusSet corpora,
) {
  final dynamic rawBenchmarks = json['benchmarks'];
  if (rawBenchmarks is! List) {
    throw _UsageException('oracle report has no benchmarks array');
  }
  final Map<String, _NativeEntry> entries = <String, _NativeEntry>{};
  for (final dynamic item in rawBenchmarks) {
    if (item is! Map<String, dynamic>) continue;
    final dynamic paramsRaw = item['params'];
    if (paramsRaw is! Map<String, dynamic>) continue;
    final String corpusName = paramsRaw['input']?.toString() ?? '';
    final String op = paramsRaw['op'] == 'compress' ? 'encode' : 'decode';
    final int? quality = int.tryParse(paramsRaw['quality']?.toString() ?? '');
    final dynamic value = item['value'];
    if (!corpusNames.contains(corpusName) || quality == null || value is! num) {
      continue;
    }
    entries['$corpusName/$op/q$quality'] = _NativeEntry(
      mbPerSecond: value.toDouble(),
      rmePct:
          ((item['stats'] as Map<String, dynamic>?)?['rme_pct'] as num?)
              ?.toDouble() ??
          0,
      rawBytes:
          int.tryParse(paramsRaw['raw_bytes']?.toString() ?? '') ??
          corpora[corpusName].bytes.length,
      compressedBytes:
          int.tryParse(paramsRaw['compressed_bytes']?.toString() ?? '') ?? 0,
      ratio:
          double.tryParse(paramsRaw['ratio']?.toString() ?? '') ?? 0,
    );
  }
  if (entries.isEmpty) {
    throw _UsageException('oracle report has no usable benchmark entries');
  }
  final dynamic meta = json['meta'];
  final dynamic platform = meta is Map<String, dynamic> ? meta['platform'] : null;
  final String hostSummary = platform is Map<String, dynamic>
      ? <String>[
          platform['os']?.toString() ?? '?',
          platform['arch']?.toString() ?? '?',
          platform['cpu']?.toString() ?? '?',
        ].join(' ')
      : 'unknown host';
  return _NativeBaseline(
    path: path,
    entries: entries,
    runs: 1,
    rounds: 0,
    warmup: 0,
    statistic: 'single oracle report (mean per op)',
    hostSummary: hostSummary,
    corpusHashes: const <String, ({int bytes, String sha256})>{},
  );
}

Future<void> _refreshNative(
  Directory root,
  _Options options,
  _CorpusSet corpora,
) async {
  final String? oracle = _oraclePath(root, options.oracle);
  if (oracle == null) {
    throw _UsageException(
      'Rust oracle not found. Build it first:\n'
      '  cargo build --release --locked --manifest-path tool/oracle_rust/Cargo.toml\n'
      'or pass --oracle <path>.',
    );
  }
  final String qualities = options.qualities.join(',');
  final List<Map<String, Map<String, Object?>>> runEntries =
      <Map<String, Map<String, Object?>>>[];
  Map<String, dynamic>? firstDecoded;
  for (var runIndex = 1; runIndex <= options.nativeRuns; runIndex++) {
    final File reportFile = File(
      _resolve(
        root,
        'build/benchmark_test/v2_native_oracle_$runIndex.json',
      ),
    );
    reportFile.parent.createSync(recursive: true);
    stdout.writeln(
      'native run $runIndex/${options.nativeRuns}: $oracle bench -q $qualities '
      '-w $nativeLgwin --rounds ${options.nativeRounds} '
      '--warmup ${options.nativeWarmup}',
    );
    final ProcessResult run = await Process.run(oracle, <String>[
      'bench',
      '-i',
      corpora['text'].filePath,
      '--label',
      'text',
      '-i',
      corpora['binary'].filePath,
      '--label',
      'binary',
      '-q',
      qualities,
      '-w',
      '$nativeLgwin',
      '--rounds',
      '${options.nativeRounds}',
      '--warmup',
      '${options.nativeWarmup}',
      '--unit',
      'MB/s',
      '--json',
      reportFile.path,
    ]);
    if (run.exitCode != 0) {
      throw _UsageException(
        'oracle bench failed (${run.exitCode}):\n${run.stderr}\n${run.stdout}',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(reportFile.readAsStringSync());
    } on FormatException catch (error) {
      throw _UsageException(
        'oracle report is not valid JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw _UsageException('oracle report must be a JSON object');
    }
    firstDecoded ??= decoded;
    final dynamic rawBenchmarks = decoded['benchmarks'];
    if (rawBenchmarks is! List) {
      throw _UsageException('oracle report has no benchmarks array');
    }
    final Map<String, Map<String, Object?>> entries =
        <String, Map<String, Object?>>{};
    for (final dynamic item in rawBenchmarks) {
      if (item is! Map<String, dynamic>) continue;
      final dynamic paramsRaw = item['params'];
      if (paramsRaw is! Map<String, dynamic>) continue;
      final String corpusName = paramsRaw['input']?.toString() ?? '';
      final String op = paramsRaw['op'] == 'compress' ? 'encode' : 'decode';
      final int? quality = int.tryParse(
        paramsRaw['quality']?.toString() ?? '',
      );
      final dynamic value = item['value'];
      if (!corpusNames.contains(corpusName) ||
          quality == null ||
          value is! num) {
        continue;
      }
      entries['$corpusName/$op/q$quality'] = <String, Object?>{
        'mb_per_second': value.toDouble(),
        'rme_pct':
            ((item['stats'] as Map<String, dynamic>?)?['rme_pct'] as num?)
                ?.toDouble() ??
            0,
        'raw_bytes':
            int.tryParse(paramsRaw['raw_bytes']?.toString() ?? '') ??
            corpora[corpusName].bytes.length,
        'compressed_bytes':
            int.tryParse(paramsRaw['compressed_bytes']?.toString() ?? '') ?? 0,
        'ratio': double.tryParse(paramsRaw['ratio']?.toString() ?? '') ?? 0,
      };
    }
    runEntries.add(entries);
  }

  final Map<String, dynamic> info = <String, dynamic>{};
  final ProcessResult infoRun = await Process.run(oracle, <String>['info']);
  if (infoRun.exitCode == 0) {
    final dynamic infoJson = jsonDecode(infoRun.stdout as String);
    if (infoJson is Map<String, dynamic>) info.addAll(infoJson);
  }

  final Map<String, Map<String, Map<String, Object?>>> results =
      <String, Map<String, Map<String, Object?>>>{};
  for (final String corpusName in corpusNames) {
    results[corpusName] = <String, Map<String, Object?>>{
      'encode': <String, Object?>{},
      'decode': <String, Object?>{},
    };
  }
  for (final String corpusName in corpusNames) {
    for (final String op in <String>['encode', 'decode']) {
      for (final int quality in options.qualities) {
        final String key = '$corpusName/$op/q$quality';
        final List<double> throughputs = <double>[];
        final List<double> rmes = <double>[];
        Map<String, Object?>? representative;
        for (final Map<String, Map<String, Object?>> entries in runEntries) {
          final Map<String, Object?>? entry = entries[key];
          if (entry == null) continue;
          throughputs.add((entry['mb_per_second'] as num).toDouble());
          rmes.add((entry['rme_pct'] as num).toDouble());
          representative ??= entry;
        }
        if (throughputs.isEmpty || representative == null) {
          throw _UsageException('oracle report missing $key');
        }
        final double median = _medianOf(throughputs);
        final double rme = _medianOf(rmes);
        results[corpusName]![op]!['q$quality'] = <String, Object?>{
          'mb_per_second': _round(median, 3),
          'rme_pct': _round(rme, 3),
          'min_mb_per_second': _round(
            throughputs.reduce(math.min),
            3,
          ),
          'max_mb_per_second': _round(
            throughputs.reduce(math.max),
            3,
          ),
          'raw_bytes': representative['raw_bytes'],
          'compressed_bytes': representative['compressed_bytes'],
          'ratio': _round(
            (representative['ratio'] as num).toDouble(),
            3,
          ),
        };
      }
    }
  }

  final dynamic meta = firstDecoded?['meta'];
  final dynamic platform = meta is Map<String, dynamic> ? meta['platform'] : null;
  final Map<String, Object?> host = platform is Map<String, dynamic>
      ? <String, Object?>{
          'os': platform['os'],
          'arch': platform['arch'],
          'cpu': platform['cpu'],
          'cores': platform['cores'],
        }
      : <String, Object?>{'os': Platform.operatingSystem, 'arch': 'unknown'};

  final Map<String, Object?> baseline = <String, Object?>{
    'schema': nativeSchema,
    'tool': 'tool/oracle_rust (brotli-oracle)',
    'tool_version': info['cli_version']?.toString() ?? 'unknown',
    'brotli_crate': info['brotli_crate']?.toString() ?? 'unknown',
    'host': host,
    'lgwin': nativeLgwin,
    'mode': 'generic',
    'unit': 'MB/s',
    'statistic': 'median of independent runs',
    'runs': options.nativeRuns,
    'rounds': options.nativeRounds,
    'warmup': options.nativeWarmup,
    'method':
        'Median of ${options.nativeRuns} independent oracle runs; each run is '
        'the arithmetic mean of ${options.nativeRounds} timed rounds '
        '(std::time::Instant). MB/s = raw_bytes / mean_seconds / 1e6; '
        'min/max bound the per-run values. Encode is one-shot BrotliCompress, '
        'generic mode, lgwin $nativeLgwin, size_hint = input. Decode is strict '
        'one-shot BrotliDecompressStream; trailing bytes are rejected. '
        'Measured by tool/oracle_rust.',
    'corpus': <String, Object?>{
      for (final String name in corpusNames)
        name: <String, Object?>{
          'path': 'build/benchmark_test/corpus/$name.bin',
          'bytes': corpora[name].bytes.length,
          'sha256': corpora[name].sha256,
        },
    },
    'results': results,
  };
  final String outPath = _resolve(root, options.nativePath);
  final File outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(baseline)}\n',
  );
  stdout.writeln('wrote ${options.nativePath} (${outFile.lengthSync()} bytes)');

  final StringBuffer table = StringBuffer()
    ..writeln('corpus  op      q   median   min      max      rme    ratio')
    ..writeln('-' * 62);
  for (final String corpusName in corpusNames) {
    for (final String op in <String>['encode', 'decode']) {
      for (final int quality in options.qualities) {
        final dynamic entry = results[corpusName]![op]!['q$quality'];
        if (entry is! Map<String, Object?>) continue;
        table.writeln(
          '${corpusName.padRight(7)} ${op.padRight(7)} '
          '${quality.toString().padRight(3)} '
          '${entry['mb_per_second'].toString().padLeft(7)} '
          '${entry['min_mb_per_second'].toString().padLeft(7)} '
          '${entry['max_mb_per_second'].toString().padLeft(7)} '
          '${entry['rme_pct'].toString().padLeft(6)} '
          '${entry['ratio'].toString().padLeft(6)}',
        );
      }
    }
  }
  stdout.writeln('');
  stdout.write(table);
}

// ---------------------------------------------------------------------------
// Native decode streams
// ---------------------------------------------------------------------------

final class _Stream {
  const _Stream(this.bytes, this.source);
  final Uint8List bytes;
  final String source;
}

final class _DecodeStreams {
  _DecodeStreams({
    required this.root,
    required this.corpora,
    required this.oraclePath,
    required this.mode,
  }) : _cache = <String, _Stream>{};

  final Directory root;
  final _CorpusSet corpora;
  final String? oraclePath;
  final String mode;
  final Map<String, _Stream> _cache;

  _Stream stream(_Corpus corpusData, int quality) {
    final String key = '${corpusData.name}/q$quality';
    final _Stream? cached = _cache[key];
    if (cached != null) return cached;
    if (mode == 'self') {
      return _cache[key] = _self(corpusData, quality);
    }
    final File file = File(_path(corpusData.name, quality));
    if (file.existsSync() && file.lengthSync() > 0) {
      final Uint8List bytes = file.readAsBytesSync();
      if (_bytesEqual(v1.brotliDecompress(bytes), corpusData.bytes)) {
        return _cache[key] = _Stream(bytes, 'native');
      }
      stderr.writeln('warning: stale native stream ${file.path}; regenerating');
    }
    if (oraclePath == null) {
      if (mode == 'native') {
        throw _UsageException(
          'decode streams requested native but the Rust oracle was not found; '
          'pass --oracle or build tool/oracle_rust',
        );
      }
      return _cache[key] = _self(corpusData, quality);
    }
    file.parent.createSync(recursive: true);
    final ProcessResult result = Process.runSync(oraclePath!, <String>[
      'compress',
      '-i',
      corpusData.filePath,
      '-o',
      file.path,
      '-q',
      '$quality',
      '-w',
      '$nativeLgwin',
    ]);
    if (result.exitCode != 0) {
      throw _UsageException(
        'oracle compress failed for ${corpusData.name} q$quality '
        '(${result.exitCode}): ${result.stderr}',
      );
    }
    final Uint8List bytes = file.readAsBytesSync();
    if (!_bytesEqual(v1.brotliDecompress(bytes), corpusData.bytes)) {
      throw _UsageException(
        'oracle stream ${file.path} does not round-trip through the '
        'v1 decoder',
      );
    }
    stderr.writeln('generated native decode stream ${file.path}');
    return _cache[key] = _Stream(bytes, 'native');
  }

  _Stream _self(_Corpus corpusData, int quality) {
    final Uint8List bytes = v1.brotliCompress(
      corpusData.bytes,
      options: v1.BrotliEncodeOptions(quality: quality),
    );
    return _Stream(bytes, 'self');
  }

  String _path(String corpusName, int quality) =>
      '${root.path}${Platform.pathSeparator}build${Platform.pathSeparator}'
      'benchmark_test${Platform.pathSeparator}native_streams'
      '${Platform.pathSeparator}$corpusName.q$quality.br';
}

// ---------------------------------------------------------------------------
// Corpus
// ---------------------------------------------------------------------------

final class _Corpus {
  const _Corpus({
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.filePath,
  });

  final String name;
  final Uint8List bytes;
  final String sha256;
  final String filePath;
}

final class _CorpusSet {
  const _CorpusSet(this._byName);

  final Map<String, _Corpus> _byName;

  _Corpus operator [](String name) {
    final _Corpus? corpusData = _byName[name];
    if (corpusData == null) {
      throw _UsageException('unknown corpus $name');
    }
    return corpusData;
  }
}

_CorpusSet _loadCorpus(Directory root, String dirArg) {
  final String corpusDir = _resolve(root, dirArg);
  final Directory dir = Directory(corpusDir)..createSync(recursive: true);
  final Map<String, _Corpus> out = <String, _Corpus>{};
  for (final String name in corpusNames) {
    final File file = File(
      '${dir.path}${Platform.pathSeparator}$name.bin',
    );
    if (!file.existsSync() || file.lengthSync() == 0) {
      final Uint8List generated = name == 'text'
          ? corpus.makeText()
          : corpus.makeBinary();
      file.writeAsBytesSync(generated, flush: true);
      stderr.writeln('generated corpus $file (${generated.length} bytes)');
    }
    final Uint8List bytes = file.readAsBytesSync();
    if (bytes.length != corpus.benchmarkPayloadBytes) {
      throw _UsageException(
        'corpus $file has ${bytes.length} bytes; expected '
        '${corpus.benchmarkPayloadBytes}. Regenerate with '
        'dart run benchmark/gen_corpus.dart',
      );
    }
    out[name] = _Corpus(
      name: name,
      bytes: bytes,
      sha256: crypto.sha256.convert(bytes).toString(),
      filePath: file.path,
    );
  }
  return _CorpusSet(out);
}

// ---------------------------------------------------------------------------
// Process/environment helpers
// ---------------------------------------------------------------------------

String? _oraclePath(Directory root, String? explicit) {
  final String? env = Platform.environment['BROTLI_ORACLE'];
  final List<String> candidates = <String>[
    ?explicit,
    if (env != null && env.isNotEmpty) env,
    _resolve(
      root,
      'tool/oracle_rust/target/release/'
      'brotli-oracle${Platform.isWindows ? '.exe' : ''}',
    ),
  ];
  for (final String candidate in candidates) {
    final String path = File(candidate).isAbsolute
        ? candidate
        : _resolve(root, candidate);
    if (File(path).existsSync()) return path;
  }
  return null;
}

Directory _findRepoRoot(String? explicit) {
  final List<Directory> starts = <Directory>[
    if (explicit != null) Directory(explicit),
    Directory.current,
  ];
  for (final Directory start in starts) {
    Directory dir = start.absolute;
    for (var depth = 0; depth < 8; depth++) {
      final bool hasPubspec = File(
        '${dir.path}${Platform.pathSeparator}pubspec.yaml',
      ).existsSync();
      final bool hasLibrary = File(
        '${dir.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}brotli_neo.dart',
      ).existsSync();
      if (hasPubspec && hasLibrary) return dir;
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw _UsageException(
    'cannot find the repository root (looked for pubspec.yaml + '
    'lib/brotli_neo.dart); run from the repository or pass --root',
  );
}

String _resolve(Directory root, String path) {
  final String normalized = path.replaceAll('/', Platform.pathSeparator);
  return File(normalized).isAbsolute
      ? normalized
      : '${root.path}${Platform.pathSeparator}$normalized';
}

void _writeFile(Directory root, String path, String contents) {
  final File file = File(_resolve(root, path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents, flush: true);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

final class _UsageException implements Exception {
  const _UsageException(this.message);
  final String message;
}

final class _Options {
  _Options();

  String api = 'auto';
  String gateApi = 'auto';
  double gate = 0.8;
  String corpusDir = 'build/benchmark_test/corpus';
  String nativePath = 'benchmark/v2_native.json';
  String? jsonlPath;
  String? markdownPath;
  String format = 'table';
  String? compileLabel;
  String? root;
  String? oracle;
  bool refreshNative = false;
  bool help = false;
  bool verbose = false;
  int rounds = defaultRounds;
  int warmup = defaultWarmup;
  int nativeRuns = defaultNativeRuns;
  int nativeRounds = defaultNativeRounds;
  int nativeWarmup = defaultNativeWarmup;
  List<int> qualities = List<int>.of(defaultQualities);
  String decodeStreams = 'auto';

  static _Options parse(List<String> args) {
    final _Options options = _Options();
    for (var i = 0; i < args.length; i++) {
      final String raw = args[i];
      if (raw == '-h' || raw == '--help') {
        options.help = true;
        continue;
      }
      String name = raw;
      String? inline;
      final int equals = raw.indexOf('=');
      if (raw.startsWith('--') && equals > 0) {
        name = raw.substring(0, equals);
        inline = raw.substring(equals + 1);
      }
      String value() {
        if (inline != null) return inline;
        if (i + 1 >= args.length) {
          throw _UsageException('$name requires a value');
        }
        return args[++i];
      }

      switch (name) {
        case '--api':
          options.api = value();
        case '--gate-api':
          options.gateApi = value();
        case '--gate':
          options.gate = double.tryParse(value()) ??
              (throw _UsageException('--gate expects a number'));
        case '--corpus-dir':
          options.corpusDir = value();
        case '--native':
          options.nativePath = value();
        case '--rounds':
          options.rounds = int.tryParse(value()) ??
              (throw _UsageException('--rounds expects an integer'));
        case '--warmup':
          options.warmup = int.tryParse(value()) ??
              (throw _UsageException('--warmup expects an integer'));
        case '--native-runs':
          options.nativeRuns = int.tryParse(value()) ??
              (throw _UsageException('--native-runs expects an integer'));
        case '--native-rounds':
          options.nativeRounds = int.tryParse(value()) ??
              (throw _UsageException('--native-rounds expects an integer'));
        case '--native-warmup':
          options.nativeWarmup = int.tryParse(value()) ??
              (throw _UsageException('--native-warmup expects an integer'));
        case '--quality':
        case '--qualities':
          options.qualities = value()
              .split(',')
              .map((s) => int.tryParse(s.trim()))
              .map(
                (q) => q ?? (throw _UsageException('bad quality list')),
              )
              .toList();
        case '--jsonl':
          options.jsonlPath = value();
        case '--markdown':
          options.markdownPath = value();
        case '--format':
          options.format = value();
        case '--compile-label':
          options.compileLabel = value();
        case '--root':
          options.root = value();
        case '--oracle':
          options.oracle = value();
        case '--decode-streams':
          options.decodeStreams = value();
        case '--refresh-native':
          options.refreshNative = true;
        case '--verbose':
          options.verbose = true;
        default:
          throw _UsageException('unknown option $raw');
      }
    }
    if (!<String>{'v1', 'v2', 'auto', 'both'}.contains(options.api)) {
      throw _UsageException('--api must be v1, v2, auto or both');
    }
    if (!<String>{'auto', 'v1', 'v2', 'all', 'none'}.contains(
      options.gateApi,
    )) {
      throw _UsageException('--gate-api must be auto, v1, v2, all or none');
    }
    if (!<String>{'auto', 'self', 'native'}.contains(options.decodeStreams)) {
      throw _UsageException('--decode-streams must be auto, self or native');
    }
    if (!<String>{'table', 'markdown'}.contains(options.format)) {
      throw _UsageException('--format must be table or markdown');
    }
    if (options.gate < 0 || options.gate > 2) {
      throw _UsageException('--gate must be between 0 and 2');
    }
    if (options.rounds < 2) {
      throw _UsageException('--rounds must be >= 2');
    }
    if (options.warmup < 0) {
      throw _UsageException('--warmup must be >= 0');
    }
    if (options.nativeRuns < 1) {
      throw _UsageException('--native-runs must be >= 1');
    }
    if (options.nativeRounds < 2) {
      throw _UsageException('--native-rounds must be >= 2');
    }
    if (options.nativeWarmup < 0) {
      throw _UsageException('--native-warmup must be >= 0');
    }
    if (options.qualities.isEmpty) {
      throw _UsageException('--qualities cannot be empty');
    }
    for (final int quality in options.qualities) {
      if (quality < 0 || quality > 11) {
        throw _UsageException('quality $quality outside 0..11');
      }
    }
    if (options.refreshNative &&
        (options.jsonlPath != null || options.markdownPath != null)) {
      throw _UsageException(
        '--refresh-native does not combine with --jsonl/--markdown',
      );
    }
    return options;
  }
}

const String _usage = '''
v2_bench — brotli_neo v0.2.0 performance gate harness

Usage:
  dart run tool/v2_bench.dart [options]
  dart compile exe tool/v2_bench.dart -o build/benchmark_test/v2_bench.exe
  build/benchmark_test/v2_bench.exe [options]

Core options:
  --api v1|v2|auto|both     implementations to measure (default: auto)
  --gate-api auto|v1|v2|all|none
                            which implementation the gate applies to
                            (default: auto = v2 when available, else v1)
  --gate X                  minimum Dart/native ratio (default: 0.80)
  --corpus-dir DIR          corpus directory (default: build/benchmark_test/corpus)
  --native PATH             native baseline JSON (default: benchmark/v2_native.json)
  --qualities LIST          comma list (default: 0,1,5,9)
  --rounds N                timed rounds per operation (default: 15)
  --warmup N                warm-up calls per operation (default: 3)
  --decode-streams auto|self|native
                            decode inputs: oracle streams, self-encoded, or auto
  --jsonl PATH              write one JSON record per result
  --markdown PATH           write a Markdown table
  --format table|markdown   stdout format (default: table)
  --compile-label LABEL     override the jit/aot label
  --root DIR                repository root (default: auto-detect)
  --oracle PATH             brotli-oracle binary (default: tool/oracle_rust/...)
  --verbose                 print stack traces on failure

Native baseline:
  --refresh-native          run the Rust oracle and rewrite --native
  --native-runs N           independent oracle runs (default: 3)
  --native-rounds N         rounds per oracle run (default: 31)
  --native-warmup N         oracle warm-up (default: 5)

Gate defaults: encode q0/q1/q5 and decode q5 must reach >= 0.80x native.
q9 is report-only. Exit codes: 0 pass, 1 gate failure, 2 configuration error.
''';
