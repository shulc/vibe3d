// Task 9441 (HOV3): the element-pick law has ONE home, `hover_state` — the
// reach, the comparator and its edge-midpoint veto. Part 1 pins the
// comparator against the captured mixed-type rows (K-P P5*A) on its own
// inputs; part 2 is the production-text census: one comparator definition,
// the named call-site roster, no literal reach left in a picker, the deleted
// copies gone. The suite cells are tests/test_element_pick_law.d.
module tests.unit.element_pick_test;

import std.algorithm : canFind, sort;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : matchFirst, regex;
import std.string    : indexOf;

import hover_state : PickGather, cascadeClassWins, electElement, kCascadeVertex,
    kCascadeEdge, kCascadePolygon, kElementPickRadiusPx;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent,
    enclosingSymbols, isIdentChar, lineOf, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private PickGather gather(float v, float e, float mid, float poly) {
    PickGather g;
    g.vertex = v; g.edge = e; g.edgeMid = mid; g.polygon = poly;
    return g;
}

unittest { // the comparator, row by row (distances in px; inf = not gathered)
    enum inf = float.infinity;
    assert(kElementPickRadiusPx == 8.0f, "the element-pick reach is the captured 8 px");
    // Controls: one class alone takes the pick; nothing gathered takes none.
    assert(electElement(gather(7, inf, inf, inf)) == kCascadeVertex, "lone vertex");
    assert(electElement(gather(inf, inf, inf, 0)) == kCascadePolygon, "lone polygon");
    assert(electElement(gather(inf, inf, inf, inf)) == -1, "empty gather");
    // P5A: vertex 7, edge 3, midpoint 25 -> the vertex (tolerance 16).
    assert(electElement(gather(7, 3, 25, inf)) == kCascadeVertex,
           "P5A: a vertex inside its doubled tolerance beats a nearer edge");
    // P5bA: the vertex at 10 px is never gathered -> the edge.
    assert(electElement(gather(inf, 3, 25, inf)) == kCascadeEdge, "P5bA: the edge");
    // P5cA: the edge's midpoint 3 px, nearer than the vertex -> the edge.
    assert(electElement(gather(7, 3, 3, inf)) == kCascadeEdge,
           "P5cA: the edge-midpoint veto removes the vertex");
    // The veto's range is strict: a midpoint AT the reach vetoes nothing.
    assert(electElement(gather(9, 3, 8, inf)) == kCascadeVertex,
           "a midpoint at exactly the reach must not veto");
    // The cascade, not V > E > F: an edge AT the reach over a polygon under
    // the cursor trails it by the whole edge tolerance and loses.
    assert(electElement(gather(inf, 3, 25, 0)) == kCascadeEdge, "edge inside its tolerance");
    assert(electElement(gather(inf, 8, 25, 0)) == kCascadePolygon,
           "an edge at the reach loses to the polygon under the cursor");
    // ... while a vertex at the reach keeps its DOUBLED tolerance and wins.
    assert(electElement(gather(8, inf, inf, 0)) == kCascadeVertex,
           "a vertex at the reach beats the polygon under the cursor (tolerance 16)");
}

unittest { // clause 4 (inside its own tolerance -> win) is an early-out only for
           // non-negative distances; a guide may answer a negative one.
    bool[3]  has = [true, true, false];
    float[3] d   = [5.0f, -20.0f, 1e12f];
    assert(cascadeClassWins(kCascadeVertex, has, d, 16.0f),
           "a class inside its own tolerance wins even when another trails it negatively");
}

