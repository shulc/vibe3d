// The layer-props form's PER-KIND section: declared vs RENDERED.
//
// No HTTP, no running vibe3d, no ImGui. Source-backed: `import forms` /
// `import layer_params` pull those modules (and their transitive unittest
// blocks) into the `dmd -unittest` compile.
//
// ---------------------------------------------------------------------------
// What this file exists to prevent
// ---------------------------------------------------------------------------
// An image plane's ten channels were DECLARED as `Param`s in layer_params.d
// and reachable through `layer.attr` from the moment they shipped — and none
// of them was reachable from the UI, because the form is authored in YAML and
// nothing in it named them. Every test that existed passed throughout: they
// asserted the params were declared, which was true, and the shipped claim
// that the panel showed them was never checked by anything.
//
// So a test here is worthless unless it can tell those two states apart. The
// seam that does it is `forms.planForm`: the pure function that decides WHICH
// rows the renderer emits for a given provider snapshot. FormsPanel.draw calls
// it and then draws exactly what it returns, asking no visibility question of
// its own (forms_render.d) — so a plan is the panel's row list, not a model of
// it. A param with no row is absent from the plan; a param with a row is in it.
// That is precisely the distinction that was missing.
//
// The `?`-query read-back path is NOT a substitute: `layer.attr <i> brightness
// ?` answered correctly the whole time the channel was unreachable. Asserting
// through it would reproduce the original mistake in test form.

import forms;
import layer_params : LayerPropsProvider, layerAttrUniverse, itemPropsTarget;
import params : Param;

import std.algorithm : canFind;
import std.conv      : to;
import std.json      : JSONValue;

void main() {}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// The shipped form, loaded from the real config file. A missing file is a hard
// FAILURE, never a skip: a skip would report green while asserting nothing,
// which is the same "coverage that was never there" this file exists to end.
private Form layerPropsForm()
{
    import std.file : exists;
    enum path = "config/forms/layer_props.yaml";
    assert(exists(path),
        "fixture: " ~ path ~ " must be readable from the harness cwd — this "
        ~ "test asserts the SHIPPED form, and silently skipping when it is "
        ~ "missing would report green having checked nothing");
    auto forms = loadForms(path);
    foreach (ref f; forms)
        if (f.id == "layer.props") return f;
    assert(false, "fixture: no form with id 'layer.props' in " ~ path);
}

private Param[] planeParams(out Object keepAlive)
{
    import document : Layer, ItemKind, ImagePlaneData;
    auto plane = new Layer;
    plane.name = "backdrop";
    plane.kind = ItemKind.ImagePlane;
    plane.imagePlaneRef() = new ImagePlaneData();
    keepAlive = plane;              // the params' pointers alias its fields
    return (new LayerPropsProvider(plane)).params();
}

private Param[] meshParams(out Object keepAlive)
{
    import document : Layer;
    import mesh     : makeCube;
    auto m = new Layer;
    m.name = "the mesh";
    m.meshRef() = makeCube();       // kind defaults to Mesh
    keepAlive = m;
    return (new LayerPropsProvider(m)).params();
}

// The ten authored channels, spelled out. A count would pass on ten of the
// WRONG rows.
private static immutable string[] kPlaneChannels = [
    "projection", "showInPerspective", "pixelSize", "keepAspect",
    "brightness", "contrast", "transparency", "invert",
    "flipHorizontal", "smooth",
];

// Find a planned row of a given kind carrying a given visible label.
private bool plannedLabel(PlannedRow[] plan, RowKind kind, string label)
{
    foreach (ref pr; plan) {
        if (pr.kind == kind && pr.label == label) return true;
        if (plannedLabel(pr.children, kind, label)) return true;
    }
    return false;
}

private PlannedRow* findControl(PlannedRow[] plan, string attr)
{
    foreach (ref pr; plan) {
        if (pr.kind == RowKind.control && pr.attr == attr) return &pr;
        if (auto hit = findControl(pr.children, attr)) return hit;
    }
    return null;
}

