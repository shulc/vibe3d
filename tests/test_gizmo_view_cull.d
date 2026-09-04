// test_gizmo_view_cull.d — a gizmo handle the view has flattened is REMOVED,
// from the drawing and from the hit test alike.
//
// WHAT THE RULE IS. An axis within 5.126 deg of the ray the view looks along
// through the gizmo projects to nothing. Its arm is dropped; so are the two
// plane handles whose planes SPAN it. A rotate ring is dropped instead when it
// is within ~5 deg of edge-on, and only in an axis-locked view. The predicates
// live in `handles/gl_util.d` (`axisFacesViewer`, `planeHandleHidden`,
// `rotateRingHidden`) and are applied in `handles/shapes.d`.
//
// WHY THE MODULE unittests IN gl_util.d ARE NOT ENOUGH. They pin the
// predicate; they cannot see whether anything CALLS it, or whether the answer
// reaches the hit test. This file drives a real camera and reads the real
// registry. Both halves matter and the second one is the one that bit us: the
// rule that shipped for a year was gated on the cell being ORTHOGRAPHIC, so in
// a perspective viewport nothing was ever culled and a zero-length arm went on
// swallowing clicks. A test written only at an axis-aligned ortho view would
// have passed on that code, green, forever. Every flow here is therefore in a
// PERSPECTIVE viewport except the one that is about ortho by construction.
//
// HOW THE THRESHOLD IS ADDRESSED. With the camera's focus at the origin and
// the gizmo pivot at the origin, the eye vector at the gizmo is exactly
// -normalize(eye), so for elevation 0
//
//     |dot(worldX, eyeVectorAtGizmo)| == |sin(azimuth)|
//
// and an azimuth of `asin(t)` puts the X axis at a chosen `t` to the last
// float. Both premises are asserted, not assumed. That makes the bracket below
// exact rather than approximate: 0.99581 must draw and 0.99600 must not.
//
// FLOWS
//   A  the threshold, bracketed from BOTH sides, in perspective. Arms and the
//      two plane handles spanning the axis cross together, in one frame.
//   B  the DISCRIMINATING case. A plane handle held exactly edge-on through a
//      75-degree sweep stays drawn. The plausible rival rule — "hide a plane
//      handle when its plane is edge-on", which is what a neighbouring helper
//      in the reference does — fails every row of this flow.
//   C  a culled handle is also UNCLICKABLE, asserted at the SAME pixel on both
//      sides of the threshold so nothing but the rule differs between the two
//      readings.
//   D  rotate rings: the cull is gated on the viewport being an axis view, and
//      inside one it drops the EDGE-ON rings rather than keeping only the
//      face-on one. Those two phrasings agree for a world-aligned gizmo and
//      disagree for a rotated one, where the old form left NO axis ring at all.
//
// VERIFIED BY MUTATION. Each was applied to a green tree, built and run; the
// assertion named is the one that actually fired.
//   * `GIZMO_FACING_COS` 0.996 -> 0.999
//        -> Flow A, "the X arm must be culled at |dot(X, eye)| = 0.99600".
//   * `axisFacesViewer` re-gated on `isOrtho(vp)` — the rule as it shipped
//        -> Flow A, same assertion. (Perspective is the whole gap.)
//   * `planeHandleHidden` switched to the rival rule, testing the plane's
//     NORMAL with the edge-on threshold
//        -> Flow A first, "the XZ plane handle spans X and must follow the X
//           arm at |dot(X, eye)| = 0.99000" — the two rules already disagree
//           there. Flow B is the flow written FOR this mutation and was
//           confirmed to reject it on its own, with the other three flows
//           disabled: "the edge-on XY plane handle must be DRAWN at elevation
//           5.25 deg". Flow B is not redundant with Flow A: it is the only one
//           that fails for a rule that is right about the arms.
//   * `ToolHandles.test`'s `if (!e.h.isVisible()) continue;` removed, i.e. the
//     handle is hidden but still hit-tested
//        -> Flow C, "a culled arm must not be hot — the same pixel returned
//           part 0".
//   * `rotateRingHidden` reverted to the shipped form (ortho gate, keep only
//     `|dot| >= 0.999`)
//        -> Flow D, "a ring 45 degrees to the eye is grabbable and must be
//           drawn — the rule that kept only the FACE-ON ring left none of the
//           three". Legs 1 and 2 of that flow stay GREEN under the mutation,
//           which is the point: the old rule is indistinguishable from this
//           one until the gizmo's basis stops being the world basis.

