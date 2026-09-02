// Tests for mesh.quantize — snaps every selected vertex to a grid step.
//
// Behaviour pinned by these tests:
//   * step=0.5 on a unit cube ⇒ no-op (corners already on the grid).
//   * step=0.3 on a unit cube ⇒ each ±0.5 corner snaps to the nearest
//     0.3 multiple, which is ±0.6 (round-half-away-from-zero).
//   * Empty selection ⇒ whole mesh quantized.
//   * Polygon-mode + selection ⇒ only verts of selected faces touched.
//   * Undo restores the original positions exactly.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // step=0.5: cube corners already on grid → unchanged
    postJson("/api/reset", "");
    cmd("mesh.quantize X:0.5 Y:0.5 Z:0.5");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        // Every component should still be ±0.5.
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.5),
                "step=0.5 quantize moved a corner: " ~ a[c].floating.to!string);
        }
    }
}

unittest { // step=0.3: ±0.5 → ±0.6 (round-half-away-from-zero, then ×0.3)
    postJson("/api/reset", "");
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            // 0.5 / 0.3 ≈ 1.67 → floor(1.67 + 0.5) = 2 → 2 * 0.3 = 0.6.
            // -0.5 / 0.3 ≈ -1.67 → floor(-1.67 + 0.5) = -2 → -2 * 0.3 = -0.6.
            // The one tricky case: +0.5 sits exactly on the *.5 boundary
            // before scaling, so it always goes UP via floor(x + 0.5).
            double v_ = a[c].floating;
            assert(approxEq(fabs(v_), 0.6, 1e-4),
                "expected ±0.6 after step=0.3 quantize, got " ~ v_.to!string);
        }
    }
}

unittest { // step=0.4: 0.5 → 0.4 (nearest 0.4 multiple is 0.4 vs 0.8 → 0.4 closer)
    // 0.5 / 0.4 = 1.25 → floor(1.25 + 0.5) = 1 → 1 * 0.4 = 0.4. Yes.
    postJson("/api/reset", "");
    cmd("mesh.quantize X:0.4 Y:0.4 Z:0.4");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            double v_ = a[c].floating;
            assert(approxEq(fabs(v_), 0.4, 1e-4),
                "expected ±0.4 after step=0.4 quantize, got " ~ v_.to!string);
        }
    }
}

unittest { // empty selection ⇒ whole mesh quantized
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    // No selectedFaces — the command should still touch every vert.
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.6, 1e-4),
                "empty-selection quantize should still touch every vert");
        }
    }
}

unittest { // selection-aware in vertices mode: only selected verts move
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    // Select vert 0 only — that's at (-0.5, -0.5, -0.5).
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(sel["status"].str == "ok", sel.toString);
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    // Vert 0: ±0.5 → ±0.6 (-0.6 for negative components).
    auto v0 = verts[0].array;
    assert(approxEq(v0[0].floating, -0.6, 1e-4),
        "vert 0.x expected -0.6, got " ~ v0[0].floating.to!string);
    assert(approxEq(v0[1].floating, -0.6, 1e-4));
    assert(approxEq(v0[2].floating, -0.6, 1e-4));
    // Vert 1 (= +0.5, -0.5, -0.5) should be untouched.
    auto v1 = verts[1].array;
    assert(approxEq(v1[0].floating,  0.5, 1e-4),
        "vert 1.x should be untouched at +0.5, got " ~ v1[0].floating.to!string);
    assert(approxEq(v1[1].floating, -0.5, 1e-4));
    assert(approxEq(v1[2].floating, -0.5, 1e-4));
}

unittest { // undo restores pre-quantize positions
    postJson("/api/reset", "");
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");
    cmd("history.undo");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.5),
                "undo should restore ±0.5 corners");
        }
    }
}


unittest { // PR-2 of the convolve design doc: per-axis
           // anisotropic step. X stays on a 0.5 grid (already-on),
           // Y snaps to 0.3 (±0.5 → ±0.6), Z stays on 0.5.
    postJson("/api/reset", "");
    cmd("mesh.quantize X:0.5 Y:0.3 Z:0.5");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        assert(approxEq(fabs(a[0].floating), 0.5),
            "X should stay at ±0.5 under X:0.5: " ~ a[0].floating.to!string);
        assert(approxEq(fabs(a[1].floating), 0.6),
            "Y should snap ±0.5 → ±0.6 under Y:0.3: " ~ a[1].floating.to!string);
        assert(approxEq(fabs(a[2].floating), 0.5),
            "Z should stay at ±0.5 under Z:0.5: " ~ a[2].floating.to!string);
    }
}

