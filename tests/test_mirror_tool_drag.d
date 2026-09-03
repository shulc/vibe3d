// Interactive drag coverage for the Mirror tool's Center handle. Task 0233
// REMOVED the axis arrows from the Mirror gizmo (reference = 2 boxes + plane,
// no arrows), so center MOVE now runs only through the center box
// (planeDragDelta path), and a click where the old arrow shaft used to be is a
// free click-to-place relocation — no longer an axis-locked arrow drag.
//
// WHAT THIS FILE WAS MISSING (task 2900). Both gestures here are REAL — measured
// on this stand, each one takes the cube from 8 vertices to 16 and pushes one
// `mesh.bevel_edit` labelled "Mirror". The defect was the ASSERTION: every line
// of this file read the `center` ATTRIBUTE and nothing else, so a MirrorTool
// whose kernel mirrored nothing — `inserted == 0`, `deactivate()` recording
// nothing — would have left it green. `center` is a gizmo field that the free
// screen-plane drag moves whether or not one face was ever copied.
//
// This is the sharpest instance of a group-wide hole: before task 2900 NOT ONE
// shipped test in this repository asserted that ANY of the five tools in this
// family records anything when a real gesture commits. None of the five calls
// `/api/undo` or reads `/api/history` around an interactive commit.
//
// `built` IS NOT ON THE WIRE HERE, and that is measured rather than assumed:
// `/api/tool/state` publishes it for exactly six tools tree-wide (poly_bevel,
// edge_bevel, edge_extend, edge_extrude, edge_slice, loop_slice —
// `grep -rn '"built"' source/`) and answers `{}` for `mesh.mirrorTool` both
// while armed and while built. A NAMED VERTEX COUNT stands in for it and is
// strictly stronger: `built` is the tool's own claim about its kernel's return,
// and the count is that claim's consequence read off the mesh. 16 is not a
// magic number — it is the 8-vertex cube plus its whole-mesh mirror image, with
// no weld, because Mirror's operand rule is `operandFaceMask()` and an empty
// face selection means the whole mesh.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.mirrorTool";

string getRaw(string path) { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path) { return parseJSON(getRaw(path)); }

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control. Each new assertion is "something MOVED": a
// `/api/mesh/planes` serving a stale copy leaves `moved` empty and goes RED, an
// `/api/history` that stopped tracking leaves the delta at 0 and goes RED, an
// `/api/model` that froze leaves the count at 8 and goes RED. (The frozen
// fixtures in `tests/test_tool_gesture_g*.d` assert "EQUAL" and "EMPTY", which a
// dead channel satisfies for free — that is why THEY open with a control.)

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

/// The three assertions the acceptance criterion names, run after the drop.
/// `gesture` names the gesture in every message, because both blocks below
/// share this body and a bare "the drag" would not say which one failed.
void assertMirrorCommitted(string gesture, string planesBefore, long u0, size_t v0) {
    immutable size_t v1 = vertexCount();
    assert(v1 == 16,
        gesture ~ ": the drop left " ~ v1.to!string ~ " vertices (started at "
        ~ v0.to!string ~ "), expected 16 — the 8-vertex cube plus its whole-mesh "
        ~ "mirror. `deactivate()` commits only when `inserted > 0`, so no growth "
        ~ "means the kernel mirrored nothing and the record was never pushed. "
        ~ "This is the check this file never had: the `center` attribute above "
        ~ "moves either way");
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        gesture ~ ": the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    immutable long d = undoLen() - u0;
    assert(d == 1,
        gesture ~ ": the drop recorded " ~ d.to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 (`mesh.bevel_edit`, label \"Mirror\") — 0 means "
        ~ "the whole gesture was a no-op the attribute could not see");
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double qf(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].floating;
}

Vec3 queriedCenter() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " center ?");
    assert(r["status"].str == "ok", "query center failed: " ~ r.toString);
    auto a = r["value"].array;
    return Vec3(cast(float) a[0].floating, cast(float) a[1].floating,
                cast(float) a[2].floating);
}

