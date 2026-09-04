// test_tool_gesture_g2 — task 1905, lane G0-G2: the FROZEN plane fixture for
// group G2 (the five `alignment`-family tools), driven by REAL GESTURES.
//
// WHY IT EXISTS, and why neither of the other two G2 witnesses can replace it.
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
// G2 DOES **NOT** SHARE THE SINGLE-WIRE-NAME PROPERTY THE G1 AND G4 LANES
// FOUND — measured while freezing this file, and it is the first group of the
// three where `entryNames` is a usable discriminator. Four distinct wire names
// over five cells:
//
//     mesh.mirrorTool      -> mesh.bevel_edit        (bevelEditFactory)
//     mesh.radialSweepTool -> mesh.bevel_edit        (bevelEditFactory)
//     mesh.radialArrayTool -> mesh.radial_array_edit (radialArrayEditFactory)
//     mesh.clone           -> mesh.clone_edit        (cloneEditFactory)
//     mesh.arrayTool       -> mesh.array_edit        (arrayEditFactory)
//
// So a mutation that must redden EXACTLY ONE cell CAN key on `entryNames` here,
// as long as the tool it re-points is not one of the two that collide — and
// re-pointing exactly one of those two still reddens exactly one cell, because
// the other keeps the shared name. `liveEntryNames` is carried anyway, for the
// reason the G1 lane added it and because in G2 it separates the group along a
// second, independent axis: the MOMENT of the record. `mesh.arrayTool` and
// `mesh.clone` record INSIDE the gesture (`onMouseButtonUp`), so their live
// names are already populated before the tool is dropped; the other three
// record at `deactivate()` and read EMPTY there.
//
// WHY THE DRIVE IS `/api/play-events` AND NEVER `tool.doApply`. `tool.doApply`
// records a `ToolDoApplyCommand` — a different entry, from a different site —
// so a cell built on it would freeze the geometry of a command while claiming
// to pin a tool's own commit body. Every cell below drives the input that
// REALLY reaches the tool's record site.
//
// THE PREVIEW WITNESS, AND A CORRECTION TO PLAN §5.3. G2 carries FOUR of the
// eight batchless previews. Three of them rebuild on the DOCUMENT mesh
// (`array_tool.d rebuildPreview`, `clone_tool.d rebuildPreview`,
// `radial_array_tool.d rebuildPreview`) and therefore DO tick
// `changeBus.unbatchedGeometryCommits`. The fourth, `mirror.d`'s free function
// `rebuildMirrorPreview`, writes the tool's OWN `previewMesh`, and plan §5.3
// says the counter cannot see it because the counter is filtered to the
// document mesh — true — and prescribes "a delivery-count band instead".
//
// MEASURED HERE: **the delivery channel is filtered by the SAME predicate.**
// `Mesh.deliverPending`'s first line is `if (!deliverySubjectAccepted(&this))
// return;`, the same `g_isDocumentMesh` the counter consults (`source/mesh.d`),
// so `deliveryCount` is exactly as blind to a preview mesh as
// `unbatchedGeometryCommits` is. A band on it would have been the same vacuous
// zero in a different column.
//
// What IS observable, and what these cells therefore freeze, is both channels
// read AGAINST THE DOCUMENT MESH across two spans of the same gesture:
//
//                            drag: ubgc / deliveries    drop: ubgc / deliveries
//     mirror (own preview)        0 / 0                      2 / 1
//     radialSweep (own preview)   0 / 0                      2 / 1
//     radialArray (doc mesh)     32 / 432                    0 / 0
//     array (doc mesh)           24 /  84                    0 / 0
//     clone (doc mesh)           24 /  60                    0 / 0
//
// The zero is NOT a bare zero: the SAME cell, on the SAME two counters, in the
// SAME run, requires them to move at the drop. A dead counter fails that half,
// so the zero half cannot be satisfied for free. Every one of those assertions
// says in its own message which mesh it is watching. (The numbers above were
// measured on the lane's own stand; the frozen ones are whatever the capture
// run produced on the suite lane's viewport, and they are pinned EXACTLY.)
//
// EVERY SHIPPED INTERACTIVE TEST OF THIS GROUP IS HOLLOW OR ABSENT, and that is
// why this file measures `postCommit != preOp` and `undoDelta == 1` before it
// measures anything else. Surveyed by DRIVING each one, at the tree this
// fixture was frozen against:
//
//   * `tests/test_mirror_tool_drag.d` — two real drags, both asserting only the
//     `center` ATTRIBUTE. The gesture does reach the record site (measured: the
//     drop takes the cube from 8 to 16 vertices and pushes one
//     `mesh.bevel_edit`), and not one line of the file would notice if it
//     stopped.
//   * `tests/test_radial_sweep_handle_drag.d` — a real drag asserting
//     `startAngle` plus `opLogEntriesRecorded == 0` WITH its own positive
//     control (that half is sound and is the sample this file copies). Nothing
//     asserts the tool built or recorded; measured, the drop goes 8 -> 108
//     vertices and pushes one entry.
//   * `tests/test_radial_array_handle_drag.d` — a real drag asserting `offset`.
//     Its sibling `tests/test_radial_array_center_space.d` DOES assert geometry
//     (12 vertices after an off-handle click), so this tool's PREVIEW has a real
//     witness — but neither file touches `/api/undo` or `/api/history`, so the
//     RECORD has none.
//   * `tests/test_tool_overlay_item_space.d` block 5 — a real haul on
//     `mesh.arrayTool` asserting the offset DELTA and the item-space law. Sound
//     for what it measures; silent about the commit.
//   * `mesh.clone` — **no interactive coverage anywhere**: `tool.set mesh.clone`
//     does not appear in one test in the tree. `tests/test_mesh_clone.d` drives
//     the one-shot COMMAND of the same name.
//
// So: no shipped test in this repository asserts that ANY of G2's five tools
// records anything when a real gesture commits. Five cells below are the first.
//
// `built` IS NOT A CHANNEL IN THIS GROUP — measured, all five: `/api/tool/state`
// answers `{}` for every one of them while armed and while built. The brief's
// "assert the tool reports itself built" is therefore unrepresentable here, and
// its place is taken by the two stronger, geometric anti-vacuity assertions in
// `runCell` (`postCommit != preOp`, `undoDelta == 1`) plus a named element-count
// assertion in each gesture.
//
// WHY THE FAILURES ACCUMULATE INSTEAD OF FAILING FAST. The acceptance criterion
// for this lane is plan §5.4's mutation table, whose every row names both the
// fields that must REDDEN and the fields that must stay GREEN. A cell that
// fails fast reports the first and hides the rest, so the green column — the
// half that makes a mutation DISCRIMINATING rather than merely loud — would not
// be observable at all. Fields accumulate; cells still fail on the first.
//
// RESIDUALS ARE FROZEN EXACTLY, NEVER TOLERATED. All five cells round-trip
// byte-for-byte in both directions on this tree, so every residual list is
// frozen EMPTY — and an empty list pinned exactly is still a pin: a residual
// that APPEARS reddens. Had one been non-empty it would have been frozen as its
// exact plane list, so that a residual which grows and a residual which
// disappears both redden.
//
// CAPTURE. `VIBE3D_TOOL_GESTURE_CAPTURE_G2=<abs path to g2.json>` makes this
// file WRITE the fixture instead of comparing it. The capture arm lives beside
// the reader on purpose (the `undo_parity` precedent): a capture script that is
// not the reader drifts from it, and then the fixture records a recipe no test
// runs. The destination is a PATH and not a flag because the suite lane runs
// from a per-worker scratch COPY of `tests/`, so `__FILE_FULL_PATH__` here does
// not name the repository file; the read side uses `import()`, which `-J=tests`
// resolves in either tree.
//
// LANE: `./run_test.d --no-build test_tool_gesture_g2`.
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
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

