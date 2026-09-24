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
//        -> Flow E, cell C1-front-gizmoRy40 (task 7139 moved the 45-degree
//           case there from Flow D leg 3, which a turned view no longer
//           separates). Legs 1 and 2 of Flow D stay GREEN under the mutation,
//           which is the point: the old rule is indistinguishable from this
//           one until the gizmo's basis stops being the view's basis.
//   * the gate reverted to `lockedViewAxis(vp) < 0` (a WORLD-axis view test)
//        -> Flow D leg 3 and Flow E cell K1 (task 7139).

import http_client : getJson, postRaw, testBaseUrl;
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
    script("workplane.reset");
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

    // 3. ORTHO FRONT under a plane pinned 45 degrees about Y, gizmo on the
    //    WORKPLANE axis. Since task 7139 the Front preset TURNS with the plane
    //    (gap 187), so it looks along the plane's -Z and its forward is no
    //    world axis. It is still an axis view — the gate is the view TYPE
    //    (capture gizmo_view_cull_plane, V-none) — so the gizmo's two rings
    //    edge-on to the turned view (X and Y) go and the face-on Z ring stays.
    //    The world-axis gate kept all three here, edge-on rings grabbable.
    //    The "45 degrees survive" half of this rule is the C1 cell below.
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
        assert(!g.visible[P_RING_X] && !g.visible[P_RING_Y],
               "a turned Front is still an axis view: the rings edge-on to it go");
        assert( g.visible[P_RING_Z], "the ring face-on to the turned view stays");
        assert(g.visible[P_RING_VIEW], "the screen-plane ring is never culled");
    }
}

// ---------------------------------------------------------------------------
// Flow E — the gate under a pinned plane, one cell per captured cell (task
// 7139; capture gizmo_view_cull_plane, verdict V-none;
// tests/fixtures/rotate_ring_cull_gate.json). An axis view is ortho AND on an
// axis preset — never "looks along a world axis" — and inside one a ring goes
// when |gizmo axis . eye| < 0.087. The gizmo basis is the ELEMENT axis of one
// quad built from the cell's own axes (element basis: up = face normal, right =
// first edge), read back before the rings are judged.
// ---------------------------------------------------------------------------
unittest {
    scope(exit) restoreWorld();
    auto fx = parseJSON(import("fixtures/rotate_ring_cull_gate.json"));
    auto cells = fx["cells"];
    enum string[] order = ["C0-front-world", "C1-front-gizmoRy40",
                           "K1-turned-gizmoBRx35", "K2-turned-gizmoBRz30",
                           "P1-persp-turned"];
    assert(cells.object.length == order.length,
           format("fixture population: %d cells, expected %d",
                  cells.object.length, order.length));
    int judged = 0;
    foreach (name; order) {
        auto c = cells[name];
        double[3][3] G;
        foreach (i; 0 .. 3) foreach (k; 0 .. 3) G[i][k] = jnum(c["gizmo_axes_world"].array[i].array[k]);
        double[3] w(double x, double z) {
            double[3] r;
            foreach (k; 0 .. 3) r[k] = 0.25 * (x * G[0][k] + z * G[2][k]);
            return r;
        }
        // Face winding (-X+Z)->(X+Z)->(X-Z)->(-X-Z): first edge +X, normal +Y.
        auto q = [w(-1, 1), w(1, 1), w(1, -1), w(-1, -1)];
        postRaw("/api/command", `{"id":"scene.reset","params":{"empty":true}}`);
        script("workplane.reset");
        postRaw("/api/command", format(
            `{"id":"scene.loadMesh","params":{"vertices":[[%.9f,%.9f,%.9f],[%.9f,%.9f,%.9f],`
          ~ `[%.9f,%.9f,%.9f],[%.9f,%.9f,%.9f]],"faces":[[0,1,2,3]]}}`,
            q[0][0], q[0][1], q[0][2], q[1][0], q[1][1], q[1][2],
            q[2][0], q[2][1], q[2][2], q[3][0], q[3][1], q[3][2]));
        postRaw("/api/command", `{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`);
        immutable bool persp = c["projection"].str == "perspective";
        command("viewport.view", persp ? `"Perspective"` : `"Front"`);
        if (c["plane_pinned"].type == JSONType.true_)
            script("workplane.edit rotX:30 rotY:40 rotZ:0");
        if (persp) {
            // Aimed along the turned Front's direction, in world terms.
            double[3] vd;
            foreach (k; 0 .. 3) vd[k] = jnum(c["view_dir_world"].array[k]);
            double[3] up = [0, 1, 0];
            double[3] b = [-vd[0], -vd[1], -vd[2]];
            double[3] r = [up[1]*b[2]-up[2]*b[1], up[2]*b[0]-up[0]*b[2], up[0]*b[1]-up[1]*b[0]];
            double rl = (r[0]*r[0] + r[1]*r[1] + r[2]*r[2]) ^^ 0.5;
            foreach (k; 0 .. 3) r[k] /= rl;
            double[3] u = [b[1]*r[2]-b[2]*r[1], b[2]*r[0]-b[0]*r[2], b[0]*r[1]-b[1]*r[0]];
            postRaw("/api/camera", format(
                `{"focus":{"x":0,"y":0,"z":0},"distance":3,"orientation":`
              ~ `[%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f]}`,
                r[0], r[1], r[2], u[0], u[1], u[2], b[0], b[1], b[2]));
        }
        script("tool.set rotate on");
        script("tool.pipe.attr axis mode element");

        // Premises: the view direction and the gizmo basis are the cell's.
        {
            import std.conv : to;
            auto cam = getJson("/api/camera");
            double[3] vdGot = [-jnum(cam["viewMatrix"].array[2]),
                               -jnum(cam["viewMatrix"].array[6]),
                               -jnum(cam["viewMatrix"].array[10])];
            foreach (k; 0 .. 3)
                assert(abs(vdGot[k] - jnum(c["view_dir_world"].array[k])) < 1e-3,
                       format("%s premise: view direction %s", name, vdGot));
            bool found;
            foreach (st; getJson("/api/toolpipe")["stages"].array) {
                if (st["id"].str != "axis") continue;
                found = true;
                auto a = st["attrs"];
                foreach (i, key; ["right", "up", "fwd"])
                    foreach (k, comp; ["X", "Y", "Z"])
                        assert(abs(to!double(a[key ~ comp].str) - G[i][k]) < 1e-3,
                               format("%s premise: gizmo axis %s%s = %s, fixture %g",
                                      name, key, comp, a[key ~ comp].str, G[i][k]));
            }
            assert(found, name ~ " premise: no axis stage");
        }

        auto g = registry();
        string hidden;
        foreach (i, letter; ["X", "Y", "Z"])
            if (!g.visible[ROT_BASE + cast(int)i]) hidden ~= letter;
        if (hidden.length == 0) hidden = "none";
        assert(hidden == c["measured_hidden_rings"].str,
               format("%s: hidden rotate rings %s, the reference hides %s", name,
                      hidden, c["measured_hidden_rings"].str));
        assert(g.visible[P_RING_VIEW], name ~ ": the screen-plane ring is never culled");
        ++judged;
        script("tool.set rotate off");
    }
    assert(judged == 5, format("judged %d cells, expected 5", judged));
}

private double jnum(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}
