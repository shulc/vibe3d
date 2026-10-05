// Task 9405: one snap packet read (`snap.snapPacketOf`), one stage finder
// (`toolpipe.stages.snap.liveSnapStage`) and one call shape — every production
// `snapCursor` call consults the registered guides (`liveSnapGuides()`, or the
// stage's own `_guides`). Source census over the production text (unittest
// bodies blanked), then one behaviour cell: a guide registered on the live
// stage changes a create tool's answer.
module tests.unit.snap_call_census_test;

import std.algorithm : canFind, map, sort;
import std.array     : array;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, balancedSpan,
                                   countOccurrences, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private struct Site { string file; string args; }

/// Whole-word occurrences of `id` in `code`.
private size_t[] wordsAt(string code, string id) {
    size_t[] at;
    for (ptrdiff_t i = code.indexOf(id); i >= 0;
         i = code.indexOf(id, cast(size_t)i + 1)) {
        const size_t e = cast(size_t)i + id.length;
        if ((i == 0 || !isIdentChar(code[i - 1])) && (e >= code.length || !isIdentChar(code[e])))
            at ~= cast(size_t)i;
    }
    return at;
}

/// Every use of `id` in a code view, classified: a CALL (followed by `(`)
/// gets its argument span; the declaration (preceded by its return type
/// `SnapResult`) and import-list mentions are skipped; anything else (an
/// address, an alias) is returned as an "other" site with empty args.
private void scanCalls(string file, string code, string id, string declType,
                       ref Site[] calls, ref Site[] others) {
    foreach (at; wordsAt(code, id)) {
        size_t j = at + id.length;
        while (j < code.length && (code[j] == ' ' || code[j] == '\n')) ++j;
        size_t k = at;
        while (k > 0 && (code[k - 1] == ' ' || code[k - 1] == '\n')) --k;
        const bool decl = k >= declType.length && code[k - declType.length .. k] == declType;
        size_t s = at;
        while (s > 0 && code[s - 1] != ';' && code[s - 1] != '{' && code[s - 1] != '}') --s;
        const bool imported = code[s .. at].strip.indexOf("import ") == 0;
        if (decl || imported) continue;
        if (j < code.length && code[j] == '(') calls ~= Site(file, balancedSpan(code, j, '(', ')'));
        else others ~= Site(file, "");
    }
}

private string[2][] productionSources() {
    string[2][] files;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        files ~= [de.name[repoRoot.length + 1 .. $], readText(de.name)];
    return files;
}

private string[] fileRoster(const Site[] sites) {
    string[] r = sites.map!(s => s.file.idup).array;
    r.sort();
    return r;
}

/// A call consults the guide registry when its argument text names it.
private bool consultsGuides(string args) {
    return args.canFind("liveSnapGuides()") || wordsAt(args, "_guides").length != 0;
}

unittest // the scanner itself: positive controls on a scratch buffer
{
    Site[] calls, others;
    enum scratch = "import snap : snapCursor, X;\nSnapResult snapCursor(Vec3 a) { return r; }\n"
                 ~ "void f() { auto r = snapCursor(a, b, null, liveSnapGuides());\n"
                 ~ "  auto q = snapCursor (a, pkt);\n  auto p = &snapCursor; }";
    scanCalls("scratch.d", scratch, "snapCursor", "SnapResult", calls, others);
    assert(calls.length == 2 && others.length == 1,
        format("scanner control: 2 calls + 1 address expected, got %s / %s", calls.length, others.length));
    assert(consultsGuides(calls[0].args) && !consultsGuides(calls[1].args),
        "scanner control: the guide-less call must be told apart from the consulting one");
}

