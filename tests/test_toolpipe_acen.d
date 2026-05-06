// Tests for phase 7.2a: ActionCenterStage skeleton + Auto / Select /
// SelectAuto / Origin modes.
//
// Verifies:
// - The ACEN stage is registered by default at TaskCode.Acen.
// - Default mode = auto; cenX/Y/Z reflect mesh-or-selection centroid.
// - tool.pipe.attr actionCenter mode <X> switches modes.
// - Origin mode publishes (0,0,0) regardless of selection.
// - Select sub-mode (top/bottom/...) returns bbox extreme positions.
// - Unknown mode / sub-mode strings are rejected.

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

// Walk the /api/toolpipe stages array and return the ACEN stage's
// attrs as a string→string map.
string[string] getAcenAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "ACEN") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "ACEN stage not found in /api/toolpipe payload");
}

float floatAttr(string[string] attrs, string key) {
    return attrs[key].to!float;
}

// Reset to a known starting point: cube primitive + empty selection.
void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
}

// -------------------------------------------------------------------------
// 7.2a: ACEN stage is registered.
// -------------------------------------------------------------------------

unittest { // ACEN stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array)
        if (st["task"].str == "ACEN") { found = true; break; }
    assert(found, "ACEN stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.2a: Default mode is auto. Empty selection ⇒ centroid is whole-mesh
// centroid. The default cube spans [-0.5..+0.5] on each axis ⇒ centroid
// at origin.
// -------------------------------------------------------------------------

unittest { // default = auto, centroid at origin for default cube
    resetCube();
    auto a = getAcenAttrs();
    assert(a["mode"] == "auto", "expected mode=auto, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "cenX")) < 1e-4, "cenX != 0: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-4, "cenY != 0: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-4, "cenZ != 0: " ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// 7.2a: With a face selected, Auto centroid follows the selected face's
// centroid (mesh.selectionCentroidFaces returns the avg of selected
// face's vertices). For face 0 of the unit cube — verts 0,3,2,1 at
// y=-0.5 — centroid sits at (0,-0.5,0).
// -------------------------------------------------------------------------

unittest { // Auto follows selection centroid
    resetCube();
    // Select face 0 (back face of default cube — verts 0,3,2,1 all
    // at z=-0.5; centroid sits at (0,0,-0.5)).
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenZ") - (-0.5f)) < 1e-3,
        "Auto+selection cenZ expected -0.5, got " ~ a["cenZ"]);
    assert(abs(floatAttr(a, "cenX")) < 1e-3, "cenX != 0: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY")) < 1e-3, "cenY != 0: " ~ a["cenY"]);
}

// -------------------------------------------------------------------------
// 7.2a: Origin mode = (0,0,0) regardless of selection.
// -------------------------------------------------------------------------

unittest { // Origin mode
    resetCube();
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode origin");
    auto a = getAcenAttrs();
    assert(a["mode"] == "origin", "mode != origin: " ~ a["mode"]);
    assert(abs(floatAttr(a, "cenX")) < 1e-6 &&
           abs(floatAttr(a, "cenY")) < 1e-6 &&
           abs(floatAttr(a, "cenZ")) < 1e-6,
        "Origin mode must publish (0,0,0); got "
        ~ a["cenX"] ~ "," ~ a["cenY"] ~ "," ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// 7.2a: Select sub-mode top/bottom returns bbox.maxY / bbox.minY of the
// selection (in world XYZ — phase7_2_plan.md §1).
// -------------------------------------------------------------------------

unittest { // selectSubMode top / bottom
    resetCube();
    // Select all 6 faces (whole cube — bbox = [-0.5..+0.5]^3).
    postJson("/api/select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode select");

    postJson("/api/command",
        "tool.pipe.attr actionCenter selectSubMode top");
    auto top = getAcenAttrs();
    assert(abs(floatAttr(top, "cenY") - 0.5f) < 1e-4,
        "Top sub-mode cenY expected 0.5, got " ~ top["cenY"]);

    postJson("/api/command",
        "tool.pipe.attr actionCenter selectSubMode bottom");
    auto bot = getAcenAttrs();
    assert(abs(floatAttr(bot, "cenY") - (-0.5f)) < 1e-4,
        "Bottom sub-mode cenY expected -0.5, got " ~ bot["cenY"]);
}

// -------------------------------------------------------------------------
// 7.2b: Manual mode pins center via cenX/Y/Z attrs. Setting cen* in any
// other mode auto-promotes to Manual.
// -------------------------------------------------------------------------

unittest { // Manual mode via cenX/Y/Z auto-promote
    resetCube();
    // tool.pipe.attr sets one attr per call — argstring positional
    // form is `<stage> <name> <value>`.
    postJson("/api/command", "tool.pipe.attr actionCenter cenX 1.5");
    postJson("/api/command", "tool.pipe.attr actionCenter cenY -2.0");
    postJson("/api/command", "tool.pipe.attr actionCenter cenZ 0.25");
    auto a = getAcenAttrs();
    assert(a["mode"] == "manual",
        "Setting cen* should promote to Manual; got mode=" ~ a["mode"]);
    assert(abs(floatAttr(a, "cenX") - 1.5f) < 1e-6, "cenX: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY") - (-2.0f)) < 1e-6, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ") - 0.25f) < 1e-6, "cenZ: " ~ a["cenZ"]);
}

unittest { // Manual ignores selection changes
    resetCube();
    postJson("/api/command", "tool.pipe.attr actionCenter mode manual");
    postJson("/api/command", "tool.pipe.attr actionCenter cenX 5");
    postJson("/api/command", "tool.pipe.attr actionCenter cenY 5");
    postJson("/api/command", "tool.pipe.attr actionCenter cenZ 5");
    // Now select a face that would shift Auto's centroid — Manual must
    // stay pinned.
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    auto a = getAcenAttrs();
    assert(abs(floatAttr(a, "cenX") - 5.0f) < 1e-6,
        "Manual cenX must not follow selection; got " ~ a["cenX"]);
}

// -------------------------------------------------------------------------
// 7.2b: Switching modes clears Auto's userPlaced sub-state. Re-selecting
// "Auto" from a Manual mode resets userPlaced=false (matches popup re-
// click semantics in MODO).
// -------------------------------------------------------------------------

unittest { // mode switch clears userPlaced
    resetCube();
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    postJson("/api/command", "tool.pipe.attr actionCenter cenX 5");   // → Manual
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    auto a = getAcenAttrs();
    assert(a["mode"] == "auto", "expected auto, got " ~ a["mode"]);
    assert(a["userPlaced"] == "false",
        "userPlaced must clear on mode switch; got " ~ a["userPlaced"]);
}

// -------------------------------------------------------------------------
// 7.2b: Screen mode publishes a center on the workplane. With default
// camera looking at origin and workplane = world XZ at origin, the
// screen-center ray should hit at (0,0,0) (or close — camera might be
// slightly off-axis).
// -------------------------------------------------------------------------

unittest { // Screen mode resolves to a finite center
    resetCube();
    // Reset camera to default so the test is deterministic.
    postJson("/api/command", "viewport.fit");
    postJson("/api/command", "tool.pipe.attr actionCenter mode screen");
    auto a = getAcenAttrs();
    assert(a["mode"] == "screen", "expected screen, got " ~ a["mode"]);
    // Just verify the values are finite floats (no NaN). Screen-center
    // depends on camera state which other tests may have mutated; the
    // important contract is "doesn't crash + publishes a Vec3".
    auto cx = floatAttr(a, "cenX");
    auto cy = floatAttr(a, "cenY");
    auto cz = floatAttr(a, "cenZ");
    assert(cx == cx && cy == cy && cz == cz,    // NaN check
        "Screen mode published NaN: " ~ a["cenX"] ~ "," ~ a["cenY"] ~ "," ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// 7.2a: Unknown mode value is rejected (mode stays unchanged).
// -------------------------------------------------------------------------

unittest { // unknown mode rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr actionCenter mode origin");
    auto before = getAcenAttrs();
    // Should fail / leave mode as origin.
    postJson("/api/command", "tool.pipe.attr actionCenter mode flubber");
    auto after = getAcenAttrs();
    assert(before["mode"] == after["mode"],
        "Unknown mode should leave state unchanged: was "
        ~ before["mode"] ~ ", now " ~ after["mode"]);
}
