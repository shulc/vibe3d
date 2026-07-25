module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : hypot, SQRT2;

import tool;
import mesh                : Mesh, GpuMesh;
import math               : Vec3, Viewport, projectToWindowFull, closestOnSegment2D,
                             screenPointToRay, closestPointOnSegmentToRay, dot,
                             pointInPolygon2D;
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
import bvh_pick              : BvhPick, SurfaceHit;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot              : MeshSnapshot;
import display_sync         : refreshDisplay;
import change_bus            : MeshEditScope;
import params                : Param, IntEnumEntry;
import tool_input            : ToolAction, PassThrough, InputPhase, InputButton,
                                InputMod, ResetScope, InputBinding,
                                resolveToolAction, toButton, toMods;

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

/// Factory the tool calls ONCE PER MOVE-LOOP GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P10, doc/topopen_p10_moveloop_plan.md) —
/// an EIGHTH dedicated factory, distinct from every sibling above: a
/// per-vertex loop re-snap is Position-only (like `TopoPenMoveFactory`/
/// `TopoPenSlideFactory`/`TopoPenSmoothFactory`), but reusing any of them
/// would bake the wrong `wireName` ("mesh.topoPen_move"/"mesh.topoPen_slide"/
/// "mesh.topoPen_smooth" on a loop drag — corrupts undo history / event-log
/// replay / macros). Wired with `wireName="mesh.topoPen_moveloop"` and
/// `MeshEditScope.Position` at the app.d construction site, mirroring
/// `topoPenSlideEditFactory`.
alias TopoPenMoveLoopFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER DUPLICATE-LOOP GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P11, doc/topopen_p11_duploop_plan.md) —
/// a NINTH dedicated factory, distinct from every sibling above: duplicating
/// an edge loop into a new bridge ring IS a topology change (wire name
/// "mesh.topoPen_duploop", editScope Geometry|Marks — the extrude resizes
/// selection arrays, same scope as `TopoPenAddLoopFactory`), so reusing any
/// sibling factory would corrupt undo history / event-log replay / macros
/// with the wrong wire name.
alias TopoPenDupLoopFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER SMOOTH+LOOP GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P12, doc/topopen_p12_smoothloop_plan.md) —
/// a TENTH dedicated factory, distinct from every sibling above: a 1-D
/// loop-restricted relax+re-snap gesture is Position-only (like
/// `TopoPenMoveLoopFactory`), but reusing it would bake the wrong wire name
/// ("mesh.topoPen_moveloop" on a smooth — corrupts undo history / event-log
/// replay / macros). Wired with `wireName="mesh.topoPen_smoothloop"` and
/// `MeshEditScope.Position` at the app.d construction site, mirroring
/// `topoPenMoveLoopEditFactory`.
alias TopoPenSmoothLoopFactory = MeshSessionEdit delegate();

/// Factory the tool calls ONCE PER FILL GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (Fill mode V1, task 0477 continuation,
/// doc/topopen_fill_plan.md) — an ELEVENTH dedicated factory, distinct from
/// every sibling above: capping a gap cell with one quad IS a topology
/// change (new face, and for a notch a new mouth edge too — Geometry
/// scope, like `TopoPenSplitFactory`/`TopoPenRemoveFactory`), so reusing
/// any sibling factory would bake the wrong wire name ("mesh.topoPen_split"/
/// "mesh.topoPen_remove" on a fill — corrupts undo history / event-log
/// replay / macros) onto its own atomic undo entry. Wired with
/// `wireName="mesh.topoPen_fill"` and `MeshEditScope.Geometry` at the
/// app.d construction site, mirroring `topoPenSplitEditFactory`.
alias TopoPenFillFactory = MeshSessionEdit delegate();

/// The four connectivity outcomes a drag-from-vertex build gesture can
/// resolve to on release, per `classifySource` below (capture-verified,
/// doc/topopen_p3_plan.md's mechanism table). `None` covers BOTH "the
/// source vertex's topology doesn't qualify" and the measured one-shot
/// ceiling (a hub already embedded in a quad classifies degree-2/non
/// -triangle-hub, which is exactly `None`).
private enum BuildCase { None, Edge, Tri, Quad }

/// Fill mode dropdown (task 0477 continuation, doc/topopen_fill_plan.md
/// REV 2, owner decision 1): the two values a plain-LMB click can dispatch
/// to. `Draw` (default) is today's existing place-on-empty/grab-move
/// behavior, byte-unchanged; `Fill` reroutes plain-LMB to
/// `findFillCell`/`commitFill` (Phase 4). A tool-wide dropdown, not a
/// per-gesture arm — mirrors `splitAtMiddle_`'s sticky-option precedent
/// (must survive `resyncSession()`, an external history navigation).
private enum PenMode { Draw, Fill }

// ---------------------------------------------------------------------------
// TopoPenAction / kTopoPenBindings — the declarative (button, modifier) ->
// action dispatch table (`source/tool_input.d`,
// doc/topopen_input_dispatch_phase2_plan.md), now the LIVE, authoritative
// classifier: `onMouseButtonDown`/`onMouseButtonUp` route every press through
// the base's `dispatchInput()` state machine against `kTopoPenBindings`
// below, which replaces the tool's own former hand-rolled DOWN-side
// `GestureSlot`/`resolveGestureSlot` classifier + UP-side arm-flag cascade
// (Phase 2 input-dispatch migration — a pure restructuring, no behavior
// change; see the plan for the byte-identity argument).
//
// The reference's COMPLETE 3-button × 4-modifier-state input grid for this
// tool (12 slots; doc-mined, cross-confirmed by 3 independent sources — help
// text, per-mode cfg Desc strings, and the input-map cfg's abstract-event
// grid — see toolcards/topology_pen/gesture_map.md, PRIVATE) has NO
// Alt-modified slot (Alt is reserved for camera nav everywhere in vibe3d,
// hard-blocked by `resolveToolAction` itself, above any table scan) and 2
// slots that stay undocumented/unimplemented (Ctrl+RMB, Shift+Ctrl+MMB).
// `kTopoPenBindings` is a 1:1 transcription of the 10 WIRED slots; the 2
// undocumented slots and every Alt combo are simply ABSENT from the table,
// so `resolveToolAction` answers `PassThrough` for them and `dispatchInput`
// returns `false` without ever calling `onToolAction` — byte-identical to
// the old classifier's own `CtrlRmb`/`ShiftCtrlMmb`/`None` cases falling
// through unconsumed.
// ---------------------------------------------------------------------------
private enum TopoPenAction : ToolAction {
    LmbPlaceOrMove,   // plain LMB       — place-on-empty OR grab-move (resolved at Down)
    Build,            // Shift+LMB       — drag-build (P3)
    Slide,            // Ctrl+LMB        — edge slide (P7)
    Smooth,           // Shift+Ctrl+LMB  — whole-mesh smooth (P8)
    Split,            // plain MMB       — vertex-to-vertex split (P9)
    AddLoop,          // Shift+MMB       — add loop cut (P6)
    Remove,           // Ctrl+MMB        — remove-on-DOWN face delete (P5); Up is a no-op
    MoveLoop,         // plain RMB       — move edge loop (P10)
    DupLoop,          // Shift+RMB       — duplicate edge loop (P11)
    SmoothLoop,       // Shift+Ctrl+RMB  — loop-restricted smooth (P12)
}

/// LEFT rows are `ResetScope.AllButtons` — reproduces the LEFT-button trio's
/// own top-of-handler `resetAllGestureArms()` call (`onPlainLmbDown`/
/// `onShiftLmbDown`/`onCtrlLmbDown`/`onShiftCtrlLmbDown`), now wired through
/// `dispatchInput`'s `onInputResetAll()` hook instead. MIDDLE/RIGHT rows stay
/// the default `SelfButton` — each mode's own narrow self-reset (already
/// inside the kept `on*Down` methods) is what closes a same-slot re-press
/// hazard for those buttons, exactly as today (see `resetAllGestureArms`'s
/// own doc comment for why MIDDLE/RIGHT deliberately do NOT get a full reset:
/// a chord on those buttons can legitimately coexist with a held LEFT drag).
private immutable InputBinding[] kTopoPenBindings = [
    InputBinding(InputButton.Left,   InputMod.None,                   TopoPenAction.LmbPlaceOrMove, ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Shift,                  TopoPenAction.Build,          ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Ctrl,                   TopoPenAction.Slide,          ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Shift | InputMod.Ctrl,  TopoPenAction.Smooth,         ResetScope.AllButtons),
    InputBinding(InputButton.Middle, InputMod.None,                   TopoPenAction.Split),
    InputBinding(InputButton.Middle, InputMod.Shift,                  TopoPenAction.AddLoop),
    InputBinding(InputButton.Middle, InputMod.Ctrl,                   TopoPenAction.Remove),
    InputBinding(InputButton.Right,  InputMod.None,                   TopoPenAction.MoveLoop),
    InputBinding(InputButton.Right,  InputMod.Shift,                  TopoPenAction.DupLoop),
    InputBinding(InputButton.Right,  InputMod.Shift | InputMod.Ctrl,  TopoPenAction.SmoothLoop),
];

// ---------------------------------------------------------------------------
// kTopoPenBindings — exhaustive resolver-grid pin. A single pure,
// camera-free regression guard covering EVERY (button, modifier) combo this
// tool's grid can see — replaces the 7 scattered `resolveGestureSlot` guards
// the pre-Phase-2 classifier used to need (Ctrl+MMB/Shift+MMB/Ctrl+LMB/
// plain-MMB/plain-RMB/Shift+RMB/Shift+Ctrl+RMB), consolidated into ONE table
// so a bad merge that silently drops or misroutes a row is caught here
// rather than by 7 separate best-effort pins. All 10 bound slots resolve to
// their documented action; the 2 undocumented slots (Ctrl+RMB,
// Shift+Ctrl+MMB) and every Alt-held combo resolve to `PassThrough` (Alt is
// hard-blocked by `resolveToolAction` itself, above the table scan — this
// pin also proves that holds for THIS tool's table).
// ---------------------------------------------------------------------------
unittest {
    // The 10 documented slots.
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.None)
        == TopoPenAction.LmbPlaceOrMove, "plain LMB must resolve to LmbPlaceOrMove");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift)
        == TopoPenAction.Build, "Shift+LMB must resolve to Build");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Ctrl)
        == TopoPenAction.Slide, "Ctrl+LMB must resolve to Slide");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift | InputMod.Ctrl)
        == TopoPenAction.Smooth, "Shift+Ctrl+LMB must resolve to Smooth");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.None)
        == TopoPenAction.Split, "plain MMB must resolve to Split");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift)
        == TopoPenAction.AddLoop, "Shift+MMB must resolve to AddLoop");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Ctrl)
        == TopoPenAction.Remove, "Ctrl+MMB must resolve to Remove");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.None)
        == TopoPenAction.MoveLoop, "plain RMB must resolve to MoveLoop");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift)
        == TopoPenAction.DupLoop, "Shift+RMB must resolve to DupLoop");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift | InputMod.Ctrl)
        == TopoPenAction.SmoothLoop, "Shift+Ctrl+RMB must resolve to SmoothLoop");

    // The 2 undocumented slots -- absent from the table -> PassThrough.
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Ctrl) == PassThrough,
        "Ctrl+RMB is undocumented -> PassThrough");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift | InputMod.Ctrl) == PassThrough,
        "Shift+Ctrl+MMB is undocumented -> PassThrough");

    // Every Alt combo -> PassThrough, on every button, with or without other
    // modifiers held alongside it (Alt is hard-blocked above the table scan,
    // per `resolveToolAction`'s own contract).
    foreach (btn; [InputButton.Left, InputButton.Middle, InputButton.Right]) {
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Shift) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Ctrl) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Shift | InputMod.Ctrl) == PassThrough);
    }
}

