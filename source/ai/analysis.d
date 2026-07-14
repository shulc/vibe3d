module ai.analysis;

// AI Modeling Copilot — Phase 1 (task 0402, doc/ai_copilot_plan.md): the
// whole-mesh analysis engine. `analyzeMesh` is a proactive/global candidate
// generator emitting `Finding[]` across finding categories — analogous to
// `ai.support_loop_candidates.generateSupportLoopCandidates` (a single
// category's producer) but the multi-category umbrella over it. Pure D, no
// `version(WithAI)` anywhere in this module: it must compile and be useful
// under BOTH `--config=modeling` and `--config=modeling-noai` (ONNX-scored
// ranking of findings is a later phase, mirroring how `ai.onnx_backend`
// sits behind `ai.advisor`'s heuristic fallback today).
//
// Phase 1 wires exactly ONE category — SubdivReadiness — by mapping each
// `SupportLoopCandidate` the A0 generator already produces onto a `Finding`.
// Cleanup / Topology / Retopo are declared in `FindingCategory` (so the
// schema is stable across phases) but `analyzeMesh` does not populate them
// yet; Phase 4 adds their detectors.
//
// A `Finding` NEVER carries an executable command — `suggestedOp` is a
// neutral hint string for UI/text display only (e.g. "loop.slice"), never
// dispatched by this module or any of its callers. See the plan's hard
// constraint: "no auto-apply of primitives."

import std.algorithm : sort, min, max;
import std.array     : appender;
import std.conv      : to;
import std.json      : JSONValue;
import std.math      : isFinite;

import mesh : Mesh;
import ai.support_loop_candidates : SupportLoopCandidate,
    generateSupportLoopCandidates;

enum int findingSchemaVersion = 1;

/// Broad kind of modeling issue a `Finding` reports. Stable across phases —
/// Phase 1 only ever emits `SubdivReadiness`; the other three are declared
/// now so downstream schema consumers (JSON clients, the Phase 6 ONNX
/// feature groups) don't need a breaking enum change later.
enum FindingCategory {
    SubdivReadiness,   // sharp edges that will visibly round under Catmull-Clark
    Cleanup,           // degenerate/duplicate faces, coincident verts, orphans (Phase 4)
    Topology,          // non-manifold edges, inconsistent winding, naked boundaries (Phase 4)
    Retopo,            // tri/n-gon clusters, high-valence poles, thin faces (Phase 4)
}

/// How strongly a `Finding` is being surfaced. Purely advisory — severity
/// never gates whether a finding is emitted, only how it might be
/// presented (e.g. a later panel's color/tag).
enum FindingSeverity {
    Info,
    Suggest,
    Warn,
}

/// One analysis result. `verts`/`edges`/`faces` are the element index sets a
/// later "act-on" step would SELECT (see the plan's Phase 2) — never mutate.
/// `suggestedOp` is a neutral hint string only (e.g. "loop.slice") and is
/// NEVER executed by this module. `features` mirrors the producing
/// candidate's feature vector (see e.g.
/// `ai.support_loop_candidates.supportLoopFeatureNames`) for later ranking.
struct Finding {
    string id = "";
    FindingCategory category = FindingCategory.SubdivReadiness;
    FindingSeverity severity = FindingSeverity.Suggest;
    string message = "";
    uint[] verts;
    uint[] edges;
    uint[] faces;
    string suggestedOp = "";
    float score = 0.0f;
    float[] features;
}

/// Severity threshold (SubdivReadiness): a chain whose heuristic score is at
/// or above this is surfaced as `Warn` rather than `Suggest` — a simple,
/// deterministic split; no separate model needed for Phase 1.
enum float subdivReadinessWarnScore = 0.7f;

struct AnalyzeOptions {
    float dihedralThresholdDeg = 30.0f;
    int   maxFindingsPerCategory = 64;
}

/// Hard allocation backstop, independent of `AnalyzeOptions.maxFindingsPerCategory`
/// — a caller-supplied cap is a UI-layer hint, not a guarantee, so `analyzeMesh`
/// always additionally clamps to this ceiling regardless of what was requested.
/// When `maxFindingsPerCategory` is ever surfaced as a user-facing Param, that
/// Param must ALSO carry `.enforceBounds()` with a floor of 1 (param_bounds_plan.md
/// convention) — this constant is the kernel-side half of the two-layer clamp.
enum int MAX_FINDINGS_PER_CATEGORY = 256;

/// Analyze `mesh` and return findings across all categories, each category
/// independently score-sorted (descending) and clamped. Deterministic: the
/// same mesh always yields the same findings in the same order (the
/// underlying per-category generators are themselves deterministic — see
/// `generateSupportLoopCandidates`'s doc comment). Empty or fully-smooth
/// meshes return `[]`.
Finding[] analyzeMesh(const ref Mesh mesh, AnalyzeOptions o = AnalyzeOptions.init) {
    immutable int cap = max(1, min(o.maxFindingsPerCategory, MAX_FINDINGS_PER_CATEGORY));

    Finding[] result;
    result ~= analyzeSubdivReadiness(mesh, o.dihedralThresholdDeg, cap);
    // Cleanup / Topology / Retopo: Phase 4.
    return result;
}

