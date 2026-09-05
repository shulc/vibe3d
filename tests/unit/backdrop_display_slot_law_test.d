// Frozen-fixture cell for how the reference editor draws a NON-FOREGROUND
// (background) layer, and what that means under the weight surface style
// (capture campaign batch A', 2026-09-05). Read statically off the reference's
// own shipped libraries and resource configuration; zero engine boots.
//
// WHY IT EXISTS. The register's row for this law forbade, by name, deriving
// the answer from a colour property -- the move that produced
// `solidRunsNoBackdropFacePass` -- and asked instead for the CALLER that draws
// a non-foreground layer. Read at that caller, the mechanism is:
//
//   * there are TWO complete display states per viewport, indexed by a slot
//     the item's own foreground bit selects;
//   * the model draw is gated by pass -- the background pass draws only
//     slot-1 meshes, the main pass only slot-0 ones;
//   * "same as active" folds slot 1 to slot 0 BEFORE that gate, so under it
//     every mesh draws in the MAIN pass with the active state;
//   * there is NO brightness multiplier anywhere on the path.
//
// So the row's headline question -- two layers, one background, active style =
// the weight style, does the background layer's surface fill? -- answers YES,
// undimmed, and our resolver already answers that. What does NOT survive is
// `solidRunsNoBackdropFacePass`: it reads the sub-pass COUNT correctly and
// applies it to the one configuration in which that sub-pass is never used.
//
// WHAT EACH BLOCK IS. Read the labels, because they are not all the same kind
// of claim:
//
//   A  the frozen law's own shape and arithmetic  -- must stay green;
//   B  PARITY: our backdrop under the weight style fills, is weight-shaded,
//      and keeps its overlay                      -- must stay green;
//   C  DIVERGENCE PINS, not parity. Two of them, and both assert what WE do
//      while naming what the reference does. They exist because a deliberate
//      divergence with no test is indistinguishable from an accident -- and
//      because the second one is REFUTED and must not be quietly widened
//      while it waits for its own task.
//
// ORDERING IS LOAD-BEARING. A and B sit above C, so a mutation that reddens a
// C pin still demonstrates that the parity half ran and passed: everything
// above the first red line executed.
//
// MUTATIONS THAT REDDEN IT (both run and quoted in the task card):
//   * `source/display_state.d`: widen the solid rule to the weight style
//     (`d.active.style == DisplayStyle.Solid || d.active.style ==
//     DisplayStyle.Weight`) => block B reddens naming the fill. That is the
//     exact move the register's row forbids;
//   * `source/display_state.d`: `kBackdropDim` 0.45f -> 1.0f => block C1
//     reddens naming both numbers.
//
// LANE: `dub test --config=tests`.
module tests.unit.backdrop_display_slot_law_test;

import std.file      : readText;
import std.format    : format;
import std.json      : JSONType, JSONValue, parseJSON;
import std.math      : abs;
import std.path      : buildPath, dirName;

import display_state : BackdropStyle, DisplayState, DisplayStyle, DrawPlan,
                       SurfaceShading, ViewportDisplay, WireOverlay,
                       kBackdropDim, resolveDrawPlan;

private enum string kFixturePath =
    buildPath(dirName(dirName(__FILE_FULL_PATH__)), "fixtures",
              "backdrop_display_slots.json");

private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(readText(kFixturePath)); loaded = true; }
    return cached;
}

