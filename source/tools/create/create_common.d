module tools.create.create_common;

import math : Vec3, Viewport, dot, isOrtho, matMul4, matrixMirrorsWinding, normalize,
              projectToWindowFull, rayPlaneIntersect, screenPointToRay;
import std.math : abs;
import viewgrid : vectorSnap, viewVectorQuantum, viewWorkPlaneAnchor;

import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.packets        : SubjectPacket, WorkplanePacket, SnapPacket;
import toolpipe.stage          : TaskCode;
import toolpipe.stages.workplane : WorkplaneStage;
import operator                : VectorStack;
import drag                    : HandleDrag, DragFrame, DragKind, planeDragDelta;
import handler                 : MoveHandler;

import mesh : Mesh;
import editmode : EditMode;
import seltype : SelType;
import toolpipe.subject : evaluateSubject, viewOnlySubject, SubjectSource;
import snap : SnapResult, snapCursor, snapPacketOf;
import toolpipe.stages.snap : liveSnapGuides;
import snap_render : publishLastSnap, clearLastSnap;
// Task 0617 Stage 4: Create-tools always build into the active/primary
// layer's mesh (the `mesh` argument below), so its ModelSpace is the same
// resolver every other cross-module picking/snap call site uses.
import document : primaryModelSpace;

// ---------------------------------------------------------------------------
// Helpers shared by interactive Create-tools (BoxTool and the upcoming
// SphereTool / CylinderTool / ConeTool / CapsuleTool / TorusTool / PenTool).
// Extracted from BoxTool's private helpers so multiple Create-tools can share.
//
// Single-source note: `WorkplaneStage.evaluate` (source/toolpipe/stages/
// workplane.d) is the ONE production source of the active construction
// plane — the camera-facing auto pick only ever runs there, driven by a
// live `SubjectPacket.viewport`. Every direct `pickMostFacingPlane` call
// left in this file (`pickWorkplane`, `pickWorkplaneFrame`,
// `pickWorkplaneGizmoBasis`) is a no-pipe / no-stage fallback — it only
// fires when `g_pipeCtx` is unset (unit tests with no app loop) or the
// stage can't be found, and exists purely so those callers still return a
// sane plane in that degenerate case. Tools should always prefer the
// pipe-routed accessors over calling `pickMostFacingPlane` themselves.
// ---------------------------------------------------------------------------

/// The construction plane selected at tool activation: the world axis plane
/// most directly facing the camera (largest absolute component of the view
/// matrix's forward row). Carries the plane normal and its two orthogonal
/// in-plane axes in world space.
///
/// Usage:
///   auto bp = pickMostFacingPlane(vp);
///   // bp.normal is the plane normal (one of ±X, ±Y, ±Z world axes)
///   // bp.axis1 / bp.axis2 are the in-plane spanning vectors
struct BuildPlane {
    Vec3 normal;   /// unit — perpendicular to the plane
    Vec3 axis1;    /// unit — first in-plane axis
    Vec3 axis2;    /// unit — second in-plane axis (axis1 × normal direction)
}

/// Shared "most-facing basis axis" argmax, used by every construction-plane
/// picker in the Create-tools (see the call-site list in each file's
/// `choosePlane` — box/sphere/cone/cylinder/capsule/torus/tube/pen/
/// vertex_place, plus `pickMostFacingPlane` and `planeDragDelta`). Returns
/// only the winning INDEX (0=a, 1=b, 2=c) — callers keep their own
/// index→axis mapping (signed or unsigned, local or world), so every call
/// site's output is unchanged by routing through here.
///
/// Tie-break matches every existing call site's `>=` chain exactly: `a`
/// wins ties over `b`/`c`; `b` wins ties over `c`.
int mostFacingAxis(Vec3 camBack, Vec3 a, Vec3 b, Vec3 c) {
    float da = abs(dot(camBack, a));
    float db = abs(dot(camBack, b));
    float dc = abs(dot(camBack, c));
    if      (da >= db && da >= dc) return 0;
    else if (db >= da && db >= dc) return 1;
    else                            return 2;
}

/// The index of `f`'s axis most facing `vp`'s camera (0 = axis1 / local X,
/// 1 = normal / local Y, 2 = axis2 / local Z): the local principal plane a
/// placement on `f` takes (task 9408).
int viewPrincipalAxis(in WorkplaneFrame f, const ref Viewport vp) {
    return mostFacingAxis(Vec3(vp.view[2], vp.view[6], vp.view[10]),
                          f.axis1, f.normal, f.axis2);
}

/// The unit local axis `k` (0 = X, 1 = Y, 2 = Z).
Vec3 axisUnit(int k) {
    return Vec3(k == 0 ? 1 : 0, k == 1 ? 1 : 0, k == 2 ? 1 : 0);
}

