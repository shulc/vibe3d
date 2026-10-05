// Task 9410 — one mirror walker, one side test.
// (c1) the pair rule `mirrorStepFor(` is called only by `walkMirrorPairs`, and
// the four mirror passes are walker callers with no loop of their own; (c2)
// the symmetry side test is `symmetrySide(` at every symmetry reader — Edge
// Extend keeps no `dot(` sign test; (w1) an auto work plane maps the axis by
// the world identity (K-S3a, task 9475); (w2) the walker's refusals; (w3) the
// pairings' epsilon side test; (w4) the routed walk's one change note. Task
// 9414: (c4) the work-plane symmetry plane is computed only in
// `workplaneSymmetryPlane`, called once by the stage and once by the pen, which
// maps it by the work plane once more (task 9417); (w6) its value under a pinned turned
// plane (K-S2). No symmetry overlay is drawn (K-S3b, task 9475: the suite's
// test_frame_counts pins it).
// Order: floors first, then the needles, then the pins (druntime stops a
// module at its first red).
module tests.unit.mirror_walker_census_test;

import std.conv : to;
import std.algorithm : sort;
import std.string : indexOf;
import tests.unit.census_symbols : countOccurrences, balancedSpan, blankNonCode,
                                   blankUnittestBodies;

private enum string kRepoRoot = () {
    import std.path : dirName;
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}();

private string codeOf(string rel) {
    import std.file : readText;
    import std.path : buildPath;
    return blankUnittestBodies(blankNonCode(readText(buildPath(kRepoRoot, rel))));
}

/// The balanced `{…}` body after the first `header` in `code` ("" if absent).
private string bodyAfter(string code, string header) {
    const h = code.indexOf(header);
    if (h < 0) return "";
    const b = code.indexOf('{', h);
    if (b < 0) return "";
    return balancedSpan(code, cast(size_t)b, '{', '}');
}

private string v3(T)(T v) {
    import std.format : format;
    return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z);
}

/// Every production file under source/ that contains `needle`, repo-relative.
private string[] filesWith(string needle, out size_t scanned) {
    import std.file : dirEntries, SpanMode;
    import std.path : buildPath;
    string[] hits;
    foreach (de; dirEntries(buildPath(kRepoRoot, "source"), "*.d", SpanMode.depth)) {
        ++scanned;
        const rel = de.name[kRepoRoot.length + 1 .. $];
        if (countOccurrences(codeOf(rel), needle) > 0) hits ~= rel;
    }
    hits.sort();
    return hits;
}

unittest { // (c1) ONE mirror walker
    size_t scanned;
    const callers = filesWith("mirrorStepFor(", scanned);
    assert(scanned >= 500, "(c1) floor: scanned " ~ scanned.to!string ~ " source files");
    // Needle: the declaration + the walker's one call, and nothing else anywhere.
    assert(callers == ["source/symmetry.d"], "(c1) mirrorStepFor( outside symmetry.d: " ~ callers.to!string);
    const sym = codeOf("source/symmetry.d");
    assert(countOccurrences(sym, "mirrorStepFor(") == 2,
           "(c1) symmetry.d mirrorStepFor( count " ~ countOccurrences(sym, "mirrorStepFor(").to!string
           ~ ", expected 2 (declaration + walkMirrorPairs)");
    const walker = bodyAfter(sym, "void walkMirrorPairs(");
    assert(walker.length > 200, "(c1) walkMirrorPairs body not found");
    assert(countOccurrences(walker, "mirrorStepFor(") == 1, "(c1) the walker does not call mirrorStepFor(");
    // Structural: each of the four passes is a walker caller with no loop.
    string[2][] passes = [
        ["source/symmetry.d", "void applySymmetryMirror(Mesh* mesh,"],
        ["source/symmetry.d", "void applySymmetryMirrorDelta(Mesh* mesh,"],
        ["source/tools/transform/morph_route.d", "void applySymmetryMirrorRouted("],
        ["source/tools/transform/morph_route.d", "void applySymmetryMirrorDeltaRouted("],
    ];
    int found;
    foreach (p; passes) {
        const body_ = bodyAfter(codeOf(p[0]), p[1]);
        assert(body_.length > 40, "(c1) pass body not found: " ~ p[1]);
        ++found;
        assert(countOccurrences(body_, "walkMirrorPairs!(") == 1,
               "(c1) " ~ p[1] ~ " does not call walkMirrorPairs!( exactly once");
        foreach (tok; ["foreach", "for (", "pairOf[", "vertSign[", "baseSide", "projectOnPlane("])
            assert(countOccurrences(body_, tok) == 0,
                   "(c1) " ~ p[1] ~ " keeps its own `" ~ tok ~ "` — the walk lives in walkMirrorPairs");
    }
    assert(found == 4, "(c1) pass population changed");
}

