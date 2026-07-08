// Tests for mesh.magnet — convergent attraction deformer.
//
// Geometry: default cube (makeCube). Anchor = vertex 6 at (0.5, 0.5, 0.5).
// Target   = (0.5, 0.5, 1.5) — directly above v6 in Z.
// dist     = 1.2, strength = 1.0
//
// Distances from v6:
//   v0: √3 ≈ 1.73 — outside sphere, unmoved
//   v1: √2 ≈ 1.41 — outside sphere, unmoved
//   v2:  1.0      — inside (t=5/6, smooth weight≈2/27), moves in Z only
//   v3: √2 ≈ 1.41 — outside sphere, unmoved
//   v4: √2 ≈ 1.41 — outside sphere, unmoved
//   v5:  1.0      — inside, moves in Y AND Z (convergent proof)
//   v6:  0        — anchor (weight=1 via anchorRing) → lands on target
//   v7:  1.0      — inside, moves in X AND Z (convergent proof)
//
// "localhost:8080" is rewritten to the per-worker port by run_test.d when
// running in parallel; keep the literal so that rewrite still matches.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;
import std.stdio : writefln;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

enum string BASE = "http://localhost:8080";

void resetCube() {
    auto resp = cast(string)post(BASE ~ "/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/reset cube failed: " ~ resp);
}

JSONValue cmd(string body_) {
    return parseJSON(cast(string)post(BASE ~ "/api/command", body_));
}

void mustOk(JSONValue r, string ctx = "") {
    assert(r["status"].str == "ok",
           (ctx.length ? ctx ~ ": " : "") ~ r.toString());
}

JSONValue postUndo() { return parseJSON(cast(string)post(BASE ~ "/api/undo", "")); }
JSONValue getModel() { return parseJSON(cast(string)get (BASE ~ "/api/model")); }

struct V3 { double x, y, z; }
V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

// ---------------------------------------------------------------------------
// Test 1 — headless attract with anchor: analytic golden values.
//
// Convergent proof (vs parallel):
//   A parallel field would move every vertex the same direction (+Z).
//   v5=(0.5,−0.5,0.5) → target=(0.5,0.5,1.5): delta=(0,+1,+1).
//   Y-component is NON-ZERO → convergent, not parallel.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    auto r = cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[0.5,0.5,0.5],` ~
                 `"strength":1.0,"dist":1.2,"anchor":6}`);
    mustOk(r, "mesh.magnet");

    auto m = getModel();

    // v6 — anchor (weight=1 via anchorRing) → lands exactly on target.
    auto v6 = vert(m, 6);
    assert(abs(v6.x - 0.5) < 1e-4, "v6.x unchanged");
    assert(abs(v6.y - 0.5) < 1e-4, "v6.y unchanged");
    assert(abs(v6.z - 1.5) < 1e-4, "v6.z should be 1.5 (landed on target)");

    // v5 = (0.5,−0.5,0.5): convergent pull toward (0.5,0.5,1.5).
    // Y increases (0.5 > −0.5) AND Z increases — direction ≠ v6's pure-Z.
    auto v5 = vert(m, 5);
    assert(v5.y > -0.5 + 1e-3,
           "v5.y must increase (convergent y-component: target.y=0.5 > v5.y=-0.5)");
    assert(v5.z > 0.5 + 1e-3,
           "v5.z must increase (convergent z-component)");
    assert(abs(v5.x - 0.5) < 1e-4,
           "v5.x unchanged (delta_x=0 since target.x=v5.x=0.5)");

    // v7 = (−0.5,0.5,0.5): X AND Z increase.
    auto v7 = vert(m, 7);
    assert(v7.x > -0.5 + 1e-3,
           "v7.x must increase (convergent x-component)");
    assert(v7.z > 0.5 + 1e-3,
           "v7.z must increase");

    // v2 = (0.5,0.5,−0.5): Z increases only (target x=v2.x, target y=v2.y).
    auto v2 = vert(m, 2);
    assert(v2.z > -0.5 + 1e-3, "v2.z must increase toward target.z=1.5");
    assert(abs(v2.x - 0.5) < 1e-4, "v2.x unchanged");
    assert(abs(v2.y - 0.5) < 1e-4, "v2.y unchanged");

    // Out-of-sphere verts: v0, v1, v3, v4 (d ≥ √2 > 1.2) — unmoved.
    auto v0 = vert(m, 0);
    assert(abs(v0.x - (-0.5)) < 1e-5, "v0.x unmoved");
    assert(abs(v0.y - (-0.5)) < 1e-5, "v0.y unmoved");
    assert(abs(v0.z - (-0.5)) < 1e-5, "v0.z unmoved");

    auto v1 = vert(m, 1);
    assert(abs(v1.y - (-0.5)) < 1e-5, "v1.y unmoved");
    assert(abs(v1.z - (-0.5)) < 1e-5, "v1.z unmoved");
}

