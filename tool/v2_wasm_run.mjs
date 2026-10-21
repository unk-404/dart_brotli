// Node driver for `tool/v2_wasm_bench.dart` (copied next to its generated
// `.mjs`/`.wasm` pair before running).
import { readFileSync } from 'node:fs';
import { compile } from './v2_wasm_bench.mjs';

const bytes = readFileSync(new URL('./v2_wasm_bench.wasm', import.meta.url));
const app = await compile(bytes);
const instance = await app.instantiate({});
instance.invokeMain();
