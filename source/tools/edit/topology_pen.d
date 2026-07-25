module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : hypot;

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
import constraint           : resolveHoverTarget, kTopoPenSnapPx, closestPointOnMeshes;
import snap                  : backgroundSourcesSnapshot;
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

/// Factory the tool calls ONCE PER SLIDE GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P7, doc/topopen_p7_slide_plan.md) — a
/// FIFTH dedicated factory, distinct from every sibling above: a
/// constrained-edge slide is Position-only (like `TopoPenMoveFactory`), but
/// reusing `moveEditFactory_` would bake the wrong `wireName`
/// ("mesh.topoPen_move" on a slide — corrupts undo history / event-log
/// replay / macros). Wired with `wireName="mesh.topoPen_slide"` and
/// `MeshEditScope.Position` at the app.d construction site, mirroring
/// `topoPenMoveEditFactory`.
alias TopoPenSlideFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER SMOOTH GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P8, doc/topopen_p8_smooth_plan.md) — a
/// SIXTH dedicated factory, distinct from every sibling above: a multi-pass
/// relax+re-snap gesture is Position-only (like `TopoPenMoveFactory`/
/// `TopoPenSlideFactory`), but reusing either would bake the wrong
/// `wireName` ("mesh.topoPen_move"/"mesh.topoPen_slide" on a smooth gesture
/// — corrupts undo history / event-log replay / macros). Wired with
/// `wireName="mesh.topoPen_smooth"` and `MeshEditScope.Position` at the
/// app.d construction site, mirroring `topoPenSlideEditFactory`.
alias TopoPenSmoothFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER SPLIT GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P9, doc/topopen_p9_split_plan.md) — a
/// SEVENTH dedicated factory, distinct from every sibling above: a
/// vertex-to-vertex polygon split IS a topology change (new edge, one face
/// becomes two — like `TopoPenRemoveFactory`/`TopoPenAddLoopFactory`), but
/// reusing either would bake the wrong `wireName` ("mesh.topoPen_remove"/
/// "mesh.topoPen_addloop" on a split — corrupts undo history / event-log
/// replay / macros). Wired with `wireName="mesh.topoPen_split"` and
/// `MeshEditScope.Geometry` at the app.d construction site, mirroring
/// `topoPenRemoveEditFactory`.
alias TopoPenSplitFactory = MeshSessionEdit delegate();

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
    CtrlLmb,       // Ctrl,       LMB — Slide / Edge Slide — THIS PHASE (P7)
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
// TopologyPenTool — Phases P0 + P1 + P2 + P3 + P4 + P5 + P6 + P7 of the
// topology-pen port (factory id `mesh.topoPen`, doc/topopen_p0_plan.md,
// doc/topopen_p1_plan.md, doc/topopen_p2_plan.md, doc/topopen_p3_plan.md,
// doc/topopen_p4_plan.md, doc/topopen_p5_remove_plan.md,
// doc/topopen_p6_addloop_plan.md, doc/topopen_p7_slide_plan.md).
//
// P7 adds SLIDE on the **Ctrl+LMB** overlay slot (`GestureSlot.CtrlLmb`,
// doc/topopen_p7_slide_plan.md, V1-scope Option B — EDGE grab): a press
// picks the nearest primary-layer EDGE (`findRingSeedEdge`, reused verbatim
// from P6) and arms a constrained slide for each grabbed endpoint that has
// EXACTLY ONE remaining incident edge (`continuationNeighbor`, over the raw
// `edgeNeighbors` scan — P3 KILLER-1) — that endpoint slides COLINEARLY
// along its own remaining edge, `[0,1]`-clamped at the neighbor
// (`slidePoint`, a pure clamped lerp; `t=1` lands EXACTLY on the neighbor's
// pre-slide position). An endpoint with zero or 2+ remaining incident edges
// is HELD FIXED — the reference's (deferred) per-vertex valence>2 direction-
// selection rule never fired in the capture (plan §5); rather than guess which of ≥2 colinear/
// non-colinear neighbors it would pick, V1 conservatively holds such an
// endpoint fixed (an under-approximation, never a wrong direction) and
// defers the extension to a follow-up capture (plan §Follow-up capture).
// Commit is deferred to release (`onMouseButtonUp`, `commitSlide`) — a
// direct Position-only kernel write (`m.vertices[i]=pos` +
// `commitChange(Position)`, mirroring `moveVertexTo`, extended to up to 2
// vertices), one atomic undo via its OWN dedicated `slideEditFactory_`
// (wireName "mesh.topoPen_slide" — never `moveEditFactory_`, despite
// sharing its Position-only scope, or the undo history / event-log replay /
// macro dispatch would misname this op). Zero topology change, so — unlike
// P5/P6 — `commitSlide` does NOT call `resyncSession()` (no `faces[]`/
// `edges[]`/`vertices[]` resize/rebuild for a sibling's cached index to
// dangle against). REV1 FIX-1 (cross-arm coupling): a private
// `resetAllGestureArms()` helper now clears EVERY arm group (P3 build, P4
// Move/Place, P6 Add Loop, P7 Slide) and is called at the TOP of every
// LEFT-button gesture-DOWN handler (`onPlainLmbDown`/`onShiftLmbDown`/
// `onCtrlLmbDown`) BEFORE that press (maybe) re-arms exactly one of them —
// superseding the old per-handler partial resets, which left OTHER arm
// groups stranded true across a replayed/malformed DOWN-DOWN-UP sequence (a
// later release would then fire the WRONG committer against stale
// indices). `resyncSession()` itself is now a one-line call to the same
// helper. `onCtrlMmbDown`/`onShiftMmbDown` (the MIDDLE-button handlers)
// deliberately do NOT get this call: unlike the same-physical-button
// DOWN-DOWN-without-UP hazard the LEFT-button trio can only suffer from a
// malformed replay, a DIFFERENT button (MIDDLE) genuinely CAN be pressed
// while LEFT is still legitimately held (a real two-button chord) — an
// unconditional reset there would cancel an in-progress Move/Build/Slide
// drag the user still expects to commit on their eventual LEFT release.
// Their own hazards are already closed by existing mechanisms instead: a
// same-slot MIDDLE re-press is guarded by Add Loop's own top-of-handler
// reset, and a cross-arm hazard from a SUCCESSFUL Remove/Add-Loop mutation
// (which DOES invalidate sibling indices) already goes through
// `resyncSession()` via their own commit paths. REV1 FIX-2 (min-drag gate):
// `onMouseButtonUp`'s Slide branch gates on `kMinDragPx` (mirroring P3
// `:875-877`) using `slideStartX_`/`slideStartY_`, so a Ctrl+LMB
// click-without-drag is an explicit, no-mutation, no-undo-entry no-op —
// consistent with every other gesture's click-vs-drag discipline (a
// stationary slide would already no-op via `commitSlide`'s own eps guard,
// but the explicit gate keeps the discipline uniform and keeps
// `slideStartX_`/`slideStartY_` genuinely read).
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

    // --- P7 Slide gesture deps (doc/topopen_p7_slide_plan.md, REV1) ---
    TopoPenSlideFactory slideEditFactory_;

    // --- P8 Smooth gesture deps (doc/topopen_p8_smooth_plan.md) ---
    TopoPenSmoothFactory smoothEditFactory_;

    // --- P9 Split gesture deps (doc/topopen_p9_split_plan.md) ---
    TopoPenSplitFactory splitEditFactory_;

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

    // --- P7 Slide session state (topology_pen.d,
    // doc/topopen_p7_slide_plan.md, V1-scope Option B). Armed on a Ctrl+LMB
    // press that lands on a primary-layer edge with at least one slidable
    // endpoint (`onCtrlLmbDown`); `slideEndA_`/`slideEndB_` are the grabbed
    // edge's two endpoint vertex indices, `slideNbrA_`/`slideNbrB_` are each
    // endpoint's OWN unique remaining incident-edge neighbor (`-1` when that
    // endpoint is held fixed — zero or 2+ remaining neighbors,
    // `continuationNeighbor`), and `slideTA_`/`slideTB_` are the `[0,1]`
    // fractions each slidable endpoint tracks along ITS OWN rail
    // (`x -> neighbor`), recomputed on every subsequent motion event
    // (`onMouseMotion`) and again at release (`onMouseButtonUp`'s Slide
    // branch, `commitSlide`). Cleared by `onMouseButtonUp` on commit/no-op
    // and by `resyncSession` on an external history navigation, exactly
    // like the P3/P4/P6 arm state above.
    int   slideSeed_  = -1;
    bool  slideArmed_ = false;
    int   slideStartX_, slideStartY_;
    int   slideEndA_ = -1, slideEndB_ = -1;
    int   slideNbrA_ = -1, slideNbrB_ = -1;
    float slideTA_ = 0.0f, slideTB_ = 0.0f;

    // --- P8 Smooth session state (topology_pen.d,
    // doc/topopen_p8_smooth_plan.md). Armed by a Shift+Ctrl+LMB press
    // (`onShiftCtrlLmbDown`) — NO source-vertex pick (whole-primary-mesh
    // scope, unlike every other gesture above) and NO mutation on down;
    // `smoothDragPx_` accumulates cursor travel on every subsequent motion
    // event (`onMouseMotion`) and is converted to a pass count at release
    // (`onMouseButtonUp`'s Smooth branch, `applySmoothPasses`) — the only
    // read of `smoothDragPx_` (REV1 MINOR: the plan's original
    // `smoothPassCount_` field is dropped since it was never assigned;
    // both `onMouseButtonUp` and `toolStateJson()` recompute `N` from
    // `smoothDragPx_` directly). Cleared by `onMouseButtonUp` on
    // commit/no-op and by `resyncSession` on an external history
    // navigation, exactly like the P3/P4/P6/P7 arm state above.
    bool  smoothArmed_ = false;
    int   smoothStartX_, smoothStartY_, smoothLastX_, smoothLastY_;
    float smoothDragPx_ = 0.0f;

    // --- P9 Split session state (topology_pen.d,
    // doc/topopen_p9_split_plan.md). Armed on a plain-MMB press that lands
    // on an existing primary-layer vertex A (`onPlainMmbDown`);
    // `splitTargetVert_` tracks the CURRENT snap target C off every
    // subsequent motion event (`onMouseMotion`) and is re-resolved once more
    // at the release pixel (`onMouseButtonUp`'s MIDDLE branch, `commitSplit`)
    // — the release event's own resolution is authoritative, never the
    // last-motion value (a mouse-up with no intervening motion event must
    // still resolve C at ITS OWN pixel). `-1` means "no vertex under the
    // cursor" (the deferred mid-edge-insert case stays a clean no-op in V1).
    // Cleared by `onMouseButtonUp` on commit/no-op and by `resyncSession` on
    // an external history navigation, exactly like the P3/P4/P6/P7/P8 arm
    // state above.
    bool splitArmed_       = false;
    int  splitSourceVert_  = -1;
    int  splitTargetVert_  = -1;

    // P8 (doc/topopen_p8_smooth_plan.md "Passes: click = 1, drag = N",
    // vibe3d-divergence, throttle constant UNMEASURED — pacing only, the
    // per-pass relax+re-snap LAW itself is measured): a drag of
    // `kSmoothPassStridePx` screen pixels adds one more pass beyond the
    // click's own floor of 1. `MAX_TOPOPEN_SMOOTH_PASSES` is the two-layer
    // DoS backstop (mirrors `MeshSmooth`'s own `MAX_SMOOTH_ITER`,
    // `commands/mesh/smooth.d`) — this is a DERIVED count (drag distance),
    // not a user `Param`, so it needs the kernel cap + floor, not an
    // `enforceBounds()`.
    private enum float kSmoothPassStridePx      = 20.0f;
    private enum int   MAX_TOPOPEN_SMOOTH_PASSES = 256;

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
    // P7 (doc/topopen_p7_slide_plan.md): 7th param `sf` appended LAST for
    // the Slide factory, same rationale — `TopoPenSlideFactory` is yet
    // another structurally identical delegate alias, so it goes after
    // `alf`, never inserted between existing params (every positional
    // caller — registration.d — stays byte-unchanged up through `alf`).
    // P8 (doc/topopen_p8_smooth_plan.md): 8th param `smf` appended LAST
    // (after `sf`) for the Smooth factory — same rationale as every prior
    // addition: `TopoPenSmoothFactory` is yet another structurally
    // identical delegate alias, so inserting it anywhere but the tail would
    // silently mis-bind a sibling gesture's factory rather than fail to
    // compile. `bf`/`mf`/`rf`/`alf`/`sf` MUST stay in their existing
    // positions — every existing positional caller (registration.d) stays
    // byte-unchanged through `sf`.
    // P9 (doc/topopen_p9_split_plan.md): 9th positional param `spf` appended
    // LAST (after `smf`) for the Split factory — same rationale as every
    // prior addition: `TopoPenSplitFactory` is yet another structurally
    // identical delegate alias, so inserting it anywhere but the tail would
    // silently mis-bind a sibling gesture's factory rather than fail to
    // compile. `bf`/`mf`/`rf`/`alf`/`sf`/`smf` MUST stay in their existing
    // positions — every existing positional caller (registration.d) stays
    // byte-unchanged through `smf`.
    void setUndoBindings(CommandHistory h, VertexNewFactory f,
                        TopoPenBuildFactory bf = null,
                        TopoPenMoveFactory mf = null,
                        TopoPenRemoveFactory rf = null,
                        TopoPenAddLoopFactory alf = null,
                        TopoPenSlideFactory sf = null,
                        TopoPenSmoothFactory smf = null,
                        TopoPenSplitFactory spf = null) {
        history_           = h;
        addVertexFactory_  = f;
        buildEditFactory_  = bf;
        moveEditFactory_   = mf;
        removeEditFactory_ = rf;
        addLoopEditFactory_ = alf;
        slideEditFactory_   = sf;
        smoothEditFactory_  = smf;
        splitEditFactory_   = spf;
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

        // P7 (doc/topopen_p7_slide_plan.md Phase 2): while a Slide gesture
        // is armed, recompute each SLIDABLE endpoint's `[0,1]` fraction off
        // THIS motion event's cursor, per its OWN incident-edge rail — the
        // only mid-drag feedback, since commit is deferred to release.
        // Consumes, mirroring the Add Loop branch above. A held-fixed
        // endpoint (`slideNbrA_`/`slideNbrB_ < 0`) has no rail to project
        // onto, so its fraction is simply left at 0 (never read by
        // `commitSlide`/the draw ghost either way).
        if (slideArmed_) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            auto m = mesh;
            if (m !is null) {
                immutable vlen = cast(int)m.vertices.length;
                if (slideNbrA_ >= 0 && slideNbrA_ < vlen && slideEndA_ >= 0 && slideEndA_ < vlen)
                    slideTA_ = ratioOnSegment(e.x, e.y, vp, m.vertices[slideEndA_], m.vertices[slideNbrA_]);
                if (slideNbrB_ >= 0 && slideNbrB_ < vlen && slideEndB_ >= 0 && slideEndB_ < vlen)
                    slideTB_ = ratioOnSegment(e.x, e.y, vp, m.vertices[slideEndB_], m.vertices[slideNbrB_]);
            }
            return true;
        }

        // P8 (doc/topopen_p8_smooth_plan.md Phase 3): while a Smooth
        // gesture is armed, accumulate cursor travel — click=1 pass, a
        // longer drag = more passes (`onMouseButtonUp`'s Smooth branch
        // derives the pass count from THIS running total). No mid-drag
        // mutation/preview beyond `draw()`'s cheap affordance (deferred
        // commit, same rationale as every other armed gesture above).
        // Consumes, mirroring the Add Loop/Slide branches above.
        if (smoothArmed_) {
            smoothDragPx_ += hypot(cast(float)(e.x - smoothLastX_), cast(float)(e.y - smoothLastY_));
            smoothLastX_ = e.x;
            smoothLastY_ = e.y;
            return true;
        }

        // P9 (doc/topopen_p9_split_plan.md Phase 3): while a Split gesture is
        // armed, resolve the CURRENT snap-target vertex C off THIS motion
        // event's cursor — the only mid-drag feedback (the ghost preview,
        // draw() below) and the source of the "snap to a non-adjacent vertex"
        // affordance, since commit is deferred to release. `-1` (no vertex
        // under the cursor) is a normal, valid state — the ghost preview
        // simply tracks the raw cursor instead. Consumes, mirroring the Add
        // Loop/Slide/Smooth branches above.
        if (splitArmed_) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            splitTargetVert_ = findSourceVertex(e.x, e.y, vp);
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

    // P9 (doc/topopen_p9_split_plan.md, kernel-reuse verdict): the ONLY new
    // mesh-adjacent logic this phase adds — resolve WHICH face to pass to
    // `mesh.splitFaceByVertices` as `faceIdx`. Scans `facesAroundVertex(a)`
    // (reliable here — A and C are both existing ON-FACE vertices, unlike
    // the bare/floating-edge verts `classifySource` above has to special-case)
    // and returns the FIRST face that also contains C, non-adjacently in
    // that face's winding — a deterministic non-manifold tie-break (stable
    // iteration order). Returns -1 for every no-op condition: a/c invalid or
    // equal, out of bounds, no shared face, or A/C adjacent (chord would be
    // an existing edge) in every shared face.
    //
    // REV1 FIX-3 (MODERATE): `lo`/`hi` are the SORTED winding positions,
    // computed BEFORE the adjacency reject — using the unsorted
    // (posA, posC) pair directly would let a wrap-around adjacent pair (one
    // endpoint at `len-1`, the other at `0`) evade BOTH reject terms
    // (`hi==lo+1` and `lo==0 && hi==len-1`) whenever posA/posC happen to be
    // passed in the "wrong" relative order, mis-classifying a real edge as
    // splittable in non-manifold topology (a 3+-incident-face edge) where
    // another shared face WOULD have offered a genuine split — this function
    // would then silently return a face where the kernel itself rejects the
    // split (0), dropping a legitimate split the caller can't tell apart
    // from "no common face at all".
    private int findCommonSplitFace(Mesh* m, int a, int c) {
        if (m is null || a < 0 || c < 0 || a == c) return -1;
        if (a >= cast(int)m.vertices.length || c >= cast(int)m.vertices.length) return -1;

        foreach (fi; m.facesAroundVertex(cast(uint)a)) {
            auto f = m.faces[fi];
            int len = cast(int)f.length;
            int posA = -1, posC = -1;
            foreach (k, vv; f) {
                if (vv == cast(uint)a) posA = cast(int)k;
                if (vv == cast(uint)c) posC = cast(int)k;
            }
            if (posC < 0) continue;   // C not on this face -> not the shared one

            int lo = posA < posC ? posA : posC;
            int hi = posA < posC ? posC : posA;
            bool adjacent = (hi == lo + 1) || (lo == 0 && hi == len - 1);
            if (adjacent) continue;   // chord would be an existing edge here

            return cast(int)fi;
        }
        return -1;
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
            case GestureSlot.CtrlLmb:  return onCtrlLmbDown(e, vts);
            case GestureSlot.CtrlMmb:  return onCtrlMmbDown(e, vts);
            case GestureSlot.ShiftMmb: return onShiftMmbDown(e, vts);
            case GestureSlot.ShiftCtrlLmb: return onShiftCtrlLmbDown(e, vts);
            case GestureSlot.Mmb:      return onPlainMmbDown(e, vts);
            case GestureSlot.Rmb:
            case GestureSlot.ShiftRmb:
            case GestureSlot.CtrlRmb:
            case GestureSlot.ShiftCtrlRmb:
            case GestureSlot.ShiftCtrlMmb:
                // TODO: Move+Edge-Loop / Duplicate Loop / the 2 undocumented
                // slots / Smoothing+Edge-Loop — gesture_map.md table A,
                // slots 2/5/8/10/11/12. Not implemented yet.
                return false;
            case GestureSlot.None:
                return false;
        }
    }

    // REV1 FIX-1 (opponent objection 1, cross-arm coupling — doc/topopen_p7_slide_plan.md
    // "REV1"): the single source of truth for "clear every gesture's armed
    // state", called at the TOP of every LEFT-button gesture-DOWN handler
    // (`onPlainLmbDown`/`onShiftLmbDown`/`onCtrlLmbDown`) BEFORE that press
    // (maybe) re-arms exactly one of P3 build / P4 Move-Place / P7 Slide —
    // and by `resyncSession()` (an external history navigation). The former
    // per-handler partial resets (the old NIT-2 pattern: each handler only
    // cleared ITS OWN fields) left every OTHER arm group untouched, so a
    // replayed/malformed DOWN-DOWN-UP sequence for the LEFT button (two
    // presses under different modifier states, no intervening UP) could
    // strand two arm groups simultaneously true; the eventual release would
    // then fire the FIRST-checked committer (`onMouseButtonUp`'s
    // `dragArmed_`-before-`placeArmed_`/`moveArmed_`-before-`slideArmed_`
    // order) against indices captured at a STALE press — a silent
    // wrong-vertex mutation recorded as a legitimate undo entry. Pure safety
    // hardening: a real press/hold/release cycle only ever has ONE arm group
    // true at a time already (gesture identity is pinned at DOWN), so
    // clearing all of them before re-arming exactly one changes nothing for
    // legitimate input.
    //
    // `onCtrlMmbDown`/`onShiftMmbDown` (the MIDDLE-button handlers)
    // deliberately do NOT call this: unlike the LEFT-button trio's hazard —
    // which can only arise from a malformed replay, since real hardware
    // cannot emit two DOWN events for the SAME physical button without an
    // intervening UP — a DIFFERENT button (MIDDLE) genuinely CAN be pressed
    // while LEFT is still legitimately held (a real two-button chord); an
    // unconditional reset there would silently cancel an in-progress
    // Move/Build/Slide drag the user still expects to commit on their
    // eventual LEFT release. Their own hazards are already closed by
    // existing, narrower mechanisms: a same-slot MIDDLE re-press is guarded
    // by Add Loop's own top-of-handler reset (`onShiftMmbDown`, below), and
    // a cross-arm hazard from a SUCCESSFUL Remove/Add-Loop mutation (which
    // DOES invalidate sibling cached indices, unlike a mere re-press)
    // already goes through `resyncSession()` via `removeFaceAt`/
    // `commitAddLoop`'s own commit paths.
    private void resetAllGestureArms() {
        // P3 build (doc/topopen_p3_plan.md)
        sourceVert_     = -1;
        dragArmed_      = false;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
        // P4 Move/Place (doc/topopen_p4_plan.md)
        placeArmed_     = false;
        moveArmed_      = false;
        grabbedVert_    = -1;
        // P6 Add Loop (doc/topopen_p6_addloop_plan.md)
        addLoopSeed_    = -1;
        addLoopArmed_   = false;
        // P7 Slide (doc/topopen_p7_slide_plan.md)
        slideSeed_   = -1;
        slideArmed_  = false;
        slideEndA_ = slideEndB_ = -1;
        slideNbrA_ = slideNbrB_ = -1;
        slideTA_ = slideTB_ = 0.0f;
        // P8 Smooth (doc/topopen_p8_smooth_plan.md)
        smoothArmed_  = false;
        smoothDragPx_ = 0.0f;
        // P9 Split (doc/topopen_p9_split_plan.md) — cleared here so the
        // LEFT-button trio's own reset closes a stray split arm too (e.g. an
        // external history navigation via `resyncSession`, below); the
        // MIDDLE-button `onPlainMmbDown` does NOT call this helper (REV1
        // FIX-1 — see that handler's own doc comment) and uses its own
        // narrow self-reset instead.
        splitArmed_      = false;
        splitSourceVert_ = -1;
        splitTargetVert_ = -1;
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
        // REV1 FIX-1 (doc/topopen_p7_slide_plan.md): full symmetric close —
        // clear EVERY arm group (not just this handler's own
        // `placeArmed_`/`moveArmed_`/`grabbedVert_`, the old NIT-2 partial
        // reset) before the disambiguation below re-arms exactly one.
        // Supersedes the old per-handler partial resets; see
        // `resetAllGestureArms`'s own doc comment for the full hazard this
        // closes.
        resetAllGestureArms();

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
        // REV1 FIX-1 (doc/topopen_p7_slide_plan.md, same rationale as
        // `onPlainLmbDown` above): full symmetric close, superseding the old
        // per-handler partial reset (which only cleared THIS handler's own
        // `dragArmed_` + classify-scratch, leaving Move/Place/Slide's arm
        // state untouched).
        resetAllGestureArms();

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

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2), generalized by P7
    // (doc/topopen_p7_slide_plan.md Phase 2 item 2): re-project the cursor
    // onto an arbitrary segment `[a,b]` and recover the scalar `t` the
    // caller wants — copied verbatim from `loop_slice_tool.onMouseMotion`'s
    // scrub math (`screenPointToRay` -> `closestPointOnSegmentToRay` ->
    // re-project onto the UNCLAMPED `ab` direction), then clamp to `[0,1]`
    // (REV1 point (c): `closestPointOnSegmentToRay` already clamps its
    // returned POINT to the segment, so this clamp is a defensive backstop,
    // not the primary mechanism). Falls back to 0.5 on a degenerate
    // (zero-length) segment. The segment used to be hardwired to the armed
    // Add Loop rail (`seedRailA_`/`seedRailB_`); P7's Slide gesture needs the
    // SAME projection against each grabbed endpoint's OWN incident-edge
    // rail, so the segment is now a parameter — `ratioFromCursor` below is
    // the Add Loop caller's unchanged convenience wrapper.
    private float ratioOnSegment(int mx, int my, const ref Viewport vp, Vec3 a, Vec3 b) {
        Vec3 origin, dir;
        screenPointToRay(cast(float)mx, cast(float)my, vp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(a, b, origin, dir);
        Vec3  ab    = b - a;
        float denom = dot(ab, ab);
        if (denom <= 1e-12f) return 0.5f;
        float t = dot(hit - a, ab) / denom;
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;
        return t;
    }

    private float ratioFromCursor(int mx, int my, const ref Viewport vp) {
        return ratioOnSegment(mx, my, vp, seedRailA_, seedRailB_);
    }

    // P7 (doc/topopen_p7_slide_plan.md, kernel-reuse verdict): pure
    // clamped-lerp helper for the Slide gesture — colinear by construction
    // (the result always lies on the segment `x -> neighbor`, which IS the
    // incident-edge line), `t=1` lands EXACTLY on the neighbor's (pre-slide)
    // position (the measured overshoot clamp), `t=0` leaves `x` untouched.
    // static + pure so it's directly unit-testable without an app-wired
    // instance, mirroring `findRingSeedEdge`/`seedRail`'s own
    // self-contained-helper convention.
    private static Vec3 slidePoint(Vec3 x, Vec3 neighbor, float t) {
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;
        // Canonical lerp form (neighbor*t + x*(1-t)) — FP-exact at BOTH ends
        // (t=1 lands bit-exactly on `neighbor`, the captured clamp), unlike
        // `x + (neighbor-x)*t`. Matches the project's taper-lerp convention.
        return neighbor * t + x * (1.0f - t);
    }

    // P7 (doc/topopen_p7_slide_plan.md, V1-scope Option B): the endpoint
    // `x`'s UNIQUE remaining incident edge, once the grabbed edge's OTHER
    // endpoint `other` is excluded — via the raw `edgeNeighbors` scan (P3
    // KILLER-1, the only adjacency that sees bare/diagonal edges a
    // loop-fan helper would miss). Returns `-1` when `x` has zero
    // (grabbed-edge-only, valence-1) or 2+ (valence>2, the UNMEASURED
    // per-vertex direction-selection rule — deliberately unhandled, never
    // guessed, plan §Follow-up capture) remaining neighbors: either way the
    // endpoint is held FIXED, not slid.
    private static int continuationNeighbor(Mesh* m, uint x, uint other) {
        int found = -1, count = 0;
        foreach (v; m.edgeNeighbors(x)) {
            if (v == other) continue;
            ++count;
            found = cast(int)v;
        }
        return (count == 1) ? found : -1;
    }

    // P7 (doc/topopen_p7_slide_plan.md), on the Ctrl+LMB "Slide" slot
    // (V1-scope Option B — EDGE grab, capture-verified §1/§3/§4): a press
    // picks the nearest primary-layer EDGE (`findRingSeedEdge`, reused
    // verbatim from P6); each endpoint that has EXACTLY ONE remaining
    // incident edge (after excluding the grabbed edge itself) is slidable
    // along that edge (`continuationNeighbor`); an endpoint with zero or 2+
    // remaining incident edges is HELD FIXED (the UNMEASURED per-vertex
    // valence>2 direction-selection rule — never guessed, plan §Follow-up capture). If
    // NEITHER endpoint is slidable, nothing is armed (no documented gesture
    // to perform) — don't consume, matching every other down-handler's miss
    // convention. The commit itself is deferred to release
    // (`onMouseButtonUp`); this only arms + seeds the initial `t` via THIS
    // press's own cursor, so a stationary click still has a sane (harmless,
    // near-zero) fraction at commit.
    private bool onCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // REV1 FIX-1 (doc/topopen_p7_slide_plan.md): full symmetric close —
        // clear EVERY arm group before (maybe) re-arming Slide, superseding
        // the old per-handler partial resets. See `resetAllGestureArms`'s
        // own doc comment for the full hazard this closes.
        resetAllGestureArms();

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int seed = findRingSeedEdge(e.x, e.y, vp);
        if (seed < 0) return false;

        auto m = mesh;
        if (m is null) return false;
        auto edgePair = m.edges[seed];
        int eA = cast(int)edgePair[0], eB = cast(int)edgePair[1];
        int nA = continuationNeighbor(m, cast(uint)eA, cast(uint)eB);
        int nB = continuationNeighbor(m, cast(uint)eB, cast(uint)eA);
        if (nA < 0 && nB < 0) return false;   // neither endpoint slidable -> nothing to do

        slideSeed_   = seed;
        slideArmed_  = true;
        slideStartX_ = e.x;
        slideStartY_ = e.y;
        slideEndA_   = eA;
        slideEndB_   = eB;
        slideNbrA_   = nA;
        slideNbrB_   = nB;
        slideTA_ = (nA >= 0) ? ratioOnSegment(e.x, e.y, vp, m.vertices[eA], m.vertices[nA]) : 0.0f;
        slideTB_ = (nB >= 0) ? ratioOnSegment(e.x, e.y, vp, m.vertices[eB], m.vertices[nB]) : 0.0f;
        return true;
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

    // P9 (doc/topopen_p9_split_plan.md Phase 3), on the plain-MMB "Split"
    // slot: a press picks the nearest primary-layer VERTEX (`findSourceVertex`,
    // reused verbatim from P3/P4); if none is within snap range, this is not
    // a documented gesture — don't consume, matching every other down-
    // handler's miss convention. Otherwise arms the gesture at the picked
    // source vertex A; the target C is resolved live on every subsequent
    // motion event (`onMouseMotion`) and once more, authoritatively, at
    // release (`onMouseButtonUp`'s MIDDLE branch, `commitSplit`).
    //
    // REV1 FIX-1 (KILLER-1): this handler does ONLY its own narrow
    // self-reset — `resetAllGestureArms()` is DELIBERATELY NOT called here,
    // mirroring `onShiftMmbDown`/`onCtrlMmbDown` immediately above (the
    // MIDDLE-button discipline; see `resetAllGestureArms`'s own doc comment
    // for the full rationale): a MIDDLE press can legitimately be a
    // two-button chord while a LEFT gesture (Build/Move/Slide/Smooth) is
    // still held, so an unconditional full reset here would silently cancel
    // that in-progress drag before the user's eventual LEFT release commits
    // it. A same-slot MIDDLE re-press is guarded by this handler's own
    // top-of-function reset, exactly like Add Loop's.
    private bool onPlainMmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        splitArmed_      = false;
        splitSourceVert_ = -1;
        splitTargetVert_ = -1;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int src = findSourceVertex(e.x, e.y, vp);
        if (src < 0) return false;   // no vertex under the cursor -> no documented gesture

        splitArmed_      = true;
        splitSourceVert_ = src;
        splitTargetVert_ = -1;
        return true;
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 3), on the Shift+Ctrl+LMB
    // "Smooth" slot: arms a whole-primary-mesh relax+re-snap gesture — NO
    // source-vertex/edge pick (unlike every other gesture above, this one
    // is scope-free: it relaxes the ENTIRE primary mesh, not a
    // press-selected element) and NO mutation on down. Commit is deferred
    // to release (`onMouseButtonUp`'s Smooth branch, `applySmoothPasses`),
    // reading the accumulated drag distance to derive the pass count. Full
    // symmetric close via `resetAllGestureArms()` (same LEFT-button
    // discipline as `onPlainLmbDown`/`onShiftLmbDown`/`onCtrlLmbDown` — see
    // that helper's own doc comment) before arming, so a stray Move/Build/
    // Slide arm from an earlier press can never survive into this one.
    // Always claims the event (Shift+Ctrl+LMB is unambiguously the Smooth
    // gesture, regardless of what — if anything — is under the cursor).
    private bool onShiftCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        resetAllGestureArms();

        smoothArmed_  = true;
        smoothStartX_ = smoothLastX_ = e.x;
        smoothStartY_ = smoothLastY_ = e.y;
        smoothDragPx_ = 0.0f;
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
        // --- P6/P9 (doc/topopen_p6_addloop_plan.md Phase 3,
        // doc/topopen_p9_split_plan.md REV1 FIX-2): commits whichever MIDDLE
        // gesture is armed, at the RELEASE event's own cursor-derived
        // resolution. REV1 FIX-2 (KILLER-2): per-arm GUARDED returns, not a
        // single unconditional `if (!addLoopArmed_) return false;` early-out
        // — that old shape made a `splitArmed_` check placed "after" it
        // categorically unreachable (Add Loop unarmed -> return false BEFORE
        // ever testing Split). `addLoopArmed_`/`splitArmed_` are armed by
        // disjoint DOWN slots (Shift+MMB vs plain MMB) and
        // `resetAllGestureArms()`/`onPlainMmbDown`'s own narrow reset keep
        // them mutually exclusive in practice, so branch order is immaterial;
        // Add Loop stays first to minimize diff. An unarmed MIDDLE release
        // (no press landed on a valid ring seed / vertex) doesn't consume,
        // matching every other slot's miss convention.
        if (e.button == SDL_BUTTON_MIDDLE) {
            if (addLoopArmed_) {
                int seed = addLoopSeed_;
                addLoopSeed_  = -1;
                addLoopArmed_ = false;
                Viewport vp;
                if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
                float r = ratioFromCursor(e.x, e.y, vp);
                commitAddLoop(cast(uint)seed, r);
                return true;
            }
            if (splitArmed_) {
                int a = splitSourceVert_;
                splitArmed_      = false;
                splitSourceVert_ = -1;
                Viewport vp;
                if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
                // C is resolved AT THE RELEASE PIXEL — authoritative, never
                // the last-motion `splitTargetVert_` (a release with no
                // intervening motion event must still resolve C at its own
                // pixel). `-1` (no vertex under the cursor) is the deferred
                // mid-edge-insert case — `commitSplit` treats it as a clean
                // no-op (V1-SCOPE LINE).
                int c = findSourceVertex(e.x, e.y, vp);
                splitTargetVert_ = -1;
                commitSplit(a, c);
                return true;
            }
            return false;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;

        // --- P8 (doc/topopen_p8_smooth_plan.md Phase 3): commits the armed
        // Smooth gesture — click (zero/near-zero drag) applies exactly ONE
        // pass, a drag applies N (derived from the accumulated cursor
        // travel). Risk 5 (plan): UNLIKE every other gesture above, this
        // one is NOT gated by `kMinDragPx` — a stationary click must still
        // apply its one pass (`applySmoothPasses` itself carries the
        // REV1 FIX-2 no-op-undo guard for the case where that one pass
        // genuinely changes nothing). Checked BEFORE Slide/Build/Place/Move
        // below since it is armed by its own disjoint modifier chord
        // (Shift+Ctrl+LMB) and `resetAllGestureArms()` guarantees at most
        // one of these is ever true at once.
        if (smoothArmed_) {
            smoothArmed_ = false;
            int n = 1 + cast(int)(smoothDragPx_ / kSmoothPassStridePx);
            applySmoothPasses(n);
            return true;
        }

        // --- P7 (doc/topopen_p7_slide_plan.md Phase 3): commits the armed
        // Slide gesture at the RELEASE event's own cursor-derived per-rail
        // fraction. Mutually exclusive with drag-build/Place/Move (at most
        // one of `dragArmed_`/`placeArmed_`/`moveArmed_`/`slideArmed_` is
        // ever true at once — `resetAllGestureArms()` enforces this at
        // every fresh press).
        if (slideArmed_) {
            uint seed   = cast(uint)slideSeed_;
            int  eA     = slideEndA_, eB = slideEndB_;
            int  nA     = slideNbrA_, nB = slideNbrB_;
            int  startX = slideStartX_, startY = slideStartY_;

            slideSeed_  = -1;
            slideArmed_ = false;
            slideEndA_ = slideEndB_ = -1;
            slideNbrA_ = slideNbrB_ = -1;

            // REV1 FIX-2 (doc/topopen_p7_slide_plan.md): a release back at
            // (near enough) the press pixel is a click without a real drag —
            // an explicit, clean no-op (no vertex write, no undo entry),
            // mirroring P3's own `kMinDragPx` guard immediately below. (A
            // zero-drag slide would already no-op via `commitSlide`'s own
            // eps guard, since `t≈0` -> `slidePoint` returns the original
            // position — this gate just keeps the click-vs-drag discipline
            // uniform across every gesture, and keeps `slideStartX_`/
            // `slideStartY_` genuinely read.)
            enum int kMinDragPx = 3;
            int dx = e.x - startX, dy = e.y - startY;
            if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return true;

            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            auto m = mesh;
            float tA = 0.0f, tB = 0.0f;
            if (m !is null) {
                if (nA >= 0) tA = ratioOnSegment(e.x, e.y, vp, m.vertices[eA], m.vertices[nA]);
                if (nB >= 0) tB = ratioOnSegment(e.x, e.y, vp, m.vertices[eB], m.vertices[nB]);
            }
            commitSlide(seed, eA, eB, nA, nB, tA, tB);
            return true;
        }

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

    // P7 (doc/topopen_p7_slide_plan.md Phase 3): commit the armed Slide
    // gesture — writes AT MOST 2 vertex positions (the grabbed edge's own
    // endpoints; a HELD-FIXED endpoint, `nA`/`nB == -1`, keeps its CURRENT
    // position). Position-only, direct kernel mutation
    // (`m.vertices[i] = pos` + `commitChange(Position)`), bracketed in ONE
    // before/after `MeshSnapshot` pair recorded through the DEDICATED
    // `slideEditFactory_` (wireName "mesh.topoPen_slide") — mirrors
    // `moveVertexTo`'s shape, extended to up to 2 vertices. `seed` is a
    // defensive cross-check (the grabbed edge must still connect `eA`/`eB`
    // — guards against a stale/corrupted arm rather than trusting the
    // caller's indices blindly); the eps no-op guard mirrors
    // `moveVertexTo`'s. Zero topology change — never resizes/rebuilds
    // `faces[]`/`edges[]`/`vertices[]` (no `buildLoops`, no
    // `deleteFacesByMask`, no `insertEdgeLoops`) — so unlike P5/P6 this does
    // NOT call `resyncSession()` (plan §Risks: no sibling gesture's cached
    // INDEX can dangle from a pure position write).
    private void commitSlide(uint seed, int eA, int eB, int nA, int nB, float tA, float tB) {
        if (meshSrc_ is null || history_ is null || slideEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;
        if (eA < 0 || eA >= cast(int)m.vertices.length) return;
        if (eB < 0 || eB >= cast(int)m.vertices.length) return;
        if (nA >= cast(int)m.vertices.length) return;
        if (nB >= cast(int)m.vertices.length) return;
        if (seed >= m.edges.length) return;
        auto ep = m.edges[seed];
        bool edgeMatches = (ep[0] == eA && ep[1] == eB) || (ep[0] == eB && ep[1] == eA);
        if (!edgeMatches) return;   // stale/corrupted arm — defensive, should not happen

        Vec3 origA = m.vertices[eA];
        Vec3 origB = m.vertices[eB];
        Vec3 pA = (nA >= 0) ? slidePoint(origA, m.vertices[nA], tA) : origA;
        Vec3 pB = (nB >= 0) ? slidePoint(origB, m.vertices[nB], tB) : origB;

        enum float kSlideEps = 1e-4f;   // mirrors moveVertexTo's stationary-grab guard
        if ((pA - origA).length <= kSlideEps && (pB - origB).length <= kSlideEps) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);
        m.vertices[eA] = pA;
        m.vertices[eB] = pB;
        m.commitChange(MeshEditScope.Position);
        MeshSnapshot after = MeshSnapshot.capture(*m);

        auto cmd = slideEditFactory_();
        cmd.setSnapshots(before, after, "Topology Slide");
        history_.record(cmd);

        // Position-only: no resyncSession() — see this method's own doc
        // comment / plan §Risks.

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // P8 (doc/topopen_p8_smooth_plan.md "The pluggable weight"): true when
    // edge `ei` is OPEN — bordered by AT MOST one face (either a genuine
    // boundary edge, `facesAroundEdge` yielding exactly one, or a bare/
    // floating edge with no incident face at all, e.g. an un-closed P3
    // CASE-EDGE build). Reuses `facesAroundEdge` — the same primitive
    // `seedRail`/`commitAddLoop` already walk — so this classification
    // stays consistent with the rest of this tool, and additionally covers
    // the bare-edge case a `loop.twin`-based test (as `MeshSmooth`'s own
    // `lockBound`/`lockCorner` use) cannot see on a non-face-bounded patch.
    private static bool isOpenEdge(Mesh* m, uint ei) {
        int n = 0;
        foreach (fi; m.facesAroundEdge(ei)) { ++n; if (n > 1) break; }
        return n <= 1;
    }

    // P8: true when vertex `v` is incident to AT LEAST ONE open edge
    // (`isOpenEdge`) — a boundary vertex, per the measured relax rule in
    // `smoothedRelaxTarget` below. `adjOff`/`adjNbrs` are the caller's
    // already-fetched CSR adjacency (avoids re-fetching per vertex).
    private static bool isOpenVertex(Mesh* m, uint v,
                                     const(size_t)[] adjOff, const(uint)[] adjNbrs) {
        foreach (nb; adjNbrs[adjOff[v] .. adjOff[v + 1]])
            if (m.edgeIndex(v, nb) != uint.max && isOpenEdge(m, m.edgeIndex(v, nb)))
                return true;
        return false;
    }

    // PLUGGABLE relax target — the pre-re-snap smoothed position of vertex
    // `v` (P8, doc/topopen_p8_smooth_plan.md "The MEASURED weight"). Reads
    // `v`'s neighbors from `m.vertexAdjacencyCSR` — the EXACT same CSR
    // adjacency the shipped Laplacian smooth averages over
    // (`commands/mesh/smooth.d`) — so this gesture's neighbor SET can never
    // drift from that command's.
    //
    // MEASURED (task 0477 P8 capture, 3 independent boots, 14/16 verts —
    // 87.5%): INVERSE EDGE-LENGTH weighting — NOT a uniform centroid — a
    // closer neighbor pulls harder:
    //   relaxTarget(v) = Σ_i (n_i / len_i) / Σ_i (1 / len_i)
    // where `len_i = |v − n_i|` at the PRE-PASS ("read") positions — every
    // vertex in the pass reads from the SAME `readPos` snapshot, mirroring
    // `MeshSmooth`'s own prev/cur double-buffer (smooth.d:280-297).
    // `kStrength = 1.0` (V1 fixed, full relax) is kept as an explicit blend
    // so a future capture can retune it without touching the weight law.
    //
    // Boundary vertices (measured — the reference's boundary-restriction rule): a vertex on the
    // open boundary (`isOpenVertex`) relaxes using ONLY its open-edge
    // -incident neighbors, not its full 1-ring — a neighbor reached only
    // via a fully-interior (2-face) edge is excluded for such a vertex.
    //
    // RESIDUAL (flagged, NOT modeled — do not guess): the reference applies
    // an additional tangential/shrinkage-correction term this function does
    // not reproduce, so inverse-edge-length is CLOSE to the reference but
    // not bit-exact (see this file's T4-equivalent unittest below, a
    // tolerance-based discriminator, never an exact-value assert).
    //
    // A vertex with zero (usable) neighbors — an isolated point, or
    // (defensively; should not occur — the classifying edge is itself an
    // open-edge neighbor) a boundary vertex with none — returns `readPos[v]`
    // UNCHANGED: a true no-op, bit-identical (no arithmetic performed).
    // `hadNeighbors` reports WHICH case this was so the caller
    // (`applySmoothPasses`) can tell "genuinely relaxed" apart from
    // "passthrough no-op" and skip a 0-neighbor vertex ENTIRELY — no relax,
    // no background re-snap either (review NIT-2: snapping an isolated/
    // loose point onto a background surface is a deliberate NON-goal here,
    // and UNMEASURED against the reference — flagged, not modeled — so a
    // 0-neighbor vertex is left untouched rather than guessed at).
    private static Vec3 smoothedRelaxTarget(Mesh* m, uint v, const(Vec3)[] readPos,
                                            out bool hadNeighbors) {
        const(size_t)[] adjOff;
        const(uint)[]   adjNbrs;
        m.vertexAdjacencyCSR(adjOff, adjNbrs);
        auto nbrs = adjNbrs[adjOff[v] .. adjOff[v + 1]];
        if (nbrs.length == 0) return readPos[v];

        immutable bool boundary = isOpenVertex(m, v, adjOff, adjNbrs);

        Vec3  weightedSum = Vec3(0, 0, 0);
        float weightSum   = 0.0f;
        bool  any         = false;
        foreach (nb; nbrs) {
            if (boundary) {
                uint ei = m.edgeIndex(v, nb);
                if (ei == uint.max || !isOpenEdge(m, ei)) continue;
            }
            float len = (readPos[v] - readPos[nb]).length;
            float w   = 1.0f / ((len > 1e-6f) ? len : 1e-6f);
            weightedSum = weightedSum + readPos[nb] * w;
            weightSum  += w;
            any = true;
        }
        if (!any) return readPos[v];   // defensive; should not occur (see doc comment above)

        hadNeighbors = true;
        Vec3 mean = weightedSum * (1.0f / weightSum);
        enum float kStrength = 1.0f;   // V1 fixed (full relax)
        return readPos[v] + (mean - readPos[v]) * kStrength;
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 2/REV1): commit `passCount`
    // passes of relax+re-snap over the WHOLE primary mesh (V1 scope — no
    // falloff-radius brushing, see plan §Scope). Click supplies
    // `passCount==1`; a drag supplies more (`onMouseButtonUp`'s Smooth
    // branch). Each pass: snapshot the current positions ONCE
    // (`read = m.vertices.dup`), then for every vertex compute
    // `smoothedRelaxTarget` (the measured inverse-edge-length weight) and,
    // when a background source exists, re-snap it onto the NEAREST point
    // of that background via `closestPointOnMeshes` (constraint.d;
    // capture-verified crux — a nearest-FOOT query, NOT a camera-ray one —
    // the same primitive the CONS Point-mode branch already uses).
    // `sources`/`before` are captured ONCE per commit (not per pass):
    // `sources` is a point-in-time snapshot of the live background layers,
    // `before` is the DOWN-time state. Deferring every pass to release
    // (plan "Undo — COALESCE") means the mesh is never mutated before this
    // one call, so `mutationVersion` never moves mid-loop — the CSR
    // adjacency cache (`vertexAdjacencyCSR`, fetched once per vertex per
    // pass inside `smoothedRelaxTarget`) stays warm across the WHOLE
    // N-pass loop; only `closestPointOnMeshes`'s brute-force scan carries
    // the O(V·F_bg) per-pass cost (plan Risk 3). Position-only, zero
    // topology delta — never resizes/rebuilds `faces[]`/`edges[]`/
    // `vertices[]`, so unlike P5/P6 this does NOT call `resyncSession()`
    // (mirrors `commitSlide`'s own reasoning).
    //
    // REV1 FIX-2 (PRIORITY, not hedged/unconditional — opponent obj-2): a
    // Smooth gesture that produces NO net vertex change — 0-neighbor
    // disconnected verts, no background source, or any other combination
    // that nets to identity — restores `before` and records NO undo entry
    // (mirrors `moveVertexTo`/`commitSlide`'s own eps guards). This is
    // ROUTINE, not a rare edge case (a freshly-placed, still-disconnected
    // patch with no bg layer is exactly this), so the guard runs on EVERY
    // commit, never skipped.
    private void applySmoothPasses(int passCount) {
        if (meshSrc_ is null || history_ is null || smoothEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;

        // Two-layer clamp (plan "Passes"): floor at 1 (a click always
        // applies exactly one pass), cap at MAX_TOPOPEN_SMOOTH_PASSES (the
        // runaway backstop, mirroring MeshSmooth's own MAX_SMOOTH_ITER).
        if (passCount < 1) passCount = 1;
        if (passCount > MAX_TOPOPEN_SMOOTH_PASSES) passCount = MAX_TOPOPEN_SMOOTH_PASSES;

        auto sources = backgroundSourcesSnapshot();   // point-in-time, fetched ONCE per commit
        MeshSnapshot before = MeshSnapshot.capture(*m);

        immutable size_t nV = m.vertices.length;
        foreach (pass; 0 .. passCount) {
            Vec3[] read = m.vertices.dup;   // this pass's neighbor-read snapshot
            foreach (vi; 0 .. nV) {
                bool hadNeighbors;
                Vec3 relaxed = smoothedRelaxTarget(m, cast(uint)vi, read, hadNeighbors);
                // NIT-2: a vertex with no relaxation neighbors is a loose
                // (0-neighbor) point — skip it ENTIRELY, including the
                // background re-snap below, so it is a TRUE no-op rather
                // than getting silently pulled onto the background surface
                // (see this function's own doc comment above — this is
                // what keeps `smoothedRelaxTarget`'s no-op premise true).
                if (!hadNeighbors) continue;
                if (sources.length) {
                    Vec3  hit, hitN;
                    int   si, fi;
                    float d2;
                    enum bool dblSided = false;   // V1 default — matches CONS Point-mode's own default
                    if (closestPointOnMeshes(relaxed, sources, dblSided, hit, hitN, si, fi, d2))
                        relaxed = hit;
                }
                m.vertices[vi] = relaxed;
            }
        }

        // REV1 FIX-2: unconditional no-op check — a gesture that nets to
        // ZERO vertex movement (within eps) restores `before` exactly and
        // records no undo entry at all.
        enum float kSmoothEps = 1e-4f;   // mirrors moveVertexTo's/commitSlide's own eps guards
        bool changed = false;
        foreach (i; 0 .. nV)
            if ((m.vertices[i] - before.vertices[i]).length > kSmoothEps) { changed = true; break; }
        if (!changed) { before.restore(*m); return; }   // no mutation worth recording — no GPU churn

        // NIT-1: fire the change-bus Position commit only on the CHANGED
        // path — committing unconditionally (the old placement, above the
        // no-op check) recomputed every position-keyed cache to identical
        // values on the routine no-op gesture the guard above just caught.
        m.commitChange(MeshEditScope.Position);

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = smoothEditFactory_();
        cmd.setSnapshots(before, after, "Topology Smooth");
        history_.record(cmd);

        // Position-only: no resyncSession() — see this method's own doc
        // comment / plan §Undo.

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
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

    // P9 (doc/topopen_p9_split_plan.md Phase 2): commit the armed Split
    // gesture — FULL KERNEL REUSE, zero kernel change. Mirrors `removeFaceAt`
    // above exactly: resolve the shared face (`findCommonSplitFace` — every
    // no-op condition, incl. C==-1/the deferred mid-edge case, C==A, and
    // cross-polygon/adjacent A-C, funnels through its -1 return with NO
    // snapshot and NO undo entry), bracket the ONE kernel call in a single
    // before/after `MeshSnapshot` pair, record through the DEDICATED
    // `splitEditFactory_` (never `removeEditFactory_`/`addLoopEditFactory_`,
    // which would bake the wrong wire name onto a split).
    //
    // KILLER-2 (sibling index dangle): `splitFaceByVertices` ->
    // `rebuildFacesWithChordSplits` calls `rebuildEdges()`+`buildLoops()`, so
    // `faces[]`/`edges[]` are wholesale-rebuilt (Δf=+1/Δe=+1) — any OTHER
    // gesture armed on a different button holding a face/edge index would
    // dangle. `resyncSession()` is called on SUCCESS, in the SAME position
    // `removeFaceAt`/`commitAddLoop` call it, for the identical reason (the
    // tool never overrides `isDragging()`, so a plain-MMB Split CAN fire
    // mid-build/mid-move/mid-slide on a different button). Vertices are NOT
    // compacted here — no orphans are created by a split — so a concurrently
    // armed gesture's VERTEX index stays valid regardless; `resyncSession()`
    // is still the uniform, cheap-to-call safety net every sibling commit
    // uses.
    private void commitSplit(int a, int c) {
        if (meshSrc_ is null || history_ is null || splitEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;

        int fi = findCommonSplitFace(m, a, c);
        if (fi < 0) return;   // every no-op condition (C==-1, C==A, no shared
                               // face, adjacent A/C) funnels here — no mutation

        MeshSnapshot before = MeshSnapshot.capture(*m);

        size_t n = m.splitFaceByVertices(cast(uint)fi, cast(uint)a, cast(uint)c);
        if (n == 0) return;   // defensive; `before` discarded, mesh unmutated

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = splitEditFactory_();
        cmd.setSnapshots(before, after, "Topology Split");
        history_.record(cmd);

        // KILLER-2: invalidate any OTHER armed gesture's cached face/edge
        // indices now that faces[]/edges[] have been rebuilt.
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
    // could otherwise commit against a dangling seed edge index. P7
    // (doc/topopen_p7_slide_plan.md Phase 3 item 3): also clears the Slide
    // arm, same rationale. REV1 FIX-1: the actual clearing logic now lives
    // in `resetAllGestureArms()` — the single source of truth ALSO called
    // at the top of every LEFT-button gesture-DOWN handler — so this method
    // is just that helper's "external history navigation" entry point.
    override void resyncSession() {
        resetAllGestureArms();
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

        // P7 (doc/topopen_p7_slide_plan.md Phase 4): the Slide ghost is
        // likewise independent of `lastHit_`/CONS (Slide never touches the
        // background constraint — pure current-layer edge-line constrained
        // move), so it too is drawn BEFORE the `lastHit_.hit` early-return,
        // mirroring the Add Loop ghost above. Purely re-reads already-armed
        // state (`slideEndA_`/`slideEndB_`/`slideNbrA_`/`slideNbrB_`/
        // `slideTA_`/`slideTB_`) — no mesh mutation, no raycast. A
        // held-fixed endpoint (`slideNbrA_`/`slideNbrB_ < 0`) draws at its
        // CURRENT (unmoved) position, same as `commitSlide` would leave it.
        if (slideArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null
             && slideEndA_ >= 0 && slideEndA_ < cast(int)m.vertices.length
             && slideEndB_ >= 0 && slideEndB_ < cast(int)m.vertices.length) {
                enum uint slideCol     = IM_COL32(120, 200, 255, 220);   // slide cyan-blue
                enum uint slideRailCol = IM_COL32(120, 200, 255, 90);    // faint rail

                Vec3 pA = (slideNbrA_ >= 0 && slideNbrA_ < cast(int)m.vertices.length)
                    ? slidePoint(m.vertices[slideEndA_], m.vertices[slideNbrA_], slideTA_)
                    : m.vertices[slideEndA_];
                Vec3 pB = (slideNbrB_ >= 0 && slideNbrB_ < cast(int)m.vertices.length)
                    ? slidePoint(m.vertices[slideEndB_], m.vertices[slideNbrB_], slideTB_)
                    : m.vertices[slideEndB_];

                ImVec2 pa, pb;
                if (projectPt(pA, vp, pa) && projectPt(pB, vp, pb)) {
                    dl.AddLine(pa, pb, slideCol, 2.5f);
                    dl.AddCircleFilled(pa, 4.0f, slideCol, 16);
                    dl.AddCircleFilled(pb, 4.0f, slideCol, 16);
                }

                void faintRail(int end, int nbr) {
                    if (nbr < 0 || nbr >= cast(int)m.vertices.length) return;
                    ImVec2 ra, rb;
                    if (projectPt(m.vertices[end], vp, ra) && projectPt(m.vertices[nbr], vp, rb))
                        dl.AddLine(ra, rb, slideRailCol, 1.0f);
                }
                faintRail(slideEndA_, slideNbrA_);
                faintRail(slideEndB_, slideNbrB_);
            }
        }

        // P8 (doc/topopen_p8_smooth_plan.md Phase 4): a cheap "Smooth
        // armed" affordance — a colored ring at the CURSOR'S OWN screen
        // position while `smoothArmed_`. Unlike the P1 hover marker below
        // (which needs a CONS hit against a background layer) or the Add
        // Loop/Slide ghosts above (which key off an armed seed edge's
        // WORLD position), Smooth has neither a source pick nor a
        // background dependency — it relaxes the WHOLE primary mesh, so
        // tying its affordance to `lastHit_.point` would make it invisible
        // in exactly the bg-less scene this preview must still cover.
        // Drawn in pure screen space (no projectPt/raycast, no mesh
        // access), so it is unconditionally visible and unconditionally
        // cheap; placed BEFORE the `lastHit_.hit` early-return immediately
        // below, mirroring the Add Loop/Slide ghosts' positioning in this
        // function. No per-pass relaxation preview (deferred/expensive —
        // consistent with the deferred-commit divergence, plan §Undo).
        if (smoothArmed_) {
            enum uint smoothCol = IM_COL32(120, 255, 200, 220);   // smoothing green-blue
            ImVec2 cur = ImVec2(cast(float)smoothLastX_, cast(float)smoothLastY_);
            dl.AddCircle(cur, 14.0f, smoothCol, 24, 2.5f);
            dl.AddCircleFilled(cur, 4.0f, smoothCol, 16);
        }

        // P9 (doc/topopen_p9_split_plan.md Phase 4): the Split ghost is
        // likewise independent of `lastHit_`/CONS (Split never touches the
        // background constraint — pure current-layer topology op), so it too
        // is drawn BEFORE the `lastHit_.hit` early-return, mirroring the Add
        // Loop/Slide ghosts above. A line from the armed source A to the
        // current snap target C (drawn only once C resolves to a real
        // vertex — the deferred mid-edge case has no line to preview),
        // plus a small filled circle at C as the snap affordance. Purely
        // re-reads already-armed state (`splitSourceVert_`/
        // `splitTargetVert_`) — no mesh mutation, no raycast.
        if (splitArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && splitSourceVert_ >= 0 && splitSourceVert_ < cast(int)m.vertices.length) {
                enum uint splitCol = IM_COL32(80, 200, 230, 220);   // split cyan
                ImVec2 aPt;
                if (projectPt(m.vertices[splitSourceVert_], vp, aPt)
                 && splitTargetVert_ >= 0 && splitTargetVert_ < cast(int)m.vertices.length) {
                    ImVec2 cPt;
                    if (projectPt(m.vertices[splitTargetVert_], vp, cPt)) {
                        dl.AddLine(aPt, cPt, splitCol, 2.0f);
                        dl.AddCircleFilled(cPt, 5.0f, splitCol, 16);
                    }
                }
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

        // P7 (doc/topopen_p7_slide_plan.md Phase 4): the armed Slide
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and tracked per-endpoint fractions without driving a full release.
        root["slideArmed"] = JSONValue(slideArmed_);
        root["slideSeed"]  = JSONValue(slideSeed_);
        root["slideTA"]    = JSONValue(cast(double)slideTA_);
        root["slideTB"]    = JSONValue(cast(double)slideTB_);

        // P8 (doc/topopen_p8_smooth_plan.md Phase 4): the armed Smooth
        // gesture's state, for Tier-C tests to assert click-vs-drag pass
        // counts without driving a full release. `smoothPassCount` reports
        // the SAME `1 + floor(smoothDragPx_ / kSmoothPassStridePx)`,
        // clamped to `MAX_TOPOPEN_SMOOTH_PASSES` exactly like
        // `applySmoothPasses`'s own clamp, that `onMouseButtonUp`'s Smooth
        // branch will apply if released now (NIT-3: reporting the
        // unclamped value here would make that "will apply" doc-comment
        // false for an extreme drag).
        root["smoothArmed"]     = JSONValue(smoothArmed_);
        int smoothPassCount = 1 + cast(int)(smoothDragPx_ / kSmoothPassStridePx);
        if (smoothPassCount > MAX_TOPOPEN_SMOOTH_PASSES) smoothPassCount = MAX_TOPOPEN_SMOOTH_PASSES;
        root["smoothPassCount"] = JSONValue(smoothPassCount);

        // P9 (doc/topopen_p9_split_plan.md Phase 4): the armed Split
        // gesture's state, for Tier-C tests to assert the picked source
        // vertex and tracked snap target without driving a full release.
        root["splitArmed"]      = JSONValue(splitArmed_);
        root["splitSourceVert"] = JSONValue(splitSourceVert_);
        root["splitTargetVert"] = JSONValue(splitTargetVert_);

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

// ---------------------------------------------------------------------------
// resolveGestureSlot — Ctrl+LMB dispatch guard (P7, doc/topopen_p7_slide_plan.md
// "Testing Strategy", Tier-A): the same pure, camera-free regression guard
// shape as the P5/P6 dispatch pins above — a bad merge that silently
// reverted the `CtrlLmb` dispatch case would be caught by `dub test`, not
// just by best-effort Tier-C.
// ---------------------------------------------------------------------------
unittest {
    assert(resolveGestureSlot(SDL_BUTTON_LEFT, KMOD_CTRL) == GestureSlot.CtrlLmb,
        "Ctrl+LMB must resolve to the Slide gesture slot");
}

// ---------------------------------------------------------------------------
// continuationNeighbor — T6 (P7, doc/topopen_p7_slide_plan.md §Testing):
// pure adjacency-counting tests, independent of `commitSlide`/the down
// -handler. Valence-2 (one remaining edge) -> the unique neighbor;
// valence-1 (grabbed-edge-only) -> -1; valence-3 (two remaining edges,
// regardless of whether they happen to be colinear — `continuationNeighbor`
// only COUNTS, it never inspects direction) -> -1, the deferred/held-fixed
// case (plan §Follow-up capture — never guessed).
// ---------------------------------------------------------------------------
unittest {
    // Chain D-A-B: A's remaining neighbor (excluding B) is D.
    {
        Mesh m;
        uint d = m.addVertex(Vec3(-2, 0, 0));
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(d, a);
        m.addEdge(a, b);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d,
            "valence-2 endpoint must report its unique remaining neighbor");
    }
    // Bare edge A-B only: A has NO remaining edge once B is excluded.
    {
        Mesh m;
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(a, b);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1,
            "valence-1 (grabbed-edge-only) endpoint must report -1 (held fixed)");
    }
    // A connects to B (grabbed), plus TWO others (E, F): 2 remaining edges.
    {
        Mesh m;
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        uint e = m.addVertex(Vec3(0, 2, 0));
        uint f = m.addVertex(Vec3(0, 0, 2));
        m.addEdge(a, b);
        m.addEdge(a, e);
        m.addEdge(a, f);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1,
            "valence>2 (2+ remaining edges) endpoint must report -1 (deferred, held fixed — "
          ~ "never guessed among ambiguous candidates)");
    }
}

// ---------------------------------------------------------------------------
// commitSlide — T1 (P7, doc/topopen_p7_slide_plan.md §Testing, "colinear @
// fraction (two-sided)"): a rig where the grabbed edge A-B has A also on
// edge A-D and B also on edge B-E (both valence-2, DIFFERENT rail
// directions) — each endpoint must land at its OWN independently-computed
// clamped-lerp position along ITS OWN incident edge, regardless of the
// other endpoint's rail. Driven directly (private, same-module access);
// `gpu_` stays null so the guarded display tail never runs under bare
// `dub test`, mirroring every other Tier-B unittest in this file.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;

    Vec3 a0 = Vec3(0, 0, 0),  d0 = Vec3(-2, 0, 0);
    Vec3 b0 = Vec3(2, 0, 0),  e0 = Vec3(5, 3, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    uint e = m.addVertex(e0);
    m.addEdge(a, d);
    m.addEdge(a, b);
    m.addEdge(b, e);
    uint seed = m.edgeIndex(a, b);
    assert(seed != uint.max, "setup: the grabbed edge A-B must exist");

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d);
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == cast(int)e);

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, cast(int)e, 0.4f, 0.7f);

    Vec3 expectedA = a0 + (d0 - a0) * 0.4f;
    Vec3 expectedB = b0 + (e0 - b0) * 0.7f;
    assert((m.vertices[a] - expectedA).length < 1e-5f,
        "A must slide EXACTLY 0.4 of the way toward D along A's own incident edge");
    assert((m.vertices[b] - expectedB).length < 1e-5f,
        "B must slide EXACTLY 0.7 of the way toward E along B's own incident edge, "
      ~ "independent of A's own rail/fraction");
    assert(history.canUndo(), "a real slide must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSlide — T2 (P7, doc/topopen_p7_slide_plan.md §Testing,
// "clamp-at-neighbor"): an overshoot fraction (t > 1, already clamped to 1.0
// by `slidePoint`) must land the endpoint EXACTLY at the neighbor's
// pre-slide position — the captured overshoot clamp (plan §1/§3).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;

    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-3, 1, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 5.0f, 0.0f);

    assert((m.vertices[a] - d0).length < 1e-5f,
        "an overshoot fraction must clamp EXACTLY to the neighbor's pre-slide position");
}

// ---------------------------------------------------------------------------
// commitSlide — T3 (P7, doc/topopen_p7_slide_plan.md §Testing, "topology
// delta = 0"): a real slide must never change vertex/edge/face COUNTS —
// position-only, zero topology mutation.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 0.5f, 0.0f);

    assert(m.vertices.length == vBefore, "Slide must never add/remove vertices");
    assert(m.edges.length == eBefore, "Slide must never add/remove edges");
    assert(m.faces.length == fBefore, "Slide must never add/remove faces");
}

