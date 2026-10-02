// Module unittests for `display_state`, moved verbatim out of source/display_state.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.display_state_test;

public import viewport_scheme : kSchemeSolidFill;
import display_state;
import std.format : format;

/// The shipped default differs by projection on the SURFACE axis only.
unittest {
    immutable persp = shippedDisplayFor(false);
    immutable ortho = shippedDisplayFor(true);

    assert(persp.style == DisplayStyle.Shaded,
        "a perspective cell ships shaded");
    assert(ortho.style == DisplayStyle.Wireframe,
        "an orthographic cell ships lines-only");

    // The overlay axis is NOT part of this default. Both ship a uniform
    // overlay at full opacity; only the surface style differs. If a future
    // change wants a fainter ortho overlay it is a separate decision with a
    // separate sign-off, and this assertion is what makes it deliberate.
    assert(persp.wire == ortho.wire && persp.wire == WireOverlay.Uniform,
        "the overlay axis must not vary with projection");
    assert(persp.wireAlpha == ortho.wireAlpha && persp.wireAlpha == 1.0f,
        "the opacity must not vary with projection");

    // The perspective default is EXACTLY the struct default — a Single-layout
    // perspective viewport must be untouched by this whole change.
    assert(persp == DisplayState.init,
        "the perspective default must remain the struct's own default");
}

/// A wireframe ortho cell resolves to a plan that draws no faces but still
/// draws lines — i.e. the default is renderable, not merely representable.
unittest {
    ViewportDisplay d;
    d.active = shippedDisplayFor(true);
    const p = resolveDrawPlan(d, false);
    assert(!p.drawFaces, "the ortho default must not draw faces");
    assert(p.drawWire,   "the ortho default must still draw lines");
    assert(p.drawVerts,  "the ortho default draws vertex dots (Wireframe)");
}

unittest {
    // The default state is TODAY'S BEHAVIOUR. This is the assertion that
    // guards "introducing the display model changed no pixels": faces on and
    // lit, wireframe on at full opacity, no forced vertex dots, no dimming.
    // If a default ever drifts, this fails before anything renders.
    ViewportDisplay d;
    const p = resolveDrawPlan(d, false);
    assert(p.drawFaces, "default must draw faces");
    assert(p.facesLit,  "default must light faces");
    assert(p.drawWire,  "default must draw the wireframe overlay");
    assert(p.wireAlpha == 1.0f, "default overlay must be fully opaque");
    assert(!p.drawVerts, "default must not force vertex dots on");
    assert(p.dim == 1.0f, "the active pass must not be dimmed");
}

unittest {
    // Backdrop under the default state: identical passes, dimmed. That is
    // what the renderer did before this model existed, expressed as data.
    ViewportDisplay d;
    const b = resolveDrawPlan(d, true);
    const a = resolveDrawPlan(d, false);
    assert(b.drawFaces == a.drawFaces);
    assert(b.facesLit  == a.facesLit);
    assert(b.drawWire  == a.drawWire);
    assert(b.dim == kBackdropDim, "backdrop must carry the dim factor");
    assert(a.dim != b.dim, "active and backdrop must not share a dim");
}

unittest {
    // Surface-style truth table (active side).
    ViewportDisplay d;

    d.active.style = DisplayStyle.Shaded;
    auto p = resolveDrawPlan(d, false);
    assert(p.drawFaces && p.facesLit && !p.drawVerts);

    d.active.style = DisplayStyle.Solid;
    p = resolveDrawPlan(d, false);
    assert(p.drawFaces, "Solid draws a filled surface");
    assert(!p.facesLit, "Solid renders the geometry WITHOUT shading");
    assert(!p.drawVerts);

    d.active.style = DisplayStyle.Wireframe;
    p = resolveDrawPlan(d, false);
    assert(!p.drawFaces,
        "Wireframe must not draw faces at all — the model is see-through, "
        ~ "so not even a depth-only face pass is allowed");
    assert(p.drawVerts,
        "Wireframe draws vertices as well as the edges connecting them");

    // Task 1090. Note what `facesLit` alone can and cannot say here: it is
    // false for Weight exactly as it is for Solid, so the SHADING field is
    // what separates the two, and asserting only `!facesLit` would pass on a
    // Weight case that had silently fallen through to the unshaded fill.
    d.active.style = DisplayStyle.Weight;
    p = resolveDrawPlan(d, false);
    assert(p.drawFaces, "the weight style draws a filled surface");
    assert(!p.facesLit, "the weight style is UNLIT — measured, not inferred");
    assert(p.shading == SurfaceShading.Weight,
        "the weight style must resolve to its OWN shading arm; falling "
        ~ "through to Fill renders the scheme grey and still reports "
        ~ "facesLit:false, which is why this line exists");
    assert(!p.drawVerts,
        "the weight style is not a lines-only style; it must not force "
        ~ "vertex dots on");
    assert(p.drawWire,
        "the surface style must not disturb the overlay axis");

    // And every OTHER style keeps its own arm — a switch that wrote the new
    // value unconditionally would pass every assertion above.
    d.active.style = DisplayStyle.Shaded;
    assert(resolveDrawPlan(d, false).shading == SurfaceShading.Material);
    d.active.style = DisplayStyle.Solid;
    assert(resolveDrawPlan(d, false).shading == SurfaceShading.Fill);
    d.active.style = DisplayStyle.Wireframe;
    assert(resolveDrawPlan(d, false).shading == SurfaceShading.Fill,
        "a lines-only style has no face pass, but the field is still resolved "
        ~ "determinately — and to the value that keeps `facesLit` false");
}

