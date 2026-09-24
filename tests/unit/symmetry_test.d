// Module unittests for `symmetry`, moved verbatim out of source/symmetry.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.symmetry_test;

import std.algorithm : sort, max;
import std.math      : abs;
import math : Vec3, dot;
import mesh : Mesh;
import toolpipe.packets : SymmetryPacket;
import std.conv : to;
import symmetry;


// mirrorEdgePoint (Edge Slice's mirrored chain): the image edge of (v0, v1) is
// (pairOf[v0], pairOf[v1]) when the images are joined, and there is none for
// an unjoined pair, a self-mirroring edge, an unpaired endpoint, or symmetry
// off; an on-plane endpoint is its own image. Hand-built X-symmetric mesh:
//   0 (1,0,0) <-> 2 (-1,0,0),  1 (2,0,0) <-> 3 (-2,0,0),  5 (1,0,1) <-> 6 (-1,0,1),
//   4 (0,0,0) on the plane,    7 (-1.5,0,1) unpaired.
// Faces [0,1,5], [3,2,7], [4,0,2]: (2,3) exists, (2,6) does not.
unittest {
    Mesh m;
    m.vertices = [Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(-1, 0, 0), Vec3(-2, 0, 0),
                  Vec3(0, 0, 0), Vec3(1, 0, 1), Vec3(-1, 0, 1), Vec3(-1.5f, 0, 1)];
    m.addFace([0u, 1, 5]);
    m.addFace([3u, 2, 7]);
    m.addFace([4u, 0, 2]);
    SymmetryPacket sp;
    sp.enabled = true;
    sp.axisIndex = 0;
    sp.pairOf  = [2, 3, 0, 1, -1, 6, 5, -1];
    sp.onPlane = [false, false, false, false, true, false, false, false];
    assert(m.edgeIndex(2, 3) != ~0u && m.edgeIndex(2, 6) == ~0u
           && m.edgeIndex(0, 2) != ~0u && m.edgeIndex(4, 0) != ~0u,
           "mirrorEdgePoint rig: the hand-built edges are not as drawn");
    uint m0, m1;
    // Joined images: the positive control, in the argument's own order.
    assert(mirrorEdgePoint(m, sp, 0, 1, m0, m1) && m0 == 2 && m1 == 3,
           "mirrorEdgePoint: joined images not found: " ~ m0.to!string ~ "," ~ m1.to!string);
    assert(mirrorEdgePoint(m, sp, 1, 0, m0, m1) && m0 == 3 && m1 == 2,
           "mirrorEdgePoint: reversed argument order not kept");
    // Unjoined images: (0,5) maps to (2,6), which is not an edge.
    assert(!mirrorEdgePoint(m, sp, 0, 5, m0, m1) && m0 == ~0u && m1 == ~0u,
           "mirrorEdgePoint: an unjoined image pair was reported as a mirror edge");
    // Self-mirror: (0,2) maps onto itself.
    assert(!mirrorEdgePoint(m, sp, 0, 2, m0, m1),
           "mirrorEdgePoint: a self-mirroring edge was reported as its own mirror");
    // On-plane endpoint: (4,0) — vertex 4 is its own image, so (4,2).
    assert(mirrorEdgePoint(m, sp, 4, 0, m0, m1) && m0 == 4 && m1 == 2,
           "mirrorEdgePoint: an edge with an on-plane endpoint was not mirrored onto (4,2): "
           ~ m0.to!string ~ "," ~ m1.to!string);
    // Unpaired endpoint off the plane: (2,7).
    assert(!mirrorEdgePoint(m, sp, 2, 7, m0, m1),
           "mirrorEdgePoint: an edge with an unpaired endpoint was mirrored");
    // Symmetry off.
    sp.enabled = false;
    assert(!mirrorEdgePoint(m, sp, 0, 1, m0, m1),
           "mirrorEdgePoint: symmetry off still mirrors");
}

// ===========================================================================
// Task 7144 — symmetry is a SELECTION-time rule; a transform writes only its
// operand, in ONE authoring frame; the authoring side A is one latch. Law:
// gap rows 315–319, 328–334, toolcards/symmetry_selection, doc/measured_laws.md
// §24a; behaviour witnesses tests/test_symmetry_selection_{time,doors}.d.
// Cells (u1)–(u8) of the S3b plan.
// ===========================================================================

