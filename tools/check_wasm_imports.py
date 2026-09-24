#!/usr/bin/env python3
"""Inspect the WebAssembly import section without converting it to text."""
import pathlib
import sys

FORBIDDEN = {"dlopen", "dlsym", "dlclose", "dlerror"}

def uleb(data, pos):
    value = shift = 0
    while True:
        b = data[pos]; pos += 1
        value |= (b & 0x7f) << shift
        if b < 0x80: return value, pos
        shift += 7

def name(data, pos):
    n, pos = uleb(data, pos)
    return data[pos:pos+n].decode("utf-8"), pos+n

def imports(blob):
    if blob[:8] != b"\0asm\x01\0\0\0": raise ValueError("not wasm v1")
    pos = 8
    while pos < len(blob):
        sid = blob[pos]; pos += 1
        size, pos = uleb(blob, pos); end = pos + size
        if sid != 2: pos = end; continue
        count, pos = uleb(blob, pos); out = []
        for _ in range(count):
            mod, pos = name(blob, pos); field, pos = name(blob, pos)
            kind = blob[pos]; pos += 1
            if kind == 0: _, pos = uleb(blob, pos)
            elif kind == 1:
                pos += 1; flags, pos = uleb(blob, pos); _, pos = uleb(blob, pos)
                if flags & 1: _, pos = uleb(blob, pos)
            elif kind == 2:
                flags, pos = uleb(blob, pos); _, pos = uleb(blob, pos)
                if flags & 1: _, pos = uleb(blob, pos)
            elif kind == 3: pos += 2
            elif kind == 4: _, pos = uleb(blob, pos); _, pos = uleb(blob, pos)
            else: raise ValueError(f"unknown import kind {kind}")
            out.append((mod, field))
        return out
    return []

def exports(blob):
    if blob[:8] != b"\0asm\x01\0\0\0": raise ValueError("not wasm v1")
    pos = 8
    while pos < len(blob):
        sid = blob[pos]; pos += 1
        size, pos = uleb(blob, pos); end = pos + size
        if sid != 7: pos = end; continue
        count, pos = uleb(blob, pos); out = []
        for _ in range(count):
            field, pos = name(blob, pos)
            kind = blob[pos]; pos += 1
            _, pos = uleb(blob, pos)
            out.append((field, kind))
        return out
    return []

# The browser file bridge (task 7420): the JS library's two functions are
# imported from `env`, and the two D callbacks it wakes are exported functions.
REQUIRED_IMPORTS = {("env", "vibe3d_web_pick_open"), ("env", "vibe3d_web_offer_download")}
REQUIRED_EXPORTS = {"vibe3d_web_pick_done", "vibe3d_web_pick_failed"}

def section(payload, sid):
    def enc(n):
        out = bytearray()
        while True:
            b=n&127; n >>= 7; out.append(b | (128 if n else 0))
            if not n: return bytes(out)
    return bytes([sid]) + enc(len(payload)) + payload

def positive_control():
    # type ()->(), then one function import named dlopen
    return b"\0asm\x01\0\0\0" + section(b"\x01\x60\x00\x00", 1) + section(b"\x01\x01m\x06dlopen\x00\x00", 2)

control = imports(positive_control())
if not any(field in FORBIDDEN for _, field in control):
    raise SystemExit("WEB-DLOPEN inspector positive control failed")
found = imports(pathlib.Path(sys.argv[1]).read_bytes())
bad = sorted(f"{m}.{f}" for m, f in found if f in FORBIDDEN)
print(f"WEB-IMPORTS count={len(found)} forbidden={len(bad)} positive-control=dlopen")
if bad:
    print("forbidden dynamic-loader imports: " + ", ".join(bad), file=sys.stderr)
    raise SystemExit(1)
blob = pathlib.Path(sys.argv[1]).read_bytes()
missing_imports = sorted(f"{m}.{f}" for m, f in REQUIRED_IMPORTS - set(found))
function_exports = {f for f, kind in exports(blob) if kind == 0}
missing_exports = sorted(REQUIRED_EXPORTS - function_exports)
print(f"WEB-FILE-BRIDGE imports={len(REQUIRED_IMPORTS) - len(missing_imports)}/{len(REQUIRED_IMPORTS)}"
      f" exports={len(REQUIRED_EXPORTS) - len(missing_exports)}/{len(REQUIRED_EXPORTS)}")
if missing_imports or missing_exports:
    print("file bridge missing: " + ", ".join(missing_imports + missing_exports), file=sys.stderr)
    raise SystemExit(1)
