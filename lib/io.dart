/// Optional file helpers for Brotli streams.
///
/// Backed by `package:blit` 0.2.x (`BlitFile`/`Blit`), which uses native
/// random-access I/O on the VM and Web storage on the browser, so this library
/// stays web-safe: it never imports `dart:io`.
///
/// Import it explicitly:
///
/// ```dart
/// import 'package:brotli_neo/io.dart';
///
/// final raw = await brotliDecodeFile('data.txt.br');
/// await brotliEncodeFile('data.txt.br', raw);
/// ```
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'src/common/errors.dart';
import 'src/decoder/decoder.dart';
import 'src/encoder/encoder.dart';
import 'src/options.dart';

/// Input read size used by [brotliDecodeFile].
const int _fileChunkSize = 64 * 1024;

/// Decompresses the Brotli stream stored in [path].
///
/// The file is read in [_fileChunkSize] chunks and pushed through the
/// streaming [BrotliDecoder]; memory use is proportional to the decompressed
/// size, not the compressed size.
///
/// The stream is validated strictly: trailing bytes after a complete Brotli
/// stream raise [BrotliException] (`unusedBytesAfterEnd`), matching
/// [brotliDecompress].
Future<Uint8List> brotliDecodeFile(
  String path, {
  BrotliDecodeOptions options = const BrotliDecodeOptions(),
}) async {
  final file = await const Blit().open(
    path,
    options: const FileOptions(mode: FileMode.read, create: false),
  );
  try {
    final decoder = BrotliDecoder(options: options);
    final output = Uint8List(_fileChunkSize);
    final builder = BytesBuilder(copy: false);
    var fileOffset = 0;
    var eof = false;
    var done = false;
    while (!done) {
      if (!eof) {
        final input = await file.readAt(fileOffset, _fileChunkSize);
        if (input.length == 0) {
          eof = true;
          decoder.closeInput();
        } else {
          fileOffset += input.length;
          decoder.addInput(input);
        }
      }
      final status = _pump(decoder, builder, output);
      if (status == BrotliStatus.done) {
        done = true;
        break;
      }
      if (status == BrotliStatus.needMoreInput) {
        if (eof) {
          throw BrotliException(
            BrotliErrorCode.truncatedInput,
            'file ended before the Brotli stream completed',
            inputOffset: decoder.consumedInput,
          );
        }
        continue;
      }
    }
    return builder.takeBytes();
  } finally {
    await file.close();
  }
}

/// Compresses [input] and writes the stream to [path].
///
/// [create] controls whether a missing file is created. An existing file is
/// truncated to the compressed length.
Future<void> brotliEncodeFile(
  String path,
  Uint8List input, {
  BrotliEncodeOptions options = const BrotliEncodeOptions(),
  bool create = true,
}) async {
  final compressed = brotliCompress(input, options: options);
  final file = await const Blit().open(
    path,
    options: FileOptions(
      mode: FileMode.write,
      create: create,
      truncate: true,
    ),
  );
  try {
    await file.write(compressed);
    await file.flush();
  } finally {
    await file.close();
  }
}

/// Consumes decoder output until it needs more input or finishes.
BrotliStatus _pump(
  BrotliDecoder decoder,
  BytesBuilder builder,
  Uint8List output,
) {
  while (true) {
    final status = decoder.decode(output);
    final written = decoder.bytesWritten;
    if (written > 0) {
      builder.add(output.sublist(0, written));
    }
    if (status == BrotliStatus.needMoreOutput) {
      if (written == 0) {
        throw StateError('BrotliDecoder made no progress with output space');
      }
      continue;
    }
    return status;
  }
}
