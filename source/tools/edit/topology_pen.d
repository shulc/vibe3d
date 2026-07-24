module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;

import tool;
import mesh                : Mesh, GpuMesh;
import math               : Vec3, Viewport, projectToWindowFull;
import shader              : Shader;
import operator            : VectorStack;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import constraint           : resolveHoverTarget, kTopoPenSnapPx;
import viewcache            : VertexCache, EdgeCache, FaceBoundsCache;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot              : MeshSnapshot;
import display_sync         : refreshDisplay;

import ImGui = d_imgui;
import d_imgui.imgui_h;

/// Factory the tool calls PER CLICK to obtain a fresh, primary-bound
/// `MeshVertexNew` (P2, doc/topopen_p2_plan.md REV-1) — mirrors
/// `tools.create.vertex_place`'s `VertexEditFactory` alias shape. Binding
/// happens at CALL time (`() => new MeshVertexNew(&mesh(), ...)` at the
/// registration.d wiring site), so each click's command targets whichever
/// layer is primary AT THAT MOMENT.
alias VertexNewFactory = MeshVertexNew delegate();

/// Factory the tool calls ONCE PER BUILD GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P3, doc/topopen_p3_plan.md) — the
/// generic before/after-snapshot undo command (`tools.create.pen`'s
/// `PenEditFactory` shape, same idiom as every other interactive tool's
/// `bevelEditFactory`). Binding happens at CALL time, so the build's undo
/// entry targets whichever layer is primary when the gesture commits.
alias TopoPenBuildFactory = MeshSessionEdit delegate();

/// The four connectivity outcomes a drag-from-vertex build gesture can
/// resolve to on release, per `classifySource` below (capture-verified,
/// doc/topopen_p3_plan.md's mechanism table). `None` covers BOTH "the
/// source vertex's topology doesn't qualify" and the measured one-shot
/// ceiling (a hub already embedded in a quad classifies degree-2/non
/// -triangle-hub, which is exactly `None`).
private enum BuildCase { None, Edge, Tri, Quad }

// ---------------------------------------------------------------------------
// GestureSlot — the reference's COMPLETE 3-button × 4-modifier-state input
// grid for this tool (12 slots; doc-mined, cross-confirmed by 3 independent
// sources — help text, per-mode cfg Desc strings, and the input-map cfg's
// abstract-event grid — see toolcards/topology_pen/gesture_map.md, PRIVATE).
// There is NO Alt-modified slot (Alt is reserved for camera nav everywhere in
// vibe3d, unconditionally excluded below). Only `ShiftLmb` — the
// Duplicate/build overlay this class implements — is WIRED this phase; every
// other slot is a named, inert stub so the dispatch structure is in place for
// later modes (Move, Split, Add Loop, Slide, Remove, Duplicate Loop, Move
// Edge Loop, Smoothing, ...) to plug into without re-deriving the grid.
private enum GestureSlot {
    Lmb,           // none,       LMB — Move                          (NOT YET IMPLEMENTED)
    Rmb,           // none,       RMB — Move + Edge Loop               (NOT YET IMPLEMENTED)
    Mmb,           // none,       MMB — Split                          (NOT YET IMPLEMENTED)
    ShiftLmb,      // Shift,      LMB — Duplicate/build — THIS PHASE (P3)
    ShiftRmb,      // Shift,      RMB — Duplicate Loop                 (NOT YET IMPLEMENTED)
    ShiftMmb,      // Shift,      MMB — Add Loop                       (NOT YET IMPLEMENTED)
    CtrlLmb,       // Ctrl,       LMB — Slide / Edge Slide             (NOT YET IMPLEMENTED)
    CtrlRmb,       // Ctrl,       RMB — undocumented slot               (NOT YET IMPLEMENTED)
    CtrlMmb,       // Ctrl,       MMB — Remove                         (NOT YET IMPLEMENTED)
    ShiftCtrlLmb,  // Shift+Ctrl, LMB — Smoothing                      (NOT YET IMPLEMENTED)
    ShiftCtrlRmb,  // Shift+Ctrl, RMB — Smoothing + Edge Loop           (NOT YET IMPLEMENTED)
    ShiftCtrlMmb,  // Shift+Ctrl, MMB — undocumented slot               (NOT YET IMPLEMENTED)
    None,          // Alt held (camera), or a button this grid doesn't cover
}