version (unittest) {
    private SymmetryPacket xPacket(int[] pairOf, int[] vertSign, bool[] onPlane) {
        SymmetryPacket sp;
        sp.enabled = true;
        sp.axisIndex = 0;
        sp.planePoint = Vec3(0, 0, 0);
        sp.planeNormal = Vec3(1, 0, 0);
        sp.pairOf = pairOf;
        sp.vertSign = vertSign;
        sp.onPlane = onPlane;
        sp.baseSide = +1;
        return sp;
    }
    private bool near3(Vec3 a, Vec3 b, float eps = 1e-5f) {
        return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps && abs(a.z - b.z) <= eps;
    }
    private enum string kRepoRoot = () {
        import std.path : dirName;
        return dirName(dirName(dirName(__FILE_FULL_PATH__)));
    }();
    private string codeOf(string rel) {
        import std.file : readText;
        import std.path : buildPath;
        import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;
        return blankUnittestBodies(blankNonCode(readText(buildPath(kRepoRoot, rel))));
    }
    /// The balanced `{…}` body that follows the first `header` in `code`.
    private string bodyAfter(string code, string header) {
        import std.string : indexOf;
        import tests.unit.census_symbols : balancedSpan;
        const h = code.indexOf(header);
        if (h < 0) return "";
        const b = code.indexOf('{', h);
        if (b < 0) return "";
        return balancedSpan(code, cast(size_t)b, '{', '}');
    }
}

// (u1) THE PAIR WRITE RULE, as a table (`mirrorStepFor`). Seven rows; each
// names the step and whether the partner is written.
unittest {
    // 0 (+1) <-> 1 (-1) pair, 2 (+1) <-> 3 (-1) pair, 4 on the plane, 5 unpaired (+1).
    auto sp = xPacket([1, 0, 3, 2, -1, -1], [1, -1, 1, -1, 0, 1],
                      [false, false, false, false, true, false]);
    int rows;
    MirrorStep st;
    // on the plane → project
    st = mirrorStepFor(sp, [false, false, false, false, true, false], 4, false);
    assert(st.self == SelfStep.project && !st.copyToPartner, "(u1) on-plane: not projected"); ++rows;
    // +X member of a pair in the operand → own + copy
    st = mirrorStepFor(sp, [true, true, false, false, false, false], 0, false);
    assert(st.self == SelfStep.own && st.copyToPartner && st.partner == 1,
           "(u1) +X pair member does not drive the copy"); ++rows;
    // -X member of a pair in the operand → yield
    st = mirrorStepFor(sp, [true, true, false, false, false, false], 1, false);
    assert(st.self == SelfStep.yield && !st.copyToPartner, "(u1) -X pair member does not yield"); ++rows;
    // partner outside the operand → own, never written (gap 316)
    st = mirrorStepFor(sp, [false, false, true, false, false, false], 2, false);
    assert(st.self == SelfStep.own && !st.copyToPartner,
           "(u1) a partner outside the operand is written"); ++rows;
    // hidden partner in the operand → own, not written (task 0613 R3)
    st = mirrorStepFor(sp, [true, true, false, false, false, false], 0, true);
    assert(st.self == SelfStep.own && !st.copyToPartner, "(u1) a hidden partner is written"); ++rows;
    // unpaired → own
    st = mirrorStepFor(sp, [false, false, false, false, false, true], 5, false);
    assert(st.self == SelfStep.own && !st.copyToPartner, "(u1) unpaired vertex not own"); ++rows;
    // Symmetrize negative side (baseSide -1): the -X member drives
    auto neg = sp; neg.baseSide = -1;
    st = mirrorStepFor(neg, [true, true, false, false, false, false], 1, false);
    assert(st.self == SelfStep.own && st.copyToPartner && st.partner == 0,
           "(u1) baseSide -1: the -X member does not drive"); ++rows;
    assert(rows == 7, "(u1) row population changed");
}

