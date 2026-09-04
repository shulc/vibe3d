// Regression anchor for task 3693 — strict-LIFO selection stepping.
//
// Task 0038 encoded candidate 0056's carried-suffix rule here. The later
// discriminating capture showed that selection records are their own LIFO
// steps, so this anchor now asserts the top-4 restored by undoing Select(B).
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
//   6. undo₁ → ToolDoApply(B).
//      Geometry of B reverted; selection stays bottom-4 (MeshSelect(B) not
//      touched).
//   7. undo₂ → MeshSelect(B).
//      Selection returns to top-4; geometry of A remains applied.
//
// The captures that establish this law use scripted `mesh.move_vertex` and the
// armed `tool.set`/`tool.attr`/`tool.doApply` door. This test's specific
// `/api/transform` input is still unmeasured; it pins our strict-LIFO
// implementation without projecting either measured door onto this one.
//
// Restoring candidate 0056's carried-suffix skip leaves bottom-4 selected and
// makes the top-4 assertion below fail.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
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
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
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
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postTranslate(double dx, double dy, double dz) {
    import std.format : format;
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("mesh.transform", format(`{"kind":"translate","delta":[%.10g,%.10g,%.10g]}`, dx, dy, dz)));
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/transform failed: " ~ resp);
}

JSONValue postUndo() {
    return parseJSON(post(testBaseUrl() ~ "/api/undo", ""));
}

JSONValue getSelection() {
    return parseJSON(get(testBaseUrl() ~ "/api/selection"));
}

JSONValue getModel() {
    return parseJSON(get(testBaseUrl() ~ "/api/model"));
}

// ---------------------------------------------------------------------------
// Strict-LIFO selection anchor
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

    // --- undo₁: ToolDoApply(B) reverted ---
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

    // --- undo₂: MeshSelect(B) reverted; selection returns to top-4 ---
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

    // After undo₂ the selection must be the TOP-4 (y ≈ +0.5).
    auto modelFinal = getModel();
    auto vertsFinal = modelFinal["vertices"].array;

    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(approxEqual(y, 0.5),
            "STRICT LIFO: after undo₂, selected vertex v"
            ~ idx.to!string ~ " has y=" ~ y.to!string
            ~ " but expected y≈+0.5 (top face). "
            ~ "MeshSelect(B) must be its own second undo step (task 3693).");
    }

    // Verify the selected set is exactly the top-4 indices.
    {
        int[] expectedSorted = top4.dup;
        sort(expectedSorted);
        assert(selectedIdx == expectedSorted,
            "STRICT LIFO: selected indices " ~ selectedIdx.to!string
            ~ " do not match the top-4 set " ~ expectedSorted.to!string
            ~ ". undo₂ must revert MeshSelect(B).");
    }

    // Cross-check: none of the selected vertices are on the bottom face.
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(!approxEqual(y, -0.5),
            "REGRESSION: selected vertex v" ~ idx.to!string
            ~ " is on the bottom face (y≈-0.5). "
            ~ "undo₂ skipped MeshSelect(B) instead of stepping it.");
    }
}
