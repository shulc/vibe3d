module viewport;

import view       : View;
import viewcache  : VertexCache, FaceBoundsCache, EdgeCache;
import gpu_select : GpuSelectBuffer;
import math       : Viewport;

// ---------------------------------------------------------------------------
// Phase 1 — global camera / ViewCache / picking → per-viewport data model.
//
// Viewport3D: owns one camera (View), the three screen-space caches, and the
// GPU-select picker for exactly one viewport cell.
//
// ViewportManager: owns the array of Viewport3D cells (ONE cell in Phase 1),
// routing helpers, and the GL init/shutdown lifecycle.
//
// app.d accesses these objects through ref-returning nested accessors:
//   ref View cameraView()    { return vpm.views[vpm.activeId].camera; }
//   ref VertexCache ...      { return vpm.views[vpm.activeId].vcache; }
//   GpuSelectBuffer gpuSel() { return vpm.views[vpm.activeId].gpuSel; }
// so all ~190 command-ctor injection sites, camera-member uses, and cache-method
// calls are textually unchanged.  The only mandatory call-site edits are the
// ~318 address-of sites (&x → &x()); see doc/viewport_phase1_plan.md §A.
//
// Inert Phase-2..5 fields (proj, preset, indCenter, indScale, indRotate,
// masterId) are declared here but unused in Phase 1.
// ---------------------------------------------------------------------------

/// Projection kind — inert until Phase 3.
enum ProjKind { Perspective, Ortho }

/// Named view preset — inert until Phase 3.
enum ViewPreset { Perspective, Top, Bottom, Front, Back, Left, Right, Camera }

// ---------------------------------------------------------------------------
// Viewport3D
// ---------------------------------------------------------------------------

/// One viewport cell: owns a camera, the three screen-space caches, and the
/// GPU-select picker.
///
/// Declared `final class` (heap-stable) so raw pointers captured at command
/// ctor time (SceneReset/MeshLoadRaw) remain valid across any views[] array
/// reallocation.  Phase-4 seam note: those pointers freeze to the
/// construction-time viewport cell (byte-identical in Phase 1, always cell 0).
final class Viewport3D {
    View             camera;
    VertexCache      vcache;
    FaceBoundsCache  fcache;
    EdgeCache        ecache;
    GpuSelectBuffer  gpuSel;

    // Phase-2..5 inert fields — declared now, unused in Phase 1.
    ProjKind   proj      = ProjKind.Perspective;
    ViewPreset preset    = ViewPreset.Perspective;
    bool       indCenter = true;
    bool       indScale  = true;
    bool       indRotate = true;
    int        masterId  = -1;

    this(int x, int y, int w, int h) {
        camera = new View(x, y, w, h);
    }

    /// Return the current camera snapshot (calls camera.viewport()).
    Viewport snapshotOf() { return camera.viewport(); }
}

// ---------------------------------------------------------------------------
// ViewportManager
// ---------------------------------------------------------------------------

/// Owns the viewport cell array plus routing / activation state.
///
/// Phase 1: exactly ONE cell (views[0]).  activeId == hoveredId == 0.
/// viewportUnderCursor() is a pure rect test returning 0 or −1; with one
/// cell the result is trivially 0 (inside) for all cursor positions in the
/// 3D viewport area, so activeId never leaves 0.
final class ViewportManager {
    Viewport3D[] views;
    int          activeId  = 0;
    int          hoveredId = 0;
    /// masterId: the "master" camera for linked views — reserved Phase 5, inert Phase 1.
    int          masterId  = 0;
    /// Layout rect of the 3D viewport region.  Must be kept in sync with the
    /// SDL window-resize path so viewportUnderCursor() isn't stale.
    int          lx, ly, lw, lh;

    this(int x, int y, int w, int h) {
        views ~= new Viewport3D(x, y, w, h);
        lx = x;  ly = y;  lw = w;  lh = h;
    }

    // ------------------------------------------------------------------
    // GL lifecycle
    // ------------------------------------------------------------------

    /// Initialise the GL-context-dependent GPU-select picker for every cell.
    /// Must be called AFTER the GL context exists (called from app.d init,
    /// replacing the old `gpuSelect.init()` call).
    void initGpu() {
        foreach (v; views) {
            v.gpuSel = new GpuSelectBuffer();
            v.gpuSel.init();
        }
    }

