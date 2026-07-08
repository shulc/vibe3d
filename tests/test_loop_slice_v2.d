// Tests for Loop Slice v2 (task 0239) — selection-based multi-seed
// activation, Edit(Move/Add/Remove), Mode(Free/Uniform/Symmetry), and the
// count<=1 escape hatch (owner objection #1). See tests/test_loop_slice_tool.d
// for the pre-0239 single-seed headless coverage (T1-T6, all still green —
// this file does NOT duplicate it) and tests/test_loop_slice_hover_state.d
// for the hover/sliceRing parity coverage (unchanged by this task).
//
//   V1 — M2: selecting edges on TWO DISTINCT (non-crossing) rings and
//        tool.doApply cuts BOTH rings in one pass (Count loops per ring).
//   V2 — M1/M2: Count applies PER RING, not globally — two distinct rings,
//        Count=2 gives 2 loops on EACH.
//   V3 — M3 Edit=Add: `insertAt` grows positions[]/count and doApply inserts
//        the extra loop.
//   V4 — M3 Edit=Remove: `removeCurrent` shrinks positions[]/count back down.
//   V5 — M3 Edit=Move (Free mode): scrubbing `position` relocates ONLY the
//        Current slice, others untouched.
//   V6 — M4 Mode=Uniform: positions == (k+1)/(count+1), always (a Free-mode
//        scrub is discarded the moment Mode flips back to Uniform).
//   V7 — M4 Mode=Symmetry: positions form mirrored pairs about 0.5; a scrub
//        of Current also moves its mirror partner.
//   V8 — Owner objection #1 (MAJOR): Count<=1 ALWAYS honors the scrub
//        regardless of Mode — Uniform must not freeze a Count==1 Position.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs, sqrt;

void main() {}

// --- HTTP helpers (mirror tests/test_loop_slice_tool.d) --------------------

string baseUrl = "http://localhost:8080";

