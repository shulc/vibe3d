module item_kinds;

// ---------------------------------------------------------------------------
// THE ITEM KIND TABLE (task 0721, audit №4 item D10 — the `items` stratum).
//
// What kinds of item a document can hold, and the per-kind CAPABILITY row that
// every consumer is supposed to ask instead of comparing against a kind. Split
// out of `document.d` whole: it imports nothing but `std.traits` (inside the
// one function that needs it) and is read by ~everything, which is exactly the
// shape that should not be sitting in the middle of a 4 000-line module.
//
// THE SIX `static assert`s CAME WITH IT, and they are the point of moving the
// table rather than only the enum: they are compile-time proofs about the
// table's ROWS (`drawsGeometry` requires `hasMesh`, `hasImagePlane` forbids
// `hasMesh`, and so on), so they have to live where the rows do or a new row
// added here would be proved nothing about.
//
// `document.d` re-exports every public name with a `public import`; the table
// itself stays module-private, as it was.
// ---------------------------------------------------------------------------

/// The kind of document item a `Layer` represents. `Mesh` is the only kind
/// the pre-0615 editor path assumed; `Empty` is the first non-geometry kind
/// (task 0615) — a transform-only item with no mesh payload. `Image` (task
/// 0616) is the first RESOURCE kind — it is neither geometry nor a thing
/// positioned in space; consumers reference it, it does not sit in the
/// scene. `ImagePlane` (task 0612) is the first kind that is DRAWN without
/// owning geometry — a world-placed reference image, positioned by the
/// ordinary item transform and reading its pixels through a link to an
/// `Image` item rather than owning them. New kinds append here; the enum
/// VALUE is never persisted (`.v3d` / HTTP carry the wire TOKEN from
/// `ItemKindInfo.token`, resolved through `kindFromToken`), so appending
/// never reshuffles a stored file.
enum ItemKind : ubyte { Mesh = 0, Empty = 1, Image = 2, ImagePlane = 3 }

/// The per-kind capability row. Every field is a CAPABILITY, never spelled
/// `kind == ItemKind.Mesh` at a call site — that is what makes a future
/// geometry-bearing kind a one-row table edit instead of a codebase sweep
/// (mirrors the reference editor reaching geometry by a named, failable
/// query rather than by type identity).
struct ItemKindInfo {
    string token;         ///< .v3d + HTTP wire token, e.g. "mesh" / "empty"
    bool   hasMesh;       ///< owns a geometry payload
    bool   hasXform;      ///< participates in the item transform
    bool   canBePrimary;  ///< may become the mesh edit target (`Document.primary`)
    bool   drawsGeometry; ///< participates in the bg/foreground geometry draw
    // Task 0616 Stage 2 — the second non-mesh kind's two genuine new axes.
    // Both pass the plan's honesty test for a capability bit: does the NEXT
    // kind land on a side for the bit's OWN stated reason, not merely "how
    // many kinds agree today".
    bool   hasImage;      ///< owns a decoded-pixel payload (`Layer.image_`).
                           ///< The reference-image item ([[0612]]) LINKS to an
                           ///< image rather than owning one, so it is false
                           ///< there for the same reason it is true here.
    bool   isSceneItem;   ///< appears in the scene/layer list, not just the
                           ///< item list. A document RESOURCE (an image, and
                           ///< the reference's sibling sequence/folder/group
                           ///< kinds) has no transform and nothing to see in
                           ///< the viewport, so it lives only in its own
                           ///< panel — false here for that reason, not as a
                           ///< kind check wearing a hat (Bend #2).
    // Task 0612 Stage 2 — the reference-image plane's axis.
    bool   hasImagePlane; ///< owns an image-plane payload (`Layer.imagePlane_`)
                           ///< and draws one textured world quad on ITS OWN
                           ///< display axis. Deliberately NOT folded into
                           ///< `drawsGeometry`: that bit gates the background/
                           ///< foreground MESH pass, whose body dereferences
                           ///< `meshRef()` unconditionally. `display_state.d`
                           ///< already states the house rule this follows —
                           ///< the grid, the workplane and the reference image
                           ///< are each their OWN axis — so "is drawn" is
                           ///< never one bit, and a drawable that owns no mesh
                           ///< needs no relaxation of the proof below.
}