import plane_diff_helpers;
import drag_helpers;
import batchless_control_helpers;

void main() {}

alias BASE = testBaseUrl;

/// The frozen oracle. Read through `import()` rather than off disk: the suite
/// lane compiles a scratch COPY of `tests/`, and `-J=tests` resolves this in
/// both trees while `__FILE_FULL_PATH__` would name the copy.
enum string kFrozen = import("fixtures/tool_gesture/g2.json");

/// The one file allowed to write `g2.json`. Asserted against the fixture's own
/// `writtenBy`, so a second writer has to change the field and be seen.
enum string kWrittenBy = "tests/test_tool_gesture_g2.d";

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
    // drives the wire command. A trailing `?` is a READ (this file's `mirror`
    // cell reads `center` through a bare `postJ`, never through `cmd()`, but
    // the guard stays here too so a future read-through-`cmd()` cannot be
    // mistaken for a drive). Any other `cmd()` line is stand and unrecorded.
    if ((line.startsWith("tool.set ") || line.startsWith("tool.attr "))
        && !line.endsWith(" ?"))
        gDrove ~= parseToolLine(line);
}

// ---------------------------------------------------------------------------
// Parameter capture (task 3091) — the `parameters` block (schema 3010). See
// tests/test_tool_gesture_g1.d for the full rationale; this is the same
// mechanism: `cmd()` above records every tool.set/tool.attr WRITE off its own
// argstring, `runCell` resets `gDrove` before `stand()` and reads it into
// `Cell.drove` right after `drop()`, and each gesture call site below appends
// its own `gesture.drag` entry using the SAME literal already driving that
// call (or the magnitude only, where `dragAlongProjectedAxis` resolves the
// screen direction from a runtime projection).
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

