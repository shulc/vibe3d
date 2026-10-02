// OBJ import regression guard (Phase 4 — assimp via the scene-IR seam).
//
// vibe3d imports OBJ / glTF / FBX through assimp into `ImportedScene`, then
// `flattenToMesh` merges into one Mesh. This test exercises the OBJ path end to
// end via the HTTP `file.load` command + `/api/model` read, mirroring
// test_lwo_multilayer.
//
// What it pins:
//   * A unit cube authored with QUAD faces loads to 8 verts, 6 faces, and the
//     faces stay QUADS (decision A3: no aiProcess_Triangulate). OBJ stores
//     per-corner vertices; the positional weld (B5) collapses the dupes back to
//     8 distinct corners. assimp's JoinIdenticalVertices already merges most,
//     and the weld is the authoritative step.
//   * A two-object OBJ (two `o` groups at disjoint positions) merges: vertex
//     count = sum, both position clusters present — exercises the multi-part
//     walk + flatten.
//   * A bogus .obj loads to a clean `error` with the prior mesh intact (the
//     assimp-unavailable path can't be forced in-process; a malformed file
//     drives the same failure return).
//
// OBJ nodes are IDENTITY-transform, so these fixtures do NOT exercise the
// node-transform bake (B2) or handedness/winding (B3). That coverage lives in
// test_gltf_transform.d, which authors a node-translated glTF fixture so the
// matrix helpers (toMat16 / mul4 / transformPoint) have a runtime witness.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove, exists;
import std.format : format;
import std.math   : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// Fixtures (OBJ is plain text).
// ---------------------------------------------------------------------------

// Unit cube [0,1]^3, 8 verts, 6 QUAD faces. OBJ is 1-indexed. Winding is CCW
// from outside (front faces), matching vibe3d's makeCube.
enum string cubeObj =
    "o cube\n"
    ~ "v 0 0 0\n"   // 1
    ~ "v 1 0 0\n"   // 2
    ~ "v 1 1 0\n"   // 3
    ~ "v 0 1 0\n"   // 4
    ~ "v 0 0 1\n"   // 5
    ~ "v 1 0 1\n"   // 6
    ~ "v 1 1 1\n"   // 7
    ~ "v 0 1 1\n"   // 8
    ~ "f 1 4 3 2\n" // -Z
    ~ "f 5 6 7 8\n" // +Z
    ~ "f 1 5 8 4\n" // -X
    ~ "f 2 3 7 6\n" // +X
    ~ "f 4 8 7 3\n" // +Y
    ~ "f 1 2 6 5\n";// -Y

// Two disjoint quads as separate objects: one at the origin, one far away at
// x=+10. Each is a single quad (4 verts). Merged: 8 verts, 2 faces.
enum string twoObjObj =
    "o quadA\n"
    ~ "v 0 0 0\n"   // 1
    ~ "v 1 0 0\n"   // 2
    ~ "v 1 1 0\n"   // 3
    ~ "v 0 1 0\n"   // 4
    ~ "f 1 2 3 4\n"
    ~ "o quadB\n"
    ~ "v 10 0 0\n"  // 5
    ~ "v 11 0 0\n"  // 6
    ~ "v 11 1 0\n"  // 7
    ~ "v 10 1 0\n"  // 8
    ~ "f 5 6 7 8\n";

string cubePath()  { return "/tmp/vibe3d_test_import_cube.obj"; }
string twoPath()   { return "/tmp/vibe3d_test_import_two.obj"; }

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

void resetApp() {
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
}

string loadCmd(string path) {
    auto resp = post(testBaseUrl() ~ "/api/command",
        "file.load path:\"" ~ path ~ "\"");
    return cast(string) resp;
}

