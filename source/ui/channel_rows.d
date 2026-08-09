module ui.channel_rows;

// ---------------------------------------------------------------------------
// Task 0637 — the Channels panel's ROW MODEL.
//
// WHY THIS MODULE EXISTS AT ALL, and it is not a style preference: task 0612
// shipped ten image-plane channels that are declared as `Param`s, work through
// `layer.attr` in both directions, and were reachable from NO user interface,
// because the properties form draws only the rows its YAML file names
// (`config/forms/layer_props.yaml` — thirteen rows against a plane's
// twenty-four params). The assertion that caught nothing for the whole life of
// that hole was "the param is declared": it was true the entire time. So the
// thing this panel must be testable ON is not "is the channel declared" but
// "does a ROW exist for it, and does the renderer's own resolver find a widget
// for that row" — which is what this module makes observable.
//
// The split follows `ui/image_rows.d` exactly:
//
//   * this module answers "WHAT rows would the panel draw" — pure, no ImGui,
//     no globals, the `Document*` is a PARAMETER — and is fully assertable by
//     the in-module tests at the bottom;
//   * `ui/panels.d`'s `drawChannelsPanel` answers "where on screen", which is
//     the part no test here claims to cover.
//
// THE ROWS ARE `forms.Row`, not a private struct of our own. That is the load-
// bearing choice: the panel hands this exact `Form` to the SAME `FormsPanel`
// that renders the properties form, so a row here is drawn by the same
// resolver, the same widgets and the same `layer.attr` write path as a row
// authored in YAML — there is no second renderer to drift. The only difference
// between the two surfaces is where the row list comes from: YAML there, the
// live `params()` here. That is the whole feature.
//
// WHAT THE REFERENCE'S SURFACE HAS THAT THIS DOES NOT, and why each is absent
// rather than unfinished:
//
//   * NO tab strip is built here. A dockable window docked into an occupied
//     node becomes a tab by itself (`app.d`'s `DockBuilderDockWindow` calls
//     put four windows in one node already), so Properties-beside-Channels is
//     the user's layout, not our widget. This also keeps us clear of the fact
//     that this build's ImGui binding exposes no `BeginTabBar` (`app.d`).
//   * NO placeholder rows for channels that do not exist yet, and NO trailing
//     "add channel" row. We have no user channels and no channel creation, so
//     both would be ornaments with nothing behind them.
//   * NO per-channel state/source columns. In the reference those report which
//     authoring context wrote a value and whether a driver is attached; we have
//     exactly one authoring context and no drivers, so every row would carry
//     the same word or none. What the group HEADINGS below carry instead is the
//     distinction we really do have and the one this task is about: a shared
//     channel versus a channel that exists only on this kind of item.
//   * NO units in the displayed value. `Param` has no unit metadata (only a
//     `fmt` hint), so a "%" or a "mm" would be invented here and would disagree
//     with `layer.attr`, with the `.v3d` file and with the properties form,
//     which all speak the raw number.
//   * NO name filter. The largest item in the document today has 24 channels;
//     a filter over 24 rows is chrome, and the reference's channels panel was
//     never measured for one (its clip list has none — that IS measured).
//
// COST. `channelsModel` allocates: it builds a provider, a `params()` snapshot
// and one command string per row. It is therefore NOT a per-frame call — the
// panel memoises it on the model's own `key` (see `ChannelsModel.key`) and
// rebuilds only when the bound item, its index or its param count changes.
// Values are NOT baked into the rows: the renderer reads them live from the
// provider each frame, which is what makes the memo sound.
// ---------------------------------------------------------------------------

import document     : Document, Layer, ItemKind, kindInfo;
import layer_params : LayerPropsProvider, itemPropsTarget;
import params       : Param, ParamProvider;
import forms        : Form, Row, RowKind, WidgetKind, widgetForKind;

import std.algorithm : startsWith;
import std.conv      : to;

// ---------------------------------------------------------------------------
// Group headings
// ---------------------------------------------------------------------------

