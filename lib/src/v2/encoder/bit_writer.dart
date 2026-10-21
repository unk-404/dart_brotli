/// Conditional v2 bit writer: 64-bit on VM/AOT/dart2wasm, 32-bit on dart2js.
library;

export 'bit_writer_vm.dart' if (dart.library.js_util) 'bit_writer_js.dart';
