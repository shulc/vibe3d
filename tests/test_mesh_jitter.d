// Tests for mesh.jitter — random per-vertex displacement with a
// deterministic Mt19937 seed so a given (seed, scale*) pair always
// produces the same output.
//
// This is a vibe3d-original position deformer with no cross-engine
// reference. Tests focus on:
//   * determinism: same seed ⇒ same output (twice)
//   * different seed ⇒ different output
//   * scl=0 ⇒ no-op
//   * displacement bounded by scl per axis
//   * empty selection ⇒ whole mesh
//   * undo restores

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // determinism — same seed twice ⇒ identical positions
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:42");
    auto first = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:42");
    auto second = dumpVerts();
    assert(first.length == second.length);
    foreach (i; 0 .. first.length)
        foreach (c; 0 .. 3)
            assert(approxEq(first[i][c], second[i][c]),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ ": same seed gave different positions ("
                ~ first[i][c].to!string ~ " vs "
                ~ second[i][c].to!string ~ ")");
}

unittest { // different seed ⇒ different output (with overwhelming probability)
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:42");
    auto a = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:7");
    auto b = dumpVerts();
    bool anyDifferent = false;
    foreach (i; 0 .. a.length)
        foreach (c; 0 .. 3)
            if (!approxEq(a[i][c], b[i][c])) anyDifferent = true;
    assert(anyDifferent,
        "two different seeds (42 vs 7) produced identical jitter — "
        ~ "Mt19937 sequences should diverge");
}

unittest { // scl=0 on every axis ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0 rangeY:0 rangeZ:0 seed:42");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3) {
            // Cube corners stay at ±0.5 — no displacement.
            assert(approxEq(fabs(v[c]), 0.5),
                "scl=0 jitter shouldn't move verts off ±0.5, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // displacement bounded by scl per axis
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.2 rangeY:0.05 rangeZ:0.0 seed:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // X displacement bounded by 0.2 (so X ∈ [±0.5 ± 0.2] = [-0.7, +0.7]).
        assert(fabs(v[0]) <= 0.5 + 0.2 + 1e-5,
            "X out of bounds for rangeX=0.2: " ~ v[0].to!string);
        // Y displacement bounded by 0.05.
        assert(fabs(v[1]) <= 0.5 + 0.05 + 1e-5,
            "Y out of bounds for rangeY=0.05: " ~ v[1].to!string);
        // Z displacement = 0 (rangeZ=0) — Z must remain ±0.5.
        assert(approxEq(fabs(v[2]), 0.5),
            "Z should be untouched at ±0.5, got " ~ v[2].to!string);
    }
}

unittest { // selection-aware: vertex mode + 1 selected vert ⇒ only that vert moves
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[3]}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:1");
    auto verts = dumpVerts();
    int moved = 0;
    foreach (i, v; verts) {
        // Original cube corners are at ±0.5; any drift means jitter
        // touched this vert.
        bool drifted = !approxEq(fabs(v[0]), 0.5)
                    || !approxEq(fabs(v[1]), 0.5)
                    || !approxEq(fabs(v[2]), 0.5);
        if (drifted) moved++;
    }
    // Drained-roll determinism: only the selected vert (index 3) should
    // have actually been displaced, even though the RNG advances for all.
    assert(moved == 1,
        "expected exactly 1 vert displaced by selection-aware jitter, got "
        ~ moved.to!string);
}

unittest { // undo restores pre-jitter positions
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:1");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corner, got " ~ v[c].to!string);
        }
    }
}


// PR-7 of the convolve design doc — enableX/Y/Z gate per
// axis. Disabled axis keeps the stored Range but doesn't write the
// random displacement, so the user can toggle without losing values.

unittest { // enableX:false rangeX:0.5 → X coordinate UNCHANGED.
           // RNG rolls still happen (3 per vert) so Y/Z stay in sync
           // with the all-enabled baseline — verify that by comparing
           // Y/Z against the baseline.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.5 rangeY:0.5 rangeZ:0.5 seed:42 enableX:false");
    auto gated = dumpVerts();

    foreach (v; gated) {
        assert(approxEq(fabs(v[0]), 0.5),
            "enableX:false should pin X to ±0.5, got " ~ v[0].to!string);
    }

    // Y/Z displacement should match the all-enabled run.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.5 rangeY:0.5 rangeZ:0.5 seed:42");
    auto baseline = dumpVerts();
    foreach (i; 0 .. gated.length) {
        assert(approxEq(gated[i][1], baseline[i][1]),
            "Y should match baseline (RNG rolls unconditional)");
        assert(approxEq(gated[i][2], baseline[i][2]),
            "Z should match baseline (RNG rolls unconditional)");
    }
}

unittest { // enableY:false: Y pinned, X/Z follow baseline.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.5 rangeY:0.5 rangeZ:0.5 seed:42 enableY:false");
    auto gated = dumpVerts();
    foreach (v; gated)
        assert(approxEq(fabs(v[1]), 0.5),
            "enableY:false should pin Y, got " ~ v[1].to!string);
}

unittest { // enableZ:false: Z pinned.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.5 rangeY:0.5 rangeZ:0.5 seed:42 enableZ:false");
    auto gated = dumpVerts();
    foreach (v; gated)
        assert(approxEq(fabs(v[2]), 0.5),
            "enableZ:false should pin Z, got " ~ v[2].to!string);
}