private double asDouble(JSONValue v)
{
    switch (v.type)
    {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

// ---------------------------------------------------------------------------
// A. The frozen law's shape. Population floors first: every claim below is
//    over a set, and a fixture that lost a block would satisfy them empty.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    assert(f["name"].str == "backdrop_display_slots",
           "fixture: wrong file loaded from " ~ kFixturePath);
    assert(f["provenance"]["method"].str == "static-read");

    auto slots = f["display_slots"];
    assert(slots["slot_count"].integer == 2,
           "fixture: the whole mechanism is TWO display states; one state "
           ~ "cannot express a background layer at all");
    assert(slots["active_slot"].integer == 0 && slots["inactive_slot"].integer == 1);
    assert(slots["mirrored_controls"].array.length
               == slots["mirrored_control_count"].integer,
           "fixture: the mirrored-control list and its count disagree");
    assert(slots["mirrored_control_count"].integer >= 10,
           format("fixture: %d mirrored controls is too few to support "
                  ~ "'a full second display state'",
                  slots["mirrored_control_count"].integer));

    // The gate, and the fold that makes it answer the row's question.
    auto gate = f["draw_gate"];
    assert(gate["background_pass_draws_slot"].integer == 1);
    assert(gate["main_pass_draws_slot"].integer == 0);
    assert(gate["same_as_active_folds_slot_before_the_gate"].boolean,
           "fixture: the fold's POSITION is the whole finding -- folded after "
           ~ "the gate it would mean the opposite");
    assert(gate["under_same_as_active_background_meshes_draw_in_the_main_pass"].boolean);

    // The sub-pass table, and the reading it does NOT support.
    auto sp = f["style_registry_subpasses"];
    assert(sp["shaded_style_subpass_count"].integer == 3);
    assert(sp["solid_style_subpass_count"].integer == 1);
    assert(sp["weight_style_subpass_count"].integer == 1,
           "fixture: the weight style has the same one-sub-pass shape as the "
           ~ "solid one -- which is why extending the solid rule to it would "
           ~ "look justified and be wrong");
    assert(sp["background_subpass_is_the_slot_1_pass"].boolean);

    // The four coarse modes, on both sides, with their DECLARED ORDER frozen
    // separately: they correspond one-to-one and their ordinals differ.
    auto cc = f["coarse_control"];
    assert(cc["mode_count"].integer == 4);
    auto refOrd  = cc["reference_mode_ordinals"];
    auto ourOrd  = cc["ours_mode_ordinals"];
    assert(refOrd.object.length == 4 && ourOrd.object.length == 4);
    foreach (k, v; refOrd.object)
        assert(k in ourOrd.object,
               format("fixture: mode '%s' has no counterpart on our side", k));
    // DERIVED, not restated: compute whether the two orders agree and check
    // the frozen claim against it. A hand-written boolean nobody computes is
    // the same defect as a check that cannot come out differently.
    bool ordersAgree = true;
    foreach (k, v; refOrd.object)
        if (v.integer != ourOrd[k].integer) { ordersAgree = false; break; }
    assert(ordersAgree == cc["ordinals_agree"].boolean,
           format("fixture says the two mode orders agree=%s; computed %s. "
                  ~ "If our enum was reordered to match, say so here and drop "
                  ~ "the note beside it.",
                  cc["ordinals_agree"].boolean, ordersAgree));
    assert(cc["wireframe_and_flat_write_the_inactive_slot"].boolean,
           "fixture: the coarse control is a facade over the per-slot state, "
           ~ "which is what settles the 'two controls or one alias' question "
           ~ "recorded on BackdropStyle");

    // Our enum against the frozen ordinals.
    assert(cast(int) BackdropStyle.SameAsActive == ourOrd["mirrorActive"].integer);
    assert(cast(int) BackdropStyle.Wireframe    == ourOrd["wireframe"].integer);
    assert(cast(int) BackdropStyle.Flat         == ourOrd["flat"].integer);
    assert(cast(int) BackdropStyle.Hidden       == ourOrd["hidden"].integer);
    assert(__traits(allMembers, BackdropStyle).length == 4,
           "BackdropStyle grew or shrank: the reference has exactly four "
           ~ "background-layer modes and the mapping above is one-to-one");
}

// ---------------------------------------------------------------------------
// B. PARITY. The row's headline question, on the stand that can answer it:
//    two layers, one background, "same as active", active style = the weight
//    style. The reference fills the background surface and ramps it.
//
//    THE STAND THAT COULD NOT ANSWER IT is a single layer -- there is no
//    background layer there and every candidate law agrees. So this block
//    resolves the BACKDROP plan explicitly (isBackdrop = true) and compares it
//    against the active one.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    auto ws = f["weight_style_backdrop"];
    assert(ws["backdrop_fills_under_weight_and_same_as_active"].boolean);
    assert(ws["backdrop_takes_the_weight_ramp_under_same_as_active"].boolean);

    ViewportDisplay d;
    d.active.style   = DisplayStyle.Weight;
    d.active.wire    = WireOverlay.Uniform;
    d.backdropStyle  = BackdropStyle.SameAsActive;

    const DrawPlan fg = resolveDrawPlan(d, false);
    const DrawPlan bg = resolveDrawPlan(d, true);

    // The control: the active pass must fill and ramp, or the backdrop
    // comparison below is measuring a broken resolver rather than a law.
    assert(fg.drawFaces && fg.shading == SurfaceShading.Weight,
           "control: the ACTIVE pass under the weight style must fill and ramp");

    assert(bg.drawFaces,
           "the backdrop's face pass under the weight style + same-as-active "
           ~ "must run. Measured at the reference's own draw caller: "
           ~ "same-as-active folds the background item onto the ACTIVE display "
           ~ "slot before the pass gate, so background meshes are drawn in the "
           ~ "MAIN model pass -- the pass every style installs. Withdrawing the "
           ~ "fill here is the move the register's row rejects by name.");
    assert(bg.shading == SurfaceShading.Weight,
           format("the backdrop must take the weight ramp, got %s", bg.shading));
    assert(bg.drawWire,
           "the overlay axis is untouched by any of this -- background layers "
           ~ "stay visible and snappable");
}