// ---------------------------------------------------------------------------
// Test 2 — undo restores all vertices.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    mustOk(cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[0.5,0.5,0.5],` ~
               `"strength":1.0,"dist":1.2,"anchor":6}`), "mesh.magnet before undo");
    auto v6After = vert(getModel(), 6);
    assert(abs(v6After.z - 1.5) < 1e-4, "v6.z should be 1.5 before undo");

    postUndo();

    auto m2 = getModel();
    auto v6 = vert(m2, 6);
    assert(abs(v6.z - 0.5) < 1e-4, "v6.z should be restored to 0.5 after undo");

    // All cube vertices back to original positions.
    auto v5 = vert(m2, 5);
    assert(abs(v5.y - (-0.5)) < 1e-5, "v5.y restored after undo");
    assert(abs(v5.z - 0.5)    < 1e-5, "v5.z restored after undo");

    auto v7 = vert(m2, 7);
    assert(abs(v7.x - (-0.5)) < 1e-5, "v7.x restored after undo");
}

// ---------------------------------------------------------------------------
// Test 3 — strength=0 returns status:error (no-op contract).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    auto r = cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[0.5,0.5,0.5],` ~
                 `"strength":0.0,"dist":1.2,"anchor":6}`);
    assert(r["status"].str == "error",
           "strength=0 should return status:error, got: " ~ r.toString());

    // Mesh must be unchanged.
    auto v6 = vert(getModel(), 6);
    assert(abs(v6.z - 0.5) < 1e-4, "v6.z must be unmodified when no-op");
}

// ---------------------------------------------------------------------------
// Test 4 — no vertices in sphere → status:error.
//   Center far from all geometry, no anchorRing, tiny dist.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    // Center at (10,10,10), dist=0.001, no anchor → all weights=0 → no-op.
    auto r = cmd(`{"id":"mesh.magnet","target":[10,10,11],"center":[10,10,10],` ~
                 `"strength":1.0,"dist":0.001,"anchor":-1}`);
    assert(r["status"].str == "error",
           "Empty sphere should return status:error, got: " ~ r.toString());
}

// ---------------------------------------------------------------------------
// Test 5 — task 0318 fuzz regression: dist<=0 must NOT invert into
// "affect the whole mesh".
//
// falloff.d's elementWeight() has a degenerate-radius fallback
// (`pickedRadius <= 1e-9f` → weight=1.0 EVERYWHERE) meant for the
// interactive tool-pipe drag before a real radius has been picked. Feeding
// mesh.magnet's own explicit `dist` param a literal 0 (or negative) used to
// hit that same fallback, so EVERY vertex snapped onto `target` instead of
// nothing moving. Center at the origin with no cube vertex there — a
// correctly-behaving zero/negative radius sphere contains no vertices, so
// this must be status:error / no-op, exactly like the dist=0.001 case in
// Test 4 above (dist=0.001 already passed; dist=0 and dist<0 are the
// discontinuous/inverted cases the fuzzer found).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    auto rZero = cmd(`{"id":"mesh.magnet","target":[0,0,5],"center":[0,0,0],` ~
                      `"strength":1.0,"dist":0,"anchor":-1}`);
    assert(rZero["status"].str == "error",
           "dist=0 should return status:error, got: " ~ rZero.toString());
    // No vertex may have moved onto target — the bug snapped all 8 there.
    auto mZero = getModel();
    foreach (i; 0 .. 8) {
        auto v = vert(mZero, i);
        assert(abs(v.z - 5.0) > 1e-3,
               "dist=0 must not tug vertex " ~ i.to!string ~ " onto target");
    }

    resetCube();
    auto rNeg = cmd(`{"id":"mesh.magnet","target":[0,0,5],"center":[0,0,0],` ~
                     `"strength":1.0,"dist":-1,"anchor":-1}`);
    assert(rNeg["status"].str == "error",
           "dist<0 should return status:error, got: " ~ rNeg.toString());
    auto mNeg = getModel();
    foreach (i; 0 .. 8) {
        auto v = vert(mNeg, i);
        assert(abs(v.z - 5.0) > 1e-3,
               "dist<0 must not tug vertex " ~ i.to!string ~ " onto target");
    }

    // dist>0 must still behave locally exactly as before (regression guard
    // on the fix itself): same fixture as Test 1, anchor lands on target,
    // out-of-sphere verts stay put.
    resetCube();
    mustOk(cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[0.5,0.5,0.5],` ~
               `"strength":1.0,"dist":1.2,"anchor":6}`), "mesh.magnet dist>0 after fix");
    auto v6 = vert(getModel(), 6);
    assert(abs(v6.z - 1.5) < 1e-4, "dist>0 anchor should still land on target");
    auto v0 = vert(getModel(), 0);
    assert(abs(v0.z - (-0.5)) < 1e-5, "dist>0 out-of-sphere vert should still be unmoved");
}