// Task 1090: the style tables that both viewport combos now build from.
//
// WHAT THIS DOES NOT REACH, said plainly. `viewport.displayStyle`'s own parse
// switch is a THIRD hand-kept spelling of these names, and it is not checked
// here: the command needs a live `ViewportManager` to construct, which needs a
// GL context. It is checked where it can be — `tests/test_weightmap_display.d`
// posts the id and asserts the resulting style, and `tests/test_viewport_display.d`
// already does the same for the other three. So the chain is combo →
// `displayStyleId` → (HTTP test) → the parse switch, with no link taken on
// trust; it just is not all in one file.
unittest {
    import std.string : toLower;

    // Every declared style is offered by the combos, exactly once.
    foreach (s; kDisplayStyleOrder) {
        int seen = 0;
        foreach (t; kDisplayStyleOrder) if (t == s) seen++;
        assert(seen == 1, "kDisplayStyleOrder must list each style once");
        assert(displayStyleLabel(s).length > 0);
        assert(displayStyleId(s).length > 0);
        assert(displayStyleId(s) == displayStyleLabel(s).toLower,
            "the command id is the label lower-cased; if that ever stops "
            ~ "being true, this assertion is the place to say so rather than "
            ~ "letting a combo post an argument the command refuses");
    }

    // The ids are distinct — two styles sharing one id would make half the
    // combo unreachable while every other assertion here still passed.
    foreach (i, a; kDisplayStyleOrder)
        foreach (j, b; kDisplayStyleOrder)
            if (i != j)
                assert(displayStyleId(a) != displayStyleId(b),
                    "two styles share a command id");
}

unittest {
    // Overlay truth table, and the ONE forcing relation.
    ViewportDisplay d;

    d.active.wire = WireOverlay.None;
    assert(!resolveDrawPlan(d, false).drawWire,
        "overlay None must switch the base wireframe off");

    d.active.wire = WireOverlay.Uniform;
    assert(resolveDrawPlan(d, false).drawWire);

    // A lines-only style with the overlay switched off must NOT produce an
    // empty viewport.
    d.active.style = DisplayStyle.Wireframe;
    d.active.wire  = WireOverlay.None;
    assert(resolveDrawPlan(d, false).drawWire,
        "a lines-only surface style must force the overlay on");
}

unittest {
    // COMPOSITION PROPERTY (the two axes are independent).
    //
    // Sweeping the surface style must leave the overlay group untouched — the
    // documented exception being the lines-only style, which forces its own
    // lines and its own vertices on. If a future edit folds the two axes into
    // one enum, or makes a surface style quietly change the overlay opacity,
    // this fails.
    foreach (ubyte w; 0 .. 3) {
        ViewportDisplay ref_;
        ref_.active.wire      = cast(WireOverlay)w;
        ref_.active.wireAlpha = 0.375f;

        foreach (ubyte s; 0 .. 3) {
            ViewportDisplay d = ref_;
            d.active.style = cast(DisplayStyle)s;
            const p = resolveDrawPlan(d, false);

            assert(p.wireAlpha == 0.375f,
                "a surface style must never change overlay opacity");

            if (cast(DisplayStyle)s == DisplayStyle.Wireframe) {
                assert(p.drawWire,  "lines-only forces the overlay on");
                assert(p.drawVerts, "lines-only forces vertex dots on");
            } else {
                assert(p.drawWire == (cast(WireOverlay)w != WireOverlay.None),
                    "outside the lines-only style the overlay axis decides "
                    ~ "on its own");
                assert(!p.drawVerts,
                    "only the lines-only style forces vertex dots");
            }
        }
    }
}

unittest {
    // The overlay colour is not derived from the surface style either.
    ViewportDisplay d;
    const shaded = resolveDrawPlan(d, false);
    d.active.style = DisplayStyle.Solid;
    const solid = resolveDrawPlan(d, false);
    assert(shaded.wireColor == solid.wireColor,
        "overlay colour must not depend on the surface style");
}

