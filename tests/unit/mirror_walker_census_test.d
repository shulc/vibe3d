// Task 9410 — one mirror walker, one side test, overlay = applied plane.
// (c1) the pair rule `mirrorStepFor(` is called only by `walkMirrorPairs`, and
// the four mirror passes are walker callers with no loop of their own; (c2)
// the symmetry side test is `symmetrySide(` at every symmetry reader — Edge
// Extend keeps no `dot(` sign test; (c3) the viewport's symmetry overlay reads
// the stage's applied plane; (w1) that plane equals the published packet's
// under an auto work plane that a front view turns away from the stage basis;
// (w2) the walker's refusals; (w3) the pairings' epsilon side test; (w4) the
// routed walk's one change note.
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

unittest { // (c3) the overlay draws the applied plane
    const vr = codeOf("source/ui/viewport_render.d");
    const h = vr.indexOf("findByTask(TaskCode.Symm)");
    assert(h >= 0, "(c3) the overlay's symmetry stage lookup not found");
    const block = balancedSpan(vr, cast(size_t)vr.indexOf('{', h), '{', '}');
    assert(block.length > 200 && countOccurrences(block, "glDrawArrays(") == 1,
           "(c3) the overlay block not found");
    assert(countOccurrences(block, "sym.currentPlane(c, n);") == 1, "(c3) the overlay does not read currentPlane(");
    assert(countOccurrences(block, "perpendicularFrame(n, a1, a2);") == 1,
           "(c3) the overlay's lattice axes are not spanned from the applied normal");
    foreach (tok; ["useWorkplane", "currentBasis(", "axisIndex", ".offset", "WorkplaneStage"])
        assert(countOccurrences(block, tok) == 0,
               "(c3) the overlay derives its own plane: `" ~ tok ~ "` in its block");
}

unittest { // (w1) the applied plane == the published plane; the old overlay source is not
    import math : Vec3, Viewport, identityMatrix;
    import mesh : Mesh, makeCube;
    import editmode : EditMode;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, SymmetryPacket, WorkplanePacket;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.stages.workplane : WorkplaneStage;

    Mesh cube = makeCube();
    Mesh* mp = &cube;
    EditMode em = EditMode.Vertices;
    auto wp = new WorkplaneStage();      // auto: a front view turns it to Z
    auto sy = new SymmetryStage(() => mp, &em);
    sy.enabled = true;
    sy.useWorkplane = true;

    SubjectPacket subj;
    subj.viewport.view = identityMatrix;  // camera back = +Z: a front view
    VectorStack vts;
    vts.put(&subj);
    assert(wp.evaluate(vts) && sy.evaluate(vts), "(w1) rig: the stages did not evaluate");
    const pk = vts.get!SymmetryPacket();
    Vec3 basisN, a1, a2;
    wp.currentBasis(basisN, a1, a2);
    // Positive control: the fixture exhibits the phenomenon — the stage basis
    // the overlay used to read is NOT the plane the packet applies.
    assert(pk.planeNormal == Vec3(0, 0, 1) && basisN == Vec3(0, 1, 0),
           "(w1) rig: packet normal " ~ v3(pk.planeNormal) ~ " vs basis " ~ v3(basisN));
    Vec3 c, n;
    sy.currentPlane(c, n);
    assert(c == pk.planePoint && n == pk.planeNormal,
           "(w1) workplane: overlay plane " ~ v3(n) ~ " != applied " ~ v3(pk.planeNormal));

    // Axis mode is read from the config: an axis change before the next
    // evaluation is drawn at once (the published packet still holds the old one).
    sy.useWorkplane = false;
    sy.axisIndex = 1;
    sy.offset = 0.25f;
    sy.currentPlane(c, n);
    assert(n == Vec3(0, 1, 0) && c == Vec3(0, 0.25f, 0),
           "(w1) axis Y offset 0.25: overlay plane " ~ v3(c) ~ " " ~ v3(n));
    VectorStack vts2;
    vts2.put(&subj);
    assert(wp.evaluate(vts2) && sy.evaluate(vts2), "(w1) rig: second evaluation");
    const pk2 = vts2.get!SymmetryPacket();
    assert(c == pk2.planePoint && n == pk2.planeNormal, "(w1) axis: overlay plane != applied plane");
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
    import tools.transform.morph_route : MorphRoute, applySymmetryMirrorRouted;
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
}
