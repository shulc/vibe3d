// A DOCUMENT REPLACE under a LIVE tool gesture must not let the dying gesture
// write into the replacement (task 3130, backlog 2960).
//
// WHAT THIS PINS. `SceneReset.applyImpl` writes the new primitive INTO the
// surviving layer (`*mesh = makeCube()`) and only fires `onResetTool()` — the
// tool drop — 24 lines later. For a session tool the drop IS the commit point
// (slice_tool.d: "this is the ONLY commit point (never mouse-up)"), so the
// dying gesture ran its kernel against a document that had already replaced
// the one it was armed on. Measured 2026-08-28 against the shipped binary:
//
//     /api/reset                                  -> v=8  e=12 f=6
//     tool.set  mesh.mirrorTool
//     tool.attr mesh.mirrorTool mergeVerts false  (engages the tool)
//     /api/reset                                  -> v=16 e=24 f=12   <-- !
//     /api/history  undo: [..., "Mirror", "Reset to cube"]            <-- !
//
// A "fresh" cube of sixteen vertices, and an undo entry for an edit nobody
// confirmed, filed UNDER the reset's own entry.
//
// WHY IT IS A SUITE TEST AND NOT A UNIT ONE. `run_test.d` shares one
// `vibe3d --test` per worker, so the contamination is DIRECTIONAL: a stand
// that dies mid-gesture — i.e. a RED one — hands its successor a scene the
// successor never asked for, and the successor then fails for a reason that
// has nothing to do with what it tests. The first red manufactures a second
// red with a different cause, which is the one defect shape this project names
// as the most expensive. Reproducing that needs two stands in one process,
// which is what blocks 2 and 3 below are.
//
// THE FIX HAS TWO LAYERS and this file exercises both (source/tool_disarm.d):
// the gesture is CANCELLED (so the drop is silent — no kernel run, no history
// entry), and then the tool is DROPPED, BOTH before the geometry is replaced
// (so a tool whose cancel does not clear its commit guard still commits into
// the mesh it was actually built against, never into the replacement).
//
// THE ANTI-VACUITY CONTROL, and it is block 1. Every assertion here is of the
// form "the foreign edit did NOT land" — which an arm that never engaged
// satisfies for free, on broken code and fixed code alike. So block 1 drives
// the IDENTICAL gesture with the mesh INTACT and requires that it DOES land
// (8 -> 16 vertices, a "Mirror" entry). Without that block the rest of this
// file would be green over a tool that does nothing.
//
// WHY `mergeVerts false`. The mirror plane defaults through the cube's own
// centre, so with welding ON the copy lands on top of the original and the
// vertex count does not move (8 -> 8; only the face count doubles). Turning
// welding off makes the commit UNAMBIGUOUS in the count the card reports:
// 8 -> 16 vertices. It also engages the tool — `MirrorTool.onParamChanged`
// sets `engaged = true` — which is why no drag is needed and this file is
// deterministic without an event log.

import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.json;
import std.math : fabs;
import std.net.curl : get, post;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera,
                       // projectToWindow, buildDragLog, playAndWait

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.mirrorTool";

/// Two coaxial unit squares — the `/api/load-mesh` operand for block 5.
/// 8 vertices, 2 faces: no count it carries can be confused with a cube's
/// 8/12/6 or with a mirrored cube's 16/24/12.
enum string kTwoCaps = `{
    "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0,0,1],[1,0,1],[1,1,1],[0,1,1]],
    "faces":[[0,1,2,3],[4,5,6,7]]
}`;

JSONValue getJson(string path) { return parseJSON(cast(string) get(BASE ~ path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

struct Counts {
    size_t v, e, f;
    string toString() const {
        return v.to!string ~ "v/" ~ e.to!string ~ "e/" ~ f.to!string ~ "f";
    }
}

Counts counts() {
    auto j = getJson("/api/model");
    return Counts(j["vertices"].array.length,
                  j["edges"].array.length,
                  j["faces"].array.length);
}

string[] undoLabels() {
    return getJson("/api/history")["undo"].array.map!(e => e["label"].str).array;
}

/// `/api/reset` to a cube, asserting the route itself answered.
void resetToCube(string why) {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok",
        "/api/reset refused (" ~ why ~ "): " ~ r.toString);
}

/// Arm the mirror tool and ENGAGE it, leaving a live gesture standing.
/// Deliberately does not drop it — every block below decides for itself what
/// ends the session.
void armEngagedMirror() {
    cmd("tool.set " ~ TOOL);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
}

enum Counts kCube   = Counts(8, 12, 6);
enum Counts kMirror = Counts(16, 24, 12);

/// Post-`/api/play-events` drain guard (CLAUDE.md flake note #3: `/status`
/// reports `finished` once events are POSTED to the SDL queue, not processed).
/// Only block 6 replays events; the mirror blocks are command-only and need it
/// nowhere.
void settle() {
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(180));
}

/// Screen pixel for a world point on the active viewport (block 6).
void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    assert(projectToWindow(w, vp, fx, fy),
        "world point projected off-screen — camera assumptions broke");
    px = cast(int)(fx + 0.5f);
    py = cast(int)(fy + 0.5f);
}