/// The three sections a channel can land in. Emitted in this order.
enum ChannelGroup {
    item,       ///< shared by every kind of item
    transform,  ///< the per-component item transform
    kind,       ///< exists only because the item is THIS kind
}

/// Heading text for the two fixed groups. The third's heading is the item
/// kind's own display word (`kindHeading`).
enum string kItemHeading      = "Item";
enum string kTransformHeading = "Transform";

/// The shared channels — the ones every kind carries (`layer_params.d` emits
/// them for every kind unconditionally).
private static immutable string[] kSharedChannels = ["name", "visible"];

/// The transform components' name prefixes. Same four `paramEnabled` uses for
/// its interlock (`layer_params.d`), and for the same reason: the per-component
/// transform scalars are identified by their dotted prefix, nothing else.
private static immutable string[] kTransformPrefixes =
    ["pos.", "rot.", "scl.", "pivot."];

/// Which section `attr` belongs to.
///
/// TOTAL BY CONSTRUCTION: anything that is neither a transform component nor a
/// known shared channel is a KIND channel. That default is the safe direction —
/// a channel this classifier has never heard of is still shown, merely under a
/// heading that may be slightly generous. It can never be dropped, which is the
/// one property the whole panel exists to guarantee (and which the totality
/// test below pins across every kind).
ChannelGroup channelGroupOf(string attr) pure
{
    foreach (pfx; kTransformPrefixes)
        if (attr.startsWith(pfx)) return ChannelGroup.transform;
    foreach (n; kSharedChannels)
        if (attr == n) return ChannelGroup.item;
    return ChannelGroup.kind;
}

/// The heading a kind's own channel section carries. A `final switch`, so a
/// future `ItemKind` is a COMPILE ERROR here rather than an unlabelled
/// section — the same forcing-function shape `layer_params.params()` uses for
/// the bundle itself.
///
/// No kind's word may equal `kItemHeading` or `kTransformHeading`, or a kind
/// that grows a channel would print two sections under one name and the reader
/// could not tell "every item has this" from "only this kind does" — which is
/// the single distinction these headings exist to carry. Unreachable today (the
/// two kinds with no bundle emit no heading at all), so it is pinned by the test
/// at the bottom rather than left as a comment somebody has to remember.
string kindHeading(ItemKind k) pure
{
    final switch (k) {
        case ItemKind.Mesh:       return "Mesh";
        case ItemKind.Empty:      return "Empty";
        case ItemKind.Image:      return "Image";
        case ItemKind.ImagePlane: return "Image Plane";
    }
}

// ---------------------------------------------------------------------------
// Write policy
// ---------------------------------------------------------------------------

/// True when a generic `layer.attr` write is the RIGHT write for `attr`.
///
/// One exception, and it is the same one the properties form documents:
/// `visible` carries an invariant side effect — hiding the primary must promote
/// another selected+visible item to primary — which lives in the dedicated
/// `layer.setVisible` command. `layer.attr <n> visible false` would land the
/// value and skip the promotion, stranding a hidden edit target. So the row is
/// SHOWN (the value is worth reading, and the reference shows its equivalent
/// too) but greyed here; the Layers panel's per-row "V" checkbox is the
/// writable surface and is already reachable, so nothing becomes unreachable by
/// greying it.
///
/// Deliberately NOT extended into a general "some channels are special" list:
/// every other layer property rides the generic param path, and a second entry
/// here should be argued on its own invariant, not added by analogy.
bool channelWritesThroughLayerAttr(string attr) pure
{
    return attr != "visible";
}

