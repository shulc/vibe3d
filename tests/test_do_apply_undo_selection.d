// Regression anchor for task 0038 — gap B: ToolDoApplyCommand.revert()
// must NOT restore the pre-move selection under T-SEP class-aware stepping.
//
// This test covers the `tool.set` / `tool.attr` / `tool.doApply` path — a
// DIFFERENT code route than `/api/transform` (which goes through
// MeshTransform, a selection-free revert). The existing test
// `test_multi_move_undo_selection.d` uses `/api/transform` and therefore
// missed the bug in `ToolDoApplyCommand.revert()`.
//
// --- What the sequence does ---
//
//   1. Reset to a unit cube (8 vertices at ±0.5 on each axis).
//   2. Select the TOP-4 corners (y = +0.5) via /api/select.
//   3. Activate TransformMove, set TX=0.3, tool.doApply → gesture A commit.
//      Stack after: [MeshSelect(A:UiState), ToolDoApply(A:Model)]
//   4. Select the BOTTOM-4 corners (y = −0.5) via /api/select.
//   5. Activate TransformMove, set TX=0.1, tool.doApply → gesture B commit.
//      Stack after: [MeshSelect(A:UiState), ToolDoApply(A:Model),
//                    MeshSelect(B:UiState), ToolDoApply(B:Model)]
//   6. undo₁ → T-SEP: nearest Model from tail = ToolDoApply(B).
//      Geometry of B reverted; selection stays bottom-4.
//   7. undo₂ → T-SEP: nearest Model from tail = ToolDoApply(A).
//      Suffix [ToolDoApply(A), MeshSelect(B)] moved to redo as a unit.
//      MeshSelect(B) carried inert — selection HOLDS at bottom-4.
//      ToolDoApply(A).revert() must call restoreGeometryKeepSelection(),
//      NOT restore(), so the live bottom-4 selection survives.
//
// --- What this test asserts ---
//
//   After undo₂, the selected vertices are the BOTTOM-4 (y ≈ −0.5).
//
// --- What broke before the fix ---
//
//   ToolDoApplyCommand.revert() called MeshSnapshot.restore() which
//   overwrites ALL marks including selection, reinstating the pre-A
//   snapshot's selection = top-4. The bottom-4 assertion fires, catching
//   the regression.
//
// --- What topology-changing tools see ---
//
//   edge.extrude / edge.extend go through the same ToolDoApplyCommand path
//   but add vertices, so restoreGeometryKeepSelection() falls back to the
//   snapshot marks (topology-safety rule). The tool.doApply route for those
//   tools (and thus the count-change fallback branch) is covered by
//   test_edge_extrude_tool.d / test_edge_extend_tool.d.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.algorithm : sort, map;
import std.array : array;
import std.format : format;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    auto resp = postJson("/api/reset", "");
    assert(resp["status"].str == "ok", "/api/reset failed: " ~ resp.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(resp["status"].str == "ok", "/api/select failed: " ~ resp.toString);
}

