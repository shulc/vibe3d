module tools.create_common;

import math : Vec3, Viewport;
import std.math : abs;

import toolpipe.pipeline       : g_pipeCtx;
import toolpipe.packets        : SubjectPacket;
import toolpipe.stage          : TaskCode;
import toolpipe.stages.workplane : WorkplaneStage;

// ---------------------------------------------------------------------------
// Helpers shared by interactive Create-tools (BoxTool and the upcoming
// SphereTool / CylinderTool / ConeTool / CapsuleTool / TorusTool / PenTool).
// Extracted from BoxTool's private helpers so multiple Create-tools can share.
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
    float avx = abs(vp.view[2]);
    float avy = abs(vp.view[6]);
    float avz = abs(vp.view[10]);
    if (avx >= avy && avx >= avz) {
        return BuildPlane(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
    } else if (avy >= avx && avy >= avz) {
        return BuildPlane(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1));
    } else {
        return BuildPlane(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0));
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
    SubjectPacket subj;   // empty subject — the workplane stage doesn't read it
    auto state = g_pipeCtx.pipeline.evaluate(subj, vp);
    return BuildPlane(state.workplane.normal,
                      state.workplane.axis1,
                      state.workplane.axis2);
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
        f.origin = Vec3(0, 0, 0);
        f.isAuto = true;
    } else {
        SubjectPacket subj;
        auto state = g_pipeCtx.pipeline.evaluate(subj, vp);
        f.normal = state.workplane.normal;
        f.axis1  = state.workplane.axis1;
        f.axis2  = state.workplane.axis2;
        f.origin = state.workplane.center;
        f.isAuto = state.workplane.isAuto;
    }
    fillFrameMatrices(f);
    return f;
}

/// Build a frame directly from the WorkplaneStage's internal state — no
/// viewport, no pipeline.evaluate. For headless callers (prim.* commands
/// invoked over HTTP / from the modo_diff harness) where there's no live
/// camera and the auto-mode camera-facing pick has no input. In auto-mode
/// the returned frame is identity (world XZ); in manual / aligned mode
/// the stage's stored center + rotation drive the basis.
WorkplaneFrame currentWorkplaneFrame() {
    WorkplaneFrame f;
    if (g_pipeCtx is null) {
        f.normal = Vec3(0, 1, 0);
        f.axis1  = Vec3(1, 0, 0);
        f.axis2  = Vec3(0, 0, 1);
        f.origin = Vec3(0, 0, 0);
        f.isAuto = true;
        fillFrameMatrices(f);
        return f;
    }
    if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
        if (wp.isAuto) {
            f.normal = Vec3(0, 1, 0);
            f.axis1  = Vec3(1, 0, 0);
            f.axis2  = Vec3(0, 0, 1);
            f.origin = Vec3(0, 0, 0);
            f.isAuto = true;
        } else {
            wp.currentBasis(f.normal, f.axis1, f.axis2);
            f.origin = wp.center;
            f.isAuto = false;
        }
    } else {
        f.normal = Vec3(0, 1, 0);
        f.axis1  = Vec3(1, 0, 0);
        f.axis2  = Vec3(0, 0, 1);
        f.origin = Vec3(0, 0, 0);
        f.isAuto = true;
    }
    fillFrameMatrices(f);
    return f;
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
