module unit.prepared_tool_transition_test;

import prepared_tool_effect;
import prepared_tool_transition;
import change_bus : ChangeBus, PreparedDeliveryJournal, PreparedDeliverySpec,
                    PreparedMeshSubjectOwner;
import command_history : CommandHistory, HistoryEntry, HistoryFlags,
                        PreparedHistoryImage;
import document : PreparedLayerReadScope;
import record_observer_hub : PreparedRecordObserverImage;
import edit_session : LifecycleUndoEmitter;
import tool : Tool;
import registry : ToolFactory;
import tools.edit.topology_pen.tool : TopologyPenTool;
import std.algorithm : canFind, endsWith, startsWith;

// ---------------------------------------------------------------------------
// The prepared-effect FIELD SHAPE census (task 4052)
// ---------------------------------------------------------------------------
// Each named shape below replaces one `tests/compile_fail/prepared_effect_*.d`
// fixture: a file whose whole content was `static assert(requirePreparedField!T)`
// and whose contract was that dmd must REJECT it. `!__traits(compiles, ...)`
// states the same refusal inside a module that compiles. The seven were never
// the expensive half -- 0.148 s of dmd across all of them, measured 2026-09-04
// against 21.5 s for the 65 copy fixtures -- they are retired because a
// fixture directory still needs a caller, and seven files is a caller's worth
// of scaffolding for seven `static assert`s.
//
// THE ORDER IS THE POINT. The positive control sits FIRST: an `isPreparedField`
// that answered `false` for everything would satisfy all seven negatives and
// say nothing at all. druntime stops a module at its first failed assert, so a
// run that reaches the negatives has already cleared the control -- one run
// buys both halves.
//
// What did NOT move: the fixtures also pinned the diagnostic TEXT
// ("prepared effect field is not owned"). `__traits(compiles)` cannot see a
// message, so that string is pinned by `token_census_gate` in
// tools/check_prepared_protocol.py against source/prepared_tool_effect.d.
private class PreparedEffectBorrowedClass { int value; }          // _class.d
private alias PreparedEffectDelegate = void delegate();           // _delegate.d
private alias PreparedEffectFunctionPointer = void function();    // _function_pointer.d
private struct PreparedEffectNestedPointer { int* borrowed; }     // _nested_pointer.d
private struct PreparedEffectNestedSlice { ubyte[] borrowed; }    // _nested_slice.d
private struct PreparedEffectBorrowingView { int[] source; size_t index; } // _view.d

// THREE OF THE SEVEN FIXTURES COULD NOT DISCRIMINATE, and copying them
// faithfully would have carried that across. `_nested_pointer`, `_nested_slice`
// and `_view` were plain structs with no `@PreparedAggregate`, so
// `isPreparedField` refused them at its LAST branch -- "not an admitted
// aggregate" -- and never reached the recursive field check they were written
// to state. Their refusal is real but it is the wrong refusal: delete
// `isDynamicArray!T` or `isPointer!T` from the rule and all three stay green.
// These three carry the UDA, so the only thing that can refuse them is the
// recursion over their fields, and the mutation drill in the card shows each
// going red on its own term.
@PreparedAggregate private struct PreparedEffectOwnedAggregate { OwnedId owner; ulong value; }
@PreparedAggregate private struct PreparedEffectAggregatePointer { OwnedId owner; int* borrowed; }
@PreparedAggregate private struct PreparedEffectAggregateSlice { OwnedId owner; ubyte[] borrowed; }
@PreparedAggregate private struct PreparedEffectAggregateView { OwnedId owner; int[] source; size_t index; }

