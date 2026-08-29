// test_tool_gesture_g7 — task 1905, lane G0-G7: the FROZEN plane fixture for
// group G7 (the topology-pen family), driven by REAL GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G7 witnesses can replace it.
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
// ---------------------------------------------------------------------------
// WHAT MAKES G7 ITS OWN FAMILY, MEASURED ON THIS TREE
// ---------------------------------------------------------------------------
//
// TWO RECORD SITES, not one. `TopologyPenTool.placeVertexAt` records a
// `MeshVertexNew` raw; every other gesture goes through the shared tail
// `TopologyPenTool.recordSnapshotUndo`, reached from THIRTEEN call sites. As of
// task 1905 phase D both go through `Tool.recordGestureEdit(cmd,
// GestureRecordMode.Plain)`, and the whole package's own history call surface is
// exactly ZERO (measured with comments stripped; the pin lives in
// `tests/unit/tool_commit_seam_census_g7_test.d`, members 2 and 3).
//
// THIRTEEN FACTORIES BOUND POSITIONALLY. `TopologyPenTool.setPenFactories`
// takes the thirteen `MeshSessionEdit delegate()` factories as thirteen
// structurally IDENTICAL defaulted parameters, and `source/registration.d`
// passes them by position; the declaration's own comment says a mis-ordered
// argument "would compile and silently label one op as another". Nothing in
// the tree checked that order until lane G0-G7. This file checks four of the
// thirteen behaviourally (`build`, `move`, `remove`, `dupLoop`) and
// `tests/unit/tool_commit_seam_census_g7_test.d` (member 7) closes the other
// nine with a composed position -> field -> factory-identifier roster.
//
// G7 DOES NOT SHARE THE SINGLE-WIRE-NAME PROPERTY — BUT IT HAS A HARDER ONE.
// The G0-G1 lane found the create family recording every entry under one wire
// name (`mesh.bevel_edit`), which is what forced plan §5.5's correction away
// from `entryNames`; G0-G4 found nine of eleven doing the same; G0-G3 found two
// members under two distinct names. G7 is neither. It publishes THIRTEEN
// distinct wire names, one per factory — and then binds TWO DIFFERENT GESTURES
// to ONE of them:
//
//     gesture                       factory              wire name              label
//     ----------------------------- -------------------- ---------------------- --------------------------
//     Shift+LMB from a VERTEX       factories_.build     mesh.topoPen_build     "Topology Build"
//     Shift+LMB from an EDGE        factories_.build     mesh.topoPen_build     "Topology Duplicate Edge"
//     Shift+RMB from an EDGE        factories_.dupLoop   mesh.topoPen_duploop   "Topology Duplicate Loop"
//
// So for eleven of the thirteen factories a mutation CAN key on `entryNames`,
// and for the build/duplicate-edge pair it CANNOT. That is why this file
// carries `entryLabels` beside `entryNames`: `/api/history` publishes `label`
// on every entry, and the label is the ONLY wire observable separating gesture
// #6 from gesture #15. Both are frozen; a mutation that must redden exactly
// one of those two cells keys on the label.
//
// THE TWO THAT SHARE A KERNEL ARE INDISTINGUISHABLE ON EVERY PLANE — measured
// here, not assumed. `commitDupEdges` serves the Shift+LMB single-edge gesture
// (through `dupEdgeUp`, factory `build`) and the Shift+RMB loop gesture
// (through `commitDupLoop`, factory `dupLoop`). On the stand below the two
// differ ONLY in the mouse button, and their `preOp`, `postCommit`, `postUndo`
// and `postRedo` dumps come back BYTE-IDENTICAL — same six vertices, same
// seven edges, same two faces, same positions. Merging the two gestures, or
// pointing one at the other's factory, is therefore invisible to every
// geometry assertion in `tests/` and shows up ONLY as a wire name and a label.
// The two cells are deliberately built on the SAME stand and the SAME press
// pixel and the SAME drag so that this is a property the fixture PINS rather
// than a claim its prose makes.
//
// ---------------------------------------------------------------------------
// THE SHIPPED COVERAGE OF THIS GROUP, MEASURED RATHER THAN ASSUMED
// ---------------------------------------------------------------------------
//
// Plan §6 says G7 "is REQUIRED to bring its own positive cell" because its
// three named cells — `test_topopen_addloop_clamp.d:59`,
// `test_topopen_move_stationary_noop.d:64`, `test_topopen_smooth_no_bg.d:113`
// — all assert the undo depth did NOT change and none of the three calls
// `/api/undo` anywhere in its file. That is TRUE of those three, and it was
// re-verified here. It is NOT true of the group: `test_topopen_place_undo.d`
// drives a real click and round-trips `/api/undo` + `/api/redo`, and the
// mutation section of this lane's card records which of the two the deletion
// of the raw record site actually reddens.
//
// What no shipped file in the group asserts, and what this fixture adds:
//   * the WIRE NAME of any topology-pen entry — zero of the 48
//     `tests/test_topopen_*.d` files reads `/api/history`'s `command` field;
//   * the LABEL of any entry — likewise zero, which is why the build /
//     duplicate-edge pair has never been told apart by anything but the shape
//     of the geometry each happens to produce;
//   * the plane-complete dump in BOTH directions — the shipped undo tests
//     compare vertex counts and a handful of positions, never the marks, the
//     set masks, the per-face material/part or the edge planes.
//
// `built` IS NOT A CHANNEL IN THIS GROUP — the flag is on the wire for only six
// tools tree-wide and `mesh.topoPen` is not one of them. So the brief's "assert
// the tool reports itself built" is discharged here by strictly stronger
// observables: `postCommit != preOp` plus `undoDelta == 1` in `runCell`, and a
// NAMED element-count or position assertion inside every one of the six
// gestures.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. `tool.doApply`
// records a `ToolDoApplyCommand` — a different entry from a different site — so
// a cell built on it would freeze the geometry of a command while claiming to
// pin the tool's own record site. For this tool it is not even an option: every
// one of the fifteen gestures is armed and committed inside the SDL button
// handlers, and the mouse is the only input that reaches either record site.
//
// WHY THE FAILURES ACCUMULATE INSTEAD OF FAILING FAST. The acceptance criterion
// for this lane is plan §5.4's mutation table, whose every row names both the
// fields that must REDDEN and the fields that must stay GREEN. A cell that
// fails fast reports the first and hides the rest, so the green column — the
// half that makes a mutation DISCRIMINATING rather than merely loud — would not
// be observable at all. Fields accumulate; cells still fail on the first.
//
// ANTI-VACUITY, TWO LEVELS. Block 0 is a POSITIVE CONTROL FIRST, copied from
// `tests/test_edge_bevel_seam_counters.d:222-241`: it moves the SAME four
// channels this file then asserts on — `/api/mesh/planes`, the undo depth, the
// wire name, the label — with a command that belongs to no group in this task,
// because a dead channel satisfies "this residual list is EMPTY" for free. It
// is deliberately NOT copied from `tests/test_vertex_bevel_handle_drag.d:115-125`,
// whose anti-vacuity is an `inset` value: that proves a drag began, not that
// the channel it then asserts zero on is alive. Level two is per cell, inside
// `runCell` and inside each gesture.
//
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. Every cell round-trips
// byte-for-byte in both directions on this tree, so every residual list is
// frozen EMPTY — and an empty list pinned exactly is still a pin: a residual
// that APPEARS reddens. Had one been non-empty it would have been frozen as its
// exact plane list, so that a residual which grows and a residual which
// disappears both redden.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G7=<abs path to g7.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g7`.
import std.algorithm : sort, canFind, startsWith, endsWith;
import std.array     : appender;
import std.conv      : to;
import std.format    : format;
import std.json;
import std.math      : abs, sqrt;
import std.net.curl  : get, post;
import std.process   : environment;
import std.string    : split;
import core.thread   : Thread;
import core.time     : dur;

