module tools.edit.vert_merge_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import drag : haulWorldPerPixel, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import perf_probe : g_perf, Cat;

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
    // Frozen at drag-start — the LOCAL length one pixel is worth at the
    // selection centroid, item transform included (task 0645).
    float localPerPixel;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
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

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    public override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
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
        // average:true — survivor at per-cluster centroid, matching the
        // vert.merge command path (source/commands/mesh/vert_merge.d).
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
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
        // Anchored where the geometry is DRAWN, and converted back into the
        // LOCAL units the merge threshold means (task 0645). A threshold is a
        // distance with no direction, so the conversion is the declared mean —
        // see `OverlaySpace.meanWorldPerLocal`.
        const auto os = OverlaySpace.ofPrimary();
        localPerPixel = haulWorldPerPixel(os.pos(mesh.selectionCentroidVertices()), cachedVp)
                      / os.meanWorldPerLocal();
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
        // The previous pixel comes from the cooked gesture, not from this
        // tool's own pair. Same integer subtraction, sourced one level up;
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        float dyPixels = cast(float)(prevMY - e.y);
        dist_ = dragBaseDist + dyPixels * localPerPixel;
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
    // Revert to the pre-merge cage + selection, then re-run the kernel from
    // the current `dist_`. Per-tick re-evaluate: WRITE the param + RE-RUN,
    // never incrementally mutate the already-welded mesh.
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (!mesh.hasAnySelectedVertices()) {
            built = false;
            refreshCaches();
            return;
        }
        double epsSq = cast(double)dist_ * cast(double)dist_;
        // average:true — survivor at per-cluster centroid, matching the
        // vert.merge command path (source/commands/mesh/vert_merge.d).
        size_t n = mesh.weldVerticesByMask(mesh.selectedVertices, epsSq, true);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Merge Vertices");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragging = false;
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }
}