/// Select the build plane based on which world axis the camera is most
/// directly facing. Examines the view matrix's third row (forward vector)
/// and picks the world-aligned plane whose normal is closest to the camera's
/// line of sight.
///
/// Returns a BuildPlane whose axes are always in canonical world order:
///   X-dominant → normal=X,  axis1=Y, axis2=Z
///   Y-dominant → normal=Y,  axis1=X, axis2=Z
///   Z-dominant → normal=Z,  axis1=X, axis2=Y
///
/// PenTool uses this for the initial click then locks to that plane
/// regardless of subsequent camera changes.
BuildPlane pickMostFacingPlane(const ref Viewport vp) {
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    final switch (mostFacingAxis(camBack, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))) {
        case 0: return BuildPlane(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
        case 1: return BuildPlane(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1));
        case 2: return BuildPlane(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0));
    }
}

// ---------------------------------------------------------------------------
// pickWorkplane — phase-7.1 wrapper. Routes the construction-plane query
// through the global ToolPipeContext so the WorkplaneStage's `mode`
// (auto / worldX / worldY / worldZ) is honoured. Falls back to direct
// `pickMostFacingPlane` if the pipe hasn't been initialised yet (e.g.
// in a unittest with no app loop running).
//
// Tools call this instead of `pickMostFacingPlane` directly so the
// global Tool Pipe state takes precedence over per-tool defaults.
// ---------------------------------------------------------------------------
BuildPlane pickWorkplane(const ref Viewport vp) {
    if (g_pipeCtx is null) return pickMostFacingPlane(vp);
    // Task 1904 Stage 4 / plan §1.3a: this evaluate's mesh/editMode/selType
    // are the FROZEN view-only source (`viewOnlySubject`) — never live
    // editor state. See the function's own doc comment for why.
    SubjectPacket subj;
    VectorStack   vts;
    evaluateSubject(subj, vts, viewOnlySubject(vp));
    if (auto wp = vts.get!WorkplanePacket())
        return BuildPlane(wp.normal, wp.axis1, wp.axis2);
    return pickMostFacingPlane(vp);
}

// ---------------------------------------------------------------------------
// WorkplaneFrame — full local↔world transform for the current Tool Pipe
// workplane state, plus the basis vectors / origin extracted from the
// matrix columns for callers that prefer them as separate fields.
//
// `toWorld` columns: [axis1, normal, axis2, origin]. So local-Y is the
// workplane normal — a primitive built in local XZ (Y=0) lies ON the
// workplane plane after `toWorld * v`.
//
// Step-1 of the workplane refactor (see chat) only adds this struct +
// the picker. Tools keep calling `pickWorkplane(vp) → BuildPlane` for
// now; per-tool migration to `pickWorkplaneFrame` is step-2 onwards.
// ---------------------------------------------------------------------------
struct WorkplaneFrame {
    float[16] toWorld;
    float[16] toLocal;
    Vec3      normal;
    Vec3      axis1;
    Vec3      axis2;
    Vec3      origin;
    bool      isAuto;
}

/// Same routing logic as `pickWorkplane` but returns the full transform.
/// In auto-mode the basis comes from the camera-facing pick (via
/// pipeline.evaluate) and origin = (0,0,0); in non-auto mode the
/// WorkplaneStage's stored center is used. When `g_pipeCtx` is unset
/// (tests without an app loop) the auto-mode pick is used and the
/// returned frame is identity-translated.
WorkplaneFrame pickWorkplaneFrame(const ref Viewport vp) {
    WorkplaneFrame f;
    if (g_pipeCtx is null) {
        auto bp = pickMostFacingPlane(vp);
        f.normal = bp.normal;
        f.axis1  = bp.axis1;
        f.axis2  = bp.axis2;
        // Auto plane passes through the camera focus, not the world origin,
        // so primitives land on the plane the user is looking at.
        f.origin = vp.focus;
        f.isAuto = true;
    } else {
        // Task 1904 Stage 4 / plan §1.3a: FROZEN view-only source, same as
        // `pickWorkplane` above — never live editor state.
        SubjectPacket subj;
        VectorStack   vts;
        evaluateSubject(subj, vts, viewOnlySubject(vp));
        if (auto wp = vts.get!WorkplanePacket()) {
            f.normal = wp.normal;
            f.axis1  = wp.axis1;
            f.axis2  = wp.axis2;
            // Non-auto: use the stored workplane center exactly.
            // Auto: the WorkplaneStage publishes center=(0,0,0); override with
            // the camera focus so the plane passes through what the user is
            // looking at rather than the world origin.
            f.origin = wp.isAuto ? vp.focus : wp.center;
            f.isAuto = wp.isAuto;
        }
    }
    fillFrameMatrices(f);
    return f;
}

/// The world identity frame (world XZ, normal +Y, origin 0, isAuto) — the
/// auto / no-pipe answer of `primitivePlacementFrame`.
private WorkplaneFrame worldXZFrame() {
    return frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1),
                           Vec3(0, 0, 0), true);
}

