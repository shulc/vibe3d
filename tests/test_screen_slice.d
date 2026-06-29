// test_screen_slice.d — HTTP tests for mesh.screenSlice command.
//
// Standard cube from /api/reset (8 verts, 6 quad faces, ±0.5 on each axis).
//
// Camera: azimuth=0, elevation=0, distance=5, focus=(0,0,0).
// Under this view the eye is at (0,0,5) looking straight down –Z.
// The actual viewport dimensions (width, height, vpX, vpY) are read back
// from /api/camera after the async apply, rather than hardcoded, so the
// test adapts to whatever GL panel size vibe3d uses at startup.
//
// Test cases:
//   1. Vertical center line: ax==bx==viewport_center_x; both rays have
//      world-X = 0 → cross(dA,dB) ∥ world X → plane x=0 → 10 faces / 12
//      verts, all quads, 0 orphans, 0 duplicate positions.
//      Then undo → 6 faces / 8 verts.
//   2. Short-line no-op: nearly-coincident endpoints → command returns
//      non-ok, mesh stays at 6/8.  Verify no extra undo entry is pushed:
//      real cut → no-op → single undo → original 6/8.
//
// NOTE: params are sent nested under "params" key (wire format required by
// the HTTP dispatcher for JSON commands with a Param[] schema), e.g.:
//   {"id":"mesh.screenSlice","params":{"ax":475,"ay":82,"bx":475,"by":518}}
//
// The authoritative T-junction (index-share) check lives in mesh.d unittests.
// Here we use the position-duplicate backstop from test_axis_slice.d.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// Helpers (mirrors test_axis_slice.d)
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

long vertCount(JSONValue m) { return m["vertexCount"].integer; }

size_t faceCount(JSONValue m) { return m["faces"].array.length; }

int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length]++;
    return h;
}

int[] orphanVerts(JSONValue m) {
    bool[] refd;
    refd.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < refd.length) refd[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. refd.length) if (!refd[i]) orph ~= cast(int)i;
    return orph;
}

size_t duplicatePositionVerts(JSONValue m) {
    import std.format : format;
    string[string] seen;
    size_t count;
    if ("vertices" !in m.object) return 0;
    foreach (i, v; m["vertices"].array) {
        auto arr = v.array;
        string key = format("%.9f,%.9f,%.9f",
            arr[0].floating, arr[1].floating, arr[2].floating);
        if (key in seen) count++;
        else seen[key] = i.to!string;
    }
    return count;
}

// Reset to default cube and switch to vertex mode (ensures SubjectPacket delivery).
void loadCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
    auto s = postCmd("/api/select", `{"mode":"vertices","indices":[]}`);
    assert(s["status"].str == "ok", "/api/select failed");
}

// POST /api/camera (az, el, dist, focus at origin) and wait for the main-
// thread tick to apply it (the camera POST blocks until the main thread
// processes it).  Returns the current camera state — importantly, the REAL
// viewport dimensions (width/height/vpX/vpY) which the main render loop
// owns and overrides every frame; these differ from any width/height we POST.
JSONValue setCamera(float az, float el, float dist) {
    import std.format : format;
    string body_ = format(
        `{"azimuth":%f,"elevation":%f,"distance":%f,"focus":{"x":0,"y":0,"z":0}}`,
        az, el, dist);
    postCmd("/api/camera", body_);
    return parseJSON(cast(string)get(BASE ~ "/api/camera"));
}

void runCommand(string id) {
    auto r = postCmd("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        id ~ " failed: " ~ r.toString);
}

// Run mesh.screenSlice with the nested params wire format.
void runScreenSlice(float ax, float ay, float bx, float by) {
    import std.format : format;
    auto r = postCmd("/api/command", format(
        `{"id":"mesh.screenSlice","params":{"ax":%g,"ay":%g,"bx":%g,"by":%g}}`,
        ax, ay, bx, by));
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "mesh.screenSlice failed: " ~ r.toString);
}

JSONValue runScreenSliceRaw(float ax, float ay, float bx, float by) {
    import std.format : format;
    return postCmd("/api/command", format(
        `{"id":"mesh.screenSlice","params":{"ax":%g,"ay":%g,"bx":%g,"by":%g}}`,
        ax, ay, bx, by));
}

// ---------------------------------------------------------------------------
// Test 1: vertical center line → plane x=0 → 10 faces / 12 verts
// ---------------------------------------------------------------------------

