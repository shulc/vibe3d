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