/// The ONE parameter frame (task 9408): primitive channels, placement gestures,
/// the `applyHeadless` builds, arc, slice headless and the relocate all read
/// it. Auto, no pipe or no stage ⇒ the
/// world identity (§10, §23); pinned ⇒ the stage's stored basis + centre. It
/// reads the stage, never `pipeline.evaluate` (re-entrancy on event paths,
/// doc/acen_auto_port_plan.md Risk 3); the live camera-facing basis is
/// `pickWorkplaneFrame`'s.
WorkplaneFrame primitivePlacementFrame() {
    auto wp = g_pipeCtx is null ? null
            : cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work);
    if (wp is null || wp.isAuto) return worldXZFrame();
    const p = wp.currentState();
    return frameFromBasis(p.normal, p.axis1, p.axis2, p.center);
}

/// The view re-expressed in `frame`'s LOCAL space: every read a gesture makes
/// of the camera (cursor ray, eye, focus, view axes) comes out plane-local.
/// This is the ONE conversion point for the create family's gestures — the
/// placement click (§13/§23), the centre drag (§14) and the principal-plane
/// choice all read this view instead of converting a world answer after the
/// fact, which is how a WORLD point ended up in a plane-local field (task
/// 7139, doc/measured_laws.md §23). With the identity frame it is `vp` itself.
Viewport planeLocalViewport(const ref Viewport vp, in WorkplaneFrame frame) {
    Viewport l = vp;
    l.view  = matMul4(vp.view, frame.toWorld);
    l.eye   = transformPoint(frame.toLocal, vp.eye);
    l.focus = transformPoint(frame.toLocal, vp.focus);
    return l;
}

/// A create tool's mover drag (M-HANDLE): the centre at the press
/// plus the pointer travel, in `frame`'s LOCAL space (= the Position channels).
/// Arrows 0/1/2 travel along the drawn arrow (LAW A, own); the centre box
/// through LAW D on the plane-local view (§14 read by §23). False = skip.
bool moverDrag(const ref HandleDrag grab, int part, int mx, int my, MoveHandler mover,
               in WorkplaneFrame frame, const ref Viewport vp, out Vec3 centre)
{
    DragFrame f;
    f.kind = DragKind.principalPlane;
    if (part <= 2) {
        f.kind = DragKind.screenAxis;
        f.axis = moverArrowLocal(mover, part, frame);
    }
    bool skip;
    Viewport lvp = planeLocalViewport(vp, frame);
    centre = grab.client(mx, my, f, lvp, skip);
    return !skip;
}

private Vec3 moverArrowLocal(MoveHandler mover, int part, in WorkplaneFrame frame) {
    immutable Vec3 end = part == 0 ? mover.arrowX.end : part == 1 ? mover.arrowY.end : mover.arrowZ.end;
    return transformDir(frame.toLocal, end - mover.center);
}

/// The mover's snap (task 9472, K-H / K-H2 CENTRE+TRAVEL): `moverDrag`'s
/// centre snapped as a point, then only the part's free channels taken — along
/// the arrow, or off the centre box's locked axis. Never fed back.
SnapResult snapMoverCentre(ref Vec3 centre, int part, MoveHandler mover, in WorkplaneFrame frame,
                           int x, int y, const ref Viewport vp, const ref Mesh mesh)
{
    import drag : primitiveCenterPlaneAxis;
    Vec3 s = centre;
    auto sr = snapLocalHit(s, frame, x, y, vp, mesh, EditMode.Vertices);
    if (!sr.snapped) return sr;
    if (part <= 2) {
        immutable Vec3 u = normalize(moverArrowLocal(mover, part, frame));
        centre += u * dot(s - centre, u);
        return sr;
    }
    Viewport lvp = planeLocalViewport(vp, frame);
    immutable int lock = primitiveCenterPlaneAxis(centre, lvp);
    foreach (k; 0 .. 3)
        if (k != lock) centre += axisUnit(k) * dot(s - centre, axisUnit(k));
    return sr;
}

/// A height drag's plane normal: in the work plane (perpendicular to
/// `normal`), facing the camera from `origin`; `fallback` when the eye sits on
/// the normal's line. The Box and the radial primitives differ only in origin.
Vec3 heightDragNormal(Vec3 origin, Vec3 eyeLocal, Vec3 normal, Vec3 fallback) {
    Vec3 toCamera = eyeLocal - origin;
    Vec3 inPlane  = toCamera - normal * dot(toCamera, normal);
    immutable float len = inPlane.length;
    return len > 1e-6f ? inPlane / len : fallback;
}

