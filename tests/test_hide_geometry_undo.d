// Hide Geometry — Stages 6 + 7 (doc/hide_geometry_plan.md §6 S6/S7, §7):
// the UNDO / SNAPSHOT / INVARIANT rows, plus the one end-to-end gesture the
// earlier stages could not reach.
//
// The four earlier hide test files each own a stage's own surface — marks
// (test_hide_geometry.d), buffers (…_draw.d), picking (…_pick.d), operands
// (…_ops.d). What none of them covers, and what this file is for:
//
//   T-R1    §3.1's `Select ∧ Hide = ∅` reached through the SELECT writer,
//           not through a pick — the route a script or a replayed delta takes.
//   T-R3b   the symmetric-selection auto-add cannot reach a hidden mirror.
//   T-OBJ5  the derived vertex/edge planes are correct after an undo that
//           lands INSIDE a hidden state (R13's direction, the one a
//           hide-then-undo-then-assert-nothing-hidden test cannot see).
//   T-S6a   Hide is kept LIVE across `restoreGeometryKeepSelection`, on the
//           production path (a tool apply + Ctrl+Z).
//   T-S7a   AN END-TO-END GIZMO DRAG WITH SOMETHING HIDDEN. Stage 5 asserted
//           the operand numbers at the unit level and through `mesh.quantize`
//           over HTTP, and said so in its own header; the interactive drag —
//           the way a user actually reaches the whole-mesh operand set — had
//           no coverage anywhere. This file closes it with a replayed SDL
//           event log against the real move gizmo.
//
// ---------------------------------------------------------------------------
// FIXTURE RULE, inherited from the earlier stages and worth restating
// ---------------------------------------------------------------------------
// Where a row needs a hidden VERTEX, it hides the three cube faces meeting
// corner v0, so v0 — and ONLY v0 — derives hidden. Its neighbours v1/v3/v4
// keep a visible incident face and stay VISIBLE. A fixture whose hidden
// element is surrounded by other hidden elements lets a pre-existing check do
// the new code's work and reads the right number for the wrong reason.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;
import std.algorithm : sort, canFind;
import std.format : format;
import std.file : exists, remove, getSize;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok",
        "/api/command `" ~ script ~ "` failed: " ~ r.toString);
}
void cmdId(string id) { cmd(`{"id":"` ~ id ~ `"}`); }
void cmdParams(string id, string params) {
    cmd(`{"id":"` ~ id ~ `","params":` ~ params ~ `}`);
}

void resetCube() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmdId("history.clear");
}

JSONValue model() { return getJson("/api/model"); }

