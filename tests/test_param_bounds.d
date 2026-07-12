// test_param_bounds.d — generic fuzz-smoke for the param-bounds "born-
// clamped" contract (task 0365, doc/param_bounds_plan.md Phase 3).
//
// Two independent blocks:
//
//   A. Static contract check — reads GET /api/registry?params=1 (the Phase-3
//      schema endpoint, source/http_server.d / source/app.d
//      setRegistryProvider) and asserts every count-like Int/Float Param,
//      across the WHOLE registry (every command + every tool), carries
//      `.enforceBounds()` and a finite `.max()` — UNLESS it is on the
//      explicit exemption allowlist below. This has zero geometry cost and
//      is what makes the guard "run on every new tool": a future unenforced
//      count/segments/sides/iter param fails it immediately, the way
//      tools/arc.d's `segments` would have before P1/P2 closed that gap.
//
//   B. Extreme-drive smoke — for a small, deliberately narrow subset of
//      ALREADY-capped sites (P1 kernel caps + P2 enforceBounds, both landed
//      on this branch before Phase 3), drives count-like params to extremes
//      (max*10, 0, -1, a saturating-huge probe) and asserts every HTTP call
//      completes under a wall-clock watchdog and /api/model stays within a
//      sane vertex/face ceiling. Per the plan's shared-instance hazard
//      (run_test.d reuses ONE `vibe3d --test` per worker across its whole
//      slice — see run_test.d ~686-688): every site here is chosen because
//      it is ALREADY clamped, so the extreme value clamps instead of
//      reaching an OOM. Block B proves the caps hold end-to-end through the
//      real HTTP path; it is not a "does the app survive an uncapped op"
//      test — that proof lives in the per-kernel DoS unittests running in
//      process-isolated `dub test --config=modeling`.
//
// Block-A allowlist provenance: the plan's own written allowlist
// (doc/param_bounds_plan.md §3.A) names exactly 4 entries — mesh.sweep.count,
// mesh.addPoint.t, mesh.addLoop.position, mesh.reduce.count. Running the
// heuristic below against the LIVE registry surfaced 2 more sites that are
// verifiably the same safe-by-construction shape (reject-sentinel) but were
// not enumerated in the plan doc — see the per-entry comments below and the
// implementation report for the citations (mesh.loopSliceTool.position/
// insertAt — the interactive-tool-side twin of the already-allowlisted
// mesh.addLoop.position reject sentinel). A third apparent class
// (mesh.axisSlice.count, mesh.julienne.countA/countB) was a genuine P2 gap,
// not a safe exemption — task 0365 P2-fast-follow added
// `.max(MAX_AXIS_SLICE_COUNT).enforceBounds()` to all three (P1's kernel cap
// was already in place; only the Param-layer bound was missing), so they now
// satisfy Block A directly and are not allowlisted.

