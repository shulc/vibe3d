// Task 9429 (wave-2 plan §9.4): the topology-step client body, the gizmo rebase and
// the session commit pair have ONE home, `source/tools/topology_step.d`; the twelve
// model classes compose it by mixin and the topology pen keeps its own block (a
// captured fold law). Order (form item 2): floor -> needle -> structural -> pin.
module tests.unit.topology_step_mixin_test;

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, replace;
import tests.unit.census_symbols : blankNonCode, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum kHome = "source/tools/topology_step.d";
private enum kPen  = "source/tools/edit/topology_pen/tool.d";

/// The model's twelve client files -> the mixins each composes.
private enum string[][string] kClients = [
    "source/tools/alignment/array_tool.d":        ["TopologyStepClientBody"],
    "source/tools/alignment/clone_tool.d":        ["TopologyStepClientBody"],
    "source/tools/alignment/mirror.d":            ["TopologyStepClientBody"],
    "source/tools/alignment/radial_array_tool.d": ["TopologyStepClientBody"],
    "source/tools/edit/poly_inset_tool.d":  ["TopologyStepClientBody", "SessionCommitHooks"],
    "source/tools/edit/vert_merge_tool.d":  ["TopologyStepClientBody", "SessionCommitHooks"],
    "source/tools/deform/smooth_shift_tool.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
    "source/tools/edit/edge_bevel.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
    "source/tools/edit/edge_extrude.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
    "source/tools/edit/poly_extrude.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
    "source/tools/edit/vertex_bevel_tool.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
    "source/tools/edit/vertex_extrude_tool.d":
        ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"],
];
private enum kMixins = ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"];

/// Whole-identifier occurrences of `word` in comment/string-blanked code.
private size_t words(string code, string word) {
    size_t n;
    for (ptrdiff_t at = code.indexOf(word); at >= 0;) {
        const e = at + word.length;
        if ((at == 0 || !isIdentChar(code[at - 1])) && (e == code.length || !isIdentChar(code[e])))
            ++n;
        const next = code[e .. $].indexOf(word);
        at = next < 0 ? -1 : e + next;
    }
    return n;
}