/// Select `indices` in `mode`, switching the geometry type first — the
/// sequence every hide test in this family uses.
void selectMode(string mode, int[] indices) {
    immutable string tok = mode == "polygons" ? "polygon"
                         : mode == "edges"    ? "edge" : "vertex";
    cmd("select.typeFrom " ~ tok);
    string idx = "[";
    foreach (i, v; indices) { if (i) idx ~= ","; idx ~= v.to!string; }
    idx ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idx ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

int[] selectedList(string key) {
    int[] r;
    foreach (v; getJson("/api/selection")[key].array) r ~= cast(int)v.integer;
    r.sort();
    return r;
}

bool[] hiddenPlane(string key) {
    bool[] r;
    foreach (b; model()[key].array) r ~= b.type == JSONType.true_;
    return r;
}
int[] hiddenList(string key) {
    int[] r;
    foreach (i, b; model()[key].array) if (b.type == JSONType.true_) r ~= cast(int)i;
    return r;
}
int countHidden(string key) { return cast(int)hiddenList(key).length; }

double[3][] verts() {
    double[3][] r;
    foreach (v; model()["vertices"].array) {
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}

string fmtv(double[3] v) {
    return format("(%.6f, %.6f, %.6f)", v[0], v[1], v[2]);
}

/// Hide exactly the three faces meeting cube corner v0, leaving v0 — and only
/// v0 — derived hidden. Asserted, not assumed: every row below reads a number
/// that is meaningless if the fixture did not land.
void hideCornerV0() {
    selectMode("vertices", [0]);
    cmdId("mesh.hide");
    auto vh = hiddenList("vertexHidden");
    assert(vh == [0],
        "fixture: hiding from v0 must derive EXACTLY vertex 0 hidden, got "
        ~ vh.to!string);
    assert(countHidden("faceHidden") == 3,
        "fixture: v0 has three incident cube faces, got "
        ~ countHidden("faceHidden").to!string ~ " hidden");
}

// ---------------------------------------------------------------------------
// T-R1 — `Select ∧ Hide = ∅` through the SELECT writer (§3.1)
// ---------------------------------------------------------------------------
//
// Discriminator, and it is the reason the request carries TWO indices: a call
// asking for one hidden face and one visible face separates "the writer
// filtered the hidden one" from "the call failed" and from "nothing is
// selectable". A request naming only the hidden face reads an empty selection
// under all three.
//
// The control row runs the identical request with nothing hidden and reads
// [2, 3] — without it, a build where /api/select silently rejected the whole
// list would pass the hidden row for the wrong reason.

unittest {
    resetCube();

    // CONTROL — nothing hidden. Both indices are valid and both land.
    selectMode("polygons", [2, 3]);
    assert(selectedList("selectedFaces") == [2, 3],
        "control: with nothing hidden, /api/select must select BOTH faces, got "
        ~ selectedList("selectedFaces").to!string
        ~ " — without this row the hidden row below cannot tell a filter from "
        ~ "a failed call");

    // Hide face 2. On a closed cube a single face hide derives no hidden
    // vertex, so face 3 stays wholly reachable.
    resetCube();
    selectMode("polygons", [2]);
    cmdId("mesh.hide");
    assert(hiddenList("faceHidden") == [2],
        "fixture: exactly face 2 hidden, got " ~ hiddenList("faceHidden").to!string);
    assert(countHidden("vertexHidden") == 0,
        "fixture: one cube face hide derives no hidden vertex");

    // The measurement.
    selectMode("polygons", [2, 3]);
    auto got = selectedList("selectedFaces");
    assert(got == [3],
        "T-R1: a select request naming a hidden face and a visible one must "
        ~ "select ONLY the visible one, got " ~ got.to!string
        ~ " — [2, 3] means the invariant lives only at pick time and any "
        ~ "scripted / replayed selection can still land on hidden geometry");
}

// ---------------------------------------------------------------------------
// T-R3b — the symmetric-selection auto-add cannot select a hidden mirror
// ---------------------------------------------------------------------------
//
// NO CODE CHANGE backs this row: `commands/mesh/select.d`'s auto-add goes
// through `mesh.selectVertex`, which is a §3.1 writer, so the mirror is
// refused by the same guard T-R1 measures. It is pinned because the auto-add
// is the one selection path that selects an element the user never named — if
// it is ever moved onto a raw mark write (the shape `patchSelection` already
// has, §4.1c′) the refusal disappears silently.
//
// ORDERING NOTE, and it is load-bearing: the hide runs BEFORE symmetry is
// enabled. With symmetry already on, selecting v0 to hide from would auto-add
// v1 and the hide would take BOTH corners — leaving no visible partner to
// drive the measurement with.
//
// The control row is what makes the hidden row mean anything: it proves the
// auto-add is live in this fixture AND pins which vertex is v1's mirror.
// Without it the hidden row's [1] would also pass a build with symmetry off.

unittest {
    // CONTROL — symmetry on, nothing hidden. Selecting v1 must auto-add v0.
    resetCube();
    cmd("tool.pipe.attr symmetry enabled true");
    selectMode("vertices", [1]);
    auto ctrl = selectedList("selectedVertices");
    assert(ctrl == [0, 1],
        "control: with symmetry on and nothing hidden, selecting v1 must "
        ~ "auto-add its X-mirror v0, got " ~ ctrl.to!string
        ~ " — if this row does not read [0, 1] the fixture has no live "
        ~ "auto-add and the hidden row below measures nothing");
    cmd("tool.pipe.attr symmetry enabled false");

    // MEASUREMENT — hide v0 first, THEN enable symmetry, then select v1.
    resetCube();
    hideCornerV0();
    cmd("tool.pipe.attr symmetry enabled true");
    selectMode("vertices", [1]);
    auto got = selectedList("selectedVertices");
    assert(got == [1],
        "T-R3b: the symmetry auto-add must not select the HIDDEN mirror v0, "
        ~ "got " ~ got.to!string ~ " — [0, 1] means the auto-add reaches "
        ~ "geometry the user cannot see, and a following drag would deform it");
    cmd("tool.pipe.attr symmetry enabled false");
}

// ---------------------------------------------------------------------------
// T-OBJ5 — the derived planes are correct after an undo that lands INSIDE a
// hidden state (R13)
// ---------------------------------------------------------------------------
//
// The direction is the whole point. Out of hidden (hide, undo, assert nothing
// hidden) is the easy direction and passes a broken build: whatever restores
// the authoritative face plane also, by arithmetic, leaves the derived planes
// looking empty. INTO hidden is the direction that needs the derived planes to
// come back, and it is the one R13 says goes stale the moment the Hide feature
// owns a field outside the three marks arrays.
//
// Row 1 reaches it through `mesh.unhideAll` + undo, which is a REVERT — the
// path that restores all three planes wholesale, through no Hide writer at
// all. Row 2 reaches it through hide + undo + redo, which is a re-APPLY.
// The two are different code and only one of them re-derives.
//
// The wrong implementation this row is built against, and it is the tempting
// one because §4's own table says the derived planes self-heal: a revert()
// that restores ONLY the authoritative `faceMarks` and trusts
// refreshHiddenDerived() to rebuild the rest. Undoing the unhide then puts the
// face bits back while `vertexMarks` stays as the unhide left it — and nothing
// on the revert path re-derives. Observed under that break: faceHidden count
// 3, vertexHidden count 0.

unittest { // row 1 — undo of an UNHIDE lands back inside a hidden state
    resetCube();
    hideCornerV0();
    auto hiddenFaces = hiddenList("faceHidden");

    cmdId("mesh.unhideAll");
    assert(countHidden("faceHidden") == 0 && countHidden("vertexHidden") == 0
        && countHidden("edgeHidden") == 0,
        "setup: unhideAll must clear all three planes");

    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);

    // The authoritative plane is back…
    assert(hiddenList("faceHidden") == hiddenFaces,
        "T-OBJ5 row 1: undoing the unhide must restore the SAME three faces, got "
        ~ hiddenList("faceHidden").to!string ~ " vs " ~ hiddenFaces.to!string);
    // …and so is everything derived from it. This is the assertion.
    assert(hiddenList("vertexHidden") == [0],
        "T-OBJ5 row 1: after an undo that lands INSIDE a hidden state the "
        ~ "DERIVED vertex plane must be correct, got "
        ~ hiddenList("vertexHidden").to!string
        ~ " — an empty list means the restore put the face bits back and left "
        ~ "the derived planes as the unhide left them");
    assert(countHidden("edgeHidden") == 3,
        "T-OBJ5 row 1: v0's three incident edges derive hidden, got "
        ~ countHidden("edgeHidden").to!string);

    // And the derived plane is not merely reported — it is enforced. v0 must
    // be unselectable, which reads through isVertexHidden and nothing else.
    selectMode("vertices", [0]);
    assert(selectedList("selectedVertices").length == 0,
        "T-OBJ5 row 1: the restored-hidden vertex must not be selectable, got "
        ~ selectedList("selectedVertices").to!string);
}

unittest { // row 2 — REDO of a hide lands back inside a hidden state
    resetCube();
    hideCornerV0();
    auto hiddenFaces = hiddenList("faceHidden");

    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);
    assert(countHidden("faceHidden") == 0 && countHidden("vertexHidden") == 0,
        "setup: the undo must leave nothing hidden");

    auto r = postJson("/api/command", commandBody("history.redo"));
    assert(r["status"].str == "ok", "/api/redo failed: " ~ r.toString);

    assert(hiddenList("faceHidden") == hiddenFaces,
        "T-OBJ5 row 2: the redo must restore the same three faces, got "
        ~ hiddenList("faceHidden").to!string);
    assert(hiddenList("vertexHidden") == [0],
        "T-OBJ5 row 2: after a redo INTO a hidden state the derived vertex "
        ~ "plane must be correct, got " ~ hiddenList("vertexHidden").to!string);
}

