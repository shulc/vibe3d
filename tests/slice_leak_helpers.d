module slice_leak_helpers;

// Shared rig for the slice-tool live-edit leak witnesses (task 7111):
// tests/test_edge_slice_subpatch_chain_leak.d, test_edge_slice_undo_delete_revert.d,
// test_edge_slice_undo_buildloops.d, test_slice_tool_switch_records.d,
// test_slice_tool_ctrlz_live.d and test_loop_slice_subpatch_session_key.d.
//
// One prologue for all of them, so every file drives the same history: a cube,
// the top face lifted by a real Move-gizmo drag (a tool gesture, not a
// command), a delete, then optionally Tab (subpatch ON). Every gesture goes
// through /api/play-events (real SDL events); only selection and deletion use
// /api/command. The prologue records the mesh BEFORE each history record so a
// test can compare an undo step against the state that record replaced.
//
// Nothing here asserts a slice-tool outcome; the witnesses own their red
// lines. The asserts below are floors on the rig itself (the gesture landed,
// the picker resolved the named edge), each with its own message.

import http_client : getJson, postRaw;
import drag_helpers : Vec3, Viewport, CameraState, fetchCamera,
    viewportFromCamera, projectToWindow;
import std.algorithm : canFind, count, map, sort, min, max;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, sqrt, round;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;

enum SL_SDLK_TAB = 9;
enum SL_SDLK_c = 99;
enum SL_SDLK_w = 119;
enum SL_SDLK_z = 122;
enum SL_KMOD_LSHIFT = 1;
enum SL_KMOD_LCTRL = 64;

// ---------------------------------------------------------------------------
// transport
// ---------------------------------------------------------------------------

JSONValue slPost(string path, string body_) {
    return parseJSON(postRaw(path, body_));
}

void slCmd(string id, string params = null) {
    const body_ = params.length ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
                                : `{"id":"` ~ id ~ `"}`;
    auto r = slPost("/api/command", body_);
    assert(r["status"].str == "ok", "rig command " ~ id ~ " failed: " ~ r.toString);
}

/// An argstring line (`tool.set move`) through the script door.
void slLine(string line) {
    auto r = slPost("/api/command", line);
    assert(r["status"].str == "ok", "rig line `" ~ line ~ "` failed: " ~ r.toString);
}

bool slAlive() {
    try {
        auto j = getJson("/api/ping");
        return j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

string slHeader() {
    auto c = fetchCamera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                  c.vpX, c.vpY, c.width, c.height);
}

/// Play one event log (the viewport header is prepended) and wait for it.
/// Returns false instead of throwing when the editor stops answering, so a
/// crash witness can name the step that killed it.
bool slPlayTolerant(string events, string what) {
    try {
        auto r = slPost("/api/play-events", slHeader() ~ "\n" ~ events);
        assert(r["status"].str == "success",
               "play-events (" ~ what ~ ") refused: " ~ r.toString);
        foreach (_; 0 .. 400) {
            auto s = getJson("/api/play-events/status");
            if (s["finished"].type == JSONType.true_) {
                Thread.sleep(150.msecs);   // post-playback drain settle
                return true;
            }
            Thread.sleep(25.msecs);
        }
    } catch (Exception) {
        return false;
    }
    assert(false, "play-events (" ~ what ~ ") did not finish within 10 s");
}

void slPlay(string events, string what) {
    assert(slPlayTolerant(events, what),
           "the editor stopped answering while playing " ~ what);
}

string slMotion(double t, int x, int y, int state) {
    return format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  t, x, y, state);
}