// The exact argstring FormsPanel.writeValue builds for an edit of this row:
// parse the binding, rebind the layer-index placeholder to the bound layer,
// substitute the edited value into the `?` slot. Same three calls, same order.
private string writeLine(ref PlannedRow pr, JSONValue v, string layerIndex)
{
    auto b = parseBinding(pr.row.command);
    b = rebindBindingTarget(b, "", "", layerIndex);
    return substituteQuery(b, v);
}

// ---------------------------------------------------------------------------
// T1 — a plane's channels are RENDERED, not merely declared.
//
// Wrong implementation this discriminates against: the state of the tree
// before this change — all ten `Param`s declared in layer_params.d, zero rows
// naming them in layer_props.yaml. Every declaration assertion passes for it;
// every assertion below reads a different number (planned control rows 13 vs
// 23, and each named channel absent).
// ---------------------------------------------------------------------------
unittest {
    Object keep;
    auto snapshot = planeParams(keep);
    auto form     = layerPropsForm();
    auto plan     = planForm(form, snapshot);
    auto attrs    = plannedAttrs(plan);

    // Vacuity guard: the provider really does declare the channels, so a
    // failure below is the FORM's, not a fixture that never had them.
    foreach (n; kPlaneChannels)
        assert(snapshotHasAttr(snapshot, n),
            "fixture: the plane's provider declares `" ~ n ~ "`");

    // The claim itself, channel by channel.
    foreach (n; kPlaneChannels)
        assert(attrs.canFind(n),
            "`" ~ n ~ "` is DECLARED by the provider and must also be RENDERED "
            ~ "— the panel draws exactly the rows this plan holds, and it holds "
            ~ to!string(attrs.length) ~ ": " ~ to!string(attrs));

    // The shared half is still there: a plane carries the ordinary item
    // transform, and gaining a per-kind section must not cost it.
    foreach (n; ["name", "pos.x", "pos.y", "pos.z", "rot.x", "rot.y", "rot.z",
                 "scl.x", "scl.y", "scl.z", "pivot.x", "pivot.y", "pivot.z"])
        assert(attrs.canFind(n),
            "the shared row `" ~ n ~ "` survives on a plane");

    // 13 shared + 10 channels, and nothing else.
    assert(attrs.length == 23,
        "a plane renders 13 shared rows + 10 channel rows — read "
        ~ to!string(attrs.length) ~ ": " ~ to!string(attrs));

    // CLOSURE, the assertion that keeps this from rotting: every param the
    // provider declares for a plane has a row, bar the one documented
    // exclusion. An eleventh channel added to layer_params.d with no row goes
    // RED here rather than shipping invisible — which is the whole failure
    // mode this file was written for.
    foreach (ref p; snapshot) {
        if (p.name == "visible") continue;   // rides layer.setVisible, by design
        assert(attrs.canFind(p.name),
            "the provider declares `" ~ p.name ~ "` but no row renders it — "
            ~ "declared is not rendered");
    }
    assert(!attrs.canFind("visible"),
        "`visible` is deliberately NOT a row here: hiding the primary must "
        ~ "promote another layer, a hook the generic write would bypass");
}