/// Parse a `cmd()` argstring already known to start `tool.set `/`tool.attr `
/// into its normalised drove entry. A quoted tool id is unquoted.
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

/// `gesture.drag` where only the drag LENGTH is a literal — used at every
/// `dragAlongProjectedAxis` call, whose screen direction (and therefore its
/// resolved dx/dy, INCLUDING which axis carries the motion) is resolved from
/// a runtime projection.
Drove driveDragMagOnly(int dragPx, int steps = 16, int button = 1, int mod = 0,
                        bool hover = false) {
    return Drove("gesture.drag", format(
        `{"drag_px": %d, "steps": %d, "button": %d, "mod": %d, "hover": %s}`,
        dragPx, steps, button, mod, hover));
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

/// One bus counter. Read as a DELTA across a span, never absolutely: these are
/// process-cumulative and every other test in the lane moves them.
long busCounter(string key) { return getJ("/api/changes")[key].integer; }

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
    string   previewSubject;  // which mesh the preview writes. PROVENANCE — the
                              // witness is the four counter deltas below.
    string[] liveEntryNames;  // wire names standing between gesture and drop
    string[] entryNames;      // wire names standing after the commit
    long     undoDelta;       // EXACT, never "> 0"
    long     dragUnbatched, dragDeliveries;   // across the GESTURE, doc mesh
    long     dropUnbatched, dropDeliveries;   // across the DROP, doc mesh
    string   preOp, postCommit, postUndo, postRedo;
    string[] undoResidual;    // planes where postUndo differs from preOp
    string[] redoResidual;    // planes where postRedo differs from postCommit
    Drove[]  drove;           // task 3091: this cell's captured `parameters` drive
}

