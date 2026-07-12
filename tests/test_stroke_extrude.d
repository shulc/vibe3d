// test_stroke_extrude.d — HTTP tests for the mesh.strokeExtrude command
// (task 0323 "Sketch Extrude" port, basic/captured scope).
//
// This is a golden fixture for the ONE geometry case the toolcard actually
// measured against a live reference gesture (see the private toolcard,
// task 0323 — not tracked here): a cube's top face, a straight vertical
// screen-space drag, default attrs (align=true) → +64 vertices, +64 faces
// (16 new quad bands). Reproducing the reference's exact screen-pixel
// camera-raycast mapping and the exact Precision→span-count law is an
// OPEN follow-up (the toolcard's own finding_3 — 16 spans measured vs a
// naive 6-span prediction at prec=30/180px) that is explicitly NOT
// resolved here; this test instead pins the KERNEL's topology for a
// caller-supplied 16-span WORLD-space path (mesh.strokeExtrude takes the
// path as an explicit param specifically so it is testable independently
// of that unresolved formula — see MeshStrokeExtrude's doc comment).
//
// TODO / not verified by this test (explicit task-0323 non-goals for this
// pass — flagged, not invented):
//   - curved / multi-direction path behaviour (only a straight path is
//     exercised here)
//   - the exact screen-Precision(px) -> span-count law
//   - Scale / Spin per-band modulation
//   - the reference's measured non-uniform per-band WORLD spacing (a
//     camera-perspective effect, not a kernel-level law)

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

