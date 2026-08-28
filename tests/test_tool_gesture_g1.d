// test_tool_gesture_g1 — task 1905, lane G0-G1: the FROZEN plane fixture for
// group G1, driven by REAL GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G1 witnesses can replace it.
// The text census (plan §5.1) sees WHO calls a history primitive; the wire-name
// cell (§5.2) sees WHICH record went on the stack. Neither can see the seam
// writing the RIGHT record with the WRONG geometry — a swapped snapshot pair,
// a stale `after`, a kernel argument that drifted. That defect is invisible to
// a count, invisible to a name, and invisible to a single wholesale
// before/after compare, because the wholesale compare is satisfied by any pair
// of dumps that happen to round-trip. So every cell here freezes FOUR
// plane-complete dumps and compares them PLANE BY PLANE, in BOTH directions:
//   postUndo  against the PRE-OPERATION dump,
//   postRedo  against the POST-COMMIT dump.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. Measured on
// this tree while building the lane: of 44 `tests/test_*tool*.d` only 21 reach
// an event replay, and `tests/test_edge_extrude_handle_drag.d` — the file whose
// name promises the gesture — drives a REAL drag whose only anti-vacuity is the
// `extrude` attribute. That attribute moves; `built` stays FALSE; the tool
// records NOTHING and no plane moves. A cell copied from it would have frozen
// the geometry of a gesture that never happened. Every cell below therefore
// asserts `postCommit != preOp` before it asserts anything else, and the
// extrude cell drives BOTH handles because width alone is what makes the kernel
// affect anything on this stand (measured: width 0 + extrude 0.47 → 0 edges
// affected, `built:false`, nothing recorded).
//
// WHY THE FAILURES ACCUMULATE INSTEAD OF FAILING FAST. The acceptance criterion
// for this file is a per-field mutation table (plan §5.4): each mutation must
// redden a NAMED set of fields and leave the others GREEN. A fail-fast cell
// reports only the first field and says nothing about the rest, so the "stayed
// green" half — the discriminating half — would be unobservable. Each cell
// therefore scores every field, then raises ONE assert naming every field that
// moved. Fields absent from that message are the green column.
//
// THE POSITIVE CONTROL IS FIRST AND IT IS NOT DECORATION (block 0, copied from
// `tests/test_edge_bevel_seam_counters.d:222-241`, NOT from
// `test_vertex_bevel_handle_drag.d:115-125` whose anti-vacuity is a parameter
// value). Most of what this file asserts is "these two dumps agree" and "this
// residual list is EMPTY". A DEAD channel — `/api/mesh/planes` answering a
// stale copy, `/api/history` answering `[]` — satisfies every empty-residual
// assertion for free. Block 0 makes the SAME three channels move first, with a
// command that has nothing to do with G1.
//
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. Seven of the nine cells
// round-trip byte-for-byte in both directions. The two delta-payload cells
// (`edge.extend`, `edge.extrude`) do NOT: their REDO leaves `edgePlanes` and
// `selectionOrderCounters` different from the commit. That is recorded as an
// exact plane LIST, so a residual that GROWS reddens and a residual that
// DISAPPEARS reddens too — a standing licence over a plane nobody compares is
// the thing this file is built to not have.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G1=<abs path to g1.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g1`.
import std.algorithm : sort, canFind;
import std.array     : appender, array;
import std.conv      : to;
import std.format    : format;
import std.json;
import std.math      : abs;
import std.net.curl  : get, post;
import std.process   : environment;
import core.thread   : Thread;
import core.time     : dur;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

/// The frozen oracle. Read through `import()` rather than off disk: the suite
/// lane compiles a scratch COPY of `tests/`, and `-J=tests` resolves this in
/// both trees while `__FILE_FULL_PATH__` would name the copy.
enum string kFrozen = import("fixtures/tool_gesture/g1.json");

/// The one file allowed to write `g1.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g1.d";

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

string getRaw(string path)  { return cast(string) get(BASE ~ path); }
JSONValue getJ(string path) { return parseJSON(getRaw(path)); }

