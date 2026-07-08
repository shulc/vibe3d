// Phase 2 of doc/undo_change_tracker_plan.md — wire the INTERACTIVE edge-extrude
// commit through the mesh-edit change tracker so its undo entry stores an
// operation-log MeshEditDelta instead of a before/after MeshSnapshot pair.
//
// These tests drive the INTERACTIVE tool commit path (activate via
// `tool.set edge.extrude on`, a real off-handle free-drag through
// /api/play-events, commit via `tool.set edge.extrude off` → deactivate →
// commitEdit). This is the ONLY route Phase 2 migrates — the headless
// tool.doApply / /api/command route stays on MeshSnapshot and is covered by
// tests/test_edge_extrude_tool.d.
//
// Asserted here:
//   1. PARITY GATE: the same extrude+undo under VIBE3D_UNDO_TRACKER off (snapshot
//      path) and on (delta path) yields byte-identical post-undo geometry, equal
//      to the pre-extrude cube.
//   2. ROUND-TRIP: extrude → undo == pre-extrude; redo == post-extrude.
//   3. EDGE SELECTION SURVIVES: after undo the ORIGINAL selected edge is restored
//      (NOT the post-extrude ridge).
//   4. jumpTo: jump back past the extrude then forward — geometry round-trips.
//   5. NEGATIVE CONTROL: documented separately (built under
//      -version=UndoNegControlReshape / -version=UndoNegControlReindex, which
//      stub the ReshapeFaces^-1 / Reindex^-1 inverse and MUST break the round-trip
//      — see the run instructions in the report).
//
// The toggle is flipped at runtime via the test-only `undo.tracker.on` /
// `undo.tracker.off` commands (app.d), so a single running instance exercises
// both paths (the toggle is normally read once from VIBE3D_UNDO_TRACKER).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

import drag_helpers;

void main() {}

string BASE = "http://localhost:8080";

// --- HTTP helpers ----------------------------------------------------------

void resetCube() {
    auto resp = post(BASE ~ "/api/reset?type=cube", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "/api/reset cube failed: " ~ cast(string)resp);
}