unittest {
    // Backdrop axis truth table. `Wireframe` and `Flat` read the backdrop
    // SLOT, and the coarse control is a writer of that slot
    // (`tests/fixtures/backdrop_display_slots.json`, `coarse_control`): each
    // row below sets the slot style the `viewport.backdropStyle` command
    // writes, then one row writes the slot afterwards to show it is live.
    ViewportDisplay d;

    d.backdropStyle = BackdropStyle.Hidden;
    auto b = resolveDrawPlan(d, true);
    assert(!b.drawFaces && !b.drawWire && !b.drawVerts,
        "Hidden must draw nothing at all");

    d.backdropStyle  = BackdropStyle.Wireframe;
    d.backdrop.style = DisplayStyle.Wireframe;
    b = resolveDrawPlan(d, true);
    assert(!b.drawFaces, "backdrop Wireframe draws no faces");
    assert(b.drawWire,   "backdrop Wireframe draws lines");
    assert(b.dim == 1.0f, "backdrop Wireframe is not dimmed (fixture `brightness`)");

    // The slot is read, not the coarse value: a shaded slot under the
    // Wireframe control draws a lit surface (the capture's cross-check row).
    d.backdrop.style = DisplayStyle.Shaded;
    b = resolveDrawPlan(d, true);
    assert(b.drawFaces && b.facesLit,
        "backdrop Wireframe over a Shaded slot draws the slot's lit surface");

    d.backdropStyle  = BackdropStyle.Flat;
    d.backdrop.style = DisplayStyle.Shaded;
    b = resolveDrawPlan(d, true);
    assert(b.drawFaces,  "backdrop Flat draws a filled surface");
    assert(b.facesLit,   "backdrop Flat is LIT and faceted: it writes a shaded "
        ~ "slot (fixture `retopology_display.json` backdrop.flat_writes)");
    assert(b.dim == 1.0f, "backdrop Flat is not dimmed (fixture `brightness`)");

    d.backdrop.style = DisplayStyle.Solid;
    b = resolveDrawPlan(d, true);
    assert(b.drawFaces && !b.facesLit,
        "a Solid slot under Flat draws the unlit fill: the renderer reads the slot");

    // The backdrop axis is independent of the ACTIVE style: soloing the
    // active layer must not change how the active mesh draws.
    d.backdropStyle = BackdropStyle.Hidden;
    const a = resolveDrawPlan(d, false);
    assert(a.drawFaces && a.facesLit && a.drawWire,
        "a backdrop setting must not reach the active pass");
}

unittest {
    // The activity axis is genuinely two control sets: a backdrop-only edit
    // must be visible in the backdrop plan and invisible in the active one.
    ViewportDisplay d;
    d.backdropStyle       = BackdropStyle.Wireframe;
    d.backdrop.wireAlpha  = 0.25f;

    const a = resolveDrawPlan(d, false);
    const b = resolveDrawPlan(d, true);
    assert(a.wireAlpha == 1.0f,  "active side must keep its own opacity");
    assert(b.wireAlpha == 0.25f, "backdrop side must use the backdrop opacity");
}

unittest {
    // TASK 0592 — the unshaded fill's colour is the viewport COLOUR SCHEME's,
    // and it does not come from the surface material.
    //
    // The two candidate anchors, side by side, so the assertion states which
    // one is measured:
    //   MEASURED (theirs): 0.6 grey — the scheme's fill entry, read from the
    //                      reference's own shipped colour scheme.
    //   OURS (0589, wrong): 0.8 grey — `LitShader`'s default material slot.
    // If those two were ever equal this test would be vacuous, so say so.
    enum float kMeasuredTheirs = 0.6f;
    enum float kOursWas0589    = 0.8f;   // the material grey, superseded
    static assert(kMeasuredTheirs != kOursWas0589,
        "the two anchors must differ or nothing below discriminates");

    assert(kSchemeSolidFill == kMeasuredTheirs,
        "the Solid fill must be anchored on the MEASURED scheme colour, not "
        ~ "on the surface material we happened to be loading anyway");

    ViewportDisplay d;
    d.active.style = DisplayStyle.Solid;
    const p = resolveDrawPlan(d, false);
    assert(p.fillColor == [kMeasuredTheirs, kMeasuredTheirs, kMeasuredTheirs],
        "the resolved unshaded fill must carry the scheme colour");

    // Determinate under every style — the field is resolved always and read
    // only when the pass is unlit, so a style sweep must not perturb it.
    foreach (ubyte s; 0 .. 3) {
        ViewportDisplay e;
        e.active.style = cast(DisplayStyle)s;
        assert(resolveDrawPlan(e, false).fillColor == p.fillColor,
            "fillColor is resolved, not styled — the shader's u_lit decides "
            ~ "whether it is read");
    }
}

