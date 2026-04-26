import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

private JSONValue postJson(string url, string body_) {
    return parseJSON(post(url, body_));
}

private void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

private void selectEdges(int[] indices) {
    string body_ = `{"mode":"edges","indices":[`;
    foreach (i, idx; indices) {
        if (i > 0) body_ ~= ",";
        body_ ~= idx.to!string;
    }
    body_ ~= "]}";
    auto resp = postJson("http://localhost:8080/api/select", body_);
    assert(resp["status"].str == "ok", "select failed: " ~ resp.toString());
}

private JSONValue bevvert(int vert) {
    auto resp = get("http://localhost:8080/api/bevvert?vert=" ~ vert.to!string);
    return parseJSON(resp);
}

// Tests --------------------------------------------------------------------

unittest { // BEVVERT: cube edge 0 selected → both endpoints valence=3, selCount=1
    resetCube();
    selectEdges([0]);

    foreach (v; [0, 3]) {
        auto bv = bevvert(v);
        assert(bv["vert"].integer == v);
        assert(bv["edges"].array.length == 3,
            "v=" ~ v.to!string ~ " expected valence 3, got "
            ~ bv["edges"].array.length.to!string);
        assert(bv["selCount"].integer == 1,
            "v=" ~ v.to!string ~ " expected selCount=1, got "
            ~ bv["selCount"].integer.to!string);
        assert(bv["bevEdgeIdx"].integer >= 0,
            "v=" ~ v.to!string ~ " expected bevEdgeIdx>=0");
    }
}

unittest { // BEVVERT: every EdgeHalf points to two distinct face indices
    resetCube();
    selectEdges([0]);

    foreach (v; [0, 3]) {
        auto bv = bevvert(v);
        long[bool] seenFaces;
        foreach (eh; bv["edges"].array) {
            long fnext = eh["fnext"].integer;
            long fprev = eh["fprev"].integer;
            assert(fnext >= 0, "fnext should be a valid face index");
            assert(fprev >= 0, "fprev should be a valid face index");
            assert(fnext != fprev,
                "v=" ~ v.to!string ~ ": fprev/fnext must differ for a manifold ring");
        }
    }
}

unittest { // BEVVERT: ring is CCW — e[i].fnext == e[(i+1)%N].fprev
    resetCube();
    selectEdges([0]);

    foreach (v; [0, 3]) {
        auto bv = bevvert(v);
        auto edges = bv["edges"].array;
        int N = cast(int)edges.length;
        foreach (i; 0 .. N) {
            long fnextHere = edges[i]["fnext"].integer;
            long fprevNext = edges[(i + 1) % N]["fprev"].integer;
            assert(fnextHere == fprevNext,
                "v=" ~ v.to!string ~ " ring break at i=" ~ i.to!string
                ~ ": e[i].fnext=" ~ fnextHere.to!string
                ~ " != e[i+1].fprev=" ~ fprevNext.to!string);
        }
    }
}

unittest { // BEVVERT: vertex with no incident beveled edge has selCount=0
    resetCube();
    selectEdges([0]);  // edge (0,3); v_5 is opposite corner

    auto bv = bevvert(5);
    assert(bv["selCount"].integer == 0);
    assert(bv["bevEdgeIdx"].integer == -1);
    foreach (eh; bv["edges"].array)
        assert(!eh["isBev"].boolean, "no EdgeHalf should be marked isBev");
}

unittest { // BEVVERT: out-of-range vert returns 400 error
    import std.net.curl : HTTPStatusException;
    resetCube();
    bool got400 = false;
    try
        cast(void)get("http://localhost:8080/api/bevvert?vert=9999");
    catch (HTTPStatusException e)
        got400 = (e.status == 400);
    assert(got400, "expected HTTP 400 for out-of-range vert");
}

unittest { // BEVVERT: selecting two edges sharing a vertex bumps selCount
    resetCube();
    // Edge 0 = (0,3); edge 3 = (1,0). Both incident to vertex 0.
    selectEdges([0, 3]);

    auto bv = bevvert(0);
    assert(bv["selCount"].integer == 2,
        "v=0 with two incident bev edges should have selCount=2, got "
        ~ bv["selCount"].integer.to!string);

    int bevCount = 0;
    foreach (eh; bv["edges"].array)
        if (eh["isBev"].boolean) bevCount++;
    assert(bevCount == 2, "expected 2 EdgeHalfs marked isBev");

    // The other endpoint of edge 0 (=v_3) only has 1 bev edge.
    auto bvB = bevvert(3);
    assert(bvB["selCount"].integer == 1);
}
