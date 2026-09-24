# Separate Assimp wasm proof

This is a standalone experiment. It does not change the editor or enable its
file menu. `assimp_module.wasm` contains Assimp and C++ exception support;
`d_consumer.wasm` contains DRuntime and D exception support. JS copies a
versioned binary scene between their separate memories. Neither runtime is
linked into the other's module.

Build with the repository's pinned `bindbc-assimp6/extern/assimp` source,
LDC 1.43.0, and the Emscripten DRuntime libraries built by `tools/build_web.sh`:

```sh
bash tools/web_assimp_spike/build.sh \
  /path/to/bindbc-assimp6/extern/assimp \
  /path/to/ldc2-1.43.0-linux-x86_64 \
  /path/to/vibe3d/.build/web-runtime/lib \
  /path/to/worktree/scratch
node tools/web_assimp_spike/run.mjs \
  /path/to/worktree/scratch \
  /path/to/bindbc-assimp6/extern/assimp/test/models/glTF2/BoxTextured-glTF-Binary/BoxTextured.glb
```

For a browser run, copy `browser.html` to the output directory as
`browser.html`, copy the GLB fixture there as `fixture.glb`, serve that
directory over HTTP, and open `/browser.html` in Chromium. The page reports
`PASS source=4696 wire=808 parts=1 vertices=24 faces=12` for the pinned fixture.

`SceneWire v1` is deliberately small: magic, version, part count, then per-part
name, world-space float32 XYZ, CSR face offsets and indices, and float32 UV
per corner. The importer reverses face order for mirrored nodes. The two wasm
memories each hold a copy of the wire while JS transfers it. The format does
not yet carry materials, visibility or morph maps, and the D side only
validates/counts the scene; it does not populate `ImportedScene` yet. The
experiment is an isolation and transport proof, not a finished codec.
