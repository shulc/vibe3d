// Tests for CONS constraint projection (Stage 3 + Stage 4).
//
// Stage 3: /api/constrain bridge — evaluate pipeline + project explicit pos.
// Stage 4: background-source wiring + point-mode headless tool.doApply.
//
// Covered scenarios:
//
//   1. /api/constrain with no background layers → projected:false, pos unchanged.
//   2. /api/constrain with constrain disabled → projected:false, pos unchanged.
//   3. /api/constrain with background plane layer → projected:true, Y≈0.
//   4. /api/constrain geometry=off with background present → projected:false.
//   5. Headless tool.doApply: move vertex up by TY=5 with CONS enabled + background
//      plane → vertex projected back to Y≈0.
//
// Background plane geometry: two triangles covering X=[-10,10], Z=[-10,10] at Y=0.
//   Vertices: [0]=(-10,0,-10) [1]=(10,0,-10) [2]=(10,0,10) [3]=(-10,0,10)
//   Faces:    [[0,1,2],[0,2,3]]
// This is large enough to catch any reasonable foreground vertex position
// projected straight down onto it.

import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format: format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

void resetScene() {
    postJson("/api/reset", `{"primitive":"cube"}`);
}

// Install a large flat plane at Y=0 on the CURRENTLY ACTIVE layer by
// directly uploading a mesh via /api/load-mesh.
void loadBackgroundPlane() {
    // Two triangles covering X∈[-10,10], Z∈[-10,10] at Y=0.
    // Vertices: [0]=(-10,0,-10) [1]=(10,0,-10) [2]=(10,0,10) [3]=(-10,0,10)
    // Faces: [[0,1,2],[0,2,3]]  — both CCW viewed from +Y
    string body_ = `{
        "vertices":[[-10,0,-10],[10,0,-10],[10,0,10],[-10,0,10]],
        "faces":[[0,1,2],[0,2,3]]
    }`;
    auto r = postJson("/api/load-mesh", body_);
    assert(r["status"].str == "ok",
        "load-mesh failed: " ~ r.toString);
}

// Build a two-layer scene:
//   Layer A (index 0): standard cube (foreground = primary).
//   Layer B (index 1): large flat plane at Y=0 (background = visible+deselected).
// Returns with layer A as primary, CONS still at defaults.
void buildTwoLayerScene() {
    resetScene();                          // layer A = cube, primary
    cmd("layer.add name:Plane");           // layer B active (empty)
    loadBackgroundPlane();                 // layer B = flat Y=0 plane
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");           // A primary, B deselected → background
}

// Probe /api/constrain directly. Returns the full JSON response.
JSONValue probeConstrain(double[3] pos, double[3] delta = [0, 0, 0]) {
    string body_ = format(
        `{"pos":[%f,%f,%f],"delta":[%f,%f,%f]}`,
        pos[0], pos[1], pos[2],
        delta[0], delta[1], delta[2]);
    return postJson("/api/constrain", body_);
}

bool approx(double a, double b, double eps = 1e-2) { return fabs(a - b) < eps; }

// -------------------------------------------------------------------------
// Stage 3: /api/constrain bridge — single layer, no background sources.
// -------------------------------------------------------------------------

unittest { // no background → projected:false, pos unchanged
    resetScene();   // single layer, CONS defaults (disabled)
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    assert(r["projected"].boolean == false,
        "single-layer: expected projected:false; got " ~ r.toString);
    auto rp = r["resultPos"].array;
    assert(approx(rp[0].floating, 0.5) &&
           approx(rp[1].floating, 2.0) &&
           approx(rp[2].floating, 0.5),
        "single-layer: resultPos should be unchanged; got " ~ r.toString);
}

// -------------------------------------------------------------------------
// Stage 3: /api/constrain bridge — constrain disabled with background.
// -------------------------------------------------------------------------

unittest { // constrain disabled → projected:false even with a background layer
    buildTwoLayerScene();
    // CONS enabled=false (default) — no projection expected
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    assert(r["projected"].boolean == false,
        "disabled CONS: expected projected:false; got " ~ r.toString);
}

// -------------------------------------------------------------------------
// Stage 3: /api/constrain bridge — geometry=off with background + enabled.
// -------------------------------------------------------------------------

unittest { // geometry=off → no projection even when enabled
    buildTwoLayerScene();
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry off");
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    assert(r["projected"].boolean == false,
        "geometry=off: expected projected:false; got " ~ r.toString);
}

// -------------------------------------------------------------------------
// Stage 3: /api/constrain bridge — point mode with background plane.
// -------------------------------------------------------------------------

unittest { // background plane + enabled → Y projected to 0
    buildTwoLayerScene();
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry point");
    // Query with a point above the centre of the plane at Y=2.
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    assert(r["projected"].boolean == true,
        "point mode + bg: expected projected:true; got " ~ r.toString);
    auto rp = r["resultPos"].array;
    // X and Z should be preserved (nearest foot on a flat Y=0 plane);
    // Y should collapse to ≈0.
    assert(approx(rp[0].floating, 0.5, 1e-2),
        "projected X should be ≈0.5; got " ~ rp[0].toString);
    assert(approx(rp[1].floating, 0.0, 0.02),
        "projected Y should be ≈0 (on the plane); got " ~ rp[1].toString);
    assert(approx(rp[2].floating, 0.5, 1e-2),
        "projected Z should be ≈0.5; got " ~ rp[2].toString);
}