    /// Release GL resources for every cell.  Safe to call multiple times
    /// (null-guards gpuSel), replacing the old `scope(exit) gpuSelect.destroy()`.
    void shutdown() {
        foreach (v; views) {
            if (v.gpuSel !is null) {
                v.gpuSel.destroy();
                v.gpuSel = null;
            }
        }
    }

    // ------------------------------------------------------------------
    // Snapshot helper
    // ------------------------------------------------------------------

    /// Return the camera snapshot for viewport cell `id`.
    Viewport snapshotOf(int id) { return views[id].snapshotOf(); }

    // ------------------------------------------------------------------
    // Input router
    // ------------------------------------------------------------------

    /// Return the index of the viewport cell whose rect contains the
    /// window-space point (wx, wy), or −1 if the point is outside every cell.
    ///
    /// In Phase 1 the single-cell rect is [lx, lx+lw) × [ly, ly+lh); the
    /// function returns 0 when the cursor is inside the 3D viewport and −1
    /// when it is over an ImGui panel or the window border.
    int viewportUnderCursor(int wx, int wy) {
        if (wx >= lx && wx < lx + lw && wy >= ly && wy < ly + lh)
            return 0;
        return -1;
    }

    // ------------------------------------------------------------------
    // Camera accessors (Phase-4 seams)
    // ------------------------------------------------------------------

    /// The camera of the currently ACTIVE viewport.
    ref View activeCamera() { return views[activeId].camera; }

    /// The camera of the currently HOVERED viewport.
    /// Falls back to activeCamera() when hoveredId is −1 (cursor is outside
    /// all viewport rects, e.g. over an ImGui panel).
    /// In Phase 1 hoveredId == activeId == 0, so both return views[0].camera.
    ref View hoveredCamera() {
        immutable int id = hoveredId >= 0 ? hoveredId : activeId;
        return views[id].camera;
    }
}

// ---------------------------------------------------------------------------
// Unittests — pure (no GL), verifying the data-model invariants the refactor
// rests on.  Run via `dub test --config=modeling`.
// ---------------------------------------------------------------------------
unittest {
    // 1. Basic construction: one cell, correct initial IDs.
    auto m = new ViewportManager(10, 20, 640, 480);
    assert(m.views.length == 1, "must have exactly one cell");
    assert(m.activeId  == 0, "activeId must start at 0");
    assert(m.hoveredId == 0, "hoveredId must start at 0");

    // 2. Router identity: inside vs. outside the single rect [10,650)×[20,500).
    assert(m.viewportUnderCursor(100, 100) == 0,  "cursor inside → 0");
    assert(m.viewportUnderCursor(0,   0)   == -1, "(0,0) outside → -1");
    assert(m.viewportUnderCursor(9,   19)  == -1, "just outside origin → -1");
    assert(m.viewportUnderCursor(649, 499) == 0,  "last inside pixel → 0");
    assert(m.viewportUnderCursor(650, 499) == -1, "right edge outside → -1");
    assert(m.viewportUnderCursor(649, 500) == -1, "bottom edge outside → -1");

    // 3. activeCamera() aliases views[0].camera (not a copy).
    assert(m.activeCamera() is m.views[0].camera,
           "activeCamera() must alias views[0].camera");

    // 4. Mutation through activeCamera() is observable on views[0] — proves
    //    the accessor is a genuine ref into the viewport, not a value copy.
    m.activeCamera().orbit(5, 5);
    assert(m.activeCamera().azimuth == m.views[0].camera.azimuth,
           "mutation through activeCamera() must be visible on views[0]");

    // 5. hoveredCamera() falls back to activeCamera() when hoveredId < 0.
    m.hoveredId = -1;
    assert(m.hoveredCamera() is m.views[m.activeId].camera,
           "hoveredCamera() with hoveredId=-1 must fall back to activeCamera()");
    m.hoveredId = 0;   // restore

    // 6. snapshotOf sanity: same construction args → same snapshot output.
    //    Uses a FRESH manager (m's camera was mutated by orbit() in test 4).
    {
        auto m2         = new ViewportManager(10, 20, 640, 480);
        auto standalone = new View(10, 20, 640, 480);
        assert(m2.snapshotOf(0) == standalone.viewport(),
               "snapshotOf must match an equivalent standalone View.viewport()");
    }
}