unittest {
    // The control. Must stay GREEN; everything below it is a refusal.
    static assert(isPreparedField!PreparedToolEffect);
    static assert(__traits(compiles, requirePreparedField!PreparedToolEffect));

    // prepared_effect_direct_slice.d
    static assert(!isPreparedField!(ubyte[]));
    static assert(!__traits(compiles, requirePreparedField!(ubyte[])));
    // prepared_effect_class.d
    static assert(!isPreparedField!PreparedEffectBorrowedClass);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectBorrowedClass));
    // prepared_effect_delegate.d
    static assert(!isPreparedField!PreparedEffectDelegate);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectDelegate));
    // prepared_effect_function_pointer.d
    static assert(!isPreparedField!PreparedEffectFunctionPointer);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectFunctionPointer));
    // prepared_effect_nested_pointer.d
    static assert(!isPreparedField!PreparedEffectNestedPointer);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectNestedPointer));
    // prepared_effect_nested_slice.d
    static assert(!isPreparedField!PreparedEffectNestedSlice);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectNestedSlice));
    // prepared_effect_view.d
    static assert(!isPreparedField!PreparedEffectBorrowingView);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectBorrowingView));

    // The bare shapes the old block already carried, kept.
    static assert(!isPreparedField!(int*));
    static assert(!isPreparedField!(void delegate()));
    static assert(!isPreparedField!Object);

    // The RECURSION, which the three nested fixtures above could not reach.
    // Control first again: an admitted aggregate of owned fields is ACCEPTED,
    // so "the aggregate branch always says false" cannot pass the three below.
    static assert(isPreparedField!PreparedEffectOwnedAggregate);
    static assert(__traits(compiles, requirePreparedField!PreparedEffectOwnedAggregate));
    static assert(!isPreparedField!PreparedEffectAggregatePointer);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectAggregatePointer));
    static assert(!isPreparedField!PreparedEffectAggregateSlice);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectAggregateSlice));
    static assert(!isPreparedField!PreparedEffectAggregateView);
    static assert(!__traits(compiles, requirePreparedField!PreparedEffectAggregateView));
}

private class CountingPreparedTool : Tool {
    static int destroyed;
    ~this() { ++destroyed; }
}

private class LifecyclePreparedTool : Tool, LifecycleUndoEmitter { }

unittest {
    static assert(is(TopologyPenTool : LifecycleUndoEmitter),
        "Topology Pen arm must opt into lifecycle history");
    assert(toolArmEmitsLifecycle(new LifecyclePreparedTool, "mesh.marker"),
        "a lifecycle marker must classify the prepared arm for recording");
    assert(toolArmEmitsLifecycle(new CountingPreparedTool, "mesh.sliceTool"),
        "the Slice compatibility arm lost its lifecycle classification");
    assert(!toolArmEmitsLifecycle(new CountingPreparedTool, "mesh.plain"),
        "an unmarked ordinary tool acquired a lifecycle record");
}

unittest {
    CountingPreparedTool.destroyed = 0;
    PreparedCandidateOwner owner;
    auto first = new CountingPreparedTool;
    auto second = new CountingPreparedTool;
    owner.prepare(first, null);
    owner.prepare(second, null);
    assert(CountingPreparedTool.destroyed == 1,
           "repeated candidate prepare leaked its replaced candidate");
    ToolFactory failing = () { throw new Exception("prepare failed"); };
    try owner.prepareFrom(failing, null);
    catch (Exception) {}
    assert(owner.preparedCandidate() is second,
           "failed replacement discarded the previously prepared candidate");
    owner.discardCandidate();
    assert(CountingPreparedTool.destroyed == 2,
           "candidate discard did not run the terminal disposer exactly once");
}

unittest {
    auto history = new CommandHistory;
    HistoryEntry lifecycle = { label: "prepared", flags:
        HistoryFlags.Undoable | HistoryFlags.ToolLifecycle };
    auto image = history.prepareLifecycleAppend(lifecycle);
    history.installPreparedImage(image);
    assert(history.toolLifecycleCount() == 1,
           "prepared history install did not append its lifecycle row");
    assert(!history.canRedo(),
           "prepared lifecycle append did not invalidate redo");
}