// (u2) THE AUTHORING FRAME (`authored`): K(p) on A, M·K(M·p) off A.
unittest {
    import std.math : PI, sqrt;
    auto sp = xPacket([1, 0, -1], [1, -1, 0], [false, false, true]);
    sp.authoringSide = -1;
    Vec3 tr(Vec3 q) { return q + Vec3(0.4f, 0, 0); }
    Vec3 ry45(Vec3 q) {   // RY 45 about the origin, the capture's sign
        immutable float c = cast(float)(sqrt(0.5)), s = c;
        return Vec3(q.x * c + q.z * s, q.y, -q.x * s + q.z * c);
    }
    int rows;
    assert(near3(authored(sp, 0, Vec3(0.5f, 0.5f, 0.5f), &tr), Vec3(0.1f, 0.5f, 0.5f)),
           "(u2) +X off A: translate not conjugated"); ++rows;
    assert(near3(authored(sp, 0, Vec3(0.5f, 0.5f, 0.5f), &ry45), Vec3(0, 0.5f, 0.70710677f), 1e-4f),
           "(u2) +X off A: RY45 is not the conjugate (0,0.5,0.7071)"); ++rows;
    assert(near3(authored(sp, 1, Vec3(-0.5f, 0.5f, 0.5f), &tr), Vec3(-0.1f, 0.5f, 0.5f)),
           "(u2) -X on A: not K(p)"); ++rows;
    assert(near3(authored(sp, 2, Vec3(0, 0.5f, 0.5f), &tr), Vec3(0.4f, 0.5f, 0.5f)),
           "(u2) on-plane vertex: not K(p)"); ++rows;
    auto off = sp; off.enabled = false;
    assert(near3(authored(off, 0, Vec3(0.5f, 0.5f, 0.5f), &tr), Vec3(0.9f, 0.5f, 0.5f)),
           "(u2) symmetry off: not K(p)"); ++rows;
    assert(rows == 5, "(u2) row population changed");
}

// (u3) CENSUS of the mirror pass: each of the four pass bodies calls
// `mirrorStepFor(` exactly once and keeps no comparison of its own.
unittest {
    string[2][] bodies = [
        ["source/symmetry.d", "void applySymmetryMirror(Mesh* mesh,"],
        ["source/symmetry.d", "void applySymmetryMirrorDelta(Mesh* mesh,"],
        ["source/tools/transform/morph_route.d", "void applySymmetryMirrorRouted("],
        ["source/tools/transform/morph_route.d", "void applySymmetryMirrorDeltaRouted("],
    ];
    import tests.unit.census_symbols : countOccurrences;
    int found;
    foreach (b; bodies) {
        const body_ = bodyAfter(codeOf(b[0]), b[1]);
        assert(body_.length > 200, "(u3) body not found or trivially short: " ~ b[1]);
        ++found;
        assert(countOccurrences(body_, "mirrorStepFor(") == 1,
               "(u3) " ~ b[1] ~ " — mirrorStepFor( exactly 1 expected, got "
               ~ countOccurrences(body_, "mirrorStepFor(").to!string);
        foreach (tok; ["pairOf[", "vertSign[", "baseSide", "isVertexHidden"])
            assert(countOccurrences(body_, tok) == 0,
                   "(u3) " ~ b[1] ~ " keeps its own `" ~ tok ~ "` — the pair rule lives in mirrorStepFor");
    }
    assert(found == 4, "(u3) body population changed");
}

// (u4) CENSUS "a pair only at a pointer gesture".
unittest {
    import std.file : dirEntries, SpanMode;
    import std.algorithm : canFind, sort;
    import std.array : array;
    import std.path : buildPath;
    import tests.unit.census_symbols : countOccurrences;
    // (a) the three former pairing sites read no pair table.
    foreach (rel; ["source/commands/mesh/select.d", "source/symmetry_pick.d",
                   "source/commands/mesh/transform.d"])
        assert(countOccurrences(codeOf(rel), "pairOf[") == 0,
               "(u4)(a) pairOf[ in " ~ rel ~ ": "
               ~ countOccurrences(codeOf(rel), "pairOf[").to!string ~ ", expected 0");
    // (b) no command pairs (Symmetrize builds its own pair table).
    size_t n;
    bool sawElement, sawSelect;
    foreach (de; dirEntries(buildPath(kRepoRoot, "source/commands"), "*.d", SpanMode.depth)) {
        const rel = de.name[kRepoRoot.length + 1 .. $];
        if (rel == "source/commands/mesh/symmetrize.d") continue;
        ++n;
        if (rel == "source/commands/select/element.d") sawElement = true;
        if (rel == "source/commands/mesh/select.d") sawSelect = true;
        const code = codeOf(rel);
        foreach (tok; ["mirrorElement(", "symmetricSelect", "pairOf["])
            assert(countOccurrences(code, tok) == 0, "(u4)(b) a command pairs: `" ~ tok ~ "` in " ~ rel);
    }
    assert(n >= 18 && sawElement && sawSelect, "(u4)(b) census read " ~ n.to!string ~ " command files");
    // (c) `mirrorElement(` is called (outside its declaration) exactly in the
    // three pointer-gesture files — the set is EQUAL, not "at least".
    string[] callers;
    foreach (de; dirEntries(buildPath(kRepoRoot, "source"), "*.d", SpanMode.depth)) {
        const rel = de.name[kRepoRoot.length + 1 .. $];
        const code = codeOf(rel);
        size_t c = countOccurrences(code, "mirrorElement(");
        if (rel == "source/symmetry.d") c -= countOccurrences(code, "uint mirrorElement(");
        if (c > 0) callers ~= rel;
    }
    callers.sort();
    assert(callers == ["source/input_router.d", "source/symmetry_pick.d",
                       "source/tools/transform/xfrm_transform.d"],
           "(u4)(c) mirrorElement( callers: " ~ callers.to!string);
    // ...and each helper that holds such a call is itself CALLED at its
    // gesture: the double-click closure in the double-click branch, the
    // Element Move ring in the three `take*` picks.
    const ir = codeOf("source/input_router.d");
    assert(countOccurrences(ir, "closeSelectionUnderMirror(&app.mesh(), app.editMode);") == 1,
           "(u4)(c) the double-click branch does not close its result under the mirror");
    assert(countOccurrences(codeOf("source/tools/transform/xfrm_transform.d"), "= withMirrorElement(") == 3,
           "(u4)(c) the Element Move picks do not add the mirror element to the ring");
}

