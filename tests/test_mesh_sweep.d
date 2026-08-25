// test_mesh_sweep.d — HTTP smoke tests for the mesh.sweep command.
//
// mesh.sweep revolves a selected edge profile (or polygon face) around a
// principal axis to produce a surface of revolution.
//
// Fixtures use prim.arc (faceless wire) via /api/reset?empty=true so the
// arc is the ONLY geometry — reset leaves no default cube, and prim.arc
// APPENDS to whatever is in the scene, so an empty-reset is required.
//
// Key invariants under test:
//   360° open-profile sweep:
//     faces   == segments * count
//     vertices == (segments+1) * count        (no seam dup)
//     all faces are quads
//     boundary edges == 2 * count             (two open rims)
//
//   Partial arc open-profile sweep:
//     faces == segments * (count-1)           (open-arc inclusive endpoints)
//
//   Closed-profile (polygon) sweep:
//     faces == sides * count                  (closed ring, no cap)
//
//   Rejection:
//     count < 2          → status == "error", mesh unchanged
//     empty edge sel     → status == "error", mesh unchanged
//
//   Undo round-trip:
//     history.undo restores pre-sweep vertex and face counts

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices)
        idxJson ~= (i > 0 ? "," : "") ~ v.to!string;
    idxJson ~= "]";
    auto r = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

long vertCount() { return model()["vertexCount"].integer; }
long faceCount() { return model()["faces"].array.length; }

// face-vertex-count histogram, e.g. {4: 24}.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// Count boundary edge incidences: edges appearing in only one face.
// (Built from the face list, so it works on any mesh JSON returned by /api/model.)
long boundaryEdgeCount(JSONValue m) {
    int[string] inc;
    foreach (f; m["faces"].array) {
        auto vs = f.array;
        foreach (k; 0 .. vs.length) {
            long a = vs[k].integer, b = vs[(k + 1) % vs.length].integer;
            if (a > b) { auto tmp = a; a = b; b = tmp; }
            string key = a.to!string ~ "_" ~ b.to!string;
            inc[key]++;
        }
    }
    long cnt = 0;
    foreach (v; inc.values) if (v == 1) cnt++;
    return cnt;
}

// Reset to empty mesh (no default cube), then build an arc with `segs` segments
// along the Y axis (axis=1).  Results in segs+1 verts and segs edges at indices
// 0 .. segs-1.
void buildArc(int segs) {
    postJson("/api/reset?empty=true", "");
    cmd(`{"id":"prim.arc","segments":` ~ segs.to!string ~ `,"axis":1}`);
}

