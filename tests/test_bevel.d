import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs, sqrt;

void main() {}

// Helpers ------------------------------------------------------------------

private JSONValue postJson(string url, string body_) {
    return parseJSON(post(url, body_));
}

private void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

private void selectEdge(int idx) {
    auto resp = postJson("http://localhost:8080/api/select",
                         `{"mode":"edges","indices":[` ~ idx.to!string ~ `]}`);
    assert(resp["status"].str == "ok",
        "select failed: " ~ resp.toString());
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

private double dist(double[] a, double[] b) {
    double dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// Tests --------------------------------------------------------------------

unittest { // BEVEL: cube edge 0, single segment, valence-3 endpoints → 10v/15e/7f
    resetCube();
    selectEdge(0);

    auto r = runBevel(0.2f);
    assert(r["status"].str == "ok", "bevel failed: " ~ r.toString());

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 10,
        "vertexCount: expected 10, got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer   == 15,
        "edgeCount: expected 15, got "   ~ m["edgeCount"].integer.to!string);
    assert(m["faceCount"].integer   == 7,
        "faceCount: expected 7, got "    ~ m["faceCount"].integer.to!string);
}

unittest { // BEVEL: every edge is shared by exactly 2 faces (closed manifold)
    resetCube();
    selectEdge(0);
    runBevel(0.1f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;

    int[long] uses;  // edgeKey → number of faces using it
    static long ekey(long a, long b) {
        return (a < b) ? (a << 32) | b : (b << 32) | a;
    }
    foreach (f; faces) {
        auto fv = f.array;
        foreach (i, _; fv) {
            long u = fv[i].integer, v = fv[(i + 1) % fv.length].integer;
            uses[ekey(u, v)]++;
        }
    }
    foreach (k, c; uses)
        assert(c == 2, "edge with key " ~ k.to!string
            ~ " is used by " ~ c.to!string ~ " faces (expected 2)");
}

unittest { // BEVEL: post-apply selection contains exactly the 4 bevel-quad edges
    resetCube();
    selectEdge(0);
    runBevel(0.1f);

    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["mode"].str == "edges");

    auto selectedEdges = sel["selectedEdges"].array;
    assert(selectedEdges.length == 4,
        "expected 4 selected edges (bevel quad), got "
        ~ selectedEdges.length.to!string);

    // The bevel quad is the 4-vertex face that contains both original endpoints
    // of the beveled edge (verts 0 and 3) plus two new verts (>= 8).
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;

    long[] quadVerts;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool has0 = false, has3 = false;
        int  newCount = 0;
        foreach (v; fv) {
            if (v.integer == 0) has0 = true;
            if (v.integer == 3) has3 = true;
            if (v.integer >= 8) newCount++;
        }
        if (has0 && has3 && newCount == 2) {
            foreach (v; fv) quadVerts ~= v.integer;
            break;
        }
    }
    assert(quadVerts.length == 4, "bevel quad face not found");

    auto edges = m["edges"].array;
    foreach (sei; selectedEdges) {
        auto e = edges[sei.integer].array;
        long a = e[0].integer, b = e[1].integer;
        bool found = false;
        foreach (i; 0 .. 4) {
            long u = quadVerts[i], v = quadVerts[(i + 1) % 4];
            if ((a == u && b == v) || (a == v && b == u)) { found = true; break; }
        }
        assert(found, "selected edge " ~ sei.integer.to!string
            ~ " is not on the bevel quad");
    }
}

unittest { // BEVEL: width slides each BoundVert by exactly `width` from origPos
    resetCube();
    selectEdge(0);                  // edge (0, 3): from (-.5,-.5,-.5) to (-.5,.5,-.5)
    runBevel(0.2f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;

    // After applying width=0.2 to edge 0 of a fresh cube:
    //   v_0 (orig endpoint) is reused as BV_left at v_0; slides along (0,1).
    //   v_3 (orig endpoint) is reused as BV_left at v_3; slides along (3,7).
    //   vertex 8 is the new BV_right at v_0; slides along (0,4) from v_0_orig.
    //   vertex 9 is the new BV_right at v_3; slides along (3,2) from v_3_orig.
    double[] v0Orig = [-0.5, -0.5, -0.5];
    double[] v3Orig = [-0.5,  0.5, -0.5];

    assert(abs(dist(vToD(verts[0]), v0Orig) - 0.2) < 1e-4,
        "v_0 should have moved by 0.2");
    assert(abs(dist(vToD(verts[3]), v3Orig) - 0.2) < 1e-4,
        "v_3 should have moved by 0.2");
    assert(abs(dist(vToD(verts[8]), v0Orig) - 0.2) < 1e-4,
        "vertex 8 (new BV_right at v_0) should be 0.2 from v_0_orig");
    assert(abs(dist(vToD(verts[9]), v3Orig) - 0.2) < 1e-4,
        "vertex 9 (new BV_right at v_3) should be 0.2 from v_3_orig");
}

unittest { // BEVEL: width=0 leaves all BoundVerts coincident with origPos
    resetCube();
    selectEdge(0);
    runBevel(0.0f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 10);
    auto verts = m["vertices"].array;

    double[] v0Orig = [-0.5, -0.5, -0.5];
    double[] v3Orig = [-0.5,  0.5, -0.5];

    foreach (i, exp; [v0Orig, v3Orig, v0Orig, v3Orig]) {
        // Indices 0, 3, 8, 9 — both reused endpoints and the two new BVs.
        int[] idxs = [0, 3, 8, 9];
        foreach (k; 0 .. 3)
            assert(abs(vToD(verts[idxs[i]])[k] - exp[k]) < 1e-5,
                "vertex " ~ idxs[i].to!string ~
                " should coincide with origPos at width=0");
    }
}

unittest { // BEVEL: requires Edges mode + non-empty selection
    resetCube();
    auto r = postJson("http://localhost:8080/api/command",
                     `{"id":"mesh.bevel","params":{"width":0.1}}`);
    assert(r["status"].str == "error",
        "expected error when no edges selected, got: " ~ r.toString());
}