unittest // every production snapCursor call consults the guide registry
{
    const files = productionSources();
    assert(files.length >= 500, format("population floor: %s source files scanned", files.length));
    Site[] calls, others;
    foreach (f; files)
        scanCalls(f[0], blankUnittestBodies(blankNonCode(f[1])), "snapCursor", "SnapResult",
                  calls, others);
    // Floor, then the roster: seven production calls, one per file.
    assert(calls.length == 7, format("snapCursor production calls: %s %s", calls.length, fileRoster(calls)));
    assert(fileRoster(calls) == [
        "source/http_providers.d", "source/snap.d", "source/toolpipe/stages/snap.d",
        "source/tools/create/create_common.d", "source/tools/create/pen.d",
        "source/tools/transform/move.d", "source/tools/transform/transform.d"],
        format("snapCursor call roster: %s", fileRoster(calls)));
    assert(others.length == 0, format("snapCursor reached other than by a call: %s", fileRoster(others)));
    // The needle. pen.d's merge query is exempt: pen-owned and frozen while the
    // pen wave runs; the interaction-layer pen slices own it. The topology
    // tools' vertex finder `snap.editedVertexAt` is exempt: its admit is the
    // gesture's own policy, and the registered guide would veto Split's
    // interior target (tasks 9407, 9437).
    Site[] guideless;
    foreach (c; calls) if (!consultsGuides(c.args)) guideless ~= c;
    assert(fileRoster(guideless) == ["source/snap.d", "source/tools/create/pen.d"],
        format("snapCursor calls that do not consult the guides: %s", fileRoster(guideless)));
}

unittest // one packet read, one finder: the deleted copies stay deleted
{
    const files = productionSources();
    assert(files.length >= 500, format("population floor: %s source files scanned", files.length));
    size_t[string] raw;
    string[] finders, casts, faceCalls, liveCalls, packetReads;
    foreach (f; files) {
        foreach (id; ["captureSnapForGesture", "snapStageForGesture", "guideBits_", "snapPacketOf"])
            raw[id] = raw.get(id, 0) + wordsAt(f[1], id).length;   // RAW text: comments count too
        const code = blankUnittestBodies(blankNonCode(f[1]));
        foreach (at; wordsAt(code, "findByTask")) {
            const open = code.indexOf('(', at);
            if (balancedSpan(code, open, '(', ')').canFind("TaskCode.Snap")) finders ~= f[0];
        }
        foreach (_; 0 .. countOccurrences(code, "cast(SnapStage)")) casts ~= f[0];
        foreach (_; 0 .. countOccurrences(code, "get!SnapPacket")) packetReads ~= f[0];
        Site[] fc, fo;
        scanCalls(f[0], code, "snapFace", "SnapResult", fc, fo);
        foreach (c; fc ~ fo) faceCalls ~= c.file;
        Site[] lc, lo;
        scanCalls(f[0], code, "liveSnapStage", "SnapStage", lc, lo);
        foreach (c; lc ~ lo) liveCalls ~= c.file;
    }
    // Positive control for the raw counts: the one new read is present.
    assert(raw["snapPacketOf"] >= 8, format("positive control: snapPacketOf occurs %s times", raw["snapPacketOf"]));
    foreach (id; ["captureSnapForGesture", "snapStageForGesture", "guideBits_"])
        assert(raw[id] == 0, format("deleted copy `%s` is back: %s occurrences", id, raw[id]));
    finders.sort(); casts.sort();
    // The finder lives in the stage module; the prepared activation builds a
    // FRESH pipe, not the live one, so it keeps its own lookup.
    enum kFinderRoster = ["source/prepared_topology_pen_activation.d",
                          "source/toolpipe/stages/snap.d"];
    assert(finders == kFinderRoster, format("findByTask(TaskCode.Snap) roster: %s", finders));
    assert(casts == kFinderRoster, format("cast(SnapStage) roster: %s", casts));
    // One packet read: `snapPacketOf` in snap.d; the pipe-state HTTP provider
    // reads it beside its other packets. Text needle: `get!(SnapPacket)` or
    // an alias would pass it.
    packetReads.sort();
    assert(packetReads == ["source/http_providers.d", "source/snap.d"],
        format("get!SnapPacket production roster: %s", packetReads));
    liveCalls.sort();
    assert(liveCalls == ["source/commands/snap/mode.d", "source/commands/snap/toggle.d",
                         "source/commands/snap/toggle_type.d", "source/editor_app.d",
                         "source/toolpipe/stages/snap.d", "source/toolpipe/stages/snap.d",
                         "source/tools/create/pen.d", "source/tools/create/pen.d",
                         "source/tools/edit/topology_pen/tool.d",
                         "source/tools/edit/topology_pen/tool.d", "source/tools/edit/topology_pen/tool.d",
                         "source/tools/edit/topology_pen/tool.d", "source/tools/edit/topology_pen/tool.d",
                         "source/tools/slice/slice_tool.d", "source/tools/slice/slice_tool.d",
                         "source/tools/transform/xfrm_transform.d"],
        format("liveSnapStage() call roster (%s): %s", liveCalls.length, liveCalls));
    assert(faceCalls == ["source/tools/create/box.d", "source/tools/create/box.d"],
        format("snapFace must have exactly its two face callers: %s", faceCalls));
}

