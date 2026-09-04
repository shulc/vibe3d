module document;

import mesh    : Mesh, detachedPreparedMesh, canBeginPreparedMesh,
                 installPreparedMeshImage, beginPreparedShadow,
                 drainPreparedShadowDelivery, PreparedShadowScope;
import change_bus : PreparedMeshSubjectOwner,
                    PreparedDeliverySpec;
import seltype : SelMode;
import document_selection : DocumentSelection;
// Task 0721: down to ONE name. The other six were the matrix helpers
// `ItemXform.composedMatrix`/`modelSpace` compose from, and they left with it
// (`item_xform.d`); `ModelSpace` stays because `primaryModelSpaceResolver` at
// the bottom of this module is typed on it.
import math    : ModelSpace;

// Modeling-only document/layer model: no GL, render, or UI imports. Selection,
// foreground/background, activeIndex, and the edit target are all derived from
// the item-selection state mixed in from `document_selection.d`; editing still
// binds only the derived primary layer.

// Task 0721 (audit №4, D10): the `xform` and `items` strata now live in
// their own modules. `public import`, not a plain one, and the difference
// is the whole compatibility story: ~50 modules say `import document :
// ItemXform;` / `ItemKind` / `kindInfo`, and a re-export keeps every one of
// them resolving without an edit. The public surface of `document` is
// unchanged, name for name.
//
// A third stratum, `RowTextMemo`, took the same first step (0721: a leaf
// module this one re-exported) and then left ENTIRELY (0771): nothing here
// re-exports it any more, because nothing here holds one. The image payload
// classes now take the ordinary leaf-module/re-export shape in `image_data.d`.
public import item_xform : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG,
                           ItemXform, sanitizeItemXform;
public import item_kinds : ItemKind, ItemKindInfo, kindInfo, kindFromToken,
                           tokenOf;
public import image_data : ImageData, ImagePlaneData;

// ===========================================================================
// Task 0616 Stage 6 (task file Ph3) — the CONSUMER → ITEM link.
//
// WHAT IDENTIFIES THE TARGET: the target `Layer` OBJECT itself. Nothing else.
// The three candidates that look like identity and are not:
//
//   * A PATH is not identity. Two image items may legitimately carry the same
//     `storedPath` (the user loaded one file twice and renamed the rows apart,
//     or two rows converged after a `replace`), so a path does not name ONE
//     row; and the whole point of the item indirection is that re-pointing an
//     image at a different file must reach every consumer WITHOUT touching
//     any consumer — impossible if the consumer stores the path.
//   * An INDEX is not identity. `layers[]` is spliced by `layer.delete` and
//     permuted by `layer.reorder` — whose own comment is explicit that
//     identity is untouched by the splice. A stored index survives neither,
//     and its failure mode is the worst available one: after a MIDDLE delete
//     every index past the hole silently addresses its NEIGHBOUR. That is not
//     a broken link, it is a link to the wrong thing, with nothing to notice.
//   * A NAME is not identity. `layer.rename` is a supported operation on an
//     image row (the reference's list renames the reference, never the file),
//     and layer names are not unique — two rows may share one.
//
// The `Layer` class already exists FOR this: its doc comment below states
// that a class buys a stable heap address that no slicing / reordering /
// reallocation of `layers[]` can move, and that the GC keeps a deleted layer
// alive for as long as anything still points at it. A link is one more thing
// that points at it.
//
// WHAT WOULD BE PERSISTED (Ph6/v8, NOT this phase): the target's INDEX into
// the fully written `layers[]` array, resolved back to the object after the
// whole file is parsed. That is a wire ENCODING of this same identity, not a
// second identity scheme: within one file the item list is written complete
// and in order, so index ↔ object is total and injective, and the object
// identity is authoritative again the moment the parse finishes. Its one
// precondition is written down here so the writer cannot quietly break it:
// **every item must be written, unfiltered** — if the writer ever filters the
// item list again, the index encoding stops being injective and a per-item
// stable id becomes necessary. Until then it is not (see the plan's rejection
// of per-item UUIDs).
//
// DELETE BEHAVIOUR — resolution is CHECKED, links are never swept.
// `resolve()` answers only for a target that is a present member of the
// document it is asked about; anything else is `Dangling` and resolves to
// `null`. Deleting a target therefore neither crashes nor silently re-points
// a consumer, and it needs no cooperation from the delete path at all.
//
// This DIVERGES from the plan's §Q5 provisional recommendation (sweep every
// referring link clear inside the delete's undo step) and from the house
// precedent one field over — `Layer.parent`, which `LayerDelete` does clear
// on apply and restore on revert. The distinction is in the consumer, not in
// taste: `parent`'s consumers dereference it unconditionally (`l.parent.xform`),
// so a dangling parent is an unnoticed wrong answer and MUST be cleared,
// whereas an item link is only reachable through `resolve()`, whose `null`
// result every consumer must already handle — the target file can be missing
// from disk regardless of whether the item exists. Three further reasons:
//
//   1. The sweep would not be sufficient on its own. FOUR separate sites
//      replace the whole layer list (scene reset, the `.v3d` reader, the
//      interchange import, and delete), so a link can outlive its document
//      without any delete running. Checked resolution is required anyway;
//      given that, the sweep is redundancy, not safety.
//   2. Undo becomes exact for free. `LayerDelete.revert` reinserts the SAME
//      object, so every link that pointed at it is Live again by identity —
//      with no recorded list to restore and therefore no way to restore it
//      wrong (e.g. re-establishing two links onto two different objects).
//   3. "Deleted" is strictly more information than "never set", and a panel
//      that wants to offer "this consumer's image was deleted — re-point it?"
//      cannot ask a link that was cleared. QUALIFIED (task 0616 Ph6): this
//      reason holds IN MEMORY only. Across a save it does not — the wire
//      encoding is the target's INDEX and a non-member target has none, so a
//      `Dangling` slot is DROPPED on write and reads `Unset` on load. That is
//      deliberate (no sentinel index, no tombstone entry, both of which would
//      be the second identity scheme the encoding depends on not existing);
//      `io/native.d`'s v8 schema header, decision 4, is where it is stated
//      and argued, and this line is not a second copy of it. Reasons 1 and 2
//      are untouched by the round trip and carry the decision on their own.
//
// The choice is also the reversible one: a later policy of clearing on delete
// layers cleanly ON TOP of checked resolution (`Document.referrersOf` below is
// the sweep it would need), while the reverse — trusting an unchecked pointer
// because a sweep was supposed to have cleared it — has no recovery.
// ===========================================================================