// (u5) SymmetryStage — the STATE of A: a base POINT, its side read against the
// current plane.
unittest {
    import operator : VectorStack;
    import toolpipe.pipeline : ToolPipeContext, resetToolSwitchTransientStages;
    import toolpipe.stages.symmetry : SymmetryStage;
    auto ctx = new ToolPipeContext;
    auto st = new SymmetryStage(null, null);
    ctx.pipeline.add(st);
    st.enabled = true;
    st.axisIndex = 0;
    int rows;
    VectorStack vts;
    st.evaluate(vts);
    assert(st.authoringSide() == -1 && vts.get!SymmetryPacket().authoringSide == -1,
           "(u5)(i) a fresh stage is not -X"); ++rows;
    st.placeAuthoringBase(Vec3(0.3f, 0.1f, 0));
    assert(st.authoringSide() == 1 && vts.get!SymmetryPacket().authoringSide == 1,
           "(u5)(ii) a +X placement is not published at once"); ++rows;
    st.placeAuthoringBase(Vec3(-0.3f, 0.1f, 0));
    assert(st.authoringSide() == -1, "(u5)(iii) a -X placement is not -1"); ++rows;
    st.placeAuthoringBase(Vec3(0, 0.1f, 0));
    assert(st.authoringSide() == -1, "(u5)(iv) a base ON the plane is not -1"); ++rows;
    st.placeAuthoringBase(Vec3(0.3f, 0, -0.2f));
    immutable int onX = st.authoringSide();
    st.axisIndex = 2;
    immutable int onZ = st.authoringSide();
    st.axisIndex = 0;
    assert(onX == 1 && onZ == -1 && st.authoringSide() == 1,
           "(u5)(v) the side is not the point against the current plane (a sign, not a point?)"); ++rows;
    st.placeAuthoringBase(Vec3(-0.3f, 0, 0));
    assert(st.authoringSide() == -1, "(u5)(vi) rig: the pre-state must be -X");
    st.enabled = false;
    st.placeAuthoringBase(Vec3(0.3f, 0, 0));
    st.enabled = true;
    st.evaluate(vts);
    assert(vts.get!SymmetryPacket().authoringSide == 1, "(u5)(vi) a placement with symmetry off was dropped"); ++rows;
    resetToolSwitchTransientStages(ctx.pipeline);
    st.evaluate(vts);
    assert(st.authoringSide() == 1, "(u5)(vii) tool-switch reset cleared the authoring side"); ++rows;
    st.reset();
    assert(st.authoringSide() == -1, "(u5)(viii) reset() did not unplace the base"); ++rows;
    assert(rows == 8, "(u5) row population changed");
}

