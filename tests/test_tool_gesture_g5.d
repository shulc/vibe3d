// test_tool_gesture_g5 — task 1905, lane G0-G5: the FROZEN plane fixture for
// group G5 (the slice family: EdgeSlice, LoopSlice and SliceTool), driven by
// REAL GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G5 witnesses can replace it.
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
// G5 SHARES THE SINGLE-WIRE-NAME PROPERTY IN PART — measured while freezing
// this file. `mesh.edgeSliceTool` and `mesh.sliceTool` both record under
// `mesh.bevel_edit` (both are bound to the shared `bevelEditFactory`), while
// `mesh.loopSliceTool` stands apart under `mesh.loop_slice_edit`. So a mutation
// that must redden EXACTLY ONE cell of this group cannot key on `entryNames`
// for the first two — the same correction the G0-G1 lane forced on plan §5.5,
// and the same partial form the G0-G4 lane measured. What separates the three
// here is the PLANE DUMPS: all three `postCommit` dumps are pairwise different
// (10v/7f, 12v/10f from a belt loop, 12v/10f from a mid-plane cut whose
// vertices differ). `liveEntryNames` is carried for the same reason it was
// added in G1, and in THIS group it is EMPTY for all three: every member
// commits from `deactivate`, so nothing stands on the ledger between gesture
// and drop. Frozen empty is a pin — a member that started recording inside its
// own event handler would redden it.
//
// G5 IS THE ONE GROUP HOLDING A LEGITIMATE NON-RECORDER MUTATION OF THE
// HISTORY, and Block 2 below is its first behavioural witness at the site it
// pins. `CommandHistory.invalidateRedo()` is called FOUR times in this family
// — `EdgeSliceTool.latchFirstPoint`, `EdgeSliceTool.armChain`,
// `EdgeSliceTool.rebuildPreview`, `LoopSliceTool.rebuildCut` — and that is the
// deliberate task-0429 primitive: a standing preview writes outside the history
// and must therefore kill the redo timeline. It STAYS. Two consequences this
// file is built around:
//
//   * the cells must survive it. They do, by construction: each drops its tool
//     BEFORE undoing, so the redo it then presses was pushed by its own undo,
//     never by a timeline a preview could have killed. A redo that answers
//     `noop` because the timeline was deliberately killed and a redo that
//     answers `noop` because the entry failed to revert are DIFFERENT states,
//     and `runCell` refuses the second by name.
//   * the primitive's own witness is thin, measured rather than assumed. The
//     shipped `tests/test_standing_preview_redo.d` reaches two of the four
//     sites (loop slice's `rebuildCut` interactively, edge slice's `armChain`
//     through the HEADLESS `chainArm`); the interactive FIRST LATCH and the
//     interactive scrub have no behavioural witness anywhere. Block 2 supplies
//     one for the first latch — the earliest of the four, and the only one that
//     can be isolated: it fires before the mesh has been touched at all, so a
//     dead redo timeline after it cannot be attributed to anything else. The
//     scrub's call cannot be isolated behaviourally BY CONSTRUCTION, and that
//     is worth saying rather than leaving as a gap: the latch's call has
//     already emptied the redo stack by the time any scrub can run, so a second
//     `invalidateRedo` on the same open chain has nothing left to invalidate.
//     `tests/unit/tool_gesture_runopen_g5_test.d` therefore carries the count
//     as a named census row (`invalidateRedo: 3` / `: 1`), which is what makes
//     a FIFTH call — or a deleted fourth — visible at all.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. `tool.doApply`
// records a `ToolDoApplyCommand` — a different entry, from a different site —
// so a cell built on it would freeze the geometry of a command while claiming
// to pin a tool's own commit body. All three members here commit from
// `deactivate`, so each cell's drop is `tool.set <id> off`.
//
// THE SHIPPED COVERAGE OF THIS GROUP, MEASURED RATHER THAN ASSUMED. Unlike G3
// and G4, every member of G5 already had a REAL interactive witness — one that
// asserts element counts, not attribute values:
// `tests/test_edge_slice_tool.d` (7 faces / 10 verts after an interactive
// chain), `tests/test_loop_slice_ctrlz.d` and `test_loop_slice_seam_counters.d`
// (12v/10f plus exact undo-depth deltas), `tests/test_slice_session.d` and
// `test_slice_input_model.d` (12v/10f, and that a second drag refines rather
// than stacks). This lane therefore adds the plane-complete oracle those files
// do not have, not a first drive. ONE caveat is worth carrying, because it is
// the shape this project pays for: `test_edge_slice_tool.d`'s interactive cell
// SKIPS its geometry assertions when the GPU picker fails to resolve an edge
// (`if (st["edgeA"].integer < 0 ... return;`). A skip is not a pin. The cell
// below refuses instead, naming the picker.
//
// `built` IS PUBLISHED BY TWO OF THE THREE — measured: `mesh.edgeSliceTool` and
// `mesh.loopSliceTool` answer `built` on `/api/tool/state`; `mesh.sliceTool`
// answers `lineDrawn` and no `built`. So two cells assert the flag the brief
// asks for, and the third asserts the strictly stronger observable it stands in
// for, plus `postCommit != preOp` and `undoDelta == 1` in `runCell`.
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
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. All three cells round-trip
// byte-for-byte in both directions on this tree, so every residual list is
// frozen EMPTY — and an empty list pinned exactly is still a pin: a residual
// that APPEARS reddens. Had one been non-empty it would have been frozen as its
// exact plane list, so that a residual which grows and a residual which
// disappears both redden.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G5=<abs path to g5.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g5`.
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
enum string kFrozen = import("fixtures/tool_gesture/g5.json");