/// How an `ItemLink` resolves against one particular `Document`. A link has
/// no state of its own — the same link is `Live` against the document that
/// holds its target and `Dangling` against any other — which is why every
/// query below takes the document to answer for.
enum LinkState : ubyte {
    Unset    = 0,  ///< no target set (never set, or explicitly cleared)
    Live     = 1,  ///< target set and a present member of that document
    Dangling = 2,  ///< target set, but not a member of that document — it was
                    ///< deleted, or the link outlived its whole document
}

/// A forward, many→one reference from one document item (the CONSUMER) to
/// another (the TARGET). Forward-only: the target does not know its
/// consumers, so "who references me" is a sweep (`Document.referrersOf`),
/// deliberately paid at delete/panel time and never on a draw or pick path.
///
/// The only ways to get at the target are `resolve()` (checked, `null` unless
/// `Live`) and `targetUnchecked()` (unchecked, and named so). There is no
/// plain `target` accessor, because "the pointer, trusted" is exactly the
/// zombie the checked-resolution decision above exists to make unreachable.
struct ItemLink {
    private Layer target_;

    /// A link to `l`. `null` yields the `Unset` link — a link is a value, so
    /// `ItemLink.init` is already the well-formed "points at nothing".
    static ItemLink to(Layer l) pure nothrow @nogc @safe {
        ItemLink r; r.target_ = l; return r;
    }

    /// True iff a target was set. Says nothing about whether it resolves —
    /// that needs a document (`state`).
    bool isSet() const pure nothrow @nogc @safe { return target_ !is null; }

    /// How this link resolves against `doc`. `isMember` (not `!is null`) is
    /// the membership test, for the reason its own doc comment gives: a
    /// deleted or replaced-away layer stays non-null and reachable.
    LinkState state(const ref Document doc) const {
        if (target_ is null) return LinkState.Unset;
        return doc.isMember(target_) ? LinkState.Live : LinkState.Dangling;
    }

    /// The target as an item of `doc`, or `null` when the link is `Unset` or
    /// `Dangling`. This is the accessor consumers use; the `null` it can
    /// return is the same `null` an unset link returns, so a consumer needs
    /// exactly one branch (and `state` when it wants to say WHICH).
    inout(Layer) resolve(const ref Document doc) inout {
        return state(doc) == LinkState.Live ? target_ : null;
    }

    /// The stored target WITHOUT the membership check — the identity itself.
    /// For the two jobs that legitimately need the raw pointer: comparing two
    /// links for identity, and encoding one for serialisation
    /// (`Document.indexOf`). NOT for reaching a target to use it: a value
    /// from here may name an item that no longer exists.
    inout(Layer) targetUnchecked() inout pure nothrow @nogc @safe { return target_; }
}

/// One named link slot on a consumer item. The name is a slot on the
/// CONSUMER (e.g. which of its several image inputs this is), part of that
/// consumer's own contract — it is never the target's name, and renaming
/// either end does not touch it.
struct LinkSlot {
    string   name;   ///< slot name, unique within one item
    ItemLink link;   ///< what that slot points at
}

/// A single document layer. Deliberately a CLASS, for two reasons:
///   (a) the interior `Mesh` sits at a stable heap address no matter how
///       `layers[]` is sliced / reordered / reallocated — the
///       in-place-replacement invariant generalizes per layer;
///   (b) any `Mesh*` captured by a history entry is an interior pointer
///       the GC traces, so a layer whose edits are still on the undo stack
///       cannot dangle even after the layer is deleted from `layers[]`.
/// Monotone source for `Layer.birthId`. `__gshared` and main-thread-only, like
/// every other document-model global; starts at 1 so 0 can mean "never seated".
private __gshared ulong g_nextLayerBirthId = 0;

private final class PendingPreparedMeshImage {
    Mesh image;
    ulong generation;
    bool validated;
}

struct PreparedLayerMeshToken {
private:
    ulong birthId, generation;
public:
    @disable this(this);
}

struct ValidatedLayerMeshToken {
private:
    ulong birthId, generation;
public:
    @disable this(this);
    bool valid() const nothrow @nogc { return birthId != 0; }
}

// Thread-local projected mesh view for composing a prepared predecessor with
// the incoming tool. Background/HTTP readers continue to observe live state.
private Layer preparedLifecycleReadLayer_;

struct PreparedLayerReadScope {
    @disable this(this);
private:
    Layer layer_;
public:
    void close() nothrow @nogc {
        if (preparedLifecycleReadLayer_ is layer_)
            preparedLifecycleReadLayer_ = null;
        layer_ = null;
    }
    ~this() { close(); }
}

PreparedLayerReadScope beginPreparedLayerRead(Layer layer) {
    PreparedLayerReadScope result;
    if (layer is null || !layer.hasEnlistedMesh() ||
        preparedLifecycleReadLayer_ !is null) return result;
    preparedLifecycleReadLayer_ = layer;
    result.layer_ = layer;
    return result;
}

private bool usesPreparedLifecycleRead(Layer layer) nothrow @nogc {
    return layer !is null && preparedLifecycleReadLayer_ is layer &&
        layer.hasEnlistedMesh();
}

final class Layer {
    /// THE LAYER'S IDENTITY, and the close on the address-reuse (ABA) hazard
    /// the epoch tables carry (task 1906 stage 3; `source/mesh_dirty.d`'s
    /// header states the hazard as a sequence).
    ///
    /// Every cache in the tree that is keyed on a mesh ADDRESS is really keyed
    /// on "the mesh that lived at this address when I stamped". Two `Layer`
    /// objects can occupy the same address one after the other — the first
    /// collected, the second allocated into the same block — and the second
    /// need not publish anything, so an epoch compare alone cannot tell them
    /// apart. This id can: it is minted once, here, and never copied,
    /// restored or reassigned.
    ///
    /// IT IS ON `Layer` RATHER THAN ON `Mesh` DELIBERATELY. A `ulong` on `Mesh`
    /// would be copied by every wholesale `*mesh = …` kernel and written by
    /// `MeshSnapshot.restore`, so a layer could inherit a scratch mesh's
    /// identity and an UNDO could restore one — the single thing an identity
    /// must never do. Here it is structurally impossible: `Layer` is a class,
    /// its identity is its heap address, and no struct assignment or snapshot
    /// reaches this field.
    immutable ulong birthId;