// ---------------------------------------------------------------------------
// TopologyPenTool — Phases P0 + P1 + P2 + P3 + P4 + P5 + P6 + P7 of the
// topology-pen port (factory id `mesh.topoPen`, doc/topopen_p0_plan.md,
// doc/topopen_p1_plan.md, doc/topopen_p2_plan.md, doc/topopen_p3_plan.md,
// doc/topopen_p4_plan.md, doc/topopen_p5_remove_plan.md,
// doc/topopen_p6_addloop_plan.md, doc/topopen_p7_slide_plan.md).
//
// P7 adds SLIDE on the **Ctrl+LMB** overlay slot (`TopoPenAction.Slide`,
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
// Move/Place, P6 Add Loop, P7 Slide) and fires BEFORE every LEFT-button
// gesture-DOWN handler (`onPlainLmbDown`/`onShiftLmbDown`/`onCtrlLmbDown`)
// runs — originally via each handler's own top-of-body call, now (Phase-3
// dispatch cleanup, doc/topopen_input_dispatch_phase2_plan.md §Phase 3) via
// `dispatchInput`'s `onInputResetAll()` hook instead, since every LEFT row
// in `kTopoPenBindings` is `ResetScope.AllButtons` — before that press
// (maybe) re-arms exactly one of them — superseding the old per-handler
// partial resets, which left OTHER arm groups stranded true across a
// replayed/malformed DOWN-DOWN-UP sequence (a later release would then fire
// the WRONG committer against stale indices). `resyncSession()` itself is
// now a one-line call to the same helper. `onCtrlMmbDown`/`onShiftMmbDown`
// (the MIDDLE-button handlers)
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
// (`TopoPenAction.AddLoop`, doc/topopen_p6_addloop_plan.md): a press picks
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
// P5 adds REMOVE on the **Ctrl+MMB** overlay slot (`TopoPenAction.Remove`,
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
// P4 adds MOVE on the plain (unmodified) **LMB** slot (`TopoPenAction.LmbPlaceOrMove`) —
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
// `TopoPenAction`/`kTopoPenBindings` above): a Shift+LMB press landing on an
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
// slots) is a named, inert stub for later phases — see `TopoPenAction`'s own
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

    // --- P10 Move Loop gesture deps (doc/topopen_p10_moveloop_plan.md) ---
    TopoPenMoveLoopFactory moveLoopEditFactory_;

    // --- P11 Dup Loop gesture deps (doc/topopen_p11_duploop_plan.md) ---
    TopoPenDupLoopFactory dupLoopEditFactory_;

    // --- P12 Smooth+Loop gesture deps (doc/topopen_p12_smoothloop_plan.md) ---
    TopoPenSmoothLoopFactory smoothLoopEditFactory_;

    // --- Fill mode deps (task 0477 continuation, doc/topopen_fill_plan.md) ---
    TopoPenFillFactory fillEditFactory_;

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

    // Mid-edge Split option (doc/topopen_midedge_split_plan.md Deliverable
    // #4): "Split at the Middle" — a STICKY tool-wide mode toggle, NOT
    // per-gesture arm state. Forces the mid-edge insert fraction `f` to
    // exactly 0.5 regardless of the release click's position along the
    // edge. Default OFF (owner-observed: Split lands at the click point by
    // default). Deliberately absent from `resetAllGestureArms()`/
    // `resyncSession()` — those clear per-gesture arm bools on every fresh
    // press / external history navigation; this option must survive both
    // (matches `tool_activate_sticky_clobber` precedent: sticky options are
    // set before `activate()`/arm-reset and must not be clobbered by
    // either). Read live at commit time by `splitUp` (never cached).
    bool splitAtMiddle_    = false;

    // Fill mode dropdown (task 0477 continuation, doc/topopen_fill_plan.md
    // Phase 1): the wire-tag table backing `PenMode`'s `Param.intEnum_` —
    // mirrors `loop_slice_tool.d`'s `editTable`/`modeTable` precedent. A
    // STICKY tool-wide mode toggle, NOT per-gesture arm state — like
    // `splitAtMiddle_` above, deliberately absent from
    // `resetAllGestureArms()`/`resyncSession()` (a mode switch must survive
    // an external history navigation) and read live by dispatch
    // (`onPlainLmbDown`) / the motion-time preview compute
    // (`onMouseMotion`), never cached.
    private static immutable IntEnumEntry[2] penModeTable = [
        IntEnumEntry(cast(int)PenMode.Draw, "draw", "Draw"),
        IntEnumEntry(cast(int)PenMode.Fill, "fill", "Fill"),
    ];
    PenMode penMode_ = PenMode.Draw;   // default = today's plain-LMB place/move, unchanged

    // --- P10 Move Loop session state (topology_pen.d,
    // doc/topopen_p10_moveloop_plan.md). Armed on an RMB press that lands on
    // a primary-layer edge (`onMoveLoopRmbDown`, reusing `findRingSeedEdge`
    // verbatim from P6/P7): the moving set is the SORTED-UNIQUE endpoint
    // vertices of `Mesh.selectLoopEdges(seed)` (REV1 FIX-1 — the classic
    // in-line edge-loop CHAIN, not `loopSliceRingEdges`'s perpendicular
    // ring), captured ONCE at arm time (the mesh is never mutated between
    // arm and commit, so re-gathering at release would be redundant, not
    // more correct — and a stale index after an external undo mid-drag is
    // handled by `resyncSession` clearing all of this instead).
    // `moveLoopStartX_`/`moveLoopStartY_` is the RMB-down pixel (the drag's
    // anchor); `moveLoopCurX_`/`moveLoopCurY_` tracks the LIVE cursor off
    // every subsequent motion event (`onMouseMotion`) purely for `draw()`'s
    // ghost preview — the shared screen-delta `commitMoveLoop` actually
    // applies is always computed from the RELEASE event's own pixel
    // (`onMouseButtonUp`), never from this cached value. `loopBgBvh_` is
    // this tool's OWN per-background-mesh `BvhPick` cache (mirrors P5's
    // `removePick_`/CONS's own `_bgBvh`, `constrain.d:82`) — driven ONLY
    // from the main thread (motion/up/draw), so no `cursorValid` gate is
    // needed (plan Risk 3). Cleared by `onMouseButtonUp` on commit/no-op
    // and by `resyncSession` on an external history navigation, exactly
    // like the P3/P4/P6/P7/P9 arm state above; `loopBgBvh_` itself is a
    // CACHE, not arm state, so it survives a reset (mirrors `removePick_`'s
    // own lifetime).
    bool  moveLoopArmed_  = false;
    int   moveLoopSeed_   = -1;
    int   moveLoopStartX_, moveLoopStartY_;
    int   moveLoopCurX_,   moveLoopCurY_;
    uint[] moveLoopVerts_;
    BvhPick[size_t] loopBgBvh_;

    // --- P11 Dup Loop session state (topology_pen.d,
    // doc/topopen_p11_duploop_plan.md). Armed on a Shift+RMB press that
    // lands on a primary-layer edge (`onDupLoopShiftRmbDown`, reusing
    // `findRingSeedEdge` verbatim from P6/P7/P10): `dupLoopEdges_` are the
    // gathered loop's raw EDGE INDICES (`Mesh.selectLoopEdges(seed)` — REV1
    // FIX-1 label correction: a BOUNDARY seed is the FULL CLOSED perimeter
    // — the owner-observed spec case — an INTERIOR seed an OPEN chain, see
    // `onDupLoopShiftRmbDown`'s own doc comment), captured ONCE at arm time
    // — the mesh is never mutated between arm and commit, so re-gathering
    // at release would be redundant, not more correct, and a stale index
    // after an external undo mid-drag is handled by `resyncSession`
    // clearing all of this instead. Unlike P10 Move Loop (which stores the
    // unique VERTEX set), this stores the EDGE list — the commit needs it
    // to build `Mesh.extendEdgesByMask`'s mask, not just a moving set.
    // `dupLoopStartX_`/`dupLoopStartY_` is the Shift+RMB-down pixel (the
    // drag's anchor); `dupLoopCurX_`/`dupLoopCurY_` tracks the LIVE cursor
    // off every subsequent motion event (`onMouseMotion`) purely for
    // `draw()`'s ghost preview — the shared screen-delta `commitDupLoop`
    // actually applies is always computed from the RELEASE event's own
    // pixel (`onMouseButtonUp`), never from this cached value. The
    // extrude+drag itself is deferred to ONE atomic release-time commit
    // (`commitDupLoop`), mirroring P6 Add Loop's/P9 Split's own
    // defer-to-release discipline for a topology-growing op — never a
    // mid-drag mutation. Cleared by `onMouseButtonUp` on commit/no-op and
    // by `resyncSession` on an external history navigation, exactly like
    // the P3-P10 arm state above; `loopBgBvh_` (shared with P10, above) is
    // reused verbatim — a gesture-agnostic per-background-mesh cache, no
    // new field needed.
    bool  dupLoopArmed_   = false;
    int   dupLoopSeed_    = -1;
    int[] dupLoopEdges_;
    int   dupLoopStartX_, dupLoopStartY_;
    int   dupLoopCurX_,   dupLoopCurY_;

    // --- P12 Smooth+Loop session state (topology_pen.d,
    // doc/topopen_p12_smoothloop_plan.md). Armed on a Shift+Ctrl+RMB press
    // that lands on a primary-layer edge (`onSmoothLoopRmbDown`, reusing
    // `findRingSeedEdge` verbatim from P6/P7/P10/P11); the moving set is the
    // SAME sorted-unique endpoint-vertex gather P10 uses (`uniqueRingVerts`),
    // captured ONCE at arm time into `smoothLoopVerts_` — the mesh is never
    // mutated between arm and commit, so re-gathering at release would be
    // redundant, not more correct (REV1 FIX-2: the commit REUSES this cache
    // verbatim rather than re-running `uniqueRingVerts`) — and a stale index
    // after an external undo mid-drag is handled by `resyncSession` clearing
    // all of this instead. `smoothLoopStartX_`/`_Y_` is the press pixel;
    // `smoothLoopCurX_`/`_Y_` doubles as BOTH the running "last motion
    // position" the drag-distance accumulator measures against (mirroring
    // the whole-mesh Smooth gesture's own `smoothLastX_`/`_Y_`) AND the live
    // cursor `draw()`'s ghost ring previews at (mirroring Move Loop's
    // `moveLoopCurX_`/`_Y_`) — one field serves both roles since after every
    // motion event it IS the live cursor. `smoothLoopDragPx_` accumulates
    // cursor travel exactly like the whole-mesh Smooth gesture's
    // `smoothDragPx_` — the only read of it is at release, to derive the
    // pass count (`onMouseButtonUp`'s Smooth+Loop branch). Cleared by
    // `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation, exactly like the P3-P11 arm state above.
    bool   smoothLoopArmed_   = false;
    int    smoothLoopSeed_    = -1;
    uint[] smoothLoopVerts_;
    int    smoothLoopStartX_, smoothLoopStartY_;
    int    smoothLoopCurX_,   smoothLoopCurY_;
    float  smoothLoopDragPx_ = 0.0f;

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

    // --- Generic Hover-Highlight indicator (doc/topopen_hover_highlight_plan.md,
    // REV1). An always-on, mode-INDEPENDENT "what's under the cursor"
    // affordance over the PRIMARY mesh, orthogonal to every armed gesture
    // above: resolved every motion event (`onMouseMotion`, below) via
    // `computeHoverIndicator` and rendered in `draw()` UNDER the per-mode
    // gesture ghosts (Build/Move/AddLoop/Slide/Smooth/Split/MoveLoop) —
    // those take precedence whenever `anyGestureArmed()` is true. Pure
    // render: no mesh mutation, no undo. Distinct from the P0/P1 CONS
    // `lastHit_`/`lastTarget_` (background-cage) hover path below, which is
    // left intact — that one resolves over the BACKGROUND and picks ONE of
    // vertex/edge/face; this one is over the PRIMARY and shows the nearest
    // vertex AND edge simultaneously.
    //
    // `hoverNearestVert_`/`hoverNearestEdge_` are the screen-nearest PRIMARY
    // vertex/edge (via `findSourceVertex`/`findRingSeedEdge`'s `∞`-threshold
    // RESOLUTION pass). REV1 FIX-1 (KILLER): `hoverOverMesh_` — the over-
    // mesh GATE — is NOT driven solely by `pickPrimaryFace >= 0` (a
    // face-BVH raycast that returns -1 whenever the primary has zero/sparse
    // faces — this tool's own from-scratch retopo founding state, bare
    // vertices/edges laid down before the first face closes; `classifySource`
    // explicitly treats `BuildCase.Edge`/`Tri` as normal ongoing states, not
    // error cases). Instead the gate is the OR of the face pick AND a
    // SEPARATE, FINITE-threshold proximity pass of the SAME two functions
    // (computed in `onMouseMotion`, never reused across the two purposes),
    // so a faceless/bare-edge scene still lights up while a cursor genuinely
    // far from all geometry does not.
    //
    // `hoverBoundary_` is `isEdgeBorder(hoverNearestEdge_)` (n == 1 EXACTLY —
    // MINOR-4: NOT "<=1"; a 0-face bare edge is not a boundary, it simply has
    // nothing to hatch) and `hoverBoundaryFace_` is that single incident
    // face (via `facesAroundEdge`), for the cross-hatch in `draw()`. Cleared
    // by `resyncSession` on an external history navigation (no motion event
    // may follow it), mirroring every other session-state block above —
    // but unlike the P3-P10 arm flags, this is NOT part of
    // `resetAllGestureArms()`/`anyGestureArmed()`: it is not a gesture arm,
    // just a passive display cache with no commit path of its own.
    bool hoverOverMesh_     = false;
    int  hoverNearestVert_  = -1;
    int  hoverNearestEdge_  = -1;
    bool hoverBoundary_     = false;
    int  hoverBoundaryFace_ = -1;

    // Fill mode hover preview (task 0477 continuation,
    // doc/topopen_fill_plan.md Phase 5): the ONE candidate gap-cell's 4
    // corner verts (any rotation) under the cursor, or `null` when the mode
    // isn't Fill / no cell is under the cursor / a gesture is armed. A
    // passive display cache — like `hoverNearestVert_` above — NOT part of
    // `resetAllGestureArms()`/`anyGestureArmed()`. Computed unconditionally
    // in `onMouseMotion`'s not-armed branch (its own sibling gate, NOT
    // nested inside the `hoverOverMesh_` block above — see the plan's
    // mandatory opponent fix #2: `hoverOverMesh_` requires a pick within
    // `kTopoPenSnapPx`, which is false when hovering the CENTER of an empty
    // gap cell, exactly the defining Fill-mode case).
    uint[] fillCell_;

    // Visual constants (Pinned Decision 4): a steel-blue palette
    // DELIBERATELY distinct from both the P1 bg-cage bright-cyan
    // `IM_COL32(0,220,255,…)` (`markerCol`/cyan, `draw()` below) and the
    // pen-orange `markerCol` (`draw()` below) — different hues, not a
    // near-miss. MINOR-6: flagged as an owner watch-item (the
    // retopo-over-background use case can place the two markers at nearly
    // the same pixel) — V1 does not gate on resolving it.
    private enum uint  kHoverElemCol          = IM_COL32(128, 170, 187, 255);
    private enum float kHoverVertSquareHalfPx = 6.0f;   // -> 12x12px filled square
    private enum float kHoverEdgeWidthPx      = 2.0f;
    private enum uint  kHoverHatchCol         = IM_COL32(40, 40, 40, 150);
    private enum float kHoverHatchSpacingPx   = 7.0f;
    private enum float kHoverHatchWidthPx     = 1.0f;

    // Fill-mode candidate-cell preview colour (task 0477 continuation,
    // doc/topopen_fill_plan.md Phase 5): a green DELIBERATELY distinct from
    // the steel-blue `kHoverElemCol` above and the pen-orange `markerCol`
    // (`draw()` below) — a third, unambiguous hue for "this cell would be
    // capped".
    private enum uint  kFillPreviewCol         = IM_COL32(120, 210, 120, 230);

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
    // P10 (doc/topopen_p10_moveloop_plan.md): 10th positional param `mlf`
    // appended LAST (after `spf`) for the Move Loop factory — same
    // rationale as every prior addition: `TopoPenMoveLoopFactory` is yet
    // another structurally identical delegate alias, so inserting it
    // anywhere but the tail would silently mis-bind a sibling gesture's
    // factory rather than fail to compile. `bf`/`mf`/`rf`/`alf`/`sf`/`smf`/
    // `spf` MUST stay in their existing positions — every existing
    // positional caller (registration.d) stays byte-unchanged through `spf`.
    // P11 (doc/topopen_p11_duploop_plan.md): 11th positional param `dlf`
    // appended LAST (after `mlf`) for the Dup Loop factory — same rationale
    // as every prior addition: `TopoPenDupLoopFactory` is yet another
    // structurally identical delegate alias, so inserting it anywhere but
    // the tail would silently mis-bind a sibling gesture's factory rather
    // than fail to compile. `bf`/`mf`/`rf`/`alf`/`sf`/`smf`/`spf`/`mlf` MUST
    // stay in their existing positions — every existing positional caller
    // (registration.d) stays byte-unchanged through `mlf`.
    // P12 (doc/topopen_p12_smoothloop_plan.md, REV1 FIX-1): 12th positional
    // param `slf` appended LAST (after `dlf`) for the Smooth+Loop factory —
    // same rationale as every prior addition: `TopoPenSmoothLoopFactory` is
    // yet another structurally identical delegate alias, so inserting it
    // anywhere but the tail would silently mis-bind a sibling gesture's
    // factory rather than fail to compile. `bf`/`mf`/`rf`/`alf`/`sf`/`smf`/
    // `spf`/`mlf`/`dlf` MUST stay in their existing positions — every
    // existing positional caller (registration.d) stays byte-unchanged
    // through `dlf`.
    // Fill mode (task 0477 continuation, doc/topopen_fill_plan.md): 13th
    // positional param `flf` appended LAST (after `slf`) for the Fill
    // factory — same rationale as every prior addition: `TopoPenFillFactory`
    // is yet another structurally identical delegate alias, so inserting it
    // anywhere but the tail would silently mis-bind a sibling gesture's
    // factory rather than fail to compile. `bf`/`mf`/`rf`/`alf`/`sf`/`smf`/
    // `spf`/`mlf`/`dlf`/`slf` MUST stay in their existing positions — every
    // existing positional caller (registration.d) stays byte-unchanged
    // through `slf`.
    void setUndoBindings(CommandHistory h, VertexNewFactory f,
                        TopoPenBuildFactory bf = null,
                        TopoPenMoveFactory mf = null,
                        TopoPenRemoveFactory rf = null,
                        TopoPenAddLoopFactory alf = null,
                        TopoPenSlideFactory sf = null,
                        TopoPenSmoothFactory smf = null,
                        TopoPenSplitFactory spf = null,
                        TopoPenMoveLoopFactory mlf = null,
                        TopoPenDupLoopFactory dlf = null,
                        TopoPenSmoothLoopFactory slf = null,
                        TopoPenFillFactory flf = null) {
        history_           = h;
        addVertexFactory_  = f;
        buildEditFactory_  = bf;
        moveEditFactory_   = mf;
        removeEditFactory_ = rf;
        addLoopEditFactory_ = alf;
        slideEditFactory_   = sf;
        smoothEditFactory_  = smf;
        splitEditFactory_   = spf;
        moveLoopEditFactory_ = mlf;
        dupLoopEditFactory_  = dlf;
        smoothLoopEditFactory_ = slf;
        fillEditFactory_     = flf;
    }

    override string name() const { return "Topology Pen"; }

    // Mid-edge Split option schema (doc/topopen_midedge_split_plan.md
    // Deliverable #4) — the FIRST `params()` override on this tool. Backs
    // both the `tool.attr mesh.topoPen splitMiddle ?` HTTP path and the
    // `config/forms/topology_pen.yaml` checkbox row; the attr name
    // "splitMiddle" MUST match that form's `control:` string exactly — the
    // boot-time `validateForms` strict-checks every form attr against this
    // list and fails loud on a typo.
    //
    // Fill mode dropdown (task 0477 continuation, doc/topopen_fill_plan.md
    // Phase 1, MANDATORY opponent fix #1): the `mode` IntEnum Param is
    // APPENDED to this array — never a full-replace, which would drop
    // `splitMiddle` and fail boot-time `validateForms` against its existing
    // yaml row. "mode" MUST match `config/forms/topology_pen.yaml`'s new
    // dropdown row's `control:` string exactly, same contract as
    // `splitMiddle` above.
    override Param[] params() {
        return [
            Param.bool_("splitMiddle", "Split at the Middle", &splitAtMiddle_, false),
            Param.intEnum_("mode", "Mode", cast(int*)&penMode_, penModeTable,
                           cast(int)PenMode.Draw),
        ];
    }

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

        // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
        // 3): resolve the always-on indicator state BEFORE the armed-gesture
        // branches below — a gesture ghost (once armed) takes precedence
        // over the generic indicator (`draw()`'s own `!anyGestureArmed()`
        // gate mirrors this). REV1 FIX-1 (KILLER): the over-mesh gate is the
        // OR of `pickPrimaryFace` (front-most face pick — the "hovering the
        // middle of a big face" case, Pinned Decision 2) with a FINITE-
        // threshold proximity hit on either `findSourceVertex` or
        // `findRingSeedEdge` (the faceless/bare-edge founding-state case) —
        // a SEPARATE pass from `computeHoverIndicator`'s own `∞`-threshold
        // RESOLUTION scan below, never the same call reused for both
        // purposes. Never `return true` — the hover must not consume the
        // motion (place/build/etc. still happen on button-up; the existing
        // handler already returns `false` at the tail when idle).
        if (anyGestureArmed()) {
            hoverOverMesh_ = false;   // gesture ghosts take precedence
            fillCell_      = null;   // Fill mode continuation: same precedence rule
        } else {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            int hf       = pickPrimaryFace(e.x, e.y, vp);
            int gateVert = findSourceVertex(e.x, e.y, vp, kTopoPenSnapPx);
            int gateEdge = findRingSeedEdge(e.x, e.y, vp, kTopoPenSnapPx);
            hoverOverMesh_ = (hf >= 0) || (gateVert >= 0) || (gateEdge >= 0);
            if (hoverOverMesh_) {
                computeHoverIndicator(e.x, e.y, vp);
            } else {
                hoverNearestVert_ = hoverNearestEdge_ = hoverBoundaryFace_ = -1;
                hoverBoundary_    = false;
            }

            // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md
            // Phase 5, MANDATORY opponent fix #2): computed UNCONDITIONALLY
            // here — NOT nested inside `if (hoverOverMesh_)` above — because
            // `hoverOverMesh_` requires a pick within `kTopoPenSnapPx`,
            // which is FALSE when hovering the CENTER of an empty gap cell:
            // exactly the defining Fill-mode case (no vertex/edge/face is
            // anywhere near the cursor). Nesting it in that block would
            // make the preview never render for that scenario.
            fillCell_ = (penMode_ == PenMode.Fill) ? findFillCell(e.x, e.y, vp) : null;
        }

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

        // P10 (doc/topopen_p10_moveloop_plan.md Phase 4): while a Move Loop
        // gesture is armed, just track the live cursor for `draw()`'s ghost
        // preview — the shared screen-delta itself is always recomputed from
        // the RELEASE event's own pixel at commit time
        // (`onMouseButtonUp`/`perVertexTargets`), never from this cached
        // value, so no re-snap work happens here. Consumes, mirroring the
        // Add Loop/Slide/Smooth/Split branches above.
        if (moveLoopArmed_) {
            moveLoopCurX_ = e.x;
            moveLoopCurY_ = e.y;
            return true;
        }

        // P11 (doc/topopen_p11_duploop_plan.md Phase 3): while a Dup Loop
        // gesture is armed, just track the live cursor for `draw()`'s ghost
        // preview — the shared screen-delta itself is always recomputed
        // from the RELEASE event's own pixel at commit time
        // (`onMouseButtonUp`/`commitDupLoop`), never from this cached
        // value, so no extrude/re-snap work happens here. Consumes,
        // mirroring the Move Loop branch above.
        if (dupLoopArmed_) {
            dupLoopCurX_ = e.x;
            dupLoopCurY_ = e.y;
            return true;
        }

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 2): while a
        // Smooth+Loop gesture is armed, accumulate cursor travel off the
        // RUNNING last position (mirrors the whole-mesh Smooth branch's
        // `smoothDragPx_` accumulation, P8) — click=1 pass, a longer drag =
        // more passes (`onMouseButtonUp`'s Smooth+Loop branch derives the
        // pass count from THIS running total) — and update
        // `smoothLoopCurX_`/`_Y_` to the SAME running position for
        // `draw()`'s cursor-ring ghost (Move Loop's `moveLoopCurX_` role):
        // no separate "last" field needed, since the running position IS
        // the live cursor after each motion event. No mid-drag
        // mutation/preview beyond `draw()`'s cheap affordance (deferred
        // commit, mirroring P8). Consumes, mirroring every other
        // armed-gesture branch above.
        if (smoothLoopArmed_) {
            smoothLoopDragPx_ += hypot(cast(float)(e.x - smoothLoopCurX_),
                                      cast(float)(e.y - smoothLoopCurY_));
            smoothLoopCurX_ = e.x;
            smoothLoopCurY_ = e.y;
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
    //
    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 1
    // item 4): `thresholdPx` defaults to `kTopoPenSnapPx`, so every existing
    // gesture caller (`onPlainLmbDown`, `onShiftLmbDown`, `onCtrlLmbDown`,
    // the Split motion handler, etc. — none of which pass a 3rd argument)
    // stays BYTE-IDENTICAL. The hover-resolve path (`onMouseMotion`, below)
    // passes `float.infinity` for the unconditional nearest (RESOLUTION),
    // and a finite value for the over-mesh GATE decision (REV1 FIX-1) — two
    // distinct calls, never conflated.
    private int findSourceVertex(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapPx) {
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
        if (best >= 0 && bestD2 <= thresholdPx * thresholdPx) return best;
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

    // Mid-edge Split (doc/topopen_midedge_split_plan.md Deliverable #3): the
    // pre-mutation VIABILITY GATE for the release-on-edge case — the ONLY
    // new mesh-adjacent logic this extension adds. Resolves which face
    // (incident to edge `edgeIdx`) also contains the source vertex `a`, so
    // the eventual chord A-M (M = the not-yet-inserted mid-edge vertex)
    // has somewhere to land. Returns -1 for every no-op condition: m/a/
    // edgeIdx invalid or out of bounds, or A being one of edge `edgeIdx`'s
    // own two endpoints (the chord would be degenerate — A already IS a
    // corner of any face incident to E, so splitting "at A" is meaningless).
    //
    // MUST be called BEFORE any mutation (`addEdgePoint`/snapshot) — a
    // gesture that fails this gate stays a byte-identical no-op, no undo
    // entry recorded (mirrors `findCommonSplitFace`'s own contract for the
    // vertex-target case).
    //
    // Once this returns a real face fi: M will be spliced between E's two
    // endpoints in fi's winding (by `addEdgePoint`, unconditionally, for
    // every face incident to E) — since A is neither of E's endpoints, A
    // and M are always non-adjacent in fi's post-insert winding, so the
    // later `splitFaceByVertices(fi, a, M)` call is GUARANTEED to succeed
    // (each half keeps >=3 sides). `facesAroundEdge` is safe here (E is a
    // real mesh edge with at least fi incident) — the bare/floating-edge
    // caveat `classifySource`'s KILLER-1 comment warns about does not apply
    // to an edge that is already part of a face.
    private int findEdgeSplitFace(Mesh* m, int a, int edgeIdx) {
        if (m is null || a < 0 || edgeIdx < 0) return -1;
        if (a >= cast(int)m.vertices.length) return -1;
        if (edgeIdx >= cast(int)m.edges.length) return -1;

        uint e0 = m.edges[edgeIdx][0], e1 = m.edges[edgeIdx][1];
        if (cast(uint)a == e0 || cast(uint)a == e1) return -1;   // A on E -> degenerate chord

        foreach (fi; m.facesAroundEdge(cast(uint)edgeIdx)) {
            foreach (vv; m.faces[fi]) {
                if (vv == cast(uint)a) return cast(int)fi;
            }
        }
        return -1;
    }

    // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md Phase
    // 3): pure, GL-free detection of the ONE quad gap-cell under the
    // cursor — reconstructed from BORDER-edge adjacency, never a
    // whole-boundary-loop trace (owner decision 2: "one cell per click").
    // Returns the 4 corner verts (any rotation — `commitFill`'s
    // `makePolygonFromVerts(autoOrient:true)` fixes winding), or `null`
    // when no gap cell contains the cursor (over a solid face, empty area,
    // or every candidate quad misses).
    //
    // Algorithm:
    //   1. Scan every border edge (`isEdgeBorder`, n==1 EXACTLY) once,
    //      building a border-vertex adjacency map — each border vert's
    //      OTHER border-edge neighbour(s).
    //   2. For every border edge E=(a,b): for every border-neighbour a' of
    //      a (a' != b) and every border-neighbour b' of b (b' != a), form
    //      the candidate quad cycle [a', a, b, b'] (three consecutive cell
    //      sides a'->a->b->b'; the fourth side b'->a' closes it — for a
    //      notch that fourth side is the absent mouth). Skip unless all 4
    //      verts are distinct. Seeding from BORDER edges guarantees the
    //      candidate lies on the face-FREE side of E (E's one incident
    //      face sits on the OTHER side), so a candidate can never coincide
    //      with an existing face — `commitFill` still self-guards via
    //      `makePolygonFromVerts`'s own `-1` reject regardless.
    //   3. Project all 4 verts (skip a candidate with any vertex behind
    //      the camera) and even-odd point-in-polygon test against
    //      (mx,my) — winding-agnostic.
    //   4. Pick the SMALLEST-screen-area candidate that contains the
    //      cursor — the load-bearing tiebreak that implements "nearest
    //      cell to the cursor": for a 2-cell gap/notch the tight true cell
    //      beats every bogus cross-cell quad on area, and it rejects the
    //      outer perimeter (a perimeter-seeded candidate is huge or does
    //      not contain an interior cursor).
    //
    // Known V1 limitation (vibe3d-divergence, not a blocker — owner
    // pinned the behavior): highly irregular / non-planar hole boundaries
    // could in principle let a bogus candidate be both smaller AND
    // cursor-containing than the true cell. Grid-like retopo meshes (this
    // tool's domain) are robust to this.
    private uint[] findFillCell(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null) return null;
        auto m = mesh;
        if (m is null) return null;

        uint[][uint] borderNbrs;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeBorder(cast(uint)ei)) continue;
            auto e = m.edges[ei];
            uint a = e[0], b = e[1];
            borderNbrs[a] ~= b;
            borderNbrs[b] ~= a;
        }

        uint[] bestCell;
        float  bestArea = float.infinity;

        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeBorder(cast(uint)ei)) continue;
            auto e = m.edges[ei];
            uint a = e[0], b = e[1];
            auto pnbrA = a in borderNbrs;
            auto pnbrB = b in borderNbrs;
            if (pnbrA is null || pnbrB is null) continue;

            foreach (ap; *pnbrA) {
                if (ap == b) continue;
                foreach (bp; *pnbrB) {
                    if (bp == a) continue;
                    // Must be 4 DISTINCT verts (a != b already, both are a
                    // real edge's endpoints; ap != a/b and bp != a/b are
                    // guaranteed by the neighbour-map/skip above — only
                    // ap == bp remains to check).
                    if (ap == bp) continue;

                    ImVec2 p0, p1, p2, p3;
                    if (!projectPt(m.vertices[ap], vp, p0)) continue;
                    if (!projectPt(m.vertices[a],  vp, p1)) continue;
                    if (!projectPt(m.vertices[b],  vp, p2)) continue;
                    if (!projectPt(m.vertices[bp], vp, p3)) continue;

                    float[4] xs = [p0.x, p1.x, p2.x, p3.x];
                    float[4] ys = [p0.y, p1.y, p2.y, p3.y];
                    if (!pointInPolygon2D(cast(float)mx, cast(float)my, xs[], ys[])) continue;

                    // Shoelace area (screen space, sign-agnostic — the
                    // candidate's own winding is not yet known/relevant).
                    float area2 = 0.0f;
                    foreach (k; 0 .. 4)
                        area2 += xs[k] * ys[(k + 1) % 4] - xs[(k + 1) % 4] * ys[k];
                    float area = area2 < 0 ? -area2 * 0.5f : area2 * 0.5f;

                    if (area < bestArea) {
                        bestArea = area;
                        bestCell = [ap, a, b, bp];
                    }
                }
            }
        }
        return bestCell;
    }

    // Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md):
    // `bindings()`/`onInputResetAll()` are now the LIVE dispatch table/reset
    // hook — `onMouseButtonDown`/`onMouseButtonUp` below route every press
    // through the base's `dispatchInput()` state machine instead of the
    // (now deleted) `GestureSlot`/`resolveGestureSlot` switch.
    override const(InputBinding)[] bindings() const { return kTopoPenBindings; }

    // The `ResetScope.AllButtons` hook: fires before every LEFT-button
    // gesture-DOWN handler (each LEFT row in `kTopoPenBindings` is
    // `ResetScope.AllButtons`). Phase-3 dispatch cleanup
    // (doc/topopen_input_dispatch_phase2_plan.md §Phase 3) removed the now-redundant
    // duplicate `resetAllGestureArms()` call the LEFT-button trio's own
    // handlers used to make at their own top — this hook is the sole path
    // that fires it on a LEFT Down now.
    override void onInputResetAll() { resetAllGestureArms(); }

    // Dispatch entry point: `dispatchInput` resolves (button, live modifier
    // mask) via `kTopoPenBindings`, arms the resolved action on THIS button,
    // and calls `onToolAction(a, Down, ...)` — which routes to the same
    // `on*Down` method `resolveGestureSlot`'s old `final switch` used to call
    // directly. The 2 undocumented slots (Ctrl+RMB, Shift+Ctrl+MMB) and every
    // Alt combo are simply ABSENT from `kTopoPenBindings`, so
    // `resolveToolAction` answers `PassThrough` and `dispatchInput` returns
    // `false` without ever calling `onToolAction` — byte-identical to the old
    // switch's `CtrlRmb`/`ShiftCtrlMmb`/`None` cases.
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts) {
        return dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
                             InputPhase.Down, e, vts);
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
        // P10 Move Loop (doc/topopen_p10_moveloop_plan.md) — cleared here so
        // the LEFT-button trio's own reset (and `resyncSession`, below) close
        // a stray move-loop arm too; `onMoveLoopRmbDown` (the RIGHT-button
        // handler) does NOT call this helper (same RMB/MMB-button discipline
        // as `onShiftMmbDown`/`onPlainMmbDown` above — a RIGHT-button press
        // genuinely CAN be a two-button chord while a LEFT gesture is still
        // held) and uses its own narrow self-reset instead. `loopBgBvh_` is a
        // CACHE, not arm state, so it is deliberately left intact here.
        moveLoopArmed_ = false;
        moveLoopSeed_  = -1;
        moveLoopVerts_ = null;
        // P11 Dup Loop (doc/topopen_p11_duploop_plan.md) — cleared here so
        // the LEFT-button trio's own reset (and `resyncSession()`, below)
        // close a stray dup-loop arm too; `onDupLoopShiftRmbDown` (the
        // Shift+RMB handler) does NOT call this helper (same RMB-button
        // discipline as `onMoveLoopRmbDown` above — a RIGHT-button press
        // genuinely CAN be a two-button chord while a LEFT gesture is still
        // held) and uses its own narrow self-reset instead.
        dupLoopArmed_ = false;
        dupLoopSeed_  = -1;
        dupLoopEdges_ = null;
        // P12 Smooth+Loop (doc/topopen_p12_smoothloop_plan.md) — cleared
        // here so the LEFT-button trio's own reset (and `resyncSession()`,
        // below) close a stray smooth-loop arm too; `onSmoothLoopRmbDown`
        // (the Shift+Ctrl+RMB handler) does NOT call this helper (same
        // RMB-button discipline as `onMoveLoopRmbDown`/
        // `onDupLoopShiftRmbDown` above) and uses its own narrow self-reset
        // instead.
        smoothLoopArmed_  = false;
        smoothLoopSeed_   = -1;
        smoothLoopVerts_  = null;
        smoothLoopDragPx_ = 0.0f;
    }

    // MINOR-3 (doc/topopen_hover_highlight_plan.md REV1): the single source
    // of truth for "is ANY gesture currently armed" — the OR of every arm
    // flag `resetAllGestureArms()` (immediately above) clears. The two
    // helpers travel together: `resetAllGestureArms()` is the authoritative
    // list of arm FIELDS to clear on a fresh press/history-nav, and this is
    // the authoritative list of arm FIELDS to test for "something is
    // in-progress" (currently gating the Generic Hover-Highlight indicator,
    // `onMouseMotion`/`draw()` below). As of this writing the list is the 9
    // flags: `dragArmed_` (P3 build) / `placeArmed_` + `moveArmed_` (P4
    // Move-Place) / `addLoopArmed_` (P6) / `slideArmed_` (P7) /
    // `smoothArmed_` (P8) / `splitArmed_` (P9) / `moveLoopArmed_` (P10) /
    // `dupLoopArmed_` (P11).
    // MAINTENANCE CONTRACT: every NEW gesture's arm flag MUST be OR'd in
    // HERE too, in addition to being cleared in `resetAllGestureArms()` —
    // a flag added to one list but not the other silently breaks either
    // the reset hazard that helper closes, or (if omitted here) lets a
    // gesture stay "invisible" to this predicate (e.g. the hover indicator
    // would then incorrectly draw ON TOP OF that gesture's own ghost). The
    // Tier-A pin immediately below this method's unittest guards against a
    // bad merge silently dropping a flag from this OR. As of P12
    // (doc/topopen_p12_smoothloop_plan.md) the list is the 10 flags:
    // `dragArmed_` (P3 build) / `placeArmed_` + `moveArmed_` (P4 Move-Place)
    // / `addLoopArmed_` (P6) / `slideArmed_` (P7) / `smoothArmed_` (P8) /
    // `splitArmed_` (P9) / `moveLoopArmed_` (P10) / `dupLoopArmed_` (P11) /
    // `smoothLoopArmed_` (P12).
    private bool anyGestureArmed() const {
        return dragArmed_ || placeArmed_ || moveArmed_ || addLoopArmed_
            || slideArmed_ || smoothArmed_ || splitArmed_ || moveLoopArmed_
            || dupLoopArmed_ || smoothLoopArmed_;
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
        // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3):
        // the full symmetric close this handler used to do itself here is now
        // guaranteed by `dispatchInput`'s `onInputResetAll()` hook — this
        // row's `ResetScope.AllButtons` (`kTopoPenBindings`) fires
        // `resetAllGestureArms()` unconditionally BEFORE this handler is
        // called. See `resetAllGestureArms`'s own doc comment for the full
        // hazard this closes.

        // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md
        // Phase 4): the Mode dropdown reroutes plain-LMB entirely — Fill
        // OWNS this slot and NEVER falls through to place/move below.
        // Commit-on-DOWN (like Remove, `:2339`-ish): the cell is fully
        // determined by the DOWN pixel, there is no drag to defer. A miss
        // (cursor over a solid face / empty area / no gap cell under it)
        // is a clean no-op — still consumed, so Draw's place/move can
        // never fire underneath an active Fill-mode click. No arm bool,
        // no `resyncSession`/`resetAllGestureArms` entry needed — Fill is
        // a click op, like Remove.
        if (penMode_ == PenMode.Fill) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            auto cell = findFillCell(e.x, e.y, vp);
            if (cell.length == 4) commitFill(cell);
            return true;
        }

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
        // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3,
        // same rationale as `onPlainLmbDown` above): this row's
        // `ResetScope.AllButtons` already fires `resetAllGestureArms()` via
        // `dispatchInput`'s `onInputResetAll()` hook before this handler runs.

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
    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 1
    // item 4): `thresholdPx` defaults to `kTopoPenSnapPx`, same rationale as
    // `findSourceVertex` above — every existing gesture caller stays
    // byte-identical (none pass a 3rd argument); the hover path passes
    // `float.infinity` for RESOLUTION and a finite value for the GATE.
    private int findRingSeedEdge(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapPx) {
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
        if (best >= 0 && bestD <= thresholdPx) return best;
        return -1;
    }

    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 2):
    // the pure, GL-free resolution of the always-on "what's under the
    // cursor" indicator — resolves the nearest primary VERTEX and nearest
    // primary EDGE simultaneously (Pinned Decision 2: the spec draws both a
    // vertex marker AND an edge line at once, never one-or-the-other), plus
    // the boundary-edge/hatch-face state. Deliberately separate from the
    // over-mesh GATE (`onMouseMotion`, below) — this method resolves
    // ELEMENTS only (projection math, no BVH/GL), so it stays pure and
    // fully unit-testable (U1-U7). `∞` threshold on both scans: "under the
    // cursor" here means "screen-nearest", not "within N px" — the gate
    // decides WHETHER to show it, this method decides WHAT to show.
    private void computeHoverIndicator(int mx, int my, const ref Viewport vp) {
        hoverNearestVert_  = findSourceVertex(mx, my, vp, float.infinity);
        hoverNearestEdge_  = findRingSeedEdge(mx, my, vp, float.infinity);
        hoverBoundary_     = false;
        hoverBoundaryFace_ = -1;
        if (hoverNearestEdge_ >= 0) {
            auto m = mesh;
            if (m !is null && hoverNearestEdge_ < cast(int)m.edges.length) {
                // MINOR-4: `isEdgeBorder` is `n == 1` EXACTLY (one incident
                // face) — a 0-face bare edge returns false (nothing to
                // hatch there, correctly).
                if (m.isEdgeBorder(cast(uint)hoverNearestEdge_)) {
                    hoverBoundary_ = true;
                    foreach (fi; m.facesAroundEdge(cast(uint)hoverNearestEdge_)) {
                        hoverBoundaryFace_ = cast(int)fi;
                        break;   // exactly one incident face by definition
                    }
                }
            }
        }
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
        // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3):
        // this row's `ResetScope.AllButtons` already fires
        // `resetAllGestureArms()` via `dispatchInput`'s `onInputResetAll()`
        // hook before this handler runs. See `resetAllGestureArms`'s own doc
        // comment for the full hazard this closes.

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

    // P10 (doc/topopen_p10_moveloop_plan.md, REV1 FIX-1 — the KILLER fix):
    // the moving-set for a Move Loop gesture is the SORTED-UNIQUE union of
    // endpoint vertices of `Mesh.selectLoopEdges(seedEdge)` — the classic
    // IN-LINE edge-loop CHAIN (mesh.d:13857, ported bit-exact against 11
    // reference `select.loop` cases) — NOT `loopSliceRingEdges`/
    // `collectEdgeRing` (the PERPENDICULAR ring a stack of parallel edges,
    // used by Add Loop/Slide above for an unrelated purpose: seeding a
    // loop-CUT ring, not gathering a loop to DRAG). Handles both an interior
    // seed (closed OR open in-line chain, depending on where it dead-ends)
    // and a boundary seed (`selectLoopBorderChain` — chains along the open
    // perimeter, closing if the boundary loop itself closes) — both branches
    // already live inside `selectLoopEdges` itself; this helper only turns
    // the returned edge-index list into a deduplicated, order-independent
    // vertex set. `sort` gives a deterministic, reproducible ordering for
    // tests (not a topological requirement — `commitMoveLoop` writes every
    // entry regardless of order).
    private static uint[] uniqueRingVerts(Mesh* m, uint seedEdge) {
        import std.algorithm : sort;

        bool[uint] seen;
        uint[] verts;
        foreach (ei; m.selectLoopEdges(seedEdge)) {
            if (ei < 0 || ei >= cast(int)m.edges.length) continue;   // defensive
            auto ep = m.edges[cast(uint)ei];
            foreach (v; ep) {
                if (v in seen) continue;
                seen[v] = true;
                verts ~= v;
            }
        }
        sort(verts);
        return verts;
    }

    // P10 (doc/topopen_p10_moveloop_plan.md), on the plain RMB "Move Loop"
    // slot: a press picks the nearest primary-layer EDGE
    // (`findRingSeedEdge`, reused verbatim from P6/P7) and gathers its
    // in-line edge loop (`uniqueRingVerts`, REV1 FIX-1); if no edge is
    // within snap range, or the gathered moving-set is somehow empty
    // (defensive — `selectLoopEdges` never returns an empty list for a
    // valid seed index), this is not a documented gesture — don't consume,
    // matching every other down-handler's miss convention (RMB-lasso then
    // proceeds unchanged, task-0288 "tool first crack at RMB" precedent).
    //
    // REV1 FIX-1 discipline (RMB/MMB-button symmetry, see
    // `resetAllGestureArms`'s own doc comment): this handler does ONLY its
    // own narrow self-reset — `resetAllGestureArms()` is DELIBERATELY NOT
    // called here — because a RIGHT-button press can legitimately be a
    // two-button chord while a LEFT-button gesture (Build/Move/Slide/
    // Smooth) is still held; an unconditional full reset here would
    // silently cancel that in-progress drag before the user's eventual LEFT
    // release commits it. A same-button RMB re-press is guarded by this
    // handler's own top-of-function reset, exactly like Add Loop's/Split's.
    private bool onMoveLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        moveLoopArmed_ = false;
        moveLoopSeed_  = -1;
        moveLoopVerts_ = null;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int seed = findRingSeedEdge(e.x, e.y, vp);
        if (seed < 0) return false;   // no edge under the cursor -> no documented gesture

        auto m = mesh;
        if (m is null) return false;
        auto verts = uniqueRingVerts(m, cast(uint)seed);
        if (verts.length == 0) return false;   // defensive; shouldn't happen for a valid seed

        moveLoopSeed_   = seed;
        moveLoopVerts_  = verts;
        moveLoopStartX_ = e.x;
        moveLoopStartY_ = e.y;
        moveLoopCurX_   = e.x;
        moveLoopCurY_   = e.y;
        moveLoopArmed_  = true;
        return true;   // consume; the loop drag (if any) commits on release
    }

    // P11 (doc/topopen_p11_duploop_plan.md), on the Shift+RMB "Duplicate
    // Loop" slot: a press picks the nearest primary-layer EDGE
    // (`findRingSeedEdge`, reused verbatim from P6/P7/P10) and gathers its
    // edge loop (`Mesh.selectLoopEdges`, the SAME kernel P10's
    // `uniqueRingVerts` calls) — but unlike P10, this stores the raw EDGE
    // INDICES (`dupLoopEdges_`), not the unique vertex set: the commit
    // needs the edge list to build `extendEdgesByMask`'s mask.
    //
    // REV1 FIX-1 (label correction): a BOUNDARY seed resolves to
    // `selectLoopBorderChain` — the FULL CLOSED perimeter (the
    // owner-observed "весь loop" case: a side/boundary edge duplicates the
    // WHOLE closed rim) — and is the shipped-faithful, MEASURED case. An
    // INTERIOR seed resolves to the classic quad-opposite walk — an OPEN
    // chain that dead-ends at the mesh boundary — which `extendEdgesByMask`
    // turns non-manifold (each source edge 2→3 adjacent faces, a documented
    // v1 kernel degrade, mesh.d:5659-5663); the owner did NOT capture this
    // case, so V1 ships the kernel's existing behavior UNMEASURED/FLAGGED
    // (plan §Open-item IL) rather than block or invent a split-the-mesh
    // alternative.
    //
    // If no edge is within snap range, or the gathered loop is somehow
    // empty (defensive — `selectLoopEdges` never returns an empty list for
    // a valid seed index), this is not a documented gesture — don't
    // consume, matching every other down-handler's miss convention
    // (Shift+RMB-lasso proceeds unchanged, Shift being the lasso's own
    // additive modifier).
    //
    // RMB-button discipline (mirrors `onMoveLoopRmbDown`'s own doc
    // comment): this handler does ONLY its own narrow self-reset (clear
    // the three dup-loop fields at the top) — `resetAllGestureArms()` is
    // DELIBERATELY NOT called here, because a RIGHT-button press can
    // legitimately be a two-button chord while a LEFT-button gesture
    // (Build/Move/Slide/Smooth) is still held; an unconditional full reset
    // here would silently cancel that in-progress drag before the user's
    // eventual LEFT release commits it. A same-slot Shift+RMB re-press is
    // guarded by this handler's own top-of-function reset, exactly like
    // Move Loop's/Add Loop's/Split's.
    private bool onDupLoopShiftRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        dupLoopArmed_ = false;
        dupLoopSeed_  = -1;
        dupLoopEdges_ = null;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int seed = findRingSeedEdge(e.x, e.y, vp);
        if (seed < 0) return false;   // no edge under the cursor -> no documented gesture

        auto m = mesh;
        if (m is null) return false;
        auto edges = m.selectLoopEdges(cast(uint)seed);
        if (edges.length == 0) return false;   // defensive; shouldn't happen for a valid seed

        dupLoopSeed_    = seed;
        dupLoopEdges_   = edges;
        dupLoopStartX_  = e.x;
        dupLoopStartY_  = e.y;
        dupLoopCurX_    = e.x;
        dupLoopCurY_    = e.y;
        dupLoopArmed_   = true;
        return true;   // consume; the extrude+drag (if any) commits on release
    }

    // P12 (doc/topopen_p12_smoothloop_plan.md), on the Shift+Ctrl+RMB
    // "Smoothing + Edge Loop" slot: a press picks the nearest primary-layer
    // EDGE (`findRingSeedEdge`, reused verbatim from P6/P7/P10/P11) and
    // gathers its in-line edge loop (`uniqueRingVerts`, the SAME
    // sorted-unique moving-set gather P10 Move Loop uses) into
    // `smoothLoopVerts_` — REV1 FIX-2: this DOWN-time cache is reused
    // VERBATIM at commit (`applySmoothLoopPasses`), never re-gathered, since
    // the mesh is never mutated between arm and commit. If no edge is within
    // snap range, or the gathered moving-set is somehow empty (defensive —
    // `selectLoopEdges` never returns an empty list for a valid seed index),
    // this is not a documented gesture — don't consume, matching every other
    // down-handler's miss convention (Shift+Ctrl+RMB-lasso then proceeds
    // unchanged).
    //
    // RMB-button discipline (mirrors `onMoveLoopRmbDown`'s/
    // `onDupLoopShiftRmbDown`'s own doc comment): this handler does ONLY its
    // own narrow self-reset — `resetAllGestureArms()` is DELIBERATELY NOT
    // called here — because a RIGHT-button press can legitimately be a
    // two-button chord while a LEFT-button gesture (Build/Move/Slide/Smooth)
    // is still held; an unconditional full reset here would silently cancel
    // that in-progress drag before the user's eventual LEFT release commits
    // it. A same-slot Shift+Ctrl+RMB re-press is guarded by this handler's
    // own top-of-function reset, exactly like Move Loop's/Dup Loop's.
    private bool onSmoothLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        smoothLoopArmed_ = false;
        smoothLoopSeed_  = -1;
        smoothLoopVerts_ = null;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int seed = findRingSeedEdge(e.x, e.y, vp);
        if (seed < 0) return false;   // no edge under the cursor -> no documented gesture

        auto m = mesh;
        if (m is null) return false;
        auto verts = uniqueRingVerts(m, cast(uint)seed);
        if (verts.length == 0) return false;   // defensive; shouldn't happen for a valid seed

        smoothLoopSeed_   = seed;
        smoothLoopVerts_  = verts;
        smoothLoopStartX_ = e.x;
        smoothLoopStartY_ = e.y;
        smoothLoopCurX_   = e.x;
        smoothLoopCurY_   = e.y;
        smoothLoopDragPx_ = 0.0f;
        smoothLoopArmed_  = true;
        return true;   // consume; the relax+re-snap (if any) commits on release
    }

    // P10 (doc/topopen_p10_moveloop_plan.md, plan §Re-snap): multi-background
    // camera-ray re-snap at an ARBITRARY (shifted) pixel — the SAME
    // primitive P4 Move's re-snap ultimately rests on (`BvhPick.pickSurface`,
    // `bvh_pick.d:196`), scanned over every live background source and kept
    // at the globally-nearest hit, mirroring CONS's own `bgSurfaceRayHit`
    // scan (`constrain.d:159-192`) — a low-touch, TOOL-LOCAL port (plan
    // §Phase 2 alternative (2)) rather than extracting a shared
    // `constraint.d` helper, since MOVE-LOOP is the only caller that needs
    // the scan at a pixel other than the live cursor (CONS's own Point/
    // Screen-mode call sites are left untouched). `loopBgBvh_` is this
    // tool's OWN per-background-mesh cache (mirrors P5's `removePick_`),
    // pruned here exactly like CONS prunes `_bgBvh` so a removed/hidden
    // background layer's BVH is freed. Driven ONLY from the main thread
    // (onMouseMotion/onMouseButtonUp/draw), so no `cursorValid` gate is
    // needed (plan Risk 3). Returns false (leaving `outPoint` untouched)
    // when the ray misses every background source, or none exists.
    private bool resnapToBackground(int px, int py, const ref Viewport vp, out Vec3 outPoint) {
        auto sources = backgroundSourcesSnapshot();
        if (sources.length == 0) return false;

        bool[size_t] live;
        foreach (src; sources)
            if (src !is null) live[cast(size_t)src] = true;
        size_t[] stale;
        foreach (addr, bp; loopBgBvh_)
            if ((addr in live) is null) stale ~= addr;
        foreach (addr; stale) loopBgBvh_.remove(addr);

        float bestT = float.infinity;
        bool  found = false;
        Vec3  bestPt;
        foreach (src; sources) {
            if (src is null) continue;
            size_t addr = cast(size_t)src;
            auto pp = addr in loopBgBvh_;
            BvhPick bp;
            if (pp is null) { bp = new BvhPick(); loopBgBvh_[addr] = bp; }
            else bp = *pp;
            SurfaceHit sh;
            if (!bp.pickSurface(px, py, vp, *src, sh)) continue;
            if (sh.t >= bestT) continue;
            bestT  = sh.t;
            bestPt = sh.point;
            found  = true;
        }
        if (found) outPoint = bestPt;
        return found;
    }

    // P10 (doc/topopen_p10_moveloop_plan.md "The pinned drag-mapping"): the
    // per-vertex re-snap targets for a shared SCREEN-space drag delta
    // `(dx, dy)` — project each moving vertex's CURRENT (pre-commit)
    // position, shift by the shared delta, and re-snap
    // (`resnapToBackground`). A vertex that projects behind the camera, or
    // whose shifted pixel misses every background surface, KEEPS its
    // original position (the safe, no-fling miss policy — plan
    // "Miss policy"; also the contract FIX-2's partial-miss test pins at
    // the `commitMoveLoop` layer). Returns one target per entry of `verts`,
    // same order — `verts.length == 0`/`m is null` yields an empty array
    // (defensive; callers already guard this).
    private Vec3[] perVertexTargets(const(uint)[] verts, int dx, int dy,
                                    const ref Viewport vp) {
        Vec3[] targets;
        auto m = mesh;
        if (m is null) return targets;
        targets.length = verts.length;
        foreach (i, vi; verts) {
            Vec3 orig = (vi < m.vertices.length) ? m.vertices[vi] : Vec3(0, 0, 0);
            targets[i] = orig;   // default: miss (or out-of-range) keeps the original
            if (vi >= m.vertices.length) continue;

            ImVec2 pt;
            if (!projectPt(orig, vp, pt)) continue;   // behind camera -> keep original

            int px = cast(int)(pt.x + cast(float)dx);
            int py = cast(int)(pt.y + cast(float)dy);
            Vec3 hitPt;
            if (resnapToBackground(px, py, vp, hitPt)) targets[i] = hitPt;
        }
        return targets;
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 3), on the Shift+Ctrl+LMB
    // "Smooth" slot: arms a whole-primary-mesh relax+re-snap gesture — NO
    // source-vertex/edge pick (unlike every other gesture above, this one
    // is scope-free: it relaxes the ENTIRE primary mesh, not a
    // press-selected element) and NO mutation on down. Commit is deferred
    // to release (`onMouseButtonUp`'s Smooth branch, `applySmoothPasses`),
    // reading the accumulated drag distance to derive the pass count.
    // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3):
    // the full symmetric close (same LEFT-button discipline as
    // `onPlainLmbDown`/`onShiftLmbDown`/`onCtrlLmbDown`) is now guaranteed by
    // this row's `ResetScope.AllButtons`, which fires `resetAllGestureArms()`
    // via `dispatchInput`'s `onInputResetAll()` hook before this handler
    // runs, so a stray Move/Build/Slide arm from an earlier press can never
    // survive into this one. Always claims the event (Shift+Ctrl+LMB is
    // unambiguously the Smooth gesture, regardless of what — if anything —
    // is under the cursor).
    private bool onShiftCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        smoothArmed_  = true;
        smoothStartX_ = smoothLastX_ = e.x;
        smoothStartY_ = smoothLastY_ = e.y;
        smoothDragPx_ = 0.0f;
        return true;
    }

    // Dispatch entry point: `dispatchInput` reads back the SAME action id it
    // armed on THIS button's Down (never re-derived from arm-bool priority)
    // and calls `onToolAction(a, Up, ...)`, which routes to the matching
    // `<mode>Up` helper below — the same bodies this method used to call
    // inline, per-button-branch, before the Phase-2 flip.
    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts) {
        return dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
                             InputPhase.Up, e, vts);
    }

    // --- Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md):
    // the 9 extracted UP-branch bodies below (Remove has no arm bool and no
    // UP body — it commits on DOWN) — each is BOTH the body `onMouseButtonUp`
    // above calls AND the body `onToolAction`'s UP cases will call once
    // Phase 2 flips the seam, so there is exactly one copy of this logic.
    // Each guards on its OWN arm bool first (`if (!xArmed_) return false;`) —
    // this is what makes each helper safely callable directly from
    // `onToolAction` even on a Down-that-resolved-but-declined (the
    // arm-before-decline gap the plan's own "Key decision" section documents):
    // the base's `armed_[button]` may say "armed", but the bool says
    // otherwise, and the bool is what every helper actually trusts.

    // P4 Place/Move (doc/topopen_p4_plan.md, Design A): both outcomes of a
    // plain-LMB press commit HERE, never at DOWN — see `onPlainLmbDown`'s own
    // doc comment for the disambiguation.
    private bool lmbPlaceOrMoveUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (placeArmed_) {
            placeArmed_ = false;
            readHit(vts);   // refresh lastHit_ to THIS release event's CONS-snapped hit
            if (lastHit_.hit) placeVertexAt(lastHit_.point, vts);
            return true;
        }
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

    // P3: commits the armed drag-build, if any, at the RELEASE event's own
    // CONS-snapped hit. A release with no real motion since press (a
    // stationary click-on-vertex — "revisit = Move/no-op", capture SESSION 1)
    // builds nothing.
    private bool buildUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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

    // P7 (doc/topopen_p7_slide_plan.md Phase 3): commits the armed Slide
    // gesture at the RELEASE event's own cursor-derived per-rail fraction.
    private bool slideUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!slideArmed_) return false;
        uint seed   = cast(uint)slideSeed_;
        int  eA     = slideEndA_, eB = slideEndB_;
        int  nA     = slideNbrA_, nB = slideNbrB_;
        int  startX = slideStartX_, startY = slideStartY_;

        slideSeed_  = -1;
        slideArmed_ = false;
        slideEndA_ = slideEndB_ = -1;
        slideNbrA_ = slideNbrB_ = -1;

        // REV1 FIX-2 (doc/topopen_p7_slide_plan.md): a release back at (near
        // enough) the press pixel is a click without a real drag — an
        // explicit, clean no-op (no vertex write, no undo entry), mirroring
        // P3's own `kMinDragPx` guard.
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

    // P8 (doc/topopen_p8_smooth_plan.md Phase 3): commits the armed Smooth
    // gesture — click (zero/near-zero drag) applies exactly ONE pass, a drag
    // applies N (derived from the accumulated cursor travel). Risk 5 (plan):
    // UNLIKE every other gesture, this one is NOT gated by `kMinDragPx` — a
    // stationary click must still apply its one pass (`applySmoothPasses`
    // itself carries the REV1 FIX-2 no-op-undo guard for the case where that
    // one pass genuinely changes nothing).
    private bool smoothUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!smoothArmed_) return false;
        smoothArmed_ = false;
        int n = 1 + cast(int)(smoothDragPx_ / kSmoothPassStridePx);
        applySmoothPasses(n);
        return true;
    }

    // P9 (doc/topopen_p9_split_plan.md REV1 FIX-2) + Mid-edge Split
    // (doc/topopen_midedge_split_plan.md Phase 3): commits the armed Split
    // gesture. C is resolved AT THE RELEASE PIXEL — authoritative, never the
    // last-motion `splitTargetVert_` (a release with no intervening motion
    // event must still resolve C at its own pixel).
    //
    // `c < 0` (no vertex under the cursor, within `kTopoPenSnapPx`) is now
    // resolved a SECOND way before falling back to a no-op: the nearest
    // primary-layer EDGE under the release pixel (`findRingSeedEdge`, same
    // threshold). Vertex-first precedence is free and correct here — a
    // release NEAR a corner already resolved to that vertex above (the
    // vertex↔vertex path, UNCHANGED), so only a genuinely mid-span release
    // reaches the edge branch. On an edge hit, the insert fraction `f` is
    // either the sticky `splitAtMiddle_` option's fixed 0.5, or the click's
    // own `ratioOnSegment` projection against `edges[E][0]->[1]` (MUST stay
    // in that direction — `addEdgePoint`'s own `t` convention measures from
    // `edges[ei][0]` toward `[1]`; swapping the endpoints here would land
    // the inserted vertex near the WRONG end of the edge, the same
    // direction hazard `seedRail`'s own doc comment warns about for Add
    // Loop). A release on neither a vertex nor an edge (empty space) stays
    // the original clean no-op.
    private bool splitUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!splitArmed_) return false;
        int a = splitSourceVert_;
        splitArmed_      = false;
        splitSourceVert_ = -1;
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int c = findSourceVertex(e.x, e.y, vp);
        splitTargetVert_ = -1;
        if (c >= 0) {
            commitSplit(a, c);
        } else {
            int E = findRingSeedEdge(e.x, e.y, vp);
            if (E >= 0) {
                auto m = mesh;
                if (m !is null && E < cast(int)m.edges.length) {
                    float f = splitAtMiddle_ ? 0.5f
                            : ratioOnSegment(e.x, e.y, vp,
                                m.vertices[m.edges[E][0]], m.vertices[m.edges[E][1]]);
                    commitSplitOnEdge(a, E, f);
                }
            }
            // else: release on empty space -> clean no-op, unchanged.
        }
        return true;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 3): commits the armed Add Loop
    // gesture, at the RELEASE event's own cursor-derived ratio.
    private bool addLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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

    // P10 (doc/topopen_p10_moveloop_plan.md Phase 3): commits the armed Move
    // Loop gesture at the RELEASE event's own pixel. A release back at (near
    // enough) the press pixel is a click without a real drag — an explicit,
    // clean no-op (no vertex write, no undo entry, no `perVertexTargets`/
    // re-snap work at all), mirroring P3/P7's own `kMinDragPx` guard.
    private bool moveLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!moveLoopArmed_) return false;
        auto verts = moveLoopVerts_;
        int  sx = moveLoopStartX_, sy = moveLoopStartY_;
        moveLoopArmed_ = false;
        moveLoopVerts_ = null;
        moveLoopSeed_  = -1;

        enum int kMinDragPx = 3;   // mirrors P3/P7's own click-vs-drag gate
        int dx = e.x - sx, dy = e.y - sy;
        if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return true;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        commitMoveLoop(verts, perVertexTargets(verts, dx, dy, vp));
        return true;
    }

    // P11 (doc/topopen_p11_duploop_plan.md Phase 3): commits the armed Dup
    // Loop gesture at the RELEASE event's own screen delta. A release back
    // at (near enough) the press pixel is a click without a real drag — an
    // explicit, clean no-op (no extrude, no undo entry), mirroring every
    // other gesture's `kMinDragPx` guard.
    private bool dupLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!dupLoopArmed_) return false;
        auto edges = dupLoopEdges_;
        int  sx = dupLoopStartX_, sy = dupLoopStartY_;
        dupLoopArmed_ = false;
        dupLoopEdges_ = null;
        dupLoopSeed_  = -1;

        enum int kMinDragPx = 3;   // mirrors every other gesture's click-vs-drag gate
        int dx = e.x - sx, dy = e.y - sy;
        if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return true;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        commitDupLoop(edges, dx, dy, vp);
        return true;
    }

    // P12 (doc/topopen_p12_smoothloop_plan.md Phase 3): commits the armed
    // Smooth+Loop gesture — UNLIKE Move Loop/Dup Loop, this is NOT gated by
    // `kMinDragPx` (a stationary click must still apply its one pass,
    // mirroring the whole-mesh Smooth gesture's own Risk-5 discipline, P8).
    // Disarms BEFORE calling `applySmoothLoopPasses` (REV1 plan "Disarm
    // before commit"); `smoothLoopSeed_`/`smoothLoopVerts_` stay valid for
    // THAT call (it reads them directly, REV1 FIX-2 — no re-gather) and are
    // cleared immediately after.
    private bool smoothLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!smoothLoopArmed_) return false;
        smoothLoopArmed_ = false;
        int n = 1 + cast(int)(smoothLoopDragPx_ / kSmoothPassStridePx);
        applySmoothLoopPasses(n);
        smoothLoopSeed_   = -1;
        smoothLoopVerts_  = null;
        smoothLoopDragPx_ = 0.0f;
        return true;
    }

    // Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md):
    // delivers one resolved action at one phase — the LIVE seam
    // `onMouseButtonDown`/`onMouseButtonUp` above now route through
    // `dispatchInput()` to reach. DOWN cases delegate to the existing
    // `on*Down` methods (unchanged); UP cases delegate to the extracted
    // `<mode>Up` helpers above (the SAME bodies `onMouseButtonUp` used to
    // call inline pre-flip) — each already guards on its own arm bool, so a
    // Down that resolved-but-declined (the base arms `armed_[button]` BEFORE
    // `onToolAction(Down)` can decline — the "arm-before-decline gap") safely
    // no-ops here too: the bool, not `armed_[]`, is the "really armed" truth.
    // `Remove` has no UP body (it commits on DOWN, D2) and no arm bool, so
    // its UP case returns `false`, unconsumed — never add a `removeArmed_`
    // bool (it would wrongly suppress the hover indicator during a held
    // Ctrl+MMB). `Move` never arrives — this tool does not route
    // `onMouseMotion` through `dispatchInput` (Move-phase routing is
    // deferred, design §5); `onMouseMotion` keeps reading the arm bools
    // directly, unchanged.
    override bool onToolAction(ToolAction a, InputPhase p,
                               ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        final switch (cast(TopoPenAction) a) {
        case TopoPenAction.LmbPlaceOrMove:
            if (p == InputPhase.Down) return onPlainLmbDown(e, vts);
            if (p == InputPhase.Up)   return lmbPlaceOrMoveUp(e, vts);
            return false;
        case TopoPenAction.Build:
            if (p == InputPhase.Down) return onShiftLmbDown(e, vts);
            if (p == InputPhase.Up)   return buildUp(e, vts);
            return false;
        case TopoPenAction.Slide:
            if (p == InputPhase.Down) return onCtrlLmbDown(e, vts);
            if (p == InputPhase.Up)   return slideUp(e, vts);
            return false;
        case TopoPenAction.Smooth:
            if (p == InputPhase.Down) return onShiftCtrlLmbDown(e, vts);
            if (p == InputPhase.Up)   return smoothUp(e, vts);
            return false;
        case TopoPenAction.Split:
            if (p == InputPhase.Down) return onPlainMmbDown(e, vts);
            if (p == InputPhase.Up)   return splitUp(e, vts);
            return false;
        case TopoPenAction.AddLoop:
            if (p == InputPhase.Down) return onShiftMmbDown(e, vts);
            if (p == InputPhase.Up)   return addLoopUp(e, vts);
            return false;
        case TopoPenAction.Remove:
            if (p == InputPhase.Down) return onCtrlMmbDown(e, vts);
            return false;   // Up is a no-op — Remove commits on Down (D2)
        case TopoPenAction.MoveLoop:
            if (p == InputPhase.Down) return onMoveLoopRmbDown(e, vts);
            if (p == InputPhase.Up)   return moveLoopUp(e, vts);
            return false;
        case TopoPenAction.DupLoop:
            if (p == InputPhase.Down) return onDupLoopShiftRmbDown(e, vts);
            if (p == InputPhase.Up)   return dupLoopUp(e, vts);
            return false;
        case TopoPenAction.SmoothLoop:
            if (p == InputPhase.Down) return onSmoothLoopRmbDown(e, vts);
            if (p == InputPhase.Up)   return smoothLoopUp(e, vts);
            return false;
        }
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

    // MEASURED inverse-edge-length relax KERNEL (P12,
    // doc/topopen_p12_smoothloop_plan.md Phase 1 — extracted from P8's
    // `smoothedRelaxTarget`, below, so BOTH the whole-mesh Smooth gesture
    // and the 1-D Smooth+Loop gesture share the IDENTICAL measured law over
    // whatever neighbor SET the caller hands it): a closer neighbor pulls
    // harder —
    //   relaxTarget(v) = Σ_i (n_i / len_i) / Σ_i (1 / len_i)
    // where `len_i = |v − n_i|` at the caller-supplied `readPos` snapshot
    // (every vertex in a pass reads from the SAME snapshot, mirroring
    // `MeshSmooth`'s own prev/cur double-buffer, smooth.d:280-297) and
    // `nbrs` is whatever neighbor set the caller has already resolved
    // (`smoothedRelaxTarget`'s boundary-restricted full 1-ring, or
    // `applySmoothLoopPasses`'s 1-D loop-neighbor pair) — this function
    // itself has NO topology awareness beyond the list it's handed.
    // `kStrength = 1.0` (V1 fixed, full relax) is kept as an explicit blend
    // so a future capture can retune it without touching the weight law.
    // An empty `nbrs` returns `readPos[v]` UNCHANGED — a true no-op,
    // bit-identical (no arithmetic performed), `hadNeighbors` left at its
    // `out`-default `false`. Preserves the ORIGINAL `1e-6` div-by-zero
    // floor and float summation order (iterating `nbrs` in the caller's
    // given order) bit-for-bit — a pure extraction, not a rewrite.
    private static Vec3 inverseEdgeLenRelax(const(Vec3)[] readPos, uint v,
                                            const(uint)[] nbrs, out bool hadNeighbors) {
        if (nbrs.length == 0) return readPos[v];

        Vec3  weightedSum = Vec3(0, 0, 0);
        float weightSum   = 0.0f;
        foreach (nb; nbrs) {
            float len = (readPos[v] - readPos[nb]).length;
            float w   = 1.0f / ((len > 1e-6f) ? len : 1e-6f);
            weightedSum = weightedSum + readPos[nb] * w;
            weightSum  += w;
        }

        hadNeighbors = true;
        Vec3 mean = weightedSum * (1.0f / weightSum);
        enum float kStrength = 1.0f;   // V1 fixed (full relax)
        return readPos[v] + (mean - readPos[v]) * kStrength;
    }

    // PLUGGABLE relax target — the pre-re-snap smoothed position of vertex
    // `v` (P8, doc/topopen_p8_smooth_plan.md "The MEASURED weight"). Reads
    // `v`'s neighbors from `m.vertexAdjacencyCSR` — the EXACT same CSR
    // adjacency the shipped Laplacian smooth averages over
    // (`commands/mesh/smooth.d`) — so this gesture's neighbor SET can never
    // drift from that command's.
    //
    // MEASURED (task 0477 P8 capture, 3 independent boots, 14/16 verts —
    // 87.5%): INVERSE EDGE-LENGTH weighting — NOT a uniform centroid (the
    // shared law lives in `inverseEdgeLenRelax` above, P12 extraction);
    // this function's OWN job is resolving WHICH neighbors feed it —
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

        // P12 (Phase 1 extraction): build the boundary-restricted 1-ring
        // list when needed, then delegate the actual weighting to the
        // shared kernel — the SAME one `applySmoothLoopPasses`'s 1-D loop
        // relax calls with a different (loop-neighbor) list.
        const(uint)[] relaxNbrs = nbrs;
        uint[] restricted;
        if (boundary) {
            foreach (nb; nbrs) {
                uint ei = m.edgeIndex(v, nb);
                if (ei != uint.max && isOpenEdge(m, ei)) restricted ~= nb;
            }
            relaxNbrs = restricted;
        }
        if (relaxNbrs.length == 0) return readPos[v];   // defensive; should not occur (see doc comment above)

        return inverseEdgeLenRelax(readPos, v, relaxNbrs, hadNeighbors);
    }

    // 1-D LOOP-neighbor connectivity (P12,
    // doc/topopen_p12_smoothloop_plan.md Phase 1): each vertex touched by
    // `m.selectLoopEdges(seed)` maps to its ≤2 IN-LOOP neighbors (built
    // purely from the loop's OWN edge list — no CSR / full 1-ring is read
    // anywhere here), which is exactly what enforces the "1-D along the
    // loop, not the full 2-D 1-ring" contract: for each loop edge `[a,b]`,
    // `b` is appended to `a`'s list and `a` to `b`'s. A closed interior loop
    // vertex ends up with 2 neighbors; an open-chain END vertex, 1 (F1,
    // held fixed at the caller — see `applySmoothLoopPasses`'s own doc
    // comment for the `!= 2` guard, REV1 FIX-3). `ei` bounds are guarded
    // exactly like `uniqueRingVerts` above (defensive — a valid seed should
    // never yield an out-of-range edge index).
    private static uint[][uint] loopNeighborsOf(Mesh* m, uint seed) {
        uint[][uint] nbrs;
        foreach (ei; m.selectLoopEdges(seed)) {
            if (ei < 0 || ei >= cast(int)m.edges.length) continue;   // defensive
            auto ep = m.edges[cast(uint)ei];
            nbrs[ep[0]] ~= ep[1];
            nbrs[ep[1]] ~= ep[0];
        }
        return nbrs;
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

    // P12 (doc/topopen_p12_smoothloop_plan.md Phase 3): commit `passCount`
    // passes of 1-D LOOP relax + re-snap over ONLY the armed loop's
    // vertices — modeled on `applySmoothPasses` above (same clamp/Jacobi/
    // sources-once/eps-guard/undo shape), two differences:
    //
    // (1) REV1 FIX-2 (drop redundant re-gather): the moving set is
    // `smoothLoopVerts_`, the DOWN-time cache from `onSmoothLoopRmbDown`
    // (`uniqueRingVerts`), reused VERBATIM — the mesh is never mutated
    // between arm and commit, so re-running `uniqueRingVerts` here would be
    // redundant, not more correct (mirrors `commitMoveLoop`'s own
    // no-re-gather discipline, P10). `loopNeighborsOf(m, smoothLoopSeed_)`
    // IS new commit-time work (never computed at arm time) — the 1-D
    // loop-neighbor connectivity each loop vertex relaxes along.
    //
    // (2) F1 (owner-observed, "концы стоят на месте" — REV1 F1 RESOLVED):
    // a loop vertex with EXACTLY 2 loop-neighbors relaxes toward the
    // shared `inverseEdgeLenRelax` kernel's inverse-edge-length-weighted
    // point between them and re-snaps via `closestPointOnMeshes` — P8's
    // nearest-FOOT query, NOT Move-Loop's camera-ray `resnapToBackground`:
    // a relaxed point has no natural screen pixel to ray through, so the
    // nearest-foot primitive is the correct reuse here (plan §Reuse
    // verdict item 4). A loop vertex with `!= 2` loop-neighbors — an
    // open-loop END (1 neighbor), or a defensive/degenerate 0 or 3+ (REV1
    // FIX-3 tightens the plan's original "< 2" to "!= 2") — is HELD FIXED:
    // skipped entirely, no relax, no re-snap, stays byte-unchanged across
    // every pass (the vertex is simply never written to `m.vertices`).
    // Non-loop vertices are NEVER touched either — the outer loop below
    // iterates `verts` alone, so "only loop vertices move" holds by
    // construction, not by a separate guard.
    //
    // Position-only, zero topology delta — no `resyncSession()` (mirrors
    // `commitMoveLoop`'s/`applySmoothPasses`'s own reasoning: a pure
    // position write can never dangle a sibling gesture's cached INDEX).
    private void applySmoothLoopPasses(int passCount) {
        if (meshSrc_ is null || history_ is null || smoothLoopEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;
        auto verts = smoothLoopVerts_;   // REV1 FIX-2: the DOWN-time cache, reused verbatim
        if (verts.length == 0) return;
        foreach (vi; verts)
            if (vi >= m.vertices.length) return;   // stale/corrupted arm — defensive

        auto loopNbrs = loopNeighborsOf(m, cast(uint)smoothLoopSeed_);   // new commit-time work

        // Two-layer clamp (mirrors applySmoothPasses's own): floor at 1 (a
        // click always applies exactly one pass), cap at
        // MAX_TOPOPEN_SMOOTH_PASSES (the shared runaway backstop).
        if (passCount < 1) passCount = 1;
        if (passCount > MAX_TOPOPEN_SMOOTH_PASSES) passCount = MAX_TOPOPEN_SMOOTH_PASSES;

        auto sources = backgroundSourcesSnapshot();   // point-in-time, fetched ONCE per commit
        MeshSnapshot before = MeshSnapshot.capture(*m);

        foreach (pass; 0 .. passCount) {
            Vec3[] read = m.vertices.dup;   // this pass's neighbor-read snapshot (Jacobi)
            foreach (vi; verts) {
                auto pNbrs = vi in loopNbrs;
                // F1/REV1 FIX-3: `!= 2` (not `< 2`) — an open-loop end (1
                // neighbor) OR a degenerate/self-touching >2 case is held
                // fixed identically; a missing AA entry (defensive) is the
                // same as 0 neighbors.
                if (pNbrs is null || (*pNbrs).length != 2) continue;

                bool hadNeighbors;
                Vec3 relaxed = inverseEdgeLenRelax(read, vi, *pNbrs, hadNeighbors);
                if (!hadNeighbors) continue;
                if (sources.length) {
                    Vec3  hit, hitN;
                    int   si, fi;
                    float d2;
                    enum bool dblSided = false;   // V1 default -- matches P8/CONS Point-mode's own default
                    if (closestPointOnMeshes(relaxed, sources, dblSided, hit, hitN, si, fi, d2))
                        relaxed = hit;
                }
                m.vertices[vi] = relaxed;
            }
        }

        // Unconditional eps no-op guard, restricted to the LOOP verts —
        // the only ones this gesture could possibly have touched (mirrors
        // `applySmoothPasses`'s own whole-mesh guard, narrowed to this
        // gesture's actual write set).
        enum float kSmoothLoopEps = 1e-4f;   // mirrors applySmoothPasses's own eps guard
        bool changed = false;
        foreach (vi; verts)
            if ((m.vertices[vi] - before.vertices[vi]).length > kSmoothLoopEps) { changed = true; break; }
        if (!changed) { before.restore(*m); return; }   // no mutation worth recording -- no GPU churn

        m.commitChange(MeshEditScope.Position);
        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = smoothLoopEditFactory_();
        cmd.setSnapshots(before, after, "Topology Smooth Loop");
        history_.record(cmd);

        // Position-only: no resyncSession() — see this method's own doc
        // comment above.

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

    // Mid-edge Split (doc/topopen_midedge_split_plan.md Deliverable #3):
    // commit the deferred RELEASE-ON-EDGE case — the release lands on edge
    // `edgeIdx` (not a vertex) at fraction `f` (world-proj `ratioOnSegment`,
    // ALREADY resolved by the caller in `edges[edgeIdx][0]->[1]` order to
    // match `addEdgePoint`'s own convention). ZERO kernel change: composes
    // `addEdgePoint` (insert M on the edge, splicing it into every incident
    // face's winding) with the EXISTING `splitFaceByVertices` (chord-split
    // the target face A-M) — the only new logic is the pre-mutation
    // viability gate (`findEdgeSplitFace`) and the atomicity guard below.
    //
    // MANDATORY ATOMICITY FIX (plan-opponent REVISE, folded into the
    // shipped implementation — NOT an optional hardening pass):
    // `addEdgePoint` mutates the LIVE mesh (splices M into every face
    // incident to `edgeIdx`, rebuilds edges[]/loops) BEFORE
    // `splitFaceByVertices` ever runs. A naive composition that skipped the
    // return-value check, or that re-derived the split face via
    // `findCommonSplitFace(m, a, mIdx)` AFTER that splice, could record a
    // PARTIAL split (M inserted, chord never cut) with no undo entry, or
    // mis-resolve which face to split for a bowtie/non-manifold `a` (a
    // vertex appearing more than once in one face's winding — the two
    // "wings" pinched together at `a` — so the same physical face can carry
    // more than the expected 2 cut-vertex hits post-splice, and
    // `splitFaceByVertices` legitimately declines). This implementation:
    //   1. Captures `before` BEFORE `addEdgePoint` runs, so a rollback is
    //      always possible once mutation starts.
    //   2. Uses `P` — the face `findEdgeSplitFace` resolved BEFORE any
    //      mutation — DIRECTLY as `splitFaceByVertices`'s `faceIdx`. `P`'s
    //      index stays valid across `addEdgePoint` (it splices windings in
    //      place; `rebuildEdges`/`buildLoops` never reorder `faces[]`), so
    //      no post-mutation re-derivation is needed or attempted.
    //   3. Guards the kernel's return value: `n == 0` means the chord-split
    //      step failed AFTER `addEdgePoint` already mutated the mesh, so the
    //      pre-`addEdgePoint` `before` snapshot is RESTORED — the mesh ends
    //      up byte-identical to its state before this function ran, and NO
    //      undo entry is recorded for the partial mutation.
    //   4. Only on success (`n > 0`) is `after` captured and the ONE atomic
    //      undo entry recorded — the whole gesture (insert + chord-split) is
    //      a single undo step, exactly like `commitSplit`'s vertex-target
    //      sibling above.
    //
    // Pre-mutation viability gate: `findEdgeSplitFace` runs FIRST (no
    // snapshot, no mutation, clean no-op on -1 — covers A-on-E and
    // no-shared-face). The `f` range gate runs SECOND, also before any
    // mutation: `ratioOnSegment` clamps to `[0,1]`, so `f<=0`/`f>=1` means
    // the release projected onto (or past) one of E's own endpoints — that
    // release belongs to the vertex-target path (which the caller's
    // vertex-first `findSourceVertex` snap already owns within
    // `kTopoPenSnapPx`), not this mid-edge insert; treated as a clean no-op
    // here rather than inserting a vertex on top of an existing corner.
    private void commitSplitOnEdge(int a, int edgeIdx, float f) {
        if (meshSrc_ is null || history_ is null || splitEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;

        int P = findEdgeSplitFace(m, a, edgeIdx);
        if (P < 0) return;   // A on E, or no face shared by A and E -> clean no-op

        if (f <= 0.0f || f >= 1.0f) return;   // near-endpoint -> vertex path owns this release

        MeshSnapshot before = MeshSnapshot.capture(*m);

        uint mIdx = m.addEdgePoint(cast(uint)edgeIdx, f);
        if (mIdx == uint.max) return;   // defensive; addEdgePoint's own guard fails
                                         // BEFORE any mutation, so `before` is
                                         // safely discarded (unused) here

        // ATOMICITY: `P` is used DIRECTLY — never re-derived post-mutation.
        size_t n = m.splitFaceByVertices(cast(uint)P, cast(uint)a, mIdx);
        if (n == 0) {
            // `addEdgePoint` already spliced M into the live mesh above —
            // roll back to the EXACT pre-mutation snapshot (the same
            // restore path `MeshSessionEdit.revert()` uses) so the gesture
            // leaves no partial trace and records no undo entry.
            before.restore(*m);
            return;
        }

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = splitEditFactory_();
        cmd.setSnapshots(before, after, "Topology Split");
        history_.record(cmd);

        // KILLER-2 (shared with commitSplit above): invalidate any OTHER
        // armed gesture's cached face/edge indices now that faces[]/edges[]
        // have been rebuilt (twice: once by addEdgePoint, once by
        // splitFaceByVertices).
        resyncSession();

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md Phase
    // 2): commit the ONE gap cell `findFillCell` resolved — FULL KERNEL
    // REUSE, zero kernel change. Mirrors `commitSplit`/`commitAddLoop`
    // above: bracket the ONE kernel call in a single before/after
    // `MeshSnapshot` pair, record through the DEDICATED `fillEditFactory_`
    // (never `splitEditFactory_`/`removeEditFactory_`, which would bake the
    // wrong wire name onto a fill).
    //
    // `cellVerts` reuses the 4 EXISTING corner verts (Δv=0);
    // `makePolygonFromVerts(autoOrient:true)` creates any missing edge (a
    // notch's mouth), majority-vote auto-orients winding consistent with
    // the neighbouring faces, and rejects dup-face/non-manifold/degenerate
    // with a `-1` no-op — the mesh stays byte-unchanged and NO undo entry
    // is recorded (the final backstop for a stray already-faced or
    // otherwise invalid candidate; `findFillCell`'s own border-edge
    // seeding already makes this the uncommon path).
    //
    // Single mutation, unlike `commitSplitOnEdge`'s two-kernel composition
    // — no partial-mutation rollback is needed here.
    //
    // KILLER-2 (shared with every topology-growing sibling commit above):
    // `makePolygonFromVerts` runs `buildLoops()`, moving `faces[]`/
    // `edges[]` indices — any OTHER gesture armed on a different button
    // holding a face/edge index would dangle. `resyncSession()` is called
    // on SUCCESS, in the SAME position every sibling commit calls it (the
    // tool never overrides `isDragging()`, so a Fill click CAN fire
    // mid-build/mid-move/mid-slide on a different button).
    private void commitFill(const(uint)[] cellVerts) {
        if (meshSrc_ is null || history_ is null || fillEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;
        if (cellVerts.length != 4) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        int fi = m.makePolygonFromVerts(cellVerts, false, true);
        if (fi < 0) return;   // dup-face / non-manifold / degenerate -> clean no-op, no mutation

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = fillEditFactory_();
        cmd.setSnapshots(before, after, "Topology Fill");
        history_.record(cmd);

        // KILLER-2: invalidate any OTHER armed gesture's cached face/edge
        // indices now that faces[]/edges[] have been rebuilt.
        resyncSession();

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // P10 (doc/topopen_p10_moveloop_plan.md "Commit"): commit the armed Move
    // Loop gesture — writes EVERY entry of `verts`/`targets` (same length,
    // same order), one atomic undo entry via the DEDICATED
    // `moveLoopEditFactory_` (wireName "mesh.topoPen_moveloop") — mirrors
    // `commitSlide`'s N-vertex shape (`commitSlide` is the 2-vertex
    // template; this is the general N-vertex form). `targets` is a PARAM,
    // not resolved inside this function — the unmeasured re-snap
    // (`perVertexTargets`) is isolated from the testable commit, exactly how
    // `commitSlide` takes `tA`/`tB` rather than re-deriving them; a
    // per-vertex MISS is already baked into `targets[i] == orig[i]` by the
    // caller (`perVertexTargets`'s "keep original" policy), so this function
    // has no separate miss-handling of its own — it simply writes whatever
    // it is given (REV1 FIX-2's contract: a partial-miss commits atomically,
    // no per-vertex special-casing here).
    //
    // Position-only, zero topology delta — never resizes/rebuilds
    // `faces[]`/`edges[]`/`vertices[]` — so unlike P5/P6/P9 this does NOT
    // call `resyncSession()` (mirrors `commitSlide`'s/`applySmoothPasses`'s
    // own reasoning: no sibling gesture's cached INDEX can dangle from a
    // pure position write). Eps no-op guard (mirrors `moveVertexTo`/
    // `commitSlide`): a gesture that nets to ZERO vertex movement (every
    // target within eps of its own original position — e.g. every ray
    // missed, or a whole-loop click-without-drag that slipped past the
    // release-side `kMinDragPx` gate) records no mutation and no undo entry.
    private void commitMoveLoop(const(uint)[] verts, const(Vec3)[] targets) {
        if (meshSrc_ is null || history_ is null || moveLoopEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;
        if (verts.length == 0 || verts.length != targets.length) return;
        foreach (vi; verts)
            if (vi >= m.vertices.length) return;   // stale/corrupted arm — defensive

        enum float kMoveLoopEps = 1e-4f;   // mirrors moveVertexTo's/commitSlide's own eps guards
        bool changed = false;
        foreach (i, vi; verts)
            if ((targets[i] - m.vertices[vi]).length > kMoveLoopEps) { changed = true; break; }
        if (!changed) return;   // no mutation worth recording — no GPU churn

        MeshSnapshot before = MeshSnapshot.capture(*m);
        foreach (i, vi; verts) m.vertices[vi] = targets[i];
        m.commitChange(MeshEditScope.Position);
        MeshSnapshot after = MeshSnapshot.capture(*m);

        auto cmd = moveLoopEditFactory_();
        cmd.setSnapshots(before, after, "Topology Move Loop");
        history_.record(cmd);

        // Position-only: no resyncSession() — see this method's own doc
        // comment / plan §Undo.

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // P11 (doc/topopen_p11_duploop_plan.md "The flow"): commit the armed
    // Duplicate Loop gesture — ONE atomic undo entry covering BOTH the
    // extrude (`Mesh.extendEdgesByMask`, identity TRS ⇒ a coincident
    // duplicate ring + bridge quads, ZERO new mesh.d code — the brief's
    // `extrudeEdgesByMask` is REFUTED, plan §Reuse verdict) and the
    // follow-up per-vertex drag/re-snap of the NEW (tail) verts, reusing
    // P10's `perVertexTargets` verbatim (the new verts are coincident with
    // their source loop verts, so projecting the new vert = projecting the
    // source — no source→new map needed). `loopEdges` are the edge
    // INDICES gathered at DOWN (`onDupLoopShiftRmbDown`); the mesh is
    // never mutated between arm and commit, so they stay valid — a
    // defensive out-of-range check bails before any mutation regardless
    // (a stale/corrupted arm).
    //
    // REV1 FIX-2: `[oldV .. m.vertices.length)` is a lazy `size_t` iota —
    // materialized + narrowed to a `uint[]` (`.array` + a `uint` map)
    // before it reaches `perVertexTargets` (`const(uint)[]`).
    //
    // REV1 FIX-3: `extendEdgesByMask` already calls
    // `commitChange(MeshEditScope.Geometry)` internally (the topology
    // growth); the follow-up MANUAL position write below uses
    // `commitChange(MeshEditScope.Position)` — mirrors `commitMoveLoop`'s
    // own manual-write precedent — never a second `Geometry` commit.
    //
    // `n == 0` (empty/all-wire mask — every gathered edge has zero
    // adjacent faces) is a clean no-op: `extendEdgesByMask` guarantees NO
    // mutation occurred before returning 0 (`mesh.d` "if (exEdges.length ==
    // 0) return 0;", before any `addVertex`/`faces ~=`), so this bails with
    // no history entry. Once `n > 0`, topology HAS grown regardless of
    // where the re-snap lands (UNLIKE `commitMoveLoop`'s Position-only eps
    // guard, there is no "nothing worth recording" case here — plan Risk 2's
    // all-rays-miss degenerate-coincident-ring outcome still commits the
    // one real topology change that already happened).
    //
    // Calls `resyncSession()` on success (KILLER-2, mirrors
    // `removeFaceAt`'s/`commitAddLoop`'s own discipline): `faces[]`/
    // `edges[]`/`vertices[]` all grew, so any OTHER armed gesture's cached
    // index would dangle.
    private void commitDupLoop(const(int)[] loopEdges, int dx, int dy,
                               const ref Viewport vp) {
        if (meshSrc_ is null || history_ is null || dupLoopEditFactory_ is null) return;
        auto m = mesh;
        if (m is null || loopEdges.length == 0) return;

        bool[] mask; mask.length = m.edges.length;
        foreach (ei; loopEdges) {
            if (ei < 0 || ei >= cast(int)mask.length) return;   // stale/corrupted arm -- defensive
            mask[ei] = true;
        }

        MeshSnapshot before = MeshSnapshot.capture(*m);
        size_t oldV = m.vertices.length;
        size_t n = m.extendEdgesByMask(mask, 0.0f, 0.0f,
                                       Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
        if (n == 0) return;   // nothing extendable (all-wire/empty mask) -- no mutation occurred

        import std.range     : iota;
        import std.algorithm : map;
        import std.array     : array;
        // FIX-2: materialize + narrow the lazy size_t iota to a uint[] --
        // extendEdgesByMask is pure-add (new verts appended at the tail,
        // never reindexed), so [oldV .. m.vertices.length) is exactly the
        // coincident duplicate ring.
        uint[] newVerts = iota(oldV, m.vertices.length).map!(i => cast(uint)i).array;

        auto targets = perVertexTargets(newVerts, dx, dy, vp);
        foreach (i, vi; newVerts) m.vertices[vi] = targets[i];
        // FIX-3: Position-only follow-up write -- extendEdgesByMask already
        // committed Geometry above.
        m.commitChange(MeshEditScope.Position);
        MeshSnapshot after = MeshSnapshot.capture(*m);

        auto cmd = dupLoopEditFactory_();
        cmd.setSnapshots(before, after, "Topology Duplicate Loop");
        history_.record(cmd);

        resyncSession();   // KILLER-2: topology grew -- clear every sibling arm

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
        // Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md):
        // also drop every button's BASE `armed_[]` slot — an external
        // history navigation must invalidate an in-progress gesture's
        // dispatch-level arm too, not just this tool's own bools (the two
        // are otherwise independent: `resetAllGestureArms()` only ever
        // clears the bools `dispatchInput` doesn't know about). No prior
        // behavior to preserve here (this call didn't exist pre-migration)
        // — strictly more hygienic.
        resetAllArmed();
        // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
        // 3 item 3): also clear the passive hover-indicator state — an
        // external undo/redo with no subsequent motion event must not leave
        // a stale nearest-vert/edge index (possibly deleted by the
        // navigation) dangling into the next `draw()` call.
        hoverOverMesh_     = false;
        hoverNearestVert_  = -1;
        hoverNearestEdge_  = -1;
        hoverBoundaryFace_ = -1;
        hoverBoundary_     = false;
        // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md):
        // also drop the passive candidate-cell preview — an external
        // undo/redo with no subsequent motion event must not leave a stale
        // cell (possibly referencing verts the navigation deleted)
        // dangling into the next `draw()` call.
        fillCell_ = null;
    }

    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 4):
    // an even-odd, rotated-axis scanline fill — draws a dark diagonal
    // CROSS-HATCH (two 45°/135° families) over an arbitrary screen-space
    // polygon. Correct for convex AND concave n-gons: for each family,
    // sweep parallel diagonal lines across the polygon's own AABB, collect
    // each line's intersection parameters with every polygon edge, sort
    // them along the sweep direction, and draw between consecutive (even,
    // odd) pairs — the classic even-odd interior test, no clip-rect spill
    // (the intersections are already bounded to the polygon itself).
    // `poly` must be a simple (non-self-intersecting) closed loop, in
    // either winding order — the algorithm is winding-independent.
    private static void hatchScreenPolygon(ImGui.ImDrawList* dl, const ImVec2[] poly, uint col,
                                           float spacingPx, float widthPx,
                                           const ref Viewport vp) {
        if (poly.length < 3) return;

        float minX = poly[0].x, maxX = poly[0].x;
        float minY = poly[0].y, maxY = poly[0].y;
        foreach (p; poly) {
            if (p.x < minX) minX = p.x; else if (p.x > maxX) maxX = p.x;
            if (p.y < minY) minY = p.y; else if (p.y > maxY) maxY = p.y;
        }

        // Bundled review SHOULD-FIX (#27 review /
        // doc/topopen_p12_smoothloop_plan.md "hover-highlight SHOULD-FIX"):
        // clamp the AABB to the VIEWPORT rect BEFORE computing the sweep
        // range below — an off-frustum boundary-face vertex (e.g. a large
        // polygon whose silhouette partly leaves the visible viewport)
        // would otherwise make `cMin..cMax` sweep thousands of lines for
        // hatch that is never visible anyway (a render hitch, not just
        // wasted work). Off-viewport hatch isn't visible, so clamping is
        // lossless for what actually gets drawn.
        immutable float vpMinX = cast(float)vp.x,              vpMaxX = cast(float)(vp.x + vp.width);
        immutable float vpMinY = cast(float)vp.y,              vpMaxY = cast(float)(vp.y + vp.height);
        if (minX < vpMinX) minX = vpMinX;
        if (maxX > vpMaxX) maxX = vpMaxX;
        if (minY < vpMinY) minY = vpMinY;
        if (maxY > vpMaxY) maxY = vpMaxY;
        if (minX > maxX || minY > maxY) return;   // polygon's AABB is entirely off-viewport

        // `mainDiag==true` sweeps the (+1,+1) family (lines of constant
        // x - y); `false` sweeps the (+1,-1) family (lines of constant
        // x + y). Adjacent lines within a family are `spacingPx` apart in
        // the PERPENDICULAR direction; since both invariants change by
        // `sqrt(2)` per unit of perpendicular travel along a 45° line, the
        // invariant step is `spacingPx * SQRT2`.
        void sweepFamily(bool mainDiag) {
            immutable float step = spacingPx * SQRT2;
            if (step <= 0.0f) return;   // defensive: no infinite loop below
            immutable float cMin = mainDiag ? (minX - maxY) : (minX + minY);
            immutable float cMax = mainDiag ? (maxX - minY) : (maxX + maxY);

            // Bundled review SHOULD-FIX: ONE scratch buffer reused across
            // every sweep line in this family (`.length = 0` keeps the
            // underlying GC allocation's capacity, so the `~=` below grows
            // it in place instead of allocating fresh per line) rather than
            // a brand-new `ImVec2[]` per line — a convex face (the common
            // real call-site shape, a mesh polygon) needs only 2 slots per
            // line; a concave n-gon's extra crossings just grow this same
            // buffer. `assumeSafeAppend` after the length reset preserves the
            // append-capacity so `~=` reuses the block instead of reallocating
            // fresh each sweep line (safe: `hits` is never sliced or escaped —
            // the sort is in-place and AddLine copies the points).
            ImVec2[] hits;
            for (float c = cMin; c <= cMax; c += step) {
                hits.length = 0;
                hits.assumeSafeAppend();
                immutable size_t n = poly.length;
                foreach (i; 0 .. n) {
                    ImVec2 A = poly[i];
                    ImVec2 B = poly[(i + 1) % n];
                    float fA = mainDiag ? (A.x - A.y - c) : (A.x + A.y - c);
                    float fB = mainDiag ? (B.x - B.y - c) : (B.x + B.y - c);
                    if (fA == 0.0f && fB == 0.0f) continue;   // whole edge on the line: ill-defined
                    if ((fA > 0.0f && fB > 0.0f) || (fA < 0.0f && fB < 0.0f)) continue;   // same side
                    if (fA == fB) continue;   // defensive: avoid div-by-zero below
                    float s = fA / (fA - fB);
                    if (s < 0.0f || s > 1.0f) continue;   // defensive clamp
                    hits ~= ImVec2(A.x + s * (B.x - A.x), A.y + s * (B.y - A.y));
                }
                if (hits.length < 2) continue;   // guard: need a pair to draw a segment

                import std.algorithm : sort;
                // Both 45°-family directions are monotonic in x along the
                // sweep line, so sorting by x alone orders the crossings
                // correctly for either family.
                sort!((a, b) => a.x < b.x)(hits);

                size_t i = 0;
                while (i + 1 < hits.length) {
                    dl.AddLine(hits[i], hits[i + 1], col, widthPx);
                    i += 2;
                }
            }
        }

        sweepFamily(true);
        sweepFamily(false);
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

        // P10 (doc/topopen_p10_moveloop_plan.md Phase 4): the Move Loop
        // ghost is likewise independent of `lastHit_`/CONS's OWN hit
        // (unlike P4 Move's ghost below, which reuses `lastHit_.point` —
        // MOVE-LOOP resolves its OWN N per-vertex re-snap targets via
        // `resnapToBackground`, not the single CONS-published hit), so it
        // too is drawn BEFORE the `lastHit_.hit` early-return, mirroring
        // every other armed-gesture ghost above: a primary-only scene with
        // no background layer must still preview the armed loop (every
        // vertex simply staying at its own original position, per the miss
        // policy). Purely re-reads already-armed state
        // (`moveLoopSeed_`/`moveLoopVerts_`/`moveLoopStartX_`/`_Y_`/
        // `moveLoopCurX_`/`_Y_`) plus the live cursor delta — no mesh
        // mutation.
        if (moveLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && moveLoopSeed_ >= 0 && moveLoopSeed_ < cast(int)m.edges.length) {
                enum uint moveLoopCol = IM_COL32(255, 140, 60, 220);   // move-loop ghost orange
                int dx = moveLoopCurX_ - moveLoopStartX_;
                int dy = moveLoopCurY_ - moveLoopStartY_;

                Vec3[uint] ghostPos;
                foreach (vi; moveLoopVerts_) {
                    if (vi >= m.vertices.length) continue;
                    Vec3 orig = m.vertices[vi];
                    Vec3 g    = orig;   // default: miss (or off-screen) keeps the original
                    ImVec2 pt;
                    if (projectPt(orig, vp, pt)) {
                        int px = cast(int)(pt.x + cast(float)dx);
                        int py = cast(int)(pt.y + cast(float)dy);
                        Vec3 hitPt2;
                        if (resnapToBackground(px, py, vp, hitPt2)) g = hitPt2;
                    }
                    ghostPos[vi] = g;
                }

                foreach (ei; m.selectLoopEdges(cast(uint)moveLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    auto ga = ringE[0] in ghostPos;
                    auto gb = ringE[1] in ghostPos;
                    if (ga is null || gb is null) continue;
                    ImVec2 pa, pb;
                    if (projectPt(*ga, vp, pa) && projectPt(*gb, vp, pb))
                        dl.AddLine(pa, pb, moveLoopCol, 2.0f);
                }
                foreach (vi, pos; ghostPos) {
                    ImVec2 gp;
                    if (projectPt(pos, vp, gp))
                        dl.AddCircleFilled(gp, 4.0f, moveLoopCol, 16);
                }
            }
        }

        // P11 (doc/topopen_p11_duploop_plan.md Phase 4): the Dup Loop
        // ghost — preview of the coincident-then-dragged duplicate ring +
        // bridge quads, recomputed every frame from the LIVE cursor
        // (`dupLoopCurX_`/`dupLoopCurY_`), mirroring the Move Loop ghost
        // immediately above (same `resnapToBackground`/`projectPt`
        // primitives, no mesh mutation, no extrude — pure preview).
        // Independent of `lastHit_`/CONS, drawn before the same
        // `!lastHit_.hit` early-return as every other gesture ghost.
        if (dupLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                enum uint dupLoopCol = IM_COL32(60, 220, 140, 220);   // dup-loop ghost green
                int dx = dupLoopCurX_ - dupLoopStartX_;
                int dy = dupLoopCurY_ - dupLoopStartY_;

                foreach (ei; dupLoopEdges_) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto edgeE = m.edges[ei];
                    Vec3 a = m.vertices[edgeE[0]], b = m.vertices[edgeE[1]];

                    Vec3 aP = a, bP = b;   // default: miss (or off-screen) keeps coincident
                    ImVec2 pa, pb;
                    if (projectPt(a, vp, pa)) {
                        Vec3 hitA;
                        if (resnapToBackground(cast(int)(pa.x + cast(float)dx),
                                               cast(int)(pa.y + cast(float)dy), vp, hitA)) aP = hitA;
                    }
                    if (projectPt(b, vp, pb)) {
                        Vec3 hitB;
                        if (resnapToBackground(cast(int)(pb.x + cast(float)dx),
                                               cast(int)(pb.y + cast(float)dy), vp, hitB)) bP = hitB;
                    }

                    ImVec2 sa, sb, saP, sbP;
                    bool ok = projectPt(a, vp, sa) && projectPt(b, vp, sb)
                           && projectPt(aP, vp, saP) && projectPt(bP, vp, sbP);
                    if (!ok) continue;

                    // The predicted bridge quad a-b-b'-a' + the new dup-loop
                    // edge a'-b' (drawn with a heavier stroke), + a dot per
                    // predicted (dragged) vert.
                    dl.AddLine(sa, sb,   dupLoopCol, 1.5f);
                    dl.AddLine(sb, sbP,  dupLoopCol, 1.5f);
                    dl.AddLine(sbP, saP, dupLoopCol, 2.0f);
                    dl.AddLine(saP, sa,  dupLoopCol, 1.5f);

                    dl.AddCircleFilled(saP, 4.0f, dupLoopCol, 16);
                    dl.AddCircleFilled(sbP, 4.0f, dupLoopCol, 16);
                }
            }
        }

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 4): the Smooth+Loop
        // ghost — highlights the ARMED loop at its CURRENT (pre-relax)
        // vertex positions (no per-pass relaxation preview — deferred/
        // expensive, consistent with the whole-mesh Smooth ghost's own
        // restraint above), plus a P8-style cursor ring at the live drag
        // position (`smoothLoopCurX_`/`_Y_`). Independent of `lastHit_`/
        // CONS, drawn before the same `!lastHit_.hit` early-return as every
        // other gesture ghost above.
        if (smoothLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && smoothLoopSeed_ >= 0 && smoothLoopSeed_ < cast(int)m.edges.length) {
                enum uint smoothLoopCol = IM_COL32(120, 255, 200, 220);   // smoothing green-blue (P8's own hue)
                foreach (ei; m.selectLoopEdges(cast(uint)smoothLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    ImVec2 ra, rb;
                    if (projectPt(m.vertices[ringE[0]], vp, ra)
                     && projectPt(m.vertices[ringE[1]], vp, rb))
                        dl.AddLine(ra, rb, smoothLoopCol, 2.5f);
                }
                ImVec2 cur = ImVec2(cast(float)smoothLoopCurX_, cast(float)smoothLoopCurY_);
                dl.AddCircle(cur, 14.0f, smoothLoopCol, 24, 2.5f);
                dl.AddCircleFilled(cur, 4.0f, smoothLoopCol, 16);
            }
        }

        // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
        // 4). MINOR-5: placed AFTER the LAST pre-`!lastHit_.hit`-return
        // ghost block above (P10 Move Loop, P11 Dup Loop, P12 Smooth+Loop)
        // rather than literally "after smooth" — Split (P9), Move Loop
        // (P10), Dup Loop (P11), and Smooth+Loop (P12) all now sit between
        // the whole-mesh Smooth ghost and this early-return too. Independent
        // of `lastHit_`/CONS
        // (over the PRIMARY, not the background), like every ghost above,
        // so a primary-only scene still shows it. Gated on
        // `!anyGestureArmed()` (mode ghosts win when armed — Pinned Decision
        // 5) AND `hoverOverMesh_` (the REV1 FIX-1 gate resolved in
        // `onMouseMotion`). Draw order — edge, then hatch, then square — so
        // the square reads on top and the hatch sits under the edge line.
        if (!anyGestureArmed() && hoverOverMesh_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                immutable vlen = cast(int)m.vertices.length;
                immutable elen = cast(int)m.edges.length;

                // (a) nearest-EDGE line (full length) — under the square.
                if (hoverNearestEdge_ >= 0 && hoverNearestEdge_ < elen) {
                    auto he = m.edges[hoverNearestEdge_];
                    ImVec2 ea, eb;
                    if (projectPt(m.vertices[he[0]], vp, ea)
                     && projectPt(m.vertices[he[1]], vp, eb))
                        dl.AddLine(ea, eb, kHoverElemCol, kHoverEdgeWidthPx);
                }

                // (b) boundary-edge face CROSS-HATCH.
                if (hoverBoundary_ && hoverBoundaryFace_ >= 0
                                   && hoverBoundaryFace_ < cast(int)m.faces.length) {
                    ImVec2[] pts;
                    bool ok = true;
                    foreach (fvi; m.faces[hoverBoundaryFace_]) {
                        ImVec2 p;
                        if (!projectPt(m.vertices[fvi], vp, p)) { ok = false; break; }
                        pts ~= p;
                    }
                    if (ok && pts.length >= 3)
                        hatchScreenPolygon(dl, pts, kHoverHatchCol,
                                          kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                }

                // (c) nearest-VERTEX filled SQUARE — on top.
                if (hoverNearestVert_ >= 0 && hoverNearestVert_ < vlen) {
                    ImVec2 vc;
                    if (projectPt(m.vertices[hoverNearestVert_], vp, vc))
                        dl.AddRectFilled(
                            ImVec2(vc.x - kHoverVertSquareHalfPx, vc.y - kHoverVertSquareHalfPx),
                            ImVec2(vc.x + kHoverVertSquareHalfPx, vc.y + kHoverVertSquareHalfPx),
                            kHoverElemCol);
                }
            }
        }

        // Fill mode V1 candidate-cell preview (task 0477 continuation,
        // doc/topopen_fill_plan.md Phase 5, MANDATORY opponent fix #2): its
        // OWN sibling gate — `penMode_ == Fill && fillCell_.length == 4` —
        // deliberately NOT folded into the `hoverOverMesh_` block above.
        // `hoverOverMesh_` requires a pick within `kTopoPenSnapPx`, which is
        // FALSE when hovering the center of an empty gap cell (the defining
        // Fill-mode case: no vertex/edge/face is anywhere near the
        // cursor) — nesting this there would make the preview never render
        // for that scenario. Still gated on `!anyGestureArmed()` (mode
        // ghosts win when armed, same precedent as every other ghost).
        if (!anyGestureArmed() && penMode_ == PenMode.Fill
                                && fillCell_.length == 4 && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                immutable size_t vlen2 = m.vertices.length;
                bool ok = true;
                ImVec2[4] pts;
                foreach (k, vi; fillCell_) {
                    if (vi >= vlen2 || !projectPt(m.vertices[vi], vp, pts[k])) { ok = false; break; }
                }
                if (ok) {
                    hatchScreenPolygon(dl, pts[], kFillPreviewCol,
                                      kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                    foreach (k; 0 .. 4)
                        dl.AddLine(pts[k], pts[(k + 1) % 4], kFillPreviewCol, kHoverEdgeWidthPx);
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
        // Mid-edge Split (doc/topopen_midedge_split_plan.md Deliverable #4):
        // the sticky "Split at the Middle" option, for Tier-C tests to
        // assert the param wiring end-to-end without driving a full release.
        root["splitAtMiddle"]   = JSONValue(splitAtMiddle_);

        // P10 (doc/topopen_p10_moveloop_plan.md Phase 4): the armed Move
        // Loop gesture's state, for Tier-C tests to assert the picked seed
        // edge and gathered moving-set size without driving a full release.
        root["moveLoopArmed"]     = JSONValue(moveLoopArmed_);
        root["moveLoopSeed"]      = JSONValue(moveLoopSeed_);
        root["moveLoopVertCount"] = JSONValue(cast(int)moveLoopVerts_.length);

        // P11 (doc/topopen_p11_duploop_plan.md Phase 4): the armed Dup Loop
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and gathered loop-edge count without driving a full release.
        root["dupLoopArmed"]     = JSONValue(dupLoopArmed_);
        root["dupLoopSeed"]      = JSONValue(dupLoopSeed_);
        root["dupLoopEdgeCount"] = JSONValue(cast(int)dupLoopEdges_.length);

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 4): the armed
        // Smooth+Loop gesture's state, for Tier-C tests to assert the
        // picked seed edge and gathered moving-set size without driving a
        // full release. `smoothLoopPassCount` mirrors the whole-mesh
        // Smooth's own `smoothPassCount` derivation exactly (NIT-3 parity:
        // reports the CLAMPED value `onMouseButtonUp`'s Smooth+Loop branch
        // will actually apply if released now).
        root["smoothLoopArmed"]     = JSONValue(smoothLoopArmed_);
        root["smoothLoopSeed"]      = JSONValue(smoothLoopSeed_);
        root["smoothLoopVertCount"] = JSONValue(cast(int)smoothLoopVerts_.length);
        int smoothLoopPassCount = 1 + cast(int)(smoothLoopDragPx_ / kSmoothPassStridePx);
        if (smoothLoopPassCount > MAX_TOPOPEN_SMOOTH_PASSES) smoothLoopPassCount = MAX_TOPOPEN_SMOOTH_PASSES;
        root["smoothLoopPassCount"] = JSONValue(smoothLoopPassCount);

        // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
        // 6): a NEW nested object (deliberately NOT the existing `hover{}`
        // object above, which carries the P0/P1 CONS/background fields) so
        // Tier-C tests for that path stay intact.
        auto hi = JSONValue.emptyObject;
        hi["overMesh"]     = JSONValue(hoverOverMesh_);
        hi["nearestVert"]  = JSONValue(hoverNearestVert_);
        hi["nearestEdge"]  = JSONValue(hoverNearestEdge_);
        hi["isBoundary"]   = JSONValue(hoverBoundary_);
        hi["boundaryFace"] = JSONValue(hoverBoundaryFace_);
        root["hoverIndicator"] = hi;

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
// no-op — no vertex write, no undo entry — driven through the extracted
// `slideUp` release-side helper directly (arming state set up directly,
// mirroring `onCtrlLmbDown`'s post-classification result, rather than
// driving a full screen-space press) so the min-drag GATE ITSELF is under
// test, not just `commitSlide`'s own (also-present) eps guard. Phase-2
// input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md,
// Testing Category C): calls `slideUp` directly rather than
// `onMouseButtonUp` — the flipped `onMouseButtonUp` now routes through
// `dispatchInput`, which keys on the BASE's private `armed_[button]` (only
// set by a real Down through `onMouseButtonDown`), not on `slideArmed_` this
// test sets directly, so driving `onMouseButtonUp` here would no longer
// reach the min-drag gate at all. `gpu_` stays null and the release event
// carries no `SubjectPacket`, so this never reaches `refreshDisplay` — safe
// under bare `dub test`.
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
    bool consumed = t.slideUp(e, vts);
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
// findCommonSplitFace / commitSplit — T7b (P9 REVIEW NIT-1, vacuous-pass
// hazard): T7 above pins the FIX-3 sorted-lo/hi tie-break, but it only
// EXERCISES the tie-break if `facesAroundVertex(A)`'s dart fan visits the
// triangle (the must-be-rejected face) before the pentagon -- T7 does not
// pin that ordering. `buildLoops`'s serial `vertLoop` seed pass is
// last-write-wins over increasing loop index (face-major order), so the
// face added LAST at the shared vertex is the one the fan visits FIRST; in
// T7 (triangle added, then pentagon) that means the pentagon is visited
// first and `findCommonSplitFace` returns it before the triangle's
// adjacency check is ever reached -- an unsorted-variant regression would
// ALSO pass T7, vacuously. This rig is IDENTICAL to T7 except the two
// `addFace` calls are swapped, flipping which face is added last so the
// triangle is visited first instead. Together the two tests guarantee the
// triangle is first-in-fan in at least one of them, so the pair catches an
// unsorted-variant regression regardless of fan-walk order.
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
    // A=0, C=1, D=2, E=3, F=4 -- same rig as T7, `addFace` calls SWAPPED
    // (pentagon first, triangle second) so the triangle is added last.
    foreach (i; 0 .. 5) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 2u, 3u, 1u, 4u]);  // pentagon [A,D,E,C,F] -> A@pos0, C@pos3 (non-adjacent)
    m.addFace([1u, 2u, 0u]);          // triangle [C,D,A] -> A@pos2(len-1), C@pos0 (wrap-adjacent)
                                       // shares edge A-D with the pentagon, so both
                                       // faces are on A's dart fan.
    m.buildLoops();

    // Setup sanity: same as T7, plus this rig's whole POINT -- the triangle
    // (not the pentagon) must be first-in-fan here, the opposite of T7.
    int incidentCount = 0;
    int firstFi = -1;
    foreach (fi; m.facesAroundVertex(0u)) { if (firstFi < 0) firstFi = cast(int)fi; ++incidentCount; }
    assert(incidentCount == 2,
        "setup: vertex A(0) must be incident to BOTH the triangle and the pentagon");
    assert(m.faces[firstFi].length == 3,
        "setup: this rig must visit the TRIANGLE first in A's dart fan (the opposite of T7) -- "
      ~ "otherwise it duplicates T7 instead of covering the flipped order");

    int triangleFi = (m.faces[0].length == 3) ? 0 : 1;
    auto triangleBefore = m.faces[triangleFi].dup;

    t.commitSplit(0, 1);

    assert(m.faces.length == 3,
        "expected the PENTAGON to split into 2 sub-faces (triangle survives untouched) -- "
      ~ "3 total faces");
    bool triangleSurvives = false;
    foreach (f; m.faces) if (f[] == triangleBefore[]) triangleSurvives = true;
    assert(triangleSurvives,
        "the adjacent triangle (where A-C is a real edge) must survive byte-unchanged -- "
      ~ "the tool must have picked the PENTAGON, not the triangle, even when the triangle "
      ~ "is visited FIRST in the dart fan");
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

// ---------------------------------------------------------------------------
// uniqueRingVerts — REV1 FIX-1 (doc/topopen_p10_moveloop_plan.md): the
// moving-set on a small grid must be the classic IN-LINE edge-loop chain
// (`Mesh.selectLoopEdges`), NOT the perpendicular ring
// (`loopSliceRingEdges`/`collectEdgeRing`). Both cases below are HAND-
// COMPUTED against the grid's own known layout (`makeGridPlane(2)`: a 3x3
// vertex grid, `index(i,j) = i*3+j`), independently of any prior probe of
// `selectLoopEdges` itself:
//   * INTERIOR seed (edge 3-4, the middle row's own row-boundary edge)
//     walks the classic in-line chain STRAIGHT ACROSS the whole middle row
//     (i=1, j=0..2) — vertices {3,4,5} — dead-ending at the left/right
//     grid boundary on each side (an OPEN chain on a non-toroidal grid).
//   * BOUNDARY seed (edge 0-1, a genuine top-row perimeter edge) chains
//     along the grid's own closed perimeter (`selectLoopBorderChain`) —
//     every perimeter vertex EXCEPT the untouched center (4) — a CLOSED
//     loop.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.format : format;

    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges

    uint seedRow = m.edgeIndex(3, 4);
    assert(seedRow != uint.max, "setup: middle-row edge 3-4 must exist");
    auto rowVerts = TopologyPenTool.uniqueRingVerts(&m, seedRow);
    assert(rowVerts == [3u, 4u, 5u],
        format("interior seed must gather the in-line row chain {3,4,5}; got %s", rowVerts));

    uint seedBoundary = m.edgeIndex(0, 1);
    assert(seedBoundary != uint.max, "setup: top-row boundary edge 0-1 must exist");
    auto boundaryVerts = TopologyPenTool.uniqueRingVerts(&m, seedBoundary);
    assert(boundaryVerts == [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u],
        format("boundary seed must gather the full closed perimeter (every vertex but the "
             ~ "untouched center, 4); got %s", boundaryVerts));
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T1 INTERIOR (doc/topopen_p10_moveloop_plan.md §Testing):
// a hand-built target set (each loop vertex offset by a fixed vector) must
// land EXACTLY at its target, topology (v/e/f counts) must stay unchanged
// (δ=0), the gesture is one atomic undo entry, and undo/redo restore the
// exact pre-/post-move positions.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_             = history;
    t.moveLoopEditFactory_  = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                        "mesh.topoPen_moveloop", "Topology Move Loop",
                                                        MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [3u, 4u, 5u]);

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];

    enum Vec3 offset = Vec3(0.2f, 1.5f, -0.4f);
    Vec3[] targets;
    foreach (o; orig) targets ~= o + offset;

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    t.commitMoveLoop(verts, targets);

    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            format("loop vertex %d must land exactly at its target", vi));
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real loop move must record one undo entry");

    history.undo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - orig[i]).length < 1e-5f,
            "undo must restore every loop vertex's exact pre-move position");

    history.redo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            "redo must restore every loop vertex's exact moved position");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T2 BOUNDARY (doc/topopen_p10_moveloop_plan.md §Testing):
// the same commit contract over the full closed-perimeter moving-set (8
// vertices) — every entry lands at its target, δ=0.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u]);

    Vec3[] targets;
    foreach (vi; verts) targets ~= m.vertices[vi] + Vec3(0, 0.75f, 0);

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    t.commitMoveLoop(verts, targets);

    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            format("perimeter vertex %d must land exactly at its target", vi));
    // The untouched center (4) must be left exactly alone.
    assert((m.vertices[4] - Vec3(0, 0, 0)).length < 1e-6f,
        "the center vertex (outside the boundary loop) must not move");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real perimeter loop move must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T3 NO-OP GUARD (doc/topopen_p10_moveloop_plan.md
// §Undo): targets identical (within eps) to the current positions must be a
// byte-identical no-op — no mutation, no undo entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);

    Vec3[] targets;
    foreach (vi; verts) targets ~= m.vertices[vi];   // exactly the current positions

    auto before = MeshSnapshot.capture(m);
    t.commitMoveLoop(verts, targets);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices, "an all-stationary target set must not move any vertex");
    assert(!history.canUndo(), "an all-stationary commit must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T4 PARTIAL-MISS (REV1 FIX-2, doc/topopen_p10_moveloop_plan.md
// "The pinned drag-mapping" / REV1): simulates a per-vertex background-ray
// MISS by feeding `commitMoveLoop` a `targets[]` where SOME entries equal
// `orig[i]` exactly (the "keep original" policy `perVertexTargets` applies
// on a miss) while others carry a real offset. The specific held vertex
// must stay EXACTLY put while the others move — locking the "miss -> keep
// original per-vertex" contract at the commit layer (there is no
// Escape-cancel in this tool family, so a partial-miss commits atomically,
// as one single undo entry covering the whole gesture).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);   // [3, 4, 5]
    assert(verts == [3u, 4u, 5u]);

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];

    // verts[0]=3 and verts[2]=5 get a real offset ("hit"); verts[1]=4's
    // target is set to its OWN original position, simulating a per-vertex
    // ray MISS for the middle loop vertex.
    Vec3[] targets = [orig[0] + Vec3(0, 1.0f, 0), orig[1], orig[2] + Vec3(0, 1.0f, 0)];

    t.commitMoveLoop(verts, targets);

    assert((m.vertices[3] - targets[0]).length < 1e-5f, "the HIT vertex (3) must move to its target");
    assert((m.vertices[4] - orig[1]).length < 1e-6f,
        format("the MISS vertex (4) must stay EXACTLY at its original position; got %s", m.vertices[4]));
    assert((m.vertices[5] - targets[2]).length < 1e-5f, "the HIT vertex (5) must move to its target");
    assert(history.canUndo(),
        "a partial-miss gesture (some verts moved) must still record ONE atomic undo entry");

    history.undo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - orig[i]).length < 1e-5f,
            "undo must restore every loop vertex — including the ones that never moved — exactly");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T5 SPACING PRESERVED / ON-SURFACE (doc/topopen_p10_moveloop_plan.md
// §Testing "spacing / no-collapse"): targets computed from an INJECTED
// analytic curved surface (a parabola `y = 0.3*x^2` over the loop's own
// x-line, evaluated HERE in-test — no Document background needed) must
// each lie exactly ON that surface (re-derived independently, never by
// re-reading the target array's own construction) and consecutive
// loop-vertex distances must stay within a band of the PRE-drag spacing —
// proving the commit does not collapse the loop toward a point, unlike a
// hypothetical implementation that averaged/interpolated instead of writing
// every target verbatim.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.math   : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);   // [3, 4, 5] at x=-1,0,1 (z=0)

    static float heightAt(float x) { return 0.3f * x * x; }

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];
    Vec3[] targets;
    foreach (o; orig) targets ~= Vec3(o.x, heightAt(o.x), o.z);

    // Pre-drag consecutive spacing (all exactly 1.0 on the flat grid).
    float preD01 = (orig[1] - orig[0]).length;
    float preD12 = (orig[2] - orig[1]).length;

    t.commitMoveLoop(verts, targets);

    // On-surface: re-derive the expected height independently per vertex
    // (never reusing the `targets` array's own values).
    foreach (i, vi; verts) {
        float expectedY = heightAt(m.vertices[vi].x);
        assert(abs(m.vertices[vi].y - expectedY) < 1e-5f,
            format("loop vertex %d must lie exactly on the injected surface y=0.3x^2; "
                 ~ "got y=%f expected %f", vi, m.vertices[vi].y, expectedY));
    }

    float postD01 = (m.vertices[verts[1]] - m.vertices[verts[0]]).length;
    float postD12 = (m.vertices[verts[2]] - m.vertices[verts[1]]).length;
    assert(postD01 > preD01 * 0.5f && postD01 < preD01 * 2.0f,
        format("consecutive spacing (0-1) must stay within a band of pre-drag; pre=%f post=%f",
               preD01, postD01));
    assert(postD12 > preD12 * 0.5f && postD12 < preD12 * 2.0f,
        format("consecutive spacing (1-2) must stay within a band of pre-drag; pre=%f post=%f",
               preD12, postD12));
}