// ---------------------------------------------------------------------------
// 1. ANTI-VACUITY CONTROL — the gesture has a REAL drive.
//
//    Same arm, same engage, but the mesh is still under the tool when the
//    session ends. The commit MUST land. If this block ever goes green while
//    reporting a cube, every "nothing happened" assertion in blocks 2-5 is
//    satisfied by an empty gesture and this file measures nothing.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 1 baseline");
    cmd("history.clear");
    assert(counts() == kCube,
        "block 1 baseline is not a plain cube: got " ~ counts().toString);

    armEngagedMirror();
    assert(counts() == kCube,
        "MirrorTool must not touch the document mesh DURING interaction "
        ~ "(it previews into its own mesh); got " ~ counts().toString);

    // The ordinary end of a session: drop the tool with its mesh intact.
    cmd("tool.set " ~ TOOL ~ " off");

    assert(counts() == kMirror,
        "POSITIVE CONTROL FAILED: dropping an engaged mesh.mirrorTool over an "
        ~ "INTACT cube must commit the mirror (" ~ kMirror.toString ~ "), got "
        ~ counts().toString ~ ". Until this holds, the negative assertions in "
        ~ "blocks 2-5 are vacuous — they would pass over a gesture that never "
        ~ "engaged.");
    assert(undoLabels() == ["Mirror"],
        "POSITIVE CONTROL FAILED: the intact-mesh drop must record exactly one "
        ~ "\"Mirror\" entry, got " ~ undoLabels().to!string);
}

// ---------------------------------------------------------------------------
// 2. THE POISONING STAND. Leaves a tool ARMED and ENGAGED and returns — which
//    is exactly what a stand that dies mid-gesture leaves behind, and what
//    block 3 must survive.
//
//    It asserts nothing about the reset on purpose: its whole job is to set
//    block 3's initial condition. Splitting it out of block 3 is what makes
//    the pair reproduce the CROSS-STAND shape (two separate unittest bodies,
//    one shared `--test` process) rather than a within-one-block sequence,
//    which block 4 covers separately.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 2 baseline");
    cmd("history.clear");
    assert(counts() == kCube,
        "block 2 baseline is not a plain cube: got " ~ counts().toString);
    armEngagedMirror();
    // …and that is all. The tool is left standing on purpose.
}

// ---------------------------------------------------------------------------
// 3. THE WITNESS — a stand that must be INDEPENDENT of the one before it.
//
//    This is an ordinary stand opening: reset, clear history, read the scene.
//    It does NOT disarm anything first, because a stand should not have to
//    know what its predecessor left behind — that knowledge is precisely the
//    workaround this task removes (nine files carried it; see the task card).
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 3 — the independent stand");
    // READ THE HISTORY BEFORE CLEARING IT. The obvious spelling of an ordinary
    // stand opening is `reset; history.clear;` and then assert an empty stack —
    // which is a check that CANNOT come out differently: `history.clear` wipes
    // the stray entry the mutation produces just as thoroughly as the fix
    // prevents it, so that assertion is green on broken code. Block 2 left the
    // stack empty, so what stands here is exactly what THIS reset recorded.
    auto recorded = undoLabels();
    cmd("history.clear");

    auto c = counts();
    assert(c == kCube,
        "CROSS-STAND CONTAMINATION: this stand opened with `/api/reset` and "
        ~ "must therefore stand on a plain cube (" ~ kCube.toString ~ "), but "
        ~ "it reads " ~ c.toString ~ ". The previous block left a "
        ~ TOOL ~ " gesture engaged, and the reset let that dying gesture "
        ~ "commit INTO the cube it had just created: " ~ kMirror.toString
        ~ " is a cube plus its unwelded mirror image. The geometry in this "
        ~ "scene belongs to the stand before this one. See "
        ~ "source/tool_disarm.d — the tool must be cancelled and dropped "
        ~ "BEFORE the document is replaced, not 24 lines after.");

    assert(recorded == ["Reset to "],
        "CROSS-STAND CONTAMINATION: this stand's opening reset must record "
        ~ "ONLY itself, but the stack it left is " ~ recorded.to!string
        ~ ". A \"Mirror\" entry here is the PREVIOUS stand's abandoned gesture, "
        ~ "committed and recorded by the very reset that was supposed to "
        ~ "discard it — and it is filed UNDER the reset, so a single undo "
        ~ "would not even reveal it.");
}

