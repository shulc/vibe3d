// Tests for mesh.subdivide mode=smooth.
//
// Smooth subdivide = faceted (linear) topology + one Laplacian relax pass
// (λ=0.5, boundary-pinned).  Corner analytic golden on a ±0.5 unit cube:
//   new = 0.5 + 0.5*(1/3 - 0.5) = 5/12 ≈ 0.41667
// (strictly between flat=0.5 and ccsds≈0.278).

import std.net.curl;
import std.json;
import std.algorithm : sort, min, max;
import std.array     : array;
import std.conv      : to;
import std.math      : fabs, sqrt;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

JSONValue selection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

void runCmdParams(string id, string params) {
    auto body_ = `{"id":"` ~ id ~ `","params":{` ~ params ~ `}}`;
    auto resp  = post("http://localhost:8080/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " (" ~ params ~ ") failed: " ~ resp);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

// Centroid of face fi from /api/model JSON.
double[3] faceCentroid(JSONValue m, size_t fi) {
    auto verts = m["vertices"].array;
    auto face  = m["faces"].array[fi].array;
    double cx = 0, cy = 0, cz = 0;
    foreach (vi; face) {
        auto v = verts[cast(size_t)vi.integer].array;
        cx += v[0].floating;
        cy += v[1].floating;
        cz += v[2].floating;
    }
    double n = cast(double)face.length;
    return [cx / n, cy / n, cz / n];
}

// ---------------------------------------------------------------------------
// Topology: same as faceted (26/48/24 all-quads)
// ---------------------------------------------------------------------------

unittest { // smooth subdivide cube → 26 / 48 / 24
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "smooth: expected 26 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer   == 48,
        "smooth: expected 48 edges, got " ~ m["edgeCount"].integer.to!string);
    assert(m["faceCount"].integer   == 24,
        "smooth: expected 24 faces, got " ~ m["faceCount"].integer.to!string);
}

unittest { // every smooth-subdivided face is a quad
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto faces = model()["faces"].array;
    foreach (i, f; faces)
        assert(f.array.length == 4,
            "smooth face " ~ i.to!string ~ " is not a quad");
}

// ---------------------------------------------------------------------------
// Position: smooth ≠ flat (analytic golden corner ≈ 5/12 ≈ 0.41667)
// ---------------------------------------------------------------------------

unittest { // smooth corners strictly inside flat surface (< 0.5)
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto verts = model()["vertices"].array;
    // facetedSubdivide puts original cage verts at indices 0-7.
    // After smooth relax they must be strictly inside the flat cube.
    foreach (vi; 0 .. 8) {
        auto v = verts[vi].array;
        assert(fabs(v[0].floating) < 0.5 - 1e-4,
            "smooth: original vert " ~ vi.to!string ~ " x should be < 0.5");
        assert(fabs(v[1].floating) < 0.5 - 1e-4,
            "smooth: original vert " ~ vi.to!string ~ " y should be < 0.5");
        assert(fabs(v[2].floating) < 0.5 - 1e-4,
            "smooth: original vert " ~ vi.to!string ~ " z should be < 0.5");
    }
}

unittest { // smooth corner ≈ 5/12 ≈ 0.41667 (analytic golden, eps 1e-4)
    // Formula: original corner at 0.5 with 3 edge-midpoint neighbors at avg=1/3.
    // new = 0.5 + 0.5*(1/3 - 0.5) = 5/12 ≈ 0.41667.
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto verts = model()["vertices"].array;
    // Any original cage corner suffices — check vert 0.
    auto v0 = verts[0].array;
    double golden = 5.0 / 12.0;
    assert(approxEqual(fabs(v0[0].floating), golden),
        "smooth corner x ≈ 0.41667, got " ~ v0[0].floating.to!string);
    assert(approxEqual(fabs(v0[1].floating), golden),
        "smooth corner y ≈ 0.41667, got " ~ v0[1].floating.to!string);
    assert(approxEqual(fabs(v0[2].floating), golden),
        "smooth corner z ≈ 0.41667, got " ~ v0[2].floating.to!string);
}

// ---------------------------------------------------------------------------
// Three-way discrimination: smooth ≠ flat ≠ ccsds (positions are distinct)
// ---------------------------------------------------------------------------

unittest { // smooth corner (≈0.417) is strictly different from flat corner (=0.5)
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    double smCorner = fabs(model()["vertices"].array[0].array[0].floating);

    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"flat"`);
    double flatCorner = fabs(model()["vertices"].array[0].array[0].floating);

    assert(fabs(smCorner - flatCorner) > 0.05,
        "smooth and flat corners should differ by > 0.05; got "
        ~ smCorner.to!string ~ " vs " ~ flatCorner.to!string);
    // flat corner is exactly 0.5; smooth is strictly less.
    assert(smCorner < flatCorner - 0.05,
        "smooth corner should be less than flat corner by > 0.05");
}

unittest { // smooth corner (≈0.417) is strictly different from ccsds corner (≈0.278)
    // CC corner for a cube: (F + 2E + (n-3)V) / n with n=3, F=(1/6,1/6,1/6),
    // E=(1/3,1/3,1/3) → new = (1/6 + 2/3) / 3 = (5/6) / 3 = 5/18 ≈ 0.278.
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    // Smooth corners are the first 8 verts (original cage verts, preserved by
    // facetedSubdivide layout).
    double smCorner = fabs(model()["vertices"].array[0].array[0].floating);

    resetCube();
    runCmd("mesh.subdivide");  // default = ccsds
    auto ccVerts = model()["vertices"].array;
    // CC corner: the vert closest to (0.5, 0.5, 0.5) among all 26 output verts.
    double ccCorner = 0;
    {
        double best = double.infinity;
        foreach (v; ccVerts) {
            double dx = v.array[0].floating - 0.5;
            double dy = v.array[1].floating - 0.5;
            double dz = v.array[2].floating - 0.5;
            double d  = sqrt(dx*dx + dy*dy + dz*dz);
            if (d < best) {
                best     = d;
                ccCorner = fabs(v.array[0].floating);
            }
        }
    }
    // smooth ≈ 0.417, ccsds ≈ 0.278; must differ by > 0.1.
    assert(fabs(smCorner - ccCorner) > 0.1,
        "smooth and ccsds corners should differ by > 0.1; got "
        ~ smCorner.to!string ~ " vs " ~ ccCorner.to!string);
    assert(smCorner > ccCorner + 0.1,
        "smooth corner should be > ccsds corner (less pulled in)");
}

// ---------------------------------------------------------------------------
// mode=flat via mesh.subdivide → byte-identical to mesh.subdivide_faceted
// ---------------------------------------------------------------------------

unittest { // mode=flat produces same verts as mesh.subdivide_faceted
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"flat"`);
    auto flatViaParam = model()["vertices"].array;

    resetCube();
    runCmd("mesh.subdivide_faceted");
    auto flatViaDedicated = model()["vertices"].array;

    assert(flatViaParam.length == flatViaDedicated.length,
        "flat-via-param and subdivide_faceted vertex counts differ");
    foreach (i; 0 .. flatViaParam.length) {
        foreach (ax; 0 .. 3) {
            double a = flatViaParam[i].array[ax].floating;
            double b = flatViaDedicated[i].array[ax].floating;
            assert(approxEqual(a, b, 1e-5),
                "flat-via-param vert[" ~ i.to!string ~ "][" ~ ax.to!string
                ~ "] differs: " ~ a.to!string ~ " vs " ~ b.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// Selection preservation
// ---------------------------------------------------------------------------

unittest { // smooth preserves face selection (back face → 4 children on back side)
    // Unlike flat/ccsds, smooth relax moves the corner verts of the back face
    // (z=-0.5) toward z=0, so child-face centroids land at z≈-0.458 (-11/24),
    // NOT at z=-0.5.  Check that all 4 selected children are in the back half
    // (z < -0.1) rather than checking for the exact plane z=-0.5.
    resetCube();
    setSelection("polygons", [0]);  // back face, z = -0.5
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 4,
        "smooth: should select 4 children of back face, got " ~ sel.length.to!string);
    auto m = model();
    foreach (s; sel) {
        auto c = faceCentroid(m, cast(size_t)s.integer);
        // Children of the back face have centroid z < -0.1; front/side faces ≥ 0.
        assert(c[2] < -0.1,
            "smooth: selected child should be in the back half (z < -0.1), got z="
            ~ c[2].to!string);
        // Also bounded: smooth can't push any child past the cage (z > -0.5 after relax).
        assert(c[2] > -0.55,
            "smooth: selected child centroid z too negative, got z=" ~ c[2].to!string);
    }
}

unittest { // no selection → no auto-select after smooth
    resetCube();
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 0,
        "smooth with no selection should leave result unselected, got "
        ~ sel.length.to!string ~ " selected");
}

// ---------------------------------------------------------------------------
// Edit-mode fallback
// ---------------------------------------------------------------------------

unittest { // smooth in Vertices mode refines whole cage → 26/48/24
    resetCube();
    setSelection("polygons", [0]);  // stale selection — should be ignored
    post("http://localhost:8080/api/command", "select.typeFrom vertex");
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"mesh.subdivide","params":{"mode":"smooth"}}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "smooth in vertex mode should succeed, got " ~ resp);
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "smooth in vertex mode: expected full-cage refinement (26 verts), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24);
}