unittest { // (c2) ONE side test
    size_t scanned;
    const users = filesWith("symmetrySide(", scanned);
    assert(users == ["source/mesh_ops/extrude.d", "source/symmetry.d",
                     "source/toolpipe/stages/symmetry.d", "source/tools/edit/edge_extend.d"],
           "(c2) symmetrySide( users: " ~ users.to!string);
    // Edge Extend: the handle base and the ring offset read the side test, and
    // keep no `dot(` of their own beyond the offset's two normal components.
    const ee = codeOf("source/tools/edit/edge_extend.d");
    foreach (fn; ["Vec3 extendHandleBase(", "void readSymmetry(", "private int liveAuthoringSide("]) {
        const body_ = bodyAfter(ee, fn);
        assert(body_.length > 40, "(c2) body not found: " ~ fn);
        assert(countOccurrences(body_, "dot(") == 0, "(c2) " ~ fn ~ " keeps its own dot( sign test");
    }
    assert(countOccurrences(bodyAfter(ee, "Vec3 extendHandleBase("), "symmetrySide(") == 1,
           "(c2) extendHandleBase does not read symmetrySide(");
    const ring = bodyAfter(codeOf("source/mesh_ops/extrude.d"), "Vec3 ringOffset(uint v)");
    assert(ring.length > 40, "(c2) ringOffset body not found");
    assert(countOccurrences(ring, "symmetrySide(") == 1, "(c2) ringOffset does not read symmetrySide(");
    assert(countOccurrences(ring, "dot(") == 2 && countOccurrences(ring, "dot(offset, n)") == 2,
           "(c2) ringOffset keeps a dot( beyond the offset's normal component");
}

unittest { // (c4) ONE work-plane symmetry plane function, ONE call
    size_t scanned;
    const hits = filesWith("workplaneSymmetryPlane(", scanned);
    assert(scanned > 300, "(c4) floor: scanned " ~ scanned.to!string ~ " source files");
    assert(hits == ["source/toolpipe/stages/symmetry.d", "source/tools/create/pen.d"],
           "(c4) workplaneSymmetryPlane( outside the stage and the pen: " ~ hits.to!string);
    const pen = codeOf("source/tools/create/pen.d");   // the pen maps the plane once more
    assert(countOccurrences(pen, "workplaneSymmetryPlane(") == 1 &&
           countOccurrences(pen, "transformPoint(frame.toWorld, mirror_.planePoint)") == 1 &&
           countOccurrences(pen, "normalize(transformDir(frame.toWorld, mirror_.planeNormal))") == 1,
           "(c4) the pen does not read the stage's plane once, mapped by W once more");
    const st = codeOf("source/toolpipe/stages/symmetry.d");
    assert(countOccurrences(st, "workplaneSymmetryPlane(") == 2, "(c4) the stage does not define it and call it once");
    const ev = bodyAfter(st, "bool evaluate(ref VectorStack vts)");
    assert(ev.length > 400, "(c4) evaluate body not found");
    assert(countOccurrences(ev, "currentPlane(pkt.planePoint, pkt.planeNormal);") == 1,
           "(c4) evaluate does not publish currentPlane's plane");
    import std.regex : matchAll, regex;
    import std.range : walkLength;
    // Positive control: the needle sees an assignment spelt as the old body spelt it.
    assert(walkLength(matchAll("pkt.planePoint  = wp.center;", regex(`\bplane(Normal|Point)\s*=[^=]`))) == 1,
           "(c4) the assignment needle is blind");
    assert(walkLength(matchAll(ev, regex(`\bplane(Normal|Point)\s*=[^=]`))) == 0,
           "(c4) evaluate assigns the plane itself instead of reading currentPlane");
}

