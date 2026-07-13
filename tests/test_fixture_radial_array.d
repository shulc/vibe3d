// Golden parity fixture for RadialArrayTool (interactive tool, factory id
// `mesh.radialArrayTool`) — task 0356.
//
// The golden (tests/fixtures/radial_array.json) is frozen from a captured
// reference-editor session (toolcards/radial_array/capture/parity_case1_
// {before,after}.json in the private task worktree) — NOT replayed against
// any external engine here. Only the counts and the corrected Offset step
// law (offset/(count-1), not a flat offset-per-clone) are pulled from that
// capture; vertex ORDER is vibe3d-native, so this test asserts counts +
// specific-position existence checks rather than an ordered vertex array —
// same methodology tests/test_mesh_radial_array.d already uses for the
// one-shot mesh.radial_array command.
//
// Covers:
//   1. Headless tool session (tool.set on / tool.attr .../ tool.doApply)
//      reproduces the captured parity case's counts and Y-step law.
//   2. Undo restores the pre-array cube.
//   3. Tool <-> one-shot-command parity: the interactive tool and
//      `mesh.radial_array` (same params, translated to its native units)
//      produce identical vertex/face counts — both are thin wrappers over
//      the same `Mesh.radialArrayFaces` kernel.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, PI;

import fixture_helpers : requireProvenance;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postCommand(string body_) {
    auto resp = post("http://localhost:8080/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }

bool approxEq(double a, double b, double eps = 1e-4) { return abs(a - b) < eps; }

int countVertsAtY(JSONValue m, double y) {
    int n = 0;
    foreach (v; m["vertices"].array)
        if (approxEq(v.array[1].floating, y)) ++n;
    return n;
}

private JSONValue fixture() {
    enum string json = import("fixtures/radial_array.json");
    auto fx = parseJSON(json);
    requireProvenance(fx, "radial_array");
    return fx;
}

// ---------------------------------------------------------------------------
// TEST 1: Headless tool path matches the captured parity case.
// ---------------------------------------------------------------------------

unittest { // HeadlessToolMatchesReferenceCapture
    auto fx = fixture();
    auto p  = fx["params"];

    resetCube();
    postSelect("polygons", [4]);   // top face (4 verts at y=0.5) — vibe3d's own cube layout

    auto before = getModel();
    assert(before["vertices"].array.length == fx["before"]["vertexCount"].integer,
        "before verts: expected " ~ fx["before"]["vertexCount"].toString ~
        ", got " ~ before["vertices"].array.length.to!string);
    assert(before["faces"].array.length == fx["before"]["faceCount"].integer,
        "before faces: expected " ~ fx["before"]["faceCount"].toString ~
        ", got " ~ before["faces"].array.length.to!string);

    postCommand("tool.set mesh.radialArrayTool on");
    postCommand("tool.attr mesh.radialArrayTool count " ~ p["count"].integer.to!string);
    postCommand("tool.attr mesh.radialArrayTool axis " ~ p["axis"].str);
    postCommand("tool.attr mesh.radialArrayTool angle " ~ p["angle_deg"].integer.to!string);
    postCommand("tool.attr mesh.radialArrayTool offset " ~ p["offset"].floating.to!string);
    postCommand("tool.attr mesh.radialArrayTool weld " ~ p["weld"].floating.to!string);
    postCommand("tool.doApply");

    auto after = getModel();
    assert(after["vertices"].array.length == fx["after"]["vertexCount"].integer,
        "after verts: expected " ~ fx["after"]["vertexCount"].toString ~
        ", got " ~ after["vertices"].array.length.to!string);
    assert(after["faces"].array.length == fx["after"]["faceCount"].integer,
        "after faces: expected " ~ fx["after"]["faceCount"].toString ~
        ", got " ~ after["faces"].array.length.to!string);

    // Offset step law: 4 verts at each of y=0.6/0.7/0.8 (one ring per new
    // clone) — offset/(count-1) = 0.3/3 = 0.1 per step, NOT a flat 0.3.
    foreach (yWant; fx["yStepsPresent"].array) {
        int n = countVertsAtY(after, yWant.floating);
        assert(n == 4,
            "expected 4 verts at y=" ~ yWant.floating.to!string ~
            ", got " ~ n.to!string);
    }
    // The original top face survives untouched (Replace Source = off).
    double origY = fx["originalTopFaceY"].floating;
    assert(countVertsAtY(after, origY) == 4,
        "original top-face verts should survive at y=" ~ origY.to!string);
}

// ---------------------------------------------------------------------------
// TEST 2: Undo restores the pre-array cube.
// ---------------------------------------------------------------------------

unittest { // HeadlessToolUndo
    auto fx = fixture();
    auto p  = fx["params"];

    resetCube();
    postSelect("polygons", [4]);

    postCommand("tool.set mesh.radialArrayTool on");
    postCommand("tool.attr mesh.radialArrayTool count " ~ p["count"].integer.to!string);
    postCommand("tool.attr mesh.radialArrayTool angle " ~ p["angle_deg"].integer.to!string);
    postCommand("tool.attr mesh.radialArrayTool offset " ~ p["offset"].floating.to!string);
    postCommand("tool.doApply");
    assert(getModel()["faces"].array.length == fx["after"]["faceCount"].integer,
        "HeadlessToolUndo: after apply");

    postUndo();
    auto undone = getModel();
    assert(undone["vertices"].array.length == fx["before"]["vertexCount"].integer,
        "HeadlessToolUndo: after undo expected " ~ fx["before"]["vertexCount"].toString ~
        " verts, got " ~ undone["vertices"].array.length.to!string);
    assert(undone["faces"].array.length == fx["before"]["faceCount"].integer,
        "HeadlessToolUndo: after undo expected " ~ fx["before"]["faceCount"].toString ~
        " faces, got " ~ undone["faces"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// TEST 3: Tool <-> one-shot-command parity. Both wrap the same
// Mesh.radialArrayFaces kernel; the tool's Offset (total span) translates
// to the command's extra_step_translate (per-step) via /(count-1).
// ---------------------------------------------------------------------------

unittest { // ToolCommandParity
    auto fx = fixture();
    auto p  = fx["params"];
    int    count  = cast(int)p["count"].integer;
    double angleDeg = p["angle_deg"].integer;
    double offset  = p["offset"].floating;
    double stepY   = offset / (count - 1);

    // One-shot command result (native units: radians + per-step translate).
    resetCube();
    postSelect("polygons", [4]);
    postCommand(`{"id":"mesh.radial_array","params":{
        "count":` ~ count.to!string ~ `,"axis":"Y","center":[0,0,0],
        "total_angle":` ~ (angleDeg * PI / 180.0).to!string ~ `,
        "extra_step_translate":[0,` ~ stepY.to!string ~ `,0],"weld":0
    }}`);
    auto cmdModel = getModel();
    size_t cmdVerts = cmdModel["vertices"].array.length;
    size_t cmdFaces = cmdModel["faces"].array.length;

    // Interactive tool result (degrees + total-span offset).
    resetCube();
    postSelect("polygons", [4]);
    postCommand("tool.set mesh.radialArrayTool on");
    postCommand("tool.attr mesh.radialArrayTool count " ~ count.to!string);
    postCommand("tool.attr mesh.radialArrayTool angle " ~ angleDeg.to!string);
    postCommand("tool.attr mesh.radialArrayTool offset " ~ offset.to!string);
    postCommand("tool.doApply");
    auto toolModel = getModel();
    size_t toolVerts = toolModel["vertices"].array.length;
    size_t toolFaces = toolModel["faces"].array.length;

    assert(cmdVerts == toolVerts,
        "ToolCommandParity: command " ~ cmdVerts.to!string ~
        " verts vs tool " ~ toolVerts.to!string);
    assert(cmdFaces == toolFaces,
        "ToolCommandParity: command " ~ cmdFaces.to!string ~
        " faces vs tool " ~ toolFaces.to!string);
}

// ---------------------------------------------------------------------------
// TEST 4: `count` DoS clamp (review fix). A scripted `tool.attr ... count
// <huge>` must NOT synchronously allocate `count * selectedFaceCount`
// verts/faces (an easy OOM/hang) — the Param's `.max(256).enforceBounds()`
// clamps the STORED field itself (not just the derived geometry), and
// Mesh.radialArrayFaces clamps internally too as a defense-in-depth backstop
// for any caller that reaches the kernel a different way (e.g. the one-shot
// mesh.radial_array command). Verifies BOTH: the read-back `?` query sees
// the clamped stored value, and the applied geometry matches count=256
// exactly (not a partial/degenerate result and not the raw huge request).
// ---------------------------------------------------------------------------

unittest { // CountDosClamp
    resetCube();
    postSelect("polygons", [4]);   // top face

    postCommand("tool.set mesh.radialArrayTool on");
    postCommand("tool.attr mesh.radialArrayTool count 100000000");

    // Stored field is clamped by the Param itself, not just the eventual
    // kernel output — a write-then-query round-trip proves that.
    auto q = parseJSON(post("http://localhost:8080/api/command",
        "tool.attr mesh.radialArrayTool count ?"));
    assert(q["status"].str == "ok",
        "count query failed: " ~ q.toString);
    assert(q["value"].integer == 256,
        "count should clamp to 256, got " ~ q["value"].toString);

    // A full 360-degree apply at the clamped count must complete promptly
    // (the point of the fix — no hang/OOM) and produce EXACTLY the
    // count=256 topology, not a partial result from the unclamped request:
    // 6 original faces (unchanged count) + (256-1) new one-face clones;
    // 8 original verts + (256-1)*4 new (unwelded) clone verts.
    postCommand("tool.attr mesh.radialArrayTool angle 360");
    postCommand("tool.doApply");
    auto m = getModel();
    assert(m["faces"].array.length == 6 + 255,
        "clamped apply: expected " ~ (6 + 255).to!string ~
        " faces, got " ~ m["faces"].array.length.to!string);
    assert(m["vertices"].array.length == 8 + 255 * 4,
        "clamped apply: expected " ~ (8 + 255 * 4).to!string ~
        " verts, got " ~ m["vertices"].array.length.to!string);
}
