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
// EdgeSliceTool — interactive N-cut chain (factory id `mesh.edgeSliceTool`),
// driving the EXISTING `Mesh.edgeSliceEx(edgeA, edgeB, tA, tB, splitPolygons)`
// kernel unchanged. Coexists with the one-shot `mesh.edgeSlice` command
// (source/commands/mesh/edge_slice.d) — untouched.
//
// Gesture (task 0295, F2 — supersedes the two-edge-only v1 model): hover an
// edge (HoverEdges capability) -> click LATCHES a chain point (edge + `t`
// derived from the click's projection) -> drag scrubs that point's `t` while
// the mouse is held -> click a second, DISTINCT edge latches a second point
// and immediately materialises a live preview cut on the real mesh
// (mutate/revert, non-cumulative) -> a THIRD+ click EXTENDS the chain (does
// NOT commit-and-reseed — the v1 behaviour this replaces): each new point
// slices a strip from the previous point's exact cut vertex to the new one,
// via the SAME `Mesh.edgeSliceEx`. The whole chain stands as ONE uncommitted
// preview across frames until Enter / tool-drop, which commits every latched
// segment as ONE undo entry.
//
// F1 (task 0295): a click landing at t=0/1 (an edge endpoint) is a valid
// cut — the kernel reuses the existing corner vertex instead of inserting a
// coincident one (see `insertEdgePoint`, mesh.d). This is also the mechanism
// that lets a chain segment continue exactly from the previous segment's
// shared cut vertex (`pickSeedSubEdge` below).
//
// Headless (`tool.set mesh.edgeSliceTool on; tool.attr ... edges [e0,e1,...];
// ...; tool.doApply`) reads `edgesParam_`/`tA_`/`tB_`/`split_` directly and
// NEVER touches `armed_`/`scrubbing_`/session state — `ToolDoApplyCommand`
// wraps its own snapshot pair around `applyHeadless()`. A deterministic
// `chainArm` trigger param (picker-free) arms the SAME chain state a click
// sequence would produce, without committing, so a synthetic Enter / tool-off
// can exercise the real interactive commit path in a test.
// ---------------------------------------------------------------------------
final class EdgeSliceTool : Tool {
public:
    enum Show { None, Position }

    static immutable IntEnumEntry[2] showTable = [
        IntEnumEntry(cast(int)Show.None,     "none",     "None"),
        IntEnumEntry(cast(int)Show.Position, "position", "Position"),
    ];

    enum Phase { Idle, EdgeA, EdgeB }

    // A latched chain click: the edge's endpoint VERTEX PAIR (stable across
    // an intervening edgeSliceEx's rebuildEdges() — vertex indices only ever
    // grow, mesh.d:10445) plus a click `t`. The live edge is re-resolved each
    // bake via `Mesh.edgeIndexOf(v0, v1)`.
    //
    // S2: `t`'s meaning differs by producer — `tFromClick` (interactive
    // latch/scrub path) already returns `effectiveT(raw)`, so `t` here is the
    // EFFECTIVE value; `pointsFromEdgesParam` (headless `edges`-param path)
    // stores the RAW panel value (`tA_`/`tB_`/0.5f interior) straight through,
    // unconverted. Both `bakeChainFrom` and `chainPointPos` re-apply
    // `effectiveT(p.t)` unconditionally, which is safe for the
    // already-effective interactive case ONLY because `effectiveT` is
    // idempotent (re-clamping/re-snapping/re-forcing-to-middle an already
    // effective value reproduces it) — so the double application never
    // changes the interactive path's result.
    private struct ChainPoint { uint v0, v1; float t; }

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

    // Headless "edges" param (IntArray) — the ordered chain edge list.
    // Kept in sync with latchedPoints_ by the interactive latch so the two
    // paths converge on the same kernel calls.
    uint[] edgesParam_;

    // Deterministic commit driver (task 0295, F2, objection 2 — picker-free
    // test coverage of commitChain/deactivate-commit). Its VALUE is unused —
    // writing it is purely a trigger; onParamChanged("chainArm") reads
    // edgesParam_ fresh and arms the chain it describes without committing.
    uint[] chainArm_;

    // Confirmed chain points — advances ONLY at click-latch (or chainArm),
    // clears ONLY at commit/cancel. NEVER mutated by preview rebuilds.
    ChainPoint[]  latchedPoints_;
    MeshSnapshot  chainBefore_;   // the ONE undo baseline for the whole chain

    // Headless-only "first t" / "last t" (interior points default to 0.5 —
    // a deliberate v1 surface limitation, see pointsFromEdgesParam). Also
    // double as panel params for the LAST interactively-latched point's
    // scrub display (see onMouseMotion).
    float tA_ = 0.5f;
    float tB_ = 0.5f;
    Phase phase_ = Phase.Idle;

