// Generates lib/src/common/context_lookup.dart from the reference context.c.
// Maintainer-only: the generated file is committed.
//
// Usage:
//   dart run tool/gen_context.dart \
//     --input path/to/brotli/c/common/context.c \
//     --output lib/src/common/context_lookup.dart [--check]
import 'dart:io';

void main(List<String> args) {
  final input = _arg(args, '--input', '');
  final output = _arg(args, '--output', 'lib/src/common/context_lookup.dart');
  final check = args.contains('--check');
  if (input.isEmpty) {
    stderr.writeln('usage: --input path/to/context.c [--output ...]');
    exit(2);
  }

  var text = File(input).readAsStringSync();
  final start = text.indexOf('_kBrotliContextLookupTable[2048]');
  if (start < 0) {
    stderr.writeln('context table declaration not found');
    exit(1);
  }
  final open = text.indexOf('{', start);
  final close = text.indexOf('};', open);
  if (open < 0 || close < 0) {
    stderr.writeln('context table body not found');
    exit(1);
  }
  text = text.substring(open + 1, close);
  // Drop comments so numbers inside them are not captured.
  text = text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  text = text.replaceAll(RegExp(r'//[^\n]*'), '');
  final values = RegExp(r'\b\d+\b')
      .allMatches(text)
      .map((m) => int.parse(m.group(0)!))
      .toList();
  if (values.length != 2048) {
    stderr.writeln('expected 2048 context values, got ${values.length}');
    exit(1);
  }

  final rows = <String>[];
  for (var i = 0; i < values.length; i += 16) {
    final end = i + 16 < values.length ? i + 16 : values.length;
    rows.add('  ${values.sublist(i, end).join(', ')},');
  }

  final source =
      '''
// GENERATED FILE - do not edit by hand.
//
// RFC 7932 context lookup table (4 modes x 512 bytes), generated from
// google/brotli c/common/context.c (MIT). See NOTICE.
library;

import 'dart:typed_data';

const List<int> _kContextLookupValues = <int>[
${rows.join('\n')}
];

/// Context lookup table: `mode * 512 + byte`.
final Uint8List kContextLookupTable =
    Uint8List.fromList(_kContextLookupValues);
''';

  final file = File(output);
  if (check) {
    if (!file.existsSync() || file.readAsStringSync() != source) {
      stderr.writeln('$output is out of date; re-run the generator');
      exit(1);
    }
    stdout.writeln('$output is up to date');
    return;
  }
  file.writeAsStringSync(source);
  stdout.writeln('wrote $output (${source.length} chars)');
}

String _arg(List<String> args, String name, String fallback) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}
