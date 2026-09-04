// Task 1054 Phase 4 -- the ring-PREVIEW overlay (`selectionRingPreviewMask`,
// consumed as `/api/tool/state`'s `selectionRing` field, task 0399) must
// describe the BAND, not the whole unrestricted ring belt, once band mode
// (`select` ON, Polygons, a non-empty face selection) is active.
//
// Before this fix, the overlay unconditionally unioned each of
// `activationSeeds()`'s seeds' FULL `loopSliceRingEdges` -- exactly what
// `select = off` cuts, and a DIFFERENT thing from what band mode (task 1054
// Phase 3, doc/loop_slice_corner_plan.md §3.1) actually cuts: band mode never
// collects a ring at all. So the old preview drew edges the cut would never
// touch and omitted edges it would (e.g. a turn's second cut edge, or -- for
// a lone/disjoint selection with no interior edge at all -- almost the whole
// mesh belt through an arbitrary seed instead of the two edges the walk
// actually resolves).
//
// P1 -- the TURN case (corpus `L`, same five-cell selection as
//       test_loop_slice_band_interactive.d): the band overlay marks EXACTLY
//       6 distinct edges (a 5-cell open chain touches k+1 = 6 distinct edges
//       by §3.2's shared-rail identity), and each marked edge's PRE-CUT
//       midpoint equals one of the 6 NEW vertices the committed cut actually
//       produces -- tying the preview directly to the real geometry, not to
//       a hand-derived count.
// P2 -- the LONE-SELECTION case (same non-quad-neighbour mesh as
//       test_loop_slice_band_arm_nonquad.d, one selected quad, no interior
//       edge at all -- `activationSeeds()`'s "any" fallback): the band
//       overlay marks EXACTLY 2 edges, the selected face's own OPPOSITE pair
//       (local edges 0 and n/2, per §1 step 3's "both < 0" rule for a
//       single-polygon chain) -- not the ~4-edge "any edge of the selected
//       face" set the old code would have unioned full rings from.
//
// Mutation (run and confirmed to redden both cases, see task log): revert
// `selectionRingPreviewMask` to the pre-1054-Phase-4 unconditional
// `activationSeeds()`-ring-union body. P1's marked-edge count changes (no
// longer 6, and no longer matching the committed new-vertex set). P2's
// marked-edge count changes (the "any" fallback returns ALL FOUR of face 0's
// edges, each unioned with its own FULL ring through a triangle flap and
// back around the rest of the mesh -- observed count 4, not 2, and includes
// edges nowhere near the actual 2 cut edges).

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.math    : sqrt;
import std.algorithm : sort, uniq, map;
import std.array    : array;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;
enum ARGSTRING = "prim.cube segmentsX:3 segmentsY:1 segmentsZ:3 sizeX:1 sizeY:1 sizeZ:1 sharp:true radius:0";

JSONValue postCmd(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}


