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
import std.math  : abs, sqrt;
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

// -------------------------------------------------------------------------
// Projection-wiring: off-gizmo click in Auto mode relocates onto the
// PRINCIPAL-AXIS PLANE the camera is most directly facing, NOT onto a
// fixed ground plane (Y=0).
//
// This is an EVIDENCE-JUSTIFIED FLIP, not test-fitting. An earlier task
// pinned the fixed-ground-plane behaviour here based on a paper argument
// over a genuinely contested axis rule (see doc/acen_auto_port_plan.md,
// "Conflict B"). A subsequent discriminating live capture across two
// independent camera families (X-dominant, Z-dominant) plus an
// in-session camera tumble (Z-dominant → X-dominant, watching the pinned
// axis follow the camera) confirmed at high confidence that the correct
// rule is camera-facing (argmax|fwd|), computed instantaneously per the
// current view with no sticky state (doc/acen_auto_port_plan.md;
// scratchpad capture memos referenced there). This test now pins THAT
// confirmed behaviour and is the before/after discriminator for the fix:
//   PRE-FIX  (bug):     the binary always projects onto the fixed +Y
//                        ground plane → cenY ≈ 0 regardless of camera.
//   POST-FIX (correct): the binary projects onto pickMostFacingPlane(vp)
//                        (the camera-facing axis plane) → for this
//                        side-view camera cenX ≈ 0 (through the focus,
//                        which equals the origin here) and cenY is a
//                        free in-plane coordinate (≫ 0 for this pixel).
//
// Mechanism: identical to test_relocate_boundary.d (proven) — off-gizmo
// mouse-DOWN via buildDragLog/playAndWait, pivot read via evalPivot().
//
// Discriminating camera: azimuth=1.4, elevation=0.15, focus=(0,0,0). The
// /api/camera POST handler only consumes azimuth/elevation/distance/focus
// (no "eye" field — the eye is always derived from the spherical triple),
// so the camera is set explicitly in those terms rather than by a
// (silently-ignored) eye position. This gives a camera forward dominantly
// −X (≈(−0.97,−0.15,−0.17)) — |view[2]|=avx is the largest component — so
// pickMostFacingPlane returns normal=(1,0,0) (the X-plane through the
// focus — which is also the origin for this camera, so this is a PURE
// axis discriminator, with no focus-vs-origin entanglement; that is
// covered separately by the two tests below).  Projecting the click ray
// onto that plane gives a hit with Y ≠ 0, which distinguishes it clearly
// from a ground-plane hit with Y≈0.
//
// The MANDATORY discriminator (plan Risk 8) is encoded in-test:
//   groundHit  = rayPlaneIntersect(eye, dir, (0,0,0), (0,1,0))  [bug]
//   facingHit  = rayPlaneIntersect(eye, dir, (0,0,0), (1,0,0))  [reference]
// We assert:
//   (a) relocated center ≈ facingHit  (full X/Y/Z)
//   (b) relocated center ≠ groundHit  (Y component differs by > 0.5)
// -------------------------------------------------------------------------

// Inline screenRay + rayPlaneIntersect — duplicated from source/math.d
// so the test binary compiles without pulling in the app sources.
private Vec3 testScreenRay(float sx, float sy, const ref Viewport vp) {
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(v[0]*vx + v[1]*vy + v[2]*(-1.0f),
                  v[4]*vx + v[5]*vy + v[6]*(-1.0f),
                  v[8]*vx + v[9]*vy + v[10]*(-1.0f));
    float len = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    return len > 1e-9f ? Vec3(d.x/len, d.y/len, d.z/len) : Vec3(0, 0, -1);
}

private bool testRayPlaneIntersect(Vec3 origin, Vec3 dir,
                                    Vec3 planePoint, Vec3 n, out Vec3 hit) {
    float denom = n.x*dir.x + n.y*dir.y + n.z*dir.z;
    if (abs(denom) < 1e-6f) return false;
    Vec3 d = Vec3(planePoint.x - origin.x,
                  planePoint.y - origin.y,
                  planePoint.z - origin.z);
    float t = (n.x*d.x + n.y*d.y + n.z*d.z) / denom;
    hit = Vec3(origin.x + dir.x*t,
               origin.y + dir.y*t,
               origin.z + dir.z*t);
    return true;
}

