module layer_params;

import params   : Param, ParamProvider;
import document : Layer, Document, kindInfo, ItemKind, ItemXform,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG, sanitizeItemXform;
import seltype  : SelType;

// ---------------------------------------------------------------------------
// LayerPropsProvider — exposes a layer's editable properties as registered
// `Param`s so the same forms / undo / serialize machinery that drives tools and
// stages can drive layer (item) properties.
//
// This provider is the single source of a layer's editable params: the
// layer-props form reads/writes them through it, the `layer.attr` command
// resolves attr names against it, and the `.v3d` codec persists the transform
// fields it exposes. ONE param declaration (below) drives the panel row, the
// UI-undo/coalescing write, and the read-back query — the "one declaration"
// goal, proven end-to-end through `name` (Phase 5).
//
// Design rationale:
//   * The provider WRAPS a `Layer*` rather than `Layer` implementing
//     `ParamProvider` itself — this keeps `Layer` a plain data class and avoids
//     a `document.d` → `params` coupling, and gives `onParamChanged` a home to
//     (later, P3) fire the change bus / notify the app.
//   * The per-layer transform is exposed as PER-COMPONENT scalar `Float` params
//     (`pos.x` … `pivot.z`, 12 floats) — NOT a single `Vec3` param — because the
//     forms `vec3` widget is a read-only stub; the editable Float widget binds
//     each component as its own pointer (mirroring how a transform tool binds
//     TX/TY/TZ scalar floats). Storage on `Layer.xform` stays `Vec3` fields; the
//     params hold component pointers into them.
//   * `name` (String) and `visible` (Bool) round out the 14 params. Only "safe"
//     scalar props are exposed — `selected`/`primary` are governed by the
//     selection-set invariants and are deliberately NOT writable params here.
// ---------------------------------------------------------------------------

final class LayerPropsProvider : ParamProvider {
    private Layer layer_;   // the wrapped layer (a class ⇒ stable heap identity)

    // P4 primary-transform interlock. When a transform tool is active, the panel
    // binds the item-selection FOCUS (`itemPropsTarget`, below) — which on any
    // all-mesh document IS the primary, the one the gizmo is operating on.
    // Task 0616 Ph4 widened the binding so a non-mesh focus is reachable; the
    // widening is conservative here, since a focused item that has no transform
    // at all (an image) exposes none of the 12 params this flag gates, and a
    // focused `Empty` at worst greys rows a geometry-mode gizmo is not writing.
    // Authoring
    // a primary transform mid-gesture would silently desync the gizmo from the
    // mesh it thinks it is moving (the transform is render-only; the gizmo + drag
    // math run in the layer's LOCAL frame). So while this flag is set, the 12
    // transform component params (pos.*/rot.*/scl.*/pivot.*) report DISABLED and
    // the panel greys those rows. This is a MID-GESTURE interlock, NOT a permanent
    // lock: the rows RE-ENABLE the instant the transform tool drops, and any value
    // authored while no tool is active PERSISTS. `name`/`visible` stay enabled.
    //
    // Task 0614 Phase 5 — NARROWED to the geometry subject. The interlock's whole
    // premise ("the gizmo edits VERTICES in the layer's local frame, so the item
    // transform is a second, invisible writer") is FALSE when the current
    // selection type is Item: there the gizmo's only write target IS
    // `Layer.xform`, i.e. these exact 12 params. Greying them then would hide the
    // numbers the gizmo is authoring and make the numeric panel unusable for the
    // whole time the item tool is up — the opposite of "gizmo and panel show the
    // same thing". So the guard is armed only for a NON-item subject; see
    // `setTransformGuard`.
    private bool transformGuard_;

    this(Layer l) { layer_ = l; }

    /// The wrapped layer (for callers that need it back).
    Layer layer() { return layer_; }

    /// Re-point this provider at a different layer. Lets a per-frame caller
    /// (the layer-props panel) keep ONE provider instance and rebind it to the
    /// live primary each frame instead of allocating a fresh provider every
    /// frame. The returned `params()` always alias the CURRENT layer's fields,
    /// so a rebind is allocation-free and keeps the provider correct.
    void setLayer(Layer l) { layer_ = l; }

    /// P4 + task 0614 Phase 5: set the primary-transform interlock (see
    /// `transformGuard_`). The app's panel hook computes "an active tool is a
    /// transform tool" each frame and passes it together with the CURRENT
    /// selection type, so the transform rows grey out only while a transform
    /// gesture could be desynced — and re-enable when the tool drops.
    ///
    /// `current` is the live authority (`currentSelType`), not a cached copy:
    /// under `SelType.Item` the transform tool writes these very params, so the
    /// interlock must NOT arm. Taking the type rather than a pre-reduced bool
    /// keeps the reason for the exemption at the place that states it, and makes
    /// the narrowing itself unit-testable (there is no headless surface that
    /// reports a panel row's greyed-ness).
    void setTransformGuard(bool toolActive, SelType current) {
        transformGuard_ = toolActive && current != SelType.Item;
    }

    // -----------------------------------------------------------------------
    // ParamProvider
    // -----------------------------------------------------------------------

