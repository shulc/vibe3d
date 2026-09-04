// test_tool_gesture_g4 — task 1905, lane G0-G4: the FROZEN plane fixture for
// group G4 (the eleven `edit`-family tools), driven by REAL GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G4 witnesses can replace it.
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
// G4 SHARES THE SINGLE-WIRE-NAME PROPERTY THE G1 LANE FOUND, and only just.
// Measured while freezing this file: NINE of the eleven cells record under the
// one name `mesh.bevel_edit` (the 24 `bevelEditFactory` registrations seen from
// the wire side). Only `poly.extrude` (`mesh.face_extrude_edit`) and
// `mesh.reduceTool` (`mesh.reduce_edit`) stand apart. So a mutation that has to
// redden EXACTLY ONE cell of this group cannot key on `entryNames` either — the
// same correction the G1 lane forced on plan §5.5. `liveEntryNames` is carried
// here for the same reason it was added there, and in G4 it separates a real
// distinction: nine tools record at the DROP (`deactivate`), so their
// `liveEntryNames` is EMPTY, while `mesh.dragWeld` and `mesh.tack` record
// SYNCHRONOUSLY inside their own event handler and already show
// `["mesh.bevel_edit"]` before the tool is switched off.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. `tool.doApply`
// records a `ToolDoApplyCommand` — a different entry, from a different site —
// so a cell built on it would freeze the geometry of a command while claiming
// to pin a tool's own `commitEdit`. Every cell below therefore drives the input
// that REALLY reaches the tool's record site, and the one tool with no mouse
// handler at all (`mesh.reduceTool`) is driven by the only other input that
// reaches it: `/api/script?interactive=true`, which is the sole path that sets
// `interactiveParamEdit` and makes `onParamChanged` build a preview.
//
// TWO SHIPPED HANDLE-DRAG TESTS OF THIS GROUP ARE HOLLOW, and they are the
// reason this file measures `postCommit != preOp` before it measures anything
// else. Measured on this stand, at the tree this fixture was frozen against:
//
//   * `tests/test_vertex_extrude_handle_drag.d` grabs the EXTRUDE arrow only.
//     `shift` reaches 0.028 and its assertion passes — while `width` stays 0,
//     the kernel merges/extrudes NOTHING, `built` stays false, the drop records
//     NOTHING and not one plane moves. The cell below therefore grabs the WIDTH
//     part FIRST and the extrude arrow second.
//   * `tests/test_vert_merge_drag.d` hauls 60 px and asserts `dist` rose. It
//     does — to 0.033. The cube's selected vertices are 1.0 apart, so nothing
//     merges; and no haul reachable on that framing can close the gap (measured
//     at 700 px: dist 0.82, zero planes moved). The cell below moves the CAMERA
//     to distance 40, where the same haul buys dist 1.53 and the four vertices
//     actually collapse to one.
//
// Both files are green today and would stay green if their tool stopped
// recording altogether: their only anti-vacuity is a tool ATTRIBUTE, which
// moves whether or not the kernel touched an element. That is the same shape
// the G0-G1 lane found in `tests/test_edge_extrude_handle_drag.d`, and it is
// now three instances, not one.
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
// `built` IS NOT A UNIVERSAL CHANNEL IN THIS GROUP — measured. Only
// `edge.bevel` and `poly.bevel` publish it to `/api/tool/state`; the other nine
// publish nothing (`{}`) or a tool-specific object without it. So the cells that
// CAN assert `built` do, and the rest lean on the geometric anti-vacuity in
// `runCell` plus, for the two hollow-coverage tools, a named element-count
// assertion that says in as many words what the shipped test failed to see.
//
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. All eleven cells round-trip
// byte-for-byte in both directions on this tree, so every residual list is
// frozen EMPTY — and an empty list pinned exactly is still a pin: a residual
// that APPEARS reddens. Had one been non-empty it would have been frozen as its
// exact plane list, so that a residual which grows and a residual which
// disappears both redden. A standing licence over a plane nobody compares is
// the thing this file is built to not have.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G4=<abs path to g4.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g4`.
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.algorithm : sort, canFind, startsWith, endsWith;
import std.array     : appender, array;
import std.conv      : to;
import std.format    : format;
import std.json;
import std.math      : abs, sqrt;
import std.net.curl  : get, post;
import std.process   : environment;
import std.string    : split;
import core.thread   : Thread;
import core.time     : dur;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

