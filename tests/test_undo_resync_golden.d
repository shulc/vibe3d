// Golden-fixture regression LOCK for the P1 resyncSession() contract.
//
// Contract under lock (undo/redo migration Phase 1):
//   "While an interactive tool stays ACTIVE with NO open edit, Ctrl+Z pops a
//    committed history step, resyncSession() re-syncs the tool's cached
//    baseline to the post-undo mesh, and a subsequent drag operates on that
//    post-undo baseline."
//
// This closes the deeper golden follow-up that test_tool_undo_coordination.d
// §4 explicitly deferred ("commit live drag -> undo -> live drag again, assert
// the result is computed from the POST-undo baseline"). §4 only checks vertex
// counts survive the pop; here we lock the actual POST-UNDO SMOOTHED GEOMETRY.
//
// Why xfrm.smooth (a CommandWrapperTool deformer), NOT Move/Rotate/Scale:
//   CommandWrapperTool captures `baseline = meshPtr.vertices.dup` at activate()
//   and REVERTS the live mesh to that baseline on every drag motion
//   (source/tools/command_wrapper.d onMouseButtonDown / applyWithLivePipeline).
//   So if a committed history pop moves geometry beneath the still-active tool
//   and resyncSession() does NOT re-dup the baseline, the next drag restores the
//   STALE pre-undo mesh and smooths from there -> wrong geometry. Move/Rotate/
//   Scale recapture their edit baseline at mouse-DOWN, so they'd pass even with
//   a broken resyncSession (a weak test). The smooth wrapper is the witness that
//   actually exercises the resync.
//
// The sequence MUST keep a tool ACTIVE across the Ctrl+Z: if the tool were
// deactivated first, no tool is active -> resyncSession() is never called and
// the test would prove nothing. So: select set -> committed translate (the
// undo target, top of stack) -> activate xfrm.smooth (baseline = translated
// mesh) -> Ctrl+Z (tool still active, no open edit) -> free-drag -> assert.
//
// NOTE: this is a vibe3d-self-output regression lock (the golden values were
// generated empirically by running this exact sequence once and freezing the
// output) — NOT a cross-engine reference comparison. No external engine is
// involved.
//
// NEGATIVE CONTROL (verified during authoring): stubbing
// CommandWrapperTool.resyncSession() to a no-op makes this test FAIL (the
// stale translated-mesh baseline leaks through: v2 lands at ~[0.62,0.54,-0.14]
// instead of the golden [0.30,0.30,-0.30]). Reverting restores green. The test
// therefore genuinely locks the contract.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

import drag_helpers;

void main() {}

enum int SDLK_z     = 122;     // 'z'
enum int KMOD_LCTRL = 0x0040;  // 64 — handleKeyDown reads KMOD_CTRL

string BASE = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}
size_t undoLen() { return getJson("/api/history")["undo"].array.length; }
size_t redoLen() { return getJson("/api/history")["redo"].array.length; }

// A Ctrl+Z keyboard tap injected through /api/play-events. Mirrors the
// playKey idiom in test_tool_undo_coordination.d: SDL_KEYDOWN/KEYUP for 'z'
// with KMOD_LCTRL routes through handleKeyDown -> navHistory(true).
enum string KEY_LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

