module document;

import mesh    : Mesh;
import seltype : SelMode;
import document_selection : DocumentSelection;
// Task 0721: down to ONE name. The other six were the matrix helpers
// `ItemXform.composedMatrix`/`modelSpace` compose from, and they left with it
// (`item_xform.d`); `ModelSpace` stays because `primaryModelSpaceResolver` at
// the bottom of this module is typed on it.
import math    : ModelSpace;

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

// Task 0721 (audit №4, D10): the `xform` and `items` strata now live in
// their own modules. `public import`, not a plain one, and the difference
// is the whole compatibility story: ~50 modules say `import document :
// ItemXform;` / `ItemKind` / `kindInfo`, and a re-export keeps every one of
// them resolving without an edit. The public surface of `document` is
// unchanged, name for name.
//
// A third stratum, `RowTextMemo`, took the same first step (0721: a leaf
// module this one re-exported) and then left ENTIRELY (0771): nothing here
// re-exports it any more, because nothing here holds one — see `ImageData`'s
// doc comment below for where it went and why.
public import item_xform : MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG,
                           ItemXform, sanitizeItemXform;
public import item_kinds : ItemKind, ItemKindInfo, kindInfo, kindFromToken,
                           tokenOf;

/// An image item's payload (task 0616). A CLASS reference — unlike `Mesh`
/// (a value struct `MeshSnapshot` moves) — so that a `Layer` can be REPOINTED
/// at another payload through `Layer.imageRef()` without the field itself
/// having to move, and so the pixel-cache handle a later stage parks here has
/// one identity to hang off.
///
/// EVERY ITEM OWNS ITS OWN `ImageData`. An earlier revision of this comment
/// said the opposite — that `LayerDuplicate` points a clone at the exact same
/// object — and that is not what the code does, nor what it may do:
/// `commands/layer/commands.d` deep-copies all seven fields into a fresh
/// `ImageData`, and `io/native.d`'s round-trip test asserts two same-path
/// clips come back as two DISTINCT payloads. The aliasing version shipped
/// briefly under the heading "one decode, N consumers" and was a real defect:
/// `image.replace` on the clone re-pointed BOTH rows, because they were one
/// object. Sharing belongs one level down (the plan's cache is keyed by PATH,
/// so two items naturally meet at one cache entry) and one level up
/// (`ItemLink` is how many consumers reference one clip). Not here.
///
/// `Layer.parent` is the existing precedent for a shared class reference on
/// `Layer`, and the cautionary one: it has no refcount, which is the
/// un-refcounted-alias shape the pixel cache must not repeat.
///
/// Stage 2 shipped only the one field that already had a consumer:
/// `storedPath`, so a duplicated image row had something non-default to
/// compare against its source. Stage 3 adds the two remaining v1 channels the
/// item's provider bundle exposes — `colorspace` and `useAlpha`
/// (`layer_params.d`'s `kindParams`, §Q2 of the plan). Both are AUTHORED
/// fields, never computed — the distinction that keeps them out of the
/// "derived value in a writable channel" trap a `format` channel would have
/// been. Stage 4 added the DERIVED `width` / `height` / `channels` /
/// `missing`, recomputed from the file by `io/image_path.d`'s
/// `refreshImageMeta` and never authored, so none of them is a provider param.
/// There is no `resolvedPath` field and no `format` field: the resolved
/// absolute path is computed on demand (`resolveStoredPath`) rather than
/// cached beside a `storedPath` it could contradict, and the pixel format the
/// panel shows is derived from `channels` at display time
/// (`ui/image_rows.d`'s `pixelFormatText`). Stage 5 adds the pixel-cache
/// handle. Bend #4 (the plan) notes the limit this shape has, in advance: a
/// faithful one-slot-per-kind payload for kind #2 and #3, a tagged union by
/// kind #6 — not paid for now.
///
/// A hazard for Stage 5 specifically, flagged here in advance because this
/// is the class the pixel-cache handle lands on: `io.image_decode
/// .DecodedImage` (task 0616's decoder, `bbfe3a48`) is manual-release, not
/// automatic — copying is `@disable`d and `free()` returns its C-heap buffer
/// to the decoder's allocator, but there is no `~this()`. Parking one
/// directly inside this GC-managed class and expecting GC finalisation to
/// call `free()` for you will leak the C-heap buffer (a GC collection does
/// not run struct destructors it never had, and even if it did, D class
/// finalization order at collection time is not something to lean on for a
/// non-GC resource). Stage 5's refcount must land BEFORE the first
/// `.free()` call site exists — the same ordering the `Layer.parent`
/// cautionary note above makes for the alias itself: ship the count, then
/// the thing that needs it, not the other way around.
final class ImageData {
    string storedPath;             ///< the authored path, as it will be
                                    ///< serialised (Stage 4 owns the store-
                                    ///< relative / resolve-absolute rules;
                                    ///< this stage only holds the field)
    // Task 0616 Stage 3 — the two inert v1 channels (plan §Q2). Measured
    // defaults: `colorspace` `'(default)'`, `useAlpha` `1`. `colorspace` is
    // narrowed to a closed three-tag ENUM rather than the measured open
    // `string` (plan divergence 4) — the only reversal cost, if the tag set
    // ever needs to be open-ended, is one `Param.enum_` → `Param.string_`
    // swap in `layer_params.d`; this field's TYPE stays `string` either way.
    string colorspace = "(default)"; ///< closed tag set: see kindParams' Enum
                                      ///< declaration in layer_params.d
    bool   useAlpha   = true;        ///< inert; round-tripped, nothing reads it

    // -----------------------------------------------------------------------
    // Task 0616 Ph5 — the DERIVED half. Recomputed from the file by
    // `io.image_path.refreshImageMeta`; never authored, never a `Param`,
    // never serialised. The split is the point: the three fields above are
    // what the document SAYS, these four are what the disk ANSWERED, and the
    // answer is allowed to change under the document without the document
    // changing (that is exactly what `image.reload` exists to observe).
    //
    // Persisting any of these would create the second source of truth the
    // plan's §Q2 forbids: it goes stale the moment the file changes on disk,
    // and — worse — a stale `width` cannot be told apart from a fresh one, so
    // a reader would report a confident wrong number for a file it never
    // opened.
    // -----------------------------------------------------------------------
    int  width;      ///< pixels; 0 while `missing`
    int  height;     ///< pixels; 0 while `missing`
    int  channels;   ///< channel count present in the SOURCE file (1/2/3/4);
                      ///< 0 while `missing`. The list's "format" column is a
                      ///< rendering of this, not the file extension.
    bool missing = true; ///< true until a read of `storedPath` has SUCCEEDED.
                          ///< Defaults true rather than false because a payload
                          ///< that was never refreshed has not resolved
                          ///< anything — "unresolved" is the honest initial
                          ///< answer, and claiming `missing == false` for a
                          ///< path nobody has opened is the one wrong answer
                          ///< a consumer cannot detect.

    // Task 0635 added a MEMOISED half here — a rendering of the two halves
    // above, held so a draw path did not rebuild it once per row per frame.
    // Task 0771 moved it off this object entirely: it was a UI cache with no
    // business on the document's own payload class, and unlike the derived
    // fields above it carries no information of the document's — a
    // `RowTextMemo[ImageData]` side table, keyed on this object's identity
    // and pruned by the panel's own draw pass, now lives in
    // `ui/image_rows.d`, the cache's only reader. See that module for the
    // struct, the table, and the lifetime rule that replaces the field.
}


/// A reference-image plane's payload (task 0612). A class reference, for the
/// same two reasons `ImageData` is one: a `Layer` can be repointed at another
/// payload without the field moving, and the object has one identity to hang
/// things off.
///
/// EVERY FIELD IS AN AUTHORED CHANNEL. There is deliberately nothing derived
/// here and no path of its own:
///
///   * the image's PIXEL DIMENSIONS live on the linked clip's `ImageData`,
///     where the disk answered them;
///   * the resolved absolute PATH is computed on demand from that clip;
///   * the TEXTURE lives in the path-keyed pixel cache (`image_cache.d`).
///
/// So there is no second source of truth to keep in sync, and none of the
/// staleness `ImageData`'s own comment argues against. The plane's placement
/// is a pure FUNCTION of these channels plus the item transform plus the
/// clip's dimensions; nothing about it is stored.
final class ImagePlaneData {
    // ---- what the plane faces -------------------------------------------
    /// Which axis-aligned view this plane is a reference FOR. A closed token
    /// set rather than an int, for the reason `ItemKind`'s own comment gives:
    /// the token is what `.v3d` carries, so a later value appended to the set
    /// cannot reshuffle a stored file. The declaration that pins the set is
    /// the `Param.enum_` in `layer_params.d`.
    ///
    /// No "camera" value: we have no camera item to project from.
    string projection = "front";
    /// Whether the plane is also drawn in a free-orbit (perspective) cell.
    /// The measured channel is the NEGATIVE `hide in perspective`, default
    /// "shown"; the positive spelling is the reference's own UI label and is
    /// what this field carries, so the default reads `true` rather than
    /// `false` meaning the same thing.
    bool showInPerspective = true;

    // ---- how big it is ---------------------------------------------------
    /// World metres per image pixel — the channel that makes "a 1 m backdrop
    /// makes a 1 m character" expressible at all, and the one the whole task
    /// is for. A LIVE property, not an import-time constant: writing it after
    /// the clip is linked resizes the plane (measured, 2026-08-09).
    ///
    /// Bounded at its `Param` declaration (`layer_params.d`) with an enforced
    /// floor, so a zero or a NaN cannot reach the extent formula and produce
    /// a degenerate or non-finite quad. It is not count-like — nothing
    /// allocates or loops on it — so it owes no kernel `MAX_` cap.
    float pixelSize = 0.01f;
    /// Whether the image's proportion is locked. It selects between two
    /// extent LAWS (measured): on, the base is `(W*p, H*p)` scaled by the
    /// single factor `min(sx, sy)`; off, the base is the image's HEIGHT on
    /// both axes and the scale applies per-axis. It is NOT a constraint on
    /// the scale gesture — that reading was measured false — which is why it
    /// lives here, on the item, and not in the transform tool.
    bool keepAspect = true;