void loadOk(string path) {
    auto resp = loadCmd(path);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "file.load should succeed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get(testBaseUrl() ~ "/api/model"));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {  // cube: 8 verts, 6 faces, faces stay quads (no triangulation)
    write(cubePath(), cubeObj);
    resetApp();
    loadOk(cubePath());
    auto m = model();

    assert(m["vertexCount"].integer == 8,
        "expected 8 verts after positional weld, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "expected 6 faces, got " ~ m["faceCount"].integer.to!string);

    // n-gons preserved: every face must have 4 corners.
    auto faces = m["faces"].array;
    assert(faces.length == 6, "expected 6 faces");
    foreach (i, f; faces)
        assert(f.array.length == 4,
            format("face %d should stay a QUAD (n-gon preserved), got %d corners",
                   i, f.array.length));

    remove(cubePath());
}

unittest {  // cube positions: the 8 unit-cube corners are all present
    write(cubePath(), cubeObj);
    resetApp();
    loadOk(cubePath());
    auto m = model();

    auto verts = m["vertices"].array;
    assert(verts.length == 8, "expected 8 vertex tuples");

    // Each imported vertex must be a unit-cube corner (coords in {0,1}).
    bool[8] seen;
    foreach (v; verts) {
        auto a = v.array;
        const x = a[0].floating, y = a[1].floating, z = a[2].floating;
        assert((approxEqual(x, 0) || approxEqual(x, 1))
            && (approxEqual(y, 0) || approxEqual(y, 1))
            && (approxEqual(z, 0) || approxEqual(z, 1)),
            format("vertex (%g,%g,%g) is not a unit-cube corner", x, y, z));
        const ix = approxEqual(x, 1) ? 1 : 0;
        const iy = approxEqual(y, 1) ? 2 : 0;
        const iz = approxEqual(z, 1) ? 4 : 0;
        seen[ix + iy + iz] = true;
    }
    foreach (i, s; seen)
        assert(s, format("cube corner %d missing after weld", i));

    remove(cubePath());
}

unittest {  // two-object OBJ → TWO layers (no flattening, layers Stage 3)
    // Pre-Stage-3 this fixture merged into one 8-vert / 2-face mesh. With the
    // layered import path a multi-part interchange file stops flattening: each
    // OBJ object becomes its own layer (first active/foreground, the rest
    // visible background). /api/model defaults to the ACTIVE layer, so it now
    // shows just the first quad (4 verts, 1 face). The full-coverage assertions
    // (layer count, per-layer geometry, flattened export) live in
    // test_layer_import.d; this guard only pins that the obj path no longer
    // flattens a multi-object file.
    write(twoPath(), twoObjObj);
    resetApp();
    loadOk(twoPath());
    auto m = model();

    assert(m["vertexCount"].integer == 4,
        "active layer should be the first quad (4 verts), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1,
        "active layer should be a single quad (1 face), got "
        ~ m["faceCount"].integer.to!string);

    // The active layer is the ORIGIN object (first part); the far object lives
    // in the second (background) layer, so it is NOT in the active model.
    auto verts = m["vertices"].array;
    foreach (v; verts) {
        const x = v.array[0].floating;
        assert(x <= 1.5, "active layer should hold only the origin object");
    }

    remove(twoPath());
}

unittest {  // missing .obj => clean error, prior mesh intact
    // Establish a known-good state first.
    resetApp();
    auto before = model();
    const beforeV = before["vertexCount"].integer;
    const beforeF = before["faceCount"].integer;
    assert(beforeV > 0, "reset should leave a non-empty mesh to guard");

    // A non-existent path with an assimp extension. aiImportFile returns null;
    // importViaAssimp returns false; FileLoad.apply returns false; the command
    // dispatcher maps that to status:error. (assimp's OBJ importer is lenient
    // about garbage *content* — it silently skips unknown lines and yields an
    // empty scene — so a missing file is the reliable hard-failure trigger.)
    const missing = "/tmp/vibe3d_test_import_does_not_exist.obj";
    if (exists(missing)) remove(missing);
    auto resp = loadCmd(missing);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "missing .obj should report error, got: " ~ resp);

    // The mesh must be unchanged (the load failed before replacing it).
    auto after = model();
    assert(after["vertexCount"].integer == beforeV,
        "prior mesh vertexCount changed after a failed load");
    assert(after["faceCount"].integer == beforeF,
        "prior mesh faceCount changed after a failed load");
}

