// Tests for mesh.smooth through the command route. The law itself is pinned
// cell by cell against the capture in
// tests/unit/commands/mesh/smooth_kernel_parity_test.d
// (tests/fixtures/smooth_kernel.json, task 9484); these cells check the wiring:
//   * strn=0 / iter=0 ⇒ no-op;
//   * a regular cube is a FIXED POINT of the relax law (every vertex's own
//     force is cancelled by its neighbours' reactions);
//   * one selected vertex moves by its own force only (the reactions onto the
//     fixed neighbours are dropped): v0 → -0.5 + strn/30 per axis;
//   * the locks, the sharp threshold in degrees, preserve and the falloff;
//   * undo restores.
// Cells that need motion use the cube with one corner moved (`perturbed()`).

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;

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

/// The default cube with corner 6 moved off the regular lattice.
void perturbed() {
    postJson("/api/command", commandBody("scene.reset"));
    cmd("mesh.move_vertex from:{0.5,0.5,0.5} to:{1.25,0.5,0.2}");
}

bool anyMovedFrom(const double[3][] before, const double[3][] after) {
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            if (!approxEq(before[i][c], after[i][c], 1e-4)) return true;
    return false;
}

unittest { // strn=0 ⇒ no-op
    postJson("/api/command", commandBody("scene.reset"));
    cmd("mesh.smooth strn:0 iter:5");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "strn=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // iter=0 ⇒ no-op
    postJson("/api/command", commandBody("scene.reset"));
    cmd("mesh.smooth strn:1 iter:0");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "iter=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // a regular cube is a fixed point of the relax law — one and many
           // iterations (the old Laplacian moved every corner to |c| = 1/6)
    foreach (line; ["mesh.smooth strn:1 iter:1", "mesh.smooth strn:1 iter:100"]) {
        postJson("/api/command", commandBody("scene.reset"));
        cmd(line);
        foreach (v; dumpVerts())
            foreach (c; 0 .. 3)
                assert(approxEq(fabs(v[c]), 0.5),
                    "`" ~ line ~ "`: a regular cube must stay put, got "
                    ~ v[c].to!string);
    }
}

unittest { // selection-aware: vertex mode + 1 selected vert ⇒ only it moves, by
           // its own force (F = strn/20; own force = (2/3)F per axis inward)
    foreach (strn; [1.0, 0.5]) {
        postJson("/api/command", commandBody("scene.reset"));
        cmd("select.typeFrom vertex");
        auto sel = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
        assert(sel["status"].str == "ok");
        cmd("mesh.smooth strn:" ~ strn.to!string ~ " iter:1");
        auto verts = dumpVerts();
        const want = -0.5 + strn / 30.0;
        foreach (c; 0 .. 3)
            assert(approxEq(verts[0][c], want, 1e-6),
                "strn " ~ strn.to!string ~ ": vert 0 should move to "
                ~ want.to!string ~ ", got " ~ verts[0][c].to!string);
        // Vert 1 = (+0.5, -0.5, -0.5), unselected → stays (no reaction).
        assert(approxEq(verts[1][0],  0.5, 1e-6),
            "vert 1 should stay at +0.5, got " ~ verts[1][0].to!string);
        assert(approxEq(verts[1][1], -0.5, 1e-6));
        assert(approxEq(verts[1][2], -0.5, 1e-6));
    }
}

unittest { // undo restores
    perturbed();
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:3");
    assert(anyMovedFrom(before, dumpVerts()), "control: the smooth must move");
    cmd("history.undo");
    assert(!anyMovedFrom(before, dumpVerts()), "undo should restore the mesh");
}


// PR-3 of the convolve design doc — lockBound freezes verts
// on boundary edges (edges shared by only one face). Setup deletes
// the top face of a cube to create a 4-vert boundary; without
// lockBound the smoothing pulls those verts toward the cube centre,
// with lockBound they stay pinned at ±0.5.

unittest { // lockBound:false ⇒ boundary verts move (regression check)
    postJson("/api/command", commandBody("scene.reset"));
    // Select + delete top face (f4 in cube order).
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    // Now the 4 top verts (originally v2,v3,v6,v7 = corners at y=+0.5)
    // sit on the open seam. Smooth aggressively.
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:5 lockBound:false");
    auto verts = dumpVerts();
    bool anyMoved = false;
    foreach (v; verts) {
        if (!approxEq(fabs(v[0]), 0.5)
         || !approxEq(fabs(v[1]), 0.5)
         || !approxEq(fabs(v[2]), 0.5)) {
            anyMoved = true; break;
        }
    }
    assert(anyMoved,
        "lockBound=false: at least one vert should have moved off ±0.5");
}

