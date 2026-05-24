// Tests for /api/transform — the translate / rotate / scale primitive that
// the move / rotate / scale tools (source/tools/{move,rotate,scale}.d) drive
// at the end of every drag. Gizmo plumbing is UI-only and not covered here;
// these tests pin down the math the tools rely on:
//   • translate adds delta to selected verts (or every vert affected by an
//     edge / face selection in the corresponding edit modes)
//   • rotate applies Rodrigues around (axis, angle) about a pivot
//   • scale multiplies (v - pivot) * factor + pivot component-wise
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

import std.net.curl;
import std.json;
import std.math : fabs, PI;
import std.conv : to;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
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

void runTransform(string body) {
    auto resp = post("http://localhost:8080/api/transform", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/transform failed: " ~ resp);
}

string runTransformAllowError(string body) {
    return cast(string)post("http://localhost:8080/api/transform", body);
}

double[3] vertexAt(int idx) {
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto v = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x),
        label ~ ": v" ~ idx.to!string ~ ".x expected " ~ x.to!string
        ~ ", got " ~ v[0].to!string);
    assert(approxEqual(v[1], y),
        label ~ ": v" ~ idx.to!string ~ ".y expected " ~ y.to!string
        ~ ", got " ~ v[1].to!string);
    assert(approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ ".z expected " ~ z.to!string
        ~ ", got " ~ v[2].to!string);
}

// ---------------------------------------------------------------------------
// translate
// ---------------------------------------------------------------------------

unittest { // translate one vertex
    resetCube();
    setSelection("vertices", [0]);  // (-0.5, -0.5, -0.5)
    runTransform(`{"kind":"translate","delta":[1.0,0.5,-0.25]}`);
    assertVertex(0,  0.5, 0.0, -0.75, "translate v0");
    // Other verts unchanged.
    assertVertex(1,  0.5, -0.5, -0.5, "v1 untouched");
    assertVertex(7, -0.5,  0.5,  0.5, "v7 untouched");
}

unittest { // translate every vertex of a selected face
    resetCube();
    // Face 0 = back face [0,3,2,1] — verts 0,1,2,3 should all move.
    setSelection("polygons", [0]);
    runTransform(`{"kind":"translate","delta":[0.0,0.0,1.0]}`);
    foreach (i; [0, 1, 2, 3])
        assertVertex(i, i==0||i==3 ? -0.5 : 0.5,
                        i==0||i==1 ? -0.5 : 0.5,
                        0.5, "back-face vert " ~ i.to!string ~ " moved +Z");
    // Front-face verts unchanged.
    assertVertex(4, -0.5, -0.5, 0.5, "v4 untouched");
}

unittest { // translate via edge selection picks both endpoints
    resetCube();
    // Edge 0 = [0,3] (back-left vertical) → verts 0 and 3 should move.
    setSelection("edges", [0]);
    runTransform(`{"kind":"translate","delta":[0.1,0.0,0.0]}`);
    assertVertex(0, -0.4, -0.5, -0.5, "v0 of edge moved +X");
    assertVertex(3, -0.4,  0.5, -0.5, "v3 of edge moved +X");
    // v1 not part of edge 0 — unchanged.
    assertVertex(1,  0.5, -0.5, -0.5, "v1 untouched");
}

unittest { // empty selection => no-op
    resetCube();
    runTransform(`{"kind":"translate","delta":[10,10,10]}`);
    // No selection in the freshly reset state → nothing should move.
    assertVertex(0, -0.5, -0.5, -0.5, "v0 unchanged on empty selection");
    assertVertex(6,  0.5,  0.5,  0.5, "v6 unchanged on empty selection");
}

// ---------------------------------------------------------------------------
// rotate
// ---------------------------------------------------------------------------