import http_client : testBaseUrl;
import std.format : format;
import std.json;
import std.math : abs, asin, sin, cos, PI;
import std.net.curl : get, post;

import drag_helpers : playAndWait;

void main() {}

alias baseUrl = testBaseUrl;

// Registration bases from source/tools/transform/xfrm_transform.d, and the
// slot order inside each bank from its own `registerHandles`. Restated rather
// than imported, on this suite's standing convention: moving a part id has to
// fail here and be re-justified.
private enum int MOVE_BASE = 0, ROT_BASE = 10;
private enum int P_ARM_X = MOVE_BASE + 0, P_ARM_Y = MOVE_BASE + 1, P_ARM_Z = MOVE_BASE + 2;
private enum int P_CENTRE = MOVE_BASE + 3;
private enum int P_PLANE_XY = MOVE_BASE + 4;   // normal Z, spans X and Y
private enum int P_PLANE_YZ = MOVE_BASE + 5;   // normal X, spans Y and Z
private enum int P_PLANE_XZ = MOVE_BASE + 6;   // normal Y, spans X and Z
private enum int P_RING_X = ROT_BASE + 0, P_RING_Y = ROT_BASE + 1;
private enum int P_RING_Z = ROT_BASE + 2, P_RING_VIEW = ROT_BASE + 3;

// The measured cull constants, restated (handles/gl_util.d).
private enum double FACING_COS = 0.996;

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
private void postRaw(string path, string body_) {
    post(baseUrl ~ path, body_);
}
private void script(string line) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/script", line));
    assert(r["status"].str == "ok", "script failed: " ~ line ~ " -> " ~ r.toString);
}
private void command(string id, string params) {
    postRaw("/api/command",
            format(`{"command":"%s","id":"%s","params":%s}`, id, id, params));
}

private double num(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

// ---------------------------------------------------------------------------
// Camera + registry
// ---------------------------------------------------------------------------

private void orbit(double az, double el, double dist = 3.0) {
    postRaw("/api/camera",
            format(`{"azimuth":%.9g,"elevation":%.9g,"distance":%.9g}`, az, el, dist));
}

private struct Reg {
    bool[int]  visible;
    double[2][int] screen;
    int hot, captured;
}

private Reg registry() {
    auto h = getJson("/api/tool/handles")["handles"];
    Reg r;
    r.hot      = cast(int)num(h, "hot");
    r.captured = cast(int)num(h, "captured");
    foreach (p; h["parts"].array) {
        immutable int id = cast(int)num(p, "part");
        r.visible[id] = p["visible"].type == JSONType.TRUE;
        if (p["screen"].type == JSONType.array)
            r.screen[id] = [p["screen"].array[0].floating, p["screen"].array[1].floating];
    }
    return r;
}

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)num(c, "vpX"),   cast(int)num(c, "vpY"),
                cast(int)num(c, "width"), cast(int)num(c, "height"));
}

// Park the pointer and leave it there. The player's mouse override is never
// cleared, so the hover survives into every frame the next registry read sees.
private void hoverAt(int x, int y) {
    auto c = cell();
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, x, y);
    playAndWait(log);
}

// Put the world back the way every other test in the suite expects to find it.
// The runner's between-test reset does not restore a viewport preset, a
// work-plane rotation or an axis-stage mode, and three of the flows below set
// one of those.
private void restoreWorld() {
    script("workplane.edit rotY:0");
    script("tool.pipe.attr axis mode auto");
    command("viewport.view", `"Perspective"`);
    script("tool.set move off");
    orbit(0.5, 0.4);
    hoverAt(4, 4);
}