    /// Mint the identity and register it against this layer's mesh address.
    /// `Layer` has no other constructor, so every `new Layer` in the tree goes
    /// through here — the same "the compiler is the completeness proof"
    /// argument `Command.apply`'s `final` carries.
    this() {
        birthId = ++g_nextLayerBirthId;
        preparedSubjectOwner_ = new PreparedMeshSubjectOwner(
            this, cast(size_t)&mesh_, birthId);
        import mesh_dirty : noteMeshBirth;
        noteMeshBirth(cast(size_t)&mesh_, birthId);
    }

    // Task 0615 Stage 5: PRIVATE + renamed from the public `mesh`. This is the
    // enforcement mechanism, not cosmetics — every direct payload consumer
    // outside this module becomes a compile error, and the compiler's error
    // list IS the audit (§Consumer inventory, tier 1). Reach it only through
    // `hasMesh()` / `meshOrNull()` / `meshRef()` / `Document.meshLayers()`.
    private Mesh mesh_;         ///< the layer's geometry (stable heap address)
    private PreparedMeshSubjectOwner preparedSubjectOwner_;
    private ulong preparedMeshGeneration_;
    private PendingPreparedMeshImage preparedMeshPending_;
    private PreparedLayerMeshToken enlistedMeshToken_;
    private ValidatedLayerMeshToken enlistedMeshValidated_;

    PreparedLayerMeshToken beginPreparedMesh() {
        PreparedLayerMeshToken token;
        if (preparedMeshPending_ !is null || !canBeginPreparedMesh(mesh_))
            return token;
        auto pending = new PendingPreparedMeshImage();
        pending.generation = ++preparedMeshGeneration_;
        pending.image = detachedPreparedMesh(mesh_);
        preparedMeshPending_ = pending;
        token.birthId = birthId; token.generation = pending.generation;
        return token;
    }

    private bool ownsPrepared(ref PreparedLayerMeshToken token) const nothrow @nogc {
        return preparedMeshPending_ !is null && token.birthId == birthId &&
               token.generation == preparedMeshPending_.generation;
    }

    /// Evolve from another detached whole image; the live mesh is untouched.
    bool prepareMeshImage(ref PreparedLayerMeshToken token, ref const Mesh image) {
        if (!ownsPrepared(token) || !canBeginPreparedMesh(image)) return false;
        preparedMeshPending_.image = detachedPreparedMesh(image);
        preparedMeshPending_.validated = false;
        return true;
    }

    ValidatedLayerMeshToken validatesPreparedMesh(ref PreparedLayerMeshToken token)
            nothrow @nogc {
        ValidatedLayerMeshToken result;
        if (!ownsPrepared(token)) return result;
        preparedMeshPending_.validated = true;
        result.birthId = token.birthId; result.generation = token.generation;
        token.birthId = 0; token.generation = 0;
        return result;
    }

    void installPreparedMesh(ref ValidatedLayerMeshToken token) nothrow @nogc {
        if (preparedMeshPending_ is null || !preparedMeshPending_.validated ||
            token.birthId != birthId ||
            token.generation != preparedMeshPending_.generation) return;
        auto pending = preparedMeshPending_;
        preparedMeshPending_ = null;
        token.birthId = 0; token.generation = 0;
        installPreparedMeshImage(mesh_, pending.image);
    }

    void discardPreparedMesh(ref PreparedLayerMeshToken token) nothrow @nogc {
        if (!ownsPrepared(token)) return;
        preparedMeshPending_ = null;
        token.birthId = 0; token.generation = 0;
    }

    bool ownsMesh(const(Mesh)* candidate) const nothrow @nogc {
        return candidate is &mesh_;
    }
    bool beginEnlistedMesh() {
        enlistedMeshToken_ = beginPreparedMesh();
        return preparedMeshPending_ !is null;
    }
    bool hasEnlistedMesh() const nothrow @nogc {
        return preparedMeshPending_ !is null;
    }
    ref Mesh enlistedShadow() return {
        return preparedMeshPending_.image;
    }
    bool replaceEnlistedShadow(ref const Mesh image) {
        return prepareMeshImage(enlistedMeshToken_, image);
    }
    PreparedShadowScope beginEnlistedShadowMutation() {
        return beginPreparedShadow(preparedMeshPending_.image);
    }
    PreparedDeliverySpec drainEnlistedDelivery() {
        uint flags, domains;
        drainPreparedShadowDelivery(preparedMeshPending_.image, flags, domains);
        return PreparedDeliverySpec(preparedSubjectOwner_,
            preparedSubjectOwner_.issue(), flags, domains);
    }
    PreparedDeliverySpec enlistedDeliveryForStampedImage(uint flags,
                                                          uint domains) {
        return PreparedDeliverySpec(preparedSubjectOwner_,
            preparedSubjectOwner_.issue(), flags, domains);
    }
    bool validateEnlistedMesh() nothrow @nogc {
        enlistedMeshValidated_ = validatesPreparedMesh(enlistedMeshToken_);
        return enlistedMeshValidated_.valid;
    }
    void installEnlistedMesh() nothrow @nogc {
        installPreparedMesh(enlistedMeshValidated_);
    }
    void abortEnlistedMesh() nothrow @nogc {
        if (preparedMeshPending_ !is null) preparedMeshPending_ = null;
    }
    // Task 0615: a plain DEFAULTED field, so every pre-existing `new Layer`
    // site (~15 of them) keeps compiling and keeps meaning "mesh item"
    // without being touched.
    ItemKind kind = ItemKind.Mesh; ///< item kind; capability lookup via `kindInfo`
    string name;               ///< display name (e.g. "Layer 1")
    bool   visible    = true;  ///< drawn when true
    bool   selected   = false; ///< membership of the CURRENT item selection
    /// Task 0671 — this item's SEAT in the ordered item-selection list.
    ///
    /// The current selection is not a set, it is a QUEUE: the reference keeps
    /// its selection as an ordered list and the edit target is the list's
    /// FIRST surviving member (measured — `set B; add A` targets **B**, the
    /// earlier one, not the newer). A `bool selected` alone cannot answer
    /// "which was first", and `layers` order is the wrong answer: it says A,
    /// because A is layer 0.
    ///
    /// Ascending = later. `Document.noteSelected` seats a joining item at the
    /// BACK (`++selSeatBack_`); `Document.setPrimary` — vibe3d's own affordance,
    /// see there — re-seats at the FRONT (`--selSeatFront_`), which is why this
    /// is signed. `0` means "never seated"; ties (two never-seated items) break
    /// on `layers` order, so the walk is total even for a document assembled by
    /// direct field writes.
    ///
    /// Deliberately NOT cleared on deselect: an item that leaves the current
    /// list keeps its seat, and `Document.deselected_` — the history bucket —
    /// is ordered by the same number. That is what makes the two queues one
    /// order, and it is also why an undo that restores `selected` by raw field
    /// write (three `revert()` paths do) restores the ORDER too, without
    /// knowing this field exists.
    long   selSeat    = 0;
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
    // reorder/delete-renumber-safe. ~~Not persisted to .v3d in this task —
    // save/reload drops the parent link silently.~~ One level only: Parent mode
    // reads `l.parent` directly (no ancestor-chain walk).
    //
    // CORRECTED (task 0612 Stage 6, the stale-comment sweep). The
    // non-persistence half stopped being true at v8: `io/native.d` writes
    // `parent` as an index into the fully written `layers[]` and resolves it
    // back to the object in a second pass, and its own round-trip unittest
    // asserts the restored reference by identity with the message *"the parent
    // link now persists — a v7 codec reads null here"*. The two other things
    // this comment says are unchanged and still load-bearing.
    Layer parent;