    /// The layer params: `name` + `visible` (every kind), the 12
    /// transform-component Floats for a kind that `hasXform` (task 0616
    /// Stage 2), and — task 0616 Stage 3 — a per-kind CHANNEL bundle.
    /// Pointers alias the live `Layer` fields (or, for the image bundle,
    /// the live `ImageData` fields), so a write through a param's pointer
    /// mutates the backing storage and vice-versa.
    ///
    /// The transform bundle stays gated on the `hasXform` CAPABILITY
    /// (`kindInfo(layer_.kind).hasXform`, task 0616 Stage 2, resolving the
    /// forcing `static assert` at `document.d`'s `kItemKindTable`) — real
    /// factoring, on the evidence that TWO kinds (`mesh` and `empty`) sit on
    /// the true side for the capability's own stated reason, not because
    /// they happen to agree today. This is also what makes `layer.attr
    /// <img> pos.x 5` fail as an UNKNOWN attribute rather than silently
    /// succeed: `LayerAttr` resolves attr names against exactly this list
    /// (`commands/layer/commands.d`), so omitting the params here is both
    /// the "get" and the "set" gate — there is no separate write path to
    /// close.
    ///
    /// The per-kind bundle below (the image kind's `filename` /
    /// `colorspace` / `useAlpha`) is deliberately NOT gated on a
    /// capability bit — the plan's rev-2 conclusion (Bend #3): a bit used
    /// by exactly one kind is a kind check wearing a hat, and the next
    /// resource kind this chain adds (the not-yet-written reference-image
    /// item, task 0612) needs a THIRD bundle that fits neither `hasXform`'s
    /// nor an image-shaped bit. Dispatch is an explicit `final switch
    /// (layer_.kind)`, so a future `ItemKind` is a COMPILE ERROR at this
    /// switch instead of a silently empty bundle — the same forcing-
    /// function shape as the `static assert`s in `document.d`. Scaling
    /// limit, written down and not paid for now (the plan's own words):
    /// fine at three or four kinds; past that, move each kind's bundle
    /// beside its `ItemKindInfo` row instead of growing this switch
    /// forever.
    Param[] params() {
        immutable bool hasXform = kindInfo(layer_.kind).hasXform;
        // Task 0616 Stage 3: an Image-kind layer whose payload has not been
        // constructed yet has nothing for the image bundle's pointers to
        // bind to. Reachable today only through a still-open test-only hole
        // (R15 / Stage 10 — no production path creates an image item
        // without a payload); `params()` is a per-frame query, not the
        // place to construct one as a side effect, so it falls back to the
        // base bundle instead of dereferencing a null `ImageData`.
        //
        // No `kind == ItemKind.Image` prefix: `imageOrNull()` is ALREADY
        // capability-gated (`hasImage ? image_ : null`, document.d), so the
        // comparison would be dead code AND would spell the literal
        // `kind == ItemKind.X` idiom document.d's capability-table comment
        // bans. One null check covers both "wrong kind" and "no payload yet".
        auto img = layer_.imageOrNull();
        // Task 0612 Stage 2 — same shape, same null-fallback reasoning: an
        // image-plane layer whose payload has not been constructed yet has
        // nothing for the bundle's pointers to bind to, and `params()` is a
        // per-frame query, not the place to construct one as a side effect.
        // `imagePlaneOrNull()` is already capability-gated, so this one null
        // check covers both "wrong kind" and "no payload yet".
        auto plane = layer_.imagePlaneOrNull();

        // NIT (review round 4, still honoured): reserve the EXACT capacity
        // up front, then append each `Param` individually (`~=` under a
        // held capacity is amortized in-place) — one allocation total for
        // what the module intro (line 16-ish, "one declaration") calls a
        // per-frame snapshot, never an array LITERAL append.
        size_t cap = 2;                // name + visible, every kind
        if (hasXform)       cap += 12; // pos/rot/scl/pivot
        if (img !is null)   cap += 3;  // filename, colorspace, useAlpha
        if (plane !is null) cap += 10; // the image plane's authored channels

        Param[] result;
        result.reserve(cap);
        if (hasXform) {
            // Position (world translation).
            result ~= Param.float_("pos.x",   "Pos X",   &layer_.xform.pos.x,   0.0f);
            result ~= Param.float_("pos.y",   "Pos Y",   &layer_.xform.pos.y,   0.0f);
            result ~= Param.float_("pos.z",   "Pos Z",   &layer_.xform.pos.z,   0.0f);
            // Rotation (euler degrees, ZYX) — angle hint for coarser drag step.
            result ~= Param.float_("rot.x",   "Rot X",   &layer_.xform.rot.x,   0.0f).angle();
            result ~= Param.float_("rot.y",   "Rot Y",   &layer_.xform.rot.y,   0.0f).angle();
            result ~= Param.float_("rot.z",   "Rot Z",   &layer_.xform.rot.z,   0.0f).angle();
            // Scale (per-axis; default 1).
            //
            // R7, layer two — the magnitude CEILING, declared as an enforced
            // bound so the generic `injectParamsInto` clamp applies it on every
            // JSON/argstring/HTTP write without this provider being in the loop.
            // The symmetric range is deliberate: a NEGATIVE scale is a legitimate
            // mirror, so the bound may only cap the magnitude, never the sign.
            // The FLOOR is not expressible here (it excludes an interval AROUND
            // zero, which is not a min/max pair) and neither is the NaN rejection
            // (`enforceBounds` compares with `<`/`>`, and every comparison against
            // NaN is false) — both live in `sanitizeXform` below.
            result ~= Param.float_("scl.x",   "Scale X", &layer_.xform.scl.x,   1.0f)
                           .min(-MAX_ITEM_SCALE_MAG).max(MAX_ITEM_SCALE_MAG).enforceBounds();
            result ~= Param.float_("scl.y",   "Scale Y", &layer_.xform.scl.y,   1.0f)
                           .min(-MAX_ITEM_SCALE_MAG).max(MAX_ITEM_SCALE_MAG).enforceBounds();
            result ~= Param.float_("scl.z",   "Scale Z", &layer_.xform.scl.z,   1.0f)
                           .min(-MAX_ITEM_SCALE_MAG).max(MAX_ITEM_SCALE_MAG).enforceBounds();
            // Pivot (rotation/scale center).
            result ~= Param.float_("pivot.x", "Pivot X", &layer_.xform.pivot.x, 0.0f);
            result ~= Param.float_("pivot.y", "Pivot Y", &layer_.xform.pivot.y, 0.0f);
            result ~= Param.float_("pivot.z", "Pivot Z", &layer_.xform.pivot.z, 0.0f);
        }

        // Task 0616 Stage 3 — the per-kind channel bundle. `final switch`
        // (never `if (layer_.kind == ItemKind.Image)`): the compiler forces
        // every future `ItemKind` to be visited here, the same forcing-
        // function shape as document.d's capability-table `static assert`s.
        final switch (layer_.kind) {
            case ItemKind.Mesh:
            case ItemKind.Empty:
                break; // no kind-specific channels of their own yet
            case ItemKind.Image:
                if (img !is null) {
                    // `filename` is READ-ONLY on this generic path (plan
                    // §Q2 / R14): authoring it here would bypass the
                    // resolve + decode + refcount hook a later stage's
                    // dedicated `image.replace` command owns to keep the
                    // payload in sync with the path — the exact `visible`
                    // precedent below, one call site over. The flag is
                    // ENFORCED, not decorative: `LayerAttr.apply`
                    // (commands/layer/commands.d) rejects a write to a
                    // readonly param after the name resolve — `?` read-back
                    // still works. (`injectParamsInto` itself stays a generic
                    // typed-pointer writer with no policy; the gate lives at
                    // the write path, not in the injector.)
                    result ~= Param.string_("filename", "Filename",
                                             &img.storedPath, "").readonly();
                    // Enum over a CLOSED three-tag set (plan divergence 4) —
                    // narrower than the measured open `string`; nothing
                    // reads the value either way (plan §Q2), so the
                    // narrowing is inert today and reversible to
                    // `Param.string_` with no format change.
                    result ~= Param.enum_("colorspace", "Colorspace",
                                           &img.colorspace,
                                           [["(default)", "(default)"],
                                            ["sRGB",       "sRGB"],
                                            ["linear",     "Linear"]],
                                           "(default)");
                    result ~= Param.bool_("useAlpha", "Use Alpha",
                                           &img.useAlpha, true);
                }
                break;
            case ItemKind.ImagePlane:
                // Task 0612 Stage 2 — ten authored channels. The ELEVENTH
                // piece of the plane's v1 state, the link to its image clip,
                // is deliberately absent: a link is not a `Param` (it names a
                // `Layer` OBJECT, which no typed pointer can carry and no
                // JSON scalar can encode), so it rides its own command rather
                // than this generic form.
                if (plane !is null) {
                    // The projection's value set is CLOSED and matches what a
                    // cell can actually be: the six axis-aligned presets. It
                    // is an `enum_` over tokens rather than an int, so the
                    // `.v3d` channel carries the token and appending a value
                    // later cannot reshuffle a stored file.
                    result ~= Param.enum_("projection", "Projection",
                                           &plane.projection,
                                           [["top",    "Top"],
                                            ["bottom", "Bottom"],
                                            ["front",  "Front"],
                                            ["back",   "Back"],
                                            ["right",  "Right"],
                                            ["left",   "Left"]],
                                           "front");
                    result ~= Param.bool_("showInPerspective", "Show in Perspective",
                                           &plane.showInPerspective, true);
                    // R7-shaped guard: `pixelSize` is a LIVE, user-editable
                    // runtime input to a size, so a zero or a negative would
                    // reach the extent formula and produce a degenerate quad,
                    // and `enforceBounds` is what applies the floor on every
                    // JSON / argstring / HTTP write without this provider
                    // being in the loop. The floor is a FLOOR, not a reject
                    // sentinel — there is no "pixelSize < x means refuse"
                    // contract anywhere — so declaring it here is the whole
                    // guard. It is not count-like: nothing allocates or loops
                    // on it, so no kernel `MAX_` cap is owed. (NaN still is
                    // not caught by `enforceBounds`, whose comparisons are
                    // both false against NaN — the placement function rejects
                    // a non-finite extent input on its own side.)
                    result ~= Param.float_("pixelSize", "Pixel Size",
                                            &plane.pixelSize, 0.01f)
                                   .min(1e-6f).max(1e3f).enforceBounds();
                    result ~= Param.bool_("keepAspect", "Keep Aspect",
                                           &plane.keepAspect, true);
                    // The three look scalars are fractions, bounded for the
                    // same reason: they multiply into a shader and a value
                    // outside the range is not a stronger effect, it is a
                    // clipped one that the user cannot tell from a bug.
                    result ~= Param.float_("brightness", "Brightness",
                                            &plane.brightness, 0.0f)
                                   .min(-1.0f).max(1.0f).enforceBounds();
                    result ~= Param.float_("contrast", "Contrast",
                                            &plane.contrast, 0.0f)
                                   .min(-1.0f).max(1.0f).enforceBounds();
                    result ~= Param.float_("transparency", "Transparency",
                                            &plane.transparency, 0.0f)
                                   .min(0.0f).max(1.0f).enforceBounds();
                    result ~= Param.bool_("invert", "Invert",
                                           &plane.invert, false);
                    result ~= Param.bool_("flipHorizontal", "Flip Horizontal",
                                           &plane.flipHorizontal, false);
                    result ~= Param.bool_("smooth", "Smooth",
                                           &plane.smooth, false);
                }
                break;
        }

        // Bespoke layer props.
        //
        // `name` rides the GENERIC registry end-to-end: it is a plain String
        // param here, a form text row, and writable via `layer.attr 0 name
        // <new>` (UI-undoable + coalescing) — the "one declaration" proof
        // (Phase 5). `layer.rename` is kept as the explicit rename path, but
        // `name` ALSO participates in the same forms/undo/serialize machinery
        // as every transform component. (It always round-tripped through the
        // `.v3d` layer envelope; see io/native.d + test_v3d_layers.d.)
        result ~= Param.string_("name",    "Name",    &layer_.name,    "");
        // `visible` is EXPOSED as a readable Bool param (so the panel can show
        // it / a `?` query can read it back), but is DELIBERATELY NOT driven
        // through the generic `layer.attr` write path. Hiding a layer carries
        // an invariant side-effect — hiding the PRIMARY must promote another
        // selected+visible layer to primary — so the write must go through the
        // dedicated `layer.setVisible` command, which owns that promotion hook.
        // The layer-props form's visibility toggle therefore dispatches
        // `layer.setVisible`, never `layer.attr` (see config/forms/layer_props
        // .yaml). Writing `visible` via `layer.attr` would bypass the promotion
        // and could strand a hidden primary — so it is intentionally excluded
        // from the form's writable rows. This is the single principled
        // exception to "every layer property rides the generic param path."
        result ~= Param.bool_  ("visible", "Visible", &layer_.visible, true);
        return result;
    }