unittest {
    // TASK 0592 — the unshaded style runs NO BACKDROP FACE PASS.
    //
    // Measured from the reference's style registry: every shaded style
    // installs three model-draw sub-passes (background, main, transparency);
    // the unshaded solid style installs one, the main one. So `SameAsActive`
    // must not re-run the fill for background layers.
    //
    // NARROW reading, asserted as such: the FACE pass stops, the layers do
    // NOT vanish. The overlay half below is the load-bearing half of that —
    // without it this test would equally pass on "Solid hides the backdrop",
    // which is the over-read the measurement does not support.
    ViewportDisplay d;
    d.active.style = DisplayStyle.Solid;
    assert(d.backdropStyle == BackdropStyle.SameAsActive);

    const b = resolveDrawPlan(d, true);
    assert(!b.drawFaces,
        "the unshaded style installs no background face step, so a backdrop "
        ~ "that mirrors it must not draw one");
    assert(b.drawWire,
        "background layers must NOT vanish — the overlay is its own axis and "
        ~ "the measurement says nothing about it");

    // Backdrop-only: the active pass keeps its fill.
    const a = resolveDrawPlan(d, false);
    assert(a.drawFaces && !a.facesLit,
        "the rule is about the BACKDROP pass; the active surface still fills");

    // Shaded is untouched — this is the neutrality half.
    ViewportDisplay sh;
    assert(sh.active.style == DisplayStyle.Shaded);
    assert(resolveDrawPlan(sh, true).drawFaces,
        "a shaded style DOES install a background step; the default backdrop "
        ~ "face pass must be exactly as it was");

    // An EXPLICIT flat backdrop still fills, even under an active Solid. That
    // is the user naming a backdrop representation — a separate style in the
    // reference — not the active surface style reaching across.
    ViewportDisplay f;
    f.active.style  = DisplayStyle.Solid;
    f.backdropStyle = BackdropStyle.Flat;
    f.backdrop.style = DisplayStyle.Solid;
    const fb = resolveDrawPlan(f, true);
    assert(fb.drawFaces && !fb.facesLit,
        "an explicitly chosen flat backdrop over a Solid slot keeps its fill — "
        ~ "the suppression is scoped to SameAsActive inheritance");
}

/// The ACTIVE plan is never dimmed (task 9040). The primary face pass writes
/// `u_dim` through the plan-uniform seam (`LitShader.applyPlan`), where it
/// used to leave it at the park; that is pixel-neutral only while this holds,
/// so a change to it reddens here instead of as a silent look change.
unittest {
    import std.format : format;
    import std.traits : EnumMembers;
    struct Row { DisplayStyle style; bool retopo; float dim; }
    Row[] rows;
    foreach (style; [EnumMembers!DisplayStyle]) {
        foreach (retopo; [false, true]) {
            ViewportDisplay d;
            d.active.style = style;
            d.retopology   = retopo;
            rows ~= Row(style, retopo, resolveDrawPlan(d, false).dim);
        }
    }
    // Floor first: 6 styles x retopology off/on (9150 appended Gooch, 9250 Reflection).
    assert(rows.length == 12, format("expected 12 style x retopology rows, swept %d", rows.length));
    foreach (r; rows)
        assert(r.dim == 1.0f,
            format("the active plan of style %s (retopology %s) has dim %s; "
                   ~ "only a backdrop plan may dim", r.style, r.retopo, r.dim));
}

/// Task 9070 (S1a A3): the normal source. Default smooth on both plans; `smooth`
/// off resolves flat on both; a `Flat` backdrop reads the BACKDROP slot's
/// `smooth`, a `SameAsActive` backdrop the ACTIVE slot's.
unittest {
    ViewportDisplay d;
    assert(DrawPlan.init.smoothNormals, "the DrawPlan default normal source must be smooth");
    assert(resolveDrawPlan(d, false).smoothNormals && resolveDrawPlan(d, true).smoothNormals,
        "a default cell must resolve smooth on both plans");
    d.active.smooth = false;
    d.backdrop.smooth = false;
    assert(!resolveDrawPlan(d, false).smoothNormals && !resolveDrawPlan(d, true).smoothNormals,
        "smooth=false on both slots must resolve flat on both plans");

    ViewportDisplay f;
    f.backdropStyle = BackdropStyle.Flat;
    f.active.smooth = true;
    f.backdrop.smooth = false;
    assert(!resolveDrawPlan(f, true).smoothNormals,
        "a Flat backdrop must read the backdrop slot's smooth (false), not the active slot's");
    assert(resolveDrawPlan(f, false).smoothNormals, "the active plan reads the active slot");

    ViewportDisplay s;   // SameAsActive is the default backdrop style
    assert(s.backdropStyle == BackdropStyle.SameAsActive, "premise: default backdrop is SameAsActive");
    s.active.smooth = false;
    s.backdrop.smooth = true;
    assert(!resolveDrawPlan(s, true).smoothNormals,
        "a SameAsActive backdrop must follow the ACTIVE slot's smooth (false)");
}

/// [E1] The composition of `DisplayState`: a new per-slot control is a
/// decision every consumer (prefs mirror, endpoint, command) must see.
unittest {
    static assert([__traits(allMembers, DisplayState)]
        == ["style", "wire", "wireAlpha", "showVertices", "pointSize", "smooth"],
        "DisplayState's members changed — extend the prefs mirror, the display endpoint "
        ~ "and the command surface for the new control, then this list");
}

