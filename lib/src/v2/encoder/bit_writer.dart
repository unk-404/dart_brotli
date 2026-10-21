/// Conditional v2 bit writer: 64-bit on VM/AOT, 32-bit on Web.
library;

export 'bit_writer_vm.dart' if (dart.library.js_interop) 'bit_writer_js.dart';
