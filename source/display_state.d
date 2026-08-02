module display_state;

// ---------------------------------------------------------------------------
// Per-viewport display model — the resolved description of what a scene pass
// is allowed to draw.
//
// Task 0559 Phase 1, doc/viewport_display_modes_plan.md.
//
// WHY THIS FILE EXISTS AT ALL
// ---------------------------
// Until now the renderer drew the mesh exactly one way, and every pass was
// unconditional: faces always, edges always, background layers always (the
// same two passes, dimmed). There was no object anywhere in the codebase that
// described "what this viewport is supposed to draw", so there was also no way
// to test a drawing change except by looking at it.
//
// This module introduces that object. The rule the rest of the phases lean on:
//
//     the renderer must be structurally unable to draw what the plan does
//     not describe.
//
// So the state lives here (`ViewportDisplay`), the resolution lives here
// (`resolveDrawPlan`, pure and GL-free), and the renderer consumes only
// `DrawPlan`. An HTTP endpoint dumping the same `DrawPlan` the renderer
// consumes is then a real assertion about drawing rather than a parallel
// re-derivation that can silently drift.
//
// TWO AXES, NOT ONE — AND THEY COMPOSE
// ------------------------------------
// The surface style (what the solid geometry looks like) and the wireframe
// overlay (whether, and how, lines are drawn on top of it) are INDEPENDENT
// controls with separate value spaces. They are not two values of one enum.
// So `DrawPlan` is split into two labelled groups below, and the composition
// property is pinned by unittest: changing the surface style must not disturb
// the overlay group except through the single forcing relation described in
// `DisplayStyle.Wireframe`.
//
// WHAT DELIBERATELY DOES NOT LIVE HERE
// ------------------------------------
// Selection highlight, hover feedback, smooth-vs-flat shading, cages, guides,
// the grid, the workplane and the backdrop image are each their OWN axis. None
// of them may ever become a `DrawPlan` field. Concretely: `drawWire == false`
// must not suppress selected-edge or hovered-edge feedback — that is the
// obvious wrong implementation of the overlay axis and it is a named risk.
// ---------------------------------------------------------------------------

/// Surface style: what the solid geometry looks like.
///
/// Deliberately a SUBSET, declared so it grows. The wider set found in the
/// reference read is mostly a texture ladder (styles that differ only by how
/// much image-map data they consume) plus a vertex-map shading path, two
/// programmable shaders and a separate deferred renderer. We have no texture
/// sampling in any surface shader at all, so those styles have no plumbing to
/// reuse and collapse onto materials-only Blinn-Phong — which is exactly what
/// `Shaded` is. The AXIS STRUCTURE is faithful; only the value set is a
/// subset. See the plan's D1.
enum DisplayStyle : ubyte {
    /// Lines only. Faces are NOT drawn — not even depth-only — so the model
    /// is see-through and back-side edges remain visible. This is line soup,
    /// not hidden-line removal. Forces the overlay on (a wireframe style with
    /// the overlay set to `None` must not produce an empty viewport) and also
    /// shows vertex dots, because this style draws vertices *and* the edges
    /// that connect them.
    Wireframe,
    /// Solid fill with NO shading — a flat sketch fill, most useful combined
    /// with a wireframe overlay. Our fill colour comes from the per-face
    /// surface `baseColor` we already upload; the reference takes it from a
    /// global preference. Recorded, minor, deliberate divergence.
    Solid,
    /// Lit surface from the material definition (diffuse / specular /
    /// glossiness). No image maps — we have none.
    Shaded,
}

/// Wireframe-overlay style: whether, and how, lines are drawn over the
/// surface. A separate axis from `DisplayStyle`, with its own value space.
enum WireOverlay : ubyte {
    /// No overlay. Selection and hover feedback are NOT part of this axis and
    /// must survive it.
    None,
    /// One colour for every line. Today's behaviour.
    Uniform,
    /// A per-item colour. NOT reachable yet: the colour source is an open
    /// question and we have no per-item colour to resolve it from (a layer
    /// carries a transform and channels, but no colour). Declared so the
    /// value space is right; deferred rather than guessed.
    Colored,
}