// ---------------------------------------------------------------------------
// T2 — a MESH renders none of them, and the section heading goes with them.
//
// The other half of the per-kind claim, and the one a naive fix fails: rows
// declared UNGATED would render on every kind. That implementation reads 23
// planned attrs here instead of 13, with the ten channel rows bound to attrs
// the mesh provider does not expose — so every edit would dispatch
// `layer.attr <i> brightness …` at a mesh and be rejected as an unknown attr.
// ---------------------------------------------------------------------------
unittest {
    Object keep;
    auto snapshot = meshParams(keep);
    auto form     = layerPropsForm();
    auto plan     = planForm(form, snapshot);
    auto attrs    = plannedAttrs(plan);

    foreach (n; kPlaneChannels) {
        assert(!snapshotHasAttr(snapshot, n),
            "fixture: a mesh's provider does not declare `" ~ n ~ "`");
        assert(!attrs.canFind(n),
            "a mesh layer must not grow the image-plane row `" ~ n ~ "` — the "
            ~ "mesh plan holds " ~ to!string(attrs.length) ~ ": "
            ~ to!string(attrs));
    }

    // The shared half is untouched — this change is inert on a mesh.
    assert(attrs.length == 13,
        "a mesh renders name + the 12 transform components and nothing else — "
        ~ "read " ~ to!string(attrs.length) ~ ": " ~ to!string(attrs));

    // The section HEADING carries no value bind of its own, so it cannot
    // self-hide; it rides an explicit `whenAttr` gate. Assert both directions
    // — a heading captioning an empty region on every mesh in the document is
    // exactly what an ungated one would do.
    assert(!plannedLabel(plan, RowKind.label, "Image Plane"),
        "the per-kind section heading must not caption an empty region on a "
        ~ "mesh layer");

    Object keep2;
    auto planePlan = planForm(form, planeParams(keep2));
    assert(plannedLabel(planePlan, RowKind.label, "Image Plane"),
        "…and it MUST appear for a plane — asserting only the mesh half would "
        ~ "be satisfied by deleting the heading outright");
}

// ---------------------------------------------------------------------------
// T3 — each channel resolves to the right WIDGET and the right visible LABEL.
//
// A row that renders but as the wrong control is still a broken row, and the
// label is what the user reads. Both are display-ready values on the plan, so
// a wrong implementation reads a different string/enum here rather than hiding
// the difference in the ImGui half nothing can assert.
//
// Discriminating on the widget: dropping `style: slider` from the three look
// scalars leaves them rendered and bound, and flips exactly these three reads
// from sliderFloat to dragFloat.
// ---------------------------------------------------------------------------
unittest {
    Object keep;
    auto form = layerPropsForm();
    auto plan = planForm(form, planeParams(keep));

    // LAYOUT INVARIANT — the one property a row plan cannot see directly,
    // made assertable rather than left to a screenshot.
    //
    // beginLabeledRow (forms_render.d) prints a LEFT-column label and then
    // places the widget at a FIXED column (fieldColumnX == 7em). ImGui's
    // SameLine(x) sets the cursor ABSOLUTELY, so a label wider than that
    // column is not pushed aside — the widget lands on top of its tail. That
    // is the same defect class that reached the Images panel, where two
    // hardcoded column offsets let one cell run into the next, and which
    // nothing but looking at it could find.
    //
    // A checkbox is immune: drawCheckbox calls beginLabeledRow("") and puts
    // its label to the RIGHT of the box, where there is no column to overrun.
    // So the invariant is narrow and checkable: a row that puts its label in
    // the LEFT column must have a label that fits there. It is what makes the
    // long channel names ("Show in Perspective", "Flip Horizontal") safe —
    // they are bools, and bools are checkboxes.
    //
    // The budget is in CHARACTERS, not pixels, because the pixel width is an
    // ImGui runtime value: 7em at the default font is roughly 12-14 average
    // glyphs, so 12 is the conservative read. This is therefore a proxy with a
    // stated basis, not a measurement — see the report note.
    enum size_t kLeftColumnGlyphs = 12;
    foreach (ref pr; plan) {
        // Top level only: a group's members are drawn by the vector-cluster
        // layout, a different column scheme with one-glyph labels.
        if (pr.kind != RowKind.control) continue;
        if (pr.widget == WidgetKind.checkbox || pr.widget == WidgetKind.button)
            continue;                       // label rides right of the widget
        assert(pr.label.length <= kLeftColumnGlyphs,
            "row `" ~ pr.attr ~ "` puts '" ~ pr.label ~ "' ("
            ~ to!string(pr.label.length) ~ " glyphs) in the fixed left column, "
            ~ "which fits about " ~ to!string(kLeftColumnGlyphs)
            ~ " — the widget would be drawn over its tail");
    }

    struct Expect { string attr; WidgetKind widget; string label; }
    static immutable Expect[] expect = [
        Expect("projection",        WidgetKind.combo,       "Projection"),
        Expect("showInPerspective", WidgetKind.checkbox,    "Show in Perspective"),
        Expect("pixelSize",         WidgetKind.dragFloat,   "Pixel Size"),
        Expect("keepAspect",        WidgetKind.checkbox,    "Keep Aspect"),
        Expect("brightness",        WidgetKind.sliderFloat, "Brightness"),
        Expect("contrast",          WidgetKind.sliderFloat, "Contrast"),
        Expect("transparency",      WidgetKind.sliderFloat, "Transparency"),
        Expect("invert",            WidgetKind.checkbox,    "Invert"),
        Expect("flipHorizontal",    WidgetKind.checkbox,    "Flip Horizontal"),
        Expect("smooth",            WidgetKind.checkbox,    "Smooth"),
    ];

    foreach (e; expect) {
        auto pr = findControl(plan, e.attr);
        assert(pr !is null, "`" ~ e.attr ~ "` has a planned row");
        assert(pr.widget == e.widget,
            "`" ~ e.attr ~ "` renders as " ~ to!string(e.widget) ~ " — read "
            ~ to!string(pr.widget));
        assert(pr.label == e.label,
            "`" ~ e.attr ~ "` is labelled '" ~ e.label ~ "' — read '"
            ~ pr.label ~ "'");
    }

    // The enum's choices come from the Param, not the YAML — so the projection
    // combo offers the six axis-aligned presets and nothing else.
    auto proj = findControl(plan, "projection");
    assert(proj.rc.choices.length == 6,
        "the projection combo offers the six presets — read "
        ~ to!string(proj.rc.choices.length));
    foreach (i, tag; ["top", "bottom", "front", "back", "right", "left"])
        assert(proj.rc.choices[i][0] == tag,
            "projection choice " ~ to!string(i) ~ " is '" ~ tag ~ "' — read '"
            ~ proj.rc.choices[i][0] ~ "'");
}