/// Where a placement click meets the view work plane, in `frame`'s LOCAL
/// space, UNQUANTISED: the cursor ray of the plane-local view meets the plane
/// perpendicular to the most-facing local axis (`axisLocal`) through the view
/// anchor (`viewWorkPlaneAnchor`; task 9411). Total: a parallel plane falls
/// back to the view-perpendicular plane through the same anchor.
Vec3 placementPlaneHit(float sx, float sy, const ref Viewport vp,
                       in WorkplaneFrame frame, out int axisLocal)
{
    Viewport l = planeLocalViewport(vp, frame);
    axisLocal = viewPrincipalAxis(frame, vp);
    immutable Vec3 anchor = viewWorkPlaneAnchor(l, axisLocal);
    Vec3 o, d, hit;
    screenPointToRay(sx, sy, l, o, d);
    if (rayPlaneIntersect(o, d, anchor, axisUnit(axisLocal), hit)) return hit;
    if (rayPlaneIntersect(o, d, anchor, Vec3(l.view[2], l.view[6], l.view[10]), hit))
        return hit;
    return anchor;
}

/// Where a placement click lands, in `frame`'s LOCAL space (= the channels):
/// `placementPlaneHit` snapped to the view quantum on every channel — the one
/// click law of the create tools, the radial-array centre, the falloff point
/// and the relocate click (K-W / K-W2, tests/fixtures/create_click_plane.json).
Vec3 screenToPlacementLocal(float sx, float sy, const ref Viewport vp,
                            in WorkplaneFrame frame, out int axisLocal)
{
    return vectorSnap(placementPlaneHit(sx, sy, vp, frame, axisLocal),
                      viewVectorQuantum(vp));
}

/// The constraint's background surface on the view ray of plane point
/// `planeLocal`'s own screen position (task 9404, K-C2 QPLANE-RAY), offset
/// along the hit normal, NOT quantised; false (`local` untouched) = no hit,
/// or the constraint does not take the pointer.
bool backgroundSurfacePoint(Vec3 planeLocal, const ref Viewport vp, in WorkplaneFrame frame,
                            ref Vec3 local)
{
    import toolpipe.stages.constrain : liveConstrainStage;
    import bvh_pick : SurfaceHit;
    auto cs = liveConstrainStage();
    float px, py, ndcZ;
    Vec3 org, dir;
    SurfaceHit sh;
    if (cs is null || !projectToWindowFull(transformPoint(frame.toWorld, planeLocal), vp, px, py, ndcZ))
        return false;
    screenPointToRay(px, py, vp, org, dir);
    if (!cs.surfaceOnRay(org, dir, sh)) return false;
    local = transformPoint(frame.toLocal, cs.offsetPoint(sh.point, sh.normal));
    return true;
}

/// A plane point onto the background: `backgroundSurfacePoint`; no hit ⇒
/// `planeLocal` snapped to the view quantum.
Vec3 backgroundPoint(Vec3 planeLocal, const ref Viewport vp, in WorkplaneFrame frame,
                     out bool onSurface)
{
    Vec3 p = vectorSnap(planeLocal, viewVectorQuantum(vp));
    onSurface = backgroundSurfacePoint(planeLocal, vp, frame, p);
    return p;
}

/// A primitive's BASE-DRAG point (task 9473, K-C2 C2d + K-C3): the press
/// corner `grab.point` (q of the press plane hit) carried by the pixel travel
/// through drag.d's press-frozen plane map on the base plane (normal `n`), onto
/// the background (`backgroundPoint`: the hit unquantised, else q); the
/// base-plane channel stays the press's. The snap runs after it. False (`p`
/// untouched) = no map at the press corner (behind the camera): the caller
/// keeps its last corner.
bool baseDragPoint(const ref HandleDrag grab, int x, int y, Vec3 n,
                   const ref Viewport vp, in WorkplaneFrame frame, ref Vec3 p)
{
    bool skip, onSurface;
    Viewport lvp = planeLocalViewport(vp, frame);
    immutable Vec3 t = grab.point + planeDragDelta(x, y, grab.pressX, grab.pressY, 3, grab.point,
        lvp, skip, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), n);
    if (skip) return false;
    p = backgroundPoint(t, vp, frame, onSurface);
    p -= n * dot(p - grab.point, n);
    return true;
}

/// A mouse handler's FIRST statement: the event resolves under its own Quad
/// cell's projection (`SubjectPacket.viewport`; tasks 0209, 9473), not the
/// last-drawn cell's.
void syncEventViewport(ref Viewport cached, ref VectorStack vts) {
    if (auto sp = vts.get!SubjectPacket()) cached = sp.viewport;
}

/// The FREE point under the pointer: the click's q onto the background, then
/// the snap, replacing all three channels (K-C2 C2i). A primitive's press is
/// the plane point and never comes here (K-C role law).
Vec3 placeFreePoint(int x, int y, const ref Viewport vp, in WorkplaneFrame frame,
                    const ref Mesh mesh, out SnapResult snap)
{
    bool onSurface;
    Vec3 p = backgroundPoint(screenToPlacementLocal(x, y, vp, frame), vp, frame, onSurface);
    snap = snapLocalHit(p, frame, x, y, vp, mesh, EditMode.Vertices);
    return p;
}

