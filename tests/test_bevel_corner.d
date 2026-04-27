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

unittest { // selCount=2 valence=3 (two adjacent bev edges) seg=2 — manifold
           // The alias-merged cap edge has its midpoint shared between both
           // bev strips; without the leftBV-profile-forwarding fix in
           // capSamples, the midpoint would be left dangling and edges
           // BV0-mid / mid-BV1 would only sit in one face each.
    resetCube();
    selectEdges([0, 3]);          // edges sharing v_0
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh for selCount=2 seg=2, got "
        ~ bad.to!string ~ " non-manifold edges");
}

unittest { // selCount=2 seg=2 with non-bev EH BETWEEN the two bev EHs in
           // CCW order — regression: with the naive
           // leftBVidxAlloc=boundVertIdxForEh(bevEdgeIdx) selection, the
           // chosen leftBV is the alias-target sliding on the non-bev edge.
           // Its profile.start == profile.end (post alias-merge), so the
           // super-ellipse midpoint collapses onto a degenerate curve and
           // the strip cross-section midpoint lands at a meaningless
           // (≈ midpoint of origPos and the alias) point instead of on the
           // rounded cap. The fix scans for a non-degenerate leftBV.
           //
           // Edges 5 (v_5–v_6) and 6 (v_6–v_7) share v_6; the third edge at
           // v_6 (v_6–v_2) is non-bev and falls *between* them in the EH
           // ring. The cap mid at v_6 must land on the convex super-ellipse
           // arc bridging the corner BV (≈ (0.355, 0.355, 0.5)) and the
           // alias BV (≈ (0.5, 0.5, 0.355)). The convex parameterization
           // P = origPos + (1-v)·dStart + (1-u)·dEnd places the midpoint
           // close to origPos (rounding *off* the corner toward the
           // inscribed sphere), at ≈ (0.458, 0.458, 0.458).
    resetCube();
    selectEdges([5, 6]);
    runBevelSeg(0.145f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    int bad = countNonManifoldEdges(m);
    assert(bad == 0,
        "expected manifold mesh, got " ~ bad.to!string ~ " non-manifold edges");

    int found = 0;
    foreach (i, v; m["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - 0.4575) < 0.005
         && abs(a[1].floating - 0.4575) < 0.005
         && abs(a[2].floating - 0.4575) < 0.005) {
            found++;
        }
    }
    assert(found == 1,
        "expected exactly one cap mid at (0.4575, 0.4575, 0.4575) for v_6 "
        ~ "selCount=2 seg=2; got " ~ found.to!string ~ " — leftBVidxAlloc "
        ~ "regression or convex-bevel formula change?");
}

unittest { // selCount=2 valence=3 seg=2: total vertex count
           // v_0:  1 unique BV (BV0; BV1 aliases to BV2) + 1 mid (cap edge)
           //       Wait: BV0 + (BV1=BV2 alias) = 2 unique BVs at v_0,
           //       one of which reuses v_0 → 1 NEW BV. Plus 1 mid = 2 new.
           // v_1, v_3 (selCount=1): 1 BV + 1 cap-mid = 2 each → 4 total.
           // Total = 8 + 2 + 4 = 14.
    resetCube();
    selectEdges([0, 3]);
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 14,
        "expected 14 vertices for selCount=2 seg=2, got "
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

unittest { // CUBE CORNER seg=2: M_ADJ cap is a sphere octant (Blender's
           // tri_corner_adj_vmesh). All 7 cap vertices (3 corner BVs +
           // 3 cap-arc midpoints + 1 center) lie on the sphere of radius
           // `width` centered at the offset point sphere_center =
           // origPos + width · sum(unit_bev_edge_dirs).
           //
           // For cube corner v_0 with width=0.2:
           //   sphere_center = (-0.5+0.2, -0.5+0.2, -0.5+0.2) = (-0.3, -0.3, -0.3)
           //   center on (1,1,1) diagonal at dist 0.2 from sphere_center
           //     → (-0.4155, -0.4155, -0.4155), dist from v_0_orig ≈ 0.1464.
           //   cap-arc mid SLERP of two BVs at dist 0.2 from sphere_center
           //     → coords like (-0.3, -0.4414, -0.4414), dist from v_0 ≈ 0.2165.
    resetCube();
    selectEdges([0, 3, 8]);
    runBevelSeg(0.2f, 2);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;
    auto verts = m["vertices"].array;
    double[] v0orig    = [-0.5, -0.5, -0.5];
    double[] sphereC   = [-0.3, -0.3, -0.3];
    double dist3(JSONValue v, double[] o) {
        auto a = v.array;
        double dx = a[0].floating - o[0];
        double dy = a[1].floating - o[1];
        double dz = a[2].floating - o[2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }
    // Find the cap center: the unique vertex shared by all three cap quads.
    int[int] vertHits;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool allClose = true;
        foreach (vi; fv) {
            if (dist3(verts[cast(int)vi.integer], v0orig) > 0.5) {
                allClose = false; break;
            }
        }
        if (!allClose) continue;
        foreach (vi; fv)
            vertHits[cast(int)vi.integer] = (cast(int)vi.integer in vertHits)
                ? vertHits[cast(int)vi.integer] + 1 : 1;
    }
    int centerVid = -1;
    foreach (k, c; vertHits) if (c == 3) { centerVid = k; break; }
    assert(centerVid >= 0, "could not find M_ADJ center vertex");
    double dCenterFromV0 = dist3(verts[centerVid], v0orig);
    assert(abs(dCenterFromV0 - 0.1464) < 0.005,
        "M_ADJ center at distance " ~ dCenterFromV0.to!string ~ " from v_0_orig, "
        ~ "expected ~0.1464 (sphere octant, width=0.2)");
    // Stronger invariant: every cap vertex (any vertex referenced in a cap
    // quad) sits on the sphere of radius 0.2 centered at sphere_center.
    foreach (k, _; vertHits) {
        double dS = dist3(verts[k], sphereC);
        assert(abs(dS - 0.2) < 1e-4,
            "cap vertex " ~ k.to!string ~ " at dist " ~ dS.to!string
            ~ " from sphere_center; expected 0.2 (sphere octant)");
    }
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