/// One row per `ItemKind`, indexed by the enum's numeric value — kept in
/// enum declaration order so `kItemKindTable[k]` is a plain array index.
private immutable ItemKindInfo[ItemKind.max + 1] kItemKindTable = [
    //             token         hasMesh hasXform canBePrimary drawsGeometry hasImage isSceneItem hasImagePlane
    ItemKindInfo("mesh",       true,  true,  true,  true,  false, true,  false), // ItemKind.Mesh
    ItemKindInfo("empty",      false, true,  false, false, false, true,  false), // ItemKind.Empty
    ItemKindInfo("image",      false, false, false, false, true,  false, false), // ItemKind.Image
    // Task 0612. Every column is load-bearing and none of them is "how many
    // kinds agree today":
    //   * `hasMesh` FALSE — and the `!hasImagePlane || !hasMesh` proof below
    //     turns that into a compile-time fact, which is what makes every
    //     mesh-shaped consumer skip this kind by construction rather than by
    //     a guard somebody has to remember.
    //   * `hasXform` TRUE — the whole premise is that it is placed with the
    //     ordinary Move / Rotate / Scale tools in Item mode.
    //   * `canBePrimary` FALSE — `primary` is the MESH edit target.
    //   * `drawsGeometry` FALSE — see `hasImagePlane`'s comment above, and
    //     the note under the `drawsGeometry implies hasMesh` proof below.
    //   * `hasImage` FALSE — it LINKS to an image item, it does not own one,
    //     so it is not an Images-panel row.
    //   * `isSceneItem` TRUE — mandatory, not stylistic: the Layers panel
    //     filters on it and the Images panel on `hasImage`, and the two are
    //     documented as exact complements. False on both would put this item
    //     in NO panel at all, and with no viewport item picking it would be
    //     unselectable and undeletable.
    ItemKindInfo("imagePlane", false, true,  false, false, false, true,  true),  // ItemKind.ImagePlane
];

// `drawsGeometry` implies `hasMesh`, as a compile-time PROOF over the table
// rather than a convention every row author has to remember. It holds for
// every kind declared above only because nothing has violated it yet — the
// consumer side leans on that: `ui/panels.d`'s per-frame draw loop gates on
// `drawsGeometry` and then dereferences `lyr.meshRef()` unconditionally,
// while its snap loop ~20 lines below gates on `hasMesh` instead. If a
// future row ever set `drawsGeometry` true without `hasMesh`, the draw
// loop's `meshRef()` call would be reachable on a non-mesh layer (hitting
// its `debug`-only assert, or worse in a release build) despite passing its
// own gate. This `static foreach` makes that impossible to compile instead
// of merely being true today.
//
// Task 0612: the prediction the block further down used to make — that the
// reference-image item would force this proof to be RELAXED — is SUPERSEDED,
// and the two comments now agree (see the note at the end of that block).
// The image-plane row keeps `drawsGeometry` FALSE and draws on its own
// display axis instead, so "drawn" never travels through the mesh pass and
// this line stands unweakened. It is precisely the consequence this comment
// states — an empty-mesh upload behind a passing gate — that made relaxing
// it the wrong move.
static foreach (row; kItemKindTable)
    static assert(!row.drawsGeometry || row.hasMesh,
        "ItemKindInfo(\"" ~ row.token ~ "\"): drawsGeometry requires hasMesh");

// Task 0616 Stage 2, Bend #2: the companion proof for `isSceneItem` — a kind
// that draws in the viewport must also be listed in the scene list, else the
// user can see something they have no row to select it from. Same shape as
// the `hasMesh` proof above; kept as a SEPARATE `static foreach` (rather than
// folded into one assert) so a future row that violates only one of the two
// gets a message naming the one it actually broke.
//
// Deliberate break, performed and reverted while writing this stage (T2):
// temporarily setting `isSceneItem` false on the `mesh` row (which is
// `drawsGeometry == true`) makes this line fail to compile with exactly this
// message; restoring the row makes the build green again.
static foreach (row; kItemKindTable)
    static assert(!row.drawsGeometry || row.isSceneItem,
        "ItemKindInfo(\"" ~ row.token ~ "\"): drawsGeometry requires isSceneItem");