    /// R7, layer two — repair the wrapped layer's `ItemXform` after a generic
    /// param write, and report whether anything had to be repaired.
    ///
    /// `injectParamsInto` writes the raw JSON value through the typed pointer,
    /// applying only the declared `.min`/`.max` clamp. Two hazards survive that:
    ///
    ///  * **Non-finite, on any of the 12.** `enforceBounds` compares the incoming
    ///    value with `<` and `>`, and BOTH comparisons are false for NaN, so a
    ///    NaN sails through every declared bound. A NaN anywhere in the xform
    ///    makes `composedMatrix()` all-NaN, which then propagates into the action
    ///    centre, the axis basis, every snap frame and the exported file.
    ///    Policy: **reject** — restore the component's pre-write value, exactly
    ///    like a command that declines an out-of-domain argument. Rejecting
    ///    rather than coercing matters because there is no "nearest legal value"
    ///    for a NaN: any number we invented would be an edit the caller never
    ///    asked for. If the pre-write value is ITSELF non-finite (a document
    ///    loaded from a file written before this guard existed), fall back to the
    ///    channel's identity element so the repair always terminates in a
    ///    composable xform.
    ///  * **A `scl` component inside the degenerate band around zero.** That is
    ///    an interval EXCLUSION, which a min/max pair cannot express, so the
    ///    declared bounds only cap the magnitude from above. Policy: **clamp** —
    ///    push `|scl|` out to `MIN_ITEM_SCALE_MAG` with the sign preserved. Here
    ///    clamping is right where rejection was right above: `scl.x 0` is a
    ///    perfectly ordinary thing to type on the way to `0.5`, and the nearest
    ///    legal value is well defined.
    ///
    /// Called by the authored-write points in `layer.attr` — `apply()`, which
    /// owns the undo snapshot and the change-bus publication, and `revert()`,
    /// which re-injects the snapshotted prior value — each with the xform it
    /// captured BEFORE its own injection. The gesture path does not come through
    /// here (it is guarded at its own layer by the kernel's
    /// `clampedScaleComponent`) and neither does the `.v3d` reader (it calls
    /// `sanitizeItemXform` directly, with no prior value to restore); all three
    /// enforcement points read the bounds AND the policy from `document.d`, so
    /// they cannot drift apart.
    ///
    /// This wrapper is the provider-shaped face of `document.sanitizeItemXform`:
    /// it exists so a caller holding a `LayerPropsProvider` does not have to
    /// reach through to `layer_.xform` itself.
    bool sanitizeXform(ref const ItemXform before) {
        return sanitizeItemXform(layer_.xform, before);
    }

    /// P4: the 12 transform-component params (pos.*/rot.*/scl.*/pivot.*) are
    /// disabled while the primary-transform interlock is set (a transform tool is
    /// active — see `setTransformGuard`). `name`/`visible` are always enabled.
    /// This is a mid-gesture grey-out, not a permanent lock; the rows re-enable
    /// when the tool drops and any value authored tool-free persists.
    bool paramEnabled(string name) const {
        if (!transformGuard_) return true;
        // A transform component is one of pos/rot/scl/pivot (the dotted scalars).
        if (name.length >= 4) {
            immutable p4 = name[0 .. 4];
            if (p4 == "pos." || p4 == "rot." || p4 == "scl.") return false;
        }
        if (name.length >= 6 && name[0 .. 6] == "pivot.") return false;
        return true;
    }

