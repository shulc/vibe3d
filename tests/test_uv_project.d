// test_uv_project.d — analytic golden + smoke tests for `uv.project`.
//
// Coverage:
//   SOURCE-BACKED (in-process):
//     1. Planar axis=Z, create-if-absent: UV map created, (u,v)=(x,y) for all corners.
//     2. Box: per-face normal selects the planar basis; matches projectUv(Planar,
//        dominant-axis) independently computed for every face.
//     3. Undo (create-from-absent): revert() removes the freshly created map.
//     4. Selected-face scoping: only selected faces' corners get written.
//     5. Zero-face mesh: apply() returns false, no orphan UV map created.
//        (meshFromJson rejects empty-vertex AND empty-polygon meshes, so this
//        invariant is tested in-process only; HTTP cannot load a no-face file.)
//   HTTP:
//     6. Planar analytic golden: default cube → uv.project → file.save → parse all
//        face corners; expected (u,v)=(x,y) reconstructed from vertex positions.
//     7. Box smoke: map present, data.length == loops*2 (inferred from face count).
//     8. Cylindrical smoke: map present, u ∈ [0,1] for all corners.
//     9. Spherical smoke: map present, both u and v ∈ [0,1] for all corners.
//    10. Undo of created-from-absent: after /api/undo, file.save has no uvMaps.

import std.math   : fabs, atan2, PI;
import std.file   : write, remove, exists, readText;
import std.format : format;
import std.json   : parseJSON, JSONType, JSONValue;
import std.conv   : to;

import mesh     : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import math     : Vec3;
import view     : View;
import editmode : EditMode;
import snapshot : MeshSnapshot;
import commands.mesh.uv_project : UvProject;
import uv_project : UvProjMode, UvProjAxis, projectUv, dominantAxis;
import std.net.curl : post, get;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

private enum string kBase = "http://localhost:8080";

private JSONValue runCmd(string id, string paramsJson = "") {
    string body_ = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body_));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
    return j;
}

private string runCmdRaw(string body_) {
    return cast(string) post(kBase ~ "/api/command", body_);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

private enum float eps = 1e-4f;
private bool feq(float a, float b) { return fabs(a - b) < eps; }

// Set enum/string param named `name` on cmd.
private void setStrParam(T)(T cmd, string name, string value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == name) { *p.sptr = value; return; }
    assert(false, "string param not found: " ~ name);
}

// Return UV at face corner (fi, c) from the "uv" map.
private float[2] cornerUv(const ref Mesh m, uint fi, uint c) {
    auto map = m.meshMap(kUvMapName);
    if (map is null) return [float.nan, float.nan];
    const size_t l = m.faceCornerLoop(fi, c);
    if (l == size_t.max || l * 2 + 1 >= map.data.length)
        return [float.nan, float.nan];
    return [map.data[l * 2], map.data[l * 2 + 1]];
}

// Select only face fi (all others deselected).
private void selectOnlyFace(ref Mesh m, uint fi) {
    if (m.faceMarks.length < m.faces.length)
        m.faceMarks.length = m.faces.length;
    foreach (ref b; m.faceMarks) b &= ~Mesh.Marks.Select;
    m.faceMarks[fi] |= Mesh.Marks.Select;
}

// Parse a JSON number as float (handles integer, uinteger, float_ types).
private float jfloat(JSONValue v) {
    if (v.type == JSONType.float_)   return cast(float) v.floating;
    if (v.type == JSONType.integer)  return cast(float) v.integer;
    if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
    assert(false, "jfloat: unexpected type " ~ v.type.to!string);
}

// ---------------------------------------------------------------------------
// Test 1: Planar axis=Z, create-if-absent.
//
// makeCube() has no UV map.  uv.project must CREATE the map and write
// (u,v) = (vertex.x, vertex.y) for every corner (center=origin, size=1).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    assert(m.meshMap(kUvMapName) is null, "cube must start without a UV map");

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvProject(&m, view, EditMode.Vertices);
    // defaults: mode=planar, axis=z, size=1, center=origin
    assert(cmd.apply(), "planar apply on cube must return true");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null,  "UV map must be created by uv.project");
    assert(map.data.length == m.loops.length * 2,
           format("UV data length %d != loops*2 %d", map.data.length, m.loops.length * 2));

    // (u,v) = (x,y) for every face corner.
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        foreach (uint c; 0 .. cast(uint) m.faces[fi].length) {
            const size_t l = m.faceCornerLoop(fi, c);
            assert(l != size_t.max);
            Vec3 p = m.vertices[m.loops[l].vert];
            float gotU = map.data[l * 2];
            float gotV = map.data[l * 2 + 1];
            assert(feq(gotU, p.x),
                format("planar-Z face %d corner %d: u=%g expected %g", fi, c, gotU, p.x));
            assert(feq(gotV, p.y),
                format("planar-Z face %d corner %d: v=%g expected %g", fi, c, gotV, p.y));
        }
    }
}

