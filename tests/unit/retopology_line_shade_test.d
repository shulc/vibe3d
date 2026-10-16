// The retopology line shade (`retopology_line_shade.lineShade`) and the one
// light rig it shares with the lit program (`light_rig`), task 9130.
//
// Numbers: the rig's constants against the captured values (cell 0);
// `lineShade` against an independent double-precision copy of the EYE-SPACE
// light function at the item's local +Z (cells 1-3b), including the
// view-relative law — a camera turn with the item fixed moves the shade (2c)
// — and the product order normalMatrix(view·model) (2d).
// Source text: the rig is uploaded at ONE site, `LitShader.useProgram`; no
// other function of a lit-program file reads a rig constant or spells a rig
// location other than its declaration and lookup (cells 4-5; the rig
// locations are also `private`, cell 5a).
module tests.unit.retopology_line_shade_test;

import tests.unit.census_symbols : wave15InputsIntact, wave15InputStart;



import tests.unit.census_symbols : exists = wave15Exists;

import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.math   : abs, cos, sin, sqrt, PI;
import std.path   : buildPath, dirName, relativePath;
import std.regex  : ctRegex, matchAll, matchFirst, replaceAll;
import std.string : indexOf;

import vibe3d.viewport.display_policy.light_rig : kKeyLightEye, kFillLightEye, kKeyIntensity, kFillIntensity,
    kLightAmbient, specPowerForRoughness;
import vibe3d.util.math.math : Vec3;
import vibe3d.viewport.display_policy.retopology_line_shade : lineShade;
import tests.unit.census_symbols : balancedSpan, blankNonCode,
    blankUnittestBodies, countOccurrences, lineOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---- the one-upload-site census ---------------------------------------------

// The Gooch style's light and tones (task 9150) ride the same upload site.
private immutable string[] kRigIds =
    ["kKeyLightEye", "kFillLightEye", "kKeyIntensity", "kFillIntensity", "kLightAmbient",
     "kGoochLightEye", "kGoochCool", "kGoochWarm", "kGoochCoolKd", "kGoochWarmKd"];
private immutable string[] kRigLocs =
    ["locKeyDir", "locFillDir", "locKeyI", "locFillI", "locAmbient",
     "locGoochDir", "locGoochCool", "locGoochWarm", "locGoochCoolKd", "locGoochWarmKd"];

private enum identRe  = ctRegex!(`\b(kKeyLightEye|kFillLightEye|kKeyIntensity|kFillIntensity|kLightAmbient|kGoochLightEye|kGoochCool|kGoochWarm|kGoochCoolKd|kGoochWarmKd|locKeyDir|locFillDir|locKeyI|locFillI|locAmbient|locGoochDir|locGoochCool|locGoochWarm|locGoochCoolKd|locGoochWarmKd)\b`);
private enum importRe = ctRegex!(`\bimport\b[^;]*;`);
/// A location's declaration (`GLint locX`) and its one `glGetUniformLocation`
/// assignment: the only spellings of a location allowed outside the span.
private enum locDeclRe   = ctRegex!(`\bGLint\s+$`);
private enum locAssignRe = ctRegex!(`^\s*=\s*glGetUniformLocation\s*\(`);
private enum addrOfRe    = ctRegex!(`&\s*$`);
/// Every rig location and uniform NAME, for the raw-text fence (5a).
private enum rigNameRe = ctRegex!(`\b(locKeyDir|locFillDir|locKeyI|locFillI|locAmbient|locGoochDir|locGoochCool|locGoochWarm|locGoochCoolKd|locGoochWarmKd|u_keyDir|u_fillDir|u_keyI|u_fillI|u_ambient|u_goochDir|u_goochCool|u_goochWarm|u_goochCoolKd|u_goochWarmKd)\b`);

/// Blank import declarations (an import NAMES a constant, it does not read it),
/// keeping offsets.
private string blankImports(string code) {
    char[] o = code.dup;
    foreach (m; matchAll(code, importRe))
        foreach (i; m.pre.length .. m.pre.length + m.hit.length)
            if (o[i] != '\n') o[i] = ' ';
    return cast(string) o;
}

/// Offenders in `code`: every spelling of a rig identifier outside
/// [allowLo, allowHi) — a constant read, a location in an upload, `&locX`, an
/// alias — EXCEPT a location's declaration and its `glGetUniformLocation`
/// assignment, which are counted into `allowed` (the complement's floor).
private string[] offenders(string file, string code, size_t allowLo, size_t allowHi,
                           ref size_t allowed) {
    string[] o;
    bool inside(size_t p) { return p >= allowLo && p < allowHi; }
    foreach (m; matchAll(code, identRe)) {
        immutable p = m.pre.length;
        if (inside(p)) continue;
        immutable string id = m.hit;
        if (id.length > 3 && id[0 .. 3] == "loc") {
            immutable before = code[(p >= 64 ? p - 64 : 0) .. p];
            immutable after  = code[p + id.length .. $];
            immutable head   = after[0 .. (after.length < 64 ? after.length : 64)];
            if (!matchFirst(before, locDeclRe).empty || !matchFirst(head, locAssignRe).empty) {
                ++allowed;
                continue;
            }
            o ~= format("%s:%d %s %s", file, lineOf(code, p),
                matchFirst(before, addrOfRe).empty ? "names" : "takes the address of", id);
            continue;
        }
        o ~= format("%s:%d reads %s", file, lineOf(code, p), id);
    }
    return o;
}

