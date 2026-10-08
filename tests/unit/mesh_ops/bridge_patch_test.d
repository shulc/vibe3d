module tests.unit.mesh_ops.bridge_patch_test;
import mesh;
import math;
import mesh_ops.bridge;
import mesh_ops.bridge_patch;
import tools.edit.bridge_tool : applyBridgeOp, BridgeParams, resolveBridgeSelection;
import editmode : EditMode;
import std.json;
import std.file : readText;
import std.math : fabs;
import std.string : indexOf, replace;
private string noSpace(string s) {return s.replace(" ","").replace("\n","").replace("\t","");}
import std.conv : to;

private double num(JSONValue v)
{
    return v.type == JSONType.float_ ? v.floating : cast(double) v.integer;
}

private Vec3d vec(JSONValue v)
{
    return Vec3d(num(v[0]), num(v[1]), num(v[2]));
}

private uint[] ids(JSONValue v)
{
    uint[] r;
    foreach (x; v.array)
        r ~= cast(uint) x.integer;
    return r;
}

private void close(Vec3d a, Vec3d b, string msg, double tol = 1e-12)
{
    foreach (i; 0 .. 3)
        assert(fabs(a.v[i] - b.v[i]) <= tol,
                msg ~ " actual=" ~ a.v.to!string ~ " expected=" ~ b.v.to!string);
}

private uint bits(float f)
{
    import core.stdc.string : memcpy;

    uint b;
    memcpy(&b, &f, 4);
    return b;
}

unittest
{
    auto fixture = parseJSON(
            readText("tests/fixtures/bridge_auto_connection/tangent_witnesses.json"));
    assert(fixture["records"].array.length == 24, "typed population 24");
    size_t fits, groups, smooth, curve;
    foreach (w; fixture["records"].array)
    {
        auto p = vec(w["A"]), q = vec(w["B"]);
        auto fit = railFit(p, q, vec(w["a"]), vec(w["b"]), num(w["tau"]),
                w["kind"].str == "group_adjustment" ? 2 : w["mode"].str == "smooth" ? 2 : 1);
        auto t1 = ((q - p) * 3 - fit[1] * 2) - fit[2];
        if (w["kind"].str == "rail_fit")
        {
            ++fits;
            if (w["mode"].str == "smooth")
                ++smooth;
            else
                ++curve;
            close(fit[1], vec(w["captured_T0"]), "captured rail T0");
            close(t1, vec(w["captured_T1"]), "captured rail T1");
        }
        else
        {
            ++groups;
            assert(w["kind"].str == "group_adjustment", "typed kind");
            assert(w["static_prediction"]["provenance"].str == "static-law",
                    "group fallback provenance");
            close(fit[1], vec(w["captured_direction_A"]), "group adjusted captured direction A");
            close(t1, vec(w["captured_direction_B"]), "group adjusted captured direction B");
            close(fit[1], vec(w["static_prediction"]["T0"]),
                    "static-law centroid chord fallback T0");
            close(t1, vec(w["static_prediction"]["T1"]), "static-law centroid chord fallback T1");
        }
    }
    assert(fits == 23 && groups == 1 && smooth == 19 && curve == 4, "typed floors 23/1/19/4");
}

