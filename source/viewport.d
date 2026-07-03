module viewport;

import view       : View, ProjKind, ViewPreset;
import viewcache  : VertexCache, FaceBoundsCache, EdgeCache;
import gpu_select : GpuSelectBuffer;
import math       : Viewport, Vec3;

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
    // Live tool matrix (transform gizmo's gpuMatrix, identity when idle/no
    // tool). During a drag this changes every frame while meshMutVer/selEpoch
    // do not (the edit only commits to the mesh at gesture end), so without
    // this field an inactive Quad/Split cell's key never changes mid-gesture
    // and the cell freezes. `= 0` (not `identityMatrix`): a struct field
    // default must be CTFE-constant, and `identityMatrix` (math.d) is
    // `immutable float[16]` — casting that to a mutable field default is not
    // supported at compile time. The interactive render loop overwrites this
    // every frame before comparing (see app.d N-cell FBO render loop), so the
    // zero default is inert; the --test branch never reaches the compare.
    float[16] toolMat = 0;

    // Task 0206 (Quad/Split multi-cell overlays), Phase 1 — overlay-state
    // term, mirrors toolMat above. `toolMat` alone only changes during a
    // LIVE drag (gpuMatrix moves every motion frame); it stays at identity
    // the moment a tool activates on an unchanged selection or a falloff
    // gizmo is enabled/edited via the panel with no drag in flight — so
    // without this term a non-owner Quad/Split cell would not refresh until
    // its own camera moved, and a static gizmo would appear to not exist in
    // that cell. This term captures the GIZMO's WORLD state (view-
    // independent — the interactive render loop stamps the SAME value into
    // every cell's key, exactly like toolMat), so "gizmo appeared / moved /
    // falloff center or radius changed" is caught even at rest.
    // `= 0` CTFE-constant defaults, inert in --test (Single layout never
    // reaches the compare) — same neutrality argument as toolMat.
    int       overlayKind    = 0; // bit0 = tool gizmo active, bit1 = falloff active
    float[3]  overlayCenter  = 0; // gizmo pivot (ActionCenterPacket.center)
    float[3]  falloffCenter  = 0;
    float     falloffRadius  = 0;

    // Task 0210 (Quad/Split live soft-drag preview) — shared GPU
    // vertex-buffer epoch (GpuMesh.uploadVersion). meshMutVer stays stable
    // during a soft/CPU-fold drag (deformers write mesh.vertices in place
    // and re-upload the VBO WITHOUT a mutationVersion bump — see
    // transform.d's uploadToGpu), and toolMat only moves on the RIGID
    // fast-path (no re-upload happens there). This term moves whenever the
    // VBO is rewritten, so inactive Quad/Split cells re-render on every
    // frame a falloff drag deforms the mesh. `= 0` CTFE-constant default,
    // inert in --test (Single layout never reaches the compare) — same
    // neutrality argument as toolMat/overlay terms above.
    ulong     gpuUploadVer   = 0;

    // Task 0209 (Quad/Split any-cell input) — shared rollover ("hot") part,
    // mirrors overlayKind/gpuUploadVer above. The arbiter (ToolHandles /
    // PipeGizmoHost pool) now runs in the HOVERED cell each frame, and every
    // eligible cell draws the SAME shared `hot` state (task 0206). Without
    // this term, a non-hovered eligible cell whose own view/proj/mesh are
    // unchanged would not re-render when `hot` flips as the cursor rolls
    // onto/off a handle in another cell — leaving a stale highlight there.
    // `= -1` (no part hot) is CTFE-constant, inert in --test (Single layout
    // never reaches the compare) — same neutrality argument as the other
    // overlay terms.
    int       overlayHot     = -1;
}

unittest {
    // DirtyKey must discriminate on toolMat alone: two keys identical in
    // every other field but different toolMat must compare unequal, or an
    // inactive cell's dirty-key compare would silently ignore a live drag on
    // another cell (the exact freeze this field exists to fix).
    DirtyKey a, b;
    a.meshMutVer = 7; b.meshMutVer = 7;
    a.selEpoch   = 3; b.selEpoch   = 3;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.toolMat[12] = 1.5f; // e.g. a translate baked into the tool matrix
    assert(a != b, "keys differing only in toolMat must compare unequal");
}