// Build a 4-vert closed quad profile in the XZ plane via /api/load-mesh.
// The four verts sit at unit radius from the Y axis; the single quad face
// is at index 0.  Call setSelection("polygons",[0]) after to activate it.
void buildClosedQuadProfile() {
    // load-mesh replaces the current mesh entirely; no reset required, but
    // an explicit reset first keeps the mode clean.
    postJson("/api/reset?empty=true", "");
    auto r = postJson("/api/load-mesh", `{
        "vertices": [[1,0,0],[0,0,1],[-1,0,0],[0,0,-1]],
        "faces": [[0,1,2,3]]
    }`);
    assert(r["status"].str == "ok", "buildClosedQuadProfile /api/load-mesh failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// test 1: 360° sweep of open arc profile — tube of revolution
// ---------------------------------------------------------------------------

unittest {
    // Arc: 4 segments → 5 verts, 4 edges (indices 0..3).
    // Sweep 360° with count=6:
    //   faces   = 4 * 6 = 24
    //   vertices = 5 * 6 = 30   (no seam duplicate for 360° closed sweep)
    //   boundary edges = 2 * 6 = 12  (two open rims, each a hexagon)
    immutable int segs  = 4;
    immutable int count = 6;

    buildArc(segs);
    // Select all arc edges (indices 0..segs-1) in edge mode.
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    auto m = model();
    long wantFaces = segs * count;
    long wantVerts = (segs + 1) * count;
    long wantBdry  = 2 * count;

    assert(m["faces"].array.length == wantFaces,
        "360° sweep: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "360° sweep: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);

    // All faces must be quads.
    assert(fvDist(m).get(4, 0) == wantFaces,
        "360° sweep: all faces must be quads");

    // Two open rims (one per arc endpoint, each of length `count`).
    long bdry = boundaryEdgeCount(m);
    assert(bdry == wantBdry,
        "360° sweep: expected " ~ wantBdry.to!string ~ " boundary edges, got "
        ~ bdry.to!string);
}

// ---------------------------------------------------------------------------
// test 2: partial arc (90°) sweep — open patch, more boundary
// ---------------------------------------------------------------------------

unittest {
    // Arc: 4 segments.  Open 90° sweep with count=4:
    //   stepAngle = (π/2)/(count-1) — inclusive endpoints.
    //   faces   = segs * (count-1) = 4 * 3 = 12
    //   vertices = (segs+1) * count = 5 * 4 = 20
    immutable int segs  = 4;
    immutable int count = 4;

    buildArc(segs);
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":1.5707963}`);   // π/2

    auto m = model();
    long wantFaces = segs * (count - 1);
    long wantVerts = (segs + 1) * count;

    assert(m["faces"].array.length == wantFaces,
        "90° sweep: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "90° sweep: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(fvDist(m).get(4, 0) == wantFaces, "90° sweep: all faces must be quads");
}

// ---------------------------------------------------------------------------
// test 3: 360° sweep of a closed polygon profile (polygon mode)
// ---------------------------------------------------------------------------

unittest {
    // 4-vert closed quad profile at unit radius from Y axis (from /api/load-mesh).
    // Sweep 360° with count=8:
    //   faces    = 4 * 8 = 32  (closed profile → `count` bridge steps)
    //   vertices = 4 * 8 = 32  (no seam dup; closed sweep reuses ring[0])
    //   boundary = 0            (watertight toroid)
    immutable int sides = 4;
    immutable int count = 8;

    buildClosedQuadProfile();
    setSelection("polygons", [0]);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    auto m = model();
    long wantFaces = sides * count;
    long wantVerts = cast(long)(sides) * count;

    assert(m["faces"].array.length == wantFaces,
        "closed-profile 360°: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "closed-profile 360°: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(fvDist(m).get(4, 0) == wantFaces,
        "closed-profile 360°: all faces must be quads");

    // Watertight: no boundary edges.
    long bdry = boundaryEdgeCount(m);
    assert(bdry == 0,
        "closed-profile 360°: expected 0 boundary edges (watertight), got "
        ~ bdry.to!string);
}

// ---------------------------------------------------------------------------
// test 4: rejection — count < 2 → error, mesh unchanged
// ---------------------------------------------------------------------------

unittest {
    immutable int segs = 3;
    buildArc(segs);
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    long vertsBefore = vertCount();
    long facesBefore = faceCount();

    auto r = postJson("/api/command",
        `{"id":"mesh.sweep","count":1,"axis":"Y","angle":6.2831853}`);
    assert(r["status"].str != "ok",
        "count=1 rejection: expected non-ok status, got " ~ r.toString);

    assert(vertCount() == vertsBefore, "count=1 rejection: vertex count must be unchanged");
    assert(faceCount() == facesBefore, "count=1 rejection: face count must be unchanged");
}

// ---------------------------------------------------------------------------
// test 5: rejection — empty edge selection → error, mesh unchanged
// ---------------------------------------------------------------------------

unittest {
    buildArc(3);
    // Switch to edge mode but select NO edges.
    setSelection("edges", []);

    long vertsBefore = vertCount();
    long facesBefore = faceCount();

    auto r = postJson("/api/command",
        `{"id":"mesh.sweep","count":6,"axis":"Y","angle":6.2831853}`);
    assert(r["status"].str != "ok",
        "empty-sel rejection: expected non-ok status, got " ~ r.toString);

    assert(vertCount() == vertsBefore, "empty-sel rejection: vertex count must be unchanged");
    assert(faceCount() == facesBefore, "empty-sel rejection: face count must be unchanged");
}

// ---------------------------------------------------------------------------
// test 6: undo round-trip
// ---------------------------------------------------------------------------

unittest {
    immutable int segs  = 4;
    immutable int count = 5;

    buildArc(segs);
    long vertsBefore = vertCount();   // segs+1 = 5
    long facesBefore = faceCount();   // 0

    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    // Confirm sweep ran.
    assert(faceCount() > facesBefore, "undo test: sweep must produce faces");

    // Undo.
    cmd(`{"id":"history.undo"}`);

    assert(vertCount() == vertsBefore,
        "undo: expected " ~ vertsBefore.to!string ~ " verts, got "
        ~ vertCount().to!string);
    assert(faceCount() == facesBefore,
        "undo: expected " ~ facesBefore.to!string ~ " faces, got "
        ~ faceCount().to!string);
}

// ---------------------------------------------------------------------------
// test 7: the transitional batch inside `revolveProfileEx` is not NESTED
// (task 1903 Stage D3, review MAJOR-1).
//
// `revolveProfileEx` opens a `MeshEditBatch` of its OWN around the ring-bridging
// loop — but only on the CLOSED-profile arm, which is the only one that calls a
// Bridge kernel (`bridgeLoopsPaired`); see "WHY ONLY THAT ARM" in
// source/mesh_ops/revolve.d. That open is a documented debt, and it is only
// safe while it is the outermost batch: the moment a caller of
// `revolveProfileEx` opens one first, `changeBus.nestedBatchOpens` ticks, the
// inner `close()` stops stamping, and the block has to go.
//
// THE PROFILE MATTERS. This case uses the CLOSED quad profile deliberately —
// on an open (arc) profile no batch is opened at all after the D3 narrowing, so
// the same delta could not move whatever a caller did, and the check would be
// unfailable.
//
// WHY A DELTA HERE AND NOT THE `== 0` IN test_undo_tracker_delete.d: that one
// is a single end-of-test read of a process-cumulative counter, in a test that
// never runs `mesh.sweep` — and at `-j 8` it is a different process (review
// MAJOR-1, measured on the thicken twin).
//
// THE MUTATION THAT REDDENS IT: wrap the `revolveProfileEx` call in the
// `mesh.sweep` command (source/commands/mesh/sweep.d) in an
// `auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Geometry);` …
// `ed.close();` pair. Delta becomes 1 and this block reddens by name.
// ---------------------------------------------------------------------------

long busCounter(string key) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/changes"));
    return j[key].integer;
}

unittest { // mesh.sweep, closed profile: the kernel's ring batch is outermost
    immutable int sides = 4;
    immutable int count = 8;

    buildClosedQuadProfile();
    setSelection("polygons", [0]);

    immutable long nestedBefore = busCounter("nestedBatchOpens");
    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);
    immutable long nestedAfter = busCounter("nestedBatchOpens");

    assert(nestedAfter - nestedBefore == 0,
        "mesh.sweep (closed profile) moved changeBus.nestedBatchOpens by "
      ~ (nestedAfter - nestedBefore).to!string ~ ", expected 0. "
      ~ "`revolveProfileEx` opens a TRANSITIONAL batch around its closed-profile "
      ~ "ring loop (source/mesh_ops/revolve.d, \"TASK 1903 Stage D3 — A "
      ~ "TRANSITIONAL BATCH\"), which is only safe while it is the outermost "
      ~ "one. A caller has now opened a batch first, so that block must be "
      ~ "removed in the SAME change: `revolveProfileEx` takes a "
      ~ "`ref MeshEditBatch` from its callers and the transitional open goes "
      ~ "away. That removal is Stage E2 of doc/mesh_edit_seam_plan.md (the "
      ~ "revolve/sweep family conversion).");

    // Non-vacuity floor: the closed-profile sweep really ran, so the ring batch
    // really opened — a delta measured across a refused command proves nothing.
    auto m = model();
    assert(m["faces"].array.length == sides * count,
        "sweep nested-batch probe: expected " ~ (sides * count).to!string
      ~ " faces, got " ~ m["faces"].array.length.to!string
      ~ " — the command did not run, so the delta above was measured across "
      ~ "nothing");
}
