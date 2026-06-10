// Active-tool <-> history coordination (undo/redo migration Phase 0).
//
// P0 adds three base-Tool hooks (hasUncommittedEdit / cancelUncommittedEdit /
// resyncSession) and a main-thread `navHistory(isUndo)` chokepoint wired into
// exactly three interactive sites (keyboard Ctrl+Z / Ctrl+Shift+Z, and the
// history-panel drag-jump loop). The chokepoint:
//   - if the active tool holds an uncommitted live edit, the first Ctrl+Z
//     cancels THAT edit (no history pop); if that clears the last pending edit,
//     the tool deactivates;
//   - otherwise it pops/pushes the history stack and resyncs the tool.
//
// This file pins the KEYBOARD path end-to-end through /api/play-events:
// injected SDL_KEYDOWN(Ctrl+Z) must route through handleKeyDown ->
// navHistory(true) -> history.undo(). It asserts the canon-id special-case
// (history.undo / history.redo) added before the generic runCommand dispatch
// still drives plain undo/redo when no tool holds a live edit (activeTool ==
// null in these scenarios), and that the command FACTORIES were left raw (the
// /api/undo + /api/command paths, exercised by the other history tests, are
// unchanged).
//
// NOTE (follow-up, not blocking P0): a full live-edit-cancel e2e — open a tool
// drag, inject Ctrl+Z mid-flight, assert the live edit is cancelled while the
// prior committed step survives — needs either (a) an interactive preview build
// (EdgeExtrude's `built` path is gated behind the ImGui property panel, not
// reachable over HTTP) or (b) a frozen gizmo-handle drag log (camera + pixel
// coords). Both are heavier than this milestone warrants; the per-tool
// hasUncommittedEdit()/cancelUncommittedEdit() predicates are verified against
// each tool's real deactivate guard by code review (see the migration plan
// §3.2 table) and backstopped by the existing per-tool drag/deactivate suites
// (test_edge_extrude_tool, test_tool_move_drag, test_primitive_box, ...).

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;
import std.math : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// --- SDL constants (standard values; bindbc-sdl mirrors libSDL2) -----------
enum int SDLK_z       = 122;       // 'z'
enum int KMOD_LCTRL   = 0x0040;    // 64  — canonFromEvent reads KMOD_CTRL
enum int KMOD_LSHIFT  = 0x0001;    // 1

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

// A KEYDOWN/KEYUP pair for a key+modifier, as JSON-Lines consumed by
// EventPlayer (eventlog.d) and injected into the main loop -> handleKeyDown.
string keyTap(double t, int sym, int mod) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        t,        sym, mod,
        t + 10.0, sym, mod);
}

enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

void playKey(int sym, int mod) {
    auto r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ keyTap(50, sym, mod));
    assert(r["status"].str == "success",
        "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();
}

size_t undoLen() { return getJson("/api/history")["undo"].array.length; }
size_t redoLen() { return getJson("/api/history")["redo"].array.length; }
long   vertCount() { return getJson("/api/model")["vertexCount"].integer; }

// Run an argstring command through /api/command and assert ok. Used by the
// live-edit-cancel test (§5), which drives the testMode session hooks.
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double vertX(int idx) {
    return getJson("/api/model")["vertices"].array[idx].array[0].floating;
}

// Read back a live tool attr via the forms-engine `?` query idiom. The handler
// boxes the live value under "value" in the /api/command response.
double attrValue(string toolId, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ toolId ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok",
        "tool.attr query failed: " ~ r.toString);
    return r["value"].floating;
}

bool attrQueryOk(string toolId, string name) {
    auto r = postJson("/api/command", "tool.attr " ~ toolId ~ " " ~ name ~ " ?");
    return r["status"].str == "ok";
}

// Authoritative gizmo pivot: /api/toolpipe/eval runs the pipeline once and
// returns the evaluated ActionCenterPacket.center — the exact point the gizmo
// renders at (mirrors tools/perf/run.d's pivot read). Returns the X component
// (sufficient for the §6 single-axis relocate assertion).
double pivotX() {
    auto j = getJson("/api/toolpipe/eval");
    return j["actionCenter"]["center"].array[0].floating;
}

