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
    /// It ALSO withdraws the backdrop's face pass under `SameAsActive` — and
    /// that rule's premise is REFUTED, so do not read it as parity: the
    /// reference fills there. It survives as a registered divergence (gap
    /// registry row 96) only until task 4340 decides the visible change. The
    /// correction is argued at the site, in `resolveDrawPlan`.
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
    /// The retopology display mode's translucent face fill: the scheme's
    /// retopology face colour lit by the same light function as `Material`.
    /// APPENDED LAST — `u_shading` is this enum's ordinal. Resolved only by
    /// `applyRetopology`, never by a `DisplayStyle`.
    Retopology,
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
/// RESOLVED — this NOTE used to record it as an open question, and it is not
/// one. The reference does carry BOTH a coarse background-draw control with
/// roughly these values AND a full mirror of every active-mesh control (a
/// second surface style, a second overlay, a second opacity, ...), but they
/// are ONE system rather than two live controls or a legacy alias: the coarse
/// control is a FACADE over that same second display state. Two of its four
/// modes WRITE a display preset into the state; the other two set a standalone
/// flag beside it. So `ViewportDisplay` carrying both shapes is right for the
/// reason it was guessed, and no retrofit is owed. Read statically off the
/// reference's shipped libraries and configuration, zero engine boots, and
/// task 4340 carries the symbols and offsets. The answer is frozen — with our
/// ordinals, which are NOT the reference's — in
/// `tests/fixtures/backdrop_display_slots.json`, computed rather than asserted
/// by block A of `tests/unit/backdrop_display_slot_law_test.d`.
enum BackdropStyle : ubyte {
    /// Background layers draw exactly like the active mesh. Today's behaviour
    /// (plus our dim factor, below).
    SameAsActive,
    /// Background layers draw as lines only. A WRITER: the
    /// `viewport.backdropStyle` command also writes `Wireframe` into the
    /// backdrop slot's style, and the resolver reads that slot.
    Wireframe,
    /// Background layers draw as a lit faceted surface. A WRITER like
    /// `Wireframe`: the command writes `Shaded` into the backdrop slot's
    /// style (faceted is our only shading), and the resolver reads the slot,
    /// so a later slot-style write (`viewport.displayStyle slot=1`) is live.
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
import viewport_scheme : schemeColor, SchemeColor, kBasePointSize, MAX_POINT_SIZE,
    kRetopologyFillTransparency, kRetopologyLineAlpha, kRetopologyLightGain,
    kRetopologyVertexCulling;

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
    /// Show vertex dots whatever the style. Default off = today's behaviour.
    bool         showVertices = false;
    /// Vertex dot size in pixels; 0 (or any non-positive / non-finite value)
    /// means the scheme's `kBasePointSize`.
    float        pointSize = 0.0f;
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
    /// The retopology display mode: one override over BOTH resolved plans,
    /// applied by `applyRetopology` after the style switch. Deliberately not
    /// a `DisplayStyle` value — under the mode the active style does not
    /// change the foreground's drawing at all, yet it still decides picking
    /// occlusion (`DrawPlan.styleFills`). Per cell; off by default.
    bool retopology = false;
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
/// `wireAlpha`, `wireColor`, `drawVerts`, `dim`, and the retopology fields
/// below. Do not write a test that infers rendering from an unconsumed field —
/// it would pass forever.
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
    /// CONSUMED (reaches GL as the lit shader's `u_fillColor`), so a test may
    /// assert rendering from it. See
    /// `kSchemeSolidFill` for where the value comes from and for the per-item
    /// override that would resolve into this field ahead of it.
    float[3] fillColor = [kSchemeSolidFill, kSchemeSolidFill, kSchemeSolidFill];

    // ---- overlay -----------------------------------------------------
    /// Draw the base wireframe over the surface.
    bool     drawWire  = true;
    /// Overlay opacity, 0..1.
    float    wireAlpha = 1.0f;
    /// Base (unselected) line colour. CONSUMED since task 8600: the base line
    /// pass takes it through `BaseWire.color` (shaded per item when
    /// `shadeLinesByItem`); the default is the scheme row that pass drew in
    /// before, so a mode-off frame is byte-identical.
    float[3] wireColor = [schemeColor(SchemeColor.wireframe).x,
                          schemeColor(SchemeColor.wireframe).y,
                          schemeColor(SchemeColor.wireframe).z];
    /// The style FORCES vertex dots on, independently of edit mode. False for
    /// every style except `Wireframe`, which draws vertices as well as edges.
    ///
    /// This is a forcing term, not a permission: the ordinary "show the
    /// vertex dots in vertex edit mode" behaviour is a separate, unmodelled
    /// axis and stays where it is. The renderer ORs the two.
    bool     drawVerts = false;