    // ---- what it looks like ---------------------------------------------
    // Three signed/unsigned fractions rather than the measured "percent"
    // type: a fraction is what the shader multiplies by, and carrying 0..100
    // here would put a unit conversion between the channel and its only
    // consumer. Each is bounded with `enforceBounds` at its declaration.
    float brightness   = 0.0f;   ///< -1 .. +1; 0 = unchanged
    float contrast     = 0.0f;   ///< -1 .. +1; 0 = unchanged
    float transparency = 0.0f;   ///<  0 .. 1;  0 = opaque, 1 = invisible
    bool  invert       = false;  ///< invert RGB (a pencil drawing on white)
    bool  flipHorizontal = false;///< mirror across the plane's vertical axis
    bool  smooth       = false;  ///< filter neighbouring pixels (low-res scans)
}

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
final class Layer {
    // Task 0615 Stage 5: PRIVATE + renamed from the public `mesh`. This is the
    // enforcement mechanism, not cosmetics — every direct payload consumer
    // outside this module becomes a compile error, and the compiler's error
    // list IS the audit (§Consumer inventory, tier 1). Reach it only through
    // `hasMesh()` / `meshOrNull()` / `meshRef()` / `Document.meshLayers()`.
    private Mesh mesh_;         ///< the layer's geometry (stable heap address)
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
    ref inout(Mesh) meshRef() inout {
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
/// edit target (task 0654): the viewport draw, the screen-space caches, the
/// picking projections — everything that must produce a frame rather than an
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
ref Mesh noEditTargetMesh() { return g_noEditTargetMesh; }

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
    assert(!doc.background(doc.active()), "bootstrap layer is foreground (not background)");
    assert(doc.foreground(doc.active()), "bootstrap layer is foreground (derived)");
    // SET-of-one + primary invariants.
    assert(doc.primary !is null, "primary is non-null");
    assert(doc.primary is doc.active(), "primary == active");
    assert(doc.primary is doc.layers[doc.activeIndex], "primary == layers[activeIndex]");
    assert(doc.primary.selected, "primary is selected");
    size_t selCount = 0;
    foreach (l; doc.layers) if (l.selected) ++selCount;
    assert(selCount == 1, "exactly one layer selected (SET-of-one)");
    assert(doc.isPrimary(doc.active()), "isPrimary(active) is true");
    assert(doc.isFocused(doc.focusedItem), "isFocused(focusedItem) is true");
    assert(doc.isFocused(doc.active()), "on an all-mesh document, focus == primary");
}



// ---------------------------------------------------------------------------
// Stage 2a/2b contract: the multi-select mutators + the FULLY DERIVED
// background/foreground rule. A shared helper asserts the load-bearing
// invariants AND that the derived helpers track `selected`/`visible` exactly
// (there is no longer any stored bool — Stage 2b deleted it).
// ---------------------------------------------------------------------------

/// TEST-ONLY oracle for the in-module unit tests below. Every check here is
/// a plain `assert()`, which `-release` strips entirely (dlang.org: `-release`
/// disables assertions other than `assert(0)`) — this function enforces
/// nothing in a release binary; production code must never come to depend on
/// it firing.
private void assertDocInvariants(ref Document d) {
    assert(d.layers.length >= 1, "layers.length >= 1");
    // TASK 0654 — the three clauses that used to sit here ("primary non-null",
    // "focusedItem non-null", "at least one layer is always selected") are
    // replaced by the BICONDITIONAL. The oracle no longer forbids the empty
    // state; it forbids every HALFWAY state around it, which is the part that
    // is actually load-bearing now.
    // TASK 0668 — the biconditional SPLIT. `focusedItem` still tracks
    // emptiness exactly; `primary` now tracks whether anything SELECTED can
    // be the edit target, which is a strictly weaker question. `empty` below
    // therefore means "no edit target", not "nothing selected" — the two
    // parted company the moment an item that cannot be primary was allowed to
    // be the only selected one.
    // TASK 0671 — `primary` is a WALK now, so the oracle reads it ONCE and
    // asserts against that value. Re-reading it per clause would let a walk
    // that is not a function of the state pass by answering differently each
    // time, which is the one failure mode a derived target has that a stored
    // one does not.
    auto prim = d.primary;
    immutable bool empty = prim is null;
    bool primaryInLayers = false;
    bool focusedInLayers = false;
    bool anyCanBePrimary = false;
    size_t selCount = 0;
    size_t stateCanBePrimary = 0;
    foreach (l; d.layers) {
        if (l is prim) primaryInLayers = true;
        if (l is d.focusedItem) focusedInLayers = true;
        if (l.selected) ++selCount;
        if (kindInfo(l.kind).canBePrimary && d.selectionState(l) != SelState.None)
            ++stateCanBePrimary;
        if (kindInfo(l.kind).canBePrimary) anyCanBePrimary = true;
        // Task 0671: the derivation is `roleOf`, and these two are one arm of
        // it each. Restated so a `foreground`/`background` that stopped
        // agreeing with the classifier is caught here rather than at whichever
        // consumer noticed first.
        assert(d.background(l) == (d.roleOf(l) == LayerRole.Background),
            "derived background() == roleOf() is Background");
        assert(d.foreground(l) == (d.roleOf(l) == LayerRole.Foreground),
            "derived foreground() == roleOf() is Foreground");
        // A layer is never simultaneously foreground and background.
        assert(!(d.foreground(l) && d.background(l)),
            "foreground and background are mutually exclusive");
        // Task 0671: an item is never in BOTH lists. `selectionState` resolves
        // current-first so it could never SAY so, which is exactly why the
        // storage has to be checked directly.
        if (l.selected)
            foreach (h; d.deselected_[l.kind])
                assert(h !is l,
                    "a CURRENT item must not also sit in its kind's history bucket");
    }
    assert(empty || primaryInLayers, "primary is a member of layers");
    // TASK 0671 — the primary is NOT necessarily selected any more. That
    // clause was the storage model talking: it held because a stored pointer
    // had to be kept pointing at something the user could see marked. A
    // latched target is in the history list, and the whole point is that it
    // survives its own deselection. What it must still be is FOREGROUND, which
    // is the property every consumer actually depends on.
    assert(empty || d.roleOf(prim) == LayerRole.Foreground,
        "the edit target is a foreground layer (task 0671)");
    assert(empty || d.selectionState(prim) != SelState.None,
        "the edit target has a non-zero selection state (task 0671)");
    // The focus is the SELECTION's pointer, so it is governed by `selCount`,
    // not by `empty` (task 0668). Keeping it on `empty` would have made this
    // oracle reject the very state the task exists to produce.
    immutable bool noSelection = selCount == 0;
    assert((d.focusedItem is null) == noSelection,
        "focusedItem is null exactly when nothing is selected (task 0654/0668)");
    assert(noSelection || focusedInLayers, "focusedItem is a member of layers (task 0615)");
    assert(noSelection || d.focusedItem.selected,
        "focusedItem is selected (task 0615; relaxed from Stage 2's focusedItem is primary)");
    // The other direction, restated for 0671: no primary ⟺ no `canBePrimary`
    // item has a non-zero SELECTION STATE. 0668's version of this line read
    // `selected` and would now reject the very state this task exists to
    // produce — a mesh latched in the history bucket with nothing selected.
    // Without the clause in some form the oracle would accept "no target while
    // a targetable item is foreground", i.e. an edit target available and the
    // walk failing to find it.
    assert(empty == (stateCanBePrimary == 0),
        "primary is null exactly when no item with a selection state can be "
        ~ "the edit target (task 0671)");
    // …and it really is the WALK's head, not merely some candidate. This is
    // the clause that would catch a `primary` re-implemented as anything other
    // than `nthEditTargetCandidate(0)`.
    assert(prim is d.nthEditTargetCandidate(0),
        "the edit target is the head of the foreground walk (task 0671)");
    // NIT: `anyCanBePrimary` is already implied by `primaryInLayers` + the
    // `canBePrimary` assertion just below (primary is itself a layer that
    // can be primary), so it cannot currently fail independently. Kept
    // anyway — it documents the invariant directly and is free if the two
    // facts it depends on are ever decoupled by a future change.
    //
    // SF3 (review round 2): this oracle must key on the CAPABILITY
    // (`canBePrimary`), not on mesh-ness (`hasMesh`) — every refuse path in
    // `exclusiveSelect` / `rehomePrimary` / `anotherPrimaryCandidate` keys
    // on `canBePrimary`, and today the two coincide only because `Mesh` is
    // the sole `canBePrimary` kind. A future kind with a mesh but barred
    // from being the edit target (e.g. read-only reference geometry) would
    // silently decouple a `hasMesh`-keyed oracle from the invariant it is
    // meant to guard.
    assert(anyCanBePrimary, "at least one layer can be primary (document invariant, task 0615)");
    assert(empty || kindInfo(prim.kind).canBePrimary,
        "primary can always be primary (task 0615, §Q2)");
    // activeIndex (derived) tracks the primary by identity — and answers the
    // OUT-OF-RANGE sentinel, never `0`, when there is no primary (task 0654).
    if (empty)
        assert(d.activeIndex == d.layers.length,
            "activeIndex is the absent-sentinel when there is no primary (task 0654)");
    else
        assert(d.layers[d.activeIndex] is prim, "activeIndex points at primary");
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

unittest {  // mode:add accumulates selection; the target stays on the HEAD.
    // TASK 0671 — INTENT CHANGE. This case used to assert "add promotes the
    // newest to primary", which is the reading a stored pointer invites and
    // which the reference contradicts: with `set B; add A` the target is B,
    // the EARLIER one. The current selection is a queue and the target is its
    // head, so an add appends and changes nothing about who is being edited.
    // (Frozen: `tests/fixtures/edit_target_legality.json`, cell
    // `flush_is_per_item_kind` step 3, whose `foreground_order` column pins
    // the order this test reads through `foregroundLayersInto`.)
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && !c.selected, "add keeps prior selection");
    assert(doc.primary is a, "add does NOT promote — the target is the head, A");
    assert(doc.focusedItem is b, "…but the FOCUS is the newest touch, B");
    doc.selectItem(c, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && c.selected, "three selected (multi-foreground)");
    assert(doc.primary is a, "still the head");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 3 && fg[0] is a && fg[1] is b && fg[2] is c,
        "the foreground list is the selection queue in SEAT order, and the "
        ~ "target is its head — one walk, two questions");
}

unittest {  // mode:add in REVERSE layer order: seat order, not `layers` order.
    // The discriminating rig for the ordering law. `set C; add A` selects the
    // LAST layer first, so an implementation that reads `layers` order answers
    // A and the seat order answers C. Without this, both readings agree on
    // every ascending rig above.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], c = doc.layers[2];
    doc.selectItem(c, SelMode.Set);
    doc.selectItem(a, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is c,
        "the target is the earliest SELECTED, not the earliest LISTED — a "
        ~ "`layers`-order walk answers A here");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 2 && fg[0] is c && fg[1] is a,
        "…and the list is in the same order the target was picked from");
}

unittest {  // mode:remove of the target: CURRENT outranks HISTORY.
    // TASK 0671 — the case that separates "history is a second queue" from
    // "history is just more of the first". The removed item keeps a non-zero
    // selection state and its seat (1, the earliest of the three), so a walk
    // that merged the two lists by seat would put it back at the head and the
    // target would never move off a deselected layer. It does not: the walk
    // runs CURRENT to exhaustion first, so the target promotes to B — and the
    // latched A is still in the list, just last.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    doc.selectItem(c, SelMode.Add);            // A,B,C selected; A is the head
    doc.selectItem(a, SelMode.Remove);         // remove the TARGET
    assertDocInvariants(doc);
    assert(!a.selected, "A deselected");
    assert(doc.selectionState(a) == SelState.History, "…into the mesh bucket");
    assert(doc.primary is b,
        "the target promoted to the first remaining CURRENT item, even though "
        ~ "the latched A holds an earlier seat — a seat-only merge answers A");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 3 && fg[0] is b && fg[1] is c && fg[2] is a,
        "the WALK is current-then-history: B, C, then the latched A");
    assert(doc.primary is fg[0], "…and the target is the head of it");
}

