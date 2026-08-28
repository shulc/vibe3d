// test_tool_gesture_g3 — task 1905, lane G0-G3: the FROZEN plane fixture for
// group G3 (the deform family: SmoothShift and StrokeExtrude), driven by REAL
// GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G3 witnesses can replace it.
// The text census (plan §5.1) sees WHO calls a history primitive; the wire-name
// cell (§5.2) sees WHICH record went on the stack. Neither can see the seam
// writing the RIGHT record with the WRONG geometry — a swapped snapshot pair, a
// stale `after`, a kernel argument that drifted. That defect is invisible to a
// count, invisible to a name, and invisible to a single wholesale before/after
// compare, because the wholesale compare is satisfied by any pair of dumps that
// happen to round-trip. So every cell here freezes FOUR plane-complete dumps
// and compares them PLANE BY PLANE, in BOTH directions:
//   postUndo  against the PRE-OPERATION dump,
//   postRedo  against the POST-COMMIT dump.
//
// G3 DOES NOT SHARE THE SINGLE-WIRE-NAME PROPERTY — measured, and it is the
// first group of this task that does not. The G0-G1 lane found the create
// family recording every entry under one name (`mesh.bevel_edit`), and the
// G0-G4 lane found nine of eleven doing the same; that is what forced plan
// §5.5's correction away from `entryNames`. Here the two members record under
// TWO DISTINCT names — `mesh.smooth_shift_edit` and `mesh.strokeExtrude_edit`,
// from two distinct factories (`smoothShiftEditFactory`,
// `strokeExtrudeEditFactory`, `source/app.d`) — so in THIS group a mutation
// that must redden exactly one cell CAN key on `entryNames`. `liveEntryNames`
// is carried anyway, and both cells freeze it EMPTY: both tools record from
// `deactivate`, so nothing stands on the ledger between gesture and drop. That
// empty list is a pin, not a placeholder — a member that started recording
// synchronously inside its own event handler (the shape `mesh.dragWeld` and
// `mesh.tack` have in G4) would redden it.
//
// THE CARD'S "RISKIEST BATCHLESS PREVIEW" NOTE IS STALE, and this lane
// re-measured it rather than repeating it. Plan §6 already says G3 carries zero
// batchless previews; confirmed by reading both files on this tree:
// `stroke_extrude_tool.d:326` and `smooth_shift_tool.d:259` / `:426` each open
// `MeshEditBatch.unrecorded` around their kernel call. The inherited item 6
// ("the riskiest is `stroke_extrude_tool`, its preview writes the DOCUMENT mesh
// every frame") describes a tree two stages old.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. `tool.doApply`
// records a `ToolDoApplyCommand` — a different entry, from a different site —
// so a cell built on it would freeze the geometry of a command while claiming
// to pin a tool's own `commitEdit`. For `tool.strokeExtrude` that is not even
// an option: its `applyHeadless()` returns false unconditionally, faithfully
// reproducing a captured finding, so the mouse is the ONLY input that reaches
// its record site.
//
// THE SHIPPED COVERAGE OF THIS GROUP, MEASURED RATHER THAN ASSUMED:
//
//   * `mesh.smoothShiftTool` — `tests/test_smooth_shift_handle_drag.d` drives a
//     REAL arrow drag (measured on this stand: the cube goes 8v/6f -> 12v/10f),
//     but its only assertion is `abs(shift) > 1e-3`. An attribute moves whether
//     or not the kernel touched a face, so that file would stay green if the
//     tool stopped building and stopped recording altogether. Drive real,
//     ASSERTION hollow — the same shape `test_vertex_bevel_handle_drag.d`
//     carries, which is why plan §5.3 forbids copying that file's anti-vacuity.
//   * `tool.strokeExtrude` — NO interactive witness anywhere in `tests/`.
//     `tests/test_stroke_extrude.d` drives the one-shot `mesh.strokeExtrude`
//     COMMAND (zero `play-events` in the file); the tool's own record site had
//     never been reached by the suite before this cell. Plan §6 names it as one
//     of the three tools in that state.
//
// So both cells assert the ELEMENT COUNT GREW, by name, before anything is
// compared — the check neither shipped file has.
//
// `built` IS NOT A CHANNEL IN THIS GROUP — measured: `/api/tool/state` answers
// `{}` for both members (tree-wide the flag is published by only six tools, and
// neither of these is one). So the brief's "assert the tool reports itself
// built" is discharged here by the two strictly stronger observables it stands
// in for: `postCommit != preOp` plus `undoDelta == 1` in `runCell`, and a named
// vertex-count assertion inside each gesture.
//
// WHY THE FAILURES ACCUMULATE INSTEAD OF FAILING FAST. The acceptance criterion
// for this lane is plan §5.4's mutation table, whose every row names both the
// fields that must REDDEN and the fields that must stay GREEN. A cell that
// fails fast reports the first and hides the rest, so the green column — the
// half that makes a mutation DISCRIMINATING rather than merely loud — would not
// be observable at all. Fields accumulate; cells still fail on the first.
//
// ANTI-VACUITY, TWO LEVELS. Block 0 is a POSITIVE CONTROL FIRST, copied from
// `tests/test_edge_bevel_seam_counters.d:222-241`: it moves the SAME three
// channels this file then asserts on — `/api/mesh/planes`, the undo depth, the
// wire name — with a command that belongs to no group in this task, because a
// dead channel satisfies "this residual list is EMPTY" for free. It is
// deliberately NOT copied from `tests/test_vertex_bevel_handle_drag.d:115-125`,
// whose anti-vacuity is an `inset` value: that proves a drag began, not that the
// channel it then asserts zero on is alive. Level two is per cell, inside
// `runCell`.
//
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. Both cells round-trip
// byte-for-byte in both directions on this tree, so every residual list is
// frozen EMPTY — and an empty list pinned exactly is still a pin: a residual
// that APPEARS reddens. Had one been non-empty it would have been frozen as its
// exact plane list, so that a residual which grows and a residual which
// disappears both redden.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G3=<abs path to g3.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g3`.
import std.algorithm : sort, canFind;
import std.array     : appender, array;
import std.conv      : to;
import std.format    : format;
import std.json;
import std.math      : abs, sqrt;
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
enum string kFrozen = import("fixtures/tool_gesture/g3.json");

