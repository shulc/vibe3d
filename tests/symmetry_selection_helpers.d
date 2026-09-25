module symmetry_selection_helpers;

// Shared rig and real-input drivers for the symmetry selection-time witnesses
// (tests/test_symmetry_selection_time.d, tests/test_symmetry_selection_doors.d;
// task 7143, the R half of wave slice S3b).
//
// The numbers come from the frozen capture tests/fixtures/symmetry_selection_time_laws.json
// (cells.<id>), never from a run. Fixture vertex keys are the CAPTURE's indices,
// which differ from ours for two cube vertices, so a keyed record is matched to
// our vertex BY ITS POSITION (`before`) and the match is cross-checked against
// the fixture's own `index_map` — a raw key is never read as one of our indices.
//
// Two kinds of assert, kept apart on purpose:
//   * a RIG FLOOR (`assert(..., "rig: ...")`) fails at once — the cell cannot
//     judge the law, so nothing after it would mean anything;
//   * a LAW CHECK (`law(ok, msg)`) is recorded and the file goes on, so one run
//     shows every law this tree breaks, each with its own message. The file
//     ends with `lawSummary`: first the population of law checks (a measured
//     literal), then one assert listing every red law check.
//
// The authoring-side floor (`sideFloor`) reads `authoringSide` from
// /api/toolpipe/eval before a numeric step that depends on it. A tree without
// that readout cannot run the floor; the floor then counts itself as ABSENT and
// `sideFloorSummary` — placed after `lawSummary` — requires every floor to have
// run, so the floor cannot stay silently skipped on a tree that has the law.

import http_client : frameFence, getJson, postJson, waitPlaybackProcessed,
    waitPreviewBuilt;
import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      CameraState, DHVec3 = Vec3;

import core.thread : Thread;
import core.time : msecs;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, round, isNaN;
import std.stdio : writeln, stdout;

alias V3 = double[3];

// --- fixture ----------------------------------------------------------------

JSONValue fixture() {
    __gshared JSONValue j;
    __gshared bool loaded;
    if (!loaded) {
        j = parseJSON(import("fixtures/symmetry_selection_time_laws.json"));
        loaded = true;
    }
    return j;
}

JSONValue cell(string id) {
    auto c = fixture()["cells"];
    assert(id in c.object, "rig: the fixture has no cell " ~ id);
    return c[id];
}

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : v.floating;
}

V3 vec(JSONValue a) {
    auto x = a.array;
    assert(x.length == 3, "rig: fixture vector is not 3 long: " ~ a.toString);
    return [num(x[0]), num(x[1]), num(x[2])];
}

string fmt(V3 v) { return format("(%.4f,%.4f,%.4f)", v[0], v[1], v[2]); }

bool near3(V3 a, V3 b, double eps = 1e-3) {
    foreach (k; 0 .. 3) if (!(abs(a[k] - b[k]) <= eps)) return false;
    return true;
}

// --- law ledger ---------------------------------------------------------------

__gshared string[] g_red;
__gshared int g_checks;
__gshared int g_sideFloorsRun, g_sideFloorsAbsent;

void law(bool ok, lazy string msg) {
    ++g_checks;
    if (ok) return;
    immutable string m = msg;
    g_red ~= m;
    writeln("[RED] ", m);
    stdout.flush();
}

/// The population of law checks first (a measured literal), then every red.
void lawSummary(string file, int expectChecks) {
    writeln(format("[%s] law checks %d, red %d; authoring-side floors ran %d, absent %d",
                   file, g_checks, g_red.length, g_sideFloorsRun, g_sideFloorsAbsent));
    stdout.flush();
    assert(g_checks == expectChecks,
        format("%s: law-check population changed: ran %d, expected %d", file, g_checks, expectChecks));
    assert(g_red.length == 0,
        format("%s: %d of %d law checks red:\n  %s", file, g_red.length, g_checks, g_red.join("\n  ")));
}

/// Every authoring-side floor ran (none absent) and the count is the measured one.
void sideFloorSummary(string file, int expectRun) {
    assert(g_sideFloorsAbsent == 0 && g_sideFloorsRun == expectRun,
        format("%s: authoring-side floors: %d ran, %d had no authoringSide readout, expected %d ran",
               file, g_sideFloorsRun, g_sideFloorsAbsent, expectRun));
}

/// Floor before a numeric step that depends on the authoring side A.
void sideFloor(int want, string where) {
    auto s = getJson("/api/toolpipe/eval")["symmetry"];
    if (s.type != JSONType.object || !("authoringSide" in s.object)) {
        ++g_sideFloorsAbsent;
        return;
    }
    ++g_sideFloorsRun;
    immutable long got = s["authoringSide"].integer;
    assert(got == want,
        format("rig: authoringSide %d before the numeric step, expected %d (%s)", got, want, where));
}