import std.net.curl;
import std.json;
import std.regex   : regex, matchFirst;
import std.conv     : to;
import std.array    : join;
import std.datetime.stopwatch : StopWatch, AutoStart;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers (same shape as tests/test_fixture_radial_array.d /
// tests/test_mesh_array.d).
// ---------------------------------------------------------------------------

private enum string BASE = "http://localhost:8080";

void resetCube() {
    auto resp = post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

JSONValue postCommandRaw(string body_) {
    return parseJSON(post(BASE ~ "/api/command", body_));
}

void postCommand(string body_) {
    auto j = postCommandRaw(body_);
    assert(j["status"].str == "ok",
        "/api/command failed: `" ~ body_ ~ "` -> " ~ j.toString);
}

JSONValue getModel()     { return parseJSON(get(BASE ~ "/api/model")); }
JSONValue getRegistryWithParams() {
    return parseJSON(get(BASE ~ "/api/registry?params=1"));
}

// ---------------------------------------------------------------------------
// Block A — static "born-clamped" contract check
// ---------------------------------------------------------------------------

// Count-like name heuristic (plan §3.A / D2), with one deliberate deviation:
// the plan's literal regex also lists bare "major|minor" (meant to catch
// majorSegments/minorSegments-style counts) — but those already match via
// "segment", and the bare alternatives ALSO false-positive on dimensional
// params like prim.torus's majorRadius/minorRadius (a radius is not a
// DoS-scaling count; it has no natural upper bound). Dropped as redundant
// + false-positive-prone; verified against the live registry that dropping
// it does not miss any genuine count-like param (grep audit, no other
// "major"/"minor"-named param exists outside prim.torus's segment pair,
// which still matches via "segment").
private auto countLikeNameRe =
    regex(`(?i)count|segment|sides?|rings?|iter|steps|subdiv|num[xyz]?|precision`);

/// A numeric Param is "count-like" (subject to the born-clamped contract)
/// when either (a) its name suggests an allocation/loop-scaling knob, or
/// (b) it is shaped like a normalized-position reject sentinel: an OPEN
/// interval strictly inside (0,1) on both ends (`0 < min` and `max < 1`).
/// (b) exists specifically to catch mesh.addPoint.t / mesh.addLoop.position
/// (and their tool-side twins), whose names ("t", "position") give no name-
/// based signal at all — the value 0 or 1 there is a documented reject
/// condition (evaluate() rejects the degenerate endpoint), which is exactly
/// why the interval EXCLUDES both endpoints. Verified against the live
/// registry that this is narrow enough not to also catch ordinary closed-
/// range sliders like ratio/strn/tA/tB (min==0 or max==1 exactly — ordinary
/// valid boundary values, not reject sentinels) — a broader "has any finite
/// max" rule was tried first and pulled in ~30 unrelated bounded floats
/// (angles, distances, ratios), which is not what this check is for.
bool isCountLike(JSONValue p) {
    string kind = p["kind"].str;
    if (kind != "Int" && kind != "Float") return false;
    if (!matchFirst(p["name"].str, countLikeNameRe).empty) return true;
    if ("min" !in p || "max" !in p) return false;
    double lo = p["min"].type == JSONType.integer ? cast(double)p["min"].integer : p["min"].floating;
    double hi = p["max"].type == JSONType.integer ? cast(double)p["max"].integer : p["max"].floating;
    return lo > 0.0 && hi < 1.0;
}

// Explicit exemption allowlist. Every entry is a VERIFIED safe-by-
// construction param the heuristic would otherwise false-positive on —
// either a self-clamping op (huge input degrades to a bounded no-op, so
// enforcing would corrupt a legitimate large request) or a reject sentinel
// (an out-of-range value must pass through so evaluate() can reject it,
// per params.d:799-837's opt-in-enforcement rationale). Format:
// "<registeredId>.<paramName>".
immutable string[] blockAAllowlist = [
    // --- Mandated 4 (doc/param_bounds_plan.md §3.A) ---
    "mesh.sweep.count",
        // reject sentinel: count<2 -> status!=ok (test_mesh_sweep.d:234-253);
        // kernel-capped only (mesh.MAX_SWEEP_SIDES), never Param-enforced.
    "mesh.addPoint.t",
        // reject sentinel: t outside (0.001,0.999) -> status!=ok
        // (test_add_point.d:298-301).
    "mesh.addLoop.position",
        // reject sentinel, identical class (commands/mesh/loop_slice.d
        // MeshAddLoop).
    "mesh.reduce.count",
        // self-clamps to a no-op: target = min(count, origFaces)
        // (commands/mesh/reduce.d:62-67); a huge count is a legitimate
        // request ("reduce as far as possible"), not a DoS — the reduce
        // loop is bounded by origFaces, not by count.

    // --- Additional verified exemptions (same reject-sentinel class as
    //     mesh.addPoint.t / mesh.addLoop.position above), found by running
    //     this checker against the live registry. Not enumerated in the
    //     plan doc's 4-entry list; see the file header and the
    //     implementation report. ---
    "mesh.loopSliceTool.position",
        // reject-sentinel twin of mesh.addLoop.position, on the
        // interactive-tool side (tools/loop_slice_tool.d) — identical
        // (0.001,0.999) open-interval contract, same command-side kernel
        // (MeshAddLoop) backs both.
    "mesh.loopSliceTool.insertAt",
        // ditto — the tool's second position-typed reject-sentinel field
        // (drives per-gesture "current" slice placement).
];

unittest { // BlockA_BornClampedContract
    auto reg = getRegistryWithParams();
    assert("commandParams" in reg.object, "registry missing commandParams — is ?params=1 wired?");
    assert("toolParams"    in reg.object, "registry missing toolParams — is ?params=1 wired?");

    bool[string] allowSet;
    foreach (a; blockAAllowlist) allowSet[a] = true;
    bool[string] allowSeen;

    string[] failures;
    int checked = 0;

    void scan(string sectionLabel, JSONValue section) {
        foreach (id, params; section.object) {
            foreach (p; params.array) {
                if (!isCountLike(p)) continue;
                string key = id ~ "." ~ p["name"].str;
                ++checked;
                if (key in allowSet) { allowSeen[key] = true; continue; }
                bool hasFiniteMax = ("max" in p) !is null;
                bool enforced     = p["enforceBounds"].type == JSONType.true_;
                if (!enforced || !hasFiniteMax)
                    failures ~= sectionLabel ~ ":" ~ key ~
                        " (enforceBounds=" ~ (enforced ? "true" : "false") ~
                        ", max=" ~ (hasFiniteMax ? p["max"].toString : "none") ~ ")";
            }
        }
    }
    scan("command", reg["commandParams"]);
    scan("tool",    reg["toolParams"]);

    assert(failures.length == 0,
        "Block A: unenforced count-like param(s) found — add a kernel cap + " ~
        ".enforceBounds(), or add a citation to blockAAllowlist:\n  " ~
        failures.join("\n  "));

    // "No misses": every allowlist entry must actually match a live
    // count-like param. A stale entry (renamed/removed/since-enforced
    // param) would silently narrow the checked surface without anyone
    // noticing — this catches that drift the other direction.
    string[] stale;
    foreach (a; blockAAllowlist)
        if (a !in allowSeen) stale ~= a;
    assert(stale.length == 0,
        "Block A: allowlist entries never matched a live count-like param " ~
        "(renamed, removed, or since-enforced — remove or update): " ~
        stale.join(", "));

    // Sanity: the allowlist should be a small minority of the checked
    // surface, not most of it (a heuristic that exempts nearly everything
    // it flags isn't doing any work).
    assert(checked > blockAAllowlist.length,
        "Block A: expected more count-like params (" ~ checked.to!string ~
        ") than allowlist entries (" ~ blockAAllowlist.length.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Block B — extreme-drive smoke (already-capped paths only)
// ---------------------------------------------------------------------------

private enum WATCHDOG_MSEC = 2000;

private void assertPrompt(void delegate() op, string ctx) {
    auto sw = StopWatch(AutoStart.yes);
    op();
    sw.stop();
    auto ms = sw.peek.total!"msecs";
    assert(ms < WATCHDOG_MSEC,
        ctx ~ ": exceeded watchdog (" ~ ms.to!string ~ "ms >= " ~
        WATCHDOG_MSEC.to!string ~ "ms)");
}

private void assertModelBounded(string ctx,
                                 long maxVerts = 2_000_000,
                                 long maxFaces = 2_000_000) {
    auto m = getModel();
    long vc = m["vertexCount"].integer;
    long fc = m["faceCount"].integer;
    assert(vc < maxVerts,
        ctx ~ ": vertexCount " ~ vc.to!string ~ " exceeds sane ceiling " ~ maxVerts.to!string);
    assert(fc < maxFaces,
        ctx ~ ": faceCount "  ~ fc.to!string ~ " exceeds sane ceiling " ~ maxFaces.to!string);
}

// Site 1 — mesh.loopSliceTool.count: the PRIMARY set-time hazard (plan gap
// #5). The kernel cap on insertEdgeLoopsMulti lives inside doApply, but
// syncPositionsToCount() grows `positions_` synchronously on the *set*
// call, before any apply — so this site's read-back + prompt-set assertion
// is the one that actually matters (doApply is not exercised here; the
// hazard this guards against happens before doApply could ever run).
unittest { // BlockB_LoopSliceCountSetTimeGuard
    resetCube();
    postCommand("tool.set mesh.loopSliceTool on");
    foreach (extreme; ["2560", "0", "-1", "1000000000"]) {
        assertPrompt(() {
            postCommand("tool.attr mesh.loopSliceTool count " ~ extreme);
        }, "loopSliceTool.count set(" ~ extreme ~ ")");

        auto q = postCommandRaw("tool.attr mesh.loopSliceTool count ?");
        assert(q["status"].str == "ok", "count read-back failed: " ~ q.toString);
        long v = q["value"].integer;
        assert(v >= 1 && v <= 256,
            "loopSliceTool.count should clamp to [1,256], got " ~ v.to!string ~
            " for extreme " ~ extreme);
    }
    postCommand("tool.set mesh.loopSliceTool off");
}

// Site 2 — mesh.radialSweepTool.sides: tool apply-time hazard, driven
// through the TOOL path (tool.set / tool.attr / tool.doApply — distinct
// from the one-shot /api/command path exercised by sites 3-5 below).
// Deliberately does NOT select a valid sweep profile first: doApply is
// expected to answer status:error ("nothing to sweep") rather than ok —
// both are acceptable non-hang outcomes here. The point of this site is
// that the Param clamp (min(1).max(1024).enforceBounds()) holds and the
// call returns promptly regardless of what doApply ultimately decides.
unittest { // BlockB_RadialSweepSidesToolPathBounded
    resetCube();
    postCommand("tool.set mesh.radialSweepTool on");
    foreach (extreme; ["10240", "0", "-1", "1000000000"]) {
        postCommand("tool.attr mesh.radialSweepTool sides " ~ extreme);
        auto q = postCommandRaw("tool.attr mesh.radialSweepTool sides ?");
        assert(q["status"].str == "ok", "sides read-back failed: " ~ q.toString);
        long v = q["value"].integer;
        assert(v >= 1 && v <= 1024,
            "radialSweepTool.sides should clamp to [1,1024], got " ~ v.to!string ~
            " for extreme " ~ extreme);

        assertPrompt(() { postCommandRaw("tool.doApply"); },
            "radialSweepTool.sides doApply(" ~ extreme ~ ")");
        assertModelBounded("radialSweepTool.sides(" ~ extreme ~ ")");
    }
    postCommand("tool.set mesh.radialSweepTool off");
}

// Site 3 — prim.arc.segments: one-shot command apply-time hazard
// (buildArc's O(segments) loop). A primitive generator — no pre-existing
// selection required.
unittest { // BlockB_ArcSegmentsApplyBounded
    foreach (extreme; ["10240", "0", "-1", "1000000000"]) {
        resetCube();
        assertPrompt(() {
            postCommand(`{"id":"prim.arc","params":{"segments":` ~ extreme ~ `}}`);
        }, "prim.arc.segments(" ~ extreme ~ ")");
        assertModelBounded("prim.arc.segments(" ~ extreme ~ ")");
    }
}

// Site 4 — mesh.array.count: one-shot command apply-time hazard
// (arrayFaces's O(count) copy loop). Whole-mesh default (no selection
// needed). count=0/-1 clamp to the Param's min(1) floor, which then makes
// the copy a no-op ("count includes the original") — the command answers
// status:error for that case (nothing to do), which is an acceptable
// bounded/prompt outcome, not a failure of this smoke.
unittest { // BlockB_ArrayCountApplyBounded
    foreach (extreme; ["2560", "0", "-1", "1000000000"]) {
        resetCube();
        assertPrompt(() {
            postCommandRaw(`{"id":"mesh.array","params":{"count":` ~ extreme ~
                `,"offset":[1,0,0],"weld":0}}`);
        }, "mesh.array.count(" ~ extreme ~ ")");
        assertModelBounded("mesh.array.count(" ~ extreme ~ ")");
    }
}

// Site 5 — mesh.smooth.iter: one-shot command iteration-count hazard (the
// Laplacian relaxation loop). Smoothing never changes vertex/face COUNT
// (only positions), so the meaningful bound here is wall-clock — the
// model-size assertion is still run as a basic "didn't error into a
// degenerate mesh" sanity check.
unittest { // BlockB_SmoothIterApplyBounded
    foreach (extreme; ["2560", "0", "-1", "1000000000"]) {
        resetCube();
        assertPrompt(() {
            postCommand("mesh.smooth strn:1 iter:" ~ extreme);
        }, "mesh.smooth.iter(" ~ extreme ~ ")");
        assertModelBounded("mesh.smooth.iter(" ~ extreme ~ ")");
    }
}
