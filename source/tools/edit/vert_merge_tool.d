module tools.edit.vert_merge_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : gizmoSize, getGizmoPixels;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

// Reuses the generic before/after-snapshot record command (MeshSessionEdit),
// same as tools/poly_inset_tool.d / tools/mirror.d / tools/tack.d — see
// those modules' comments. The undo LABEL is set per-session via
// setSnapshots(..., "Merge Vertices").
alias VertMergeEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// VertexMergeTool — interactive Vertex Merge (factory id `vert.merge`,
// task 0360 promotion of the one-shot `vert.merge` command).
//
// Grounded in the captured toolcard (private spec tree — not reproduced
// here beyond the geometry/behavior facts baked into
// mesh.weldVerticesByMask, source/mesh.d — see that kernel's doc-comment
// for the full captured-law writeup):
//   - ONE attribute exposed on the interactive tool: `dist` (Distance,
//     world units, default 0.001 — bit-exact match to the pre-existing
//     one-shot command's own default, and to the reference's own live-
//     confirmed default). NO drawn gizmo/handle at idle/hover/drag — a
//     plain click+drag ANYWHERE over the viewport hauls the threshold
//     directly (the SAME undecorated "numeric haul" family as
//     mesh.polyInsetTool — see that tool's doc-comment).
//   - Threshold law: welds any two (or, transitively, more) SELECTED
//     vertices whose distance apart is <= dist (inclusive boundary,
//     confirmed at the exact grid-edge-length boundary of a captured
//     test mesh). mesh.weldVerticesByMask's own boundary check was fixed
//     to `<=` (from a strict `<`) to match — see its doc-comment for the
//     parity evidence and the still-open transitive/connected-component
//     clustering caveat this port did NOT fully resolve.
//   - The one-shot command's `range` auto/fixed toggle and the `keep`/
//     `morph` attributes are COMMAND-only in the reference (the captured
//     toolcard confirms them absent from the interactive tool's own
//     panel — only Distance/Keep/Morph appear there, and even Keep/Morph
//     have no vibe3d counterpart honored yet). This tool deliberately
//     does NOT expose `range`; it always runs the reference's "always a
//     plain Distance field" mode by calling `weldVerticesByMask` directly
//     rather than routing through the one-shot MeshVertMerge command
//     (which keeps its own `range`/`keep`/`morph` params for the
//     one-shot/menu path, untouched by this tool).
//
// Session lifecycle mirrors PolyInsetTool (one attribute, no drawn handle,
// generic viewport haul, topology-mutating via a shared MeshSessionEdit
// before/after snapshot).
// ---------------------------------------------------------------------------
class VertexMergeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory       history;
    VertMergeEditFactory factory;

    // Reference default (task 0360 toolcard: live-confirmed bit-exact
    // 1mm), matching vibe3d's pre-existing one-shot command default
    // (dist_ = 0.001f).
    float dist_ = 0.001f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    // Haul drag state. No drawn handle to hit-test — any LMB press
    // (outside camera-nav modifiers, with a live vertex selection) begins
    // the haul directly.
    bool  dragging;
    int   dragLastMX, dragLastMY;
    float dragBaseDist;
    float worldPerPixel;

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

    void setUndoBindings(CommandHistory h, VertMergeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Vertex Merge"; }

    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [
            Param.float_("dist", "Distance", &dist_, 0.001f).min(0.0f).fmt("%.4f"),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragging = false;
        dist_    = 0.001f;
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

    // Headless apply (tool.doApply) — MUST NOT snapshot; ToolDoApplyCommand
    // wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Vertices) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.vertices.length == 0) return false;
        if (!mesh.hasAnySelectedVertices()) return false;
        double epsSq = cast(double)dist_ * cast(double)dist_;
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq);
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
        if (*editMode != EditMode.Vertices) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // No drawn handle to hit-test (task 0360 toolcard: confirmed no
        // gizmo graphic at idle/hover/drag) — any qualifying click begins
        // the generic haul directly, anchored at the selected vertices'
        // centroid.
        dragging      = true;
        dragLastMX    = e.x;
        dragLastMY    = e.y;
        dragBaseDist  = dist_;
        worldPerPixel = haulWorldPerPixel();
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
        // Vertical screen delta -> world distance delta. Drag UP (screen Y
        // decreases) increases the threshold, matching this codebase's
        // other haul tools' "up/out = positive" convention (see
        // PolyInsetTool's identical drag law + rationale).
        float dyPixels = cast(float)(dragLastMY - e.y);
        dist_ = dragBaseDist + dyPixels * worldPerPixel;
        if (dist_ < 0.0f) dist_ = 0.0f;
        dragLastMX = e.x;
        dragLastMY = e.y;
        rebuildPreview();
        return true;
    }

    // No drawn gizmo/handle (task 0360 toolcard: confirmed absent at idle/
    // hover/drag in every captured screenshot) — intentionally empty.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    // World units per screen pixel at the selected vertices' centroid —
    // the same perspective/zoom-correct scale poly_bevel.d/poly_inset_tool.d
    // use for their handles/haul.
    float haulWorldPerPixel() {
        Vec3 anchor = mesh.selectionCentroidVertices();
        float px = getGizmoPixels();
        if (px < 1e-6f) px = 90.0f;
        return gizmoSize(anchor, cachedVp, 1.0f) / px;
    }

    // Revert to the pre-merge cage + selection, then re-run the kernel from
    // the current `dist_`. Per-tick re-evaluate: WRITE the param + RE-RUN,
    // never incrementally mutate the already-welded mesh.
    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (!mesh.hasAnySelectedVertices()) {
            built = false;
            refreshCaches();
            return;
        }
        double epsSq = cast(double)dist_ * cast(double)dist_;
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Merge Vertices");
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