unittest { // (w1) an AUTO (view-turned) work plane maps the axis by the IDENTITY
    // (K-S3a, toolcards/interaction_layer/findings_K-S3.md, fixture
    // workplane_symmetry_auto_ks3.json): Right view axis X -> plane x = 0, partner
    // mx; Front view axis Y offset 0.3 -> plane y = 0.3, partner my+. Flag off
    // reads the same plane bit for bit. The published pair table names the partner.
    import math : Vec3, identityMatrix;
    import mesh : Mesh;
    import editmode : EditMode;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, SymmetryPacket, WorkplanePacket;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.stages.workplane : WorkplaneStage;

    struct Cell { string id; float[16] view; int axis; float offset; Vec3[] verts;
                  Vec3 autoN, lawN, lawP; int partner; }
    float[16] right = identityMatrix;     // camera back = +X
    right[0] = 0; right[8] = -1; right[2] = 1; right[10] = 0;
    const Cell[2] cells = [
        Cell("KS3_rgtX", right, 0, 0.0f,
             [Vec3(0.4f, 0.3f, 0.25f), Vec3(-0.4f, 0.3f, 0.25f), Vec3(0.4f, -0.3f, 0.25f),
              Vec3(0.4f, 0.3f, -0.25f), Vec3(-0.4f, -0.3f, 0.25f), Vec3(-0.4f, 0.3f, -0.25f)],
             Vec3(1, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 0), 1),
        Cell("KS3_fntY", identityMatrix, 1, 0.3f,
             [Vec3(0.25f, 0.4f, 0.45f), Vec3(0.25f, 0.2f, 0.45f), Vec3(0.25f, 0.4f, 0.15f),
              Vec3(0.25f, 0.4f, -1.05f), Vec3(0.25f, 0.4f, -0.45f), Vec3(0.25f, -1.0f, 0.45f)],
             Vec3(0, 0, 1), Vec3(0, 1, 0), Vec3(0, 0.3f, 0), 1),
    ];
    int rows;
    foreach (cell; cells) foreach (flag; [true, false]) {
        Mesh m;
        m.vertices = cell.verts.dup;
        m.resizeVertexSelection();
        Mesh* mp = &m;
        EditMode em = EditMode.Vertices;
        auto wp = new WorkplaneStage();
        auto sy = new SymmetryStage(() => mp, &em);
        sy.enabled = true;
        sy.useWorkplane = flag;
        sy.axisIndex = cell.axis;
        sy.offset = cell.offset;
        SubjectPacket subj;
        subj.viewport.view = cell.view;
        VectorStack vts;
        vts.put(&subj);
        assert(wp.evaluate(vts) && sy.evaluate(vts), "(w1) rig " ~ cell.id ~ ": the stages did not evaluate");
        // Positive control: the auto plane IS turned by the view (its permuted
        // basis would put the axis elsewhere).
        const w = vts.get!WorkplanePacket();
        assert(w.isAuto && w.normal == cell.autoN, "(w1) rig " ~ cell.id ~ ": auto plane normal " ~ v3(w.normal));
        const pk = vts.get!SymmetryPacket();
        const tag = cell.id ~ (flag ? "" : " flag off");
        assert(pk.planeNormal == cell.lawN && pk.planePoint == cell.lawP,
               "(w1) " ~ tag ~ ": plane " ~ v3(pk.planePoint) ~ " " ~ v3(pk.planeNormal)
               ~ ", law (world axis) " ~ v3(cell.lawP) ~ " " ~ v3(cell.lawN));
        assert(pk.pairOf.length == cell.verts.length && pk.pairOf[0] == cell.partner,
               "(w1) " ~ tag ~ ": v pairs with " ~ pk.pairOf.to!string ~ ", law partner " ~ cell.partner.to!string);
        Vec3 c, n;
        sy.currentPlane(c, n);
        assert(c == pk.planePoint && n == pk.planeNormal, "(w1) " ~ tag ~ ": currentPlane != the published plane");
        ++rows;
    }
    assert(rows == 4, "(w1) population");
}

