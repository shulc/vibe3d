// Tests for mesh.triple / mesh.quadruple / mesh.detriangulate.
//
// Starting topology: cube — 8 vertices, 12 edges, 6 quad faces.
//
// After mesh.triple (whole-mesh):
//   faces  = 12 (each quad → 2 tris)
//   verts  = 8  (no new verts)
//   edges  = 18 (12 original + 6 diagonals)
//
// After mesh.quadruple on that triangulated mesh:
//   faces  = 6 quads  (coplanar intra-face tri pairs merged back)
//   verts  = 8
//   edges  = 12
//
// After mesh.detriangulate on the triangulated mesh:
//   Same result as quadruple for a cube (all tri pairs are coplanar
//   intra-face pairs; cross-edge tri pairs have different normals).

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.array     : array;
import std.conv      : to;
import std.math      : fabs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

JSONValue getSel() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
                     `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           id ~ " failed: " ~ resp);
}

void undoCmd() {
    auto resp = post("http://localhost:8080/api/command", `{"id":"history.undo"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           "undo failed: " ~ resp);
}

void redoCmd() {
    auto resp = post("http://localhost:8080/api/command", `{"id":"history.redo"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           "redo failed: " ~ resp);
}

void setPolyMode() {
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
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
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           "/api/select failed: " ~ resp);
}

// Newell normal of face fi from /api/model JSON. Returns unit normal.
double[3] faceNormalFrom(JSONValue m, size_t fi) {
    auto verts = m["vertices"].array;
    auto face  = m["faces"].array[fi].array;
    double nx = 0, ny = 0, nz = 0;
    foreach (i; 0 .. face.length) {
        auto a = verts[cast(size_t)face[i].integer].array;
        auto b = verts[cast(size_t)face[(i+1) % face.length].integer].array;
        nx += (a[1].floating - b[1].floating) * (a[2].floating + b[2].floating);
        ny += (a[2].floating - b[2].floating) * (a[0].floating + b[0].floating);
        nz += (a[0].floating - b[0].floating) * (a[1].floating + b[1].floating);
    }
    double len = sqrt(nx*nx + ny*ny + nz*nz);
    if (len < 1e-9) return [0.0, 1.0, 0.0];
    return [nx/len, ny/len, nz/len];
}

double dotN(double[3] a, double[3] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

// ---------------------------------------------------------------------------
// Phase 1: mesh.triple
// ---------------------------------------------------------------------------

unittest { // cube → triple → 12 tris, 8 verts, 18 edges
    resetCube();
    runCmd("mesh.triple");
    auto m = getModel();
    assert(m["faceCount"].integer == 12,
        "triple: expected 12 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "triple: expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer == 18,
        "triple: expected 18 edges, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // every triple-result face is a triangle
    resetCube();
    runCmd("mesh.triple");
    foreach (i, f; getModel()["faces"].array)
        assert(f.array.length == 3,
            "triple: face " ~ i.to!string ~ " has " ~ f.array.length.to!string
            ~ " verts, expected 3");
}

unittest { // winding: child normals axis-aligned (inherit parent cube-face normal)
    // Parent cube faces have normals ±X/±Y/±Z.  After triple, every child tri
    // should lie on a single cube face, so its Newell normal is also axis-aligned.
    resetCube();
    runCmd("mesh.triple");
    auto m = getModel();
    foreach (fi; 0 .. 12) {
        auto n = faceNormalFrom(m, fi);
        bool axisAligned =
            approxEq(fabs(n[0]), 1.0, 0.01) ||
            approxEq(fabs(n[1]), 1.0, 0.01) ||
            approxEq(fabs(n[2]), 1.0, 0.01);
        assert(axisAligned,
            "triple: face " ~ fi.to!string ~ " normal not axis-aligned: "
            ~ n[0].to!string ~ "," ~ n[1].to!string ~ "," ~ n[2].to!string);
    }
}

unittest { // selection-aware: triple one selected face → 7 faces total
    resetCube();
    setSelection("polygons", [0]);
    runCmd("mesh.triple");
    auto m = getModel();
    assert(m["faceCount"].integer == 7,
        "triple selected: expected 7 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "triple selected: expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
    // The 2 children of face 0 should be selected.
    auto selFaces = getSel()["selectedFaces"].array;
    assert(selFaces.length == 2,
        "triple selected: expected 2 child faces selected, got "
        ~ selFaces.length.to!string);
}

unittest { // undo restores 6 quads / 12 edges
    resetCube();
    runCmd("mesh.triple");
    undoCmd();
    auto m = getModel();
    assert(m["faceCount"].integer == 6,   "triple undo: expected 6 faces");
    assert(m["edgeCount"].integer == 12,  "triple undo: expected 12 edges");
    assert(m["vertexCount"].integer == 8, "triple undo: expected 8 verts");
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 4,
            "triple undo: face " ~ i.to!string ~ " not a quad");
}

unittest { // redo re-splits after undo
    resetCube();
    runCmd("mesh.triple");
    undoCmd();
    redoCmd();
    auto m = getModel();
    assert(m["faceCount"].integer == 12, "triple redo: expected 12 faces");
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 3,
            "triple redo: face " ~ i.to!string ~ " not a triangle");
}

// ---------------------------------------------------------------------------
// Phase 2: mesh.quadruple
// ---------------------------------------------------------------------------

unittest { // triple → quadruple → 6 quads (round-trip by count)
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.quadruple");
    auto m = getModel();
    assert(m["faceCount"].integer == 6,
        "quadruple: expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "quadruple: expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "quadruple: expected 12 edges, got " ~ m["edgeCount"].integer.to!string);
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 4,
            "quadruple: face " ~ i.to!string ~ " not a quad (length "
            ~ f.array.length.to!string ~ ")");
}

unittest { // PLANARITY: every result quad is flat — catches cross-fold bent-quad mis-merges
    // Split quad [a,b,c,d] into implied tris (a,b,c) and (a,c,d); their normals
    // must satisfy dot(n1,n2) > 0.999. A bent cross-face quad (two cube faces
    // sharing an edge) would have a ~45° normal and fail immediately.
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.quadruple");
    auto m = getModel();
    auto verts = m["vertices"].array;

    double[3] triNorm(JSONValue[] face, size_t a, size_t b, size_t c) {
        auto pa = verts[cast(size_t)face[a].integer].array;
        auto pb = verts[cast(size_t)face[b].integer].array;
        auto pc = verts[cast(size_t)face[c].integer].array;
        double ux = pb[0].floating - pa[0].floating;
        double uy = pb[1].floating - pa[1].floating;
        double uz = pb[2].floating - pa[2].floating;
        double vx = pc[0].floating - pa[0].floating;
        double vy = pc[1].floating - pa[1].floating;
        double vz = pc[2].floating - pa[2].floating;
        double nx = uy*vz - uz*vy;
        double ny = uz*vx - ux*vz;
        double nz = ux*vy - uy*vx;
        double len = sqrt(nx*nx + ny*ny + nz*nz);
        if (len < 1e-9) return [0.0, 1.0, 0.0];
        return [nx/len, ny/len, nz/len];
    }

    foreach (fi, fj; m["faces"].array) {
        auto f = fj.array;
        assert(f.length == 4, "planarity check: face is not a quad");
        auto n1 = triNorm(f, 0, 1, 2);
        auto n2 = triNorm(f, 0, 2, 3);
        double d = dotN(n1, n2);
        assert(d > 0.999,
            "quadruple planarity: face " ~ fi.to!string
            ~ " is not flat (dot=" ~ d.to!string
            ~ "); indicates a cross-fold bent-quad mis-merge");
    }
}

unittest { // a lone triangle with no coplanar-convex partner stays as-is
    // Partial-triple one face (→ 2 tris + 5 quads = 7), then whole-mesh
    // quadruple: the 2 coplanar intra-face tris merge → 6 faces total.
    resetCube();
    setSelection("polygons", [0]);
    runCmd("mesh.triple");
    setPolyMode();
    runCmd("mesh.quadruple");
    auto m = getModel();
    assert(m["faceCount"].integer == 6,
        "quadruple lone-tri: expected 6 faces, got "
        ~ m["faceCount"].integer.to!string);
}

unittest { // quadruple undo/redo
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.quadruple");
    undoCmd();
    assert(getModel()["faceCount"].integer == 12,
        "quadruple undo: expected 12 tri faces");
    redoCmd();
    assert(getModel()["faceCount"].integer == 6,
        "quadruple redo: expected 6 quad faces");
}

// ---------------------------------------------------------------------------
// Phase 3: mesh.detriangulate
// ---------------------------------------------------------------------------

unittest { // round-trip: triple one quad → detriangulate → back to 6 faces
    resetCube();
    setSelection("polygons", [0]);
    runCmd("mesh.triple");          // 2 tris + 5 quads = 7 faces
    setPolyMode();
    runCmd("mesh.detriangulate");   // whole-mesh: merges coplanar pairs
    auto m = getModel();
    assert(m["faceCount"].integer == 6,
        "detriangulate round-trip: expected 6 faces, got "
        ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "detriangulate round-trip: expected 8 verts, got "
        ~ m["vertexCount"].integer.to!string);
    // Confirm the re-merged face is a quad.
    bool hasQuad = false;
    foreach (f; m["faces"].array) if (f.array.length == 4) { hasQuad = true; break; }
    assert(hasQuad, "detriangulate round-trip: no quad face found");
}

unittest { // triple whole cube → detriangulate → 6 quads
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.detriangulate");
    auto m = getModel();
    assert(m["faceCount"].integer == 6,
        "detriangulate cube: expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "detriangulate cube: expected 8 verts");
    foreach (i, f; m["faces"].array)
        assert(f.array.length == 4,
            "detriangulate cube: face " ~ i.to!string ~ " not a quad");
}

unittest { // cross-edge tri pairs do NOT merge (different normals, 90° apart)
    // After triple, cube-edge-crossing tri pairs have 90°-apart normals →
    // coplanarity gate (dot > 0.999) rejects them.
    // Only 6 intra-face pairs merge → exactly 6 final faces.
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.detriangulate");
    auto m = getModel();
    assert(m["faceCount"].integer == 6,
        "detriangulate cross-edge: expected 6 faces (no cross-edge merges), got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "detriangulate cross-edge: expected 12 edges, got "
        ~ m["edgeCount"].integer.to!string);
}

unittest { // corner positions survive triple → detriangulate round-trip
    resetCube();
    auto before = getModel()["vertices"].array;
    runCmd("mesh.triple");
    runCmd("mesh.detriangulate");
    auto after = getModel()["vertices"].array;
    assert(before.length == after.length,
        "detriangulate positions: vertex count changed");

    // Sort both sets by coordinates and compare order-independently.
    double[][] extractSorted(JSONValue[] vs) {
        double[][] r;
        foreach (v; vs)
            r ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];
        r.sort!((a, b) =>
            a[0] != b[0] ? a[0] < b[0] :
            a[1] != b[1] ? a[1] < b[1] :
                           a[2] < b[2]);
        return r;
    }
    auto bv = extractSorted(before);
    auto av = extractSorted(after);
    foreach (i; 0 .. bv.length) {
        assert(approxEq(bv[i][0], av[i][0], 1e-5) &&
               approxEq(bv[i][1], av[i][1], 1e-5) &&
               approxEq(bv[i][2], av[i][2], 1e-5),
            "detriangulate: vertex " ~ i.to!string ~ " position changed");
    }
}

unittest { // detriangulate undo/redo
    resetCube();
    runCmd("mesh.triple");
    runCmd("mesh.detriangulate");
    undoCmd();
    assert(getModel()["faceCount"].integer == 12,
        "detriangulate undo: expected 12 faces");
    redoCmd();
    assert(getModel()["faceCount"].integer == 6,
        "detriangulate redo: expected 6 faces");
}
