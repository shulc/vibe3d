module tools.alignment.clone_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import drag : planeDragDelta;
import shader : Shader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

alias MeshCloneEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// CloneTool — interactive drag-clone (factory id `mesh.clone`).
//
// One drag gesture = one copy of the selected faces offset by the screen drag
// delta, recorded as a single undo entry (MeshSessionEdit before/after pair).
//
// Behavior:
//   - On activate: capture a baseline MeshSnapshot from the current mesh.
//   - LMB drag start: require a non-empty face selection (no-op otherwise).
//     Record the anchor pixel and the selection centroid in world space.
//   - Each motion frame: restore the baseline → arrayFaces(mask,2,delta,0)
//     where delta is the ABSOLUTE world displacement from the anchor to the
//     current mouse position (never accumulate across frames).
//   - LMB release: commit one MeshSessionEdit entry; recapture baseline from
//     the post-clone state so the next drag is independent.
//   - Deactivate: if a preview is live, commit first.
//   - RMB: cancel live preview (restore baseline without recording).
//
// Gated to Polygons edit mode (duplicateSelectedFaces / arrayFaces are
// face-selection operations; non-Polygons drag is a no-op).
//
// Drag→offset feel is a vibe3d-divergence (no reference tool-model exists;
// we use our own planeDragDelta on the most-facing screen plane).  The
// analytic success bar is: original + exactly one offset copy; original
// verts byte-unchanged; single undo entry per gesture.
// ---------------------------------------------------------------------------
class CloneTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }

    GpuMesh*         gpu;
    EditMode*        editMode;
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory       history;
    MeshCloneEditFactory factory;

    bool         active;
    bool         built;       // true when a preview is baked into the live mesh
    bool         dragging;    // true between LMB-down and LMB-up
    MeshSnapshot before;      // session baseline (recaptured after each commit)

    int  anchorMX, anchorMY;  // drag-start pixel coords
    Vec3 anchorWorld;          // world-space drag anchor (selection centroid)
    Viewport cachedVp;         // last viewport from draw(), used by drag math

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, MeshCloneEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Clone"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override void activate() {
        active   = true;
        built    = false;
        dragging = false;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built) commitEdit();
        active   = false;
        built    = false;
        dragging = false;
    }

    override bool hasUncommittedEdit() const {
        return active && built;
    }

    override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    override void resyncSession() {
        if (!active) return;
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragging = false;
        before   = MeshSnapshot.capture(*mesh);
        refreshCaches();
    }

    override void evaluate() {}

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;

        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        // Gated to Polygons mode.
        if (*editMode != EditMode.Polygons) return false;

        // Require a non-empty face selection — drag with nothing selected is
        // a deliberate no-op (must not silently clone the whole mesh).
        if (!mesh.hasAnySelectedFaces()) return false;

        anchorMX    = e.x;
        anchorMY    = e.y;
        anchorWorld = mesh.selectionCentroidFaces();
        dragging    = true;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        if (built) {
            commitEdit();
            built  = false;
            before = MeshSnapshot.capture(*mesh);  // new baseline for next drag
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        bool skip;
        // ABSOLUTE delta from drag-start anchor to current pixel, projected
        // onto the most-facing screen plane (dragAxis=3).
        Vec3 delta = planeDragDelta(e.x, e.y, anchorMX, anchorMY,
                                    3, anchorWorld, cachedVp, skip);
        if (!skip) rebuildPreview(delta);
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // No gizmo arrows — the drag trace is the visual feedback.
    }

private:
    /// Restore baseline → place one offset copy at `delta`.
    /// Never accumulates: every frame is computed off the pristine `before`.
    void rebuildPreview(Vec3 delta) {
        if (!active) return;
        before.restore(*mesh);

        // Zero delta → no visible copy yet (skip to avoid a coincident face
        // at frame 0, though weld=0 would keep it; cosmetic only).
        if (delta.x == 0.0f && delta.y == 0.0f && delta.z == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }

        // Build mask from the restored face selection.
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) { built = false; refreshCaches(); return; }

        size_t n = mesh.arrayFaces(mask, 2, delta, 0.0f);  // weld=0 PINNED
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Clone");
        history.record(cmd);
    }

    void cancelLiveEdit() {
        if (built && before.filled) {
            before.restore(*mesh);
            refreshCaches();
        }
        built    = false;
        dragging = false;
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