/// True when the forms renderer would actually put a widget on screen for `p`.
///
/// Two ways a param has no widget: it is hidden, or its `Param.Kind` maps to
/// `WidgetKind.none` (the array kinds, which carry parallel index/before/after
/// payloads for headless commands and are not a single editable value). A row
/// emitted for either would resolve to nothing and draw nothing — a model that
/// claimed such a row would be lying about what is on screen, which is the
/// exact failure mode this whole module is built to prevent. So the model does
/// not emit them.
///
/// `widgetForKind` is the RENDERER'S OWN function (`forms.d`), not a copy of
/// its rules: if the renderer learns to draw a kind, this admits it in the same
/// commit.
bool channelIsRenderable(const ref Param p)
{
    if (p.hidden_) return false;
    return widgetForKind(p.kind, p.hints) != WidgetKind.none;
}

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// What the panel draws for one bound item.
struct ChannelsModel {
    /// False when there is no item to show (an empty document). The panel then
    /// draws its empty line and nothing else.
    bool bound;

    /// The bound item's display name — the panel's header line.
    string title;
    /// Its kind's display word, shown beside the name.
    string kindText;
    /// Its index in `document.layers` — the index every row's `layer.attr`
    /// addresses. Held separately so a test can read it without re-parsing a
    /// command line.
    size_t index;

    /// The rows, in the shape the shared `FormsPanel` renders.
    Form form;

    /// Control rows only (headings and dividers excluded) — i.e. how many
    /// channels this panel is actually offering.
    size_t channelCount;

    /// Memo key: rebuild when this changes. Item identity covers a selection
    /// move, the index covers a reorder/delete under a stable item, and the
    /// param count covers a payload appearing on an item that had none.
    /// Values are read live by the renderer, so they are deliberately NOT part
    /// of the key.
    ChannelsKey key;
}

/// See `ChannelsModel.key`.
struct ChannelsKey {
    Layer  item;
    size_t index;
    size_t paramCount;
}

/// The empty-state line. The panel has its own text rather than an empty
/// rectangle, the same call `ui/image_rows.d` made.
enum string kNoItemText = "(no item selected)";

/// Build the row list for a live `params()` snapshot.
///
/// The pure core, taking a snapshot rather than a `Document` so a test can feed
/// it a param list no `Layer` can currently produce (an array-kind param, a
/// hidden one) and assert what the model does with it.
///
/// `idxToken` is the layer index the write lines address, already stringified.
/// It is baked into the line here rather than left as a placeholder for
/// `forms.rebindBindingTarget` to overwrite: this form is SYNTHESISED per bound
/// item, so the live index is known at build time and there is nothing for a
/// rebind to fix. (`FormsPanel.draw` is therefore passed an empty `layerIndex`,
/// which leaves these literals alone.)
Form channelsFormFor(Param[] ps, string idxToken, string kindHeadingText)
{
    Form f;
    f.id        = "channels";
    f.label     = "";
    f.showLabel = false;

    // One pass per group, in `ChannelGroup` order, so the sections come out
    // stable regardless of the order `params()` happens to emit in.
    static immutable ChannelGroup[3] order =
        [ChannelGroup.item, ChannelGroup.transform, ChannelGroup.kind];

    bool anyEmitted = false;
    foreach (g; order) {
        Row[] rows;
        foreach (ref p; ps) {
            if (!channelIsRenderable(p))     continue;
            if (channelGroupOf(p.name) != g) continue;
            // A control row's binding line: the generic attr write, with the
            // value slot left as the `?` the forms engine substitutes.
            immutable string line =
                "layer.attr " ~ idxToken ~ " " ~ p.name ~ " ?";
            // The control id is the ATTR, not the row ordinal: a row's identity
            // must survive a section growing above it, or the renderer's
            // per-control edit scratch follows the wrong row when a payload
            // appears mid-edit.
            rows ~= Row.makeControl(line, p.label, "chan." ~ p.name);
        }
        if (rows.length == 0) continue;   // no heading for an empty section

        if (anyEmitted) f.rows ~= Row.makeDivider();
        final switch (g) {
            case ChannelGroup.item:      f.rows ~= Row.makeLabel(kItemHeading);      break;
            case ChannelGroup.transform: f.rows ~= Row.makeLabel(kTransformHeading); break;
            case ChannelGroup.kind:      f.rows ~= Row.makeLabel(kindHeadingText);   break;
        }
        f.rows ~= rows;
        anyEmitted = true;
    }
    return f;
}

