// test_standing_preview_redo.d — task 0429: arming/scrubbing a slice-family
// STANDING preview invalidates the redo timeline (reference-captured
// semantics), so a redo pressed while a preview is up is a dead no-op — the
// preview stays byte-identical, the tool stays armed and committable. The
// control direction is pinned too: commit → undo → NO re-arm leaves the redo
// timeline alive, and the FIRST redo press re-applies the commit under the
// still-active tool.
//
// Mechanism under test (not a special navigate() branch): every write-point
// where the standing preview touches the real mesh calls
// CommandHistory.invalidateRedo() (LoopSliceTool.rebuildCut,
// EdgeSliceTool.rebuildPreview/armChain/latchFirstPoint), exactly as
// record() clears the redo stack for a committed entry — so the redo
// keystroke structurally finds an empty stack. Task 0232's former
// "first redo cancels the preview, second steps" rule is GONE (task 0429
// removed it); these are the first tests to pin the redo direction at all.
//
// Undo/redo run ONLY as synthetic keystrokes through /api/play-events —
// Ctrl+Z (sym=122, mod=64) / Ctrl+Shift+Z (sym=122, mod=65, binding
// config/shortcuts.yaml history.redo) — the navHistory()/EditSession.
// navigate() chokepoint a real keypress reaches. /api/undo|redo and
// cmd("history.undo") bypass that chokepoint (frozen contract, task 0428)
// and MUST NOT be used here.
//
// Assert channels: /api/model (vertex count + byte-identical vertices array
// across the dead presses), /api/undo/status (full-shape parse — see
// undoStatus()), /api/tool/state (`armed`, tool-active probe).
//
// Scenarios:
//   A  (loop slice, interactive arm): commit → Ctrl+Z → RE-ARM by click →
//      canRedo==false; Ctrl+Shift+Z ×2 both dead (preview byte-identical,
//      still armed); Enter still commits.
//   A' (edge slice, headless chainArm arm — the armChain write-point):
//      tool.attr edges + tool.doApply commit → Ctrl+Z → re-set edges +
//      chainArm → canRedo==false; Ctrl+Shift+Z ×2 dead; Enter commits the
//      chain.
//   B  (control, loop slice): commit → Ctrl+Z → NO re-arm → the FIRST
//      Ctrl+Shift+Z re-applies the commit (12v) under the still-active
//      tool; the second is a no-op.
//
// Fixtures: the standard /api/reset cube (8v/6f). Loop slice seed = belt
// edge (-0.5,-0.5,-0.5)-(0.5,-0.5,-0.5), cut → 12v/10f (same golden as
// tests/test_loop_slice_ctrlz.d). Edge slice chain = edge(0,1)+edge(4,5)
// (shared bottom face), cut → 10v/7f (same golden as
// tests/test_edge_slice_tool.d test 1).

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : sqrt;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

enum BASE = "http://localhost:8080";

// --- HTTP helpers (mirror tests/test_loop_slice_ctrlz.d) --------------------

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

JSONValue model()     { return getJson("/api/model"); }
JSONValue toolState() { return getJson("/api/tool/state"); }

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faceCount"].integer; }

// The byte-compare channel: the serialized vertices array. Two reads with no
// intervening mutation must serialize identically (same data, same
// serializer) — any redo press that actually moved geometry shows up here.
string vertsBlob(JSONValue m) { return m["vertices"].toString; }

// /api/tool/state returns the bare `{}` sentinel iff activeTool is null.
bool toolIsActive(JSONValue st) { return ("tool" in st.object) !is null; }

// --- /api/undo/status: full-shape parse -------------------------------------
// The endpoint returns the FULL status object built by app.d's
// undoStatusProvider: {state, lockout, canUndo, canRedo, modelDepth, uiDepth,
// canUndoModel, canUndoUi, toolLifecycleCount, canUndoLifecycle}. Parse it as
// that object — assert the fields this test relies on exist with their real
// JSON types rather than assuming a 2-field shape.
JSONValue undoStatus() {
    auto s = getJson("/api/undo/status");
    assert(s.type == JSONType.object, "/api/undo/status must be a JSON object");
    static immutable string[] boolFields =
        ["lockout", "canUndo", "canRedo", "canUndoModel", "canUndoUi"];
    static immutable string[] intFields = ["modelDepth", "uiDepth"];
    assert(("state" in s.object) !is null && s["state"].type == JSONType.string,
        "/api/undo/status missing string `state`: " ~ s.toString);
    foreach (f; boolFields)
        assert((f in s.object) !is null
               && (s[f].type == JSONType.true_ || s[f].type == JSONType.false_),
            "/api/undo/status missing bool `" ~ f ~ "`: " ~ s.toString);
    foreach (f; intFields)
        assert((f in s.object) !is null && s[f].type == JSONType.integer,
            "/api/undo/status missing integer `" ~ f ~ "`: " ~ s.toString);
    return s;
}

