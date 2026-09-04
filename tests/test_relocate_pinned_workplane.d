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
// carries `rotation` as extrinsic-XYZ Euler degrees and `center` as a full
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

import http_client : testBaseUrl, getJson, postJson;
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

void settle() { Thread.sleep(150.msecs); }

// Cube + Move tool + the given viewport preset + a PINNED work plane + the
// given ACEN mode. Order matters: tool.set / viewport.view re-stamp the
// tool's default action-center preset, so the ACEN mode is set last. The
// work plane is pinned after the view because `workplane.edit` is
// independent of both and reads cleaner here.
void setupPinned(string viewPreset, string workplaneEdit, string acenMode) {
    postJson("/api/reset", `{"primitive":"cube"}`);
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
// Correct landing: the pinned plane is edge-on to a Front camera, so the
// relocate uses the camera-perpendicular plane through the pinned origin
// (the task-0226 fix) — which for a Front view is z = 0.
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
               ~ "plane through the pinned origin, z~0; cenZ=%.4f", z));
}

// -------------------------------------------------------------------------
// 2. The same collapse in a SECOND axis-locked cell, so the guard is not
// specific to Front. TOP ortho locks Y; the plane is still pinned to world
// X at x=3, so the collapsed arm wrote 3 into cenY.
// -------------------------------------------------------------------------
unittest {
    setupPinned("Top", "workplane.edit cenX:3 rotZ:90", "none");
    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assertRelocated(a, "Top ortho + plane pinned to world X");

    immutable float y = floatAttr(a, "cenY");
    assert(abs(y - 3.0f) > 0.5f,
        format("the pinned plane's X offset (3) was written into the VIEW "
               ~ "axis's Y component: cenY=%.4f", y));
    assert(abs(y) < 5e-2,
        format("Top ortho relocate must land on the camera-perpendicular "
               ~ "plane through the pinned origin, y~0; cenY=%.4f", y));
}

// -------------------------------------------------------------------------
// 3. THE ROTATION, in the default perspective view.
//
// `rotX:45` tilts the plane normal to (0, 0.7071, 0.7071); `cenZ:2` puts its
// origin at (0,0,2). The plane is therefore { y + z == 2 }.
//
// The collapse chose the argmax of |normal| — a tie between Y and Z that
// falls to Y — and read the origin's Y component, which is 0. So it landed
// the pivot on the flat plane { y == 0 }: the tilt gone, and the only
// non-zero origin component thrown away with it.
//
// Both facts are asserted: ON the tilted plane, and OFF the flat one. The
// second assertion is what makes the first non-vacuous — the two planes
// intersect along a line, and a landing that happened to fall on it would
// satisfy either.
// -------------------------------------------------------------------------
unittest {
    setupPinned("", "workplane.edit rotX:45 cenZ:2", "none");
    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assertRelocated(a, "perspective + 45-degree tilted plane");

    immutable float y = floatAttr(a, "cenY");
    immutable float z = floatAttr(a, "cenZ");

    assert(abs(y) > 0.1f,
        format("the pivot landed on the AXIS-ALIGNED plane y=0, not on the "
               ~ "45-degree plane the user pinned: (y,z)=(%.4f,%.4f). The "
               ~ "work plane's rotation has been discarded.", y, z));
    assert(abs(y + z - 2.0f) < 5e-2,
        format("the pivot must lie on the pinned plane y+z=2; got "
               ~ "(y,z)=(%.4f,%.4f), y+z=%.4f", y, z, y + z));
}

// -------------------------------------------------------------------------
// 4. AUTO mode takes the same pinned plane. The relocate branch is shared by
// the None and Auto action-center modes, so a fix that only reached one of
// them would be half a fix.
// -------------------------------------------------------------------------
unittest {
    setupPinned("", "workplane.edit rotX:45 cenZ:2", "auto");
    clickOffGizmo(fetchCamera());
    auto a = getAcenAttrs();
    assert(a["mode"] == "auto", "relocate must not change mode; got " ~ a["mode"]);
    assertRelocated(a, "auto mode + 45-degree tilted plane");

    immutable float y = floatAttr(a, "cenY");
    immutable float z = floatAttr(a, "cenZ");
    assert(abs(y) > 0.1f,
        format("auto mode discarded the work plane's rotation too: "
               ~ "(y,z)=(%.4f,%.4f)", y, z));
    assert(abs(y + z - 2.0f) < 5e-2,
        format("auto-mode pivot must lie on the pinned plane y+z=2; got "
               ~ "(y,z)=(%.4f,%.4f), y+z=%.4f", y, z, y + z));
}

// -------------------------------------------------------------------------
// 5. THE AUTO PLANE IS NOT AFFECTED. With no plane pinned the relocate goes
// through the ported law, and that path must keep landing where it did: on
// the camera-facing principal-axis plane through the camera focus. This is
// the control for tests 1-4 — it says the fix above was scoped to the pinned
// branch and did not buy its correctness by disabling the port.
// -------------------------------------------------------------------------
unittest {
    postJson("/api/reset", `{"primitive":"cube"}`);
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