/// The whole model for the item the panel binds.
///
/// BINDS THE ITEM-SELECTION FOCUS, through `itemPropsTarget` — never
/// `document.primary`. `primary` is by invariant a `canBePrimary` item, i.e.
/// always a mesh, so a panel bound to it could not show an image plane's
/// channels AT ALL and this task would close nothing. This is the same rule the
/// properties form follows (`layer_params.d`), reached through the same
/// function so the two surfaces cannot disagree about which item is being
/// edited.
ChannelsModel channelsModel(Document* doc)
{
    ChannelsModel m;
    if (doc is null || doc.layers.length == 0) return m;

    auto item = itemPropsTarget(doc);
    if (item is null) return m;

    auto prov = new LayerPropsProvider(item);
    auto ps   = prov.params();

    m.bound    = true;
    m.title    = item.name.length ? item.name : "(unnamed)";
    m.kindText = kindHeading(item.kind);
    m.index    = doc.indexOf(item);
    m.form     = channelsFormFor(ps, m.index.to!string, m.kindText);
    m.key      = ChannelsKey(item, m.index, ps.length);

    foreach (ref r; m.form.rows)
        if (r.kind == RowKind.control) m.channelCount++;

    return m;
}

// ---------------------------------------------------------------------------
// ChannelsProvider — the provider the panel hands the renderer.
//
// A thin decorator over `LayerPropsProvider` that answers ONE extra question:
// which rows are greyed. Two reasons a channel row is not editable here, and
// both are per-PARAM facts the base provider's `paramEnabled` (a per-NAME
// interlock about transform gestures) does not cover:
//
//   * `Param.readonly_` — the layer set has exactly one, the image item's
//     `filename`. `layer.attr` REFUSES a write to it (commands/layer/
//     commands.d), so an editable-looking widget would throw a command error on
//     every keystroke. Greyed, value still legible: that is what "read-only"
//     should look like, and it matches the reference's greyed derived rows.
//   * `channelWritesThroughLayerAttr` — `visible`, for the promotion invariant
//     documented at that function.
//
// WHY A DECORATOR rather than teaching `forms_render.drawControl` about
// `readonly_`: the renderer is shared with every tool and stage form, and this
// is a rule about what THIS panel offers, not about what a readonly param means
// everywhere. (`PropertyPanel.drawProvider` does apply the readonly rule
// engine-wide; that the forms renderer does not is a pre-existing gap, inert
// today because no YAML form binds a readonly param — out of scope here rather
// than fixed silently as a side effect.)
//
// The blocked set is computed once per REBIND, not per query: `params()`
// rebuilds its array on every call, so scanning it inside `paramEnabled` would
// allocate once per row per frame.
// ---------------------------------------------------------------------------

final class ChannelsProvider : ParamProvider {
    private LayerPropsProvider base_;
    private bool[string]       blocked_;

    this(Layer l) { base_ = new LayerPropsProvider(l); rebuildBlocked(); }

    /// Re-point at another item and recompute the blocked set. Called on a memo
    /// miss only (see `ChannelsModel.key`).
    void rebind(Layer l) { base_.setLayer(l); rebuildBlocked(); }

    /// The wrapped provider, for the caller that must drive the base's own
    /// per-frame interlock (`setTransformGuard`).
    LayerPropsProvider base() { return base_; }

    private void rebuildBlocked()
    {
        blocked_ = null;
        foreach (ref p; base_.params()) {
            if (p.readonly_ || !channelWritesThroughLayerAttr(p.name))
                blocked_[p.name] = true;
        }
    }

    Param[] params() { return base_.params(); }

    bool paramEnabled(string name) const
    {
        if ((name in blocked_) !is null) return false;
        return base_.paramEnabled(name);
    }

    void onParamChanged(string name) { base_.onParamChanged(name); }
}