    /// True iff this item owns a geometry payload — a CAPABILITY read off
    /// `kind`, never `kind == ItemKind.Mesh` directly (see `ItemKindInfo`).
    bool hasMesh() const { return kindInfo(kind).hasMesh; }

    /// Pointer to the geometry payload, or `null` for a non-mesh item.
    /// `inout`, not a separate const overload (S6): the interchange writers
    /// that only ever read through a `const(Layer)` — `io/lwo_export.d`,
    /// `io/scene_export.d`, `io/native.d`, `io/scene_ir.d` — need this
    /// accessor too, and a single `inout` definition covers both call shapes.
    inout(Mesh)* meshOrNull() inout { return hasMesh ? &mesh_ : null; }

    /// Reference to the geometry payload. `inout` for the same reason as
    /// `meshOrNull()` (S6). The `debug`-only assert is a DEV-ONLY backstop
    /// for a call site this function does not have yet (review round 2
    /// NIT): nothing calls `meshRef()` before Stage 5 — this stage is
    /// additive-only, so the still-public `mesh` field is what every
    /// consumer, including the per-frame `app.mesh` path at `app.d:1567`,
    /// reads today. Once Stage 5 routes `activeMeshRef()` through
    /// `meshRef()` this assert WILL sit on that per-frame path, which is why
    /// it must not add an unconditional branch to a release build — a
    /// `debug` block compiles out entirely in a non-debug build regardless of
    /// `-release`. The actual guarantee is structural: `Document`'s mutators
    /// keep `primary.hasMesh` true. That structural guarantee is itself only
    /// PROVED by `assertDocInvariants`, which is plain `assert()` and is
    /// therefore ALSO compiled out under `-release` (see its own doc
    /// comment) — neither check is production enforcement.
    ref inout(Mesh) meshRef() inout nothrow @nogc {
        debug assert(hasMesh, "meshRef() called on a non-mesh item");
        return mesh_;
    }

    // Task 0616 Stage 2: the image-payload trio, mirroring the mesh trio
    // above exactly (same three shapes, same reasoning) — `private` field +
    // `hasImage()` / `imageOrNull()` / `imageRef()`. Unlike `mesh_` (a value
    // struct, always present, gated only by whether it is ADDRESSABLE),
    // `image_` is a class reference that is genuinely null until something
    // constructs an `ImageData` for this layer — today, only
    // `LayerDuplicate`'s payload-sharing clone (`commands/layer/commands.d`)
    // and this module's own unit tests do that; the command that constructs
    // one for a freshly loaded image is a later stage.
    private ImageData image_;   ///< the layer's image payload, null unless
                                 ///< `hasImage` (stable heap address: a class
                                 ///< reference, not moved by anything)

    /// True iff this item owns an image-pixel payload — a CAPABILITY read
    /// off `kind`, never `kind == ItemKind.Image` directly (mirrors
    /// `hasMesh`). Note this is independent of whether `image_` has been
    /// constructed yet: like `hasMesh`, it answers "can this kind have one",
    /// not "does this instance have one right now".
    bool hasImage() const { return kindInfo(kind).hasImage; }

    /// The image payload, or `null` for a non-image item OR an image item
    /// whose payload has not been constructed yet. `inout` for the same
    /// const-consumer reason as `meshOrNull()`. Unlike `meshOrNull()` this
    /// returns the class reference directly rather than a pointer-to-it —
    /// `ImageData` already has a native null state, so there is nothing a
    /// pointer indirection would add.
    inout(ImageData) imageOrNull() inout { return hasImage ? image_ : null; }

    /// Reference to the image-payload FIELD itself (not merely its current
    /// value) — this is what lets a caller REBIND which `ImageData` object
    /// the layer points at, e.g. `LayerDuplicate`'s payload-sharing clone
    /// (`l2.imageRef() = src.imageOrNull();`), the class-reference analogue
    /// of `meshRef()` letting `MeshSnapshot.restore()` overwrite the mesh
    /// value in place. The `debug`-only assert mirrors `meshRef()`'s: a
    /// dev-only backstop, not production enforcement (see its comment above).
    ref inout(ImageData) imageRef() inout {
        debug assert(hasImage, "imageRef() called on a non-image item");
        return image_;
    }

