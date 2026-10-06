// A registered snap guide that PROPOSES a position (task 9416, interaction-
// layer plan §9.14): the election offers it in the constraint tier, so an
// element in range wins over it, with no element it places and reports its
// type, and a guide proposing nothing leaves the answer the guide-less one.
// Then the pen's `LineGuide`: its lines by point count (the thresholds) and its
// two gates (`live`, the packet's type bits). DRUNTIME STOPS A MODULE AT ITS
// FIRST FAILING ASSERT — score mutations one at a time.
module tests.unit.snap_guide_registry_test;

import std.math : PI, round, sqrt;
import std.format : format;

import math : ModelSpace, Vec3, Viewport, lookAt, perspectiveMatrix, projectToWindowFull;
import mesh : Mesh;
import snap : SnapResult, invalidateSnapGrids, snapCursor;
import toolpipe.guide : GuideDrawState, SnapGuide;
import toolpipe.packets : SnapPacket, SnapType;
import tools.create.pen_geometry : LineGuide;

/// Proposes `at` (as `type`) when `on`; re-ranks nothing.
private final class FixedGuide : SnapGuide {
    bool on;
    Vec3 at;
    override bool propose(Vec3, int, int, const ref Viewport, const ref SnapPacket,
                 out Vec3 pos, out SnapType type) {
        pos = at; type = SnapType.StraightLine; return on;
    }
}

// A look down -Y onto y = 0 (slightly tilted), 800 px, ~80 px per metre.
private Viewport rigView() {
    Viewport vp;
    vp.eye    = Vec3(0, 5, 0.5f);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    return vp;
}

unittest { // the tier order of a proposed position
    Viewport vp = rigView();
    void pixelOf(Vec3 w, out int sx, out int sy) {
        float x, y, z;
        assert(projectToWindowFull(w, vp, x, y, z), "fixture: off-screen point");
        sx = cast(int)round(x); sy = cast(int)round(y);
    }
    float pix(Vec3 w, int sx, int sy) {
        float x, y, z;
        assert(projectToWindowFull(w, vp, x, y, z), "fixture: off-screen point");
        return sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy));
    }
    immutable Vec3 cur = Vec3(0, 0, 0), vert = Vec3(0.0625f, 0, 0), prop = Vec3(0, 0, 0.0375f);
    int sx, sy; pixelOf(cur, sx, sy);
    const dv = pix(vert, sx, sy), dp = pix(prop, sx, sy);
    assert(dv > 4.5f && dv < 5.5f && dp > 2.5f && dp < 3.5f,
        format("fixture: the element ~5 px, the proposal ~3 px (measured %s, %s)", dv, dp));

    SnapPacket cfg;
    cfg.enabled = true;
    cfg.enabledTypes = SnapType.Vertex;
    Mesh one, none;
    one.vertices = [vert];
    auto g = new FixedGuide;
    g.at = prop;

    // propose false: the answer is the guide-less one, field for field.
    invalidateSnapGrids();
    const bare = snapCursor(cur, sx, sy, vp, one, ModelSpace.world(), cfg);
    invalidateSnapGrids();
    const silent = snapCursor(cur, sx, sy, vp, one, ModelSpace.world(), cfg, null, null, [g]);
    assert(bare.snapped && bare.targetType == SnapType.Vertex && silent == bare,
        "a guide proposing nothing must leave the guide-less answer");
    invalidateSnapGrids();
    const bareEmpty = snapCursor(cur, sx, sy, vp, none, ModelSpace.world(), cfg);
    invalidateSnapGrids();
    const silentEmpty = snapCursor(cur, sx, sy, vp, none, ModelSpace.world(), cfg, null, null, [g]);
    assert(!bareEmpty.snapped && silentEmpty == bareEmpty,
        "with no element and a silent guide the query passes the point through");

    // An element 5 px away beats a proposal 3 px away (element > constraint).
    g.on = true;
    invalidateSnapGrids();
    const elem = snapCursor(cur, sx, sy, vp, one, ModelSpace.world(), cfg, null, null, [g]);
    assert(elem.snapped && elem.targetType == SnapType.Vertex &&
           elem.constraintType == SnapType.None && (elem.worldPos - vert).length < 1e-6f,
        format("the element in range must win over a nearer proposal: %s", elem));

    // No element: the proposal places and names its type.
    invalidateSnapGrids();
    const placed = snapCursor(cur, sx, sy, vp, none, ModelSpace.world(), cfg, null, null, [g]);
    assert(placed.snapped && placed.constraintType == SnapType.StraightLine &&
           placed.targetType == SnapType.None && (placed.worldPos - prop).length < 1e-6f,
        format("with no element the proposed point must place: %s", placed));

    // Every guide is asked with the ENUMERATION's rank: a higher-priority
    // guide that leaves the distance alone is not handed a lower one's answer.
    static final class FarRank : SnapGuide {
        override bool proximity(Vec3, SnapType, int, int, ref float d, ref int) { d = 1000; return true; }
    }
    static final class TopPassThrough : SnapGuide {
        override bool proximity(Vec3, SnapType, int, int, ref float, ref int p) { p = 5; return true; }
    }
    invalidateSnapGrids();
    const ranked = snapCursor(cur, sx, sy, vp, one, ModelSpace.world(), cfg, null, null,
                              [cast(SnapGuide)new FarRank, new TopPassThrough]);
    assert(ranked.snapped && ranked.targetType == SnapType.Vertex,
        format("the top guide's untouched distance is the enumeration's (5 px), not 1000: %s", ranked));

    // Beyond the inner range it does not place.
    g.at = Vec3(0, 0, 0.5f);
    assert(pix(g.at, sx, sy) > cfg.innerRangePx, "fixture: the far proposal is out of range");
    invalidateSnapGrids();
    const far = snapCursor(cur, sx, sy, vp, none, ModelSpace.world(), cfg, null, null, [g]);
    assert(!far.snapped, "a proposal beyond the inner range must not place");
    invalidateSnapGrids();
}

