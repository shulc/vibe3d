// test_path_stage.d — HTTP integration tests for the PATH toolpipe stage.
//
// Tests:
//   1. PATH stage appears in /api/toolpipe after registration.
//   2. path.define + enable → /api/path returns expected value/tangent/length.
//   3. Straight 2-vertex path analytic goldens.
//   4. Equal-leg L-shaped 3-vertex path analytic goldens.
//   5. /api/reset clears the source (no -j8 bleed).

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

string postRaw(string path, string body_) {
    return cast(string) post(baseUrl ~ path, body_);
}

void cmd(string c) {
    postJson("/api/command", c);
}

void resetScene() {
    postJson("/api/reset", `{"primitive":"subdivcube"}`);
}

// Load a tiny mesh with known vertex positions via /api/load-mesh.
void loadMesh(float[][] verts, uint[][] faces) {
    import std.array  : appender;
    import std.format : format;
    auto buf = appender!string;
    buf.put(`{"vertices":[`);
    foreach (i, v; verts) {
        if (i > 0) buf.put(",");
        buf.put(format("[%g,%g,%g]", v[0], v[1], v[2]));
    }
    buf.put(`],"faces":[`);
    foreach (i, f; faces) {
        if (i > 0) buf.put(",");
        buf.put("[");
        foreach (j, idx; f) {
            if (j > 0) buf.put(",");
            buf.put(idx.to!string);
        }
        buf.put("]");
    }
    buf.put("]}");
    postJson("/api/load-mesh", buf.data);
}

// Query /api/path at t and return the parsed JSON.
// Use %f to ensure the JSON always contains a decimal point so the server
// parses t as a float (not integer) even at exact integers like 0.0 and 1.0.
JSONValue queryPath(float t) {
    import std.format : format;
    return parseJSON(postRaw("/api/path", format(`{"t":%f}`, t)));
}

// Helper: read a JSON number that may be integer or float type.
// The server uses %f for float fields, so this is mainly a safety net.
float jFloat(JSONValue j) {
    if (j.type == JSONType.integer)  return cast(float)j.integer;
    if (j.type == JSONType.uinteger) return cast(float)j.uinteger;
    return cast(float)j.floating;
}

// -------------------------------------------------------------------------
// 1. PATH stage appears in /api/toolpipe after registration.
// -------------------------------------------------------------------------

unittest { // PATH stage registered
    resetScene();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (s; j["stages"].array) {
        if (s["id"].str == "path") {
            found = true;
            assert(s["task"].str == "PATH",
                   "PATH stage task code should be 'PATH', got " ~ s["task"].str);
            assert(s["ordinal"].integer == 0x80,
                   "PATH ordinal should be 0x80");
            // Verify the top-level enabled field (not attrs.enabled) reflects the
            // inherited Stage.enabled, which PathStage initialises to false.
            assert(s["enabled"].type == JSONType.false_,
                   "/api/toolpipe 'enabled' should be false for PATH stage after reset");
        }
    }
    assert(found, "PATH stage not found in /api/toolpipe");
}

// -------------------------------------------------------------------------
// 2. path.define positional args are delivered.
//    After path.define 0,1, querying with enabled=true must return enabled.
// -------------------------------------------------------------------------

unittest { // path.define delivers verts
    // Use a valid 3-vert mesh (vibe3d requires >= 3-vert faces).
    // Vertex 0=(0,0,0), 1=(2,0,0), 2=(0,0,0) — path uses verts 0 and 1.
    loadMesh([[0,0,0],[2,0,0],[0,0,0]], [[0u,1u,2u]]);
    cmd(`tool.pipe.attr path enabled false`);
    cmd(`path.define "0,1"`);
    cmd(`tool.pipe.attr path enabled true`);
    auto j = queryPath(0.5f);
    assert("enabled" in j.object, "/api/path must have 'enabled' field");
    assert(j["enabled"].type == JSONType.true_,
           "PATH stage should report enabled=true after path.define");
    assert("value" in j.object, "/api/path must have 'value' field when enabled");
    assert(j["value"].array.length == 3, "'value' must be [x,y,z]");
}

// -------------------------------------------------------------------------
// 3. Straight 2-vertex path analytic goldens.
//    Mesh: vert 0=(0,0,0), vert 1=(2,0,0).  Total length = 2.
//    t=0   → (0,0,0)    tangent=(1,0,0)   length=0
//    t=0.5 → (1,0,0)    tangent=(1,0,0)   length=1
//    t=1   → (2,0,0)    tangent=(1,0,0)   length=2
// -------------------------------------------------------------------------

