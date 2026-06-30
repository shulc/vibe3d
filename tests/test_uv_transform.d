// test_uv_transform.d — analytic golden tests for uv.flip / uv.mirror /
// uv.rotate + HTTP read-back smoke.
//
// Pure-D source-backed tests (run via run_test.d's `dmd -unittest -i` path)
// exercise the kernel and command classes in-process.  There is no HTTP
// surface for creating/seeding UV maps, so this follows the same pattern as
// test_uv_pipeline.d / test_mesh_map.d — source-backed for the geometry
// assertions, one HTTP smoke test using a hand-written .v3d fixture.
//
// Coverage:
//   - flip-U whole-map (no face selected) → u' = 1 − u, v unchanged
//   - mirror-U about centroid (ASYMMETRIC fixture, bbox centre ≠ unit):
//       corners [0.2..0.9]×[0.1..0.6], centroid (0.55, 0.35) ≠ (0.5, 0.5);
//       result must DIFFER from the unit-pivot result (pins the centroid path)
//   - rotate-90° CCW on a unit-square UV → (1,0)↦(1,1)
//   - rotate-90° CCW about asymmetric centroid → correct result AND ≠ unit-pivot
//   - undo (revert): UV data restored byte-exact
//   - selected-faces restriction: only the selected face's corners change
//   - missing UV map → throws (non-ok status in HTTP)
//   - empty loop set (empty mesh + UV map) → apply() returns false, no history
//   - HTTP smoke: hand-written v6 .v3d → file.load → uv.flip → file.save →
//     parse uvMaps, assert u' = 1−u → /api/undo → file.save → assert restored

import std.math   : fabs, cos, sin, PI;
import std.file   : write, remove, exists, readText;
import std.format : format;
import std.json   : parseJSON, JSONType, JSONValue;
import std.conv   : to;

import mesh       : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import view       : View;
import editmode   : EditMode;
import snapshot   : MeshSnapshot;
import commands.mesh.uv_transform;
import std.net.curl : post, get;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers (only reached when run_test.d starts vibe3d --test)
// ---------------------------------------------------------------------------

private enum string kBase = "http://localhost:8080";

private JSONValue runCmd(string id, string paramsJson = "") {
    string body_ = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body_));
    assert(j["status"].str == "ok",
           id ~ " failed: " ~ j.toString);
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

// Return the UV pair at face corner (fi, c) from the "uv" map, or [NaN, NaN].
private float[2] cornerUv(const ref Mesh m, uint fi, uint c) {
    auto map = m.meshMap(kUvMapName);
    if (map is null) return [float.nan, float.nan];
    const size_t loop = m.faceCornerLoop(fi, c);
    if (loop == size_t.max || loop * 2 + 1 >= map.data.length)
        return [float.nan, float.nan];
    return [map.data[loop * 2], map.data[loop * 2 + 1]];
}

// Set the UV at face corner (fi, c) in the "uv" map.
private void setCornerUv(ref Mesh m, uint fi, uint c, float u, float v) {
    auto map = m.meshMap(kUvMapName);
    assert(map !is null);
    const size_t loop = m.faceCornerLoop(fi, c);
    assert(loop != size_t.max && loop * 2 + 1 < map.data.length);
    map.data[loop * 2]     = u;
    map.data[loop * 2 + 1] = v;
}

// Build a cube with a fresh zero-filled "uv" PolyVertex map (dim 2).
private Mesh makeCubeWithUv() {
    auto m = makeCube();
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null, "addMeshMap(uv) on cube must succeed");
    // 6 faces × 4 corners = 24 loops → data.length = 48
    assert(map.data.length == m.loops.length * 2,
           "UV map data must be sized to loops*2");
    return m;
}