unittest // no client but the pen registers a guide: snapCursor elects no guide-type candidate
{
    // Task 9406 (capture K-G): the world-axis / straight-line bits are inert on
    // every non-pen client, so `snapCursor` offers no candidate of a guide type.
    // Floor: the constraint tier keeps exactly its box-face call. Needle: a guide
    // type in any `consider*` call, or the world-axis enumeration's math helper.
    const code = blankUnittestBodies(blankNonCode(readText(buildPath(repoRoot, "source", "snap.d"))));
    string[] constraintArgs, guideArgs;
    size_t offered;
    foreach (id; ["considerConstraint", "consider"])
        foreach (at; wordsAt(code, id)) {
            const open = at + id.length;
            if (open >= code.length || code[open] != '(') continue;
            const args = balancedSpan(code, open, '(', ')');
            ++offered;
            if (id == "considerConstraint") constraintArgs ~= args;
            foreach (t; ["WorldAxis", "StraightLine", "RightAngle"])
                if (wordsAt(args, t).length) guideArgs ~= args;
        }
    assert(offered == 8, format("consider* production calls: %s (floor 8)", offered));
    assert(constraintArgs.length == 1 && constraintArgs[0].canFind("SnapType.Box"),
        format("constraint-tier floor: the box-face call only, got %s", constraintArgs));
    assert(guideArgs.length == 0, format("snapCursor offers a guide-type candidate: %s", guideArgs));
    assert(wordsAt(code, "closestPointOnLineToRay").length == 0,
        "snap.d reaches the line helper again (the origin world-axis lines)");
}

unittest // one vertex finder for the topology tools (tasks 9407, 9437); the pen's press pick stays
{
    string code(string file) {
        return blankUnittestBodies(blankNonCode(readText(buildPath(repoRoot, file))));
    }
    string body(string src, string decl) {
        const at = src.indexOf(decl);
        assert(at >= 0, "declaration not found: " ~ decl);
        return balancedSpan(src, src.indexOf('{', at), '{', '}');
    }
    // The finder: the election's vertex leg, Global scope, both ranges, slot 0.
    const finder = body(code("source/snap.d"), "int editedVertexAt(");
    assert(finder.length > 200, format("editedVertexAt body: %s chars", finder.length));
    foreach (needle; ["snapCursor(", "SnapMode.Global", "outerRangePx", "slot == 0"])
        assert(countOccurrences(finder, needle) == 1,
            format("editedVertexAt must contain `%s` once", needle));
    // Its callers: the pen's weld target and Drag Weld's one finder, nothing else.
    string[] callers;
    foreach (f; productionSources())
        foreach (_; wordsAt(blankUnittestBodies(blankNonCode(f[1])), "editedVertexAt"))
            callers ~= f[0];
    callers.sort();
    assert(callers.length == 5, format("editedVertexAt mentions: %s %s", callers.length, callers));
    assert(callers == ["source/snap.d", "source/tools/edit/drag_weld.d",
                       "source/tools/edit/drag_weld.d", "source/tools/edit/topology_pen/tool.d",
                       "source/tools/edit/topology_pen/tool.d"],
        format("editedVertexAt roster (declaration + import + call per client): %s", callers));
    const weld = code("source/tools/edit/drag_weld.d");
    assert(wordsAt(weld, "findVertex").length == 3 && wordsAt(weld, "projectToWindowFull").length == 0,
        "Drag Weld: the press and the release reach the one finder, and nothing projects on its own");
    const pen = code("source/tools/edit/topology_pen/tool.d");
    assert(countOccurrences(body(pen, "int weldTargetVertex("), "editedVertexAt(") == 1,
        "the pen's weld target must be the shared finder");
    foreach (decl; ["int resolveSnapTargetVert(", "int resolveSplitTargetVert("]) {
        const b = body(pen, decl);
        assert(wordsAt(b, "findSourceVertex").length == 0,
            format("%s still calls the press pick", decl));
        assert(wordsAt(b, "weldTargetVertex").length == (decl.canFind("Split") ? 1 : 2),
            format("%s weldTargetVertex calls: %s", decl, wordsAt(b, "weldTargetVertex").length));
    }
    // Positive control: the press pick is still there, unchanged by this slice.
    assert(pen.indexOf("int findSourceVertex(") >= 0, "the press pick must still exist");
}