// ---------------------------------------------------------------------------
// 4. THE SAME DEFECT WITHIN ONE BLOCK — a reset fired while THIS block's own
//    gesture is live. Same law, no reliance on block ordering, and it is the
//    form a user meets: File -> New with a tool up.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 4 baseline");
    cmd("history.clear");
    armEngagedMirror();

    resetToCube("block 4 — with a live gesture standing");

    auto c = counts();
    assert(c == kCube,
        "a reset fired under a live " ~ TOOL ~ " gesture must hand back a "
        ~ "plain cube (" ~ kCube.toString ~ "), got " ~ c.toString
        ~ " — the abandoned gesture committed into the scene the reset had "
        ~ "just built.");
    assert(undoLabels() == ["Reset to "],
        "a reset under a live gesture must record ONLY itself; got "
        ~ undoLabels().to!string ~ ". A \"Mirror\" entry here is an undo step "
        ~ "for an edit the user never confirmed, filed underneath the reset.");

    // …and the tool really is gone, not merely silent: `tool.attr` names the
    // active tool in its refusal, so this reads the app's own answer rather
    // than inferring "dropped" from the absence of an edit.
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(r["status"].str == "error",
        "after a reset there must be no active tool, but `tool.attr " ~ TOOL
        ~ "` was accepted: " ~ r.toString);
    assert(r["message"].str.canFind("active tool is ''"),
        "the refusal must say the active tool is empty (i.e. the reset dropped "
        ~ "it), got: " ~ r["message"].str);
}

// ---------------------------------------------------------------------------
// 5. THE OTHER DOCUMENT-REPLACING COMMAND — `scene.loadMesh` (`/api/load-mesh`)
//    has the identical shape: `*mesh = m` first, `onResetTool()` after. One
//    seam, two callers; this block is why the fix is a shared seam and not a
//    line inside `SceneReset`.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 5 baseline");
    cmd("history.clear");
    armEngagedMirror();

    auto r = postJson("/api/load-mesh", kTwoCaps);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);

    auto c = counts();
    assert(c == Counts(8, 8, 2),
        "a raw load under a live " ~ TOOL ~ " gesture must hand back exactly "
        ~ "the loaded mesh (8v/8e/2f — two coaxial squares), got "
        ~ c.toString ~ ". The abandoned gesture mirrored the freshly loaded "
        ~ "geometry.");
    assert(!undoLabels().canFind("Mirror"),
        "a raw load under a live gesture must record no \"Mirror\" entry; got "
        ~ undoLabels().to!string);
}

// ---------------------------------------------------------------------------
// 6. THE LAYER-1 WITNESS — a tool whose gesture CANNOT be cancelled.
//
//    Blocks 1-5 all ride `mesh.mirrorTool`, whose `cancelUncommittedEdit()`
//    clears the exact field its `deactivate()` commit tests. That is layer 2,
//    and a fix built on layer 2 alone would be green in every block above and
//    still wrong: a census of all 35 `deactivate()` overrides found FIVE that
//    write and whose cancel does NOT clear their commit guard —
//    `slice/slice_tool.d`, `edit/topology_pen/tool.d`, `transform/rotate.d`,
//    `transform/scale.d` and `edit/edge_extend.d`'s embedded transform. Four of
//    those five never override the pair at all, so `hasUncommittedEdit()`
//    answers the base `false` and the cancel loop is a NO-OP for them.
//
//    `mesh.sliceTool` is the drivable one, and it is the sharpest of the five
//    because it writes to the DOCUMENT mesh during the drag (12v/10f standing
//    before any commit) rather than into a private preview. What protects the
//    fresh scene here is layer 1 alone: the tool is dropped while its own mesh
//    is still current.
//
//    THE UNDO ENTRY IS PART OF THE LAW, not an accident. Layer 1 lets this
//    tool's commit run against the mesh it was armed on, so the session bakes
//    its usual single entry — and that entry is what EXPLAINS the geometry the
//    reset then snapshots. Before this task the same reset left a 12v/10f mesh
//    in the undo image with NO entry accounting for the cut (`SliceTool`'s own
//    `armedKey_` guard, task 2880, silently refused the commit once the mesh
//    had been swapped). "Silent" there meant an un-undoable edit inside the
//    reset's own snapshot; asserting the entry HERE is what stops a future
//    change from calling that silence an improvement.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 6 baseline");
    cmd("history.clear");
    assert(counts() == kCube,
        "block 6 baseline is not a plain cube: got " ~ counts().toString);

    cmd("tool.set mesh.sliceTool on");
    settle();

    // The tool's own auto construction plane (pickMostFacingPlane): the world
    // axis whose |dot(camBack)| is largest is the normal; the other two span
    // it, tie-broken X>Y>Z. Copied from `test_slice_session.d`, which is where
    // this drag recipe is derived and explained.
    auto vp = viewportFromCamera(fetchCamera(BASE));
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    immutable float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    Vec3 ax1, ax2;
    if (ax >= ay && ax >= az)      { ax1 = Vec3(0,1,0); ax2 = Vec3(0,0,1); }
    else if (ay >= ax && ay >= az) { ax1 = Vec3(1,0,0); ax2 = Vec3(0,0,1); }
    else                           { ax1 = Vec3(1,0,0); ax2 = Vec3(0,1,0); }

    int a1x, a1y, b1x, b1y;
    scr(ax2 * (-0.6f), vp, a1x, a1y);
    scr(ax2 * ( 0.6f), vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height,
                             a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();

    // THE ANTI-VACUITY CONTROL for this block: the cut is really standing on
    // the DOCUMENT mesh, and nothing has committed yet. Without this the reset
    // assertion below would be satisfied by a drag that never engaged.
    assert(counts() == Counts(12, 20, 10),
        "the slice drag must leave ONE live mid-plane cut standing on the "
        ~ "document mesh (12v/20e/10f), got " ~ counts().toString
        ~ " — without a live cut this block asserts nothing.");
    assert(undoLabels().length == 0,
        "the slice session must not have committed at mouse-up (it bakes on "
        ~ "tool-drop); undo holds " ~ undoLabels().to!string);

    resetToCube("block 6 — with a live slice standing");

    assert(counts() == kCube,
        "LAYER 1 FAILED: a reset under a live `mesh.sliceTool` cut must hand "
        ~ "back a plain cube (" ~ kCube.toString ~ "), got " ~ counts().toString
        ~ ". This tool does not implement the cancel pair, so the cancel loop "
        ~ "is a no-op for it — only the unconditional DROP-BEFORE-REPLACE "
        ~ "keeps its session away from the scene the reset just built.");
    assert(undoLabels() == ["Slice", "Reset to "],
        "the slice session must bake its one entry against the mesh it was "
        ~ "armed on, BEFORE the reset's own entry; got "
        ~ undoLabels().to!string ~ ". Order matters: \"Slice\" after \"Reset "
        ~ "to \" would mean the cut was baked into the replacement.");
}

