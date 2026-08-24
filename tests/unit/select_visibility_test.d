// THE SELECTION-VISIBILITY TRUTH TABLE — all eight rows of the resolver, plus
// the two facts that make the table mean anything:
//
//   * the shipped default is `StyleAware` (a behaviour promise, not a detail),
//   * `drawFaces == false` is reached by exactly ONE display style, and it is
//     reached through `resolveDrawPlan` rather than by a hand-built plan — so
//     a style whose plan stopped drawing faces (or started) shows up here.
//
// This file asserts the FUNCTION, never engine behaviour: the resolver is pure
// and has no way to know whether anybody honours what it returns. The wiring
// is proven by the suite test `tests/test_wireframe_select_through.d`, which
// drives real picks; a green table here says nothing about it.
module tests.unit.select_visibility_test;

import std.format : format;

import display_state    : DisplayStyle, DrawPlan, ViewportDisplay, resolveDrawPlan;
import select_visibility;

private DrawPlan planFor(DisplayStyle s) {
    ViewportDisplay d;
    d.active.style = s;
    return resolveDrawPlan(d, /*isBackdrop=*/false);
}

private DrawPlan bareplan(bool facesDrawn) {
    DrawPlan p;
    p.drawFaces = facesDrawn;
    return p;
}

unittest {
    // The default is a promise: `StyleAware` is what makes the style link
    // live at all. Every other value ignores the style on at least one axis.
    assert(kSelectVisibilityDefault == SelectVisibility.StyleAware,
        "the shipped selection-visibility default must be StyleAware; got "
        ~ format("%s", kSelectVisibilityDefault));
}

unittest {
    // The style half of the link, read through the real resolver rather than
    // assumed: exactly one shipped style draws no faces.
    assert(!planFor(DisplayStyle.Wireframe).drawFaces,
        "the wireframe style must resolve to drawFaces == false — the whole "
        ~ "style link hangs on it");
    foreach (s; [DisplayStyle.Solid, DisplayStyle.Shaded, DisplayStyle.Weight])
        assert(planFor(s).drawFaces,
            format("%s must draw faces; if it stopped, picking through it "
                   ~ "became reachable and that is a product decision", s));
}

unittest {
    // ---- the eight rows -------------------------------------------------
    // Read as: (value, facesDrawn) -> (facingTerm, occlusionTerm).
    static struct Row {
        SelectVisibility v;
        bool facesDrawn;
        bool facing;
        bool occlusion;
        string why;
    }
    static immutable Row[] rows = [
        Row(SelectVisibility.StyleAware, true,  true,  true,
            "faces are drawn, so the surface both hides and orients"),
        Row(SelectVisibility.StyleAware, false, false, false,
            "THE ROW THIS FEATURE SHIPS: no faces drawn, so neither term applies"),
        Row(SelectVisibility.BothSides,  true,  false, true,
            "never culls by facing, regardless of style"),
        Row(SelectVisibility.BothSides,  false, false, true,
            "regardless of style means the face-less style too"),
        Row(SelectVisibility.FrontOnly,  true,  true,  true,
            "always culls by facing, regardless of style"),
        Row(SelectVisibility.FrontOnly,  false, true,  true,
            "regardless of style means the face-less style too"),
        Row(SelectVisibility.AlwaysOccluded, true,  true,  true,
            "occlusion pinned on; facing inherited from StyleAware"),
        Row(SelectVisibility.AlwaysOccluded, false, false, true,
            "OUR CONTRACT, unmeasured: occlusion pinned on, facing still follows the style"),
        Row(SelectVisibility.NeverOccluded,  true,  true,  false,
            "occlusion pinned off; facing inherited from StyleAware"),
        Row(SelectVisibility.NeverOccluded,  false, false, false,
            "OUR CONTRACT, unmeasured: occlusion pinned off, facing still follows the style"),
    ];

    foreach (r; rows) {
        auto t = resolveSelectVisibility(r.v, bareplan(r.facesDrawn));
        assert(t.facingTerm == r.facing,
            format("%s with drawFaces=%s: facingTerm expected %s, got %s — %s",
                   r.v, r.facesDrawn, r.facing, t.facingTerm, r.why));
        assert(t.occlusionTerm == r.occlusion,
            format("%s with drawFaces=%s: occlusionTerm expected %s, got %s — %s",
                   r.v, r.facesDrawn, r.occlusion, t.occlusionTerm, r.why));
    }
}

unittest {
    // The default, resolved against the two styles that matter, stated as the
    // product behaviour rather than as a table lookup. A mutation that flips
    // the `StyleAware` + face-less row reddens HERE with the sentence that
    // says what the user would see.
    auto shaded = resolveSelectVisibility(kSelectVisibilityDefault,
                                          planFor(DisplayStyle.Shaded));
    assert(shaded.occlusionTerm,
        "in a shaded cell the surface must still hide what is behind it");

    auto wire = resolveSelectVisibility(kSelectVisibilityDefault,
                                        planFor(DisplayStyle.Wireframe));
    assert(!wire.occlusionTerm,
        "in a wireframe cell nothing is drawn to hide anything: a vertex or "
        ~ "edge behind the surface must stay pickable");
    assert(!wire.facingTerm,
        "in a wireframe cell both sides of the model are on screen, so the "
        ~ "facing term must be off too");
}

unittest {
    // `pure @nogc` is part of the contract — the resolver is called per pick
    // and per lasso element. A CTFE evaluation proves purity the way a
    // signature alone cannot.
    enum SelectVisibilityTerms ctWire =
        resolveSelectVisibility(SelectVisibility.StyleAware,
                                planFor(DisplayStyle.Wireframe));
    static assert(!ctWire.occlusionTerm && !ctWire.facingTerm,
        "the default against the wireframe plan must resolve to 'pick "
        ~ "through' at COMPILE TIME — both the resolver and resolveDrawPlan "
        ~ "are pure");
}
