import 'package:brotli_neo/brotli_neo.dart';

void main() {
  // One-shot APIs (implementation lands in D1/E0).
  const options = BrotliEncodeOptions(quality: 5);
  print('brotli_neo: quality=${options.quality}, lgwin=${options.lgwin}');

  final input = Bytes.fromList([1, 2, 3, 4]);
  print('input: ${input.length} bytes');
}