// ---------------------------------------------------------------------------
// Test 2: Box projection.
//
// For each face, box chooses the planar basis via the face's dominant normal
// axis.  Assert that every corner's UV matches an independent call to
// projectUv(Planar, dominant-axis-from-faceNormal).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    View view = new View(0, 0, 800, 600);
    auto cmd = new UvProject(&m, view, EditMode.Vertices);
    setStrParam(cmd, "mode", "box");
    assert(cmd.apply(), "box apply on cube must return true");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "box: UV map must be created");

    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        Vec3 fn = m.faceNormal(fi);
        uint da = dominantAxis(fn);
        UvProjAxis boxAxis = (da == 0) ? UvProjAxis.X
                           : (da == 1) ? UvProjAxis.Y
                                       : UvProjAxis.Z;
        foreach (uint c; 0 .. cast(uint) m.faces[fi].length) {
            const size_t l = m.faceCornerLoop(fi, c);
            assert(l != size_t.max);
            Vec3     p   = m.vertices[m.loops[l].vert];
            float[2] exp = projectUv(p, UvProjMode.Planar, boxAxis,
                                     Vec3(0,0,0), 1.0f, fn);
            float gotU = map.data[l * 2];
            float gotV = map.data[l * 2 + 1];
            assert(feq(gotU, exp[0]),
                format("box face %d corner %d: u=%g expected %g (da=%d)",
                       fi, c, gotU, exp[0], da));
            assert(feq(gotV, exp[1]),
                format("box face %d corner %d: v=%g expected %g (da=%d)",
                       fi, c, gotV, exp[1], da));
        }
    }
}

// ---------------------------------------------------------------------------
// Test 3: Undo removes a created-from-absent map.
//
// Snapshot precedes addMeshMap; snapshot.d:97 restores meshMaps wholesale,
// removing the freshly created entry.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    assert(m.meshMap(kUvMapName) is null, "cube must start without UV map");

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvProject(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "apply must return true");
    assert(m.meshMap(kUvMapName) !is null, "UV map must exist after apply");

    assert(cmd.revert(), "revert must return true");
    // snapshot.d:97 replaced meshMaps with the pre-addMeshMap snapshot →
    // "uv" entry is gone.
    assert(m.meshMap(kUvMapName) is null,
           "UV map must be removed after revert (snapshot precedes addMeshMap)");
}

// ---------------------------------------------------------------------------
// Test 4: Selected-face scoping.
//
// Select only face 0.  Only its corners should have non-zero UVs after apply.
// (The cube is centred at origin so all vertex x/y coordinates are ±0.5,
// i.e. non-zero — good discriminator for "was written vs left at 0".)
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    selectOnlyFace(m, 0);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvProject(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "selected-face apply must return true");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null);

    // Face 0 corners: u and v must equal vertex x and y (non-zero).
    const uint nc0 = cast(uint) m.faces[0].length;
    foreach (uint c; 0 .. nc0) {
        const size_t l = m.faceCornerLoop(0, c);
        Vec3 p = m.vertices[m.loops[l].vert];
        assert(feq(map.data[l * 2],     p.x),
            format("selected face 0 corner %d: u=%g expected %g", c, map.data[l*2], p.x));
        assert(feq(map.data[l * 2 + 1], p.y),
            format("selected face 0 corner %d: v=%g expected %g", c, map.data[l*2+1], p.y));
    }

    // All other faces' corners must be zero (addMeshMap zero-initialises).
    foreach (uint fi; 1 .. cast(uint) m.faces.length) {
        foreach (uint c; 0 .. cast(uint) m.faces[fi].length) {
            const size_t l = m.faceCornerLoop(fi, c);
            assert(feq(map.data[l * 2],     0.0f),
                format("unselected face %d corner %d: u must be 0", fi, c));
            assert(feq(map.data[l * 2 + 1], 0.0f),
                format("unselected face %d corner %d: v must be 0", fi, c));
        }
    }
}

// ---------------------------------------------------------------------------
// Test 5: Empty mesh → apply() returns false, no orphan UV map created.
//
// This is the critical ordering check: affected.length == 0 is detected BEFORE
// MeshSnapshot.capture and before addMeshMap, so the mesh stays clean.
// ---------------------------------------------------------------------------
unittest {
    // Zero-face mesh: one isolated vertex, no faces → zero loops.
    // This is the same shape the HTTP test loads (meshFromJson rejects
    // empty vertices, so one vertex with no faces is the minimal no-op case).
    auto m = Mesh.init;
    m.vertices ~= Vec3(0, 0, 0);
    m.buildLoops(); // 0 faces → 0 loops

    assert(m.meshMap(kUvMapName) is null, "no-face mesh must have no UV map");

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvProject(&m, view, EditMode.Vertices);
    assert(!cmd.apply(),  "apply on zero-face mesh must return false");
    assert(!cmd.revert(), "revert after false-apply must return false (no snapshot)");

    // The critical contract: no orphan map was created.
    assert(m.meshMap(kUvMapName) is null,
           "no orphan UV map after false apply on zero-face mesh");
}