unittest {  // mode:remove of a NON-target keeps the target.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A target, B focus
    doc.selectItem(b, SelMode.Remove);         // remove the non-target, focused B
    assertDocInvariants(doc);
    assert(!b.selected && a.selected, "B deselected, A remains");
    assert(doc.primary is a, "the target is unchanged on a non-target remove");
    assert(doc.focusedItem is a, "focus fell back to the remaining current item");
}

unittest {  // S3: selectItem(Remove) must re-home focus ONLY when the
            // removed layer itself held focus — an unrelated, still-
            // selected, still-valid focus must survive. Behavioural check
            // (which layer focus is on after the sequence), not just an
            // invariant pass — assertDocInvariants alone cannot see this.
            //
            // NIT (review round 2): reach the split state (primary !=
            // focusedItem) through REAL mutators, not a raw `doc.focusedItem
            // = …` field write — no mutator can produce that split on an
            // all-mesh document (every mutator keeps primary/focusedItem in
            // lockstep when every layer can be primary). The mixed-document
            // fixture reaches the identical split legitimately: Add on a
            // non-mesh layer moves focus without moving primary (§L2).
    auto doc = mixedDoc();                     // [meshA(primary+focus), empty, meshB]
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(meshB, SelMode.Add);        // meshA, meshB selected; meshB primary+focus
    doc.setPrimary(meshA);                     // primary+focus back to meshA
    doc.selectItem(empty, SelMode.Add);        // + empty selected; focus->empty, primary stays meshA
    assertDocInvariants(doc);
    assert(doc.primary is meshA && doc.focusedItem is empty && meshB.selected);
    // Discriminating check for `isFocused` (review round): the bootstrap
    // unittest's `isFocused` checks pass even if the predicate were
    // mis-written to compare against the edit target (`primary`/`active()`)
    // instead of `focusedItem`, because on an all-mesh document the two
    // coincide. Here they deliberately do NOT: meshA is primary but must NOT
    // be focused, empty holds focus but is NOT primary.
    assert(!doc.isFocused(meshA), "isFocused: the mesh primary is not the focus here");
    assert(doc.isFocused(empty),  "isFocused: the non-mesh item holds the focus here");

    doc.selectItem(meshB, SelMode.Remove);     // remove meshB: neither primary(meshA) nor focus(empty)
    assertDocInvariants(doc);
    assert(!meshB.selected, "meshB deselected");
    assert(doc.primary is meshA, "primary untouched by an unrelated remove");
    assert(doc.focusedItem is empty, "focus untouched by an unrelated remove");
}

unittest {  // mode:remove of the LAST selected EMPTIES the selection (task 0654)
            // — and KEEPS the edit target (task 0671).
    // ~~INTENT CHANGE, not a repaired test. This case used to assert the exact
    // opposite ("cannot deselect the last selected layer") because the ≥1
    // invariant made emptying unrepresentable. 0653 measured the reference —
    // ctrl-clicking the last selected item empties — and the owner decided we
    // follow it, so the old assertion is now pinning behaviour we deliberately
    // removed.~~
    //
    // SECOND INTENT CHANGE (task 0671), and it is the half 0653 could not see.
    // 0653 measured that the SELECTION empties; the line that followed it here
    // ("and drops the primary with it") was never measured — it was forced,
    // because in the model of the day there was nowhere else for the target to
    // live. 0670 read the mechanism: deselecting MOVES the item into its
    // kind's history bucket, its selection state stays non-zero, and the walk
    // still finds it. So the selection empties and the mesh is still the thing
    // you are editing.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];
    doc.selectItem(a, SelMode.Remove);         // A is the only selected
    assertDocInvariants(doc);
    assert(!a.selected, "removing the last selected layer deselects it (task 0654)");
    assert(doc.selectedItemCount() == 0, "the item selection is empty");
    assert(doc.focusedItem is null, "the FOCUS goes with the selection — it is the "
        ~ "current list's pointer and the current list is empty");
    assert(doc.selectionState(a) == SelState.History,
        "…and A moved into the mesh history bucket rather than out of existence");
    assert(doc.primary is a && doc.hasEditTarget(),
        "task 0671: the edit target is the head of [current ++ history], so it "
        ~ "is still A. A model that read `selected` would answer null here.");
    assert(doc.foreground(a),
        "…and A draws as FOREGROUND, not as a dimmed background layer being "
        ~ "silently edited — the objection 0668 raised, answered");
    assert(doc.activeIndex == 0, "activeIndex follows the latched target");
    assert(doc.activeMesh() !is null, "there is a mesh to bind");
}

unittest {  // the absent edit target, reached the way the reference reaches it
            // (task 0671): every mesh's bucket flushed, then the holder gone.
    //
    // WHY NOT `clearItemSelection` ANY MORE: it does not produce this state, it
    // produces the LATCHED one (the unittest above). Building the no-target
    // state now takes a document in which no `canBePrimary` item has any
    // selection state at all — here, one assembled without ever selecting.
    Document doc;
    auto a = new Layer; a.name = "A";
    auto b = new Layer; b.name = "B";
    doc.layers = [a, b];
    assertDocInvariants(doc);
    assert(doc.primary is null && !doc.hasEditTarget(),
        "nothing has a selection state, so the walk is empty");
    assert(doc.focusedItem is null, "and nothing is selected");
    // The absent-sentinel, spelled out: a consumer that indexes `layers` with
    // this gets a bounds error, not layer 0's geometry.
    assert(doc.activeIndex == doc.layers.length,
        "activeIndex is the absent-sentinel, NOT 0");
    assert(doc.activeMesh() is null, "activeMesh() refuses by returning null");
    bool threw = false;
    try { doc.activeMeshRef(); } catch (NoEditTargetException) { threw = true; }
    assert(threw, "activeMeshRef() refuses by throwing NoEditTargetException");
    // Both are BACKGROUND — this is what "everything dims" looks like, and it
    // is a different state from the latched one above where A is foreground.
    foreach (l; doc.layers)
        assert(doc.background(l) && !doc.foreground(l),
            "with no selection state anywhere, every visible layer is background");
    // …and it is not a trap: one select recovers.
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b && doc.hasEditTarget(),
        "a select out of the no-target state installs a target again");
}

unittest {  // clearItemSelection empties the SELECTION in one transition, is
            // idempotent, and LEAVES THE EDIT TARGET (task 0671).
    auto doc = threeLayerDoc();
    doc.selectItem(doc.layers[1], SelMode.Add);   // {A, B}
    assert(doc.selectedItemCount() == 2, "precondition: two selected");
    assert(doc.primary is doc.layers[0],
        "precondition: the target is the queue HEAD (A, selected first), not "
        ~ "the newest addition — task 0671");
    doc.clearItemSelection();
    assertDocInvariants(doc);
    assert(doc.selectedItemCount() == 0 && doc.focusedItem is null,
        "clear empties the whole set at once");
    doc.clearItemSelection();                     // idempotent
    assertDocInvariants(doc);
    assert(doc.selectedItemCount() == 0, "clearing an empty selection is a no-op");
    // TASK 0671 — the target survived, and it is still the head of the same
    // order: both A and B went into the mesh bucket, A was seated first.
    assert(doc.primary is doc.layers[0],
        "an empty item selection with a live edit target is a LEGAL state "
        ~ "(frozen fixture edit_target_legality / target_set_nothing_selected)");
    assert(doc.foreground(doc.layers[0]) && doc.foreground(doc.layers[1]),
        "…and both latched meshes are foreground: two foreground layers with "
        ~ "nothing selected, which is the walk's own answer and not a special case");
    assert(doc.background(doc.layers[2]),
        "the mesh that was never selected is background — the negative control, "
        ~ "without which 'everything is foreground' would pass here");
    // Selecting again re-flushes the bucket, so the latch does not accumulate.
    doc.selectItem(doc.layers[2], SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is doc.layers[2] && doc.hasEditTarget(),
        "a select out of the empty state installs a primary again");
    assert(doc.foregroundLayerCount() == 1,
        "…and exactly one: selecting a MESH flushes the mesh bucket, so the two "
        ~ "latched layers are gone from the walk rather than joining it");
}

unittest {  // mode:toggle flips selection (remove ↔ add).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Toggle);         // B not selected → add
    assertDocInvariants(doc);
    // TASK 0671 — `add` does NOT promote. The target is the queue head, and A
    // was seated first. This line used to read `doc.primary is b`.
    assert(b.selected && doc.primary is a,
        "toggle-on selects, and the target stays on the earlier-seated A");
    doc.selectItem(b, SelMode.Toggle);         // B selected → remove
    assertDocInvariants(doc);
    assert(!b.selected, "toggle-off deselects");
    assert(doc.primary is a, "the target was on A throughout");
}

unittest {  // setPrimary RE-SEATS an already-selected member at the front.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    assert(doc.primary is a, "precondition: the head is A (task 0671)");
    doc.setPrimary(b);                         // re-seat B at the front
    assertDocInvariants(doc);
    assert(a.selected && b.selected, "set is preserved");
    assert(doc.primary is b, "setPrimary moved the edit target to B");
    assert(doc.selectedItemCount() == 2, "…without deselecting anyone");
    // setPrimary on a not-yet-selected layer selects it (focus invariant).
    auto c = doc.layers[2];
    doc.setPrimary(c);
    assertDocInvariants(doc);
    assert(c.selected && doc.primary is c, "setPrimary selects + re-seats");
    assert(doc.selectedItemCount() == 3, "…and still does not deselect anyone");
}