/// The one file allowed to write `g5.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g5.d";

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
    // Task 3091: every `tool.set` / `tool.attr` WRITE this cell issues IS a
    // captured parameter (schema 3010) — recorded off the SAME string that
    // drives the wire command. A trailing `?` is a READ (`attrOf` above reads
    // through a bare `postJ`, never through `cmd()`; the guard stays here too
    // so a future read-through-`cmd()` cannot be mistaken for a drive).
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

/// `gesture.click` where the pixel is a projection of STAND geometry (an edge
/// midpoint, the viewport centre) — no x_px/y_px is a literal.
Drove driveClickNoOffset(int button = 1, int mod = 0, bool hover = false) {
    return Drove("gesture.click", format(
        `{"button": %d, "mod": %d, "hover": %s}`, button, mod, hover));
}

/// `gesture.drag` where both endpoints are projections of a runtime plane
/// basis, but the OFFSET each is placed at along that basis (here `u * ±0.6`)
/// is a world-space literal — recorded under its own name rather than
/// disguised as a pixel quantity it is not.
Drove driveDragWorldOffset(double endpointOffsetWorld, int steps = 16,
                            int button = 1, int mod = 0, bool hover = false) {
    return Drove("gesture.drag", format(
        `{"steps": %d, "button": %d, "mod": %d, "hover": %s, "endpoint_offset_world": %g}`,
        steps, button, mod, hover, endpointOffsetWorld));
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

/// Drive one gesture and score it. `stand` builds and arms the scene, then
/// clears history; `gesture` is the play-events drive; `drop` deactivates the
/// tool.  Clear-after-arm is load-bearing now that `toolcards/undo_surfaces/`
/// establishes the arm as a visible row: `undoDelta` still begins at the
/// deliberately empty stack this fixture promises.
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
    s ~= "    \"notes\": \"collected live by this producer's own runCell/cmd() "
       ~ "instrumentation (task 3091): tool.set/tool.attr values are parsed "
       ~ "off the wire argstring cmd() actually sent; gesture magnitudes are "
       ~ "recorded at their own driving call site\"\n";
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
    s ~= "  \"family\": \"tool_gesture_g5\",\n";
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
    string msg = "tests/fixtures/tool_gesture/g5.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G5` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g5: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G5", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g5.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g5.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g5.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g5.json: cell %d is '%s' frozen and '%s' now — the roster "
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
/// element. The override behind `queryMouse()` is updated on MOTION events
/// only, so a log that opens with the button-down hit-tests a stale cursor —
/// and for this family that is the difference between latching the edge under
/// the cursor and latching nothing.
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

/// A discrete LEFT click: two settling motions, down, one held motion, up —
/// the shape `tests/test_edge_slice_tool.d` uses for its latches, kept because
/// the press hit-test reads the cursor override rather than the event pixel.
void click(int x, int y) {
    auto cam = fetchCamera(BASE);
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":70.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":90.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":110.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":0}` ~ "\n"
      ~ `{"t":130.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x, y, x, y, x, y, x, y), BASE);
    settle(250);
}

/// The cube vertex at a world position — the operands below are named by
/// POSITION, never by index, so a change in the cube factory's vertex order
/// reddens by failing to find the operand instead of silently slicing a
/// different edge.
int vertexAt(in JSONValue m, double x, double y, double z) {
    foreach (i, v; m["vertices"].array) {
        auto p = v.array;
        if (abs(p[0].floating - x) < 1e-4 &&
            abs(p[1].floating - y) < 1e-4 &&
            abs(p[2].floating - z) < 1e-4) return cast(int) i;
    }
    assert(false, format("no vertex at (%g,%g,%g)", x, y, z));
}