// The fixture every flow leans on: the gizmo sits at the world origin, so the
// eye vector through it is exactly -normalize(eye) and the dot products below
// are the camera's own spherical angles. Asserted, not assumed.
private void armMoveAtOrigin() {
    script("tool.set move on");
    orbit(0.5, 0.4);
    auto piv = getJson("/api/tool/state")["pivot"].array;
    foreach (i, k; ["x", "y", "z"]) {
        auto e = piv[i];
        immutable double v = e.type == JSONType.integer
            ? cast(double)e.integer : e.floating;
        assert(abs(v) < 1e-6,
               format("fixture premise: the gizmo must sit at the world origin, "
                      ~ "pivot.%s = %g", k, v));
    }
}

// ---------------------------------------------------------------------------
// Flow A — the threshold, from both sides, in a PERSPECTIVE viewport
// ---------------------------------------------------------------------------

unittest {
    scope(exit) restoreWorld();
    armMoveAtOrigin();

    // The camera stays perspective throughout — this is the half the old
    // ortho-gated rule could not do at all.
    assert(getJson("/api/camera")["projKind"].str == "Perspective",
           "fixture premise: Flow A must run in a perspective viewport");

    // Elevation 0, azimuth asin(t): |dot(worldX, eye)| == t exactly.
    // The two rows either side of the constant are 0.0004 apart, which is the
    // width of the window four independent live brackets put it in.
    static struct Row { double t; bool drawn; }
    static immutable Row[] rows = [
        Row(0.99000, true),  Row(0.99500, true),  Row(0.99581, true),
        Row(0.99600, false), Row(0.99620, false), Row(0.99900, false),
        Row(1.00000, false),
    ];

    foreach (r; rows) {
        // asin(1.0) is exactly PI/2 and needs no guard; every other row is
        // strictly inside the domain.
        orbit(asin(r.t), 0.0);
        auto g = registry();

        // The dot product this row claims to be at, recomputed from the camera
        // the app actually adopted rather than from what was asked for.
        auto c = getJson("/api/camera");
        immutable double ex = num(c, "eye", "x"), ey = num(c, "eye", "y"),
                         ez = num(c, "eye", "z");
        immutable double len = (ex*ex + ey*ey + ez*ez) ^^ 0.5;
        immutable double dotX = abs(ex) / len;
        assert(abs(dotX - r.t) < 5e-4,
               format("fixture premise: |dot(X, eye)| should be %.5f, camera gives %.5f",
                      r.t, dotX));

        immutable string at = format(" at |dot(X, eye)| = %.5f", r.t);

        // The ARM.
        assert(g.visible[P_ARM_X] == r.drawn,
               (r.drawn ? "the X arm must be drawn" : "the X arm must be culled") ~ at);

        // ...and the two plane handles whose planes SPAN X, in the same frame.
        // That they cross together is a measured property, not a coincidence:
        // both tests read the eye vector at the same point.
        assert(g.visible[P_PLANE_XY] == r.drawn,
               "the XY plane handle spans X and must follow the X arm" ~ at);
        assert(g.visible[P_PLANE_XZ] == r.drawn,
               "the XZ plane handle spans X and must follow the X arm" ~ at);

        // CONTROLS. Nothing else may move. Y and Z are far from the eye ray at
        // every row (elevation 0 keeps Y perpendicular), the YZ plane handle
        // does not span X, and the centre handle is never culled.
        assert(g.visible[P_ARM_Y],     "control: the Y arm must be untouched" ~ at);
        assert(g.visible[P_ARM_Z],     "control: the Z arm must be untouched" ~ at);
        assert(g.visible[P_PLANE_YZ],  "control: the YZ plane handle does not span X" ~ at);
        assert(g.visible[P_CENTRE],    "control: the centre handle is never culled" ~ at);
    }
}

