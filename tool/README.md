# Maintainer generators

The files under `lib/src/common/` that contain large reference tables are
generated and committed. Users never need the reference checkout.

These scripts are for maintainers who update the reference revision:

```sh
dart run tool/gen_dictionary.dart \
  --input path/to/brotli/c/common/dictionary.bin \
  --output lib/src/common/dictionary_data.dart

dart run tool/gen_context.dart \
  --input path/to/brotli/c/common/context.c \
  --output lib/src/common/context_lookup.dart
```

Use `--check` in CI to fail when a generated file is stale.

`format_tables.dart` and `transforms.dart` are hand-ported from the reference
Java/C sources; they contain no generated blobs. `Notices` for the Google
Brotli MIT license are in the repository root `NOTICE` and `LICENSE`.