unittest {
    auto anchor1 = new Object(), anchor2 = new Object();
    auto owner1 = new PreparedMeshSubjectOwner(anchor1, 11, 101);
    auto owner2 = new PreparedMeshSubjectOwner(anchor2, 22, 202);
    auto rows = [PreparedDeliverySpec(owner1, owner1.issue(), 3, 1),
                 PreparedDeliverySpec(owner2, owner2.issue(), 8, 4)];
    auto journal = PreparedDeliveryJournal.prepare(rows);
    rows[0].flags = 99; // post-prepare alias mutation cannot affect owner copy
    ChangeBus bus;
    size_t[] subjects; uint[] flags; uint[] domains;
    bus.onMeshChanged((size_t s, uint f) nothrow { subjects ~= s; flags ~= f; });
    bus.onSelectionChanged((uint d) nothrow { domains ~= d; });
    journal.replay(bus);
    assert(subjects.length == 2,
           "prepared journal lost/coalesced a delivery");
    assert(subjects == [11, 22] && flags == [3, 8] && domains == [1, 4],
           "prepared journal changed subject/flags/domain order");

    bool refused;
    try PreparedDeliveryJournal.prepare([
        PreparedDeliverySpec(owner1, owner2.issue(), 1, 0)]);
    catch (Exception) refused = true;
    assert(refused, "a token issued by another owner was accepted");
    auto generationOwner = new PreparedMeshSubjectOwner(new Object(), 33, 303);
    auto stale = PreparedDeliveryJournal.prepare([
        PreparedDeliverySpec(generationOwner, generationOwner.issue(), 1, 0)]);
    assert(stale.validate());
    generationOwner.issue();
    assert(!stale.validate(), "a superseded subject generation stayed valid");
}

// ===========================================================================
// The prepared-token copy census (task 4052)
// ===========================================================================
// WHAT THIS REPLACES, AND WHAT IT COST. Until 2026-09-04 the non-copyability
// of a prepared token was stated by one file per token under
// `tests/compile_fail/` -- 66 of them, each three to six lines of
// `T original; auto forbiddenCopy = original;` -- and checked by
// `tools/check_prepared_protocol.py` launching one `dmd -c` per fixture and
// requiring the rejection to mention a disabled copy. Measured on this host
// with `dmd` behind a timing wrapper (2026-09-04): 65 of those compiles cost
// 21.5 s of the scanner's 39.9 s wall. The property is one `__traits` call, so
// the 66 fixtures are gone and the census below is paid by
// `dub test --config=tests`, which compiles this module anyway.
//
// WHY IT IS NOT VACUOUS -- the failure mode this whole file exists to avoid.
// The census set is chosen by NAME (a struct called `Prepared*Token` or
// `Validated*Token`, declared by one of the modules listed below), NEVER by
// copyability. Deleting `@disable this(this)` from a token therefore leaves it
// in the set and reddens its own `static assert` with its own name. A set
// derived from "has a disabled copy" would be a tautology and could not go red
// at all. `kCopyableByDesign` is asserted in the POSITIVE direction for the
// same reason: a stale exception cannot hide, because giving one of those three
// a disabled copy reddens the row that excuses it.
//
// THE HOLE D CANNOT SEE, and who closes it. D compile-time reflection cannot
// enumerate the modules on disk, so `kTokenModules` could silently fall behind
// a new `source/prepared_*.d` and the census would then be honestly green over
// a smaller set -- the "pattern matches nothing" shape. That half is
// filesystem enumeration, which is exactly what the Python census can see and
// D cannot: `token_census_gate` in `tools/check_prepared_protocol.py` compares
// this list, the two counts below and the exception list against the tree, and
// refuses a drift in either direction. Neither half is sufficient alone.
private enum string[] kTokenModules = [
    "command_history",
    "document",
    "handles.shapes",
    "mesh_gpu",
    "prepared_array_param_update",
    "prepared_bridge_activation",
    "prepared_command_wrapper_activation",
    "prepared_edge_bevel_activation",
    "prepared_edge_bevel_param_update",
    "prepared_edge_extend_deactivate",
    "prepared_edge_extend_param_update",
    "prepared_edge_extend_tool_activation",
    "prepared_edge_extrude_activation",
    "prepared_edge_extrude_param_update",
    "prepared_edge_slice_activation",
    "prepared_edge_slice_deactivate",
    "prepared_edge_slice_param_update",
    "prepared_inherited_noop",
    "prepared_loop_slice_activation",
    "prepared_loop_slice_deactivate",
    "prepared_loop_slice_param_update",
    "prepared_magnet_param_update",
    "prepared_mirror_activation",
    "prepared_move_update",
    "prepared_poly_bevel_activation",
    "prepared_poly_bevel_param_update",
    "prepared_poly_extrude_activation",
    "prepared_poly_extrude_param_update",
    "prepared_poly_inset_activation",
    "prepared_poly_inset_param_update",
    "prepared_private_state",
    "prepared_radial_array_transition",
    "prepared_reduction_param_update",
    "prepared_rotate_update",
    "prepared_scale_update",
    "prepared_slice_activation",
    "prepared_slice_deactivate",
    "prepared_slice_param_update",
    "prepared_smooth_shift_activation",
    "prepared_smooth_shift_param_update",
    "prepared_stroke_extrude_activation",
    "prepared_tack_activation",
    "prepared_tool_effect",
    "prepared_topology_pen_activation",
    "prepared_topology_pen_deactivate",
    "prepared_topology_pen_update",
    "prepared_transform_activation",
    "prepared_transform_product_activation",
    "prepared_vertex_bevel_activation",
    "prepared_vertex_bevel_param_update",
    "prepared_vertex_extrude_activation",
    "prepared_vertex_extrude_param_update",
    "prepared_vertex_merge_activation",
    "prepared_vertex_merge_param_update",
    "prepared_xfrm_activation_session",
    "prepared_xfrm_move_regrade",
    "prepared_xfrm_slot_poll",
    "prepared_xfrm_update_boundary",
    "prepared_xfrm_update_edit_close",
    "prepared_xfrm_update_tail",
    "snap_render",
];