bool canRedoNow() { return undoStatus()["canRedo"].type == JSONType.true_; }
long modelDepth() { return undoStatus()["modelDepth"].integer; }

// --- geometry helpers (mirror tests/test_loop_slice_ctrlz.d) ----------------

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

// The belt seed edge (-0.5,-0.5,-0.5)-(0.5,-0.5,-0.5) for the loop-slice
// scenarios (same as test_loop_slice_ctrlz.d / test_loop_slice_tool.d T1).
int seedEdgeIndex() {
    auto m = model();
    int va = vertAt(m, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(m, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube belt verts not found");
    int ei = edgeIndex(m, va, vb);
    assert(ei >= 0, "cube belt edge not found");
    return ei;
}

// Edge lookup by ORIGINAL cube vertex ids (mirror tests/test_edge_slice_tool.d).
uint edgeIndexByVerts(JSONValue m, int a, int b) {
    int ei = edgeIndex(m, a, b);
    assert(ei >= 0, format("cube edge (%d,%d) not found", a, b));
    return cast(uint)ei;
}

// --- play-events helpers (mirror tests/test_loop_slice_ctrlz.d) -------------

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

enum SDLK_RETURN       = 13;
enum SDLK_z            = 122;
enum KMOD_LCTRL        = 64;
// Ctrl+Shift+Z = KMOD_LCTRL(64) | KMOD_LSHIFT(1) — the history.redo binding
// (config/shortcuts.yaml); canonFromEvent masks KMOD_CTRL/KMOD_SHIFT, so the
// left-mod composite matches (proven recipe: tests/test_falloff_refire_rs.d).
enum KMOD_CTRL_SHIFT   = 65;

// A fixed viewport matching the default /api/camera pose for a freshly reset
// cube. Loop Slice's interactive arm is selection-seeded (activationSeeds()),
// so the click pixel only needs to land inside a registered viewport cell.
enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX  = VPX + VPW / 2, CY = VPY + VPH / 2;

string viewportLine() {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                   VPX, VPY, VPW, VPH);
}

// LMB down+up over the viewport center: arms the loop-slice tool via the
// selected seed edge (fresh arm), or re-scrubs while already armed.
void clickLoopSlice() {
    string log = viewportLine() ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY) ~ "\n"
        ~ format(`{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY);
    playAndSettle(log);
}

void activateLoopSlice()   { cmd("tool.set mesh.loopSliceTool on"); }
void deactivateLoopSlice() { cmd("tool.set mesh.loopSliceTool off"); }
void activateEdgeSlice()   { cmd("tool.set mesh.edgeSliceTool on"); }
void deactivateEdgeSlice() { cmd("tool.set mesh.edgeSliceTool off"); }

// ---------------------------------------------------------------------------
// A. Loop slice, interactive re-arm: arming the standing preview kills the
//    redo timeline; a redo press while armed is a dead no-op (twice), and the
//    preview still commits.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    long depth0 = modelDepth();

    clickLoopSlice();              // arm: 12v standing preview
    playKey(SDLK_RETURN);          // commit
    auto mCommit = model();
    assert(vertCount(mCommit) == 12 && faceCount(mCommit) == 10,
        "commit golden: expected 12v/10f, got "
        ~ vertCount(mCommit).to!string ~ "v/" ~ faceCount(mCommit).to!string ~ "f");
    long depthCommit = modelDepth();
    assert(depthCommit == depth0 + 1, "commit must add one model-undo entry");

    playKey(SDLK_z, KMOD_LCTRL);   // undo the commit
    auto mUndone = model();
    assert(vertCount(mUndone) == 8 && faceCount(mUndone) == 6,
        "undo must revert the commit (8v/6f)");
    assert(canRedoNow(), "undo must leave the commit on the redo timeline");

    // RE-ARM: the seed edge's selection survived the undo (MeshSnapshot
    // restores marks — test_loop_slice_ctrlz case 4), so a fresh click arms
    // again. The arm's rebuildCut() write-point must invalidate redo.
    clickLoopSlice();
    auto stArmed = toolState();
    assert(toolIsActive(stArmed) && stArmed["armed"].type == JSONType.true_,
        "re-arm click must arm the standing preview");
    auto mArmed = model();
    assert(vertCount(mArmed) == 12,
        "re-armed preview must show the cut (12v), got " ~ vertCount(mArmed).to!string);
    assert(!canRedoNow(),
        "arming a standing preview must invalidate the redo timeline "
        ~ "(reference-captured semantics, task 0429)");

    string blobArmed = vertsBlob(mArmed);

    // TWO redo presses — both dead no-ops: geometry byte-identical, redo
    // still empty, tool still armed and active. (Task 0232's former rule —
    // first press cancels the preview, second steps — must NOT resurface.)
    foreach (press; 1 .. 3) {
        playKey(SDLK_z, KMOD_CTRL_SHIFT);
        auto mP = model();
        assert(vertCount(mP) == 12,
            format("redo press %d while armed must be a no-op (12v), got %dv",
                   press, vertCount(mP)));
        assert(vertsBlob(mP) == blobArmed,
            format("redo press %d while armed must leave the preview byte-identical", press));
        assert(!canRedoNow(),
            format("redo press %d: the redo timeline must stay dead", press));
        auto stP = toolState();
        assert(toolIsActive(stP),
            format("redo press %d must not drop the tool", press));
        assert(stP["armed"].type == JSONType.true_,
            format("redo press %d must leave the preview armed", press));
    }

    // The armed preview is still live and committable.
    playKey(SDLK_RETURN);
    auto mRecommit = model();
    assert(vertCount(mRecommit) == 12 && faceCount(mRecommit) == 10,
        "commit after the dead redo presses must land the cut (12v/10f)");
    long depthRecommit = modelDepth();
    assert(depthRecommit == depth0 + 1,
        "the re-commit must add one model-undo entry over the post-undo depth, got "
        ~ depthRecommit.to!string ~ " vs baseline " ~ depth0.to!string);
    auto stDone = toolState();
    assert(toolIsActive(stDone) && stDone["armed"].type == JSONType.false_,
        "commit must re-idle the tool (armed=false), keeping it active");

    deactivateLoopSlice();
}

// ---------------------------------------------------------------------------
// A'. Edge slice, headless chainArm re-arm — exercises the armChain()
//     write-point (bakes directly, bypassing rebuildPreview): arming kills
//     redo; two presses are dead; Enter commits the chain.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    postSelect("edges", []);       // Edges mode, empty selection (headless path)
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    activateEdgeSlice();
    long depth0 = modelDepth();

    // Headless commit: edges param + tool.doApply (ToolDoApplyCommand records).
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d}", eA, eB));
    cmd("tool.doApply");
    auto mCommit = model();
    assert(vertCount(mCommit) == 10 && faceCount(mCommit) == 7,
        "doApply golden: expected 10v/7f, got "
        ~ vertCount(mCommit).to!string ~ "v/" ~ faceCount(mCommit).to!string ~ "f");
    assert(modelDepth() == depth0 + 1, "doApply must record one model-undo entry");

    playKey(SDLK_z, KMOD_LCTRL);   // undo the commit (chain empty -> plain history.undo)
    assert(vertCount(model()) == 8, "undo must revert the doApply commit (8v)");
    assert(canRedoNow(), "undo must leave the commit on the redo timeline");

    // RE-ARM via chainArm. resyncSession() after the undo re-initialized the
    // session (edgesParam_ cleared), so re-set the edges first — the restored
    // 8v cube has the original edge indices.
    cmd(format("tool.attr mesh.edgeSliceTool edges {%d,%d}", eA, eB));
    cmd("tool.attr mesh.edgeSliceTool chainArm {1}");
    auto stArmed = toolState();
    assert(toolIsActive(stArmed) && stArmed["armed"].type == JSONType.true_,
        "chainArm must arm the standing chain preview");
    assert(stArmed["built"].type == JSONType.true_, "chainArm must bake the preview cut");
    auto mArmed = model();
    assert(vertCount(mArmed) == 10,
        "armed chain preview must show the cut (10v), got " ~ vertCount(mArmed).to!string);
    assert(!canRedoNow(),
        "the armChain write-point must invalidate the redo timeline "
        ~ "(reference-captured semantics, task 0429)");

    string blobArmed = vertsBlob(mArmed);

    foreach (press; 1 .. 3) {
        playKey(SDLK_z, KMOD_CTRL_SHIFT);
        auto mP = model();
        assert(vertCount(mP) == 10,
            format("redo press %d while chain-armed must be a no-op (10v), got %dv",
                   press, vertCount(mP)));
        assert(vertsBlob(mP) == blobArmed,
            format("redo press %d must leave the chain preview byte-identical", press));
        assert(!canRedoNow(),
            format("redo press %d: the redo timeline must stay dead", press));
        auto stP = toolState();
        assert(toolIsActive(stP) && stP["armed"].type == JSONType.true_,
            format("redo press %d must leave the chain armed", press));
    }

    // Enter commits the standing chain through the real interactive path.
    playKey(SDLK_RETURN);
    auto mRecommit = model();
    assert(vertCount(mRecommit) == 10 && faceCount(mRecommit) == 7,
        "commitChain after the dead redo presses must land the cut (10v/7f)");
    assert(modelDepth() == depth0 + 1,
        "commitChain must add one model-undo entry over the post-undo depth");
    auto stDone = toolState();
    assert(toolIsActive(stDone) && stDone["armed"].type == JSONType.false_,
        "commitChain must re-idle the tool (armed=false)");

    deactivateEdgeSlice();
}

// ---------------------------------------------------------------------------
// B. Control (no re-arm): commit → undo leaves the redo timeline ALIVE, and
//    the FIRST redo press re-applies the commit under the still-active tool;
//    the second press is a no-op. Guards against an over-eager invalidation
//    creeping into undo/resync/cancel paths (only preview WRITES may kill
//    redo).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    int ei = seedEdgeIndex();
    postSelect("edges", [ei]);
    activateLoopSlice();

    long depth0 = modelDepth();

    clickLoopSlice();
    playKey(SDLK_RETURN);          // commit: 12v/10f
    long depthCommit = modelDepth();
    assert(depthCommit == depth0 + 1, "commit must add one model-undo entry");

    playKey(SDLK_z, KMOD_LCTRL);   // undo
    assert(vertCount(model()) == 8, "undo must revert the commit (8v)");
    assert(canRedoNow(), "without a re-arm the redo timeline must stay alive");

    // FIRST redo press re-applies the commit — one press, one step; no
    // cancel-press exists in the redo direction (task 0429). This already
    // held before 0429 (the former 0232 rule only fired while armed) — the
    // scenario pins that it KEEPS holding under the write-point-invalidation
    // model.
    playKey(SDLK_z, KMOD_CTRL_SHIFT);
    auto mRedone = model();
    assert(vertCount(mRedone) == 12 && faceCount(mRedone) == 10,
        "the FIRST redo press must re-apply the commit (12v/10f), got "
        ~ vertCount(mRedone).to!string ~ "v/" ~ faceCount(mRedone).to!string ~ "f");
    auto stRedone = toolState();
    assert(toolIsActive(stRedone), "the redo step must not drop the still-active tool");
    assert(stRedone["armed"].type == JSONType.false_,
        "a redo of a committed cut must not arm a preview");
    assert(!canRedoNow(), "the single redo entry is consumed by the step");
    assert(modelDepth() == depthCommit,
        "redo must restore the commit's model-undo depth");

    // Second press: nothing left — a plain no-op.
    string blobRedone = vertsBlob(mRedone);
    playKey(SDLK_z, KMOD_CTRL_SHIFT);
    auto mAfter = model();
    assert(vertCount(mAfter) == 12 && vertsBlob(mAfter) == blobRedone,
        "a second redo press with an empty timeline must be a no-op");
    assert(!canRedoNow(), "redo timeline stays empty");
    assert(toolIsActive(toolState()), "the dead press must not drop the tool");

    deactivateLoopSlice();
}