unittest
{
    auto overlay = parseJSON(
            readText("tests/fixtures/bridge_auto_connection/ours_smooth_expected.json"));
    auto rig = overlay["rig"];
    Mesh m;
    foreach (p; rig["points"].array)
        m.addVertex(vec(p).stored());
    foreach (f; rig["faces"].array)
        m.addFace(ids(f));
    m.buildLoops();
    m.edgeMarks.length = m.edges.length;
    m.edgeSelectionOrder.length = m.edges.length;
    BridgeGroup[] gs;
    foreach (group; rig["groups"].array)
    {
        BridgeGroup g;
        foreach (e; group.array)
            g ~= BridgeNode(cast(uint) e["v0"].integer,
                    cast(uint) e["v1"].integer, cast(int) e["face"].integer);
        gs ~= g;
    }
    auto adjusted = adjustedGroupDirections(m, gs);
    foreach (i; 0 .. 2)
        close(adjusted[i], vec(rig["adjusted_directions"][i]),
                "independent adjusted rig direction");
    foreach (i; 0 .. 2)
    {
        auto n = m.faceNormal(cast(uint) i);
        auto expected = vec(rig["normals"][i]).stored();
        assert(n == expected, "independent OURS Newell normal");
    }
    size_t residual, positionDifference;
    foreach (w; rig["rails"].array)
    {
        size_t i = cast(size_t) w["index"].integer;
        auto a = groupNodes(gs[0]), b = groupNodes(gs[1]);
        auto p = Vec3d(m.vertices[a[i]]), q = Vec3d(m.vertices[b[i]]);
        auto ds = smoothSourceDirections(m, gs, i, unitD(q - p), adjusted);
        foreach (j; 0 .. 2)
        {
            close(ds[j], vec(w["directions"][j]), "independent OURS indexed/averaged direction");
            if (lengthD(ds[j] - vec(w["triangle_directions"][j])) > 1e-6)
                ++residual;
        }
        auto fit = railFit(p, q, ds[0], ds[1], 1, 2);
        auto v = evalSpline([fit], .5).stored();
        uint[3] actual = [bits(v.x), bits(v.y), bits(v.z)], expected;
        foreach (j; 0 .. 3)
            expected[j] = cast(uint) w["position_bits"][j].integer;
        assert(actual == expected, "independent nonplanar OURS position bits");
        foreach (j; 0 .. 3)
            if (expected[j] != w["triangle_position_bits"][j].integer)
                ++positionDifference;
    }
    assert(residual >= 1 && positionDifference >= 1,
            "nonplanar direction/position discriminator population");
    // Collinear leading triangle and tiny/degenerate polygons use our same seam.
    Mesh n;
    foreach (p; [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(2, 1, 0),
            Vec3(0, 1, 0)
        ])
        n.addVertex(p);
    n.addFace([0u, 1u, 2u, 3u, 4u]);
    n.addFace([0u, 1u, 2u]);
    assert(n.faceNormal(0) == Vec3(0, 0, 1), "collinear leading triple Newell");
    assert(n.faceNormal(1) == Vec3(0, 1, 0), "degenerate fallback");
    Mesh tiny;
    foreach (p; [Vec3(0, 0, 0), Vec3(1e-5f, 0, 0), Vec3(0, 1e-5f, 0)])
        tiny.addVertex(p);
    tiny.addFace([0u, 1u, 2u]);
    assert(tiny.faceNormal(0) == Vec3(0, 1, 0), "tiny fallback");
    assert(readText("source/mesh_ops/bridge_patch.d")
            .indexOf("m.faceNormal(owner)") >= 0, "production normal seam census");
    assert(noSpace(readText("source/mesh_ops/bridge.d"))
            .indexOf("smoothSourceDirections(ed.mesh,groups,i,chord,adjusted)") >= 0,
            "production Smooth wiring census");
}

unittest
{
    assert(effectiveSegments(7, true, true, [[0u, 1u, 2u], [3u, 4u, 5u]]) == 2,
            "auto natural segments");
    assert(effectiveSegments(7, true, false, [[0u, 1u, 2u], [3u, 4u, 5u]]) == 7,
            "static-law autoStep false requested");
    assert(effectiveSegments(-2, false, true, []) == 1, "requested floor");
    assert(effectiveSegments(int.max, false, true, []) == 512, "requested hard cap");
    assert(effectiveSegments(7, true, true, [[0u, 1u], [2u, 3u, 4u]]) == 7, "unequal side fallback");
    uint[] side = [19, 17, 15, 13, 11, 9];
    assert(borrowedId(side, .2) == 17, "borrowed trunc discriminator");
    assert(borrowedId(side, .25) == 17 && borrowedId(side, .5) == 13
            && borrowedId(side, .75) == 11, "borrowed quarters");
    auto spline = cardinalCoefficients([
        Vec3d(0, 0, 0), Vec3d(1, 0, 1), Vec3d(4, 0, 0)
    ]);
    // Off-knot static-law predictions computed independently by the accepted spec.
    close(evalSpline(spline, .25), Vec3d(.39887287570313157, 0,
            .6783813728906053), "static-law ghost quarter", 1e-12);
    close(evalSpline(spline, .75), Vec3d(2.2393470724001348, 0,
            .7606529275998649), "static-law ghost three-quarter", 1e-12);
    auto linear = railFit(Vec3d(1, 2, 3), Vec3d(3, 4, 5), Vec3d.init, Vec3d.init, 0, 0);
    close(evalSpline([linear], .5), Vec3d(2, 3, 4), "linear exact lerp");
}

unittest
{
    // Two open chains ring existing faces via unselected closing edges.
    Mesh m;
    foreach (p; [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 0, 1),
            Vec3(1, 0, 1), Vec3(1, 1, 1)
        ])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u]);
    m.addFace([3u, 4u, 5u]);
    m.buildLoops();
    m.edgeMarks.length = m.edges.length;
    m.edgeSelectionOrder.length = m.edges.length;
    foreach (ei, e; m.edges)
        if (edgeKey(e[0], e[1]) == edgeKey(0, 1) || edgeKey(e[0],
                e[1]) == edgeKey(1, 2) || edgeKey(e[0], e[1]) == edgeKey(3, 4)
                || edgeKey(e[0], e[1]) == edgeKey(4, 5))
            m.selectEdge(cast(int) ei);
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid && sel.openRows && sel.capFaces.length == 2,
            "pathological cap lookup population");
    BridgeParams p;
    p.connect = false;
    auto before = m.faces.dup;
    auto result = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p, true);
    assert(result.added == 2 && !result.removed && m.faces.length == 4,
            "openRows remove guard preserves ringed caps");
    foreach (i; 0 .. 2)
        assert(m.faces[i] == before[i], "pathological caps unchanged");
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, BridgeParams(1, 1.0f), true);
    assert(r.added == 0, "open twist refusal");
}

