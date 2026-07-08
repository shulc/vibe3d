// Tests for mesh.edge_slide — positional edge-slide deformer.
//
// Geometry contract (vibe3d-original, no cross-engine capture gate):
//   * Each endpoint of a selected edge slides linearly toward its rail
//     neighbour by fraction |t|; t = 0 is a no-op; t = ±1 lands on the
//     rail neighbour.
//   * On an equatorial loop of a segmented cube (clean 2-colouring) all
//     loop verts slide in the same direction; t and -t produce opposite
//     motion.
//   * An empty edge selection returns {"status":"error"}.
//   * A selected edge with no rail on the requested side returns
//     {"status":"ok"} with the vertex unchanged (graceful degradation).
//   * history.undo restores pre-slide positions.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs, sqrt;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void reset() { postJson("/api/reset", ""); }

struct V3 { double x, y, z; }

V3[] dumpVerts() {
    V3[] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= V3(a[0].floating, a[1].floating, a[2].floating);
    }
    return out_;
}

// edge as [a, b] vertex-index pair
long[2][] dumpEdges() {
    long[2][] out_;
    foreach (e; getJson("/api/model")["edges"].array) {
        auto a = e.array;
        out_ ~= [a[0].integer, a[1].integer];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

/// Build a segmented cube and return its vertex + edge arrays.
/// Uses `prim.cube segmentsX:2 segmentsY:2 segmentsZ:2 radius:0` so the
/// equatorial ring sits at y=0 with clean rail neighbours at y=±0.5.
void buildSegCube() {
    reset();
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
      ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
}

/// Find all edge indices in `edges` whose both endpoints have |y| < eps.
long[] equatorialEdgeIndices(const V3[] verts, const long[2][] edges,
                             double eps = 0.01)
{
    long[] out_;
    foreach (long ei, e; edges) {
        if (fabs(verts[e[0]].y) < eps && fabs(verts[e[1]].y) < eps)
            out_ ~= ei;
    }
    return out_;
}

/// Find the index of the vertex nearest to (x, y, z), or -1 if none is
/// within `eps`. Used to locate cube corners by coordinate rather than
/// hard-coding vertex indices that depend on the primitive generator's
/// internal ordering.
long findVertexNear(const V3[] verts, double x, double y, double z,
                    double eps = 1e-3)
{
    foreach (long i, v; verts)
        if (approxEq(v.x, x, eps) && approxEq(v.y, y, eps) && approxEq(v.z, z, eps))
            return i;
    return -1;
}

/// Find the edge index whose endpoints are exactly {a, b} (order-independent).
long edgeIndexOf(const long[2][] edges, long a, long b) {
    foreach (long ei, e; edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return ei;
    return -1;
}

double dist(V3 a, V3 b) {
    return sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2);
}

/// Select the given edge indices in edge mode.
void selectEdges(long[] indices) {
    cmd("select.typeFrom edge");
    // Build JSON array of indices.
    string arr = "[";
    foreach (i, idx; indices) {
        if (i > 0) arr ~= ",";
        arr ~= idx.to!string;
    }
    arr ~= "]";
    auto j = postJson("/api/select", `{"mode":"edges","indices":` ~ arr ~ `}`);
    assert(j["status"].str == "ok", "edge select failed: " ~ j.toString);
}

// ---------------------------------------------------------------------------

unittest { // empty edge selection → error status, no history entry
    reset();
    cmd("select.typeFrom edge");  // switch to edge mode, nothing selected
    auto j = postJson("/api/command", `{"id":"mesh.edge_slide","params":{"t":0.5}}`);
    assert(j["status"].str == "error",
        "empty selection must return error, got: " ~ j.toString);
}

unittest { // t=0 is a no-op: all vertices unchanged
    buildSegCube();
    auto before = dumpVerts();
    auto edges  = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);
    assert(eqEdges.length > 0, "equatorial edges must exist");
    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0");
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        assert(approxEq(before[i].x, after[i].x)
            && approxEq(before[i].y, after[i].y)
            && approxEq(before[i].z, after[i].z),
            format("t=0 must be identity, vert %d changed", i));
}

unittest { // equatorial loop slide: all loop verts move same direction + magnitude
    buildSegCube();
    auto before  = dumpVerts();
    auto edges   = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);
    assert(eqEdges.length == 8,
        "subdivided cube must have 8 equatorial edges, got "
        ~ eqEdges.length.to!string);

    // Collect loop vertex indices (endpoints at |y| < eps).
    bool[] isLoopVert = new bool[](before.length);
    foreach (ei; eqEdges) {
        isLoopVert[cast(size_t)edges[cast(size_t)ei][0]] = true;
        isLoopVert[cast(size_t)edges[cast(size_t)ei][1]] = true;
    }
    long loopVertCount = 0;
    foreach (f; isLoopVert) if (f) ++loopVertCount;
    assert(loopVertCount == 8,
        "subdivided cube must have 8 equatorial vertices, got "
        ~ loopVertCount.to!string);

    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0.4");
    auto after = dumpVerts();

    // All loop verts must have moved. Non-loop verts must be unchanged.
    double[] dyLoop;
    foreach (i; 0 .. before.length) {
        if (!isLoopVert[i]) {
            assert(approxEq(before[i].x, after[i].x)
                && approxEq(before[i].y, after[i].y)
                && approxEq(before[i].z, after[i].z),
                format("non-loop vert %d must be unchanged", i));
        } else {
            double dy = after[i].y - before[i].y;
            assert(!approxEq(dy, 0.0), format("loop vert %d must move", i));
            dyLoop ~= dy;
        }
    }

    // All ΔY must share the same sign (loop consistency).
    bool allPos = true, allNeg = true;
    foreach (d; dyLoop) {
        if (d <= 0) allPos = false;
        if (d >= 0) allNeg = false;
    }
    assert(allPos || allNeg,
        "all equatorial verts must slide in the same Y direction");

    // All |ΔY| must be equal (each rail is 0.5 units for a unit cube).
    double magRef = fabs(dyLoop[0]);
    foreach (d; dyLoop)
        assert(approxEq(fabs(d), magRef, 1e-4),
            "all equatorial verts must slide the same distance");

    // Expected rail distance = 0.5 (half the cube side); t=0.4 → |ΔY| = 0.2.
    assert(approxEq(magRef, 0.2, 1e-4),
        "expected |ΔY| = 0.2 (t=0.4 × rail distance 0.5), got "
        ~ magRef.to!string);
}

