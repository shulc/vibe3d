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
// The shared HTTP client resolves the port assigned by run_test.d.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;
import std.stdio : writefln;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

alias BASE = testBaseUrl;

void resetCube() {
    auto resp = cast(string)post(BASE ~ "/api/command", commandBody("scene.reset", `{"type":"cube"}`));
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

JSONValue postUndo() { return parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("history.undo"))); }
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
    // The value, not only the direction: smooth shape at t=5/6 gives
    // w = 1-(3t²-2t³) = 2/27, so v2.z = -0.5 + 2·(2/27) (a linear shape
    // would give w = 1/6).
    assert(abs(v2.z - (-0.5 + 2.0 * 2.0 / 27.0)) < 1e-4,
           "v2.z must be -0.5 + 2·(2/27) (smooth-shape weight), got " ~ v2.z.to!string);
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

// ---------------------------------------------------------------------------
// Injected falloff REPLACES the command's own Element sphere (task 9445).
// A linear falloff (w=1 at y=+0.5, w=0 at y=-0.5) sends every top-row vertex
// onto the target and leaves the bottom row; the sphere (centre v6, dist 1.2)
// would leave the far top corner (-0.5,0.5,-0.5) unmoved — that corner is the
// cell that tells the two packets apart.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    mustOk(cmd(`{"id":"mesh.magnet","params":{"target":[0.5,0.5,1.5],`
             ~ `"center":[0.5,0.5,0.5],"strength":1.0,"dist":1.2,"anchor":-1,`
             ~ `"falloff":{"type":"linear","shape":"linear",`
             ~ `"start":[0,0.5,0],"end":[0,-0.5,0]}}}`), "mesh.magnet injected falloff");
    auto m = getModel();
    size_t top, bottom;
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        if (abs(v.z - 1.5) < 1e-4) {
            assert(abs(v.x - 0.5) < 1e-4 && abs(v.y - 0.5) < 1e-4,
                   "vertex " ~ i.to!string ~ " at w=1 must land on the target");
            ++top;
        } else {
            assert(abs(v.y + 0.5) < 1e-5 && abs(abs(v.z) - 0.5) < 1e-5,
                   "vertex " ~ i.to!string ~ " is neither on the target nor an "
                   ~ "unmoved bottom-row (w=0) vertex: (" ~ v.x.to!string ~ ", "
                   ~ v.y.to!string ~ ", " ~ v.z.to!string ~ ")");
            ++bottom;
        }
    }
    assert(top == 4 && bottom == 4, "the injected linear falloff must move the "
           ~ "4 top-row vertices and no other; moved " ~ top.to!string
           ~ ", stayed " ~ bottom.to!string);
}

// ---------------------------------------------------------------------------
// The anchor vertex moves by the ANCHOR RING, not by the sphere: centre far
// from the mesh, tiny dist, anchor 0. Only v0 lands on the target; without
// the ring every weight is 0 and the command refuses (task 9445). Anchor 0
// also keeps the ring's `>= 0` guard honest at its boundary.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    mustOk(cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[10,10,10],` ~
               `"strength":1.0,"dist":0.001,"anchor":0}`), "mesh.magnet anchor ring");
    auto m = getModel();
    auto v0 = vert(m, 0);
    assert(abs(v0.x - 0.5) < 1e-5 && abs(v0.y - 0.5) < 1e-5 && abs(v0.z - 1.5) < 1e-5,
           "the anchor vertex 0 must land on the target via the anchor ring");
    foreach (i; 1 .. 8) {
        auto v = vert(m, i);
        assert(abs(abs(v.x) - 0.5) < 1e-5 && abs(abs(v.y) - 0.5) < 1e-5
               && abs(abs(v.z) - 0.5) < 1e-5,
               "vertex " ~ i.to!string ~ " is outside the far sphere and must not move");
    }
}

// ---------------------------------------------------------------------------
// Turned layer (task 9491): the Element weight is world-space, so the sphere is
// centred on the DRAWN anchor. A rigid layer transform keeps every distance,
// so the analytic weights of Test 1 must hold unchanged; a sphere left at the
// layer-local centre sits ~3 m from the drawn cube and moves only the anchor.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    foreach (c; ["layer.attr 0 pos.x 3", "layer.attr 0 rot.z 90"])
        mustOk(parseJSON(cast(string)post(BASE ~ "/api/command", c)), c);

    mustOk(cmd(`{"id":"mesh.magnet","target":[0.5,0.5,1.5],"center":[0.5,0.5,0.5],` ~
               `"strength":1.0,"dist":1.2,"anchor":6}`), "mesh.magnet on a turned layer");
    auto m = getModel();
    assert(abs(vert(m, 6).z - 1.5) < 1e-4, "turned layer: the anchor did not land on the target");
    immutable double z2 = vert(m, 2).z;
    assert(abs(z2 - (-0.5 + 2.0 * 2.0 / 27.0)) < 1e-4,
           "turned layer: v2.z must be -0.5 + 2·(2/27) as on an unturned layer (sphere on the "
           ~ "drawn anchor), got " ~ z2.to!string);
}