unittest { // lockBound:true ⇒ boundary verts STAY put under heavy smoothing
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    // Capture boundary positions: every vert at y=+0.5 sits on the
    // open seam after deleting the top face.
    auto before = dumpVerts();
    double[3][] boundaryBefore;
    foreach (v; before) {
        if (approxEq(v[1], 0.5))
            boundaryBefore ~= v;
    }
    assert(boundaryBefore.length == 4,
        "setup: expected 4 boundary verts at y=+0.5, got "
        ~ boundaryBefore.length.to!string);

    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:10 lockBound:true");

    auto after = dumpVerts();
    double[3][] boundaryAfter;
    foreach (v; after) {
        if (approxEq(v[1], 0.5))
            boundaryAfter ~= v;
    }
    assert(boundaryAfter.length == 4,
        "lockBound: 4 boundary verts should remain at y=+0.5, got "
        ~ boundaryAfter.length.to!string);
    // Boundary verts should EXACTLY match their pre-smooth positions
    // (lockBound drops them from vmask → smoothing never reads
    // them via `cur[vi].x = ...`). Compare each pre-smooth boundary
    // vert against the corresponding post-smooth one — set-equality
    // by position match.
    foreach (b; boundaryBefore) {
        bool found = false;
        foreach (a; boundaryAfter)
            if (approxEq(b[0], a[0]) && approxEq(b[1], a[1]) && approxEq(b[2], a[2])) {
                found = true; break;
            }
        assert(found,
            "lockBound: boundary vert at ("
            ~ b[0].to!string ~ "," ~ b[1].to!string ~ "," ~ b[2].to!string
            ~ ") should be unchanged after smooth");
    }
}

unittest { // lockBound on a CLOSED mesh (no boundary) is a no-op
           // — smoothing identical with lockBound on/off.
    perturbed();
    auto before = dumpVerts();
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:0.5 iter:2 lockBound:false");
    auto noLock = dumpVerts();
    assert(anyMovedFrom(before, noLock), "control: the closed mesh must move");

    perturbed();
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:0.5 iter:2 lockBound:true");
    auto withLock = dumpVerts();

    assert(noLock.length == withLock.length);
    foreach (i; 0 .. noLock.length)
        foreach (c; 0 .. 3)
            assert(approxEq(noLock[i][c], withLock[i][c]),
                "closed mesh: lockBound on/off should be identical");
}


// lockCorner freezes the vertices used by exactly ONE polygon (K-F3s,
// cell F3S_LOCKC), not the full boundary loop. A subset of lockBound.

unittest { // cube-minus-top: every top corner is used by two polygons,
           // so lockCorner locks NOTHING and the verts must move.
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:5 lockCorner:true");
    auto verts = dumpVerts();
    bool topMoved = false;
    foreach (v; verts) {
        if (approxEq(v[1], 0.5) && approxEq(fabs(v[0]), 0.5)
                                && approxEq(fabs(v[2]), 0.5)) {
            // still at original ±0.5 — didn't move
        } else if (approxEq(v[1], 0.5)) {
            // moved within the y=0.5 plane (still boundary-ish) — count it
            topMoved = true;
        } else {
            // any other y position counts as moved
            topMoved = true;
        }
    }
    assert(topMoved,
        "cube-minus-top: lockCorner alone should not pin valence-3 verts");
}