// ---------------------------------------------------------------------------
// resnapToBackground — HIT + MISS (doc/topopen_p10_moveloop_plan.md
// §Re-snap): a camera-ray cast through an arbitrary pixel against a flat
// background plane must match an INDEPENDENTLY-computed ray-plane
// intersection (`screenPointToRay` — the same primitive `pickSurface`
// itself calls — combined with a hand-derived `y = planeY` solve, never a
// second call into `resnapToBackground`/`pickSurface`); a pixel whose ray
// misses the (finite) background mesh entirely must return false.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import math : screenPointToRay;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();

    enum float planeY = -1.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-10, planeY, -10), Vec3(10, planeY, -10),
                   Vec3(10, planeY, 10),   Vec3(-10, planeY, 10)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    int px = 100, py = 100;   // viewport center
    Vec3 org, dir;
    screenPointToRay(cast(float)px + 0.5f, cast(float)py + 0.5f, vp, org, dir);
    assert(abs(dir.y) > 1e-6f, "setup: the ray must not be parallel to the bg plane");
    float ty = (planeY - org.y) / dir.y;
    assert(ty > 0, "setup: the bg plane must be in FRONT of the camera at this pixel");
    Vec3 expected = org + dir * ty;

    Vec3 got;
    bool hit = t.resnapToBackground(px, py, vp, got);
    assert(hit, "resnapToBackground must hit the (large, in-front) background plane");
    assert((got - expected).length < 1e-3f,
        format("resnapToBackground must match the independently-computed ray-plane hit; "
             ~ "got %s expected %s", got, expected));

    // No background at all -> must miss cleanly.
    setBackgroundSnapSources(null);
    Vec3 gotNone;
    bool hitNone = t.resnapToBackground(px, py, vp, gotNone);
    assert(!hitNone, "resnapToBackground must return false with no background source at all");
}