import topopen_place_helpers : Vec3, Viewport, CameraState,
    fetchCamera, viewportFromCamera, projectToWindow, buildDragLog,
    setupSphereBg, waitPlayerIdle;

void main() {}

enum string BASE = "http://localhost:8080";

/// The frozen oracle. Read through `import()` rather than off disk: the suite
/// lane compiles a scratch COPY of `tests/`, and `-J=tests` resolves this in
/// both trees while `__FILE_FULL_PATH__` would name the copy.
enum string kFrozen = import("fixtures/tool_gesture/g7.json");

/// The one file allowed to write `g7.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g7.d";

/// The recipe this fixture records, hoisted out of `fixtureJson` (task 3370)
/// so the `provenance` block's own prose quotes THE SAME text the `recipe`
/// key is emitted from, instead of a second copy able to drift from it.
enum string kRecipe = "stand -> gesture (/api/play-events) -> drop -> undo -> redo";

// The background sphere every stand loads. Resolution and radius are the
// topology-pen suite's own (`tests/topopen_place_helpers.d`), so the re-snap
// law the duplicate gestures obey is the one every other file in the group
// already measures against.
enum float kBgR   = 2.0f;
enum int   kBgLon = 96, kBgLat = 72;

/// The primary-layer quad four of the six cells press on. Half-extent taken
/// from `tests/test_topopen_dup_edge_drag.d` so the press pixel clears the
/// tool's own 8 px vertex pick reach by the same margin that file measured.
enum float kQuadHalf = 0.75f;

/// KMOD_LSHIFT / KMOD_LCTRL, the two modifiers the pen's chords read.
enum uint kLShift = 0x0001;
enum uint kLCtrl  = 0x0040;

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

string getRaw(string path)  { return cast(string) get(BASE ~ path); }
JSONValue getJ(string path) { return parseJSON(getRaw(path)); }

