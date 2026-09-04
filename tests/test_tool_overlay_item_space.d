// A tool's handles, and the gain of the drag they drive, in the space the mesh
// is DRAWN in — not the space it is STORED in.  (Task 0645.)
//
// ── WHAT THIS PINS ────────────────────────────────────────────────────────
//
// A layer carries an item transform; its mesh is stored in the layer's own
// coordinates and drawn through that matrix.  A tool that builds its gizmo out
// of mesh geometry therefore holds LOCAL quantities, and everything it hands
// them to — `drag.screenAxisDelta`, `drag.planeDragDelta`,
// `drag.haulWorldPerPixel`, `handles.gl_util.gizmoSize`, `Handler.draw`,
// `Handler.hitTest` — is a WORLD-space function.  Two things follow, and this
// file asserts both:
//
//   1. the handle is DRAWN where the geometry is drawn;
//   2. N pixels of drag produce the same WORLD displacement on a transformed
//      layer as on an untransformed one.
//
// ── THE TRAP, AND WHY THE FIXTURE IS SHAPED LIKE THIS ─────────────────────
//
// "The click hit the handle" PASSES with the bug live.  `ToolHandles` uses the
// same `Viewport` for `draw()` and for `hitTest()`, so the drawing and the
// hit-testing agree WITH EACH OTHER — the handle sits where the geometry would
// be at the identity pose, and the user still hits it.  Any assertion whose
// only content is "a press at the reported handle position grabbed the handle"
// measures nothing at all here.
//
// So the fixture separates the two candidate READINGS instead, twice over, by
// two independent routes:
//
//   * THE BAKE STAND.  The same drawn picture is built two ways — once as
//     `(local verts V, item matrix M)` and once as `(baked verts M*V, identity)`.
//     Both draw pixel-identically, so the handle must land on the same pixel.
//     Under the bug the first reads `centroid(V)` and the second `M*centroid(V)`,
//     hundreds of pixels apart.  This leg uses NO test-side projection at all.
//   * THE NAMED WRONG READING.  The two candidate anchor points are both
//     built and projected here — `M*c` (the geometry as drawn) and `c` (the
//     geometry at the identity pose) — and the handle is asserted to match the
//     first and to refuse the second.  A broken test-side projection would
//     match NEITHER, so this leg validates itself.
//
// The item transform carries translation AND rotation AND a different scale on
// every axis, so no two candidate readings can alias: a translation-only stand
// would leave every direction question invisible, a rotation-only one would let
// `M^-T` pass for `M` (they are equal for a rotation), and a uniform scale would
// let the drag gain pass for any single axis's.
//
// ── WHAT IS DELIBERATELY NOT PINNED ──────────────────────────────────────
//
// The arrow's DIRECTION under a non-uniform scale.  The stand's normal is a
// coordinate axis and the item scale is diagonal, so `L*n` and `L^-T*n` are
// parallel there and this fixture cannot separate them.  That is on purpose:
// which of the two an arrow should point along is a statement about what the
// KERNEL does to the geometry, not about the overlay, and `overlay_space.d`'s
// header says which one it picked and why.  The POSITION question — the one
// this task exists for — is fully separated.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, sin, cos, PI;
import std.format : format;
import std.conv   : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera,
                       // projectToWindow, gizmoSize, buildDragLog, playAndWait

void main() {}

alias BASE = testBaseUrl;

// --------------------------------------------------------------------------
// HTTP plumbing
// --------------------------------------------------------------------------


void cmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert("status" in r && r["status"].str == "ok",
           format("cmd `%s` failed: %s", argstring, r.toString()));
}
double attr(string tool, string name) {
    auto r = postJson("/api/command", format("tool.attr %s %s ?", tool, name));
    assert(r["status"].str == "ok", "attr read failed: " ~ r.toString());
    auto v = r["value"];
    return (v.type == JSONType.integer)  ? cast(double) v.integer
         : (v.type == JSONType.uinteger) ? cast(double) v.uinteger
                                         : v.floating;
}
// The registry is rebuilt on every interactive draw, so a read must follow a
// frame. Same 130 ms the other handle tests settle for.
void settle() { Thread.sleep(dur!"msecs"(160)); }

// --------------------------------------------------------------------------
// The stand: a unit cube, its top face (index 4, local normal +Y) selected.
// --------------------------------------------------------------------------
immutable double[3][8] CUBE = [
    [-0.5, -0.5, -0.5], [ 0.5, -0.5, -0.5], [ 0.5,  0.5, -0.5], [-0.5,  0.5, -0.5],
    [-0.5, -0.5,  0.5], [ 0.5, -0.5,  0.5], [ 0.5,  0.5,  0.5], [-0.5,  0.5,  0.5],
];
immutable int[4][6] FACES = [
    [4, 5, 6, 7],   // 0  front  +Z
    [1, 0, 3, 2],   // 1  back   -Z
    [5, 1, 2, 6],   // 2  right  +X
    [0, 4, 7, 3],   // 3  left   -X
    [7, 6, 2, 3],   // 4  top    +Y   <- the operand
    [0, 1, 5, 4],   // 5  bottom -Y
];
enum int TOP_FACE = 4;