// ---------------------------------------------------------------------------
// commitSlide — T4 (P7, doc/topopen_p7_slide_plan.md §Testing,
// "slide-then-undo"): a real slide must undo back to the exact pre-slide
// state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    auto before = MeshSnapshot.capture(m);
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 0.5f, 0.0f);
    assert(history.canUndo(), "a real slide must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-slide state");
}

// ---------------------------------------------------------------------------
// commitSlide — T5a (P7, doc/topopen_p7_slide_plan.md §Testing, "held-fixed
// endpoint"): B is valence-1 (only the grabbed edge A-B) -> nB=-1 -> B must
// stay UNTOUCHED while A (valence-2, via A-D) slides normally.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-2, 0, 0), b0 = Vec3(2, 0, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    m.addEdge(a, d);
    m.addEdge(a, b);   // B's ONLY edge -> valence-1 once A-B itself is grabbed
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1,
        "setup: B must have no remaining incident edge once A-B is excluded");

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 0.5f, 0.5f);

    Vec3 expectedA = a0 + (d0 - a0) * 0.5f;
    assert((m.vertices[a] - expectedA).length < 1e-5f, "A (slidable) must slide normally");
    assert((m.vertices[b] - b0).length < 1e-6f,
        "B (valence-1, held fixed) must NOT move, regardless of the tB argument");
}

