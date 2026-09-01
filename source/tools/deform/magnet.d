module tools.deform.magnet;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import command_history : PreparedHistoryKind;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import shader : Shader;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import snapshot : MeshSnapshot;
import tools.common.session_mesh_key : SessionMeshKey;
import display_sync : refreshDisplay;
import deform_magnet : applyMagnet;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, ElementConnect;
import hover_state : g_hoveredVertex;
import change_bus : MeshEditScope;
import document : primaryModelSpace;

import std.math : sqrt;
import perf_probe : g_perf, Cat;

/// Convergent attraction deformer tool (`xfrm.magnet`).
///
/// Workflow:
///   1. Hover over a vertex — it highlights (ToolFlag.HoverVertices enables GPU pick).
///   2. LMB-drag from the highlighted vertex: the vertex is the ANCHOR
///      (anchorRing → weight=1, always lands on the projected cursor position).
///      All other vertices within `dist` world units are pulled toward the same
///      target with a Smooth-curve falloff.  Strength ramps 0→1 over
///      STRENGTH_PX pixels of drag distance.
///   3. Release: commits a MeshVertexEdit undo entry.  Multiple gestures each
///      get their own independent entry.
///
/// Headless surface: `mesh.magnet` command.
class MagnetTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;



    // Gesture state.
    bool         active;
    bool         dragging;
    bool         built;
    int          pickedVi  = -1;   // which vertex was grabbed
    // LAYER-LOCAL, both of them. `center_` is a raw `mesh.vertices[]` read
    // (this comment used to say "world position" — task 0619; it was wrong,
    // and it is the exact comment-lies-about-a-space shape that task hunts).
    // `target_` must match it: both are handed to `applyMagnet` /
    // `FalloffPacket.pickedCenter`, which compare and write LOCAL vertex
    // coordinates.
    Vec3         center_;          // anchor vertex position at grab time (LOCAL)
    Vec3         target_;          // cursor on the camera-facing plane (LOCAL)
    float        strength_ = 0.0f;
    int          dragStartX, dragStartY;

    // Public tool parameter.
    float        dist_     = 1.0f;

    MeshSnapshot before;
    // The WORLD-space viewport `draw()` was handed (task 0619 rename): this
    // tool's aiming kind is **RayPlane** (§1.2), which builds its ray from
    // the UN-composed viewport and then moves it into local space — it must
    // never be handed a composed/aim viewport.
    Viewport     vpWorld_;

    // Per-gesture undo payload (populated by applyMagnet via rebuildPreview).
    uint[] touchedIdx_;
    /// The identity of the mesh `touchedIdx_` indexes — see `SessionMeshKey`.
    /// `commitEdit()` reads `mesh.vertices[touchedIdx_[k]]` to build the undo
    /// AFTER-image, and `built` alone is gesture state: measured 2026-08-28, a
    /// vertex haul left mid-drag (LMB still down) followed by
    /// `POST /api/reset?empty=true` kills the process with
    /// `ArrayIndexError@source/tools/deform/magnet.d(298)`. The mouse-UP path
    /// clears `built`, so the reachable window is a tool-drop mid-drag — which
    /// is exactly what a document change performs.
    SessionMeshKey sessionKey_;
    Vec3[] touchedPrev_;

    /// Pixel drag distance that maps to strength = 1.0.
    enum float STRENGTH_PX = 150.0f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
    }

    override string name() const { return "Magnet"; }

    /// Require vertex hover so `g_hoveredVertex` is updated while the tool
    /// is active (app.d: pickVertices runs when wantsHoverForType(Vertices)).
    override ToolFlag flags() const { return ToolFlag.HoverVertices; }

    /// Switching to this tool also switches the edit mode to Vertices.
    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [
            Param.float_("dist", "Dist", &dist_, 1.0f),
        ];
    }

    override void activate() {
        active    = true;
        built     = false;
        dragging  = false;
        pickedVi  = -1;
        before    = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active) {
            if (built)
                commitEdit();
            // When built=false the mesh is already in the baseline state
            // (rebuildPreview always restores `before` before deforming).
        }
        active    = false;
        built     = false;
        dragging  = false;
        pickedVi  = -1;
    }

    override bool isDragging() const { return dragging; }

    override bool hasUncommittedEdit() const { return active && built; }

    override void cancelUncommittedEdit() {
        if (built && before.filled)
            before.restore(*mesh);
        built    = false;
        dragging = false;
        pickedVi = -1;
        refreshCaches();
    }

    override void resyncSession() {
        if (!active) return;
        if (built && before.filled)
            before.restore(*mesh);
        built    = false;
        dragging = false;
        pickedVi = -1;
        before   = MeshSnapshot.capture(*mesh);
        refreshCaches();
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
    }

    override void onParamChanged(string pname) {
        // dist changed while dragging — rebuild with new radius.
        if (pname == "dist" && dragging && built) rebuildPreview();
    }
    override void evaluate() {}

    // -----------------------------------------------------------------------
    // Mouse handling
    // -----------------------------------------------------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;

        int hv = g_hoveredVertex;
        if (hv < 0 || cast(size_t)hv >= mesh.vertices.length) return false;

        // Commit any prior in-flight gesture (edge case: two downs without up).
        if (built) { commitEdit(); built = false; }

        pickedVi   = hv;
        center_    = mesh.vertices[hv];
        target_    = center_;
        strength_  = 0.0f;
        dragStartX = e.x;
        dragStartY = e.y;
        before     = MeshSnapshot.capture(*mesh);
        dragging   = true;
        built      = false;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (built) commitEdit();
        dragging  = false;
        pickedVi  = -1;
        built     = false;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging || pickedVi < 0) return false;

        // Project cursor onto the camera-facing plane through `center_`.
        //
        // AIMING KIND: **RayPlane** (task 0619 §1.2). The whole test runs in
        // the LAYER'S LOCAL space, because `target_` is written into local
        // vertex coordinates by `applyMagnet` (and `center_` is a raw
        // `mesh.vertices[]` read, i.e. already local).
        //
        // The plane's ANCHOR is `center_`, already local. Its NORMAL is the
        // camera forward, a genuinely WORLD direction — and a normal is
        // carried into local space by `M^T` (`toLocalNormal`), NOT by `M^-1`
        // (`toLocalDir`). The two are EQUAL for a pure rotation and diverge
        // under any non-uniform scale, which is exactly the case where the
        // wrong one silently tilts the drag plane.
        //
        // View forward: col-major lookAt stores (-f.x,-f.y,-f.z) at indices 2,6,10.
        const ms = primaryModelSpace();
        Vec3 fwdWorld = Vec3(-vpWorld_.view[2], -vpWorld_.view[6], -vpWorld_.view[10]);
        Vec3 fwd = ms.toLocalNormal(fwdWorld);
        Vec3 magOrig, ray;
        screenPointToLocalRay(cast(float)e.x, cast(float)e.y, vpWorld_, ms, magOrig, ray);
        Vec3 hit;
        if (rayPlaneIntersect(magOrig, ray, center_, fwd, hit))
            target_ = hit;

        // Strength ramps 0→1 over STRENGTH_PX pixels from the grab point.
        float dx = cast(float)(e.x - dragStartX);
        float dy = cast(float)(e.y - dragStartY);
        float d  = sqrt(dx*dx + dy*dy);
        strength_ = d / STRENGTH_PX;
        if (strength_ > 1.0f) strength_ = 1.0f;

        rebuildPreview();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        vpWorld_ = vp;
        // No gizmo in v1 — hover sphere drawing deferred to later.
    }

