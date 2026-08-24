module select_visibility;

import display_state : DrawPlan;

// ---------------------------------------------------------------------------
// SELECTION-VISIBILITY POLICY — which geometry a selection gesture may reach.
//
// One global rule, evaluated against the DISPLAY STYLE of the cell the gesture
// landed in. Two independent terms come out of it:
//
//   * facingTerm    — cull geometry turned away from the eye
//   * occlusionTerm — let the drawn surface hide what is behind it
//
// WHY THIS IS NOT A `DrawPlan` FIELD, and must never become one. `DrawPlan`
// carries a load-bearing invariant in its own doc comment (`display_state.d`):
// "no selection or hover term ever appears here". The dependency runs the
// other way round — the policy READS the resolved plan. In the reference
// editor the same asymmetry is visible in the scoping: the selection rule is a
// global preference while the display style is a per-view value, and the
// per-view record carries no selection field at all.
//
// WHAT THE STYLE LINK MEANS, and why it is not "wireframe is special": under a
// style that draws no faces the far side of the model IS VISIBLE TO THE USER,
// so a picker that still models an opaque surface is answering about a scene
// that is not on screen. `drawFaces` is that fact, resolved once, on the
// rendering side.
//
// CONSUMED TODAY — `occlusionTerm` only, by the ID-buffer picker
// (`gpu_select.renderMode` runs its face depth pre-pass only when the term is
// set) and therefore by hover, click, paint and the lasso's vertex/edge half.
// See `facingTerm`'s own comment below for the rest.
// ---------------------------------------------------------------------------

/// The five values of the selection-visibility rule.
///
/// Two axes in ONE mutually-exclusive enum: the first three choose the facing
/// rule, the last two override the occlusion rule. That shape is the reference
/// editor's, kept so the value space does not need retrofitting when a command
/// or preference eventually writes it. The NAMES are ours; the mapping onto
/// the reference's own tokens lives in the private design doc and nowhere in
/// this tree.
enum SelectVisibility : ubyte {
    /// Cull back-facing geometry, EXCEPT under a style that draws no faces,
    /// where both sides are pickable. The shipped default.
    StyleAware,
    /// Never cull by facing, whatever the style.
    BothSides,
    /// Always cull by facing, whatever the style.
    FrontOnly,
    /// Occlusion always on, whatever the style. NOT REACHABLE (no writer).
    AlwaysOccluded,
    /// Occlusion always off, whatever the style. NOT REACHABLE (no writer).
    NeverOccluded,
}

/// The resolved terms, for one gesture in one cell.
struct SelectVisibilityTerms {
    /// Cull geometry turned away from the eye.
    ///
    /// RESOLVED BUT NOT CONSUMED, and that is a hazard with a guard. Its only
    /// LAWFUL future consumers are the lasso's polygon cull (`frontFacing` in
    /// `app.d`) and snap (`snap.d`) — the two places that carry a facing rule
    /// today. It MUST NEVER be wired into the click/hover path: that path is
    /// MEASURED to have no facing term at all (`CLAUDE.md` §Measured laws,
    /// `bvh_pick.d`'s characterisation unittests, and the two-sided pre-pass
    /// `gpu_select.renderMode` now enforces explicitly). A suite cell exists
    /// whose only job is to keep that true — an unoccluded BACK-FACING quad
    /// stays click-pickable in both styles (`tests/test_wireframe_select_through.d`).
    ///
    /// Do not write a test that infers rendering or picking from this field:
    /// nothing reads it, so such a test would pass forever — the same trap
    /// `DrawPlan.wireColor` documents.
    bool facingTerm;
    /// Let the drawn surface hide what is behind it. Consumed by the
    /// ID-buffer picker's face depth pre-pass.
    bool occlusionTerm;
}

/// The value the engine ships. Changing it is a behaviour change to every
/// selection gesture; owner-signed 2026-08-24.
enum SelectVisibility kSelectVisibilityDefault = SelectVisibility.StyleAware;

/// Resolve the rule against ONE cell's already-resolved draw plan.
///
/// `plan` must be the ACTIVE (foreground) plan — `resolveDrawPlan(display,
/// isBackdrop: false)`. The backdrop plan is a different question and
/// `BackdropStyle.Hidden` must never reach this function: it would read as
/// "the style draws no faces", i.e. "pick through", for geometry that is not
/// drawn at all.
///
/// | value            | facesDrawn | facingTerm | occlusionTerm |
/// |------------------|------------|------------|---------------|
/// | `StyleAware`     | true       | true       | true          |
/// | `StyleAware`     | **false**  | **false**  | **false**     |
/// | `BothSides`      | any        | false      | true          |
/// | `FrontOnly`      | any        | true       | true          |
/// | `AlwaysOccluded` | true       | true       | true          |
/// | `AlwaysOccluded` | false      | false      | true          |
/// | `NeverOccluded`  | true       | true       | false         |
/// | `NeverOccluded`  | false      | false      | false         |
///
/// The two `false`-row cells of `AlwaysOccluded` / `NeverOccluded` are OUR
/// CONTRACT, not a claim about the reference: they override the OCCLUSION term
/// only and inherit the facing term from `StyleAware`. Whether the reference's
/// equivalents also drag the facing rule into a face-less style was not
/// measured. Neither value is reachable (no writer exists), so nothing
/// observable depends on the choice — but measure before either becomes
/// reachable. Row in `doc/behavior_gap_registry.md`.
SelectVisibilityTerms resolveSelectVisibility(SelectVisibility v, in DrawPlan plan)
    pure nothrow @safe @nogc
{
    immutable bool facesDrawn = plan.drawFaces;
    SelectVisibilityTerms t;
    final switch (v) {
        case SelectVisibility.StyleAware:
            t.facingTerm    = facesDrawn;
            t.occlusionTerm = facesDrawn;
            break;
        case SelectVisibility.BothSides:
            t.facingTerm    = false;
            t.occlusionTerm = true;
            break;
        case SelectVisibility.FrontOnly:
            t.facingTerm    = true;
            t.occlusionTerm = true;
            break;
        case SelectVisibility.AlwaysOccluded:
            t.facingTerm    = facesDrawn;
            t.occlusionTerm = true;
            break;
        case SelectVisibility.NeverOccluded:
            t.facingTerm    = facesDrawn;
            t.occlusionTerm = false;
            break;
    }
    return t;
}
