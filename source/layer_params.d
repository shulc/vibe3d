module layer_params;

import params   : Param, ParamProvider;
import document : Layer, kindInfo, ItemXform, MIN_ITEM_SCALE_MAG,
                  MAX_ITEM_SCALE_MAG, sanitizeItemXform;
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
    // ALWAYS binds the PRIMARY layer — the one the gizmo is operating on. Authoring
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

    /// The layer params: `name` + `visible`, plus — for a kind that
    /// `hasXform` (task 0616 Stage 2) — the 12 transform-component Floats.
    /// Pointers alias the live `Layer` fields, so a write through a param's
    /// pointer mutates the layer (and vice-versa).
    ///
    /// The transform bundle is gated on `kindInfo(layer_.kind).hasXform`
    /// (task 0616 Stage 2, resolving the forcing `static assert` at
    /// `document.d`'s `kItemKindTable`): an item with no transform
    /// capability — the measured image item has none — must not expose
    /// `pos.*`/`rot.*`/`scl.*`/`pivot.*` params it has no field backing that
    /// is ever meaningfully read. This is also what makes `layer.attr <img>
    /// pos.x 5` fail as an UNKNOWN attribute rather than silently succeed:
    /// `LayerAttr` resolves attr names against exactly this list
    /// (`commands/layer/commands.d`), so omitting the params here is both
    /// the "get" and the "set" gate the forcing assert asked for — there is
    /// no separate write path to close.
    ///
    /// This is a per-kind BUNDLE gate, not the full per-kind channel split —
    /// the image kind's own attributes (its path and colour handling) arrive
    /// in a later stage; see the plan for the list. For now an image-kind
    /// layer's provider exposes only `name`/`visible`.
    Param[] params() {
        // NIT (review round 4): appending two array LITERALS (`result ~=
        // [...]` twice) allocates the literal itself, then again on the
        // append — up to four allocations a frame for what the module intro
        // (line 16-ish, "one declaration") calls a per-frame snapshot.
        // `reserve()` once up front, then append each `Param` individually
        // (`~=` under a held capacity is amortized in-place, no further
        // allocation) — one allocation total, matching every other
        // steady-state-allocation-free path in this codebase.
        immutable bool hasXform = kindInfo(layer_.kind).hasXform;
        Param[] result;
        result.reserve(hasXform ? 14 : 2);
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
