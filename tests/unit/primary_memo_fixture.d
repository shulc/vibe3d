// Shared fixture for the `Document.primary` memo cells (task 4061 review).
//
// The cells live in SIX modules on purpose, not in one. druntime stops a
// module at its first failed assert, so two paths that must redden under two
// different mutations cannot both be demonstrated from one module — and the
// masking the review found (a revert path that invalidates twice, so neither
// call is individually witnessed) is exactly what a shared module reproduces
// at the test level. One module per mutation-group means a single run reports
// every red it earned, each with its own message.
//
// This module holds no unittest of its own: it is the builder the cells share
// so that six copies of an eight-layer document cannot drift apart.
module tests.unit.primary_memo_fixture;

import document;
import mesh   : Mesh;
import params : Param;
import std.format : format;

/// `n` mesh-kind layers. Layer 0 arrives selected (bootstrap's `setActive`);
/// the rest are appended and are not selected, focused or seated.
///
/// The appends go through `~=` + `noteLayerListChanged()` — the shape every
/// production add uses — so a cell that then mutates the list is mutating a
/// document assembled the way the app assembles one.
Document layeredDocument(size_t n)
in (n >= 1, "fixture: a document has at least the bootstrap layer")
{
    Mesh m;
    auto doc = Document.bootstrap(m);
    foreach (i; 1 .. n) {
        auto l = new Layer;
        l.name    = format("Layer %d", i + 1);
        l.visible = true;
        doc.layers ~= l;
    }
    doc.noteLayerListChanged();
    assert(doc.layers.length == n,
        "fixture population floor: the cells below all assume exactly n layers");
    return doc;
}

/// Write an `int` command parameter by NAME. The layer commands keep their
/// argument fields private and expose them only through `params()`, and these
/// cells live outside `commands.layer.commands`, so this is how a cell drives
/// the REAL command rather than a hand-rolled copy of its splice.
void setIntParam(C)(C cmd, string name, int value) {
    foreach (ref p; cmd.params())
        if (p.name == name) {
            assert(p.kind == Param.Kind.Int,
                "fixture: '" ~ name ~ "' is not an int parameter");
            *p.iptr = value;
            return;
        }
    assert(false, "fixture: no parameter named '" ~ name ~ "'");
}
