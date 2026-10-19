// Generates lib/src/common/dictionary_data.dart from the reference
// dictionary.bin. Maintainer-only: the generated file is committed, so users
// never need the reference checkout.
//
// Usage:
//   dart run tool/gen_dictionary.dart \
//     --input path/to/brotli/c/common/dictionary.bin \
//     --output lib/src/common/dictionary_data.dart [--check]
import 'dart:convert';
import 'dart:io';

const String _sizeBits = '''
const List<int> kDictionarySizeBitsByLength = <int>[
  0, 0, 0, 0, 10, 10, 11, 11,
  10, 10, 10, 10, 10, 9, 9, 8,
  7, 7, 8, 7, 7, 6, 6, 5,
  5, 0, 0, 0, 0, 0, 0, 0,
];
''';

void main(List<String> args) {
  final input = _arg(args, '--input', '');
  final output = _arg(args, '--output', 'lib/src/common/dictionary_data.dart');
  final check = args.contains('--check');
  if (input.isEmpty) {
    stderr.writeln('usage: --input path/to/dictionary.bin [--output ...]');
    exit(2);
  }

  final bytes = File(input).readAsBytesSync();
  if (bytes.length != 122784) {
    stderr.writeln('unexpected dictionary size: ${bytes.length}');
    exit(1);
  }
  final base64Text = base64.encode(bytes);
  final chunks = <String>[];
  for (var i = 0; i < base64Text.length; i += 100) {
    final end = i + 100 < base64Text.length ? i + 100 : base64Text.length;
    chunks.add("    '${base64Text.substring(i, end)}'");
  }

  final source =
      '''
// GENERATED FILE - do not edit by hand.
//
// RFC 7932 static dictionary payload (122,784 bytes), generated from
// google/brotli c/common/dictionary.bin (MIT). See NOTICE.
//
// Decoded lazily with base64; keep this file out of hot paths.
library;

import 'dart:convert';
import 'dart:typed_data';

const String _dictionaryBase64 =
${chunks.join('\n')};

/// The RFC 7932 static dictionary payload.
final Uint8List kDictionaryData = base64.decode(_dictionaryBase64);

$_sizeBits''';

  _write(output, source, check: check);
}

String _arg(List<String> args, String name, String fallback) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}

void _write(String path, String content, {required bool check}) {
  final file = File(path);
  if (check) {
    if (!file.existsSync() || file.readAsStringSync() != content) {
      stderr.writeln('$path is out of date; re-run the generator');
      exit(1);
    }
    stdout.writeln('$path is up to date');
    return;
  }
  file.writeAsStringSync(content);
  stdout.writeln('wrote $path (${content.length} chars)');
}