// The one package-qualified entry needs a static import spelled out here: dmd
// deprecates naming `handles.shapes` through the string mixin below ("module
// handles.shapes is not accessible here"), because the package symbol is not
// in scope at the point the mixin's `__traits(allMembers, ...)` resolves it.
static import handles.shapes;
static foreach (m; kTokenModules) mixin("static import " ~ m ~ ";");

/// Membership in the census, by NAME alone -- see the note above.
private bool isPreparedTokenName(string n) {
    return n.endsWith("Token")
        && (n.startsWith("Prepared") || n.startsWith("Validated"));
}

private enum string[] kCensusTokens = () {
    string[] rows;
    static foreach (mod; kTokenModules)
        static foreach (name; __traits(allMembers, mixin(mod)))
            static if (isPreparedTokenName(name)) rows ~= mod ~ "." ~ name;
    return rows;
}();

// POPULATION FLOOR. "Every token in the census is non-copyable" is true over an
// empty census, and over a census of one. Both counts are pinned, so a module
// dropped from the list above, or a token renamed out of the pattern, moves a
// number rather than quietly shrinking the set the asserts run over.
static assert(kTokenModules.length == 61,
    "prepared-token module list changed -- update the count and the Python "
    ~ "token_census_gate together");
static assert(kCensusTokens.length == 134,
    "prepared-token population changed -- a token was added, removed or "
    ~ "renamed out of the Prepared*Token / Validated*Token pattern");