void resetGrid(int n) {
    auto resp = post(BASE ~ "/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "/api/reset grid failed: " ~ cast(string)resp);
}

void cmd(string s) {
    auto resp = post(BASE ~ "/api/command", s);
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ cast(string)resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(BASE ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "/api/select failed: " ~ cast(string)resp);
}

JSONValue postUndo() { return parseJSON(cast(string)post(BASE ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(BASE ~ "/api/redo", "")); }
JSONValue getModel() { return parseJSON(cast(string)get(BASE ~ "/api/model")); }
JSONValue getSelection() { return parseJSON(cast(string)get(BASE ~ "/api/selection")); }

JSONValue jumpTo(int target) {
    return parseJSON(cast(string)post(BASE ~ "/api/history/jump",
        `{"target":` ~ target.to!string ~ `}`));
}

// --- geometry helpers ------------------------------------------------------

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

// True iff every vertex of `a` has a coincident vertex in `b` and vice versa,
// AND the counts match. Order-independent BYTE-LEVEL geometry equality.
bool sameGeometry(JSONValue a, JSONValue b) {
    if (a["vertexCount"].integer != b["vertexCount"].integer) return false;
    if (a["faceCount"].integer   != b["faceCount"].integer)   return false;
    if (a["vertices"].array.length != b["vertices"].array.length) return false;
    foreach (i; 0 .. a["vertices"].array.length)
        if (vertAt(b, vert(a, i)) < 0) return false;
    foreach (i; 0 .. b["vertices"].array.length)
        if (vertAt(a, vert(b, i)) < 0) return false;
    return true;
}

// The set of endpoint POSITION pairs of the currently-selected edges, as a
// canonicalised string list (so it can be compared order-independently).
string[] selectedEdgeEndpointKeys(JSONValue model, JSONValue sel) {
    string[] keys;
    // /api/selection returns selectedEdges as an array of selected EDGE INDICES
    // (not a bool array); each indexes model["edges"].
    foreach (idxJson; sel["selectedEdges"].array) {
        size_t ei = cast(size_t)idxJson.integer;
        if (ei >= model["edges"].array.length) continue;
        auto e = model["edges"].array[ei];
        int a = cast(int)e.array[0].integer;
        int b = cast(int)e.array[1].integer;
        auto pa = vert(model, a);
        auto pb = vert(model, b);
        // Canonical: sort endpoints by tuple so (a,b) == (b,a).
        string ka = format3(pa), kb = format3(pb);
        keys ~= (ka < kb) ? (ka ~ "|" ~ kb) : (kb ~ "|" ~ ka);
    }
    import std.algorithm : sort;
    keys.sort();
    return keys;
}

string format3(V3 p) {
    import std.format : format;
    // Round to 1e-4 to absorb float noise.
    return format("%.4f,%.4f,%.4f", p.x, p.y, p.z);
}

// --- interactive drag driver -----------------------------------------------

// Perform one interactive edge-extrude session via a FREE (off-handle) screen
// drag: click well away from the gizmo so toolHandles.test misses both handles
// and a blind 2-axis drag begins (-dy → +extrude, +dx → +width). Then commit by
// deactivating the tool. Returns nothing; leaves the mesh post-extrude with one
// committed history entry.
void interactiveExtrude() {
    cmd("tool.set edge.extrude on");

    auto cam = fetchCamera(BASE);
    // Click near the TOP-LEFT corner of the viewport (away from the cube center,
    // which projects near the middle), so the click misses the gizmo handles and
    // starts a PART_FREE drag. Drag up + right: -dy → +extrude, +dx → +width.
    int x0 = cam.vpX + 40;
    int y0 = cam.vpY + cam.height - 40;   // bottom-left in window space
    int x1 = x0 + 50;                     // +dx → width ~ 0.5
    int y1 = y0 - 50;                     // -dy → extrude ~ 0.5
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log, BASE);

    cmd("tool.set edge.extrude off");     // deactivate → commitEdit
}

// ---------------------------------------------------------------------------
// Shared: select the cube top-front edge, return the pre-extrude model.
// ---------------------------------------------------------------------------
JSONValue selectTopFrontEdgeAndReturnPre() {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube top-front edge not found");
    postSelect("edges", [ei]);
    return before;
}

// ---------------------------------------------------------------------------
// Shared: select a FREE-END grid boundary edge and return the pre-extrude model.
//
// Extruding a boundary edge of an open grid dissolves its (degree-2 corner)
// endpoints as free ends — the kernel's tail compactUnreferenced DROPS those
// verts and builds a NON-identity remap[]. That is the case that exercises the
// Reindex⁻¹ inverse end-to-end (the cube top-front edge, whose endpoints are
// 3-face corners, drops nothing → its Reindex is identity → it cannot prove the
// permutation handling). This helper is what makes the extrude-path Reindex
// negative control bite.
//
// On grid n=2, edge index 0 = [vert0(-1,0,-1) → vert1(0,0,-1)] is a top-row
// boundary corner edge (1 adjacent face); both endpoints are corners.
// ---------------------------------------------------------------------------
JSONValue selectGridBoundaryEdgeAndReturnPre() {
    resetGrid(2);
    auto before = getModel();
    int va = vertAt(before, V3(-1.0, 0.0, -1.0));
    int vb = vertAt(before, V3( 0.0, 0.0, -1.0));
    assert(va >= 0 && vb >= 0, "grid boundary endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "grid boundary edge not found");
    postSelect("edges", [ei]);
    return before;
}

// ===========================================================================
// 1. PARITY GATE: snapshot path (off) == delta path (on) == pre-extrude cube
//    after undo. Run the SAME sequence under both toggle states in one instance.
// ===========================================================================
unittest {
    // --- snapshot path (tracker OFF) ---
    cmd("undo.tracker.off");
    cmd("history.clear");
    auto preOff = selectTopFrontEdgeAndReturnPre();
    interactiveExtrude();
    auto postOff = getModel();
    assert(postOff["vertexCount"].integer > preOff["vertexCount"].integer,
        "snapshot path: extrude built no geometry (verts unchanged)");
    auto u1 = postUndo();
    assert(u1["status"].str == "ok", "snapshot-path undo failed: " ~ u1.toString);
    auto undoneOff = getModel();
    assert(sameGeometry(undoneOff, preOff),
        "snapshot path: post-undo geometry != pre-extrude cube");

    // --- delta path (tracker ON) ---
    cmd("undo.tracker.on");
    cmd("history.clear");
    auto preOn = selectTopFrontEdgeAndReturnPre();
    interactiveExtrude();
    auto postOn = getModel();
    assert(postOn["vertexCount"].integer > preOn["vertexCount"].integer,
        "delta path: extrude built no geometry (verts unchanged)");
    auto u2 = postUndo();
    assert(u2["status"].str == "ok", "delta-path undo failed: " ~ u2.toString);
    auto undoneOn = getModel();
    assert(sameGeometry(undoneOn, preOn),
        "delta path: post-undo geometry != pre-extrude cube");

    // --- PARITY: the two post-extrude meshes match AND the two post-undo meshes
    //     match (both equal the pre-extrude cube). This is the byte-identical gate.
    assert(sameGeometry(postOff, postOn),
        "PARITY: post-extrude geometry differs between snapshot and delta paths");
    assert(sameGeometry(undoneOff, undoneOn),
        "PARITY: post-undo geometry differs between snapshot and delta paths");
    assert(sameGeometry(undoneOff, preOff) && sameGeometry(undoneOn, preOn),
        "PARITY: post-undo geometry is not the pre-extrude cube on both paths");

    cmd("undo.tracker.off");   // leave the instance in the default state
}

// ===========================================================================
// 2. ROUND-TRIP (delta path): extrude → undo == pre; redo == post.
// ===========================================================================
unittest {
    cmd("undo.tracker.on");
    cmd("history.clear");
    auto pre = selectTopFrontEdgeAndReturnPre();
    interactiveExtrude();
    auto post = getModel();

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assert(sameGeometry(getModel(), pre), "round-trip: undo != pre-extrude");

    auto r = postRedo();
    assert(r["status"].str == "ok", "redo failed: " ~ r.toString);
    assert(sameGeometry(getModel(), post), "round-trip: redo != post-extrude");

    cmd("undo.tracker.off");
}

// ===========================================================================
// 3. EDGE SELECTION SURVIVES (delta path): after undo the ORIGINAL selected edge
//    is restored, NOT the post-extrude ridge.
// ===========================================================================
unittest {
    cmd("undo.tracker.on");
    cmd("history.clear");
    auto pre = selectTopFrontEdgeAndReturnPre();
    auto selPre = getSelection();
    auto preKeys = selectedEdgeEndpointKeys(pre, selPre);
    assert(preKeys.length == 1,
        "expected exactly one selected edge pre-extrude, got " ~ preKeys.length.to!string);

    interactiveExtrude();

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto undone = getModel();
    auto selPost = getSelection();
    auto postKeys = selectedEdgeEndpointKeys(undone, selPost);

    assert(postKeys == preKeys,
        "edge selection not restored on undo: pre=" ~ preKeys.to!string
        ~ " post=" ~ postKeys.to!string
        ~ " (the original selected edge must come back, NOT the ridge)");

    cmd("undo.tracker.off");
}

// ===========================================================================
// 4. jumpTo across the extrude (delta path): jump back past the extrude, then
//    forward — geometry round-trips byte-identically in both directions.
// ===========================================================================
unittest {
    cmd("undo.tracker.on");
    cmd("history.clear");
    auto pre = selectTopFrontEdgeAndReturnPre();
    interactiveExtrude();
    auto post = getModel();

    // History now: [ select(edge), edge-extrude ]. Jump to BEFORE the extrude
    // (target = number of entries to keep applied; 1 keeps just the select).
    auto hist = parseJSON(cast(string)get(BASE ~ "/api/history"));
    auto undoLen = hist["undo"].array.length;
    assert(undoLen >= 1, "expected at least the extrude on the undo stack");

    // Jump back to just after the select (drop the extrude).
    auto jb = jumpTo(cast(int)undoLen - 1);
    assert(jb["status"].str == "ok", "jump back failed: " ~ jb.toString);
    // jumpTo is drained on the main thread; poll the model until it settles.
    assert(sameGeometry(getModel(), pre),
        "jumpTo back past extrude != pre-extrude geometry");

    // Jump forward past the extrude again.
    auto jf = jumpTo(cast(int)undoLen);
    assert(jf["status"].str == "ok", "jump forward failed: " ~ jf.toString);
    assert(sameGeometry(getModel(), post),
        "jumpTo forward past extrude != post-extrude geometry");

    cmd("undo.tracker.off");
}

// ===========================================================================
// 5. FREE-END round-trip + PARITY (the Reindex⁻¹ witness). Extruding a grid
//    boundary edge dissolves its free-end endpoints, so the kernel's tail
//    compaction DROPS verts and builds a non-identity remap[]. This is the
//    case the §2.3 Reindex⁻¹ negative control must break (the cube edge drops
//    nothing, so its Reindex is identity and cannot exercise the inverse).
//
//    Asserts: (a) snapshot path round-trips; (b) delta path round-trips +
//    redo; (c) the two are byte-identical (parity) at post-extrude AND
//    post-undo. Under -version=UndoNegControlReindex the stubbed Reindex⁻¹
//    corrupts the delta revert here → this test FAILS (it passes on the
//    cube-only tests because those have an identity Reindex).
// ===========================================================================
unittest {
    // --- snapshot path (tracker OFF) ---
    cmd("undo.tracker.off");
    cmd("history.clear");
    auto preOff = selectGridBoundaryEdgeAndReturnPre();
    interactiveExtrude();
    auto postOff = getModel();
    // Free-end dissolve: post mesh has a DIFFERENT vert set (endpoints dropped,
    // insets added) — assert the extrude actually changed geometry.
    assert(!sameGeometry(postOff, preOff),
        "free-end snapshot path: extrude did not change geometry");
    auto u1 = postUndo();
    assert(u1["status"].str == "ok", "free-end snapshot undo failed: " ~ u1.toString);
    auto undoneOff = getModel();
    assert(sameGeometry(undoneOff, preOff),
        "free-end snapshot path: post-undo geometry != pre-extrude grid");

    // --- delta path (tracker ON) — the Reindex⁻¹ witness ---
    cmd("undo.tracker.on");
    cmd("history.clear");
    auto preOn = selectGridBoundaryEdgeAndReturnPre();
    interactiveExtrude();
    auto postOn = getModel();
    assert(!sameGeometry(postOn, preOn),
        "free-end delta path: extrude did not change geometry");
    auto u2 = postUndo();
    assert(u2["status"].str == "ok", "free-end delta undo failed: " ~ u2.toString);
    auto undoneOn = getModel();
    assert(sameGeometry(undoneOn, preOn),
        "free-end delta path: post-undo geometry != pre-extrude grid "
        ~ "(Reindex⁻¹ must restore the dropped free-end verts at their indices)");

    // Redo: forward replay of a NON-identity compaction (drop+repack) — the
    // delta.apply path's compaction-forward lock at the HTTP level.
    auto r = postRedo();
    assert(r["status"].str == "ok", "free-end redo failed: " ~ r.toString);
    assert(sameGeometry(getModel(), postOn),
        "free-end delta path: redo != post-extrude grid");

    // --- PARITY across the free-end (Reindex-bearing) op ---
    assert(sameGeometry(postOff, postOn),
        "free-end PARITY: post-extrude geometry differs between snapshot and delta");
    assert(sameGeometry(undoneOff, undoneOn),
        "free-end PARITY: post-undo geometry differs between snapshot and delta");

    cmd("undo.tracker.off");
}

// ===========================================================================
// 6. TASK 0317 SHOULD-FIX — redo must reproduce the WINDING-CORRECTED mesh,
//    not the pre-flip (folded) winding the tracker captured before the
//    winding-consistency safety net ran.
//
//    mesh.d's extrudeEdgesByMask records recordReshapeFaces (neighbour/side
//    rewrites) and recordAddFaces (bridge/cap tail) BEFORE the task-0317
//    two-colouring winding pass runs. When that pass actually flips a face
//    (a multi-edge overshoot that welds one free end's clamp onto another's),
//    the flip was until now invisible to the edit-delta: MeshEditDelta.apply
//    (redo) replays faceListsAfter/faceLists verbatim, silently restoring the
//    PRE-flip (folded) winding even though undo — which restores the whole
//    pre-op face list via the RemoveFaces/AddFaces/ReshapeFaces inverses —
//    was unaffected. Fixed by recording one more ReshapeFaces entry for
//    exactly the faces the winding pass flips, keyed in the same
//    post-cleanup index space `removeFacesForward` reproduces on replay.
//
//    This exact repro ALSO tripped a second, previously-unknown instance of
//    the identical class of bug in the degenerate-face cleanup pass just
//    above the winding pass: a face whose consecutive duplicate corners
//    collapse (e.g. an overshoot-welded [a,b,b,c,c] -> [a,b,c]) but that
//    SURVIVES (>=3 corners after collapsing) was mutated in place with NO
//    tracker record at all — redo left it at whatever duplicate-corner shape
//    an earlier ReshapeFaces/AddFaces entry had recorded. Fixed the same way:
//    one more ReshapeFaces entry for exactly the faces that collapse-but-
//    survive, keyed in the SAME pre-cleanup index space the RemoveFaces
//    entry already uses. Both fixes are required for this test to pass —
//    the collapse-tracking gap surfaces first (as literal duplicate corners
//    on redo, worse than a mere winding flip) and would otherwise mask the
//    winding-flip fix entirely.
//
//    Repro: n=3 grid, center-quad opposite edges (5,6)+(9,10), extrude=0.2,
//    width=3 — the EXACT multi-edge overshoot from test_edge_extrude.d's
//    task 0317 one-shot regression (test 16), driven here through the
//    INTERACTIVE tool + tracker commit path instead of the one-shot command
//    (the one-shot/headless `tool.doApply` and `mesh.edge_extrude` paths are
//    snapshot-backed, not delta-backed, so they can't exercise this bug).
//    The off-handle free drag maps pixels to params at FREE_SCALE=0.01
//    (source/tools/edge_extrude.d), so a (+300,-20) px delta from a zero
//    baseline yields EXACTLY width=3.0, extrude=0.2 — no need to approximate.
// ===========================================================================

// Exact per-face WINDING comparison (order-sensitive) — unlike sameGeometry
// above, which only checks vertex-SET membership and would miss a face whose
// corners are the same set but in reversed (folded) order.
bool facesExactMatch(JSONValue a, JSONValue b) {
    auto fa = a["faces"].array;
    auto fb = b["faces"].array;
    if (fa.length != fb.length) return false;
    foreach (i; 0 .. fa.length) {
        auto ca = fa[i].array;
        auto cb = fb[i].array;
        if (ca.length != cb.length) return false;
        foreach (k; 0 .. ca.length)
            if (ca[k].integer != cb[k].integer) return false;
    }
    return true;
}

// Hole-free: no undirected edge shared by >2 faces, no directed half-edge
// used twice (a fold / inconsistent winding). Index-only, no vertex positions
// needed. (Duplicated from tests/test_edge_extrude.d — test binaries compile
// standalone; see drag_helpers.d's header note on why the math is repeated.)
bool isHoleFree(JSONValue m) {
    int[ulong] undirected;
    int[ulong] directed;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        auto n = idx.length;
        foreach (k; 0 .. n) {
            ulong x = cast(ulong)idx[k].integer;
            ulong y = cast(ulong)idx[(k + 1) % n].integer;
            ulong lo = x < y ? x : y, hi = x < y ? y : x;
            undirected[(lo << 32) | hi] += 1;
            directed[(x << 32) | y] += 1;
        }
    }
    foreach (_, c; undirected) if (c > 2) return false;
    foreach (_, c; directed)   if (c > 1) return false;
    return true;
}

unittest {
    cmd("undo.tracker.on");
    cmd("history.clear");

    resetGrid(3);
    auto pre = getModel();
    assert(pre["vertexCount"].integer == 16, "0317 redo: expected 16-vert n=3 grid");
    int e56  = edgeIndex(pre, 5, 6);
    int e910 = edgeIndex(pre, 9, 10);
    assert(e56 >= 0 && e910 >= 0, "0317 redo: center-quad opposite edges (5,6)/(9,10) not found");
    postSelect("edges", [e56, e910]);

    // Interactive commit through the TRACKED (delta) path: off-handle free
    // drag with a TOTAL delta of (+300,-20) px == exactly (width=3.0,
    // extrude=0.2) at FREE_SCALE=0.01 — the same overshoot task 0317's
    // one-shot test drives, built here via the interactive tool + tracker
    // instead. Click near the top-left viewport corner (far from the gizmo,
    // which anchors at the selected edges' midpoint) so the click misses
    // both handles and a blind PART_FREE 2-axis drag begins.
    cmd("tool.set edge.extrude on");
    auto cam = fetchCamera(BASE);
    int x0 = cam.vpX + 40;
    int y0 = cam.vpY + cam.height - 40;
    int x1 = x0 + 300;   // +dx*0.01 = +3.0 width
    int y1 = y0 - 20;    // -dy*0.01 = +0.2 extrude
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log, BASE);
    cmd("tool.set edge.extrude off");   // deactivate -> commitEdit (delta path)

    auto post = getModel();
    assert(post["vertexCount"].integer > pre["vertexCount"].integer,
        "0317 redo: interactive commit built no geometry (drag did not reach the tool)");
    assert(isHoleFree(post),
        "0317 redo: post-extrude mesh is not hole-free (drag did not reproduce the "
        ~ "0317 overshoot scenario, or the winding-consistency pass itself regressed)");

    auto u = postUndo();
    assert(u["status"].str == "ok", "0317 redo: undo failed: " ~ u.toString);
    assert(sameGeometry(getModel(), pre),
        "0317 redo: post-undo geometry != pre-extrude grid");

    auto r = postRedo();
    assert(r["status"].str == "ok", "0317 redo: redo failed: " ~ r.toString);
    auto redone = getModel();

    // THE regression assertion: redo must reproduce `post` EXACTLY, including
    // per-face corner ORDER. Pre-fix, MeshEditDelta.apply replayed the
    // pre-flip (folded) faceListsAfter/faceLists the tracker captured before
    // the winding-consistency pass ran, so a face the pass flipped would come
    // back reversed here even though sameGeometry (vertex-SET only) would
    // pass anyway.
    assert(facesExactMatch(post, redone),
        "0317 redo: redo restored FOLDED winding instead of the winding-corrected "
        ~ "mesh (the flip was invisible to the recorded edit-delta)");
    assert(isHoleFree(redone), "0317 redo: redone mesh is not hole-free");

    cmd("undo.tracker.off");
}
