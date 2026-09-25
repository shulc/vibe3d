# Browser interchange I/O

`tools/build_web.sh` builds the editor and separate native-library wasm
instances. The editor is LDC/D with DRuntime;
`tools/build_web_assimp.sh` builds Assimp and
`web/assimp_module.cpp` with Emscripten's `-fwasm-exceptions`. No C++ object,
exception or pointer crosses into the editor instance. The page initializes
Assimp first, then starts the editor. If Assimp cannot load, the editor starts
with its interchange commands gated off.

`web/lib/assimp_bridge.js` copies picked files to Assimp's MEMFS, calls its
synchronous import/export entry points, copies a versioned V3DI v2 buffer
between wasm memories, and copies exported files back. `source/io/assimp_wire.d`
validates counts, offsets and indices before constructing editor objects. The
wire carries parts, node transforms, polygon corners, per-corner UV, material
names/colors and visibility. The browser picker accepts sidecars (`.mtl`,
`.bin`, images); an OBJ or glTF export with sidecars downloads as a ZIP.

To test the module without the editor:

```sh
node tools/test_web_assimp_module.mjs \
  "$PWD/.build/web-assimp" /path/to/bindbc-assimp6/extern/assimp
```

For the full browser command path, run `tools/test_web_assimp_io.sh`.
This exercises OBJ/glTF/GLB/FBX import/export through the editor commands and
rejects a malformed GLB. Interchange remains lossy by the desktop policy:
mesh geometry, UVs, layer names/transforms and the visibility bit are carried;
other native document data belongs in `.v3d`.