// ---------------------------------------------------------------------------
// T-S6a — Hide is kept LIVE across `restoreGeometryKeepSelection` (§1.5)
// ---------------------------------------------------------------------------
//
// WHAT THIS ROW CAN AND CANNOT SEE, measured rather than assumed, because the
// plan's specified shape ("run a geometry-only tool gesture and assert Subpatch
// on a different face was restored from the snapshot") is only HALF reachable
// from HTTP, and the unreachable half is the one it leans on:
//
//   * `MeshSnapshot.capture` runs inside `tool.doApply`, and nothing on the
//     apply path changes a Hide or Subpatch bit. So the snapshot's marks and
//     the live marks are IDENTICAL at restore time, and any implementation
//     that sources a bit from the snapshot reads the same number as one that
//     keeps it live. From HTTP the splice's two branches are indistinguishable.
//   * Therefore the "restore Hide from the snapshot instead of keeping it
//     live" break is INERT here. It is caught by the unittest in
//     source/snapshot.d (T-S6a), which hides a face AFTER the capture so the
//     two sources genuinely disagree, and asserts Hide-kept and
//     Subpatch-restored off ONE call so neither "restore everything" nor
//     "keep everything" passes.
//
// What this row DOES pin, and it is not covered by that unittest: that the
// production undo path reaches the splice at all and does not DROP the hide.
// The break it is sensitive to is a splice that clears Hide on restore —
// `restoredFaceMarks[i] & ~(Marks.Subpatch | Marks.Hide) | (snapshot Subpatch)`,
// the natural slip once somebody reads "Hide is session state". Under it the
// hidden faces come back visible after a Ctrl+Z of an unrelated move.

