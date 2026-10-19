// Normalizes benchmark_test JSONL and Rust-oracle JSONL into the same
// canonical records, so bench-svg can compare implementations on identical
// operations.
//
// Usage:
//   dart run benchmark/normalize_bench.dart \
//     --dart-dir build/benchmark_test \
//     --rust build/benchmark_test/rust.jsonl \
//     --out-dir build/benchmark_test/normalized
import 'dart:convert';
import 'dart:io';

const Set<String> _targets = <String>{'jit', 'aot', 'js', 'wasm'};

void main(List<String> args) {
  final dartDir = _arg(args, '--dart-dir', 'build/benchmark_test');
  final rustPath = _arg(args, '--rust', '$dartDir/rust.jsonl');
  final outDir = _arg(args, '--out-dir', '$dartDir/normalized');
  Directory(outDir).createSync(recursive: true);

  for (final target in _targets) {
    final input = File('$dartDir/brotli_$target.jsonl');
    if (!input.existsSync()) {
      stderr.writeln('missing $input');
      exit(1);
    }
    final records = _normalizeDart(input);
    _write('$outDir/dart_$target.jsonl', records);
  }

  final rust = File(rustPath);
  if (!rust.existsSync()) {
    stderr.writeln('missing $rust');
    exit(1);
  }
  _write('$outDir/rust.jsonl', _normalizeRust(rust));
}

List<Map<String, Object?>> _normalizeDart(File input) {
  final result = <Map<String, Object?>>[];
  for (final line in input.readAsLinesSync()) {
    if (!line.startsWith('{')) continue;
    final raw = jsonDecode(line) as Map<String, dynamic>;
    final name = raw['name'] as String;
    // benchmark_test prefixes the enclosing group name, e.g.
    // "brotli core decode.text.1024KiB.q5"; match the trailing operation id.
    final match =
        RegExp(r'(decode|encode)\.(text|binary)\.(\d+)KiB\.q(\d+)$')
            .firstMatch(name);
    if (match == null) continue;
    final op = match.group(1)!;
    final payload = match.group(2)!;
    final kib = int.parse(match.group(3)!);
    final quality = int.parse(match.group(4)!);
    final throughput = raw['throughput'] as Map<String, dynamic>;
    final value = (throughput['value'] as num).toDouble() * kib * 1024;
    final stats = raw['statistics'] as Map<String, dynamic>?;
    result.add(<String, Object?>{
      'id': '$op.$payload.${kib}KiB.q$quality',
      'group': op == 'decode' ? 'Decode' : 'Encode',
      'label': '${op == 'decode' ? 'Decode' : 'Encode'} $payload · Q$quality',
      'unit': 'B/s',
      'direction': 'higher',
      'value': value,
      if (stats != null && stats['relativeMarginOfError'] != null)
        'stats': <String, Object?>{
          'rme_pct': stats['relativeMarginOfError'],
        },
    });
  }
  return result;
}

List<Map<String, Object?>> _normalizeRust(File input) {
  final result = <Map<String, Object?>>[];
  for (final line in input.readAsLinesSync()) {
    if (!line.startsWith('{')) continue;
    final raw = jsonDecode(line) as Map<String, dynamic>;
    final id = raw['id'] as String;
    final params = (raw['params'] as Map<String, dynamic>?) ?? const {};
    final payload = (params['input'] as String?) ?? _rustPayload(id);
    final op = id.contains('.compress.') ? 'encode' : 'decode';
    final quality = params['quality']?.toString() ?? '5';
    final unit = (raw['unit'] as String?) ?? 'MB/s';
    var value = (raw['value'] as num).toDouble();
    if (unit == 'MB/s') {
      value *= 1000000;
    } else if (unit == 'MiB/s') {
      value *= 1024 * 1024;
    } else if (unit == 'KB/s') {
      value *= 1000;
    } else if (unit == 'B/s') {
      // already bytes/s
    }
    final stats = raw['stats'] as Map<String, dynamic>?;
    result.add(<String, Object?>{
      'id': '$op.$payload.1024KiB.q$quality',
      'group': op == 'encode' ? 'Encode' : 'Decode',
      'label': '${op == 'encode' ? 'Encode' : 'Decode'} $payload · Q$quality',
      'unit': 'B/s',
      'direction': 'higher',
      'value': value,
      if (stats != null && stats['rme_pct'] != null)
        'stats': <String, Object?>{'rme_pct': stats['rme_pct']},
    });
  }
  return result;
}

String _rustPayload(String id) {
  for (final name in <String>['text', 'binary']) {
    if (id.endsWith('.$name')) return name;
  }
  return 'text';
}

void _write(String path, List<Map<String, Object?>> records) {
  final sink = StringBuffer();
  for (final record in records) {
    sink.writeln(jsonEncode(record));
  }
  File(path).writeAsStringSync(sink.toString());
  stdout.writeln('wrote $path (${records.length} rows)');
}

String _arg(List<String> args, String name, String fallback) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}