private Finding[] analyzeSubdivReadiness(const ref Mesh mesh, float dihedralThresholdDeg,
                                         int cap) {
    if (mesh.vertices.length == 0 || mesh.edges.length == 0) return [];

    auto candidates = generateSupportLoopCandidates(mesh, dihedralThresholdDeg);
    if (candidates.length == 0) return [];

    Finding[] findings;
    findings.reserve(candidates.length);
    foreach (ref cand; candidates)
        findings ~= findingFromSupportLoopCandidate(cand);

    findings.sort!((a, b) => a.score > b.score);
    if (findings.length > cast(size_t)cap) findings = findings[0 .. cap];
    return findings;
}

private Finding findingFromSupportLoopCandidate(const ref SupportLoopCandidate cand) {
    Finding f;
    f.id          = cand.id;
    f.category    = FindingCategory.SubdivReadiness;
    f.severity    = cand.score >= subdivReadinessWarnScore
        ? FindingSeverity.Warn : FindingSeverity.Suggest;
    f.message     = subdivReadinessMessage(cand.edgeLoop.length);
    f.edges       = cand.edgeLoop.dup;
    f.suggestedOp = "loop.slice";
    f.score       = cand.score;
    f.features    = cand.features.dup;
    return f;
}

private string subdivReadinessMessage(size_t sharpEdgeCount) {
    immutable string plural = sharpEdgeCount == 1 ? "" : "s";
    return sharpEdgeCount.to!string ~ " sharp edge" ~ plural ~
        " will round under subdivision — add holding loops";
}

// ---------------------------------------------------------------------
// JSON encoding — mirrors `ai.interaction_log`'s hand-rolled `toJsonLine`
// style (an `appender!string` + literal `buf.put` fragments; JSONValue is
// used only for string-escaping individual fields, never for building the
// whole document, keeping this allocation-cheap for a large finding list).
// ---------------------------------------------------------------------

string findingsToJson(const(Finding)[] findings) {
    auto buf = appender!string();
    buf.put(`[`);
    foreach (i, ref f; findings) {
        if (i) buf.put(`,`);
        putFindingJson(buf, f);
    }
    buf.put(`]`);
    return buf.data;
}

private void putFindingJson(B)(ref B buf, const ref Finding f) {
    buf.put(`{"id":`);
    putJsonString(buf, f.id);
    buf.put(`,"category":`);
    putJsonString(buf, findingCategoryId(f.category));
    buf.put(`,"severity":`);
    putJsonString(buf, findingSeverityId(f.severity));
    buf.put(`,"message":`);
    putJsonString(buf, f.message);
    buf.put(`,"verts":`);
    putUintArrayJson(buf, f.verts);
    buf.put(`,"edges":`);
    putUintArrayJson(buf, f.edges);
    buf.put(`,"faces":`);
    putUintArrayJson(buf, f.faces);
    buf.put(`,"suggestedOp":`);
    putJsonString(buf, f.suggestedOp);
    buf.put(`,"score":`);
    putJsonFloat(buf, f.score);
    buf.put(`,"features":[`);
    foreach (i, v; f.features) {
        if (i) buf.put(`,`);
        putJsonFloat(buf, v);
    }
    buf.put(`]}`);
}

string findingCategoryId(FindingCategory c) pure nothrow @safe {
    final switch (c) {
        case FindingCategory.SubdivReadiness: return "subdivReadiness";
        case FindingCategory.Cleanup:          return "cleanup";
        case FindingCategory.Topology:         return "topology";
        case FindingCategory.Retopo:           return "retopo";
    }
}

string findingSeverityId(FindingSeverity s) pure nothrow @safe {
    final switch (s) {
        case FindingSeverity.Info:    return "info";
        case FindingSeverity.Suggest: return "suggest";
        case FindingSeverity.Warn:    return "warn";
    }
}

private void putJsonString(B)(ref B buf, string value) {
    buf.put(JSONValue(value).toString());
}

private void putJsonFloat(B)(ref B buf, float value) {
    import std.format : format;
    if (value.isFinite)
        buf.put(format("%f", value));
    else
        buf.put(`null`);
}

private void putUintArrayJson(B)(ref B buf, const(uint)[] values) {
    buf.put(`[`);
    foreach (i, v; values) {
        if (i) buf.put(`,`);
        buf.put(v.to!string);
    }
    buf.put(`]`);
}

// =======================================================================
// Unit tests
// =======================================================================

version(unittest) {
    import mesh : makeCube;
    import math : Vec3;
}