bool approx(double a, double b, double eps = 1e-3) { return abs(a - b) <= eps; }

void resetForMirrorCamera() {
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
}

void dragWorldHandle(Vec3 handle, Vec3 axis, double pixels = 80.0, int steps = 16) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float hx, hy, ax, ay;
    assert(projectToWindow(handle, vp, hx, hy), "handle projects behind camera");
    assert(projectToWindow(handle + axis, vp, ax, ay), "axis projects behind camera");
    double dx = ax - hx;
    double dy = ay - hy;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "projected handle axis is degenerate");
    int x0 = cast(int) hx;
    int y0 = cast(int) hy;
    int x1 = cast(int)(hx + dx / len * pixels);
    int y1 = cast(int)(hy + dy / len * pixels);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(120));
}

// ---------------------------------------------------------------------------
// 1. The axis arrows are GONE (task 0233). A drag that begins where the old X
//    arrow shaft used to be no longer hits an axis handle — it misses every
//    handle and falls through to click-to-place, which relocates the center to
//    the cursor's screen-projected point on the screen-facing plane through the
//    current center. So the OLD axis-constrained signature (center.x moves,
//    center.y/z stay exactly 0) must NO LONGER hold: the relocation is a free
//    screen-plane point that generally leaves the X axis. This is the
//    regression guard that the arrows were truly removed (not merely hidden).
// ---------------------------------------------------------------------------

unittest {
    resetForMirrorCamera();

    // Read the three channels BEFORE the gesture. `resetForMirrorCamera` has
    // already cleared the history, so `u0` is 0 — it is read rather than
    // assumed so that a future stand change cannot silently turn the delta
    // below into a comparison against a constant.
    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    auto vp = viewportFromCamera(fetchCamera(BASE));
    float size = gizmoSize(Vec3(0, 0, 0), vp);
    // The former arrowX shaft location — now empty (no arrow handle there),
    // and well clear of the center box, so this click hits nothing.
    Vec3 grabPoint = Vec3(size * 0.5f, 0, 0);

    dragWorldHandle(grabPoint, Vec3(1, 0, 0));

    auto c = queriedCenter();
    // Center relocated (click-to-place fired) ...
    bool moved = abs(c.x) > 0.02 || abs(c.y) > 0.02 || abs(c.z) > 0.02;
    assert(moved, "a click at the former arrow location should relocate the center, got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");
    // ... and it is NOT an axis-locked X-only arrow move: with the arrow gone
    // the free screen-plane relocation leaves the X axis (y or z non-zero).
    assert(abs(c.y) > 1e-3 || abs(c.z) > 1e-3,
        "arrows removed (task 0233): a drag at the old X-arrow spot must be a free "
        ~ "click-to-place, not an axis-locked X-only move; got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");

    // The drop is where MirrorTool records. Settle past it before reading the
    // planes: `deactivate()` runs the kernel, deletes nothing, re-uploads and
    // only then pushes the entry.
    cmd("tool.set " ~ TOOL ~ " off");
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(250));
    assertMirrorCommitted("click-to-place at the former arrow spot",
                          planesBefore, u0, v0);
}

// ---------------------------------------------------------------------------
// 2. Drag the center box — free (screen-plane) drag: center should move.
// ---------------------------------------------------------------------------

unittest {
    resetForMirrorCamera();

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    dragWorldHandle(Vec3(0, 0, 0), Vec3(1, 0, 0), 60.0);

    auto c = queriedCenter();
    bool moved = abs(c.x) > 0.02 || abs(c.y) > 0.02 || abs(c.z) > 0.02;
    assert(moved, "dragging the center box should move center, got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");

    cmd("tool.set " ~ TOOL ~ " off");
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(250));
    assertMirrorCommitted("centre-box haul", planesBefore, u0, v0);
}