/// Resolve which of the 12 documented slots a mouse button + the live
/// modifier mask maps to. Pure/stateless — reused identically by any future
/// down/up handler; the only slot currently acted on is `ShiftLmb`.
private GestureSlot resolveGestureSlot(ubyte button, SDL_Keymod mods) {
    if (mods & KMOD_ALT) return GestureSlot.None;   // camera orbit/pan/zoom — never ours
    bool shift = (mods & KMOD_SHIFT) != 0;
    bool ctrl  = (mods & KMOD_CTRL)  != 0;
    switch (button) {
        case SDL_BUTTON_LEFT:
            if (shift && ctrl) return GestureSlot.ShiftCtrlLmb;
            if (shift)         return GestureSlot.ShiftLmb;
            if (ctrl)          return GestureSlot.CtrlLmb;
            return GestureSlot.Lmb;
        case SDL_BUTTON_RIGHT:
            if (shift && ctrl) return GestureSlot.ShiftCtrlRmb;
            if (shift)         return GestureSlot.ShiftRmb;
            if (ctrl)          return GestureSlot.CtrlRmb;
            return GestureSlot.Rmb;
        case SDL_BUTTON_MIDDLE:
            if (shift && ctrl) return GestureSlot.ShiftCtrlMmb;
            if (shift)         return GestureSlot.ShiftMmb;
            if (ctrl)          return GestureSlot.CtrlMmb;
            return GestureSlot.Mmb;
        default:
            return GestureSlot.None;
    }
}

// ---------------------------------------------------------------------------
// TopologyPenTool — Phases P0 + P1 + P2 + P3 of the topology-pen port
// (factory id `mesh.topoPen`, doc/topopen_p0_plan.md, doc/topopen_p1_plan.md,
// doc/topopen_p2_plan.md, doc/topopen_p3_plan.md).
//
// P3 adds the DRAG-FROM-VERTEX build gesture on the **Shift+LMB** overlay
// slot (doc-mined gesture grid, cross-confirmed by 3 independent reference
// sources — toolcards/topology_pen/gesture_map.md, PRIVATE; the "Duplicate"
// overlay while the tool would otherwise be in its Move mode; correction to
// the initial mode-less draft, applied BEFORE this phase shipped — see
// `GestureSlot`/`resolveGestureSlot` above): a Shift+LMB press landing on an
// existing primary-layer vertex A arms a drag-build (`findSourceVertex`/
// `classifySource`, both handled entirely by THIS class — no CONS
// involvement, the source pick/classify is intrinsic to the gesture, not a
// background-surface constraint); release (`onMouseButtonUp`) commits a bare
// edge / auto-closed triangle / spliced quad per A's EXISTING topology at
// press time, at the CONS-snapped release hit — one atomic undo via
// `buildFromSource` (the `pen.d` `commitPolygonWithUndo` precedent: a direct
// kernel mutation bracketed in ONE before/after `MeshSnapshot`, NOT a per-op
// command). Snap itself STAYS in CONS (owner hard rule #1, unchanged from
// P0-P2); P3's new logic is the gesture/classify/build state machine living
// entirely in this tool + the three additive `Mesh` seams it consumes
// (`edgeNeighbors`, `deleteFacesByMask(keepFloatingEdges)`,
// `makePolygonFromVerts(autoOrient)`). Plain (unmodified) LMB stays
// `placeVertexAt` (P2's press-on-empty click) — UNTOUCHED, dispatched via
// `GestureSlot.Lmb` below exactly as it always was. Every other slot in the
// grid (Move, Split, Add Loop, Slide, Remove, the two loop-variant overlays,
// Smoothing, the 2 undocumented slots) is a named, inert stub for later
// phases — see `GestureSlot`'s own doc comment.
//
// LAYERED like the reference editor (owner hard rule #1): the background-
// surface constraint (Point-mode nearest-foot magnet, Screen-mode
// camera-ray) lives ENTIRELY in the mesh-CONSTRAINT toolpipe stage
// (ConstrainStage's mode-dispatched branches, source/toolpipe/stages/
// constrain.d, reusing the existing BvhPick — source/bvh_pick.d — for
// Screen mode and `constraint.closestPointOnMeshes` for Point mode), and
// the hover snap-target RESOLUTION lives ENTIRELY in the constraint
// (pure-math) layer (`resolveHoverTarget`, source/constraint.d — P1,
// review REV-A). This tool is a THIN CONSUMER of both: it does NOT
// raycast, does NOT touch BvhPick or `closestPointOnMeshes` directly, does
// NOT resolve a snap target inline (it only CALLS `resolveHoverTarget`),
// and mutates the mesh ONLY through the `mesh.addVertex` command
// (`MeshVertexNew`, P2) — never a direct `mesh.addVertex` call of its own.
// P0 shipped the raycast plumbing; P1 added hover-preview rendering + the
// resolved target exposed over `toolStateJson()`; P2 adds the actual
// placement: a click with a hit creates ONE vertex in the PRIMARY layer at
// `ConstrainHitPacket.point` (now the corrected nearest-foot point under
// Point mode). Polygon/strip building from a chain of placed verts is a
// later phase (P3, doc/topopen_p2_plan.md §Extension).
//
// Lifecycle:
//   activate()   — composes CONS (enabled + geometry=Point) via the
//                  stage's own setAttr, mirroring how a preset composes an
//                  ancillary pipe stage. Since ConstrainStage.onParamChanged
//                  no longer locks on every write (review fix SF), this
//                  setAttr call is ALREADY transient by construction — no
//                  unlock dance needed. Critically (review fix SF-1), this
//                  means activate() must NOT blindly clobber a pre-existing
//                  `userLocked`: when the user already explicitly enabled
//                  CONS (`constrain.toggle` or `tool.pipe.attr constrain
//                  enabled true`), that lock — and the user's own
//                  enabled/geometry choice — MUST survive this tool
//                  activating. So activate() only composes when CONS is
//                  NOT already user-locked; a locked CONS is left
//                  completely untouched (the tool still reads whatever hit
//                  packet the user's own config produces).
//                  `resetTransientPipeStages()` (app.d, called on every
//                  tool switch BEFORE the outgoing tool's deactivate())
//                  cleanly reverts the tool's OWN unlocked composition —
//                  mirroring ActionCenterStage / AxisStage's userLocked
//                  pattern — while a genuine user lock passes straight
//                  through both this activate() and that reset. No
//                  bespoke tool-local save/restore.
//   deactivate() — clears the tool's own cached hit/target only; CONS
//                  itself is already reverted by the funnel above by the
//                  time this runs (or immediately after, on the "toggle
//                  same tool off" path) — either way this tool never
//                  hand-rolls a CONS restore, and a user's prior lock was
//                  never touched in the first place.
//   onMouseMotion()/update() — read `vts.get!ConstrainHitPacket()` (the
//                  packet CONS published earlier in the SAME
//                  pipeline.evaluate() pass the dispatcher already ran)
//                  and cache it as `lastHit_`. The packet is present only
//                  when the dispatching `vts` carried a valid cursor
//                  (mouse-event dispatch — see SubjectPacket's doc
//                  comment); the per-frame render-loop's `update()` call
//                  always sees no packet, so a present→absent transition
//                  must NOT stomp the last real reading. When the packet
//                  IS present, also resolve `lastTarget_` from the SAME
//                  vts's `SubjectPacket.viewport` (P1) — CONS only
//                  publishes a hit when a SubjectPacket was present (its
//                  `evaluate()` requires it), so the viewport read here is
//                  exactly the one the hit was raycast against.
//   draw()       — P1: renders a hover-preview marker at `lastHit_.point`
//                  (orange dot + ring + short normal pin) and, when the
//                  hover resolves to a vertex/edge, a cyan highlight of
//                  that element — mirrors `snap_render.drawSnapOverlay`'s
//                  conventions. Re-resolves the target against THIS
//                  cell's `vp` (a multi-viewport draw may run once per
//                  eligible cell, each with its own camera) rather than
//                  reusing the motion-time `lastTarget_`, which stays the
//                  cached value `toolStateJson()` reports. No raycast, no
//                  mesh access, no mutation — every input comes from
//                  `lastHit_` (the packet) and the passed-in `vp`.
// ---------------------------------------------------------------------------
class TopologyPenTool : Tool {
private:
    ConstrainHitPacket lastHit_;
    HoverTarget         lastTarget_;

