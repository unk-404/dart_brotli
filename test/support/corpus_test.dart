import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'corpus.dart';

void main() {
  final corpus = Corpus.load();

  test('manifest has the expected number of vectors', () {
    expect(corpus.entries.length, 22);
    expect(corpus.malformed.length, 23);
  });

  test('every raw/compressed pair matches its manifest hash', () {
    for (final entry in corpus.entries) {
      final raw = corpus.rawBytes(entry);
      final compressed = corpus.compressedBytes(entry);
      expect(raw.length, entry.rawBytes, reason: entry.name);
      expect(compressed.length, entry.compressedBytes, reason: entry.name);
      expect(sha256.convert(raw).toString(), entry.rawSha256,
          reason: entry.name);
      expect(sha256.convert(compressed).toString(), entry.compressedSha256,
          reason: entry.name);
    }
  });
}
