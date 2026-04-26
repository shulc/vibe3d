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

private void runBevel(float width, int seg, float superR = 2.0f) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":` ~ width.to!string
                         ~ `,"seg":` ~ seg.to!string
                         ~ `,"superR":` ~ superR.to!string ~ `}}`);
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

// Tests --------------------------------------------------------------------

unittest { // PROFILE seg=4 vert count: 8 cube + (seg new per endpoint) * 2 = 16
    resetCube();
    selectEdge(0);
    runBevel(0.1f, 4);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 16,
        "expected 16 verts for seg=4, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // PROFILE seg=4 superR=2 (circle): all sample points at distance w from origPos
    resetCube();
    selectEdge(0);
    runBevel(0.1f, 4, 2.0f);

    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto verts = m["vertices"].array;
    double[] v0orig = [-0.5, -0.5, -0.5];
    double[] v3orig = [-0.5,  0.5, -0.5];

    // For seg=4 cube edge 0, the new vertices land at indices 8..15:
    //   v_0 cap profile: indices 8 (BV_right), 9, 10, 11 (intermediates,
    //                    all at distance w from v_0_orig)
    //   v_3 cap profile: indices 12 (BV_right), 13, 14, 15 (intermediates,
    //                    all at distance w from v_3_orig)
    // Plus moved originals v_0 (index 0) and v_3 (index 3).
    foreach (i; [0, 8, 9, 10, 11]) {
        double d = dist(vToD(verts[i]), v0orig);
        assert(abs(d - 0.1) < 1e-4,
            "v[" ~ i.to!string ~ "] dist from v_0_orig = " ~ d.to!string
            ~ ", expected 0.1");
    }
    foreach (i; [3, 12, 13, 14, 15]) {
        double d = dist(vToD(verts[i]), v3orig);
        assert(abs(d - 0.1) < 1e-4,
            "v[" ~ i.to!string ~ "] dist from v_3_orig = " ~ d.to!string
            ~ ", expected 0.1");
    }
}

unittest { // PROFILE seg=4: bevel-quad strip has 4 quads (each 4 verts)
    resetCube();
    selectEdge(0);
    runBevel(0.1f, 4);

    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    auto selectedEdges = sel["selectedEdges"].array;
    // The strip has 4 quads × 4 edges = 16 edge slots; deduped into the
    // strip's edge set. Just check count > 4 (more than seg=1 case).
    assert(selectedEdges.length > 4,
        "expected more than 4 selected edges for seg=4 strip, got "
        ~ selectedEdges.length.to!string);

    // Verify each strip face is a quad.
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto faces = m["faces"].array;
    int stripQuads = 0;
    foreach (f; faces) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        // Strip quads contain only "new" or moved-orig BV verts (indices
        // in {0, 3, 8..15} for our seg=4 cube case).
        bool allBV = true;
        foreach (v; fv) {
            long vi = v.integer;
            if (vi != 0 && vi != 3 && (vi < 8 || vi > 15)) { allBV = false; break; }
        }
        if (allBV) stripQuads++;
    }
    assert(stripQuads == 4,
        "expected 4 strip quads for seg=4, got " ~ stripQuads.to!string);
}

unittest { // PROFILE: /api/bevvert exposes profile.sample
    resetCube();
    selectEdge(0);
    // Run bevel so the (apply-time) seg/superR are reflected, then ask
    // /api/bevvert for the BevVert. Note: /api/bevvert recomputes the
    // BevVert with default seg=1, so we just verify the JSON shape, not the
    // exact intermediate positions.
    auto bv = parseJSON(get("http://localhost:8080/api/bevvert?vert=0"));
    foreach (b; bv["boundVerts"].array) {
        assert("profile" in b, "boundVert should expose profile");
        auto pf = b["profile"];
        assert("superR" in pf);
        assert("sample" in pf);
        assert(pf["sample"].array.length >= 2,
            "profile.sample should have at least 2 points (seg+1 ≥ 2)");
    }
}

unittest { // PROFILE seg=1 falls back to existing topology (10v/15e/7f)
    resetCube();
    selectEdge(0);
    runBevel(0.1f, 1);
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(m["vertexCount"].integer == 10);
    assert(m["edgeCount"].integer   == 15);
    assert(m["faceCount"].integer   == 7);
}
