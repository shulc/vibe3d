// The Topology Pen tool itself: the class, its gesture handlers and its
// commit steps. Reached by everyone through the package facade
// (`import tools.edit.topology_pen;`); this module name exists so that
// `package` here means the PEN's package and nothing wider -- see
// `package.d` for why that distinction is the point.
module tools.edit.topology_pen.tool;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : hypot, SQRT2;

import tool;
import mesh                : Mesh, GpuMesh, MeshCacheKey;
import math               : Vec3, Viewport, projectToWindowFull, closestOnSegment2D,
                             screenPointToRay, closestPointOnSegmentToRay, dot,
                             pointInPolygon2D, rayPlaneIntersect,
                             AimViewport, aimSpace, ModelSpace,
                             screenPointToLocalRay;
import document             : primaryModelSpace;
import shader              : Shader;
import operator            : VectorStack, viewportOf;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket, SnapPacket, SnapType;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.guide       : SnapGuide, GuideDrawState, kGuidePrioritySeed;
import constraint           : resolveHoverTarget, topoPenPressPickPx,
                              topoPenSnapAcceptPx, topoPenSnapGatherPx,
                              kTopoPenSnapAuto, closestPointOnMeshes;
import snap                  : backgroundSourcesFull, SnapAdmit;
import tools.edit.smooth_relax : RelaxVec3, RelaxTopology, deriveBoundary, relaxPasses;
import tools.edit.topology_pen.render : PenRenderOps;
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

/// The 13 per-gesture undo factories, grouped (refactor): they used to be 13
/// sibling `*EditFactory_` fields on the tool, each under its own P*
/// provenance header — those headers now live on the fields below. The tool
/// carries ONE member (`factories_`); the pre-grouping field names survive
/// as `ref` shims on the class, because the same-module direct-construction
/// rigs assign them one at a time. Prod code reads `factories_` directly.
private struct TopoPenFactories {
    TopoPenBuildFactory        build;         // P3 (doc/topopen_p3_plan.md)
    TopoPenMoveFactory         move;          // P4 (doc/topopen_p4_plan.md, OBJ-3 FOLDED)
    TopoPenRemoveFactory       remove;        // P5 (doc/topopen_p5_remove_plan.md, opponent KILLER-1)
    TopoPenRemoveEdgeFactory   removeEdge;    // task 0494: Remove's edge-latched primitive
    TopoPenRemoveVertexFactory removeVertex;  // task 0494: Remove's vertex-latched primitive
    TopoPenAddLoopFactory      addLoop;       // P6 (doc/topopen_p6_addloop_plan.md, REV1 opponent obj-1)
    TopoPenSlideFactory        slide;         // P7 (doc/topopen_p7_slide_plan.md, REV1)
    TopoPenSmoothFactory       smooth;        // P8 (doc/topopen_p8_smooth_plan.md)
    TopoPenSplitFactory        split;         // P9 (doc/topopen_p9_split_plan.md)
    TopoPenMoveLoopFactory     moveLoop;      // P10 (doc/topopen_p10_moveloop_plan.md)
    TopoPenDupLoopFactory      dupLoop;       // P11 (doc/topopen_p11_duploop_plan.md)
    TopoPenSmoothLoopFactory   smoothLoop;    // P12 (doc/topopen_p12_smoothloop_plan.md)
    TopoPenFillFactory         fill;          // Fill mode (task 0477 continuation, doc/topopen_fill_plan.md)
}

/// The four connectivity outcomes a drag-from-vertex build gesture can
/// resolve to on release, per `classifySource` below (capture-verified,
/// doc/topopen_p3_plan.md's mechanism table). `None` covers BOTH "the
/// source vertex's topology doesn't qualify" and the measured one-shot
/// ceiling (a hub already embedded in a quad classifies degree-2/non
/// -triangle-hub, which is exactly `None`).
package enum BuildCase { None, Edge, Tri, Quad }

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
package enum PenMode { Move, Duplicate, Remove, Split, AddLoop, Point, Fill, Smooth }