// ---------------------------------------------------------------------------
// T4 — editing a channel row dispatches at the BOUND layer.
//
// A correct value routed at the wrong item is the bug class a value-only
// assertion cannot see: the YAML's `<index>` token is a literal placeholder
// (0) that must be overwritten with the live index of the item the form is
// bound to. On a document whose focus is not layer 0 — which is every document
// with a plane in it, since a plane can never be primary — a row that failed
// to rebind would silently edit layer 0 instead.
//
// This builds the write line through the same three calls FormsPanel.writeValue
// makes, so the assertion is on the argstring the panel actually emits.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, Layer, ItemKind, ImagePlaneData;
    import mesh     : makeCube;
    import seltype  : SelMode;

    auto doc = Document.bootstrap(makeCube());
    auto plane = new Layer;
    plane.name = "backdrop";
    plane.kind = ItemKind.ImagePlane;
    plane.imagePlaneRef() = new ImagePlaneData();
    doc.layers ~= plane;
    // ADD, not Set (task 0668): an exclusive select of a plane leaves NO
    // primary, and the fixture guard below turns on the bound item differing
    // from a LIVE primary — against `null` it would stop discriminating.
    doc.selectItem(plane, SelMode.Add);

    // The end-to-end binding: the form follows the item-selection FOCUS, and a
    // plane can never be primary — so this is what makes the section reachable
    // at all. Bind the provider the way the panel does.
    auto bound = itemPropsTarget(&doc);
    assert(bound is plane, "precondition: the form binds the focused plane");
    immutable idx = doc.indexOf(bound);
    assert(idx == 1 && doc.indexOf(doc.primary) == 0,
        "fixture: the bound item is NOT index 0, so a missing rebind is "
        ~ "visible — bound " ~ to!string(idx));

    auto form = layerPropsForm();
    auto plan = planForm(form, (new LayerPropsProvider(bound)).params());

    auto bright = findControl(plan, "brightness");
    assert(bright !is null);
    assert(writeLine(*bright, JSONValue(0.5), to!string(idx))
           == "layer.attr 1 brightness 0.5",
        "a brightness edit writes at the bound layer — read '"
        ~ writeLine(*bright, JSONValue(0.5), to!string(idx)) ~ "'");

    auto inv = findControl(plan, "invert");
    assert(writeLine(*inv, JSONValue(true), to!string(idx))
           == "layer.attr 1 invert true",
        "a checkbox writes the bool token — read '"
        ~ writeLine(*inv, JSONValue(true), to!string(idx)) ~ "'");

    auto proj = findControl(plan, "projection");
    assert(writeLine(*proj, JSONValue("left"), to!string(idx))
           == "layer.attr 1 projection left",
        "a combo writes the enum TAG — read '"
        ~ writeLine(*proj, JSONValue("left"), to!string(idx)) ~ "'");

    // And the shared rows rebind to the same bound item, not to the primary.
    auto px = findControl(plan, "pos.x");
    assert(writeLine(*px, JSONValue(2.0), to!string(idx))
           == "layer.attr 1 pos.x 2",
        "the shared transform rows address the bound item too — read '"
        ~ writeLine(*px, JSONValue(2.0), to!string(idx)) ~ "'");
}