unittest { // straight path goldens
    loadMesh([[0,0,0],[2,0,0],[0,0,0]], [[0u,1u,2u]]);
    cmd(`tool.pipe.attr path enabled false`);
    cmd(`path.define "0,1"`);
    cmd(`tool.pipe.attr path enabled true`);

    enum eps = 1e-4f;
    void chk(float t, float ex, float ey, float ez,
                       float tx_, float ty_, float tz_,
                       float expLen, string tag) {
        auto j = queryPath(t);
        assert(j["enabled"].type == JSONType.true_,
               tag ~ ": expected enabled=true");
        auto v  = j["value"].array;
        auto tv = j["tangent"].array;
        float len = jFloat(j["length"]);
        assert(fabs(jFloat(v[0]) - ex)   < eps, tag ~ ": value.x");
        assert(fabs(jFloat(v[1]) - ey)   < eps, tag ~ ": value.y");
        assert(fabs(jFloat(v[2]) - ez)   < eps, tag ~ ": value.z");
        assert(fabs(jFloat(tv[0]) - tx_) < eps, tag ~ ": tangent.x");
        assert(fabs(jFloat(tv[1]) - ty_) < eps, tag ~ ": tangent.y");
        assert(fabs(jFloat(tv[2]) - tz_) < eps, tag ~ ": tangent.z");
        assert(fabs(len - expLen) < eps,         tag ~ ": length");
    }

    chk(0.0f,  0,0,0,  1,0,0,  0.0f, "straight t=0");
    chk(0.5f,  1,0,0,  1,0,0,  1.0f, "straight t=0.5");
    chk(1.0f,  2,0,0,  1,0,0,  2.0f, "straight t=1");
}

// -------------------------------------------------------------------------
// 4. Equal-leg L-shaped 3-vertex path analytic goldens.
//    Mesh: vert 0=(0,0,0), vert 1=(1,0,0), vert 2=(1,0,1).
//    Leg-0 = 1, leg-1 = 1, total = 2.
//    t=0    → (0,0,0)      tangent=(1,0,0)    length=0
//    t=0.25 → (0.5,0,0)   tangent=(1,0,0)    length=0.5
//    t=0.5  → (1,0,0)      tangent=(1,0,0)    length=1
//    t=0.75 → (1,0,0.5)   tangent=(0,0,1)    length=1.5
//    t=1    → (1,0,1)      tangent=(0,0,1)    length=2
// -------------------------------------------------------------------------

unittest { // L-shaped path goldens
    loadMesh([[0,0,0],[1,0,0],[1,0,1]], [[0u,1u,2u]]);
    cmd(`tool.pipe.attr path enabled false`);
    cmd(`path.define "0,1,2"`);
    cmd(`tool.pipe.attr path enabled true`);

    enum eps = 1e-4f;
    void chk(float t, float ex, float ey, float ez,
                       float tx_, float ty_, float tz_,
                       float expLen, string tag) {
        auto j = queryPath(t);
        assert(j["enabled"].type == JSONType.true_,
               tag ~ ": expected enabled=true");
        auto v  = j["value"].array;
        auto tv = j["tangent"].array;
        float len = jFloat(j["length"]);
        assert(fabs(jFloat(v[0]) - ex)   < eps, tag ~ ": value.x");
        assert(fabs(jFloat(v[1]) - ey)   < eps, tag ~ ": value.y");
        assert(fabs(jFloat(v[2]) - ez)   < eps, tag ~ ": value.z");
        assert(fabs(jFloat(tv[0]) - tx_) < eps, tag ~ ": tangent.x");
        assert(fabs(jFloat(tv[1]) - ty_) < eps, tag ~ ": tangent.y");
        assert(fabs(jFloat(tv[2]) - tz_) < eps, tag ~ ": tangent.z");
        assert(fabs(len - expLen) < eps,         tag ~ ": length");
    }

    chk(0.0f,  0,0,0,       1,0,0,  0.0f, "L t=0");
    chk(0.25f, 0.5f,0,0,    1,0,0,  0.5f, "L t=0.25");
    chk(0.5f,  1,0,0,       1,0,0,  1.0f, "L t=0.5");
    chk(0.75f, 1,0,0.5f,    0,0,1,  1.5f, "L t=0.75");
    chk(1.0f,  1,0,1,       0,0,1,  2.0f, "L t=1");
}

// -------------------------------------------------------------------------
// 5. /api/reset clears the path source (no -j8 cross-test bleed).
// -------------------------------------------------------------------------

unittest { // reset clears path
    // Set up a path first.
    loadMesh([[0,0,0],[2,0,0],[0,0,0]], [[0u,1u,2u]]);
    cmd(`path.define "0,1"`);
    cmd(`tool.pipe.attr path enabled true`);
    // Verify it is live before the reset.
    auto before = queryPath(0.5f);
    assert(before["enabled"].type == JSONType.true_,
           "reset-test: path should be enabled before reset");
    // Reset — PathStage.reset() clears sources + sets enabled=false.
    resetScene();
    // After reset, stage.enabled is false → {"enabled":false}.
    auto after = queryPath(0.5f);
    assert(after["enabled"].type == JSONType.false_,
           "reset-test: path should be disabled after /api/reset");
}