    // Task 0612 Stage 2: the image-plane payload trio, mirroring the image
    // trio above exactly — private field + `hasImagePlane()` /
    // `imagePlaneOrNull()` / `imagePlaneRef()`, same three shapes, same
    // reasoning. Like `image_` and unlike `mesh_`, it is a class reference
    // that is genuinely null until something constructs one.
    private ImagePlaneData imagePlane_;  ///< the plane's channels, null unless
                                          ///< `hasImagePlane` and constructed

    /// True iff this item owns an image-plane payload — a CAPABILITY read off
    /// `kind`, never `kind == ItemKind.ImagePlane` directly. Answers "can this
    /// kind have one", not "does this instance have one right now".
    bool hasImagePlane() const { return kindInfo(kind).hasImagePlane; }

    /// The plane payload, or `null` for another kind OR a plane whose payload
    /// has not been constructed yet.
    inout(ImagePlaneData) imagePlaneOrNull() inout {
        return hasImagePlane ? imagePlane_ : null;
    }

    /// Reference to the plane-payload FIELD itself, so a caller can REBIND
    /// which `ImagePlaneData` the layer points at (the clone path, and
    /// whatever constructs one). Same `debug`-only backstop as `imageRef()`.
    ref inout(ImagePlaneData) imagePlaneRef() inout {
        debug assert(hasImagePlane, "imagePlaneRef() called on a non-plane item");
        return imagePlane_;
    }

    // Task 0616 Stage 6 (Ph3): this item's outgoing links, as named slots.
    //
    // Kept SORTED by `name`, with names unique. Sorted rather than an
    // associative array on purpose: the set is tiny (one or two slots on a
    // consumer), and a canonical order means Ph6 can write the `links` block
    // straight out of `linkSlots()` and get the same bytes for the same
    // document every time — an AA's iteration order is a hash order and would
    // have made a byte-comparison round-trip test depend on insertion history.
    //
    // No `parent`-style special case lives here: `parent` is a separate,
    // structural field with its own delete handling, and folding it into this
    // generic map would change its (unchecked, dereferenced-directly)
    // semantics — see the header comment above `LinkState`.
    private LinkSlot[] links_;

    /// The link in slot `name`, or the `Unset` link when there is no such
    /// slot. Never `null`-returning and never throwing: an absent slot and an
    /// unset one are the same state to a consumer, and the difference has no
    /// representation to leak.
    /// `inout` rather than plain mutable (review NIT 1): `linkSlots()` is
    /// `const`, so without this a `const(Layer)` could enumerate every slot
    /// but not ask for one BY NAME — the read-only consumers (a `const ref
    /// Document` writer, an HTTP reporter) would have had to hand-scan the
    /// slot array to do what this function already does. Plain `const` would
    /// have forced `const(ItemLink)` on the mutable callers too; `inout`
    /// gives each caller back what it put in.
    inout(ItemLink) link(string name) inout {
        foreach (ref s; links_) if (s.name == name) return s.link;
        return typeof(return).init;
    }

    /// Point slot `name` at `target`, replacing whatever it held. A `null`
    /// `target` REMOVES the slot rather than leaving an unset one behind —
    /// two representations of "points at nothing" would both have to be
    /// written by Ph6 and compared by every reader, so there is only one.
    void setLink(string name, Layer target) {
        assert(name.length > 0, "setLink: a link slot must be named");
        if (target is null) { clearLink(name); return; }
        size_t i = 0;
        while (i < links_.length && links_[i].name < name) ++i;
        if (i < links_.length && links_[i].name == name) {
            links_[i].link = ItemLink.to(target);
            return;
        }
        links_ = links_[0 .. i] ~ LinkSlot(name, ItemLink.to(target)) ~ links_[i .. $];
    }

    /// Remove slot `name`. Returns true iff a slot was actually removed.
    bool clearLink(string name) {
        foreach (i, ref s; links_) if (s.name == name) {
            links_ = links_[0 .. i] ~ links_[i + 1 .. $];
            return true;
        }
        return false;
    }

    /// Every slot on this item, in canonical (name-sorted) order. `const`, so
    /// the read-only consumers that will need it — a `const ref Document`
    /// writer, an HTTP reporter — reach it without a mutable handle.
    const(LinkSlot)[] linkSlots() const { return links_; }

    /// True iff any slot on this item names `t` — by IDENTITY, and
    /// deliberately UNCHECKED (`targetUnchecked`): the question this answers
    /// is "does this item still point at that object", which stays meaningful
    /// (and is the only useful question) precisely when the object is no
    /// longer a document member. `Document.referrersOf` is built on it.
    bool linksTo(const(Layer) t) const pure nothrow @nogc @safe {
        if (t is null) return false;
        foreach (ref s; links_) if (s.link.targetUnchecked() is t) return true;
        return false;
    }

    /// Copy `src`'s link slots onto this item — a SHALLOW copy: the slot
    /// array is duplicated (so the two items' slot sets are independent), the
    /// targets are shared by identity (so a cloned consumer points at the
    /// same item its source did, which is the whole many→one point). The
    /// `.dup` is load-bearing: without it `setLink`'s in-place replacement
    /// branch on one item would write through the other's slice.
    void copyLinksFrom(Layer src) {
        if (src is null) { links_ = null; return; }
        links_ = src.links_.dup;
    }
}

