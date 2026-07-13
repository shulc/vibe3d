// Survey #3 P4 — per-item (per-layer) transform, analytic golden fixture.
//
// This is the NON-BAKED proof: a per-layer item transform is authored via
// `layer.attr` writes, drawn render-only, and exposed on `/api/layers` as both
// the authored components AND a composed world matrix — WITHOUT ever moving a
// vertex. The fixture's `expected_matrix` was computed by an INDEPENDENT numpy
// formula (NOT by calling `composedMatrix()`), so a code/fixture agreement is a
// real check, not a tautology. See tests/fixtures/item_transform_trs_pivot.json.
//
// Unlike the `runFixture` golden harness (which drives a `setup` step list and
// asserts `/api/model` vertices), this test must assert a value off `/api/layers`
// (the composed `matrix` + components) and ALSO that `/api/model` vertices are
// UNCHANGED. That non-vertex assertion does not fit `runFixture`'s vertex-only
// contract, so this is a direct HTTP test that parses the fixture itself.
//
// Assertions:
//   1) author pos/rot/scl/pivot via layer.attr → /api/layers xform.matrix equals
//      expected_matrix (1e-6) and the components round-trip;
//   2) /api/model?layer=0 vertices are UNCHANGED vs the reset cube (non-baked);
//   3) /api/reset returns the layer xform to identity (the reset-clears fix).

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : fabs;
import std.format: format;

import fixture_helpers : requireProvenance;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors tests/test_layer_params.d).
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

// Write a layer attr via the argstring form (the forms-panel dispatch shape:
// `layer.attr <index> <attr> <value>`).
void writeAttr(int index, string attr, double value) {
    auto body_ = "layer.attr " ~ index.to!string ~ " " ~ attr ~ " " ~ value.to!string;
    cmd(body_);
}

// The xform sub-object for a given layer index off /api/layers.
JSONValue getXform(int layer) {
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["index"].integer == layer) {
            assert("xform" in l, "layer carries an xform field: " ~ l.toString);
            return l["xform"];
        }
    assert(false, "no layer " ~ layer.to!string ~ " in /api/layers");
}

double num(JSONValue v) {
    if (v.type == JSONType.float_)   return v.floating;
    if (v.type == JSONType.integer)  return cast(double)v.integer;
    if (v.type == JSONType.uinteger) return cast(double)v.uinteger;
    assert(false, "expected a number, got " ~ v.toString);
}

double[] vec(JSONValue arr) {
    double[] r;
    foreach (e; arr.array) r ~= num(e);
    return r;
}

// Flat vertex list for a layer (sorted-independent: we compare element-wise in
// index order, which the reset cube preserves across a render-only xform write).
double[][] modelVerts(int layer) {
    double[][] vs;
    foreach (v; getJson("/api/model?layer=" ~ layer.to!string)["vertices"].array)
        vs ~= vec(v);
    return vs;
}

// ---------------------------------------------------------------------------
// The analytic golden fixture.
// ---------------------------------------------------------------------------

unittest {
    enum string fixtureJson = import("fixtures/item_transform_trs_pivot.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "item_transform_trs_pivot");

    double tol = ("tolerance" in fx) ? num(fx["tolerance"]) : 1e-6;
    auto item  = fx["item"];
    double[] pos = vec(item["pos"]);
    double[] rot = vec(item["rot_deg"]);
    double[] scl = vec(item["scl"]);
    double[] piv = vec(item["pivot"]);
    double[] expM = vec(fx["expected_matrix"]);
    assert(expM.length == 16, "expected_matrix is a float[16]");

    // ---- baseline: reset cube vertices (the non-baked reference) ------------
    resetCube();
    auto vertsBefore = modelVerts(0);
    assert(vertsBefore.length == 8, "reset cube has 8 vertices");

    // The reset layer's xform must be identity (default ItemXform): the matrix
    // is identity, components are default.
    {
        auto x0 = getXform(0);
        double[] m0 = vec(x0["matrix"]);
        double[16] I = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        foreach (i; 0 .. 16)
            assert(fabs(m0[i] - I[i]) <= tol,
                   format("reset xform is identity at [%d]: got %.9g", i, m0[i]));
    }

    // ---- author the transform via layer.attr (the panel dispatch path) ------
    writeAttr(0, "pos.x",   pos[0]); writeAttr(0, "pos.y",   pos[1]); writeAttr(0, "pos.z",   pos[2]);
    writeAttr(0, "rot.x",   rot[0]); writeAttr(0, "rot.y",   rot[1]); writeAttr(0, "rot.z",   rot[2]);
    writeAttr(0, "scl.x",   scl[0]); writeAttr(0, "scl.y",   scl[1]); writeAttr(0, "scl.z",   scl[2]);
    writeAttr(0, "pivot.x", piv[0]); writeAttr(0, "pivot.y", piv[1]); writeAttr(0, "pivot.z", piv[2]);

    // ---- assertion 1a: components round-trip on /api/layers -----------------
    {
        auto x = getXform(0);
        double[] gp = vec(x["pos"]), gr = vec(x["rot"]), gs = vec(x["scl"]), gv = vec(x["pivot"]);
        foreach (i; 0 .. 3) {
            assert(fabs(gp[i] - pos[i]) <= tol, "pos round-trip");
            assert(fabs(gr[i] - rot[i]) <= tol, "rot round-trip");
            assert(fabs(gs[i] - scl[i]) <= tol, "scl round-trip");
            assert(fabs(gv[i] - piv[i]) <= tol, "pivot round-trip");
        }
    }

    // ---- assertion 1b: composed matrix equals the INDEPENDENT golden --------
    {
        auto x = getXform(0);
        double[] gm = vec(x["matrix"]);
        assert(gm.length == 16, "matrix is a float[16]");
        foreach (i; 0 .. 16)
            assert(fabs(gm[i] - expM[i]) <= tol,
                   format("composed matrix vs independent golden at [%d]: " ~
                          "got %.9g want %.9g", i, gm[i], expM[i]));
    }

    // ---- assertion 2: vertices UNCHANGED — the non-baked proof --------------
    {
        auto vertsAfter = modelVerts(0);
        assert(vertsAfter.length == vertsBefore.length,
               "vertex count unchanged by a render-only item transform");
        foreach (i; 0 .. vertsBefore.length)
            foreach (k; 0 .. 3)
                assert(fabs(vertsAfter[i][k] - vertsBefore[i][k]) <= 1e-9,
                       format("vertex %d.%d moved (transform is render-only): " ~
                              "%.9g vs %.9g", i, k, vertsAfter[i][k], vertsBefore[i][k]));
    }

    // ---- assertion 3: reset clears the xform back to identity ---------------
    {
        resetCube();
        auto x = getXform(0);
        double[] m = vec(x["matrix"]);
        double[16] I = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        foreach (i; 0 .. 16)
            assert(fabs(m[i] - I[i]) <= tol,
                   format("reset cleared xform at [%d]: got %.9g", i, m[i]));
        double[] gp = vec(x["pos"]), gs = vec(x["scl"]);
        foreach (i; 0 .. 3) {
            assert(fabs(gp[i]) <= tol, "reset cleared pos");
            assert(fabs(gs[i] - 1.0) <= tol, "reset restored unit scale");
        }
    }
}