// ---------------------------------------------------------------------------
// C1. DIVERGENCE PIN, not parity: our backdrop brightness multiplier.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    auto br = f["brightness"];

    const double refMul  = asDouble(br["reference_background_brightness_multiplier"]);
    const double ourMul  = asDouble(br["ours_background_brightness_multiplier"]);
    assert(br["alpha_sites_agreeing"].integer >= 2,
           "fixture: 'the alpha is the same constant everywhere' needs more "
           ~ "than one site to be a finding");
    assert(br["branches_on_foreground_near_the_alpha"].integer == 0);

    // The one foreground-dependent alpha in the draw code was searched for and
    // found, and it is NOT this: it sits on the silhouette/overlay bin, applies
    // to FOREGROUND items, is gated on a viewport mode, and its value is a user
    // preference rather than a constant. Pinned so that finding it later does
    // not get mistaken for the backdrop dim.
    auto one = br["the_one_foreground_dependent_alpha_found"];
    assert(one["applies_to"].str == "foreground");
    assert(!one["on_the_surface_path"].boolean);
    assert(!one["value_is_a_constant"].boolean);

    assert(refMul == 1.0,
           "fixture: the reference does not dim a background layer at all");
    assert(refMul != ourMul,
           "fixture: this block is a DIVERGENCE pin -- if the two ever agree, "
           ~ "retire the block instead of leaving it asserting nothing");

    ViewportDisplay d;
    d.active.style  = DisplayStyle.Weight;
    d.backdropStyle = BackdropStyle.SameAsActive;
    const DrawPlan bg = resolveDrawPlan(d, true);

    assert(abs(cast(double) bg.dim - ourMul) < 1e-6,
           format("our backdrop dim is %s; the frozen record of OUR value is "
                  ~ "%s and the reference's is %s. This is a declared "
                  ~ "divergence (task 0559): the reference distinguishes a "
                  ~ "background layer by giving it a second display state, not "
                  ~ "by dimming one. Change the constant and this fixture "
                  ~ "together, or the divergence stops being declared.",
                  bg.dim, ourMul, refMul));
    assert(cast(double) kBackdropDim == ourMul,
           "kBackdropDim and the fixture's record of it have drifted apart");
}

// ---------------------------------------------------------------------------
// C2. DIVERGENCE PIN for a REFUTED rule: our solid style still withdraws the
//     backdrop's face pass, and the reference does not. Pinned so it cannot be
//     widened (to the weight style, say) or silently changed while it waits
//     for its own task; block B above is what reddens if it IS widened.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    auto dv = f["ours_divergences"]["solid_withdraws_the_backdrop_face_pass"];
    assert(dv["ours"].boolean && !dv["reference"].boolean,
           "fixture: this block is a divergence pin; if the two sides agree, "
           ~ "retire it");

    ViewportDisplay d;
    d.active.style  = DisplayStyle.Solid;
    d.backdropStyle = BackdropStyle.SameAsActive;

    const DrawPlan fg = resolveDrawPlan(d, false);
    const DrawPlan bg = resolveDrawPlan(d, true);

    assert(fg.drawFaces,
           "control: the ACTIVE pass under the solid style must still fill");

    // The fixture field is "does the solid style WITHDRAW the backdrop's face
    // pass", so it is the negation of `drawFaces`. Spelled out rather than
    // inlined, because getting that polarity wrong is how a divergence pin
    // turns into a check that cannot come out differently.
    const bool oursWithdraws = dv["ours"].boolean;
    const bool refWithdraws  = dv["reference"].boolean;
    assert(!bg.drawFaces == oursWithdraws,
           format("our backdrop face pass under solid + same-as-active is %s "
                  ~ "(withdrawn = %s); the frozen record says OURS withdraws it "
                  ~ "(%s) and the reference does NOT (%s). The reference draws "
                  ~ "background meshes in the MAIN pass under same-as-active, so "
                  ~ "their faces fill; our rule reads the sub-pass count "
                  ~ "correctly and applies it to the one configuration where "
                  ~ "that sub-pass is never used. Fixing it is a behaviour "
                  ~ "change with its own task -- do it there, and retire this "
                  ~ "block in the same commit.",
                  bg.drawFaces, !bg.drawFaces, oursWithdraws, refWithdraws));
    assert(oursWithdraws != refWithdraws,
           "fixture: the two sides must still disagree, or this pin is inert");

    // And the scoping stays as it is: naming a backdrop representation
    // outright keeps its fill on both sides.
    ViewportDisplay flat;
    flat.active.style  = DisplayStyle.Solid;
    flat.backdropStyle = BackdropStyle.Flat;
    assert(resolveDrawPlan(flat, true).drawFaces,
           "the Flat backdrop mode names a representation outright and must "
           ~ "keep its fill -- the withdrawal is scoped to SameAsActive");
}