unittest {
    resetCube();

    // Subpatch on a face that is NOT one of the hidden ones, so the two marks
    // exercise different indices of the same word.
    selectMode("polygons", [3]);
    cmdId("mesh.subpatch_toggle");
    auto sub = model()["isSubpatch"].array;
    assert(sub[3].type == JSONType.true_, "fixture: face 3 must be a subpatch");

    selectMode("polygons", [0, 4]);
    cmdId("mesh.hide");
    assert(hiddenList("faceHidden") == [0, 4],
        "fixture: faces 0 and 4 hidden, got " ~ hiddenList("faceHidden").to!string);

    // A geometry-only tool apply: no topology change, so the undo takes the
    // `topologyUnchanged` splice branch — the one under test.
    auto before = verts();
    cmd("tool.set move on");
    cmd("tool.attr move TX 0.35");
    cmd("tool.doApply");
    cmd("tool.set move off");
    auto moved = verts();
    assert(moved.length == before.length,
        "T-S6a: the apply must not change topology, or the undo takes the "
        ~ "snapshot-marks branch and this row measures a different splice");
    assert(fabs(moved[1][0] - before[1][0]) > 0.1,
        "T-S6a: the tool apply must actually move geometry (dx="
        ~ (moved[1][0] - before[1][0]).to!string ~ ") — an apply that no-opped "
        ~ "would leave this row asserting nothing");

    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);

    assert(hiddenList("faceHidden") == [0, 4],
        "T-S6a: undoing a geometry-only apply must KEEP the live Hide bits, got "
        ~ hiddenList("faceHidden").to!string
        ~ " — an empty list means the splice cleared Hide on restore");
    assert(model()["isSubpatch"].array[3].type == JSONType.true_,
        "T-S6a: the same restore must leave face 3's Subpatch bit set");
}

