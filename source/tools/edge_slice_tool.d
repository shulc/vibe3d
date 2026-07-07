module tools.edge_slice_tool;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : round;
import ImGui = d_imgui;
import d_imgui.imgui_h;   // ImDrawList / ImVec2 / IM_COL32 for the `t = %` HUD

import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import hover_state : g_hoveredEdge;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment;

// The interactive commit reuses the generic before/after snapshot edit command
// (the same MeshBevelEdit the mirror / tack / Slice tools reuse for their
// one-shot snapshot undo), labelled "Edge Slice".
alias EdgeSliceEditFactory = MeshBevelEdit delegate();

/// The `t = %` HUD readout string — mirrors `loopSliceHudLabel`
/// (loop_slice_tool.d) so both slice-family tools print the same shape.
string edgeSliceHudLabel(float t) {
    import std.format : format;
    return format("%.2f %%", t * 100.0f);
}

unittest {
    assert(edgeSliceHudLabel(0.25f) == "25.00 %");
    assert(edgeSliceHudLabel(0.5f)  == "50.00 %");
    assert(edgeSliceHudLabel(0.0f)  == "0.00 %");
    assert(edgeSliceHudLabel(1.0f)  == "100.00 %");
}

private Vec3 lerpVec3(Vec3 a, Vec3 b, float t) {
    return a + (b - a) * t;
}

// ---------------------------------------------------------------------------
// EdgeSliceTool — interactive two-edge strip cut (factory id
// `mesh.edgeSliceTool`), driving the EXISTING `Mesh.edgeSlice(edgeA, edgeB,
// tA, tB, splitPolygons)` kernel unchanged. Coexists with the one-shot
// `mesh.edgeSlice` command (source/commands/mesh/edge_slice.d) — untouched.
//
// Gesture (mirrors LoopSliceTool's mutate/revert armed-preview model, adapted
// to a two-edge phased latch): hover an edge (HoverEdges capability) → click
// latches edge A (`tA` derived from the click's projection onto the edge,
// kernel `[0]->[1]` order) → drag scrubs `tA` while the mouse is held → click
// a second, different edge latches edge B (`tB`) and immediately materialises
// a live preview cut on the real mesh (mutate/revert, non-cumulative) → the
// preview STANDS across frames until Enter / tool-drop / a third click, which
// commits the pair as ONE undo entry and re-seeds the click as a fresh edge A
// (chainable two-edge cuts, each its own undo).
//
// Headless (`tool.set mesh.edgeSliceTool on; tool.attr ... edges [eA,eB]; ...;
// tool.doApply`) reads `edgesParam_`/`tA_`/`tB_`/`split_` directly and NEVER
// touches `armed_`/`scrubbing_`/session state — `ToolDoApplyCommand` wraps its
// own snapshot pair around `applyHeadless()`.
// ---------------------------------------------------------------------------
final class EdgeSliceTool : Tool {
public:
    enum Show { None, Position }

    static immutable IntEnumEntry[2] showTable = [
        IntEnumEntry(cast(int)Show.None,     "none",     "None"),
        IntEnumEntry(cast(int)Show.Position, "position", "Position"),
    ];

    enum Phase { Idle, EdgeA, EdgeB }

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
    EdgeSliceEditFactory factory;

    // Panel params (sticky — NOT reset by reinitSession/activate, matching
    // Slice/Loop-Slice's other tool options).
    bool  split_  = true;
    bool  middle_ = false;
    float snap_   = 0.5f;
    Show  show_   = Show.Position;

    // Headless "edges" param (IntArray) — kept in sync with edgeA_/edgeB_ by
    // the interactive latch so the two paths converge on one kernel call.
    uint[] edgesParam_;

    // Latch state (per-gesture, reset by reinitSession/dropArmedPreview).
    int   edgeA_ = -1;
    int   edgeB_ = -1;
    float tA_    = 0.5f;
    float tB_    = 0.5f;
    Phase phase_ = Phase.Idle;

    // Latched edge rails, world space, in the KERNEL's `[0]->[1]` direction
    // (mesh.edges[e][0..1]) — so the click->t projection and the drawn handle
    // agree with where `Mesh.edgeSlice` actually cuts.
    Vec3 railA0_, railA1_;
    Vec3 railB0_, railB1_;

    // Session state (mirrors LoopSliceTool's Model B: arm-then-commit
    // standing preview).
    bool         active;
    bool         armed_;       // a standing two-edge preview sits on the real mesh
    bool         scrubbing_;   // a latched edge's `t` is being dragged
    bool         built_;       // true once the last rebuildPreview() materialised a cut
    int          dragPart_ = -1;
    MeshSnapshot before_;      // idle baseline: mesh == before_ whenever !armed_
    MeshCacheKey armedKey_;    // mesh identity+version guard (scene reset / layer switch)
    Viewport     cachedVp;

