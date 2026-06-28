// Regression anchor for task 0038 — T-SEP class-aware undo stepping.
//
// This test LOCKS vibe3d's post-0038 post-undo selection behaviour so it
// cannot silently regress.  Prior to 0038, the test asserted the top-4
// (divergent) set; task 0038 (class-aware carried-suffix undo) brings
// vibe3d into alignment, and this test now asserts the bottom-4 set.
//
// --- What the sequence does ---
//
//   1. Reset to a unit cube (8 vertices at ±0.5 on each axis).
//   2. Select the TOP-4 corners (y = +0.5) via /api/select.
//   3. Translate them +0.3 in X via /api/transform  → gesture A commit.
//      Stack after: [MeshSelect(A:UiState), ToolDoApply(A:Model)]
//   4. Re-select the BOTTOM-4 corners (y = −0.5) via /api/select.
//   5. Translate them +0.1 in X via /api/transform  → gesture B commit.
//      Stack after: [MeshSelect(A:UiState), ToolDoApply(A:Model),
//                    MeshSelect(B:UiState), ToolDoApply(B:Model)]
//   6. undo₁ → class-aware: nearest Model from tail = ToolDoApply(B).
//      Suffix [ToolDoApply(B)] moved to redo (no trailing UI entries).
//      Geometry of B reverted; selection stays bottom-4 (MeshSelect(B) not
//      touched).
//   7. undo₂ → class-aware: nearest Model from tail = ToolDoApply(A).
//      Suffix [ToolDoApply(A), MeshSelect(B)] moved to redo as a unit.
//      MeshSelect(B) is carried inert — selection HOLDS at bottom-4.
//      Geometry of A reverted.
//
// --- What vibe3d yields after 0038 (the ALIGNED behaviour) ---
//
//   After undo₂, selection is the BOTTOM-4 vertices (y ≈ −0.5).
//   MeshSelect(B) was carried inert by the suffix move; it was never
//   revert()'d, so the live selection remains "bottom-4" throughout.
//   This matches the reference editor's T-SEP rule (B2): a geometry undo
//   never pops an interleaved selection entry.
//
// --- Revert opens the divergence ---
//
//   Reverting task 0038 (restoring class-blind LIFO undo) causes undo₂ to
//   revert MeshSelect(B), which restores the top-4 snapshot, and this test
//   will fail (the bottom-4 assertion fires).  That is the intended
//   regression gate.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.algorithm : sort, map;
import std.array : array;

void main() {}

