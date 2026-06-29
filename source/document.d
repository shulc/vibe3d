module document;

import mesh    : Mesh;
import seltype : SelMode;
import math    : Vec3, identityMatrix, translationMatrix, matrixFromEulerZYX,
                 pivotScaleMatrix, matMul4;

// source/document.d — imports mesh only; no GL, no render, no UI.
//
// The Document is the single source of truth for the layer list, the active
// (foreground) layer, and the item-selection set.
//
// Selection-types Stage 0/2a/2b (this file): the item-selection model.
//
// Stage 0 landed the SET-of-exactly-one — every document had exactly ONE
// selected layer (today's active layer) — plus a `primary` reference aliasing
// the active layer. The active accessors (`active()`/`activeMesh()`/
// `activeMeshRef()`) are re-expressed over `primary`, so the ~136 binding sites
// that resolve "the active mesh" stay untouched.
//
// Stage 2a added the REAL multi-select mutators — `selectItem(l, mode)` +
// `setPrimary(l)` — implementing the uniform {set,add,remove,toggle} model with
// the full invariants (always ≥1 selected; primary always selected + visible;
// hide-primary promotion). Multi-foreground is now a representable DATA state,
// but EDITING still binds the primary only.
//
// **Stage 2b (this stage) collapses the third state.** The stored per-layer
// `bool background` field is GONE; `background(l) == l.visible && !l.selected`
// is now the SOLE (derived) source of truth, read by the snap source, both draw
// guards, `/api/layers`, and the panel. There is no longer any path that can
// desync background from `!selected` — the legacy `layer.setBackground` command
// is GONE (Stage 5); callers dispatch `layer.select mode:add/remove` directly.
// `activeIndex` is now a DERIVED
// read-only accessor (`return index of primary`) — every former writer routes
// through `setActive` / `selectItem` / `setPrimary`, which set `primary`; the
// index follows the primary OBJECT by identity, so reorder/delete renumbering
// can never drift it.

/// A per-layer (item) transform: position / euler-rotation-in-degrees / scale,
/// about a pivot. Authored as four separate `Vec3` channels (the source of
/// truth); the world matrix is a DERIVED runtime value composed on demand by
/// `composedMatrix()` and is never itself an authored field.
///
/// Survey #3 Phase 0: this is the data model only. No render / IO / forms /
/// command wiring yet (those are P1-P4); the field is unused by the rest of the
/// app after P0 — that is expected.
struct ItemXform {
    // NOTE: Vec3's components are plain `float`, so their `.init` is NaN, not 0.
    // Every field needs an explicit zero/unit initialiser so a default-
    // constructed ItemXform composes to identity (not a NaN matrix).
    Vec3 pos   = Vec3(0, 0, 0); ///< translation
    Vec3 rot   = Vec3(0, 0, 0); ///< euler rotation in DEGREES (applied ZYX)
    Vec3 scl   = Vec3(1, 1, 1); ///< per-axis scale (default = unit)
    Vec3 pivot = Vec3(0, 0, 0); ///< pivot point for rotation + scale