// settle: identical to test_relocate_boundary.d — wait ~120ms for the
// main loop to process the injected events before reading geometry/pivot.
private void settle() { Thread.sleep(120.msecs); }

// Read the authoritative gizmo pivot from /api/toolpipe/eval.
private Vec3 evalPivotLocal() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

unittest { // Auto off-gizmo click relocates onto the camera-facing PRINCIPAL-AXIS plane, not the fixed ground plane
    // --- Preamble ---
    // resetCubeAuto() resets to a cube with Auto ACEN, no userPlaced pin.
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/script", "tool.set move");
    settle();

    // --- Set a discriminating side-view camera ---
    // azimuth=1.4, elevation=0.15, focus=(0,0,0): camera forward is
    // dominantly −X. The view matrix has |view[2]| (avx component) as the
    // largest of avx/avy/avz, so pickMostFacingPlane returns normal=(1,0,0)
    // (the X-plane through the focus/origin, cenX ≈ 0 post-fix). Set via
    // azimuth/elevation/distance — /api/camera has no "eye" field.
    postJson("/api/camera",
        `{"azimuth":1.4,"elevation":0.15,"distance":3.0,"focus":{"x":0,"y":0,"z":0}}`);
    settle();

    // Fetch the actual camera so our in-test projections use the same
    // view/proj matrices as the running binary.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // --- Choose an off-gizmo click pixel ---
    // Compute the +X arrow handle grab point (0.7 along the arrow) and
    // the +X screen direction (unit), then offset perpendicularly by 220px
    // to land well clear of every handle. Mirrors arrowGrabPx +
    // arrowDirPx from test_relocate_boundary.d (same logic, inlined here
    // since those are local to that file, not in drag_helpers).
    auto pivot = evalPivotLocal();
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    // Grab point: 0.7 along the arrow (matches arrowGrabPx).
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    // Unit direction along +X arrow in screen space.
    float dxr = sx2 - sx1, dyr = sy2 - sy1;
    float rlen = sqrt(dxr*dxr + dyr*dyr);
    float ux = dxr/rlen, uy = dyr/rlen;
    // Perpendicular offset of 220px, same as test_relocate_boundary.d.
    int xoff = cast(int)(xa + 220.0f * uy);
    int yoff = cast(int)(ya - 220.0f * ux);

    // --- Compute the two expected hit points analytically (discriminator) ---
    Vec3 dir = testScreenRay(cast(float)xoff, cast(float)yoff, vp);
    // The bug's expectation: fixed ground plane Y=0, normal=(0,1,0).
    Vec3 groundHit, facingHit;
    bool gOk = testRayPlaneIntersect(vp.eye, dir,
                                      Vec3(0,0,0), Vec3(0,1,0), groundHit);
    // The confirmed-reference expectation: the most-facing plane for this
    // camera (avx is dominant). Replicated inline from create_common.d
    // (abs-compare on view[2/6/10]).
    float avx = abs(vp.view[2]);
    float avy = abs(vp.view[6]);
    float avz = abs(vp.view[10]);
    Vec3 facingNormal;
    if (avx >= avy && avx >= avz)       facingNormal = Vec3(1,0,0);
    else if (avy >= avx && avy >= avz)  facingNormal = Vec3(0,1,0);
    else                                 facingNormal = Vec3(0,0,1);
    bool fOk = testRayPlaneIntersect(vp.eye, dir,
                                      Vec3(0,0,0), facingNormal, facingHit);
    assert(gOk, "ground plane ray-intersect failed (ray parallel to Y=0?)");
    assert(fOk, "facing-plane ray-intersect failed");
    // Sanity: the two hits differ clearly — if not, the camera is wrong.
    float ydiff = abs(groundHit.y - facingHit.y);
    assert(ydiff > 0.5f,
        format("Camera is not discriminating: groundHit.y=%.4f facingHit.y=%.4f diff=%.4f",
               groundHit.y, facingHit.y, ydiff));

    // --- Inject the off-gizmo click ---
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    // --- Read the relocated pivot ---
    Vec3 cen = evalPivotLocal();

    // (a) Assert full landed point ≈ facingHit (the camera-facing X-plane).
    //     X tolerance: 1e-2 — the plane check is tight; cenX near zero
    //     proves the projection is onto the X-plane through the focus,
    //     not the fixed ground plane.
    //     Y/Z tolerance: 1.0 world unit — the in-plane landing point depends
    //     on the perspective ray, which is PROVISIONAL (0058 follow-up; the
    //     app's cachedVp and our reconstructed vp may differ by sub-frame
    //     rounding). The discriminator against the bug is the Y check in
    //     part (b).
    assert(abs(cen.x - facingHit.x) < 1e-2f,
        format("cenX expected ≈%.4f (facingHit) but got %.4f (diff %.4f)",
               facingHit.x, cen.x, abs(cen.x - facingHit.x)));
    assert(abs(cen.y - facingHit.y) < 1.0f,
        format("cenY expected ≈%.4f (facingHit) but got %.4f (PROVISIONAL in-plane)",
               facingHit.y, cen.y));
    assert(abs(cen.z - facingHit.z) < 1.0f,
        format("cenZ expected ≈%.4f (facingHit) but got %.4f (PROVISIONAL in-plane)",
               facingHit.z, cen.z));

    // (b) Assert the landed point is NOT on the fixed ground plane (the bug).
    //     The camera ensures groundHit.y ≈ 0 while facingHit.y is ≫ 0.5 away
    //     from it (verified above), so a Y-near-groundHit.y result would mean
    //     the fixed-ground-plane bug is still present.
    assert(abs(cen.y - groundHit.y) > 0.4f,
        format("cenY ≈ groundHit.y (%.4f) — still projecting onto the fixed ground plane, not the camera-facing axis",
               groundHit.y));

    // Clean up.
    postJson("/api/script", "tool.set move off");
}