void playCtrlZ() {
    import std.format : format;
    string tap = format(
        `{"t":50,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        SDLK_z, KMOD_LCTRL, SDLK_z, KMOD_LCTRL);
    playAndWait(KEY_LOG_HEADER ~ "\n" ~ tap, BASE);
}

bool approx(double a, double b, double eps) { return fabs(a - b) < eps; }

unittest {
    // The frozen golden: vertex positions after the POST-undo smooth drag.
    // Generated empirically from this exact sequence on the default cube with
    // resyncSession() working. With a broken resyncSession the top verts
    // (2,3,6,7) instead reflect the translated mesh smoothed (~[0.62,0.54,...]).
    enum double TOL = 1e-4;
    immutable double[3][8] GOLDEN = [
        [-0.500000, -0.500000, -0.500000],
        [ 0.500000, -0.500000, -0.500000],
        [ 0.300000,  0.300000, -0.300000],   // v2 — smoothed from POST-undo cube
        [-0.300000,  0.300000, -0.300000],   // v3
        [-0.500000, -0.500000,  0.500000],
        [ 0.500000, -0.500000,  0.500000],
        [ 0.300000,  0.300000,  0.300000],   // v6
        [-0.300000,  0.300000,  0.300000],   // v7
    ];

    // 1. Fresh default cube, empty history stack.
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    assert(undoLen() == 0, "history.clear did not empty the undo stack");

    // 2. Select the top-face vertices and commit a translate of that set. This
    //    is the undo target; it sits at the TOP of the stack (the /api/select
    //    that precedes it is its own entry underneath). Translate keeps the
    //    vertex count constant, so the post-undo and pre-undo baselines are the
    //    same length — the stale-baseline failure shows up as different
    //    geometry, not a crash.
    auto sel = postJson("/api/select", `{"mode":"vertices","indices":[2,3,6,7]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    auto xf = postJson("/api/transform", `{"kind":"translate","delta":[0.4,0.3,0.2]}`);
    assert(xf["status"].str == "ok", "translate failed: " ~ xf.toString);

    size_t undoAfterEdit = undoLen();
    assert(undoAfterEdit >= 1, "translate did not record a history entry");
    auto pre = getJson("/api/model")["vertices"].array;
    // Sanity: the committed edit actually moved the selected top verts.
    assert(approx(pre[6].array[1].floating, 0.8, 1e-6),
        "translate did not move v6 (expected y=0.8): " ~ pre[6].toString);

    // 3. Activate xfrm.smooth — tool now ACTIVE on the MAIN thread (tool.set
    //    runs through the command bridge). CommandWrapperTool.activate() dups
    //    its baseline from the CURRENT (translated) mesh. No open live edit
    //    right after activate (dirty==false) -> hasUncommittedEdit() is false,
    //    so the upcoming Ctrl+Z takes the pop+resync branch, not the cancel
    //    branch. The selection [2,3,6,7] is unchanged, so smooth will act on it.
    auto act = postJson("/api/command", "tool.set xfrm.smooth");
    assert(act["status"].str == "ok" || act["status"].str == "success",
        "tool.set xfrm.smooth failed: " ~ act.toString);

    // 4. Ctrl+Z under the active tool: navHistory(true) -> history.undo() pops
    //    the translate AND drives activeTool.resyncSession(), which re-dups the
    //    smooth baseline from the now-current (un-translated) mesh.
    playCtrlZ();
    assert(undoLen() == undoAfterEdit - 1,
        "Ctrl+Z under an active tool did not pop one undo entry (undo="
        ~ undoLen().to!string ~ " expected " ~ (undoAfterEdit - 1).to!string ~ ")");
    assert(redoLen() >= 1, "Ctrl+Z under an active tool did not push a redo entry");
    auto undone = getJson("/api/model")["vertices"].array;
    // The translate is undone: the top verts are back at the cube corners.
    assert(approx(undone[6].array[1].floating, 0.5, 1e-6),
        "Ctrl+Z did not restore the pre-translate geometry (v6.y): "
        ~ undone[6].toString);

    // 5. Free-drag the smooth tool (LMB-down + motion + up anywhere in the
    //    viewport — the smooth wrapper's drag is a free screen drag, NOT gizmo-
    //    handle-pixel gated). Click at the projected mesh center and drag +120 px
    //    in X -> strength clamp(120*0.005)=0.6, iterations 1.
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float cx, cy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, cx, cy),
        "mesh center projects off-camera");
    int x0 = cast(int)cx, y0 = cast(int)cy;
    int x1 = x0 + 120,    y1 = y0;
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log, BASE);

    // 6. Assert the resulting geometry matches the frozen golden — i.e. the
    //    smooth ran against the POST-undo baseline, not the stale translated one.
    auto vfinal = getJson("/api/model")["vertices"].array;
    assert(vfinal.length == GOLDEN.length,
        "vertex count changed: " ~ vfinal.length.to!string);
    foreach (i; 0 .. GOLDEN.length) {
        auto v = vfinal[i].array;
        foreach (k; 0 .. 3) {
            assert(approx(v[k].floating, GOLDEN[i][k], TOL),
                "vertex " ~ i.to!string ~ " component " ~ k.to!string
                ~ " = " ~ v[k].floating.to!string
                ~ " expected " ~ GOLDEN[i][k].to!string
                ~ " (post-undo smooth diverged from the golden — resyncSession "
                ~ "may not be re-syncing the deform baseline to the post-undo mesh)");
        }
    }

    // Deactivate so we don't leak an active xfrm.smooth into later tests
    // (deactivate() no-ops: no dirty edit to commit after a fresh drag-up... the
    // drag DID set dirty, so this commits the smooth as one history entry, which
    // is fine — it's torn down with the worker).
    postJson("/api/command", "tool.set xfrm.smooth off");
}