/// The one file allowed to write `g3.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g3.d";

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

double attrOf(string tool, string name) {
    auto r = postJ("/api/command", "tool.attr " ~ tool ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok",
        "tool.attr " ~ tool ~ " " ~ name ~ " ? failed: " ~ r.toString);
    return r["value"].type == JSONType.integer
         ? cast(double) r["value"].integer : r["value"].floating;
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

size_t vertexCount() { return getJ("/api/model")["vertices"].array.length; }

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
    string   payload;      // MeshSessionEdit | MeshVertexEdit | …
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
    // and it is the failure two SHIPPED tests of this very group already carry
    // (`test_vertex_extrude_handle_drag.d`, `test_vert_merge_drag.d`: the
    // attribute moves, the kernel touches nothing, the drop records nothing).
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
    s ~= "  \"family\": \"tool_gesture_g3\",\n";
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
    string msg = "tests/fixtures/tool_gesture/g3.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G3` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g3: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G3", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g3.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g3.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g3.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g3.json: cell %d is '%s' frozen and '%s' now — the roster "
                 ~ "was reordered", i, fc[i]["name"].str, c.name));
        scoreCell(c, fc[i]);
    }
}

// ---------------------------------------------------------------------------
// Stands and gestures
// ---------------------------------------------------------------------------

void resetCube() {
    auto r = postJ("/api/reset");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}

void setCamera(double az, double el, double dist,
               double fx = 0, double fy = 0, double fz = 0) {
    auto r = postJ("/api/camera",
        format(`{"azimuth":%g,"elevation":%g,"distance":%g,`
             ~ `"focus":{"x":%g,"y":%g,"z":%g}}`, az, el, dist, fx, fy, fz));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
}

/// The framing every cell is frozen under. Written EXPLICITLY rather than
/// inherited from `/api/reset`'s default pose: the drag distances below are
/// pixels, the geometry they buy is world units, and a fixture that leans on a
/// default pose re-freezes itself the day that default moves.
void setOrbitCamera(double dist = 4.0) { setCamera(0.4, 1.1, dist); }

void selectMode(string mode, int[] idx) {
    auto r = postJ("/api/select",
        format(`{"mode":"%s","indices":%s}`, mode, idx.to!string));
    assert(r["status"].str == "ok",
        "select " ~ mode ~ " " ~ idx.to!string ~ " failed: " ~ r.toString);
}