// ---------------------------------------------------------------------------
// T5 — the boot fence: a misspelt layer attr fails LOUD.
//
// The failure mode without it is silence, and silence is what let the original
// gap ship: an unresolvable row is hidden on every snapshot, which looks
// exactly like a channel nobody wrote a row for. Tool and stage bindings have
// had this fence since the forms engine's Phase 3.
//
// The universe must be the UNION over kinds, or the per-kind section itself is
// rejected — so both directions are asserted.
// ---------------------------------------------------------------------------
unittest {
    import std.exception : collectExceptionMsg;

    FormValidators v;
    v.layerAttrs = () => layerAttrUniverse();

    static Row gate(string attr) {
        auto r = Row.makeLabel("Image Plane");
        r.whenAttr = attr;
        return r;
    }

    // The shipped form validates clean — the ten channel rows are legal even
    // though no single kind exposes all of the form's attrs at once. A throw
    // here fails the test with its own message.
    auto shipped = [layerPropsForm()];
    validateForms(shipped, v, "config/forms/layer_props.yaml");

    // A misspelt channel throws instead of vanishing. The message is asserted,
    // not merely the throw: that pins WHICH attr was rejected, so the case
    // cannot pass on some unrelated validation failure.
    Form typo;
    typo.id   = "layer.props";
    typo.rows = [Row.makeControl("layer.attr 0 brightnes ?")];
    immutable m1 = collectExceptionMsg(validateForms([typo], v, "<typo>"));
    assert(m1.canFind("brightnes") && m1.canFind("unknown attr"),
        "a misspelt layer attr must fail at boot — unfenced it resolves absent "
        ~ "forever and the row simply never appears. Read: '" ~ m1 ~ "'");

    // …and so does a misspelt SECTION gate, which hides a whole section.
    Form badGate;
    badGate.id   = "layer.props";
    badGate.rows = [Row.makeControl("layer.attr 0 name ?"), gate("projektion")];
    immutable m2 = collectExceptionMsg(validateForms([badGate], v, "<bad-gate>"));
    assert(m2.canFind("projektion") && m2.canFind("whenAttr"),
        "a misspelt whenAttr gate must fail at boot too — it decides whether a "
        ~ "whole section appears, and a typo hides it silently. Read: '"
        ~ m2 ~ "'");

    // Control: the same gate spelled correctly passes, so the case above is
    // about the SPELLING and not about gates being rejected outright.
    Form goodGate;
    goodGate.id   = "layer.props";
    goodGate.rows = [Row.makeControl("layer.attr 0 name ?"), gate("projection")];
    immutable m3 = collectExceptionMsg(validateForms([goodGate], v, "<good>"));
    assert(m3 is null, "a correctly spelt gate passes — read: '" ~ m3 ~ "'");
}