/// Three tokens ship WITHOUT a disabled copy, and no retired fixture ever
/// covered one of them (the 66 fixtures named 76 types out of 134). They are
/// pinned as copyable so the exception cannot rot -- but they are THREE
/// DIFFERENT cases, not one in triplicate. Only `PreparedGpuResourceToken` has
/// a `Validated*` counterpart to be asymmetric with; the other two have none,
/// and for them the copy CANNOT be disabled -- each is consumed by value from
/// an lvalue, so `@disable this(this)` stops the build (measured 2026-09-04:
/// handles/shapes.d(2048) and change_bus.d(121/123)). Their defence against a
/// second consumer is the owner's generation counter, not the postblit. Card
/// 4090 therefore has ONE decision left, on the GPU pair.
private enum string[] kCopyableByDesign = [
    "handles.shapes.PreparedClickPointResourceToken",
    "mesh_gpu.PreparedGpuResourceToken",
    "prepared_tool_effect.PreparedSubjectToken",
];

static foreach (mod; kTokenModules)
    static foreach (name; __traits(allMembers, mixin(mod)))
        static if (isPreparedTokenName(name)) {
            static if (kCopyableByDesign.canFind(mod ~ "." ~ name))
                static assert(__traits(isCopyable,
                        __traits(getMember, mixin(mod), name)),
                    "kCopyableByDesign lists " ~ mod ~ "." ~ name ~ ", which "
                    ~ "now disables its copy -- delete that row");
            else
                static assert(!__traits(isCopyable,
                        __traits(getMember, mixin(mod), name)),
                    "prepared token " ~ mod ~ "." ~ name ~ " became copyable: "
                    ~ "restore `@disable this(this)`. A prepared token is a "
                    ~ "one-shot capability; a copy is a second consumer.");
        }

// SEVEN prepared aggregates are non-copyable without being spelled `*Token`,
// so the pattern above reaches none of them. Until 2026-09-04 this comment and
// the Python gate both said TWO -- `PreparedArm` and `PreparedCandidateOwner`,
// the only pair that had ever owned a compile-fail fixture. Nothing regressed
// when the fixtures went, because the other five were never covered by
// anything; but the miscount was the stated rationale for keying the census on
// the name suffix, so it is corrected here and the roster is walked out of the
// tree by `token_census_gate` in tools/check_prepared_protocol.py.
//
// Five can be named from this module and are asserted below.
// `prepared_arm_copy.d` was the fixture for the first two.
static assert(!__traits(isCopyable, PreparedArm),
    "PreparedArm became copyable: restore `@disable this(this)`");
static assert(!__traits(isCopyable, PreparedCandidateOwner),
    "PreparedCandidateOwner became copyable: restore `@disable this(this)`");
static assert(!__traits(isCopyable, PreparedHistoryImage),
    "PreparedHistoryImage became copyable: restore `@disable this(this)`");
static assert(!__traits(isCopyable, PreparedLayerReadScope),
    "PreparedLayerReadScope became copyable: restore `@disable this(this)`");
static assert(!__traits(isCopyable, PreparedRecordObserverImage),
    "PreparedRecordObserverImage became copyable: restore `@disable this(this)`");
// The remaining two are `private struct`s -- `command_history.PreparedHistoryBatch`
// and `tools.create.vertex_place.ValidatedVertexActivate` -- which this module
// cannot import at any protection level, so no `static assert` can reach them.
// For those two the scanner's source walk IS the check: it reads the
// `@disable this(this)` out of the declaration and reports a disagreement with
// its roster. That is the same division of labour as the module list above --
// the compiler states what it can see, the scanner states what is on disk.

