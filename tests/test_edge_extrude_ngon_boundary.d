// Test for mesh.edge_extrude (Mesh.extrudeEdgesByMask) ridge-vertex weld at
// extrude≈0 (mesh-robustness batch, fuzz-found).
//
// A standalone open n-gon (single face, open boundary loop) whose corners are
// all SHARED (>=2 selected boundary edges per corner, not free ends/chamfer)
// run through an overshoot `width` at `extrude=0` used to mint a coincident
// duplicate vertex at each original corner position: the "out-of-scope
// boundary topology" fallback (a shared corner on a boundary edge) references
// BOTH the original endpoint AND its ridge vertex as separate face corners,
// and Pass 1 always minted a NEW ridge vertex via addVertex(v + dir*extrude)
// even when extrude=0 (where dir*extrude is exactly the zero vector, so the
// new vertex coincides exactly with the original). Confirmed by a before-fix
// probe: a regular pentagon with all 5 boundary edges selected and
// extrude=0/width=0.3 produced V=15 (5 coincident duplicate pairs); after the
// fix (Pass 1 reuses the original vertex id at extrude≈0 instead of minting a
// new one), it produces V=10 with zero duplicate positions.
//
// The fix is gated strictly on `abs(extrude) < 1e-6f`, so it cannot affect
// any nonzero-extrude path — confirmed separately (dub build + full test
// suite) that test_edge_extrude.d / test_edge_extrude_tool.d /
// test_edge_extrude_crash.d (which pin 0311/0313/0317/0328 at nonzero
// extrude) are unaffected. A before-fix probe additionally confirmed the
// INTERIOR-edge extrude=0 cases (test_edge_extrude.d test 1's cube edge and
// test 2's grid edge (3,4), re-driven at extrude=0 instead of their
// canonical 0.2) are BYTE-IDENTICAL in vertex/face count before and after
// this fix (12v/10f and 14v/8f respectively, no duplicates either way) — the
// coincident-dup only ever survived for the shared-boundary-corner case
// exercised here, matching the plan's risk analysis.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : PI, cos, sin;

void main() {}

enum BASE = "http://localhost:8080";

string postRaw(string path, string body) {
    return cast(string)post(BASE ~ path, body);
}
JSONValue postJ(string path, string body) { return parseJSON(postRaw(path, body)); }
JSONValue getJ(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

void postLoadMesh(string body) {
    auto resp = postJ("/api/load-mesh", body);
    assert(resp["status"].str == "ok", "/api/load-mesh failed: " ~ resp.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = postJ("/api/select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(resp["status"].str == "ok", "/api/select failed: " ~ resp.toString);
}

JSONValue getModel() { return getJ("/api/model"); }

/// No two DISTINCT vertex indices sit within `eps` of each other — catches a
/// coincident duplicate that `assertManifoldClean` (same-index dup corners
/// only) would miss.
void assertNoCoincidentVerts(JSONValue model, double eps, string context) {
    auto vertices = model["vertices"].array;
    foreach (i; 0 .. vertices.length) {
        auto a = vertices[i].array;
        foreach (j; i + 1 .. vertices.length) {
            auto b = vertices[j].array;
            double dx = a[0].floating - b[0].floating;
            double dy = a[1].floating - b[1].floating;
            double dz = a[2].floating - b[2].floating;
            double d2 = dx*dx + dy*dy + dz*dz;
            assert(d2 > eps*eps,
                context ~ ": vertices " ~ i.to!string ~ " and " ~ j.to!string ~
                " are coincident (dist=" ~ (d2 < 0 ? 0.0 : d2).to!string ~ ")");
        }
    }
}

/// Every undirected edge used by at most 2 faces.
void assertEdgeManifold(JSONValue model, string context) {
    int[ulong] efCount;
    foreach (f; model["faces"].array) {
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

// A regular pentagon: single open-boundary face, every corner shared by
// exactly 2 boundary edges (a chain-joint / shared corner, not a free end).
string pentagonMeshJson() {
    string vertsJson = "[";
    foreach (k; 0 .. 5) {
        double ang = 2 * PI * k / 5 - PI / 2;
        if (k) vertsJson ~= ",";
        vertsJson ~= "[" ~ cos(ang).to!string ~ ",0," ~ sin(ang).to!string ~ "]";
    }
    vertsJson ~= "]";
    return `{"vertices":` ~ vertsJson ~ `,"faces":[[0,1,2,3,4]]}`;
}

unittest { // StandaloneOpenPentagonSharedCornerNoCoincidentDup
    postLoadMesh(pentagonMeshJson());

    auto before = getModel();
    assert(before["vertices"].array.length == 5, "BEFORE: expected 5 verts");
    assert(before["faces"].array.length == 1, "BEFORE: expected 1 face");

    // Select all 5 boundary edges — every corner is shared (2 selected edges).
    int[] allEdges;
    foreach (i; 0 .. before["edges"].array.length) allEdges ~= cast(int)i;
    postSelect("edges", allEdges);

    auto resp = postJ("/api/command",
        `{"id":"mesh.edge_extrude","params":{"extrude":0.0,"width":0.3}}`);
    assert(resp["status"].str == "ok", "mesh.edge_extrude failed: " ~ resp.toString);

    auto after = getModel();
    assertNoCoincidentVerts(after, 1e-4, "pentagon extrude=0 width=0.3");
    assertEdgeManifold(after, "pentagon extrude=0 width=0.3");

    // Exact topology confirmed by the before-fix/after-fix repro: 10 verts,
    // 6 faces (vs. 15 verts pre-fix, with 5 coincident duplicate pairs).
    assert(after["vertices"].array.length == 10,
        "pentagon extrude=0 width=0.3: expected 10 verts, got " ~
        after["vertices"].array.length.to!string);
    assert(after["faces"].array.length == 6,
        "pentagon extrude=0 width=0.3: expected 6 faces, got " ~
        after["faces"].array.length.to!string);
}
