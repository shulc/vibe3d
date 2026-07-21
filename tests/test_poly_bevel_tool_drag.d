// Interactive Poly Bevel handle-drag coverage.
//
// The poly.bevel TOOL's interactive mouse drag had ZERO test coverage — every
// poly-bevel fixture drives the mesh.bevel COMMAND / applyHeadless, never the
// tool's Shift/Inset drag handles. That gap let TWO regressions ship:
//   1. a stale queryMouse made the handles unclickable (fixed: hit-test at the
//      click event's own e.x/e.y);
//   2. onMouseMotion measured the delta from the LAST motion, not the mouse-
//      DOWN — so a smooth multi-event drag jumped/jittered per SDL event
//      instead of accumulating the total (fixed: measure from dragStart). This
//      is the same last-event/base bug edge.bevel had and fixed.
// NOTE: EventPlayer freshens the mouse position per injected event, so playback
// cannot reproduce the real-GUI queryMouse staleness of (1); the (2) assertions
// (monotonic multi-batch growth + backward-restores-baseline + one-step ==
// three-step) DO catch the accumulation bug directly.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : fabs;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers; // Vec3, fetchCamera, viewportFromCamera, projectToWindow

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void settle() { Thread.sleep(140.msecs); }

void play(string log) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) break;
        Thread.sleep(50.msecs);
    }
    settle(); // EventPlayer reports posted, not processed — let the queue drain.
}

string motion(int x, int y, int state = 0, uint mod = 0) {
    return format(`{"t":0.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%u}`,
                  x, y, state, mod);
}
string button(string kind, int x, int y, uint mod = 0) {
    return format(`{"t":0.0,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`, kind, x, y, mod);
}

enum uint LCTRL = 64; // KMOD_LCTRL

// Screen position of the tool's published handle part (0 = Shift, 1 = Inset).
void handleScreen(int part, out int x, out int y) {
    auto parts = getJson("/api/tool/handles")["handles"]["parts"].array;
    foreach (p; parts)
        if (p["part"].integer == part) {
            x = cast(int)(p["screen"].array[0].floating + 0.5);
            y = cast(int)(p["screen"].array[1].floating + 0.5);
            return;
        }
    assert(false, "handle part not published to /api/tool/handles: " ~ part.to!string);
}

void selectFaceZero() {
    auto sel = parseJSON(cast(string)post(BASE ~ "/api/select", `{"mode":"polygons","indices":[0]}`));
    assert(sel["status"].str == "ok", "face select failed");
}

double shiftNow() { return getJson("/api/tool/state")["shift"].floating; }

// Shift handle: direct press captures; a SMOOTH multi-batch drag accumulates the
// TOTAL delta (not per-event); backward restores baseline; one-step == three-step.
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle(); // draw() must publish the handle bank + compute the gizmo frame.

    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles["parts"].array.length == 2, "poly.bevel must publish 2 handles (Shift + Inset)");

    int sx, sy;
    handleScreen(0, sx, sy);
    enum int DX = -60, DY = -105; // up-left along the shift (normal) screen axis

    play(button("SDL_MOUSEBUTTONDOWN", sx, sy));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "Shift handle did not capture on a direct mouse-down — hit-test regression");

    play(motion(sx, sy, 1));
    assert(shiftNow() < 1e-6, "zero motion changed shift");

    // Three SEPARATE motion batches (defeats SDL coalescing). With the old
    // last-event delta this jumps per event instead of growing monotonically.
    double prev = 0;
    foreach (k; [1, 2, 3]) {
        play(motion(sx + DX * k / 3, sy + DY * k / 3, 1));
        double s = shiftNow();
        assert(s > prev + 1e-5, "shift not monotonic at batch " ~ k.to!string
            ~ " (per-event jump bug): " ~ s.to!string);
        assert(getJson("/api/tool/state")["built"].type == JSONType.true_,
            "non-zero shift did not build a live preview");
        prev = s;
    }
    double multiShift = prev;
    string multiVerts = getJson("/api/model")["vertices"].toString;
    assert(getJson("/api/model")["vertices"].array.length > 8, "shift drag did not bevel the mesh");

    // Backward to the press pixel: a total-delta drag returns to baseline.
    play(motion(sx, sy, 1));
    assert(shiftNow() < 1e-5, "backward drag to the press pixel did not restore the shift baseline");
    // Forward to the endpoint again: same total.
    play(motion(sx + DX, sy + DY, 1));
    assert(fabs(shiftNow() - multiShift) < 1e-5, "returning to the endpoint changed shift");

    play(button("SDL_MOUSEBUTTONUP", sx + DX, sy + DY));
    assert(getJson("/api/tool/state")["dragPart"].integer == -1, "mouse-up kept Shift captured");
    cmd("tool.set poly.bevel off");
    auto undo = parseJSON(cast(string)post(BASE ~ "/api/undo", ""));
    assert(undo["status"].str == "ok", "undo failed");
    assert(getJson("/api/model")["vertexCount"].integer == 8, "one undo did not restore the cube");

    // One-step drag to the same endpoint == the three-step drag (accumulation).
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();
    handleScreen(0, sx, sy);
    play(button("SDL_MOUSEBUTTONDOWN", sx, sy));
    play(motion(sx + DX, sy + DY, 1));
    assert(fabs(shiftNow() - multiShift) < 1e-4,
        "one-step vs three-step drag shift differ (accumulation bug): "
        ~ shiftNow().to!string ~ " vs " ~ multiShift.to!string);
    assert(getJson("/api/model")["vertices"].toString == multiVerts,
        "one-step vs three-step drag geometry differ");
    play(button("SDL_MOUSEBUTTONUP", sx + DX, sy + DY));
    cmd("tool.set poly.bevel off");
}

