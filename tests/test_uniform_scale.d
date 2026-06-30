// Headless test for the xfrm.scaleUniform preset.
//
// Verifies:
//   (1) uniformScale 2   — every vertex coordinate doubles on all three axes.
//   (2) uniformScale 0.5 — every vertex coordinate halves on all three axes.
//   (3) undo after (2)   — vertices restored to baseline.
//   (4) Regression: plain `scale` SX 2 still affects only X (non-uniform path
//       unchanged by the shared-params addition).
//
// The default cube is centred at the origin, so the action centre (centroid)
// is at (0,0,0) and a uniform scale factor f maps every vertex v → f*v.
// No reference engine needed — the assertion is analytic.

import std.net.curl : get, post;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format : format;

void main() {}

private string baseUrl = "http://localhost:8080";

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

private JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

// Post an argstring command to /api/command (matches the format used by
// test_scale_drag_parity.d, fixture_helpers.d, etc.).
private void cmd(string s) {
    auto r = postJson("/api/command", s);
    assert(r["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

private void reset() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed");
}

// Returns the vertices of the active mesh as an array of [x,y,z] triples.
private float[3][] dumpVerts() {
    auto arr = getJson("/api/model")["vertices"].array;
    float[3][] out_;
    out_.length = arr.length;
    foreach (i, v; arr) {
        auto a = v.array;
        float toF(JSONValue jv) {
            if (jv.type == JSONType.float_)   return cast(float) jv.floating;
            if (jv.type == JSONType.integer)  return cast(float) jv.integer;
            if (jv.type == JSONType.uinteger) return cast(float) jv.uinteger;
            assert(false, "unexpected JSON type for vertex coord");
        }
        out_[i] = [toF(a[0]), toF(a[1]), toF(a[2])];
    }
    return out_;
}

private void assertApprox(float actual, float expected, float tol, string msg) {
    assert(fabs(actual - expected) <= tol,
        format("%s: got %.6f, want %.6f (tol %.6f)", msg, actual, expected, tol));
}

// -------------------------------------------------------------------------
// Case 1 + 2 + 3: xfrm.scaleUniform
// -------------------------------------------------------------------------
unittest {
    reset();
    auto base = dumpVerts();
    assert(base.length == 8, "expected 8-vertex cube, got " ~ to!string(base.length));

    // Case 1: factor 2 → all axes double
    cmd("tool.set xfrm.scaleUniform on");
    cmd("tool.attr xfrm.scaleUniform uniformScale 2");
    cmd("tool.doApply");
    cmd("tool.set xfrm.scaleUniform off");

    auto after2 = dumpVerts();
    assert(after2.length == base.length, "vertex count changed after scale×2");
    enum float tol = 1e-4f;
    foreach (i, v; after2) {
        assertApprox(v[0], base[i][0] * 2.0f, tol,
            format("vert[%d].x after uniformScale 2", i));
        assertApprox(v[1], base[i][1] * 2.0f, tol,
            format("vert[%d].y after uniformScale 2", i));
        assertApprox(v[2], base[i][2] * 2.0f, tol,
            format("vert[%d].z after uniformScale 2", i));
    }

    // Case 2: factor 0.5 → all axes halve.
    // Reset to a clean state so the action-centre stays at origin.
    reset();
    base = dumpVerts();

    cmd("tool.set xfrm.scaleUniform on");
    cmd("tool.attr xfrm.scaleUniform uniformScale 0.5");
    cmd("tool.doApply");
    cmd("tool.set xfrm.scaleUniform off");

    auto after05 = dumpVerts();
    assert(after05.length == base.length, "vertex count changed after scale×0.5");
    foreach (i, v; after05) {
        assertApprox(v[0], base[i][0] * 0.5f, tol,
            format("vert[%d].x after uniformScale 0.5", i));
        assertApprox(v[1], base[i][1] * 0.5f, tol,
            format("vert[%d].y after uniformScale 0.5", i));
        assertApprox(v[2], base[i][2] * 0.5f, tol,
            format("vert[%d].z after uniformScale 0.5", i));
    }

    // Case 3: undo restores baseline
    cmd("history.undo");
    auto afterUndo = dumpVerts();
    assert(afterUndo.length == base.length, "vertex count changed after undo");
    foreach (i, v; afterUndo) {
        assertApprox(v[0], base[i][0], tol, format("vert[%d].x after undo", i));
        assertApprox(v[1], base[i][1], tol, format("vert[%d].y after undo", i));
        assertApprox(v[2], base[i][2], tol, format("vert[%d].z after undo", i));
    }
}

// -------------------------------------------------------------------------
// Case 4: regression — plain `scale` with SX 2 only doubles X
// -------------------------------------------------------------------------
unittest {
    reset();
    auto base = dumpVerts();
    assert(base.length == 8);

    cmd("tool.set scale on");
    cmd("tool.attr scale SX 2");
    cmd("tool.attr scale SY 1");
    cmd("tool.attr scale SZ 1");
    cmd("tool.doApply");
    cmd("tool.set scale off");

    auto afterX2 = dumpVerts();
    assert(afterX2.length == base.length);
    enum float tol = 1e-4f;
    foreach (i, v; afterX2) {
        assertApprox(v[0], base[i][0] * 2.0f, tol,
            format("regression vert[%d].x (should double)", i));
        // Y and Z must be unchanged — proves the uniformScale param addition
        // did not accidentally force SY=SZ to follow SX.
        assertApprox(v[1], base[i][1], tol,
            format("regression vert[%d].y (must be unchanged)", i));
        assertApprox(v[2], base[i][2], tol,
            format("regression vert[%d].z (must be unchanged)", i));
    }
}