/// [E1] Task 9150 (S4a, H2): the style and shading member lists, in ORDER —
/// ordinals reach GL (`u_shading`) and persisted fixtures, so a new member is
/// appended LAST and every consumer below is extended with it.
unittest {
    static assert([__traits(allMembers, DisplayStyle)]
        == ["Wireframe", "Solid", "Shaded", "Weight", "Gooch", "Reflection"],
        "DisplayStyle's members changed — extend kDisplayStyleOrder, the label/id "
        ~ "switches, resolveDrawPlan, the command parse and the prefs parse, then this list");
    static assert([__traits(allMembers, SurfaceShading)]
        == ["Material", "Fill", "Weight", "Retopology", "Gooch", "Reflection"],
        "SurfaceShading's members changed — the ordinal is the lit shader's u_shading; "
        ~ "extend litFragSrc's arms, then this list");
    static assert(cast(int) SurfaceShading.Gooch == 4 && cast(int) DisplayStyle.Gooch == 4,
        "Gooch is appended LAST: u_shading == 4 in litFragSrc");
}

/// Task 9150 (S4a, H2): Gooch resolves to its OWN lit arm, offered in the
/// combos after Weight, labelled "Gooch" / posted as "gooch".
unittest {
    ViewportDisplay d;
    d.active.style = DisplayStyle.Gooch;
    const p = resolveDrawPlan(d, false);
    assert(p.drawFaces && p.styleFills, "the Gooch style draws a filled surface");
    assert(p.shading == SurfaceShading.Gooch,
        "the Gooch style must resolve to its own arm, not Material's Blinn");
    assert(p.facesLit, "the Gooch style is lit (its own eye-space light)");
    assert(!p.drawVerts && p.drawWire && p.dim == 1.0f,
        "the Gooch style must not disturb the overlay axis or dim the active plan");
    assert(resolveDrawPlan(d, true).shading == SurfaceShading.Gooch
        && resolveDrawPlan(d, true).dim == kBackdropDim,
        "a SameAsActive backdrop mirrors the Gooch arm, dimmed");
    assert(kDisplayStyleOrder[$ - 2] == DisplayStyle.Gooch && kDisplayStyleOrder.length == 6,
        "Gooch is offered after Weight (Reflection follows it, task 9250)");
    assert(displayStyleLabel(DisplayStyle.Gooch) == "Gooch"
        && displayStyleId(DisplayStyle.Gooch) == "gooch");
}

/// Task 9150 (S4a, H2): the command's own parse switch (the third hand-kept
/// spelling) accepts every offered id and writes that style — driven through
/// the real command with a headless ViewportManager.
unittest {
    import command_args : bindArgs;
    import commands.viewport.display : ViewportDisplayStyle;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.format : format;
    import viewport : ViewportManager;
    auto vpm = new ViewportManager(0, 0, 800, 600);
    auto m = makeCube();
    size_t checked;
    foreach (s; kDisplayStyleOrder) {
        auto c = new ViewportDisplayStyle(&m, vpm.views[0].camera, EditMode.Polygons, vpm);
        bindArgs(c, format(`{"value":"%s","viewport":0}`, displayStyleId(s)));
        assert(c.apply(), format("viewport.displayStyle refused the offered id '%s'", displayStyleId(s)));
        assert(vpm.views[0].display.active.style == s,
            format("viewport.displayStyle '%s' wrote %s, not %s — the parse switch maps "
                   ~ "the id to the wrong style", displayStyleId(s),
                   vpm.views[0].display.active.style, s));
        ++checked;
    }
    assert(checked == 6, format("population floor: 6 offered styles, checked %d", checked));
}

/// [E1] The composition of the cavity state and the composite plan (task
/// 9190): a new field is a decision the prefs mirror, the endpoint, the
/// command and the clamp table must all see.
unittest {
    static assert([__traits(allMembers, CavityState)]
        == ["mode", "screenRidge", "screenValley", "worldRidge", "worldValley",
            "distance", "attenuation", "samples"],
        "CavityState's members changed — extend the prefs mirror, the endpoint, "
        ~ "viewport.cavityParams and resolveCavityParams, then this list");
    static assert([__traits(allMembers, CompositePlan)]
        == ["cavity", "screenRidge", "screenValley", "worldRidge", "worldValley",
            "distance", "attenuation", "samples", "empty"],
        "CompositePlan's members changed — extend the compositor's pass table, "
        ~ "the endpoint and this list");
}