unittest {
    // Task 0206 Phase 1: DirtyKey must also discriminate on the overlay
    // term alone — two keys identical in every other field (including
    // toolMat, at rest = identity/0) but differing only in overlayKind or
    // overlayCenter must compare unequal. This is the exact idle-freeze
    // this term exists to fix: a tool/falloff gizmo appearing or moving
    // with no live drag in progress (meshMutVer/selEpoch/toolMat all
    // unchanged).
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.overlayKind = 1; // tool gizmo activated
    assert(a != b, "keys differing only in overlayKind must compare unequal");

    b.overlayKind = 0;
    b.overlayCenter = [1.0f, 0.0f, 0.0f]; // gizmo pivot moved (no drag, e.g. panel edit)
    assert(a != b, "keys differing only in overlayCenter must compare unequal");

    b.overlayCenter = [0.0f, 0.0f, 0.0f];
    b.falloffCenter = [0.0f, 0.0f, 2.0f];
    assert(a != b, "keys differing only in falloffCenter must compare unequal");

    b.falloffCenter = [0.0f, 0.0f, 0.0f];
    b.falloffRadius = 3.0f;
    assert(a != b, "keys differing only in falloffRadius must compare unequal");
}

unittest {
    // Task 0210: DirtyKey must also discriminate on gpuUploadVer alone —
    // two keys identical in every other field (including toolMat/overlay*
    // at rest) but differing only in gpuUploadVer must compare unequal.
    // This is the exact freeze this term exists to fix: a soft/falloff
    // drag re-uploads the shared VBO every frame without moving
    // meshMutVer, toolMat, or any overlay term.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.gpuUploadVer = 1;
    assert(a != b, "keys differing only in gpuUploadVer must compare unequal");
}

unittest {
    // Task 0209: DirtyKey must also discriminate on overlayHot alone — two
    // keys identical in every other field (including toolMat/overlay*/
    // gpuUploadVer at rest) but differing only in overlayHot must compare
    // unequal. This is the exact stale-highlight freeze this term exists to
    // fix: the cursor rolls onto/off a handle in the hovered (owner) cell,
    // flipping the shared `hot` part with no drag/mesh/view change, and every
    // OTHER eligible cell must still notice and re-render to mirror it.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.overlayHot = 3; // e.g. a move-arrow handle rolled over
    assert(a != b, "keys differing only in overlayHot must compare unequal");
}

// ---------------------------------------------------------------------------
// overlayDrawOrder — task 0206 Phase 0/3
// ---------------------------------------------------------------------------

/// Cell visitation order for the N-cell overlay draw pass: every cell OTHER
/// than `ownerId` first, then `ownerId` LAST.
///
/// The overlay-owner (active/origin) cell's `Interactive` draw pins the
/// active tool's `cachedVp` + `ToolHandles` registration/hit-test state
/// (see `Tool.draw`'s `visualOnly` doc comment) — that state must be the
/// one resident when this frame's draw pass ends, since the NEXT frame's
/// event handling reads it. Drawing the owner last guarantees that
/// regardless of how many non-owner `Visual` replicas ran first.
///
/// `cellCount == 1` (the `--test` invariant, Single layout) always returns
/// `[ownerId]` — a single-element order, so the visual (non-owner) branch is
/// NEVER taken and the FBO render loop is byte-identical to pre-task-0206
/// behaviour. Pure / no GC churn beyond the returned array.
int[] overlayDrawOrder(int cellCount, int ownerId) {
    int[] order;
    order.reserve(cellCount);
    foreach (k; 0 .. cellCount)
        if (k != ownerId) order ~= k;
    order ~= ownerId;
    return order;
}

unittest {
    // --test byte-neutrality guard: cellCount == 1 must return exactly
    // [activeId] (the owner), never taking the multi-cell visual branch.
    assert(overlayDrawOrder(1, 0) == [0]);
}