unittest
{
    // Trace first eligible incidence edge, target before degree check, no backtracking.
    BridgeIncidence inc;
    inc.neighbors = [
        [1u, 2u, 3u], [0u, 4u, 5u], [0u, 4u, 5u], [0u], [1u, 2u], [1u, 2u]
    ];
    foreach (e; [
            [0u, 1u], [0u, 2u], [0u, 3u], [1u, 4u], [1u, 5u], [2u, 4u], [2u, 5u]
        ])
        inc.owners[edgeKey(e[0], e[1])] = [0];
    inc.selected[edgeKey(0, 3)] = true;
    assert(traceSide(0, 4, inc) == [0u, 1u, 4u],
            "trace first eligible and target degree precedence");
    assert(traceSide(0, 2, inc).length == 0, "trace intermediate low degree refuses");
    BridgeIncidence cycle;
    cycle.neighbors = [
        [1u, 2u, 3u], [0u, 2u, 3u], [1u, 0u, 3u], [0u, 1u, 2u], []
    ];
    foreach (e; [[0u, 1u], [1u, 2u], [2u, 0u]])
        cycle.owners[edgeKey(e[0], e[1])] = [0];
    assert(traceSide(0, 4, cycle).length == 0, "trace repeated vertex refuses");
    assert(traceSide(3, 0, inc).length == 0, "trace initial low degree refuses");
    // Distance fallback genuine tie retains direction; parity toggles reversal.
    Mesh m;
    foreach (p; [Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(0, -1, 0), Vec3(0, 1, 0)])
        m.addVertex(p);
    BridgeGroup[] groups = [[BridgeNode(0, 1, -1)], [BridgeNode(2, 3, -1)]];
    BridgeIncidence empty;
    empty.neighbors.length = 4;
    assert(!adjustOpenChains(m, groups, empty), "distance fallback tie retains B");
    assert(groupNodes(groups[1]) == [2u, 3u], "fallback tie ordering");
    assert(adjustOpenChains(m, groups, empty, -1), "signed odd parity reverses B");
    assert(groupNodes(groups[1]) == [3u, 2u], "parity edge ownership reversal");
}

unittest
{
    auto corpus = parseJSON(readText("tests/fixtures/bridge_auto_connection/frozen.json"));
    JSONValue cell;
    foreach (c; corpus["cases"].array)
        if (c["case"].str == "S03")
            cell = c;
    auto inp = cell["input"];
    Mesh m;
    foreach (p; inp["vertices"].array)
        m.addVertex(vec(p).stored());
    foreach (f; inp["faces"].array)
        m.addFace(ids(f));
    m.buildLoops();
    m.edgeMarks.length = m.edges.length;
    m.edgeSelectionOrder.length = m.edges.length;
    foreach (e; inp["selection_packet_order"]["edges"].array)
        foreach (ei, edge; m.edges)
            if (edgeKey(edge[0], edge[1]) == edgeKey(cast(uint) e[0].integer,
                    cast(uint) e[1].integer))
                m.selectEdge(cast(int) ei);
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    auto inc = bridgeIncidence(m, [sel.loopA, sel.loopB]);
    auto gs = reseedOpenChains(m, [sel.loopA, sel.loopB], inc);
    adjustOpenChains(m, gs, inc);
    auto directions = curveSourceDirections(m, gs);
    close(directions[0], Vec3d(-.36859759092330935, 0, -.4392768099904061),
            "captured Curve centroid direction");
    assert(noSpace(readText("source/mesh_ops/bridge.d")).indexOf("curveSourceDirections(ed.mesh,groups)") >= 0,
            "production Curve direction wiring census");
}
unittest {
    // K1 flip semantics on multiple strips must reverse each baseline quad.
    Mesh base;foreach(p;[Vec3(0,0,0),Vec3(1,0,0),Vec3(2,0,0),Vec3(0,0,2),Vec3(1,0,2),Vec3(2,0,2)])base.addVertex(p);
    auto a=[0u,1u,2u],b=[3u,4u,5u];
    import snapshot:MeshSnapshot;Mesh plain,flipped;auto snap=MeshSnapshot.capture(base);snap.restore(plain);snap.restore(flipped);BridgeParams p;p.segments=3;p.connect=false;
    auto r0=applyBridgeOp(plain,a,b,[],p,true);p.flip=true;auto r1=applyBridgeOp(flipped,a,b,[],p,true);
    assert(r0.added==6 && r1.added==6,"open flip population six quads");
    foreach(i;0..plain.faces.length){auto expected=plain.faces[i].dup;import std.algorithm:reverse;reverse(expected[1..$]);assert(flipped.faces[i]==expected,"open multi-span exact quad reversal");}
}