// --- commands -----------------------------------------------------------------

void cmd(string s) {
    auto r = postJson("/api/command", s);
    assert(r["status"].str == "ok", "rig: /api/command `" ~ s ~ "` failed: " ~ r.toString);
}

void settle(int ms = 120) { frameFence(); }

string intList(int[] ix) {
    string s = "[";
    foreach (i, v; ix) { if (i) s ~= ","; s ~= v.to!string; }
    return s ~ "]";
}

void selectVerts(int[] ix) {
    cmd(`{"id":"mesh.select","params":{"mode":"vertices","indices":` ~ intList(ix) ~ `}}`);
}

void selectEdges(int[] ix) {
    cmd(`{"id":"mesh.select","params":{"mode":"edges","indices":` ~ intList(ix) ~ `}}`);
}

int[] selV() {
    int[] r;
    foreach (v; getJson("/api/selection")["selectedVertices"].array) r ~= cast(int) v.integer;
    return r;
}

int[] selE() {
    int[] r;
    foreach (v; getJson("/api/selection")["selectedEdges"].array) r ~= cast(int) v.integer;
    return r;
}

int[] selF() {
    int[] r;
    foreach (v; getJson("/api/selection")["selectedFaces"].array) r ~= cast(int) v.integer;
    return r;
}

V3[] verts() {
    V3[] r;
    foreach (v; getJson("/api/model")["vertices"].array) r ~= vec(v);
    return r;
}

/// Our vertex at `p` — exactly one within 1e-5, or the rig is wrong.
int near(V3 p) {
    int found = -1, n = 0;
    foreach (i, v; verts())
        if (near3(v, p, 1e-5)) { found = cast(int) i; ++n; }
    assert(n == 1, format("rig: fixture vertex at %s matched %d of ours, expected 1", fmt(p), n));
    return found;
}

/// Our vertex for a fixture record keyed by a CAPTURE index `key`, matched by
/// its `before` position and cross-checked against the fixture's index_map.
int mapKey(string key, V3 before) {
    immutable int ours = near(before);
    auto im = fixture()["index_map"]["captured_index"];
    immutable string name = "v" ~ ours.to!string;
    if (name in im.object)
        assert(im[name].integer.to!string == key,
            format("rig: position map disagrees with index_map for %s (ours %s, index_map %s)",
                   key, name, im[name].toString));
    return ours;
}

/// Our vertex for a CAPTURE index that the fixture names only by index
/// (selection lists): through index_map, which must cover it.
int mapIndex(long captured) {
    foreach (name, v; fixture()["index_map"]["captured_index"].object)
        if (v.integer == captured) return name[1 .. $].to!int;
    // Outside the map the capture's cube index equals ours (index_map note).
    return cast(int) captured;
}

void symmetry(bool on) {
    cmd("tool.pipe.attr symmetry enabled " ~ (on ? "true" : "false"));
}

/// Fresh session (A unplaced), the 8-vertex cube, symmetry X OFF, vertex mode,
/// empty selection, empty history.
void rig() {
    cmd(`{"id":"scene.reset"}`);
    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr symmetry topology false");
    cmd("select.typeFrom vertex");
    selectVerts([]);
    cmd("history.clear");
    assert(verts().length == 8, "rig: the reset cube does not have 8 vertices");
    settle();
}

/// The ±0.5 cube with `sx` segments in X (and 1 in Y, Z), empty selection.
void cubeRig(int sx) {
    rig();
    selectVerts([0, 1, 2, 3, 4, 5, 6, 7]);
    cmd("mesh.delete");
    assert(verts().length == 0, "rig: the default cube was not cleared");
    cmd(format("prim.cube segmentsX:%d segmentsY:1 segmentsZ:1 radius:0", sx));
    selectVerts([]);
    cmd("history.clear");
    assert(verts().length == 4 * (sx + 1), format("rig: a %d-segment cube has %d vertices", sx, verts().length));
}

void meshTranslate(V3 d) {
    cmd(format(`{"id":"mesh.transform","params":{"kind":"translate","delta":[%.9g,%.9g,%.9g]}}`,
               d[0], d[1], d[2]));
}

/// `mesh.transform` rotate about the world origin (its default pivot); the
/// angle is in RADIANS on this door.
void meshRotateY(double degrees) {
    import std.math : PI;
    cmd(format(`{"id":"mesh.transform","params":{"kind":"rotate","axis":[0,1,0],"angle":%.12g}}`,
               degrees * PI / 180.0));
}

/// The tool door: arm, write attrs, apply once, drop.
void toolApply(string preset, string[] attrs, void delegate() afterArm = null) {
    cmd("tool.set " ~ preset ~ " on");
    if (afterArm !is null) afterArm();
    foreach (a; attrs) cmd("tool.attr " ~ preset ~ " " ~ a);
    cmd("tool.doApply");
    cmd("tool.set " ~ preset ~ " off");
}

