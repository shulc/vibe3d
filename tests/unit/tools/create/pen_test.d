// Module unittests for `tools.create.pen`, moved verbatim out of source/tools/create/pen.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.create.pen_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tool;
import mesh;
import math;
import params : Param;
import handler : BoxHandler, gizmoSize, ToolHandles;
import viewport_scheme : schemeColor, SchemeColor;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import tools.create.create_common : pickWorkplane, BuildPlane,
                              pickWorkplaneFrame, WorkplaneFrame,
                              mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              currentSnapPacket,
                              workplaneCursorRay, workplaneCursorPlaneHit;
import toolpipe.packets : SnapType;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import std.math : abs;
import tools.create.pen;

// Pure guide-geometry unit tests — no HTTP harness, no app loop.
// Covers the core math used by applyPenGuide so dub test catches regressions
// independently of the interactive test suite.
unittest {
    import tools.create.create_common : transformDir, frameFromBasis;

    // Helper: verify two floats agree to < 1e-5.
    static bool near(float a, float b) { return abs(a - b) < 1e-5f; }

    // --- straightLine candidate ---
    // Closest point on infinite line (anchor=(0.2,0,0), dir=(1,0,0)) to a
    // vertical ray at x=0.7, y=1, z=0 pointing straight down.
    // Expected: (0.7, 0, 0).
    {
        import math : closestPointOnLineToRay;
        Vec3 anchor = Vec3(0.2f, 0, 0);
        Vec3 dir    = Vec3(1, 0, 0);
        Vec3 p = closestPointOnLineToRay(anchor, dir,
                                         Vec3(0.7f, 1, 0), Vec3(0, -1, 0));
        assert(near(p.x, 0.7f) && near(p.y, 0) && near(p.z, 0));
    }

    // --- rightAngle direction: cross(planeNormal, segL) ---
    // planeNormal = (0,1,0), segL = (1,0,0) → perp = (0,0,-1).
    // Verify perp ⊥ segL AND perp ⊥ planeNormal (stays in-plane).
    {
        Vec3 pn   = Vec3(0, 1, 0);
        Vec3 segL = Vec3(1, 0, 0);
        Vec3 perp = cross(pn, segL);
        assert(perp.length > 1e-6f);                      // non-degenerate
        Vec3 perpN = normalize(perp);
        assert(abs(dot(perpN, segL)) < 1e-6f);            // ⊥ segment
        assert(abs(dot(perpN, pn))   < 1e-6f);            // stays in-plane
        assert(near(perpN.x, 0) && near(perpN.z, -1.0f)); // specific direction
    }

    // --- worldAxis in-plane filter (aN case: planeNormal = local-Y) ---
    // For the Z-workplane frame (normal=+Z, axis1=+X, axis2=+Y, origin=0):
    // world +X and +Y land in the plane (local y≈0), world +Z maps to the
    // plane normal (local y=1) and should be skipped.
    // choosePlane gives planeNormal=(0,1,0) when aN wins (camBack ≈ frame.normal).
    {
        auto f = frameFromBasis(Vec3(0,0,1), Vec3(1,0,0), Vec3(0,1,0),
                                Vec3(0,0,0));
        Vec3 pn  = Vec3(0,1,0); // planeNormal in local coords (aN case)
        Vec3 axX = transformDir(f.toLocal, Vec3(1,0,0)); // world +X
        Vec3 axY = transformDir(f.toLocal, Vec3(0,1,0)); // world +Y
        Vec3 axZ = transformDir(f.toLocal, Vec3(0,0,1)); // world +Z (plane normal)
        assert(abs(dot(axX, pn)) < 0.1f);  // in-plane — should NOT be filtered
        assert(abs(dot(axY, pn)) < 0.1f);  // in-plane — should NOT be filtered
        assert(abs(dot(axZ, pn)) > 0.9f);  // plane-normal — SHOULD be filtered
    }

    // --- worldAxis in-plane filter: non-Y planeNormal (view-dependent regression) ---
    // Default Y-up frame (normal=Y, axis1=X, axis2=Z) has identity toLocal,
    // so axL == ax for every world axis.  choosePlane sets planeNormal=(0,0,1)
    // in local space when aZ wins — i.e. when camBack is most aligned with
    // frame.axis2 (world Z in the default frame).  In that case:
    //   construction plane  = XY plane (normal = world Z = local (0,0,1))
    //   in-plane axes       = world X (local (1,0,0)) and world Y (local (0,1,0))
    //   plane-normal axis   = world Z (local (0,0,1))   ← must be filtered
    //
    // OLD code abs(axL.y) — wrong for this case:
    //   world Z → axL=(0,0,1) → abs(axL.y)=0 → NOT filtered  ← misses the normal
    //   world Y → axL=(0,1,0) → abs(axL.y)=1 → filtered       ← drops in-plane axis
    //
    // NEW code abs(dot(axL, planeNormal)):
    //   world X → dot((1,0,0),(0,0,1))=0 → NOT filtered ✓
    //   world Y → dot((0,1,0),(0,0,1))=0 → NOT filtered ✓
    //   world Z → dot((0,0,1),(0,0,1))=1 → filtered     ✓
    {
        auto f  = frameFromBasis(Vec3(0,1,0), Vec3(1,0,0), Vec3(0,0,1), Vec3(0,0,0));
        Vec3 pn = Vec3(0,0,1); // planeNormal in local coords (aZ case, world Z is normal)

        immutable Vec3[3] worldAxes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
        // world Z (index 2) is the plane normal and must be filtered; X and Y must not.
        foreach (size_t i, ax; worldAxes) {
            Vec3 axL     = transformDir(f.toLocal, ax);
            bool newPass = abs(dot(axL, pn)) > 0.9f;
            assert(newPass == (i == 2),
                   "worldAxis non-Y planeNormal: wrong filter result for axis index " ~
                   cast(char)('0' + i));
        }
        // Red→green witness: confirm old abs(axL.y) was wrong.
        Vec3 axZL = transformDir(f.toLocal, Vec3(0,0,1)); // world Z, the plane normal
        Vec3 axYL = transformDir(f.toLocal, Vec3(0,1,0)); // world Y, an in-plane axis
        // Old code: abs(axZL.y)=0 → did NOT filter world Z (missed the plane normal).
        assert(abs(axZL.y) < 0.1f,
               "RED witness: old abs(axL.y) must fail to filter world-Z plane-normal");
        // Old code: abs(axYL.y)=1 → DID filter world Y (wrongly dropped in-plane axis).
        assert(abs(axYL.y) > 0.9f,
               "RED witness: old abs(axL.y) must wrongly filter in-plane world-Y axis");
    }

    // --- degenerate segment guard ---
    // Two coincident prior vertices produce a zero-length segVec. Guard:
    // segVec.length < 1e-6f, so normalize is never called (would yield NaN).
    {
        Vec3 v0 = Vec3(1, 0, 0);
        Vec3 v1 = Vec3(1, 0, 0);  // same as v0
        Vec3 segVec = v1 - v0;
        assert(segVec.length < 1e-6f);  // guard triggers: guide inert
    }
}
