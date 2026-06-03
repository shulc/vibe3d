module test_history_coalesce;

// Phase 2 of the undo/redo migration — op coalescing.
//
// Consecutive COMPATIBLE programmatic edits (same command type, same index
// set, same edit label) collapse into ONE undo entry. The merge keeps the
// FIRST edit's pre-state and adopts the LATEST post-state, so one undo of the
// coalesced entry restores the original pre-first-edit geometry.
//
// The programmatic path under test is /api/command with id "mesh.vertex_edit"
// (the delta command). That id is registered as a command factory and its
// before[]/after[]/indices params are JSON-injectable, so the request funnels
// through commandHandlerDelegate -> history.recordCoalescing() — the exact
// dispatcher site Phase 2 wires. Interactive tool commits do NOT take this
// path (they call history.record() directly) and so never coalesce.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

double jnum(JSONValue v) {
    switch (v.type) {
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        case JSONType.float_:   return v.floating;
        default: throw new Exception("not a number: " ~ v.toString());
    }
}

double[3] vertexPos(int i) {
    auto verts = getJson("/api/model")["vertices"].array;
    auto a = verts[i].array;
    return [jnum(a[0]), jnum(a[1]), jnum(a[2])];
}

size_t historyLen(string side) {
    auto j = getJson("/api/history");
    return j[side].array.length;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}
bool posEq(double[3] a, double[3] b, double eps = 1e-4) {
    return approxEq(a[0], b[0], eps)
        && approxEq(a[1], b[1], eps)
        && approxEq(a[2], b[2], eps);
}

void resetCube() {
    post(baseUrl ~ "/api/reset", "");
    // Wipe the worker-global undo stack. The undo history is shared across
    // every test that runs against this worker's long-lived vibe3d, and
    // /api/reset does NOT clear it (it records a scene.reset entry instead).
    // The stack is capped at maxDepth, so once prior tests saturate it a
    // fresh append evicts the oldest entry and the length stops growing —
    // which breaks the absolute +N length assertions below. Mirrors the
    // clearHistory() convention in test_history_jump.d.
    post(baseUrl ~ "/api/command", "history.clear");
}

// Dispatch a mesh.vertex_edit through /api/command (JSON form) — the
// coalescing dispatcher path. `before`/`after` are the absolute positions
// for the single vertex at index `idx`.
JSONValue vertexEdit(int idx, double[3] before, double[3] after,
                     string label = "Move") {
    string body_ = format(
        `{"id":"mesh.vertex_edit","params":{`
        ~ `"indices":[%d],`
        ~ `"before":[[%.6f,%.6f,%.6f]],`
        ~ `"after":[[%.6f,%.6f,%.6f]]`
        ~ `}}`,
        idx,
        before[0], before[1], before[2],
        after[0],  after[1],  after[2]);
    return postJson("/api/command", body_);
}

JSONValue undoStep() { return postJson("/api/undo", ""); }
JSONValue redoStep() { return postJson("/api/redo", ""); }

// ---------------------------------------------------------------------------
// (a) Two COMPATIBLE edits (same vertex) coalesce into ONE entry; one undo
//     restores the ORIGINAL pre-first-edit geometry.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    int idx = 0;
    double[3] orig = vertexPos(idx);
    size_t baseLen = historyLen("undo");

    double[3] mid  = [orig[0] + 0.10, orig[1], orig[2]];
    double[3] last = [orig[0] + 0.25, orig[1], orig[2]];

    auto r1 = vertexEdit(idx, orig, mid);
    assert(r1["status"].str == "ok", "edit 1: " ~ r1.toString());
    auto r2 = vertexEdit(idx, mid, last);
    assert(r2["status"].str == "ok", "edit 2: " ~ r2.toString());

    // Two compatible edits => undo stack grew by exactly ONE.
    assert(historyLen("undo") == baseLen + 1,
        format("coalesce: expected +1 entry, got +%d",
            historyLen("undo") - baseLen));

    // Mesh is at the LATEST position.
    assert(posEq(vertexPos(idx), last),
        format("after coalesced edits, vert should be at last %s, got %s",
            last, vertexPos(idx)));

    // ONE undo restores the ORIGINAL pre-FIRST-edit geometry (proves the
    // merge kept the older before[]).
    auto u = undoStep();
    assert(u["status"].str == "ok", "undo: " ~ u.toString());
    assert(posEq(vertexPos(idx), orig),
        format("one undo of the coalesced entry should restore ORIGINAL %s, "
            ~ "got %s", orig, vertexPos(idx)));
    assert(historyLen("undo") == baseLen,
        "after undo, undo stack should be back to baseline length");
}