JSONValue postJ(string path, string body_ = "") {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJ("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString
      ~ " — the stand this cell measures was never built");
}

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks, no per-face material/part and no map values, and every
/// one of those is a plane an undo can silently lose.
string planes() { return getRaw("/api/mesh/planes"); }

string[] historyNames() {
    string[] out_;
    foreach (e; getJ("/api/history")["undo"].array) out_ ~= e["command"].str;
    return out_;
}

long undoLen() { return cast(long) getJ("/api/history")["undo"].array.length; }

void settle(int ms = 150) { Thread.sleep(dur!"msecs"(ms)); }

// ---------------------------------------------------------------------------
// Plane comparison
// ---------------------------------------------------------------------------

/// Every plane on which two dumps disagree, sorted, with `provenance` skipped.
///
/// `provenance` carries the capture SHA and the family label, which differ by
/// construction; comparing it would redden every cell for the one reason that
/// is never a finding.
string[] planeDiff(string aText, string bText) {
    auto a = parseJSON(aText);
    auto b = parseJSON(bText);
    bool[string] keys;
    foreach (k, _; a.objectNoRef) keys[k] = true;
    foreach (k, _; b.objectNoRef) keys[k] = true;
    string[] names;
    foreach (k, _; keys) if (k != "provenance") names ~= k;
    names.sort();
    string[] diff;
    foreach (k; names) {
        auto pa = k in a.objectNoRef;
        auto pb = k in b.objectNoRef;
        if (pa is null || pb is null) { diff ~= k; continue; }
        if (pa.toString() != pb.toString()) diff ~= k;
    }
    return diff;
}

/// The two renderings WINDOWED ON THE FIRST DIFFERING CHARACTER — a leading
/// clip prints two identical strings under the word "differs".
string contrast(string a, string b) {
    size_t i = 0;
    immutable size_t n = a.length < b.length ? a.length : b.length;
    while (i < n && a[i] == b[i]) ++i;
    immutable size_t from = i > 60 ? i - 60 : 0;
    static string window(string s, size_t from) {
        immutable size_t to_ = from + 160 < s.length ? from + 160 : s.length;
        return (from > 0 ? "…" : "") ~ s[from .. to_] ~ (to_ < s.length ? "…" : "");
    }
    return "\n      frozen: " ~ window(a, from) ~ "\n      fresh : " ~ window(b, from);
}

// ---------------------------------------------------------------------------
// One cell
// ---------------------------------------------------------------------------

struct Cell {
    string   name;         // the cell's id in the fixture
    string   tool;         // the wire id driven
    string   recordSite;   // file + enclosing symbol; NEVER a line number
    string   mode;         // Plain | InSession | ReplaceRunTail — DECLARED, read
                           // off the source. Provenance, not a witness.
    string   payload;      // MeshSessionEdit | MeshVertexEdit | BoxLiveEditCommand
    string[] liveEntryNames;  // wire names standing between gesture and drop
    string[] entryNames;      // wire names standing after the commit
    long     undoDelta;       // EXACT, never "> 0"
    string   preOp, postCommit, postUndo, postRedo;
    string[] undoResidual;    // planes where postUndo differs from preOp
    string[] redoResidual;    // planes where postRedo differs from postCommit
}

