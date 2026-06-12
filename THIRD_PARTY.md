# Third-party components

Vibe3D is MIT-licensed. It links and/or bundles the third-party components
below. Each is redistributable under a license compatible with MIT; the full
license texts are available in each project's own repository.

## Asset import/export

| Component | Role | License |
|---|---|---|
| [assimp](https://github.com/assimp/assimp) (Open Asset Import Library) | OBJ / glTF / FBX import and OBJ / glTF export, loaded dynamically at runtime | BSD-3-Clause |
| [bindbc-assimp6](https://github.com/shulc/bindbc-assimp6) | D bindings to the assimp C API (dynamic `dlopen` loader) | BSL-1.0 |
| [lwo2-writer](https://github.com/shulc/D-Lwo2Writer) | Clean-room LWO2 (LightWave object) writer | MIT |

**assimp bundling.** Release builds ship the assimp shared library
(`libassimp.so.6` / `assimp.dll` / `libassimp.6.dylib`) alongside the
executable; the BSD-3-Clause license permits binary redistribution with
attribution. The library is loaded at runtime — a build with no bundled and no
system libassimp still runs, with the OBJ/glTF/FBX import/export menu items
disabled (the native `.v3d` document format and LWO save/load are pure D and
always available).

## Other declared dependencies

The remaining build dependencies are declared in `dub.json` and fetched by DUB
(SDL2, OpenGL, Dear ImGui, D-YAML, nativefiledialog-extended, OpenSubdiv, and
the bindbc loaders). They are linked, not vendored; consult each package for
its license.