/// The frozen oracle. Read through `import()` rather than off disk: the suite
/// lane compiles a scratch COPY of `tests/`, and `-J=tests` resolves this in
/// both trees while `__FILE_FULL_PATH__` would name the copy.
enum string kFrozen = import("fixtures/tool_gesture/g4.json");

/// The one file allowed to write `g4.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g4.d";

/// The recipe this fixture records, hoisted out of `fixtureJson` (task 3370)
/// so the `provenance` block's own prose quotes THE SAME text the `recipe`
/// key is emitted from, instead of a second copy able to drift from it.
enum string kRecipe = "stand -> gesture (/api/play-events) -> drop -> undo -> redo";

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
    recordToolLineIfDrive(line);
}

/// The ONLY input that sets `interactiveParamEdit`, and therefore the only one
/// that makes a panel-driven tool build a live preview. `/api/command` hard-codes
/// the flag FALSE, so the same line posted there reaches no preview at all.
void interactiveAttr(string line) {
    auto r = postJ("/api/script?interactive=true", line ~ "\n");
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/script?interactive=true '" ~ line ~ "' failed: " ~ r.toString);
    recordToolLineIfDrive(line);
}

// Task 3091: every `tool.set` / `tool.attr` WRITE this cell issues (through
// EITHER `cmd()` or `interactiveAttr()` — the reduce cell's panel write goes
// through the latter, since `/api/command` hard-codes `interactiveParamEdit`
// false) IS a captured parameter (schema 3010) — recorded off the SAME string
// that drove the wire command. A trailing `?` is a READ (`attrOf` above reads
// through a bare `postJ`, never through either wrapper; the guard stays here
// too so a future read-through-wrapper cannot be mistaken for a drive).
void recordToolLineIfDrive(string line) {
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

Drove driveDrag(int dxPx, int dyPx, int steps = 16, int button = 1, int mod = 0,
                bool hover = false) {
    return Drove("gesture.drag", format(
        `{"dx_px": %d, "dy_px": %d, "steps": %d, "button": %d, "mod": %d, "hover": %s}`,
        dxPx, dyPx, steps, button, mod, hover));
}

/// `gesture.drag` where the arm carries a `/api/tool/handles` part index.
Drove driveDragHandle(int dxPx, int dyPx, int handlePart, int steps = 16,
                       int button = 1, int mod = 0, bool hover = false) {
    return Drove("gesture.drag", format(
        `{"dx_px": %d, "dy_px": %d, "steps": %d, "button": %d, "mod": %d, "hover": %s, "handle_part": %d}`,
        dxPx, dyPx, steps, button, mod, hover, handlePart));
}

/// `gesture.drag` where only the drag LENGTH is a literal — every `axisDrag`
/// call resolves BOTH the direction and axis of motion from a runtime
/// projection.
Drove driveDragMagOnly(int dragPx, int steps = 16, int button = 1, int mod = 0,
                        bool hover = false) {
    return Drove("gesture.drag", format(
        `{"drag_px": %d, "steps": %d, "button": %d, "mod": %d, "hover": %s}`,
        dragPx, steps, button, mod, hover));
}

/// `gesture.drag` where BOTH endpoints are projections of STAND geometry
/// (drag.weld's source/target vertices) — no offset of any kind is a literal.
Drove driveDragNoOffset(int steps = 16, int button = 1, int mod = 0,
                         bool hover = false) {
    return Drove("gesture.drag", format(
        `{"steps": %d, "button": %d, "mod": %d, "hover": %s}`,
        steps, button, mod, hover));
}

/// `gesture.click` where the pixel is a projection of STAND geometry (tack's
/// hovered target face) — no x_px/y_px is a literal.
Drove driveClickNoOffset(int button = 1, int mod = 0, bool hover = false) {
    return Drove("gesture.click", format(
        `{"button": %d, "mod": %d, "hover": %s}`, button, mod, hover));
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
    c.drove      = gDrove;   // task 3091: captured after stand+gesture+drop

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
    s ~= "    \"notes\": \"collected live by this producer's own runCell/cmd()/"
       ~ "interactiveAttr() instrumentation (task 3091): tool.set/tool.attr "
       ~ "values are parsed off the wire argstring actually sent; gesture "
       ~ "magnitudes are recorded at their own driving call site\"\n";
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
    s ~= "  \"family\": \"tool_gesture_g4\",\n";
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
    string msg = "tests/fixtures/tool_gesture/g4.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G4` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g4: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G4", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g4.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g4.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g4.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g4.json: cell %d is '%s' frozen and '%s' now — the roster "
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

/// `/api/load-mesh` RESETS THE CAMERA, so every stand that loads a scene sets
/// the camera AFTER the load, never before.
void loadMesh(string body_) {
    auto r = postJ("/api/command", commandBody("scene.loadMesh", body_));
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

void setCamera(double az, double el, double dist,
               double fx = 0, double fy = 0, double fz = 0) {
    auto r = postJ("/api/camera",
        format(`{"azimuth":%g,"elevation":%g,"distance":%g,`
             ~ `"focus":{"x":%g,"y":%g,"z":%g}}`, az, el, dist, fx, fy, fz));
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
}

void setOrbitCamera(double dist = 4.0) { setCamera(0.4, 1.1, dist); }

void selectMode(string mode, int[] idx) {
    auto r = postJ("/api/command", commandBody("mesh.select", format(`{"mode":"%s","indices":%s}`, mode, idx.to!string)));
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
/// handle. Several tools in this group pick their drag part on hover.
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

/// A discrete LEFT click (down + up, no motion between).
void click(int x, int y) {
    auto cam = fetchCamera(BASE);
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, x, y, x, y), BASE);
    settle(250);
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

/// Drag mid-shaft along a WORLD axis anchored at `anchor`, in the direction the
/// axis actually projects to. Used only where the tool publishes no part whose
/// screen anchor is on the shaft.
void axisDrag(Vec3 anchor, Vec3 axis, double pixels, bool hoverFirst) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    immutable float arm = gizmoSize(anchor, vp);
    Vec3 press = anchor + axis * cast(float)(arm * 0.6);
    float ax, ay, tx, ty, pxx, pyy;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind the camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty), "axis tip projects behind the camera");
    assert(projectToWindow(press, vp, pxx, pyy), "shaft mid-point is off-camera");
    immutable double dx = tx - ax, dy = ty - ay;
    immutable double len = sqrt(dx * dx + dy * dy);
    assert(len > 1.0,
        "the axis projects to a point on this framing, so no drag direction "
      ~ "separates the arrow branch from the free one");
    if (hoverFirst) hover(cast(int) pxx, cast(int) pyy);
    dragPixels(cast(int) pxx, cast(int) pyy,
               cast(int)(pxx + dx / len * pixels),
               cast(int)(pyy + dy / len * pixels), 16);
    // Every call in this file resolves BOTH the direction and the axis of
    // motion from a runtime projection, and grabs no handle part — only the
    // drag LENGTH and `hoverFirst` are literals.
    gDrove ~= driveDragMagOnly(cast(int) pixels, 16, 1, 0, hoverFirst);
}

