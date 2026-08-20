module viewport;

import view          : View, ProjKind, ViewPreset;
import viewcache     : VertexCache, FaceBoundsCache, EdgeCache;
import gpu_select    : GpuSelectBuffer;
import math          : Viewport, Vec3, Orientation;
import display_state : ViewportDisplay, DrawPlan, resolveDrawPlan, kBackdropDim;
// Task 0612 Stage 1 — teardown only. `shutdown()` below is the app's single
// all-GL-objects reclaim site; the cache itself is never touched from here on
// any other path, and nothing in this module reads a texture.
import image_cache   : imagePixelCache;

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

    // Task 0559 (per-viewport display modes) — the display term, and the
    // FIRST genuinely per-cell render input on this struct.
    //
    // Read the comment block above carefully before touching this one: every
    // OTHER term here is SHARED — the render loop stamps the same value into
    // all four cells' keys, because until now the only per-cell render inputs
    // were the camera matrices and the FBO size. Display style is not shared.
    // It must be stamped FROM THE CELL (`_cv`), never from a frame-level
    // value, or all four cells silently share one mode and the bug looks
    // exactly like a working implementation.
    //
    // WHY THE RESOLVED PLANS AND NOT THE STATE. This file documents four
    // prior instances of the same bug — a render input added without a
    // matching key term, so a non-hovered cell froze until its camera moved
    // (`toolMat` :132, the overlay terms :144, `gpuUploadVer` :161,
    // `overlayHot` :174). Every one of those was an ENUMERATED field somebody
    // had to remember to add. So this term is not an encoding of the display
    // state; it is the two `DrawPlan`s the render pass ACTUALLY CONSUMES,
    // stamped from the same `resolveDrawPlan` call the renderer makes. A key
    // derived from what a pass reads cannot miss a term the way a hand-kept
    // list can: a future display field that reaches the plan is caught with
    // no edit here at all, and one that does not reach the plan correctly
    // triggers no re-render.
    //
    // Defaults are CTFE-constant (`DrawPlan`'s own field initialisers) and
    // inert in --test, where the Single layout never reaches the compare —
    // the same neutrality argument as every term above.
    DrawPlan  planActive;
    DrawPlan  planBackdrop;

    // Task 0612 — the reference-image plane term.
    //
    // WHY IT NEEDS ONE AT ALL. The plane is deliberately NOT a `DrawPlan`
    // field (`display_state.d`'s standing rule: the grid, the workplane and
    // the reference image are each their OWN axis), so the `planActive` /
    // `planBackdrop` terms above cannot carry it, and none of the other terms
    // move when a plane's channel, transform, link or texture changes.
    // Without this field a `pixelSize` edit would do nothing until the mouse
    // moved — the exact symptom this file already documents five times
    // (`toolMat` :132, the overlay terms :144, `gpuUploadVer` :161,
    // `overlayHot` :174, the display term above).
    //
    // WHY A DIGEST AND NOT A BUMPED COUNTER. A counter has to be incremented
    // at every write site — plane channels, the item transform, link set and
    // clear, a clip's path change, a texture upload — and item-transform
    // writes in particular go through `layer_params.d`'s generic `Param`
    // pointers, which are raw `float*` stores with no hook to bump from. A
    // digest FOLDED FROM WHAT THE PASS READS cannot miss a write the way a
    // hand-kept list of bump sites can; it is the same argument the display
    // term above makes for storing resolved plans instead of the state they
    // came from.
    //
    // SHARED, not per-cell: plane state is view-independent, so the render
    // loop stamps the same value into every cell's key (exactly like
    // `toolMat` and the overlay terms). WHICH cell shows a plane is a
    // function of that cell's preset, and a preset change moves its camera —
    // i.e. `view`/`proj` above already carry it.
    //
    // `= 0` is CTFE-constant and inert in --test, where the Single layout
    // never reaches the compare — the same neutrality argument as every term
    // above.
    ulong     imagePlaneKey = 0;

    // Task 0647 — the item-highlight term.
    //
    // WHY NONE OF THE TERMS ABOVE CARRY IT. Item-mode hover paints the whole
    // item under the cursor, and the three hover fields above are ELEMENT
    // indices into the primary layer — they stay at -1 for the entire life of
    // an item-mode hover, because no vertex, edge or face is being hovered.
    // `selEpoch` is bumped by mesh-mark changes and does not move when an ITEM
    // is selected; `meshMutVer` does not move for a selection of any kind.
    // So without this field, moving the pointer from one item to another under
    // the Item selection type changes what the pass draws and changes no key —
    // the sixth instance of the bug this file already documents five times
    // (`toolMat` :132, the overlay terms :144, `gpuUploadVer` :161,
    // `overlayHot` :174, the display term, `imagePlaneKey`).
    //
    // A DIGEST, for the `imagePlaneKey` reason: it is folded from exactly what
    // the highlight pass reads — the selection type, the hovered index, and
    // each layer's (visible, drawsGeometry, selected) triple — so a future
    // input that reaches the pass is caught without an edit here, and one that
    // does not reach the pass correctly triggers no re-render. Notably it
    // covers item SELECTION too, which nothing else on this struct does.
    //
    // SHARED, not per-cell: which items are lit is view-independent. WHICH
    // cell the pointer is in is not, but the pointer only ever hovers one cell
    // and the highlight it produces is drawn in all of them, exactly like the
    // overlay terms.
    //
    // `= 0` is CTFE-constant and inert in --test, where the Single layout
    // never reaches the compare — the same neutrality argument as every term
    // above.
    ulong     itemHighlightKey = 0;

    // Task 1090 — the current-weight-map term.
    //
    // WHY NONE OF THE TERMS ABOVE CARRY IT. Which weight map the viewport
    // shows is SESSION state held by name (`weightmap_view`), not viewport
    // state, so `planActive`/`planBackdrop` cannot carry it — the map name is
    // deliberately kept out of `ViewportDisplay` (two cells must not be able
    // to show two different maps, and `resolveDrawPlan` is pure). Selecting a
    // different map moves no mesh version, no selection epoch and no upload
    // version either: `mesh.weightmap.select` is a `CmdFlags.UI` command that
    // writes one string. So without this field, switching maps changes what
    // the pass draws and changes no key — the seventh instance of the bug this
    // file already documents six times (`toolMat` above, the overlay terms,
    // `gpuUploadVer`, `overlayHot`, the display term, `imagePlaneKey`,
    // `itemHighlightKey`).
    //
    // A DIGEST, for the `imagePlaneKey` reason and not the display term's:
    // this is real state that is not plan-shaped, folded from exactly what the
    // pass reads (`currentWeightMapName()`, through the same accessor). Note
    // the display term's own block argues for terms DERIVED FROM WHAT THE PASS
    // READS over enumerated fields — which is this — while its specific advice
    // ("ride the resolved plan") does not apply, because the name is not in
    // the plan by design.
    //
    // SHARED, not per-cell: the map selection is global. WHICH cells draw the
    // weight style is per-cell, and `planActive` above already carries that.
    //
    // AND SAY THE HONEST THING: this term has NO LIVE EFFECT UNDER `--test`
    // and therefore no HTTP coverage at all. `app.d`'s cell loop short-
    // circuits to `needRender = (k == activeId)` in test mode and never
    // reaches the dirty-key compare — exactly as every sibling term's comment
    // says. It is covered by `tests/unit/dirty_key_weightmap_test.d`, at the
    // struct level, and that is the ceiling. Do not try to close the gap with
    // a cleverer HTTP case; it is a property of the harness.
    //
    // `= 0` is CTFE-constant and inert in --test — the same neutrality
    // argument as every term above.
    ulong     weightMapKey = 0;
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

