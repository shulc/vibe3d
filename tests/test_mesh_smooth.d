// Tests for mesh.smooth — Laplacian smoothing of selected vertices.
//
// Cube smoke-tests:
//   * strn=0 ⇒ no-op
//   * iter=0 ⇒ no-op
//   * Each iteration moves every vert toward the centroid of its 3
//     edge-adjacent corners. With strn=1 the cube collapses partway
//     toward origin; with strn=0.5 partway less.
//   * High iter count ⇒ all verts converge near origin (uniform
//     averaging on a closed regular mesh is contractive).
//   * Selection-aware: only selected verts move; unselected stay put
//     even though they're neighbours of moving ones (the snapshot
//     pattern reads the previous-iteration positions of unselected
//     verts as their original ones).
//   * Undo restores.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;

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

unittest { // strn=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0 iter:5");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "strn=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // iter=0 ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:0");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "iter=0 smooth shouldn't move verts off ±0.5");
    }
}

unittest { // strn=1, iter=1 on cube — each vert averages with its 3
           // edge-adjacent corners, all of which differ by ±1 in
           // exactly two of XYZ. The signed component along each axis
           // averages: (0.5 + 0.5 + 0.5 + (-0.5)) / 4 = 0.25 for the
           // three "same-sign" corner & one diagonal opposite. Wait —
           // actually each cube corner has 3 edge-neighbours; each
           // neighbour differs in exactly ONE axis. So for vert
           // (-0.5, -0.5, -0.5):
           //   nbr1 = (+0.5, -0.5, -0.5)  // X-edge
           //   nbr2 = (-0.5, +0.5, -0.5)  // Y-edge
           //   nbr3 = (-0.5, -0.5, +0.5)  // Z-edge
           // avg = (-0.5+0.5-0.5-0.5)/3, (...) ... = (-0.5/3, -0.5/3, -0.5/3)
           //     = (-1/6, -1/6, -1/6).
           // strn=1: new = old + 1*(avg-old) = avg.
           // So every cube vert moves to its (avg of 3 nbrs).
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // Each cube corner had components ±0.5; after one strn=1 smooth,
        // each component magnitude should be 1/6 (since two of the three
        // neighbours share that component value, the third flips).
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 1.0/6.0, 1e-4),
                "strn=1 iter=1 cube smooth: expected |c|=1/6, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // strn=0.5, iter=1 on cube — half the displacement of strn=1
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // new = old + 0.5*(avg-old) = (old + avg)/2
        // old = ±0.5; avg = ±1/6; (0.5 + 1/6)/2 = 1/3 (for positive-sign
        // axis); (-0.5 + -1/6)/2 = -1/3.
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 1.0/3.0, 1e-4),
                "strn=0.5 iter=1 cube smooth: expected |c|=1/3, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // many iterations converge toward origin
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:100");
    auto verts = dumpVerts();
    foreach (v; verts) {
        double r = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
        assert(r < 0.05,
            "after 100 iter strn=1 smooth, vert should be near origin, got r="
            ~ r.to!string);
    }
}

unittest { // selection-aware: vertex mode + 1 selected vert ⇒ only it moves
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.smooth strn:1 iter:1");
    auto verts = dumpVerts();
    // Vert 0 = (-0.5, -0.5, -0.5) → moved to (-1/6, -1/6, -1/6).
    auto v0 = verts[0];
    assert(approxEq(v0[0], -1.0/6.0, 1e-4),
        "vert 0 should move to -1/6, got " ~ v0[0].to!string);
    assert(approxEq(v0[1], -1.0/6.0, 1e-4));
    assert(approxEq(v0[2], -1.0/6.0, 1e-4));
    // Vert 1 = (+0.5, -0.5, -0.5), unselected → stays.
    auto v1 = verts[1];
    assert(approxEq(v1[0],  0.5, 1e-4),
        "vert 1 should stay at +0.5, got " ~ v1[0].to!string);
    assert(approxEq(v1[1], -0.5, 1e-4));
    assert(approxEq(v1[2], -0.5, 1e-4));
}

unittest { // undo restores
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:3");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corners");
    }
}


// PR-3 of the convolve design doc — lockBound freezes verts
// on boundary edges (edges shared by only one face). Setup deletes
// the top face of a cube to create a 4-vert boundary; without
// lockBound the smoothing pulls those verts toward the cube centre,
// with lockBound they stay pinned at ±0.5.