JSONValue postJ(string path, string body_ = "") {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmdLine(string line) {
    auto r = postJ("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString
      ~ " — the stand this cell measures was never built");
    // Task 3091: every `tool.set` / `tool.attr` WRITE this cell issues IS a
    // captured parameter (schema 3010) — recorded off the SAME string that
    // drives the wire command. A trailing `?` is a READ (no reader in this
    // file uses one through `cmdLine()`; the guard stays here anyway so a
    // future read cannot be mistaken for a drive).
    if ((line.startsWith("tool.set ") || line.startsWith("tool.attr "))
        && !line.endsWith(" ?"))
        gDrove ~= parseToolLine(line);
}

// ---------------------------------------------------------------------------
// Parameter capture (task 3091) — the `parameters` block (schema 3010). See
// tests/test_tool_gesture_g1.d for the full rationale.
struct Drove { string op; string values; }

Drove[] gDrove;

string jsonScalar(string raw) {
    if (raw == "true" || raw == "false") return raw;
    bool numeric = raw.length > 0;
    bool sawDot = false;
    foreach (i, ch; raw) {
        if (ch == '-' && i == 0) continue;
        if (ch == '.' && !sawDot) { sawDot = true; continue; }
        if (ch < '0' || ch > '9') { numeric = false; break; }
    }
    return numeric ? raw : (`"` ~ raw ~ `"`);
}

Drove parseToolLine(string line) {
    auto toks = line.split();
    assert(toks.length >= 2, "parseToolLine: too short: " ~ line);
    string id = toks[1];
    if (id.length >= 2 && id[0] == '"' && id[$ - 1] == '"') id = id[1 .. $ - 1];
    if (toks[0] == "tool.set") {
        if (toks.length >= 3 && toks[2] == "on")  return Drove("tool.set " ~ id, `{"on": true}`);
        if (toks.length >= 3 && toks[2] == "off") return Drove("tool.set " ~ id, `{"off": true}`);
        return Drove("tool.set " ~ id, "{}");
    }
    assert(toks.length >= 4, "parseToolLine: tool.attr needs name+value: " ~ line);
    return Drove("tool.attr " ~ id,
        `{"` ~ toks[2] ~ `": ` ~ jsonScalar(toks[3]) ~ `}`);
}

/// `gesture.drag` — this family's presses carry no hover phase, so (unlike
/// every other producer in this task) there is no `hover` field to record.
Drove driveDrag(int dxPx, int dyPx, int steps = 16, int button = 1, int mod = 0) {
    return Drove("gesture.drag", format(
        `{"dx_px": %d, "dy_px": %d, "steps": %d, "button": %d, "mod": %d}`,
        dxPx, dyPx, steps, button, mod));
}

/// `gesture.press` — a single down+up at one pixel (`pressReleaseLog`), the
/// pixel itself always a projection of STAND geometry (a vertex, an edge
/// midpoint, a face centroid, or the viewport centre) and never a literal.
Drove drivePress(int button = 1, int mod = 0) {
    return Drove("gesture.press", format(`{"button": %d, "mod": %d}`, button, mod));
}

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks, no per-face material/part and no map values, and every
/// one of those is a plane an undo can silently lose. It answers off the ACTIVE
/// mesh, which on every stand below is the primary EDIT layer — never the
/// background sphere.
string planes() { return getRaw("/api/mesh/planes"); }

string[] historyNames() {
    string[] out_;
    foreach (e; getJ("/api/history")["undo"].array) out_ ~= e["command"].str;
    return out_;
}

/// The second wire observable, and in this family it is load-bearing rather
/// than decorative: `mesh.topoPen_build` is carried by TWO gestures and the
/// label is what separates them.
string[] historyLabels() {
    string[] out_;
    foreach (e; getJ("/api/history")["undo"].array) out_ ~= e["label"].str;
    return out_;
}

long undoLen() { return cast(long) getJ("/api/history")["undo"].array.length; }

size_t vertexCount() { return getJ("/api/model")["vertices"].array.length; }
size_t edgeCount()   { return getJ("/api/model")["edges"].array.length; }
size_t faceCount()   { return getJ("/api/model")["faces"].array.length; }

double[3] vertexAt(size_t i) {
    auto v = getJ("/api/model")["vertices"].array[i].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void settle(int ms = 150) { Thread.sleep(dur!"msecs"(ms)); }

void play(string log) {
    auto r = postJ("/api/play-events", log);
    assert("error" !in r, "/api/play-events failed: " ~ r.toString);
    waitPlayerIdle();
    settle(120);
}

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
    string   payload;      // MeshSessionEdit | MeshVertexNew | …
    string[] liveEntryNames;  // wire names standing between gesture and drop
    string[] entryNames;      // wire names standing after the commit
    string[] entryLabels;     // labels standing after the commit — the ONLY
                              // observable separating this family's two
                              // `mesh.topoPen_build` gestures
    long     undoDelta;       // EXACT, never "> 0"
    string   preOp, postCommit, postUndo, postRedo;
    string[] undoResidual;    // planes where postUndo differs from preOp
    string[] redoResidual;    // planes where postRedo differs from postCommit
    Drove[]  drove;           // task 3091: this cell's captured `parameters` drive
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

    gDrove = [];   // task 3091: this cell's own (stand, gesture, drop) drive
    stand();
    immutable long u0 = undoLen();
    assert(u0 == 0,
        name ~ ": the stand left " ~ u0.to!string ~ " undo entr(ies) standing. "
      ~ "`undoDelta` is measured from a CLEARED stack, and `/api/load-mesh` "
      ~ "plus `layer.add` both record, so the stand must clear history AFTER "
      ~ "it builds the scene");
    c.preOp = planes();

    gesture();
    c.liveEntryNames = historyNames();

    drop();
    settle();
    c.postCommit = planes();
    c.entryNames  = historyNames();
    c.entryLabels = historyLabels();
    c.undoDelta   = undoLen() - u0;
    c.drove       = gDrove;   // task 3091: captured after stand+gesture+drop

    // ANTI-VACUITY, BEFORE anything is compared. A gesture that moved no plane
    // makes every assertion below satisfiable by an undo that does nothing.
    assert(c.postCommit != c.preOp,
        name ~ ": the gesture moved NO plane. Its record, its undo and its redo "
      ~ "are then all satisfied by doing nothing. Either the drive missed the "
      ~ "press target, or the tool declined on this stand — check "
      ~ "`/api/tool/state`");
    assert(c.undoDelta == 1,
        name ~ ": the gesture left " ~ c.undoDelta.to!string ~ " undo entr(ies), "
      ~ "expected exactly 1. Zero means the commit never recorded; more than "
      ~ "one means a gesture that should be a single entry split");

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

/// Render this run's captured `parameters` block (schema 3010, task 3091).
/// `derived_from` is "generator": this producer IS the generator that emits
/// the fixture, and it built this block from `gDrove` — its own live drive
/// record — not by re-reading a previous fixture's copy.
string parametersJson(in Cell[] cells) {
    auto s = appender!string();
    s ~= "{\n";
    s ~= "    \"schema\": 1,\n";
    s ~= "    \"state\": \"recorded\",\n";
    s ~= "    \"derived_from\": \"generator\",\n";
    s ~= "    \"cells\": [\n";
    foreach (i, ref c; cells) {
        s ~= format("      {\"cell\": \"%s\", \"drove\": [", c.name);
        foreach (j, ref d; c.drove) {
            s ~= format(`{"op": "%s", "values": %s}`, d.op, d.values);
            if (j + 1 < c.drove.length) s ~= ", ";
        }
        s ~= (i + 1 < cells.length) ? "]},\n" : "]}\n";
    }
    s ~= "    ],\n";
    s ~= "    \"notes\": \"collected live by this producer's own runCell/cmdLine() "
       ~ "instrumentation (task 3091): tool.set/tool.attr values are parsed "
       ~ "off the wire argstring cmdLine() actually sent; gesture magnitudes "
       ~ "are recorded at their own driving call site\"\n";
    s ~= "  }";
    return s.data;
}

// ---------------------------------------------------------------------------
// Provenance capture (task 3370) — the `provenance` block (schema 1, task 0366).
//
// WHY THIS LIVES HERE, for exactly the reason `parametersJson` above does.
// Task 3140 hand-inserted a `provenance` block into all six of this family's
// fixtures — a surgical edit of the JSON FILE — but `fixtureJson()` never
// learned to emit one, so the next capture through this arm would silently
// drop it. This family's presence rule is ON (3140 enabled it immediately,
// unlike `parameters`'), so that drop does not wait: it reddens the ROUTINE
// lane, `dub test --config=tests` ->
// `tests/unit/fixture_provenance_census_test.d`, as "MISSING provenance
// block", and the private `provenance_check.py` names the file too.
//
// THE TRIAD, AND WHY `method` IS `self-drive` RATHER THAN `unknown`.
// `provenance.method` names the CHANNEL the frozen numbers were read
// through, and the vocabulary's own definitions
// (`tools/local/fixture_gen/provenance.py`, private) make almost every other
// value a REFERENCE read channel: `capture-drag`, `gui-gesture` and
// `command` each denote driving the reference editor (by pointer, by GUI
// gesture, by its command port); `from-trace`, `rr-memory`, `static-read`
// and `debug-live` each denote reading the reference's own execution or its
// shipped binary. Not one of them can be true of a fixture whose
// `reference` is `vibe3d-selfgen`. `closed-form` and `hand` are the two
// NON-EXECUTION answers — we derived the value analytically, or a human
// wrote it down — and both are false here: every number in the cells below
// came back over HTTP from a live vibe3d process this test itself started,
// armed and drove. What remains, and what the corpus already carries on all
// 22 of its `vibe3d-selfgen` fixtures without exception (13 `undo_parity/*`,
// 3 `loop_slice*`, and these 6), is `self-drive`: the harness drove the
// engine under test through the engine's own scripted interface.
//
// `unknown` would be the WRONG answer, not the cautious one. It is the
// schema's honest sentinel for "the record does not settle this" — and this
// producer is the one participant that cannot say that truthfully. It IS the
// driver; at the instant it emits the block it knows which endpoint it drove.
// Writing `unknown` here would erase a distinction the vocabulary keeps
// deliberately (the same harm backlog 3302 / task 3340 was filed for, where
// a stale list would have advised `unknown` over a VALID value).
//
// `captured_utc` IS THIS RUN'S WALL CLOCK, and it is the one field whose
// MEANING changes with this task. 3140 was labelling files captured days
// earlier and had no capture time to read, so it took the commit date of
// each file's own `producedBy` SHA out of git. A live generator has the real
// answer, and the schema names this exact path: `make_provenance`'s
// docstring says `captured_utc`, when omitted, "auto-fills to UTC-now (the
// live-generator path)" and is passed explicitly only "for a back-filled
// historical entry whose real capture time isn't known".
enum string kProvSource    = "simulated";       // no reference editor was read
enum string kProvReference = "vibe3d-selfgen";  // the engine driven IS vibe3d
enum string kProvMethod    = "self-drive";      // see the argument above
enum string kProvTask      = "1905";            // the lane that froze this family

/// This capture run's own time, UTC, in the `YYYY-MM-DDTHH:MM:SSZ` shape the
/// rest of the corpus uses. Built field by field rather than through
/// `toISOExtString` so the seconds-precision, `Z`-suffixed form is explicit.
string capturedUtcNow() {
    import std.datetime.systime  : Clock;
    import std.datetime.timezone : UTC;
    auto t = Clock.currTime(UTC());
    return format("%04d-%02d-%02dT%02d:%02d:%02dZ",
                  t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second);
}

/// Render this run's `provenance` block. Every prose field is DERIVED from
/// the same constants the fixture's other keys are written from — `kWrittenBy`
/// (which also fills `writtenBy`, and which the compare arm asserts against)
/// and `kRecipe` (which also fills `recipe`) — never retyped, so the block
/// cannot come to describe a producer or a recipe other than the one that
/// actually wrote the file it sits in.
string provenanceJson() {
    auto s = appender!string();
    s ~= "{\n";
    s ~= "    \"schema\": 1,\n";
    s ~= "    \"source\": \"" ~ kProvSource ~ "\",\n";
    s ~= "    \"reference\": \"" ~ kProvReference ~ "\",\n";
    s ~= "    \"method\": \"" ~ kProvMethod ~ "\",\n";
    s ~= "    \"captured_utc\": \"" ~ capturedUtcNow() ~ "\",\n";
    s ~= "    \"harness\": \"" ~ kWrittenBy ~ ", driven over /api/play-events "
       ~ "against vibe3d's own running instance -- no reference editor "
       ~ "involved (recipe: " ~ kRecipe ~ ")\",\n";
    s ~= "    \"task\": \"" ~ kProvTask ~ "\",\n";
    s ~= "    \"notes\": \"emitted by this producer at capture time (task "
       ~ "3370), from its own `kWrittenBy`/`kRecipe`; `captured_utc` is the "
       ~ "wall clock of the capture run itself. Before 3370 the block was a "
       ~ "hand insert (task 3140) that any re-capture would have dropped, and "
       ~ "`captured_utc` was the commit date of the `producedBy` SHA.\"\n";
    s ~= "  }";
    return s.data;
}

string fixtureJson(in Cell[] cells) {
    auto s = appender!string();
    s ~= "{\n";
    s ~= "  \"family\": \"tool_gesture_g7\",\n";
    s ~= "  \"parameters\": " ~ parametersJson(cells) ~ ",\n";
    s ~= "  \"writtenBy\": \"" ~ kWrittenBy ~ "\",\n";
    s ~= "  \"producedBy\": \"" ~ environment.get("VIBE3D_TOOL_GESTURE_SHA", "unknown") ~ "\",\n";
    s ~= "  \"stand\": \"per-cell; see each cell's `drive`\",\n";
    s ~= "  \"recipe\": \"" ~ kRecipe ~ "\",\n";
    s ~= "  \"provenance\": " ~ provenanceJson() ~ ",\n";
    s ~= "  \"cells\": [\n";
    foreach (i, ref c; cells) {
        s ~= "    {\n";
        s ~= format("      \"name\": \"%s\", \"tool\": \"%s\",\n", c.name, c.tool);
        s ~= format("      \"recordSite\": \"%s\", \"mode\": \"%s\", \"payload\": \"%s\",\n",
                    c.recordSite, c.mode, c.payload);
        s ~= format("      \"liveEntryNames\": %s,\n", JSONValue(c.liveEntryNames).toString());
        s ~= format("      \"entryNames\": %s,\n",     JSONValue(c.entryNames).toString());
        s ~= format("      \"entryLabels\": %s,\n",    JSONValue(c.entryLabels).toString());
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
        ~ " vs fresh " ~ JSONValue(fresh.entryNames).toString()
        ~ " — the wire name is what the history and a replay carry");
    field("entryLabels",
          jsonStrings(frozen["entryLabels"]) == fresh.entryLabels,
          "frozen " ~ frozen["entryLabels"].toString()
        ~ " vs fresh " ~ JSONValue(fresh.entryLabels).toString()
        ~ " — in THIS family the label is not decoration: `mesh.topoPen_build` "
        ~ "is carried by two different gestures and the label is the only wire "
        ~ "observable that separates them");
    field("liveEntryNames",
          jsonStrings(frozen["liveEntryNames"]) == fresh.liveEntryNames,
          "frozen " ~ frozen["liveEntryNames"].toString()
        ~ " vs fresh " ~ JSONValue(fresh.liveEntryNames).toString()
        ~ " — a NON-empty list here pins that this tool records SYNCHRONOUSLY "
        ~ "inside its own button handler; a member that moved its record to "
        ~ "`deactivate` would empty it");
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
    string msg = "tests/fixtures/tool_gesture/g7.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G7` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g7: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G7", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g7.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g7.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g7.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g7.json: cell %d is '%s' frozen and '%s' now — the roster "
                 ~ "was reordered", i, fc[i]["name"].str, c.name));
        scoreCell(c, fc[i]);
    }
}

