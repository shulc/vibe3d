// Tests for phase 7.2c: AxisStage skeleton + World / Workplane / Auto
// modes. Verifies the stage is registered, default mode=Auto, and that
// setting AXIS=workplane after WorkplaneStage.alignToSelection emits
// the workplane's basis on state.axis.

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

string[string] getAxisAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "AXIS") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "AXIS stage not found in /api/toolpipe payload");
}

float floatAttr(string[string] attrs, string key) {
    return attrs[key].to!float;
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr workplane mode auto");
    postJson("/api/command", "tool.pipe.attr axis mode auto");
}

// -------------------------------------------------------------------------
// 7.2c: AXIS stage is registered.
// -------------------------------------------------------------------------

unittest { // AXIS stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array)
        if (st["task"].str == "AXIS") { found = true; break; }
    assert(found, "AXIS stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.2c: Default mode = auto.
// -------------------------------------------------------------------------

unittest { // default = auto
    resetCube();
    auto a = getAxisAttrs();
    assert(a["mode"] == "auto", "expected mode=auto, got " ~ a["mode"]);
}

// -------------------------------------------------------------------------
// 7.2c: World mode publishes identity (right=+X, up=+Y, fwd=+Z).
// -------------------------------------------------------------------------

unittest { // World mode
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode world");
    auto a = getAxisAttrs();
    assert(a["mode"] == "world", "expected mode=world, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-6, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "rightY")) < 1e-6, "rightY: " ~ a["rightY"]);
    assert(abs(floatAttr(a, "rightZ")) < 1e-6, "rightZ: " ~ a["rightZ"]);
    assert(abs(floatAttr(a, "upX")) < 1e-6, "upX: " ~ a["upX"]);
    assert(abs(floatAttr(a, "upY") - 1.0f) < 1e-6, "upY: " ~ a["upY"]);
    assert(abs(floatAttr(a, "upZ")) < 1e-6, "upZ: " ~ a["upZ"]);
    assert(abs(floatAttr(a, "fwdX")) < 1e-6, "fwdX: " ~ a["fwdX"]);
    assert(abs(floatAttr(a, "fwdY")) < 1e-6, "fwdY: " ~ a["fwdY"]);
    assert(abs(floatAttr(a, "fwdZ") - 1.0f) < 1e-6, "fwdZ: " ~ a["fwdZ"]);
}

// -------------------------------------------------------------------------
// 7.2c: Workplane mode publishes the workplane's basis. With
// `workplane.edit rotZ:90`, axis1 ≈ (0,-1,0), normal=axis1=(0,-1,0)?
// Actually rotZ:90 sends (1,0,0) to (0,1,0), (0,1,0) to (-1,0,0).
// Let's use worldX preset: rotation = (0,0,-90) — sends Y to X, so
// axis1 = (0,-1,0), normal = (1,0,0), axis2 = (0,0,1).
// -------------------------------------------------------------------------

unittest { // Workplane mode follows WorkplaneStage
    resetCube();
    // World X workplane → normal = +X, axis1 = -Y, axis2 = +Z.
    postJson("/api/command", "tool.pipe.attr workplane mode worldX");
    postJson("/api/command", "tool.pipe.attr axis mode workplane");
    auto a = getAxisAttrs();
    // up = workplane.normal = +X.
    assert(abs(floatAttr(a, "upX") - 1.0f) < 1e-3, "upX: " ~ a["upX"]);
    assert(abs(floatAttr(a, "upY")) < 1e-3, "upY: " ~ a["upY"]);
    assert(abs(floatAttr(a, "upZ")) < 1e-3, "upZ: " ~ a["upZ"]);
    // fwd = workplane.axis2 = +Z (unchanged in worldX preset).
    assert(abs(floatAttr(a, "fwdZ") - 1.0f) < 1e-3, "fwdZ: " ~ a["fwdZ"]);
}

// -------------------------------------------------------------------------
// 7.2e: Element mode — basis from selected face's normal. Top face
// (face 4) of the default cube has normal +Y, so up=(0,1,0). Right
// is a tangent in the face plane (one of the face edges projected
// perp to up).
// -------------------------------------------------------------------------

unittest { // Element mode — face normal as up
    resetCube();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/command", "tool.pipe.attr axis mode element");
    auto a = getAxisAttrs();
    assert(a["mode"] == "element", "expected element, got " ~ a["mode"]);
    // Top face normal = +Y.
    assert(abs(floatAttr(a, "upX")) < 1e-3, "upX: " ~ a["upX"]);
    assert(abs(floatAttr(a, "upY") - 1.0f) < 1e-3, "upY: " ~ a["upY"]);
    assert(abs(floatAttr(a, "upZ")) < 1e-3, "upZ: " ~ a["upZ"]);
    // Right + fwd should be unit vectors perpendicular to up. Spot-check
    // their length.
    auto rx = floatAttr(a, "rightX");
    auto ry = floatAttr(a, "rightY");
    auto rz = floatAttr(a, "rightZ");
    assert(abs(rx*rx + ry*ry + rz*rz - 1.0f) < 1e-3,
        "right not unit: (" ~ a["rightX"] ~ "," ~ a["rightY"] ~ "," ~ a["rightZ"] ~ ")");
    // Up · right ≈ 0 (orthogonal).
    assert(abs(0.0f*rx + 1.0f*ry + 0.0f*rz) < 1e-3,
        "up not perpendicular to right");
}

// -------------------------------------------------------------------------
// 7.2e+: Select mode — bbox-extent-sort. Map: largest extent → right,
// middle → up, smallest → fwd; fwd = cross(right, up) (always right-
// handed). Verified against MODO Selection auto-axis behaviour.
// -------------------------------------------------------------------------

unittest { // Select mode — selecting top face (y=0.5) of unit cube
    resetCube();
    // Top face = [3,7,6,2]; bbox spans X=1, Y=0, Z=1 → extents
    // (1, 0, 1). Tie between X and Z: stable sort keeps X first.
    // Result: right=X (largest, X picked first on tie), up=Z,
    // fwd = X×Z = -Y.
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/command", "tool.pipe.attr axis mode select");
    auto a = getAxisAttrs();
    assert(a["mode"] == "select", "got " ~ a["mode"]);
    // right = X (1,0,0)
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-3, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "rightY")) < 1e-3, "rightY: " ~ a["rightY"]);
    assert(abs(floatAttr(a, "rightZ")) < 1e-3, "rightZ: " ~ a["rightZ"]);
    // up = Z (0,0,1)
    assert(abs(floatAttr(a, "upZ") - 1.0f) < 1e-3, "upZ: " ~ a["upZ"]);
    // fwd = right×up = X×Z = -Y → (0,-1,0)
    assert(abs(floatAttr(a, "fwdY") - (-1.0f)) < 1e-3, "fwdY: " ~ a["fwdY"]);
}

unittest { // Select mode — back face (z=-0.5) gives extents (1,1,0)
    resetCube();
    // Face 0 = back, verts at z=-0.5; X-extent=1, Y=1, Z=0.
    // Tie X vs Y: X wins → right=X. Y → up. fwd = X×Y = Z.
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    postJson("/api/command", "tool.pipe.attr axis mode select");
    auto a = getAxisAttrs();
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-3, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "upY") - 1.0f) < 1e-3, "upY: " ~ a["upY"]);
    assert(abs(floatAttr(a, "fwdZ") - 1.0f) < 1e-3, "fwdZ: " ~ a["fwdZ"]);
}

// -------------------------------------------------------------------------
// 7.2c: Unknown mode rejected.
// -------------------------------------------------------------------------

unittest { // unknown mode rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode world");
    auto before = getAxisAttrs();
    postJson("/api/command", "tool.pipe.attr axis mode flubber");
    auto after = getAxisAttrs();
    assert(before["mode"] == after["mode"],
        "Unknown mode should leave state unchanged: was "
        ~ before["mode"] ~ ", now " ~ after["mode"]);
}
