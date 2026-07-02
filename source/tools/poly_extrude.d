module tools.poly_extrude;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.face_extrude_edit : MeshFaceExtrudeEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;

/// The interactive tool reuses the dedicated MeshFaceExtrudeEdit record command
/// (a before/after MeshSnapshot pair) — mirroring EdgeExtrudeTool's pattern.
alias FaceExtrudeEditFactory = MeshFaceExtrudeEdit delegate();

// ---------------------------------------------------------------------------
// PolyExtrudeTool — interactive Face Extrude (factory id `poly.extrude`).
//
// Cloned from EdgeExtrudeTool and simplified to a SINGLE axis (distance) with
// no width axis. Polygon-mode only; topology-creating: one snapshot-based undo
// entry per session (Phase 5 delta undo is deferred).
//
// Session model (matches EdgeExtrudeTool):
//   activate()   — snapshot cage+selection; reset distance to 0; build gizmo.
//   drag         — restore cage, reapply extrudeFacesByMask(mask, distance_).
//   deactivate() — if built && distance != 0: commit MeshFaceExtrudeEdit.
//
// Single handle:
//   PART_EXTRUDE = BLUE Arrow along averaged region normal. Dragging changes
//   `distance` only. Off-handle (miss click) starts a blind vertical free drag
//   (up/down → distance_).
//
// Headless path: `tool.set poly.extrude on; tool.attr poly.extrude distance
// <v>; tool.doApply` drives through applyHeadless(); ToolDoApplyCommand wraps
// it with a snapshot pair for undo (applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class PolyExtrudeTool : Tool {
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
    FaceExtrudeEditFactory factory;

    // Parameters.
    float distance_ = 0.0f;

    // Interactive session state.
    bool          active;
    bool          built;
    MeshSnapshot  before;
    Viewport      cachedVp;

    // Gizmo frame.
    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 extrudeAxis;
    ulong gizmoSelHash;

    // Drag state.
    enum int PART_EXTRUDE = 0;
    enum int PART_FREE    = 1;   // off-handle blind vertical drag
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    int   dragStartMX, dragStartMY;
    float dragBaseDistance;

    enum float FREE_SCALE = 0.01f;

    Arrow       extrudeArrow;
    ToolHandles toolHandles;

    enum Vec3 EXTRUDE_COLOR = Vec3(0.2f, 0.45f, 1.0f);   // blue

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
        extrudeArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 1, 0), EXTRUDE_COLOR);
        toolHandles  = new ToolHandles();
    }

    void destroy() {
        if (extrudeArrow !is null) extrudeArrow.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    void setUndoBindings(CommandHistory h, FaceExtrudeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Face Extrude"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [Param.float_("distance", "Distance", &distance_, 0.0f)];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built     = false;
        dragPart  = -1;
        distance_ = 0.0f;
        before    = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && distance_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && distance_ != 0.0f;
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

    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        if (distance_ == 0.0f) return true;   // identity is a clean no-op
        auto mask = currentMask();
        size_t n = mesh.extrudeFacesByMask(mask, distance_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0 || !gizmoValid) return false;

        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragLastMX       = e.x;
        dragLastMY       = e.y;
        dragStartMX      = e.x;
        dragStartMY      = e.y;
        dragBaseDistance = distance_;

        if (part == PART_EXTRUDE) {
            dragPart = PART_EXTRUDE;
            toolHandles.setHaul(part);
            return true;
        }
        // Off-handle: blind vertical free drag.
        dragPart = PART_FREE;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;

        if (dragPart == PART_FREE) {
            int dy = e.y - dragStartMY;
            distance_ = dragBaseDistance + (-dy) * FREE_SCALE;
            rebuildPreview();
            dragLastMX = e.x;
            dragLastMY = e.y;
            return true;
        }

        // PART_EXTRUDE: project per-event delta onto the extrude axis.
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, extrudeAxis, cachedVp, skip);
        if (!skip) {
            distance_ += dot(delta, extrudeAxis);
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        cachedVp = vp;
        // Recompute gizmo frame when selection changes while idle (not mid-drag,
        // not after built preview — that would double-count the distance offset).
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        // Anchor slides analytically along extrudeAxis by distance_.
        anchor = baseAnchor + extrudeAxis * distance_;

        float armLen = gizmoSize(anchor, vp, 1.0f);
        extrudeArrow.start = anchor + extrudeAxis * (armLen / 6.0f);
        extrudeArrow.end   = anchor + extrudeAxis * armLen;
        extrudeArrow.color = EXTRUDE_COLOR;

        toolHandles.begin();
        toolHandles.add(extrudeArrow, PART_EXTRUDE);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        extrudeArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Polygons)) {
            auto m = new bool[](mesh.faces.length);
            m[] = true;
            return m;
        }
        return mesh.selectedFaces;
    }

    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (distance_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.extrudeFacesByMask(mask, distance_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Face Extrude");
        history.record(cmd);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    void cancelLiveEdit() {
        before.restore(*mesh);
        refreshCaches();
        distance_ = 0.0f;
        built     = false;
        dragPart  = -1;
        toolHandles.clearHaul();
    }

    // Compute gizmo anchor + extrude axis from the current face selection.
    // anchor      = centroid of selected face centroids.
    // extrudeAxis = normalized average of selected face normals.
    void computeGizmoFrame() {
        gizmoValid   = false;
        gizmoSelHash = mesh.selectionSignature(EditMode.Polygons);
        if (mesh.faces.length == 0) return;

        bool wholeMesh = mesh.nothingSelected(EditMode.Polygons);
        auto selFaces  = mesh.selectedFaces;

        Vec3   centSum = Vec3(0, 0, 0);
        size_t centN   = 0;
        Vec3   normSum = Vec3(0, 0, 0);

        foreach (fi; 0 .. mesh.faces.length) {
            bool selected = wholeMesh || (fi < selFaces.length && selFaces[fi]);
            if (!selected) continue;
            Vec3 c = mesh.faceCentroid(cast(uint)fi);
            centSum = centSum + c;
            ++centN;
            normSum = normSum + mesh.faceNormal(cast(uint)fi);
        }

        if (centN == 0) return;
        anchor     = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);
        baseAnchor = anchor;

        float nl = sqrt(normSum.x*normSum.x + normSum.y*normSum.y + normSum.z*normSum.z);
        extrudeAxis = (nl > 1e-6f) ? normSum * (1.0f / nl) : Vec3(0, 1, 0);

        gizmoValid = true;
    }
}