    // Session state (mirrors LoopSliceTool's Model B: arm-then-commit
    // standing preview), generalised from a single pair to an N-point chain.
    bool         active;
    bool         armed_;       // >=2 points latched -> a standing preview sits on the real mesh
    bool         scrubbing_;   // the last latched point's `t` is being dragged
    bool         built_;       // true once the last bake actually produced a cut
    int          dragPart_ = -1;
    MeshCacheKey armedKey_;    // mesh identity+version guard (scene reset / layer switch)
    Viewport     cachedVp;

    // Active-point index (task 0321, D2) — which `latchedPoints_[]` entry a
    // scrub/drag or a numeric `activePoint`/`pointT` panel edit targets. Set
    // by every latch producer (latchFirstPoint/appendPoint/armChain) to the
    // point it just latched, and by a re-pick press (onMouseButtonDown, D3)
    // to whichever earlier handle was grabbed. `pointProxy_` is the
    // Param-bound mirror of `latchedPoints_[activePoint_].t`, exactly
    // LoopSliceTool's `positionProxy_` <-> `positions_[current_]` pattern.
    int          activePoint_ = -1;
    float        pointProxy_  = 0.5f;

    // Cut-point handles (lazily built inside a live GL context) — one per
    // latched point, plus one for the pending (hover-derived) point.
    BoxHandler[] handles_;
    ToolHandles  toolHandles_;

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
            Param.intArray_("chainArm", "Chain Arm", &chainArm_).transient(),
            Param.float_("tA", "t on Edge A", &tA_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.float_("tB", "t on Edge B", &tB_, 0.5f).min(0.0f).max(1.0f).transient(),
            // Active-point index + numeric edit (task 0321, D2) — re-targets
            // any already-latched chain point (not just the tail) for a
            // panel-driven `t` edit; also the picker-free test driver for the
            // re-pick+drag gesture (D3).
            Param.int_("activePoint", "Active Point", &activePoint_, -1).transient(),
            Param.float_("pointT", "Point t", &pointProxy_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.bool_("split", "Split Polygons", &split_, true),
            Param.bool_("middle", "Split at Middle", &middle_, false),
            Param.float_("snap", "Snap Value", &snap_, 0.5f).min(0.0f),
            Param.intEnum_("show", "Show", cast(int*)&show_, showTable, cast(int)Show.Position),
        ];
    }

    // Pure `t` law shared by BOTH the interactive scrub (tFromClick) and the
    // headless path (applyHeadless) so they never diverge: Split at Middle
    // forces 0.5 first, then Snap Value quantizes, then clamp to the closed
    // unit interval. task 0295 F1: the clamp is CLOSED ([0,1]) — t==0/1 is a
    // valid endpoint cut (the kernel reuses the corner instead of inserting a
    // coincident vertex there), so it no longer needs the open-interval
    // buffer the pre-F1 tool used.
    public float effectiveT(float raw) const {
        float t = middle_ ? 0.5f : raw;
        if (snap_ > 0.0f) {
            float step = snap_ / 100.0f;
            t = round(t / step) * step;
        }
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;
        return t;
    }

    // Test-introspection (GET /api/tool/state) — mirrors LoopSliceTool.toolStateJson.
    // edgeA/tA report the FIRST latched point, edgeB/tB the LAST — so a
    // replay test can assert chain growth (edgeB advances with every click;
    // edgeA is stable since the chain's first point is never re-cut).
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("edgeSlice");
        root["hoveredEdge"] = JSONValue(g_hoveredEdge);