// ---------------------------------------------------------------------------
// perVertexTargets — SHIFT + PER-VERTEX MISS POLICY
// (doc/topopen_p10_moveloop_plan.md "The pinned drag-mapping"): a shared
// screen-delta is applied to EACH vertex's own screen projection before
// re-snapping; a vertex whose shifted pixel hits the background lands
// (approximately) ON it, while a vertex whose shifted pixel misses (here,
// simply because it is far from the small background's footprint) keeps
// its EXACT original position — the miss policy this function is
// responsible for (REV1 FIX-2's contract is pinned at the commit layer
// above; this pins the same contract one layer up, where the miss is
// actually decided).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import math  : screenPointToRay;
    import snap  : setBackgroundSnapSources;
    import std.math : abs;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();

    Vec3 vA = Vec3(0, 0, 0);
    Vec3 vB = Vec3(8, 0, 8);   // far away -> its shifted ray will land far from a small bg patch

    Mesh m;
    m.addVertex(vA);
    m.addVertex(vB);
    t.meshSrc_ = () => &m;

    int dx = 10, dy = -6;

    // Determine (via the SAME pixel-rounding perVertexTargets itself uses)
    // exactly where vA's shifted ray lands on the y=-1.5 plane, so the small
    // background patch below can be centered there — SETUP ONLY, not the
    // assertion itself (the assertion below re-derives the same value from
    // scratch via `screenPointToRay`, never by reading this back).
    ImVec2 ptA;
    assert(TopologyPenTool.projectPt(vA, vp, ptA), "setup: vA must project on-screen");
    int pxA = cast(int)(ptA.x + cast(float)dx);
    int pyA = cast(int)(ptA.y + cast(float)dy);
    Vec3 orgA, dirA;
    screenPointToRay(cast(float)pxA + 0.5f, cast(float)pyA + 0.5f, vp, orgA, dirA);
    enum float planeY = -1.5f;
    assert(abs(dirA.y) > 1e-6f);
    float tyA = (planeY - orgA.y) / dirA.y;
    assert(tyA > 0, "setup: vA's shifted ray must hit the plane in front of the camera");
    Vec3 hitA = orgA + dirA * tyA;

    auto bg = new Mesh();
    enum float half = 0.6f;
    bg.vertices = [Vec3(hitA.x - half, planeY, hitA.z - half), Vec3(hitA.x + half, planeY, hitA.z - half),
                   Vec3(hitA.x + half, planeY, hitA.z + half), Vec3(hitA.x - half, planeY, hitA.z + half)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    auto targets = t.perVertexTargets([0u, 1u], dx, dy, vp);
    assert(targets.length == 2);
    assert((targets[0] - hitA).length < 1e-3f,
        "vA's shifted-and-resnapped target must match the small bg patch's own ray-plane hit");
    assert((targets[1] - vB).length < 1e-6f,
        "vB (far outside the small bg patch's footprint) must keep its EXACT original position");
}

