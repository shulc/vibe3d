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
    /// with a wireframe overlay. The fill colour is the viewport colour
    /// scheme's (`kSchemeSolidFill`), NOT the surface material: this style does
    /// not consult the material at all. Task 0589 shipped it reading the
    /// material and 0592 corrected that — see `kSchemeSolidFill` for the
    /// measurement and for the per-item override we do not have.
    ///
    /// Also installs no BACKDROP face pass: see `resolveDrawPlan`'s
    /// `SameAsActive` case.
    Solid,
    /// Lit surface from the material definition (diffuse / specular /
    /// glossiness). No image maps — we have none.
    Shaded,
    /// The surface coloured by the CURRENT WEIGHT MAP's per-vertex value
    /// (task 1090): neutral at zero, red toward +1, blue toward −1, clamped.
    ///
    /// REPLACES the surface pass — it is not a tint over shading, and it is
    /// not lit: the measured colour carries no light, material or gamma term
    /// (a control on the same quad, the same camera, the same run read the
    /// shaded style at `(59,59,59)` and the unshaded fill at `(153,153,153)`,
    /// while this style read the exact neutral). Drawing weights as an
    /// OVERLAY on top of another style is a separate reference control with
    /// its own switch, and so are numeric weight labels; neither is this.
    ///
    /// PER VERTEX, with the COLOUR interpolated across the face — measured,
    /// not chosen (see `weightmap_view.weightSurfaceColor`).
    ///
    /// Which map: the session's current one (`weightmap_view`), by name. None
    /// selected, or a name that does not resolve on this mesh, renders the
    /// same neutral a zero weight does — which is what was measured, and here
    /// it is reached structurally rather than by a branch.
    ///
    /// NOT the other single-component ramp that ships alongside it in the
    /// reference (`2t + 0.5(1−t)`, saturating a third of the way along). That
    /// one exists, it is adjacent, it serves other scalar channels, and it was
    /// rejected by pixels at 51/255 and 85/255.
    Weight,
}

/// How the face pass shades the surface — the SHADING half of `DisplayStyle`,
/// resolved.
///
/// Replaces `DrawPlan`'s former `bool facesLit`, which could only say two
/// things and now has three to say. Reaches GL as the lit shader's
/// `u_shading`.
enum SurfaceShading : ubyte {
    /// Blinn-Phong from the material definition. Today's `Shaded`.
    Material,
    /// A flat fill at `DrawPlan.fillColor`, consulting no material and no
    /// light. Today's `Solid`. Also what `Wireframe` resolves to — moot with
    /// no face pass, kept determinate.
    Fill,
    /// The per-vertex weight colour, interpolated, with no light term at all.
    Weight,
}

/// The order the surface styles are OFFERED in, and their UI text.
///
/// WHY THIS EXISTS. Until task 1090 the claim was that `resolveDrawPlan`'s
/// `final switch` is the compiler's gate on a new `DisplayStyle` value. It is
/// not, and the count is worth stating: `resolveDrawPlan` was the ONLY
/// `final switch` over this enum. Every other consumer was hand-listed — a
/// string switch in `prefs.d` with a SILENT `default: break` (so a persisted
/// style the parser does not know vanishes without a word), a throwing switch
/// in `commands/viewport/display.d`, and SIX `[3]`-sized static arrays across
/// two UI files. A `[3]` array with four initialisers is a compile error, so
/// the compiler would have caught the arrays — but only file by file, and only
/// if you edited that file at all. Missing one leaves the new style
/// unreachable from half the UI while every test still passes, because the
/// tests drive the command.
///
/// So the tables live here, behind two `final switch`es, and both UI surfaces
/// build their combo from `kDisplayStyleOrder`. After this, a new enum value
/// breaks the build in `displayStyleLabel`, `displayStyleId`,
/// `resolveDrawPlan` and the `static assert` below.
///
/// THE ORDER IS EXPLICIT AND IS NOT ENUM ORDER. The shipped combos read
/// Shaded, Solid, Wireframe — which is neither declaration order nor
/// alphabetical — and reordering a combo is a UI change nobody asked for.
immutable DisplayStyle[] kDisplayStyleOrder = [
    DisplayStyle.Shaded,
    DisplayStyle.Solid,
    DisplayStyle.Wireframe,
    DisplayStyle.Weight,
];

static assert(kDisplayStyleOrder.length == __traits(allMembers, DisplayStyle).length,
    "every DisplayStyle must appear in kDisplayStyleOrder — a value missing "
    ~ "from it is a value no combo offers");