// ---------------------------------------------------------------------------
// commitSlide — T5b MIXED VALENCE (P7, doc/topopen_p7_slide_plan.md
// §Testing "held-fixed endpoint" + the mixed-valence requirement): B has
// TWO remaining incident edges after excluding the grabbed edge A-B
// (valence-3 overall) -> nB=-1 -> HELD FIXED, while A (valence-2) slides
// normally in the SAME gesture. Distinct from T5a (which uses a valence-1
// B) — this is the genuinely ambiguous ≥2-remaining case the plan's V1
// scope defers rather than guesses (plan §Follow-up capture).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-2, 0, 0), b0 = Vec3(2, 0, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    uint g = m.addVertex(Vec3(2, 2, 0));   // B's 2nd extra neighbor
    uint h = m.addVertex(Vec3(2, 0, 2));   // B's 3rd extra neighbor
    m.addEdge(a, d);
    m.addEdge(a, b);   // the edge to be grabbed
    m.addEdge(b, g);
    m.addEdge(b, h);   // B now has 3 total incident edges (valence-3)
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d,
        "setup: A must remain the unambiguous valence-2 endpoint");
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1,
        "setup: B must have 2 remaining incident edges (valence>2) -> deferred/held-fixed");

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 0.6f, 0.9f);

    Vec3 expectedA = a0 + (d0 - a0) * 0.6f;
    assert((m.vertices[a] - expectedA).length < 1e-5f,
        "the valence-2 endpoint (A) must slide normally");
    assert((m.vertices[b] - b0).length < 1e-6f,
        "the valence>2 endpoint (B) must be HELD FIXED — never guessed among its "
      ~ "2 remaining incident edges");
    assert(history.canUndo(), "a mixed-valence slide (one endpoint moves) must still be undoable");
}