// Task 0616 Stage 2 — the forcing function above this comment (`hasXform`
// unconditionally required true) has now done its job and is RETIRED.
//
// It read, until this stage:
//
//     static foreach (row; kItemKindTable)
//         static assert(row.hasXform, "... hasXform == false has no "
//             ~ "consumer yet — gate source/layer_params.d's LayerPropsProvider "
//             ~ "(transform-component params) on this capability before "
//             ~ "adding a kind like this, then relax this assertion");
//
// Adding the `image` row above (`hasXform: false`, on the evidence that the
// measured reference item has no transform channels at all —
// doc/tasks/0612-evidence) tripped it immediately, at the row being edited,
// exactly as designed: a year of drift since task 0615 did not erase the
// cost, and the failure named its own fix. That fix is now applied:
// `source/layer_params.d`'s `LayerPropsProvider.params()` gates the 12
// transform-component params on `kindInfo(layer_.kind).hasXform` (an
// image-kind layer's provider now exposes only `name`/`visible`), and
// `ui/panels.d`'s item-snap-frame loop (which calls `editor_app.d`'s
// `buildItemFrame`) skips a layer with no transform to snap by, so a
// pivot nothing ever authors is never offered as a snap target either.
//
// Review round 4 (SHOULD-FIX 1): the paragraph that used to sit here claimed
// there was no cross-field invariant left to check from the table. Grepping
// the consumers contradicts that — three call sites already dereference
// `.xform` unconditionally, each sitting under a SIBLING capability gate
// that this diff either relies on or (one of them) itself introduced. Two
// narrower assertions replace the retired blanket one:
//   * `hasMesh` implies `hasXform` — `ui/panels.d`'s background-snap-source
//     loop gates on `hasMesh` and then reads `lyr.xform.modelSpace()`
//     unconditionally. Chained through the `drawsGeometry implies hasMesh`
//     proof above, this ALSO covers the draw loop's `lyr.xform
//     .composedMatrix()` read a few lines above that gate — so both of that
//     loop's `xform` reads stay proven, transitively, by one new line.
//   * `canBePrimary` implies `hasXform` — `app.d`'s
//     `primaryModelSpaceResolver`, `toolpipe/stages/actcenter.d`'s
//     `Mode.Pivot`/`Mode.Parent` centers, and `toolpipe/stages/axis.d`'s
//     `Mode.Pivot` basis all resolve `document.primary.xform
//     .composedMatrix()` (or a parent's) with NO capability check at the
//     call site — they lean entirely on the Document invariant that
//     `primary` is always `canBePrimary` (§Q2, `assert(kindInfo(d.primary
//     .kind).canBePrimary, ...)` below). Without this row-level guarantee, a
//     future `canBePrimary` kind with `hasXform == false` would make
//     primary-selection an unchecked path to a meaningless identity
//     transform at three call sites that have no gate of their own to add.
//
// This diff itself created the second half of the `hasMesh`/`hasXform`
// coupling: `ui/panels.d`'s item-snap-frame loop (Bend #1) now DENIES a snap
// frame to a layer with no transform, while the draw loop two guards above
// it would still draw one that `drawsGeometry` — chaining `drawsGeometry`
// implies `hasMesh` implies `hasXform` is what keeps those two loops
// agreeing on which layers have a real pivot instead of drifting apart the
// next time either gate changes alone.
//
// ~~Forward-looking reason this still matters: the reference-image item draws
// in the viewport while owning no mesh, so `drawsGeometry implies hasMesh`
// is the assertion that will have to be RELAXED next. At that point
// `hasXform` becomes the ONLY thing still coupling "drawn" to "positionable"
// — retiring it now, before that relaxation, would have removed the guard
// just before it became load-bearing.~~
//
// SUPERSEDED (task 0612 Stage 2), not wrong. The reference-image item has
// landed — `ItemKind.ImagePlane` above — and it did NOT relax
// `drawsGeometry implies hasMesh`. It got its own capability bit
// (`hasImagePlane`) and its own draw pass instead, following the rule
// `display_state.d` states for the display axes: the grid, the workplane and
// the reference image are each their OWN axis, so "is drawn" was never one
// bit to begin with. The paragraph above was written before that rule became
// the house shape, and under it "drawn" never has to travel through the mesh
// pass at all. A comment predicting a future task's shape is a hypothesis,
// not a spec — this one is kept struck through rather than deleted so the
// prediction and its outcome stay visible together, and the proof it
// predicted would be relaxed carries a matching note at its own site above.
//
// What DOES survive from it, and is now the operative reason these two lines
// exist: `hasXform` is what couples "positionable" to the payload-bearing
// kinds, and the three `hasImagePlane` proofs below extend exactly that
// coupling to the new drawable.
static foreach (row; kItemKindTable)
    static assert(!row.hasMesh || row.hasXform,
        "ItemKindInfo(\"" ~ row.token ~ "\"): hasMesh requires hasXform");
