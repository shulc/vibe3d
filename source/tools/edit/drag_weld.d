module tools.edit.drag_weld;
import display_state : DrawPlan;

import bindbc.sdl;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import editmode : EditMode;
import operator : VectorStack;
import snap : editedVertexAt, snapPacketOf;
import toolpipe.packets : SnapPacket, SymmetryPacket;
import constraint : topoPenPressPickPx, topoPenSnapAcceptPx;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import document : Layer;

// ---------------------------------------------------------------------------
// DragWeldTool — drag a source vertex onto a target vertex to weld them.
//
// Gesture (task 9437; captures K-W2, K-P P6): the press and the target are
// `snap.editedVertexAt`, the topology pen's finder — edited mesh only, with
// the occlusion and hidden masks. The press reaches `topoPenPressPickPx`; a
// miss is not consumed (camera and other handlers see it). The release asks
// for a target only with snapping ON, at the snap acceptance, excluding the
// source, and welds `weldVertexPairs([[target, source]])`: the target keeps
// its index and position. Nothing moves until the release; a weld is one
// snapshot-undo entry, a miss records nothing.
//
// Selection after the weld (unscored, kept): the survivor is re-found by its
// LAYER-LOCAL position (`keepPos`, captured before the weld; the compaction
// reindexes), local against local, so no item transform applies (task 0619).
//
// Gated to Vertices edit mode via supportedModes().
// ---------------------------------------------------------------------------
class DragWeldTool : Tool, PreparedToolDoorClient {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu_;
    LitShader        litShader_;

    // The world viewport `draw()` was handed; the finder folds the item transform.
    Viewport vpWorld_;

    bool dragging_ = false;
    int  source_   = -1;   // vertex index picked on button-down

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader)
    {
        this.meshSrc_   = meshSrc;
        this.gpu_       = gpu;
        this.litShader_ = litShader;
    }

    override string name() const { return "Drag Weld"; }

    override Param[] params() { return []; }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) { return context.markNoHistoryInstall(); }
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) { return context.markNoHistoryInstall(); }

    // Restrict to Vertices mode — mirrors EdgeExtrudeTool.supportedModes().
    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    // Cache the viewport each frame so pick helpers have current camera.
    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, const ref DrawPlan plan,
                       bool visualOnly = false)
    {
        vpWorld_ = vp;
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Drag a vertex onto another to weld them.");
    }

    // A drag is in progress between button-down and button-up.
    override bool hasUncommittedEdit() const { return dragging_; }

    // H7 (slice M6): the flags table sets the rollover flag on this tool; it
    // picks no hover type yet (`wantsHoverForType`), so nothing is drawn.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            rollovers: Rollover.target,
            sessionSteps: true, historyRecordedSteps: true };
        return policy;
    }

    override void cancelUncommittedEdit() {
        dragging_ = false;
        source_   = -1;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts)
    {
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Alt is reserved for camera orbit/pan/zoom.
        if (SDL_GetModState() & KMOD_ALT) return false;

        int vi = findVertex(e.x, e.y, SnapPacket.init, topoPenPressPickPx(vpWorld_), null);
        if (vi < 0) return false;  // no vertex nearby — let camera handle it

        source_   = vi;
        dragging_ = true;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                                ref VectorStack vts)
    {
        // Consume motion events while dragging so camera doesn't orbit.
        // No geometry mutation during the drag — picking is done on release.
        return dragging_;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts)
    {
        if (!dragging_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;

        scope(exit) { dragging_ = false; source_ = -1; }

        const cfg = snapPacketOf(vts);
        if (!cfg.enabled) return true;     // the target search runs only with snapping on
        int target = findVertex(e.x, e.y, cfg, topoPenSnapAcceptPx(vpWorld_, cfg),
                                [cast(uint)source_]);
        if (target < 0) return true;       // no-op release

        Vec3 keepPos = mesh.vertices[cast(uint)target];
        MeshSnapshot pre = MeshSnapshot.capture(*mesh);
        uint[2][] pairs = [[cast(uint)target, cast(uint)source_]];
        // Under symmetry the source's partner welds into the target's (task 9438,
        // KW2_ADW); never into a hidden vertex (W2f), nor when the target IS the
        // partner (the own-mirror weld stays single, pending K-W2b KW2_M).
        auto sym = vts.get!SymmetryPacket();   // off: pairOf is empty
        if (sym !is null && sym.pairOf.length == mesh.vertices.length) {
            immutable int pt = sym.pairOf[target], ps = sym.pairOf[source_];
            if (pt >= 0 && ps >= 0 && ps != target
                && !mesh.isVertexHidden(pt) && !mesh.isVertexHidden(ps))
                pairs ~= [cast(uint)pt, cast(uint)ps];
        }
        if (mesh.weldVertexPairs(pairs) == 0)
            return true;                   // both faceless: no-op

        mesh.clearVertexSelection();       // `compactUnreferenced` already resized it
        int   bestIdx   = -1;
        float bestDist2 = 1e-5f * 1e-5f;
        foreach (i, v; mesh.vertices) {
            Vec3 d = v - keepPos;
            float dist2 = d.x*d.x + d.y*d.y + d.z*d.z;
            if (dist2 < bestDist2) { bestDist2 = dist2; bestIdx = cast(int)i; }
        }
        if (bestIdx >= 0) mesh.selectVertex(bestIdx);

        gpu_.upload(*mesh);

        // Record one snapshot-undo entry per completed gesture.
        if (history !is null && gestureFactory !is null && pre.filled) {
            // The ONE G4 record INLINED in an event handler rather than in a
            // commit body — the gesture ends with the button, so there is no
            // later `deactivate` to write from. The refusal is an `else`, not
            // an early return: the handler still owes its caller the selection
            // sync and the display refresh below.
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd is null) noteGestureCarrierMismatch();
            else {
                auto post = MeshSnapshot.capture(*mesh);
                cmd.setSnapshots(pre, post, "Weld Vertices");
                recordGestureEdit(cmd, GestureRecordMode.Plain);
            }
        }

        // Refresh selection / picking caches (mirrors vertex_place.d:174-187).
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_);
        return true;
    }

private:
    int findVertex(int sx, int sy, in SnapPacket cfg, float rangePx, const(uint)[] exclude) {
        import document : primaryModelSpace;
        return editedVertexAt(sx, sy, vpWorld_, *mesh, primaryModelSpace(), cfg, rangePx,
                              null, exclude);
    }
}