void cmd(string argstring) {
    auto resp = postJson("/api/command", argstring);
    assert(resp["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ resp.toString);
}

JSONValue postUndo() {
    return postJson("/api/undo", "");
}

JSONValue getSelection() {
    return getJson("/api/selection");
}

JSONValue getModel() {
    return getJson("/api/model");
}

// ---------------------------------------------------------------------------
// The tool.doApply-path anchor test
// ---------------------------------------------------------------------------

unittest {
    // --- Setup ---
    resetCube();

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

    // --- Gesture A: select top-4, tool.doApply +0.3 X ---
    // This is the critical difference from test_multi_move_undo_selection:
    // we go through tool.set / tool.attr / tool.doApply instead of
    // /api/transform, exercising ToolDoApplyCommand.revert().
    postSelect("vertices", top4);
    cmd("tool.set move on");
    cmd("tool.attr move TX 0.3");
    cmd("tool.attr move TY 0.0");
    cmd("tool.attr move TZ 0.0");
    cmd("tool.doApply");

    // Sanity: top corners shifted by +0.3 in X.
    {
        auto m = getModel();
        foreach (idx; top4) {
            double origX = verts0[idx].array[0].floating;
            double newX  = m["vertices"].array[idx].array[0].floating;
            assert(approxEqual(newX, origX + 0.3),
                "gesture A: top corner v" ~ idx.to!string
                ~ " not shifted: expected x≈" ~ (origX + 0.3).to!string
                ~ ", got " ~ newX.to!string);
        }
    }

    // --- Gesture B: re-select bottom-4, tool.doApply +0.1 X ---
    postSelect("vertices", bot4);
    cmd("tool.set move on");
    cmd("tool.attr move TX 0.1");
    cmd("tool.attr move TY 0.0");
    cmd("tool.attr move TZ 0.0");
    cmd("tool.doApply");

    // --- undo₁: T-SEP → ToolDoApply(B) reverted; selection stays bottom-4 ---
    auto u1 = postUndo();
    assert(u1["status"].str == "ok",
        "undo₁ should succeed, got: " ~ u1.toString);

    {
        auto s = getSelection();
        assert(s["mode"].str == "vertices",
            "expected vertices mode after undo₁, got: " ~ s["mode"].str);
        auto sv = s["selectedVertices"].array;
        assert(sv.length == 4,
            "expected 4 selected after undo₁, got " ~ sv.length.to!string);
        int[] got = sv.map!(v => cast(int)v.integer).array;
        sort(got);
        int[] exp = bot4.dup;
        sort(exp);
        assert(got == exp,
            "after undo₁ selection should still be bottom-4 "
            ~ exp.to!string ~ ", got " ~ got.to!string);
    }

    // --- undo₂: T-SEP → ToolDoApply(A) reverted; selection MUST stay bottom-4 ---
    //
    // Before the fix: ToolDoApplyCommand.revert() called MeshSnapshot.restore()
    // which reinstated the pre-A snapshot's selection = top-4.
    // After the fix:  restoreGeometryKeepSelection() keeps the live bottom-4.
    auto u2 = postUndo();
    assert(u2["status"].str == "ok",
        "undo₂ should succeed, got: " ~ u2.toString);

    auto sel = getSelection();
    assert(sel["mode"].str == "vertices",
        "expected vertex selection mode after undo₂, got: " ~ sel["mode"].str);

    auto rawSel = sel["selectedVertices"].array;
    assert(rawSel.length == 4,
        "expected exactly 4 selected vertices after undo₂, got "
        ~ rawSel.length.to!string);

    int[] selectedIdx = rawSel.map!(v => cast(int)v.integer).array;
    sort(selectedIdx);

    // The selection must be the BOTTOM-4 (y ≈ −0.5).
    // Under T-SEP, ToolDoApply(A).revert() must preserve the live selection
    // (bottom-4 set by MeshSelect(B)) — NOT restore the pre-A snapshot marks.
    auto modelFinal = getModel();
    auto vertsFinal = modelFinal["vertices"].array;

    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(approxEqual(y, -0.5),
            "ALIGNED: after undo₂, selected vertex v" ~ idx.to!string
            ~ " has y=" ~ y.to!string
            ~ " but expected y≈-0.5 (bottom face). "
            ~ "ToolDoApplyCommand.revert() restored the pre-move selection "
            ~ "(task 0038 gap B). Fix: use restoreGeometryKeepSelection().");
    }

    {
        int[] expectedSorted = bot4.dup;
        sort(expectedSorted);
        assert(selectedIdx == expectedSorted,
            "ALIGNED: selected indices " ~ selectedIdx.to!string
            ~ " do not match bottom-4 " ~ expectedSorted.to!string
            ~ ". undo₂ via tool.doApply path incorrectly restored pre-A selection.");
    }

    // Cross-check: no selected vertex is on the top face.
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(!approxEqual(y, 0.5),
            "REGRESSION: selected vertex v" ~ idx.to!string
            ~ " is on the top face (y≈+0.5) after undo₂ via tool.doApply. "
            ~ "ToolDoApplyCommand.revert() is wrongly restoring snapshot marks.");
    }
}