// ---------------------------------------------------------------------------
// Helpers (same style as test_undo_redo.d)
// ---------------------------------------------------------------------------

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postTranslate(double dx, double dy, double dz) {
    import std.format : format;
    auto resp = post("http://localhost:8080/api/transform",
        format(`{"kind":"translate","delta":[%.10g,%.10g,%.10g]}`, dx, dy, dz));
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/transform failed: " ~ resp);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue getSelection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// ---------------------------------------------------------------------------
// The aligned-behaviour test (now asserts bottom-4)
// ---------------------------------------------------------------------------

unittest {
    // --- Setup ---
    resetCube();

    // Read the full vertex list once so we can resolve indices by coordinate.
    auto model0 = getModel();
    auto verts0 = model0["vertices"].array;
    assert(verts0.length == 8,
        "expected 8 vertices on a fresh cube, got " ~ verts0.length.to!string);

    // Identify the TOP-4 corners: y ≈ +0.5.
    int[] top4;
    foreach (i, v; verts0) {
        if (approxEqual(v.array[1].floating, 0.5))
            top4 ~= cast(int)i;
    }
    assert(top4.length == 4,
        "expected 4 top corners (y=+0.5), got " ~ top4.length.to!string);

    // Identify the BOTTOM-4 corners: y ≈ −0.5.
    int[] bot4;
    foreach (i, v; verts0) {
        if (approxEqual(v.array[1].floating, -0.5))
            bot4 ~= cast(int)i;
    }
    assert(bot4.length == 4,
        "expected 4 bottom corners (y=-0.5), got " ~ bot4.length.to!string);

    // --- Gesture A: select top-4, haul +0.3 X ---
    postSelect("vertices", top4);
    enum double gestureADx = 0.3;
    postTranslate(gestureADx, 0.0, 0.0);

    // Sanity: top corners should now be at x = original_x + 0.3.
    {
        auto m = getModel();
        foreach (idx; top4) {
            double origX = verts0[idx].array[0].floating;
            double newX  = m["vertices"].array[idx].array[0].floating;
            assert(approxEqual(newX, origX + gestureADx),
                "gesture A: top corner v" ~ idx.to!string
                ~ " not shifted: expected x≈" ~ (origX + gestureADx).to!string
                ~ ", got " ~ newX.to!string);
        }
    }

    // --- Gesture B: re-select bottom-4, haul +0.1 X ---
    postSelect("vertices", bot4);
    enum double gestureBDx = 0.1;
    postTranslate(gestureBDx, 0.0, 0.0);

    // --- undo₁: class-aware step → ToolDoApply(B) reverted ---
    //     MeshSelect(B) has no trailing UI entries; suffix = [ToolDoApply(B)].
    auto u1 = postUndo();
    assert(u1["status"].str == "ok",
        "undo₁ should succeed, got: " ~ u1.toString);

    // Bottom-4 geometry reverted; selection unchanged (still bottom-4).
    {
        auto s = getSelection();
        assert(s["mode"].str == "vertices", "expected vertices mode after undo₁");
        auto sv = s["selectedVertices"].array;
        assert(sv.length == 4, "expected 4 selected after undo₁");
        int[] got = sv.map!(v => cast(int)v.integer).array;
        sort(got);
        int[] exp = bot4.dup; sort(exp);
        assert(got == exp,
            "after undo₁ selection should still be bottom-4, got " ~ got.to!string);
    }

    // --- undo₂: class-aware step → ToolDoApply(A) reverted ---
    //     Suffix = [ToolDoApply(A), MeshSelect(B)].
    //     MeshSelect(B) carried inert → selection HOLDS at bottom-4.
    auto u2 = postUndo();
    assert(u2["status"].str == "ok",
        "undo₂ should succeed, got: " ~ u2.toString);

    // --- Read the resulting selection ---
    auto sel = getSelection();
    assert(sel["mode"].str == "vertices",
        "expected vertex selection mode after undo₂, got: " ~ sel["mode"].str);

    auto rawSel = sel["selectedVertices"].array;
    assert(rawSel.length == 4,
        "expected exactly 4 selected vertices after undo₂, got "
        ~ rawSel.length.to!string);

    // Convert to a sorted int[] for coordinate-based assertions.
    int[] selectedIdx = rawSel.map!(v => cast(int)v.integer).array;
    sort(selectedIdx);

    // After undo₂ the selection must be the BOTTOM-4 (y ≈ −0.5).
    // MeshSelect(B) was carried inert by the suffix move; it was never
    // revert()'d, so the live selection is still "bottom-4" (set by
    // MeshSelect(B).apply() and never touched by either undo).
    auto modelFinal = getModel();
    auto vertsFinal = modelFinal["vertices"].array;

    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(approxEqual(y, -0.5),
            "ALIGNED BEHAVIOUR: after undo₂, selected vertex v"
            ~ idx.to!string ~ " has y=" ~ y.to!string
            ~ " but expected y≈-0.5 (bottom face). "
            ~ "If this fails, the class-aware carried-suffix undo has regressed "
            ~ "(task 0038). The reference rule T-SEP requires that geometry undo "
            ~ "never pops an interleaved selection entry.");
    }

    // Verify the selected set is exactly the bottom-4 indices.
    {
        int[] expectedSorted = bot4.dup;
        sort(expectedSorted);
        assert(selectedIdx == expectedSorted,
            "ALIGNED BEHAVIOUR: selected indices " ~ selectedIdx.to!string
            ~ " do not match the bottom-4 set " ~ expectedSorted.to!string
            ~ ". undo₂ should leave MeshSelect(B) inert (carried suffix), "
            ~ "so the bottom-4 set stays selected throughout both geometry undos.");
    }

    // Cross-check: none of the selected vertices are on the top face.
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(!approxEqual(y, 0.5),
            "REGRESSION: selected vertex v" ~ idx.to!string
            ~ " is on the top face (y≈+0.5). "
            ~ "Task 0038 class-aware undo regressed — undo₂ is incorrectly "
            ~ "reverting MeshSelect(B) (the class-blind LIFO bug).");
    }
}
