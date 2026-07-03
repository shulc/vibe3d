// ACEN click-away relocate in an ORTHOGRAPHIC viewport.
//
// Behaviour pinned here (task 0226):
//
//   With a transform tool active and a relocate-allowed action-center
//   mode (None / Auto), a left-click that lands OFF every gizmo handle
//   relocates the action-center pivot to the projection of the click
//   onto the relocate plane — in an ORTHO cell exactly as in a
//   PERSPECTIVE one.
//
// The bug this guards against: the relocate projected the click onto the
// world work plane (+Y-normal ground plane by default). An orthographic
// camera casts all rays parallel to its forward vector, so in a Front /
// Side ortho view (forward perpendicular to +Y) the projection ray lies
// IN the ground plane — rayPlaneIntersect degenerated (denom ~ 0 →
// returned false) and the relocate silently no-op'd: userPlaced stayed
// false and the pivot never moved. (The Top ortho view happened to work
// because its forward equals the plane normal; perspective works because
// its rays diverge from the eye.)
//
// The fix (source/tools/transform.d computeClickRelocateHitRaw) swaps in a
// camera-perpendicular plane through the same origin when the camera is
// orthographic, so the ray always hits and the click lands under the
// cursor at focus depth. This is the ONE shared relocate projection every
// transform tool (Move / Rotate / Scale) and every relocate-allowed mode
// (None / Auto / Screen) routes through, so the fix is uniform.
//
// Discriminator (pre-fix vs post-fix), robust and projection-independent:
//   - PRE-FIX  : ortho Front relocate ray parallel to ground plane →
//                no relocate → userPlaced == "false", pivot unchanged.
//   - POST-FIX : userPlaced == "true" and the pivot lands on the Front
//                plane (z ~ 0), moved off the origin.
// The Top ortho view (which already worked) is asserted too, so the fix
// did not regress the previously-working cell.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, sqrt;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

// Walk /api/toolpipe and return the ACEN stage's attrs as string→string.
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

void settle() { Thread.sleep(150.msecs); }

// Reset to a known start: cube, Move tool, the given ortho viewport
// preset, and the given ACEN mode. The ACEN mode is set LAST because
// tool.set / viewport.view re-stamp the tool's default action-center
// preset, so a mode set earlier would be clobbered.
void setupOrtho(string acenMode, string viewPreset) {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/script",  "tool.set move");
    postJson("/api/command", "viewport.view " ~ viewPreset);
    postJson("/api/command", "tool.pipe.attr actionCenter mode " ~ acenMode);
    settle();
}

// Inject a zero-motion left-click at an off-gizmo pixel. The gizmo sits at
// the world origin, which projects to the viewport centre in any centred
// camera; a 25%-of-extent diagonal offset lands clear of both axis arrows
// and the centre handle regardless of projection.
void clickOffGizmo(CameraState cam) {
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    int x  = cx - cam.width  / 4;   // up-left of centre
    int y  = cy - cam.height / 4;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x, y, x, y, 1));
    settle();
}

// -------------------------------------------------------------------------
// FRONT ortho, ACEN None — the previously-degenerate case. Pre-fix this
// left userPlaced=false and the pivot at the origin; post-fix it relocates
// onto the Front plane (z ~ 0).
// -------------------------------------------------------------------------
unittest {
    setupOrtho("none", "Front");

    // Confirm the camera really is orthographic (guards the premise: if
    // this ever reports "Perspective" the discriminator is meaningless).
    auto camj = getJson("/api/camera");
    if (auto pk = "projKind" in camj.object)
        assert(pk.str == "Ortho",
            "precondition: Front view must be Ortho, got " ~ pk.str);

    auto before = getAcenAttrs();
    assert(before["userPlaced"] == "false",
        "fresh None must not be userPlaced; got " ~ before["userPlaced"]);

    clickOffGizmo(fetchCamera());

    auto a = getAcenAttrs();
    // Core discriminator: the relocate fired in ortho.
    assert(a["userPlaced"] == "true",
        "ortho Front click-away must relocate (userPlaced); got "
        ~ a["userPlaced"] ~ " — degenerate ray not fixed?");
    // Landed on the Front plane (camera-perpendicular through focus=origin,
    // so z ~ 0).
    assert(abs(floatAttr(a, "cenZ")) < 5e-2,
        "ortho Front relocate must land on z~0 plane; cenZ=" ~ a["cenZ"]);
    // And it genuinely moved off the origin (some in-plane X/Y offset).
    float offset = sqrt(floatAttr(a, "cenX") * floatAttr(a, "cenX")
                      + floatAttr(a, "cenY") * floatAttr(a, "cenY"));
    assert(offset > 0.05f,
        format("ortho Front relocate did not move off origin; (%s,%s)",
               a["cenX"], a["cenY"]));
}

// -------------------------------------------------------------------------
// LEFT ortho (a side view), ACEN None — the other degenerate cell.
// Post-fix lands on the Left plane (x ~ 0).
// -------------------------------------------------------------------------
unittest {
    setupOrtho("none", "Left");
    clickOffGizmo(fetchCamera());

    auto a = getAcenAttrs();
    assert(a["userPlaced"] == "true",
        "ortho Left click-away must relocate; got " ~ a["userPlaced"]);
    assert(abs(floatAttr(a, "cenX")) < 5e-2,
        "ortho Left relocate must land on x~0 plane; cenX=" ~ a["cenX"]);
}

// -------------------------------------------------------------------------
// FRONT ortho, ACEN Auto — same shared projection, second relocate-allowed
// mode. Proves the fix is not scoped to None.
// -------------------------------------------------------------------------
unittest {
    setupOrtho("auto", "Front");
    clickOffGizmo(fetchCamera());

    auto a = getAcenAttrs();
    assert(a["mode"] == "auto",
        "relocate must not change mode; got " ~ a["mode"]);
    assert(a["userPlaced"] == "true",
        "ortho Front Auto click-away must relocate; got " ~ a["userPlaced"]);
    assert(abs(floatAttr(a, "cenZ")) < 5e-2,
        "ortho Front Auto relocate must land on z~0 plane; cenZ=" ~ a["cenZ"]);
}

// -------------------------------------------------------------------------
// TOP ortho, ACEN None — the cell that ALREADY worked (forward == ground
// plane normal). Guards that the ortho branch did not regress it: still
// relocates, still lands on the ground plane (y ~ 0).
// -------------------------------------------------------------------------
unittest {
    setupOrtho("none", "Top");
    clickOffGizmo(fetchCamera());

    auto a = getAcenAttrs();
    assert(a["userPlaced"] == "true",
        "ortho Top click-away must still relocate; got " ~ a["userPlaced"]);
    assert(abs(floatAttr(a, "cenY")) < 5e-2,
        "ortho Top relocate must land on y~0 ground plane; cenY=" ~ a["cenY"]);
}