    // ---- retopology-mode fields ------------------------------------------
    // Every default below is TODAY'S behaviour; only `applyRetopology` moves
    // them. `styleFills` is read by `select_visibility`, `lightGain` is the
    // lit program's `u_lightGain`, and the face pass (`facePassFor`) reads
    // `faceAlpha`, `cullBackFaces`, `reverseFaceOrder` and `clearDepthFirst`.
    // Measured values and their record: the constants block in
    // `viewport_scheme.d` and `tests/fixtures/retopology_display.json`.
    /// Face pass opacity (1 = opaque).
    float    faceAlpha = 1.0f;
    /// Cull back-facing polygons in the face pass.
    bool     cullBackFaces = false;
    /// Submit the face pass in reverse polygon index order (captured: the
    /// translucent fill is one depth-writing pass in reverse polygon order).
    bool     reverseFaceOrder = false;
    /// Clear the depth buffer before this item's passes.
    bool     clearDepthFirst = false;
    /// Multiplier on the lit term above ambient (1 = today's light).
    float    lightGain = 1.0f;
    /// Base (unselected) vertex dot colour, consumed through `BaseDots.color`.
    /// Defaults to the wireframe row the dot pass always drew in.
    float[3] vertColor = [schemeColor(SchemeColor.wireframe).x,
                          schemeColor(SchemeColor.wireframe).y,
                          schemeColor(SchemeColor.wireframe).z];
    /// Base vertex dot opacity.
    float    vertAlpha = 1.0f;
    /// Base vertex dot size in pixels, resolved (never 0).
    float    pointSize = kBasePointSize;
    /// Skip base dots whose every incident polygon faces away.
    bool     cullHiddenVerts = false;
    /// Base wire / dot colours are shaded per item by the light function.
    bool     shadeLinesByItem = false;
    /// The base-dot pass also runs because of the vertex / edge selection
    /// type (today's OR). A policy bit about the base pass, NOT a selection
    /// term, so the no-selection invariant above holds.
    bool     baseDotsBySelection = true;
    /// Backdrop plan only: background layers are drawn inside the
    /// foreground item sequence instead of before it.
    bool     joinsItemSequence = false;
    /// Does the resolved STYLE fill faces? Equal to `drawFaces` as the style
    /// switch left it, BEFORE any mode override, and never written by
    /// `applyRetopology`: picking occlusion follows the active style whether
    /// or not the mode is on (captured; `select_visibility` reads this).
    bool     styleFills = true;
}

/// A cell's vertex dot size as the plan carries it: a non-positive or
/// non-finite request means the scheme's `kBasePointSize`; anything else is
/// clamped to `[1, MAX_POINT_SIZE]` (the command clamps too; this is the
/// kernel's own ceiling, so no route can scale the dot past it).
float resolvePointSize(float requested) pure nothrow @safe @nogc
{
    import std.math : isFinite;
    if (!isFinite(requested) || requested <= 0.0f) return kBasePointSize;
    if (requested < 1.0f) return 1.0f;
    if (requested > MAX_POINT_SIZE) return MAX_POINT_SIZE;
    return requested;
}

/// The face-pass opacity of the retopology fill at transparency `t`: the
/// measured law `1 - t` (fixture `face.alpha_law`, its `cells_alpha` rows).
float retopologyFaceAlpha(float t) pure nothrow @safe @nogc
{
    return 1.0f - t;
}

/// The retopology display mode, applied to an already style-resolved plan.
///
/// ONE override instead of a fifth style or a renderer-side branch: every
/// field the mode owns is written here, so the renderer stays a plain reader
/// of `DrawPlan`. A no-op when `d.retopology` is false. The active side takes
/// the mode's whole representation whatever the style (the style is
/// irrelevant to the foreground's pixels under the mode); the backdrop side
/// gains the light multiplier, and under `SameAsActive` it becomes an item of
/// the foreground sequence: undimmed (owner decision D6 — mode off keeps the
/// dim), drawn with no depth clear of its own, with ordinary base dots when
/// show-vertices is on (captured; plan §10.3 / §10.9 item 5). `styleFills` is
/// left as the style resolved it, and `pointSize` as the size resolved it.
void applyRetopology(ref DrawPlan p, in ViewportDisplay d, bool isBackdrop)
    pure nothrow @safe @nogc
{
    if (!d.retopology) return;
    p.lightGain = kRetopologyLightGain;
    if (isBackdrop) {
        if (d.backdropStyle == BackdropStyle.SameAsActive) {
            p.dim                 = 1.0f;
            p.joinsItemSequence   = true;
            p.drawVerts           = d.active.showVertices;
            p.baseDotsBySelection = false;
        }
        return;
    }

    immutable face = schemeColor(SchemeColor.retopologyFace);
    immutable edge = schemeColor(SchemeColor.retopologyEdge);
    immutable vert = schemeColor(SchemeColor.retopologyVertex);

    p.drawFaces           = true;
    p.shading             = SurfaceShading.Retopology;
    p.fillColor           = [face.x, face.y, face.z];
    p.faceAlpha           = retopologyFaceAlpha(kRetopologyFillTransparency);
    p.cullBackFaces       = true;
    p.reverseFaceOrder    = true;
    p.clearDepthFirst     = true;
    p.drawWire            = true;
    p.wireColor           = [edge.x, edge.y, edge.z];
    p.wireAlpha           = kRetopologyLineAlpha;
    p.drawVerts           = d.active.showVertices;
    p.vertColor           = [vert.x, vert.y, vert.z];
    p.vertAlpha           = kRetopologyLineAlpha;
    p.cullHiddenVerts     = kRetopologyVertexCulling;
    p.shadeLinesByItem    = true;
    p.baseDotsBySelection = false;
}