/// [lo, hi) of `LitShader.useProgram`'s body in shader.d's blanked code.
private size_t[2] useProgramSpan(string code) {
    immutable ptrdiff_t cls = code.indexOf("class LitShader");
    assert(cls >= 0, "5: class LitShader not found in shader.d");
    immutable ptrdiff_t at = code[cls .. $].indexOf("void useProgram(");
    assert(at >= 0, "5: LitShader.useProgram not found");
    immutable ptrdiff_t open = code.indexOf('{', cls + at);
    immutable b = balancedSpan(code, cast(size_t) open, '{', '}');
    assert(b.length > 2, "5: LitShader.useProgram has no braced body");
    return [cast(size_t) open, cast(size_t) open + b.length];
}

unittest { // 4. positive control: the census sees each pre-slice upload shape
    // A hand upload in a function that is NOT useProgram, in the three
    // spellings a pre-slice site used or a bypass would use.
    enum preSlice = q{
        void drawLitPreview() {
            glUniform3f(litShader.locKeyDir, kKeyLightEye.x, kKeyLightEye.y, kKeyLightEye.z);
            glUniform1f(litShader.locAmbient,
                        kLightAmbient);
            float a = kFillIntensity;
            GLint* bypass = &locFillI;
            private GLint locKeyI;
            locKeyI = glGetUniformLocation(program, "u_keyI");
        }
        void useProgram() { glUniform1f(locKeyI, kKeyIntensity); }
    };
    // Allowed span = the second function's body.
    immutable lo = preSlice.indexOf("void useProgram()");
    size_t allowed;
    const got = offenders("ctl", preSlice, lo, preSlice.length, allowed);
    // 3 kKeyLightEye + kLightAmbient + kFillIntensity reads, 2 locations in
    // uploads, 1 `&locFillI` = 8; the declaration + assignment are allowed (2).
    assert(got.length == 8, format("4 positive control: the census saw %s "
        ~ "of the 8 offences in the pre-slice text; its needles are blind: %s",
        got.length, got));
    assert(got[$ - 1].indexOf("takes the address of locFillI") >= 0,
        format("4 positive control: `&locFillI` is not reported as an address-of: %s", got));
    assert(allowed == 2, format("4 positive control: %s of the 2 allowed location "
        ~ "spellings (declaration, glGetUniformLocation) were allowed", allowed));
    assert(blankImports("import light_rig : kKeyLightEye;").indexOf("kKeyLightEye") < 0,
        "4 positive control: an import declaration must not count as a read");
}

unittest { // 5. the rig is read and uploaded ONLY inside LitShader.useProgram
    auto wave15Inputs = wave15InputStart();
    import std.array : replace;
    immutable src = buildPath(repoRoot, "source");
    // Domain from the RULE: every source file naming LitShader, plus shader.d
    // and the pen preview; light_rig.d declares the constants and is excluded.
    string[] files;
    foreach (scanSourceRoot; [src, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        immutable rel = relativePath(de.name, src).replace("\\", "/");
        if (rel == "../packages/display-policy/source/light_rig.d") continue;
        immutable raw = readText(de.name);
        if (rel == "../packages/viewport-gpu/source/shader.d" || rel == "tools/create/pen.d"
            || countOccurrences(raw, "LitShader") > 0)
            files ~= rel;
    }
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        immutable rel = relativePath(sourceCarrierPath, src).replace("\\", "/");
        if (rel == "../packages/display-policy/source/light_rig.d") continue;
        immutable raw = readText(sourceCarrierPath);
        if (rel == "../packages/viewport-gpu/source/shader.d" || rel == "tools/create/pen.d"
            || countOccurrences(raw, "LitShader") > 0)
            files ~= rel;

    }
    // Floor: measured 2026-10-02 —
    //   grep -rl LitShader source --include=*.d | wc -l -> 81 (shader.d and pen.d among them);
    //   2026-10-05 (wave-2 PRM1 folds eleven owner modules): 73, light_rig.d excluded -> 72;
    //   after PRM2 folds five more: 69 -> 68; task 9525 deletes drag_weld.d: 67.
    assert(files.length >= 67, format("5 floor: the lit-program domain is %d files, "
        ~ "floor 67 — the walk lost its domain", files.length));

    string[] bad;
    size_t[string] insideReads;
    size_t shaderAllowed, otherAllowed;
    foreach (rel; files) {
        immutable code = blankImports(blankUnittestBodies(blankNonCode(
            readText(buildPath(src, rel)))));
        size_t lo = size_t.max, hi = size_t.max;
        if (rel == "../packages/viewport-gpu/source/shader.d") {
            immutable sp = useProgramSpan(code);
            lo = sp[0]; hi = sp[1];
            foreach (m; matchAll(code[lo .. hi], identRe)) insideReads[m.hit] += 1;
        }
        bad ~= offenders(rel, code, lo, hi, rel == "../packages/viewport-gpu/source/shader.d" ? shaderAllowed : otherAllowed);
    }
    // Complement floor: outside useProgram, shader.d spells each location only
    // in its declaration and its glGetUniformLocation assignment — measured
    // 2026-10-02 (task 9150, +5 Gooch locations): grep -nE "GLint (locKeyDir|locFillDir|locKeyI|locFillI|locAmbient|locGooch[A-Za-z]+)\b|(locKeyDir|locFillDir|locKeyI|locFillI|locAmbient|locGooch[A-Za-z]+) *= *glGetUniformLocation"
    // source/shader.d | wc -l -> 20. Fewer = the allowance stopped matching.
    assert(shaderAllowed == 20 && otherAllowed == 0, format("5 floor: %s allowed "
        ~ "location spellings in shader.d (measured 20: 10 declarations + 10 "
        ~ "assignments), %s elsewhere (want 0)", shaderAllowed, otherAllowed));
    // Population floor: useProgram reads every rig constant and uploads every
    // rig location (each name ≥ 1 inside the allowed span).
    foreach (id; kRigIds ~ kRigLocs)
        assert((id in insideReads) !is null && insideReads[id] >= 1,
            format("5 floor: LitShader.useProgram no longer reads/uploads %s — "
                   ~ "the one upload site lost its rig (%s)", id, insideReads));
    // Stationary assert over the ALLOWED set {LitShader.useProgram}: true
    // after task 9130. A red names the re-added hand upload (drawLitPreview,
    // PenTool.draw, or any create tool's lit preview).
    assert((bad.length == 0) && wave15InputsIntact(wave15Inputs), format("5: the light rig is read or uploaded outside "
        ~ "LitShader.useProgram — a hand upload came back: %s", bad));
}

