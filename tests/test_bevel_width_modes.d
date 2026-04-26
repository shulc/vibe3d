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

private void selectEdge(int idx) {
    auto resp = postJson("http://localhost:8080/api/select",
                         `{"mode":"edges","indices":[` ~ idx.to!string ~ `]}`);
    assert(resp["status"].str == "ok", "select failed: " ~ resp.toString());
}

private void runBevel(float width, string mode) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":` ~ width.to!string
                         ~ `,"mode":"` ~ mode ~ `"}}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}

private double[] vToD(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

private double dist(double[] a, double[] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// All four assertions hit cube edge 0 = (v_0, v_3): the BoundVerts at v_0
// (vertices[0] reused, vertices[8] new) slide along the two non-bev edges
// (0,1) → +X and (0,4) → +Z. The Euclidean distance from each BoundVert to
// v_0_orig (-0.5,-0.5,-0.5) equals the resolved per-edge offset.

private double sliceDist0(JSONValue m, int idx) {
    return dist(vToD(m["vertices"].array[idx]), [-0.5, -0.5, -0.5]);
}

// Tests --------------------------------------------------------------------

unittest { // OFFSET mode: w=0.3 → BV slides 0.3 (cube 90° corner: slide==offset)
    resetCube();
    selectEdge(0);
    runBevel(0.3f, "offset");
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    foreach (i; [0, 8])
        assert(abs(sliceDist0(m, i) - 0.3) < 1e-4,
            "OFFSET: vert " ~ i.to!string
            ~ " slid " ~ sliceDist0(m, i).to!string ~ ", expected 0.3");
}

unittest { // WIDTH mode: w=1 → resolved offset = w/(2 sin 45°) = √2/2 ≈ 0.7071
    resetCube();
    selectEdge(0);
    runBevel(1.0f, "width");
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    double expected = 1.0 / sqrt(2.0);
    foreach (i; [0, 8])
        assert(abs(sliceDist0(m, i) - expected) < 1e-4,
            "WIDTH: vert " ~ i.to!string
            ~ " slid " ~ sliceDist0(m, i).to!string
            ~ ", expected " ~ expected.to!string);
}

unittest { // DEPTH mode: w=1 → resolved offset = w/cos 45° = √2 ≈ 1.4142
    resetCube();
    selectEdge(0);
    runBevel(1.0f, "depth");
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    double expected = sqrt(2.0);
    foreach (i; [0, 8])
        assert(abs(sliceDist0(m, i) - expected) < 1e-4,
            "DEPTH: vert " ~ i.to!string
            ~ " slid " ~ sliceDist0(m, i).to!string
            ~ ", expected " ~ expected.to!string);
}

unittest { // PERCENT mode: w=50 with cube edges of length 1 → offset = 0.5
    resetCube();
    selectEdge(0);
    runBevel(50.0f, "percent");
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    double expected = 0.5;
    foreach (i; [0, 8])
        assert(abs(sliceDist0(m, i) - expected) < 1e-4,
            "PERCENT: vert " ~ i.to!string
            ~ " slid " ~ sliceDist0(m, i).to!string
            ~ ", expected " ~ expected.to!string);
}

unittest { // WIDTH/OFFSET equivalence: WIDTH at √2 ≈ same offset as OFFSET=1
    resetCube();
    selectEdge(0);
    runBevel(sqrt(2.0f), "width");
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    foreach (i; [0, 8])
        assert(abs(sliceDist0(m, i) - 1.0) < 1e-4,
            "WIDTH=√2 should give offset 1.0, got " ~ sliceDist0(m, i).to!string);
}

unittest { // unknown mode string returns error
    resetCube();
    selectEdge(0);
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":0.1,"mode":"bogus"}}`);
    assert(resp["status"].str == "error",
        "expected error for unknown mode, got: " ~ resp.toString());
}
