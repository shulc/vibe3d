// Task 1054 Phase 3, step 10 — drive the INTERACTIVE arm, not just
// `applyHeadless` (doc/loop_slice_corner_plan.md §5 Phase 3, the closing
// note under the validation list). `rebuildCut()` (the standing preview
// writer, re-run on every attribute change while armed) and `applyHeadless`
// call the IDENTICAL kernel entry with the same-shaped argument
// (`restrictFor(armedSelFaces_)` vs `restrictFor(selectedFaceIndices())`),
// and `armedSelFaces_` is latched from the Phase-1 ordered accessor — so the
// instant Phase 3's kernel change merges, a live interactive arm with the
// option on ALREADY produces band geometry, before Phase 4 wires the
// overlay. Since every headless F1/F2 fixture drives `applyHeadless` only,
// nothing else in this task's test surface touches the `rebuildCut` call
// site — this file is that drive, on the two shapes the plan names:
//
//   1. A TURN case — corpus `L` (the flagship corner fixture: 38v/71e/35f).
//   2. A MULTI-CHAIN case — corpus `plus` (five cells, threading into more
//      than one chain: 40v/73e/35f).
//
// Both arm via a REAL synthetic LMB click (`/api/play-events`), the same
// `onMouseButtonDown` chokepoint an interactive user reaches — NOT
// `tool.doApply` (that is `applyHeadless`, already covered by
// test_fixture_loop_slice_band.d). Faces are selected by GEOMETRY (vertex-
// coordinate SET), never by index — vibe3d's own `prim.cube` numbers faces
// differently from the reference corpus these expected counts came from
// (see tests/unit/mesh_ops/loop_slice_test.d's `bandTestBasePolys` doc
// comment, and CLAUDE.md's Picking Strategy note).

import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : sqrt;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

enum BASE = "http://localhost:8080";
enum ARGSTRING = "prim.cube segmentsX:3 segmentsY:1 segmentsZ:3 sizeX:1 sizeY:1 sizeZ:1 sharp:true radius:0";

JSONValue postCmd(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}
JSONValue getJson(string path) { return parseJSON(cast(string) get(BASE ~ path)); }

void resetEmpty() {
    auto r = postCmd("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "/api/reset failed");
}
void cmd(string s) {
    auto r = postCmd("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}
JSONValue model() { return getJson("/api/model"); }
long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faceCount"].integer; }
long edgeCount(JSONValue m) { return m["edgeCount"].integer; }

struct V3 { double x, y, z; }
bool near(double a, double b) { return (a - b < 1e-4) && (b - a < 1e-4); }
bool near(V3 a, V3 b) { return near(a.x,b.x) && near(a.y,b.y) && near(a.z,b.z); }

V3[] faceCoords(JSONValue m, size_t fi) {
    auto V = m["vertices"].array;
    V3[] out_;
    foreach (vi; m["faces"].array[fi].array)
        out_ ~= V3(V[vi.integer].array[0].floating,
                    V[vi.integer].array[1].floating,
                    V[vi.integer].array[2].floating);
    return out_;
}

// Resolve a polygon by its corner-coordinate SET (any order) — the same
// engine-neutral match tests/fixture_helpers.d's `resolveCoords` performs
// over HTTP, reimplemented here since this file drives its own event-log
// arm rather than the `loop_slice`/`select` step vocabulary.
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
    assert(false, "resolveFace: no matching polygon in the built cube");
}

void postSelect(int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postCmd("/api/select", `{"mode":"polygons","indices":` ~ idxJson ~ `}`);
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

// A fixed viewport, same idiom as tests/test_loop_slice_ctrlz.d. Loop
// Slice's Polygons-mode arm is SELECTION-seeded (`activationSeeds()`), so
// the click pixel doesn't need to hover any particular element.
enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

void clickArm() {
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

// Arms the band-mode tool on `sel` (face corner-coordinate rings, in
// SELECTION order) and returns the ARMED (not committed) /api/model.
JSONValue armBand(V3[][] sel) {
    resetEmpty();
    cmd(ARGSTRING);
    auto m0 = model();
    int[] idx;
    foreach (spec; sel) idx ~= resolveFace(m0, spec);
    postSelect(idx);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool select 1");   // Slice Selected ON, BEFORE the arm click
    clickArm();

    auto st = getJson("/api/tool/state");
    assert(("tool" in st.object) !is null, "tool must still be active after arming");
    assert(st["armed"].type == JSONType.true_, "arm click must set armed_=true");
    assert(st["built"].type == JSONType.true_, "arm click must materialize the standing preview");
    return model();
}

unittest { // 1. TURN case — corpus `L`, the flagship corner selection.
    V3[][] sel = [
        [V3(-0.5,0.5,-0.5), V3(-0.5,0.5,-0.166667), V3(-0.166667,0.5,-0.166667), V3(-0.166667,0.5,-0.5)],
        [V3(-0.166667,0.5,-0.5), V3(-0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.5)],
        [V3(0.166667,0.5,-0.5), V3(0.166667,0.5,-0.166667), V3(0.5,0.5,-0.166667), V3(0.5,0.5,-0.5)],
        [V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,0.166667), V3(0.5,0.5,0.166667), V3(0.5,0.5,-0.166667)],
        [V3(0.166667,0.5,0.166667), V3(0.166667,0.5,0.5), V3(0.5,0.5,0.5), V3(0.5,0.5,0.166667)],
    ];
    auto armed = armBand(sel);
    assert(vertCount(armed) == 38,
        "L (armed): expected 38 verts, got " ~ vertCount(armed).to!string);
    assert(edgeCount(armed) == 71,
        "L (armed): expected 71 edges, got " ~ edgeCount(armed).to!string);
    assert(faceCount(armed) == 35,
        "L (armed): expected 35 faces, got " ~ faceCount(armed).to!string);
    // The turn's own corner triangle — reference-sourced (§2's histogram):
    // exactly one 3-gon among the armed preview's faces.
    long tris = 0;
    foreach (f; armed["faces"].array) if (f.array.length == 3) tris++;
    assert(tris == 1, "L (armed): expected exactly one corner triangle, got " ~ tris.to!string);
}

unittest { // 2. MULTI-CHAIN case — corpus `plus` (five cells threading into
    // more than one chain — §2's branch-coverage table names this shape).
    V3[][] sel = [
        [V3(-0.5,0.5,-0.166667), V3(-0.5,0.5,0.166667), V3(-0.166667,0.5,0.166667), V3(-0.166667,0.5,-0.166667)],
        [V3(-0.166667,0.5,-0.166667), V3(-0.166667,0.5,0.166667), V3(0.166667,0.5,0.166667), V3(0.166667,0.5,-0.166667)],
        [V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,0.166667), V3(0.5,0.5,0.166667), V3(0.5,0.5,-0.166667)],
        [V3(-0.166667,0.5,-0.5), V3(-0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.166667), V3(0.166667,0.5,-0.5)],
        [V3(-0.166667,0.5,0.166667), V3(-0.166667,0.5,0.5), V3(0.166667,0.5,0.5), V3(0.166667,0.5,0.166667)],
    ];
    auto armed = armBand(sel);
    assert(vertCount(armed) == 40,
        "plus (armed): expected 40 verts, got " ~ vertCount(armed).to!string);
    assert(edgeCount(armed) == 73,
        "plus (armed): expected 73 edges, got " ~ edgeCount(armed).to!string);
    assert(faceCount(armed) == 35,
        "plus (armed): expected 35 faces, got " ~ faceCount(armed).to!string);
}