unittest { // t=+0.4 and t=-0.4 slide in opposite directions
    buildSegCube();
    auto before  = dumpVerts();
    auto edges   = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);

    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0.4");
    auto afterP = dumpVerts();

    buildSegCube();
    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:-0.4");
    auto afterN = dumpVerts();

    bool isLoop(size_t i) {
        return fabs(before[i].y) < 0.01;
    }

    foreach (i; 0 .. before.length) {
        if (!isLoop(i)) continue;
        double dyP = afterP[i].y - before[i].y;
        double dyN = afterN[i].y - before[i].y;
        assert((dyP > 0) != (dyN > 0),
            format("loop vert %d: t and -t must slide opposite Y directions", i));
    }
}

unittest { // t=1 lands exactly on rail neighbour
    buildSegCube();
    auto before  = dumpVerts();
    auto edges   = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);

    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:1");
    auto after = dumpVerts();

    foreach (i; 0 .. before.length) {
        if (fabs(before[i].y) > 0.01) continue;  // not a loop vert
        // After sliding t=1, the vert must coincide with one of its neighbours
        // at y = ±0.5.
        assert(approxEq(fabs(after[i].y), 0.5, 1e-4),
            format("loop vert %d at t=1 should be at |y|=0.5, got y=%f",
                   i, after[i].y));
    }
}

unittest { // history.undo restores pre-slide positions
    buildSegCube();
    auto before  = dumpVerts();
    auto edges   = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);

    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0.4");
    cmd("history.undo");
    auto after = dumpVerts();

    foreach (i; 0 .. before.length)
        assert(approxEq(before[i].x, after[i].x)
            && approxEq(before[i].y, after[i].y)
            && approxEq(before[i].z, after[i].z),
            format("undo must restore vert %d to pre-slide position", i));
}

unittest { // degraded: command returns ok with vertex unchanged when no rail on side
    // Plain (non-segmented) cube — top face edges have only one incident face
    // per vertex endpoint, so one side has no rail.
    reset();
    cmd("select.typeFrom edge");
    // Select the first edge (cube edge, 1 or 2 incident faces).
    auto j = postJson("/api/select", `{"mode":"edges","indices":[0]}`);
    assert(j["status"].str == "ok");

    auto before = dumpVerts();
    // mesh.edge_slide must not return error — even if no rail exists on
    // the requested side for all endpoints.
    auto resp = postJson("/api/command",
        `{"id":"mesh.edge_slide","params":{"t":0.5}}`);
    assert(resp["status"].str == "ok",
        "selected edge must return ok even when no rail on side: "
        ~ resp.toString);
}

