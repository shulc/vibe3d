// One operation per tool: a tool's preview and scripted apply reach the
// geometry kernel through ONE function, so they cannot drift apart (task 9431; wave plan PV1, the first row; task 9433, PV3a, the edit
// family's eight; task 9434, PV3b, the bevel / extend / array five).
//
// The kernel set of a row comes from a RULE over the kernel module's members,
// not from a list of today's call sites. Counting is on WHOLE IDENTIFIERS over
// code with comments, strings and unittest bodies blanked, attributed to the
// enclosing declaration (`tests.unit.census_symbols.enclosingSymbols`, which
// attributes a line to the declaration open at its START). The spellings that
// reach a member past that view — `.tupleof`, `__traits(getMember`, string
// `mixin(` — are counted in the RAW text.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score mutations one at
// a time.
module tests.unit.tool_single_operation_census_test;

import std.algorithm : startsWith;
import std.array : split;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath, dirName;

static import mesh_ops.cut;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    countIdent, countOccurrences, enclosingSymbols;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// `ident` occurrences keyed "<enclosing path>|<ident>".
private size_t[string] identOwners(string code, const string[] idents) {
    const syms = enclosingSymbols(code);
    size_t[string] hits;
    foreach (li, line; code.split('\n'))
        foreach (id; idents) {
            const n = countIdent(line, id);
            if (!n) continue;
            const owner = li < syms.length && syms[li].length ? syms[li] : "(module scope)";
            hits[owner ~ "|" ~ id] = hits.get(owner ~ "|" ~ id, 0) + n;
        }
    return hits;
}

/// The rule for the slice row: every `mesh_ops.cut` member named `cutByPlane…`.
private string[] planeCutKernels() {
    string[] names;
    static foreach (m; __traits(allMembers, mesh_ops.cut))
        static if (m.length >= 10 && m[0 .. 10] == "cutByPlane") names ~= m;
    return names;
}

private string codeOf(string rel, out string raw) {
    immutable path = buildPath(repoRoot, rel);
    assert(exists(path), "census target " ~ path ~ " does not exist — the "
        ~ "census would scan nothing and stay green; move this entry with the file");
    raw = readText(path);
    return blankUnittestBodies(blankNonCode(raw));
}

unittest // Slice: every plane-cut kernel call lives in `sliceCut` (and its split-gap arm)
{
    // FLOOR: the needle set. Measured 2026-10-05 (task 9431): 5 names —
    // cutByPlane, cutByPlaneRestricted, cutByPlaneClipped, cutByPlaneEx,
    // cutByPlaneSplitGap.
    const kernels = planeCutKernels();
    assert(kernels.length == 5, format("the cutByPlane rule now selects %s names "
        ~ "(%s); measured 5 — re-measure and pin, never widen blindly",
        kernels.length, kernels));

    // Positive control of the counter and the attribution.
    assert(countIdent("e.cutByPlane(p); auto d = &cutByPlane; cutByPlaneEx(x);",
        "cutByPlane") == 2, "identifier counter lost a spelling");
    auto ctl = identOwners("size_t f() {\n    g.cutByPlaneEx(1);\n}\n", ["cutByPlaneEx"]);
    assert(ctl == ["f|cutByPlaneEx": size_t(1)], format("attribution control: %s", ctl));

    string raw;
    const code = codeOf("source/tools/slice/slice_tool.d", raw);
    assert(code.length > 40_000, format("slice_tool.d code view is %s bytes; the "
        ~ "census would read a stub", code.length));

    // NEEDLE + PIN: each kernel's sites, by enclosing function. Anything outside
    // `sliceCut` (its nested `cutAt` included) and `sliceSplitGap` — the
    // two-cut arm with its partial-cut fallback, called only from `sliceCut`
    // (pinned below) — is a second operation. State: RED on the pre-9431 tree
    // (`sliceFromBaseline.cutAt` and `SliceTool.applyHeadless.cutAt` held the
    // non-split kernels, `SliceTool.applyHeadless` its own cutByPlaneEx).
    size_t[string] want = [
        "sliceCut.cutAt|cutByPlane": 1,
        "sliceCut.cutAt|cutByPlaneRestricted": 1,
        "sliceCut.cutAt|cutByPlaneClipped": 1,
        "sliceCut|cutByPlaneEx": 1,
        "sliceSplitGap|cutByPlaneSplitGap": 1,
        "sliceSplitGap|cutByPlaneEx": 1,
    ];
    auto got = identOwners(code, kernels);
    assert(got == want, format("slice_tool.d calls a plane-cut kernel outside the "
        ~ "one operation `sliceCut`:\n  found    %s\n  expected %s", got, want));

    // STRUCTURAL: the bypasses that reach a member past the blanked view.
    assert(countOccurrences(raw, ".tupleof") == 0 &&
        countOccurrences(raw, "getMember") == 0 &&
        countOccurrences(raw, "mixin(") == 0 &&
        countOccurrences(raw, "mixin (") == 0,
        "slice_tool.d gained a .tupleof / getMember / string-mixin spelling the "
        ~ "identifier census cannot see");

    // PIN: the split-gap arm has one caller, and the operation has exactly the
    // two producers — the baseline re-cut (live preview, commit) and the
    // scripted apply. State: RED on the pre-9431 tree.
    auto callers = identOwners(code, ["sliceSplitGap", "sliceCut"]);
    size_t[string] wantCallers = [
        "(module scope)|sliceSplitGap": 1,    // its definition
        "sliceCut|sliceSplitGap": 1,
        "(module scope)|sliceCut": 1,         // its definition
        "sliceFromBaseline|sliceCut": 1,
        "SliceTool.applyHeadless|sliceCut": 1,
    ];
    assert(callers == wantCallers, format("slice_tool.d operation callers moved:"
        ~ "\n  found    %s\n  expected %s", callers, wantCallers));
}