    /// Intentional no-op (Phase 5 confirmed). `ParamProvider` (the interface this
    /// implements) DECLARES `onParamChanged` (params.d), so the method must exist
    /// — but for layer params the change-bus publication + revert snapshot are
    /// owned by the `layer.attr` command (commands/layer/commands.d), which fires
    /// `noteLayerChange(LayerChange.PropertyChanged)` itself after writing through
    /// the param pointer. The provider is never on a path that calls this hook
    /// (the panel writes go through `layer.attr`, not a direct provider-driven
    /// PropertyPanel mutation), so there is nothing for it to do. It stays a
    /// documented minimal stub rather than being deleted: removing it would break
    /// the interface contract, and a redraw needs no work here — an item-matrix
    /// change is read fresh from `composedMatrix()` at the two draw sites each
    /// frame (no GPU vertex re-upload, since vertices never move and the mesh
    /// `mutationVersion` is untouched).
    void onParamChanged(string name) {}
}

/// Which item the shared item-properties form binds — the item-selection
/// FOCUS, not the primary.
///
/// Task 0616 Ph4. The measured shape of the image list is explicit that a
/// clip's editable properties live OUTSIDE the list, in the shared properties
/// panel, and that the two must not overlap. That only means anything if the
/// shared panel can actually reach a non-mesh item, and bound to
/// `Document.primary` it never could: `primary` is by invariant a
/// `canBePrimary` item, i.e. always a mesh, so an image item's `colorspace` /
/// `useAlpha` params — declared in `kindParams` below precisely so the form
/// could show them — had no reachable surface at all.
///
/// This is the SAME correction task 0615 Stage 6 made to the Layers panel's
/// Delete button, and for the same reason: the panel highlighted the focus
/// while the affordance addressed the primary, so on any document where the
/// two differ the user acted on a row they were not looking at.
///
/// NOT a behaviour change on an all-mesh document. `focusedItem` and `primary`
/// coincide there always (a mesh is `canBePrimary`, so every select that moves
/// the focus moves the primary with it), which is what keeps every existing
/// mesh-only expectation intact — and what makes the test below meaningful
/// only because it also exercises a document where they differ.
///
/// Falls back to `primary` when the focus is not a MEMBER of the document —
/// `doc.isMember`, not `!is null` (review S4).
///
/// The two are not the same test, and only one of them is reachable.
/// "Non-null" is a document invariant, so a null focus is the case that cannot
/// happen; STALE is the one that can, and `Document.isMember`'s own doc comment
/// names the mechanism: a caller that replaces `layers` on a live `Document` by
/// direct field assignment leaves `focusedItem` non-null but no longer present
/// — which is exactly what `readV3d` does through `FileLoad`, and what
/// `document.d`'s own stale-focus fixture pins.
///
/// A stale focus is not a cosmetic problem here. This function's result is
/// handed to `document.indexOf`, which answers `layers.length` for a
/// non-member; `resolveIndex` (`commands/layer/commands.d`) CLAMPS that into
/// range, so every `layer.attr` the form dispatched would land on the LAST
/// item in the document — a real item, silently edited, with the panel showing
/// someone else's values. Falling back to `primary` targets an item that is a
/// member by invariant.
///
/// The sibling affordance added in the same change already gets this right
/// (`ui/image_rows.d`'s `imageRemoveTarget` refuses an out-of-range index);
/// this is the other half of one rule.
Layer itemPropsTarget(Document* doc) {
    if (doc is null) return null;
    return doc.isMember(doc.focusedItem) ? doc.focusedItem : doc.primary;
}

// ---------------------------------------------------------------------------
// P0.4b (task 0616 Ph4): the properties form follows the FOCUS.
//
// Discriminating: the fixture's focus is an IMAGE while its primary is a mesh,
// so an implementation returning `doc.primary` reads the mesh — a different
// object, with a different name and a different param set. The all-mesh half
// is the control that proves the change is inert where it must be.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ItemKind, ImageData;
    import mesh     : makeCube;
    import seltype  : SelMode;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "the mesh";
    assert(itemPropsTarget(&doc) is doc.primary,
        "all-mesh control: focus and primary coincide, so the binding is "
        ~ "unchanged from what it has always been");

    auto img = new Layer;
    img.name = "the image";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();
    doc.layers ~= img;
    doc.selectItem(img, SelMode.Set);

    assert(doc.primary is doc.layers[0],
        "vacuity guard: an image can never become the primary, so the focus "
        ~ "and the primary here really are different objects");
    assert(doc.focusedItem is img, "precondition: the image took the focus");

    auto bound = itemPropsTarget(&doc);
    assert(bound is img,
        "the properties form binds the FOCUS; binding the primary would show "
        ~ "'" ~ doc.primary.name ~ "' instead of '" ~ img.name ~ "'");

    // And the bound provider really does expose the image's own channels —
    // which is the whole point of following the focus.
    auto prov = new LayerPropsProvider(bound);
    bool sawColorspace = false;
    foreach (p; prov.params()) if (p.name == "colorspace") sawColorspace = true;
    assert(sawColorspace,
        "the image's per-kind channels are reachable through the bound "
        ~ "provider — they are not through the primary's");
}

// ---------------------------------------------------------------------------
// P0.4c (review S4): a STALE focus falls back to the primary.
//
// The guard here used to be `focusedItem !is null`, which is the UNREACHABLE
// case — non-null is a document invariant. The reachable one is stale:
// non-null but no longer a member of `layers`, which is what
// `Document.isMember`'s own doc comment describes and what a whole-document
// replacement by direct field assignment produces. `readV3d` (through
// `FileLoad`) is that replacement, on the live `Document`, every File → Open.
//
// WHY IT MATTERS, and why "it draws the wrong panel" understates it: the bound
// item's index is what the form's rows dispatch `layer.attr` against.
// `indexOf` answers `layers.length` for a non-member and `resolveIndex`
// (`commands/layer/commands.d`) CLAMPS that into range — so every edit made in
// the properties panel would land on the LAST item in the document. The
// assertion below reads that number directly rather than describing it.
//
// Discriminating: the stale item is a real, live `Layer` object with a
// different name, so a `!is null` implementation returns it and every
// assertion here reads it — `is` identity, not "not null".
// ---------------------------------------------------------------------------
unittest {
    import document : Document, Layer;
    import mesh     : makeCube;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "the document that was open before";
    auto stale = doc.focusedItem;
    assert(stale !is null, "fixture: there is a focus to go stale");

    // The whole layer list is replaced by direct field assignment — the shape
    // `readV3d` uses, and the only way `primary`/`focusedItem` can go stale.
    auto fresh = new Layer;
    fresh.name = "the document just loaded";
    fresh.meshRef() = makeCube();
    fresh.selected  = true;
    doc.layers      = [fresh];
    doc.primary     = fresh;
    // …and `focusedItem` is deliberately NOT repointed: that is the bug state.

    assert(doc.focusedItem is stale,
        "precondition: the focus still points at the OLD object — if a "
        ~ "mutator had already healed it there would be nothing to test");
    assert(!doc.isMember(doc.focusedItem),
        "…and that object is no longer in the document, which is exactly what "
        ~ "`!is null` cannot see");
    assert(doc.indexOf(doc.focusedItem) == doc.layers.length,
        "…so its index is the out-of-range sentinel that `resolveIndex` "
        ~ "clamps onto the last item");

    auto bound = itemPropsTarget(&doc);
    assert(bound is fresh,
        "a stale focus falls back to the primary; a `!is null` guard binds '"
        ~ stale.name ~ "' — an item that left the document, whose index "
        ~ "clamps every `layer.attr` the panel dispatches onto the last row");
    assert(doc.isMember(bound),
        "…and whatever is bound is a genuine member, which is the property "
        ~ "the index arithmetic downstream depends on");
}