unittest { // no-op slide undo must not truncate the undo stack (0099 regression)
    // Sequence: real slide → no-op slide (empty touchedIdx) → undo twice.
    //
    // With the bug (revert() returned false on empty touchedIdx):
    //   history.undo() received false → discarded the failed entry AND the entire
    //   trailing suffix → returned false → HistoryUndo.apply() threw → HTTP
    //   returned {"status":"error"} → the real slide's entry was silently gone.
    //
    // With the fix (revert() returns true on empty):
    //   the no-op undo is a successful no-op; the prior real slide entry survives
    //   on the undo stack; both undos return ok; mesh is fully restored.
    //
    // edgeSlidePositions() short-circuits at t==0 returning m.vertices.dup
    // unchanged (mesh.d:8995), so t=0 with any selection is a guaranteed
    // empty-touchedIdx trigger.
    buildSegCube();
    auto before  = dumpVerts();
    auto edges   = dumpEdges();
    auto eqEdges = equatorialEdgeIndices(before, edges);
    assert(eqEdges.length > 0);

    // (1) Real slide — touchedIdx non-empty, model undo entry pushed.
    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0.4");

    // (2) No-op slide — t=0 leaves all positions identical → touchedIdx empty.
    //     apply() still returns true and records a model history entry.
    selectEdges(eqEdges);
    cmd("mesh.edge_slide t:0");

    // (3) Undo the no-op.  With the bug this returned {"status":"error"} and
    //     truncated the stack; with the fix it must return {"status":"ok"}.
    auto j1 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j1["status"].str == "ok",
        "undo of no-op slide must return ok (0099 stack-truncation regression): "
        ~ j1.toString);

    // (4) Undo the real slide.  If the stack was truncated in step 3 this entry
    //     would be gone and the call would return noop or error instead of ok.
    auto j2 = postJson("/api/command", `{"id":"history.undo"}`);
    assert(j2["status"].str == "ok",
        "undo of real slide must return ok after no-op undo (prior entry truncated): "
        ~ j2.toString);

    // (5) Positions must be fully restored to pre-slide state.
    auto after = dumpVerts();
    foreach (i; 0 .. before.length)
        assert(approxEq(before[i].x, after[i].x)
            && approxEq(before[i].y, after[i].y)
            && approxEq(before[i].z, after[i].z),
            format("vert %d not restored after two undos (0099 stack-truncation regression)", i));
}

unittest { // task 0307 (fuzz-found): 3-of-4 quad edges selected must not
    // collapse the mutual-rail vertex pair at an ordinary t
    //
    // Plain (non-segmented) cube, corner face at y=-0.5 with corners at
    //   (-0.5,-0.5,-0.5), (0.5,-0.5,-0.5), (0.5,-0.5,0.5), (-0.5,-0.5,0.5)
    // Select 3 of that quad's 4 edges, leaving the edge between the two
    // "+z" corners unselected. Those two corners are then each other's
    // ONLY rail candidate — the buggy kernel slid both toward each other's
    // original position and they coincided exactly at t=0.5, degenerating
    // that quad AND its neighbour across the shared edge.
    reset();
    cmd("select.typeFrom edge");

    auto verts = dumpVerts();
    long vA = findVertexNear(verts, -0.5, -0.5, -0.5);
    long vB = findVertexNear(verts,  0.5, -0.5, -0.5);
    long vC = findVertexNear(verts, -0.5, -0.5,  0.5);
    long vD = findVertexNear(verts,  0.5, -0.5,  0.5);
    assert(vA >= 0 && vB >= 0 && vC >= 0 && vD >= 0,
        "expected 4 cube corners at y=-0.5 not found");

    auto edges = dumpEdges();
    long eAB = edgeIndexOf(edges, vA, vB);
    long eBD = edgeIndexOf(edges, vB, vD);
    long eAC = edgeIndexOf(edges, vA, vC);
    long eCD = edgeIndexOf(edges, vC, vD);
    assert(eAB >= 0 && eBD >= 0 && eAC >= 0 && eCD >= 0,
        "expected all 4 quad edges to exist");

    selectEdges([eAB, eBD, eAC]);   // 3 of 4; eCD (the mutual-rail edge) stays unselected
    cmd("mesh.edge_slide t:0.5");

    auto faces = getJson("/api/model")["faces"].array;
    auto after = dumpVerts();

    // Regression: the mutual-rail pair (C, D) must not coincide.
    assert(dist(after[vC], after[vD]) > 0.05,
        format("task 0307 regression: mutual-rail verts %d/%d collapsed "
             ~ "(dist=%f)", vC, vD, dist(after[vC], after[vD])));

    // No face may become degenerate: no two distinct vertex-index slots of
    // any face may resolve to (near-)coincident positions post-slide.
    foreach (fi, f; faces) {
        auto idx = f.array;
        foreach (ai; 0 .. idx.length)
            foreach (bi; ai + 1 .. idx.length) {
                auto va = after[cast(size_t) idx[ai].integer];
                auto vb = after[cast(size_t) idx[bi].integer];
                assert(dist(va, vb) > 1e-3,
                    format("task 0307 regression: face %d has coincident "
                         ~ "vertices after slide", fi));
            }
    }
}
