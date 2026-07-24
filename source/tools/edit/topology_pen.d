module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;

import tool;
import mesh                : Mesh, GpuMesh;
import math               : Vec3, Viewport, projectToWindowFull, closestOnSegment2D,
                             screenPointToRay, closestPointOnSegmentToRay, dot;
import shader              : Shader;
import operator            : VectorStack;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import constraint           : resolveHoverTarget, kTopoPenSnapPx;
import viewcache            : VertexCache, EdgeCache, FaceBoundsCache;
import bvh_pick              : BvhPick;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot              : MeshSnapshot;
import display_sync         : refreshDisplay;
import change_bus            : MeshEditScope;

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

/// Factory the tool calls ONCE PER MOVE GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P4, doc/topopen_p4_plan.md OBJ-3
/// FOLDED) — a DEDICATED factory, distinct from `TopoPenBuildFactory`:
/// reusing the build factory would bake the wrong `wireName`
/// ("mesh.topoPen_build" for a move — corrupts undo history / event-log
/// replay / macros) and the wrong `editScope` (Geometry|Marks vs the
/// position-only write a re-snap move actually is). Wired with
/// `wireName="mesh.topoPen_move"` and `MeshEditScope.Position` at the
/// app.d construction site, mirroring `topoPenBuildEditFactory`.
alias TopoPenMoveFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER REMOVE GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P5, doc/topopen_p5_remove_plan.md D4,
/// opponent KILLER-1) — a THIRD dedicated factory, distinct from BOTH
/// `TopoPenBuildFactory` and `TopoPenMoveFactory`: reusing either would bake
/// the wrong `wireName` ("mesh.topoPen_build"/"mesh.topoPen_move" on a
/// face-removal — corrupts undo history / event-log replay / macros) and,
/// for the build factory, the wrong `editScope` (Geometry|Marks vs the
/// plain Geometry a face delete actually is). Wired with
/// `wireName="mesh.topoPen_remove"` and `MeshEditScope.Geometry` at the
/// app.d construction site, mirroring `topoPenMoveEditFactory`.
alias TopoPenRemoveFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER ADD-LOOP GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P6, doc/topopen_p6_addloop_plan.md,
/// REV1 factory precedent) — a FOURTH dedicated factory, distinct from
/// `TopoPenBuildFactory`/`TopoPenMoveFactory`/`TopoPenRemoveFactory`:
/// reusing any sibling would bake the wrong `wireName`
/// ("mesh.topoPen_build"/"mesh.topoPen_move"/"mesh.topoPen_remove" on a
/// loop-cut — corrupts undo history / event-log replay / macros). Wired
/// with `wireName="mesh.topoPen_addloop"` and
/// `MeshEditScope.Geometry|Marks` (the cut resizes selection arrays) at
/// the app.d construction site, mirroring `topoPenRemoveEditFactory`.
alias TopoPenAddLoopFactory = MeshSessionEdit delegate();

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
    Lmb,           // none,       LMB — Move — THIS PHASE (P4)
    Rmb,           // none,       RMB — Move + Edge Loop               (NOT YET IMPLEMENTED)
    Mmb,           // none,       MMB — Split                          (NOT YET IMPLEMENTED)
    ShiftLmb,      // Shift,      LMB — Duplicate/build — THIS PHASE (P3)
    ShiftRmb,      // Shift,      RMB — Duplicate Loop                 (NOT YET IMPLEMENTED)
    ShiftMmb,      // Shift,      MMB — Add Loop — THIS PHASE (P6)
    CtrlLmb,       // Ctrl,       LMB — Slide / Edge Slide             (NOT YET IMPLEMENTED)
    CtrlRmb,       // Ctrl,       RMB — undocumented slot               (NOT YET IMPLEMENTED)
    CtrlMmb,       // Ctrl,       MMB — Remove — THIS PHASE (P5)
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
// TopologyPenTool — Phases P0 + P1 + P2 + P3 + P4 + P5 + P6 of the
// topology-pen port (factory id `mesh.topoPen`, doc/topopen_p0_plan.md,
// doc/topopen_p1_plan.md, doc/topopen_p2_plan.md, doc/topopen_p3_plan.md,
// doc/topopen_p4_plan.md, doc/topopen_p5_remove_plan.md,
// doc/topopen_p6_addloop_plan.md).
//
// P6 adds ADD LOOP on the **Shift+MMB** overlay slot
// (`GestureSlot.ShiftMmb`, doc/topopen_p6_addloop_plan.md): a press picks
// the nearest primary-layer EDGE under the cursor (`findRingSeedEdge`,
// mirroring `findSourceVertex` but over edges) and, if that edge's
// perpendicular quad ring exists (`collectEdgeRing`), arms a loop-cut —
// tracking a `[0,1]` ratio off the cursor (`ratioFromCursor`, the SAME
// ray/segment projection `loop_slice_tool.d`'s scrub uses) as the mouse
// moves, and committing on release (`onMouseButtonUp`'s MIDDLE branch).
// The commit (`commitAddLoop`) is FULL KERNEL REUSE — a single call to
// `Mesh.insertEdgeLoops(seedEdge, [r])` (`source/mesh_ops/loop_slice.d`,
// the SAME kernel `mesh.addLoop`/the Loop Slice tool call), bracketed in
// one before/after `MeshSnapshot` pair recorded through its OWN dedicated
// `addLoopEditFactory_` (wireName "mesh.topoPen_addloop") — one gesture,
// one atomic undo. `source/mesh_ops/loop_slice.d` and
// `source/commands/mesh/loop_slice.d` are UNCHANGED; the tool only copies
// the existing `MeshAddLoop.evaluate`'s open-interval guard
// (`r<=0||r>=1` -> no-op, the captured "landing exactly on a vertex
// inserts nothing"). `insertEdgeLoops` does a wholesale `faces=newFaces`
// rebuild, so a successful commit calls `resyncSession()` — exactly like
// P5's `removeFaceAt` — to invalidate any OTHER gesture's cached face/
// vertex indices that might be armed on a different button concurrently
// (the tool never overrides `isDragging()`). Out of scope for V1: an
// OPEN-span ring (the kernel's own existing open-ring path runs
// unmodified but parity there is unmeasured — flagged, not claimed) and
// post-cut loop-edge selection (the capture did not measure one for this
// gesture, unlike `mesh.addLoop`'s own `selectNewLoopEdges`).
//
// P5 adds REMOVE on the **Ctrl+MMB** overlay slot (`GestureSlot.CtrlMmb`,
// doc/topopen_p5_remove_plan.md): remove-on-DOWN (D2, capture-faithful and
// the simplest composition — no `onMouseButtonUp` involvement at all, so
// it is disjoint from every LEFT-button gesture above). One press picks the
// front-most PRIMARY-layer face under the cursor via the tool's own
// `BvhPick` (`pickPrimaryFace`, D1) and deletes ONLY that face
// (`removeFaceAt`, D5) — `keepOrphans`+`keepFloatingEdges` both true, so
// orphaned points AND orphaned edges survive, one atomic undo entry via its
// OWN dedicated `removeEditFactory_` (D4, opponent KILLER-1: never
// `buildEditFactory_`/`moveEditFactory_`, which would bake the wrong wire
// name onto a removal). A miss (-1, cursor off every polygon silhouette) is
// a clean no-op that still CONSUMES the click (D3) — Ctrl+MMB is
// unambiguously the Remove gesture. Remove arms no session state of its
// own, but its mutation COMPACTS `faces[]`, so a successful removal calls
// `resyncSession()` (opponent KILLER-2) to invalidate any OTHER gesture
// that might be armed on a different button (P3's `dragArmed_` build, P4's
// `moveArmed_` grab) — `isDragging()` is never overridden, so those CAN be
// armed concurrently with a Ctrl+MMB press.
//
// P4 adds MOVE on the plain (unmodified) **LMB** slot (`GestureSlot.Lmb`) —
// the dispatch backbone's base behavior, every modifier an overlay on top of
// it (capture-verified, doc/topopen_p4_plan.md "The MEASURED mechanism").
// Design A: BOTH Move and Place now commit on RELEASE, not DOWN — a plain
// LMB press disambiguates at press time (`onPlainLmbDown`, reusing P3's
// `findSourceVertex`, kTopoPenSnapPx threshold, over the PRIMARY layer
// only): landing on an existing vertex arms Move (`moveArmed_`/
// `grabbedVert_`); landing on empty background arms Place (`placeArmed_`,
// the same P2 `placeVertexAt` path, now deferred). `onMouseButtonUp`
// commits whichever is armed at the release event's own CONS-snapped hit:
// Move re-snaps the grabbed vertex to that hit (`moveVertexTo` — a direct
// `m.vertices[i]=pos` + `m.commitChange(Position)` write, no new mesh.d
// seam, its own `topoPenMoveEditFactory`/wireName "mesh.topoPen_move", OBJ-3
// FOLDED); Place creates one vertex exactly as P2 always did. A release
// landing back within eps of the grabbed vertex's CURRENT position
// (stationary click, or an all-on-surface no-move) is a clean no-op — no
// mutation, no undo entry, mirroring P3's degenerate-release convention.
// `draw()` renders a live Move ghost (grabbed vertex's re-snapped position)
// since commit is deferred to release — the only mid-drag feedback.
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
// `makePolygonFromVerts(autoOrient)`). Plain (unmodified) LMB now runs P4's
// Move/Place disambiguation (`onPlainLmbDown`, above) — P2's placement
// still fires verbatim on the Place branch, just deferred to release.
// Every other slot in the grid (Move+Edge-Loop, Split, Add Loop, Slide,
// Remove, the two loop-variant overlays, Smoothing, the 2 undocumented
// slots) is a named, inert stub for later phases — see `GestureSlot`'s own
// doc comment.
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

    // --- P5 Remove gesture's own BVH face pick (doc/topopen_p5_remove_plan.md
    // D1) — self-contained: the tool already holds gpu_/meshSrc_ from P2, so
    // this instance is lazily constructed (`pickPrimaryFace`) and used ONLY
    // for `pickFace` on the PRIMARY cage mesh — zero coupling to app
    // internals / the app's own hover-pick instance.
    BvhPick removePick_;

    CommandHistory    history_;
    VertexNewFactory  addVertexFactory_;

    // --- P3 drag-build gesture deps (doc/topopen_p3_plan.md) ---
    TopoPenBuildFactory buildEditFactory_;

    // --- P4 Move gesture deps (doc/topopen_p4_plan.md, OBJ-3 FOLDED) ---
    TopoPenMoveFactory moveEditFactory_;

    // --- P5 Remove gesture deps (doc/topopen_p5_remove_plan.md, opponent
    // KILLER-1) ---
    TopoPenRemoveFactory removeEditFactory_;

    // --- P6 Add Loop gesture deps (doc/topopen_p6_addloop_plan.md, REV1
    // opponent obj-1) ---
    TopoPenAddLoopFactory addLoopEditFactory_;

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

    // --- P4 Move/Place session state (topology_pen.d, doc/topopen_p4_plan.md,
    // Design A). Both outcomes of a plain-LMB press are ARMED at DOWN
    // (`onPlainLmbDown`'s findSourceVertex disambiguation) and COMMITTED at
    // UP (`onMouseButtonUp`) — never at DOWN, so a stationary click's
    // DOWN-then-UP pair stays bit-identical to the pre-P4 DOWN-commit
    // behavior (the byte-identity gate P4 step 1 proves). `placeArmed_`
    // mirrors P2's original press-on-empty-background click; `moveArmed_`/
    // `grabbedVert_` arm when the SAME press instead lands on an existing
    // primary-layer vertex. Cleared by `onMouseButtonUp` on every
    // commit/no-op path and by `resyncSession` on an external history
    // navigation, exactly like the P3 drag-build state above.
    bool placeArmed_  = false;
    bool moveArmed_   = false;
    int  grabbedVert_ = -1;

    // --- P6 Add Loop session state (topology_pen.d,
    // doc/topopen_p6_addloop_plan.md). Armed on a Shift+MMB press that
    // lands on a primary-layer edge whose perpendicular ring exists
    // (`onShiftMmbDown`); the ratio tracks the cursor on every subsequent
    // motion event (`onMouseMotion`) and commits on release
    // (`onMouseButtonUp`'s MIDDLE branch, `commitAddLoop`). `seedRailA_`/
    // `seedRailB_` are the directed world-space endpoints `ratioFromCursor`
    // measures the `[0,1]` ratio against (`seedRail`, captured once at arm
    // time — the mesh is never mutated between arm and commit, so
    // re-deriving them at every motion event would be redundant). Cleared
    // by `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation, exactly like the P3/P4 arm state above.
    int  addLoopSeed_  = -1;
    bool addLoopArmed_ = false;
    int  addLoopStartX_, addLoopStartY_;
    Vec3 seedRailA_, seedRailB_;
    float addLoopRatio_ = 0.5f;

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

    // REV1 (opponent obj-1): 6th param `alf` appended for the Add Loop
    // factory. `mf`/`rf` MUST stay assigned — `TopoPenMoveFactory` and
    // `TopoPenRemoveFactory` are structurally identical delegate aliases,
    // so dropping either here would SILENTLY mis-bind that sibling
    // gesture's factory rather than fail to compile.
    void setUndoBindings(CommandHistory h, VertexNewFactory f,
                        TopoPenBuildFactory bf = null,
                        TopoPenMoveFactory mf = null,
                        TopoPenRemoveFactory rf = null,
                        TopoPenAddLoopFactory alf = null) {
        history_           = h;
        addVertexFactory_  = f;
        buildEditFactory_  = bf;
        moveEditFactory_   = mf;
        removeEditFactory_ = rf;
        addLoopEditFactory_ = alf;
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

        // P6 (doc/topopen_p6_addloop_plan.md Phase 3): while an Add Loop
        // gesture is armed, track the ratio off THIS motion event's cursor
        // — the only mid-drag feedback, since commit is deferred to
        // release. Consumes (unlike the build/move ghosts above, which
        // never claim motion) so the drag reads as this tool's own,
        // mirroring the armed-gesture contract elsewhere in this class.
        if (addLoopArmed_) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            addLoopRatio_ = ratioFromCursor(e.x, e.y, vp);
            return true;
        }
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
            case GestureSlot.CtrlMmb:  return onCtrlMmbDown(e, vts);
            case GestureSlot.ShiftMmb: return onShiftMmbDown(e, vts);
            case GestureSlot.Rmb:
            case GestureSlot.Mmb:
            case GestureSlot.ShiftRmb:
            case GestureSlot.CtrlLmb:
            case GestureSlot.CtrlRmb:
            case GestureSlot.ShiftCtrlLmb:
            case GestureSlot.ShiftCtrlRmb:
            case GestureSlot.ShiftCtrlMmb:
                // TODO: Move+Edge-Loop / Split / Duplicate Loop / Slide /
                // the 2 undocumented slots / Smoothing /
                // Smoothing+Edge-Loop — gesture_map.md table A, slots
                // 2/3/5/7/8/10/11/12. Not implemented yet.
                return false;
            case GestureSlot.None:
                return false;
        }
    }

    // P2/P4 (doc/topopen_p2_plan.md, doc/topopen_p4_plan.md, Design A): a
    // plain (unmodified) LEFT press disambiguates HERE, at press time,
    // between grabbing an existing primary-layer vertex (Move) and placing
    // a new one on the background surface (Place) — reusing P3's
    // `findSourceVertex` (the SAME `kTopoPenSnapPx` screen-space threshold,
    // over the PRIMARY mesh only; the background is the snap reference,
    // never grabbed). Neither outcome commits here: both are armed only,
    // and the actual mutation happens on RELEASE (`onMouseButtonUp`) at
    // THAT event's own CONS-snapped hit — a stationary click's DOWN+UP
    // pixel pair therefore still yields exactly one placement/no mutation,
    // same as the pre-P4 DOWN-commit behavior (byte-identity gate, P4 step
    // 1). Always claims the event either way.
    private bool onPlainLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Replay-hardening (review NIT-2): a DOWN-DOWN-UP sequence injected by
        // an event log could otherwise arm BOTH `placeArmed_` (first DOWN)
        // and `moveArmed_` (second DOWN); since `onMouseButtonUp` checks
        // Place before Move, a genuine move would then commit as a Place and
        // strand `moveArmed_`/`grabbedVert_` armed (a spurious ghost on the
        // next frame). Reset defensively at every fresh press, BEFORE the
        // disambiguation below re-arms exactly one of them.
        placeArmed_  = false;
        moveArmed_   = false;
        grabbedVert_ = -1;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int src = findSourceVertex(e.x, e.y, vp);
        if (src >= 0) {
            moveArmed_   = true;
            grabbedVert_ = src;
        } else {
            placeArmed_ = true;
        }
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
        // Replay-hardening (review NIT-2, same latent shape flagged on
        // `onPlainLmbDown` above): a replayed DOWN-DOWN-UP could otherwise
        // leave a stale build-arm (`dragArmed_` + its classify-scratch)
        // stranded across a second press. Reset the build-arm state
        // defensively at every fresh press, BEFORE it is (maybe) re-armed
        // below.
        dragArmed_      = false;
        sourceVert_     = -1;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;

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

    // P5 (doc/topopen_p5_remove_plan.md D1): the front-most PRIMARY-layer
    // face under (mx,my), via the tool's OWN `BvhPick` — positional,
    // orientation-independent (a back-facing face is still hit; Remove is
    // not a front-facing-only pick), -1 on a miss (cursor off every polygon
    // silhouette). `FaceBoundsCache` is deliberately NOT used here (D1's
    // rejection: its backface cull-by-normal would wrongly reject a
    // back-facing face). Lazily constructs `removePick_` — mirrors
    // `findSourceVertex`'s guard shape.
    private int pickPrimaryFace(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null || gpu_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (removePick_ is null) removePick_ = new BvhPick();
        return removePick_.pickFace(mx, my, vp, *m, *gpu_);
    }

    // P5 (doc/topopen_p5_remove_plan.md D2), on the Ctrl+MMB "Remove" slot:
    // remove-on-DOWN — one press deletes exactly the front-most
    // primary-layer face under the cursor, capture-faithful (measured a
    // click, down px == up px) and the simplest composition: no
    // `onMouseButtonUp` involvement (that handler stays LEFT-only, so this
    // is disjoint from the P3 build / P4 Move LMB arms above) and no armed
    // state of its own, so it naturally caps at one face per press (a held
    // drag emits no further removes — the drag-sweep extension is
    // UNMEASURED and explicitly deferred, D2/scope). A miss (-1) is a clean
    // no-op (D3) but the gesture is still CONSUMED (`return true`) either
    // way — Ctrl+MMB is unambiguously the Remove gesture, so it should
    // never fall through to camera/selection handling.
    private bool onCtrlMmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int fi = pickPrimaryFace(e.x, e.y, vp);
        if (fi >= 0) removeFaceAt(fi);
        return true;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2): project every EDGE of the
    // PRIMARY layer's mesh and return the nearest within `kTopoPenSnapPx`, or
    // -1 — mirrors `findSourceVertex` above (same threshold, same
    // self-contained no-CONS/no-cache contract), but over edges: each
    // endpoint is projected (skipping the edge if either end is behind the
    // camera) and the cursor's distance to the screen-space SEGMENT (not
    // just the endpoints) is measured via `closestOnSegment2D`. O(E) per
    // press.
    private int findRingSeedEdge(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        int   best   = -1;
        float bestD  = float.infinity;
        foreach (ei, e; m.edges) {
            ImVec2 pa, pb;
            if (!projectPt(m.vertices[e[0]], vp, pa)) continue;
            if (!projectPt(m.vertices[e[1]], vp, pb)) continue;
            float t;
            float d = closestOnSegment2D(cast(float)mx, cast(float)my,
                                        pa.x, pa.y, pb.x, pb.y, t);
            if (d < bestD) { bestD = d; best = cast(int)ei; }
        }
        if (best >= 0 && bestD <= kTopoPenSnapPx) return best;
        return -1;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2): the directed world-space
    // endpoints `ratioFromCursor` measures the `[0,1]` ratio against — MUST
    // match the direction `insertEdgeLoops` treats as this seed edge's
    // p-rail, or a drag toward one end lands the cut near the OTHER end.
    // Copied verbatim from `tools.slice.loop_slice_tool.seedRail` (exact
    // for the CLOSED-ring case this tool scopes to; see that function's own
    // doc comment for the open-ring caveat, inherited unchanged here).
    private void seedRail(uint seedEdge, out Vec3 a, out Vec3 b) {
        auto m = mesh;
        if (m is null) return;
        uint firstFace = uint.max;
        foreach (fi; m.facesAroundEdge(seedEdge)) { firstFace = fi; break; }
        if (firstFace == uint.max) {
            uint va = m.edges[seedEdge][0], vb = m.edges[seedEdge][1];
            a = m.vertices[va]; b = m.vertices[vb];
            return;
        }
        int j0 = m.findEdgeInFace(firstFace, m.edgeKeyOf(seedEdge));
        auto face = m.faces[firstFace];
        uint va = face[j0], vb = face[(j0 + 1) % face.length];
        a = m.vertices[va];
        b = m.vertices[vb];
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2): re-project the cursor
    // onto the armed seed rail and recover the scalar `t` the kernel wants
    // — copied verbatim from `loop_slice_tool.onMouseMotion`'s scrub math
    // (`screenPointToRay` -> `closestPointOnSegmentToRay` -> re-project onto
    // the UNCLAMPED `ab` direction), then clamp to `[0,1]` (REV1 point (c):
    // `closestPointOnSegmentToRay` already clamps its returned POINT to the
    // segment, so this clamp is a defensive backstop, not the primary
    // mechanism). Falls back to 0.5 on a degenerate (zero-length) rail.
    private float ratioFromCursor(int mx, int my, const ref Viewport vp) {
        Vec3 origin, dir;
        screenPointToRay(cast(float)mx, cast(float)my, vp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(seedRailA_, seedRailB_, origin, dir);
        Vec3  ab    = seedRailB_ - seedRailA_;
        float denom = dot(ab, ab);
        if (denom <= 1e-12f) return 0.5f;
        float t = dot(hit - seedRailA_, ab) / denom;
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;
        return t;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 3), on the Shift+MMB "Add
    // Loop" slot: a press picks the nearest primary-layer edge
    // (`findRingSeedEdge`); if none is within snap range, or the picked
    // edge's perpendicular quad ring doesn't exist (`collectEdgeRing`
    // empty — a non-quad or unringed seed), this is not a documented
    // gesture — don't consume, matching every other down-handler's miss
    // convention. Otherwise arms the gesture, captures the seed rail
    // (`seedRail`) once, and seeds `addLoopRatio_` from THIS press's own
    // cursor position so a stationary click (no subsequent motion) still
    // has a sane ratio at commit.
    private bool onShiftMmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        addLoopSeed_  = -1;
        addLoopArmed_ = false;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int seed = findRingSeedEdge(e.x, e.y, vp);
        if (seed < 0) return false;

        auto m = mesh;
        if (m is null) return false;
        bool closed;
        if (m.collectEdgeRing(cast(uint)seed, closed).length == 0) return false;

        addLoopSeed_   = seed;
        addLoopArmed_  = true;
        addLoopStartX_ = e.x;
        addLoopStartY_ = e.y;
        seedRail(cast(uint)seed, seedRailA_, seedRailB_);
        addLoopRatio_  = ratioFromCursor(e.x, e.y, vp);
        return true;
    }

    // Commits whichever gesture is armed at RELEASE, at the release event's
    // own CONS-snapped hit — P3's drag-build (unchanged), or P4's Move/Place
    // disambiguation (doc/topopen_p4_plan.md, Design A: both of P4's
    // outcomes now commit here, never at DOWN). At most one of
    // `dragArmed_`/`placeArmed_`/`moveArmed_` is ever set at a time (each is
    // armed by a distinct GestureSlot's down-handler), so these branches are
    // mutually exclusive in practice; each disarms its own state before
    // returning so a rejected/no-op release never leaves anything stale for
    // the next press to inherit.
    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts) {
        // --- P6 (doc/topopen_p6_addloop_plan.md Phase 3): commits the armed
        // Add Loop gesture at the RELEASE event's own cursor-derived ratio.
        // Disjoint from every LEFT-button gesture below (this branch only
        // fires for MIDDLE); an unarmed MIDDLE release (no press landed on a
        // valid ring seed) doesn't consume, matching every other slot's
        // miss convention.
        if (e.button == SDL_BUTTON_MIDDLE) {
            if (!addLoopArmed_) return false;
            int seed = addLoopSeed_;
            addLoopSeed_  = -1;
            addLoopArmed_ = false;
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            float r = ratioFromCursor(e.x, e.y, vp);
            commitAddLoop(cast(uint)seed, r);
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;

        // --- P3: commits the armed drag-build, if any, at the RELEASE
        // event's own CONS-snapped hit. A release with no real motion since
        // press (a stationary click-on-vertex — "revisit = Move/no-op",
        // capture SESSION 1) builds nothing.
        if (dragArmed_) {
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

        // --- P4 Place: the deferred P2 placement (doc/topopen_p4_plan.md
        // step 1) — commit the SAME `placeVertexAt` path P2 always used,
        // just at release instead of press. A stationary click's DOWN+UP
        // pair still yields exactly one placement (or none, on a bg miss),
        // matching the pre-P4 DOWN-commit behavior bit-for-bit.
        if (placeArmed_) {
            placeArmed_ = false;
            readHit(vts);   // refresh lastHit_ to THIS release event's CONS-snapped hit
            if (lastHit_.hit) placeVertexAt(lastHit_.point, vts);
            return true;
        }

        // --- P4 Move: re-snap the grabbed vertex to the release event's own
        // CONS-snapped hit (doc/topopen_p4_plan.md "The MEASURED mechanism").
        // `moveVertexTo` itself applies the eps no-op guard (stationary grab
        // / all-on-surface no-move -> clean no-op, no undo entry).
        if (moveArmed_) {
            int vi = grabbedVert_;
            moveArmed_   = false;
            grabbedVert_ = -1;
            readHit(vts);   // refresh lastHit_ to THIS release event's CONS-snapped hit
            if (lastHit_.hit) moveVertexTo(vi, lastHit_.point);
            return true;
        }

        return false;
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

    // P4 (doc/topopen_p4_plan.md): commit the armed Move gesture — a
    // position-only write, direct kernel mutation with NO new mesh.d seam
    // (the plan's kernel-layering decision): `m.vertices[vi] = pos` +
    // `m.commitChange(MeshEditScope.Position)` from OUTSIDE `Mesh` is
    // idiomatic in this codebase (`commands/mesh/move_vertex.d`,
    // `edge_slide.d`, `linear_align.d` all do exactly this), bracketed in
    // ONE before/after `MeshSnapshot` pair recorded through the DEDICATED
    // `moveEditFactory_` (OBJ-3 FOLDED — wireName "mesh.topoPen_move", NOT
    // `buildEditFactory_`'s "mesh.topoPen_build"), so one Move drag is one
    // atomic undo entry, mirroring `buildFromSource`'s own
    // capture/mutate/record/refresh shape. A release that re-snaps back to
    // (within eps of) the vertex's CURRENT position — a stationary grab, or
    // an all-on-surface no-move — is a clean no-op: no mutation, no undo
    // entry, matching `buildFromSource`'s degenerate-release convention
    // (this path never partially mutates before the check, so the guard is
    // a simple up-front distance test rather than a restore-after-the-fact).
    private void moveVertexTo(int vi, Vec3 pos) {
        if (meshSrc_ is null || history_ is null || moveEditFactory_ is null) return;
        auto m = mesh;
        if (m is null || vi < 0 || vi >= cast(int)m.vertices.length) return;

        Vec3 origPos = m.vertices[vi];
        enum float kMoveEps = 1e-4f;   // stationary-grab / all-on-surface no-move guard
        if ((pos - origPos).length <= kMoveEps) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);
        m.vertices[vi] = pos;
        m.commitChange(MeshEditScope.Position);
        MeshSnapshot after = MeshSnapshot.capture(*m);

        auto cmd = moveEditFactory_();
        cmd.setSnapshots(before, after, "Topology Move");
        history_.record(cmd);

        m.syncSelection();
        if (gpu_ !is null) gpu_.upload(*m);
        refreshDisplay(m, gpu_, vc_, ec_, fc_);
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
                // -derived (doc/topopen_p3_plan.md "WINDING" finding); it
                // assumes an OUTWARD-side release. A wrong-side or exactly
                // collinear release makes [A,B,N] self-intersecting or
                // zero-area — `makePolygonFromVerts` rejects the zero-area
                // case (-1, review SHOULD-FIX: rolled back below) but NOT a
                // merely self-intersecting one, which is accepted verbatim,
                // matching the reference (no wrong-side capture contradicts
                // it).
                if (m.makePolygonFromVerts([cast(uint)a, b, cast(uint)n], false,
                                           /*autoOrient*/false) < 0) {
                    // Degenerate/wrong-side release (collinear A-B-N ->
                    // Newell-null): only `b` itself would be left stray.
                    // Restore `before` so the whole gesture is a clean
                    // no-op rather than a silently-committed stray vertex.
                    before.restore(*m);
                    return;
                }
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
                // Same winding caveat as CASE-TRI above: [P,A,Q,B] assumes an
                // outward-side release; a wrong-side B yields a bowtie
                // (self-intersecting quad), accepted verbatim unless its
                // signed area cancels to zero (Newell-null — rejected below).
                auto mask = new bool[](m.faces.length);
                mask[triFi] = true;
                m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
                if (m.makePolygonFromVerts([cast(uint)p, cast(uint)a, cast(uint)q, b],
                                           false, /*autoOrient*/false) < 0) {
                    // Degenerate/wrong-side release (review SHOULD-FIX): by
                    // this point the source triangle is ALREADY deleted and
                    // `b` already added — a bare `return` here would leave 3
                    // floating edges + a stray vertex committed as this
                    // gesture's one undo entry. `before` predates BOTH the
                    // triangle delete and the vertex add, so restoring it
                    // makes the whole gesture a clean no-op instead.
                    before.restore(*m);
                    return;
                }
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

    // P5 (doc/topopen_p5_remove_plan.md D4/D5): commit a single-face removal
    // — deletes ONLY `faceIdx`, keeping orphaned points AND orphaned edges
    // (`deleteFacesByMask(keepOrphans:true, keepFloatingEdges:true)`, D5), as
    // one atomic undo entry via the DEDICATED `removeEditFactory_`
    // (`MeshEditScope.Geometry` — a removal IS a topology change, unlike
    // Move's Position-only scope; opponent KILLER-1 — never
    // `buildEditFactory_`/`moveEditFactory_`, which would bake the wrong
    // wire name onto this op). A miss/out-of-range `faceIdx` bails BEFORE
    // any mutation (D3) — mirrors `moveVertexTo`'s up-front guard shape.
    //
    // On SUCCESS, calls `resyncSession()` (opponent KILLER-2, Risk 1): the
    // tool never overrides `isDragging()`, so a Ctrl+MMB Remove can fire
    // while a Shift+LMB build (`dragArmed_`/`quadTriFi_`) or an LMB Move
    // (`moveArmed_`/`grabbedVert_`) is armed on a DIFFERENT button; this
    // kernel call COMPACTS `faces[]`, so those cached indices would dangle
    // (silent mis-delete or a RangeError on the sibling gesture's eventual
    // release) unless invalidated here, before the sibling ever reads them
    // again — the same idiom `resyncSession` already provides for an
    // external undo/redo navigation.
    private void removeFaceAt(int faceIdx) {
        if (meshSrc_ is null || history_ is null || removeEditFactory_ is null) return;
        auto m = mesh;
        if (m is null || faceIdx < 0 || faceIdx >= cast(int)m.faces.length) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        auto mask = new bool[](m.faces.length);
        mask[faceIdx] = true;
        m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = removeEditFactory_();
        cmd.setSnapshots(before, after, "Topology Remove");
        history_.record(cmd);

        // Opponent KILLER-2: invalidate any OTHER armed gesture's cached
        // indices now that faces[] has been compacted out from under them.
        resyncSession();

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 4): commit the armed Add Loop
    // gesture — FULL KERNEL REUSE, zero kernel change. The clamp/exact
    // -vertex-inserts-nothing guard is copied VERBATIM from
    // `MeshAddLoop.evaluate` (`source/commands/mesh/loop_slice.d:68-69`):
    // `r` is already in `[0,1]` (`ratioFromCursor`'s own clamp), so this is
    // an open-INTERVAL check, not a re-clamp. The dry-run
    // `collectEdgeRing` call mirrors that same command's defensive
    // re-check (the mesh is never mutated between arm and commit, so the
    // ring cannot have vanished, but a stale seed index after some other
    // path's mutation is cheap to guard against here too). The entire
    // topology op is the ONE `insertEdgeLoops` call below — bracketed in a
    // single before/after `MeshSnapshot` pair, recorded through the
    // DEDICATED `addLoopEditFactory_` (REV1 obj-1 — never
    // `buildEditFactory_`/`moveEditFactory_`/`removeEditFactory_`, which
    // would bake the wrong wire name onto a loop-cut).
    //
    // REV1 KILLER-2: `insertEdgeLoops`/`insertEdgeLoopsMulti` does
    // `faces = newFaces` — a WHOLESALE rebuild (every ring face expands
    // into 2, shifting every subsequent face index). A concurrently-armed
    // Shift+LMB build's `quadTriFi_` is a FACE index that would dangle
    // (silent wrong-face delete on that build's eventual release) unless
    // invalidated here — `resyncSession()` is called on SUCCESS, in the
    // SAME position `removeFaceAt` above calls it (right after
    // `history_.record`, before `syncSelection`/the display tail), for the
    // identical reason (the tool never overrides `isDragging()`, so a
    // Shift+MMB Add Loop CAN fire mid-build/mid-move on a different
    // button). No `resizeVertexSelection` needed here — `insertEdgeLoops`
    // already rebuilds the selection arrays itself; the `after` snapshot +
    // `syncSelection` cover it.
    private void commitAddLoop(uint seedEdge, float r) {
        if (meshSrc_ is null || history_ is null || addLoopEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;

        // Verbatim MeshAddLoop.evaluate's open-interval guard: a ratio
        // landing exactly on a vertex (r<=0 or r>=1) inserts nothing.
        if (r <= 0.0f || r >= 1.0f) return;

        bool closed;
        if (m.collectEdgeRing(seedEdge, closed).length == 0) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        bool ok = m.insertEdgeLoops(seedEdge, [r]);
        if (!ok) { before.restore(*m); return; }

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = addLoopEditFactory_();
        cmd.setSnapshots(before, after, "Topology Add Loop");
        history_.record(cmd);

        // REV1 KILLER-2: invalidate any OTHER armed gesture's cached
        // indices now that faces[] has been wholesale-rebuilt.
        resyncSession();

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // Stored drag-arm index/case dangle across an external history
    // navigation mid-drag (a redo/undo elsewhere could delete the source
    // vertex or its incident geometry out from under an armed gesture) — the
    // driver calls this on every such navigation; clear the whole armed
    // state rather than trust a possibly-stale index. Covers P4's Move/Place
    // arm state (doc/topopen_p4_plan.md) the same way — an external undo/redo
    // could equally delete a grabbed vertex out from under an armed Move.
    // P6 (doc/topopen_p6_addloop_plan.md Risk "stale armed state"): also
    // clears the Add Loop arm — a history nav between MMB-down and MMB-up
    // could otherwise commit against a dangling seed edge index.
    override void resyncSession() {
        sourceVert_     = -1;
        dragArmed_      = false;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
        placeArmed_     = false;
        moveArmed_      = false;
        grabbedVert_    = -1;
        addLoopSeed_    = -1;
        addLoopArmed_   = false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false) {
        auto dl = ImGui.GetForegroundDrawList();

        // P6 (doc/topopen_p6_addloop_plan.md Phase 5): the Add Loop ghost is
        // independent of `lastHit_`/CONS (this gesture never touches the
        // background constraint — pure current-layer topology op), so it is
        // drawn BEFORE the `lastHit_.hit` early-return below: a primary-only
        // scene with no background layer (hence no CONS hit ever) must still
        // preview the armed seed ring. Purely re-reads already-classified
        // state (`addLoopSeed_`/`seedRailA_`/`seedRailB_`/`addLoopRatio_`) —
        // no mesh mutation, no raycast.
        if (addLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && addLoopSeed_ >= 0 && addLoopSeed_ < cast(int)m.edges.length) {
                enum uint loopCol = IM_COL32(255, 90, 220, 220);   // add-loop magenta
                foreach (ei; m.loopSliceRingEdges(cast(uint)addLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    ImVec2 ra, rb;
                    if (projectPt(m.vertices[ringE[0]], vp, ra)
                     && projectPt(m.vertices[ringE[1]], vp, rb))
                        dl.AddLine(ra, rb, loopCol, 2.0f);
                }
                Vec3 markerPos = seedRailA_ + (seedRailB_ - seedRailA_) * addLoopRatio_;
                ImVec2 mk;
                if (projectPt(markerPos, vp, mk))
                    dl.AddCircleFilled(mk, 5.0f, loopCol, 16);
            }
        }

        if (!lastHit_.hit) return;

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

        // P4 (doc/topopen_p4_plan.md): ghost preview of an in-progress Move
        // drag — since the commit is deferred to RELEASE (Design A), this is
        // the ONLY live feedback for the grabbed vertex: a line from its
        // CURRENT (pre-commit) position to the live CONS-snapped re-snap
        // point, plus a ghost dot at that point. Mirrors the `dragArmed_`
        // ghost block immediately above (same `hitPt`/projectPt inputs); no
        // mesh mutation, no raycast.
        if (moveArmed_ && hitPtOk && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && grabbedVert_ >= 0 && grabbedVert_ < cast(int)m.vertices.length) {
                enum uint moveGhostCol = IM_COL32(80, 220, 120, 220);   // move ghost green
                ImVec2 fromPt;
                if (projectPt(m.vertices[grabbedVert_], vp, fromPt))
                    dl.AddLine(fromPt, hitPt, moveGhostCol, 2.0f);
                dl.AddCircleFilled(hitPt, 5.0f, moveGhostCol, 16);
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

        // P4 (doc/topopen_p4_plan.md): the armed Move/Place disambiguation
        // state, for Tier-C tests to assert WHICH gesture a plain-LMB press
        // armed (and the grabbed vertex, for Move) without driving a full
        // release.
        root["placeArmed"]  = JSONValue(placeArmed_);
        root["moveArmed"]   = JSONValue(moveArmed_);
        root["grabbedVert"] = JSONValue(grabbedVert_);

        // P6 (doc/topopen_p6_addloop_plan.md Phase 5): the armed Add Loop
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and tracked ratio without driving a full release.
        root["addLoopArmed"] = JSONValue(addLoopArmed_);
        root["addLoopSeed"]  = JSONValue(addLoopSeed_);
        root["addLoopRatio"] = JSONValue(cast(double)addLoopRatio_);

        return root;
    }
}

// ---------------------------------------------------------------------------
// buildFromSource — degenerate/wrong-side release is a clean no-op (review
// SHOULD-FIX, doc/topopen_p3_plan.md). `makePolygonFromVerts(autoOrient:
// false)` returns -1 on a collinear/zero-area (Newell-null) vertex order,
// and by the time either CASE-TRI or CASE-QUAD reaches that call the mesh
// has ALREADY been mutated (the new vertex `b`, and CASE-QUAD's own
// source-triangle delete) — so a bare `return` on that -1 used to leave
// the partial mutation committed as the gesture's one undo entry
// (CASE-QUAD: 3 floating edges + a stray vertex; CASE-TRI: a stray
// vertex). Driven directly (private, same-module access — this failure
// path never reaches gpu_/refreshDisplay, so it's safe under a bare
// `dub test` with no GL context) with a `bPos` placed EXACTLY at an
// existing vertex's own position:
//   CASE-TRI:  B == N's position -> [A,B,N] collapses to a doubled line
//              (zero area is an exact geometric fact for 3 points where
//              two coincide, not a float-precision coincidence).
//   CASE-QUAD: B == A's position -> the spliced quad's two triangular
//              lobes (P,A,Q) and (Q,B,P) cancel EXACTLY: SignedArea
//              (Q,B,P) with B==A equals -SignedArea(P,A,Q) by the same
//              "reverse the vertex order negates signed area" identity,
//              regardless of P/A/Q's actual coordinates.
// Both are exact identities (no camera/raycast round-trip involved), so
// the Newell-null rejection triggers deterministically.
unittest {
    import view            : View;
    import editmode        : EditMode;
    import mesh_edit_delta : MeshEditScope;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.buildEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_build", "Topology Build",
                                                    MeshEditScope.Geometry | MeshEditScope.Marks);

    // --- CASE-TRI: hub A(0) with one bare edge to N(1); release collinear
    // (B placed exactly at N's own position) ---
    {
        Mesh m;
        t.meshSrc_ = () => &m;

        uint a = m.addVertex(Vec3(0, 0, 0));
        uint n = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(a, n);
        m.buildLoops();

        auto before = MeshSnapshot.capture(m);
        t.buildFromSource(cast(int)a, BuildCase.Tri, cast(int)n, -1, -1, -1,
                          Vec3(2, 0, 0));   // == N's own position -> collinear
        auto after = MeshSnapshot.capture(m);

        assert(after.vertices == before.vertices,
            "CASE-TRI degenerate release must not leave a stray vertex");
        assert(after.edges == before.edges,
            "CASE-TRI degenerate release must not add a stray edge");
        assert(after.faces == before.faces,
            "CASE-TRI degenerate release must not add a face");
        assert(!history.canUndo(),
            "CASE-TRI degenerate release must record NO undo entry");
    }

    // --- CASE-QUAD: hub A is the apex of an existing triangle [P,A,Q];
    // release at B == A's own position -> the spliced quad's two lobes
    // cancel exactly (Newell-null) ---
    {
        Mesh m;
        t.meshSrc_ = () => &m;

        uint p = m.addVertex(Vec3(1, 0, 0));
        uint a = m.addVertex(Vec3(0, 1, 0));
        uint q = m.addVertex(Vec3(-1, 0, 0));
        int triFi = m.makePolygonFromVerts([p, a, q], false);
        assert(triFi >= 0, "setup: the source triangle must be valid");

        auto before = MeshSnapshot.capture(m);
        t.buildFromSource(cast(int)a, BuildCase.Quad, -1, cast(int)p, cast(int)q, triFi,
                          Vec3(0, 1, 0));   // == A's own position -> bowtie cancels to zero area
        auto after = MeshSnapshot.capture(m);

        assert(after.vertices == before.vertices,
            "CASE-QUAD degenerate release must not leave a stray vertex");
        assert(after.edges == before.edges,
            "CASE-QUAD degenerate release must not leave floating edges");
        assert(after.faces == before.faces,
            "CASE-QUAD degenerate release must restore the ORIGINAL triangle, not a partial mutation");
        assert(!history.canUndo(),
            "CASE-QUAD degenerate release must record NO undo entry");
    }
}

// ---------------------------------------------------------------------------
// moveVertexTo — the eps no-op guard (P4, doc/topopen_p4_plan.md hard
// requirement #4): a release landing back within eps of the grabbed
// vertex's CURRENT position (stationary grab / all-on-surface no-move)
// must leave the mesh untouched and record NO undo entry. Driven directly
// (private, same-module access) — the no-op path returns BEFORE the
// `refreshDisplay`/`gpu_.upload` tail, so it's safe under a bare `dub test`
// with no GL context, mirroring the buildFromSource degenerate-release
// unittest immediately above. (The committing/"real move" path — which DOES
// reach `gpu_.upload` and therefore needs a live GL context — is covered
// end-to-end by the HTTP suite instead: test_topopen_move_drag.d /
// test_topopen_move_undo_redo.d.)
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_move", "Topology Move",
                                                   MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(1, 2, 3));

    // Stationary grab: release EXACTLY at the vertex's own position.
    auto before = MeshSnapshot.capture(m);
    t.moveVertexTo(cast(int)a, Vec3(1, 2, 3));
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices, "stationary grab must not move the vertex");
    assert(!history.canUndo(), "stationary grab must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resolveGestureSlot — Ctrl+MMB dispatch guard (P5, doc/topopen_p5_remove_plan.md
// D6): a pure Tier-A pin so a bad merge that silently reverted the `CtrlMmb`
// dispatch case would be caught by `dub test`, not just by best-effort
// Tier-C (the P3 dispatch had no such guard prior to this phase).
// ---------------------------------------------------------------------------
unittest {
    assert(resolveGestureSlot(SDL_BUTTON_MIDDLE, KMOD_CTRL) == GestureSlot.CtrlMmb,
        "Ctrl+MMB must resolve to the Remove gesture slot");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T1 (P5, doc/topopen_p5_remove_plan.md §Testing, DOMINO):
// removing an INTERIOR/shared-edge face must keep the OTHER face
// byte-unchanged and every edge/vertex in place — the strongest
// keepOrphans+keepFloatingEdges proof (default flags would drop the 3
// now-floating edges instead, discriminating). Driven directly (private,
// same-module access; no gpu_/BVH needed — the display tail is guarded off).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    // Two quads sharing edge 1-2: F0=[0,1,2,3], F1=[1,4,5,2].
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 0, 1));   // 2
    m.addVertex(Vec3(0, 0, 1));   // 3
    m.addVertex(Vec3(2, 0, 0));   // 4
    m.addVertex(Vec3(2, 0, 1));   // 5
    m.addFace([0u, 1u, 2u, 3u]);   // F0 = face index 0
    m.addFace([1u, 4u, 5u, 2u]);   // F1 = face index 1
    m.buildLoops();

    assert(m.vertices.length == 6 && m.edges.length == 7 && m.faces.length == 2,
        "setup: pre-state must be the hand-enumerated domino (6v/7e/2f)");

    t.removeFaceAt(0);   // remove F0

    assert(m.faces.length == 1 && m.faces[0] == [1u, 4u, 5u, 2u],
        "F1 must survive byte-unchanged");
    assert(m.edges.length == 7,
        "keepFloatingEdges must preserve every edge, incl. the 3 now-floating ones (01,23,30)");
    assert(m.vertices.length == 6,
        "keepOrphans must preserve every vertex, incl. 0 and 3 now face-unreferenced");
    assert(history.canUndo(), "a real removal must record one undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T2 (P5, doc/topopen_p5_remove_plan.md §Testing, GRID
// CORNER): removing a CORNER face on a multi-face grid must leave the
// other 3 faces byte-unchanged and the corner's 2 exclusive boundary edges
// surviving as floating edges — confirms Remove leaves every OTHER face
// intact on a mesh bigger than a single pair.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m = makeGridPlane(2);   // 2x2 quads: 9 verts, 12 edges, 4 faces
    t.meshSrc_ = () => &m;

    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        "setup: pre-state must be the 2x2 grid");

    auto other1 = m.faces[1].dup;
    auto other2 = m.faces[2].dup;
    auto other3 = m.faces[3].dup;

    t.removeFaceAt(0);   // corner face

    assert(m.faces.length == 3, "exactly one face must be removed");
    assert(m.faces[0] == other1 && m.faces[1] == other2 && m.faces[2] == other3,
        "the other 3 faces must survive byte-unchanged");
    assert(m.edges.length == 12,
        "keepFloatingEdges must preserve all 12 edges, incl. the corner's 2 now-floating ones");
    assert(m.vertices.length == 9, "keepOrphans must preserve every vertex");
    assert(history.canUndo(), "a real removal must record one undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T3 (P5, doc/topopen_p5_remove_plan.md §Testing, D3): a miss
// (-1) or an out-of-range face index must be a byte-identical no-op — no
// mutation, no undo entry recorded.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    m.addFace([v0, v1, v2]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.removeFaceAt(-1);                       // miss
    t.removeFaceAt(cast(int)m.faces.length);  // out-of-range
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "miss/out-of-range must not mutate the mesh");
    assert(!history.canUndo(), "miss/out-of-range must record NO undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T4 (P5, doc/topopen_p5_remove_plan.md §Testing): a real
// removal must undo back to the exact pre-removal state, including the
// kept orphan edges/vertices and the removed face itself.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1));
    m.addVertex(Vec3(0, 0, 1));
    m.addVertex(Vec3(2, 0, 0));
    m.addVertex(Vec3(2, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([1u, 4u, 5u, 2u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.removeFaceAt(0);
    assert(history.canUndo(), "a real removal must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-removal state, incl. the removed face");
}

// ---------------------------------------------------------------------------
// resolveGestureSlot — Shift+MMB dispatch guard (P6,
// doc/topopen_p6_addloop_plan.md), the same Tier-A pin shape as the P5
// Ctrl+MMB guard above: a pure, camera-free regression guard so a bad merge
// that silently reverted the `ShiftMmb` dispatch case would be caught by
// `dub test`, not just by best-effort Tier-C.
// ---------------------------------------------------------------------------
unittest {
    assert(resolveGestureSlot(SDL_BUTTON_MIDDLE, KMOD_SHIFT) == GestureSlot.ShiftMmb,
        "Shift+MMB must resolve to the Add Loop gesture slot");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T1 (P6, doc/topopen_p6_addloop_plan.md §Testing, "cube belt
// r=0.5"): FULL kernel reuse via `insertEdgeLoops` on the SAME cube + seed
// edge (0-1) as `source/mesh_ops/loop_slice.d`'s own closed-ring unittest —
// Δv=+4/Δe=+8/Δf=+4 (8/12/6 -> 12/20/10), every new vertex at the EXACT
// midpoint of one of the 4 crossed belt edges. Driven directly (private,
// same-module access; `gpu_` stays null so the guarded display tail never
// runs under bare `dub test`, mirroring `moveVertexTo`/`removeFaceAt`'s own
// unittests above).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.math : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max, "setup: seed edge 0-1 must exist on the default cube");
    assert(m.vertices.length == 8 && m.edges.length == 12 && m.faces.length == 6,
        "setup: pre-state must be the untouched cube");

    t.commitAddLoop(seed, 0.5f);

    assert(m.vertices.length == 12,
        format("cube belt r=0.5 must add exactly 4 vertices; got %d", m.vertices.length));
    assert(m.edges.length == 20,
        format("cube belt r=0.5 must add exactly 8 edges; got %d", m.edges.length));
    assert(m.faces.length == 10,
        format("cube belt r=0.5 must add exactly 4 faces; got %d", m.faces.length));

    static bool hasVertNear(const ref Mesh mm, float x, float y, float z, float eps = 1e-4f) {
        foreach (v; mm.vertices)
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps) return true;
        return false;
    }
    // Independently-computed midpoints of the 4 crossed belt edges (0-1,
    // 2-3, 6-7, 4-5 — same belt loop_slice.d's own insertEdgeLoops unittest
    // walks), from the cube's OWN hand-known vertex coordinates, never from
    // the tool's own output.
    assert(hasVertNear(m, 0.0f, -0.5f, -0.5f), "midpoint of edge 0-1 must exist at (0,-0.5,-0.5)");
    assert(hasVertNear(m, 0.0f,  0.5f, -0.5f), "midpoint of edge 2-3 must exist at (0,0.5,-0.5)");
    assert(hasVertNear(m, 0.0f,  0.5f,  0.5f), "midpoint of edge 6-7 must exist at (0,0.5,0.5)");
    assert(hasVertNear(m, 0.0f, -0.5f,  0.5f), "midpoint of edge 4-5 must exist at (0,-0.5,0.5)");

    assert(history.canUndo(), "a real Add Loop cut must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T2 (P6, doc/topopen_p6_addloop_plan.md §Testing, "cube belt
// r=0.25"): the SAME closed ring, cut at an off-center ratio — every new
// vertex must sit at parameter 0.25 FROM ONE END of its own crossed edge
// (the ± resolves the per-face orientation sign-flip the plan documents;
// symmetric only at r=0.5, which T1 above already covers). Independent
// expecteds computed from the belt edges' OWN pre-cut endpoint coordinates
// (captured before the cut), never from the tool's own output.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);

    // Belt edges' endpoints, captured BEFORE the cut (independent ground truth).
    Vec3[2][4] belt = [
        [m.vertices[0], m.vertices[1]],
        [m.vertices[2], m.vertices[3]],
        [m.vertices[6], m.vertices[7]],
        [m.vertices[4], m.vertices[5]],
    ];

    t.commitAddLoop(seed, 0.25f);
    assert(m.vertices.length == 12, "r=0.25 must still add exactly 4 vertices");

    static bool near(Vec3 p, Vec3 q, float eps) {
        return abs(p.x - q.x) < eps && abs(p.y - q.y) < eps && abs(p.z - q.z) < eps;
    }
    enum float eps = 1e-4f;
    foreach (i; 8 .. 12) {
        Vec3 v = m.vertices[i];
        bool matched = false;
        foreach (pair; belt) {
            Vec3 lo = pair[0] + (pair[1] - pair[0]) * 0.25f;
            Vec3 hi = pair[0] + (pair[1] - pair[0]) * 0.75f;
            if (near(v, lo, eps) || near(v, hi, eps)) { matched = true; break; }
        }
        assert(matched,
            "each new vertex must sit at param 0.25 (or its 0.75 sign-flip) "
          ~ "from one end of its own crossed belt edge");
    }
}

// ---------------------------------------------------------------------------
// commitAddLoop — T3 (P6, doc/topopen_p6_addloop_plan.md §Testing, "clamp ->
// no-op"): a ratio landing exactly on a vertex (r<=0 or r>=1) must be a
// byte-identical no-op — no mutation, no undo entry — the verbatim
// `MeshAddLoop.evaluate` open-interval guard copied into `commitAddLoop`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);

    auto before = MeshSnapshot.capture(m);
    t.commitAddLoop(seed, 1.0f);
    t.commitAddLoop(seed, 0.0f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "an exact-vertex ratio (0 or 1) must be a byte-identical no-op");
    assert(!history.canUndo(), "clamp no-op must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T4 (P6, doc/topopen_p6_addloop_plan.md §Testing, "undo
// restores exact"): a real Add Loop cut must undo back to the exact pre-cut
// state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);

    auto before = MeshSnapshot.capture(m);
    t.commitAddLoop(seed, 0.5f);
    assert(history.canUndo(), "a real Add Loop cut must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-cut state");
}