unittest { // the pen's LineGuide: lines by point count, its two gates
    size_t count(LineGuide g, SnapType t) {
        size_t n;
        foreach (l; g.lines) if (l.type == t) ++n;
        return n;
    }
    immutable Vec3 up = Vec3(0, 1, 0);
    // Points on y = 0; the dragged index is the last.
    immutable Vec3[] p4 = [Vec3(-0.6f, 0, 0.1f), Vec3(-0.1f, 0, 0.3f), Vec3(0.2f, 0, -0.3f),
                           Vec3(0.3f, 0, -0.6f)];
    auto g = new LineGuide;
    // n = 2: world axes through the one neighbour (X and Z; Y is the normal).
    g.aim(p4[0 .. 2], 1, up);
    assert(count(g, SnapType.WorldAxis) == 2 && g.lines.length == 2,
        format("2 points: world X / Z through the one neighbour only; got %s", g.lines));
    // n = 3: axes through prev and next, a right angle on each side, no line.
    g.aim(p4[0 .. 3], 2, up);
    assert(count(g, SnapType.WorldAxis) == 4 && count(g, SnapType.RightAngle) == 2 &&
           count(g, SnapType.StraightLine) == 0,
        format("3 points: 4 axes, 2 right angles, no straight line; got %s", g.lines));
    // n = 4: the straight line on each side too.
    g.aim(p4, 3, up);
    assert(count(g, SnapType.StraightLine) == 2 && count(g, SnapType.RightAngle) == 2 &&
           count(g, SnapType.WorldAxis) == 4,
        format("4 points: 2 lines, 2 right angles, 4 axes; got %s", g.lines));
    // A degenerate side (two coincident points) offers no line along it.
    g.aim([p4[0], p4[0], p4[2]], 2, up);
    assert(count(g, SnapType.RightAngle) == 0 && count(g, SnapType.WorldAxis) == 4,
        format("coincident p0 = p1 (both sides of p2 degenerate): no right angle, 4 axes; got %s",
               g.lines));
    foreach (l; g.lines)
        assert(l.dir.length > 0.99f && l.dir.length < 1.01f, format("a line without a direction: %s", l));
    g.aim(p4, 3, up);
    // The prev-side line runs through p2 along p2 - p1.
    assert((g.lines[0].origin - p4[2]).length < 1e-6f &&
           (g.lines[0].dir - (p4[2] - p4[1]) / (p4[2] - p4[1]).length).length < 1e-6f,
        format("the prev-side straight line: through p2 along p2 - p1; got %s", g.lines[0]));

    // The gates: `live` and the packet's bits.
    Viewport vp = rigView();
    SnapPacket cfg;
    cfg.enabled = true;
    cfg.enabledTypes = SnapType.StraightLine;
    float x, y, z;
    immutable Vec3 near = Vec3(0.41f, 0, -0.9f);   // close to the line through p2 along p2 - p1
    assert(projectToWindowFull(near, vp, x, y, z));
    const int sx = cast(int)round(x), sy = cast(int)round(y);
    Vec3 pos;
    SnapType t;
    g.live = true;
    assert(g.propose(near, sx, sy, vp, cfg, pos, t) && t == SnapType.StraightLine,
        "control: a live guide with its bit on proposes");
    g.live = false;
    assert(!g.propose(near, sx, sy, vp, cfg, pos, t), "a guide that is not live proposes nothing");
    g.live = true;
    cfg.enabledTypes = SnapType.Vertex;
    assert(!g.propose(near, sx, sy, vp, cfg, pos, t), "a guide whose bits are off proposes nothing");
}

