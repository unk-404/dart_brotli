/// Fixed VM-vs-Web parity vectors for the v2 encoder.
///
/// The SHA-256 constants are the VM/AOT output (see `test/v2/api_test.dart`);
/// the browser test asserts the dart2js build produces the same bytes.
library;

import 'dart:typed_data';

class ParityVector {
  const ParityVector(this.kind, this.size, this.quality, this.sha256);

  final int kind;
  final int size;
  final int quality;
  final String sha256;

  Uint8List input() {
    final out = Uint8List(size);
    var seed = 12345;
    for (var i = 0; i < size; i++) {
      switch (kind) {
        case 0:
          out[i] = (i * 17 + i ~/ 11) & 0xFF;
        case 1:
          out[i] = 0;
        case 2:
          seed = (seed * 1664525 + 1013904223) & 0x7FFFFFFF;
          out[i] = (seed >> 16) & 0xFF;
        case 3:
          out[i] =
              'brotli compression pure dart web parity test '.codeUnits[i % 43];
      }
    }
    return out;
  }
}

const List<ParityVector> parityVectors = <ParityVector>[
  ParityVector(
    0,
    256,
    0,
    '6f4f4ee17a7a79ec6d4044465dea6ef48192e8ead6776ba11f76eeb358291009',
  ),
  ParityVector(
    1,
    1024,
    5,
    'fbadb9f8d369d1122fa64e6c7d9afe9a80343d6e604636b5ff5e6b22dc030547',
  ),
  ParityVector(
    2,
    4096,
    5,
    '6ffc7230bdc455374628b435d6e96207120397fa6d8831d79787eef6e0b48d3b',
  ),
  ParityVector(
    3,
    8192,
    5,
    'a1ca5894e18b53209a80c1b079e7331c939b7f6c5b15aabb0e2cab3109468f8a',
  ),
];
