/// CI-friendly v0.2.0 performance gate.
///
/// This is a **script**, not a `package:test` test (it intentionally lives in
/// `benchmark/`, so `dart test` does not pick it up). It:
///
/// 1. compiles `tool/v2_bench.dart` to AOT (unless `--no-compile` and the exe
///    already exists),
/// 2. runs the AOT harness (`--api v2` and the 0.80 gate by default),
/// 3. runs the same harness on the JIT for a report-only comparison,
/// 4. writes `build/benchmark_test/v2_gate.jsonl` + `v2_gate.md` and prints the
///    combined Markdown,
/// 5. exits with the AOT gate status (0 pass, 1 below gate, 2 setup error).
///
/// Usage:
///   dart run benchmark/v2_gate_test.dart
///   dart run benchmark/v2_gate_test.dart --api v1 --gate 0.8
///   dart run benchmark/v2_gate_test.dart --exe build/benchmark_test/v2_bench.exe --no-compile
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on _UsageException catch (error) {
    stderr.writeln('v2_gate: ${error.message}');
    stderr.writeln(_usage);
    exit(64);
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final Directory root;
  try {
    root = _findRepoRoot(options.root);
  } on _UsageException catch (error) {
    stderr.writeln('v2_gate: ${error.message}');
    exit(2);
  }

  final File exe = File(_resolve(root, options.exe));
  final File harness = File(
    '${root.path}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'v2_bench.dart',
  );
  final bool stale =
      exe.existsSync() &&
      harness.existsSync() &&
      harness.lastModifiedSync().isAfter(exe.lastModifiedSync());
  if (!exe.existsSync() || (stale && !options.noCompile)) {
    if (options.noCompile) {
      stderr.writeln(
        'v2_gate: ${options.exe} does not exist and --no-compile was passed',
      );
      exit(2);
    }
    if (stale) {
      stdout.writeln('recompiling: tool/v2_bench.dart is newer than the exe');
    }
    final String dart = options.dart ?? _dartExecutable();
    stdout.writeln('compiling tool/v2_bench.dart -> ${options.exe}');
    final ProcessResult compile = await Process.run(
      dart,
      <String>[
        'compile',
        'exe',
        'tool/v2_bench.dart',
        '-o',
        exe.path,
      ],
      workingDirectory: root.path,
    );
    if (compile.exitCode != 0) {
      stderr.writeln('v2_gate: compile failed (${compile.exitCode})');
      stderr.write(compile.stdout);
      stderr.write(compile.stderr);
      exit(2);
    }
    stdout.writeln('compiled ${exe.path}');
  }

  if (options.refreshNative) {
    stdout.writeln('refreshing native baseline from the local Rust oracle');
    final ProcessResult refresh = await Process.run(
      options.dart ?? _dartExecutable(),
      <String>[
        'run',
        'tool/v2_bench.dart',
        '--refresh-native',
        '--native',
        options.native,
      ],
      workingDirectory: root.path,
    );
    stdout.write(refresh.stdout);
    stderr.write(refresh.stderr);
    if (refresh.exitCode != 0) {
      stderr.writeln('v2_gate: native refresh failed (${refresh.exitCode})');
      exit(2);
    }
  }

  final Directory outDir = Directory(
    _resolve(root, options.outDir),
  )..createSync(recursive: true);
  final String aotJsonl = '${outDir.path}${Platform.pathSeparator}v2_gate_aot.jsonl';
  final String aotMd = '${outDir.path}${Platform.pathSeparator}v2_gate_aot.md';
  final String jitJsonl = '${outDir.path}${Platform.pathSeparator}v2_gate_jit.jsonl';
  final String jitMd = '${outDir.path}${Platform.pathSeparator}v2_gate_jit.md';

  final List<String> common = <String>[
    '--api',
    options.api,
    '--gate',
    options.gate.toString(),
    '--native',
    options.native,
  ];

  stdout.writeln('running AOT gate: ${options.api} @ ${options.gate}');
  final ProcessResult aot = await Process.run(exe.path, <String>[
    ...common,
    '--gate-api',
    options.api,
    '--compile-label',
    'aot',
    '--jsonl',
    aotJsonl,
    '--markdown',
    aotMd,
  ], workingDirectory: root.path);
  stdout.write(aot.stdout);
  stderr.write(aot.stderr);
  if (aot.exitCode != 0 && aot.exitCode != 1) {
    stderr.writeln('v2_gate: AOT harness failed (${aot.exitCode})');
    exit(2);
  }

  String jitMarkdown = '';
  if (!options.skipJit) {
    stdout.writeln('');
    stdout.writeln('running JIT report (gate disabled)');
    final ProcessResult jit = await Process.run(
      options.dart ?? _dartExecutable(),
      <String>[
        'run',
        'tool/v2_bench.dart',
        ...common,
        '--gate-api',
        'none',
        '--compile-label',
        'jit',
        '--jsonl',
        jitJsonl,
        '--markdown',
        jitMd,
      ],
      workingDirectory: root.path,
    );
    stdout.write(jit.stdout);
    stderr.write(jit.stderr);
    if (jit.exitCode != 0) {
      stderr.writeln('v2_gate: JIT report failed (${jit.exitCode})');
      exit(2);
    }
    jitMarkdown = _readIfExists(jitMd);
  }

  final String aotMarkdown = _readIfExists(aotMd);
  final String combinedMarkdown =
      '## AOT — gated at ${options.gate.toStringAsFixed(2)}× native\n\n'
      '$aotMarkdown\n'
      '${options.skipJit ? '' : '## JIT — report only\n\n$jitMarkdown\n'}';

  final File combinedMd = File(
    '${outDir.path}${Platform.pathSeparator}v2_gate.md',
  )..writeAsStringSync(combinedMarkdown);
  final StringBuffer jsonl = StringBuffer();
  jsonl.write(_readIfExists(aotJsonl));
  if (!options.skipJit) jsonl.write(_readIfExists(jitJsonl));
  final File combinedJsonl = File(
    '${outDir.path}${Platform.pathSeparator}v2_gate.jsonl',
  )..writeAsStringSync(jsonl.toString());

  stdout.writeln('');
  stdout.write(combinedMarkdown);
  stdout.writeln('markdown: ${combinedMd.path}');
  stdout.writeln('jsonl: ${combinedJsonl.path}');
  stdout.writeln(
    'AOT gate: ${aot.exitCode == 0 ? 'PASS' : 'FAIL'} (exit ${aot.exitCode})',
  );
  exit(aot.exitCode);
}

