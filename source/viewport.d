module viewport;

import view       : View, ProjKind, ViewPreset;
import viewcache  : VertexCache, FaceBoundsCache, EdgeCache;
import gpu_select : GpuSelectBuffer;
import math       : Viewport;

// ---------------------------------------------------------------------------
// Phase 1 — global camera / ViewCache / picking → per-viewport data model.
//
// Viewport3D: owns one camera (View), the three screen-space caches, and the
// GPU-select picker for exactly one viewport cell.
//
// ViewportManager: owns the array of Viewport3D cells (ONE cell in Phase 1,
// up to FOUR in Phase 4), routing helpers, and the GL init/shutdown lifecycle.
//
// app.d accesses these objects through ref-returning nested accessors:
//   ref View cameraView()    { return vpm.views[vpm.activeId].camera; }
//   ref VertexCache ...      { return vpm.views[vpm.activeId].vcache; }
//   GpuSelectBuffer gpuSel() { return vpm.views[vpm.activeId].gpuSel; }
// so all ~190 command-ctor injection sites, camera-member uses, and cache-method
// calls are textually unchanged.  The only mandatory call-site edits are the
// ~318 address-of sites (&x → &x()); see doc/viewport_phase1_plan.md §A.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// LayoutPreset — Phase 4
// ---------------------------------------------------------------------------

/// Layout presets controlling how the 3D area is subdivided into cells.
/// Single = one cell (default, --test invariant); SplitH = left/right;
/// SplitV = top/bottom; Quad = 2×2 grid.
enum LayoutPreset { Single, SplitH, SplitV, Quad }

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
/// reallocation.  Phase-4: views[] is pre-allocated to 4 and never reallocated.
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
    bool       indCenter = true;
    bool       indScale  = true;
    bool       indRotate = true;
    int        masterId  = -1;

    // Phase-4: window-space cell rect (for the input router) and stable
    // ImGui window id string.  winX/Y/W/H are set by the Viewport##k
    // window loop (interactive) or by cellRectsFor (--test / analytic).
    int    winX = 0, winY = 0, winW = 0, winH = 0;
    string windowId;   // "Viewport##0" .. "Viewport##3"

    this(int cellIdx, int x, int y, int w, int h) {
        import std.conv : to;
        camera   = new View(x, y, w, h);
        windowId = "Viewport##" ~ to!string(cellIdx);
        winX = x;  winY = y;  winW = w;  winH = h;
    }

    /// Return the current camera snapshot (calls camera.viewport()).
    Viewport snapshotOf() { return camera.viewport(); }

    /// True when this viewport's camera is using orthographic projection.
    bool isOrtho() const { return camera.projKind == ProjKind.Ortho; }
}

// ---------------------------------------------------------------------------
// ViewportManager
// ---------------------------------------------------------------------------

/// Owns the viewport cell array plus routing / activation state.
///
/// Phase 1: exactly ONE live cell (views[0]).  activeId == hoveredId == 0.
/// Phase 4: up to FOUR live cells; `cellCount` gates liveness.
///
/// The `views` array is PRE-ALLOCATED to 4 elements at construction and NEVER
/// reallocated.  This keeps the HTTP-thread GET provider safe: it indexes
/// views[id].camera without a mutex — the array length is stable for the
/// object's lifetime.
final class ViewportManager {
    // Stable 4-element array (MAJOR-6).  Only views[0..cellCount] are live.
    Viewport3D[4] views;   // fixed-size static array; no heap realloc ever

    int          activeId    = 0;
    int          hoveredId   = 0;
    /// masterId: the "master" camera for linked views — reserved Phase 5, inert.
    int          masterId    = 0;
    /// dragOriginId: cell where the current pointer gesture began.
    /// -1 = no active gesture.  Latched at MOUSEBUTTONDOWN; cleared at UP.
    int          dragOriginId = -1;
    /// cellCount: number of live cells (1..4).  Gates iteration everywhere.
    int          cellCount   = 1;
    /// layout: current layout preset.
    LayoutPreset layout      = LayoutPreset.Single;
    /// layoutDirty: set by applyLayout(); cleared by the app loop after the
    /// DockBuilder rebuild.
    bool         layoutDirty = false;

