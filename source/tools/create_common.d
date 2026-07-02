module tools.create_common;

import math : Vec3, Viewport, dot;
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
/// ACEN.Auto relocate plane at `transform.d:1036` all call this — it is a
/// live production path, not a headless-only shim. `WorkplaneStage` is the
/// single owner of the answer:
///   - auto  ⇒ the `WorkplanePacket.init` default (world XZ, origin 0) —
///     there is no headless equivalent of the camera-facing pick, so this
///     is NOT the last-published camera-driven packet (see Risk 1 in
///     doc/workplane_single_source_plan.md: reading the live camera pick
///     here would tilt the ACEN.Auto relocate plane and break the
///     auto-origin=focus behaviour).
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
    sr = snapCursor(hitWorld, sx, sy, vp, mesh, localPkt, excludeVerts);
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