String _readIfExists(String path) {
  final File file = File(path);
  return file.existsSync() ? file.readAsStringSync() : '';
}

String _dartExecutable() {
  final String? env = Platform.environment['DART'];
  if (env != null && env.isNotEmpty) return env;
  final String resolved = Platform.resolvedExecutable;
  if (File(resolved).uri.pathSegments.last.startsWith('dart')) {
    return resolved;
  }
  return 'dart';
}

Directory _findRepoRoot(String? explicit) {
  final List<Directory> starts = <Directory>[
    if (explicit != null) Directory(explicit),
    Directory.current,
  ];
  for (final Directory start in starts) {
    Directory dir = start.absolute;
    for (var depth = 0; depth < 8; depth++) {
      if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync() &&
          File(
            '${dir.path}${Platform.pathSeparator}lib'
            '${Platform.pathSeparator}brotli_neo.dart',
          ).existsSync()) {
        return dir;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw _UsageException(
    'cannot find the repository root (pubspec.yaml + lib/brotli_neo.dart); '
    'run from the repository or pass --root',
  );
}

String _resolve(Directory root, String path) {
  final String normalized = path.replaceAll('/', Platform.pathSeparator);
  return File(normalized).isAbsolute
      ? normalized
      : '${root.path}${Platform.pathSeparator}$normalized';
}

final class _UsageException implements Exception {
  const _UsageException(this.message);
  final String message;
}

final class _Options {
  _Options();

  String exe = 'build/benchmark_test/v2_bench.exe';
  String api = 'v2';
  double gate = 0.8;
  String outDir = 'build/benchmark_test';
  String native = 'benchmark/v2_native.json';
  String? root;
  String? dart;
  bool noCompile = false;
  bool skipJit = false;
  bool refreshNative = false;
  bool help = false;

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
        case '--exe':
          options.exe = value();
        case '--api':
          options.api = value();
        case '--gate':
          options.gate = double.tryParse(value()) ??
              (throw _UsageException('--gate expects a number'));
        case '--out-dir':
          options.outDir = value();
        case '--native':
          options.native = value();
        case '--root':
          options.root = value();
        case '--dart':
          options.dart = value();
        case '--no-compile':
          options.noCompile = true;
        case '--skip-jit':
          options.skipJit = true;
        case '--refresh-native':
          options.refreshNative = true;
        default:
          throw _UsageException('unknown option $raw');
      }
    }
    if (!<String>{'v1', 'v2'}.contains(options.api)) {
      throw _UsageException('--api must be v1 or v2');
    }
    if (options.gate < 0 || options.gate > 2) {
      throw _UsageException('--gate must be between 0 and 2');
    }
    return options;
  }
}

const String _usage = '''
v2_gate — compile/run the AOT performance gate and emit CI JSONL/Markdown

Usage:
  dart run benchmark/v2_gate_test.dart [options]

Options:
  --exe PATH        AOT harness path (default: build/benchmark_test/v2_bench.exe)
  --api v1|v2       implementation to gate (default: v2)
  --gate X          Dart/native ratio required (default: 0.80)
  --out-dir DIR     output directory (default: build/benchmark_test)
  --native PATH     native baseline (default: benchmark/v2_native.json)
  --no-compile      fail instead of compiling when --exe is missing
  --skip-jit        skip the report-only JIT run
  --refresh-native  regenerate --native with the local Rust oracle first
                    (recommended in CI: native and Dart must share a machine)
  --dart PATH       Dart executable used for compile/JIT (default: current SDK)
  --root DIR        repository root (default: auto-detect)

Writes v2_gate.jsonl (AOT + JIT records) and v2_gate.md, prints the Markdown,
and exits with the AOT gate status. The gate covers encode q0/q1/q5 and decode
q5; q9 is report-only. This file is deliberately not under test/.
''';