// ---------------------------------------------------------------------------
// commitSlide — T5c (P7, doc/topopen_p7_slide_plan.md §Testing): BOTH
// endpoints held fixed (an isolated grabbed edge, neither end has any other
// incident edge) must be a byte-identical no-op — no mutation, no undo
// entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, b);   // isolated bare edge -> both endpoints valence-1
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1);
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1);

    auto before = MeshSnapshot.capture(m);
    t.commitSlide(seed, cast(int)a, cast(int)b, -1, -1, 0.5f, 0.5f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices, "both-fixed slide must not move any vertex");
    assert(!history.canUndo(), "both-fixed slide must record NO undo entry");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — MIN-DRAG (P7 REV1 FIX-2, doc/topopen_p7_slide_plan.md):
// a Ctrl+LMB release within `kMinDragPx` of the press pixel is a clean
// no-op — no vertex write, no undo entry — driven through the REAL
// `onMouseButtonUp` path (arming state set up directly, mirroring
// `onCtrlLmbDown`'s post-classification result, rather than driving a full
// screen-space press) so the min-drag GATE ITSELF is under test, not just
// `commitSlide`'s own (also-present) eps guard. `gpu_` stays null and the
// release event carries no `SubjectPacket`, so this never reaches
// `refreshDisplay` — safe under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import operator : VectorStack;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    // Arm directly — mirrors `onCtrlLmbDown`'s post-classification state —
    // rather than driving the full down-handler (which needs a live
    // screen-space `findRingSeedEdge` pick); this test targets the
    // RELEASE-side min-drag gate specifically.
    t.slideSeed_   = cast(int)seed;
    t.slideArmed_  = true;
    t.slideStartX_ = 50;
    t.slideStartY_ = 50;
    t.slideEndA_   = cast(int)a;
    t.slideEndB_   = cast(int)b;
    t.slideNbrA_   = cast(int)d;
    t.slideNbrB_   = -1;
    t.slideTA_     = 0.5f;
    t.slideTB_     = 0.0f;

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_LEFT;
    e.x = 51;
    e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.onMouseButtonUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.slideArmed_, "release must disarm Slide regardless of the min-drag gate");
    assert(after.vertices == before.vertices, "click-without-drag must not move any vertex");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// smoothedRelaxTarget — T4 (P8, doc/topopen_p8_smooth_plan.md "Testing