unittest { // Auto relocate plane passes through the camera FOCUS, not the ORIGIN (task 0064/0066)
    // ---------------------------------------------------------------------
    // FOCUS-vs-ORIGIN plane discriminator (task 0063 guard FLIPPED by 0066).
    //
    // Task 0063 verdict was ORIGIN-supported based on panned captures with a
    // small focus offset (focus.z ≈ 0.015–0.053u), where the focus vs origin
    // difference fell below the in-plane residual noise. Task 0064 repeated the
    // capture with a LARGE pan (focus.y ≈ 0.6u) and three agreeing probes
    // (the reference editor's work-plane center tracked the camera focus to
    // Δ0.001u after a big pan; the default un-panned camera returned origin). The fresh evidence
    // overturns the 0063 verdict. See doc/focus_plane_fresh_capture_findings.md.
    //
    // Task 0066 implements the fix: the auto work plane now passes through
    // vp.focus (carried as Viewport.focus from View.viewport()). This test
    // pins the NEW behaviour:
    //   POST-FIX (focus plane):   cen.y ≈ focusHit.y ≈ focus.y   (0.6)
    //   PRE-FIX  (origin plane):  cen.y ≈ 0                       (fails)
    // The Y axis is the out-of-plane discriminator (tight tol);
    // X/Z are in-plane PROVISIONAL (0058) and use loose tolerance.
    //
    // Camera REWORKED for the Phase-1 axis fix (evidence-justified — see the
    // ground-plane test above): the plane normal is now camera-facing
    // (argmax|fwd|), so the out-of-plane axis must be the one this test
    // actually wants to discriminate on (Y). The old camera's dominant axis
    // would put Y IN-plane post-fix and break this check; use an explicit
    // high-elevation (Y-dominant) camera instead, same family as the
    // two-axis focus-tracking test below. Set via azimuth/elevation/
    // distance — /api/camera has no "eye" field (an "eye" key in the POST
    // body is silently ignored; only azimuth/elevation/distance/focus
    // matter), so the camera must be specified in those terms to control
    // which axis is actually dominant.
    // ---------------------------------------------------------------------
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/script", "tool.set move");
    settle();

    // Panned camera: focus is lifted to y=0.6 (a large, discriminating pan).
    // High elevation (1.3 rad) keeps the forward vector dominantly -Y
    // (argmax|fwd| = Y), keeping Y as the out-of-plane axis post-fix.
    postJson("/api/camera",
        `{"azimuth":0.3,"elevation":1.3,"distance":3.0,"focus":{"x":0.0,"y":0.6,"z":0.0}}`);
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    assert(abs(cam.focus.y - 0.6f) < 1e-3f,
        format("camera focus not applied: focus.y=%.4f (expected 0.6)", cam.focus.y));
    // Sanity: confirm the camera really is Y-dominant (argmax|fwd|=Y), i.e.
    // pickMostFacingPlane picks the normal this test assumes below.
    float avx2 = abs(vp.view[2]);
    float avy2 = abs(vp.view[6]);
    float avz2 = abs(vp.view[10]);
    assert(avy2 > avx2 && avy2 > avz2,
        format("camera not Y-dominant as required: avx=%.4f avy=%.4f avz=%.4f",
               avx2, avy2, avz2));

    // Off-gizmo click pixel (same construction as the ground-plane test).
    auto pivot = evalPivotLocal();
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    float dxr = sx2 - sx1, dyr = sy2 - sy1;
    float rlen = sqrt(dxr*dxr + dyr*dyr);
    float ux = dxr/rlen, uy = dyr/rlen;
    int xoff = cast(int)(xa + 220.0f * uy);
    int yoff = cast(int)(ya - 220.0f * ux);

    // Two expected hits on the SAME normal (0,1,0), differing only by the
    // plane through-point: FOCUS (Y=focus.y) vs ORIGIN (Y=0).
    Vec3 dir = testScreenRay(cast(float)xoff, cast(float)yoff, vp);
    Vec3 originHit, focusHit;
    bool oOk = testRayPlaneIntersect(vp.eye, dir, Vec3(0,0,0), Vec3(0,1,0), originHit);
    bool fOk = testRayPlaneIntersect(vp.eye, dir,
                                     Vec3(0, cam.focus.y, 0), Vec3(0,1,0), focusHit);
    assert(oOk && fOk, "origin/focus plane ray-intersect failed (ray parallel to Y=0?)");
    // Sanity: the two planes are clearly separated by the focus lift.
    assert(abs(originHit.y - focusHit.y) > 0.5f,
        format("Camera not discriminating origin vs focus: originHit.y=%.4f focusHit.y=%.4f",
               originHit.y, focusHit.y));

    // Inject the off-gizmo click and read the relocated pivot.
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    Vec3 cen = evalPivotLocal();

    // NEW behaviour (task 0066): lands on the FOCUS plane Y=focus.y, NOT the
    // origin plane Y=0. The out-of-plane Y coordinate is the decisive check
    // (tight tolerance); X/Z are in-plane PROVISIONAL (0058), loose tolerance.
    assert(abs(cen.y - focusHit.y) < 1e-2f,
        format("cenY expected ≈%.4f (focusHit, through-focus plane) but got %.4f "
               ~ "(diff %.4f — still on origin plane?)",
               focusHit.y, cen.y, abs(cen.y - focusHit.y)));
    // Guard: must NOT be on the old origin plane.
    assert(abs(cen.y - originHit.y) > 0.4f,
        format("cenY ≈ originHit.y (%.4f) — plane is still through the world origin, "
               ~ "not the camera focus (0066 fix not applied?)", originHit.y));

    postJson("/api/script", "tool.set move off");
}

