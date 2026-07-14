module tools.poly_bevel;

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
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;

alias PolyBevelEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// PolyBevelTool — interactive Polygon Bevel (factory id `poly.bevel`).
//
// Topology-creating tool, modelled on PolyExtrudeTool. One snapshot undo entry
// per gesture (MeshBevelEdit before/after pair, via bevelEditFactory).
//
// Two handles:
//   PART_SHIFT = BLUE Arrow along the region face normal.
//   PART_INSET = RED CubicArrow along an in-plane axis.
//
// Headless: tool.set poly.bevel on; tool.attr poly.bevel inset/shift <v>;
//           tool.doApply → applyHeadless(); ToolDoApplyCommand wraps undo.
// ---------------------------------------------------------------------------
class PolyBevelTool : Tool {
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
    PolyBevelEditFactory factory;

    float inset_    = 0.0f;
    float shift_    = 0.0f;
    bool  group_    = true;
    int   segments_ = 0;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 shiftAxis;
    Vec3 insetAxis;
    ulong gizmoSelHash;

    enum int PART_SHIFT = 0;
    enum int PART_INSET = 1;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseShift, dragBaseInset;

    Arrow      shiftArrow;
    CubicArrow insetArrow;
    ToolHandles toolHandles;

    enum Vec3 SHIFT_COLOR = Vec3(0.2f, 0.45f, 1.0f);  // blue
    enum Vec3 INSET_COLOR = Vec3(0.9f, 0.2f, 0.2f);   // red

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
        insetArrow  = new CubicArrow(Vec3(0,0,0), Vec3(1,0,0), INSET_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (shiftArrow !is null) shiftArrow.destroy();
        if (insetArrow !is null) insetArrow.destroy();
    }

    void setUndoBindings(CommandHistory h, PolyBevelEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Poly Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        import mesh : MAX_BEVEL_SEGMENTS;
        return [
            Param.float_("inset", "Inset", &inset_, 0.0f),
            Param.float_("shift", "Shift", &shift_, 0.0f),
            Param.bool_("group", "Group Polygons", &group_, true),
            Param.int_("segments", "Segments", &segments_, 0)
                .min(0).max(MAX_BEVEL_SEGMENTS).enforceBounds(),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        inset_   = 0.0f;
        shift_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && (inset_ != 0.0f || shift_ != 0.0f))
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && (inset_ != 0.0f || shift_ != 0.0f);
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
        if (inset_ == 0.0f && shift_ == 0.0f) return true;
        auto mask = currentMask();
        size_t n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_);
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
        if (*editMode != EditMode.Polygons) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragLastMX    = e.x; dragLastMY = e.y;
        dragBaseShift = shift_;
        dragBaseInset = inset_;

        if (part == PART_SHIFT || part == PART_INSET) {
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
        Vec3 axis = (dragPart == PART_SHIFT) ? shiftAxis : insetAxis;
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, axis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, axis);
            if (dragPart == PART_SHIFT) shift_ = dragBaseShift + d;
            else                        inset_ = dragBaseInset + d;
            if (inset_ < 0.0f) inset_ = 0.0f;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor + shiftAxis * shift_;

        float armLen   = gizmoSize(anchor, vp, 1.0f);
        float cubeHalf = gizmoSize(anchor, vp, 0.03f);
        shiftArrow.start = anchor + shiftAxis * (armLen / 6.0f);
        shiftArrow.end   = anchor + shiftAxis * armLen;
        shiftArrow.color = SHIFT_COLOR;
        insetArrow.start         = anchor + insetAxis * (armLen / 7.0f);
        insetArrow.end           = anchor + insetAxis * armLen;
        insetArrow.fixedCubeHalf = cubeHalf;
        insetArrow.color         = INSET_COLOR;

        toolHandles.begin();
        toolHandles.add(shiftArrow, PART_SHIFT);
        toolHandles.add(insetArrow, PART_INSET);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        shiftArrow.draw(shader, vp);
        insetArrow.draw(shader, vp);
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

    void computeGizmoFrame() {
        gizmoValid = false;
        if (mesh.faces.length == 0) return;
        Vec3 sum = Vec3(0,0,0);
        bool any = mesh.hasAnySelectedFaces();
        anchor = Vec3(0,0,0);
        int cnt = 0;
        foreach (fi; 0 .. mesh.faces.length) {
            if (any && !mesh.isFaceSelected(fi)) continue;
            sum   = sum + mesh.faceNormal(cast(uint)fi);
            anchor = anchor + mesh.faceCentroid(cast(uint)fi);
            ++cnt;
        }
        if (cnt == 0) return;
        anchor = anchor * (1.0f / cast(float)cnt);
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        Vec3 up   = (abs(shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);
        Vec3 side = cross(shiftAxis, up);
        float slen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
        insetAxis    = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);
        baseAnchor   = anchor;
        gizmoSelHash = mesh.selectionSignature(EditMode.Polygons);
        gizmoValid   = true;
    }

    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (inset_ == 0.0f && shift_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Poly Bevel");
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
