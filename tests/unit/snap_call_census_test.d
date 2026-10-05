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
    // Floor, then the roster: six production calls, one per file.
    assert(calls.length == 6, format("snapCursor production calls: %s %s", calls.length, fileRoster(calls)));
    assert(fileRoster(calls) == [
        "source/http_providers.d", "source/toolpipe/stages/snap.d",
        "source/tools/create/create_common.d", "source/tools/create/pen.d",
        "source/tools/transform/move.d", "source/tools/transform/transform.d"],
        format("snapCursor call roster: %s", fileRoster(calls)));
    assert(others.length == 0, format("snapCursor reached other than by a call: %s", fileRoster(others)));
    // The needle. pen.d's merge query is the one exempt row: pen-owned and frozen
    // while the pen wave runs; the interaction-layer pen slices own it.
    Site[] guideless;
    foreach (c; calls) if (!consultsGuides(c.args)) guideless ~= c;
    assert(fileRoster(guideless) == ["source/tools/create/pen.d"],
        format("snapCursor calls that do not consult the guides: %s", fileRoster(guideless)));
}

unittest // one packet read, one finder: the deleted copies stay deleted
{
    const files = productionSources();
    assert(files.length >= 500, format("population floor: %s source files scanned", files.length));
    size_t[string] raw;
    string[] finders, casts, faceCalls;
    foreach (f; files) {
        foreach (id; ["captureSnapForGesture", "snapStageForGesture", "guideBits_", "snapPacketOf"])
            raw[id] = raw.get(id, 0) + wordsAt(f[1], id).length;   // RAW text: comments count too
        const code = blankUnittestBodies(blankNonCode(f[1]));
        foreach (at; wordsAt(code, "findByTask")) {
            const open = code.indexOf('(', at);
            if (balancedSpan(code, open, '(', ')').canFind("TaskCode.Snap")) finders ~= f[0];
        }
        foreach (_; 0 .. countOccurrences(code, "cast(SnapStage)")) casts ~= f[0];
        Site[] fc, fo;
        scanCalls(f[0], code, "snapFace", "SnapResult", fc, fo);
        foreach (c; fc ~ fo) faceCalls ~= c.file;
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
    assert(faceCalls == ["source/tools/create/box.d", "source/tools/create/box.d"],
        format("snapFace must have exactly its two face callers: %s", faceCalls));
}

unittest // the signatures the clients rely on (compiler pins)
{
    import operator : VectorStack;
    import snap : snapPacketOf, kGuideTypes;
    import toolpipe.packets : SnapPacket, SnapType;
    import toolpipe.guide : SnapGuide;
    import toolpipe.stages.snap : SnapStage, liveSnapStage, liveSnapGuides;
    static assert(is(typeof(&snapPacketOf) == SnapPacket function(ref VectorStack)));
    static assert(is(typeof(&liveSnapStage) == SnapStage function()));
    static assert(is(typeof(&liveSnapGuides) == SnapGuide[] function()));
    static assert(kGuideTypes == (SnapType.WorldAxis | SnapType.StraightLine | SnapType.RightAngle));
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
        size_t asked;
        void limits(float, float) {}
        bool proximity(Vec3, SnapType, int, int, out float d, ref int) { ++asked; return false; }
        void setDrawState(GuideDrawState) {}
        uint flags() const { return 0; }
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
    assert(liveSnapGuides() == [cast(SnapGuide)g], "the registry is what the finder hands out");
    assert(!snappedAt() && g.asked > 0,
        format("a registered refusing guide must reach snapLocalHit's query (asked %s)", g.asked));
}