void resetEmpty() {
    auto r = postCmd("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "/api/reset failed");
}
void resetScene() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
}
void cmd(string s) {
    auto r = postCmd("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}
void loadMesh(string body_) {
    auto r = postCmd("/api/command", commandBody("scene.loadMesh", body_));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}
JSONValue model() { return getJson("/api/model"); }

void postSelect(int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postCmd("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":` ~ idxJson ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void playAndSettle(string log) {
    auto r = postCmd("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "play-events replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, CLAUDE.md flake note)
}

enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    import std.format : format;
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

void clickArm() {
    import std.format : format;
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

int[] dedupSorted(JSONValue arr) {
    int[] xs;
    foreach (v; arr.array) xs ~= cast(int)v.integer;
    return xs.sort().uniq().array;
}

struct V3 { double x, y, z; }
bool near(double a, double b) { return (a - b < 1e-3) && (b - a < 1e-3); }
bool near(V3 a, V3 b) { return near(a.x,b.x) && near(a.y,b.y) && near(a.z,b.z); }
V3 mid(V3 a, V3 b) { return V3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2); }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

V3[] faceCoords(JSONValue m, size_t fi) {
    auto V = m["vertices"].array;
    V3[] out_;
    foreach (vi; m["faces"].array[fi].array)
        out_ ~= V3(V[vi.integer].array[0].floating,
                    V[vi.integer].array[1].floating,
                    V[vi.integer].array[2].floating);
    return out_;
}

// Same engine-neutral resolve-by-coordinate-set idiom as
// test_loop_slice_band_interactive.d -- vibe3d's own prim.cube face indices
// need not match any fixture's assumed layout.
int resolveFace(JSONValue m, V3[] want) {
    auto faces = m["faces"].array;
    outer: foreach (fi; 0 .. faces.length) {
        auto fc = faceCoords(m, fi);
        if (fc.length != want.length) continue;
        auto used = new bool[](fc.length);
        foreach (w; want) {
            bool found = false;
            foreach (k, c; fc) {
                if (used[k]) continue;
                if (near(c, w)) { used[k] = true; found = true; break; }
            }
            if (!found) continue outer;
        }
        return cast(int) fi;
    }
    assert(false, "resolveFace: no matching polygon in the built mesh");
}

unittest { // P1 -- TURN case: the band overlay's marked edges' midpoints
    // are EXACTLY the committed cut's 6 new vertices.
    resetEmpty();
    cmd(ARGSTRING);
    auto m0 = model();

    V3[][] sel = [
        [V3(-0.5,0.5,-0.5), V3(-0.5,0.5,-0.166667), V3(-0.166667,0.5,-0.166667), V3(-0.166667,0.5,-0.5)],
        [V3(-0.166667,0.5,-0.5), V3(-0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.5)],
        [V3(0.166667,0.5,-0.5), V3(0.166667,0.5,-0.166667), V3(0.5,0.5,-0.166667), V3(0.5,0.5,-0.5)],
        [V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,0.166667), V3(0.5,0.5,0.166667), V3(0.5,0.5,-0.166667)],
        [V3(0.166667,0.5,0.166667), V3(0.166667,0.5,0.5), V3(0.5,0.5,0.5), V3(0.5,0.5,0.166667)],
    ];
    int[] idx;
    foreach (spec; sel) idx ~= resolveFace(m0, spec);
    postSelect(idx);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");   // Slice Selected ON, before any click

    auto st = getJson("/api/tool/state");
    assert(st["armed"].type == JSONType.false_,
        "selection alone must not arm the tool (a click does)");
    int[] ring = dedupSorted(st["selectionRing"]);
    assert(ring.length == 6,
        "L turn: band overlay should mark exactly 6 edges (k+1 for a 5-cell "
        ~ "open chain, §3.2's shared-rail identity), got " ~ ring.length.to!string
        ~ ": " ~ ring.to!string);

    // Each marked edge's PRE-cut midpoint must be one of the 6 points the
    // real cut is about to create.
    V3[] previewMids;
    foreach (ei; ring) {
        auto e = m0["edges"].array[ei].array;
        previewMids ~= mid(vert(m0, e[0].integer), vert(m0, e[1].integer));
    }

    clickArm();
    auto armed = model();
    assert(armed["vertices"].array.length == 38,
        "L (armed): expected 38 verts, got " ~ armed["vertices"].array.length.to!string);

    V3[] newVerts;
    foreach (i; 32 .. armed["vertices"].array.length) newVerts ~= vert(armed, i);
    assert(newVerts.length == 6, "expected 6 new vertices");

    // Set-wise match, order-independent: every preview midpoint is one of
    // the new vertices, and every new vertex is claimed exactly once.
    auto claimed = new bool[](newVerts.length);
    foreach (pm; previewMids) {
        bool found = false;
        foreach (k, nv; newVerts) {
            if (claimed[k]) continue;
            if (near(pm, nv)) { claimed[k] = true; found = true; break; }
        }
        assert(found, "preview-mask edge midpoint " ~ pm.to!string
            ~ " does not match any of the cut's actual new vertices "
            ~ newVerts.to!string);
    }
    foreach (k, c; claimed)
        assert(c, "new vertex " ~ newVerts[k].to!string
            ~ " was not predicted by any band-overlay edge");
}

unittest { // P2 -- LONE-SELECTION case (no interior edge at all --
    // `activationSeeds()`'s fallback branch, §3.4): the band overlay marks
    // EXACTLY the selected face's own opposite edge pair, not an "any edge
    // of the selection, full ring" union.
    resetScene();   // whatever default scene -- overwritten by load-mesh
    loadMesh(`{"vertices":[
        [-1,0,-1],[1,0,-1],[1,0,1],[-1,0,1],
        [0,1,-2],[2,1,0],[0,1,2],[-2,1,0]
    ],"faces":[
        [0,1,2,3],
        [0,1,4],
        [1,2,5],
        [2,3,6],
        [3,0,7]
    ]}`);
    postSelect([0]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");

    auto st = getJson("/api/tool/state");
    int[] ring = dedupSorted(st["selectionRing"]);
    assert(ring.length == 2,
        "lone selection: band overlay should mark exactly 2 edges (the "
        ~ "single-polygon-chain 'both<0 -> edge 0 / n/2' rule), got "
        ~ ring.length.to!string ~ ": " ~ ring.to!string);

    auto m0 = model();
    auto e0 = m0["edges"].array[ring[0]].array;
    auto e1 = m0["edges"].array[ring[1]].array;
    V3 a0 = vert(m0, e0[0].integer), b0 = vert(m0, e0[1].integer);
    V3 a1 = vert(m0, e1[0].integer), b1 = vert(m0, e1[1].integer);
    // Face 0's own two OPPOSITE edges are (0,1)/(-1,0,-1)-(1,0,-1) and
    // (2,3)/(1,0,1)-(-1,0,1) -- the base quad's local edges 0 and 2 (n/2=2
    // for a quad). Assert the marked pair IS this pair (order-independent).
    V3 wantA0 = V3(-1,0,-1), wantB0 = V3(1,0,-1);
    V3 wantA1 = V3(1,0,1),   wantB1 = V3(-1,0,1);
    bool matchesDirect = (near(a0,wantA0) && near(b0,wantB0) && near(a1,wantA1) && near(b1,wantB1))
                       || (near(a1,wantA0) && near(b1,wantB0) && near(a0,wantA1) && near(b0,wantB1));
    assert(matchesDirect,
        "lone selection: the 2 marked edges should be face 0's own opposite "
        ~ "pair (local edges 0/2), got " ~ [a0,b0].to!string ~ " / " ~ [a1,b1].to!string);
}