unittest { // (w1e) an EMPTY mesh: no pair table is built, currentPlane still reads the applied plane
    import math : Vec3, identityMatrix;
    import mesh : Mesh;
    import editmode : EditMode;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, SymmetryPacket;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.stages.workplane : WorkplaneStage;

    Mesh empty;
    Mesh* mp = &empty;
    EditMode em = EditMode.Vertices;
    auto wp = new WorkplaneStage();
    wp.isAuto = false;
    wp.rotation = Vec3(0, 0, 30);         // a tilted plane: neither world XZ nor an axis plane
    wp.center = Vec3(0.5f, 0, 0);
    auto sy = new SymmetryStage(() => mp, &em);
    sy.enabled = true;
    sy.useWorkplane = true;
    SubjectPacket subj;
    subj.viewport.view = identityMatrix;
    VectorStack vts;
    vts.put(&subj);
    assert(wp.evaluate(vts) && sy.evaluate(vts), "(w1e) rig: the stages did not evaluate");
    const pk = vts.get!SymmetryPacket();
    // Positive control: the applied plane is NOT the world-XZ fallback.
    assert(pk.pairOf.length == 0 && pk.planeNormal != Vec3(0, 1, 0) && pk.planePoint == Vec3(0.5f, 0, 0),
           "(w1e) rig: applied " ~ v3(pk.planePoint) ~ " " ~ v3(pk.planeNormal));
    Vec3 c, n;
    sy.currentPlane(c, n);
    assert(c == pk.planePoint && n == pk.planeNormal,
           "(w1e) empty mesh: currentPlane " ~ v3(c) ~ " " ~ v3(n)
           ~ " != applied " ~ v3(pk.planePoint) ~ " " ~ v3(pk.planeNormal));
    // A reset is a fresh session: the record goes with it (the world basis until
    // the next pass: axis X maps to world X — K-S2's flag-off control's plane).
    sy.reset();
    sy.enabled = true;
    sy.useWorkplane = true;
    sy.currentPlane(c, n);
    assert(c == Vec3(0, 0, 0) && n == Vec3(1, 0, 0),
           "(w1e) after reset: currentPlane " ~ v3(c) ~ " " ~ v3(n) ~ ", expected world X");
}

unittest { // (w6) the plane maps the axis and the offset through W once (K-S2 S2z)
    import math : Vec3, identityMatrix;
    import mesh : Mesh;
    import editmode : EditMode;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, SymmetryPacket;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.stages.workplane : WorkplaneStage;

    Mesh empty;
    Mesh* mp = &empty;
    EditMode em = EditMode.Vertices;
    auto wp = new WorkplaneStage();
    wp.isAuto = false;
    wp.rotation = Vec3(30, 0, 40);
    wp.center = Vec3(0.5f, 0.2f, -0.3f);
    auto sy = new SymmetryStage(() => mp, &em);
    sy.enabled = true;
    sy.useWorkplane = true;
    sy.offset = 0.3f;
    SubjectPacket subj;
    subj.viewport.view = identityMatrix;
    const Vec3[3] lawN = [Vec3(0.766044f, 0.642788f, 0), Vec3(-0.55667f, 0.663414f, 0.5f),
                          Vec3(0.321394f, -0.383022f, 0.866025f)];
    int rows;
    foreach (ax; 0 .. 3) {
        sy.axisIndex = ax;
        VectorStack vts;
        vts.put(&subj);
        assert(wp.evaluate(vts) && sy.evaluate(vts), "(w6) rig: the stages did not evaluate");
        const pk = vts.get!SymmetryPacket();
        const Vec3 lawP = wp.center + lawN[ax] * 0.3f;
        assert(pk.axisIndex == -1, "(w6) axis " ~ ax.to!string ~ ": the packet's axisIndex is not -1 (an arbitrary plane)");
        assert((pk.planeNormal - lawN[ax]).length < 1e-5
               && (pk.planePoint - lawP).length < 1e-5,
               "(w6) axis " ~ ax.to!string ~ ": plane " ~ v3(pk.planePoint) ~ " " ~ v3(pk.planeNormal)
               ~ ", law " ~ v3(lawP) ~ " " ~ v3(lawN[ax]));
        Vec3 c, n;
        sy.currentPlane(c, n);
        assert(c == pk.planePoint && n == pk.planeNormal,
               "(w6) axis " ~ ax.to!string ~ ": currentPlane != the published plane");
        ++rows;
    }
    assert(rows == 3, "(w6) population");
}