/// [E2] The composite truth table (owner ruling, task 9190): cavity reaches
/// the ACTIVE plan only under the Shaded style with the retopology mode off;
/// every other style and the mode resolve it Off; the backdrop never carries
/// it; `clearDepthFirst ⇒ composite.empty`; `effectFlags` bit 0 iff the pass
/// shades Material from Shaded.
unittest {
    import std.traits : EnumMembers;
    size_t rows;
    foreach (style; [EnumMembers!DisplayStyle])
    foreach (mode; [EnumMembers!CavityMode])
    foreach (retopo; [false, true]) {
        ViewportDisplay d;
        d.active.style = style;
        d.cavity.mode  = mode;
        d.cavity.samples = 33;   // off its default: an unresolved plan must not carry it
        d.retopology   = retopo;
        immutable DrawPlan a = resolveDrawPlan(d, false);
        immutable DrawPlan b = resolveDrawPlan(d, true);
        immutable bool want = style == DisplayStyle.Shaded && !retopo && mode != CavityMode.Off;
        immutable ctx = format("style %s mode %s retopology %s", style, mode, retopo);
        assert(a.composite.empty == !want,
            "E2: active composite " ~ (want ? "must carry" : "must be empty") ~ " — " ~ ctx);
        if (want) assert(a.composite.cavity == mode, "E2: active composite mode — " ~ ctx);
        // An unresolved composite is the INIT value, whatever the parameters
        // (a hidden parameter change must not re-render the cell).
        else assert(a.composite == CompositePlan.init, "E2: an empty composite must be CompositePlan.init — " ~ ctx);
        assert(b.composite.empty, "E2: the backdrop plan never carries a composite — " ~ ctx);
        assert(!a.clearDepthFirst || a.composite.empty, "E2: clearDepthFirst ⇒ composite.empty — " ~ ctx);
        immutable ubyte flags = (style == DisplayStyle.Shaded && !retopo) ? kEffectCavityEligible : 0;
        assert(a.effectFlags == flags,
            format("E2: active effectFlags %d, expected %d — %s", a.effectFlags, flags, ctx));
        // SameAsActive backdrop follows the active style (Shaded → eligible).
        immutable ubyte bflags = (style == DisplayStyle.Shaded) ? kEffectCavityEligible : 0;
        assert(b.effectFlags == bflags,
            format("E2: backdrop effectFlags %d, expected %d — %s", b.effectFlags, bflags, ctx));
        ++rows;
    }
    assert(rows == (DisplayStyle.max + 1) * 4 * 2,
        format("E2 population: %d rows, expected every DisplayStyle × CavityMode × retopology", rows));
}

/// The kernel clamp of the cavity parameters at both bounds (two-layer clamp:
/// the command refuses, this caps every other route — prefs, a future
/// writer). Non-finite takes the field's default; the mode passes through.
unittest {
    import std.math : isNaN;
    struct Cell { string field; float lo, hi; }
    immutable Cell[6] cells = [Cell("screenRidge", 0, 250), Cell("screenValley", 0, 250),
        Cell("worldRidge", 0, 250), Cell("worldValley", 0, 250),
        Cell("distance", 1e-4f, 1e5f), Cell("attenuation", 0, 1e5f)];
    size_t n;
    static foreach (f; ["screenRidge", "screenValley", "worldRidge", "worldValley",
                        "distance", "attenuation"]) {{
        Cell c;
        foreach (x; cells) if (x.field == f) c = x;
        CavityState s;
        mixin("s." ~ f ~ " = c.lo - 1;");
        assert(mixin("resolveCavityParams(s)." ~ f) == c.lo, "clamp: " ~ f ~ " below its floor");
        mixin("s." ~ f ~ " = c.hi * 2;");
        assert(mixin("resolveCavityParams(s)." ~ f) == c.hi, "clamp: " ~ f ~ " above its ceiling");
        mixin("s." ~ f ~ " = c.lo;");
        assert(mixin("resolveCavityParams(s)." ~ f) == c.lo, "clamp: " ~ f ~ " at its floor must stand");
        mixin("s." ~ f ~ " = c.hi;");
        assert(mixin("resolveCavityParams(s)." ~ f) == c.hi, "clamp: " ~ f ~ " at its ceiling must stand");
        mixin("s." ~ f ~ " = float.nan;");
        assert(mixin("resolveCavityParams(s)." ~ f) == mixin("CavityState.init." ~ f),
            "clamp: a non-finite " ~ f ~ " must take its default");
        mixin("s." ~ f ~ " = float.infinity;");
        assert(mixin("resolveCavityParams(s)." ~ f) == mixin("CavityState.init." ~ f),
            "clamp: an infinite " ~ f ~ " must take its default");
        ++n;
    }}
    assert(n == 6, "clamp floor: six float params");
    CavityState s;
    s.samples = 0;    assert(resolveCavityParams(s).samples == 1, "clamp: samples below 1");
    s.samples = 1;    assert(resolveCavityParams(s).samples == 1, "clamp: samples at 1");
    s.samples = MAX_CAVITY_SAMPLES; assert(resolveCavityParams(s).samples == MAX_CAVITY_SAMPLES,
        "clamp: samples at the cap");
    s.samples = int.max; assert(resolveCavityParams(s).samples == MAX_CAVITY_SAMPLES,
        "clamp: samples above the kernel cap");
    s.mode = CavityMode.World;
    assert(resolveCavityParams(s).cavity == CavityMode.World, "clamp: the mode passes through");
}