    /// The composed world matrix (column-major `float[16]`), in the exact
    /// order declared by the plan:
    ///
    ///     M = T(pos) · T(pivot) · Rz·Ry·Rx · S · T(-pivot)
    ///
    /// ZYX euler, rotations in degrees. The rotation block is built by
    /// `matrixFromEulerZYX` (R = Rz·Ry·Rx), the scale block by an origin-pivot
    /// `pivotScaleMatrix` (pure `diag(scl)`), and the pivot is bracketed by
    /// `T(pivot) … T(-pivot)` so rotation + scale fix the pivot point. The
    /// default `ItemXform` (pos=0, rot=0, scl=1, pivot=0) yields identity.
    ///
    /// Pure: composes from the matrix helpers in `math.d`; no hand-rolled matrix.
    float[16] composedMatrix() const {
        float[16] T    = translationMatrix(pos);
        float[16] Tp   = translationMatrix(pivot);
        float[16] R    = matrixFromEulerZYX(rot);
        float[16] S    = pivotScaleMatrix(Vec3(0, 0, 0), scl.x, scl.y, scl.z);
        float[16] Tpi  = translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z));
        // M = T · Tp · R · S · Tpi  (left-to-right composition order)
        return matMul4(T,
               matMul4(Tp,
               matMul4(R,
               matMul4(S, Tpi))));
    }
}

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
    // Stage 2b: the stored `bool background` field is DELETED. Background is now
    // derived — `Document.background(l) == l.visible && !l.selected` — with no
    // separate field of record (the third state collapsed).
    // Survey #3 Phase 0: per-layer (item) transform/pivot. Authored as four
    // separate `Vec3` channels (pos/rot/scl/pivot); the world matrix is derived
    // via `xform.composedMatrix()`. Render/IO/forms/command wiring is P1-P4 —
    // after P0 this field is unused by the rest of the app (data model only).
    ItemXform xform;
    // Task 0082 — single-level item-parent reference. Nullable; null = no parent.
    // The Layer class (stable heap identity, GC-traced) makes this ref
    // reorder/delete-renumber-safe. Not persisted to .v3d in this task —
    // save/reload drops the parent link silently. One level only: Parent mode
    // reads `l.parent` directly (no ancestor-chain walk).
    Layer parent;
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
    Layer   primary;           ///< most-recently-selected foreground layer
                               ///< (the edit target); == layers[activeIndex].

    /// The index of the active (foreground) layer — DERIVED (Stage 2b) from the
    /// `primary` object's position in `layers`. Read-only: there is no stored
    /// field and no assignment LHS; every former writer routes through
    /// `setActive` / `selectItem` / `setPrimary` (which move `primary`). Because
    /// it follows the primary by IDENTITY, reorder/delete renumbering can never
    /// drift it. Returns 0 when `primary` is not found (degenerate; should never
    /// happen given the invariants).
    size_t activeIndex() const {
        foreach (i, l; layers) if (l is primary) return i;
        return 0;
    }

    /// The active (foreground) layer object — i.e. the primary.
    Layer     active()        { return primary; }
    /// Pointer to the primary layer's mesh (interior pointer, GC-traced).
    Mesh*     activeMesh()    { return &primary.mesh; }
    /// Reference to the primary layer's mesh.
    ref Mesh  activeMeshRef() { return primary.mesh; }

    /// True iff `l` is the primary (the single edit target).
    bool isPrimary(const(Layer) l) const { return l is primary; }

    /// Foreground / background DERIVATION (Stage 2b: the SOLE source of truth).
    ///
    /// `foreground(l) == l.visible &&  l.selected`,
    /// `background(l) == l.visible && !l.selected`.
    ///
    /// The stored `bool background` field is gone — these helpers ARE the truth.
    /// Read by the snap source, both draw guards, `/api/layers`, and the panel
    /// "foreground" indicator. Accept `const(Layer)` so const consumers (e.g.
    /// the `ref const Document` writer) can call them.
    static bool foreground(const(Layer) l) { return l.visible &&  l.selected; }
    static bool background(const(Layer) l) { return l.visible && !l.selected; }

    /// Set the active layer by index, keeping `primary` and `selected` in
    /// lockstep (the Stage-0 SET-of-one invariant). Exactly the target layer is
    /// selected; every other layer is deselected. `activeIndex` follows `primary`
    /// by derivation (Stage 2b) — no index to write here. Callers MUST invoke
    /// this BEFORE any `fireSwitchIfChanged` / switch-hook call so the hook
    /// (which reads `activeMesh()` == primary's mesh) re-uploads the correct
    /// mesh — see the Stage-0 ordering rule.
    void setActive(size_t idx) {
        if (layers.length == 0) { primary = null; return; }
        if (idx >= layers.length) idx = layers.length - 1;
        primary = layers[idx];
        foreach (l; layers) l.selected = false;
        primary.selected = true;
    }

    // -----------------------------------------------------------------------
    // Stage 2a/2b multi-select mutators. They maintain the load-bearing
    // invariant contract (≥1 selected; primary selected+visible; hide-primary
    // promotes). `activeIndex` derives from `primary`, so no index bookkeeping
    // is needed and no stored `background` bool is touched (Stage 2b deleted it).
    // -----------------------------------------------------------------------

    /// The most-recent remaining selected+visible layer OTHER than `exclude`,
    /// or null if none. v1 has no per-pick order counter (declared divergence
    /// B9), so "most recent" is approximated by scanning the list — adequate
    /// for the single-primary edit model. Used by hide-primary / remove-primary
    /// promotion.
    private Layer anotherSelectedVisible(Layer exclude) {
        foreach (l; layers)
            if (l !is exclude && l.selected && l.visible) return l;
        return null;
    }

    /// The single item-select mutator. Mirrors `mode:{set,add,remove,toggle}`.
    /// Invariants held on return: `primary !is null`, `primary ∈ layers`,
    /// `primary.selected`, at least one layer selected. `background` is fully
    /// derived (Stage 2b) — there is no stored bool to keep in sync.
    void selectItem(Layer l, SelMode mode) {
        if (layers.length == 0 || l is null) return;

        final switch (mode) {
            case SelMode.Set:
                // Exclusive: deselect everyone, select l, l becomes primary.
                foreach (x; layers) x.selected = false;
                l.selected = true;
                primary = l;
                break;

            case SelMode.Add:
                l.selected = true;
                primary = l;                 // newest-selected becomes primary
                break;

            case SelMode.Remove:
                if (!l.selected) break;       // not selected → nothing to do
                if (l is primary) {
                    // Removing the primary: promote the most-recent remaining
                    // selected+visible layer. If none exists, this would empty
                    // the set / leave no visible primary → refuse (no-op).
                    auto promote = anotherSelectedVisible(l);
                    if (promote is null) break;   // last-selected remove = no-op
                    l.selected = false;
                    primary = promote;
                } else {
                    // Non-primary remove is always safe (primary still holds the
                    // ≥1-selected invariant).
                    l.selected = false;
                }
                break;

            case SelMode.Toggle:
                if (l.selected) selectItem(l, SelMode.Remove);
                else            selectItem(l, SelMode.Add);
                return;
        }
        // primary remains the edit target; activeIndex derives from it on read.
    }

    /// Promote an already-selected layer to primary (the edit target) without
    /// changing the selected set. If `l` is not selected this selects it (Add
    /// semantics) so the primary invariant (`primary.selected`) holds.
    void setPrimary(Layer l) {
        if (layers.length == 0 || l is null) return;
        if (!l.selected) l.selected = true;
        primary = l;
    }

    /// Hide-primary promotion helper (called by the setVisible command path).
    /// Hiding the primary moves the primary to another selected+visible layer
    /// when one exists; returns false (refuse) when the primary is the only
    /// selected+visible layer (the caller then leaves it visible). Does NOT
    /// itself flip the `visible` flag — the command owns that, calling this
    /// AFTER setting visible=false to re-establish a visible primary.
    bool promoteAwayFromHiddenPrimary() {
        if (primary is null || primary.visible) return true;  // nothing to do
        auto promote = anotherSelectedVisible(primary);
        if (promote is null) return false;                    // refuse
        primary = promote;
        return true;
    }

    /// Build a one-layer document from an existing mesh. The mesh is moved
    /// into a fresh "Layer 1" which becomes the (only, active, selected) layer.
    static Document bootstrap(Mesh m) {
        auto l = new Layer;
        l.mesh = m;
        l.name = "Layer 1";
        l.visible = true;
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
    assert(!Document.background(doc.active()), "bootstrap layer is foreground (not background)");
    assert(Document.foreground(doc.active()), "bootstrap layer is foreground (derived)");
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

// ---------------------------------------------------------------------------
// Stage 2a/2b contract: the multi-select mutators + the FULLY DERIVED
// background/foreground rule. A shared helper asserts the load-bearing
// invariants AND that the derived helpers track `selected`/`visible` exactly
// (there is no longer any stored bool — Stage 2b deleted it).
// ---------------------------------------------------------------------------

private void assertDocInvariants(ref Document d) {
    assert(d.layers.length >= 1, "layers.length >= 1");
    assert(d.primary !is null, "primary non-null");
    bool primaryInLayers = false;
    size_t selCount = 0;
    foreach (l; d.layers) {
        if (l is d.primary) primaryInLayers = true;
        if (l.selected) ++selCount;
        // Background is the SOLE derived rule now: visible && !selected.
        assert(Document.background(l) == (l.visible && !l.selected),
            "derived background() == visible && !selected");
        assert(Document.foreground(l) == (l.visible && l.selected),
            "derived foreground() == visible && selected");
        // A layer is never simultaneously foreground and background.
        assert(!(Document.foreground(l) && Document.background(l)),
            "foreground and background are mutually exclusive");
    }
    assert(primaryInLayers, "primary is a member of layers");
    assert(d.primary.selected, "primary is selected");
    assert(selCount >= 1, "at least one layer is always selected");
    // activeIndex (derived) tracks the primary by identity.
    assert(d.layers[d.activeIndex] is d.primary, "activeIndex points at primary");
}

// Build a 3-layer document A/B/C, A primary+selected (SET-of-one), for the
// mutator tests. All meshes default-constructed (geometry irrelevant here).
private Document threeLayerDoc() {
    Mesh m;
    auto doc = Document.bootstrap(m);          // Layer 1 (A) selected primary
    auto b = new Layer; b.name = "B"; doc.layers ~= b;
    auto c = new Layer; c.name = "C"; doc.layers ~= c;
    doc.setActive(0);                          // A primary, B/C deselected
    return doc;
}

unittest {  // mode:set is exclusive — equals today's setActive behaviour.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b, "set makes the target primary");
    assert(b.selected && !a.selected && !c.selected, "set is exclusive");
    size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
    assert(sel == 1, "set leaves exactly one selected");
}

unittest {  // mode:add accumulates selection and promotes primary.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && !c.selected, "add keeps prior selection");
    assert(doc.primary is b, "add promotes the newest to primary");
    doc.selectItem(c, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && c.selected, "three selected (multi-foreground)");
    assert(doc.primary is c, "newest add is primary");
}

unittest {  // mode:remove of the primary moves primary to a remaining member.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary
    doc.selectItem(c, SelMode.Add);            // A,B,C selected; C primary
    doc.selectItem(c, SelMode.Remove);         // remove primary C
    assertDocInvariants(doc);
    assert(!c.selected, "C deselected");
    assert(doc.primary is a || doc.primary is b, "primary promoted to a remainder");
    assert(doc.primary.selected, "promoted primary is selected");
}

unittest {  // mode:remove of a NON-primary keeps the primary.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary
    doc.selectItem(a, SelMode.Remove);         // remove non-primary A
    assertDocInvariants(doc);
    assert(!a.selected && b.selected, "A deselected, B remains");
    assert(doc.primary is b, "primary unchanged on non-primary remove");
}

unittest {  // mode:remove of the LAST selected is a no-op (≥1 invariant).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];
    doc.selectItem(a, SelMode.Remove);         // A is the only selected
    assertDocInvariants(doc);
    assert(a.selected, "cannot deselect the last selected layer");
    assert(doc.primary is a, "primary unchanged on last-selected remove");
}

unittest {  // mode:toggle flips selection (remove ↔ add).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Toggle);         // B not selected → add, primary
    assertDocInvariants(doc);
    assert(b.selected && doc.primary is b, "toggle-on selects + promotes");
    doc.selectItem(b, SelMode.Toggle);         // B selected → remove
    assertDocInvariants(doc);
    assert(!b.selected, "toggle-off deselects");
    assert(doc.primary is a, "primary fell back to remaining selected A");
}

unittest {  // setPrimary promotes an already-selected member without reselecting.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary
    doc.setPrimary(a);                         // promote A (already selected)
    assertDocInvariants(doc);
    assert(a.selected && b.selected, "set is preserved");
    assert(doc.primary is a, "setPrimary moved the edit target to A");
    // setPrimary on a not-yet-selected layer selects it (primary.selected inv).
    auto c = doc.layers[2];
    doc.setPrimary(c);
    assertDocInvariants(doc);
    assert(c.selected && doc.primary is c, "setPrimary selects + promotes");
}

unittest {  // hide-primary promotion: setVisible(false) on primary moves it.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary
    // Simulate the command: hide the primary, then promote.
    b.visible = false;
    auto ok = doc.promoteAwayFromHiddenPrimary();
    assert(ok, "promotion succeeds (A is selected+visible)");
    assertDocInvariants(doc);                  // primary must be visible now
    assert(doc.primary is a, "primary moved to the visible selected A");
    assert(doc.primary.visible, "promoted primary is visible");
}

unittest {  // hide-primary refusal: no other selected+visible layer.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];                     // only A selected
    a.visible = false;
    auto ok = doc.promoteAwayFromHiddenPrimary();
    assert(!ok, "refuse — no other selected+visible layer to promote");
    // Document is left with the (now hidden) primary; the command restores
    // visibility on refusal (tested at the command layer).
}

// ---------------------------------------------------------------------------
// Survey #3 Phase 0: ItemXform.composedMatrix() correctness.
//
// The default xform (pos=0, rot=0, scl=1, pivot=0) MUST equal identity. A known
// {pos,rot_deg,scl,pivot} must produce the expected 4×4 — computed here by an
// INDEPENDENT hand formula (NOT by calling composedMatrix), so fixture and code
// cannot agree tautologically and hide a bug. Order under test:
//     M = T(pos) · T(pivot) · Rz·Ry·Rx · S · T(-pivot)  (ZYX, degrees).
// ---------------------------------------------------------------------------

unittest {  // default ItemXform composes to identity (within 1e-6).
    import std.math : isClose;
    import math : identityMatrix;
    ItemXform x;                       // pos=0, rot=0, scl=1, pivot=0
    auto m = x.composedMatrix();
    foreach (i; 0 .. 16)
        assert(isClose(m[i], identityMatrix[i], 1e-6f, 1e-6f),
               "default ItemXform must compose to identity");
}

unittest {  // pure translation (no rot/scale/pivot) → translation in column 3.
    import std.math : isClose;
    ItemXform x;
    x.pos = Vec3(3, -2, 5);
    auto m = x.composedMatrix();
    // Column-major: translation at m[12],m[13],m[14]; 3×3 block = identity.
    assert(isClose(m[12], 3,  1e-6f, 1e-6f));
    assert(isClose(m[13], -2, 1e-6f, 1e-6f));
    assert(isClose(m[14], 5,  1e-6f, 1e-6f));
    assert(isClose(m[0], 1, 1e-6f, 1e-6f) && isClose(m[5], 1, 1e-6f, 1e-6f)
        && isClose(m[10], 1, 1e-6f, 1e-6f));
}

unittest {  // known TRS-about-pivot vs an INDEPENDENT hand-built expected matrix.
    import std.math : sin, cos, PI, isClose;

    // Inputs.
    Vec3 pos   = Vec3(1, 2, 3);
    Vec3 rdeg  = Vec3(0, 90, 0);          // 90° about Y only (clean closed form)
    Vec3 scl   = Vec3(2, 3, 4);
    Vec3 pivot = Vec3(0.5f, -1.0f, 0.25f);

    ItemXform x;
    x.pos = pos; x.rot = rdeg; x.scl = scl; x.pivot = pivot;
    auto got = x.composedMatrix();

    // ---- Independent expected matrix (column-major m[row + col*4]) ----------
    // R = Ry(90°): cos=0, sin=1. Column-major rotation about Y:
    //   Rcol = [ c 0 -s | 0 1 0 | s 0 c ] (rows) →
    //   [r00 r01 r02; r10 r11 r12; r20 r21 r22] = [0 0 1; 0 1 0; -1 0 0].
    double c = cos(90.0 * PI / 180.0), s = sin(90.0 * PI / 180.0);
    double[3][3] R = [
        [ c,   0.0,  s  ],
        [ 0.0, 1.0,  0.0],
        [-s,   0.0,  c  ],
    ];
    // RS = R · diag(scl)  (scale columns).
    double[3][3] RS;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3)
        RS[i][j] = R[i][j] * [scl.x, scl.y, scl.z][j];
    // Linear part L = RS (rotation+scale, pivot only affects translation).
    // Translation: from M = T(pos)·T(pivot)·RS_about_origin·T(-pivot), the
    // about-pivot affine offset for a linear map L is  pivot - L·pivot, then
    // shifted by pos+pivot folded as: t = pos + (pivot - L·pivot).
    double[3] piv = [pivot.x, pivot.y, pivot.z];
    double[3] Lpiv;
    foreach (i; 0 .. 3)
        Lpiv[i] = RS[i][0]*piv[0] + RS[i][1]*piv[1] + RS[i][2]*piv[2];
    double[3] t = [
        pos.x + (piv[0] - Lpiv[0]),
        pos.y + (piv[1] - Lpiv[1]),
        pos.z + (piv[2] - Lpiv[2]),
    ];
    // Assemble expected column-major float[16]: exp[row + col*4].
    double[16] exp;
    foreach (col; 0 .. 3) foreach (row; 0 .. 3)
        exp[row + col*4] = RS[row][col];
    exp[3] = exp[7] = exp[11] = 0;
    exp[12] = t[0]; exp[13] = t[1]; exp[14] = t[2]; exp[15] = 1;

    foreach (i; 0 .. 16)
        assert(isClose(got[i], cast(float)exp[i], 1e-5f, 1e-5f),
               "composedMatrix mismatch vs independent hand formula at index");
}