/// How background (visible-but-unselected) layers are represented.
///
/// "Background" here is exactly our existing document predicate — visible and
/// not selected — which coincides with the reference's own definition, so this
/// axis needs no new notion of foreground/background.
///
/// NOTE, open question: the reference carries BOTH a coarse background-draw
/// control with roughly these values AND a full mirror of every active-mesh
/// control (a second surface style, a second overlay, a second opacity, ...).
/// Whether those are two live controls or one legacy alias is not decidable
/// from the material mined so far. `ViewportDisplay` carries both shapes so
/// neither answer costs a retrofit; the precedence taken meanwhile is
/// documented on `resolveDrawPlan`.
enum BackdropStyle : ubyte {
    /// Background layers draw exactly like the active mesh. Today's behaviour
    /// (plus our dim factor, below).
    SameAsActive,
    /// Background layers draw as lines only.
    Wireframe,
    /// Background layers draw as unshaded solid fill.
    Flat,
    /// Background layers are not drawn at all — "solo" the active layer.
    Hidden,
}

/// Brightness multiplier applied to background layers under
/// `BackdropStyle.SameAsActive`.
///
/// OURS, not the reference's: the reference distinguishes background layers by
/// giving them a genuinely different representation, not by dimming one. We
/// keep the dim so that today's appearance survives this refactor unchanged.
/// Recorded as a deliberate divergence (the plan's D3). Was a local constant
/// in the renderer; it moves here because it is now an output of resolution.
enum float kBackdropDim = 0.45f;

/// One activity state's controls — the active mesh, or the backdrop.
///
/// Defaults are TODAY'S BEHAVIOUR, deliberately: a default-constructed
/// `ViewportDisplay` must resolve to the exact set of passes the renderer ran
/// before this model existed, so that introducing it changes no pixels.
struct DisplayState {
    DisplayStyle style     = DisplayStyle.Shaded;
    WireOverlay  wire      = WireOverlay.Uniform;
    /// Overlay opacity, 0..1. Default 1.0 = today's fully opaque lines. The
    /// reference ships a much fainter default; adopting it would change what
    /// every existing viewport looks like and is held for an explicit
    /// decision.
    float        wireAlpha = 1.0f;
}

/// The complete display state of ONE viewport cell.
///
/// Carries the ACTIVITY AXIS from the outset — `active` and `backdrop` are two
/// full control sets, not one set plus a dimming factor — even though only the
/// active side is resolved to anything but today's behaviour today. That is a
/// decision of record: the reference carries a full parallel control set for
/// the backdrop, its foreground/background definition is identical to ours,
/// modelling it now is free, and retrofitting it later would touch this
/// struct, the dirty key, the prefs schema, the command set, the endpoint
/// payload and every test that asserts a plan.
struct ViewportDisplay {
    /// Controls for foreground (selected + visible) geometry.
    DisplayState  active;
    /// Controls for background (visible, not selected) geometry. Reserved for
    /// the backdrop phase; see `resolveDrawPlan` for exactly which of its
    /// fields are read today.
    DisplayState  backdrop;
    /// Coarse backdrop representation. `SameAsActive` (the default) reproduces
    /// today's look.
    BackdropStyle backdropStyle = BackdropStyle.SameAsActive;
}

/// The RESOLVED description of one scene pass: what it may draw, and how.
///
/// This is the only display input the renderer sees. Two labelled groups,
/// because the two axes compose rather than exclude each other:
///
///   * SHADING  — the solid surface: `drawFaces`, `facesLit`, `dim`
///   * OVERLAY  — what is drawn on top: `drawWire`, `wireAlpha`, `wireColor`,
///                `drawVerts`
///
/// INVARIANT, load-bearing: no selection or hover term ever appears here.
/// Selection highlight and rollover are their own axes; a plan that could turn
/// them off would make `WireOverlay.None` silently eat selection feedback.
///
/// CONSUMED TODAY — `drawFaces`, `facesLit`, `drawWire`, `wireAlpha`,
/// `drawVerts`, `dim`. `wireColor` is resolved correctly and dumped by the
/// display endpoint, but no pass reads it yet (the overlay still takes its
/// colour from the edge shader's own default, and giving it a source is the
/// per-item-colour question `WireOverlay.Colored` is parked on). Do not write
/// a test that infers rendering from an unconsumed field — it would pass
/// forever.
///
/// `facesLit` joined the consumed list in task 0589, which is what made
/// `DisplayStyle.Solid` reachable; before that it was resolved and read by
/// nobody, and the command refused the style by name rather than let it
/// render as `Shaded`.
struct DrawPlan {
    // ---- shading -----------------------------------------------------
    /// Draw the solid surface at all. False ⇒ no face pass, not even
    /// depth-only: the model must be see-through.
    bool  drawFaces = true;
    /// Light the surface. False ⇒ flat unshaded fill: the face pass runs
    /// unchanged (same geometry, same material colours, same hover/selection
    /// branches) with the diffuse and specular terms removed, so the fill
    /// carries no information about how the surface is oriented. Reaches GL
    /// as the lit shader's `u_lit`.
    bool  facesLit  = true;
    /// Brightness multiplier for this pass (1.0 = full).
    float dim       = 1.0f;

