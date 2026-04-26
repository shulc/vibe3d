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

private void runBevelAsymmetric(float widthL, float widthR) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":` ~ widthL.to!string
                         ~ `,"widthR":` ~ widthR.to!string ~ `}}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}

private double[] vToD(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// Perpendicular distance from point `p` to the line through `a` and `b`.
private double perpDist(double[] p, double[] a, double[] b) {
    double[3] ab = [b[0]-a[0], b[1]-a[1], b[2]-a[2]];
    double[3] ap = [p[0]-a[0], p[1]-a[1], p[2]-a[2]];
    double[3] c  = [ap[1]*ab[2]-ap[2]*ab[1],
                    ap[2]*ab[0]-ap[0]*ab[2],
                    ap[0]*ab[1]-ap[1]*ab[0]];
    double clen = sqrt(c[0]*c[0]+c[1]*c[1]+c[2]*c[2]);
    double ablen = sqrt(ab[0]*ab[0]+ab[1]*ab[1]+ab[2]*ab[2]);
    return clen / ablen;
}

// Tests --------------------------------------------------------------------

unittest { // ASYMMETRIC: cube edge 0 with widthL=0.1 widthR=0.3 → two faces, two perp dists
    resetCube();
    selectEdge(0);                       // bev edge runs along +Y at (-.5, *, -.5)
    runBevelAsymmetric(0.1f, 0.3f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;
    auto faces = m["faces"].array;

    double[] v0orig = [-0.5, -0.5, -0.5];
    double[] v3orig = [-0.5,  0.5, -0.5];

    // For each face touching exactly one bev-edge endpoint (= 4-vertex face
    // adjacent to the beveled edge), all corner BoundVerts should be at the
    // SAME perpendicular distance from the bev-edge line: either widthL or
    // widthR depending on which side of the edge the face is on. Both
    // endpoints of one face must agree (no twist).
    int[] faceDistsBucket01;   // face indices whose BVs are at perp 0.1
    int[] faceDistsBucket03;   // face indices whose BVs are at perp 0.3

    foreach (fi, f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        // A "patched bev-adjacent face" contains v_0 OR new vert 8 (for v_0
        // BV_right) plus v_3 or new vert 9.
        bool touchesV0 = false, touchesV3 = false;
        foreach (v; fv) {
            long vi = v.integer;
            if (vi == 0 || vi == 8) touchesV0 = true;
            if (vi == 3 || vi == 9) touchesV3 = true;
        }
        if (!(touchesV0 && touchesV3)) continue;

        // Skip the bevel quad itself — it has 2 BVs at width=L and 2 at
        // width=R, so its perp distances differ within one face.
        bool allBoundary = true;
        foreach (v; fv) {
            long vi = v.integer;
            if (vi != 0 && vi != 3 && vi != 8 && vi != 9) { allBoundary = false; break; }
        }
        if (allBoundary) continue;       // bevel quad

        // Compute perp dist of every BV vertex (0, 3, 8, 9) on this face.
        double[] dists;
        foreach (v; fv) {
            long vi = v.integer;
            if (vi == 0 || vi == 3 || vi == 8 || vi == 9)
                dists ~= perpDist(vToD(verts[vi]), v0orig, v3orig);
        }
        assert(dists.length == 2, "patched face should have 2 BV corners");
        assert(abs(dists[0] - dists[1]) < 1e-5,
            "face " ~ fi.to!string ~ " perp dists differ: "
            ~ dists[0].to!string ~ " vs " ~ dists[1].to!string);
        if (abs(dists[0] - 0.1) < 1e-5)      faceDistsBucket01 ~= cast(int)fi;
        else if (abs(dists[0] - 0.3) < 1e-5) faceDistsBucket03 ~= cast(int)fi;
        else assert(false, "unexpected perp dist " ~ dists[0].to!string);
    }
    assert(faceDistsBucket01.length == 1,
        "expected exactly one bev-adjacent face at perp 0.1, got "
        ~ faceDistsBucket01.length.to!string);
    assert(faceDistsBucket03.length == 1,
        "expected exactly one bev-adjacent face at perp 0.3, got "
        ~ faceDistsBucket03.length.to!string);
}

unittest { // ASYMMETRIC: widthR omitted → falls back to symmetric width=widthL
    resetCube();
    selectEdge(0);
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":0.2}}`);
    assert(resp["status"].str == "ok");

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;
    double[] v0orig = [-0.5, -0.5, -0.5];
    double[] v3orig = [-0.5,  0.5, -0.5];

    foreach (i; [0, 3, 8, 9]) {
        double d = perpDist(vToD(verts[i]), v0orig, v3orig);
        assert(abs(d - 0.2) < 1e-5,
            "vert " ~ i.to!string ~ " perp = " ~ d.to!string ~ ", expected 0.2");
    }
}

unittest { // ASYMMETRIC: widthL == widthR equivalent to omitting widthR
    resetCube();
    selectEdge(0);
    runBevelAsymmetric(0.2f, 0.2f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;
    double[] v0orig = [-0.5, -0.5, -0.5];
    double[] v3orig = [-0.5,  0.5, -0.5];
    foreach (i; [0, 3, 8, 9]) {
        double d = perpDist(vToD(verts[i]), v0orig, v3orig);
        assert(abs(d - 0.2) < 1e-5,
            "vert " ~ i.to!string ~ " perp = " ~ d.to!string ~ ", expected 0.2");
    }
}
