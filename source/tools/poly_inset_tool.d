module tools.poly_inset_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : gizmoSize, getGizmoPixels;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

// Reuses the generic before/after-snapshot record command (MeshBevelEdit),
// same as tools/mirror.d and tools/tack.d — see those modules' comments.
// The undo LABEL is set per-session via setSnapshots(..., "Inset"), so the
// history entry reads "Inset" even though the underlying command class name
// stays "mesh.bevel_edit".
alias PolyInsetEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// PolyInsetTool — interactive Polygon Inset (factory id `mesh.polyInsetTool`,
// task 0359 promotion of the one-shot `mesh.poly_inset` command).
//
// Grounded in the captured toolcard (toolcards/inset/ in the private spec
// tree — not reproduced here beyond the geometry/behavior facts baked into
// mesh.insetFacesByMask):
//   - ONE attribute (`inset`, world units, default 0.0).
//   - Always per-polygon (no group/island toggle exists to diverge from).
//   - Sign law: positive shrinks (toward centroid), negative grows (away).
//   - `inset == 0` is NOT a no-op — the kernel always performs the split.
//   - NO drawn gizmo/handle in the viewport (confirmed by capture screenshots
//     at idle/hover/drag) — draw() is intentionally empty. A plain click+drag
//     ANYWHERE over the viewport (while the tool is active, outside camera-nav
//     modifiers) drives the sole `inset` value: a generic, undecorated
//     "numeric haul" (the same un-rigged mechanism poly.bevel's Shift/Inset
//     rails and poly.smshift's Shift use, just without their extra arrow
//     graphic — see toolcard `gestures[1]`).
//
// Drag law (NOT captured — flagged as an open TODO in the toolcard's
// viewport-drag finding): this implementation maps vertical screen motion
// (drag UP = increase inset, matching this codebase's other haul tools'
// "up/out = positive" convention) to world units via the same
// perspective/zoom-correct `gizmoSize` scale poly_bevel.d uses for its arrow
// handles, anchored at the selected faces' centroid. If a captured
// drag-distance→value law ever lands, only `motionHaul`'s scale factor needs
// to change — the rest of the session/undo plumbing is unaffected.
//
// Session lifecycle mirrors PolyBevelTool (its closest sibling: one
// attribute, topology-creating, per-face independent): activate() snapshots
// the clean cage; a drag/param-edit reverts to that cage and RE-RUNS the
// kernel from the current `inset_` (rebuildPreview — never vertex-transforms
// the already-split ridge); deactivate() commits ONE undo entry if any
// topology was built. This does NOT reproduce the reference editor's
// per-release auto-chain (each haul-release committing its own step, so a
// second drag insets the FRESH inner faces) — that would need a materially
// different commit lifecycle than every other topology tool in this
// codebase uses, and the toolcard does not treat it as a load-bearing
// requirement. Deferred; see task 0359 Лог.
// ---------------------------------------------------------------------------
class PolyInsetTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory         history;
    PolyInsetEditFactory   factory;

    // Reference default (task 0359 toolcard: bit-exact 0.0). Deliberately
    // NOT changed to a safe non-zero value like the one-shot command
    // (commands/mesh/poly_inset.d) — this 0.0 is only ever a TRANSIENT
    // starting value: activate()/reinitSession() do not build a preview
    // (see reinitSession's doc-comment), so a session that ends without any
    // drag/param-edit/doApply never manufactures the degenerate zero-area
    // ring. Geometry is only ever produced once `inset_` has actually been
    // written to something (a drag, a panel edit, or an explicit
    // tool.attr), at which point the caller owns whatever value they chose.
    float inset_ = 0.0f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    // Haul drag state. No drawn handle to hit-test — any LMB press (outside
    // camera-nav modifiers) begins the haul directly.
    bool  dragging;
    int   dragLastMX, dragLastMY;
    float dragBaseInset;
    float worldPerPixel;   // frozen at drag-start (see anchorForHaul)

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, PolyInsetEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Polygon Inset"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.0f),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragging = false;
        inset_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built) commitEdit();
        active   = false;
        built    = false;
        dragging = false;
    }

    public override bool hasUncommittedEdit() const {
        return active && built;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // Headless apply (tool.doApply) — the Post-Mode path a panel numeric
    // edit + Apply button drives (toolcard `gestures[0]`, "panel-apply").
    // MUST NOT snapshot — ToolDoApplyCommand wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        auto mask = currentMask();
        size_t n = mesh.insetFacesByMask(mask, inset_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera nav
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        // No drawn handle to hit-test (task 0359 toolcard: confirmed no
        // gizmo graphic at idle/hover/drag) — any qualifying click begins
        // the generic haul directly, anchored at the selected faces'
        // centroid (empty selection ⇒ whole-mesh centroid, matching
        // currentMask's empty-selection convention).
        dragging       = true;
        dragLastMX     = e.x;
        dragLastMY     = e.y;
        dragBaseInset  = inset_;
        worldPerPixel  = haulWorldPerPixel();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        // Vertical screen delta → world inset delta. Drag UP (screen Y
        // decreases) increases inset. See the class doc-comment for why this
        // particular law was picked (drag calibration is uncaptured).
        float dyPixels = cast(float)(dragLastMY - e.y);
        inset_ = dragBaseInset + dyPixels * worldPerPixel;
        dragLastMX = e.x;
        dragLastMY = e.y;
        rebuildPreview();
        return true;
    }

    // No drawn gizmo/handle (task 0359 toolcard: confirmed absent at idle/
    // hover/drag in every captured screenshot) — intentionally empty.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching
    // the mesh.poly_inset command convention).
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Polygons)) {
            auto m = new bool[](mesh.faces.length);
            m[] = true;
            return m;
        }
        return mesh.selectedFaces;
    }

    // World units per screen pixel at the selected faces' centroid — the
    // same perspective/zoom-correct scale poly_bevel.d uses for its arrow
    // handles (gizmoSize(pos, vp, 1.0) is the world length of a
    // getGizmoPixels()-pixel span at `pos`).
    float haulWorldPerPixel() {
        Vec3 anchor = Vec3(0, 0, 0);
        bool any = mesh.hasAnySelectedFaces();
        int cnt = 0;
        foreach (fi; 0 .. mesh.faces.length) {
            if (any && !mesh.isFaceSelected(fi)) continue;
            anchor = anchor + mesh.faceCentroid(cast(uint)fi);
            ++cnt;
        }
        if (cnt > 0) anchor = anchor * (1.0f / cast(float)cnt);
        float px = getGizmoPixels();
        if (px < 1e-6f) px = 90.0f;
        return gizmoSize(anchor, cachedVp, 1.0f) / px;
    }

    // Revert to the pre-inset cage + selection, then re-run the kernel from
    // the current `inset_`. This is the per-tick re-evaluate: WRITE the
    // param + RE-RUN, never vertex-transform the post-inset ridge.
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        auto mask = currentMask();
        size_t n = mesh.insetFacesByMask(mask, inset_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Inset");
        history.record(cmd);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragging = false;
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