// Set face `fi` as the only selected face.
private void selectOnlyFace(ref Mesh m, uint fi) {
    if (m.faceMarks.length < m.faces.length)
        m.faceMarks.length = m.faces.length;
    foreach (ref b; m.faceMarks) b &= ~Mesh.Marks.Select;
    m.faceMarks[fi] |= Mesh.Marks.Select;
}

// Set param named `name` to string value on cmd.
private void setStrParam(T)(T cmd, string name, string value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == name) { *p.sptr = value; return; }
    assert(false, "param not found: " ~ name);
}

// Set float param named `name` on cmd.
private void setFloatParam(T)(T cmd, string name, float value) {
    foreach (ref p; cmd.params())
        if (p.name == name) { *p.fptr = value; return; }
    assert(false, "float param not found: " ~ name);
}

// ---------------------------------------------------------------------------
// Test 1: flip-U, whole-map mode (no face selected)
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);

    // Set face-0 corners to distinct u values; leave others at 0.
    setCornerUv(m, 0, 0,  0.2f, 0.1f);
    setCornerUv(m, 0, 1,  0.4f, 0.3f);
    setCornerUv(m, 0, 2,  0.6f, 0.7f);
    setCornerUv(m, 0, 3,  0.8f, 0.9f);

    // No face selected → whole-map mode; defaults axis=u, pivot=unit.
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "uv.flip whole-map must return true");

    // u' = 1 - u for all four corners of face 0.
    auto r0 = cornerUv(m, 0, 0); assert(feq(r0[0], 0.8f) && feq(r0[1], 0.1f),
        format("flip-U c0: expected (0.8,0.1) got (%g,%g)", r0[0], r0[1]));
    auto r1 = cornerUv(m, 0, 1); assert(feq(r1[0], 0.6f) && feq(r1[1], 0.3f),
        format("flip-U c1: expected (0.6,0.3) got (%g,%g)", r1[0], r1[1]));
    auto r2 = cornerUv(m, 0, 2); assert(feq(r2[0], 0.4f) && feq(r2[1], 0.7f),
        format("flip-U c2: expected (0.4,0.7) got (%g,%g)", r2[0], r2[1]));
    auto r3 = cornerUv(m, 0, 3); assert(feq(r3[0], 0.2f) && feq(r3[1], 0.9f),
        format("flip-U c3: expected (0.2,0.9) got (%g,%g)", r3[0], r3[1]));
}

// ---------------------------------------------------------------------------
// Test 2: flip-V, whole-map mode
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);

    setCornerUv(m, 0, 0,  0.3f, 0.2f);
    setCornerUv(m, 0, 1,  0.3f, 0.8f);

    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    setStrParam(cmd, "axis", "v");   // pivot stays "unit"
    assert(cmd.apply(), "uv.flip axis=v must return true");

    // v' = 1 - v, u unchanged
    auto r0 = cornerUv(m, 0, 0);
    assert(feq(r0[0], 0.3f), "flip-V: u unchanged");
    assert(feq(r0[1], 0.8f), "flip-V: v' = 1-0.2 = 0.8");
    auto r1 = cornerUv(m, 0, 1);
    assert(feq(r1[0], 0.3f), "flip-V: u unchanged");
    assert(feq(r1[1], 0.2f), "flip-V: v' = 1-0.8 = 0.2");
}

