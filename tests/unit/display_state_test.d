// Module unittests for `display_state`, moved verbatim out of source/display_state.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.display_state_test;

public import viewport_scheme : kSchemeSolidFill;
import display_state;

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
    // Backdrop axis truth table. Only `SameAsActive` is reachable today (no
    // command sets it), but the resolution is the schema, so it is pinned.
    ViewportDisplay d;

    d.backdropStyle = BackdropStyle.Hidden;
    auto b = resolveDrawPlan(d, true);
    assert(!b.drawFaces && !b.drawWire && !b.drawVerts,
        "Hidden must draw nothing at all");

    d.backdropStyle = BackdropStyle.Wireframe;
    b = resolveDrawPlan(d, true);
    assert(!b.drawFaces, "backdrop Wireframe draws no faces");
    assert(b.drawWire,   "backdrop Wireframe draws lines");

    d.backdropStyle = BackdropStyle.Flat;
    b = resolveDrawPlan(d, true);
    assert(b.drawFaces,  "backdrop Flat draws a filled surface");
    assert(!b.facesLit,  "backdrop Flat is unshaded");

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
    const fb = resolveDrawPlan(f, true);
    assert(fb.drawFaces && !fb.facesLit,
        "an explicitly chosen flat backdrop keeps its fill — the suppression "
        ~ "is scoped to SameAsActive inheritance");
}