/// Drive one gesture and score it. `stand` builds the scene AND clears history;
/// `gesture` is the play-events drive; `drop` deactivates the tool.
Cell runCell(string name, string tool, string recordSite, string mode,
             string payload,
             void delegate() stand, void delegate() gesture, void delegate() drop)
{
    Cell c;
    c.name = name; c.tool = tool; c.recordSite = recordSite;
    c.mode = mode; c.payload = payload;

    stand();
    immutable long u0 = undoLen();
    assert(u0 == 0,
        name ~ ": the stand left " ~ u0.to!string ~ " undo entr(ies) standing. "
      ~ "`undoDelta` is measured from a CLEARED stack, and a selection POST "
      ~ "records `mesh.select`, so the stand must clear history AFTER it "
      ~ "selects");
    c.preOp = planes();

    gesture();
    c.liveEntryNames = historyNames();

    drop();
    settle();
    c.postCommit = planes();
    c.entryNames = historyNames();
    c.undoDelta  = undoLen() - u0;

    // ANTI-VACUITY, BEFORE anything is compared. A gesture that moved no plane
    // makes every assertion below satisfiable by an undo that does nothing —
    // and it is the failure `test_edge_extrude_handle_drag.d` already ships
    // (its drag drives the attribute and builds no topology).
    assert(c.postCommit != c.preOp,
        name ~ ": the gesture moved NO plane. Its record, its undo and its redo "
      ~ "are then all satisfied by doing nothing. Either the drive missed the "
      ~ "handle, or the tool refused on this stand — check `/api/tool/state`");
    assert(c.undoDelta == 1,
        name ~ ": the gesture left " ~ c.undoDelta.to!string ~ " undo entr(ies), "
      ~ "expected exactly 1. Zero means the commit never recorded; more than "
      ~ "one means an in-session run was left unspliced");

    auto ru = postJ("/api/undo");
    assert(ru["status"].str == "ok", name ~ ": /api/undo failed: " ~ ru.toString);
    settle();
    c.postUndo = planes();
    assert(undoLen() == u0,
        name ~ ": the undo moved the stack to " ~ undoLen().to!string
      ~ ", expected back to " ~ u0.to!string ~ " — more than one step means the "
      ~ "entry's revert() answered false and the suffix behind it was truncated");

    auto rr = postJ("/api/redo");
    assert(rr["status"].str == "ok", name ~ ": /api/redo failed: " ~ rr.toString);
    settle();
    c.postRedo = planes();

    c.undoResidual = planeDiff(c.preOp,      c.postUndo);
    c.redoResidual = planeDiff(c.postCommit, c.postRedo);
    return c;
}

// ---------------------------------------------------------------------------
// Compare against the frozen oracle — or capture
// ---------------------------------------------------------------------------

string fixtureJson(in Cell[] cells) {
    auto s = appender!string();
    s ~= "{\n";
    s ~= "  \"family\": \"tool_gesture_g1\",\n";
    s ~= "  \"writtenBy\": \"" ~ kWrittenBy ~ "\",\n";
    s ~= "  \"producedBy\": \"" ~ environment.get("VIBE3D_TOOL_GESTURE_SHA", "unknown") ~ "\",\n";
    s ~= "  \"stand\": \"per-cell; see each cell's `drive`\",\n";
    s ~= "  \"recipe\": \"stand -> gesture (/api/play-events) -> drop -> undo -> redo\",\n";
    s ~= "  \"cells\": [\n";
    foreach (i, ref c; cells) {
        s ~= "    {\n";
        s ~= format("      \"name\": \"%s\", \"tool\": \"%s\",\n", c.name, c.tool);
        s ~= format("      \"recordSite\": \"%s\", \"mode\": \"%s\", \"payload\": \"%s\",\n",
                    c.recordSite, c.mode, c.payload);
        s ~= format("      \"liveEntryNames\": %s,\n", JSONValue(c.liveEntryNames).toString());
        s ~= format("      \"entryNames\": %s,\n",     JSONValue(c.entryNames).toString());
        s ~= format("      \"undoDelta\": %d,\n",      c.undoDelta);
        s ~= format("      \"undoResidual\": %s,\n",   JSONValue(c.undoResidual).toString());
        s ~= format("      \"redoResidual\": %s,\n",   JSONValue(c.redoResidual).toString());
        s ~= format("      \"preOp\": %s,\n",      c.preOp);
        s ~= format("      \"postCommit\": %s,\n", c.postCommit);
        s ~= format("      \"postUndo\": %s,\n",   c.postUndo);
        s ~= format("      \"postRedo\": %s\n",    c.postRedo);
        s ~= (i + 1 < cells.length) ? "    },\n" : "    }\n";
    }
    s ~= "  ]\n}\n";
    return s.data;
}

string[] jsonStrings(in JSONValue v) {
    string[] out_;
    foreach (e; v.array) out_ ~= e.str;
    return out_;
}