/// Which cells the N-cell FBO loop re-renders under `--test` (task 1650).
///
/// `--test` used to render the ACTIVE cell and nothing else. Under the Single
/// layout invariant that is every live cell, so the rule was invisible — but a
/// test that switches to Quad with `viewport.layout` got three cells whose FBO
/// was never filled. That is a silent-pass trap for `/api/viewport/probe`
/// (documented at its own declaration in http_server.d), and worse, it made
/// the whole `OverlayMode.Visual` replica path UNREACHABLE from the test lane:
/// a check on it could not come out differently, whatever the code did.
///
/// So the rule is now "the active cell, plus every cell of a MULTI-cell
/// layout". Single layout ⇒ `cellCount == 1` ⇒ the answer is `k == activeId`
/// exactly as before, and every test that never touches `viewport.layout` is
/// byte-identical. A test opts in by the very act that makes the extra cells
/// worth rendering.
///
/// Interactive mode does not consult this — it renders on the per-cell dirty
/// key, which already visits every cell.
bool testRendersCell(int k, int activeId, int cellCount) {
    return k == activeId || cellCount > 1;
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

    /// The overlay-draw mode the N-cell loop RESOLVED for this cell on the
    /// last frame that considered it (task 1650). Stamped as an `int` rather
    /// than an `OverlayMode` on purpose: the enum lives in `editor_app.d`,
    /// which already imports THIS module, and a back-edge from here would
    /// close an import cycle. `editor_app.OverlayMode` is what the value
    /// means; `/api/viewport/display` casts it back.
    ///
    /// WHY THIS IS RECORDED AND NOT RE-DERIVED. `/api/viewport/display` is
    /// the endpoint a multi-cell overlay test asserts on, and the defect task
    /// 1650 fixed lived at the loop's CALL SITE, not inside the resolver — a
    /// dump that called the resolver itself would keep reporting `Visual`
    /// while the loop, gated by something the dump never sees, drew nothing.
    /// That failure was reproduced deliberately: with the pre-fix type
    /// enumeration restored at the call site, a re-deriving dump still said
    /// `Visual` for all three non-owner cells and only the pixel arm noticed.
    /// So the loop stamps what it decided and the dump reads the stamp.
    ///
    /// Written for every cell the loop CONSIDERS, before the dirty-key skip —
    /// the decision is made whether or not the cell then renders.
    int lastOverlayMode = 0;   // == OverlayMode.None

    // Task 0559 — this cell's display state (surface style, wireframe
    // overlay, backdrop representation), for BOTH activity states.
    //
    // The FIRST per-cell render input beyond the camera and the FBO size:
    // everything else the renderer branches on is either global (edit mode,
    // selection) or derived from the shared frame. It is defaulted to today's
    // exact behaviour, so a cell that is never touched renders as it always
    // did.
    ViewportDisplay display;

    // Task 0594 — PROVENANCE: has this cell's display style been chosen by
    // somebody, rather than merely inherited from the shipped default?
    //
    // Deliberately NOT part of `ViewportDisplay`: it is not a render input,
    // and `display_state.d`'s standing rule is that the renderer sees only
    // what `DrawPlan` describes. A field there would eventually be read by a
    // pass.
    //
    // What it protects: `applyLayout` seeds ortho cells with the wireframe
    // template (`shippedDisplayFor`). Without this bit, a user who sets cell 0
    // to Shaded and then switches Quad -> Single -> Quad silently loses it,
    // and a restored preference would be overwritten by the template on the
    // first layout switch of the session. Set by the `viewport.display*`
    // commands and by the preference restore; cleared only by a full reset.
    bool displayUserSet = false;

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
                                    camera.orientation);
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

    /// Task 0223 (quad cross splitter): user-adjustable cell split ratios.
    /// `hRatio` places the VERTICAL divider at `x = rx + hRatio*rw` — this
    /// is the divider seen in SplitH (left|right) and Quad (both rows).
    /// `vRatio` places the HORIZONTAL divider at `y = ry + vRatio*rh` — seen
    /// in SplitV (top/bottom) and Quad (both columns). Naming mirrors the
    /// AXIS the ratio controls, not the preset name (see cellRectsForRatios'
    /// doc comment for the naming-trap explanation). Defaults reproduce the
    /// existing 0.5 halving exactly (see the byte-neutrality unittest below).
    float        hRatio = 0.5f;
    float        vRatio = 0.5f;

    /// crossDrag: which cross-splitter arm currently owns the drag gesture.
    /// -1 = idle, 0 = V (vertical/hRatio) arm, 1 = H (horizontal/vRatio) arm.
    /// There is no separate "center" arm: a drag that engaged inside the
    /// intersection zone sets `crossBothAxes` so the owning arm drives BOTH
    /// ratios. The owning arm is the one whose InvisibleButton is active, so
    /// exactly one arm ever runs the update/release logic. Drives the ratio
    /// update in the app-loop cross-widget block (source/app.d).
    int          crossDrag = -1;
    bool         crossBothAxes = false;

    /// Task 0223: one-shot "re-front the cross-splitter arm windows" request,
    /// raised by applyLayout on every layout change and consumed by the
    /// cross-widget block (source/app.d) on the next frame. A layout switch
    /// reactivates hidden cells, which — lacking NoFocusOnAppearing — call
    /// FocusWindow as they reappear and jump ABOVE the arm overlay windows,
    /// stealing the arms' InvisibleButton hover so the splitter stops
    /// resizing. The widget answers this flag by explicitly SetWindowFocus-ing
    /// both arms (submitted after the cells) so they return to the top; it is
    /// a one-shot so steady-state layouts have no per-frame focus churn.
    bool         crossNeedsRefocus = false;

    /// Cross-widget drag anchor (source/app.d's per-frame widget block):
    /// the widget is now built from per-arm ImGui InvisibleButtons inside
    /// dedicated thin overlay windows (so the popup layer blocks its hover
    /// natively — see the widget block in source/app.d). The drag motion is
    /// driven by ImGui's cumulative GetMouseDragDelta(), so on the frame a
    /// drag engages we snapshot the ratio the divider started at; each frame
    /// the live ratio = start + delta/extent. No raw-SDL mouse poll is used.
    float        crossStartHRatio = 0.5f;
    float        crossStartVRatio = 0.5f;

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
    ///
    /// Task 0612 Stage 1 — the image-plane pixel cache is torn down here too.
    /// It is not per-cell, so this is not the obvious home; it is the right
    /// one because this is the app's single all-GL-objects teardown site
    /// (`app.d`'s `scope(exit) vpm.shutdown()`), and a GL owner with a
    /// lifetime longer than a frame that is NOT reclaimed here would be the
    /// only one. `ImagePixelCache.shutdown()` is idempotent and safe with no
    /// GL context, exactly like `ViewportFbo.destroy()` beside it.
    void shutdown() {
        foreach (v; views[]) {
            if (v.gpuSel !is null) {
                v.gpuSel.destroy();
                v.gpuSel = null;
            }
            v.fbo.destroy();
        }
        imagePixelCache().shutdown();
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

    /// Task 0223: ratio-driven cell rects for the custom cross-splitter.
    /// Mirrors `cellRectsFor` above but the split fraction is a caller-
    /// supplied ratio instead of a hardcoded 0.5 — `cellRectsFor` itself is
    /// left BYTE-FOR-BYTE UNCHANGED (it remains the sole `--test` rect
    /// authority; not touching it is the cheapest byte-neutrality guarantee).
    ///
    /// NAMING TRAP (verify before touching call sites): `LayoutPreset.SplitH`
    /// / `SplitV` are named for the pane ARRANGEMENT, which is the OPPOSITE
    /// of the divider ORIENTATION.  SplitH gives a left|right pane pair, so
    /// its divider is a VERTICAL line — driven by `hR`.  SplitV gives a
    /// top/bottom pane pair, so its divider is a HORIZONTAL line — driven by
    /// `vR`.  Quad uses both.  Get this backwards and the wrong widget moves
    /// the wrong divider; see the mapping unittest below.
    ///
    /// `hR`/`vR` are fractions in (0,1); NOT clamped here (this function
    /// stays pure / side-effect-free) — the caller (the drag site) is
    /// responsible for clamping the stored ratio to a sane range before it
    /// ever reaches this function.
    ///
    /// Uses TRUNCATING `cast(int)`, not `round` — `cast(int)(rw*0.5f) ==
    /// rw/2` for every int `rw` (even AND odd), so at the default 0.5/0.5
    /// this is byte-identical to `cellRectsFor`'s `rw/2` integer division.
    /// `round` would diverge on odd dimensions — do not switch to it.
    static void cellRectsForRatios(LayoutPreset p,
                              int rx, int ry, int rw, int rh,
                              float hR, float vR,
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
                // Vertical divider, driven by hRatio.
                int hw = cast(int)(rw * hR);
                xs[0] = rx;      ys[0] = ry; ws[0] = hw;      hs[0] = rh;
                xs[1] = rx + hw; ys[1] = ry; ws[1] = rw - hw; hs[1] = rh;
                break;
            }
            case LayoutPreset.SplitV: {
                // Horizontal divider, driven by vRatio.
                int hh = cast(int)(rh * vR);
                xs[0] = rx; ys[0] = ry;      ws[0] = rw; hs[0] = hh;
                xs[1] = rx; ys[1] = ry + hh; ws[1] = rw; hs[1] = rh - hh;
                break;
            }
            case LayoutPreset.Quad: {
                int hw = cast(int)(rw * hR), hh = cast(int)(rh * vR);
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

        // Task 0594: seed each cell's display style from the layout template.
        //
        // Placed HERE, after the Quad block, because that block is what sets
        // `projKind` — seeding earlier would read the previous layout's
        // projections and give a fresh Quad four shaded cells.
        seedShippedDisplay();

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
        // Task 0223: a layout switch tears down / re-seeds the cross-splitter
        // arm windows, so any in-flight cross-drag gesture (crossDrag>=0) can
        // never see its own InvisibleButton release. Clear the drag state here
        // (applyLayout is the sole layout-change entry) so a drag interrupted
        // by a layout switch leaves no latched owner that would swallow the
        // next arm's press in the re-entered layout.
        crossDrag     = -1;
        crossBothAxes = false;
        // Ask the cross-widget to re-front its arm windows next frame (see the
        // field doc): a layout switch reappears cells that would otherwise
        // bury the arms and steal their hover.
        crossNeedsRefocus = true;
        if (activeId  >= cellCount) activeId  = cellCount - 1;
        if (hoveredId >= cellCount) hoveredId = cellCount - 1;
        if (masterId  >= cellCount) masterId  = 0;

        dirtyAll();
        layoutDirty = true;
    }

    /// Seed every cell's ACTIVE display state from the shipped layout
    /// template — orthographic cells lines-only, perspective cells shaded
    /// (task 0594, `display_state.shippedDisplayFor`).
    ///
    /// A DEFAULT, WITH TWO THINGS IT MUST NOT DO:
    ///
    ///  1. It must not overwrite a chosen style. `displayUserSet` is set by
    ///     the `viewport.display*` commands and by the preference restore, and
    ///     a cell carrying it is skipped entirely. Layout switching is a
    ///     routine action (Quad -> Single -> Quad); losing a style to it would
    ///     be exactly the "a default silently overwrote a saved choice"
    ///     defect.
    ///  2. It must not fire on a camera change. This is called from
    ///     `applyLayout` only — where a layout ESTABLISHES its cells — and
    ///     deliberately NOT from `applyCellViewPreset`. Swinging an existing
    ///     cell from Perspective to Top changes the camera, not the styling;
    ///     the reference ships these values as view TEMPLATES, which are the
    ///     initial content of a viewport rather than a rule re-evaluated on
    ///     every camera move.
    ///
    /// All FOUR cells are seeded, not just the live ones, for the same reason
    /// the preference restore covers all four: `views` is a fixed array that
    /// is never reallocated, so a cell that Single does not show is the same
    /// object Quad will show later.
    ///
    /// Only the ACTIVE side is seeded. The backdrop side is still resolved
    /// from `SameAsActive` and has no template of its own; giving it one is a
    /// separate defaults decision.
    void seedShippedDisplay() {
        import display_state : shippedDisplayFor;
        foreach (k; 0..4) {
            if (views[k].displayUserSet) continue;
            views[k].display.active = shippedDisplayFor(views[k].isOrtho());
            views[k].dirty = true;
        }
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
            // Task 0594: drop the "somebody chose this style" bit too. It is
            // sticky BY DESIGN — that is the whole point of it — so a reset
            // that left it set would let one test's `viewport.displayStyle`
            // pin every later test in the same shared --test instance to that
            // style, and the shipped-default assertions would pass or fail
            // depending on slice order. Cleared BEFORE applyLayout, which is
            // what re-seeds the template.
            views[k].displayUserSet = false;
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

    /// Focus-follows-mouse: make `activeId` track `hoveredId` on every
    /// positioned mouse event (motion/wheel/down/up), not just on click —
    /// so key-driven per-cell commands (fit, view presets, ind*/master,
    /// snap, ...) that read `views[activeId]` act on whichever cell the
    /// mouse is over, matching key-based dispatch conventions where the
    /// pointer's cell is implicitly the target. Call AFTER `hoveredId` has
    /// been refreshed via `viewportUnderCursor()` for the current event.
    ///
    /// Two guards:
    ///  - Pinned during an active gesture (`dragOriginId >= 0`): the
    ///    per-cell picking caches (vertexCache/faceCache/edgeCache/gpuSelect,
    ///    all indexed by activeId) must not switch cells mid-drag.
    ///  - No-op when the cursor is outside every cell (`hoveredId < 0`,
    ///    e.g. over a docked panel) — sticky-last, activeId stays put
    ///    rather than snapping to an arbitrary cell.
    void followHover() {
        if (dragOriginId < 0 && hoveredId >= 0)
            activeId = hoveredId;
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
        Orientation o;
        resolveFollow(id, focus, distance, o);
        float r;
        o.toAngles(az, el, r);
    }

    /// `resolveFollow` returning the whole ROTATION. The entire orientation
    /// rides on `indRotate` — heading, pitch and bank alike are one rotation,
    /// so a cell that follows its master's orbit follows all of it; splitting
    /// them would let a linked pair render mutually rotated horizons while
    /// claiming to share a rotation.
    void resolveFollow(int id,
                       out Vec3 focus, out float distance,
                       out Orientation orient) const {
        auto f   = views[id];
        int  mid = groupMasterOf(id);
        auto m   = views[mid];
        focus    = f.indCenter ? f.camera.focus       : m.camera.focus;
        distance = f.indScale  ? f.camera.distance    : m.camera.distance;
        orient   = f.indRotate ? f.camera.orientation : m.camera.orientation;
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
        Vec3 fo; float di; Orientation ro;
        resolveFollow(id, fo, di, ro);
        return views[id].camera.viewportWith(fo, di, ro);
    }

    /// Resolved snapshot for the currently active cell.
    Viewport activeSnapshot() { return resolvedSnapshot(activeId); }

    /// Resolved snapshot for the drag-origin cell (or active if no gesture).
    Viewport originSnapshot() {
        return resolvedSnapshot(dragOriginId >= 0 ? dragOriginId : activeId);
    }

    /// The cell that owns the CURRENT pointer input, and with it this frame's
    /// overlay: the drag-origin cell during a gesture, else the HOVERED cell,
    /// else the active cell.
    ///
    /// The `cellCount > 1` guard makes the hovered term inert in `--test`
    /// (Single layout invariant), so the answer there is `activeId` — the
    /// pre-task-0209 gate exactly.
    ///
    /// Task 1650: this formula had TWO copies — here (as `inputSnapshot`'s
    /// body) and again in app.d's N-cell FBO loop as a local named
    /// `overlayOwner`. They agreed, but nothing made them: the overlay owner
    /// and the input owner are the same cell BY DESIGN (the arbiter's hit-test
    /// runs where the cursor is), so they get one implementation.
    int overlayOwnerId() const {
        return dragOriginId >= 0 ? dragOriginId
             : (cellCount > 1 && hoveredId >= 0 ? hoveredId : activeId);
    }

    /// Resolved snapshot for the cell that owns the CURRENT pointer input.
    /// In Single layout (cellCount==1) this is identical to originSnapshot()
    /// (there is no second cell to hover), so `--test` stays byte-neutral.
    Viewport inputSnapshot() {
        return resolvedSnapshot(overlayOwnerId());
    }

    /// Return resolved camera JSON for cell `id`.  `const`, non-mutating — safe
    /// on any thread.  Eye is recomputed from the resolved inputs.
    string resolvedCameraJson(int id) const {
        Vec3 fo; float di; Orientation ro;
        resolveFollow(id, fo, di, ro);
        return views[id].camera.toJsonWith(fo, di, ro);
    }
}