// ===========================================================================
// Tests
// ===========================================================================

// ---------------------------------------------------------------------------
// THE TEST THIS TASK IS FOR: a row exists for every one of the plane's ten
// channels, and the RENDERER'S OWN resolver finds a widget for each.
//
// "Declared" and "rendered" are different assertions and only the second one
// could have caught task 0612's hole. `layer_params.d` already asserts the ten
// params exist — that assertion passed for the entire life of the gap, because
// the surface drawing them (`config/forms/layer_props.yaml`, thirteen rows)
// never mentioned them. So this test asserts the two things a param needs in
// order to appear on screen:
//
//   1. a ROW exists whose binding line names it, and
//   2. `forms.resolveControl` — the function `drawControl` itself calls, before
//      it draws anything — reports `found` and a real `WidgetKind` for that row
//      against the live provider.
//
// Everything after (2) is the ImGui call, which no headless test can observe;
// that part was checked by eye and is recorded as not automated.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: `channelsModel` binding
// `doc.primary` instead of `itemPropsTarget(doc)` — the single most plausible
// wrong line, because it is what this codebase's item-bound surfaces did until
// task 0616 corrected them one at a time, and because on an all-mesh document
// the two are the same object so nothing else complains. OBSERVED RED, at the
// FIRST assertion to speak (D aborts a module at its first `AssertError`):
// "the panel headers the FOCUSED item; bound to the primary it would read
// 'the mesh'". Behind it, unreached but real: the addressed index is 0 rather
// than 1, every plane row is absent, and `channelCount` reads 14, not 24.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ImagePlaneData;
    import mesh     : makeCube;
    import seltype  : SelMode;
    import forms    : resolveControl;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "the mesh";

    auto plane = new Layer;
    plane.name = "the plane";
    plane.kind = ItemKind.ImagePlane;
    plane.imagePlaneRef() = new ImagePlaneData();
    doc.layers ~= plane;
    doc.selectItem(plane, SelMode.Set);

    // Vacuity guard: the focus and the primary must really be different
    // objects here, or "binds the focus" is not being tested at all.
    assert(doc.primary is doc.layers[0] && doc.focusedItem is plane,
        "fixture: a plane can never be primary, so focus != primary");

    auto m = channelsModel(&doc);
    assert(m.bound, "an item is bound");
    assert(m.title == "the plane",
        "the panel headers the FOCUSED item; bound to the primary it would "
        ~ "read '" ~ doc.primary.name ~ "'");
    assert(m.index == 1,
        "…and addresses its index; the primary's is 0 — every row's write "
        ~ "would land on the wrong item");

    // ---- a ROW exists for each channel, and it RESOLVES to a widget --------
    auto ps = (new LayerPropsProvider(plane)).params();
    Row* rowFor(string attr) {
        foreach (ref r; m.form.rows)
            if (r.kind == RowKind.control && r.id == "chan." ~ attr) return &r;
        return null;
    }

    static immutable string[] planeChannels = [
        "projection", "showInPerspective", "pixelSize", "keepAspect",
        "brightness", "contrast", "transparency", "invert",
        "flipHorizontal", "smooth",
    ];
    foreach (attr; planeChannels) {
        auto r = rowFor(attr);
        assert(r !is null,
            "no ROW for the plane channel '" ~ attr ~ "' — this is exactly "
            ~ "the shape of task 0612's hole: the param is declared and "
            ~ "nothing draws it");
        assert(r.command == "layer.attr 1 " ~ attr ~ " ?",
            "the row's write line must address layer 1's '" ~ attr
            ~ "'; read '" ~ r.command ~ "'");
        auto rc = resolveControl(*r, ps);
        assert(rc.found,
            "the renderer's own resolver does not find '" ~ attr ~ "' — the "
            ~ "row would be skipped before a widget is drawn");
        assert(rc.widget != WidgetKind.none,
            "'" ~ attr ~ "' resolves to no widget — the row draws nothing");
    }

    // The transform and the shared channels are there TOO: this panel is
    // exhaustive, so nothing may be lost by adding the kind bundle.
    foreach (attr; ["pos.x", "rot.y", "scl.z", "pivot.x", "name", "visible"]) {
        auto r = rowFor(attr);
        assert(r !is null, "'" ~ attr ~ "' has no row");
        assert(resolveControl(*r, ps).found, "'" ~ attr ~ "' does not resolve");
    }

    assert(m.channelCount == 24,
        "every one of the plane's params gets a row — name + visible + 12 "
        ~ "transform + 10 channels; read " ~ m.channelCount.to!string);
    assert(m.channelCount == ps.length,
        "EXHAUSTIVE is the whole point: a param with no row is a channel with "
        ~ "no surface. params() = " ~ ps.length.to!string ~ ", rows = "
        ~ m.channelCount.to!string);
}