unittest { // lockBound:false ⇒ boundary verts move (regression check)
    postJson("/api/reset", "");
    // Select + delete top face (f4 in cube order).
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");
    // Now the 4 top verts (originally v2,v3,v6,v7 = corners at y=+0.5)
    // sit on the open seam. Smooth aggressively.
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
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
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
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

    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
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

unittest { // lockBound on a CLOSED mesh (cube with no boundary) is a no-op
           // — smoothing identical with lockBound on/off.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:0.5 iter:2 lockBound:false");
    auto noLock = dumpVerts();

    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:0.5 iter:2 lockBound:true");
    auto withLock = dumpVerts();

    assert(noLock.length == withLock.length);
    foreach (i; 0 .. noLock.length)
        foreach (c; 0 .. 3)
            assert(approxEq(noLock[i][c], withLock[i][c]),
                "closed mesh: lockBound on/off should be identical");
}


// PR-4 of the convolve design doc — lockCorner freezes
// ONLY valence-2 boundary verts (true open-mesh corners), not the
// full boundary loop. Strict subset of lockBound.

unittest { // cube-minus-top: top corners are valence-3 (2 horizontal
           // boundary edges + 1 vertical shared edge), so lockCorner
           // locks NOTHING and the verts must move under heavy smooth.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
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

unittest { // single quad (cube minus 5 faces): all 4 remaining verts
           // are valence-2 corners (each touches 2 boundary edges of
           // the same single face). lockCorner pins ALL of them →
           // smooth becomes a no-op.
    postJson("/api/reset", "");
    // Keep f0 (back face), delete f1..f5.
    postJson("/api/select", `{"mode":"polygons","indices":[1,2,3,4,5]}`);
    cmd("mesh.delete");
    auto before = dumpVerts();
    assert(before.length == 4,
        "setup: single quad should have 4 verts, got " ~ before.length.to!string);

    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:1 iter:10 lockCorner:true");
    auto after = dumpVerts();

    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "single quad: all corners are valence-2, lockCorner "
                ~ "should freeze every vert; v[" ~ i.to!string
                ~ "][" ~ c.to!string ~ "] before=" ~ before[i][c].to!string
                ~ " after=" ~ after[i][c].to!string);
}

unittest { // lockBound + lockCorner together is equivalent to lockBound
           // alone — corner is a subset. Verify on cube-minus-top.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:1 iter:5 lockBound:true lockCorner:true");
    auto both = dumpVerts();

    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:1 iter:5 lockBound:true");
    auto boundOnly = dumpVerts();

    assert(both.length == boundOnly.length);
    foreach (i; 0 .. both.length)
        foreach (c; 0 .. 3)
            assert(approxEq(both[i][c], boundOnly[i][c]),
                "lockBound+lockCorner should match lockBound alone "
                ~ "(corner is a subset)");
}


// PR-5 of the convolve design doc — lockSharp pins verts
// on interior edges whose dihedral angle exceeds the sharp angle
// (degrees). All cube edges are 90°.

unittest { // sharpAngle = 45° < 90° → every cube edge is
           // "sharp" → all 8 verts pinned → smooth no-op.
    postJson("/api/reset", "");
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpAngle:45");
    auto after = dumpVerts();
    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "lockSharp 45°: every cube edge is 90°, all verts "
                ~ "should be pinned (no-op); v[" ~ i.to!string ~ "][" ~ c.to!string ~ "] "
                ~ "before=" ~ before[i][c].to!string
                ~ " after="  ~ after[i][c].to!string);
}

unittest { // sharpAngle = 115° > 90° → no edge passes
           // the threshold → no lock → cube smooths normally.
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpAngle:115");
    auto after = dumpVerts();
    bool anyMoved = false;
    foreach (v; after)
        if (!approxEq(fabs(v[0]), 0.5) || !approxEq(fabs(v[1]), 0.5)
                                       || !approxEq(fabs(v[2]), 0.5)) {
            anyMoved = true; break;
        }
    assert(anyMoved,
        "lockSharp 115°: no cube edge passes threshold, "
        ~ "smooth should move every vert toward centroid");
}

unittest { // sharpThreshold (RADIANS wire alias) = π/4 ≈ 0.785 (45°)
           // < 90° → every cube edge is "sharp" → all 8 verts pinned →
           // smooth no-op. Mirrors the sharpAngle:45 case but exercises
           // the radians wire param the parity harness sends.
    postJson("/api/reset", "");
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpThreshold:0.7853981633974483");
    auto after = dumpVerts();
    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "sharpThreshold 45°(rad): every cube edge is 90°, all verts "
                ~ "should be pinned (no-op); v[" ~ i.to!string ~ "][" ~ c.to!string ~ "] "
                ~ "before=" ~ before[i][c].to!string
                ~ " after="  ~ after[i][c].to!string);
}

unittest { // sharpThreshold (RADIANS wire alias) = 2.0 (≈114.59°)
           // > 90° → no edge passes the threshold → no lock → cube
           // smooths toward centroid. Radians analogue of the
           // sharpAngle:115 case; this is the parity divergence fixed
           // in task 0473 (harness sends `sharpThreshold` in radians).
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpThreshold:2.0");
    auto after = dumpVerts();
    bool anyMoved = false;
    foreach (v; after)
        if (!approxEq(fabs(v[0]), 0.5) || !approxEq(fabs(v[1]), 0.5)
                                       || !approxEq(fabs(v[2]), 0.5)) {
            anyMoved = true; break;
        }
    assert(anyMoved,
        "sharpThreshold 2.0 rad: no cube edge passes threshold, "
        ~ "smooth should move every vert toward centroid");
}

