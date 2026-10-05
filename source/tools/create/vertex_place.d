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
                              placeFreePoint, baseDragTarget, axisUnit;
import tools.common.session_mesh_key : SessionMeshKey;
import change_bus : MeshEditScope;
import drag : HandleDrag;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : publishLastSnap, clearLastSnap, SnapOverlayOwner;
import operator : VectorStack;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import document : Layer;

// ---------------------------------------------------------------------------
// VertexTool — interactive single-vertex placement.
//
// Each LMB press places one isolated vertex at the FREE point
// (`placeFreePoint` on the parameter frame: the create click law's q, read
// onto the background surface when the constraint takes the pointer, then the
// snap) and selects only it. The drag moves it live: every motion re-resolves
// the free point at q(q(press) + travel) under the same gate (K-C5, gap 573).
// The release records ONE undo entry for the gesture; until then the vertex is
// the tool's uncommitted edit (Ctrl+Z / RMB remove it, a drop records it).
// Vertices are isolated: no auto-edge, no auto-face. The headless geometry
// contract for vertex creation is mesh.addVertex (task 0131).
// ---------------------------------------------------------------------------
class VertexTool : Tool, PreparedToolDoorClient {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*          gpu_;
    LitShader         litShader_;

    // The live gesture, press to release: its vertex (-1 = none), the press it
    // carries, the plane frame and axis of that press, the mesh before it.
    int            vert_ = -1;
    HandleDrag     grab_;
    int            axis_;
    WorkplaneFrame frame_;
    MeshSnapshot   pre_;
    SessionMeshKey key_;

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
        commitVertex();
        clearLastSnap();
    }

    // Idle, the tool keeps no private state (its snap is `g_lastSnap`): a
    // switch away enlists only the snap clear, an arm nothing. A switch during
    // the drag (a script door; keys wait for the release) is refused.
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        if (context is null) return false;
        const ok = !hasUncommittedEdit() &&
                   context.prepareSnapClear(new SnapOverlayOwner()) &&
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

    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, const ref DrawPlan plan,
                       bool visualOnly = false)
    {
        cachedVp = vp;
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Click in viewport to place a vertex.");
    }

    // The press's vertex until the release records it, while the mesh is the
    // one it was placed on.
    override bool hasUncommittedEdit() const {
        return vert_ >= 0 && key_.matches(*mesh);
    }

    // H7 (slice M6): the flags table sets the rollover flag on this tool; it
    // picks no hover type yet (`wantsHoverForType`), so nothing is drawn.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            rollovers: Rollover.target, sessionSteps: true,
            historyRecordedSteps: true };
        return policy;
    }

    // Removes the live vertex: the mesh goes back to its image before the press.
    override void cancelUncommittedEdit() {
        if (hasUncommittedEdit()) {
            pre_.restore(*mesh);
            refreshDisplay(mesh, gpu_);
        }
        vert_ = -1;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts)
    {
        if (e.button == SDL_BUTTON_RIGHT && vert_ >= 0) {
            cancelUncommittedEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt is reserved for camera orbit / pan / zoom.
        if (mods & KMOD_ALT) return false;
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;

        frame_ = primitivePlacementFrame();
        grab_.press(screenToPlacementLocal(e.x, e.y, cachedVp, frame_, axis_), e.x, e.y);
        pre_ = MeshSnapshot.capture(*mesh);
        SnapResult sr;
        Vec3 world = transformPoint(frame_.toWorld,
            placeFreePoint(grab_.point, e.x, e.y, cachedVp, frame_, *mesh, sr));
        publishLastSnap(sr);

        // CRITICAL: addVertex grows vertices[] only; resizeVertexSelection()
        // must precede selectVertex to prevent an out-of-bounds RangeError.
        vert_ = cast(int)mesh.addVertex(world);
        mesh.resizeVertexSelection();
        mesh.clearVertexSelection();    // only the NEWEST vertex selected
        mesh.selectVertex(vert_);
        mesh.syncSelection();
        key_.stamp(*mesh);
        refreshDisplay(mesh, gpu_);
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts)
    {
        if (e.button != SDL_BUTTON_LEFT || vert_ < 0) return false;
        commitVertex();
        return true;
    }

    // The drag moves the live vertex (version-silent, Position class); with no
    // gesture, the snap preview shows where the next press would land.
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                                ref VectorStack vts)
    {
        if (!hasUncommittedEdit()) {
            WorkplaneFrame f = primitivePlacementFrame();
            Vec3 hit = screenToPlacementLocal(e.x, e.y, cachedVp, f);
            publishLastSnap(snapLocalHit(hit, f, e.x, e.y, cachedVp, *mesh, EditMode.Vertices));
            return false;
        }
        Vec3 t;
        if (!baseDragTarget(grab_, e.x, e.y, axisUnit(axis_), cachedVp, frame_, t)) return true;
        SnapResult sr;
        const uint[1] self = [cast(uint)vert_];
        mesh.vertices[vert_] = transformPoint(frame_.toWorld,
            placeFreePoint(t, e.x, e.y, cachedVp, frame_, *mesh, sr, self[]));
        publishLastSnap(sr);
        mesh.publishChange(MeshEditScope.Position);
        refreshDisplay(mesh, gpu_);
        return true;
    }

private:
    // One undo entry per gesture, at its end (release or drop).
    void commitVertex() {
        if (!hasUncommittedEdit()) { vert_ = -1; return; }
        vert_ = -1;
        if (history is null || gestureFactory is null || !pre_.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        cmd.setSnapshots(pre_, MeshSnapshot.capture(*mesh), "Add Vertex");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
}
