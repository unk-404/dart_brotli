/// Conditional wide ring-copy backend.
///
/// The VM/AOT implementation uses 64-bit `ByteData` loads/stores (fast, and
/// `dart2js` rejects those accessors at compile time). On the Web the helper
/// falls back to 32-bit accesses, which dart2js supports.
///
/// Both implementations have identical semantics and are byte-identical; the
/// caller only uses them for forward overlapping copies where
/// `dst - src >= 8`, so word-at-a-time forward copies cannot read bytes that
/// have not been written yet.
library;

export 'wide_copy_vm.dart' if (dart.library.js_interop) 'wide_copy_web.dart';
