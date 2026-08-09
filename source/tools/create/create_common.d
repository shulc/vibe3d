module tools.create.create_common;

import math : Vec3, Viewport, dot, isOrtho, rayPlaneIntersect, screenPointToRay;
import std.math : abs;

import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.packets        : SubjectPacket, WorkplanePacket, SnapPacket;
import toolpipe.stage          : TaskCode;
import toolpipe.stages.workplane : WorkplaneStage;
import operator                : VectorStack;

import mesh : Mesh;
import editmode : EditMode;
import snap : SnapResult, snapCursor;
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
    SubjectPacket subj;
    subj.viewport = vp;   // workplane stage reads viewport for auto-mode camera-facing pick
    VectorStack vts;
    vts.put(&subj);
    g_pipeCtx.pipeline.evaluate(vts);
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
        // so primitives and relocates land on the plane the user is looking at.
        f.origin = vp.focus;
        f.isAuto = true;
    } else {
        SubjectPacket subj;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);
        g_pipeCtx.pipeline.evaluate(vts);
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

/// The default construction frame: world XZ plane, normal +Y, origin 0,
/// isAuto=true. This is the ONE fallback identity — used whenever the
/// stage can't be consulted (no pipe) or is itself in auto mode (there is
/// no headless equivalent of the camera-facing pick — see
/// `currentWorkplaneFrame`'s doc comment).
private WorkplaneFrame worldXZFrame() {
    return frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1),
                           Vec3(0, 0, 0), true);
}

/// Build a WorkplaneFrame from a WorkplanePacket (stage state or its
/// default). Shared by `currentWorkplaneFrame`'s stage-found path.
private WorkplaneFrame frameFromPacket(const WorkplanePacket p) {
    return frameFromBasis(p.normal, p.axis1, p.axis2, p.center, p.isAuto);
}

/// The frame accessor used by every plane-consuming tool: the `applyHeadless`
/// of all 8 interactive Create-tools (sphere/cone/box/tube/torus/cylinder/
/// capsule + arc), the interactive commit at `arc.d:317`, and the
/// ACEN.Auto relocate plane in `transform.d` (`computeClickRelocateHitRaw`)
/// all call this — it is a live production path, not a headless-only shim.
/// The relocate call site additionally calls `pickMostFacingPlane` directly
/// for its auto-mode plane NORMAL (see below); this accessor still supplies
/// its `isAuto` flag and the pinned-plane fallback. `WorkplaneStage` is the
/// single owner of the answer:
///   - auto  ⇒ the `WorkplanePacket.init` default (world XZ, origin 0) —
///     there is no headless equivalent of the camera-facing pick THROUGH
///     THIS ACCESSOR, because it deliberately avoids `pipeline.evaluate`
///     (re-entrancy risk on tool event-handling paths — see
///     doc/acen_auto_port_plan.md Risk 3). A caller that needs the live
///     camera-facing axis in auto mode (the ACEN.Auto relocate) reads it
///     from a separate, pure `pickMostFacingPlane(vp)` call instead of
///     from this accessor's auto branch.
///   - non-auto ⇒ the stage's live basis + center.
/// `g_pipeCtx is null` or the stage can't be found ⇒ the same world-XZ
/// default (the one fallback identity, `worldXZFrame`).
WorkplaneFrame currentWorkplaneFrame() {
    if (g_pipeCtx is null) return worldXZFrame();
    if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work))
        return frameFromPacket(wp.currentState());
    return worldXZFrame();
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
    Vec3 o, d;
    screenPointToRay(sx, sy, vp, o, d);
    orgLocal = transformPoint(frame.toLocal, o);
    dirLocal = transformDir (frame.toLocal, d);
}

/// Intersect the cursor ray at pixel (sx, sy) with a plane stated in `frame`'s
/// LOCAL space. Returns false on the same parallel-ray condition
/// `rayPlaneIntersect` refuses on.
///
/// In an axis-locked orthographic view against the camera-facing plane this is
/// algebraically the ported law's no-ray arm
/// (`tools.transform.relocate_plane.posToPrincipalPlane`): the ortho ray
/// origin IS the unprojected click, the direction is the plane normal, so the
/// intersection changes exactly the one coordinate along the view axis and
/// leaves the other two at the click. The unittest below asserts that equality
/// rather than asserting it in prose.
bool workplaneCursorPlaneHit(in WorkplaneFrame frame, const ref Viewport vp,
                             float sx, float sy,
                             Vec3 planeOrigin, Vec3 planeNormal,
                             out Vec3 hitLocal)
{
    Vec3 o, d;
    workplaneCursorRay(frame, vp, sx, sy, o, d);
    return rayPlaneIntersect(o, d, planeOrigin, planeNormal, hitLocal);
}