// ---------------------------------------------------------------------------
// T-S7a — THE END-TO-END GIZMO DRAG WITH SOMETHING HIDDEN
// ---------------------------------------------------------------------------
//
// The debt Stage 5 recorded in its own header and handed here. Stage 5's rows
// drive commands (`mesh.quantize`, `mesh.flip`, `tool.doApply`); the whole-mesh
// MOVE has no command form at all — `commands/mesh/transform.d` has no
// whole-mesh fallback branch — so the only way a user reaches it is by
// dragging the gizmo with nothing selected. That path consumes
// `Mesh.selectedVertexIndices*` (§3.2 shape A) and had no end-to-end coverage.
//
// Fixture: hide the three faces around corner v0, which derives v0 — and only
// v0 — hidden, and (by §3.1) empties the selection, so the drag takes the
// whole-mesh fallback. Then drag the move gizmo's X arm.
//
// The assertion is the C8e pair, measured on the real drag:
//   * v0 is BIT-IDENTICAL — not "moved less", not "moved by a falloff weight";
//   * the other SEVEN all move, by the SAME non-zero delta.
// Both halves are needed. "v0 unmoved" alone passes a build where the drag
// moved nothing (a missed handle, a dead gizmo); "the seven moved" alone
// passes a build that moved all eight. A wrong implementation — the whole-mesh
// fallback not subtracting hidden — reads eight equal deltas, so the two rows
// disagree in the number of MOVED vertices (7 vs 8), which is a count no
// tolerance can blur.

unittest {
    resetCube();
    auto before = verts();
    assert(before.length == 8, "cube fixture");

    hideCornerV0();
    assert(selectedList("selectedVertices").length == 0,
        "fixture: the hide must leave an EMPTY selection (§3.1), else the drag "
        ~ "takes the SELECTION branch and not the whole-mesh fallback");

    cmd("tool.set move on");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Thread.sleep(250.msecs);   // handles publish after a drawn frame

    double sx0, sy0;
    bool found;
    fetchHandlePart(0, sx0, sy0, found);
    assert(found,
        "T-S7a: the X move handle (part 0) is missing from /api/tool/handles — "
        ~ "with nothing selected the gizmo must still arm on the whole mesh, "
        ~ "and without it this row cannot drive a drag at all");

    // Screen direction of world +X at the gizmo pivot (the mesh centre for a
    // whole-mesh operand). Magnitude does not matter — the assertion is
    // relative motion — but the direction must be right or the drag slides
    // along the arm's perpendicular and moves nothing.
    float px, py, nx, ny;
    assert(projectToWindow(Vec3(0, 0, 0), vp, px, py), "pivot off-camera");
    assert(projectToWindow(Vec3(1, 0, 0), vp, nx, ny), "pivot+X off-camera");
    double dx = nx - px, dy = ny - py;
    double len = sqrt(dx*dx + dy*dy);
    assert(len > 1.0, "world +X projects too short to drive a drag");

    immutable int x0 = cast(int)sx0, y0 = cast(int)sy0;
    immutable int x1 = x0 + cast(int)(100.0 * dx / len);
    immutable int y1 = y0 + cast(int)(100.0 * dy / len);

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    Thread.sleep(200.msecs);
    cmd("tool.set move off");

    auto after = verts();
    assert(after.length == 8, "the drag must not change the vertex count");

    // Count what moved, and by how much, per vertex.
    int movedCount = 0;
    double[3] delta0 = [0.0, 0.0, 0.0];
    foreach (vi; 0 .. 8) {
        double[3] d = [after[vi][0] - before[vi][0],
                       after[vi][1] - before[vi][1],
                       after[vi][2] - before[vi][2]];
        immutable double mag = sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
        if (mag > 1e-6) {
            if (movedCount == 0) delta0 = d;
            ++movedCount;
        }
    }

    // assertDidSomething: without a real drag every number below is 0 and the
    // "v0 unmoved" assertion would pass a test that measured nothing.
    immutable double mag0 = sqrt(delta0[0]*delta0[0] + delta0[1]*delta0[1]
                               + delta0[2]*delta0[2]);
    assert(mag0 > 0.05,
        "T-S7a: the gizmo drag moved nothing measurable (max |delta|="
        ~ mag0.to!string ~ ") — the event log is not hitting the move arm at "
        ~ "this camera / viewport, and every assertion below would be vacuous");

    assert(movedCount == 7,
        "T-S7a: a whole-mesh gizmo drag with vertex 0 hidden must move exactly "
        ~ "the SEVEN visible vertices, moved " ~ movedCount.to!string
        ~ " — 8 means the interactive drag path does not subtract hidden "
        ~ "geometry from the whole-mesh operand set (C8e)");

    // v0 by value, not by "it moved less".
    assert(after[0] == before[0],
        "T-S7a: the hidden vertex must be BIT-IDENTICAL after the drag, was "
        ~ fmtv(before[0]) ~ " now " ~ fmtv(after[0]));

    // …and the seven that did move all took the SAME translation, so this is a
    // rigid whole-mesh move minus one vertex, not a per-vertex falloff that
    // happened to weight v0 to zero.
    foreach (vi; 1 .. 8) {
        double[3] d = [after[vi][0] - before[vi][0],
                       after[vi][1] - before[vi][1],
                       after[vi][2] - before[vi][2]];
        foreach (k; 0 .. 3)
            assert(fabs(d[k] - delta0[k]) < 1e-4,
                "T-S7a: visible vertex " ~ vi.to!string ~ " must take the same "
                ~ "translation as the rest, got " ~ fmtv(d) ~ " vs "
                ~ fmtv(delta0));
    }
}

