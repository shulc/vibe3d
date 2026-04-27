import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

private void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

private void selectEdge(int idx) {
    post("http://localhost:8080/api/select",
         `{"mode":"edges","indices":[` ~ idx.to!string ~ `]}`);
}

private void runBevel(float width) {
    auto resp = parseJSON(post("http://localhost:8080/api/command",
        `{"id":"mesh.bevel","params":{"width":` ~ width.to!string ~ `}}`));
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}

// True iff every face's plane normal points "outward" with respect to the
// origin — a coarse check that nothing has flipped inside-out for cube-like
// geometry centered at the origin.
private bool allFacesOutward(JSONValue model) {
    import std.algorithm : map;
    foreach (f; model["faces"].array) {
        auto fv = f.array;
        if (fv.length < 3) continue;
        // Newell's normal
        double nx = 0, ny = 0, nz = 0;
        double cx = 0, cy = 0, cz = 0;
        foreach (i; 0 .. fv.length) {
            auto a = model["vertices"].array[fv[i].integer].array;
            auto b = model["vertices"].array[fv[(i + 1) % fv.length].integer].array;
            nx += (a[1].floating - b[1].floating) * (a[2].floating + b[2].floating);
            ny += (a[2].floating - b[2].floating) * (a[0].floating + b[0].floating);
            nz += (a[0].floating - b[0].floating) * (a[1].floating + b[1].floating);
            cx += a[0].floating; cy += a[1].floating; cz += a[2].floating;
        }
        cx /= fv.length; cy /= fv.length; cz /= fv.length;
        // For an outward-oriented face on a convex mesh containing the origin,
        // dot(normal, centroid) > 0.
        double d = nx * cx + ny * cy + nz * cz;
        if (d < -1e-4) return false;
    }
    return true;
}

unittest { // limit_offset: requested width 100 on a unit-edge cube clamps to ≤ 0.5
    resetCube();
    selectEdge(0);
    runBevel(100.0f);   // wildly excessive — should silently clamp
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(allFacesOutward(m),
        "expected no inverted faces after clamp; got at least one face whose "
        ~ "normal points inward");
    // Topology should still match a normal seg=1 cube edge bevel: 10v / 15e / 7f
    assert(m["vertexCount"].integer == 10,
        "expected 10 verts after clamped bevel, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "expected 7 faces after clamped bevel, got "
        ~ m["faceCount"].integer.to!string);
}

unittest { // limit_offset: width slightly below limit produces normal bevel
    resetCube();
    selectEdge(0);
    runBevel(0.4f);     // well within the 0.5 limit
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(allFacesOutward(m),
        "expected no inverted faces at width=0.4");
    // The new BV positions should be at distance ~0.4 from v_0 along its
    // adjacent edges.
    auto verts = m["vertices"].array;
    bool foundForwardBV = false;
    foreach (v; verts) {
        auto a = v.array;
        // Look for a BV that slid +X by 0.4 from v_0=(-0.5,-0.5,-0.5)
        if (abs(a[0].floating - (-0.1)) < 1e-3
         && abs(a[1].floating - (-0.5)) < 1e-3
         && abs(a[2].floating - (-0.5)) < 1e-3) { foundForwardBV = true; break; }
    }
    assert(foundForwardBV,
        "expected a BoundVert at (-0.1, -0.5, -0.5) for width=0.4 bevel of edge 0");
}

unittest { // limit_offset: cube corner (3 edges at v_0) — limit binds to 0.5 too
    resetCube();
    post("http://localhost:8080/api/select",
         `{"mode":"edges","indices":[0,3,8]}`);
    auto resp = parseJSON(post("http://localhost:8080/api/command",
        `{"id":"mesh.bevel","params":{"width":99.0,"seg":2}}`));
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    assert(allFacesOutward(m),
        "expected no inverted faces in clamped cube-corner bevel");
}