// ---------------------------------------------------------------------------
// onMoveLoopRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p10_moveloop_plan.md "RMB-dispatch resolution":
// a miss must fall through to RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onMoveLoopRmbDown(eHit, vts);
    assert(consumed, "a press on a valid edge midpoint must arm and consume");
    assert(t.moveLoopArmed_, "must arm the Move Loop gesture");
    assert(t.moveLoopVerts_ == [3u, 4u, 5u],
        format("armed moving-set must be the in-line row chain; got %s", t.moveLoopVerts_));

    t.moveLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onMoveLoopRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.moveLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch MIN-DRAG (doc/topopen_p10_moveloop_plan.md
// Phase 3): a RMB release within `kMinDragPx` of the press pixel is a clean
// no-op — no vertex write, no undo entry — driven through the extracted
// `moveLoopUp` release-side helper directly (arming state set up directly,
// mirroring P7 Slide's own MIN-DRAG test) so the min-drag GATE ITSELF is
// under test, not just `commitMoveLoop`'s own (also-present) eps guard.
// Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md,
// Testing Category C): calls `moveLoopUp` directly rather than
// `onMouseButtonUp` — see the Slide MIN-DRAG test's own doc comment above
// for why (the flipped `onMouseButtonUp` keys on the base's private
// `armed_[button]`, set only by a real Down, not on `moveLoopArmed_` this
// test sets directly).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.moveLoopSeed_   = cast(int)seed;
    t.moveLoopArmed_  = true;
    t.moveLoopStartX_ = 50;
    t.moveLoopStartY_ = 50;
    t.moveLoopVerts_  = [3u, 4u, 5u];

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 51; e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.moveLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.moveLoopArmed_, "release must disarm Move Loop regardless of the min-drag gate");
    assert(after.vertices == before.vertices, "click-without-drag must not move any vertex");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Move Loop arm (doc/topopen_p10_moveloop_plan.md
// "Undo factory"): an external history navigation mid-drag must not leave a
// dangling seed/moving-set for the eventual (now stale) release to commit
// against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 3;
    t.moveLoopVerts_ = [3u, 4u, 5u];

    t.resyncSession();

    assert(!t.moveLoopArmed_, "resyncSession must clear the armed Move Loop gesture");
    assert(t.moveLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.moveLoopVerts_.length == 0, "resyncSession must clear the moving-set");
}