void linearFalloff(V3 start, V3 end) {
    cmd("tool.pipe.attr falloff type linear");
    cmd(format(`tool.pipe.attr falloff start "%g,%g,%g"`, start[0], start[1], start[2]));
    cmd(format(`tool.pipe.attr falloff end "%g,%g,%g"`, end[0], end[1], end[2]));
    cmd("tool.pipe.attr falloff shape linear");
}

V3 acenCentre() { return vec(getJson("/api/toolpipe/eval")["actionCenter"]["center"]); }

/// "xfrm", "edgeExtend", or "" when nothing is armed.
string toolId() {
    auto s = getJson("/api/tool/state");
    return (s.type == JSONType.object && "tool" in s.object) ? s["tool"].str : "";
}

// --- real input ---------------------------------------------------------------

string vpLine() {
    auto c = fetchCamera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
                  ~ `{"t":0.000,"type":"PACE","mode":"frames"}` ~ "\n",
                  c.vpX, c.vpY, c.width, c.height);
}

void play(string events) {
    auto r = postJson("/api/play-events", vpLine() ~ events);
    assert(r["status"].str == "success", "rig: play-events failed: " ~ r.toString);
    waitPlaybackProcessed();
    waitPreviewBuilt();
}

int[2] px(V3 w) {
    auto vp = viewportFromCamera(fetchCamera());
    float fx, fy;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]), vp, fx, fy),
           "rig: point " ~ fmt(w) ~ " does not project");
    return [cast(int) round(fx), cast(int) round(fy)];
}

enum int KMOD_LSHIFT = 0x0001, KMOD_LCTRL = 0x0040;

void clickPx(int x, int y, int mod = 0, int clicks = 1, int btn = 1) {
    play(format(`{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}` ~ "\n"
              ~ `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":%d,"mod":%d}` ~ "\n"
              ~ `{"t":90.000,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":%d,"mod":%d}` ~ "\n",
                x, y, mod, btn, x, y, clicks, mod, btn, x, y, clicks, mod));
}

void click(V3 w, int mod = 0, int clicks = 1) { auto p = px(w); clickPx(p[0], p[1], mod, clicks); }

/// Hover, press, `n` motions of (dx,dy) with the button held, release — three
/// playbacks, so the press and every motion land in frames of their own.
void haulPx(int x, int y, int dx, int dy, int n, int mod = 0) {
    play(format(`{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}` ~ "\n"
              ~ `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
                x, y, mod, x, y, mod));
    string log;
    foreach (i; 1 .. n + 1)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%d}` ~ "\n",
                      50.0 * i, x + dx * i, y + dy * i, dx, dy, mod);
    play(log);
    play(format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
                x + dx * n, y + dy * n, mod));
}

void haul(V3 pressAt, int dx, int dy, int n, int mod = 0) {
    auto p = px(pressAt);
    haulPx(p[0], p[1], dx, dy, n, mod);
}

/// A right-button region gesture: a square of half-side `r` px around `w`.
void lasso(V3 w, int r = 30) {
    auto p = px(w);
    immutable int x = p[0], y = p[1];
    play(format(`{"t":100.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
              ~ `{"t":150.0,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
              ~ `{"t":200.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":4,"mod":0}` ~ "\n"
              ~ `{"t":250.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":%d,"state":4,"mod":0}` ~ "\n"
              ~ `{"t":270.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":4,"mod":0}` ~ "\n"
              ~ `{"t":300.0,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                x - r, y - r, x - r, y - r, x + r, y - r, 2 * r, x + r, y + r, 2 * r,
                x - r, y + r, -2 * r, x - r, y + r));
}

void tapKey(int sym, int mod = 0) {
    play(format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
              ~ `{"t":80.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
                sym, mod, sym, mod));
}

/// The armed tool's handle anchors on screen (empty when none is drawn).
double[2][] handlePixels() {
    double[2][] r;
    auto j = getJson("/api/tool/handles")["handles"];
    if (j.type == JSONType.null_) return r;
    foreach (p; j["parts"].array)
        if (p["screen"].type != JSONType.null_)
            r ~= [num(p["screen"].array[0]), num(p["screen"].array[1])];
    return r;
}

/// Floor: the press pixel for `w` is at least `minPx` from every handle anchor.
void assertOffHandle(V3 w, string what, double minPx = 60) {
    import std.math : sqrt;
    auto p = px(w);
    foreach (h; handlePixels()) {
        immutable double d = sqrt((h[0] - p[0]) ^^ 2 + (h[1] - p[1]) ^^ 2);
        assert(d >= minPx, format("rig: %s — the press pixel (%d,%d) is %.0f px from a handle anchor "
                                ~ "(%.0f,%.0f); it must land off the handle", what, p[0], p[1], d, h[0], h[1]));
    }
}