// Inset handle behaves like a SCALE box: a direct press captures its own part;
// dragging the box TOWARD the center grows inset (cap shrinks) — inverted from a
// naive axis drag — and the box FOLLOWS the cursor inward.
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();

    // Gizmo anchor = the selected face's centroid; project it to a screen point.
    auto model = getJson("/api/model");
    auto f0 = model["faces"].array[0].array;
    Vec3 cen = Vec3(0, 0, 0);
    foreach (vi; f0) {
        auto v = model["vertices"].array[vi.integer].array;
        cen = cen + Vec3(cast(float)v[0].floating, cast(float)v[1].floating, cast(float)v[2].floating);
    }
    cen = cen * (1.0f / cast(float)f0.length);
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float ax, ay;
    assert(projectToWindow(cen, vp, ax, ay), "face centroid projects off camera");

    int bx, by;
    handleScreen(1, bx, by); // inset box, out along the in-plane axis from the anchor
    double boxToCenter0 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);

    play(button("SDL_MOUSEBUTTONDOWN", bx, by));
    assert(getJson("/api/tool/state")["dragPart"].integer == 1,
        "Inset handle did not capture on a direct mouse-down — hit-test regression");

    // Drag the box 60% of the way toward the centroid — the "toward center" dir.
    int tx = bx + cast(int)((ax - bx) * 0.6f);
    int ty = by + cast(int)((ay - by) * 0.6f);
    play(motion(tx, ty, 1));
    assert(getJson("/api/tool/state")["inset"].floating > 1e-3,
        "dragging the inset box TOWARD the center did not grow inset (wrong drag sign)");
    assert(getJson("/api/model")["vertices"].array.length > 8, "inset drag did not bevel the mesh");

    // The box must have FOLLOWED the cursor toward the centroid (scale-box feel).
    int nbx, nby;
    handleScreen(1, nbx, nby);
    double boxToCenter1 = (nbx - ax) * (nbx - ax) + (nby - ay) * (nby - ay);
    assert(boxToCenter1 < boxToCenter0 - 1.0,
        "inset box did not move toward the center as inset grew (box should follow)");

    play(button("SDL_MOUSEBUTTONUP", tx, ty));
    cmd("tool.set poly.bevel off");
}

// Free 2D drag OFF the handles: click empty space + drag → vertical is shift
// (up = +), horizontal is inset (right = +), both at once.
unittest {
    enum int EX = 400, EY = 450; // clearly off the two handles (near screen centre)

    // vertical UP → shift grows, inset untouched.
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();
    play(button("SDL_MOUSEBUTTONDOWN", EX, EY));
    assert(getJson("/api/tool/state")["dragPart"].integer == 2,
        "click off the handles must start a FREE 2D drag (dragPart == 2)");
    play(motion(EX, EY - 100, 1));
    auto st = getJson("/api/tool/state");
    assert(st["shift"].floating > 1e-3, "vertical (up) free drag did not grow shift");
    assert(fabs(st["inset"].floating) < 1e-6, "a purely vertical free drag changed inset");
    play(button("SDL_MOUSEBUTTONUP", EX, EY - 100));
    cmd("tool.set poly.bevel off");

    // horizontal RIGHT → inset grows, shift untouched.
    reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();
    play(button("SDL_MOUSEBUTTONDOWN", EX, EY));
    play(motion(EX + 100, EY, 1));
    st = getJson("/api/tool/state");
    assert(st["inset"].floating > 1e-3, "horizontal (right) free drag did not grow inset");
    assert(fabs(st["shift"].floating) < 1e-6, "a purely horizontal free drag changed shift");
    // LEFT of the press point → NEGATIVE inset (outset): must NOT clamp at 0.
    play(motion(EX - 100, EY, 1));
    assert(getJson("/api/tool/state")["inset"].floating < -1e-3,
        "left free drag must let inset go negative (outset) — no >=0 clamp");
    play(button("SDL_MOUSEBUTTONUP", EX - 100, EY));
    cmd("tool.set poly.bevel off");
}

// Ctrl + free drag LOCKS to one axis by the initial dominant direction.
unittest {
    enum int EX = 400, EY = 450;

    // Ctrl + up-dominant diagonal (dy > dx) → only shift.
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();
    play(button("SDL_MOUSEBUTTONDOWN", EX, EY, LCTRL));
    play(motion(EX + 50, EY - 100, 1, LCTRL)); // dy=100 > dx=50 → lock to shift
    auto st = getJson("/api/tool/state");
    assert(st["shift"].floating > 1e-3, "Ctrl vertical-dominant drag did not grow shift");
    assert(fabs(st["inset"].floating) < 1e-6, "Ctrl vertical-dominant drag must NOT change inset");
    play(button("SDL_MOUSEBUTTONUP", EX + 50, EY - 100, LCTRL));
    cmd("tool.set poly.bevel off");

    // Ctrl + right-dominant (dx > dy) → only inset.
    reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();
    play(button("SDL_MOUSEBUTTONDOWN", EX, EY, LCTRL));
    play(motion(EX + 100, EY - 35, 1, LCTRL)); // dx=100 > dy=35 → lock to inset
    st = getJson("/api/tool/state");
    assert(st["inset"].floating > 1e-3, "Ctrl horizontal-dominant drag did not grow inset");
    assert(fabs(st["shift"].floating) < 1e-6, "Ctrl horizontal-dominant drag must NOT change shift");
    play(button("SDL_MOUSEBUTTONUP", EX + 100, EY - 35, LCTRL));
    cmd("tool.set poly.bevel off");
}