// (u5b) ActionCenterStage — the EVENT of A.
unittest {
    import operator : VectorStack;
    import editmode : EditMode;
    import seltype : SelType;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.packets : ActionCenterPacket;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.stages.actcenter : ActionCenterStage;
    auto m = new Mesh;
    m.addVertex(Vec3( 0.5f, 0, 0));   // 0 +X
    m.addVertex(Vec3(-0.5f, 0, 0));   // 1 -X
    m.addVertex(Vec3( 0.5f, 1, 0));   // 2 +X
    m.addVertex(Vec3(-0.5f, 1, 0));   // 3 -X
    m.addFace([0u, 2u, 3u, 1u]);
    m.buildLoops();
    m.syncSelection();
    auto em = EditMode.Vertices;
    auto sy = new SymmetryStage(() => m, &em);
    auto ac = new ActionCenterStage(() => m, &em, null, () => SelType.Vertex);
    auto ctx = new ToolPipeContext;
    ctx.pipeline.add(sy);
    ctx.pipeline.add(ac);
    sy.enabled = true;
    sy.axisIndex = 0;
    auto saved = g_pipeCtx;
    g_pipeCtx = ctx;
    scope(exit) g_pipeCtx = saved;
    void only(int vi) { m.clearVertexSelection(); m.selectVertex(vi); }
    VectorStack eval() { VectorStack v; ctx.pipeline.evaluate(v); return v; }
    int rows;
    ac.mode = ActionCenterStage.Mode.Select;
    only(0);
    ac.notePlacement();
    eval();
    assert(sy.authoringSide() == 1, "(u5b)(i) a deferred placement at a +X centre is not +1"); ++rows;
    only(1);
    eval();
    assert(sy.authoringSide() == 1, "(u5b)(ii) an evaluation with no placement moved A"); ++rows;
    assert(ac.setAttr("mode", "origin"));
    assert(sy.authoringSide() == -1, "(u5b)(iii) switching the origin centre on did not latch -X at once"); ++rows;
    ac.notePlacementAt(Vec3(0.4f, 0, 0));
    assert(sy.authoringSide() == 1, "(u5b)(iv) an immediate placement is not +1"); ++rows;
    ac.notePlacement();
    ac.resetTransient();
    assert(!ac.placementPending(), "(u5b)(v) a tool drop left the deferred placement pending");
    eval();
    assert(sy.authoringSide() == 1, "(u5b)(v) a tool drop moved A"); ++rows;
    ac.mode = ActionCenterStage.Mode.Select;
    only(0);
    auto v1 = eval();
    const Vec3 c0 = v1.get!ActionCenterPacket().center;
    ac.notePlacement();
    auto v2 = eval();
    assert(v2.get!ActionCenterPacket().center == c0, "(u5b)(vi) placement changed the published pivot"); ++rows;
    only(1);
    ac.installPreparedMode(ActionCenterStage.Mode.Select, "select");
    assert(ac.placementPending(), "(u5b)(vii) a prepared ACEN mode did not note a placement");
    eval();
    assert(sy.authoringSide() == -1, "(u5b)(vii) a prepared ACEN mode did not latch the selection centre's side"); ++rows;
    // (viii) opponent R25 №1 — an eager W2 latches NOW, not at a later
    // evaluation under a later selection.
    only(0);
    assert(ac.setAttr("mode", "select"));
    only(1);
    eval();
    assert(sy.authoringSide() == 1, "(u5b)(viii) switching the selection centre on latched a later selection"); ++rows;
    // (ix) opponent R25 №2 — a user-locked centre does not keep a dropped
    // activation's deferred latch alive.
    ac.setUserMode("select");
    assert(ac.userLocked, "(u5b)(ix) rig: the centre is not user-locked");
    ac.notePlacement();
    ac.resetTransient();
    assert(!ac.placementPending(), "(u5b)(ix) the deferred placement survived a drop under a user lock"); ++rows;
    assert(rows == 9, "(u5b) row population changed");
}