/// One per-tool row: the tool file, its class, its kernel, the producers that
/// name `operation` (each once), and whether the kernel module is imported by
/// name (a module-scope occurrence).
private struct OperationRow { string file, cls, kernel; string[] producers; bool imported; }

private enum string[] kTwoProducers = ["rebuildPreview", "applyHeadless"];

/// The census of one family; returns the files read.
private size_t checkRows(const OperationRow[] rows) {
    size_t files;
    foreach (r; rows) {
        string raw;
        const code = codeOf(r.file, raw);
        assert(code.length > 10_000, format("%s code view is %s bytes; the census "
            ~ "would read a stub", r.file, code.length));
        ++files;

        // NEEDLE + PIN: the kernel's sites by enclosing function — `operation`
        // only.
        size_t[string] want = [r.cls ~ ".operation|" ~ r.kernel: 1];
        if (r.imported) want["(module scope)|" ~ r.kernel] = 1;
        auto got = identOwners(code, [r.kernel]);
        assert(got == want, format("%s calls `%s` outside its one operation:"
            ~ "\n  found    %s\n  expected %s", r.file, r.kernel, got, want));

        // STRUCTURAL: the spellings that reach a member past the blanked view.
        assert(countOccurrences(raw, ".tupleof") == 0 &&
            countOccurrences(raw, "getMember") == 0 &&
            countOccurrences(raw, "mixin(") == 0 &&
            countOccurrences(raw, "mixin (") == 0,
            r.file ~ " gained a .tupleof / getMember / string-mixin spelling");

        // PIN: the producers.
        size_t[string] wantCallers = [r.cls ~ "|operation": 1];   // its definition
        foreach (p; r.producers) wantCallers[r.cls ~ "." ~ p ~ "|operation"] = 1;
        auto callers = identOwners(code, ["operation"]);
        assert(callers == wantCallers, format("%s: `operation` callers moved:"
            ~ "\n  found    %s\n  expected %s", r.file, callers, wantCallers));
    }
    return files;
}

unittest // Edit family: each tool's kernel lives in its one `operation`, called by its two producers
{
    // The preview rebuild and the scripted apply.
    alias R = OperationRow;
    const R[] rows = [
        R("source/tools/edit/edge_extrude.d", "EdgeExtrudeTool", "extrudeEdgesByMask",
            kTwoProducers),
        R("source/tools/edit/poly_extrude.d", "PolyExtrudeTool", "extrudeFacesByMask",
            kTwoProducers),
        R("source/tools/edit/vertex_bevel_tool.d", "VertexBevelTool",
            "bevelVerticesByMask", kTwoProducers, true),
        R("source/tools/edit/vertex_extrude_tool.d", "VertexExtrudeTool",
            "extrudeVerticesByMask", kTwoProducers),
        R("source/tools/edit/poly_inset_tool.d", "PolyInsetTool", "insetFacesByMask",
            kTwoProducers),
        R("source/tools/edit/vert_merge_tool.d", "VertexMergeTool", "weldVerticesByMask",
            kTwoProducers),
        R("source/tools/edit/reduce.d", "ReductionTool", "reduceToTarget",
            kTwoProducers, true),
        R("source/tools/deform/smooth_shift_tool.d", "SmoothShiftTool",
            "smoothShiftFacesByMask", kTwoProducers),
    ];
    // FLOOR (plan PV3a: eight files; PV1's slice row is the block above).
    assert(rows.length == 8, format("%s edit-family rows, expected 8", rows.length));
    assert(checkRows(rows) == 8);
}

unittest // Bevel, extend and array family: each tool's kernel lives in its one `operation`
{
    alias R = OperationRow;
    const R[] rows = [
        R("source/tools/edit/edge_bevel.d", "EdgeBevelTool", "bevelEdgesByMask",
            kTwoProducers, true),
        // The preview reaches it through `previewOperation` (built only once a
        // press applied the operation).
        R("source/tools/edit/poly_bevel.d", "PolyBevelTool", "bevelFacesByMask",
            ["previewOperation", "applyHeadless"]),
        // The caller owns the batch: the preview kernel, the recording commit
        // carrier and the scripted apply.
        R("source/tools/edit/edge_extend.d", "EdgeExtendTool", "extendEdgesByMask",
            ["runPreviewKernel", "fillCommitCarrier", "applyHeadless"]),
        R("source/tools/alignment/array_tool.d", "ArrayTool", "arrayFacesGrid",
            kTwoProducers),
        R("source/tools/alignment/radial_array_tool.d", "RadialArrayTool",
            "radialArrayFaces", kTwoProducers),
    ];
    // FLOOR (plan PV3b: five files; with the slice row and the edit family's
    // eight the census covers 14).
    assert(rows.length == 5, format("%s family rows, expected 5", rows.length));
    assert(checkRows(rows) == 5);
}