/// Score every field of one cell against the frozen one and raise ONE assert
/// naming every field that moved.
///
/// ACCUMULATE-THEN-RAISE IS THE POINT, not a style choice. This file's
/// acceptance criterion is a mutation table whose every row names both the
/// fields that must redden AND the fields that must stay green; a fail-fast
/// cell reports the first and hides the rest, so the green column — the half
/// that makes a mutation DISCRIMINATING rather than merely loud — would not be
/// observable at all.
void scoreCell(const ref Cell fresh, const ref JSONValue frozen) {
    string[] bad;

    void field(string what, bool ok, string detail) {
        if (!ok) bad ~= "    · " ~ what ~ ": " ~ detail;
    }

    field("entryNames",
          jsonStrings(frozen["entryNames"]) == fresh.entryNames,
          "frozen " ~ frozen["entryNames"].toString()
        ~ " vs fresh " ~ JSONValue(fresh.entryNames).toString());
    field("liveEntryNames",
          jsonStrings(frozen["liveEntryNames"]) == fresh.liveEntryNames,
          "frozen " ~ frozen["liveEntryNames"].toString()
        ~ " vs fresh " ~ JSONValue(fresh.liveEntryNames).toString());
    field("undoDelta",
          frozen["undoDelta"].integer == fresh.undoDelta,
          "frozen " ~ frozen["undoDelta"].integer.to!string
        ~ " vs fresh " ~ fresh.undoDelta.to!string);

    void dump(string what, const ref JSONValue frozenDump, string freshText) {
        auto d = planeDiff(frozenDump.toString(), freshText);
        if (d.length == 0) return;
        auto fj = parseJSON(freshText);
        immutable string first = d[0];
        immutable string fa = (first in frozenDump.objectNoRef) is null
                            ? "<absent>" : frozenDump[first].toString();
        immutable string fb = (first in fj.objectNoRef) is null
                            ? "<absent>" : fj[first].toString();
        bad ~= "    · " ~ what ~ ": planes " ~ d.to!string
             ~ " differ from the frozen capture; first is '" ~ first ~ "'"
             ~ contrast(fa, fb);
    }
    dump("postCommit", frozen["postCommit"], fresh.postCommit);
    dump("postUndo",   frozen["postUndo"],   fresh.postUndo);
    dump("postRedo",   frozen["postRedo"],   fresh.postRedo);

    // The two DIRECTIONS, computed live and pinned as EXACT lists. An empty
    // list stays empty; a non-empty one keeps exactly its members, so a
    // residual that grows AND a residual that disappears both redden.
    field("undoResidual",
          jsonStrings(frozen["undoResidual"]) == fresh.undoResidual,
          "post-undo differs from the PRE-OPERATION dump on "
        ~ fresh.undoResidual.to!string ~ ", frozen says "
        ~ frozen["undoResidual"].toString());
    field("redoResidual",
          jsonStrings(frozen["redoResidual"]) == fresh.redoResidual,
          "post-redo differs from the POST-COMMIT dump on "
        ~ fresh.redoResidual.to!string ~ ", frozen says "
        ~ frozen["redoResidual"].toString());

    if (bad.length == 0) return;
    string msg = "tests/fixtures/tool_gesture/g1.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G1` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g1: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G1", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g1.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g1.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g1.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g1.json: cell %d is '%s' frozen and '%s' now — the roster "
                 ~ "was reordered", i, fc[i]["name"].str, c.name));
        scoreCell(c, fc[i]);
    }
}

// ---------------------------------------------------------------------------
// Stands and gestures
// ---------------------------------------------------------------------------

void resetEmpty() {
    auto r = postJ("/api/reset?empty=true");
    assert(r["status"].str == "ok", "reset(empty) failed: " ~ r.toString);
}

void resetCube() {
    auto r = postJ("/api/reset");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}

void setOrbitCamera(double az = 0.4, double el = 1.1, double dist = 4.0) {
    auto r = postJ("/api/camera",
        format(`{"azimuth":%g,"elevation":%g,"distance":%g,`
             ~ `"focus":{"x":0,"y":0,"z":0}}`, az, el, dist));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
}

