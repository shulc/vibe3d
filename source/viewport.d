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
// ViewportFbo — Phase 2
// ---------------------------------------------------------------------------

/// GL FBO for rendering one viewport cell's scene into (color RGBA8 + depth24).
///
/// Ids (fbo / colorTex / depthRbo) are generated ONCE on first use and remain
/// stable for the object's lifetime.  On a size change, EXISTING storage is
/// re-specified in-place via glTexImage2D / glRenderbufferStorage — never
/// delete+regen — so an ImGui.Image handle recorded before a resize still
/// names a live texture at RenderDrawData time.  Pattern mirrors
/// gpu_select.d:607-635 exactly.
struct ViewportFbo {
    uint fbo      = 0;
    uint colorTex = 0;
    uint depthRbo = 0;
    int  w        = 0;
    int  h        = 0;
    int  _allocGen = 0;  // bumped on first use and each resize; used by unittest

    /// Ensure the FBO is at least (newW × newH).  Guards w>0 && h>0.
    /// On a size change, re-specifies existing storage in place — ids are stable.
    void ensure(int newW, int newH) {
        if (newW <= 0 || newH <= 0) return;
        if (newW == w && newH == h && w > 0) return;
        w = newW;
        h = newH;
        _allocGen++;
        version(unittest) {} else {
            import bindbc.opengl;
            // Generate ids on first use only.
            if (fbo == 0) {
                glGenFramebuffers(1, &fbo);
                glGenTextures(1, &colorTex);
                glGenRenderbuffers(1, &depthRbo);
            }
            // Re-specify existing storage in place (ids stay stable).
            glBindTexture(GL_TEXTURE_2D, colorTex);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, null);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glBindTexture(GL_TEXTURE_2D, 0);

            glBindRenderbuffer(GL_RENDERBUFFER, depthRbo);
            glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
            glBindRenderbuffer(GL_RENDERBUFFER, 0);

            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                   GL_TEXTURE_2D, colorTex, 0);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                      GL_RENDERBUFFER, depthRbo);
            GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (status != GL_FRAMEBUFFER_COMPLETE) {
                import std.conv : to;
                throw new Exception(
                    "ViewportFbo: FBO incomplete (status=0x"
                    ~ to!string(status, 16) ~ ")");
            }
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
        }
    }

    /// Release GL resources.  Null-safe and idempotent.
    void destroy() {
        version(unittest) {
            w = 0; h = 0; _allocGen = 0;
            fbo = 0; colorTex = 0; depthRbo = 0;
            return;
        } else {
            import bindbc.opengl;
            if (fbo != 0)      { glDeleteFramebuffers(1, &fbo);       fbo      = 0; }
            if (colorTex != 0) { glDeleteTextures(1, &colorTex);      colorTex = 0; }
            if (depthRbo != 0) { glDeleteRenderbuffers(1, &depthRbo); depthRbo = 0; }
            w = 0; h = 0; _allocGen = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// DirtyKey — Phase 2 dirty-cache
// ---------------------------------------------------------------------------

/// Captures the enumerable render inputs for one viewport cell.
/// Two identical DirtyKeys mean the scene image has not changed and the
/// retained colorTex can be re-blitted without a GL re-render.
struct DirtyKey {
    float[16] view  = 0;
    float[16] proj  = 0;
    ulong     meshMutVer;
    ulong     selEpoch;   // bumped on every selection-mark change (Marks class)
    int       editMode_k;
    int       hovV, hovE, hovF;
    int       fboW,  fboH;
}

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

    // Phase-2 FBO + dirty-cache fields.
    ViewportFbo fbo;
    bool        dirty    = true;   // starts dirty → first frame always renders
    DirtyKey    lastKey;

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
            v.fbo.destroy();
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

// ---------------------------------------------------------------------------
// ViewportFbo unittests — pure size-decision logic (no GL context needed).
// ---------------------------------------------------------------------------
unittest {
    ViewportFbo f;

    // Initial state.
    assert(f.w == 0 && f.h == 0 && f._allocGen == 0, "initial state must be zeroed");

    // ensure with invalid sizes must be a no-op.
    f.ensure(0, 100);
    assert(f._allocGen == 0, "ensure(0,100) must be a no-op");
    f.ensure(100, 0);
    assert(f._allocGen == 0, "ensure(100,0) must be a no-op");
    f.ensure(-1, -1);
    assert(f._allocGen == 0, "ensure(-1,-1) must be a no-op");

    // First valid call allocates storage.
    f.ensure(100, 100);
    assert(f.w == 100 && f.h == 100, "ensure(100,100) must set w=100, h=100");
    assert(f._allocGen == 1, "first ensure must bump _allocGen to 1");

    // Same size → idempotent (no realloc).
    f.ensure(100, 100);
    assert(f._allocGen == 1, "same-size ensure must NOT bump _allocGen");

    // Size change → realloc.
    f.ensure(200, 100);
    assert(f.w == 200 && f.h == 100, "size-change ensure must update w/h");
    assert(f._allocGen == 2, "size-change ensure must bump _allocGen");

    f.ensure(200, 300);
    assert(f._allocGen == 3, "second size-change must bump _allocGen again");

    // Idempotent after second change.
    f.ensure(200, 300);
    assert(f._allocGen == 3, "same size after resize must be idempotent");

    // destroy resets tracking fields.
    f.destroy();
    assert(f.w == 0 && f.h == 0 && f._allocGen == 0,
           "destroy must reset w, h, _allocGen to 0");

    // ensure works again after destroy.
    f.ensure(64, 64);
    assert(f.w == 64 && f.h == 64 && f._allocGen == 1,
           "ensure after destroy must work as a fresh first call");
}