unittest { // all three enables = false ⇒ no movement at all.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.5 rangeY:0.5 rangeZ:0.5 seed:42 "
        ~ "enableX:false enableY:false enableZ:false");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "all enables off should pin every coordinate");
    }
}

unittest { // explicit enableAxis:true ≡ default-omitted (regression).
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.3 rangeY:0.3 rangeZ:0.3 seed:1 "
        ~ "enableX:true enableY:true enableZ:true");
    auto explicit = dumpVerts();

    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.3 rangeY:0.3 rangeZ:0.3 seed:1");
    auto omitted = dumpVerts();

    foreach (i; 0 .. explicit.length)
        foreach (c; 0 .. 3)
            assert(approxEq(explicit[i][c], omitted[i][c]),
                "all-enableAxis:true should match default-omitted");
}

unittest {
    // Linear falloff (in-process) — top verts get full jitter, bottom
    // verts stay put. The blend math is verified here against vibe3d's
    // own baseline.
    // We compare jitter-with-weight=1-at-top against jitter-without-
    // falloff at the same seed, expecting top displacements to match
    // and bottom displacements to be zero.
    postJson("/api/reset", "");
    cmd("mesh.jitter rangeX:0.2 rangeY:0.2 rangeZ:0.2 seed:42");
    auto unweighted = dumpVerts();

    postJson("/api/reset", "");
    auto pre = dumpVerts();
    auto resp = postJson("/api/command",
        `{"id":"mesh.jitter","params":{`
        ~ `"rangeX":0.2,"rangeY":0.2,"rangeZ":0.2,"seed":42,`
        ~ `"falloff":{"type":"linear","shape":"linear",`
        ~ `"start":[0,0.5,0],"end":[0,-0.5,0]}}}`);
    assert(resp["status"].str == "ok", resp.toString());
    auto weighted = dumpVerts();

    foreach (i; 0 .. pre.length) {
        bool topY = (pre[i][1] > 0);   // weight 1 at y=+0.5
        foreach (c; 0 .. 3) {
            double expected = topY ? unweighted[i][c] : pre[i][c];
            assert(approxEq(weighted[i][c], expected),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ ": linear falloff blend wrong (" ~ weighted[i][c].to!string
                ~ " vs expected " ~ expected.to!string ~ ")");
        }
    }
}

long undoDepth() { return getJson("/api/history")["undo"].array.length; }

unittest { // no-op jitter undo must not truncate the undo stack (task 2110).
           // jitter has no identity-param short-circuit (unlike mesh.smooth's
           // iter<=0), so the only reachable route to touchedIdx.length == 0
           // with apply() still returning true is an EMPTY OPERAND: nothing
           // selected AND every vertex hidden (operandVertexMask's L1 funnel
           // falls back to visibleVertexMask(), which is all-false once the
           // whole mesh is hidden).
           //
           // Sequence: hide everything (its own UiState undo entry, unrelated
           // to the bug) → real jitter with the WHOLE mesh explicitly selected
           // (selection wins over hidden state in the Vertices-mode mask, so
           // this still moves all 8 verts even though they're hidden) → no-op
           // jitter with the selection cleared (now nothing selected AND
           // everything hidden ⇒ empty operand).
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

    // (1) Real edit — all 8 verts still explicitly selected (hidden or not),
    //     touchedIdx non-empty. Model history entry pushed on top of hide's.
    auto before = dumpVerts();
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:1");

    // (2) No-op edit — clear the selection; everything is still hidden from
    //     step (1)'s setup, so operandVertexMask's fallback is all-false.
    //     NOTE: `/api/select` itself records its own "mesh.select" UiState
    //     history entry (measured — it is NOT the bare selection-only bridge
    //     it appears to be from the route code alone), so the stack between
    //     the real edit and the no-op edit is [... real jitter, mesh.select,
    //     no-op jitter] rather than the two edits being adjacent. Strict LIFO
    //     therefore needs three presses below: no-op jitter, mesh.select, then
    //     real jitter. Each press removes one record.
    auto clearSel = postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    assert(clearSel["status"].str == "ok", clearSel.toString);
    cmd("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:2");
    auto depthBeforeUndos = undoDepth();

    // (3) Undo the no-op. With the bug (revert() returned false on empty
    //     touchedIdx) this returns {"status":"error"} and the entry is
    //     dropped without a redo counterpart; with the fix it returns
    //     {"status":"ok"} (a genuine no-op revert). Nothing was pushed after
    //     the no-op edit, so this pop is exactly one entry either way.
    auto j1 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j1["status"].str == "ok",
        "undo of no-op jitter must return ok (task 2110 stack-truncation regression): "
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

    // (5) Undo the real jitter.
    auto j3 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j3["status"].str == "ok",
        "undo of real jitter must return ok after the selection undo: "
        ~ j3.toString);
    assert(undoDepth() == depthAfterUndo2 - 1,
        "undoing the real jitter must remove exactly one record");

    // (6) Positions must be fully restored to the pre-jitter cube (mesh.hide
    //     never moves a vertex, so `before` — captured right after the hide —
    //     is exactly the state two undos must reach).
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ " not restored after two undos (task 2110 regression)");
}
