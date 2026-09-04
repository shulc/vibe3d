// test_slice_split_gap_seam.d — the Slice tool's split+gap SEAM WRITE, over
// HTTP (task 1903 Stage E3, added in the E3 review round).
//
// WHAT IT PINS. `mesh_ops.cut.cutByPlaneEx`'s Gap arm pushes the two halves of
// every seam pair apart along the cut normal. Until Stage E3 it did that with
// two RAW `vertices[pr[0]] = …` writes, which reach no mutation hook at all:
// the coordinates moved and the change bus never heard about it. E3 replaced
// them with ONE `ed.setVertexPositions(...)`, so the edit now publishes the
// Position class exactly once. `tests/unit/mesh_ops/cut_test.d` pins the op-log
// side of that (one `Kind.SetPos` entry, not eight); above the unit lane there
// was nothing, and the arm that actually carries the write in production — a
// RESTRICTED split+gap, i.e. with polygons selected — had no suite cell of any
// kind. This file is that cell.
//
// WHY THE RESTRICTED ARM, AND WHY THE OTHER ONE IS THE CONTROL.
// `tools/slice/slice_tool.d` routes an UNRESTRICTED split+gap to
// `sliceSplitGap` — two real parallel plane cuts plus a band delete (task
// 0291) — which moves no EXISTING vertex and so publishes no Position. Only
// the restricted arm reaches `cutByPlaneEx`'s seam separation. So the two arms
// are a differential and not one number: the same tool with the same gap, one
// publishing Position and the other measurably not. A Position tick that fired
// on both would be measuring "a slice happened", not "the seam write is on the
// bus".
//
// WHAT NO CONSUMER DOES WITH IT, MEASURED (E3 review, 2026-08-26). Both live
// readers of this class in this tree are OR-masks that `Points|Polygons`
// already trips — `display_sync.DisplayRefreshMask` and
// `change_bus.MeshChangeAll` — and the one construct that could subscribe to
// Position ALONE, `MeshDirtyEpochs.forClasses(MeshEditScope.Position)`, has no
// production caller (every occurrence is inside `mesh_dirty.d`'s own
// unittests). So nothing downstream behaves differently because of the new
// bit, and that is exactly why this is a bus-counter assertion and not a
// behavioural one: there is no behaviour to assert. It is worth pinning anyway
// — the day a Position-only consumer appears (task 1906 §2.3), this cell is
// what says the plane cut feeds it, and a suite that only ever looked at
// geometry would not notice the feed going away.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : abs;

void main() {}

alias BASE = testBaseUrl;

JSONValue postAt(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

JSONValue model()   { return parseJSON(cast(string)get(BASE ~ "/api/model")); }
JSONValue changes() { return parseJSON(cast(string)get(BASE ~ "/api/changes")); }

// One /api/command argstring (the `tool.set` / `tool.attr` / `tool.doApply`
// spelling the fixture harness uses), asserted ok.
void cmd(string s) {
    auto r = postAt("/api/command", s);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "`" ~ s ~ "` failed: " ~ r.toString);
}

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.floating;
}

// The faces the x = 0 cut plane crosses, read off the CURRENT model rather than
// hard-coded: a face-index literal is a different cube the day /api/reset
// changes its winding order, and the test would then restrict to faces the
// plane misses and quietly measure a refusal.
uint[] crossingFaces() {
    auto m = model();
    auto vs = m["vertices"].array;
    uint[] out_;
    foreach (i, f; m["faces"].array) {
        double lo = double.max, hi = -double.max;
        foreach (c; f.array) {
            const double x = num(vs[cast(size_t)c.integer].array[0]);
            if (x < lo) lo = x;
            if (x > hi) hi = x;
        }
        if (lo < -1e-6 && hi > 1e-6) out_ ~= cast(uint)i;
    }
    return out_;
}