// ---------------------------------------------------------------------------
// toolStateJson — Move Loop fields (doc/topopen_p10_moveloop_plan.md
// Phase 4): reports the armed seed + moving-set size, for Tier-C tests to
// assert the picked seed edge without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["moveLoopArmed"].type == JSONType.false_, "must start with no armed Move Loop");
    assert(cast(int)s0["moveLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["moveLoopVertCount"].integer == 0, "must start with an empty moving-set");

    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 7;
    t.moveLoopVerts_ = [1u, 2u, 3u, 4u];

    auto s1 = t.toolStateJson();
    assert(s1["moveLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["moveLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["moveLoopVertCount"].integer == 4, "must report the gathered moving-set size");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P10, doc/topopen_p10_moveloop_plan.md): drives the REAL RMB gesture
// end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `TopoPenAction.MoveLoop` -> `onMoveLoopRmbDown`), a motion event, and the
// RIGHT-button release branch
// (-> `commitMoveLoop`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `commitMoveLoop` cases above already cover, nor just the dispatch
// wiring, as `onMoveLoopRmbDown`'s own test above covers) — all still
// pure-`dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();

    // A flat background plane well BELOW the primary grid, large enough
    // that every loop vertex's shifted ray lands on it regardless of the
    // exact drag delta chosen below.
    enum float planeY = -1.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.moveLoopArmed_, "the real dispatch must have armed Move Loop");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 12; eMove.y = my - 7;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Vec3[] origPos;
    foreach (vi; [3u, 4u, 5u]) origPos ~= m.vertices[vi];

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 12; eUp.y = my - 7;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.moveLoopArmed_, "release must disarm Move Loop regardless of outcome");

    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    foreach (i, vi; [3u, 4u, 5u]) {
        assert((m.vertices[vi] - origPos[i]).length > 1e-3f,
            format("loop vertex %d must have actually moved", vi));
        assert(abs(m.vertices[vi].y - planeY) < 0.05f,
            format("loop vertex %d must land ON the background plane (y~=%f); got y=%f",
                   vi, planeY, m.vertices[vi].y));
    }

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md) — Phase 5
// pure, GL-free unittests (U1-U7) + the `anyGestureArmed()` Tier-A pin.
//
// Two hand-derived test cameras (mirroring `math.d`'s own `makeTestViewport`/
// `constraint.d`'s `makeHoverTestViewport` convention — a `version(unittest)`
// private Viewport builder local to this module): `makeHoverIndicatorTestViewport`
// looks down -Z at the XY plane (for hand-built vertex/edge fixtures, U1/U2/
// U5/U6/U7); `makeGridPlaneTestViewport` looks down -Y at the XZ plane (for
// `makeGridPlane`'s own ground-plane layout, U3/U4). Every test derives its
// cursor pixel via `TopologyPenTool.projectPt` on the mesh's OWN vertices
// (the same technique the P10 dispatch test above uses,
// `(p3.x+p4.x)*0.5f` etc.) rather than hand-computed screen math — exact
// regardless of perspective distortion, and robust to either camera choice.
// ---------------------------------------------------------------------------

version (unittest) private Viewport makeHoverIndicatorTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

version (unittest) private Viewport makeGridPlaneTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 5, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // U1 — nearest-vertex resolution: a cursor at vertex 0's own
           // projected pixel must resolve `hoverNearestVert_ == 0`,
           // independent of any farther vertex.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    uint v2 = m.addVertex(Vec3(0, 2, 0));
    m.addEdge(v0, v1);

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[v0], vp, p0), "setup: v0 must project on-screen");

    t.computeHoverIndicator(cast(int)p0.x, cast(int)p0.y, vp);
    assert(t.hoverNearestVert_ == cast(int)v0,
        "cursor at v0's own projected pixel must resolve v0 as nearest");
}

unittest { // U2 — nearest-edge resolution: a cursor at an edge's screen
           // midpoint (far from every vertex) must resolve
           // `hoverNearestEdge_` to that edge; `hoverNearestVert_` must
           // ALSO resolve simultaneously (both present, never
           // one-or-the-other).
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    uint v2 = m.addVertex(Vec3(0, 5, 0));   // far away: keeps v0/v1 the two nearest verts
    m.addEdge(v0, v1);
    m.addEdge(v1, v2);   // a second, much farther edge — the pick must not be trivial

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[v0], vp, p0));
    assert(TopologyPenTool.projectPt(m.vertices[v1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f);
    int my = cast(int)((p0.y + p1.y) * 0.5f);

    uint expectEdge = m.edgeIndex(v0, v1);
    assert(expectEdge != uint.max, "setup: edge v0-v1 must exist");

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)expectEdge,
        "cursor at the v0-v1 midpoint must resolve that edge as nearest");
    assert(t.hoverNearestVert_ >= 0,
        "the nearest vertex must ALSO resolve simultaneously");
}

unittest { // U3 — boundary detection: `makeGridPlane(2)`'s edge 0-1 (a
           // genuine top-row perimeter edge, exactly one incident face) must
           // resolve `hoverBoundary_==true` and `hoverBoundaryFace_==` that
           // single incident face — cross-checked independently via
           // `isEdgeBorder`/`facesAroundEdge` (not via the code under test).
    import mesh : makeGridPlane;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges
    t.meshSrc_ = () => &m;

    uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: boundary edge 0-1 must exist");
    assert(m.isEdgeBorder(e01), "setup: edge 0-1 must be a genuine boundary edge");
    int expectFace = -1;
    foreach (fi; m.facesAroundEdge(e01)) { expectFace = cast(int)fi; break; }
    assert(expectFace >= 0, "setup: a boundary edge must have exactly one incident face");

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f);
    int my = cast(int)((p0.y + p1.y) * 0.5f);

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)e01,
        "cursor at the edge-0-1 midpoint must resolve edge 0-1 as nearest");
    assert(t.hoverBoundary_, "edge 0-1 must be classified as a boundary edge");
    assert(t.hoverBoundaryFace_ == expectFace,
        "the hatch face must be the edge's own single incident face");
}

unittest { // U4 — interior (non-boundary) edge: `makeGridPlane(2)`'s edge
           // 3-4 is shared by two cells, so `hoverBoundary_` must resolve
           // false and there is no hatch face.
    import mesh : makeGridPlane;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges
    t.meshSrc_ = () => &m;

    uint e34 = m.edgeIndex(3, 4);
    assert(e34 != uint.max, "setup: interior edge 3-4 must exist");
    assert(!m.isEdgeBorder(e34), "setup: edge 3-4 must be a genuine interior (shared) edge");

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p3, p4;
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f);
    int my = cast(int)((p3.y + p4.y) * 0.5f);

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)e34,
        "cursor at the edge-3-4 midpoint must resolve edge 3-4 as nearest");
    assert(!t.hoverBoundary_, "an interior (2-face) edge must never be classified as a boundary");
    assert(t.hoverBoundaryFace_ == -1, "no hatch face for a non-boundary edge");
}

unittest { // U5 — empty mesh / no `meshSrc_`: must resolve to the all-clear
           // state with no crash, whether the delegate itself is unset or
           // wired to a genuinely empty mesh.
    auto vp = makeHoverIndicatorTestViewport();

    auto t1 = new TopologyPenTool();   // fresh tool: meshSrc_ unset (null delegate)
    t1.computeHoverIndicator(400, 400, vp);
    assert(t1.hoverNearestVert_ == -1 && t1.hoverNearestEdge_ == -1 && !t1.hoverBoundary_,
        "no meshSrc_ at all must resolve to the all-clear state");

    auto t2 = new TopologyPenTool();
    Mesh m2;                            // meshSrc_ wired, but the mesh itself is empty
    t2.meshSrc_ = () => &m2;
    t2.computeHoverIndicator(400, 400, vp);
    assert(t2.hoverNearestVert_ == -1 && t2.hoverNearestEdge_ == -1 && !t2.hoverBoundary_,
        "an empty mesh must also resolve to the all-clear state");
}

unittest { // U6 — both-simultaneous ("not one-or-the-other" guard): the
           // nearest vertex and nearest edge resolve INDEPENDENTLY, each to
           // its own pre-known expected index, even when they name entirely
           // unrelated elements — the cursor sits at v0, while the mesh's
           // only edge (v1-v2) is far away and shares no endpoint with v0.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));      // the cursor's target: nearest VERTEX
    uint v1 = m.addVertex(Vec3(10, 10, 0));    // far away, forms the mesh's ONLY edge
    uint v2 = m.addVertex(Vec3(10, 10.3f, 0));
    m.addEdge(v1, v2);
    uint expectEdge = m.edgeIndex(v1, v2);
    assert(expectEdge != uint.max, "setup: edge v1-v2 must exist");

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[v0], vp, p0));

    t.computeHoverIndicator(cast(int)p0.x, cast(int)p0.y, vp);
    assert(t.hoverNearestVert_ == cast(int)v0,
        "nearest vertex must resolve to v0, right under the cursor");
    assert(t.hoverNearestEdge_ == cast(int)expectEdge,
        "nearest edge must ALSO resolve — to the mesh's only edge, v1-v2 — "
      ~ "even though it shares no endpoint with the nearest vertex");
}

unittest { // U7 (REV1 FIX-2 — the test that would have caught FIX-1): a
           // non-null primary with vertices + bare EDGES + ZERO faces (the
           // tool's own from-scratch retopo founding state) must still
           // light up the hover indicator through the REAL `onMouseMotion`
           // gate. `gpu_` stays null (default) so `pickPrimaryFace`
           // short-circuits to -1 unconditionally — exactly mirroring a
           // genuinely faceless mesh's own BVH (zero triangles -> every ray
           // misses), so this proves the gate is NOT driven solely by
           // `pickPrimaryFace >= 0`.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(v0, v1);
    assert(m.faces.length == 0, "setup: this fixture must have ZERO faces");

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[v0], vp, p0));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent eOn;
    eOn.x = cast(int)p0.x;
    eOn.y = cast(int)p0.y;
    bool consumed = t.onMouseMotion(eOn, vts);
    assert(!consumed, "hover resolution must never consume motion");
    assert(t.hoverOverMesh_,
        "REV1 FIX-1: a faceless/bare-edge primary must still gate 'over the mesh' "
      ~ "via the finite-threshold vertex/edge proximity OR, even though "
      ~ "pickPrimaryFace is unconditionally -1 here");
    assert(t.hoverNearestVert_ == cast(int)v0,
        "the nearest vertex must resolve correctly even in the faceless state");
    assert(t.hoverNearestEdge_ >= 0,
        "the nearest edge must ALSO resolve in the faceless state");

    // A second motion far from all geometry must clear the gate again —
    // proving the gate is a genuine proximity test, not a sticky latch.
    SDL_MouseMotionEvent eOff;
    eOff.x = cast(int)p0.x + 5000;
    eOff.y = cast(int)p0.y + 5000;
    t.onMouseMotion(eOff, vts);
    assert(!t.hoverOverMesh_, "a cursor far from all geometry must clear the over-mesh gate");
    assert(t.hoverNearestVert_ == -1 && t.hoverNearestEdge_ == -1,
        "off-mesh must also clear the resolved nearest indices");
}

unittest { // anyGestureArmed — Tier-A pin (doc/topopen_hover_highlight_plan.md
           // MINOR-3, extended by P12 doc/topopen_p12_smoothloop_plan.md):
           // every one of the 10 currently-enumerated arm flags
           // independently flips the predicate true and none is silently
           // ignored — guards a future merge from dropping a flag from the
           // OR (the hazard `resetAllGestureArms()`'s own doc comment
           // enumerates for its sibling list).
    auto t = new TopologyPenTool();
    assert(!t.anyGestureArmed(), "no arm flag set -> false");

    t.dragArmed_ = true;     assert(t.anyGestureArmed(), "dragArmed_ must count");
    t.dragArmed_ = false;
    t.placeArmed_ = true;    assert(t.anyGestureArmed(), "placeArmed_ must count");
    t.placeArmed_ = false;
    t.moveArmed_ = true;     assert(t.anyGestureArmed(), "moveArmed_ must count");
    t.moveArmed_ = false;
    t.addLoopArmed_ = true;  assert(t.anyGestureArmed(), "addLoopArmed_ must count");
    t.addLoopArmed_ = false;
    t.slideArmed_ = true;    assert(t.anyGestureArmed(), "slideArmed_ must count");
    t.slideArmed_ = false;
    t.smoothArmed_ = true;   assert(t.anyGestureArmed(), "smoothArmed_ must count");
    t.smoothArmed_ = false;
    t.splitArmed_ = true;    assert(t.anyGestureArmed(), "splitArmed_ must count");
    t.splitArmed_ = false;
    t.moveLoopArmed_ = true; assert(t.anyGestureArmed(), "moveLoopArmed_ must count");
    t.moveLoopArmed_ = false;
    t.dupLoopArmed_ = true;  assert(t.anyGestureArmed(), "dupLoopArmed_ must count");
    t.dupLoopArmed_ = false;
    t.smoothLoopArmed_ = true; assert(t.anyGestureArmed(), "smoothLoopArmed_ must count");
    t.smoothLoopArmed_ = false;

    assert(!t.anyGestureArmed(), "every flag cleared again -> false");
}

// ===========================================================================
// P11 Duplicate Loop (doc/topopen_p11_duploop_plan.md) — Tier-B in-file
// unittests. The mandatory Phase-0 closed-rim probe (REV1 FIX-1) lives in
// mesh.d itself (`extendEdgesByMask: CLOSED-RING boundary probe`), since it
// pins the KERNEL's own behavior, not this tool. Everything below drives
// `commitDupLoop`/the dispatch handlers directly against hand-built
// `makeGridPlane(2)` fixtures — no bg needed for the topology-delta/
// coincident-vert/undo assertions (dx=dy=0 with no background source ⇒
// every ray misses ⇒ new verts stay exactly coincident, the deterministic
// no-bg case). The on-surface/resnap assertion is Tier-C
// (tests/test_topopen_duploop_resnap.d).
// ===========================================================================

unittest { // commitDupLoop — T1 BOUNDARY (doc/topopen_p11_duploop_plan.md
           // "Testing strategy", the owner-observed/measured case): a
           // CLOSED-perimeter loop (REV1 FIX-1 label correction — a
           // BOUNDARY seed is the FULL closed rim) duplicated with no
           // background (dx=dy=0 -> every ray misses -> new verts stay
           // EXACTLY coincident with their source): topology delta =
           // (+M,+(N+M),+N) computed from the gathered loop itself (not
           // hard-coded); every new (tail) vert coincident with its source
           // loop vert; the M original loop verts UNCHANGED; one history
           // entry; undo restores EXACTLY (removes all new geometry); redo
           // re-applies.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 8, "boundary seed must gather the full closed 8-edge rim");

    uint[] loopVerts;
    bool[uint] seen;
    foreach (ei; loop) {
        auto ep = m.edges[cast(uint)ei];
        foreach (v; ep) if (v !in seen) { seen[v] = true; loopVerts ~= v; }
    }
    size_t N = loop.length, M = loopVerts.length;
    assert(M == 8, "closed ring: M == N == 8 (one vertex per rim edge)");

    Vec3[] origLoopPos;
    foreach (vi; loopVerts) origLoopPos ~= m.vertices[vi];

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);

    assert(m.vertices.length == vBefore + M,
        format("expected +%d verts, got +%d", M, m.vertices.length - vBefore));
    assert(m.faces.length    == fBefore + N,
        format("expected +%d faces, got +%d", N, m.faces.length - fBefore));
    assert(m.edges.length    == eBefore + N + M,
        format("expected +%d edges, got +%d", N + M, m.edges.length - eBefore));

    // Every new (tail) vert is coincident with SOME original loop vertex —
    // no background -> every ray misses -> perVertexTargets keeps the
    // coincident post-extrude position verbatim.
    foreach (i; vBefore .. m.vertices.length) {
        bool matched = false;
        foreach (op; origLoopPos) if ((m.vertices[i] - op).length < 1e-5f) { matched = true; break; }
        assert(matched, format("new tail vertex %d must be coincident with some original loop vertex", i));
    }

    // The M original loop verts are UNCHANGED.
    foreach (i, vi; loopVerts)
        assert((m.vertices[vi] - origLoopPos[i]).length < 1e-6f,
            "the original loop vertices must never be written by DupLoop");

    assert(history.canUndo(), "a real Dup Loop commit must record one undo entry");

    history.undo();
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "undo must remove every bit of new geometry");
    foreach (i, vi; loopVerts)
        assert((m.vertices[vi] - origLoopPos[i]).length < 1e-6f,
            "undo must leave the original loop verts exactly alone");

    history.redo();
    assert(m.vertices.length == vBefore + M && m.edges.length == eBefore + N + M
        && m.faces.length == fBefore + N,
        "redo must re-apply the exact topology growth");
}

unittest { // commitDupLoop — T2 INTERIOR, FLAGGED (doc/topopen_p11_duploop_plan.md
           // "Out of scope (deferred, flagged)" / REV1 FIX-1 §Open-item IL):
           // an INTERIOR seed resolves to the classic OPEN in-line chain
           // (REV1 label correction), which `extendEdgesByMask` extends into
           // a non-manifold (2->3-face) result — UNMEASURED, the owner did
           // NOT capture this case. This test pins only the well-defined
           // TOPOLOGY DELTA (open-chain M=N+1); manifoldness is
           // DELIBERATELY NOT asserted here.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);   // interior seed -> the middle-row open chain
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 2, "interior seed must gather the 2-edge open middle-row chain");

    uint[] loopVerts;
    bool[uint] seen;
    foreach (ei; loop) {
        auto ep = m.edges[cast(uint)ei];
        foreach (v; ep) if (v !in seen) { seen[v] = true; loopVerts ~= v; }
    }
    size_t N = loop.length, M = loopVerts.length;
    assert(M == N + 1, "open chain: M == N+1");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);

    assert(m.vertices.length == vBefore + M,
        format("expected +%d verts, got +%d", M, m.vertices.length - vBefore));
    assert(m.faces.length    == fBefore + N,
        format("expected +%d faces, got +%d", N, m.faces.length - fBefore));
    assert(m.edges.length    == eBefore + N + M,
        format("expected +%d edges, got +%d", N + M, m.edges.length - eBefore));
    assert(history.canUndo(), "a real interior Dup Loop commit must still record one undo entry");
    // Manifoldness NOT asserted -- Open-item IL, unmeasured against the reference.
}

unittest { // commitDupLoop — NO-OP GUARD (doc/topopen_p11_duploop_plan.md
           // "The flow"): a WIRE edge (zero adjacent faces) as the sole
           // gathered loop -- `extendEdgesByMask` skips it (no orienting
           // face to bridge against) and returns 0 -- must be a clean
           // no-op: no mutation, no history entry, `!canUndo`.
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    m.addEdge(v0, v1);   // a bare wire edge -- zero adjacent faces
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(v0, v1);
    assert(seed != uint.max);
    auto loop = m.selectLoopEdges(seed);   // a stray/degenerate edge -> [seed] itself
    assert(loop == [cast(int)seed]);

    Viewport vp;
    auto before = MeshSnapshot.capture(m);
    t.commitDupLoop(loop, 5, 5, vp);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && m.faces.length == 0,
        "a wire-only loop must produce NO mutation");
    assert(!history.canUndo(), "a wire-only loop must record NO undo entry");
}

unittest { // commitDupLoop — resyncSession-on-success (doc/topopen_p11_duploop_plan.md
           // "Undo factory" KILLER-2): once a real Dup Loop commit lands
           // (topology GREW -- faces[]/edges[]/vertices[] all resized), any
           // OTHER gesture armed on a different button must be invalidated
           // -- its cached index would otherwise dangle against the
           // resized arrays. Mirrors `removeFaceAt`'s/`commitAddLoop`'s own
           // resyncSession()-on-success discipline.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);   // boundary seed -> the full closed perimeter
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 8);

    // Hand-arm a sibling gesture on a DIFFERENT button, as if it were
    // mid-drag concurrently.
    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 3;
    t.moveLoopVerts_ = [3u, 4u, 5u];

    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);   // no bg -> every new vert stays coincident; still a real commit

    assert(history.canUndo(), "setup: the commit must have actually recorded an undo entry");
    assert(!t.moveLoopArmed_, "resyncSession() on a successful Dup Loop commit must clear a sibling arm");
}

// ---------------------------------------------------------------------------
// onDupLoopShiftRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p11_duploop_plan.md "Shift+RMB dispatch
// resolution": a miss must fall through to Shift+RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f), my = cast(int)((p0.y + p1.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onDupLoopShiftRmbDown(eHit, vts);
    assert(consumed, "a Shift+RMB press on a valid boundary edge midpoint must arm and consume");
    assert(t.dupLoopArmed_, "must arm the Dup Loop gesture");
    assert(t.dupLoopEdges_.length == 8,
        format("armed loop must be the full closed 8-edge rim; got %d edges", t.dupLoopEdges_.length));

    t.dupLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onDupLoopShiftRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.dupLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch MIN-DRAG (doc/topopen_p11_duploop_plan.md
// Phase 3): a Shift+RMB release within `kMinDragPx` of the press pixel is a
// clean no-op — no extrude, no undo entry — driven through the extracted
// `dupLoopUp` release-side helper directly (arming state set up directly,
// mirroring P10 Move Loop's own MIN-DRAG test) so the min-drag GATE ITSELF
// is under test. Phase-2 input-dispatch migration
// (doc/topopen_input_dispatch_phase2_plan.md, Testing Category C): calls
// `dupLoopUp` directly rather than `onMouseButtonUp` — see the Slide
// MIN-DRAG test's own doc comment for why.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto edges = m.selectLoopEdges(seed);
    t.dupLoopSeed_    = cast(int)seed;
    t.dupLoopArmed_   = true;
    t.dupLoopStartX_  = 50;
    t.dupLoopStartY_  = 50;
    t.dupLoopEdges_   = edges;

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 51; e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.dupLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.dupLoopArmed_, "release must disarm Dup Loop regardless of the min-drag gate");
    assert(after.vertices == before.vertices && after.faces.length == before.faces.length,
        "click-without-drag must not mutate the mesh at all");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Dup Loop arm (doc/topopen_p11_duploop_plan.md
// "Undo factory"): an external history navigation mid-drag must not leave a
// dangling seed/edge-list for the eventual (now stale) release to commit
// against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.dupLoopArmed_ = true;
    t.dupLoopSeed_  = 3;
    t.dupLoopEdges_ = [3, 4];

    t.resyncSession();

    assert(!t.dupLoopArmed_, "resyncSession must clear the armed Dup Loop gesture");
    assert(t.dupLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.dupLoopEdges_.length == 0, "resyncSession must clear the gathered loop-edge list");
}

// ---------------------------------------------------------------------------
// toolStateJson — Dup Loop fields (doc/topopen_p11_duploop_plan.md Phase 4):
// reports the armed seed + gathered loop-edge count, for Tier-C tests to
// assert the picked seed edge without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["dupLoopArmed"].type == JSONType.false_, "must start with no armed Dup Loop");
    assert(cast(int)s0["dupLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["dupLoopEdgeCount"].integer == 0, "must start with an empty gathered loop");

    t.dupLoopArmed_ = true;
    t.dupLoopSeed_  = 7;
    t.dupLoopEdges_ = [1, 2, 3, 4, 5];

    auto s1 = t.toolStateJson();
    assert(s1["dupLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["dupLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["dupLoopEdgeCount"].integer == 5, "must report the gathered loop-edge count");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P11, doc/topopen_p11_duploop_plan.md): drives the REAL Shift+RMB gesture
// end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `TopoPenAction.DupLoop` ->
// `onDupLoopShiftRmbDown`), a motion event, and the RIGHT-button release
// branch (-> `commitDupLoop`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `commitDupLoop` cases above already cover, nor just the dispatch
// wiring, as `onDupLoopShiftRmbDown`'s own test above covers) — all still
// pure-`dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(KMOD_SHIFT);
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();

    // A flat background plane well BELOW the primary grid, large enough
    // that every new vertex's shifted ray lands on it regardless of the
    // exact drag delta chosen below.
    enum float planeY = -1.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f), my = cast(int)((p0.y + p1.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "Shift+RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.dupLoopArmed_, "the real dispatch must have armed Dup Loop");
    assert(t.dupLoopEdges_.length == 8, "the real dispatch must have gathered the full closed rim");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 12; eMove.y = my - 7;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 12; eUp.y = my - 7;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.dupLoopArmed_, "release must disarm Dup Loop regardless of outcome");

    assert(m.vertices.length == vBefore + 8 && m.edges.length == eBefore + 16
        && m.faces.length == fBefore + 8,
        "the real dispatch path must grow topology by the closed-rim delta (+8v/+16e/+8f)");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    foreach (vi; vBefore .. m.vertices.length)
        assert(abs(m.vertices[vi].y - planeY) < 0.05f,
            format("new vertex %d must land ON the background plane (y~=%f); got y=%f",
                   vi, planeY, m.vertices[vi].y));

    // The original 9 grid verts must be exactly unchanged.
    Vec3[9] gridPos;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3)
        gridPos[i * 3 + j] = Vec3(-1.0f + cast(float)j, 0.0f, -1.0f + cast(float)i);
    foreach (vi; 0 .. 9)
        assert((m.vertices[vi] - gridPos[vi]).length < 1e-5f,
            format("original grid vertex %d must be left exactly alone", vi));
}

