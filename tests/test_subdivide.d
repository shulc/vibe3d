// Tests for mesh.subdivide (Catmull-Clark) and mesh.subdivide_faceted.
//
// Catmull-Clark on a cube (8v / 12e / 6f), one step:
//   verts: 8 originals + 6 face points + 12 edge points = 26
//   faces: 6 × 4 = 24
//   edges: by Euler (V − E + F = 2 for a closed surface) = 48

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.array     : array;
import std.conv      : to;
import std.math      : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    // Subdivide / subdivide_faceted / subpatch_toggle all require
    // Polygons edit mode (guard added with phase-7.6 SYMM work — see
    // commands/mesh/subdivide.d). Reset leaves edit mode at Vertices,
    // so switch explicitly. Tests that exercise the guard itself
    // switch back to vertex / edge mode after this helper.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
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

// ---------------------------------------------------------------------------
// Catmull-Clark
// ---------------------------------------------------------------------------

unittest { // subdivide cube once → 26 / 48 / 24
    resetCube();
    runCmd("mesh.subdivide");
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "expected 26 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer == 48,
        "expected 48 edges, got " ~ m["edgeCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "expected 24 faces, got " ~ m["faceCount"].integer.to!string);
}

unittest { // every subdivided face is a quad
    resetCube();
    runCmd("mesh.subdivide");
    auto faces = model()["faces"].array;
    foreach (i, f; faces)
        assert(f.array.length == 4,
            "face " ~ i.to!string ~ " is not a quad");
}

unittest { // subdivide is volume-preserving on average — face points are
           // weighted averages, so they stay inside the original cube AABB.
    resetCube();
    runCmd("mesh.subdivide");
    auto verts = model()["vertices"].array;
    foreach (v; verts) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        assert(x >= -0.5 - 1e-6 && x <= 0.5 + 1e-6,
            "subdivided vertex x out of [-0.5, 0.5]: " ~ x.to!string);
        assert(y >= -0.5 - 1e-6 && y <= 0.5 + 1e-6, "y OOR");
        assert(z >= -0.5 - 1e-6 && z <= 0.5 + 1e-6, "z OOR");
    }
}

unittest { // double-subdivide: 26 → ?, then check Euler holds
    resetCube();
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");
    auto m = model();
    long V = m["vertexCount"].integer;
    long E = m["edgeCount"].integer;
    long F = m["faceCount"].integer;
    // Closed surface, genus 0: V - E + F = 2.
    assert(V - E + F == 2,
        "Euler violated after 2 subdivides: V=" ~ V.to!string
        ~ " E=" ~ E.to!string ~ " F=" ~ F.to!string);
    // Every face still a quad.
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 4,
            "face " ~ i.to!string ~ " is not a quad after second subdivide");
}

// ---------------------------------------------------------------------------
// Selection-aware subdivide
// ---------------------------------------------------------------------------

unittest { // subdivide only one selected face → topology grows by less than full
    resetCube();
    setSelection("polygons", [0]);  // back face only
    runCmd("mesh.subdivide");
    auto m = model();
    long V = m["vertexCount"].integer;
    long F = m["faceCount"].integer;
    // Full cube subdivide gives 26 / 24. Selecting one face gives strictly
    // fewer of each — the unselected faces stay intact (possibly merged into
    // n-gons at the boundary, but never expanded into 4 quads).
    assert(V < 26,
        "selected subdivide should add fewer verts than a full one (got V=" ~ V.to!string ~ ")");
    assert(F < 24,
        "selected subdivide should add fewer faces (got F=" ~ F.to!string ~ ")");
    assert(F > 6,
        "selected subdivide should still add some faces (got F=" ~ F.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Faceted subdivide
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Edit-mode behaviour
//
// subdivide / subdivide_faceted are polygon-aware in Polygons mode (refine
// just the selected faces) but in Vertices / Edges mode they ignore any
// stale face selection and refine the whole cage. subpatch_toggle stays
// polygon-only — it has no whole-mesh fallback that would make sense.
// ---------------------------------------------------------------------------

unittest { // subdivide in vertices mode refines the whole cage, ignoring
           // any stale face selection from a prior polygon session.
    resetCube();
    setSelection("polygons", [0]);  // stale selection that should be ignored
    auto r = post("http://localhost:8080/api/command", "select.typeFrom vertex");
    assert(parseJSON(cast(string)r)["status"].str == "ok");
    auto resp = post("http://localhost:8080/api/command", "mesh.subdivide");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "mesh.subdivide should succeed in vertex mode, got " ~ resp);
    auto m = model();
    // Whole-cage CC on a cube → 26 / 48 / 24 (same as the polygon-mode
    // no-selection case).
    assert(m["vertexCount"].integer == 26,
        "expected full-cage refinement (26 verts), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24);
}

unittest { // subdivide_faceted in edges mode refines the whole cage too.
    resetCube();
    setSelection("polygons", [0]);
    post("http://localhost:8080/api/command", "select.typeFrom edge");
    auto resp = post("http://localhost:8080/api/command",
                     "mesh.subdivide_faceted");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "mesh.subdivide_faceted should succeed in edges mode, got " ~ resp);
    auto m = model();
    assert(m["vertexCount"].integer == 26);
    assert(m["faceCount"].integer == 24);
}

unittest { // subpatch_toggle still refused in vertices mode — no whole-mesh
           // fallback that would make sense (it's a per-face flag flip).
    resetCube();
    post("http://localhost:8080/api/command", "select.typeFrom vertex");
    auto resp = post("http://localhost:8080/api/command",
                     "mesh.subpatch_toggle");
    auto j = parseJSON(cast(string)resp);
    assert(j["status"].str != "ok",
        "mesh.subpatch_toggle should fail in vertex mode, got " ~ resp);
}

unittest { // subdivide allowed in polygon mode (resetCube already sets it)
    resetCube();
    auto resp = post("http://localhost:8080/api/command", "mesh.subdivide");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "mesh.subdivide should succeed in polygon mode, got " ~ resp);
    auto m = model();
    assert(m["vertexCount"].integer == 26);
}