/// World-space basis triple for Create-tool gizmos (mover arrows / plane
/// handles / etc.) — same basis the construction-plane pickers use, so the
/// gizmo always agrees with where primitives actually drop:
///   - auto  ⇒ pickMostFacingPlane(vp) (camera-snapped world axis triple)
///   - non-auto ⇒ WorkplaneStage's (axis1, normal, axis2)
/// Used by Sphere / Cylinder / Cone / Capsule / Torus mover.setOrientation
/// in draw(). Box has its own captured frame and doesn't need this.
void pickWorkplaneGizmoBasis(const ref Viewport vp,
                             out Vec3 ax, out Vec3 ay, out Vec3 az)
{
    if (g_pipeCtx !is null) {
        auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work);
        if (wp !is null && !wp.isAuto) {
            Vec3 n, a1, a2;
            wp.currentBasis(n, a1, a2);
            ax = a1; ay = n; az = a2;
            return;
        }
    }
    auto bp = pickMostFacingPlane(vp);
    ax = bp.axis1; ay = bp.normal; az = bp.axis2;
}

// ---------------------------------------------------------------------------
// The cursor ray, in a workplane frame's LOCAL space — ORTHO-AWARE.
//
// This exists as ONE shared helper because the four Create-tool families
// (box / pen / vertex_place / the PrimitiveCreateTool hierarchy) each carried
// their own `localEye()` + `localRay()` pair built from `vp.eye` and
// `screenRay`, and that pair is the PERSPECTIVE law: one common apex, with the
// direction fanning out from it. It is the only construction of a cursor ray
// left in the tree that does not go through `math.screenPointToRay`, which has
// carried the orthographic arm all along.
//
// Under an orthographic projection the rays are PARALLEL — each starts at its
// own point on the image plane and they all share the view forward. Feeding a
// plane the perspective pencil instead scales the answer: the ray leaves the
// eye and only reaches the construction plane after travelling the camera
// DISTANCE, so the in-plane offset it accumulates is the click's offset times
// that distance. Measured on a distance-3 camera (task 0661 Ph0): a click
// intended for 0.4 world units right of the focus created geometry 1.206 units
// right of it, in EVERY one of the six axis presets — Top and Bottom included.
//
// The two entry points below take the plane test with them so no call site can
// pair an apex with a parallel ray again: `workplaneCursorPlaneHit` is the one
// the tools call, and the ray form is exposed for the rare site that wants the
// ray itself.
// ---------------------------------------------------------------------------

/// The cursor ray at pixel (sx, sy), expressed in `frame`'s LOCAL space.
///
/// `frame` is rigid (orthonormal basis + translation), so the transformed
/// direction stays unit length and the ray parameter keeps meaning a world
/// distance.
void workplaneCursorRay(in WorkplaneFrame frame, const ref Viewport vp,
                        float sx, float sy,
                        out Vec3 orgLocal, out Vec3 dirLocal)
{
    // Through the one plane-local conversion (task 7139): the ray of the
    // plane-local view IS the local ray, in both projection arms.
    Viewport l = planeLocalViewport(vp, frame);
    screenPointToRay(sx, sy, l, orgLocal, dirLocal);
}

/// Intersect the cursor ray at pixel (sx, sy) with a plane stated in `frame`'s
/// LOCAL space. Returns false on the same parallel-ray condition
/// `rayPlaneIntersect` refuses on.
bool workplaneCursorPlaneHit(in WorkplaneFrame frame, const ref Viewport vp,
                             float sx, float sy,
                             Vec3 planeOrigin, Vec3 planeNormal,
                             out Vec3 hitLocal)
{
    Vec3 o, d;
    workplaneCursorRay(frame, vp, sx, sy, o, d);
    return rayPlaneIntersect(o, d, planeOrigin, planeNormal, hitLocal);
}

/// `screenToPlacementLocal` on the parameter frame, in WORLD space: the click
/// point of a reader with no frame of its own (falloff point, radial-array
/// centre, wrapped-command handle, relocate).
Vec3 screenToPlacementWorld(float sx, float sy, const ref Viewport vp) {
    auto f = primitivePlacementFrame();
    return transformPoint(f.toWorld, screenToPlacementLocal(sx, sy, vp, f));
}

/// `screenToPlacementLocal` for a caller that does not need the axis.
Vec3 screenToPlacementLocal(float sx, float sy, const ref Viewport vp,
                            in WorkplaneFrame frame)
{
    int axisLocal;
    return screenToPlacementLocal(sx, sy, vp, frame, axisLocal);
}

