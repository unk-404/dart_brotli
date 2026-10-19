import 'package:brotli_neo/src/common/context.dart';
import 'package:brotli_neo/src/common/context_lookup.dart';
import 'package:test/test.dart';

void main() {
  test('context table shape', () {
    expect(kContextLookupTable.length, 2048);
    expect(contextTableForMode(contextModeLsb6).length, 512);
  });

  test('LSB6 context is the low six bits of the previous byte', () {
    for (var b = 0; b < 256; b++) {
      expect(contextId(contextModeLsb6, b, 0), b & 63);
    }
  });

  test('MSB6 context is the high six bits of the previous byte', () {
    expect(contextId(contextModeMsb6, 0x00, 0), 0);
    expect(contextId(contextModeMsb6, 0xFF, 0), 63);
    expect(contextId(contextModeMsb6, 0x41, 0), 16);
  });

  test('UTF8 and signed modes stay in the 6-bit range', () {
    for (final mode in [contextModeUtf8, contextModeSigned]) {
      for (var p1 = 0; p1 < 256; p1++) {
        final id = contextId(mode, p1, p1);
        expect(id, inInclusiveRange(0, 63));
      }
    }
  });
}
