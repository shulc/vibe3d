module tools.edge_bevel;

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
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;

alias EdgeBevelEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// EdgeBevelTool — interactive Edge Bevel (factory id `edge.bevel`).
//
// Topology-creating tool, modelled on PolyExtrudeTool. One snapshot undo entry
// per gesture (MeshSessionEdit before/after pair, via bevelEditFactory).
//
// Single handle:
//   PART_WIDTH = BLUE Arrow along the averaged adjacent-face normal.
//
// Headless: tool.set edge.bevel on; tool.attr edge.bevel width <v>;
//           tool.doApply → applyHeadless(); ToolDoApplyCommand wraps undo.
// ---------------------------------------------------------------------------
class EdgeBevelTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory      history;
    EdgeBevelEditFactory factory;

    float width_      = 0.0f;
    int   roundLevel_ = 0;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 widthAxis;
    ulong gizmoSelHash;

    enum int PART_WIDTH = 0;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseWidth;

    Arrow       widthArrow;
    ToolHandles toolHandles;

    enum Vec3 WIDTH_COLOR = Vec3(0.2f, 0.45f, 1.0f);  // blue

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
        widthArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (widthArrow !is null) widthArrow.destroy();
    }

    void setUndoBindings(CommandHistory h, EdgeBevelEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Edge Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        import mesh : MAX_ROUND_LEVEL;
        return [
            Param.float_("width", "Width", &width_, 0.0f),
            Param.int_("roundLevel", "Round Level", &roundLevel_, 0)
                .min(0).max(MAX_ROUND_LEVEL).enforceBounds(),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        width_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && width_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && width_ != 0.0f;
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
        if (*editMode != EditMode.Edges) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.edges.length == 0) return false;
        if (width_ == 0.0f) return true;
        auto mask = currentMask();
        size_t n = mesh.bevelEdgesByMask(mask, width_, roundLevel_);
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
        if (*editMode != EditMode.Edges) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragLastMX    = e.x; dragLastMY = e.y;
        dragBaseWidth = width_;

        if (part == PART_WIDTH) {
            dragPart = PART_WIDTH;
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
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, widthAxis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, widthAxis);
            width_ = dragBaseWidth + d;
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Edges) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor;

        float armLen = gizmoSize(anchor, vp, 1.0f);
        widthArrow.start = anchor + widthAxis * (armLen / 6.0f);
        widthArrow.end   = anchor + widthAxis * armLen;
        widthArrow.color = WIDTH_COLOR;

        toolHandles.begin();
        toolHandles.add(widthArrow, PART_WIDTH);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        widthArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        if (mesh.nothingSelected(EditMode.Edges)) {
            auto m = new bool[](mesh.edges.length);
            m[] = true;
            return m;
        }
        return mesh.selectedEdges;
    }

    void computeGizmoFrame() {
        gizmoValid = false;
        if (mesh.edges.length == 0) return;
        anchor = mesh.selectionCentroidEdges();
        // widthAxis = averaged normal of adjacent faces of selected edges.
        Vec3 sum = Vec3(0,0,0);
        bool any = mesh.hasAnySelectedEdges();
        foreach (fi; 0 .. mesh.faces.length) {
            if (any) {
                bool adj = false;
                auto f = mesh.faces[fi];
                foreach (k; 0..f.length) {
                    foreach (ei; 0 .. mesh.edges.length) {
                        if (!mesh.isEdgeSelected(ei)) continue;
                        uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
                        uint u = f[k], w = f[(k+1)%f.length];
                        if ((a==u&&b==w)||(a==w&&b==u)) { adj = true; break; }
                    }
                    if (adj) break;
                }
                if (adj) sum = sum + mesh.faceNormal(cast(uint)fi);
            } else {
                sum = sum + mesh.faceNormal(cast(uint)fi);
            }
        }
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        widthAxis    = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        baseAnchor   = anchor;
        gizmoSelHash = mesh.selectionSignature(EditMode.Edges);
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
        size_t n = mesh.bevelEdgesByMask(mask, width_, roundLevel_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Bevel");
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