// ===========================================================================
// P12 Smooth+Loop (doc/topopen_p12_smoothloop_plan.md) — Tier-B in-file
// unittests. The relax LAW is the P8-shared kernel extracted above
// (`inverseEdgeLenRelax`); P8's OWN `smoothedRelaxTarget` T4/boundary
// unittests (earlier in this file) already pin the wrapper's behavior and
// stay green unchanged — same direct-call signature, a pure extraction
// (REV1 core-plan approval). This section pins the NEW P12-only surface:
// the extracted kernel called with a RESTRICTED (loop) neighbor set, the
// 1-D loop-neighbor connectivity helper, the commit-level "only loop
// vertices move" + F1 endpoints-held-fixed contracts, dispatch, and undo.
// ===========================================================================

unittest { // inverseEdgeLenRelax — 2-neighbor exact match against an
           // INDEPENDENTLY-computed inverse-edge-length midpoint (mirrors
           // P8's own T4 discriminator, applied here directly to the
           // EXTRACTED kernel rather than through `smoothedRelaxTarget`'s
           // full-1-ring wrapper).
    import std.format : format;

    Vec3[] readPos = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 4, 0)];   // v=0; n1=1 (len 1), n2=2 (len 4)
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, [1u, 2u], hadNeighbors);
    assert(hadNeighbors, "a 2-neighbor set must report usable relax neighbors");

    float w1 = 1.0f / (readPos[0] - readPos[1]).length;
    float w2 = 1.0f / (readPos[0] - readPos[2]).length;
    Vec3 expected = (readPos[1] * w1 + readPos[2] * w2) * (1.0f / (w1 + w2));

    assert((actual - expected).length < 1e-5f,
        format("expected the inverse-edge-length midpoint %s; got %s", expected, actual));
}

unittest { // inverseEdgeLenRelax — a 1-neighbor set relaxes FULLY onto that
           // single neighbor (kStrength=1 -> weightedSum/weightSum reduces to
           // the one neighbor's own position exactly) — a pure property of
           // the shared weighting law over WHATEVER list it's handed;
           // F1's "held fixed" policy for a real open-loop end lives at the
           // `applySmoothLoopPasses` call site's `!= 2` guard below, never
           // inside this topology-agnostic kernel.
    Vec3[] readPos = [Vec3(0, 0, 0), Vec3(5, 2, -3)];
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, [1u], hadNeighbors);
    assert(hadNeighbors, "a 1-neighbor set must report usable relax neighbors");
    assert((actual - readPos[1]).length < 1e-5f,
        "a single-neighbor relax must land exactly on that neighbor");
}

unittest { // inverseEdgeLenRelax — a 0-neighbor set is a true no-op:
           // `readPos[v]` byte-unchanged, `hadNeighbors` stays false.
    Vec3[] readPos = [Vec3(1, 2, 3)];
    bool hadNeighbors;
    const(uint)[] noNbrs;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, noNbrs, hadNeighbors);
    assert(!hadNeighbors, "an empty neighbor set must report NO usable neighbors");
    assert(actual == readPos[0], "an empty neighbor set must be a byte-identical no-op");
}

unittest { // loopNeighborsOf — an interior loop vertex gets exactly its 2
           // loop-neighbors; an open-chain END gets exactly 1
           // (doc/topopen_p12_smoothloop_plan.md Phase 1 — mirrors
           // `uniqueRingVerts`'s own REV1 FIX-1 grid rig: `makeGridPlane(2)`,
           // a 3x3 vertex grid, `index(i,j) = i*3+j`).
    import mesh : makeGridPlane;
    import std.algorithm : sort;

    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges

    uint seedRow = m.edgeIndex(3, 4);
    assert(seedRow != uint.max, "setup: middle-row edge 3-4 must exist");
    auto rowNbrs = TopologyPenTool.loopNeighborsOf(&m, seedRow);
    assert(rowNbrs[3] == [4u], "open-chain END (3) must have exactly 1 loop-neighbor");
    assert(rowNbrs[5] == [4u], "open-chain END (5) must have exactly 1 loop-neighbor");
    auto n4 = rowNbrs[4].dup;
    sort(n4);
    assert(n4 == [3u, 5u], "interior loop vertex (4) must have exactly its 2 loop-neighbors");

    uint seedBoundary = m.edgeIndex(0, 1);
    assert(seedBoundary != uint.max, "setup: top-row boundary edge 0-1 must exist");
    auto boundaryNbrs = TopologyPenTool.loopNeighborsOf(&m, seedBoundary);
    foreach (vi; [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u])
        assert(boundaryNbrs[vi].length == 2,
            "every vertex of a CLOSED perimeter loop must have exactly 2 loop-neighbors");
}

unittest { // applySmoothLoopPasses — interior relax + nearest-foot re-snap,
           // non-loop verts UNCHANGED, F1 open-chain ENDPOINTS byte-unchanged,
           // δ=0, undo restores exactly (doc/topopen_p12_smoothloop_plan.md
           // §Testing Strategy + ⚠️ F1 RESOLVED's own added test). Uses the
           // SAME interior seed (edge 3-4) as `uniqueRingVerts`'s/
           // `loopNeighborsOf`'s own grid rig above — the gathered chain
           // [3,4,5] is EXACTLY the owner-observed "3x3 side edge" shape: 3
           // and 5 are the open-chain ENDS (1 loop-neighbor each), 4 is the
           // sole interior vertex (2 loop-neighbors). Vertex 4 is perturbed
           // off the flat grid's own colinear midpoint (else the relax would
           // be a no-op on this perfectly uniform grid) so the test can
           // discriminate "actually relaxed" from "left alone".
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    // Perturb vertex 4 off the flat grid's own colinear midpoint between 3
    // and 5 — on the UN-perturbed grid, 3/4/5 are exactly colinear and
    // evenly spaced, so the inverse-edge-length mean IS vertex 4's own
    // current position (a coincidental no-op unrelated to this gesture's
    // own no-op guard).
    m.vertices[4] = Vec3(0.3f, 2.0f, 0.0f);

    // A large flat background plane well below the perturbed grid.
    enum float planeY = -0.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    uint seed = m.edgeIndex(3, 4);
    assert(seed != uint.max);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [3u, 4u, 5u]);

    t.smoothLoopSeed_  = cast(int)seed;
    t.smoothLoopVerts_ = verts;

    Vec3 orig3 = m.vertices[3], orig4 = m.vertices[4], orig5 = m.vertices[5];
    // Independently-computed inverse-edge-length target for vertex 4, off
    // the SAME pre-pass positions `applySmoothLoopPasses` will read.
    float w3 = 1.0f / (orig4 - orig3).length;
    float w5 = 1.0f / (orig4 - orig5).length;
    Vec3 expectedMean = (orig3 * w3 + orig5 * w5) * (1.0f / (w3 + w5));

    Vec3[] beforeAll = m.vertices.dup;
    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    t.applySmoothLoopPasses(1);

    // (1) Interior vertex 4 relaxed to the independently-computed
    // inverse-edge-length midpoint (X/Z) AND lies ON the background plane
    // (perp distance to the surface ~0 — nearest-FOOT re-snap, not a
    // camera-ray one).
    assert(abs(m.vertices[4].x - expectedMean.x) < 1e-4f
        && abs(m.vertices[4].z - expectedMean.z) < 1e-4f,
        format("interior vertex 4 must relax to the inverse-edge-length midpoint's X/Z; "
             ~ "expected (%f,_,%f), got %s", expectedMean.x, expectedMean.z, m.vertices[4]));
    assert(abs(m.vertices[4].y - planeY) < 1e-3f,
        format("interior vertex 4 must land ON the background plane (y~=%f); got y=%f",
               planeY, m.vertices[4].y));

    // (2) F1 (⚠️ F1 RESOLVED, "концы стоят на месте"): BOTH open-chain
    // endpoints (3, 5) are byte-unchanged — held fixed, no relax, no re-snap.
    assert(m.vertices[3] == orig3, "F1: open-chain endpoint 3 must be byte-unchanged");
    assert(m.vertices[5] == orig5, "F1: open-chain endpoint 5 must be byte-unchanged");

    // (3) Non-loop vertices (everything except 3,4,5) are byte-unchanged —
    // the "only loop vertices move" contract, dedicated assertion over
    // every index NOT in the gathered moving-set.
    foreach (vi; 0 .. m.vertices.length) {
        bool inLoop = (vi == 3 || vi == 4 || vi == 5);
        if (inLoop) continue;
        assert(m.vertices[vi] == beforeAll[vi],
            format("non-loop vertex %d must be byte-unchanged", vi));
    }

    // (4) δ=0: topology counts unchanged.
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Smooth+Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real Smooth+Loop commit must record one undo entry");

    // (5) Undo restores exactly.
    history.undo();
    assert((m.vertices[3] - orig3).length < 1e-6f
        && (m.vertices[4] - orig4).length < 1e-6f
        && (m.vertices[5] - orig5).length < 1e-6f,
        "undo must restore every loop vertex's exact pre-relax position");
}

unittest { // applySmoothLoopPasses — a gesture that nets to ZERO movement
           // (the flat, un-perturbed grid: 3/4/5 are exactly colinear and
           // evenly spaced, so vertex 4's inverse-edge-length mean IS its own
           // current position, and no background source exists to re-snap
           // anything) is the ROUTINE no-op case — byte-identical mesh, NO
           // undo entry (mirrors `applySmoothPasses`'s own T7 no-op test).
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null);   // test-isolation, not a production call site

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.smoothLoopSeed_  = cast(int)seed;
    t.smoothLoopVerts_ = TopologyPenTool.uniqueRingVerts(&m, seed);

    auto before = MeshSnapshot.capture(m);
    t.applySmoothLoopPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "a flat/uniform grid with no background must be a byte-identical no-op");
    assert(!history.canUndo(), "a no-op Smooth+Loop gesture must record NO undo entry");
}

// ---------------------------------------------------------------------------
// onSmoothLoopRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p12_smoothloop_plan.md "RMB-dispatch resolution":
// a miss must fall through to Shift+Ctrl+RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onSmoothLoopRmbDown(eHit, vts);
    assert(consumed, "a press on a valid edge midpoint must arm and consume");
    assert(t.smoothLoopArmed_, "must arm the Smooth+Loop gesture");
    assert(t.smoothLoopVerts_ == [3u, 4u, 5u],
        format("armed moving-set must be the in-line row chain; got %s", t.smoothLoopVerts_));

    t.smoothLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onSmoothLoopRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.smoothLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch, Smooth+Loop is NOT `kMinDragPx`-gated (a
// stationary click still applies its one pass, mirroring the whole-mesh
// Smooth gesture's own Risk-5 discipline, P8) — driven through the extracted
// `smoothLoopUp` release-side helper directly (arming state set up
// directly, mirroring P10/P11's own click-vs-drag tests) so the commit path
// itself is under test. Phase-2 input-dispatch migration
// (doc/topopen_input_dispatch_phase2_plan.md, Testing Category C): calls
// `smoothLoopUp` directly rather than `onMouseButtonUp` — see the Slide
// MIN-DRAG test's own doc comment for why.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null);   // test-isolation: force the deterministic no-bg no-op path

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.smoothLoopSeed_    = cast(int)seed;
    t.smoothLoopArmed_   = true;
    t.smoothLoopStartX_  = 50;
    t.smoothLoopStartY_  = 50;
    t.smoothLoopCurX_    = 50;
    t.smoothLoopCurY_    = 50;
    t.smoothLoopDragPx_  = 0.0f;
    t.smoothLoopVerts_   = TopologyPenTool.uniqueRingVerts(&m, seed);

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 50; e.y = 50;   // release exactly at the press pixel -- a stationary click
    VectorStack vts;
    bool consumed = t.smoothLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a stationary-click release must still consume the event");
    assert(!t.smoothLoopArmed_, "release must disarm Smooth+Loop regardless of outcome");
    // The flat/uniform grid + no background is a byte-identical no-op (the
    // SAME rig as `applySmoothLoopPasses`'s own no-op unittest above) -- this
    // additionally proves the RIGHT-branch dispatch applies exactly ONE pass
    // for a click, with no `kMinDragPx` gate suppressing it.
    assert(after.vertices == before.vertices,
        "a stationary click on a no-op rig must leave the mesh byte-identical");
    assert(!history.canUndo(), "a no-op click must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Smooth+Loop arm
// (doc/topopen_p12_smoothloop_plan.md "Undo factory"): an external history
// navigation mid-drag must not leave a dangling seed/moving-set for the
// eventual (now stale) release to commit against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.smoothLoopArmed_   = true;
    t.smoothLoopSeed_    = 3;
    t.smoothLoopVerts_   = [3u, 4u, 5u];
    t.smoothLoopDragPx_  = 42.0f;

    t.resyncSession();

    assert(!t.smoothLoopArmed_, "resyncSession must clear the armed Smooth+Loop gesture");
    assert(t.smoothLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.smoothLoopVerts_.length == 0, "resyncSession must clear the moving-set");
    assert(t.smoothLoopDragPx_ == 0.0f, "resyncSession must reset the drag-distance accumulator");
}

// ---------------------------------------------------------------------------
// toolStateJson — Smooth+Loop fields (doc/topopen_p12_smoothloop_plan.md
// Phase 4): reports the armed seed + moving-set size + derived pass count,
// for Tier-C tests to assert without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["smoothLoopArmed"].type == JSONType.false_, "must start with no armed Smooth+Loop");
    assert(cast(int)s0["smoothLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["smoothLoopVertCount"].integer == 0, "must start with an empty moving-set");
    assert(cast(int)s0["smoothLoopPassCount"].integer == 1, "a fresh (unarmed) tool reports pass count 1");

    t.smoothLoopArmed_  = true;
    t.smoothLoopSeed_   = 7;
    t.smoothLoopVerts_  = [1u, 2u, 3u, 4u];
    t.smoothLoopDragPx_ = 45.0f;   // 1 + floor(45/20) = 3 passes

    auto s1 = t.toolStateJson();
    assert(s1["smoothLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["smoothLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["smoothLoopVertCount"].integer == 4, "must report the gathered moving-set size");
    assert(cast(int)s1["smoothLoopPassCount"].integer == 3,
        "must report the SAME pass-count derivation onMouseButtonUp will apply");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P12, doc/topopen_p12_smoothloop_plan.md): drives the REAL Shift+Ctrl+RMB
// gesture end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `TopoPenAction.SmoothLoop` -> `onSmoothLoopRmbDown`), a motion event (drag-distance
// accumulation), and the RIGHT-button release branch (->
// `applySmoothLoopPasses`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `applySmoothLoopPasses` cases above already cover, nor just the
// dispatch wiring, as `onSmoothLoopRmbDown`'s own test above covers) — all
// still pure-`dub test`. Reuses the SAME perturbed-vertex-4 rig as the
// Tier-B relax test above, so the real dispatch path is proven to reach the
// identical relax+re-snap outcome.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)(KMOD_SHIFT | KMOD_CTRL));
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;
    m.vertices[4] = Vec3(0.3f, 2.0f, 0.0f);   // off the flat grid's own colinear midpoint

    Viewport vp = view.viewport();

    enum float planeY = -0.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);
    scope(exit) setBackgroundSnapSources(null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    Vec3 orig3 = m.vertices[3], orig5 = m.vertices[5];

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "Shift+Ctrl+RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.smoothLoopArmed_, "the real dispatch must have armed Smooth+Loop");
    assert(t.smoothLoopVerts_ == [3u, 4u, 5u], "the real dispatch must have gathered the row chain");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 8; eMove.y = my - 5;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");
    assert(t.smoothLoopDragPx_ > 0.0f, "motion must accumulate drag distance");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 8; eUp.y = my - 5;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.smoothLoopArmed_, "release must disarm Smooth+Loop regardless of outcome");

    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Smooth+Loop must never change topology (δ=0)");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    // F1: both open-chain endpoints stay exactly put; only the interior
    // vertex (4) moved and landed on the background plane.
    assert(m.vertices[3] == orig3, "F1: endpoint 3 must be byte-unchanged via the real dispatch");
    assert(m.vertices[5] == orig5, "F1: endpoint 5 must be byte-unchanged via the real dispatch");
    assert(abs(m.vertices[4].y - planeY) < 0.05f,
        format("interior vertex 4 must land ON the background plane (y~=%f); got y=%f",
               planeY, m.vertices[4].y));

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Mid-edge Split (doc/topopen_midedge_split_plan.md) — Tier-B unittests + the
// MANDATORY dispatch e2e.
//
// `facesMatchCyclic` is a `version(unittest)` test-only helper (mirrors
// `makeHoverIndicatorTestViewport`'s own module-local convention above):
// unlike the existing `splitFaceByVertices`/`commitSplit` unittests (which
// pin one FIXED winding via literal `f[] == [...]`, since the kernel's scan
// order happens to match a hand-derived array for THEIR specific rigs), this
// extension's composed kernel call (`addEdgePoint` then
// `splitFaceByVertices`) produces a face that is only correct up to CYCLIC
// ROTATION — verified directly against the real kernels: a quad
// `[0,1,2,3]` split on edge `(2,3)` at the newly-inserted vertex `4` yields
// one half literally as `[4,3,0]`, a rotation of the intuitive `[0,4,3]`
// (never a reflection — the chord split never reverses winding direction).
// ---------------------------------------------------------------------------
version (unittest) private bool facesMatchCyclic(const(uint)[] actual, const(uint)[] expected) {
    if (actual.length != expected.length) return false;
    size_t n = actual.length;
    if (n == 0) return true;
    foreach (start; 0 .. n) {
        bool ok = true;
        foreach (k; 0 .. n) {
            if (actual[(start + k) % n] != expected[k]) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #1 (quad edge-target at the click's OWN
// fraction, f=0.3 — NOT the midpoint): proves the composition inserts M at
// the requested fraction (in `edges[E][0]->[1]` direction) and chord-splits
// the shared face. Δv=+1, Δe=+2 (E -> 2 sub-edges, +1 chord), Δf=+1.
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
    m.addVertex(Vec3(0, 0, 0));   // 0 A
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    uint E = m.edgeIndex(2, 3);
    assert(E != uint.max, "setup: edge (2,3) must exist");

    t.commitSplitOnEdge(0, cast(int)E, 0.3f);

    assert(m.vertices.length == 5, "commitSplitOnEdge: Δv=+1 (M inserted)");
    assert(m.edges.length    == 6, "commitSplitOnEdge: Δe=+2 (E->2 sub-edges, +1 chord)");
    assert(m.faces.length    == 2, "commitSplitOnEdge: Δf=+1");

    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (facesMatchCyclic(f[], [0u, 1u, 2u, 4u])) hasF1 = true;
        if (facesMatchCyclic(f[], [0u, 4u, 3u]))     hasF2 = true;
    }
    assert(hasF1, "commitSplitOnEdge: expected quad [0,1,2,M]");
    assert(hasF2, "commitSplitOnEdge: expected tri [0,M,3]");

    Vec3 expectedM = m.vertices[2] + (m.vertices[3] - m.vertices[2]) * 0.3f;
    assert((m.vertices[4] - expectedM).length < 1e-5f,
        "commitSplitOnEdge: M must land at lerp(v2,v3,0.3) — edges[E][0]->[1] direction");

    assert(history.canUndo(), "a real mid-edge split must record one undo entry");
}

// ---------------------------------------------------------------------------
// splitUp — Tier-B #2: "Split at the Middle" forces f=0.5 regardless of the
// release click's own position along the edge. Drives the REAL `splitUp`
// (armed manually, mirroring the shipped commitSplit-adjacent tests' own
// direct-call convention) with a release pixel biased toward v3 (f=0.65,
// NOT the midpoint) — if the option were ignored, `ratioOnSegment` would
// resolve f~=0.65, not 0.5.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);
    t.splitAtMiddle_ = true;

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(-0.3f, 0, -0.3f));  // 0 A
    m.addVertex(Vec3( 0.3f, 0, -0.3f));  // 1
    m.addVertex(Vec3( 0.3f, 0,  0.3f));  // 2
    m.addVertex(Vec3(-0.3f, 0,  0.3f));  // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // f=0.65 -- far enough from EITHER screen-projected endpoint (>kTopoPenSnapPx)
    // that `findSourceVertex`'s vertex-first snap never intercepts the release,
    // while still measurably off-center from the true midpoint (0.5).
    Vec3 releasePos = m.vertices[2] + (m.vertices[3] - m.vertices[2]) * 0.65f;
    ImVec2 rp;
    assert(TopologyPenTool.projectPt(releasePos, vp, rp), "setup: releasePos must project on-screen");

    t.splitArmed_      = true;
    t.splitSourceVert_ = 0;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)rp.x; eUp.y = cast(int)rp.y;
    bool consumed = t.splitUp(eUp, vts);
    assert(consumed, "splitUp must consume the release");

    assert(m.vertices.length == 5, "the option must still insert exactly one vertex");
    Vec3 expectedMid = (m.vertices[2] + m.vertices[3]) * 0.5f;
    assert((m.vertices[4] - expectedMid).length < 1e-4f,
        "splitAtMiddle_ must force M to the EXACT edge midpoint, ignoring the click's own "
      ~ "0.65 fraction");
    assert(history.canUndo(), "a real mid-edge split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #3: TRIANGLE edge-target, proving the insert
// isn't quad-only. tri [0,1,2], A=0, E=(1,2), f=0.5 -> two tris [0,1,M] +
// [0,M,2].
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
    m.addVertex(Vec3(0, 0, 0));   // 0 A
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(0, 1, 0));   // 2
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();

    uint E = m.edgeIndex(1, 2);
    assert(E != uint.max, "setup: edge (1,2) must exist");

    t.commitSplitOnEdge(0, cast(int)E, 0.5f);

    assert(m.vertices.length == 4, "triangle edge-target: Δv=+1");
    assert(m.edges.length    == 5, "triangle edge-target: Δe=+2");
    assert(m.faces.length    == 2, "triangle edge-target: Δf=+1");

    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (facesMatchCyclic(f[], [0u, 1u, 3u])) hasF1 = true;
        if (facesMatchCyclic(f[], [0u, 3u, 2u])) hasF2 = true;
    }
    assert(hasF1, "triangle edge-target: expected tri [0,1,M]");
    assert(hasF2, "triangle edge-target: expected tri [0,M,2]");
    assert(history.canUndo(), "a real mid-edge split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — Tier-B #4 (regression pin): the shipped vertex<->vertex
// Split is untouched by this extension — Δv=0, no mid-edge vertex is ever
// inserted on this path.
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

    t.commitSplit(0, 2);

    assert(m.vertices.length == 4, "vertex<->vertex split: Δv=0, unchanged by this extension");
    assert(m.faces.length    == 2, "vertex<->vertex split: still 2 faces");
    assert(history.canUndo());
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #5 (no-op): A is an endpoint of the target edge
// E -> `findEdgeSplitFace` rejects (degenerate chord) BEFORE any mutation ->
// byte-identical, no undo entry.
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

    uint E = m.edgeIndex(0, 1);   // A(=0) is THIS edge's own endpoint
    assert(E != uint.max);

    auto before = MeshSnapshot.capture(m);
    t.commitSplitOnEdge(0, cast(int)E, 0.5f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "A-on-E: must be a byte-identical no-op");
    assert(!history.canUndo(), "A-on-E: must record no undo entry");
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #6 (no-op): edge E is on a face that shares NO
// face with A (two fully disjoint quads) -> `findEdgeSplitFace` scans
// `facesAroundEdge(E)` and finds A nowhere -> byte-identical, no undo entry.
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
    m.addVertex(Vec3(0, 0, 0));   // 0 A
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addFace([0u, 1u, 2u, 3u]);  // F0 -- contains A

    m.addVertex(Vec3(5, 0, 0));   // 4
    m.addVertex(Vec3(6, 0, 0));   // 5
    m.addVertex(Vec3(6, 1, 0));   // 6
    m.addVertex(Vec3(5, 1, 0));   // 7
    m.addFace([4u, 5u, 6u, 7u]);  // F1 -- fully disjoint from F0
    m.buildLoops();

    uint E = m.edgeIndex(5, 6);   // an edge of F1, nowhere near A
    assert(E != uint.max);

    auto before = MeshSnapshot.capture(m);
    t.commitSplitOnEdge(0, cast(int)E, 0.5f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "cross-polygon: no face shares both A and E -> byte-identical no-op");
    assert(!history.canUndo(), "cross-polygon: must record no undo entry");
}