/// Every `source/**.d` file, relative path -> blanked code.
private string[string] sourceCode() {
    string[string] code;
    foreach (e; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        code[relativePath(e.name, repoRoot)] = blankNonCode(readText(e.name));
    return code;
}

/// Files whose code names `word`, sorted.
private string[] filesNaming(const string[string] code, string word) {
    string[] r;
    foreach (f, c; code) if (words(c, word)) r ~= f;
    return r.sort.array;
}

unittest { // the composition: each client mixes in exactly its set, each once
    auto code = sourceCode();
    // FLOOR: the home and the twelve clients are read (form item 4).
    assert(kHome in code && kPen in code, "9429 floor: the home or the topology pen is missing");
    assert(kClients.length == 12, format("9429 floor: %s clients named, 12 measured", kClients.length));
    size_t uses;
    foreach (f, want; kClients) {
        assert(f in code, "9429 floor: no client file " ~ f);
        foreach (m; kMixins) {
            const n = words(code[f], m);
            assert(n == (want.canFind(m) ? 1 : 0),
                   format("9429 structural: %s names %s %s times, expected %s", f, m, n,
                          want.canFind(m) ? 1 : 0));
            uses += n;
        }
    }
    assert(uses == 12 + 8 + 6, format("9429 structural: %s mixin uses, measured 26 (12 + 8 + 6)", uses));
    // NEEDLE (polarity: true after 9429): each mixin is named only by its home and its clients.
    foreach (m; kMixins) {
        string[] want = [kHome];
        foreach (f, ms; kClients) if (ms.canFind(m)) want ~= f;
        assert(filesNaming(code, m) == want.sort.array,
               format("9429 needle: %s is named in %s, expected %s", m, filesNaming(code, m), want));
    }
}

unittest { // the deleted copies live only in the home and the topology pen
    auto code = sourceCode();
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
    assert(carriers == [kHome], format("9429 needle: a topology-step carrier body stands in "
                                       ~ "%s; expected the home only (the pen's is its own)", carriers));
    assert(gizmos == [kHome], format("9429 needle: a gizmo rebase body stands in %s; expected "
                                     ~ "the home only", gizmos));
    assert(pairs == [kHome], format("9429 needle: a session commit pair stands in %s; expected "
                                    ~ "the home only", pairs));
    // The declarations of the interface member: the interface, the home, the pen.
    assert(filesNaming(code, "topologyStepCarrier").length >= 3
           && code[kHome].words("topologyStepCarrier") == 1
           && code[kPen].words("topologyStepCarrier") == 1,
           "9429 needle: topologyStepCarrier lost the home's or the pen's declaration");
    // The one allowed hook: declared by exactly the two tools whose rebase adds lines.
    assert(filesNaming(code, "afterTopologyRebase")
           == [kHome, "source/tools/deform/smooth_shift_tool.d", "source/tools/edit/edge_bevel.d"].sort.array,
           format("9429 needle: afterTopologyRebase is named in %s",
                  filesNaming(code, "afterTopologyRebase")));
}

// PIN (form item 1): the hook is a member the compiler sees, so the mixin's
// `__traits(hasMember)` branch is taken for these two and no other gizmo tool.
static assert(__traits(hasMember, imported!"tools.deform.smooth_shift_tool".SmoothShiftTool,
                       "afterTopologyRebase"));
static assert(__traits(hasMember, imported!"tools.edit.edge_bevel".EdgeBevelTool,
                       "afterTopologyRebase"));
static assert(!__traits(hasMember, imported!"tools.edit.edge_extrude".EdgeExtrudeTool,
                        "afterTopologyRebase"));
static assert(is(imported!"tools.alignment.mirror".MirrorTool : imported!"tool".TopologyStepClient));

// ---------------------------------------------------------------------------
// Behaviour of the shared bodies, read through one client each (task 9429 drill:
// the suite families do not see the gizmo rebase's terms, its hook, nor the basis
// the body hands the session — every such mutation stayed green there).
// ---------------------------------------------------------------------------
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import shader : LitShader;
import snapshot : MeshSnapshot;
import tools.alignment.mirror : MirrorTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.edge_bevel : EdgeBevelTool;

private Mesh selectedCube(EditMode m) {
    Mesh c = makeCube();
    c.syncSelection();
    if (m == EditMode.Edges) c.selectEdge(0); else c.selectFace(0);
    return c;
}

unittest { // the gizmo rebase over the live mesh: frame on it, drag state cleared, hook ran
    Mesh mesh = selectedCube(EditMode.Edges), old = makeCube();
    old.vertices[0] = Vec3(4, 5, 6);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(old);
    const want = tool.preparedFrameForTest(mesh);
    // Rig: the seed is stale everywhere the rebase must write (form item 5).
    const s = tool.readInteractionForTest();
    assert(want.gizmoValid && s.anchor != want.anchor && s.dragPart != -1 && s.built
           && !tool.previewResetForTest(), "9429 rig VOID: the seed does not differ from the rebase");
    tool.rebaseTopologyStep(MeshSnapshot.capture(mesh));
    const r = tool.readInteractionForTest();
    assert(r.gizmoValid && r.anchor == want.anchor && r.baseAnchor == want.baseAnchor
           && r.widthAxis == want.widthAxis && r.gizmoSelHash == want.gizmoSelHash,
           "9429 gizmo rebase: the frame over a matching basis is not the live mesh's");
    assert(!r.built && r.dragPart == -1, "9429 gizmo rebase: built or dragPart survived a rebase");
    assert(tool.previewResetForTest(), "9429 edge bevel hook: the rebase kept the old preview key");
    assert(tool.topologyStepLabel() == "Edge Bevel" && tool.topologyStepMesh() is &mesh
           && tool.topologyStepBasis().matches(mesh),
           "9429 client body: Edge Bevel's label, mesh or basis is not its own");
}

unittest { // the gizmo rebase over a stale basis: frame on the basis, mesh put back, built
    Mesh mesh = selectedCube(EditMode.Edges), basis = selectedCube(EditMode.Edges);
    const v = basis.edges[0][0];
    basis.vertices[v] = basis.vertices[v] + Vec3(0.5f, 0.25f, 0);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    Mesh old = makeCube();
    tool.seedPreparedActivationForTest(old);
    const onBasis = tool.preparedFrameForTest(basis), onLive = tool.preparedFrameForTest(mesh);
    assert(onBasis.gizmoValid && onBasis.anchor != onLive.anchor,
           "9429 rig VOID: the basis does not move the frame");
    const live = mesh.vertices.dup;
    tool.rebaseTopologyStep(MeshSnapshot.capture(basis));
    const r = tool.readInteractionForTest();
    assert(r.anchor == onBasis.anchor && r.widthAxis == onBasis.widthAxis,
           "9429 gizmo rebase: the frame over a stale basis is not the basis's");
    assert(r.built && r.dragPart == -1 && mesh.vertices == live,
           "9429 gizmo rebase: a stale basis left built false, a drag part, or the basis on screen");
}

unittest { // Smooth Shift's own hook: a rebased step belongs to an engaged operation
    Mesh mesh = selectedCube(EditMode.Polygons);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Polygons;
    auto tool = new SmoothShiftTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedParamForTest(mesh, false);
    assert(!tool.buildPreparedParamUpdate(mesh).expected.engaged, "9429 rig VOID: seeded engaged");
    tool.rebaseTopologyStep(MeshSnapshot.capture(mesh));
    assert(tool.buildPreparedParamUpdate(mesh).expected.engaged,
           "9429 smooth shift hook: a rebased step is not engaged");
    assert(tool.topologyStepLabel() == "Smooth Shift", "9429 client body: Smooth Shift's label");
}

unittest { // Mirror's basis field and own rebase, through the shared restore body
    Mesh mesh = selectedCube(EditMode.Polygons), other = makeCube();
    other.vertices[0] = Vec3(4, 5, 6);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    auto tool = new MirrorTool(() => &mesh, &gpu, LitShader.init);
    assert(!tool.topologyStepBasis().matches(other), "9429 rig VOID: the basis already matches");
    tool.restoreTopologyStep(tool.captureAttrImage(), MeshSnapshot.capture(other));
    assert(tool.topologyStepBasis().matches(other),
           "9429 client body: Mirror's basis is not the field its rebase wrote");
    assert(tool.topologyStepLabel() == "Mirror" && tool.topologyStepMesh() is &mesh,
           "9429 client body: Mirror's label or mesh is not its own");
}

unittest { // the session commit pair: re-bases an active tool in place, refuses an idle one
    Mesh mesh = selectedCube(EditMode.Polygons);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Polygons;
    auto tool = new SmoothShiftTool(() => &mesh, &gpu, &mode, LitShader.init);
    assert(!tool.commitUncommittedEdit() && !tool.commitOperation(),
           "9429 commit pair: an inactive tool committed, or the in-place commit is not refused");
    tool.seedPreparedParamForTest(mesh, true);
    const s = tool.buildPreparedParamUpdate(mesh).expected;
    assert(s.active && s.built && s.engaged, "9429 rig VOID: the seed is not a built, engaged tool");
    assert(tool.commitOperation(), "9429 commit pair: an active tool's close was refused");
    const e = tool.buildPreparedParamUpdate(mesh).expected;
    assert(!e.built && !e.engaged, "9429 commit pair: the close did not re-base the tool in place");
}