// ---------------------------------------------------------------------------
// T-S8a — hiding does not survive save + reload (§1.4), which is the one hide
// behaviour DOCUMENTED to users
// ---------------------------------------------------------------------------
//
// §1.4 makes hiding session state on purpose: `kV3dFormatVersion` stays 7 and
// no `"faceHide"` array is written next to `"faceSubpatch"`. USAGE.md now tells
// users so in as many words ("save a document with half of it hidden, reopen
// it, and everything is visible again"). A documented promise with no test is
// a promise that rots — and the wrong-but-plausible implementation here is not
// an accident but a well-meant feature: somebody adds `"faceHide"` beside
// `"faceSubpatch"` in io/native.d because "of course hiding should persist".
// Under that change this row reads 2 hidden faces after the reload and the
// USAGE.md line becomes false.
//
// Discriminator, and it is why Subpatch is in the fixture at all: the two
// assertions pull opposite ways off ONE reload. Subpatch MUST come back
// (it is document content) and Hide MUST NOT (it is a view). A row asserting
// only "nothing is hidden after the reload" would also pass a reload that
// produced an empty mesh, a default cube, or a silently-failed load — all of
// which have zero hidden faces. Requiring the Subpatch bit to survive the same
// round-trip proves the file really carried this document.

unittest {
    enum string path = "/tmp/vibe3d-test-hide-persistence.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();

    // Document content that MUST survive…
    selectMode("polygons", [3]);
    cmdId("mesh.subpatch_toggle");
    assert(model()["isSubpatch"].array[3].type == JSONType.true_,
        "fixture: face 3 must be a subpatch before the save");

    // …and a view onto it that must NOT.
    selectMode("polygons", [0, 4]);
    cmdId("mesh.hide");
    assert(hiddenList("faceHidden") == [0, 4],
        "fixture: faces 0 and 4 hidden before the save, got "
        ~ hiddenList("faceHidden").to!string);

    cmdParams("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path) && getSize(path) > 0,
        "T-S8a: file.save produced no file — nothing below would measure a "
        ~ "round-trip");

    // Reload over the live document.
    cmdParams("file.load", `{"path":"` ~ path ~ `"}`);

    assert(model()["isSubpatch"].array[3].type == JSONType.true_,
        "T-S8a: the reload must bring back face 3's Subpatch bit — without "
        ~ "this the 'nothing hidden' assertion below would also pass an empty "
        ~ "or failed load");
    assert(countHidden("faceHidden") == 0 && countHidden("vertexHidden") == 0
        && countHidden("edgeHidden") == 0,
        "T-S8a: hiding is session state (§1.4) and must NOT survive a save + "
        ~ "reload — got " ~ hiddenList("faceHidden").to!string
        ~ " hidden faces. USAGE.md tells users everything comes back visible; "
        ~ "a persisted Hide bit makes that line false.");
}