// The distinct x coordinates of the current model, rounded to 4 decimals and
// sorted — the shape of the opened gap, which both arms must agree on.
double[] distinctX() {
    import std.algorithm : sort, uniq;
    import std.array     : array;
    double[] xs;
    foreach (v; model()["vertices"].array) {
        import std.math : round;
        xs ~= round(num(v.array[0]) * 10_000.0) / 10_000.0;
    }
    sort(xs);
    return xs.uniq.array;
}

// Reset to the standard cube and clear the selection.
void loadCube() {
    auto r = postAt("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    auto s = postAt("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    assert(s["status"].str == "ok", "/api/select failed: " ~ s.toString);
}

// Arm the Slice tool for an infinite split+gap cut on the plane x = 0 (the line
// runs along Z, the headless work plane is +Y, so the plane normal is ||X — the
// same law every slice_*.json fixture uses). Leaves the tool ON and armed; the
// caller samples /api/changes, then applies.
void armSplitGap(double gap) {
    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool split 1");
    cmd("tool.attr mesh.sliceTool caps 1");
    cmd("tool.attr mesh.sliceTool infinite 1");
    cmd(format("tool.attr mesh.sliceTool gap %g", gap));
    cmd("tool.attr mesh.sliceTool startX 0");
    cmd("tool.attr mesh.sliceTool startY 0");
    cmd("tool.attr mesh.sliceTool startZ -1");
    cmd("tool.attr mesh.sliceTool endX 0");
    cmd("tool.attr mesh.sliceTool endY 0");
    cmd("tool.attr mesh.sliceTool endZ 1");
}

enum uint kPosition = 1 << 0;   // MeshEditScope.Position
enum uint kPoints   = 1 << 1;
enum uint kPolygons = 1 << 2;

unittest { // a RESTRICTED split+gap publishes the seam write: Position, once
    loadCube();
    auto cross = crossingFaces();
    assert(cross.length == 4,
        format("the x=0 plane crosses %d cube face(s), expected 4 — the "
             ~ "restriction below would select faces the plane misses and the "
             ~ "command would refuse, making every counter assertion vacuous",
               cross.length));

    auto sel = postAt("/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d,%d]}`, cross[0], cross[1])));
    assert(sel["status"].str == "ok", "/api/select polygons failed: " ~ sel.toString);

    armSplitGap(0.2);
    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();
    cmd("tool.set mesh.sliceTool off");

    // ANTI-VACUITY FIRST. A refused apply moves no counter at all, and
    // `totalPosition` would then read +0 for a reason that has nothing to do
    // with the seam write.
    auto m = model();
    assert(m["vertexCount"].integer == 16 && m["faceCount"].integer == 8,
        format("the restricted split+gap left V=%d F=%d, expected V=16 F=8 "
             ~ "(4 crossing verts + their 4 duplicates on top of 8; 2 of the 4 "
             ~ "crossed faces split, +2 caps) — a refusal makes the counter "
             ~ "assertions below vacuous",
               m["vertexCount"].integer, m["faceCount"].integer));

    const long dPos = a["totalPosition"].integer - b["totalPosition"].integer;
    assert(dPos == 1,
        format("the restricted split+gap published Position %d time(s), "
             ~ "expected exactly 1. This is the seam separation reaching the "
             ~ "change bus: pre-E3 it was two raw `vertices[pr[0]] = …` writes "
             ~ "that no hook could see, and this counter read +0. A 0 means the "
             ~ "raw write is back (or the arm routed to sliceSplitGap, which "
             ~ "moves no existing vertex — see the control block below); an 8 "
             ~ "means the bulk `setVertexPositions` became a per-vertex loop "
             ~ "(task 1903 §2.5, Stage E3).", dPos));
    // `lastDeliveryFlags`, not the frame flush's word: task 1906 stage 3 removed
    // `lastFlushFlags` from /api/changes. The two are NOT interchangeable in
    // general (measured before a doApply: flush word 0x8, last delivery 0x3F);
    // they agree at both assertion points here only because `tool.doApply`
    // produces exactly ONE delivery (deliveryCount +1 on both arms), so the
    // frame's coalesced word and the last delivery's word are the same word.
    const uint flags = cast(uint)a["lastDeliveryFlags"].integer;
    assert((flags & kPosition) != 0,
        format("the flush that delivered the restricted split+gap carried "
             ~ "flags 0x%x, with no Position bit (0x%x) — the per-class total "
             ~ "and the delivered flag word must agree", flags, kPosition));

    // The gap itself: 0.2 centered ⇒ the seam pairs sit at x = ±0.1 and the
    // cube's own faces stay at ±0.5. Without this the Position tick could be
    // any position write at all.
    auto xs = distinctX();
    assert(xs.length == 4 && abs(xs[0] + 0.5) < 1e-4 && abs(xs[1] + 0.1) < 1e-4
        && abs(xs[2] - 0.1) < 1e-4 && abs(xs[3] - 0.5) < 1e-4,
        format("the restricted split+gap left distinct x = %s, expected "
             ~ "[-0.5, -0.1, 0.1, 0.5] — gap 0.2 about the centre", xs));

    const long leaks = a["batchLeaks"].integer - b["batchLeaks"].integer;
    const long nested = a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer;
    const long unbatched = a["unbatchedGeometryCommits"].integer
                         - b["unbatchedGeometryCommits"].integer;
    assert(leaks == 0 && nested == 0 && unbatched == 0,
        format("the restricted split+gap moved batchLeaks by %d, "
             ~ "nestedBatchOpens by %d, unbatchedGeometryCommits by %d — all "
             ~ "three must stay 0 (task 1903 §2.2c, §2.3, §3.2 L2)",
               leaks, nested, unbatched));
}

unittest { // CONTROL — the UNRESTRICTED whole-mesh gap publishes NO Position
    // Same tool, same gap, nothing selected: `slice_tool.d` routes this one to
    // `sliceSplitGap` (two parallel cuts + a band delete), which ADDS and
    // REMOVES geometry instead of moving any existing vertex. If this arm also
    // ticked Position, the block above would be measuring "a slice happened".
    loadCube();
    armSplitGap(0.2);
    auto b = changes();
    cmd("tool.doApply");
    auto a = changes();
    cmd("tool.set mesh.sliceTool off");

    auto m = model();
    assert(m["vertexCount"].integer == 16 && m["faceCount"].integer == 12,
        format("the unrestricted split+gap left V=%d F=%d, expected V=16 F=12 "
             ~ "— a refusal would make the +0 below vacuous",
               m["vertexCount"].integer, m["faceCount"].integer));

    const long dPos = a["totalPosition"].integer - b["totalPosition"].integer;
    assert(dPos == 0,
        format("the UNRESTRICTED split+gap published Position %d time(s), "
             ~ "expected 0: this route (sliceSplitGap — two plane cuts and a "
             ~ "band delete) moves no existing vertex. A non-zero here means "
             ~ "the two arms are no longer distinguishable, and the +1 the "
             ~ "block above asserts stops being evidence about the seam write "
             ~ "(task 1903 Stage E3, task 0291).", dPos));
    const uint flags = cast(uint)a["lastDeliveryFlags"].integer;
    assert(flags == (kPoints | kPolygons),
        format("the flush that delivered the unrestricted split+gap carried "
             ~ "flags 0x%x, expected 0x%x (Points|Polygons and nothing else — "
             ~ "no Position, and no Marks: the band delete carries no "
             ~ "selection). Measured at Stage E3.",
               flags, kPoints | kPolygons));

    // AND THE GEOMETRY AGREES. Both routes open the same 0.2 gap about the
    // centre, so the difference between them is which bus classes fire, not
    // what the user sees. This is what says the E3 conversion reproduced the
    // raw write's numbers rather than merely publishing something.
    auto xs = distinctX();
    assert(xs.length == 4 && abs(xs[0] + 0.5) < 1e-4 && abs(xs[1] + 0.1) < 1e-4
        && abs(xs[2] - 0.1) < 1e-4 && abs(xs[3] - 0.5) < 1e-4,
        format("the unrestricted split+gap left distinct x = %s, expected the "
             ~ "same [-0.5, -0.1, 0.1, 0.5] the restricted arm produces", xs));
}