unittest { // faceted subdivide on cube — same topology as CC, but verts stay on
           // the original cube faces (no smoothing pull-in).
    resetCube();
    runCmd("mesh.subdivide_faceted");
    auto m = model();
    assert(m["vertexCount"].integer == 26,
        "expected 26 verts after faceted subdivide, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "expected 24 faces after faceted subdivide, got " ~ m["faceCount"].integer.to!string);

    // Faceted = no smoothing → every vert lies exactly on a cube face.
    foreach (v; m["vertices"].array) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        bool onSurface =
            approxEqual(fabs(x), 0.5) ||
            approxEqual(fabs(y), 0.5) ||
            approxEqual(fabs(z), 0.5);
        assert(onSurface,
            "faceted vertex should lie on a cube face: ("
            ~ x.to!string ~ ", " ~ y.to!string ~ ", " ~ z.to!string ~ ")");
    }
}

// ---------------------------------------------------------------------------
// Selection preservation across subdivision
//
// Both subdivide commands snapshot the pre-op face selection and re-apply it
// to the children of each selected cage face. Editing-flow rationale: a user
// who refines a focused subset to keep working on it shouldn't lose that
// focus to a hard-coded resetSelection — the new sub-faces ARE the new
// working set.
//
// Coverage: the selected children of cage face[0] (back face, z = -0.5) all
// inherit z = -0.5 (corner-pinned for OSD, midpoints/centroid for faceted),
// so a centroid check identifies them without depending on the engine-
// specific output ordering.
// ---------------------------------------------------------------------------

JSONValue selection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

// Centroid of face fi from /api/model JSON (avg of its vertex positions).
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

unittest { // mesh.subdivide preserves selection on the back face
    resetCube();
    setSelection("polygons", [0]);  // back face, z = -0.5
    runCmd("mesh.subdivide");
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 4,
        "subdivide should select all 4 children of the back face, got "
        ~ sel.length.to!string);
    auto m = model();
    foreach (s; sel) {
        auto c = faceCentroid(m, cast(size_t)s.integer);
        assert(approxEqual(c[2], -0.5),
            "selected child face should sit on z = -0.5 (back face), got z="
            ~ c[2].to!string);
    }
}

unittest { // mesh.subdivide_faceted preserves selection on the back face
    resetCube();
    setSelection("polygons", [0]);
    runCmd("mesh.subdivide_faceted");
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 4,
        "subdivide_faceted should select all 4 children of the back face, got "
        ~ sel.length.to!string);
    auto m = model();
    foreach (s; sel) {
        auto c = faceCentroid(m, cast(size_t)s.integer);
        assert(approxEqual(c[2], -0.5),
            "selected child face should sit on z = -0.5 (back face), got z="
            ~ c[2].to!string);
    }
}

unittest { // selecting two opposite faces — both selections survive
    resetCube();
    setSelection("polygons", [0, 1]);  // back (z=-0.5) + front (z=+0.5)
    runCmd("mesh.subdivide_faceted");
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 8,
        "expected 4+4 children selected, got " ~ sel.length.to!string);
    auto m = model();
    int back = 0, front = 0;
    foreach (s; sel) {
        auto c = faceCentroid(m, cast(size_t)s.integer);
        if      (approxEqual(c[2], -0.5)) ++back;
        else if (approxEqual(c[2],  0.5)) ++front;
    }
    assert(back == 4 && front == 4,
        "expected 4 back + 4 front, got " ~ back.to!string ~ "/" ~ front.to!string);
}

unittest { // no selection → no auto-select after subdivide
    // Refining the WHOLE cage (no user selection) should leave the result
    // unselected — auto-selecting all 24 child faces would surprise the user
    // and invalidate the next "select something then act on it" gesture.
    resetCube();
    runCmd("mesh.subdivide");
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 0,
        "subdivide with no selection should leave the result unselected, got "
        ~ sel.length.to!string ~ " selected");
}

unittest { // no selection → no auto-select after subdivide_faceted
    // Same auto-select guard as the CC variant. subdivide_faceted falls back
    // to an internal all-true mask when nothing is selected, but that's an
    // implementation detail — the user-visible "previous selection" is
    // empty, so the post-op selection must stay empty.
    resetCube();
    runCmd("mesh.subdivide_faceted");
    auto sel = selection()["selectedFaces"].array;
    assert(sel.length == 0,
        "subdivide_faceted with no selection should leave the result unselected, got "
        ~ sel.length.to!string ~ " selected");
}
