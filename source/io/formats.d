module io.formats;

// Asset-I/O Phase 6 — format registry + document-path memory.
//
// A small, data-driven table the File menu and the load/save dialogs
// consult. Every supported file extension maps to a human label, a
// `kind` (native | lwoNative | assimp), capability flags, and — for
// assimp exports — the assimp exporter id. Adding a format later is a
// one-row edit here plus a menu entry; no dialog code changes.
//
// All of `source/io/*` is base modeling code (no render/material
// imports). This module is pure D + nfde and links into the default
// modeling build.

import std.path : extension;
import std.uni  : toLower;

/// How a format is read/written under the hood. The load/save commands
/// already dispatch by extension; `kind` is the registry's mirror of
/// that decision so the menu can reason about it (gating, labels).
enum FormatKind {
    native,     // .v3d — vibe3d's own document (source of truth, pure D)
    lwoNative,  // .lwo — our own clean-room LWO reader/writer (pure D)
    assimp,     // .obj/.gltf/.glb/.fbx — via the dynamic assimp bridge
}

/// One row of the format registry.
struct FormatInfo {
    string     ext;            // lowercase, dot-prefixed (".v3d", ".obj", ...)
    string     label;          // human label ("Wavefront OBJ")
    FormatKind kind;
    bool       canImport;      // surfaced under Import ▸ / Open
    bool       canExport;      // surfaced under Export ▸ / Save As
    string     assimpExportId; // assimp exporter id ("obj"/"gltf2"/"glb2"); "" otherwise
}

/// The registry. Order is the order the formats appear in dialogs and
/// menus. FBX now exports too (binary "fbx"); see io.scene_export for the
/// unit-scale handling that keeps our export->import round-trip in meters.
immutable FormatInfo[] formats = [
    FormatInfo(".v3d",  "vibe3d Document",   FormatKind.native,    true,  true,  ""),
    FormatInfo(".lwo",  "LightWave Object",  FormatKind.lwoNative, true,  true,  ""),
    FormatInfo(".obj",  "Wavefront OBJ",     FormatKind.assimp,    true,  true,  "obj"),
    FormatInfo(".gltf", "glTF",              FormatKind.assimp,    true,  true,  "gltf2"),
    FormatInfo(".glb",  "glTF Binary",       FormatKind.assimp,    true,  true,  "glb2"),
    FormatInfo(".fbx",  "FBX",               FormatKind.assimp,    true,  true,  "fbx"),
];

/// Normalize an arbitrary path/extension to a lowercase dot-prefixed
/// extension key (".OBJ" -> ".obj", "model.gltf" -> ".gltf").
string normExt(string pathOrExt) {
    if (pathOrExt.length == 0) return "";
    // Accept either a full path or a bare extension (with/without dot).
    string e = pathOrExt;
    auto fromPath = extension(pathOrExt);
    if (fromPath.length > 0) e = fromPath;
    else if (e[0] != '.')    e = "." ~ e;
    return e.toLower;
}

/// Look up a format row by extension (path or bare ext accepted).
/// Returns null when unknown.
const(FormatInfo)* formatFor(string pathOrExt) {
    const e = normExt(pathOrExt);
    foreach (ref f; formats)
        if (f.ext == e) return &f;
    return null;
}

/// True when reading/writing this extension routes through assimp
/// (and therefore requires the dynamic libassimp to be loaded).
bool formatNeedsAssimp(string pathOrExt) {
    auto f = formatFor(pathOrExt);
    return f !is null && f.kind == FormatKind.assimp;
}

// ---------------------------------------------------------------------------
// nfde FilterItem builders
//
// nfde takes ASCII C strings on POSIX and UTF-16 on Windows. The two
// existing file commands already branch on `version (Windows)` for the
// wide-string form; these builders centralize the POSIX (narrow) path
// and expose the raw (name, spec) pairs so the Windows caller can wrap
// them the same way it does today. nfde's filter `spec` is a
// comma-separated, dot-LESS extension list ("obj" or "obj,gltf,glb").
// ---------------------------------------------------------------------------

/// A (display name, nfde spec) pair — the data behind one FilterItem,
/// kept format-agnostic so callers build the platform-correct FilterItem.
struct FilterSpec {
    string name;  // "Wavefront OBJ"
    string spec;  // "obj"  (dot-less, comma-separated for multi)
}

private string bareExt(string ext) {
    // ".obj" -> "obj"
    return ext.length > 0 && ext[0] == '.' ? ext[1 .. $] : ext;
}

/// Open/Import filter list. `assimpAvailable == false` drops the assimp
/// rows so the dialog never offers a format that can't be read.
/// `withAllSupported` prepends an "All supported" aggregate row.
FilterSpec[] importFilterSpecs(bool assimpAvailable, bool withAllSupported) {
    import std.array : appender, join;
    auto specs = appender!(FilterSpec[]);
    auto allExts = appender!(string[]);
    foreach (ref f; formats) {
        if (!f.canImport) continue;
        if (f.kind == FormatKind.assimp && !assimpAvailable) continue;
        specs.put(FilterSpec(f.label, bareExt(f.ext)));
        allExts.put(bareExt(f.ext));
    }
    FilterSpec[] result;
    if (withAllSupported && allExts.data.length > 1)
        result ~= FilterSpec("All supported", allExts.data.join(","));
    result ~= specs.data;
    return result;
}

/// Save As / Export filter list (export-capable rows only).
FilterSpec[] exportFilterSpecs(bool assimpAvailable) {
    import std.array : appender;
    auto specs = appender!(FilterSpec[]);
    foreach (ref f; formats) {
        if (!f.canExport) continue;
        if (f.kind == FormatKind.assimp && !assimpAvailable) continue;
        specs.put(FilterSpec(f.label, bareExt(f.ext)));
    }
    return specs.data;
}

/// Single-format filter (the Import ▸ X / Export ▸ X menu items each open
/// a dialog restricted to one format). Returns a one-element list (empty
/// for an unknown ext).
FilterSpec[] singleFilterSpecs(string pathOrExt) {
    auto f = formatFor(pathOrExt);
    if (f is null) return null;
    return [FilterSpec(f.label, bareExt(f.ext))];
}