/// The layer list, the index of the one active (foreground) layer, and the
/// `primary` / `focusedItem` pointers into it.
///
/// Invariants — enforced today by every TYPE-LEVEL mutator declared on this
/// struct (`setActive`, `selectItem`, `setPrimary`,
/// `promoteAwayFromHiddenPrimary`, `exclusiveSelect`, `rehomePrimary`), AND
/// (task 0615 Stage 6) by `commands/layer/commands.d`'s `LayerDelete`, which
/// now decides the delete-time successor by OBJECT IDENTITY and calls
/// `rehomePrimary` when the deleted layer was itself the primary (L1) —
/// `rehomePrimary`'s first production caller. ~~`io/native.d`'s `.v3d` loader
/// still raw-writes `document.primary = parsed[primaryIndex]` before any
/// mutator runs (L3) — currently harmless because the v7 reader can only ever
/// produce mesh-kind layers (Stage 8/v8, which would let a non-mesh `"type"`
/// reach that raw write, is deferred to task 0616 by owner decision). A
/// caller reaching `Document` only through that one remaining site could
/// still violate the invariants below once a non-mesh layer becomes
/// loadable.~~
///
/// CLOSED (task 0612 Stage 6, the stale-comment sweep) — and it was closed by
/// the very change this paragraph feared. v8 does let a non-mesh `"type"`
/// reach the loader, and rather than leaving the raw write reachable from
/// there, `io/native.d` deleted it: the loader now checks the file's
/// `primaryIndex` against `canBePrimary`, rehomes onto a mesh-kind item and
/// warns if the file names one that is not, then installs the selection
/// through `setActive` / `selectItem` / `setPrimary` — the same mutators as
/// every other caller. Its own comment records the removal at the site. So
/// the mutator list above is the WHOLE enforcement surface, with no remaining
/// exception; there is no site left that can violate the invariants below.
///   * `layers.length >= 1`.
///   * `primary` ∈ `layers` when non-null; `primary is layers[activeIndex]`;
///     `primary` always `canBePrimary` (today: always mesh-kind) — at least
///     one mesh-kind layer always exists (task 0615, §Q2).
///   * `focusedItem` ∈ `layers` when non-null; `focusedItem.selected`.
///     `focusedItem` may be ANY kind — it is the item-selection FOCUS (item
///     transform / property panel / item ops), distinct from `primary` (the
///     MESH EDIT TARGET) only once a non-mesh item is selected (task 0615).
///
/// TASK 0654 RETIRED THE "AT LEAST ONE SELECTED" INVARIANT. It used to read
/// "`primary.selected` is always true; at least one layer is always selected"
/// and "`primary !is null`" / "`focusedItem !is null`" — three clauses that
/// were never asserted, only MAINTAINED by the mutators below. An empty item
/// selection is legal now (measured, task 0653: a viewport miss in item mode
/// empties the selection, and removing the last selected item empties it too),
/// so what remains is a BICONDITIONAL, and it is the whole model:
///
///     primary is null  ⟺  focusedItem is null  ⟺  no layer is selected
///
/// TASK 0668 SPLIT THAT BICONDITIONAL IN TWO. 0654's chain silently assumed
/// that anything selected can be the edit target, which held only because the
/// exclusive-select path REFUSED to leave a `canBePrimary == false` kind alone
/// in the selection (it spared the previous primary instead). Once creating a
/// reference plane is allowed to select only the plane, "something is
/// selected" and "there is an edit target" are two different questions with
/// two different answers, and the model is:
///
///     focusedItem is null  ⟺  no layer is selected
///     primary is null      ⟺  no SELECTED layer is `canBePrimary`
///
/// ===========================================================================
/// TASK 0671 — THE SECOND HALF OF THAT SPLIT IS ALSO WRONG, AND `primary` IS
/// NOT A FIELD ANY MORE.
/// ===========================================================================
///
/// 0654 and 0668 both reasoned from OUR model. Task 0670 went and read the
/// reference's instead, and the mechanism is not the one everybody (this
/// comment included) had inferred. There is no latched pointer living outside
/// the selection, and there is no second variable at all. **Per selection type
/// the reference keeps TWO lists: the current selection, and a cache of
/// recently deselected elements.** Selectedness is therefore not a boolean:
/// an element is `CURRENT`, or `HISTORY`, or neither.
///
/// Everything else falls out of one comparison. The foreground layer list is
/// an ENUMERATION over both lists — current first, then history — filtered to
/// the layer bucket; a mesh counts as foreground when its selection state is
/// **non-zero**, not when it is in the current list; and history is non-zero.
/// The edit target is simply the FIRST SURVIVOR OF THAT SAME WALK. It is
/// recomputed on demand, never stored.
///
/// So in this file:
///
///   * `Layer.selected` is membership of the CURRENT list only.
///   * `deselected_` is the second list, bucketed by item KIND — because the
///     reference's history buckets are keyed by (selection type, subtype) and
///     the subtype of an item packet is the item's type.
///   * `primary` is a derived accessor (`nthEditTargetCandidate(0)`), not a
///     field. Nothing assigns it; the mutators move ITEMS BETWEEN THE TWO
///     LISTS and the target follows.
///   * `foreground(l)` / `background(l)` route through `roleOf(l)`, the port of
///     the reference's own three-way classifier.
///
/// THE LAW THAT MAKES THE LATCH: history buckets are keyed by kind, so only a
/// selection OF A MESH flushes the mesh bucket. Selecting a reference plane
/// flushes the PLANE bucket and leaves the previously-selected mesh sitting in
/// the mesh history — still non-zero, therefore still foreground, therefore
/// still the edit target. Dropping the whole item selection does not flush any
/// bucket at all, so it too keeps the target (measured; `tests/fixtures/
/// edit_target_legality.json`, cell `target_set_nothing_selected`).
///
/// ~~There is STILL deliberately no state where a layer is latched as the edit
/// target while unselected. `foreground(l) == visible && selected` is the sole
/// derivation of foreground/background, so such a primary would render as
/// BACKGROUND — a dimmed, read-only, non-snappable layer that the toolpipe
/// nevertheless writes to. That is not a representable state for the draw
/// path, and it is a hidden selection for the user: the gizmo would act on an
/// item nothing on screen marks. That is precisely why 0668 clears the mesh
/// rather than keeping it latched: every consumer that needs an edit target
/// must ask for one and take the refusal (`hasEditTarget`, `activeMesh() is
/// null`, `activeMeshRef()` throwing) rather than be handed a substitute.~~
///
/// SUPERSEDED, and the objection is what got answered rather than overruled.
/// It was a sound argument about a model in which `foreground` reads
/// `selected`. In the reference `foreground` reads the SELECTION STATE, and a
/// deselected mesh in the history bucket has one — so the latched mesh draws
/// as FOREGROUND, is not a background snap source, and is exactly as marked on
/// screen as it was a moment ago. The dimmed-but-edited state this paragraph
/// refuses to represent is still unrepresentable; it was never what the
/// reference did.
///
/// WHAT SURVIVES 0654/0668 UNCHANGED: an absent edit target is still legal and
/// is still a refusal, not a substitution — every consumer asks
/// (`hasEditTarget`, `activeMesh() is null`, `activeMeshRef()` throwing) and
/// takes the refusal. Only the way that state is REACHED changed: no mesh has a
/// non-zero selection state (e.g. the mesh that held the target was deleted,
/// or its bucket was flushed by another mesh which was then deleted). Both
/// odd states are legal and both were measured: "target set, nothing selected"
/// and "selection non-empty, no target".
///
/// The model, whole:
///
///     focusedItem is null  ⟺  no layer is in the CURRENT list
///     primary              == first survivor of [current ++ history], filtered
///                             to `canBePrimary` members
///
/// The two are now genuinely independent — neither implies the other in either
/// direction — which is what the frozen fixtures measure.