unittest {
    // Cube: SubdivReadiness must surface at least one finding whose edges
    // group (a subset of) the cube's 12 sharp edges.
    auto m = makeCube();
    auto findings = analyzeMesh(m);

    assert(findings.length >= 1, "cube should yield at least one SubdivReadiness finding");

    bool[uint] coveredEdges;
    foreach (ref f; findings) {
        assert(f.category == FindingCategory.SubdivReadiness);
        assert(f.suggestedOp == "loop.slice");
        assert(f.edges.length > 0, "a SubdivReadiness finding should carry a non-empty edge set");
        foreach (ei; f.edges) coveredEdges[ei] = true;
    }
    assert(coveredEdges.length > 0);
    foreach (ei; coveredEdges.byKey)
        assert(ei < m.edges.length, "finding edge index must be a valid mesh edge");
}

unittest {
    // A flat grid has no sharp edges — analyzeMesh must return [] cleanly,
    // not crash and not spam suggestions on a smooth surface.
    import mesh : makeGridPlane;
    auto m = makeGridPlane(4);
    auto findings = analyzeMesh(m);
    assert(findings.length == 0, "a flat grid should yield zero findings");
}

unittest {
    // Empty mesh: no vertices/edges at all must not crash.
    Mesh m;
    auto findings = analyzeMesh(m);
    assert(findings.length == 0);
}

unittest {
    // Determinism: analyzing the same mesh twice yields identical findings
    // in the same order with the same scores.
    auto m = makeCube();
    auto a = analyzeMesh(m);
    auto b = analyzeMesh(m);
    assert(a.length == b.length);
    foreach (i; 0 .. a.length) {
        assert(a[i].id == b[i].id);
        assert(a[i].edges == b[i].edges);
        assert(a[i].score == b[i].score);
        assert(a[i].category == b[i].category);
        assert(a[i].severity == b[i].severity);
    }
}

unittest {
    // findingsToJson: valid JSON array; each object carries the expected
    // key set and round-trips the id/category/severity/score/edges.
    import std.json : parseJSON, JSONType;

    auto m = makeCube();
    auto findings = analyzeMesh(m);
    assert(findings.length >= 1);

    auto json = findingsToJson(findings);
    auto parsed = parseJSON(json);
    assert(parsed.type == JSONType.array);
    assert(parsed.array.length == findings.length);

    auto first = parsed.array[0];
    assert(first["id"].str == findings[0].id);
    assert(first["category"].str == findingCategoryId(findings[0].category));
    assert(first["severity"].str == findingSeverityId(findings[0].severity));
    assert(first["message"].str == findings[0].message);
    assert(first["suggestedOp"].str == findings[0].suggestedOp);
    assert(first["edges"].array.length == findings[0].edges.length);
    assert(first["features"].array.length == findings[0].features.length);
    assert(first["verts"].array.length == 0);
    assert(first["faces"].array.length == 0);
}

unittest {
    // MAX_FINDINGS_PER_CATEGORY / maxFindingsPerCategory clamp: a mesh with
    // many disjoint sharp-edge islands, requested with a huge (or zero/
    // negative) cap, never exceeds the kernel ceiling and never crashes on
    // a degenerate option value.
    Mesh m;
    // 40 disjoint "hinge" islands (two quad wings meeting at a 90deg ridge
    // edge each — same shape as the isolated-hinge case proven in
    // ai.support_loop_candidates's unittest), far apart so no edge-loop walk
    // crosses islands and each yields exactly one 1-edge candidate.
    foreach (i; 0 .. 40) {
        immutable float x = cast(float)i * 10.0f;
        immutable uint baseIdx = cast(uint)m.vertices.length;
        m.vertices ~= [
            Vec3(x, 0.0f, 0.0f), Vec3(x, 1.0f, 0.0f),   // ridge
            Vec3(x + 1.0f, 0.0f, 0.0f), Vec3(x + 1.0f, 1.0f, 0.0f), // wing1 far
            Vec3(x, 0.0f, 1.0f), Vec3(x, 1.0f, 1.0f),   // wing2 far
        ];
        m.addFace([baseIdx, baseIdx + 1, baseIdx + 3, baseIdx + 2]);
        m.addFace([baseIdx + 1, baseIdx, baseIdx + 4, baseIdx + 5]);
    }
    m.buildLoops();

    AnalyzeOptions huge;
    huge.maxFindingsPerCategory = int.max;
    auto findingsHuge = analyzeMesh(m, huge);
    assert(findingsHuge.length <= MAX_FINDINGS_PER_CATEGORY,
           "kernel cap must bound findings regardless of a huge caller-requested cap");

    AnalyzeOptions zero;
    zero.maxFindingsPerCategory = 0;
    auto findingsZero = analyzeMesh(m, zero);
    assert(findingsZero.length >= 1,
           "a non-positive cap must be floored to at least 1, not yield zero findings outright");

    AnalyzeOptions negative;
    negative.maxFindingsPerCategory = -5;
    auto findingsNeg = analyzeMesh(m, negative);
    assert(findingsNeg.length == findingsZero.length);
}