void resetCube() {
    auto resp = post(baseUrl ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body_) {
    auto resp = post(baseUrl ~ "/api/load-mesh", body_);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post(baseUrl ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void postCommand(string body_) {
    auto resp = post(baseUrl ~ "/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(baseUrl ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(get(baseUrl ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(get(baseUrl ~ "/api/tool/state")); }

// --- geometry helpers (mirror tests/test_loop_slice_tool.d) ----------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

// Two disjoint unit cubes (cube B translated +3 on X) — the SAME fixture as
// the mesh.d insertEdgeLoopsMulti unittest (b)/(c): two rings that share NO
// faces at all, the simplest "Count loops per DISTINCT ring" case.
immutable string kTwoDisjointCubesJson = `{
  "vertices": [
    [-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
    [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5],
    [2.5,-0.5,-0.5],[3.5,-0.5,-0.5],[3.5,0.5,-0.5],[2.5,0.5,-0.5],
    [2.5,-0.5,0.5],[3.5,-0.5,0.5],[3.5,0.5,0.5],[2.5,0.5,0.5]
  ],
  "faces": [
    [0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4],
    [8,11,10,9],[12,13,14,15],[8,12,15,11],[9,10,14,13],[11,15,14,10],[8,9,13,12]
  ]
}`;

// ---------------------------------------------------------------------------
// V1 — M2: selecting one edge on EACH of two distinct (non-crossing) rings
// activates the tool against BOTH; tool.doApply cuts both in one pass.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    postLoadMesh(kTwoDisjointCubesJson);
    auto before = getModel();
    assert(before["vertexCount"].integer == 16 && before["faceCount"].integer == 12,
        "two-disjoint-cubes fixture must start at V=16/F=12");

    int eiA = edgeIndex(before, 0, 1);
    int eiB = edgeIndex(before, 8, 9);
    assert(eiA >= 0 && eiB >= 0, "both cube belt seeds must exist");
    postSelect("edges", [eiA, eiB]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.doApply");

    auto after = getModel();
    // Each cube independently: single-ring count=1 insert gives V:8->12(+4),
    // F:6->10(+4) (established by the pre-0239 tests). Two distinct,
    // non-crossing rings selected together must cut BOTH, not just one.
    assert(after["vertexCount"].integer == 16 + 2 * 4,
        "M2: expected both rings cut (V=24), got " ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 12 + 2 * 4,
        "M2: expected both rings cut (F=20), got " ~ after["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// V2 — M1/M2: Count applies PER RING, not globally. Two distinct
// (non-crossing) rings, Count=2 gives exactly 2 loops on EACH ring.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    postLoadMesh(kTwoDisjointCubesJson);
    auto before = getModel();

    int eiA = edgeIndex(before, 0, 1);
    int eiB = edgeIndex(before, 8, 9);
    postSelect("edges", [eiA, eiB]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 2");
    cmd("tool.doApply");

    auto after = getModel();
    // Each cube independently: single-ring count=2 insert gives
    // V:8->8+4*2=16 (+8), F:6->2+4*3=14 (+8) (ringLen=4 rails/faces).
    assert(after["vertexCount"].integer == 16 + 2 * 8,
        "V2: Count=2 per ring expected V=32, got " ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 12 + 2 * 8,
        "V2: Count=2 per ring expected F=28, got " ~ after["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// V3 — M3 Edit=Add: `insertAt` grows positions[]/count; doApply inserts the
// extra loop (plain cube, single seed — Mode=Free so the literal inserted
// value survives, undisturbed by a Uniform re-lay).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool mode free");

    auto st0 = getToolState();
    assert(st0["count"].integer == 1, "V3: fresh tool must start at count=1");
    assert(st0["positions"].array.length == 1, "V3: fresh tool must start with 1 position");

    cmd("tool.attr mesh.loopSliceTool insertAt 0.3");
    auto st1 = getToolState();
    assert(st1["count"].integer == 2,
        "V3: Add must grow count to 2, got " ~ st1["count"].integer.to!string);
    assert(st1["positions"].array.length == 2,
        "V3: Add must grow positions[] to length 2");
    assert(st1["current"].integer == 1,
        "V3: Add must move Current to the newly-added slice (index 1)");

    cmd("tool.doApply");
    auto after = getModel();
    // Plain cube, ringLen=4, count=2: V=8+4*2=16, F=2+4*3=14 (see V2 above).
    assert(after["vertexCount"].integer == 16,
        "V3: Add-grown Count=2 doApply expected V=16, got " ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 14,
        "V3: Add-grown Count=2 doApply expected F=14, got " ~ after["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// V3b — duplicate `insertAt` (task 0308, fuzz-found). Free mode does not
// enforce distinct slice fractions: `insertAt 0.5` on top of the fresh
// tool's own default `positions_ == [0.5]` reaches the kernel as the
// literal duplicate pair `[0.5, 0.5]`. Before the fix this corrupted the
// mesh (16v/28e/14f — 4 coincident vertex pairs + 4 zero-area faces)
// instead of collapsing to a clean single cut (12v/20e/10f, same as V4's
// Count=1 baseline).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool position 0.5");

    auto st0 = getToolState();
    assert(st0["count"].integer == 1 && st0["positions"].array.length == 1,
        "V3b: fresh tool must start at count=1, position=0.5");

    cmd("tool.attr mesh.loopSliceTool insertAt 0.5");   // duplicate cut position
    auto st1 = getToolState();
    assert(st1["count"].integer == 2, "V3b: Add must still grow count to 2");
    assert(st1["positions"].array.length == 2, "V3b: Add must still grow positions[] to 2");
    double p0 = st1["positions"].array[0].floating;
    double p1 = st1["positions"].array[1].floating;
    assert(abs(p0 - 0.5) < 1e-4 && abs(p1 - 0.5) < 1e-4,
        "V3b: both slots must read back 0.5 (the duplicate-cut precondition)");

    cmd("tool.doApply");
    auto after = getModel();
    // A duplicate cut position must collapse to the SAME clean single cut as
    // Count=1 (V4's baseline below) — NOT the corrupted 16v/28e/14f.
    assert(after["vertexCount"].integer == 12,
        "V3b: duplicate cut position must yield a clean single cut (V=12), got "
        ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 10,
        "V3b: duplicate cut position must yield a clean single cut (F=10), got "
        ~ after["faceCount"].integer.to!string);
    assert(after["edgeCount"].integer == 20,
        "V3b: duplicate cut position must yield a clean single cut (E=20), got "
        ~ after["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// V4 — M3 Edit=Remove: `removeCurrent` shrinks positions[]/count back down;
// a no-op at Count==1 (owner-decision D7).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool insertAt 0.3");   // count -> 2, current -> 1
    cmd("tool.attr mesh.loopSliceTool insertAt 0.7");   // count -> 3, current -> 2

    auto st0 = getToolState();
    assert(st0["count"].integer == 3, "V4: setup must reach count=3");

    // Shrink 3 -> 2 -> 1 via removeCurrent, then verify D7's no-op at
    // Count==1 with one more remove attempt.
    cmd("tool.attr mesh.loopSliceTool current 1");
    cmd("tool.attr mesh.loopSliceTool removeCurrent true");
    auto st1 = getToolState();
    assert(st1["count"].integer == 2,
        "V4: Remove must shrink count to 2, got " ~ st1["count"].integer.to!string);
    assert(st1["positions"].array.length == 2,
        "V4: Remove must shrink positions[] to length 2");

    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool removeCurrent true");
    auto st2 = getToolState();
    assert(st2["count"].integer == 1,
        "V4: second Remove must shrink count to 1, got " ~ st2["count"].integer.to!string);

    // D7 no-op: a THIRD remove at Count==1 must not shrink further (stays at 1).
    cmd("tool.attr mesh.loopSliceTool removeCurrent true");
    auto st3 = getToolState();
    assert(st3["count"].integer == 1,
        "V4: Remove at Count==1 must be a no-op (D7), got " ~ st3["count"].integer.to!string);
    assert(st3["positions"].array.length == 1,
        "V4: Remove at Count==1 must not empty positions[] (D7)");

    cmd("tool.doApply");
    auto after = getModel();
    assert(after["vertexCount"].integer == 12 && after["faceCount"].integer == 10,
        "V4: Count=1 after 2 removes must doApply as a normal single loop (V=12,F=10)");
}

// ---------------------------------------------------------------------------
// V5 — M3 Edit=Move (Mode=Free): scrubbing `position` relocates ONLY the
// Current slice; the others are left exactly as they were.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool insertAt 0.2");   // positions=[0.5,0.2], current=1
    cmd("tool.attr mesh.loopSliceTool insertAt 0.8");   // positions=[0.5,0.2,0.8], current=2

    cmd("tool.attr mesh.loopSliceTool current 1");
    cmd("tool.attr mesh.loopSliceTool position 0.35");  // Move: relocate ONLY index 1

    auto st = getToolState();
    assert(st["positions"].array.length == 3, "V5: Move must not change Count");
    double p0 = st["positions"].array[0].floating;
    double p1 = st["positions"].array[1].floating;
    double p2 = st["positions"].array[2].floating;
    assert(abs(p0 - 0.5) < 1e-4, "V5: index 0 (not Current) must be untouched, got " ~ p0.to!string);
    assert(abs(p1 - 0.35) < 1e-4, "V5: Current (index 1) must move to the scrubbed value, got " ~ p1.to!string);
    assert(abs(p2 - 0.8) < 1e-4, "V5: index 2 (not Current) must be untouched, got " ~ p2.to!string);
}

// ---------------------------------------------------------------------------
// V6 — M4 Mode=Uniform: positions == (k+1)/(count+1), ALWAYS — switching
// back to Uniform discards any Free-mode scrub (D3).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 3");   // Mode=Uniform is the default

    auto st = getToolState();
    assert(st["mode"].str == "uniform", "V6: default Mode for Count>1 must be Uniform");
    double[3] expected = [0.25, 0.5, 0.75];
    foreach (i; 0 .. 3) {
        double p = st["positions"].array[i].floating;
        assert(abs(p - expected[i]) < 1e-4,
            "V6: Uniform positions[" ~ i.to!string ~ "] expected " ~ expected[i].to!string
            ~ ", got " ~ p.to!string);
    }

    // A scrub attempt on a Uniform-mode Current is discarded (D3) — the law
    // still owns every position.
    cmd("tool.attr mesh.loopSliceTool current 1");
    cmd("tool.attr mesh.loopSliceTool position 0.99");
    auto st2 = getToolState();
    double p1 = st2["positions"].array[1].floating;
    assert(abs(p1 - 0.5) < 1e-4,
        "V6: Uniform must ignore a per-slice scrub (D3), got " ~ p1.to!string);
}

// ---------------------------------------------------------------------------
// V7 — M4 Mode=Symmetry: positions form mirrored pairs about 0.5; scrubbing
// Current also relocates its mirror partner to 1-t.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 3");
    cmd("tool.attr mesh.loopSliceTool mode symmetry");

    auto st0 = getToolState();
    assert(st0["mode"].str == "symmetry", "V7: mode must read back as symmetry");
    // Switching INTO Symmetry re-lays via the same even-spacing default,
    // which is inherently symmetric about 0.5 (see the kernel doc comment).
    double p0_0 = st0["positions"].array[0].floating;
    double p0_1 = st0["positions"].array[1].floating;
    double p0_2 = st0["positions"].array[2].floating;
    assert(abs((p0_0 + p0_2) - 1.0) < 1e-4, "V7: fresh Symmetry layout must already be mirrored");
    assert(abs(p0_1 - 0.5) < 1e-4, "V7: odd Count keeps a fixed center slice at 0.5");

    // Scrub Current (index 0) — its mirror partner (index count-1-0 = 2)
    // must move to 1-t; the center (index 1) must stay untouched.
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.2");

    auto st1 = getToolState();
    double p1_0 = st1["positions"].array[0].floating;
    double p1_1 = st1["positions"].array[1].floating;
    double p1_2 = st1["positions"].array[2].floating;
    assert(abs(p1_0 - 0.2) < 1e-4, "V7: scrubbed Current must land at 0.2, got " ~ p1_0.to!string);
    assert(abs(p1_2 - 0.8) < 1e-4,
        "V7: mirror partner must move to 1-t=0.8, got " ~ p1_2.to!string);
    assert(abs(p1_1 - 0.5) < 1e-4, "V7: center slice must stay untouched, got " ~ p1_1.to!string);
}

// ---------------------------------------------------------------------------
// V8 — Owner objection #1 (MAJOR): Count<=1 ALWAYS honors the scrub
// regardless of Mode — a default Mode (Uniform) must NEVER freeze a
// Count==1 Position at 0.5. Reproduces the pre-0239 T2 shape under the v2
// state model, plus an explicit check that the default Mode doesn't matter.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    auto st0 = getToolState();
    assert(st0["mode"].str == "uniform", "V8: default Mode must be Uniform (the risky case)");
    assert(st0["count"].integer == 1, "V8: fresh tool must start at Count=1");

    cmd("tool.attr mesh.loopSliceTool position 0.3");
    auto st1 = getToolState();
    assert(abs(st1["position"].floating - 0.3) < 1e-4,
        "V8: Count<=1 must ALWAYS honor the scrub even under the default Uniform Mode, got "
        ~ st1["position"].floating.to!string);
    assert(st1["positions"].array.length == 1 && abs(st1["positions"].array[0].floating - 0.3) < 1e-4,
        "V8: positions[0] must reflect the scrub at Count<=1");

    cmd("tool.doApply");
    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "V8: expected 12 verts after one loop");
    assert(after["faceCount"].integer == 10, "V8: expected 10 faces after one loop");
    bool atNeg = false, atPos = false;
    foreach (i; 0 .. after["vertices"].array.length) {
        auto v = vert(after, i);
        if (sqrt((v.x-(-0.2))^^2 + (v.y-(-0.5))^^2 + (v.z-(-0.5))^^2) < 1e-4) atNeg = true;
        if (sqrt((v.x-( 0.2))^^2 + (v.y-(-0.5))^^2 + (v.z-(-0.5))^^2) < 1e-4) atPos = true;
    }
    assert(atNeg != atPos,
        "V8: split midpoint at t=0.3 not found at exactly one of (-0.2|0.2,-0.5,-0.5)");
    bool atMid = false;
    foreach (i; 0 .. after["vertices"].array.length) {
        auto v = vert(after, i);
        if (sqrt(v.x*v.x + (v.y-(-0.5))^^2 + (v.z-(-0.5))^^2) < 1e-4) atMid = true;
    }
    assert(!atMid, "V8: unexpected t=0.5 midpoint present — Uniform must not have frozen Position");
}
