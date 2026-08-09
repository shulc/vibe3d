module tools.edit.vertex_bevel_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;
import std.json : JSONValue;

// Reuses the generic before/after-snapshot record command (MeshSessionEdit),
// same as tools/edge_bevel.d and tools/poly_bevel.d — see those modules'
// comments. The undo LABEL is set per-session via setSnapshots(...,
// "Vertex Bevel"), so the history entry reads distinctly even though the
// underlying command class name stays "mesh.bevel_edit".
alias VertexBevelEditFactory = MeshSessionEdit delegate();

// ---------------------------------------------------------------------------
// VertexBevelTool — interactive Vertex Bevel (factory id `mesh.vertexBevel`,
// task 0360 promotion of the one-shot `mesh.vertexBevel` command).
//
// Grounded in the captured toolcard (private spec tree — not reproduced
// here beyond the geometry/behavior facts already baked into
// mesh.bevelVerticesByMask):
//   - ONE attribute (`inset`, world units, default 0.0).
//   - Exactly ONE drawn handle ("Inset"), ACTR-anchored — unlike Polygon
//     Bevel's two handles, only inset is adjustable when beveling
//     vertices.
//   - `inset == 0` AND `inset < 0` are BOTH confirmed byte-exact no-ops
//     (unlike the polygon-inset tool's degenerate-but-real zero-width split) —
//     mesh.bevelVerticesByMask already guards `amount < 1e-6f` as a
//     no-op, so this divergence from the polygon-inset tool needed ZERO kernel
//     changes to already be correct.
//   - "Round Level" (extra rounding geometry) is a real, captured, but
//     UNVERIFIED-formula reference option (confirmed to add substantial
//     extra geometry structurally — roughly 2x the vertex count at
//     level=1 on a 4-corner selection; exact rounding profile not
//     derivable from the capture). Deliberately left OUT of this port
//     rather than guessed — it is also not part of the captured
//     handle_map (single handle only), so this is a panel-only gap, not
//     a missing-handle gap.
//   - Multi-adjacent-selection interaction (the exact per-vertex offset
//     law when several mutually-edge-adjacent vertices are beveled
//     together) is an OPEN QUESTION per the toolcard — not independently
//     re-derivable with the capture harness used. This tool ports the
//     single-vertex law byte-exact (see mesh.bevelVerticesByMask's own
//     tests) and does not attempt to special-case multi-adjacent
//     selections beyond what the existing kernel already does.
//
// Session lifecycle mirrors EdgeBevelTool (its closest sibling: one
// attribute, ACTR-anchored single handle, topology-creating, generic
// before/after-snapshot undo).
// ---------------------------------------------------------------------------
class VertexBevelTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory          history;
    VertexBevelEditFactory  factory;

    float inset_ = 0.0f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 insetAxis;
    ulong gizmoSelHash;

    enum int PART_INSET = 0;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseInset;

    Arrow       insetArrow;
    ToolHandles toolHandles;

    enum Vec3 INSET_COLOR = schemeColor(SchemeColor.toolWidth);

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
        insetArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), INSET_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (insetArrow !is null) insetArrow.destroy();
    }

    void setUndoBindings(CommandHistory h, VertexBevelEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Vertex Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [Param.float_("inset", "Inset", &inset_, 0.0f)];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        inset_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && inset_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && inset_ != 0.0f;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    public override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // Headless apply (tool.doApply) — the Post-Mode path a panel numeric
    // edit + Apply button drives. MUST NOT snapshot — ToolDoApplyCommand
    // wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Vertices) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.vertices.length == 0) return false;
        if (inset_ == 0.0f) return true;
        auto mask = currentMask();
        size_t n = mesh.bevelVerticesByMask(mask, inset_);
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
        dragBaseInset = inset_;

        if (part == PART_INSET) {
            dragPart = PART_INSET;
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
        // The previous pixel comes from the cooked gesture, not from this
        // tool's own pair — same integer subtraction, sourced one level up.
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        bool skip;
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length the kernel means (task 0645) — one OverlayAxis in
        // both roles, so the arm the pixels are dotted against is the arm on
        // screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(insetAxis);
        Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            float d = ax.toLocal(dot(delta, ax.dir));
            // No clamp to >=0: the captured law says BOTH inset==0 AND
            // inset<0 are no-ops (mesh.bevelVerticesByMask already guards
            // `amount < 1e-6f`), so a drag that crosses zero just yields a
            // cleared preview rather than needing to be pinned at zero.
            inset_ = dragBaseInset + d;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }


    // Read-only test seam (task 0645) — GET /api/tool/handles. The registry
    // stays the hit-testing authority; this only exposes its already-drawn
    // state, and that state is the ONLY place a handle's SPACE is observable
    // from outside the process. Mirrors PolyBevelTool / EdgeBevelTool, which
    // carried it already.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Vertices) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor;   // LOCAL, like the kernel

        // ONE overlay space for the pass (task 0645): the arm is positioned in
        // it and `toolHandles.update` below hit-tests this same object, so
        // drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const auto ax      = os.axis(insetAxis);
        const Vec3 anchorW = os.pos(anchor);

        float armLen = gizmoSize(anchorW, vp, 1.0f);
        insetArrow.start = anchorW + ax.dir * (armLen / 6.0f);
        insetArrow.end   = anchorW + ax.dir * armLen;
        insetArrow.color = INSET_COLOR;

        toolHandles.begin();
        toolHandles.add(insetArrow, PART_INSET);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        insetArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandVertexMask(EditMode.Vertices);
    }

    // Anchor = selection centroid; insetAxis = averaged normal of faces
    // incident to the selected vertices (mirrors EdgeBevelTool's
    // width-axis derivation, one level down the element hierarchy).
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
        insetAxis    = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        baseAnchor   = anchor;
        gizmoSelHash = mesh.selectionSignature(EditMode.Vertices);
        gizmoValid   = true;
    }

    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        if (inset_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        size_t n = mesh.bevelVerticesByMask(mask, inset_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Vertex Bevel");
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
