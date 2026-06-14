module layer_params;

import params   : Param, ParamProvider;
import document : Layer;

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

    /// P4: set the primary-transform interlock (see `transformGuard_`). The app's
    /// panel hook computes "an active tool is a transform tool" each frame and
    /// sets this before `draw`, so the transform rows grey out only while a
    /// transform gesture could be desynced — and re-enable when the tool drops.
    void setTransformGuard(bool on) { transformGuard_ = on; }

    // -----------------------------------------------------------------------
    // ParamProvider
    // -----------------------------------------------------------------------

    /// The 14 layer params: 12 transform-component Floats + name + visible.
    /// Pointers alias the live `Layer` fields, so a write through a param's
    /// pointer mutates the layer (and vice-versa).
    Param[] params() {
        return [
            // Position (world translation).
            Param.float_("pos.x",   "Pos X",   &layer_.xform.pos.x,   0.0f),
            Param.float_("pos.y",   "Pos Y",   &layer_.xform.pos.y,   0.0f),
            Param.float_("pos.z",   "Pos Z",   &layer_.xform.pos.z,   0.0f),
            // Rotation (euler degrees, ZYX) — angle hint for coarser drag step.
            Param.float_("rot.x",   "Rot X",   &layer_.xform.rot.x,   0.0f).angle(),
            Param.float_("rot.y",   "Rot Y",   &layer_.xform.rot.y,   0.0f).angle(),
            Param.float_("rot.z",   "Rot Z",   &layer_.xform.rot.z,   0.0f).angle(),
            // Scale (per-axis; default 1).
            Param.float_("scl.x",   "Scale X", &layer_.xform.scl.x,   1.0f),
            Param.float_("scl.y",   "Scale Y", &layer_.xform.scl.y,   1.0f),
            Param.float_("scl.z",   "Scale Z", &layer_.xform.scl.z,   1.0f),
            // Pivot (rotation/scale center).
            Param.float_("pivot.x", "Pivot X", &layer_.xform.pivot.x, 0.0f),
            Param.float_("pivot.y", "Pivot Y", &layer_.xform.pivot.y, 0.0f),
            Param.float_("pivot.z", "Pivot Z", &layer_.xform.pivot.z, 0.0f),
            // Bespoke layer props.
            //
            // `name` rides the GENERIC registry end-to-end: it is a plain String
            // param here, a form text row, and writable via `layer.attr 0 name
            // <new>` (UI-undoable + coalescing) — the "one declaration" proof
            // (Phase 5). `layer.rename` is kept as the explicit rename path, but
            // `name` ALSO participates in the same forms/undo/serialize machinery
            // as every transform component. (It always round-tripped through the
            // `.v3d` layer envelope; see io/native.d + test_v3d_layers.d.)
            Param.string_("name",    "Name",    &layer_.name,    ""),
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
            Param.bool_  ("visible", "Visible", &layer_.visible, true),
        ];
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