unittest { // (w2) the walker's refusals: a disabled packet, a pair table or a
    // baseline of another length write nothing (a positive control writes).
    import math : Vec3;
    import mesh : Mesh;
    import toolpipe.packets : SymmetryPacket;
    import symmetry : applySymmetryMirror, applySymmetryMirrorDelta;
    Mesh m;
    m.vertices = [Vec3(1, 0, 0), Vec3(-0.5f, 0, 0), Vec3(0.2f, 1, 0)];   // 0 <-> 1, 2 on the plane
    m.resizeVertexSelection();
    SymmetryPacket sp;
    sp.enabled = true; sp.axisIndex = 0; sp.baseSide = +1;
    sp.pairOf = [1, 0, -1]; sp.onPlane = [false, false, true]; sp.vertSign = [1, -1, 0];
    const bool[] all = [true, true, true];
    const Vec3[] base = [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0)];
    bool[] touched = new bool[](3);
    const Vec3[] before = m.vertices.dup;
    // The delta control runs first: the plain family has suite witnesses of its own.
    Mesh dctl = m; dctl.vertices = m.vertices.dup;   // the delta walk: same projection, the edit mirrored
    applySymmetryMirrorDelta(&dctl, sp, base, all, touched);
    assert(dctl.vertices[1] == Vec3(-1, 0, 0) && dctl.vertices[2] == Vec3(0, 1, 0),
           "(w2) delta control: the walk did not mirror the edit and project the on-plane vertex");
    Mesh ctl = m; ctl.vertices = m.vertices.dup;
    applySymmetryMirror(&ctl, sp, all, touched);
    assert(ctl.vertices[1] == Vec3(-1, 0, 0) && ctl.vertices[2] == Vec3(0, 1, 0) && touched[1],
           "(w2) control: the enabled walk did not mirror the pair and project the on-plane vertex");
    auto off = sp; off.enabled = false;
    applySymmetryMirror(&m, off, all, touched);
    assert(m.vertices == before, "(w2) a disabled packet wrote");
    auto shortTable = sp; shortTable.pairOf = [1, 0];
    applySymmetryMirror(&m, shortTable, all, touched);
    assert(m.vertices == before, "(w2) a pair table of another length wrote");
    applySymmetryMirrorDelta(&m, sp, base ~ Vec3(0, 0, 0), all, touched);
    assert(m.vertices == before, "(w2) a baseline of another length wrote");
}

unittest { // (w3) both pairings classify a vertex inside epsilonWorld as on the plane
    import math : Vec3;
    import mesh : Mesh;
    import toolpipe.packets : SymmetryPacket;
    import symmetry : rebuildPairing, rebuildPairingTopological;
    Mesh m;
    m.vertices = [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(5e-5f, 1, 0)];
    m.addFace([0u, 1, 2]);
    SymmetryPacket sp;
    sp.enabled = true; sp.axisIndex = 0; sp.epsilonWorld = 1e-4f;
    int[] pairOf, vertSign; bool[] onPlane;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    assert(vertSign == [1, -1, 0] && onPlane == [false, false, true],
           "(w3) rebuildPairing: near-plane vertex not on the plane: " ~ vertSign.to!string);
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);
    assert(vertSign == [1, -1, 0] && onPlane == [false, false, true],
           "(w3) rebuildPairingTopological: near-plane vertex not on the plane: " ~ vertSign.to!string);
}