// ---------------------------------------------------------------------------
// The other half of the task's Ph3: a MESH must not grow the plane's section,
// and its own row set must not silently inherit one.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: `channelsFormFor` emitting the
// kind heading unconditionally instead of only when the section has rows.
// OBSERVED RED: "no heading for an empty section — the form ends with a
// channel, not an empty 'Mesh' heading" — the mesh's form grew a trailing
// divider + "Mesh" label with nothing under it.
// ---------------------------------------------------------------------------
unittest {
    import document : Document;
    import mesh     : makeCube;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "just a mesh";

    auto m = channelsModel(&doc);
    assert(m.bound && m.title == "just a mesh");
    assert(m.channelCount == 14,
        "a mesh has 14 channels — 12 transform + name + visible; read "
        ~ m.channelCount.to!string);

    foreach (ref r; m.form.rows) {
        assert(r.kind != RowKind.control || !r.id.startsWith("chan.projection"),
            "a mesh must not grow the image plane's channels");
        assert(r.kind != RowKind.label || r.label != "Image Plane",
            "…nor the image plane's heading");
    }

    // No heading may be emitted for a section with no rows: a mesh has no
    // kind-specific channels, so the LAST row must be a control, never a
    // dangling label.
    assert(m.form.rows.length > 0);
    assert(m.form.rows[$ - 1].kind == RowKind.control,
        "no heading for an empty section — the form ends with a channel, not "
        ~ "an empty '" ~ m.form.rows[$ - 1].label ~ "' heading");

    // Headings that ARE earned: Item and Transform, in that order, each
    // followed by rows.
    string[] headings;
    foreach (ref r; m.form.rows)
        if (r.kind == RowKind.label) headings ~= r.label;
    assert(headings == [kItemHeading, kTransformHeading],
        "a mesh shows exactly the two earned headings");
}

