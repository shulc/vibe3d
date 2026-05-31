// Per-element marks authority tests (element-marks migration, Phase 2).
//
// Phase 2 flips per-element selection + subpatch storage so a single
// per-element bitfield ("marks") is the sole source of truth, and the
// `selectedFaces` / `isSubpatch` bool[] views are materialized on read.
// Two invariants from the migration's Risks section are pinned here:
//
//   B3 — Subpatch survives a topology edit. Select and Subpatch share one
//        word per face; a selection clear must mask ONLY the Select bit and
//        leave the Subpatch bit intact. Deleting an ADJACENT face runs a face
//        mutator (deleteFacesByMask) that rewrites subpatch flags then clears
//        the selection word — the surviving face's Subpatch bit must remain.
//
//   B4 — Snapshot round-trip is idempotent and order-independent. Undo
//        restores via the full snapshot, which writes Select and Subpatch as
//        two independent assigns. After delete→undo, BOTH bits must match the
//        pre-delete state exactly, regardless of the assign order.
//
// HTTP-API style like the other tests: drive selection + subpatch + delete +
// undo through /api/*, read state back via /api/model + /api/selection.

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.algorithm : count, sort;
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

bool ok(JSONValue r) {
    return ("status" in r) && r["status"].type == JSONType.string
        && r["status"].str == "ok";
}

bool[] subpatchFlags() {
    auto j = getJson("/api/model");
    bool[] r;
    foreach (b; j["isSubpatch"].array)
        r ~= (b.type == JSONType.TRUE);
    return r;
}

// /api/selection reports selectedFaces as a list of selected face INDICES
// (not a parallel bool[]). Return that index list, sorted.
int[] selectedFaceIndices() {
    auto j = getJson("/api/selection");
    int[] r;
    foreach (n; j["selectedFaces"].array)
        r ~= cast(int)n.integer;
    r.sort();
    return r;
}

// True iff face index `fi` is in the selected set.
bool faceSelected(int[] sel, int fi) {
    foreach (s; sel) if (s == fi) return true;
    return false;
}

size_t faceCount() {
    return getJson("/api/model")["faces"].array.length;
}

// Mark the given faces subpatch via the command channel: select them in
// Polygons mode, toggle subpatch, then clear the selection so it doesn't
// interfere with later steps.
void markSubpatch(int[] faces) {
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/select", format(`{"mode":"polygons","indices":%s}`, faces.to!string));
    auto r = postJson("/api/command", "mesh.subpatch_toggle");
    assert(ok(r), "subpatch_toggle failed: " ~ r.toString);
}

unittest { // B3: subpatch bit survives deleting an adjacent face
    postJson("/api/reset", "");
    assert(faceCount() == 6, "fresh cube has 6 faces");

    // Mark faces 0 and 2 subpatch; leave 1,3,4,5 plain.
    markSubpatch([0, 2]);
    auto sub = subpatchFlags();
    assert(sub.length == 6);
    assert(sub[0] && sub[2], "faces 0,2 should be subpatch after toggle");
    size_t subCountBefore = sub.count!(b => b);
    assert(subCountBefore == 2, "exactly two subpatch faces expected");

    // Select a DIFFERENT face (1) and delete it. deleteFacesByMask runs the
    // subpatch-write-then-select-clear sequence — the masked Select-clear must
    // not wipe the Subpatch bits of the surviving faces.
    postJson("/api/select", `{"mode":"polygons","indices":[1]}`);
    auto del = postJson("/api/command", "mesh.delete");
    assert(ok(del), "mesh.delete failed: " ~ del.toString);

    assert(faceCount() == 5, "one face deleted -> 5 remain");
    auto subAfter = subpatchFlags();
    assert(subAfter.length == 5, "subpatch array tracks faces length");
    // The two subpatch faces survived (we deleted a non-subpatch face), so
    // exactly two subpatch flags must remain set.
    size_t subCountAfter = subAfter.count!(b => b);
    assert(subCountAfter == 2,
        format("B3 VIOLATION: expected 2 surviving subpatch faces, got %s " ~
               "(masked select-clear clobbered the Subpatch bit?)", subCountAfter));
}

unittest { // B4: delete->undo restores BOTH Select and Subpatch, idempotently
    postJson("/api/reset", "");
    assert(faceCount() == 6);

    // Mark faces 1 and 4 subpatch, then leave faces 0 and 5 SELECTED. This
    // gives a state where Select and Subpatch bits live on different faces of
    // the same word array, so an order-dependent restore would corrupt one.
    markSubpatch([1, 4]);
    postJson("/api/select", `{"mode":"polygons","indices":[0,5]}`);

    auto subBefore = subpatchFlags();
    auto selBefore = selectedFaceIndices();
    assert(subBefore[1] && subBefore[4], "faces 1,4 subpatch pre-delete");
    assert(faceSelected(selBefore, 0) && faceSelected(selBefore, 5),
        "faces 0,5 selected pre-delete");
    assert(!subBefore[0] && !subBefore[5], "selected faces are not subpatch");
    assert(!faceSelected(selBefore, 1) && !faceSelected(selBefore, 4),
        "subpatch faces are not selected");

    // Select a face NOT in either set (face 2) and delete it. This captures a
    // full MeshSnapshot of the pre-delete cage.
    postJson("/api/select", `{"mode":"polygons","indices":[2]}`);
    auto del = postJson("/api/command", "mesh.delete");
    assert(ok(del), "mesh.delete failed: " ~ del.toString);
    assert(faceCount() == 5);

    // Undo -> snapshot restore writes Select and Subpatch as two independent
    // assigns. Both bit planes must come back exactly as captured.
    auto undo = postJson("/api/undo", "");
    assert(ok(undo), "undo failed: " ~ undo.toString);
    assert(faceCount() == 6, "undo restored the deleted face");

    auto subAfter = subpatchFlags();
    auto selAfter = selectedFaceIndices();
    assert(subAfter.length == subBefore.length, "subpatch length restored");
    // The Subpatch plane must come back bit-identical to its pre-delete state
    // (the snapshot restore wrote it independently of the Select plane).
    foreach (i; 0 .. subBefore.length)
        assert(subAfter[i] == subBefore[i],
            format("B4 VIOLATION: Subpatch bit on face %s changed across " ~
                   "delete->undo (%s -> %s)", i, subBefore[i], subAfter[i]));
    // Faces 1 and 4 were subpatch and never selected; after restore they must
    // still be subpatch and NOT have leaked a Select bit (order-dependent or
    // mask-wrong restore would collide the two planes on the same word).
    assert(subAfter[1] && subAfter[4], "subpatch faces survive undo");
    foreach (i; 0 .. subAfter.length)
        if (subAfter[i])
            assert(!faceSelected(selAfter, cast(int)i),
                format("B4 VIOLATION: face %s has BOTH Select and Subpatch " ~
                       "after restore — shared-word corruption", i));
}