/// Thrown by `Document.activeMeshRef()` when the item selection is empty
/// (task 0654). Its own type, not a bare `Exception`, so a caller that WANTS to
/// tolerate the empty state can catch exactly this and nothing else.
class NoEditTargetException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// The one-clause reason every consumer names when it refuses for want of an
/// edit target (task 0654). Declared ONCE so the command layer, the tool
/// layer and the HTTP surface cannot drift into three different wordings that
/// a test would then have to match three ways.
enum string kNoEditTargetReason =
    "no mesh item is selected: there is no mesh edit target";

// `command.d` declares the same string (it cannot import this module — see
// `command.g_editTargetResolver`). Two literals that must stay identical are a
// latent divergence unless something checks, so this is the check: a test that
// asserts the HTTP refusal against `document.kNoEditTargetReason` would
// otherwise pass while a command answered something else entirely.
static assert(kNoEditTargetReason == imported!"command".kNoEditTargetReason,
    "document.kNoEditTargetReason and command.kNoEditTargetReason must be "
    ~ "byte-identical — the refusal is one sentence, not two");

private __gshared Mesh g_noEditTargetMesh;

/// The READ-ONLY empty stand-in the per-frame READ paths see when there is no
/// edit target (task 0654): the viewport draw, the picking projections —
/// everything that must produce a frame rather than an
/// exception. It has no vertices, edges or faces, so every loop over it does
/// nothing, which is the truth of the state: with nothing selected there is no
/// foreground geometry.
///
/// IT IS NOT A SUBSTITUTE EDIT TARGET, and the difference is the whole point of
/// this task. Layer 0 would be a substitute — a real layer, silently edited.
/// This is a detached mesh that belongs to no layer and no document, so a write
/// that reached it could corrupt nothing; and no write is supposed to reach it,
/// because every WRITE funnel refuses first:
///
///   * `Command.apply()`'s Operator branch — every mesh-mutating command —
///     refuses with `kNoEditTargetReason` before its kernel runs.
///   * tool ACTIVATION refuses, so no tool ever binds a `Mesh*` off this.
///
/// `tests/test_empty_item_selection.d` asserts it stays empty after a refused
/// command, which is how "no write reaches it" stays true rather than merely
/// intended.
ref Mesh noEditTargetMesh() nothrow @nogc { return g_noEditTargetMesh; }

/// The selection STATE of one item — the port of the reference's own state
/// word, narrowed to the two bits this document model uses (task 0671).
/// "Deselected" is not the absence of a state; it is the state `History`.
enum SelState : ubyte {
    None    = 0,  ///< in neither list
    Current = 1,  ///< in the current item selection
    History = 2,  ///< not current, but still in the recently-deselected cache
}

/// The three-way classification of an item as a LAYER (task 0671) — the port
/// of the reference's own classifier, which returns exactly these three
/// answers and whose "none of those" arm is documented in its own headers.
///
/// It is deliberately three-valued and not `bool foreground`: a hidden item
/// with no selection state is neither foreground nor background, and an item
/// of a kind that is not a scene item at all (a clip) is not a layer at all.
enum LayerRole : ubyte {
    None       = 0,  ///< not a layer: not a scene item, or hidden with no state
    Foreground = 1,  ///< an active layer — editable, undimmed, target-eligible
    Background = 2,  ///< visible but inactive — dimmed, read-only, snappable
}

struct Document {
    Layer[] layers;            ///< flat list; always length >= 1
    // Task 0615 Stage 2: splits the role `primary` used to conflate. `primary`
    // is the mesh edit target; `focusedItem` is the item-selection focus (item
    // transform, property panel, item ops) and may be ANY kind. On an
    // all-mesh document the two coincide whenever the mesh is CURRENT; task
    // 0671 lets them part company the other way too (a latched mesh is the
    // target while the focus sits on a plane, or on nothing).
    Layer   focusedItem;       ///< most-recently-touched item of the CURRENT
                               ///< selection, any kind.

    // -----------------------------------------------------------------------
    // THE SELECTION STRATUM (task 0721, audit №4 D10) — `document_selection.d`.
    //
    // The two lists the edit target is derived from, the walk over them, every
    // reader built on that walk, and the mutators. Mixed in rather than moved
    // to a second type on purpose: `deselected_` / `selSeatBack_` /
    // `selSeatFront_` stay PRIVATE members of `Document`, so the set of code
    // that can violate the invariants is the same closed set of mutators it
    // was before the file boundary existed. A separate object would have had
    // to open all three.
    // -----------------------------------------------------------------------
    mixin DocumentSelection;

    /// Lazy range over just the mesh-kind layers — for "iterate the meshes"
    /// consumers that must not see a non-mesh layer (task 0615, R1 mitigation
    /// #1). A `std.algorithm.filter` over the slice, NOT `.array` — this is
    /// reached from per-frame draw/snap loops (`ui/panels.d`), so it must not
    /// allocate (0585 / [[selection_property_on2_trap]] precedent).
    ///
    /// A `this This` template parameter, not a plain `inout` function:
    /// `std.algorithm.filter`'s `FilterResult` stores the range in a field,
    /// and D forbids an `inout` FIELD (only parameters/stack locals may be
    /// `inout`) — instantiating `filter!` over an `inout(Layer)[]` fails to
    /// compile. Deducing `This` (`Document` or `const(Document)` per call
    /// site) sidesteps `inout` entirely — each instantiation sees a
    /// concrete, non-`inout` element type — so `const`-qualified callers
    /// (`io/scene_ir.d`'s `flattenDocument`, `io/scene_export.d`,
    /// `io/lwo_export.d` — all take `const ref Document`) and mutable
    /// callers share this one declaration instead of two near-duplicates.
    auto meshLayers(this This)() {
        import std.algorithm : filter;
        return layers.filter!(l => l.hasMesh);
    }


