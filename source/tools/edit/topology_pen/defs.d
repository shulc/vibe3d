// The Topology Pen's vocabulary: the per-gesture command-factory aliases and
// the struct that holds them, the gesture/mode/case enums, the chord table and
// its overrides, the input-binding grid, and the `GestureArm` type every arm
// flag is declared with.
//
// Declarations only -- no behaviour, and nothing here knows the tool class
// exists. That is what makes it separable: `tool.d` reads this vocabulary,
// never the other way round, so the file can be read on its own to learn what
// the pen's gestures ARE before reading how they run.
//
// Split out of the tool module by task 0718, verbatim. Visibility is
// unchanged except for three types the tool needs across the new module
// boundary (`TopoPenFactories`, `ChordOv`, `modeOfOverride`), which went from
// `private` to `package` -- the pen's package, not one module wider.
module tools.edit.topology_pen.defs;

import commands.mesh.vertex_new   : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import tool_input                 : ToolAction, PassThrough, InputButton, InputMod,
                                    InputBinding, ResetScope;

/// Factory the tool calls PER CLICK to obtain a fresh, primary-bound
/// `MeshVertexNew` (P2, doc/topopen_p2_plan.md REV-1) — mirrors
/// `tools.create.vertex_place`'s `VertexEditFactory` alias shape. Binding
/// happens at CALL time (`() => new MeshVertexNew(&mesh(), ...)` at the
/// registration.d wiring site), so each click's command targets whichever
/// layer is primary AT THAT MOMENT.
alias VertexNewFactory = MeshVertexNew delegate();

/// Factory the tool calls ONCE PER BUILD GESTURE to obtain a fresh,
/// primary-bound `MeshSessionEdit` (P3, doc/topopen_p3_plan.md) — the
/// generic before/after-snapshot undo command — the same idiom as every
/// other interactive tool's `bevelEditFactory`. (The pen's own
/// `PenEditFactory` alias it used to be named after is gone as of task 1905
/// phase B; the create family binds through `Tool.setGestureBindings`, whose
/// parameter is a plain `Command delegate()`. The pen's thirteen factories
/// migrate with group G7.) Binding happens at CALL time, so the build's undo
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
package struct TopoPenFactories {
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

package struct ChordOv {
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
/// filled in (every direct-call unittest in the package's test module,
/// `tests/unit/tools/edit/topology_pen/gestures_test.d`) still books its
/// gesture against the right button.
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
package PenMode modeOfOverride(ModeOv m) {
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
// "Slide law — REFERENCE PARITY CONFORMANCE" unittest in the package's test
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
