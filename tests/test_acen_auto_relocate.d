// Click-away-from-gizmo relocate in Auto action-center mode.
//
// Behaviour pinned here (new, intentional — there is no external
// reference suite for it):
//
//   In Auto mode, a left-click that lands OFF every transform gizmo
//   handle relocates the action-center pivot to the projection of the
//   click ray onto the work plane, and the relocated point becomes the
//   pivot for the subsequent transform — it does NOT fall back to the
//   static selection / geometry centroid.
//
// The transform tools implement the relocate by pushing the projected
// world point through ActionCenterStage.setUserPlaced (which sets
// userPlaced=true and userPlacedCenter=<hit>); Auto-mode computeCenter
// then returns userPlacedCenter until the mode is re-picked. This is
// the same hook every transform tool (Move / Rotate / Scale) calls, so
// the relocate is uniform across them.
//
// The HTTP `userPlacedX/Y/Z` write-attrs are the test-automation
// counterpart of setUserPlaced (see actcenter.d): they simulate the
// post-click relocated state without a GPU-hover-driven click, so this
// test is fully deterministic and needs no raw event injection.

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

// Reset to a known starting point: cube primitive + Auto ACEN.
void resetCubeAuto() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
}

// Simulate a click-away-from-gizmo relocate to a world point. This is
// exactly what every transform tool does on a gizmo-miss click in Auto:
// notifyAcenUserPlaced(<work-plane projection of click ray>) →
// ActionCenterStage.setUserPlaced(hit).
void relocateAuto(float x, float y, float z) {
    postJson("/api/command",
        "tool.pipe.attr actionCenter userPlacedX " ~ x.to!string);
    postJson("/api/command",
        "tool.pipe.attr actionCenter userPlacedY " ~ y.to!string);
    postJson("/api/command",
        "tool.pipe.attr actionCenter userPlacedZ " ~ z.to!string);
}

// -------------------------------------------------------------------------
// Baseline: with a face selected and no click-away, Auto's pivot is the
// selection centroid (static). This is the "before" the relocate must
// override.
// -------------------------------------------------------------------------

unittest { // Auto baseline = selection centroid, userPlaced=false
    resetCubeAuto();
    // Face 4 = top of the default cube, centroid (0, 0.5, 0).
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    auto a = getAcenAttrs();
    assert(a["mode"] == "auto", "expected auto, got " ~ a["mode"]);
    assert(a["userPlaced"] == "false",
        "fresh Auto must not be userPlaced; got " ~ a["userPlaced"]);
    assert(abs(floatAttr(a, "cenY") - 0.5f) < 1e-3,
        "Auto baseline cenY expected 0.5 (top centroid), got " ~ a["cenY"]);
}

// -------------------------------------------------------------------------
// Core: a click-away relocate in Auto moves the pivot to the projected
// work-plane point — NOT the static selection centroid. The pivot must
// equal the relocated point and userPlaced must be true.
// -------------------------------------------------------------------------

unittest { // Auto click-away relocates the pivot
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);  // centroid (0,0.5,0)

    // Click away from the gizmo → pivot projected onto the work plane at
    // a point distinct from the selection centroid.
    relocateAuto(2.0f, 0.0f, -1.5f);

    auto a = getAcenAttrs();
    assert(a["mode"] == "auto",
        "relocate must NOT change mode (Auto stays Auto); got " ~ a["mode"]);
    assert(a["userPlaced"] == "true",
        "click-away must set userPlaced; got " ~ a["userPlaced"]);
    // The published pivot now equals the relocated point, NOT (0,0.5,0).
    assert(abs(floatAttr(a, "cenX") - 2.0f)  < 1e-3, "cenX: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY") - 0.0f)  < 1e-3, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ") - (-1.5f)) < 1e-3, "cenZ: " ~ a["cenZ"]);
    // And it is genuinely different from the static centroid it replaced.
    assert(abs(floatAttr(a, "cenY") - 0.5f) > 1e-2,
        "relocated pivot must differ from selection centroid");
}

// -------------------------------------------------------------------------
// The relocated pivot is sticky across selection changes (it overrides
// the centroid until the mode is re-picked) — proving the transform that
// follows the click uses the relocated point, not a freshly recomputed
// centroid.
// -------------------------------------------------------------------------

unittest { // relocated pivot sticks across selection change
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    relocateAuto(1.0f, 1.0f, 1.0f);

    // Change the selection — Auto would normally recompute the centroid,
    // but the click-away pin must win.
    postJson("/api/select", `{"mode":"polygons","indices":[5]}`); // bottom face
    auto a = getAcenAttrs();
    assert(a["userPlaced"] == "true",
        "relocate pin must survive a selection change; got " ~ a["userPlaced"]);
    assert(abs(floatAttr(a, "cenX") - 1.0f) < 1e-3, "cenX: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenY") - 1.0f) < 1e-3, "cenY: " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenZ") - 1.0f) < 1e-3, "cenZ: " ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// Re-picking Auto clears the relocate pin (popup re-click semantics) —
// the pivot returns to the live selection centroid.
// -------------------------------------------------------------------------

unittest { // re-picking Auto clears the relocate pin
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    relocateAuto(3.0f, 3.0f, 3.0f);
    assert(getAcenAttrs()["userPlaced"] == "true", "precondition: pinned");

    // Re-select Auto in the popup → clears userPlaced.
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    auto a = getAcenAttrs();
    assert(a["userPlaced"] == "false",
        "re-picking Auto must clear the relocate pin; got " ~ a["userPlaced"]);
    // Pivot back to the live selection centroid (top face, y=0.5).
    assert(abs(floatAttr(a, "cenY") - 0.5f) < 1e-3,
        "cleared pin → centroid; cenY: " ~ a["cenY"]);
}

// -------------------------------------------------------------------------
// A NON-relocating mode (Select) ignores a would-be click-away — its
// pivot stays the strict selection centroid. This guards that the
// relocate is scoped to the relocate-allowed modes only and the fix did
// not widen it.
// -------------------------------------------------------------------------

unittest { // Select mode ignores the relocate pin
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/command", "tool.pipe.attr actionCenter mode select");

    // Even if a userPlaced point gets written, Select's computeCenter
    // never consults it — pivot stays at the selection centroid.
    relocateAuto(5.0f, 5.0f, 5.0f);
    auto a = getAcenAttrs();
    assert(a["mode"] == "select", "expected select, got " ~ a["mode"]);
    assert(abs(floatAttr(a, "cenY") - 0.5f) < 1e-3,
        "Select pivot must stay the selection centroid, got " ~ a["cenY"]);
    assert(abs(floatAttr(a, "cenX")) < 1e-3, "cenX: " ~ a["cenX"]);
    assert(abs(floatAttr(a, "cenZ")) < 1e-3, "cenZ: " ~ a["cenZ"]);
}