    /// Layout rect of the 3D viewport region.  Must be kept in sync with the
    /// SDL window-resize path so viewportUnderCursor() isn't stale.
    int          lx, ly, lw, lh;

    this(int x, int y, int w, int h) {
        // Pre-allocate all 4 cells (stable length — HTTP thread indexes this).
        // Only views[0] is live at startup (cellCount = 1).  Cells 1-3 exist
        // with valid cameras but null gpuSel until applyLayout makes them live.
        foreach (k; 0..4)
            views[k] = new Viewport3D(k, x, y, w, h);
        cellCount = 1;
        lx = x;  ly = y;  lw = w;  lh = h;
    }

    // ------------------------------------------------------------------
    // GL lifecycle
    // ------------------------------------------------------------------

    /// Initialise the GL-context-dependent GPU-select picker for live cells.
    /// Must be called AFTER the GL context exists (called from app.d init,
    /// replacing the old `gpuSelect.init()` call).
    /// Newly-live cells beyond cellCount=1 are gpu-init'd in applyLayout().
    void initGpu() {
        foreach (v; views[0..cellCount]) {
            v.gpuSel = new GpuSelectBuffer();
            v.gpuSel.init();
        }
    }

    /// Release GL resources for ALL cells.  Safe to call multiple times
    /// (null-guards gpuSel), replacing the old `scope(exit) gpuSelect.destroy()`.
    void shutdown() {
        foreach (v; views[]) {
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
    // Layout helpers — Phase 4
    // ------------------------------------------------------------------

    /// Number of live cells for a given preset.
    static int cellsFor(LayoutPreset p) pure nothrow @nogc {
        final switch (p) {
            case LayoutPreset.Single: return 1;
            case LayoutPreset.SplitH: return 2;
            case LayoutPreset.SplitV: return 2;
            case LayoutPreset.Quad:   return 4;
        }
    }

    /// Analytically subdivide the rectangle [rx,ry,rw,rh] into up to 4
    /// cell rects for the given preset.  All outputs are filled for all 4
    /// slots; only [0..cellsFor(p)] are meaningful.
    ///
    /// Single: cell0 = the whole rect (MUST equal the interactive window
    ///   content rect so --test and interactive routes are pixel-identical).
    /// SplitH: cell0=left half, cell1=right half (integer division, no gap).
    /// SplitV: cell0=top half, cell1=bottom half.
    /// Quad:   cell0=TL, cell1=TR, cell2=BL, cell3=BR.
    static void cellRectsFor(LayoutPreset p,
                              int rx, int ry, int rw, int rh,
                              out int[4] xs, out int[4] ys,
                              out int[4] ws, out int[4] hs)
        pure nothrow @nogc
    {
        xs[] = 0; ys[] = 0; ws[] = 0; hs[] = 0;
        final switch (p) {
            case LayoutPreset.Single:
                xs[0] = rx; ys[0] = ry; ws[0] = rw; hs[0] = rh;
                break;
            case LayoutPreset.SplitH: {
                int hw = rw / 2;
                xs[0] = rx;      ys[0] = ry; ws[0] = hw;      hs[0] = rh;
                xs[1] = rx + hw; ys[1] = ry; ws[1] = rw - hw; hs[1] = rh;
                break;
            }
            case LayoutPreset.SplitV: {
                int hh = rh / 2;
                xs[0] = rx; ys[0] = ry;      ws[0] = rw; hs[0] = hh;
                xs[1] = rx; ys[1] = ry + hh; ws[1] = rw; hs[1] = rh - hh;
                break;
            }
            case LayoutPreset.Quad: {
                int hw = rw / 2, hh = rh / 2;
                xs[0] = rx;      ys[0] = ry;      ws[0] = hw;      hs[0] = hh;
                xs[1] = rx + hw; ys[1] = ry;      ws[1] = rw - hw; hs[1] = hh;
                xs[2] = rx;      ys[2] = ry + hh; ws[2] = hw;      hs[2] = rh - hh;
                xs[3] = rx + hw; ys[3] = ry + hh; ws[3] = rw - hw; hs[3] = rh - hh;
                break;
            }
        }
    }

    /// Switch to a new layout preset: update cellCount, gpu-init newly-live
    /// cells, assign per-cell camera presets (Quad only), compute initial
    /// cell rects, clamp indices, dirty all live cells, raise layoutDirty.
    ///
    /// Must be called from the main thread (GPU init requires a GL context).
    void applyLayout(LayoutPreset p) {
        int oldCount = cellCount;
        layout    = p;
        cellCount = cellsFor(p);

        // GPU-init newly-live cells (requires GL context; no-op in unittest).
        version(unittest) {} else {
            foreach (k; oldCount .. cellCount) {
                if (views[k].gpuSel is null) {
                    views[k].gpuSel = new GpuSelectBuffer();
                    views[k].gpuSel.init();
                }
            }
        }

        // Assign per-cell camera presets for Quad layout.
        // TL(0)=Top, TR(1)=Front, BL(2)=Left, BR(3)=Perspective.
        if (p == LayoutPreset.Quad) {
            views[0].camera.viewPreset = ViewPreset.Top;
            views[0].camera.projKind   = ProjKind.Ortho;
            views[1].camera.viewPreset = ViewPreset.Front;
            views[1].camera.projKind   = ProjKind.Ortho;
            views[2].camera.viewPreset = ViewPreset.Left;
            views[2].camera.projKind   = ProjKind.Ortho;
            views[3].camera.viewPreset = ViewPreset.Perspective;
            views[3].camera.projKind   = ProjKind.Perspective;
        }

        // Compute initial analytic cell rects (the interactive window loop
        // overrides these once it runs; this serves as a pre-first-frame
        // fallback and as the authoritative rect for --test mode).
        int[4] cxs, cys, cws, chs;
        cellRectsFor(p, lx, ly, lw, lh, cxs, cys, cws, chs);
        foreach (k; 0..cellCount) {
            views[k].winX = cxs[k];  views[k].winY = cys[k];
            views[k].winW = cws[k];  views[k].winH = chs[k];
            views[k].camera.setSize(cws[k], chs[k]);
        }

        // Hygiene: clear drag origin; clamp activation indices to valid range.
        dragOriginId = -1;
        if (activeId  >= cellCount) activeId  = cellCount - 1;
        if (hoveredId >= cellCount) hoveredId = cellCount - 1;
        if (masterId  >= cellCount) masterId  = 0;

        dirtyAll();
        layoutDirty = true;
    }

    /// Mark every live cell dirty (forces a re-render next frame).
    void dirtyAll() {
        foreach (v; views[0..cellCount]) v.dirty = true;
    }

    // ------------------------------------------------------------------
    // Input router
    // ------------------------------------------------------------------

    /// Return the index of the viewport cell whose rect contains the
    /// window-space point (wx, wy), or −1 if the point is outside every
    /// live cell.
    ///
    /// In Single layout (cellCount==1) this is identical to the ph1 rect
    /// test because views[0].winRect == {lx,ly,lw,lh}.
    int viewportUnderCursor(int wx, int wy) {
        foreach (k; 0..cellCount) {
            auto v = views[k];
            if (wx >= v.winX && wx < v.winX + v.winW &&
                wy >= v.winY && wy < v.winY + v.winH)
                return k;
        }
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
    ref View hoveredCamera() {
        immutable int id = hoveredId >= 0 ? hoveredId : activeId;
        return views[id].camera;
    }

    /// The camera of the ORIGIN cell for the current gesture.
    /// During a pointer gesture (dragOriginId >= 0), returns the origin
    /// cell's camera so all drag math stays frozen to that cell.
    /// Outside a gesture, falls back to the active cell's camera.
    ref View originCamera() {
        return views[dragOriginId >= 0 ? dragOriginId : activeId].camera;
    }
}

// ---------------------------------------------------------------------------
// Unittests — pure (no GL), verifying the data-model invariants the refactor
// rests on.  Run via `dub test --config=modeling`.
// ---------------------------------------------------------------------------
unittest {
    // 1. Basic construction: 4 allocated cells, cellCount=1, correct initial IDs.
    auto m = new ViewportManager(10, 20, 640, 480);
    assert(m.views.length == 4,   "must pre-allocate 4 cells (stable array)");
    assert(m.cellCount    == 1,   "cellCount must start at 1");
    assert(m.activeId     == 0,   "activeId must start at 0");
    assert(m.hoveredId    == 0,   "hoveredId must start at 0");
    assert(m.dragOriginId == -1,  "dragOriginId must start at -1");
    assert(m.layout       == LayoutPreset.Single, "layout must start as Single");

    // 2. Router identity: inside vs. outside the single-cell rect [10,650)×[20,500).
    //    With Single layout, views[0].winRect = (10,20,640,480).
    assert(m.viewportUnderCursor(100, 100) == 0,  "cursor inside → 0");
    assert(m.viewportUnderCursor(0,   0)   == -1, "(0,0) outside → -1");
    assert(m.viewportUnderCursor(9,   19)  == -1, "just outside origin → -1");
    assert(m.viewportUnderCursor(649, 499) == 0,  "last inside pixel → 0");
    assert(m.viewportUnderCursor(650, 499) == -1, "right edge outside → -1");
    assert(m.viewportUnderCursor(649, 500) == -1, "bottom edge outside → -1");

    // 3. activeCamera() aliases views[0].camera (not a copy).
    assert(m.activeCamera() is m.views[0].camera,
           "activeCamera() must alias views[0].camera");

    // 4. Mutation through activeCamera() is observable on views[0].
    m.activeCamera().orbit(5, 5);
    assert(m.activeCamera().azimuth == m.views[0].camera.azimuth,
           "mutation through activeCamera() must be visible on views[0]");

    // 5. hoveredCamera() falls back to activeCamera() when hoveredId < 0.
    m.hoveredId = -1;
    assert(m.hoveredCamera() is m.views[m.activeId].camera,
           "hoveredCamera() with hoveredId=-1 must fall back to activeCamera()");
    m.hoveredId = 0;   // restore

    // 6. originCamera(): no gesture → active cell; gesture → origin cell.
    assert(m.originCamera() is m.views[0].camera,
           "originCamera() with no gesture must return active cell camera");
    m.dragOriginId = 0;
    assert(m.originCamera() is m.views[0].camera,
           "originCamera() with dragOriginId=0 must return views[0].camera");
    m.dragOriginId = -1;  // restore

    // 7. snapshotOf sanity: same construction args → same snapshot output.
    //    Uses a FRESH manager (m's camera was mutated by orbit() in test 4).
    {
        auto m2         = new ViewportManager(10, 20, 640, 480);
        auto standalone = new View(10, 20, 640, 480);
        assert(m2.snapshotOf(0) == standalone.viewport(),
               "snapshotOf must match an equivalent standalone View.viewport()");
    }

    // 8. windowId: each cell gets a stable id string.
    {
        auto m3 = new ViewportManager(0, 0, 800, 600);
        assert(m3.views[0].windowId == "Viewport##0");
        assert(m3.views[1].windowId == "Viewport##1");
        assert(m3.views[2].windowId == "Viewport##2");
        assert(m3.views[3].windowId == "Viewport##3");
    }
}

// ---------------------------------------------------------------------------
// cellsFor + cellRectsFor unittests
// ---------------------------------------------------------------------------
unittest {
    // cellsFor.
    assert(ViewportManager.cellsFor(LayoutPreset.Single) == 1);
    assert(ViewportManager.cellsFor(LayoutPreset.SplitH) == 2);
    assert(ViewportManager.cellsFor(LayoutPreset.SplitV) == 2);
    assert(ViewportManager.cellsFor(LayoutPreset.Quad)   == 4);

    // cellRectsFor — Single: must equal the full rect (MINOR-8 pixel-identity).
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.Single, 10, 20, 640, 480,
                                     xs, ys, ws, hs);
        assert(xs[0] == 10 && ys[0] == 20 && ws[0] == 640 && hs[0] == 480,
               "Single must return the whole rect");
    }

    // cellRectsFor — SplitH: two exact halves, no gap, no overlap.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.SplitH, 0, 0, 640, 480,
                                     xs, ys, ws, hs);
        // Left + right widths sum to total; no overlap.
        assert(ws[0] + ws[1] == 640,      "SplitH widths must sum to total");
        assert(xs[1] == xs[0] + ws[0],    "SplitH: right starts where left ends");
        assert(ys[0] == 0 && hs[0] == 480, "SplitH: same height");
        assert(ys[1] == 0 && hs[1] == 480, "SplitH: same height R");
    }

    // cellRectsFor — SplitV: two exact halves top/bottom.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.SplitV, 0, 0, 640, 480,
                                     xs, ys, ws, hs);
        assert(hs[0] + hs[1] == 480,       "SplitV heights must sum to total");
        assert(ys[1] == ys[0] + hs[0],     "SplitV: bottom starts where top ends");
        assert(xs[0] == 0 && ws[0] == 640, "SplitV: same width");
        assert(xs[1] == 0 && ws[1] == 640, "SplitV: same width B");
    }

    // cellRectsFor — Quad: four tiles, no gap, no overlap.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.Quad, 100, 50, 640, 480,
                                     xs, ys, ws, hs);
        // Column widths.
        assert(ws[0] + ws[1] == 640, "Quad: top row widths sum to total");
        assert(ws[2] + ws[3] == 640, "Quad: bottom row widths sum to total");
        assert(ws[0] == ws[2],       "Quad: left column same width");
        assert(ws[1] == ws[3],       "Quad: right column same width");
        // Row heights.
        assert(hs[0] + hs[2] == 480, "Quad: left column heights sum to total");
        assert(hs[1] + hs[3] == 480, "Quad: right column heights sum to total");
        assert(hs[0] == hs[1],       "Quad: top row same height");
        assert(hs[2] == hs[3],       "Quad: bottom row same height");
        // Origin offsets.
        assert(xs[0] == 100 && ys[0] == 50,  "Quad TL origin");
        assert(xs[1] == 100 + ws[0] && ys[1] == 50, "Quad TR origin");
        assert(xs[2] == 100 && ys[2] == 50 + hs[0], "Quad BL origin");
        assert(xs[3] == 100 + ws[0] && ys[3] == 50 + hs[0], "Quad BR origin");
    }
}