// ---------------------------------------------------------------------------
// Partial-mask corruption guard (opponent fix)
//
// Select one face → smooth → check that a corner of an UNREFINED face stays
// exactly put (position eps 1e-6).  A counts-only check would pass even if
// cage verts moved; this position assertion catches the silent-corruption path.
// ---------------------------------------------------------------------------

unittest { // partial smooth: counts strictly less than full
    resetCube();
    setSelection("polygons", [0]);  // back face only
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto m = model();
    assert(m["vertexCount"].integer < 26,
        "partial smooth: V should be < 26, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer < 24,
        "partial smooth: F should be < 24, got " ~ m["faceCount"].integer.to!string);
    assert(m["faceCount"].integer > 6,
        "partial smooth: F should be > 6, got " ~ m["faceCount"].integer.to!string);
}

unittest { // partial smooth: corners of unrefined face stay exactly put (eps 1e-6)
    // Select face[0] (back face, z=-0.5). The front face (z=+0.5) is unrefined.
    // Its 4 corners at (±0.5, ±0.5, +0.5) must not be relaxed.
    resetCube();
    setSelection("polygons", [0]);
    runCmdParams("mesh.subdivide", `"mode":"smooth"`);
    auto verts = model()["vertices"].array;

    int pinnedCount = 0;
    foreach (v; verts) {
        double z = v.array[2].floating;
        if (z > 0.49) {
            // Should be an original cage corner: (±0.5, ±0.5, +0.5).
            double x = v.array[0].floating;
            double y = v.array[1].floating;
            assert(fabs(fabs(x) - 0.5) < 1e-6,
                "unrefined face corner x should stay at ±0.5, got " ~ x.to!string);
            assert(fabs(fabs(y) - 0.5) < 1e-6,
                "unrefined face corner y should stay at ±0.5, got " ~ y.to!string);
            assert(fabs(z - 0.5) < 1e-6,
                "unrefined face corner z should stay at +0.5, got " ~ z.to!string);
            ++pinnedCount;
        }
    }
    assert(pinnedCount == 4,
        "expected exactly 4 pinned front-face corners, found " ~ pinnedCount.to!string);
}