// Translation AND rotation AND a DIFFERENT scale on all three axes.
immutable double[3] ITEM_POS = [ 2.5, -1.25,  0.75];
immutable double[3] ITEM_ROT = [20.0,  40.0,  65.0];   // degrees, applied ZYX
immutable double[3] ITEM_SCL = [ 2.0,   3.0,   0.5];

// The camera. Fixed explicitly so neither stand inherits whatever framing
// /api/load-mesh's reframe left behind (its `focus` leaks in otherwise, and the
// eye stops being a function of the fixture).
enum double CAM_AZ = 0.9, CAM_EL = 0.5, CAM_DIST = 8.0;

// --------------------------------------------------------------------------
// The item matrix, composed here from the same declared order document.d
// states (M = T(pos) . Rz.Ry.Rx . S, pivot 0), and cross-checked against the
// matrix the engine publishes. An independent formula, not a copy of the
// engine's answer — if the two disagree the fixture is wrong before any tool
// is involved.
// --------------------------------------------------------------------------
double[16] composeItemMatrix() {
    double d2r(double d) { return d * PI / 180.0; }
    double cx = cos(d2r(ITEM_ROT[0])), sx = sin(d2r(ITEM_ROT[0]));
    double cy = cos(d2r(ITEM_ROT[1])), sy = sin(d2r(ITEM_ROT[1]));
    double cz = cos(d2r(ITEM_ROT[2])), sz = sin(d2r(ITEM_ROT[2]));
    // R = Rz * Ry * Rx, row-major 3x3.
    double[3][3] R = [
        [ cz*cy,  cz*sy*sx - sz*cx,  cz*sy*cx + sz*sx],
        [ sz*cy,  sz*sy*sx + cz*cx,  sz*sy*cx - cz*sx],
        [   -sy,             cy*sx,             cy*cx],
    ];
    // L = R * diag(scl); column-major float[16] layout.
    double[16] m;
    foreach (c; 0 .. 3)
        foreach (r; 0 .. 3)
            m[c*4 + r] = R[r][c] * ITEM_SCL[c];
    m[3] = m[7] = m[11] = 0;
    m[12] = ITEM_POS[0]; m[13] = ITEM_POS[1]; m[14] = ITEM_POS[2]; m[15] = 1;
    return m;
}

double[3] applyAffine(const double[16] m, const double[3] p) {
    return [m[0]*p[0] + m[4]*p[1] + m[ 8]*p[2] + m[12],
            m[1]*p[0] + m[5]*p[1] + m[ 9]*p[2] + m[13],
            m[2]*p[0] + m[6]*p[1] + m[10]*p[2] + m[14]];
}
double[3] applyLinear(const double[16] m, const double[3] v) {
    return [m[0]*v[0] + m[4]*v[1] + m[ 8]*v[2],
            m[1]*v[0] + m[5]*v[1] + m[ 9]*v[2],
            m[2]*v[0] + m[6]*v[1] + m[10]*v[2]];
}
double len3(const double[3] v) { return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
Vec3 v3(const double[3] p) { return Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]); }

