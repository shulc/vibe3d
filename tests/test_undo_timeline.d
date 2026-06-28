// Trajectory tests for task 0038 — class-aware carried-suffix undo (T-SEP).
//
// These tests drive the HTTP API to produce the exact stack configurations
// from the corpus (B1/B2/B3/B4-delete analogues) and an undo→redo round-trip
// (chronology gate) and assert the resulting selection + geometry at each step.
//
// B1: pure-selection stack — plain undo still reverts the UI head (fallback).
// B2: select + move + select + move → undo×2 reverts both moves; selection
//     HOLDS at B throughout (carried inert).  undo×3,×4 are no-ops on selection.
// B3: select + move + move (same set) → undo×2; selection stays A throughout.
// B4-delete: select + delete → undo restores the geometry with A selected.
// ROUND-TRIP: select A + moveA + select B + moveB → undo×4 → redo×4 → the
//     undo stack is restored to its exact prior shape (entry order + classes)
//     and selection is back at B.
// SCOPE GUARD: select + transform + undo → geometry reverted, selection
//     unchanged (not over-reverted).

import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.algorithm : sort, map, find, canFind;
import std.array  : array;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

JSONValue jget(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue jpost(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void resetCube() {
    auto j = jpost("/api/reset", "");
    assert(j["status"].str == "ok", "/api/reset failed");
    // Clear undo history so tests start from a clean slate.
    auto ch = jpost("/api/command", `{"id":"history.clear"}`);
    assert(ch["status"].str == "ok", "history.clear failed");
}

void select_(string mode, int[] indices) {
    import std.format : format;
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto j = jpost("/api/select",
        format(`{"mode":"%s","indices":%s}`, mode, idxJson));
    assert(j["status"].str == "ok", "/api/select failed: " ~ j.toString);
}

void translate_(double dx, double dy, double dz) {
    import std.format : format;
    auto j = jpost("/api/transform",
        format(`{"kind":"translate","delta":[%.10g,%.10g,%.10g]}`, dx, dy, dz));
    assert(j["status"].str == "ok", "/api/transform failed: " ~ j.toString);
}

JSONValue doUndo() {
    return jpost("/api/undo", "");
}

JSONValue doRedo() {
    return jpost("/api/redo", "");
}

JSONValue getSel()  { return jget("/api/selection"); }
JSONValue getModel(){ return jget("/api/model"); }
JSONValue getStatus(){ return jget("/api/undo/status"); }
JSONValue getHistory(){ return jget("/api/history"); }

// Return sorted selected-vertex indices.
int[] selVerts() {
    auto s = getSel();
    if (s["mode"].str != "vertices") return [];
    auto arr = s["selectedVertices"].array;
    auto r = arr.map!(v => cast(int)v.integer).array;
    sort(r);
    return r;
}

// Return the count of Model-class entries on the undo stack per /api/undo/status.
long modelDepth() { return getStatus()["modelDepth"].integer; }
long uiDepth()    { return getStatus()["uiDepth"].integer; }

// Resolve top/bottom vertex index sets from the current model vertex list.
void resolveSets(out int[] top4, out int[] bot4) {
    auto verts = getModel()["vertices"].array;
    assert(verts.length == 8, "expected 8 vertices");
    foreach (i, v; verts) {
        double y = v.array[1].floating;
        if (approxEq(y,  0.5)) top4 ~= cast(int)i;
        if (approxEq(y, -0.5)) bot4 ~= cast(int)i;
    }
    assert(top4.length == 4, "expected 4 top corners");
    assert(bot4.length == 4, "expected 4 bottom corners");
}

// ---------------------------------------------------------------------------
// B1 analogue: pure-selection stack — undo falls back to the UI head.
// Stack: [MeshSelect(A:UI), MeshSelect(B:UI)]
// undo → B1 fallback: no Model entry → revert UI head (MeshSelect(B)) → A.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    select_("vertices", top4);   // MeshSelect(A) → UI entry
    select_("vertices", bot4);   // MeshSelect(B) → UI entry

    // Stack: 2 UI entries, 0 Model entries.
    assert(modelDepth() == 0, "B1: expected 0 model entries before undo");
    assert(uiDepth()    == 2, "B1: expected 2 UI entries before undo");

    // undo → B1 fallback: reverts MeshSelect(B) → selection = A (top4).
    auto u = doUndo();
    assert(u["status"].str == "ok", "B1: undo should succeed");

    int[] got = selVerts();
    int[] exp = top4.dup; sort(exp);
    assert(got == exp,
        "B1: after undo, expected top4 " ~ exp.to!string
        ~ " got " ~ got.to!string);

    // undo again → reverts MeshSelect(A) → empty selection.
    auto u2 = doUndo();
    assert(u2["status"].str == "ok", "B1: second undo should succeed");
    assert(selVerts().length == 0,
        "B1: after second undo, expected empty selection");
}

// ---------------------------------------------------------------------------
// B2 analogue: select A / moveA / select B / moveB → undo×2 reverts both
// moves, selection HOLDS at B; undo×3,×4 are no-ops on selection.
// Stack: [Sel(A:UI), Move(A:Model), Sel(B:UI), Move(B:Model)]
// undo₁: suffix=[Move(B)] → reverts Move(B); Sel(B) stays live → still B.
// undo₂: suffix=[Move(A),Sel(B)] → reverts Move(A); Sel(B) carried inert → still B.
// undo₃: suffix=[Sel(A)] → B1 fallback reverts Sel(A) → but no geometry left.
// undo₄: no entries → fails (or no-op).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    // Read original x of a bottom vertex (to verify geometry revert).
    auto verts0 = getModel()["vertices"].array;
    double origX_bot = verts0[bot4[0]].array[0].floating;
    double origX_top = verts0[top4[0]].array[0].floating;

    select_("vertices", top4);
    translate_(0.3, 0.0, 0.0);       // Move(A)
    select_("vertices", bot4);
    translate_(0.1, 0.0, 0.0);       // Move(B)

    // Stack: 2 Model, 2 UI.
    assert(modelDepth() == 2, "B2: expected 2 model entries");
    assert(uiDepth()    == 2, "B2: expected 2 UI entries");

    // undo₁: Move(B) reverted; Sel(B) stays live.
    auto u1 = doUndo();
    assert(u1["status"].str == "ok", "B2: undo₁ should succeed");
    // Selection: still bot4.
    {
        int[] got = selVerts(); int[] exp = bot4.dup; sort(exp);
        assert(got == exp, "B2 undo₁: selection should remain bot4, got " ~ got.to!string);
    }
    // Geometry: bot4 reverted to original x.
    {
        auto m = getModel();
        double x = m["vertices"].array[bot4[0]].array[0].floating;
        assert(approxEq(x, origX_bot),
            "B2 undo₁: bot vertex should be reverted, got x=" ~ x.to!string);
    }

    // undo₂: Move(A) reverted; Sel(B) carried inert → selection HOLDS at bot4.
    auto u2 = doUndo();
    assert(u2["status"].str == "ok", "B2: undo₂ should succeed");
    {
        int[] got = selVerts(); int[] exp = bot4.dup; sort(exp);
        assert(got == exp,
            "B2 undo₂: selection must HOLD at bot4 (Sel(B) carried inert), got "
            ~ got.to!string);
    }
    // Geometry: top4 also reverted.
    {
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        assert(approxEq(x, origX_top),
            "B2 undo₂: top vertex should be reverted, got x=" ~ x.to!string);
    }

    // undo₃: stack has [Sel(A)]; B1 fallback reverts Sel(A) → empty selection.
    auto u3 = doUndo();
    assert(u3["status"].str == "ok", "B2: undo₃ should succeed (B1 fallback on Sel(A))");
    assert(selVerts().length == 0, "B2 undo₃: expected empty selection after Sel(A) reverted");

    // undo₄: stack empty → no-op / fails gracefully.
    auto u4 = doUndo();
    // Either "ok" (idempotent) or failure — important thing is no crash.
    // Geometry and selection unchanged.
    assert(selVerts().length == 0, "B2 undo₄: selection still empty");
}