unittest { // Auto relocate tracks camera focus on two axes (task 0066 focus-tracking)
    // ---------------------------------------------------------------------
    // Focus-tracking discriminator on TWO out-of-plane axes.
    //
    // Pan the camera so focus = (0.5, 0.6, 0): both X and Y are off-origin.
    // Camera forward is kept dominantly -Z (elevation near 0, azimuth near 0)
    // so the auto-picked plane normal is Z and focus.x / focus.y both lie
    // ON the plane. A relocate ray aimed along -Z would be parallel to the
    // plane; instead use a large elevation so the ray crosses the Z-plane
    // from a non-degenerate angle, and assert the hit tracks (focus.x, focus.y)
    // out-of-plane along Z.
    //
    // The cleanest discriminator: use high elevation (Y-dominant forward) so
    // autoNormal=Y, and set focus=(0.5,0.6,0). The Y hit should be ≈ focus.y
    // = 0.6. X/Z are loose (in-plane PROVISIONAL, 0058). FAILS pre-fix (Y≈0).
    // ---------------------------------------------------------------------
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/script", "tool.set move");
    settle();

    // Camera panned on TWO axes: focus=(0.5,0.6,0). High elevation (1.3 rad ≈
    // 75°) keeps view forward Y-dominant (avy dominant), making autoNormal=Y
    // and focus.y the out-of-plane discriminator. The /api/camera handler
    // takes azimuth/elevation/distance/focus — eye key is ignored by the server.
    postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.3,"distance":3.0,"focus":{"x":0.5,"y":0.6,"z":0.0}}`);
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    assert(abs(cam.focus.x - 0.5f) < 1e-3f, "focus.x not applied");
    assert(abs(cam.focus.y - 0.6f) < 1e-3f, "focus.y not applied");

    // Determine which axis is most-facing (highest abs of view[2/6/10]).
    float avx = abs(vp.view[2]);
    float avy = abs(vp.view[6]);
    float avz = abs(vp.view[10]);
    Vec3 autoNormal;
    Vec3 focusOnPlane; // the focus component along the normal axis
    if (avy >= avx && avy >= avz) {
        autoNormal   = Vec3(0, 1, 0);
        focusOnPlane = Vec3(cam.focus.x, cam.focus.y, cam.focus.z);
    } else if (avx >= avy && avx >= avz) {
        autoNormal   = Vec3(1, 0, 0);
        focusOnPlane = Vec3(cam.focus.x, cam.focus.y, cam.focus.z);
    } else {
        autoNormal   = Vec3(0, 0, 1);
        focusOnPlane = Vec3(cam.focus.x, cam.focus.y, cam.focus.z);
    }

    // The focus hit: ray from eye through the chosen off-gizmo pixel,
    // intersected with the focus plane (point=cam.focus, normal=autoNormal).
    auto pivot = evalPivotLocal();
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    float dxr = sx2 - sx1, dyr = sy2 - sy1;
    float rlen = sqrt(dxr*dxr + dyr*dyr);
    float ux = dxr/rlen, uy = dyr/rlen;
    int xoff = cast(int)(xa + 220.0f * uy);
    int yoff = cast(int)(ya - 220.0f * ux);

    Vec3 dir = testScreenRay(cast(float)xoff, cast(float)yoff, vp);
    Vec3 originHit, focusHit;
    bool oOk = testRayPlaneIntersect(vp.eye, dir,
                                     Vec3(0,0,0), autoNormal, originHit);
    bool fOk = testRayPlaneIntersect(vp.eye, dir,
                                     cam.focus, autoNormal, focusHit);
    assert(oOk && fOk, "ray-plane intersect failed for focus-tracking test");

    // The focus lift must be large enough to discriminate.
    float normalComp; // focus's component along autoNormal
    if (autoNormal.y > 0.5f)      normalComp = cam.focus.y;
    else if (autoNormal.x > 0.5f) normalComp = cam.focus.x;
    else                           normalComp = cam.focus.z;
    assert(abs(normalComp) > 0.4f,
        format("Camera not discriminating: focus component along normal = %.4f",
               normalComp));

    // Inject off-gizmo click.
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    Vec3 cen = evalPivotLocal();

    // Assert cen lies on the FOCUS plane (tight out-of-plane tol).
    // The out-of-plane coordinate of the focus hit is focusHit dotted with autoNormal.
    float cenOnNormal;
    float focusHitOnNormal;
    float originHitOnNormal;
    if (autoNormal.y > 0.5f) {
        cenOnNormal        = cen.y;
        focusHitOnNormal   = focusHit.y;
        originHitOnNormal  = originHit.y;
    } else if (autoNormal.x > 0.5f) {
        cenOnNormal        = cen.x;
        focusHitOnNormal   = focusHit.x;
        originHitOnNormal  = originHit.x;
    } else {
        cenOnNormal        = cen.z;
        focusHitOnNormal   = focusHit.z;
        originHitOnNormal  = originHit.z;
    }

    assert(abs(cenOnNormal - focusHitOnNormal) < 1e-2f,
        format("Focus-tracking: cenOnNormal=%.4f expected ≈%.4f (focus plane); "
               ~ "diff=%.4f (still on origin plane?)",
               cenOnNormal, focusHitOnNormal,
               abs(cenOnNormal - focusHitOnNormal)));
    assert(abs(cenOnNormal - originHitOnNormal) > 0.4f,
        format("Focus-tracking: cenOnNormal=%.4f ≈ originHitOnNormal=%.4f — "
               ~ "relocate is still through the origin, not the focus",
               cenOnNormal, originHitOnNormal));

    postJson("/api/script", "tool.set move off");
}

// -------------------------------------------------------------------------
// NEW discriminating regression case (Phase 1, evidence-justified): a
// camera whose FOCUS is far from the world origin on every axis, at both
// an X-dominant and a Z-dominant forward direction.
//
// This is the case that would have caught the whole "origin vs fixed
// ground vs camera-facing" confusion in one shot: the fixed-ground-plane
// bug always projects through the plane Y=focus.y (the 0066 focus-origin
// fix is untouched by the Phase-1 normal fix), so its landing on whichever
// axis the camera actually FACES is an unconstrained, ray-dependent
// coordinate — generically far from both 0 (origin) and focus[axis]. The
// confirmed camera-facing rule instead pins landing[axis] == focus[axis]
// EXACTLY (any point on a plane through `focus` with normal e_axis has
// that coordinate equal to focus[axis], independent of the ray), for
// whichever axis (X or Z here) the camera happens to face.
//
// No grid-snap is applied — vibe3d projects to the raw focus (the
// reference editor grid-snaps the focus on the normal axis; that gap is
// a documented, deferred minor residual — see doc/acen_auto_port_plan.md
// and doc/acen_auto_formula_findings.md). So the expected value here is
// the raw focus component (1.6 / 2.15), not a rounded one (2.0).
// -------------------------------------------------------------------------

unittest { // Focus-far-from-origin discriminator: X-dominant camera
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/script", "tool.set move");
    settle();

    // Focus well away from the origin on all three axes; azimuth/elevation
    // chosen so forward is dominantly -X (/api/camera has no "eye" field —
    // only azimuth/elevation/distance/focus set the actual camera).
    postJson("/api/camera",
        `{"azimuth":1.4,"elevation":0.15,"distance":3.0,"focus":{"x":1.6,"y":1.0,"z":2.15}}`);
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    assert(abs(cam.focus.x - 1.6f)  < 1e-3f, "focus.x not applied");
    assert(abs(cam.focus.y - 1.0f)  < 1e-3f, "focus.y not applied");
    assert(abs(cam.focus.z - 2.15f) < 1e-3f, "focus.z not applied");
    float avx = abs(vp.view[2]);
    float avy = abs(vp.view[6]);
    float avz = abs(vp.view[10]);
    assert(avx > avy && avx > avz,
        format("camera not X-dominant as required: avx=%.4f avy=%.4f avz=%.4f",
               avx, avy, avz));

    // Off-gizmo click pixel (same construction as the other tests in this file).
    auto pivot = evalPivotLocal();
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    float dxr = sx2 - sx1, dyr = sy2 - sy1;
    float rlen = sqrt(dxr*dxr + dyr*dyr);
    float ux = dxr/rlen, uy = dyr/rlen;
    int xoff = cast(int)(xa + 220.0f * uy);
    int yoff = cast(int)(ya - 220.0f * ux);

    Vec3 dir = testScreenRay(cast(float)xoff, cast(float)yoff, vp);
    // Reference/expected: X-plane through the raw FOCUS (confirmed rule).
    Vec3 newHit, oldHit;
    bool nOk = testRayPlaneIntersect(vp.eye, dir, cam.focus, Vec3(1,0,0), newHit);
    // The bug's expectation: fixed ground plane (normal always Y) — still
    // through the focus (the 0066 origin fix is untouched by Phase 1).
    bool oOk = testRayPlaneIntersect(vp.eye, dir, cam.focus, Vec3(0,1,0), oldHit);
    assert(nOk && oOk, "ray-plane intersect failed (ray parallel to a plane?)");
    // Sanity: this camera+pixel choice must actually discriminate — the
    // bug's X landing must differ clearly from the focus, or this test
    // would pass by accident regardless of which rule the code implements.
    assert(abs(newHit.x - oldHit.x) > 0.4f,
        format("Camera/pixel not discriminating: newHit.x=%.4f (focus.x=%.4f) oldHit.x=%.4f",
               newHit.x, cam.focus.x, oldHit.x));

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    Vec3 cen = evalPivotLocal();

    // (a) The dominant (X) axis lands EXACTLY on the raw focus — tight tol,
    //     distinguishes focus (1.6) from both the origin (0) and the old
    //     fixed-ground-plane landing (oldHit.x, generically far from 1.6).
    assert(abs(cen.x - cam.focus.x) < 1e-2f,
        format("cenX expected ≈%.4f (raw focus.x, camera-facing plane) but got %.4f",
               cam.focus.x, cen.x));
    // (b) Guard: must NOT be on the old fixed-ground-plane landing.
    assert(abs(cen.x - oldHit.x) > 0.4f,
        format("cenX ≈ oldHit.x (%.4f) — still projecting onto the fixed ground plane",
               oldHit.x));
    // Y/Z are in-plane, PROVISIONAL (0058) — loose tolerance.
    assert(abs(cen.y - newHit.y) < 1.0f,
        format("cenY expected ≈%.4f (PROVISIONAL in-plane) but got %.4f", newHit.y, cen.y));
    assert(abs(cen.z - newHit.z) < 1.0f,
        format("cenZ expected ≈%.4f (PROVISIONAL in-plane) but got %.4f", newHit.z, cen.z));

    postJson("/api/script", "tool.set move off");
}

unittest { // Focus-far-from-origin discriminator: Z-dominant camera
    resetCubeAuto();
    postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    postJson("/api/script", "tool.set move");
    settle();

    // Same far-from-origin focus; azimuth/elevation chosen so forward is
    // dominantly -Z.
    postJson("/api/camera",
        `{"azimuth":0.1,"elevation":0.15,"distance":3.0,"focus":{"x":1.6,"y":1.0,"z":2.15}}`);
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    assert(abs(cam.focus.x - 1.6f)  < 1e-3f, "focus.x not applied");
    assert(abs(cam.focus.y - 1.0f)  < 1e-3f, "focus.y not applied");
    assert(abs(cam.focus.z - 2.15f) < 1e-3f, "focus.z not applied");
    float avx = abs(vp.view[2]);
    float avy = abs(vp.view[6]);
    float avz = abs(vp.view[10]);
    assert(avz > avx && avz > avy,
        format("camera not Z-dominant as required: avx=%.4f avy=%.4f avz=%.4f",
               avx, avy, avz));

    auto pivot = evalPivotLocal();
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    int xa = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int ya = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    float dxr = sx2 - sx1, dyr = sy2 - sy1;
    float rlen = sqrt(dxr*dxr + dyr*dyr);
    float ux = dxr/rlen, uy = dyr/rlen;
    int xoff = cast(int)(xa + 220.0f * uy);
    int yoff = cast(int)(ya - 220.0f * ux);

    Vec3 dir = testScreenRay(cast(float)xoff, cast(float)yoff, vp);
    // Reference/expected: Z-plane through the raw FOCUS (confirmed rule).
    Vec3 newHit, oldHit;
    bool nOk = testRayPlaneIntersect(vp.eye, dir, cam.focus, Vec3(0,0,1), newHit);
    // The bug's expectation: fixed ground plane (normal always Y).
    bool oOk = testRayPlaneIntersect(vp.eye, dir, cam.focus, Vec3(0,1,0), oldHit);
    assert(nOk && oOk, "ray-plane intersect failed (ray parallel to a plane?)");
    assert(abs(newHit.z - oldHit.z) > 0.4f,
        format("Camera/pixel not discriminating: newHit.z=%.4f (focus.z=%.4f) oldHit.z=%.4f",
               newHit.z, cam.focus.z, oldHit.z));

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    Vec3 cen = evalPivotLocal();

    // (a) The dominant (Z) axis lands EXACTLY on the raw focus.
    assert(abs(cen.z - cam.focus.z) < 1e-2f,
        format("cenZ expected ≈%.4f (raw focus.z, camera-facing plane) but got %.4f",
               cam.focus.z, cen.z));
    // (b) Guard: must NOT be on the old fixed-ground-plane landing.
    assert(abs(cen.z - oldHit.z) > 0.4f,
        format("cenZ ≈ oldHit.z (%.4f) — still projecting onto the fixed ground plane",
               oldHit.z));
    // X/Y are in-plane, PROVISIONAL (0058) — loose tolerance.
    assert(abs(cen.x - newHit.x) < 1.0f,
        format("cenX expected ≈%.4f (PROVISIONAL in-plane) but got %.4f", newHit.x, cen.x));
    assert(abs(cen.y - newHit.y) < 1.0f,
        format("cenY expected ≈%.4f (PROVISIONAL in-plane) but got %.4f", newHit.y, cen.y));

    postJson("/api/script", "tool.set move off");
}
