// A SESSION RECORD FIRED WITHOUT ITS SESSION (task 1552).
//
// `mesh.bevel_edit` is the wire name of `MeshSessionEdit` — the RECORD of an
// interactive tool gesture, carrying the (before, after) snapshots the tool
// captured. Only REDO re-enters it with that payload. Built fresh from the
// command registry it is BLANK, and restoring a blank snapshot assigned empty
// arrays over the live mesh: a measured 8v/6f cube went to 0v/0f, the command
// answered `ok`, and the entry it left could not undo the damage (its
// `before` was blank too).
//
// FIVE PATHS REACH IT and all five converge on `Command.apply()`, so one gate
// closes them: `/api/command`, `/api/history/replay`, the History panel's `>`
// button and its "Re-run" context item, the macro recorder, and
// `history.saveAsScript`. The two POLICY branches do NOT converge, though —
// a script-origin refusal throws and becomes `{"status":"error"}`, a
// UI-origin one becomes a notice — so both are driven here (C-1, C-5).
//
// WHY C-3 CARRIES THREE ASSERTIONS AND NOT ONE. `/api/history` serializes
// `undoEntriesVisible()`, which FILTERS `ToolLifecycle` entries;
// `/api/history/replay` indexes the RAW `undoStack`. They are two index
// spaces. Whenever they disagree, replay lands on an entry whose command line
// is "" and the route answers `{"status":"error","message":"no entry at given
// index"}` — status `error`, mesh intact, the check passes, and the mutation
// it names ("delete the gate") cannot redden it. So the check pins the index
// space (`toolLifecycleCount == 0`, which makes the two spaces equal
// element-for-element), searches for the entry BY NAME rather than assuming a
// position, and asserts the refusal's TEXT, which is what tells a real
// refusal apart from a missed entry.

import std.json;
import std.net.curl : get, post;
import std.algorithm : canFind;
import std.conv : to;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.polyInsetTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(BASE ~ path));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void resetScene() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}

size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }
size_t faceCount()   { return getJson("/api/model")["faces"].array.length; }
long   modelDepth()  { return getJson("/api/undo/status")["modelDepth"].integer; }

unittest { // C-1 — the bare script call REFUSES and does not touch the mesh
    resetScene();
    assert(vertexCount() == 8 && faceCount() == 6,
        "the reset document is expected to be the 8v/6f cube");

    auto r = postJson("/api/command", "mesh.bevel_edit");
    assert(r["status"].str == "error",
        "a payload-less session record must be REFUSED to a script: "
        ~ r.toString);
    assert(r["message"].str.canFind("no recorded edit session"),
        "the refusal must carry its own reason, not just fail: " ~ r.toString);

    assert(vertexCount() == 8,
        "the mesh lost vertices to a payload-less mesh.bevel_edit: "
        ~ vertexCount().to!string);
    assert(faceCount() == 6,
        "the mesh lost faces to a payload-less mesh.bevel_edit: "
        ~ faceCount().to!string);
}

unittest { // C-2 — a refusal leaves NO undo entry behind
    // The point of the check, and why it is separate from C-1: the entry the
    // old behaviour recorded was un-undoable (its `before` was blank too), so
    // "did it wipe the mesh" and "did it leave a record you cannot walk back"
    // are two different questions. A command that refuses must not appear on
    // the stack at all.
    resetScene();
    const long before = modelDepth();

    // Deliberately NOT asserting the status here: C-1 owns that claim, and a
    // status assert in front of this one would fire first under the mutation
    // that is supposed to redden THIS check, leaving the depth unmeasured.
    postJson("/api/command", "mesh.bevel_edit");

    assert(modelDepth() == before,
        "a refused command must not be recorded — modelDepth went "
        ~ before.to!string ~ " -> " ~ modelDepth().to!string);
}