/// Build a frame from explicit basis + origin. Useful for tools that
/// want to lock the workplane at activation time and cache the frame
/// (matches today's BoxTool's `choosePlane` pattern).
WorkplaneFrame frameFromBasis(Vec3 normal, Vec3 axis1, Vec3 axis2, Vec3 origin,
                              bool isAuto = false) {
    WorkplaneFrame f;
    f.normal = normal;
    f.axis1  = axis1;
    f.axis2  = axis2;
    f.origin = origin;
    f.isAuto = isAuto;
    fillFrameMatrices(f);
    return f;
}

// Populate toWorld + toLocal from the frame's basis / origin fields.
// Assumes (axis1, normal, axis2) are mutually orthonormal — true for
// every code path that produces a frame today (alignToSelection
// orthogonalises; the world / preset modes are world-axis-aligned).
private void fillFrameMatrices(ref WorkplaneFrame f) {
    f.toWorld = [
        f.axis1.x, f.axis1.y, f.axis1.z, 0,
        f.normal.x, f.normal.y, f.normal.z, 0,
        f.axis2.x, f.axis2.y, f.axis2.z, 0,
        f.origin.x, f.origin.y, f.origin.z, 1,
    ];
    // Orthonormal inverse: transpose the rotation, translate by -Rᵀ·origin.
    float tx = -(f.axis1.x * f.origin.x + f.axis1.y * f.origin.y + f.axis1.z * f.origin.z);
    float ty = -(f.normal.x * f.origin.x + f.normal.y * f.origin.y + f.normal.z * f.origin.z);
    float tz = -(f.axis2.x * f.origin.x + f.axis2.y * f.origin.y + f.axis2.z * f.origin.z);
    f.toLocal = [
        f.axis1.x, f.normal.x, f.axis2.x, 0,
        f.axis1.y, f.normal.y, f.axis2.y, 0,
        f.axis1.z, f.normal.z, f.axis2.z, 0,
        tx,        ty,         tz,        1,
    ];
}

// ---------------------------------------------------------------------------
// frameIsLeftHanded / reverseFaceWinding — task 0424. Hoisted from BoxTool
// (box.d), the only Create-tool that self-corrected this, into shared
// helpers so every Create-tool built on `PrimitiveCreateTool` can apply the
// same fix.
//
// `pickMostFacingPlane`'s X-dominant and Z-dominant camera cases each
// return a basis triple whose (axis1, normal, axis2) ordering is
// LEFT-handed — e.g. X-dominant returns normal=+X, axis1=+Y, axis2=+Z, and
// axis1×normal (+Y×+X = -Z) is the negation of axis2 (+Z), unlike the
// Y-dominant / world-default case. `fillFrameMatrices` lays `toWorld`'s
// columns out as [axis1, normal, axis2, origin] regardless of handedness,
// so a left-handed input triple produces a `toWorld` with
// det(upper-left 3×3) = -1. Builders emit primitives in LOCAL space with a
// fixed CCW winding (assuming a right-handed local→world map); transforming
// those vertices through a det=-1 `toWorld` mirrors the winding, flipping
// every face normal to point inward. `frameIsLeftHanded` detects this;
// `reverseFaceWinding` corrects it by reversing the newly emitted faces'
// vertex order.
// ---------------------------------------------------------------------------

/// True when `frame.toWorld`'s rotation part (upper-left 3×3, column-major)
/// is a left-handed basis — i.e. transforming local-space geometry through
/// it mirrors winding. See the banner above for why the auto-mode
/// X/Z-dominant camera cases trigger this and the Y-dominant case never
/// does.
/// (Task 0684: the determinant test itself now lives in `math` as
/// `matrixMirrorsWinding` — the export boundary needs the SAME predicate on
/// `ItemXform.composedMatrix()`, and two hand-written 3x3 determinants would be
/// a latent divergence rather than a redundancy. This name stays as the
/// workplane-flavoured spelling of it.)
bool frameIsLeftHanded(in WorkplaneFrame frame) {
    return matrixMirrorsWinding(frame.toWorld);
}

/// Reverse the vertex order of every face in `m` from `firstFaceIdx`
/// onward (in place). Callers pass the pre-emission `m.faces.length` as
/// `firstFaceIdx` so only the newly appended faces are touched — existing
/// scene geometry (and any other tool's prior output) is left alone.
void reverseFaceWinding(Mesh* m, size_t firstFaceIdx) {
    foreach (fi; firstFaceIdx .. m.faces.length) {
        auto face = m.faces[fi];
        for (size_t k = 0; k < face.length / 2; k++) {
            auto t = face[k]; face[k] = face[$ - 1 - k]; face[$ - 1 - k] = t;
        }
    }
}

/// Apply `m` (column-major 4×4) to a point (w=1). Convenience for tools.
Vec3 transformPoint(in float[16] m, Vec3 v) @nogc nothrow {
    return Vec3(
        m[0]*v.x + m[4]*v.y + m[8] *v.z + m[12],
        m[1]*v.x + m[5]*v.y + m[9] *v.z + m[13],
        m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14],
    );
}