/// The cube edge whose midpoint is (mx,my,mz) — the operand of the edge cell.
int findEdgeMid(double mx, double my, double mz) {
    auto m = getJ("/api/model");
    auto verts = m["vertices"].array;
    foreach (i, e; m["edges"].array) {
        auto pa = verts[cast(int) e.array[0].integer].array;
        auto pb = verts[cast(int) e.array[1].integer].array;
        if (abs((pa[0].floating + pb[0].floating) / 2 - mx) < 1e-4 &&
            abs((pa[1].floating + pb[1].floating) / 2 - my) < 1e-4 &&
            abs((pa[2].floating + pb[2].floating) / 2 - mz) < 1e-4)
            return cast(int) i;
    }
    assert(false, format("no cube edge with midpoint (%g,%g,%g)", mx, my, mz));
}

/// Two disjoint triangles — the drag-weld operand. The source (v3) and the
/// target (v0) share no face, which is what makes the weld legal.
enum string kTwoTriangles = `{
    "vertices":[[-0.5,0,0],[0,0,1],[0.5,0,0],[-0.5,0,2],[0,0,3],[0.5,0,2]],
    "faces":[[0,1,2],[3,4,5]]
}`;

/// Two coaxial unit squares — the bridge operand (the `test_bridge.d` stand).
enum string kTwoCaps = `{
    "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0,0,1],[1,0,1],[1,1,1],[0,1,1]],
    "faces":[[0,1,2,3],[4,5,6,7]]
}`;