void resetCube() {
    auto resp = post(BASE ~ "/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

JSONValue postJson(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postJson("/api/select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

JSONValue getModel() { return parseJSON(cast(string)get(BASE ~ "/api/model")); }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faces"].array.length; }

// ---------------------------------------------------------------------------
// Geometry helpers (local copies, matching test_face_extrude.d's pattern)
// ---------------------------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

// Every undirected edge used by at most 2 faces, and no directed half-edge
// repeated (no flipped / duplicated windings) — the same manifold contract
// test_face_extrude.d's isHoleFree checks.
bool isHoleFree(JSONValue m) {
    int[ulong] undirected;
    int[ulong] directed;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        auto n = idx.length;
        foreach (k; 0 .. n) {
            ulong a = cast(ulong)idx[k].integer;
            ulong b = cast(ulong)idx[(k + 1) % n].integer;
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi] += 1;
            directed[(a << 32) | b] += 1;
        }
    }
    foreach (v; undirected) if (v > 2) return false;
    foreach (v; directed)   if (v > 1) return false;
    return true;
}

// Index of the cube's top face (all 4 corners at y == +0.5) — same
// directional selector the toolcard's own capture harness used
// (`subset y gt 0.4`) to avoid the absgt bug that matched both the top
// and bottom face.
int findTopFaceIndex(JSONValue m) {
    foreach (i, f; m["faces"].array) {
        bool allTop = true;
        foreach (vi; f.array) {
            if (abs(vert(m, cast(size_t)vi.integer).y - 0.5) > 1e-6) { allTop = false; break; }
        }
        if (allTop) return cast(int)i;
    }
    return -1;
}

// Straight +Y world-space path JSON: 1 anchor + `spans` steps of `stepY`.
// The golden-case caller below uses spans=16 — the same span count the
// toolcard's one measured live gesture produced — fed directly as an
// explicit path so the kernel's topology can be pinned independently of
// the unresolved screen-Precision->span-count formula.
string buildStraightPathJson(int spans, double stepY) {
    string s = "[[0,0.5,0]";
    foreach (k; 1 .. spans + 1) {
        double y = 0.5 + stepY * cast(double)k;
        s ~= ",[0," ~ y.to!string ~ ",0]";
    }
    s ~= "]";
    return s;
}

// ---------------------------------------------------------------------------
// TEST 1: golden fixture — the ONE captured case's topology
//   cube top face, 16-span straight +Y path -> +64 verts, +64 faces.
// ---------------------------------------------------------------------------

unittest {
    resetCube();

    auto before = getModel();
    assert(faceCount(before) == 6, "BEFORE: expected 6 cube faces");
    assert(vertCount(before) == 8, "BEFORE: expected 8 cube verts");

    int topFi = findTopFaceIndex(before);
    assert(topFi >= 0, "top face not found on default cube");

    postSelect("polygons", [topFi]);

    string path = buildStraightPathJson(16, 0.1);
    auto r = postJson("/api/command",
        `{"id":"mesh.strokeExtrude","path":` ~ path ~ `,"alignToPath":true}`);
    assert(r["status"].str == "ok", "mesh.strokeExtrude failed: " ~ r.toString);

    auto after = getModel();
    assert(faceCount(after) == 6 + 64,
        "golden case: expected " ~ (6 + 64).to!string ~ " faces, got "
        ~ faceCount(after).to!string);
    assert(vertCount(after) == 8 + 64,
        "golden case: expected " ~ (8 + 64).to!string ~ " verts, got "
        ~ vertCount(after).to!string);

    assert(isHoleFree(after), "golden case: surface has winding/manifold errors");

    // Undo round-trip restores the original 6/8 cube topology.
    postJson("/api/command", `{"id":"history.undo"}`);
    auto undone = getModel();
    assert(faceCount(undone) == 6, "undo: expected 6 faces, got " ~ faceCount(undone).to!string);
    assert(vertCount(undone) == 8, "undo: expected 8 verts, got " ~ vertCount(undone).to!string);
}

// ---------------------------------------------------------------------------
// TEST 2: alignToPath=false smoke test. NOT a captured-law assertion — on a
// perfectly straight path every segment shares one tangent, so
// Mesh.extrudeAlongPath's align-to-path rotation is identity regardless
// (see the kernel's doc comment); this only proves the param round-trips
// and produces the same topology count on a straight path, not that the
// tilt behaviour itself is correct for a curved path (open TODO).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = findTopFaceIndex(before);
    assert(topFi >= 0, "top face not found on default cube");
    postSelect("polygons", [topFi]);

    string path = buildStraightPathJson(5, 0.2);
    auto r = postJson("/api/command",
        `{"id":"mesh.strokeExtrude","path":` ~ path ~ `,"alignToPath":false}`);
    assert(r["status"].str == "ok", "mesh.strokeExtrude (alignToPath=false) failed: " ~ r.toString);

    auto after = getModel();
    // 5 spans * 4 net faces/verts per band (single quad boundary).
    assert(faceCount(after) == 6 + 5 * 4,
        "alignToPath=false: expected " ~ (6 + 5 * 4).to!string ~ " faces, got "
        ~ faceCount(after).to!string);
    assert(isHoleFree(after), "alignToPath=false: surface has winding/manifold errors");
}

// ---------------------------------------------------------------------------
// TEST 3: rejection — no polygon selected -> error, mesh unchanged.
// (Reference precondition: "select a polygon, and then click the tool" —
// the command does not pick one for you.)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    long vertsBefore = vertCount(before);
    long facesBefore = faceCount(before);

    // Explicitly clear the selection (fresh reset already has none, but be
    // defensive against ordering with other tests in the same run).
    postSelect("polygons", []);

    string path = buildStraightPathJson(4, 0.1);
    auto r = postJson("/api/command",
        `{"id":"mesh.strokeExtrude","path":` ~ path ~ `}`);
    assert(r["status"].str != "ok",
        "no-selection rejection: expected non-ok status, got " ~ r.toString);

    auto after = getModel();
    assert(vertCount(after) == vertsBefore, "no-selection rejection: vertex count must be unchanged");
    assert(faceCount(after) == facesBefore, "no-selection rejection: face count must be unchanged");
}

// ---------------------------------------------------------------------------
// TEST 4: rejection — path with fewer than 2 points -> error, mesh unchanged.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = findTopFaceIndex(before);
    postSelect("polygons", [topFi]);

    long vertsBefore = vertCount(getModel());
    long facesBefore = faceCount(getModel());

    auto r1 = postJson("/api/command", `{"id":"mesh.strokeExtrude","path":[]}`);
    assert(r1["status"].str != "ok", "empty-path rejection: expected non-ok status, got " ~ r1.toString);

    auto r2 = postJson("/api/command", `{"id":"mesh.strokeExtrude","path":[[0,0.5,0]]}`);
    assert(r2["status"].str != "ok", "single-point-path rejection: expected non-ok status, got " ~ r2.toString);

    auto after = getModel();
    assert(vertCount(after) == vertsBefore, "short-path rejection: vertex count must be unchanged");
    assert(faceCount(after) == facesBefore, "short-path rejection: face count must be unchanged");
}