unittest {  // TASK 0671 — HIDING THE EDIT TARGET DOES NOT MOVE IT.
    // ~~hide-primary promotion: setVisible(false) on primary moves it.~~
    // ~~S2: hiding the primary must not steal focus from an unrelated item.~~
    // ~~hide-primary refusal: no other selected+visible layer.~~
    //
    // Three cases retired into one, because the behaviour all three pinned was
    // an artefact of `foreground(l) == visible && selected`: a hidden primary
    // was neither foreground nor background, so it HAD to be handed on or the
    // hide had to be refused. Measured (`tests/fixtures/
    // edit_target_legality.json`, cell `hidden_mesh_keeps_the_target`) the
    // reference does neither — visibility and targethood are independent, and
    // its own classifier says so: the hidden arm keeps a targetable item
    // FOREGROUND instead of dropping it. `promoteAwayFromHiddenPrimary` is now
    // the constant `true` and this is what replaces its three tests.
    //
    // The CONTROL is the third block: the target still moves normally when a
    // different mesh is selected, so the first two are not a frozen read.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    assert(doc.primary is a, "precondition: A holds the target");

    a.visible = false;                         // hide the TARGET
    assert(doc.promoteAwayFromHiddenPrimary(), "hiding is never refused now");
    assertDocInvariants(doc);
    assert(doc.primary is a,
        "THE MEASUREMENT: a hidden layer is still the edit target — B does not "
        ~ "inherit it, and the hide is not refused");
    assert(doc.foreground(a),
        "…and it classifies FOREGROUND while hidden, which is what stops the "
        ~ "walk skipping it");
    assert(doc.roleOf(a) != LayerRole.Background,
        "…and specifically NOT background: it must not become a dimmed snap "
        ~ "source while it is the thing being edited");
    assert(doc.focusedItem is b, "the focus is untouched by any of this");

    // A hidden mesh with NO selection state is not a layer at all — the
    // negative control for the arm above, which would otherwise pass for an
    // implementation that made every hidden mesh foreground.
    auto c = doc.layers[2];
    c.visible = false;
    assert(doc.roleOf(c) == LayerRole.None,
        "a hidden item with no selection state is neither foreground nor "
        ~ "background — the reference's 'none of those' state");

    // CONTROL: the target still moves.
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b, "CONTROL: selecting another mesh moves the target");
    assert(!doc.foreground(a),
        "…and the hidden former target loses its state entirely, because "
        ~ "selecting a mesh FLUSHES the mesh bucket");
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 1: `ItemKind` + the capability table. Pure lookups — no
// `Document` involved yet.
// ---------------------------------------------------------------------------




unittest {  // a default-constructed Layer is a mesh item.
    auto l = new Layer;
    assert(l.kind == ItemKind.Mesh, "new Layer defaults to ItemKind.Mesh");
    assert(l.hasMesh, "a default Layer has a mesh");
    assert(l.meshOrNull !is null, "meshOrNull is non-null for a mesh item");
    assert(l.meshOrNull is &l.mesh_, "meshOrNull points at the mesh field");
    assert(&l.meshRef() is &l.mesh_, "meshRef() aliases the same mesh field");
}


// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T2 (capability-row half): `kindInfo(ItemKind.Image)`
// field by field, and the image-payload accessor trio (mirrors the mesh
// trio tests just above).
// ---------------------------------------------------------------------------


unittest {  // hasImage()/imageOrNull()/imageRef() mirror the mesh trio: a
            // non-image item reports no image through the capability
            // accessors, and an image item's imageRef() aliases the same
            // field imageOrNull() reads.
    auto mesh = new Layer;
    assert(!mesh.hasImage, "a default (mesh-kind) Layer has no image capability");
    assert(mesh.imageOrNull is null, "imageOrNull is null for a non-image item");

    auto img = new Layer;
    img.kind = ItemKind.Image;
    assert(img.hasImage, "an Image-kind layer has the image capability");
    // Freshly kind-flipped, no payload constructed yet — capability true,
    // instance payload still null (mirrors "hasMesh answers CAN, not DOES").
    assert(img.imageOrNull is null, "imageOrNull is null until something constructs an ImageData");

    img.imageRef() = new ImageData();

    // A fresh `ImageData`'s FIELD INITIALISERS, read before anything
    // overwrites them. These are reference-measured contract values (see the
    // `ImageData` declaration above), and until this assertion existed a typo
    // in either initialiser was invisible to the whole suite: the param
    // `default_` that layer_params.d declares is an INDEPENDENT literal in a
    // different module, so `bool useAlpha = false;` here would have kept every
    // param-side default assertion green while silently changing what a newly
    // constructed image item means. `storedPath` needs no such line — it has
    // no initialiser (empty is `string.init`) and is overwritten below.
    assert(img.imageOrNull.colorspace == "(default)",
        "a fresh ImageData initialises colorspace to '(default)'");
    assert(img.imageOrNull.useAlpha == true,
        "a fresh ImageData initialises useAlpha to true");

    img.imageRef().storedPath = "logo.png";
    assert(img.imageOrNull !is null, "imageOrNull is non-null once imageRef() is assigned");
    assert(img.imageOrNull.storedPath == "logo.png", "imageOrNull aliases the same object imageRef() wrote");
    assert(&img.imageRef() is &img.image_, "imageRef() aliases the same image_ field");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 6 (Ph3): the consumer → item link.
//
// The fixture below is built to defeat the two ways a link test goes inert:
//
//   * THREE image items, TWO consumers. With one of each, "the link resolved
//     to the right item" is indistinguishable from "everything resolves to
//     the only item there is", and a sweep that clears the first match and
//     stops is indistinguishable from a correct one.
//   * TWO of the images share one `storedPath`. A path-keyed implementation
//     then resolves to the WRONG one of the two, with a different name to
//     read — so "a path is not identity" has an observable value, not just an
//     argument.
//   * Deletes happen in the MIDDLE of the list. Deleting the tail cannot tell
//     "the link reports dangling" apart from "an index was clamped into an
//     empty range", and cannot expose the index scheme's real failure — the
//     slot past the hole changing owner.
// ---------------------------------------------------------------------------

version (unittest) {
    private struct LinkFixture {
        Document doc;
        Layer meshLayer, clipA, clipB, clipC, consumerX, consumerY;
    }

    /// layers = [mesh, clipA, clipB, clipC, consumerX, consumerY]
    ///   clipA and clipB deliberately share one storedPath;
    ///   consumerX links backdropImage→clipB and maskImage→clipC,
    ///   consumerY links backdropImage→clipB  (many→one on clipB).
    private LinkFixture makeLinkFixture() {
        LinkFixture f;
        Mesh m;
        f.doc = Document.bootstrap(m);
        f.meshLayer = f.doc.layers[0];

        Layer mkClip(string name, string path) {
            auto l = new Layer;
            l.kind = ItemKind.Image;
            l.name = name;
            l.imageRef() = new ImageData();
            l.imageRef().storedPath = path;
            return l;
        }
        Layer mkConsumer(string name) {
            auto l = new Layer;
            l.kind = ItemKind.Empty;   // a scene item that is not itself an image
            l.name = name;
            return l;
        }

        f.clipA = mkClip("clipA", "shared.png");
        f.clipB = mkClip("clipB", "shared.png");   // SAME file, different item
        f.clipC = mkClip("clipC", "other.png");
        f.consumerX = mkConsumer("consumerX");
        f.consumerY = mkConsumer("consumerY");
        f.doc.layers ~= [f.clipA, f.clipB, f.clipC, f.consumerX, f.consumerY];

        // Slots set in REVERSE alphabetical order, so the canonical ordering
        // `linkSlots()` promises is produced by the insert, not by luck.
        f.consumerX.setLink("maskImage",     f.clipC);
        f.consumerX.setLink("backdropImage", f.clipB);
        f.consumerY.setLink("backdropImage", f.clipB);
        return f;
    }
}

unittest {  // Ph3 core: many→one, per-slot independence, canonical slot order,
            // and the reverse sweep. Every assertion here needs at least two
            // clips or two slots to be able to fail.
    auto f = makeLinkFixture();

    auto xBack = f.consumerX.link("backdropImage").resolve(f.doc);
    auto yBack = f.consumerY.link("backdropImage").resolve(f.doc);
    auto xMask = f.consumerX.link("maskImage").resolve(f.doc);

    assert(xBack is f.clipB, "consumerX's backdrop link resolves to clipB");
    assert(yBack is f.clipB, "consumerY's backdrop link resolves to clipB");
    assert(xBack is yBack,
        "two consumers of one image must resolve to the SAME object, not to "
        ~ "two equal-looking ones");
    assert(xMask is f.clipC,
        "a second named slot on the SAME consumer is independent — this is "
        ~ "clipC, not the other slot's clipB");

    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Live);
    assert(f.consumerX.link("noSuchSlot").state(f.doc) == LinkState.Unset,
        "an absent slot is Unset, not Dangling and not a crash");
    assert(f.consumerX.link("noSuchSlot").resolve(f.doc) is null);
    assert(f.meshLayer.linkSlots().length == 0, "an item with no links has no slots");

    // A READ-ONLY handle can ask for one slot by name, not merely enumerate
    // them (review NIT 1). This is a compile-time claim as much as a runtime
    // one: `link()` was mutable-only, so this line did not compile at all and
    // a `const(Layer)` consumer had to hand-scan `linkSlots()`.
    {
        const(Layer) ro = f.consumerX;
        assert(ro.link("backdropImage").targetUnchecked() is f.clipB,
            "a const(Layer) resolves one named slot");
        assert(ro.link("noSuchSlot").isSet() == false,
            "and gets the Unset link for an absent one, same as a mutable one");
    }

    // Canonical order, and the exact slot set — inserted mask-then-backdrop.
    auto slots = f.consumerX.linkSlots();
    assert(slots.length == 2, "consumerX has exactly two slots");
    assert(slots[0].name == "backdropImage" && slots[1].name == "maskImage",
        "linkSlots() is name-sorted regardless of insertion order");

    // The reverse direction. clipB has two referrers, in layers order.
    Layer[] refs;
    f.doc.referrersOf(f.clipB, refs);
    assert(refs.length == 2, "clipB has two referrers");
    assert(refs[0] is f.consumerX && refs[1] is f.consumerY,
        "referrersOf reports in layers order");

    // A PATH IS NOT IDENTITY. clipA carries byte-identical `storedPath` to
    // clipB and is reached by nothing — a path-keyed link or a path-keyed
    // sweep would hand back clipA (it is the earlier of the two) and would
    // report clipA as having two referrers.
    assert(f.clipA.imageOrNull.storedPath == f.clipB.imageOrNull.storedPath,
        "fixture vacuity guard: the two clips really do share one path");
    assert(f.clipA !is f.clipB, "…and are still two distinct items");
    f.doc.referrersOf(f.clipA, refs);
    assert(refs.length == 0,
        "nothing links to clipA — sharing a file with clipB is not sharing "
        ~ "clipB's identity");
    f.doc.referrersOf(f.clipC, refs);
    assert(refs.length == 1 && refs[0] is f.consumerX, "clipC has one referrer");
}

unittest {  // A NAME IS NOT IDENTITY — renaming either end changes nothing.
    auto f = makeLinkFixture();

    f.clipB.name     = "renamed";      // the target
    f.consumerX.name = "consumerX2";   // and the consumer, for good measure

    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "rename must not break the link");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "…for either consumer");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "…and must not disturb the sibling slot");
    assert(f.consumerX.linkSlots()[0].name == "backdropImage",
        "the SLOT name belongs to the consumer, not to the target — a target "
        ~ "rename does not rename the slot");

    // Names are not even unique: give a second item the renamed one's name and
    // the link still names exactly one item.
    f.clipC.name = "renamed";
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "two items may share a name; the link still resolves to one of them");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "…and the other slot still resolves to the OTHER one");
}