unittest { // the pen's guide lifetime in its production text (signalling census)
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, blankNonCode, blankUnittestBodies, isIdentChar;
    size_t[] wordsAt(string code, string id) {
        size_t[] at;
        for (ptrdiff_t i = code.indexOf(id); i >= 0; i = code.indexOf(id, cast(size_t)i + 1)) {
            const size_t e = cast(size_t)i + id.length;
            if ((i == 0 || !isIdentChar(code[i - 1])) && (e >= code.length || !isIdentChar(code[e])))
                at ~= cast(size_t)i;
        }
        return at;
    }
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    const pen = blankUnittestBodies(blankNonCode(readText(buildPath(root, "source/tools/create/pen.d"))));
    string body(string decl) {
        const at = pen.indexOf(decl);
        assert(at >= 0, "declaration not found: " ~ decl);
        return balancedSpan(pen, pen.indexOf('{', at), '{', '}');
    }
    // Floor: the pen still has its drag arm and its guide field.
    assert(wordsAt(pen, "armDrag").length >= 3 && wordsAt(pen, "guide_").length >= 4,
        "census floor: pen.d's drag press and its guide");
    foreach (gone; ["applyPenGuide", "guideBits"])
        assert(wordsAt(pen, gone).length == 0, "pen.d names `" ~ gone ~ "` again");
    // One registration, inside the drag press; one removal, in endDragGuide,
    // which the release and the drop reach.
    assert(wordsAt(pen, "addGuide").length == 1 && wordsAt(body("void armDrag("), "addGuide").length == 1,
        "pen.d registers its guide outside the drag press");
    assert(wordsAt(pen, "removeGuide").length == 1 &&
           wordsAt(body("void endDragGuide("), "removeGuide").length == 1,
        "pen.d removes its guide outside endDragGuide");
    foreach (decl; ["bool onMouseButtonUp(", "void deactivate("])
        assert(wordsAt(body(decl), "endDragGuide").length == 1, decl ~ " does not end the drag's guide");
    // A switch mid-drag (no release) is the transition's: every arm clears
    // the registry in the prepared pipe activation's install, once.
    const pipe = blankUnittestBodies(blankNonCode(readText(buildPath(root,
        "source/prepared_pipe_activation.d"))));
    const at = pipe.indexOf("void install()");
    assert(at >= 0 && wordsAt(balancedSpan(pipe, pipe.indexOf('{', at), '{', '}'),
                              "installPreparedGuides").length == 1,
        "the prepared pipe activation no longer clears the guide registry at an arm");
    assert(wordsAt(pen, "installPreparedGuides").length == 0,
        "pen.d removes its guide on a switch again: the transition owns that");
}