// Strategy"): on an IRREGULAR 1-ring (one very distant neighbor, two close
// ones — a "hub" of 3 BARE edges, so every incident edge is open and the
// boundary-filtering branch keeps the full ring, isolating the weight-law
// question from the boundary-restriction one), the relaxed result must be
// CLOSER to the MEASURED inverse-edge-length-weighted target than to the
// uniform (plain) mean — mirroring the capture's own discriminator. This is
// primarily a TOLERANCE-based assertion (not a bit-exact one against the
// reference — this file's own doc comment on `smoothedRelaxTarget` flags an
// unmodeled tangential/shrinkage-correction residual there); the SECOND
// assertion below (distToWeighted near-zero) IS an exact check, but only
// against this function's OWN documented formula, independently
// re-derived here — never a second call into the implementation under
// test.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;

    Mesh m;
    uint v  = m.addVertex(Vec3(0, 0, 0));
    uint n1 = m.addVertex(Vec3(1, 0, 0));    // close  (len 1)
    uint n2 = m.addVertex(Vec3(0, 10, 0));   // far    (len 10)
    uint n3 = m.addVertex(Vec3(0, 0, 1));    // close  (len 1)
    m.addEdge(v, n1);
    m.addEdge(v, n2);
    m.addEdge(v, n3);
    m.buildLoops();

    Vec3[] readPos = m.vertices.dup;
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.smoothedRelaxTarget(&m, v, readPos, hadNeighbors);
    assert(hadNeighbors, "a hub of 3 bare edges must report usable relax neighbors");

    // Independently-computed candidates — never re-deriving the tool's own
    // implementation by calling back into it.
    Vec3 uniformMean = (readPos[n1] + readPos[n2] + readPos[n3]) * (1.0f / 3.0f);
    float w1 = 1.0f / (readPos[v] - readPos[n1]).length;
    float w2 = 1.0f / (readPos[v] - readPos[n2]).length;
    float w3 = 1.0f / (readPos[v] - readPos[n3]).length;
    Vec3 weightedMean = (readPos[n1] * w1 + readPos[n2] * w2 + readPos[n3] * w3)
                       * (1.0f / (w1 + w2 + w3));

    float distToWeighted = (actual - weightedMean).length;
    float distToUniform  = (actual - uniformMean).length;

    assert(distToWeighted < distToUniform,
        format("relax target must be CLOSER to the inverse-edge-length-weighted mean "
             ~ "than to the uniform mean; distToWeighted=%f distToUniform=%f",
               distToWeighted, distToUniform));
    assert(distToWeighted < 1e-4f,
        "the implementation must match the documented inverse-edge-length formula exactly "
      ~ "pre-re-snap (the flagged residual is a divergence from the REFERENCE, not from "
      ~ "this function's own stated law)");
}