/// Pixel of a world point under the LIVE camera.
void px(Vec3 w, out int x, out int y) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float fx, fy;
    assert(projectToWindow(w, vp, fx, fy), "point projects behind the camera");
    x = cast(int) fx; y = cast(int) fy;
}

void dragPixels(int x0, int y0, int x1, int y1, int steps = 16) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    settle(120);
}

/// A hover motion (state 0) BEFORE the press, then the drag. MagnetTool picks
/// its anchor on hover, so a bare press-and-drag picks nothing.
void hoverDrag(int hx, int hy, int x1, int y1, int steps = 20) {
    auto cam = fetchCamera(BASE);
    auto s = appender!string();
    s ~= format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
              ~ "\n", cam.vpX, cam.vpY, cam.width, cam.height);
    s ~= format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
              ~ "\n", hx, hy);
    s ~= format(`{"t":200.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
              ~ "\n", hx, hy);
    int lx = hx, ly = hy;
    foreach (i; 1 .. steps + 1) {
        int x = hx + (x1 - hx) * cast(int) i / steps;
        int y = hy + (y1 - hy) * cast(int) i / steps;
        s ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`
                  ~ "\n", 200.0 + i * 50.0, x, y, x - lx, y - ly);
        lx = x; ly = y;
    }
    s ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
              ~ "\n", 200.0 + (steps + 1) * 50.0, x1, y1);
    playAndWait(s.data, BASE);
    settle(150);
}

enum string kClickHeader =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

string clickAt(double t, int x, int y) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t, x, y, t + 5.0, x, y, t + 10.0, x, y);
}

/// The screen anchor of a registered handle part (`/api/tool/handles`). Used
/// instead of re-deriving the arm geometry: the extrude cell needs TWO parts,
/// and a re-derivation that drifts from the tool silently turns the drag into
/// the "attribute moved, nothing built" non-gesture this file exists to reject.
void handlePx(int part, out int x, out int y) {
    auto h = getJ("/api/tool/handles")["handles"];
    assert(h.type != JSONType.null_,
        "the active tool publishes no handle arbiter — part " ~ part.to!string
      ~ " cannot be grabbed");
    foreach (p; h["parts"].array) {
        if (cast(int) p["part"].integer != part) continue;
        assert(p["screen"].type != JSONType.null_,
            "handle part " ~ part.to!string ~ " is off-camera");
        x = cast(int) p["screen"].array[0].floating;
        y = cast(int) p["screen"].array[1].floating;
        return;
    }
    assert(false, "no handle part " ~ part.to!string);
}

/// The cube edge at x=+0.5, z=-0.5 — the operand both edge cells act on.
int findEdgeXPosZNeg() {
    auto m = getJ("/api/model");
    auto verts = m["vertices"].array;
    foreach (i, e; m["edges"].array) {
        immutable int a = cast(int) e.array[0].integer;
        immutable int b = cast(int) e.array[1].integer;
        auto pa = verts[a].array, pb = verts[b].array;
        if (abs(pa[0].floating - 0.5) < 1e-4 && abs(pb[0].floating - 0.5) < 1e-4 &&
            abs(pa[2].floating + 0.5) < 1e-4 && abs(pb[2].floating + 0.5) < 1e-4)
            return cast(int) i;
    }
    assert(false, "no cube edge at x=+0.5, z=-0.5");
}