// ---------------------------------------------------------------------------
// 7. THE `tool.set` LAW, PINNED ON PURPOSE — a tool SWITCH with the mesh
//    INTACT still COMMITS the outgoing gesture.
//
//    This is not an oversight left standing: commit-on-drop is the designed
//    session law of this editor (`deactivate()` is the documented single
//    commit point, never mouse-up), and a switch is a drop. Task 3130's fix
//    deliberately changes nothing here — it narrows the repair to the paths
//    that REPLACE the mesh, where the commit lands somewhere the gesture was
//    never built for. Pinned so that a later reading of "the switch should
//    cancel" has to argue with a red test instead of a silent edit.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 7 baseline");
    cmd("history.clear");
    armEngagedMirror();

    // Switch to a DIFFERENT tool. No reset, no load: the mesh under the
    // outgoing gesture is exactly the mesh it was armed on.
    cmd("tool.set mesh.clone");

    assert(counts() == kMirror,
        "a tool SWITCH over an intact mesh must still commit the outgoing "
        ~ "gesture (" ~ kMirror.toString ~ "), got " ~ counts().toString
        ~ ". Commit-on-drop is the session law; task 3130 narrowed the repair "
        ~ "to document-REPLACING paths only, and this block is what says so.");
    assert(undoLabels() == ["Mirror"],
        "the switch must record the outgoing tool's commit; got "
        ~ undoLabels().to!string);

    cmd("tool.set mesh.clone off");
}

// ---------------------------------------------------------------------------
// 8. THE GUARD MUST NOT REDDEN ON CORRECT USE. A perfectly ordinary reset,
//    with nothing armed, must be answered — not refused, not turned into a
//    no-op, and not given an extra history entry by the disarm seam it now
//    crosses. A guard that fires on legal input is worth no more than none.
//
//    Last on purpose: it leaves the shared `--test` instance on a plain cube
//    with no tool up, so the next test in this worker's slice inherits exactly
//    what it would inherit from a fresh process.
// ---------------------------------------------------------------------------
unittest {
    resetToCube("block 8 — no tool armed");
    cmd("history.clear");
    assert(counts() == kCube,
        "a plain reset must produce a cube, got " ~ counts().toString);

    resetToCube("block 8 — second plain reset");
    assert(counts() == kCube,
        "a second plain reset must produce a cube, got " ~ counts().toString);
    assert(undoLabels() == ["Reset to "],
        "a reset with nothing armed must record exactly one entry — its own; "
        ~ "got " ~ undoLabels().to!string ~ ". An extra entry would mean the "
        ~ "disarm seam records something on a path where there was nothing to "
        ~ "disarm.");
}