unittest {  // AN INDEX IS NOT IDENTITY — a pure reorder of layers[] moves
            // every slot number and no link.
    auto f = makeLinkFixture();
    assert(f.doc.indexOf(f.clipB) == 2 && f.doc.indexOf(f.clipC) == 3,
        "fixture vacuity guard: clipB at 2, clipC at 3 before the permute");

    // Move clipB (2) to the tail — the shape `layer.reorder` produces.
    f.doc.layers = f.doc.layers[0 .. 2] ~ f.doc.layers[3 .. $] ~ f.clipB;
    assert(f.doc.indexOf(f.clipB) == 5 && f.doc.indexOf(f.clipC) == 2,
        "vacuity guard: both slot numbers really did change");

    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "reorder must not move a link");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB);
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC);
}

unittest {  // Deleting the MIDDLE clip: both links report themselves dangling,
            // the sibling slot is untouched, and nothing swaps to a neighbour.
    auto f = makeLinkFixture();
    immutable size_t bIdx = f.doc.indexOf(f.clipB);
    assert(bIdx == 2, "vacuity guard: clipB is a MIDDLE layer, not the tail");

    // Splice clipB out — the exact operation LayerDelete performs.
    f.doc.layers = f.doc.layers[0 .. bIdx] ~ f.doc.layers[bIdx + 1 .. $];
    assert(f.doc.layers.length == 5,
        "vacuity guard: the list is still non-empty, so 'dangling' cannot be "
        ~ "an index clamped into an empty range");

    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Dangling,
        "a link to a deleted item reports Dangling");
    assert(f.consumerY.link("backdropImage").state(f.doc) == LinkState.Dangling,
        "…for BOTH consumers — not just the first one a sweep would reach");
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is null,
        "a dangling link resolves to null");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is null);
    assert(f.consumerX.link("backdropImage").state(f.doc) != LinkState.Unset,
        "Dangling is distinguishable from Unset — 'the image you chose was "
        ~ "deleted' is not the same statement as 'you chose no image'");

    // NOT A SILENT SWAP. clipC sat at slot 3; the delete slid consumerX into
    // that slot. A link that stored the NUMBER 3 would now hand back
    // consumerX — a live, plausible-looking, completely wrong item. The first
    // assertion is the vacuity guard that proves the slot really changed
    // owner, so the second one is testing something.
    assert(f.doc.layers[3] is f.consumerX,
        "vacuity guard: the middle delete moved a DIFFERENT item into clipC's "
        ~ "old slot 3");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "the surviving link followed the OBJECT, not the slot number");
    assert(f.consumerX.link("maskImage").state(f.doc) == LinkState.Live);

    // The identity survives even though the resolution does not — which is
    // what makes the reverse sweep able to answer "who was pointing at the
    // thing that just went", the question a re-point UI or a later
    // clear-on-delete policy has to ask.
    assert(f.consumerX.link("backdropImage").targetUnchecked() is f.clipB,
        "a dangling link still names WHICH item it lost");
    Layer[] refs;
    f.doc.referrersOf(f.clipB, refs);
    assert(refs.length == 2 && refs[0] is f.consumerX && refs[1] is f.consumerY,
        "referrersOf still finds both consumers of the deleted clip");

    // Undo shape: reinsert the SAME object at its old slot. Both links are
    // Live again, on one and the same object, with nothing to restore.
    f.doc.layers = f.doc.layers[0 .. bIdx] ~ f.clipB ~ f.doc.layers[bIdx .. $];
    auto xBack = f.consumerX.link("backdropImage").resolve(f.doc);
    auto yBack = f.consumerY.link("backdropImage").resolve(f.doc);
    assert(xBack is f.clipB && yBack is f.clipB,
        "reinserting the object relinks both consumers");
    assert(xBack is yBack,
        "…to ONE object — an implementation that restored two links onto two "
        ~ "objects would pass a 'both are non-null' check");
}

unittest {  // A link answers for the document it is ASKED about. This is the
            // whole-document-replacement case (scene reset, .v3d load,
            // interchange import) — the one no delete-time sweep can cover.
    auto f     = makeLinkFixture();
    auto other = makeLinkFixture();   // same shape, all-new objects

    assert(other.doc.layers[2].name == "clipB",
        "vacuity guard: the other document has a same-named item at the SAME "
        ~ "slot, so an index- or name-keyed link would happily resolve here");
    assert(other.doc.layers[2] !is f.clipB, "…but it is a different object");

    assert(f.consumerX.link("backdropImage").state(other.doc) == LinkState.Dangling,
        "a link into a replaced-away document is Dangling, not Live");
    assert(f.consumerX.link("backdropImage").resolve(other.doc) is null,
        "…and must not resolve into the new document's item at that slot");
    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Live,
        "the same link is still Live against its own document — the state is "
        ~ "a property of the PAIR, not of the link");
}

unittest {  // Slot mutation: replace, clear, the null-target spelling, and the
            // independence a cloned slot set must have.
    auto f = makeLinkFixture();

    // Replace, not append.
    f.consumerX.setLink("backdropImage", f.clipA);
    assert(f.consumerX.linkSlots().length == 2, "re-pointing a slot does not add one");
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipA,
        "the slot now points at clipA");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "…and the OTHER consumer's slot is untouched");

    // Clear, and the null-target spelling of the same thing — one
    // representation of "points at nothing", never a leftover empty slot.
    assert(f.consumerX.clearLink("backdropImage"), "clearLink reports the removal");
    assert(!f.consumerX.clearLink("backdropImage"), "…and reports nothing the second time");
    assert(f.consumerX.linkSlots().length == 1, "the slot is gone, not emptied");
    assert(f.consumerX.linkSlots()[0].name == "maskImage");
    f.consumerX.setLink("maskImage", null);
    assert(f.consumerX.linkSlots().length == 0,
        "setLink(name, null) removes the slot rather than leaving an unset one");

    // Cloning a slot set shares TARGETS but not the slot array.
    auto clone = new Layer;
    clone.kind = ItemKind.Empty;
    clone.name = "clone";
    clone.copyLinksFrom(f.consumerY);
    f.doc.layers ~= clone;
    assert(clone.link("backdropImage").resolve(f.doc) is f.clipB,
        "the clone points at the SAME item, not a copy of it");
    clone.setLink("backdropImage", f.clipC);
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "re-pointing the clone must not write through into the source's slots");
    assert(clone.link("backdropImage").resolve(f.doc) is f.clipC);
}

// ---------------------------------------------------------------------------
// Task 0615 Stages 3 / 3b: the mesh-primary rule (§Q2), the L2 exclusive-
// select formula, and the L1 `rehomePrimary` promotion algorithm — all
// exercised over a MIXED document, which no test before this task could
// build (see plan §Lifecycle invariants, R14).
// ---------------------------------------------------------------------------

/// [MeshA(primary), Empty, MeshB] — the fixture the plan's L1/L2 walkthroughs
/// use, built directly against the type API (no command layer involved).
private Document mixedDoc() {
    Mesh m;
    auto doc = Document.bootstrap(m);           // "Layer 1" == MeshA
    doc.layers[0].name = "MeshA";
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    doc.layers ~= empty;
    doc.layers ~= meshB;
    doc.setActive(0);                            // MeshA primary+focused
    return doc;
}

unittest {  // Stage 3: selecting a non-mesh item (mode:add) moves focus,
            // never primary, and never deselects the mesh primary.
            //
            // TASK 0668 kept this law and inverted only `Set`'s. The pair is
            // the point: without an `Add` row asserting the OPPOSITE outcome,
            // 0668's fix could have been written as "a non-mesh selection
            // never has a primary", which would also drop the edit target on
            // a ctrl-click — where the user is adding to a selection, not
            // replacing it.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    assert(doc.primary is meshA && doc.focusedItem is meshA);

    doc.selectItem(empty, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.focusedItem is empty, "Add on a non-mesh item moves focus");
    assert(doc.primary is meshA, "Add on a non-mesh item never moves primary");
    assert(meshA.selected, "the mesh primary stays selected under Add");
    size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
    assert(sel == 2, "and the set GREW to {meshA, empty} — Add is not Set");
}

unittest {  // TASK 0668 — this INVERTS Stage 3 / L2, which asserted the
            // opposite ("exclusive select of a non-mesh item must not evict
            // the mesh primary"). That law was forced by the pre-0654
            // invariants, not chosen: with a non-null selected primary
            // mandatory, sparing the mesh was the only representable answer.
            // 0654 made an absent primary legal, so exclusive is exclusive for
            // every kind. Both entry points that implement it are covered
            // (selectItem(Set) and setActive).
            //
            // The COUNT is the load-bearing assertion. "The target is
            // selected" passed under the old law too — only `sel == 1`
            // separates "cleared all others" from "cleared none", and the
            // fixture has THREE layers so it also separates it from "cleared
            // exactly one".
    // TASK 0671 — BOTH HALVES AT ONCE, which is the whole point of the task.
    // 0668 bought the reference's selected SET (the non-mesh item ALONE) by
    // spending the edit target; 0670 read the mechanism and there was never a
    // trade to make. Deselecting the mesh moves it into the MESH bucket;
    // selecting the non-mesh item flushes the item's OWN bucket and leaves the
    // mesh one standing; so the set is `{target}` AND the mesh is still the
    // thing being edited. This is `tests/fixtures/layer_main_latched.json`
    // rows 3 and 5, in a unit test.
    static void check(Document doc, Layer meshA, Layer empty) {
        assertDocInvariants(doc);
        assert(doc.primary is meshA,
               "0671: the edit target stays LATCHED on the last-selected mesh");
        assert(!meshA.selected,
               "0668, kept: the exclusive select is exclusive — the mesh is "
               ~ "DESELECTED, not spared, so the SET matches the reference");
        assert(doc.selectionState(meshA) == SelState.History,
               "…and what it became is HISTORY, not nothing: one bucket, and "
               ~ "the non-mesh selection could not reach it");
        assert(doc.foreground(meshA) && !doc.background(meshA),
               "…so it draws FOREGROUND. A latched target that derived as "
               ~ "BACKGROUND — dimmed, read-only, a snap source — while the "
               ~ "toolpipe wrote to it is the state 0668 refused to represent, "
               ~ "and it is not what the reference does either.");
        assert(empty.selected && doc.focusedItem is empty,
               "the target is selected and becomes the focus");
        size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
        assert(sel == 1, "the selected set is exactly {target}");
        assert(doc.hasEditTarget() && doc.activeMesh() !is null,
               "every edit-target accessor answers, because there IS one");
        assert(doc.activeIndex == doc.indexOf(meshA),
               "and activeIndex names the latched mesh");
        // The OTHER mesh in the fixture never had a selection state, so it is
        // background — without this row "everything is foreground" would pass.
        assert(doc.foregroundLayerCount() == 1,
               "exactly one foreground layer: the latched mesh. The non-mesh "
               ~ "item is not a candidate and MeshB never had a state.");
    }

    auto d1 = mixedDoc();
    d1.selectItem(d1.layers[1], SelMode.Set);
    check(d1, d1.layers[0], d1.layers[1]);

    auto d2 = mixedDoc();
    d2.setActive(1);
    check(d2, d2.layers[0], d2.layers[1]);
}

