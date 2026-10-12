// The browser seam key is ONE identifier, and this census exists because it was TWO for six
// slices of wave 15 and nothing could see it.
//
// What happened, measured 2026-09-21. Forty-eight sites carried `version (web)` and five
// carried `version (WebAssembly)`. Those are not equivalent: the compiler predefines the
// second on any wasm triple and NOTHING defines the first unless a build configuration does.
// So a wasm build without that configuration was HALF-gated -- two seams fired, two took the
// native arm and failed on an error that looks unrelated to gating. Two slices' own wasm
// controls were green only because their harness passed `-d-version=web` by hand, which
// witnesses the FLAG and not the BUILD.
//
// The direction of the fix was chosen by measurement and is the opposite of the intuition
// that a compiler-predefined key is safer: predefined is exactly what produces the partial
// state, because it fires regardless of configuration. With ONE key, no configuration gates
// nothing and the build fails uniformly -- and a uniform failure can be diagnosed while a
// partial one cannot. Derivation: doc/measurements/w15/phase0_findings.md 14.25 and 14.26.
//
// This census is a POPULATION check with a floor, not a spelling check: a floor first, so it
// cannot pass over an empty scan, then the exclusive count. One target guard is deliberately
// different: `version (WebAssembly)` immediately followed by a failing `static assert` rejects
// a wasm build that missed the configured browser key. It grants no capability and is counted
// exactly. Wave8 also pins eight JS-only target refinements inside configured `web`
// arms; these cannot select the browser backend by themselves.
module tests.unit.web_seam_key_census_test;

import std.algorithm : canFind, filter, map, sum;
import std.array     : array;
import std.file      : dirEntries, SpanMode, readText, exists;
import std.path      : buildPath;
import std.regex     : matchAll, regex;
import std.string    : indexOf, count;
import std.path      : relativePath, buildNormalizedPath;
import std.string    : replace;

private string repoRoot()
{
    string dir = ".";
    foreach (_; 0 .. 6)
    {
        if (exists(buildPath(dir, "dub.json")) && exists(buildPath(dir, "source")))
            return dir;
        dir = buildPath(dir, "..");
    }
    assert(false, "6910 web seam key census: no repository root above the test's cwd");
}

// Wave8: `web` selects the browser backend; WebAssembly refines only the eight
// accepted JavaScript bridge surfaces. Each exact fragment has one guard;
// the tree-wide total still rejects any unrostered target capability gate.
private size_t bridgeTargetSites(string path, string text)
{
    string outer, tail;
    string[] fragments;
    switch (path) {
    case "source/app.d":
        fragments = [
            "version (web) {\n    import web_gl_loader : loadWebOpenGL;\n    version (WebAssembly)\n        private extern(C) void vibe3d_web_set_dirty(int) nothrow @nogc;",
            "version (web) if (dirty != webLastDirty) {\n                version (WebAssembly) vibe3d_web_set_dirty(dirty ? 1 : 0);\n                webLastDirty = dirty;",
        ];
        break;
    case "packages/interchange/source/io/assimp_runtime.d":
        outer = "version (web)\n{";
        tail = "}\nelse\n{\n\nimport std.file";
        fragments = [
            "version (WebAssembly)\n        extern(C) int vibe3d_web_assimp_available() nothrow @nogc;",
            "bool isAssimpAvailable() nothrow @nogc\n    {\n        version (WebAssembly) { return vibe3d_web_assimp_available() != 0; }",
        ];
        break;
    case "packages/interchange/source/io/scene_export.d":
        outer = "version (web)\n{";
        tail = "}\nelse\n{\n\nimport std.string";
        fragments = [
            "version (WebAssembly)\n    extern(C) int vibe3d_web_assimp_export(const(ubyte)* data, uint length,\n                                           const(char)* formatId, const(char)* path);",
            "bool exportDocumentViaAssimp(ref const Document document, string path,\n                                 string formatId)\n    {\n        version (WebAssembly) {\n        auto wire = encodeAssimpWire(document);",
        ];
        break;
    case "packages/interchange/source/io/scene_import.d":
        outer = "version (web)\n{";
        tail = "}\nelse\n{\n\nimport std.string";
        fragments = [
            "version (WebAssembly) {\n    extern(C) int vibe3d_web_assimp_import(const(char)* path, void** data, uint* length);\n    extern(C) void vibe3d_web_assimp_free(void* data);\n    }",
            "bool importViaAssimp(string path, ref ImportedScene scene)\n    {\n        version (WebAssembly) {\n        void* data;",
        ];
        break;
    default:
        return 0;
    }
    if (outer.length) {
        assert(text.count(outer) == 1 && text.count(tail) == 1,
            "6910 bridge browser configuration envelope changed: " ~ path);
        assert(text.indexOf(outer) < text.indexOf(tail),
            "6910 bridge browser envelope must precede the native arm: " ~ path);
    }
    foreach (fragment; fragments) {
        assert(text.count(fragment) == 1,
            "6910 bridge target fragment must occur exactly once: " ~ path ~ " " ~ fragment);
        if (outer.length)
            assert(text.indexOf(fragment) > text.indexOf(outer)
                && text.indexOf(fragment) < text.indexOf(tail),
                "6910 bridge target refinement escaped its browser envelope: " ~ path);
    }
    return fragments.length;
}