// ---------------------------------------------------------------------------
// Totality: EVERY param of EVERY kind lands in a section, and the section a
// kind's own channels land in is the kind section.
//
// The property that matters is "nothing is dropped". A classifier that
// returned, say, a fourth unhandled group for an unrecognised name would lose
// the row silently — which is the failure this whole panel exists to prevent,
// wearing a different hat.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: `channelGroupOf` returning
// `ChannelGroup.item` for an unknown attr instead of `.kind`. OBSERVED RED:
// "'projection' is a channel only an image plane has…", reading group `item`
// — the plane's ten channels file under the shared "Item" heading. Note what
// does NOT fire: the totality assertion above stays green, because a
// misfiled channel is still DRAWN. That is the intended division of labour
// between the two halves of this test, and the reason the group assertions
// are here rather than trusted to the count.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ImageData, ImagePlaneData;
    import mesh     : makeCube;

    static Layer mk(ItemKind k, string n) {
        auto l = new Layer;
        l.kind = k;
        l.name = n;
        if (k == ItemKind.Mesh)       l.meshRef()       = makeCube();
        if (k == ItemKind.Image)      l.imageRef()      = new ImageData();
        if (k == ItemKind.ImagePlane) l.imagePlaneRef() = new ImagePlaneData();
        return l;
    }

    foreach (k; [ItemKind.Mesh, ItemKind.Empty, ItemKind.Image,
                 ItemKind.ImagePlane]) {
        auto l  = mk(k, "x");
        auto ps = (new LayerPropsProvider(l)).params();
        auto f  = channelsFormFor(ps, "0", kindHeading(k));

        size_t controls = 0;
        foreach (ref r; f.rows) if (r.kind == RowKind.control) controls++;
        assert(controls == ps.length,
            "kind " ~ k.to!string ~ ": every param must get a row — params "
            ~ ps.length.to!string ~ ", rows " ~ controls.to!string);
    }

    // …and the kind bundle really is filed as a KIND channel, not folded into
    // the shared section.
    assert(channelGroupOf("projection") == ChannelGroup.kind,
        "'projection' is a channel only an image plane has — filing it as "
        ~ "shared would show it under a heading claiming every item has it");
    assert(channelGroupOf("colorspace") == ChannelGroup.kind,
        "'colorspace' likewise belongs to the image kind alone");
    assert(channelGroupOf("name")    == ChannelGroup.item,
        "'name' is carried by every kind");
    assert(channelGroupOf("visible") == ChannelGroup.item,
        "'visible' is carried by every kind");
    assert(channelGroupOf("pos.x")   == ChannelGroup.transform,
        "a dotted transform component files under Transform");
    assert(channelGroupOf("pivot.z") == ChannelGroup.transform,
        "…including the longest prefix, 'pivot.'");

    // No kind's heading may collide with a fixed one (see `kindHeading`).
    // Unreachable today — `Mesh` and `Empty` carry no bundle, so their word is
    // never printed — which is exactly why it is asserted here instead of being
    // left to whoever adds the first mesh-only channel.
    foreach (k; [ItemKind.Mesh, ItemKind.Empty, ItemKind.Image,
                 ItemKind.ImagePlane]) {
        immutable h = kindHeading(k);
        assert(h != kItemHeading && h != kTransformHeading,
            "kind " ~ k.to!string ~ "'s heading is '" ~ h ~ "', which collides "
            ~ "with a fixed section — a reader could not tell a shared channel "
            ~ "from one only this kind has");
    }
}

// ---------------------------------------------------------------------------
// A param with no widget gets NO row.
//
// A model that claimed a row the renderer draws nothing for would be lying in
// the one direction this module is built to prevent. No `Layer` can produce an
// array-kind param today, which is exactly why the pure core takes a `Param[]`
// rather than a `Document` — the case is unreachable through the live provider
// and would otherwise be untestable.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: `channelIsRenderable` returning
// true unconditionally. OBSERVED RED: the row count reads 3 instead of 1 and
// the first assertion fires — the array param and the hidden param both get
// rows that resolve to `WidgetKind.none` and draw nothing.
// ---------------------------------------------------------------------------
unittest {
    import forms : resolveControl;

    float  f;
    uint[] idx;
    bool   b;

    Param[] ps = [
        Param.float_("real", "Real", &f, 0.0f),
        Param.intArray_("indices", "Indices", &idx),
        Param.bool_("secret", "Secret", &b, false).hidden(),
    ];

    auto form = channelsFormFor(ps, "7", "Kind");
    size_t controls = 0;
    foreach (ref r; form.rows) if (r.kind == RowKind.control) controls++;
    assert(controls == 1,
        "only the param the renderer can draw gets a row; read "
        ~ controls.to!string);

    foreach (ref r; form.rows) {
        if (r.kind != RowKind.control) continue;
        assert(r.id == "chan.real", "the surviving row is the float one");
        auto rc = resolveControl(r, ps);
        assert(rc.found && rc.widget != WidgetKind.none,
            "and it resolves to a real widget");
    }
}