/// Where a click lands on the ACTIVE construction plane, in WORLD space.
///
/// TOTAL — there is no "could not", and that is the point. The call sites this
/// replaces were written `if (screenToWorkPlane(...)) handle.setPos(hit);`
/// with no else, so a refusal kept the previous value and the click was simply
/// not registered. A boolean nobody is forced to read turns "cannot" into
/// "unchanged", which is indistinguishable from success at the only place a
/// user can see it.
///
/// The plane FOLLOWS THE VIEW, which is the other half of the same defect: the
/// plane those call sites projected onto was the fixed world floor (Y = 0,
/// normal (0,1,0)), which a horizontal view's ray is exactly parallel to — so
/// all four horizontal axis presets refused, every time, in silence.
///
/// The law is `XfrmTransformTool.computeClickRelocateHitRaw`'s Auto/None
/// branch, read from there rather than re-derived:
///   * auto     -> the camera-most-facing principal world axis as the normal,
///                 anchored at the camera FOCUS;
///   * pinned   -> the stage's full frame (rotation and origin both), because
///                 collapsing it onto a principal axis would discard the
///                 user's rotation without telling them.
/// `currentWorkplaneFrame` is deliberately the accessor used (not
/// `pickWorkplaneFrame`): it reads the stage directly and never calls
/// `pipeline.evaluate`, so this stays safe to call from a mouse handler that
/// is itself inside a pipeline walk.
///
/// Lives beside the other workplane accessors rather than in a create-only
/// module by accident: the construction plane is global state
/// (`WorkplaneStage`), and non-create callers (the command-wrapper click
/// handle, the radial-array centre) want exactly the same answer the
/// Create-tools drop geometry on.
Vec3 screenToConstructionPlane(float sx, float sy, const ref Viewport vp)
{
    WorkplaneFrame wf = currentWorkplaneFrame();
    Vec3 planeOrigin = wf.isAuto ? vp.focus : wf.origin;
    Vec3 planeNormal = wf.isAuto ? pickMostFacingPlane(vp).normal : wf.normal;

    Vec3 o, d;
    screenPointToRay(sx, sy, vp, o, d);

    Vec3 hit;
    if (rayPlaneIntersect(o, d, planeOrigin, planeNormal, hit))
        return hit;

    // The only reachable refusal: a user-PINNED plane seen edge-on. Swap in
    // the camera-perpendicular plane through the same origin — task 0226's
    // fix, the same swap `computeClickRelocateHitRaw` makes for the same
    // configuration. The cursor ray meets that plane at |dot| >= cos(halfFov)
    // (== 1 under ortho), so this second test cannot refuse and the function
    // is total.
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    if (rayPlaneIntersect(o, d, planeOrigin, camBack, hit))
        return hit;

    // Unreachable: `camBack` is the ray direction itself under ortho and
    // within one half-FOV of it under perspective. Returning the plane origin
    // (the point under the cursor at screen centre) is a defined answer, not
    // a silent retention of whatever the caller had before.
    return planeOrigin;
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
bool frameIsLeftHanded(in WorkplaneFrame frame) {
    // det of upper-left 3×3 of toWorld (column-major).
    const ref float[16] m = frame.toWorld;
    float a = m[0], b = m[4], c = m[8];
    float d = m[1], e = m[5], f = m[9];
    float g = m[2], h = m[6], i = m[10];
    float det = a*(e*i - f*h) - b*(d*i - f*g) + c*(d*h - e*g);
    return det < 0;
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
    SubjectPacket subj;
    subj.mesh     = cast(Mesh*)&mesh;
    subj.editMode = editMode;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    g_pipeCtx.pipeline.evaluate(vts);
    auto snapPkt = vts.get!SnapPacket();
    if (snapPkt is null) return SnapPacket.init;
    return *snapPkt;
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
///
/// `excludeTypes` (default 0 = no change) lets callers suppress specific
/// SnapType bits from the shared pipeline packet before `snapCursor` runs.
/// The Pen uses this to prevent the transform-scoped WorldAxis-through-origin
/// (snap.d Stage 2) from firing during pen clicks — the Pen handles those
/// guide types itself via applyPenGuide. All other Create-tools pass 0 and
/// are byte-identical to the pre-guide code path.
SnapResult snapLocalHit(ref Vec3 hitLocal,
                        in WorkplaneFrame frame,
                        int sx, int sy,
                        const ref Viewport vp,
                        const ref Mesh mesh,
                        EditMode editMode,
                        const(uint)[] excludeVerts = [],
                        uint excludeTypes = 0)
{
    SnapResult sr;
    if (g_pipeCtx is null) return sr;
    SubjectPacket subj;
    subj.mesh             = cast(Mesh*)&mesh;   // SnapStage doesn't mutate
    subj.editMode         = editMode;
    subj.viewport         = vp;
    VectorStack vts;
    vts.put(&subj);
    g_pipeCtx.pipeline.evaluate(vts);
    auto snapPkt = vts.get!SnapPacket();
    if (snapPkt is null || !snapPkt.enabled) return sr;

    // Apply exclusion mask: the caller can suppress certain SnapType bits so
    // it can handle those constraint types itself. Default 0 = no change
    // (backward-compatible for all non-Pen Create-tools).
    SnapPacket localPkt = *snapPkt;
    localPkt.enabledTypes &= ~excludeTypes;

    Vec3 hitWorld = transformPoint(frame.toWorld, hitLocal);
    sr = snapCursor(hitWorld, sx, sy, vp, mesh, primaryModelSpace(), localPkt, excludeVerts);
    if (sr.snapped)
        hitLocal = transformPoint(frame.toLocal, sr.worldPos);
    return sr;
}

unittest {
    import math : Viewport;

    // Helper: build a Viewport whose view matrix has given column-major
    // elements. Only elements [2], [6], [10] (the forward-vector components)
    // matter for pickMostFacingPlane.
    Viewport makeVp(float v2, float v6, float v10) {
        Viewport vp;
        vp.view[] = 0;
        vp.view[2]  = v2;
        vp.view[6]  = v6;
        vp.view[10] = v10;
        return vp;
    }

    // Camera looking mostly along X — should pick X plane
    {
        auto vp = makeVp(0.9f, 0.3f, 0.1f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.x == 1 && bp.normal.y == 0 && bp.normal.z == 0);
        assert(bp.axis1.y  == 1);
        assert(bp.axis2.z  == 1);
    }

    // Camera looking mostly along Y — should pick Y plane
    {
        auto vp = makeVp(0.1f, 0.95f, 0.2f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.y == 1 && bp.normal.x == 0 && bp.normal.z == 0);
        assert(bp.axis1.x  == 1);
        assert(bp.axis2.z  == 1);
    }

    // Camera looking mostly along Z — should pick Z plane
    {
        auto vp = makeVp(0.1f, 0.2f, 0.85f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.z == 1 && bp.normal.x == 0 && bp.normal.y == 0);
        assert(bp.axis1.x  == 1);
        assert(bp.axis2.y  == 1);
    }

    // Equal X and Z — X wins (avx >= avz in tie)
    {
        auto vp = makeVp(0.7f, 0.0f, 0.7f);
        auto bp = pickMostFacingPlane(vp);
        assert(bp.normal.x == 1);
    }
}

// WorkplaneFrame matrix smoke test — toWorld∘toLocal = identity, and
// local Y maps to the published normal. Independent of g_pipeCtx.
unittest {
    import std.math : abs;
    auto f = frameFromBasis(
        Vec3(0, 1, 0),                  // normal = +Y
        Vec3(1, 0, 0),                  // axis1  = +X
        Vec3(0, 0, 1),                  // axis2  = +Z
        Vec3(2.0f, 3.0f, 4.0f));        // origin offset

    // Local origin → world origin offset.
    auto p0 = transformPoint(f.toWorld, Vec3(0, 0, 0));
    assert(abs(p0.x - 2.0f) < 1e-6f);
    assert(abs(p0.y - 3.0f) < 1e-6f);
    assert(abs(p0.z - 4.0f) < 1e-6f);

    // Round-trip a non-trivial point.
    auto pw = Vec3(7.0f, 8.0f, 9.0f);
    auto pl = transformPoint(f.toLocal, pw);
    auto pw2 = transformPoint(f.toWorld, pl);
    assert(abs(pw2.x - pw.x) < 1e-5f);
    assert(abs(pw2.y - pw.y) < 1e-5f);
    assert(abs(pw2.z - pw.z) < 1e-5f);

    // Local Y axis (direction, no translation) → world normal.
    auto upL = Vec3(0, 1, 0);
    auto upW = transformDir(f.toWorld, upL);
    assert(abs(upW.x - f.normal.x) < 1e-6f);
    assert(abs(upW.y - f.normal.y) < 1e-6f);
    assert(abs(upW.z - f.normal.z) < 1e-6f);
}

// 90° workplane (worldX preset: normal = +X, axis1 = -Y, axis2 = +Z)
// plus a centre offset — verifies the inverse against a non-identity
// rotation, which is the case alignToSelection-style frames hit.
unittest {
    import std.math : abs;
    auto f = frameFromBasis(
        Vec3(1, 0, 0),                  // normal  = +X
        Vec3(0, -1, 0),                 // axis1   = -Y
        Vec3(0, 0, 1),                  // axis2   = +Z
        Vec3(5, 0, 0));                 // origin

    // World point (5, 1, 0) is at local (-1, 0, 0) — origin shifted, then
    // y-flipped because axis1 = -Y so local-X maps to negative-world-Y.
    auto pl = transformPoint(f.toLocal, Vec3(5, 1, 0));
    assert(abs(pl.x - (-1.0f)) < 1e-5f);
    assert(abs(pl.y -   0.0f)  < 1e-5f);
    assert(abs(pl.z -   0.0f)  < 1e-5f);

    auto pw = transformPoint(f.toWorld, Vec3(2, 0, 3));
    // local (2,0,3) → world: origin + 2*axis1 + 0*normal + 3*axis2
    //                       = (5,0,0) + (0,-2,0) + (0,0,3) = (5,-2,3)
    assert(abs(pw.x - 5.0f)  < 1e-5f);
    assert(abs(pw.y - (-2)) < 1e-5f);
    assert(abs(pw.z - 3.0f) < 1e-5f);
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

unittest { // ortho: identical to the ported law's no-ray arm, term for term
    import std.math : abs, tan, PI;
    import tools.transform.relocate_plane : posToPrincipalPlane;
    import math : screenPointToRay, lockedViewAxis;

    immutable float dist = 4.5f;
    immutable Vec3  focus = Vec3(0.7f, 0.5f, 2.0f);
    auto vp = frontOrthoViewport(dist, focus);
    assert(lockedViewAxis(vp) == 2,
           "rig premise: a Front ortho view is axis-locked on Z");

    auto f = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                            focus, true);

    foreach (px; [40.0f, 200.0f, 320.0f, 610.0f]) {
        foreach (py; [15.0f, 190.0f, 240.0f, 470.0f]) {
            Vec3 hitLocal;
            assert(workplaneCursorPlaneHit(f, vp, px, py, Vec3(0, 0, 0),
                                           Vec3(0, 1, 0), hitLocal));
            Vec3 mine = transformPoint(f.toWorld, hitLocal);

            // The ported law, driven from the same ray.
            Vec3 o, d;
            screenPointToRay(px, py, vp, o, d);
            Vec3 theirs;
            assert(posToPrincipalPlane(vp, o, d, 2, vp.focus, false, 0.0f, theirs));

            assert(abs(mine.x - theirs.x) < 1e-5f
                && abs(mine.y - theirs.y) < 1e-5f
                && abs(mine.z - theirs.z) < 1e-5f,
                "the ortho arm must BE the ported law's no-ray arm, not a "
                ~ "second opinion that happens to agree at the centre pixel");
        }
    }
}

unittest { // perspective is untouched: the ray still leaves the eye
    import std.math : abs;
    import math : perspectiveMatrix, screenRay;

    Viewport vp;
    vp.width = 640; vp.height = 480;
    vp.focus = Vec3(0, 0, 0);
    vp.eye   = Vec3(0, 0, 3);
    vp.view  = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, -3, 1];
    vp.proj  = perspectiveMatrix(0.785398f, 640.0f / 480.0f, 0.1f, 100.0f);
    assert(!isOrtho(vp), "rig premise: this arm must be perspective");

    auto f = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                            Vec3(0, 0, 0), true);
    Vec3 hitLocal;
    assert(workplaneCursorPlaneHit(f, vp, 500.0f, 120.0f, Vec3(0, 0, 0),
                                   Vec3(0, 1, 0), hitLocal));
    Vec3 mine = transformPoint(f.toWorld, hitLocal);

    // What the pre-0661 pair computed, spelled out.
    Vec3 oldEye = transformPoint(f.toLocal, vp.eye);
    Vec3 oldRay = transformDir (f.toLocal, screenRay(500.0f, 120.0f, vp));
    Vec3 oldHit;
    assert(rayPlaneIntersect(oldEye, oldRay, Vec3(0, 0, 0), Vec3(0, 1, 0), oldHit));
    Vec3 old = transformPoint(f.toWorld, oldHit);

    assert(abs(mine.x - old.x) < 1e-5f && abs(mine.y - old.y) < 1e-5f
        && abs(mine.z - old.z) < 1e-5f,
        "the perspective arm must be byte-for-byte the behaviour it replaces");
}

