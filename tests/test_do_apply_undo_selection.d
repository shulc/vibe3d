// Regression anchor for tasks 3693/3694: selection and lifecycle records are
// strict-LIFO steps.
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
//      Stack after: [MeshSelect(A:UiState), Arm(A:ToolLifecycle),
//                    ToolDoApply(A:Model)]
//   4. Select the BOTTOM-4 corners (y = −0.5) via /api/select.
//   5. Activate TransformMove, set TX=0.1, tool.doApply → gesture B commit.
//      Stack after: [MeshSelect(A:UiState), Arm(A:ToolLifecycle),
//                    ToolDoApply(A:Model), MeshSelect(B:UiState),
//                    Arm(B:ToolLifecycle), ToolDoApply(B:Model)]
//   6. undo₁ → ToolDoApply(B).
//      Geometry of B reverted; selection stays bottom-4.
//   7. undo₂ → Arm(B). Selection remains bottom-4 and gesture A remains.
//   8. undo₃ → MeshSelect(B).
//      Selection returns to top-4; ToolDoApply(A) remains applied.
//
// Candidate 0056 previously carried MeshSelect(B) inert and was encoded here
// as though measured. The separating capture was inert after undo₁ and did not
// establish that candidate. The live capture that now establishes strict LIFO
// used scripted `mesh.move_vertex`; this test uses the gesture door
// `tool.set`/`tool.attr`/`tool.doApply`. Whether gesture records coalesce
// differently remains unmeasured, so this is an implementation anchor, not a
// claim that the remaining gesture door has been captured.
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

    // --- undo₁: ToolDoApply(B) reverted; selection stays bottom-4 ---
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

    // --- undo₂: Arm(B) reverted; selection must remain bottom-4 ---
    auto u2 = postUndo();
    assert(u2["status"].str == "ok",
        "undo₂ should succeed, got: " ~ u2.toString);

    auto selAfterArm = getSelection();
    auto rawAfterArm = selAfterArm["selectedVertices"].array;
    int[] selectedAfterArm = rawAfterArm.map!(v => cast(int)v.integer).array;
    sort(selectedAfterArm);
    int[] bottomExpected = bot4.dup;
    sort(bottomExpected);
    int[] topExpected = top4.dup;
    sort(topExpected);
    assert(selectedAfterArm == bottomExpected,
        "STRICT LIFO: undo₂ must consume Arm(B) and leave bottom-4 selected; got "
        ~ selectedAfterArm.to!string);
    assert(selectedAfterArm != topExpected,
        "obsolete selection-only contract resurfaced: undo₂ already reverted MeshSelect(B)");

    // --- undo₃: MeshSelect(B) reverted; selection returns to top-4 ---
    auto u3 = postUndo();
    assert(u3["status"].str == "ok",
        "undo₃ should succeed, got: " ~ u3.toString);

    auto sel = getSelection();
    assert(sel["mode"].str == "vertices",
        "expected vertex selection mode after undo₃, got: " ~ sel["mode"].str);

    auto rawSel = sel["selectedVertices"].array;
    assert(rawSel.length == 4,
        "expected exactly 4 selected vertices after undo₃, got "
        ~ rawSel.length.to!string);

    int[] selectedIdx = rawSel.map!(v => cast(int)v.integer).array;
    sort(selectedIdx);

    // The selection must be the TOP-4 (y ≈ +0.5).
    auto modelFinal = getModel();
    auto vertsFinal = modelFinal["vertices"].array;

    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(approxEqual(y, 0.5),
            "STRICT LIFO: after undo₃, selected vertex v" ~ idx.to!string
            ~ " has y=" ~ y.to!string
            ~ " but expected y≈+0.5 (top face). "
            ~ "MeshSelect(B) must follow the Arm(B) undo step.");
    }

    {
        int[] expectedSorted = top4.dup;
        sort(expectedSorted);
        assert(selectedIdx == expectedSorted,
            "STRICT LIFO: selected indices " ~ selectedIdx.to!string
            ~ " do not match top-4 " ~ expectedSorted.to!string
            ~ ". undo₃ via tool.doApply skipped MeshSelect(B).");
    }

    // Cross-check: no selected vertex is on the bottom face.
    foreach (idx; selectedIdx) {
        double y = vertsFinal[idx].array[1].floating;
        assert(!approxEqual(y, -0.5),
            "REGRESSION: selected vertex v" ~ idx.to!string
            ~ " is on the bottom face (y≈-0.5) after undo₃ via tool.doApply. "
            ~ "Selection was carried inert instead of stepped.");
    }
}