/// The style's UI label (what a combo shows).
string displayStyleLabel(DisplayStyle s) pure nothrow @safe @nogc {
    final switch (s) {
        case DisplayStyle.Shaded:    return "Shaded";
        case DisplayStyle.Solid:     return "Solid";
        case DisplayStyle.Wireframe: return "Wireframe";
        case DisplayStyle.Weight:    return "Weight";
    }
}

/// The style's command-argument spelling (what `viewport.displayStyle` parses).
///
/// Lower case, and it must stay in step with that command's own switch. The
/// two are cross-checked in `tests/unit/display_state_test.d` (which may
/// import the command; this module deliberately may not).
string displayStyleId(DisplayStyle s) pure nothrow @safe @nogc {
    final switch (s) {
        case DisplayStyle.Shaded:    return "shaded";
        case DisplayStyle.Solid:     return "solid";
        case DisplayStyle.Wireframe: return "wireframe";
        case DisplayStyle.Weight:    return "weight";
    }
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

/// The unshaded fill colour of `DisplayStyle.Solid`: 0.6 grey.
///
/// This is a VIEWPORT SCHEME entry and it now lives with the rest of the
/// scheme in `viewport_scheme.d` — re-exported here so that every existing
/// `import display_state : kSchemeSolidFill;` keeps resolving. Task 0596
/// folded it in: it was the one scheme value living apart from the table, and
/// one table is the whole point. See `viewport_scheme.kSchemeSolidFill` for
/// where the value comes from and for the per-item precedence we do not yet
/// have. Value and behaviour are unchanged by the move.
public import viewport_scheme : kSchemeSolidFill;

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

/// The SHIPPED display state for a freshly-established cell, as a function of
/// its projection: orthographic cells ship lines-only, perspective cells ship
/// shaded.
///
/// WHY THIS IS A FUNCTION AND NOT A FIELD DEFAULT
/// ---------------------------------------------
/// `DisplayState`'s own field defaults are still today's behaviour, and must
/// stay that way: they are what a default-constructed `ViewportDisplay`
/// resolves to, which is the baseline half the tests in this module assert
/// against. The projection-dependent default is a property of a cell being
/// SET UP inside a layout — the layout template — not of the struct. Keeping
/// them separate is what lets "a cell nobody configured renders as it always
/// did" and "a fresh Quad ships three wireframe cells" both be true.
///
/// PROVENANCE, not a rule. This is the value a cell is BORN with, applied
/// where a layout establishes a cell's camera preset. It is emphatically NOT
/// re-applied whenever a projection changes: switching an existing cell's view
/// from Perspective to Top must not overwrite a style the user chose. The
/// reference ships these values as view TEMPLATES — the initial content of a
/// viewport — and a template is consulted when the viewport is created, not on
/// every subsequent camera change. `Viewport3D.displayUserSet` carries the
/// "someone chose this" bit that protects the other direction.
DisplayState shippedDisplayFor(bool ortho) pure nothrow @safe @nogc {
    DisplayState d;                       // Shaded / Uniform / 1.0
    if (ortho) d.style = DisplayStyle.Wireframe;
    return d;
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
///   * SHADING  — the solid surface: `drawFaces`, `facesLit`, `fillColor`,
///                `dim`
///   * OVERLAY  — what is drawn on top: `drawWire`, `wireAlpha`, `wireColor`,
///                `drawVerts`
///
/// INVARIANT, load-bearing: no selection or hover term ever appears here.
/// Selection highlight and rollover are their own axes; a plan that could turn
/// them off would make `WireOverlay.None` silently eat selection feedback.
///
/// CONSUMED TODAY — `drawFaces`, `facesLit`, `fillColor`, `drawWire`,
/// `wireAlpha`, `drawVerts`, `dim`. `wireColor` is resolved correctly and dumped by the
/// display endpoint, but no pass reads it yet (the overlay still takes its
/// colour from the edge shader's own default, and giving it a source is the
/// per-item-colour question `WireOverlay.Colored` is parked on). Do not write
/// a test that infers rendering from an unconsumed field — it would pass
/// forever.
///
/// `facesLit` joined the consumed list in task 0589, which is what made
/// `DisplayStyle.Solid` reachable; before that it was resolved and read by
/// nobody, and the command refused the style by name rather than let it
/// render as `Shaded`. `fillColor` joined it in 0592, when a read of the
/// reference's own shading machinery showed that the unshaded fill's colour
/// does not come from the material.
struct DrawPlan {
    // ---- shading -----------------------------------------------------
    /// Draw the solid surface at all. False ⇒ no face pass, not even
    /// depth-only: the model must be see-through.
    bool  drawFaces = true;
    /// How the surface is shaded. Reaches GL as the lit shader's `u_shading`.
    ///
    /// `Fill` ⇒ flat unshaded fill: the face pass runs unchanged (same
    /// geometry, same hover/selection branches) with the diffuse and specular
    /// terms removed AND the material no longer consulted, so the fill carries
    /// no information about how the surface is oriented and none about what it
    /// is made of. `Weight` ⇒ the same face pass again, taking its base colour
    /// from a per-vertex attribute instead (task 1090).
    ///
    /// This was a `bool facesLit` until task 1090 gave the axis a third value.
    /// `facesLit` survives as a derived accessor below because it is what the
    /// display endpoint reports and what several assertions read; it is no
    /// longer storage, so there is exactly one field to resolve and no way for
    /// the two to disagree.
    SurfaceShading shading = SurfaceShading.Material;
    /// Is the surface lit? DERIVED from `shading` — see above.
    ///
    /// Note what this does NOT distinguish: `Fill` and `Weight` are both
    /// "not lit", so a test that only reads this cannot tell an unshaded fill
    /// from a weight-coloured surface. Read `shading` for that.
    bool facesLit() const pure nothrow @safe @nogc {
        return shading == SurfaceShading.Material;
    }
    /// Brightness multiplier for this pass (1.0 = full).
    float dim       = 1.0f;
    /// The unshaded fill colour, read by the face pass ONLY when
    /// `facesLit == false`. Resolved always so the field is determinate; under
    /// a lit pass the shader takes its base colour from the material and this
    /// value is not observable.
    ///
    /// CONSUMED (reaches GL as the lit shader's `u_fillColor`) — unlike the
    /// sibling `wireColor`, so a test may assert rendering from it. See
    /// `kSchemeSolidFill` for where the value comes from and for the per-item
    /// override that would resolve into this field ahead of it.
    float[3] fillColor = [kSchemeSolidFill, kSchemeSolidFill, kSchemeSolidFill];

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

    // Set only by `SameAsActive` below; applied after the shading switch,
    // because it overrides what the style would otherwise resolve to.
    bool solidRunsNoBackdropFacePass = false;

    if (isBackdrop) {
        p.dim = kBackdropDim;
        final switch (d.backdropStyle) {
            case BackdropStyle.SameAsActive:
                st = d.active;
                // MEASURED CORRECTION (task 0592). In the reference's style
                // registry every shaded style installs THREE model-draw
                // sub-passes — a background one, the main one, and a
                // transparency one — while the unshaded solid style installs
                // exactly ONE, the main one. So "same as active" cannot mean
                // "run the unshaded fill a second time for the background
                // layers": running a background face pass is precisely the
                // thing that style provably does not do.
                //
                // WHICH READING THIS IS — the narrow one, deliberately. The
                // measurement establishes that the SOLID STYLE installs no
                // background face step. It does NOT establish that background
                // layers disappear, and this does not implement that: the
                // overlay axis is untouched, so background layers keep their
                // wireframe, stay visible, and stay snappable. Only the
                // backdrop's FACE pass stops.
                //
                // Scoped to `SameAsActive` on purpose. `Flat` below also
                // resolves the backdrop to `Solid`, but that is the user
                // naming a backdrop representation outright — a separate
                // registered style in the reference, not the active surface
                // style reaching across — so it keeps its fill.
                solidRunsNoBackdropFacePass =
                    (d.active.style == DisplayStyle.Solid);
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
            // Moot with no face pass; kept determinate. `Fill` and not
            // `Material` so the endpoint keeps reporting `facesLit: false`
            // here, exactly as it did when this was a bool.
            p.shading   = SurfaceShading.Fill;
            break;
        case DisplayStyle.Solid:
            p.drawFaces = true;
            p.shading   = SurfaceShading.Fill;
            break;
        case DisplayStyle.Shaded:
            p.drawFaces = true;
            p.shading   = SurfaceShading.Material;
            break;
        case DisplayStyle.Weight:
            p.drawFaces = true;
            p.shading   = SurfaceShading.Weight;
            break;
    }

    // Applied AFTER the switch, not inside it: the style resolved a face pass
    // and this withdraws it. See the `SameAsActive` case above for what the
    // measurement does and does not say.
    if (solidRunsNoBackdropFacePass) p.drawFaces = false;

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