// -------------------------------------------------------------------------
// Stage 3: /api/constrain bridge — vector/screen modes are identity (no-op).
// -------------------------------------------------------------------------

unittest { // vector mode → identity (capture-gated)
    buildTwoLayerScene();
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry vector");
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    // vector mode is a no-op; resultPos should equal input pos
    auto rp = r["resultPos"].array;
    assert(approx(rp[1].floating, 2.0, 0.05),
        "vector mode: Y should be unchanged (2.0); got " ~ rp[1].toString);
}

unittest { // screen mode → identity (capture-gated)
    buildTwoLayerScene();
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry screen");
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    auto rp = r["resultPos"].array;
    assert(approx(rp[1].floating, 2.0, 0.05),
        "screen mode: Y should be unchanged (2.0); got " ~ rp[1].toString);
}

// -------------------------------------------------------------------------
// Stage 4: headless tool.doApply — vertex projected onto background plane.
//
// Recipe:
//   1. Build two-layer scene (A=cube, B=flat plane at Y=0, B is background).
//   2. Select vertex 0 of layer A (default cube v0 ≈ (-0.5, -0.5, -0.5)).
//   3. Enable CONS (geometry=point).
//   4. Activate xfrm.move; set TY=5.0 (would move v0 to Y≈4.5 pre-CONS).
//   5. tool.doApply — applyTRS runs, CONS post-pass projects v0 onto Y=0 plane.
//   6. Assert v0.Y ≈ 0 (collapsed onto the plane), not ≈4.5 (raw move).
//
// Teleport-guard negative control: ALL OTHER unselected vertices start at
// baseline and remain there (they have w=0 in the falloff-less full-mesh
// path), so they must NOT be yanked to Y=0.
// -------------------------------------------------------------------------

// Read vertex positions from the active layer via /api/model.
double[3][] readActiveVerts() {
    auto j = getJson("/api/model");
    double[3][] result;
    foreach (v; j["vertices"].array) {
        auto coords = v.array;
        result ~= [coords[0].floating, coords[1].floating, coords[2].floating];
    }
    return result;
}

// Select a single vertex by index using /api/select.
void selectVert(int idx) {
    auto r = postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idx.to!string ~ `]}`);
    assert(r["status"].str == "ok", "selectVert failed: " ~ r.toString);
}

unittest { // headless doApply: moved vertex lands on background plane
    buildTwoLayerScene();

    // Enable CONS on the toolpipe (geometry=point, default).
    cmd("tool.pipe.attr constrain enabled true");

    // Activate xfrm.move and select vertex 0 of layer A.
    cmd("tool.set move");
    selectVert(0);

    // Record v0 and all other verts before the apply.
    auto vertsBefore = readActiveVerts();
    assert(vertsBefore.length >= 8, "expected cube (8 verts)");

    // Set a large TY so without CONS v0 would move to Y≈4.5.
    // With CONS enabled + background plane at Y=0, v0 must land at Y≈0.
    cmd("tool.attr move TY 5.0");
    cmd("tool.doApply");

    auto vertsAfter = readActiveVerts();
    assert(vertsAfter.length == vertsBefore.length,
        "vertex count changed after doApply");

    // v0 should have been projected to Y≈0, not left at Y≈4.5.
    double v0y = vertsAfter[0][1];
    assert(approx(v0y, 0.0, 0.05),
        "v0.Y after CONS doApply should be ≈0; got " ~ v0y.to!string);

    // Teleport-guard: remaining vertices must NOT have been yanked.
    // Their Y values must still match their pre-apply positions
    // (they were not selected, so they are at baseline = unmodified).
    foreach (i; 1 .. vertsAfter.length) {
        double yBefore = vertsBefore[i][1];
        double yAfter  = vertsAfter[i][1];
        assert(approx(yAfter, yBefore, 0.01),
            "vertex " ~ i.to!string
            ~ " should not have been yanked: before=" ~ yBefore.to!string
            ~ " after=" ~ yAfter.to!string);
    }
}

// -------------------------------------------------------------------------
// Stage 4: /api/reset clears CONS state between tests.
// -------------------------------------------------------------------------

unittest { // /api/reset after a two-layer CONS test leaves only 1 layer, CONS disabled
    buildTwoLayerScene();
    cmd("tool.pipe.attr constrain enabled true");
    resetScene();
    // Should be back to single layer with CONS disabled.
    auto j = getJson("/api/layers");
    assert(j["layers"].array.length == 1,
        "after reset: expected 1 layer, got " ~ j["layers"].array.length.to!string);
    // /api/constrain probe must return projected:false (no bg + CONS disabled).
    auto r = probeConstrain([0.5, 2.0, 0.5]);
    assert(r["projected"].boolean == false,
        "after reset: expected projected:false; got " ~ r.toString);
}