unittest { // rotate one vertex 90° around Y about origin
    resetCube();
    setSelection("vertices", [1]);  // (+0.5, -0.5, -0.5)
    // Right-hand-rule 90° (= π/2) around +Y about origin:
    //   x' = z,   z' = -x   (looking down -Y, ccw rotates +X→-Z)
    // (0.5, -0.5, -0.5) → (-0.5, -0.5, -0.5)
    import std.format : format;
    runTransform(format(`{"kind":"rotate","axis":[0,1,0],"angle":%.10f,"pivot":[0,0,0]}`,
        PI / 2));
    assertVertex(1, -0.5, -0.5, -0.5, "rotate v1 90° around Y");
}

unittest { // rotate around an off-origin pivot
    resetCube();
    setSelection("vertices", [0]);  // (-0.5, -0.5, -0.5)
    // Rotate 180° around X-axis about pivot (0, 0, -0.5):
    // y' = -y, z' = -z + 2*pivot.z = -(-0.5) + (-1) = -0.5 (back to same z).
    // v0 = (-0.5, -0.5, -0.5) → (-0.5, +0.5, -0.5).
    import std.format : format;
    runTransform(format(`{"kind":"rotate","axis":[1,0,0],"angle":%.10f,"pivot":[0,0,-0.5]}`,
        PI));
    assertVertex(0, -0.5,  0.5, -0.5, "rotate v0 180° around X about (0,0,-0.5)");
}

unittest { // rotate of full back face by 90° around Z about origin
    resetCube();
    setSelection("polygons", [0]);  // back face
    // 90° around +Z about origin: x→-y, y→+x.
    // v0 (-0.5,-0.5,-0.5) → ( 0.5,-0.5,-0.5)
    // v1 ( 0.5,-0.5,-0.5) → ( 0.5, 0.5,-0.5)
    // v2 ( 0.5, 0.5,-0.5) → (-0.5, 0.5,-0.5)
    // v3 (-0.5, 0.5,-0.5) → (-0.5,-0.5,-0.5)
    import std.format : format;
    runTransform(format(`{"kind":"rotate","axis":[0,0,1],"angle":%.10f,"pivot":[0,0,0]}`,
        PI / 2));
    assertVertex(0,  0.5, -0.5, -0.5, "v0 after Z-rot");
    assertVertex(1,  0.5,  0.5, -0.5, "v1 after Z-rot");
    assertVertex(2, -0.5,  0.5, -0.5, "v2 after Z-rot");
    assertVertex(3, -0.5, -0.5, -0.5, "v3 after Z-rot");
}

// ---------------------------------------------------------------------------
// scale
// ---------------------------------------------------------------------------

unittest { // uniform scale 2x of one vertex about origin
    resetCube();
    setSelection("vertices", [6]);  // (+0.5, +0.5, +0.5)
    runTransform(`{"kind":"scale","factor":[2,2,2],"pivot":[0,0,0]}`);
    assertVertex(6, 1.0, 1.0, 1.0, "v6 scale 2x");
}

unittest { // non-uniform scale of a face about its centroid
    resetCube();
    setSelection("polygons", [1]);  // front face [4,5,6,7] at z=+0.5; centroid (0,0,0.5)
    // Scale by (3, 1, 1) about (0, 0, 0.5):
    // v4 (-0.5,-0.5, 0.5) → (-1.5, -0.5, 0.5)
    // v6 ( 0.5, 0.5, 0.5) → ( 1.5,  0.5, 0.5)
    runTransform(`{"kind":"scale","factor":[3,1,1],"pivot":[0,0,0.5]}`);
    assertVertex(4, -1.5, -0.5, 0.5, "v4 stretched in X");
    assertVertex(6,  1.5,  0.5, 0.5, "v6 stretched in X");
    // Back-face untouched.
    assertVertex(0, -0.5, -0.5, -0.5, "v0 untouched (not in face 1)");
}

// ---------------------------------------------------------------------------
// errors
// ---------------------------------------------------------------------------

unittest { // unknown kind returns error
    resetCube();
    auto resp = runTransformAllowError(`{"kind":"shear"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for unknown kind, got: " ~ resp);
}

unittest { // missing kind returns error
    resetCube();
    auto resp = runTransformAllowError(`{}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for missing kind, got: " ~ resp);
}