unittest { // (w4) a routed walk that stores announces ONE Maps change
    import math : Vec3;
    import mesh : Mesh, MapKind;
    import mesh_edit_delta : MeshEditScope;
    import toolpipe.packets : SymmetryPacket;
    import tools.transform.morph_route : MorphRoute, applySymmetryMirrorRouted,
                                         applySymmetryMirrorDeltaRouted;
    Mesh m;
    m.vertices = [Vec3(1, 0.5f, 0.25f), Vec3(-1, 0.5f, 0.25f)];
    m.resizeVertexSelection();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    MorphRoute route;
    route.kind = MapKind.morphRelative; route.name = "mm";
    route.base = m.vertices.dup; route.runPos = m.vertices.dup;
    SymmetryPacket sp;
    sp.enabled = true; sp.axisIndex = 0; sp.baseSide = +1;
    sp.pairOf = [1, 0]; sp.onPlane = [false, false]; sp.vertSign = [1, -1];
    bool[] touched = new bool[](2);
    m.undeliveredChanges_ = 0;
    applySymmetryMirrorRouted(&m, sp, [true, true], touched, route);
    assert(touched[1], "(w4) rig: the routed walk did not write the partner");
    assert((m.undeliveredChanges_ & MeshEditScope.Maps) != 0, "(w4) a routed store announced no Maps change");
    touched[] = false;
    m.undeliveredChanges_ = 0;
    applySymmetryMirrorDeltaRouted(&m, sp, route.base, [true, true], touched, route);
    assert(touched[1], "(w4) rig: the routed delta walk did not write the partner");
    assert((m.undeliveredChanges_ & MeshEditScope.Maps) != 0, "(w4) a routed delta store announced no Maps change");
}

unittest { // (w5) the routed POSITION walk stores the EXACT mirror of the drawn
    // driver, even when the partner's run position is not the driver's mirror
    // (the delta rule would keep the partner's own morph; this walk must not).
    import math : Vec3;
    import mesh : Mesh, MapKind;
    import mesh_morph : morphApply;
    import toolpipe.packets : SymmetryPacket;
    import symmetry : mirrorPosition;
    import tools.transform.morph_route : MorphRoute, applySymmetryMirrorRouted;
    Mesh m;
    m.vertices = [Vec3(1, 0.5f, 0.25f), Vec3(-1, 0.5f, 0.25f)];
    m.resizeVertexSelection();
    m.addMeshMapOfKind(MapKind.morphRelative, "mm");
    auto map = m.morphMapForWrite("mm");
    map.setEntry(1, Vec3(0, 0.3f, 0));   // the partner carries a morph of its own
    MorphRoute route;
    route.kind = MapKind.morphRelative; route.name = "mm";
    route.base = m.vertices.dup;
    route.runPos = [m.vertices[0], m.vertices[1] + Vec3(0, 0.3f, 0)];
    map.setEntry(0, Vec3(0, 0, 0.4f));   // the gesture moved the driver +Z 0.4
    SymmetryPacket sp;
    sp.enabled = true; sp.axisIndex = 0; sp.baseSide = +1;
    sp.planePoint = Vec3(0, 0, 0); sp.planeNormal = Vec3(1, 0, 0);
    sp.pairOf = [1, 0]; sp.onPlane = [false, false]; sp.vertSign = [1, -1];
    // Positive control: the fixture separates the rules — the partner's run
    // position is NOT the mirror of the driver's.
    assert(route.runPos[1] != mirrorPosition(sp, route.runPos[0]), "(w5) rig: a symmetric run");
    bool[] touched = new bool[](2);
    applySymmetryMirrorRouted(&m, sp, [true, true], touched, route);
    const Vec3 want = mirrorPosition(sp, Vec3(1, 0.5f, 0.65f));   // the drawn driver, mirrored
    Vec3 st;
    assert(touched[1] && m.morphValue("mm", 1, st), "(w5) rig: the partner was not written");
    const Vec3 got = morphApply(route.base[1], st, MapKind.morphRelative, 1.0f);
    assert(got == want, "(w5) routed position walk: partner drawn at " ~ v3(got)
           ~ ", expected the exact mirror " ~ v3(want));
}
