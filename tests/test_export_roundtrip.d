// Export round-trip via assimp (Phase 5) — the B3 1e-6 gate.
//
// Phase 5 routes `.obj`/`.gltf`/`.glb` save through io.scene_export
// (exportViaAssimp -> aiExportScene). This test confirms that a cube exported
// through assimp and re-imported through our Phase 4 importer (io.scene_import)
// lands back in vibe3d's own space within 1e-6 — the round-trip gate that
// decision B3 (no winding/handedness flip on import OR export) must satisfy.
//
// Flow (per format):
//   reset → cube → file.save {path: tmp.<ext>}  (assimp exporter)
//   → mutate (subdivide) so stale state can't masquerade as success
//   → file.load tmp.<ext>  (assimp importer + flattenToMesh weld)
//   → compare /api/model geometry to the pre-export cube.
//
// OBJ vs glTF (the two formats differ in what survives):
//   * OBJ writes n-gons faithfully → assert EXACT geometry: same vertex count,
//     vertex POSITION SET within 1e-6 (set-matched: weld/index order may
//     differ), same face count, and quad arity preserved (6 quads stay quads).
//   * glTF is triangle-only — its exporter triangulates n-gons, so face arity
//     does NOT survive. Assert only that the vertex POSITION SET round-trips
//     within 1e-6 (every original corner present after export+import+weld) and
//     the mesh is non-empty / non-degenerate. The triangulation is glTF-inherent
//     (the format has no n-gon encoding), NOT a vibe3d bug.
//
// The default cube is the unit cube at ±0.5, so a 1e-6 tolerance is meaningful
// (coords are O(1), not O(1e6)).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.file : remove, exists, getSize;
import std.format : format;

void main() {}

// ---------------------------------------------------------------------------
// plumbing
// ---------------------------------------------------------------------------

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = cast(string) post("http://localhost:8080/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", id ~ " failed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

double comp(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

struct P { double x, y, z; }

P[] vertexSet(JSONValue m) {
    P[] ps;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        ps ~= P(comp(a[0]), comp(a[1]), comp(a[2]));
    }
    return ps;
}

// Every point in `want` has a match in `have` within eps (set membership;
// index order is allowed to differ after the export/import weld).
void assertSubset(P[] want, P[] have, double eps, string ctx) {
    foreach (w; want) {
        bool found = false;
        foreach (h; have) {
            if (fabs(w.x - h.x) < eps && fabs(w.y - h.y) < eps
                && fabs(w.z - h.z) < eps) { found = true; break; }
        }
        assert(found, format("%s: original vertex (%g,%g,%g) missing after "
            ~ "round-trip (>%g from every reloaded vertex)",
            ctx, w.x, w.y, w.z, eps));
    }
}

// ---------------------------------------------------------------------------
// OBJ — exact geometry: counts, position SET (1e-6), and quad arity preserved.
// ---------------------------------------------------------------------------

unittest {
    enum string path = "/tmp/vibe3d-test-export-roundtrip.obj";
    enum double EPS = 1e-6;
    if (exists(path)) remove(path);

    resetCube();
    auto orig = model();
    immutable long origV = orig["vertexCount"].integer;
    immutable long origF = orig["faceCount"].integer;
    assert(origV == 8 && origF == 6, "cube prerequisite (8v/6f)");
    auto origPts = vertexSet(orig);

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after OBJ export");
    assert(getSize(path) > 0, "exported OBJ is empty");

    // Mutate so a failed reload can't pass on stale state.
    runCmd("mesh.subdivide");
    assert(model()["vertexCount"].integer != origV, "subdivide should change vert count");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto rt = model();

    // Counts: OBJ preserves n-gons, so the welded cube comes back 8v / 6f.
    assert(rt["vertexCount"].integer == origV,
        "OBJ round-trip vertexCount: expected " ~ origV.to!string
        ~ ", got " ~ rt["vertexCount"].integer.to!string);
    assert(rt["faceCount"].integer == origF,
        "OBJ round-trip faceCount: expected " ~ origF.to!string
        ~ ", got " ~ rt["faceCount"].integer.to!string);

    // Position set round-trips within 1e-6 (both directions = exact set match).
    auto rtPts = vertexSet(rt);
    assertSubset(origPts, rtPts, EPS, "OBJ orig->reloaded");
    assertSubset(rtPts, origPts, EPS, "OBJ reloaded->orig");

    // Quad arity survives (n-gons are written verbatim by the OBJ exporter).
    foreach (i, f; rt["faces"].array)
        assert(f.array.length == 4,
            format("OBJ round-trip face %d should stay a quad (4 corners), got %d",
                   i, f.array.length));

    if (exists(path)) remove(path);
}

// ---------------------------------------------------------------------------
// glTF — position SET only (1e-6). glTF triangulates n-gons on export, so face
// arity is NOT expected to survive; we assert geometry (corners) + non-degenerate.
// ---------------------------------------------------------------------------

unittest {
    enum string path = "/tmp/vibe3d-test-export-roundtrip.gltf";
    enum double EPS = 1e-6;
    if (exists(path)) remove(path);

    resetCube();
    auto orig = model();
    immutable long origV = orig["vertexCount"].integer;
    assert(origV == 8, "cube prerequisite (8v)");
    auto origPts = vertexSet(orig);

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after glTF export");
    assert(getSize(path) > 0, "exported glTF is empty");

    runCmd("mesh.subdivide");
    assert(model()["vertexCount"].integer != origV, "subdivide should change vert count");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto rt = model();

    // Non-degenerate: after triangulation + weld, the 8 cube corners survive and
    // every face still has >= 3 corners.
    assert(rt["vertexCount"].integer == origV,
        "glTF round-trip vertexCount (corners): expected " ~ origV.to!string
        ~ ", got " ~ rt["vertexCount"].integer.to!string);
    assert(rt["faceCount"].integer > 0, "glTF round-trip produced no faces");
    foreach (i, f; rt["faces"].array)
        assert(f.array.length >= 3,
            format("glTF round-trip face %d collapsed below 3 corners "
                   ~ "(inversion/degenerate?), got %d", i, f.array.length));

    // The vertex POSITION SET round-trips within 1e-6 (triangulation does not
    // move corners; it only re-partitions faces).
    auto rtPts = vertexSet(rt);
    assertSubset(origPts, rtPts, EPS, "glTF orig->reloaded");
    assertSubset(rtPts, origPts, EPS, "glTF reloaded->orig");

    if (exists(path)) remove(path);
}