// ---------------------------------------------------------------------------
// applySmoothPasses — T7 (P8 REV1 FIX-2, doc/topopen_p8_smooth_plan.md): a
// Smooth gesture over a fully DISCONNECTED patch (every vertex has 0
// neighbors) with NO background source is the ROUTINE no-op case — the
// mesh must be byte-identical and record NO undo entry, mirroring
// `commitSlide`'s own T5c both-fixed no-op test. `gpu_` stays null and this
// path returns before ever reaching `refreshDisplay` — safe under bare
// `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    // Defensive (test-isolation, not a production call site): `snap.d`'s
    // background-source list is a module-level `__gshared` — explicitly
    // clear it rather than assume no earlier `dub test` unittest left it
    // populated, so this test's "no background source" premise holds
    // regardless of run order.
    setBackgroundSnapSources(null);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(5, 0, 0));
    m.addVertex(Vec3(0, 5, 0));   // 3 isolated points -> 0 neighbors each, no background layer

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "a disconnected patch with no background source must be a byte-identical no-op");
    assert(!history.canUndo(),
        "a disconnected/no-bg Smooth gesture must record NO undo entry");
}

// ---------------------------------------------------------------------------
// applySmoothPasses — isolated (0-neighbor) vertex WITH a background present
// (review NIT-2): T7 above only covers "no background source at all". This
// covers the previously-untested combination — a loose point plus a LIVE
// background layer — which used to fall through to the `sources.length`
// re-snap branch and get pulled onto the background surface even though it
// has zero relaxation neighbors, contradicting the FIX-2 "0-neighbor = true
// no-op" premise (and this behavior was never measured against the
// reference — a deliberate NON-goal, not a modeled law). The fix skips a
// 0-neighbor vertex entirely, so it stays byte-unchanged regardless of
// whether a background exists; since it is the ONLY vertex here, the whole
// gesture nets to no-op and records no undo entry either. `gpu_` stays
// null and this path returns before ever reaching `refreshDisplay` — safe
// under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    auto bg = new Mesh();
    bg.vertices = [Vec3(-10, -10, -5), Vec3(10, -10, -5), Vec3(10, 10, -5), Vec3(-10, 10, -5)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));   // single isolated point -> 0 neighbors, background IS present

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "an isolated (0-neighbor) vertex must stay byte-unchanged even WITH a background "
      ~ "present — loose points are never snapped to a surface");
    assert(!history.canUndo(),
        "the only vertex in the gesture is untouched -> no undo entry, even with a background");
}