unittest { // 5a. the fence: rig locations are private, and nobody spells around it
    import vibe3d.viewport.gpu.shader : LitShader;
    // Positive control: the same probe DOES compile on a public field, so a
    // `false` below means "private", not "the probe is malformed".
    static assert(__traits(compiles, (LitShader s) { auto v = s.locModel; }),
        "5a control: the probe cannot read the public LitShader.locModel — "
        ~ "the fence below is vacuous");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locKeyDir; }),
        "5a: LitShader.locKeyDir is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locFillDir; }),
        "5a: LitShader.locFillDir is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locKeyI; }),
        "5a: LitShader.locKeyI is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locFillI; }),
        "5a: LitShader.locFillI is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locAmbient; }),
        "5a: LitShader.locAmbient is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locGoochDir; }),
        "5a: LitShader.locGoochDir is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locGoochCool; }),
        "5a: LitShader.locGoochCool is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locGoochWarm; }),
        "5a: LitShader.locGoochWarm is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locGoochCoolKd; }),
        "5a: LitShader.locGoochCoolKd is reachable outside shader.d");
    static assert(!__traits(compiles, (LitShader s) { auto v = s.locGoochWarmKd; }),
        "5a: LitShader.locGoochWarmKd is reachable outside shader.d");
    import std.array : replace;
    immutable src = buildPath(repoRoot, "source");
    size_t scanned;
    string[] named;
    foreach (scanSourceRoot; [src, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source")]
        ~ (exists(buildPath(repoRoot, "packages/selection-model/source")) ? [buildPath(repoRoot, "packages/selection-model/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/scene-query/source")) ? [buildPath(repoRoot, "packages/scene-query/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/editor-commands/source")) ? [buildPath(repoRoot, "packages/editor-commands/source")] : []))

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        immutable rel = relativePath(de.name, src).replace("\\", "/");
        if (rel == "../packages/viewport-gpu/source/shader.d") continue;
        ++scanned;
        immutable raw = readText(de.name);   // RAW: strings and comments too
        if (!matchAll(raw, rigNameRe).empty) named ~= rel;
    }
    const string[] sourceCarriersWave14_2 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_2) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_2) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        immutable rel = relativePath(sourceCarrierPath, src).replace("\\", "/");
        if (rel == "../packages/viewport-gpu/source/shader.d") continue;

        immutable raw = readText(sourceCarrierPath);   // RAW: strings and comments too
        if (!matchAll(raw, rigNameRe).empty) named ~= rel;

    }
    // Floor: find source -name '*.d' | wc -l -> 582 on 2026-10-02 (581 without shader.d);
    // 578 (577) on 2026-10-05 after wave-2 PRM1 folded eleven owner modules; 574 (573) after PRM2.
    assert(scanned >= 573, format("5a floor: scanned %d files outside shader.d, floor 573", scanned));
    // Stationary: no file outside shader.d names a rig location or uniform —
    // a `__traits(getMember, lit, "locKeyDir")` or a
    // `glGetUniformLocation(p, "u_keyDir")` would.
    assert(named.length == 0, format("5a: rig location / uniform names outside shader.d: %s", named));
}