/// Two disjoint boxes — the tack operand (the `test_tack_tool.d` stand). Box A
/// (verts 0-7) is the SOURCE island, its face 4 the source polygon; Box B
/// (verts 8-15) carries a tilted +Y face 10 as the target.
enum string kTackScene = `{
  "vertices":[[-2.5,-0.5,-0.5],[-2.5,-0.5,0.5],[-2.5,0.5,-0.2],[-2.5,0.5,0.5],
              [-1.5,-0.5,-0.5],[-1.5,-0.5,0.5],[-1.5,0.5,-0.5],[-1.5,0.5,0.5],
              [2.5,-0.5,-0.5],[2.5,-0.5,0.5],[2.5,0.5,-0.5],[2.5,1.3,0.5],
              [3.5,-0.5,-0.5],[3.5,-0.5,0.5],[3.5,0.5,-0.5],[3.5,1.3,0.5]],
  "faces":[[0,2,6,4],[1,5,7,3],[0,1,3,2],[4,6,7,5],[2,3,7,6],[0,4,5,1],
           [8,10,14,12],[9,13,15,11],[8,9,11,10],[12,14,15,13],[10,11,15,14],[8,12,13,9]]}`;

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
// 1. The roster: ELEVEN cells, one per G4 record site. ONE unittest, because
//    they share one frozen file and the fixture compare is per-cell anyway
//    (each cell raises its own accumulated assert, naming itself).
//
//    All eleven write through `history.record` (mode `Plain`) and all eleven
//    carry a `MeshSessionEdit` — measured, not assumed: the three factories
//    this group is bound to (`bevelEditFactory`, `polyExtrudeEditFactory`,
//    `reduceEditFactory`, `source/app.d`) all construct that one class. G4 is
//    therefore the group with ONE record primitive and ONE payload shape and
//    ELEVEN hand-written commit bodies, which is exactly the redundancy plan
//    §6 migrates — and exactly why a per-body geometric oracle is what pins it.
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) PolyBevelTool. Two handle parts (Shift + Inset); the Shift haul
    //     alone builds. One of only TWO tools in this group that publish
    //     `built` to `/api/tool/state`, so this cell asserts it.
    cells ~= runCell("poly.bevel/shift-drag", "poly.bevel",
        "source/tools/edit/poly_bevel.d PolyBevelTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("polygons", [0]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set poly.bevel on"); settle(250); },
        {
            int hx, hy; handlePx(0, hx, hy);
            dragPixels(hx, hy, hx + 70, hy - 40, 16);
            gDrove ~= driveDragHandle(70, -40, 0, 16);
            assert(getJ("/api/tool/state")["built"].type == JSONType.true_,
                "poly.bevel: the Shift haul left `built` false — the kernel "
              ~ "touched no face, so the drop will record nothing");
        },
        { cmd("tool.set poly.bevel off"); });

    // --- (b) PolyInsetTool. NO handle at all: the haul is anchored at the
    //     selection centroid wherever the press lands, so the press is the
    //     viewport centre by construction.
    cells ~= runCell("mesh.polyInsetTool/centroid-haul", "mesh.polyInsetTool",
        "source/tools/edit/poly_inset_tool.d PolyInsetTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.polyInsetTool on"); settle(250); },
        {
            auto cam = fetchCamera(BASE);
            immutable int cx = cam.vpX + cam.width / 2;
            immutable int cy = cam.vpY + cam.height / 2;
            dragPixels(cx, cy, cx, cy - 60, 12);
            gDrove ~= driveDrag(0, -60, 12);
            assert(attrOf("mesh.polyInsetTool", "inset") > 1e-4,
                "mesh.polyInsetTool: the 60 px haul left `inset` at zero — the press "
              ~ "fell outside the viewport the haul is anchored in");
        },
        { cmd("tool.set mesh.polyInsetTool off"); });

    // --- (c) PolyExtrudeTool on the cube's +X face: centroid (0.5,0,0),
    //     averaged normal +X. The arrow shaft is re-derived here because the
    //     tool's single published part sits at the arrow TIP, not mid-shaft.
    cells ~= runCell("poly.extrude/axis-drag", "poly.extrude",
        "source/tools/edit/poly_extrude.d PolyExtrudeTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("polygons", [3]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set poly.extrude on"); settle(250); },
        {
            axisDrag(Vec3(0.5f, 0, 0), Vec3(1, 0, 0), 80, false);
            assert(attrOf("poly.extrude", "distance") > 1e-3,
                "poly.extrude: the drag left `distance` at zero — the press "
              ~ "missed the arrow and fell into the free branch");
        },
        { cmd("tool.set poly.extrude off"); });

    // --- (d) EdgeBevelTool on the cube's top-front edge. The second of the two
    //     tools in this group that publish `built`.
    cells ~= runCell("edge.bevel/width-drag", "edge.bevel",
        "source/tools/edit/edge_bevel.d EdgeBevelTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("edges", [findEdgeMid(0.0, 0.5, -0.5)]);
          cmd("history.clear"); setOrbitCamera();
          cmd("tool.set edge.bevel on"); settle(250); },
        {
            int hx, hy; handlePx(0, hx, hy);
            hover(hx, hy);
            dragPixels(hx, hy, hx + 70, hy - 50, 16);
            gDrove ~= driveDragHandle(70, -50, 0, 16, 1, 0, true);
            assert(getJ("/api/tool/state")["built"].type == JSONType.true_,
                "edge.bevel: the Width drag left `built` false — the kernel "
              ~ "chamfered no edge and the drop will record nothing");
        },
        { cmd("tool.set edge.bevel off"); });

    // --- (e) VertexBevelTool on cube vertex 6 = (0.5,0.5,0.5): its three
    //     adjacent faces average to the (1,1,1) diagonal, which is the inset
    //     axis the arrow is drawn along.
    cells ~= runCell("vertex.bevel/inset-drag", "mesh.vertexBevel",
        "source/tools/edit/vertex_bevel_tool.d VertexBevelTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("vertices", [6]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.vertexBevel on"); settle(250); },
        {
            enum float T = 0.57735027f;
            axisDrag(Vec3(0.5f, 0.5f, 0.5f), Vec3(T, T, T), 80, true);
            assert(abs(attrOf("mesh.vertexBevel", "inset")) > 1e-3,
                "vertex.bevel: the drag left `inset` at zero — the press "
              ~ "missed the arrow");
        },
        { cmd("tool.set mesh.vertexBevel off"); });

    // --- (f) VertexExtrudeTool, and the cell that cost this lane a drive path.
    //     The shipped `test_vertex_extrude_handle_drag.d` grabs the EXTRUDE
    //     arrow only; measured on this stand that leaves `width == 0`, the
    //     kernel affects NOTHING, the drop records nothing and no plane moves,
    //     while the `shift` attribute the file asserts on reads 0.028. So this
    //     cell grabs the WIDTH part (1) first and the extrude arrow (0) second,
    //     and asserts the vertex count actually GREW — the check the shipped
    //     file does not have.
    cells ~= runCell("vertex.extrude/width-then-shift", "mesh.vertexExtrude",
        "source/tools/edit/vertex_extrude_tool.d VertexExtrudeTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("vertices", [6]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.vertexExtrude on"); settle(250); },
        {
            immutable size_t v0 = vertexCount();
            int wx, wy; handlePx(1, wx, wy);       // Width
            hover(wx, wy);
            dragPixels(wx, wy, wx + 70, wy - 50, 16);
            gDrove ~= driveDragHandle(70, -50, 1, 16, 1, 0, true);
            int sx, sy; handlePx(0, sx, sy);       // Extrude (shift)
            hover(sx, sy);
            dragPixels(sx, sy, sx + 70, sy - 50, 16);
            gDrove ~= driveDragHandle(70, -50, 0, 16, 1, 0, true);
            assert(vertexCount() > v0,
                "vertex.extrude: the two handle drags added no vertex (still "
              ~ v0.to!string ~ "). This is exactly the non-gesture the shipped "
              ~ "`test_vertex_extrude_handle_drag.d` cannot see: it grabs the "
              ~ "extrude arrow only, `shift` moves off zero and its assertion "
              ~ "passes while `width` stays 0 and the kernel builds nothing");
        },
        { cmd("tool.set mesh.vertexExtrude off"); });

    // --- (g) VertexMergeTool, the second hollow-coverage tool. `dist` is a
    //     WORLD threshold hauled in SCREEN pixels, so its gain per pixel scales
    //     with camera distance: on the default framing the shipped 60 px haul
    //     buys dist 0.033 against a cube whose selected vertices are 1.0 apart,
    //     and nothing merges at any haul the viewport can hold (measured to
    //     700 px: dist 0.82, zero planes moved). Distance 40 is what makes the
    //     same gesture a real merge, and the cell asserts the count FELL.
    cells ~= runCell("vert.merge/far-haul", "vert.merge",
        "source/tools/edit/vert_merge_tool.d VertexMergeTool.commitEdit",
        "Plain", "MeshSessionEdit",
        { resetCube(); selectMode("vertices", [0, 1, 2, 3]); cmd("history.clear");
          setOrbitCamera(40.0); cmd("tool.set vert.merge on"); settle(250); },
        {
            immutable size_t v0 = vertexCount();
            auto cam = fetchCamera(BASE);
            immutable int cx = cam.vpX + cam.width / 2;
            immutable int cy = cam.vpY + cam.height / 2;
            dragPixels(cx, cy + 200, cx, cy - 200, 16);
            gDrove ~= driveDrag(0, -400, 16);
            assert(vertexCount() < v0,
                "vert.merge: the haul merged nothing (still " ~ v0.to!string
              ~ " vertices) even though `dist` reads "
              ~ attrOf("vert.merge", "dist").to!string ~ ". That is the shipped "
              ~ "`test_vert_merge_drag.d` failure exactly: its only anti-vacuity "
              ~ "is `dist`, which rises whether or not two vertices ever came "
              ~ "within it");
        },
        { cmd("tool.set vert.merge off"); });

    // --- (h) ReductionTool. It has NO mouse handler of any kind — the only
    //     input that reaches its record site is a panel parameter write, and
    //     the only wire path that sets `interactiveParamEdit` (and therefore
    //     builds a preview) is `/api/script?interactive=true`. `tool.doApply`
    //     is NOT that path: it records a `ToolDoApplyCommand`, so a cell built
    //     on it would freeze a command's entry while claiming to pin
    //     `ReductionTool.commitEdit`. This is also the only cell whose wire
    //     name is `mesh.reduce_edit`.
    cells ~= runCell("reduce/panel-attr", "mesh.reduceTool",
        "source/tools/edit/reduce.d ReductionTool.commitEdit",
        "Plain", "MeshSessionEdit",
        {
            resetCube(); cmd("select.typeFrom polygon");
            cmd("mesh.subdivide"); cmd("mesh.subdivide"); cmd("mesh.triple");
            cmd("history.clear"); setOrbitCamera();
            cmd("tool.set mesh.reduceTool on"); settle(250);
        },
        { interactiveAttr("tool.attr mesh.reduceTool ratio 0.5"); settle(300); },
        { cmd("tool.set mesh.reduceTool off"); });

    // --- (i) DragWeldTool: the record is INLINE in `onMouseButtonUp`, so the
    //     entry is already on the stack BEFORE the drop. That is what
    //     `liveEntryNames` reads, and it is the field that separates this cell
    //     (and tack's) from the nine that record at `deactivate`.
    cells ~= runCell("drag.weld/vertex-onto-vertex", "mesh.dragWeld",
        "source/tools/edit/drag_weld.d DragWeldTool.onMouseButtonUp (inline history_.record)",
        "Plain", "MeshSessionEdit",
        {
            resetEmpty(); loadMesh(kTwoTriangles);
            setCamera(0.0, 0.6, 6.0, 0.0, 0.0, 1.0);
            cmd("history.clear"); cmd("tool.set mesh.dragWeld on"); settle(250);
        },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            float sx, sy, tx, ty;
            assert(projectToWindow(Vec3(-0.5f, 0, 2), vp, sx, sy),
                "drag.weld: source vertex projects off-screen");
            assert(projectToWindow(Vec3(-0.5f, 0, 0), vp, tx, ty),
                "drag.weld: target vertex projects off-screen");
            dragPixels(cast(int) sx, cast(int) sy, cast(int) tx, cast(int) ty, 20);
            gDrove ~= driveDragNoOffset(20);
        },
        { cmd("tool.set mesh.dragWeld off"); });

    // --- (j) TackTool: the record is synchronous with the mouse-DOWN, and
    //     `hasUncommittedEdit()` is hard-coded FALSE, so a seam keyed on that
    //     predicate never sees this tool at all. The hover before the click is
    //     load-bearing: it is what settles the hovered target face.
    cells ~= runCell("tack/click", "mesh.tack",
        "source/tools/edit/tack.d TackTool.commitTackEdit (from onMouseButtonDown)",
        "Plain", "MeshSessionEdit",
        {
            resetEmpty(); loadMesh(kTackScene); selectMode("polygons", [4]);
            setCamera(3.14159265, 0.9, 6.0, 3.0, 0.9, 0.0);
            cmd("history.clear"); cmd("tool.set mesh.tack on"); settle(250);
        },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            float sx, sy;
            assert(projectToWindow(Vec3(2.9793754f, 0.65790217f, -0.30262226f),
                                   vp, sx, sy),
                "tack: the target anchor must project on-camera with this framing");
            hover(cast(int) sx, cast(int) sy);
            auto st = getJ("/api/tool/state");
            assert(st["sourceFace"].integer == 4 &&
                   st["hoveredTargetFace"].integer == 10 &&
                   st["previewActive"].type == JSONType.true_,
                "tack: the hover did not settle on the target face — the click "
              ~ "would then tack nothing: " ~ st.toString);
            click(cast(int) sx, cast(int) sy);
            gDrove ~= driveClickNoOffset(1, 0, true);
        },
        { cmd("tool.set mesh.tack off"); });

    // --- (k) BridgeTool, the T7 sibling: it commits from `deactivate`, and it
    //     had NO interactive coverage anywhere in `tests/` before this cell
    //     (plan §8 names that gap: an override landing there would otherwise
    //     sit without a witness). Its gesture is a bare horizontal LMB drag —
    //     no handle — reading 20 px per segment.
    cells ~= runCell("bridge/segments-drag", "mesh.bridgeTool",
        "source/tools/edit/bridge_tool.d BridgeTool.commitBridgeEdit (from deactivate)",
        "Plain", "MeshSessionEdit",
        {
            resetEmpty(); loadMesh(kTwoCaps); selectMode("polygons", [0, 1]);
            setCamera(0.6, 0.5, 5.0, 0.5, 0.5, 0.5);
            cmd("history.clear"); cmd("tool.set mesh.bridgeTool on"); settle(250);
        },
        {
            auto cam = fetchCamera(BASE);
            immutable int cx = cam.vpX + cam.width / 2;
            immutable int cy = cam.vpY + cam.height / 2;
            dragPixels(cx, cy, cx + 60, cy, 12);
            gDrove ~= driveDrag(60, 0, 12);
            auto st = getJ("/api/tool/state");
            assert(st["valid"].type == JSONType.true_ &&
                   st["engaged"].type == JSONType.true_,
                "bridge: the drag left the tool unengaged or the selection "
              ~ "invalid, so `deactivate` will record nothing: " ~ st.toString);
        },
        { cmd("tool.set mesh.bridgeTool off"); });

    freezeOrCompare(cells);
}
