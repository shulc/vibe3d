module document;

import mesh : Mesh;

// source/document.d — imports mesh only; no GL, no render, no UI.
//
// The Document is the single source of truth for the layer list, the active
// (foreground) layer, and the item-selection set.
//
// Selection-types Stage 0 (this file): the item-selection model lands as a
// SET-of-exactly-one — every document has exactly ONE selected layer, which
// equals today's active layer — plus a `primary` reference that aliases the
// active layer. The active accessors (`active()`/`activeMesh()`/
// `activeMeshRef()`) are re-expressed over `primary`, so the ~136 binding
// sites that resolve "the active mesh" stay untouched. `activeIndex` REMAINS a
// stored field in Stage 0 (so there is no LHS hazard at its writers); every
// writer additionally sets `primary` + the one `selected` bool in lockstep via
// `setActive`, keeping the invariant `primary ∈ layers ∧ primary.selected ∧
// ≥1 selected` after every load/import/reset/revert. This is the layers
// Stage-0a/0b pattern: provably byte-neutral, the whole suite is the oracle.
// `background` stays a STORED bool in Stage 0 (it becomes derived in a later
// stage); the `background()` helper below returns the stored value for now.

/// A single document layer. Deliberately a CLASS, for two reasons:
///   (a) the interior `Mesh` sits at a stable heap address no matter how
///       `layers[]` is sliced / reordered / reallocated — the
///       in-place-replacement invariant generalizes per layer;
///   (b) any `Mesh*` captured by a history entry is an interior pointer
///       the GC traces, so a layer whose edits are still on the undo stack
///       cannot dangle even after the layer is deleted from `layers[]`.
final class Layer {
    Mesh   mesh;               ///< the layer's geometry (stable heap address)
    string name;               ///< display name (e.g. "Layer 1")
    bool   visible    = true;  ///< drawn when true
    bool   selected   = false; ///< item selection (foreground membership)
    bool   background = false;  ///< non-editable reference geometry when true
    // reserved (phase 2, survey #3): pivot / transform as registered Params.
    // Held as a comment only here — no per-layer transform plumbing in v1.
}

/// The layer list, the index of the one active (foreground) layer, and the
/// `primary` alias for that active layer.
///
/// Invariants (maintained by every mutator / writer in Stage 0):
///   * `layers.length >= 1` and `activeIndex < layers.length`.
///   * `primary !is null`; `primary` ∈ `layers`; `primary is layers[activeIndex]`.
///   * `primary.selected` is always true; at least one layer is always
///     selected (a SET-of-one in Stage 0).
struct Document {
    Layer[] layers;            ///< flat list; always length >= 1
    size_t  activeIndex;       ///< exactly one active (foreground) layer
    Layer   primary;           ///< most-recently-selected foreground layer
                               ///< (the edit target); == layers[activeIndex].

    /// The active (foreground) layer object — i.e. the primary.
    Layer     active()        { return primary; }
    /// Pointer to the primary layer's mesh (interior pointer, GC-traced).
    Mesh*     activeMesh()    { return &primary.mesh; }
    /// Reference to the primary layer's mesh.
    ref Mesh  activeMeshRef() { return primary.mesh; }

    /// True iff `l` is the primary (the single edit target).
    bool isPrimary(Layer l) const { return l is primary; }

    /// Foreground / background derivation (Stage 0: `background` is still the
    /// stored bool of record, so `background()` returns it to stay neutral;
    /// later stages flip these to `visible && (!)selected`).
    static bool foreground(Layer l) { return l.visible && !l.background; }
    static bool background(Layer l) { return l.background; }

    /// Set the active layer by index, keeping `primary`, `selected`, and
    /// `activeIndex` in lockstep (the Stage-0 SET-of-one invariant). Exactly
    /// the target layer is selected; every other layer is deselected. Callers
    /// MUST invoke this BEFORE any `fireSwitchIfChanged` / switch-hook call so
    /// the hook (which reads `activeMesh()` == primary's mesh) re-uploads the
    /// correct mesh — see the Stage-0 ordering rule.
    void setActive(size_t idx) {
        if (layers.length == 0) { activeIndex = 0; primary = null; return; }
        if (idx >= layers.length) idx = layers.length - 1;
        activeIndex = idx;
        primary     = layers[idx];
        foreach (l; layers) l.selected = false;
        primary.selected = true;
    }