// ---------------------------------------------------------------------------
// In-module unit test (P0.4): the 14 expected names/kinds, the pointers alias
// the layer fields (mutating the param value changes the layer and vice-versa),
// and a round-trip through paramToJson → injectParamsInto restores values.
// ---------------------------------------------------------------------------

unittest {
    import std.math : isClose;
    import std.json : JSONValue;
    import params   : paramToJson, injectParamsInto;
    import math     : Vec3;

    auto l = new Layer;
    l.name = "Layer 1";
    auto prov = new LayerPropsProvider(l);

    // ---- the 14 expected names / kinds, in order ----------------------------
    auto ps = prov.params();
    assert(ps.length == 14, "LayerPropsProvider exposes exactly 14 params");

    struct Spec { string name; Param.Kind kind; }
    Spec[] expect = [
        Spec("pos.x",   Param.Kind.Float),
        Spec("pos.y",   Param.Kind.Float),
        Spec("pos.z",   Param.Kind.Float),
        Spec("rot.x",   Param.Kind.Float),
        Spec("rot.y",   Param.Kind.Float),
        Spec("rot.z",   Param.Kind.Float),
        Spec("scl.x",   Param.Kind.Float),
        Spec("scl.y",   Param.Kind.Float),
        Spec("scl.z",   Param.Kind.Float),
        Spec("pivot.x", Param.Kind.Float),
        Spec("pivot.y", Param.Kind.Float),
        Spec("pivot.z", Param.Kind.Float),
        Spec("name",    Param.Kind.String),
        Spec("visible", Param.Kind.Bool),
    ];
    foreach (i, e; expect) {
        assert(ps[i].name == e.name, "param name at index mismatch");
        assert(ps[i].kind == e.kind, "param kind at index mismatch");
    }
    // The three rotation params carry the angle hint.
    assert(ps[3].hints.isAngle && ps[4].hints.isAngle && ps[5].hints.isAngle,
           "rot.x/y/z are angle params");
    // paramEnabled is true for all (P0).
    foreach (e; expect) assert(prov.paramEnabled(e.name));

    // ---- pointers alias the layer fields (both directions) ------------------
    // Layer → param: mutate the layer, read it back through paramToJson.
    l.xform.pos = Vec3(3, -2, 5);
    auto ps2 = prov.params();
    assert(isClose(paramToJson(ps2[0]).floating, 3.0,  1e-6));
    assert(isClose(paramToJson(ps2[1]).floating, -2.0, 1e-6));
    assert(isClose(paramToJson(ps2[2]).floating, 5.0,  1e-6));

    // Param → layer: write through the param's typed pointer, see the layer.
    *ps2[6].fptr = 2.0f;   // scl.x
    assert(isClose(l.xform.scl.x, 2.0f, 1e-6f),
           "writing through the param pointer mutates the layer");

    // ---- round-trip: paramToJson → injectParamsInto restores values ---------
    // Snapshot current values, perturb the layer, then inject the snapshot back.
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    auto snap = prov.params();
    foreach (ref p; snap) pj[p.name] = paramToJson(p);

    // Perturb every field away from the snapshot.
    l.xform.pos   = Vec3(0, 0, 0);
    l.xform.rot   = Vec3(9, 9, 9);
    l.xform.scl   = Vec3(7, 7, 7);
    l.xform.pivot = Vec3(1, 1, 1);
    l.name        = "changed";
    l.visible     = false;

    auto sink = prov.params();
    injectParamsInto(sink, pj);

    // Values restored to the snapshot.
    assert(isClose(l.xform.pos.x, 3.0f,  1e-6f));
    assert(isClose(l.xform.pos.z, 5.0f,  1e-6f));
    assert(isClose(l.xform.scl.x, 2.0f,  1e-6f));
    assert(isClose(l.xform.scl.y, 1.0f,  1e-6f));   // unchanged default 1
    assert(l.name == "Layer 1", "name round-tripped");
    assert(l.visible == true,   "visible round-tripped");
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 5 — the transform interlock is narrowed to a GEOMETRY
// subject.
//
// This is the ONLY place the narrowing can be observed: `paramEnabled` feeds
// the forms renderer's greyed-row decision and nothing else, so there is no
// HTTP surface (a `layer.attr` write is a command and lands whether or not the
// row is greyed — that is what makes an end-to-end test of this property
// impossible, not merely inconvenient).
//
// BOTH directions are asserted on purpose. Asserting only the Item case would
// be satisfied by deleting the interlock outright — which is a different, worse
// change that this test must not wave through.
// ---------------------------------------------------------------------------

unittest {
    import std.conv : to;   // `t` is a RUNTIME loop variable: `t.stringof` is
                            // the literal "t", never the enum member's name.
    auto l = new Layer;
    auto prov = new LayerPropsProvider(l);

    static immutable string[] transformRows = [
        "pos.x", "pos.y", "pos.z", "rot.x", "rot.y", "rot.z",
        "scl.x", "scl.y", "scl.z", "pivot.x", "pivot.y", "pivot.z",
    ];

    // No tool at all: everything is editable, whatever the selection type is.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item]) {
        prov.setTransformGuard(false, t);
        foreach (n; transformRows)
            assert(prov.paramEnabled(n),
                   "with no transform tool active every transform row stays "
                   ~ "editable, regardless of selection type (" ~ n ~ ")");
    }

    // Transform tool + a GEOMETRY subject: the interlock arms. The gizmo is
    // moving VERTICES in the layer's local frame; the item transform is a
    // second, invisible writer and authoring it mid-gesture desyncs the two.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon]) {
        prov.setTransformGuard(true, t);
        foreach (n; transformRows)
            assert(!prov.paramEnabled(n),
                   "a transform tool over a GEOMETRY selection must still grey "
                   ~ "the transform rows (" ~ n ~ ", selType " ~ t.to!string ~ ")");
        assert(prov.paramEnabled("name") && prov.paramEnabled("visible"),
               "name/visible are never part of the interlock");
    }

    // Transform tool + an ITEM subject: the interlock must NOT arm. Here the
    // gizmo's only write target IS `Layer.xform`, so there is no second writer
    // to desync from — and greying the rows would hide the very numbers the
    // gizmo is authoring for as long as the tool is up.
    prov.setTransformGuard(true, SelType.Item);
    foreach (n; transformRows)
        assert(prov.paramEnabled(n),
               "under SelType.Item the transform tool IS the item editor — the "
               ~ "row must stay live (" ~ n ~ ")");
    assert(prov.paramEnabled("name") && prov.paramEnabled("visible"));
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 5 — R7 layer two: `sanitizeXform`.
//
// The rig is deliberately displaced and rotated OFF EVERY AXIS with a
// non-uniform, non-unit scale. A rig at the origin with identity rotation and
// unit scale cannot tell "restored the pre-write value" from "reset to the
// channel's identity", which is precisely the wrong implementation this test
// exists to catch.
//
// NOTE ON REACHABILITY, stated here so nobody later "promotes" this to an HTTP
// test and gets a green that means nothing: a NaN cannot be delivered over the
// wire. The argstring number scanner (argstring.d) accepts only
// `-?digits(.digits)?` — `NaN` lexes as a BAREWORD, and `params._jsonFloat`
// answers 0.0f for any non-numeric JSON — while JSON itself has no NaN literal.
// So the non-finite arm is reachable from in-process callers (the forms panel's
// float scratch, a `.v3d` load, any future writer) and is pinned HERE. The
// magnitude band, by contrast, IS reachable over the wire and is pinned end to
// end in tests/test_item_panel_gizmo_sync.d.
// ---------------------------------------------------------------------------

