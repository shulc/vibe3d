#!/usr/bin/env python3
"""Hash every tool, source and configuration input to ldc-build-runtime."""
from hashlib import sha256
from pathlib import Path
import subprocess
import sys

ldc, builder, toolchain, runtime_root = map(Path, sys.argv[1:])
h = sha256()

def add(label: str, path: Path) -> None:
    h.update(label.encode() + b"\0")
    h.update(path.resolve().as_posix().encode() + b"\0")
    h.update(path.read_bytes())

add("ldc", ldc)
add("ldc-build-runtime", builder)
add("emscripten-toolchain", toolchain)
h.update(subprocess.check_output([str(ldc), "--version"]))
h.update(b"triple=wasm32-unknown-emscripten\0target=Emscripten;UNIX\0ninja=1")

# ldc-build-runtime's complete D inputs are the downloaded source archive plus
# runtime/druntime and runtime/phobos. Hash both archive and expanded trees so
# a local mutation, a changed download, or generated runtime config invalidates
# the cache deterministically. Build outputs and the stamp itself are excluded.
for relative in ("ldc-src.zip", "ldc-src/runtime/CMakeLists.txt",
                 "ldc-src/runtime/druntime", "ldc-src/runtime/phobos"):
    path = runtime_root / relative
    if path.is_file():
        add(relative, path)
    elif path.is_dir():
        for child in sorted(p for p in path.rglob("*") if p.is_file()):
            add(child.relative_to(runtime_root).as_posix(), child)

print(h.hexdigest())