/// The plan is compared WHOLE by the cell's dirty key: two resolutions of one
/// state must compare equal, with and without a composite (a NaN default in
/// `CompositePlan` would make every frame dirty).
unittest {
    ViewportDisplay d;
    assert(resolveDrawPlan(d, false) == resolveDrawPlan(d, false)
        && resolveDrawPlan(d, true) == resolveDrawPlan(d, true),
        "plan equality: the default plan must equal itself");
    d.cavity.mode = CavityMode.Screen;
    assert(!resolveDrawPlan(d, false).composite.empty, "premise: cavity screen resolves");
    assert(resolveDrawPlan(d, false) == resolveDrawPlan(d, false),
        "plan equality: a plan with a composite must equal itself");
    ViewportDisplay e = d;
    e.cavity.samples = 8;
    assert(resolveDrawPlan(d, false) != resolveDrawPlan(e, false),
        "plan equality: a cavity parameter change must change the plan (re-render)");
}

/// Task 9190: `viewport.compositeTestGain` is TEST-ONLY — refused outside
/// --test (production never writes the resolve gain) — and refuses a gain
/// outside [0, kCompositeTestGainMax] or non-finite, writing nothing.
unittest {
    import command : g_testMode;
    import command_args : bindArgs;
    import commands.viewport.display : ViewportCompositeTestGain, kCompositeTestGainMax;
    import editmode : EditMode;
    import mesh : makeCube;
    import viewport : ViewportManager;
    immutable bool prior = g_testMode;
    scope (exit) g_testMode = prior;
    auto vpm = new ViewportManager(0, 0, 800, 600);
    auto m = makeCube();
    bool applies(string body) {
        auto c = new ViewportCompositeTestGain(&m, vpm.views[0].camera, EditMode.Polygons, vpm);
        try { bindArgs(c, body); return c.apply(); } catch (Exception) return false;
    }
    g_testMode = true;
    vpm.views[0].dirty = false;
    assert(applies(`{"value":0.5,"viewport":0}`) && vpm.views[0].fbo.compositeTestGain == 0.5f,
        "control: under --test the gain is written");
    assert(vpm.views[0].dirty, "a written gain must mark the cell dirty (re-render)");
    size_t refused;
    foreach (body; [`{"value":-0.25,"viewport":0}`, `{"value":4.5,"viewport":0}`,
                    `{"value":"nan","viewport":0}`]) {
        assert(!applies(body), "an out-of-domain gain must be refused: " ~ body);
        assert(vpm.views[0].fbo.compositeTestGain == 0.5f, "a refused gain must write nothing: " ~ body);
        ++refused;
    }
    assert(refused == 3, "population floor: three out-of-domain gains");
    // NaN cannot arrive over JSON (the parse refuses it first), so the finite
    // term is reached by writing the bound field directly.
    {
        auto c = new ViewportCompositeTestGain(&m, vpm.views[0].camera, EditMode.Polygons, vpm);
        auto ps = c.params();
        assert(ps.length == 2 && ps[0].name == "value", "the gain is the command's first param");
        *ps[0].fptr = float.nan;
        bool ok;
        try ok = c.apply(); catch (Exception) ok = false;
        assert(!ok && vpm.views[0].fbo.compositeTestGain == 0.5f,
            "a non-finite gain must be refused, writing nothing");
    }
    assert(applies(format(`{"value":%s,"viewport":0}`, kCompositeTestGainMax)),
        "the domain's ceiling itself is accepted");
    g_testMode = false;
    assert(!applies(`{"value":2,"viewport":0}`), "outside --test the command must be refused");
    assert(vpm.views[0].fbo.compositeTestGain == kCompositeTestGainMax,
        "a refusal outside --test must write nothing");
}

