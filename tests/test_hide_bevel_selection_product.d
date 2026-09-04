// Task 1330 — a command's PRODUCT SELECTION must not depend on whether the
// hide-derive was batched.
//
// ---------------------------------------------------------------------------
// THE BUG THIS PINS (found by adversarial review, reproduced live)
// ---------------------------------------------------------------------------
// `Mesh.rebuildEdges()` gives `edges` an entirely new index space but does NOT
// re-index `edgeMarks` — `mesh_edit_delta.d`'s own comment states the hazard:
// until the following derive runs, `edgeMarks[ei]`'s Hide bit is whatever
// stale word already sat at position `ei`, and `selectEdge` FILTERS AGAINST
// those stale bits.
//
// What used to clear them for free was the per-`addEdge` commit inside
// rebuildEdges: each one ran `refreshHiddenDerived()`. Task 1330 batches that
// derive — and the first cut of the batch deferred it unconditionally, so the
// stale bits survived until the end of the command. `selectEdge` refused every
// edge whose STALE bit was set, the end-of-command derive then cleared the bit,
// and the Select bit was never written. The refusal is silent and permanent.
//
// Direction matters, and it is why only one half of this self-heals: a stale
// CLEAR is fixed by the closing derive (the element gets hidden, and Select is
// stripped with it); a stale SET is not (the refusal already happened).
//
// The fix keeps the derive eager whenever ANYTHING is hidden — deferral is
// allowed only in the state where `refreshHiddenDerived` provably writes
// nothing (its own three-plane word-OR early-out). This file drives the exact
// user-visible consequence rather than the internal flag.
//
// ---------------------------------------------------------------------------
// WHY THIS FIXTURE, AND WHY IT IS NOT VACUOUS
// ---------------------------------------------------------------------------
// Hiding vertex 0's three incident faces (`mesh.hide` over vertex 0 hides
// faces 0, 2, 5) derives vertex 0 hidden AND edges 0, 3, 8 hidden. Bevelling
// edge 9 then rebuilds the edge array, so indices 0/3/8 land on DIFFERENT
// edges of the product — exactly the elements the stale bits refuse.
//
// The expected sets below were measured on `main` (the un-batched code) and
// are the oracle: with the bug, edge 8 is missing from the first row and edge
// 3 from the second — two of the three pre-bevel hidden indices. A test that
// only asserted "the command returned ok" passes with the bug fully present,
// and one that asserted only the vertex plane passes too (rebuildEdges does
// not re-index vertexMarks, so the vertex product is identical either way).
import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : sort;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

int[] selectedEdges() {
    auto sel = getJson("/api/selection");
    int[] out_;
    if (auto p = "selectedEdges" in sel)
        foreach (v; p.array) out_ ~= cast(int) v.integer;
    out_.sort();
    return out_;
}

// hide vertex 0's faces → bevel one edge → what did the command leave selected?
int[] beveledProduct(int operandEdge) {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);

    cmd("select.typeFrom vertex");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    cmd(`{"id":"mesh.hide"}`);

    cmd("select.typeFrom edge");
    postJson("/api/select",
             `{"mode":"edges","indices":[` ~ operandEdge.to!string ~ `]}`);
    cmd(`{"id":"mesh.bevel"}`);
    return selectedEdges();
}

unittest { // operand edge 9 — the product keeps edge 8
    auto got = beveledProduct(9);
    assert(got == [1, 8, 11, 14],
           "edge bevel next to hidden geometry lost part of its product "
           ~ "selection: got " ~ got.to!string ~ ", expected [1, 8, 11, 14]");
}

unittest { // operand edge 11 — the product keeps edge 3
    auto got = beveledProduct(11);
    assert(got == [3, 6, 13, 14],
           "edge bevel next to hidden geometry lost part of its product "
           ~ "selection: got " ~ got.to!string ~ ", expected [3, 6, 13, 14]");
}
