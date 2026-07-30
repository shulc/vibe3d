module tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : hypot, SQRT2;

import tool;
import mesh                : Mesh, GpuMesh;
import math               : Vec3, Viewport, projectToWindowFull, closestOnSegment2D,
                             screenPointToRay, closestPointOnSegmentToRay, dot,
                             pointInPolygon2D, rayPlaneIntersect;
import shader              : Shader;
import operator            : VectorStack;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket, SnapPacket;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import constraint           : resolveHoverTarget, topoPenPressPickPx,
                              topoPenSnapAcceptPx, topoPenSnapGatherPx,
                              kTopoPenSnapAuto, closestPointOnMeshes;
import snap                  : backgroundSourcesSnapshot;
import tools.edit.smooth_relax : RelaxVec3, RelaxTopology, deriveBoundary, relaxPasses;
import viewcache            : VertexCache, EdgeCache, FaceBoundsCache;
import bvh_pick              : BvhPick;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot              : MeshSnapshot;
import display_sync         : refreshDisplay;
import change_bus            : MeshEditScope;
import params                : Param, IntEnumEntry, wireTagForValue;
import tool_input            : ToolAction, PassThrough, InputPhase, InputButton,
                                InputMod, ResetScope, InputBinding,
                                resolveToolAction, toButton, toMods;
import drag                  : planeDragDelta;
import eventlog               : queryMouse;

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

/// Factories the tool calls ONCE PER REMOVE GESTURE THAT LATCHED AN EDGE /
/// A VERTEX (task 0494) — a TWELFTH and THIRTEENTH dedicated factory. Remove
/// is one gesture with THREE primitives, chosen by the class of the element
/// the press latched, and they are three different mesh operations: a
/// polygon-latched press deletes one face (`TopoPenRemoveFactory`), an
/// edge-latched press DISSOLVES (merging the two incident polygons into one),
/// a vertex-latched press merges the whole incident fan and drops the vertex.
/// Same `MeshEditScope.Geometry` on all three, but reusing
/// `topoPenRemoveEditFactory` for the other two would bake "a face was
/// removed" onto an op that removed no face — the undo history, the event-log
/// replay and any macro built on it would all describe the wrong edit. Wired
/// with `wireName="mesh.topoPen_removeedge"` / `"mesh.topoPen_removevertex"`
/// at the app.d construction site, mirroring `topoPenRemoveEditFactory`.
alias TopoPenRemoveEdgeFactory   = MeshSessionEdit delegate();
alias TopoPenRemoveVertexFactory = MeshSessionEdit delegate();

/// The four connectivity outcomes a drag-from-vertex build gesture can
/// resolve to on release, per `classifySource` below (capture-verified,
/// doc/topopen_p3_plan.md's mechanism table). `None` covers BOTH "the
/// source vertex's topology doesn't qualify" and the measured one-shot
/// ceiling (a hub already embedded in a quad classifies degree-2/non
/// -triangle-hub, which is exactly `None`).
private enum BuildCase { None, Edge, Tri, Quad }

/// The Mode dropdown's value set (task 0483, doc/tasks/work/0483-topopen-mode-set.md) —
/// a 1:1 transcription of the reference tool's own `mode` enum: the SAME
/// eight values, in the reference dropdown's own order, under the reference's
/// own wire tags and labels (doc-mined from the reference catalog's
/// per-option `UserName`/`Desc` table; the value set and the `move` default
/// are both live-measured — toolcards/topology_pen/attr_defaults_capture.md,
/// PRIVATE).
///
/// Every value here names a gesture this tool ALREADY implements on a
/// modifier chord (`kTopoPenBindings` below); the dropdown is the second way
/// to reach it — it decides what an UNMODIFIED LMB press does, exactly as the
/// reference's own per-option `Desc` strings spell out ("Move element
/// position. (RMB plus Edge Loop)", "Duplicate vertex or edge. (Shift-LMB,
/// Shift-RMB plus Edge Loop)", ...). The chords stay ABSOLUTE overrides: they
/// resolve to their own action whatever the dropdown says, which is what makes
/// the modeless chord workflow and the dropdown workflow coexist.
///
/// `Point` is the mode this tool used to call "Draw": place a vertex on an
/// empty-space click, behave as `Move` on a click that lands on geometry
/// (the reference's own wording for its Point option). The old vibe3d-only
/// `Draw` tag is GONE — it named a mode the reference does not have.
///
/// A tool-wide sticky dropdown, not per-gesture arm state — mirrors
/// `addLoopMiddle_`'s precedent (must survive `resyncSession()`, an external
/// history navigation).
private enum PenMode { Move, Duplicate, Remove, Split, AddLoop, Point, Fill, Smooth }

// Why a Ctrl+LMB Slide press did not arm — see `slideDecline_`'s own doc
// comment for the full rationale. `None` also covers "the press armed
// normally", so a consumer reads `slideDeclineReason == "none"` as "no decline
// to explain". A plain enum + `final switch` in `toolStateJson` (the
// `BuildCase`/`HoverTargetKind` precedent) rather than an `IntEnumEntry` table:
// this is not a `Param`, nothing parses it back, and the `final switch` keeps
// the token mapping compile-time exhaustive.
private enum SlideDecline { None, NoEdge, NoContinuation }

/// Which kind of element a Move-family press grabbed (task 0484). Resolved
/// by PROXIMITY, in this order — vertex within `topoPenPressPickPx`, else edge
/// within the same radius, else the face under the cursor — so the closest
/// thing to the cursor is what moves, which is how the reference's Move mode
/// reads to a user ("hover it, drag it").
///
/// `Vertex` keeps P4's measured law verbatim: the grabbed vertex goes TO the
/// cursor's own constrained surface hit. `Edge`/`Face` cannot follow that law
/// (there is no single point to place), so they take the law this tool
/// already measured for its OTHER multi-vertex gesture, Move Loop: one shared
/// SCREEN delta applied to every vertex of the set, each re-snapped to the
/// background surface independently, a per-vertex miss keeping its original
/// position (`perVertexTargets`).
///
/// `None` = nothing armed. A plain enum + `final switch` rather than an
/// `IntEnumEntry` table, for the `BuildCase`/`SlideDecline` reason: it is not
/// a `Param`, nothing parses it back, and the exhaustive switch makes a new
/// member a compile error at every consumer.
private enum MoveElem { None, Vertex, Edge, Face }

// ---------------------------------------------------------------------------
// PenGesture / kTopoPenBindings — the declarative (button, modifier) ->
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
// hard-blocked by `resolveToolAction` itself, above any table scan).
// `kTopoPenBindings` is a 1:1 transcription of ALL 12 slots (task 0499):
// the last two — Ctrl+RMB and Shift+Ctrl+MMB — carry no documentation
// because the reference's dispatcher has no case for them, and a MEASURED
// capture (`toolcards/topology_pen/dragweld_unlabeled_slots_capture.md`,
// PRIVATE) showed what that means concretely: the event falls through to
// "run whatever the Mode dropdown currently holds", with no loop gather, no
// slide constraint and no smoothing of its own. Under the 0487 chord model
// that is expressible as data — a row that overrides NOTHING — so they are
// now WIRED rows rather than absent ones. Every Alt combo stays absent, so
// `resolveToolAction` answers `PassThrough` for it and `dispatchInput`
// returns `false` without ever calling `onToolAction`.
// ---------------------------------------------------------------------------
private enum PenGesture {
    PlaceOrMove,      // place-on-empty OR grab-move (resolved at Down)
    Build,            // drag-build / duplicate from a vertex (P3)
    Slide,            // edge slide (P7)
    Smooth,           // whole-mesh smooth (P8)
    Split,            // vertex-to-vertex split (P9)
    AddLoop,          // add loop cut (P6)
    Remove,           // remove-on-DOWN face delete (P5); Up is a no-op
    MoveLoop,         // move edge loop (P10)
    DupLoop,          // duplicate edge loop (P11)
    SmoothLoop,       // loop-restricted smooth (P12)
}

// ---------------------------------------------------------------------------
// The CHORD model (task 0487) — a chord is an OVERRIDE PAIR, not a gesture.
//
// This table used to map each (button, modifier) slot straight onto a gesture,
// as if the tool had ten independent gestures. It does not. A live capture of
// the Duplicate slot (`toolcards/topology_pen/dragweld_dupedge_loopscope_capture.md`,
// PRIVATE) measured the actual shape: a chord contributes an optional MODE
// override and an optional FLAG override, and the result feeds the ONE mode
// dispatcher the Mode dropdown already drives. Two independent captures agree:
//
//   * Shift+RMB stores a LITERAL 1 into the effective loop flag and never
//     reads the attribute (`loop=false` and `loop=true` came back
//     bit-identical), while Shift+LMB DOES read it (1 quad vs 3 on one seed).
//     So "forced" vs "from the user" is a real, measured distinction.
//   * The two formerly-undocumented slots (Ctrl+RMB, Shift+Ctrl+MMB) were
//     measured executing "whatever the Mode dropdown currently is"
//     (`status.yaml: unlabeled_slots`) — which only makes sense if a chord
//     leaves the mode alone unless it overrides it. Task 0499 WIRES those two
//     as exactly that: a row that overrides nothing.
//
// Why it matters beyond tidiness: under the old table a chord could not
// compose with the dropdown at all, so plain RMB was hard-wired to move-loop
// and stayed move-loop with the dropdown on Remove. Under the measured model
// it is "the dropdown's mode, with the loop forced on".
//
// PROVENANCE IS PER COLUMN, and the difference is load-bearing — do not level
// it out. `[M]` = measured on this tool; `[D]` = doc-derived from the
// reference catalog's own per-option `Desc` strings (the same source that gave
// the 10-slot grid, and which every ported gesture already rests on).
// Nothing here is inferred from a third slot's behavior.
private enum ModeOv : ubyte { FromUser, Duplicate, Split, AddLoop, Remove, Smooth }
private enum FlagOv : ubyte { FromUser, ForceOn }

private struct ChordOv {
    ModeOv mode  = ModeOv.FromUser;
    FlagOv loop  = FlagOv.FromUser;
    FlagOv slide = FlagOv.FromUser;
}

/// All 12 wired slots, named by the CHORD they are — the gesture each one ends
/// up running is a RESULT now, not an identity. `dispatchInput` only ever moves
/// this id around, so it doubles as the index into `kChordOv` below.
///
/// APPEND ONLY. This enum is simultaneously the index into the fixed-length
/// `kChordOv` below, so inserting a value in the MIDDLE silently rebinds every
/// row after it instead of failing to compile — the same footgun the positional
/// `setUndoBindings` parameters carry. `CtrlRmb`/`ShiftCtrlMmb` (task 0499) are
/// therefore last, in wiring order, not grouped with their own buttons.
private enum TopoPenChord : ToolAction {
    Lmb, ShiftLmb, CtrlLmb, ShiftCtrlLmb,
    Mmb, ShiftMmb, CtrlMmb,
    Rmb, ShiftRmb, ShiftCtrlRmb,
    CtrlRmb, ShiftCtrlMmb,
}

/// What each chord overrides. Indexed by `TopoPenChord`.
///
/// Every row reproduces this tool's previous behavior when the dropdown sits
/// at its default (`move`, both flags off) — that was the acceptance condition
/// for this refactor, so the only outcomes that CHANGE are the ones the
/// capture pins: a chord composing with a NON-default dropdown.
private immutable ChordOv[12] kChordOv = [
    // Lmb          — the base slot: the dropdown, verbatim.                    [M]
    ChordOv(ModeOv.FromUser,  FlagOv.FromUser, FlagOv.FromUser),
    // ShiftLmb     — Duplicate, and it READS the loop flag.                    [M]
    ChordOv(ModeOv.Duplicate, FlagOv.FromUser, FlagOv.FromUser),
    // CtrlLmb      — the dropdown, with Edge SLIDE forced: the reference
    //                documents Ctrl in Move mode as doing exactly what the
    //                Edge Slide option does. Ctrl+RMB was MEASURED not to
    //                force slide (it ran a plain move), so this is asymmetric
    //                on purpose and is NOT generalised to "Ctrl forces slide". [D]
    ChordOv(ModeOv.FromUser,  FlagOv.FromUser, FlagOv.ForceOn),
    // ShiftCtrlLmb — Smoothing.                                               [D]
    ChordOv(ModeOv.Smooth,    FlagOv.FromUser, FlagOv.FromUser),
    // Mmb          — Split.                                                   [D]
    ChordOv(ModeOv.Split,     FlagOv.FromUser, FlagOv.FromUser),
    // ShiftMmb     — Add Loop.                                                [D]
    ChordOv(ModeOv.AddLoop,   FlagOv.FromUser, FlagOv.FromUser),
    // CtrlMmb      — Remove.                                                  [D]
    ChordOv(ModeOv.Remove,    FlagOv.FromUser, FlagOv.FromUser),
    // Rmb          — the dropdown, loop FORCED. The row the old table got
    //                wrong: it read as an absolute move-loop.                 [M]
    ChordOv(ModeOv.FromUser,  FlagOv.ForceOn,  FlagOv.FromUser),
    // ShiftRmb     — Duplicate, loop FORCED (the literal-1 store).            [M]
    ChordOv(ModeOv.Duplicate, FlagOv.ForceOn,  FlagOv.FromUser),
    // ShiftCtrlRmb — Smoothing "plus Edge Loop".                              [D]
    ChordOv(ModeOv.Smooth,    FlagOv.ForceOn,  FlagOv.FromUser),
    // CtrlRmb      — overrides NOTHING: the dropdown's mode, the user's own
    //                loop flag, the user's own slide flag. The reference's
    //                dispatcher has no case for this slot, and the capture
    //                measured the fall-through directly: dropdown=Move ran a
    //                plain per-vertex move (whose own mesh delta carries the
    //                already-decoded "empty selection ⇒ whole mesh" signature,
    //                not a slide constraint), dropdown=Split ran the split, in
    //                lockstep. NOT "like the base slot of its own button":
    //                plain RMB forces the loop and this one does not, and it
    //                does NOT force slide either — which is precisely the
    //                measurement `CtrlLmb`'s asymmetric slide row rests on, so
    //                these two rows have to be read together.               [M]
    ChordOv(ModeOv.FromUser,  FlagOv.FromUser, FlagOv.FromUser),
    // ShiftCtrlMmb — the same unbound-slot fall-through, measured on the other
    //                button and refuting "probably inert": dropdown=Move ran a
    //                per-vertex move where the base MMB slot in the very same
    //                condition ran Split, so this row cannot be "like the base
    //                slot of its own button" either.                        [M]
    ChordOv(ModeOv.FromUser,  FlagOv.FromUser, FlagOv.FromUser),
];

/// Which physical button a chord slot belongs to. Taken from the SLOT rather
/// than from the event, so a synthetic press whose `button` field was never
/// filled in (every direct-call unittest in this file) still books its gesture
/// against the right button.
private InputButton chordButton(TopoPenChord c) {
    final switch (c) {
    case TopoPenChord.Lmb: case TopoPenChord.ShiftLmb:
    case TopoPenChord.CtrlLmb: case TopoPenChord.ShiftCtrlLmb:
        return InputButton.Left;
    case TopoPenChord.Mmb: case TopoPenChord.ShiftMmb: case TopoPenChord.CtrlMmb:
    case TopoPenChord.ShiftCtrlMmb:
        return InputButton.Middle;
    case TopoPenChord.Rmb: case TopoPenChord.ShiftRmb: case TopoPenChord.ShiftCtrlRmb:
    case TopoPenChord.CtrlRmb:
        return InputButton.Right;
    }
}

/// The mode a chord's override names. `FromUser` never reaches here.
private PenMode modeOfOverride(ModeOv m) {
    final switch (m) {
    case ModeOv.FromUser:  return PenMode.Move;   // unreachable; caller checks first
    case ModeOv.Duplicate: return PenMode.Duplicate;
    case ModeOv.Split:     return PenMode.Split;
    case ModeOv.AddLoop:   return PenMode.AddLoop;
    case ModeOv.Remove:    return PenMode.Remove;
    case ModeOv.Smooth:    return PenMode.Smooth;
    }
}

/// LEFT rows are `ResetScope.AllButtons` — reproduces the LEFT-button trio's
/// own top-of-handler `resetAllGestureArms()` call, now wired through
/// `dispatchInput`'s `onInputResetAll()` hook instead. MIDDLE/RIGHT rows stay
/// the default `SelfButton` — each mode's own narrow self-reset is what closes
/// a same-slot re-press hazard for those buttons, exactly as today (see
/// `resetAllGestureArms`'s own doc comment for why MIDDLE/RIGHT deliberately
/// do NOT get a full reset: a chord on those buttons can legitimately coexist
/// with a held LEFT drag).
///
/// The two rows task 0499 added (Ctrl+RMB, Shift+Ctrl+MMB) are MIDDLE/RIGHT
/// rows and take the same default `SelfButton` — `AllButtons` there would
/// change the neighbouring gestures' reset behavior rather than port these two.
///
/// Ctrl+RMB has a visible PRICE outside this tool and it is deliberate: an
/// un-consumed RMB press falls through to the application's own RMB lasso
/// select (`source/app.d`, "give the ACTIVE tool first crack at RMB"), so
/// binding the slot hands Ctrl+RMB to the pen while the pen is active. It is
/// the same fall-through plain RMB already lives with: `dispatchInput` returns
/// this tool's own Down verdict, so a Ctrl+RMB press the pen DECLINES (nothing
/// grabbable under the cursor) still reaches the lasso.
private immutable InputBinding[] kTopoPenBindings = [
    InputBinding(InputButton.Left,   InputMod.None,                   TopoPenChord.Lmb,          ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Shift,                  TopoPenChord.ShiftLmb,     ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Ctrl,                   TopoPenChord.CtrlLmb,      ResetScope.AllButtons),
    InputBinding(InputButton.Left,   InputMod.Shift | InputMod.Ctrl,  TopoPenChord.ShiftCtrlLmb, ResetScope.AllButtons),
    InputBinding(InputButton.Middle, InputMod.None,                   TopoPenChord.Mmb),
    InputBinding(InputButton.Middle, InputMod.Shift,                  TopoPenChord.ShiftMmb),
    InputBinding(InputButton.Middle, InputMod.Ctrl,                   TopoPenChord.CtrlMmb),
    InputBinding(InputButton.Right,  InputMod.None,                   TopoPenChord.Rmb),
    InputBinding(InputButton.Right,  InputMod.Shift,                  TopoPenChord.ShiftRmb),
    InputBinding(InputButton.Right,  InputMod.Shift | InputMod.Ctrl,  TopoPenChord.ShiftCtrlRmb),
    InputBinding(InputButton.Right,  InputMod.Ctrl,                   TopoPenChord.CtrlRmb),
    InputBinding(InputButton.Middle, InputMod.Shift | InputMod.Ctrl,  TopoPenChord.ShiftCtrlMmb),
];

// ---------------------------------------------------------------------------
// kTopoPenBindings — exhaustive resolver-grid pin. A single pure,
// camera-free regression guard covering EVERY (button, modifier) combo this
// tool's grid can see — replaces the 7 scattered `resolveGestureSlot` guards
// the pre-Phase-2 classifier used to need (Ctrl+MMB/Shift+MMB/Ctrl+LMB/
// plain-MMB/plain-RMB/Shift+RMB/Shift+Ctrl+RMB), consolidated into ONE table
// so a bad merge that silently drops or misroutes a row is caught here
// rather than by 7 separate best-effort pins. All 12 slots of the grid now
// resolve to their own chord id (task 0499 wired the last two, Ctrl+RMB and
// Shift+Ctrl+MMB); every Alt-held combo resolves to `PassThrough` (Alt is
// hard-blocked by `resolveToolAction` itself, above the table scan — this
// pin also proves that holds for THIS tool's table).
// ---------------------------------------------------------------------------
unittest {
    // The 10 wired slots, each resolving to its own CHORD id (task 0487 —
    // the id names the chord now; which GESTURE it runs is resolved later
    // from the chord's override plus the user's dropdown/flags).
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.None)
        == TopoPenChord.Lmb, "plain LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift)
        == TopoPenChord.ShiftLmb, "Shift+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Ctrl)
        == TopoPenChord.CtrlLmb, "Ctrl+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlLmb, "Shift+Ctrl+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.None)
        == TopoPenChord.Mmb, "plain MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift)
        == TopoPenChord.ShiftMmb, "Shift+MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Ctrl)
        == TopoPenChord.CtrlMmb, "Ctrl+MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.None)
        == TopoPenChord.Rmb, "plain RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift)
        == TopoPenChord.ShiftRmb, "Shift+RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlRmb, "Shift+Ctrl+RMB");
    // The 2 slots the reference's dispatcher has no case for — WIRED (task
    // 0499) as rows that override nothing, after being measured executing the
    // dropdown's own mode. They used to answer `PassThrough` here.
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Ctrl)
        == TopoPenChord.CtrlRmb, "Ctrl+RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlMmb, "Shift+Ctrl+MMB");

    // Every chord belongs to the button its own slot names — the mapping the
    // dispatch books a gesture against, taken from the SLOT so a synthetic
    // press with no `button` field still lands on the right one.
    assert(chordButton(TopoPenChord.Lmb)          == InputButton.Left);
    assert(chordButton(TopoPenChord.ShiftCtrlLmb) == InputButton.Left);
    assert(chordButton(TopoPenChord.Mmb)          == InputButton.Middle);
    assert(chordButton(TopoPenChord.CtrlMmb)      == InputButton.Middle);
    assert(chordButton(TopoPenChord.Rmb)          == InputButton.Right);
    assert(chordButton(TopoPenChord.ShiftCtrlRmb) == InputButton.Right);
    assert(chordButton(TopoPenChord.CtrlRmb)      == InputButton.Right);
    assert(chordButton(TopoPenChord.ShiftCtrlMmb) == InputButton.Middle);

    // The override table itself — the measured half stated as assertions, so a
    // future edit that levels the FlagOv distinction away fails here.
    assert(kChordOv[TopoPenChord.Rmb].loop       == FlagOv.ForceOn,
        "plain RMB FORCES the loop flag (measured: the literal-1 store)");
    assert(kChordOv[TopoPenChord.ShiftRmb].loop  == FlagOv.ForceOn,
        "Shift+RMB FORCES the loop flag (measured bit-identical across loop=false/true)");
    assert(kChordOv[TopoPenChord.ShiftLmb].loop  == FlagOv.FromUser,
        "Shift+LMB READS the loop flag (measured: 1 quad vs 3 on one seed)");
    assert(kChordOv[TopoPenChord.Lmb].mode       == ModeOv.FromUser,
        "the base slot never overrides the dropdown");
    assert(kChordOv[TopoPenChord.Rmb].mode       == ModeOv.FromUser,
        "plain RMB runs the DROPDOWN's mode — it is not an absolute move-loop");
    assert(kChordOv[TopoPenChord.ShiftLmb].mode  == ModeOv.Duplicate);
    assert(kChordOv[TopoPenChord.ShiftRmb].mode  == ModeOv.Duplicate);
    assert(kChordOv[TopoPenChord.CtrlLmb].slide  == FlagOv.ForceOn,
        "Ctrl+LMB forces Edge Slide");
    assert(kChordOv[TopoPenChord.Rmb].slide      == FlagOv.FromUser,
        "and Ctrl+RMB was measured NOT forcing slide, so the rule is not 'Ctrl forces slide'");

    // The 2 rows task 0499 wired: they override NOTHING, on all three columns.
    // Stated column by column because each one pins a separate half of the
    // measurement, and each one is a different way to get this wrong:
    //   * mode  — the slot is not "the base slot of its own button" (base MMB
    //             forces Split, base RMB forces the loop);
    //   * loop  — it is not an RMB-family forced loop either;
    //   * slide — the measured "Ctrl+RMB ran a plain move, no slide" is the
    //             very reason `CtrlLmb`'s slide row is NOT generalised to
    //             "Ctrl forces slide". Level this one out and that asymmetry
    //             loses its evidence.
    foreach (c; [TopoPenChord.CtrlRmb, TopoPenChord.ShiftCtrlMmb]) {
        assert(kChordOv[c].mode  == ModeOv.FromUser,
            "an unbound slot runs the DROPDOWN's mode, not its own button's base mode");
        assert(kChordOv[c].loop  == FlagOv.FromUser,
            "an unbound slot does not force the loop flag");
        assert(kChordOv[c].slide == FlagOv.FromUser,
            "an unbound slot does not force Edge Slide (measured on Ctrl+RMB)");
    }

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
// P7 adds SLIDE on the **Ctrl+LMB** overlay slot (`PenGesture.Slide`,
// doc/topopen_p7_slide_plan.md, V1-scope Option B — EDGE grab): a press
// picks the nearest primary-layer EDGE (`findRingSeedEdge`, reused verbatim
// from P6) and arms a constrained slide for each grabbed endpoint whose rail
// resolves (`continuationNeighbor`) — that endpoint slides COLINEARLY along
// its rail. The rail is the endpoint's unique remaining incident edge at
// valence-2 (raw `edgeNeighbors` scan — P3 KILLER-1), and at valence>2 the
// POLYGON-CONTINUATION edge: the one continuing the grabbed edge around its
// own polygon, which supersedes V1's blanket hold-fixed. An endpoint whose
// rail does not resolve — valence-1, or valence>2 with zero / 2+ distinct
// continuation candidates — is still HELD FIXED; see
// `continuationNeighbor`'s own comment for the enumerated open cases, which
// are deferred rather than tie-broken (a guessed direction is worse than no
// motion), and for the CORRECTION to this rule's original "drag-independent"
// justification.
//
// The slide PARAMETERISATION is now the measured law, replacing V1's
// absolute / world-projective / `[0,1]`-clamped `ratioOnSegment` fraction:
//
//     k      = argmax_j |delta[j]|        (`dominantAxisDelta`)
//     w      = unit(neighbor - endpoint)  the rail, AWAY from the grabbed edge
//     offset = -delta[k] * w              (`slideEndpointPos`)
//
// applied from the pre-gesture positions, with the LAST evaluation committed
// (not a sum), both endpoints sharing the scalar, and NO `[0,1]` clamp — a
// vertex passes through and beyond its rail neighbour. Four measured
// divergences closed at once (delta rather than absolute cursor; axis
// extraction rather than a world-projective segment fraction; unbounded;
// and the sign, which was inverted in half the tested configurations). The
// fifth, the pixel->world MAGNITUDE CURVE, stays ours by decision — see
// `slideDeltaFromDrag` for the measurement, the reason it was frozen, and
// the sanity band our gain sits in. The whole set is pinned by the
// "Slide law — REFERENCE PARITY CONFORMANCE" unittest at the bottom of this
// module.
// Commit is deferred to release (`onMouseButtonUp`, `commitSlide`) — a
// direct Position-only kernel write (`m.vertices[i]=pos` +
// `commitChange(Position)`, mirroring `applyMoveTargets`, extended to up to 2
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
// (`PenGesture.AddLoop`, doc/topopen_p6_addloop_plan.md): a press picks
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
// P5 adds REMOVE on the **Ctrl+MMB** overlay slot (`PenGesture.Remove`,
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
// P4 adds MOVE on the plain (unmodified) **LMB** slot (`PenGesture.PlaceOrMove`) —
// the dispatch backbone's base behavior, every modifier an overlay on top of
// it (capture-verified, doc/topopen_p4_plan.md "The MEASURED mechanism").
// Design A: BOTH Move and Place resolve at press time (`onPlainLmbDown`,
// reusing P3's `findSourceVertex`, topoPenPressPickPx threshold, over the PRIMARY
// layer only) and land at the RELEASE event's own CONS-snapped hit: landing
// on geometry arms Move (`moveArmed_` + the moving set, `armMoveElement`);
// landing on empty background arms Place (`placeArmed_`, the same P2
// `placeVertexAt` path, deferred to release). A release landing back within
// eps of the moving set's CURRENT positions (stationary click, or an
// all-on-surface no-move) is a clean no-op — no mutation, no undo entry,
// mirroring P3's degenerate-release convention.
//
// Task 0484 widened Move on both axes, per the reference's own description of
// it ("moves an element as you drag it, but it remains fixed against the
// background surface as it slides around ... useful in editing vertices,
// edges, and polygons"):
//   * WHAT — a press grabs the nearest element by proximity (vertex, else
//     edge, else the face under the cursor) and moves ITS whole vertex set;
//     an edge/face press used to be declined outright (0482).
//   * WHEN — the mesh is written LIVE on every motion event, so the geometry
//     itself deforms under the cursor instead of a ghost line predicting it.
//     Still exactly ONE undo entry: `moveBefore_` is captured at arm time and
//     `finishMove` records the (before, after) pair at release, which is the
//     `MeshSessionEdit` contract. Where the gesture LANDS is unchanged — the
//     release recomputes its targets from its own pixel, as it always did.
// A single grabbed vertex keeps P4's measured law verbatim (go to the
// cursor's constrained hit); a multi-vertex element takes the law this tool
// already measured for Move Loop (one shared screen delta, per-vertex
// re-snap). Both write through `applyMoveTargets` — a direct
// `m.vertices[i]=pos` + `m.commitChange(Position)`, no new mesh.d seam,
// recorded through its own `topoPenMoveEditFactory`/wireName
// "mesh.topoPen_move" (OBJ-3 FOLDED).
//
// P3 adds the DRAG-FROM-VERTEX build gesture on the **Shift+LMB** overlay
// slot (doc-mined gesture grid, cross-confirmed by 3 independent reference
// sources — toolcards/topology_pen/gesture_map.md, PRIVATE; the "Duplicate"
// overlay while the tool would otherwise be in its Move mode; correction to
// the initial mode-less draft, applied BEFORE this phase shipped — see
// `PenGesture`/`kTopoPenBindings` above): a Shift+LMB press landing on an
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
// slots) is a named, inert stub for later phases — see `PenGesture`'s own
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

    // --- Remove's OTHER two primitives (task 0494): the same gesture, but the
    // press latched an edge / a vertex rather than a polygon. Own factories,
    // own wire names — see their aliases. ---
    TopoPenRemoveEdgeFactory   removeEdgeEditFactory_;
    TopoPenRemoveVertexFactory removeVertexEditFactory_;

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

    // --- Move-mode ELEMENT grab + LIVE drag (task 0484). Two extensions of
    // the P4 vertex grab above, both owner-observed on the reference and
    // spelled out by its own Move description ("moves an element as you drag
    // it, but it remains fixed against the background surface as it slides
    // around — useful in editing vertices, EDGES, and POLYGONS"):
    //
    //   1. WHAT can be grabbed. A press resolves the element under the
    //      cursor by proximity — vertex within `topoPenPressPickPx`, else edge
    //      within the same radius, else the face under the cursor — and
    //      `moveVerts_` becomes THAT element's vertices (1 / 2 / N). Before
    //      this, an edge or face press was declined outright
    //      (doc/tasks/done/0482-topopen-move-nonvertex.md deliberately left
    //      it unimplemented rather than invent one).
    //
    //   2. WHEN the mesh changes. The move is applied LIVE on every motion
    //      event, not only at release — the geometry deforms under the
    //      cursor instead of a ghost line predicting it. `moveBefore_` is
    //      captured ONCE at arm time and the whole drag records exactly ONE
    //      undo entry at release: the `MeshSessionEdit` contract ("mutates
    //      the mesh freely while the user drags ... records this command
    //      holding (before, after) snapshots so the entire gesture is a
    //      single undo step").
    //
    // The FINAL positions still come from the RELEASE event's own pixel, as
    // they always did — the live writes are a preview made of real geometry,
    // and they never change where the gesture lands. That is what keeps this
    // a superset of the P4 law rather than a replacement for it.
    //
    // `moveBase_` is the moving set's positions AT ARM TIME and every target
    // is computed from it, never from the live (already-moved) positions —
    // otherwise each motion event would compound onto the previous one and
    // the element would race away from the cursor.
    //
    // `moveDirty_` records whether any live write actually happened, so a
    // press-with-no-motion stays the byte-identical no-op it has always been
    // (no snapshot pair, no undo entry, no GPU churn). Cleared — like every
    // arm above — by `resetAllGestureArms()`; `deactivate()` finalizes a
    // still-dirty drag first, so switching tools mid-gesture cannot leave an
    // un-undoable mutation behind.
    MoveElem     moveElem_  = MoveElem.None;
    uint[]       moveVerts_;
    Vec3[]       moveBase_;
    int          moveStartX_, moveStartY_;
    bool         moveDirty_ = false;
    MeshSnapshot moveBefore_;

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

    // Add Loop "at the Middle" option (reference parity,
    // doc/tasks/work/0480-topopen-addloop-middle.md): forces the loop cut to
    // the exact 50% of every crossed edge instead of the click-derived
    // ratio. A STICKY tool-wide toggle, NOT per-gesture arm state — read
    // live at commit time by `addLoopFrac` (never cached) and deliberately
    // absent from `resetAllGestureArms()`/`resyncSession()`, which clear the
    // per-gesture arm bools on every fresh press / external history
    // navigation (matches the `tool_activate_sticky_clobber` precedent:
    // sticky options are set before `activate()`/arm-reset and must not be
    // clobbered by either). Default OFF, so the shipped click-derived
    // behaviour remains the default. The reference pairs this option with a
    // numeric "position" attribute and greys THAT out while this is on; our
    // "position" is the live cursor ratio (`addLoopRatio_`), so the same
    // pairing shows up here as `addLoopFrac` ignoring the cursor entirely.
    bool addLoopMiddle_ = false;

    // --- P7 Slide session state (topology_pen.d,
    // doc/topopen_p7_slide_plan.md, V1-scope Option B). Armed on a Ctrl+LMB
    // press that lands on a primary-layer edge with at least one slidable
    // endpoint (`onCtrlLmbDown`); `slideEndA_`/`slideEndB_` are the grabbed
    // edge's two endpoint vertex indices, `slideNbrA_`/`slideNbrB_` are each
    // endpoint's OWN rail neighbor — its unique remaining incident edge at
    // valence-2, its polygon-continuation edge at valence>2 (`-1` when the
    // rail doesn't resolve and the endpoint is held fixed; see
    // `continuationNeighbor`).
    //
    // `slideAnchor_` is the grabbed edge's midpoint FROZEN AT PRESS — the
    // plane anchor the pointer drag is converted against (`slideDeltaFromDrag`);
    // freezing it keeps the conversion stable while the ghost moves.
    // `slideDeltaK_` is the law's ONE signed scalar, shared by BOTH endpoints
    // (only the rail direction differs between them — see `slideEndpointPos`),
    // recomputed press->cursor on every motion event (`onMouseMotion`) and
    // again at release (`slideUp` -> `commitSlide`). It replaces the pair of
    // `[0,1]` per-rail fractions V1 tracked; there is no bounded fraction in
    // this law at all.
    //
    // Cleared by `onMouseButtonUp` on commit/no-op and by `resyncSession` on
    // an external history navigation, exactly like the P3/P4/P6 arm state
    // above.
    int   slideSeed_  = -1;
    bool  slideArmed_ = false;
    int   slideStartX_, slideStartY_;
    int   slideEndA_ = -1, slideEndB_ = -1;
    int   slideNbrA_ = -1, slideNbrB_ = -1;
    Vec3  slideAnchor_ = Vec3(0, 0, 0);
    float slideDeltaK_ = 0.0f;

    // Slide DECLINE diagnostics (doc/tasks/work/0482-topopen-move-nonvertex.md
    // item 3 follow-up) — read-only observability, no behaviour change.
    //
    // `onCtrlLmbDown` declines on two structurally DIFFERENT outcomes that were
    // indistinguishable from outside, because both leave `slideArmed_ == false`
    // and `slideSeed_ == -1` (the seed is only assigned once the gesture arms):
    //   * NoEdge          — no primary edge within `topoPenPressPickPx`: a genuine
    //                       pick miss.
    //   * NoContinuation  — an edge WAS resolved, but neither endpoint's rail
    //                       resolves, so the shipped hold-fixed contract leaves
    //                       nothing to slide (see `continuationNeighbor` for the
    //                       enumerated open cases). Not a miss: a deliberate,
    //                       contract-driven decline.
    // A consumer that cannot tell those apart has to treat every non-apply as a
    // possible port-side pick failure, which makes a whole gesture's worth of
    // differential cells untriageable. `slideDeclineSeed_` carries the
    // resolved-but-unarmed edge for the NoContinuation case (`-1` otherwise) so
    // a differential can also check WHICH edge was picked, not just that one
    // was. It is deliberately a SEPARATE field from `slideSeed_`, which keeps
    // its existing meaning ("the ARMED gesture's seed") — nothing that reads
    // the armed seed can be confused by a declined press.
    //
    // Lifecycle: written on EVERY exit of `onCtrlLmbDown` (so it always
    // describes the most recent Slide press, not a stale one) and cleared by
    // `activate`/`deactivate`/`resyncSession`. It is NOT arm state and is
    // deliberately absent from `resetAllGestureArms()` (which runs BEFORE this
    // handler on every LEFT press, and would therefore erase the record a
    // consumer is about to read) and from `anyGestureArmed()` (a diagnostic
    // record must never gate the hover indicator). `resyncSession` DOES clear
    // it: an external history navigation can delete the very edge
    // `slideDeclineSeed_` names, and publishing a stale index is worse than
    // publishing none — same rationale as the passive hover/fill state cleared
    // there.
    SlideDecline slideDecline_     = SlideDecline.None;
    int          slideDeclineSeed_ = -1;

    // --- P8 Smooth session state (topology_pen.d,
    // doc/topopen_p8_smooth_plan.md). Armed by a Shift+Ctrl+LMB press
    // (`onShiftCtrlLmbDown`) — NO source-vertex pick (whole-primary-mesh
    // scope, unlike every other gesture above) and NO mutation on down;
    // `smoothDragDx_` is the SIGNED horizontal displacement of the cursor
    // from the press pixel, recomputed (never accumulated) on every
    // subsequent motion event (`onMouseMotion`) and converted to a pass
    // count at release (`onMouseButtonUp`'s Smooth branch,
    // `applySmoothPasses`) through the one shared law helper
    // `smoothPassesForDragDx` — the only read of `smoothDragDx_` besides
    // `toolStateJson()`'s live readback (REV1 MINOR: the plan's original
    // `smoothPassCount_` field is dropped since it was never assigned;
    // both `onMouseButtonUp` and `toolStateJson()` derive `N` from
    // `smoothDragDx_` directly). `smoothLastX_`/`_Y_` now track ONLY the
    // live cursor for `draw()`'s armed-ring affordance — the pass count no
    // longer measures anything against them (see `kSmoothPassStridePx`:
    // path length and vertical motion are both measured to be ignored).
    // Cleared by `onMouseButtonUp` on commit/no-op and by `resyncSession`
    // on an external history navigation, exactly like the P3/P4/P6/P7 arm
    // state above.
    bool  smoothArmed_ = false;
    int   smoothStartX_, smoothStartY_, smoothLastX_, smoothLastY_;
    int   smoothDragDx_ = 0;

    // --- P9 Split session state (topology_pen.d,
    // doc/topopen_p9_split_plan.md). Armed on a plain-MMB press that lands
    // on an existing primary-layer vertex A (`onPlainMmbDown`);
    // `splitTargetVert_` tracks the CURRENT snap target C off every
    // subsequent motion event (`onMouseMotion`) and is re-resolved once more
    // at the release pixel (`onMouseButtonUp`'s MIDDLE branch, `commitSplit`)
    // — the release event's own resolution is authoritative, never the
    // last-motion value (a mouse-up with no intervening motion event must
    // still resolve C at ITS OWN pixel). `-1` means "no vertex under the
    // cursor" — a clean no-op, since Split is a vertex->vertex chord split
    // and never inserts a vertex partway along an edge (that is Add Loop's
    // job, doc/tasks/work/0480-topopen-addloop-middle.md).
    // Cleared by `onMouseButtonUp` on commit/no-op and by `resyncSession` on
    // an external history navigation, exactly like the P3/P4/P6/P7/P8 arm
    // state above.
    bool splitArmed_       = false;
    int  splitSourceVert_  = -1;
    int  splitTargetVert_  = -1;

    // --- The snap CONFIGURATION this gesture runs on, snapshotted at press.
    //
    // The drag-snap acceptance and gather radii are not the pen's own numbers.
    // They belong to the application-wide snapping service (our `SnapStage`,
    // which publishes them on the `SnapPacket` every other snapping consumer
    // in the tree already reads) and the tool is one client of it among many.
    // The pen used to carry a private copy of the same pair in `constraint.d`
    // — two subsystems storing one fact, each unable to see the other — and
    // this field is what replaced it.
    //
    // SNAPSHOT-AT-PRESS, dropped at release, deliberately: the ranges must not
    // change under a gesture that is already in flight, so a mid-drag `snap
    // innerRange` edit takes effect on the NEXT press and not this one. That
    // is the same lifetime a registered snapping guide has — the ranges are
    // pushed into it when its drag starts and it is unregistered when the drag
    // ends — and the same shape `XfrmToolBase.captureSnapForDrag` already uses
    // for the transform tools.
    //
    // Read from the `VectorStack` the event handler is already holding rather
    // than by walking the pipeline again: `app.d`'s `buildToolVts` has already
    // run `pipeline.evaluate` into it, so the packet is right there, and this
    // is `captureSnapForDrag`'s own source. When no SNAP stage is registered
    // this stays `SnapPacket.init`, whose ranges ARE the stage's declared
    // defaults (pinned by a unittest in `toolpipe/stages/snap.d`), so a
    // pipeline-less pen — every direct-construction unittest below, and the
    // headless paths — behaves exactly as it did when the constants were
    // private.
    //
    // NOT gated on `SnapPacket.enabled`. Whether the pen should fall silent
    // when the user turns snapping off is an open question with a real
    // behaviour change on either answer; it is not settled here, and taking
    // only the numbers is the change that costs nothing.
    SnapPacket dragSnap_;

    // The Mode dropdown (task 0477 continuation + task 0483): the wire-tag
    // table backing `PenMode`'s `Param.intEnum_` — mirrors
    // `loop_slice_tool.d`'s `editTable`/`modeTable` precedent. Tags and
    // labels are the REFERENCE's own, single-sourced here so the form row,
    // the `tool.attr mesh.topoPen mode <tag>` write and the
    // `/api/tool/state` readback can never drift apart.
    //
    // A STICKY tool-wide mode toggle, NOT per-gesture arm state — like
    // `addLoopMiddle_` above, deliberately absent from
    // `resetAllGestureArms()`/`resyncSession()` (a mode switch must survive
    // an external history navigation) and read live by dispatch
    // (`onPlainLmbDown`) / the motion-time preview compute
    // (`onMouseMotion`), never cached.
    private static immutable IntEnumEntry[8] penModeTable = [
        IntEnumEntry(cast(int)PenMode.Move,      "move",      "Move"),
        IntEnumEntry(cast(int)PenMode.Duplicate, "duplicate", "Duplicate"),
        IntEnumEntry(cast(int)PenMode.Remove,    "remove",    "Remove"),
        IntEnumEntry(cast(int)PenMode.Split,     "split",     "Split"),
        IntEnumEntry(cast(int)PenMode.AddLoop,   "addLoop",   "Add Loop"),
        IntEnumEntry(cast(int)PenMode.Point,     "point",     "Point"),
        IntEnumEntry(cast(int)PenMode.Fill,      "fill",      "Fill"),
        IntEnumEntry(cast(int)PenMode.Smooth,    "smooth",    "Smoothing"),
    ];
    PenMode penMode_ = PenMode.Move;   // live-measured reference default

    // Edge Loop / Edge Slide — the two sticky boolean modifiers that sit
    // ALONGSIDE the Mode dropdown in the reference's own Tool Properties
    // sheet, with the same defaults (both OFF, live-measured —
    // toolcards/topology_pen/attr_defaults_capture.md, PRIVATE).
    //
    // `edgeLoop_` ("Edge Loop") promotes a mode to its loop variant, exactly
    // as the reference's per-option `Desc` strings pair them: Move+loop is
    // the RMB gesture (`onMoveLoopRmbDown`), Duplicate+loop the Shift+RMB one
    // (`onDupLoopShiftRmbDown`), Smoothing+loop the Shift+Ctrl+RMB one
    // (`onSmoothLoopRmbDown`), and Remove+loop dissolves the whole edge loop
    // through the pressed edge (`removeEdgeAt`, task 0494 — this used to be
    // the tool's one unwired input slot, and the note here used to claim the
    // flag was deliberately ignored by Remove; it was measured, it is ported,
    // and the claim is gone with it). The remaining four modes have no loop
    // variant and ignore the flag.
    //
    // Remove reads it in ONE of its three primitives — the edge one. A Remove
    // press that latches a polygon or a vertex behaves identically with the
    // flag on or off, because the reference's dispatcher does not read it
    // either.
    //
    // `edgeSlide_` ("Edge Slide") restricts a move to the neighbouring edge
    // rails — the reference documents it as doing exactly what holding Ctrl
    // in Move mode does, so it routes to the SAME `onCtrlLmbDown` the Ctrl
    // chord does. It applies to the Move family only (Move mode, and Point
    // mode's move half, which the reference defines as "works as in the Move
    // mode"); `edgeLoop_` wins when both are on (there is no slide-a-whole-
    // loop gesture in this tool, so a loop press is the only one of the two
    // that can be honoured — see `moveOrPlaceDown`).
    //
    // Sticky, for the same reason `penMode_` is: they are dropdown-adjacent
    // options, not gesture state.
    bool edgeLoop_  = false;
    bool edgeSlide_ = false;

    // `innerSnap_` ("Inner Snap") — the reference's own third dropdown-adjacent
    // checkbox, default OFF (measured, task 0496), and it selects a CANDIDATE
    // SET rather than a radius: with it OFF the pen's SNAP TARGET must be a
    // BORDER element (an edge with at most one incident polygon, or a vertex
    // touching one such edge); with it ON the mesh interior becomes snappable
    // too. Sticky across gestures, for the same reason `penMode_` is.
    //
    // SCOPE, deliberately narrow and measured (task 0496): this gates the
    // pen's drag-time SNAP TARGET — today that is Split's target vertex C,
    // vibe3d's only "which existing element does this drag land on" query
    // (`splitTargetVert_`, whose own doc comment already calls it the snap
    // target). It deliberately does NOT gate the press-time element PICK
    // (`findSourceVertex` / `findRingSeedEdge` on their own): our own capture
    // corpus shows the reference grabbing and sliding an INTERIOR edge
    // (polygon count 2) with this flag at its default, and seeding Add Loop
    // from interior edges of a closed mesh, so gating the press pick would
    // contradict measurements we already hold. See the resolvers' own note.
    bool innerSnap_ = false;

    // `keepVertex_` ("Keep Vertices") — the reference's own fourth
    // dropdown-adjacent checkbox, default OFF (measured, task 0494), and it
    // gates ORPHAN RETENTION on the Remove mode's EDGE path: with it off, a
    // dissolve that eats a vertex's WHOLE polygon fan deletes that vertex and
    // re-stitches its survivors; with it on the vertex stays as a corner of the
    // merged polygon. See `removeEdgeAt`.
    //
    // Wiring this knob CHANGED this tool's default outcome: before task 0494
    // the pen's only dissolve path kept consumed vertices unconditionally, i.e.
    // it shipped the ON branch while the measured default is OFF.
    //
    // SCOPE, and it is narrow because that is what was measured: the flag was
    // varied on the EDGE path only. The vertex and polygon primitives were both
    // captured at OFF, and the reference's own code reads the flag in neither
    // — so they ignore it here rather than guess a second meaning for it.
    //
    // Sticky across gestures, for the same reason `penMode_` is.
    bool keepVertex_ = false;

    // `fillRange_` ("Range") and `fillQuadOnly_` ("Quads Only") — the two
    // FILL-mode attributes (task 0488). Both were in this tool's "awaiting
    // their own measurement" bucket (see `params()`'s three-bucket audit)
    // until the Fill candidate rule was measured twice — once live and once
    // off a recording — and both are now load-bearing inputs to
    // `findFillRing`, so they ship together with it rather than as knobs
    // added for their own sake.
    //
    //   `fillRange_`    multiplies the hover radius to give the candidate
    //                   GATHER radius, in screen pixels
    //                   (`fillRange_ * fillHoverRadiusPx(...)`). It is a
    //                   gather radius and NOTHING else: it never enters the
    //                   ranking, so above the mesh's own threshold more reach
    //                   changes nothing (the nearest-four cap absorbs it) and
    //                   below it the gesture refuses.
    //   `fillQuadOnly_` is the COUNT gate: on, the search accepts exactly 4
    //                   candidates; off, exactly 4 OR exactly 3 (and the
    //                   3-path runs no shape test at all).
    //
    // BOUNDS, measured, never guessed — the same measured clamp table every
    // other row on this tool traces to (task 0499 §C-0, recovered live AND
    // statically from the reference's own UI-hint table, so it is not
    // re-derivable from anything in this repo — read it there before moving a
    // number): `range` is min 0.0 with NO upper bound; `quadOnly` is [0,1],
    // i.e. a plain boolean. Defaults 1.5 / ON, both measured (the reference's
    // own reset seeds 1.5, and every armed cell of the live run read back
    // exactly the requested value).
    //
    // WHAT IS NOT PORTED WITH THEM: the reference REFUSES a write to either
    // attribute outside Fill mode (an error, not an ignore) and greys the row
    // out in its panel. vibe3d has no value-conditional row-disable mechanism
    // yet (it is owned by the forms-engine task that also owes it to
    // `smoothStrength`), so these rows stay always-writable exactly like
    // `smoothStrength` does today. Recorded, not silently diverged.
    private enum float kFillRangeDefault = 1.5f;
    float fillRange_    = kFillRangeDefault;
    bool  fillQuadOnly_ = true;

    // Which gesture the LAST unmodified-LMB press actually resolved to
    // (task 0483). Written by `onPlainLmbDown`'s router at DOWN, read by
    // `lmbModeUp` at UP so the release reaches THAT gesture's commit leg —
    // re-resolving the mode at release would dispatch the wrong commit if
    // the dropdown moved mid-drag (`tool.attr mesh.topoPen mode <tag>` is
    // reachable over HTTP at any moment, and the Tool Properties dropdown
    // is one click away). Per-press RECORD, so `resetAllGestureArms()`
    // returns it to the neutral `PlaceOrMove` — whose UP leg is guarded
    // by `placeArmed_`/`moveArmed_` and therefore a safe no-op.
    PenGesture[3] gestureOn_ = PenGesture.PlaceOrMove;

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
    // (`onMouseButtonUp`), never from this cached value. Cleared by
    // `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation, exactly like the P3/P4/P6/P7/P9 arm
    // state above. (Task 0503 removed the per-background `BvhPick` cache
    // that used to live here: the re-snap is no longer a ray, so there is
    // no BVH to keep — `resnapToBackground` now calls the same
    // `closestPointOnMeshes` P8/P12's Smooth does, which walks the source
    // faces directly.)
    bool  moveLoopArmed_  = false;
    int   moveLoopSeed_   = -1;
    int   moveLoopStartX_, moveLoopStartY_;
    int   moveLoopCurX_,   moveLoopCurY_;
    uint[] moveLoopVerts_;

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
    // the P3-P10 arm state above.
    bool  dupLoopArmed_   = false;
    int   dupLoopSeed_    = -1;
    int[] dupLoopEdges_;
    int   dupLoopStartX_, dupLoopStartY_;
    int   dupLoopCurX_,   dupLoopCurY_;

    // --- Duplicate-EDGE session state (task 0485). The single-edge sibling
    // of the Dup Loop state above, armed by a Shift+LMB press that lands on
    // an edge instead of a vertex: the reference's Duplicate mode
    // "duplicates an edge as you drag it", and only widens that to a whole
    // loop "with Edge Loop enabled or by dragging with the right mouse
    // button". So Shift+LMB on an edge is the ONE-edge case of the very
    // operation Shift+RMB already runs, and it commits through the same
    // kernel (`commitDupEdges`) with a one-element edge list.
    //
    // DELIBERATELY NOT the `dupLoop*` fields reused with a shorter list: a
    // RIGHT-button press can legitimately arrive while a LEFT gesture is
    // still held (the two-button chord this tool's MIDDLE/RIGHT handlers are
    // careful to preserve — see `resetAllGestureArms`), and
    // `onDupLoopShiftRmbDown`'s own narrow self-reset would then silently
    // cancel the LEFT drag by clearing state they shared. Separate fields
    // keep that property intact.
    bool  dupEdgeArmed_ = false;
    int   dupEdgeSeed_  = -1;
    int[] dupEdgeEdges_;          // what the release will duplicate: [seed], or the trimmed border run
    int   dupEdgeStartX_, dupEdgeStartY_;
    int   dupEdgeCurX_,   dupEdgeCurY_;

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
    // position" the drag-distance accumulator measures against AND the live
    // cursor `draw()`'s ghost ring previews at (mirroring Move Loop's
    // `moveLoopCurX_`/`_Y_`) — one field serves both roles since after every
    // motion event it IS the live cursor. `smoothLoopDragPx_` accumulates
    // cursor TRAVEL — the whole-mesh Smooth gesture used to do the same, but
    // its pacing has since been measured and replaced (`kSmoothPassStridePx`)
    // while this path's was never sampled, so the two are deliberately forked
    // (`kSmoothLoopPassStridePx`). The only read of it is at release, to
    // derive the pass count (`onMouseButtonUp`'s Smooth+Loop branch). Cleared by
    // `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation, exactly like the P3-P11 arm state above.
    bool   smoothLoopArmed_   = false;
    int    smoothLoopSeed_    = -1;
    uint[] smoothLoopVerts_;
    int    smoothLoopStartX_, smoothLoopStartY_;
    int    smoothLoopCurX_,   smoothLoopCurY_;
    float  smoothLoopDragPx_ = 0.0f;

    // P8 pass count — the MEASURED law (task 0490; superseded the earlier
    // "unmeasured throttle" guess of one pass per 20px of cursor TRAVEL):
    //
    //     N = max(1, 1 + (xCurrent - xPress) / kSmoothPassStridePx)
    //
    // Three things are measured here and each one of them contradicts the
    // guess it replaces:
    //   * the stride is 5 screen pixels, not 20;
    //   * the input is the SIGNED HORIZONTAL displacement from the press
    //     pixel — so dragging back toward (and past) the press pixel makes
    //     the count FALL again, and it is bounded by the floor of 1, never
    //     by how far the cursor has been;
    //   * vertical motion contributes NOTHING (a purely vertical drag is
    //     one pass, exactly like a stationary click) and neither does the
    //     accumulated PATH length — only where the cursor is now, relative
    //     to where the press was.
    // The division is signed and truncates toward zero, matching the
    // reference's own integer divide.
    //
    // `MAX_TOPOPEN_SMOOTH_PASSES` stays the two-layer DoS backstop (mirrors
    // `MeshSmooth`'s own `MAX_SMOOTH_ITER`, `commands/mesh/smooth.d`) — this
    // is a DERIVED count (drag geometry), not a user `Param`, so it needs
    // the kernel cap + floor, not an `enforceBounds()`. At a 5px stride the
    // cap is first reached at a +1275px horizontal drag, i.e. beyond any
    // real viewport-width gesture: it is a runaway guard, NOT a silent clamp
    // inside the working range.
    private enum int kSmoothPassStridePx        = 5;
    private enum int MAX_TOPOPEN_SMOOTH_PASSES  = 256;

    // FORKED, DELIBERATELY UNMEASURED: the Smooth+LOOP path
    // (`applySmoothLoopPasses`) keeps the ORIGINAL guessed pacing — one pass
    // per 20px of accumulated cursor travel. The law above was measured on
    // the whole-mesh Smooth path only; the loop variant was never sampled,
    // and silently generalizing a measurement from one path to another is
    // exactly what `inverseEdgeLenRelax`'s own doc comment warns against.
    // Close it with a capture of THAT path, not by deleting this fork.
    private enum float kSmoothLoopPassStridePx = 20.0f;

    // The one place the measured pass-count law above is evaluated: both the
    // release path (`smoothUp` -> `applySmoothPasses`) and the live state
    // readback (`toolStateJson`'s `smoothPassCount`) go through it, so the
    // count a test observes mid-drag is by construction the count a release
    // would apply. Returns the FULLY clamped value (floor 1, cap
    // MAX_TOPOPEN_SMOOTH_PASSES) — `applySmoothPasses` re-applies the same
    // clamp for its direct (headless / unit-test) callers.
    //
    // NO USER PARAM, ON PURPOSE (task 0490 — do not "fix" this by adding
    // one): the reference exposes an iteration-count attribute of its own,
    // but that attribute and this gesture counter are the SAME storage cell
    // in it, and its press handler overwrites that cell with 1 at the start
    // of EVERY Smooth press. Setting the attribute therefore cannot affect
    // the gesture that follows — which is why a captured run that set it to
    // 3 still relaxed exactly once. Exposing it as a `Param` here would
    // CREATE a divergence rather than close one, the same resolution already
    // taken for the reference's boundary/corner lock attributes (see
    // `applySmoothPasses`).
    private static int smoothPassesForDragDx(int dragDx) {
        int n = 1 + dragDx / kSmoothPassStridePx;   // signed, truncating toward zero
        if (n < 1) n = 1;
        if (n > MAX_TOPOPEN_SMOOTH_PASSES) n = MAX_TOPOPEN_SMOOTH_PASSES;
        return n;
    }

    // Smooth relaxation force factor (measured): `F = strength / 20`, with a
    // reference default `strength` of 1.0 → F = 0.05. The divisor is a
    // literal read from the reference, not a fitted constant. Backing store
    // for the `smoothStrength` Param (see `params()`); sticky across
    // gestures like every other tool option here.
    private enum float kSmoothStrengthDefault = 1.0f;
    private enum float kSmoothStrengthDivisor = 20.0f;
    float smoothStrength_ = kSmoothStrengthDefault;

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

    // WHAT a press at the current cursor would grab (task 0484 follow-up),
    // resolved by the SAME `resolveGrabTarget` the press itself calls — so
    // the highlight cannot name one element while the press takes another.
    // This is what `draw()` renders: exactly ONE element, never the
    // nearest-vertex-and-nearest-edge pair the fields above describe.
    //
    // Those fields stay, and stay published: they answer a DIFFERENT question
    // ("what is nearest, at any distance" — an ∞-threshold scan, the
    // affordance the hover plan specified) which `/api/tool/state` consumers
    // already read. This pair answers "what is under the cursor, within pick
    // range, and therefore live". `hoverGrabIndex_` indexes whichever array
    // `hoverGrabElem_` names.
    MoveElem hoverGrabElem_  = MoveElem.None;
    int      hoverGrabIndex_ = -1;

    // The reference's two DISPLAY toggles for this tool (task 0499), both
    // measured default ON and both plain booleans with no mode gate of their
    // own. They are the only two attributes in the reference's whole attribute
    // set whose behavior is measured AND which vibe3d does not publish: a
    // display flag has no numeric or topological effect to get wrong, which is
    // exactly why these two can be ported when the numeric ones cannot.
    //
    // SCOPE IS A VIBE3D DECISION, NOT A MEASURED LAW — do not silently widen
    // it. What is measured: the attributes exist, they are booleans, they
    // default ON, and they control drawing only. WHICH overlay elements they
    // gate in the reference was NOT measured. We gate exactly our own pen
    // hover indicator's vertex marker / edge line (`hoverIndicatorElem`), and
    // nothing else — never the viewport's own vertex/edge display, which is a
    // global view setting here and would be a far larger claim than the
    // measurement supports. Both default `true`, so the drawn result with an
    // untouched panel is byte-identical to before this row existed.
    //
    // The hover indicator's third case — the FACE hatch — has no counterpart
    // among the reference's two toggles and is therefore left ungated
    // (recorded as an open item in the task file, not resolved by guessing a
    // third toggle into existence).
    bool showVertex_ = true;
    bool showEdge_   = true;

    // Fill mode hover preview: the ring `findFillRing` resolves under the
    // cursor — 4 corners, or 3 when `quadOnly` is off — in the ORDER the
    // build would use, or `null` when the mode isn't Fill / the search
    // refuses / a gesture is armed. A passive display cache — like
    // `hoverNearestVert_` above — NOT part of
    // `resetAllGestureArms()`/`anyGestureArmed()`. Computed unconditionally
    // in `onMouseMotion`'s not-armed branch (its own sibling gate, NOT
    // nested inside the `hoverOverMesh_` block above — see the plan's
    // mandatory opponent fix #2: `hoverOverMesh_` requires a pick within
    // `topoPenPressPickPx`, which is false when hovering the CENTER of an empty
    // gap cell, exactly the defining Fill-mode case).
    //
    // ONE SEARCH, shared with the commit (task 0488): the reference's own
    // draw path runs the identical candidate search the press does, so the
    // highlight is not an approximation of the outcome — it IS the outcome.
    // Anything that changes the rule therefore changes this preview in the
    // same breath; they cannot be ported apart.
    uint[] fillRing_;

    // Fill mode hover-reach RADIUS overlay (task 0477 continuation, a
    // derived law — full provenance/disassembly kept in the PRIVATE
    // toolcard, toolcards/topology_pen/fill_radius_law_capture.md): a
    // cosmetic screen-space circle, centered on the live cursor pixel,
    // sized to the farther endpoint of whichever BORDER edge the cursor is
    // nearest. `fillRadiusPx_` is computed alongside `fillRing_` above, in
    // `onMouseMotion`'s Fill-mode branch (its own sibling gate, same
    // rationale `fillRing_` isn't nested in `hoverOverMesh_`: hovering the
    // open middle of a gap is nowhere near any vertex/edge/face within
    // `topoPenPressPickPx`, yet a nearby border edge still legitimately sizes
    // the circle). `fillRadiusValid_` is false whenever a non-Fill mode is
    // active, a gesture is armed, or no border edge is within tolerance of
    // the cursor (this also covers the vertex-only-hover case the toolcard
    // leaves unresolved as an honest gap — no circle rather than a guessed
    // one). Overlay-only: never read by `findFillRing`/`commitFill`, so it
    // cannot affect the fill kernel, undo, or any other mode.
    bool  fillRadiusValid_ = false;
    float fillRadiusPx_    = 0.0f;

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

    // Fill-mode radius-overlay colour (task 0477 continuation, the derived
    // radius law): pale, thin, and translucent — DELIBERATELY distinct
    // from every other hue in this palette (steel-blue element, green cell
    // preview, cyan snap highlight, orange place marker) so the reach
    // circle never reads as any of those affordances.
    private enum uint  kFillRadiusCol          = IM_COL32(230, 230, 230, 140);
    private enum int   kFillRadiusSegments     = 48;
    private enum float kFillRadiusThicknessPx  = 1.0f;

    void readHit(ref VectorStack vts) {
        if (auto p = vts.get!ConstrainHitPacket()) {
            lastHit_ = *p;
            Viewport vp;
            if (auto s = vts.get!SubjectPacket())
                vp = s.viewport;
            lastTarget_ = resolveHoverTarget(lastHit_, vp, topoPenPressPickPx(vp));
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

    // Fill mode radius-overlay LAW (task 0477 continuation — derived from a
    // reference engine's disassembly; full provenance kept in the PRIVATE
    // toolcard, toolcards/topology_pen/fill_radius_law_capture.md, never in
    // this tracked source): the hover-reach circle's radius is the FARTHER
    // of the cursor's screen-space Euclidean distance to the two endpoints
    // of whichever border edge the cursor is nearest. Pure + static (no
    // mesh/GL access) so the arithmetic is independently unit-testable.
    static float fillHoverRadiusPx(float cursorX, float cursorY,
                                   ImVec2 edgeEndpointA, ImVec2 edgeEndpointB) {
        immutable float dA = hypot(edgeEndpointA.x - cursorX, edgeEndpointA.y - cursorY);
        immutable float dB = hypot(edgeEndpointB.x - cursorX, edgeEndpointB.y - cursorY);
        return dA > dB ? dA : dB;
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
    // Remove's edge / vertex primitives (task 0494): 14th and 15th positional
    // params `ref`/`rvf` appended LAST (after `flf`) — same rationale as every
    // prior addition, and it bites harder here than usual: all THREE Remove
    // factories are structurally identical delegate aliases whose only
    // difference is the wire name they were built with, so a mis-ordered
    // argument would silently label an edge dissolve as a face removal rather
    // than fail to compile.
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
                        TopoPenFillFactory flf = null,
                        TopoPenRemoveEdgeFactory ref_ = null,
                        TopoPenRemoveVertexFactory rvf = null) {
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
        removeEdgeEditFactory_   = ref_;
        removeVertexEditFactory_ = rvf;
    }

    override string name() const { return "Topology Pen"; }

    // Add Loop "at the Middle" option schema
    // (doc/tasks/work/0480-topopen-addloop-middle.md) — the FIRST `params()`
    // override on this tool. Backs both the
    // `tool.attr mesh.topoPen middle ?` HTTP path and the
    // `config/forms/topology_pen.yaml` checkbox row; the attr name
    // "middle" MUST match that form's `control:` string exactly — the
    // boot-time `validateForms` strict-checks every form attr against this
    // list and fails loud on a typo.
    //
    // Mode dropdown (task 0477 continuation, doc/topopen_fill_plan.md
    // Phase 1, MANDATORY opponent fix #1): the `mode` IntEnum Param is
    // APPENDED to this array — never a full-replace, which would drop
    // `middle` and fail boot-time `validateForms` against its existing
    // yaml row. "mode" MUST match `config/forms/topology_pen.yaml`'s new
    // dropdown row's `control:` string exactly, same contract as
    // `middle` above.
    //
    // `loop` / `slide` (task 0483) — the reference's own "Edge Loop" /
    // "Edge Slide" checkboxes, APPENDED for that same reason. They modify
    // what the Mode dropdown dispatches an unmodified LMB press to; see
    // `edgeLoop_`/`edgeSlide_`'s own doc comment for the routing rules and
    // `onPlainLmbDown` for the table that applies them.
    //
    // `innerSnap` (task 0496) — the reference's own third checkbox, APPENDED
    // for the same reason, default OFF (measured). Unlike the attributes this
    // form deliberately omits, its behaviour IS measured: it selects the
    // CANDIDATE SET the pen's snap target may resolve to (border-only when
    // off, the interior as well when on) — see `innerSnap_` for the scope.
    //
    // Smooth strength (reference parity, `doc/tasks/work/0478-topopen-smooth-kernel.md`):
    // APPENDED for the same reason — never a full-replace. Scales the Smooth
    // relaxation force as `F = smoothStrength / kSmoothStrengthDivisor`
    // (`applySmoothPasses`); the reference's own default is 1.0, giving
    // F = 0.05. Bounds are `.enforceBounds()`-backed so a headless
    // `tool.attr` injection cannot drive the force outside the sane range
    // (0 = a pure no-op, the upper end already well past useful). This is a
    // FORCE scale, not a work scale — the iteration count, which IS the work
    // scale, carries its own `MAX_TOPOPEN_SMOOTH_PASSES` cap in
    // `applySmoothPasses`, and the kernel additionally rejects a non-finite
    // factor that `.enforceBounds()` cannot clamp.
    //
    // `showVertex` / `showEdge` (task 0499) — the reference's two DISPLAY
    // toggles, both measured default ON, both ungated booleans. APPENDED, same
    // reason as every row above. See their fields' own doc comment for the one
    // thing about them that is a vibe3d decision rather than a measurement (the
    // SCOPE of what they hide) and for why the face hatch stays ungated.
    //
    // `keepVertex` (task 0494) — the Remove mode's orphan-retention gate,
    // measured in BOTH directions on one cell pair and measured default OFF.
    // APPENDED LAST, same reason as every row above. Note what publishing it
    // did: our pre-0494 behaviour was its ON branch, so the row does not merely
    // expose a knob, it moves the default. See the field's own doc comment.
    //
    // `range` / `quadOnly` (task 0488) — the two FILL attributes, APPENDED
    // LAST, same reason as every row above. They leave the "awaiting
    // measurement" bucket below because the Fill candidate rule is now
    // measured twice over and BOTH are load-bearing inputs to it: `range`
    // multiplies the hover radius into the candidate gather radius, and
    // `quadOnly` is the 3-vs-4 count gate. Bounds are the measured ones (min
    // 0.0, no upper bound / [0,1]) — see `fillRange_`'s own doc comment for
    // the provenance and for the one clause NOT ported with them (the
    // reference REFUSES a write outside Fill mode; we have no row-disable
    // mechanism yet, exactly as with `smoothStrength`).
    //
    // ---- WHY THIS LIST IS SHORT, AND WHAT OWNS THE REST -------------------
    //
    // The reference tool carries 31 attributes; this list publishes 7. The gap
    // is deliberate and sorted into three buckets. A knob whose BEHAVIOR is not
    // measured is not "approximately right" — it does something else and the
    // user cannot tell. A knob with GUESSED BOUNDS is the same class of error,
    // so every row here traces to the measured clamp table (task 0499 §C-0 in
    // the task file; recovered live AND statically, so it is not re-derivable
    // from anything in this repo — read it there before adding a row).
    //
    //   (a) behavior measured, safe to publish now — `range`, `quadOnly`
    //       (task 0488). Both graduated out of bucket (c) when Fill's
    //       candidate rule was measured; neither is a knob for its own sake
    //       (each is an input the ported search reads).
    //   (b) measured as pure DISPLAY — `showVertex`, `showEdge`. Below.
    //   (c) awaiting their own measurement — NOT published, one owner each:
    //         iteration count (see the note below)       -> task 0490 (Smooth)
    //         `falloffDist`, `connect`, `shape`, p0/p1   -> task 0491 (falloff)
    //         `joinDisco`                                -> task 0500 (weld)
    //         boundary/corner locks + the iteration row  -> task 0501 (gated
    //                                                       rows; they need a
    //                                                       panel-gate
    //                                                       mechanism first)
    //         `reverse`                                  -> no owner yet; an
    //                                                       undocumented
    //                                                       boolean whose
    //                                                       behavior was never
    //                                                       measured at all
    //
    // Two rows are absent ON PURPOSE rather than pending, and both stay absent:
    // an iteration/pass-count row (the reference overwrites that attribute with
    // 1 at the start of every Smooth press, so publishing it would CREATE a
    // divergence — see `config/forms/topology_pen.yaml`'s own note and
    // `applySmoothPasses`), and the boundary/corner locks (measured inert on
    // the path we implement, but that measurement is path-conditional — task
    // 0501 owns re-deciding them, so shipping them "inert" here is exactly what
    // must not happen).
    override Param[] params() {
        return [
            Param.bool_("middle", "Split at the Middle", &addLoopMiddle_, false),
            Param.intEnum_("mode", "Mode", cast(int*)&penMode_, penModeTable,
                           cast(int)PenMode.Move),
            Param.bool_("loop",  "Edge Loop",  &edgeLoop_,  false),
            Param.bool_("slide", "Edge Slide", &edgeSlide_, false),
            Param.float_("smoothStrength", "Smooth Strength", &smoothStrength_,
                         kSmoothStrengthDefault)
                 .min(0.0f).max(4.0f).enforceBounds(),
            Param.bool_("showVertex", "Show Vertex", &showVertex_, true),
            Param.bool_("showEdge",   "Show Edge",   &showEdge_,   true),
            Param.bool_("innerSnap", "Inner Snap", &innerSnap_, false),
            Param.bool_("keepVertex", "Keep Vertices", &keepVertex_, false),
            Param.float_("range", "Range", &fillRange_, kFillRangeDefault)
                 .min(0.0f).enforceBounds(),
            Param.bool_("quadOnly", "Quads Only", &fillQuadOnly_, true),
        ];
    }

    override void activate() {
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
        // Slide decline diagnostics are a per-press RECORD, so they must not
        // survive into a fresh activation — a stale "no_continuation" from a
        // previous session would be read as this session's own outcome (the
        // classic cross-test bleed). Cleared on the way out too, below.
        slideDecline_     = SlideDecline.None;
        slideDeclineSeed_ = -1;
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
        // Task 0484: Move is the one gesture here that writes the mesh
        // DURING the drag, so a tool switch mid-drag would otherwise leave
        // those writes applied with no history entry to undo them. Record
        // what is already on the mesh, then clear. No new targets are
        // computed — there is no event, hence no pixel, to compute them for;
        // the mesh's current state IS the answer.
        commitLiveMoveIfDirty();
        lastHit_    = ConstrainHitPacket.init;
        lastTarget_ = HoverTarget.init;
        slideDecline_     = SlideDecline.None;
        slideDeclineSeed_ = -1;
        // Per-gesture snap snapshot — a tool switch mid-drag ends the gesture,
        // so it must not survive into the next activation any more than the
        // decline diagnostics above do.
        dragSnap_ = SnapPacket.init;
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
            hoverOverMesh_   = false;   // gesture ghosts take precedence
            hoverGrabElem_   = MoveElem.None;
            hoverGrabIndex_  = -1;
            fillRing_        = null;   // Fill mode continuation: same precedence rule
            fillRadiusValid_ = false;  // Fill radius overlay: same precedence rule
        } else {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            hoverOverMesh_ = overPrimaryMesh(e.x, e.y, vp);
            if (hoverOverMesh_) {
                computeHoverIndicator(e.x, e.y, vp);
                // The grab target, from the press's own resolver. Whenever
                // `hoverOverMesh_` holds this resolves something: that gate
                // is the OR of the very three terms `resolveGrabTarget`
                // tries, at the same thresholds.
                hoverGrabElem_ = resolveGrabTarget(e.x, e.y, vp, hoverGrabIndex_);
            } else {
                hoverNearestVert_ = hoverNearestEdge_ = hoverBoundaryFace_ = -1;
                hoverBoundary_    = false;
                hoverGrabElem_    = MoveElem.None;
                hoverGrabIndex_   = -1;
            }

            // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md
            // Phase 5, MANDATORY opponent fix #2): computed UNCONDITIONALLY
            // here — NOT nested inside `if (hoverOverMesh_)` above — because
            // `hoverOverMesh_` requires a pick within `topoPenPressPickPx`,
            // which is FALSE when hovering the CENTER of an empty gap cell:
            // exactly the defining Fill-mode case (no vertex/edge/face is
            // anywhere near the cursor). Nesting it in that block would
            // make the preview never render for that scenario.
            fillRing_ = (penMode_ == PenMode.Fill) ? findFillRing(e.x, e.y, vp) : null;

            // Fill mode radius overlay (task 0477 continuation, derived
            // law — see `fillRadiusPx_`'s own doc comment for provenance):
            // resolved alongside `fillRing_` above, same unconditional
            // sibling gate and the same rationale — an empty-gap hover has
            // no vertex/edge/face within `topoPenPressPickPx`, yet a nearby
            // border edge still legitimately sizes the circle. Recomputed
            // every motion event, so the cached radius tracks the cursor;
            // `draw()` re-polls the LIVE cursor pixel for the circle's
            // CENTER (not this event's cached (e.x,e.y)), matching the
            // law's "re-polled every redraw" cursor semantics.
            //
            // TASK 0488: the seed is now `fillSeedEdge` — the SAME border
            // edge the candidate search runs from — instead of a separate
            // press-pick-bounded nearest-border-edge query. Two queries for
            // one gesture could disagree, and did: at the bare centre of a
            // gap the search resolved a ring while the circle silently
            // refused to draw, because the old seed was gated at
            // `topoPenPressPickPx` and Fill's press has no reach at all. The
            // circle's ARITHMETIC is untouched (the measured hover radius,
            // not the `range`-multiplied gather radius) — only which edge
            // sizes it.
            fillRadiusValid_ = false;
            if (penMode_ == PenMode.Fill) {
                int bre = fillSeedEdge(e.x, e.y, vp);
                auto m  = mesh;
                if (bre >= 0 && m !is null && bre < cast(int)m.edges.length) {
                    ImVec2 pa, pb;
                    if (projectPt(m.vertices[m.edges[bre][0]], vp, pa)
                     && projectPt(m.vertices[m.edges[bre][1]], vp, pb)) {
                        fillRadiusPx_    = fillHoverRadiusPx(cast(float)e.x, cast(float)e.y, pa, pb);
                        fillRadiusValid_ = true;
                    }
                }
            }
        }

        // Move-family LIVE drag (task 0484). Alone among this tool's
        // gestures, Move mutates the mesh DURING the drag rather than
        // previewing it with a ghost: the element deforms the geometry under
        // the cursor, which is what the reference does and what makes a
        // multi-vertex grab readable at all (a ghost line cannot show an edge
        // or a polygon dragging its incident faces along with it).
        //
        // Still ONE undo entry: `moveBefore_` was captured at arm time and
        // `finishMove` records the pair at release. The targets are absolute
        // (always recomputed from `moveBase_`), so an event stream of any
        // density lands in exactly the same place — and the release recomputes
        // them once more for its OWN pixel, which is what actually decides
        // where the gesture ends. Consumes, mirroring every armed branch
        // below.
        if (moveArmed_) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            applyMoveTargets(moveTargets(e.x, e.y, vp, vts));
            return true;
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

        // P7 (doc/topopen_p7_slide_plan.md Phase 2), re-based on the measured
        // law: while a Slide gesture is armed, recompute the ONE shared
        // scalar off THIS motion event's cursor, press->current (NOT
        // accumulated — the law commits the last evaluation, not a sum).
        // The only mid-drag feedback, since commit is deferred to release.
        // Consumes, mirroring the Add Loop branch above. Unlike V1 this needs
        // no per-endpoint work at all: both endpoints share the scalar, and a
        // held-fixed endpoint (`slideNbrA_`/`slideNbrB_ < 0`) simply never
        // consumes it (neither `commitSlide` nor the draw ghost reads a rail
        // it does not have).
        if (slideArmed_) {
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            slideDeltaK_ = slideDeltaFromDrag(e.x, e.y, vp);
            return true;
        }

        // P8 (doc/topopen_p8_smooth_plan.md Phase 3, re-based on the measured
        // pass-count law — see `kSmoothPassStridePx`): while a Smooth gesture
        // is armed, recompute the ONE signed scalar the law reads off THIS
        // motion event's cursor, press->current in x (NOT accumulated — the
        // count follows where the cursor IS, so a backtrack lowers it again,
        // and y is ignored outright). `smoothLastX_`/`_Y_` keep tracking the
        // live cursor purely for `draw()`'s armed-ring affordance. No
        // mid-drag mutation/preview beyond that cheap affordance (deferred
        // commit, same rationale as every other armed gesture above).
        // Consumes, mirroring the Add Loop/Slide branches above.
        if (smoothArmed_) {
            smoothDragDx_ = e.x - smoothStartX_;
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
            splitTargetVert_ = resolveSnapTargetVert(e.x, e.y, vp);
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

        // Task 0485: same cursor tracking for the single-edge duplicate — the
        // ghost's only input; the committed delta always comes from the
        // RELEASE event's own pixel (`dupEdgeUp`), never from this cache.
        if (dupEdgeArmed_) {
            dupEdgeCurX_ = e.x;
            dupEdgeCurY_ = e.y;
            return true;
        }

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 2): while a
        // Smooth+Loop gesture is armed, accumulate cursor travel off the
        // RUNNING last position — the ORIGINAL, unmeasured pacing the
        // whole-mesh Smooth branch (P8) used before its law was measured, and
        // deliberately forked here rather than followed (see
        // `kSmoothLoopPassStridePx`) — click=1 pass, a longer drag =
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

    // ---------------------------------------------------------------------
    // The MEASURED snap-candidate filter (task 0496, `innerSnap`)
    //
    // The reference's snap query does not merely rank candidates by distance —
    // it REJECTS them per candidate before the distance compare ever runs, and
    // with `innerSnap` at its default OFF the rejected set is the mesh
    // INTERIOR: an edge candidate must have at most one incident polygon, and
    // a vertex candidate must touch at least one such edge. Rejecting rather
    // than de-prioritising is the load-bearing part: an interior vertex 2px
    // from the cursor must not shadow a border vertex 10px away, it must be
    // invisible to the query.
    //
    // ONE deliberate, named extrapolation. The measured predicate is "exactly
    // one incident polygon", which also excludes FACE-LESS geometry (an
    // isolated vertex, a bare wire edge). vibe3d builds exactly that as a
    // normal intermediate state — `classifySource` treats a bare edge as an
    // ongoing retopo state, and the "no degenerate line polygon" divergence in
    // doc/topopen_p3_plan.md means the reference's own retopo never produces
    // it, so it is outside the measured domain rather than covered by it.
    // These predicates therefore exclude the INTERIOR (>= 2 polygons) and
    // leave wire geometry snappable. The boundary is pinned by its own test:
    // change it only with a measurement, not with a hunch.
    // ---------------------------------------------------------------------

    /// True if edge `ei` is INTERIOR — shared by two or more polygons.
    ///
    /// Counted off `faces[]` via `Mesh.edgePolygonCounts`, NOT through
    /// `facesAroundEdge` (task 0502): the half-edge rings have no
    /// representation for a non-manifold fan and report ONE face for three
    /// quads sharing an edge, so the ring walk classified a NON-MANIFOLD edge
    /// as a BORDER edge — and this predicate is the border-only snap-candidate
    /// filter, so such an edge silently became a snap target. `>= 2` is
    /// unchanged; only the counter under it is now truthful.
    private static bool isEdgeInterior(in int[] polyCount, uint ei) {
        return ei < polyCount.length && polyCount[ei] >= 2;
    }

    /// One-off convenience — RECOUNTS THE WHOLE MESH per call. Any loop over
    /// edges or vertices must hoist `Mesh.edgePolygonCounts()` once and use the
    /// array overload; the two `borderOnly` scans below do exactly that.
    private static bool isEdgeInterior(Mesh* m, uint ei) {
        return isEdgeInterior(m.edgePolygonCounts(), ei);
    }

    /// True if vertex `vi` is INTERIOR — it has incident edges and EVERY one
    /// of them is interior, i.e. it touches no border and no wire edge.
    private static bool isVertexInterior(Mesh* m, in int[] polyCount, uint vi) {
        bool any = false;
        foreach (ei; m.edgesAroundVertex(vi)) {
            any = true;
            if (!isEdgeInterior(polyCount, ei)) return false;
        }
        return any;
    }

    /// One-off convenience — see the `isEdgeInterior` overload above.
    private static bool isVertexInterior(Mesh* m, uint vi) {
        return isVertexInterior(m, m.edgePolygonCounts(), vi);
    }

    /// The pen's SNAP TARGET (task 0496): which existing primary-layer vertex
    /// does a drag land on.
    ///
    /// A DIFFERENT QUERY from the press pick, with its own — much wider —
    /// radius, and a different OWNER. The press pick reaches ~8px
    /// (`topoPenPressPickPx`), a constant the tool owns; this one accepts at
    /// the snapping service's inner range (`topoPenSnapAcceptPx`, 24px at the
    /// default configuration), taken from the packet this gesture snapshotted
    /// at press (`dragSnap_`). They were once fused behind a single 15px
    /// constant, which was simultaneously too wide for the press and too
    /// narrow for the landing. The candidate SET is the measured one too:
    /// border-only unless `innerSnap` opens the interior.
    ///
    /// The one caller today is the Split gesture, whose target vertex C is by
    /// its own definition the element the drag snaps to (and whose reference
    /// commit is gated on that snap succeeding). Future snap-target consumers
    /// (mid-drag Split feedback, Duplicate re-snap) must come through HERE
    /// rather than call `findSourceVertex` directly, so the candidate set AND
    /// the radius stay stated in one place.
    private int resolveSnapTargetVert(int mx, int my, const ref Viewport vp) {
        return findSourceVertex(mx, my, vp, topoPenSnapAcceptPx(vp, dragSnap_),
                                !innerSnap_);
    }

    // P3 (doc/topopen_p3_plan.md): project every vertex of the PRIMARY
    // layer's mesh and return the nearest within `topoPenPressPickPx`, or -1.
    // O(V) per press — self-contained (no CONS, no new module), mirroring
    // `projectPt`'s own screen-space-only contract.
    //
    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 1
    // item 4): `thresholdPx` defaults to `kTopoPenSnapAuto`, resolved to the
    // view's own `topoPenPressPickPx(vp)` below, so every existing
    // gesture caller (`onPlainLmbDown`, `onShiftLmbDown`, `onCtrlLmbDown`,
    // the Split motion handler, etc. — none of which pass a 3rd argument)
    // stays BYTE-IDENTICAL. The hover-resolve path (`onMouseMotion`, below)
    // passes `float.infinity` for the unconditional nearest (RESOLUTION),
    // and a finite value for the over-mesh GATE decision (REV1 FIX-1) — two
    // distinct calls, never conflated.
    //
    // `borderOnly` (task 0496) applies the measured snap-candidate filter above:
    // interior vertices are not candidates at all. It defaults to FALSE, and
    // only the SNAP-TARGET caller passes `!innerSnap_` — every press-time PICK
    // stays unfiltered, because the captures we hold show the reference picking
    // interior elements with `innerSnap` at its default (see `innerSnap_`).
    private int findSourceVertex(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapAuto,
                                 bool borderOnly = false) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (thresholdPx < 0.0f) thresholdPx = topoPenPressPickPx(vp);
        int   best   = -1;
        float bestD2 = float.infinity;
        // Hoisted once — the per-element overload of the predicate would
        // recount the whole mesh on every vertex (task 0502).
        const int[] polyCount = borderOnly ? m.edgePolygonCounts() : null;
        foreach (vi; 0 .. m.vertices.length) {
            if (borderOnly && isVertexInterior(m, polyCount, cast(uint)vi)) continue;
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

    // ------------------------------------------------------------------
    // FILL — the candidate rule (task 0488). Ported, not invented: every
    // clause below is a MEASURED clause of the reference's own candidate
    // search, taken from two independent readings (a live run that armed 13
    // of 13 cells and produced the first observed Fill commit, and a
    // recording off which the enumerator itself was read across 316
    // candidate searches). Provenance, addresses and the per-cell tables
    // live in the PRIVATE toolcard, never in this tracked source.
    //
    // This REPLACES the V1 rule (border-edge cell reconstruction with a
    // mandatory real fourth side, picking the smallest screen-area
    // cursor-containing cell). V1 was not a near-miss — it was a different
    // algorithm, and it is refuted on the vertex SET by two rigs at once:
    // the reference built a quad BRIDGING two topologically disconnected
    // bars (a closing side that is not a mesh edge at all), and it put an
    // ISOLATED vertex — one on no polygon whatsoever — in as a corner.
    // V1's construction can produce neither.
    //
    // THE RULE, clause by clause:
    //
    //   SEEDS.  The pressed border edge's two endpoints occupy slots 0 and
    //     1 and are NEVER distance-tested (0.0 in every measured row, 0
    //     exceptions in 316 searches). "Pinned" is not a ranking special
    //     case here and must not be implemented as one: the seeds are not
    //     candidates at all, so eviction simply never looks at them.
    //
    //   GATHER RADIUS.  `range` × the hovered edge's own hover radius
    //     (`fillHoverRadiusPx`), in screen pixels, centred on the CURSOR.
    //     Read directly: the product is what the enumerator receives as its
    //     radius argument. It is a GATHER radius and nothing else — it
    //     never enters the ranking, which is why more reach changes nothing
    //     once the four-nearest cap absorbs it.
    //
    //     ONE OPERATIONAL FACT, because it explains three sessions of
    //     failure: the hover radius is max(dA, dB) over the edge's two
    //     endpoints, so it is MINIMISED at the edge's MIDPOINT. Pressing an
    //     edge in the middle — by far the most natural aim — gives this
    //     gesture its smallest possible reach, and is the worst aim for it.
    //     Aim near an ENDPOINT to reach more candidates.
    //
    //   QUALIFIER.  A vertex qualifies if it is ISOLATED (on no polygon at
    //     all), or belongs to exactly one DEGENERATE polygon (≤ 2 corners),
    //     or carries at least one BORDER edge. Read on 3135 evaluations
    //     with ZERO candidates dropped at this gate. The isolated clause is
    //     load-bearing: an isolated vertex is a legal corner, and V1 could
    //     never produce one.
    //
    //   SCREEN-CROSSING REJECT.  For each SEED vertex, for each polygon
    //     incident to that seed, for each edge of that polygon: reject the
    //     candidate when the OPEN screen segment from the CURSOR to the
    //     CANDIDATE properly crosses that edge (both intersection
    //     parameters strictly inside (0,1)). This is NOT a footnote — the
    //     recording has it firing on 73 % of qualified candidates and
    //     changing the outcome of 77 % of searches. A distance ranking
    //     without it picks different corners on three quarters of them.
    //
    //   RANKING.  The four nearest in 3-SPACE among the reject's SURVIVORS.
    //     An eviction replaces the FARTHEST non-seed entry and only with
    //     something strictly nearer; the count never grows past four. Both
    //     the eviction rule and "never a seed" are read, not reasoned.
    //
    //   COUNT GATE.  Exactly four — or exactly three when `quadOnly` is
    //     off, and the three-path runs NO shape test at all.
    //
    //   SHAPE TEST AND ORDER.  Exactly two cyclic orders are ever tried,
    //     (0,1,2,3) then (0,1,3,2), so the pressed edge is ALWAYS a side of
    //     the built polygon. The first that is convex IN SCREEN SPACE wins;
    //     when the second wins the code SWAPS slots 2 and 3 IN PLACE, and
    //     it is that array — verbatim — that becomes the polygon. The array
    //     is ARRIVAL order mutated by eviction, never a sort (139 of 240
    //     four-slot searches have slot 2 farther than slot 3), so a port
    //     that sorts winds a different polygon.
    //
    // TWO THINGS THIS PORT DELIBERATELY DROPS, both of them ours:
    //
    //   * the mandatory real fourth side. The reference has no such
    //     requirement and demonstrably bridges a gap with no closing edge.
    //   * the clean no-op on a miss. A refusal in the reference is
    //     DESTRUCTIVE — see `fillDown`.
    //
    // WHAT IS NOT PORTED, AND IS NOT INVENTED EITHER — there is one more
    // gate AFTER the convexity test in the reference, and it is strict: it
    // accepted only 76 of 270 formed rings on the recording. Its predicate
    // is UNREAD. Empirically the rings it refuses INCLUDE every ring whose
    // vertex set is an already-existing polygon, which our own
    // `makePolygonFromVerts` duplicate-face guard already declines, so
    // `commitFill` keeps exactly today's behaviour there and nothing is
    // guessed for the rest. Marked here, in `commitFill`, and in the task
    // file as an UNREAD GATE — the single most valuable next reading.
    //
    // THE ONE MODELLED TERM, named so it is not mistaken for a measurement:
    // the ranking's 3-space distance is measured against the reference's own
    // internal cursor MODEL point, which is not a quantity we can read. We
    // use this tool's OWN established screen→world mapping for it
    // (`shiftedWorldPoint` — unproject the cursor onto the constant-view-
    // depth plane through the seed edge's midpoint), reusing the convention
    // every other gesture here already drags on rather than inventing a
    // second one. It is exact for the fronto-parallel planar rigs the rule
    // was measured on, and it is the term to revisit if a future reading
    // ever exposes the reference's own point.
    //
    // ENUMERATION ORDER is ours (ascending vertex index); the reference's
    // is a spatial structure's and was not read. It cannot change the
    // ANSWER: the eviction rule leaves the same SET whatever the order, and
    // the two-cyclic-order shape test then fixes the ring, so arrival order
    // survives into the result only as which of the two non-seed corners
    // sits in slot 2 before that test.
    // ------------------------------------------------------------------

    // Does the OPEN segment p1→p2 properly cross the OPEN segment q1→q2 —
    // both parameters strictly inside (0,1)? Pure screen-space arithmetic,
    // extracted so the reject's own predicate is unit-testable on hand
    // numbers. Touching at an endpoint, collinear overlap and parallel are
    // all FALSE: "properly" is the measured word, and it is what lets a
    // candidate that is itself a corner of the tested polygon survive.
    static bool segmentsProperlyCross(ImVec2 p1, ImVec2 p2, ImVec2 q1, ImVec2 q2) {
        immutable float rx = p2.x - p1.x, ry = p2.y - p1.y;
        immutable float sx = q2.x - q1.x, sy = q2.y - q1.y;
        immutable float denom = rx * sy - ry * sx;
        if (denom == 0.0f) return false;          // parallel or degenerate
        immutable float wx = q1.x - p1.x, wy = q1.y - p1.y;
        immutable float t = (wx * sy - wy * sx) / denom;
        immutable float u = (wx * ry - wy * rx) / denom;
        return t > 0.0f && t < 1.0f && u > 0.0f && u < 1.0f;
    }

    // The shape test: is the screen-space cycle a→b→c→d CONVEX? The four
    // corner cross products must all carry the SAME sign. A zero corner
    // (three collinear points) is neither sign and fails — which also keeps
    // a degenerate cycle out of the build.
    static bool screenQuadConvex(ImVec2 a, ImVec2 b, ImVec2 c, ImVec2 d) {
        ImVec2[4] p = [a, b, c, d];
        bool pos = false, neg = false;
        foreach (i; 0 .. 4) {
            immutable float ux = p[(i + 1) % 4].x - p[i].x;
            immutable float uy = p[(i + 1) % 4].y - p[i].y;
            immutable float vx = p[(i + 2) % 4].x - p[(i + 1) % 4].x;
            immutable float vy = p[(i + 2) % 4].y - p[(i + 1) % 4].y;
            immutable float cr = ux * vy - uy * vx;
            if      (cr > 0.0f) pos = true;
            else if (cr < 0.0f) neg = true;
            else return false;                    // collinear corner
        }
        return pos != neg;
    }

    // The SEED: which border edge this cursor pixel presses/hovers, or -1.
    //
    // Fill's press has NO reach radius — measured (task 0507), and it is why
    // a press at the bare centre of a gap, 32 px from the nearest border
    // edge where an ordinary selection click resolves nothing at all, still
    // classifies as an edge press and caps the cell. So the scan below is
    // unbounded on purpose; do NOT "unify" it onto `topoPenPressPickPx`.
    //
    // It is bounded by something else, and that too is measured: whatever
    // ELSE is nearer wins the press, and only an EDGE press can fill.
    //
    //   * a VERTEX nearer than every border edge makes this a vertex press,
    //     from which the reference's fill build is structurally unreachable
    //     — read statically AND observed live (a press at a hole's centre
    //     resolved an isolated vertex sitting inside the hole, and nothing
    //     happened). Ties go to the vertex, matching both this tool's own
    //     vertex→edge→face pick precedence and the reference's own
    //     vertex-favouring arbitration.
    //   * a POLYGON under the cursor likewise wins (a face the cursor is
    //     inside is at distance zero), and Fill has no polygon path. Needs
    //     `gpu_`'s BVH, so under a bare `dub test` this term is inert and
    //     the vertex term carries the same cases — the identical limitation
    //     `overPrimaryEdgeOrFace` documents.
    //
    // NOT PORTED, and named rather than guessed: the reference's press pick
    // also classifies INTERIOR edges, and an interior-edge press in Fill
    // mode would take the same destructive refusal path `fillDown`
    // implements for a border edge. No cell ever pressed an interior edge in
    // Fill mode, so that case is unmeasured and this scan simply does not
    // consider interior edges.
    private int fillSeedEdge(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (pickPrimaryFace(mx, my, vp) >= 0) return -1;   // POLYGON press

        immutable float cx = cast(float)mx, cy = cast(float)my;

        float bestVertD = float.infinity;
        foreach (vi; 0 .. m.vertices.length) {
            ImVec2 pv;
            if (!projectPt(m.vertices[vi], vp, pv)) continue;
            immutable float d = hypot(pv.x - cx, pv.y - cy);
            if (d < bestVertD) bestVertD = d;
        }

        // `edgePolygonCounts` rather than `isEdgeBorder`: the same predicate
        // (exactly one incident polygon) off the counter that cannot
        // undercount a non-manifold fan, hoisted once for the whole scan.
        const int[] polyCount = m.edgePolygonCounts();
        int   bestEdge  = -1;
        float bestEdgeD = float.infinity;
        foreach (ei, e; m.edges) {
            if (ei >= polyCount.length || polyCount[ei] != 1) continue;
            ImVec2 pa, pb;
            if (!projectPt(m.vertices[e[0]], vp, pa)) continue;
            if (!projectPt(m.vertices[e[1]], vp, pb)) continue;
            float t;
            immutable float d = closestOnSegment2D(cx, cy, pa.x, pa.y, pb.x, pb.y, t);
            if (d < bestEdgeD) { bestEdgeD = d; bestEdge = cast(int)ei; }
        }
        if (bestEdge < 0) return -1;
        if (bestVertD <= bestEdgeD) return -1;   // VERTEX press — no fill path
        return bestEdge;
    }

    // The candidate search itself, run from the seed `fillSeedEdge` resolved.
    // Returns the ring VERBATIM in the order the shape test accepted (4
    // corners, or 3 when `quadOnly` is off), or `null` when any gate refuses.
    // The hover preview and the commit both call this — the reference's own
    // draw path runs the identical search, so the highlight and the build
    // obey ONE rule and can never disagree.
    private uint[] findFillRing(int mx, int my, const ref Viewport vp) {
        immutable int seedEi = fillSeedEdge(mx, my, vp);
        if (seedEi < 0) return null;
        return fillRingFromSeed(cast(uint)seedEi, mx, my, vp);
    }

    private uint[] fillRingFromSeed(uint seedEi, int mx, int my, const ref Viewport vp) {
        auto m = mesh;
        if (m is null || seedEi >= m.edges.length) return null;
        immutable uint seedA = m.edges[seedEi][0];
        immutable uint seedB = m.edges[seedEi][1];
        if (seedA >= m.vertices.length || seedB >= m.vertices.length) return null;

        immutable float cx = cast(float)mx, cy = cast(float)my;
        ImVec2 pSeedA, pSeedB;
        if (!projectPt(m.vertices[seedA], vp, pSeedA)) return null;
        if (!projectPt(m.vertices[seedB], vp, pSeedB)) return null;

        // GATHER radius = range × the hover radius. `range` 0 leaves nothing
        // but the seeds reachable, so the count gate refuses — the measured
        // "below the threshold the gesture refuses" branch, at its extreme.
        immutable float reachPx =
            fillRange_ * fillHoverRadiusPx(cx, cy, pSeedA, pSeedB);

        // The cursor's 3-space point — the ONE modelled term, see the block
        // comment above.
        immutable Vec3 seedMid = (m.vertices[seedA] + m.vertices[seedB]) * 0.5f;
        immutable Vec3 cursorPt = shiftedWorldPoint(seedMid, mx, my, vp);

        // The screen segments the crossing reject tests against: every edge
        // of every polygon incident to EITHER seed, gathered once. The
        // reference walks seed → polygon → edge and marks polygons visited;
        // what that marking changes is UNREAD, but it cannot change this
        // boolean — testing one polygon twice yields the same answer — so the
        // union is equivalent for the predicate's purposes.
        ImVec2[2][] barriers;
        foreach (fi, const ref f; m.faces) {
            bool touchesSeed = false;
            foreach (v; f) if (v == seedA || v == seedB) { touchesSeed = true; break; }
            if (!touchesSeed || f.length < 2) continue;
            foreach (k; 0 .. f.length) {
                immutable uint u0 = f[k], u1 = f[(k + 1) % f.length];
                if (u0 >= m.vertices.length || u1 >= m.vertices.length) continue;
                ImVec2 q0, q1;
                if (!projectPt(m.vertices[u0], vp, q0)) continue;
                if (!projectPt(m.vertices[u1], vp, q1)) continue;
                barriers ~= [q0, q1];
            }
        }

        // Per-vertex polygon count + the single incident polygon when there
        // is exactly one — the qualifier's first two clauses read straight
        // off `faces[]`, hoisted once (never re-walked per candidate).
        auto npoly    = new uint[](m.vertices.length);
        auto onlyFace = new int[](m.vertices.length);
        onlyFace[] = -1;
        foreach (fi, const ref f; m.faces)
            foreach (v; f)
                if (v < npoly.length) {
                    if (npoly[v] == 0) onlyFace[v] = cast(int)fi;
                    ++npoly[v];
                }

        // The qualifier's third clause: carries at least one BORDER edge.
        const int[] polyCount = m.edgePolygonCounts();
        auto borderVert = new bool[](m.vertices.length);
        foreach (ei, e; m.edges)
            if (ei < polyCount.length && polyCount[ei] == 1) {
                if (e[0] < borderVert.length) borderVert[e[0]] = true;
                if (e[1] < borderVert.length) borderVert[e[1]] = true;
            }

        uint[4]  slot;
        float[4] dist;
        slot[0] = seedA; slot[1] = seedB;
        dist[0] = 0.0f;  dist[1] = 0.0f;
        enum size_t kSeedCount = 2;
        size_t n = kSeedCount;

        foreach (vi; 0 .. m.vertices.length) {
            immutable uint v = cast(uint)vi;

            // Already in the list — the enumerator re-offers the seeds, and
            // this drop is what the reference does with them, BEFORE the
            // qualifier ever runs.
            bool already = false;
            foreach (k; 0 .. n) if (slot[k] == v) { already = true; break; }
            if (already) continue;

            ImVec2 pv;
            if (!projectPt(m.vertices[v], vp, pv)) continue;
            if (hypot(pv.x - cx, pv.y - cy) > reachPx) continue;

            // QUALIFIER — isolated, or degenerate-polygon-only, or border.
            bool qualifies = false;
            if (npoly[v] == 0) qualifies = true;
            else if (npoly[v] == 1 && onlyFace[v] >= 0
                     && m.faces[onlyFace[v]].length <= 2) qualifies = true;
            else qualifies = borderVert[v];
            if (!qualifies) continue;

            // SCREEN-CROSSING REJECT.
            bool blocked = false;
            foreach (ref seg; barriers)
                if (segmentsProperlyCross(ImVec2(cx, cy), pv, seg[0], seg[1])) {
                    blocked = true;
                    break;
                }
            if (blocked) continue;

            // RANKING — four nearest in 3-space among the survivors.
            immutable float d = (m.vertices[v] - cursorPt).length;
            if (n < 4) {
                slot[n] = v; dist[n] = d; ++n;
            } else {
                // Replace the FARTHEST non-seed entry, and only with
                // something strictly nearer. Seeds are never scanned, which
                // is the whole of "pinned".
                size_t worst = size_t.max;
                float  worstD = d;
                foreach (k; kSeedCount .. 4)
                    if (dist[k] > worstD) { worstD = dist[k]; worst = k; }
                if (worst != size_t.max) { slot[worst] = v; dist[worst] = d; }
            }
        }

        // COUNT GATE.
        if (fillQuadOnly_) { if (n != 4) return null; }
        else               { if (n != 4 && n != 3) return null; }

        // n == 3 runs NO shape test at all — measured on two independent
        // rigs, two boots, two cameras.
        if (n == 3) return slot[0 .. 3].dup;

        ImVec2[4] sp;
        foreach (k; 0 .. 4)
            if (!projectPt(m.vertices[slot[k]], vp, sp[k])) return null;

        if (screenQuadConvex(sp[0], sp[1], sp[2], sp[3])) return slot[0 .. 4].dup;
        if (screenQuadConvex(sp[0], sp[1], sp[3], sp[2])) {
            immutable uint tmp = slot[2]; slot[2] = slot[3]; slot[3] = tmp;
            return slot[0 .. 4].dup;
        }
        return null;
    }

    // Fill mode radius overlay (task 0477 continuation): screen-nearest
    // BORDER edge to the cursor, gated at `thresholdPx` — feeds the
    // hover-reach circle's endpoints in `onMouseMotion` below, NOT cell
    // reconstruction (`findFillRing` above stays the sole source of truth
    // there; this is a read-only companion query over the SAME
    // `isEdgeBorder`/`projectPt` primitives). Mirrors `findRingSeedEdge`'s
    // point-to-segment scan (same `closestOnSegment2D` call), filtered to
    // border edges only — a gap's boundary is exactly its border edges.
    // Reuses `topoPenPressPickPx(vp)`, the same edge-pick tolerance every other
    // gesture in this tool already snaps at, rather than inventing a
    // second constant.
    private int findNearestBorderEdge(int mx, int my, const ref Viewport vp,
                                      float thresholdPx = kTopoPenSnapAuto) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (thresholdPx < 0.0f) thresholdPx = topoPenPressPickPx(vp);
        int   best  = -1;
        float bestD = float.infinity;
        foreach (ei, e; m.edges) {
            if (!m.isEdgeBorder(cast(uint)ei)) continue;
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

    // The NON-VERTEX half of the over-mesh GATE: true when the cursor is
    // over an EXISTING element of the primary layer that is NOT a vertex —
    // an edge within `topoPenPressPickPx` (`findRingSeedEdge`) or a face under
    // the cursor (`pickPrimaryFace`, front-most BVH pick, which covers the
    // "middle of a big face, nowhere near its rim" case an edge scan alone
    // misses).
    //
    // Extracted so the gate has exactly ONE definition, shared by its two
    // consumers (previously `onMouseMotion` inlined the only copy):
    //   * the Generic Hover-Highlight indicator's visibility gate
    //     (`overPrimaryMesh` below, `onMouseMotion`) — what the user SEES
    //     highlighted under the cursor;
    //   * the plain-LMB press's place-vs-decline decision
    //     (`onPlainLmbDown`) — what a press at that same pixel DOES.
    // Those two answers have to come from the same predicate: a press that
    // lands on an element the indicator is actively highlighting must not
    // be treated as a press on empty space (that mismatch is exactly the
    // stray-vertex defect `onPlainLmbDown` documents).
    //
    // `pickPrimaryFace` needs `gpu_` (its BVH is keyed on the GPU mesh's
    // upload version) and answers -1 without it, so under a bare `dub test`
    // (no GL, no `gpu_`) only the edge term is live — deliberate: the face
    // term is exercised by the HTTP tests, which have a real upload.
    private bool overPrimaryEdgeOrFace(int mx, int my, const ref Viewport vp) {
        return findRingSeedEdge(mx, my, vp, topoPenPressPickPx(vp)) >= 0
            || pickPrimaryFace(mx, my, vp) >= 0;
    }

    // The FULL over-mesh GATE (REV1 FIX-1 of doc/topopen_hover_highlight_plan.md,
    // preserved verbatim as an OR of the same three terms — only the
    // short-circuit order changed, which no caller can observe): the vertex
    // term plus `overPrimaryEdgeOrFace` above. A FINITE threshold on both
    // projection scans, deliberately a SEPARATE pass from
    // `computeHoverIndicator`'s own `∞`-threshold RESOLUTION scan — this
    // decides WHETHER the cursor is over the mesh, that decides WHAT to draw.
    private bool overPrimaryMesh(int mx, int my, const ref Viewport vp) {
        return findSourceVertex(mx, my, vp, topoPenPressPickPx(vp)) >= 0
            || overPrimaryEdgeOrFace(mx, my, vp);
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
    // directly. All 12 grid slots are present in `kTopoPenBindings` since task
    // 0499; every Alt combo is still ABSENT, so `resolveToolAction` answers
    // `PassThrough` for it and `dispatchInput` returns `false` without ever
    // calling `onToolAction`.
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                                    ref VectorStack vts) {
        // Take the gesture's snap configuration BEFORE dispatching: whichever
        // gesture this press turns out to arm, it runs on the ranges that were
        // live when the button went down (see `dragSnap_`). Unconditional and
        // free of any arm bool — the capture must happen even for a press that
        // goes on to decline, because `resetAllGestureArms()` runs INSIDE the
        // dispatch below and would otherwise be a place to lose it.
        captureSnapForGesture(vts);
        return dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
                             InputPhase.Down, e, vts);
    }

    /// Snapshot the live SNAP configuration for the gesture that is starting.
    /// Mirrors `XfrmToolBase.captureSnapForDrag` — same packet, same source,
    /// same "no stage registered ⇒ the init packet's defaults" fallback.
    private void captureSnapForGesture(ref VectorStack vts) {
        if (auto sp = vts.get!SnapPacket()) dragSnap_ = *sp;
        else                                dragSnap_ = SnapPacket.init;
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
        // Mode router (task 0483) — the per-press record of WHICH gesture the
        // unmodified-LMB slot resolved to. Neutral value first, so a press
        // that declines leaves behind an UP leg that is a guarded no-op
        // rather than a stale mode's commit.
        gestureOn_[]    = PenGesture.PlaceOrMove;
        // P3 build (doc/topopen_p3_plan.md)
        sourceVert_     = -1;
        dragArmed_      = false;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
        // P4 Move/Place (doc/topopen_p4_plan.md) + the task-0484 element grab.
        // `clearMoveArm` drops the live drag's base positions and its
        // arm-time snapshot WITHOUT recording anything — correct for every
        // caller of this helper: a same-slot re-press starts a fresh gesture,
        // and `resyncSession` runs when an external history navigation has
        // already replaced the mesh this drag was editing, so there is no
        // "before" left that a recorded entry could mean anything against.
        placeArmed_     = false;
        clearMoveArm();
        // P6 Add Loop (doc/topopen_p6_addloop_plan.md)
        addLoopSeed_    = -1;
        addLoopArmed_   = false;
        // P7 Slide (doc/topopen_p7_slide_plan.md)
        slideSeed_   = -1;
        slideArmed_  = false;
        slideEndA_ = slideEndB_ = -1;
        slideNbrA_ = slideNbrB_ = -1;
        slideAnchor_ = Vec3(0, 0, 0);
        slideDeltaK_ = 0.0f;
        // P8 Smooth (doc/topopen_p8_smooth_plan.md)
        smoothArmed_  = false;
        smoothDragDx_ = 0;
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
        // held) and uses its own narrow self-reset instead.
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
        // Duplicate EDGE (task 0485) — the Shift+LMB sibling; cleared here
        // for the same reason as every LEFT-button arm above.
        dupEdgeArmed_ = false;
        dupEdgeSeed_  = -1;
        dupEdgeEdges_ = null;
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
            || dupLoopArmed_ || smoothLoopArmed_ || dupEdgeArmed_;
    }

    // The Mode router (task 0483) — the ONE place the Mode dropdown, the
    // Edge Loop flag and the Edge Slide flag turn into a gesture. Every
    // branch delegates to a handler that ALREADY exists for the equivalent
    // modifier chord, so a mode and its chord run byte-identical code:
    //
    //     mode        loop=0            loop=1              measured chord
    //     ----------- ----------------- ------------------- ----------------------
    //     Move        move (or slide)   move loop           LMB   / RMB
    //     Duplicate   build             dup loop            Shift+LMB / Shift+RMB
    //     Remove      remove            remove (loop on an  Ctrl+MMB
    //                                   edge-latched press)
    //     Split       split             split               MMB
    //     AddLoop     add loop          add loop            Shift+MMB
    //     Point       place-or-move     place-or-move-loop  (no chord)
    //     Fill        fill              fill                (no chord)
    //     Smooth      smooth            smooth loop         Shift+Ctrl+LMB / Shift+Ctrl+RMB
    //
    // Remove is the one row whose loop column is conditional, and the table
    // cannot express why: the flag is read by the primitive Remove chooses
    // from the PRESSED ELEMENT'S CLASS, not by the router. See `removeDown`.
    //
    // The chords themselves are untouched and remain ABSOLUTE: they resolve
    // through `kTopoPenBindings` to their own action whatever this dropdown
    // says, so the modeless chord workflow keeps working unchanged and a
    // mode is never able to shadow it.
    //
    // The resolved action is RECORDED in `gestureOn_` so the matching
    // RELEASE (`lmbModeUp`) reaches the same gesture's commit leg even if
    // the dropdown is written mid-drag (`tool.attr` is reachable over HTTP
    // at any time) — resolving the mode a second time at release would
    // otherwise commit a gesture nobody armed.
    private bool onPlainLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        return runPenMode(penMode_, edgeLoop_, edgeSlide_, InputButton.Left, e, vts);
    }

    // THE mode dispatcher (task 0487) — the one place a resolved
    // (mode, loop, slide) triple turns into a gesture. Every chord reaches it:
    // the chord contributes its overrides (`kChordOv`), the user's dropdown and
    // flags supply the rest, and this runs the result. Before this refactor the
    // ten chords each named a gesture outright, so a chord could not compose
    // with the dropdown at all.
    //
    // `btn` is the physical button the gesture is booked against, taken from
    // the chord's own slot rather than from the event — a release then reaches
    // the same gesture's commit leg, per button, so a MIDDLE chord fired
    // during a held LEFT drag cannot redirect the LEFT release.
    //
    // The gesture is stamped AFTER the delegated handler returns, never
    // before: a commit-on-DOWN gesture (Remove) runs `resyncSession()` inside
    // its own handler, which calls `resetAllGestureArms()` and would wipe a
    // record written up front. Stamping last makes the field describe the
    // press that just happened, whatever the handler did along the way.
    private bool runPenMode(PenMode mode, bool loop, bool slide, InputButton btn,
                            ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        final switch (mode) {
        case PenMode.Move:
            return moveOrPlaceDown(e, vts, false, loop, slide, btn);
        case PenMode.Point:
            return moveOrPlaceDown(e, vts, true, loop, slide, btn);
        case PenMode.Duplicate:
            // Two variants, one implementation each, both on this path: the
            // loop variant gathers and trims (`onDupLoopShiftRmbDown`), the
            // plain one takes the pressed edge alone. Both carry the border
            // gate (task 0486 C-0). Measured BIT-IDENTICAL to the Shift+LMB /
            // Shift+RMB chords respectively, which is why those chords are
            // just (mode=Duplicate, loop=...) rows now.
            if (loop) return stamp(onDupLoopShiftRmbDown(e, vts), PenGesture.DupLoop, btn);
            return stamp(onShiftLmbDown(e, vts), PenGesture.Build, btn);
        case PenMode.Remove:
            // ONE branch, and it is inside the handler rather than here (task
            // 0494): the loop flag is read by the EDGE primitive alone, so a
            // Remove press that latches a polygon or a vertex runs the same
            // thing with the flag on or off. Stamping a separate
            // "remove loop" gesture here would therefore mislabel two thirds of
            // the presses. Commits on DOWN and arms nothing.
            return stamp(removeDown(e, vts, loop), PenGesture.Remove, btn);
        case PenMode.Split:
            return stamp(onPlainMmbDown(e, vts), PenGesture.Split, btn);
        case PenMode.AddLoop:
            return stamp(onShiftMmbDown(e, vts), PenGesture.AddLoop, btn);
        case PenMode.Smooth:
            if (loop) return stamp(onSmoothLoopRmbDown(e, vts), PenGesture.SmoothLoop, btn);
            return stamp(onShiftCtrlLmbDown(e, vts), PenGesture.Smooth, btn);
        case PenMode.Fill:
            return fillDown(e, vts, btn);
        }
    }

    // Record `a` as the gesture this press resolved to and pass `consumed`
    // straight through — the router's one-liner for "delegate, then stamp".
    private bool stamp(bool consumed, PenGesture g, InputButton btn) {
        if (btn != InputButton.None) gestureOn_[btn] = g;
        return consumed;
    }

    // Fill OWNS the plain-LMB slot and NEVER falls through to place. The
    // build commits on DOWN (like Remove): the ring is fully determined by
    // the DOWN pixel, there is no drag to defer.
    //
    // A REFUSAL IS DESTRUCTIVE (task 0488, measured — and this is the single
    // most surprising thing this port changes). vibe3d shipped a clean no-op
    // on a miss. The reference does not: when the candidate search refuses,
    // the press falls through to GRABBING THE PRESSED BORDER EDGE and moving
    // it — the measured refusals displaced the edge's two vertices onto the
    // background-constraint plane, to within 0.05 % of that plane's own
    // offset, undone in a single step. That retroactively explains a run of
    // earlier observations filed as "the nearest vertex moved but no facet
    // appeared": they were not failures to reach the engine, they were this
    // branch.
    //
    // Ported as an ARM, not as an immediate write: the miss arms this tool's
    // own Move gesture on the pressed border edge, so the drag and the
    // release run the Move law already measured for an edge grab (one shared
    // screen delta, per-vertex nearest-foot re-snap to the background, ONE
    // undo entry at release, and Move's own 3px click-vs-drag gate). That
    // reuses a measured law instead of inventing a second one for this
    // branch, and it keeps the refusal undoable in exactly one step, which
    // the measurement also reports.
    //
    // Still always consumed, either way — no other mode's place/move may
    // fire underneath an active Fill-mode click.
    private bool fillDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts,
                          InputButton btn) {
        // `PlaceOrMove` is also the slot whose UP leg runs `finishMove`, so
        // the destructive-refusal arm below needs no new gesture tag.
        stamp(true, PenGesture.PlaceOrMove, btn);
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;

        immutable int seedEi = fillSeedEdge(e.x, e.y, vp);
        if (seedEi < 0) return true;   // no border-edge press at all — nothing to fill OR move

        auto ring = fillRingFromSeed(cast(uint)seedEi, e.x, e.y, vp);
        if (ring.length >= 3) { commitFill(ring); return true; }

        armMoveOnEdge(cast(uint)seedEi, e);
        return true;
    }

    // P2/P4 (doc/topopen_p2_plan.md, doc/topopen_p4_plan.md, Design A), now
    // the Move / Point modes' shared DOWN leg: a plain (unmodified) LEFT
    // press disambiguates HERE, at press time, between grabbing an existing
    // primary-layer vertex (Move) and placing a new one on the background
    // surface (Place) — reusing P3's `findSourceVertex` (the SAME
    // `topoPenPressPickPx` screen-space threshold, over the PRIMARY mesh only;
    // the background is the snap reference, never grabbed). Neither outcome
    // commits here: both are armed only, and the actual mutation happens on
    // RELEASE (`onMouseButtonUp`) at THAT event's own CONS-snapped hit — a
    // stationary click's DOWN+UP pixel pair therefore still yields exactly
    // one placement/no mutation, same as the pre-P4 DOWN-commit behavior
    // (byte-identity gate, P4 step 1).
    //
    // `placeOnEmpty` is what separates the two modes, and it is the ONLY
    // thing that does: Point places a vertex on an empty-space press, Move
    // declines it (the reference's Move mode has nothing to move there;
    // placing is Point's job). A press that lands on GEOMETRY runs the same
    // move family in both — which is the reference's own definition of its
    // Point mode ("if you click any geometry component in this mode, then
    // the tool works as in the Move mode").
    //
    // "Place" means EMPTY SPACE, not merely "no vertex resolved": a press
    // that lands on the primary layer's existing EDGE or FACE arms neither
    // gesture and is DECLINED (see the geometry branch below for the full
    // rationale) — it is a press on an element this tool has no plain-LMB
    // gesture for, never a placement. So the handler claims the event for
    // both of its own outcomes, and only for those.
    private bool moveOrPlaceDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts,
                                 bool placeOnEmpty, bool loop, bool slide,
                                 InputButton btn) {
        stamp(true, PenGesture.PlaceOrMove, btn);

        // Edge Loop / Edge Slide resolve FIRST, above the on-geometry gate —
        // each routes to the very handler its equivalent chord routes to, and
        // those handlers do their OWN pick and their OWN decline bookkeeping.
        // Checking them after the gate (as an earlier draft of task 0487 did)
        // silently swallowed that bookkeeping: a Ctrl+LMB press with no edge in
        // range never reached `onCtrlLmbDown`, so `slideDecline_` kept reading
        // "none" where it must read "no_edge" — the diagnostic channel task
        // 0482 added on purpose, and the regression the suite caught. Resolving
        // them here also keeps both byte-identical to the pre-refactor chords,
        // which went straight to their handler whatever was under the cursor.
        //
        // Edge Loop wins when both are set: there is no slide-a-whole-loop
        // gesture in this tool, so a loop press is the only one of the two that
        // can be honoured.
        if (loop)  return stamp(onMoveLoopRmbDown(e, vts), PenGesture.MoveLoop, btn);
        if (slide) return stamp(onCtrlLmbDown(e, vts),     PenGesture.Slide,    btn);

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int src = findSourceVertex(e.x, e.y, vp);

        // Is this press on GEOMETRY at all? `||` short-circuits, so a press
        // that resolved a vertex never pays for the `overPrimaryEdgeOrFace`
        // scan — the same call pattern this handler has always had.
        if (src >= 0 || overPrimaryEdgeOrFace(e.x, e.y, vp)) {
            // The Move grab (task 0484). Resolve WHICH element is under the
            // cursor by proximity — vertex, else edge, else the face the
            // cursor is over — and arm that element's whole vertex set. A
            // press on an edge or a face used to be DECLINED here
            // (doc/tasks/done/0482-topopen-move-nonvertex.md: the behaviour
            // was unmeasured, and inventing one would have been worse than
            // the gap); the reference's own Move description settles it —
            // Move slides "an element ... against the background surface",
            // and is "useful in editing vertices, edges, and polygons".
            //
            // A press that lands on geometry the pick cannot resolve into any
            // element still declines, for the reasons the old guard spelled
            // out: with a tool active app.d gates every selection/camera
            // branch on `!anyToolActive`, so a declined press changes no
            // selection, records no undo entry and mutates nothing, and the
            // release is safe because `lmbPlaceOrMoveUp` trusts the arm BOOLS
            // rather than the base's `armed_[]` slot (the documented
            // arm-before-decline gap).
            return armMoveElement(e, vts, vp);
        }

        // Empty space. Only Point mode places here; Move mode has nothing to
        // move and declines, exactly like every other miss in this tool.
        if (!placeOnEmpty) return false;

        placeArmed_ = true;
        return true;
    }

    // WHICH element the cursor is on — the single source of truth for both
    // "what would a press grab" (`armMoveElement`) and "what does the hover
    // indicator highlight" (`onMouseMotion`/`draw`). Those two answers MUST
    // come from one function: a highlight that names a different element than
    // the press takes is worse than no highlight, because the user aims by it.
    //
    // Proximity order — vertex within `topoPenPressPickPx`, else edge within the
    // same radius, else the face under the cursor. `index` is the resolved
    // element's own index in its own array (vertex / edge / face), or -1.
    //
    // `pickPrimaryFace` needs `gpu_` and answers -1 without it, so under a
    // bare `dub test` (no GL) only the vertex and edge terms are live — the
    // face term is exercised by the HTTP tests, which have a real upload.
    private MoveElem resolveGrabTarget(int mx, int my, const ref Viewport vp, out int index) {
        index = -1;
        auto m = mesh;
        if (m is null) return MoveElem.None;

        // Explicit `>= 0` on every pick, never a truthiness test: these
        // answer -1 on a miss, and index 0 is a perfectly ordinary element.
        immutable int vi = findSourceVertex(mx, my, vp);
        if (vi >= 0 && vi < cast(int)m.vertices.length) { index = vi; return MoveElem.Vertex; }

        immutable int ei = findRingSeedEdge(mx, my, vp);
        if (ei >= 0 && ei < cast(int)m.edges.length) { index = ei; return MoveElem.Edge; }

        immutable int fi = pickPrimaryFace(mx, my, vp);
        if (fi >= 0 && fi < cast(int)m.faces.length && m.faces[fi].length >= 3) {
            index = fi;
            return MoveElem.Face;
        }
        return MoveElem.None;
    }

    // The hover indicator element `draw()` actually paints: the RESOLVED grab
    // target (`hoverGrabElem_`) filtered by the two display toggles (task
    // 0499). `draw()` switches on THIS, never on `hoverGrabElem_` directly, so
    // the toggle cannot be honoured in one of the two places and forgotten in
    // the other — and so a unittest can pin the drawn outcome without an ImGui
    // draw list.
    //
    // Display-only, by construction: this never feeds `armMoveElement`, so a
    // hidden indicator still grabs exactly the same element on a press.
    // Hiding the marker does not disable the grab — that would be a behavior
    // claim nothing measured.
    //
    // `MoveElem.Face` passes through unfiltered: the reference has two
    // toggles, not three, and inventing a `showPolygon` here would be exactly
    // the kind of guessed knob task 0499 exists to refuse.
    private MoveElem hoverIndicatorElem() const {
        final switch (hoverGrabElem_) {
        case MoveElem.Vertex: return showVertex_ ? MoveElem.Vertex : MoveElem.None;
        case MoveElem.Edge:   return showEdge_   ? MoveElem.Edge   : MoveElem.None;
        case MoveElem.Face:   return MoveElem.Face;
        case MoveElem.None:   return MoveElem.None;
        }
    }

    // The border-run TRIM (task 0486, measured — implementer contract C-4 in
    // toolcards/topology_pen/dragweld_dupedge_loopscope_capture.md, PRIVATE).
    //
    // The gather and the COMMITTED SET are two different sets, and only the
    // gather was ported. `Mesh.selectLoopEdges` is the right gather — its
    // border branch walking the whole open boundary is what the reference's
    // own gather does, confirmed edge-for-edge on a 12-edge perimeter. What
    // was missing is the filter the reference applies between gathering and
    // committing, and only when the pressed edge is a BORDER edge:
    //
    //     4x4 grid, top border seed:  gather 12 (whole perimeter) -> commit 3
    //     flat annulus, outer border: gather  8 (closed ring)     -> commit 8
    //
    // So it is a no-op on a CLOSED boundary and only bites on an OPEN one —
    // which is exactly why a port that never trims looks correct on a cylinder
    // and duplicates the entire perimeter of a retopo patch. That 12-vs-3 is
    // the owner-reported "it takes all edges".
    //
    // The rule: keep the seed, walk the border chain outward from BOTH of its
    // endpoints, and stop at the first chain-end vertex with a single incident
    // polygon (a patch corner). The annulus is unchanged because its boundary
    // has no such vertex — which also refutes any GEOMETRIC co-linearity
    // phrasing of the rule: that boundary turns 45 degrees at every vertex and
    // still survives whole. The predicate is topological.
    //
    // "One incident polygon" and "valence 2" are the SAME test here, and that
    // is a structural fact, not a property of the rigs the capture happened to
    // use. The trim only ever evaluates a vertex it reached ALONG A BORDER EDGE
    // (the seed is border-gated by `armDuplicateOnEdge` /
    // `onDupLoopShiftRmbDown`, and every hop below is filtered by
    // `isEdgeBorder`), so that vertex's dart fan is OPEN — and an open fan
    // yields corners+1 edges (`VertexEdgeRange` emits the extra open-end edge)
    // against corners faces (`VertexFaceRange`):
    //
    //     vertexValence(v) == polyCount(v) + 1     for every vertex the walk
    //                                              can reach
    //
    // so `polyCount <= 1` and `vertexValence == 2` coincide identically.
    // Combinatorially (this also covers an unordered-fan enumerator): every
    // polygon at v occupies exactly two of v's edge slots, so
    // 2*polyCount(v) == sum over e at v of |faces(e)|; at valence 2 each
    // incident polygon must use BOTH of v's edges, hence
    // |faces(e1)| == |faces(e2)| == polyCount(v), and the edge the walk
    // arrived on is a border edge with exactly one face, so polyCount == 1.
    // The converse is immediate. The polygon-count phrasing is the one coded
    // because the reference's own branching is on the polygon count.
    //
    // CAVEAT, and it is a real one: the equivalence holds for the DART-FAN
    // degree only. A degree read off the raw `edges[]` array
    // (`Mesh.edgeNeighbors`) separates the two phrasings, because a face-less
    // edge is listed in `edges[]` but owns no dart — and this tool creates
    // face-less edges itself (`BuildCase.Edge` in `buildFromSource`). A wire
    // spur on a patch corner reads raw degree 3 while the fan reads valence 2.
    // Wire is not even needed to separate them: two quads meeting at ONE
    // vertex read raw degree 4 there against fan valence 2, because the fan
    // sees only one of the two fans. Do NOT "simplify" the stop test onto that
    // enumerator: the reference behaviour on either shape is unmeasured. The
    // equivalence and both separating shapes are pinned by the unittest below
    // this class.
    private int[] trimBorderRunAroundSeed(const(int)[] gathered, int seed) {
        auto m = mesh;
        if (m is null || seed < 0 || seed >= cast(int)m.edges.length) return null;

        // Only edges the gather already returned may survive — the trim
        // narrows a set, it never invents an edge the walk did not reach.
        bool[int] inSet;
        foreach (ei; gathered) inSet[ei] = true;
        if ((seed in inSet) is null) return [seed];

        size_t polyCount(uint vi) {
            size_t n = 0;
            foreach (fi; m.facesAroundVertex(vi)) ++n;
            return n;
        }

        int[] run = [seed];
        bool[int] taken;
        taken[seed] = true;

        foreach (endpoint; [m.edges[seed][0], m.edges[seed][1]]) {
            uint cur  = endpoint;
            int  came = seed;
            while (true) {
                if (polyCount(cur) <= 1) break;   // chain-end corner -> stop this direction
                int next = -1;
                foreach (ei; m.edgesAroundVertex(cur)) {
                    immutable int e2 = cast(int) ei;
                    if (e2 == came) continue;
                    if ((e2 in inSet) is null) continue;
                    if ((e2 in taken) !is null) continue;
                    if (!m.isEdgeBorder(cast(uint) e2)) continue;
                    next = e2;
                    break;
                }
                if (next < 0) break;
                taken[next] = true;
                run ~= next;
                auto ep = m.edges[next];
                cur  = (ep[0] == cur) ? ep[1] : ep[0];
                came = next;
            }
        }
        return run;
    }

    // The Duplicate slot's EDGE outcome (task 0486, contract C-0/C-1/C-4).
    // `loopFlag` is the slot's effective Edge Loop: `edgeLoop_` for Shift+LMB,
    // forced true for Shift+RMB (C-1 — the chord stores the literal 1 and
    // never reads the attribute, measured both directions).
    //
    // C-0 gates everything else here: Duplicate requires a BORDER edge. On an
    // interior edge the reference silently runs MOVE instead — so a Shift+LMB
    // there is a 2-vertex element move and a Shift+RMB there is a move-loop,
    // NOT a declined press and NOT a duplicate. This is the gate that makes
    // the rest of the contract coherent, and it was found only because the
    // capture recorded the engine's own guard value per press.
    private bool armDuplicateOnEdge(ref const SDL_MouseButtonEvent e, ref VectorStack vts,
                                    const ref Viewport vp, int seed, bool loopFlag) {
        auto m = mesh;
        if (m is null || seed < 0 || seed >= cast(int)m.edges.length) return false;

        if (!m.isEdgeBorder(cast(uint) seed)) {
            // Interior seed -> the Move family, per the effective loop flag.
            if (loopFlag) return stamp(onMoveLoopRmbDown(e, vts), PenGesture.MoveLoop,
                                       InputButton.Left);
            return stamp(armMoveElement(e, vts, vp), PenGesture.PlaceOrMove, InputButton.Left);
        }

        // The LOOP variant is `onDupLoopShiftRmbDown`'s job (gather + trim);
        // this path is the single pressed edge, so there is exactly one
        // implementation of each and no chance of the two drifting apart.
        int[] edges = [seed];

        dupEdgeSeed_   = seed;
        dupEdgeEdges_  = edges;
        dupEdgeStartX_ = dupEdgeCurX_ = e.x;
        dupEdgeStartY_ = dupEdgeCurY_ = e.y;
        dupEdgeArmed_  = true;
        return true;
    }

    // Resolve the element under a Move-family press and arm it (task 0484).
    // `srcVert` is the caller's already-computed `findSourceVertex` result,
    // passed in rather than recomputed so the pick runs exactly once per
    // press. Returns false — arming nothing — when no element resolves.
    //
    // The edge/face picks here repeat the two `overPrimaryEdgeOrFace` just
    // ran for the caller's on-geometry gate. Deliberately NOT folded into one
    // pass: the gate answering true while this returns false — a degenerate
    // (<3 corner) face, a stale index — must stay a DECLINE, and folding them
    // would turn exactly that case into a fall-through to Place, which is the
    // stray-vertex defect 0482 closed. One extra edge scan and one BVH pick,
    // per PRESS (never per motion event), buys that guarantee.
    private bool armMoveElement(ref const SDL_MouseButtonEvent e, ref VectorStack vts,
                                const ref Viewport vp) {
        auto m = mesh;
        if (m is null) return false;

        int index;
        immutable MoveElem kind = resolveGrabTarget(e.x, e.y, vp, index);
        if (kind == MoveElem.None) return false;
        return armMoveOn(kind, index, e);
    }

    // Fill's destructive refusal (task 0488) grabs a border edge the search
    // ALREADY resolved, not one a fresh pick would find, so the arm is
    // factored out of `armMoveElement` above rather than duplicated: one
    // definition of what "the Move gesture is now armed on this element"
    // means, so the two entry points can never drift.
    private bool armMoveOnEdge(uint ei, ref const SDL_MouseButtonEvent e) {
        auto m = mesh;
        if (m is null || ei >= m.edges.length) return false;
        return armMoveOn(MoveElem.Edge, cast(int)ei, e);
    }

    private bool armMoveOn(MoveElem kind, int index, ref const SDL_MouseButtonEvent e) {
        auto m = mesh;
        if (m is null) return false;

        uint[] verts;
        final switch (kind) {
        case MoveElem.Vertex:
            if (index < 0 || index >= cast(int)m.vertices.length) return false;
            verts = [cast(uint) index];
            break;
        case MoveElem.Edge:
            if (index < 0 || index >= cast(int)m.edges.length) return false;
            verts = [m.edges[index][0], m.edges[index][1]];
            break;
        case MoveElem.Face:
            if (index < 0 || index >= cast(int)m.faces.length) return false;
            verts = m.faces[index].dup;
            break;
        case MoveElem.None: return false;
        }
        if (verts.length == 0) return false;

        // A face's corner list can name the same vertex twice on a
        // malformed polygon; moving one twice is harmless but recording it
        // twice in `moveBase_` is not (the second copy would carry a
        // stale base). Deduplicate, preserving order.
        uint[] uniq;
        foreach (vi; verts) {
            if (vi >= m.vertices.length) return false;   // stale pick — arm nothing
            bool seen = false;
            foreach (u; uniq) if (u == vi) { seen = true; break; }
            if (!seen) uniq ~= vi;
        }

        moveElem_    = kind;
        moveVerts_   = uniq;
        moveBase_.length = uniq.length;
        foreach (i, vi; uniq) moveBase_[i] = m.vertices[vi];
        moveStartX_  = e.x;
        moveStartY_  = e.y;
        moveDirty_   = false;
        moveArmed_   = true;
        grabbedVert_ = (kind == MoveElem.Vertex) ? cast(int) uniq[0] : -1;
        return true;
    }

    // Where the armed moving set belongs for a cursor at (px,py) — the ONE
    // place the two Move laws live, so the live preview and the release
    // commit can never drift apart (task 0484).
    //
    //   Vertex — P4's measured law, unchanged: the grabbed vertex goes TO the
    //            cursor's own constrained hit. A cursor that misses every
    //            background surface leaves it where it started.
    //   Edge/Face — Move Loop's measured law: one shared SCREEN delta from
    //            the press pixel, applied to each vertex's ARM-TIME position
    //            and re-snapped to the background independently, a per-vertex
    //            miss keeping that vertex's original position.
    //
    // Always computed from `moveBase_`, never from the live positions, so N
    // motion events produce the same answer as one — no compounding.
    private Vec3[] moveTargets(int px, int py, const ref Viewport vp, ref VectorStack vts) {
        if (moveElem_ == MoveElem.Vertex) {
            Vec3[] one = [ moveBase_[0] ];
            readHit(vts);   // the CONS-snapped hit for THIS event's pixel
            if (lastHit_.hit) one[0] = lastHit_.point;
            return one;
        }

        // Click-vs-drag gate, inherited WITH the screen-delta law from Move
        // Loop (`moveLoopUp`'s own `kMinDragPx`) — every gesture in this tool
        // that re-snaps a whole set by a shared delta carries it. Without it
        // a bare CLICK on an edge or a face would apply a zero delta, which
        // is NOT a no-op: each vertex would re-snap to whatever background
        // surface sits under its own pixel, yanking the element onto the
        // background just for being clicked. Below the threshold the set
        // stays exactly where it is.
        enum int kMinDragPx = 3;
        immutable int dx = px - moveStartX_, dy = py - moveStartY_;
        if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return moveBase_.dup;

        return perVertexTargetsFrom(moveBase_, dx, dy, vp);
    }

    // Apply `targets` to the armed moving set in place — the live half of the
    // drag (task 0484). No snapshot, no history: `moveBefore_` was taken at
    // arm time and the single undo entry is recorded once, at release
    // (`finishMove`). Sets `moveDirty_` so a gesture that never actually
    // moved anything stays a true no-op.
    private void applyMoveTargets(const(Vec3)[] targets) {
        auto m = mesh;
        if (m is null || targets.length != moveVerts_.length) return;
        foreach (vi; moveVerts_)
            if (vi >= m.vertices.length) return;   // stale arm — defensive

        enum float kMoveEps = 1e-4f;   // stationary-grab / all-on-surface no-move guard
        bool changed = false;
        foreach (i, vi; moveVerts_)
            if ((targets[i] - m.vertices[vi]).length > kMoveEps) { changed = true; break; }
        if (!changed) return;

        // The undo baseline is captured LAZILY, at the first write of the
        // gesture rather than at arm time: a press that never drags — by far
        // the common case, every click this tool sees — then costs no
        // whole-mesh snapshot at all. `moveDirty_` is still false here, so
        // the mesh is untouched by this gesture and this IS the pre-gesture
        // state.
        if (!moveDirty_) moveBefore_ = MeshSnapshot.capture(*m);

        foreach (i, vi; moveVerts_) m.vertices[vi] = targets[i];
        m.commitChange(MeshEditScope.Position);
        moveDirty_ = true;

        m.syncSelection();
        if (gpu_ !is null) gpu_.upload(*m);
        refreshDisplay(m, gpu_, vc_, ec_, fc_);
    }

    // Close an armed Move: apply the FINAL targets, then record the whole
    // drag as ONE undo entry (task 0484). The final positions come from the
    // caller's event pixel — the release's own, exactly as before this
    // gesture went live — so where a Move lands is unchanged; the live writes
    // only decided what the user saw on the way there.
    //
    // Records nothing when the mesh never actually moved (`moveDirty_` false
    // after the final apply): a stationary click, or a drag whose every
    // vertex missed the background surface, stays the byte-identical no-op it
    // has always been. Disarms unconditionally on the way out.
    private void finishMove(int px, int py, const ref Viewport vp, ref VectorStack vts) {
        scope(exit) clearMoveArm();
        if (!moveArmed_ || moveVerts_.length == 0) return;
        applyMoveTargets(moveTargets(px, py, vp, vts));
        recordLiveMove();
    }

    // Record whatever the live drag has already written, WITHOUT computing
    // new targets — the tool-switch path (`deactivate`), which has no event
    // and therefore no pixel to compute them for. Disarms afterwards, so a
    // reactivation starts clean.
    private void commitLiveMoveIfDirty() {
        if (!moveArmed_) return;
        scope(exit) clearMoveArm();
        recordLiveMove();
    }

    // The single undo entry for an armed Move drag: `moveBefore_` (arm time)
    // paired with the mesh as it stands now. A gesture that moved nothing
    // records nothing — a stationary click, or a drag whose every vertex
    // missed the background surface, stays the byte-identical no-op it has
    // always been.
    private void recordLiveMove() {
        if (!moveDirty_) return;
        auto m = mesh;
        if (m is null || history_ is null || moveEditFactory_ is null) return;

        // A drag that wandered and came home again HAS written the mesh
        // (`moveDirty_`), but its net effect is nothing — recording it would
        // put an undo entry on the stack that restores what is already there.
        // Compare the moving set against its arm-time base and drop the
        // entry when they agree; only the moving set can have changed, so
        // this stays O(set), not O(mesh).
        enum float kNetEps = 1e-4f;   // the same eps `applyMoveTargets` writes by
        bool net = false;
        foreach (i, vi; moveVerts_) {
            if (vi >= m.vertices.length) { net = true; break; }   // stale: record, don't lose it
            if ((m.vertices[vi] - moveBase_[i]).length > kNetEps) { net = true; break; }
        }
        if (!net) return;

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = moveEditFactory_();
        cmd.setSnapshots(moveBefore_, after, "Topology Move");
        history_.record(cmd);
        // Position-only edit: no `resyncSession()` — no index this or any
        // sibling gesture caches can have been invalidated (the same
        // reasoning `commitMoveLoop` documents).
    }

    // Drop the arm WITHOUT recording. Every caller either has already
    // recorded (`finishMove`, `commitLiveMoveIfDirty`) or genuinely has
    // nothing to record — `resyncSession`, where an external history
    // navigation has already replaced the mesh this drag was editing, so an
    // (arm-time, post-navigation) snapshot pair would describe a transition
    // that never happened.
    //
    // ONE narrow consequence, deliberately not machined around: a MIDDLE- or
    // RIGHT-button gesture that commits while a LEFT Move drag is still held
    // (a legitimate two-button chord — see `resetAllGestureArms`'s own note)
    // routes through `resyncSession` too, so the live delta so far is not
    // recorded as its OWN entry. It is not lost and the mesh is not
    // corrupted: that sibling captured its `before` AFTER these writes, so
    // the delta is simply part of its baseline and survives its undo. Only
    // the granularity differs, and only for that chord.
    private void clearMoveArm() {
        moveArmed_   = false;
        grabbedVert_ = -1;
        moveElem_    = MoveElem.None;
        moveVerts_   = null;
        moveBase_    = null;
        moveDirty_   = false;
        moveBefore_  = MeshSnapshot.init;
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
        if (src < 0) {
            // Not a vertex — try an EDGE (task 0485). The reference's
            // Duplicate mode "duplicates an edge as you drag it", and widens
            // that to a whole loop only "with Edge Loop enabled or by
            // dragging with the right mouse button": Shift+LMB on an edge is
            // the ONE-edge case of the operation Shift+RMB already runs, so
            // it arms here and commits through the same `commitDupEdges`
            // kernel with a one-element list. Dragging an edge sideways
            // therefore builds the quad between it and its duplicate — the
            // single most common retopo stroke, and the one this slot used to
            // decline outright.
            int ei = findRingSeedEdge(e.x, e.y, vp);
            if (ei < 0) return false;   // neither vertex nor edge -> no documented gesture

            // Task 0486 (contract C-1): this slot READS `edgeLoop_` — measured
            // both ways on one seed (1 quad with the flag off, 3 with it on).
            // Its Shift+RMB sibling does the opposite and ignores the flag.
            return armDuplicateOnEdge(e, vts, vp, ei, edgeLoop_);
        }

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

    // The Remove mode's DOWN leg (P5, doc/topopen_p5_remove_plan.md D2;
    // REWRITTEN by task 0494) — remove-on-DOWN: one press removes exactly one
    // thing and commits it, with no `onMouseButtonUp` involvement (that handler
    // stays LEFT-only, so this is disjoint from the P3 build / P4 Move LMB
    // arms) and no armed state of its own, so it naturally caps at one removal
    // per press. A held drag emits no further removes — drag-sweep Remove is
    // UNMEASURED and stays deferred. A miss is a clean no-op but the gesture is
    // still CONSUMED (`return true`) either way, so a Remove press never falls
    // through to camera/selection handling.
    //
    // WHAT IT REMOVES IS THE CLASS OF THE ELEMENT THE PRESS LATCHED — task
    // 0494's headline, and the thing this handler used to get wrong. It used to
    // call `pickPrimaryFace` and delete a polygon whatever the cursor was over.
    // Measured on one 4x4 rig, three presses, the element class read out of the
    // engine on each:
    //
    //     latched   primitive                                       V/E/F
    //     --------  ---------------------------------------------   --------
    //     polygon   delete the polygon, keep the orphans            16/24/8
    //     edge      DISSOLVE it (its two polygons merge into one)   16/23/8
    //     vertex    merge its whole fan, then drop the vertex       15/20/6
    //
    // So an edge-latched press provably never removes a polygon, and neither
    // does a vertex-latched one. There is no border precondition on any of the
    // three (unlike Duplicate, which has one).
    //
    // The resolver is `resolveGrabTarget` — the SAME one the hover highlight
    // paints from and the Move grab presses through. That is not a convenience:
    // the highlight is how the user aims a destructive click, so the two must
    // answer with one function or the highlight names one element and the press
    // eats another.
    //
    // `loop` reaches only the edge primitive, because that is the only one that
    // reads it (the dispatcher does not) — a Remove press with Edge Loop on
    // that lands on a polygon still removes exactly that polygon.
    private bool removeDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts,
                            bool loop) {
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int idx;
        final switch (resolveGrabTarget(e.x, e.y, vp, idx)) {
        case MoveElem.Vertex: removeVertexAt(idx);      break;
        case MoveElem.Edge:   removeEdgeAt(idx, loop);  break;
        case MoveElem.Face:   removeFaceAt(idx);        break;
        case MoveElem.None:   break;   // resolved nothing — clean no-op
        }
        return true;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2): project every EDGE of the
    // PRIMARY layer's mesh and return the nearest within `topoPenPressPickPx`, or
    // -1 — mirrors `findSourceVertex` above (same threshold, same
    // self-contained no-CONS/no-cache contract), but over edges: each
    // endpoint is projected (skipping the edge if either end is behind the
    // camera) and the cursor's distance to the screen-space SEGMENT (not
    // just the endpoints) is measured via `closestOnSegment2D`. O(E) per
    // press.
    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 1
    // item 4): `thresholdPx` defaults to `kTopoPenSnapAuto` (resolved to the
    // view's own `topoPenPressPickPx(vp)` below), same rationale as
    // `findSourceVertex` above — every existing gesture caller stays
    // byte-identical (none pass a 3rd argument); the hover path passes
    // `float.infinity` for RESOLUTION and a finite value for the GATE.
    //
    // `borderOnly` (task 0496): the same measured snap-candidate filter
    // `findSourceVertex` carries, over edges — an interior edge (two or more
    // incident polygons) is not a candidate. Defaults FALSE for exactly the
    // same reason: only a SNAP-TARGET caller may pass it.
    private int findRingSeedEdge(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapAuto,
                                 bool borderOnly = false) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (thresholdPx < 0.0f) thresholdPx = topoPenPressPickPx(vp);
        int   best   = -1;
        float bestD  = float.infinity;
        // Hoisted once — see findSourceVertex.
        const int[] polyCount = borderOnly ? m.edgePolygonCounts() : null;
        foreach (ei, e; m.edges) {
            if (borderOnly && isEdgeInterior(polyCount, cast(uint)ei)) continue;
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
    // Add Loop rail (`seedRailA_`/`seedRailB_`); it became a parameter so
    // the mid-edge Split gesture could re-project against an arbitrary
    // edge — `ratioFromCursor` below is the Add Loop caller's unchanged
    // convenience wrapper. NOT used by Slide: Slide is a DELTA law
    // (`slideDeltaFromDrag`), not an absolute cursor parameterisation, and
    // has no `[0,1]` range at all.
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

    // Slide, THE MEASURED LAW — step 1 of 2: extract the drag's dominant
    // world-axis component.
    //
    //     k = argmax_j |delta[j]|   ->   returns delta[k] (SIGNED)
    //
    // The reference's own move delta carries exactly one live component per
    // evaluation (axis-aligned in 20/20 captured gestures), so there the
    // argmax merely EXTRACTS that component rather than choosing between
    // three. Our delta (`slideDeltaFromDrag`) is a free plane drag and is
    // generally not axis-aligned, so the argmax is load-bearing here: it is
    // the documented generalisation, and it is what makes the slide magnitude
    // a single world-axis projection of the pointer travel rather than the
    // full 3D drag length.
    //
    // Ties (two components equal in magnitude) resolve to the LOWEST axis
    // index — arbitrary but deterministic, which is all a tie needs; the
    // captured data never exercises one.
    private static float dominantAxisDelta(Vec3 delta) {
        import std.math : abs;
        float ax = abs(delta.x), ay = abs(delta.y), az = abs(delta.z);
        if (ax >= ay && ax >= az) return delta.x;
        if (ay >= az)             return delta.y;
        return delta.z;
    }

    // Slide, THE MEASURED LAW — step 2 of 2: the endpoint's new position.
    //
    //     w      = unit(neighbor - x)      // the rail, directed AWAY from
    //                                      // the grabbed edge
    //     offset = -deltaK * w             // |offset| == |deltaK| EXACTLY
    //     x'     = x + offset
    //
    // Properties this pins, each independently verified against the captured
    // conformance set (see the "Slide law — REFERENCE PARITY CONFORMANCE"
    // unittest at the bottom of this module):
    //   * colinear — `x'` always lies on the infinite rail LINE through
    //     `x`/`neighbor` (max relative perpendicular 2.4e-08 measured);
    //   * UNBOUNDED — there is deliberately NO `[0,1]` clamp. A vertex
    //     passes through its rail neighbour and keeps going; the measured
    //     parameter ranged over [-8.53, +4.19]. The previous implementation
    //     clamped, which is why this is a behaviour change and not just a
    //     re-derivation;
    //   * both endpoints of a grabbed edge share `deltaK` — only `w` differs
    //     (max relative difference between the two endpoints' scalars:
    //     1.7e-08), which is why `commitSlide` takes ONE scalar for both.
    //
    // On the rail direction: the source contract states `w` as "the edge
    // direction as traversed in its polygon's winding". Measured against the
    // conformance set that holds for only 16 of the 32 determinate endpoints,
    // because a polygon walk arrives at one endpoint of the grabbed edge and
    // departs from the other. `unit(neighbor - x)` — equivalently, that same
    // winding direction taken ORIENTED AWAY FROM THE GRABBED EDGE — is
    // 32/32. Getting this backwards inverts the gesture, so the conformance
    // unittest asserts positions, not just magnitudes.
    //
    // Takes `deltaK` as a DOUBLE and runs in double throughout, rounding once
    // on return. The captured targets are float-exact but the normalisation is
    // not: float everywhere leaves the achievable error at 8.9e-08 against a
    // 1e-7 tolerance, and even keeping only `deltaK` at float still costs
    // 6.0e-08 — no useful margin either way. In double it is 3.3e-08, the
    // float STORAGE granularity of the targets themselves, i.e. the floor. The
    // interactive caller's own scalar is float (it comes out of float viewport
    // math) and simply widens for free; the width exists so the API is not the
    // thing that loses the precision. A degenerate (zero-length) rail leaves
    // `x` untouched rather than emitting NaN, and a non-finite `deltaK` is
    // rejected outright.
    //
    // static + pure so it's directly unit-testable without an app-wired
    // instance, mirroring `findRingSeedEdge`/`seedRail`'s own
    // self-contained-helper convention.
    private static Vec3 slideEndpointPos(Vec3 x, Vec3 neighbor, double deltaK) {
        import std.math : sqrt, isFinite;
        if (!isFinite(deltaK)) return x;
        const double rx = cast(double) neighbor.x - cast(double) x.x;
        const double ry = cast(double) neighbor.y - cast(double) x.y;
        const double rz = cast(double) neighbor.z - cast(double) x.z;
        const double len = sqrt(rx * rx + ry * ry + rz * rz);
        if (!(len > 1e-12)) return x;              // degenerate rail (also catches NaN)
        const double s = -deltaK / len;
        return Vec3(cast(float)(cast(double) x.x + rx * s),
                    cast(float)(cast(double) x.y + ry * s),
                    cast(float)(cast(double) x.z + rz * s));
    }

    // Slide — THE GAIN, and the one part of this law that is deliberately
    // NOT the reference's.
    //
    // Returns the signed dominant-world-axis scalar the law consumes, for a
    // pointer that has travelled from the PRESS pixel to `(mx, my)`. Computed
    // press->current in one shot, never accumulated: the law commits the LAST
    // evaluation's offset, not a sum over evaluations, and a ray-plane
    // solution is affine in the pixel so press->current is exact.
    //
    // FROZEN DIVERGENCE — DECIDED, NOT OVERLOOKED. The reference's own
    // pixel->world magnitude curve is SUPERLINEAR: 0.0013099 / 0.0014310 /
    // 0.0015664 / 0.0017854 world units per pixel at 60 / 120 / 175 / 240 px
    // of drag, i.e. ~36% growth over a 4x range. It is not a constant that
    // could be encoded here. It was not chased because it is not a bounded
    // leaf computation and, more importantly, not specific to this gesture at
    // all — it is produced by shared transform-pipeline machinery selected at
    // runtime by whichever transform / axis / action-centre stages are live,
    // and the same conversion feeds that reference's whole Move family. So we
    // keep OUR gain and match everything else — axis extraction, rail
    // direction, the offset sign relative to the rail, no clamp — exactly.
    //
    // Our gain is `planeDragDelta`'s most-facing-world-plane drag through the
    // grab anchor: the same free-move conversion vibe3d's own Move gizmo
    // uses, LINEAR in the pixel. SANITY-CHECKED against the reference scale,
    // on the reference's own captured camera: its recorded pixel size is
    // 1.2422e-3 world units, its view direction is (-0.716, 0.316, -0.622),
    // so the most-facing world plane is the X plane and a ray-plane drag
    // against it stretches by 1/|fwd.x| = 1.396 — giving at most
    // 1.2422e-3 * 1.396 = 1.735e-3 world units per pixel, and less than that
    // once `dominantAxisDelta` takes a single component. The reference
    // measured 1.31e-3 (60 px) to 1.79e-3 (240 px) on that same camera, so we
    // sit inside its band across the whole sweep rather than merely near it.
    // That check matters more than it used to: this change also removed the
    // `[0,1]` clamp, so the implementation is no longer bounded and a
    // badly-scaled gain now costs more than it did. Gain, clamp removal and
    // sign are one change.
    //
    // ALSO FROZEN, and on purpose: which world axis the drag selects and with
    // WHAT SIGN. That is produced by the same opaque call as the magnitude, so
    // the capture pins only delta -> geometry, never pixels -> delta. There is
    // no cursor-tracking rule to copy: measured over the 20 captured gestures
    // the reference's own slide moves WITH the pointer in just 10 of them, and
    // two gestures with exactly OPPOSITE pixel drags along the same rail
    // (`C_C_p`/`C_C_m`) produced the SAME motion direction, because the
    // reference picked a different world axis for each. Our literal reading —
    // dominant axis of the free plane drag, sign as-is — reproduces that
    // rail-orientation-dependent character rather than papering over it. A
    // cursor-tracking convention (flip the scalar so the grab's primary
    // endpoint follows the pointer) was considered and REJECTED: it is
    // unmeasured, and it would introduce a full-magnitude sign flip as the
    // drag rotates through perpendicular to the rail. If a UX call is later
    // made to prefer tracking, THIS function is the only place it belongs —
    // the law below it stays untouched either way.
    //
    // To reopen either: the evidence trail carries `delta` for every
    // evaluation of every captured gesture, so the curve — and the axis
    // choice — can be re-fit offline without re-driving anything.
    //
    // `skip` (projection failure — degenerate viewport, anchor behind the
    // camera) yields 0, i.e. no slide this evaluation, rather than a garbage
    // scalar.
    private float slideDeltaFromDrag(int mx, int my, const ref Viewport vp) {
        bool skip;
        Vec3 d = planeDragDelta(mx, my, slideStartX_, slideStartY_,
                                3,                    // most-facing world plane
                                slideAnchor_, vp, skip);
        if (skip) return 0.0f;
        return dominantAxisDelta(d);
    }

    // Slide, valence>2 endpoints: the DISTINCT polygon-continuation
    // candidates at endpoint `x` of the grabbed edge `x-other`. For every
    // face that lists `x-other` as a CONSECUTIVE corner pair, that face's
    // other corner adjacent to `x` is one candidate — i.e. the edge that
    // continues the grabbed edge around that same polygon. Deduplicated, so
    // two faces naming the same continuation collapse to one entry.
    //
    // Deliberately keyed on faces containing the GRABBED EDGE, not merely
    // faces containing `x`: "continuation" means the polygon walk steps
    // across `x` from `other`, so a face that touches `x` but not the
    // grabbed edge contributes nothing. O(total face corners); this runs
    // only on the valence>2 branch below, twice per press and twice per
    // release (the result is cached in `slideNbrA_`/`slideNbrB_` for the
    // motion stream), so it is nowhere near a hot loop.
    //
    // Corner-ring degeneracies (`w == x` or `w == other`, i.e. a face that
    // repeats a vertex) are skipped rather than reported as candidates —
    // they name no usable rail.
    private static int[] continuationRailCandidates(Mesh* m, uint x, uint other) {
        int[] cands;
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            const size_t n = f.length;
            if (n < 3) continue;
            foreach (k; 0 .. n) {
                if (f[k] != x) continue;
                const uint prev = f[(k + n - 1) % n];
                const uint next = f[(k + 1) % n];
                uint w;
                if      (next == other) w = prev;
                else if (prev == other) w = next;
                else continue;                       // this corner isn't on the grabbed edge
                if (w == x || w == other) continue;  // degenerate corner ring
                bool seen = false;
                foreach (c; cands) if (c == cast(int)w) { seen = true; break; }
                if (!seen) cands ~= cast(int)w;
            }
        }
        return cands;
    }

    // P7 (doc/topopen_p7_slide_plan.md, V1-scope Option B), extended by the
    // Slide-law decode lane's valence>2 finding: the rail the endpoint `x`
    // slides along, once the grabbed edge's OTHER endpoint `other` is
    // excluded. Two regimes, by how many incident edges `x` has left:
    //
    //   0 remaining (grabbed-edge-only, valence-1) -> -1, held FIXED.
    //   1 remaining (valence-2) -> that unique neighbor, via the raw
    //     `edgeNeighbors` scan (P3 KILLER-1, the only adjacency that sees
    //     bare/diagonal edges a loop-fan helper would miss — a bare edge
    //     chain has no face at all, so this path must NOT go through the
    //     polygon walk). Unchanged from V1.
    //   2+ remaining (valence>2) -> the POLYGON-CONTINUATION rail: the edge
    //     that continues the grabbed edge around the polygon the grabbed
    //     edge belongs to (`continuationRailCandidates`). This replaces V1's
    //     blanket hold-fixed for valence>2, which was measurably wrong. It
    //     acts ONLY when that yields exactly ONE candidate, which is the
    //     unambiguous case: there is a single polygon to continue around and
    //     nothing left to choose.
    //
    // CORRECTION to this rule's original justification (the change that
    // introduced it asserted the rail choice is drag-direction INDEPENDENT,
    // citing 6/6): that generalisation is REFUTED. Later capture on a rig
    // whose two candidates are NOT antiparallel shows the reference's choice
    // at a MULTI-candidate endpoint switching with the sign of the drag's
    // dominant component. The original six drags happened to share one sign,
    // so they could not have detected it. Nothing here changes — the
    // single-candidate case this code acts on was never the drag-dependent
    // one — but the reason it is safe is that it is UNAMBIGUOUS, not that
    // selection is drag-independent.
    //
    // OPEN CASES, still held FIXED because no measurement disambiguates them
    // — a tie-break here would be a guess, and a guessed rail direction is
    // worse than not moving:
    //   * 2+ DISTINCT continuation candidates. The common shape is an
    //     interior (2-face) grabbed edge: each of the two faces continues
    //     across `x` in a different direction. Selection here is
    //     SIGN-DEPENDENT and UNDETERMINED: the captured cases are reproduced
    //     by "take the candidate most aligned with +delta[k]*e_k", 4/4 — but
    //     that is the OPPOSITE sign convention from the 32/32 rule the
    //     single-candidate endpoints obey, so it cannot be the same law and
    //     is not implemented. Deliberately left as hold-fixed. Non-manifold
    //     fans (3+ faces on the grabbed edge) land here too.
    //   * ZERO continuation candidates at a valence>2 vertex — the grabbed
    //     edge borders no face at all (a bare edge meeting a face corner,
    //     which the topology pen's own bare-edge build cases can produce),
    //     so there is no polygon to continue around.
    // Both are recorded as open rather than tie-broken; revisit when the
    // capture lane pins a polygon-selection rule.
    //
    // SCOPE OF "HELD FIXED" (doc/tasks/work/0482-topopen-move-nonvertex.md item
    // 3): this rule is stated PER ENDPOINT, and `onCtrlLmbDown` composes it one
    // step further than the wording alone implies — when NEITHER endpoint's rail
    // resolves it declines the whole gesture instead of arming a Slide that
    // would hold both endpoints fixed. Read that as the intended reading of this
    // contract, not a deviation from it: the two are IDENTICAL for the geometry
    // (a moving set in which no vertex has a rail is a Slide that moves nothing,
    // whichever way you get there), and declining is strictly better on the
    // channels the per-endpoint wording never addressed — it cannot leave a
    // no-op undo entry behind, and it does not suppress the hover indicator for
    // the duration of a hold that was never going to do anything. What the
    // decline used to cost was observability, and that is now published
    // explicitly (`slideDecline_` / `slideDeclineReason`) rather than left to be
    // inferred from an armed-but-railless state that no longer exists. A
    // 4-valent interior edge is the common shape that lands here: both endpoints
    // hit the "2+ DISTINCT continuation candidates" open case above, so no rail
    // resolves at either end and the press declines with `no_continuation`.
    private static int continuationNeighbor(Mesh* m, uint x, uint other) {
        int found = -1, count = 0;
        foreach (v; m.edgeNeighbors(x)) {
            if (v == other) continue;
            ++count;
            found = cast(int)v;
        }
        if (count == 0) return -1;
        if (count == 1) return found;
        auto cands = continuationRailCandidates(m, x, other);
        return (cands.length == 1) ? cands[0] : -1;
    }

    // P7 (doc/topopen_p7_slide_plan.md), on the Ctrl+LMB "Slide" slot
    // (V1-scope Option B — EDGE grab, capture-verified §1/§3/§4): a press
    // picks the nearest primary-layer EDGE (`findRingSeedEdge`, reused
    // verbatim from P6); each endpoint whose rail resolves
    // (`continuationNeighbor` — unique remaining incident edge at valence-2,
    // polygon-continuation edge at valence>2) is slidable along it; an
    // endpoint whose rail does not resolve is HELD FIXED (see
    // `continuationNeighbor` for the enumerated open cases, and its "SCOPE OF
    // HELD FIXED" note for why declining is the intended composition of that
    // per-endpoint rule). If NEITHER endpoint is slidable, nothing is armed (no
    // documented gesture to perform) — don't consume, matching every other
    // down-handler's miss convention. The commit itself is deferred to release
    // (`onMouseButtonUp`); this only arms, freezes the drag-conversion anchor
    // (the grabbed edge's midpoint) and zeroes the law's scalar — a press with
    // no motion is by construction a zero delta, hence a zero offset.
    //
    // Every exit writes `slideDecline_` (and `slideDeclineSeed_`), so
    // `/api/tool/state` always explains the OUTCOME of the most recent Slide
    // press: a pick miss and a contract-driven hold-both-fixed decline are
    // different answers, not the one indistinguishable "nothing armed" they used
    // to collapse into. Purely additive bookkeeping — no gesture behaviour here
    // reads it back.
    private bool onCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3):
        // this row's `ResetScope.AllButtons` already fires
        // `resetAllGestureArms()` via `dispatchInput`'s `onInputResetAll()`
        // hook before this handler runs. See `resetAllGestureArms`'s own doc
        // comment for the full hazard this closes.

        // Pessimistic default: every early exit below is a "no edge to work
        // with" outcome (a real pick miss, or no mesh at all), and the two paths
        // that know better overwrite it explicitly.
        slideDecline_     = SlideDecline.NoEdge;
        slideDeclineSeed_ = -1;

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
        if (nA < 0 && nB < 0) {
            // Neither endpoint slidable -> nothing to do. NOT a pick miss: the
            // edge resolved, the hold-fixed contract simply leaves nothing to
            // move. Record both facts so a consumer can tell this apart from
            // `NoEdge` and can still see WHICH edge was picked.
            slideDecline_     = SlideDecline.NoContinuation;
            slideDeclineSeed_ = seed;
            return false;
        }

        slideDecline_     = SlideDecline.None;
        slideDeclineSeed_ = -1;

        slideSeed_   = seed;
        slideArmed_  = true;
        slideStartX_ = e.x;
        slideStartY_ = e.y;
        slideEndA_   = eA;
        slideEndB_   = eB;
        slideNbrA_   = nA;
        slideNbrB_   = nB;
        slideAnchor_ = (m.vertices[eA] + m.vertices[eB]) * 0.5f;
        slideDeltaK_ = 0.0f;
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

        // Task 0486 (contract C-0): Duplicate needs a BORDER edge. On an
        // interior one this chord is a MOVE-LOOP, not a declined press and not
        // a duplicate — the reference's Evaluate guards Duplicate on
        // `isEdgeBorder(pressed)` and silently runs Move when it fails.
        if (!m.isEdgeBorder(cast(uint) seed)) return onMoveLoopRmbDown(e, vts);

        // Contract C-1: this chord FORCES the loop on and never reads
        // `edgeLoop_` — `loop=false` and `loop=true` were bit-identical on one
        // seed. C-4: the committed set is the border RUN, not the whole
        // gathered perimeter.
        auto edges = trimBorderRunAroundSeed(m.selectLoopEdges(cast(uint)seed), seed);
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

    // The world point a shared SCREEN drag puts `orig` at: unproject the
    // shifted pixel onto the plane through `orig` parallel to the image
    // plane — i.e. drag at CONSTANT view depth. Same pixel-CENTRE
    // convention (`+0.5f`) the ray path used, so the screen→world mapping
    // this tool has always applied is unchanged; only what happens to the
    // resulting point (see `resnapToBackground`) is.
    //
    // TASK 0503, on the ONE clause of the measured law this does NOT port.
    // The reference feeds its constraint `src_i + Δ` with a SINGLE 3D offset
    // Δ shared by every moving vertex (identical to 1e-9 across them —
    // dupedge cells `A0-FLAT`/`A1-TILT`/`A2-NOBG`). Shifting each vertex's
    // OWN pixel by a shared screen delta is a DEPTH-DEPENDENT world delta,
    // so the two laws agree exactly when the moving vertices share a view
    // depth and diverge when they do not. Every rig either capture ran on
    // has its moving set on one fronto-parallel plane, so both measurements
    // are silent on the difference — and Δ's own law (which plane the drag
    // unprojects onto, whether the drag point is itself constrained) is
    // explicitly NOT established by either note. Porting the shared-Δ shape
    // would therefore mean inventing Δ, so this keeps the existing
    // per-vertex mapping and records the gap instead.
    private static Vec3 shiftedWorldPoint(Vec3 orig, int px, int py,
                                          const ref Viewport vp) {
        Vec3 org, dir;
        screenPointToRay(cast(float)px + 0.5f, cast(float)py + 0.5f, vp, org, dir);
        // View matrix third ROW (column-major m[row + col*4]) = the
        // camera-back direction; the plane through `orig` with that normal
        // is the constant-view-depth plane. Same derivation `drag.d`'s
        // `planeDragDelta` uses for its own camera-facing plane.
        const ref float[16] v = vp.view;
        Vec3 camBack = Vec3(v[2], v[6], v[10]);
        Vec3 q;
        if (!rayPlaneIntersect(org, dir, orig, camBack, q)) return orig;   // degenerate view
        return q;
    }

    // TASK 0503 (measured port): re-snap `orig`, dragged to pixel (px,py),
    // onto the background as the NEAREST POINT on the background facet,
    // CLAMPED to that facet — NOT a camera ray through the pixel.
    //
    // This replaces the `BvhPick.pickSurface` ray P10 shipped. The ray was
    // OUR divergence, and it is measured wrong twice over, on two gestures,
    // by two independently built rigs:
    //
    //   * Duplicate, cells `A5-TILT30`/`A1-TILT`(×2 boots)/`A6-TILT60`
    //     (toolcards/topology_pen/dupedge_resnap_capture.md, contract C-2):
    //     |new edge| / |source edge| = cos(tilt) — 0.866025692 / 0.707106741 /
    //     0.500000075, worst deviation 2.9e-7 — which is exactly the length a
    //     PERPENDICULAR projection of a screen-horizontal segment onto a plane
    //     tilted by θ leaves. A per-vertex ray predicts 1.804 / 2.484 / 4.369
    //     on the same three cells: wrong by factors of 2 to 9. Cell `A0-FLAT`
    //     rules out "exotic background" as an excuse — on the FLAT background
    //     every earlier cell in this campaign used, the measurement is 1.000
    //     and the ray law predicts 1.220.
    //   * Add Loop, verdict V-1 (addloop_bgresnap_undo_capture.md, run g5,
    //     cells `AL-BG-1`/`AL-BG-2`/`AL-BG-MID`/`AL-BG-RAY`): all four
    //     inserted vertices land on the background plane to 1.1e-09…7.6e-09 D,
    //     and their lateral profile matches the perpendicular-foot formula to
    //     5.36e-09 D against 5.75e-03 D for the view ray — six orders.
    //
    // WHY THE PORT SURVIVED FOUR EARLIER CAPTURES: on a background PARALLEL
    // to the plane the drag resolves on, the per-vertex correction is the
    // IDENTITY, and every background before these two runs was parallel. A
    // test on a flat/parallel background cannot see this law at all (it can
    // still see the RATIO, 1.000 vs 1.220 — which is why the fixtures below
    // use both a tilted and a flat background).
    //
    // Per-vertex, never anchor-plus-rigid: refuted three independent ways on
    // Duplicate (the length ratio; a 4.8× spread of per-point displacement
    // — 0.0651/0.0617/0.1886/0.3155 — inside ONE evaluation, where a rigid
    // rest requires equality; and a zero hit count on the function a static
    // read had blamed). The port's "one target per moving vertex" shape was
    // already right and is unchanged.
    //
    // Reuses `constraint.closestPointOnMeshes` — the SAME nearest-foot
    // primitive P8/P12's Smooth already re-snaps with (`applySmoothPasses`,
    // `applySmoothLoopPasses`), so after this change every re-snap in the
    // tool goes through one query instead of two rival ones. `dblSided =
    // false` mirrors those call sites and CONS's Point-mode default.
    //
    // MISS SEMANTICS CHANGE, deliberately. A ray misses whenever the shifted
    // pixel points at empty space; a nearest-foot query over a non-empty
    // background never misses — it CLAMPS to the facet (that clamp is
    // measured: cell `A3-CLIP` put both feet past a cut background edge and
    // both landed exactly on the cut, β = -0.30000). So `false` here now
    // means only "no background surface exists at all", which is still a
    // measured case: with no background the gesture commits and translates
    // rigidly (cell `A2-NOBG`, contract C-5), which is what the callers'
    // keep-the-original policy produces. What is NOT ported is the honest
    // consequence of the clamp — the reference commits the DEGENERATE quad
    // it produces, and "match the reference" vs "never emit a zero-area
    // facet" is an owner call, not a capture verdict (contract C-4). No
    // guard is added here either way.
    //
    // Returns false (leaving `outPoint` untouched) only when no live
    // background source exists, or none has a usable face.
    private bool resnapToBackground(Vec3 orig, int px, int py,
                                    const ref Viewport vp, out Vec3 outPoint) {
        auto sources = backgroundSourcesSnapshot();
        if (sources.length == 0) return false;

        Vec3 query = shiftedWorldPoint(orig, px, py, vp);

        Vec3  hitPt, hitN;
        int   si, fi;
        float d2;
        enum bool dblSided = false;   // matches P8/P12/CONS Point-mode's own default
        if (!closestPointOnMeshes(query, sources, dblSided, hitPt, hitN, si, fi, d2))
            return false;
        outPoint = hitPt;
        return true;
    }

    // P10 (doc/topopen_p10_moveloop_plan.md "The pinned drag-mapping"): the
    // per-vertex re-snap targets for a shared SCREEN-space drag delta
    // `(dx, dy)` — project each moving vertex's CURRENT (pre-commit)
    // position, shift by the shared delta, and re-snap
    // (`resnapToBackground`). A vertex that projects behind the camera, or
    // for which NO background surface exists at all, KEEPS its original
    // position (also the contract FIX-2's partial-miss test pins at the
    // `commitMoveLoop` layer). TASK 0503 narrowed that branch: the re-snap
    // is now a nearest-foot query, which cannot miss a non-empty background
    // the way the old camera ray could — see `resnapToBackground`. Returns
    // one target per entry of `verts`, same order — `verts.length == 0`/
    // `m is null` yields an empty array (defensive; callers already guard
    // this).
    private Vec3[] perVertexTargets(const(uint)[] verts, int dx, int dy,
                                    const ref Viewport vp) {
        Vec3[] base;
        auto m = mesh;
        if (m is null) return base;
        base.length = verts.length;
        foreach (i, vi; verts)
            base[i] = (vi < m.vertices.length) ? m.vertices[vi] : Vec3(0, 0, 0);
        return perVertexTargetsFrom(base, dx, dy, vp);
    }

    // The same law, taking the source positions EXPLICITLY (task 0484). A
    // gesture that writes the mesh LIVE cannot project "the vertex's current
    // position" — by the second motion event that is already the moved one,
    // and the element would race away from the cursor by an ever-growing
    // delta. It hands its ARM-TIME positions in instead, so every motion
    // event recomputes the same absolute answer from the same origin.
    //
    // `perVertexTargets` above is the identity case (base = live positions),
    // which is exactly right for a gesture that only ever computes this once,
    // at release — Move Loop / Dup Loop are unchanged by this split.
    private Vec3[] perVertexTargetsFrom(const(Vec3)[] base, int dx, int dy,
                                        const ref Viewport vp) {
        Vec3[] targets;
        targets.length = base.length;
        foreach (i, orig; base) {
            targets[i] = orig;   // default: a miss keeps the original

            ImVec2 pt;
            if (!projectPt(orig, vp, pt)) continue;   // behind camera -> keep original

            int px = cast(int)(pt.x + cast(float)dx);
            int py = cast(int)(pt.y + cast(float)dy);
            Vec3 hitPt;
            if (resnapToBackground(orig, px, py, vp, hitPt)) targets[i] = hitPt;
        }
        return targets;
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 3), on the Shift+Ctrl+LMB
    // "Smooth" slot: arms a whole-primary-mesh relax+re-snap gesture — NO
    // source-vertex/edge pick (unlike every other gesture above, this one
    // is scope-free: it relaxes the ENTIRE primary mesh, not a
    // press-selected element) and NO mutation on down. Commit is deferred
    // to release (`onMouseButtonUp`'s Smooth branch, `applySmoothPasses`),
    // deriving the pass count from the cursor's signed horizontal offset from
    // THIS press pixel (`smoothStartX_`, the law's anchor — see
    // `kSmoothPassStridePx`).
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
        smoothDragDx_ = 0;
        return true;
    }

    // Dispatch entry point: `dispatchInput` reads back the SAME action id it
    // armed on THIS button's Down (never re-derived from arm-bool priority)
    // and calls `onToolAction(a, Up, ...)`, which routes to the matching
    // `<mode>Up` helper below — the same bodies this method used to call
    // inline, per-button-branch, before the Phase-2 flip.
    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e,
                                  ref VectorStack vts) {
        // The release still runs on the press's ranges — `splitUp` re-resolves
        // its target vertex at the release pixel and must use the same
        // acceptance the whole gesture used — so the drop happens AFTER the
        // dispatch, never before it.
        bool handled = dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
                                     InputPhase.Up, e, vts);
        dragSnap_ = SnapPacket.init;
        return handled;
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
            // Task 0484: the release applies the FINAL targets for its own
            // pixel and records the whole drag as one undo entry — see
            // `finishMove`. For a grabbed VERTEX this is P4's original law
            // verbatim (go to the release event's CONS-snapped hit), so
            // where a vertex move lands is unchanged; edges and faces take
            // the shared screen-delta law.
            Viewport vp;
            if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
            finishMove(e.x, e.y, vp, vts);
            return true;
        }
        return false;
    }

    // P3: commits the armed drag-build, if any, at the RELEASE event's own
    // CONS-snapped hit. A release with no real motion since press (a
    // stationary click-on-vertex — "revisit = Move/no-op", capture SESSION 1)
    // builds nothing.
    private bool buildUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Task 0485: the same slot's EDGE outcome. Checked first and
        // exclusively — `onShiftLmbDown` arms exactly one of the two, so this
        // can never shadow a vertex build.
        if (dupEdgeArmed_) return dupEdgeUp(e, vts);
        // Task 0486 (contract C-0): the Duplicate slot FALLS THROUGH to the
        // Move family on an interior edge, so this release must be able to
        // reach a move's commit leg too. `lmbModeUp` dispatches on the action
        // the press recorded, and every leg it can reach is guarded by its own
        // arm bool — so when nothing was armed this stays the same no-op it
        // was before.
        if (!dragArmed_) return lmbModeUp(e, vts);
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
    // gesture at the RELEASE event's own cursor-derived scalar. Re-derived
    // press->release here rather than reusing the last motion event's
    // `slideDeltaK_`, so the committed offset is the LAST evaluation's — the
    // law's own commit rule — even if the release pixel differs from the last
    // motion pixel.
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
        commitSlide(seed, eA, eB, nA, nB, slideDeltaFromDrag(e.x, e.y, vp));
        slideDeltaK_ = 0.0f;
        return true;
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 3): commits the armed Smooth
    // gesture — a click, and equally a drag that ends back at the press
    // pixel's own column, applies exactly ONE pass; a rightward drag applies
    // N per the measured law (`smoothPassesForDragDx`). Risk 5 (plan):
    // UNLIKE every other gesture, this one is NOT gated by `kMinDragPx` — a
    // stationary click must still apply its one pass (`applySmoothPasses`
    // itself carries the REV1 FIX-2 no-op-undo guard for the case where that
    // one pass genuinely changes nothing).
    //
    // Reads the LAST MOTION EVENT's displacement (`smoothDragDx_`), not this
    // release event's own pixel — matching the reference, which likewise
    // recomputes the count only while moving and consumes the last value it
    // published at release. This also keeps the release and the live
    // `smoothPassCount` readback exactly in step by construction.
    private bool smoothUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!smoothArmed_) return false;
        smoothArmed_ = false;
        applySmoothPasses(smoothPassesForDragDx(smoothDragDx_));
        return true;
    }

    // P9 (doc/topopen_p9_split_plan.md REV1 FIX-2): commits the armed Split
    // gesture. C is resolved AT THE RELEASE PIXEL — authoritative, never the
    // last-motion `splitTargetVert_` (a release with no intervening motion
    // event must still resolve C at its own pixel).
    //
    // Split is a VERTEX -> VERTEX chord split, and nothing else
    // (doc/tasks/work/0480-topopen-addloop-middle.md): a release that does
    // NOT land on an existing vertex within the drag-snap acceptance radius
    // (`topoPenSnapAcceptPx`, via `resolveSnapTargetVert`) — mid-span over
    // an edge, or on empty space — is a clean no-op. Inserting a new vertex
    // partway along a crossed edge belongs to the Add Loop gesture
    // (`addLoopUp`/`addLoopFrac`), which owns both the fraction and the
    // "at the Middle" option; this path never creates a vertex.
    private bool splitUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!splitArmed_) return false;
        int a = splitSourceVert_;
        splitArmed_      = false;
        splitSourceVert_ = -1;
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        int c = resolveSnapTargetVert(e.x, e.y, vp);
        splitTargetVert_ = -1;
        if (c >= 0) commitSplit(a, c);
        // else: release on an edge / empty space -> clean no-op.
        return true;
    }

    // The Add Loop insert-fraction law (reference parity,
    // doc/tasks/work/0480-topopen-addloop-middle.md):
    //
    //     frac = middle ? 0.5 : clamp(cursorRatio, 0, 1)
    //
    // ONE uniform scalar for the WHOLE ring — the returned value is handed
    // to `insertEdgeLoops` once and applied at the same fraction on every
    // crossed edge; it is never re-derived per crossed edge from that edge's
    // own screen projection. (Measured on the reference: the cut fractions
    // across the crossed edges of one gesture had a spread of exactly 0.)
    //
    // `middle` bypasses the cursor entirely, so it also bypasses the clamp —
    // there is no cursor value that can perturb the forced 0.5. With the
    // option OFF the clamp is nominally redundant (`ratioOnSegment` already
    // clamps to `[0,1]`), but it is stated here because the clamp is part of
    // the law, not an artefact of the current cursor plumbing: it must hold
    // for ANY future producer of the ratio.
    private float addLoopFrac(float cursorRatio) const {
        if (addLoopMiddle_) return 0.5f;
        if (!(cursorRatio > 0.0f)) return 0.0f;   // also rejects NaN
        if (cursorRatio > 1.0f)    return 1.0f;
        return cursorRatio;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 3): commits the armed Add Loop
    // gesture, at the RELEASE event's own cursor-derived ratio — passed
    // through `addLoopFrac`, so the sticky "at the Middle" option overrides
    // it with a flat 0.5 for every crossed edge.
    private bool addLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!addLoopArmed_) return false;
        int seed = addLoopSeed_;
        addLoopSeed_  = -1;
        addLoopArmed_ = false;
        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        float r = addLoopFrac(ratioFromCursor(e.x, e.y, vp));
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
        // Task 0486 (contract C-0): on an interior edge this chord fell through
        // to a move-loop, whose commit leg is `moveLoopUp` — reach it, or the
        // gesture would arm and then never commit.
        if (!dupLoopArmed_ && moveLoopArmed_) return moveLoopUp(e, vts);
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

    // Task 0485: commits the armed Shift+LMB duplicate-EDGE gesture — the
    // single-edge sibling of `dupLoopUp` immediately above, with the same
    // click-vs-drag gate (a stationary Shift+click duplicates nothing) and
    // the same release-pixel delta. Disarms on every path.
    private bool dupEdgeUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!dupEdgeArmed_) return false;
        auto edges = dupEdgeEdges_;
        immutable int sx = dupEdgeStartX_, sy = dupEdgeStartY_;
        dupEdgeArmed_ = false;
        dupEdgeSeed_  = -1;
        dupEdgeEdges_ = null;

        enum int kMinDragPx = 3;   // mirrors every other gesture's click-vs-drag gate
        immutable int dx = e.x - sx, dy = e.y - sy;
        if (dx * dx + dy * dy < kMinDragPx * kMinDragPx) return true;
        if (edges.length == 0) return true;

        Viewport vp;
        if (auto s = vts.get!SubjectPacket()) vp = s.viewport;
        // `buildEditFactory_` — this IS the Shift+LMB Duplicate/build slot,
        // so the entry carries that slot's own wire name, never the loop
        // gesture's (the OBJ-3/D4 discipline every commit path here follows).
        commitDupEdges(edges, dx, dy, vp, buildEditFactory_, "Topology Duplicate Edge");
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
        int n = 1 + cast(int)(smoothLoopDragPx_ / kSmoothLoopPassStridePx);
        applySmoothLoopPasses(n);
        smoothLoopSeed_   = -1;
        smoothLoopVerts_  = null;
        smoothLoopDragPx_ = 0.0f;
        return true;
    }

    // The Mode router's RELEASE leg (task 0483): the unmodified-LMB slot's
    // UP dispatches to whichever gesture THIS press's DOWN actually resolved
    // to (`gestureOn_`), never to a freshly re-read `penMode_` — see
    // `gestureOn_`'s own doc comment for the mid-drag hazard that closes.
    //
    // Every `*Up` below already guards on its own arm bool, so a DOWN that
    // resolved-but-declined lands here as a clean no-op. `Remove` and the
    // Fill click op have no UP leg at all (both commit on DOWN) and return
    // `false`, unconsumed — matching how the Ctrl+MMB chord's own UP case
    // answers. `PlaceOrMove` is both the Move/Point modes' leg and the
    // neutral post-reset value, and is guarded by `placeArmed_`/`moveArmed_`.
    private bool lmbModeUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        return penGestureUp(gestureOn_[InputButton.Left], e, vts);
    }

    /// Dispatch a RELEASE to the commit leg of the gesture `g` — the gesture
    /// the matching press actually resolved to, per button (task 0487). Every
    /// leg guards on its own arm bool, so a press that resolved-but-declined
    /// lands here as a clean no-op.
    private bool penGestureUp(PenGesture g, ref const SDL_MouseButtonEvent e,
                              ref VectorStack vts) {
        switch (g) {
        case PenGesture.Build:      return buildUp(e, vts);
        case PenGesture.Slide:      return slideUp(e, vts);
        case PenGesture.Smooth:     return smoothUp(e, vts);
        case PenGesture.Split:      return splitUp(e, vts);
        case PenGesture.AddLoop:    return addLoopUp(e, vts);
        case PenGesture.MoveLoop:   return moveLoopUp(e, vts);
        case PenGesture.DupLoop:    return dupLoopUp(e, vts);
        case PenGesture.SmoothLoop: return smoothLoopUp(e, vts);
        case PenGesture.Remove:     return false;   // commits on DOWN (D2)
        default:                    return lmbPlaceOrMoveUp(e, vts);
        }
    }

    // `gestureOn_` as a stable wire token for `/api/tool/state` (task 0483).
    // A `final switch` (the `BuildCase`/`SlideDecline` precedent) rather than
    // an `IntEnumEntry` table: this is not a `Param`, nothing parses it back,
    // and the exhaustive switch makes a newly added action a COMPILE error
    // here instead of a silently unlabelled state field.
    // `moveElem_` as a stable wire token for `/api/tool/state` (task 0484),
    // same `final switch` discipline as `penGestureTag` below.
    private static string moveElemTag(MoveElem k) {
        final switch (k) {
        case MoveElem.None:   return "none";
        case MoveElem.Vertex: return "vertex";
        case MoveElem.Edge:   return "edge";
        case MoveElem.Face:   return "face";
        }
    }

    private static string penGestureTag(PenGesture a) {
        final switch (a) {
        case PenGesture.PlaceOrMove:    return "place_or_move";
        case PenGesture.Build:          return "build";
        case PenGesture.Slide:          return "slide";
        case PenGesture.Smooth:         return "smooth";
        case PenGesture.Split:          return "split";
        case PenGesture.AddLoop:        return "add_loop";
        case PenGesture.Remove:         return "remove";
        case PenGesture.MoveLoop:       return "move_loop";
        case PenGesture.DupLoop:        return "dup_loop";
        case PenGesture.SmoothLoop:     return "smooth_loop";
        }
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
        immutable auto chord = cast(TopoPenChord) a;
        immutable auto btn   = chordButton(chord);
        immutable auto ov    = kChordOv[chord];

        if (p == InputPhase.Down) {
            // The chord's overrides on top of the user's own settings — the
            // whole of the input model, in three lines.
            immutable PenMode mode = (ov.mode == ModeOv.FromUser)
                                   ? penMode_ : modeOfOverride(ov.mode);
            immutable bool loop    = (ov.loop  == FlagOv.ForceOn) || edgeLoop_;
            immutable bool slide   = (ov.slide == FlagOv.ForceOn) || edgeSlide_;
            return runPenMode(mode, loop, slide, btn, e, vts);
        }
        if (p == InputPhase.Up) return penGestureUp(gestureOn_[btn], e, vts);
        // `Move` never arrives — this tool does not route `onMouseMotion`
        // through `dispatchInput` (Move-phase routing is deferred, design §5);
        // `onMouseMotion` keeps reading the arm bools directly, unchanged.
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

    // P7 (doc/topopen_p7_slide_plan.md Phase 3): commit the armed Slide
    // gesture — writes AT MOST 2 vertex positions (the grabbed edge's own
    // endpoints; a HELD-FIXED endpoint, `nA`/`nB == -1`, keeps its CURRENT
    // position). Position-only, direct kernel mutation
    // (`m.vertices[i] = pos` + `commitChange(Position)`), bracketed in ONE
    // before/after `MeshSnapshot` pair recorded through the DEDICATED
    // `slideEditFactory_` (wireName "mesh.topoPen_slide") — mirrors
    // `applyMoveTargets`'s shape, extended to up to 2 vertices. `seed` is a
    // defensive cross-check (the grabbed edge must still connect `eA`/`eB`
    // — guards against a stale/corrupted arm rather than trusting the
    // caller's indices blindly); the eps no-op guard mirrors
    // `applyMoveTargets`'s. Zero topology change — never resizes/rebuilds
    // `faces[]`/`edges[]`/`vertices[]` (no `buildLoops`, no
    // `deleteFacesByMask`, no `insertEdgeLoops`) — so unlike P5/P6 this does
    // NOT call `resyncSession()` (plan §Risks: no sibling gesture's cached
    // INDEX can dangle from a pure position write).
    //
    // `deltaK` is the law's single signed scalar (`dominantAxisDelta` of the
    // gesture's world-space move delta) — ONE value for BOTH endpoints, which
    // is measured, not an economy: the two endpoints differ only in their rail
    // DIRECTION. See `slideEndpointPos` for the per-endpoint law and for why
    // there is no `[0,1]` clamp any more.
    private void commitSlide(uint seed, int eA, int eB, int nA, int nB, double deltaK) {
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
        Vec3 pA = (nA >= 0) ? slideEndpointPos(origA, m.vertices[nA], deltaK) : origA;
        Vec3 pB = (nB >= 0) ? slideEndpointPos(origB, m.vertices[nB], deltaK) : origB;

        enum float kSlideEps = 1e-4f;   // mirrors applyMoveTargets's stationary-grab guard
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
    // (`isOpenEdge`) — a boundary vertex, per the measured relax rule the
    // Smooth kernel applies (`buildRelaxTopology` below feeds the equivalent
    // per-slot flags to `deriveBoundary`, which is the authority on that
    // path; this predicate remains for single-vertex queries and tests).
    // `adjOff`/`adjNbrs` are the caller's already-fetched CSR adjacency
    // (avoids re-fetching per vertex).
    private static bool isOpenVertex(Mesh* m, uint v,
                                     const(size_t)[] adjOff, const(uint)[] adjNbrs) {
        foreach (nb; adjNbrs[adjOff[v] .. adjOff[v + 1]])
            if (m.edgeIndex(v, nb) != uint.max && isOpenEdge(m, m.edgeIndex(v, nb)))
                return true;
        return false;
    }

    // Inverse-edge-length relax KERNEL for the 1-D Smooth+Loop gesture (P12,
    // doc/topopen_p12_smoothloop_plan.md Phase 1).
    //
    // SCOPE (narrowed — read this before reusing it): this was originally
    // extracted so the whole-mesh Smooth gesture and the 1-D Smooth+Loop
    // gesture could share one law. That premise no longer holds. The
    // whole-mesh Smooth path has since been re-measured and moved to a
    // DIFFERENT, force-accumulating law (`tools/edit/smooth_relax.d`), which
    // superseded the reading below — in particular the weights there are
    // proportional to edge LENGTH, not its inverse, and the step is projected
    // perpendicular to each edge. Smooth+Loop's own weighting has NOT been
    // re-measured, so it keeps this law until it is; do not "unify" the two
    // on the assumption that they must agree, and do not treat this function
    // as evidence about the whole-mesh path.
    //
    // The law it does implement: a closer neighbor pulls harder —
    //   relaxTarget(v) = Σ_i (n_i / len_i) / Σ_i (1 / len_i)
    // where `len_i = |v − n_i|` at the caller-supplied `readPos` snapshot
    // (every vertex in a pass reads from the SAME snapshot, mirroring
    // `MeshSmooth`'s own prev/cur double-buffer, smooth.d:280-297) and
    // `nbrs` is whatever neighbor set the caller has already resolved
    // (today: `applySmoothLoopPasses`'s 1-D loop-neighbor pair) — this
    // function itself has NO topology awareness beyond the list it's handed.
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

    // Freeze this mesh's topology into the form the measured relaxation
    // kernel consumes (`tools/edit/smooth_relax.d`, which owns the law
    // itself and the evidence for it). Built ONCE per Smooth gesture: the
    // gesture is Position-only, so `edges[]`/`faces[]` — and therefore every
    // field here — are invariant across all of its iterations.
    //
    // Neighbours come from `m.vertexAdjacencyCSR`, the EXACT same CSR
    // adjacency the shipped Laplacian smooth averages over
    // (`commands/mesh/smooth.d`), so this gesture's neighbour SET can never
    // drift from that command's. `openTo` is filled slot-for-slot from
    // `isOpenEdge` — the same open-edge classification `seedRail` /
    // `commitAddLoop` use — and `boundary` is DERIVED from it by
    // `deriveBoundary`, never assembled here, so the per-vertex flag and the
    // per-slot flags cannot disagree.
    //
    // The measured boundary rule: a vertex with at least one open edge
    // relaxes using ONLY its open-edge neighbours, not its full 1-ring
    // (dropping this restriction costs 4.3e-02 against the conformance
    // fixture). A missing `edgeIndex` (defensive — should not occur
    // post-`buildLoops`) is treated as NOT open, i.e. as an interior edge:
    // the conservative choice, since it can only restrict, never widen.
    private static RelaxTopology buildRelaxTopology(Mesh* m) {
        const(size_t)[] adjOff;
        const(uint)[]   adjNbrs;
        m.vertexAdjacencyCSR(adjOff, adjNbrs);

        auto openTo = new bool[](adjNbrs.length);
        foreach (v; 0 .. m.vertices.length) {
            foreach (k; adjOff[v] .. adjOff[v + 1]) {
                uint ei = m.edgeIndex(cast(uint) v, adjNbrs[k]);
                openTo[k] = (ei != uint.max) && isOpenEdge(m, ei);
            }
        }

        RelaxTopology topo = {
            offset:   adjOff,
            nbrs:     adjNbrs,
            openTo:   openTo,
            boundary: deriveBoundary(adjOff, openTo),
        };
        return topo;
    }

    // SCALE-RELATIVE no-op threshold for the Smooth gesture: the distance a
    // vertex must move before the gesture counts as having changed anything.
    // Returns a fraction of the pre-gesture bounding-box DIAGONAL rather than
    // a world-unit constant.
    //
    // Why this had to stop being absolute. The guard's job is to catch a
    // gesture that nets to IDENTITY — a disconnected patch with no usable
    // neighbours, no background to snap against, or a perfectly regular mesh
    // (an exact fixed point of this relaxation law). Every one of those
    // produces EXACTLY zero movement, not merely small movement, so the
    // threshold only ever has to clear float round-trip noise. The old
    // `1e-4f` was inherited from the sibling `kMoveEps`/`kSlideEps`/
    // `kMoveLoopEps` guards, where the displacement is DRAG-proportional and
    // a tenth of a millimetre genuinely is nothing. Smooth's displacement is
    // not drag-proportional: it scales with mesh size and with `strength`
    // (per click, roughly `0.028 · strength · medianEdgeLength`). Against a
    // fixed 1e-4 that produces a silent cliff — below it the ENTIRE gesture
    // is discarded, mesh restored, no undo entry, no feedback of any kind.
    // Measured: strength 0.05 (legal, well inside the Param's own [0, 4])
    // on a mesh with 0.07-unit edges — ordinary detail-modelling scale, and
    // exactly the spacing of the reference capture rig — displaces 5.46e-05
    // and was swallowed whole. Scaling the threshold to the model removes the
    // cliff instead of relocating it, which is why this is preferred over
    // simply lowering the constant.
    //
    // Why 1e-6 of the diagonal. Positions are `float`, i.e. ~1.2e-7 relative
    // precision, so a coordinate out at the extremity of a bounding box of
    // diagonal D carries roughly D·1e-7 of quantisation. 1e-6·D sits an order
    // of magnitude above that noise floor while staying ~370x below the
    // smallest genuinely-visible gesture above. The floor keeps the threshold
    // positive for a degenerate mesh (single vertex, or all vertices
    // coincident) whose diagonal is 0, so that a background re-snap of a
    // coincident cluster is still recorded rather than divided into nothing.
    //
    // Deliberately NOT applied to the sibling guards: `kMoveEps` (2906),
    // `kSlideEps` (2957), `kSmoothLoopEps`, and `kMoveLoopEps` all sit on
    // paths whose laws this change did not touch and whose displacement is
    // drag-proportional, so an absolute threshold remains correct for them.
    // `kSmoothEps` had no reader outside this function.
    private static float smoothNoOpEps(const(Vec3)[] verts) {
        enum float kRel   = 1e-6f;    // fraction of the bbox diagonal
        enum float kFloor = 1e-9f;    // degenerate (zero-extent) mesh
        if (verts.length == 0) return kFloor;

        Vec3 lo = verts[0], hi = verts[0];
        foreach (v; verts[1 .. $]) {
            if (v.x < lo.x) lo.x = v.x;  if (v.x > hi.x) hi.x = v.x;
            if (v.y < lo.y) lo.y = v.y;  if (v.y > hi.y) hi.y = v.y;
            if (v.z < lo.z) lo.z = v.z;  if (v.z > hi.z) hi.z = v.z;
        }
        immutable float diag = (hi - lo).length;
        immutable float eps  = kRel * diag;
        return eps > kFloor ? eps : kFloor;
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

    // Commit ONE Smooth evaluation of `passCount` relaxation iterations over
    // the WHOLE primary mesh (V1 scope — no falloff-radius brushing), then a
    // SINGLE background re-snap. Click supplies `passCount==1`; a drag
    // supplies more (`onMouseButtonUp`'s Smooth branch).
    //
    // The relaxation law itself lives in `tools/edit/smooth_relax.d` — see
    // that module's header for the measured formula and the per-part
    // ablation evidence. This function owns everything AROUND it: the
    // topology freeze, the float↔double conversion, the re-snap, and the
    // undo record.
    //
    // EVALUATION SEMANTICS (measured, reference parity). Three properties,
    // all of which this shape satisfies:
    //
    //   (1) RESTART FROM THE PRE-GESTURE MESH. Every evaluation begins from
    //       the positions the mesh had before the gesture started — passes
    //       do not compound across evaluations. Here that holds by
    //       construction: the whole gesture is deferred to release, so this
    //       is the ONLY evaluation and `m.vertices` still holds the DOWN-time
    //       state when the iteration loop is seeded from it.
    //   (2) SNAP ONCE, AFTER ALL ITERATIONS — not between them. This is a
    //       real change from the previous shape, which re-snapped every
    //       pass: re-snapping mid-relaxation feeds the constrained position
    //       back into the next iteration's neighbour reads, which is a
    //       different trajectory (and, with N>1, a visibly different result)
    //       from relaxing freely and constraining the outcome once.
    //   (3) COMMIT ONLY THE LAST EVALUATION — one `history_.record` for the
    //       whole gesture, which this already did.
    //
    // The iteration loop is pure arithmetic on a local `double` array, so
    // `mutationVersion` never moves inside it and the CSR adjacency behind
    // `buildRelaxTopology` is fetched exactly once. `closestPointOnMeshes`'s
    // brute-force O(V·F_bg) scan now runs ONCE per gesture instead of once
    // per pass — property (2) makes the multi-pass case cheaper, not dearer.
    // Position-only, zero topology delta, so unlike P5/P6 this does NOT call
    // `resyncSession()` (mirrors `commitSlide`'s own reasoning).
    //
    // `lockBound` / `lockCorner` — MEASURED, NOT OVERLOOKED. The reference
    // carries two such flags and they are deliberately absent here: both
    // were confirmed to reach the reference's own kernel and to change
    // NOTHING on this whole-mesh path (with either flag on, all 15 boundary
    // and all 4 corner vertices of the capture rig still moved, bit-identical
    // to the unlocked run — the conformance fixture pins two of those cases
    // directly). Implementing them as vertex-holding here would therefore
    // CREATE a divergence, not close one. They become real only on the
    // falloff / edge-loop path, if that is ever ported.
    //
    // The ITERATION COUNT likewise has no user knob, for the same
    // "implementing it would create the divergence" reason and NOT by
    // omission — the reference's own iteration attribute shares storage with
    // its gesture counter and is overwritten at every Smooth press, so it
    // cannot influence a gesture. Full reasoning at
    // `smoothPassesForDragDx`; `passCount` here therefore only ever arrives
    // from that law (or from a direct unit-test caller).
    //
    // REV1 FIX-2 (PRIORITY, not hedged/unconditional — opponent obj-2): a
    // Smooth gesture that produces NO net vertex change — 0-neighbor
    // disconnected verts, no background source, or any other combination
    // that nets to identity — restores `before` and records NO undo entry
    // (mirrors `applyMoveTargets`/`commitSlide`'s own eps guards). This is
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
        // This is the ONLY work-scaling quantity on this path and the cap is
        // unconditional, so a headless caller cannot drive the O(iters·E)
        // loop past it.
        if (passCount < 1) passCount = 1;
        if (passCount > MAX_TOPOPEN_SMOOTH_PASSES) passCount = MAX_TOPOPEN_SMOOTH_PASSES;

        auto sources = backgroundSourcesSnapshot();   // point-in-time, fetched ONCE per commit
        MeshSnapshot before = MeshSnapshot.capture(*m);

        immutable size_t nV = m.vertices.length;
        if (nV == 0) return;

        // Topology frozen once (Position-only gesture — it cannot move).
        auto topo = buildRelaxTopology(m);

        // Seed the double-precision working set from the PRE-GESTURE
        // positions (semantics (1) above) and run every iteration on it.
        auto pos = new RelaxVec3[](nV);
        foreach (vi; 0 .. nV)
            pos[vi] = RelaxVec3(m.vertices[vi].x, m.vertices[vi].y, m.vertices[vi].z);

        relaxPasses(pos, topo, cast(double) smoothStrength_ / kSmoothStrengthDivisor,
                    passCount);

        // ONE re-snap pass over the relaxed result (semantics (2) above),
        // onto the NEAREST point of the background via `closestPointOnMeshes`
        // (constraint.d; capture-verified crux — a nearest-FOOT query, NOT a
        // camera-ray one — the same primitive the CONS Point-mode branch
        // already uses).
        foreach (vi; 0 .. nV) {
            // A 0-neighbor vertex is a loose point: it can neither generate
            // nor receive a relaxation force, so it is skipped ENTIRELY,
            // including the background re-snap, leaving it byte-unchanged.
            //
            // OPEN / static-only: the reference is understood to still run
            // its per-vertex commit callback for such a vertex, and would
            // therefore snap it to the background. The conformance fixture
            // cannot settle this — its minimum vertex degree is 2, so it
            // contains no isolated vertex at all — so the existing
            // vibe3d behavior is kept rather than changed on a prediction.
            if (topo.offset[vi] == topo.offset[vi + 1]) continue;

            Vec3 relaxed = Vec3(cast(float) pos[vi].x, cast(float) pos[vi].y,
                                cast(float) pos[vi].z);
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

        // REV1 FIX-2: unconditional no-op check — a gesture that nets to
        // ZERO vertex movement (within eps) restores `before` exactly and
        // records no undo entry at all. The threshold is SCALE-RELATIVE (see
        // `smoothNoOpEps`) — an absolute one silently discarded whole
        // gestures at low `smoothStrength` or on small-scale meshes.
        // Measured against the PRE-gesture positions, so the reference scale
        // cannot itself be perturbed by the edit being tested.
        immutable float smoothEps = smoothNoOpEps(before.vertices);
        bool changed = false;
        foreach (i; 0 .. nV)
            if ((m.vertices[i] - before.vertices[i]).length > smoothEps) { changed = true; break; }
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
    // any mutation (D3) — mirrors `applyMoveTargets`'s up-front guard shape.
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

    // ---- Remove's other two primitives (task 0494) ------------------------

    /// The index of the vertex at exactly `p`, or -1. Positions survive the
    /// dissolve kernels' vertex compaction by value (they are copied, never
    /// re-derived), which is what makes this the way to carry a vertex
    /// identity ACROSS one of them — the same technique, and the same
    /// coincident-position caveat, as `Mesh.edgeDeleteRegion`.
    private static int vertexAtPosition(Mesh* m, Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }

    // Face-less geometry (placed points, a chain drawn before any polygon
    // closes over it) used to be wiped MESH-WIDE by the dissolve kernels' tail,
    // and this tool carried its own capture/re-add pair to survive that. Task
    // 0502 moved the preservation INTO the kernels (`Mesh.captureLooseGeometry`
    // and the pins/remap replay around `compactUnreferenced`), where it also
    // covers `edge.remove` / `edge.delete` — which rode the same kernel and had
    // the same defect. The local copy is gone; nothing here needs to bracket a
    // dissolve any more.

    /// Remove-on-an-EDGE (task 0494, contracts C-1/C-2/C-3/C-4): DISSOLVE the
    /// pressed edge — its two incident polygons merge into one — through the
    /// DEDICATED `removeEdgeEditFactory_`, as one atomic undo entry.
    ///
    /// A BORDER seed is a TOTAL no-op, in both variants (C-3). The guard is on
    /// the SEED and it runs BEFORE the gather, which is what the measurement
    /// showed: on a border press the reference's primitive returned without
    /// reaching its loop branch at all, 0 edits, 0 moved vertices. Written as
    /// its own early return, and tested as its own case, precisely because a
    /// well-meaning "just filter the gathered set" refactor would still pass
    /// every OTHER test here.
    ///
    /// `loop` promotes the seed to the vertex-continuation edge LOOP through
    /// it (C-2) — `Mesh.selectLoopEdges`, the same gather every other loop
    /// gesture in this tool uses, with NO border trim (Duplicate's trim was
    /// measured NOT to apply to removal) and one filter: an edge joins the
    /// doomed set only if it borders exactly two polygons.
    ///
    /// The flag is the EFFECTIVE one (C-1), never the button. A plain press
    /// with Edge Loop on and the chord that forces the flag were measured
    /// bit-identical, down to the removed-edge, new-edge and removed-vertex
    /// sets, so keying this on the physical button would be keying it on the
    /// one thing the measurement says is irrelevant.
    ///
    /// `keepVertex_` (C-4) is passed straight to the kernel: OFF (the measured
    /// default) purges the vertices whose whole polygon fan the dissolve ate
    /// and re-stitches their survivors; ON keeps them as corners of the merged
    /// polygons. See `Mesh.consumedFanVertexMask` for the rule and for why it
    /// is not the 2-valent one.
    private void removeEdgeAt(int edgeIdx, bool loop) {
        if (meshSrc_ is null || history_ is null || removeEdgeEditFactory_ is null) return;
        auto m = mesh;
        if (m is null || edgeIdx < 0 || edgeIdx >= cast(int)m.edges.length) return;

        // C-3: the seed gate, before the gather.
        auto polyCount = m.edgePolygonCounts();
        if (polyCount[edgeIdx] != 2) return;

        auto mask = new bool[](m.edges.length);
        if (loop)
            foreach (ei; m.selectLoopEdges(cast(uint)edgeIdx)) {
                if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                if (polyCount[ei] != 2) continue;
                mask[ei] = true;
            }
        mask[edgeIdx] = true;   // the seed dissolves whether or not it gathered

        MeshSnapshot before = MeshSnapshot.capture(*m);

        if (m.removeEdgesByMask(mask, keepVertex_) == 0) { before.restore(*m); return; }

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = removeEdgeEditFactory_();
        cmd.setSnapshots(before, after, "Topology Remove Edge");
        history_.record(cmd);

        // Same reason `removeFaceAt` calls it: the kernel COMPACTS `faces[]`
        // and `vertices[]`, so any sibling gesture armed on another button is
        // holding stale indices.
        resyncSession();

        m.syncSelection();
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    /// Remove-on-a-VERTEX (task 0494, contract C-0): merge the pressed
    /// vertex's WHOLE incident polygon fan into one polygon, then drop the
    /// vertex — through the DEDICATED `removeVertexEditFactory_`, as one
    /// atomic undo entry.
    ///
    /// This is its OWN law and is deliberately not expressed in terms of the
    /// edge primitive's. Measured on an interior vertex of a 4x4 grid: the
    /// four quads around it became ONE 8-gon and exactly that one vertex went
    /// (15/20/6). Running the EDGE path's fan rule over the same four edges
    /// would additionally have taken the two neighbours whose own fans are
    /// fully consumed, giving 13/18/6 — a different mesh. Two primitives, two
    /// laws, recorded as measured rather than generalised into one.
    ///
    /// Two consequences of that law worth stating, since neither is obvious:
    ///
    ///   * A CORNER vertex (one incident polygon) still works, and the merge
    ///     is simply vacuous: measured, its quad collapses to a triangle and
    ///     the vertex's two border edges go with it.
    ///   * `keepVertex_` is NOT read here. It was captured OFF on this path
    ///     and the reference's own vertex primitive reads the flag nowhere, so
    ///     honouring it would be inventing a second meaning for it.
    ///
    /// A vertex with NO incident polygon is DECLINED. That case is outside
    /// everything measured (the reference's retopo never builds face-less
    /// geometry) and there is no fan to merge, so a press there changes
    /// nothing rather than guessing — which also keeps a bare retopo chain out
    /// of a kernel that would rebuild the edge array around it.
    private void removeVertexAt(int vertIdx) {
        if (meshSrc_ is null || history_ is null || removeVertexEditFactory_ is null) return;
        auto m = mesh;
        if (m is null || vertIdx < 0 || vertIdx >= cast(int)m.vertices.length) return;

        // The fan, and the edges interior to it. Both by direct scan rather
        // than through the half-edge rings: this runs right after arbitrary
        // other mutations, and the scan cannot be stale.
        bool hasFan = false;
        foreach (ref f; m.faces) {
            foreach (v; f) if (v == cast(uint)vertIdx) { hasFan = true; break; }
            if (hasFan) break;
        }
        if (!hasFan) return;

        immutable Vec3 pos = m.vertices[vertIdx];
        auto polyCount = m.edgePolygonCounts();
        auto mask = new bool[](m.edges.length);
        size_t nMerge = 0;
        foreach (ei; 0 .. m.edges.length) {
            auto e = m.edges[ei];
            if (e[0] != cast(uint)vertIdx && e[1] != cast(uint)vertIdx) continue;
            if (polyCount[ei] != 2) continue;   // border/wire: nothing to merge across
            mask[ei] = true;
            ++nMerge;
        }

        MeshSnapshot before = MeshSnapshot.capture(*m);

        // Merge the fan, KEEPING every consumed vertex — the one the press
        // named is dropped below, and only it.
        if (nMerge > 0) m.removeEdgesByMask(mask);

        // Drop the pressed vertex. An interior fan merges to a polygon that no
        // longer uses it, so the kernel's own tail compaction already took it
        // and there is nothing left to find; a border fan leaves it a corner of
        // the merged polygon, and this is what removes it.
        immutable int vi = vertexAtPosition(m, pos);
        if (vi >= 0) {
            auto vmask = new bool[](m.vertices.length);
            vmask[vi] = true;
            m.dissolveVerticesByMask(vmask, /*keepOrphans*/true);
        }

        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = removeVertexEditFactory_();
        cmd.setSnapshots(before, after, "Topology Remove Vertex");
        history_.record(cmd);

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

        // MeshAddLoop.evaluate's open-interval guard: a ratio landing
        // exactly on a vertex (r<=0 or r>=1) inserts nothing. Written as a
        // NEGATED in-range test rather than that command's literal
        // `r <= 0 || r >= 1` so a non-finite `r` — which compares false
        // against everything and would slip through the literal form into
        // `insertEdgeLoops` — is rejected here too.
        if (!(r > 0.0f && r < 1.0f)) return;

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
    // no-op condition, incl. C==-1 (release on an edge or empty space), C==A, and
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

    // Commit the ring `findFillRing` resolved — FULL KERNEL REUSE, zero
    // kernel change. Mirrors `commitSplit`/`commitAddLoop` above: bracket
    // the ONE kernel call in a single before/after `MeshSnapshot` pair,
    // record through the DEDICATED `fillEditFactory_` (never
    // `splitEditFactory_`/`removeEditFactory_`, which would bake the wrong
    // wire name onto a fill).
    //
    // `ringVerts` reuses EXISTING verts (Δv=0) and arrives in the ORDER the
    // shape test accepted — 4 corners, or 3 when `quadOnly` is off. It is
    // passed through verbatim: the reference hands its own candidate array,
    // in exactly that order, to its polygon build, so re-sorting here would
    // wind a different polygon (measured — 139 of 240 four-slot searches
    // have slot 2 farther from the cursor than slot 3, so "the four nearest"
    // describes the SET and never the order). `autoOrient:true` only
    // REVERSES a winding, it never re-sorts, so it leaves the ring's own
    // adjacency intact while keeping the new face consistent with its
    // neighbours — the one degree of freedom the capture explicitly does not
    // score.
    //
    // `makePolygonFromVerts` creates any missing edge (a notch's mouth, or
    // the closing side of a bridge across a gap that has no edge at all —
    // the reference has NO real-fourth-side requirement and that guard is
    // dropped in this port), and rejects dup-face/non-manifold/degenerate
    // with a `-1` no-op — the mesh stays byte-unchanged and NO undo entry is
    // recorded.
    //
    // THE UNREAD GATE (task 0488). The reference runs one MORE gate after
    // the convexity test, and it is strict: 76 of 270 formed rings survived
    // it on the recording. Its predicate is UNREAD, so nothing is invented
    // for it here. What IS known is that the rings it refuses include every
    // ring whose vertex set is an already-existing polygon — which the
    // duplicate-face guard below already declines — so on that subset our
    // behaviour and the reference's agree by construction. Everywhere else
    // this port BUILDS where the reference might refuse; that is today's
    // behaviour kept deliberately rather than a guess dressed as a port.
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
    private void commitFill(const(uint)[] ringVerts) {
        if (meshSrc_ is null || history_ is null || fillEditFactory_ is null) return;
        auto m = mesh;
        if (m is null) return;
        if (ringVerts.length != 4 && ringVerts.length != 3) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        int fi = m.makePolygonFromVerts(ringVerts, false, true);
        if (fi < 0) return;   // dup-face / non-manifold / degenerate -> clean no-op, no mutation

        consumeDegeneratePolysOnRing(m, ringVerts);

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

    // The reference's own post-build cleanup contract, ported (task 0488):
    // immediately after the polygon is created it walks the NEW ring once and
    // deletes any LINE polygon (2 corners) lying along a new side, and any
    // POINT polygon (1 corner) sitting at a new corner. A fill CONSUMES the
    // degenerate polygons it swallows.
    //
    // INERT ON TODAY'S vibe3d, and that is a statement about our substrate,
    // not about the clause: nothing in this codebase creates a polygon with
    // fewer than three corners (`makePolygonFromVerts` rejects them outright),
    // and we model loose retopo geometry as bare EDGES and orphan VERTICES
    // instead — neither of which is a polygon, so neither is touched here.
    // The clause is ported anyway because it is measured, it is cheap, and a
    // mesh that arrives from an importer that does carry point/line polygons
    // must behave the same as the reference on it.
    //
    // `keepOrphans` + `keepFloatingEdges` both true: consuming the degenerate
    // polygon must not additionally eat its vertices or its edge — those are
    // corners and sides of the face we just built.
    private static void consumeDegeneratePolysOnRing(Mesh* m, const(uint)[] ring) {
        if (m is null || ring.length < 3) return;
        bool[] mask;
        bool any = false;
        foreach (fi, const ref f; m.faces) {
            bool hit = false;
            if (f.length == 1) {
                foreach (v; ring) if (f[0] == v) { hit = true; break; }
            } else if (f.length == 2) {
                foreach (k; 0 .. ring.length) {
                    immutable uint a = ring[k], b = ring[(k + 1) % ring.length];
                    if ((f[0] == a && f[1] == b) || (f[0] == b && f[1] == a)) { hit = true; break; }
                }
            }
            if (!hit) continue;
            if (mask.length == 0) mask = new bool[](m.faces.length);
            mask[fi] = true;
            any = true;
        }
        if (any) m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
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
    // pure position write). Eps no-op guard (mirrors `applyMoveTargets`/
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

        enum float kMoveLoopEps = 1e-4f;   // mirrors applyMoveTargets's/commitSlide's own eps guards
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
        if (dupLoopEditFactory_ is null) return;
        commitDupEdges(loopEdges, dx, dy, vp, dupLoopEditFactory_,
                       "Topology Duplicate Loop");
    }

    // The duplicate-edges KERNEL, shared by the Shift+RMB loop gesture above
    // and the Shift+LMB single-edge one (task 0485). Identical work either
    // way — the two differ ONLY in how many edges the caller put in the list
    // and in which factory/label the entry carries — so they cannot drift
    // apart in the extrude, the re-snap, or the undo shape.
    private void commitDupEdges(const(int)[] loopEdges, int dx, int dy,
                                const ref Viewport vp,
                                MeshSessionEdit delegate() factory, string label) {
        if (meshSrc_ is null || history_ is null || factory is null) return;
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

        auto cmd = factory();
        cmd.setSnapshots(before, after, label);
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
        hoverGrabElem_     = MoveElem.None;   // same staleness hazard, same fix
        hoverGrabIndex_    = -1;
        // Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md):
        // also drop the passive candidate-cell preview — an external
        // undo/redo with no subsequent motion event must not leave a stale
        // cell (possibly referencing verts the navigation deleted)
        // dangling into the next `draw()` call.
        fillRing_ = null;
        // Fill mode radius overlay (task 0477 continuation): same
        // rationale — an external undo/redo with no subsequent motion
        // event must not leave a stale radius (possibly sized off a
        // now-deleted border edge) dangling into the next `draw()` call.
        fillRadiusValid_ = false;
        // Slide decline diagnostics (doc/tasks/work/0482-topopen-move-nonvertex.md):
        // same rationale one more time — `slideDeclineSeed_` names an EDGE
        // INDEX, and an external undo/redo can delete that very edge, so a
        // navigation must not leave a stale index published on
        // `/api/tool/state`. Reporting no decline is strictly better than
        // reporting one against geometry that no longer exists.
        slideDecline_     = SlideDecline.None;
        slideDeclineSeed_ = -1;
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
                // The ghost marker previews what a release WOULD commit, so
                // it reads the same `addLoopFrac` law `addLoopUp` does — with
                // the "at the Middle" option on, the marker pins to 50% of
                // the rail and stops following the cursor.
                Vec3 markerPos = seedRailA_
                               + (seedRailB_ - seedRailA_) * addLoopFrac(addLoopRatio_);
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
        // `slideDeltaK_`) — no mesh mutation, no raycast. A
        // held-fixed endpoint (`slideNbrA_`/`slideNbrB_ < 0`) draws at its
        // CURRENT (unmoved) position, same as `commitSlide` would leave it.
        // The ghost runs the SAME `slideEndpointPos` the commit does, so an
        // unbounded (past-the-neighbour) slide previews truthfully — the
        // faint rail below is drawn edge-to-neighbour only and is a reference
        // line, not a bound.
        if (slideArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null
             && slideEndA_ >= 0 && slideEndA_ < cast(int)m.vertices.length
             && slideEndB_ >= 0 && slideEndB_ < cast(int)m.vertices.length) {
                enum uint slideCol     = IM_COL32(120, 200, 255, 220);   // slide cyan-blue
                enum uint slideRailCol = IM_COL32(120, 200, 255, 90);    // faint rail

                Vec3 pA = (slideNbrA_ >= 0 && slideNbrA_ < cast(int)m.vertices.length)
                    ? slideEndpointPos(m.vertices[slideEndA_], m.vertices[slideNbrA_], slideDeltaK_)
                    : m.vertices[slideEndA_];
                Vec3 pB = (slideNbrB_ >= 0 && slideNbrB_ < cast(int)m.vertices.length)
                    ? slideEndpointPos(m.vertices[slideEndB_], m.vertices[slideNbrB_], slideDeltaK_)
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
        // vertex — a release that resolves no vertex is a no-op, so there
        // is nothing to preview),
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
                        if (resnapToBackground(orig, px, py, vp, hitPt2)) g = hitPt2;
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
        if (dupLoopArmed_ && meshSrc_ !is null) drawDupGhost(dl, vp, dupLoopEdges_,
            dupLoopCurX_ - dupLoopStartX_, dupLoopCurY_ - dupLoopStartY_);

        // Task 0485: the SAME ghost for the Shift+LMB single-edge duplicate —
        // one edge instead of a loop, identical preview arithmetic.
        if (dupEdgeArmed_ && dupEdgeEdges_.length && meshSrc_ !is null)
            drawDupGhost(dl, vp, dupEdgeEdges_,
                         dupEdgeCurX_ - dupEdgeStartX_, dupEdgeCurY_ - dupEdgeStartY_);

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
                // ONE element — the one a press would grab (task 0484
                // follow-up), resolved by the press's own
                // `resolveGrabTarget`. This block used to paint the nearest
                // VERTEX and the nearest EDGE simultaneously, plus a hatch on
                // a boundary edge's face: three affordances answering "what
                // is near you". Now that a press grabs exactly one element,
                // showing more than that one misleads — the user aims by this
                // highlight, so it has to name what they will actually get.
                //
                // Switched on `hoverIndicatorElem()`, not on `hoverGrabElem_`:
                // that is the resolved target with the `showVertex`/`showEdge`
                // display toggles applied (task 0499). Both default ON, so the
                // painted result is unchanged unless the user turns one off.
                final switch (hoverIndicatorElem()) {
                case MoveElem.Vertex:
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.vertices.length) {
                        ImVec2 vc;
                        if (projectPt(m.vertices[hoverGrabIndex_], vp, vc))
                            dl.AddRectFilled(
                                ImVec2(vc.x - kHoverVertSquareHalfPx, vc.y - kHoverVertSquareHalfPx),
                                ImVec2(vc.x + kHoverVertSquareHalfPx, vc.y + kHoverVertSquareHalfPx),
                                kHoverElemCol);
                    }
                    break;

                case MoveElem.Edge:
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.edges.length) {
                        auto he = m.edges[hoverGrabIndex_];
                        ImVec2 ea, eb;
                        if (projectPt(m.vertices[he[0]], vp, ea)
                         && projectPt(m.vertices[he[1]], vp, eb))
                            dl.AddLine(ea, eb, kHoverElemCol, kHoverEdgeWidthPx);
                    }
                    break;

                case MoveElem.Face:
                    // Cross-hatch + outline. ANY face under the cursor, not
                    // just a boundary edge's — the hatch used to be reachable
                    // only through `hoverBoundary_`, which is a fact about an
                    // EDGE, and left an interior polygon with no highlight at
                    // all even though a press there grabs it.
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.faces.length) {
                        ImVec2[] pts;
                        bool ok = true;
                        foreach (fvi; m.faces[hoverGrabIndex_]) {
                            ImVec2 p;
                            if (!projectPt(m.vertices[fvi], vp, p)) { ok = false; break; }
                            pts ~= p;
                        }
                        if (ok && pts.length >= 3) {
                            hatchScreenPolygon(dl, pts, kHoverHatchCol,
                                              kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                            foreach (i, pa; pts)
                                dl.AddLine(pa, pts[(i + 1) % pts.length],
                                           kHoverElemCol, kHoverEdgeWidthPx);
                        }
                    }
                    break;

                case MoveElem.None:
                    break;   // over the mesh but nothing resolved -> nothing to promise
                }
            }
        }

        // Fill candidate-ring preview (MANDATORY opponent fix #2): its
        // OWN sibling gate — `penMode_ == Fill && fillRing_.length >= 3` —
        // deliberately NOT folded into the `hoverOverMesh_` block above.
        // Three corners as readily as four, because `quadOnly` off is a
        // measured build (task 0488).
        // `hoverOverMesh_` requires a pick within `topoPenPressPickPx`, which is
        // FALSE when hovering the center of an empty gap cell (the defining
        // Fill-mode case: no vertex/edge/face is anywhere near the
        // cursor) — nesting this there would make the preview never render
        // for that scenario. Still gated on `!anyGestureArmed()` (mode
        // ghosts win when armed, same precedent as every other ghost).
        if (!anyGestureArmed() && penMode_ == PenMode.Fill
                                && fillRing_.length >= 3 && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                immutable size_t vlen2 = m.vertices.length;
                bool ok = true;
                ImVec2[] pts;
                pts.length = fillRing_.length;
                foreach (k, vi; fillRing_) {
                    if (vi >= vlen2 || !projectPt(m.vertices[vi], vp, pts[k])) { ok = false; break; }
                }
                if (ok) {
                    hatchScreenPolygon(dl, pts, kFillPreviewCol,
                                      kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                    foreach (k; 0 .. pts.length)
                        dl.AddLine(pts[k], pts[(k + 1) % pts.length],
                                   kFillPreviewCol, kHoverEdgeWidthPx);
                }
            }
        }

        // Fill mode radius overlay (task 0477 continuation, the derived
        // radius law — full provenance in the PRIVATE toolcard,
        // toolcards/topology_pen/fill_radius_law_capture.md): a cosmetic
        // screen-space circle OUTLINE, centered on the LIVE cursor pixel,
        // sized to `fillRadiusPx_` (resolved in `onMouseMotion` above). Its
        // OWN sibling gate — `penMode_ == Fill && fillRadiusValid_` —
        // mirrors the candidate-cell preview immediately above and is,
        // for the identical reason, NOT folded into the `hoverOverMesh_`
        // block earlier in this function: it must still render while
        // hovering the open middle of a gap, where `hoverOverMesh_` is
        // false. Still gated on `!anyGestureArmed()` (mode ghosts win when
        // armed, same precedent as every other ghost). Re-polls the cursor
        // via `queryMouse` — the same draw()-time live-cursor idiom used
        // by this tool's own hover ghosts elsewhere in the codebase —
        // rather than any cached (e.x,e.y), so the circle keeps tracking
        // the cursor between motion events exactly like the derived law's
        // own "re-polled every redraw" cursor semantics. Draw-only: no
        // mesh read, no command, no undo interaction.
        if (!anyGestureArmed() && penMode_ == PenMode.Fill && fillRadiusValid_) {
            int qmx, qmy;
            queryMouse(qmx, qmy);
            dl.AddCircle(ImVec2(cast(float)qmx, cast(float)qmy), fillRadiusPx_,
                        kFillRadiusCol, kFillRadiusSegments, kFillRadiusThicknessPx);
        }

        if (!lastHit_.hit) return;

        // Re-resolve for THIS cell's camera — a multi-viewport draw may
        // run once per eligible cell, each with its own `vp`; the cached
        // `lastTarget_` (motion-time) stays what toolStateJson() reports.
        auto ht = resolveHoverTarget(lastHit_, vp, topoPenPressPickPx(vp));

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

        // Move drag affordance (P4's ghost, re-purposed by task 0484). P4
        // drew a line from the grabbed vertex's pre-commit position to the
        // live re-snap point, because the mesh did not move until release and
        // that line was the ONLY feedback. The drag is live now — the
        // geometry itself is the feedback — so the line would connect a point
        // to itself. What remains is a marker on the moving set, so the user
        // can still see WHICH element they grabbed once it is sitting under
        // the cursor: a small square per moving vertex, in the same green.
        if (moveArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                enum uint  moveGhostCol = IM_COL32(80, 220, 120, 220);   // move green
                enum float halfPx       = 4.0f;
                foreach (vi; moveVerts_) {
                    if (vi >= m.vertices.length) continue;
                    ImVec2 p;
                    if (!projectPt(m.vertices[vi], vp, p)) continue;
                    dl.AddRectFilled(ImVec2(p.x - halfPx, p.y - halfPx),
                                     ImVec2(p.x + halfPx, p.y + halfPx), moveGhostCol);
                }
            }
        }
    }

    // The duplicate ghost, shared by the Shift+RMB loop gesture and the
    // Shift+LMB single-edge one (task 0485): preview of the
    // coincident-then-dragged duplicate + its bridge quads, recomputed every
    // frame from the LIVE cursor delta. Mirrors the Move Loop ghost's
    // primitives (`resnapToBackground`/`projectPt`) — no mesh mutation, no
    // extrude, pure preview. Independent of `lastHit_`/CONS, drawn before the
    // same `!lastHit_.hit` early-return as every other gesture ghost.
    private void drawDupGhost(ImDrawList* dl, const ref Viewport vp,
                              const(int)[] edgeList, int dx, int dy) {
        auto m = mesh;
        if (m is null) return;
        enum uint dupCol = IM_COL32(60, 220, 140, 220);   // duplicate ghost green

        foreach (ei; edgeList) {
            if (ei < 0 || ei >= cast(int)m.edges.length) continue;
            auto edgeE = m.edges[ei];
            Vec3 a = m.vertices[edgeE[0]], b = m.vertices[edgeE[1]];

            Vec3 aP = a, bP = b;   // default: miss (or off-screen) keeps coincident
            ImVec2 pa, pb;
            if (projectPt(a, vp, pa)) {
                Vec3 hitA;
                if (resnapToBackground(a, cast(int)(pa.x + cast(float)dx),
                                       cast(int)(pa.y + cast(float)dy), vp, hitA)) aP = hitA;
            }
            if (projectPt(b, vp, pb)) {
                Vec3 hitB;
                if (resnapToBackground(b, cast(int)(pb.x + cast(float)dx),
                                       cast(int)(pb.y + cast(float)dy), vp, hitB)) bP = hitB;
            }

            ImVec2 sa, sb, saP, sbP;
            bool ok = projectPt(a, vp, sa) && projectPt(b, vp, sb)
                   && projectPt(aP, vp, saP) && projectPt(bP, vp, sbP);
            if (!ok) continue;

            // The predicted bridge quad a-b-b'-a' + the new duplicate edge
            // a'-b' (heavier stroke), + a dot per predicted (dragged) vert.
            dl.AddLine(sa, sb,   dupCol, 1.5f);
            dl.AddLine(sb, sbP,  dupCol, 1.5f);
            dl.AddLine(sbP, saP, dupCol, 2.0f);
            dl.AddLine(saP, sa,  dupCol, 1.5f);

            dl.AddCircleFilled(saP, 4.0f, dupCol, 16);
            dl.AddCircleFilled(sbP, 4.0f, dupCol, 16);
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
        // Which element the armed Move grabbed, and how many vertices it is
        // dragging (task 0484). `grabbedVert` alone cannot say: it is -1 for
        // BOTH "nothing armed" and "an edge/face is armed", which are
        // opposite states. `moveDirty` separates "armed but nothing has
        // actually moved yet" from "the live drag has already written the
        // mesh" — the difference between a press and a press+drag, invisible
        // from geometry alone until the release records its entry.
        root["moveElem"]      = JSONValue(moveElemTag(moveElem_));
        root["moveVertCount"] = JSONValue(cast(int)moveVerts_.length);
        root["moveDirty"]     = JSONValue(moveDirty_);
        root["grabbedVert"] = JSONValue(grabbedVert_);

        // P6 (doc/topopen_p6_addloop_plan.md Phase 5): the armed Add Loop
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and tracked ratio without driving a full release.
        root["addLoopArmed"] = JSONValue(addLoopArmed_);
        root["addLoopSeed"]  = JSONValue(addLoopSeed_);
        root["addLoopRatio"] = JSONValue(cast(double)addLoopRatio_);
        // "at the Middle" (doc/tasks/work/0480-topopen-addloop-middle.md):
        // the sticky option itself plus the EFFECTIVE fraction a release
        // would commit right now (`addLoopFrac(addLoopRatio_)`), so a Tier-C
        // test can observe the override without driving a full release.
        // `addLoopRatio` above stays the RAW cursor ratio — the two differ
        // exactly when the option is on.
        root["addLoopMiddle"] = JSONValue(addLoopMiddle_);
        root["addLoopFrac"]   = JSONValue(cast(double)addLoopFrac(addLoopRatio_));

        // P7 (doc/topopen_p7_slide_plan.md Phase 4): the armed Slide
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and the tracked scalar without driving a full release.
        // `slideDeltaK` replaces V1's `slideTA`/`slideTB` pair: the measured
        // law has ONE signed world-space scalar shared by both endpoints, and
        // no per-endpoint `[0,1]` fraction exists to report.
        root["slideArmed"]  = JSONValue(slideArmed_);
        root["slideSeed"]   = JSONValue(slideSeed_);
        root["slideDeltaK"] = JSONValue(cast(double)slideDeltaK_);
        root["slideNbrA"]   = JSONValue(slideNbrA_);
        root["slideNbrB"]   = JSONValue(slideNbrB_);

        // Why the most recent Slide press did not arm
        // (doc/tasks/work/0482-topopen-move-nonvertex.md item 3 follow-up).
        // Read-only; see `slideDecline_`'s own doc comment for the lifecycle.
        // The three fields above (`slideArmed`/`slideSeed`/`slideNbr*`) describe
        // an ARMED gesture and all read "nothing" on either decline — these two
        // are what separate the two declines:
        //   "none"            -> armed normally, or no Slide press yet/since a
        //                        reset (nothing to explain).
        //   "no_edge"         -> no primary edge within the snap radius: a real
        //                        pick miss. `slideDeclineSeed` is -1.
        //   "no_continuation" -> an edge WAS resolved (`slideDeclineSeed` names
        //                        it) but neither endpoint's rail resolves, so
        //                        the hold-fixed contract leaves nothing to
        //                        slide. A deliberate decline, NOT a miss —
        //                        do not score it as a pick failure.
        string slideDeclineToken;
        final switch (slideDecline_) {
            case SlideDecline.None:           slideDeclineToken = "none";            break;
            case SlideDecline.NoEdge:         slideDeclineToken = "no_edge";         break;
            case SlideDecline.NoContinuation: slideDeclineToken = "no_continuation"; break;
        }
        root["slideDeclineReason"] = JSONValue(slideDeclineToken);
        root["slideDeclineSeed"]   = JSONValue(slideDeclineSeed_);

        // P8 (doc/topopen_p8_smooth_plan.md Phase 4): the armed Smooth
        // gesture's state, for Tier-C tests to assert click-vs-drag pass
        // counts without driving a full release. `smoothPassCount` goes
        // through the SAME law helper (`smoothPassesForDragDx`, fully
        // clamped) that `onMouseButtonUp`'s Smooth branch will apply if
        // released now — one function, so this readback cannot drift from
        // the committed count (NIT-3: reporting an unclamped value here
        // would make that "will apply" doc-comment false for an extreme
        // drag).
        root["smoothArmed"]     = JSONValue(smoothArmed_);
        root["smoothPassCount"] = JSONValue(smoothPassesForDragDx(smoothDragDx_));

        // P9 (doc/topopen_p9_split_plan.md Phase 4): the armed Split
        // gesture's state, for Tier-C tests to assert the picked source
        // vertex and tracked snap target without driving a full release.
        root["splitArmed"]      = JSONValue(splitArmed_);
        root["splitSourceVert"] = JSONValue(splitSourceVert_);
        root["splitTargetVert"] = JSONValue(splitTargetVert_);

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

        // Task 0485: the Shift+LMB single-edge duplicate's own arm, kept
        // separate from the loop gesture's so a test (and a reader of the
        // state) can tell which of the two is in flight.
        root["dupEdgeArmed"]     = JSONValue(dupEdgeArmed_);
        root["dupEdgeSeed"]      = JSONValue(dupEdgeSeed_);
        root["dupEdgeEdgeCount"] = JSONValue(cast(int)dupEdgeEdges_.length);

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 4): the armed
        // Smooth+Loop gesture's state, for Tier-C tests to assert the
        // picked seed edge and gathered moving-set size without driving a
        // full release. NIT-3 parity with the whole-mesh Smooth's own
        // `smoothPassCount`: reports the CLAMPED value
        // `onMouseButtonUp`'s Smooth+Loop branch will actually apply if
        // released now. It is NOT the same LAW, though — this path keeps the
        // forked, unmeasured travel-based pacing (`kSmoothLoopPassStridePx`).
        root["smoothLoopArmed"]     = JSONValue(smoothLoopArmed_);
        root["smoothLoopSeed"]      = JSONValue(smoothLoopSeed_);
        root["smoothLoopVertCount"] = JSONValue(cast(int)smoothLoopVerts_.length);
        int smoothLoopPassCount = 1 + cast(int)(smoothLoopDragPx_ / kSmoothLoopPassStridePx);
        if (smoothLoopPassCount > MAX_TOPOPEN_SMOOTH_PASSES) smoothLoopPassCount = MAX_TOPOPEN_SMOOTH_PASSES;
        root["smoothLoopPassCount"] = JSONValue(smoothLoopPassCount);

        // The sticky Mode dropdown's CURRENT value, as its wire tag
        // ("move" / "duplicate" / ... / "smooth"), read straight out of
        // `penModeTable` via `wireTagForValue` so this can never drift from
        // the `Param.intEnum_` schema `params()` publishes or from the tag
        // `tool.attr mesh.topoPen mode <tag>` accepts. Read-only
        // observability: without it an automated run can SET the mode but
        // cannot verify the setting took, so a Fill-mode no-op and a
        // still-in-Move-mode press are indistinguishable from outside. Flat
        // root key (the `hover{}`/`hoverIndicator{}` nesting is for grouped
        // per-element state; this is one tool-wide scalar, like
        // `addLoopMiddle`).
        root["penMode"] = JSONValue(wireTagForValue(penModeTable, cast(int)penMode_));

        // The two dropdown-adjacent sticky flags, and the gesture the LAST
        // unmodified-LMB press actually resolved to under them (task 0483).
        // `lmbAction` is the router's own decision made visible: it is what
        // separates "Edge Loop was on, so the press armed a loop move" from
        // "Edge Loop was on but the press found no ring seed", which the arm
        // bools alone cannot tell apart from outside.
        root["edgeLoop"]  = JSONValue(edgeLoop_);
        root["edgeSlide"] = JSONValue(edgeSlide_);
        // The third sticky flag (task 0496): which CANDIDATE SET the pen's
        // snap target may resolve to — border-only when off, the interior
        // too when on.
        root["innerSnap"] = JSONValue(innerSnap_);
        // The fourth sticky flag (task 0494): whether a Remove-mode edge
        // dissolve KEEPS the vertices whose whole polygon fan it consumed.
        // Observability matters more here than for the others — the flag
        // changes what a click DESTROYS, so a run must be able to read back
        // which branch it is about to take.
        root["keepVertex"] = JSONValue(keepVertex_);
        root["lmbAction"] = JSONValue(penGestureTag(gestureOn_[InputButton.Left]));

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
        // WHAT a press here would grab, and therefore the one element this
        // indicator draws (task 0484 follow-up). Distinct from `nearestVert`
        // /`nearestEdge` above, which are ∞-threshold "what is closest"
        // answers: this one is pick-range-limited and single, and it is the
        // only way an automated run can check that the highlight and the
        // press agree — they share `resolveGrabTarget`, and this field is
        // what proves it from outside.
        hi["grabElem"]  = JSONValue(moveElemTag(hoverGrabElem_));
        hi["grabIndex"] = JSONValue(hoverGrabIndex_);
        // What `draw()` actually PAINTS — `grabElem` filtered by the
        // `showVertex`/`showEdge` display toggles (task 0499). Reported
        // separately from `grabElem` above precisely because the toggles must
        // not change what a press grabs: an automated run can see the marker
        // disappear (`shownElem` = "none") while the grab target stays put.
        hi["shownElem"] = JSONValue(moveElemTag(hoverIndicatorElem()));
        hi["showVertex"] = JSONValue(showVertex_);
        hi["showEdge"]   = JSONValue(showEdge_);
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
// trimBorderRunAroundSeed — the stop predicate's two phrasings are ONE set.
// The trim only ever evaluates a vertex it reached ALONG A BORDER EDGE, so
// that vertex's dart fan is OPEN, and an open fan yields corners+1 edges
// (`VertexEdgeRange` emits the extra open-end edge) against corners faces
// (`VertexFaceRange`):
//
//     vertexValence(v) == polyCount(v) + 1     for every border-reachable v
//
// so "polyCount <= 1" and "valence == 2" are the same test there. Case A
// pins that on representative rigs; case B pins the identity that CAUSES it,
// so a failure localises. Case D pins the ONE phrasing that is NOT
// equivalent: a degree read off the raw `edges[]` array
// (`Mesh.edgeNeighbors`) instead of the dart fan. Face-less edges — which
// this tool creates itself (`BuildCase.Edge`, see `buildFromSource`) — are in
// `edges[]` but own no dart, so a wire spur on a patch corner reads raw
// degree 3 while the fan reads valence 2. Do not "simplify" the stop test
// onto that enumerator; see the comment on `trimBorderRunAroundSeed` itself.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : sort;
    import std.math      : cos, sin, PI;

    auto t = new TopologyPenTool();

    static size_t polyCountOf(const ref Mesh m, uint v) {
        size_t n = 0;
        foreach (fi; m.facesAroundVertex(v)) ++n;
        return n;
    }
    static int[] sortedDup(const(int)[] a) { auto b = a.dup; b.sort(); return b; }

    // A parameterised copy of the trim's walk. Case A asserts
    // walkWith(polygon-count) == trimBorderRunAroundSeed(...), which pins
    // this copy to the shipped function so it cannot drift unnoticed.
    static int[] walkWith(Mesh* m, const(int)[] gathered, int seed,
                          bool delegate(uint) stopAt)
    {
        bool[int] inSet;
        foreach (ei; gathered) inSet[ei] = true;
        if ((seed in inSet) is null) return [seed];

        int[] run = [seed];
        bool[int] taken;
        taken[seed] = true;
        foreach (endpoint; [m.edges[seed][0], m.edges[seed][1]]) {
            uint cur  = endpoint;
            int  came = seed;
            while (true) {
                if (stopAt(cur)) break;
                int next = -1;
                foreach (ei; m.edgesAroundVertex(cur)) {
                    immutable int e2 = cast(int) ei;
                    if (e2 == came) continue;
                    if ((e2 in inSet) is null) continue;
                    if ((e2 in taken) !is null) continue;
                    if (!m.isEdgeBorder(cast(uint) e2)) continue;
                    next = e2;
                    break;
                }
                if (next < 0) break;
                taken[next] = true;
                run ~= next;
                auto ep = m.edges[next];
                cur  = (ep[0] == cur) ? ep[1] : ep[0];
                came = next;
            }
        }
        return run;
    }

    // ---- rigs ----------------------------------------------------------
    static void buildGrid(Mesh* m, uint nx, uint ny) {       // nx*ny quads
        foreach (j; 0 .. ny + 1) foreach (i; 0 .. nx + 1)
            m.addVertex(Vec3(cast(float) i, 0, cast(float) j));
        foreach (j; 0 .. ny) foreach (i; 0 .. nx) {
            immutable uint a = j * (nx + 1) + i;
            m.makePolygonFromVerts([a, a + 1, a + nx + 2, a + nx + 1], false);
        }
        m.buildLoops();
    }
    static void buildAnnulus(Mesh* m, uint n) {              // closed band
        foreach (i; 0 .. n) {
            immutable float a = cast(float)(2.0 * PI * i / n);
            m.addVertex(Vec3(cast(float) cos(a), 0, cast(float) sin(a)));
        }
        foreach (i; 0 .. n) {
            immutable float a = cast(float)(2.0 * PI * i / n);
            m.addVertex(Vec3(2.0f * cast(float) cos(a), 0, 2.0f * cast(float) sin(a)));
        }
        foreach (i; 0 .. n) {
            immutable uint i2 = (i + 1) % n;
            m.makePolygonFromVerts([i, i2, n + i2, n + i], false);
        }
        m.buildLoops();
    }
    static void buildFan(Mesh* m, uint n) {                  // open triangle fan
        m.addVertex(Vec3(0, 0, 0));
        foreach (i; 0 .. n + 1) {
            immutable float a = cast(float)(PI * i / n);
            m.addVertex(Vec3(cast(float) cos(a), 0, cast(float) sin(a)));
        }
        foreach (i; 0 .. n) m.makePolygonFromVerts([0u, 1u + i, 2u + i], false);
        m.buildLoops();
    }
    static void buildEll(Mesh* m) {   // 3 of a 2x2 grid's quads: a REFLEX border
        foreach (j; 0 .. 3) foreach (i; 0 .. 3)
            m.addVertex(Vec3(cast(float) i, 0, cast(float) j));
        m.makePolygonFromVerts([0u, 1u, 4u, 3u], false);
        m.makePolygonFromVerts([1u, 2u, 5u, 4u], false);
        m.makePolygonFromVerts([3u, 4u, 7u, 6u], false);
        m.buildLoops();
    }
    static void buildButterfly(Mesh* m) {   // two quads sharing ONE vertex
        foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                     Vec3(-1,0,0), Vec3(-1,0,-1), Vec3(0,0,-1)])
            m.addVertex(p);
        m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
        m.makePolygonFromVerts([0u, 6u, 5u, 4u], false);
        m.buildLoops();
    }

    // ---- cases A + B ---------------------------------------------------
    // `fanIdentity` is false only for the butterfly, whose shared vertex is
    // TWO fans: both enumerators may see one fan or both, but they always
    // see the SAME one, so the equivalence still holds while the
    // valence == polyCount + 1 identity (a single-fan statement) need not.
    void sweep(string rig, Mesh* m, bool fanIdentity) {
        if (fanIdentity)
            foreach (v; 0 .. cast(uint) m.vertices.length) {
                if (!m.isVertexBorder(v)) continue;
                assert(m.vertexValence(v) == cast(uint) polyCountOf(*m, v) + 1,
                    rig ~ ": a border-reachable vertex must have an OPEN dart fan "
                        ~ "(valence == incident-polygon count + 1) — this identity "
                        ~ "is WHY the two stop phrasings coincide");
            }

        t.meshSrc_ = () => m;
        foreach (ei; 0 .. cast(int) m.edges.length) {
            if (!m.isEdgeBorder(cast(uint) ei)) continue;   // the only seeds the trim sees
            auto gathered = m.selectLoopEdges(cast(uint) ei);

            auto shipped = sortedDup(t.trimBorderRunAroundSeed(gathered, ei));
            auto byPoly  = sortedDup(walkWith(m, gathered, ei,
                               (uint v) => polyCountOf(*m, v) <= 1));
            auto byVal   = sortedDup(walkWith(m, gathered, ei,
                               (uint v) => m.vertexValence(v) == 2));

            assert(shipped == byPoly,
                rig ~ ": the shipped trim IS the incident-polygon-count phrasing");
            assert(shipped == byVal,
                rig ~ ": the valence-2 phrasing must select the SAME run — if this "
                    ~ "fires, the two phrasings have been separated and the "
                    ~ "reference behaviour on that shape is UNMEASURED");
        }
    }

    { Mesh m; buildGrid(&m, 3, 3);   sweep("grid3x3",   &m, true);  }
    { Mesh m; buildGrid(&m, 3, 1);   sweep("strip3",    &m, true);  }
    { Mesh m; buildGrid(&m, 1, 1);   sweep("loneQuad",  &m, true);  }
    { Mesh m; buildAnnulus(&m, 8);   sweep("annulus8",  &m, true);  }
    { Mesh m; buildFan(&m, 4);       sweep("triFan4",   &m, true);  }
    { Mesh m; buildEll(&m);          sweep("ellReflex", &m, true);  }
    { Mesh m; buildButterfly(&m);    sweep("butterfly", &m, false); }

    // ---- case D: the ONE phrasing that is NOT equivalent ----------------
    {
        Mesh m;
        foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)])
            m.addVertex(p);
        immutable uint spur = m.addVertex(Vec3(-1, 0, -1));
        m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
        m.addEdge(0u, spur);            // a BARE edge: in edges[], owns no dart
        m.buildLoops();

        assert(polyCountOf(m, 0u) == 1,
            "the spur is face-less, so the corner still has ONE incident polygon");
        assert(m.vertexValence(0u) == 2,
            "the dart fan cannot see the spur, so the FAN valence is still 2");
        assert(m.edgeNeighbors(0u).length == 3,
            "...but the RAW edges[] degree is 3 — the two phrasings part here");

        immutable int seed = cast(int) m.edgeIndex(0u, 1u);
        assert(seed >= 0 && m.isEdgeBorder(cast(uint) seed));
        auto gathered = m.selectLoopEdges(cast(uint) seed);
        t.meshSrc_ = () => &m;

        auto shipped = sortedDup(t.trimBorderRunAroundSeed(gathered, seed));
        auto byRaw   = sortedDup(walkWith(&m, gathered, seed,
                           (uint v) => m.edgeNeighbors(v).length == 2));

        assert(shipped.length == 1,
            "the shipped predicate stops at BOTH ends of a lone quad's border edge");
        assert(byRaw != shipped,
            "a raw edges[]-degree phrasing selects a DIFFERENT run — do NOT "
            ~ "refactor the stop test onto Mesh.edgeNeighbors");
    }
}

// ---------------------------------------------------------------------------
// applyMoveTargets — the eps no-op guard (P4, doc/topopen_p4_plan.md hard
// requirement #4, carried onto the live-drag path by task 0484): targets
// landing back within eps of the moving set's CURRENT positions (stationary
// grab / all-on-surface no-move) must leave the mesh untouched, leave
// `moveDirty_` false, and — through `recordLiveMove`'s own `moveDirty_`
// gate — record NO undo entry. Driven directly (private, same-module
// access) — the no-op path returns BEFORE the `refreshDisplay`/`gpu_.upload`
// tail, so it's safe under a bare `dub test` with no GL context, mirroring
// the buildFromSource degenerate-release unittest immediately above. (The
// committing/"real move" path — which DOES reach `gpu_.upload` and therefore
// needs a live GL context — is covered end-to-end by the HTTP suite instead:
// test_topopen_move_drag.d / test_topopen_move_undo_redo.d.)
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

    // Stationary grab: the target IS the vertex's own position.
    t.moveArmed_ = true;
    t.moveElem_  = MoveElem.Vertex;
    t.moveVerts_ = [a];
    t.moveBase_  = [Vec3(1, 2, 3)];
    t.moveBefore_ = MeshSnapshot.capture(m);

    auto before = MeshSnapshot.capture(m);
    t.applyMoveTargets([Vec3(1, 2, 3)]);
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices, "stationary grab must not move the vertex");
    assert(!t.moveDirty_, "a no-op apply must leave the drag clean");

    t.recordLiveMove();
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
// runs under bare `dub test`, mirroring `applyMoveTargets`/`removeFaceAt`'s own
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
// Add Loop — T5: ONE UNIFORM SCALAR across every crossed edge
// (doc/tasks/work/0480-topopen-addloop-middle.md). The reference was measured
// applying a single fraction to the whole ring — the cut fractions across the
// crossed edges of one gesture had a spread of exactly 0 — rather than
// re-deriving a fraction per crossed edge from that edge's own projection.
//
// On the cube belt around edge 0-1 all four crossed edges run along X, so a
// uniform scalar puts all four new vertices at the SAME x (a planar loop);
// a per-edge recomputation would let them scatter. Asserting the SPREAD is
// the direct form of the measured claim, and it is immune to the global
// orientation sign-flip T2 documents (which flips all four together).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.algorithm : max, min;
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

    // Deliberately OFF-CENTER: at r=0.5 a per-edge recomputation would
    // coincide with the uniform answer and the test would prove nothing.
    t.commitAddLoop(seed, 0.25f);
    assert(m.vertices.length == 12, "setup: the belt cut must add exactly 4 vertices");

    float xLo = float.max, xHi = -float.max;
    foreach (i; 8 .. 12) {
        xLo = min(xLo, m.vertices[i].x);
        xHi = max(xHi, m.vertices[i].x);
    }
    assert(xHi - xLo < 1e-6f,
        "every crossed edge must be cut at the SAME scalar fraction — the four new belt "
      ~ "vertices must be coplanar in x (measured spread on the reference: 0)");

    // ...and that shared fraction must be the requested one (0.25 of the
    // 1.0-wide cube edge => |x| == 0.25), not some averaged or defaulted value.
    assert(abs(abs(xLo) - 0.25f) < 1e-5f,
        "the shared fraction must be the requested 0.25 (|x| = 0.25 on a unit cube), "
      ~ "up to the ring's global orientation sign-flip");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T7: an OPEN SPAN through the TOOL path, against the frozen
// reference row `grid3x2_edge_third_click_0149`
// (tests/fixtures/topopen_addloop.json; the whole 8-case golden runs against
// the KERNEL in tests/test_topopen_addloop_conformance.d — this is the one
// case driven through the tool's own commit leg, which that test cannot reach
// because `commitAddLoop`/`history_`/`meshSrc_` are private).
//
// A flat 3x2 quad grid seeded on the BORDER edge 0-1: the ring terminates at
// the mesh boundary at both ends, so the measured delta is the OPEN-SPAN
// formula +(N+1) verts / +(2N+1) edges / +N faces with N=2 crossed quads —
// 12/17/6 -> 15/22/8, NOT the closed ring's +2/+4/+2 — and all three crossed
// rails carry the SAME fraction 0.498288683 from their lower-index endpoint.
// Seed 0-1's only incident face is [0,1,5,4], whose dart is (0,1), so the
// kernel's ratio sense already matches the fixture's and the ratio passes
// unflipped.
//
// The undo assert pins OUR invariant, not parity: one Add Loop drag produces
// exactly ONE history entry (`commitAddLoop` brackets the single
// `insertEdgeLoops` in one before/after snapshot pair and records once; the
// motion handler only updates the ratio and never mutates the mesh). What the
// reference does with undo granularity for this gesture is still unmeasured.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m;
    static immutable float[3][12] P = [
        [-0.5f,-0.5f,0], [-0.166667f,-0.5f,0], [0.166667f,-0.5f,0], [0.5f,-0.5f,0],
        [-0.5f, 0.0f,0], [-0.166667f, 0.0f,0], [0.166667f, 0.0f,0], [0.5f, 0.0f,0],
        [-0.5f, 0.5f,0], [-0.166667f, 0.5f,0], [0.166667f, 0.5f,0], [0.5f, 0.5f,0],
    ];
    foreach (p; P) m.vertices ~= Vec3(p[0], p[1], p[2]);
    m.addFace([0u,1u,5u,4u]);  m.addFace([1u,2u,6u,5u]);  m.addFace([2u,3u,7u,6u]);
    m.addFace([4u,5u,9u,8u]);  m.addFace([5u,6u,10u,9u]); m.addFace([6u,7u,11u,10u]);
    m.buildLoops();
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);
    assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6);

    t.commitAddLoop(seed, 0.498288683f);

    // Open-span delta: +3 verts / +5 edges / +2 faces (N=2), NOT the closed
    // ring's +2/+4/+2.
    assert(m.vertices.length == 15, "open-span Add Loop must add N+1 == 3 vertices");
    assert(m.edges.length    == 22, "open-span Add Loop must add 2N+1 == 5 edges");
    assert(m.faces.length    ==  8, "open-span Add Loop must add N == 2 faces");
    foreach (const f; m.faces) assert(f.length == 4, "every face must stay a quad");

    // One uniform scalar: all three new verts share the reference x, on the
    // three rails y = -0.5 / 0.0 / +0.5.
    enum float X = -0.3339039385318756f;
    bool[3] seen;
    foreach (i; 12 .. 15) {
        assert(abs(m.vertices[i].x - X) < 1e-5f,
            "every crossed rail must be cut at the SAME scalar fraction");
        if (abs(m.vertices[i].y + 0.5f) < 1e-5f) seen[0] = true;
        if (abs(m.vertices[i].y)        < 1e-5f) seen[1] = true;
        if (abs(m.vertices[i].y - 0.5f) < 1e-5f) seen[2] = true;
    }
    assert(seen[0] && seen[1] && seen[2], "all three rails of the open span must be cut");

    // One gesture, ONE undo entry — this pins OUR side of the granularity
    // question; the reference's own answer is still unmeasured.
    assert(history.canUndo(), "an Add Loop cut must be undoable");
    history.undo();
    assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
        "one undo must restore the exact pre-cut grid");
    assert(!history.canUndo(), "one Add Loop drag must produce exactly ONE undo entry");
}

// ---------------------------------------------------------------------------
// addLoopUp — T6: the "at the Middle" option, driven through the REAL release
// handler (doc/tasks/work/0480-topopen-addloop-middle.md). Armed manually
// (mirroring the sibling direct-call convention), released at a pixel biased
// well off the seed edge's midpoint: with the option ON the cut must land at
// exactly 0.5 of EVERY crossed edge, ignoring the cursor entirely.
//
// This replaces the equivalent pin that used to sit on Split's release
// handler — the option moved modes, the law did not.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import toolpipe.packets : SubjectPacket;
    import std.algorithm : max, min;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Arm on the seed edge, with the rail in edges[seed][0] -> [1] order (the
    // same order `seedRail` establishes on a real press).
    t.addLoopArmed_ = true;
    t.addLoopSeed_  = cast(int)seed;
    t.seedRailA_    = m.vertices[m.edges[seed][0]];
    t.seedRailB_    = m.vertices[m.edges[seed][1]];
    t.addLoopMiddle_ = true;

    // Release pixel = 0.8 along the rail — nowhere near the midpoint, so an
    // ignored option would resolve ~0.8 (|x| = 0.3) instead of 0.5 (x = 0).
    Vec3 releasePos = t.seedRailA_ + (t.seedRailB_ - t.seedRailA_) * 0.8f;
    ImVec2 rp;
    assert(TopologyPenTool.projectPt(releasePos, vp, rp), "setup: releasePos must project");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)rp.x; eUp.y = cast(int)rp.y;
    assert(t.addLoopUp(eUp, vts), "addLoopUp must consume the release");

    assert(m.vertices.length == 12, "the option must still cut the full belt (Δv=+4)");
    float xLo = float.max, xHi = -float.max;
    foreach (i; 8 .. 12) {
        xLo = min(xLo, m.vertices[i].x);
        xHi = max(xHi, m.vertices[i].x);
    }
    assert(xHi - xLo < 1e-6f, "`middle` must be the same uniform scalar on every crossed edge");
    assert(abs(xLo) < 1e-5f,
        "`middle` must force the EXACT midpoint (x = 0 on a unit cube belt), ignoring the "
      ~ "release's own 0.8 fraction");
    assert(history.canUndo(), "a real Add Loop cut must record one undo entry");

    // ...and with the option OFF the SAME release follows the cursor again.
    history.undo();
    t.addLoopMiddle_ = false;
    t.addLoopArmed_  = true;
    t.addLoopSeed_   = cast(int)seed;
    assert(t.addLoopUp(eUp, vts), "addLoopUp must consume the second release");
    assert(m.vertices.length == 12, "the OFF path must still cut the full belt");
    float xLo2 = float.max, xHi2 = -float.max;
    foreach (i; 8 .. 12) {
        xLo2 = min(xLo2, m.vertices[i].x);
        xHi2 = max(xHi2, m.vertices[i].x);
    }
    assert(xHi2 - xLo2 < 1e-6f, "the OFF path is uniform across crossed edges too");
    assert(abs(xLo2) > 0.05f,
        "with the option OFF the cut must follow the release cursor, NOT snap to the midpoint");
}

// ---------------------------------------------------------------------------
// continuationNeighbor — T6 (P7, doc/topopen_p7_slide_plan.md §Testing):
// pure adjacency tests, independent of `commitSlide`/the down-handler.
// Valence-2 (one remaining edge) -> the unique neighbor; valence-1
// (grabbed-edge-only) -> -1; valence-3 on BARE EDGES (two remaining edges,
// no face anywhere, so no polygon to continue around) -> -1, still the
// held-fixed open case. The valence>2 WITH a polygon-continuation rail is
// pinned separately below.
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
    // A connects to B (grabbed), plus TWO others (E, F): 2 remaining edges,
    // and NO face anywhere — so there is no polygon whose walk could pick a
    // continuation, and the endpoint stays on the held-fixed open case.
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
            "valence>2 with NO incident face (no polygon to continue around) must report -1 "
          ~ "(held fixed — never guessed among ambiguous candidates)");
    }
}

// ---------------------------------------------------------------------------
// continuationNeighbor — VALENCE>2 POLYGON-CONTINUATION RAIL (the measured
// rule; supersedes V1's blanket hold-fixed for valence>2).
//
// Rig: quad [0,1,2,3] plus triangle [0,3,4] sharing edge 0-3 — the capture
// rig. Grab edge 0-1. Endpoint v0 is valence-3, so after excluding v1 it has
// TWO candidate neighbours in genuinely different directions (v3 along
// +Z, v4 along -X+Z) and V1 held it FIXED. The grabbed edge 0-1 belongs to
// exactly ONE polygon (the quad), whose walk continues across v0 onto 0-3, so
// v0 must now resolve to v3. v1 (valence-2) is the built-in control: its
// unique remaining neighbour v2, unchanged.
//
// This rig is the SINGLE-candidate case: `continuationRailCandidates` yields
// exactly one, so there is nothing to select and the answer cannot depend on
// the drag. That is asserted structurally below. It is NOT evidence that
// selection among SEVERAL candidates is drag-independent — that claim was
// made when this rule landed and has since been refuted; see
// `continuationNeighbor`'s doc comment.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    uint v0 = m.addVertex(Vec3( 0, 0, 0));
    uint v1 = m.addVertex(Vec3( 1, 0, 0));
    uint v2 = m.addVertex(Vec3( 1, 0, 1));
    uint v3 = m.addVertex(Vec3( 0, 0, 1));
    uint v4 = m.addVertex(Vec3(-1, 0, 1));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v3, v4]);

    assert(m.edgeNeighbors(v0).length == 3, "setup: v0 must be valence-3");

    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a valence>2 endpoint must take the POLYGON-CONTINUATION rail (0->3, the edge "
      ~ "continuing the grabbed edge around its own polygon), not be held fixed");
    assert(TopologyPenTool.continuationNeighbor(&m, v1, v0) == cast(int)v2,
        "the valence-2 control endpoint must keep reporting its unique remaining neighbour");

    // Scoped structural check: with exactly ONE candidate there is nothing to
    // select, and `continuationNeighbor` takes no cursor/drag argument at all,
    // so re-querying can only ever return the same rail. Asserted here so a
    // future refactor that threads a direction into the SINGLE-candidate path
    // trips this test. (The multi-candidate path is a different question and
    // is deliberately not answered — see the OPEN-CASE test below.)
    assert(TopologyPenTool.continuationRailCandidates(&m, v0, v1).length == 1,
        "setup: this rig's valence>2 endpoint must offer exactly ONE continuation "
      ~ "candidate — the unambiguous case, which is all this rule acts on");
    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a single-candidate rail is unambiguous and cannot depend on the drag");
}

// ---------------------------------------------------------------------------
// continuationNeighbor — OPEN CASE, still held fixed: an INTERIOR grabbed
// edge (two incident faces) offers TWO distinct continuation rails at each
// endpoint, one per face. Measurement says the reference DOES pick one and
// that the pick flips with the sign of the drag's dominant component — a
// SIGN-DEPENDENT selection rule that is not determined (the one candidate law
// that fits all four captured multi-candidate gestures carries the opposite
// sign convention from the 32/32 single-candidate law, so it cannot be the
// same rule). Deferred, NOT tie-broken — this test pins the deferral so a
// later "just pick the first face" shortcut, or a guessed sign rule, cannot
// slip in unnoticed. Rig: quads [0,1,2,3] and [1,4,5,2] sharing edge 1-2.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    uint v3 = m.addVertex(Vec3(0, 0, 1));
    uint v4 = m.addVertex(Vec3(2, 0, 0));
    uint v5 = m.addVertex(Vec3(2, 0, 1));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v1, v4, v5, v2]);

    assert(TopologyPenTool.continuationRailCandidates(&m, v1, v2).length == 2,
        "setup: an interior grabbed edge must offer one continuation per incident face");
    assert(TopologyPenTool.continuationNeighbor(&m, v1, v2) == -1,
        "2+ distinct continuation rails is an OPEN case -> held fixed, never tie-broken");
    assert(TopologyPenTool.continuationNeighbor(&m, v2, v1) == -1,
        "...at both endpoints of the interior edge");

    // The boundary edges of the same rig stay on the valence-2 fast path,
    // proving the new branch didn't disturb the unchanged regime.
    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a valence-2 endpoint must still report its unique remaining neighbour");
}

// ---------------------------------------------------------------------------
// commitSlide — the valence>2 endpoint MOVES (end-to-end over the kernel, not
// just the rail lookup). Same capture rig as above: v0 was once held fixed at
// its original position for every fraction; it must travel along the 0->3
// continuation rail, and land nowhere near the competing 0->4 neighbour.
//
// UPDATED for the measured law. `commitSlide` now takes the law's ONE signed
// scalar instead of a per-endpoint `[0,1]` fraction pair. `deltaK = -0.5`
// gives `offset = +0.5 * unit(rail)` at BOTH endpoints; the 0->3 rail is unit
// length, so v0's landing point is numerically the same `p0 + (p3-p0)*0.5` the
// old `tA = 0.5` produced — the rail-CHOICE assertions this test exists for
// are unchanged. What did change: v1 no longer has an independent `tB = 0`, so
// it slides too (its own 1->2 rail, same scalar). That is the law, not a
// weakening — the old "stays put at fraction 0" line is replaced by an
// assertion that v1 lands exactly on ITS own rail, which is a strictly
// stronger statement about the same vertex.
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
    Vec3 p0 = Vec3( 0, 0, 0), p3 = Vec3(0, 0, 1), p4 = Vec3(-1, 0, 1);
    uint v0 = m.addVertex(p0);
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    uint v3 = m.addVertex(p3);
    uint v4 = m.addVertex(p4);
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v3, v4]);
    Vec3 p1 = m.vertices[v1], p2 = m.vertices[v2];

    uint seed = m.edgeIndex(v0, v1);
    assert(seed != uint.max, "setup: the grabbed edge 0-1 must exist");

    int nA = TopologyPenTool.continuationNeighbor(&m, v0, v1);
    int nB = TopologyPenTool.continuationNeighbor(&m, v1, v0);
    t.commitSlide(seed, cast(int)v0, cast(int)v1, nA, nB, -0.5f);

    assert((m.vertices[v0] - p0).length > 1e-3f,
        "the valence>2 endpoint must no longer be held fixed");
    assert((m.vertices[v0] - (p0 + (p3 - p0) * 0.5f)).length < 1e-5f,
        "it must land ON the 0->3 polygon-continuation rail, 0.5 world units along it");
    assert((m.vertices[v0] - (p0 + (p4 - p0) * 0.5f)).length > 1e-2f,
        "and NOT on the competing 0->4 rail");
    assert((m.vertices[v1] - (p1 + (p2 - p1) * 0.5f)).length < 1e-5f,
        "the valence-2 control endpoint slides the SAME 0.5 world units along ITS "
      ~ "own 1->2 rail — one scalar, two rail directions");
    assert(m.faces.length == 2 && m.vertices.length == 5,
        "slide is position-only — topology must be untouched");
    assert(history.canUndo(), "a real slide must record one undo entry");
    history.undo();
    assert((m.vertices[v0] - p0).length < 1e-6f, "undo must restore the pre-slide position");
}

// ---------------------------------------------------------------------------
// commitSlide — T1 (P7, doc/topopen_p7_slide_plan.md §Testing, "colinear
// (two-sided)"): a rig where the grabbed edge A-B has A also on edge A-D and
// B also on edge B-E (both valence-2, DIFFERENT rail directions, and
// DIFFERENT rail LENGTHS: |AD| = 2, |BE| = sqrt(18)) — each endpoint must land
// on ITS OWN incident edge, regardless of the other endpoint's rail. Driven
// directly (private, same-module access); `gpu_` stays null so the guarded
// display tail never runs under bare `dub test`, mirroring every other Tier-B
// unittest in this file.
//
// UPDATED for the measured law, with the test's POINT strengthened rather
// than weakened. The old version fed independent fractions (0.4, 0.7) and
// asserted two independent lerps — which under the old law could be satisfied
// by any per-endpoint parameterisation. The law says both endpoints share ONE
// signed scalar and differ only in rail direction, so this now feeds one
// scalar and asserts the consequence the old form could not see: the two
// endpoints travel the SAME world DISTANCE (|deltaK|) along rails of
// DIFFERENT length, i.e. the displacement is a world offset and emphatically
// NOT a shared normalised fraction. Rail INDEPENDENCE, the original point, is
// still asserted — each landing point is checked against its own rail.
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

    enum float kDeltaK = -0.8f;   // negative -> both endpoints move TOWARD their rail neighbour
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, cast(int)e, kDeltaK);

    Vec3 railA = (d0 - a0) * (1.0f / (d0 - a0).length);
    Vec3 railB = (e0 - b0) * (1.0f / (e0 - b0).length);
    Vec3 expectedA = a0 + railA * (-kDeltaK);
    Vec3 expectedB = b0 + railB * (-kDeltaK);
    assert((m.vertices[a] - expectedA).length < 1e-5f,
        "A must slide 0.8 WORLD UNITS toward D along A's own incident edge");
    assert((m.vertices[b] - expectedB).length < 1e-5f,
        "B must slide 0.8 WORLD UNITS toward E along B's own incident edge, "
      ~ "independent of A's own rail direction");
    assert(((m.vertices[a] - a0).length - (m.vertices[b] - b0).length) < 1e-5f
        && ((m.vertices[b] - b0).length - (m.vertices[a] - a0).length) < 1e-5f,
        "both endpoints must travel the SAME world distance despite rails of "
      ~ "different length — one shared scalar, not a shared [0,1] fraction");
    assert(history.canUndo(), "a real slide must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSlide — T2, INVERTED BY MEASUREMENT: NO OVERSHOOT CLAMP.
//
// This test used to assert the opposite — that an overshoot fraction clamps
// EXACTLY to the neighbour's pre-slide position — on the strength of an
// early reading of the reference (plan §1/§3). The conformance capture
// refutes it directly: the reference's slide parameter was measured over
// [-8.53, +4.19] and vertices pass THROUGH the rail neighbour and keep going.
// So the assertion is reversed, not relaxed: the endpoint must land at the
// exact unbounded position, strictly PAST the neighbour, and the old
// clamped-at-neighbour answer is now explicitly asserted WRONG. It is also
// checked in the negative direction (a vertex may run backwards past its own
// start), which the clamped implementation could never do at all.
//
// This is the assertion that makes the gain matter — see
// `slideDeltaFromDrag`'s note on clamp removal.
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

    // |A->D| = sqrt(10) ~= 3.1623. Slide 5 world units toward D: comfortably
    // PAST D, which the old [0,1] clamp made unreachable.
    Vec3 rail = (d0 - a0) * (1.0f / (d0 - a0).length);
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -5.0f);

    assert((m.vertices[a] - (a0 + rail * 5.0f)).length < 1e-5f,
        "an overshoot must land at the exact UNBOUNDED position — there is no [0,1] clamp");
    assert((m.vertices[a] - d0).length > 1.0f,
        "...and specifically must NOT stop at the neighbour's pre-slide position");
    assert(dot(m.vertices[a] - d0, d0 - a0) > 0.0f,
        "...it must be BEYOND the neighbour, on the far side");

    // The negative direction is equally unbounded: the vertex runs backwards
    // past its own start, away from the rail neighbour.
    history.undo();
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 2.0f);
    assert((m.vertices[a] - (a0 - rail * 2.0f)).length < 1e-5f,
        "a negative slide must run AWAY from the rail neighbour, past the start point");
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
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -0.5f);

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
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -0.5f);
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

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -1.0f);

    // deltaK = -1.0 on the unit-length-per-world-unit rail A->D (|AD| = 2)
    // puts A exactly 1 world unit toward D — numerically the same point the
    // old `tA = 0.5` fraction produced, so this assertion is unchanged.
    Vec3 expectedA = a0 + (d0 - a0) * 0.5f;
    assert((m.vertices[a] - expectedA).length < 1e-5f, "A (slidable) must slide normally");
    assert((m.vertices[b] - b0).length < 1e-6f,
        "B (valence-1, held fixed) must NOT move — a held-fixed endpoint consumes "
      ~ "no scalar at all, even though the scalar is now shared");
}

// ---------------------------------------------------------------------------
// commitSlide — T5b MIXED VALENCE (P7, doc/topopen_p7_slide_plan.md
// §Testing "held-fixed endpoint" + the mixed-valence requirement): B has
// TWO remaining incident edges after excluding the grabbed edge A-B
// (valence-3 overall) and NO incident face -> nB=-1 -> HELD FIXED, while A
// (valence-2) slides normally in the SAME gesture. Distinct from T5a (which
// uses a valence-1 B) — this is the genuinely ambiguous ≥2-remaining case
// with no polygon-continuation rail to resolve it, still deferred rather
// than guessed.
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
        "setup: B must have 2 remaining incident edges (valence>2) and no face "
      ~ "-> no continuation rail -> deferred/held-fixed");

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -1.2f);

    // deltaK = -1.2 on the |AD| = 2 rail lands A at the same point the old
    // `tA = 0.6` fraction produced — assertion unchanged.
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
    t.commitSlide(seed, cast(int)a, cast(int)b, -1, -1, -0.5f);
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
    t.slideAnchor_ = Vec3(1, 0, 0);
    // A deliberately NON-zero pending scalar: the gate must reject on pixel
    // travel alone, without relying on the scalar happening to be ~0.
    t.slideDeltaK_ = 0.5f;

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
// Slide law — REFERENCE PARITY CONFORMANCE (the primary gate for this
// gesture's parameterisation: `dominantAxisDelta` + `slideEndpointPos` +
// `continuationNeighbor`, driven through the REAL `commitSlide` path).
//
// 20 independently-captured gestures over 3 meshes, each giving the mesh, the
// grabbed edge, the reference's own world-space move delta for the committed
// evaluation, and the exact post-gesture vertex positions. Feeding the
// RECORDED delta in — rather than a pixel drag — is deliberate and is what
// makes this a real gate: it tests axis extraction, rail resolution and rail
// ORIENTATION independently of our gain, which is a documented divergence
// (see `slideDeltaFromDrag`). A wrong sign, a wrong rail, or a surviving
// `[0,1]` clamp all fail here; only the magnitude curve is out of scope.
//
// Tolerance 1e-7, the fixture's own. A correct port lands at 3.3e-08, which
// is the float STORAGE granularity of the captured targets — i.e. the floor,
// not a slack budget. Anything materially above it means the law drifted.
//
// SPLIT BY DETERMINACY. 16 of the 20 cases grab an edge whose endpoints each
// have exactly ONE continuation edge; those are asserted against
// `expected_vertices`, and their resolved rails are additionally cross-checked
// against the captured ones (32/32 endpoints). The other 4 have TWO
// continuation candidates per endpoint, where the reference's selection is
// sign-dependent and undetermined (`continuationNeighbor`'s doc comment), so
// this tool holds those endpoints FIXED by design. For those the test asserts
// exactly that — no movement, no undo entry — instead of asserting positions
// we deliberately do not reproduce. That is the shipped contract under test,
// not a weakened assertion; asserting `expected_vertices` there would require
// guessing the selection rule.
//
// On the rail ORIENTATION, which is the subtle half of this law: the source
// contract phrases it as the continuation edge's direction "as traversed in
// its polygon's winding". Measured over these 32 determinate endpoints that
// reproduces only 16 — a polygon walk departs from one end of the grabbed
// edge and ARRIVES at the other, so the raw traversal points inward at one of
// them. `unit(neighbor - endpoint)`, i.e. the same edge taken oriented AWAY
// from the grabbed edge, is 32/32. Half these cases invert under the other
// reading, which is why the assertions below are on positions.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import view       : View;
    import editmode   : EditMode;

    static immutable double[3][8] run11BoundaryVerts = [
        [0.49750889051610303, -0.41370677261163746, -0.03908497105394376],
        [0.36219140916061615, -0.35986172605662464, 0.1441044938142526],
        [-0.15470460441553574, 0.27729932133893814, -0.4249950066121535],
        [-0.019387123060048833, 0.22345427478392532, -0.6081844714803498],
        [-0.011595571798637481, -0.045949952078994126, 0.16439239563592428],
        [-0.13274307498054808, 0.10338466840434088, 0.031009700223485356],
        [-0.36729337599672546, 0.19671608243302977, 0.3485381059950258],
        [-0.24614587281481487, 0.04738146194969475, 0.4819208014074648],
    ];
    static immutable uint[][2] run11BoundaryFaces = [
        [3u, 2u, 1u, 0u],
        [4u, 5u, 6u, 7u],
    ];

    static immutable double[3][6] run13StripVerts = [
        [0.2678946589037937, -0.2549208077455667, 0.0735016433594463],
        [0.09021165423699151, -0.03589669770334199, -0.12212630991213082],
        [-0.08747135042981072, 0.18312741233888274, -0.3177542631837079],
        [0.08747135042981116, -0.18312741233888297, 0.31775426318370814],
        [-0.09021165423699107, 0.035896697703341765, 0.12212630991213104],
        [-0.26789465890379327, 0.25492080774556647, -0.07350164335944608],
    ];
    static immutable uint[][2] run13StripFaces = [
        [0u, 1u, 4u, 3u],
        [1u, 2u, 5u, 4u],
    ];

    static immutable double[3][6] run14BentVerts = [
        [0.2678946589037937, -0.2549208077455667, 0.0735016433594463],
        [0.09021165423699151, -0.03589669770334199, -0.12212630991213082],
        [0.09171882133094071, 0.04508019534620554, -0.3640606251148423],
        [0.08747135042981116, -0.18312741233888297, 0.31775426318370814],
        [-0.09021165423699107, 0.035896697703341765, 0.12212630991213104],
        [-0.2048835161282584, 0.2224315836214501, -0.13699603164314578],
    ];
    static immutable uint[][2] run14BentFaces = [
        [0u, 1u, 4u, 3u],
        [1u, 2u, 5u, 4u],
    ];

    static immutable double[3][8] exp00 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp01 = [
        [0.3714374601840973, -0.25830259919166565, -0.177888885140419],
        [0.23611997067928314, -0.20445753633975983, 0.005300584714859724],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp02 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp03 = [
        [0.5381929874420166, -0.4638567268848419, 0.0057079605758190155],
        [0.40287548303604126, -0.4100116789340973, 0.18889743089675903],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp04 = [
        [0.5864051580429077, -0.5232864022254944, 0.05878932401537895],
        [0.45108771324157715, -0.46944132447242737, 0.24197879433631897],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp05 = [
        [0.7193203568458557, -0.6871265769004822, 0.20512813329696655],
        [0.5840028524398804, -0.6332815289497375, 0.38831761479377747],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp06 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp07 = [
        [0.4104355275630951, -0.3063742518424988, -0.13495221734046936],
        [0.27511805295944214, -0.25252923369407654, 0.04823724552989006],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp08 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [0.09341167658567429, -0.028545614331960678, -0.15182043612003326],
        [0.22872914373874664, -0.08239065110683441, -0.335009902715683],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp09 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.3369227945804596, 0.5019137859344482, -0.625616192817688],
        [-0.20160531997680664, 0.4480687975883484, -0.8088056445121765],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp10 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.1161508783698082, -0.004345679190009832, 0.3059367835521698],
        [-0.237298384308815, 0.14498893916606903, 0.17255409061908722],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp11 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.11959760636091232, -0.002974170260131359, 0.3106028735637665],
        [-0.24074511229991913, 0.14636044204235077, 0.1772201806306839],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][6] exp12 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [-0.2885283827781677, 0.430963933467865, -0.5391168594360352],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [-0.46895167231559753, 0.5027573108673096, -0.2948642671108246],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp13 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.26759618520736694, -0.2545529007911682, 0.07317303866147995],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [0.08717288821935654, -0.18275950849056244, 0.3174256682395935],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp14 = [
        [0.48049625754356384, -0.5169879794120789, 0.3075747787952423],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.30007296800613403, -0.4451945722103119, 0.5518273711204529],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp15 = [
        [0.14727678894996643, -0.10623905807733536, -0.05929791182279587],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [-0.033146511763334274, -0.03444566950201988, 0.1849547028541565],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp16 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.09385570138692856, 0.1598898470401764, -0.707076907157898],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [-0.2987203001976013, 0.3750743865966797, -0.34903764724731445],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp17 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.28252652287483215, -0.2729570269584656, 0.0896112322807312],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [0.10210320353507996, -0.2011636346578598, 0.33386385440826416],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp18 = [
        [0.07406548410654068, -0.015993835404515266, -0.13990314304828644],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [-0.10635782033205032, 0.05579955875873566, 0.10434948652982712],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp19 = [
        [0.40300917625427246, -0.42147210240364075, 0.2222619205713272],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.22258585691452026, -0.34967872500419617, 0.46651455760002136],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];

    struct Case {
        string id; int mesh; uint ga, gb; double[3] delta; int domAxis;
        int railA, railB;            // -1 = fixture reports no rail for that endpoint
        bool determinate;            // false = MULTI-candidate endpoint, held fixed here
        const(double[3])[] expect;
    }
    static immutable Case[20] cases = [
        Case("run11_boundary/A_step02", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp00[]),
        Case("run11_boundary/A_step03", 0, 0u, 1u, [0.0, 0.0, -0.24353848868170486], 2, 3, 2, true, exp01[]),
        Case("run11_boundary/A_step06", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp02[]),
        Case("run11_boundary/B_px060", 0, 0u, 1u, [0.0, 0.0785914666275071, 0.0], 1, 3, 2, true, exp03[]),
        Case("run11_boundary/B_px120", 0, 0u, 1u, [0.0, 0.17172540888373483, 0.0], 1, 3, 2, true, exp04[]),
        Case("run11_boundary/B_px240", 0, 0u, 1u, [0.0, 0.4284842559971134, 0.0], 1, 3, 2, true, exp05[]),
        Case("run11_boundary/C_S_p", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp06[]),
        Case("run11_boundary/C_S_m", 0, 0u, 1u, [0.0, -0.16820394089168939, 0.0], 1, 3, 2, true, exp07[]),
        Case("run11_boundary/C_F_p", 0, 2u, 3u, [0.0, -0.47929860233631355, 0.0], 1, 1, 0, true, exp08[]),
        Case("run11_boundary/C_F_m", 0, 2u, 3u, [0.0, 0.352, 0.0], 1, 1, 0, true, exp09[]),
        Case("run11_boundary/C_C_p", 0, 4u, 5u, [-0.18082462078503622, 0.0, 0.0], 0, 7, 6, true, exp10[]),
        Case("run11_boundary/C_C_m", 0, 4u, 5u, [0.0, 0.0, -0.1867856083621176], 2, 7, 6, true, exp11[]),
        Case("run13_strip/I_shared_p", 1, 1u, 4u, [0.0, 0.7316310550781467, 0.0], 1, 2, 5, false, exp12[]),
        Case("run13_strip/I_shared_m", 1, 1u, 4u, [0.0, -0.3426625872266482, 0.0], 1, 2, 5, false, exp13[]),
        Case("run13_strip/I_outer_p", 1, 0u, 3u, [0.0, 0.41069314088024644, 0.0], 1, 1, 4, true, exp14[]),
        Case("run13_strip/I_outer_m", 1, 0u, 3u, [0.0, -0.23300354934593515, 0.0], 1, 1, 4, true, exp15[]),
        Case("run14_bent/I_shared_p", 2, 1u, 4u, [0.0, 0.0, -0.6168572132788047], 2, 2, 5, false, exp16[]),
        Case("run14_bent/I_shared_m", 2, 1u, 4u, [0.0, 0.0, 0.37150423149664574], 2, 0, 3, false, exp17[]),
        Case("run14_bent/I_outer_p", 2, 0u, 3u, [0.0, 0.0, -0.3744295004047694], 2, 1, 4, true, exp18[]),
        Case("run14_bent/I_outer_m", 2, 0u, 3u, [0.0, 0.0, 0.26100744462938286], 2, 1, 4, true, exp19[]),
    ];

    string report;
    double overallWorst = 0;
    int gated = 0, heldFixed = 0;

    foreach (ref c; cases) {
        auto verts = c.mesh == 0 ? run11BoundaryVerts[]
                   : c.mesh == 1 ? run13StripVerts[]
                                 : run14BentVerts[];
        auto faces = c.mesh == 0 ? run11BoundaryFaces[]
                   : c.mesh == 1 ? run13StripFaces[]
                                 : run14BentFaces[];
        // Two disjoint quads vs a 2-quad strip sharing one edge. Asserted so a
        // face-list transcription error cannot quietly change the topology
        // under test — the rail resolution reads faces, not just positions.
        immutable size_t expectEdges = (c.mesh == 0) ? 8 : 7;

        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        t.history_          = history;
        t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                        "mesh.topoPen_slide", "Topology Slide",
                                                        MeshEditScope.Position);
        Mesh m;
        t.meshSrc_ = () => &m;
        foreach (v; verts)
            m.addVertex(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]));
        foreach (fc; faces) m.addFace(fc.dup);
        m.buildLoops();

        assert(m.vertices.length == verts.length && m.faces.length == faces.length
            && m.edges.length == expectEdges,
            format("case %s: rebuilt rig must match the captured one "
                 ~ "(%d verts / %d edges / %d faces); got %d/%d/%d",
                   c.id, verts.length, expectEdges, faces.length,
                   m.vertices.length, m.edges.length, m.faces.length));

        uint seed = m.edgeIndex(c.ga, c.gb);
        assert(seed != uint.max,
            format("case %s: the grabbed edge %d-%d must exist", c.id, c.ga, c.gb));

        // --- Axis extraction, checked against the reference's OWN recorded
        // dominant axis rather than against our own re-derivation of it. ---
        Vec3 dv = Vec3(cast(float) c.delta[0], cast(float) c.delta[1], cast(float) c.delta[2]);
        float gotAxisVal = TopologyPenTool.dominantAxisDelta(dv);
        immutable float wantAxisVal = c.domAxis == 0 ? dv.x : c.domAxis == 1 ? dv.y : dv.z;
        assert(gotAxisVal == wantAxisVal,
            format("case %s: argmax|delta| must select world axis %d", c.id, c.domAxis));
        // Consume the FULL-precision component, not the float round-trip —
        // see `slideEndpointPos` on why the API is double.
        immutable double deltaK = c.delta[c.domAxis];

        int nA = TopologyPenTool.continuationNeighbor(&m, c.ga, c.gb);
        int nB = TopologyPenTool.continuationNeighbor(&m, c.gb, c.ga);

        auto before = MeshSnapshot.capture(m);
        t.commitSlide(seed, cast(int) c.ga, cast(int) c.gb, nA, nB, deltaK);

        assert(m.vertices.length == verts.length && m.edges.length == expectEdges
            && m.faces.length == faces.length,
            format("case %s: slide is position-only — topology must be untouched", c.id));

        if (!c.determinate) {
            // MULTI-candidate endpoints: selection is undetermined, so both
            // ends are held fixed and the whole gesture is a clean no-op.
            ++heldFixed;
            assert(nA == -1 && nB == -1,
                format("case %s: a multi-continuation endpoint must resolve to NO rail "
                     ~ "(-1); got %d/%d — a tie-break has slipped in", c.id, nA, nB));
            assert(m.vertices == before.vertices,
                format("case %s: with neither endpoint slidable the commit must not "
                     ~ "move any vertex", c.id));
            assert(!history.canUndo(),
                format("case %s: a both-fixed slide must record NO undo entry", c.id));
            continue;
        }

        ++gated;
        assert(nA == c.railA && nB == c.railB,
            format("case %s: resolved rails must match the captured ones "
                 ~ "(%d/%d); got %d/%d", c.id, c.railA, c.railB, nA, nB));

        double worst = 0;
        size_t worstAt = 0;
        foreach (i; 0 .. verts.length) {
            auto e = c.expect[i];
            const double dx = cast(double) m.vertices[i].x - e[0];
            const double dy = cast(double) m.vertices[i].y - e[1];
            const double dz = cast(double) m.vertices[i].z - e[2];
            import std.math : sqrt;
            const double dist = sqrt(dx * dx + dy * dy + dz * dz);
            if (dist > worst) { worst = dist; worstAt = i; }
        }
        report ~= format("\n    %-26s axis=%d delta=%+.6f worst=%.4e at v%d",
                         c.id, c.domAxis, deltaK, worst, worstAt);
        if (worst > overallWorst) overallWorst = worst;

        // Guard against a vacuous pass: the grabbed endpoints must genuinely
        // move, or "reproduces the target" would be satisfied by doing nothing.
        assert((m.vertices[c.ga] - before.vertices[c.ga]).length > 1e-4f
            && (m.vertices[c.gb] - before.vertices[c.gb]).length > 1e-4f,
            format("case %s: both grabbed endpoints must actually slide", c.id));

        // The captured invariant that both endpoints share ONE scalar: equal
        // travel distance, independent of the two rails' directions/lengths.
        immutable double travA = (m.vertices[c.ga] - before.vertices[c.ga]).length;
        immutable double travB = (m.vertices[c.gb] - before.vertices[c.gb]).length;
        import std.math : abs;
        assert(abs(travA - travB) < 1e-6,
            format("case %s: both endpoints must travel the same distance "
                 ~ "(%.9f vs %.9f)", c.id, travA, travB));
        // ...and that distance is |delta[k]| EXACTLY — no clamp anywhere.
        assert(abs(travA - abs(deltaK)) < 1e-6,
            format("case %s: travel must equal |delta[k]| = %.9f exactly (got %.9f) "
                 ~ "— a surviving [0,1] clamp would shorten it", c.id, abs(deltaK), travA));

        assert(history.canUndo(), format("case %s: a real slide must be undoable", c.id));
        history.undo();
        foreach (i; 0 .. verts.length)
            assert((m.vertices[i] - before.vertices[i]).length < 1e-6f,
                format("case %s: one undo must fully revert the gesture", c.id));
    }

    assert(gated == 16 && heldFixed == 4,
        format("the split by determinacy must stay 16 gated / 4 held-fixed; got %d/%d",
               gated, heldFixed));
    assert(overallWorst < 1e-7,
        format("the Slide law must reproduce every determinate captured gesture to the "
             ~ "fixture's 1e-7 (a correct port lands at 3.3e-08); worst over %d cases "
             ~ "= %.4e%s", gated, overallWorst, report));
}

// ---------------------------------------------------------------------------
// Smooth relaxation kernel — REFERENCE PARITY CONFORMANCE (the primary gate
// for `tools/edit/smooth_relax.d`; that module's header states the law and
// the ablation evidence).
//
// Six independently-captured cases over two rigs, replayed through the REAL
// path this tool uses: a `Mesh` built from the rig, `buildRelaxTopology`'s
// own CSR + open-edge extraction, then `relaxPasses`. The expected values
// are the exact positions the reference kernel produces BEFORE its per-vertex
// background re-snap — i.e. precisely the output this kernel must reproduce
// — read at full double precision and stable across independent capture
// sessions. Coverage: both rig orientations, strength 1.0 and 0.5, a single
// iteration and a 57-iteration run, and the two lock flags.
//
// Tolerance: 1e-9. A correct port lands near 1e-16 (the fixture's own
// clean-room verifier reaches 2.3e-16); the four orders of margin absorb
// only the neighbour-summation ORDER difference between that verifier's
// sorted 1-ring and this mesh's CSR order. Anything approaching 1e-9 means
// the law itself has drifted, not that the arithmetic reassociated.
//
// The two lock cases are the load-bearing evidence for NOT implementing
// `lockBound`/`lockCorner` on this path: their expected positions are
// IDENTICAL to the unlocked case's, boundary and corner vertices included.
// See `applySmoothPasses`'s doc comment.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import std.math   : abs;

    string report;          // every case's worst error, so ONE failure shows the whole picture
    double overallWorst = 0;

    // Shared topology (the two rigs are the same builder output, differing
    // only in orientation, so edges/faces are identical).
    static immutable uint[][9] rigFaces = [
        [0u,2u,3u,1u],
        [2u,4u,5u,3u],
        [4u,6u,7u,5u],
        [6u,8u,9u,7u],
        [10u,11u,12u],
        [10u,12u,13u],
        [10u,13u,14u],
        [10u,14u,15u],
        [10u,15u,11u],
    ];
    enum size_t kRigEdgeCount = 23;
    static immutable double[3][16] rigAVerts = [
        [-0.3499999940395355, -0.05000000074505806, 0.55859375],
        [-0.3499999940395355, 0.05000000074505806, 0.55859375],
        [-0.2800000011920929, -0.05000000074505806, 0.6274999976158142],
        [-0.2800000011920929, 0.05000000074505806, 0.6274999976158142],
        [0.0, -0.05000000074505806, 0.75],
        [0.0, 0.05000000074505806, 0.75],
        [0.10000000149011612, -0.05000000074505806, 0.734375],
        [0.10000000149011612, 0.05000000074505806, 0.734375],
        [0.3499999940395355, -0.05000000074505806, 0.55859375],
        [0.3499999940395355, 0.05000000074505806, 0.55859375],
        [0.75, 0.0, 0.5],
        [1.0499999523162842, 0.05000000074505806, 0.5],
        [0.8999999761581421, 0.2800000011920929, 0.5],
        [0.6499999761581421, 0.20000000298023224, 0.5],
        [0.4699999988079071, -0.05000000074505806, 0.5],
        [0.8299999833106995, -0.25, 0.5],
    ];
    static immutable double[3][16] rigBVerts = [
        [0.55859375, -0.3499999940395355, -0.05000000074505806],
        [0.55859375, -0.3499999940395355, 0.05000000074505806],
        [0.6274999976158142, -0.2800000011920929, -0.05000000074505806],
        [0.6274999976158142, -0.2800000011920929, 0.05000000074505806],
        [0.75, 0.0, -0.05000000074505806],
        [0.75, 0.0, 0.05000000074505806],
        [0.734375, 0.10000000149011612, -0.05000000074505806],
        [0.734375, 0.10000000149011612, 0.05000000074505806],
        [0.55859375, 0.3499999940395355, -0.05000000074505806],
        [0.55859375, 0.3499999940395355, 0.05000000074505806],
        [0.5, 0.75, 0.0],
        [0.5, 1.0499999523162842, 0.05000000074505806],
        [0.5, 0.8999999761581421, 0.2800000011920929],
        [0.5, 0.6499999761581421, 0.20000000298023224],
        [0.5, 0.4699999988079071, -0.05000000074505806],
        [0.5, 0.8299999833106995, -0.25],
    ];

    // The six captured cases: rig, strength, iteration count, and the exact
    // pre-re-snap position the reference kernel produces for every vertex.
    struct Case { string id; bool rigB; double strength; int iters; const(double[3])[] expect; }
    static immutable double[3][16] expect0 = [
        [-0.3509309595007398, -0.047522392129164905, 0.5595394926268349],
        [-0.3509309595007398, 0.047522392129164905, 0.5595394926268349],
        [-0.2793560716931852, -0.052477609360951215, 0.6272103371785385],
        [-0.2793560716931852, 0.052477609360951215, 0.6272103371785385],
        [0.0002310144766059759, -0.05000000074505806, 0.7489853802966783],
        [0.0002310144766059759, 0.05000000074505806, 0.7489853802966783],
        [0.09908954754612097, -0.05376729737875115, 0.7333589947213962],
        [0.09908954754612097, 0.05376729737875115, 0.7333589947213962],
        [0.3509664694692213, -0.04623270411136497, 0.5599682927923663],
        [0.3509664694692213, 0.04623270411136497, 0.5599682927923663],
        [0.7531294454837306, 0.005525881341248126, 0.5],
        [1.0514480743992267, 0.04595558369844894, 0.5],
        [0.9012222446670399, 0.278483298147573, 0.5],
        [0.6439291070734187, 0.20394696446603477, 0.5],
        [0.47358182993924025, -0.05548756388530698, 0.5],
        [0.8266891851885189, -0.24842415959567274, 0.5],
    ];
    static immutable double[3][16] expect1 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect2 = [
        [0.5590666213134174, -0.3504654767701377, -0.04876119643711148],
        [0.5590666213134174, -0.3504654767701377, 0.04876119643711148],
        [0.6273551673971763, -0.27967803644263906, -0.05123880505300464],
        [0.6273551673971763, -0.27967803644263906, 0.05123880505300464],
        [0.7494926901483392, 0.00011550723830298796, -0.05000000074505806],
        [0.7494926901483392, 0.00011550723830298796, 0.05000000074505806],
        [0.7338669973606982, 0.09954477451811855, -0.0518836490619046],
        [0.7338669973606982, 0.09954477451811855, 0.0518836490619046],
        [0.5592810213961832, 0.3504832317543784, -0.048116352428211516],
        [0.5592810213961832, 0.3504832317543784, 0.048116352428211516],
        [0.5, 0.7515647227418654, 0.002762940670624063],
        [0.5, 1.0507240133577553, 0.047977792221753496],
        [0.5, 0.900611110412591, 0.27924164966983295],
        [0.5, 0.6469645416157803, 0.2019734837231335],
        [0.5, 0.4717909143735737, -0.05274378231518252],
        [0.5, 0.8283445842496092, -0.24921207979783636],
    ];
    static immutable double[3][16] expect3 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect4 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect5 = [
        [0.5962737273978181, -0.363094558491022, -0.015080484073826325],
        [0.5962737273978181, -0.363094558491022, 0.015080484073826325],
        [0.626922080802297, -0.27763038288802244, -0.052343801519729456],
        [0.626922080802297, -0.27763038288802244, 0.052343801519729456],
        [0.6965278116823995, 0.00827632716910339, -0.09207342573683973],
        [0.6965278116823995, 0.00827632716910339, 0.09207342573683973],
        [0.6937818213225817, 0.08148025116265885, -0.08522879883085108],
        [0.6937818213225817, 0.08148025116265885, 0.08522879883085108],
        [0.6155570564107176, 0.37096836334530564, -0.005273493564043758],
        [0.6155570564107176, 0.37096836334530564, 0.005273493564043758],
        [0.5, 0.7749926766641773, 0.03832796273685365],
        [0.5, 1.0515001104481065, 0.006508481493563776],
        [0.5, 0.9192413876921455, 0.2789238997470296],
        [0.5, 0.5861224012616796, 0.22484105746251834],
        [0.5, 0.5177956877733761, -0.08903431310515317],
        [0.5, 0.8003476229116904, -0.22956708416248714],
    ];
    static immutable Case[6] cases = [
        Case("click_strength1_iter1", false, 1.0, 1, expect0[]),
        Case("click_strength1_iter1_rigB", true, 1.0, 1, expect1[]),
        Case("click_strength0.5_iter1", true, 0.5, 1, expect2[]),
        Case("click_lockBound_true", true, 1.0, 1, expect3[]),
        Case("click_lockCorner_true", true, 1.0, 1, expect4[]),
        Case("drag_57_iterations", true, 1.0, 57, expect5[]),
    ];

    foreach (ci, ref c; cases) {
        auto verts = c.rigB ? rigBVerts[] : rigAVerts[];

        Mesh m;
        foreach (v; verts) m.addVertex(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]));
        foreach (f; rigFaces) m.addFace(f.dup);
        m.buildLoops();

        // Rig sanity: the faces must derive exactly the captured edge set, or
        // the topology under test is not the topology that was measured.
        assert(m.vertices.length == verts.length && m.edges.length == kRigEdgeCount
            && m.faces.length == rigFaces.length,
            format("case %s: rebuilt rig must match the captured one "
                 ~ "(%d verts / %d edges / %d faces); got %d/%d/%d",
                   c.id, verts.length, kRigEdgeCount, rigFaces.length,
                   m.vertices.length, m.edges.length, m.faces.length));

        auto topo = TopologyPenTool.buildRelaxTopology(&m);
        assert(topo.valid(m.vertices.length), "extracted topology must be self-consistent");

        // Seed from `m.vertices`, NOT from the fixture's own doubles — this
        // is the float→double widening `applySmoothPasses` itself performs,
        // so the gate covers that step instead of bypassing it. Bit-identical
        // either way today (every captured coordinate is float-exact), which
        // is precisely why seeding from the rig would silently leave the
        // conversion untested.
        auto pos = new RelaxVec3[](verts.length);
        foreach (i; 0 .. m.vertices.length)
            pos[i] = RelaxVec3(m.vertices[i].x, m.vertices[i].y, m.vertices[i].z);

        relaxPasses(pos, topo, c.strength / 20.0, c.iters);

        double worst = 0;
        size_t worstAt = 0;
        foreach (i; 0 .. verts.length) {
            auto e = c.expect[i];
            auto d = RelaxVec3(pos[i].x - e[0], pos[i].y - e[1], pos[i].z - e[2]).length();
            if (d > worst) { worst = d; worstAt = i; }
        }
        report ~= format("\n    %-28s strength=%-4g iters=%-3d worst=%.4e at v%d",
                         c.id, c.strength, c.iters, worst, worstAt);
        if (worst > overallWorst) overallWorst = worst;

        // Guard against a vacuous pass: the rig must genuinely move, or the
        // comparison above would be satisfied by doing nothing at all.
        double moved = 0;
        foreach (i; 0 .. verts.length)
            moved += RelaxVec3(pos[i].x - verts[i][0], pos[i].y - verts[i][1],
                               pos[i].z - verts[i][2]).length();
        assert(moved > 1e-6, format("case %s: the rig must actually relax", c.id));
    }

    assert(overallWorst < 1e-9,
        format("the Smooth kernel must reproduce every captured reference relaxation target "
             ~ "to 1e-9 (a correct port lands near 1e-16); worst over all %d cases = %.4e%s",
               cases.length, overallWorst, report));
}

// ---------------------------------------------------------------------------
// smoothPassesForDragDx — the MEASURED pass-count law (task 0490):
//
//     N = max(1, 1 + (xCurrent - xPress) / 5)
//
// x-only, SIGNED, truncating toward zero, floored at 1 and capped at the
// runaway backstop. Pinned as a table so the three separable claims are each
// asserted on their own row: the stride is 5px (not 20), the direction is
// signed (leftward lowers the count to its floor instead of raising it), and
// the cap sits far outside the working range.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;

    static struct PassCase { int dx; int want; string why; }
    static immutable PassCase[] cases = [
        PassCase(    0,   1, "a press with no horizontal travel is exactly one pass"),
        PassCase(    1,   1, "sub-stride travel cannot add a pass"),
        PassCase(    4,   1, "still inside the first 5px stride"),
        PassCase(    5,   2, "the first full stride adds the second pass"),
        PassCase(    9,   2, "the second stride is not complete yet"),
        PassCase(   10,   3, "one extra pass per 5px, exactly"),
        PassCase(   40,   9, "the stride is 5px, not 20: a 40px drag is 9 passes"),
        PassCase(  100,  21, "and a 100px drag is 21, not 6"),
        PassCase( 1275, 256, "the runaway cap is first reached only at +1275px"),
        PassCase( 5000, 256, "and clamps there, never above"),
        PassCase(   -1,   1, "leftward travel floors at 1 — never 0, never negative"),
        PassCase(   -5,   1, "one stride left of the press column is still one pass"),
        PassCase( -100,   1, "and so is a long leftward drag: distance alone adds nothing"),
    ];

    foreach (c; cases) {
        int got = TopologyPenTool.smoothPassesForDragDx(c.dx);
        assert(got == c.want,
            format("dx=%+d must give %d pass(es) — %s; got %d", c.dx, c.want, c.why, got));
    }
}

// ---------------------------------------------------------------------------
// The Smooth gesture FEEDS that law with the right quantity (task 0490):
// the signed horizontal offset of the live cursor from THIS press pixel —
// so vertical motion contributes nothing at all, the accumulated path is
// never consulted (an out-and-back ends where it started, at one pass), and
// nothing survives into the next press. Driven through the REAL dispatch
// (`onMouseButtonDown`/`onMouseMotion`/`onMouseButtonUp`) and observed
// through the same `/api/tool/state` field a Tier-C test reads.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)(KMOD_SHIFT | KMOD_CTRL));
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Mesh m    = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = view.viewport();
    VectorStack vts;
    vts.put(&subj);

    // `history_`/`smoothEditFactory_` are deliberately left null: this case is
    // about the COUNT the gesture derives, so the release must not mutate the
    // mesh (`applySmoothPasses` returns immediately without them).
    enum int px = 100, py = 100;

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_LEFT;
    eDown.x = px; eDown.y = py;
    assert(t.onMouseButtonDown(eDown, vts), "Shift+Ctrl+LMB must be consumed by the real dispatch");
    assert(t.smoothArmed_, "Shift+Ctrl+LMB must arm the whole-mesh Smooth gesture");
    assert(cast(int)t.toolStateJson()["smoothPassCount"].integer == 1,
        "a stationary armed press must report exactly one pass");

    int passesAt(int x, int y) {
        SDL_MouseMotionEvent e;
        e.x = x; e.y = y;
        assert(t.onMouseMotion(e, vts), "motion while Smooth is armed must be consumed");
        return cast(int)t.toolStateJson()["smoothPassCount"].integer;
    }

    // Pure VERTICAL motion: 300px straight down is still the click's one pass.
    assert(passesAt(px, py + 300) == 1,
        format("pure vertical motion must contribute NO passes; got %d", passesAt(px, py + 300)));

    // Horizontal offset is the whole input — and the same offset gives the
    // same count whatever y does.
    assert(passesAt(px + 40, py + 300) == 9, "a +40px horizontal offset is 9 passes");
    assert(passesAt(px + 40, py) == 9, "the count must not depend on y at all");

    // Left of the press column: floored at 1, and the ~400px of path already
    // walked to get here contributes nothing.
    assert(passesAt(px - 40, py) == 1,
        format("a cursor left of the press column must floor at one pass; got %d",
               passesAt(px - 40, py)));

    // Out and back: rising on the way out, and back to a single pass once the
    // cursor returns to the press column — the count follows the CURRENT
    // offset, never the distance travelled.
    assert(passesAt(px + 100, py) == 21, "a +100px offset is 21 passes");
    assert(passesAt(px, py) == 1, "returning to the press column returns to one pass");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_LEFT;
    eUp.x = px; eUp.y = py;
    assert(t.onMouseButtonUp(eUp, vts), "LMB-up must be consumed");
    assert(!t.smoothArmed_, "release must disarm Smooth");

    // A fresh press re-anchors: the offset is measured from the NEW press
    // pixel, so nothing accumulates across gestures.
    SDL_MouseButtonEvent eDown2;
    eDown2.button = SDL_BUTTON_LEFT;
    eDown2.x = px + 500; eDown2.y = py;
    assert(t.onMouseButtonDown(eDown2, vts), "a second Shift+Ctrl+LMB press must arm again");
    assert(cast(int)t.toolStateJson()["smoothPassCount"].integer == 1,
        "a fresh press must start over at one pass — the count never survives a gesture");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
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
// applySmoothPasses — LOW STRENGTH x SMALL EDGES must still produce a
// visible, undoable change (review SHOULD-FIX: the no-op guard was an
// ABSOLUTE 1e-4 world-unit threshold).
//
// This pins the exact combination that used to be swallowed. Smooth's
// displacement is not drag-proportional — it scales with mesh size and with
// `smoothStrength` — so a fixed threshold creates a silent cliff below which
// the whole gesture is discarded: mesh restored, no undo entry, no feedback.
// The rig is an irregular hexahedron with 0.07-unit edges (ordinary
// detail-modelling scale, and the spacing of the reference capture rig) at
// strength 0.05, which is legal and well inside the Param's own [0, 4].
//
// The middle assertion is the one that makes this a REGRESSION test rather
// than a generic smoke test: it asserts the movement is genuinely BELOW the
// old 1e-4 constant. So the rig provably lands in the swallowed band, and
// this test would fail against the previous guard rather than passing for
// unrelated reasons. `gpu_` stays null, so `refreshDisplay` is never reached
// — safe under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null);   // no background — isolate pure relaxation

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    // Irregular hexahedron (one corner pulled out so it is NOT a fixed point
    // of the relaxation law), scaled to 0.07-unit edges.
    enum float s = 0.035f;
    Mesh m;
    t.meshSrc_ = () => &m;
    foreach (p; [Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(1, 1, -1), Vec3(-1, 1, -1),
                 Vec3(-1, -1,  1), Vec3(1, -1,  1), Vec3(1.8, 1.3, 1.1), Vec3(-1, 1, 1)])
        m.addVertex(p * s);
    m.addFace([0u, 3u, 2u, 1u]);  m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([0u, 1u, 5u, 4u]);  m.addFace([2u, 3u, 7u, 6u]);
    m.addFace([1u, 2u, 6u, 5u]);  m.addFace([0u, 4u, 7u, 3u]);
    m.buildLoops();

    t.smoothStrength_ = 0.05f;   // legal, inside the Param's declared [0, 4]

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);      // one click == one iteration

    float maxDisp = 0;
    foreach (i; 0 .. m.vertices.length) {
        immutable float d = (m.vertices[i] - before.vertices[i]).length;
        if (d > maxDisp) maxDisp = d;
    }

    assert(maxDisp > 0,
        "setup: an irregular mesh must genuinely relax — a regular one is an exact fixed "
      ~ "point of this law and would make the assertions below vacuous");
    assert(maxDisp < 1e-4f,
        format("setup: this rig must land in the band the OLD absolute 1e-4 guard swallowed, "
             ~ "or it is not testing the regression; maxDisp=%.4e", maxDisp));
    assert(history.canUndo(),
        format("a low-strength gesture on a small-scale mesh must still be recorded as a real, "
             ~ "undoable edit — the no-op threshold must scale with the model, not sit at a "
             ~ "fixed world-unit constant (maxDisp=%.4e)", maxDisp));

    // ...and the movement must have SURVIVED, not been rolled back by the
    // guard: `before.restore` on the no-op path would leave these identical.
    bool anyMoved = false;
    foreach (i; 0 .. m.vertices.length)
        if (m.vertices[i] != before.vertices[i]) { anyMoved = true; break; }
    assert(anyMoved,
        "the relaxed positions must remain in the mesh — a swallowed gesture restores "
      ~ "`before` and leaves every vertex byte-identical");
}

// ---------------------------------------------------------------------------
// buildRelaxTopology — boundary-restriction coverage (review NIT-4, carried
// forward to the current kernel): the conformance fixture above pins the
// restriction NUMERICALLY (dropping it costs 4.3e-02 there), but only as one
// term inside a whole-mesh result. This isolates the extraction itself on a
// rig where boundary vertex `v0` has BOTH kinds of neighbor at once:
// `v1`/`v3` via open (single-face) edges, `v2` via the edge shared by both
// triangles. A regression that dropped the exclusion would still reproduce
// every other structural property and fail here.
//
// Asserted against `buildRelaxTopology`'s OWN output — the per-slot `openTo`
// flags and the derived per-vertex `boundary` flag — rather than against a
// relaxed position, so the failure points at the extraction rather than at
// the arithmetic downstream of it.
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

    auto topo = TopologyPenTool.buildRelaxTopology(&m);
    assert(topo.valid(m.vertices.length), "extracted topology must be self-consistent");
    assert(topo.boundary[v0],
        "v0 has open incident edges — the derived boundary flag must be set, which is what "
      ~ "restricts its relaxation neighbor set");

    // The restriction that flag triggers: exactly v1 and v3 survive for v0,
    // and the interior neighbor v2 is excluded.
    bool sawV1, sawV2, sawV3;
    foreach (k; topo.offset[v0] .. topo.offset[v0 + 1]) {
        immutable uint nb = topo.nbrs[k];
        if (nb == v1) { sawV1 = true; assert(topo.openTo[k], "v0-v1 is a single-face edge — must be OPEN"); }
        if (nb == v3) { sawV3 = true; assert(topo.openTo[k], "v0-v3 is a single-face edge — must be OPEN"); }
        if (nb == v2) {
            sawV2 = true;
            assert(!topo.openTo[k],
                format("v0-v2 is shared by both faces — it must NOT be flagged open, or the "
                     ~ "interior neighbor leaks into boundary vertex v0's relaxation set"));
        }
    }
    assert(sawV1 && sawV2 && sawV3, "setup: v0's CSR ring must contain all three neighbors");

    // v2 itself is also a boundary vertex here (its v2-v1 / v2-v3 rim edges
    // are single-face), so the flag is not vacuously true for v0 alone.
    assert(topo.boundary[v1] && topo.boundary[v2] && topo.boundary[v3],
        "every vertex of this two-triangle patch sits on the rim");
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
// commitSplit — T6 (task 0489): the split LAW as it was measured live, rather
// than as it was reasoned about.
//
// Two chord cells committed under instrumentation with every gate value read
// out of the reference engine on the way through, and both produced the same
// three-part signature:
//
//     Δ(V,E,F) = (0, +1, +1),  max|dp| = 0,  exactly ONE undo restores both
//     the counts and the positions.
//
// The vertex count is the load-bearing third of that: a chord split adds no
// vertex, so a kernel that ever grew `vertices` would be wrong even with the
// right face count. `max|dp| = 0` is the fourth: a split never moves geometry.
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
    // the measured rig: a regular hexagon, one polygon
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    const size_t v0 = m.vertices.length, e0 = m.edges.length, f0 = m.faces.length;

    t.commitSplit(0, 2);   // the measured cell: press v0, release v2

    assert(m.vertices.length == v0, "measured law: a chord split is Δv = 0");
    assert(m.edges.length == e0 + 1, "measured law: a chord split is Δe = +1");
    assert(m.faces.length == f0 + 1, "measured law: a chord split is Δf = +1");

    // no vertex moves — measured as max|dp| = 0 on every committing cell
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices[0 .. v0] == before.vertices[0 .. v0],
        "measured law: a chord split never moves existing geometry");

    // ONE undo restores counts AND positions (measured: undo_steps == 1)
    assert(history.canUndo(), "a real split records exactly one undo entry");
    history.undo();
    assert(m.vertices.length == v0 && m.edges.length == e0
        && m.faces.length == f0,
        "measured law: ONE undo restores the counts");
    assert(MeshSnapshot.capture(m).vertices == before.vertices,
        "measured law: ONE undo restores the positions");
    assert(!history.canUndo(), "the split must be ONE undo entry, not two");
}

// ---------------------------------------------------------------------------
// commitSplit — T7 (task 0489): the GATE EQUIVALENCE, proven exhaustively
// instead of argued in a comment.
//
// The reference refuses a chord through four separate tests. Three of them are
// redundant: with `n1 = ((j - i) mod n) + 1` and `n2 = n - n1 + 2`, the pair
// `n1 >= 3 && n2 >= 3` is equivalent to `2 <= (j - i) mod n <= n - 2`, which is
// exactly "distinct, and not neighbours around the ring"; the `|i - j| >= 2`
// test is strictly implied by it, and the `n >= 4` test is implied for a
// triangle. So the whole law is ONE clause, and it is the clause
// `findCommonSplitFace` already spells as `adjacent`.
//
// This asserts that equality over every polygon size and every ordered pair,
// so the claim stops depending on anyone re-reading the argument.
// ---------------------------------------------------------------------------
unittest {
    foreach (n; 3 .. 13) {
        foreach (i; 0 .. n) {
            foreach (j; 0 .. n) {
                // our clause, written exactly as findCommonSplitFace has it
                const int lo = i < j ? i : j;
                const int hi = i < j ? j : i;
                const bool ours = !(i == j)
                    && !((hi == lo + 1) || (lo == 0 && hi == n - 1));

                // the reference's four tests, in its own arithmetic
                const int n1 = ((j - i) % n + n) % n + 1;
                const int n2 = n - n1 + 2;
                const bool theirs = (n >= 4)
                    && (i > j ? i - j : j - i) >= 2
                    && n1 >= 3 && n2 >= 3;

                assert(ours == theirs,
                    "gate equivalence broken: our adjacency reject and the "
                    ~ "reference's four gates must accept exactly the same "
                    ~ "(polygon size, corner pair) set");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// commitSplit — T8 (task 0489): divergence D1, the NON-MANIFOLD fork.
//
// MEASURED: on a rig where the same vertex pair is a legal chord of one
// incident polygon and an illegal one of another, the reference resolves
// EXACTLY ONE candidate, finds it unsuitable, and abandons the split — it does
// not try the other polygon. Δ = (0,0,0), with the engine printing
// `nverts = 3` for the candidate it picked.
//
// vibe3d deliberately does the opposite: `findCommonSplitFace` walks the
// pressed vertex's faces and `continue`s past a failing candidate to the next
// one, so it finds the quad and cuts. The retry is defended on purpose by the
// REV1 FIX-3 comment above that function.
//
// This test pins OUR behaviour and NAMES it as the measured divergence, so the
// day someone decides to match the reference this assertion is the thing that
// tells them the change is intentional rather than a regression.
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
    m.addVertex(Vec3(1, -1, 0));   // 0
    m.addVertex(Vec3(-1, -1, 0));  // 1
    m.addVertex(Vec3(-1, 1, 0));   // 2
    m.addVertex(Vec3(1, 1, 0));    // 3
    m.addFace([0u, 1u, 2u]);       // the triangle: (0,2) is ADJACENT here
    m.addFace([0u, 1u, 2u, 3u]);   // the quad:     (0,2) is a legal chord here
    m.buildLoops();

    const size_t f0 = m.faces.length;
    t.commitSplit(0, 2);

    // DIVERGENCE D1, deliberate and now measured: the reference refuses here
    // (one candidate, no retry); we retry and cut.
    assert(m.faces.length == f0 + 1,
        "D1: vibe3d retries past the unsuitable candidate and splits the quad "
        ~ "-- the reference resolves one candidate and refuses. If this "
        ~ "assertion is being changed, the change is a deliberate move TOWARD "
        ~ "the reference, not a regression.");
    assert(m.vertices.length == 4, "D1: the split still adds no vertex");
}

// ---------------------------------------------------------------------------
// commitSplit — T9 (task 0489): divergence D2, WHICH HALF KEEPS THE PARENT
// POLYGON'S SLOT.
//
// MEASURED, on the one case shape that can tell the two conventions apart —
// a chord whose PRESS index is the HIGHER winding index. The reference keeps
// the arc running from the PRESSED vertex forward to the RELEASED one in the
// parent's slot, and appends the mirror arc as the new polygon. vibe3d's
// `rebuildFacesWithChordSplits` takes `f1 = face[i .. j+1]` with `i` the LOWER
// winding index regardless of which end was pressed, so the two halves are
// SWAPPED whenever `idx(press) > idx(release)`.
//
// The counts are identical either way, which is why this went unnoticed: only
// the face identity differs, and today both halves inherit the same per-face
// attributes, so the divergence is visible only through the facet index and
// anything keyed on it.
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
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    // REVERSED chord: press v3, release v0 -> idx(press) 3 > idx(release) 0
    t.commitSplit(3, 0);
    assert(m.faces.length == 2 && m.edges.length == 7 && m.vertices.length == 6,
        "D2 setup: the reversed chord must still split (0,+1,+1)");

    // OUR convention: the parent slot (face index 0) keeps the LOW-index arc.
    assert(m.faces[0][] == [0u, 1u, 2u, 3u],
        "D2: vibe3d keeps the LOW-index arc in the parent slot. MEASURED, the "
        ~ "reference keeps the arc from the PRESSED vertex ([3,4,5,0] here) "
        ~ "and appends [0,1,2,3]. The halves are swapped whenever the press "
        ~ "index is the higher one. Changing this assertion to [3,4,5,0] is "
        ~ "the fix that closes D2 -- it is an owner call because it moves a "
        ~ "shipped facet index.");
    assert(m.faces[1][] == [3u, 4u, 5u, 0u],
        "D2: and the new polygon is the other arc");

    // the FORWARD chord is where the two conventions agree -- kept here so the
    // test itself documents why a forward-chord case can never discriminate
    Mesh m2;
    t.meshSrc_ = () => &m2;
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m2.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m2.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m2.buildLoops();
    t.commitSplit(0, 3);
    assert(m2.faces[0][] == [0u, 1u, 2u, 3u],
        "D2 control: on a FORWARD chord both conventions give the same parent "
        ~ "slot, which is why every earlier case was blind to the difference");
}

// ---------------------------------------------------------------------------
// commitSplit — T5 (P9, doc/topopen_p9_split_plan.md §Testing): a release
// that does not land on a vertex (C == -1) must be a byte-identical no-op.
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
// resnapToBackground — TASK 0503, THE MEASURED LAW ON A TILTED BACKGROUND.
//
// This is the fixture the law needs. On a background PARALLEL to the plane
// the drag resolves on, the per-vertex correction is the IDENTITY, which is
// why four earlier captures (every one of them on a parallel background)
// could not see the difference between the camera ray this tool used to cast
// and the nearest foot the reference actually takes. The rig here is cell A's
// own construction: the source edge runs SCREEN-HORIZONTALLY, the background
// is tilted about the SCREEN-VERTICAL axis, so the two source vertices sit at
// different depths on it.
//
// Three scored invariants, all computed here from scratch, never by a second
// call into the code under test:
//
//   (a) each target lies ON the background plane (the capture's own
//       `d(new, bg)` channel: 6.8e-10 … 8.4e-9);
//   (b) |new edge| / |source edge| == cos(tilt) at 30/45/60 degrees — the
//       capture measured 0.866025692 / 0.707106741 / 0.500000075 against
//       cos to 2.9e-7. A per-vertex CAMERA RAY predicts 1.804 / 2.484 /
//       4.369 on the same three cells, and every rigid law predicts 1.000,
//       so this single number refutes both by 0.94-3.87 and 0.13-0.50;
//   (c) each target equals the independently-derived PERPENDICULAR FOOT of
//       its own source vertex — which refutes anchor-plus-rigid a second
//       way (a rigid rest gives both vertices the same displacement; the
//       capture measured a 4.8x spread inside one evaluation).
//
// Tolerances: the query pixel is an INT (`cast(int)` in the callers, `+0.5f`
// pixel centre inside), so the query point carries up to ~1px of world
// wobble — 0.0124 world units on this camera. Both bands below are set well
// above that and still an order of magnitude under every refuted rival.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import math : normalize, cross;
    import snap : setBackgroundSnapSources;
    import std.math : abs, cos, sin, PI;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null);

    // Camera basis straight off the view matrix (column-major m[row+col*4]),
    // so the rig is stated in SCREEN terms exactly like the capture's was.
    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f;   // source depth = this View's own default distance
    enum float L = 2.0f;   // source edge length, screen-horizontal
    Vec3 srcMid = vp.eye + camFwd * D;
    Vec3 v0 = srcMid - camRight * (L * 0.5f);
    Vec3 v1 = srcMid + camRight * (L * 0.5f);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(v0, vp, p0)
        && TopologyPenTool.projectPt(v1, vp, p1),
        "setup: both source verts must project on-screen");

    foreach (degrees; [30.0f, 45.0f, 60.0f]) {
        immutable float th = degrees * cast(float)PI / 180.0f;

        // Tilt about the screen-vertical axis; place the facet 0.22 D behind
        // the source plane (cell A's own separation).
        Vec3 n     = normalize(camFwd * cos(th) + camRight * sin(th));
        Vec3 bgPt  = vp.eye + camFwd * (D * 1.22f);
        Vec3 inU   = normalize(cross(n, camUp));
        Vec3 inW   = normalize(cross(n, inU));
        enum float H = 40.0f;   // large enough that no foot is ever clamped here

        auto bg = new Mesh();
        bg.vertices = [bgPt - inU * H - inW * H, bgPt + inU * H - inW * H,
                       bgPt + inU * H + inW * H, bgPt - inU * H + inW * H];
        bg.faces    = [[0u, 1u, 2u, 3u]];
        const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
        setBackgroundSnapSources(srcs);

        Vec3 got0, got1;
        assert(t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, got0),
            format("tilt %.0f: v0 must re-snap onto the background", degrees));
        assert(t.resnapToBackground(v1, cast(int)p1.x, cast(int)p1.y, vp, got1),
            format("tilt %.0f: v1 must re-snap onto the background", degrees));

        // (a) ON the background plane.
        assert(abs(dot(got0 - bgPt, n)) < 1e-4f && abs(dot(got1 - bgPt, n)) < 1e-4f,
            format("tilt %.0f: both targets must lie ON the background plane; "
                 ~ "d0=%g d1=%g", degrees, dot(got0 - bgPt, n), dot(got1 - bgPt, n)));

        // (b) the capture's scored invariant.
        immutable float ratio = (got1 - got0).length / L;
        assert(abs(ratio - cos(th)) < 0.02f,
            format("tilt %.0f: |new|/|src| must be cos(tilt)=%.6f (a camera-ray re-snap "
                 ~ "gives ~1.8/2.5/4.4, every rigid law gives 1.000); got %.6f",
                   degrees, cos(th), ratio));

        // (c) the perpendicular foot, per vertex, derived here.
        Vec3 foot0 = v0 - n * dot(v0 - bgPt, n);
        Vec3 foot1 = v1 - n * dot(v1 - bgPt, n);
        assert((got0 - foot0).length < 0.05f && (got1 - foot1).length < 0.05f,
            format("tilt %.0f: each target must be its OWN source vertex's perpendicular "
                 ~ "foot; got %s/%s expected %s/%s", degrees, got0, got1, foot0, foot1));
    }

    // No background at all -> must report a miss cleanly, and the callers'
    // keep-the-original policy then leaves the gesture a rigid translate
    // (cell A2-NOBG: the duplicate is still created and moved rigidly).
    setBackgroundSnapSources(null);
    Vec3 gotNone;
    assert(!t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, gotNone),
        "resnapToBackground must return false with no background source at all");
}

// ---------------------------------------------------------------------------
// resnapToBackground — TASK 0503, THE SAME LAW ON A FLAT BACKGROUND.
//
// Cell A0-FLAT exists because the divergence is NOT an exotic-background
// corner case: on the flat background every earlier cell in this campaign
// used, the reference measured |new|/|src| = 0.999999851 while a camera-ray
// re-snap onto a plane 0.22 D behind the source plane scales the edge by
// exactly that depth ratio — 1.220. This fixture reproduces those two
// numbers, so the ray law is refuted by 0.22 on the friendliest possible
// geometry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null);

    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f, L = 2.0f;
    Vec3 srcMid = vp.eye + camFwd * D;
    Vec3 v0 = srcMid - camRight * (L * 0.5f);
    Vec3 v1 = srcMid + camRight * (L * 0.5f);

    Vec3 bgPt = vp.eye + camFwd * (D * 1.22f);   // parallel to the image plane
    enum float H = 40.0f;
    auto bg = new Mesh();
    bg.vertices = [bgPt - camRight * H - camUp * H, bgPt + camRight * H - camUp * H,
                   bgPt + camRight * H + camUp * H, bgPt - camRight * H + camUp * H];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(v0, vp, p0)
        && TopologyPenTool.projectPt(v1, vp, p1), "setup: both verts must project on-screen");

    Vec3 got0, got1;
    assert(t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, got0));
    assert(t.resnapToBackground(v1, cast(int)p1.x, cast(int)p1.y, vp, got1));

    immutable float ratio = (got1 - got0).length / L;
    assert(abs(ratio - 1.0f) < 0.02f,
        format("on a flat background the edge length must be PRESERVED (reference 1.000); "
             ~ "a camera-ray re-snap onto a plane 0.22 D behind scales it to 1.220; got %.6f",
               ratio));

    // And the displacement is a PURE depth shift: no lateral component (the
    // ray law spreads the pair apart by 0.22*L/2 = 0.22 per vertex).
    assert(abs(dot(got0 - v0, camRight)) < 0.05f && abs(dot(got1 - v1, camRight)) < 0.05f,
        format("the flat-background correction must be perpendicular (no lateral slide); "
             ~ "got %g / %g", dot(got0 - v0, camRight), dot(got1 - v1, camRight)));
}

// ---------------------------------------------------------------------------
// perVertexTargets — SHIFT + THE MISS POLICY AFTER TASK 0503.
//
// A shared screen-delta is still applied to EACH vertex's own screen
// projection before re-snapping (the shared-3D-offset shape the reference
// uses is recorded as an open divergence — see `shiftedWorldPoint`). What
// changed is what a vertex pointing at empty space does: a camera ray MISSED
// and the vertex kept its original position; a nearest-foot query over a
// bounded facet does not miss, it CLAMPS to the facet edge. That clamp is
// measured — cell A3-CLIP shortened the background so both feet fell past
// its edge and both new vertices landed exactly on the cut (beta = -0.30000),
// which refutes "keep the original" (they had moved 0.913 and 0.943), "fall
// back to the drag plane" and "refuse the gesture" in one row.
//
// So this pins BOTH halves: a vertex over the patch lands on it, a vertex far
// outside the patch's footprint lands on the patch BOUNDARY (not back at its
// original position), and the keep-the-original branch survives only for the
// no-background case.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null);

    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f;
    Vec3 vA = vp.eye + camFwd * D;                        // on the patch's axis
    Vec3 vB = vA + camRight * 4.0f;                       // far outside its footprint

    Mesh m;
    m.addVertex(vA);
    m.addVertex(vB);
    t.meshSrc_ = () => &m;

    // A SMALL patch, parallel to the image plane, 0.5 behind vA.
    Vec3 bgPt = vA + camFwd * 0.5f;
    enum float half = 0.6f;
    auto bg = new Mesh();
    bg.vertices = [bgPt - camRight * half - camUp * half, bgPt + camRight * half - camUp * half,
                   bgPt + camRight * half + camUp * half, bgPt - camRight * half + camUp * half];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    setBackgroundSnapSources(srcs);

    auto targets = t.perVertexTargets([0u, 1u], 0, 0, vp);
    assert(targets.length == 2);

    // vA: straight onto the patch, a pure depth shift.
    assert(abs(dot(targets[0] - bgPt, camFwd)) < 1e-4f
        && abs(dot(targets[0] - vA, camRight)) < 0.05f,
        format("vA must land ON the patch, perpendicular to it; got %s", targets[0]));

    // vB: CLAMPED to the patch's own boundary, NOT left where it started.
    assert((targets[1] - vB).length > 1.0f,
        format("vB must NOT keep its original position — a nearest-foot query clamps to the "
             ~ "facet instead of missing (cell A3-CLIP); got %s vs original %s",
               targets[1], vB));
    assert(abs(dot(targets[1] - bgPt, camFwd)) < 1e-4f,
        "vB's clamped target must still lie in the patch's own plane");
    assert(abs(abs(dot(targets[1] - bgPt, camRight)) - half) < 1e-4f,
        format("vB must land exactly on the patch's near EDGE (|lateral| == %.2f); got %g",
               half, dot(targets[1] - bgPt, camRight)));

    // With NO background at all, both keep their exact original positions.
    setBackgroundSnapSources(null);
    auto none = t.perVertexTargets([0u, 1u], 0, 0, vp);
    assert((none[0] - vA).length < 1e-6f && (none[1] - vB).length < 1e-6f,
        "with no background source the keep-the-original branch must still hold");
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
// `PenGesture.MoveLoop` -> `onMoveLoopRmbDown`), a motion event, and the
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
// onShiftLmbDown on an EDGE -> arms the single-edge DUPLICATE, not a build
// (task 0485). The reference's Duplicate mode "duplicates an edge as you drag
// it", widening to a loop only under Edge Loop / the right mouse button — so
// this slot has two outcomes, resolved by what the press lands on, and the
// vertex outcome (P3's drag-build) must keep working untouched.
//
// A stationary Shift+click duplicates nothing: same click-vs-drag gate as
// every other gesture here. Driven directly — the no-drag path returns before
// any `gpu_`/GL tail, so it runs under a bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    // Task 0496: the grid-plane viewport (80px per grid cell), not the 100x100
    // `View` default this case used to build. Under that tiny viewport a grid
    // half-edge projected to ~13px, which the pen's press-pick reach could
    // swallow, so the "midpoint resolves no vertex" precondition below could no
    // longer hold. The precondition is the point of the case; the viewport was
    // incidental. Asserted below, so the reach can move again without this
    // case silently turning into a different test.
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[0][0]], vp, p0), "setup: endpoint projects");
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[0][1]], vp, p1), "setup: endpoint projects");

    // --- EDGE midpoint: no vertex within snap range, so the edge outcome.
    SDL_MouseButtonEvent eEdge;
    eEdge.x = cast(int)((p0.x + p1.x) * 0.5f);
    eEdge.y = cast(int)((p0.y + p1.y) * 0.5f);
    assert(t.findSourceVertex(eEdge.x, eEdge.y, vp) < 0,
        "setup: the midpoint must resolve NO vertex, or this would test the build path");
    immutable int seed = t.findRingSeedEdge(eEdge.x, eEdge.y, vp);
    assert(seed >= 0, "setup: the midpoint must resolve an edge");

    assert(t.onShiftLmbDown(eEdge, vts), "a Shift+LMB press on an edge must be consumed");
    assert(t.dupEdgeArmed_, "it must arm the single-edge duplicate");
    assert(t.dupEdgeSeed_ == seed, "and arm it on the edge the pick resolved");
    assert(!t.dragArmed_, "it must NOT arm P3's vertex drag-build");
    assert(t.anyGestureArmed(), "the new arm must be visible to anyGestureArmed()");

    // A release back at the press pixel is a click, not a drag: no mutation.
    immutable size_t vBefore = m.vertices.length, fBefore = m.faces.length;
    assert(t.buildUp(eEdge, vts), "the release of an armed gesture is consumed");
    assert(!t.dupEdgeArmed_, "the release must disarm");
    assert(m.vertices.length == vBefore && m.faces.length == fBefore,
        "a stationary Shift+click on an edge must duplicate nothing");

    // --- VERTEX: P3's drag-build still owns that outcome, unchanged.
    t.resetAllGestureArms();
    SDL_MouseButtonEvent eVert;
    eVert.x = cast(int)p0.x; eVert.y = cast(int)p0.y;
    assert(t.onShiftLmbDown(eVert, vts), "a Shift+LMB press on a vertex must still be consumed");
    assert(t.dragArmed_, "a vertex press must still arm the drag-build");
    assert(!t.dupEdgeArmed_, "a vertex press must NOT arm the edge duplicate");

    // --- Neither: still declined, so a Shift+LMB on empty space falls through
    // to the host's own sel-add path exactly as before.
    t.resetAllGestureArms();
    SDL_MouseButtonEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    assert(!t.onShiftLmbDown(eFar, vts), "a press on nothing must stay unconsumed");
    assert(!t.dragArmed_ && !t.dupEdgeArmed_, "and must arm neither outcome");
}

// ---------------------------------------------------------------------------
// The BORDER GATE on Duplicate (task 0486, contract C-0) — the finding that
// re-scoped the whole capture. The reference's Evaluate guards Duplicate on
// `isEdgeBorder(pressed edge)`; when it fails it silently runs MOVE. So an
// interior-edge press through the Duplicate slot is neither a duplicate NOR a
// declined press: Shift+LMB there is a 2-vertex element move, Shift+RMB there
// is a move-loop.
//
// `makeGridPlane(3)` carries both sides of the gate: its rim edges are border
// edges (one incident face) and its inner edges are not (two).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;
    auto vp = makeGridPlaneTestViewport();

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Find one border edge and one interior edge, and the pixel at each midpoint.
    int borderEdge = -1, interiorEdge = -1;
    foreach (ei; 0 .. cast(int)m.edges.length) {
        if (m.isEdgeBorder(cast(uint) ei)) { if (borderEdge < 0) borderEdge = ei; }
        else if (interiorEdge < 0) interiorEdge = ei;
    }
    assert(borderEdge >= 0 && interiorEdge >= 0,
        "setup: a 3x3 grid must carry both a border and an interior edge");

    SDL_MouseButtonEvent pixOf(int ei) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectPt(m.vertices[m.edges[ei][0]], vp, pa));
        assert(TopologyPenTool.projectPt(m.vertices[m.edges[ei][1]], vp, pb));
        SDL_MouseButtonEvent ev;
        ev.x = cast(int)((pa.x + pb.x) * 0.5f);
        ev.y = cast(int)((pa.y + pb.y) * 0.5f);
        return ev;
    }

    // --- BORDER side: Shift+LMB duplicates.
    auto eB = pixOf(borderEdge);
    assert(t.findSourceVertex(eB.x, eB.y, vp) < 0,
        "setup: the border midpoint must resolve no vertex, or this tests the vertex outcome");
    assert(t.onShiftLmbDown(eB, vts), "Shift+LMB on a BORDER edge must be consumed");
    assert(t.dupEdgeArmed_, "a border seed must arm the DUPLICATE");
    assert(!t.moveArmed_, "and must not arm a move");

    // --- INTERIOR side, same chord: falls through to a 2-vertex MOVE.
    t.resetAllGestureArms();
    auto eI = pixOf(interiorEdge);
    if (t.findSourceVertex(eI.x, eI.y, vp) < 0 && t.findRingSeedEdge(eI.x, eI.y, vp) == interiorEdge) {
        assert(t.onShiftLmbDown(eI, vts), "Shift+LMB on an INTERIOR edge must still be consumed");
        assert(!t.dupEdgeArmed_,
            "an interior seed must NOT arm a duplicate — the reference gates Duplicate on "
          ~ "isEdgeBorder and silently runs Move instead");
        assert(t.moveArmed_ && t.moveElem_ == MoveElem.Edge,
            "it must arm the EDGE move family instead");
        assert(t.moveVerts_.length == 2,
            format("a 2-vertex move, per the measured interior outcome; got %d",
                   t.moveVerts_.length));

        // The release must reach the MOVE's commit leg, not the build's — the
        // Duplicate slot's UP has to follow where its own DOWN went.
        assert(t.buildUp(eI, vts), "the release after a fall-through must be consumed");
        assert(!t.moveArmed_, "and must disarm the move it actually armed");
    }

    // --- INTERIOR side, Shift+RMB: falls through to a MOVE-LOOP.
    t.resetAllGestureArms();
    if (t.findRingSeedEdge(eI.x, eI.y, vp) == interiorEdge) {
        SDL_MouseButtonEvent eR = eI;
        eR.button = SDL_BUTTON_RIGHT;
        t.onDupLoopShiftRmbDown(eR, vts);
        assert(!t.dupLoopArmed_,
            "Shift+RMB on an interior edge must NOT arm a duplicate-loop");
        assert(t.moveLoopArmed_, "it must arm the MOVE-loop instead");
        assert(t.dupLoopUp(eR, vts),
            "and the release must reach moveLoopUp through the dup-loop UP leg");
    }
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

    // Task 0486 (contract C-4): the armed set is the trimmed border RUN, not
    // the whole gathered rim. `makeGridPlane(2)` is 2x2 quads, so its rim's
    // four CORNER vertices have a single incident polygon each; the walk from
    // seed 0-1 stops at both of them and keeps the top run {0-1, 1-2}. This
    // assertion used to demand all 8 rim edges — which is exactly the
    // owner-reported "it takes all edges", and what the reference does NOT do
    // (measured 12-gathered -> 3-committed on the 4x4 grid; the run length is
    // the number of quads along that side).
    assert(t.dupLoopEdges_.length == 2,
        format("armed set must be the trimmed 2-edge top run, not the whole rim; got %d edges",
               t.dupLoopEdges_.length));
    foreach (ei; t.dupLoopEdges_) {
        assert(m.isEdgeBorder(cast(uint) ei), "every edge in the run must be a border edge");
        auto ep = m.edges[ei];
        assert(ep[0] <= 2 && ep[1] <= 2,
            "the run must stay on the TOP row (vertices 0-2), never turn a corner");
    }

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
// `PenGesture.DupLoop` ->
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
    assert(t.dupLoopEdges_.length == 2,
        "the real dispatch must arm the TRIMMED border run (task 0486 C-4), not the whole rim");

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

    // Task 0486 (contract C-4): the trimmed 2-edge run, not the 8-edge rim.
    // An OPEN run of n edges duplicates to +(n+1) vertices, +(2n+1) edges
    // (n duplicated + n+1 rungs) and +n faces — the same arithmetic the
    // reference was measured at for n=1 (+2/+3/+1) and n=3 (+4/+7/+3). Here
    // n=2, so +3/+5/+2. A CLOSED rim would be +8/+16/+8, which is what this
    // used to assert and what the trim exists to prevent on an open patch.
    assert(m.vertices.length == vBefore + 3 && m.edges.length == eBefore + 5
        && m.faces.length == fBefore + 2,
        format("the real dispatch path must grow by the trimmed 2-edge-run delta "
             ~ "(+3v/+5e/+2f); got (+%d/+%d/+%d)",
               m.vertices.length - vBefore, m.edges.length - eBefore,
               m.faces.length - fBefore));
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
// `PenGesture.SmoothLoop` -> `onSmoothLoopRmbDown`), a motion event (drag-distance
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
// commitSplit — Split Tier-B #1 (the whole of Split): the vertex<->vertex
// chord split — Δv=0, no vertex is ever inserted on this path.
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

    assert(m.vertices.length == 4, "vertex<->vertex split: Δv=0 — Split never creates a vertex");
    assert(m.faces.length    == 2, "vertex<->vertex split: still 2 faces");
    assert(history.canUndo());
}

// ---------------------------------------------------------------------------
// splitUp — Split Tier-B #2 (no-op): release on empty space (no vertex
// within the drag-snap acceptance radius) is a clean no-op — the release must not
// fabricate a target out of nothing.
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
// params() / toolStateJson — Add Loop "at the Middle" option schema
// (doc/tasks/work/0480-topopen-addloop-middle.md): the sticky `middle` Param
// round-trips through both the schema (for the `tool.attr`/form binding) and
// the introspection JSON (for HTTP tests), defaulting OFF, and survives
// `resyncSession()` (a mode toggle, not per-gesture arm state — matches the
// `tool_activate_sticky_clobber` precedent).
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps.length == 11, "mesh.topoPen must expose the Add Loop `middle` option, the Mode "
                          ~ "dropdown, the Edge Loop / Edge Slide flags (task 0483), the Smooth "
                          ~ "strength, the two display toggles (task 0499), the Inner Snap "
                          ~ "flag (task 0496), the Keep Vertices flag (task 0494) and the two "
                          ~ "Fill attributes (task 0488) — every later Param is APPENDED, "
                          ~ "never a full-replace");
    assert(ps[$ - 2].name == "range" && ps[$ - 1].name == "quadOnly",
        "the two Fill attributes must be APPENDED LAST, in that order");
    assert(ps[$ - 2].hints.hasMinF && ps[$ - 2].hints.minF == 0.0f && !ps[$ - 2].hints.hasMaxF,
        "`range`'s bounds are the MEASURED ones: min 0.0 and NO upper bound — not a "
      ~ "sane-looking pair invented at the call site");
    assert(ps[$ - 1].kind == Param.Kind.Bool && ps[$ - 1].default_.b == true,
        "`quadOnly` is the measured boolean count gate, default ON");
    assert(ps[0].name == "middle");
    assert(ps[0].kind == Param.Kind.Bool);
    assert(ps[0].default_.b == false, "`middle` must default OFF — the shipped click-derived "
                                     ~ "Add Loop ratio stays the default behaviour");
    assert(ps[0].bptr is &t.addLoopMiddle_, "the Param must bind directly to addLoopMiddle_");

    auto s0 = t.toolStateJson();
    assert(s0["addLoopMiddle"].type == JSONType.false_, "must start OFF");
    assert("splitAtMiddle" !in s0,
        "the option is no longer attached to Split — the old key must be gone, not aliased");

    t.addLoopMiddle_ = true;
    auto s1 = t.toolStateJson();
    assert(s1["addLoopMiddle"].type == JSONType.true_, "must report a live toggle");

    t.resyncSession();
    assert(t.addLoopMiddle_,
        "addLoopMiddle_ must survive resyncSession() (external history navigation) — it is a "
      ~ "sticky mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// addLoopFrac — the Add Loop insert-fraction LAW
// (doc/tasks/work/0480-topopen-addloop-middle.md):
// `frac = middle ? 0.5 : clamp(cursorRatio, 0, 1)`. Pins both branches
// directly, including the fact that `middle` ignores the cursor ENTIRELY
// (not "clamps it toward 0.5"), and that `addLoopRatio`/`addLoopFrac` in the
// introspection JSON diverge exactly when the option is on.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs, isNaN;

    auto t = new TopologyPenTool();

    // --- option OFF: the click-derived ratio passes through, clamped ---
    assert(abs(t.addLoopFrac(0.3f)  - 0.3f) < 1e-6f, "OFF: the cursor ratio passes through");
    assert(abs(t.addLoopFrac(0.75f) - 0.75f) < 1e-6f);
    assert(abs(t.addLoopFrac(-2.0f) - 0.0f) < 1e-6f, "OFF: below-range clamps to 0");
    assert(abs(t.addLoopFrac(9.0f)  - 1.0f) < 1e-6f, "OFF: above-range clamps to 1");
    assert(abs(t.addLoopFrac(float.nan) - 0.0f) < 1e-6f,
        "OFF: a non-finite ratio must resolve to the rejected 0, never propagate — "
      ~ "commitAddLoop's open-interval guard then no-ops it");

    // --- option ON: a flat 0.5, whatever the cursor says ---
    t.addLoopMiddle_ = true;
    foreach (float r; [0.0f, 0.05f, 0.3f, 0.5f, 0.95f, 1.0f, -3.0f, 7.0f]) {
        assert(abs(t.addLoopFrac(r) - 0.5f) < 1e-6f,
            "ON: `middle` bypasses the cursor entirely — always exactly 0.5");
    }
    assert(!isNaN(t.addLoopFrac(float.nan)) && abs(t.addLoopFrac(float.nan) - 0.5f) < 1e-6f,
        "ON: even a non-finite cursor ratio is bypassed, not propagated");

    // --- the introspection JSON reports BOTH the raw ratio and the law's
    //     output, so a Tier-C test can see the override without a release ---
    t.addLoopRatio_ = 0.8f;
    auto s = t.toolStateJson();
    assert(abs(s["addLoopRatio"].get!double - 0.8) < 1e-6,
        "addLoopRatio must stay the RAW cursor ratio");
    assert(abs(s["addLoopFrac"].get!double - 0.5) < 1e-6,
        "addLoopFrac must report what a release would actually commit");
}

// ---------------------------------------------------------------------------
// params() — Mode dropdown schema (task 0477 continuation + task 0483): the
// `mode` IntEnum Param round-trips through the schema (for the
// `tool.attr`/form binding), carries the reference's OWN eight values in the
// reference's own order under the reference's own wire tags, defaults to the
// live-measured `move`, and survives `resyncSession()` (a sticky mode toggle,
// not per-gesture arm state — matches `addLoopMiddle_`'s own precedent,
// pinned in the schema block above).
//
// The wire-tag list is pinned member-by-member ON PURPOSE: these tags are the
// external contract (`tool.attr mesh.topoPen mode <tag>`, the `/api/tool/state`
// readback, every reference-comparison harness case), so a rename or a
// reordering has to be a deliberate edit here, not a silent side effect.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[1].name == "mode");
    assert(ps[1].kind == Param.Kind.IntEnum);
    assert(ps[1].default_.i == cast(int)PenMode.Move, "mode must default to Move");
    assert(ps[1].iePtr is cast(int*)&t.penMode_, "the Param must bind directly to penMode_");
    assert(ps[1].intEnumValues.length == 8, "the reference's mode enum has exactly 8 values");

    static immutable string[8] wantTags =
        ["move", "duplicate", "remove", "split", "addLoop", "point", "fill", "smooth"];
    static immutable string[8] wantLabels =
        ["Move", "Duplicate", "Remove", "Split", "Add Loop", "Point", "Fill", "Smoothing"];
    foreach (i, want; wantTags) {
        assert(ps[1].intEnumValues[i].wireTag == want,
            "mode entry " ~ want ~ " must keep its reference wire tag and position");
        assert(ps[1].intEnumValues[i].userLabel == wantLabels[i],
            "mode entry " ~ want ~ " must keep its reference label");
        assert(ps[1].intEnumValues[i].value == cast(int)i,
            "the table's values must be the enum's own ordinals, in order");
    }

    assert(t.penMode_ == PenMode.Move, "must start in Move mode");

    t.penMode_ = PenMode.Fill;
    t.resyncSession();
    assert(t.penMode_ == PenMode.Fill,
        "penMode_ must survive resyncSession() (external history navigation) — it is a sticky "
      ~ "mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// params() — Edge Loop / Edge Slide schema (task 0483): the reference's own
// two dropdown-adjacent checkboxes, bound to the fields the router reads,
// both defaulting OFF (live-measured), both sticky across `resyncSession()`
// for the same reason `penMode_` is.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[2].name == "loop"  && ps[2].kind == Param.Kind.Bool);
    assert(ps[3].name == "slide" && ps[3].kind == Param.Kind.Bool);
    assert(ps[2].bptr is &t.edgeLoop_,  "loop must bind directly to edgeLoop_");
    assert(ps[3].bptr is &t.edgeSlide_, "slide must bind directly to edgeSlide_");
    assert(!ps[2].default_.b && !ps[3].default_.b, "both flags default OFF");
    assert(!t.edgeLoop_ && !t.edgeSlide_, "a fresh tool must start with both flags OFF");

    // Inner Snap (task 0496) — the third sticky flag, APPENDED last, default
    // OFF (measured). It selects the pen snap target's candidate set.
    // Index 7, not 5: task 0499's two display toggles were appended first, and the
    // module's rule is APPEND-never-replace — so a merge shifts the index, never the order.
    assert(ps[7].name == "innerSnap" && ps[7].kind == Param.Kind.Bool);
    assert(ps[7].bptr is &t.innerSnap_, "innerSnap must bind directly to innerSnap_");
    assert(!ps[7].default_.b && !t.innerSnap_,
        "innerSnap must default OFF — border-only snap candidates is the measured default");

    // Keep Vertices (task 0494) — the fourth sticky flag, APPENDED last,
    // default OFF (measured in both directions). Index 8 for the same reason
    // innerSnap is 7: the module's rule is APPEND-never-replace, so a merge
    // shifts the index and never the order.
    //
    // The default is the whole point of this row, not a formality: with it OFF
    // a Remove press on an interior edge loop DELETES the vertices whose whole
    // polygon fan the dissolve ate. Flipping this literal to `true` would
    // silently restore the pre-0494 behaviour tool-wide.
    assert(ps[8].name == "keepVertex" && ps[8].kind == Param.Kind.Bool);
    assert(ps[8].bptr is &t.keepVertex_, "keepVertex must bind directly to keepVertex_");
    assert(!ps[8].default_.b && !t.keepVertex_,
        "keepVertex must default OFF — purging the consumed vertices is the measured default");

    t.edgeLoop_ = t.edgeSlide_ = t.innerSnap_ = t.keepVertex_ = true;
    t.resyncSession();
    assert(t.edgeLoop_ && t.edgeSlide_ && t.innerSnap_ && t.keepVertex_,
        "the flags must survive resyncSession() — sticky options, not gesture state");
}

// ---------------------------------------------------------------------------
// The Mode router's full table (task 0483) — every (mode, Edge Loop) pair
// dispatches an unmodified LMB press to the gesture the reference pairs it
// with. Asserted through `gestureOn_`, the router's own recorded decision,
// so a row is pinned by WHICH gesture it chose and not by whether that
// gesture happened to find a seed under the probe pixel: a seed miss is the
// delegated handler's business (each has its own tests), a misrouted mode is
// this table's.
//
// The press pixel is an edge midpoint on a grid plane — geometry, so the
// Move family takes its on-geometry branch — and the same pixel is used for
// every row, which is what makes the rows comparable.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();

    ImVec2 pa, pb;
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[0][0]], vp, pa), "setup: endpoint projects");
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[0][1]], vp, pb), "setup: endpoint projects");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)((pa.x + pb.x) * 0.5f);
    e.y = cast(int)((pa.y + pb.y) * 0.5f);

    static struct Row { PenMode mode; bool loop; PenGesture want; string why; }
    static immutable Row[] rows = [
        Row(PenMode.Move,      false, PenGesture.PlaceOrMove, "Move = the plain LMB gesture"),
        Row(PenMode.Move,      true,  PenGesture.MoveLoop,       "Move + Edge Loop = the RMB gesture"),
        Row(PenMode.Point,     false, PenGesture.PlaceOrMove, "Point = place-or-move"),
        Row(PenMode.Point,     true,  PenGesture.MoveLoop,       "Point on geometry follows Move"),
        Row(PenMode.Duplicate, false, PenGesture.Build,          "Duplicate = the Shift+LMB gesture"),
        Row(PenMode.Duplicate, true,  PenGesture.DupLoop,        "Duplicate + Edge Loop = the loop variant (gather + trim), the same mode's other half"),
        Row(PenMode.Remove,    false, PenGesture.Remove,         "Remove = the Ctrl+MMB gesture"),
        Row(PenMode.Remove,    true,  PenGesture.Remove,         "Remove + Edge Loop is still the Remove gesture — the loop flag reaches its EDGE primitive, it does not select a different gesture (task 0494)"),
        Row(PenMode.Split,     false, PenGesture.Split,          "Split = the MMB gesture"),
        Row(PenMode.Split,     true,  PenGesture.Split,          "Split ignores Edge Loop"),
        Row(PenMode.AddLoop,   false, PenGesture.AddLoop,        "Add Loop = the Shift+MMB gesture"),
        Row(PenMode.AddLoop,   true,  PenGesture.AddLoop,        "Add Loop ignores Edge Loop"),
        Row(PenMode.Smooth,    false, PenGesture.Smooth,         "Smoothing = the Shift+Ctrl+LMB gesture"),
        Row(PenMode.Smooth,    true,  PenGesture.SmoothLoop,     "Smoothing + Edge Loop = Shift+Ctrl+RMB"),
    ];

    foreach (r; rows) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = r.mode;
        t.edgeLoop_  = r.loop;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == r.want, r.why);
    }

    // Task 0486 (C-1/C-4) + 0487: for Duplicate, Edge Loop selects between the
    // mode's TWO variants — the pressed edge alone, or the gathered-and-trimmed
    // border run. One implementation each, both reached from the one
    // dispatcher, so they cannot drift. The reference reads `edgeLoop_` on the
    // Shift+LMB slot and FORCES it on Shift+RMB, which is why those two chords
    // are now just (mode=Duplicate, loop=...) rows in `kChordOv` rather than
    // two hand-wired gestures.
    {
        auto t1 = new TopologyPenTool();
        t1.meshSrc_ = () => &m;
        t1.penMode_ = PenMode.Duplicate;
        t1.onPlainLmbDown(e, vts);
        assert(t1.dupEdgeEdges_.length == 1,
            "Duplicate with the flag OFF arms exactly the pressed edge");
        assert(!t1.dupLoopArmed_, "and never the loop variant");

        auto t2 = new TopologyPenTool();
        t2.meshSrc_ = () => &m;
        t2.penMode_ = PenMode.Duplicate;
        t2.edgeLoop_ = true;
        t2.onPlainLmbDown(e, vts);
        assert(t2.dupLoopArmed_, "Duplicate with Edge Loop ON arms the loop variant");
        assert(t2.dupLoopEdges_.length >= 1,
            "and its set is the trimmed border run — never fewer than the pressed edge");
        assert(t2.dupEdgeEdges_.length == 0, "the single-edge variant must stay untouched");
    }

    // Edge Slide reroutes the Move family — and ONLY the Move family — to the
    // very gesture the Ctrl+LMB chord runs. Edge Loop wins when both are on
    // (there is no slide-a-whole-loop gesture to compose them into).
    foreach (mode; [PenMode.Move, PenMode.Point]) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = mode;
        t.edgeSlide_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == PenGesture.Slide, "Edge Slide must route the Move family to Slide");

        t.resetAllGestureArms();
        t.edgeLoop_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == PenGesture.MoveLoop, "Edge Loop must win over Edge Slide");
    }

    // Every OTHER mode ignores Edge Slide outright.
    foreach (mode; [PenMode.Duplicate, PenMode.Remove, PenMode.Split,
                    PenMode.AddLoop, PenMode.Smooth]) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = mode;
        t.edgeSlide_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] != PenGesture.Slide,
            "Edge Slide must not leak into a non-Move-family mode");
    }
}

// ---------------------------------------------------------------------------
// The CHORD MODEL composes with the dropdown (task 0487) — the property the old
// table could not express and the reason for the refactor.
//
// Two halves, and the second is the one that used to be wrong:
//   * a chord that OVERRIDES the mode ignores the dropdown (Shift+MMB is Add
//     Loop whatever the dropdown says);
//   * a chord that does NOT override it runs the DROPDOWN's mode. Plain RMB is
//     that case — measured as "the dropdown's mode with the loop forced on",
//     where the old table hard-wired it to move-loop, so it stayed a move-loop
//     with the dropdown parked on Remove.
//
// Driven through the real `onToolAction` seam with a synthetic chord id, so the
// override resolution and the per-button booking are both exercised.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // A vertex pixel: every mode below resolves SOMETHING there, so the rows
    // differ by the routing decision and not by a pick miss.
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    PenGesture press(TopoPenChord c, PenMode dropdown, bool loop = false, bool slide = false) {
        auto t = new TopologyPenTool();
        t.meshSrc_  = () => &m;
        t.penMode_  = dropdown;
        t.edgeLoop_ = loop;
        t.edgeSlide_ = slide;
        t.onToolAction(c, InputPhase.Down, e, vts);
        return t.gestureOn_[chordButton(c)];
    }

    // --- a mode-overriding chord ignores the dropdown entirely.
    foreach (dropdown; [PenMode.Move, PenMode.Remove, PenMode.Fill, PenMode.Smooth]) {
        assert(press(TopoPenChord.ShiftMmb, dropdown) == PenGesture.AddLoop,
            "Shift+MMB overrides the mode to Add Loop whatever the dropdown says");
        assert(press(TopoPenChord.CtrlMmb, dropdown) == PenGesture.Remove,
            "Ctrl+MMB overrides the mode to Remove whatever the dropdown says");
    }

    // --- a NON-overriding chord follows the dropdown. This is the row the old
    //     absolute table got wrong.
    assert(press(TopoPenChord.Rmb, PenMode.Move) == PenGesture.MoveLoop,
        "plain RMB with the dropdown on Move is a move-LOOP (the loop is forced)");
    assert(press(TopoPenChord.Rmb, PenMode.Remove) == PenGesture.Remove,
        "plain RMB with the dropdown on Remove must run REMOVE — under the old absolute "
      ~ "table it stayed a move-loop regardless");
    assert(press(TopoPenChord.Rmb, PenMode.Smooth) == PenGesture.SmoothLoop,
        "plain RMB with the dropdown on Smoothing is smooth+loop — its forced loop meets "
      ~ "the dropdown's mode");

    // --- the forced loop cannot be switched off by the user's flag...
    assert(press(TopoPenChord.Rmb, PenMode.Move, /*loop=*/false) == PenGesture.MoveLoop);
    assert(press(TopoPenChord.Rmb, PenMode.Move, /*loop=*/true)  == PenGesture.MoveLoop,
        "and the flag being on changes nothing for a chord that already forces it");

    // --- ...while a chord that does NOT force it reads the user's flag.
    assert(press(TopoPenChord.Lmb, PenMode.Move, /*loop=*/false) == PenGesture.PlaceOrMove);
    assert(press(TopoPenChord.Lmb, PenMode.Move, /*loop=*/true)  == PenGesture.MoveLoop,
        "the base slot honours Edge Loop — that is what FlagOv.FromUser means");

    // --- Ctrl+LMB forces Edge Slide; plain LMB honours the user's flag.
    assert(press(TopoPenChord.CtrlLmb, PenMode.Move) == PenGesture.Slide,
        "Ctrl+LMB forces Edge Slide on top of the dropdown's mode");
    assert(press(TopoPenChord.Lmb, PenMode.Move, false, /*slide=*/true) == PenGesture.Slide,
        "and the user's own Edge Slide reaches the base slot");

    // --- the gesture is booked against the chord's OWN button, so a MIDDLE
    //     chord cannot redirect a LEFT release.
    {
        auto t = new TopologyPenTool();
        t.meshSrc_ = () => &m;
        t.penMode_ = PenMode.Move;
        t.onToolAction(TopoPenChord.Lmb,    InputPhase.Down, e, vts);
        t.onToolAction(TopoPenChord.CtrlMmb, InputPhase.Down, e, vts);
        assert(t.gestureOn_[InputButton.Left]   == PenGesture.PlaceOrMove,
            "the LEFT booking must survive a MIDDLE chord fired during the drag");
        assert(t.gestureOn_[InputButton.Middle] == PenGesture.Remove,
            "and the MIDDLE booking is its own");
    }

    // --- task 0499: the two slots that override NOTHING. Each one must run
    //     the DROPDOWN's mode — the whole content of the measurement — and
    //     must NOT behave like the base slot of its own button.
    foreach (c; [TopoPenChord.CtrlRmb, TopoPenChord.ShiftCtrlMmb]) {
        assert(press(c, PenMode.Move)      == PenGesture.PlaceOrMove,
            "an unbound slot with the dropdown on Move runs a plain move");
        assert(press(c, PenMode.Remove)    == PenGesture.Remove,
            "…on Remove it removes");
        assert(press(c, PenMode.Split)     == PenGesture.Split,
            "…on Split it splits (the condition the capture ran in lockstep)");
        assert(press(c, PenMode.AddLoop)   == PenGesture.AddLoop);
        assert(press(c, PenMode.Duplicate) == PenGesture.Build);
        // Smoothing WITHOUT the loop — this is the assertion that fails if
        // either row is ever "fixed" into looking like its own button's base
        // slot: plain RMB forces the loop (-> SmoothLoop) and Ctrl+RMB does
        // not, and plain MMB forces Split where Shift+Ctrl+MMB does not.
        assert(press(c, PenMode.Smooth)    == PenGesture.Smooth,
            "an unbound slot does NOT force the loop the way its button's base slot may");
        // …and it still READS the user's own flags, like the base LMB slot.
        assert(press(c, PenMode.Smooth, /*loop=*/true) == PenGesture.SmoothLoop,
            "FromUser means the user's Edge Loop reaches the slot");
        assert(press(c, PenMode.Move, /*loop=*/false, /*slide=*/true) == PenGesture.Slide,
            "…and so does the user's Edge Slide");
    }
    // The distinction stated as a direct comparison, in the exact condition the
    // capture ran (dropdown = Move / Split): same button, different slot.
    assert(press(TopoPenChord.Rmb, PenMode.Move) != press(TopoPenChord.CtrlRmb, PenMode.Move),
        "plain RMB forces the loop, Ctrl+RMB does not — measured on the same rig");
    assert(press(TopoPenChord.Mmb, PenMode.Move) != press(TopoPenChord.ShiftCtrlMmb, PenMode.Move),
        "plain MMB forces Split, Shift+Ctrl+MMB followed the dropdown (measured: MOVE)");
    assert(press(TopoPenChord.Mmb, PenMode.Split) == press(TopoPenChord.ShiftCtrlMmb, PenMode.Split),
        "and with the dropdown ON Split the two agree — the other half of the lockstep");
}

// ---------------------------------------------------------------------------
// The 12-slot grid at the DEFAULT dropdown — the "nothing else moved"
// acceptance condition, restated for task 0499 exactly as task 0487 stated it:
// with the dropdown parked at its default (`move`, both flags off), every slot
// that existed before yields EXACTLY the gesture it yielded before, and the two
// new rows land on the base slot's own outcome (they override nothing, so at the
// default dropdown they cannot differ from plain LMB's routing).
//
// One table, all 12 rows, driven through the real `onToolAction` seam. A future
// edit that "tidies" the chord table by shifting an enum member or a row is a
// silent rebinding of everything after it (`kChordOv` is indexed BY the enum) —
// this is the pin that turns that into a failure.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    static struct Slot { TopoPenChord chord; PenGesture want; string why; }
    immutable Slot[] grid = [
        Slot(TopoPenChord.Lmb,          PenGesture.PlaceOrMove, "plain LMB"),
        Slot(TopoPenChord.ShiftLmb,     PenGesture.Build,       "Shift+LMB = Duplicate, loop from the user (off)"),
        Slot(TopoPenChord.CtrlLmb,      PenGesture.Slide,       "Ctrl+LMB forces Edge Slide"),
        Slot(TopoPenChord.ShiftCtrlLmb, PenGesture.Smooth,      "Shift+Ctrl+LMB = Smoothing, no loop"),
        Slot(TopoPenChord.Mmb,          PenGesture.Split,       "plain MMB = Split"),
        Slot(TopoPenChord.ShiftMmb,     PenGesture.AddLoop,     "Shift+MMB = Add Loop"),
        Slot(TopoPenChord.CtrlMmb,      PenGesture.Remove,      "Ctrl+MMB = Remove"),
        Slot(TopoPenChord.Rmb,          PenGesture.MoveLoop,    "plain RMB = the dropdown + forced loop"),
        Slot(TopoPenChord.ShiftRmb,     PenGesture.DupLoop,     "Shift+RMB = Duplicate + forced loop"),
        Slot(TopoPenChord.ShiftCtrlRmb, PenGesture.SmoothLoop,  "Shift+Ctrl+RMB = Smoothing + forced loop"),
        // The two rows task 0499 wired. At the DEFAULT dropdown they are the
        // base slot's own outcome — that is what "overrides nothing" means, and
        // it is why wiring them cannot disturb any row above.
        Slot(TopoPenChord.CtrlRmb,      PenGesture.PlaceOrMove, "Ctrl+RMB follows the dropdown"),
        Slot(TopoPenChord.ShiftCtrlMmb, PenGesture.PlaceOrMove, "Shift+Ctrl+MMB follows the dropdown"),
    ];
    assert(grid.length == kChordOv.length,
        "every chord slot must appear in this pin — a new row without a row here is a gap");

    foreach (s; grid) {
        auto t = new TopologyPenTool();
        t.meshSrc_ = () => &m;   // default dropdown/flags: Move, loop off, slide off
        t.onToolAction(s.chord, InputPhase.Down, e, vts);
        assert(t.gestureOn_[chordButton(s.chord)] == s.want, s.why);
    }
}

// ---------------------------------------------------------------------------
// The router's RELEASE leg follows the press, not the dropdown (task 0483):
// a mode written mid-drag must not redirect the commit to a gesture nobody
// armed. Split is the probe — it arms on a vertex press and its `splitUp`
// disarms observably — and the dropdown is flipped to Move (whose UP leg is
// the entirely different `lmbPlaceOrMoveUp`) between the press and the
// release.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    t.penMode_ = PenMode.Split;
    assert(t.onPlainLmbDown(e, vts), "a Split-mode press on a vertex must arm");
    assert(t.splitArmed_ && t.splitSourceVert_ == 0, "Split must arm at the pressed vertex");
    assert(t.gestureOn_[InputButton.Left] == PenGesture.Split, "the press must record the Split gesture");

    // The dropdown moves mid-drag (this is reachable over HTTP at any time).
    t.penMode_ = PenMode.Move;

    assert(t.lmbModeUp(e, vts), "the release must still reach Split's own commit leg");
    assert(!t.splitArmed_, "Split's commit leg must have run and disarmed");
}

// ---------------------------------------------------------------------------
// params() — Smooth strength schema (reference parity,
// doc/tasks/work/0478-topopen-smooth-kernel.md): the measured `strength` attribute
// exposed as a real, bound, bounded Param. Defaults to the reference's own
// 1.0 (force factor 0.05 after the ÷20), binds directly to the field the
// Smooth kernel reads, declares `.enforceBounds()` so a headless `tool.attr`
// injection is clamped rather than honoured, and — like every other option on
// this tool — is sticky across `resyncSession()`.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[4].name == "smoothStrength");
    assert(ps[4].kind == Param.Kind.Float);
    assert(abs(ps[4].default_.f - 1.0f) < 1e-6f,
        "smoothStrength must default to 1.0 — the reference's own default, giving F = 1/20 = 0.05");
    assert(ps[4].fptr is &t.smoothStrength_, "the Param must bind directly to smoothStrength_");
    assert(ps[4].enforceBounds_,
        "smoothStrength must clamp injected values — an out-of-range force factor would be "
      ~ "honoured verbatim by the headless attr path otherwise");
    assert(ps[4].hints.hasMinF && ps[4].hints.hasMaxF
        && abs(ps[4].hints.minF - 0.0f) < 1e-6f && abs(ps[4].hints.maxF - 4.0f) < 1e-6f,
        "smoothStrength bounds must be declared as [0, 4] — `.enforceBounds()` clamps to the "
      ~ "hinted range, so a missing hint would silently disarm the clamp");

    assert(abs(t.smoothStrength_ - 1.0f) < 1e-6f, "must start at the default strength");

    t.smoothStrength_ = 0.5f;
    t.resyncSession();
    assert(abs(t.smoothStrength_ - 0.5f) < 1e-6f,
        "smoothStrength_ must survive resyncSession() — it is a sticky tool option, not "
      ~ "per-gesture arm state");
}

// ---------------------------------------------------------------------------
// params() / toolStateJson — the two DISPLAY toggles (task 0499): the
// reference's `showVertex`/`showEdge`, both measured default ON, published as
// plain sticky booleans. Nothing here is bounded or gated — they are the only
// two attributes in the reference's set whose behavior is measured to be
// "drawing only", which is what makes them portable when the numeric ones are
// not.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[5].name == "showVertex");
    assert(ps[5].kind == Param.Kind.Bool);
    assert(ps[5].default_.b == true, "showVertex must default ON — the measured default");
    assert(ps[5].bptr is &t.showVertex_, "the Param must bind directly to showVertex_");
    assert(ps[6].name == "showEdge");
    assert(ps[6].kind == Param.Kind.Bool);
    assert(ps[6].default_.b == true, "showEdge must default ON — the measured default");
    assert(ps[6].bptr is &t.showEdge_, "the Param must bind directly to showEdge_");

    // Defaults ON => a tool nobody touched draws exactly what it drew before
    // these rows existed.
    assert(t.showVertex_ && t.showEdge_, "both toggles must start ON");

    auto s0 = t.toolStateJson();
    assert(s0["hoverIndicator"]["showVertex"].type == JSONType.true_);
    assert(s0["hoverIndicator"]["showEdge"].type   == JSONType.true_);

    t.showVertex_ = false;
    t.resyncSession();
    assert(!t.showVertex_,
        "showVertex_ must survive resyncSession() — a sticky display option, not arm state");
    auto s1 = t.toolStateJson();
    assert(s1["hoverIndicator"]["showVertex"].type == JSONType.false_,
        "the live toggle must be observable from outside");
}

// ---------------------------------------------------------------------------
// hoverIndicatorElem — WHAT the toggles actually do (task 0499). `draw()`
// switches on this function, so this is the drawn outcome, pinned without an
// ImGui draw list.
//
// The load-bearing half is the SECOND assertion of each pair: turning a marker
// off must NOT change `hoverGrabElem_`, i.e. what a press grabs. These are
// display toggles; nothing measured says they disable the grab, and a knob that
// silently changed the grab target would be the exact failure mode task 0499
// exists to avoid.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    // A resolved VERTEX target.
    t.hoverGrabElem_  = MoveElem.Vertex;
    t.hoverGrabIndex_ = 3;
    assert(t.hoverIndicatorElem() == MoveElem.Vertex, "ON by default -> the marker draws");
    t.showVertex_ = false;
    assert(t.hoverIndicatorElem() == MoveElem.None, "showVertex off -> nothing is painted");
    assert(t.hoverGrabElem_ == MoveElem.Vertex && t.hoverGrabIndex_ == 3,
        "…and the resolved grab target is untouched — the press still takes the vertex");
    // The OTHER toggle is not involved.
    t.showEdge_ = false;
    t.showVertex_ = true;
    assert(t.hoverIndicatorElem() == MoveElem.Vertex,
        "showEdge must not gate the vertex marker");

    // A resolved EDGE target, same shape.
    t.hoverGrabElem_  = MoveElem.Edge;
    t.hoverGrabIndex_ = 7;
    t.showEdge_ = true;
    assert(t.hoverIndicatorElem() == MoveElem.Edge);
    t.showEdge_ = false;
    assert(t.hoverIndicatorElem() == MoveElem.None, "showEdge off -> nothing is painted");
    assert(t.hoverGrabElem_ == MoveElem.Edge && t.hoverGrabIndex_ == 7,
        "…and the press still takes the edge");
    t.showVertex_ = false;
    t.showEdge_   = true;
    assert(t.hoverIndicatorElem() == MoveElem.Edge,
        "showVertex must not gate the edge line");

    // The FACE hatch has no toggle in the reference's two-flag set, so neither
    // flag may hide it. Guessing a third toggle into existence here is the
    // failure this asserts against.
    t.hoverGrabElem_  = MoveElem.Face;
    t.hoverGrabIndex_ = 1;
    t.showVertex_ = false;
    t.showEdge_   = false;
    assert(t.hoverIndicatorElem() == MoveElem.Face,
        "the face hatch is ungated — the reference has two display toggles, not three");

    // Nothing resolved stays nothing, either way.
    t.hoverGrabElem_  = MoveElem.None;
    t.hoverGrabIndex_ = -1;
    t.showVertex_ = true;
    t.showEdge_   = true;
    assert(t.hoverIndicatorElem() == MoveElem.None);
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseButtonUp — NEGATIVE DISPATCH pin: Split does
// NOT do mid-edge insertion (doc/tasks/work/0480-topopen-addloop-middle.md).
// Drives the REAL dispatch path end-to-end — plain-MMB down on vertex A (0),
// plain-MMB up on the screen-space MIDPOINT of the opposite edge (2,3),
// never a vertex — mirroring the vertex<->vertex e2e test above exactly
// (same rig, same camera). Split is a vertex->vertex chord split, so this
// release must leave the mesh byte-identical with NO undo entry. Inserting a
// vertex partway along a crossed edge belongs to Add Loop, whose own
// `middle`/click-fraction law is pinned separately above and in
// tests/test_topopen_addloop_middle.d.
//
// This test previously asserted the OPPOSITE (Δv=+1/Δf=+1/one undo entry) —
// it encoded the wrong mode attachment and is inverted here deliberately,
// not weakened: the same real gesture is driven, and every count is still
// asserted exactly.
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
    // projected edge (2,3) comfortably longer than 2*topoPenSnapAcceptPx at
    // this camera distance — its screen-space MIDPOINT must land clearly
    // outside the DRAG-SNAP acceptance radius of EITHER endpoint (the release
    // resolves through `resolveSnapTargetVert`, whose reach is wider than the
    // press pick's — task 0496), so the release genuinely
    // resolves NO vertex (a snap to v2/v3 would turn this into an ordinary
    // vertex-target split and the no-op assertions below would be vacuous).
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

    // Guard the rig itself: the release pixel must resolve NO vertex, or the
    // no-op below would prove nothing about the removed edge branch. Asked of
    // the query the release ACTUALLY runs (`resolveSnapTargetVert`, 24px), not
    // of the narrower press pick — a guard weaker than the code path it guards
    // is not a guard.
    assert(t.resolveSnapTargetVert(midX, midY, vp) < 0,
        "setup: the edge midpoint pixel must be outside every vertex's drag-snap radius");

    auto before = MeshSnapshot.capture(m);

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = midX; eUp.y = midY;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "plain-MMB release on the edge midpoint must still be consumed");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");

    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "Split must NOT insert a mid-edge vertex — a release on an edge is a byte-identical "
      ~ "no-op (that behaviour belongs to Add Loop)");
    assert(m.vertices.length == 4, "Δv=0 — no vertex may be created by a Split release");
    assert(m.faces.length    == 1, "Δf=0 — the quad must stay whole");
    assert(m.edges.length    == 4, "Δe=0 — no sub-edge and no chord may be created");
    assert(!history.canUndo(), "a no-op release must record no undo entry");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md) — Tier-B
// tests. The `params()`/`mode` schema round-trip is already pinned right
// after the Add Loop `middle` option schema block above (mirroring
// `addLoopMiddle_`'s own precedent); everything below exercises
// `findFillRing`/`commitFill`/the dropdown-routed dispatch/the hover
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
// removal). `findFillRing` must resolve exactly that cell from a cursor at
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

    // The press pixel is the gap cell's own CENTROID -- as far from every
    // element of the mesh as the cell allows, and well outside
    // `topoPenPressPickPx`. That is deliberate and it is the load-bearing half
    // of this assertion (task 0507): the reference drops its press-pick gather
    // radius entirely in Fill mode, so a press at the bare centre of a gap
    // still resolves the cell. Gating `findFillRing`/`fillDown` on
    // `topoPenPressPickPx` to make Fill "consistent" with the other modes is
    // the exact regression this line catches -- see `source/constraint.d`'s
    // MODE-DEPENDENT paragraph.
    auto cell = t.findFillRing(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillRing must resolve the one interior gap cell "
        ~ "from a press at its bare centroid -- Fill's press has NO reach radius");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillRing must return exactly the gap cell's own 4 corners");

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
// `isEdgeBorder`'s n==1 predicate). `findFillRing` must still resolve the
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

    auto cell = t.findFillRing(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillRing must resolve the notch cell from its 3 border edges");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillRing must return exactly the notch cell's own 4 corners");

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
// NOTE on scope (revised after a post-e6ca77a review fix): TWO
// MUTUALLY-ADJACENT missing cells (sharing one now-gone middle edge) were
// investigated in detail; the outcome DEPENDS on whether the pair touches
// the mesh's own outer perimeter:
//   - INTERIOR adjacent pair (neither cell touches the mesh perimeter): now
//     resolves CORRECTLY, one true cell per click — see the dedicated
//     interior-adjacent-2-cell unittest right after this one. (An earlier
//     draft of THIS comment claimed the interior case also failed; that
//     was an incomplete-enumeration mistake in hand analysis, not a real
//     limitation — a full seed-edge enumeration finds a valid seed for
//     EACH true cell, and `findFillRing`'s closing-edge guard
//     — `m.edgeIndex(bp,ap) != ~0u` — is exactly what lets each true cell's
//     candidate win: the true cell closes on the shared middle edge, which
//     still EXISTS as a floating (0-face) edge, while the bogus
//     "skip-through" candidate's closing side is a non-edge diagonal and
//     is rejected outright.)
//   - PERIMETER adjacent pair (both cells touch the SAME outer mesh side,
//     e.g. a "2-cell-wide" notch along one edge of the mesh): still
//     resolves to `[]` — see the dedicated perimeter-adjacent-2-cell
//     unittest right after this one. Root cause: the shared "waist" vertex
//     between the two missing cells has ZERO border-edge incidences at all
//     (both its own mouth-facing side and the shared middle edge are
//     non-border), so it never even enters `findFillRing`'s
//     border-adjacency graph — no candidate mentioning it is EVER
//     generated, closing-edge guard or not. This is a real, acceptable V1
//     gap (falls under doc/topopen_fill_plan.md's own AF-1 "known
//     limitation" umbrella) — but is now at least a SAFE no-op rather than
//     the wrong bogus fill the guard was added to prevent.
//
// This test itself verifies owner decision 2's core promise ("one click,
// one cell, never both") on two gaps that are trivially, unambiguously
// resolvable: two separate single-cell interior gaps, far enough apart
// that neither's reconstruction can be confused with the other's.
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

    auto foundA = t.findFillRing(cast(int)pixA.x, cast(int)pixA.y, vp);
    assert(foundA.length == 4, "a cursor over gap A must resolve exactly that cell");
    assert(fillCellSetEq(foundA, cellA),
        "must resolve ONLY gap A's own 4 corners, never gap B's");

    auto foundB = t.findFillRing(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundB.length == 4, "a cursor over gap B must resolve exactly that cell");
    assert(fillCellSetEq(foundB, cellB),
        "must resolve ONLY gap B's own 4 corners, never gap A's");

    // One click fills ONE cell -- the other remains an untouched gap,
    // fillable by a SECOND click (owner decision 2: "one cell per click").
    t.commitFill(foundA);
    assert(m.faces.length == 24, "commitFill must add exactly ONE face for gap A");

    auto foundBAfter = t.findFillRing(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundBAfter.length == 4, "gap B must still be found as a gap after gap A alone was filled");
    assert(fillCellSetEq(foundBAfter, cellB));

    t.commitFill(foundBAfter);
    assert(m.faces.length == 25, "commitFill must add exactly ONE more face for gap B");
    assert(m.vertices.length == 36, "both fills together are Δv=0 -- every corner is reused");
    assert(history.canUndo());
}

// F3-PERIMETER — two MUTUALLY-ADJACENT cells removed from the SAME mesh
// perimeter side (a 2-row x 4-col grid, middle row-0 cells at indices 1
// and 2, asymmetric widths 1 / 3).
//
// FIXTURE CHANGED BY TASK 0488, and this is the reviewed reason. The old
// expectation here was `[]` -- a deliberate no-op produced by V1's mandatory
// real-fourth-side guard, on a rig V1's border-edge-adjacency construction
// could not resolve at all (the shared "waist" vertex carries no border edge,
// so no V1 candidate ever mentioned it). The measured rule has NO
// fourth-side requirement and does not reconstruct cells from adjacency: it
// seeds on the pressed border edge and takes the nearest qualifying vertices,
// and the waist vertex qualifies here through the ISOLATED clause (both its
// remaining sides lost their last polygon, so it is on no polygon at all).
// The left cell's own four corners are exactly what the search returns, and
// the fill lands on the cell the cursor is in.
//
// So the change is a strict improvement in outcome, but it is NOT why it was
// made: it is what dropping a guard the reference does not have produces on
// this rig. Recorded as a changed fixture, not as a fix.
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

    uint[] leftVerts = m.faces[1].dup;   // width 1 -- retained only for the centroid pixel
    auto mask = new bool[](m.faces.length);
    mask[1] = true; mask[2] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 6, "setup: both perimeter cells must be removed");
    auto before = MeshSnapshot.capture(m);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 leftC = (m.vertices[leftVerts[0]] + m.vertices[leftVerts[1]]
                + m.vertices[leftVerts[2]] + m.vertices[leftVerts[3]]) * 0.25f;
    ImVec2 leftPix;
    assert(TopologyPenTool.projectPt(leftC, vp, leftPix));

    auto cell = t.findFillRing(cast(int)leftPix.x, cast(int)leftPix.y, vp);
    assert(cell.length == 4,
        "the measured rule resolves the LEFT cell of a perimeter 2-cell gap -- the waist "
      ~ "vertex qualifies as ISOLATED, and no fourth-side guard stands in the way");
    assert(fillCellSetEq(cell, leftVerts),
        "it must be the cell the CURSOR is in, never a span of both missing cells");

    t.commitFill(cell);
    auto after = MeshSnapshot.capture(m);
    assert(m.faces.length == 7, "exactly ONE face is added -- one cell per press");
    assert(m.vertices.length == before.vertices.length, "Dv=0 -- every corner is reused");
    assert(m.edges.length == before.edges.length,
        "De=0 here -- the left cell's fourth side survived the deletion as a floating edge");
    assert(history.canUndo(), "a real fill records one undo entry");
    assert(after.vertices == before.vertices,
        "a fill moves no vertex -- positions are byte-identical");
}

// F3-INTERIOR — the companion case: two MUTUALLY-ADJACENT cells removed
// from the MIDDLE of a bigger grid (neither touches the mesh perimeter).
// Here the closing-edge guard does the opposite job: it REJECTS the bogus
// cross-cell candidates (their closing side is a non-edge diagonal) while
// LETTING THROUGH each true single cell's own candidate (its closing side
// is the shared middle edge, which still EXISTS as a floating/0-face edge
// -- `deleteFacesByMask`'s `keepFloatingEdges` contract). A cursor over
// EITHER cell must resolve to exactly that ONE cell, never a span of both.
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

    Mesh m = makeGridPlane(4);   // 5x5=25 verts, 4x4=16 quads
    assert(m.faces.length == 16);
    uint[] leftVerts  = m.faces[5].dup;   // interior cell (i=1,j=1)
    uint[] rightVerts = m.faces[6].dup;   // adjacent interior cell (i=1,j=2) -- shares an edge
    auto mask = new bool[](m.faces.length);
    mask[5] = true; mask[6] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 14, "setup: both interior cells must be removed");
    assert(m.vertices.length == 25, "setup: no vertex is deleted (keepOrphans)");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 leftC  = (m.vertices[leftVerts[0]]  + m.vertices[leftVerts[1]]
                 + m.vertices[leftVerts[2]]  + m.vertices[leftVerts[3]])  * 0.25f;
    Vec3 rightC = (m.vertices[rightVerts[0]] + m.vertices[rightVerts[1]]
                 + m.vertices[rightVerts[2]] + m.vertices[rightVerts[3]]) * 0.25f;
    ImVec2 leftPix, rightPix;
    assert(TopologyPenTool.projectPt(leftC,  vp, leftPix));
    assert(TopologyPenTool.projectPt(rightC, vp, rightPix));

    auto leftCell = t.findFillRing(cast(int)leftPix.x, cast(int)leftPix.y, vp);
    assert(leftCell.length == 4,
        "an interior adjacent-2-cell gap must still resolve the LEFT cell (the closing-edge "
      ~ "guard rejects the bogus span, but the true cell's own candidate survives)");
    assert(fillCellSetEq(leftCell, leftVerts),
        "must resolve ONLY the left cell's own 4 corners, never a span of both cells");

    auto rightCell = t.findFillRing(cast(int)rightPix.x, cast(int)rightPix.y, vp);
    assert(rightCell.length == 4, "must likewise resolve the RIGHT cell under its own cursor");
    assert(fillCellSetEq(rightCell, rightVerts),
        "must resolve ONLY the right cell's own 4 corners, never a span of both cells");

    t.commitFill(leftCell);
    assert(m.faces.length == 15, "commitFill must add exactly ONE face for the left cell");
    auto rightCellAfter = t.findFillRing(cast(int)rightPix.x, cast(int)rightPix.y, vp);
    assert(rightCellAfter.length == 4 && fillCellSetEq(rightCellAfter, rightVerts),
        "the right cell must still resolve correctly after the left cell alone was filled");
    t.commitFill(rightCellAfter);
    assert(m.faces.length == 16, "commitFill must add exactly ONE more face for the right cell");
    assert(m.vertices.length == 25, "both fills together are Δv=0 -- every corner is reused");
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
    auto cellOverFace = t.findFillRing(cast(int)spix.x, cast(int)spix.y, vp);
    assert(cellOverFace.length == 0,
        "findFillRing must return [] over an already-faced INTERIOR cell (no border edges "
      ~ "nearby to seed a candidate from)");

    // (b) cursor far outside the mesh entirely.
    auto cellOverEmpty = t.findFillRing(-99999, -99999, vp);
    assert(cellOverEmpty.length == 0, "findFillRing must return [] over empty area");

    // (c) commitFill([]) / a miss must be a clean no-op.
    t.commitFill(cellOverFace);
    t.commitFill(null);
    auto afterAll = MeshSnapshot.capture(m);
    assert(afterAll.vertices == beforeAll.vertices && afterAll.edges == beforeAll.edges
        && afterAll.faces == beforeAll.faces,
        "commitFill must leave the mesh byte-identical on a miss/empty cell");
    assert(!history.canUndo(), "a miss/empty cell must record NO undo entry");
}

// F5/F9 — dropdown routing: plain-LMB is a NO-OP for Point's place/move path
// when Fill owns it, and vice versa. dropdown=Point must arm place/move
// exactly like pre-Fill behavior; dropdown=Fill must fill immediately
// (commit-on-DOWN) and arm NOTHING.
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

    // dropdown = Point: plain-LMB over the gap centroid must arm place/move
    // -- NEVER Fill -- byte-identical to pre-Fill behavior.
    t.penMode_ = PenMode.Point;
    int facesBefore = cast(int)m.faces.length;
    bool consumed = t.onPlainLmbDown(e, vts);
    assert(consumed, "plain-LMB must always be consumed");
    assert(t.placeArmed_ || t.moveArmed_,
        "Point mode must arm place/move, exactly like pre-Fill behavior");
    assert(cast(int)m.faces.length == facesBefore, "Point mode must not mutate the mesh on DOWN");
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

// F8 — hover preview state: `fillRing_` equals the cell (as a set) after
// the Fill-mode motion compute; `null` in every other mode, off any gap, and when
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

    // Move mode (the default): the preview must stay empty even directly over
    // a gap cell -- Fill's hatch is gated on the mode.
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 0, "a non-Fill mode must never populate the Fill preview");

    // Fill mode: the SAME motion must resolve exactly the gap cell.
    t.penMode_ = PenMode.Fill;
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 4, "Fill mode must resolve the gap cell under the cursor");
    assert(fillCellSetEq(t.fillRing_, cellVerts));

    // A gesture armed on ANY button must clear the preview even in Fill mode.
    t.dragArmed_ = true;
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 0, "an armed gesture must take precedence over the Fill preview");
    t.dragArmed_ = false;

    // Off any gap (far away) -> null, even in Fill mode.
    SDL_MouseMotionEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    t.onMouseMotion(eFar, vts);
    assert(t.fillRing_.length == 0, "a cursor far from every gap must clear the preview");
}

// Fill mode radius overlay -- pure LAW arithmetic (task 0477 continuation,
// a derived law; full provenance/disassembly kept in the PRIVATE toolcard,
// toolcards/topology_pen/fill_radius_law_capture.md, never in this tracked
// source): radius = max(euclidean(cursor, edgeEndpointA),
// euclidean(cursor, edgeEndpointB)), screen-space pixels. A 3-4-5/6-8-10
// pair of right triangles off the SAME cursor pins both the per-endpoint
// Euclidean arithmetic and the max() tiebreak (never sum/average/first-arg)
// with hand-checkable numbers -- the draw itself isn't unit-testable, but
// this arithmetic, extracted as a pure static helper, is.
unittest {
    import std.math : abs, sqrt;

    auto cursor = ImVec2(0, 0);
    auto a = ImVec2(3, 4);     // distance 5 from cursor
    auto b = ImVec2(-6, 8);    // distance 10 from cursor -- farther

    float r = TopologyPenTool.fillHoverRadiusPx(cursor.x, cursor.y, a, b);
    assert(abs(r - 10.0f) < 1e-4, "radius must be the FARTHER endpoint's distance, not the nearer");

    // Order-independence: swapping which argument is farther must not
    // change the result (max, not "first argument wins").
    float rSwapped = TopologyPenTool.fillHoverRadiusPx(cursor.x, cursor.y, b, a);
    assert(abs(rSwapped - 10.0f) < 1e-4, "radius must be order-independent (max, not positional)");

    // Cursor coincident with the NEARER endpoint: radius collapses to
    // exactly the farther endpoint's own distance (0 max'd with a
    // positive value), not 0 and not a sum.
    float rAtA = TopologyPenTool.fillHoverRadiusPx(a.x, a.y, a, b);
    float expected = sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    assert(abs(rAtA - expected) < 1e-3,
        "radius at a coincident endpoint must equal the OTHER endpoint's own distance");
}

// Fill mode radius overlay -- hover-time integration (task 0477
// continuation): `fillRadiusValid_`/`fillRadiusPx_` populate alongside
// `fillRing_` in `onMouseMotion`'s Fill-mode branch, off the screen-nearest
// BORDER EDGE (not the candidate cell's corners). False/unset in Draw
// mode, off any border edge, and when ANY gesture is armed -- mirrors the
// F8 `fillRing_` test above, same precedence rules.
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.math : abs;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    // Hover pixel = the screen-space MIDPOINT of one of the gap's own
    // border edges (cellVerts[0]-cellVerts[1]) -- lies exactly ON that
    // projected segment (distance 0 in SCREEN space, by construction), so
    // it is unambiguously the screen-nearest border edge regardless of
    // perspective distortion.
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[cellVerts[0]], vp, p0));
    assert(TopologyPenTool.projectPt(m.vertices[cellVerts[1]], vp, p1));
    ImVec2 hoverPix = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent e;
    e.x = cast(int)hoverPix.x; e.y = cast(int)hoverPix.y;

    // Move mode (the default): no radius overlay, even directly over a border edge.
    t.onMouseMotion(e, vts);
    assert(!t.fillRadiusValid_, "a non-Fill mode must never populate the radius overlay");

    // Fill mode: the SAME motion must resolve the radius against THIS
    // edge's own two endpoints, matching the pure law exactly.
    t.penMode_ = PenMode.Fill;
    t.onMouseMotion(e, vts);
    assert(t.fillRadiusValid_, "Fill mode must resolve a radius when hovering a border edge");
    float expected = TopologyPenTool.fillHoverRadiusPx(cast(float)e.x, cast(float)e.y, p0, p1);
    assert(abs(t.fillRadiusPx_ - expected) < 1e-2,
        "radius must equal max(dist to e0, dist to e1) for the hovered border edge");

    // A gesture armed on ANY button must clear the overlay even in Fill mode.
    t.dragArmed_ = true;
    t.onMouseMotion(e, vts);
    assert(!t.fillRadiusValid_, "an armed gesture must take precedence over the radius overlay");
    t.dragArmed_ = false;

    // Off any border edge (far away) -> invalid, even in Fill mode.
    SDL_MouseMotionEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    t.onMouseMotion(eFar, vts);
    assert(!t.fillRadiusValid_, "a cursor far from every border edge must clear the overlay");
}

// ---------------------------------------------------------------------------
// FILL — the measured candidate rule (task 0488). Every block below pins a
// clause that the SHIPPED rule got wrong, and every one of them FAILS on that
// shipped rule. Provenance for each clause is the private toolcard, never
// this file.
//
// Shared rig helpers keep the arithmetic hand-checkable: all rigs are planar
// (y = 0) under `makeGridPlaneTestViewport`, which looks straight down, so a
// world (x, z) offset is a screen offset and every distance quoted in a
// comment can be read off the coordinates.
// ---------------------------------------------------------------------------

// The pure screen-space predicates the rule is built from, on hand numbers.
unittest {
    // segmentsProperlyCross — an X crosses; a T-junction does NOT (the
    // measured word is "properly": both parameters strictly inside (0,1)),
    // and neither do parallels, disjoint pairs, or a shared endpoint. The
    // endpoint cases are load-bearing: a candidate that is itself a corner of
    // the polygon being tested must survive, and it only does because
    // touching is not crossing.
    assert(TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(0, -1), ImVec2(0, 1)),
           "an X must cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(0, 1), ImVec2(-1, 0), ImVec2(1, 0)),
           "a T-junction touching at a segment END is NOT a proper crossing");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(-1, 1), ImVec2(1, 1)),
           "parallels never cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(5, -1), ImVec2(5, 1)),
           "disjoint segments never cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(1, 1), ImVec2(0, 0), ImVec2(1, -1)),
           "a shared endpoint is not a crossing");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(2, 0), ImVec2(1, 0), ImVec2(3, 0)),
           "collinear overlap is not a PROPER crossing");

    // screenQuadConvex — the shape test. A square passes either way round; a
    // bowtie (the SAME four points in the other cyclic order) fails, which is
    // exactly what makes the two-order search do real work; a collinear
    // corner fails, keeping a degenerate cycle out of the build.
    auto p00 = ImVec2(0, 0), p10 = ImVec2(1, 0), p11 = ImVec2(1, 1), p01 = ImVec2(0, 1);
    assert(TopologyPenTool.screenQuadConvex(p00, p10, p11, p01), "a square is convex");
    assert(TopologyPenTool.screenQuadConvex(p01, p11, p10, p00),
           "convexity is winding-agnostic — all four corners same sign, either sign");
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, p01, p11),
           "the bowtie order of the same four points must FAIL");
    assert(!TopologyPenTool.screenQuadConvex(
               ImVec2(0, 0), ImVec2(1, 0), ImVec2(2, 0), ImVec2(1, 1)),
           "a collinear corner is neither sign — reject");
    // A dart (one point inside the triangle of the other three) is convex in
    // NO cyclic order, which is how the search refuses outright rather than
    // building a self-overlapping facet.
    auto inside = ImVec2(0.5f, 0.2f);
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, inside, p01));
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, p01, inside));
}

// The bridge: a quad across a gap whose closing side is NOT a mesh edge.
//
// FAILS ON THE OLD RULE, which is the point. The shipped rule reconstructed a
// cell from BORDER-EDGE ADJACENCY and required the fourth side to be a real
// mesh edge, so it could never leave the bar it seeded on: two topologically
// disconnected bars had no candidate at all and the press was a no-op. The
// reference has no such requirement and was measured building exactly this.
//
// Rig: two lone quads facing each other across a gap in x, both border on all
// four sides. Cursor between them but nearer bar A, so A's facing edge is the
// seed and both of B's facing corners are the only things in reach.
version (unittest) private Mesh makeFillBridgeRig(out uint[4] barA, out uint[4] barB) {
    Mesh m;
    // Bar A (left), corners in cycle order.
    barA[0] = m.addVertex(Vec3(-0.6f, 0, -0.2f));
    barA[1] = m.addVertex(Vec3(-0.2f, 0, -0.2f));
    barA[2] = m.addVertex(Vec3(-0.2f, 0,  0.2f));
    barA[3] = m.addVertex(Vec3(-0.6f, 0,  0.2f));
    // Bar B (right).
    barB[0] = m.addVertex(Vec3( 0.2f, 0, -0.2f));
    barB[1] = m.addVertex(Vec3( 0.6f, 0, -0.2f));
    barB[2] = m.addVertex(Vec3( 0.6f, 0,  0.2f));
    barB[3] = m.addVertex(Vec3( 0.2f, 0,  0.2f));
    m.addFace([barA[0], barA[1], barA[2], barA[3]]);
    m.addFace([barB[0], barB[1], barB[2], barB[3]]);
    m.buildLoops();
    return m;
}

unittest {
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] barA, barB;
    Mesh m = makeFillBridgeRig(barA, barB);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectPt(Vec3(-0.05f, 0, 0), vp, cur));

    // The closing side does not exist as an edge before the fill — that is
    // the whole premise, asserted rather than assumed.
    assert(m.edgeIndex(barA[1], barB[0]) == ~0u, "setup: no closing edge may exist yet");
    assert(m.edgeIndex(barA[2], barB[3]) == ~0u, "setup: nor the other one");
    immutable size_t e0 = m.edges.length;

    // The seed really is bar A's facing edge, not a vertex press.
    immutable int seed = t.fillSeedEdge(cast(int)cur.x, cast(int)cur.y, vp);
    assert(seed >= 0, "the press must classify as a BORDER-EDGE press");
    assert((m.edges[seed][0] == barA[1] && m.edges[seed][1] == barA[2])
        || (m.edges[seed][0] == barA[2] && m.edges[seed][1] == barA[1]),
        "the seed must be bar A's facing edge");

    auto ring = t.findFillRing(cast(int)cur.x, cast(int)cur.y, vp);
    assert(ring.length == 4, "the measured rule bridges the gap — the old rule declined here");

    // SEEDS OCCUPY SLOTS 0 AND 1, in the EDGE'S OWN STORED ORDER (measured:
    // not sorted, not cursor-relative). The old rule put the seed edge's two
    // endpoints in slots 1 and 2, so this line alone fails on it.
    assert(ring[0] == m.edges[seed][0] && ring[1] == m.edges[seed][1],
        "slots 0 and 1 are the pressed edge's endpoints, in the edge's own stored order");

    assert(canFind(ring, barB[0]) && canFind(ring, barB[3]),
        "the two corners of the OTHER, disconnected bar must be the other two slots");

    t.commitFill(ring);
    assert(m.faces.length == 3, "the bridge must be built as exactly one new facet");
    assert(m.vertices.length == 8, "Dv=0 — a bridge reuses existing corners");
    assert(m.edges.length == e0 + 2, "De=+2 — both closing sides are created by the build");
    assert(history.canUndo(), "a real fill records one undo entry");
}

// `range` is a GATHER multiplier and nothing else: below the rig's own
// threshold the press refuses, above it builds, and FURTHER above it builds
// THE SAME THING — the four-nearest cap absorbs the extra reach. Measured as
// a ratio, so it needs no camera model; here it needs no pixel arithmetic
// either, only the same rig at three settings.
//
// FAILS ON THE OLD RULE, which had no reach of any kind (it was purely
// topological) and therefore could not vary with this attribute at all.
unittest {
    import std.algorithm : canFind;

    auto t = new TopologyPenTool();
    uint[4] barA, barB;
    Mesh m = makeFillBridgeRig(barA, barB);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectPt(Vec3(-0.05f, 0, 0), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    // Below the threshold: the seeds are ~0.25 from the cursor and the far
    // bar's corners ~0.32, so a multiplier of 1 cannot reach them.
    t.fillRange_ = 1.0f;
    assert(t.findFillRing(cx, cy, vp).length == 0,
        "below the rig's own threshold the gesture refuses — only the two seeds are in reach");

    t.fillRange_ = 1.5f;
    auto atDefault = t.findFillRing(cx, cy, vp);
    assert(atDefault.length == 4, "above the threshold it builds");

    // Well above: bar A's far corners and bar B's far corners all come into
    // reach, and the answer does not move. Two independent reasons, both
    // measured — the reject discards anything on the far side of the seed's
    // own polygon, and the nearest-four cap evicts whatever is left over.
    t.fillRange_ = 3.0f;
    auto atTriple = t.findFillRing(cx, cy, vp);
    assert(atTriple == atDefault,
        "more reach changes NOTHING once the cap absorbs it — same ring, same order");
    assert(!canFind(atTriple, barA[0]) && !canFind(atTriple, barA[3]),
        "the seed bar's own far corners are never picked up, however wide the reach");

    // Zero reach is the extreme of the same law, not a special case.
    t.fillRange_ = 0.0f;
    assert(t.findFillRing(cx, cy, vp).length == 0, "range 0 gathers nothing — refuse");
}

// An ISOLATED vertex — one on no polygon at all — is a legal corner, and it
// BEATS the gap's own far corners when it is nearer. Measured directly, with
// the candidate's polygon count of 0 printed beside it, and built into armed
// rings 150 times over.
//
// FAILS ON THE OLD RULE twice over: that rule enumerated candidates as
// BORDER-EDGE NEIGHBOURS of the seed's endpoints, so a vertex with no
// polygon (and therefore no border edge) could never be reached at all, and
// on this rig it returns the hole's own four corners instead.
//
// Also pins the ORDER contract, which is a second thing the old rule got
// wrong: the pressed edge's two endpoints are slots 0 and 1 IN THE EDGE'S OWN
// STORED ORDER (the old rule put them in slots 1 and 2), and the returned
// array is the cyclic order the shape test ACCEPTED — asserted as "this order
// is screen-convex and the slot-2/3 swap of it is not", which pins the
// two-order search without depending on which of the two won.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);
    uint[] holeVerts = m.faces[4].dup;          // the centre cell's own 4 corners
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);

    // Two vertices INSIDE the hole, on no polygon whatsoever — nearer to the
    // cursor than the hole's own far corners, and far enough from it that the
    // press still resolves an EDGE and not a vertex.
    immutable uint isoL = m.addVertex(Vec3(-0.28f, 0,  0.28f));
    immutable uint isoR = m.addVertex(Vec3( 0.28f, 0,  0.28f));
    assert(m.vertices.length == 18);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectPt(Vec3(0, 0, -0.05f), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    immutable int seed = t.fillSeedEdge(cx, cy, vp);
    assert(seed >= 0, "an isolated vertex sitting farther than the border edge must not "
                    ~ "steal the press");

    auto ring = t.findFillRing(cx, cy, vp);
    assert(ring.length == 4);
    assert(ring[0] == m.edges[seed][0] && ring[1] == m.edges[seed][1],
        "slots 0 and 1 are the pressed edge's endpoints, in the edge's own stored order");
    assert(canFind(ring, isoL) && canFind(ring, isoR),
        "BOTH isolated vertices are corners — they are the two nearest survivors");

    // The hole's own FAR corners lose to them, which is what makes this a
    // ranking result and not merely "isolated vertices are allowed".
    uint[] farCorners;
    foreach (v; holeVerts)
        if (v != ring[0] && v != ring[1]) farCorners ~= v;
    assert(farCorners.length == 2, "setup: the seed edge accounts for two of the four corners");
    foreach (v; farCorners)
        assert(!canFind(ring, v),
            "the gap's own far corners are FARTHER than the isolated pair and must be evicted");

    // The returned array IS the accepted cyclic order: convex as returned,
    // and not convex with slots 2 and 3 exchanged. Exactly one of the two
    // orders the search tries can hold, so this pins the search's output
    // without depending on which one won.
    ImVec2[4] sp;
    foreach (k; 0 .. 4) assert(TopologyPenTool.projectPt(m.vertices[ring[k]], vp, sp[k]));
    assert(TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[2], sp[3]),
        "the returned order is the one the shape test accepted");
    assert(!TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[3], sp[2]),
        "and the other of the two tried orders is the one it rejected");

    immutable size_t e0 = m.edges.length;
    t.commitFill(ring);
    assert(m.faces.length == 9, "exactly one facet is built");
    assert(m.vertices.length == 18, "Dv=0 — the isolated vertices are REUSED as corners");
    assert(m.edges.length == e0 + 3,
        "De=+3 — three of the four sides did not exist, and a fill creates them");
    assert(history.canUndo());
}

// THE SCREEN-CROSSING REJECT, isolated by the one experiment that isolates
// it: the SAME rig, the SAME seed edge, the SAME two candidates in reach, and
// the cursor moved across that edge. Outside the gap the candidates are on
// the far side of the seed's own polygon and every one of them is rejected —
// the press refuses. Inside the gap nothing is in the way and the same two
// build the facet.
//
// The reach is asserted, not assumed, on the refusing side: the candidate IS
// within the gather radius and is dropped anyway, so nothing but the reject
// can account for it. Without this clause a distance ranking picks different
// corners on three quarters of all searches, which is why it is tested as its
// own contrast pair rather than folded into another rig.
unittest {
    import mesh : makeGridPlane;
    import std.algorithm : canFind;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);

    // Two isolated vertices just INSIDE the hole, near its bottom side.
    immutable uint isoR = m.addVertex(Vec3( 0.15f, 0, -0.15f));
    immutable uint isoL = m.addVertex(Vec3(-0.15f, 0, -0.15f));

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;
    auto vp = makeGridPlaneTestViewport();

    // OUTSIDE the gap, just past the hole's bottom border edge.
    ImVec2 outside;
    assert(TopologyPenTool.projectPt(Vec3(0, 0, -0.36f), vp, outside));
    immutable int ox = cast(int)outside.x, oy = cast(int)outside.y;

    immutable int seedOut = t.fillSeedEdge(ox, oy, vp);
    assert(seedOut >= 0, "the press outside the gap still resolves the same border edge");

    // The reach covers the candidates — so the refusal below is NOT a reach
    // refusal. Computed from the very law the search uses.
    ImVec2 pa, pb, pIso;
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[seedOut][0]], vp, pa));
    assert(TopologyPenTool.projectPt(m.vertices[m.edges[seedOut][1]], vp, pb));
    assert(TopologyPenTool.projectPt(m.vertices[isoR], vp, pIso));
    immutable float reach =
        1.5f * TopologyPenTool.fillHoverRadiusPx(cast(float)ox, cast(float)oy, pa, pb);
    assert(hypot(pIso.x - ox, pIso.y - oy) < reach,
        "setup: the candidate is comfortably INSIDE the gather radius");

    assert(t.findFillRing(ox, oy, vp).length == 0,
        "every candidate is on the far side of the seed's own polygon — all rejected, refuse");

    // INSIDE the gap, 0.06 world units away, same seed edge, same reach.
    ImVec2 inside;
    assert(TopologyPenTool.projectPt(Vec3(0, 0, -0.30f), vp, inside));
    immutable int ix = cast(int)inside.x, iy = cast(int)inside.y;
    immutable int seedIn = t.fillSeedEdge(ix, iy, vp);
    assert(seedIn == seedOut, "setup: the pair must differ ONLY in which side of the edge "
                             ~ "the cursor is on");

    auto ring = t.findFillRing(ix, iy, vp);
    assert(ring.length == 4, "with nothing in the way the same two candidates build the facet");
    assert(canFind(ring, isoR) && canFind(ring, isoL),
        "and they are exactly the two that were rejected from the other side");

    ImVec2[4] sp;
    foreach (k; 0 .. 4) assert(TopologyPenTool.projectPt(m.vertices[ring[k]], vp, sp[k]));
    assert(TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[2], sp[3]),
        "the returned order is the accepted one");
}

// THE COUNT GATE, and the triangle it lets through. A rig that reaches
// exactly THREE: with `quadOnly` on the press refuses; with it off the same
// press builds a TRIANGLE, and the three-path runs no shape test at all.
//
// FAILS ON THE OLD RULE, which had no count gate, no attribute, and could
// only ever return four corners or nothing.
version (unittest) private Mesh makeFillTripleRig(out uint[4] bar, out uint loose) {
    Mesh m;
    bar[0] = m.addVertex(Vec3(-0.6f, 0, -0.2f));
    bar[1] = m.addVertex(Vec3(-0.2f, 0, -0.2f));
    bar[2] = m.addVertex(Vec3(-0.2f, 0,  0.2f));
    bar[3] = m.addVertex(Vec3(-0.6f, 0,  0.2f));
    m.addFace([bar[0], bar[1], bar[2], bar[3]]);
    loose  = m.addVertex(Vec3(0.2f, 0, 0));      // isolated, on no polygon
    m.buildLoops();
    return m;
}

unittest {
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] bar; uint loose;
    Mesh m = makeFillTripleRig(bar, loose);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectPt(Vec3(-0.05f, 0, 0), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    assert(t.fillQuadOnly_, "the measured default is ON");
    assert(t.findFillRing(cx, cy, vp).length == 0,
        "three in reach and quads-only: the count gate refuses");

    t.fillQuadOnly_ = false;
    auto tri = t.findFillRing(cx, cy, vp);
    assert(tri.length == 3, "with the gate off, exactly three is a build");
    immutable int seed = t.fillSeedEdge(cx, cy, vp);
    assert(tri[0] == m.edges[seed][0] && tri[1] == m.edges[seed][1],
        "the pressed edge is still slots 0 and 1 — and still a side of the facet");
    assert(tri[2] == loose, "the third corner is the one candidate in reach");

    immutable size_t e0 = m.edges.length;
    t.commitFill(tri);
    assert(m.faces.length == 2, "a TRIANGLE is built");
    assert(m.faces[1].length == 3);
    assert(m.vertices.length == 5, "Dv=0");
    assert(m.edges.length == e0 + 2, "De=+2 — the two new sides");
    assert(history.canUndo());
}

// A REFUSAL IS DESTRUCTIVE. The shipped behaviour was a clean no-op; the
// measured one grabs the pressed border edge and moves it. Ported as an arm
// of this tool's own Move gesture on that edge, so the drag and the release
// run the already-measured Move law and the whole thing undoes in one step.
//
// FAILS ON THE OLD RULE, whose `fillDown` armed nothing whatsoever on a miss.
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] bar; uint loose;
    Mesh m = makeFillTripleRig(bar, loose);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectPt(Vec3(-0.05f, 0, 0), vp, cur));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)cur.x; e.y = cast(int)cur.y;

    immutable int seed = t.fillSeedEdge(e.x, e.y, vp);
    assert(seed >= 0);
    immutable size_t f0 = m.faces.length;

    // quads-only ON: the search refuses at three, and the press falls
    // through to grabbing the pressed border edge.
    assert(t.onPlainLmbDown(e, vts), "a Fill press is always consumed");
    assert(t.moveArmed_, "the refusal must GRAB the pressed edge, not do nothing");
    assert(t.moveElem_ == MoveElem.Edge, "and it grabs an EDGE, never a vertex or a face");
    assert(t.moveVerts_.length == 2
        && canFind(t.moveVerts_, m.edges[seed][0]) && canFind(t.moveVerts_, m.edges[seed][1]),
        "the grabbed set is exactly the PRESSED border edge's two endpoints");
    assert(m.faces.length == f0, "the press itself mutates nothing — the move writes on drag");
    assert(!history.canUndo(), "and records nothing until the release");
    assert(!t.placeArmed_, "Fill never falls through to PLACE");
    t.resetAllGestureArms();

    // quads-only OFF: the same press builds instead, and arms nothing.
    t.fillQuadOnly_ = false;
    assert(t.onPlainLmbDown(e, vts));
    assert(m.faces.length == f0 + 1, "a resolved ring commits on DOWN");
    assert(!t.moveArmed_, "a press that BUILT must not also grab the edge");
}

// ---------------------------------------------------------------------------
// Plain-LMB press on an EDGE -> arms an EDGE move, and NEVER Place
// (task 0484, superseding doc/tasks/done/0482-topopen-move-nonvertex.md).
//
// The regression class 0482 closed: `onPlainLmbDown` resolved its Move target
// with `findSourceVertex` (VERTICES only), so a press aimed at an EDGE
// resolved nothing and fell through to Place — the release then committed a
// stray `mesh.addVertex` at the background-snapped cursor point. 0482 fixed
// that by DECLINING the press, because what an edge press should do was
// unmeasured at the time. 0484 measures it: the press grabs the edge and
// moves it. The half this test still pins unchanged is the important one —
// such a press must never, ever arm Place.
//
// The mesh-level proof (the edge's two endpoints actually move, one undo
// entry) needs a real background surface + GL and lives in the HTTP test
// (tests/test_topopen_move_nonvertex_decline.d).
//
// Pixel = the SCREEN-SPACE midpoint of grid edge 0-1: distance 0 from that
// projected segment by construction, while `makeGridPlane(3)`'s cell is ~53px
// wide under `makeGridPlaneTestViewport` so both endpoints sit ~26px away —
// outside the pen's press-pick reach (`topoPenPressPickPx`, 8px at scale 1).
// Asserted below rather than assumed, so a future viewport/grid change cannot
// silently turn this into a Move test.
// `pickPrimaryFace` answers -1 here (no `gpu_` under a bare `dub test`), so
// this exercises the EDGE term of the gate in isolation.
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1), "setup: v1 must project");
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)mid.x; e.y = cast(int)mid.y;

    // Setup precondition: the press pixel must be OUTSIDE snap range of every
    // vertex, or this would be testing Move, not the edge/face fall-through.
    assert(t.findSourceVertex(e.x, e.y, vp) < 0,
        "setup: the edge-midpoint pixel must resolve NO vertex within topoPenPressPickPx");
    assert(t.findRingSeedEdge(e.x, e.y, vp) >= 0,
        "setup: the edge-midpoint pixel must resolve the edge itself");
    assert(hypot(mid.x - p0.x, mid.y - p0.y) > topoPenPressPickPx(vp),
        "setup: the midpoint must be farther than the snap radius from endpoint 0");

    immutable size_t vBefore = m.vertices.length;
    immutable size_t eBefore = m.edges.length;
    immutable size_t fBefore = m.faces.length;

    assert(t.penMode_ == PenMode.Move, "setup: must be in the default Move mode");
    immutable int seedEdge = t.findRingSeedEdge(e.x, e.y, vp);
    bool consumed = t.onPlainLmbDown(e, vts);

    assert(consumed, "a plain-LMB press on an EDGE must be consumed — it grabs the edge");
    assert(!t.placeArmed_,
        "a press on an existing edge must NOT arm Place — that is the stray-vertex defect");
    assert(t.moveArmed_, "the press must arm a Move");
    assert(t.moveElem_ == MoveElem.Edge, "the grabbed element must be the EDGE, not a vertex");
    assert(t.grabbedVert_ < 0,
        "`grabbedVert` names a single grabbed VERTEX — an edge grab must leave it -1");
    assert(t.moveVerts_.length == 2, "an edge move drags exactly its two endpoints");
    assert(t.moveVerts_[0] == m.edges[seedEdge][0] && t.moveVerts_[1] == m.edges[seedEdge][1],
        "the moving set must be the picked edge's own endpoints");
    assert(t.moveBase_.length == 2
        && t.moveBase_[0] == m.vertices[t.moveVerts_[0]]
        && t.moveBase_[1] == m.vertices[t.moveVerts_[1]],
        "the arm must snapshot the endpoints' CURRENT positions as the drag's origin");
    assert(!t.moveDirty_, "arming alone must not count as a mutation");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore
        && m.faces.length == fBefore, "the press itself must not mutate the mesh");

    // A release with no intervening motion is still a no-op: the targets land
    // back on the base positions (no background surface here, so every
    // re-snap misses and keeps its original), so nothing is written and no
    // undo entry is recorded. Consumed, because the gesture WAS armed.
    assert(t.lmbPlaceOrMoveUp(e, vts), "the release of an armed Move is consumed");
    assert(!t.moveArmed_ && t.moveElem_ == MoveElem.None, "the release must disarm");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore
        && m.faces.length == fBefore, "a stationary edge grab must not mutate the mesh");
}

// ---------------------------------------------------------------------------
// The LIVE drag is ABSOLUTE, not incremental (task 0484, the compounding
// hazard). Every motion event recomputes its targets from `moveBase_` — the
// positions captured at ARM time — so N events at the same cursor position
// land the set in the same place as one, and a stream of events walking to a
// pixel lands it where a single event straight to that pixel would.
//
// If the targets were ever computed from the LIVE positions instead, each
// event would stack its delta onto the previous event's result and the
// element would race away from the cursor at a rate set by the event density
// — the classic bug this pins shut. Driven directly through the Vertex law
// (no background surface needed: `readHit` misses, so the target is the base
// position and the write is a no-op) plus a direct `perVertexTargetsFrom`
// comparison for the set law.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Arm an EDGE grab by hand (the pick itself is covered above).
    t.moveArmed_  = true;
    t.moveElem_   = MoveElem.Edge;
    t.moveVerts_  = [m.edges[0][0], m.edges[0][1]];
    t.moveBase_   = [m.vertices[t.moveVerts_[0]], m.vertices[t.moveVerts_[1]]];
    t.moveStartX_ = 100;
    t.moveStartY_ = 100;

    // The same cursor, asked twice, must answer twice the same — even after
    // the first answer has been written into the mesh.
    auto first = t.moveTargets(180, 140, vp, vts);
    t.applyMoveTargets(first);
    auto second = t.moveTargets(180, 140, vp, vts);
    assert(first.length == second.length, "target count must not depend on the live mesh");
    foreach (i, v; first)
        assert((v - second[i]).length < 1e-6f,
            "a repeated motion event must recompute the SAME target — targets are absolute, "
          ~ "computed from the arm-time base, never from the already-moved positions");

    // And the delta itself is measured from the PRESS pixel, not the previous
    // event's: the law is `perVertexTargetsFrom(base, cursor - press)`.
    auto direct = t.perVertexTargetsFrom(t.moveBase_, 180 - 100, 140 - 100, vp);
    foreach (i, v; direct)
        assert((v - first[i]).length < 1e-6f,
            "the set law must be the shared screen delta from the press pixel");
}

// ---------------------------------------------------------------------------
// The click-vs-drag gate on the SET law (task 0484): a press-and-release
// under `kMinDragPx` leaves the element exactly where it was. Without it a
// bare click would apply a ZERO delta — which is not a no-op, since each
// vertex would then re-snap to whatever background surface sits under its own
// pixel — and clicking an edge would yank it onto the background. Inherited
// with the law from Move Loop, whose `moveLoopUp` carries the same gate.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    t.moveArmed_  = true;
    t.moveElem_   = MoveElem.Edge;
    t.moveVerts_  = [m.edges[0][0], m.edges[0][1]];
    t.moveBase_   = [m.vertices[t.moveVerts_[0]], m.vertices[t.moveVerts_[1]]];
    t.moveStartX_ = 200;
    t.moveStartY_ = 200;

    // 2px away — inside the gate.
    auto held = t.moveTargets(201, 201, vp, vts);
    assert(held.length == 2);
    foreach (i, v; held)
        assert((v - t.moveBase_[i]).length < 1e-9f,
            "a sub-threshold drag must leave every vertex on its arm-time position");

    // 10px away — through the gate, so the law runs (and, with no background
    // surface in this fixture, every re-snap misses and keeps its original —
    // which is the documented miss policy, not the gate).
    t.moveStartX_ = 200; t.moveStartY_ = 200;
    auto moved = t.moveTargets(210, 200, vp, vts);
    assert(moved.length == 2, "past the gate the law still answers one target per vertex");
}

// The guard's CONTROL: Place must still arm on genuinely empty space. Same
// tool, same viewport, a mesh of two ISOLATED vertices (no edges, no faces)
// and a press ~70px clear of both — nothing for `overPrimaryEdgeOrFace` to
// find, so the press is a placement exactly as before. Without this, a guard
// that declined EVERY non-vertex press would look "fixed" while having killed
// Point mode's placement gesture. Runs in Point mode explicitly — the
// default Move mode DECLINES an empty-space press, which is the very
// distinction between the two modes (task 0483).
unittest {
    import toolpipe.packets : SubjectPacket;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // A pixel 70px from v0 (and farther still from v1, which projects on the
    // opposite side of the grid) — clear of the press-pick reach.
    SDL_MouseButtonEvent e;
    e.x = cast(int)(p0.x + 70.0f); e.y = cast(int)p0.y;
    assert(t.findSourceVertex(e.x, e.y, vp) < 0,
        "setup: the probe pixel must resolve no vertex");
    assert(m.edges.length == 0, "setup: an isolated-vertex mesh must have no edges");

    t.penMode_ = PenMode.Point;
    assert(t.onPlainLmbDown(e, vts), "a press on empty space must still be consumed");
    assert(t.placeArmed_, "a press on empty space must still arm Place");
    assert(!t.moveArmed_, "a press on empty space must not arm Move");

    // ... and the SAME press in Move mode places nothing: Move has nothing to
    // move out there, and placing is Point's job (live-measured reference
    // split — toolcards/topology_pen/attr_defaults_capture.md, PRIVATE).
    t.resetAllGestureArms();
    t.penMode_ = PenMode.Move;
    assert(!t.onPlainLmbDown(e, vts), "Move mode must DECLINE a press on empty space");
    assert(!t.placeArmed_ && !t.moveArmed_, "Move mode must arm nothing on empty space");
}

// `toolStateJson().penMode` — the Mode dropdown's readback
// (doc/tasks/work/0482-topopen-move-nonvertex.md item 2): the wire tag, not
// the raw ordinal, and single-sourced from `penModeTable` so it tracks the
// `Param.intEnum_` schema and the `tool.attr mesh.topoPen mode <tag>` write.
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert("penMode" in s0, "toolStateJson must publish penMode");
    assert(s0["penMode"].str == "move", "the default mode must report the \"move\" wire tag");

    // Every value round-trips through the SAME table the Param publishes, so
    // the readback cannot drift from the tag `tool.attr` accepts.
    static immutable string[8] tags =
        ["move", "duplicate", "remove", "split", "addLoop", "point", "fill", "smooth"];
    foreach (i, tag; tags) {
        t.penMode_ = cast(PenMode) i;
        assert(t.toolStateJson()["penMode"].str == tag,
            "mode " ~ tag ~ " must report its own wire tag");
    }

    // The two dropdown-adjacent flags are published alongside it (task 0483).
    t.penMode_ = PenMode.Move;
    auto s1 = t.toolStateJson();
    assert(s1["edgeLoop"].type == JSONType.false_ && s1["edgeSlide"].type == JSONType.false_,
        "both flags must start OFF in the readback");
    assert(s1["lmbAction"].str == "place_or_move",
        "a fresh tool must report the neutral LMB action");
    t.edgeLoop_ = t.edgeSlide_ = true;
    auto s2 = t.toolStateJson();
    assert(s2["edgeLoop"].type == JSONType.true_ && s2["edgeSlide"].type == JSONType.true_,
        "the readback must track the flags");

    // Keep Vertices (task 0494) is published too — it decides what a Remove
    // click destroys, so a run has to be able to read the branch back.
    assert(s1["keepVertex"].type == JSONType.false_,
        "keepVertex must read back OFF on a fresh tool — the measured default");
    t.keepVertex_ = true;
    assert(t.toolStateJson()["keepVertex"].type == JSONType.true_,
        "the readback must track keepVertex");
}

// ---------------------------------------------------------------------------
// Slide decline diagnostics — the two declines are DISTINGUISHABLE, and the
// record's lifecycle (doc/tasks/work/0482-topopen-move-nonvertex.md item 3
// follow-up). `makeGridPlane(3)` carries both shapes:
//   * edge 0-1 — a boundary edge whose endpoint 0 is a valence-2 corner, so
//     that rail resolves and the press ARMS (reason "none");
//   * edge 5-6 — an interior edge between two valence-4 vertices, so BOTH
//     endpoints hit the "2+ distinct continuation candidates" open case and the
//     press declines with NoContinuation, naming the seed;
//   * a pixel far from every edge declines with NoEdge and names nothing.
// The lifecycle assertions are the part an HTTP test cannot reach: the record
// must SURVIVE a later unrelated LEFT press (`resetAllGestureArms` runs before
// every one of them and must NOT erase it, or a consumer reading state after
// the fact sees "none") while `resyncSession` MUST clear it (its seed is an
// edge index an external history navigation can delete).
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    ImVec2 pixOf(uint a, uint b) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectPt(m.vertices[a], vp, pa), "setup: endpoint must project");
        assert(TopologyPenTool.projectPt(m.vertices[b], vp, pb), "setup: endpoint must project");
        return ImVec2((pa.x + pb.x) * 0.5f, (pa.y + pb.y) * 0.5f);
    }

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Baseline: nothing pressed yet.
    assert(t.slideDecline_ == SlideDecline.None, "a fresh tool must record no decline");
    assert(t.slideDeclineSeed_ == -1, "a fresh tool must record no declined seed");

    // --- NoEdge: a pixel far off the grid entirely.
    SDL_MouseButtonEvent far;
    far.x = -5000; far.y = -5000;
    assert(!t.onCtrlLmbDown(far, vts), "a Ctrl+LMB press with no edge in range must decline");
    assert(t.slideDecline_ == SlideDecline.NoEdge,
        "a pick miss must be recorded as NoEdge");
    assert(t.slideDeclineSeed_ == -1, "a pick miss resolved no edge, so it names none");
    assert(!t.slideArmed_, "a pick miss must not arm Slide");

    // --- NoContinuation: the interior edge 5-6 (both endpoints valence-4).
    immutable uint kA = 5, kB = 6;
    immutable uint iEdge = m.edgeIndex(kA, kB);
    assert(iEdge != ~0u, "setup: grid edge 5-6 must exist");
    assert(TopologyPenTool.continuationNeighbor(&m, kA, kB) < 0
        && TopologyPenTool.continuationNeighbor(&m, kB, kA) < 0,
        "setup: edge 5-6 must be the both-endpoints-unresolved shape this case is about");

    auto ip = pixOf(kA, kB);
    SDL_MouseButtonEvent interior;
    interior.x = cast(int)ip.x; interior.y = cast(int)ip.y;
    assert(!t.onCtrlLmbDown(interior, vts),
        "the interior edge must still DECLINE (the shipped hold-fixed contract)");
    assert(t.slideDecline_ == SlideDecline.NoContinuation,
        "an edge that resolved but has no rail at either end must be NoContinuation, NOT NoEdge");
    assert(t.slideDeclineSeed_ == cast(int)iEdge,
        "the declined record must name the edge that WAS resolved");
    assert(!t.slideArmed_ && t.slideSeed_ == -1,
        "`slideSeed_` keeps its ARMED-gesture meaning and must stay -1 on a decline");

    // Lifecycle 1: a later unrelated LEFT press fires `resetAllGestureArms()`
    // via the dispatch reset hook, which must NOT erase this record.
    t.resetAllGestureArms();
    assert(t.slideDecline_ == SlideDecline.NoContinuation && t.slideDeclineSeed_ == cast(int)iEdge,
        "resetAllGestureArms must NOT clear the decline record — it runs before every LEFT "
      ~ "press, and erasing it there would hide the outcome a consumer is about to read");
    assert(!t.anyGestureArmed(),
        "the decline record must not register as an armed gesture (it would gate the hover "
      ~ "indicator)");

    // Lifecycle 2: an external history navigation MUST clear it — the seed is
    // an edge index the navigation can delete.
    t.resyncSession();
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "resyncSession must clear the decline record rather than publish a stale edge index");

    // --- None: the boundary edge 0-1 arms (endpoint 0 is a valence-2 corner).
    assert(TopologyPenTool.continuationNeighbor(&m, 0, 1) >= 0,
        "setup: grid vertex 0 is a valence-2 corner, so its rail must resolve");
    auto bp = pixOf(0, 1);
    SDL_MouseButtonEvent boundary;
    boundary.x = cast(int)bp.x; boundary.y = cast(int)bp.y;
    assert(t.onCtrlLmbDown(boundary, vts), "a press with a resolvable rail must arm and consume");
    assert(t.slideArmed_, "the boundary-edge press must arm Slide");
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "an ARMED press must record no decline (a stuck-at-NoEdge field would otherwise be "
      ~ "indistinguishable from a working one)");

    // Lifecycle 3: deactivate clears the record, so it cannot bleed into the
    // next activation (or, in a shared test process, the next test).
    t.slideDecline_     = SlideDecline.NoContinuation;
    t.slideDeclineSeed_ = cast(int)iEdge;
    t.deactivate();
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "deactivate must clear the decline record");
}

// ---------------------------------------------------------------------------
// Task 0496 — the MEASURED PRESS-PICK reach, pinned at its BRACKET ENDS.
//
// This block is the pen-side pin of the press-pick query. It is written
// against the grid-plane viewport whose scale is hand-derivable (eye at y=5,
// fovY=90, 800x800 => 80 px per world unit, and `makeGridPlane`'s vertices sit
// on whole world units), so the probe pixels below land exactly where the
// comments say and the assertions do not round-trip through the code under
// test.
//
// WHAT IS PINNED, and what deliberately is NOT. The reference printed ONE
// press limit of 8.0, but the reach it delivered was only bracketed:
//
//     vertex : enumerated at 7.07px, not enumerated at 7.78px
//     edge   : enumerated at 7.00px, not enumerated at 8.85px
//
// So the probes are 7px (at/below both brackets' lower ends => must resolve)
// and 9px (above both brackets' upper ends => must not). Nothing here pins 8.0
// as a behavioural edge: the measurement does not locate the cut to better
// than a pixel, and a test that claimed otherwise would be inventing
// precision. The 8.0 VALUE is asserted at the end as the number we chose to
// carry, separately from the behaviour.
//
// FAILS ON THE SHIPPED BEHAVIOUR by construction: under the 15px gate this
// module carried until now, the 9px probes resolved the vertex and the edge.
// They are the near rim of the ~7px annulus in which our press disagreed with
// the reference's; the far rim (14px) is pinned by the annulus test below.
//
// Also pins the MEASURING POINT (task 0496's recorded, NOT-isolated
// divergence): both of these resolvers measure from the RAW CURSOR pixel,
// while `constraint.resolveHoverTarget` measures from the projected surface
// HIT. Unifying them is deferred (it changes what the pen resolves, not merely
// how far); this test makes our two origins explicit so neither can drift.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import constraint : topoPenPressPickPx, topoPenSnapAcceptPx, topoPenSnapGatherPx;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);          // 3x3 verts, 4 quads, 80px per cell here
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1), "setup: v1 must project");

    // --- vertex resolver, at both ends of the measured bracket ---
    immutable int inX  = cast(int)(p0.x + 7.0f), inY  = cast(int)p0.y;
    immutable int outX = cast(int)(p0.x + 9.0f), outY = cast(int)p0.y;
    // The probe distances are ASSERTED, not assumed: integer truncation of a
    // projected float could otherwise move a probe across the very bracket end
    // it is meant to sit on.
    assert(hypot(inX - p0.x, inY - p0.y) <= 7.07f,
        "setup: the near probe must sit at or inside the brackets' LOWER ends (7.07px / 7.00px)");
    assert(hypot(outX - p0.x, outY - p0.y) >= 8.85f,
        "setup: the far probe must sit at or beyond the brackets' UPPER ends (7.78px / 8.85px)");

    assert(t.findSourceVertex(inX, inY, vp) == 0,
        "a cursor 7px from a vertex is at the measured bracket's lower end and must resolve it");
    assert(t.findSourceVertex(outX, outY, vp) < 0,
        "a cursor 9px from every vertex is past the measured bracket and must resolve nothing "
      ~ "(the pre-fix 15px reach grabbed it — this is the annulus's near rim)");

    // --- edge resolver, same reach, no per-type threshold ---
    // PERPENDICULAR from edge 0-1's midpoint: 40px from either endpoint, and
    // the next parallel grid edge is 80px away, so edge 0-1 is unambiguous.
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
    immutable uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: grid edge 0-1 must exist");
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 7.0f), vp) == cast(int)e01,
        "a cursor 7px from an edge segment is inside the same measured reach and must resolve it "
      ~ "— the press-pick reach is type-uniform");
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) < 0,
        "a cursor 9px from every edge segment is past the measured bracket "
      ~ "(the pre-fix 15px reach grabbed it)");

    // --- the reach is one value, not a per-type family: the SAME distance
    // decides for a vertex and for an edge. 7px in, 9px out, both types.
    assert((t.findSourceVertex(inX, inY, vp) >= 0)
        == (t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 7.0f), vp) >= 0),
        "vertex and edge candidates must share ONE press-pick reach");
    assert((t.findSourceVertex(outX, outY, vp) >= 0)
        == (t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) >= 0),
        "and they must fall out of it together too");

    // The values themselves, asserted LAST on purpose: the behaviour above is
    // the claim, and it must be what breaks if the reach moves. A value check
    // placed first would mask the behavioural probes it is meant to explain.
    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick carries the one limit the reference printed, 8px at scale 1");
    // The drag-snap pair comes off the gesture's snap snapshot, which on a
    // freshly-constructed tool is the default configuration — so these still
    // pin the measured values, and they now pin them at their real source.
    assert(topoPenSnapAcceptPx(vp, t.dragSnap_) == 24.0f,
        "the drag-snap acceptance is a separate, wider radius — 24px at scale 1");
    assert(topoPenSnapGatherPx(vp, t.dragSnap_) == 40.0f,
        "and its gather is 40px, a ratio of 5/3 rather than the refuted 2x");
    assert(t.dragSnap_ == SnapPacket.init,
        "a pen that has seen no press runs on the default snap configuration, "
        ~ "which is what makes the pipeline-less paths behave as before");
}

// ---------------------------------------------------------------------------
// Task 0496 — THE ANNULUS. The single case that was divergent on main.
//
// Between the press-pick reach (~8px) and the 15px this tool shipped lies a
// ~7px annulus around every vertex and every edge in which our press took the
// element and the reference took the FACE underneath. Two of the reference's
// own cells sit squarely in it: a vertex at 14.0px and an edge at 9.0px, both
// of which produced no candidate of that type at all and resolved POLY.
//
// This test is that pair, at this module's own resolvers. Every probe here
// answered the OTHER way before this change — that is the point of the file.
//
// `pickPrimaryFace` needs `gpu_` and answers -1 under a bare `dub test`, so
// the "and the FACE wins instead" half cannot be asserted here; it is asserted
// through the HTTP path in tests/test_topopen_move_disambiguation.d, which has
// a real upload. What IS asserted here is the load-bearing half: the vertex
// and the edge are NOT candidates at those distances.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1), "setup: v1 must project");

    // --- the reference's own `P_vert14` cell: a vertex 14px away, nothing
    // else nearby. We grabbed it; the reference resolved the polygon.
    // The probe runs DIAGONALLY into the quad interior — 10px in each axis, so
    // 14.1px from v0 and 10px from each of the two grid edges leaving it. Both
    // of those are past the measured reach too, which is what makes this a
    // pure vertex-annulus probe rather than an edge grab in disguise.
    immutable int ax = cast(int)(p0.x + 10.0f), ay = cast(int)(p0.y + 10.0f);
    immutable float dV14 = hypot(ax - p0.x, ay - p0.y);
    assert(dV14 > 8.85f && dV14 < 20.0f,
        "setup: the probe must sit in the annulus — past the measured reach, well short of the "
      ~ "next vertex 80px along");
    assert(t.findRingSeedEdge(ax, ay, vp) < 0,
        "setup: no grid edge may be within the measured reach of the probe either, or this "
      ~ "would be an edge case wearing a vertex's clothes");
    assert(t.findSourceVertex(ax, ay, vp) < 0,
        "a press 14px from a vertex must NOT grab it: that is outside the measured press-pick "
      ~ "reach, and the reference resolved the polygon there. Before this fix our 15px gate "
      ~ "grabbed the vertex — a straight divergence, advertised by the hover highlight because "
      ~ "it shares this resolver");

    // --- the reference's own `P_edge9` cell: an edge 9px away.
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) < 0,
        "a press 9px from an edge must NOT grab it either — same annulus, same divergence");

    // --- and the hover highlight, which is the same answer by construction:
    // whatever `resolveGrabTarget` says is what the indicator paints, so the
    // annulus has to be closed on BOTH at once or the highlight lies.
    int idx = -12345;
    assert(t.resolveGrabTarget(ax, ay, vp, idx) == MoveElem.None,
        "the grab target 14px from a vertex must be None (no face term without gpu_) — the "
      ~ "highlight and the press must never name different elements");
    assert(idx < 0, "and it must publish no index");
}

// ---------------------------------------------------------------------------
// Task 0496 — Vertex > Edge > Face is MEASURED-POSITIVE. The OPPOSITE test.
//
// An earlier reading of the reference held that it takes ONE closest candidate
// across all types and applies the radius afterwards, which would make a
// vertex at 14px lose to an edge at 2px. Task 0496's `## Открыто` item №1 asked
// for a test pinning exactly that. The live run refuted it twice, on two
// independent cells: a vertex at 5.83px beat an edge at 3.00px AND a polygon at
// 0.00px, and a vertex at 7.07px beat an edge at 7.00px. Porting "one closest
// across types" would have been a regression, so this is the test that item
// asked for, INVERTED — and it is the guard against someone re-reading the old
// note and "fixing" the short circuit.
//
// Rig: `makeGridPlane(2)` down -Y, 80px per cell, so grid edge 0-1 is a
// horizontal screen segment from v0. The cursor sits 3px off that segment and
// 6.7px from v0 — the edge is strictly NEARER, both are inside the press-pick
// reach, and the VERTEX must win.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectPt(m.vertices[1], vp, p1), "setup: v1 must project");
    assert(p0.y == p1.y && p1.x > p0.x,
        "setup: grid edge 0-1 must be a horizontal screen segment running +x from v0");

    immutable int cx = cast(int)(p0.x + 6.0f), cy = cast(int)(p0.y + 3.0f);

    // The premise, measured on the fixture rather than assumed: the edge is
    // NEARER than the vertex, and both are inside the press-pick reach.
    immutable float dVert = hypot(cx - p0.x, cy - p0.y);
    assert(dVert > 3.0f && dVert <= 7.07f,
        "setup: the vertex must be FARTHER than the edge yet still inside the measured reach");
    immutable uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: grid edge 0-1 must exist");
    assert(t.findRingSeedEdge(cx, cy, vp) == cast(int)e01,
        "setup: the nearest edge at this pixel must be 0-1, ~3px away");
    assert(t.findSourceVertex(cx, cy, vp) == 0,
        "setup: v0 must still be a candidate at this pixel");

    int idx = -12345;
    assert(t.resolveGrabTarget(cx, cy, vp, idx) == MoveElem.Vertex,
        "a vertex inside the press-pick reach must beat a strictly NEARER edge — 'one closest "
      ~ "candidate across types' was measured-negative and must not be ported");
    assert(idx == 0, "and the resolved element must be v0 itself");
}

// ---------------------------------------------------------------------------
// Task 0496 — the MEASURED snap-candidate set (`innerSnap`).
//
// Three separate claims, three separate pins:
//
//   1. The predicates. `isEdgeInterior` / `isVertexInterior` classify a grid
//      exactly as the measured law does (>= 2 incident polygons = interior).
//   2. The SNAP TARGET honours them. Split's target vertex C — vibe3d's only
//      "which existing element does this drag land on" query — refuses an
//      interior vertex at the default `innerSnap = false` and accepts it when
//      the flag is on. FAILS ON THE OLD BEHAVIOUR: before 0496 the same drag
//      split the quad regardless.
//   3. The press-time PICK is deliberately NOT gated, and wire geometry is
//      deliberately NOT excluded. Both are regression pins (green before and
//      after); they exist because both are decisions with a stated reason, and
//      a silent change to either would be a measured regression rather than an
//      improvement.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;

    Mesh m = makeGridPlane(2);   // 3x3 verts / 4 quads: vertex 4 is the interior one
    Mesh* mp = &m;

    // (1) the predicates
    immutable uint eInterior = m.edgeIndex(1, 4);   // center-touching: 2 polygons
    immutable uint eBorder   = m.edgeIndex(0, 1);   // perimeter: 1 polygon
    assert(eInterior != uint.max && eBorder != uint.max, "setup: both grid edges must exist");
    assert(TopologyPenTool.isEdgeInterior(mp, eInterior),
        "an edge shared by two quads is interior");
    assert(!TopologyPenTool.isEdgeInterior(mp, eBorder),
        "a perimeter edge has one polygon and is NOT interior");
    assert(TopologyPenTool.isVertexInterior(mp, 4),
        "the grid's center vertex touches only interior edges");
    foreach (uint vi; [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u])
        assert(!TopologyPenTool.isVertexInterior(mp, vi),
            "every perimeter vertex touches at least one border edge");

    // (3a) wire geometry stays a candidate — the named extrapolation boundary.
    Mesh w;
    w.addVertex(Vec3(0, 0, 0));            // isolated: no incident edges at all
    w.addVertex(Vec3(1, 0, 0));
    w.addVertex(Vec3(2, 0, 0));
    w.addEdge(1, 2);                       // bare wire edge: zero polygons
    w.buildLoops();
    Mesh* wp = &w;
    assert(!TopologyPenTool.isVertexInterior(wp, 0),
        "an ISOLATED vertex is not interior — the measured predicate is about the interior, and "
      ~ "face-less geometry is outside its domain (see the filter's own note)");
    assert(!TopologyPenTool.isVertexInterior(wp, 1),
        "a wire-edge endpoint is not interior either");
    immutable uint wireEdge = w.edgeIndex(1, 2);
    assert(wireEdge != uint.max, "setup: the wire edge must exist");
    assert(!TopologyPenTool.isEdgeInterior(wp, wireEdge),
        "a zero-polygon wire edge is not interior");
}

// ---------------------------------------------------------------------------
// Task 0502 — the predicate above on a NON-MANIFOLD edge.
//
// The grid fixture cannot see this: there, "count off the faces" and "walk the
// half-edge rings" agree on every edge, so a green grid test says nothing about
// which one is under the predicate. Three quads sharing edge 0-1 separate them
// — the rings yield ONE face (they have no representation for the fan), the
// face scan yields three.
//
// The consequence was not academic. `isEdgeInterior` IS the border-only
// snap-candidate filter (`findRingSeedEdge`/`findSourceVertex` with
// `innerSnap` off), so a non-manifold edge — the most topologically suspect
// edge in the mesh — read as a plain border edge and was offered as a snap
// target, along with both its endpoints.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();
    Mesh* mp = &m;

    immutable uint fan = m.edgeIndex(0, 1);
    assert(m.edgePolygonCounts()[fan] == 3, "setup: three quads really do border it");
    assert(TopologyPenTool.isEdgeInterior(mp, fan),
        "FAILS ON THE OLD BEHAVIOUR: the ring walk returned ONE face here, so a "
      ~ "non-manifold edge classified as a BORDER edge and entered the "
      ~ "border-only snap-candidate set");
    assert(TopologyPenTool.isVertexInterior(mp, 0) == false,
        "vertex 0 still touches genuine border edges, so it is not interior — the "
      ~ "fix must not flip this by over-counting");

    // The array overload the two scans hoist is the same predicate, not a
    // second one that could drift.
    auto counts = m.edgePolygonCounts();
    foreach (uint ei; 0 .. cast(uint)m.edges.length)
        assert(TopologyPenTool.isEdgeInterior(counts, ei)
            == TopologyPenTool.isEdgeInterior(mp, ei),
            "the hoisted overload and the one-off overload must agree edge for edge");
}

// ---------------------------------------------------------------------------
// Task 0496, claim (2) + claim (3b): the Split snap target through the REAL
// dispatch path, and the press-time pick left alone.
//
// Rig: `makeGridPlane(2)` (3x3 verts / 4 quads) looked at down -Y. A plain-MMB
// press on corner vertex 0 arms Split; the release lands on the grid's INTERIOR
// center vertex 4, which shares quad (0,1,4,3) with it — so before 0496 this
// drag chord-split that quad. With `innerSnap` at its measured default the
// target is not a candidate and the release is a clean no-op; with `innerSnap`
// on, the same drag splits again.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    static struct Rig {
        TopologyPenTool t;
        Mesh* m;
        Viewport vp;
        VectorStack vts;
        SubjectPacket* subj;
    }

    // A fresh tool + mesh per case: Split MUTATES on success, so the two cases
    // cannot share a rig without the first one's cut changing the second's
    // topology (and its vertex indices).
    static Rig makeRig(bool innerSnap, Mesh* m) {
        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        *m = makeGridPlane(2);
        t.meshSrc_          = () => m;
        t.history_          = history;
        t.innerSnap_        = innerSnap;
        t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_split", "Topology Split",
                                                       MeshEditScope.Geometry);
        Rig r;
        r.t    = t;
        r.m    = m;
        r.vp   = makeGridPlaneTestViewport();
        r.subj = new SubjectPacket();
        r.subj.mesh     = m;
        r.subj.viewport = r.vp;
        r.vts.put(r.subj);
        return r;
    }

    static void driveSplit(ref Rig r, uint fromVert, uint toVert) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectPt(r.m.vertices[fromVert], r.vp, pa),
            "setup: the source vertex must project");
        assert(TopologyPenTool.projectPt(r.m.vertices[toVert], r.vp, pb),
            "setup: the target vertex must project");
        SDL_MouseButtonEvent down;
        down.button = SDL_BUTTON_MIDDLE;
        down.x = cast(int)pa.x; down.y = cast(int)pa.y;
        assert(r.t.onMouseButtonDown(down, r.vts), "a plain-MMB press on a vertex must consume");
        assert(r.t.splitArmed_, "a plain-MMB press on a vertex must arm Split");
        assert(r.t.splitSourceVert_ == cast(int)fromVert,
            "the press must arm the PRESSED vertex as the split source — the press-time pick is "
          ~ "NOT candidate-filtered, whatever innerSnap says");
        SDL_MouseButtonEvent up;
        up.button = SDL_BUTTON_MIDDLE;
        up.x = cast(int)pb.x; up.y = cast(int)pb.y;
        assert(r.t.onMouseButtonUp(up, r.vts), "a plain-MMB release must consume");
        assert(!r.t.splitArmed_, "the release must disarm Split whatever the outcome");
    }

    // --- default (innerSnap == false): the interior target is not a candidate.
    Mesh mOff;
    auto off = makeRig(false, &mOff);
    assert(TopologyPenTool.isVertexInterior(&mOff, 4),
        "setup: the grid's center vertex must be interior, or this case tests nothing");
    immutable size_t fBefore = mOff.faces.length;
    immutable size_t eBefore = mOff.edges.length;

    // The CLAIM first, end to end through the real dispatch, so it is the
    // assertion that breaks if the gate goes away.
    driveSplit(off, 0, 4);
    assert(mOff.faces.length == fBefore && mOff.edges.length == eBefore,
        "a Split whose target vertex is INTERIOR must be a clean no-op at the measured default "
      ~ "(before task 0496 this chord-split the quad)");

    // Then WHY: the press-time pick still sees that interior vertex — only the
    // SNAP TARGET is filtered (claim 3b).
    assert(off.t.findSourceVertex(cast(int)projectedX(&mOff, 4, off.vp),
                                 cast(int)projectedY(&mOff, 4, off.vp), off.vp) == 4,
        "the press-time pick must still resolve an INTERIOR vertex — the captures we hold show "
      ~ "the reference grabbing interior elements at this flag's default");
    assert(off.t.resolveSnapTargetVert(cast(int)projectedX(&mOff, 4, off.vp),
                                      cast(int)projectedY(&mOff, 4, off.vp), off.vp) < 0,
        "the SNAP TARGET must refuse the interior vertex at innerSnap = false");

    // --- innerSnap on: the very same drag splits.
    Mesh mOn;
    auto on = makeRig(true, &mOn);
    immutable size_t fBefore2 = mOn.faces.length;
    driveSplit(on, 0, 4);
    assert(mOn.faces.length == fBefore2 + 1,
        "with innerSnap on, the same corner-to-center drag must split the shared quad");
}

// ---------------------------------------------------------------------------
// Task 0496 — the DRAG-SNAP acceptance radius, measured at 24px, behaviourally.
//
// The press pick and the drag snap are two queries with two reaches, and this
// is the pin of the SECOND one. It goes through the real Split dispatch,
// because `resolveSnapTargetVert` is vibe3d's only "which existing element
// does this drag land on" query and Split's target vertex C is its only
// caller.
//
// Rig: `makeGridPlane(2)` down -Y, 80px per cell. Quad [1,2,5,4] has BORDER
// vertices 1 and 5 on its diagonal — both border, so `innerSnap` is not in
// play here and this case isolates the RADIUS. Vertex 5 projects with 80px of
// clear space to every other vertex, so a release offset from it can be read
// as a distance to v5 and nothing else.
//
//   release 20px from v5 -> INSIDE the measured 24px acceptance -> the drag
//                           lands on v5 and the chord splits the quad.
//   release 26px from v5 -> outside it -> clean no-op.
//
// FAILS ON THE SHIPPED BEHAVIOUR: this resolver used to share the press pick's
// constant (15px, and ~8px after this change), under which the 20px release
// resolved nothing and the split never happened.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import constraint : topoPenSnapAcceptPx;
    import std.math : hypot;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    // Split MUTATES on success, so each offset gets its own tool + mesh.
    // `snapPkt` is the SNAP configuration the press sees: null means "no SNAP
    // stage registered", the case every other assertion below runs, and the
    // one whose ranges must stay exactly what the pen used when it owned
    // private constants.
    static bool splitLands(float offsetPx, Mesh* m, out size_t facesBefore,
                           SnapPacket* snapPkt = null) {
        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        *m = makeGridPlane(2);
        t.meshSrc_          = () => m;
        t.history_          = history;
        t.innerSnap_        = false;         // the measured default, untouched
        t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_split", "Topology Split",
                                                       MeshEditScope.Geometry);
        auto vp = makeGridPlaneTestViewport();
        auto subj = new SubjectPacket();
        subj.mesh     = m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(subj);
        if (snapPkt !is null) vts.put(snapPkt);

        ImVec2 pa, pb;
        assert(TopologyPenTool.projectPt(m.vertices[1], vp, pa), "setup: v1 must project");
        assert(TopologyPenTool.projectPt(m.vertices[5], vp, pb), "setup: v5 must project");
        assert(!TopologyPenTool.isVertexInterior(m, 1) && !TopologyPenTool.isVertexInterior(m, 5),
            "setup: BOTH ends of this diagonal must be border vertices, so innerSnap is not the "
          ~ "thing under test here");

        facesBefore = m.faces.length;

        SDL_MouseButtonEvent down;
        down.button = SDL_BUTTON_MIDDLE;
        down.x = cast(int)pa.x; down.y = cast(int)pa.y;
        assert(t.onMouseButtonDown(down, vts), "a plain-MMB press on a vertex must consume");
        assert(t.splitArmed_ && t.splitSourceVert_ == 1, "and it must arm Split on v1");

        // Offset along +x from v5: the grid's next vertex in that direction is
        // off the mesh entirely, and every other vertex is >= 80px away.
        SDL_MouseButtonEvent up;
        up.button = SDL_BUTTON_MIDDLE;
        up.x = cast(int)(pb.x + offsetPx); up.y = cast(int)pb.y;
        assert(hypot(up.x - pb.x, up.y - pb.y) > offsetPx - 1.0f,
            "setup: the release must actually sit at the offset the case names");
        assert(t.onMouseButtonUp(up, vts), "a plain-MMB release must consume");
        return m.faces.length == facesBefore + 1;
    }

    Mesh mIn;
    size_t fIn;
    assert(splitLands(20.0f, &mIn, fIn),
        "a release 20px from the target vertex is INSIDE the measured 24px drag-snap acceptance "
      ~ "and must land on it, splitting the quad — before this fix the snap target shared the "
      ~ "press pick's constant and this release resolved nothing");

    Mesh mOut;
    size_t fOut;
    assert(!splitLands(26.0f, &mOut, fOut),
        "a release 26px away is outside the acceptance and must be a clean no-op");
    assert(mOut.faces.length == fOut && mOut.edges.length == 12,
        "and it must leave the grid untouched, not merely un-split");

    // The value last, as a label on the behaviour above rather than a
    // substitute for it. Note it is deliberately NOT the press-pick reach.
    auto vp = makeGridPlaneTestViewport();
    assert(topoPenSnapAcceptPx(vp, SnapPacket.init) == 24.0f,
        "the drag-snap acceptance is 24px at scale 1, its own measured number — "
        ~ "and it is the snap service's default inner range, not a constant the "
        ~ "pen keeps for itself");

    // THE DE-DUPLICATION, as behaviour: 24px is a CONFIGURED number, so a
    // press that sees a narrower configured acceptance must land differently
    // at the very same pixel. The 20px release above split the quad; with the
    // acceptance moved to 12px it is a clean no-op, and nothing else changed.
    // This is the assertion a re-introduced private constant fails.
    SnapPacket narrow;
    narrow.innerRangePx = 12.0f;
    Mesh mNarrow;
    size_t fNarrow;
    assert(!splitLands(20.0f, &mNarrow, fNarrow, &narrow),
        "the acceptance is snap CONFIGURATION, not a constant the pen owns: at a "
        ~ "12px inner range the same 20px release must stop landing");
    assert(mNarrow.faces.length == fNarrow && mNarrow.edges.length == 12,
        "and the declined split must leave the grid untouched");

    // ... and widening it the other way re-lands the release the default
    // rejected, so the pen is reading the number rather than merely being
    // gated by one.
    SnapPacket wide;
    wide.innerRangePx = 40.0f;
    Mesh mWide;
    size_t fWide;
    assert(splitLands(26.0f, &mWide, fWide, &wide),
        "and at a 40px inner range the 26px release the default rejected must land");
}

version (unittest) private float projectedX(Mesh* m, uint vi, const ref Viewport vp) {
    ImVec2 p;
    assert(TopologyPenTool.projectPt(m.vertices[vi], vp, p), "vertex must project");
    return p.x;
}

version (unittest) private float projectedY(Mesh* m, uint vi, const ref Viewport vp) {
    ImVec2 p;
    assert(TopologyPenTool.projectPt(m.vertices[vi], vp, p), "vertex must project");
    return p.y;
}

// ---------------------------------------------------------------------------
// Remove — the ELEMENT-CLASS dispatch, the edge loop, Keep Vertices and the
// border no-op (task 0494).
//
// Every number below is a measured cell on a 4x4 planar grid, which is what
// `makeGridPlane(3)` is (16v/24e/9f, vertex index 4*row + col), so these
// assertions are the capture rows and not a re-derivation of our own code.
//
// The presses go through `onPlainLmbDown` — the real router — rather than
// calling the primitives directly, because the DISPATCH is the thing that
// changed: before this task every one of these presses deleted a polygon.
// Each test first asserts WHICH element class the press latches, so a failure
// says "the aim moved" or "the outcome moved" rather than leaving the two
// indistinguishable.
// ---------------------------------------------------------------------------
version (unittest) private TopologyPenTool makeRemoveTestTool(Mesh* m, CommandHistory h) {
    import view : View;
    import editmode : EditMode;
    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    t.meshSrc_ = () => m;
    t.history_ = h;
    t.penMode_ = PenMode.Remove;
    // All three, with their own wire names — mirrors the app.d construction
    // site. Leaving one null would make its primitive a silent no-op and the
    // test would read as "the dispatch is wrong".
    t.removeEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_remove", "Topology Remove", MeshEditScope.Geometry);
    t.removeEdgeEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_removeedge", "Topology Remove Edge", MeshEditScope.Geometry);
    t.removeVertexEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_removevertex", "Topology Remove Vertex", MeshEditScope.Geometry);
    return t;
}

version (unittest) private SDL_MouseButtonEvent gridEdgeMidPixel(ref Mesh m, ref Viewport vp,
                                                                 uint a, uint b) {
    ImVec2 pa, pb;
    assert(TopologyPenTool.projectPt(m.vertices[a], vp, pa), "setup: endpoint projects");
    assert(TopologyPenTool.projectPt(m.vertices[b], vp, pb), "setup: endpoint projects");
    SDL_MouseButtonEvent e;
    e.x = cast(int)((pa.x + pb.x) * 0.5f);
    e.y = cast(int)((pa.y + pb.y) * 0.5f);
    return e;
}

version (unittest) private SDL_MouseButtonEvent gridVertPixel(ref Mesh m, ref Viewport vp, uint v) {
    ImVec2 p;
    assert(TopologyPenTool.projectPt(m.vertices[v], vp, p), "setup: vertex projects");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p.x;
    e.y = cast(int)p.y;
    return e;
}

version (unittest) private int gridVertAt(ref Mesh m, Vec3 p) {
    foreach (i, ref v; m.vertices)
        if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
    return -1;
}

unittest { // an EDGE-latched press DISSOLVES the edge — it does not remove a polygon
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    immutable uint seed = m.edgeIndex(5, 9);
    auto e = gridEdgeMidPixel(m, vp, 5, 9);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge && idx == cast(int)seed,
        "setup: the press must LATCH THE INTERIOR EDGE, or this measures the aim");

    assert(t.onPlainLmbDown(e, vts), "a Remove press is always consumed");

    assert(m.vertices.length == 16 && m.edges.length == 23 && m.faces.length == 8,
        "an edge-latched Remove dissolves ONE edge: 16/23/8. The pre-0494 behaviour "
      ~ "was 16/24/8 — one polygon gone, no edge — which is what this pins against");
    assert(m.edgeIndex(5, 9) == ~0u, "and it is the pressed edge that went");
    assert(m.edgeIndex(4, 5) != ~0u && m.edgeIndex(5, 6) != ~0u,
        "its neighbours are untouched");

    // The two quads it separated are now ONE hexagon, and nothing else moved.
    size_t hexes = 0;
    foreach (ref f; m.faces) {
        if (f.length == 4) continue;
        assert(f.length == 6, "the merge produces a hexagon, nothing else");
        ++hexes;
        uint[] got = f.dup;
        import std.algorithm : sort;
        got.sort();
        assert(got == [4u, 5u, 6u, 8u, 9u, 10u], "the union of the two incident quads");
    }
    assert(hexes == 1);
    assert(history.canUndo(), "a real removal records one undo entry");
}

unittest { // a VERTEX-latched press merges its whole fan and drops the vertex
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto pre = m.vertices.dup;
    auto e   = gridVertPixel(m, vp, 5);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Vertex && idx == 5,
        "setup: the press must LATCH THE VERTEX");

    assert(t.onPlainLmbDown(e, vts));

    assert(m.vertices.length == 15 && m.edges.length == 20 && m.faces.length == 6,
        "the four quads around vertex 5 become ONE 8-gon and only vertex 5 goes: 15/20/6");
    assert(gridVertAt(m, pre[5]) < 0, "the pressed vertex is gone");
    foreach (keep; [1, 4, 6, 9])
        assert(gridVertAt(m, pre[keep]) >= 0,
            "and ONLY it — the vertex primitive is not the edge path's fan rule, which "
          ~ "would also have taken 1 and 4 (13/18/6)");

    size_t bigs = 0;
    foreach (ref f; m.faces) if (f.length != 4) { assert(f.length == 8); ++bigs; }
    assert(bigs == 1, "exactly one 8-gon");
}

unittest { // a CORNER vertex (one incident polygon): the merge is vacuous and
           // the quad collapses to a triangle
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto pre = m.vertices.dup;
    auto e   = gridVertPixel(m, vp, 0);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Vertex && idx == 0,
        "setup: the press must LATCH THE CORNER VERTEX");

    assert(t.onPlainLmbDown(e, vts));

    assert(m.vertices.length == 15 && m.edges.length == 23 && m.faces.length == 9,
        "15/23/9 — the corner quad becomes a triangle and no polygon is lost");
    assert(gridVertAt(m, pre[0]) < 0);
    immutable int v1 = gridVertAt(m, pre[1]);
    immutable int v4 = gridVertAt(m, pre[4]);
    assert(v1 >= 0 && v4 >= 0 && m.edgeIndex(cast(uint)v1, cast(uint)v4) != ~0u,
        "the triangle's new edge closes across the removed corner");
    size_t tris = 0;
    foreach (ref f; m.faces) if (f.length == 3) ++tris;
    assert(tris == 1, "exactly one triangle");
}

unittest { // Edge Loop + Keep Vertices, both ways round, on an edge-latched press
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // Runs one Remove press with the given flags and hands the mesh back.
    static void press(ref Mesh m, bool loop, bool keepVertex, ref CommandHistory h) {
        auto vp = makeGridPlaneTestViewport();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_   = loop;
        t.keepVertex_ = keepVertex;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridEdgeMidPixel(m, vp, 5, 9);
        int idx;
        assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge
            && idx == cast(int)m.edgeIndex(5, 9), "setup: the press must latch the seed edge");
        assert(t.onPlainLmbDown(e, vts));
    }

    // Keep Vertices ON: the three loop edges dissolve, every vertex stays as a
    // corner of a merged hexagon.
    {
        Mesh m = makeGridPlane(3);
        auto h = new CommandHistory();
        press(m, /*loop*/true, /*keepVertex*/true, h);
        assert(m.vertices.length == 16 && m.edges.length == 21 && m.faces.length == 6,
            "16/21/6");
        assert(m.edgeIndex(1, 5) == ~0u && m.edgeIndex(5, 9) == ~0u
            && m.edgeIndex(9, 13) == ~0u,
            "the gather is the vertex-continuation loop through the seed — exactly "
          ~ "those three, which is also what refutes a perpendicular ring");
        assert(m.edgeIndex(4, 5) != ~0u && m.edgeIndex(5, 6) != ~0u,
            "and nothing perpendicular to it");
    }

    // Keep Vertices OFF — the measured DEFAULT: the four vertices whose whole
    // polygon fan the dissolve ate go with it, and their survivors re-stitch.
    {
        Mesh m   = makeGridPlane(3);
        auto pre = m.vertices.dup;
        auto h   = new CommandHistory();
        press(m, /*loop*/true, /*keepVertex*/false, h);
        assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
            "12/17/6 — this is what the tool now does by DEFAULT, where before this "
          ~ "task it kept the orphans unconditionally (the Keep-Vertices-ON branch)");
        foreach (gone; [1, 5, 9, 13])
            assert(gridVertAt(m, pre[gone]) < 0, "the consumed vertices go");
        assert(gridVertAt(m, pre[4]) >= 0,
            "but NOT vertex 4, whose fan is equally consumed and which is nobody's "
          ~ "dissolving endpoint");
        foreach (pair; [[0, 2], [4, 6], [8, 10], [12, 14]]) {
            immutable int a = gridVertAt(m, pre[pair[0]]), b = gridVertAt(m, pre[pair[1]]);
            assert(a >= 0 && b >= 0 && m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
                "and the survivors are re-stitched across the gap");
        }
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    }

    // And the DEFAULT tool takes the OFF branch — the flag's default is the
    // behaviour, not a formality.
    {
        Mesh m = makeGridPlane(3);
        auto h = new CommandHistory();
        auto t = makeRemoveTestTool(&m, h);
        assert(!t.keepVertex_, "a fresh tool must purge");
    }
}

unittest { // the loop variant keys on the EFFECTIVE flag, never on the button
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // The chord that FORCES the loop flag, against a plain press with the flag
    // set by the user. These were measured bit-identical down to the removed-
    // edge / new-edge / removed-vertex sets, so the port must not be able to
    // tell them apart either.
    static Mesh run(bool viaChord) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = !viaChord;   // the chord supplies it in the other arm

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridEdgeMidPixel(m, vp, 5, 9);
        if (viaChord)
            t.onToolAction(TopoPenChord.Rmb, InputPhase.Down, e, vts);
        else
            t.onPlainLmbDown(e, vts);
        return m;
    }

    Mesh viaFlag  = run(false);
    Mesh viaChord = run(true);
    assert(viaFlag.vertices == viaChord.vertices, "same vertices");
    assert(viaFlag.edges    == viaChord.edges,    "same edges");
    assert(viaFlag.faces    == viaChord.faces,    "same faces");
    assert(viaFlag.vertices.length == 12 && viaFlag.edges.length == 17
        && viaFlag.faces.length == 6, "and both ran the LOOP variant");
}

unittest { // a BORDER seed is a TOTAL no-op, in BOTH variants
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    foreach (loop; [false, true]) {
        Mesh m   = makeGridPlane(3);
        auto vp  = makeGridPlaneTestViewport();
        auto h   = new CommandHistory();
        auto t   = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = loop;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto before = MeshSnapshot.capture(m);
        auto e = gridEdgeMidPixel(m, vp, 0, 1);   // top-left BORDER edge
        int idx;
        assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge
            && idx == cast(int)m.edgeIndex(0, 1), "setup: the press must latch the border edge");

        assert(t.onPlainLmbDown(e, vts), "still consumed");

        auto after = MeshSnapshot.capture(m);
        assert(after.vertices == before.vertices && after.edges == before.edges
            && after.faces == before.faces,
            "16/24/9 and not one vertex moved");
        assert(!h.canUndo(), "and no undo entry is recorded");
    }
}

unittest { // ...and the seed gate is a GATE, not the kernel's per-edge skip
    // Honest note on the block above: it does NOT discriminate. On a border
    // seed the dissolve kernel skips the edge anyway, so deleting the seed gate
    // outright leaves every assertion there green — verified by mutation. No
    // BORDER fixture can separate the two, either: a border seed's loop gather
    // walks the open boundary, so everything it returns is a border edge too.
    //
    // A NON-MANIFOLD seed does separate them, and it is the case the measured
    // rule actually names — the gate is "exactly two incident polygons", not
    // "not a border". Three quads share edge 0-1 here. The gate declines it;
    // the kernel would NOT, because its own adjacency keeps the first two
    // distinct faces per edge and would merrily merge those two.
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();

    immutable uint seed = m.edgeIndex(0, 1);
    assert(m.edgePolygonCounts()[seed] == 3,
        "setup: the count must SEE all three — the half-edge rings report 1 here, "
      ~ "which is why this tool counts off the faces instead");

    auto h = new CommandHistory();
    auto t = makeRemoveTestTool(&m, h);
    auto before = MeshSnapshot.capture(m);
    foreach (loop; [false, true]) {
        t.edgeLoop_ = loop;
        t.removeEdgeAt(cast(int)seed, loop);
    }
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "a seed with other than exactly two incident polygons is a TOTAL no-op");
    assert(!h.canUndo(), "and records nothing");
}

unittest { // one undo restores counts AND positions, for all three primitives
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    static void roundTrip(bool loop, uint a, uint b, bool vertexPress, uint v) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = loop;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto before = MeshSnapshot.capture(m);
        auto e = vertexPress ? gridVertPixel(m, vp, v) : gridEdgeMidPixel(m, vp, a, b);
        assert(t.onPlainLmbDown(e, vts));
        assert(h.canUndo(), "the gesture must be undoable");
        h.undo();
        auto after = MeshSnapshot.capture(m);
        assert(after.vertices == before.vertices && after.edges == before.edges
            && after.faces == before.faces,
            "ONE undo must restore counts AND positions — the whole gesture is one step");
    }

    roundTrip(/*loop*/false, 5, 9, false, 0);   // edge dissolve
    roundTrip(/*loop*/true,  5, 9, false, 0);   // edge loop dissolve (+ the purge)
    roundTrip(/*loop*/false, 0, 0, true,  5);   // vertex fan merge
}

unittest { // Keep Vertices reaches the EDGE path and nothing else
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // Measured only on the edge path, and the reference reads the flag in
    // neither of the other two primitives — so honouring it there would be
    // inventing a second meaning for it.
    foreach (keep; [false, true]) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.keepVertex_ = keep;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridVertPixel(m, vp, 5);
        assert(t.onPlainLmbDown(e, vts));
        assert(m.vertices.length == 15 && m.edges.length == 20 && m.faces.length == 6,
            "the vertex primitive ignores Keep Vertices in both positions");
    }
}

unittest { // a bare retopo chain elsewhere in the mesh SURVIVES a dissolve
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // vibe3d-side contract, not a ported behaviour (`captureWireEdges`): this
    // tool builds face-less edges as an ordinary intermediate state, and the
    // dissolve kernels re-derive the edge array from the faces, which would
    // otherwise wipe every one of them mesh-wide — related to the edit or not.
    Mesh m  = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    auto h  = new CommandHistory();
    auto t  = makeRemoveTestTool(&m, h);

    // Two loose vertices joined by a bare edge, plus one placed point with no
    // edge at all — well away from the grid, and all three face-less.
    immutable uint w0 = m.addVertex(Vec3(5, 0, 5));
    immutable uint w1 = m.addVertex(Vec3(6, 0, 5));
    immutable uint w2 = m.addVertex(Vec3(7, 0, 5));
    m.addEdge(w0, w1);
    m.buildLoops();
    auto wa = m.vertices[w0], wb = m.vertices[w1], wc = m.vertices[w2];
    assert(m.edges.length == 25, "setup: 24 grid edges plus the wire");

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto e = gridEdgeMidPixel(m, vp, 5, 9);
    assert(t.onPlainLmbDown(e, vts));

    immutable int a = gridVertAt(m, wa), b = gridVertAt(m, wb);
    assert(a >= 0 && b >= 0, "the wire's endpoints must survive");
    assert(m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
        "and so must the bare edge between them");
    assert(gridVertAt(m, wc) >= 0,
        "and so must a placed point with no edge at all — the kernel's tail compaction "
      ~ "drops every face-less vertex in the mesh, not only the ones this edit touched");
}