unittest {
    import std.math : isClose, isNaN, isFinite;
    import math     : Vec3;

    static ItemXform rig() {
        ItemXform x;
        x.pos   = Vec3( 1.3f,  0.7f, -0.9f);
        x.rot   = Vec3(20.0f, 35.0f, -50.0f);
        x.scl   = Vec3( 1.4f,  0.8f,  1.9f);
        x.pivot = Vec3(0.25f, -0.4f,  0.6f);
        return x;
    }

    immutable float nan = float.nan;
    immutable float inf = float.infinity;

    // ---- non-finite on a POSITION component: rejected, prior value restored --
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.pos.y = nan;                    // what injectParamsInto would leave
        assert(prov.sanitizeXform(before), "a NaN write must be reported repaired");
        assert(isClose(l.xform.pos.y, 0.7f, 1e-6f),
               "a rejected write restores the PRE-WRITE value (0.7), not the "
               ~ "channel identity (0.0) — the rig is off-origin precisely so "
               ~ "those two are distinguishable");
        // Nothing else moved.
        assert(l.xform.pos.x == before.pos.x && l.xform.pos.z == before.pos.z);
        assert(l.xform.rot == before.rot && l.xform.scl == before.scl
               && l.xform.pivot == before.pivot,
               "the repair touches only the component that went non-finite");
    }

    // ---- non-finite on a SCALE component: rejected, prior value restored -----
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.z = inf;
        assert(prov.sanitizeXform(before));
        assert(isClose(l.xform.scl.z, 1.9f, 1e-6f),
               "an infinite scale restores the PRE-WRITE 1.9, not the identity "
               ~ "1.0 and not the floor 1e-4");
    }

    // ---- non-finite prior as well: falls back to the channel identity -------
    // A document loaded from a file written before this guard existed can carry
    // a poisoned value; the repair must still terminate somewhere composable.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        before.rot.x = nan;                     // the PRIOR value is unusable too
        auto prov = new LayerPropsProvider(l);

        l.xform.rot.x = nan;
        assert(prov.sanitizeXform(before));
        assert(l.xform.rot.x == 0.0f,
               "with no usable prior, a rotation falls back to its identity (0)");

        before.scl.y = nan;
        l.xform.scl.y = nan;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.y == 1.0f,
               "with no usable prior, a scale falls back to its identity (1) — "
               ~ "NOT 0, which would be singular");
    }

    // ---- the degenerate band around zero: clamped, SIGN PRESERVED -----------
    // Sign preservation is the load-bearing half: a negative scale is a legal
    // mirror, so an implementation that clamped to a positive floor would read
    // +1e-4 where this reads -1e-4.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x =  0.0f;
        l.xform.scl.y = -1e-9f;
        l.xform.scl.z =  1e-9f;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.x ==  MIN_ITEM_SCALE_MAG);
        assert(l.xform.scl.y == -MIN_ITEM_SCALE_MAG,
               "a NEGATIVE near-zero scale floors to the NEGATIVE floor — a "
               ~ "mirror must survive the guard that keeps the matrix invertible");
        assert(l.xform.scl.z ==  MIN_ITEM_SCALE_MAG);
    }

    // ---- the magnitude ceiling, both signs ----------------------------------
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x =  1e30f;
        l.xform.scl.y = -1e30f;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.x ==  MAX_ITEM_SCALE_MAG,
               "a finite-but-absurd scale is capped at the ceiling, not passed "
               ~ "through — 1e30 squares to +inf at the first matrix product");
        assert(l.xform.scl.y == -MAX_ITEM_SCALE_MAG,
               "the ceiling preserves the sign, like the floor");
    }

    // ---- a legal xform is left BYTE-IDENTICAL and reports "not repaired" ----
    // Without this, an implementation that unconditionally rewrote every
    // component (rounding, renormalising, clamping to a narrower band) would
    // pass every assertion above.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        assert(!prov.sanitizeXform(before),
               "a legal xform must report NOTHING repaired");
        assert(l.xform.pos   == before.pos   && l.xform.rot   == before.rot
            && l.xform.scl   == before.scl   && l.xform.pivot == before.pivot,
               "a legal xform must come through byte-identical");
    }

    // ---- the composed matrix is finite and non-singular after a repair ------
    // The property R7 actually cares about, asserted directly rather than
    // inferred from the components.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x = 0.0f;
        l.xform.scl.y = nan;
        prov.sanitizeXform(before);
        auto m = l.xform.composedMatrix();
        foreach (v; m) assert(isFinite(v), "no NaN/Inf survives into the matrix");
        // det of the upper-left 3x3 — non-zero ⇒ invertible.
        immutable float det =
              m[0] * (m[5]*m[10] - m[6]*m[9])
            - m[4] * (m[1]*m[10] - m[2]*m[9])
            + m[8] * (m[1]*m[6]  - m[2]*m[5]);
        assert(det != 0.0f && isFinite(det),
               "the repaired xform composes to an INVERTIBLE matrix — the whole "
               ~ "point of the floor");
    }
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T2 (per-kind channels half): the IMAGE kind's param
// NAME SET must differ from the MESH kind's — SET equality, not count, and
// specifically `pos.x` must be ABSENT, not merely present-and-disabled. An
// implementation that kept the 12 transform params and returned
// `paramEnabled == false` for an image-kind layer would read DIFFERENT from
// this assertion (both the length AND the presence of "pos.x" in the name
// set would differ), so this is the fixture that catches that specific
// wrong shape, not merely "some kind of gating exists".
// ---------------------------------------------------------------------------
unittest {
    import document : ItemKind;

    auto mesh = new Layer;
    mesh.name = "Mesh";
    auto meshProv = new LayerPropsProvider(mesh);
    auto meshParams = meshProv.params();

    auto img = new Layer;
    img.name = "Image";
    img.kind = ItemKind.Image;
    auto imgProv = new LayerPropsProvider(img);
    auto imgParams = imgProv.params();

    assert(meshParams.length == 14, "mesh-kind layer still exposes all 14 params");
    assert(imgParams.length == 2, "image-kind layer exposes only name + visible");

    bool[string] meshSet, imgSet;
    foreach (p; meshParams) meshSet[p.name] = true;
    foreach (p; imgParams)  imgSet[p.name]  = true;

    assert(("pos.x"   in meshSet) !is null, "fixture: pos.x IS a mesh-kind param");
    assert(("pos.x"   in imgSet)  is  null, "pos.x must be ABSENT from the image-kind set, not merely disabled");
    assert(("rot.y"   in imgSet)  is  null, "rot.y must be ABSENT from the image-kind set");
    assert(("pivot.z" in imgSet)  is  null, "pivot.z must be ABSENT from the image-kind set");
    assert(("name"    in imgSet)  !is null, "name survives on every kind");
    assert(("visible" in imgSet)  !is null, "visible survives on every kind");

    // NIT (review round 4): the two assertions above alone don't separate
    // "gated on the `hasXform` CAPABILITY" from "gated on `kind ==
    // ItemKind.Mesh`" — every fixture so far is Mesh on one side and
    // non-Mesh on the other, so a kind-equality check would pass them
    // identically. `Empty` is the discriminator: it `hasXform == true` but
    // `hasMesh == false` (`document.d`'s `kItemKindTable`) — it is neither
    // Mesh nor Image. A `kind == ItemKind.Mesh` implementation would give it
    // only `name`/`visible` (2 params, `pos.x` absent); the real
    // capability-read implementation must give it the full 14, `pos.x`
    // included, because the capability it actually has is true.
    auto placeholder = new Layer;
    placeholder.name = "Placeholder";
    placeholder.kind = ItemKind.Empty;
    auto placeholderProv = new LayerPropsProvider(placeholder);
    auto placeholderParams = placeholderProv.params();
    assert(placeholderParams.length == 14,
        "Empty (hasXform==true, hasMesh==false) must still get the full 14-param set — "
        ~ "a kind==Mesh check would wrongly give it 2");
    bool[string] placeholderSet;
    foreach (p; placeholderParams) placeholderSet[p.name] = true;
    assert(("pos.x" in placeholderSet) !is null,
        "pos.x must be PRESENT for Empty — a kind==Mesh check would wrongly omit it");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 3: the image kind's own channel bundle —
// `filename` (readonly) / `colorspace` (Enum) / `useAlpha` (Bool) — bound
// to a CONSTRUCTED `ImageData`. The unittest above already pins the
// null-payload fallback (an image-kind layer with no `ImageData` yet reads
// exactly 2 params, same as before this stage); this one pins the bundle
// itself once a payload exists, and every assertion below was verified by a
// deliberate, restored break: dropping `.readonly()` flips the readonly
// assertion; swapping `Param.enum_` for `Param.string_` on `colorspace`
// removes the `enumValues` entries and makes the bogus-tag inject NOT
// throw; deleting the `if (img !is null)` guard's outer condition (i.e.
// always emitting the bundle) makes the null-payload case in the unittest
// above dereference a null `ImageData` instead of reading length 2; and
// binding either default to the LIVE field value instead of a literal
// (`Param.enum_(..., &img.colorspace, tags, img.colorspace)`) makes the
// non-default-snapshot default assertions read "sRGB"/false.
// ---------------------------------------------------------------------------
unittest {
    import std.json  : JSONValue;
    import params    : paramToJson, injectParamsInto;
    import document  : ImageData;

    auto img = new Layer;
    img.name = "logo";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();
    img.imageRef().storedPath = "assets/logo.png";

    auto prov = new LayerPropsProvider(img);
    auto ps = prov.params();

    // Discriminating (count + set): a payload-bearing image layer gets
    // EXACTLY 5 params — filename/colorspace/useAlpha + name/visible — not
    // the bare 2 the null-payload fixture above reads, and not the 14 a
    // hasXform-style bundle would give a kind that has none.
    assert(ps.length == 5,
        "payload-bearing image layer exposes filename+colorspace+useAlpha+name+visible");

    Param* byName(Param[] arr, string n) {
        foreach (ref p; arr) if (p.name == n) return &p;
        return null;
    }
    auto filenameP   = byName(ps, "filename");
    auto colorspaceP = byName(ps, "colorspace");
    auto useAlphaP   = byName(ps, "useAlpha");
    assert(filenameP   !is null, "filename channel present");
    assert(colorspaceP !is null, "colorspace channel present");
    assert(useAlphaP   !is null, "useAlpha channel present");
    assert(byName(ps, "pos.x") is null, "image kind still has no transform channels");
    assert(byName(ps, "format") is null,
        "format is NEVER a channel — it is derived, not authored (plan §Q2)");

    // ---- kinds, exactly (discriminates a String/Bool mix-up) ----------------
    assert(filenameP.kind   == Param.Kind.String, "filename is a String param");
    assert(colorspaceP.kind == Param.Kind.Enum,   "colorspace is an Enum param");
    assert(useAlphaP.kind   == Param.Kind.Bool,   "useAlpha is a Bool param");

    // ---- filename is read-only; the other two channels are NOT --------------
    // Discriminating: a wrong implementation that forgets `.readonly()`
    // reads `filenameP.readonly_ == false` here.
    assert(filenameP.readonly_,    "filename must be marked readonly");
    assert(!colorspaceP.readonly_, "colorspace is a writable channel");
    assert(!useAlphaP.readonly_,   "useAlpha is a writable channel");

    // ---- colorspace's tag set is the closed three-tag set, exactly ----------
    assert(colorspaceP.enumValues.length == 3,
        "colorspace has exactly the three declared tags");
    bool[string] tags;
    foreach (e; colorspaceP.enumValues) tags[e[0]] = true;
    assert(("(default)" in tags) !is null);
    assert(("sRGB"       in tags) !is null);
    assert(("linear"     in tags) !is null);

    // ---- defaults: NOT asserted here, deliberately -------------------------
    // The obvious place for `colorspaceP.default_.s == "(default)"` is right
    // here — and it would be INERT. `ps` was captured off a fresh
    // `new ImageData()`, whose field initialisers ARE "(default)"/true, so a
    // wrong implementation that binds the default to the LIVE value
    // (`Param.enum_(..., &img.colorspace, tags, img.colorspace)`) reads the
    // identical value through the assertion and stays green. That bug is not
    // cosmetic: `default_` is what `isUserSet` compares against (params.d), so
    // a live-bound default makes `isUserSet` permanently false. The default
    // assertions therefore live on the NON-DEFAULT snapshot further down
    // (search "defaults are LITERALS"), where the two implementations read
    // different values.

    // ---- pointers alias the live ImageData (both directions) ----------------
    img.imageRef().storedPath = "changed/path.png";
    auto ps2 = prov.params();
    assert(paramToJson(*byName(ps2, "filename")).str == "changed/path.png",
        "filename param reads the live storedPath");
    *byName(ps2, "colorspace").sptr = "linear";
    assert(img.imageRef().colorspace == "linear",
        "writing through the colorspace param pointer mutates the payload");
    *byName(ps2, "useAlpha").bptr = false;
    assert(img.imageRef().useAlpha == false,
        "writing through the useAlpha param pointer mutates the payload");

    // ---- generic round-trip: paramToJson -> injectParamsInto ----------------
    // Non-default values throughout (mirrors the plan's T8d reasoning: a
    // default-valued fixture cannot tell a codec that drops the block from
    // one that reads it correctly).
    img.imageRef().colorspace = "sRGB";
    img.imageRef().useAlpha  = false;
    auto snap = prov.params();

    // ---- defaults are LITERALS, not the live field value (plan §Q2) --------
    // Asserted HERE, off a snapshot whose live values are "sRGB"/false, NOT
    // off the fresh-`ImageData` snapshot above where the initialisers happen
    // to equal the defaults. Discriminating: an implementation that binds the
    // default to the live value reads "sRGB"/false here and goes RED; the
    // correct one reads the declared literals. (Also pins the measured
    // reference values themselves.)
    assert(byName(snap, "colorspace").default_.s == "(default)",
        "colorspace default is the LITERAL '(default)', not the live field value");
    assert(byName(snap, "useAlpha").default_.b == true,
        "useAlpha default is the LITERAL true, not the live field value");
    // ...and the live values really are the non-default ones, so the two
    // assertions above cannot have been read off a coincidence.
    assert(*byName(snap, "colorspace").sptr == "sRGB",
        "fixture precondition: colorspace's LIVE value differs from its default");
    assert(*byName(snap, "useAlpha").bptr == false,
        "fixture precondition: useAlpha's LIVE value differs from its default");

    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    foreach (ref p; snap) if (!p.readonly_) pj[p.name] = paramToJson(p);

    img.imageRef().colorspace = "(default)";
    img.imageRef().useAlpha  = true;
    auto sink = prov.params();
    injectParamsInto(sink, pj);
    assert(img.imageRef().colorspace == "sRGB",
        "colorspace round-trips a NON-DEFAULT value through paramToJson/injectParamsInto");
    assert(img.imageRef().useAlpha == false,
        "useAlpha round-trips a NON-DEFAULT value through paramToJson/injectParamsInto");

    // ---- Enum kind rejects an unknown tag; discriminates vs. a String impl --
    // If `colorspace` were declared `Param.string_` (the measured reference
    // type — plan divergence 4), this inject would NOT throw: it is
    // specifically `Param.Kind.Enum`'s validation in `injectParamsInto`
    // (params.d) that rejects an unrecognised tag.
    auto sink2 = prov.params();
    JSONValue bad = JSONValue(cast(JSONValue[string]) null);
    bad["colorspace"] = JSONValue("not-a-real-tag");
    bool threw = false;
    try { injectParamsInto(sink2, bad); }
    catch (Exception) { threw = true; }
    assert(threw, "an unknown colorspace tag must be rejected by injectParamsInto");

    // ---- filename is exposed for READING even though it is not authored
    //      through this generic path (the `visible` precedent) -------------
    auto ps3 = prov.params();
    assert(paramToJson(*byName(ps3, "filename")).str == "changed/path.png",
        "filename remains READABLE through the generic param path");
}

// ---------------------------------------------------------------------------
// Task 0612 Stage 2 — the image plane's channel bundle.
//
// A plane is `hasXform == true`, so it gets the 12 transform components too:
// 12 + 10 channels + name/visible = 24. That total is the discriminator for
// the two shapes this could have been got wrong in — a bundle bolted onto the
// wrong `final switch` arm reads 14 (the transform-only count), and a plane
// wrongly declared `hasXform == false` reads 12.
//
// The bounds are asserted through `injectParamsInto` rather than by reading
// the hint fields, because the hints are INERT without `.enforceBounds()` and
// a test that read `p.hints.minF` would pass on a Param that clamps nothing.
// That distinction is the whole content of the guard.
// ---------------------------------------------------------------------------
unittest {
    import std.json  : JSONValue, parseJSON;
    import params    : paramToJson, injectParamsInto;
    import document  : ImagePlaneData;

    auto lyr = new Layer;
    lyr.name = "front sheet";
    lyr.kind = ItemKind.ImagePlane;
    lyr.imagePlaneRef() = new ImagePlaneData();
    auto plane = lyr.imagePlaneRef();

    auto prov = new LayerPropsProvider(lyr);
    auto ps = prov.params();
    assert(ps.length == 24,
        "12 transform + 10 plane channels + name + visible");

    Param* byName(Param[] arr, string n) {
        foreach (ref p; arr) if (p.name == n) return &p;
        return null;
    }
    foreach (n; ["projection", "showInPerspective", "pixelSize", "keepAspect",
                 "brightness", "contrast", "transparency", "invert",
                 "flipHorizontal", "smooth"])
        assert(byName(ps, n) !is null, "channel '" ~ n ~ "' is declared");
    assert(byName(ps, "pos.x") !is null,
        "a plane IS positionable — the transform bundle is present");
    assert(byName(ps, "filename") is null,
        "a plane owns no image and therefore no filename channel: its pixels "
        ~ "come through a LINK, which is not a Param at all");
    assert(byName(ps, "projection").kind == Param.Kind.Enum,
        "projection is a closed token set, not a free string");

    // pixelSize's FLOOR is enforced on the generic write path — the path a
    // `.v3d` channel block, an argstring and an HTTP `layer.attr` all take.
    // Zero is the value that matters: it collapses the plane's world extent
    // to nothing, and the quad becomes degenerate rather than merely small.
    { auto _j0 = parseJSON(`{"pixelSize": 0.0}`); injectParamsInto(ps, _j0); }
    assert(plane.pixelSize == 1e-6f,
        "a zero pixelSize is clamped to the declared floor — without "
        ~ "`.enforceBounds()` it lands as 0 and the plane has no extent");
    { auto _j1 = parseJSON(`{"pixelSize": -5.0}`); injectParamsInto(ps, _j1); }
    assert(plane.pixelSize == 1e-6f, "and so is a negative one");
    { auto _j2 = parseJSON(`{"pixelSize": 1e9}`); injectParamsInto(ps, _j2); }
    assert(plane.pixelSize == 1e3f, "and the ceiling holds at the other end");
    { auto _j3 = parseJSON(`{"pixelSize": 0.004}`); injectParamsInto(ps, _j3); }
    assert(plane.pixelSize == 0.004f,
        "a value INSIDE the range is written through untouched — a clamp that "
        ~ "always fired would pass every assertion above");

    // The three look scalars are bounded too, each at its own range: the
    // signed pair at -1..1 and transparency at 0..1. Asserting all three with
    // the SAME out-of-range input is what separates them — a copy-paste that
    // gave transparency the signed range reads -1 for the third.
    { auto _j4 = parseJSON(`{"brightness": -9.0, "contrast": -9.0, "transparency": -9.0}`); injectParamsInto(ps, _j4); }
    assert(plane.brightness == -1.0f && plane.contrast == -1.0f,
        "brightness and contrast floor at -1");
    assert(plane.transparency == 0.0f,
        "transparency floors at 0 — it is a fraction of invisibility, and a "
        ~ "negative one has no meaning");

    // The enum REJECTS an unknown tag rather than writing it. This is the one
    // channel where a silent accept would be invisible: an unknown projection
    // would resolve to no viewport at all and the plane would simply never
    // appear, with nothing to read that says why.
    bool threw = false;
    try { auto _j5 = parseJSON(`{"projection": "diagonal"}`); injectParamsInto(ps, _j5); }
    catch (Exception) threw = true;
    assert(threw, "an unknown projection tag is refused");
    assert(plane.projection == "front", "and the channel keeps its value");
    { auto _j6 = parseJSON(`{"projection": "right"}`); injectParamsInto(ps, _j6); }
    assert(plane.projection == "right", "a known tag is written");
}

// A plane layer whose payload has not been constructed yet falls back to the
// base bundle instead of dereferencing a null. Same contract, same reason, as
// the image kind's null-payload case: `params()` is a per-frame query and is
// not the place to construct a payload as a side effect.
unittest {
    auto lyr = new Layer;
    lyr.kind = ItemKind.ImagePlane;
    auto ps = (new LayerPropsProvider(lyr)).params();
    assert(ps.length == 14,
        "12 transform + name + visible — the plane channels need a payload to "
        ~ "point at, and there is none");
}
