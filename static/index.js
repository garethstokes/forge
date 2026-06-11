// Boot loader for the evals-ui miso wasm32-wasi browser reactor.
// Pattern from miso's sample-app (static/index.js), with the WASI shim
// vendored locally (static/wasi_shim/ = @bjorn3/browser_wasi_shim 0.3.0 dist).
import { WASI, OpenFile, File, ConsoleStdout } from "./wasi_shim/index.js";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

const args = [];
const env = ["GHCRTS=-H64m"];
const fds = [
  new OpenFile(new File([])), // stdin
  ConsoleStdout.lineBuffered((msg) => console.log(`[WASI stdout] ${msg}`)),
  ConsoleStdout.lineBuffered((msg) => console.warn(`[WASI stderr] ${msg}`)),
];
const options = { debug: false };
const wasi = new WASI(args, env, fds, options);

const instance_exports = {};
const { instance } = await WebAssembly.instantiateStreaming(fetch("evals-ui.wasm"), {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghc_wasm_jsffi(instance_exports),
});
Object.assign(instance_exports, instance.exports);

wasi.initialize(instance); // calls the reactor's _initialize()
await instance.exports.hs_start();