// EVERY RETIRED FIXTURE HAS A NAMED REPLACEMENT. This is the list of token
// types the 66 deleted files named, and each must be a member of the census
// above -- so the replacement is provably a superset of what was removed, not
// merely something in the same area. `PreparedArm`, the 76th, is asserted by
// name just above.
private enum string[] kRetiredCopyFixtureTokens = [
    "PreparedBridgeActivationToken",
    "PreparedBridgeDeactivateToken",
    "PreparedCommandWrapperActivationToken",
    "PreparedEdgeBevelActivationToken",
    "PreparedEdgeExtendDeactivateToken",
    "PreparedEdgeExtendParamToken",
    "PreparedEdgeExtendToolActivationPostToken",
    "PreparedEdgeExtendToolActivationPreToken",
    "PreparedEdgeExtrudeActivationToken",
    "PreparedEdgeSliceActivationToken",
    "PreparedEdgeSliceDeactivateToken",
    "PreparedEdgeSliceParamToken",
    "PreparedInheritedNoopToken",
    "PreparedLoopSliceActivationToken",
    "PreparedLoopSliceDeactivateToken",
    "PreparedLoopSliceParamToken",
    "PreparedMirrorActivationToken",
    "PreparedMirrorDeactivateToken",
    "PreparedMoveUpdateToken",
    "PreparedPolyBevelActivationToken",
    "PreparedPolyExtrudeActivationToken",
    "PreparedPolyInsetActivationToken",
    "PreparedRadialArrayTransitionToken",
    "PreparedRotateUpdateToken",
    "PreparedScaleUpdateToken",
    "PreparedSliceActivationToken",
    "PreparedSliceParamToken",
    "PreparedSmoothShiftActivationToken",
    "PreparedStrokeExtrudeActivationToken",
    "PreparedTackActivationToken",
    "PreparedTopologyPenActivationToken",
    "PreparedTopologyPenDeactivateToken",
    "PreparedTransformActivationToken",
    "PreparedTransformProductActivationToken",
    "PreparedVertexBevelActivationToken",
    "PreparedVertexExtrudeActivationToken",
    "PreparedVertexMergeActivationToken",
    "PreparedXfrmActivationPreToken",
    "PreparedXfrmMoveRegradeToken",
    "PreparedXfrmSlotPollToken",
    "PreparedXfrmUpdateBoundaryToken",
    "PreparedXfrmUpdateEditCloseToken",
    "PreparedXfrmUpdateTailToken",
    "ValidatedBridgeActivationToken",
    "ValidatedBridgeDeactivateToken",
    "ValidatedCommandWrapperActivationToken",
    "ValidatedEdgeBevelActivationToken",
    "ValidatedEdgeExtendToolActivationPostToken",
    "ValidatedEdgeExtendToolActivationPreToken",
    "ValidatedEdgeExtrudeActivationToken",
    "ValidatedEdgeSliceActivationToken",
    "ValidatedLoopSliceActivationToken",
    "ValidatedMirrorActivationToken",
    "ValidatedMirrorDeactivateToken",
    "ValidatedMoveUpdateToken",
    "ValidatedPolyBevelActivationToken",
    "ValidatedPolyExtrudeActivationToken",
    "ValidatedPolyInsetActivationToken",
    "ValidatedRadialArrayTransitionToken",
    "ValidatedRotateUpdateToken",
    "ValidatedScaleUpdateToken",
    "ValidatedSliceActivationToken",
    "ValidatedSmoothShiftActivationToken",
    "ValidatedStrokeExtrudeActivationToken",
    "ValidatedTackActivationToken",
    "ValidatedTopologyPenActivationToken",
    "ValidatedTopologyPenDeactivateToken",
    "ValidatedTransformActivationToken",
    "ValidatedTransformProductActivationToken",
    "ValidatedVertexBevelActivationToken",
    "ValidatedVertexExtrudeActivationToken",
    "ValidatedVertexMergeActivationToken",
    "ValidatedXfrmSlotPollToken",
    "ValidatedXfrmUpdateEditCloseToken",
    "ValidatedXfrmUpdateTailToken",
];

private bool censusCovers(string typeName) {
    foreach (row; kCensusTokens)
        if (row.length > typeName.length + 1
            && row[$ - typeName.length .. $] == typeName
            && row[$ - typeName.length - 1] == '.')
            return true;
    return false;
}

static assert(kRetiredCopyFixtureTokens.length == 75,
    "the retired-fixture roster changed size");
static foreach (t; kRetiredCopyFixtureTokens)
    static assert(censusCovers(t),
        "retired copy fixture for " ~ t ~ " has no replacement in the census");