// ---------------------------------------------------------------------------
// Stands and gestures
// ---------------------------------------------------------------------------

void setCamera(double az, double el, double dist,
               double fx = 0, double fy = 0, double fz = 0) {
    auto r = postJ("/api/camera",
        format(`{"azimuth":%g,"elevation":%g,"distance":%g,`
             ~ `"focus":{"x":%g,"y":%g,"z":%g}}`, az, el, dist, fx, fy, fz));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
}

/// The framing every cell is frozen under. Written EXPLICITLY rather than
/// inherited from any default pose: the drag distances below are pixels, the
/// geometry they buy is world units, and a fixture that leans on a default pose
/// re-freezes itself the day that default moves. Posted LAST in every stand —
/// `/api/load-mesh` restores the post-load camera.
void setStandCamera() { setCamera(0.3, 0.5, 8.0); }

/// Background sphere in layer 0, an EMPTY primary in layer 1. The background is
/// what every re-snap in this tool resolves against; with none, the duplicate
/// gestures leave their new vertices coincident and the position planes would
/// be vacuous.
void standEmptyPrimary() {
    setupSphereBg(kBgR, kBgLon, kBgLat);
    setStandCamera();
}

/// The same background plus ONE quad in the primary layer — the stand four
/// cells press on.
void standQuadPrimary() {
    setupSphereBg(kBgR, kBgLon, kBgLat);
    auto lq = postJ("/api/load-mesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);
    assert(vertexCount() == 4 && edgeCount() == 4 && faceCount() == 1,
        "stand: the primary layer must hold exactly the quad, got "
      ~ vertexCount().to!string ~ "v/" ~ edgeCount().to!string ~ "e/"
      ~ faceCount().to!string ~ "f");
    setStandCamera();
}

void penOn(string mode) {
    cmdLine("tool.set mesh.topoPen on");
    // The chords are ABSOLUTE — they resolve to their own action whatever the
    // dropdown says — but the mode is pinned anyway so a cell that drives an
    // UNMODIFIED press (place, move) names the row it means.
    cmdLine("tool.attr mesh.topoPen mode " ~ mode);
    settle(200);
}

void penOff() { cmdLine("tool.set mesh.topoPen off"); }

/// The screen pixel of primary-layer vertex `i`, projected through the SAME
/// formula the tool's own hit-test uses.
void vertexPx(size_t i, out int px, out int py) {
    auto c  = fetchCamera(BASE);
    auto vp = viewportFromCamera(c);
    auto v  = vertexAt(i);
    float sx, sy;
    assert(projectToWindow(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]),
                           vp, sx, sy),
        "vertex " ~ i.to!string ~ " does not project on-screen — the press "
      ~ "would land nowhere and the gesture would consume nothing");
    px = cast(int) sx; py = cast(int) sy;
}

