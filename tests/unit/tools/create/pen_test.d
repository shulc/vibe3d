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

// One resolve per motion event (task 9362 s3): a drag motion resolves only
// the dragged point, never the hover point as well (the drag resolve would
// overwrite it on the same event). A resolve is one `snapCursor` for the
// user's snap (pipe snap stage enabled) plus one for the merge search when
// `merge` is on, counted as `Cat.snapQuery` scopes: N motions 40 px apart on
// an empty mesh (no target, no marker under the cursor) = 2N with merge on,
// N with it off; the hover resolve restored during a drag doubles both.
version (PerfProbe) unittest {
    import perf_probe : g_perf;
    import std.conv : to;
    import std.format : format;
    import std.json : parseJSON;
    import std.process : environment;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.stages.snap : SnapStage;
    import mesh_gpu : GpuMesh;
    import view : View;

    const hadDriver = "SDL_VIDEODRIVER" in environment;
    const oldDriver = environment.get("SDL_VIDEODRIVER", "");
    environment["SDL_VIDEODRIVER"] =
        environment.get("DISPLAY", "").length != 0 ? "x11" : "offscreen";
    scope (exit) {
        if (hadDriver) environment["SDL_VIDEODRIVER"] = oldDriver;
        else environment.remove("SDL_VIDEODRIVER");
    }
    assert(loadSDL() == sdlSupport, "pen motion rig could not load SDL");
    assert(SDL_Init(SDL_INIT_VIDEO) == 0,
        "pen motion rig could not initialize SDL: " ~ SDL_GetError().to!string);
    scope (exit) SDL_Quit();
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    auto window = SDL_CreateWindow("pen-motion-resolves",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 32, 32,
        SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    assert(window !is null, "pen motion rig: no hidden window: " ~ SDL_GetError().to!string);
    scope (exit) SDL_DestroyWindow(window);
    auto context = SDL_GL_CreateContext(window);
    assert(context !is null, "pen motion rig: no GL context: " ~ SDL_GetError().to!string);
    scope (exit) SDL_GL_DeleteContext(context);
    assert(loadOpenGL() >= glSupport, "pen motion rig could not load OpenGL 3.3");
    SDL_SetModState(cast(SDL_Keymod)0);

    auto saved = g_pipeCtx;
    scope (exit) g_pipeCtx = saved;   // a process-wide global: restore, never null
    auto ctx = new ToolPipeContext();
    auto st = new SnapStage();
    ctx.pipeline.add(st);
    st.enabled = true;   // after the add: `add` resets the stage's config
    g_pipeCtx = ctx;

    Mesh m;
    GpuMesh gpu;
    auto pen = new PenTool(() => &m, &gpu, LitShader.init);
    pen.activate();
    scope (exit) pen.deactivate();
    pen.setViewportForTest(new View(0, 0, 400, 400).viewport());
    float* posX; bool* merge;
    foreach (ref p; pen.params()) {
        if (p.name == "posX") posX = p.fptr;
        if (p.name == "merge") merge = p.bptr;
    }
    assert(posX !is null && merge !is null && *merge, "pen motion rig: params");
    VectorStack vts;

    long dragQueries(int y) {
        SDL_MouseButtonEvent down, up;
        down.button = up.button = SDL_BUTTON_LEFT;
        down.x = up.x = 200; down.y = up.y = y;
        assert(pen.onMouseButtonDown(down, vts), "pen motion rig: the press");
        const before = *posX;
        g_perf.reset();
        foreach (k; 1 .. 5) {
            SDL_MouseMotionEvent e;
            e.x = 200 + 40 * k; e.y = y;
            assert(pen.onMouseMotion(e, vts), "pen motion rig: a drag motion");
        }
        const n = g_perf.toJson().parseJSON()["snapQuery"]["count"].integer;
        up.x = 360;
        pen.onMouseButtonUp(up, vts);
        assert(*posX != before, "pen motion rig: the drag did not move its point");
        return n;
    }
    const withMerge = dragQueries(200);
    *merge = false;
    const withoutMerge = dragQueries(120);
    assert(withMerge == 8 && withoutMerge == 4,
        format("pen: snap queries over 4 drag motions: %s with merge, %s without; "
            ~ "expected 8 and 4 (one resolve per motion)", withMerge, withoutMerge));
}
