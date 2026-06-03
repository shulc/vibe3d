// Active-tool <-> history coordination (undo/redo migration Phase 0).
//
// P0 adds three base-Tool hooks (hasUncommittedEdit / cancelUncommittedEdit /
// resyncSession) and a main-thread `navHistory(isUndo)` chokepoint wired into
// exactly three interactive sites (keyboard Ctrl+Z / Ctrl+Shift+Z, and the
// history-panel drag-jump loop). The chokepoint:
//   - if the active tool holds an uncommitted live edit, the first Ctrl+Z
//     cancels THAT edit (no history pop, tool stays active);
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

void main() {}

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