unittest {  // TASK 0671 — the round trip, and the LATCH MOVES.
            // ~~0668: selecting a mesh again RESTORES the edit target.~~ There
            // is nothing to restore now; what this has to show instead is that
            // the latched value is not pinned to one layer — it follows
            // whichever mesh was selected last. Two meshes are what make that
            // observable at all (`layer_main_latched`'s own premise note).
    auto doc = mixedDoc();                           // [MeshA, Empty, MeshB]
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(empty, SelMode.Set);              // plane-alike alone
    assert(doc.primary is meshA, "precondition: latched on MeshA");
    doc.selectItem(meshB, SelMode.Set);              // the OTHER mesh
    assertDocInvariants(doc);
    assert(doc.primary is meshB && doc.focusedItem is meshB,
        "selecting a mesh moves both the target and the focus");
    assert(!meshA.selected && doc.selectionState(meshA) == SelState.None,
        "…and FLUSHES the mesh bucket, so the previously latched MeshA loses "
        ~ "its state entirely rather than accumulating beside MeshB");
    assert(doc.background(meshA), "…which is what makes it background again");
    doc.selectItem(empty, SelMode.Set);              // and latch again
    assertDocInvariants(doc);
    assert(doc.primary is meshB,
        "the latch re-arms on the OTHER mesh — so it is the last mesh selected, "
        ~ "not a value pinned to one particular layer");
    assert(!doc.layers[2].selected, "and the non-mesh item is the whole set");
}

unittest {  // Stage 3: the walk SKIPS the non-mesh candidate, in both queues.
    // TASK 0671 — the mechanism changed under this test and its point did not:
    // a non-mesh item must never end up as the edit target, whichever list it
    // is sitting in. The old rig reached the question through a promotion that
    // no longer happens, so the rig moved; the negative it asserts did not.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.setPrimary(meshB);                       // meshB seated at the front
    doc.selectItem(empty, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is meshB, "precondition: meshB heads the current queue");
    // Drop BOTH meshes, leaving the non-mesh item as the only CURRENT one.
    doc.selectItem(meshB, SelMode.Remove);
    doc.selectItem(meshA, SelMode.Remove);
    assertDocInvariants(doc);
    assert(!meshA.selected && !meshB.selected && empty.selected,
        "the non-mesh item is now the entire current selection");
    assert(doc.primary !is empty && doc.primary !is null,
        "the target is never the non-mesh item — the walk filters on the "
        ~ "capability in BOTH stages, not just in the current one");
    assert(doc.primary is meshB,
        "…and it is the front-seated meshB, which is the head of the history "
        ~ "queue for the same reason it was the head of the current one");
}

unittest {  // Stage 3: setPrimary on a non-mesh item selects it and moves
            // focus, but refuses to move primary and deselects no one.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    doc.setPrimary(empty);
    assertDocInvariants(doc);
    assert(empty.selected, "setPrimary selects the target");
    assert(doc.focusedItem is empty, "setPrimary moves focus");
    assert(doc.primary is meshA, "setPrimary refuses to move primary onto a non-mesh item");
    assert(meshA.selected, "setPrimary must not deselect the prior primary");
}

unittest {  // Stage 3b / L1, RED-before-fix. Fixture from the plan:
            // [MeshA(primary), Empty, MeshB]; splice out MeshA (index 0). The
            // pre-revision wording picks the successor by ARRAY POSITION
            // (`setActive(0)`), landing on Empty — which then leaves `primary`
            // dangling on the spliced-out MeshA. `rehomePrimary` must instead
            // skip Empty and land on MeshB.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.layers = [empty, meshB];                 // MeshA spliced out at index 0
    auto survivor = doc.rehomePrimary(0);
    assert(survivor is meshB, "forward scan from the vacated slot skips Empty");
    // SF3 (review round 2): assert the CAPABILITY (`canBePrimary`), not
    // mesh-ness (`hasMesh`) — see `assertDocInvariants`'s matching fix.
    assert(kindInfo(survivor.kind).canBePrimary, "the survivor can always be primary");

    // Close the loop the way the eventual LayerDelete caller will (Stage 6,
    // plan §L1: `doc.setActive(doc.indexOf(survivor))` — `survivor` is
    // `canBePrimary` by construction, so `setActive` takes its unchanged
    // all-mesh branch and genuinely selects it).
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
    assert(doc.primary is survivor, "primary now names the rehomed survivor");
    assert(doc.layers[doc.activeIndex] is doc.primary,
           "activeIndex now resolves correctly — false under the old positional wording");
}

unittest {  // Stage 3b: removing the layer at the TAIL falls back to a
            // backward scan; matches the plan's [MeshA, Empty, MeshB(primary)].
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.setActive(2);                            // MeshB becomes primary
    assertDocInvariants(doc);
    doc.layers = [meshA, empty];                 // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is meshA, "backward scan over [MeshA, Empty] finds MeshA");

    // NIT: close the loop the same way the forward-scan test above does —
    // leaving the fixture un-set-active'd would violate L1 (primary would
    // still name the spliced-out MeshB) even though the pure `rehomePrimary`
    // query itself already answered correctly.
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
    assert(doc.primary is survivor, "primary now names the rehomed survivor");
}

unittest {  // Stage 3b: an all-mesh document is the DEGENERATE case and must
            // match today's exact positional rule
            // (`commands/layer/commands.d:420-421`), at both `at` extremes.
    auto doc = threeLayerDoc();                  // A(primary), B, C — all mesh
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];

    Document afterRemoveHead = doc;
    afterRemoveHead.layers = [b, c];             // A spliced out at index 0
    assert(afterRemoveHead.rehomePrimary(0) is b, "degenerate case == layers[at]");

    Document afterRemoveTail = doc;
    afterRemoveTail.layers = [a, b];             // C spliced out at index 2
    assert(afterRemoveTail.rehomePrimary(2) is b, "degenerate case == layers[$-1]");
}

unittest {  // NIT: rehomePrimary — a genuinely INTERIOR removal, where the
            // forward scan must step over more than one non-primary
            // candidate before it succeeds (previous tests found the
            // survivor on the very first element checked).
    Mesh m;
    auto doc = Document.bootstrap(m);
    doc.layers[0].name = "MeshA";
    auto loc1  = new Layer; loc1.name  = "Loc1";  loc1.kind  = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    auto loc2  = new Layer; loc2.name  = "Loc2";  loc2.kind  = ItemKind.Empty;
    auto meshC = new Layer; meshC.name = "MeshC";
    doc.layers ~= [loc1, meshB, loc2, meshC];
    doc.setActive(2);                            // MeshB primary
    assertDocInvariants(doc);

    doc.layers = [doc.layers[0], loc1, loc2, meshC]; // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is meshC, "interior forward scan steps over Loc2 to find MeshC");
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
}

unittest {  // NIT: rehomePrimary — forward scan finds nothing at all,
            // forcing a genuinely multi-step BACKWARD scan from an interior
            // position (not just the immediate predecessor).
    Mesh m;
    auto doc = Document.bootstrap(m);
    doc.layers[0].name = "MeshA";
    auto loc1  = new Layer; loc1.name  = "Loc1";  loc1.kind  = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    auto loc2  = new Layer; loc2.name  = "Loc2";  loc2.kind  = ItemKind.Empty;
    auto loc3  = new Layer; loc3.name  = "Loc3";  loc3.kind  = ItemKind.Empty;
    doc.layers ~= [loc1, meshB, loc2, loc3];
    doc.setActive(2);                            // MeshB primary
    assertDocInvariants(doc);

    doc.layers = [doc.layers[0], loc1, loc2, loc3];  // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is doc.layers[0],
        "forward scan finds nothing; backward scan steps over Loc1 to MeshA");
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
}


unittest {  // Stage 3b: indexOf resolves by identity; absent ⇒ layers.length.
    auto doc = mixedDoc();
    assert(doc.indexOf(doc.layers[1]) == 1);
    assert(doc.indexOf(doc.layers[2]) == 2);
    auto stray = new Layer;
    assert(doc.indexOf(stray) == doc.layers.length, "absent layer ⇒ layers.length sentinel");
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 6: `selectedItemsInto` is the SOLE answer to "which items
// does an item-mode gesture act on". Four properties, each of which a
// plausible alternative implementation gets wrong:
//   * membership is `selected`, and NOTHING else — a non-mesh item that can
//     never be primary is in the set (that is the whole point of Phase 6),
//     and a HIDDEN selected item stays in it (see the accessor's own note on
//     why `foreground()` is the wrong predicate here);
//   * order is `layers` order, deterministically — the undo payload's
//     first-touch union is built on it;
//   * the buffer is reused, so a SHRINK must not leave a stale tail visible
//     through `length` (an implementation that only ever grows the buffer
//     reads three entries where two are selected);
//   * a single-selection document yields exactly the primary.
// ---------------------------------------------------------------------------

unittest {  // selectedItemsInto — membership, order, and buffer reuse.
    import std.conv : to;
    auto doc = mixedDoc();                       // [MeshA(primary), Empty, MeshB]
    Layer[] buf;

    // Bootstrap: exactly the primary is selected.
    doc.selectedItemsInto(buf);
    assert(buf.length == 1 && buf[0] is doc.layers[0],
        "a single-selection document yields exactly the primary — got length "
        ~ buf.length.to!string);

    // A non-mesh item joins the set even though it can never be primary —
    // Phase 6 is the first thing that can transform one.
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[2], SelMode.Add);
    doc.selectedItemsInto(buf);
    assert(buf.length == 3,
        "every selected item is in the moving set — got length "
        ~ buf.length.to!string);
    assert(buf[0] is doc.layers[0] && buf[1] is doc.layers[1] && buf[2] is doc.layers[2],
        "the moving set is emitted in `layers` order, deterministically");
    assert(buf[1].kind == ItemKind.Empty && !doc.isPrimary(buf[1]),
        "a non-primary, non-mesh item is a legitimate transform target");

    // Hidden but selected stays in — the deliberate divergence from
    // `foreground()`, pinned so a later `visible &&` cannot slip in unnoticed.
    doc.layers[2].visible = false;
    doc.selectedItemsInto(buf);
    assert(buf.length == 3 && buf[2] is doc.layers[2],
        "a HIDDEN but selected item stays in the moving set (`selected`, not "
        ~ "`visible && selected`) — got length " ~ buf.length.to!string);
    doc.layers[2].visible = true;

    // SHRINK through the same buffer: no stale tail may remain readable.
    doc.selectItem(doc.layers[1], SelMode.Remove);
    doc.selectItem(doc.layers[2], SelMode.Remove);
    doc.selectedItemsInto(buf);
    assert(buf.length == 1 && buf[0] is doc.layers[0],
        "the reused buffer must SHRINK to the new count — a stale tail would "
        ~ "make a de-selected item keep receiving the gesture. got length "
        ~ buf.length.to!string);
}


