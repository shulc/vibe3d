module document;

import mesh    : Mesh;
import seltype : SelMode;
import math    : Vec3, identityMatrix, translationMatrix, matrixFromEulerZYX,
                 pivotScaleMatrix, matMul4, ModelSpace;

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

/// Degenerate-scale floor for `ItemXform.scl` (task 0614, R7). A `scl`
/// component whose MAGNITUDE falls below this makes `composedMatrix()`
/// singular, which poisons every consumer that inverts or normalises it
/// (action-centre, axis basis, snap frames, export). The sign is NOT part of
/// the floor — a negative scale is a legitimate mirror, so the guard clamps
/// `|scl|` and preserves the sign.
///
/// This constant lives HERE, next to `ItemXform`, rather than in either of the
/// two places that enforce it, because R7 is a TWO-LAYER guard and the two
/// layers must agree by construction: the gesture kernel
/// (`tools/transform/item_xform_kernels.d`, which re-exports this symbol) and
/// the authored-param write path (`layer_params.d`). Two independently
/// declared floors would be a latent divergence, not a redundancy.
enum float MIN_ITEM_SCALE_MAG = 1e-4f;

/// Magnitude ceiling for `ItemXform.scl` (task 0614, R7 — the other end of the
/// same guard). A finite but absurd scale (`1e30`) does not make the matrix
/// singular, but it overflows to infinity the moment it is composed with
/// anything else, which reintroduces the non-finite state the floor exists to
/// prevent. `1e6` is far beyond any modelling use and still leaves ~30 bits of
/// float headroom for a matrix product.
enum float MAX_ITEM_SCALE_MAG = 1e6f;

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

    /// The `ModelSpace` (task 0617, doc/picking_item_transform_plan.md §3.1)
    /// packaging this transform for picking: `m` == `composedMatrix()`, plus
    /// its ANALYTIC inverse and the `isIdentity`/`invertible`/`mirrored`
    /// flags every picking entry point gates on.
    ///
    /// Exact identity fast path (§3.5, a HARD requirement): `pos`/`rot`/`scl`
    /// compared by EXACT float equality against their defaults, not
    /// `isClose` — the existing test suite is the neutrality proof for every
    /// picking stage built on this, and a float-epsilon "close enough" would
    /// turn that proof into noise. `pivot` is deliberately excluded from the
    /// check: at rot=0/scl=1, `T(pivot)·I·T(-pivot) == I` for ANY pivot, so a
    /// non-zero pivot alone never makes the composed matrix non-identity.
    ///
    /// `mInv` is analytic, not a general 4×4 inverse (`math.d` has none, and
    /// this composition order never needs one — §3.1):
    ///
    ///     M⁻¹ = T(pivot) · S⁻¹ · Rᵀ · T(-pivot) · T(-pos)
    ///
    /// `S⁻¹ = diag(1/scl)`. `Rᵀ` is the TRANSPOSE of `matrixFromEulerZYX(rot)`
    /// — NOT `matrixFromEulerZYX(-rot)`, which composes to `Rz(-)·Ry(-)·Rx(-)`,
    /// the reverse-order product and NOT the inverse of `Rz·Ry·Rx` (pinned by
    /// the unittest below; this is the trap the plan calls out by name).
    /// Since `matrixFromEulerZYX` already returns a matrix with zero
    /// translation and bottom row `(0,0,0,1)`, transposing the FULL `float[16]`
    /// gives exactly the transpose of its 3×3 rotation block (the swapped
    /// translation/bottom-row entries are all zero either way), so no
    /// separate 3×3-only transpose helper is needed.
    ///
    /// Degenerate in exactly one place (§3.1): any `scl` component `== 0`
    /// has no inverse — `invertible` is set false and `mInv` is left at
    /// identity (meaningless; callers MUST check `invertible` first, per R2).
    ///
    /// `mirrored = det(M) < 0`. For this composition order
    /// `det(M) = det(R)·det(S) = 1 · (scl.x·scl.y·scl.z)` (translations are
    /// unit-determinant, `matrixFromEulerZYX` is a proper rotation) — so the
    /// PRODUCT of the three scale components, not "any component negative"
    /// (§3.7). No general 3×3 determinant helper is added; none is needed.
    ModelSpace modelSpace() const {
        immutable bool isId =
               pos.x == 0 && pos.y == 0 && pos.z == 0
            && rot.x == 0 && rot.y == 0 && rot.z == 0
            && scl.x == 1 && scl.y == 1 && scl.z == 1;
        if (isId) return ModelSpace.world();

        immutable float det = scl.x * scl.y * scl.z; // §3.7 — no det3 helper

        ModelSpace ms;
        ms.m          = composedMatrix();
        ms.isIdentity = false;
        ms.mirrored   = det < 0;

        if (scl.x == 0 || scl.y == 0 || scl.z == 0) {
            ms.invertible = false;
            ms.mInv       = identityMatrix; // meaningless; callers check `invertible` first
            return ms;
        }

        float[16] R  = matrixFromEulerZYX(rot);
        // R^T: matrixFromEulerZYX has zero translation + bottom row (0,0,0,1),
        // so a full-matrix transpose IS the 3x3 rotation-block transpose.
        float[16] Rt = [
            R[0], R[4], R[ 8], 0,
            R[1], R[5], R[ 9], 0,
            R[2], R[6], R[10], 0,
            0,    0,    0,     1,
        ];
        float[16] Sinv       = pivotScaleMatrix(Vec3(0, 0, 0), 1.0f/scl.x, 1.0f/scl.y, 1.0f/scl.z);
        float[16] Tpiv       = translationMatrix(pivot);
        float[16] TpivNeg    = translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z));
        float[16] TposNeg    = translationMatrix(Vec3(-pos.x, -pos.y, -pos.z));

        // M^-1 = T(pivot) . S^-1 . R^T . T(-pivot) . T(-pos)
        ms.mInv = matMul4(Tpiv,
                  matMul4(Sinv,
                  matMul4(Rt,
                  matMul4(TpivNeg, TposNeg))));
        ms.invertible = true;
        return ms;
    }
}

