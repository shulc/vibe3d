import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

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

private JSONValue runBevel(float width) {
    return postJson("http://localhost:8080/api/command",
                    `{"id":"mesh.bevel","params":{"width":`
                    ~ width.to!string ~ `}}`);
}

private double[] vToD(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// Perpendicular distance from point `p` to the line through `a` and `b`.
private double perpDist(double[] p, double[] a, double[] b) {
    double[3] ab = [b[0]-a[0], b[1]-a[1], b[2]-a[2]];
    double[3] ap = [p[0]-a[0], p[1]-a[1], p[2]-a[2]];
    // |ap × ab| / |ab|
    double[3] c  = [ap[1]*ab[2]-ap[2]*ab[1],
                    ap[2]*ab[0]-ap[0]*ab[2],
                    ap[0]*ab[1]-ap[1]*ab[0]];
    double clen = sqrt(c[0]*c[0]+c[1]*c[1]+c[2]*c[2]);
    double ablen = sqrt(ab[0]*ab[0]+ab[1]*ab[1]+ab[2]*ab[2]);
    return clen / ablen;
}

// Tests --------------------------------------------------------------------

unittest { // OFFSET_MEET selCount=1: BoundVerts at perpendicular distance w from the bev edge
    resetCube();
    selectEdges([0]);          // edge (0, 3) along +Y
    runBevel(0.1f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;

    // Cube edge 0 = (v_0, v_3): bev axis is +Y at x=z=-0.5.
    // Slide directions for v_0: BV_left along (0,1)=+X, BV_right along (0,4)=+Z.
    // After bevel, v_0 stays as the reused BV_left (slid 0.1 along +X), and a
    // new vert is added as BV_right at v_0_orig + 0.1*+Z.
    double[] v0Orig = [-0.5, -0.5, -0.5];
    double[] v3Orig = [-0.5,  0.5, -0.5];
    double[] v3Now  = [-0.5,  0.5, -0.5];

    // Perpendicular distance from each "new" or moved BV at v_0 to the bev edge
    // line (= the line through v_0_orig and v_3_orig) must equal width=0.1.
    foreach (i; [0, 8]) {
        auto p = vToD(verts[i]);
        assert(abs(perpDist(p, v0Orig, v3Orig) - 0.1) < 1e-5,
            "vert " ~ i.to!string
            ~ " perp distance to bev edge != 0.1: got "
            ~ perpDist(p, v0Orig, v3Orig).to!string);
    }
    foreach (i; [3, 9]) {
        auto p = vToD(verts[i]);
        assert(abs(perpDist(p, v0Orig, v3Orig) - 0.1) < 1e-5,
            "vert " ~ i.to!string
            ~ " perp distance to bev edge != 0.1: got "
            ~ perpDist(p, v0Orig, v3Orig).to!string);
    }
}

unittest { // OFFSET_MEET selCount=2: shared BoundVert at perp distance w from BOTH bev edges
    resetCube();
    // Edge 0 = (0, 3) along +Y; edge 3 = (1, 0) along -X (same as +X from v_0).
    // Both incident to v_0, both lie on face F0 (the back face at z=-0.5).
    // The corner between them is right-angle.
    selectEdges([0, 3]);

    auto bv = parseJSON(get("http://localhost:8080/api/bevvert?vert=0"));
    assert(bv["selCount"].integer == 2, "expected selCount=2 at v_0");

    // Find the BoundVert whose slideDir lies between the two bev edges
    // (isOnEdge=false → both flanking EHs are bev).
    JSONValue both;
    bool found = false;
    foreach (b; bv["boundVerts"].array)
        if (!b["isOnEdge"].boolean) { both = b; found = true; break; }
    assert(found, "expected a BoundVert flanked by two bev EdgeHalfs");

    // BoundVert position at width=0.1.
    auto orig = vToD(bv["origPos"]);
    auto sd   = vToD(both["slideDir"]);
    double w = 0.1;
    double[] pos = [orig[0] + sd[0]*w, orig[1] + sd[1]*w, orig[2] + sd[2]*w];

    // The two bev edges from v_0: edge 0 → v_3 = (-0.5, 0.5, -0.5);
    // edge 3 → v_1 = (0.5, -0.5, -0.5).
    double[] v3 = [-0.5,  0.5, -0.5];
    double[] v1 = [ 0.5, -0.5, -0.5];

    double dToBev0 = perpDist(pos, orig, v3);
    double dToBev3 = perpDist(pos, orig, v1);

    assert(abs(dToBev0 - w) < 1e-5,
        "shared BV perp dist to edge (0,3) = " ~ dToBev0.to!string
        ~ ", expected " ~ w.to!string);
    assert(abs(dToBev3 - w) < 1e-5,
        "shared BV perp dist to edge (1,0) = " ~ dToBev3.to!string
        ~ ", expected " ~ w.to!string);
}

unittest { // OFFSET_MEET selCount=2: BV between bev and non-bev still slides on the non-bev edge
    resetCube();
    selectEdges([0, 3]);

    auto bv = parseJSON(get("http://localhost:8080/api/bevvert?vert=0"));

    // Each "isOnEdge" BoundVert (one flanking EH bev, the other non-bev)
    // should have slideDir of unit length along the non-bev edge.
    foreach (b; bv["boundVerts"].array) {
        if (!b["isOnEdge"].boolean) continue;
        auto sd = vToD(b["slideDir"]);
        double mag = sqrt(sd[0]*sd[0] + sd[1]*sd[1] + sd[2]*sd[2]);
        assert(abs(mag - 1.0) < 1e-5,
            "isOnEdge BV slideDir magnitude should be 1, got " ~ mag.to!string);
    }
}