    // --- P2 placement deps (doc/topopen_p2_plan.md) — wired by
    // registration.d, mirroring VertexTool's ctor/setUndoBindings shape
    // (tools/create/vertex_place.d). All may be left unset (test/no-app
    // construction); `placeVertexAt` degrades to a no-op rather than
    // crashing when `addVertexFactory_` is null.
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() { return meshSrc_(); }
    GpuMesh*         gpu_;
    VertexCache*     vc_;
    EdgeCache*       ec_;
    FaceBoundsCache* fc_;

    CommandHistory    history_;
    VertexNewFactory  addVertexFactory_;

    // --- P3 drag-build gesture deps (doc/topopen_p3_plan.md) ---
    TopoPenBuildFactory buildEditFactory_;

    // --- P3 drag-build session state (topology_pen.d, doc/topopen_p3_plan.md).
    // Armed on a press that lands on an existing primary-layer vertex;
    // classified ONCE at arm time (the mesh is never mutated between press
    // and release, so re-classifying at release would be redundant, not
    // more correct — and a stale index after an external undo mid-drag is
    // handled by `resyncSession` clearing all of this instead). Cleared by
    // `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation.
    int       sourceVert_     = -1;
    bool      dragArmed_      = false;
    int       dragStartX_, dragStartY_;
    BuildCase classifiedCase_ = BuildCase.None;
    int       triN_           = -1;   // Tri case: A's one existing neighbor
    int       quadP_          = -1;   // Quad case: cyclic-next(A) in the triangle
    int       quadQ_          = -1;   // Quad case: cyclic-prev(A) in the triangle
    int       quadTriFi_      = -1;   // Quad case: the triangle face index to splice