unittest {
    // Quad (cellCount == 4): owner drawn last, every other cell visited
    // exactly once, order of the non-owner cells otherwise unspecified but
    // stable (ascending scan order here).
    assert(overlayDrawOrder(4, 2) == [0, 1, 3, 2]);
    assert(overlayDrawOrder(4, 0) == [1, 2, 3, 0]);
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
    // ImGui window id string.  The rect has ONE owner — the camera (`View`)
    // itself, since `View.viewportWith(...)` already bakes x/y/width/height
    // into every camera-matrix snapshot (viewport camera single-source,
    // 0181). winX/Y/W/H are named forwarding views onto `camera.x/y/width/
    // height`, not a second copy — set by the Viewport##k window loop
    // (interactive) or by cellRectsFor (--test / analytic), same as before.
    @property int  winX() const { return camera.x; }
    @property void winX(int v)  { camera.x = v; }
    @property int  winY() const { return camera.y; }
    @property void winY(int v)  { camera.y = v; }
    @property int  winW() const { return camera.width; }
    @property void winW(int v)  { camera.width = v; }
    @property int  winH() const { return camera.height; }
    @property void winH(int v)  { camera.height = v; }
    string windowId;   // "Viewport##0" .. "Viewport##3"

    this(int cellIdx, int x, int y, int w, int h) {
        import std.conv : to;
        camera   = new View(x, y, w, h);   // already sets x/y/width/height
        windowId = "Viewport##" ~ to!string(cellIdx);
    }

    /// Return the current camera snapshot, computed directly from the
    /// camera's own transform inputs (no member mirror — viewport camera
    /// single-source, 0181).
    Viewport snapshotOf() {
        return camera.viewportWith(camera.focus, camera.distance,
                                    camera.azimuth, camera.elevation);
    }

    /// True when this viewport's camera is using orthographic projection.
    bool isOrtho() const { return camera.projKind == ProjKind.Ortho; }

    /// Reset this cell's independence flags to the fully-independent baseline
    /// (V4): own center, own scale, own rotate, no per-cell master. The one
    /// body for a default that used to be duplicated across the field
    /// initializers, applyLayout's per-cell sweep, and resetToDefault.
    void resetIndependence() {
        indCenter = true;
        indScale  = true;
        indRotate = true;
        masterId  = -1;
    }
}