static foreach (row; kItemKindTable)
    static assert(!row.canBePrimary || row.hasXform,
        "ItemKindInfo(\"" ~ row.token ~ "\"): canBePrimary requires hasXform");

// Task 0612 Stage 2 — the image plane's three proofs, in the same style as
// the four above and beside them for the same reason.
//
//   * drawn implies positionable — a plane the item transform cannot reach
//     would be stuck at the origin with no way to move it, and `resolve
//     Placement` reads `xform` unconditionally.
//   * drawn implies reachable in a panel — same argument as `drawsGeometry
//     implies isSceneItem` one proof up, and it bites harder here: viewport
//     item picking does not exist, so the panel row is the ONLY way to
//     select or delete one.
//   * the third is the whole non-participation audit in one line. An image
//     plane owns no mesh AT COMPILE TIME, so every mesh-shaped consumer
//     (picking, snapping, subdivision, export, bounds) skips it by
//     construction rather than by a guard that has to be remembered and can
//     be forgotten one call site at a time.
//
// Deliberate break, performed and reverted while writing this stage: setting
// `hasMesh` true on the `imagePlane` row fails to compile at the third line
// with exactly its message (and, chained through `hasMesh implies hasXform`,
// nothing else) — restoring the row makes the build green again.
static foreach (row; kItemKindTable)
    static assert(!row.hasImagePlane || row.hasXform,
        "ItemKindInfo(\"" ~ row.token ~ "\"): hasImagePlane requires hasXform");
static foreach (row; kItemKindTable)
    static assert(!row.hasImagePlane || row.isSceneItem,
        "ItemKindInfo(\"" ~ row.token ~ "\"): hasImagePlane requires isSceneItem");
static foreach (row; kItemKindTable)
    static assert(!row.hasImagePlane || !row.hasMesh,
        "ItemKindInfo(\"" ~ row.token ~ "\"): hasImagePlane forbids hasMesh");

/// The capability row for `k`.
ref immutable(ItemKindInfo) kindInfo(ItemKind k) pure nothrow @nogc @safe {
    return kItemKindTable[k];
}

/// Resolve a wire token (`.v3d` `"type"`, HTTP `kind:` param) to an
/// `ItemKind`. Validated, reject-on-unknown: the numeric-parameter
/// chokepoint for every file/HTTP-supplied kind token — never
/// `cast(ItemKind) someInt`, never an array index by a caller-supplied
/// number. Returns `false` (and leaves `kind` unchanged) on no match.
///
/// `kind` is `ref`, not `out`: D zero-initialises an `out` parameter on
/// function entry, so under `out` a rejected token would have silently
/// forced `kind` to `ItemKind.init` — `ItemKind.Mesh`, the first declared
/// enum member and the single worst value for an unknown document-type
/// token to become. `ref` makes "leaves `kind` unchanged" literally true;
/// callers must still check the return value before reading `kind`.
bool kindFromToken(string token, ref ItemKind kind) pure nothrow @nogc @safe {
    import std.traits : EnumMembers;
    foreach (k; EnumMembers!ItemKind)
        if (kindInfo(k).token == token) { kind = k; return true; }
    return false;
}

/// The wire token for `k` — the inverse of `kindFromToken`. Routed through
/// the attributed `kindInfo()` lookup (review round 2 NIT), not a raw
/// `kItemKindTable[k]` index: an unattributed direct index here would drop
/// its bounds check under a `-release` build (default `-boundscheck=
/// safeonly` keeps bounds checks only in `@safe` code), unlike the sibling
/// lookup at `kindInfo` itself.
string tokenOf(ItemKind k) pure nothrow @nogc @safe { return kindInfo(k).token; }