// ---------------------------------------------------------------------------
// smoothedRelaxTarget — boundary-restriction coverage (review NIT-4): no
// existing P8 test exercises the branch that EXCLUDES a boundary vertex's
// interior (2-face-shared) edge neighbors from its relax average — T4 above
// is an all-bare-edge hub (every incident edge is open, so the exclusion
// never actually removes anyone) and the click/build tests use a single
// triangle (no interior edge exists at all to exclude). This rig gives
// boundary vertex `v0` BOTH kinds of neighbor at once: `v1`/`v3` via open
// (single-face) edges, `v2` via the edge shared by both triangles — so a
// regression that dropped the exclusion (falling back to the full 1-ring)
// would still pass every other P8 test but fail this one.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;

    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));    // open-edge neighbor  (v0-v1: face0 only)
    uint v2 = m.addVertex(Vec3(10, 10, 0));  // INTERIOR neighbor   (v0-v2: shared by both faces)
    uint v3 = m.addVertex(Vec3(0, 1, 0));    // open-edge neighbor  (v0-v3: face1 only)
    m.addFace([v0, v1, v2]);
    m.addFace([v0, v2, v3]);
    m.buildLoops();

    // Rig sanity: v0-v2 must actually be the shared (interior) edge, and v0
    // must actually classify as a boundary vertex, or this rig isn't
    // testing what it claims to.
    uint eV0V2 = m.edgeIndex(v0, v2);
    assert(eV0V2 != uint.max, "setup: v0-v2 must exist as an edge");
    assert(!TopologyPenTool.isOpenEdge(&m, eV0V2),
        "setup: v0-v2 must be INTERIOR (shared by both faces) for this rig to test anything");
    const(size_t)[] adjOff;
    const(uint)[]   adjNbrs;
    m.vertexAdjacencyCSR(adjOff, adjNbrs);
    assert(TopologyPenTool.isOpenVertex(&m, v0, adjOff, adjNbrs),
        "setup: v0 must classify as a boundary vertex (has open edges v0-v1/v0-v3)");

    Vec3[] readPos = m.vertices.dup;
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.smoothedRelaxTarget(&m, v0, readPos, hadNeighbors);
    assert(hadNeighbors, "v0 has usable (open-edge) relax neighbors");

    // Independently-computed expected target using ONLY the open-edge
    // neighbors v1/v3 — never re-deriving the implementation under test.
    float w1 = 1.0f / (readPos[v0] - readPos[v1]).length;
    float w3 = 1.0f / (readPos[v0] - readPos[v3]).length;
    Vec3 openOnlyTarget = (readPos[v1] * w1 + readPos[v3] * w3) * (1.0f / (w1 + w3));

    // The target that WOULD result if the exclusion regressed away and the
    // interior neighbor v2 leaked into the average.
    float w2 = 1.0f / (readPos[v0] - readPos[v2]).length;
    Vec3 fullRingTarget = (readPos[v1] * w1 + readPos[v2] * w2 + readPos[v3] * w3)
                         * (1.0f / (w1 + w2 + w3));

    float distToOpenOnly = (actual - openOnlyTarget).length;
    float distToFullRing = (actual - fullRingTarget).length;
    assert(distToOpenOnly < 1e-4f,
        format("boundary relax must use ONLY the open-edge neighbors (v1,v3), excluding the "
             ~ "interior neighbor v2; distToOpenOnly=%f", distToOpenOnly));
    assert(distToFullRing > 0.05f,
        format("this rig must actually discriminate the exclusion — the full-ring (regressed) "
             ~ "target must be MEASURABLY different from the open-edge-only one; "
             ~ "distToFullRing=%f", distToFullRing));
}

// ---------------------------------------------------------------------------
// resolveGestureSlot — plain-MMB dispatch guard (P9,
// doc/topopen_p9_split_plan.md), the same Tier-A pin shape as the P5/P6
// guards above: a pure, camera-free regression guard so a bad merge that
// silently reverted the `Mmb` (plain, no modifier) dispatch case — or
// collapsed it into the Ctrl/Shift MMB slots — would be caught by
// `dub test`, not just by best-effort Tier-C. Also pins that Ctrl/Shift+MMB
// still resolve to their OWN slots, never Split's.
// ---------------------------------------------------------------------------
unittest {
    assert(resolveGestureSlot(SDL_BUTTON_MIDDLE, cast(SDL_Keymod)0) == GestureSlot.Mmb,
        "plain MMB (no modifier) must resolve to the Split gesture slot");
    assert(resolveGestureSlot(SDL_BUTTON_MIDDLE, KMOD_CTRL) == GestureSlot.CtrlMmb,
        "Ctrl+MMB must still resolve to Remove, not Split");
    assert(resolveGestureSlot(SDL_BUTTON_MIDDLE, KMOD_SHIFT) == GestureSlot.ShiftMmb,
        "Shift+MMB must still resolve to Add Loop, not Split");
}

