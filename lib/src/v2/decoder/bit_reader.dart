/// Backend selection for the v2 decoder bit reader.
///
/// VM/AOT gets the 64-bit accumulator implementation; dart2js/dart2wasm fall
/// back to the 32-bit-safe port. Both expose the same `BitReader` API and
/// produce byte-identical output.
library;

export 'bit_reader_input.dart';
export 'bit_reader_64.dart' if (dart.library.js_interop) 'bit_reader_32.dart';
