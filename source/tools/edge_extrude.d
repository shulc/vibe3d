module tools.edge_extrude;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : BoxHandler, gizmoSize;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.edge_extrude_edit : MeshEdgeExtrudeEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

import std.math : abs;

/// The interactive tool reuses the dedicated MeshEdgeExtrudeEdit record
/// command (a before/after MeshSnapshot pair) — analogous to how BoxTool
/// reuses MeshBevelEdit via `alias BoxEditFactory = MeshBevelEdit delegate();`.
/// A dedicated class (rather than reusing the bevel edit) keeps the undo label
/// reading "Edge Extrude".
alias EdgeExtrudeEditFactory = MeshEdgeExtrudeEdit delegate();

// ---------------------------------------------------------------------------
// EdgeExtrudeTool — interactive Edge Extrude (factory id `edge.extrude`).
//
// Modelled on BoxTool / PenTool (NOT TransformTool): topology-creating tools
// own their undo plumbing and commit ONE before/after MeshSnapshot record
// command at deactivate. TransformTool's vertex-position-delta MeshVertexEdit
// cannot undo added verts/faces, so it is unusable here.
//
// Session model (the BoxTool commit pattern):
//   activate()  — capture `before` = MeshSnapshot.capture(mesh) (geometry +
//                 selection); reset extrude/width to 0 (identity ⇒ no-op).
//   drag        — restore `before` (re-establishes the original cage AND the
//                 original edge selection), recompute the (extrude,width) pair
//                 from the accumulated screen-space mouse delta, re-run
//                 Mesh.extrudeEdgesByMask on the restored selection, then
//                 gpu.upload + cache refresh. The kernel is cheap (O(selected
//                 edges + their faces)), so a per-frame revert+reapply is fine
//                 — the same revert/reapply pattern bevel_edit.d documents.
//   deactivate() — if any geometry was built (extrude or width nonzero),
//                 capture `after`, build a MeshEdgeExtrudeEdit via the injected
//                 factory, setSnapshots(before, after, "Edge Extrude"), and push
//                 it onto history as ONE undo step.
//
// Interaction mapping (v1, per doc/edge_extrude_plan.md §4): a simple 2-axis
// screen-space drag — vertical mouse delta (−dy, up = positive) → Extrude,
// horizontal mouse delta (dx) → Width — each scaled by a constant px→world
// factor. A draw-only crosshair marker sits at the selection centroid; it is
// intentionally NOT registered with a ToolHandles arbiter, so it stays
// draw-only and never highlights (per the plan). A proper single-axis arrow
// gizmo can land as a follow-up.
//
// The headless path (`tool.set edge.extrude on; tool.attr edge.extrude
// extrude <v>; tool.attr edge.extrude width <v>; tool.doApply`) drives the
// SAME kernel through applyHeadless(); ToolDoApplyCommand wraps it with a
// snapshot pair for undo (so applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class EdgeExtrudeTool : Tool {
private:
    Mesh*            mesh;
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    // Caches refreshed after the per-drag revert+reapply (drag mutates the
    // mesh outside setActiveTool's bulk refresh).
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory         history;
    EdgeExtrudeEditFactory factory;

    // Parameters — exposed via params() so both the Tool Properties panel
    // and the headless tool.attr path write into them.
    float extrude_ = 0.0f;
    float width_   = 0.0f;

    // Interactive session state.
    bool          active;          // between activate() and deactivate()
    bool          built;           // true once a nonzero extrude/width built topology
    MeshSnapshot  before;          // captured at activate() (geometry + selection)
    Viewport      cachedVp;        // last frame's viewport (for the centroid marker)

    // Drag state — accumulated screen-space delta since LMB-down.
    bool  dragging;
    int   dragStartMX, dragStartMY;
    float dragBaseExtrude, dragBaseWidth;

    // Screen pixels → world units for the drag mapping (v1 constant).
    enum float PX_TO_WORLD = 0.01f;

    BoxHandler centroidMarker;      // draw-only; never registered with an arbiter

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
        centroidMarker = new BoxHandler(Vec3(0, 0, 0), Vec3(0.9f, 0.6f, 0.1f));
    }

    void destroy() {
        if (centroidMarker !is null) centroidMarker.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    /// commitEdit() is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, EdgeExtrudeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Edge Extrude"; }

    // Edge Extrude only makes sense on an edge selection.
    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        return [
            Param.float_("extrude", "Extrude", &extrude_, 0.0f),
            Param.float_("width",   "Width",   &width_,   0.0f),
        ];
    }

    override void activate() {
        active   = true;
        built    = false;
        dragging = false;
        extrude_ = 0.0f;
        width_   = 0.0f;
        // Snapshot the cage + selection at the start of the session. The
        // per-drag revert+reapply restores from here; the commit pairs it
        // with the final `after`.
        before = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // Commit one undo step iff a nonzero param actually built topology.
        if (active && built && (extrude_ != 0.0f || width_ != 0.0f))
            commitEdit();
        active   = false;
        built    = false;
        dragging = false;
    }

    // A parameter changed. Two callers, distinguished by `interactiveParamEdit`
    // (set by PropertyPanel only):
    //   - Interactive Tool Properties edit → rebuild the live preview from the
    //     clean cage (the same revert+reapply the drag path uses), so the
    //     panel's Extrude/Width sliders update the mesh immediately.
    //   - Headless `tool.attr ...; tool.doApply` → leave the mesh untouched.
    //     applyHeadless() runs the kernel once from the clean cage; mutating
    //     the mesh on every attr write would double-apply AND poison
    //     ToolDoApplyCommand's pre-snapshot (captured AFTER the attr writes).
    override void onParamChanged(string name) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the kernel on the current edge
    // selection. MUST NOT snapshot — ToolDoApplyCommand wraps with undo.
    // -----------------------------------------------------------------------
    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live drag previously built preview topology, restore the clean
        // cage first so the kernel applies exactly once (idempotent). In the
        // pure headless flow (no drag) `before` == the current mesh, so this
        // is a no-op and ToolDoApplyCommand's pre-snapshot stays clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.edges.length == 0) return false;
        if (extrude_ == 0.0f && width_ == 0.0f) return true;   // no-op success
        auto mask = currentMask();
        size_t n = mesh.extrudeEdgesByMask(mask, extrude_, width_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // Interactive drag: vertical delta → Extrude, horizontal delta → Width.
    // -----------------------------------------------------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            // Cancel: drop any built topology, restore the original cage.
            before.restore(*mesh);
            refreshCaches();
            extrude_ = 0.0f;
            width_   = 0.0f;
            built    = false;
            dragging = false;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0) return false;

        dragging        = true;
        dragStartMX     = e.x;
        dragStartMY     = e.y;
        dragBaseExtrude = extrude_;
        dragBaseWidth   = width_;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        // Up on screen (smaller y) extrudes outward (positive). Right (larger
        // x) widens the inset.
        float dy = cast(float)(e.y - dragStartMY);
        float dx = cast(float)(e.x - dragStartMX);
        extrude_ = dragBaseExtrude + (-dy) * PX_TO_WORLD;
        width_   = dragBaseWidth   + ( dx) * PX_TO_WORLD;
        rebuildPreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        cachedVp = vp;
        // Draw-only centroid crosshair at the selection centroid. Never
        // registered with an arbiter — stays draw-only and never highlights.
        Vec3 c;
        if (selectionCentroid(c)) {
            centroidMarker.pos  = c;
            centroidMarker.size = gizmoSize(c, vp, 0.05f);
            centroidMarker.draw(shader, vp);
        }
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching the
    // mesh.delete / mesh.edge_extrude convention).
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Edges)) {
            auto m = new bool[](mesh.edges.length);
            m[] = true;
            return m;
        }
        return mesh.selectedEdges;
    }

    // Revert to the pre-extrude cage + selection, then rebuild from the
    // current extrude/width. Identity params leave the mesh restored (no-op).
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (extrude_ == 0.0f && width_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.extrudeEdgesByMask(mask, extrude_, width_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Extrude");
        history.record(cmd);
    }

    void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }

    // Centroid of the currently selected edges' endpoints (or the whole-mesh
    // centroid when nothing is selected). False if the mesh is empty.
    bool selectionCentroid(out Vec3 c) {
        Vec3 sum = Vec3(0, 0, 0);
        size_t count;
        auto sel = mesh.selectedEdges;
        bool any;
        foreach (i; 0 .. mesh.edges.length)
            if (i < sel.length && sel[i]) { any = true; break; }
        if (any) {
            foreach (i; 0 .. mesh.edges.length) {
                if (i >= sel.length || !sel[i]) continue;
                auto ed = mesh.edges[i];
                sum.x += mesh.vertices[ed[0]].x + mesh.vertices[ed[1]].x;
                sum.y += mesh.vertices[ed[0]].y + mesh.vertices[ed[1]].y;
                sum.z += mesh.vertices[ed[0]].z + mesh.vertices[ed[1]].z;
                count += 2;
            }
        } else {
            foreach (v; mesh.vertices) {
                sum.x += v.x; sum.y += v.y; sum.z += v.z;
                ++count;
            }
        }
        if (count == 0) return false;
        c = Vec3(sum.x / count, sum.y / count, sum.z / count);
        return true;
    }
}
