module document;

import mesh : Mesh;

// source/document.d — imports mesh only; no GL, no render, no UI.
//
// The Document is the single source of truth for the layer list and the
// active (foreground) layer. In Stage 0a it is NOT yet instantiated by
// app.d — the types and their invariants land here so the resolver/seam
// conversions in the rest of Stage 0a have a target to grow into. The
// global `Mesh mesh` local in app.d is untouched until Stage 0b.

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
    bool   background = false;  ///< non-editable reference geometry when true
    // reserved (phase 2, survey #3): pivot / transform as registered Params.
    // Held as a comment only here — no per-layer transform plumbing in v1.
}

/// The layer list plus the index of the one active (foreground) layer.
/// Invariant: `layers.length >= 1` and `activeIndex < layers.length`.
struct Document {
    Layer[] layers;            ///< flat list; always length >= 1
    size_t  activeIndex;       ///< exactly one active (foreground) layer

    /// The active (foreground) layer object.
    Layer     active()        { return layers[activeIndex]; }
    /// Pointer to the active layer's mesh (interior pointer, GC-traced).
    Mesh*     activeMesh()    { return &layers[activeIndex].mesh; }
    /// Reference to the active layer's mesh.
    ref Mesh  activeMeshRef() { return layers[activeIndex].mesh; }

    /// Build a one-layer document from an existing mesh. The mesh is moved
    /// into a fresh "Layer 1" which becomes the (only, active) layer.
    static Document bootstrap(Mesh m) {
        auto l = new Layer;
        l.mesh = m;
        l.name = "Layer 1";
        l.visible = true;
        l.background = false;
        Document d;
        d.layers = [l];
        d.activeIndex = 0;
        return d;
    }
}

// ---------------------------------------------------------------------------
// In-module unit tests (Stage 0a contract: accessor identity, bootstrap
// invariants, layers.length >= 1). Types only — no app.d wiring exercised.
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

    // Layer is a class: a copy of the Document struct shares the same Layer
    // object (reference), hence the same interior mesh pointer.
    Document doc2 = doc;
    assert(doc2.active() is doc.active(),
           "Document copy shares the same Layer reference (class identity)");
    assert(doc2.activeMesh() is doc.activeMesh(),
           "shared Layer ⇒ shared interior mesh address");
}

unittest {
    // multi-layer shape (types only — no commands yet): the active accessors
    // track activeIndex and each Layer holds its own distinct mesh address.
    Mesh m;
    auto doc = Document.bootstrap(m);
    auto l2 = new Layer;
    l2.name = "Layer 2";
    doc.layers ~= l2;
    assert(doc.layers.length == 2);

    Mesh* a0 = doc.activeMesh();
    doc.activeIndex = 1;
    Mesh* a1 = doc.activeMesh();
    assert(a0 !is a1, "distinct layers have distinct mesh addresses");
    assert(a1 is &doc.layers[1].mesh, "activeMesh() follows activeIndex");
}