    /// The index of `l` in `layers` by identity, or `layers.length` if
    /// absent. Callers should not re-derive a position by pointer/index
    /// arithmetic (task 0615, §L1).
    ///
    /// NIT: `setActive(indexOf(x))` is not a safe "select `x` or fail" idiom
    /// — an absent `x` returns the `layers.length` sentinel, and `setActive`
    /// silently CLAMPS any out-of-range index to the last layer (it exists
    /// to clamp genuinely out-of-range user/HTTP indices, and
    /// `test_layers.d` pins that behaviour). A caller that must not tolerate
    /// "absent silently becomes select-the-tail" — e.g. a future
    /// `rehomePrimary` caller — has to check `indexOf(x) < layers.length`
    /// itself before calling `setActive`.
    ///
    /// NIT (review round 2): cross-reference — `activeIndex()` is this same
    /// identity scan over `layers`, but its absent-sentinel is `0`, not
    /// `layers.length`. The two are NOT interchangeable; do not swap one
    /// scan's result into a context expecting the other's sentinel.
    size_t indexOf(const(Layer) l) const {
        foreach (i, x; layers) if (x is l) return i;
        return layers.length;
    }

    /// True iff `l` is a genuine member of `layers` — MEMBERSHIP, not just
    /// non-null (task 0615, SF1, review round 2). `primary` / `focusedItem`
    /// can go STALE: non-null, but no longer present in `layers`, when a
    /// caller replaces `layers` on a LIVE `Document` via direct field
    /// assignment before repointing `primary` — e.g. the `.v3d` loader
    /// reuses the app's live `Document` by `ref`
    /// (`commands/file/load.d:122` → `io/native.d`) and assigns
    /// `document.layers = parsed` before any mutator has a chance to run. A
    /// plain `l is null` check does not catch this; `indexOf` does.
    bool isMember(const(Layer) l) const { return l !is null && indexOf(l) != layers.length; }

    /// Does some item in this document own the mesh STORAGE at `m`? — the
    /// address question, and deliberately not the identity one (task 1906,
    /// review B1).
    ///
    /// `Mesh` is a value field inside `Layer` (`mesh_`), so "this pointer is a
    /// document mesh" can only be asked as "does it alias some layer's mesh
    /// field". There is no back-pointer from a `Mesh` to its `Layer` — a
    /// `Mesh` does not know it is owned — and there cannot be one while
    /// kernels replace the whole struct with `*mesh = …` (that assignment
    /// would copy a stale owner along with the geometry). So the walk over
    /// `layers` IS the mechanism, not a shortcut around a missing one.
    ///
    /// It answers on `&l.mesh_` rather than on `l.meshOrNull()` on purpose:
    /// `meshOrNull` gates on `hasMesh`, i.e. on the layer's KIND, and the
    /// question here is about STORAGE. A layer whose kind changed still owns
    /// the same bytes, and a pointer into them is still a pointer a listener
    /// may legitimately be told about.
    ///
    /// This is what `app.d` installs into `mesh.g_isDocumentMesh`, the one
    /// symbol tasks 1906 (delivery subject filter) and 1903 (mutation-path
    /// counter) share. `nothrow` although that symbol's type is not: 1906's
    /// caller runs INSIDE a mesh edit (`Mesh.deliverPending`), where an
    /// escaping exception would abandon a half-finished mutation, and a
    /// `nothrow` body converts implicitly to the throwing delegate type.
    bool ownsMesh(const(Mesh)* m) const nothrow {
        if (m is null) return false;
        foreach (l; layers) {
            if (l is null) continue;
            if (&l.mesh_ is m) return true;
        }
        return false;
    }

    /// Every item that still links to `target`, in `layers` order — the
    /// REVERSE of a forward-only link, and therefore a full sweep of the item
    /// list (O(items × slots)). There is no back-edge to consult: the target
    /// does not know its consumers, by design, so this is the only way to ask.
    ///
    /// Cost is why the phrasing matters: this is a DELETE-TIME / PANEL-TIME
    /// query ("is this image still used", "which consumers would a delete
    /// affect", and — if a later policy ever wants to clear links on delete —
    /// the exact list it would clear). It must never be reached from a draw,
    /// pick or per-frame path.
    ///
    /// Reports referrers whose link is DANGLING too (it matches on identity,
    /// not on resolution), because the caller that most needs this list is
    /// the one asking about an item that has just left, or is about to.
    ///
    /// Fills `outBuf` in place — the `selectedItemsInto` idiom, so a caller
    /// that asks repeatedly keeps one buffer instead of churning an array.
    void referrersOf(const(Layer) target, ref Layer[] outBuf) {
        size_t n = 0;
        if (target !is null)
            foreach (l; layers) if (l !is null && l.linksTo(target)) ++n;
        if (outBuf.length != n) outBuf.length = n;
        if (n == 0) return;
        size_t i = 0;
        foreach (l; layers) if (l !is null && l.linksTo(target)) outBuf[i++] = l;
    }

    /// Build a one-layer document from an existing mesh. The mesh is moved
    /// into a fresh "Layer 1" which becomes the (only, active, selected) layer.
    static Document bootstrap(Mesh m) {
        auto l = new Layer;
        l.mesh_ = m;
        l.name = "Layer 1";
        l.visible = true;
        // Task 0671: NOT `l.selected = true` here. `setActive` routes through
        // `noteSelected`, which is what allocates the queue SEAT; pre-setting
        // the bool made that call a no-op and left the only layer unseated.
        Document d;
        d.layers = [l];
        d.noteLayerListChanged();
        d.setActive(0);
        return d;
    }
}

/// Resolver installed by the app for call sites without a Document instance.
__gshared ModelSpace delegate() primaryModelSpaceResolver;

ModelSpace primaryModelSpace() {
    return primaryModelSpaceResolver !is null
        ? primaryModelSpaceResolver() : ModelSpace.world();
}

version (DocumentUnitTests) {
    import tests.unit.document_test : DocumentTests;
    mixin DocumentTests;
}
