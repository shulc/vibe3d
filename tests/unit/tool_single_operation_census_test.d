// One operation per tool: a tool's preview, prepared panel edit and scripted
// apply reach the geometry kernel through ONE function, so they cannot drift
// apart (task 9431; wave plan PV1, the first row — PV3a/PV3b add theirs).
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
    countOccurrences, enclosingSymbols, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Whole-identifier occurrences of `ident` in `code`.
private size_t countIdent(string code, string ident) {
    size_t n = 0, i = 0;
    while (i + ident.length <= code.length) {
        if (code[i .. i + ident.length] == ident &&
            (i == 0 || !isIdentChar(code[i - 1])) &&
            (i + ident.length == code.length ||
             !isIdentChar(code[i + ident.length]))) {
            ++n; i += ident.length;
        } else ++i;
    }
    return n;
}

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
    // two producers — the baseline re-cut (live preview, commit, prepared panel
    // edit) and the scripted apply. State: RED on the pre-9431 tree.
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
