// Task 9429 (wave-2 plan §9.4): the topology-step client body, the gizmo rebase and
// the session commit pair have ONE home, `source/tools/topology_step.d`; the twelve
// model classes compose it by mixin and the topology pen keeps its own block (a
// captured fold law). Order (form item 2): floor -> needle -> structural -> pin.
module tests.unit.topology_step_mixin_census_test;

import tests.unit.census_symbols : wave15InputsIntact, wave15InputStart;



import tests.unit.census_symbols : exists = wave15Exists;

import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, replace;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum kHome = "source/tools/topology_step.d";
private enum kPen  = "source/tools/edit/topology_pen/tool.d";

private struct Client { string mod, cls; bool gizmo, commitPair, ownDormant, hook; }
private enum Client[] kComposition = [
    Client("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool"),
    Client("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool"),
    Client("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool"),
    Client("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool"),
    Client("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool", false, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool", false, true),
    Client("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool", true, true, false, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool", true, true, false, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool", true, true, false, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool", true, true, true, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool", true, true, false, true),
    Client("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool", true, true, false, true),
];

/// Every `source/**.d` file, relative path -> blanked code.
private string[string] sourceCode() {
    string[string] code;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (e; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        code[relativePath(e.name, repoRoot)] = blankNonCode(readText(e.name));
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);code[relativePath(sourceCarrierPath, repoRoot)] = blankNonCode(readText(sourceCarrierPath));
    }
    return code;
}

unittest { // the deleted copies live only in the home and the topology pen
    auto wave15Inputs = wave15InputStart();
    auto code = sourceCode();
    assert(kHome in code && kPen in code, "9429 floor: the home or the topology pen is missing");
    // POSITIVE CONTROL: the needles find the bodies where they stand (form item 5).
    enum carrier = "gestureFactoryisnull?null:gestureFactory()";
    enum gizmo   = "visible.restore(*mesh);}elsecomputeGizmoFrame();";
    enum pair    = "if(!active)returnfalse;resyncSession();returntrue;";
    string[] carriers, gizmos, pairs;
    foreach (f, c; code) {
        const s = c.replace(" ", "").replace("\n", "").replace("\t", "");
        if (s.indexOf(carrier) >= 0) carriers ~= f;
        if (s.indexOf(gizmo) >= 0) gizmos ~= f;
        if (s.indexOf(pair) >= 0) pairs ~= f;
    }
    assert((carriers == [kHome]) && wave15InputsIntact(wave15Inputs), format("9429 needle: a topology-step carrier body stands in "
                                       ~ "%s; expected the home only (the pen's is its own)", carriers));
    assert(gizmos == [kHome], format("9429 needle: a gizmo rebase body stands in %s; expected "
                                     ~ "the home only", gizmos));
    assert(pairs == [kHome], format("9429 needle: a session commit pair stands in %s; expected "
                                    ~ "the home only", pairs));
}

static assert(is(imported!"vibe3d.editing.tools.interactive.tools.alignment.mirror".MirrorTool : imported!"vibe3d.editing.tools.interactive.tool".TopologyStepClient));

// PIN (form item 1), by the compiler: where each client's interface members and
// commit pair are DECLARED (`__traits(getLocation)` names the mixin's file for a
// mixed-in member, the class's for its own). A class member hides the mixin's, so
// this is also the proof that Mirror's and the short rebases, and Polygon Extrude's
// dormant setter, are the ones the vtable holds.
private bool declaredInHome(C, string m)() {
    import std.algorithm : endsWith;
    return __traits(getLocation, __traits(getOverloads, C, m)[0])[0].endsWith("topology_step.d");
}
static assert(kComposition.length == 12);
unittest { static foreach (c; kComposition) {{
    alias C = __traits(getMember, imported!(c.mod), c.cls);
    static foreach (m; ["topologyStepMesh", "topologyStepBasis", "topologyStepCarrier",
                        "recordTopologyStep", "topologyStepLabel", "restoreTopologyStep"])
        static assert(declaredInHome!(C, m), c.cls ~ "." ~ m ~ " is not the client mixin's");
    static assert(declaredInHome!(C, "setTopologyDormant") == !c.ownDormant,
                  c.cls ~ ".setTopologyDormant: the class/mixin split moved");
    static assert(declaredInHome!(C, "rebaseTopologyStep") == c.gizmo,
                  c.cls ~ ".rebaseTopologyStep: the class/mixin split moved");
    // The one allowed hook (plan §3.3): the gizmo mixin calls it unconditionally.
    static assert(__traits(hasMember, C, "afterTopologyRebase") == c.hook,
                  c.cls ~ ".afterTopologyRebase: the hook set moved");
    static assert(declaredInHome!(C, "commitOperation") == c.commitPair
                  && declaredInHome!(C, "commitUncommittedEdit") == c.commitPair,
                  c.cls ~ ": the commit pair's class/mixin split moved");
}} }