unittest { // production-text census
    size_t files;
    string[] cmpDefs, electSites;
    foreach (f; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++files;
        const rel = f.name[repoRoot.length + 1 .. $];
        const code = blankUnittestBodies(blankNonCode(readText(f.name)));
        const syms = enclosingSymbols(code);
        if (code.indexOf("bool cascadeClassWins(") >= 0) cmpDefs ~= rel;
        for (ptrdiff_t at = code.indexOf("electElement"); at >= 0;
             at = code.indexOf("electElement", at + 1)) {
            const e = at + "electElement".length;
            if ((at > 0 && isIdentChar(code[at - 1])) || code[e] != '(') continue;
            if (code[0 .. at].matchFirst(regex(`int\s+$`))) continue;   // its definition
            electSites ~= symbolAt(syms, lineOf(code, at) - 1);
        }
        foreach (gone; ["pressVertexVetoed", "kTopoPenPressPickNominalPx"])
            assert(countIdent(code, gone) == 0,
                   format("element-pick census: deleted copy `%s` is back in %s", gone, rel));
    }
    assert(files > 100, format("element-pick census: only %d source files scanned", files));

    // One comparator, in the law's home.
    assert(cmpDefs == ["source/hover_state.d"],
           format("element-pick census: comparator defined in %s", cmpDefs));

    // The comparator's call-site roster: the active-tool hover publish, the
    // polygon pen's hover-record stand-in (its merge, task 9503), the topology
    // pen's press pick (Duplicate and Remove press through it too) and its
    // background hover readout (task 9501).
    electSites.sort();
    assert(electSites.length == 4, format("element-pick census: %d call sites", electSites.length));
    assert(electSites == ["InputFrameState.publishHover", "PenTool.hoverHoldsEdge",
                          "resolveHoverTarget", "toolPressAt"],
           format("element-pick census: call-site roster changed: %s", electSites));

    // The pickers carry no reach of their own: two instantiations, no literal.
    const ifs = blankNonCode(readText(buildPath(repoRoot, "source/input_frame_state.d")));
    size_t inst;
    for (ptrdiff_t at = ifs.indexOf("pickHover!("); at >= 0; at = ifs.indexOf("pickHover!(", at + 1)) {
        ++inst;
        const close = ifs.indexOf(")", at);
        assert(!ifs[at .. close].matchFirst(regex(`[,(]\s*\d`)),
               "element-pick census: a pickHover instantiation carries a literal reach");
    }
    assert(inst == 2, format("element-pick census: %d pickHover instantiations", inst));
    assert(ifs.indexOf("gpuSelect.pick(sm, mx, my, cast(int)kElementPickRadiusPx,") >= 0,
           "element-pick census: pickHover no longer picks at the element-pick reach");
}

// Tool-press facing is source-aware and independent of ordinary click selection.
unittest {
    import hover_state : ToolPressSource, toolPressAt, toolPressEdgeAdmitted,
        toolPressVertexAdmitted, toolPressFaceAdmitted;
    import mesh : Mesh, makeGridPlane;
    import math : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix, projectToWindowFull;
    import std.math : round;
    import std.algorithm : reverse;
    auto vp = Viewport(lookAt(Vec3(0, 5, 0), Vec3(0, 0, 0), Vec3(0, 0, -1)),
        orthographicMatrix(1.5f, 1, 0.01f, 100), 600, 600, 0, 0, Vec3(0, 5, 0));
    vp.focus = Vec3(0, 0, 0);
    auto down = makeGridPlane(2); // geometric normal -Y
    auto up = makeGridPlane(2);
    foreach (ref f; up.faces) reverse(f);
    up.buildLoops();
    const ms = ModelSpace.world();
    const interior = down.edgeIndex(1, 4), border = down.edgeIndex(0, 1);
    assert(!toolPressFaceAdmitted(down, 0, ms, vp, true), "press-facing: back-facing face refused");
    assert(!toolPressEdgeAdmitted(down, interior, ms, vp, true), "press-facing: back-facing interior edge refused");
    assert(!toolPressVertexAdmitted(down, 4, ms, vp, true), "press-facing: back-facing interior vertex refused");
    assert(toolPressEdgeAdmitted(down, border, ms, vp, true), "press-border: boundary edge admitted");
    assert(toolPressVertexAdmitted(down, 0, ms, vp, true), "press-border: boundary vertex admitted");
    assert(toolPressEdgeAdmitted(up, interior, ms, vp, true) && toolPressVertexAdmitted(up, 4, ms, vp, true),
           "press-facing: reversed winding admits interior edge and vertex");
    int[2] at(Vec3 p) {
        float x, y, z;
        assert(projectToWindowFull(p, vp, x, y, z));
        return [cast(int)round(x), cast(int)round(y)];
    }
    const probes = [Vec3(0, 0, -0.5f), Vec3(0, 0, 0), Vec3(-0.5f, 0, -0.5f), Vec3(-0.5f, 0, -1)];
    const kinds = [kCascadeEdge, kCascadeVertex, kCascadePolygon, kCascadeEdge];
    size_t n;
    foreach (i, p; probes) {
        const xy = at(p);
        const refused = toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&down, ms)], true, true, true);
        assert(refused.kind == (i == 3 ? kCascadeEdge : -1), "press-query: back-facing interior contrast");
        const front = toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&up, ms)], true, true, true);
        assert(front.kind == kinds[i], "press-query: front-facing class contrast");
        const both = toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&down, ms)], false, true, true);
        assert(both.kind == kinds[i], "press-query: both-sides preference bypasses facing");
        const wire = toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&down, ms)], false, false, false);
        assert(wire.kind == (i == 2 ? -1 : kinds[i]), "press-query: wire admits components without polygon fill");
        ++n;
    }
    assert(n == 4, "press-query: four classes exercised");
    Mesh empty;
    const xy = at(probes[0]);
    const secondary = toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&empty, ms, 10), ToolPressSource(&up, ms, 20)], true, true, true);
    assert(secondary.kind == kCascadeEdge && secondary.source == 1 && secondary.owner.mesh is &up, "press-source: secondary foreground retains source identity");
    assert(toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&empty, ms, 10)], true, true, true).kind == -1,
           "press-source: excluded background is not queried");
    Mesh cover;
    cover.vertices = [Vec3(-2, 1, -2), Vec3(2, 1, -2), Vec3(2, 1, 2), Vec3(-2, 1, 2)];
    cover.faces = [cast(uint[])[0, 3, 2, 1]];
    cover.buildLoops();
    const centre = at(Vec3(0, 0, 0));
    const covered = [ToolPressSource(&cover, ms), ToolPressSource(&up, ms)];
    assert(toolPressAt(centre[0], centre[1], vp, covered, true, false, false).kind == kCascadeVertex,
           "press-occlusion: no depth policy admits a front vertex behind a surface");
    assert(toolPressAt(centre[0], centre[1], vp, covered, true, true, false).kind == -1,
           "press-occlusion: admitted foreground surface hides the lower vertex");
    reverse(cover.faces[0]); cover.buildLoops();
    const throughBack = toolPressAt(centre[0], centre[1], vp, covered, true, true, false);
    assert(throughBack.kind == kCascadeVertex && throughBack.owner.mesh is &up,
           "press-occlusion: cull facing before depth so the lower front candidate survives");
    up.resizeVertexSelection(); up.resizeEdgeSelection(); up.resizeFaceSelection();
    foreach (fi; 0 .. up.faces.length) up.setFaceHidden(fi, true);
    assert(up.countHiddenFaces() == 4, "press-hidden: all four faces are actually hidden");
    assert(!toolPressFaceAdmitted(up, 0, ms, vp, false) &&
           !toolPressEdgeAdmitted(up, interior, ms, vp, false) &&
           !toolPressVertexAdmitted(up, 4, ms, vp, false),
           "press-hidden: facing bypass does not admit hidden geometry");
    assert(toolPressAt(xy[0], xy[1], vp, [ToolPressSource(&up, ms)], false, false, true).kind == -1,
           "press-hidden: hidden source supplies no component or polygon candidate");
}

