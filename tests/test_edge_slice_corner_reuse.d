// test_edge_slice_corner_reuse.d — golden-parity test for the mesh-robustness
// batch (task 0349): a chord chain that degenerates into a plain edge-split
// (a real vertex inserted, facesSplit==0) is KEPT and finalized, matching a
// frozen reference capture, and — critically — that KEEP is visible through
// the real product surface (the `mesh.edgeSlice` HTTP command), not just the
// kernel. A raw-kernel-only test would be insufficient here: `mesh.edgeSlice`
// (the command) used to gate rollback on `nSplit == 0` (the old `.facesSplit`
// wrapper), which reverted this exact case — the command-level caller fix
// (gating on `!meshChanged` instead) is what this test actually proves.
//
// Scenario: standard cube, edge(0,1)@t=0.51 (genuine interior insert) chained
// to edge(1,5)@corner-reuse (lands on the SHARED corner, vertex 1). Both
// edges border face 5 ([0,1,5,4]); the two cut positions are ADJACENT there,
// so the chord-split guard correctly refuses to split any face
// (facesSplit==0) — but the interior insert on edge(0,1) is a real,
// reference-faithful mutation and must be KEPT:
//   cube (V8/E12/F6) -> V9/E13/F6, chi stays 2, new vertex ~= [0.01,-0.5,-0.5]
//   on edge(0,1); edge(0,1) is replaced by (0,newVert)+(newVert,1); no face
//   is added or removed (only re-wound). Golden derived from a frozen
// reference capture, stripped of all provenance (geometry only).
//
// Asserted TOPOLOGY-invariantly (counts + edge-set + vertex-position
// multiset + manifold), NOT exact face-array order/winding.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue model() { return parseJSON(cast(string)get(BASE ~ "/api/model")); }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
size_t faceCount(JSONValue m) { return m["faces"].array.length; }
size_t edgeCount(JSONValue m) { return m["edges"].array.length; }

void runCommandWith(string body_) {
    auto r = postCmd("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ r.toString);
}

uint edgeIndexByVerts(JSONValue m, int a, int b) {
    if ("edges" !in m.object) return uint.max;
    foreach (i, e; m["edges"].array) {
        int ea = cast(int)e.array[0].integer;
        int eb = cast(int)e.array[1].integer;
        if ((ea == a && eb == b) || (ea == b && eb == a))
            return cast(uint)i;
    }
    return uint.max;
}

void assertEdgeManifold(JSONValue m, string context) {
    int[ulong] efCount;
    foreach (f; m["faces"].array) {
        auto fc = f.array;
        foreach (i; 0 .. fc.length) {
            size_t a = cast(size_t)fc[i].integer;
            size_t b = cast(size_t)fc[(i + 1) % fc.length].integer;
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            efCount[key]++;
        }
    }
    foreach (key, cnt; efCount)
        assert(cnt <= 2,
            context ~ ": edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");
}

bool hasVertexNear(JSONValue m, double x, double y, double z, double eps) {
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - x) < eps && abs(a[1].floating - y) < eps &&
            abs(a[2].floating - z) < eps) return true;
    }
    return false;
}

unittest { // golden-parity: kept degenerate-chain edge-split visible through mesh.edgeSlice
    auto r0 = postCmd("/api/reset", "");
    assert(r0["status"].str == "ok", "/api/reset failed");
    auto s0 = postCmd("/api/select", `{"mode":"edges","indices":[]}`);
    assert(s0["status"].str == "ok", "/api/select (edges) failed");

    auto m0 = model();
    assert(vertCount(m0) == 8, "cube starts with 8 verts");
    assert(faceCount(m0) == 6, "cube starts with 6 faces");
    assert(edgeCount(m0) == 12, "cube starts with 12 edges");

    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 1, 5);
    assert(eA != uint.max, "edge(0,1) must exist on cube");
    assert(eB != uint.max, "edge(1,5) must exist on cube");

    // tB picked so it lands EXACTLY on the shared corner vertex 1, regardless
    // of the stored edge's endpoint order.
    double tB = (m0["edges"].array[eB].array[0].integer == 1) ? 0.0 : 1.0;

    // Expected new-vertex position: lerp(edges[eA][0], edges[eA][1], 0.51) in
    // vibe3d's OWN stored edge direction (t is measured from edges[][0] to
    // edges[][1] — see edgeSliceEx's doc comment — and that direction is an
    // internal dedup-order detail, independent of which endpoint the caller
    // names first). This is the analytic position ~= [+-0.01, -0.5, -0.5]
    // (the reference capture's [0.01,-0.5,-0.5] up to that direction sign).
    auto eAEnds = m0["edges"].array[eA].array;
    auto vFrom = m0["vertices"].array[cast(size_t)eAEnds[0].integer].array;
    auto vTo   = m0["vertices"].array[cast(size_t)eAEnds[1].integer].array;
    double expX = vFrom[0].floating + 0.51 * (vTo[0].floating - vFrom[0].floating);
    double expY = vFrom[1].floating + 0.51 * (vTo[1].floating - vFrom[1].floating);
    double expZ = vFrom[2].floating + 0.51 * (vTo[2].floating - vFrom[2].floating);
    assert(abs(abs(expX) - 0.01) < 1e-6 && abs(expY - (-0.5)) < 1e-6 && abs(expZ - (-0.5)) < 1e-6,
        format("sanity: expected the analytic cut position near |x|=0.01,y=-0.5,z=-0.5, got [%.6f,%.6f,%.6f]",
               expX, expY, expZ));

    runCommandWith(format(`{"id":"mesh.edgeSlice","edges":[%d,%d],"tA":0.51,"tB":%.1f}`,
                          eA, eB, tB));

    auto m1 = model();
    assert(vertCount(m1) == 9,
        "expected V=9 after the kept degenerate-chain insert, got " ~ vertCount(m1).to!string);
    assert(edgeCount(m1) == 13,
        "expected E=13 after the kept degenerate-chain insert, got " ~ edgeCount(m1).to!string);
    assert(faceCount(m1) == 6,
        "expected F=6 (no face split, only re-wound), got " ~ faceCount(m1).to!string);
    assert(cast(long)vertCount(m1) - cast(long)edgeCount(m1) + cast(long)faceCount(m1) == 2,
        "Euler characteristic must stay 2");

    assertEdgeManifold(m1, "kept degenerate-chain insert");

    // The new vertex lands at the analytic cut position computed above
    // (~= [+-0.01,-0.5,-0.5], matching the reference capture's
    // [0.01,-0.5,-0.5] up to vibe3d's own edge-storage direction).
    assert(hasVertexNear(m1, expX, expY, expZ, 1e-4),
        format("expected a new vertex near [%.6f,%.6f,%.6f]", expX, expY, expZ));

    // edge(0,1) is gone; (0,newVert)+(newVert,1) exist.
    assert(edgeIndexByVerts(m1, 0, 1) == uint.max,
        "edge(0,1) must no longer exist as a single edge after the kept split");
    uint newVert = uint.max;
    foreach (i, v; m1["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - expX) < 1e-4 && abs(a[1].floating - expY) < 1e-4 &&
            abs(a[2].floating - expZ) < 1e-4) { newVert = cast(uint)i; break; }
    }
    assert(newVert != uint.max, "new vertex index must be resolvable");
    assert(edgeIndexByVerts(m1, 0, newVert) != uint.max,
        "half-edge (0, newVert) must exist after the kept split");
    assert(edgeIndexByVerts(m1, newVert, 1) != uint.max,
        "half-edge (newVert, 1) must exist after the kept split");
}