    void readHit(ref VectorStack vts) {
        if (auto p = vts.get!ConstrainHitPacket()) {
            lastHit_ = *p;
            Viewport vp;
            if (auto s = vts.get!SubjectPacket())
                vp = s.viewport;
            lastTarget_ = resolveHoverTarget(lastHit_, vp, kTopoPenSnapPx);
        }
        // else: leave lastHit_/lastTarget_ unchanged — see class doc (the
        // per-frame render-loop's vts never carries the packet; only a
        // real mouse event does).
    }

    // Project a world point to a foreground-drawlist pixel; false when
    // behind the camera (mirrors snap_render.d's private `project`).
    static bool projectPt(Vec3 world, const ref Viewport vp, out ImVec2 pt) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(world, vp, sx, sy, ndcZ)) return false;
        pt = ImVec2(sx, sy);
        return true;
    }

public:
    // Deps default-unset (matches the pre-P2 `new TopologyPenTool()`
    // registration site — every existing P0/P1 caller/test keeps working
    // unchanged); `setUndoBindings` supplies the placement path.
    this() {}

    this(Mesh* delegate() meshSrc, GpuMesh* gpu,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_ = meshSrc;
        this.gpu_     = gpu;
        this.vc_      = vc;
        this.ec_      = ec;
        this.fc_      = fc;
    }

    void setUndoBindings(CommandHistory h, VertexNewFactory f,
                        TopoPenBuildFactory bf = null) {
        history_          = h;
        addVertexFactory_ = f;
        buildEditFactory_ = bf;
    }

    override string name() const { return "Topology Pen"; }

    override void activate() {
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
        if (g_pipeCtx is null) return;
        auto cs = cast(ConstrainStage) g_pipeCtx.pipeline.findByTask(TaskCode.Cons);
        if (cs is null) return;
        // SF-1: a pre-existing EXPLICIT user lock (constrain.toggle /
        // tool.pipe.attr constrain enabled true) must survive this tool
        // activating — do not touch CONS at all in that case, so neither
        // the user's enabled/geometry choice nor the lock itself is
        // clobbered. Only compose CONS+Point when it is NOT already
        // user-locked; that composition stays unlocked (CONS.onParamChanged
        // no longer locks — review fix SF), so resetTransientPipeStages()
        // cleanly reverts it on the next tool switch.
        if (cs.userLocked) return;
        cs.setAttr("enabled", "true");
        cs.setAttr("geometry", "point");
    }

    override void deactivate() {
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        readHit(vts);
        // While a drag-build is armed, this keeps `lastHit_` tracking the
        // CONS-snapped cursor point for the in-progress ghost preview
        // (draw(), below) — no other state changes during the drag; the
        // build itself only fires on release.
        return false;   // never consumes — placement/build happens on button-up, not motion
    }

    override void update(ref VectorStack vts) {
        readHit(vts);
    }

    // P3 (doc/topopen_p3_plan.md): project every vertex of the PRIMARY
    // layer's mesh and return the nearest within `kTopoPenSnapPx`, or -1.
    // O(V) per press — self-contained (no CONS, no new module), mirroring
    // `projectPt`'s own screen-space-only contract.
    private int findSourceVertex(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        int   best   = -1;
        float bestD2 = float.infinity;
        foreach (vi; 0 .. m.vertices.length) {
            ImVec2 pt;
            if (!projectPt(m.vertices[vi], vp, pt)) continue;
            float dx = pt.x - cast(float)mx, dy = pt.y - cast(float)my;
            float d2 = dx * dx + dy * dy;
            if (d2 < bestD2) { bestD2 = d2; best = cast(int)vi; }
        }
        if (best >= 0 && bestD2 <= kTopoPenSnapPx * kTopoPenSnapPx) return best;
        return -1;
    }

    // P3 — classify source vertex `a`'s EXISTING topology (capture-verified,
    // doc/topopen_p3_plan.md "The MEASURED mechanism" table), via the raw
    // `edgeNeighbors` scan (KILLER-1) for the edge-count test and
    // `facesAroundVertex` (reliable here — a vertex ON a face has `vertLoop`
    // seeded) ONLY for the face-incidence test. Fills `triN_`/`quadP_`/
    // `quadQ_`/`quadTriFi_` scratch on a Tri/Quad result.
    private BuildCase classifySource(int a) {
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
        auto m = mesh;
        if (m is null || a < 0 || a >= cast(int)m.vertices.length) return BuildCase.None;

        auto en = m.edgeNeighbors(cast(uint)a);
        if (en.length == 0) return BuildCase.Edge;          // A truly isolated
        if (en.length == 1) {                               // one bare edge -> auto-close
            triN_ = cast(int)en[0];
            return BuildCase.Tri;
        }

        // en.length >= 2: only a genuine "hub of exactly one triangle" (both
        // neighbors already mutually edge-connected via that one face)
        // qualifies for the quad splice. A hub already embedded in a quad
        // (nf==1 but a 4-gon) or a vertex on 0/2+ faces falls through to
        // None — the measured one-shot ceiling / non-triangle-hub case.
        int nf = 0, triFi = -1;
        foreach (fi; m.facesAroundVertex(cast(uint)a)) { ++nf; triFi = cast(int)fi; }
        if (nf == 1 && triFi >= 0 && m.faces[triFi].length == 3) {
            auto f  = m.faces[triFi];
            int  ai = -1;
            foreach (k, vv; f) if (vv == cast(uint)a) { ai = cast(int)k; break; }
            if (ai < 0) return BuildCase.None;   // defensive; shouldn't happen
            int n = cast(int)f.length;
            quadP_     = cast(int)f[(ai + 1) % n];
            quadQ_     = cast(int)f[(ai + n - 1) % n];
            quadTriFi_ = triFi;
            return BuildCase.Quad;
        }
        return BuildCase.None;
    }

    // Dispatch entry point: resolve which of the 12 documented slots this
    // press belongs to (`GestureSlot`, above) and route to the one live
    // handler (`ShiftLmb` -> the P3 build-arm) or the unchanged P2 handler
    // (`Lmb`). Every other slot is a named, inert stub — don't consume, so
    // any other handler (camera, selection) still sees the event, exactly
    // like the pre-P3 "not handled yet" Ctrl/Shift early-return this
    // replaces.
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts) {
        final switch (resolveGestureSlot(e.button, SDL_GetModState())) {
            case GestureSlot.Lmb:      return onPlainLmbDown(e, vts);
            case GestureSlot.ShiftLmb: return onShiftLmbDown(e, vts);
            case GestureSlot.Rmb:
            case GestureSlot.Mmb:
            case GestureSlot.ShiftRmb:
            case GestureSlot.ShiftMmb:
            case GestureSlot.CtrlLmb:
            case GestureSlot.CtrlRmb:
            case GestureSlot.CtrlMmb:
            case GestureSlot.ShiftCtrlLmb:
            case GestureSlot.ShiftCtrlRmb:
            case GestureSlot.ShiftCtrlMmb:
                // TODO: Move / Move+Edge-Loop / Split / Duplicate Loop / Add
                // Loop / Slide / the 2 undocumented slots / Remove /
                // Smoothing / Smoothing+Edge-Loop — gesture_map.md table A,
                // slots 1/2/3/5/6/7/8/9/10/11/12. Not implemented yet.
                return false;
            case GestureSlot.None:
                return false;
        }
    }

    // P2 (doc/topopen_p2_plan.md): a plain (unmodified) LEFT click with a
    // background hit places ONE vertex in the primary layer at the (now
    // nearest-foot-corrected) hit point. UNCHANGED by P3 — a plain LMB press
    // never checks for an existing vertex under the cursor at all (Move, the
    // reference's plain-LMB action, is a later phase; see `GestureSlot.Lmb`'s
    // doc comment). Dispatched via app.d's general `if (activeTool)`
    // mouse-down block (app.d:6135-6136), which already ran
    // `buildToolVts(..., btn.x, btn.y, true)` -> `cursorValid=true` ->
    // pipeline.evaluate(vts) BEFORE calling here, so CONS has already
    // published this event's ConstrainHitPacket onto `vts` — `readHit`
    // below reads it fresh rather than trusting a possibly-stale
    // `lastHit_` from the last motion event.
    private bool onPlainLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        readHit(vts);
        if (!lastHit_.hit) return true;   // claimed the click; no bg/degenerate seed -> place nothing

        placeVertexAt(lastHit_.point, vts);
        return true;
    }

    // P3 (doc/topopen_p3_plan.md), on the Shift+LMB "Duplicate" overlay slot
    // (gesture_map.md table A #4 — corrected from the initial mode-less
    // draft before this phase shipped): a Shift+LMB press landing on an
    // existing primary-layer vertex arms a drag-build gesture (source picked
    // LIVE per press — a deliberate divergence from the reference's
    // arm-scan caching, see the plan's owner-decision #3); it does NOT
    // place. The build itself commits on RELEASE (`onMouseButtonUp`),
    // reading whatever CONS-snapped surface hit that later event carries. A
    // Shift+LMB press that does NOT land on an existing vertex has no
    // documented gesture (Duplicate always starts on a pre-highlighted
    // element) — don't consume, matching the dispatch default.
    private bool onShiftLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int src = findSourceVertex(e.x, e.y, vp);
        if (src < 0) return false;   // no pre-highlighted element -> no documented gesture

        sourceVert_     = src;
        dragArmed_      = true;
        dragStartX_     = e.x;
        dragStartY_     = e.y;
        classifiedCase_ = classifySource(src);
        return true;   // consume; the build (if any) commits on release
    }

    // P3 (doc/topopen_p3_plan.md): commits the armed drag-build, if any, at
    // the RELEASE event's own CONS-snapped hit. A release with no armed
    // drag (P2's plain click already handled everything on the matching
    // down event) or with no real motion since press (a stationary
    // click-on-vertex — "revisit = Move/no-op", capture SESSION 1) builds
    // nothing. Always disarms before returning, so a rejected/no-op release
    // never leaves a stale armed source for the NEXT press to inherit.
    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (!dragArmed_) return false;

        int       a     = sourceVert_;
        BuildCase casee  = classifiedCase_;
        int       n      = triN_;
        int       p      = quadP_;
        int       q      = quadQ_;
        int       triFi  = quadTriFi_;
        int       startX = dragStartX_, startY = dragStartY_;

        sourceVert_     = -1;
        dragArmed_      = false;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;

        readHit(vts);   // refresh lastHit_ to THIS release event's CONS-snapped hit

        // A release back at (near enough) the press pixel is a stationary
        // click on the source vertex, not a drag — capture-confirmed no-op
        // (a near-zero-displacement Move), never a build.
        enum int kMinDragPx = 3;
        int dx = e.x - startX, dy = e.y - startY;
        if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return true;

        if (!lastHit_.hit) return true;        // no surface hit at release -> nothing to build
        if (casee == BuildCase.None) return true;   // unsupported source state / one-shot ceiling

        buildFromSource(a, casee, n, p, q, triFi, lastHit_.point);
        return true;
    }

    // Create one isolated vertex at `point` in the PRIMARY layer via the
    // `mesh.addVertex` command (P2 REV-1, doc/topopen_p2_plan.md): fires
    // the real `MeshVertexNew` through its Operator interface
    // (`cmd.evaluate(vts)`, using the TOOL's own vts so the command's
    // internal `SubjectPacket` guard is satisfied) and records it
    // POST-apply via `history_.record(cmd)` — no re-apply, one
    // non-coalescing undo entry per click (mirrors the precedent at
    // `tools/common/command_wrapper.d`'s `applyWithLivePipeline`, NOT
    // VertexTool's snapshot-diff path: `addVertexFactory_` binds `&mesh()`
    // = primary at CALL time, so the command targets whichever layer is
    // primary right now, and its own `MeshSnapshot`-based `revert()`
    // handles undo). Returns the new vertex's index (`-1` on a no-op —
    // missing factory or a rejected `evaluate`), for P3's chain-building to
    // reuse (doc/topopen_p2_plan.md §Extension); this tool itself does not
    // use the return value yet.
    private int placeVertexAt(Vec3 point, ref VectorStack vts) {
        // Guard BOTH prerequisites BEFORE creating/applying the command
        // (review NIT): meshSrc_/gpu_/vc_/ec_/fc_ are wired together with
        // addVertexFactory_ (registration.d), so a partially-constructed tool
        // (e.g. no-arg ctor + setUndoBindings only) must bail HERE — above
        // cmd.evaluate() — so it never mutates-then-fails-to-record (which
        // would leave an applied-but-un-undoable edit).
        if (addVertexFactory_ is null || meshSrc_ is null) return -1;

        auto cmd = addVertexFactory_();   // binds &mesh() = primary NOW
        cmd.setPos(point);
        if (!cmd.evaluate(vts)) return -1;

        if (history_ !is null) history_.record(cmd);   // non-coalescing -> one undo entry

        if (gpu_ !is null) gpu_.upload(*mesh);
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_, vc_, ec_, fc_);

        return cast(int)(mesh.vertices.length - 1);
    }

    // P3 (doc/topopen_p3_plan.md): fire the classified build (EDGE/TRI/QUAD)
    // for the drag gesture just released, on the `pen.d:903-926`
    // `commitPolygonWithUndo` precedent — a DIRECT kernel `mesh.addVertex`
    // (like `pen.d:933`, NOT the `MeshVertexNew` command) bracketed in ONE
    // before/after `MeshSnapshot` pair, so the whole gesture (new vertex +
    // every new edge/face the case implies) is ONE atomic undo entry. Every
    // guard (armed/motion/hit/case) already ran in `onMouseButtonUp`; this
    // is the unconditional mutation + undo-record + display-refresh tail.
    private void buildFromSource(int a, BuildCase casee, int n, int p, int q,
                                 int triFi, Vec3 bPos) {
        if (meshSrc_ is null || history_ is null || buildEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        uint b = m.addVertex(bPos);
        // Same hazard `MeshVertexNew.evaluate` (vertex_new.d:54) documents:
        // addVertex only grows `vertices[]` — grow the selection arrays to
        // match BEFORE anything below could index vertexMarks at `b`.
        m.resizeVertexSelection();

        final switch (casee) {
            case BuildCase.None:
                return;   // defensive; onMouseButtonUp already filters this out
            case BuildCase.Edge:
                // CASE-EDGE: A was truly isolated — a bare edge A-B, no face.
                m.addEdge(cast(uint)a, b);
                m.buildLoops();
                break;
            case BuildCase.Tri:
                // CASE-TRI: A had exactly one bare edge (to N) — auto-close
                // the triangle in the CAPTURED index order [A, B, N] (hub,
                // newest, older-neighbor). autoOrient:false — this winding is
                // a fixed construction-order convention, not adjacency
                // -derived (doc/topopen_p3_plan.md "WINDING" finding).
                m.makePolygonFromVerts([cast(uint)a, b, cast(uint)n], false,
                                       /*autoOrient*/false);
                break;
            case BuildCase.Quad: {
                // CASE-QUAD: A is the hub of one existing triangle (P,A,Q in
                // the triangle's own cyclic order) — splice B into its
                // boundary as [P, A, Q, B]. The triangle is removed WITH
                // both `keepOrphans` (B's own new vertex aside, nothing here
                // orphans a vertex) AND `keepFloatingEdges` (KILLER-2): the
                // old P-Q edge borders no surviving face afterward and must
                // survive as a non-bounding diagonal, exactly like the
                // SESSION-3 capture — never a `rebuildEdges*` in this path.
                auto mask = new bool[](m.faces.length);
                mask[triFi] = true;
                m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
                m.makePolygonFromVerts([cast(uint)p, cast(uint)a, cast(uint)q, b],
                                       false, /*autoOrient*/false);
                break;
            }
        }

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = buildEditFactory_();
        cmd.setSnapshots(before, after, "Topology Build");
        history_.record(cmd);

        m.syncSelection();
        if (gpu_ !is null) gpu_.upload(*m);
        refreshDisplay(m, gpu_, vc_, ec_, fc_);
    }

    // Stored drag-arm index/case dangle across an external history
    // navigation mid-drag (a redo/undo elsewhere could delete the source
    // vertex or its incident geometry out from under an armed gesture) — the
    // driver calls this on every such navigation; clear the whole armed
    // state rather than trust a possibly-stale index.
    override void resyncSession() {
        sourceVert_     = -1;
        dragArmed_      = false;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
    }

    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false) {
        if (!lastHit_.hit) return;

        auto dl = ImGui.GetForegroundDrawList();

        // Re-resolve for THIS cell's camera — a multi-viewport draw may
        // run once per eligible cell, each with its own `vp`; the cached
        // `lastTarget_` (motion-time) stays what toolStateJson() reports.
        auto ht = resolveHoverTarget(lastHit_, vp, kTopoPenSnapPx);

        enum uint markerCol = IM_COL32(255, 150, 0, 230);   // pen orange
        enum uint cyan      = IM_COL32(0, 220, 255, 230);   // snap highlight

        ImVec2 hitPt;
        bool   hitPtOk = projectPt(lastHit_.point, vp, hitPt);
        if (hitPtOk) {
            // Hover marker: filled dot + ring ("free place-point" cursor).
            dl.AddCircleFilled(hitPt, 4.0f, markerCol, 16);
            dl.AddCircle(hitPt, 10.0f, markerCol, 24, 2.0f);

            // Normal pin — short line showing surface orientation.
            ImVec2 tip;
            if (projectPt(lastHit_.point + lastHit_.normal * 0.15f, vp, tip))
                dl.AddLine(hitPt, tip, markerCol, 2.0f);
        }

        final switch (ht.kind) {
            case HoverTargetKind.Vertex: {
                ImVec2 vpt;
                if (projectPt(lastHit_.nearestVertPos, vp, vpt))
                    dl.AddCircleFilled(vpt, 5.0f, cyan, 16);
                break;
            }
            case HoverTargetKind.Edge: {
                ImVec2 a, b;
                if (projectPt(lastHit_.nearestEdgeA, vp, a)
                 && projectPt(lastHit_.nearestEdgeB, vp, b))
                    dl.AddLine(a, b, cyan, 2.5f);
                break;
            }
            case HoverTargetKind.Face:
            case HoverTargetKind.None:
                break;   // marker only — no element to highlight
        }

        // P3 (doc/topopen_p3_plan.md): ghost preview of an in-progress
        // drag-build — a line from the armed source A to the current
        // (CONS-snapped) release point, plus a line from whichever existing
        // neighbor(s) the classified case will auto-connect (Tri: N; Quad:
        // P and Q). No mesh mutation, no raycast — purely re-reads the
        // already-classified state and the packet-sourced `lastHit_`.
        if (dragArmed_ && hitPtOk && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && sourceVert_ >= 0 && sourceVert_ < cast(int)m.vertices.length) {
                enum uint ghostCol = IM_COL32(255, 210, 60, 220);
                ImVec2 aPt;
                if (projectPt(m.vertices[sourceVert_], vp, aPt))
                    dl.AddLine(aPt, hitPt, ghostCol, 2.0f);

                void ghostTo(int vi) {
                    if (vi < 0 || vi >= cast(int)m.vertices.length) return;
                    ImVec2 p;
                    if (projectPt(m.vertices[vi], vp, p))
                        dl.AddLine(p, hitPt, ghostCol, 1.5f);
                }
                final switch (classifiedCase_) {
                    case BuildCase.Tri:  ghostTo(triN_);  break;
                    case BuildCase.Quad: ghostTo(quadP_); ghostTo(quadQ_); break;
                    case BuildCase.Edge:
                    case BuildCase.None: break;
                }
            }
        }
    }

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----
    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("mesh.topoPen");
        root["hit"]         = JSONValue(lastHit_.hit);
        root["point"]       = JSONValue([cast(double)lastHit_.point.x,
                                          cast(double)lastHit_.point.y,
                                          cast(double)lastHit_.point.z]);
        root["normal"]      = JSONValue([cast(double)lastHit_.normal.x,
                                          cast(double)lastHit_.normal.y,
                                          cast(double)lastHit_.normal.z]);
        root["layer"]       = JSONValue(lastHit_.layer);
        root["face"]        = JSONValue(lastHit_.face);
        root["nearestVert"] = JSONValue(lastHit_.nearestVert);
        root["nearestEdge"] = JSONValue(lastHit_.nearestEdge);

        // P1 (doc/topopen_p1_plan.md): the resolved hover snap-target,
        // nested so the P0 root fields above stay intact for the existing
        // Tier-C test.
        auto hv = JSONValue.emptyObject;
        hv["hit"]    = JSONValue(lastHit_.hit);
        hv["point"]  = JSONValue([cast(double)lastHit_.point.x,
                                   cast(double)lastHit_.point.y,
                                   cast(double)lastHit_.point.z]);
        hv["normal"] = JSONValue([cast(double)lastHit_.normal.x,
                                   cast(double)lastHit_.normal.y,
                                   cast(double)lastHit_.normal.z]);
        string kindToken;
        final switch (lastTarget_.kind) {
            case HoverTargetKind.None:   kindToken = "none";   break;
            case HoverTargetKind.Vertex: kindToken = "vertex"; break;
            case HoverTargetKind.Edge:   kindToken = "edge";   break;
            case HoverTargetKind.Face:   kindToken = "face";   break;
        }
        hv["targetKind"] = JSONValue(kindToken);
        hv["targetVert"] = JSONValue(lastTarget_.vert);
        hv["targetEdge"] = JSONValue(lastTarget_.edge);
        root["hover"] = hv;

        // P3 (doc/topopen_p3_plan.md): the armed drag-build state, for
        // Tier-C tests to assert the classified case (incl. a press on a
        // BARE-EDGE vertex -> "tri", the KILLER-1 regression guard) without
        // driving a full build.
        root["sourceVert"] = JSONValue(sourceVert_);
        root["dragArmed"]  = JSONValue(dragArmed_);
        string caseToken;
        final switch (classifiedCase_) {
            case BuildCase.None: caseToken = "none"; break;
            case BuildCase.Edge: caseToken = "edge"; break;
            case BuildCase.Tri:  caseToken = "tri";  break;
            case BuildCase.Quad: caseToken = "quad"; break;
        }
        root["case"] = JSONValue(caseToken);

        return root;
    }
}