private:
    void rebuildPreview() {
        if (!active || pickedVi < 0) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);

        if (strength_ <= 0.0f) {
            built = false;
            refreshCaches();
            return;
        }

        // Moving set: selected verts (empty → whole mesh), vertex mode.
        int[] indices = mesh.selectedVertexIndicesVertices();

        FalloffPacket fp;
        fp.type         = FalloffType.Element;
        fp.enabled      = true;
        fp.pickedCenter = center_;
        fp.pickedRadius = dist_;
        fp.connect      = ElementConnect.Ignore;
        fp.shape        = FalloffShape.Smooth;
        fp.anchorPos    = [center_];
        fp.anchorRing   = [cast(uint)pickedVi];

        // The packet just above pins `FalloffType.Element`, which never
        // projects — but the aim space is a required parameter (task 0619),
        // so build the real one from this tool's own world viewport rather
        // than reach for an identity that would be a placeholder.
        const auto aim = aimSpace(vpWorld_, primaryModelSpace());
        bool displaced = applyMagnet(mesh, indices, target_, strength_, fp, aim,
                                     touchedIdx_, touchedPrev_);
        built = displaced;
        // Freeze the identity WITH the indices, every rebuild. This tool's own
        // per-motion edit is Position-class, so it moves no term of the key —
        // a legal drag stamps and matches the same three values throughout.
        if (displaced) sessionKey_.stamp(*mesh);
        if (displaced) mesh.commitChange(MeshEditScope.Position);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        bool accepted;
        if (active && built && touchedIdx_.length && context !is null &&
            history !is null && gestureFactory !is null && sessionKey_.matches(*mesh)) {
            Vec3[] after = new Vec3[](touchedIdx_.length);
            foreach (k; 0 .. touchedIdx_.length)
                after[k] = mesh.vertices[touchedIdx_[k]];
            auto cmd = cast(MeshVertexEdit) gestureFactory();
            if (cmd !is null) {
                cmd.setEdit(touchedIdx_.dup, touchedPrev_.dup, after, "Magnet");
                accepted = context.prepare(cmd, PreparedHistoryKind.Plain).accepted;
            }
        }
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Magnet, accepted);
    }

    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!built || touchedIdx_.length == 0) return;
        // ... and the document mesh must still be the one those indices came
        // from. Without this the read below indexed a mesh a scene reset had
        // already replaced. Dropping silently is right: there is no edit of
        // ours left on that mesh to record.
        if (!sessionKey_.matches(*mesh)) {
            built               = false;
            touchedIdx_.length  = 0;
            touchedPrev_.length = 0;
            return;
        }
        Vec3[] after;
        after.length = touchedIdx_.length;
        foreach (k; 0 .. touchedIdx_.length)
            after[k] = mesh.vertices[touchedIdx_[k]];
        // The ONE non-wrapper tool on the vertex-delta carrier: `setEdit` is a
        // THIRD install form, expressible by neither of the snapshot spellings
        // — which is why the seam takes a FILLED command rather than an
        // installer set (task 1905, round 2 / Б2).
        auto cmd = cast(MeshVertexEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        cmd.setEdit(touchedIdx_.dup, touchedPrev_.dup, after, "Magnet");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
        built               = false;
        touchedIdx_.length  = 0;
        touchedPrev_.length = 0;
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }
}