/// Repair an `ItemXform` in place and report whether anything had to be
/// repaired. This is THE statement of the R7 value policy (task 0614): every
/// write path that can introduce a NEW `ItemXform` value ends here, so the
/// invalid state is impossible rather than merely rare.
///
/// Two hazards, two different policies:
///
///  * **Non-finite, on any of the 12 components.** A NaN anywhere makes
///    `composedMatrix()` all-NaN, which propagates into the action centre, the
///    axis basis, every snap frame and the exported file. Policy: **reject** —
///    restore the component's value from `before`, exactly like a command that
///    declines an out-of-domain argument. There is no "nearest legal value"
///    for a NaN, so any number invented here would be an edit nobody asked
///    for. If `before`'s own component is ALSO non-finite (a document written
///    before this guard existed), fall back to the channel's identity element
///    so the repair always terminates in a composable xform. A caller with no
///    meaningful prior value (a fresh file load) passes `ItemXform.init`,
///    which makes the identity fallback the whole rule.
///  * **A `scl` component outside `[MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG]`
///    in MAGNITUDE.** Below the floor the matrix is singular; above the
///    ceiling it overflows to infinity at the first product. Policy:
///    **clamp**, sign preserved — a negative scale is a legitimate mirror, and
///    unlike the NaN case the nearest legal value is well defined (`scl.x 0`
///    is an ordinary keystroke on the way to `0.5`).
///
/// Deliberately NOT a method on `ItemXform`: it is a repair applied by the
/// write paths, not a property of the value, and keeping it free makes the
/// call sites read as the enforcement points they are.
bool sanitizeItemXform(ref ItemXform x, ref const ItemXform before) {
    import std.math : isFinite, fabs;

    bool repaired = false;

    void finite(ref float v, float prior, float identity) {
        if (isFinite(v)) return;
        v = isFinite(prior) ? prior : identity;
        repaired = true;
    }
    finite(x.pos.x,   before.pos.x,   0.0f);
    finite(x.pos.y,   before.pos.y,   0.0f);
    finite(x.pos.z,   before.pos.z,   0.0f);
    finite(x.rot.x,   before.rot.x,   0.0f);
    finite(x.rot.y,   before.rot.y,   0.0f);
    finite(x.rot.z,   before.rot.z,   0.0f);
    finite(x.scl.x,   before.scl.x,   1.0f);
    finite(x.scl.y,   before.scl.y,   1.0f);
    finite(x.scl.z,   before.scl.z,   1.0f);
    finite(x.pivot.x, before.pivot.x, 0.0f);
    finite(x.pivot.y, before.pivot.y, 0.0f);
    finite(x.pivot.z, before.pivot.z, 0.0f);

    void band(ref float v) {
        immutable float m = fabs(v);
        if (m < MIN_ITEM_SCALE_MAG) {
            v = v < 0 ? -MIN_ITEM_SCALE_MAG : MIN_ITEM_SCALE_MAG;
            repaired = true;
        } else if (m > MAX_ITEM_SCALE_MAG) {
            v = v < 0 ? -MAX_ITEM_SCALE_MAG : MAX_ITEM_SCALE_MAG;
            repaired = true;
        }
    }
    band(x.scl.x);
    band(x.scl.y);
    band(x.scl.z);

    return repaired;
}

/// The kind of document item a `Layer` represents. `Mesh` is the only kind
/// the pre-0615 editor path assumed; `Empty` is the first non-geometry kind
/// (task 0615) — a transform-only item with no mesh payload. `Image` (task
/// 0616) is the first RESOURCE kind — it is neither geometry nor a thing
/// positioned in space; consumers reference it, it does not sit in the
/// scene. New kinds append here; the enum VALUE is never persisted (`.v3d` /
/// HTTP carry the wire TOKEN from `ItemKindInfo.token`, resolved through
/// `kindFromToken`), so appending never reshuffles a stored file.
enum ItemKind : ubyte { Mesh = 0, Empty = 1, Image = 2 }

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
}

