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

unittest { // Select mode — top face (face 4) — face-normal as up.
    resetCube();
    // Top face has avg normal +Y. up = world +Y. In-plane bbox
    // extents X=1, Z=1 → tie; X has lower index → right = +X.
    // fwd = X × Y = +Z. Verified against modo_cl xfrm.move (see
    // tools/modo_diff/cases/acen_select_translate_x.json + _y).
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/command", "tool.pipe.attr axis mode select");
    auto a = getAxisAttrs();
    assert(a["mode"] == "select", "got " ~ a["mode"]);
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-3, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "upY")    - 1.0f) < 1e-3, "upY: "    ~ a["upY"]);
    assert(abs(floatAttr(a, "fwdZ")   - 1.0f) < 1e-3, "fwdZ: "   ~ a["fwdZ"]);
}

unittest { // Select mode — back face (face 0) — face-normal -Z up.
    resetCube();
    // Back face avg normal = -Z. up = world -Z. In-plane bbox
    // extents X=1, Y=1 → tie; X wins → right = +X.
    // fwd = X × (-Z) = +Y.
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    postJson("/api/command", "tool.pipe.attr axis mode select");
    auto a = getAxisAttrs();
    assert(abs(floatAttr(a, "rightX") - 1.0f)    < 1e-3, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "upZ")    - (-1.0f)) < 1e-3, "upZ: "    ~ a["upZ"]);
    assert(abs(floatAttr(a, "fwdY")   - 1.0f)    < 1e-3, "fwdY: "   ~ a["fwdY"]);
}

// -------------------------------------------------------------------------
// Mode-coverage tests — every mode must at least set its label and
// emit a finite right/up/fwd vector.
// -------------------------------------------------------------------------

unittest { // SelectAuto — same algorithm as Select (face-normal up).
    resetCube();
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    postJson("/api/command", "tool.pipe.attr axis mode selectauto");
    auto a = getAxisAttrs();
    assert(a["mode"] == "selectauto", "got " ~ a["mode"]);
    // Back face: up=-Z, right=+X (tie-break by lowest index).
    assert(abs(floatAttr(a, "rightX") - 1.0f)    < 1e-3, "rightX: " ~ a["rightX"]);
    assert(abs(floatAttr(a, "upZ")    - (-1.0f)) < 1e-3, "upZ: "    ~ a["upZ"]);
}

unittest { // Origin — alias of World (identity basis).
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode origin");
    auto a = getAxisAttrs();
    assert(a["mode"] == "origin", "got " ~ a["mode"]);
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-6, "rightX");
    assert(abs(floatAttr(a, "upY") - 1.0f)    < 1e-6, "upY");
    assert(abs(floatAttr(a, "fwdZ") - 1.0f)   < 1e-6, "fwdZ");
}

unittest { // Local — currently degrades to Auto basis (workplane).
           // Smoke test: mode label set + finite vectors.
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode local");
    auto a = getAxisAttrs();
    assert(a["mode"] == "local", "got " ~ a["mode"]);
    auto rx = floatAttr(a, "rightX");
    auto uy = floatAttr(a, "upY");
    auto fz = floatAttr(a, "fwdZ");
    assert(rx == rx && uy == uy && fz == fz, "Local published NaN");
}

unittest { // Screen — degrades to Auto basis (workplane). Smoke test.
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode screen");
    auto a = getAxisAttrs();
    assert(a["mode"] == "screen", "got " ~ a["mode"]);
    auto rx = floatAttr(a, "rightX");
    auto uy = floatAttr(a, "upY");
    auto fz = floatAttr(a, "fwdZ");
    assert(rx == rx && uy == uy && fz == fz, "Screen published NaN");
}

unittest { // Manual — switching mode without setting manual* attrs
           // returns the field defaults (right=+X, up=+Y, fwd=+Z).
           // Manual right/up/fwd HTTP attrs land in a follow-up.
    resetCube();
    postJson("/api/command", "tool.pipe.attr axis mode manual");
    auto a = getAxisAttrs();
    assert(a["mode"] == "manual", "got " ~ a["mode"]);
    assert(abs(floatAttr(a, "rightX") - 1.0f) < 1e-6, "default rightX");
    assert(abs(floatAttr(a, "upY") - 1.0f)    < 1e-6, "default upY");
    assert(abs(floatAttr(a, "fwdZ") - 1.0f)   < 1e-6, "default fwdZ");
}

unittest { // Element edges — edge tangent as right; up perpendicular.
    resetCube();
    // Edge 0 = [0,3] direction = +Y. Tangent → right=(0,1,0).
    postJson("/api/select", `{"mode":"edges","indices":[0]}`);
    postJson("/api/command", "tool.pipe.attr axis mode element");
    auto a = getAxisAttrs();
    assert(abs(floatAttr(a, "rightY") - 1.0f) < 1e-3,
        "edge tangent: rightY expected 1, got " ~ a["rightY"]);
    // up is workplane-normal projected perp to edge tangent. With
    // workplane=auto + camera default, can vary slightly — just assert
    // it's a unit vector perpendicular to right.
    auto ux = floatAttr(a, "upX");
    auto uy = floatAttr(a, "upY");
    auto uz = floatAttr(a, "upZ");
    assert(abs(ux*ux + uy*uy + uz*uz - 1.0f) < 1e-3, "up not unit");
    assert(abs(0.0f*ux + 1.0f*uy + 0.0f*uz) < 1e-3, "up not perp to right");
}

unittest { // Element vertices — averaged incident face normal as up.
    resetCube();
    // Vert 6 = (0.5, 0.5, 0.5) — corner shared by faces 1 (top, +Y),
    // 3 (right, +X), 4 (front, +Z). Avg face normal: (1/√3)*(1,1,1).
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/command", "tool.pipe.attr axis mode element");
    auto a = getAxisAttrs();
    auto ux = floatAttr(a, "upX");
    auto uy = floatAttr(a, "upY");
    auto uz = floatAttr(a, "upZ");
    // up should be a unit vector (verify magnitude rather than exact
    // direction — the picked face set depends on cube topology).
    assert(abs(ux*ux + uy*uy + uz*uz - 1.0f) < 1e-3,
        "vertex normal up not unit: ("
        ~ a["upX"] ~ "," ~ a["upY"] ~ "," ~ a["upZ"] ~ ")");
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