// ---------------------------------------------------------------------------
// How read-only renders, and the one channel this panel deliberately does not
// write.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: `rebuildBlocked` testing only
// `channelWritesThroughLayerAttr` and dropping the `p.readonly_` term.
// OBSERVED RED: `paramEnabled("filename")` reads TRUE — the path renders as an
// editable text field whose every keystroke dispatches a `layer.attr` the
// command refuses ("attribute 'filename' is read-only"), which is the failure
// the grey-out exists to prevent.
// ---------------------------------------------------------------------------
unittest {
    import document : ImageData;

    auto img = new Layer;
    img.name = "logo";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();

    auto prov = new ChannelsProvider(img);

    // Vacuity guard: `filename` really is declared readonly, and really is in
    // this item's param set — otherwise the assertion below is about nothing.
    bool sawFilename = false, filenameReadonly = false;
    foreach (ref p; prov.params())
        if (p.name == "filename") { sawFilename = true; filenameReadonly = p.readonly_; }
    assert(sawFilename && filenameReadonly,
        "fixture: the image item exposes a readonly 'filename'");

    assert(!prov.paramEnabled("filename"),
        "a readonly channel is shown but greyed — an editable widget would "
        ~ "dispatch a write layer.attr refuses");
    assert(!prov.paramEnabled("visible"),
        "'visible' is greyed here: the generic write would skip the "
        ~ "hide-the-primary promotion that layer.setVisible owns");
    assert(prov.paramEnabled("colorspace") && prov.paramEnabled("useAlpha"),
        "…and every ordinary channel stays live — greying everything would "
        ~ "pass the two assertions above and close no gap at all");
    assert(prov.paramEnabled("name"),
        "'name' rides the generic path like any other channel");

    // The decorator must not swallow the BASE provider's own interlock.
    auto plane = new Layer;
    plane.kind = ItemKind.Mesh;
    auto p2 = new ChannelsProvider(plane);
    assert(p2.paramEnabled("pos.x"), "no tool active: the transform row is live");
    {
        import seltype : SelType;
        p2.base.setTransformGuard(true, SelType.Vertex);
        assert(!p2.paramEnabled("pos.x"),
            "the base's mid-gesture transform interlock still greys the row "
            ~ "through the decorator");
    }
}

// ---------------------------------------------------------------------------
// The memo key changes exactly when the rows must be rebuilt.
//
// WRONG IMPLEMENTATION, BROKEN AND RESTORED: dropping `paramCount` from
// `ChannelsKey`. OBSERVED RED: the last assertion fires — an image-plane item
// whose payload appears (null -> constructed, 14 params -> 24) keeps the SAME
// key, so a memoising panel would go on drawing the 14-row form and the ten
// channels would stay invisible until something else moved the selection. That
// is task 0612's hole re-created inside the fix for it.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ImagePlaneData;
    import mesh     : makeCube;
    import seltype  : SelMode;

    auto doc = Document.bootstrap(makeCube());
    auto a = channelsModel(&doc);

    auto plane = new Layer;
    plane.name = "p";
    plane.kind = ItemKind.ImagePlane;      // payload deliberately absent
    doc.layers ~= plane;
    doc.selectItem(plane, SelMode.Set);

    auto b = channelsModel(&doc);
    assert(b.key != a.key, "the bound item changed: the key must change");
    assert(b.channelCount == 14,
        "a payload-less plane exposes only the base bundle; read "
        ~ b.channelCount.to!string);

    plane.imagePlaneRef() = new ImagePlaneData();
    auto c = channelsModel(&doc);
    assert(c.channelCount == 24, "the payload's ten channels appear");
    assert(c.key != b.key,
        "same item, same index, MORE params — the key must still change or a "
        ~ "memoised panel never redraws the ten channels");
}

// ---------------------------------------------------------------------------
// An empty document binds nothing rather than crashing or inventing an item.
// ---------------------------------------------------------------------------
unittest {
    Document empty;
    auto m = channelsModel(&empty);
    assert(!m.bound && m.form.rows.length == 0 && m.channelCount == 0);
    assert(channelsModel(null).bound == false);
}