// ---------------------------------------------------------------------------
// Task 0612 Stage 8 — `itemTransformTarget` / `itemTransformTargets`, the walk
// of every reachable focus-vs-primary state (plan §7.2's table, driven through
// the REAL mutators rather than by writing the two pointers by hand — the
// whole claim is that the mutators keep them in lockstep on an all-mesh
// document, and a hand-written state could not have refuted it).
//
// WRONG IMPLEMENTATIONS THIS DISCRIMINATES AGAINST
//   * the pre-Stage-8 code — no narrowing at all. Reads 2 in the "plane
//     selected alone" row where the correct answer is 1, and names the MESH
//     as the target where the correct answer is the plane.
//   * "narrow to exactly the focus" (the tempting one-liner). Reads 1 in the
//     multi-mesh row, where two meshes must both move — that is the row that
//     kills it, and it is why the table has a ctrl-add-mesh step.
//   * "drop the primary whenever anything else is selected". Reads 1 in the
//     multi-mesh row too, for a different reason: there focus IS primary.
//
// The mesh-only rows are the CONTROL. They are the entire neutrality proof
// for changing what four call sites bind, so they are asserted first and
// their answers are the pre-Stage-8 answers, unchanged.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    Document doc;
    auto meshA = new Layer;  meshA.name = "A";
    auto meshB = new Layer;  meshB.name = "B";
    auto plane = new Layer;  plane.name = "P"; plane.kind = ItemKind.ImagePlane;
    auto plane2 = new Layer; plane2.name = "P2"; plane2.kind = ItemKind.ImagePlane;
    doc.layers = [meshA, meshB, plane, plane2];
    doc.selectItem(meshA, SelMode.Set);

    Layer[] buf;
    string names() {
        string s;
        foreach (i, l; buf) { if (i) s ~= ","; s ~= l.name; }
        return "{" ~ s ~ "}";
    }

    // --- CONTROL: an all-mesh document is bit-for-bit what it always was ---
    doc.exclusiveSelect(meshA);
    assert(doc.itemTransformTarget() is meshA && doc.itemTransformTarget() is doc.primary,
        "all-mesh control: the target IS the primary, so every measured L2 "
        ~ "centre is preserved");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is meshA, "select mesh A ⇒ {A}, got " ~ names());

    doc.selectItem(meshB, SelMode.Add);          // ctrl-add a second MESH
    // TASK 0671 — the two pointers no longer move in lockstep here: `Add`
    // appends to the selection queue and the target is the queue's HEAD, so
    // the focus lands on B while A keeps the target. This line used to read
    // `doc.primary is meshB`, and it is exactly that lockstep going away that
    // made approximation D's `target !is primary` condition wrong — see
    // `itemTransformTargets`. The row below is what would have caught it.
    assert(doc.primary is meshA && doc.focusedItem is meshB,
        "Add moves the FOCUS to the newest and leaves the target on the head");
    doc.itemTransformTargets(buf);
    assert(buf.length == 2 && buf[0] is meshA && buf[1] is meshB,
        "MULTI-MESH DRAG IS UNTOUCHED: {A,B}. A 'narrow to the focus' "
        ~ "implementation reads {B} here, and so does a D whose condition is "
        ~ "still `target !is primary`. got " ~ names());
    assert(doc.isTransformTarget(meshA) && doc.isTransformTarget(meshB),
        "…and the per-layer bool agrees with the set, on both rows");

    // --- TASK 0668: the plane SELECTED ALONE, and it really is alone ------
    // This row used to open by asserting that a mesh was STILL primary and
    // STILL selected ("the document invariant FORCES the mesh to stay
    // selected — if it did not, there would be nothing for D to subtract").
    // 0668 removed the forcing from the exclusive path, so the correct answer
    // {P} now comes out of the SELECTION rather than out of approximation D.
    // The row is kept, and inverted, because it is the one a user reaches by
    // clicking a plane.
    doc.selectItem(plane, SelMode.Set);
    assert(doc.primary is meshA,
        "0671: an exclusive select of a plane leaves the mesh edit target "
        ~ "LATCHED — 0668's `is null` was the cost this task removes");
    assert(!meshA.selected && !meshB.selected,
        "…and neither mesh is spared into the selection: 0668's half is kept");
    assert(doc.itemTransformTarget() is plane,
        "the target follows the FOCUS onto the plane — the pre-Stage-8 "
        ~ "binding reads the mesh here, which is the gizmo sitting on the "
        ~ "character while the panel shows the plane's numbers");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is plane,
        "select the plane ⇒ {P} ONLY. got " ~ names());
    assert(!doc.isTransformTarget(meshA) && doc.isTransformTarget(plane),
        "…and the derived per-layer bool `/api/layers` reports agrees with "
        ~ "the set it is derived from");

    // --- ctrl-add a mesh back: recovery, and it is ONE click --------------
    doc.selectItem(meshA, SelMode.Add);
    assert(doc.focusedItem is meshA && doc.primary is meshA,
        "Add on a mesh re-homes BOTH pointers onto it");
    doc.itemTransformTargets(buf);
    assert(buf.length == 2,
        "ctrl-adding the mesh brings it back into the set. got " ~ names());

    // --- APPROXIMATION D, which 0668 did NOT retire ----------------------
    // D subtracts the primary from the moving set when it is not the
    // transform target. 0668 removed the state that made D unavoidable (a
    // plane selected by itself), but not the state D exists for: select a
    // MESH, then ctrl-ADD a plane. The mesh is genuinely selected — the user
    // asked for it — the focus is on the plane, and D is what stops the drag
    // taking the model along with the reference image. `itemTransformTargets`
    // documents this as the ONE declared divergence; `tests/
    // test_item_transform_focus.d` T-X6 pins it end to end.
    doc.selectItem(meshA, SelMode.Set);
    doc.selectItem(plane, SelMode.Add);
    assert(doc.primary is meshA && meshA.selected && plane.selected,
        "vacuity guard: the mesh is selected BY THE USER here (Add, not the "
        ~ "old forcing), or there would be nothing for D to subtract");
    assert(doc.focusedItem is plane, "…and the focus is on the plane");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is plane,
        "D: the selected-but-not-targeted primary is subtracted ⇒ {P}. The "
        ~ "ungated set reads {A,P} and drags the model with the reference "
        ~ "image. got " ~ names());

    // --- two planes over that same mesh selection ------------------------
    doc.selectItem(plane2, SelMode.Add);
    doc.itemTransformTargets(buf);
    assert(buf.length == 2 && buf[0] is plane && buf[1] is plane2,
        "P1 + P2 move together and the subtracted mesh does not — got "
        ~ names());

    // --- ctrl-REMOVE the planes: the Remove arm re-homes focus ------------
    doc.selectItem(plane2, SelMode.Remove);
    doc.selectItem(plane,  SelMode.Remove);
    assert(doc.primary is meshA && doc.focusedItem is doc.primary,
        "Remove re-homes the focus to the primary, so the narrowing lifts "
        ~ "by itself — no stored bit to go stale");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is doc.primary,
        "…and the set recovers to the mesh alone. got " ~ names());
}


// ---------------------------------------------------------------------------
// Task 0615 S3 (review round 3): `meshLayers()` is the plan's primary
// mitigation for the tier the compiler cannot check — its whole claim is
// "iterating it can never yield a non-mesh layer". Exercise BOTH overload
// instantiations (mutable `This=Document`, const `This=const(Document)`)
// against the mixed fixture, so the claim is actually proved rather than
// merely asserted in a comment.
// ---------------------------------------------------------------------------

unittest {  // meshLayers() — mutable receiver.
    auto doc = mixedDoc();                       // [MeshA(primary), Empty, MeshB]
    size_t seen = 0;
    foreach (l; doc.meshLayers()) {
        assert(l.hasMesh, "meshLayers() (mutable) must never yield a non-mesh layer");
        ++seen;
    }
    assert(seen == 2, "meshLayers() (mutable) yields exactly the mesh-kind layers");
}

unittest {  // meshLayers() — const receiver, the shape every real caller uses
            // (io/scene_ir.d, io/scene_export.d, io/lwo_export.d all take
            // `const ref Document`).
    const doc = mixedDoc();
    size_t seen = 0;
    foreach (l; doc.meshLayers()) {
        assert(l.hasMesh, "meshLayers() (const) must never yield a non-mesh layer");
        ++seen;
    }
    assert(seen == 2, "meshLayers() (const) yields exactly the mesh-kind layers");
}

unittest {  // S5: selectItem/setPrimary must guard MEMBERSHIP, not just
            // null — a stray `Layer` that is not (or no longer) in `layers`
            // must be a total no-op, never installed as target/focus/primary
            // (L1: `primary`/`focusedItem` always name a layer IN `layers`).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];
    auto stray = new Layer;                    // never added to doc.layers

    doc.selectItem(stray, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "selectItem(Set) ignores a stray layer");
    assert(!stray.selected, "selectItem never touches a stray layer's state");

    doc.selectItem(stray, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "selectItem(Add) on a stray layer is also a no-op");

    doc.setPrimary(stray);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "setPrimary ignores a stray layer");
}

// ---------------------------------------------------------------------------
// Task 0615, review round 2: SF1 (guard MEMBERSHIP, not just null — a STALE
// `primary`/`focusedItem` is non-null but no longer a member of `layers`)
// and SF2 (the `Add` and `setPrimary` arms must not leave `primary`
// null/stale either). The S5 tests above prove the null/absent-STRAY case;
// these prove the STALE case the earlier fix's null check cannot see.
// ---------------------------------------------------------------------------

/// SF1 fixture: a `Document` whose `primary` AND `focusedItem` are STALE —
/// non-null, but no longer members of `layers` — the exact shape a LIVE
/// `Document` reaches when a caller replaces `layers` via direct field
/// assignment before repointing `primary`. This is not a contrived state:
/// it is literally what `io/native.d`'s `.v3d` loader does today
/// (`document.layers = parsed;` at `:450`, before any mutator runs) to the
/// app's live `Document`, reused by `ref` from `commands/file/load.d:122`.
/// Returns the document plus the two GENUINE (post-swap) members: `empty`
/// (not `canBePrimary`) and `meshB` (the only `canBePrimary` survivor, so
/// the one `rehomePrimary` must land on).
private Document staleDoc(out Layer empty, out Layer meshB) {
    auto doc = mixedDoc();                  // [meshA(primary+focus), Empty, MeshB]
    empty = new Layer; empty.name = "FreshEmpty"; empty.kind = ItemKind.Empty;
    meshB = new Layer; meshB.name = "FreshMeshB";
    doc.layers = [empty, meshB];            // `primary`/`focusedItem` still name
                                             // the OLD meshA — now STALE.
    return doc;
}

