// add_injection_range_test — the ONE cell that reaches `LayerAdd`'s
// out-of-range refusal.
//
// `LayerAdd.applyImpl` opens with
//
//     if (requestedIndex != size_t.max && requestedIndex > doc.layers.length) {
//         refusal_ = "layer.add: insertion index is out of range";
//         return false;
//     }
//
// and until this file existed nothing could make it fire. `requestedIndex` is
// only ever written by `configureInjection`, whose one caller is the
// `/api/test/layer` handler — and that handler rejects the same condition
// FIRST, with its own `'index' out of range`. So the command's guard sat
// behind A SECOND, UNNAMED GUARD: over HTTP it is unreachable by construction,
// and a mutation deleting it moves no test. That is the "the check cannot come
// out differently" shape, in its purest form — the refusal was neither wrong
// nor absent, it was simply never reached.
//
// Rather than delete a defensive invariant that belongs to the command (the
// route is one caller; the command owns its own preconditions), this reaches
// it the only way that is left: by driving `configureInjection` directly.
//
// ORDER AND POPULATION FLOOR. druntime stops a module at its first failed
// assert, so the assert that must stay GREEN — the boundary index `n`, which
// is an APPEND and must be accepted — is placed ABOVE the one that must go
// RED under a mutation. A single run then buys both halves. The layer count is
// pinned before either, because "the out-of-range index was refused" is
// vacuously satisfiable over a document whose length nobody checked.
module tests.unit.commands.layer.add_injection_range_test;

import std.conv : to;

import mesh     : Mesh;
import view     : View;
import editmode : EditMode;
import document : Document, ItemKind;
import commands.layer.commands : LayerAdd;

private LayerAdd mkAdd(Document* doc, Mesh* m, View v) {
    return new LayerAdd(m, v, EditMode.Vertices, doc, null);
}

unittest {
    Mesh m;
    auto doc = Document.bootstrap(m);
    auto view = new View(0, 0, 800, 600);

    // POPULATION FLOOR. Every claim below is about an index measured against
    // this number; over a document of unknown length "index N+1 was refused"
    // says nothing at all.
    immutable size_t n = doc.layers.length;
    assert(n == 1, "bootstrap gives exactly one layer; got " ~ n.to!string);

    // GREEN HALF, deliberately first: `index == length` is the APPEND
    // boundary and must be ACCEPTED. Without it the refusal below is also
    // satisfied by a guard that refuses everything, which is the mutation the
    // red half cannot distinguish on its own.
    {
        auto ok = mkAdd(&doc, &m, view);
        ok.configureInjection(ItemKind.Mesh, n, "boundary append");
        assert(ok.apply(),
            "index == layers.length is the append boundary and must be "
          ~ "accepted: " ~ ok.refusalReason());
        assert(doc.layers.length == n + 1,
            "the accepted injection must actually have inserted a layer");
        assert(ok.refusalReason().length == 0,
            "an accepted injection carries no refusal reason");
    }

    // RED HALF: one past the boundary, measured against the length AFTER the
    // append above, so the number is not stale.
    {
        immutable size_t len = doc.layers.length;
        auto bad = mkAdd(&doc, &m, view);
        bad.configureInjection(ItemKind.Mesh, len + 1, "one past the end");
        assert(!bad.apply(),
            "an insertion index one past layers.length must be REFUSED");
        assert(bad.refusalReason() == "layer.add: insertion index is out of range",
            "the refusal reason is the command's own, verbatim; got '"
          ~ bad.refusalReason() ~ "'");
        assert(doc.layers.length == len,
            "a refused injection must not have inserted anything");
    }
}