unittest { // 9513: opposite purposes, both, and query-owned registry isolation
    import toolpipe.guide : SnapPurpose, SnapGuideScope, SnapQueryPolicy;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.stages.snap : SnapStage, liveSnapGuides;
    import tools.edit.topology_pen.snap_guide : PenSnapGuide;

    static class DeclaredGuide : SnapGuide {
        SnapPurpose declared;
        this(SnapPurpose p) { declared = p; }
        override SnapPurpose purpose() const nothrow @nogc { return declared; }
        override bool proximity(Vec3, SnapType, int, int, ref float, ref int) { return false; }
    }
    auto saved = g_pipeCtx;
    scope(exit) g_pipeCtx = saved;
    auto ctx = new ToolPipeContext;
    auto st = new SnapStage;
    ctx.pipeline.add(st);
    g_pipeCtx = ctx;
    auto placement = new DeclaredGuide(SnapPurpose.placement);
    auto weld = new DeclaredGuide(SnapPurpose.weld);
    auto both = new DeclaredGuide(SnapPurpose.both);
    st.addGuide(placement); st.addGuide(weld); st.addGuide(both);
    assert(st.guideCount == 3, "9513 registry fixture: three declared purposes");
    assert(liveSnapGuides(SnapQueryPolicy(SnapPurpose.placement, SnapGuideScope.registered)) ==
           [cast(SnapGuide)placement, both], "placement excludes weld and retains both");
    assert(liveSnapGuides(SnapQueryPolicy(SnapPurpose.weld, SnapGuideScope.registered)) ==
           [cast(SnapGuide)weld, both], "weld excludes placement and retains both");
    assert(liveSnapGuides(SnapQueryPolicy(SnapPurpose.both, SnapGuideScope.registered)) == st.guides(),
           "both-purpose query retains the complete registry in order");
    assert(liveSnapGuides(SnapQueryPolicy(SnapPurpose.weld, SnapGuideScope.queryOwned)) is null,
           "query-owned admission never receives registered vetoes");
    assert((new PenSnapGuide).purpose() == SnapPurpose.weld, "topology guide declares weld purpose");
    assert((new LineGuide).purpose() == SnapPurpose.placement, "polygon guide declares placement purpose");

    // Real election: client refusal precedes even a higher-ranked guide.
    static class OverrideGuide : SnapGuide {
        size_t asked;
        override bool proximity(Vec3, SnapType, int, int, ref float, ref int rank) {
            ++asked; rank = 100; return true;
        }
    }
    auto rank = new OverrideGuide;
    st.removeGuide(placement); st.removeGuide(weld); st.removeGuide(both);
    st.addGuide(rank);
    Viewport vp = rigView();
    Mesh m; m.vertices = [Vec3(0, 0, 0)];
    SnapPacket cfg; cfg.enabled = true; cfg.enabledTypes = SnapType.Vertex;
    float x, y, z;
    assert(projectToWindowFull(m.vertices[0], vp, x, y, z));
    invalidateSnapGrids();
    auto accepted = snapCursor(Vec3(0, 0, 0), cast(int)round(x), cast(int)round(y), vp, m,
        ModelSpace.world(), cfg, null, null,
        liveSnapGuides(SnapQueryPolicy(SnapPurpose.placement, SnapGuideScope.registered)));
    assert(accepted.snapped && rank.asked == 1, "control: registered rank guide reaches accepted vertex");
    rank.asked = 0;
    auto refused = snapCursor(Vec3(0, 0, 0), cast(int)round(x), cast(int)round(y), vp, m,
        ModelSpace.world(), cfg, null, (SnapType, int, int) => false,
        liveSnapGuides(SnapQueryPolicy(SnapPurpose.placement, SnapGuideScope.registered)));
    assert(!refused.snapped && rank.asked == 0, "client refusal precedes registered guide ranking");
}