/// The edge joining two vertices, by index into `mesh.edges`.
int edgeBetween(in JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        immutable int x = cast(int) e.array[0].integer;
        immutable int y = cast(int) e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int) i;
    }
    assert(false, format("no edge between %d and %d", a, b));
}

/// The world midpoint of an edge — where a latch click has to land.
Vec3 edgeMidpoint(in JSONValue m, int edgeIdx) {
    auto e = m["edges"].array[edgeIdx].array;
    auto pa = m["vertices"].array[cast(int) e[0].integer].array;
    auto pb = m["vertices"].array[cast(int) e[1].integer].array;
    return Vec3(cast(float)((pa[0].floating + pb[0].floating) * 0.5),
                cast(float)((pa[1].floating + pb[1].floating) * 0.5),
                cast(float)((pa[2].floating + pb[2].floating) * 0.5));
}

JSONValue model() { return getJ("/api/model"); }

/// `/api/undo/status`'s `canRedo`, the only wire view of the redo timeline.
bool canRedo() {
    return getJ("/api/undo/status")["canRedo"].type == JSONType.true_;
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

/// The two world axes spanning the construction plane `SliceTool` picks for
/// itself (`pickMostFacingPlane`): the axis with the largest |dot(camBack)| is
/// the plane NORMAL, the other two span it, tie-broken X > Y > Z. Re-derived
/// here for the same reason `drag_helpers.gizmoSize` re-derives the arm length:
/// an independent copy makes a product-side change fail loudly instead of
/// following silently.
void inPlaneSpan(const ref Viewport vp, out Vec3 u, out Vec3 v) {
    immutable float ax = abs(vp.view[2]), ay = abs(vp.view[6]), az = abs(vp.view[10]);
    if (ax >= ay && ax >= az)      { u = Vec3(0, 0, 1); v = Vec3(0, 1, 0); }
    else if (ay >= ax && ay >= az) { u = Vec3(0, 0, 1); v = Vec3(1, 0, 0); }
    else                           { u = Vec3(0, 1, 0); v = Vec3(1, 0, 0); }
}

// ---------------------------------------------------------------------------
// 1. The roster: THREE cells, one per G5 record site.
//
//    All three write through `history.record` (mode `Plain`) and all three
//    carry a `MeshSessionEdit` — measured, not assumed: `bevelEditFactory`
//    (edge slice, slice) and `loopSliceEditFactory` (loop slice) construct that
//    one class (`source/app.d:3629` / `:3631`). One record primitive, one
//    payload shape, three hand-written commit bodies — which is exactly the
//    redundancy plan §6 migrates, and exactly why a per-body geometric oracle
//    is what pins it.
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) EdgeSliceTool: two latch clicks make a 2-point chain, the drop
    //     commits it as EXACTLY ONE entry for the whole chain. The operand
    //     edges are the cube's (4,5) and (6,7) — the pair the shipped
    //     interactive cell uses — found by POSITION, not by index.
    cells ~= runCell("mesh.edgeSliceTool/two-click-chain", "mesh.edgeSliceTool",
        "source/tools/slice/edge_slice_tool.d EdgeSliceTool.commitChain",
        "Plain", "MeshSessionEdit",
        { resetCube(); cmd("select.typeFrom edge");
          setOrbitCamera(); cmd("tool.set mesh.edgeSliceTool on"); settle(250);
          cmd("history.clear"); },
        {
            auto m  = model();
            auto vp = viewportFromCamera(fetchCamera(BASE));
            immutable int eA = edgeBetween(m, vertexAt(m, -0.5, -0.5, 0.5),
                                              vertexAt(m,  0.5, -0.5, 0.5));
            immutable int eB = edgeBetween(m, vertexAt(m, -0.5, 0.5, 0.5),
                                              vertexAt(m,  0.5, 0.5, 0.5));
            float ax, ay, bx, by;
            assert(projectToWindow(edgeMidpoint(m, eA), vp, ax, ay),
                "mesh.edgeSliceTool: operand edge A projects behind the camera");
            assert(projectToWindow(edgeMidpoint(m, eB), vp, bx, by),
                "mesh.edgeSliceTool: operand edge B projects behind the camera");

            click(cast(int) ax, cast(int) ay);
            gDrove ~= driveClickNoOffset();
            auto s1 = getJ("/api/tool/state");
            assert(s1["edgeA"].integer == eA,
                "mesh.edgeSliceTool: the first click latched edge "
              ~ s1["edgeA"].integer.to!string ~ ", expected " ~ eA.to!string
              ~ ". The GPU picker did not resolve the edge under the cursor. "
              ~ "The shipped `tests/test_edge_slice_tool.d` RETURNS here and "
              ~ "skips its geometry assertions; a skip is not a pin, so this "
              ~ "cell refuses instead: " ~ s1.toString);

            click(cast(int) bx, cast(int) by);
            gDrove ~= driveClickNoOffset();
            auto s2 = getJ("/api/tool/state");
            assert(s2["built"].type == JSONType.true_ &&
                   s2["chainSegments"].integer == 1,
                "mesh.edgeSliceTool: after the second latch the tool reports built="
              ~ s2["built"].toString ~ " segments="
              ~ s2["chainSegments"].integer.to!string ~ ", expected a single "
              ~ "built segment — the drop would then record nothing");
        },
        { cmd("tool.set mesh.edgeSliceTool off"); });

    // --- (b) LoopSliceTool: the arm is SELECTION-seeded, so the click only has
    //     to land inside a registered viewport cell — the belt edge chosen by
    //     position is what decides which ring is cut. One click arms AND builds
    //     the default centre cut; the drop commits it.
    cells ~= runCell("loop.slice/seeded-arm", "mesh.loopSliceTool",
        "source/tools/slice/loop_slice_tool.d LoopSliceTool.commitEdit",
        "Plain", "MeshSessionEdit",
        {
            resetCube();
            auto m = model();
            selectMode("edges", [edgeBetween(m, vertexAt(m, -0.5, -0.5, -0.5),
                                                vertexAt(m,  0.5, -0.5, -0.5))]);
            setOrbitCamera(); cmd("tool.set mesh.loopSliceTool on"); settle(250);
            cmd("history.clear");
        },
        {
            auto cam = fetchCamera(BASE);
            click(cam.vpX + cam.width / 2, cam.vpY + cam.height / 2);
            gDrove ~= driveClickNoOffset();
            auto st = getJ("/api/tool/state");
            assert(st["armed"].type == JSONType.true_ &&
                   st["built"].type == JSONType.true_,
                "loop.slice: the arm click left armed=" ~ st["armed"].toString
              ~ " built=" ~ st["built"].toString ~ " — an unbuilt arm CANCELS "
              ~ "on drop instead of recording");
        },
        { cmd("tool.set mesh.loopSliceTool off"); });

    // --- (c) SliceTool: a single Start->End line drag on the tool's own
    //     construction plane. The line is laid ALONG the in-plane axis `u` so
    //     it is never collinear with the idle default line — a collinear drag
    //     would GRAB that line instead of drawing a fresh one, and the cell
    //     would then freeze a handle drag under the name of a line draw.
    cells ~= runCell("slice/line-drag", "mesh.sliceTool",
        "source/tools/slice/slice_tool.d SliceTool.commitCurrentSlice",
        "Plain", "MeshSessionEdit",
        { resetCube();
          setOrbitCamera(); cmd("tool.set mesh.sliceTool on"); settle(250);
          cmd("history.clear"); },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            Vec3 u, v;
            inPlaneSpan(vp, u, v);
            float ax, ay, bx, by;
            assert(projectToWindow(u * -0.6f, vp, ax, ay) &&
                   projectToWindow(u *  0.6f, vp, bx, by),
                "slice: the line endpoints project behind the camera");
            dragPixels(cast(int) ax, cast(int) ay, cast(int) bx, cast(int) by, 20);
            gDrove ~= driveDragWorldOffset(0.6, 20);
            auto st = getJ("/api/tool/state");
            assert(st["lineDrawn"].type == JSONType.true_,
                "slice: the drag drew no line (lineDrawn=false), so the drop "
              ~ "records nothing. This tool publishes no `built` flag — "
              ~ "`lineDrawn` plus the plane compare in runCell is what stands "
              ~ "in for it: " ~ st.toString);
        },
        { cmd("tool.set mesh.sliceTool off"); });

    freezeOrCompare(cells);
}

