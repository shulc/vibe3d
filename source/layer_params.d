module layer_params;

import params   : Param, ParamProvider, MixedValueProvider, paramToJson;
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

final class LayerPropsProvider : ParamProvider, MixedValueProvider {
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
    /// resource kind this chain adds (the reference-image item, task 0612 —
    /// ~~not yet written~~ **written, and it is the `ItemKind.ImagePlane`
    /// arm below**) needs a THIRD bundle that fits neither `hasXform`'s
    /// nor an image-shaped bit. That prediction is now a measured fact
    /// rather than a forecast: the plane's ten channels share no capability
    /// with the image kind's three, and the `final switch` is what made the
    /// omission impossible to ship. Dispatch is an explicit `final switch
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

    // -----------------------------------------------------------------------
    // MixedValueProvider — TASK 1880, gang edit
    // -----------------------------------------------------------------------

    /// The OTHER subjects this provider stands for, beside `layer_`.
    ///
    /// Snapshots of their `params()`, not the layers: a `Param` holds a typed
    /// POINTER into its layer's fields and `Layer` is a class (stable heap
    /// address by design — see document.d), so a snapshot taken once stays
    /// live for the whole frame and re-reads the current value on every probe.
    /// Taking it once is the point: `params()` allocates a fresh array per
    /// call, and asking it per row per target would rebuild it ~20 x N times a
    /// frame for a panel that needs it N.
    private Param[][] gangSnapshots_;

    /// Bind the gang-edit subject set — every OTHER item the edit applies to.
    ///
    /// Called once per frame by the panel with the item selection minus the
    /// focus. Passing an empty array (or never calling this) leaves the
    /// provider single-subject, which is the pre-1880 behaviour exactly:
    /// `paramMixed` then answers false for everything and no widget changes.
    ///
    /// KIND FILTERING IS THE CALLER'S. The reference gang-edits "multiple
    /// layer selections of identical item types", and the panel is the layer
    /// that knows the focus's kind; doing it here would duplicate that rule in
    /// a second place and let the two drift.
    void setGangTargets(Layer[] others) {
        if (others.length == 0) { gangSnapshots_.length = 0; return; }
        gangSnapshots_.length = others.length;
        foreach (i, o; others)
            gangSnapshots_[i] = (o is null) ? null
                              : (new LayerPropsProvider(o)).params();
    }

    /// True when the subjects disagree on `name`.
    ///
    /// Compared through `paramToJson`, which is the same boxing the read-back
    /// query and the `.v3d` codec already use — so "these two agree" means the
    /// same thing here as it does everywhere else that reads a layer param,
    /// rather than being a fourth notion of equality.
    ///
    /// A target that does not EXPOSE `name` counts as agreeing. The row is
    /// only drawn because the focus exposes it, and a kind that lacks the
    /// channel entirely has no value to disagree with; reporting mixed there
    /// would put a placeholder on a row whose only real subject is the focus.
    bool paramMixed(string name) {
        if (gangSnapshots_.length == 0) return false;
        auto mine = params();
        const(Param)* self;
        foreach (ref p; mine) if (p.name == name) { self = &p; break; }
        if (self is null) return false;
        auto want = paramToJson(*self);
        foreach (ref snap; gangSnapshots_) {
            foreach (ref p; snap) {
                if (p.name != name) continue;
                if (paramToJson(p) != want) return true;
                break;
            }
        }
        return false;
    }
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
/// TASK 0612 STAGE 8 — this rule was PROMOTED, not copied. It now lives on
/// `Document.itemTransformTarget()` and this function delegates, because the
/// gizmo centre (`actcenter.d`), the item basis (`axis.d`) and the moving set
/// (`registration.d`) needed the same answer and were reading
/// `document.primary` instead. Panel and gizmo showing the same thing is a
/// property task 0614 shipped; keeping a second copy of the rule here is how
/// it would have stopped being true. The doc comment above still describes the
/// rule — the implementation is one call away.
Layer itemPropsTarget(Document* doc) {
    if (doc is null) return null;
    return doc.itemTransformTarget();
}

/// Every attr a layer can expose, across EVERY item kind — the union, in
/// first-seen order.
///
/// This is the static universe `forms.validateForms` fences the layer-props
/// form against at boot, and it has to be the UNION because ONE form serves
/// every kind: its per-kind section names channels that only a plane's
/// provider returns, and those rows are hidden (not erroneous) for a mesh.
///
/// Why it exists at all: a `layer.attr` control row whose attr is misspelt
/// fails SILENTLY. It resolves `found == false` on every snapshot, the row is
/// never planned, and the panel looks exactly as it does when the channel has
/// no row — which is the precise defect the per-kind section was added to
/// correct. Tool and stage bindings have had this boot fence since the forms
/// engine's Phase 3; the layer namespace was the one that never got it.
///
/// Built by asking a real provider, one kind at a time, rather than by listing
/// names: a list would be a second declaration of the param set and would drift
/// from `params()` the first time a bundle changed. The `final switch` is the
/// forcing function — a new `ItemKind` is a COMPILE ERROR here until someone
/// decides whether it carries a payload, so a kind cannot be added with its
/// channels silently outside the universe.
string[] layerAttrUniverse()
{
    import document   : ImageData, ImagePlaneData;
    import std.traits : EnumMembers;

    string[] names;
    bool[string] seen;
    foreach (k; [EnumMembers!ItemKind]) {
        auto l = new Layer;
        l.kind = k;
        // Construct the payload a kind's bundle binds its pointers into —
        // without it `params()` takes its documented null-payload fallback and
        // that kind contributes nothing but the base bundle.
        final switch (k) {
            case ItemKind.Mesh:
            case ItemKind.Empty:
                break;                                        // payload-less
            case ItemKind.Image:
                l.imageRef() = new ImageData();
                break;
            case ItemKind.ImagePlane:
                l.imagePlaneRef() = new ImagePlaneData();
                break;
        }
        foreach (ref p; (new LayerPropsProvider(l)).params())
            if (p.name !in seen) { seen[p.name] = true; names ~= p.name; }
    }
    return names;
}





// ---------------------------------------------------------------------------
// In-module unit test (P0.4): the 14 expected names/kinds, the pointers alias
// the layer fields (mutating the param value changes the layer and vice-versa),
// and a round-trip through paramToJson → injectParamsInto restores values.
// ---------------------------------------------------------------------------


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
