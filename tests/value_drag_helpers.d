// Rig for the press-relative horizontal VALUE DRAG of the no-handle tools
// (Merge Points, Polygon Inset — task 7121, law `doc/measured_laws.md` §26/§27,
// fixture `tests/fixtures/editor_attrs_acen_laws_w17.json` key `value_drag`).
//
// The law is a function of the view's PIXEL SIZE, so the pixel size is part of
// the rig, not decoration: `orthoAtPixelSize` sets it to the capture's number
// and refuses to go on when it did not take. Every gesture is played as
// independently playable press / motion / release logs, so the tool's value
// can be read between increments while the button is still held.
module value_drag_helpers;

import core.thread : Thread;
import core.time   : dur;
import std.format  : format;
import std.json;
import std.math    : abs;

import http_client : getJson, postJson;
import drag_helpers : fetchCamera, playAndWait, buildDragDownLog, buildDragUpLog;

void vdCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double vdAttr(string tool, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "query " ~ name ~ " failed: " ~ r.toString);
    return r["value"].type == JSONType.integer ? cast(double) r["value"].integer
                                               : r["value"].floating;
}

double vdNum(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "not a number: " ~ v.toString);
    }
}

/// The active cell's pixel size, as `/api/viewport/display` reports it (the
/// same scalar `drag.viewWorldPerPixel` returns).
double activePixelSize() {
    auto d = getJson("/api/viewport/display");
    const id = cast(size_t) d["activeId"].integer;
    return vdNum(d["cells"].array[id]["grid"]["pixelSize"]);
}

/// Switch to the orthographic preset `view` and set the pixel size to the
/// capture's `pFix`: the ortho extent is linear in the camera distance, so the
/// distance is rescaled by `pFix / P_now` and the result re-read.
void orthoAtPixelSize(string view, double pFix) {
    vdCmd("viewport.view " ~ view);
    Thread.sleep(dur!"msecs"(80));
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig: the " ~ view ~ " view must be orthographic");
    double p = activePixelSize();
    foreach (i; 0 .. 3) {
        if (abs(p - pFix) <= 1e-7 * pFix) break;
        const double d = vdNum(getJson("/api/camera")["distance"]) * pFix / p;
        auto r = postJson("/api/camera", format(`{"distance":%.12g}`, d));
        assert(r["status"].str == "ok", "rig: camera distance failed: " ~ r.toString);
        Thread.sleep(dur!"msecs"(60));
        p = activePixelSize();
    }
    assert(abs(p - pFix) <= 1e-6 * pFix,
        format("rig: pixel size not set to the capture's (%.10g vs %.10g)", p, pFix));
}

/// One held drag, played a piece at a time. `press` opens it at (x, y);
/// `move(dx, dy)` plays ONE motion event relative to the current pixel;
/// `release` closes it where the cursor is.
struct HeldDrag {
    int vpX, vpY, vpW, vpH;
    int x, y;

    static HeldDrag press(int x, int y) {
        auto cam = fetchCamera();
        HeldDrag h = HeldDrag(cam.vpX, cam.vpY, cam.width, cam.height, x, y);
        playAndWait(buildDragDownLog(h.vpX, h.vpY, h.vpW, h.vpH, x, y));
        return h;
    }

    void move(int dx, int dy) {
        const int nx = x + dx, ny = y + dy;
        string log = format(
            `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
            `{"t":1.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            vpX, vpY, vpW, vpH, nx, ny, dx, dy);
        playFast(log);
        x = nx; y = ny;
    }

    void release() {
        playAndWait(buildDragUpLog(vpX, vpY, vpW, vpH, x, y));
    }
}

/// `playAndWait` with a 5 ms poll instead of 50 ms: a cell here plays hundreds
/// of one-event logs, and the poll interval was most of its wall time.
void playFast(string log) {
    import std.net.curl : get, post;
    import http_client : testBaseUrl;
    auto j = parseJSON(cast(string) post(testBaseUrl() ~ "/api/play-events", log));
    assert(j["status"].str == "success", "play-events failed: " ~ j.toString);
    foreach (i; 0 .. 2000) {
        auto st = parseJSON(cast(string) get(testBaseUrl() ~ "/api/play-events/status"));
        if (st["finished"].type == JSONType.true_) return;
        Thread.sleep(dur!"msecs"(5));
    }
    assert(false, "play-events did not finish within 10s");
}

/// A fixture leg list `[["+x", count, px], …]` expanded into per-increment
/// (dx, dy) steps plus the leg label each belongs to.
struct Increment { int dx, dy; string leg; }

Increment[] expandLegs(JSONValue legs) {
    Increment[] out_;
    foreach (leg; legs.array) {
        const string dir = leg.array[0].str;
        const int count = cast(int) vdNum(leg.array[1]);
        const int px    = cast(int) vdNum(leg.array[2]);
        int dx, dy;
        switch (dir) {
            case "+x": dx =  px; break;
            case "-x": dx = -px; break;
            case "+y": dy =  px; break;   // screen down
            case "-y": dy = -px; break;
            default: assert(false, "unknown leg direction " ~ dir);
        }
        foreach (k; 0 .. count) out_ ~= Increment(dx, dy, dir);
    }
    return out_;
}

JSONValue valueDragFixture() {
    import std.file : readText;
    return parseJSON(readText("tests/fixtures/editor_attrs_acen_laws_w17.json"))["value_drag"];
}