// ---------------------------------------------------------------------------
// 0. POSITIVE CONTROL FIRST, and it is not decoration.
//
//    Almost everything below is "the fresh dump equals the frozen one" and
//    "this residual list is EMPTY". A DEAD channel satisfies the second kind
//    for free: `/api/mesh/planes` answering a stale copy makes every
//    `undoResidual == []` true no matter what the undo did, and an
//    `/api/history` that stopped reporting makes every `entryNames` compare
//    against a constant. So make the SAME three channels move first, with a
//    command that belongs to no group in this task.
//
//    Copied from `tests/test_edge_bevel_seam_counters.d:222-241`. Deliberately
//    NOT from `test_vertex_bevel_handle_drag.d:115-125`, whose anti-vacuity is
//    an `inset` value: that proves a drag began, not that the channel it then
//    asserts zero on is alive.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("history.clear");
    immutable string before = planes();
    immutable long   u0     = undoLen();

    auto r = postJ("/api/command", `{"id":"mesh.clone"}`);
    assert(r["status"].str == "ok", "control: mesh.clone failed: " ~ r.toString);
    settle();

    immutable string after = planes();
    auto moved = planeDiff(before, after);
    assert(moved.canFind("vertices"),
        "CONTROL: `mesh.clone` moved planes " ~ moved.to!string ~ " — `vertices` "
      ~ "is not among them. Either /api/mesh/planes is answering a stale copy "
      ~ "or planeDiff() does not discriminate, and then EVERY empty-residual "
      ~ "assertion in this file is satisfied for free");

    assert(undoLen() - u0 == 1,
        "CONTROL: `mesh.clone` moved the undo stack by "
      ~ (undoLen() - u0).to!string ~ ", expected exactly 1 — /api/history is "
      ~ "not tracking, so every `undoDelta` and `entryNames` assertion below "
      ~ "is comparing two constants");
    assert(historyNames()[$ - 1] == "mesh.clone",
        "CONTROL: the top history entry is '" ~ historyNames()[$ - 1]
      ~ "', expected 'mesh.clone' — the wire-name channel is not live");

    // And the diff must be able to say EMPTY as well as non-empty, or it is a
    // predicate that always answers "different" and no residual pin means
    // anything either.
    assert(planeDiff(after, planes()).length == 0,
        "CONTROL: two dumps of the SAME unchanged mesh compared as different — "
      ~ "planeDiff() is not a stable predicate");

    postJ("/api/undo");
    settle();
}