        int   edgeAOut = -1, edgeBOut = -1;
        float tAOut = 0.5f, tBOut = 0.5f;
        if (latchedPoints_.length > 0) {
            auto first = latchedPoints_[0];
            auto last  = latchedPoints_[$ - 1];
            edgeAOut = cast(int)mesh.edgeIndexOf(first.v0, first.v1);
            edgeBOut = cast(int)mesh.edgeIndexOf(last.v0, last.v1);
            tAOut    = effectiveT(first.t);
            tBOut    = effectiveT(last.t);
        }
        root["edgeA"] = JSONValue(edgeAOut);
        root["edgeB"] = JSONValue(edgeBOut);
        root["tA"]    = JSONValue(tAOut);
        root["tB"]    = JSONValue(tBOut);
        final switch (phase_) {
            case Phase.Idle:  root["phase"] = JSONValue("idle");  break;
            case Phase.EdgeA: root["phase"] = JSONValue("edgeA"); break;
            case Phase.EdgeB: root["phase"] = JSONValue("edgeB"); break;
        }
        root["armed"]  = JSONValue(armed_);
        root["built"]  = JSONValue(built_);
        root["activePoint"] = JSONValue(activePoint_);
        root["pointT"]      = JSONValue(pointProxy_);
        root["split"]  = JSONValue(split_);
        root["middle"] = JSONValue(middle_);
        root["snap"]   = JSONValue(snap_);
        root["show"]   = JSONValue(wireTagForValue(showTable, cast(int)show_));
        // Pure derivation (NOT a counter) — the number of BAKED segments the
        // current latched chain describes.
        root["chainSegments"] = JSONValue(
            latchedPoints_.length >= 1 ? cast(long)(latchedPoints_.length - 1) : 0L);
        return root;
    }

    // Test-introspection (GET /api/tool/handles) — one part per latched point
    // plus the pending one (see draw()).
    override JSONValue toolHandlesJson() const {
        return toolHandles_ is null ? JSONValue(null) : toolHandles_.toJson(cachedVp);
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        armed_      = false;
        scrubbing_  = false;
        built_      = false;
        phase_      = Phase.Idle;
        latchedPoints_ = [];
        edgesParam_    = [];
        dragPart_   = -1;
        activePoint_ = -1;
        // split_/middle_/snap_/show_ deliberately NOT reset — sticky tool
        // options, matching Slice's other panel settings (Loop-Slice, unlike
        // Slice, DOES reset its own options in reinitSession — not the
        // analogue here).
        armedKey_.invalidate();
        chainBefore_ = MeshSnapshot.init;
    }

    override void deactivate() {
        // A chain of >=2 latched points is a deliberate placement — commit it
        // on tool-drop, same as Loop Slice, REGARDLESS of whether a pending
        // (unlatched) tip was being previewed. A lone latched point (or none)
        // has nothing worth keeping, so it cancels instead.
        if (active) {
            if (latchedPoints_.length >= 2) commitChain();
            else                            cancelLiveEdit();
        }
        active = false;
        dropArmedPreview();
        // Release the cut-point handles' GL objects (VAO+VBO each) — a fresh
        // tool instance is built per activation, so without this every
        // activate->draw->deactivate cycle leaks a VAO+VBO per handle.
        foreach (h; handles_) if (h !is null) h.destroy();
        handles_ = [];
    }

    public override bool hasUncommittedEdit() const {
        return active && (armed_ || latchedPoints_.length > 0);
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // A standing armed preview (or even a lone latched point) sits on the
    // mesh across arbitrary frames, so a REDO reachable while any chain state
    // is live must cancel it first (mirrors LoopSliceTool).
    public override bool cancelsOnRedo() const {
        return active && (armed_ || latchedPoints_.length > 0);
    }

    // Mid-chain per-click undo peel (task 0321, D1). Reached from the app's
    // navHistory() chokepoint BEFORE its whole-edit cancel branch: while a
    // live latched chain exists, Ctrl+Z peels exactly the LAST latched point
    // (keeping earlier ones) instead of unwinding the whole chain and
    // dropping the tool. Returns false once the chain is empty (committed or
    // never started), so navHistory falls through to the ordinary
    // hasUncommittedEdit()/history.undo() path — the post-commit whole-chain
    // undo (chainBefore_ + the single MeshBevelEdit at commitChain) is
    // completely unaffected: dropArmedPreview() has already cleared
    // latchedPoints_ by the time a commit lands.
    override bool tryUndoStepInSession() {
        if (!active || latchedPoints_.length == 0) return false;
        peelLastPoint();
        return true;
    }

    public override void resyncSession() {
        if (!active) return;
        if (armed_ || latchedPoints_.length > 0) return;   // only commit/cancel may end a live chain
        reinitSession();
    }

    /// Discard the standing preview WITHOUT touching the mesh or recording
    /// anything to history. Safe to call even when nothing is armed, and safe
    /// to call AFTER the underlying mesh has already been swapped out from
    /// under this tool (scene.reset / active-layer switch) — see the two
    /// swap-site call sites in app.d.
    public void dropArmedPreview() {
        armed_         = false;
        scrubbing_     = false;
        built_         = false;
        phase_         = Phase.Idle;
        latchedPoints_ = [];
        edgesParam_    = [];
        dragPart_      = -1;
        activePoint_   = -1;
        armedKey_.invalidate();
        chainBefore_   = MeshSnapshot.init;
    }

    override void evaluate() {}

    // A panel edit of a geometry-affecting option while a preview is armed
    // must refresh it immediately (mirrors LoopSliceTool's onParamChanged
    // convention) — otherwise toggling Split Polygons / Split at Middle /
    // Snap Value, or editing tA/tB directly (rather than scrubbing the
    // handle), would silently wait for the next scrub to take effect.
    // `show` is display-only and never touches geometry.
    //
    // `chainArm` (task 0295, F2, objection 2) runs BEFORE the `!armed_` guard
    // — it is the deterministic, picker-free chain driver: it arms the exact
    // chain state a click sequence over edgesParam_ would produce, without
    // committing, so a subsequent real Enter / tool-drop exercises the
    // genuine commitChain()/deactivate() path.
    override void onParamChanged(string pname) {
        if (pname == "chainArm") { armChain(); return; }
        // Active-point index + numeric `t` edit (task 0321, D2) — re-target
        // any latched point and re-bake via the same whole-polyline engine a
        // scrub/drag uses. Handled BEFORE the `!armed_` guard below: a
        // 1-point chain (phase_ EdgeA, not yet armed_) can still have its
        // sole point's `t` edited (rebuildPreview() is a harmless no-op restore
        // in that case — bakeChainFrom needs >=2 points to cut anything).
        if (pname == "activePoint") {
            int maxIdx = cast(int)latchedPoints_.length - 1;
            if (maxIdx < 0)                  activePoint_ = -1;
            else if (activePoint_ < 0)        activePoint_ = 0;
            else if (activePoint_ > maxIdx)   activePoint_ = maxIdx;
            syncProxy();
            return;
        }
        if (pname == "pointT") {
            // Bounds guard (task 0321 opponent fold, Risk #5) — a `pointT`
            // write must never index `latchedPoints_[-1]` or past the end,
            // e.g. right after a peel shrank the chain out from under a
            // stale `activePoint_`.
            if (activePoint_ < 0 || activePoint_ >= cast(int)latchedPoints_.length) return;
            latchedPoints_[activePoint_].t = pointProxy_;
            rebuildPreview();
            return;
        }
        if (!armed_) return;
        if (pname == "split" || pname == "middle" || pname == "snap"
            || pname == "tA" || pname == "tB")
            rebuildPreview();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Reads edgesParam_/tA_/tB_/split_ ONLY —
    // MUST NOT touch armed_/scrubbing_/phase_/latchedPoints_/session state;
    // ToolDoApplyCommand wraps this with its own snapshot pair. Accepts an
    // N-edge chain (length >= 2) via the SAME bakeChainFrom engine the
    // interactive path uses.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        auto pts = pointsFromEdgesParam();
        if (pts.length < 2) return false;
        auto baseline = MeshSnapshot.capture(*mesh);
        size_t n = bakeChainFrom(baseline, pts);
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
        if (*editMode != EditMode.Edges)    return false;

        // Re-pick (task 0321, D3): a press ON an already-latched point's
        // handle grabs IT as the drag target — "grab the point under the
        // cursor" rather than always scrubbing the tail. Checked BEFORE the
        // hovered-edge latch/append logic below. `part < latchedPoints_.length`
        // excludes the PENDING (hover-derived, not-yet-latched) handle draw()
        // registers at part==latchedPoints_.length, so a click on the pending
        // handle still falls through to the normal latch/append path below.
        if (toolHandles_ !is null && latchedPoints_.length >= 1) {
            int part = toolHandles_.test(cast(int)e.x, cast(int)e.y, cachedVp);
            if (part >= 0 && part < cast(int)latchedPoints_.length) {
                activePoint_ = part;
                syncProxy();
                scrubbing_   = true;
                dragPart_    = part;
                return true;
            }
        }

        int h = g_hoveredEdge;
        if (h < 0 || h >= cast(int)mesh.edges.length) return false;

        if (phase_ == Phase.Idle) {
            latchFirstPoint(h, cast(float)e.x, cast(float)e.y);
            return true;
        }

        // EdgeA (1 point latched) or EdgeB (>=2 latched): a further click
        // EXTENDS the chain (task 0295, F2) — it no longer commits+reseeds
        // (the v1 behaviour this replaces). Reject a click on the SAME edge
        // as the last latched point (no zero-length segment).
        //
        // S3: explicit uint comparison rather than `cast(int)lastEdge == h`
        // — the old form only worked because edgeIndexOf's ~0u "not found"
        // sentinel casts to -1, which can never coincide with `h` (already
        // guarded non-negative above); that safety was implicit in the
        // wraparound, not stated. Guard the sentinel by name instead.
        uint lastEdge = mesh.edgeIndexOf(latchedPoints_[$ - 1].v0, latchedPoints_[$ - 1].v1);
        if (lastEdge != ~0u && lastEdge == cast(uint)h) return false;
        appendPoint(h, cast(float)e.x, cast(float)e.y);
        return true;
    }

    // Only touches the mesh (via rebuildPreview) while ACTIVELY SCRUBBING an
    // already-latched point AND armed_ (>=2 points, so a bake is meaningful).
    // Mere hovering between clicks must NEVER mutate the mesh: the app's own
    // picker (g_hoveredEdge) is re-evaluated against whatever the CURRENT
    // mesh looks like, so a speculative hover-triggered cut would desync the
    // NEXT click's captured vertex pair from chainBefore_'s indices (a
    // restore-then-index-out-of-bounds hazard). The "live between click 1
    // and click 2" preview is covered by draw()'s own non-mutating
    // hover-derived pending point/line — no mesh write needed for that.
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_ || latchedPoints_.length == 0) return false;
        // Generalised (task 0321, D2/D3) from the hard-wired last point to
        // `activePoint_` — set to the tail by latchFirstPoint/appendPoint/
        // armChain, or to a re-picked earlier point by onMouseButtonDown.
        if (activePoint_ < 0 || activePoint_ >= cast(int)latchedPoints_.length) return false;
        auto p = latchedPoints_[activePoint_];
        latchedPoints_[activePoint_].t = tFromClick(
            mesh.vertices[p.v0], mesh.vertices[p.v1],
            cast(float)e.x, cast(float)e.y);
        syncProxy();
        if (armed_) rebuildPreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        scrubbing_ = false;
        dragPart_  = -1;
        // Model B: mouse-up never commits — the preview (once built) STANDS
        // until Enter / tool-drop / another click extends it.
        return true;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || latchedPoints_.length == 0) return false;
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                commitChain();
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
        if (!active || latchedPoints_.length == 0) return;

        Vec3[] positions;
        positions.length = latchedPoints_.length;
        foreach (i, p; latchedPoints_) positions[i] = chainPointPos(p);

        // The pending (hover-derived, not-yet-latched) point — previews the
        // NEXT segment live (a strict superset of v1's "preview only after
        // the 2nd click"; deliberate, topology unaffected).
        bool  havePending = false;
        Vec3  pendingPos;
        float pendingT = 0.0f;
        int h = g_hoveredEdge;
        if (h >= 0 && h < cast(int)mesh.edges.length) {
            uint lastEdge = mesh.edgeIndexOf(latchedPoints_[$ - 1].v0, latchedPoints_[$ - 1].v1);
            if (cast(int)lastEdge != h) {
                Vec3 r0 = mesh.vertices[mesh.edges[h][0]];
                Vec3 r1 = mesh.vertices[mesh.edges[h][1]];
                int mx, my;
                queryMouse(mx, my);
                pendingT    = tFromClick(r0, r1, cast(float)mx, cast(float)my);
                pendingPos  = lerpVec3(r0, r1, pendingT);
                havePending = true;
            }
        }

        size_t total = positions.length + (havePending ? 1 : 0);
        ensureHandleCount(total);

        immutable float handleScale = HANDLE_HALF_PX / getGizmoPixels();
        toolHandles_.begin();
        foreach (i, pos; positions) {
            handles_[i].pos  = pos;
            handles_[i].size = gizmoSize(pos, vp, handleScale);
            toolHandles_.add(handles_[i], cast(int)i);
        }
        if (havePending) {
            handles_[$ - 1].pos  = pendingPos;
            handles_[$ - 1].size = gizmoSize(pendingPos, vp, handleScale);
            toolHandles_.add(handles_[$ - 1], cast(int)(total - 1));
        }
        toolHandles_.setHaul(dragPart_);
        int mx, my;
        queryMouse(mx, my);
        toolHandles_.update(mx, my, vp);

        // Chords between consecutive LATCHED points are already baked into
        // the mesh (real edges — the normal edge-draw pass renders them); the
        // PENDING chord is the only one that needs an explicit world-space
        // line, since it isn't baked yet.
        if (havePending)
            drawWorldSegment(positions[$ - 1], pendingPos, vp, CHORD_COLOR, 2.0f, shader.program);

        foreach (hd; handles_) hd.draw(shader, vp);

        if (show_ == Show.Position) {
            Vec3  anchor = havePending ? pendingPos : positions[$ - 1];
            float t      = havePending ? pendingT   : effectiveT(latchedPoints_[$ - 1].t);
            drawHud(vp, anchor, t);
        }
    }