// (u6) CENSUS of the WIRING — the production call sites, which (u2)/(u5)/(u5b)
// build their own collaborators for and cannot see.
unittest {
    import std.file : dirEntries, SpanMode;
    import std.path : buildPath;
    import std.string : indexOf, lastIndexOf;
    import std.algorithm : sort;
    import std.array : join;
    import tests.unit.census_symbols : countOccurrences, enclosingSymbols, symbolAt, lineOf,
                                       balancedSpan;
    // (a) the kernels: one `authored(` per loop.
    {
        const k = codeOf("source/tools/transform/xform_kernels.d");
        const ax = bodyAfter(k, "void applyXformMatrix(");
        const sc = bodyAfter(k, "void applyScaleFromActivation(");
        const mt = bodyAfter(codeOf("source/commands/mesh/transform.d"), "private bool applyKernel(");
        assert(ax.length > 200 && sc.length > 200 && mt.length > 200, "(u6)(a) a kernel body is missing");
        assert(countOccurrences(ax, "authored(") == 2, "(u6)(a) applyXformMatrix authored( count");
        assert(countOccurrences(sc, "authored(") == 1, "(u6)(a) applyScaleFromActivation authored( count");
        assert(countOccurrences(mt, "authored(") == 3, "(u6)(a) MeshTransform.applyKernel authored( count");
        // per loop: second `if (uniform) {` .. `goto tail;` and `goto tail;` .. `tail:`
        size_t u1 = ax.indexOf("if (uniform) {");
        size_t u2 = ax.indexOf("if (uniform) {", u1 + 1);
        size_t gt = ax.indexOf("goto tail;");
        size_t tl = ax.indexOf("tail:");
        assert(u2 != size_t.max && gt > u2 && tl > gt, "(u6)(a) loop markers not found");
        const uni = ax[u2 .. gt], per = ax[gt .. tl];
        assert(uni.length > 100 && per.length > 100, "(u6)(a) loop segments trivially short");
        assert(countOccurrences(uni, "authored(") == 1,
               "(u6)(a) authored( in the uniform loop: " ~ countOccurrences(uni, "authored(").to!string ~ ", expected 1");
        assert(countOccurrences(per, "authored(") == 1,
               "(u6)(a) authored( in the per-vertex loop: " ~ countOccurrences(per, "authored(").to!string ~ ", expected 1");
    }
    // (b) the live call: applyFold hands the kernel the drag packet.
    {
        const f = codeOf("source/tools/transform/xfrm_apply.d");
        const fold = bodyAfter(f, "void applyFold(");
        assert(fold.length > 200, "(u6)(b) applyFold body missing");
        assert(countOccurrences(fold, "applyXformMatrix(") == 1, "(u6)(b) applyFold must call the kernel once");
        const at = fold.indexOf("applyXformMatrix(");
        const args = balancedSpan(fold, fold.indexOf('(', at), '(', ')');
        assert(args.indexOf("dragSymmetry") >= 0 && args.indexOf("noSym") < 0,
               "(u6)(b) applyFold does not hand the kernel the drag packet: " ~ args);
        assert(countOccurrences(f, "noSym") == 0, "(u6)(b) noSym survives in xfrm_apply.d");
    }
    // (c) THE WRITERS OF A — exact, per enclosing symbol.
    {
        size_t files;
        int[string] got;
        string[] needles = ["placeAuthoringBase(", "notePlacementAt(", "notePlacement()",
                            "placeActionCentreOnInstall("];
        foreach (de; dirEntries(buildPath(kRepoRoot, "source"), "*.d", SpanMode.depth)) {
            const rel = de.name[kRepoRoot.length + 1 .. $];
            const code = codeOf(rel);
            ++files;
            string[] syms;
            foreach (nd; needles) {
                size_t from = 0;
                for (;;) {
                    const i = code.indexOf(nd, from);
                    if (i < 0) break;
                    from = i + nd.length;
                    // skip the declaration: `void name(`
                    const pre = code[(i >= 12 ? i - 12 : 0) .. i];
                    if (pre.indexOf("void ") >= 0) continue;
                    if (syms.length == 0) syms = enclosingSymbols(code);
                    const key = nd ~ " @ " ~ symbolAt(syms, lineOf(code, i) - 1);
                    got[key] = got.get(key, 0) + 1;
                }
            }
        }
        assert(files >= 500, "(u6)(c) census read " ~ files.to!string ~ " source files");
        int[string] want = [
            "placeAuthoringBase( @ ActionCenterStage.notePlacementAt": 1,
            "placeAuthoringBase( @ ActionCenterStage.evaluate": 1,
            "notePlacementAt( @ ActionCenterStage.applySetAttr": 2,
            "notePlacementAt( @ TransformTool.notePressPlacement": 1,
            "notePlacementAt( @ EdgeExtendTool.onMouseButtonDown": 1,
            "notePlacement() @ ActionCenterStage.installPreparedMode": 1,
            "notePlacement() @ PreparedXfrmActivationSessionOwner.installPost": 1,
            "notePlacement() @ XfrmTransformTool.resumeAfterForeignEdit": 1,
            "notePlacement() @ XfrmTransformTool.update": 1,
            "placeActionCentreOnInstall( @ XfrmTransformTool.prepareActivate": 1,
        ];
        string show(int[string] t) {
            string[] r;
            foreach (k, v; t) r ~= k ~ ": " ~ v.to!string;
            r.sort();
            return r.join("; ");
        }
        assert(got == want, "(u6)(c) authoring-side writers: " ~ show(got) ~ "\n  expected " ~ show(want));
        // The W3 sites: the placing branches, next to the relocate / pick pin.
        int[string] w3;
        foreach (rel; ["source/tools/transform/move.d", "source/tools/transform/rotate.d",
                       "source/tools/transform/scale.d", "source/tools/transform/xfrm_transform.d"]) {
            const code = codeOf(rel);
            auto syms = enclosingSymbols(code);
            size_t from = 0;
            for (;;) {
                const i = code.indexOf("notePressPlacement(", from);
                if (i < 0) break;
                from = i + 1;
                const pre = code[(i >= 12 ? i - 12 : 0) .. i];
                if (pre.indexOf("void ") >= 0) continue;
                const key = symbolAt(syms, lineOf(code, i) - 1);
                w3[key] = w3.get(key, 0) + 1;
            }
        }
        int[string] w3want = [
            "MoveTool.beginScreenPlaneDragAt": 1,
            "RotateTool.onMouseButtonDownWithResolvedAxis": 1,
            "ScaleTool.onMouseButtonDownWithResolvedAxis": 1,
            "XfrmTransformTool.writeElementAnchor": 1,
        ];
        assert(w3 == w3want, "(u6)(c) W3 press-placement sites: " ~ show(w3) ~ "\n  expected " ~ show(w3want));
        // Not writers, by construction: the legacy activate and the Edge
        // Extend arm owner.
        const xf = codeOf("source/tools/transform/xfrm_transform.d");
        const act = bodyAfter(xf, "override void activate()");
        assert(act.length > 100, "(u6)(c) XfrmTransformTool.activate body missing");
        foreach (tok; ["notePlacement", "placeActionCentreOnInstall"])
            assert(countOccurrences(act, tok) == 0, "(u6)(c) XfrmTransformTool.activate writes A: " ~ tok);
        assert(countOccurrences(codeOf("source/prepared_edge_extend_tool_activation.d"),
                                "placeActionCentreOnInstall(") == 0,
               "(u6)(c) the Edge Extend arm places the action centre");
        // W5b gates: Element mode and a preset-armed transform only.
        const upd = bodyAfter(xf, "override void update(ref VectorStack vts)");
        const w5 = upd.indexOf("notePlacement()");
        assert(w5 >= 0, "(u6)(c) W5b not in update");
        const gate = upd[(w5 >= 300 ? w5 - 300 : 0) .. w5];
        assert(gate.indexOf("Mode.Element") >= 0 && gate.indexOf("ownsActivationLatch_") >= 0,
               "(u6)(c) W5b lost its Element / preset-arm gate");
        // captureSymmetryForDrag copies A from the stage.
        const cap = bodyAfter(codeOf("source/tools/transform/transform.d"), "bool captureSymmetryForDrag(");
        // one statement: `dragSymmetry.authoringSide = st.authoringSide();`
        assert(countOccurrences(cap, "authoringSide") == 2,
               "(u6)(c) captureSymmetryForDrag: authoringSide " ~ countOccurrences(cap, "authoringSide").to!string ~ ", expected 2");
        // Edge Extend: the copy of A, no reset, no symmetry gate on W4.
        const ee = codeOf("source/tools/edit/edge_extend.d");
        assert(countOccurrences(ee, "symMirror_.pressSide = -1") == 0,
               "(u6)(c) edge_extend.d assigns symMirror_.pressSide = -1");
        assert(countOccurrences(ee, "liveAuthoringSide(") == 4,   // 3 calls + the declaration
               "(u6)(c) edge_extend.d liveAuthoringSide( count " ~ countOccurrences(ee, "liveAuthoringSide(").to!string);
        const npa = ee.indexOf("notePlacementAt(");
        const ifAt = ee[0 .. npa].lastIndexOf("if (offHandlePress");
        assert(ifAt >= 0, "(u6)(c) the W4 block is not under `if (offHandlePress`");
        const cond = balancedSpan(ee, ee.indexOf('(', ifAt), '(', ')');
        assert(cond.indexOf("symMirror_.enabled") < 0, "(u6)(c) the extend placement is gated on symmetry");
    }
    // (d) copy and check carry A.
    {
        const pk = bodyAfter(codeOf("source/toolpipe/packets.d"), "SymmetryPacket ownedDup()");
        assert(countOccurrences(pk, "authoringSide") == 2,   // `p.authoringSide = authoringSide;`
               "(u6)(d) ownedDup does not copy authoringSide");
        const xf = codeOf("source/tools/transform/xfrm_transform.d");
        assert(countOccurrences(bodyAfter(xf, "public bool preparedReplayMatches("), "authoringSide") >= 1,
               "(u6)(d) preparedReplayMatches ignores authoringSide");
        assert(countOccurrences(bodyAfter(xf, "public bool preparedRefireStateMatches("), "authoringSide") >= 1,
               "(u6)(d) preparedRefireStateMatches ignores authoringSide");
    }
    // (e) THE CONSUMER'S PLACE: after the base-side restriction, before
    // `pkt.isAuto`, and it writes nothing into `pkt`.
    {
        const ev = bodyAfter(codeOf("source/toolpipe/stages/actcenter.d"), "bool evaluate(ref VectorStack vts)");
        const r = ev.indexOf("restrictToBaseSide(");
        const c = ev.indexOf("if (placementPending_)");
        const a = ev.indexOf("pkt.isAuto");
        assert(r >= 0 && c > r && a > c, "(u6)(e) the placement consumer is not between the restriction and pkt.isAuto");
        const blk = balancedSpan(ev, ev.indexOf('{', c), '{', '}');
        assert(blk.length > 20 && blk.indexOf("pkt.center") >= 0, "(u6)(e) consumer block not found");
        // No WRITE into `pkt`: every `pkt.<field>` in the block is a read.
        for (size_t i = blk.indexOf("pkt."); i != size_t.max && i < blk.length;
             i = blk.indexOf("pkt.", i + 1)) {
            size_t j = i + 4;
            while (j < blk.length && (blk[j] == '_' || (blk[j] >= 'a' && blk[j] <= 'z')
                   || (blk[j] >= 'A' && blk[j] <= 'Z') || (blk[j] >= '0' && blk[j] <= '9') || blk[j] == '.')) ++j;
            while (j < blk.length && blk[j] == ' ') ++j;
            const bool writes = j < blk.length && (blk[j] == '=' && (j + 1 >= blk.length || blk[j + 1] != '='))
                             || (j + 1 < blk.length && blk[j + 1] == '=' && "+-*/~".indexOf(blk[j]) >= 0);
            assert(!writes, "(u6)(e) the placement consumer writes the pivot packet");
        }
    }
}