/// Apply `m` to a direction (w=0). No translation; rotates only.
Vec3 transformDir(in float[16] m, Vec3 v) @nogc nothrow {
    return Vec3(
        m[0]*v.x + m[4]*v.y + m[8] *v.z,
        m[1]*v.x + m[5]*v.y + m[9] *v.z,
        m[2]*v.x + m[6]*v.y + m[10]*v.z,
    );
}

/// Read the current SnapPacket from the live ToolPipeContext.
/// Returns a default-init packet (enabled=false) when g_pipeCtx is null.
/// Used by tools that need snap configuration (enabled bits, innerRangePx)
/// without triggering snapping logic — e.g. the Pen guide constraint
/// evaluator reads this to check which guide bits are active.
SnapPacket currentSnapPacket(const ref Mesh mesh, EditMode editMode,
                              const ref Viewport vp)
{
    if (g_pipeCtx is null) return SnapPacket.init;
    // selType frozen at Vertex (plan §1.3 — one of the seven sites that
    // never had a live SelType/SelTypeOrder to read).
    SubjectPacket subj;
    VectorStack   vts;
    evaluateSubject(subj, vts,
        SubjectSource(cast(Mesh*)&mesh, editMode, SelType.Vertex, vp));
    return snapPacketOf(vts);
}

/// Run SNAP against a workplane-local hit. Each Create-tool computes
/// the cursor's intersection with the construction plane in LOCAL
/// workplane coordinates via `rayPlaneIntersect(localEye, localRay,
/// ...)`. Snap targets live in WORLD coordinates, so this helper:
///
///   1. Converts the local hit to world.
///   2. Queries the SnapStage via the live ToolPipeContext.
///   3. If a snap target was found, overwrites `hitLocal` with the
///      target's world position transformed back to the tool's local
///      frame.
///   4. Returns the raw SnapResult so the tool can publish it for
///      overlay rendering.
///
/// Falls through (leaves `hitLocal` untouched, returns `SnapResult.init`)
/// when there's no toolpipe / SnapStage is disabled / no candidate
/// within outerRange. `excludeVerts` is empty by default — Create-tools
/// don't have a "moving set" the way MoveTool's drag does, and
/// snapping a primitive's first corner to a selected vertex is a
/// legitimate gesture.
SnapResult snapLocalHit(ref Vec3 hitLocal,
                        in WorkplaneFrame frame,
                        int sx, int sy,
                        const ref Viewport vp,
                        const ref Mesh mesh,
                        EditMode editMode,
                        const(uint)[] excludeVerts = [])
{
    SnapPacket localPkt = currentSnapPacket(mesh, editMode, vp);
    if (!localPkt.enabled) return SnapResult.init;

    Vec3 hitWorld = transformPoint(frame.toWorld, hitLocal);
    auto sr = snapCursor(hitWorld, sx, sy, vp, mesh, primaryModelSpace(), localPkt, excludeVerts,
                         null, liveSnapGuides());
    if (sr.snapped)
        hitLocal = transformPoint(frame.toLocal, sr.worldPos);
    return sr;
}




// ---------------------------------------------------------------------------
// workplaneCursorPlaneHit — the ortho arm, and the equality that makes it the
// ported law rather than a second opinion (task 0661).
//
// Rig: the Front axis preset. Camera at (0,0,dist) looking down -Z, ortho,
// construction plane = the camera-facing principal plane (normal +Z) through
// the focus. `frame` is identity-basis-with-normal-Z so local == world here,
// which keeps the assertions readable in world coordinates.
// ---------------------------------------------------------------------------
private Viewport frontOrthoViewport(float dist, Vec3 focus) {
    import math : orthographicMatrix;
    import std.math : tan, PI;
    Viewport vp;
    vp.width = 640; vp.height = 480;
    vp.x = 0; vp.y = 0;
    vp.focus = focus;
    vp.eye = Vec3(focus.x, focus.y, focus.z + dist);
    // Front basis: right=+X, up=+Y, back=+Z. View matrix rows are the basis
    // vectors (column-major m[row + col*4]).
    vp.view = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        -focus.x, -focus.y, -(focus.z + dist), 1,
    ];
    float halfH = dist * tan(cast(float)(PI / 8.0));
    vp.proj = orthographicMatrix(halfH, cast(float)vp.width / vp.height, 0.1f, 100.0f);
    return vp;
}