// ---------------------------------------------------------------------------
// Flow B — the discriminator: an EDGE-ON plane handle stays drawn
// ---------------------------------------------------------------------------
//
// Hold the camera IN the world XY plane (azimuth PI/2, any elevation). The XY
// plane handle's normal is Z, which is perpendicular to the view ray at EVERY
// elevation — so that handle is edge-on throughout, and a rule that tested the
// normal would hide it at every row below. The measured rule tests the two
// axes the plane SPANS, so it stays visible except inside the two narrow cones
// where X or Y itself points at the camera.
//
// At elevation `e`: |dot(X, eye)| = cos(e), |dot(Y, eye)| = sin(e). So the
// handle appears just past 5.126 deg and vanishes again just before 84.874.
unittest {
    scope(exit) restoreWorld();
    armMoveAtOrigin();

    static struct Row { double deg; bool drawn; }
    static immutable Row[] rows = [
        Row( 4.00, false),                      // inside X's cone
        Row( 5.00, false),                      // |dot(X,eye)| = 0.99619
        Row( 5.25, true ),                      // |dot(X,eye)| = 0.99580
        Row(10.00, true ), Row(30.00, true ),
        Row(45.00, true ), Row(60.00, true ),
        Row(80.00, true ), Row(84.75, true ),   // |dot(Y,eye)| = 0.99580
        Row(85.00, false),                      // |dot(Y,eye)| = 0.99619
    ];

    foreach (r; rows) {
        immutable double el = r.deg * PI / 180.0;
        orbit(PI / 2.0, el);
        auto g = registry();

        // Premise: this handle really is edge-on. Its normal is world Z and the
        // camera is in the XY plane, so the eye ray has no Z component at all.
        auto c = getJson("/api/camera");
        assert(abs(num(c, "eye", "z")) < 1e-3,
               format("fixture premise: at %.2f deg the camera must stay in the XY "
                      ~ "plane so the XY handle is edge-on (eye.z = %g)",
                      r.deg, num(c, "eye", "z")));

        assert(g.visible[P_PLANE_XY] == r.drawn,
               format("the edge-on XY plane handle must be %s at elevation %.2f deg "
                      ~ "(|dot(X,eye)| = %.5f, |dot(Y,eye)| = %.5f) — a rule that "
                      ~ "tested the plane's NORMAL would hide it at every row here",
                      r.drawn ? "DRAWN" : "culled", r.deg, cos(el), sin(el)));

        // CONTROL: the centre handle, which no rule reaches.
        assert(g.visible[P_CENTRE], "control: the centre handle is never culled");
    }
}

// ---------------------------------------------------------------------------
// Flow C — a culled handle is also unclickable, at the SAME pixel
// ---------------------------------------------------------------------------
//
// The two readings differ by 0.0002 of camera aim and nothing else: the same
// screen pixel, the same tool, the same registration order. So the only thing
// that can explain a change in what is hot is the cull.
unittest {
    scope(exit) restoreWorld();
    armMoveAtOrigin();

    // 8 window pixels along +x from the gizmo centre. Chosen from the two
    // regions this pixel is NOT in: the centre handle's own grab region ends
    // inside 6 px (asserted below), and at these azimuths the X arm's drawn
    // stub is only ~10 px long while its grab band is 8 px wide — which is
    // exactly the complaint the rule answers. A 0-px arm that still swallows
    // clicks is worse than a small one.
    enum int PROBE_DX = 8;

    int hotAt(double t, int dx) {
        orbit(asin(t), 0.0);
        auto g = registry();
        immutable int cx = cast(int)(g.screen[P_CENTRE][0] + 0.5);
        immutable int cy = cast(int)(g.screen[P_CENTRE][1] + 0.5);
        hoverAt(cx + dx, cy);
        return registry().hot;
    }

    // Drawn side: the arm is registered and the pixel grabs it.
    assert(hotAt(0.99581, PROBE_DX) == P_ARM_X,
           "premise: at |dot(X,eye)| = 0.99581 the X arm is drawn and this pixel "
           ~ "is inside its grab band");

    // Culled side: the SAME pixel, and the arm is gone from the hit test too.
    immutable int hotCulled = hotAt(0.99600, PROBE_DX);
    assert(hotCulled != P_ARM_X,
           format("a culled arm must not be hot — the same pixel returned part %d "
                  ~ "at |dot(X,eye)| = 0.99600, where the arm is not drawn", hotCulled));

    // CONTROLS. The centre handle is hot at the gizmo centre on BOTH sides, so
    // the probe is reading a live frame and the cull did not take the whole
    // gizmo with it. This also pins that PROBE_DX sits outside the centre
    // handle's own region — otherwise the assertion above would have been
    // about the centre box, not about the arm.
    assert(hotAt(0.99581, 0) == P_CENTRE,
           "control: the centre handle is hot at the gizmo centre (drawn side)");
    assert(hotAt(0.99600, 0) == P_CENTRE,
           "control: the centre handle is hot at the gizmo centre (culled side)");
}

