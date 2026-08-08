// Hide Geometry — Stage 2 (doc/hide_geometry_plan.md): the commands
// (mesh.hide / mesh.hideUnselected / mesh.hideInvert / mesh.unhideAll),
// their registration, their keyboard shortcuts, and the /api/model HTTP
// surface (faceHidden / vertexHidden / edgeHidden). Drawing and picking
// exclusion (Stage 3) are NOT in scope here — every assertion below reads
// state through /api/model and /api/selection, never through a screenshot
// or a pick.
//
// Every fixture asserts BY IDENTITY (which faces), not just by count, per
// the project's testing gate: a wrong rule that hides the right NUMBER of
// faces from the wrong SET must still fail.

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.algorithm : sort, canFind;
import core.thread : Thread;
import core.time : msecs;

void main() {}

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

void clearHistory() {
    auto r = postJson("/api/command", `{"id":"history.clear"}`);
    assert(r["status"].str == "ok", "history.clear failed: " ~ r.toString);
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    clearHistory();
}

void selectMode(string mode, int[] indices) {
    // Mirrors tests/test_subpatch_tab_toggle.d's proven-working sequence:
    // switch the geometry type first, then post the selection.
    string typeTok = mode == "polygons" ? "polygon" : (mode == "edges" ? "edge" : "vertex");
    auto t = postJson("/api/command", "select.typeFrom " ~ typeTok);
    assert(t["status"].str == "ok", "select.typeFrom " ~ typeTok ~ " failed: " ~ t.toString);
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postJson("/api/select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void runCmd(string id) {
    auto r = postJson("/api/command", id);
    assert(r["status"].str == "ok", "/api/command " ~ id ~ " failed: " ~ r.toString);
}

JSONValue apiUndo() { return postJson("/api/undo", ""); }
JSONValue apiRedo() { return postJson("/api/redo", ""); }

JSONValue model() { return getJson("/api/model"); }

bool[] faceHidden()   { bool[] r; foreach (b; model()["faceHidden"].array)   r ~= b.type == JSONType.true_; return r; }
bool[] vertexHidden() { bool[] r; foreach (b; model()["vertexHidden"].array) r ~= b.type == JSONType.true_; return r; }
bool[] edgeHidden()   { bool[] r; foreach (b; model()["edgeHidden"].array)   r ~= b.type == JSONType.true_; return r; }

int[][] faces() {
    int[][] r;
    foreach (f; model()["faces"].array) {
        int[] fv;
        foreach (v; f.array) fv ~= cast(int)v.integer;
        r ~= fv;
    }
    return r;
}

// The set of face indices touching vertex `vi` (ground truth for the
// vertex-mode ANY-rule assertions), computed from the live /api/model
// output rather than assumed from any particular cube face ordering.
int[] facesTouchingVertex(int[][] fcs, int vi) {
    int[] r;
    foreach (fi, f; fcs) if (f.canFind(vi)) r ~= cast(int)fi;
    return r;
}

// The current face selection, as a sorted index list.
int[] selectedFaceList() {
    auto sel = getJson("/api/selection");
    assert("selectedFaces" in sel, "/api/selection lost its selectedFaces key: " ~ sel.toString);
    int[] r;
    foreach (v; sel["selectedFaces"].array) r ~= cast(int)v.integer;
    r.sort();
    return r;
}

bool[] isSubpatch() {
    bool[] r;
    foreach (b; model()["isSubpatch"].array) r ~= b.type == JSONType.true_;
    return r;
}

JSONValue getHistory() { return getJson("/api/history"); }

size_t countUndo(string commandName) {
    size_t n = 0;
    foreach (e; getHistory()["undo"].array)
        if (e["command"].str == commandName) ++n;
    return n;
}

JSONValue topEntry(string commandName) {
    auto undo = getHistory()["undo"].array;
    foreach_reverse (e; undo)
        if (e["command"].str == commandName) return e;
    return JSONValue.init;
}

bool[] boolMask(size_t n, int[] setBits) {
    auto m = new bool[](n);
    foreach (i; setBits) if (i >= 0 && cast(size_t)i < n) m[i] = true;
    return m;
}

// ---------------------------------------------------------------------------
// Keyboard-shortcut playback helpers (mirrors tests/test_subpatch_tab_toggle.d)
// ---------------------------------------------------------------------------

enum SDLK_h = 104;
enum SDLK_u = 117;
enum KMOD_LSHIFT = 1;
enum KMOD_LCTRL  = 64;

string keyCombo(double t, int sym, int mod) {
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

void pressKey(int sym, int mod) {
    auto r = postJson("/api/play-events", LOG_HEADER ~ "\n" ~ keyCombo(50, sym, mod));
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlaybackFinish();
}

// ---------------------------------------------------------------------------

unittest { // T-S2: mesh.hide hides a NON-CONTIGUOUS face pair, is undoable in
           // the UI-undo class, and clears the selection it hides — all as
           // ONE undo entry (§1.5, C9). Discriminator: faces 0 and 4 (not
           // adjacent) — an implementation that stores a count or hides
           // "the first N" reads a different set here.
    resetCube();
    auto m0 = model();
    assert(m0["faceCount"].integer == 6, "cube must have 6 faces");

    selectMode("polygons", [0, 4]);
    runCmd("mesh.hide");

    auto fh = faceHidden();
    assert(fh == [true, false, false, false, true, false],
        "mesh.hide(polygons,[0,4]) must hide EXACTLY faces {0,4}, got " ~ fh.to!string);

    // The hide command must clear the selection on what it hid (§3.1's
    // FACE-plane half — the invariant this stage owes). Asserted
    // UNCONDITIONALLY: the key exists (http_providers.d builds it for every
    // /api/selection response), and guarding on `if ("selectedFaces" in ...)`
    // would turn a future rename of it into a silently-green test instead of
    // a failure.
    auto selAfter = getJson("/api/selection");
    assert("selectedFaces" in selAfter,
        "/api/selection must expose selectedFaces: " ~ selAfter.toString);
    assert(selAfter["selectedFaces"].array.length == 0,
        "hidden faces must leave the selection, got " ~ selAfter.toString);

    // Exactly one entry, classified UI-undo.
    assert(countUndo("mesh.hide") == 1,
        "expected exactly one mesh.hide entry on the stack");
    auto top = topEntry("mesh.hide");
    assert(top.type != JSONType.null_, "no mesh.hide entry found");
    assert(top["ui"].type == JSONType.true_,
        "mesh.hide must be classified UI-undo (ui:true), not Model");

    // ONE undo restores BOTH the marks AND the pre-hide selection (C9).
    auto u = apiUndo();
    assert(u["status"].str == "ok", "undo of mesh.hide failed: " ~ u.toString);
    assert(faceHidden() == [false, false, false, false, false, false],
        "undo must restore all faces visible");
    assert(countUndo("mesh.hide") == 0, "mesh.hide entry must be gone after undo");
    // Unguarded, same reasoning as the selAfter assertion above.
    auto selRestored = getJson("/api/selection");
    assert("selectedFaces" in selRestored,
        "/api/selection must expose selectedFaces: " ~ selRestored.toString);
    int[] got;
    foreach (v; selRestored["selectedFaces"].array) got ~= cast(int)v.integer;
    got.sort();
    assert(got == [0, 4],
        "undo must restore the PRE-HIDE selection {0,4} in the SAME step, got " ~ got.to!string);
}

unittest { // Undo restores the selection ORDER STAMPS, not merely the Select
           // bits (code review BLOCKER). The apply path zeroes
           // faceSelectionOrder[i] in the SAME word write that drops Select
           // (mesh.d, setFaceHiddenFrom), so a revert() that restores only
           // the marks arrays hands back faces that read "selected" with
           // order 0 — and every order-consuming command then silently does
           // nothing: select.between/select.more find no ordered pair,
           // select.less finds no most-recent element, mesh.makePolygon
           // derives its winding from an all-zero vertex order.
           //
           // The test above sorts the restored selection and never looks at a
           // stamp, so it cannot see this; /api/selection reports WHICH faces
           // are selected but not their stamps, so there is no direct read to
           // assert on. This drives select.less instead — "deselect the most
           // recently selected element" — and reads the resulting set, which
           // is a pure function of the stamps.
           //
           // Discriminator: select face 0 THEN face 4 (stamps 1, 2). With the
           // stamps restored, select.less drops face 4 and leaves {0}. With
           // marks-only restore (every stamp 0) it finds no candidate at all
           // and leaves {0,4}. A restore that got the ORDER backwards would
           // leave {4}. All three outcomes are distinct.
    resetCube();
    selectMode("polygons", [0, 4]);
    runCmd("mesh.hide");
    auto u = apiUndo();
    assert(u["status"].str == "ok", "undo of mesh.hide failed: " ~ u.toString);
    assert(selectedFaceList() == [0, 4],
        "sanity: undo must restore the Select bits before the ORDER can matter, got "
        ~ selectedFaceList().to!string);

    runCmd("select.less");
    assert(selectedFaceList() == [0],
        "select.less after an undone hide must drop face 4 (the LAST one picked, "
        ~ "stamp 2) — {0,4} means the order stamps came back as zeros, {4} means "
        ~ "they came back reversed; got " ~ selectedFaceList().to!string);
}

unittest { // T-S2b row 1: Vertices-mode mesh.hide is the ANY rule (propagation
           // UP), asserted BY IDENTITY. Discriminator: selecting ONE vertex on
           // a cube hides exactly its 3 incident faces — neither 0 (an
           // implementation that requires ALL of a face's vertices selected)
           // nor 6 (an implementation that treats "one vertex" the same as
           // "nothing selected").
    resetCube();
    auto fcs = faces();
    auto incident = facesTouchingVertex(fcs, 0);
    assert(incident.length == 3,
        "sanity: a cube vertex must touch exactly 3 faces, touched " ~ incident.length.to!string);

    selectMode("vertices", [0]);
    runCmd("mesh.hide");

    auto expected = boolMask(fcs.length, incident);
    assert(faceHidden() == expected,
        "vertex-mode mesh.hide([v0]) must hide EXACTLY vertex 0's incident faces "
        ~ incident.to!string ~ ", got " ~ faceHidden().to!string);
}

unittest { // T-S2b row 2: Vertices-mode mesh.hideUnselected keeps visible only
           // the faces whose vertices are ALL selected — NOT the face-by-face
           // negation of the ANY rule (§1.2). Discriminator: selecting exactly
           // one face's 4 vertices keeps exactly THAT face visible (1), not 5
           // (what a negated-ANY implementation reads: every face touching
           // ANY of those 4 vertices stays visible except the lone face that
           // touches none).
    resetCube();
    auto fcs = faces();
    auto vs0 = fcs[0];   // face 0's own vertex ring
    assert(vs0.length >= 3, "face 0 must be a real polygon");

    selectMode("vertices", vs0);
    runCmd("mesh.hideUnselected");

    auto fh = faceHidden();
    size_t visibleCount = 0;
    foreach (b; fh) if (!b) ++visibleCount;
    assert(visibleCount == 1,
        "hideUnselected(vertices, face0's verts) must leave EXACTLY 1 face visible, got "
        ~ visibleCount.to!string ~ " (" ~ fh.to!string ~ ")");
    assert(!fh[0], "the one visible face must be face 0 (its vertex ring drove the selection)");
}

unittest { // mesh.hide is ADDITIVE — MEASURED, not derived (accumulation
           // cases M2P/M2V against the clean-state control M2CTRL; the
           // C-series cannot show this because every C row starts from a
           // clean scene, where union and replace agree bit for bit). A
           // second Hide Selected call grows the hidden set, it does not
           // replace it. Discriminator: hide face 0, then hide face 1 in a
           // SEPARATE call — a "replace" implementation reads only face 1
           // hidden after the second call.
    resetCube();
    selectMode("polygons", [0]);
    runCmd("mesh.hide");
    selectMode("polygons", [1]);
    runCmd("mesh.hide");

    auto fh = faceHidden();
    assert(fh == [true, true, false, false, false, false],
        "two separate mesh.hide calls must UNION their targets, got " ~ fh.to!string);
}

unittest { // mesh.hideUnselected UNIONS with the already-hidden set — it does
           // NOT replace it, and an isolate never clears a bit that was
           // already set, not even for a face that lands back in the keep
           // set. MEASURED (accumulation cases M1 and M1ALT, which predict
           // opposite numbers under the two candidate rules and agree on
           // union both times; the clean-state control M1CTRL re-measured the
           // ALL-selected keep rule itself).
           //
           // Fixture, and what each rule predicts: hide face 0; then select
           // face 0's own vertex ring — those vertices are all still VISIBLE,
           // since each touches two other unhidden cube faces — and isolate.
           // Face 0 is the only cube face whose whole vertex ring is
           // selected, so keep = {0} and its complement is {1..5}.
           //   * REPLACE ⇒ hidden becomes exactly {1..5}: face 0 comes back
           //     VISIBLE and 1 face is visible.
           //   * UNION   ⇒ hidden becomes {0} ∪ {1..5} = ALL SIX: face 0
           //     stays hidden and 0 faces are visible.
           // Measured behaviour is union, so the whole mesh goes dark here.
           // That is the "isolate onto an already-hidden target blanks the
           // viewport" case, and it is CORRECT, not a bug to guard against —
           // the mitigation is a hidden-count readout in a later stage.
    resetCube();
    auto fcs = faces();
    auto vs0 = fcs[0];

    selectMode("polygons", [0]);
    runCmd("mesh.hide");
    assert(faceHidden()[0], "face 0 must be hidden by the setup step");

    auto vh = vertexHidden();
    foreach (vi; vs0)
        assert(!vh[vi], "sanity: face 0's own vertices must still be visible "
            ~ "(each touches 2 other, unhidden cube faces)");

    selectMode("vertices", vs0);
    runCmd("mesh.hideUnselected");

    auto fh = faceHidden();
    assert(fh[0],
        "hideUnselected must UNION with the standing hidden set: face 0 was "
        ~ "already hidden, so it must STAY hidden even though its vertex ring "
        ~ "is fully selected and it is in the keep set. Reading false here is "
        ~ "the replace rule. got hidden=" ~ fh.to!string);
    assert(fh == [true, true, true, true, true, true],
        "union of {0} with the keep-set complement {1..5} is every face, got "
        ~ fh.to!string);
    size_t visibleCount = 0;
    foreach (b; fh) if (!b) ++visibleCount;
    assert(visibleCount == 0,
        "isolate onto an already-hidden target leaves NOTHING visible "
        ~ "(measured); replace would leave exactly 1. got "
        ~ visibleCount.to!string ~ " visible faces");
}

unittest { // mesh.hideInvert in POLYGONS mode is a plain flip of every face's
           // Hide bit, independent of the CURRENT selection (§5.1 and
           // accumulation cases M3B/M3E_polygon: measured, no selection
           // involved). Discriminator: select an UNRELATED visible face
           // before inverting — an implementation that scopes the invert to
           // the selection would leave that face's bit untouched (still
           // visible) instead of flipping it too.
           //
           // Scope note: this fixture stays in POLYGONS mode throughout, and
           // that is the only mode the implementation is correct in. The
           // capture found the reference's invert to be COMPONENT-TYPED —
           // Vertices/Edges mode flips the vertex plane and propagates up,
           // Item mode touches nothing (M3/M3C/M3E_*) — a known divergence
           // recorded in commands/mesh/hide.d and deliberately not covered
           // here, because a test written against the current face-only flip
           // would have to be rewritten by the fix rather than driving it.
    resetCube();
    selectMode("polygons", [0, 2]);
    runCmd("mesh.hide");
    assert(faceHidden() == [true, false, true, false, false, false]);

    selectMode("polygons", [3]);   // an unrelated, currently-visible face
    runCmd("mesh.hideInvert");

    assert(faceHidden() == [false, true, false, true, true, true],
        "hideInvert must flip EVERY face's bit, ignoring the current selection");

    auto u = apiUndo();
    assert(u["status"].str == "ok", "undo of mesh.hideInvert failed: " ~ u.toString);
    assert(faceHidden() == [true, false, true, false, false, false],
        "undo of hideInvert must restore the PRE-invert hidden set exactly");
}

unittest { // mesh.unhideAll: (a) is a no-op (no undo entry) when nothing is
           // hidden; (b) clears the face plane AND lets the derived
           // vertex/edge planes self-heal via refreshHiddenDerived(), in ONE
           // command, not two; (c) undoes back to the fully-hidden state.
    resetCube();
    // A no-op Operator returns false from evaluate(); the generic /api/command
    // dispatcher (http_providers.d) surfaces that as status:error ("did not
    // apply") — the same convention every other no-op command follows, not a
    // bug in this test. The point under test is that NO undo entry is
    // recorded, not that the HTTP call reports "ok".
    auto noop = postJson("/api/command", "mesh.unhideAll");
    assert(noop["status"].str == "error",
        "unhideAll on an already-clear mesh must be a no-op: " ~ noop.toString);
    assert(countUndo("mesh.unhideAll") == 0,
        "unhideAll on an already-clear mesh must be a no-op (no undo entry)");

    // C6: empty selection ⇒ mesh.hide hides EVERYTHING, all three planes.
    //
    // What the two derived-plane assertions below do and do NOT show: with
    // EVERY face hidden, all-true is the answer under any candidate
    // derivation rule — vertex ANY-incident and vertex ALL-incident agree,
    // and so do edge-from-vertices and edge-from-polygons. So these pin only
    // that the derivation RAN on all three planes, never that it ran by the
    // measured law. The law is pinned asymmetrically elsewhere: by the
    // partial-hide fixture in the masked-clear test below (which reads
    // all-FALSE on both derived planes in a state where the rejected rules
    // read something else), and by Stage 0's own mesh.d unittests T-S0a/b.
    selectMode("polygons", []);   // ensure nothing selected
    runCmd("mesh.hide");
    auto fh = faceHidden();
    foreach (b; fh) assert(b, "empty-selection mesh.hide must hide every face");
    auto vh = vertexHidden();
    foreach (b; vh) assert(b, "every vertex must derive hidden when every face is");
    auto eh = edgeHidden();
    foreach (b; eh) assert(b, "every edge must derive hidden when every vertex is");

    runCmd("mesh.unhideAll");
    foreach (b; faceHidden())   assert(!b, "unhideAll must clear every face");
    foreach (b; vertexHidden()) assert(!b, "unhideAll must self-heal the derived vertex plane");
    foreach (b; edgeHidden())   assert(!b, "unhideAll must self-heal the derived edge plane");

    auto u = apiUndo();
    assert(u["status"].str == "ok", "undo of mesh.unhideAll failed: " ~ u.toString);
    foreach (b; faceHidden()) assert(b, "undo of unhideAll must restore the fully-hidden state");
}

unittest { // mesh.unhideAll clears ONLY the Hide bit — `&= ~Marks.Hide`,
           // never a wholesale `faceMarks[] = 0`. faceMarks packs Select,
           // Subpatch and Hide into ONE word, so in the all-hidden /
           // nothing-else-set fixture above a wrong `= 0` reads IDENTICALLY
           // to the correct mask: everything ends up visible either way, and
           // there is nothing else in the word to lose. Nothing else in the
           // repo exercises clearHidden, so without this fixture the mask is
           // untested.
           //
           // Discriminator: enter unhideAll with two other bits live in that
           // same word — (i) Subpatch set on a face, (ii) a still-VISIBLE
           // face selected — and assert both survive. `= 0` drops both;
           // `&= ~(Hide|Select)` drops the second alone.
           //
           // The partial hide also makes the DERIVED planes asymmetric,
           // which the all-hidden fixture above cannot: faces 0 and 2 share
           // edge (0,3), and hiding both leaves every vertex touching some
           // third visible face. So the measured law reads all-false on both
           // derived planes here, while an ANY-incident vertex rule reads 6
           // vertices hidden and a derived-from-POLYGONS edge rule hides the
           // shared edge. All-false is a real discriminator in this state.
    resetCube();

    // (i) A Subpatch bit, on a face that will stay visible throughout.
    selectMode("polygons", [5]);
    runCmd("mesh.subpatch_toggle");
    assert(isSubpatch()[5], "setup: face 5 must be subpatch before the hide");

    // A PARTIAL hide, of two faces that share an edge.
    selectMode("polygons", [0, 2]);
    runCmd("mesh.hide");
    assert(faceHidden() == [true, false, true, false, false, false],
        "setup: exactly faces {0,2} hidden, got " ~ faceHidden().to!string);
    foreach (vi, b; vertexHidden())
        assert(!b, "vertex " ~ vi.to!string ~ " must stay visible: it still touches "
            ~ "a third, unhidden face (ALL-incident rule). An ANY-incident rule "
            ~ "hides 6 of the 8 here. got " ~ vertexHidden().to!string);
    foreach (ei, b; edgeHidden())
        assert(!b, "edge " ~ ei.to!string ~ " must stay visible: edges derive from "
            ~ "VERTICES, and no vertex is hidden. A derived-from-polygons rule "
            ~ "hides the edge faces 0 and 2 share. got " ~ edgeHidden().to!string);
    assert(isSubpatch()[5], "the hide itself must not disturb the Subpatch bit");

    // (ii) A live selection on a face that is visible when unhideAll runs.
    selectMode("polygons", [3]);
    assert(selectedFaceList() == [3], "setup: face 3 must be selected");

    runCmd("mesh.unhideAll");

    foreach (b; faceHidden()) assert(!b, "unhideAll must clear every face");
    assert(isSubpatch()[5],
        "unhideAll must mask ONLY the Hide bit — face 5's Subpatch bit shares "
        ~ "that word and must survive. Reading false here is a `faceMarks[] = 0` "
        ~ "wipe. got isSubpatch=" ~ isSubpatch().to!string);
    assert(selectedFaceList() == [3],
        "unhideAll must leave a visible face's Select bit alone — it shares the "
        ~ "same word as Hide. got " ~ selectedFaceList().to!string);
}

unittest { // Shortcut wiring end-to-end: H / Shift+H / Ctrl+H / U fire the
           // registered commands through the SAME SDL event path Tab uses
           // for mesh.subpatch_toggle (tests/test_subpatch_tab_toggle.d).
           // §1.3: these four keys are unbound elsewhere — the gizmo-size
           // keys (-/=) are untouched by this task.
    resetCube();

    // H hides the selection.
    selectMode("polygons", [0, 3]);
    pressKey(SDLK_h, 0);
    assert(faceHidden() == [true, false, false, true, false, false],
        "H must fire mesh.hide on the selection");

    // U unhides everything.
    pressKey(SDLK_u, 0);
    foreach (b; faceHidden()) assert(!b, "U must fire mesh.unhideAll");

    // Shift+H isolates the selection.
    selectMode("polygons", [1]);
    pressKey(SDLK_h, KMOD_LSHIFT);
    auto fh1 = faceHidden();
    assert(!fh1[1], "Shift+H must keep the selected face visible");
    size_t visible = 0;
    foreach (b; fh1) if (!b) ++visible;
    assert(visible == 1, "Shift+H must fire mesh.hideUnselected (isolate), got "
        ~ visible.to!string ~ " visible faces");

    pressKey(SDLK_u, 0);   // back to fully visible

    // Ctrl+H inverts.
    selectMode("polygons", [2, 5]);
    pressKey(SDLK_h, 0);   // hide {2,5}
    assert(faceHidden() == [false, false, true, false, false, true]);
    pressKey(SDLK_h, KMOD_LCTRL);
    assert(faceHidden() == [true, true, false, true, true, false],
        "Ctrl+H must fire mesh.hideInvert");
}