// ---------------------------------------------------------------------------
// Test 3: mirror-U, selected-face mode, ASYMMETRIC centroid fixture.
//
// Corners of face 0 span [0.2..0.9]×[0.1..0.6] → bbox centre (0.55, 0.35).
// Mirror-U about (0.55, 0.35): u' = 2*0.55 - u = 1.1 - u
// Mirror-U about unit (0.5, 0.5): u' = 1.0 - u
//
// The two pivots give DIFFERENT results: (0.2,0.1)→(0.9,0.1) vs (0.8,0.1).
// This fixture pins that centroid is computed correctly (not confused with
// the unit point).
// ---------------------------------------------------------------------------
unittest {
    import uv_transform : makeFlipU, applyUvAffine, UvAffine;

    // --- centroid result ---
    auto m = makeCubeWithUv();
    selectOnlyFace(m, 0);
    setCornerUv(m, 0, 0,  0.2f, 0.1f);
    setCornerUv(m, 0, 1,  0.9f, 0.1f);
    setCornerUv(m, 0, 2,  0.9f, 0.6f);
    setCornerUv(m, 0, 3,  0.2f, 0.6f);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvMirror(&m, view, EditMode.Vertices);
    // defaults: axis=u, pivot=centroid
    assert(cmd.apply(), "uv.mirror centroid must return true");

    // centroid = (0.55, 0.35), so u' = 1.1 - u
    auto c0 = cornerUv(m, 0, 0); // was (0.2, 0.1)
    auto c1 = cornerUv(m, 0, 1); // was (0.9, 0.1)
    assert(feq(c0[0], 0.9f),  format("mirror-U c0 u': expected 0.9 got %g", c0[0]));
    assert(feq(c0[1], 0.1f),  "mirror-U c0 v: unchanged");
    assert(feq(c1[0], 0.2f),  format("mirror-U c1 u': expected 0.2 got %g", c1[0]));
    assert(feq(c1[1], 0.1f),  "mirror-U c1 v: unchanged");

    // --- unit-pivot result for the same input (must DIFFER) ---
    auto m2 = makeCubeWithUv();
    selectOnlyFace(m2, 0);
    setCornerUv(m2, 0, 0,  0.2f, 0.1f);
    setCornerUv(m2, 0, 1,  0.9f, 0.1f);
    setCornerUv(m2, 0, 2,  0.9f, 0.6f);
    setCornerUv(m2, 0, 3,  0.2f, 0.6f);

    auto cmd2 = new UvMirror(&m2, view, EditMode.Vertices);
    setStrParam(cmd2, "pivot", "unit");
    assert(cmd2.apply());

    // unit: u' = 1.0 - u → (0.2,0.1)→(0.8,0.1) ≠ centroid (0.9,0.1)
    auto u0 = cornerUv(m2, 0, 0);
    assert(feq(u0[0], 0.8f),  format("mirror-U unit c0 u': expected 0.8 got %g", u0[0]));
    // Confirm the two results differ (proving the centroid path is actually used).
    assert(!feq(c0[0], u0[0]),
        "centroid result must differ from unit-pivot result for asymmetric fixture");
}

// ---------------------------------------------------------------------------
// Test 4: rotate-90° CCW, selected-face mode, unit-square UV.
//
// Face 0 corners: (0,0), (1,0), (1,1), (0,1) — centroid = (0.5,0.5) = unit.
// 90° CCW about (0.5,0.5) cycles: (0,0)→(1,0)→(1,1)→(0,1)→(0,0).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    selectOnlyFace(m, 0);
    setCornerUv(m, 0, 0,  0.0f, 0.0f);
    setCornerUv(m, 0, 1,  1.0f, 0.0f);
    setCornerUv(m, 0, 2,  1.0f, 1.0f);
    setCornerUv(m, 0, 3,  0.0f, 1.0f);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvRotate(&m, view, EditMode.Vertices);
    // defaults: angle=90, pivot=centroid (=unit here since UV is symmetric)
    assert(cmd.apply(), "uv.rotate 90° must return true");

    // CCW: (0,0)→(1,0); (1,0)→(1,1); (1,1)→(0,1); (0,1)→(0,0)
    auto r0 = cornerUv(m, 0, 0);
    assert(feq(r0[0], 1.0f) && feq(r0[1], 0.0f),
        format("rotate 90° c0: expected (1,0) got (%g,%g)", r0[0], r0[1]));
    auto r1 = cornerUv(m, 0, 1);
    assert(feq(r1[0], 1.0f) && feq(r1[1], 1.0f),
        format("rotate 90° c1: expected (1,1) got (%g,%g)", r1[0], r1[1]));
    auto r2 = cornerUv(m, 0, 2);
    assert(feq(r2[0], 0.0f) && feq(r2[1], 1.0f),
        format("rotate 90° c2: expected (0,1) got (%g,%g)", r2[0], r2[1]));
    auto r3 = cornerUv(m, 0, 3);
    assert(feq(r3[0], 0.0f) && feq(r3[1], 0.0f),
        format("rotate 90° c3: expected (0,0) got (%g,%g)", r3[0], r3[1]));
}