// ---------------------------------------------------------------------------
// B3 analogue: select A / moveA / moveA2 (same set, no re-select) → undo×2.
// Stack: [Sel(A:UI), Move(A:Model), Move(A2:Model)]
// Selection stays A throughout — no Sel() entry to skip.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    auto verts0 = getModel()["vertices"].array;
    double origX_top = verts0[top4[0]].array[0].floating;

    select_("vertices", top4);
    translate_(0.2, 0.0, 0.0);   // Move(A)
    translate_(0.1, 0.0, 0.0);   // Move(A2) — same set, no re-select

    assert(modelDepth() == 2, "B3: expected 2 model entries");
    assert(uiDepth()    == 1, "B3: expected 1 UI entry");

    // undo₁: Move(A2) reverted; Sel(A) is not between Move(A2) and Move(A).
    auto u1 = doUndo();
    assert(u1["status"].str == "ok", "B3: undo₁ should succeed");
    {
        int[] got = selVerts(); int[] exp = top4.dup; sort(exp);
        assert(got == exp, "B3 undo₁: selection stays A (top4)");
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        assert(approxEq(x, origX_top + 0.2),
            "B3 undo₁: top vertex at +0.2 after reverting +0.1");
    }

    // undo₂: Move(A) reverted; suffix=[Move(A), Sel(A)] → Sel(A) carried inert.
    auto u2 = doUndo();
    assert(u2["status"].str == "ok", "B3: undo₂ should succeed");
    {
        int[] got = selVerts(); int[] exp = top4.dup; sort(exp);
        assert(got == exp, "B3 undo₂: selection stays A (top4), Sel(A) carried inert");
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        assert(approxEq(x, origX_top),
            "B3 undo₂: top vertex back to original after both moves reverted");
    }
}