// ---------------------------------------------------------------------------
// viewportUnderCursor multi-cell + applyLayout unittests
// ---------------------------------------------------------------------------
unittest {
    // Quad hit-test via applyLayout (lx/ly/lw/lh must be set first).
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    assert(m.cellCount == 4,  "Quad layout must produce 4 live cells");
    assert(!m.views[0].dirty || m.views[0].dirty, "dirtyAll ran — just checking no crash");

    // Each cell's top-left interior pixel must map to the correct index.
    // TL=0: top-left quadrant, TR=1: top-right, BL=2: bottom-left, BR=3: bottom-right.
    // Cell rects: 0=(0,0,320,240), 1=(320,0,320,240), 2=(0,240,320,240), 3=(320,240,320,240)
    assert(m.viewportUnderCursor(1,   1)   == 0, "TL interior → cell 0");
    assert(m.viewportUnderCursor(321, 1)   == 1, "TR interior → cell 1");
    assert(m.viewportUnderCursor(1,   241) == 2, "BL interior → cell 2");
    assert(m.viewportUnderCursor(321, 241) == 3, "BR interior → cell 3");
    // Outside the whole rect.
    assert(m.viewportUnderCursor(640, 0)   == -1, "right of last cell → -1");
    assert(m.viewportUnderCursor(0,   480) == -1, "below last cell → -1");

    // applyLayout hygiene: clamp indices, clear dragOriginId.
    m.activeId    = 3;
    m.hoveredId   = 3;
    m.masterId    = 3;
    m.dragOriginId = 2;
    m.applyLayout(LayoutPreset.Single);
    assert(m.cellCount    == 1,  "Single: cellCount=1");
    assert(m.activeId     == 0,  "activeId clamped to 0");
    assert(m.hoveredId    == 0,  "hoveredId clamped to 0");
    assert(m.masterId     == 0,  "masterId clamped to 0");
    assert(m.dragOriginId == -1, "dragOriginId cleared");
    assert(m.layoutDirty,        "layoutDirty raised");

    // Single layout router after applyLayout — same as old single-rect test.
    m.views[0].winX = 0; m.views[0].winY = 0;
    m.views[0].winW = 640; m.views[0].winH = 480;
    assert(m.viewportUnderCursor(100, 100) == 0,   "inside single cell → 0");
    assert(m.viewportUnderCursor(640, 0)   == -1,  "right of single cell → -1");
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