// ---------------------------------------------------------------------------
// Test 5: rotate-90° CCW, ASYMMETRIC centroid fixture.
//
// Face 0 corners: (0.2,0.1),(0.9,0.1),(0.9,0.6),(0.2,0.6)
// Centroid: bbox centre u=(0.2+0.9)/2=0.55, v=(0.1+0.6)/2=0.35
// 90° CCW about (0.55,0.35): u'=−v+0.90, v'=u−0.20
//   (0.2,0.1)→(0.80,0.00); (0.9,0.1)→(0.80,0.70)
// Unit (0.5,0.5) would give: u'=−v+1.0, v'=u
//   (0.2,0.1)→(0.90,0.20) — differs from centroid result ✓
// ---------------------------------------------------------------------------
unittest {
    // --- centroid result ---
    auto m = makeCubeWithUv();
    selectOnlyFace(m, 0);
    setCornerUv(m, 0, 0,  0.2f, 0.1f);
    setCornerUv(m, 0, 1,  0.9f, 0.1f);
    setCornerUv(m, 0, 2,  0.9f, 0.6f);
    setCornerUv(m, 0, 3,  0.2f, 0.6f);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvRotate(&m, view, EditMode.Vertices);
    // angle=90 (default), pivot=centroid (default)
    assert(cmd.apply());

    auto r0 = cornerUv(m, 0, 0);
    auto r1 = cornerUv(m, 0, 1);
    assert(feq(r0[0], 0.80f) && feq(r0[1], 0.00f),
        format("rotate centroid c0: expected (0.80,0.00) got (%g,%g)", r0[0], r0[1]));
    assert(feq(r1[0], 0.80f) && feq(r1[1], 0.70f),
        format("rotate centroid c1: expected (0.80,0.70) got (%g,%g)", r1[0], r1[1]));

    // --- unit-pivot result (must DIFFER) ---
    auto m2 = makeCubeWithUv();
    selectOnlyFace(m2, 0);
    setCornerUv(m2, 0, 0,  0.2f, 0.1f);
    setCornerUv(m2, 0, 1,  0.9f, 0.1f);
    setCornerUv(m2, 0, 2,  0.9f, 0.6f);
    setCornerUv(m2, 0, 3,  0.2f, 0.6f);

    auto cmd2 = new UvRotate(&m2, view, EditMode.Vertices);
    setStrParam(cmd2, "pivot", "unit");
    assert(cmd2.apply());

    auto u0 = cornerUv(m2, 0, 0);
    // unit: u'=-0.1+1.0=0.90, v'=0.2 — differs from centroid (0.80, 0.00)
    assert(feq(u0[0], 0.90f),
        format("rotate unit c0 u': expected 0.90 got %g", u0[0]));
    assert(!feq(r0[0], u0[0]),
        "centroid rotate result must differ from unit-pivot result");
}

// ---------------------------------------------------------------------------
// Test 6: undo (revert) — UV data restored byte-exact.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    setCornerUv(m, 0, 0,  0.2f, 0.3f);
    setCornerUv(m, 0, 1,  0.7f, 0.4f);

    // Capture the data before apply.
    auto map = m.meshMap(kUvMapName);
    auto before = map.data.dup;

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "apply must succeed");

    // Data has changed after apply.
    assert(map.data[0] != before[0], "u0 must have changed after flip");

    // Revert → data must be restored byte-exact.
    // restore() replaces mesh.meshMaps with a new slice (snapshot.d:97), so
    // the `map` pointer captured before apply is stale after revert.  Re-fetch.
    assert(cmd.revert(), "revert must return true");
    auto mapAfterRevert = m.meshMap(kUvMapName);
    assert(mapAfterRevert !is null, "UV map must exist after revert");
    assert(mapAfterRevert.data == before, "UV data must be byte-exact after revert");
}

