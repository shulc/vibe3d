module tools.edit.poly_bevel;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, CubicArrow, ToolHandles, HandleState, gizmoSize, getGizmoPixels;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;
import std.json : JSONValue;

alias PolyBevelEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// PolyBevelTool — interactive Polygon Bevel (factory id `poly.bevel`).
//
// Topology-creating tool, modelled on PolyExtrudeTool. One snapshot undo entry
// per gesture (MeshSessionEdit before/after pair, via bevelEditFactory).
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
    bool  square_   = false;

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
    enum int PART_FREE  = 2;   // free 2D drag off the handles: vertical→shift, horizontal→inset
    int   dragPart = -1;
    int   dragStartMX, dragStartMY;
    float dragBaseShift, dragBaseInset;
    bool  freeCtrl;            // Ctrl held at free-drag start → lock to one axis
    int   freeLockAxis = -1;   // PART_SHIFT / PART_INSET, decided on first motion
    float freeWorldPerPixel;

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
            // task 0458 Phase 3: recovered Square Corner topology rewrite
            // (`bevelFacesByMask`'s `square` — findings.md §3), parity-
            // fixture-verified (Q1-Q4). Promoted out of Hidden now that
            // the kernel + fixtures are green (don't-expose-unready-
            // params rule).
            Param.bool_("square", "Square Corner", &square_, false),
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

    // Read-only test/introspection seams (mirror edge.bevel). The handle
    // registry stays the hit-testing authority; these expose its drawn state
    // + the tool's live params to /api/tool/handles + /api/tool/state.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]     = JSONValue("polyBevel");
        root["shift"]    = JSONValue(shift_);
        root["inset"]    = JSONValue(inset_);
        root["group"]    = JSONValue(group_);
        root["segments"] = JSONValue(segments_);
        root["square"]   = JSONValue(square_);
        root["built"]    = JSONValue(built);
        root["dragPart"] = JSONValue(dragPart);
        return root;
    }

    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        if (inset_ == 0.0f && shift_ == 0.0f) return true;
        auto mask = currentMask();
        size_t n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_, square_);
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

        // Hit-test at the CLICK EVENT's own coords (e.x,e.y) — the exact
        // position of this click — NOT the queryMouse() global override.
        // The override can be stale/stuck at a prior position (app.d keeps it
        // "in lockstep" with motion but a discrete click can still read a
        // stale value → the hit-test misses and the drag silently does
        // nothing). The proven transform gizmo hit-tests with e.x,e.y for
        // exactly this reason (xfrm_transform.d onMouseButtonDown).
        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragStartMX   = e.x; dragStartMY = e.y;
        dragBaseShift = shift_;
        dragBaseInset = inset_;

        if (part == PART_SHIFT || part == PART_INSET) {
            dragPart = part;
            toolHandles.setHaul(part);
            return true;
        }
        // No handle hit → free 2D drag on empty space: vertical → shift (up = +),
        // horizontal → inset (right = +), both at once. With Ctrl held, lock to
        // whichever axis the drag first moves along (only that one changes).
        dragPart          = PART_FREE;
        freeCtrl          = (mods & KMOD_CTRL) != 0;
        freeLockAxis      = -1;
        freeWorldPerPixel = haulWorldPerPixel();
        return true;
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

        if (dragPart == PART_FREE) {
            int dx = e.x - dragStartMX;   // right +
            int dy = dragStartMY - e.y;   // up +
            if (freeCtrl && freeLockAxis < 0 && (abs(dx) > 3 || abs(dy) > 3))
                freeLockAxis = (abs(dy) >= abs(dx)) ? PART_SHIFT : PART_INSET;
            if (!freeCtrl || freeLockAxis == PART_SHIFT)
                shift_ = dragBaseShift + cast(float)dy * freeWorldPerPixel;
            if (!freeCtrl || freeLockAxis == PART_INSET) {
                inset_ = dragBaseInset + cast(float)dx * freeWorldPerPixel;
                if (inset_ < 0.0f) inset_ = 0.0f;
            }
            rebuildPreview();
            return true;
        }

        Vec3 axis = (dragPart == PART_SHIFT) ? shiftAxis : insetAxis;
        bool skip;
        // TOTAL delta from the mouse-DOWN position (dragStart, fixed), NOT the
        // last motion — a smooth multi-event drag must ACCUMULATE, not jump to
        // each SDL motion's tiny increment (otherwise the value depends on how
        // SDL split one physical drag into events → visible jumping). This is
        // the exact bug edge.bevel had and fixed; mirror its onMouseMotion.
        //
        // Project against the FIXED `baseAnchor`, NOT the live `anchor` (which
        // draw() slides along the normal by the current shift): a moving
        // projection reference drifts the screen→world mapping mid-drag, so the
        // same screen pixel would map to a different value each event.
        Vec3 delta = screenAxisDelta(e.x, e.y, dragStartMX, dragStartMY,
                                     baseAnchor, axis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, axis);
            // shift: drag ALONG +normal (away from center) grows it. inset:
            // drag TOWARD the center (−insetAxis) shrinks the cap → inset grows,
            // so its sign is inverted (scale-handle feel: pull the box inward).
            if (dragPart == PART_SHIFT) shift_ = dragBaseShift + d;
            else                        inset_ = dragBaseInset - d;
            if (inset_ < 0.0f) inset_ = 0.0f;
            rebuildPreview();
        }
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
        // Inset handle = a SCALE-style box: it sits out along the in-plane axis
        // and travels TOWARD the center as inset grows, so dragging the box
        // inward visibly shrinks the cap (the box follows the cursor 1:1).
        float insetBoxDist = armLen - inset_;
        if (insetBoxDist < cubeHalf * 2.5f) insetBoxDist = cubeHalf * 2.5f;
        insetArrow.start         = anchor;
        insetArrow.end           = anchor + insetAxis * insetBoxDist;
        insetArrow.fixedCubeHalf = cubeHalf;
        insetArrow.color         = INSET_COLOR;

        toolHandles.begin();
        toolHandles.add(shiftArrow, PART_SHIFT);
        toolHandles.add(insetArrow, PART_INSET);
        if (dragPart == PART_SHIFT || dragPart == PART_INSET) toolHandles.setHaul(dragPart);
        else                                                  toolHandles.setHaul(-1);
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

    // World units per screen pixel at the gizmo anchor — the free 2D drag's
    // pixel→world scale (mirrors PolyInsetTool.haulWorldPerPixel).
    float haulWorldPerPixel() {
        float px = getGizmoPixels();
        if (px < 1e-6f) px = 90.0f;
        return gizmoSize(anchor, cachedVp, 1.0f) / px;
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
        size_t n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_, square_);
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