/// One press+release at a single pixel, with a modifier and a button. Written
/// here rather than taken from `topopen_place_helpers.clickLog`, which hard-codes
/// button 1 and modifier 0 — the Remove gesture is Ctrl+MMB.
string pressReleaseLog(int px, int py, uint mod, ubyte btn) {
    auto c = fetchCamera(BASE);
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                  c.vpX, c.vpY, c.width, c.height) ~ "\n"
         ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  btn, px, py, mod) ~ "\n"
         ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  btn, px, py, mod) ~ "\n";
}

/// A dragged press from (x0,y0) to (x1,y1), through the suite's own builder so
/// the motion spacing and the `state` bitmask stay the ones every other
/// interactive test in the tree drives.
string dragLog(int x0, int y0, int x1, int y1, uint mod, ubyte btn) {
    auto c = fetchCamera(BASE);
    return buildDragLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x1, y1, 16, mod, btn);
}

/// The two duplicate cells press the MIDPOINT of the quad's 0-1 edge, and both
/// assert first that the pixel is on that edge and clear of every corner —
/// otherwise the VERTEX outcome arms instead and the cell measures a different
/// gesture under this one's name.
void quadEdge01Px(out int ex, out int ey) {
    auto c  = fetchCamera(BASE);
    auto vp = viewportFromCamera(c);
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        auto v = vertexAt(i);
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]),
                               vp, sx, sy),
            format("stand: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy;
    }
    ex = cast(int) ((qx[0] + qx[1]) * 0.5f);
    ey = cast(int) ((qy[0] + qy[1]) * 0.5f);
    foreach (i; 0 .. 4) {
        immutable float dx = qx[i] - ex, dy = qy[i] - ey;
        immutable float d  = sqrt(dx * dx + dy * dy);
        assert(d > 8.0f,
            format("stand: the press pixel must clear corner %d by more than the "
                 ~ "tool's own 8 px vertex reach (`topoPenPressPickPx`), else the "
                 ~ "VERTEX outcome arms and this cell measures a different "
                 ~ "gesture under this one's name; got %.1f px", i, d));
    }
}