// ---------------------------------------------------------------------------
// 1. The roster. ONE unittest, because the nine cells share one frozen file
//    and the fixture compare is per-cell anyway (each cell raises its own
//    accumulated assert, naming itself).
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) the PrimitiveCreateTool funnel: one body shared by nine leaves.
    //     `prim.sphere` stands for all of them; the record is the base's
    //     `commitEdit(MeshSnapshot pre)`, the single site plan §6 migrates to
    //     close nine tools with one change.
    cells ~= runCell("prim.sphere/create-drop", "prim.sphere",
        "source/tools/create/primitive_create_tool.d PrimitiveCreateTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetEmpty(); cmd("history.clear"); setOrbitCamera(); cmd("tool.set prim.sphere"); },
        {
            int cx, cy; px(Vec3(0, 0, 0), cx, cy);
            dragPixels(cx, cy, cx + 140, cy + 130);
            dragPixels(cx, cy, cx, cy - 90);
        },
        { cmd("tool.set prim.sphere off"); });

    // --- (b) box, PLAIN arm. A base-only construction leaves `liveRunActive`
    //     false, so `commitBoxEdit` takes `history.record` — box's own EXTRA
    //     record site, on top of the base funnel it also inherits.
    cells ~= runCell("prim.cube/base-drop", "prim.cube",
        "source/tools/create/box.d BoxTool.commitBoxEdit (liveRunActive == false)",
        "Plain", "MeshSessionEdit",
        { resetEmpty(); cmd("history.clear"); setOrbitCamera(); cmd("tool.set prim.cube"); },
        {
            int cx, cy; px(Vec3(0, 0, 0), cx, cy);
            dragPixels(cx, cy, cx + 150, cy + 140);
        },
        { cmd("tool.set prim.cube off"); });

    // --- (c) box, the OTHER TWO record primitives in one gesture, and the only
    //     tool in the tree that walks all three. The height drag opens a run
    //     and records a `BoxLiveEditCommand` through `recordInSession`
    //     (payload FOUR: not a snapshot pair, not a vertex delta — the tool's
    //     own parameters); the drop then SPLICES that run's tail into one entry
    //     through `replaceInSessionTailWith`.
    //
    //     `liveEntryNames` is what makes those two branches visible: it is
    //     `["prim.cube.live"]` while the run is open and `["mesh.bevel_edit"]`
    //     after the splice, and `undoDelta` is 1 across the pair. A splice that
    //     failed would APPEND instead, and both fields move.
    cells ~= runCell("prim.cube/live-drop", "prim.cube",
        "source/tools/create/box.d BoxTool.recordLiveEdit + commitBoxEdit (liveRunActive == true)",
        "InSession+ReplaceRunTail", "BoxLiveEditCommand",
        { resetEmpty(); cmd("history.clear"); setOrbitCamera(); cmd("tool.set prim.cube"); },
        {
            int cx, cy; px(Vec3(0, 0, 0), cx, cy);
            dragPixels(cx, cy, cx + 150, cy + 140);
            dragPixels(cx, cy, cx, cy - 100);
        },
        { cmd("tool.set prim.cube off"); });

    // --- (d) ArcTool: the commit is SYNCHRONOUS with the mouse-UP and
    //     `hasUncommittedEdit()` is hard-coded false, so a seam keyed on that
    //     predicate never sees it. This cell is also the first interactive
    //     coverage `prim.arc` has anywhere in the suite (plan §5.4 named it as
    //     one of three tools with no interactive witness in the tree).
    cells ~= runCell("prim.arc/mouseup", "prim.arc",
        "source/tools/create/arc.d ArcTool.commitArcEdit (from onMouseButtonUp)",
        "Plain", "MeshSessionEdit",
        { resetEmpty(); cmd("history.clear"); setOrbitCamera(); cmd("tool.set prim.arc"); },
        {
            int cx, cy; px(Vec3(0, 0, 0), cx, cy);
            dragPixels(cx, cy, cx + 150, cy + 120);
        },
        { cmd("tool.set prim.arc off"); });

    // --- (e) VertexTool: the record is INLINED in `onMouseButtonDown` — there
    //     is no commit method at all, and `hasUncommittedEdit()` is likewise
    //     hard-coded false. One click is one entry.
    cells ~= runCell("prim.vertex/click", "prim.vertex",
        "source/tools/create/vertex_place.d VertexTool.onMouseButtonDown (inline history_.record)",
        "Plain", "MeshSessionEdit",
        {
            resetEmpty(); cmd("history.clear");
            setOrbitCamera(0.0, 0.2, 3.0);
            cmd(`tool.set "prim.vertex" on 0`);
        },
        { playAndWait(kClickHeader ~ "\n" ~ clickAt(100, 350, 280), BASE); settle(); },
        { cmd(`tool.set "prim.vertex" off 0`); });

    // --- (f) PenTool: three clicks and Enter. A standing edit with NO commit
    //     override (a T7 sibling), committing from its own keyboard handler.
    cells ~= runCell("pen/triangle", "pen",
        "source/tools/create/pen.d PenTool.commitPolygonWithUndo",
        "Plain", "MeshSessionEdit",
        {
            resetEmpty(); cmd("history.clear");
            setOrbitCamera(0.0, 0.2, 3.0);
            cmd(`tool.set "pen" on 0`);
        },
        {
            playAndWait(kClickHeader ~ "\n"
                      ~ clickAt(100, 350, 280) ~ "\n"
                      ~ clickAt(200, 430, 280) ~ "\n"
                      ~ clickAt(300, 390, 340) ~ "\n"
                      ~ `{"t":400,"type":"SDL_KEYDOWN","sym":13,"scan":0,"mod":0,"repeat":0}` ~ "\n"
                      ~ `{"t":410,"type":"SDL_KEYUP","sym":13,"scan":0,"mod":0,"repeat":0}`,
                        BASE);
            settle();
        },
        { cmd(`tool.set "pen" off 0`); });

    // --- (g) MagnetTool: the `setEdit` installer and the `MeshVertexEdit`
    //     payload — the one non-wrapper tool on that class, and the reason the
    //     seam's carrier interface cannot be a set of snapshot setters.
    cells ~= runCell("xfrm.magnet/drag", "xfrm.magnet",
        "source/tools/deform/magnet.d MagnetTool.commitEdit (cmd.setEdit)",
        "Plain", "MeshVertexEdit",
        { resetCube(); cmd("history.clear"); setOrbitCamera(); cmd("tool.set xfrm.magnet"); },
        {
            int x0, y0; px(Vec3(0.5f, 0.5f, 0.5f), x0, y0);
            hoverDrag(x0, y0, x0 + 100, y0);
        },
        { cmd("tool.set xfrm.magnet off"); });

    // --- (h) edge.extend: the `setDelta` installer, a RECORDING MeshEditBatch,
    //     and the degenerate-arm site P0-a instrumented. Its REDO does not
    //     restore `edgePlanes` / `selectionOrderCounters`; that is frozen as an
    //     exact residual list, never tolerated.
    cells ~= runCell("edge.extend/drag", "edge.extend",
        "source/tools/edit/edge_extend.d EdgeExtendTool.commitEdit (cmd.setDelta)",
        "Plain", "MeshSessionEdit+delta",
        {
            resetCube();
            auto r = postJ("/api/select",
                `{"mode":"edges","indices":[` ~ findEdgeXPosZNeg().to!string ~ `]}`);
            assert(r["status"].str == "ok", "edge select failed: " ~ r.toString);
            cmd("history.clear");
            setOrbitCamera();
            cmd("tool.set edge.extend on");
            settle(250);
        },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            Vec3 anchor = Vec3(0.5f, 0.0f, -0.5f);
            enum float R = 0.70710678f;
            Vec3 axis   = Vec3(R, 0.0f, -R);
            float arm   = gizmoSize(anchor, vp);
            Vec3 press  = anchor + axis * (arm * 0.6f);
            float ax, ay, tx, ty, pxx, pyy;
            assert(projectToWindow(anchor, vp, ax, ay), "anchor behind camera");
            assert(projectToWindow(anchor + axis, vp, tx, ty), "axis behind camera");
            assert(projectToWindow(press, vp, pxx, pyy), "shaft mid-point off-camera");
            immutable double sdx = tx - ax;
            assert(abs(sdx) > 20.0,
                "the extend axis must project with a real horizontal component "
              ~ "for this drag to separate the arrow branch from the free one");
            dragPixels(cast(int) pxx, cast(int) pyy,
                       cast(int) pxx + (sdx > 0 ? 80 : -80), cast(int) pyy, 16);
        },
        { cmd("tool.set edge.extend off"); });

    // --- (i) edge.extrude, the twin — and the cell that cost this lane a drive
    //     path. The shipped `test_edge_extrude_handle_drag.d` grabs the EXTRUDE
    //     arrow only; measured on this stand that leaves `width == 0`, the
    //     kernel affects ZERO edges, `built` stays false and the drop records
    //     nothing while the `extrude` attribute reads 0.47. So this cell grabs
    //     the WIDTH part first and the EXTRUDE arrow second, and the
    //     anti-vacuity in `runCell` is what would catch a regression back to
    //     the attribute-only drag.
    cells ~= runCell("edge.extrude/drag", "edge.extrude",
        "source/tools/edit/edge_extrude.d EdgeExtrudeTool.commitEdit (cmd.setDelta)",
        "Plain", "MeshSessionEdit+delta",
        {
            resetCube();
            auto r = postJ("/api/select",
                `{"mode":"edges","indices":[` ~ findEdgeXPosZNeg().to!string ~ `]}`);
            assert(r["status"].str == "ok", "edge select failed: " ~ r.toString);
            cmd("history.clear");
            setOrbitCamera();
            cmd("tool.set edge.extrude on");
            settle(250);
        },
        {
            int wx, wy; handlePx(1, wx, wy);          // width box
            dragPixels(wx, wy, wx - 40, wy, 12);
            int ex, ey; handlePx(0, ex, ey);          // extrude arrow
            dragPixels(ex, ey, ex + 70, ey, 12);
            auto st = getJ("/api/tool/state");
            assert(st["built"].type == JSONType.true_,
                "edge.extrude: the two handle drags left `built` false — the "
              ~ "kernel affected no edge, so the drop will record nothing. "
              ~ "This is exactly the non-gesture the shipped handle-drag test "
              ~ "cannot see: " ~ st.toString);
        },
        { cmd("tool.set edge.extrude off"); });

    freezeOrCompare(cells);
}