unittest { // sharpThreshold OVERRIDES sharpAngle when both supplied:
           // sharpAngle:45 alone would pin the cube, but a radians
           // sharpThreshold:2.0 (≈114.59°) supplied alongside wins →
           // no lock → cube smooths. Locks in the override precedence.
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:1 iter:5 lockSharp:true sharpAngle:45 sharpThreshold:2.0");
    auto after = dumpVerts();
    bool anyMoved = false;
    foreach (v; after)
        if (!approxEq(fabs(v[0]), 0.5) || !approxEq(fabs(v[1]), 0.5)
                                       || !approxEq(fabs(v[2]), 0.5)) {
            anyMoved = true; break;
        }
    assert(anyMoved,
        "sharpThreshold (radians) must override sharpAngle (degrees) "
        ~ "when both are supplied");
}

unittest { // lockSharp:false ⇔ default smooth: regression — no
           // difference between explicit lockSharp:false and the
           // default omitted parameter.
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:2 lockSharp:false");
    auto explicit = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:2");
    auto omitted = dumpVerts();
    assert(explicit.length == omitted.length);
    foreach (i; 0 .. explicit.length)
        foreach (c; 0 .. 3)
            assert(approxEq(explicit[i][c], omitted[i][c]),
                "lockSharp:false should match default-omitted smooth");
}


// PR-6 of the convolve design doc — preserve (Preserve
// Volume) projects each smoothed vert back onto its pre-smooth
// tangent plane, cancelling the normal-direction component of the
// Laplacian motion. On a radially-symmetric closed cube every
// vert's smoothing delta is purely along its corner normal, so
// preserve cancels the entire motion → smooth no-op.

unittest { // cube + preserve:true ⇒ no-op (all motion is along
           // corner normals, all cancelled by projection).
    postJson("/api/reset", "");
    auto before = dumpVerts();
    cmd("mesh.smooth strn:1 iter:5 preserve:true");
    auto after = dumpVerts();
    assert(before.length == after.length);
    foreach (i; 0 .. before.length)
        foreach (c; 0 .. 3)
            assert(approxEq(before[i][c], after[i][c]),
                "cube + preserve: all cube smoothing is along corner "
                ~ "normals, preserve should cancel entirely; v["
                ~ i.to!string ~ "][" ~ c.to!string ~ "] "
                ~ "before=" ~ before[i][c].to!string
                ~ " after="  ~ after[i][c].to!string);
}

unittest { // preserve:false ⇔ default smooth: regression.
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:2 preserve:false");
    auto explicit = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.smooth strn:0.5 iter:2");
    auto omitted = dumpVerts();
    foreach (i; 0 .. explicit.length)
        foreach (c; 0 .. 3)
            assert(approxEq(explicit[i][c], omitted[i][c]),
                "preserve:false should match default-omitted smooth");
}

unittest { // open mesh (cube minus top) + preserve: verts still
           // move tangentially but the normal component is removed.
           // We don't pin specific positions here — just verify that
           // preserve produces a DIFFERENT result from non-preserved
           // smooth (proving the projection actually fires) and that
           // verts haven't escaped a reasonable bbox.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");

    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("mesh.smooth strn:0.5 iter:2 preserve:true");
    auto withPreserve = dumpVerts();

    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    cmd("mesh.delete");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
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
    // Linear falloff blend — top corners get full smooth (weight=1),
    // bottom corners stay put (weight=0). The blend lerps each touched
    // vert between its pre-smooth original and the post-smooth result
    // by per-vert weight, evaluated at the ORIGINAL position (not the
    // moving target).
    postJson("/api/reset", "");
    auto pre = dumpVerts();

    auto resp = postJson("/api/command",
        `{"id":"mesh.smooth","params":{"strn":0.5,"iter":2,`
        ~ `"falloff":{"type":"linear","shape":"linear",`
        ~ `"start":[0,0.5,0],"end":[0,-0.5,0]}}}`);
    assert(resp["status"].str == "ok", resp.toString());
    auto out_ = dumpVerts();

    // Top corners (y=+0.5): smoothed → toward centroid. For closed
    // cube + strn=0.5 + iter=2, top vert at (±0.5, +0.5, ±0.5) ends
    // at (±2/9, +2/9, ±2/9) ≈ ±0.2222.
    // Bottom corners (y=-0.5): weight=0 → stay at original ±0.5.
    foreach (i; 0 .. pre.length) {
        if (pre[i][1] > 0) {
            assert(approxEq(fabs(out_[i][0]), 2.0 / 9.0, 1e-4),
                "top vert X expected ±2/9, got " ~ out_[i][0].to!string);
            assert(approxEq(out_[i][1], 2.0 / 9.0, 1e-4),
                "top vert Y expected +2/9, got " ~ out_[i][1].to!string);
        } else {
            foreach (c; 0 .. 3)
                assert(approxEq(out_[i][c], pre[i][c]),
                    "bottom vert (weight 0) should stay at original");
        }
    }
}
