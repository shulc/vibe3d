// A REAL gizmo drag under morph routing (task 1069) — the only path that
// reaches `TransformTool.commitEdit` -> `buildMorphEditCmd`, the routed
// gesture's own undo record, and the only path on which `dragBaseline` exists
// at all.
//
// WHY THIS FILE IS SEPARATE FROM tests/test_morph_routing.d.  That file drives
// the numeric `tool.attr` + `tool.doApply` path, which is genuinely a
// different mechanism: `applyHeadless()` calls `applyTRS(mesh.vertices.dup)`
// with its OWN fresh baseline and never touches `dragBaseline`, and the whole
// apply is wrapped in `ToolDoApplyCommand`'s `MeshSnapshot` so undo there is a
// snapshot restore rather than the tool's commit. Two of this task's sharpest
// traps live ONLY on the drag path and are invisible to that file:
//
//   * writing the morphed run baseline into `dragBaseline` (gesture 2 then
//     double-counts gesture 1);
//   * a routed drag reaching the undo stack through nothing at all, because
//     `buildEditCmd` diffs two identical position arrays.
//
// The gizmo handle is not guessed: `/api/tool/handles` reports each part's
// screen position, and the synthesized event log presses exactly there.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.file   : remove, exists, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias kBase = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}
void runCmd(string id, string paramsJson) {
    auto j = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}
void resetCube() {
    auto j = postJson("/api/reset", "");
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}
void postSelect(string mode, int[] indices) {
    string idx = "[";
    foreach (i, v; indices) { if (i > 0) idx ~= ","; idx ~= v.to!string; }
    idx ~= "]";
    auto j = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idx ~ `}`));
    assert(j["status"].str == "ok", "/api/select failed: " ~ j.toString);
}
bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

void playAndWait(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events refused: " ~ r.toString);
    foreach (i; 0 .. 600) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) return;
        Thread.sleep(dur!"msecs"(50));
    }
    assert(false, "play-events did not finish within 30s");
}

private int g_seq = 0;
JSONValue saveAndReadMesh(string tag) {
    string path = format("/tmp/vibe3d-test-morphdrag-%s-%d.v3d", tag, g_seq++);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    return parseJSON(readText(path))["layers"][0]["mesh"];
}