unittest {
    import hover_state : ToolPressSource, toolPressAt, toolPressSupport;
    import mesh : makeGridPlane;
    import math : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix;
    import std.algorithm : reverse;
    import core.time : MonoTime;
    import core.memory : GC;
    import std.stdio : writefln;
    auto m = makeGridPlane(64);
    foreach (ref f; m.faces) reverse(f);
    m.buildLoops();
    assert(m.vertices.length == 4225 && m.edges.length == 8320 && m.faces.length == 4096,
           "press-cost: nontrivial mesh population");
    auto vp = Viewport(lookAt(Vec3(0, 5, 0), Vec3(0, 0, 0), Vec3(0, 0, -1)),
        orthographicMatrix(1.5f, 1, 0.01f, 100), 600, 600, 0, 0, Vec3(0, 5, 0));
    const sources = [ToolPressSource(&m, ModelSpace.world())];
    const allocatedBefore = GC.stats().allocatedInCurrentThread;
    const support = toolPressSupport(m, ModelSpace.world(), vp);
    const supportBytes = GC.stats().allocatedInCurrentThread - allocatedBefore;
    assert(support.faces.length == 4096 && support.edges.length == 8320 && support.vertices.length == 4225,
        "press-cost: one populated linear source preparation");
    writefln("PRESS-SUPPORT faces=%s edges=%s vertices=%s allocated_bytes=%s",support.faces.length,support.edges.length,support.vertices.length,supportBytes);
    size_t n;
    const start = MonoTime.currTime;
    foreach (i; 0 .. 5) {
        const hit = toolPressAt(300 + i, 300, vp, sources, true, true, true);
        assert(hit.source == 0 && hit.kind >= 0, "press-cost: measured query must return a real candidate");
        ++n;
    }
    assert(n == 5, "press-cost: five queries timed");
    writefln("PRESS-COST faces=4096 vertices=4225 edges=8320 queries=%s elapsed_us=%s", n,
             (MonoTime.currTime - start).total!"usecs");
    const firstLoose = cast(uint)m.vertices.length;
    m.vertices ~= [Vec3(0,0,0),Vec3(0,0,.1)]; m.edges ~= [firstLoose,firstLoose+1];
    m.resizeFaceSelection(); m.setFaceSubpatch(0,true);
    const mixedBefore = GC.stats().allocatedInCurrentThread;
    const mixedSupport = toolPressSupport(m,ModelSpace.world(),vp);
    const mixedBytes = GC.stats().allocatedInCurrentThread - mixedBefore;
    assert(!mixedSupport.vertices[firstLoose] && !mixedSupport.edges[$-1] && !mixedSupport.faces[0],
        "press-cost: actual mixed loose/subpatch support population");
    const mixedStart=MonoTime.currTime;
    foreach(i;0..5) assert(toolPressAt(300+i,300,vp,[ToolPressSource(&m,ModelSpace.world())],true,true,true).kind>=0,
        "press-cost: five nonempty mixed queries");
    writefln("PRESS-MIXED faces=%s vertices=%s edges=%s queries=5 elapsed_us=%s support_allocated_bytes=%s",
        m.faces.length,m.vertices.length,m.edges.length,(MonoTime.currTime-mixedStart).total!"usecs",mixedBytes);

}

