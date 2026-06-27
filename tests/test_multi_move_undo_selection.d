// Baseline-lock test for task 0056 Phase 4.
//
// This file LOCKS vibe3d's CURRENT (known-divergent) post-undo selection
// behavior so it cannot silently drift before task 0038 fixes it.
//
// --- What the sequence does ---
//
//   1. Reset to a unit cube (8 vertices at ±0.5 on each axis).
//   2. Select the TOP-4 corners (y = +0.5) via /api/select.
//   3. Translate them +0.3 in X via /api/transform  → gesture A commit
//      (lands MeshSelect(A) + ToolDoApply(A) on the unified undo stack).
//   4. Re-select the BOTTOM-4 corners (y = −0.5) via /api/select.
//   5. Translate them +0.1 in X via /api/transform  → gesture B commit
//      (lands MeshSelect(B) + ToolDoApply(B) on the unified undo stack).
//   6. undo₁  → pops ToolDoApply(B); selection = bottom-4.
//   7. undo₂  → pops MeshSelect(B).revert; vibe3d's current implementation
//      reverts the selection snapshot stored in MeshSelect(B), which was
//      "top-4 *at the time of gesture B's select*".
//
// --- What vibe3d currently yields (the LOCKED divergence) ---
//
//   After undo₂, vibe3d selects the top-4 vertices — the ones at y = +0.5
//   with x shifted by gesture A's delta (+0.3).  This is because MeshSelect
//   is a Model-class command on the unified undo stack, so undo₂ literally
//   restores the vertex-index snapshot that MeshSelect(B).before captured
//   (= the top-4 set), not the selection that was live at the time of undo₁.
//
// --- Known divergence from the reference editor ---
//
//   The reference editor yields the BOTTOM-4 set after undo₂, because its
//   separate model/UI undo timelines mean that undoing gesture B's geometry
//   does not also undo the re-select that preceded it.  Task 0038 (separate
//   model/UI undo timelines) will fix this: once that lands, undo₂ will
//   leave the bottom-4 set selected, and the expectation in this test must
//   be flipped to assert the bottom-4 corners instead.
//
// --- Root cause (for task 0038 context) ---
//
//   vibe3d pushes selection changes as Model-class commands onto the same
//   unified undo stack as geometry edits.  Undoing a geometry command with
//   Ctrl+Z pops the top entry, which may be a MeshSelect that the user did
//   not intend to undo.  Separate timelines (task 0038) make selection
//   non-model-undoable so only geometry steps appear on the model stack.

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
// The baseline-lock test
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

    // --- undo₁: pops ToolDoApply(B) → bottom-4 geometry reverts ---
    auto u1 = postUndo();
    assert(u1["status"].str == "ok",
        "undo₁ should succeed, got: " ~ u1.toString);

    // --- undo₂: pops MeshSelect(B).revert ---
    //     vibe3d's current behavior: selection reverts to the snapshot stored
    //     in MeshSelect(B).before, which is the top-4 set (the selection that
    //     was active just before gesture B's re-select).
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

    // --- Resolve which vertices are currently at y ≈ +0.5 (top face) ---
    //     After gesture A, the top corners moved in X but stayed at y = +0.5.
    //     After undo₁ (geometry undo of gesture B), the top corners are still
    //     shifted by gestureADx.  Their y coordinate is unchanged.
    auto modelFinal = getModel();
    auto vertsFinal = modelFinal["vertices"].array;

    // vibe3d's CURRENT behavior: undo₂ restores the top-4 set.
    // Verify each selected vertex is at y ≈ +0.5 (the top face).
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(approxEqual(y, 0.5),
            "CURRENT BEHAVIOR LOCK: after undo₂, selected vertex v"
            ~ idx.to!string ~ " has y=" ~ y.to!string
            ~ " but expected y≈+0.5 (top face). "
            ~ "If this fails, vibe3d's undo selection behavior changed — "
            ~ "verify whether task 0038 has landed and flip the assertion "
            ~ "to expect the bottom-face set (y≈-0.5) instead.");
    }

    // Also verify the selected set is exactly the top-4 indices (not just any
    // 4 vertices that happen to have y=+0.5 — there should be exactly 4 and
    // they should match the originally-identified top4 set).
    {
        int[] expectedSorted = top4.dup;
        sort(expectedSorted);
        assert(selectedIdx == expectedSorted,
            "CURRENT BEHAVIOR LOCK: selected indices " ~ selectedIdx.to!string
            ~ " do not match the top-4 set " ~ expectedSorted.to!string
            ~ ". vibe3d's undo₂ should restore the MeshSelect(B).before "
            ~ "snapshot = the top-4 corners at the time gesture B began. "
            ~ "If this fails, verify whether task 0038 has landed.");
    }

    // --- Cross-check: none of the selected vertices are on the bottom face ---
    //     (Documents the divergence: the reference editor would leave the
    //     bottom-4 selected here.  This assert confirms they are NOT bottom.)
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(!approxEqual(y, -0.5),
            "DIVERGENCE NOTE: selected vertex v" ~ idx.to!string
            ~ " is on the bottom face (y≈-0.5). "
            ~ "The reference editor yields this set; vibe3d currently yields "
            ~ "the top-4 set. If this assert fires, the divergence has been "
            ~ "resolved (task 0038 landed) — flip the test expectations.");
    }
}
