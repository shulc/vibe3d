// Click-away relocate against a USER-PINNED work plane.
//
// Behaviour pinned here: when the work plane is pinned (non-auto), the
// relocate projects the click onto THAT plane — the one the user actually
// set, with its full orientation and its full origin. Not onto an
// axis-aligned stand-in for it.
//
// THE BUG THIS GUARDS AGAINST. The click-relocate plane law was ported from
// a reference whose pinned work-plane state is one principal-axis INDEX plus
// one SCALAR offset along it. vibe3d's is a full frame: `WorkplaneStage`
// carries `rotation` as Euler degrees (B = Rz·Rx·Ry) and `center` as a full
// Vec3, both reachable from shipped commands (`workplane.edit rotX/Y/Z`,
// `workplane.rotate`, `workplane.offset`, `workplane.alignToSelection`).
// Routing our frame through the reference's lock arm collapsed it to
// (argmax axis, one origin component) and threw the rest away silently. Two
// distinct losses, one per test below:
//
//   1. THE COMPONENT MIX-UP. The lock arm's axis assignment is conditional —
//      it is skipped when the VIEW has a locked axis of its own — but its
//      value write is not. Fed a scalar that had been read along the pinned
//      plane's axis, it wrote that number into the VIEW axis's component
//      instead. Pin the plane to world X at x=3, look through Front ortho,
//      and the pivot landed at z=3 instead of z=0.
//
//   2. THE ROTATION. A plane tilted 45 degrees became a flat axis-aligned
//      one, and the two origin components that were not the chosen axis's
//      went with it.
//
// Both are asserted as LANDINGS, and every case first asserts the relocate
// actually fired (`userPlaced`) — a relocate that no-ops leaves the pivot at
// the origin, which would satisfy a bare "lands near zero" check for the
// wrong reason.

import http_client : testBaseUrl, getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, sqrt;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;


void runCmd(string argstring) {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

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


void settle() { quiesce(); }

// Cube + Move tool + the given viewport preset + a PINNED work plane + the
// given ACEN mode. Order matters: tool.set / viewport.view re-stamp the
// tool's default action-center preset, so the ACEN mode is set last. The
// work plane is pinned after the view because `workplane.edit` is
// independent of both and reads cleaner here.
void setupPinned(string viewPreset, string workplaneEdit, string acenMode) {
    postJson("/api/command", commandBody("scene.reset", `{"type":"cube"}`));
    postJson("/api/script",  "tool.set move");
    if (viewPreset.length) postJson("/api/command", "viewport.view " ~ viewPreset);
    runCmd(workplaneEdit);
    postJson("/api/command", "tool.pipe.attr actionCenter mode " ~ acenMode);
    settle();
}

// Zero-motion left-click well clear of the gizmo. The gizmo sits at the
// action centre, which starts at the world origin and projects to the cell
// centre; a quarter-extent diagonal offset clears both axis arrows and the
// centre handle in either projection.
void clickOffGizmo(CameraState cam) {
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    int x  = cx - cam.width  / 4;
    int y  = cy - cam.height / 4;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x, y, x, y, 1));
    settle();
}

// Guard every landing assertion below: a relocate that silently no-ops
// leaves the pivot at (0,0,0), and several of the plane equations here are
// satisfied by the origin. Assert the click was actually consumed first.
void assertRelocated(string[string] a, string where) {
    assert(a["userPlaced"] == "true",
        where ~ ": the click-away must relocate (userPlaced), got "
        ~ a["userPlaced"] ~ " — every landing assertion after this would be "
        ~ "reading the un-relocated origin");
}

// -------------------------------------------------------------------------
// 1. THE COMPONENT MIX-UP, in the cell that produced it.
//
// Work plane pinned to world X (rotZ:90 turns the local +Y normal into -X)
// with its centre at x=3, seen through a FRONT orthographic view. Front is
// an axis-locked view whose axis is Z, and Z is also the camera-facing
// argmax — so the collapsed lock arm kept k=Z and wrote the plane's X
// offset, 3, into the Z component.
//
// Correct landing: an ortho relocate keeps the pre-press centre's depth
// (gap 364, task 7134) — the cube's centre, z = 0; it equals the plane
// origin's depth in this rig (the origin is (3, 0, 0)).
//
// The discriminator is a full 3.0 world units and nothing in this rig
// quantises: the law's out-of-plane quantum is off by default, and even at
// its largest candidate step (2.0) 0 and 3 do not collapse onto each other.
// -------------------------------------------------------------------------
unittest {
    setupPinned("Front", "workplane.edit cenX:3 rotZ:90", "none");

    auto camj = getJson("/api/camera");
    if (auto pk = "projKind" in camj.object)
        assert(pk.str == "Ortho",
            "precondition: Front view must be Ortho, got " ~ pk.str);

    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assertRelocated(a, "Front ortho + plane pinned to world X");

    immutable float z = floatAttr(a, "cenZ");
    assert(abs(z - 3.0f) > 0.5f,
        format("the pinned plane's X offset (3) was written into the VIEW "
               ~ "axis's Z component: cenZ=%.4f. The work-plane frame has "
               ~ "been collapsed onto an axis+scalar again.", z));
    assert(abs(z) < 5e-2,
        format("Front ortho relocate must land on the camera-perpendicular "
               ~ "plane at the pre-press centre's depth (gap 364; equals the "
               ~ "plane origin in this rig), z~0; cenZ=%.4f", z));
}