unittest {
    const app = blankNonCode(readText(buildPath(repoRoot, "source/app.d")));
    const input = blankNonCode(readText(buildPath(repoRoot, "source/input_frame_state.d")));
    const subject = blankNonCode(readText(buildPath(repoRoot, "source/toolpipe/subject.d")));
    const pen = blankNonCode(readText(buildPath(repoRoot, "source/tools/edit/topology_pen/tool.d")));
    assert(app.indexOf("toolPressSourcesResolver =") >= 0 && app.indexOf("document.foreground(layer)") >= 0,
           "press-wiring: application installs foreground query population");
    assert(input.indexOf("src.pickFacing = pickPolicy.facingTerm;") >= 0 &&
           input.indexOf("src.pickFacesDrawn = resolveDrawPlan(") >= 0,
           "press-wiring: event subject seeds actual cell facing and fill policy");
    assert(subject.indexOf("subj.pickFacing = src.pickFacing;") >= 0 &&
           subject.indexOf("subj.pickFacesDrawn = src.pickFacesDrawn;") >= 0,
           "press-wiring: one subject funnel carries both tool-press terms");
    assert(pen.indexOf("hit.owner.mesh !is mesh") >= 0,
           "press-authoring: a source-aware query cannot index another mesh into the bound primary");
    assert(pen.indexOf("pickOcclusionOf(vts), null, ToolQueryIntent.legacyHover)") >= 0 &&
           pen.indexOf("policy.legacy =") >= 0 && pen.indexOf("return legacyPressGather(") >= 0,
           "press-wiring: production hover intent and old subset provider are explicit");
    const query = blankNonCode(readText(buildPath(repoRoot, "source/hover_state.d")));
    assert(query.indexOf("subset = support[si]; prepared = true;") >= 0 &&
           query.indexOf("if (!prepared && policy.legacySource.mesh !is null)") >= 0,
           "press-preparation: an empty matched source is already prepared at the actual provider call");
    assert(pen.indexOf("layer.meshOrNull()") < 0 && app.indexOf("layer.meshOrNull()") >= 0,
           "press-wiring: actual foreground provider uses cage mesh sources");
    assert(pen.indexOf("other.source >= 0 && other.owner.mesh !is mesh") >= 0,
           "press-authoring: accepted secondary query cannot become empty-primary placement");
}

unittest {
    import std.string : count;
    const query=blankNonCode(readText(buildPath(repoRoot,"source/hover_state.d")));
    const pen=blankNonCode(readText(buildPath(repoRoot,"source/tools/edit/topology_pen/tool.d")));
    assert(query.count("toolPressCandidateWins(")==5,"tie-wiring: exactly four production comparisons and one declaration");
    foreach(needle;["toolPressCandidateWins(d, candidate, g.vertex, vertex)","toolPressCandidateWins(d, candidate, g.edge, edge)",
        "toolPressCandidateWins(old.distances.vertex, old.vertex, g.vertex, vertex)","toolPressCandidateWins(old.distances.edge, old.edge, g.edge, edge)",
        "aimSpace(vp, src.space)","projectToWindowFull(v, aim.vp, ix, iy, iz)","projectToWindowFull(m.vertices[e[0]], aim.vp, iax, iay, iaz)",
        "projectToWindowFull(m.vertices[e[1]], aim.vp, ibx, iby, ibz)","candidate.reductionMetric = dx * dx + dy * dy;",
        "candidate.reductionMetric = closestOnSegment2D(cast(float)mx, cast(float)my,"]) {
        assert(query.indexOf(needle)>=0,"tie-wiring: actual producer/query seam "~needle);
    }
    assert(pen.count("float* reductionMetric = null")==2 && pen.count("*reductionMetric = float.nan;")==2,
        "tie-wiring: both optional helper outputs retain explicit absence");
    foreach(needle;["*reductionMetric = bestD2;","*reductionMetric = bestD;","admitV, &vertexMetric)","admitE, &edgeMetric)",
        "primary.space.toWorldPoint(m.vertices[vi]), primary, vertexMetric)","primary.space.toWorldPoint(edgePoint), primary, edgeMetric)"]) {
        assert(pen.indexOf(needle)>=0,"tie-wiring: actual legacy metric transport "~needle);
    }
}