unittest { // C-3 — Re-run of a REAL recorded session refuses, mesh intact
    // The recipe is imported verbatim from tests/test_poly_inset_drag.d: a
    // polygon-mode drag sets `built` inside onMouseMotion, so deactivating
    // the tool commits through `commitEdit()`, which records the session
    // under the wire name "mesh.bevel_edit". No latch plumbing to trust.
    resetScene();

    auto r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    // AFTER the select, deliberately unlike the original — this clears any
    // entry the select itself left, so the session record lands at a
    // predictable place. The search below does not depend on that, but a
    // surprise here is worth seeing rather than absorbing.
    cmd("history.clear");

    cmd("tool.set " ~ TOOL ~ " on");

    auto cam = fetchCamera(BASE);
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy - 60, 12), BASE);

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));

    cmd("tool.set " ~ TOOL ~ " off");

    // (a) PIN THE INDEX SPACE. /api/history hides ToolLifecycle entries and
    // /api/history/replay does not; at zero such entries the two number the
    // stack identically. Measured, not assumed — this is an assertion about
    // the state this recipe produced, not a fact about the tool.
    auto st = getJson("/api/undo/status");
    assert(st["toolLifecycleCount"].integer == 0,
        "this check reads an index out of /api/history and feeds it to "
        ~ "/api/history/replay; those are the same numbering ONLY while no "
        ~ "ToolLifecycle entry sits on the stack. Got: " ~ st.toString);

    // (b) ANTI-VACUUM. If the recipe failed to record a session, everything
    // below would pass vacuously against some other entry (or none).
    auto hist = getJson("/api/history");
    long idx = -1;
    foreach (i, e; hist["undo"].array)
        if (e["command"].str == "mesh.bevel_edit") { idx = cast(long)i; break; }
    assert(idx >= 0,
        "no mesh.bevel_edit entry was recorded — the drag recipe did not "
        ~ "commit a session, so the replay below would prove nothing. "
        ~ "/api/history was: " ~ hist.toString);

    // (c) THE LOAD-BEARING ASSERT. The message is what separates "the command
    // refused" from "there was no entry at that index" — both of which are
    // `status:error` with an intact mesh.
    const size_t vBefore = vertexCount();
    assert(vBefore > 0, "the recipe left no mesh to lose");
    auto rep = postJson("/api/history/replay",
                        `{"index":` ~ idx.to!string ~ `}`);
    // THE DATA-LOSS ASSERT FIRST, on purpose: this is the defect the task is
    // about, and putting it ahead of the status/message pair means the
    // mutation "delete the gate" reddens it showing the actual wipe rather
    // than tripping a status assert on the way there.
    assert(vertexCount() == vBefore,
        "the re-run wiped the mesh: " ~ vBefore.to!string ~ " -> "
        ~ vertexCount().to!string);
    assert(rep["status"].str == "error",
        "re-running a recorded session record must refuse: " ~ rep.toString);
    assert(rep["message"].str.canFind("no recorded edit session"),
        "the replay must fail because the CARRIER IS BLANK, not because the "
        ~ "index missed the entry. Got: " ~ rep.toString);
}

unittest { // C-5 — the GUI policy branch: a notice, not a thrown error
    // The History panel's `>` button and "Re-run" item dispatch with
    // CommandOrigin.ui, which goes through runUiCommand and turns a refusal
    // into a notice. C-1/C-3 drive the script branch only; without this case
    // the panel path is unwitnessed.
    resetScene();

    auto r = postJson("/api/command?origin=ui", "mesh.bevel_edit");
    assert(r["status"].str == "ok",
        "a UI-origin refusal must NOT surface as a thrown error: "
        ~ r.toString);

    auto pol = getJson("/api/ui/policy");
    assert("last" in pol.object, "the UI dispatch must be recorded: " ~ pol.toString);
    assert(pol["last"]["id"].str == "mesh.bevel_edit", pol.toString);
    assert(pol["last"]["refused"].boolean,
        "the record must say the command refused: " ~ pol.toString);
    assert(pol["last"]["notice"].str.canFind("no recorded edit session"),
        "the notice must carry the reason to the user: " ~ pol.toString);

    assert(vertexCount() == 8 && faceCount() == 6,
        "the UI branch wiped the mesh: " ~ vertexCount().to!string ~ "v/"
        ~ faceCount().to!string ~ "f");
}

unittest { // C-4 — the neighbour: mesh.vertex_edit with no payload REFUSES
    resetScene();

    auto r = postJson("/api/command", "mesh.vertex_edit");
    assert(r["status"].str == "error",
        "a payload-less vertex edit must be refused: " ~ r.toString);
    assert(r["message"].str.canFind("no vertex edit payload"),
        "the refusal must carry its own reason: " ~ r.toString);
}

unittest { // C-4c — …and leaves no junk 'Edit 0 verts' entry behind
    // A SEPARATE block, not a third assert on C-4: the harm here is not data
    // loss but a bogus undo step plus a Position commit that invalidates
    // every position-keyed cache. If this rode behind C-4's status assert,
    // the mutation that is meant to redden it would trip that assert first
    // and the history depth would never be read.
    resetScene();
    const long before = modelDepth();

    postJson("/api/command", "mesh.vertex_edit");

    assert(modelDepth() == before,
        "a refused vertex edit must not leave a junk 'Edit 0 verts' entry — "
        ~ "modelDepth went " ~ before.to!string ~ " -> "
        ~ modelDepth().to!string);
}

unittest { // C-4b — WHERE the C-4 gate sits: after the length check
    // The same body tests/test_vertex_edit.d sends for "missing indices
    // field": before/after of one entry each, no `indices`. That is a real
    // length mismatch and the existing message names all three lengths. A
    // gate placed ahead of it would answer "no payload" instead — a lie
    // about before/after — while a test that only reads `status` stayed
    // green. This pins the existing sentence so the ordering is witnessed.
    resetScene();

    auto r = postJson("/api/command",
        `{"id":"mesh.vertex_edit","params":{"before":[[-0.5,-0.5,-0.5]],"after":[[1,2,3]]}}`);
    assert(r["status"].str == "error", r.toString);
    assert(r["message"].str.canFind("length mismatch"),
        "a genuine length mismatch must still be reported as one: " ~ r.toString);
    assert(r["message"].str.canFind("indices=0 before=1 after=1"),
        "the message must keep naming all three lengths — the empty-payload "
        ~ "gate must not intercept this case: " ~ r.toString);
}