// -------------------------------------------------------------------------
// 2. The same collapse in a SECOND axis-locked cell, so the guard is not
// specific to Front. The plane is still pinned to world X at x=3. An ortho
// preset view turns with a pinned plane (gap 187, task 7139), so the cell has
// to be one where that plane stays EDGE-ON: a turned Top looks along the plane
// normal (face-on) and could no longer separate anything. RIGHT turned by
// rotZ 90 looks along world -Y, so it locks Y — the component the collapsed
// arm wrote 3 into, exactly as the unturned Top did before 7139.
// -------------------------------------------------------------------------
unittest {
    setupPinned("Right", "workplane.edit cenX:3 rotZ:90", "none");
    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assertRelocated(a, "Right ortho (turned) + plane pinned to world X");

    immutable float y = floatAttr(a, "cenY");
    assert(abs(y - 3.0f) > 0.5f,
        format("the pinned plane's X offset (3) was written into the VIEW "
               ~ "axis's Y component: cenY=%.4f", y));
    assert(abs(y) < 5e-2,
        format("Right ortho relocate must land on the camera-perpendicular "
               ~ "plane at the pre-press centre's depth (gap 364; equals the "
               ~ "plane origin in this rig), y~0; cenY=%.4f", y));
}

// -------------------------------------------------------------------------
// 3. THE ROTATION, in the default perspective view, None and Auto modes (the
// relocate branch is shared by both, so a fix that reached one would be half).
//
// `rotX:45 cenZ:2` tilts the plane. The landing is the create click law in
// plane-local numbers (captured K-W W2a, tests/fixtures/create_click_plane.json):
// on the plane perpendicular to the most-facing LOCAL axis through the local
// focus rounded to ten grid steps after a q pre-snap, every channel snapped to
// q. The collapsed lock arm landed on the flat world plane y = 0, and the old
// rule on the pinned plane itself (local y = 0); the rig asserts the law's
// plane is neither.
// -------------------------------------------------------------------------
void assertPinnedPerspLaw(string mode) {
    import std.math : round, cos, sin, PI;
    setupPinned("", "workplane.edit rotX:45 cenZ:2", mode);
    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assert(a["mode"] == mode, "relocate must not change mode; got " ~ a["mode"]);
    assertRelocated(a, mode ~ " mode + 45-degree tilted plane");

    // Plane frame: world = (0,0,2) + Rx(45) * local.
    immutable double c = cos(PI / 4), sn = sin(PI / 4);
    double[3] toLocal(double[3] w) {
        const d = [w[0], w[1], w[2] - 2.0];
        return [d[0], c * d[1] + sn * d[2], -sn * d[1] + c * d[2]];
    }
    auto cam = getJson("/api/camera");
    double n(JSONValue v) { return v.type == JSONType.integer ? v.integer : v.floating; }
    const focusL = toLocal([n(cam["focus"]["x"]), n(cam["focus"]["y"]), n(cam["focus"]["z"])]);
    const landL = toLocal([floatAttr(a, "cenX"), floatAttr(a, "cenY"), floatAttr(a, "cenZ")]);
    auto vp = viewportFromCamera(fetchCamera());
    const double[3] backL = [vp.view[2], c * vp.view[6] + sn * vp.view[10],
                             -sn * vp.view[6] + c * vp.view[10]];
    int k = 0;
    foreach (i; 1 .. 3) if (abs(backL[i]) > abs(backL[k])) k = i;
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    immutable double q = n(g["subStep"]), step = 10 * n(g["size"]);
    immutable double want = round(round(focusL[k] / q) * q / step) * step;
    assert(k == 1 ? abs(want) > 0.1 : true,
        format("rig: the law's plane (local %d = %.4f) must differ from the pinned plane", k, want));
    assert(abs(landL[k] - want) <= 1e-3,
        format("%s: the relocated centre must lie on the local plane %d = %.4f (the "
               ~ "rounded local focus %.4f); local landing (%.4f, %.4f, %.4f)", mode, k,
               want, focusL[k], landL[0], landL[1], landL[2]));
    assert(abs(floatAttr(a, "cenY")) > 0.1f,
        format("the pivot landed on the AXIS-ALIGNED plane y=0: the work plane's "
               ~ "rotation has been discarded (cenY %.4f)", floatAttr(a, "cenY")));
}

unittest { assertPinnedPerspLaw("none"); }
unittest { assertPinnedPerspLaw("auto"); }

// -------------------------------------------------------------------------
// 5. THE AUTO PLANE IS NOT AFFECTED. With no plane pinned the relocate goes
// through the ported law, and that path must keep landing where it did: on
// the camera-facing principal-axis plane through the camera focus. This is
// the control for tests 1-4 — it says the fix above was scoped to the pinned
// branch and did not buy its correctness by disabling the port.
// -------------------------------------------------------------------------
unittest {
    postJson("/api/command", commandBody("scene.reset", `{"type":"cube"}`));
    postJson("/api/script",  "tool.set move");
    postJson("/api/command", "viewport.view Front");
    postJson("/api/command", "tool.pipe.attr actionCenter mode none");
    settle();

    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assertRelocated(a, "Front ortho + auto plane");

    // Focus is the origin, the Front principal axis is Z: the landing sits on
    // z = 0 and moves off the origin in the plane.
    assert(abs(floatAttr(a, "cenZ")) < 5e-2,
        "auto-plane Front relocate must still land on z~0; cenZ=" ~ a["cenZ"]);
    immutable float offset = sqrt(floatAttr(a, "cenX") * floatAttr(a, "cenX")
                                + floatAttr(a, "cenY") * floatAttr(a, "cenY"));
    assert(offset > 0.05f,
        format("auto-plane Front relocate did not move off the origin; (%s,%s)",
               a["cenX"], a["cenY"]));
}