unittest {  // SF1: exclusiveSelect (reached via BOTH `selectItem(Set)` and
            // `setActive`, mirroring the L2 test above) must not install a
            // STALE primary. The original hazard: the null check never fires
            // on a stale reference (it is non-null), so `primaryAfter` stayed
            // the stale layer and was written straight into `primary` — a
            // silent L1 violation.
            //
            // TASK 0668 CLOSED IT AT THE SOURCE rather than by repairing it.
            // The `: primary` branch that could carry a stale pointer into
            // `primaryAfter` is gone: `primary-after` is now either `target`
            // (checked a member) or null. So the assertion changes from "the
            // stale primary was REHOMED" to "no primary was installed at all",
            // and the L1 property under test — `primary` is never a
            // non-member — is stronger, not weaker.
    static void check(Document doc, Layer empty, Layer meshB) {
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "SF1/0668: a target that cannot be primary installs NO primary, so "
            ~ "the stale one cannot survive into it");
        assert(!meshB.selected,
            "…and the exclusive select did not drag a mesh in behind it");
        assert(doc.focusedItem is empty, "the target still becomes focus");
    }

    Layer empty1, meshB1;
    auto d1 = staleDoc(empty1, meshB1);
    d1.selectItem(empty1, SelMode.Set);     // exclusiveSelect via selectItem(Set)
    check(d1, empty1, meshB1);

    Layer empty2, meshB2;
    auto d2 = staleDoc(empty2, meshB2);
    d2.setActive(0);                        // exclusiveSelect via setActive (idx 0 == empty2)
    check(d2, empty2, meshB2);
}

unittest {  // TASK 0671 — A STALE EDIT TARGET IS NOT REPRESENTABLE ANY MORE.
            // ~~SF1's surviving half (0668): `recoverStalePrimary` is still
            // the repair for the two arms that never route through
            // `exclusiveSelect`.~~ There is nothing left to repair. The target
            // is derived by ENUMERATING `layers`, so an item that leaves the
            // list stops being an answer the same instant — a whole class of
            // defect (and the function that fixed it) went away with the
            // field. What replaces the two "rehomed" rows is the stronger
            // claim: after the replacement the target is decided by the NEW
            // list alone, and nothing is conjured into it.
    {   // STALE → the departed layer is simply not an answer.
        Layer empty, meshB;
        auto doc = staleDoc(empty, meshB);
        doc.selectItem(empty, SelMode.Add);
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "the old primary left `layers`, so the walk cannot reach it — and "
            ~ "no replacement is invented: meshB was never selected");
        assert(!meshB.selected,
            "above all it is not SELECTED on the way; that is the substitution "
            ~ "0654 removed everywhere else, and the pre-0671 repair did it here");
        assert(doc.focusedItem is empty, "Add still moves focus to the target");
    }
    {   // ABSENT → stays absent. RED before 0668: the mesh gets selected.
        // TASK 0671 — the rig had to change, and the change IS the finding.
        // It used to reach "no edit target" with `clearItemSelection()`, which
        // does not produce that state any more: dropping the selection LATCHES
        // every mesh that was in it. The state still exists, it is just reached
        // by having no mesh with a selection state at all — here, a document
        // nobody has selected anything in yet.
        Document doc;
        auto empty = new Layer; empty.name = "E0"; empty.kind = ItemKind.Empty;
        auto meshA = new Layer; meshA.name  = "M0";
        doc.layers = [empty, meshA];
        assert(doc.primary is null, "precondition: no target to begin with");
        doc.selectItem(empty, SelMode.Add);
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "0668: an Add on a non-mesh item from a document with no "
            ~ "targetable item must not conjure an edit target");
        size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
        assert(sel == 1,
            "and exactly one item is selected — the one that was added. The "
            ~ "pre-0668 repair read 2 here, having selected a mesh nobody "
            ~ "clicked");
    }
}

unittest {  // SF1, RED-before-fix: the focus assignment inside
            // `selectItem(Remove)`'s non-primary branch (`:368`-shape) must
            // guard membership too. Pre-fix it unconditionally copies
            // `primary` into `focusedItem`; with a STALE primary that
            // installs a non-member focus — the same L1 violation, just on
            // the other pointer. This arm does NOT repair `primary` itself
            // (only `Set`/`Add`/`setPrimary` do — see the next test), so
            // only `focusedItem` is checked here; `assertDocInvariants`
            // would still fail on the (deliberately still-stale) `primary`.
            //
            // `focusedItem` is set by a raw field write here, not a mutator:
            // every mutator that touches `focusedItem` (`Set`/`Add`/
            // `setPrimary`) ALSO now self-heals a stale `primary` (SF1/SF2),
            // so routing through one would repair the very staleness this
            // test needs to hold constant. This mirrors how `staleDoc`
            // itself is built — production reaches this shape via a raw
            // `document.layers = …` write too (`io/native.d:450`).
    Layer empty, meshB;
    auto doc = staleDoc(empty, meshB);
    empty.selected = true;
    meshB.selected = true;
    doc.focusedItem = empty;

    doc.selectItem(empty, SelMode.Remove);
    assert(!empty.selected, "empty deselected");
    assert(doc.focusedItem is meshB,
        "SF1: the focus fallback must not install the STALE primary — it must fall back to rehomePrimary");
    assert(doc.isMember(doc.focusedItem), "the recovered focusedItem is a genuine member of layers");
}

unittest {  // SF2 as amended by TASK 0668. The original read: `selectItem(Add)`
            // on a non-mesh layer must not leave `primary` null, because a
            // `Document` assembled by direct field writes starts with
            // `primary is null` and `Add`'s `if (canBePrimary) primary = l;`
            // has no `else`. 0654 then made a null primary a LEGAL state, and
            // after that the repair could no longer tell "mid-assembly" from
            // "the user emptied the selection" — it only ever saw `null`. It
            // chose wrongly for the second, and the second is the common one:
            // measured before this change, ctrl-adding a plane to an empty
            // selection came back with a MESH selected and primary.
            //
            // So a null primary now stays null. The stale case — the one the
            // repair can actually identify — is unchanged and is covered by
            // the `staleDoc` tests above.
    Document doc;
    auto empty = new Layer; empty.name = "E"; empty.kind = ItemKind.Empty;
    auto meshA = new Layer; meshA.name = "M";
    doc.layers = [empty, meshA];            // primary/focusedItem still null

    doc.selectItem(empty, SelMode.Add);
    assert(doc.primary is null,
        "SF2/0668: Add on a non-mesh target leaves an ABSENT primary absent — "
        ~ "it must not conjure an edit target the caller never asked for");
    assert(!meshA.selected,
        "…and above all must not SELECT one: that is the substitution 0654 "
        ~ "removed everywhere else");
    assert(doc.focusedItem is empty, "Add still moves focus to the non-mesh target");
    assertDocInvariants(doc);
}

unittest {  // SF2, RED-before-fix: setPrimary on a non-mesh layer must not
            // leave `primary` null either — same defect class as Add, the
            // sibling arm the earlier fix skipped.
    Document doc;
    auto empty = new Layer; empty.name = "E2"; empty.kind = ItemKind.Empty;
    auto meshA = new Layer; meshA.name = "M2";
    doc.layers = [empty, meshA];            // primary/focusedItem still null

    doc.setPrimary(empty);
    assert(doc.primary is null,
        "SF2/0668: same amendment as the Add arm — an ABSENT primary stays "
        ~ "absent; see that test for why the repair can no longer tell "
        ~ "mid-assembly from an emptied selection");
    assert(!meshA.selected, "…and no mesh is selected on the way");
    assert(doc.focusedItem is empty, "setPrimary still moves focus to the target");
    assertDocInvariants(doc);
}

unittest {  // TASK 0671 — the `setPrimary` half of the same retirement.
            // ~~SF2's surviving half (0668): a STALE primary is still
            // repaired by `recoverStalePrimary`.~~
    Layer empty, meshB;
    auto doc = staleDoc(empty, meshB);
    doc.setPrimary(empty);
    assert(doc.primary is null,
        "setPrimary on a non-targetable item seats it and focuses it; the walk "
        ~ "then filters it out and finds nothing else with a selection state");
    assert(!meshB.selected, "…and no mesh is selected on the way");
    assert(doc.focusedItem is empty, "and the focus is still the target");
    assertDocInvariants(doc);
    // …and the recovery is one ordinary select, exactly as everywhere else.
    doc.setPrimary(meshB);
    assert(doc.primary is meshB && doc.isMember(doc.primary) && meshB.selected,
        "CONTROL: seating a targetable item really does install a target, so "
        ~ "the null above is a real absence and not a broken walk");
    assertDocInvariants(doc);
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




// ---------------------------------------------------------------------------
// Task 0617: ItemXform.modelSpace() — the picking-facing ModelSpace factory.
// ---------------------------------------------------------------------------








// ---------------------------------------------------------------------------
// Task 0617: the primary-layer ModelSpace resolver.
//
// Picking code that needs the CURRENT primary layer's transform but has no
// `Document` instance of its own — `http_providers.d`'s HTTP-thread-bridged
// providers, `tools/edit/topology_pen/tool.d`'s `TopologyPenTool` (its
// `pickPrimaryFace` picks against the primary mesh via its own `BvhPick`) —
// resolves it through this global, mirroring `display_sync.activeMeshResolver`
// (the identical cross-module problem, already solved once in this codebase).
// `app.d`'s main() installs the resolver once, right after the `Document` is
// constructed; every call site — inside app.d's own nested closures too, so
// there is exactly ONE formula, not a duplicated one — resolves the transform
// through `primaryModelSpace()` rather than reaching into a `Document`.
// ---------------------------------------------------------------------------

__gshared ModelSpace delegate() primaryModelSpaceResolver;

/// The current primary layer's `ModelSpace`. Identity when the resolver has
/// not been installed (tools/tests built without a running app) — the same
/// null-safety convention `display_sync.activeMeshResolver` uses.
///
/// Folds ONLY `primary.xform` (the per-layer item transform). The draw path
/// (`ui/panels.d`'s "Per-item (per-layer) transform" feed-site) folds a
/// SECOND matrix on top of that during an active `TransformTool` drag
/// (`meshModel = matMul4(itemMatrix, tt.gpuMatrix)`) — the gizmo's live
/// preview of an in-progress T/R/S edit, not yet committed to `xform`. This
/// resolver does not know about `tt.gpuMatrix` and is not reachable from it,
/// so a pick made while that second matrix is non-identity would be picking
/// against a pose the draw path isn't actually drawing. This is currently
/// unreachable in practice — picking is not exercised while a transform
/// gizmo drag is in flight — but that is an invariant of the CALLERS, not of
/// this function; if a future change starts picking mid-drag, this is where
/// the mismatch would resurface.
ModelSpace primaryModelSpace() {
    return primaryModelSpaceResolver !is null
        ? primaryModelSpaceResolver()
        : ModelSpace.world();
}
