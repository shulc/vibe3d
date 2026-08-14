// Module unittests for `ui.channel_rows`, moved verbatim out of source/ui/channel_rows.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.channel_rows_test;

import document     : Document, Layer, ItemKind, kindInfo;
import layer_params : LayerPropsProvider, itemPropsTarget;
import params       : Param, ParamProvider;
import forms        : Form, Row, RowKind, WidgetKind, widgetForKind;
import std.algorithm : startsWith;
import std.conv      : to;
import ui.channel_rows;

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
    // ADD, not Set (task 0668): an exclusive select of a plane leaves NO
    // primary, and the vacuity guard below would then be comparing the focus
    // against `null` rather than against a live, different layer.
    doc.selectItem(plane, SelMode.Add);

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
