// Task 9429 (wave-2 plan §9.4): the topology-step client body, the gizmo rebase and
// the session commit pair have ONE home, `source/tools/topology_step.d`; the twelve
// model classes compose it by mixin and the topology pen keeps its own block (a
// captured fold law). Order (form item 2): floor -> needle -> structural -> pin.
module tests.unit.topology_step_mixin_census_test;

import std.algorithm : sort;
import std.array : array;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, replace;
import tests.unit.census_symbols : blankNonCode, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum kHome = "source/tools/topology_step.d";
private enum kPen  = "source/tools/edit/topology_pen/tool.d";

private struct Client { string mod, cls; bool gizmo, commitPair, ownDormant; }
private enum Client[] kComposition = [
    Client("tools.alignment.array_tool", "ArrayTool"),
    Client("tools.alignment.clone_tool", "CloneTool"),
    Client("tools.alignment.mirror", "MirrorTool"),
    Client("tools.alignment.radial_array_tool", "RadialArrayTool"),
    Client("tools.edit.poly_inset_tool", "PolyInsetTool", false, true),
    Client("tools.edit.vert_merge_tool", "VertexMergeTool", false, true),
    Client("tools.deform.smooth_shift_tool", "SmoothShiftTool", true, true),
    Client("tools.edit.edge_bevel", "EdgeBevelTool", true, true),
    Client("tools.edit.edge_extrude", "EdgeExtrudeTool", true, true),
    Client("tools.edit.poly_extrude", "PolyExtrudeTool", true, true, true),
    Client("tools.edit.vertex_bevel_tool", "VertexBevelTool", true, true),
    Client("tools.edit.vertex_extrude_tool", "VertexExtrudeTool", true, true),
];
private enum kMixins = ["TopologyStepClientBody", "SessionCommitHooks", "GizmoTopologyRebase"];
private string pathOf(Client c) { return "source/" ~ c.mod.replace(".", "/") ~ ".d"; }

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

unittest { // each mixin is named by its home and exactly its clients
    auto code = sourceCode();
    // FLOOR (form item 4): the home, the pen and the twelve clients are read.
    assert(kHome in code && kPen in code, "9429 floor: the home or the topology pen is missing");
    foreach (c; kComposition) assert(pathOf(c) in code, "9429 floor: no client file " ~ pathOf(c));
    // NEEDLE (polarity: true after 9429), per mixin: 12 + 8 + 6 clients.
    foreach (i, m; kMixins) {
        string[] want = [kHome];
        foreach (c; kComposition) if ([true, c.commitPair, c.gizmo][i]) want ~= pathOf(c);
        assert(want.length == 1 + [12, 8, 6][i], format("9429 floor: %s clients of %s", want.length - 1, m));
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
    static assert(declaredInHome!(C, "commitOperation") == c.commitPair
                  && declaredInHome!(C, "commitUncommittedEdit") == c.commitPair,
                  c.cls ~ ": the commit pair's class/mixin split moved");
}} }