struct MorphBlock {
    long[]   verts;
    double[] values;
    size_t entryCount() const { return verts.length; }
    bool valueOf(long vi, out double[3] v) const {
        foreach (k, w; verts) {
            if (w != vi) continue;
            v = [values[k * 3], values[k * 3 + 1], values[k * 3 + 2]];
            return true;
        }
        return false;
    }
}
MorphBlock morphOf(JSONValue meshJson, string name) {
    assert(("vertexMorphs" in meshJson) !is null,
        "mesh JSON carries no \"vertexMorphs\" key");
    foreach (m; meshJson["vertexMorphs"].array) {
        if (m["name"].str != name) continue;
        MorphBlock b;
        foreach (v; m["verts"].array)  b.verts  ~= v.integer;
        foreach (v; m["values"].array) b.values ~= v.floating;
        return b;
    }
    assert(false, "no morph map named '" ~ name ~ "'");
}
double[3][] allVerts(JSONValue meshJson) {
    double[3][] r;
    foreach (v; meshJson["vertices"].array) {
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}
void assertBaseUnmoved(JSONValue before, JSONValue after, string what) {
    auto a = allVerts(before), b = allVerts(after);
    assert(a.length == b.length, what ~ ": vertex count changed");
    foreach (i; 0 .. a.length)
        assert(approxEq(a[i][0], b[i][0]) && approxEq(a[i][1], b[i][1])
            && approxEq(a[i][2], b[i][2]),
            format("%s: vertex %d moved from (%.5f,%.5f,%.5f) to (%.5f,%.5f,%.5f)",
                   what, i, a[i][0], a[i][1], a[i][2], b[i][0], b[i][1], b[i][2]));
}

// --- the drag ------------------------------------------------------------

struct Handle { double x, y; }

/// The screen position the ACTIVE tool reports for gizmo part `part`, plus the
/// viewport rect. Read rather than guessed, so the press lands on the handle
/// whatever the camera happens to be.
Handle handlePos(int part, out int vx, out int vy, out int vw, out int vh) {
    auto j = getJson("/api/tool/handles")["handles"];
    auto vp = j["viewport"];
    vx = cast(int) vp["x"].integer;   vy = cast(int) vp["y"].integer;
    vw = cast(int) vp["width"].integer; vh = cast(int) vp["height"].integer;
    foreach (p; j["parts"].array) {
        if (cast(int) p["part"].integer != part) continue;
        assert(p["visible"].type == JSONType.true_,
            format("gizmo part %d is not visible -- the drag would miss it", part));
        auto sc = p["screen"].array;
        return Handle(sc[0].floating, sc[1].floating);
    }
    assert(false, format("gizmo reports no part %d", part));
}

/// Press on `h`, drag by (dx,dy) pixels in four steps, release. Coordinates
/// are absolute window pixels, which is what the event log carries.
void dragHandle(Handle h, int dx, int dy,
                int vx, int vy, int vw, int vh) {
    string log;
    void line(string s) { log ~= s ~ "\n"; }
    line(format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                vx, vy, vw, vh));
    const int x0 = cast(int) h.x, y0 = cast(int) h.y;
    line(format(`{"t":50.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                x0, y0));
    line(format(`{"t":100.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                x0, y0));
    double t = 150.0;
    int px = x0, py = y0;
    foreach (k; 1 .. 5) {
        const int nx = x0 + cast(int)(dx * k / 4.0);
        const int ny = y0 + cast(int)(dy * k / 4.0);
        line(format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`,
                    t, nx, ny, nx - px, ny - py));
        px = nx; py = ny; t += 50.0;
    }
    line(format(`{"t":%.1f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                t, px, py));
    playAndWait(log);
}

/// Labels currently on the undo stack.
string[] undoLabels() {
    string[] r;
    foreach (e; getJson("/api/history")["undo"].array) r ~= e["label"].str;
    return r;
}

// ==========================================================================

unittest { // A routed DRAG: the base does not move, the map receives the edit,
           // and the gesture lands on the undo stack as its OWN command.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [6]);
    cmd("tool.set move");

    auto before = saveAndReadMesh("pre");
    int vx, vy, vw, vh;
    auto h = handlePos(0, vx, vy, vw, vh);     // part 0 == the first axis arm
    dragHandle(h, 60, 0, vx, vy, vw, vh);

    auto after = saveAndReadMesh("dragged");
    assertBaseUnmoved(before, after,
        "a routed gizmo DRAG must leave every base vertex where it was");

    auto b = morphOf(after, "m");
    double[3] v;
    assert(b.valueOf(6, v),
        format("the dragged vertex must have a map entry -- %d entries total. "
             ~ "If this is 0 the drag missed the handle and every assertion "
             ~ "in this file is inert", b.entryCount));
    assert(fabs(v[0]) + fabs(v[1]) + fabs(v[2]) > 1e-3,
        format("the stored delta must be non-trivial, got (%.6f,%.6f,%.6f)",
               v[0], v[1], v[2]));

    // Drop the tool: that commits the session. The entry must be the ROUTED
    // command, not a vertex edit -- `MeshMorphEdit.label()` names its own
    // payload, so the label is the proof of which branch ran.
    cmd("tool.set move off");
    auto labels = undoLabels();
    bool sawMorphEdit = false;
    foreach (l; labels)
        if (l.length >= 13 && l[$ - 13 .. $] == "morph entries") sawMorphEdit = true;
    assert(sawMorphEdit,
        "the routed drag must record a MORPH edit on the undo stack. Without "
      ~ "its own command it records NOTHING: buildEditCmd diffs `mesh.vertices` "
      ~ "against the positions beginEdit captured, and under routing those are "
      ~ "identical. Stack was: " ~ labels.to!string);

    // ...and undoing it takes the ENTRY back out, without disturbing the base.
    cmd("history.undo");
    auto undone = saveAndReadMesh("undone");
    double[3] w;
    assert(!morphOf(undone, "m").valueOf(6, w),
        "undo of a routed drag must remove the entry, not merely zero it");
    assertBaseUnmoved(before, undone, "undo of a routed drag");
}

unittest { // TWO routed drags ACCUMULATE (law L7).
           //
           // This is the case that catches the run baseline being written into
           // `dragBaseline`: `applyTRS` restores `mesh.vertices` from
           // `dragBaseline` on every apply, and the routed kernel never
           // overwrites it, so a morphed `dragBaseline` (a) moves the BASE for
           // the whole gesture and (b) is re-captured by drag 2, which then
           // stacks its delta on an already-morphed base.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [6]);
    cmd("tool.set move");

    auto before = saveAndReadMesh("acc-pre");
    int vx, vy, vw, vh;
    auto h1 = handlePos(0, vx, vy, vw, vh);
    dragHandle(h1, 60, 0, vx, vy, vw, vh);

    auto mid = saveAndReadMesh("acc-mid");
    double[3] v1;
    assert(morphOf(mid, "m").valueOf(6, v1), "drag 1 wrote no entry");
    assertBaseUnmoved(before, mid, "after drag 1");

    // Second drag from the gizmo's CURRENT handle position.
    auto h2 = handlePos(0, vx, vy, vw, vh);
    dragHandle(h2, 60, 0, vx, vy, vw, vh);

    auto end = saveAndReadMesh("acc-end");
    double[3] v2;
    assert(morphOf(end, "m").valueOf(6, v2), "drag 2 wrote no entry");
    assertBaseUnmoved(before, end,
        "the base must STILL be untouched after two routed drags -- a "
      ~ "`dragBaseline` dirtied with the morphed run baseline moves it here");

    // Two equal drags along one axis: the second delta must be about TWICE the
    // first. Not exactly (the drag maps pixels through the live camera, and
    // the gizmo has moved), so the band is generous -- what it excludes is the
    // two failure modes: no accumulation at all (ratio ~1) and double-counting
    // (ratio ~3 or more).
    const double m1 = fabs(v1[0]) + fabs(v1[1]) + fabs(v1[2]);
    const double m2 = fabs(v2[0]) + fabs(v2[1]) + fabs(v2[2]);
    assert(m1 > 1e-3, "drag 1's delta is degenerate; the test would be inert");
    const double ratio = m2 / m1;
    assert(ratio > 1.5 && ratio < 2.6,
        format("two equal routed drags must ACCUMULATE: |d2|/|d1| == %.3f. "
             ~ "About 1.0 means the second gesture REPLACED the first (its run "
             ~ "baseline was read from the true base); 3.0 or more means the "
             ~ "morphed baseline was written back into `dragBaseline` and got "
             ~ "double-counted. d1=(%.4f,%.4f,%.4f) d2=(%.4f,%.4f,%.4f)",
               ratio, v1[0], v1[1], v1[2], v2[0], v2[1], v2[2]));
}

unittest { // CANCELLING a routed drag mid-session restores the MAP.
           //
           // The cancel path replays `editBefore` straight into
           // `mesh.vertices`, which is exactly why that array must keep holding
           // POSITIONS: with map deltas in it, a cancel would teleport every
           // moving vertex to near the origin and then publish the result. And
           // because the routed drag moved no position, restoring positions
           // alone leaves the edit in place -- so the map needs its own
           // restore, and an assertion on `mesh.vertices` alone cannot see
           // whether it happened.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.1,"y":0.0,"z":0.0}`);
    postSelect("vertices", [6]);
    cmd("tool.set move");

    auto before = saveAndReadMesh("cancel-pre");
    double[3] v0;
    assert(morphOf(before, "m").valueOf(6, v0));

    int vx, vy, vw, vh;
    auto h = handlePos(0, vx, vy, vw, vh);
    dragHandle(h, 60, 0, vx, vy, vw, vh);

    auto dragged = saveAndReadMesh("cancel-dragged");
    double[3] vd;
    assert(morphOf(dragged, "m").valueOf(6, vd));
    assert(fabs(vd[0] - v0[0]) + fabs(vd[1] - v0[1]) + fabs(vd[2] - v0[2]) > 1e-3,
        "the drag must actually have changed the stored value, or the cancel "
      ~ "below has nothing to undo and this test is inert");

    // Ctrl+Z with the session still open cancels the uncommitted edit rather
    // than popping a committed entry.
    cmd("history.undo");
    auto cancelled = saveAndReadMesh("cancel-done");
    double[3] vc;
    assert(morphOf(cancelled, "m").valueOf(6, vc),
        "the pre-gesture entry must still exist after a cancel");
    assert(approxEq(vc[0], v0[0]) && approxEq(vc[1], v0[1]) && approxEq(vc[2], v0[2]),
        format("a cancelled routed drag must restore the MAP to its "
             ~ "pre-gesture value: got (%.5f,%.5f,%.5f) want (%.5f,%.5f,%.5f)",
               vc[0], vc[1], vc[2], v0[0], v0[1], v0[2]));
    assertBaseUnmoved(before, cancelled, "a cancelled routed drag");
    cmd("tool.set move off");
}
