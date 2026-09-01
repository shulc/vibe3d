module tools.edit.edge_bevel;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import command_history : PreparedHistoryKind;

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

    float width_      = 0.0f;
    int   roundLevel_ = 0;
    // Mirrors the mesh.bevel command's edge `widthMode`: false (default) =
    // `width_` IS the along-face slide (inset); true = `width_` is the true
    // perpendicular bevel width (slide = width/sin(dihedral/2)). Kept in lock-
    // step with the command so tool preview == headless apply.
    bool  widthMode_  = false;

    bool         active;
    bool         built;
    MeshSnapshot before;
    // The restore-and-rebuild seam (task 1620) — see
    // tools/edit/preview_rebuild.d.
    PreviewRebuild preview_;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 widthAxis;
    ulong gizmoSelHash;

    enum int PART_WIDTH = 0;
    int   dragPart = -1;
    // One drag has one screen-space origin.  Width is written back as an
    // absolute value from that origin, so replay/coalescing cannot make the
    // result depend on how many motion events SDL delivered.
    int   dragStartMX, dragStartMY;
    float dragBaseWidth;

    Arrow       widthArrow;
    ToolHandles toolHandles;

    enum Vec3 WIDTH_COLOR = schemeColor(SchemeColor.toolOffset);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        widthArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (widthArrow !is null) widthArrow.destroy();
    }

    override string name() const { return "Edge Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        import mesh : MAX_ROUND_LEVEL;
        return [
            Param.float_("width", "Width", &width_, 0.0f),
            Param.int_("roundLevel", "Round Level", &roundLevel_, 0)
                .min(0).max(MAX_ROUND_LEVEL).enforceBounds(),
            Param.bool_("widthMode", "Width Mode", &widthMode_, false),
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
        preview_.reset();          // a new clean cage ⇒ a new topology key
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
        preview_.reset();          // drop the clean-cage scratch with the session
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

    /// Test/diagnostic seam (task 1620): how the preview-rebuild seam split
    /// this session's rebuilds. `fullRebuilds` are the restore-and-rebuild
    /// frames (a real topology change, and the ones that legitimately cost a
    /// subpatch dispatch), `placements` the position-only ones, `keyMisses`
    /// the frames where the declared topology key claimed "unchanged" and the
    /// produced topology disagreed. A correct key never misses — see
    /// tools/edit/preview_rebuild.d.
    public PreviewRebuildCounts previewRebuildCounts() const {
        return preview_.counts();
    }

    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live drag (or an interactive-attr scrub) previously built
        // preview topology, restore the clean cage first so the kernel applies
        // exactly once (idempotent) — same guard the whole topology-tool family
        // carries (poly.bevel / edge.extrude / poly.extrude / vertex.bevel /
        // poly.inset). In the pure headless flow (no drag) `before` == the
        // current mesh, so this is a no-op and ToolDoApplyCommand's pre-snapshot
        // stays clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        // This path rebuilds the live mesh behind the seam's back, so the
        // key it remembers no longer describes what is standing.
        preview_.reset();
        if (mesh.edges.length == 0) return false;
        if (width_ == 0.0f) return true;
        auto mask = currentMask();
        // Task 1903 Stage G — the COMMIT door's batch, opened at the tool
        // boundary (§4.1) and scoped to the kernel call alone. UNRECORDED:
        // this tool undoes through the whole-mesh `before`/`post` snapshot
        // pair `commitEdit` records, so a recording batch would build an
        // op-log nothing reads and `close()` would drop. Stage M owns the
        // flip.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kEdgeBevelEditScope);
            n = ed.bevelEdgesByMask(mask, width_, roundLevel_, widthMode_);
            ed.close();
        }
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

        dragStartMX   = e.x; dragStartMY = e.y;
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
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length the kernel means (task 0645) — one OverlayAxis in
        // both roles, so the arm the pixels are dotted against is the arm on
        // screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(widthAxis);
        Vec3 delta = screenAxisDelta(e.x, e.y, dragStartMX, dragStartMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            float d = ax.toLocal(dot(delta, ax.dir));
            width_ = dragBaseWidth + d;
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
        }
        return true;
    }

    // Read-only test seams.  The handle registry remains the hit-testing
    // authority; these merely expose its already-drawn state to the HTTP API.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]       = JSONValue("edgeBevel");
        root["width"]      = JSONValue(width_);
        root["roundLevel"] = JSONValue(roundLevel_);
        root["widthMode"]  = JSONValue(widthMode_);
        root["built"]      = JSONValue(built);
        root["dragPart"]   = JSONValue(dragPart);
        return root;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Edges) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor;   // LOCAL, like the kernel

        // ONE overlay space for the pass (task 0645): the arm is positioned in
        // it and `toolHandles.update` below hit-tests this same object, so
        // drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const auto ax      = os.axis(widthAxis);
        const Vec3 anchorW = os.pos(anchor);

        float armLen = gizmoSize(anchorW, vp, 1.0f);
        widthArrow.start = anchorW + ax.dir * (armLen / 6.0f);
        widthArrow.end   = anchorW + ax.dir * armLen;
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
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandEdgeMask();
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
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        // TOPOLOGY KEY (task 1620): the operand mask, `roundLevel` (which is
        // the bevel's segment count and therefore how many rings exist),
        // `widthMode` — and THE ZERO CROSSING.
        //
        // `width_ == 0` is the kernel-side "build nothing" branch below, and
        // dragging the width down through zero and back makes the bevel
        // geometry disappear and reappear. A key of (mask, roundLevel) alone
        // would not move across either crossing while the topology moved
        // twice, so the degenerate predicate is part of the key rather than a
        // case beside it. `widthMode` only reinterprets the width (a
        // position quantity), but it is a dropdown that changes at human
        // speed: keying it costs an occasional extra full rebuild and buys
        // not having to prove that no width mode can collapse a face.
        size_t n = preview_.run(*mesh, before,
            (ref Mesh cage) => PreviewTopologyKey.make(cage.operandEdgeMask(),
                                                       width_ == 0.0f,
                                                       roundLevel_,
                                                       widthMode_ ? 1 : 0),
            (ref Mesh target) {
                if (width_ == 0.0f) return cast(size_t)0;
                // Task 1903 Stage G — the PER-FRAME PREVIEW's batch, opened
                // INSIDE this kernel lambda rather than by changing
                // `preview_.run`'s delegate signature (plan §9.1 as corrected
                // at Stage F2, памятка 41). `target` IS the private cage on
                // the placement path and IS the live mesh on the key-changed
                // full-rebuild path, so the batch lands on whichever mesh the
                // kernel actually got — both of §9.1's consequences, with no
                // edit to a seam that still serves `mesh_ops/extrude.d`
                // (Stage H).
                //
                // UNRECORDED, and that is §9's whole point: a preview frame
                // must record NOTHING. `changeBus.opLogEntriesRecorded` is
                // the row that says so across every frame;
                // `unbatchedGeometryCommits` is `g_isDocumentMesh`-FILTERED
                // (§3.2 L2), so on a `PreviewRebuild` tool it witnesses the
                // full-rebuild frames only — a weaker statement, and the
                // suite cell says which it is making (памятка 40).
                auto ed = MeshEditBatch.unrecorded(target, kEdgeBevelEditScope);
                immutable size_t nPrev =
                    ed.bevelEdgesByMask(target.operandEdgeMask(),
                                        width_, roundLevel_, widthMode_);
                ed.close();
                return nPrev;
            });
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && width_ != 0 && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Edge Bevel");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.EdgeBevel,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Bevel");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        preview_.reset();
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }
}