// --------------------------------------------------------------------------
// Stand construction.
//
// `transformed == true`  -> local verts V, item matrix M.
// `transformed == false` -> baked verts M*V, identity item matrix.
// The two DRAW the same picture; that is the whole point.
// --------------------------------------------------------------------------
void buildStand(bool transformed) {
    postJson("/api/command", commandBody("scene.reset", "{}"));

    auto M = composeItemMatrix();
    string verts = "[";
    foreach (i, p; CUBE) {
        double[3] q = transformed ? cast(double[3]) p : applyAffine(M, p);
        verts ~= (i ? "," : "") ~ format("[%.10g,%.10g,%.10g]", q[0], q[1], q[2]);
    }
    verts ~= "]";
    string faces = "[";
    foreach (i, f; FACES) {
        faces ~= (i ? ",[" : "[");
        foreach (k, vi; f) faces ~= (k ? "," : "") ~ vi.to!string;
        faces ~= "]";
    }
    faces ~= "]";
    auto lm = postJson("/api/command", commandBody("scene.loadMesh", format(`{"vertices":%s,"faces":%s}`, verts, faces)));
    assert(lm["status"].str == "ok", "load-mesh failed: " ~ lm.toString());

    // Written in BOTH stands, identity included, so neither inherits a
    // leftover transform from a prior stand in the same process.
    static immutable string[3] ax = ["x", "y", "z"];
    foreach (i; 0 .. 3) {
        cmd(format("layer.attr 0 pos.%s %.10g", ax[i], transformed ? ITEM_POS[i] : 0.0));
        cmd(format("layer.attr 0 rot.%s %.10g", ax[i], transformed ? ITEM_ROT[i] : 0.0));
        cmd(format("layer.attr 0 scl.%s %.10g", ax[i], transformed ? ITEM_SCL[i] : 1.0));
        cmd(format("layer.attr 0 pivot.%s 0", ax[i]));
    }

    // The camera is set AFTER load-mesh (which reframes) and is identical for
    // both stands — they are the same picture, so they must be looked at from
    // the same place.
    auto cr = postJson("/api/camera", format(
        `{"azimuth":%.10g,"elevation":%.10g,"distance":%.10g,"roll":0,` ~
        `"focus":{"x":%.10g,"y":%.10g,"z":%.10g}}`,
        CAM_AZ, CAM_EL, CAM_DIST, ITEM_POS[0], ITEM_POS[1], ITEM_POS[2]));
    assert("status" !in cr || cr["status"].str != "error",
           "camera set failed: " ~ cr.toString());

    postJson("/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, TOP_FACE)));
    settle();
}

// The top face's own ring, in whichever element type a tool wants. Every one
// of these resolves to the SAME averaged normal — local +Y — because the four
// side faces' normals cancel in pairs. That is what makes the bake stand a
// legal comparison for these tools: a local coordinate axis is an eigenvector
// of `L^T L` for a diagonal scale, so `L*n` and `L^-T*n` stay parallel and the
// baked stand's recomputed normal points the same way.
void selectTopRing(string mode) {
    if (mode == "polygons") {
        postJson("/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, TOP_FACE)));
    } else if (mode == "vertices") {
        postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[2,3,6,7]}`));
    } else {
        auto m = getJson("/api/model");
        static immutable int[2][4] ring = [[7,6],[6,2],[2,3],[3,7]];
        int[] idx;
        foreach (pair; ring) {
            bool got = false;
            foreach (i, e; m["edges"].array) {
                int a = cast(int) e.array[0].integer, b = cast(int) e.array[1].integer;
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    idx ~= cast(int) i; got = true; break;
                }
            }
            assert(got, format("no edge (%d,%d) on the stand", pair[0], pair[1]));
        }
        string js = "[";
        foreach (k, i; idx) js ~= (k ? "," : "") ~ i.to!string;
        js ~= "]";
        postJson("/api/command", commandBody("mesh.select", format(`{"mode":"edges","indices":%s}`, js)));
    }
    settle();
}

// The engine's own composed matrix for the transformed stand — the
// cross-check on `composeItemMatrix`.
double[16] publishedMatrix() {
    auto j = getJson("/api/layers");
    auto arr = j["layers"].array[0]["xform"]["matrix"].array;
    double[16] m;
    foreach (i; 0 .. 16) {
        auto e = arr[i];
        m[i] = (e.type == JSONType.integer)  ? cast(double) e.integer
             : (e.type == JSONType.uinteger) ? cast(double) e.uinteger
                                             : e.floating;
    }
    return m;
}

// --------------------------------------------------------------------------
// GET /api/tool/handles -> the screen anchor of one part.
// --------------------------------------------------------------------------
bool handleScreen(int part, out double sx, out double sy) {
    auto j = getJson("/api/tool/handles");
    if (j["handles"].type == JSONType.null_) return false;
    foreach (p; j["handles"]["parts"].array) {
        if (cast(int) p["part"].integer != part) continue;
        if (p["screen"].type == JSONType.null_) return false;
        sx = p["screen"].array[0].floating;
        sy = p["screen"].array[1].floating;
        return true;
    }
    return false;
}

double pixDist(double ax, double ay, double bx, double by) {
    return sqrt((ax-bx)*(ax-bx) + (ay-by)*(ay-by));
}

// The screen point `ShaftedArrow.screenAnchor` reports: 70% of the way from
// `start` to `end`. `frac` is where that lands as a fraction of the arm:
//   * poly.bevel's SHIFT Arrow spans arm/6 .. arm  ->  1/6 + 0.7*5/6 = 0.75
//   * its INSET CubicArrow spans 0 .. arm          ->        0.7
// Built from an anchor and a direction so the SAME formula can be fed the
// drawn-geometry reading and the identity-pose one.
bool arrowAnchorPixel(double[3] anchor, double[3] dirUnit, double frac,
                      const ref Viewport vp, out double px, out double py)
{
    float arm = gizmoSize(v3(anchor), vp);
    double[3] grab = [anchor[0] + dirUnit[0]*arm*frac,
                      anchor[1] + dirUnit[1]*arm*frac,
                      anchor[2] + dirUnit[2]*arm*frac];
    float fx, fy;
    if (!projectToWindow(v3(grab), vp, fx, fy)) return false;
    px = fx; py = fy;
    return true;
}

double[3] unit3(double[3] v) {
    double l = len3(v);
    assert(l > 1e-9, "cannot normalise a zero vector");
    return [v[0]/l, v[1]/l, v[2]/l];
}
double[3] cross3(double[3] a, double[3] b) {
    return [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]];
}

// --------------------------------------------------------------------------
// 0. The fixture checks itself: the hand-composed matrix reproduces the one
//    the engine publishes, and the three readings the later legs separate are
//    genuinely distinct.
//
//    Without this, every assertion below could be scoring a wrong matrix
//    against itself.
// --------------------------------------------------------------------------
unittest {
    buildStand(true);
    auto mine = composeItemMatrix();
    auto theirs = publishedMatrix();
    double worst = 0;
    foreach (i; 0 .. 16) {
        double d = fabs(mine[i] - theirs[i]);
        if (d > worst) worst = d;
    }
    assert(worst < 1e-5,
        format("hand-composed item matrix disagrees with /api/layers by %.6g", worst));

    // The gain the drag legs assert. |L*y| == scl.y exactly, because R is a
    // proper rotation and S is diagonal — asserted, not assumed, so a change
    // to the composition order shows up here rather than as a mystery in the
    // drag leg.
    double gy = len3(applyLinear(mine, [0.0, 1.0, 0.0]));
    assert(fabs(gy - ITEM_SCL[1]) < 1e-6,
        format("axis gain along local +Y should be scl.y=%g, got %g", ITEM_SCL[1], gy));

    // Anti-vacuity for every leg below: the three axis gains must be pairwise
    // different, or "converted with the wrong axis's gain" would pass.
    double gx = len3(applyLinear(mine, [1.0, 0.0, 0.0]));
    double gz = len3(applyLinear(mine, [0.0, 0.0, 1.0]));
    assert(fabs(gx - gy) > 0.5 && fabs(gy - gz) > 0.5 && fabs(gx - gz) > 0.5,
        format("the three axis gains must not alias: %g / %g / %g", gx, gy, gz));
}

// --------------------------------------------------------------------------
// 1. poly.bevel — the handle is drawn where the geometry is drawn.
//
//    Leg A (no test-side projection): the transformed stand and the baked
//    stand report the SAME pixel.
//    Leg B (the named wrong reading): that pixel is the one `M*centroid`
//    projects to, and NOT the one `centroid` projects to.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "poly.bevel";

    buildStand(true);
    cmd("tool.set " ~ TOOL ~ " on");
    settle();
    double tSX, tSY, tIX, tIY;
    assert(handleScreen(0, tSX, tSY), "transformed stand: shift arrow has no screen anchor");
    assert(handleScreen(1, tIX, tIY), "transformed stand: inset box has no screen anchor");

    // The camera is identical in both stands; read it once, from this one.
    auto vp = viewportFromCamera(fetchCamera());
    cmd("tool.set " ~ TOOL ~ " off");

    buildStand(false);
    cmd("tool.set " ~ TOOL ~ " on");
    settle();
    double bSX, bSY, bIX, bIY;
    assert(handleScreen(0, bSX, bSY), "baked stand: shift arrow has no screen anchor");
    assert(handleScreen(1, bIX, bIY), "baked stand: inset box has no screen anchor");
    cmd("tool.set " ~ TOOL ~ " off");

    // ---- Leg B: the two candidate readings, built and projected here. ----
    auto M = composeItemMatrix();
    immutable double[3] cLocal = [0.0, 0.5, 0.0];        // top-face centroid, LOCAL
    immutable double[3] nLocal = [0.0, 1.0, 0.0];        // its normal,        LOCAL
    double[3] cWorld = applyAffine(M, cLocal);
    double[3] nWorldRaw = applyLinear(M, nLocal);
    double nl = len3(nWorldRaw);
    double[3] nWorld = [nWorldRaw[0]/nl, nWorldRaw[1]/nl, nWorldRaw[2]/nl];

    double drawnX, drawnY, identX, identY;
    assert(arrowAnchorPixel(cWorld, nWorld, 0.75, vp, drawnX, drawnY),
           "the drawn-geometry candidate must project");
    assert(arrowAnchorPixel(cLocal, nLocal, 0.75, vp, identX, identY),
           "the identity-pose candidate must project");

    double spread = pixDist(drawnX, drawnY, identX, identY);
    assert(spread > 100.0, format(
        "the fixture does not separate the two readings (only %.1f px apart) — " ~
        "every assertion below would be vacuous", spread));

    assert(pixDist(tSX, tSY, drawnX, drawnY) < 3.0, format(
        "the shift arrow is not at the DRAWN geometry: handle (%.1f, %.1f), " ~
        "drawn (%.1f, %.1f), identity-pose (%.1f, %.1f)",
        tSX, tSY, drawnX, drawnY, identX, identY));
    assert(pixDist(tSX, tSY, identX, identY) > 50.0, format(
        "the shift arrow sits at the IDENTITY-POSE geometry (%.1f, %.1f)", tSX, tSY));

    // The INSET box, same two readings. Its axis is the tool's own in-plane
    // reference direction, `normalize(cross(shiftAxis, up))` with `up` elected
    // from `shiftAxis` — reproduced here in the LOCAL frame, which is where
    // `computeGizmoFrame` builds it, and then lifted like any other local
    // direction.
    double[3] upLocal = (fabs(nLocal[1]) < 0.9) ? [0.0, 1.0, 0.0] : [1.0, 0.0, 0.0];
    double[3] iLocal  = unit3(cross3(cast(double[3]) nLocal, upLocal));
    double[3] iWorld  = unit3(applyLinear(M, iLocal));
    double insDrawnX, insDrawnY, insIdentX, insIdentY;
    assert(arrowAnchorPixel(cWorld, iWorld, 0.70, vp, insDrawnX, insDrawnY),
           "the drawn-geometry inset candidate must project");
    assert(arrowAnchorPixel(cLocal, iLocal, 0.70, vp, insIdentX, insIdentY),
           "the identity-pose inset candidate must project");
    assert(pixDist(insDrawnX, insDrawnY, insIdentX, insIdentY) > 100.0,
           "the fixture does not separate the two readings for the inset box");
    assert(pixDist(tIX, tIY, insDrawnX, insDrawnY) < 3.0, format(
        "the inset box is not at the DRAWN geometry: handle (%.1f, %.1f), " ~
        "drawn (%.1f, %.1f), identity-pose (%.1f, %.1f)",
        tIX, tIY, insDrawnX, insDrawnY, insIdentX, insIdentY));
    assert(pixDist(tIX, tIY, insIdentX, insIdentY) > 50.0, format(
        "the inset box sits at the IDENTITY-POSE geometry (%.1f, %.1f)", tIX, tIY));

    // ---- Leg A: the bake stand. No projection involved at all. ----
    //
    // The SHIFT arrow only, and the exclusion is not slack. Baking `M` into
    // the vertices is behaviour-preserving for the ANCHOR (a centroid is an
    // average, and an affine map commutes with averaging) and for THIS arrow's
    // direction (the stand's normal is a coordinate axis and the item scale is
    // diagonal, so `L*n` and `L^-T*n` are parallel). It is NOT behaviour-
    // preserving for the INSET axis: `computeGizmoFrame` elects `up` by asking
    // whether `|shiftAxis.y| < 0.9`, and that question has different answers
    // for a local +Y and for the rotated world normal the baked stand hands it
    // — a different in-plane reference direction, measured 36 px away when
    // this leg tried to cover it. The inset box's POSITION claim is carried by
    // Leg B above instead, where the reference direction is reconstructed in
    // the frame the tool actually builds it in.
    assert(pixDist(tSX, tSY, bSX, bSY) < 1.0, format(
        "same picture, two poses: shift arrow at (%.1f, %.1f) with an item " ~
        "matrix vs (%.1f, %.1f) with the matrix baked into the vertices — " ~
        "%.1f px apart", tSX, tSY, bSX, bSY, pixDist(tSX, tSY, bSX, bSY)));
    // `bIX`/`bIY` are read and deliberately NOT compared — see above.
    cast(void) bIX; cast(void) bIY;
}

// --------------------------------------------------------------------------
// 2. poly.bevel — N pixels of drag produce the same WORLD displacement on the
//    transformed layer as on the untransformed one.
//
//    `shift` is a LOCAL length applied along the local face normal, so its
//    world reading is `shift * |L*n|`. The two stands are dragged from the
//    same press pixel (they draw the same handle in the same place) by the
//    same pixel offset, so their world readings must match.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "poly.bevel";

    // Aim the drag along the arrow's own screen direction so the projection
    // is well-conditioned; derived from the drawn geometry, once.
    auto M = composeItemMatrix();
    immutable double[3] cLocal = [0.0, 0.5, 0.0];
    immutable double[3] nLocal = [0.0, 1.0, 0.0];
    double[3] cWorld = applyAffine(M, cLocal);
    double[3] nWorldRaw = applyLinear(M, nLocal);
    double nl = len3(nWorldRaw);
    double[3] nWorld = [nWorldRaw[0]/nl, nWorldRaw[1]/nl, nWorldRaw[2]/nl];
    double gainY = nl;   // world length of one local unit along the shift axis

    double shiftOf(bool transformed, out int pressX, out int pressY) {
        buildStand(transformed);
        cmd("tool.set " ~ TOOL ~ " on");
        settle();
        double hx, hy;
        assert(handleScreen(0, hx, hy), "shift arrow has no screen anchor");
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);

        // Tip pixel, for the drag direction.
        float arm = gizmoSize(v3(cWorld), vp);
        double[3] tip = [cWorld[0] + nWorld[0]*arm,
                         cWorld[1] + nWorld[1]*arm,
                         cWorld[2] + nWorld[2]*arm];
        float tx, ty;
        assert(projectToWindow(v3(tip), vp, tx, ty), "arrow tip must project");
        double dx = tx - hx, dy = ty - hy;
        double dl = sqrt(dx*dx + dy*dy);
        assert(dl > 5.0, "the arrow is too foreshortened to drag against");
        enum double DRAG_PX = 60.0;
        int x0 = cast(int) hx, y0 = cast(int) hy;
        int x1 = cast(int)(hx + dx / dl * DRAG_PX);
        int y1 = cast(int)(hy + dy / dl * DRAG_PX);
        pressX = x0; pressY = y0;

        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x1, y1, 12), BASE);
        settle();
        double v = attr(TOOL, "shift");
        cmd("tool.set " ~ TOOL ~ " off");
        return v;
    }

    int tpx, tpy, bpx, bpy;
    double shiftT = shiftOf(true,  tpx, tpy);
    double shiftB = shiftOf(false, bpx, bpy);

    // The presses must have landed on the same pixel — otherwise the two
    // stands were not given the same drag and the comparison below is
    // meaningless. (Under the pre-0645 reading they differ by hundreds.)
    assert(pixDist(tpx, tpy, bpx, bpy) < 2.0, format(
        "the two stands were pressed at different pixels: (%d,%d) vs (%d,%d)",
        tpx, tpy, bpx, bpy));

    assert(fabs(shiftB) > 0.05, format(
        "the control drag produced almost nothing (shift=%.6f) — the assertion " ~
        "below would pass on two zeros", shiftB));

    double worldT = shiftT * gainY;
    assert(fabs(worldT - shiftB) < 0.02 * fabs(shiftB) + 1e-4, format(
        "same drag, different world displacement: transformed layer moved %.6f " ~
        "world units (shift=%.6f x gain=%.4f), untransformed layer moved %.6f",
        worldT, shiftT, gainY, shiftB));
}

// --------------------------------------------------------------------------
// 3. Polygon inset — the directionless haul (LAW C) carries the item scale too.
//
//    `inset` has no axis, so its conversion is the declared mean of the three
//    axis gains (`OverlaySpace.meanWorldPerLocal`). Same two stands, same
//    vertical drag; the world readings must match.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "mesh.polyInsetTool";

    auto M = composeItemMatrix();
    double meanGain = (len3(applyLinear(M, [1.0, 0.0, 0.0])) +
                       len3(applyLinear(M, [0.0, 1.0, 0.0])) +
                       len3(applyLinear(M, [0.0, 0.0, 1.0]))) / 3.0;

    double insetOf(bool transformed) {
        buildStand(transformed);
        cmd("tool.set " ~ TOOL ~ " on");
        settle();
        auto cam = fetchCamera();
        // No handle to hit — any qualifying press starts the haul, anchored at
        // the selected faces' centroid. Press in the middle of the pane and
        // drag straight up.
        int x0 = cam.vpX + cam.width / 2;
        int y0 = cam.vpY + cam.height / 2 + 40;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x0, y0 - 60, 12), BASE);
        settle();
        double v = attr(TOOL, "inset");
        cmd("tool.set " ~ TOOL ~ " off");
        return v;
    }

    double insetT = insetOf(true);
    double insetB = insetOf(false);

    assert(fabs(insetB) > 0.05, format(
        "the control haul produced almost nothing (inset=%.6f)", insetB));
    assert(fabs(meanGain - 1.0) > 0.3, format(
        "the stand's mean gain is %.4f — too close to 1 to separate the two " ~
        "readings", meanGain));

    double worldT = insetT * meanGain;
    assert(fabs(worldT - insetB) < 0.02 * fabs(insetB) + 1e-4, format(
        "same haul, different world distance: transformed layer %.6f " ~
        "(inset=%.6f x mean gain=%.4f), untransformed layer %.6f",
        worldT, insetT, meanGain, insetB));
}

// --------------------------------------------------------------------------
// 4. The edge-slice handle bank — the instance task 0649 measured and left
//    open by name.
//
//    Its handles are `BoxHandler`s, so `screenAnchor` is the projection of the
//    handle's own position with no arm arithmetic in the way: the strongest
//    form of "the handle is where the geometry is drawn" available anywhere in
//    this family.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "mesh.edgeSliceTool";

    // Which two edges, and where on them — resolved from the model BEFORE the
    // arm, because arming cuts the mesh and renumbers the edge table.
    buildStand(true);
    auto m0 = getJson("/api/model");
    uint edgeByVerts(JSONValue m, int a, int b) {
        foreach (i, e; m["edges"].array) {
            int p = cast(int) e.array[0].integer, q = cast(int) e.array[1].integer;
            if ((p == a && q == b) || (p == b && q == a)) return cast(uint) i;
        }
        assert(false, format("no edge (%d,%d)", a, b));
    }
    // Two opposite edges of the BOTTOM face, so the chain is well away from
    // the selected top face and the handles sit clear of each other.
    uint eA = edgeByVerts(m0, 0, 1);
    uint eB = edgeByVerts(m0, 4, 5);
    double[3] endpoint(JSONValue m, uint e, int which) {
        int vi = cast(int) m["edges"].array[e].array[which].integer;
        auto v = m["vertices"].array[vi].array;
        return [v[0].floating, v[1].floating, v[2].floating];
    }
    double[3] a0 = endpoint(m0, eA, 0), a1 = endpoint(m0, eA, 1);
    double[3] b0 = endpoint(m0, eB, 0), b1 = endpoint(m0, eB, 1);

    void arm() {
        cmd("tool.set " ~ TOOL ~ " on");
        cmd(format("tool.attr %s edges {%d,%d}", TOOL, eA, eB));
        cmd("tool.attr " ~ TOOL ~ " tA 0.25");
        cmd("tool.attr " ~ TOOL ~ " tB 0.75");
        cmd("tool.attr " ~ TOOL ~ " chainArm {1}");
        settle();
    }
    arm();
    double t0X, t0Y, t1X, t1Y;
    assert(handleScreen(0, t0X, t0Y), "transformed stand: chain handle 0 has no anchor");
    assert(handleScreen(1, t1X, t1Y), "transformed stand: chain handle 1 has no anchor");
    auto vp = viewportFromCamera(fetchCamera());
    cmd("tool.set " ~ TOOL ~ " off");

    // The two candidate readings for handle 0, built here.
    double[3] lerp3(double[3] p, double[3] q, double t) {
        return [p[0] + (q[0]-p[0])*t, p[1] + (q[1]-p[1])*t, p[2] + (q[2]-p[2])*t];
    }
    auto M = composeItemMatrix();
    double[3] pLocal = lerp3(a0, a1, 0.25);
    double[3] pWorld = applyAffine(M, pLocal);
    float dwX, dwY, idX, idY;
    assert(projectToWindow(v3(pWorld), vp, dwX, dwY), "the drawn chain point must project");
    assert(projectToWindow(v3(pLocal), vp, idX, idY), "the identity-pose chain point must project");
    assert(pixDist(dwX, dwY, idX, idY) > 100.0, format(
        "the fixture does not separate the two readings for the chain point " ~
        "(only %.1f px apart)", pixDist(dwX, dwY, idX, idY)));

    assert(pixDist(t0X, t0Y, dwX, dwY) < 1.5, format(
        "chain handle 0 is not at the DRAWN geometry: handle (%.1f, %.1f), " ~
        "drawn (%.1f, %.1f), identity-pose (%.1f, %.1f)",
        t0X, t0Y, dwX, dwY, idX, idY));
    assert(pixDist(t0X, t0Y, idX, idY) > 50.0, format(
        "chain handle 0 sits at the IDENTITY-POSE geometry (%.1f, %.1f)", t0X, t0Y));

    // And the bake stand, projection-free.
    buildStand(false);
    auto mB = getJson("/api/model");
    eA = edgeByVerts(mB, 0, 1);
    eB = edgeByVerts(mB, 4, 5);
    arm();
    double b0X, b0Y, b1X, b1Y;
    assert(handleScreen(0, b0X, b0Y), "baked stand: chain handle 0 has no anchor");
    assert(handleScreen(1, b1X, b1Y), "baked stand: chain handle 1 has no anchor");
    cmd("tool.set " ~ TOOL ~ " off");

    assert(pixDist(t0X, t0Y, b0X, b0Y) < 1.0, format(
        "same picture, two poses: chain handle 0 at (%.1f, %.1f) vs (%.1f, %.1f) " ~
        "— %.1f px apart", t0X, t0Y, b0X, b0Y, pixDist(t0X, t0Y, b0X, b0Y)));
    assert(pixDist(t1X, t1Y, b1X, b1Y) < 1.0, format(
        "same picture, two poses: chain handle 1 at (%.1f, %.1f) vs (%.1f, %.1f) " ~
        "— %.1f px apart", t1X, t1Y, b1X, b1Y, pixDist(t1X, t1Y, b1X, b1Y)));
}

// --------------------------------------------------------------------------
// 5. the array tool — the plane drag (LAW B) answers in WORLD and the offset it
//    feeds is LAYER-space, so it converts back as a full vector.
//
//    Unlike the axis hauls there is no gain to elect here: the whole
//    displacement goes through the linear inverse. Asserted as "the same drag
//    moves the copy the same distance in the world", i.e. |L * offset_T| ==
//    |offset_B|, plus the direction.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "mesh.arrayTool";

    // The DELTA the drag added, not the absolute offset: `offX/offY/offZ`
    // default to (1,1,1), a layer-space baseline the drag never touches and
    // which must not be run through the item matrix along with the drag.
    double[3] offsetOf(bool transformed) {
        buildStand(transformed);
        cmd("tool.set " ~ TOOL ~ " on");
        settle();
        double[3] pre = [attr(TOOL, "offX"), attr(TOOL, "offY"), attr(TOOL, "offZ")];
        auto cam = fetchCamera();
        int x0 = cam.vpX + cam.width / 2;
        int y0 = cam.vpY + cam.height / 2;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x0 + 70, y0 - 40, 12), BASE);
        settle();
        double[3] post = [attr(TOOL, "offX"), attr(TOOL, "offY"), attr(TOOL, "offZ")];
        cmd("tool.set " ~ TOOL ~ " off");
        return [post[0] - pre[0], post[1] - pre[1], post[2] - pre[2]];
    }

    double[3] offT = offsetOf(true);
    double[3] offB = offsetOf(false);

    assert(len3(offB) > 0.05, format(
        "the control drag produced almost no offset (%.6f)", len3(offB)));

    auto M = composeItemMatrix();
    double[3] worldT = applyLinear(M, offT);
    double[3] d = [worldT[0]-offB[0], worldT[1]-offB[1], worldT[2]-offB[2]];
    assert(len3(d) < 0.02 * len3(offB) + 1e-4, format(
        "same drag, different world offset: transformed layer (%.4f,%.4f,%.4f) " ~
        "lifts to (%.4f,%.4f,%.4f), untransformed layer (%.4f,%.4f,%.4f) — " ~
        "%.4f apart",
        offT[0], offT[1], offT[2], worldT[0], worldT[1], worldT[2],
        offB[0], offB[1], offB[2], len3(d)));

    // Anti-vacuity: the raw layer-space offsets must NOT already agree, or the
    // assertion above would pass without any conversion happening.
    double[3] raw = [offT[0]-offB[0], offT[1]-offB[1], offT[2]-offB[2]];
    assert(len3(raw) > 0.1 * len3(offB), format(
        "the two stands produced the same LAYER-space offset (%.6f apart) — " ~
        "the conversion is not being exercised", len3(raw)));
}

// --------------------------------------------------------------------------
// 6. The rest of the family — every remaining single-arrow tool reports its
//    primary handle at the same pixel on both stands.
//
//    Projection-free, and it is the cheap half of Leg 1 applied across the
//    files that share the seam: each of these builds its arm from a selection
//    centroid and an averaged face normal, hands them to `gizmoSize` and to a
//    `Handler` the world viewport draws AND hit-tests, and would therefore
//    park its handle at the identity pose without the lift. The operand is the
//    top face's own ring in each element type, so every tool's axis is the
//    same local +Y (see `selectTopRing`).
// --------------------------------------------------------------------------
unittest {
    static struct Case { string tool; string mode; }
    static immutable Case[] cases = [
        Case("poly.extrude",         "polygons"),
        Case("mesh.smoothShiftTool", "polygons"),
        Case("edge.bevel",           "edges"),
        Case("edge.extrude",         "edges"),
        Case("mesh.vertexBevel",     "vertices"),
        Case("mesh.vertexExtrude",   "vertices"),
    ];

    foreach (c; cases) {
        double[2] read(bool transformed) {
            buildStand(transformed);
            selectTopRing(c.mode);
            cmd("tool.set " ~ c.tool ~ " on");
            settle();
            double sx, sy;
            assert(handleScreen(0, sx, sy),
                   c.tool ~ ": primary handle has no screen anchor");
            cmd("tool.set " ~ c.tool ~ " off");
            return [sx, sy];
        }
        auto t = read(true);
        auto b = read(false);
        assert(pixDist(t[0], t[1], b[0], b[1]) < 1.0, format(
            "%s: same picture, two poses — handle at (%.1f, %.1f) with an item " ~
            "matrix vs (%.1f, %.1f) with the matrix baked into the vertices, " ~
            "%.1f px apart", c.tool, t[0], t[1], b[0], b[1],
            pixDist(t[0], t[1], b[0], b[1])));
    }
}

// --------------------------------------------------------------------------
// 7. vert.merge — the second directionless haul (LAW C), and the last member
//    of the family with an observable of its own.
//
//    `dist` is a merge threshold in LAYER units. Same drag on both stands; the
//    world readings must match.
// --------------------------------------------------------------------------
unittest {
    enum string TOOL = "vert.merge";

    auto M = composeItemMatrix();
    double meanGain = (len3(applyLinear(M, [1.0, 0.0, 0.0])) +
                       len3(applyLinear(M, [0.0, 1.0, 0.0])) +
                       len3(applyLinear(M, [0.0, 0.0, 1.0]))) / 3.0;

    double distOf(bool transformed) {
        buildStand(transformed);
        selectTopRing("vertices");
        cmd("tool.set " ~ TOOL ~ " on");
        settle();
        auto cam = fetchCamera();
        int x0 = cam.vpX + cam.width / 2;
        int y0 = cam.vpY + cam.height / 2 + 40;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x0, y0 - 60, 12), BASE);
        settle();
        double v = attr(TOOL, "dist");
        cmd("tool.set " ~ TOOL ~ " off");
        return v;
    }

    double dT = distOf(true);
    double dB = distOf(false);

    assert(fabs(dB) > 0.05, format(
        "the control haul produced almost nothing (dist=%.6f)", dB));
    assert(fabs(dT * meanGain - dB) < 0.02 * fabs(dB) + 1e-4, format(
        "same haul, different world threshold: transformed layer %.6f " ~
        "(dist=%.6f x mean gain=%.4f), untransformed layer %.6f",
        dT * meanGain, dT, meanGain, dB));
}