/// One row per `ItemKind`, indexed by the enum's numeric value — kept in
/// enum declaration order so `kItemKindTable[k]` is a plain array index.
private immutable ItemKindInfo[ItemKind.max + 1] kItemKindTable = [
    ItemKindInfo("mesh",  true,  true,  true,  true,  false, true),   // ItemKind.Mesh
    ItemKindInfo("empty", false, true,  false, false, false, true),   // ItemKind.Empty
    ItemKindInfo("image", false, false, false, false, true,  false),  // ItemKind.Image
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
// Forward-looking reason this still matters: the reference-image item draws
// in the viewport while owning no mesh, so `drawsGeometry implies hasMesh`
// is the assertion that will have to be RELAXED next. At that point
// `hasXform` becomes the ONLY thing still coupling "drawn" to "positionable"
// — retiring it now, before that relaxation, would have removed the guard
// just before it became load-bearing.
static foreach (row; kItemKindTable)
    static assert(!row.hasMesh || row.hasXform,
        "ItemKindInfo(\"" ~ row.token ~ "\"): hasMesh requires hasXform");
static foreach (row; kItemKindTable)
    static assert(!row.canBePrimary || row.hasXform,
        "ItemKindInfo(\"" ~ row.token ~ "\"): canBePrimary requires hasXform");

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

/// An image item's payload (task 0616). A CLASS reference — unlike `Mesh`
/// (a value struct `MeshSnapshot` moves) — because the natural operation on
/// two layers sharing one image is SHARE, not copy: `LayerDuplicate` points
/// a clone's `image_` at the exact same `ImageData` object as its source
/// (`Layer.imageRef()` below), the same way twenty consumers of one loaded
/// image share one entry in the pixel cache a later stage adds on top of
/// this. `Layer.parent` is the existing precedent for a shared class
/// reference on `Layer` — and the cautionary one: `parent` has no refcount,
/// which is exactly the un-refcounted-alias shape a cache must not repeat
/// (the refcount bump on a shared clone is Stage 5's job, not this one's).
///
/// Stage 2 shipped only the one field that already had a consumer:
/// `storedPath`, so a duplicated image row had something non-default to
/// compare against its source. Stage 3 (this stage) adds the two remaining
/// v1 channels the item's provider bundle exposes — `colorspace` and
/// `useAlpha` (`layer_params.d`'s `kindParams`, §Q2 of the plan). Both are
/// inert today (nothing reads them; §Q2 records why) and both are AUTHORED
/// fields, never computed — the distinction that keeps them out of the
/// "derived value in a writable channel" trap `format` would have been.
/// Later stages extend this class rather than replace it: Stage 4 adds the
/// derived `resolvedPath` / `width` / `height` / `missing` / `format`
/// fields (the path model; NONE of those become provider params — they are
/// recomputed from the file, never authored), Stage 5 adds the pixel-cache
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
//      cannot ask a link that was cleared.
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
    static ItemLink to(Layer l) { ItemLink r; r.target_ = l; return r; }

    /// True iff a target was set. Says nothing about whether it resolves —
    /// that needs a document (`state`).
    bool isSet() const { return target_ !is null; }

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
    inout(Layer) targetUnchecked() inout { return target_; }
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
    ItemLink link(string name) {
        foreach (ref s; links_) if (s.name == name) return s.link;
        return ItemLink.init;
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
    bool linksTo(const(Layer) t) const {
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
/// `rehomePrimary`'s first production caller. `io/native.d`'s `.v3d` loader
/// still raw-writes `document.primary = parsed[primaryIndex]` before any
/// mutator runs (L3) — currently harmless because the v7 reader can only ever
/// produce mesh-kind layers (Stage 8/v8, which would let a non-mesh `"type"`
/// reach that raw write, is deferred to task 0616 by owner decision). A
/// caller reaching `Document` only through that one remaining site could
/// still violate the invariants below once a non-mesh layer becomes loadable.
///   * `layers.length >= 1` and `activeIndex < layers.length`.
///   * `primary !is null`; `primary` ∈ `layers`; `primary is layers[activeIndex]`;
///     `primary` always `canBePrimary` (today: always mesh-kind) — at least
///     one mesh-kind layer always exists (task 0615, §Q2).
///   * `primary.selected` is always true; at least one layer is always
///     selected (a SET-of-one by default; multi-foreground is representable).
///   * `focusedItem !is null`; `focusedItem` ∈ `layers`; `focusedItem.selected`.
///     `focusedItem` may be ANY kind — it is the item-selection FOCUS (item
///     transform / property panel / item ops), distinct from `primary` (the
///     MESH EDIT TARGET) only once a non-mesh item is selected (task 0615).
struct Document {
    Layer[] layers;            ///< flat list; always length >= 1
    Layer   primary;           ///< the MESH EDIT TARGET — component tools and
                               ///< commands bind `Mesh*` off this; always
                               ///< `canBePrimary` (today: always mesh-kind).
    // Task 0615 Stage 2: splits the role `primary` used to conflate. `primary`
    // is the mesh edit target; `focusedItem` is the item-selection focus (item
    // transform, property panel, item ops) and may be ANY kind. On an
    // all-mesh document the two always coincide — every mutator below keeps
    // them in lockstep unless the touched target cannot be primary (§L2).
    Layer   focusedItem;       ///< most-recently-touched selected item, any
                               ///< kind; `primary` on an all-mesh document.

    /// The index of the active (foreground) layer — DERIVED (Stage 2b) from the
    /// `primary` object's position in `layers`. Read-only: there is no stored
    /// field and no assignment LHS; every former writer routes through
    /// `setActive` / `selectItem` / `setPrimary` (which move `primary`). Because
    /// it follows the primary by IDENTITY, reorder/delete renumbering can never
    /// drift it. Returns 0 when `primary` is not found (degenerate; should never
    /// happen given the invariants).
    ///
    /// NIT (review round 2): cross-reference — `indexOf` is the same
    /// identity scan over `layers`, but its absent-sentinel is
    /// `layers.length`, not `0`. Do not treat the two as interchangeable.
    size_t activeIndex() const {
        foreach (i, l; layers) if (l is primary) return i;
        return 0;
    }

    /// The active (foreground) layer object — i.e. the primary.
    Layer     active()        { return primary; }
    /// Pointer to the primary layer's mesh (interior pointer, GC-traced).
    /// `primary` is always `hasMesh` (the document invariant, §Q2) — the
    /// `debug` assert in `meshRef()` is the dev-only backstop for that.
    Mesh*     activeMesh()    { return &primary.meshRef(); }
    /// Reference to the primary layer's mesh.
    ref Mesh  activeMeshRef() { return primary.meshRef(); }

    /// True iff `l` is the primary (the single edit target).
    bool isPrimary(const(Layer) l) const { return l is primary; }

    /// True iff `l` holds the item-selection focus. Distinct from `isPrimary`
    /// only once a non-mesh item is selected (task 0615, §Q2) — on an
    /// all-mesh document `focusedItem is primary` always, so the two agree.
    bool isFocused(const(Layer) l) const { return l is focusedItem; }

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

    /// The item-transform MOVING SET — every SELECTED item, in `layers`
    /// order. Task 0614 Phase 6, law L2 (`doc/tasks/0614-evidence/
    /// phase0_findings.md` case B): a transform gesture in Item mode moves
    /// the WHOLE selected set, not only the primary. This is the one place
    /// that answers "which items does the gizmo act on"; the transform tool
    /// resolves all three of its target lists (run baseline, headless
    /// one-shot baseline, undo session) through it so they cannot drift.
    ///
    /// Deliberately NOT `visible`-filtered. `foreground(l)` is
    /// `visible && selected`, and a hidden-but-selected layer is a
    /// representable state (`layer.setVisible` on a non-primary selected
    /// layer). Dropping it from the moving set would silently desync the
    /// undo payload from the selection the user sees in the layer list, and
    /// re-showing the layer would reveal it stranded at a stale pose. The
    /// primary is always visible (document invariant), so the shared action
    /// centre is unaffected either way.
    ///
    /// Fills `outBuf` IN PLACE (its `length` is the count) rather than
    /// returning a fresh array: the caller keeps long-lived buffers and
    /// re-resolves once per run / per session, so an allocating accessor
    /// would churn an array per gesture for nothing — and a `Document`-owned
    /// scratch buffer could not be shared by two callers without aliasing.
    ///
    /// `layers` order is DETERMINISTIC and stable, which
    /// `LayerXformEdit.mergeRunTail`'s first-touch union relies on for a
    /// reproducible multi-target undo payload.
    ///
    /// `kindInfo(l.kind).hasXform` is deliberately NOT consulted: the
    /// `static assert` over `kItemKindTable` (above) proves every declared
    /// kind participates in the item transform, so a filter here would be a
    /// branch that can never be false. This is a site to gate when a
    /// `hasXform == false` kind first lands — alongside `layer_params.d`,
    /// per that assertion's own message.
    void selectedItemsInto(ref Layer[] outBuf) {
        size_t n = 0;
        foreach (l; layers) if (l !is null && l.selected) ++n;
        if (outBuf.length != n) outBuf.length = n;
        size_t i = 0;
        foreach (l; layers) if (l !is null && l.selected) outBuf[i++] = l;
    }

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

    /// Set the active layer by index — routes through `exclusiveSelect` (task
    /// 0615, §L2), which keeps today's exact SET-of-one behaviour when `idx`
    /// names a mesh-kind layer, and otherwise SPARES the mesh primary from
    /// the exclusive deselect (a non-mesh target becomes `focusedItem` only).
    /// `activeIndex` follows `primary` by derivation (Stage 2b) — no index to
    /// write here. Callers MUST invoke this BEFORE any `fireSwitchIfChanged` /
    /// switch-hook call so the hook (which reads `activeMesh()` == primary's
    /// mesh) re-uploads the correct mesh — see the Stage-0 ordering rule.
    ///
    /// NIT (review round 2): this can be a TOTAL no-op. `exclusiveSelect`
    /// refuses silently when neither `target` nor the current `primary` nor
    /// `rehomePrimary` can produce a `canBePrimary` layer — a state the
    /// ≥1-mesh invariant forbids on a well-formed `Document`, but callers
    /// must not assume `setActive` always changes something (e.g. mid-
    /// assembly of a `Document` via direct field writes, before its first
    /// invariant-restoring call).
    void setActive(size_t idx) {
        if (layers.length == 0) { primary = null; focusedItem = null; return; }
        if (idx >= layers.length) idx = layers.length - 1;
        exclusiveSelect(layers[idx]);
    }

    /// L2 (task 0615): the single implementation of exclusive select.
    /// Computes `primary-after` FIRST, then leaves the selected set exactly
    /// `{target} ∪ {primary-after}`. On an all-mesh document `primary-after
    /// is target`, so this reduces — bit for bit — to "deselect everyone,
    /// select target, target becomes primary": today's exact behaviour, which
    /// is what keeps the existing suite green as the neutrality proof. When
    /// `target` cannot be primary, `primary-after` stays the CURRENT primary,
    /// so the mesh edit target is never evicted from the selected set (and
    /// never reclassified as background — see `Document.background`).
    private void exclusiveSelect(Layer target) {
        Layer primaryAfter = kindInfo(target.kind).canBePrimary ? target : primary;
        // B1 / SF1 (review round 2): `primary` can be null OR STALE here — a
        // `Document` built by direct field assignment (`d.layers = [...]`)
        // rather than `bootstrap()`, exactly the shape `io/scene_ir.d` and
        // `io/native.d` use before their first `setActive` call, OR a LIVE
        // Document whose `layers` a caller replaced by direct field write
        // before repointing `primary` (the `.v3d` loader reuses the app's
        // live Document by `ref` — `commands/file/load.d:122`). A plain
        // `is null` check does not catch the stale case: `primary` is
        // non-null, just no longer a member of `layers` — installing it
        // unchecked would be a silent L1 violation with no crash to notice
        // it by. `isMember` checks membership, not just nullness. Fall back
        // to a fresh scan for a mesh-kind layer, and refuse (no-op) only in
        // the state the ≥1-mesh invariant forbids.
        if (!isMember(primaryAfter)) primaryAfter = rehomePrimary(0);
        if (primaryAfter is null) return;
        foreach (l; layers) l.selected = false;
        target.selected = true;
        primaryAfter.selected = true;
        primary = primaryAfter;
        focusedItem = target;
    }

    // -----------------------------------------------------------------------
    // Stage 2a/2b multi-select mutators. They maintain the load-bearing
    // invariant contract (≥1 selected; primary selected+visible; hide-primary
    // promotes). `activeIndex` derives from `primary`, so no index bookkeeping
    // is needed and no stored `background` bool is touched (Stage 2b deleted it).
    // -----------------------------------------------------------------------

    /// The most-recent remaining selected+visible+`canBePrimary` layer OTHER
    /// than `exclude`, or null if none. v1 has no per-pick order counter
    /// (declared divergence B9), so "most recent" is approximated by scanning
    /// the list — adequate for the single-primary edit model. Used by
    /// hide-primary / remove-primary promotion — BOTH callers assign the
    /// result straight to `primary`, so the candidate must be `canBePrimary`
    /// (task 0615, renamed from `anotherSelectedVisible`).
    private Layer anotherPrimaryCandidate(Layer exclude) {
        foreach (l; layers)
            if (l !is exclude && l.selected && l.visible && kindInfo(l.kind).canBePrimary)
                return l;
        return null;
    }

    /// The single item-select mutator. Mirrors `mode:{set,add,remove,toggle}`.
    /// Invariants held on return: `primary !is null`, `primary ∈ layers`,
    /// `primary.selected`, `primary.hasMesh`; `focusedItem !is null`,
    /// `focusedItem ∈ layers`, `focusedItem.selected`; at least one layer
    /// selected. `background` is fully derived (Stage 2b) — there is no
    /// stored bool to keep in sync. Task 0615 (§L2): `primary` moves to `l`
    /// only when `l` `canBePrimary` — a non-mesh `l` becomes `focusedItem`
    /// and never evicts the mesh edit target.
    void selectItem(Layer l, SelMode mode) {
        // S5 / L1: guard membership, not just null — a `Layer` that is not
        // (or no longer) in `layers` must never become target/focus/primary.
        if (layers.length == 0 || l is null || indexOf(l) == layers.length) return;

        final switch (mode) {
            case SelMode.Set:
                exclusiveSelect(l);
                break;

            case SelMode.Add:
                l.selected = true;
                focusedItem = l;                        // newest touch is focus
                if (kindInfo(l.kind).canBePrimary) {
                    primary = l;
                } else {
                    // SF2 (review round 2): Add on a non-mesh layer must not
                    // leave `primary` null/stale — this arm never routes
                    // through `exclusiveSelect`, so nothing else here would
                    // repair it.
                    recoverStalePrimary();
                }
                break;

            case SelMode.Remove:
                if (!l.selected) break;       // not selected → nothing to do
                if (l is primary) {
                    // Removing the primary: promote the most-recent remaining
                    // selected+visible+canBePrimary layer. If none exists,
                    // this would leave no valid primary → refuse (no-op).
                    auto promote = anotherPrimaryCandidate(l);
                    if (promote is null) break;   // last-selected remove = no-op
                    l.selected = false;
                    primary = promote;
                    if (focusedItem is l) focusedItem = promote;
                } else {
                    // Non-primary remove is always safe (primary still holds
                    // the ≥1-selected invariant). If the removed layer held
                    // focus, focus falls back to the primary — focusedItem
                    // must stay selected, and the primary always is.
                    l.selected = false;
                    if (focusedItem is l) {
                        // SF1 (review round 2): guard MEMBERSHIP, not just
                        // null — `primary` can be non-null yet STALE (see
                        // `exclusiveSelect`'s comment). Blindly copying it
                        // into `focusedItem` would propagate the same L1
                        // violation into the focus pointer. This arm does
                        // NOT repair `primary` itself (only `Set`/`Add`/
                        // `setPrimary` do) — it only refuses to hand a stale
                        // value to `focusedItem`, falling back read-only to
                        // `rehomePrimary`.
                        Layer fallback = isMember(primary) ? primary : rehomePrimary(0);
                        if (fallback !is null) fallback.selected = true;
                        focusedItem = fallback;
                    }
                }
                break;

            case SelMode.Toggle:
                if (l.selected) selectItem(l, SelMode.Remove);
                else            selectItem(l, SelMode.Add);
                return;
        }
        // primary remains the mesh edit target; activeIndex derives from it.
    }

    /// Promote an already-selected layer to primary (the mesh edit target)
    /// without changing the selected set — UNLESS `l` cannot be primary (task
    /// 0615), in which case `primary` is left alone and `l` only becomes
    /// selected + `focusedItem`. If `l` is not selected this selects it (Add
    /// semantics) so the `focusedItem.selected` invariant holds. `setPrimary`
    /// is not exclusive today and must not become so.
    void setPrimary(Layer l) {
        // S5 / L1: same membership guard as `selectItem` — see there.
        if (layers.length == 0 || l is null || indexOf(l) == layers.length) return;
        if (!l.selected) l.selected = true;
        focusedItem = l;
        if (kindInfo(l.kind).canBePrimary) {
            primary = l;
        } else {
            // SF2 (review round 2): same recovery as `selectItem`'s `Add`
            // arm — `setPrimary` on a non-mesh `l` must not leave `primary`
            // null/stale either.
            recoverStalePrimary();
        }
    }

    /// Hide-primary promotion helper (called by the setVisible command path).
    /// Hiding the primary moves the primary to another selected+visible layer
    /// when one exists; returns false (refuse) when the primary is the only
    /// selected+visible layer (the caller then leaves it visible). Does NOT
    /// itself flip the `visible` flag — the command owns that, calling this
    /// AFTER setting visible=false to re-establish a visible primary.
    bool promoteAwayFromHiddenPrimary() {
        if (primary is null || primary.visible) return true;  // nothing to do
        auto promote = anotherPrimaryCandidate(primary);
        if (promote is null) return false;                    // refuse
        // S2: only re-home focus when the hidden primary WAS the focus.
        // Evaluated before `primary` moves, so a focus that is on some
        // OTHER still-selected, still-valid item is never stolen by this
        // promotion (mirrors the `if (focusedItem is l) …` gate already used
        // by `selectItem`'s Remove arm).
        immutable bool focusFollows = focusedItem is primary;
        primary = promote;
        if (focusFollows) focusedItem = promote;
        return true;
    }

    /// L1 (task 0615): the promotion algorithm a structural mutation of
    /// `layers` (e.g. a layer delete) must run to keep `primary` inside the
    /// list. `at` is the slot the OLD primary vacated — read against the
    /// POST-mutation `layers` slice. Scans forward from `at` first, then
    /// backward over `[0 .. at)`, for the first `canBePrimary` layer. Lazy,
    /// no allocation — this may run on a delete mid-drag.
    ///
    /// Caller precondition (NIT, undocumented before this revision): only
    /// call this when the layer that vacated slot `at` actually WAS
    /// `primary` (or otherwise needs re-homing). This function does not
    /// check that itself — it unconditionally returns *a* `canBePrimary`
    /// candidate near `at`, so calling it when the current `primary` is
    /// still valid will silently propose moving `primary` to someone else.
    /// Callers must gate on identity first, e.g.
    /// `removed is prevPrimary ? doc.rehomePrimary(at) : prevPrimary`
    /// (Stage 6's `LayerDelete`).
    ///
    /// Degenerate on an all-mesh document: returns `layers[at]` when
    /// `at < layers.length`, else `layers[$-1]` — EXACTLY today's positional
    /// successor rule (`commands/layer/commands.d:420-421`). Any drift in
    /// that degenerate case against `test_layers.d` / `test_layers_undo.d` /
    /// `test_layer_duplicate.d` means this generalisation is wrong, not that
    /// those tests need changing.
    ///
    /// Returns `null` only in the state the ≥1-mesh document invariant
    /// forbids — unreachable once the delete guard (Stage 6) refuses to
    /// remove the last `canBePrimary` layer.
    Layer rehomePrimary(size_t at) {
        immutable size_t start = at <= layers.length ? at : layers.length;
        foreach (l; layers[start .. $])
            if (kindInfo(l.kind).canBePrimary) return l;
        foreach_reverse (l; layers[0 .. start])
            if (kindInfo(l.kind).canBePrimary) return l;
        return null;
    }

    /// SF2 (task 0615, review round 2): repair `primary` IN PLACE when it is
    /// unusable — null OR STALE (`!isMember`, see `exclusiveSelect`'s
    /// comment) — for the two mutator arms that never route through
    /// `exclusiveSelect` (`selectItem`'s `Add` case and `setPrimary`) and
    /// therefore have no other chance to notice `primary` has gone bad. Only
    /// call this when the caller's own target could not itself become
    /// `primary` (i.e. `!canBePrimary`) — it does not touch `target` at all,
    /// only `this.primary`. Marks the recovered candidate `selected` (so the
    /// `primary.selected` invariant holds the moment this returns) and
    /// installs it. Returns the (possibly still null) result — null only in
    /// the state the ≥1-mesh invariant forbids.
    private Layer recoverStalePrimary() {
        if (isMember(primary)) return primary;
        auto candidate = rehomePrimary(0);
        if (candidate !is null) candidate.selected = true;
        primary = candidate;
        return candidate;
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
    assert(doc.isFocused(doc.focusedItem), "isFocused(focusedItem) is true");
    assert(doc.isFocused(doc.active()), "on an all-mesh document, focus == primary");
}

unittest {
    // accessor identity: active(), activeMesh(), activeMeshRef() all resolve
    // to the same heap mesh; the address is stable across repeated calls.
    Mesh m;
    auto doc = Document.bootstrap(m);

    Mesh* p1 = doc.activeMesh();
    Mesh* p2 = doc.activeMesh();
    assert(p1 is p2, "activeMesh() is stable across calls");

    assert(p1 is &doc.active().meshRef(),
           "activeMesh() points at the active layer's mesh field");
    assert(&doc.activeMeshRef() is p1,
           "activeMeshRef() and activeMesh() identify the same mesh");
    // primary aliases the active mesh.
    assert(p1 is &doc.primary.meshRef(), "activeMesh() points at the primary's mesh");

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
    assert(a1 is &doc.layers[1].meshRef(), "activeMesh() follows the primary");
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

/// TEST-ONLY oracle for the in-module unit tests below. Every check here is
/// a plain `assert()`, which `-release` strips entirely (dlang.org: `-release`
/// disables assertions other than `assert(0)`) — this function enforces
/// nothing in a release binary; production code must never come to depend on
/// it firing.
private void assertDocInvariants(ref Document d) {
    assert(d.layers.length >= 1, "layers.length >= 1");
    assert(d.primary !is null, "primary non-null");
    assert(d.focusedItem !is null, "focusedItem non-null (task 0615)");
    bool primaryInLayers = false;
    bool focusedInLayers = false;
    bool anyCanBePrimary = false;
    size_t selCount = 0;
    foreach (l; d.layers) {
        if (l is d.primary) primaryInLayers = true;
        if (l is d.focusedItem) focusedInLayers = true;
        if (l.selected) ++selCount;
        if (kindInfo(l.kind).canBePrimary) anyCanBePrimary = true;
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
    assert(focusedInLayers, "focusedItem is a member of layers (task 0615)");
    assert(d.primary.selected, "primary is selected");
    assert(d.focusedItem.selected,
        "focusedItem is selected (task 0615; relaxed from Stage 2's focusedItem is primary)");
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
    assert(kindInfo(d.primary.kind).canBePrimary, "primary can always be primary (task 0615, §Q2)");
    // NIT: similarly implied by `primaryInLayers` + `d.primary.selected`
    // above (the primary itself is a selected member of `layers`) — kept as
    // documentation, not as independent coverage.
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
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary+focus
    doc.selectItem(a, SelMode.Remove);         // remove non-primary, non-focus A
    assertDocInvariants(doc);
    assert(!a.selected && b.selected, "A deselected, B remains");
    assert(doc.primary is b, "primary unchanged on non-primary remove");
    assert(doc.focusedItem is b, "focus unchanged — A held neither primary nor focus");
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
    doc.selectItem(b, SelMode.Add);            // A,B selected; B primary+focus
    // Simulate the command: hide the primary, then promote.
    b.visible = false;
    auto ok = doc.promoteAwayFromHiddenPrimary();
    assert(ok, "promotion succeeds (A is selected+visible)");
    assertDocInvariants(doc);                  // primary must be visible now
    assert(doc.primary is a, "primary moved to the visible selected A");
    assert(doc.primary.visible, "promoted primary is visible");
    assert(doc.focusedItem is a, "S2: focus follows promotion when focus WAS on the hidden primary");
}

unittest {  // S2: hiding the primary must not steal focus from an unrelated,
            // still-selected, still-valid item — re-home focus ONLY when the
            // hidden primary WAS itself the focus. Fixture from the finding:
            // [MeshA(primary), Empty(selected,FOCUS), MeshB(selected)].
    auto doc = mixedDoc();                     // [MeshA(primary+focus), Empty, MeshB]
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(meshB, SelMode.Add);        // meshA,meshB selected; meshB primary+focus
    doc.setPrimary(meshA);                     // primary+focus back to meshA
    doc.selectItem(empty, SelMode.Add);        // + empty selected; focus->empty, primary stays meshA
    assertDocInvariants(doc);
    assert(doc.primary is meshA && doc.focusedItem is empty && meshB.selected);

    meshA.visible = false;
    auto ok = doc.promoteAwayFromHiddenPrimary();
    assert(ok, "promotion succeeds (meshB is selected+visible+canBePrimary)");
    assertDocInvariants(doc);
    assert(doc.primary is meshB, "primary promoted to the other mesh layer");
    assert(doc.focusedItem is empty,
        "S2: focus must not be stolen by a promotion it had nothing to do with");
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
// Task 0615 Stage 1: `ItemKind` + the capability table. Pure lookups — no
// `Document` involved yet.
// ---------------------------------------------------------------------------

unittest {  // every ItemKind has a row with a distinct, non-empty token.
    import std.traits : EnumMembers;
    bool[string] seen;
    foreach (k; EnumMembers!ItemKind) {
        auto info = kindInfo(k);
        assert(info.token.length > 0, "every kind has a non-empty wire token");
        assert(info.token !in seen, "wire tokens are pairwise distinct");
        seen[info.token] = true;
    }
}

unittest {  // kindFromToken is validated, reject-on-unknown (the R-cap #1
            // chokepoint: never a cast, never an index by a caller number).
            // S4: `kind` is `ref`, not `out` — a rejected token must leave
            // it TRULY unchanged (not silently reset to ItemKind.Mesh by
            // D's out-parameter zero-init), so seed it with a non-Mesh
            // sentinel and confirm every rejection leaves the sentinel.
    ItemKind k = ItemKind.Empty;
    assert(!kindFromToken("", k), "empty token rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (empty token)");
    assert(!kindFromToken("MESH", k), "wrong case rejected (case-sensitive)");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (wrong case)");
    assert(!kindFromToken("backdrop", k), "an unshipped kind's token rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (unshipped kind)");
    assert(!kindFromToken("\x00garbage\xff", k), "arbitrary garbage rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (garbage)");
}

unittest {  // tokenOf / kindFromToken round-trip for every shipped kind.
    import std.traits : EnumMembers;
    foreach (k; EnumMembers!ItemKind) {
        // Seed with the OPPOSITE kind so a match must genuinely overwrite it
        // (not merely "happen to already equal" the expected result).
        ItemKind back = (k == ItemKind.Mesh) ? ItemKind.Empty : ItemKind.Mesh;
        assert(kindFromToken(tokenOf(k), back), "tokenOf(k) must itself resolve");
        assert(back == k, "round-trip must return the same kind");
    }
}

unittest {  // a default-constructed Layer is a mesh item.
    auto l = new Layer;
    assert(l.kind == ItemKind.Mesh, "new Layer defaults to ItemKind.Mesh");
    assert(l.hasMesh, "a default Layer has a mesh");
    assert(l.meshOrNull !is null, "meshOrNull is non-null for a mesh item");
    assert(l.meshOrNull is &l.mesh_, "meshOrNull points at the mesh field");
    assert(&l.meshRef() is &l.mesh_, "meshRef() aliases the same mesh field");
}

unittest {  // a non-mesh item reports no mesh through the capability accessors.
    auto l = new Layer;
    l.kind = ItemKind.Empty;
    assert(!l.hasMesh, "Empty has no mesh capability");
    assert(l.meshOrNull is null, "meshOrNull is null for a non-mesh item");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T2 (capability-row half): `kindInfo(ItemKind.Image)`
// field by field, and the image-payload accessor trio (mirrors the mesh
// trio tests just above).
// ---------------------------------------------------------------------------

unittest {  // the Image row's five pre-existing capabilities are all false,
            // matching the measured reference item (no mesh, no transform,
            // never the mesh edit target, nothing drawn in the viewport, and
            // — Bend #2 — not listed in the scene list either).
    auto info = kindInfo(ItemKind.Image);
    assert(info.token == "image", "Image row's wire token");
    assert(!info.hasMesh,       "Image: hasMesh == false");
    assert(!info.hasXform,      "Image: hasXform == false (Bend #1 — the forcing assert row)");
    assert(!info.canBePrimary,  "Image: canBePrimary == false");
    assert(!info.drawsGeometry, "Image: drawsGeometry == false");
    assert(!info.isSceneItem,   "Image: isSceneItem == false (Bend #2)");
    // The one capability that IS true for this kind — the payload it owns.
    assert(info.hasImage, "Image: hasImage == true (it is the kind this bit exists for)");

    // Mesh and Empty must NOT have picked up the two new bits by accident —
    // both are real document items (visible in the layer panel), and
    // neither owns pixel data.
    assert(kindInfo(ItemKind.Mesh).isSceneItem,  "Mesh: isSceneItem == true");
    assert(kindInfo(ItemKind.Empty).isSceneItem, "Empty: isSceneItem == true");
    assert(!kindInfo(ItemKind.Mesh).hasImage,  "Mesh: hasImage == false");
    assert(!kindInfo(ItemKind.Empty).hasImage, "Empty: hasImage == false");
}

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
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    assert(doc.primary is meshA && doc.focusedItem is meshA);

    doc.selectItem(empty, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.focusedItem is empty, "Add on a non-mesh item moves focus");
    assert(doc.primary is meshA, "Add on a non-mesh item never moves primary");
    assert(meshA.selected, "the mesh primary stays selected under Add");
}

unittest {  // Stage 3 / L2, RED-before-fix: exclusive select of a non-mesh
            // item must not evict the mesh primary from the selected set —
            // via BOTH entry points that implement it (selectItem(Set) and
            // setActive).
    static void check(Document doc, Layer meshA, Layer empty) {
        assertDocInvariants(doc);
        assert(doc.primary is meshA, "primary is unchanged (Empty cannot be primary)");
        assert(doc.primary.selected, "L2: exclusive select must not deselect the primary");
        assert(!Document.background(doc.primary),
               "L2: the primary must not be reclassified as background");
        assert(empty.selected && doc.focusedItem is empty,
               "the target is selected and becomes the focus");
        size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
        assert(sel == 2, "selected set is exactly {target, primary-after}");
    }

    auto d1 = mixedDoc();
    d1.selectItem(d1.layers[1], SelMode.Set);
    check(d1, d1.layers[0], d1.layers[1]);

    auto d2 = mixedDoc();
    d2.setActive(1);
    check(d2, d2.layers[0], d2.layers[1]);
}

unittest {  // Stage 3: removing the last mesh selection promotes to the
            // OTHER mesh layer, never to the non-mesh candidate.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(empty, SelMode.Add);
    doc.selectItem(meshB, SelMode.Add);          // meshA, empty, meshB selected; meshB primary
    assertDocInvariants(doc);
    assert(doc.primary is meshB);
    doc.selectItem(meshB, SelMode.Remove);       // remove the primary
    assertDocInvariants(doc);
    assert(!meshB.selected);
    assert(doc.primary is meshA, "promotion skips the non-mesh candidate");
    assert(doc.primary.selected);
}

unittest {  // Stage 3: hiding the primary never promotes to a non-mesh item.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    doc.selectItem(empty, SelMode.Add);          // meshA, empty selected; meshA primary
    meshA.visible = false;
    auto ok = doc.promoteAwayFromHiddenPrimary();
    assert(!ok, "refuse — the only other selected layer cannot be primary");
    assert(doc.primary is meshA, "primary unchanged on refusal");
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

unittest {  // NIT: rehomePrimary on an EMPTY layers list must not crash and
            // must return null (the only answer the ≥1-mesh invariant allows
            // when there is nothing to promote to).
    Document doc;                                // default-constructed: layers.length == 0
    assert(doc.layers.length == 0);
    assert(doc.rehomePrimary(0) is null, "no layers => no candidate");
    assert(doc.rehomePrimary(5) is null, "an out-of-range `at` on an empty list is also safe");
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

unittest {  // SF1, RED-before-fix: exclusiveSelect (reached via BOTH
            // `selectItem(Set)` and `setActive`, mirroring the L2 test
            // above) must not install a STALE primary. Pre-fix, the null
            // check at `:291`/`:297` never fires (the stale reference is
            // non-null), so `primaryAfter` stays the stale layer and gets
            // written straight into `primary` — a silent L1 violation.
    static void check(Document doc, Layer empty, Layer meshB) {
        assertDocInvariants(doc);
        assert(doc.primary is meshB,
            "SF1: a STALE primary must be recovered via rehomePrimary, not installed as-is");
        assert(doc.isMember(doc.primary), "the recovered primary is a genuine member of layers");
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

unittest {  // SF2, RED-before-fix: selectItem(Add) on a non-mesh layer must
            // not leave `primary` null. A `Document` assembled by direct
            // field writes — the shape `io/scene_ir.d` / `io/native.d` use
            // before their first `setActive` call (task 0615's own B1
            // comment on `exclusiveSelect`) — starts with `primary is
            // null`; pre-fix, `Add`'s `if (canBePrimary) primary = l;` has
            // no `else`, so a non-mesh `l` leaves it null.
    Document doc;
    auto empty = new Layer; empty.name = "E"; empty.kind = ItemKind.Empty;
    auto meshA = new Layer; meshA.name = "M";
    doc.layers = [empty, meshA];            // primary/focusedItem still null

    doc.selectItem(empty, SelMode.Add);
    assert(doc.primary !is null, "SF2: Add must not leave primary null");
    assert(doc.primary is meshA, "SF2: Add recovers primary via rehomePrimary");
    assert(doc.primary.selected, "the recovered primary satisfies primary.selected");
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
    assert(doc.primary !is null, "SF2: setPrimary must not leave primary null");
    assert(doc.primary is meshA, "SF2: setPrimary recovers primary via rehomePrimary");
    assert(doc.focusedItem is empty, "setPrimary still moves focus to the target");
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

// ---------------------------------------------------------------------------
// Task 0617: ItemXform.modelSpace() — the picking-facing ModelSpace factory.
// ---------------------------------------------------------------------------

unittest {  // default ItemXform -> isIdentity, invertible, not mirrored;
    // m/mInv are literally identityMatrix (the exact fast path, §3.5).
    import math : identityMatrix;
    ItemXform x;
    auto ms = x.modelSpace();
    assert(ms.isIdentity && ms.invertible && !ms.mirrored);
    foreach (i; 0 .. 16) {
        assert(ms.m[i]    == identityMatrix[i]);
        assert(ms.mInv[i] == identityMatrix[i]);
    }
}

unittest {  // a non-zero pivot ALONE (rot=0, scl=1) must still be identity —
    // T(pivot)*I*T(-pivot) == I for any pivot. Pins that the isIdentity
    // check is deliberately blind to `pivot`.
    ItemXform x;
    x.pivot = Vec3(5, -3, 2);
    auto ms = x.modelSpace();
    assert(ms.isIdentity, "pivot alone (rot=0, scl=1) must not break the identity fast path");
}

unittest {  // M . M^-1 ~= I for a combined rot + non-uniform-scale + pivot xform.
    import std.math : isClose;
    ItemXform x;
    x.pos   = Vec3(4, -1, 2);
    x.rot   = Vec3(15, -40, 70);
    x.scl   = Vec3(2, 0.5f, 3);
    x.pivot = Vec3(1, 1, -1);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity && ms.invertible);

    auto prod = matMul4(ms.m, ms.mInv);
    foreach (i; 0 .. 16)
        assert(isClose(prod[i], identityMatrix[i], 1e-4f, 1e-4f),
               "M * mInv must be ~identity for a rot+non-uniform-scale+pivot transform");
}

unittest {  // The trap the plan calls out by name: R^T (what modelSpace's
    // mInv actually uses) is NOT the same matrix as matrixFromEulerZYX(-rot)
    // (Rz(-)*Ry(-)*Rx(-), the reverse-order product) for a rotation that
    // mixes more than one axis. If a future edit "simplifies" mInv's
    // rotation term to matrixFromEulerZYX(-rot), THIS must fail.
    import std.math : isClose;
    Vec3 rot = Vec3(20, -35, 50); // multi-axis, away from any accidental symmetry
    auto Rt = matrixFromEulerZYX(rot);
    // Hand-transpose (same construction modelSpace() uses internally).
    float[16] RtT = [
        Rt[0], Rt[4], Rt[ 8], 0,
        Rt[1], Rt[5], Rt[ 9], 0,
        Rt[2], Rt[6], Rt[10], 0,
        0,     0,     0,      1,
    ];
    auto wrongInverse = matrixFromEulerZYX(Vec3(-rot.x, -rot.y, -rot.z));
    bool anyDifferent = false;
    foreach (i; 0 .. 16)
        if (!isClose(RtT[i], wrongInverse[i], 1e-4f, 1e-4f)) anyDifferent = true;
    assert(anyDifferent,
        "R^T must differ from matrixFromEulerZYX(-rot) for a multi-axis rotation "
        ~ "-- if they match, the trap this test guards against has gone silent");
}

unittest {  // scl.z == 0 -> !invertible (and scl.x/scl.y likewise, R2).
    ItemXform x;
    x.scl = Vec3(2, 3, 0);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity);
    assert(!ms.invertible, "a zero scale component must report !invertible");
}

unittest {  // mirrored == true for exactly one OR three negative scale
    // components, false for zero or two — the PRODUCT rule (§3.7), not
    // "any component is negative".
    ItemXform x;

    x.scl = Vec3(2, 3, 4);      // zero negatives
    assert(!x.modelSpace().mirrored);

    x.scl = Vec3(-2, 3, 4);     // one negative
    assert(x.modelSpace().mirrored);

    x.scl = Vec3(-2, -3, 4);    // two negatives
    assert(!x.modelSpace().mirrored);

    x.scl = Vec3(-2, -3, -4);   // three negatives
    assert(x.modelSpace().mirrored);
}

unittest {  // projectionSpace's forward-projection identity, exercised through
    // the PRODUCTION factory (math.d's own unittest covers the general
    // primitive; this pins document.ItemXform.modelSpace() specifically).
    import std.math : PI, isClose;
    import math : projectionSpace, projectToWindow, lookAt, perspectiveMatrix, Viewport;

    ItemXform x;
    x.pos = Vec3(2, 0, -1);
    x.rot = Vec3(0, 25, 0);
    x.scl = Vec3(1, 1, 1);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity);

    Vec3 eye = Vec3(0, 3, 10);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(50.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 300; vp.height = 300; vp.eye = eye;

    Vec3 pLocal = Vec3(0.2f, 0.1f, 0.4f);
    auto vpLocal = projectionSpace(vp, ms);
    float px1, py1, z1;
    bool ok1 = projectToWindow(pLocal, vpLocal, px1, py1, z1);

    Vec3 pWorld = ms.toWorldPoint(pLocal);
    float px2, py2, z2;
    bool ok2 = projectToWindow(pWorld, vp, px2, py2, z2);

    assert(ok1 == ok2 && ok1);
    assert(isClose(px1, px2, 1e-3f, 1e-3f) && isClose(py1, py2, 1e-3f, 1e-3f),
        "projectionSpace(vp, x.modelSpace()) must agree with pre-transforming the point");
}

// ---------------------------------------------------------------------------
// Task 0617: the primary-layer ModelSpace resolver.
//
// Picking code that needs the CURRENT primary layer's transform but has no
// `Document` instance of its own — `http_providers.d`'s HTTP-thread-bridged
// providers, `tools/edit/topology_pen.d`'s `TopologyPenTool` (its
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