unittest {
    // Linear falloff blend — top corners snap to the 0.3 grid (weight
    // 1), bottom corners stay at ±0.5 (weight 0).
    postJson("/api/reset", "");
    auto resp = postJson("/api/command",
        `{"id":"mesh.quantize","params":{"X":0.3,"Y":0.3,"Z":0.3,`
        ~ `"falloff":{"type":"linear","shape":"linear",`
        ~ `"start":[0,0.5,0],"end":[0,-0.5,0]}}}`);
    assert(resp["status"].str == "ok", resp.toString());
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        double x = a[0].floating, y = a[1].floating, z = a[2].floating;
        if (y > 0) {
            // top → snapped: ±0.5 round to nearest 0.3 multiple = ±0.6
            assert(approxEq(fabs(x), 0.6),
                "top X expected ±0.6, got " ~ x.to!string);
            assert(approxEq(y, 0.6),
                "top Y expected +0.6, got " ~ y.to!string);
            assert(approxEq(fabs(z), 0.6),
                "top Z expected ±0.6, got " ~ z.to!string);
        } else {
            // bottom → weight 0, stays at original ±0.5
            assert(approxEq(fabs(x), 0.5));
            assert(approxEq(y, -0.5));
            assert(approxEq(fabs(z), 0.5));
        }
    }
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

long undoDepth() { return getJson("/api/history")["undo"].array.length; }

unittest { // no-op quantize undo must not truncate the undo stack (task 2110).
           // Same shape as mesh.jitter's regression: quantize has no
           // identity-param short-circuit either (a step<=0 makes apply()
           // return FALSE, not a true-with-empty-touchedIdx no-op), so the
           // only reachable route is the EMPTY OPERAND — nothing selected AND
           // every vertex hidden.
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto selAll = postJson("/api/select",
        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selAll["status"].str == "ok", selAll.toString);
    // `CommandHistory` caps the undo stack at `maxDepth = 50`
    // (command_history.d:243) and evicts the OLDEST entry on every push once
    // full. This worker's `--test` instance is shared across its whole slice
    // of test files, so by the time this block runs the stack is already
    // saturated — PUSHING an entry (mesh.hide, a real edit, a no-op edit)
    // leaves `undoDepth()` unchanged (one evicted, one added), so a push
    // cannot be asserted by count. POPPING (undo) never evicts, so the
    // pop-count deltas below ARE reliable.
    cmd("mesh.hide");   // all 8 verts selected ⇒ hides every face

    // (1) Real edit — all 8 verts still explicitly selected (hidden or not,
    //     selection wins over hidden state in the Vertices-mode mask),
    //     touchedIdx non-empty.
    auto before = dumpVerts();
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");

    // (2) No-op edit — clear the selection; everything is still hidden, so
    //     operandVertexMask's fallback (visibleVertexMask) is all-false.
    //     NOTE: `/api/select` itself records its own "mesh.select" UiState
    //     history entry (measured — see the twin comment in
    //     test_mesh_jitter.d), so the stack between the real edit and the
    //     no-op edit is [... real quantize, mesh.select, no-op quantize].
    //     Strict LIFO therefore needs three presses below: no-op quantize,
    //     mesh.select, then real quantize. Each press removes one record.
    auto clearSel = postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    assert(clearSel["status"].str == "ok", clearSel.toString);
    cmd("mesh.quantize X:0.3 Y:0.3 Z:0.3");
    auto depthBeforeUndos = undoDepth();

    // (3) Undo the no-op. With the bug this returns {"status":"error"} and
    //     the entry is dropped without a redo counterpart; with the fix it
    //     returns {"status":"ok"} (a genuine no-op revert). Nothing was
    //     pushed after the no-op edit, so this pop is exactly one entry
    //     either way.
    auto j1 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j1["status"].str == "ok",
        "undo of no-op quantize must return ok (task 2110 stack-truncation regression): "
        ~ j1.toString);
    auto depthAfterUndo1 = undoDepth();
    assert(depthAfterUndo1 == depthBeforeUndos - 1,
        "undoing the no-op entry must remove exactly one entry from the "
        ~ "stack — a bulk suffix loss would drop more than one even when "
        ~ "the call above reports ok");

    // (4) Undo the intervening mesh.select entry.
    auto j2 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j2["status"].str == "ok",
        "undo of mesh.select must return ok after the no-op undo: "
        ~ j2.toString);
    auto depthAfterUndo2 = undoDepth();
    assert(depthAfterUndo2 == depthAfterUndo1 - 1,
        "undoing mesh.select must remove exactly one record");

    // (5) Undo the real quantize.
    auto j3 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j3["status"].str == "ok",
        "undo of real quantize must return ok after the selection undo: "
        ~ j3.toString);
    assert(undoDepth() == depthAfterUndo2 - 1,
        "undoing the real quantize must remove exactly one record");

    // (6) Positions must be fully restored (mesh.hide never moves a vertex,
    //     so `before` — captured right after the hide — is exactly the
    //     state two undos must reach).
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ " not restored after two undos (task 2110 regression)");
}