// ---------------------------------------------------------------------------
// Test 7: revert without apply returns false (no filled snapshot).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    assert(!cmd.revert(), "revert without apply must return false");
}

// ---------------------------------------------------------------------------
// Test 8: selected-faces restriction — only face 0's corners change.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCubeWithUv();
    auto map = m.meshMap(kUvMapName);

    // Face 0 corners: u = 0.2; other faces' corners: u = 0.7.
    foreach (i; 0 .. m.loops.length) map.data[i * 2] = 0.7f;  // all u = 0.7
    foreach (c; 0 .. 4) {
        const size_t loop = m.faceCornerLoop(0, c);
        map.data[loop * 2] = 0.2f;  // face 0 u = 0.2
    }

    selectOnlyFace(m, 0);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    // axis=u (default), pivot=unit (default) → face 0 u' = 1 - 0.2 = 0.8
    assert(cmd.apply());

    // Face 0 corners must have changed.
    foreach (c; 0 .. 4) {
        const size_t loop = m.faceCornerLoop(0, c);
        assert(feq(map.data[loop * 2], 0.8f),
            format("selected-face: face 0 corner %d u' must be 0.8", c));
    }
    // All other loops (faces 1..5) must be unchanged.
    foreach (fi; 1 .. 6) {
        const face = m.faces[fi];
        foreach (c; 0 .. cast(uint) face.length) {
            const size_t loop = m.faceCornerLoop(cast(uint)fi, cast(uint)c);
            assert(feq(map.data[loop * 2], 0.7f),
                format("selected-face: face %d corner %d must be unchanged (u=0.7)", fi, c));
        }
    }
}

// ---------------------------------------------------------------------------
// Test 9: missing UV map → apply() throws.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();   // no UV map
    View view = new View(0, 0, 800, 600);
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception e) {
        threw = true;
        assert(e.msg.length > 0, "exception message must not be empty");
    }
    assert(threw, "uv.flip with no UV map must throw");
}

// ---------------------------------------------------------------------------
// Test 10: empty loop set → apply() returns false, no snapshot, revert false.
// Empty mesh has 0 loops → whole-map mode returns empty set.
// ---------------------------------------------------------------------------
unittest {
    auto m = Mesh.init;
    m.buildLoops();   // 0 faces → 0 loops, consistent state
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null && uvMap.data.length == 0,
           "UV map on empty mesh must have 0-length data");

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvFlip(&m, view, EditMode.Vertices);
    assert(!cmd.apply(),  "apply on empty mesh (0 loops) must return false");
    assert(!cmd.revert(), "revert after false-apply must return false (no snapshot)");
}

// ---------------------------------------------------------------------------
// HTTP smoke test — hand-written v6 .v3d with a uvMaps block.
//
// Mesh: single quad (4 verts, 1 face = 4 loops).
// UV: [(0.1,0.2), (0.9,0.2), (0.9,0.8), (0.1,0.8)] — 4*2 = 8 floats.
//
// Flow: /api/reset → file.load → uv.flip {axis:u,pivot:unit} →
//       file.save → parse uvMaps → assert u'=1−u →
//       /api/undo → file.save → assert original values restored.
//
// The "localhost:8080" literal is rewritten per-worker by run_test.d for
// parallel runs — keep it spelled out, do not build it dynamically.
// ---------------------------------------------------------------------------