private:
    void latchFirstPoint(int h, float sx, float sy) {
        chainBefore_ = MeshSnapshot.capture(*mesh);
        ChainPoint p;
        p.v0 = mesh.edges[h][0];
        p.v1 = mesh.edges[h][1];
        p.t  = tFromClick(mesh.vertices[p.v0], mesh.vertices[p.v1], sx, sy);
        latchedPoints_ = [p];
        edgesParam_    = [cast(uint)h];
        phase_     = Phase.EdgeA;
        scrubbing_ = true;
        dragPart_  = 0;
        activePoint_ = 0;
        syncProxy();
        armedKey_.stamp(*mesh);
        // No cut yet — armed_/built_ stay false until a second point latches.
    }

    void appendPoint(int h, float sx, float sy) {
        ChainPoint p;
        p.v0 = mesh.edges[h][0];
        p.v1 = mesh.edges[h][1];
        p.t  = tFromClick(mesh.vertices[p.v0], mesh.vertices[p.v1], sx, sy);
        latchedPoints_ ~= p;
        edgesParam_    ~= cast(uint)h;
        armed_     = true;
        scrubbing_ = true;
        dragPart_  = cast(int)(latchedPoints_.length - 1);
        activePoint_ = cast(int)(latchedPoints_.length - 1);
        syncProxy();
        phase_     = Phase.EdgeB;
        armedKey_.stamp(*mesh);
        rebuildPreview();
    }

    // Deterministic chain driver (task 0295, F2, objection 2): reads
    // edgesParam_ fresh and arms the chain it describes without committing,
    // so a subsequent real onKeyDown/deactivate exercises the genuine
    // commitChain() path in a picker-free test.
    void armChain() {
        auto pts = pointsFromEdgesParam();
        if (pts.length < 2) return;
        latchedPoints_ = pts;
        activePoint_   = cast(int)latchedPoints_.length - 1;
        syncProxy();
        chainBefore_   = MeshSnapshot.capture(*mesh);
        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        // Stamp AFTER baking — bakeChainFrom mutates the mesh (bumps
        // mutationVersion), so stamping before it would leave armedKey_
        // stale the instant this returns, and commitChain()'s
        // armedKey_.matches() guard would then (wrongly) treat the just-armed
        // chain as clobbered-from-under-us and drop it without recording.
        armedKey_.stamp(*mesh);
        armed_ = true;
        built_ = n > 0;
        phase_ = Phase.EdgeB;
        // S1: bakeChainFrom just mutated the mesh — keep the GPU upload +
        // screen-space caches in step (mirrors rebuildPreview/commitChain),
        // so this stays consistent if ever exercised with a visible window.
        refreshCaches();
    }

    // Mid-chain per-click undo peel (task 0321, D1) — pops exactly the LAST
    // latched point, clamps every piece of chain state to the shrunk range
    // (including `activePoint_` — Risk #5), then re-bakes by the remaining
    // length:
    //   >=2 points left -> still a real chain: re-arm + re-bake the shorter
    //     polyline.
    //   ==1 point left  -> a lone point bakes NO cut; rebuildPreview()'s
    //     `bakeChainFrom` restores `chainBefore_` (the base mesh) via its own
    //     `pts.length < 2` guard.
    //   ==0 points left -> the mesh is ALREADY at `chainBefore_` (from the
    //     length-1 case above, or was never cut at all); just clear the
    //     session state (dropArmedPreview) WITHOUT touching the mesh again.
    //     The tool stays active-idle — NOT dropped — so a further Ctrl+Z
    //     falls through to the ordinary global history.
    void peelLastPoint() {
        if (latchedPoints_.length == 0) return;
        latchedPoints_.length = latchedPoints_.length - 1;
        if (edgesParam_.length > 0) edgesParam_.length = edgesParam_.length - 1;
        scrubbing_ = false;
        dragPart_  = -1;

        if (latchedPoints_.length >= 2) {
            armed_       = true;
            phase_       = Phase.EdgeB;
            activePoint_ = cast(int)(latchedPoints_.length - 1);
            syncProxy();
            rebuildPreview();
        } else if (latchedPoints_.length == 1) {
            armed_       = false;
            phase_       = Phase.EdgeA;
            activePoint_ = 0;
            syncProxy();
            rebuildPreview();
        } else {
            activePoint_ = -1;
            dropArmedPreview();
        }
    }

    // Keep the Param-bound `pointProxy_` mirror in sync with
    // `latchedPoints_[activePoint_].t` after any mutation not itself driven
    // by a "pointT" param write (a re-pick, a peel, a fresh latch) — mirrors
    // LoopSliceTool's `syncProxy`/`positionProxy_`.
    void syncProxy() {
        if (activePoint_ >= 0 && cast(size_t)activePoint_ < latchedPoints_.length)
            pointProxy_ = latchedPoints_[activePoint_].t;
    }

    // Build a ChainPoint[] from edgesParam_ against the CURRENT mesh — shared
    // by applyHeadless (baseline == current mesh, nothing cut yet) and
    // armChain (same precondition: the deterministic driver arms straight
    // from the idle mesh). Interior points (neither first nor last) default
    // to t=0.5, mirroring the kernel's own interior convention
    // (mesh.d edgeSlice's cutT[i]=0.5 for interior path edges) — headless
    // chains have no per-interior-t param (a deliberate v1 surface
    // limitation; interactive interior points cut at their clicked t).
    ChainPoint[] pointsFromEdgesParam() const {
        ChainPoint[] pts;
        if (edgesParam_.length < 2) return pts;
        pts.length = edgesParam_.length;
        foreach (i, ei; edgesParam_) {
            if (ei >= mesh.edges.length) return null;
            pts[i].v0 = mesh.edges[ei][0];
            pts[i].v1 = mesh.edges[ei][1];
            if (i == 0)                           pts[i].t = tA_;
            else if (i == edgesParam_.length - 1)  pts[i].t = tB_;
            else                                   pts[i].t = 0.5f;
        }
        return pts;
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

    Vec3 chainPointPos(ChainPoint p) const {
        return lerpVec3(mesh.vertices[p.v0], mesh.vertices[p.v1], effectiveT(p.t));
    }

    void drawHud(const ref Viewport vp, Vec3 anchor, float t) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(anchor, vp, sx, sy, ndcZ)) return;
        ImDrawList* dl = ImGui.GetForegroundDrawList();
        string label = edgeSliceHudLabel(t);
        dl.AddText(ImVec2(sx + 10.0f, sy - 8.0f), IM_COL32(255, 255, 255, 235), label);
    }

    void ensureHandleCount(size_t n) {
        while (handles_.length < n)
            handles_ ~= new BoxHandler(Vec3(0, 0, 0), HANDLE_COLOR);
        while (handles_.length > n) {
            handles_[$ - 1].destroy();
            handles_.length = handles_.length - 1;
        }
        if (toolHandles_ is null) toolHandles_ = new ToolHandles();
    }

    // -------------------------------------------------------------------
    // bakeChainFrom — the PURE per-frame re-bake (task 0295, F2, objection 1
    // — the earlier draft's bakeSegment mutated chain counters on every
    // onMouseMotion, corrupting the seed after the first frame). Restores
    // `baseline`, walks the polyline ONCE re-cutting each segment via
    // Mesh.edgeSliceEx, threading the kernel-returned cut vertex as the next
    // segment's exact seed. Mutates NO tool/chain state — `latchedPoints_`
    // only ever advances at click-latch/armChain and clears at commit/cancel.
    //
    // Returns the number of segments successfully baked (pts.length - 1 on
    // full success; a smaller count if a later segment's destination edge
    // doesn't resolve against `baseline` — see the linear-chain limit note
    // on pointsFromEdgesParam/pickSeedSubEdge — or fails to reach).
    // -------------------------------------------------------------------
    size_t bakeChainFrom(ref MeshSnapshot baseline, const ChainPoint[] pts) {
        if (pts.length < 2) { baseline.restore(*mesh); return 0; }
        baseline.restore(*mesh);

        uint seed = ~0u;   // no seed for segment 0 — origin resolves via pts[0]
        foreach (k; 0 .. pts.length - 1) {
            uint eB = mesh.edgeIndexOf(pts[k + 1].v0, pts[k + 1].v1);
            if (eB == ~0u) return k;   // destination not a live baseline edge

            Mesh.EdgeSliceResult r;
            if (k == 0) {
                uint eA = mesh.edgeIndexOf(pts[0].v0, pts[0].v1);
                if (eA == ~0u) return k;
                r = mesh.edgeSliceEx(eA, eB, effectiveT(pts[0].t), effectiveT(pts[1].t), split_);
            } else {
                uint sub = pickSeedSubEdge(seed, eB);
                if (sub == ~0u) return k;
                float endT = (mesh.edges[sub][0] == seed) ? 0.0f : 1.0f;
                r = mesh.edgeSliceEx(sub, eB, endT, effectiveT(pts[k + 1].t), split_);
            }
            // S4: this dead-end check is effectively inert whenever
            // split_==false — edgeSliceEx's points-only branch (mesh.d)
            // reports facesSplit=2 as a bare SUCCESS MARKER for any distinct,
            // in-range edge pair (no face-path/connectivity requirement at
            // all in that mode), so it can only ever be 0 or 2 here, never a
            // real "dead end" signal. It only bites when split_==true.
            if (r.facesSplit == 0) return k;
            seed = r.cutVertB;   // NEXT segment's exact seed — no position scanning
        }
        return pts.length - 1;
    }

    // Continuation sub-edge choice (task 0295, F2, decision #2 — the
    // residual ambiguity: `seed` is a shared endpoint of the (typically 2-3)
    // live edges left after the previous segment's cut: the two half-edges
    // of the just-split edge, plus that face's own new chord edge). Keep the
    // one that reaches destEdge with a non-degenerate path; tie-break by
    // proximity to destEdge's midpoint, then lowest edge index.
    // `vibe3d-divergence`: the SDK is silent on which faces the reference
    // chords here — the bar is a valid, duplicate-free chain (the measured
    // seg-2 capture's shared-vertex reuse), not face-choice parity.
    //
    // W1 (perf): `reaches` used to be read back from a REAL
    // `mesh.edgeSliceEx(sub, destEdge, ..., split_)` call wrapped in a
    // `MeshSnapshot.capture`/`restore` probe — a whole-mesh dup+restore PER
    // CANDIDATE, and `bakeChainFrom` calls this per chain segment on every
    // `onMouseMotion`/`rebuildPreview`, so it was O(segments*candidates)
    // whole-mesh copies per mouse-move. `Mesh.edgeSliceReachable` is the same
    // face-incidence + dual-graph BFS `edgeSliceEx` runs internally, factored
    // out read-only (mesh.d), so the probe is gone entirely. One subtlety
    // preserved exactly: with Split Polygons OFF, `edgeSliceEx`'s
    // points-only branch never consults face connectivity at all — it
    // unconditionally succeeds (facesSplit=2) for any distinct, in-range
    // edge pair — so `reaches` must mirror that unconditional success rather
    // than running the BFS in that case (the BFS would wrongly reject
    // candidates with no face-adjacency path that the points-only cut would
    // have happily taken).
    uint pickSeedSubEdge(uint seed, uint destEdge) {
        uint[] candidates;
        foreach (sub; mesh.edgesAroundVertex(seed)) candidates ~= sub;
        if (candidates.length == 0) return ~0u;
        if (destEdge >= mesh.edges.length) return candidates[0];

        Vec3 destMid = lerpVec3(mesh.vertices[mesh.edges[destEdge][0]],
                                 mesh.vertices[mesh.edges[destEdge][1]], 0.5f);

        uint  best        = ~0u;
        float bestDist     = float.infinity;
        bool  bestReaches  = false;

        foreach (sub; candidates) {
            bool reaches;
            if (sub == destEdge) reaches = false;            // same-edge no-op, any split_ setting
            else if (!split_)    reaches = true;              // points-only: unconditional success
            else                 reaches = mesh.edgeSliceReachable(sub, destEdge);

            uint  other = mesh.edgeOtherVertex(sub, seed);
            float dist  = (mesh.vertices[other] - destMid).length();

            bool better = (best == ~0u)
                || (reaches && !bestReaches)
                || (reaches == bestReaches && dist < bestDist)
                || (reaches == bestReaches && dist == bestDist && sub < best);
            if (better) { best = sub; bestDist = dist; bestReaches = reaches; }
        }
        return best;
    }

    // The ONE-undo boundary (task 0295, F2, objection 2/3). Commits ONLY the
    // LATCHED polyline — a pending (hover-derived, un-latched) tip is dropped
    // (bakeChainFrom re-cuts from chainBefore_ using latchedPoints_ alone).
    void commitChain() {
        if (history is null || factory is null || !chainBefore_.filled) {
            dropArmedPreview();
            return;
        }
        if (latchedPoints_.length < 2) { cancelLiveEdit(); return; }
        if (!armedKey_.matches(*mesh)) {
            // The mesh underneath us was swapped/clobbered since our last
            // touch — nothing safely ours to commit.
            dropArmedPreview();
            return;
        }

        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        if (n == 0) {
            // task 0303 (fuzz-found): the whole chain failed to bake even
            // its first segment (e.g. a t=0/1 endpoint-reuse cut landing
            // ADJACENT, in the shared face's winding, to another segment's
            // cut point trips rebuildFacesWithChordSplits' adjacent-hit
            // guard). bakeChainFrom/edgeSliceEx already leave the mesh
            // exactly as chainBefore_ in that case (mesh.d's own
            // Pass-1-undo-on-Pass-2-failure), so recording an edit here
            // would be a genuine no-op undo entry — cancel instead, mirroring
            // applyHeadless's n==0 contract.
            cancelLiveEdit();
            return;
        }
        auto edit = factory();
        auto post = MeshSnapshot.capture(*mesh);
        edit.setSnapshots(chainBefore_, post, "Edge Slice");
        history.record(edit);   // EXACTLY ONE entry for the whole chain
        dropArmedPreview();     // clears latchedPoints_/chainBefore_ — next
                                 // chain recaptures chainBefore_ at its own
                                 // first latch/armChain.
        refreshCaches();
    }

    void cancelLiveEdit() {
        // Restores chainBefore_ — the WHOLE chain, never a per-segment
        // baseline — so Esc/RMB/redo-cancel unwinds every baked segment.
        if (armedKey_.matches(*mesh) && chainBefore_.filled) chainBefore_.restore(*mesh);
        dropArmedPreview();
        refreshCaches();
    }

    // The mutate/revert preview: restore chainBefore_, then re-bake the
    // WHOLE polyline (latched points + a hover-derived pending point) via
    // bakeChainFrom. Guarded by armedKey_: if the mesh underneath an armed
    // preview was swapped/clobbered by something else since our last touch,
    // drop the preview instead of restoring/cutting against the WRONG mesh.
    // Re-bakes ONLY the CONFIRMED latched chain — deliberately NOT the
    // hover-derived pending tip (see onMouseMotion's comment): mutating the
    // mesh from mere hovering would desync the app's picker (g_hoveredEdge)
    // from chainBefore_'s vertex indices by the time the NEXT click actually
    // latches, so the pending segment stays a draw()-only visual (no mesh
    // write) until it is itself latched by a real click.
    void rebuildPreview() {
        if (!chainBefore_.filled || latchedPoints_.length == 0) return;
        if (!armedKey_.matches(*mesh)) { dropArmedPreview(); return; }

        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        built_ = n > 0;
        armedKey_.stamp(*mesh);
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
