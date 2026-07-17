module tools.edit.vertex_extrude_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, CubicArrow, ToolHandles, HandleState, gizmoSize;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;

// Reuses the generic before/after-snapshot record command (MeshSessionEdit),
// same as tools/poly_bevel.d and tools/vertex_bevel_tool.d.
alias VertexExtrudeEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// VertexExtrudeTool — interactive Vertex Extrude (factory id
// `mesh.vertexExtrude`, task 0360 promotion of the one-shot
// `mesh.vertexExtrude` command).
//
// Grounded in the captured toolcard (private spec tree — not reproduced
// here beyond the geometry/behavior facts baked into
// mesh.extrudeVerticesByMask, source/mesh.d — see that kernel's
// doc-comment for the full captured-law writeup):
//   - TWO independent attributes/handles: `shift` ("Extrude", along the
//     averaged vertex normal) and `width` ("Width", ring radius around
//     the vertex).
//   - `width == 0` is a COMPLETE no-op regardless of `shift` (confirmed
//     byte-exact — shift alone never moves anything). `width != 0` with
//     `shift == 0` builds an N-gon ring around a STATIONARY apex.
//   - `shift != 0` together with `width != 0` moves the apex by
//     `(shift + width)` along the vertex normal — a TENTATIVE,
//     single-captured-data-point law (see the kernel doc-comment); this
//     tool exercises it as-is via the Extrude handle once Width is
//     nonzero, without pretending it is a fully verified reference match.
//
// Two handles (mirrors PolyBevelTool's Shift/Inset pair, one level down
// the element hierarchy):
//   PART_SHIFT = BLUE Arrow along the averaged vertex normal ("Extrude").
//   PART_WIDTH = RED CubicArrow along an in-plane axis ("Width").
//
// Session lifecycle mirrors PolyBevelTool (topology-creating, own
// before/after snapshot undo via the shared MeshSessionEdit/bevelEditFactory).
// ---------------------------------------------------------------------------
class VertexExtrudeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory           history;
    VertexExtrudeEditFactory factory;

    float shift_ = 0.0f;
    float width_ = 0.0f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 shiftAxis;
    Vec3 widthAxis;
    ulong gizmoSelHash;

    enum int PART_SHIFT = 0;
    enum int PART_WIDTH = 1;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseShift, dragBaseWidth;

    Arrow      shiftArrow;
    CubicArrow widthArrow;
    ToolHandles toolHandles;

    enum Vec3 SHIFT_COLOR = Vec3(0.2f, 0.45f, 1.0f);  // blue
    enum Vec3 WIDTH_COLOR = Vec3(0.9f, 0.2f, 0.2f);   // red

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
        shiftArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), SHIFT_COLOR);
        widthArrow  = new CubicArrow(Vec3(0,0,0), Vec3(1,0,0), WIDTH_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (shiftArrow !is null) shiftArrow.destroy();
        if (widthArrow !is null) widthArrow.destroy();
    }

    void setUndoBindings(CommandHistory h, VertexExtrudeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Vertex Extrude"; }

    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [
            Param.float_("shift", "Extrude", &shift_, 0.0f),
            Param.float_("width", "Width",   &width_, 0.0f),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        shift_   = 0.0f;
        width_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && (shift_ != 0.0f || width_ != 0.0f))
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && (shift_ != 0.0f || width_ != 0.0f);
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
        if (*editMode != EditMode.Vertices) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.vertices.length == 0) return false;
        if (width_ == 0.0f) return true;
        auto mask = currentMask();
        size_t n = mesh.extrudeVerticesByMask(mask, shift_, width_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Vertices) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragLastMX    = e.x; dragLastMY = e.y;
        dragBaseShift = shift_;
        dragBaseWidth = width_;

        if (part == PART_SHIFT || part == PART_WIDTH) {
            dragPart = part;
            toolHandles.setHaul(part);
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;
        Vec3 axis = (dragPart == PART_SHIFT) ? shiftAxis : widthAxis;
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, axis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, axis);
            if (dragPart == PART_SHIFT) shift_ = dragBaseShift + d;
            else                        width_ = dragBaseWidth + d;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Vertices) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor + shiftAxis * shift_;

        float armLen   = gizmoSize(anchor, vp, 1.0f);
        float cubeHalf = gizmoSize(anchor, vp, 0.03f);
        shiftArrow.start = anchor + shiftAxis * (armLen / 6.0f);
        shiftArrow.end   = anchor + shiftAxis * armLen;
        shiftArrow.color = SHIFT_COLOR;
        widthArrow.start         = anchor + widthAxis * (armLen / 7.0f);
        widthArrow.end           = anchor + widthAxis * armLen;
        widthArrow.fixedCubeHalf = cubeHalf;
        widthArrow.color         = WIDTH_COLOR;

        toolHandles.begin();
        toolHandles.add(shiftArrow, PART_SHIFT);
        toolHandles.add(widthArrow, PART_WIDTH);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        shiftArrow.draw(shader, vp);
        widthArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Vertices)) {
            auto m = new bool[](mesh.vertices.length);
            m[] = true;
            return m;
        }
        return mesh.selectedVertices;
    }

    void computeGizmoFrame() {
        gizmoValid = false;
        if (mesh.vertices.length == 0) return;
        bool any = mesh.hasAnySelectedVertices();
        Vec3 sum = Vec3(0, 0, 0);
        foreach (vi; 0 .. mesh.vertices.length) {
            if (any && !mesh.isVertexSelected(vi)) continue;
            foreach (fi; mesh.facesAroundVertex(cast(uint)vi))
                sum = sum + mesh.faceNormal(cast(uint)fi);
        }
        anchor = mesh.selectionCentroidVertices();
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        Vec3 up   = (abs(shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);
        Vec3 side = cross(shiftAxis, up);
        float slen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
        widthAxis    = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);
        baseAnchor   = anchor;
        gizmoSelHash = mesh.selectionSignature(EditMode.Vertices);
        gizmoValid   = true;
    }

    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (width_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.extrudeVerticesByMask(mask, shift_, width_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Vertex Extrude");
        history.record(cmd);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
