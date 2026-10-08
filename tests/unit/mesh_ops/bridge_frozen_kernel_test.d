module tests.unit.mesh_ops.bridge_frozen_kernel_test;
import mesh;
import math;
import tools.edit.bridge_tool : BridgeParams, BridgeMode, applyBridgeOp, resolveBridgeSelection;
import editmode : EditMode;
import std.json;
import std.file : readText;
import std.conv : to;
import std.algorithm : sort, canFind;

private uint bits(float f)
{
    import core.stdc.string : memcpy;

    uint b;
    memcpy(&b, &f, 4);
    return b;
}

private double number(JSONValue v)
{
    return v.type == JSONType.float_ ? v.floating : cast(double) v.integer;
}

private uint[] ring(JSONValue v)
{
    uint[] r;
    foreach (x; v.array)
        r ~= cast(uint) x.integer;
    return r;
}

private bool cyclic(const(uint)[] a, const(uint)[] b)
{
    if (a.length != b.length)
        return false;
    foreach (k; 0 .. a.length)
    {
        bool equal = true;
        foreach (i; 0 .. a.length)
            if (a[i] != b[(i + k) % b.length])
                equal = false;
        if (equal)
            return true;
    }
    return false;
}

unittest
{
    auto corpus = parseJSON(readText("tests/fixtures/bridge_auto_connection/frozen.json"));
    auto overlay = parseJSON(
            readText("tests/fixtures/bridge_auto_connection/ours_smooth_expected.json"));
    assert(corpus["cases"].array.length == 14
            && corpus["additional_source_cells"].array.length == 2, "frozen population 14+2");
    assert(overlay["cases"].array.length == 6
            && overlay["provenance"]["source"].str == "analytic"
            && overlay["provenance"]["basis"].str == "ours-geometry-normal", "OURS population/provenance");
    size_t smooth, nativeCases;
    foreach (c; corpus["cases"].array)
    {
        string id = c["case"].str;
        auto inp = c["input"], outp = c["output"], attrs = c["attributes_observed"];
        Mesh m;
        foreach (v; inp["vertices"].array)
            m.addVertex(Vec3(cast(float) number(v[0]), cast(float) number(v[1]),
                    cast(float) number(v[2])));
        foreach (f; inp["faces"].array)
            m.addFace(ring(f));
        m.buildLoops();
        m.edgeMarks.length = m.edges.length;
        m.edgeSelectionOrder.length = m.edges.length;
        ulong[] selected;
        foreach (e; inp["selection_packet_order"]["edges"].array)
        {
            auto k = edgeKey(cast(uint) e[0].integer, cast(uint) e[1].integer);
            selected ~= k;
            bool found;
            foreach (ei, actual; m.edges)
                if (edgeKey(actual[0], actual[1]) == k)
                {
                    m.selectEdge(cast(int) ei);
                    found = true;
                    break;
                }
            assert(found, id ~ " selected input edge exists");
        }
        auto selectionBefore = m.edgeSelectionOrder.dup;
        uint[] a, b, caps;
        bool openRows;
        auto resolved = resolveBridgeSelection(m, EditMode.Edges);
        a = resolved.loopA;
        b = resolved.loopB;
        caps = resolved.capFaces;
        openRows = resolved.openRows;
        assert(resolved.valid, id ~ " resolves selection");
        assert(openRows, id ~ " open rows");
        BridgeParams p;
        p.segments = cast(int) attrs["segments"].integer;
        p.mode = cast(BridgeMode) attrs["mode"].integer;
        p.tension = cast(float) number(attrs["tension"]);
        p.connect = attrs["connect"].integer != 0;
        p.autoStep = attrs["autoStep"].integer != 0;
        p.flip = attrs["flip"].integer != 0;
        p.remove = attrs["remove"].integer != 0;
        auto result = applyBridgeOp(m, a, b, caps, p, openRows);
        assert(result.added > 0, id ~ " applied population");
        assert(result.effectiveSegments == c["effective_segments_observed"].integer,
                id ~ " effective segments");
        assert(m.vertices.length == outp["vertexCount"].integer, id ~ " vertex count");
        assert(m.faces.length == outp["faceCount"].integer, id ~ " face count");
        assert(m.edges.length == outp["edgeCount"].integer, id ~ " edge count");
        JSONValue ours;
        bool useOurs;
        foreach (o; overlay["cases"].array)
            if (o["case"].str == id)
            {
                ours = o;
                useOurs = true;
            }
        if (useOurs)
        {
            ++smooth;
            assert(ours["vertices"].array.length == 10, id ~ " OURS vertex floor");
        }
        else
            ++nativeCases;
        foreach (i, expected; outp["vertices"].array)
        {
            uint[3] expectedBits;
            foreach (j; 0 .. 3)
                expectedBits[j] = bits(cast(float) number(expected[j]));
            if (useOurs && i >= inp["vertices"].array.length)
            {
                auto v = ours["vertices"][i - inp["vertices"].array.length];
                assert(v["id"].integer == i, id ~ " OURS indexed ID");
                foreach (j; 0 .. 3)
                    expectedBits[j] = cast(uint) v["bits"][j].integer;
            }
            auto actual = m.vertices[i];
            assert([bits(actual.x), bits(actual.y),
                bits(actual.z)] == expectedBits, id ~ " position bits vertex " ~ i.to!string);
        }
        foreach (fi, f; outp["faces"].array)
            assert(cyclic(m.faces[fi], ring(f)), id ~ " face cyclic winding/order " ~ fi.to!string);
        ulong[] expectedEdges, actualEdges;
        foreach (e; outp["edges"].array)
            expectedEdges ~= edgeKey(cast(uint) e[0].integer, cast(uint) e[1].integer);
        foreach (e; m.edges)
            actualEdges ~= edgeKey(e[0], e[1]);
        sort(expectedEdges);
        sort(actualEdges);
        assert(actualEdges == expectedEdges, id ~ " exact edge set");
        ulong[] remaining;
        foreach (ei, e; m.edges)
            if (m.isEdgeSelected(ei))
                remaining ~= edgeKey(e[0], e[1]);
        sort(remaining);
        sort(selected);
        assert(remaining == selected, id ~ " selected edges preserved");
        foreach (i; 0 .. selectionBefore.length)
            assert(m.edgeSelectionOrder[i] == selectionBefore[i], id ~ " selection order preserved");
        foreach (i; 0 .. inp["faces"].array.length)
            assert(m.faces[i] == ring(inp["faces"][i]), id ~ " source face immutable");
        uint[] reused;
        foreach (i; inp["faces"].array.length .. m.faces.length)
            foreach (v; m.faces[i])
                if (v < inp["vertices"].array.length && !canFind(reused, v)
                        && !canFind(a, v) && !canFind(b, v))
                    reused ~= v;
        sort(reused);
        auto expectedReuse = ring(c["reused_original_vertices_derived"]);
        sort(expectedReuse);
        // Non-connect rails use original endpoints too; derived field records side reuse only.
        if (p.connect)
            assert(reused == expectedReuse, id ~ " reused IDs");
    }
    assert(smooth == 6 && nativeCases == 8, "split position populations 6/8");
}