// (u7) the owned copy keeps A.
unittest {
    SymmetryPacket p;
    p.authoringSide = +1;
    assert(p.ownedDup().config == p.config, "(u7) ownedDup lost the config");
    assert(p.ownedDup().authoringSide == 1, "ownedDup dropped the authoring side");
}

// (u8) the production kernel `applyXformMatrix` in the authoring frame, both loops.
unittest {
    import math : AimViewport, Viewport, lookAt, perspectiveMatrix, aimSpace, ModelSpace;
    import std.math : PI;
    import toolpipe.packets : FalloffPacket, FalloffType;
    import tools.transform.transform : TransformTool;
    import tools.transform.xform_kernels : applyXformMatrix, BlendMode;
    Viewport vp;
    vp.view = lookAt(Vec3(0, 0, 5), Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width = 800; vp.height = 800;
    const AimViewport aim = aimSpace(vp, ModelSpace.world());
    float[16] T = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0.4f,0,0,1];
    auto sp = xPacket([1, 0], [1, -1], [false, false]);
    sp.authoringSide = -1;
    Vec3[] run(bool falloff, bool symOn) {
        auto m = new Mesh;
        m.vertices = [Vec3(0.5f, 0, 0), Vec3(-0.5f, 0, 0)];
        FalloffPacket f;
        if (falloff) { f.enabled = true; f.type = FalloffType.Selection; f.selectionWeights = [1.0f, 1.0f]; }
        auto s = sp; s.enabled = symOn;
        bool[] proc = [true, true];
        TransformTool.ClusterPivots cp; TransformTool.ClusterAxes ca;
        applyXformMatrix(m, [0, 1], [m.vertices[0], m.vertices[1]], Vec3(0, 0, 0), T,
                         Vec3(0, 0, 0), BlendMode.MatrixLerp, f, aim, cp, ca, null, s, proc);
        return m.vertices.dup;
    }
    int rows;
    auto a = run(false, true);
    assert(near3(a[0], Vec3(0.1f, 0, 0)) && near3(a[1], Vec3(-0.1f, 0, 0)),
           "(u8)(a) uniform loop not in the authoring frame: " ~ a.to!string); ++rows;
    auto b = run(true, true);
    assert(near3(b[0], Vec3(0.1f, 0, 0)) && near3(b[1], Vec3(-0.1f, 0, 0)),
           "(u8)(b) per-vertex loop not in the authoring frame: " ~ b.to!string); ++rows;
    auto c = run(false, false);
    assert(near3(c[0], Vec3(0.9f, 0, 0)) && near3(c[1], Vec3(-0.1f, 0, 0)),
           "(u8)(c) symmetry off is not K(p): " ~ c.to!string); ++rows;
    assert(rows == 3, "(u8) row population changed");
}