unittest { // screenToConstructionPlane is TOTAL where the old floor plane refused
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

    // No `g_pipeCtx` in a unittest, so `currentWorkplaneFrame` returns the
    // auto identity and the auto branch runs — the one this defect lived in.
    Vec3 got = screenToConstructionPlane(500.0f, 120.0f, vp);
    assert(abs(got.z - focus.z) < 1e-5f,
           "the plane follows the view AND is anchored at the camera focus: "
           ~ "a Front view lands on Z = focus.z, not Z = 0");
    // ...and in-plane it is the point under the cursor, which under ortho is
    // the unprojected click itself.
    assert(abs(got.x - rayO.x) < 1e-5f && abs(got.y - rayO.y) < 1e-5f,
           "in-plane, an ortho click lands where it was made");
    assert(abs(got.x - focus.x) > 1e-3f || abs(got.y - focus.y) > 1e-3f,
           "rig premise: the pixel must be off-centre, or nothing is measured");
}

// frameIsLeftHanded — determinant sign for pickMostFacingPlane's three
// canonical bases (task 0424). The X-dominant and Z-dominant cases are the
// bug trigger (PrimitiveCreateTool.applyFrameToMeshRange / BoxTool's own
// applyFrameToMesh both branch on this); Y-dominant (and the world-XZ
// default) must stay right-handed so every non-triggering camera/preset/
// headless path is byte-stable.
unittest {
    // Y-dominant (pickMostFacingPlane case 1): axis1=X, normal=Y, axis2=Z —
    // right-handed (this is also worldXZFrame()'s shape).
    auto fY = frameFromBasis(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    assert(!frameIsLeftHanded(fY), "Y-dominant frame should be right-handed");

    // X-dominant (case 0): axis1=Y, normal=X, axis2=Z — left-handed.
    auto fX = frameFromBasis(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(0, 0, 0));
    assert(frameIsLeftHanded(fX), "X-dominant frame should be left-handed");

    // Z-dominant (case 2): axis1=X, normal=Z, axis2=Y — left-handed.
    auto fZ = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 0));
    assert(frameIsLeftHanded(fZ), "Z-dominant frame should be left-handed");
}

// reverseFaceWinding — reverses only faces[firstFaceIdx .. $] in place;
// anything before firstFaceIdx (pre-existing scene geometry from another
// tool/gesture) must be left untouched.
unittest {
    Mesh m;
    m.faces ~= [0u, 1u, 2u];        // pre-existing face — must be left alone
    m.faces ~= [3u, 4u, 5u, 6u];    // "new" face 1
    m.faces ~= [7u, 8u, 9u];        // "new" face 2

    reverseFaceWinding(&m, 1);      // only faces[1 .. $] should reverse

    assert(m.faces[0] == [0u, 1u, 2u],       "pre-existing face must be untouched");
    assert(m.faces[1] == [6u, 5u, 4u, 3u],   "new face 1 should reverse in place");
    assert(m.faces[2] == [9u, 8u, 7u],       "new face 2 should reverse in place");
}