unittest { // single quad (cube minus 5 faces, one corner moved so it is
           // not a fixed point): every vertex is used by that one
           // polygon. lockCorner pins ALL of them → smooth is a no-op.
    postJson("/api/command", commandBody("scene.reset"));
    // Keep f0 (back face), delete f1..f5.
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[1,2,3,4,5]}`));
    cmd("mesh.delete");
    cmd("mesh.move_vertex from:{0.5,0.5,-0.5} to:{0.9,0.7,-0.5}");
    auto before = dumpVerts();
    assert(before.length == 4,
        "setup: single quad should have 4 verts, got " ~ before.length.to!string);

    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:10");
    assert(anyMovedFrom(before, dumpVerts()), "control: the unlocked quad must move");
    cmd("history.undo");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:10 lockCorner:true");
    auto after = dumpVerts();

    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "single quad: every vertex is used by one polygon, lockCorner "
                ~ "should freeze every vert; v[" ~ i.to!string
                ~ "][" ~ c.to!string ~ "] before=" ~ before[i][c].to!string
                ~ " after=" ~ after[i][c].to!string);
}

unittest { // lockBound + lockCorner together is equivalent to lockBound
           // alone — corner is a subset. Verify on cube-minus-top.
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:5 lockBound:true lockCorner:true");
    auto both = dumpVerts();

    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:1 iter:5 lockBound:true");
    auto boundOnly = dumpVerts();

    assert(both.length == boundOnly.length);
    foreach (i; 0 .. both.length)
        foreach (c; 0 .. 3)
            assert(approxEq(both[i][c], boundOnly[i][c]),
                "lockBound+lockCorner should match lockBound alone "
                ~ "(corner is a subset)");
}


// lockSharp pins both ends of an interior edge whose face normals dot below
// cos(sharpThreshold), the threshold in DEGREES (K-F3s, cell F3S_LOCKS). The
// perturbed cube's face-normal deviations are 43°, 73°, 90° (x8), 107°, 134°:
// every vertex has an edge above 60°; above 115° there is one edge.

unittest { // sharpThreshold 60 → every edge is sharp → all verts pinned
           // (60 read as radians would lock nothing: cos 60 rad = -0.95)
    perturbed();
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpThreshold:60");
    auto after = dumpVerts();
    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "lockSharp 60°: every vertex has an edge above 60°, all verts "
                ~ "should be pinned (no-op); v[" ~ i.to!string ~ "][" ~ c.to!string ~ "] "
                ~ "before=" ~ before[i][c].to!string
                ~ " after="  ~ after[i][c].to!string);
}

unittest { // sharpThreshold 115 (degrees, not radians) → only the 134° edge
           // passes → its two ends lock, the rest of the mesh smooths
    perturbed();
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpThreshold:115");
    assert(anyMovedFrom(before, dumpVerts()),
        "lockSharp 115°: only one edge passes the threshold, the mesh should move");
}

unittest { // lockSharp:false ⇔ default smooth: regression — no
           // difference between explicit lockSharp:false and the
           // default omitted parameter.
    perturbed();
    auto before = dumpVerts();
    cmd("mesh.smooth strn:0.5 iter:2 lockSharp:false");
    auto explicit = dumpVerts();
    assert(anyMovedFrom(before, explicit), "control: the smooth must move");
    perturbed();
    cmd("mesh.smooth strn:0.5 iter:2");
    auto omitted = dumpVerts();
    assert(explicit.length == omitted.length);
    foreach (i; 0 .. explicit.length)
        foreach (c; 0 .. 3)
            assert(approxEq(explicit[i][c], omitted[i][c]),
                "lockSharp:false should match default-omitted smooth");
}


// preserve (Preserve Volume) re-projects onto the ORIGINAL surface inside the
// iteration loop; its law is pinned by the KF_F3 / KF_F3i unit cells.

unittest { // preserve:false ⇔ default smooth: regression.
    perturbed();
    auto before = dumpVerts();
    cmd("mesh.smooth strn:0.5 iter:2 preserve:false");
    auto explicit = dumpVerts();
    assert(anyMovedFrom(before, explicit), "control: the smooth must move");
    perturbed();
    cmd("mesh.smooth strn:0.5 iter:2");
    auto omitted = dumpVerts();
    foreach (i; 0 .. explicit.length)
        foreach (c; 0 .. 3)
            assert(approxEq(explicit[i][c], omitted[i][c]),
                "preserve:false should match default-omitted smooth");
}

unittest { // open mesh (cube minus top) + preserve: preserve produces a
           // DIFFERENT result from non-preserved smooth (the projection
           // fires through the command route).
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");

    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:0.5 iter:2 preserve:true");
    auto withPreserve = dumpVerts();

    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    cmd("mesh.delete");
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
    cmd("mesh.smooth strn:0.5 iter:2 preserve:false");
    auto noPreserve = dumpVerts();

    bool anyDiff = false;
    foreach (i; 0 .. withPreserve.length)
        foreach (c; 0 .. 3) {
            if (!approxEq(withPreserve[i][c], noPreserve[i][c], 1e-4)) {
                anyDiff = true; break;
            }
            if (anyDiff) break;
        }
    assert(anyDiff,
        "open mesh: preserve should produce a different result than "
        ~ "non-preserved smooth (projection cancels normal motion)");
}

unittest {
    // Linear falloff — top corners weight 1, bottom corners weight 0. A
    // weight-0 vertex is INACTIVE (a fixed neighbour, no reaction), so the top
    // four relax against fixed bottoms; the weight lerp comes last. Values
    // from the relax law (tests/fixtures/smooth_kernel.json) on this cube.
    postJson("/api/command", commandBody("scene.reset"));
    auto pre = dumpVerts();

    auto resp = postJson("/api/command",
        `{"id":"mesh.smooth","params":{"strn":0.5,"iter":2,`
        ~ `"falloff":{"type":"linear","shape":"linear",`
        ~ `"start":[0,0.5,0],"end":[0,-0.5,0]}}}`);
    assert(resp["status"].str == "ok", resp.toString());
    auto out_ = dumpVerts();

    foreach (i; 0 .. pre.length) {
        if (pre[i][1] > 0) {
            assert(approxEq(fabs(out_[i][0]), 0.483380914, 1e-6),
                "top vert X expected ±0.483381, got " ~ out_[i][0].to!string);
            assert(approxEq(out_[i][1], 0.499861896, 1e-6),
                "top vert Y expected 0.499862, got " ~ out_[i][1].to!string);
            assert(approxEq(fabs(out_[i][2]), 0.483380914, 1e-6),
                "top vert Z expected ±0.483381, got " ~ out_[i][2].to!string);
        } else {
            foreach (c; 0 .. 3)
                assert(approxEq(out_[i][c], pre[i][c]),
                    "bottom vert (weight 0) should stay at original");
        }
    }
}

long undoDepth() { return getJson("/api/history")["undo"].array.length; }

unittest { // no-op smooth undo must not truncate the undo stack (task 2110,
           // same shape as edge_slide's 0099 regression). `applyKernel`
           // short-circuits at `iter<=0` with `return true;` BEFORE
           // touchedIdx is ever populated for a fresh command instance —
           // the simplest reachable route to a Model-class history entry
           // whose revert() sees touchedIdx.length == 0.
           //
           // With the bug (revert() returned false on empty touchedIdx):
           //   history.undo() reverts the top (Model) entry, gets false,
           //   drops it from undoStack WITHOUT pushing it to redoStack, and
           //   returns false → HTTP {"status":"error"}.
           // With the fix (revert() returns true on empty — no-op success):
           //   the no-op undo succeeds; the real smooth's entry is still
           //   underneath and its own undo succeeds next.
    perturbed();
    auto before = dumpVerts();
    // `/api/reset` pushes scene.reset onto the SAME undo stack as an
    // UndoBoundary entry rather than clearing it — but `CommandHistory`
    // caps the stack at `maxDepth = 50` (command_history.d:243) and evicts
    // the OLDEST entry on every push once full. This worker's `--test`
    // instance is shared across its whole slice of test files, so by the
    // time this block runs the stack is already saturated — PUSHING an
    // entry leaves `undoDepth()` unchanged (one evicted, one added), so a
    // push cannot be asserted by count. POPPING (undo) never evicts, so a
    // pop-count delta IS reliable and is what's asserted below.

    // (1) Real edit — a non-empty result (strn=1, iter=3 on the perturbed
    //     cube), Model history entry pushed.
    cmd("mesh.smooth strn:1 iter:3");

    // (2) No-op edit — iter:0 short-circuits before touchedIdx is built.
    //     apply() still returns true and records a SECOND Model entry.
    cmd("mesh.smooth strn:1 iter:0");
    auto depthBeforeUndos = undoDepth();

    // (3) Undo the no-op. With the bug this returns {"status":"error"} and
    //     drops the entry without a redo counterpart; with the fix it must
    //     return {"status":"ok"}.
    auto j1 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j1["status"].str == "ok",
        "undo of no-op smooth must return ok (task 2110 stack-truncation regression): "
        ~ j1.toString);
    assert(undoDepth() == depthBeforeUndos - 1,
        "undoing the no-op entry must remove exactly one entry from the stack — "
        ~ "a bulk suffix loss would drop more than one even when the call above reports ok");

    // (4) Undo the real smooth. If the no-op's failure had also destroyed
    //     this entry (the 0099-shaped total-suffix loss), this call would
    //     return noop/error instead of ok.
    auto j2 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j2["status"].str == "ok",
        "undo of real smooth must return ok after the no-op undo: "
        ~ j2.toString);
    assert(undoDepth() == depthBeforeUndos - 2,
        "undoing the real smooth must remove exactly one MORE entry — a "
        ~ "silent no-op undo that reports ok without popping would leave "
        ~ "this at depthBeforeUndos - 1");

    // (5) Positions must be fully restored to the pre-smooth cube.
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ " not restored after two undos (task 2110 regression)");
}