// ---------------------------------------------------------------------------
// splitUp — Tier-B #7 (no-op): release on empty space (neither a vertex nor
// an edge within `kTopoPenSnapPx`) stays the original clean no-op — the new
// edge branch must not fabricate a target out of nothing.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(0.2f, 0, 0));
    m.addVertex(Vec3(0.2f, 0.2f, 0));
    m.addVertex(Vec3(0, 0.2f, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto before = MeshSnapshot.capture(m);

    t.splitArmed_      = true;
    t.splitSourceVert_ = 0;
    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = 5; eUp.y = 5;   // far corner -- nothing projects anywhere near here
    bool consumed = t.splitUp(eUp, vts);
    assert(consumed, "splitUp must still consume the release even on a no-op");

    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "empty-space release: byte-identical no-op");
    assert(!history.canUndo(), "empty-space release: must record no undo entry");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #8: edge-split-then-undo restores the mesh
// exactly (counts + windings), mirroring `removeFaceAt`'s own undo test
// above.
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

    uint E = m.edgeIndex(2, 3);
    assert(E != uint.max);

    auto before = MeshSnapshot.capture(m);
    t.commitSplitOnEdge(0, cast(int)E, 0.5f);
    assert(history.canUndo(), "a real mid-edge split must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-split state, incl. the inserted vertex's removal");
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — BOWTIE/NON-MANIFOLD ROLLBACK (MANDATORY atomicity fix,
// doc/topopen_midedge_split_plan.md "MANDATORY atomicity fix" §3): vertex A
// is a non-manifold "pinch" vertex — it appears TWICE in the SAME face's
// winding (the face's two lobes, pinched together at A). `findEdgeSplitFace`
// correctly resolves this face as viable (A is present, and is not an
// endpoint of the target edge E), and `addEdgePoint` has ALREADY spliced M
// into that face's winding by the time `splitFaceByVertices` runs — but the
// chord-split kernel then finds THREE cut-vertex hits in that one face (A's
// two occurrences plus M, not the expected two), so it legitimately declines
// (n=0). This is the guard the MANDATORY fix exists for: the mesh must end
// up BYTE-IDENTICAL to its state before `addEdgePoint` ran, and NO undo
// entry may be recorded for the discarded partial mutation.
//
// (Empirically verified directly against the real kernels before writing
// this test — a face `[A,B,C,A,D,E]` with target edge `(D,E)` inserts M
// between D and E exactly as any other face would, and the subsequent
// `splitFaceByVertices(faceIdx, A, M)` call returns 0 — confirming this is
// a REACHABLE guard, not a hypothetical one.)
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
    m.addVertex(Vec3(0, 0, 0));    // 0 A (the pinch/bowtie vertex)
    m.addVertex(Vec3(1, 0, 0));    // 1 B
    m.addVertex(Vec3(1, 1, 0));    // 2 C
    m.addVertex(Vec3(-1, 0, 0));   // 3 D
    m.addVertex(Vec3(-1, 1, 0));   // 4 E
    // ONE bowtie face: A appears at positions 0 and 3 -- the two pinched
    // lobes A-B-C and A-D-E, sharing only vertex A.
    m.addFace([0u, 1u, 2u, 0u, 3u, 4u]);
    m.buildLoops();

    uint E = m.edgeIndex(3, 4);
    assert(E != uint.max, "setup: edge (D,E) must exist");

    auto before = MeshSnapshot.capture(m);

    t.commitSplitOnEdge(0, cast(int)E, 0.5f);

    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices
        && after.edges    == before.edges
        && after.faces    == before.faces,
        "bowtie: a chord-split failure AFTER addEdgePoint already mutated the mesh must roll "
      ~ "back to the EXACT pre-mutation state, not leave M stranded");
    assert(!history.canUndo(),
        "bowtie: a rolled-back (partial-mutation) gesture must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplitOnEdge — Tier-B #10 (watertight neighbour): edge (2,3) is
// shared by TWO quads, F0 (containing A=0) and F1 (on the far side). Only F0
// gets chord-split; F1 keeps its own single face but gains M as an extra
// (collinear) winding corner — proving `addEdgePoint`'s splice into EVERY
// incident face keeps the mesh watertight across the seam, not just inside
// the targeted polygon.
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
    m.addVertex(Vec3(0, 0, 0));   // 0 A
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addVertex(Vec3(1, 2, 0));   // 4
    m.addVertex(Vec3(0, 2, 0));   // 5
    m.addFace([0u, 1u, 2u, 3u]);   // F0 -- contains A
    m.addFace([3u, 2u, 4u, 5u]);   // F1 -- shares edge (2,3), reversed winding
    m.buildLoops();

    uint E = m.edgeIndex(2, 3);
    assert(E != uint.max);
    size_t vBefore = m.vertices.length;

    t.commitSplitOnEdge(0, cast(int)E, 0.5f);

    assert(m.vertices.length == vBefore + 1, "watertight: Δv=+1 exactly");
    assert(m.faces.length == 3,
        "watertight: F0 splits into 2, F1 stays 1 (now a pentagon) -> 3 total");

    uint M = cast(uint)vBefore;   // the newly appended vertex index
    bool hasF0Quad = false, hasF0Tri = false, hasF1Pent = false;
    foreach (f; m.faces) {
        if (facesMatchCyclic(f[], [0u, 1u, 2u, M]))     hasF0Quad = true;
        if (facesMatchCyclic(f[], [0u, M, 3u]))         hasF0Tri  = true;
        if (facesMatchCyclic(f[], [3u, M, 2u, 4u, 5u])) hasF1Pent = true;
    }
    assert(hasF0Quad, "watertight: F0's quad half [0,1,2,M]");
    assert(hasF0Tri,  "watertight: F0's tri half [0,M,3]");
    assert(hasF1Pent, "watertight: F1 must gain M as a collinear pentagon corner");

    // Both new sub-edges of the old (2,3) seam must still be shared by
    // exactly 2 faces each (one from each side) — the mesh is watertight,
    // not torn open at the seam.
    uint e2M = m.edgeIndex(2, M);
    uint eM3 = m.edgeIndex(M, 3);
    assert(e2M != uint.max && eM3 != uint.max, "watertight: both new sub-edges must exist");
    int n2M = 0, nM3 = 0;
    foreach (fi; m.facesAroundEdge(e2M)) ++n2M;
    foreach (fi; m.facesAroundEdge(eM3)) ++nM3;
    assert(n2M == 2, "watertight: edge (2,M) must have exactly 2 incident faces");
    assert(nM3 == 2, "watertight: edge (M,3) must have exactly 2 incident faces");

    assert(history.canUndo(), "a real mid-edge split must record one undo entry");
}

// ---------------------------------------------------------------------------
// splitUp — vertex-first precedence (doc/topopen_midedge_split_plan.md
// "Vertex-first precedence is correct + free"): a release NEAR an existing
// corner (at its own projected pixel, well within `kTopoPenSnapPx`) must
// resolve via `findSourceVertex` and take the UNCHANGED vertex<->vertex path
// (`commitSplit`, Δv=0) — never the new mid-edge insert — even though that
// same corner is also an endpoint of an edge `findRingSeedEdge` could
// otherwise resolve.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(-0.3f, 0, -0.3f));   // 0 A
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

    ImVec2 p2;
    assert(TopologyPenTool.projectPt(m.vertices[2], vp, p2));

    t.splitArmed_      = true;
    t.splitSourceVert_ = 0;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)p2.x; eUp.y = cast(int)p2.y;   // exactly v2's own pixel
    bool consumed = t.splitUp(eUp, vts);
    assert(consumed, "splitUp must consume the release");

    assert(m.vertices.length == 4,
        "a release on an existing corner must take the vertex path (Δv=0), not insert a mid-edge M");
    assert(m.faces.length == 2, "the diagonal split must still happen");
    assert(history.canUndo(), "a real vertex-target split must record one undo entry");
}

// ---------------------------------------------------------------------------
// params() / toolStateJson — Mid-edge Split option schema
// (doc/topopen_midedge_split_plan.md Deliverable #4): the sticky
// `splitMiddle` Param round-trips through both the schema (for the
// `tool.attr`/form binding) and the introspection JSON (for HTTP tests),
// defaulting OFF, and survives `resyncSession()` (a mode toggle, not
// per-gesture arm state — matches the `tool_activate_sticky_clobber`
// precedent).
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps.length == 2, "mesh.topoPen must expose the splitMiddle option plus the Fill-mode "
                          ~ "dropdown (task 0477 continuation, doc/topopen_fill_plan.md) — the "
                          ~ "`mode` Param is APPENDED, never a full-replace");
    assert(ps[0].name == "splitMiddle");
    assert(ps[0].kind == Param.Kind.Bool);
    assert(ps[0].default_.b == false, "splitMiddle must default OFF");
    assert(ps[0].bptr is &t.splitAtMiddle_, "the Param must bind directly to splitAtMiddle_");

    auto s0 = t.toolStateJson();
    assert(s0["splitAtMiddle"].type == JSONType.false_, "must start OFF");

    t.splitAtMiddle_ = true;
    auto s1 = t.toolStateJson();
    assert(s1["splitAtMiddle"].type == JSONType.true_, "must report a live toggle");

    t.resyncSession();
    assert(t.splitAtMiddle_,
        "splitAtMiddle_ must survive resyncSession() (external history navigation) — it is a "
      ~ "sticky mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// params() — Fill mode dropdown schema (task 0477 continuation,
// doc/topopen_fill_plan.md Phase 1, MANDATORY opponent fix #1): the `mode`
// IntEnum Param round-trips through the schema (for the `tool.attr`/form
// binding), defaults to Draw, and survives `resyncSession()` (a sticky mode
// toggle, not per-gesture arm state — matches `splitAtMiddle_`'s own
// precedent, pinned in the block immediately above).
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[1].name == "mode");
    assert(ps[1].kind == Param.Kind.IntEnum);
    assert(ps[1].default_.i == cast(int)PenMode.Draw, "mode must default to Draw");
    assert(ps[1].iePtr is cast(int*)&t.penMode_, "the Param must bind directly to penMode_");
    assert(ps[1].intEnumValues.length == 2, "exactly Draw + Fill are exposed in V1");
    assert(ps[1].intEnumValues[0].wireTag == "draw");
    assert(ps[1].intEnumValues[1].wireTag == "fill");

    assert(t.penMode_ == PenMode.Draw, "must start in Draw mode");

    t.penMode_ = PenMode.Fill;
    t.resyncSession();
    assert(t.penMode_ == PenMode.Fill,
        "penMode_ must survive resyncSession() (external history navigation) — it is a sticky "
      ~ "mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseButtonUp — MANDATORY DISPATCH for the mid-edge
// Split extension (doc/topopen_midedge_split_plan.md Phase 3): drives the
// REAL dispatch path end-to-end — plain-MMB down on vertex A (0), plain-MMB
// up on the screen-space MIDPOINT of the opposite edge (2,3), never a vertex
// — mirroring the shipped vertex<->vertex e2e test above exactly (same rig,
// same camera), so a regression that broke `splitUp`'s new edge branch
// (rather than just `commitSplitOnEdge`'s own mutation, which the Tier-B
// cases above already cover) would be caught here.
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
    // Scaled up from the shipped vertex e2e's -0.3..0.3 rig to keep the
    // projected edge (2,3) comfortably longer than 2*kTopoPenSnapPx at this
    // camera distance — its screen-space MIDPOINT must land clearly outside
    // the vertex-snap radius of EITHER endpoint, or the release would
    // wrongly resolve via the (unchanged) vertex path instead of this
    // extension's edge path.
    m.addVertex(Vec3(-0.8f, 0, -0.8f));   // 0 A
    m.addVertex(Vec3( 0.8f, 0, -0.8f));   // 1
    m.addVertex(Vec3( 0.8f, 0,  0.8f));   // 2
    m.addVertex(Vec3(-0.8f, 0,  0.8f));   // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    float sx0, sy0, ndcZ;
    assert(projectToWindowFull(m.vertices[0], vp, sx0, sy0, ndcZ),
        "setup: v0 must project on-screen for this rig");

    // Release pixel = the screen-space midpoint of the projected edge (2,3)
    // — NOT either endpoint's own pixel, so it never snaps to a vertex.
    ImVec2 p2, p3;
    assert(TopologyPenTool.projectPt(m.vertices[2], vp, p2));
    assert(TopologyPenTool.projectPt(m.vertices[3], vp, p3));
    int midX = cast(int)((p2.x + p3.x) * 0.5f), midY = cast(int)((p2.y + p3.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_MIDDLE;
    eDown.x = cast(int)sx0; eDown.y = cast(int)sy0;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "plain-MMB press on a vertex must be consumed");
    assert(t.splitArmed_, "plain-MMB press on a vertex must arm Split");
    assert(t.splitSourceVert_ == 0, "must arm the pressed vertex (0) as the split source");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = midX; eUp.y = midY;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "plain-MMB release on the edge midpoint must be consumed");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");

    assert(m.vertices.length == 5,
        "the real dispatch path must have inserted the mid-edge vertex");
    assert(m.faces.length == 2, "the real dispatch path must have split the quad into 2 faces");
    assert(m.edges.length == 6,
        "the real dispatch path must have added 2 sub-edges + 1 chord edge");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    // Loose tolerance (unlike T1's tight 1e-5 direct-call check): the release
    // pixel is the midpoint of the projected SCREEN segment, which is only
    // an approximation of the projected WORLD midpoint under perspective —
    // `ratioOnSegment`'s own re-projection (screenPointToRay ->
    // closestPointOnSegmentToRay) recovers a `t` close to, but not exactly,
    // 0.5 at this rig's camera angle. This dispatch test's job is proving
    // the real onMouseButtonDown/Up path REACHES `commitSplitOnEdge` with a
    // sane mid-span fraction — the exact-fraction contract is already
    // pinned tightly by the Tier-B direct-call tests above (T1/T3).
    Vec3 expectedMid = (m.vertices[2] + m.vertices[3]) * 0.5f;
    assert((m.vertices[4] - expectedMid).length < 0.2f,
        "the inserted vertex must land reasonably near the edge (2,3) midpoint");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md) — Tier-B
// tests. The `params()`/`mode` schema round-trip is already pinned right
// after the mid-edge Split option schema block above (mirroring
// `splitAtMiddle_`'s own precedent); everything below exercises
// `findFillCell`/`commitFill`/the dropdown-routed dispatch/the hover
// preview.
//
// Shared test idiom: every rig captures the target cell's OWN vertex array
// via `m.faces[i].dup` BEFORE deleting it, so the expected corner SET is
// read off the mesh itself rather than hand-derived from grid arithmetic
// (which this feature's own planning drift already showed is error-prone —
// see doc/topopen_fill_plan.md's line-citation warning).
// ---------------------------------------------------------------------------

version (unittest) private bool fillCellSetEq(const(uint)[] a, const(uint)[] b) {
    import std.algorithm : canFind;
    if (a.length != b.length) return false;
    foreach (v; a) if (!canFind(b, v)) return false;
    return true;
}

// F1 — interior single-cell gap: `makeGridPlane(3)` (16v, 9f, 24e) minus
// its CENTER face (i=1,j=1 — fully interior, all 4 sides border after
// removal). `findFillCell` must resolve exactly that cell from a cursor at
// its centroid; `commitFill` must cap it with ONE quad, reusing the 4
// existing corner verts (Δv=0), winding consistent with a neighbour (never
// a hardcoded axis — `makeGridPlane`'s cells wind -Y despite the source
// comment, doc's empirical finding #2). Also covers F7 (undo restores the
// exact pre-fill V/E/F).
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);   // 4x4=16 verts, 3x3=9 quads, 24 edges
    assert(m.vertices.length == 16 && m.faces.length == 9);
    uint[] cellVerts = m.faces[4].dup;   // center cell (i=1,j=1) -- fully interior
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 8, "setup: the center face must be removed");
    assert(m.vertices.length == 16, "setup: no vertex is deleted (keepOrphans)");
    auto beforeFill = MeshSnapshot.capture(m);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectPt(centroid, vp, cpix),
        "setup: the gap cell's centroid must project on-screen");

    auto cell = t.findFillCell(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillCell must resolve the one interior gap cell");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillCell must return exactly the gap cell's own 4 corners");

    t.commitFill(cell);

    assert(m.faces.length == 9, "commitFill: the gap must be capped with exactly ONE new face");
    assert(m.vertices.length == 16, "commitFill: Δv=0 -- the cell's own corners are reused");
    assert(history.canUndo(), "a real fill must record one undo entry");

    // Locate the new face (the one whose vertex set == the gap cell's) and
    // check winding CONSISTENCY with a neighbour -- never a hardcoded
    // axis/sign: for every edge of the new face, any neighbour face
    // sharing that (undirected) edge must traverse it in the OPPOSITE
    // direction.
    int newFi = -1;
    foreach (fi, f; m.faces) {
        if (f.length == 4 && fillCellSetEq(f[], cellVerts)) { newFi = cast(int)fi; break; }
    }
    assert(newFi >= 0, "the newly-added face must contain exactly the cell's 4 verts");
    auto newFace = m.faces[newFi];
    foreach (i; 0 .. newFace.length) {
        uint u = newFace[i], v = newFace[(i + 1) % newFace.length];
        bool foundOpposite = false;
        foreach (fi, f; m.faces) {
            if (cast(int)fi == newFi) continue;
            foreach (k; 0 .. f.length) {
                uint a = f[k], b = f[(k + 1) % f.length];
                assert(!(a == u && b == v),
                    "the new face's winding must NOT match a neighbour's own direction on a "
                  ~ "shared edge (task 0477 continuation: makePolygonFromVerts autoOrient)");
                if (a == v && b == u) foundOpposite = true;
            }
        }
        assert(foundOpposite, "every edge of the new face must have a neighbour traversing it "
                             ~ "in the opposite direction");
    }

    // F7: undo restores the exact pre-fill V/E/F.
    history.undo();
    auto afterUndo = MeshSnapshot.capture(m);
    assert(afterUndo.vertices == beforeFill.vertices && afterUndo.edges == beforeFill.edges
        && afterUndo.faces == beforeFill.faces,
        "undo must restore the mesh byte-identical to its pre-fill state");
}

// F2 — single-cell notch: a hand-built 2-row x 4-col quad grid (3x5=15
// verts) with the MIDDLE row-0 cell (index 1 -- touches neither the west
// nor east mesh perimeter, so it opens exactly ONE mouth, north) removed.
// 3 of its 4 sides become border edges (the 4th, north, drops to 0
// incident faces -- a floating "mouth" edge, kept by
// `deleteFacesByMask(keepFloatingEdges:true)` -- the SAME contract the
// tool's own `removeFaceAt` always uses, so this is the FAITHFUL shape of
// a notch this tool itself would ever produce; not counted by
// `isEdgeBorder`'s n==1 predicate). `findFillCell` must still resolve the
// correct 4-vertex cell from the 3 surviving border edges, and
// `commitFill` must attach the new face to that already-present floating
// mouth edge (0 incident faces -> 1 -- Δe=0, the edge record itself is
// REUSED, never duplicated).
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m;
    float[5] xs = [0.0f, 1.0f, 2.0f, 5.0f, 6.0f];
    float[3] zs = [0.0f, 1.0f, 2.0f];
    uint[5][3] idx;
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 5)
            idx[i][j] = m.addVertex(Vec3(xs[j], 0, zs[i]));
    foreach (i; 0 .. 2)
        foreach (j; 0 .. 4)
            m.addFace([idx[i][j], idx[i][j + 1], idx[i + 1][j + 1], idx[i + 1][j]]);
    m.buildLoops();
    assert(m.faces.length == 8, "setup: the 2x4 grid must have 8 faces");

    uint[] cellVerts = m.faces[1].dup;   // middle row-0 cell -- neither west nor east corner
    auto mask = new bool[](m.faces.length);
    mask[1] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 7, "setup: the notch cell must be removed");
    assert(m.vertices.length == 15, "setup: no vertex is deleted (keepOrphans)");
    size_t edgesBefore = m.edges.length;

    // Identify the mouth edge -- the one side of the cell with 0 incident
    // faces right after its own face was removed.
    int mouthEdge = -1;
    foreach (k; 0 .. 4) {
        uint ei = m.edgeIndex(cellVerts[k], cellVerts[(k + 1) % 4]);
        assert(ei != uint.max, "setup: every side of the removed cell must still exist as an "
                             ~ "edge (deleteFacesByMask keeps floating edges)");
        int nf = 0; foreach (fi; m.facesAroundEdge(ei)) ++nf;
        if (nf == 0) { mouthEdge = cast(int)ei; break; }
    }
    assert(mouthEdge >= 0, "setup: exactly one side of the notch cell must be a floating "
                         ~ "(0-face) mouth");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectPt(centroid, vp, cpix),
        "setup: the notch cell's centroid must project on-screen");

    auto cell = t.findFillCell(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillCell must resolve the notch cell from its 3 border edges");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillCell must return exactly the notch cell's own 4 corners");

    t.commitFill(cell);

    assert(m.faces.length == 8, "commitFill: the notch must be capped with exactly ONE new face");
    assert(m.vertices.length == 15, "commitFill: Δv=0 -- the cell's own corners are reused");
    assert(m.edges.length == edgesBefore,
        "commitFill: the mouth is an ALREADY-PRESENT floating edge -- Δe=0, it is reused, "
      ~ "never duplicated");
    int nfAfter = 0; foreach (fi; m.facesAroundEdge(cast(uint)mouthEdge)) ++nfAfter;
    assert(nfAfter == 1,
        "commitFill: the mouth edge must gain exactly one incident face (the new fill face)");
    assert(history.canUndo(), "a real fill must record one undo entry");
}

// F3 — two SEPARATE (non-adjacent) single-cell gaps in the same mesh, one
// click fills ONE cell (owner decision 2: "one cell per click").
//
// NOTE on scope (empirical finding, not a hand-wave): TWO MUTUALLY-ADJACENT
// missing cells sharing one now-gone middle edge (e.g. a "2-cell-wide"
// notch or interior gap) were tried here first, in THREE independent
// constructions (a uniform perimeter pair, an asymmetric-width perimeter
// pair, and an asymmetric-height interior pair) — all three produced a
// BOGUS "skip-through" candidate (a degenerate, 3-collinear-point quad
// spanning corners of BOTH missing cells) instead of resolving to EITHER
// true individual cell. Root cause: the shared "waist" vertex between two
// mutually-adjacent missing cells loses ALL border-edge connectivity (its
// own mouth-facing side AND the now-fully-gone shared inner edge are both
// non-border), isolating it from `findFillCell`'s border-adjacency graph
// entirely, so the true single-cell candidate is never even generated for
// either side to compete on area with the bogus one. This contradicts
// doc/topopen_fill_plan.md Risk R1's claim ("PROBE-checked on paper for
// ...interior 2-cell... the true cell always wins on area") — falls under
// the SAME doc's own AF-1 "known V1 limitation, not a blocker" umbrella,
// but the concrete manifestation (a mis-shaped bogus fill, not a clean
// no-op) is a genuine finding worth flagging upstream. Scoped OUT of this
// test accordingly; this test instead verifies owner decision 2's core
// promise ("one click, one cell, never both") on two gaps that ARE cleanly
// resolvable in V1: two separate single-cell interior gaps, far enough
// apart that neither's reconstruction can be confused with the other's.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(5);   // 6x6=36 verts, 5x5=25 quads
    assert(m.faces.length == 25);
    uint[] cellA = m.faces[6].dup;    // interior cell (i=1,j=1)
    uint[] cellB = m.faces[18].dup;   // a SEPARATE, non-adjacent interior cell (i=3,j=3)
    auto mask = new bool[](m.faces.length);
    mask[6] = true; mask[18] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 23, "setup: both gap cells must be removed");
    assert(m.vertices.length == 36, "setup: no vertex is deleted (keepOrphans)");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centA = (m.vertices[cellA[0]] + m.vertices[cellA[1]]
                + m.vertices[cellA[2]] + m.vertices[cellA[3]]) * 0.25f;
    Vec3 centB = (m.vertices[cellB[0]] + m.vertices[cellB[1]]
                + m.vertices[cellB[2]] + m.vertices[cellB[3]]) * 0.25f;
    ImVec2 pixA, pixB;
    assert(TopologyPenTool.projectPt(centA, vp, pixA));
    assert(TopologyPenTool.projectPt(centB, vp, pixB));

    auto foundA = t.findFillCell(cast(int)pixA.x, cast(int)pixA.y, vp);
    assert(foundA.length == 4, "a cursor over gap A must resolve exactly that cell");
    assert(fillCellSetEq(foundA, cellA),
        "must resolve ONLY gap A's own 4 corners, never gap B's");

    auto foundB = t.findFillCell(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundB.length == 4, "a cursor over gap B must resolve exactly that cell");
    assert(fillCellSetEq(foundB, cellB),
        "must resolve ONLY gap B's own 4 corners, never gap A's");

    // One click fills ONE cell -- the other remains an untouched gap,
    // fillable by a SECOND click (owner decision 2: "one cell per click").
    t.commitFill(foundA);
    assert(m.faces.length == 24, "commitFill must add exactly ONE face for gap A");

    auto foundBAfter = t.findFillCell(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundBAfter.length == 4, "gap B must still be found as a gap after gap A alone was filled");
    assert(fillCellSetEq(foundBAfter, cellB));

    t.commitFill(foundBAfter);
    assert(m.faces.length == 25, "commitFill must add exactly ONE more face for gap B");
    assert(m.vertices.length == 36, "both fills together are Δv=0 -- every corner is reused");
    assert(history.canUndo());
}

// F6 — no-op over a solid face / empty area. `makeGridPlane(3)` left FULLY
// INTACT (no gap anywhere): a cursor at the centroid of a genuinely
// INTERIOR face (i=1,j=1 -- every edge shared by 2 faces, none border)
// must resolve `[]`, and a cursor far off the mesh entirely must too.
// `commitFill([])` must be a clean no-op (no undo entry, mesh
// byte-identical).
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);   // fully intact -- no gap anywhere
    uint[] solidVerts = m.faces[4].dup;   // the same "center" cell F1 removes, kept HERE
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;
    auto beforeAll = MeshSnapshot.capture(m);

    auto vp = makeGridPlaneTestViewport();

    // (a) cursor at a genuinely interior, already-faced cell's centroid.
    Vec3 solidCentroid = (m.vertices[solidVerts[0]] + m.vertices[solidVerts[1]]
                         + m.vertices[solidVerts[2]] + m.vertices[solidVerts[3]]) * 0.25f;
    ImVec2 spix;
    assert(TopologyPenTool.projectPt(solidCentroid, vp, spix));
    auto cellOverFace = t.findFillCell(cast(int)spix.x, cast(int)spix.y, vp);
    assert(cellOverFace.length == 0,
        "findFillCell must return [] over an already-faced INTERIOR cell (no border edges "
      ~ "nearby to seed a candidate from)");

    // (b) cursor far outside the mesh entirely.
    auto cellOverEmpty = t.findFillCell(-99999, -99999, vp);
    assert(cellOverEmpty.length == 0, "findFillCell must return [] over empty area");

    // (c) commitFill([]) / a miss must be a clean no-op.
    t.commitFill(cellOverFace);
    t.commitFill(null);
    auto afterAll = MeshSnapshot.capture(m);
    assert(afterAll.vertices == beforeAll.vertices && afterAll.edges == beforeAll.edges
        && afterAll.faces == beforeAll.faces,
        "commitFill must leave the mesh byte-identical on a miss/empty cell");
    assert(!history.canUndo(), "a miss/empty cell must record NO undo entry");
}

// F5/F9 — dropdown routing: plain-LMB is a NO-OP for Draw's place/move path
// when Fill owns it, and vice versa. dropdown=Draw (default) must arm
// place/move exactly like pre-Fill behavior; dropdown=Fill must fill
// immediately (commit-on-DOWN) and arm NOTHING.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectPt(centroid, vp, cpix));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)cpix.x; e.y = cast(int)cpix.y;

    // dropdown = Draw (default): plain-LMB over the gap centroid must arm
    // place/move -- NEVER Fill -- byte-identical to pre-Fill behavior.
    assert(t.penMode_ == PenMode.Draw, "must start in Draw mode");
    int facesBefore = cast(int)m.faces.length;
    bool consumed = t.onPlainLmbDown(e, vts);
    assert(consumed, "plain-LMB must always be consumed");
    assert(t.placeArmed_ || t.moveArmed_,
        "Draw mode must arm place/move, exactly like pre-Fill behavior");
    assert(cast(int)m.faces.length == facesBefore, "Draw mode must not mutate the mesh on DOWN");
    t.placeArmed_ = false; t.moveArmed_ = false; t.grabbedVert_ = -1;

    // dropdown = Fill: the SAME press must fill the cell and arm NOTHING.
    t.penMode_ = PenMode.Fill;
    consumed = t.onPlainLmbDown(e, vts);
    assert(consumed, "plain-LMB must always be consumed");
    assert(!t.placeArmed_ && !t.moveArmed_,
        "Fill mode must never arm place/move -- it owns plain-LMB entirely");
    assert(cast(int)m.faces.length == facesBefore + 1,
        "Fill mode's plain-LMB press must commit the fill immediately (commit-on-DOWN)");
    assert(history.canUndo());
}

// F8 — hover preview state: `fillCell_` equals the cell (as a set) after
// the Fill-mode motion compute; `null` in Draw mode, off any gap, and when
// ANY gesture is armed (mode ghosts win, mirroring `hoverOverMesh_`'s own
// precedence rule -- MANDATORY opponent fix #2's sibling gate, not nested
// inside `hoverOverMesh_`).
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectPt(centroid, vp, cpix));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent e;
    e.x = cast(int)cpix.x; e.y = cast(int)cpix.y;

    // Draw mode (default): the preview must stay empty even directly over
    // a gap cell -- Fill's hatch is gated on the mode.
    t.onMouseMotion(e, vts);
    assert(t.fillCell_.length == 0, "Draw mode must never populate the Fill preview");

    // Fill mode: the SAME motion must resolve exactly the gap cell.
    t.penMode_ = PenMode.Fill;
    t.onMouseMotion(e, vts);
    assert(t.fillCell_.length == 4, "Fill mode must resolve the gap cell under the cursor");
    assert(fillCellSetEq(t.fillCell_, cellVerts));

    // A gesture armed on ANY button must clear the preview even in Fill mode.
    t.dragArmed_ = true;
    t.onMouseMotion(e, vts);
    assert(t.fillCell_.length == 0, "an armed gesture must take precedence over the Fill preview");
    t.dragArmed_ = false;

    // Off any gap (far away) -> null, even in Fill mode.
    SDL_MouseMotionEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    t.onMouseMotion(eFar, vts);
    assert(t.fillCell_.length == 0, "a cursor far from every gap must clear the preview");
}