// Why a Ctrl+LMB Slide press did not arm — see `slideDecline_`'s own doc
// comment for the full rationale. `None` also covers "the press armed
// normally", so a consumer reads `slideDeclineReason == "none"` as "no decline
// to explain". A plain enum + `final switch` in `slideDeclineTag` (the
// `BuildCase`/`HoverTargetKind` precedent, likewise `buildCaseTag`/
// `hoverTargetKindTag`) rather than an `IntEnumEntry` table:
// this is not a `Param`, nothing parses it back, and the `final switch` keeps
// the token mapping compile-time exhaustive.
package enum SlideDecline { None, NoEdge, NoContinuation }

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
package enum MoveElem { None, Vertex, Edge, Face }

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
package enum PenGesture {
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
package enum ModeOv : ubyte { FromUser, Duplicate, Split, AddLoop, Remove, Smooth }
package enum FlagOv : ubyte { FromUser, ForceOn }

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
package enum TopoPenChord : ToolAction {
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
package immutable ChordOv[12] kChordOv = [
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
package InputButton chordButton(TopoPenChord c) {
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
package immutable InputBinding[] kTopoPenBindings = [
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

/// ONE gesture's ARM bit — the "this gesture is in progress" flag every
/// `on*Down` sets and its matching `*Up` clears.
///
/// It exists as a distinct TYPE, not as a `bool`, for exactly one reason: the
/// type is what `TopologyPenTool.eachGestureArm` matches on, so the set of arms
/// is enumerated by the COMPILER from the field declarations rather than by a
/// hand-maintained list. Before task 0705 the same set was written out three
/// times — the OR in `anyGestureArmed()`, the assignments in
/// `resetAllGestureArms()`, and a Tier-A pin unittest — plus twice more in
/// prose, and those five spellings had already drifted apart: the doc comment
/// said "9", the paragraph below it said "10", the pin test listed 10, and
/// `dupEdgeArmed_` (task 0485) appeared in none of them. Declaring a field of
/// this type is now the ONLY way to have an arm, and every consumer walks the
/// same trait — a new gesture cannot be forgotten by one of them.
///
/// `alias armed this` + `opAssign(bool)` keep every existing `xArmed_ = true` /
/// `if (!xArmed_)` / `JSONValue(xArmed_)` site reading exactly as it did when
/// these were plain `bool`s; the type change is invisible at the ~214 use
/// sites and visible only to the enumeration.
struct GestureArm {
    bool armed;
    alias armed this;
    void opAssign(bool v)       { armed = v; }
    void opAssign(GestureArm o) { armed = o.armed; }
}

/// The names of every `GestureArm` field of `TopologyPenTool`, in declaration
/// order — derived by the compiler from the field declarations themselves.
///
/// THE list. `anyGestureArmed()`, `resetAllGestureArms()` and the arm-coverage
/// unittest all iterate this one constant, so none of them can be out of step
/// with the others or with the class: adding a gesture is declaring one field.
///
/// `TopologyPenTool` is named explicitly rather than reached through
/// `typeof(this)` because inside a `const` method `typeof(this)` is
/// `const(TopologyPenTool)`, and `is(typeof(field) == GestureArm)` would then
/// match NOTHING — the walk would silently visit zero fields and every arm
/// would read as disarmed. Deriving the list once, here at module scope,
/// removes that trap from the two consumers.
package enum string[] kGestureArmFields = () {
    string[] r;
    static foreach (m; __traits(derivedMembers, TopologyPenTool))
        static if (is(typeof(__traits(getMember, TopologyPenTool, m)) == GestureArm))
            r ~= m;
    return r;
}();

class TopologyPenTool : Tool, InputBindable {

    /// Click-vs-drag gate, in pixels, shared by EVERY gesture in this tool:
    /// a release within this distance of the press pixel is a click, not a
    /// drag, and commits nothing. Compared SQUARED (`dx*dx + dy*dy < k*k`),
    /// strictly less-than, so exactly `k` pixels already counts as a drag.
    ///
    /// One constant because it was six identical local `enum int
    /// kMinDragPx = 3;` declarations, each carrying a comment saying it
    /// mirrors the others (audit №4, TP3). Two gestures deliberately do NOT
    /// gate on it — `smoothUp` and `smoothLoopUp`, whose stationary click IS
    /// the operation; their own comments say so.
    ///
    /// NOT the same constant as pen.d's `DRAG_THRESHOLD_PX = 4`. That is a
    /// different tool with a different measured value; the identical idiom
    /// there is not evidence the two are one setting.
    enum int kMinDragPx = 3;

    /// The gate itself, applied to a release's screen delta from its press
    /// pixel: `true` ⇒ this release was a CLICK and the gesture commits
    /// nothing.
    ///
    /// Task 0705 gives the comparison the same single home wave 1 gave the
    /// constant. It was written out six times — `buildUp`, `slideUp`,
    /// `moveLoopUp`, `dupLoopUp`, `dupEdgeUp` and `perVertexTargets` — always
    /// as the same squared, strictly-less-than test, and always under a
    /// comment saying it "mirrors" one of the other five. Comparing squared
    /// and strictly is the part that can silently drift; the six call sites
    /// still differ in which start pixel they measure from and in what they
    /// return, which is why THIS is the shared part and the release legs are
    /// not otherwise merged.
    private static bool releaseIsClick(int dx, int dy) {
        return dx * dx + dy * dy < kMinDragPx * kMinDragPx;
    }

private:
    ConstrainHitPacket lastHit_;
    HoverTarget         lastTarget_;

    // --- P2 placement deps (doc/topopen_p2_plan.md) — wired by
    // registration.d, mirroring VertexTool's ctor/setUndoBindings shape
    // (tools/create/vertex_place.d). All may be left unset (test/no-app
    // construction); `placeVertexAt` degrades to a no-op rather than
    // crashing when `addVertexFactory_` is null.
    package Mesh* delegate() meshSrc_;
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

    package CommandHistory    history_;
    VertexNewFactory  addVertexFactory_;

    // --- Per-gesture undo factories (P3..P12 + Fill, task 0494) — grouped
    // into `TopoPenFactories` (see its own doc comment for each field's
    // provenance). The `ref` shims below keep the pre-grouping field names
    // working for the same-module direct-construction rigs, which assign
    // them one at a time; prod code reads `factories_` directly.
    TopoPenFactories factories_;
    package @property ref TopoPenBuildFactory        buildEditFactory_()        { return factories_.build; }
    package @property ref TopoPenMoveFactory         moveEditFactory_()         { return factories_.move; }
    package @property ref TopoPenRemoveFactory       removeEditFactory_()       { return factories_.remove; }
    package @property ref TopoPenRemoveEdgeFactory   removeEdgeEditFactory_()   { return factories_.removeEdge; }
    package @property ref TopoPenRemoveVertexFactory removeVertexEditFactory_() { return factories_.removeVertex; }
    package @property ref TopoPenAddLoopFactory      addLoopEditFactory_()      { return factories_.addLoop; }
    package @property ref TopoPenSlideFactory        slideEditFactory_()        { return factories_.slide; }
    package @property ref TopoPenSmoothFactory       smoothEditFactory_()       { return factories_.smooth; }
    package @property ref TopoPenSplitFactory        splitEditFactory_()        { return factories_.split; }
    package @property ref TopoPenMoveLoopFactory     moveLoopEditFactory_()     { return factories_.moveLoop; }
    package @property ref TopoPenDupLoopFactory      dupLoopEditFactory_()      { return factories_.dupLoop; }
    package @property ref TopoPenSmoothLoopFactory   smoothLoopEditFactory_()   { return factories_.smoothLoop; }
    package @property ref TopoPenFillFactory         fillEditFactory_()         { return factories_.fill; }

    // --- P3 drag-build session state (topology_pen.d, doc/topopen_p3_plan.md).
    // Armed on a press that lands on an existing primary-layer vertex;
    // classified ONCE at arm time (the mesh is never mutated between press
    // and release, so re-classifying at release would be redundant, not
    // more correct — and a stale index after an external undo mid-drag is
    // handled by `resyncSession` clearing all of this instead). Cleared by
    // `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation.
    package int       sourceVert_     = -1;
    package GestureArm      dragArmed_;
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
    package GestureArm placeArmed_;
    package GestureArm moveArmed_;
    package int  grabbedVert_ = -1;

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
    //
    // `moveWelded_` records whether the release's destructive landing (task
    // 0555) actually absorbed anything. Set between the final placement and
    // the undo record, and read by BOTH of the things that must behave
    // differently after a topology change: the record's net-no-op test (which
    // cannot compare against `moveBase_` any more — the vertex array was
    // compacted under those indices) and the post-commit `resyncSession`.
    package MoveElem     moveElem_  = MoveElem.None;
    package uint[]       moveVerts_;
    package Vec3[]       moveBase_;
    package int          moveStartX_, moveStartY_;
    package bool         moveDirty_ = false;
    bool         moveWelded_ = false;
    package MeshSnapshot moveBefore_;

    // --- P6 Add Loop session state (topology_pen.d,
    // doc/topopen_p6_addloop_plan.md). Armed on a Shift+MMB press that
    // lands on a primary-layer edge whose perpendicular ring exists
    // (`onShiftMmbDown`); the ratio tracks the cursor on every subsequent
    // motion event (`onMouseMotion`) and commits on release
    // (`onMouseButtonUp`'s MIDDLE branch, `commitAddLoop`). `seedRailA_`/
    // `seedRailB_` are the directed LAYER-LOCAL endpoints `ratioFromCursor`
    // measures the `[0,1]` ratio against (task 0619: this said "world-space"
    // and `seedRail` fills them from raw `m.vertices[]`; `ratioOnSegment`
    // is what lifts them for its own world election, and the ratio comes
    // back local for free because an affine map preserves ratios along a
    // line) (`seedRail`, captured once at arm
    // time — the mesh is never mutated between arm and commit, so
    // re-deriving them at every motion event would be redundant). Cleared
    // by `onMouseButtonUp` on commit/no-op and by `resyncSession` on an
    // external history navigation, exactly like the P3/P4 arm state above.
    package int  addLoopSeed_  = -1;
    package GestureArm addLoopArmed_;
    int  addLoopStartX_, addLoopStartY_;
    package Vec3 seedRailA_, seedRailB_;
    package float addLoopRatio_ = 0.5f;

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
    package bool addLoopMiddle_ = false;

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
    package int   slideSeed_  = -1;
    package GestureArm  slideArmed_;
    package int   slideStartX_, slideStartY_;
    package int   slideEndA_ = -1, slideEndB_ = -1;
    package int   slideNbrA_ = -1, slideNbrB_ = -1;
    package Vec3  slideAnchor_ = Vec3(0, 0, 0);
    package float slideDeltaK_ = 0.0f;

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
    package SlideDecline slideDecline_     = SlideDecline.None;
    package int          slideDeclineSeed_ = -1;

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
    package GestureArm  smoothArmed_;
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
    package GestureArm splitArmed_;
    package int  splitSourceVert_  = -1;
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
    // GATED on `SnapPacket.enabled` since task 0523, where it used not to be.
    // The pen welded whether or not the user had snapping on — alone among the
    // snapping clients in this tree — and that was our divergence, not a
    // feature: the reference gates its pen on the shared enable through both
    // of the tool's channels, and the mechanism that would have excused us (a
    // guide declaring itself always-on) does not exist. `resolveSnapTargetVert`
    // is where the gate reads; see its doc for what it costs at our default.
    package SnapPacket dragSnap_;

    // The key this tool's startup snap arming is filed under in the stage's
    // single push slot (`SnapStage.pushEnabled`). The reference keys its own
    // save/restore on the ACTIVATING PRESET'S NAME, so this is our factory id
    // — the name every route to this tool activates through. See
    // `armStartupSnap` for what the arming is and why it is measured.
    private enum string kSnapArmOwner = "mesh.topoPen";

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
    package PenMode penMode_ = PenMode.Move;   // live-measured reference default

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
    package bool edgeLoop_  = false;
    package bool edgeSlide_ = false;

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
    package bool innerSnap_ = false;

    // `backFace_` ("Backface") — the SECOND HALF of the same admission policy
    // `innerSnap_` is the first half of, default OFF (measured live, task
    // 0497). Where `innerSnap` picks WHICH TOPOLOGY may be a snap candidate,
    // this one picks WHICH ORIENTATION may: with it OFF a candidate whose own
    // normal points away from the viewer is refused; with it ON the
    // orientation test is skipped entirely and a back-facing element is as
    // good a target as a front-facing one. Sticky across gestures, for the
    // same reason `penMode_` is.
    //
    // WHY IT IS A PEN ATTRIBUTE AND NOT A SERVICE SETTING, which is the whole
    // point of the row: the reference reads this flag in the tool's own
    // candidate-FILTER callbacks — the same callbacks that carry `innerSnap`
    // — and nowhere else. The orientation gate is therefore the CLIENT'S, an
    // option the tool may decline; it is not a law the snapping service
    // applies to everybody. Our snap service does apply a front-facing (plus
    // occlusion) gate unconditionally to every one of its clients
    // (`Mesh.visibleVertices`, consulted from `snap.snapCursor`), and that
    // gate is deliberately NOT touched here: this row gives the PEN the
    // ownership the measurement puts on it, and re-scoping the service's own
    // gate for its other clients is a separate decision with its own blast
    // radius.
    //
    // SCOPE, narrow because that is what was measured: the flag gates the
    // pen's own snap-candidate admission (`PenSnapGuide.admits`) and nothing
    // else. In particular it does NOT gate the press-time element PICK, does
    // not touch the background placement ray — which was separately measured
    // to be TWO-SIDED on both sides, so culling there would CREATE a
    // divergence rather than close one — and does not switch any depth test
    // on or off. The reference reads it on the VERTEX and EDGE candidate
    // branches only; its polygon branch never reads it, and our guide admits
    // vertices only, so the vertex branch is the whole of what is reachable
    // here.
    //
    // Wiring this knob CHANGES this tool's default outcome, exactly as
    // `keepVertex_` did: before it the pen's snap target was a pure
    // screen-nearest with no orientation test at all, i.e. we shipped the ON
    // branch while the measured default is OFF.
    package bool backFace_ = false;

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
    package bool keepVertex_ = false;

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
    package float fillRange_    = kFillRangeDefault;
    package bool  fillQuadOnly_ = true;

    // Which gesture the LAST unmodified-LMB press actually resolved to
    // (task 0483). Written by `onPlainLmbDown`'s router at DOWN, read by
    // `lmbModeUp` at UP so the release reaches THAT gesture's commit leg —
    // re-resolving the mode at release would dispatch the wrong commit if
    // the dropdown moved mid-drag (`tool.attr mesh.topoPen mode <tag>` is
    // reachable over HTTP at any moment, and the Tool Properties dropdown
    // is one click away). Per-press RECORD, so `resetAllGestureArms()`
    // returns it to the neutral `PlaceOrMove` — whose UP leg is guarded
    // by `placeArmed_`/`moveArmed_` and therefore a safe no-op.
    package PenGesture[3] gestureOn_ = PenGesture.PlaceOrMove;

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
    package GestureArm  moveLoopArmed_;
    package int   moveLoopSeed_   = -1;
    package int   moveLoopStartX_, moveLoopStartY_;
    int   moveLoopCurX_,   moveLoopCurY_;
    package uint[] moveLoopVerts_;

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
    package GestureArm  dupLoopArmed_;
    package int   dupLoopSeed_    = -1;
    package int[] dupLoopEdges_;
    package int   dupLoopStartX_, dupLoopStartY_;
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
    package GestureArm  dupEdgeArmed_;
    package int   dupEdgeSeed_  = -1;
    package int[] dupEdgeEdges_;          // what the release will duplicate: [seed], or the trimmed border run
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
    package GestureArm   smoothLoopArmed_;
    package int    smoothLoopSeed_    = -1;
    package uint[] smoothLoopVerts_;
    package int    smoothLoopStartX_, smoothLoopStartY_;
    package int    smoothLoopCurX_,   smoothLoopCurY_;
    package float  smoothLoopDragPx_ = 0.0f;

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
    package static int smoothPassesForDragDx(int dragDx) {
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
    package float smoothStrength_ = kSmoothStrengthDefault;

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
    package bool hoverOverMesh_     = false;
    package int  hoverNearestVert_  = -1;
    package int  hoverNearestEdge_  = -1;
    package bool hoverBoundary_     = false;
    package int  hoverBoundaryFace_ = -1;

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
    package MoveElem hoverGrabElem_  = MoveElem.None;
    package int      hoverGrabIndex_ = -1;

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
    package bool showVertex_ = true;
    package bool showEdge_   = true;

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
    package uint[] fillRing_;

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
    package bool  fillRadiusValid_ = false;
    package float fillRadiusPx_    = 0.0f;

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
            Viewport vp = viewportOf(vts);
            lastTarget_ = resolveHoverTarget(lastHit_, vp, topoPenPressPickPx(vp));
        }
        // else: leave lastHit_/lastTarget_ unchanged — see class doc (the
        // per-frame render-loop's vts never carries the packet; only a
        // real mouse event does).
    }

    // ---------------------------------------------------------------------
    // THE FILE'S ONE PROJECTION SEAM — split in two by SPACE (task 0619
    // Stage 4a, doc/tool_aiming_item_transform_plan.md §2.2).
    //
    // What used to be here was a single `projectPt(Vec3 world, …)` whose
    // parameter was named `world` and which was handed a raw, LAYER-LOCAL
    // `mesh.vertices[…]` by most of its call sites. On a layer with a
    // non-identity item transform that projects the geometry to where it
    // would sit at IDENTITY, not to where it is drawn — so every pick,
    // veto, gather and ghost in this file aimed at the wrong pixels.
    //
    // The name is deliberately GONE rather than fixed in place: deleting it
    // turned all 161 of its call sites into build errors, which is the only
    // mechanism that forces each one to be classified rather than assumed
    // (§R2). The two replacements differ in the TYPE of their viewport, so a
    // MIS-classified site cannot compile either:
    //
    //   * `projectLocalPt` takes an `AimViewport` — a viewport that has
    //     already had a `ModelSpace` composed into it and that cannot be
    //     produced any other way (math.d §2.0). Hand it `mesh.vertices[…]`
    //     and any other layer-local quantity.
    //   * `projectWorldPt` takes a plain `Viewport`. Hand it a value that is
    //     ALREADY in world space — everything the CONS stage publishes
    //     (`lastHit_.point` / `.normal` / `.nearestVertPos` /
    //     `.nearestEdgeA/B`, world since 0617).
    //
    // Neither takes a `ModelSpace`, so there is no parameter to silence the
    // compiler with an identity value: the only available choice is a
    // semantic one.
    //
    // AIMING KIND for `projectLocalPt`: **Pixel** (§1.1). The law is "keep
    // the geometry local, compose the viewport", because
    // `proj·(view·M)·v ≡ proj·view·(M·v)` holds exactly — so the pixel this
    // returns IS the pixel the vertex is drawn at, with no per-vertex
    // transform. Build the `AimViewport` ONCE per query (§3): it is a stack
    // copy plus one 4×4 multiply, which is cheap per event and unacceptable
    // per vertex.
    // ---------------------------------------------------------------------

    /// Project a LAYER-LOCAL point to a foreground-drawlist pixel through the
    /// aiming space; false when behind the camera.
    static bool projectLocalPt(Vec3 pLocal, const ref AimViewport vpAim, out ImVec2 pt) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(pLocal, vpAim.vp, sx, sy, ndcZ)) return false;
        pt = ImVec2(sx, sy);
        return true;
    }

    /// Project an ALREADY-WORLD point to a foreground-drawlist pixel; false
    /// when behind the camera. The typed home for "this value is not a mesh
    /// coordinate" — so nobody has to fabricate an aim space to say so.
    package static bool projectWorldPt(Vec3 pWorld, const ref Viewport vp, out ImVec2 pt) {
        float sx, sy, ndcZ;
        if (!projectToWindowFull(pWorld, vp, sx, sy, ndcZ)) return false;
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
    package static float fillHoverRadiusPx(float cursorX, float cursorY,
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
        factories_.build         = bf;
        factories_.move          = mf;
        factories_.remove        = rf;
        factories_.addLoop       = alf;
        factories_.slide         = sf;
        factories_.smooth        = smf;
        factories_.split         = spf;
        factories_.moveLoop      = mlf;
        factories_.dupLoop       = dlf;
        factories_.smoothLoop    = slf;
        factories_.fill          = flf;
        factories_.removeEdge    = ref_;
        factories_.removeVertex  = rvf;
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
    // `backFace` (task 0538) — the orientation half of the pen's snap
    // admission policy, APPENDED LAST, same reason as every row above,
    // measured default OFF. It leaves the "awaiting measurement" bucket below
    // on the same terms `innerSnap` did: its BEHAVIOUR is measured (at OFF a
    // candidate whose own normal faces away from the viewer is refused; at ON
    // the orientation test is skipped), its BOUNDS are a plain boolean, and it
    // is a load-bearing input to the ported admission rule rather than a knob
    // for its own sake. See the field's own doc comment for the scope, and for
    // why publishing it MOVES the default rather than merely exposing a knob.
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
    // The reference tool carries 31 attributes; this list publishes 12. The gap
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
            Param.bool_("backFace", "Backface", &backFace_, false),
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
        // Arm the application-wide snap enable for the life of this tool, as
        // every shipped route to the reference's pen does (`armStartupSnap`).
        // BEFORE the CONS composition below and its two early returns, not
        // after: a user-locked CONS must not decide whether snapping arms —
        // they are independent stages and the reference arms unconditionally.
        armStartupSnap();
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
        // decline diagnostics above do. The guide's registration is the same
        // per-gesture state and goes with it (task 0523): a guide left in the
        // service's registry after its tool is gone would keep admitting
        // against a mesh nobody is editing.
        dragSnap_ = SnapPacket.init;
        unregisterSnapGuide();
        // And hand the application-wide snap enable back to whatever had it
        // before this tool was activated — the drop half of the reference's
        // own save/restore pair (`armStartupSnap`). AFTER
        // `commitLiveMoveIfDirty` above, which is the salvage of an abandoned
        // drag and deliberately does NOT weld: restoring first would leave
        // that path reading a snap state this tool no longer owns.
        disarmStartupSnap();
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
            Viewport vp = viewportOf(vts);
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
            //
            // TASK 0488: the seed is resolved ONCE for this event and shared
            // with the radius overlay below. Two independent seed queries per
            // motion could disagree, and each one is a full unbounded scan
            // plus a BVH pick — so sharing is both the correctness argument
            // and the cheap one.
            immutable int fillSeed =
                (penMode_ == PenMode.Fill) ? fillSeedEdge(e.x, e.y, vp) : -1;
            fillRing_ = (fillSeed >= 0)
                      ? fillRingFromSeed(cast(uint)fillSeed, e.x, e.y, vp) : null;

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
            {
                auto m = mesh;
                if (fillSeed >= 0 && m !is null && fillSeed < cast(int)m.edges.length) {
                    // Pixel (§1.1): the radius is a distance from the cursor
                    // to the DRAWN endpoints of the seed edge, so the two
                    // local vertices go through the aiming space.
                    const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
                    ImVec2 pa, pb;
                    if (projectLocalPt(m.vertices[m.edges[fillSeed][0]], vpAim, pa)
                     && projectLocalPt(m.vertices[m.edges[fillSeed][1]], vpAim, pb)) {
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
            Viewport vp = viewportOf(vts);
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
            Viewport vp = viewportOf(vts);
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
            Viewport vp = viewportOf(vts);
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
            Viewport vp = viewportOf(vts);
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
    package static bool isEdgeInterior(in int[] polyCount, uint ei) {
        return ei < polyCount.length && polyCount[ei] >= 2;
    }

    /// One-off convenience — RECOUNTS THE WHOLE MESH per call. Any loop over
    /// edges or vertices must hoist `Mesh.edgePolygonCounts()` once and use the
    /// array overload; the two `borderOnly` scans below do exactly that.
    package static bool isEdgeInterior(Mesh* m, uint ei) {
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
    package static bool isVertexInterior(Mesh* m, uint vi) {
        return isVertexInterior(m, m.edgePolygonCounts(), vi);
    }

    // -----------------------------------------------------------------------
    // The pen's SNAPPING GUIDE — S6 of doc/toolpipe_architecture_plan.md.
    //
    // The pen has no snapping of its own to own. It is a CLIENT of the one
    // snapping service in this tree, and the only thing about that service
    // that is the pen's is the ADMISSION RULE: which enumerated candidate the
    // pen is willing to land on. That rule used to be a `bool borderOnly`
    // parameter threaded through the tool's own vertex scan — a policy with no
    // owner, invisible to the service and unusable by anything else. It lives
    // here now, in one object, with the lifetime of one gesture.
    //
    // MEASURED — the LIFECYCLE. The reference's pen registers a guide object
    // on the shared event-translation packet when its drag starts and removes
    // it on mouse-up; the environment's pixel ranges are pushed INTO the guide
    // by the framework, which is why `limits` is a setter and not a getter.
    // Our `SnapStage` is the same service: `addGuide` on the press,
    // `removeGuide` on the release (`TopologyPenTool.onMouseButtonDown` /
    // `onMouseButtonUp` / `deactivate`), and the stage pushes the ranges in.
    //
    // MEASURED — the PRIORITY. `kPriority` below is read out of the reference,
    // not chosen: its pen guide declares 2 where its element-snap guide
    // declares 3, and both are live for the whole of a pen drag. The framework
    // pre-seeds the priority slot to 1 before every proximity call, so 1 is
    // what a guide that ignores the parameter reports — 2 is a deliberate
    // value, one step above the default and one below the element snap's.
    //
    // MEASURED — `flags`. The reference's pen guide installs NO flags accessor
    // at all (the vtable slot is NULL, and it is one of exactly three
    // tool-owned guides that leave it so). `0` is the faithful stand-in for
    // "declares nothing": no bit is set, and in particular the pen does NOT
    // claim the "run even when the global snap enable is off" bit — which is
    // the whole of why the weld below is gated. Do not put a bit here without
    // a measurement.
    //
    // OURS, and unmeasured: the AIM (`aimAt`). The interface pushes the
    // environment's RANGES in but not its CURSOR, and a guide cannot answer
    // "how far away is this candidate" without one. So whoever is about to run
    // a query aims the guide first, exactly as it would push a range. The
    // reference's guide carries a view and a host pointer in its own context
    // and is likewise aimed by its owner, so the direction is right; the
    // spelling is ours.
    // -----------------------------------------------------------------------
    static final class PenSnapGuide : SnapGuide {
        /// The priority this guide answers proximity queries with. MEASURED —
        /// see the block comment above. Higher wins outright; distance only
        /// breaks ties WITHIN one priority.
        enum int kPriority = 2;

        // The mesh the admission rule is evaluated against, and the border
        // classification of its edges. The counts are a CACHE, keyed on
        // (address, mutationVersion) so a gesture that edits the mesh under
        // the guide — Move writes on every motion event — re-derives them
        // instead of admitting against a stale topology. The pen's own scan
        // used to recompute them once per call, so this is never more work
        // and usually less.
        private Mesh*        mesh_;
        private int[]        polyCount_;
        private MeshCacheKey polyKey_;

        /// `innerSnap`: when set, the interior opens up and every vertex is a
        /// candidate. The pen attribute, mirrored here rather than read
        /// through a back-pointer — a guide answers from what it was told.
        private bool interiorOk_;

        /// `backFace`: when set, the ORIENTATION test below is skipped and a
        /// back-facing candidate is admitted. Mirrored here for the same
        /// reason `interiorOk_` is. MEASURED, including the polarity: the
        /// reference reads its flag in the same candidate-filter callbacks it
        /// reads the border rule in, and a non-zero value is what makes the
        /// filter accept without testing.
        private bool backFaceOk_;

        // The aim. `aimed_` is deliberately NOT defaulted true: a guide that
        // has never been aimed must reject rather than answer against a
        // zero viewport, because a wrong distance is a wrong winner and would
        // be indistinguishable from a near miss.
        //
        // `aimDir_` is the world-space ray through the aimed pixel, computed
        // once per aim and shared by every candidate — which is the measured
        // shape of the orientation test, not an optimisation: the reference
        // writes ONE screen ray into the tool before it runs the candidate
        // search and every filter call dots against that one direction. A
        // per-candidate eye→candidate direction would be a different test at
        // wide FOV.
        private Viewport aimVp_;
        private int      aimX_, aimY_;
        package Vec3     aimDir_ = Vec3(0, 0, 0);
        // The same ray direction in the PRIMARY layer's LOCAL space (task
        // 0619 §1.4), written beside `aimDir_` in `aimAt`. Deliberately NOT
        // renormalized — only its SIGN against a local normal is read.
        private Vec3     aimDirLocal_ = Vec3(0, 0, 0);
        private bool     aimed_;

        // What the service pushed in. Recorded, not consumed: the pen's own
        // resolver takes the acceptance radius off the packet it snapshotted
        // at press (one gesture, one set of ranges), and the service applies
        // its own gather cutoff before a candidate ever reaches `proximity`.
        // They are held so a reader — and the unittests below — can see that
        // the push arrived.
        private float innerPx_ = -1.0f, outerPx_ = -1.0f;
        private GuideDrawState draw_ = GuideDrawState.Off;

        /// Point the guide at the mesh and the admission policy of the gesture
        /// that is starting.
        ///
        /// `interiorOk` is `innerSnap`, in the SAME polarity — not the
        /// `borderOnly` negation the scan parameter used to carry. Stated
        /// because the flip is one character and the two spellings coexisted
        /// during this move; the 0496 Split cases below are what catch it.
        ///
        /// `backFaceOk` is `backFace`, likewise in the SAME polarity: TRUE
        /// opens back-facing candidates. It defaults to the MEASURED default
        /// (OFF, i.e. the orientation test runs) so a caller that forgets it
        /// gets the reference's behaviour rather than the permissive one.
        void retarget(Mesh* m, bool interiorOk, bool backFaceOk = false) {
            mesh_       = m;
            interiorOk_ = interiorOk;
            backFaceOk_ = backFaceOk;
            polyKey_.invalidate();
        }

        /// Aim the guide at the query that is about to run. See the block
        /// comment: OURS, because the interface pushes ranges but not a cursor.
        ///
        /// Also derives this query's one screen ray (`aimDir_`), which the
        /// orientation test in `admits` dots every candidate normal against.
        /// `screenPointToRay` rather than `screenRay` so an ORTHOGRAPHIC
        /// viewport answers with its view forward instead of an inverted
        /// perspective matrix it does not have.
        void aimAt(const ref Viewport vp, int mx, int my) {
            aimVp_ = vp;
            aimX_  = mx;
            aimY_  = my;
            Vec3 org;
            screenPointToRay(cast(float)mx, cast(float)my, vp, org, aimDir_);
            // Task 0619 §1.4: the primary layer's LOCAL copy of this same
            // ray direction, resolved ONCE per aim. `orientationAdmits`
            // dots it against local face normals, so this replaces an
            // O(faces) normal transform with one O(1) direction transform.
            // `aimVp_`/`aimDir_` stay WORLD: `proximity` receives world
            // candidate positions from the snapping service and must keep
            // measuring its pixel distance in the world viewport.
            aimDirLocal_ = primaryModelSpace().toLocalDir(aimDir_);
            aimed_ = true;
        }

        /// THE PEN'S ADMISSION RULE, and the only copy of it.
        ///
        /// Shaped as `snap.SnapAdmit` so the pen's own resolver can hand it
        /// straight to a candidate walk, and called by `proximity` below so
        /// the service's walk applies the identical rule. One predicate, two
        /// channels — which is the reference's own arrangement: its pen
        /// carries an admission callback on its own snap call AND registers a
        /// guide for the framework's, and both enforce the same border rule.
        ///
        /// * VERTICES only. The pen's snap target is a vertex by definition
        ///   (a landing on an edge mid-span is a no-op, not a weld), so every
        ///   other enumerated type is refused rather than silently outranked.
        /// * The ACTIVE mesh only (`slot == 0`). A background layer is a
        ///   snapping source for placement, never a weld target — the pen
        ///   cannot edit it.
        /// * BORDER vertices only, unless `innerSnap` opens the interior. A
        ///   vertex with no incident edges at all is NOT interior and stays a
        ///   candidate, exactly as the scan this replaces had it.
        /// * FRONT-FACING vertices only, unless `backFace` opens the other
        ///   side. See `orientationAdmits` for the test and its provenance.
        ///
        /// `nothrow` by the `SnapAdmit` contract. The count refresh allocates
        /// and is therefore not `nothrow` itself; a failure REJECTS, which is
        /// that contract's own stated answer for a predicate that cannot
        /// decide ("a predicate that needs to fail should reject").
        bool admits(SnapType type, int idx, int slot) nothrow {
            if (type != SnapType.Vertex) return false;
            if (slot != 0)               return false;
            if (mesh_ is null || idx < 0) return false;
            if (idx >= cast(int)mesh_.vertices.length) return false;
            try {
                if (!interiorOk_) {
                    if (!polyKey_.matches(*mesh_)) {
                        polyCount_ = mesh_.edgePolygonCounts();
                        polyKey_.stamp(*mesh_);
                    }
                    if (isVertexInterior(mesh_, polyCount_, cast(uint)idx))
                        return false;
                }
                return orientationAdmits(cast(uint)idx);
            } catch (Exception) {
                return false;
            }
        }

        /// The ORIENTATION half of the admission rule — `backFace`, task 0538.
        ///
        /// MEASURED, law and polarity both. At `backFace` OFF the reference
        /// takes the CANDIDATE'S OWN normal, brings it into the space of the
        /// screen ray, and dots the two: a positive dot — the normal pointing
        /// the same way the ray travels, i.e. away from the viewer — REJECTS.
        /// At `backFace` ON the test is skipped and the candidate is accepted
        /// unconditionally. A ZERO normal is never rejected (its dot is 0, and
        /// the reject is strict `> 0`); that clause is the reference's own,
        /// not a robustness flourish of ours.
        ///
        /// The normal is the UNIFORM (unweighted) average of the incident face
        /// normals — the reference's own default vertex-normal convention,
        /// documented as such and separately confirmed against it on a
        /// deform-tool fixture. `Mesh.faceNormal` returns a UNIT vector, so
        /// summing it is that average and not the area-weighted one a raw
        /// Newell sum would give. A vertex with no incident faces sums to zero
        /// and is therefore admitted, which is the same answer the border half
        /// gives face-less geometry.
        ///
        /// THE SPACES — task 0619 §1.4, and the comment this replaces was
        /// WRONG about them. It said "ours are both in world space
        /// (`Document` has no per-layer transform yet)". `Document` has had
        /// one since 0617, and `mesh_.faceNormal` was never a world normal
        /// in the first place: it is built from `mesh_.vertices[]`, i.e.
        /// LOCAL coordinates. Only `aimDir_` was world. The test therefore
        /// dotted a local normal against a world ray, which is wrong for any
        /// non-identity `M` — including under a pure rotation, where the
        /// numbers stay plausible and the SIGN can still flip near grazing.
        ///
        /// The fix is one direction transform on the RAY, not one normal
        /// transform per face, and its sign correction is **σ = +1** — no
        /// `ms.mirrored`, no `det(M)`:
        ///
        ///     dot(n_local, ms.toLocalDir(d_world))
        ///       == dot(ms.toWorldNormal(n_local), d_world)     EXACTLY,
        ///
        /// for any invertible `M`, mirrored or not, because
        /// `dot((M^-1)^T n, M v) == dot(n, v)` is an identity. Four in-tree
        /// citations, none of them this comment's own opinion:
        ///   * `math.d:428-454` — `ModelSpace.mirrored`'s doc: a front-facing
        ///     test done ENTIRELY in local space needs NO correction,
        ///     mirrored or not; names the three sites that had it backwards
        ///     and says not to reintroduce the flip;
        ///   * `math.d:666-721` — the unittest that checks the local test
        ///     against the true geometric world test (world normal via the
        ///     inverse-transpose) across four `M`s, mirrored and not, and
        ///     whose own comment records that its PREVIOUS version measured
        ///     a winding artefact and could not fail. (The plan cites this
        ///     as `math.d:570-592`; that range is the `toLocalPoint`
        ///     round-trip and `toLocalDir` non-normalisation blocks — the
        ///     line numbers moved, the argument did not.);
        ///   * `math.d:495-512` — `toWorldNormal`'s doc: do NOT "fix" a
        ///     mirror-flipped normal by cross-producting world points;
        ///   * app.d's RMB-lasso `frontFacing` closure, `Mesh.visibleVertices`'
        ///     inline cull, and snap.d's `faceVisible` — the three sites 0617
        ///     converted to exactly this law, each carrying its reason inline.
        ///     (Cited by SYMBOL on purpose: this comment previously carried
        ///     four line numbers and all four had rotted. Re-derivable by
        ///     searching for `ms.mirrored`, which is still read nowhere in
        ///     production.)
        ///
        /// Two laws that are NOT this one, rejected on purpose:
        ///   * the world WINDING normal (`sign(det M)` times this) — a true
        ///     statement about `cross(Mu, Mv)`, and not the facing truth;
        ///   * `mat3(M) * n`, what the lit vertex shader shades with
        ///     (`shader.d:136`). That is the classic wrong normal transform
        ///     under non-uniform scale — a pre-existing shading defect, not
        ///     a definition of facing. Adopting it would import a renderer
        ///     bug into a picking predicate.
        ///
        /// OURS, and unmeasured — the UN-AIMED case. The reference has no such
        /// state: it writes its screen ray immediately before the candidate
        /// search, so the ray is always there when the filter runs. Ours can
        /// be asked before an aim (`admits` is a public seam), and there the
        /// orientation test is SKIPPED rather than inverted into a rejection.
        /// Skipping is what the measured predicate itself does with a
        /// degenerate operand — a zero normal is admitted — while rejecting
        /// would be a policy no measurement carries. The one production caller
        /// (`resolveSnapTargetVert`) aims before it asks.
        ///
        /// NOT cached, deliberately. A per-vertex normal array keyed on
        /// `MeshCacheKey` would go stale under a position-only edit, because
        /// that key is a mutation COUNTER and this tree has transform paths
        /// that move vertices without bumping it — and a stale normal is a
        /// silently wrong admission. Recomputing costs one walk of the
        /// candidate's own face fan, which the border half's
        /// `edgePolygonCounts()` already dwarfs.
        private bool orientationAdmits(uint vi) {
            if (backFaceOk_) return true;   // the test is not run at all
            if (!aimed_)     return true;   // no ray to test against — see above
            Vec3 n = Vec3(0, 0, 0);
            foreach (fi; mesh_.facesAroundVertex(vi))
                n = n + mesh_.faceNormal(cast(uint)fi);
            // `n` is LOCAL (a sum of local winding normals, and the sum is
            // linear so it transports exactly the same way one of them
            // does); `aimDirLocal_` is the aim ray carried into that same
            // space. See this function's doc comment for why the sign needs
            // no correction.
            return !(dot(n, aimDirLocal_) > 0.0f);
        }

        // ---- SnapGuide ----------------------------------------------------

        void limits(float innerPx, float outerPx) {
            innerPx_ = innerPx;
            outerPx_ = outerPx;
        }

        bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       out float distPx, ref int priority)
        {
            if (!admits(type, idx, slot)) return false;
            if (!aimed_) return false;
            float qx, qy, qz;
            if (!projectToWindowFull(candWorld, aimVp_, qx, qy, qz)) return false;
            immutable float dx = qx - cast(float)aimX_;
            immutable float dy = qy - cast(float)aimY_;
            distPx   = hypot(dx, dy);
            priority = kPriority;
            return true;
        }

        void setDrawState(GuideDrawState s) { draw_ = s; }

        uint flags() const { return 0; }

        // ---- readback, for the tests and for a reader ---------------------
        float innerPushedPx() const { return innerPx_; }
        float outerPushedPx() const { return outerPx_; }
        GuideDrawState drawState() const { return draw_; }
        bool  isAimed() const { return aimed_; }
    }

    /// The guide this tool registers for the duration of a gesture. One
    /// object for the tool's lifetime, re-pointed at each gesture's mesh and
    /// policy — the REGISTRATION is what is per-gesture, not the allocation
    /// (the reference re-adds the same object on every move of one drag and
    /// the registry dedups it, which is our registry's behaviour too).
    package PenSnapGuide snapGuide_;

    private PenSnapGuide snapGuide() {
        if (snapGuide_ is null) snapGuide_ = new PenSnapGuide();
        return snapGuide_;
    }

    /// The primary mesh, or null when this tool has no source bound yet —
    /// `mesh` itself CALLS the delegate and would fault on one. Every query
    /// path already guards `meshSrc_ is null` before touching it; the guide
    /// paths run BEFORE those guards (they aim the guide, then query), so
    /// they need the guarded form.
    private Mesh* meshOrNull() { return meshSrc_ is null ? null : meshSrc_(); }

    /// The SNAP stage of the live pipeline, or null when there is none —
    /// every direct-construction unittest, and every headless path. Mirrors
    /// `XfrmToolBase.snapStageForHooks`, same lookup, same null discipline.
    private SnapStage snapStageForGesture() {
        if (g_pipeCtx is null) return null;
        return cast(SnapStage) g_pipeCtx.pipeline.findByTask(TaskCode.Snap);
    }

    /// Gesture start: point the guide at this gesture's mesh + policy and
    /// register it with the service. Idempotent at both ends — the registry
    /// dedups, and `removeGuide` on an unregistered guide is a no-op — so a
    /// malformed DOWN-DOWN-UP sequence cannot leave a double registration or
    /// strand one.
    package void registerSnapGuide() {
        auto g = snapGuide();
        g.retarget(meshOrNull(), innerSnap_, backFace_);
        if (auto st = snapStageForGesture()) st.addGuide(g);
    }

    /// Gesture end. Also called by `deactivate` — a tool switch mid-drag ends
    /// the gesture, and a guide that outlived its tool would keep answering
    /// for a mesh nobody is editing.
    package void unregisterSnapGuide() {
        if (snapGuide_ is null) return;
        if (auto st = snapStageForGesture()) st.removeGuide(snapGuide_);
    }

    // -----------------------------------------------------------------------
    // STARTUP SNAP ARMING — activating this tool turns the application-wide
    // snap enable ON, and dropping it hands the previous value back.
    //
    // MEASURED, and it is the ACTIVATION that does it, not the tool and not
    // the composition. The reference's tool-activation command carries a
    // fourth argument meaning "snap state at startup"; supplying it saves the
    // current app-global snap state and writes the new one. Every one of the
    // twelve shipped UI routes to its pen supplies it — the toolbar button,
    // the HUD form, the system menu, the model-context template, the two tool
    // bars, the three background-constraint variants. Three negative controls
    // rule out the two obvious alternative attributions: a SIBLING retopology
    // preset omits the argument (so it is deliberate and selective, not
    // boilerplate); a pen preset that composes NO snap tool at all still arms
    // (so it is not the composition); and the "bring your own snap preset"
    // atom sits on presets that both do and do not compose one (so that is a
    // different axis — which snap TYPES apply — and not an enable).
    //
    // WHICH IS WHY IT LIVES ON THE TOOL AND NOT ON A PRESET. We have exactly
    // one route to this tool, its own factory id, and every route the
    // reference has arms; putting the arming in `activate()` is therefore
    // "every route arms" stated in the one place all our routes pass through.
    // The moment a pen PRESET appears it inherits the arming for free, which
    // is the behaviour the measurement asks for.
    //
    // WHAT IT COSTS, stated plainly because it is destructive and it is a
    // DEFAULT: with the gate open, a Move drag that releases within the
    // acceptance radius of another vertex ABSORBS the grab into it — one
    // vertex for a vertex grab, both endpoints for an edge grab, all four for
    // a loop grab. That is the whole of the change; the weld itself is not
    // touched here and was already ported, tested and gated on exactly this
    // flag. What limits it at OUR configuration is `innerSnap_`, which
    // defaults OFF: the candidate set is BORDER vertices only, so this welds
    // onto borders and not into the interior of a mesh. The reference's plain
    // pen button is in precisely that configuration; its Drag Weld preset —
    // the unqualified destructive one — additionally composes a vertex-mode
    // snap tool and turns `innerSnap` on, and we ship no such preset.
    //
    // THE SAVE/RESTORE PAIR IS THE STAGE'S, not ours — see
    // `SnapStage.pushEnabled` for why the saved value cannot live on the tool
    // (a scene reset resets the stage BEFORE it drops the tool, so a
    // tool-owned value would be restored on top of the clean slate).
    private void armStartupSnap() {
        if (auto st = snapStageForGesture()) st.pushEnabled(kSnapArmOwner, true);
    }

    /// The mirror, called from `deactivate` — our equivalent of the drop the
    /// reference restores on. Inert if nothing was armed (no pipeline, or the
    /// slot was cleared by a scene reset in between): the pop is keyed on
    /// `kSnapArmOwner`, so an unmatched one writes nothing.
    private void disarmStartupSnap() {
        if (auto st = snapStageForGesture()) st.popEnabled(kSnapArmOwner);
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
    /// narrow for the landing. The candidate SET is the measured one too, and
    /// it is no longer stated here: the admission rule lives on the gesture's
    /// GUIDE (`PenSnapGuide.admits`), and this query consults that one copy.
    ///
    /// The one caller today is the Split gesture, whose target vertex C is by
    /// its own definition the element the drag snaps to (and whose reference
    /// commit is gated on that snap succeeding). Future snap-target consumers
    /// (mid-drag Split feedback, Duplicate re-snap) must come through HERE
    /// rather than call `findSourceVertex` directly, so the candidate set AND
    /// the radius stay stated in one place.
    ///
    /// Aims the guide before it asks it. The guide answers proximity for
    /// whoever is querying, and the cursor is not something the service pushes
    /// in (see `PenSnapGuide`'s block comment), so the query supplies it.
    ///
    /// GATED ON THE MASTER SNAP ENABLE (task 0523). Snapping off means no snap
    /// target, which means no weld — the same answer the service gives every
    /// other client, and the answer the reference gives this one. It is gated
    /// through BOTH of the channels this tool has, which is why the check is
    /// here and not only on the guide: the service's own gate covers the guide
    /// (a disabled stage publishes nothing and never queries), and this covers
    /// the tool's own resolver. The reference's pen tests the shared flag at
    /// the very top of its own snap entry, exactly here, and returns no-snap.
    ///
    /// This was our long-standing divergence — the pen welded unconditionally,
    /// alone among the snapping clients in this tree — and the reading that
    /// would have made it parity is dead: the pen's guide declares no flags at
    /// all, so it never claims the "ignore the global enable" bit, and in the
    /// reference the master enable short-circuits above the guide walk where no
    /// flag could reach it anyway.
    ///
    /// AND THE GATE IS OPEN OUT OF THE BOX, which is a change and a
    /// user-visible one. `SnapStage.enabled` still SHIPS false — the field's
    /// default is untouched and its six other consumers are unaffected — but
    /// this tool ARMS it for the duration of its own activation and hands it
    /// back on the drop (`armStartupSnap` / `disarmStartupSnap`). That is the
    /// reference's mechanism, measured: every shipped route to its pen passes
    /// "snap state at startup" on the activation command. So from here on a
    /// pen drag that lands inside the acceptance radius WELDS, with no setting
    /// touched by the user, and the Split gesture — which was a no-op until
    /// somebody turned snapping on — now runs by default.
    ///
    /// `exclude` (task 0555) names vertices that may not be answered with —
    /// the vertices the querying GESTURE is itself moving. Without it a
    /// dragged vertex is its own nearest candidate at zero distance and every
    /// query answers "you have landed on yourself" — the same self-snap the
    /// transform path already excludes for, at `move.d:applySnapToDelta`.
    /// Empty for the Split caller, which moves nothing.
    package int resolveSnapTargetVert(int mx, int my, const ref Viewport vp,
                                      const(uint)[] exclude = null) {
        if (!dragSnap_.enabled) return -1;
        auto g = snapGuide();
        g.retarget(meshOrNull(), innerSnap_, backFace_);
        g.aimAt(vp, mx, my);
        if (exclude.length == 0)
            return findSourceVertex(mx, my, vp, topoPenSnapAcceptPx(vp, dragSnap_),
                                    &g.admits);
        // Composed, not folded into the guide: the guide states the TOOL'S
        // admission policy (border / orientation), which is a property of the
        // mesh and the attributes, while the moving set is a property of one
        // gesture in flight. Keeping them separate means the guide the snap
        // SERVICE holds keeps answering the same way for every other client.
        scope admit = delegate bool(SnapType t, int idx, int slot) nothrow {
            if (t == SnapType.Vertex && slot == 0)
                foreach (x; exclude) if (cast(int)x == idx) return false;
            return g.admits(t, idx, slot);
        };
        return findSourceVertex(mx, my, vp, topoPenSnapAcceptPx(vp, dragSnap_), admit);
    }

    // -----------------------------------------------------------------------
    // THE DESTRUCTIVE LANDING (task 0555).
    //
    // A Move-family drag does not only re-place its grab: with the
    // application's element snapping ON, a grabbed vertex brought to within
    // the snap ACCEPTANCE radius of another vertex is ABSORBED into it — the
    // grab disappears and the target survives, at the target's own position.
    // Measured (task 0545, reproduced across two boots) at all three grabs:
    // a vertex grab loses one vertex, an EDGE grab loses BOTH of its
    // endpoints — independently, each into its own target — and a LOOP grab
    // loses all four of its. Outside the radius the two configurations are
    // bit-identical, so the radius is the whole gate.
    //
    // WHAT GATES IT, and this is the part that was mis-attributed once: the
    // shared, application-wide snap ENABLE — our `SnapPacket.enabled`, the
    // packet `SnapStage` publishes to every snapping client — and NOT any pen
    // attribute. The reference's own weld branch tests the return of the pen's
    // snap query, and that query returns "no target" immediately unless the
    // framework's global snap state is on; its `innerSnap`/`backFace` rows are
    // read only inside the candidate-ADMISSION callback, where they choose
    // WHICH element is found and never WHETHER the branch is reachable. Both
    // of those are already wired that way here — the gate is
    // `resolveSnapTargetVert`'s first line, the two attributes are
    // `PenSnapGuide.admits` — so this landing needs no gate of its own beyond
    // asking that one query.
    //
    // PER ELEMENT, NOT PER ANCHOR. Each moved vertex resolves its OWN target,
    // at its OWN post-drag screen position, and welds into it alone; a vertex
    // whose query comes back empty is simply left where the move put it. That
    // is what makes an edge grab lose two vertices and a loop grab four, and
    // it is forced by the measurement rather than chosen: a single query at a
    // single cursor pixel returns a single element and cannot account for four
    // absorptions in one gesture.
    //
    // SAME MESH, and this is READ rather than assumed. The third condition of
    // the reference's weld branch compares the first machine word of the
    // grabbed element's id against the snapped target's, and that word is the
    // element's OWNER — the very pointer the tool holds for the mesh instance
    // it is editing (measured on two independent welds, and on 40 of 40 slot
    // samples the owner field equals it; corroborated statically, since the
    // candidate-admission callback tests the same field against the same
    // quantity). It is not a vtable and not a kind tag. So the gate reads:
    // weld only if the target belongs to the SAME MESH as the grab.
    //
    // We satisfy it by CONSTRUCTION rather than by comparing: this query walks
    // the primary layer's mesh and `PenSnapGuide.admits` refuses every slot but
    // 0, so a background layer can be a placement surface and never a weld
    // target. If that admission is ever widened, an explicit owner check has to
    // arrive with it — the reference's refusal arm (differing owners fall
    // through to a plain Move) is read off the branch and has not been
    // observed, so there is no measured behaviour to lean on there either.
    //
    // THE RADIUS IS IN THE ANSWER, not beside it. The reference parks the
    // nearest element in its target slot BEFORE applying the acceptance radius
    // and folds the radius into the query's RETURN only — on one recording ten
    // evaluations had a target parked and only two were inside the radius, so
    // a port that asks "is there a target?" instead of "did the query answer?"
    // would have welded on the other EIGHT. Ours cannot make that mistake by
    // shape: `findSourceVertex` returns -1 unless the winner is within
    // `topoPenSnapAcceptPx`, so the answer IS the radius-gated one and there is
    // no unfiltered slot to read by accident.
    //
    // WHAT IS STILL OURS RATHER THAN MEASURED: the reference runs ONE query
    // from the cursor and, when it answers, dispatches on the TYPE OF THE HIT
    // (not of the grab) into a vertex / edge / polygon weld. That dispatch is
    // inert here and reachable only through a decision taken elsewhere: this
    // tool's snap query admits VERTICES ONLY (`PenSnapGuide.admits`, measured —
    // a landing mid-span is a no-op, not a weld), so the hit type is invariably
    // Vertex and the vertex weld is the only copy that can be selected. Anyone
    // who widens that admission to edges or polygons must bring the matching
    // weld with it and not leave this running per-vertex underneath.
    //
    // The remaining difference is the one the loop measurement forces: we
    // resolve a target PER MOVED VERTEX, the reference resolves one per cursor.
    // They agree on every cell that has been measured. They can differ where a
    // grabbed edge's two endpoints come to rest near vertices of two DIFFERENT
    // edges — we weld both, a single cursor hit reaches at most one of them.
    //
    // AT RELEASE, not per motion event, and that is a divergence in TIMING
    // only. The reference re-evaluates its whole tool from the pre-gesture
    // mesh on every drag event, so it can show the weld mid-drag and undo it
    // by dragging away again; our Move writes vertex positions in place and
    // owns no per-event rebuild, so a mid-drag topology edit would invalidate
    // the very indices the rest of the drag is addressing. The committed
    // result — which is what was measured — is identical either way.
    // -----------------------------------------------------------------------

    /// Resolve one weld target per moved vertex and absorb each into its own,
    /// in a single mesh pass. Returns the number of vertices absorbed.
    ///
    /// `verts` are the vertices the gesture moved, in their CURRENT (post-move)
    /// indices; their live positions are what the queries are aimed at, so this
    /// must be called AFTER the move has been written and BEFORE the mesh is
    /// snapshotted for undo.
    ///
    /// Every moved vertex is excluded from every query, not just its own: the
    /// two endpoints of a dragged edge travel together and each sits well
    /// inside the other's acceptance radius, so a self-set narrower than the
    /// whole moving set would weld the grab into itself and delete it.
    private size_t weldMovedVertices(const(uint)[] verts, const ref Viewport vp) {
        import std.math : lround;
        if (verts.length == 0) return 0;
        // An EARLY-OUT on the shared enable, not the gate: the gate is
        // `resolveSnapTargetVert`'s own first line, one per moved vertex. This
        // spares a projection and a query per vertex in the (default) case
        // where none of them can answer, and it is deliberately redundant —
        // removing it changes no outcome.
        if (!dragSnap_.enabled) return 0;
        auto m = mesh;
        if (m is null) return 0;

        // Pixel (§1.1), hoisted out of the per-moved-vertex loop (§3). The
        // pixel this produces is fed straight back into
        // `resolveSnapTargetVert`, which runs the SAME aiming space over the
        // same mesh — the two must agree or a moved vertex would query at a
        // pixel it was never drawn at.
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());

        uint[2][] pairs;
        foreach (vi; verts) {
            if (vi >= m.vertices.length) continue;   // stale arm — defensive
            ImVec2 pt;
            if (!projectLocalPt(m.vertices[vi], vpAim, pt)) continue;   // off-screen/behind
            immutable int t = resolveSnapTargetVert(cast(int)lround(pt.x),
                                                    cast(int)lround(pt.y), vp, verts);
            if (t < 0) continue;
            pairs ~= [cast(uint)t, vi];
        }
        if (pairs.length == 0) return 0;
        return m.weldVertexPairs(pairs);
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
    // `admit` (S1 of doc/toolpipe_architecture_plan.md) is the CLIENT'S
    // admission rule, consulted once per candidate BEFORE the projection and
    // the distance compare — order is load-bearing for the same reason it is
    // in `snap.snapCursor`'s own walk: a rejected candidate must be as if it
    // were never enumerated, or an inadmissible vertex would shrink `bestD2`
    // and veto an admissible one further away. It defaults to NULL, which
    // admits everything, so every press-time PICK caller stays byte-identical
    // — the press pick is not snapping at all and has no admission policy.
    // The one caller that passes a rule is the SNAP-TARGET resolver, and what
    // it passes is the gesture guide's own predicate (task 0523): the
    // border-only filter used to be a `bool` parameter here, i.e. a policy
    // with no owner that the snapping service could not see.
    package int findSourceVertex(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapAuto,
                                 scope SnapAdmit admit = null) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (thresholdPx < 0.0f) thresholdPx = topoPenPressPickPx(vp);
        // Pixel (§1.1), built ONCE for the whole O(V) scan (§3).
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        int   best   = -1;
        float bestD2 = float.infinity;
        foreach (vi; 0 .. m.vertices.length) {
            if (admit !is null && !admit(SnapType.Vertex, cast(int)vi, 0)) continue;
            ImVec2 pt;
            if (!projectLocalPt(m.vertices[vi], vpAim, pt)) continue;
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
    // THE GATE AFTER THE CONVEXITY TEST is now READ (task 0528) and PORTED
    // (task 0532) — see `ringRefusedByIncidentPolygon` below for the rule,
    // the scope, and which of its clauses this corpus never exercised. It
    // accepted 76 of 270 formed rings on the recording, so it is the strictest
    // thing in this search, and it runs on the hover preview as well as the
    // press because the reference calls it from this same shared search.
    //
    // THE ONE MODELLED TERM, named so it is not mistaken for a measurement:
    // the ranking's 3-space distance is measured against the reference's own
    // internal cursor MODEL point, which is not a quantity we can read. We
    // use this tool's OWN established screen→layer mapping for it
    // (`shiftedLocalPoint` — unproject the cursor onto the constant-view-
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

    // Exact screen coincidence — x AND y, no epsilon. The measured word is
    // "coincides", and the pairs it exempts are a polygon corner and a ring
    // corner that are THE SAME VERTEX, which project bit-for-bit alike.
    static bool samePixel(ImVec2 p, ImVec2 q) {
        return p.x == q.x && p.y == q.y;
    }

    // THE RING GATE (task 0532; READ in task 0528, full provenance in the
    // PRIVATE toolcard). It runs on the FORMED ring, after the convexity
    // test, and it is the last word on whether the cell exists at all:
    //
    //   A ring is REFUSED if, for any polygon INCIDENT TO ONE OF THE RING'S
    //   OWN VERTICES, either
    //     (1) every ring vertex is a vertex of that polygon — a SUBSET test,
    //         not an equality test; or
    //     (2) a ring side PROPERLY crosses one of that polygon's edges in
    //         screen space — both parameters strictly inside (0,1), with
    //         endpoint-coincident pairs exempt.
    //   Polygons of TWO OR FEWER corners are exempt from the whole gate.
    //
    // It accepted 76 of 270 formed rings on the recording; clause 1 accounts
    // for all 194 refusals.
    //
    // SCOPE is load-bearing, and it is also the cheap reading: both clauses
    // quantify over polygons incident to a ring vertex, NEVER over the whole
    // mesh. A ring side may cross a distant face's edge freely.
    //
    // ORDER-FREE. Any eligible incident polygon that refuses short-circuits,
    // and each is tested at most once, so the verdict is a pure OR over the
    // eligible incident set — the traversal order below is ours and cannot
    // change the answer.
    //
    // CLAUSE 1 IS NOT OUR DUPLICATE-FACE GUARD, and the difference is the
    // whole point of porting this. `Mesh.makePolygonFromVerts`'s guard is
    // length-gated (`f.length != idx.length` skips), so it fires only on
    // ring == polygon. This fires on ring ⊆ polygon; the STRICT-subset rings
    // are exactly what separates "subset" from "duplicate face" as the
    // measured word (30 of the 194 recorded refusals, a 3-ring on a quad).
    //
    // DECODED-UNEXERCISED — named so none of it is read as confirmed:
    //   * clause 2 fired ZERO times in the 270 recorded rings. It reached its
    //     LAST comparison 133 times and every one of those crossings ran past
    //     the incident edge's own extent. It is ported from the read, not
    //     from a firing, and the sibling lane's lesson applies: the same
    //     wording about the candidate-gather reject above became the dominant
    //     filter one recording later.
    //   * the ≤2-corner exemption never saw a line or point polygon on that
    //     rig. Carried anyway because `commitFill` CREATES that situation on
    //     our own substrate — `consumeDegeneratePolysOnRing` deletes exactly
    //     such polygons off the new ring — so it is reachable here in a way
    //     it was not there.
    //   * a ring strictly CONTAINING a smaller face was never formed. Clause
    //     1 as written cannot refuse one, and nothing is invented for it.
    //
    // NOT PORTED, named rather than guessed: the eligibility test also reads
    // one bit of a per-polygon type word. That bit is decoded as a bit test
    // only — never identified, and constant across all 2356 recorded
    // evaluations — so only the corner-count half is carried.
    //
    // OURS, not the reference's: a vertex that fails to PROJECT has no screen
    // position, so the sides through it drop out of clause 2. The reference's
    // transform has no failure branch; ours does, and every other screen-space
    // predicate in this tool skips on it. Clause 1 is purely topological and
    // is unaffected either way.
    // Task 0619 Stage 4a: this is a screen-space predicate over PRIMARY-layer
    // vertices, so its viewport parameter is the AIMING space (§1.1) — the
    // caller composes it once (`fillRingFromSeed` already has one) and the
    // TYPE is what stops a world viewport reaching a local vertex here. The
    // function is `static`, so it cannot resolve a `ModelSpace` of its own;
    // taking the composed viewport is also what keeps that honest.
    static bool ringRefusedByIncidentPolygon(const(Mesh)* m, const(uint)[] ring,
                                             const ref AimViewport vpAim) {
        if (m is null || ring.length == 0) return false;

        // The ring's own screen corners, once.
        auto ringPix = new ImVec2[](ring.length);
        auto ringOk  = new bool[](ring.length);
        foreach (i, v; ring)
            if (v < m.vertices.length)
                ringOk[i] = projectLocalPt(m.vertices[v], vpAim, ringPix[i]);

        foreach (const ref f; m.faces) {
            if (f.length <= 2) continue;         // ELIGIBILITY (unexercised)

            // INCIDENCE + clause 1's count in one walk: a polygon is tested
            // only if it carries at least one of the ring's own vertices.
            // The ring's entries are distinct by construction (the search
            // drops a candidate already in the list), so this counts DISTINCT
            // ring vertices.
            bool   incident = false;
            size_t matched  = 0;
            foreach (v; ring) {
                bool inFace = false;
                foreach (u; f) if (u == v) { inFace = true; break; }
                if (inFace) { incident = true; ++matched; }
            }
            if (!incident) continue;

            if (matched == ring.length) return true;          // CLAUSE 1

            // CLAUSE 2 — every polygon edge against every ring side, wrapped
            // on both. Reuses `segmentsProperlyCross`, the SAME predicate the
            // candidate-gather reject runs, rather than a second copy of the
            // arithmetic.
            //
            // The endpoint exemption in front of it is the reference's own,
            // and it is carried for faithfulness rather than for effect: it is
            // REDUNDANT on our substrate and measured to be so. Deleting it
            // moves no test in this file, because coincident corners project
            // to bit-identical pixels here, and the resulting parameters come
            // out exactly 0 or 1 (or the denominator exactly 0), which strict
            // (0,1) already rejects. Kept because the read has it explicitly,
            // because it is free, and because it is the one thing standing
            // between a shared corner and a spurious refusal if a future
            // projection path ever stops being bit-exact. Do not "simplify" it
            // away on the grounds that no test fails — that is recorded here
            // precisely so the next reader does not have to re-derive it.
            ImVec2 prev;
            bool   prevOk = f[$ - 1] < m.vertices.length
                         && projectLocalPt(m.vertices[f[$ - 1]], vpAim, prev);
            foreach (t; 0 .. f.length) {
                ImVec2 cur;
                immutable bool curOk = f[t] < m.vertices.length
                                    && projectLocalPt(m.vertices[f[t]], vpAim, cur);
                if (prevOk && curOk)
                    foreach (i; 0 .. ring.length) {
                        immutable size_t j = (i + 1) % ring.length;
                        if (!ringOk[i] || !ringOk[j]) continue;
                        immutable ImVec2 a = ringPix[i], b = ringPix[j];
                        if (samePixel(prev, a) || samePixel(prev, b)
                         || samePixel(cur,  a) || samePixel(cur,  b)) continue;
                        if (segmentsProperlyCross(a, b, prev, cur)) return true;
                    }
                prev = cur; prevOk = curOk;
            }
        }
        return false;
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
    package int fillSeedEdge(int mx, int my, const ref Viewport vp) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (pickPrimaryFace(mx, my, vp) >= 0) return -1;   // POLYGON press

        immutable float cx = cast(float)mx, cy = cast(float)my;

        // Pixel (§1.1), built ONCE for both the O(V) and the O(E) scan (§3).
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());

        float bestVertD = float.infinity;
        foreach (vi; 0 .. m.vertices.length) {
            ImVec2 pv;
            if (!projectLocalPt(m.vertices[vi], vpAim, pv)) continue;
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
            if (!projectLocalPt(m.vertices[e[0]], vpAim, pa)) continue;
            if (!projectLocalPt(m.vertices[e[1]], vpAim, pb)) continue;
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
    package uint[] findFillRing(int mx, int my, const ref Viewport vp) {
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
        if (seedA == seedB) return null;   // malformed edge — two slots, one vertex

        immutable float cx = cast(float)mx, cy = cast(float)my;
        // Pixel (§1.1), built ONCE at function entry and reused by every
        // scan below AND by `ringRefusedByIncidentPolygon` at the tail (§3).
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        ImVec2 pSeedA, pSeedB;
        if (!projectLocalPt(m.vertices[seedA], vpAim, pSeedA)) return null;
        if (!projectLocalPt(m.vertices[seedB], vpAim, pSeedB)) return null;

        // GATHER radius = range × the hover radius. `range` 0 leaves nothing
        // but the seeds reachable, so the count gate refuses — the measured
        // "below the threshold the gesture refuses" branch, at its extreme.
        immutable float reachPx =
            fillRange_ * fillHoverRadiusPx(cx, cy, pSeedA, pSeedB);

        // The cursor's 3-space point — the ONE modelled term, see the block
        // comment above. Task 0619: both operands of the RANKING distance
        // below are now in the SAME space. They were not: `m.vertices[v]` is
        // local and this point used to be a world ray met against a local
        // anchor, so under any layer transform the ranking compared two
        // different frames — a quantity in no space at all.
        //
        // WHICH space the ranking should run in, once they agree, is a
        // JUDGEMENT and not a measurement: the gather and the crossing reject
        // are already screen-space, and only this last tie-break is 3D. LOCAL
        // is chosen because that is where `m.vertices[v]` lives and because it
        // is the smaller change; under a non-uniform scale a WORLD ranking
        // would order the survivors differently. The reference's own cursor
        // model point is unreadable (see above), so no capture settles it.
        immutable Vec3 seedMid = (m.vertices[seedA] + m.vertices[seedB]) * 0.5f;
        immutable Vec3 cursorPt = shiftedLocalPoint(seedMid, mx, my, vp);

        // The screen segments the crossing reject tests against: every edge
        // of every polygon incident to EITHER seed, gathered once. The
        // reference walks seed → polygon → edge and marks polygons visited;
        // what that marking changes is UNREAD, but it cannot change this
        // boolean — testing one polygon twice yields the same answer — so the
        // union is equivalent for the predicate's purposes.
        ImVec2[2][] barriers;
        foreach (const ref f; m.faces) {
            bool touchesSeed = false;
            foreach (v; f) if (v == seedA || v == seedB) { touchesSeed = true; break; }
            if (!touchesSeed || f.length < 2) continue;
            foreach (k; 0 .. f.length) {
                immutable uint u0 = f[k], u1 = f[(k + 1) % f.length];
                if (u0 >= m.vertices.length || u1 >= m.vertices.length) continue;
                ImVec2 q0, q1;
                if (!projectLocalPt(m.vertices[u0], vpAim, q0)) continue;
                if (!projectLocalPt(m.vertices[u1], vpAim, q1)) continue;
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
            if (!projectLocalPt(m.vertices[v], vpAim, pv)) continue;
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
        // rigs, two boots, two cameras. It does NOT skip the ring gate below:
        // 30 of the recording's 194 refusals were a 3-ring.
        uint[] ring;
        if (n == 3) {
            ring = slot[0 .. 3].dup;
        } else {
            ImVec2[4] sp;
            foreach (k; 0 .. 4)
                if (!projectLocalPt(m.vertices[slot[k]], vpAim, sp[k])) return null;

            if (screenQuadConvex(sp[0], sp[1], sp[2], sp[3])) {
                ring = slot[0 .. 4].dup;
            } else if (screenQuadConvex(sp[0], sp[1], sp[3], sp[2])) {
                immutable uint tmp = slot[2]; slot[2] = slot[3]; slot[3] = tmp;
                ring = slot[0 .. 4].dup;
            } else {
                return null;
            }
        }

        // THE RING GATE (task 0532) — the last gate, on the FORMED ring, in
        // the order the build would use. It lives HERE and not in
        // `commitFill` because the reference calls it from this shared search:
        // 270 calls on the recording, at most 6 of them presses. So the HOVER
        // PREVIEW (`fillRing_`) obeys the same verdict as the press, and the
        // highlight can never offer a cell the press then refuses to build.
        //
        // A refusal returns `null`, which routes `fillDown` into the already-
        // ported destructive fall-through (arm Move on the pressed edge) — the
        // same fall-through the recording shows for a press that fails to arm.
        if (ringRefusedByIncidentPolygon(m, ring, vpAim)) return null;
        return ring;
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
        // Task 0523: and register this gesture's snapping guide, on the same
        // unconditional press-to-release window and for the same reason. The
        // registration is NOT gated on the master snap enable — the service's
        // own gate short-circuits above the guide walk (a disabled `SnapStage`
        // publishes nothing and never queries), which is where the reference
        // puts it too: its master-enable test sits above the guide loop, not
        // inside the guide.
        registerSnapGuide();
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
    package void resetAllGestureArms() {
        // EVERY arm bit, from the compiler's own list (task 0705): each field
        // declared `GestureArm` is disarmed here, so a gesture added later is
        // cleared by this helper without anyone remembering to say so. The
        // per-gesture PAYLOAD below (seeds, cached index runs, drag
        // accumulators) is still spelled out by hand — that part is not one
        // uniform shape and each block documents its own reason for the value
        // it resets to.
        static foreach (m; kGestureArmFields)
            __traits(getMember, this, m) = GestureArm.init;

        // Mode router (task 0483) — the per-press record of WHICH gesture the
        // unmodified-LMB slot resolved to. Neutral value first, so a press
        // that declines leaves behind an UP leg that is a guarded no-op
        // rather than a stale mode's commit.
        gestureOn_[]    = PenGesture.PlaceOrMove;
        // P3 build (doc/topopen_p3_plan.md)
        sourceVert_     = -1;
        classifiedCase_ = BuildCase.None;
        triN_ = quadP_ = quadQ_ = quadTriFi_ = -1;
        // P4 Move/Place (doc/topopen_p4_plan.md) + the task-0484 element grab.
        // `clearMoveArm` drops the live drag's base positions and its
        // arm-time snapshot WITHOUT recording anything — correct for every
        // caller of this helper: a same-slot re-press starts a fresh gesture,
        // and `resyncSession` runs when an external history navigation has
        // already replaced the mesh this drag was editing, so there is no
        // "before" left that a recorded entry could mean anything against.
        clearMoveArm();
        // P6 Add Loop (doc/topopen_p6_addloop_plan.md)
        addLoopSeed_    = -1;
        // P7 Slide (doc/topopen_p7_slide_plan.md)
        slideSeed_   = -1;
        slideEndA_ = slideEndB_ = -1;
        slideNbrA_ = slideNbrB_ = -1;
        slideAnchor_ = Vec3(0, 0, 0);
        slideDeltaK_ = 0.0f;
        // P8 Smooth (doc/topopen_p8_smooth_plan.md)
        smoothDragDx_ = 0;
        // P9 Split (doc/topopen_p9_split_plan.md) — cleared here so the
        // LEFT-button trio's own reset closes a stray split arm too (e.g. an
        // external history navigation via `resyncSession`, below); the
        // MIDDLE-button `onPlainMmbDown` does NOT call this helper (REV1
        // FIX-1 — see that handler's own doc comment) and uses its own
        // narrow self-reset instead.
        splitSourceVert_ = -1;
        splitTargetVert_ = -1;
        // P10 Move Loop (doc/topopen_p10_moveloop_plan.md) — cleared here so
        // the LEFT-button trio's own reset (and `resyncSession`, below) close
        // a stray move-loop arm too; `onMoveLoopRmbDown` (the RIGHT-button
        // handler) does NOT call this helper (same RMB/MMB-button discipline
        // as `onShiftMmbDown`/`onPlainMmbDown` above — a RIGHT-button press
        // genuinely CAN be a two-button chord while a LEFT gesture is still
        // held) and uses its own narrow self-reset instead.
        moveLoopSeed_  = -1;
        moveLoopVerts_ = null;
        // P11 Dup Loop (doc/topopen_p11_duploop_plan.md) — cleared here so
        // the LEFT-button trio's own reset (and `resyncSession()`, below)
        // close a stray dup-loop arm too; `onDupLoopShiftRmbDown` (the
        // Shift+RMB handler) does NOT call this helper (same RMB-button
        // discipline as `onMoveLoopRmbDown` above — a RIGHT-button press
        // genuinely CAN be a two-button chord while a LEFT gesture is still
        // held) and uses its own narrow self-reset instead.
        dupLoopSeed_  = -1;
        dupLoopEdges_ = null;
        // Duplicate EDGE (task 0485) — the Shift+LMB sibling; cleared here
        // for the same reason as every LEFT-button arm above.
        dupEdgeSeed_  = -1;
        dupEdgeEdges_ = null;
        // P12 Smooth+Loop (doc/topopen_p12_smoothloop_plan.md) — cleared
        // here so the LEFT-button trio's own reset (and `resyncSession()`,
        // below) close a stray smooth-loop arm too; `onSmoothLoopRmbDown`
        // (the Shift+Ctrl+RMB handler) does NOT call this helper (same
        // RMB-button discipline as `onMoveLoopRmbDown`/
        // `onDupLoopShiftRmbDown` above) and uses its own narrow self-reset
        // instead.
        smoothLoopSeed_   = -1;
        smoothLoopVerts_  = null;
        smoothLoopDragPx_ = 0.0f;
    }

    // MINOR-3 (doc/topopen_hover_highlight_plan.md REV1): the single source
    // of truth for "is ANY gesture currently armed" — the OR of every arm
    // flag `resetAllGestureArms()` (immediately above) clears. The two
    // helpers travel together, and since task 0705 they travel over the SAME
    // derived list (`kGestureArmFields`): this predicate cannot see a
    // different set of arms than the reset clears, because neither of them
    // names an arm.
    //
    // MAINTENANCE CONTRACT (now enforced by the compiler, not by this
    // comment): a new gesture's arm flag is declared `GestureArm` and that is
    // the whole contract — it is OR'd in here and cleared over there by
    // construction. What this comment used to say, and what the code used to
    // require, was that the flag be added to THREE hand-written lists (this
    // OR, the reset's assignments, and a Tier-A pin unittest) plus two prose
    // enumerations. Those five had already drifted: the prose above said "9"
    // in one paragraph and "10" in the next, the pin test listed 10, and
    // `dupEdgeArmed_` (task 0485) was in none of them although it was in the
    // OR — i.e. the guard everybody trusted was pinning 10 of 11 flags.
    package bool anyGestureArmed() const {
        static foreach (m; kGestureArmFields)
            if (__traits(getMember, this, m).armed) return true;
        return false;
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
    package bool onPlainLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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
        Viewport vp = viewportOf(vts);

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

        Viewport vp = viewportOf(vts);
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
    // Proximity order — vertex within `topoPenPressPickPx` (unless the veto
    // below clears it), else edge within the same radius, else the face under
    // the cursor. `index` is the resolved element's own index in its own array
    // (vertex / edge / face), or -1.
    //
    // `pickPrimaryFace` needs `gpu_` and answers -1 without it, so under a
    // bare `dub test` (no GL) only the vertex and edge terms are live — the
    // face term is exercised by the HTTP tests, which have a real upload.
    package MoveElem resolveGrabTarget(int mx, int my, const ref Viewport vp, out int index) {
        index = -1;
        auto m = mesh;
        if (m is null) return MoveElem.None;

        // Explicit `>= 0` on every pick, never a truthiness test: these
        // answer -1 on a miss, and index 0 is a perfectly ordinary element.
        //
        // The edge is resolved BEFORE the vertex clause answers, because the
        // veto needs the winning edge to have something to veto WITH. That
        // costs a vertex-hit press one edge scan it did not use to pay; it is
        // not avoidable, since the whole rule is a comparison against the
        // winning edge.
        immutable int vi = findSourceVertex(mx, my, vp);
        immutable int ei = findRingSeedEdge(mx, my, vp);

        if (vi >= 0 && vi < cast(int)m.vertices.length
                && !pressVertexVetoed(mx, my, vp, vi, ei)) {
            index = vi;
            return MoveElem.Vertex;
        }

        if (ei >= 0 && ei < cast(int)m.edges.length) { index = ei; return MoveElem.Edge; }

        immutable int fi = pickPrimaryFace(mx, my, vp);
        if (fi >= 0 && fi < cast(int)m.faces.length && m.faces[fi].length >= 3) {
            index = fi;
            return MoveElem.Face;
        }
        return MoveElem.None;
    }

    // ------------------------------------------------------------------
    // THE VERTEX-SLOT VETO ON THE PEN'S PRESS PICK (measured static).
    //
    // THE RULE: clear the vertex slot when the cursor is nearer the WINNING
    // EDGE'S MIDPOINT than it is to the best vertex, provided that midpoint is
    // inside the caller's range. A cleared slot is not demoted — it is removed
    // from the cascade outright, so the next clause answers and the press
    // grabs the EDGE.
    //
    // WHY IT EXISTS, since the rule does not say: the projected midpoint of an
    // edge lies on that edge's projected segment, so "the midpoint is nearer
    // than the vertex" is a sharper way of asking "is the cursor out along the
    // edge rather than parked on its endpoint" than the raw vertex distance
    // is. Near a shared corner every incident edge is within a pixel or two of
    // the vertex, and without this a press aimed at the middle of an edge
    // grabs the corner instead.
    //
    // A SEPARATE MECHANISM from the snapping service's centre refinement, and
    // this is the correction a sibling read had to be given: it is built from
    // the same number (the winning edge's midpoint) at a different site, with
    // different gating and a different effect. The refinement MOVES a point
    // and is gated on a snap type; this REMOVES a candidate and is gated on
    // nothing. Modelling it as "edge-centre snapping" would make it switch off
    // with a preference it has no relationship to.
    //
    // NOT THE SAME PORT `snap.d` ALREADY HAS. `snap.vertexSlotVetoed` is the
    // same rule inside the snap arbitration, reached only when a snap type
    // asked for an edge leg. This one is the PRESS PICK's, it runs on every
    // press, and no snap setting can reach it. The two are deliberately not
    // shared: they read different ranges (the pen's own press reach vs. the
    // configured acceptance), from different origins, over different candidate
    // sets.
    //
    // NOT PORTED INTO THE ORDINARY SELECTION CLICK, and that was checked
    // rather than assumed: our selection click goes through a different
    // resolver that carries no cross-type slots, so there is nothing there to
    // veto and our view-cache/BVH pick is already the right shape.
    //
    // WHERE IT IS APPLIED, and the limit is named rather than left to be
    // found. Exactly the two press picks that already hold BOTH a vertex slot
    // and an edge slot and already run a vertex-then-edge cascade:
    // `resolveGrabTarget` (Move / Point, and the hover indicator that must
    // name what a press will grab) and `onShiftLmbDown` (Duplicate). The pen's
    // vertex-ONLY press picks — Split's, and the build's source-vertex
    // resolution — are deliberately left alone: they run no edge query at all,
    // so applying the veto there would mean inventing an edge candidate for
    // the sole purpose of DECLINING a press those modes currently honour.
    // Declining is a behaviour claim nothing measured; the veto's own effect
    // is to hand the press to an edge branch, and those modes have none.
    //
    // Returns true when the resolved vertex must be treated as if it had never
    // been found.
    private bool pressVertexVetoed(int mx, int my, const ref Viewport vp,
                                   int vi, int ei) {
        // Both slots must be occupied. In the reference these are two null
        // tests on a hit record; here they are the two picks having answered,
        // which is the same question asked one step earlier.
        if (vi < 0 || ei < 0) return false;
        auto m = mesh;
        if (m is null) return false;
        if (vi >= cast(int)m.vertices.length || ei >= cast(int)m.edges.length)
            return false;
        auto e = m.edges[ei];
        if (e[0] >= m.vertices.length || e[1] >= m.vertices.length) return false;

        // Pixel (§1.1) — `mid` is the average of two LOCAL vertices, which
        // is itself a local point (an affine map commutes with a midpoint),
        // so both operands go through the same aiming space and the two
        // pixel distances compared below are both measured against the
        // DRAWN geometry.
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        immutable Vec3 mid = (m.vertices[e[0]] + m.vertices[e[1]]) * 0.5f;
        ImVec2 pm, pv;
        if (!projectLocalPt(mid, vpAim, pm)) return false;             // does not project
        if (!projectLocalPt(m.vertices[vi], vpAim, pv)) return false;

        immutable float dMid = hypot(pm.x - cast(float)mx, pm.y - cast(float)my);
        // The RANGE clause, and it uses the pen's own single press reach —
        // the same number that gated both picks above. The pen's press pick is
        // type-uniform by construction, so there is exactly one range here and
        // no question of which one the veto borrows.
        if (dMid >= topoPenPressPickPx(vp)) return false;
        immutable float dVert = hypot(pv.x - cast(float)mx, pv.y - cast(float)my);
        return dMid < dVert;
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
    package MoveElem hoverIndicatorElem() const {
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
    package int[] trimBorderRunAroundSeed(const(int)[] gathered, int seed) {
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
    package Vec3[] moveTargets(int px, int py, const ref Viewport vp, ref VectorStack vts) {
        if (moveElem_ == MoveElem.Vertex) {
            Vec3[] one = [ moveBase_[0] ];
            readHit(vts);   // the CONS-snapped hit for THIS event's pixel
            // Landing (§1.5): `moveBase_` is LOCAL (arm-time `m.vertices[]`)
            // and `lastHit_.point` is the CONS stage's WORLD hit, so this
            // one array carried two spaces depending on whether the cursor
            // was over a background surface. `applyMoveTargets` writes the
            // result to `m.vertices[]`, so local is the space it must be in.
            if (lastHit_.hit) one[0] = primaryModelSpace().toLocalPoint(lastHit_.point);
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
        immutable int dx = px - moveStartX_, dy = py - moveStartY_;
        if (releaseIsClick(dx, dy)) return moveBase_.dup;

        return perVertexTargetsFrom(moveBase_, dx, dy, vp);
    }

    // Apply `targets` to the armed moving set in place — the live half of the
    // drag (task 0484). No snapshot, no history: `moveBefore_` was taken at
    // arm time and the single undo entry is recorded once, at release
    // (`finishMove`). Sets `moveDirty_` so a gesture that never actually
    // moved anything stays a true no-op.
    package void applyMoveTargets(const(Vec3)[] targets) {
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
        // The destructive landing (task 0555), between the final placement and
        // the undo record so the absorption rides the SAME entry the move
        // does. Gated on `moveDirty_`: a grab that never moved anything cannot
        // have been "brought to within" anything, and welding on a bare click
        // would eat any vertex that merely happened to sit inside the
        // acceptance radius all along.
        if (moveDirty_ && weldMovedVertices(moveVerts_, vp) > 0) {
            moveWelded_ = true;
            afterWeld();
        }
        recordLiveMove();
        // A weld changed the TOPOLOGY, so — unlike a plain Move — every index
        // any sibling gesture cached may now name different geometry. Same
        // discipline as this tool's other topology-changing commits, and it
        // runs AFTER the record because `resyncSession` drops the arm state
        // `recordLiveMove` reads.
        if (moveWelded_) resyncSession();
    }

    /// Post-weld housekeeping shared by the two Move commit paths: the mesh
    /// has been rebuilt and compacted underneath the display, so re-sync
    /// selection and re-upload. `weldVertexPairs` has already fired its own
    /// `commitChange(Geometry)`.
    private void afterWeld() {
        auto m = mesh;
        if (m is null) return;
        m.syncSelection();
        // Both calls under the gpu guard — `commitMoveLoop`'s shape, not
        // `applyMoveTargets`'s: `refreshDisplay` dereferences the GpuMesh
        // unconditionally once the active-mesh resolver is unset, which is
        // exactly the state a GL-free unit rig runs in.
        if (gpu_ !is null) { gpu_.upload(*m); refreshDisplay(m, gpu_, vc_, ec_, fc_); }
    }

    // Record whatever the live drag has already written, WITHOUT computing
    // new targets — the tool-switch path (`deactivate`), which has no event
    // and therefore no pixel to compute them for. Disarms afterwards, so a
    // reactivation starts clean.
    //
    // And therefore NO destructive landing either (task 0555): the landing is
    // part of committing a RELEASE, and this path has no release — it is the
    // salvage of a drag the user abandoned by switching tools. It records the
    // positions as they stand. Deliberate, and the same shape as the rest of
    // this path: it computes nothing new, it only keeps what is already there.
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
    package void recordLiveMove() {
        if (!moveDirty_) return;
        auto m = mesh;
        if (m is null || !commitReady(factories_.move)) return;

        // A drag that wandered and came home again HAS written the mesh
        // (`moveDirty_`), but its net effect is nothing — recording it would
        // put an undo entry on the stack that restores what is already there.
        // Compare the moving set against its arm-time base and drop the
        // entry when they agree; only the moving set can have changed, so
        // this stays O(set), not O(mesh).
        enum float kNetEps = 1e-4f;   // the same eps `applyMoveTargets` writes by
        // A weld is never a net no-op — it removed geometry — and the loop
        // below could not judge it anyway: `moveVerts_` holds PRE-weld indices
        // and the weld compacted the vertex array under them (task 0555).
        bool net = moveWelded_;
        foreach (i, vi; moveVerts_) {
            if (net) break;
            if (vi >= m.vertices.length) { net = true; break; }   // stale: record, don't lose it
            if ((m.vertices[vi] - moveBase_[i]).length > kNetEps) { net = true; break; }
        }
        if (!net) return;

        recordSnapshotUndo(m, moveBefore_, factories_.move, "Topology Move");
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
        moveWelded_  = false;
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
    package bool onShiftLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // Phase-3 dispatch cleanup (doc/topopen_input_dispatch_phase2_plan.md §Phase 3,
        // same rationale as `onPlainLmbDown` above): this row's
        // `ResetScope.AllButtons` already fires `resetAllGestureArms()` via
        // `dispatchInput`'s `onInputResetAll()` hook before this handler runs.

        Viewport vp = viewportOf(vts);
        int src = findSourceVertex(e.x, e.y, vp);
        // The press pick's vertex-slot veto (`pressVertexVetoed`) — the same
        // one `resolveGrabTarget` runs, at the pen's other vertex-then-edge
        // press cascade. The edge is resolved up front because the veto needs
        // it, and it is the very edge the fall-through branch takes, so the
        // scan is not duplicated — only moved ahead of a branch that used to
        // skip it on a vertex hit.
        immutable int seedEi = findRingSeedEdge(e.x, e.y, vp);
        if (src >= 0 && pressVertexVetoed(e.x, e.y, vp, src, seedEi)) src = -1;
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
            immutable int ei = seedEi;
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
        // Task 0617: this picks the PRIMARY layer (per the doc comment
        // above), so it resolves the live primary ModelSpace through the
        // same cross-module accessor http_providers.d uses — this module
        // has no `Document` of its own.
        import document : primaryModelSpace;
        return removePick_.pickFace(mx, my, vp, *m, *gpu_, primaryModelSpace());
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
        Viewport vp = viewportOf(vts);
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
    // NO admission parameter, deliberately (task 0523). This query has exactly
    // one kind of caller — a press-time PICK — and a press pick is not
    // snapping: no guide is registered for it, no configured range is pushed
    // into it. It used to carry a `borderOnly` twin of `findSourceVertex`'s,
    // added for a snap-target consumer over EDGES that was never written; no
    // caller ever passed it. A second, unowned copy of the pen's admission
    // rule is precisely what moving that rule onto the gesture's guide is
    // for, so it goes. A future edge snap-target asks the guide, as the
    // vertex one now does.
    package int findRingSeedEdge(int mx, int my, const ref Viewport vp,
                                 float thresholdPx = kTopoPenSnapAuto) {
        if (meshSrc_ is null) return -1;
        auto m = mesh;
        if (m is null) return -1;
        if (thresholdPx < 0.0f) thresholdPx = topoPenPressPickPx(vp);
        // Pixel (§1.1), built ONCE for the whole O(E) scan (§3).
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        int   best   = -1;
        float bestD  = float.infinity;
        foreach (ei, e; m.edges) {
            ImVec2 pa, pb;
            if (!projectLocalPt(m.vertices[e[0]], vpAim, pa)) continue;
            if (!projectLocalPt(m.vertices[e[1]], vpAim, pb)) continue;
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
    package void computeHoverIndicator(int mx, int my, const ref Viewport vp) {
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

    // P6 (doc/topopen_p6_addloop_plan.md Phase 2): the directed LAYER-LOCAL
    // endpoints `ratioFromCursor` measures the `[0,1]` ratio against (task
    // 0619 corrected "world-space" here — every `out` below is a raw
    // `m.vertices[]` read) — MUST
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
    //
    // AIMING KIND: **Closest** (task 0619,
    // doc/tool_aiming_item_transform_plan.md §1.3), and it is the ONE kind
    // whose correct space is WORLD — deliberately the opposite of the
    // RayPlane law `shiftedLocalPoint` below runs:
    //
    //   * the closest-approach election is NOT affine-invariant. Under a
    //     non-uniform `M` the 3D-nearest point of the LOCAL rail to the local
    //     ray maps to a DIFFERENT point than the 3D-nearest point of the
    //     WORLD rail to the world ray. The user scrubs along the rail as it
    //     is DRAWN, so world is the election the cursor means;
    //   * the result converts back for FREE: what leaves here is a RATIO
    //     along the rail, and an affine map preserves ratios along a line —
    //     so the world `t` IS the local `t` `insertEdgeLoops` wants. No
    //     back-transform, no new primitive;
    //   * applying §1.2's "move it into local" law here compiles and is
    //     invisible at identity AND under uniform scale. That is why the
    //     parameters say `Local` and this comment says WORLD.
    //
    // The one caller (`ratioFromCursor`) passes `seedRailA_`/`seedRailB_`,
    // which `seedRail` fills from raw `m.vertices[]` — LOCAL, whatever the
    // comment at that field once said.
    private float ratioOnSegment(int mx, int my, const ref Viewport vp,
                                 Vec3 aLocal, Vec3 bLocal) {
        const ms = primaryModelSpace();
        Vec3 a = ms.toWorldPoint(aLocal);
        Vec3 b = ms.toWorldPoint(bLocal);
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
    package static float dominantAxisDelta(Vec3 delta) {
        final switch (dominantAxisIndex(delta)) {
            case 0: return delta.x;
            case 1: return delta.y;
            case 2: return delta.z;
        }
    }

    /// WHICH axis `dominantAxisDelta` picked (0/1/2). Split out (task 0619)
    /// so `slideDeltaFromDrag` can carry the elected step across spaces
    /// without a second copy of the tie rule that could drift from this one.
    /// `dominantAxisDelta` is defined in terms of it, so there is exactly one
    /// argmax in the file.
    private static int dominantAxisIndex(Vec3 delta) {
        import std.math : abs;
        float ax = abs(delta.x), ay = abs(delta.y), az = abs(delta.z);
        if (ax >= ay && ax >= az) return 0;
        if (ay >= az)             return 1;
        return 2;
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
    // Task 0619 §1.5 (Landing) — the two spaces this crosses, and where.
    //
    // The ELECTION is a WORLD choice and stays one: `planeDragDelta` builds
    // its pixel→world Jacobian at an anchor, against the most-facing WORLD
    // plane, from the world viewport, and the user is dragging on screen. So
    // the anchor is lifted: `slideAnchor_` is the grabbed edge's midpoint
    // read from `m.vertices[]`, i.e. LOCAL, and feeding a local point to a
    // world Jacobian measured the drag gain at the wrong depth and the wrong
    // place on screen.
    //
    // The MAGNITUDE is consumed as a LOCAL length: `slideEndpointPos` moves a
    // local vertex by exactly `|deltaK|` along a rail built from two more
    // local vertices. So the elected world step is carried into local and its
    // length taken there. The sign is carried through unchanged — this law's
    // axis choice and sign are frozen reference behaviour (see the block
    // comment on `dominantAxisDelta` above: two opposite pixel drags along
    // one rail produced the same motion direction), so there is no principled
    // re-derivation of the sign from the local frame either.
    //
    // RESIDUAL, stated rather than hidden: the carried length is exact only
    // where the local rail is parallel to the elected axis; in general `M`
    // scales the two differently. The law is a single scalar shared by two
    // endpoints with different rails, so no per-rail conversion exists that
    // preserves it. This is the smallest change that puts the scalar in the
    // space its consumer measures in.
    private float slideDeltaFromDrag(int mx, int my, const ref Viewport vp) {
        const ms = primaryModelSpace();
        bool skip;
        Vec3 d = planeDragDelta(mx, my, slideStartX_, slideStartY_,
                                3,                    // most-facing world plane
                                ms.toWorldPoint(slideAnchor_), vp, skip);
        if (skip) return 0.0f;
        immutable float kWorld = dominantAxisDelta(d);
        if (ms.isIdentity) return kWorld;   // byte-identical pre-0619 path

        immutable int axis = dominantAxisIndex(d);
        Vec3 stepWorld = Vec3(axis == 0 ? kWorld : 0.0f,
                              axis == 1 ? kWorld : 0.0f,
                              axis == 2 ? kWorld : 0.0f);
        immutable float lenLocal = ms.toLocalDir(stepWorld).length;
        return kWorld >= 0.0f ? lenLocal : -lenLocal;
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
    package static int[] continuationRailCandidates(Mesh* m, uint x, uint other) {
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
    package static int continuationNeighbor(Mesh* m, uint x, uint other) {
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
    package bool onCtrlLmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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

        Viewport vp = viewportOf(vts);
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

        Viewport vp = viewportOf(vts);
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

        Viewport vp = viewportOf(vts);
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
    package static uint[] uniqueRingVerts(Mesh* m, uint seedEdge) {
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
    package bool onMoveLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        moveLoopArmed_ = false;
        moveLoopSeed_  = -1;
        moveLoopVerts_ = null;

        Viewport vp = viewportOf(vts);
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
    package bool onDupLoopShiftRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        dupLoopArmed_ = false;
        dupLoopSeed_  = -1;
        dupLoopEdges_ = null;

        Viewport vp = viewportOf(vts);
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
    package bool onSmoothLoopRmbDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        smoothLoopArmed_ = false;
        smoothLoopSeed_  = -1;
        smoothLoopVerts_ = null;

        Viewport vp = viewportOf(vts);
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

    // The point a shared SCREEN drag puts `orig` at, in `orig`'s OWN space:
    // unproject the shifted pixel onto the plane through `orig` parallel to
    // the image plane — i.e. drag at CONSTANT view depth. Same pixel-CENTRE
    // convention (`+0.5f`) the ray path used, so the screen→3D mapping this
    // tool has always applied is unchanged in shape; task 0619 changed only
    // which space it resolves in (see the aiming-kind note below).
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
    // AIMING KIND: **RayPlane** (task 0619 §1.2), and the RENAME is part of
    // the fix — the old name was `shiftedWorldPoint`, which lied twice over:
    // its `orig` argument is a LAYER-LOCAL mesh point at both call sites, and
    // what it returned was neither space (a WORLD ray met a plane through a
    // LOCAL anchor).
    //
    // The law has three steps that must not be reordered, so it goes through
    // `screenPointToLocalRay` (math.d) rather than being open-coded:
    //   1. build the ray from the UN-composed, world `vp` — an `AimViewport`
    //      must not be used, because `screenRay` treats the view 3x3's
    //      transpose as its inverse and `M` generally carries a scale;
    //   2. carry origin and direction into local, the direction NOT
    //      renormalized so `t` keeps meaning a world distance;
    //   3. carry the plane's WORLD normal across with `toLocalNormal`
    //      (`M^T`), NOT `toLocalDir` (`M^-1`). The two are EQUAL for a pure
    //      rotation and diverge under any non-uniform scale, so a
    //      rotation-only fixture cannot tell them apart — and getting it
    //      wrong tilts the constant-depth plane, which moves the answer
    //      along the ray rather than merely scaling it.
    // Then `dot(n_l, (o_l + t·d_l) − p_l) ≡ dot(n_w, (o_w + t·d_w) − p_w)`
    // exactly, for any invertible `M`.
    //
    // LOCAL is the destination because both consumers want local: the Fill
    // search ranks `(m.vertices[v] − cursorPt).length`, and
    // `resnapToBackground` writes its answer into `m.vertices[]` after one
    // explicit world round trip for the background query.
    private static Vec3 shiftedLocalPoint(Vec3 origLocal, int px, int py,
                                          const ref Viewport vp) {
        const ms = primaryModelSpace();
        Vec3 org, dir;
        screenPointToLocalRay(cast(float)px + 0.5f, cast(float)py + 0.5f,
                              vp, ms, org, dir);
        // View matrix third ROW (column-major m[row + col*4]) = the
        // camera-back direction; the plane through `origLocal` with that
        // normal is the constant-view-depth plane. Same derivation `drag.d`'s
        // `planeDragDelta` uses for its own camera-facing plane. It is a
        // WORLD normal oriented by the camera, so it crosses with `M^T`.
        const ref float[16] v = vp.view;
        Vec3 camBackLocal = ms.toLocalNormal(Vec3(v[2], v[6], v[10]));
        Vec3 q;
        if (!rayPlaneIntersect(org, dir, origLocal, camBackLocal, q))
            return origLocal;   // degenerate view
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
    package bool resnapToBackground(Vec3 orig, int px, int py,
                                    const ref Viewport vp, out Vec3 outPoint) {
        auto sources = backgroundSourcesFull();
        if (sources.length == 0) return false;

        // Task 0619 §1.5 (Landing) — the space chain, converted at exactly
        // one point in each direction:
        //   * `orig` and the shifted query are the PRIMARY layer's LOCAL
        //     coordinates (`shiftedLocalPoint`);
        //   * `closestPointOnMeshes` folds every BACKGROUND source through
        //     its OWN ModelSpace and answers in WORLD (constraint.d:160),
        //     so the query is lifted to world for it;
        //   * the foot comes back to the PRIMARY's local space, because
        //     every consumer of `outPoint` writes it into `m.vertices[]`
        //     (`applyMoveTargets`, `commitMoveLoop`, `commitDupEdges`).
        // Leaving the result in world is the producer-moved / consumer-left
        // defect one call deeper, and it is what this function used to do.
        const ms = primaryModelSpace();
        Vec3 query = ms.toWorldPoint(shiftedLocalPoint(orig, px, py, vp));

        Vec3  hitPt, hitN;
        int   si, fi;
        float d2;
        enum bool dblSided = false;   // matches P8/P12/CONS Point-mode's own default
        if (!closestPointOnMeshes(query, sources, dblSided, hitPt, hitN, si, fi, d2))
            return false;
        outPoint = ms.toLocalPoint(hitPt);
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
    package Vec3[] perVertexTargets(const(uint)[] verts, int dx, int dy,
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
    package Vec3[] perVertexTargetsFrom(const(Vec3)[] base, int dx, int dy,
                                        const ref Viewport vp) {
        // Pixel (§1.1), hoisted out of the per-vertex loop (§3). `base` is
        // LOCAL in both callers — `perVertexTargets` fills it from
        // `m.vertices[]`, and Move's own caller hands in `moveBase_`, the
        // ARM-TIME copy of those same local positions. The pixel this
        // produces is the one the drag delta is measured from, so it has to
        // be the pixel the vertex is DRAWN at.
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        Vec3[] targets;
        targets.length = base.length;
        foreach (i, orig; base) {
            targets[i] = orig;   // default: a miss keeps the original

            ImVec2 pt;
            if (!projectLocalPt(orig, vpAim, pt)) continue;   // behind camera -> keep original

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
        // Task 0523: the guide's registration ends where the ranges snapshot
        // does, and for the same reason — one gesture, one configuration. It
        // is dropped AFTER the dispatch, so `splitUp` still resolves its
        // target vertex against the rule the whole gesture ran on.
        unregisterSnapGuide();
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
    package bool lmbPlaceOrMoveUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (placeArmed_) {
            placeArmed_ = false;
            readHit(vts);   // refresh lastHit_ to THIS release event's CONS-snapped hit
            // Task 0619 §1.5 (Landing), and the most user-visible item in
            // the stage: `lastHit_.point` is the CONS stage's WORLD hit —
            // on a BACKGROUND layer, through that layer's own transform —
            // while `addVertex` stores a coordinate in the PRIMARY layer's
            // LOCAL array. On a transformed primary the click landed the new
            // vertex at `hit` rather than at `M^-1·hit`, i.e. visibly away
            // from the cursor.
            if (lastHit_.hit)
                placeVertexAt(primaryModelSpace().toLocalPoint(lastHit_.point), vts);
            return true;
        }
        if (moveArmed_) {
            // Task 0484: the release applies the FINAL targets for its own
            // pixel and records the whole drag as one undo entry — see
            // `finishMove`. For a grabbed VERTEX this is P4's original law
            // verbatim (go to the release event's CONS-snapped hit), so
            // where a vertex move lands is unchanged; edges and faces take
            // the shared screen-delta law.
            Viewport vp = viewportOf(vts);
            finishMove(e.x, e.y, vp, vts);
            return true;
        }
        return false;
    }

    // P3: commits the armed drag-build, if any, at the RELEASE event's own
    // CONS-snapped hit. A release with no real motion since press (a
    // stationary click-on-vertex — "revisit = Move/no-op", capture SESSION 1)
    // builds nothing.
    package bool buildUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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
        int dx = e.x - startX, dy = e.y - startY;
        if (releaseIsClick(dx, dy)) return true;

        if (!lastHit_.hit) return true;        // no surface hit at release -> nothing to build
        if (casee == BuildCase.None) return true;   // unsupported source state / one-shot ceiling

        // Landing (§1.5), same conversion as Place above: the CONS hit is
        // world, `m.addVertex` inside `buildFromSource` stores local.
        buildFromSource(a, casee, n, p, q, triFi,
                        primaryModelSpace().toLocalPoint(lastHit_.point));
        return true;
    }

    // P7 (doc/topopen_p7_slide_plan.md Phase 3): commits the armed Slide
    // gesture at the RELEASE event's own cursor-derived scalar. Re-derived
    // press->release here rather than reusing the last motion event's
    // `slideDeltaK_`, so the committed offset is the LAST evaluation's — the
    // law's own commit rule — even if the release pixel differs from the last
    // motion pixel.
    package bool slideUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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
        int dx = e.x - startX, dy = e.y - startY;
        if (releaseIsClick(dx, dy)) return true;

        Viewport vp = viewportOf(vts);
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
    package bool splitUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!splitArmed_) return false;
        int a = splitSourceVert_;
        splitArmed_      = false;
        splitSourceVert_ = -1;
        Viewport vp = viewportOf(vts);
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
    package float addLoopFrac(float cursorRatio) const {
        if (addLoopMiddle_) return 0.5f;
        if (!(cursorRatio > 0.0f)) return 0.0f;   // also rejects NaN
        if (cursorRatio > 1.0f)    return 1.0f;
        return cursorRatio;
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 3): commits the armed Add Loop
    // gesture, at the RELEASE event's own cursor-derived ratio — passed
    // through `addLoopFrac`, so the sticky "at the Middle" option overrides
    // it with a flat 0.5 for every crossed edge.
    package bool addLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!addLoopArmed_) return false;
        int seed = addLoopSeed_;
        addLoopSeed_  = -1;
        addLoopArmed_ = false;
        Viewport vp = viewportOf(vts);
        float r = addLoopFrac(ratioFromCursor(e.x, e.y, vp));
        commitAddLoop(cast(uint)seed, r);
        return true;
    }

    // P10 (doc/topopen_p10_moveloop_plan.md Phase 3): commits the armed Move
    // Loop gesture at the RELEASE event's own pixel. A release back at (near
    // enough) the press pixel is a click without a real drag — an explicit,
    // clean no-op (no vertex write, no undo entry, no `perVertexTargets`/
    // re-snap work at all), mirroring P3/P7's own `kMinDragPx` guard.
    package bool moveLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!moveLoopArmed_) return false;
        auto verts = moveLoopVerts_;
        int  sx = moveLoopStartX_, sy = moveLoopStartY_;
        moveLoopArmed_ = false;
        moveLoopVerts_ = null;
        moveLoopSeed_  = -1;

        int dx = e.x - sx, dy = e.y - sy;
        if (releaseIsClick(dx, dy)) return true;

        Viewport vp = viewportOf(vts);
        commitMoveLoop(verts, perVertexTargets(verts, dx, dy, vp), vp);
        return true;
    }

    // P11 (doc/topopen_p11_duploop_plan.md Phase 3): commits the armed Dup
    // Loop gesture at the RELEASE event's own screen delta. A release back
    // at (near enough) the press pixel is a click without a real drag — an
    // explicit, clean no-op (no extrude, no undo entry), mirroring every
    // other gesture's `kMinDragPx` guard.
    package bool dupLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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

        int dx = e.x - sx, dy = e.y - sy;
        if (releaseIsClick(dx, dy)) return true;

        Viewport vp = viewportOf(vts);
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

        immutable int dx = e.x - sx, dy = e.y - sy;
        if (releaseIsClick(dx, dy)) return true;
        if (edges.length == 0) return true;

        Viewport vp = viewportOf(vts);
        // `buildEditFactory_` — this IS the Shift+LMB Duplicate/build slot,
        // so the entry carries that slot's own wire name, never the loop
        // gesture's (the OBJ-3/D4 discipline every commit path here follows).
        commitDupEdges(edges, dx, dy, vp, factories_.build, "Topology Duplicate Edge");
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
    package bool smoothLoopUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
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
    package bool lmbModeUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        return penGestureUp(gestureOn_[InputButton.Left], e, vts);
    }

    /// Dispatch a RELEASE to the commit leg of the gesture `g` — the gesture
    /// the matching press actually resolved to, per button (task 0487). Every
    /// leg guards on its own arm bool, so a press that resolved-but-declined
    /// lands here as a clean no-op.
    ///
    /// `final switch` since task 0705: this used to end in
    /// `default: return lmbPlaceOrMoveUp(...)`, which is the RIGHT answer for
    /// `PlaceOrMove` and a silently WRONG one for any gesture added later —
    /// a new `PenGesture` would have armed at Down and then committed through
    /// place-or-move's leg at Up, with nothing to say so. Spelling
    /// `PlaceOrMove` out costs one line and makes the next member a compile
    /// error here instead. Behaviour is unchanged: `PlaceOrMove` was the only
    /// member the `default` arm could ever see.
    private bool penGestureUp(PenGesture g, ref const SDL_MouseButtonEvent e,
                              ref VectorStack vts) {
        final switch (g) {
        case PenGesture.Build:       return buildUp(e, vts);
        case PenGesture.Slide:       return slideUp(e, vts);
        case PenGesture.Smooth:      return smoothUp(e, vts);
        case PenGesture.Split:       return splitUp(e, vts);
        case PenGesture.AddLoop:     return addLoopUp(e, vts);
        case PenGesture.MoveLoop:    return moveLoopUp(e, vts);
        case PenGesture.DupLoop:     return dupLoopUp(e, vts);
        case PenGesture.SmoothLoop:  return smoothLoopUp(e, vts);
        case PenGesture.Remove:      return false;   // commits on DOWN (D2)
        case PenGesture.PlaceOrMove: return lmbPlaceOrMoveUp(e, vts);
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

    // The remaining enum→token mappings `toolStateJson` needs, extracted
    // from its body under the same `final switch` discipline as
    // `moveElemTag`/`penGestureTag` above (see the comment at
    // `moveElemTag`): compile-time exhaustive, so a new enum member is a
    // compile error here instead of a silently unlabelled state field.
    private static string hoverTargetKindTag(HoverTargetKind k) {
        final switch (k) {
        case HoverTargetKind.None:   return "none";
        case HoverTargetKind.Vertex: return "vertex";
        case HoverTargetKind.Edge:   return "edge";
        case HoverTargetKind.Face:   return "face";
        }
    }

    private static string buildCaseTag(BuildCase c) {
        final switch (c) {
        case BuildCase.None: return "none";
        case BuildCase.Edge: return "edge";
        case BuildCase.Tri:  return "tri";
        case BuildCase.Quad: return "quad";
        }
    }

    private static string slideDeclineTag(SlideDecline d) {
        final switch (d) {
        case SlideDecline.None:           return "none";
        case SlideDecline.NoEdge:         return "no_edge";
        case SlideDecline.NoContinuation: return "no_continuation";
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
    /// `pointLocal` is a PRIMARY-LAYER LOCAL coordinate (task 0619): the
    /// command writes it straight into `mesh.vertices[]`, so a caller
    /// holding a world hit converts BEFORE calling, not after.
    private int placeVertexAt(Vec3 pointLocal, ref VectorStack vts) {
        // Guard BOTH prerequisites BEFORE creating/applying the command
        // (review NIT): meshSrc_/gpu_/vc_/ec_/fc_ are wired together with
        // addVertexFactory_ (registration.d), so a partially-constructed tool
        // (e.g. no-arg ctor + setUndoBindings only) must bail HERE — above
        // cmd.evaluate() — so it never mutates-then-fails-to-record (which
        // would leave an applied-but-un-undoable edit).
        if (addVertexFactory_ is null || meshSrc_ is null) return -1;

        auto cmd = addVertexFactory_();   // binds &mesh() = primary NOW
        cmd.setPos(pointLocal);
        if (!cmd.evaluate(vts)) return -1;

        if (history_ !is null) history_.record(cmd);   // non-coalescing -> one undo entry

        if (gpu_ !is null) gpu_.upload(*mesh);
        mesh.syncSelection();
        refreshDisplay(mesh, gpu_, vc_, ec_, fc_);

        return cast(int)(mesh.vertices.length - 1);
    }

    // The pre-commit gate every snapshot-undo commit below opens with: mesh
    // source, history, and the gesture's own dedicated factory all wired
    // (registration.d). A partially-constructed tool (no-arg ctor + partial
    // `setUndoBindings` — every direct-construction rig below) must bail
    // BEFORE any mutation, so it never mutates-then-fails-to-record (which
    // would leave an applied-but-un-undoable edit — the same hazard
    // `placeVertexAt`'s own guard documents).
    private bool commitReady(MeshSessionEdit delegate() factory) {
        return meshSrc_ !is null && history_ !is null && factory !is null;
    }

    // The shared undo tail every snapshot-bracketed commit below ends with
    // (the `pen.d:903-926` `commitPolygonWithUndo` precedent): capture the
    // post-mutation snapshot, mint the gesture's command through its OWN
    // dedicated factory (never a sibling's — the wire name and editScope are
    // baked into the factory at app.d's construction site, per every
    // factory alias's doc comment above), pair the two snapshots under the
    // gesture's label, and record ONE non-coalescing entry.
    private void recordSnapshotUndo(Mesh* m, MeshSnapshot before,
                                    MeshSessionEdit delegate() factory, string label) {
        MeshSnapshot after = MeshSnapshot.capture(*m);
        auto cmd = factory();
        cmd.setSnapshots(before, after, label);
        history_.record(cmd);
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
    // gesture's world-space move delta, then carried into the layer's own
    // space by `slideDeltaFromDrag` — the rails it is applied along below
    // are local) — ONE value for BOTH endpoints, which
    // is measured, not an economy: the two endpoints differ only in their rail
    // DIRECTION. See `slideEndpointPos` for the per-endpoint law and for why
    // there is no `[0,1]` clamp any more.
    package void commitSlide(uint seed, int eA, int eB, int nA, int nB, double deltaK) {
        if (!commitReady(factories_.slide)) return;
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
        recordSnapshotUndo(m, before, factories_.slide, "Topology Slide");

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
    package static bool isOpenEdge(Mesh* m, uint ei) {
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
    package static bool isOpenVertex(Mesh* m, uint v,
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
    package static Vec3 inverseEdgeLenRelax(const(Vec3)[] readPos, uint v,
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
    package static RelaxTopology buildRelaxTopology(Mesh* m) {
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
    package static uint[][uint] loopNeighborsOf(Mesh* m, uint seed) {
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
    package void applySmoothPasses(int passCount) {
        if (!commitReady(factories_.smooth)) return;
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

        auto sources = backgroundSourcesFull();   // point-in-time, fetched ONCE per commit
        const ms = primaryModelSpace();           // read fresh, once per commit (§2.4)
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
                // Task 0619 §1.5 (Landing): `relaxed` is a LOCAL position
                // (the relaxation ran entirely on `m.vertices[]`), while
                // `closestPointOnMeshes` takes and returns WORLD — it folds
                // every background source through its own ModelSpace. So the
                // query goes up and the foot comes back down, once each; the
                // write below is a LOCAL vertex coordinate. Without the
                // round trip the re-snap measured the nearest background
                // point to where the layer would sit at identity, and then
                // stored a world coordinate in a local array.
                if (closestPointOnMeshes(ms.toWorldPoint(relaxed), sources,
                                         dblSided, hit, hitN, si, fi, d2))
                    relaxed = ms.toLocalPoint(hit);
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

        recordSnapshotUndo(m, before, factories_.smooth, "Topology Smooth");

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
    package void applySmoothLoopPasses(int passCount) {
        if (!commitReady(factories_.smoothLoop)) return;
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

        auto sources = backgroundSourcesFull();   // point-in-time, fetched ONCE per commit
        const ms = primaryModelSpace();           // read fresh, once per commit (§2.4)
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
                    // Same Landing round trip as `applySmoothPasses` — local
                    // query up to world, world foot back down to local,
                    // because the write on the next line is a local vertex.
                    if (closestPointOnMeshes(ms.toWorldPoint(relaxed), sources,
                                             dblSided, hit, hitN, si, fi, d2))
                        relaxed = ms.toLocalPoint(hit);
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
        recordSnapshotUndo(m, before, factories_.smoothLoop, "Topology Smooth Loop");

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
    /// `bPosLocal` is a PRIMARY-LAYER LOCAL coordinate (task 0619) — it goes
    /// straight into `m.addVertex`. The gesture's caller converts the CONS
    /// world hit; the direct-construction unittests below already pass local
    /// fixture positions, which is what they always meant.
    package void buildFromSource(int a, BuildCase casee, int n, int p, int q,
                                 int triFi, Vec3 bPosLocal) {
        if (!commitReady(factories_.build)) return;
        auto m = mesh;
        if (m is null) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        uint b = m.addVertex(bPosLocal);
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

        recordSnapshotUndo(m, before, factories_.build, "Topology Build");

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
    package void removeFaceAt(int faceIdx) {
        if (!commitReady(factories_.remove)) return;
        auto m = mesh;
        if (m is null || faceIdx < 0 || faceIdx >= cast(int)m.faces.length) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        auto mask = new bool[](m.faces.length);
        mask[faceIdx] = true;
        m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);

        recordSnapshotUndo(m, before, factories_.remove, "Topology Remove");

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
    package void removeEdgeAt(int edgeIdx, bool loop) {
        if (!commitReady(factories_.removeEdge)) return;
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

        recordSnapshotUndo(m, before, factories_.removeEdge, "Topology Remove Edge");

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
        if (!commitReady(factories_.removeVertex)) return;
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

        recordSnapshotUndo(m, before, factories_.removeVertex, "Topology Remove Vertex");

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
    package void commitAddLoop(uint seedEdge, float r) {
        if (!commitReady(factories_.addLoop)) return;
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

        recordSnapshotUndo(m, before, factories_.addLoop, "Topology Add Loop");

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
    package void commitSplit(int a, int c) {
        if (!commitReady(factories_.split)) return;
        auto m = mesh;
        if (m is null) return;

        int fi = findCommonSplitFace(m, a, c);
        if (fi < 0) return;   // every no-op condition (C==-1, C==A, no shared
                               // face, adjacent A/C) funnels here — no mutation

        MeshSnapshot before = MeshSnapshot.capture(*m);

        size_t n = m.splitFaceByVertices(cast(uint)fi, cast(uint)a, cast(uint)c);
        if (n == 0) return;   // defensive; `before` discarded, mesh unmutated

        recordSnapshotUndo(m, before, factories_.split, "Topology Split");

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
    // THE RING GATE IS NOT HERE, AND THAT IS DELIBERATE (task 0532). The
    // reference's last gate on a formed ring — read in task 0528 — lives in
    // the shared candidate search (`ringRefusedByIncidentPolygon`), because
    // that is where the reference calls it and it is therefore a HOVER
    // quantity too. By the time a ring reaches `commitFill` it has already
    // passed that gate, so this function keeps exactly the guards it always
    // had. Anything that calls `commitFill` with a hand-built ring (the
    // unit tests below do) bypasses the gate on purpose: that is what makes
    // the two testable apart.
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
    package void commitFill(const(uint)[] ringVerts) {
        if (!commitReady(factories_.fill)) return;
        auto m = mesh;
        if (m is null) return;
        if (ringVerts.length != 4 && ringVerts.length != 3) return;

        MeshSnapshot before = MeshSnapshot.capture(*m);

        int fi = m.makePolygonFromVerts(ringVerts, false, true);
        if (fi < 0) return;   // dup-face / non-manifold / degenerate -> clean no-op, no mutation

        consumeDegeneratePolysOnRing(m, ringVerts);

        recordSnapshotUndo(m, before, factories_.fill, "Topology Fill");

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
    //
    // `vp` is the release event's viewport, and it is a REQUIRED parameter
    // rather than a defaulted one (task 0555): the destructive landing has to
    // project each moved vertex to ask where it came to rest, and a caller
    // that could omit the viewport would silently get a Move Loop that never
    // welds — the one failure mode worth a compile error.
    package void commitMoveLoop(const(uint)[] verts, const(Vec3)[] targets,
                                const ref Viewport vp) {
        if (!commitReady(factories_.moveLoop)) return;
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
        // The destructive landing (task 0555) — the LOOP grab's copy of it,
        // and the cell whose measurement (four vertices absorbed in one
        // gesture) is what proves the absorption is per moved vertex rather
        // than per cursor. Inside the snapshot pair, so the whole gesture is
        // still ONE undo entry; a no-op unless the shared snap enable is on.
        immutable bool welded = weldMovedVertices(verts, vp) > 0;
        recordSnapshotUndo(m, before, factories_.moveLoop, "Topology Move Loop");

        // Position-only: no resyncSession() — see this method's own doc
        // comment / plan §Undo. UNLESS the landing welded, which rebuilds and
        // compacts the mesh and therefore CAN dangle a sibling's cached index.
        if (welded) resyncSession();

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
    package void commitDupLoop(const(int)[] loopEdges, int dx, int dy,
                               const ref Viewport vp) {
        if (factories_.dupLoop is null) return;
        commitDupEdges(loopEdges, dx, dy, vp, factories_.dupLoop,
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
        if (!commitReady(factory)) return;
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
        recordSnapshotUndo(m, before, factory, label);

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

    mixin PenRenderOps;

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----
    // A Vec3 as a `[x, y, z]` JSON array — the shape every position/normal
    // field below reports in.
    private static JSONValue vec3Json(Vec3 v) {
        return JSONValue([cast(double)v.x, cast(double)v.y, cast(double)v.z]);
    }

    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("mesh.topoPen");
        root["hit"]         = JSONValue(lastHit_.hit);
        root["point"]       = vec3Json(lastHit_.point);
        root["normal"]      = vec3Json(lastHit_.normal);
        root["layer"]       = JSONValue(lastHit_.layer);
        root["face"]        = JSONValue(lastHit_.face);
        root["nearestVert"] = JSONValue(lastHit_.nearestVert);
        root["nearestEdge"] = JSONValue(lastHit_.nearestEdge);

        // P1 (doc/topopen_p1_plan.md): the resolved hover snap-target,
        // nested so the P0 root fields above stay intact for the existing
        // Tier-C test.
        auto hv = JSONValue.emptyObject;
        hv["hit"]    = JSONValue(lastHit_.hit);
        hv["point"]  = vec3Json(lastHit_.point);
        hv["normal"] = vec3Json(lastHit_.normal);
        hv["targetKind"] = JSONValue(hoverTargetKindTag(lastTarget_.kind));
        hv["targetVert"] = JSONValue(lastTarget_.vert);
        hv["targetEdge"] = JSONValue(lastTarget_.edge);
        root["hover"] = hv;

        // P3 (doc/topopen_p3_plan.md): the armed drag-build state, for
        // Tier-C tests to assert the classified case (incl. a press on a
        // BARE-EDGE vertex -> "tri", the KILLER-1 regression guard) without
        // driving a full build.
        root["sourceVert"] = JSONValue(sourceVert_);
        root["dragArmed"]  = JSONValue(dragArmed_);
        root["case"] = JSONValue(buildCaseTag(classifiedCase_));

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
        root["slideDeclineReason"] = JSONValue(slideDeclineTag(slideDecline_));
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
        // The ORIENTATION half of that same admission policy (task 0538):
        // whether a candidate whose own normal faces away from the viewer may
        // still be the pen's snap target. Published for the same reason
        // `innerSnap` is — the flag changes which element a drag lands on, so
        // an automated run has to be able to read back which branch it set.
        root["backFace"] = JSONValue(backFace_);
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