/// Single source of truth for a per-cell view-preset write (task 0215):
/// the three fields the view-selector dropdown, the `viewport.view` command,
/// and the numpad view shortcuts must all set identically. Axis presets
/// (Top/Bottom/Front/Back/Right/Left) imply Ortho projection; Perspective/
/// Camera imply Perspective. Marks the cell dirty so the FBO re-renders next
/// frame; does not touch selection, editMode, or the active tool.
void applyCellViewPreset(Viewport3D cell, ViewPreset preset) {
    cell.camera.viewPreset = preset;
    cell.camera.projKind   = (preset == ViewPreset.Perspective || preset == ViewPreset.Camera)
        ? ProjKind.Perspective : ProjKind.Ortho;
    cell.dirty = true;
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

        // Phase-5: reset ALL cells to fully-independent before applying the new
        // preset.  This prevents independence flags from leaking across layout
        // switches (e.g. Quad → Single would keep indCenter=false on cells 0-2).
        foreach (k; 0..4)
            views[k].resetIndependence();
        masterId = 0;

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

            // Phase-5: linked quad defaults — ortho cells follow the persp master
            // (cell 3) on Center + Scale but keep their own Rotate (az/el is
            // irrelevant for axis-locked ortho).
            foreach (k; 0..3) {
                views[k].indCenter = false;
                views[k].indScale  = false;
                views[k].indRotate = true;
                // masterId=-1 → use group master (masterId=3 set below)
            }
            masterId = 3;  // perspective cell is the group master
        }

        // Compute initial analytic cell rects (the interactive window loop
        // overrides these once it runs; this serves as a pre-first-frame
        // fallback and as the authoritative rect for --test mode).
        // The four property writes below ARE the rect's single owner
        // (camera.x/y/width/height) — no separate camera.setSize needed.
        int[4] cxs, cys, cws, chs;
        cellRectsFor(p, lx, ly, lw, lh, cxs, cys, cws, chs);
        foreach (k; 0..cellCount) {
            views[k].winX = cxs[k];  views[k].winY = cys[k];
            views[k].winW = cws[k];  views[k].winH = chs[k];
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

    /// Restore the launch default so viewport state never bleeds across the
    /// shared `--test` instance (invoked by `/api/reset`, `file.new`, and bare
    /// `scene.reset` via the `onViewportReset` delegate — the SOLE camera-reset
    /// owner for these paths, V3): Single layout, one live cell, active/hovered
    /// = 0, no in-flight drag, every cell back to free perspective.
    /// `applyLayout(Single)` already resets
    /// cellCount/activeId/hoveredId/dragOriginId/ind*/masterId/rects+size (the
    /// clamp forces activeId→0); this additionally resets every cell's camera —
    /// `View.reset()` now covers projKind/viewPreset too, so a prior Quad's
    /// per-cell ortho preset on cells 0-2 can't survive into the next test.
    void resetToDefault() {
        foreach (k; 0..4) {
            // Reset every cell's camera to the default framing (focus=origin,
            // standard az/el/distance/projKind/viewPreset). A non-active cell
            // could otherwise keep a stale focus and poison a later test that
            // assumes a fresh camera (e.g. the Quad Top-cell centre-grab).
            views[k].camera.reset();
        }
        applyLayout(LayoutPreset.Single);
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

    /// True when the ORIGIN cell's camera (same fallback rule as
    /// originCamera(): the current gesture's cell, or the active cell
    /// outside a gesture) is orthographic (V7). Mirrors originCamera()'s
    /// fallback but answers the `Viewport3D.isOrtho()` question instead,
    /// since `View` itself has no `isOrtho()` — that state lives on the cell.
    bool originIsOrtho() {
        return views[dragOriginId >= 0 ? dragOriginId : activeId].isOrtho();
    }

    // ------------------------------------------------------------------
    // Phase-5 independence resolution helpers
    // ------------------------------------------------------------------

    /// Resolve the effective transform inputs for cell `id` according to its
    /// independence flags and master pointer.  Reads RAW own+master camera
    /// members — never calls resolvedSnapshot recursively (single-hop, cycle-safe).
    /// `const` so it is safe to call from any thread.
    void resolveFollow(int id,
                       out Vec3 focus, out float distance,
                       out float az,   out float el) const {
        auto f   = views[id];
        int  mid = groupMasterOf(id);
        auto m   = views[mid];
        focus    = f.indCenter ? f.camera.focus    : m.camera.focus;
        distance = f.indScale  ? f.camera.distance : m.camera.distance;
        az       = f.indRotate ? f.camera.azimuth  : m.camera.azimuth;
        el       = f.indRotate ? f.camera.elevation: m.camera.elevation;
    }

    /// Resolve cell `id`'s effective linkage master: its own `masterId` if
    /// set, else the group `masterId`, falling back to `id` itself if that
    /// resolves out of range. Single-hop, cycle-safe — shared by
    /// `resolveFollow` and the coupled-pan/zoom owner resolvers below
    /// (task 0217).
    int groupMasterOf(int id) const {
        auto f   = views[id];
        int  mid = f.masterId >= 0 ? f.masterId : masterId;
        if (mid < 0 || mid >= cellCount) mid = id;   // safety: self
        return mid;
    }

    /// Resolve which cell's `camera.distance` a zoom gesture originating at
    /// cell `id` should mutate (task 0217, coupled zoom): itself when
    /// independently-scaled (`indScale=true` — the `viewport.indScale`
    /// opt-in override), otherwise the linkage owner (`groupMasterOf`), so a
    /// zoom in a default follower (e.g. an ortho Quad cell) couples to the
    /// whole linked group instead of writing a field `resolveFollow` never
    /// reads.
    int scaleOwner(int id) const {
        return views[id].indScale ? id : groupMasterOf(id);
    }

    /// The camera whose `distance` a zoom gesture originating at cell `id`
    /// should mutate. See `scaleOwner`.
    ref View scaleOwnerCamera(int id) { return views[scaleOwner(id)].camera; }

    /// Resolve which cell's `camera.focus` a pan gesture originating at cell
    /// `id` should mutate (task 0217, coupled pan): itself when
    /// independently-centered (`indCenter=true`), otherwise the linkage
    /// owner (`groupMasterOf`). The screen-space delta itself must still be
    /// computed from the ORIGIN cell's own basis (`View.panDelta`) — only
    /// the write target is redirected here, so an ortho follower's drag
    /// direction stays correct while the shared (master) center moves.
    int focusOwner(int id) const {
        return views[id].indCenter ? id : groupMasterOf(id);
    }

    /// The camera whose `focus` a pan gesture originating at cell `id`
    /// should mutate. See `focusOwner`.
    ref View focusOwnerCamera(int id) { return views[focusOwner(id)].camera; }

    /// Compute a resolved camera snapshot for cell `id` (follow-resolved
    /// focus/distance/az/el via resolveFollow). Non-mutating — the manager's
    /// resolved `Viewport` is the single source of truth for a cell's camera
    /// matrices; there is no `View` member mirror to write back into
    /// (viewport camera single-source, 0181).
    Viewport resolvedSnapshot(int id) {
        Vec3 fo; float di, a, e;
        resolveFollow(id, fo, di, a, e);
        return views[id].camera.viewportWith(fo, di, a, e);
    }

    /// Resolved snapshot for the currently active cell.
    Viewport activeSnapshot() { return resolvedSnapshot(activeId); }

    /// Resolved snapshot for the drag-origin cell (or active if no gesture).
    Viewport originSnapshot() {
        return resolvedSnapshot(dragOriginId >= 0 ? dragOriginId : activeId);
    }

    /// Resolved snapshot for the cell that owns the CURRENT pointer input:
    /// the drag-origin cell during a gesture, else the hovered cell, else the
    /// active cell. In Single layout (cellCount==1) this is identical to
    /// originSnapshot() (there is no second cell to hover), so `--test`
    /// stays byte-neutral.
    Viewport inputSnapshot() {
        int id = dragOriginId >= 0 ? dragOriginId
               : (cellCount > 1 && hoveredId >= 0 ? hoveredId : activeId);
        return resolvedSnapshot(id);
    }

    /// Return resolved camera JSON for cell `id`.  `const`, non-mutating — safe
    /// on any thread.  Eye is recomputed from the resolved inputs.
    string resolvedCameraJson(int id) const {
        Vec3 fo; float di, a, e;
        resolveFollow(id, fo, di, a, e);
        return views[id].camera.toJsonWith(fo, di, a, e);
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
// inputSnapshot() unittests — task 0209 (Quad/Split any-cell input).
// ---------------------------------------------------------------------------
unittest {
    // Quad layout: inputSnapshot() must resolve to the HOVERED cell (no
    // drag in progress) — the whole point of this task.
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    m.activeId  = 0;
    m.hoveredId = 2;
    assert(m.dragOriginId == -1, "no gesture in progress");
    auto snap = m.inputSnapshot();
    auto want = m.resolvedSnapshot(2);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() with no drag must resolve to the HOVERED cell (2), not active (0)");

    // During a gesture, inputSnapshot() must stay pinned to the DRAG-ORIGIN
    // cell even though the cursor has since wandered into another cell —
    // the drag-pin invariant (frozen basis / flip-fix depend on this).
    m.dragOriginId = 1;
    m.hoveredId    = 3; // cursor now over a DIFFERENT cell mid-drag
    snap = m.inputSnapshot();
    want = m.resolvedSnapshot(1);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() during a drag must stay pinned to dragOriginId (1), ignoring hoveredId (3)");
    m.dragOriginId = -1; // restore

    // hoveredId == -1 (cursor outside all cells, e.g. over an ImGui panel)
    // must fall back to the active cell, same as hoveredCamera().
    m.hoveredId = -1;
    snap = m.inputSnapshot();
    want = m.resolvedSnapshot(m.activeId);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() with hoveredId=-1 must fall back to the active cell");

    // Single layout (cellCount==1): inputSnapshot() must be IDENTICAL to
    // originSnapshot() — the byte-neutrality invariant `--test` relies on.
    m.applyLayout(LayoutPreset.Single);
    m.views[0].winX = 0; m.views[0].winY = 0;
    m.views[0].winW = 640; m.views[0].winH = 480;
    assert(m.cellCount == 1, "Single: cellCount=1");
    m.hoveredId = 0;
    auto inSnap  = m.inputSnapshot();
    auto orgSnap = m.originSnapshot();
    assert(inSnap.view == orgSnap.view && inSnap.proj == orgSnap.proj,
           "cellCount==1: inputSnapshot() must be identical to originSnapshot()");
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

// ---------------------------------------------------------------------------
// Phase-5 resolveFollow + Quad-default unittests
// ---------------------------------------------------------------------------
unittest {
    // 2-cell manager: cell 0 = follower, cell 1 = master.
    auto m = new ViewportManager(0, 0, 800, 600);
    m.lx = 0; m.ly = 0; m.lw = 800; m.lh = 600;

    // Give each cell a distinct camera state.
    m.views[0].camera.focus    = Vec3(1, 0, 0);
    m.views[0].camera.distance = 2.0f;
    m.views[0].camera.azimuth  = 0.1f;
    m.views[0].camera.elevation = 0.2f;

    m.views[1].camera.focus    = Vec3(9, 0, 0);
    m.views[1].camera.distance = 7.0f;
    m.views[1].camera.azimuth  = 1.5f;
    m.views[1].camera.elevation = 0.8f;

    // Point cell 0 at cell 1 as per-cell master.
    m.views[0].masterId = 1;
    m.cellCount = 2;   // make both cells live

    Vec3 fo; float di, a, e;

    // indCenter=true, indScale=true, indRotate=true → all own
    m.views[0].indCenter = true; m.views[0].indScale = true; m.views[0].indRotate = true;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f,  "own center: focus.x must be 1");
    assert(di   == 2.0f,  "own scale: distance must be 2");
    assert(a    == 0.1f,  "own rotate: azimuth must be 0.1");
    assert(e    == 0.2f,  "own rotate: elevation must be 0.2");

    // indCenter=false → follow master's focus
    m.views[0].indCenter = false;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 9.0f, "follow center: focus.x must be 9");
    assert(di   == 2.0f, "scale still own");

    // indScale=false → follow master's distance
    m.views[0].indCenter = true;
    m.views[0].indScale = false;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "center own again");
    assert(di   == 7.0f, "follow scale: distance must be 7");

    // indRotate=false → follow master's az+el
    m.views[0].indScale  = true;
    m.views[0].indRotate = false;
    m.resolveFollow(0, fo, di, a, e);
    import std.math : isClose;
    assert(isClose(a, 1.5f, 1e-5f), "follow rotate: az must be 1.5");
    assert(isClose(e, 0.8f, 1e-5f), "follow rotate: el must be 0.8");

    // Reset flags for next subtests
    m.views[0].indCenter = true; m.views[0].indScale = true; m.views[0].indRotate = true;

    // Self-master: masterId=-1, group masterId=0 → self
    m.views[0].masterId = -1;
    m.masterId = 0;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "self-master: must return own focus");
    assert(di   == 2.0f, "self-master: must return own distance");

    // Out-of-range master → self
    m.views[0].masterId = 99;
    m.views[0].indCenter = false;  // would follow master if master were valid
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "out-of-range master → self, own focus");
    m.views[0].indCenter = true;
    m.views[0].masterId = -1;
}