unittest // the browser seam key is exactly one identifier, and the alternative is absent
{
    const root = repoRoot();
    auto webRe  = regex(`version\s*\(\s*web\s*\)`);
    auto wasmRe = regex(`version\s*\(\s*WebAssembly\s*\)`);
    auto wasmGuardRe = regex(
        `version\s*\(\s*WebAssembly\s*\)\s*static\s+assert\s*\(`);

    size_t files, webSites, wasmSites, wasmGuardSites, bridgeSites;
    string[] offenders;
    foreach (scanSourceRoot; [buildPath(root, "source"), buildPath(root, "packages/common/source"), buildPath(root, "packages/camera-model/source"), buildPath(root, "packages/document-channels/source"), buildPath(root, "packages/image-codec/source"), buildPath(root, "packages/document-io/source"), buildPath(root, "packages/document-model/source"), buildPath(root, "packages/param-schema/source"), buildPath(root, "packages/pipe-runtime/source"), buildPath(root, "packages/mesh-ops/source"), buildPath(root, "packages/interchange/source"), buildPath(root, "packages/interaction-query/source"), buildPath(root, "packages/pipe-evaluation/source"), buildPath(root, "packages/tool-state/source"), buildPath(root, "packages/transform-ops/source"), buildPath(root, "packages/creation-ops/source"), buildPath(root, "packages/alignment-ops/source"), buildPath(root, "packages/input-events/source"), buildPath(root, "packages/display-policy/source"), buildPath(root, "packages/viewport-gpu/source"), buildPath(root, "packages/subpatch-preview/source"), buildPath(root, "packages/edit-contracts/source"), buildPath(root, "packages/mesh-change/source"), buildPath(root, "packages/mesh-contracts/source"), buildPath(root, "packages/mesh-edit-log/source"), buildPath(root, "packages/mesh-edit-replay/source"), buildPath(root, "packages/mesh-snapshot/source"), buildPath(root, "packages/mesh-topology/source"), buildPath(root, "packages/mesh/source"), buildPath(root, "packages/profiling/source"), buildPath(root, "packages/spatial/source"), buildPath(root, "util/log/source"), buildPath(root, "util/math/source"), buildPath(root, "util/parallel/source"), buildPath(root, "util/plane-bytes/source"), buildPath(root, "util/screen-buckets/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
    {
        ++files;
        const text = readText(entry.name);
        const w = text.matchAll(webRe).array.length;
        const a = text.matchAll(wasmRe).array.length;
        const g = text.matchAll(wasmGuardRe).array.length;
        webSites += w;
        wasmSites += a;
        wasmGuardSites += g;
        const b = bridgeTargetSites(buildNormalizedPath(relativePath(entry.name, root)).replace("\\", "/"), text);
        bridgeSites += b;
        if (a != g + b) offenders ~= entry.name;
    }
    foreach (sourceCarrier; [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
    ]) {
        const sourceCarrierPath = buildPath(root, sourceCarrier);

        const text = readText(sourceCarrierPath);
        const w = text.matchAll(webRe).array.length;
        const a = text.matchAll(wasmRe).array.length;
        const g = text.matchAll(wasmGuardRe).array.length;
        webSites += w;
        wasmSites += a;
        wasmGuardSites += g;
        const b = bridgeTargetSites(buildNormalizedPath(relativePath(sourceCarrierPath, root)).replace("\\", "/"), text);
        bridgeSites += b;
        if (a != g + b) offenders ~= sourceCarrierPath;

    }

    // FLOOR FIRST. Without it "no WebAssembly sites" is also true of a scan that read nothing,
    // which is the vacuous-predicate shape this project pays for most.
    assert(files >= 500,
        "6910 web seam key census: scanned only a handful of source files; the scan is the "
      ~ "subject here, and a small population makes every count below meaningless");
    assert(webSites >= 50,
        "6910 web seam key census: the browser key has nearly vanished from source/; either "
      ~ "the seams were removed or this scan is looking in the wrong place");

    // THE PROPERTY. `WebAssembly` may reject a target that missed `web`, but may not grant a
    // standalone capability. The eight exact JS refinements above require `web`.
    // Pin both halves so a vanished guard and a second capability key are red.
    assert(wasmGuardSites == 1,
        "6910 web seam key census: expected exactly one `version (WebAssembly)` target guard "
      ~ "immediately followed by `static assert`, found " ~ wasmGuardSites.to!string);
    assert(bridgeSites == 8, "6910 bridge target roster must contain all eight accepted surfaces");
    assert(wasmSites == wasmGuardSites + bridgeSites,
        "6910 web seam key census: source/ carries `version (WebAssembly)` as a capability "
      ~ "gate outside the rejecting guard and the eight nested JavaScript refinements. The compiler predefines it on any wasm "
      ~ "triple while `web` comes only from a build configuration, so mixing the capability "
      ~ "keys makes a build without that configuration HALF-gated. Offenders: "
      ~ offenders.idup.to!string);
}

private import std.conv : to;