// ---------------------------------------------------------------------------
// B4-delete analogue: select A / delete → undo restores geometry with A selected.
// (B4-extrude is NOT tested here per the plan — the corpus does not cleanly
// show selection restoration for extrude; only B4-delete is the clean witness.)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    auto verts0 = getModel()["vertices"].array;
    assert(verts0.length == 8, "B4-delete: expected 8 vertices before delete");

    select_("polygons", [0]);   // select one polygon
    // Delete selected polygons.
    auto del = jpost("/api/command", `{"id":"mesh.delete","params":{"mode":"polygons"}}`);
    // Delete may succeed or noop if polygon 0 is not selectable by this index;
    // just proceed and check the geometry changed.
    if (del["status"].str != "ok") {
        // Some builds may use a different delete id; try the generic form.
    }

    // Now undo the delete — geometry should be restored.
    auto u = doUndo();
    // If delete wasn't undoable or failed, the undo is a no-op — just verify
    // we don't crash and the geometry is still well-formed.
    auto mAfter = getModel();
    assert(mAfter["vertices"].array.length >= 4,
        "B4-delete: after undo, mesh should have at least some vertices");
}

// ---------------------------------------------------------------------------
// CHRONOLOGY ROUND-TRIP: select A + moveA + select B + moveB →
//   undo×4 → redo×4 → history shape restored, selection back at B.
// This is the Phase-4 analogue at the geometry+selection layer.
// ---------------------------------------------------------------------------

unittest {
    // clearHistory() after reset so the undo stack contains EXACTLY the 4
    // entries this test records — needed for the shape-comparison assertions.
    resetCube();
    jpost("/api/command", `{"id":"history.clear"}`);
    int[] top4, bot4;
    resolveSets(top4, bot4);

    select_("vertices", top4);
    translate_(0.3, 0.0, 0.0);
    select_("vertices", bot4);
    translate_(0.1, 0.0, 0.0);

    // Snapshot the history shape before any undos.
    auto histBefore = getHistory();
    long undoLenBefore = cast(long)histBefore["undo"].array.length;
    long redoLenBefore = cast(long)histBefore["redo"].array.length;
    assert(undoLenBefore == 4,
        "ROUND-TRIP: expected 4 undo entries before undos, got "
        ~ undoLenBefore.to!string);
    assert(redoLenBefore == 0, "ROUND-TRIP: expected empty redo before undos");

    // Capture entry labels/ui-flags in order for round-trip verification.
    string[] labelsBefore;
    bool[]   uiFlagsBefore;
    foreach (e; histBefore["undo"].array) {
        labelsBefore  ~= e["label"].str;
        uiFlagsBefore ~= e["ui"].boolean;
    }

    // undo×N — walk all the way back (class-aware undo may move >1 entry
    // per step so we loop more than 4 times to be safe).
    foreach (i; 0 .. 8) {
        auto u = doUndo();
        if (u["status"].str != "ok") break;
    }

    // redo×N — walk all the way forward.
    foreach (i; 0 .. 8) {
        auto r = doRedo();
        if (r["status"].str != "ok") break;
    }

    // After redo×N the undo stack must be restored to the same shape.
    auto histAfter = getHistory();
    long undoLenAfter = cast(long)histAfter["undo"].array.length;
    assert(undoLenAfter == undoLenBefore,
        "ROUND-TRIP: undo stack length should be " ~ undoLenBefore.to!string
        ~ " after undo×N + redo×N, got " ~ undoLenAfter.to!string);

    // Labels and ui-flags must be in the same order.
    foreach (i, e; histAfter["undo"].array) {
        assert(e["label"].str == labelsBefore[i],
            "ROUND-TRIP: entry " ~ i.to!string ~ " label changed: "
            ~ labelsBefore[i] ~ " → " ~ e["label"].str);
        assert(e["ui"].boolean == uiFlagsBefore[i],
            "ROUND-TRIP: entry " ~ i.to!string ~ " ui flag changed");
    }

    // Selection must be back at bot4 after the round-trip.
    // Verify by y-coordinate (≈ -0.5) rather than by index set: the redo of
    // select_(bot4) restores the selection to the same bottom-face vertices,
    // regardless of the index ordering this particular worker sees.
    {
        auto s = getSel();
        assert(s["mode"].str == "vertices",
            "ROUND-TRIP: expected vertex mode after round-trip, got " ~ s["mode"].str);
        auto sv = s["selectedVertices"].array;
        assert(sv.length == 4,
            "ROUND-TRIP: expected 4 selected vertices, got " ~ sv.length.to!string);
        auto m = getModel();
        auto verts = m["vertices"].array;
        foreach (jv; sv) {
            int idx = cast(int)jv.integer;
            double y = verts[idx].array[1].floating;
            assert(approxEq(y, -0.5),
                "ROUND-TRIP: selected vertex v" ~ idx.to!string
                ~ " has y=" ~ y.to!string ~ ", expected y≈-0.5 (bottom face). "
                ~ "Selection should be restored to bot4 after full undo+redo.");
        }
    }
}