unittest {
    enum string tmpLoad = "/tmp/vibe3d-test-uvxform-input.v3d";
    enum string tmpSave = "/tmp/vibe3d-test-uvxform-result.v3d";
    if (exists(tmpLoad)) remove(tmpLoad);
    if (exists(tmpSave)) remove(tmpSave);
    scope(exit) {
        if (exists(tmpLoad)) remove(tmpLoad);
        if (exists(tmpSave)) remove(tmpSave);
    }

    // --- hand-write the input v3d ---
    // Single quad: verts (0,0,0),(1,0,0),(1,1,0),(0,1,0); face [0,1,2,3].
    // 4 loops × 2 = 8 UV floats.  data.length MUST equal loops.length*2 or
    // native.d:626 silently drops the map (→ uv.flip throws "missing map").
    enum string v3d = `{
  "formatVersion": 6,
  "layers": [{
    "name": "UV Test",
    "visible": true,
    "selected": true,
    "mesh": {
      "vertices": [[0,0,0],[1,0,0],[1,1,0],[0,1,0]],
      "faces": [[0,1,2,3]],
      "uvMaps": [{"name":"uv","dim":2,"data":[0.1,0.2,0.9,0.2,0.9,0.8,0.1,0.8]}]
    }
  }]
}`;
    write(tmpLoad, v3d);

    // --- reset + load ---
    post(kBase ~ "/api/reset", "");
    runCmd("file.load", `{"path":"` ~ tmpLoad ~ `"}`);

    // --- apply flip-U about unit ---
    runCmd("uv.flip", `{"axis":"u","pivot":"unit"}`);

    // --- save and inspect the result ---
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave), "expected saved file at " ~ tmpSave);

    auto j = parseJSON(readText(tmpSave));
    assert(j["formatVersion"].integer == 6);
    auto meshJ = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ, "uvMaps must be present after uv.flip");
    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length == 8, format("expected 8 UV floats, got %d", uvData.length));

    // Original u values: [0.1, 0.9, 0.9, 0.1] (at positions 0, 2, 4, 6).
    // After flip-U about 0.5: u' = 1 − u → [0.9, 0.1, 0.1, 0.9].
    // v values at odd positions must be unchanged.
    float[] origU = [0.1f, 0.9f, 0.9f, 0.1f];
    float[] origV = [0.2f, 0.2f, 0.8f, 0.8f];
    foreach (i; 0 .. 4) {
        float gotU = cast(float) uvData[i * 2].floating;
        float gotV = cast(float) uvData[i * 2 + 1].floating;
        float expectU = 1.0f - origU[i];
        assert(feq(gotU, expectU),
            format("corner %d u': expected %g got %g", i, expectU, gotU));
        assert(feq(gotV, origV[i]),
            format("corner %d v: expected %g got %g", i, origV[i], gotV));
    }

    // --- undo and verify restoration ---
    post(kBase ~ "/api/undo", "");

    if (exists(tmpSave)) remove(tmpSave);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave));

    auto j2     = parseJSON(readText(tmpSave));
    auto uvData2 = j2["layers"][0]["mesh"]["uvMaps"][0]["data"].array;
    assert(uvData2.length == 8);
    foreach (i; 0 .. 4) {
        float gotU = cast(float) uvData2[i * 2].floating;
        float gotV = cast(float) uvData2[i * 2 + 1].floating;
        assert(feq(gotU, origU[i]),
            format("undo: corner %d u: expected %g got %g", i, origU[i], gotU));
        assert(feq(gotV, origV[i]),
            format("undo: corner %d v: expected %g got %g", i, origV[i], gotV));
    }
}

// ---------------------------------------------------------------------------
// HTTP: no-op — default cube (no UV map) → uv.flip returns status:error.
// ---------------------------------------------------------------------------
unittest {
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(runCmdRaw(`{"id":"uv.flip"}`));
    assert(resp["status"].str == "error",
           "uv.flip on a mesh without a UV map must return status:error");
}