    // Cut-point handles (lazily built inside a live GL context).
    BoxHandler  handleA_, handleB_;
    ToolHandles toolHandles_;

    enum float HANDLE_HALF_PX = 5.0f;
    enum Vec3  HANDLE_COLOR = Vec3(0.30f, 0.60f, 1.00f);
    enum Vec3  CHORD_COLOR  = Vec3(0.90f, 0.92f, 0.98f);

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
    }

    void setUndoBindings(CommandHistory h, EdgeSliceEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Edge Slice"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    // HoverEdges: needed so app.d's picker keeps writing g_hoveredEdge while
    // this tool owns the viewport (pickEdges() gates on wantsHoverForType).
    override ToolFlag flags() const { return ToolFlag.HoverEdges; }

    // Freezes the hover pick during a scrub — only the latched edge stays
    // highlighted while its `t` is being dragged.
    override bool isDragging() const { return scrubbing_; }

    override Param[] params() {
        return [
            Param.intArray_("edges", "Edges", &edgesParam_).transient(),
            Param.float_("tA", "t on Edge A", &tA_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.float_("tB", "t on Edge B", &tB_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.bool_("split", "Split Polygons", &split_, true),
            Param.bool_("middle", "Split at Middle", &middle_, false),
            Param.float_("snap", "Snap Value", &snap_, 0.5f).min(0.0f),
            Param.intEnum_("show", "Show", cast(int*)&show_, showTable, cast(int)Show.Position),
        ];
    }

    // Pure `t` law shared by BOTH the interactive scrub (tFromClick) and the
    // headless path (applyHeadless) so they never diverge: Split at Middle
    // forces 0.5 first, then Snap Value quantizes, then clamp to the kernel's
    // open interval.
    public float effectiveT(float raw) const {
        float t = middle_ ? 0.5f : raw;
        if (snap_ > 0.0f) {
            float step = snap_ / 100.0f;
            t = round(t / step) * step;
        }
        enum float eps = 1e-4f;
        if (t < eps)        t = eps;
        if (t > 1.0f - eps) t = 1.0f - eps;
        return t;
    }

    // Test-introspection (GET /api/tool/state) — mirrors LoopSliceTool.toolStateJson.
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("edgeSlice");
        root["hoveredEdge"] = JSONValue(g_hoveredEdge);
        root["edgeA"]       = JSONValue(edgeA_);
        root["edgeB"]       = JSONValue(edgeB_);
        root["tA"]          = JSONValue(effectiveT(tA_));
        root["tB"]          = JSONValue(effectiveT(tB_));
        final switch (phase_) {
            case Phase.Idle:  root["phase"] = JSONValue("idle");  break;
            case Phase.EdgeA: root["phase"] = JSONValue("edgeA"); break;
            case Phase.EdgeB: root["phase"] = JSONValue("edgeB"); break;
        }
        root["armed"]  = JSONValue(armed_);
        root["built"]  = JSONValue(built_);
        root["split"]  = JSONValue(split_);
        root["middle"] = JSONValue(middle_);
        root["snap"]   = JSONValue(snap_);
        root["show"]   = JSONValue(wireTagForValue(showTable, cast(int)show_));
        return root;
    }

    // Test-introspection (GET /api/tool/handles) — parts 0 (edge A) / 1 (edge B).
    override JSONValue toolHandlesJson() const {
        return toolHandles_ is null ? JSONValue(null) : toolHandles_.toJson(cachedVp);
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        armed_     = false;
        scrubbing_ = false;
        built_     = false;
        phase_     = Phase.Idle;
        edgeA_     = -1;
        edgeB_     = -1;
        tA_        = 0.5f;
        tB_        = 0.5f;
        edgesParam_ = [];
        dragPart_  = -1;
        // split_/middle_/snap_/show_ deliberately NOT reset — sticky tool
        // options, matching Slice's other panel settings (Loop-Slice, unlike
        // Slice, DOES reset its own options in reinitSession — not the
        // analogue here).
        armedKey_.invalidate();
        before_ = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // An armed+built standing preview is a deliberate placement — commit
        // it on tool-drop, same as Loop Slice. An armed-but-unbuilt edge case
        // cancels instead. Both self-guard against a mesh swapped out from
        // under us via armedKey_ (see commitEdit/cancelLiveEdit) — but for the
        // two KNOWN swap sites (scene.reset/file.new, active-layer switch)
        // app.d calls dropArmedPreview() explicitly BEFORE this ever runs.
        if (active && armed_) {
            if (built_) commitEdit();
            else        cancelLiveEdit();
        }
        active = false;
        dropArmedPreview();
        // Release the cut-point handles' GL objects (VAO+VBO each) — a fresh
        // tool instance is built per activation, so without this every
        // activate->draw->deactivate cycle leaks 2 VAOs + 2 VBOs.
        if (handleA_ !is null) { handleA_.destroy(); handleA_ = null; }
        if (handleB_ !is null) { handleB_.destroy(); handleB_ = null; }
    }

    public override bool hasUncommittedEdit() const {
        return active && armed_;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // A standing armed preview sits on the mesh across arbitrary frames, so a
    // REDO reachable while armed must cancel it first (mirrors LoopSliceTool).
    public override bool cancelsOnRedo() const {
        return active && armed_;
    }

    public override void resyncSession() {
        if (!active) return;
        if (armed_)  return;   // only commit/cancel may end an armed session
        reinitSession();
    }

    /// Discard the standing preview WITHOUT touching the mesh or recording
    /// anything to history. Safe to call even when nothing is armed, and safe
    /// to call AFTER the underlying mesh has already been swapped out from
    /// under this tool (scene.reset / active-layer switch) — see the two
    /// swap-site call sites in app.d.
    public void dropArmedPreview() {
        armed_      = false;
        scrubbing_  = false;
        built_      = false;
        phase_      = Phase.Idle;
        edgeA_      = -1;
        edgeB_      = -1;
        edgesParam_ = [];
        dragPart_   = -1;
        armedKey_.invalidate();
    }

    override void evaluate() {}

    // A panel edit of a geometry-affecting option while a preview is armed
    // must refresh it immediately (mirrors LoopSliceTool's onParamChanged
    // convention) — otherwise toggling Split Polygons / Split at Middle /
    // Snap Value, or editing tA/tB directly (rather than scrubbing the
    // handle), would silently wait for the next scrub to take effect.
    // `show` is display-only and never touches geometry.
    override void onParamChanged(string pname) {
        if (!armed_) return;
        if (pname == "split" || pname == "middle" || pname == "snap"
            || pname == "tA" || pname == "tB")
            rebuildPreview();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Reads edgesParam_/tA_/tB_/split_ ONLY —
    // MUST NOT touch armed_/scrubbing_/phase_/session state; ToolDoApplyCommand
    // wraps this with its own snapshot pair.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        if (edgesParam_.length != 2) return false;
        size_t nSplit = mesh.edgeSlice(edgesParam_[0], edgesParam_[1],
                                       effectiveT(tA_), effectiveT(tB_), split_);
        if (nSplit == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Edges)    return false;

        final switch (phase_) {
            case Phase.Idle: {
                int h = g_hoveredEdge;
                if (h < 0 || h >= cast(int)mesh.edges.length) return false;
                latchEdgeA(h, cast(float)e.x, cast(float)e.y);
                return true;
            }
            case Phase.EdgeA: {
                int h = g_hoveredEdge;
                if (h < 0 || h >= cast(int)mesh.edges.length || h == edgeA_) return false;
                edgeB_  = h;
                railB0_ = mesh.vertices[mesh.edges[edgeB_][0]];
                railB1_ = mesh.vertices[mesh.edges[edgeB_][1]];
                tB_     = tFromClick(railB0_, railB1_, cast(float)e.x, cast(float)e.y);
                phase_      = Phase.EdgeB;
                armed_      = true;
                scrubbing_  = true;
                dragPart_   = 1;
                edgesParam_ = [cast(uint)edgeA_, cast(uint)edgeB_];
                armedKey_.stamp(*mesh);
                rebuildPreview();
                return true;
            }
            case Phase.EdgeB: {
                // Bake the current two-edge cut as one undo entry, then treat
                // this click as a fresh Idle -> EdgeA on the hovered edge
                // (chainable two-edge cuts, each its own undo).
                if (built_) commitEdit(); else cancelLiveEdit();
                int h = g_hoveredEdge;
                if (h < 0 || h >= cast(int)mesh.edges.length) return true;
                latchEdgeA(h, cast(float)e.x, cast(float)e.y);
                return true;
            }
        }
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        final switch (phase_) {
            case Phase.Idle:
                return false;   // unreachable while scrubbing_
            case Phase.EdgeA:
                tA_ = tFromClick(railA0_, railA1_, cast(float)e.x, cast(float)e.y);
                return true;
            case Phase.EdgeB:
                tB_ = tFromClick(railB0_, railB1_, cast(float)e.x, cast(float)e.y);
                if (armed_) rebuildPreview();
                return true;
        }
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        scrubbing_ = false;
        dragPart_  = -1;
        // Model B: mouse-up never commits — the preview (once built) STAYS
        // armed until Enter / tool-drop / a third click.
        return true;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || !armed_) return false;
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                commitEdit();
                return true;
            case SDLK_ESCAPE:
                cancelLiveEdit();
                return true;
            default:
                return false;
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        if (!visualOnly) cachedVp = vp;
        if (!active) return;
        if (phase_ == Phase.Idle) return;

        if (handleA_ is null) {
            handleA_     = new BoxHandler(railA0_, HANDLE_COLOR);
            handleB_     = new BoxHandler(railB0_, HANDLE_COLOR);
            toolHandles_ = new ToolHandles();
        }

        immutable float handleScale = HANDLE_HALF_PX / getGizmoPixels();

        float teA  = effectiveT(tA_);
        Vec3  posA = lerpVec3(railA0_, railA1_, teA);
        handleA_.pos  = posA;
        handleA_.size = gizmoSize(posA, vp, handleScale);

        bool haveB = phase_ == Phase.EdgeB;
        float teB  = 0.0f;
        Vec3  posB;
        if (haveB) {
            teB  = effectiveT(tB_);
            posB = lerpVec3(railB0_, railB1_, teB);
            handleB_.pos  = posB;
            handleB_.size = gizmoSize(posB, vp, handleScale);
        }

        if (haveB)
            drawWorldSegment(posA, posB, vp, CHORD_COLOR, 2.0f, shader.program);

        toolHandles_.begin();
        toolHandles_.add(handleA_, 0);
        if (haveB) toolHandles_.add(handleB_, 1);
        toolHandles_.setHaul(dragPart_);
        int mx, my;
        queryMouse(mx, my);
        toolHandles_.update(mx, my, vp);

        handleA_.draw(shader, vp);
        if (haveB) handleB_.draw(shader, vp);

        if (show_ == Show.Position)
            drawHud(vp, haveB ? posB : posA, haveB ? teB : teA);
    }

private:
    void latchEdgeA(int h, float sx, float sy) {
        edgeA_  = h;
        railA0_ = mesh.vertices[mesh.edges[edgeA_][0]];
        railA1_ = mesh.vertices[mesh.edges[edgeA_][1]];
        tA_     = tFromClick(railA0_, railA1_, sx, sy);
        phase_      = Phase.EdgeA;
        scrubbing_  = true;
        dragPart_   = 0;
        edgesParam_ = [cast(uint)edgeA_];
    }

    // Compose the two existing helpers exactly as LoopSliceTool's mesh-drag
    // does: screenPointToRay -> closestPointOnSegmentToRay -> reproject onto
    // the (unclamped) segment direction to recover the scalar t, then apply
    // the panel's effectiveT law (Split at Middle / Snap Value / clamp).
    float tFromClick(Vec3 rail0, Vec3 rail1, float sx, float sy) const {
        Vec3 origin, dir;
        screenPointToRay(sx, sy, cachedVp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(rail0, rail1, origin, dir);
        Vec3 ab = rail1 - rail0;
        float denom = dot(ab, ab);
        float raw = denom > 1e-12f ? dot(hit - rail0, ab) / denom : 0.5f;
        return effectiveT(raw);
    }

    void drawHud(const ref Viewport vp, Vec3 anchor, float t) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(anchor, vp, sx, sy, ndcZ)) return;
        ImDrawList* dl = ImGui.GetForegroundDrawList();
        string label = edgeSliceHudLabel(t);
        dl.AddText(ImVec2(sx + 10.0f, sy - 8.0f), IM_COL32(255, 255, 255, 235), label);
    }

    // The mutate/revert preview: restore the idle baseline, then reapply the
    // cut from the latched edgeA_/edgeB_ (valid again immediately after the
    // restore). Guarded by armedKey_: if the mesh underneath an armed preview
    // was swapped/clobbered by something else since our last touch, drop the
    // preview instead of restoring/cutting against the WRONG mesh.
    void rebuildPreview() {
        if (!before_.filled || edgeA_ < 0 || edgeB_ < 0) return;
        if (!armedKey_.matches(*mesh)) { dropArmedPreview(); return; }
        before_.restore(*mesh);
        size_t n = mesh.edgeSlice(cast(uint)edgeA_, cast(uint)edgeB_,
                                  effectiveT(tA_), effectiveT(tB_), split_);
        built_ = n > 0;
        armedKey_.stamp(*mesh);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null || !before_.filled) return;
        if (!armedKey_.matches(*mesh)) {
            // The mesh underneath us was swapped/clobbered since our last
            // touch — nothing safely ours to commit. Drop instead of
            // fabricating a bogus undo entry against the wrong mesh.
            dropArmedPreview();
            return;
        }
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Edge Slice");
        history.record(cmd);
        // Re-arm: the just-committed state becomes the new idle baseline so
        // the tool is ready for another cut (each cut its own undo entry).
        before_ = post;
        dropArmedPreview();
    }

    void cancelLiveEdit() {
        if (armedKey_.matches(*mesh) && before_.filled) before_.restore(*mesh);
        dropArmedPreview();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
