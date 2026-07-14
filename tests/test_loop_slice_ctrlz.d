// test_loop_slice_ctrlz.d — task 0400: interactive Ctrl+Z during an active
// Loop Slice tool must NEVER drop the tool. Reference behavior captured live
// (gdb symbol channel + geometry cross-check, see
// doc/tasks/work/0400-ctrlz-during-loop-slice.md's Лог) across four states of
// an armed Loop Slice: nothing committed since arm (idle-armed / standing
// preview / mid-scrub — all coalesce to "no net geometry change, tool stays
// live") and one committed cut with the tool still active (undo reverts
// exactly that commit, tool stays live and re-armable).
//
// Drives the REAL interactive path — a synthetic Ctrl+Z (SDLK_z + KMOD_LCTRL)
// via /api/play-events, the same navHistory() chokepoint a real keypress
// reaches (source/app.d) — NOT `cmd("history.undo")`, which posts the raw
// HistoryUndo command directly and bypasses navHistory (and thus the tool's
// hasUncommittedEdit()/cancelUncommittedEdit()/survivesEditCancel() hooks)
// entirely. Mirrors the play-events idiom in tests/test_edge_slice_tool.d
// (test 17's `playKey` helper).
//
// Loop Slice's interactive arm is SELECTION-based (activationSeeds(), see
// source/tools/loop_slice_tool.d): with the seed edge already selected via
// /api/select, a single LMB down/up over the viewport arms/scrubs the tool
// without needing the mouse to actually hover the right screen pixel — so
// these tests don't depend on GPU picking resolving a specific edge (unlike
// hover-seeded interactive tests, which are documented best-effort/flaky).
//
//   1. Armed standing preview (states 1+2 — idle-armed / standing preview
//      are the same armed_==true, scrubbing_==false shape in this tool):
//      Ctrl+Z reverts to the pre-arm baseline (net no geometry change vs the
//      fresh cube, no undo-ledger entry consumed), and the tool is STILL
//      ACTIVE (/api/tool/state non-empty) and re-armable with a fresh click.
//   2. Mid-scrub (state 3, scrubbing_==true — LMB held, no button-up yet):
//      Ctrl+Z reverts the same way, tool stays active.
//   3. Post-commit, tool still active (state 4): arm -> Enter commit (+1
//      undo-ledger entry, 12v/10f) -> Ctrl+Z reverts EXACTLY that commit
//      (back to 8v/6f, -1 undo-ledger entry) and the tool is still active
//      (not dropped) — the divergence this task fixes was specific to states
//      1/2/3 (hasUncommittedEdit()==true), since a post-commit tool already
//      had hasUncommittedEdit()==false and fell through to plain
//      history.undo() untouched; this test locks in that it stays correct.
//   4. Round-trip (mirrors the captured reference's state-4 check): arm ->
//      commit -> undo -> pre-commit (8v/6f) -> re-arm (same edge, still
//      selected — MeshSnapshot restores selection) -> re-commit -> back to
//      the SAME post-commit geometry (12v/10f) as the first commit.
//   5. Regression guard: Esc-cancel is untouched by this fix (LoopSliceTool's
//      onKeyDown consumes Escape directly, before navHistory is ever
//      reached) — still cancels the live preview without dropping the tool.
//
// Standard cube fixture from /api/reset (8 verts, 6 quad faces, ±0.5 each
// axis). Seed edge (0,1) (verts (-0.5,-0.5,-0.5)-(0.5,-0.5,-0.5)) is the same
// belt edge used by tests/test_loop_slice_tool.d T1 / test_loop_slice_v2.d;
// a default (Count=1) cut on it inserts one loop: V:8->12(+4), F:6->10(+4)
// (documented in test_loop_slice_v2.d's V2 comment: V=8+4*count, F=6+4*count).

import std.net.curl;
import std.json;
import std.conv  : to;
import std.format : format;
import std.math  : sqrt;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

enum BASE = "http://localhost:8080";

// --- HTTP helpers (mirror tests/test_loop_slice_tool.d / test_edge_slice_tool.d) --

JSONValue postCmd(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}

void resetCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
}

void cmd(string s) {
    auto r = postCmd("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postCmd("/api/select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

JSONValue model()        { return getJson("/api/model"); }
JSONValue toolState()    { return getJson("/api/tool/state"); }
long undoModelDepth()    { return getJson("/api/undo/status")["modelDepth"].integer; }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faceCount"].integer; }

// /api/tool/state returns the bare `{}` sentinel iff activeTool is null
// (source/app.d: `activeTool is null ? "{}" : activeTool.toolStateJson()...`)
// — the direct, cheapest "was the tool dropped?" probe.
bool toolIsActive(JSONValue st) { return ("tool" in st.object) !is null; }

void activateLoopSlice() { cmd("tool.set mesh.loopSliceTool on"); }
void deactivateLoopSlice() { cmd("tool.set mesh.loopSliceTool off"); }

// --- geometry helpers (mirror tests/test_loop_slice_tool.d) ----------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

// The belt seed edge (-0.5,-0.5,-0.5)-(0.5,-0.5,-0.5), same as
// test_loop_slice_tool.d T1 / test_loop_slice_v2.d.
int seedEdgeIndex() {
    auto m = model();
    int va = vertAt(m, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(m, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube verts 0/1 not found");
    int ei = edgeIndex(m, va, vb);
    assert(ei >= 0, "cube edge 0-1 not found");
    return ei;
}

// --- play-events helpers (mirror tests/test_edge_slice_tool.d) -------------

void playAndSettle(string log) {
    auto r = postCmd("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished = false;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "play-events replay did not finish within 10s");
    Thread.sleep(150.msecs);   // settle (post-playback drain, per CLAUDE.md flake note)
}

void playKey(int sym, int mod = 0) {
    playAndSettle(format(`{"t":0.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                          sym, mod));
}

enum SDLK_RETURN  = 13;
enum SDLK_ESCAPE  = 27;
enum SDLK_z       = 122;
enum KMOD_LCTRL   = 64;

// A fixed viewport matching the default /api/camera pose for a freshly reset
// cube (same rect as tests/test_edge_slice_tool.d's interactive replay).
// Loop Slice's interactive arm is selection-seeded (activationSeeds()), so
// the exact click pixel doesn't need to hover any particular edge — it only
// needs to land inside a registered viewport cell.
enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

// LMB down (+ optional up) over the viewport center. First call (fresh
// selection, not yet armed) arms the tool via activationSeeds(); a second
// call while already armed re-scrubs the same seed set (see
// LoopSliceTool.onMouseButtonDown's `if (armed_)` branch).
void clickLoopSlice(bool includeUp) {
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    if (includeUp)
        log ~= "\n" ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

// ---------------------------------------------------------------------------
// 1. Armed standing preview (states 1+2): Ctrl+Z reverts to the pre-arm
//    baseline (no net geometry change, no undo-ledger entry consumed), tool
//    stays active and is re-armable with a fresh click.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    clickLoopSlice(true);   // down + up -> armed_=true, scrubbing_=false, built_=true

    auto st0 = toolState();
    assert(toolIsActive(st0), "tool must be active right after arming");
    assert(st0["armed"].type == JSONType.true_, "arm click must set armed_=true");
    assert(st0["built"].type == JSONType.true_, "arm click must materialize the default cut");

    auto armedModel = model();
    assert(vertCount(armedModel) == 12,
        "armed standing preview: expected 12 verts, got " ~ vertCount(armedModel).to!string);
    assert(faceCount(armedModel) == 10,
        "armed standing preview: expected 10 faces, got " ~ faceCount(armedModel).to!string);

    long depthBefore = undoModelDepth();

    playKey(SDLK_z, KMOD_LCTRL);   // the real interactive Ctrl+Z

    auto st1 = toolState();
    assert(toolIsActive(st1),
        "Ctrl+Z on an armed-but-uncommitted Loop Slice must NOT drop the tool (task 0400)");

    auto m1 = model();
    assert(vertCount(m1) == 8,
        "Ctrl+Z while armed (nothing committed) must revert to the pre-arm baseline (8v), got "
        ~ vertCount(m1).to!string);
    assert(faceCount(m1) == 6,
        "Ctrl+Z while armed (nothing committed) must revert to the pre-arm baseline (6f), got "
        ~ faceCount(m1).to!string);

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore,
        "cancelling an uncommitted arm must NOT touch the committed undo ledger, went "
        ~ depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    // Tool must still be genuinely usable: a fresh click re-arms it.
    clickLoopSlice(true);
    auto st2 = toolState();
    assert(toolIsActive(st2), "tool must still be active for a re-arm after Ctrl+Z");
    assert(st2["armed"].type == JSONType.true_, "a fresh click after Ctrl+Z must re-arm");
    auto m2 = model();
    assert(vertCount(m2) == 12 && faceCount(m2) == 10,
        "re-arm after Ctrl+Z must reproduce the same cut (12v/10f)");

    deactivateLoopSlice();
}

// ---------------------------------------------------------------------------
// 2. Mid-scrub (state 3): LMB held (button down, no button-up yet) ->
//    scrubbing_==true. Ctrl+Z reverts the same way as the standing-preview
//    case; tool stays active.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    clickLoopSlice(false);   // down only -> scrubbing_=true (mid-scrub)

    auto st0 = toolState();
    assert(toolIsActive(st0), "tool must be active mid-scrub");
    assert(st0["armed"].type == JSONType.true_, "mid-scrub is a subset of armed_");
    assert(st0["dragging"].type == JSONType.true_, "held LMB must report scrubbing_ via `dragging`");

    long depthBefore = undoModelDepth();

    playKey(SDLK_z, KMOD_LCTRL);

    auto st1 = toolState();
    assert(toolIsActive(st1),
        "Ctrl+Z during a mid-scrub Loop Slice must NOT drop the tool (task 0400)");

    auto m1 = model();
    assert(vertCount(m1) == 8 && faceCount(m1) == 6,
        "Ctrl+Z mid-scrub (nothing committed) must revert to the pre-arm baseline (8v/6f), got "
        ~ vertCount(m1).to!string ~ "v/" ~ faceCount(m1).to!string ~ "f");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore,
        "cancelling a mid-scrub arm must NOT touch the committed undo ledger, went "
        ~ depthBefore.to!string ~ " -> " ~ depthAfter.to!string);

    deactivateLoopSlice();
}

// ---------------------------------------------------------------------------
// 3. Post-commit, tool still active (state 4): arm -> Enter commit (+1 undo
//    entry, 12v/10f) -> Ctrl+Z reverts EXACTLY that commit (8v/6f, -1 undo
//    entry); tool stays active. (The post-commit tool already had
//    hasUncommittedEdit()==false pre-fix and fell straight through to plain
//    history.undo(), so this locks in it stays correct rather than proving a
//    regression fix.)
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    long depthBefore = undoModelDepth();

    clickLoopSlice(true);          // arm
    playKey(SDLK_RETURN);          // commit (LoopSliceTool.onKeyDown -> commitEdit())

    auto stCommitted = toolState();
    assert(toolIsActive(stCommitted), "tool must remain active immediately after commit");
    assert(stCommitted["armed"].type == JSONType.false_, "commit must clear armed_ (re-idles for the next cut)");

    auto mCommitted = model();
    assert(vertCount(mCommitted) == 12 && faceCount(mCommitted) == 10,
        "post-commit: expected 12v/10f, got " ~ vertCount(mCommitted).to!string ~ "v/"
        ~ faceCount(mCommitted).to!string ~ "f");

    long depthAfterCommit = undoModelDepth();
    assert(depthAfterCommit == depthBefore + 1,
        "commit must add exactly ONE model-undo entry, went "
        ~ depthBefore.to!string ~ " -> " ~ depthAfterCommit.to!string);

    playKey(SDLK_z, KMOD_LCTRL);   // undo the committed cut

    auto stUndone = toolState();
    assert(toolIsActive(stUndone),
        "Ctrl+Z after a committed cut must NOT drop the tool (task 0400)");

    auto mUndone = model();
    assert(vertCount(mUndone) == 8 && faceCount(mUndone) == 6,
        "Ctrl+Z must revert exactly the last commit (back to 8v/6f), got "
        ~ vertCount(mUndone).to!string ~ "v/" ~ faceCount(mUndone).to!string ~ "f");

    long depthAfterUndo = undoModelDepth();
    assert(depthAfterUndo == depthAfterCommit - 1,
        "Ctrl+Z must pop exactly one model-undo entry, went "
        ~ depthAfterCommit.to!string ~ " -> " ~ depthAfterUndo.to!string);

    deactivateLoopSlice();
}

// ---------------------------------------------------------------------------
// 4. Round-trip (mirrors the captured reference's state-4 check): arm ->
//    commit -> undo -> pre-commit (8v/6f) -> re-arm (same edge, still
//    selected because MeshSnapshot restores selection along with geometry)
//    -> re-commit -> the SAME post-commit geometry as the first commit
//    (12v/10f), with the undo ledger back at depthAfterCommit.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    long depthBefore = undoModelDepth();

    clickLoopSlice(true);
    playKey(SDLK_RETURN);
    long depthAfterCommit = undoModelDepth();
    assert(depthAfterCommit == depthBefore + 1, "first commit must add one undo entry");

    playKey(SDLK_z, KMOD_LCTRL);
    auto mPreCommit = model();
    assert(vertCount(mPreCommit) == 8 && faceCount(mPreCommit) == 6,
        "round-trip: undo must land back at the pre-commit baseline (8v/6f)");
    assert(toolIsActive(toolState()), "round-trip: tool must still be active after the undo");

    // Re-arm WITHOUT re-selecting — the seed edge's selection must have
    // survived the undo (MeshSnapshot captures/restores edgeMarks).
    clickLoopSlice(true);
    auto stRearmed = toolState();
    assert(stRearmed["armed"].type == JSONType.true_,
        "round-trip: a fresh click after undo must re-arm using the still-selected seed edge");
    auto mRearmed = model();
    assert(vertCount(mRearmed) == 12 && faceCount(mRearmed) == 10,
        "round-trip: re-arm must reproduce the same cut (12v/10f)");

    playKey(SDLK_RETURN);   // re-commit
    auto mRecommitted = model();
    assert(vertCount(mRecommitted) == 12 && faceCount(mRecommitted) == 10,
        "round-trip: re-commit must land on the SAME post-commit geometry (12v/10f)");

    long depthAfterRecommit = undoModelDepth();
    assert(depthAfterRecommit == depthAfterCommit,
        "round-trip: re-commit must restore the undo ledger to the first commit's depth, went "
        ~ depthAfterCommit.to!string ~ " (first commit) vs " ~ depthAfterRecommit.to!string ~ " (re-commit)");

    deactivateLoopSlice();
}

// ---------------------------------------------------------------------------
// 5. Regression guard: Esc-cancel is untouched by the task 0400 fix.
//    LoopSliceTool.onKeyDown() consumes SDLK_ESCAPE directly and calls
//    cancelLiveEdit() BEFORE the event ever reaches app.d's navHistory()
//    chokepoint (handleKeyDown gives the active tool first dibs on key
//    events) — so this path never touched survivesEditCancel() either
//    before or after the fix. Still cancels without dropping the tool.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    clickLoopSlice(true);
    auto stArmed = toolState();
    assert(stArmed["armed"].type == JSONType.true_, "arm click must set armed_=true");

    long depthBefore = undoModelDepth();

    playKey(SDLK_ESCAPE);

    auto stCancelled = toolState();
    assert(toolIsActive(stCancelled), "Esc-cancel must not drop the tool (unchanged pre/post 0400)");
    assert(stCancelled["armed"].type == JSONType.false_, "Esc must clear armed_");

    auto m1 = model();
    assert(vertCount(m1) == 8 && faceCount(m1) == 6, "Esc-cancel must revert to the pre-arm baseline");

    long depthAfter = undoModelDepth();
    assert(depthAfter == depthBefore, "Esc-cancel must record no undo entry");

    deactivateLoopSlice();
}
