module tools.create.vertex_place;
import display_state : DrawPlan;

import bindbc.sdl;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.create.create_common : primitivePlacementFrame, WorkplaneFrame,
                              transformPoint, snapLocalHit, screenToPlacementLocal,
                              placeFreePoint;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : publishLastSnap, clearLastSnap, SnapOverlayOwner;
import operator : VectorStack;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import document : Layer;

// ---------------------------------------------------------------------------
// VertexTool — interactive single-vertex placement.
//
// Each LMB click in the viewport:
//   1. Places the FREE point (`placeFreePoint` on the parameter frame): the
//      create click law's q (K-W W1e / W1g), read onto the background surface
//      when the constraint takes the pointer (K-C C1b), then the snap.
//   2. Publishes the snap.
//   3. Converts to world and appends one isolated vertex (mesh.addVertex).
//   4. Records a snapshot-undo entry immediately — one entry per click.
//
// Tool stays active across clicks (no in-progress sequence to commit or
// cancel).  Vertices are isolated: no auto-edge, no auto-face.
//
// Interactive-only; no headless command path.  The headless geometry contract
// for vertex creation is mesh.addVertex (task 0131).
// ---------------------------------------------------------------------------
class VertexTool : Tool, PreparedToolDoorClient {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*          gpu_;
    LitShader         litShader_;



    Viewport   cachedVp_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader)
    {
        this.meshSrc_   = meshSrc;
        this.gpu_       = gpu;
        this.litShader_ = litShader;
    }

    override string name() const { return "Vertex"; }

    override Param[] params() { return []; }

    override void deactivate() {
        clearLastSnap();
    }

    // The tool keeps no private state (its snap is `g_lastSnap`): a switch
    // away enlists only the snap clear, an arm nothing.
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        if (context is null) return false;
        const ok = context.prepareSnapClear(new SnapOverlayOwner()) &&
                   context.markNoHistoryInstall();
        if (!ok) context.discard();
        return ok;
    }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        if (context is null) return false;
        const ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return ok;
    }

    // Cache the viewport each frame so onMouseButtonDown has current camera.
    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, const ref DrawPlan plan,
                       bool visualOnly = false)
    {
        cachedVp_ = vp;
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Click in viewport to place a vertex.");
    }

    // Every click is committed immediately — nothing is ever pending.
    override bool hasUncommittedEdit() const { return false; }

    // H7 (slice M6): the flags table sets the rollover flag on this tool; it
    // picks no hover type yet (`wantsHoverForType`), so nothing is drawn.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            rollovers: Rollover.target, sessionSteps: true,
            historyRecordedSteps: true };
        return policy;
    }
    override void cancelUncommittedEdit() {}

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts)
    {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt is reserved for camera orbit / pan / zoom.
        if (mods & KMOD_ALT) return false;
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;

        WorkplaneFrame frame = primitivePlacementFrame();
        SnapResult sr;
        Vec3 hit = placeFreePoint(e.x, e.y, cachedVp_, frame, *mesh, sr);
        publishLastSnap(sr);

        // Convert local workplane hit → world position.
        Vec3 world = transformPoint(frame.toWorld, hit);

        // Capture mesh state before modification.
        MeshSnapshot pre = MeshSnapshot.capture(*mesh);

        // Append isolated vertex and fix up selection arrays.
        // CRITICAL: addVertex grows vertices[] only; resizeVertexSelection()
        // must precede selectVertex to prevent an out-of-bounds RangeError
        // (mirrors vertex_new.d:57-66 and pen.d:910-913).
        uint vi = mesh.addVertex(world);
        mesh.resizeVertexSelection();
        mesh.clearVertexSelection();    // only the NEWEST vertex selected
        mesh.selectVertex(cast(int)vi);

        // Upload geometry to GPU.  buildLoops() is intentionally omitted:
        // an isolated vertex has no edges / faces, so loop rebuild is a
        // no-op here — omitting it mirrors vertex_new.d (task 0131).
        gpu_.upload(*mesh);

        // Record one undo entry per click (not per session). The record sits
        // in the RAW EVENT HANDLER, not in a commit method — this tool has no
        // commit method at all and reports `hasUncommittedEdit() == false`
        // unconditionally. The seam moves the record; it does NOT move that
        // trigger (task 1905 §2).
        if (history !is null && gestureFactory !is null && pre.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd is null) noteGestureCarrierMismatch();
            else {
                auto post = MeshSnapshot.capture(*mesh);
                cmd.setSnapshots(pre, post, "Add Vertex");
                recordGestureEdit(cmd, GestureRecordMode.Plain);
            }
        }

        // Refresh selection / picking caches (same pattern as pen.d:910-913).
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_);

        return true;
    }

    // Live snap preview — show where the next click would land.
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                                ref VectorStack vts)
    {
        WorkplaneFrame f = primitivePlacementFrame();
        Vec3 hit = screenToPlacementLocal(e.x, e.y, cachedVp_, f);
        publishLastSnap(snapLocalHit(hit, f, e.x, e.y, cachedVp_, *mesh, EditMode.Vertices));
        return false;
    }
}