/// The quad's screen centroid — where the Remove press lands.
void quadFacePx(out int fx, out int fy) {
    auto c  = fetchCamera(BASE);
    auto vp = viewportFromCamera(c);
    float sx = 0, sy = 0;
    foreach (i; 0 .. 4) {
        auto v = vertexAt(i);
        float px, py;
        assert(projectToWindow(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]),
                               vp, px, py),
            format("stand: quad corner %d must project on-screen", i));
        sx += px; sy += py;
    }
    fx = cast(int) (sx / 4.0f); fy = cast(int) (sy / 4.0f);
}

// ---------------------------------------------------------------------------
// 0. POSITIVE CONTROL FIRST, and it is not decoration.
//
//    Almost everything below is "the fresh dump equals the frozen one" and
//    "this residual list is EMPTY". A DEAD channel satisfies the second kind
//    for free: `/api/mesh/planes` answering a stale copy makes every
//    `undoResidual == []` true no matter what the undo did, an `/api/history`
//    that stopped reporting makes every `entryNames` compare against a
//    constant, and a `label` field that went empty would make `entryLabels` —
//    this family's ONLY separator for two of its gestures — silently agree
//    everywhere. So make the SAME four channels move first, with a command that
//    belongs to no group in this task.
//
//    Copied from `tests/test_edge_bevel_seam_counters.d:222-241`. Deliberately
//    NOT from `test_vertex_bevel_handle_drag.d:115-125`, whose anti-vacuity is
//    an `inset` value: that proves a drag began, not that the channel it then
//    asserts zero on is alive.
// ---------------------------------------------------------------------------
unittest {
    auto r0 = postJ("/api/reset");
    assert(r0["status"].str == "ok", "control: reset failed: " ~ r0.toString);
    cmdLine("history.clear");
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
        "CONTROL: the top history entry's command is '" ~ historyNames()[$ - 1]
      ~ "', expected 'mesh.clone' — the wire-NAME channel is not live");
    assert(historyLabels()[$ - 1].length > 0
        && historyLabels()[$ - 1] != historyNames()[$ - 1],
        "CONTROL: the top history entry's label is '" ~ historyLabels()[$ - 1]
      ~ "'. It must be non-empty AND distinct from the command name, or the "
      ~ "`entryLabels` field below is either a constant or a duplicate of "
      ~ "`entryNames` — and then the one observable separating this family's "
      ~ "two `mesh.topoPen_build` gestures does not exist");

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
// 1. The roster: SIX cells over a family of FIFTEEN gestures, chosen to cover
//    the STRUCTURE rather than the population — see this file's header and the
//    lane's card for the nine left out and why.
//
//      (a) place      — the RAW record site (`placeVertexAt` -> `history_.record`
//                       on a `MeshVertexNew`). The only gesture in the family
//                       whose wire name is not `mesh.topoPen_*`.
//      (b) build      — the SHARED record site (`recordSnapshotUndo`), factory
//                       slot 1 (`bf`).
//      (c) dupEdge    — the shared KERNEL `commitDupEdges`, arm A, ALSO factory
//                       slot 1: same wire name as (b), different label.
//      (d) dupLoop    — the shared KERNEL `commitDupEdges`, arm B, factory slot
//                       9 (`dlf`). Byte-identical to (c) on every plane.
//      (e) move       — factory slot 2 (`mf`), Position-only editScope.
//      (f) remove     — factory slot 3 (`rf`). Adjacent to (e) in the positional
//                       argument list, which is what makes the factory-swap
//                       mutation land on exactly two cells.
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) The RAW record site. `mode point` is required: the default
    //     `move` places nothing on empty space (the dropdown row, task 0483).
    cells ~= runCell("topoPen/place-on-background", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d TopologyPenTool.placeVertexAt",
        "Plain", "MeshVertexNew",
        { standEmptyPrimary(); penOn("point"); cmdLine("history.clear"); },
        {
            assert(vertexCount() == 0,
                "place: the primary layer must start empty, got "
              ~ vertexCount().to!string ~ " vertices");
            auto c = fetchCamera(BASE);
            play(pressReleaseLog(c.vpX + c.width / 2, c.vpY + c.height / 2, 0, 1));
            gDrove ~= drivePress(1, 0);
            assert(vertexCount() == 1,
                "place: the centre-pixel click placed " ~ vertexCount().to!string
              ~ " vertices, expected exactly 1. The sphere's centre is on the "
              ~ "lookAt forward axis, so the centre pixel's ray cannot miss it — "
              ~ "a zero here is the tool declining, not the rig aiming badly");
        },
        { penOff(); });

    // --- (b) The SHARED record site, through the Build gesture. The stand
    //     places the hub with a plain click and CLEARS HISTORY after it, so the
    //     measured gesture is the Shift+LMB drag alone.
    cells ~= runCell("topoPen/build-edge-from-vertex", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d "
      ~ "TopologyPenTool.buildFromSource -> recordSnapshotUndo",
        "Plain", "MeshSessionEdit",
        {
            standEmptyPrimary(); penOn("point");
            auto c = fetchCamera(BASE);
            play(pressReleaseLog(c.vpX + c.width / 2, c.vpY + c.height / 2, 0, 1));
            assert(vertexCount() == 1,
                "build stand: the hub click placed " ~ vertexCount().to!string
              ~ " vertices, expected 1 — with no hub the Shift-drag has nothing "
              ~ "to build from and the cell would measure a decline");
            cmdLine("history.clear");
        },
        {
            immutable size_t v0 = vertexCount(), e0 = edgeCount();
            int hx, hy; vertexPx(0, hx, hy);
            play(dragLog(hx, hy, hx + 80, hy + 40, kLShift, 1));
            gDrove ~= driveDrag(80, 40, 16, 1, kLShift);
            assert(vertexCount() == v0 + 1 && edgeCount() == e0 + 1,
                "build: the Shift+LMB drag from the hub produced "
              ~ vertexCount().to!string ~ "v/" ~ edgeCount().to!string ~ "e, "
              ~ "expected " ~ (v0 + 1).to!string ~ "v/" ~ (e0 + 1).to!string
              ~ "e (CASE-EDGE: one new vertex at the release, one new edge). "
              ~ "This tool publishes no `built` flag, so the element counts are "
              ~ "the only thing separating a real build from a press that "
              ~ "missed the hub");
        },
        { penOff(); });

    // --- (c) The shared KERNEL, arm A: Shift+LMB pressed on an EDGE. Records
    //     through `factories_.build`, so its wire name is (b)'s — and its LABEL
    //     is not. That pair is the reason this file carries `entryLabels`.
    cells ~= runCell("topoPen/dup-edge-shift-lmb", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d "
      ~ "TopologyPenTool.dupEdgeUp -> commitDupEdges -> recordSnapshotUndo",
        "Plain", "MeshSessionEdit",
        { standQuadPrimary(); penOn("move"); cmdLine("history.clear"); },
        {
            int ex, ey; quadEdge01Px(ex, ey);
            play(dragLog(ex, ey, ex + 45, ey + 30, kLShift, 1));
            gDrove ~= driveDrag(45, 30, 16, 1, kLShift);
            assert(vertexCount() == 6 && edgeCount() == 7 && faceCount() == 2,
                "dup-edge: duplicating one edge must give 6v/7e/2f (+2 vertices, "
              ~ "+3 edges, +1 bridge quad); got " ~ vertexCount().to!string ~ "v/"
              ~ edgeCount().to!string ~ "e/" ~ faceCount().to!string ~ "f");
        },
        { penOff(); });

    // --- (d) The shared KERNEL, arm B: the SAME stand, the SAME press pixel,
    //     the SAME drag — only the mouse button differs. Its four dumps come
    //     back byte-identical to (c)'s, which is exactly why the two gestures
    //     can only be told apart by the wire name and the label.
    cells ~= runCell("topoPen/dup-loop-shift-rmb", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d "
      ~ "TopologyPenTool.commitDupLoop -> commitDupEdges -> recordSnapshotUndo",
        "Plain", "MeshSessionEdit",
        { standQuadPrimary(); penOn("move"); cmdLine("history.clear"); },
        {
            int ex, ey; quadEdge01Px(ex, ey);
            play(dragLog(ex, ey, ex + 45, ey + 30, kLShift, 3));
            gDrove ~= driveDrag(45, 30, 16, 3, kLShift);
            assert(vertexCount() == 6 && edgeCount() == 7 && faceCount() == 2,
                "dup-loop: on a lone quad the gathered loop trims to the pressed "
              ~ "edge alone, so the kernel must produce the SAME 6v/7e/2f as the "
              ~ "single-edge arm; got " ~ vertexCount().to!string ~ "v/"
              ~ edgeCount().to!string ~ "e/" ~ faceCount().to!string ~ "f. If "
              ~ "this ever diverges from the dup-edge cell, the two gestures "
              ~ "have stopped sharing `commitDupEdges` and the header's claim "
              ~ "that only the name and label separate them is stale");
        },
        { penOff(); });

    // --- (e) Factory slot 2 (`mf`), Position-only. The element counts CANNOT
    //     move here, so the anti-vacuity is a position: a plain LMB grab-drag
    //     that leaves corner 0 where it was is the shipped
    //     `test_topopen_move_stationary_noop.d` no-op, not this gesture.
    cells ~= runCell("topoPen/move-vertex", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d "
      ~ "TopologyPenTool.recordLiveMove -> recordSnapshotUndo",
        "Plain", "MeshSessionEdit",
        { standQuadPrimary(); penOn("move"); cmdLine("history.clear"); },
        {
            immutable auto p0 = vertexAt(0);
            immutable size_t v0 = vertexCount(), f0 = faceCount();
            int hx, hy; vertexPx(0, hx, hy);
            play(dragLog(hx, hy, hx - 40, hy + 30, 0, 1));
            gDrove ~= driveDrag(-40, 30, 16, 1, 0);
            immutable auto p1 = vertexAt(0);
            immutable double d = sqrt((p1[0] - p0[0]) * (p1[0] - p0[0])
                                    + (p1[1] - p0[1]) * (p1[1] - p0[1])
                                    + (p1[2] - p0[2]) * (p1[2] - p0[2]));
            assert(d > 1e-3,
                "move: corner 0 travelled " ~ d.to!string ~ " world units — the "
              ~ "grab-drag moved nothing. This gesture is Position-only, so the "
              ~ "element counts cannot witness it and this distance is the ONLY "
              ~ "anti-vacuity the cell has");
            assert(vertexCount() == v0 && faceCount() == f0,
                "move: the gesture changed the element counts ("
              ~ v0.to!string ~ "v/" ~ f0.to!string ~ "f -> "
              ~ vertexCount().to!string ~ "v/" ~ faceCount().to!string ~ "f). "
              ~ "A Position-only factory recorded a topology change means the "
              ~ "drag welded or built instead of moving, and the cell is "
              ~ "measuring a different gesture");
        },
        { penOff(); });

    // --- (f) Factory slot 3 (`rf`), ADJACENT to (e) in the positional argument
    //     list. Remove commits on the press, not the release.
    cells ~= runCell("topoPen/remove-face-ctrl-mmb", "mesh.topoPen",
        "source/tools/edit/topology_pen/tool.d "
      ~ "TopologyPenTool.removeFaceAt -> recordSnapshotUndo",
        "Plain", "MeshSessionEdit",
        { standQuadPrimary(); penOn("move"); cmdLine("history.clear"); },
        {
            immutable size_t f0 = faceCount();
            int fx, fy; quadFacePx(fx, fy);
            play(pressReleaseLog(fx, fy, kLCtrl, 2));
            gDrove ~= drivePress(2, kLCtrl);
            assert(faceCount() == f0 - 1,
                "remove: the Ctrl+MMB press left " ~ faceCount().to!string
              ~ " faces, expected " ~ (f0 - 1).to!string ~ ". A press that "
              ~ "landed off the polygon declines silently and every comparison "
              ~ "below would be satisfied by an undo that does nothing");
        },
        { penOff(); });

    freezeOrCompare(cells);
}
