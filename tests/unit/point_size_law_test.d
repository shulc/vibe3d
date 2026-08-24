// The vertex-dot SIZE law, and the occluded-selection alpha beside it
// (task 1860 — adopted from the measurement in 1820).
//
// ---------------------------------------------------------------------------
// What is being pinned, and why a value assertion would not do it
// ---------------------------------------------------------------------------
// The shipped numbers are 3 px unselected and 6 px selected. Written as two
// constants, "3 and 6" is satisfied by a function that ignores its argument
// and returns one of two literals — which is precisely the implementation this
// change replaced (`glPointSize(5.0f)` and `glPointSize(10.0f)`, two
// independent literals whose 2x ratio was a coincidence, and whose base was
// 1.67x too big).
//
// So the law is asserted as a RELATION over TWO DIFFERENT BASES. A function
// whose body reads `kBasePointSize * scale` instead of `base * scale` returns
// the right answer for the shipped base and the wrong one for any other; it
// passes the first row below and fails the second. That second row is not
// hypothetical padding either — it is the retopology layout's own base, which
// is the override channel the law provides for and we have not built yet.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION (see the task file's Мутация section for the verbatim
// red output): `pointSizePx` changed to multiply the constant rather than the
// argument reddens the "base 6" row here and nothing else in this file.
// ---------------------------------------------------------------------------
module tests.unit.point_size_law_test;

import std.format : format;
import viewport_scheme : kBasePointSize, kSelectedPointScale, pointSizePx,
                         kOccludedSelectionAlpha;

/// The shipped defaults are the measured ones.
unittest {
    assert(kBasePointSize == 3.0f,
        format("the unselected dot is measured at 3 px, the table says %g",
               kBasePointSize));
    assert(kSelectedPointScale == 2.0f,
        format("the selected dot is measured at 2x the base, the table says %g",
               kSelectedPointScale));
}

/// The law itself: base x multiplier, on TWO bases.
unittest {
    static struct Row { float base; float unselected; float selected; string what; }
    immutable Row[] rows = [
        Row(3.0f, 3.0f,  6.0f,  "the shipped base"),
        // The second base is what makes this a law rather than two numbers.
        Row(6.0f, 6.0f, 12.0f,  "a per-viewport override base — the row that "
                              ~ "an implementation multiplying the CONSTANT "
                              ~ "instead of the ARGUMENT fails"),
    ];

    foreach (r; rows) {
        assert(pointSizePx(r.base, false) == r.unselected,
            format("%s: an unselected dot at base %g must be %g px, got %g",
                   r.what, r.base, r.unselected, pointSizePx(r.base, false)));
        assert(pointSizePx(r.base, true) == r.selected,
            format("%s: a selected dot at base %g must be %g px, got %g",
                   r.what, r.base, r.selected, pointSizePx(r.base, true)));
    }

    // Non-vacuity: the two rows must actually disagree, or the pair above is
    // one row asserted twice and the argument/constant confusion sails through.
    assert(pointSizePx(rows[0].base, true) != pointSizePx(rows[1].base, true),
        "the two bases produce the same selected size — this block cannot see "
        ~ "an implementation that ignores its argument");

    // And the multiplier is a MULTIPLIER, not an additive offset: an offset
    // law fitted to the shipped row (3 -> 6 is +3 as well as x2) predicts 9 at
    // base 6, which is what this compare refuses.
    assert(pointSizePx(6.0f, true) != 6.0f + (pointSizePx(3.0f, true) - 3.0f),
        "an ADDITIVE offset fits the shipped row exactly as well as the "
        ~ "multiplier does; this is the cell that separates them");
}

/// The occluded-selection alpha, and the falsified reading of it.
///
/// The number handed to the draw layer is `1 − transparency` = 0.30. The
/// shipped reference help calls the same preference an "opacity", which would
/// make it 0.70; that reading is refuted by the reference's own arithmetic at
/// both of its use sites (registry row 76). Both values are legal alphas and
/// both produce a plausible picture, so nothing about the rendered frame
/// distinguishes a fix from a regression here — which is exactly why the
/// number is pinned as a number.
unittest {
    assert(kOccludedSelectionAlpha == 0.30f,
        format("the occluded half of a selection is drawn at 0.30 = 1 - 0.70; "
               ~ "the table says %g. If this now reads 0.70, someone has "
               ~ "'corrected' a transparency into an opacity",
               kOccludedSelectionAlpha));
    // It is a blend, in both directions: fully opaque would make the second
    // pass indistinguishable from the first, and zero would make it invisible
    // and the whole pass unobservable.
    assert(kOccludedSelectionAlpha > 0.0f && kOccludedSelectionAlpha < 1.0f);
}