// ---------------------------------------------------------------------------
// commitSplit — T1 (P9, doc/topopen_p9_split_plan.md §Testing): QUAD
// diagonal split (v0->v2). Independent expected — cross-checked against
// `mesh.d`'s own `splitFaceByVertices` unittest (`mesh.d:27551-27563`), but
// re-derived here rather than re-asserted, since `commitSplit` is the thing
// under test (the snapshot/undo bracket + factory wiring around the kernel
// call, not the kernel itself).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    t.commitSplit(0, 2);

    assert(m.faces.length == 2, "commitSplit: expected 2 faces after a quad diagonal split");
    assert(m.edges.length == 5, "commitSplit: expected 5 edges (4 boundary + 1 chord)");
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u, 1u, 2u]) hasF1 = true;
        if (f[] == [2u, 3u, 0u]) hasF2 = true;
    }
    assert(hasF1, "commitSplit: expected face [0,1,2]");
    assert(hasF2, "commitSplit: expected face [2,3,0]");
    assert(m.vertices.length == 4, "commitSplit: split is Δv=0 — no vertex is added");
    assert(history.canUndo(), "a real split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T2 (P9, doc/topopen_p9_split_plan.md §Testing): HEXAGON
// non-adjacent split (v0->v3), proving the split isn't quad-only.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3( 2.0f,  0.0f,    0));   // 0
    m.addVertex(Vec3( 1.0f,  1.732f,  0));   // 1
    m.addVertex(Vec3(-1.0f,  1.732f,  0));   // 2
    m.addVertex(Vec3(-2.0f,  0.0f,    0));   // 3
    m.addVertex(Vec3(-1.0f, -1.732f,  0));   // 4
    m.addVertex(Vec3( 1.0f, -1.732f,  0));   // 5
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    assert(m.vertices.length == 6 && m.edges.length == 6 && m.faces.length == 1,
        "setup: pre-state must be the hand-enumerated hexagon (6v/6e/1f)");

    t.commitSplit(0, 3);

    assert(m.faces.length == 2, "commitSplit: expected 2 faces after a hexagon non-adjacent split");
    assert(m.edges.length == 7, "commitSplit: expected 7 edges (6 boundary + 1 chord)");
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u, 1u, 2u, 3u]) hasF1 = true;
        if (f[] == [3u, 4u, 5u, 0u]) hasF2 = true;
    }
    assert(hasF1, "commitSplit: expected face [0,1,2,3]");
    assert(hasF2, "commitSplit: expected face [3,4,5,0]");
    assert(m.vertices.length == 6, "commitSplit: split is Δv=0 — no vertex is added");
    assert(history.canUndo(), "a real split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T3 (P9, doc/topopen_p9_split_plan.md §Testing): adjacent A/C
// (chord would duplicate an existing edge) must be a byte-identical no-op —
// no mutation, no undo entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 1);   // adjacent (standard, not wrap)
    t.commitSplit(3, 0);   // adjacent (wrap-around)
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "adjacent A/C must not mutate the mesh");
    assert(!history.canUndo(), "adjacent A/C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T4 (P9, doc/topopen_p9_split_plan.md §Testing): A==C must be
// a byte-identical no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 0);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "A==C must not mutate the mesh");
    assert(!history.canUndo(), "A==C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T5 (P9, doc/topopen_p9_split_plan.md §Testing, V1-SCOPE
// LINE): a release that does not land on a vertex (C == -1, the deferred
// mid-edge-insert case) must be a byte-identical no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, -1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "release-not-on-vertex must not mutate the mesh");
    assert(!history.canUndo(), "release-not-on-vertex must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T6 (P9, doc/topopen_p9_split_plan.md §Testing): A and C on
// two DISJOINT faces (no shared polygon at all) must be a byte-identical
// no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));   // 0 (F0)
    m.addVertex(Vec3(1, 0, 0));   // 1 (F0)
    m.addVertex(Vec3(1, 1, 0));   // 2 (F0)
    m.addVertex(Vec3(0, 1, 0));   // 3 (F0)
    m.addVertex(Vec3(5, 0, 0));   // 4 (F1)
    m.addVertex(Vec3(6, 0, 0));   // 5 (F1)
    m.addVertex(Vec3(6, 1, 0));   // 6 (F1)
    m.addVertex(Vec3(5, 1, 0));   // 7 (F1)
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 4);   // v0 in F0, v4 in F1 -> no common face
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "cross-polygon A/C must not mutate the mesh");
    assert(!history.canUndo(), "cross-polygon A/C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// findCommonSplitFace / commitSplit — T7 (P9 REV1 FIX-3, MODERATE): two
// faces share A(0) and C(1) — a TRIANGLE where A-C is a real WRAP-AROUND
// edge (A at the LAST winding position, C at the FIRST — the exact case an
// UNSORTED `i=posA,j=posC` adjacency check evades: `j==i+1` is false
// (0 != 2+1) and `i==0&&j==len-1` is false (i=2 != 0), so an unfixed version
// would wrongly treat this face as non-adjacent) and a PENTAGON where A and
// C are genuinely non-adjacent (splittable). The two faces are wired to
// share edge A-D so `facesAroundVertex(A)` walks BOTH via the dart fan (a
// setup sanity check below pins that this rig actually exercises the
// tie-break, rather than one face being unreachable). The FIXED
// (sorted-lo/hi) implementation must SKIP the triangle and split the
// pentagon; the buggy unsorted version would return the triangle first,
// the kernel would then correctly reject it (real edge) and return 0, and
// `commitSplit` would silently no-op — losing the legitimate pentagon split
// this test pins.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    // A=0, C=1, D=2, E=3, F=4
    foreach (i; 0 .. 5) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([1u, 2u, 0u]);          // face0: triangle [C,D,A] -> A@pos2(len-1), C@pos0 (wrap-adjacent)
    m.addFace([0u, 2u, 3u, 1u, 4u]);  // face1: pentagon [A,D,E,C,F] -> A@pos0, C@pos3 (non-adjacent)
                                       // shares edge A-D with face0, so both
                                       // faces are on A's dart fan.
    m.buildLoops();

    // Setup sanity: `facesAroundVertex(A)` must actually enumerate BOTH
    // faces, or this rig isn't testing the tie-break at all (it would just
    // be testing "the only reachable face wins").
    int incidentCount = 0;
    foreach (fi; m.facesAroundVertex(0u)) ++incidentCount;
    assert(incidentCount == 2,
        "setup: vertex A(0) must be incident to BOTH the triangle and the pentagon");

    auto triangleBefore = m.faces[0].dup;

    t.commitSplit(0, 1);

    assert(m.faces.length == 3,
        "expected the PENTAGON to split into 2 sub-faces (triangle survives untouched) -- "
      ~ "3 total faces");
    bool triangleSurvives = false;
    foreach (f; m.faces) if (f[] == triangleBefore[]) triangleSurvives = true;
    assert(triangleSurvives,
        "the adjacent triangle (where A-C is a real edge) must survive byte-unchanged -- "
      ~ "the tool must have picked the PENTAGON, not the triangle");
    assert(history.canUndo(), "the pentagon split must be a real, undoable mutation");
}

// ---------------------------------------------------------------------------
// commitSplit — T8 (P9, doc/topopen_p9_split_plan.md §Testing): a real split
// must undo back to the exact pre-split state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 2);
    assert(history.canUndo(), "a real split must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-split state");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseButtonUp — MANDATORY DISPATCH (P9 REV1 FIX-2,
// doc/topopen_p9_split_plan.md): drives the REAL dispatch path directly —
// `onMouseButtonDown` (plain MMB -> `onPlainMmbDown`) and `onMouseButtonUp`
// (the restructured MIDDLE branch -> `commitSplit`) — rather than calling
// `commitSplit` directly as the 8 Tier-B cases above do. Those 8 cases
// exercise the MUTATION but bypass dispatch entirely, so they would NOT
// have caught the pre-FIX-2 shape (`if (!addLoopArmed_) return false; ...`)
// that made a `splitArmed_` check placed after it categorically
// unreachable. Also pins the guard-structure sanity FIX-2 calls for
// separately: `onMouseButtonDown`'s MIDDLE routing must send a Ctrl/Shift
// chord to Remove/Add Loop, never to Split.
//
// SDL's dynamic bindings must be resolved before any real `SDL_GetModState`/
// `SDL_SetModState` call (`onMouseButtonDown` reads the LIVE modifier state
// internally) — under a bare `dub test`, app.d's own `loadSDL()` (called
// from `main()`, which never runs before unittests execute) has NOT run
// yet; calling an unresolved dynamic SDL function segfaults. `loadSDL()`
// itself needs no `SDL_Init`/video subsystem — `SDL_GetModState`/
// `SDL_SetModState` are plain global-variable accessors in the real SDL2
// library, safe to call the moment the dynamic symbols are resolved, and
// `loadSDL()` is idempotent (safe to call more than once across unittests).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(-0.3f, 0, -0.3f));   // 0
    m.addVertex(Vec3( 0.3f, 0, -0.3f));   // 1
    m.addVertex(Vec3( 0.3f, 0,  0.3f));   // 2
    m.addVertex(Vec3(-0.3f, 0,  0.3f));   // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    float sx0, sy0, sx2, sy2, ndcZ;
    assert(projectToWindowFull(m.vertices[0], vp, sx0, sy0, ndcZ),
        "setup: v0 must project on-screen for this rig");
    assert(projectToWindowFull(m.vertices[2], vp, sx2, sy2, ndcZ),
        "setup: v2 must project on-screen for this rig");

    // --- Guard-structure sanity: onMouseButtonDown's MIDDLE routing must
    // send a Ctrl/Shift chord to the Remove/Add Loop handlers, never to
    // Split's onPlainMmbDown. Each probe closes its OWN gesture with a
    // matching release before the next probe presses the SAME (middle)
    // button again — real hardware can never emit two DOWNs for one button
    // without an intervening UP, so leaving Add Loop's press unreleased
    // here would fabricate exactly the malformed same-button DOWN-DOWN
    // sequence `resetAllGestureArms`'s own doc comment says is NOT
    // (and need not be) guarded against; a real press/release cycle never
    // strands `addLoopArmed_` for the next press to inherit. ---
    SDL_SetModState(KMOD_CTRL);
    {
        SDL_MouseButtonEvent eCtrl;
        eCtrl.button = SDL_BUTTON_MIDDLE;
        eCtrl.x = cast(int)sx0;
        eCtrl.y = cast(int)sy0;
        t.onMouseButtonDown(eCtrl, vts);
        assert(!t.splitArmed_, "Ctrl+MMB must route to Remove, never arm Split");
        // Remove is a remove-on-DOWN gesture with no armed state of its own
        // (D2) — nothing to release.
    }
    SDL_SetModState(KMOD_SHIFT);
    {
        SDL_MouseButtonEvent eShiftDown;
        eShiftDown.button = SDL_BUTTON_MIDDLE;
        eShiftDown.x = cast(int)sx0;
        eShiftDown.y = cast(int)sy0;
        t.onMouseButtonDown(eShiftDown, vts);
        assert(!t.splitArmed_, "Shift+MMB must route to Add Loop, never arm Split");

        SDL_MouseButtonEvent eShiftUp;
        eShiftUp.button = SDL_BUTTON_MIDDLE;
        eShiftUp.x = cast(int)sx0;
        eShiftUp.y = cast(int)sy0;
        t.onMouseButtonUp(eShiftUp, vts);
        assert(!t.addLoopArmed_,
            "closing the probe's own press/release must disarm Add Loop, "
          ~ "leaving nothing stranded for the real Split press below");
    }

    // --- The real end-to-end drive: plain-MMB DOWN on v0, plain-MMB UP on
    // the diagonal v2 -- must arm at DOWN and commit the split at UP, through
    // the ACTUAL dispatch path (onMouseButtonDown -> onPlainMmbDown;
    // onMouseButtonUp -> the FIX-2-restructured MIDDLE branch -> commitSplit). ---
    SDL_SetModState(cast(SDL_Keymod)0);
    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_MIDDLE;
    eDown.x = cast(int)sx0;
    eDown.y = cast(int)sy0;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "plain-MMB press on a vertex must be consumed");
    assert(t.splitArmed_, "plain-MMB press on a vertex must arm Split");
    assert(t.splitSourceVert_ == 0, "must arm the pressed vertex (0) as the split source");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)sx2;
    eUp.y = cast(int)sy2;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "plain-MMB release on the diagonal vertex must be consumed");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");

    assert(m.faces.length == 2, "the real dispatch path must have split the quad into 2 faces");
    assert(m.edges.length == 5, "the real dispatch path must have added the diagonal chord edge");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}
