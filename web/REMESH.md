# Browser Quad Remesh

`tools/build_web_remesh.sh` compiles the pinned D-AutoRemesher C++ core,
geogram and the existing OBJ CLI with Emscripten. It uses the local
`~/Code/D-AutoRemesher` checkout by default, or clones the pinned commit into
`.build/web-remesh-source` when that checkout is absent. Override the source
with `VIBE3D_AUTOREMESHER_SOURCE`.

The browser module has its own WebAssembly memory. `web/remesh_worker.js` loads
it inside a disposable Web Worker. The editor copies a triangulated OBJ into
the worker and receives a polygon OBJ back through `web/lib/remesh_bridge.js`.
`RemeshJob` keeps the desktop region extraction, open-patch fallback, stitch,
stale-source check and undoable landing command. Closing the modal terminates
the worker; a geogram abort cannot stop the editor wasm.

The upstream native build pins TBB to one worker. This build uses the small
serial TBB interface under `web/remesh_tbb`, so no shared memory or browser
cross-origin isolation is needed.

Checks:

```sh
node tools/test_web_remesh_module.mjs
tools/test_web_remesh.sh
```