unittest // the signatures the clients rely on (compiler pins)
{
    import operator : VectorStack;
    import math : Vec3, Viewport;
    import snap : snapPacketOf;
    import toolpipe.packets : SnapPacket, SnapType;
    import toolpipe.guide : SnapGuide;
    import toolpipe.stages.snap : SnapStage, liveSnapStage, liveSnapGuides;
    static assert(is(typeof(&snapPacketOf) == SnapPacket function(ref VectorStack)));
    static assert(is(typeof(&liveSnapStage) == SnapStage function()));
    static assert(is(typeof(&liveSnapGuides) == SnapGuide[] function()));
    // Task 9416: a guide may propose a position; the guide-type mask is gone
    // (the bits reach the guide's own `propose` through the packet).
    static assert(is(typeof((SnapGuide g, Vec3 p, ref Viewport vp, ref SnapPacket c) {
        Vec3 o; SnapType t; bool b = g.propose(p, 1, 2, vp, c, o, t); })));
    static assert(!__traits(compiles, { import snap : kGuideTypes; }));
    VectorStack empty;
    assert(snapPacketOf(empty) == SnapPacket.init && !snapPacketOf(empty).enabled,
        "no SNAP stage ran: the read answers the init packet, snapping off");
}

unittest // a guide registered on the live stage reaches a create tool's query
{
    import math             : Vec3, Viewport, lookAt, perspectiveMatrix,
                              projectToWindowFull, identityMatrix;
    import mesh             : Mesh;
    import editmode         : EditMode;
    import snap             : invalidateSnapGrids;
    import std.math         : PI, round;
    import toolpipe.guide   : SnapGuide, GuideDrawState;
    import toolpipe.packets : SnapType;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.stages.snap : SnapStage, liveSnapStage, liveSnapGuides;
    import tools.create.create_common : snapLocalHit, WorkplaneFrame;

    static class Refuse : SnapGuide {
        import toolpipe.packets : SnapPacket;
        size_t asked;
        void limits(float, float) {}
        bool proximity(Vec3, SnapType, int, int, ref float d, ref int) { ++asked; return false; }
        void setDrawState(GuideDrawState) {}
        uint flags() const { return 0; }
        bool propose(Vec3, int, int, const ref Viewport, const ref SnapPacket,
                     out Vec3, out SnapType) { return false; }
    }

    auto saved = g_pipeCtx;
    scope (exit) g_pipeCtx = saved;
    g_pipeCtx = null;
    assert(liveSnapStage() is null && liveSnapGuides() is null, "no pipeline: no stage, no guides");

    auto ctx = new ToolPipeContext();
    auto st  = new SnapStage();
    ctx.pipeline.add(st);   // registration resets the stage: configure after it
    st.enabled = true;
    st.enabledTypes = SnapType.Vertex;
    g_pipeCtx = ctx;
    assert(liveSnapStage() is st, "the finder answers the live pipeline's stage");

    invalidateSnapGrids();
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    Mesh m;
    m.vertices = [Vec3(0, 0, 0)];
    float px, py, pz;
    assert(projectToWindowFull(m.vertices[0], vp, px, py, pz));
    WorkplaneFrame frame;
    frame.toWorld = identityMatrix;
    frame.toLocal = identityMatrix;

    bool snappedAt() {
        Vec3 hit = Vec3(0.05f, 0, 0);
        return snapLocalHit(hit, frame, cast(int)round(px) + 3, cast(int)round(py), vp, m,
                            EditMode.Vertices).snapped;
    }
    // Control first: an empty registry snaps onto the vertex under the cursor.
    assert(liveSnapGuides().length == 0 && snappedAt(), "control: empty registry snaps to the vertex");
    auto g = new Refuse();
    st.addGuide(g);
    scope (exit) st.removeGuide(g);
    assert(!snappedAt() && g.asked > 0,
        format("a registered refusing guide must reach snapLocalHit's query (asked %s)", g.asked));
    assert(liveSnapGuides() == [cast(SnapGuide)g], "the registry is what the finder hands out");
}