// ---------------------------------------------------------------------------
// Test 6 (HTTP): Planar analytic golden.
//
// Default cube → uv.project {mode:planar, axis:z} → file.save → parse.
// For every face corner: expected (u,v) = (vertex.x, vertex.y).
// CSR offset reconstruction: walk faces in order, running loopBase.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvproject-planar.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"planar","axis":"z"}`);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave), "expected saved file");

    auto j     = parseJSON(readText(tmpSave));
    auto meshJ = j["layers"][0]["mesh"];

    assert("uvMaps" in meshJ, "uvMaps must be present after uv.project");
    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length > 0, "uvMaps[0].data must be non-empty");

    auto vertsJ = meshJ["vertices"].array;
    auto facesJ = meshJ["faces"].array;

    // Walk faces in CSR order: loopBase accumulates corner count per face.
    size_t loopBase = 0;
    foreach (fi, faceJ; facesJ) {
        auto corners = faceJ.array;
        foreach (k, viJ; corners) {
            size_t vi = cast(size_t) viJ.integer;
            float px = jfloat(vertsJ[vi][0]);
            float py = jfloat(vertsJ[vi][1]);
            float gotU = jfloat(uvData[(loopBase + k) * 2]);
            float gotV = jfloat(uvData[(loopBase + k) * 2 + 1]);
            assert(feq(gotU, px),
                format("planar-Z face %d corner %d: u=%g expected %g",
                       fi, k, gotU, px));
            assert(feq(gotV, py),
                format("planar-Z face %d corner %d: v=%g expected %g",
                       fi, k, gotV, py));
        }
        loopBase += corners.length;
    }
    // Sanity: total UV floats match total corners * 2.
    assert(uvData.length == loopBase * 2,
        format("UV data length %d != loopBase*2 %d", uvData.length, loopBase * 2));
}

// ---------------------------------------------------------------------------
// Test 7 (HTTP): Box smoke — map created, correct data size.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvproject-box.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"box"}`);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);

    auto j     = parseJSON(readText(tmpSave));
    auto meshJ = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ, "box: uvMaps must be present");
    auto uvData = meshJ["uvMaps"][0]["data"].array;

    // Count expected loops from faces.
    size_t totalCorners = 0;
    foreach (faceJ; meshJ["faces"].array)
        totalCorners += faceJ.array.length;
    assert(uvData.length == totalCorners * 2,
        format("box: UV data %d != corners*2 %d", uvData.length, totalCorners * 2));
}

// ---------------------------------------------------------------------------
// Test 8 (HTTP): Cylindrical smoke — map created, u ∈ [0,1] for all corners.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvproject-cyl.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"cylindrical","axis":"y"}`);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);

    auto j     = parseJSON(readText(tmpSave));
    auto meshJ = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ, "cylindrical: uvMaps must be present");
    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length > 0);

    // u must be in [0,1] (atan2/(2π)+0.5 is always in [0,1]).
    foreach (i; 0 .. uvData.length / 2) {
        float u = jfloat(uvData[i * 2]);
        assert(u >= -eps && u <= 1.0f + eps,
            format("cylindrical: u[%d] = %g out of [0,1]", i, u));
    }
}

// ---------------------------------------------------------------------------
// Test 9 (HTTP): Spherical smoke — map created, u and v ∈ [0,1].
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvproject-sph.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"spherical","axis":"y"}`);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);

    auto j     = parseJSON(readText(tmpSave));
    auto meshJ = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ, "spherical: uvMaps must be present");
    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length > 0);

    foreach (i; 0 .. uvData.length / 2) {
        float u = jfloat(uvData[i * 2]);
        float v = jfloat(uvData[i * 2 + 1]);
        assert(u >= -eps && u <= 1.0f + eps,
            format("spherical: u[%d] = %g out of [0,1]", i, u));
        assert(v >= -eps && v <= 1.0f + eps,
            format("spherical: v[%d] = %g out of [0,1]", i, v));
    }
}

// ---------------------------------------------------------------------------
// Test 10 (HTTP): Undo of created-from-absent removes the map.
//
// Default cube (no UV map) → uv.project → /api/undo → file.save →
// assert no uvMaps key (or empty array) in the saved JSON.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvproject-undo.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    // Default cube has no UV map → uv.project creates one.
    runCmd("uv.project", `{"mode":"planar","axis":"z"}`);

    // Confirm it was created.
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    auto j1     = parseJSON(readText(tmpSave));
    auto meshJ1 = j1["layers"][0]["mesh"];
    assert("uvMaps" in meshJ1 && meshJ1["uvMaps"].array.length > 0,
           "uv map must be present after uv.project");

    // Undo: snapshot taken before addMeshMap restores the absent state.
    post(kBase ~ "/api/undo", "");

    remove(tmpSave);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    auto j2     = parseJSON(readText(tmpSave));
    auto meshJ2 = j2["layers"][0]["mesh"];
    bool hasUv = ("uvMaps" in meshJ2) !is null
              && meshJ2["uvMaps"].array.length > 0;
    assert(!hasUv,
           "uvMaps must be absent after undo of created-from-absent uv.project");
}