unittest { // screenSlice vertical center line: 4 side faces split → 10 faces, 12 verts
    loadCube();

    // Camera at azimuth=0, elevation=0 → eye=(0,0,5), looking straight down –Z.
    // The camera POST blocks until the main thread applies it; no extra sleep
    // needed. The GET reads back the REAL viewport dimensions (the main render
    // loop owns width/height/vpX/vpY and updates them each frame).
    auto cam = setCamera(0, 0, 5);
    float vpX = cam["vpX"].type == JSONType.integer
        ? cast(float)cam["vpX"].integer : cast(float)cam["vpX"].floating;
    float vpY = cam["vpY"].type == JSONType.integer
        ? cast(float)cam["vpY"].integer : cast(float)cam["vpY"].floating;
    float vpW = cam["width"].type == JSONType.integer
        ? cast(float)cam["width"].integer : cast(float)cam["width"].floating;
    float vpH = cam["height"].type == JSONType.integer
        ? cast(float)cam["height"].integer : cast(float)cam["height"].floating;

    assert(vpW > 0 && vpH > 0, "viewport must have positive dimensions");

    // Vertical center line: ax==bx==center of viewport in window coords.
    // Both rays have nx=0 (center NDC) → world-X component = 0 → the cross
    // product of the two rays lies along world X → plane x=0 cuts the cube.
    float cx    = vpX + vpW * 0.5f;
    float lineAy = vpY + vpH * 0.1f;   // 10% from top
    float lineBy = vpY + vpH * 0.9f;   // 90% from top (long enough line)

    runScreenSlice(cx, lineAy, cx, lineBy);

    auto m1 = model();
    assert(faceCount(m1) == 10,
        "expected 10 faces after screen slice, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 12,
        "expected 12 verts after screen slice, got " ~ vertCount(m1).to!string);
    assert(fvDist(m1).get(4, 0) == 10, "all 10 faces must be quads");
    assert(orphanVerts(m1).length == 0, "no orphan vertices after cut");
    assert(duplicatePositionVerts(m1) == 0,
        "no duplicate vertex positions (T-junction backstop)");

    // Undo must restore the original cube.
    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// Test 2: degenerate short-line → no-op, no extra undo entry
// ---------------------------------------------------------------------------

unittest { // screenSlice short-line no-op: mesh unchanged, no undo entry pushed
    loadCube();
    auto cam = setCamera(0, 0, 5);
    float vpX = cam["vpX"].type == JSONType.integer
        ? cast(float)cam["vpX"].integer : cast(float)cam["vpX"].floating;
    float vpY = cam["vpY"].type == JSONType.integer
        ? cast(float)cam["vpY"].integer : cast(float)cam["vpY"].floating;
    float vpW = cam["width"].type == JSONType.integer
        ? cast(float)cam["width"].integer : cast(float)cam["width"].floating;
    float vpH = cam["height"].type == JSONType.integer
        ? cast(float)cam["height"].integer : cast(float)cam["height"].floating;
    float cx = vpX + vpW * 0.5f;
    float cy = vpY + vpH * 0.5f;

    // --- Part A: nearly-coincident endpoints → command must fail/no-op. ---
    // Distance ≈ 0.28 px (sqrt(0.2²+0.2²)) < pixelEps default of 1.0.
    auto ra = runScreenSliceRaw(cx, cy, cx + 0.2f, cy + 0.2f);
    bool isOk = (ra["status"].str == "ok" || ra["status"].str == "success");
    assert(!isOk, "sub-pixel line must be a no-op, got: " ~ ra.toString);

    auto ma = model();
    assert(faceCount(ma) == 6, "no-op must leave 6 faces");
    assert(vertCount(ma)  == 8, "no-op must leave 8 verts");

    // --- Part B: verify no undo entry was pushed. ---
    // Strategy: do a real cut (1 undo entry), then the no-op (0 entries),
    // then a single undo.  If the no-op had pushed an entry, one undo only
    // undoes it and we'd still have 10 faces.  If nothing was pushed, one
    // undo restores the original 6-face cube.
    float lineAy = vpY + vpH * 0.1f;
    float lineBy = vpY + vpH * 0.9f;
    runScreenSlice(cx, lineAy, cx, lineBy);
    auto mb = model();
    assert(faceCount(mb) == 10, "real cut must produce 10 faces");

    // No-op (should push nothing onto the undo stack).
    runScreenSliceRaw(cx, cy, cx + 0.2f, cy + 0.2f);

    // Single undo must reach the original cube, not just "undo" the no-op.
    runCommand("history.undo");
    auto mc = model();
    assert(faceCount(mc) == 6,
        "single undo after no-op must restore original cube (6 faces), got " ~
        faceCount(mc).to!string);
    assert(vertCount(mc) == 8,
        "single undo after no-op must restore 8 verts, got " ~
        vertCount(mc).to!string);
}