unittest { // ortho: the in-plane answer is the click, NOT the click times distance
    import std.math : abs, tan, PI;

    immutable float dist = 3.0f;
    immutable Vec3  focus = Vec3(0, 0, 0);
    auto vp = frontOrthoViewport(dist, focus);
    assert(isOrtho(vp), "rig premise: the Front preset is orthographic");

    // Pick a pixel that unprojects to a known world point on the plane.
    float halfH  = dist * tan(cast(float)(PI / 8.0));
    float aspect = cast(float)vp.width / vp.height;
    immutable Vec3 want = Vec3(0.4f, 0.3f, 0.0f);   // right 0.4, up 0.3 of focus
    float ndcX = want.x / (halfH * aspect);
    float ndcY = want.y / halfH;
    float px = (ndcX * 0.5f + 0.5f) * vp.width;
    float py = (1.0f - (ndcY * 0.5f + 0.5f)) * vp.height;

    auto f = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                            focus, true);
    // Plane normal in LOCAL space is +Y by construction (toWorld's middle
    // column is the frame normal), and the plane passes through local origin.
    Vec3 hitLocal;
    assert(workplaneCursorPlaneHit(f, vp, px, py, Vec3(0, 0, 0), Vec3(0, 1, 0),
                                   hitLocal),
           "an axis-facing plane can never be parallel to its own view ray");
    Vec3 got = transformPoint(f.toWorld, hitLocal);

    assert(abs(got.x - want.x) < 1e-4f && abs(got.y - want.y) < 1e-4f,
           "ortho click must land AT the pixel it was taken from; the "
           ~ "perspective pencil lands at distance times that offset");
    assert(abs(got.z - focus.z) < 1e-5f, "and on the plane");
}

unittest { // ortho: the plane's DEPTH is the focus snapped to q (K-W2 finding 2)
    import std.math : abs;
    // Focus depth OFF the q lattice; `placementPlaneHit` is UNQUANTISED, so
    // only the anchor's own snap can put the hit's depth on the lattice.
    auto vp = frontOrthoViewport(3.0f, Vec3(0.7f, 0.5f, 2.01234f));
    immutable float q = viewVectorQuantum(vp);
    immutable float want = vectorSnap(vp.focus, q).z;
    assert(q > 0 && abs(want - vp.focus.z) > 1e-4f,
           "rig premise: the focus depth must sit off the q lattice");
    int axisLocal;
    immutable Vec3 hit = placementPlaneHit(500.0f, 120.0f, vp,
                                           primitivePlacementFrame(), axisLocal);
    assert(axisLocal == 2, "a Front view's principal plane is the Z plane");
    assert(abs(hit.z - want) < 1e-6f,
           "the ortho anchor's depth must be the focus snapped to the view "
           ~ "quantum, not the raw focus");
}

unittest { // the placement click is TOTAL where the old floor plane refused
    import std.math : abs;
    import math : screenPointToRay;

    immutable float dist  = 3.0f;
    // The focus is deliberately OFF the world origin on all three axes. With
    // it at the origin this test cannot tell the view-following plane from
    // the world floor: the camera-perpendicular fallback below would rescue
    // the floor case and land on z = 0, which is also the right answer. The
    // displaced focus is what makes the DEPTH a discriminator.
    immutable Vec3  focus = Vec3(0.7f, 0.5f, 2.0f);
    auto vp = frontOrthoViewport(dist, focus);

    // The premise of the whole task, asserted rather than stated in prose:
    // the fixed world floor (Y = 0, normal (0,1,0)) that the deleted
    // `math.screenToWorkPlane` defaulted to is EXACTLY parallel to a Front
    // view's ray, so a projection onto it refuses. This is the shape of that
    // call, spelled out.
    Vec3 rayO, rayD, floorHit;
    screenPointToRay(500.0f, 120.0f, vp, rayO, rayD);
    assert(!rayPlaneIntersect(rayO, rayD, Vec3(0, 0, 0), Vec3(0, 1, 0), floorHit),
           "premise: the Y=0 floor is degenerate in a horizontal view");

    // No `g_pipeCtx` in a unittest, so `primitivePlacementFrame` is the auto
    // identity — the frame this defect lived in (task 7139 moved the
    // placement arm into `screenToPlacementLocal`).
    int axisLocal;
    Vec3 got = screenToPlacementLocal(
        500.0f, 120.0f, vp, primitivePlacementFrame(), axisLocal);
    assert(axisLocal == 2, "a Front view's principal plane is the Z plane");
    assert(abs(got.z - focus.z) < 1e-5f,
           "the plane follows the view AND is anchored at the camera focus: "
           ~ "a Front view lands on Z = focus.z, not Z = 0");
    // ...and in-plane it is the point under the cursor (under ortho the
    // unprojected click itself) snapped to the view quantum.
    immutable float q = viewVectorQuantum(vp);
    assert(q > 0 && abs(got.x - vectorSnap(rayO, q).x) < 1e-5f
                 && abs(got.y - vectorSnap(rayO, q).y) < 1e-5f,
           "in-plane, an ortho click lands where it was made, on the q lattice");
    assert(abs(got.x - focus.x) > 1e-3f || abs(got.y - focus.y) > 1e-3f,
           "rig premise: the pixel must be off-centre, or nothing is measured");
}