// ---------------------------------------------------------------------------
// 2. THE LEGITIMATE NON-RECORDER: a standing preview kills the redo timeline,
//    and the FIRST LATCH is where it starts.
//
//    `invalidateRedo()` is the deliberate task-0429 primitive of this family:
//    a standing preview writes into the real mesh outside the history, so a
//    redo stepping the stack under it would replay onto a mesh nobody recorded.
//    It is not a defect and it is not migrating; what it lacked was a witness
//    at THIS site.
//
//    WHY THIS SITE AND NOT ANOTHER. Of the four calls, the shipped
//    `tests/test_standing_preview_redo.d` reaches two: loop slice's
//    `rebuildCut` (scenario A) and edge slice's `armChain`, via the HEADLESS
//    `chainArm` (scenario A'). `EdgeSliceTool.latchFirstPoint` and
//    `EdgeSliceTool.rebuildPreview` have none. The latch is the one that can be
//    isolated, and cheaply: it fires BEFORE the tool has written a single
//    vertex, so the assertions below hold the mesh byte-identical across it and
//    a dead redo timeline cannot be attributed to a mesh write. The scrub's
//    call cannot be isolated at all — by the time any scrub runs, the latch has
//    already emptied the redo stack, so a second call on the same open chain
//    has nothing left to invalidate. That is a property of the design, not a
//    hole in this cell, and the count census in
//    `tests/unit/tool_gesture_runopen_g5_test.d` is what covers the set.
//
//    THE THREE-STEP ANTI-VACUITY, because `canRedo == false` is the trivial
//    state of a fresh history and would be satisfied for free:
//      1. a real command, then `/api/undo` -> canRedo must be TRUE;
//      2. activating the tool must LEAVE it true (so the kill below belongs to
//         the latch, not to activation);
//      3. only then the latch -> canRedo false, mesh UNCHANGED, and `/api/redo`
//         answering `noop`.
//    A killed timeline and a failed revert both answer `noop`, so the mesh
//    compare is what tells them apart: a failed revert would have moved the
//    mesh or left the stack non-empty.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("select.typeFrom edge");
    cmd("history.clear");
    setOrbitCamera();

    cmd("mesh.subdivide");
    settle();
    immutable size_t vSub = vertexCount();
    assert(vSub > 8,
        "control: `mesh.subdivide` left " ~ vSub.to!string ~ " vertices — the "
      ~ "command that seeds the redo timeline did nothing");

    auto ru = postJ("/api/undo");
    assert(ru["status"].str == "ok", "control: /api/undo failed: " ~ ru.toString);
    settle();
    assert(canRedo(),
        "CONTROL: after undoing a real command `canRedo` is FALSE. Then every "
      ~ "assertion below is satisfied by a field that can only ever answer "
      ~ "false, under the mutation as much as without it");

    immutable string beforeLatch = planes();

    cmd("tool.set mesh.edgeSliceTool on");
    settle(250);
    assert(canRedo(),
        "CONTROL: merely ACTIVATING the tool killed the redo timeline. The "
      ~ "latch below would then be credited with a kill it did not do");

    auto m  = model();
    auto vp = viewportFromCamera(fetchCamera(BASE));
    immutable int eA = edgeBetween(m, vertexAt(m, -0.5, -0.5, 0.5),
                                      vertexAt(m,  0.5, -0.5, 0.5));
    float ax, ay;
    assert(projectToWindow(edgeMidpoint(m, eA), vp, ax, ay),
        "the operand edge projects behind the camera");
    click(cast(int) ax, cast(int) ay);

    auto st = getJ("/api/tool/state");
    assert(st["edgeA"].integer == eA,
        "the latch did not take: edgeA=" ~ st["edgeA"].integer.to!string
      ~ ", expected " ~ eA.to!string ~ " — the picker missed, so nothing "
      ~ "reached `latchFirstPoint` and this cell would pass over a gesture "
      ~ "that never happened: " ~ st.toString);

    assert(planes() == beforeLatch,
        "the first latch MOVED the mesh. This cell's whole discrimination is "
      ~ "that the latch writes nothing and still kills the redo timeline; if "
      ~ "it writes, a dead timeline can no longer be attributed to "
      ~ "`invalidateRedo()`");

    assert(!canRedo(),
        "the first latch left the redo timeline ALIVE. "
      ~ "`EdgeSliceTool.latchFirstPoint`'s `history.invalidateRedo()` is the "
      ~ "deliberate task-0429 primitive: a standing preview writes outside the "
      ~ "history and must kill redo, or a redo pressed under the preview "
      ~ "replays onto a mesh nobody recorded");

    auto rr = postJ("/api/redo");
    assert(rr["status"].str == "noop",
        "with the timeline killed, /api/redo answered '" ~ rr["status"].str
      ~ "', expected 'noop': " ~ rr.toString);
    assert(planes() == beforeLatch,
        "the dead redo press MOVED the mesh — a killed timeline and a failed "
      ~ "revert both answer `noop`, and this is the compare that tells them "
      ~ "apart");

    cmd("tool.set mesh.edgeSliceTool off");
    settle();
}