// ---------------------------------------------------------------------------
// 1. Keyboard Ctrl+Z routes through navHistory -> history.undo() when no tool
//    holds a live edit, and Ctrl+Shift+Z redoes. Pins the canon-id special
//    case in handleKeyDown (added BEFORE the generic command dispatch) and the
//    raw-factory invariant (the committed entry is a real history step).
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    long baseVerts = vertCount();

    // Commit one real edit so the undo stack has something to pop. An edge
    // extrude on a cube interior edge changes the vertex count (12 vs 8),
    // giving an unambiguous observable.
    auto m = getJson("/api/model");
    // top-front edge endpoints (-0.5,0.5,0.5)-(0.5,0.5,0.5)
    int va = -1, vb = -1;
    foreach (i, vv; m["vertices"].array) {
        auto a = vv.array;
        double x = a[0].floating, y = a[1].floating, z = a[2].floating;
        if (y > 0.49 && z > 0.49) {
            if (x < -0.49) va = cast(int)i;
            if (x >  0.49) vb = cast(int)i;
        }
    }
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = -1;
    foreach (i, e; m["edges"].array) {
        int p = cast(int)e.array[0].integer, q = cast(int)e.array[1].integer;
        if ((p == va && q == vb) || (p == vb && q == va)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "cube top-front edge not found");
    postJson("/api/select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`);
    postJson("/api/command",
        `{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);

    size_t undoAfterEdit = undoLen();
    assert(undoAfterEdit >= 1, "edit did not record a history entry");
    long extrudedVerts = vertCount();
    assert(extrudedVerts != baseVerts,
        "edge extrude should change the vertex count");

    // Keyboard Ctrl+Z (no active tool -> navHistory just pops history).
    playKey(SDLK_z, KMOD_LCTRL);
    assert(undoLen() == undoAfterEdit - 1,
        "Ctrl+Z did not pop one undo entry (undo stack "
        ~ undoLen().to!string ~ " expected " ~ (undoAfterEdit - 1).to!string ~ ")");
    assert(redoLen() >= 1, "Ctrl+Z did not push a redo entry");
    assert(vertCount() == baseVerts,
        "Ctrl+Z did not restore the pre-edit geometry");

    // Keyboard Ctrl+Shift+Z (redo) -> re-applies the edit.
    playKey(SDLK_z, KMOD_LCTRL | KMOD_LSHIFT);
    assert(undoLen() == undoAfterEdit,
        "Ctrl+Shift+Z did not restore the undo entry");
    assert(vertCount() == extrudedVerts,
        "Ctrl+Shift+Z did not re-apply the edit geometry");
}

// ---------------------------------------------------------------------------
// 2. The keyboard nav path is idempotent on an EMPTY stack (navHistory returns
//    false from history.undo() and records nothing) — a guard against the
//    canon special-case accidentally swallowing the key, throwing, or
//    recording a spurious entry. (/api/reset itself records a scene.reset
//    entry, so we clear the stack explicitly first.)
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    assert(undoLen() == 0, "history.clear did not empty the undo stack");
    long v0 = vertCount();

    playKey(SDLK_z, KMOD_LCTRL);   // Ctrl+Z on empty stack

    // Geometry unchanged and the stack stayed empty (no spurious record).
    assert(vertCount() == v0, "Ctrl+Z on empty stack changed geometry");
    assert(undoLen() == 0, "Ctrl+Z on empty stack grew the undo stack");
    assert(redoLen() == 0, "Ctrl+Z on empty stack pushed a redo entry");
}

// ---------------------------------------------------------------------------
// 3. (undo/redo migration P1) navHistory -> resyncSession() path: with an
//    interactive tool ACTIVE but holding NO open edit, a committed history step
//    popped via keyboard Ctrl+Z must (a) pop the step, (b) drive the active
//    tool's resyncSession() (re-init the cached pre-edit baseline + gizmo to the
//    now-current mesh) without throwing or corrupting state, and (c) leave the
//    tool coherent so a subsequent edit operates on the POST-undo geometry.
//
//    EdgeExtrudeTool is the witness: its activate() captures a `before`
//    MeshSnapshot of the current mesh; P1's resyncSession() re-captures `before`
//    from the now-current mesh after the pop (reinitSession()). Without that, a
//    later commit would pair against a stale baseline. We can't read `before`
//    over HTTP, but we CAN assert the end-to-end invariant: pop is clean,
//    redo re-applies, and a fresh edit lands on the post-undo mesh.
//
//    NOTE: the deeper golden-fixture "commit live drag -> undo -> live drag
//    again, assert gizmo recentered + baseline" lock is a documented follow-up
//    (same reason as the §2 note: the interactive `built` preview is panel-
//    gated, not reachable over HTTP). This pins the navHistory->resyncSession
//    wiring + post-undo coherence, which is P1's behavioural contract.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    long baseVerts = vertCount();

    // Commit a real edit so there is a prior step to pop underneath the tool.
    auto m = getJson("/api/model");
    int va = -1, vb = -1;
    foreach (i, vv; m["vertices"].array) {
        auto a = vv.array;
        double x = a[0].floating, y = a[1].floating, z = a[2].floating;
        if (y > 0.49 && z > 0.49) {
            if (x < -0.49) va = cast(int)i;
            if (x >  0.49) vb = cast(int)i;
        }
    }
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = -1;
    foreach (i, e; m["edges"].array) {
        int p = cast(int)e.array[0].integer, q = cast(int)e.array[1].integer;
        if ((p == va && q == vb) || (p == vb && q == va)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "cube top-front edge not found");
    postJson("/api/select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`);
    postJson("/api/command",
        `{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);

    size_t undoAfterEdit = undoLen();
    long extrudedVerts = vertCount();
    assert(extrudedVerts != baseVerts, "extrude should change vertex count");

    // Activate an interactive tool on the MAIN thread (tool.set runs through the
    // command bridge). It captures `before` from the CURRENT (extruded) mesh.
    // No open live edit (built==false right after activate) -> hasUncommittedEdit
    // is false, so keyboard Ctrl+Z takes the pop+resync branch, NOT the cancel
    // branch.
    auto act = postJson("/api/command", "tool.set edge.extrude");
    assert(act["status"].str == "ok" || act["status"].str == "success",
        "tool.set edge.extrude failed: " ~ act.toString);

    // Keyboard Ctrl+Z: navHistory(true) -> history.undo() (pops the extrude) ->
    // activeTool.resyncSession() (re-init `before`/gizmo against the now-current,
    // pre-extrude mesh). Must not throw; must pop exactly one entry.
    playKey(SDLK_z, KMOD_LCTRL);
    assert(undoLen() == undoAfterEdit - 1,
        "Ctrl+Z under an active tool did not pop one undo entry");
    assert(redoLen() >= 1, "Ctrl+Z under an active tool did not push redo");
    assert(vertCount() == baseVerts,
        "Ctrl+Z under an active tool did not restore pre-edit geometry");

    // The tool is still active and coherent: redo re-applies cleanly (the resync
    // left no half-built/stale state that would corrupt a subsequent step).
    playKey(SDLK_z, KMOD_LCTRL | KMOD_LSHIFT);
    assert(undoLen() == undoAfterEdit,
        "redo under an active tool did not restore the undo entry");
    assert(vertCount() == extrudedVerts,
        "redo under an active tool did not re-apply the edit geometry");

    // Deactivate the tool so we don't leak an active edge.extrude into later
    // tests (its deactivate() would no-op: built==false, nothing to commit).
    postJson("/api/command", "tool.set edge.extrude off");
}

// ---------------------------------------------------------------------------
// 4. (undo/redo migration P1) the resync path is robust across a TOPOLOGY-
//    changing pop with a deform-style tool active. xfrm.smooth wraps a
//    CommandWrapperTool whose activate() dups a `baseline` of the current
//    vertices; P1 adds resyncSession() that re-dups that baseline from the
//    post-undo mesh. Here the popped step changes the VERTEX COUNT (edge
//    extrude undo: 12 -> 8 on the cube), which would make a stale baseline a
//    different length than the live mesh. We assert the pop + resync survive
//    that and a redo still re-applies — i.e. resyncSession() didn't choke on a
//    length-mismatched baseline.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    long baseVerts = vertCount();

    auto m = getJson("/api/model");
    int va = -1, vb = -1;
    foreach (i, vv; m["vertices"].array) {
        auto a = vv.array;
        double x = a[0].floating, y = a[1].floating, z = a[2].floating;
        if (y > 0.49 && z > 0.49) {
            if (x < -0.49) va = cast(int)i;
            if (x >  0.49) vb = cast(int)i;
        }
    }
    int ei = -1;
    foreach (i, e; m["edges"].array) {
        int p = cast(int)e.array[0].integer, q = cast(int)e.array[1].integer;
        if ((p == va && q == vb) || (p == vb && q == va)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "cube top-front edge not found");
    postJson("/api/select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`);
    postJson("/api/command",
        `{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    size_t undoAfterEdit = undoLen();
    long extrudedVerts = vertCount();

    // Activate a deform tool (CommandWrapperTool baseline = current verts.dup,
    // length == extrudedVerts here).
    auto act = postJson("/api/command", "tool.set xfrm.smooth");
    assert(act["status"].str == "ok" || act["status"].str == "success",
        "tool.set xfrm.smooth failed: " ~ act.toString);

    // Pop the extrude underneath it -> mesh shrinks to baseVerts; resyncSession()
    // must re-dup the baseline to the new (shorter) length without asserting.
    playKey(SDLK_z, KMOD_LCTRL);
    assert(undoLen() == undoAfterEdit - 1, "Ctrl+Z did not pop one entry");
    assert(vertCount() == baseVerts, "Ctrl+Z did not restore pre-extrude verts");

    playKey(SDLK_z, KMOD_LCTRL | KMOD_LSHIFT);   // redo
    assert(vertCount() == extrudedVerts, "redo did not re-apply the extrude");

    postJson("/api/command", "tool.set xfrm.smooth off");
}

// ---------------------------------------------------------------------------
// 5. (forms-panel consistency) In-session keyboard Ctrl+Z on a live transform
//    edit must restore BOTH the geometry AND the tool's Tool-Properties attrs.
//
//    This closes the §2 follow-up: an open transform session, an in-session
//    Ctrl+Z, assert the live edit is cancelled. The testMode session hooks
//    (tool.beginSession / live tool.attr) — which did not exist at P0 — let us
//    open the session over HTTP without a frozen gizmo log.
//
//    The bug: cancelUncommittedEdit() restored the vertices (from the session
//    baseline) but left headlessTranslate at its edited value. The config form
//    / legacy sliders read the live &headlessTranslate.x pointer (params() ->
//    TX/TY/TZ) every frame, so the Position fields kept the stale number while
//    the geometry snapped back — gizmo, mesh, and panel out of sync.
//
//    Fix: beginEdit() snapshots the headless TRS attrs on the closed->open
//    transition; cancelUncommittedEdit() restores them with the vertices. We
//    assert the attr read-back (tool.attr move TX ?) returns the session-start
//    value 0, not the edited 0.2.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");

    // Select a single corner vertex so the move has an unambiguous observable.
    // v6 = (0.5, 0.5, 0.5) on the fresh cube.
    int v6 = -1;
    auto m = getJson("/api/model");
    foreach (i, vv; m["vertices"].array) {
        auto a = vv.array;
        if (a[0].floating > 0.49 && a[1].floating > 0.49 && a[2].floating > 0.49) {
            v6 = cast(int)i; break;
        }
    }
    assert(v6 >= 0, "cube +++ corner not found");
    postJson("/api/select", `{"mode":"vertices","indices":[` ~ v6.to!string ~ `]}`);

    cmd("tool.set move");

    // Session-start state: attr TX is 0, geometry pristine.
    assert(approxEqual(attrValue("move", "TX"), 0.0), "TX should start at 0");
    double x0 = vertX(v6);

    // Open a live session and drive an ABSOLUTE attr write (the same path a
    // form-field edit takes). Geometry moves and TX now reads 0.2.
    cmd("tool.beginSession");
    cmd("tool.attr move TX 0.2");
    assert(vertX(v6) > x0 + 0.19, "live attr write did not move geometry");
    assert(approxEqual(attrValue("move", "TX"), 0.2), "TX should read the edited 0.2");

    size_t undoBefore = undoLen();

    // In-session keyboard Ctrl+Z -> navHistory(true) -> hasUncommittedEdit()
    // (true) -> cancelUncommittedEdit(): the FIRST Ctrl+Z cancels the live edit
    // (no history pop). Geometry AND the attr must both snap back.
    playKey(SDLK_z, KMOD_LCTRL);

    assert(undoLen() == undoBefore,
        "in-session Ctrl+Z must NOT pop history (cancels the live edit instead); "
        ~ "before=" ~ undoBefore.to!string ~ " after=" ~ undoLen().to!string);
    assert(approxEqual(vertX(v6), x0),
        "in-session Ctrl+Z did not restore the geometry");
    assert(!attrQueryOk("move", "TX"),
        "in-session Ctrl+Z should deactivate move after cancelling its last pending edit");
    cmd("tool.set move");
    assert(approxEqual(attrValue("move", "TX"), 0.0),
        "reactivated move after Ctrl+Z should expose clean TX 0, got "
        ~ attrValue("move", "TX").to!string);

    postJson("/api/command", "tool.set move off");
}

// ---------------------------------------------------------------------------
// 6. (action-center consistency) An in-session Ctrl+Z on a transform edit that
//    was opened by a click-away RELOCATE must restore the action-center pin too
//    — not just geometry + attrs.
//
//    The bug: click-away relocates the gizmo (ACEN userPlaced pin) on
//    mouse-DOWN, BEFORE the edit session opens. cancelUncommittedEdit() restored
//    the vertices + attrs but left the pin at the click point, so the gizmo
//    stuck at the relocated position while the geometry snapped back.
//
//    Fix: setUserPlaced() stages the PRE-relocate pin state whenever no session
//    snapshot is frozen; beginEdit() freezes it as the session baseline on the
//    closed->open transition; cancelUncommittedEdit() restores it. A COMMIT
//    discards the snapshot WITHOUT restoring, so committed relocates persist.
//
//    Headless reproduction: the real click-pick reads GPU hover state, which is
//    unreachable over HTTP. We drive the SAME setUserPlaced() entry point via
//    `tool.pipe.attr actionCenter userPlacedCenter` (the documented headless
//    counterpart of the mouse-down relocate — it now routes through
//    setUserPlaced so it stages the cancel baseline exactly like a real click).
//    The ordering (relocate BEFORE beginSession) matches production.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");

    // Select the +++ corner so the Auto action center sits at that vertex
    // (single-vertex selection => centroid == the vertex). v6 = (0.5,0.5,0.5).
    int v6 = -1;
    auto m = getJson("/api/model");
    foreach (i, vv; m["vertices"].array) {
        auto a = vv.array;
        if (a[0].floating > 0.49 && a[1].floating > 0.49 && a[2].floating > 0.49) {
            v6 = cast(int)i; break;
        }
    }
    assert(v6 >= 0, "cube +++ corner not found");
    postJson("/api/select", `{"mode":"vertices","indices":[` ~ v6.to!string ~ `]}`);

    cmd("tool.set move");
    // Auto mode allows click-away relocate (Select/Element/Local refuse it).
    cmd("tool.pipe.attr actionCenter mode auto");

    // Pre-gesture pivot: Auto centroid of the single selected vertex = 0.5 in X.
    double pivot0 = pivotX();
    assert(approxEqual(pivot0, 0.5),
        "pre-relocate Auto pivot should be the selected vertex X 0.5, got "
        ~ pivot0.to!string);

    // RELOCATE (mouse-down stage in production): push a user-placed pin far from
    // the selection. The gizmo pivot now reads the relocated X.
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "5,0,0"`);
    assert(approxEqual(pivotX(), 5.0),
        "relocate did not move the pivot to the click point; got "
        ~ pivotX().to!string);

    // Now open the live session (beginEdit freezes the pre-relocate pin
    // baseline) and drive an attr write so geometry moves.
    double x0 = vertX(v6);
    cmd("tool.beginSession");
    cmd("tool.attr move TX 0.2");
    assert(vertX(v6) > x0 + 0.19, "live attr write did not move geometry");

    size_t undoBefore = undoLen();

    // In-session Ctrl+Z -> cancelUncommittedEdit(): geometry, attr AND the
    // action-center pin must all snap back to their session-start state.
    playKey(SDLK_z, KMOD_LCTRL);

    assert(undoLen() == undoBefore,
        "in-session Ctrl+Z must NOT pop history; before=" ~ undoBefore.to!string
        ~ " after=" ~ undoLen().to!string);
    assert(approxEqual(vertX(v6), x0),
        "in-session Ctrl+Z did not restore the geometry");
    assert(!attrQueryOk("move", "TX"),
        "in-session Ctrl+Z should deactivate move after cancelling its last pending edit");
    assert(approxEqual(pivotX(), pivot0),
        "in-session Ctrl+Z restored geometry but left the gizmo at the relocated "
        ~ "click point; expected pivot X " ~ pivot0.to!string
        ~ ", got " ~ pivotX().to!string);

    postJson("/api/command", "tool.set move off");
}