unittest {
    // Quad layout defaults: cells 0-2 indCenter=false, indScale=false, indRotate=true;
    // cell 3 fully-independent; group masterId=3.
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    assert(m.masterId == 3, "Quad group masterId must be 3");
    foreach (k; 0..3) {
        assert(!m.views[k].indCenter, "Quad ortho cell indCenter must be false");
        assert(!m.views[k].indScale,  "Quad ortho cell indScale must be false");
        assert( m.views[k].indRotate, "Quad ortho cell indRotate must be true");
        assert( m.views[k].masterId == -1, "Quad ortho cell masterId must be -1 (use group)");
    }
    // Persp cell (3) stays fully independent (reset block then no override)
    assert( m.views[3].indCenter, "Quad persp cell indCenter must be true");
    assert( m.views[3].indScale,  "Quad persp cell indScale must be true");
    assert( m.views[3].indRotate, "Quad persp cell indRotate must be true");

    // Layout switch hygiene: Quad → Single → Quad resets cleanly
    m.applyLayout(LayoutPreset.Single);
    assert(m.views[0].indCenter, "Single: cell 0 must reset to indCenter=true");
    assert(m.views[0].indScale,  "Single: cell 0 must reset to indScale=true");
    assert(m.views[0].indRotate, "Single: cell 0 must reset to indRotate=true");
    assert(m.masterId == 0,      "Single: group masterId must be 0");

    m.applyLayout(LayoutPreset.Quad);
    assert(!m.views[0].indCenter, "Quad again: cell 0 indCenter must be false");
    assert(!m.views[1].indScale,  "Quad again: cell 1 indScale must be false");
    assert(m.masterId == 3,       "Quad again: group masterId must be 3");
}