void dragPixels(int x0, int y0, int x1, int y1, int steps = 16) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    settle(120);
}

/// A stationary hover so the press hit-test reads a cursor already on the
/// handle. The override behind `queryMouse()` is updated on MOTION events only,
/// so a log that opens with the button-down hit-tests against a stale cursor.
void hover(int x, int y) {
    auto cam = fetchCamera(BASE);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    playAndWait(log, BASE);
    settle(150);
}

/// The screen anchor of a registered handle part (`/api/tool/handles`). Used
/// instead of re-deriving the arm geometry wherever the tool publishes one: a
/// re-derivation that drifts from the tool silently turns the drag into the
/// "attribute moved, nothing built" non-gesture this file exists to reject.
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
// 1. The roster: TWO cells, one per G3 record site.
//
//    Both write through `history.record` (mode `Plain`) and both carry a
//    `MeshSessionEdit` — measured, not assumed: the two factories this group is
//    bound to (`smoothShiftEditFactory`, `strokeExtrudeEditFactory`,
//    `source/app.d:3658` / `:3667`) construct that one class, under two
//    different wire names. Two tools, two record sites, two hand-written commit
//    bodies — the smallest group of the task, and the only one whose members
//    are told apart by their wire name alone.
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) SmoothShiftTool. Two handle parts (Offset, Scale); the Offset
    //     haul alone builds. The press point comes from `/api/tool/handles`
    //     rather than a re-derivation of the arrow shaft — a re-derivation that
    //     drifts from the tool turns the drag into the "attribute moved,
    //     nothing built" non-gesture this file exists to reject.
    cells ~= runCell("smooth.shift/offset-drag", "mesh.smoothShiftTool",
        "source/tools/deform/smooth_shift_tool.d SmoothShiftTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.smoothShiftTool on"); settle(250); },
        {
            immutable size_t v0 = vertexCount();
            int hx, hy; handlePx(0, hx, hy);
            hover(hx, hy);
            dragPixels(hx, hy, hx, hy - 80, 16);
            assert(vertexCount() > v0,
                "smooth.shift: the Offset haul added no vertex (still "
              ~ v0.to!string ~ ") even though `shift` reads "
              ~ attrOf("mesh.smoothShiftTool", "shift").to!string ~ ". That is "
              ~ "exactly what `tests/test_smooth_shift_handle_drag.d` cannot "
              ~ "see: its only anti-vacuity is that attribute, which moves "
              ~ "whether or not the kernel touched a face");
        },
        { cmd("tool.set mesh.smoothShiftTool off"); });

    // --- (b) StrokeExtrudeTool, the member with no interactive witness in the
    //     suite at all. NO handle and NO headless path: the press anchors the
    //     path at the selection's face centroid wherever it lands, every motion
    //     ray-casts a new tip, and a new span commits each time the cursor has
    //     travelled `prec` (30) pixels. So the drive is a press ON the selected
    //     face's centroid followed by a 180 px haul — six spans' worth — and
    //     the drop records the whole stroke as ONE entry.
    cells ~= runCell("stroke.extrude/straight-stroke", "tool.strokeExtrude",
        "source/tools/deform/stroke_extrude_tool.d StrokeExtrudeTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set tool.strokeExtrude on"); settle(250); },
        {
            immutable size_t v0 = vertexCount();
            auto vp = viewportFromCamera(fetchCamera(BASE));
            float cx, cy;
            assert(projectToWindow(Vec3(0.0f, 0.5f, 0.0f), vp, cx, cy),
                "stroke.extrude: the +Y face centroid projects behind the "
              ~ "camera — the press would fall on no selected polygon and the "
              ~ "tool consumes nothing");
            hover(cast(int) cx, cast(int) cy);
            dragPixels(cast(int) cx, cast(int) cy, cast(int) cx, cast(int) cy - 180, 16);
            assert(vertexCount() > v0,
                "stroke.extrude: the 180 px stroke added no vertex (still "
              ~ v0.to!string ~ "). This tool publishes no `built` flag and no "
              ~ "attribute that moves with the kernel, so the element count is "
              ~ "the ONLY thing that separates a real stroke from a press that "
              ~ "missed the selection");
        },
        { cmd("tool.set tool.strokeExtrude off"); });

    freezeOrCompare(cells);
}