// ---------------------------------------------------------------------------
// Flow D — rotate rings: a viewport-type gate, and the OPPOSITE condition
// ---------------------------------------------------------------------------
//
// Three readings. Perspective keeps everything however it is aimed, because
// the gate is a viewport-TYPE question and a perspective cell simply has no
// view axis. An axis view with the WORLD basis leaves exactly one axis ring —
// which is what both the old rule and this one produce, and why the difference
// went unnoticed. An axis view with a ROTATED basis is where they part: this
// rule leaves the two rings that are 45 degrees to the eye and drops the one
// that is edge-on, where "keep only the face-on ring" left nothing at all and
// the rotate gizmo could not rotate about any of its own axes.
unittest {
    scope(exit) restoreWorld();
    script("tool.set rotate on");
    orbit(0.5, 0.4);

    // 1. PERSPECTIVE — no ring is ever culled, including any that is edge-on.
    command("viewport.view", `"Perspective"`);
    orbit(0.0, 0.0);                      // looking straight down -Z:
                                          // the X and Y rings are exactly edge-on
    {
        auto g = registry();
        assert(getJson("/api/camera")["projKind"].str == "Perspective",
               "fixture premise: this leg must be perspective");
        assert(g.visible[P_RING_X] && g.visible[P_RING_Y] && g.visible[P_RING_Z],
               "a perspective viewport culls no ring, however the camera is aimed "
               ~ "— including the two that are exactly edge-on");
        assert(g.visible[P_RING_VIEW], "the screen-plane ring is never culled");
    }

    // 2. ORTHO FRONT, WORLD basis — exactly one axis ring, the one facing you.
    command("viewport.view", `"Front"`);
    script("tool.pipe.attr axis mode world");
    {
        auto g = registry();
        assert(getJson("/api/camera")["projKind"].str == "Ortho",
               "fixture premise: this leg must be orthographic");
        assert(!g.visible[P_RING_X], "the X ring is edge-on in a Front view");
        assert(!g.visible[P_RING_Y], "the Y ring is edge-on in a Front view");
        assert( g.visible[P_RING_Z], "the Z ring faces a Front view");
        assert( g.visible[P_RING_VIEW], "the screen-plane ring is never culled");
    }

    // 3. ORTHO FRONT, basis turned 45 degrees about Y. The two rings whose
    //    normals are 45 degrees to the eye are perfectly grabbable and must
    //    survive; only the Y ring, still exactly edge-on, goes.
    script("workplane.edit rotY:45");
    script("tool.pipe.attr axis mode workplane");
    {
        // Premise: the basis really did rotate. Read it back rather than
        // trusting that two commands landed — the whole point of this leg is
        // that the gizmo is NOT world-aligned, and a silently-ignored command
        // would leave leg 2's reading and prove nothing.
        {
            import std.conv : to;
            bool found = false;
            foreach (st; getJson("/api/toolpipe")["stages"].array) {
                if (st["id"].str != "axis") continue;
                found = true;
                auto a = st["attrs"];
                assert(a["mode"].str == "workplane",
                       "fixture premise: the axis stage must be in workplane mode");
                immutable double rx = to!double(a["rightX"].str);
                immutable double rz = to!double(a["rightZ"].str);
                assert(abs(rx - 0.707107) < 1e-3 && abs(rz + 0.707107) < 1e-3,
                       format("fixture premise: the axis basis must be turned 45 deg "
                              ~ "about Y, right = (%g, _, %g)", rx, rz));
            }
            assert(found, "fixture premise: the pipeline must publish an axis stage");
        }

        auto g = registry();
        assert(g.visible[P_RING_X],
               "a ring 45 degrees to the eye is grabbable and must be drawn — "
               ~ "the rule that kept only the FACE-ON ring left none of the three");
        assert(g.visible[P_RING_Z],
               "...and so is its partner in the turned basis");
        assert(!g.visible[P_RING_Y],
               "the Y ring is still exactly edge-on and is the one that goes");
        assert(g.visible[P_RING_VIEW], "the screen-plane ring is never culled");
    }
}