// ---- S1d (model M6): cullBySurface over the whole display space -----------
// The captured cull table (C5, C7a/b/e/g/l), copied here as the oracle: a lit
// style culls by surface, the unlit fills and Wireframe never do; the
// retopology mode clears it on the ACTIVE side only; the backdrop reads the
// style it resolved (slot or active) also under the mode; Hidden draws nothing.
unittest {
    import std.traits : EnumMembers;
    static bool litStyleCulls(DisplayStyle s) {
        switch (s) {
            case DisplayStyle.Shaded, DisplayStyle.Gooch: return true;
            default: return false;
        }
    }
    assert(DrawPlan.init.cullBySurface == false, "DrawPlan.init must not cull by surface");
    size_t rows, culled;
    foreach (act; [EnumMembers!DisplayStyle])
    foreach (slot; [EnumMembers!DisplayStyle])
    foreach (bs; [EnumMembers!BackdropStyle])
    foreach (retopo; [false, true])
    foreach (isBackdrop; [false, true]) {
        ViewportDisplay d;
        d.active.style   = act;
        d.backdrop.style = slot;
        d.backdropStyle  = bs;
        d.retopology     = retopo;
        immutable DrawPlan p = resolveDrawPlan(d, isBackdrop);
        bool want;
        if (!isBackdrop)
            want = !retopo && litStyleCulls(act);
        else final switch (bs) {
            case BackdropStyle.SameAsActive: want = litStyleCulls(act); break;
            case BackdropStyle.Wireframe:
            case BackdropStyle.Flat:         want = litStyleCulls(slot); break;
            case BackdropStyle.Hidden:       want = false; break;
        }
        assert(p.cullBySurface == want,
            format("cullBySurface: active %s slot %s backdrop %s retopology %s %s: got %s, expected %s",
                   act, slot, bs, retopo, isBackdrop ? "backdrop" : "active", p.cullBySurface, want));
        // Invariant: the two-submission path never meets blending, the hard
        // cull or the reverse polygon order.
        assert(!p.cullBySurface || (!p.cullBackFaces && p.faceAlpha == 1.0f && !p.reverseFaceOrder),
            format("invariant: cullBySurface with cull %s alpha %s reverse %s (active %s, %s)",
                   p.cullBackFaces, p.faceAlpha, p.reverseFaceOrder, act, isBackdrop ? "backdrop" : "active"));
        ++rows;
        if (p.cullBySurface) ++culled;
    }
    // Floors: the space is 5 × 5 × 4 × 2 × 2, and it holds both values.
    assert(rows == 400, format("cullBySurface table: %d rows, expected 400", rows));
    assert(culled > 0 && culled < rows, format("cullBySurface table: %d of %d rows cull", culled, rows));
    // The per-style row, through the final switch.
    assert(styleCullsBySurface(DisplayStyle.Shaded) && styleCullsBySurface(DisplayStyle.Gooch)
        && !styleCullsBySurface(DisplayStyle.Solid) && !styleCullsBySurface(DisplayStyle.Weight)
        && !styleCullsBySurface(DisplayStyle.Wireframe), "styleCullsBySurface rows moved");
}

/// [E1] Task 9250 (S4b, H2): Reflection is appended LAST to both enums
/// (`u_shading == 5` in litFragSrc), and the reflection source's composition.
unittest {
    static assert(cast(int) SurfaceShading.Reflection == 5 && cast(int) DisplayStyle.Reflection == 5,
        "Reflection is appended LAST: u_shading == 5 in litFragSrc");
    static assert([__traits(allMembers, ReflectionKind)] == ["Env", "MatCap"],
        "ReflectionKind's members changed — the ordinal is the lit shader's u_reflectionKind; "
        ~ "extend litFragSrc's Reflection arm, viewport_env's tables and ids, then this list");
    static assert([__traits(allMembers, ReflectionSource)] == ["kind", "index"],
        "ReflectionSource's members changed — extend the prefs mirror, the endpoint and the "
        ~ "command, then this list");
}

/// Task 9250 (S4b, H2): Reflection resolves to its own lit arm with the
/// cell's source, offered last, labelled "Reflection" / posted as
/// "reflection"; no cavity; the source reaches a plan only under that arm.
unittest {
    ViewportDisplay d;
    d.active.style = DisplayStyle.Reflection;
    d.reflection   = ReflectionSource(ReflectionKind.MatCap, 3);
    d.cavity.mode  = CavityMode.Both;
    const p = resolveDrawPlan(d, false);
    assert(p.drawFaces && p.styleFills, "the Reflection style draws a filled surface");
    assert(p.shading == SurfaceShading.Reflection, "the Reflection style must resolve to its own arm");
    assert(p.facesLit, "the Reflection style is lit");
    assert(p.reflection == d.reflection, "the active plan carries the cell's reflection source");
    assert(p.composite.empty && p.effectFlags == 0, "Reflection takes no cavity (owner ruling)");
    const b = resolveDrawPlan(d, true);
    assert(b.shading == SurfaceShading.Reflection && b.reflection == d.reflection
        && b.dim == kBackdropDim, "a SameAsActive backdrop mirrors the Reflection arm, dimmed");
    assert(kDisplayStyleOrder[$ - 1] == DisplayStyle.Reflection,
        "Reflection is offered last, after Gooch");
    assert(displayStyleLabel(DisplayStyle.Reflection) == "Reflection"
        && displayStyleId(DisplayStyle.Reflection) == "reflection");
    // Every other style, and the retopology mode, keep the plan's source at
    // .init: the source must not move another style's dirty key.
    import std.traits : EnumMembers;
    size_t others;
    foreach (st; [EnumMembers!DisplayStyle]) foreach (retopo; [false, true]) {
        ViewportDisplay e = d;
        e.active.style = st;
        e.retopology   = retopo;
        immutable bool refl = st == DisplayStyle.Reflection && !retopo;
        assert((resolveDrawPlan(e, false).reflection == ReflectionSource.init) == !refl,
            format("style %s retopology %s: the plan's reflection source must be %s", st, retopo,
                   refl ? "the cell's" : ".init"));
        if (!refl) ++others;
    }
    assert(others == 11, format("population floor: 11 non-Reflection rows, swept %d", others));
}