/// Resolve `d` into the plan for one pass: the active mesh, or the backdrop.
///
/// Pure and GL-free — this is where the display model's facts live, and it is
/// unit-testable without a window.
///
/// Backdrop precedence: `SameAsActive` ignores `d.backdrop` and mirrors
/// `d.active` (plus our dim); `Hidden` draws nothing; `Wireframe` and `Flat`
/// read the backdrop slot WHOLE, style included. The coarse control is a
/// writer of that slot (the command writes the style), not a second axis read
/// here — the frozen record is `tests/fixtures/backdrop_display_slots.json`
/// (`coarse_control`), and neither mode is dimmed (its `brightness` law).
DrawPlan resolveDrawPlan(in ViewportDisplay d, bool isBackdrop) pure nothrow @safe @nogc {
    DrawPlan p;

    DisplayState st = d.active;

    // Set only by `SameAsActive` below; applied after the shading switch,
    // because it overrides what the style would otherwise resolve to.
    bool solidRunsNoBackdropFacePass = false;

    if (isBackdrop) {
        final switch (d.backdropStyle) {
            case BackdropStyle.SameAsActive:
                p.dim = kBackdropDim;
                st = d.active;
                // PREMISE REFUTED — it came from task 0592, and task 4340
                // carries the read that supersedes it. What follows is a
                // DIVERGENCE WE STILL SHIP, not parity, and block C2 of
                // `tests/unit/backdrop_display_slot_law_test.d` pins it as
                // one. Gap registry row 96 is its entry.
                //
                // The table 0592 read is real: in the reference's style
                // registry every shaded style installs THREE model-draw
                // sub-passes — a background one, the main one, and a
                // transparency one — while the unshaded solid style installs
                // exactly ONE, the main one. The INFERENCE from it was
                // backwards. Read at the caller that actually draws a
                // non-foreground layer: the "background" sub-pass is the pass
                // that meshes in the BACKGROUND SLOT draw in, and "same as
                // active" folds that slot into the active one BEFORE the pass
                // gate. So under exactly the configuration this branch is
                // scoped to, no mesh is in that slot, the background sub-pass
                // draws nothing whatever the style, and background layers draw
                // in the MAIN pass with the ACTIVE state. The reference FILLS
                // here; we withdraw the fill. Removing it is a visible
                // appearance change, so it is the owner's call, which is what
                // 4340 is for — not a reflex inside a capture lane.
                //
                // DO NOT WIDEN IT to the weight style. That style has the same
                // one-sub-pass shape, so the extension looks justified; it is
                // the move gap registry row 45 forbids by name, and block B of
                // the same reader reddens on it.
                //
                // Scoped to `SameAsActive` on purpose. `Flat` and
                // `Wireframe` below read the backdrop slot, which the user
                // set outright — not the active surface style reaching
                // across — so a `Solid` slot there keeps its fill.
                solidRunsNoBackdropFacePass =
                    (d.active.style == DisplayStyle.Solid);
                break;
            case BackdropStyle.Wireframe:
            case BackdropStyle.Flat:
                st = d.backdrop;
                break;
            case BackdropStyle.Hidden:
                p.drawFaces  = false;
                p.styleFills = false;
                p.drawWire   = false;
                p.drawVerts  = false;
                applyRetopology(p, d, isBackdrop);
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
    p.drawVerts = (st.style == DisplayStyle.Wireframe) || st.showVertices;
    p.pointSize = resolvePointSize(st.pointSize);

    if (isBackdrop) {
        // The backdrop pass has no vertex-dot draw today. Resolve it to false
        // rather than leave a truthful-but-unconsumed value that a later test
        // could be written against and pass forever. When a backdrop vertex
        // pass is added, resolve this from the style exactly as above.
        p.drawVerts = false;
    }

    // Before the mode override, and never written by it: picking follows
    // the style, not the mode (see `DrawPlan.styleFills`).
    p.styleFills = p.drawFaces;
    applyRetopology(p, d, isBackdrop);
    return p;
}

// ---------------------------------------------------------------------------
// Truth table + composition-property unittests
// ---------------------------------------------------------------------------