    // ---- overlay -----------------------------------------------------
    /// Draw the base wireframe over the surface.
    bool     drawWire  = true;
    /// Overlay opacity, 0..1.
    float    wireAlpha = 1.0f;
    /// Overlay line colour. Defaults to the colour the edge pass already
    /// uses, so resolving it changes nothing.
    float[3] wireColor = [0.9f, 0.9f, 0.9f];
    /// The style FORCES vertex dots on, independently of edit mode. False for
    /// every style except `Wireframe`, which draws vertices as well as edges.
    ///
    /// This is a forcing term, not a permission: the ordinary "show the
    /// vertex dots in vertex edit mode" behaviour is a separate, unmodelled
    /// axis and stays where it is. The renderer ORs the two.
    bool     drawVerts = false;
}

/// Resolve `d` into the plan for one pass: the active mesh, or the backdrop.
///
/// Pure and GL-free — this is where the display model's facts live, and it is
/// unit-testable without a window.
///
/// Backdrop precedence, and the open question it brushes against: the coarse
/// `backdropStyle` is the control that decides. `SameAsActive` ignores
/// `d.backdrop` entirely and mirrors `d.active` (plus our dim); `Hidden` draws
/// nothing; `Wireframe`/`Flat` name a surface style outright and take the
/// remaining knobs (overlay, opacity) from `d.backdrop`. So `d.backdrop.style`
/// is carried but not read. If the coarse control and the backdrop's own style
/// turn out to be genuinely independent, the fix is a new `BackdropStyle`
/// value that defers to `d.backdrop.style` — a change to this function only,
/// not to the schema. That is why both shapes are carried.
DrawPlan resolveDrawPlan(in ViewportDisplay d, bool isBackdrop) pure nothrow @safe @nogc {
    DrawPlan p;

    DisplayState st = d.active;

    if (isBackdrop) {
        p.dim = kBackdropDim;
        final switch (d.backdropStyle) {
            case BackdropStyle.SameAsActive:
                st = d.active;
                break;
            case BackdropStyle.Wireframe:
                st       = d.backdrop;
                st.style = DisplayStyle.Wireframe;
                break;
            case BackdropStyle.Flat:
                st       = d.backdrop;
                st.style = DisplayStyle.Solid;
                break;
            case BackdropStyle.Hidden:
                p.drawFaces = false;
                p.drawWire  = false;
                p.drawVerts = false;
                return p;
        }
    }

    // ---- shading group ----
    final switch (st.style) {
        case DisplayStyle.Wireframe:
            p.drawFaces = false;
            p.facesLit  = false;   // moot with no face pass; kept determinate
            break;
        case DisplayStyle.Solid:
            p.drawFaces = true;
            p.facesLit  = false;
            break;
        case DisplayStyle.Shaded:
            p.drawFaces = true;
            p.facesLit  = true;
            break;
    }

    // ---- overlay group ----
    // Composes over the shading group; the ONE coupling is that a lines-only
    // style must still produce lines, so it forces the overlay on.
    p.drawWire  = (st.wire != WireOverlay.None)
               || (st.style == DisplayStyle.Wireframe);
    p.wireAlpha = st.wireAlpha;
    p.drawVerts = (st.style == DisplayStyle.Wireframe);

    if (isBackdrop) {
        // The backdrop pass has no vertex-dot draw today. Resolve it to false
        // rather than leave a truthful-but-unconsumed value that a later test
        // could be written against and pass forever. When a backdrop vertex
        // pass is added, resolve this from the style exactly as above.
        p.drawVerts = false;
    }

    return p;
}

// ---------------------------------------------------------------------------
// Truth table + composition-property unittests
// ---------------------------------------------------------------------------

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
