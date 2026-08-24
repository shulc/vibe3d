module tests.unit.toolpipe.view_only_subject_pin_test;

// Task 1904 (doc/subject_stage_plan.md §1.3a) — the declaration-site pin
// for `viewOnlySubject`. The two workplane pickers (`create_common.d ::
// pickWorkplane`, `:: pickWorkplaneFrame`) publish a subject with no mesh
// and the type fields frozen at `EditMode.Vertices` / `SelType.Vertex` --
// today's silent `.init` behaviour, made explicit. No behavioural test can
// see a wrong value leak in through those two call sites (§1.3a traces why:
// the packets their evaluates produce are read from a stack that only ever
// yields `WorkplanePacket`), so the guard sits at the constant's
// declaration instead. Mutation M6 (plan §8) reddens this test.

import toolpipe.subject : viewOnlySubject;
import editmode          : EditMode;
import seltype            : SelType;
import math                : Viewport, Vec3;

unittest {
    // Every field set explicitly, none left at `.init` -- `Viewport.init`
    // carries NaN in `eye`/`focus` (math.d's own comment on the struct), and
    // `NaN == NaN` is false, which would make the `viewport == vp` check
    // below fail even when viewOnlySubject copies the value through
    // correctly. Use concrete numbers so `==` is a real comparison.
    Viewport vp;
    vp.view[]  = 0.0f;
    vp.proj[]  = 0.0f;
    vp.width   = 800;
    vp.height  = 600;
    vp.x       = 10;
    vp.y       = 20;
    vp.eye     = Vec3(1, 2, 3);
    vp.focus   = Vec3(4, 5, 6);

    auto src = viewOnlySubject(vp);

    assert(src.mesh is null,
           "§1.3a: viewOnlySubject must freeze mesh == null -- pickWorkplane/"
           ~ "pickWorkplaneFrame publish no mesh today");
    assert(src.editMode == EditMode.Vertices,
           "§1.3a: editMode is frozen at Vertices -- the value the two "
           ~ "workplane pickers publish implicitly via .init today");
    assert(src.selType == SelType.Vertex,
           "§1.3a: selType is frozen at Vertex -- ActionCenterStage/AxisStage "
           ~ "branch on subj.selType unconditionally and no behavioural test "
           ~ "can see a live value leak in through pickWorkplane/"
           ~ "pickWorkplaneFrame, so the freeze is pinned here");
    assert(src.viewport == vp,
           "§1.3a: viewport is the one field the two pickers DO pass through "
           ~ "today (`subj.viewport = vp;`) -- viewOnlySubject must not drop it");
}