// ---------------------------------------------------------------------------
// (b) Two edits on DIFFERENT index sets => TWO entries (compareOp Different).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    double[3] o0 = vertexPos(0);
    double[3] o1 = vertexPos(1);
    size_t baseLen = historyLen("undo");

    auto r1 = vertexEdit(0, o0, [o0[0] + 0.10, o0[1], o0[2]]);
    assert(r1["status"].str == "ok", r1.toString());
    auto r2 = vertexEdit(1, o1, [o1[0] + 0.10, o1[1], o1[2]]);
    assert(r2["status"].str == "ok", r2.toString());

    assert(historyLen("undo") == baseLen + 2,
        format("different index sets => 2 entries, got +%d",
            historyLen("undo") - baseLen));
}

// ---------------------------------------------------------------------------
// (c) An intervening DIFFERENT command (mesh.select) between two otherwise
//     compatible edits => TWO entries (the top is no longer a compatible
//     MeshVertexEdit).
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    int idx = 2;
    double[3] orig = vertexPos(idx);
    size_t baseLen = historyLen("undo");

    auto r1 = vertexEdit(idx, orig, [orig[0] + 0.10, orig[1], orig[2]]);
    assert(r1["status"].str == "ok", r1.toString());

    // Intervening selection edit lands its own entry on top.
    auto s = postJson("/api/select", `{"mode":"vertices","indices":[0,1]}`);
    // /api/select returns {"status":"ok"} on success.
    assert(s["status"].str == "ok", "select: " ~ s.toString());

    auto r2 = vertexEdit(idx,
        [orig[0] + 0.10, orig[1], orig[2]],
        [orig[0] + 0.20, orig[1], orig[2]]);
    assert(r2["status"].str == "ok", r2.toString());

    // edit + select + edit => 3 entries (the second edit could NOT coalesce
    // because the top entry was the selection, not the first edit).
    assert(historyLen("undo") == baseLen + 3,
        format("intervening command should block coalesce: expected +3 "
            ~ "entries, got +%d", historyLen("undo") - baseLen));
}

// ---------------------------------------------------------------------------
// (d) Redo hygiene: after a coalesced merge the redo stack is empty, and a
//     normal undo of the coalesced entry works.
// ---------------------------------------------------------------------------
unittest {
    resetCube();

    int idx = 3;
    double[3] orig = vertexPos(idx);

    // Lay down a single edit, then undo it to populate the redo stack.
    auto r1 = vertexEdit(idx, orig, [orig[0] + 0.10, orig[1], orig[2]]);
    assert(r1["status"].str == "ok", r1.toString());
    auto u0 = undoStep();
    assert(u0["status"].str == "ok", u0.toString());
    assert(historyLen("redo") >= 1, "redo should be populated after undo");

    // Re-apply via redo so we have a top entry to coalesce into, plus a clean
    // (empty) redo stack again afterwards.
    auto rr = redoStep();
    assert(rr["status"].str == "ok", rr.toString());

    // Now undo once more to repopulate redo, then dispatch a compatible edit
    // that does NOT match the top entry's after — but first redo to restore.
    // Simpler: undo to leave a redo entry, redo to consume it (redo empty),
    // then verify a fresh compatible edit coalesces AND leaves redo empty.
    auto u1 = undoStep();        // redo now has 1
    assert(u1["status"].str == "ok", u1.toString());
    assert(historyLen("redo") >= 1, "redo populated before coalesce");

    // Re-apply the first edit (redo), making it the top entry again with an
    // empty redo stack.
    auto rr2 = redoStep();
    assert(rr2["status"].str == "ok", rr2.toString());

    // A second compatible edit must coalesce (no new entry) and, critically,
    // MUST clear redo if anything were lingering. Build a lingering redo entry
    // first: do a throwaway edit on a DIFFERENT vertex, undo it.
    double[3] o9 = vertexPos(4);
    auto tmp = vertexEdit(4, o9, [o9[0] + 0.10, o9[1], o9[2]]);
    assert(tmp["status"].str == "ok", tmp.toString());
    auto ut = undoStep();        // redo now holds the vertex-4 edit
    assert(ut["status"].str == "ok", ut.toString());
    assert(historyLen("redo") >= 1, "redo should hold the throwaway edit");

    size_t undoBefore = historyLen("undo");

    // Now the top undo entry is the vertex-`idx` edit again. A COMPATIBLE
    // continuation of it must MERGE (no new entry) AND clear the redo stack
    // (Invariant 1).
    double[3] cur = vertexPos(idx);
    auto rc = vertexEdit(idx, cur, [cur[0] + 0.10, cur[1], cur[2]]);
    assert(rc["status"].str == "ok", rc.toString());

    assert(historyLen("undo") == undoBefore,
        format("coalesced edit must NOT add an entry: %d -> %d",
            undoBefore, historyLen("undo")));
    assert(historyLen("redo") == 0,
        "MANDATORY: a coalesced merge must clear the redo stack");

    // The coalesced entry still undoes cleanly.
    auto uf = undoStep();
    assert(uf["status"].str == "ok", uf.toString());
    assert(posEq(vertexPos(idx), orig),
        format("undo of coalesced entry should restore original %s, got %s",
            orig, vertexPos(idx)));
}
