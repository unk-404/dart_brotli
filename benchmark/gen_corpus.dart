// Writes the deterministic benchmark corpus for the Rust oracle.
//
// Usage: dart run benchmark/gen_corpus.dart [outputDir]
import 'dart:io';

import 'corpus.dart';

void main(List<String> args) {
  final dirPath = args.isNotEmpty ? args.first : 'build/benchmark_test/corpus';
  final dir = Directory(dirPath)..createSync(recursive: true);
  File('${dir.path}/text.bin').writeAsBytesSync(makeText());
  File('${dir.path}/binary.bin').writeAsBytesSync(makeBinary());
  stdout.writeln('wrote ${dir.path}/{text,binary}.bin');
}
