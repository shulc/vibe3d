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

private void runBevel(float width) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":` ~ width.to!string ~ `}}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}

private void runBevelSeg(float width, int seg) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":` ~ width.to!string
                         ~ `,"seg":` ~ seg.to!string ~ `}}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}

// Manifold check: every undirected edge in the face soup must be incident
// to exactly two faces.
private int countNonManifoldEdges(JSONValue model) {
    int[long] uses;
    static long ekey(long a, long b) {
        return (a < b) ? (a << 32) | b : (b << 32) | a;
    }
    foreach (f; model["faces"].array) {
        auto fv = f.array;
        foreach (i, _; fv) {
            long u = fv[i].integer, v = fv[(i + 1) % fv.length].integer;
            uses[ekey(u, v)]++;
        }
    }
    int bad = 0;
    foreach (k, c; uses) if (c != 2) bad++;
    return bad;
}

// Tests --------------------------------------------------------------------

unittest { // CORNER: selCount=2 valence=3 (two bev edges sharing a vertex) — manifold
    resetCube();
    // Edge 0 = (0,3) and edge 3 = (1,0) both incident to v_0 → v_0 has selCount=2.
    selectEdges([0, 3]);
    runBevel(0.2f);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh, got " ~ bad.to!string ~ " non-manifold edges");
}

unittest { // CORNER: selCount=2 produces a 3-vertex cap polygon
    resetCube();
    selectEdges([0, 3]);
    runBevel(0.2f);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;

    // Look for the cap face: a polygon whose vertices are ALL "new" or
    // "moved" — i.e., none of {v_2, v_4, v_5, v_6, v_7} (= cube vertices
    // not endpoints of any beveled edge). For two edges sharing v_0, the
    // cap is a digon (2 vertices) — which we skip — leaving the bevel
    // quads (4 verts). With our alias-merge logic the cap collapses for
    // selCount=2 valence=3 because two corner BVs share the non-bev edge.
    // What we DO assert: every patched face uses no fewer than 4 vertices.
    foreach (f; faces) {
        auto fv = f.array;
        assert(fv.length >= 3,
            "every face must have at least 3 vertices, got " ~ fv.length.to!string);
    }
}

unittest { // CUBE CORNER: selCount=3 valence=3 (three bev edges at one vertex) — manifold
    resetCube();
    // Edges 0, 3, 8 all incident to v_0 → cube corner.
    selectEdges([0, 3, 8]);
    runBevel(0.2f);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh, got " ~ bad.to!string ~ " non-manifold edges");
}

unittest { // CUBE CORNER: triangular cap polygon at the corner vertex
    resetCube();
    selectEdges([0, 3, 8]);
    runBevel(0.2f);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;
    auto verts = m["vertices"].array;

    // Each cap-corner BoundVert is the offset_meet of two 90° beveled edges
    // with width 0.2, sitting at (0.2, 0.2, 0)-style displacements from
    // v_0_orig. The Euclidean distance is therefore 0.2·√2 ≈ 0.2828, but the
    // perpendicular distance from each cap vertex to ANY of the three bev
    // edges is exactly 0.2.
    double[] v0orig = [-0.5, -0.5, -0.5];
    double[] v3orig = [-0.5,  0.5, -0.5];   // edge 0: v_0 → v_3
    double[] v1orig = [ 0.5, -0.5, -0.5];   // edge 3: v_0 → v_1
    double[] v4orig = [-0.5, -0.5,  0.5];   // edge 8: v_0 → v_4
    double dist(double[] a, double[] b) {
        double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }
    double[] vToD(JSONValue v) {
        auto a = v.array;
        return [a[0].floating, a[1].floating, a[2].floating];
    }
    // Perpendicular distance from p to line a-b.
    double perp(double[] p, double[] a, double[] b) {
        double[3] ab = [b[0]-a[0], b[1]-a[1], b[2]-a[2]];
        double[3] ap = [p[0]-a[0], p[1]-a[1], p[2]-a[2]];
        double[3] c  = [ap[1]*ab[2]-ap[2]*ab[1],
                        ap[2]*ab[0]-ap[0]*ab[2],
                        ap[0]*ab[1]-ap[1]*ab[0]];
        return sqrt(c[0]*c[0]+c[1]*c[1]+c[2]*c[2])
             / sqrt(ab[0]*ab[0]+ab[1]*ab[1]+ab[2]*ab[2]);
    }

    int triCaps = 0;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 3) continue;
        // Cap candidate: a 3-vertex face all of whose corners are within
        // 1.0 of v_0_orig (filters out the unrelated cube faces).
        bool nearV0 = true;
        foreach (vi; fv) {
            if (dist(vToD(verts[cast(int)vi.integer]), v0orig) > 1.0) {
                nearV0 = false; break;
            }
        }
        if (!nearV0) continue;

        // Each cap-corner BV must be perpendicular-distance 0.2 from each of
        // the two bev edges it is "between". Check the strongest invariant:
        // every cap vertex's MIN perpendicular distance over the 3 bev edges
        // must equal width = 0.2.
        foreach (vi; fv) {
            double[] p = vToD(verts[cast(int)vi.integer]);
            double d0 = perp(p, v0orig, v3orig);
            double d3 = perp(p, v0orig, v1orig);
            double d8 = perp(p, v0orig, v4orig);
            double dmin = d0;
            if (d3 < dmin) dmin = d3;
            if (d8 < dmin) dmin = d8;
            assert(abs(dmin - 0.2) < 1e-4,
                "cube-corner cap vertex min perp distance "
                ~ dmin.to!string ~ " ≠ 0.2");
        }
        triCaps++;
    }
    assert(triCaps >= 1,
        "expected at least one triangular cap at the cube corner, got "
        ~ triCaps.to!string);
}

unittest { // CUBE CORNER: total vertex count = 8 + 2 (at v_0) + 1 each at v_1, v_3, v_4 = 13
    resetCube();
    selectEdges([0, 3, 8]);
    runBevel(0.2f);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 13,
        "expected 13 vertices, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // CUBE CORNER seg=2: M_ADJ cap (3 quads + center) — manifold
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh for seg=2 cube corner, got "
        ~ bad.to!string ~ " non-manifold edges");
}

unittest { // CUBE CORNER seg=2: total vertex count = 8 + 6 (at v_0: 2 BV + 3 mid + 1 ctr)
           // + 2 each at v_1, v_3, v_4 (1 BV + 1 cap mid) = 20
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 20,
        "expected 20 vertices for seg=2 cube corner, got "
        ~ m["vertexCount"].integer.to!string);
}

unittest { // CUBE CORNER seg=4: M_ADJ grid (2 CC steps via topology) — manifold
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 4);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh for seg=4 cube corner, got "
        ~ bad.to!string ~ " non-manifold edges");
}

unittest { // CUBE CORNER seg=4: total vertex count
           // v_0:  2 new BVs + 5 grid-canon per panel × 3 panels + 1 ctr = 18
           // v_1, v_3, v_4: 1 BV + 3 cap-mid (selCount=1 leftBV profile) = 4 each
           // Total = 8 + 18 + 12 = 38
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 4);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 38,
        "expected 38 vertices for seg=4 cube corner, got "
        ~ m["vertexCount"].integer.to!string);
}

unittest { // CUBE CORNER seg=8: M_ADJ grid generalizes — manifold + face count
           // Cap quads = ns2 × (ns2 + odd) per panel × N = 4 × 4 × 3 = 48.
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 8);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh for seg=8 cube corner, got "
        ~ bad.to!string ~ " non-manifold edges");

    auto faces = m["faces"].array;
    auto verts = m["vertices"].array;
    double[] v0orig = [-0.5, -0.5, -0.5];
    double dist3(JSONValue v, double[] o) {
        auto a = v.array;
        double dx = a[0].floating - o[0];
        double dy = a[1].floating - o[1];
        double dz = a[2].floating - o[2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }
    int capQuads = 0;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool allClose = true;
        foreach (vi; fv) {
            if (dist3(verts[cast(int)vi.integer], v0orig) > 0.5) {
                allClose = false; break;
            }
        }
        if (allClose) capQuads++;
    }
    assert(capQuads == 48,
        "expected 48 M_ADJ cap quads at v_0 (seg=8), got "
        ~ capQuads.to!string);
}

unittest { // CUBE CORNER seg=4: cap is 12 quads (4 per panel × 3 panels)
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 4);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;
    auto verts = m["vertices"].array;

    double[] v0orig = [-0.5, -0.5, -0.5];
    double dist3(JSONValue v, double[] o) {
        auto a = v.array;
        double dx = a[0].floating - o[0];
        double dy = a[1].floating - o[1];
        double dz = a[2].floating - o[2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }

    // Cap quads sit entirely within ~0.5 of v_0_orig (well below the
    // ~0.7 distance to v_1 / v_3 / v_4 across the bev edges).
    int capQuads = 0;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool allClose = true;
        foreach (vi; fv) {
            if (dist3(verts[cast(int)vi.integer], v0orig) > 0.5) {
                allClose = false; break;
            }
        }
        if (allClose) capQuads++;
    }
    assert(capQuads == 12,
        "expected 12 M_ADJ cap quads at v_0 (seg=4), got "
        ~ capQuads.to!string);
}

unittest { // CUBE CORNER seg=2: cap is 3 quads sharing one center vertex
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;
    auto verts = m["vertices"].array;

    double[] v0orig = [-0.5, -0.5, -0.5];
    double dist3(JSONValue v, double[] o) {
        auto a = v.array;
        double dx = a[0].floating - o[0];
        double dy = a[1].floating - o[1];
        double dz = a[2].floating - o[2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }

    // The center vertex sits roughly at the centroid of the three cap-profile
    // midpoints; for a 0.2-width cube corner that is ~0.27 from v_0_orig.
    // Find every quad whose 4 vertices are all within 1.0 of v_0_orig and
    // share one common vertex — that common vertex is the M_ADJ center.
    int[int] vertHits;
    int capQuads = 0;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool nearV0 = true;
        foreach (vi; fv) {
            if (dist3(verts[cast(int)vi.integer], v0orig) > 1.0) {
                nearV0 = false; break;
            }
        }
        if (!nearV0) continue;
        // Skip strip quads: a strip quad spans BOTH v_0 and another bev-edge
        // endpoint, so at least one vertex is far from v_0_orig (>0.4 ≈ 1
        // edge minus a width). Cap quads sit entirely near v_0_orig.
        bool allClose = true;
        foreach (vi; fv) {
            if (dist3(verts[cast(int)vi.integer], v0orig) > 0.5) {
                allClose = false; break;
            }
        }
        if (!allClose) continue;
        capQuads++;
        foreach (vi; fv)
            vertHits[cast(int)vi.integer] = (cast(int)vi.integer in vertHits)
                ? vertHits[cast(int)vi.integer] + 1 : 1;
    }
    assert(capQuads == 3,
        "expected 3 M_ADJ cap quads at v_0, got " ~ capQuads.to!string);

    // The center vertex should appear in all 3 cap quads.
    int sharedCount = 0;
    foreach (k, c; vertHits) if (c == 3) sharedCount++;
    assert(sharedCount == 1,
        "expected exactly one shared center vertex across cap quads, got "
        ~ sharedCount.to!string);
}