    /// Build a one-layer document from an existing mesh. The mesh is moved
    /// into a fresh "Layer 1" which becomes the (only, active, selected) layer.
    static Document bootstrap(Mesh m) {
        auto l = new Layer;
        l.mesh = m;
        l.name = "Layer 1";
        l.visible = true;
        l.background = false;
        l.selected = true;
        Document d;
        d.layers = [l];
        d.setActive(0);
        return d;
    }
}

// ---------------------------------------------------------------------------
// In-module unit tests (Stage 0 contract: SET-of-one invariants, primary ==
// active, accessor identity, lockstep on every active move). Types only — no
// app.d wiring exercised.
// ---------------------------------------------------------------------------

unittest {
    // bootstrap invariants
    Mesh m;
    auto doc = Document.bootstrap(m);
    assert(doc.layers.length == 1, "bootstrap must yield exactly one layer");
    assert(doc.layers.length >= 1, "layers.length >= 1 contract");
    assert(doc.activeIndex == 0, "bootstrap active layer is index 0");
    assert(doc.active() !is null, "active layer object is non-null");
    assert(doc.active().name == "Layer 1", "bootstrap names the layer 'Layer 1'");
    assert(doc.active().visible, "bootstrap layer is visible");
    assert(!doc.active().background, "bootstrap layer is foreground (not background)");
    // SET-of-one + primary invariants.
    assert(doc.primary !is null, "primary is non-null");
    assert(doc.primary is doc.active(), "primary == active");
    assert(doc.primary is doc.layers[doc.activeIndex], "primary == layers[activeIndex]");
    assert(doc.primary.selected, "primary is selected");
    size_t selCount = 0;
    foreach (l; doc.layers) if (l.selected) ++selCount;
    assert(selCount == 1, "exactly one layer selected (SET-of-one)");
    assert(doc.isPrimary(doc.active()), "isPrimary(active) is true");
}

unittest {
    // accessor identity: active(), activeMesh(), activeMeshRef() all resolve
    // to the same heap mesh; the address is stable across repeated calls.
    Mesh m;
    auto doc = Document.bootstrap(m);

    Mesh* p1 = doc.activeMesh();
    Mesh* p2 = doc.activeMesh();
    assert(p1 is p2, "activeMesh() is stable across calls");

    assert(p1 is &doc.active().mesh,
           "activeMesh() points at the active layer's mesh field");
    assert(&doc.activeMeshRef() is p1,
           "activeMeshRef() and activeMesh() identify the same mesh");
    // primary aliases the active mesh.
    assert(p1 is &doc.primary.mesh, "activeMesh() points at the primary's mesh");

    // Layer is a class: a copy of the Document struct shares the same Layer
    // object (reference), hence the same interior mesh pointer.
    Document doc2 = doc;
    assert(doc2.active() is doc.active(),
           "Document copy shares the same Layer reference (class identity)");
    assert(doc2.activeMesh() is doc.activeMesh(),
           "shared Layer ⇒ shared interior mesh address");
    assert(doc2.primary is doc.primary, "Document copy shares the same primary ref");
}

unittest {
    // multi-layer shape: setActive moves primary/selected/activeIndex in
    // lockstep and the SET-of-one invariant survives every move.
    Mesh m;
    auto doc = Document.bootstrap(m);
    auto l2 = new Layer;
    l2.name = "Layer 2";
    doc.layers ~= l2;
    assert(doc.layers.length == 2);

    Mesh* a0 = doc.activeMesh();
    assert(doc.primary is doc.layers[0] && doc.layers[0].selected);
    assert(!doc.layers[1].selected, "second layer starts deselected");

    doc.setActive(1);
    Mesh* a1 = doc.activeMesh();
    assert(a0 !is a1, "distinct layers have distinct mesh addresses");
    assert(a1 is &doc.layers[1].mesh, "activeMesh() follows the primary");
    assert(doc.activeIndex == 1, "activeIndex tracks the active move");
    assert(doc.primary is doc.layers[1], "primary tracks the active move");
    assert(doc.layers[1].selected && !doc.layers[0].selected,
           "exactly the new active layer is selected (SET-of-one)");
    size_t selCount = 0;
    foreach (l; doc.layers) if (l.selected) ++selCount;
    assert(selCount == 1, "still exactly one selected after the move");

    // setActive clamps an out-of-range index into the last layer.
    doc.setActive(99);
    assert(doc.activeIndex == 1 && doc.primary is doc.layers[1],
           "out-of-range setActive clamps to the last layer");
}