/// Drive one gesture and score it. `stand` builds the scene AND clears history;
/// `gesture` is the play-events drive; `drop` deactivates the tool.
Cell runCell(string name, string tool, string recordSite, string mode,
             string payload, string previewSubject,
             void delegate() stand, void delegate() gesture, void delegate() drop)
{
    Cell c;
    c.name = name; c.tool = tool; c.recordSite = recordSite;
    c.mode = mode; c.payload = payload; c.previewSubject = previewSubject;

    gDrove = [];   // task 3091: this cell's own (stand, gesture, drop) drive
    stand();
    immutable long u0 = undoLen();
    assert(u0 == 0,
        name ~ ": the stand left " ~ u0.to!string ~ " undo entr(ies) standing. "
      ~ "`undoDelta` is measured from a CLEARED stack, and a selection POST "
      ~ "records `mesh.select`, so the stand must clear history AFTER it "
      ~ "selects");
    c.preOp = planes();

    immutable long g0 = busCounter("unbatchedGeometryCommits");
    immutable long d0 = busCounter("deliveryCount");
    gesture();
    c.dragUnbatched  = busCounter("unbatchedGeometryCommits") - g0;
    c.dragDeliveries = busCounter("deliveryCount") - d0;
    c.liveEntryNames = historyNames();

    immutable long g1 = busCounter("unbatchedGeometryCommits");
    immutable long d1 = busCounter("deliveryCount");
    drop();
    settle();
    c.dropUnbatched  = busCounter("unbatchedGeometryCommits") - g1;
    c.dropDeliveries = busCounter("deliveryCount") - d1;
    c.postCommit = planes();
    c.entryNames = historyNames();
    c.undoDelta  = undoLen() - u0;
    c.drove      = gDrove;   // task 3091: captured after stand+gesture+drop

    // ANTI-VACUITY, BEFORE anything is compared. A gesture that moved no plane
    // makes every assertion below satisfiable by an undo that does nothing —
    // and it is the failure the whole shipped interactive coverage of this
    // group is one attribute-read away from (see the file header).
    assert(c.postCommit != c.preOp,
        name ~ ": the gesture moved NO plane. Its record, its undo and its redo "
      ~ "are then all satisfied by doing nothing. Either the drive missed the "
      ~ "handle, or the tool refused on this stand — check `/api/tool/handles`");
    assert(c.undoDelta == 1,
        name ~ ": the gesture left " ~ c.undoDelta.to!string ~ " undo entr(ies), "
      ~ "expected exactly 1. Zero means the commit never recorded; more than "
      ~ "one means an in-session run was left unspliced");

    // THE PREVIEW WITNESS, and it is a BAND ACROSS TWO SPANS on purpose. Three
    // of these tools preview on the DOCUMENT mesh and must move both counters
    // during the drag; two preview on their OWN mesh, which both channels
    // filter out through `g_isDocumentMesh`, and must read exactly zero there
    // while moving both at the drop. Each half is the other's control.
    if (c.dragUnbatched == 0 && c.dragDeliveries == 0) {
        assert(c.dropUnbatched > 0 && c.dropDeliveries > 0,
            name ~ ": watching the DOCUMENT mesh, the drag ticked 0 unbatched "
          ~ "geometry commits and delivered 0 — consistent with a tool that "
          ~ "previews on its OWN mesh — but the DROP ticked "
          ~ c.dropUnbatched.to!string ~ " / delivered "
          ~ c.dropDeliveries.to!string ~ " too. Both channels are then dead for "
          ~ "this whole cell (`/api/changes` stale, or `g_isDocumentMesh` "
          ~ "uninstalled), and the drag's two zeroes are satisfied for free "
          ~ "rather than measured");
    } else {
        assert(c.dragUnbatched > 0 && c.dragDeliveries > 0,
            name ~ ": watching the DOCUMENT mesh, the drag moved one channel "
          ~ "and not the other (unbatched " ~ c.dragUnbatched.to!string
          ~ ", deliveries " ~ c.dragDeliveries.to!string ~ "). A document-mesh "
          ~ "preview commits Geometry outside any batch, so both must move "
          ~ "together; one alone means the two are keyed differently and the "
          ~ "frozen pair below is pinning an accident");
    }

    auto ru = postJ("/api/command", commandBody("history.undo"));
    assert(ru["status"].str == "ok", name ~ ": /api/undo failed: " ~ ru.toString);
    settle();
    c.postUndo = planes();
    assert(undoLen() == u0,
        name ~ ": the undo moved the stack to " ~ undoLen().to!string
      ~ ", expected back to " ~ u0.to!string ~ " — more than one step means the "
      ~ "entry's revert() answered false and the suffix behind it was truncated");

    auto rr = postJ("/api/command", commandBody("history.redo"));
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
    s ~= "  \"family\": \"tool_gesture_g2\",\n";
    s ~= "  \"parameters\": " ~ parametersJson(cells) ~ ",\n";
    s ~= "  \"writtenBy\": \"" ~ kWrittenBy ~ "\",\n";
    s ~= "  \"producedBy\": \"" ~ environment.get("VIBE3D_TOOL_GESTURE_SHA", "unknown") ~ "\",\n";
    s ~= "  \"stand\": \"per-cell; see each cell's drive in the producer\",\n";
    s ~= "  \"recipe\": \"" ~ kRecipe ~ "\",\n";
    s ~= "  \"provenance\": " ~ provenanceJson() ~ ",\n";
    s ~= "  \"cells\": [\n";
    foreach (i, ref c; cells) {
        s ~= "    {\n";
        s ~= format("      \"name\": \"%s\", \"tool\": \"%s\",\n", c.name, c.tool);
        s ~= format("      \"recordSite\": \"%s\", \"mode\": \"%s\", \"payload\": \"%s\",\n",
                    c.recordSite, c.mode, c.payload);
        s ~= format("      \"previewSubject\": \"%s\",\n", c.previewSubject);
        s ~= format("      \"liveEntryNames\": %s,\n", JSONValue(c.liveEntryNames).toString());
        s ~= format("      \"entryNames\": %s,\n",     JSONValue(c.entryNames).toString());
        s ~= format("      \"undoDelta\": %d,\n",      c.undoDelta);
        s ~= format("      \"dragUnbatched\": %d, \"dragDeliveries\": %d,\n",
                    c.dragUnbatched, c.dragDeliveries);
        s ~= format("      \"dropUnbatched\": %d, \"dropDeliveries\": %d,\n",
                    c.dropUnbatched, c.dropDeliveries);
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

    void counter(string what, long frozenV, long freshV, string why) {
        field(what, frozenV == freshV,
              "frozen " ~ frozenV.to!string ~ " vs fresh " ~ freshV.to!string
            ~ " (watching the DOCUMENT mesh; " ~ why ~ ")");
    }
    counter("dragUnbatched", frozen["dragUnbatched"].integer, fresh.dragUnbatched,
            "this tool's preview subject is: " ~ fresh.previewSubject);
    counter("dragDeliveries", frozen["dragDeliveries"].integer, fresh.dragDeliveries,
            "this tool's preview subject is: " ~ fresh.previewSubject);
    counter("dropUnbatched", frozen["dropUnbatched"].integer, fresh.dropUnbatched,
            "the drop is the positive control for the drag's two spans");
    counter("dropDeliveries", frozen["dropDeliveries"].integer, fresh.dropDeliveries,
            "the drop is the positive control for the drag's two spans");

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
    string msg = "tests/fixtures/tool_gesture/g2.json [" ~ fresh.name
               ~ "]: " ~ bad.length.to!string ~ " field(s) moved against the "
               ~ "frozen capture (record site: " ~ fresh.recordSite
               ~ ", mode " ~ fresh.mode ~ ", payload " ~ fresh.payload ~ "):\n";
    foreach (b; bad) msg ~= b ~ "\n";
    msg ~= "  Fields NOT listed above stayed green — that is the discriminating "
         ~ "half of every row in plan §5.4's mutation table.";
    assert(false, msg);
}

/// Capture, or compare. `VIBE3D_TOOL_GESTURE_CAPTURE_G2` holds the ABSOLUTE
/// destination path when capturing.
void freezeOrCompare(Cell[] cells) {
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    assert(cells.length > 0, "g2: no cells — the fixture would be empty");

    immutable dest = environment.get("VIBE3D_TOOL_GESTURE_CAPTURE_G2", "");
    if (dest.length > 0) {
        mkdirRecurse(dirName(dest));
        write(dest, fixtureJson(cells));
        return;
    }

    auto frozen = parseJSON(kFrozen);
    assert(frozen["writtenBy"].str == kWrittenBy,
        "g2.json says it is written by '" ~ frozen["writtenBy"].str
      ~ "' but this reader is '" ~ kWrittenBy ~ "'. Two writers into one "
      ~ "fixture is how a capture meant for one roster silently re-freezes "
      ~ "another's");
    assert(frozen["producedBy"].str.length > 0,
        "g2.json: empty `producedBy` — a fixture with no provenance cannot be "
      ~ "shown to predate the code it is the oracle for");

    auto fc = frozen["cells"].array;
    assert(fc.length == cells.length,
        format("g2.json holds %d cells, the recipe produced %d — a cell added "
             ~ "or removed without re-freezing", fc.length, cells.length));
    foreach (i, ref c; cells) {
        assert(fc[i]["name"].str == c.name,
            format("g2.json: cell %d is '%s' frozen and '%s' now — the roster "
                 ~ "was reordered", i, fc[i]["name"].str, c.name));
        scoreCell(c, fc[i]);
    }
}

// ---------------------------------------------------------------------------
// Stands and gestures
// ---------------------------------------------------------------------------

void resetCube() {
    auto r = postJ("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}

void setCamera(double az, double el, double dist) {
    auto r = postJ("/api/camera",
        format(`{"azimuth":%g,"elevation":%g,"distance":%g,`
             ~ `"focus":{"x":0,"y":0,"z":0}}`, az, el, dist));
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
    settle(150);
}

/// Drag from `from` in the SCREEN direction that `axis` projects to at
/// `anchor`. Used where the tool publishes no handle part whose screen anchor
/// sits where the press must land.
void dragAlongProjectedAxis(Vec3 from, Vec3 anchor, Vec3 axis, double pixels,
                            int steps = 16) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float fx, fy, ax, ay, tx, ty;
    assert(projectToWindow(from,          vp, fx, fy), "press point is behind the camera");
    assert(projectToWindow(anchor,        vp, ax, ay), "anchor projects behind the camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty), "axis tip projects behind the camera");
    immutable double dx = tx - ax, dy = ty - ay;
    immutable double len = sqrt(dx * dx + dy * dy);
    assert(len > 1.0,
        "the axis projects to a point on this framing, so no drag direction "
      ~ "separates the handle branch from the free one");
    dragPixels(cast(int) fx, cast(int) fy,
               cast(int)(fx + dx / len * pixels),
               cast(int)(fy + dy / len * pixels), steps);
    // Every call in this file resolves BOTH the direction and the axis of
    // motion from a runtime projection — only the drag LENGTH is a literal.
    gDrove ~= driveDragMagOnly(cast(int) pixels, steps);
}

// ---------------------------------------------------------------------------
// 0. POSITIVE CONTROL FIRST, and it is not decoration.
//
//    Almost everything below is "the fresh dump equals the frozen one", "this
//    residual list is EMPTY" and "this counter read exactly N". A DEAD channel
//    satisfies the middle kind for free and turns the last kind into two
//    constants: `/api/mesh/planes` answering a stale copy makes every
//    `undoResidual == []` true no matter what the undo did, an `/api/history`
//    that stopped reporting makes every `entryNames` compare against a
//    constant, and an `unbatchedGeometryCommits` that structurally never ticks
//    is exactly the trap plan §5.3 names for the two own-preview tools here.
//    So make ALL FOUR channels move first, with a command that belongs to no
//    group in this task.
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
    immutable long   g0     = busCounter("unbatchedGeometryCommits");
    immutable long   d0     = busCounter("deliveryCount");

    // The shared batchless control — POST EVERY ELEMENT, in order. It is the
    // only sequence in the tree that is still guaranteed to tick
    // `unbatchedGeometryCommits`, and it restores the mesh behind itself.
    foreach (line; kBatchlessControlSeq) cmd(line);
    settle();

    immutable long ctrlUnbatched  = busCounter("unbatchedGeometryCommits") - g0;
    immutable long ctrlDeliveries = busCounter("deliveryCount") - d0;
    assert(ctrlUnbatched > 0,
        kBatchlessControlWhy ~ ctrlUnbatched.to!string ~ kBatchlessControlFix);
    assert(ctrlDeliveries > 0,
        "CONTROL: the " ~ kBatchlessControlCommand ~ " sequence delivered "
      ~ ctrlDeliveries.to!string ~ " change(s), expected more than zero. "
      ~ "`deliveryCount` is the SECOND channel every cell's preview witness "
      ~ "reads, and the two own-preview cells (mirror, radialSweep) assert it "
      ~ "at exactly 0 across their drag. A dead delivery counter satisfies "
      ~ "those zeroes for free");

    // Now the plane and history channels, with a command of no group here.
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
        "CONTROL: the control sequence plus `mesh.clone` moved the undo stack by "
      ~ (undoLen() - u0).to!string ~ ", expected exactly 1 (the sequence undoes "
      ~ "its own paste) — /api/history is not tracking, so every `undoDelta` "
      ~ "and `entryNames` assertion below is comparing two constants");
    assert(historyNames()[$ - 1] == "mesh.clone",
        "CONTROL: the top history entry is '" ~ historyNames()[$ - 1]
      ~ "', expected 'mesh.clone' — the wire-name channel is not live");

    // And the diff must be able to say EMPTY as well as non-empty, or it is a
    // predicate that always answers "different" and no residual pin means
    // anything either.
    assert(planeDiff(after, planes()).length == 0,
        "CONTROL: two dumps of the SAME unchanged mesh compared as different — "
      ~ "planeDiff() is not a stable predicate");

    postJ("/api/command", commandBody("history.undo"));
    settle();
}

// ---------------------------------------------------------------------------
// 1. The roster: FIVE cells, one per G2 record site. ONE unittest, because they
//    share one frozen file and the fixture compare is per-cell anyway (each
//    cell raises its own accumulated assert, naming itself).
//
//    All five write through `history.record` (mode `Plain`) and all five carry
//    a `MeshSessionEdit` — measured, not assumed: the four factories this group
//    is bound to (`bevelEditFactory`, `radialArrayEditFactory`,
//    `cloneEditFactory`, `arrayEditFactory`, `source/app.d`) all construct that
//    one class. What separates G2 from the other two groups closed so far is
//    that those four factories carry FOUR DIFFERENT WIRE NAMES.
// ---------------------------------------------------------------------------
unittest {
    Cell[] cells;

    // --- (a) MirrorTool. Commits from `deactivate()`, so `liveEntryNames` is
    //     EMPTY and the whole geometry appears at the DROP. The gesture is the
    //     centre-box haul — the same drive `tests/test_mirror_tool_drag.d`'s
    //     second block runs, whose only assertion is the `center` attribute.
    //     No face selection: Mirror's mask rule is `operandFaceMask()`, so an
    //     empty selection means the whole cube, which is what makes the drop's
    //     8 -> 16 vertices a named, checkable number.
    cells ~= runCell("mirror/centre-box-haul", "mesh.mirrorTool",
        "source/tools/alignment/mirror.d MirrorTool.commitMirrorEdit (from deactivate)",
        "Plain", "MeshSessionEdit",
        "its OWN previewMesh (mirror.d rebuildMirrorPreview) — BOTH bus channels filter it out",
        { resetCube(); cmd("history.clear"); setOrbitCamera();
          cmd("tool.set mesh.mirrorTool on"); settle(250); },
        {
            dragAlongProjectedAxis(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0), 60);
            auto c = postJ("/api/command", "tool.attr mesh.mirrorTool center ?");
            assert(c["status"].str == "ok", "mirror: centre read failed: " ~ c.toString);
            auto a = c["value"].array;
            immutable bool moved = abs(a[0].floating) > 0.02
                                || abs(a[1].floating) > 0.02
                                || abs(a[2].floating) > 0.02;
            assert(moved,
                "mirror: the centre-box haul left `center` at the origin — the "
              ~ "press missed the box, nothing engaged, and the drop will "
              ~ "record nothing");
        },
        {
            cmd("tool.set mesh.mirrorTool off");
            settle(250);
            assert(vertexCount() == 16,
                "mirror: the drop left " ~ vertexCount().to!string ~ " vertices, "
              ~ "expected 16 (the 8-vertex cube plus its whole-mesh mirror). "
              ~ "This is the assertion `tests/test_mirror_tool_drag.d` never "
              ~ "made: it reads the centre ATTRIBUTE and would stay green if "
              ~ "the tool mirrored nothing at all");
        });

    // --- (b) RadialSweepTool. Also commits from `deactivate()`. Driven exactly
    //     as `tests/test_radial_sweep_handle_drag.d` drives it — the Start
    //     Angle handle, which at the defaults (axis +Y, centre origin, start
    //     angle 0) sits at (0,0,-0.7*arm) and travels along -X.
    cells ~= runCell("radial.sweep/start-angle-haul", "mesh.radialSweepTool",
        "source/tools/alignment/radial_sweep_tool.d RadialSweepTool.commitSweepEdit (from deactivate)",
        "Plain", "MeshSessionEdit",
        "its OWN previewMesh, inside an UNRECORDED MeshEditBatch — BOTH bus channels filter it out",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          cmd("tool.set mesh.radialSweepTool on"); settle(250); },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            immutable float arm = gizmoSize(Vec3(0, 0, 0), vp) * 0.7f;
            Vec3 handle = Vec3(0, 0, -arm);
            dragAlongProjectedAxis(handle, handle, Vec3(-1, 0, 0), 80);
            assert(abs(attrOf("mesh.radialSweepTool", "startAngle")) > 0.5,
                "radial.sweep: the haul left `startAngle` at zero — this tool "
              ~ "consumes nothing when the press misses every handle");
        },
        {
            cmd("tool.set mesh.radialSweepTool off");
            settle(250);
            assert(vertexCount() > 8,
                "radial.sweep: the drop left " ~ vertexCount().to!string
              ~ " vertices, expected more than the cube's 8 — the revolve "
              ~ "inserted nothing, so `commitSweepEdit` was never reached "
              ~ "(deactivate() commits only when `inserted > 0`)");
        });

    // --- (c) RadialArrayTool. Commits from `deactivate()`, but PREVIEWS ON THE
    //     DOCUMENT MESH, so it is one of the three cells whose drag must move
    //     both bus channels. The Offset arrow is grabbed mid-shaft along the
    //     tool's own axis (+Y at the defaults).
    cells ~= runCell("radial.array/offset-arrow-haul", "mesh.radialArrayTool",
        "source/tools/alignment/radial_array_tool.d RadialArrayTool.commitEdit (from deactivate)",
        "Plain", "MeshSessionEdit",
        "the DOCUMENT mesh (radial_array_tool.d rebuildPreview) — batchless, both channels see it",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.radialArrayTool on"); settle(300); },
        {
            auto vp = viewportFromCamera(fetchCamera(BASE));
            immutable float arm = gizmoSize(Vec3(0, 0, 0), vp);
            dragAlongProjectedAxis(Vec3(0, arm * 0.6f, 0), Vec3(0, 0, 0),
                                   Vec3(0, 1, 0), 80);
            assert(abs(attrOf("mesh.radialArrayTool", "offset")) > 1e-3,
                "radial.array: the haul left `offset` at zero — a press that "
              ~ "missed the arrow only repositions the centre");
        },
        { cmd("tool.set mesh.radialArrayTool off"); });

    // --- (d) ArrayTool. Records INSIDE the gesture, at `onMouseButtonUp`, so
    //     its `liveEntryNames` is already populated before the tool is dropped
    //     and the drop itself records nothing more. No handle at all: the haul
    //     is anchored wherever the press lands and feeds `planeDragDelta`, so
    //     the press is the viewport centre by construction — the same drive
    //     `tests/test_tool_overlay_item_space.d` block 5 uses.
    cells ~= runCell("array/centre-haul", "mesh.arrayTool",
        "source/tools/alignment/array_tool.d ArrayTool.commitEdit (from onMouseButtonUp)",
        "Plain", "MeshSessionEdit",
        "the DOCUMENT mesh (array_tool.d rebuildPreview) — batchless, both channels see it",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.arrayTool on"); settle(300); },
        {
            auto cam = fetchCamera(BASE);
            immutable int cx = cam.vpX + cam.width / 2;
            immutable int cy = cam.vpY + cam.height / 2;
            dragPixels(cx, cy, cx + 70, cy - 40, 12);
            gDrove ~= driveDrag(70, -40, 12);
            assert(vertexCount() > 8,
                "array: the haul left " ~ vertexCount().to!string ~ " vertices, "
              ~ "expected more than the cube's 8. The shipped drive of this "
              ~ "gesture asserts only the offset ATTRIBUTE, which moves whether "
              ~ "or not the grid kernel copied one face");
        },
        { cmd("tool.set mesh.arrayTool off"); });

    // --- (e) CloneTool. The one tool in this group with NO interactive
    //     coverage anywhere in the tree — `tool.set mesh.clone` appears in no
    //     test — so this cell is its first. Records at `onMouseButtonUp` like
    //     ArrayTool; gated to Polygons mode, and a zero drag delta builds
    //     nothing, which is why the haul is a real 70x40 px move.
    cells ~= runCell("clone/centre-haul", "mesh.clone",
        "source/tools/alignment/clone_tool.d CloneTool.commitEdit (from onMouseButtonUp)",
        "Plain", "MeshSessionEdit",
        "the DOCUMENT mesh (clone_tool.d rebuildPreview) — batchless, both channels see it",
        { resetCube(); selectMode("polygons", [4]); cmd("history.clear");
          setOrbitCamera(); cmd("tool.set mesh.clone on"); settle(300); },
        {
            auto cam = fetchCamera(BASE);
            immutable int cx = cam.vpX + cam.width / 2;
            immutable int cy = cam.vpY + cam.height / 2;
            dragPixels(cx, cy, cx + 70, cy - 40, 12);
            gDrove ~= driveDrag(70, -40, 12);
            assert(vertexCount() == 12,
                "clone: the haul left " ~ vertexCount().to!string ~ " vertices, "
              ~ "expected 12 (the cube's 8 plus one 4-corner copy of face 4). "
              ~ "Zero growth means `rebuildPreview` took its zero-delta early "
              ~ "exit and `built` stayed false, so the mouse-up records nothing");
        },
        { cmd("tool.set mesh.clone off"); });

    freezeOrCompare(cells);
}