// ---------------------------------------------------------------------------
// S1e — the assimp-family material mapping (captured C8f, "K"): diffuse amount
// 1.0, base colour = Kd, specular = mean(Ks) (a white specular colour — no
// colour field; coloured Ks is gap G4), glossiness = 1 − rough(Ns) with
// rough = 1 − (log2 Ns − 2)/10. assimp fills Ks 0 / Ns 0 for an OBJ without
// MTL or an MTL without them (its `ObjFile::Material` defaults), so those
// read specular 0 / glossiness 0 — our pinned output, the reference's look
// uncaptured (gap G6).
// ---------------------------------------------------------------------------

/// The first surface after loading `obj` (+ `mtl` when given) from TMPDIR.
JSONValue firstSurface(string stem, string obj, string mtl) {
    import std.process : environment, thisProcessID;
    import std.path : buildPath;
    immutable dir = environment.get("TMPDIR", "/var/tmp");
    immutable o = buildPath(dir, format("s1e_%s_%d.obj", stem, thisProcessID()));
    immutable m = buildPath(dir, format("s1e_%s_%d.mtl", stem, thisProcessID()));
    scope(exit) { if (exists(o)) remove(o); if (exists(m)) remove(m); }
    import std.path : baseName;
    write(o, (mtl.length ? "mtllib " ~ baseName(m) ~ "\nusemtl M\n" : "")
             ~ "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n");
    if (mtl.length) write(m, mtl);
    resetApp();
    loadOk(o);
    auto s = model()["surfaces"].array;
    assert(s.length >= 1, stem ~ ": no surface imported");
    foreach (x; s) if (x["name"].str == "M") return x;
    return s[0];
}

double numOf(JSONValue v) { return v.type == JSONType.integer ? cast(double)v.integer : v.floating; }

unittest {  // (1) a complete MTL: the K row
    auto s = firstSurface("k", "", "newmtl M\nKd 0.2 0.4 0.8\nKs 0.2 0.5 0.8\nNs 50\nd 1\n");
    auto bc = s["baseColor"].array;
    assert(approxEqual(numOf(bc[0]), 0.2) && approxEqual(numOf(bc[1]), 0.4) && approxEqual(numOf(bc[2]), 0.8),
        "S1e (1): base colour is not Kd: " ~ s.toString);
    assert(approxEqual(numOf(s["diffuseAmount"]), 1.0), "S1e (1): diffuse amount is not 1.0: " ~ s.toString);
    assert(approxEqual(numOf(s["specularAmount"]), 0.5),
        "S1e (1): specular is not mean(Ks) 0.5 (a channel read gives 0.2 or 0.8): " ~ s.toString);
    assert(approxEqual(numOf(s["glossiness"]), 0.3643856, 1e-5),
        "S1e (1): glossiness is not 1 - rough(Ns 50) = 0.3643856: " ~ s.toString);
}

unittest {  // (2) no mtllib: assimp's filled DefaultMaterial (gap G6)
    auto s = firstSurface("nomtl", "", "");
    auto bc = s["baseColor"].array;
    assert(approxEqual(numOf(bc[0]), 0.6) && approxEqual(numOf(s["diffuseAmount"]), 1.0)
        && approxEqual(numOf(s["specularAmount"]), 0) && approxEqual(numOf(s["glossiness"]), 0),
        "S1e (2): OBJ without MTL — expected base 0.6, diffuse 1, specular 0, glossiness 0 "
        ~ "(assimp fills Ks 0 / Ns 0; gap G6): " ~ s.toString);
}

unittest {  // (3) an MTL with Kd only (gap G6)
    auto s = firstSurface("kdonly", "", "newmtl M\nKd 0.3 0.3 0.3\n");
    assert(approxEqual(numOf(s["specularAmount"]), 0) && approxEqual(numOf(s["glossiness"]), 0),
        "S1e (3): Kd-only MTL — expected specular 0, glossiness 0 (gap G6): " ~ s.toString);
}
