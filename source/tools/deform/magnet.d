module tools.deform.magnet;

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
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import deform_magnet : applyMagnet;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, ElementConnect;
import hover_state : g_hoveredVertex;
import change_bus : MeshEditScope;

import std.math : sqrt;

alias MeshVertexEditFactory = MeshVertexEdit delegate();

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

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory        history;
    MeshVertexEditFactory factory;

    // Gesture state.
    bool         active;
    bool         dragging;
    bool         built;
    int          pickedVi  = -1;   // which vertex was grabbed
    Vec3         center_;          // world position of anchor vertex at grab time
    Vec3         target_;          // cursor projected onto camera-facing plane
    float        strength_ = 0.0f;
    int          dragStartX, dragStartY;

    // Public tool parameter.
    float        dist_     = 1.0f;

    MeshSnapshot before;
    Viewport     cachedVp;

    // Per-gesture undo payload (populated by applyMagnet via rebuildPreview).
    uint[] touchedIdx_;
    Vec3[] touchedPrev_;

    /// Pixel drag distance that maps to strength = 1.0.
    enum float STRENGTH_PX = 150.0f;

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

    void setUndoBindings(CommandHistory h, MeshVertexEditFactory f) {
        this.history = h;
        this.factory = f;
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
        // View forward: col-major lookAt stores (-f.x,-f.y,-f.z) at indices 2,6,10.
        Vec3 fwd = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
        Vec3 magOrig, ray;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, magOrig, ray);
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
        cachedVp = vp;
        // No gizmo in v1 — hover sphere drawing deferred to later.
    }

private:
    void rebuildPreview() {
        if (!active || pickedVi < 0) return;
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

        Viewport nullVp;   // Element falloff ignores viewport
        bool displaced = applyMagnet(mesh, indices, target_, strength_, fp, nullVp,
                                     touchedIdx_, touchedPrev_);
        built = displaced;
        if (displaced) mesh.commitChange(MeshEditScope.Position);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!built || touchedIdx_.length == 0) return;
        Vec3[] after;
        after.length = touchedIdx_.length;
        foreach (k; 0 .. touchedIdx_.length)
            after[k] = mesh.vertices[touchedIdx_[k]];
        auto cmd = factory();
        cmd.setEdit(touchedIdx_.dup, touchedPrev_.dup, after, "Magnet");
        history.record(cmd);
        built               = false;
        touchedIdx_.length  = 0;
        touchedPrev_.length = 0;
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