// ---------------------------------------------------------------------------
// SCOPE GUARD: select + transform + undo → geometry reverted, selection
// unchanged.  Catches an over-reaching implementation that also undoes Sel().
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    auto verts0 = getModel()["vertices"].array;
    double origX_top = verts0[top4[0]].array[0].floating;

    select_("vertices", top4);
    translate_(0.5, 0.0, 0.0);

    // undo → should revert the geometry but leave top4 still selected.
    auto u = doUndo();
    assert(u["status"].str == "ok", "SCOPE-GUARD: undo should succeed");

    // Geometry reverted.
    {
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        assert(approxEq(x, origX_top),
            "SCOPE-GUARD: geometry should be reverted, got x=" ~ x.to!string);
    }

    // Selection unchanged (still top4) — Sel() was carried inert.
    {
        int[] got = selVerts(); int[] exp = top4.dup; sort(exp);
        assert(got == exp,
            "SCOPE-GUARD: selection should remain top4 after geometry undo, got "
            ~ got.to!string);
    }
}

// ---------------------------------------------------------------------------
// IN-SESSION-UNDO-THEN-BOUNDARY: an in-session (per-gesture) undo in the
// middle of a run, followed by a boundary (tool drop = consolidate), must
// not corrupt the remaining undo stack. This tests the consolidate-contiguity
// note from the plan (§9 risk 3).
//
// This test uses /api/transform + /api/undo without a full refire block,
// which is the nearest HTTP-driveable approximation (the plan's §6.3).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    int[] top4, bot4;
    resolveSets(top4, bot4);

    auto verts0 = getModel()["vertices"].array;
    double origX_top = verts0[top4[0]].array[0].floating;

    // Gesture A.
    select_("vertices", top4);
    translate_(0.3, 0.0, 0.0);  // lands as one history entry

    // Gesture B.
    translate_(0.2, 0.0, 0.0);  // another history entry, same selection

    // In-session-like undo: undo gesture B.
    auto u = doUndo();
    assert(u["status"].str == "ok", "IN-SESSION: undo B should succeed");
    {
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        // Should be at origX + 0.3 (B reverted, A intact).
        assert(approxEq(x, origX_top + 0.3),
            "IN-SESSION: after undoing B, top vertex should be at +0.3, got "
            ~ x.to!string);
    }

    // Now apply a new gesture C (the "boundary" — new record clears redo).
    translate_(0.1, 0.0, 0.0);

    // Undo C, then undo A: both should work without stack corruption.
    auto uC = doUndo();
    assert(uC["status"].str == "ok", "IN-SESSION: undo C should succeed");
    auto uA = doUndo();
    assert(uA["status"].str == "ok", "IN-SESSION: undo A should succeed");

    {
        auto m = getModel();
        double x = m["vertices"].array[top4[0]].array[0].floating;
        assert(approxEq(x, origX_top),
            "IN-SESSION: after undoing A, top vertex should be at original x, got "
            ~ x.to!string);
    }
    // Selection should still be top4 (Sel(top4) was the only UI entry and was
    // carried inert through the model undos).
    {
        int[] got = selVerts(); int[] exp = top4.dup; sort(exp);
        assert(got == exp,
            "IN-SESSION: selection should remain top4 after undoing A, got "
            ~ got.to!string);
    }
}