string slButton(double t, bool down, int btn, int x, int y) {
    return format(`{"t":%.1f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP", btn, x, y);
}

bool slKeyTolerant(int sym, int mod, string what) {
    return slPlayTolerant(format(
        `{"t":20.0,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n" ~
        `{"t":30.0,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        sym, mod, sym, mod), what);
}

void slKey(int sym, int mod, string what) {
    assert(slKeyTolerant(sym, mod, what),
           "the editor stopped answering on key " ~ what);
}

void slHover(int x, int y) {
    slPlay(slMotion(20, x, y, 0) ~ "\n" ~ slMotion(40, x, y, 0), "hover");
}

/// Segment "click k": hover the pixel, press LMB — and nothing else.
void slClickDown(int x, int y, string what) {
    slPlay(slMotion(20, x, y, 0) ~ "\n" ~ slMotion(40, x, y, 0) ~ "\n"
         ~ slButton(60, true, 1, x, y), what);
}

/// Segment "drag k": `n` held motions of (dx, dy) each, then LMB up.
void slDragUp(int x, int y, int dx, int dy, int n, string what) {
    string log;
    foreach (i; 1 .. n + 1)
        log ~= slMotion(20 + 40 * i, x + dx * i, y + dy * i, 1) ~ "\n";
    log ~= slButton(40 + 40 * n, false, 1, x + dx * n, y + dy * n);
    slPlay(log, what);
}

/// A whole LMB drag (press, `n` held motions, release) in one log.
void slFullDrag(int x0, int y0, int x1, int y1, int n, string what) {
    string log = slMotion(20, x0, y0, 0) ~ "\n" ~ slButton(50, true, 1, x0, y0) ~ "\n";
    foreach (i; 1 .. n + 1)
        log ~= slMotion(50 + 50 * i, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, 1) ~ "\n";
    log ~= slButton(100 + 50 * n, false, 1, x1, y1);
    slPlay(log, what);
}

void slRmb(int x, int y) {
    slPlay(slMotion(20, x, y, 0) ~ "\n" ~ slButton(40, true, 3, x, y) ~ "\n"
         ~ slButton(60, false, 3, x, y), "RMB");
}

// ---------------------------------------------------------------------------
// state reads
// ---------------------------------------------------------------------------

string[] slHistoryLabels() {
    string[] r;
    foreach (e; getJson("/api/history")["undo"].array) r ~= e["label"].str;
    return r;
}

long slHistoryLen() { return cast(long)getJson("/api/history")["undo"].array.length; }

/// The mesh as a comparable value: positions (index-aligned) plus faces,
/// each rotated to its smallest index (winding kept) and tagged with its
/// subpatch flag, as a sorted multiset.
struct SlMesh {
    long verts, faces, maxFaceVert;
    string canon;
    string toString() const {
        return format("(verts %d, faces %d, maxFaceVertexIndex %d)", verts, faces, maxFaceVert);
    }
}

SlMesh slMesh() {
    auto m = getJson("/api/model");
    SlMesh r;
    r.verts = m["vertexCount"].integer;
    r.faces = cast(long)m["faces"].array.length;
    r.maxFaceVert = -1;
    string[] vs;
    foreach (v; m["vertices"].array)
        vs ~= format("%.4f,%.4f,%.4f", v.array[0].floating, v.array[1].floating,
                     v.array[2].floating);
    auto flags = m["isSubpatch"].array;
    string[] fs;
    foreach (fi, f; m["faces"].array) {
        long[] idx;
        foreach (c; f.array) { idx ~= c.integer; r.maxFaceVert = max(r.maxFaceVert, c.integer); }
        size_t lo = 0;
        foreach (i; 0 .. idx.length) if (idx[i] < idx[lo]) lo = i;
        string s;
        foreach (i; 0 .. idx.length) s ~= idx[(lo + i) % idx.length].to!string ~ ".";
        if (fi < flags.length && flags[fi].type == JSONType.true_) s ~= "s";
        fs ~= s;
    }
    sort(fs);
    r.canon = vs.join(";") ~ "|" ~ fs.join(";");
    return r;
}

struct SlChain {
    string tool;
    string phase;
    long[2][] pairs;
}

SlChain slChain() {
    auto s = getJson("/api/tool/state");
    SlChain c;
    if ("tool" in s.object) c.tool = s["tool"].str;
    if ("phase" in s.object) c.phase = s["phase"].str;
    if ("latchedPairs" in s.object)
        foreach (p; s["latchedPairs"].array)
            c.pairs ~= [p.array[0].integer, p.array[1].integer];
    return c;
}

string slTool() {
    auto s = getJson("/api/tool/state");
    return ("tool" in s.object) ? s["tool"].str : "";
}

/// Order matters, a pair's orientation does not: both sides go to (min, max).
long[2][] slNorm(const long[2][] ps) {
    long[2][] r;
    foreach (p; ps) r ~= [min(p[0], p[1]), max(p[0], p[1])];
    return r;
}

string slPairsStr(const long[2][] ps) {
    return "[" ~ ps.map!(p => format("[%d,%d]", p[0], p[1])).join(",") ~ "]";
}

// ---------------------------------------------------------------------------
// geometry lookup (by position, never by a remembered index)
// ---------------------------------------------------------------------------

/// The vertex at (x, z) with the sign of y given by `top` (the prologue lifts
/// the top face, so its y is no longer 0.5).
int slCornerVert(JSONValue m, double x, bool top, double z) {
    foreach (i, v; m["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - x) < 1e-4 && abs(a[2].floating - z) < 1e-4
                && ((a[1].floating > 0) == top))
            return cast(int)i;
    }
    return -1;
}

int slEdgeOf(JSONValue m, long a, long b) {
    foreach (i, e; m["edges"].array) {
        auto x = e.array[0].integer, y = e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

/// The face whose every vertex has `axis` coordinate on the side `sign`.
int slFaceOnSide(JSONValue m, int axis, double sign) {
    auto vs = m["vertices"].array;
    foreach (fi, f; m["faces"].array) {
        bool all = true;
        foreach (c; f.array)
            if (!(vs[cast(size_t)c.integer].array[axis].floating * sign > 0.49)) { all = false; break; }
        if (all) return cast(int)fi;
    }
    return -1;
}

/// A pixel over which the edge picker resolves edge (a, b) of the CURRENT
/// mesh. Tries `hint` first (measured on the default camera), then walks the
/// edge's screen normal. The hover it confirms is the input floor for a
/// click: no click is sent at a pixel that did not resolve the named edge.
int[2] slEdgePixel(long a, long b, int[2] hint, string what) {
    auto m = getJson("/api/model");
    const e = slEdgeOf(m, a, b);
    assert(e >= 0, format("slice rig: edge (%d,%d) does not exist for %s", a, b, what));
    bool hits(int x, int y) {
        slHover(x, y);
        return getJson("/api/tool/state")["hoveredEdge"].integer == e;
    }
    if (hits(hint[0], hint[1])) return hint;
    auto vp = viewportFromCamera(fetchCamera());
    auto va = m["vertices"].array[cast(size_t)a].array, vb = m["vertices"].array[cast(size_t)b].array;
    float ax, ay, bx, by;
    projectToWindow(Vec3(va[0].floating, va[1].floating, va[2].floating), vp, ax, ay);
    projectToWindow(Vec3(vb[0].floating, vb[1].floating, vb[2].floating), vp, bx, by);
    const dx = bx - ax, dy = by - ay, len = sqrt(dx * dx + dy * dy);
    const nx = -dy / len, ny = dx / len;
    foreach (t; [0.5, 0.4, 0.6])
        foreach (step; 0 .. 41) {
            const off = (step % 2 ? 1 : -1) * 3.0 * ((step + 1) / 2);
            const x = cast(int)round(ax + dx * t + nx * off);
            const y = cast(int)round(ay + dy * t + ny * off);
            if (hits(x, y)) return [x, y];
        }
    assert(false, format("slice pick floor: no pixel hovers edge (%d,%d) for %s", a, b, what));
}

// ---------------------------------------------------------------------------
// the prologue
// ---------------------------------------------------------------------------

struct SlPrologue {
    string[] labels;       // history labels, in record order
    SlMesh[] meshBefore;   // mesh BEFORE each record (index-aligned with labels)
    long historyLen;       // == labels.length
}

private void slStep(ref SlPrologue p, void delegate() step) {
    const before = slMesh();
    const n0 = slHistoryLabels().length;
    step();
    auto labels = slHistoryLabels();
    assert(labels.length >= n0, "slice rig: a prologue step shortened the history");
    foreach (l; labels[n0 .. $]) { p.labels ~= l; p.meshBefore ~= before; }
    p.historyLen = cast(long)p.labels.length;
    assert(labels.length == p.labels.length, "slice rig: history and the recorded labels diverged");
}

void slWaitSubpatchSettled(long buildsBefore) {
    foreach (_; 0 .. 1_500) {
        auto j = getJson("/api/subpatch/preview");
        if (j["builds"].integer > buildsBefore && j["pending"].type != JSONType.true_) return;
        Thread.sleep(20.msecs);
    }
    assert(false, "slice rig: subpatch preview did not settle within 30 s");
}

/// scene.reset + history.clear; lift the top face with a 5-increment Move
/// Y-arrow drag; select what `deleteSel` names (read on the lifted cube) in
/// `deleteMode` and delete; optionally
/// switch to edge selection mode; optionally Tab (subpatch ON) and wait for
/// the preview. Returns the recorded history.
SlPrologue slPrologue(bool subpatchOn, string deleteMode, int[] function() deleteSel,
                       bool edgeMode) {
    SlPrologue p;
    slCmd("scene.reset");
    slCmd("history.clear");
    assert(slHistoryLen() == 0, "slice rig: history.clear left records behind");
    const cube = slMesh();
    assert(cube.verts == 8 && cube.faces == 6, "slice rig: reset is not the 8v/6f cube");

    auto m0 = getJson("/api/model");
    const top = slFaceOnSide(m0, 1, 1.0);
    assert(top >= 0, "slice rig: no top face on the reset cube");
    slStep(p, () { slCmd("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, top)); });
    slStep(p, () { slLine("tool.set move"); });

    // The Move gesture: grab the Y arrow (handle part 1) 70% of the way from
    // the centre handle (part 3) to its tip and drag 5 increments up.
    auto parts = getJson("/api/tool/handles")["handles"]["parts"].array;
    double[2] tip, centre;
    int found;
    foreach (q; parts) {
        const id = q["part"].integer;
        if (q["screen"].type == JSONType.null_) continue;
        auto s = q["screen"].array;
        if (id == 1) { tip = [s[0].floating, s[1].floating]; ++found; }
        if (id == 3) { centre = [s[0].floating, s[1].floating]; ++found; }
    }
    assert(found == 2 && tip[1] < centre[1] - 20,
           "slice rig: the Move Y arrow (part 1 above part 3) is not on screen");
    const gx = cast(int)round(centre[0] + 0.7 * (tip[0] - centre[0]));
    const gy = cast(int)round(centre[1] + 0.7 * (tip[1] - centre[1]));
    slStep(p, () { slFullDrag(gx, gy, gx, gy - 40, 5, "the Move Y-arrow drag"); });
    auto lifted = getJson("/api/model");
    foreach (v; lifted["vertices"].array)
        assert(v.array[1].floating < 0 || v.array[1].floating > 0.5 + 1e-3,
               "slice rig: the Move drag did not lift the top face: " ~ v.toString);
    slStep(p, () { slLine("tool.set move off"); });

    const deleteIdx = deleteSel();   // resolved on the lifted cube, by position
    slStep(p, () {
        slCmd("mesh.select", format(`{"mode":"%s","indices":%s}`, deleteMode, deleteIdx.to!string));
    });
    slStep(p, () { slCmd("mesh.delete"); });
    if (edgeMode)
        slStep(p, () { slCmd("mesh.select", `{"mode":"edges","indices":[]}`); });
    if (subpatchOn) {
        const b0 = getJson("/api/subpatch/preview")["builds"].integer;
        slStep(p, () { slKey(SL_SDLK_TAB, 0, "Tab (subpatch ON)"); });
        slWaitSubpatchSettled(b0);
        foreach (f; getJson("/api/model")["isSubpatch"].array)
            assert(f.type == JSONType.true_, "slice rig: Tab left a face without subpatch");
    }
    writeln("slice rig prologue (subpatch ", subpatchOn ? "ON" : "OFF", "): ",
            p.labels, " -> ", slMesh());
    return p;
}

/// Back (-Z) and left (-X) faces of the reset cube — two adjacent side faces,
/// neither the top: deleting them leaves every vertex on the remaining four.
int[] slBackAndLeft() {
    auto m = getJson("/api/model");
    const back = slFaceOnSide(m, 2, -1.0), left = slFaceOnSide(m, 0, -1.0);
    assert(back >= 0 && left >= 0, "slice rig: back/left faces not found");
    return [back, left];
}

/// The three chain edges on the front (+Z) and right (+X) faces, as vertex
/// pairs of the CURRENT mesh: front-left vertical, front-right vertical
/// (shared), right-back vertical. None is born of a cut.
long[2][] slFrontRightChain() {
    auto m = getJson("/api/model");
    long[2][] r;
    foreach (xz; [[-0.5, 0.5], [0.5, 0.5], [0.5, -0.5]]) {
        const lo = slCornerVert(m, xz[0], false, xz[1]);
        const hi = slCornerVert(m, xz[0], true, xz[1]);
        assert(lo >= 0 && hi >= 0 && slEdgeOf(m, lo, hi) >= 0,
               format("slice rig: vertical edge at x=%s z=%s not found", xz[0], xz[1]));
        r ~= [cast(long)lo, cast(long)hi];
    }
    return r;
}

/// The corner vertex (-0.5, -0.5, -0.5) of the lifted cube.
int[] slBackLeftBottomCorner() {
    const v = slCornerVert(getJson("/api/model"), -0.5, false, -0.5);
    assert(v >= 0, "slice rig: corner (-0.5,-0.5,-0.5) not found");
    return [v];
}

// ---------------------------------------------------------------------------
// the undo-crash witness body (items 21 and 23): one procedure, two prologues
// ---------------------------------------------------------------------------

struct SlStep {
    SlMesh mesh;
    size_t points;
    string tool;
    long historyLen;
    string toString() const {
        return format("{mesh %s, latched points %d, tool '%s', history %d}",
                      mesh.toString, points, tool, historyLen);
    }
}

SlStep slSnap() {
    auto c = slChain();
    return SlStep(slMesh(), c.pairs.length, c.tool, slHistoryLen());
}

/// Subpatch ON prologue (`deleteMode`/`deleteSel`), Edge Slice, three
/// click+drag points on the front/right verticals, then Ctrl+Z K times with
/// K = 3 + recordedHistoryLen, the editor's liveness read after every step.
/// Only once the loop has run whole does it compare each step against OUR
/// undo law (task 0321: a Ctrl+Z peels the last latched point while a chain
/// is live; the peel of the first point also ends the tool; then history
/// records are undone newest first).
void slUndoLawWitness(string deleteMode, int[] function() deleteSel,
                      long expectVerts, long expectFaces, int[2][3] hints) {
    auto pro = slPrologue(true, deleteMode, deleteSel, true);
    const base = slMesh();
    assert(base.verts == expectVerts && base.faces == expectFaces,
           format("slice floor: the prologue mesh is %s, expected %d verts / %d faces",
                  base.toString, expectVerts, expectFaces));
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    const recordedHistoryLen = slHistoryLen();
    assert(recordedHistoryLen == pro.historyLen && recordedHistoryLen > 0,
           "slice floor: the recorded history is not the prologue's");

    const P = slFrontRightChain();
    SlMesh afterDrag2;
    foreach (k; 0 .. 3) {
        const px = slEdgePixel(P[k][0], P[k][1], hints[k], format("point %d", k + 1));
        slClickDown(px[0], px[1], format("click %d", k + 1));
        slDragUp(px[0], px[1], 0, 4, 3, format("drag %d", k + 1));
        if (k == 1) afterDrag2 = slMesh();
    }
    const S0 = slSnap();
    assert(S0.mesh.faces > expectFaces,
           "slice floor: no cut on the mesh before the first Ctrl+Z: " ~ S0.toString);
    writeln("S0 (state before the first Ctrl+Z): ", S0.toString,
            " latchedPairs ", slPairsStr(slChain().pairs), " history ", slHistoryLabels());

    // Which step first reaches the prologue's Delete record, on two readings:
    // the chain as it actually stands now, and the three-point chain the input
    // described (the law).
    size_t deleteAt = size_t.max;
    foreach (i, l; pro.labels) if (l.length >= 6 && l[0 .. 6] == "Delete") deleteAt = i;
    assert(deleteAt != size_t.max, "slice floor: the prologue recorded no Delete");
    const after = pro.labels.length - 1 - deleteAt;
    const predictedNow = S0.points + after + 1;
    const predictedLaw = 3 + after + 1;
    writeln("the Delete record is reached at Ctrl+Z step ", predictedNow,
            " with the chain as it stands (", S0.points, " latched point(s)), step ",
            predictedLaw, " under the peel law");

    const K = 3 + recordedHistoryLen;
    SlStep[] snaps = [S0];
    size_t steps;
    foreach (k; 1 .. K + 1) {
        const ok = slKeyTolerant(SL_SDLK_z, SL_KMOD_LCTRL, format("Ctrl+Z step %d", k));
        assert(ok && slAlive(),
               format("editor died on undo step %d (state before: %s); the Delete record "
                      ~ "is step %d with the chain as it stood, %d under the peel law",
                      k, snaps[$ - 1].toString, predictedNow, predictedLaw));
        snaps ~= slSnap();
        ++steps;
    }
    assert(steps == K && slHistoryLen() == 0,
           format("undo loop ran %d of %d, history left %d", steps, K, slHistoryLen()));

    // The law table, reachable only by a live editor.
    bool meshIs(const SlMesh a, const SlMesh b) { return a.canon == b.canon; }
    foreach (k; 1 .. K + 1) {
        const s = snaps[k];
        bool okStep;
        if (k == 1)      okStep = s.points == 2 && meshIs(s.mesh, afterDrag2);
        else if (k == 2) okStep = s.points == 1 && meshIs(s.mesh, base);
        // Step 3 pops the session's FIRST gesture, which also ends the tool
        // (owner decision 2026-09-23, after the reference capture; it replaces
        // the plan's "tool stays active" for this step only).
        else if (k == 3) okStep = s.points == 0 && meshIs(s.mesh, base) && s.tool != "edgeSlice";
        else             okStep = meshIs(s.mesh, pro.meshBefore[cast(size_t)(recordedHistoryLen - (k - 3))]);
        assert(okStep, format("undo step %d: state differs from the peel/undo law: %s",
                              k, s.toString));
    }
}

// ---------------------------------------------------------------------------
// the Slice tool (Shift+C) line
// ---------------------------------------------------------------------------

/// Activate Slice with Shift+C through play-events and draw one line across
/// the open box (world x = 0, y from -0.6 to 0.6, projected through the live
/// camera). Returns the history length right after activation, before the
/// line.
long slSliceActivateAndDraw() {
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    assert(slTool() == "slice", "slice floor: Shift+C did not activate the Slice tool");
    const recorded = slHistoryLen();
    auto vp = viewportFromCamera(fetchCamera());
    float ax, ay, bx, by;
    assert(projectToWindow(Vec3(0, -0.6f, 0), vp, ax, ay)
           && projectToWindow(Vec3(0, 0.6f, 0), vp, bx, by),
           "slice rig: the slice line projects off screen");
    slFullDrag(cast(int)ax, cast(int)ay, cast(int)bx, cast(int)by, 10, "the Slice line");
    return recorded;
}
