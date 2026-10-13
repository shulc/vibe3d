module handles.shapes_source_cells;

import handles.gl_util;
import math;
import spatial : Viewport, isOrtho, lockedViewAxis, projectToWindowFull;
import perf_probe : g_fc, DrawPass;
import shader;
import viewport_scheme;
import bindbc.sdl;
import bindbc.opengl;
import core.atomic : atomicOp;
import std.math : sin, cos, sqrt, PI, abs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import ai.interaction : AiIntent;
import handles.shapes;

unittest {
    // Task 0604 — the shaft's batch really carries a SECOND, identical segment,
    // and `doubledShaft` really selects it.
    //
    // This is the pin the pixel tests cannot supply. Two emissions at 0.95
    // composite to 0.9975 and one emission at 1.0 composites to 1.0, and those
    // differ by less than a third of an 8-bit level over the widest background
    // contrast the viewport has — so no probe can tell the ported mechanism
    // from a folded alpha. They are NOT the same thing at the stroke's edge
    // (`u_alpha*cov` means a coverage-c fringe fragment lands at `1-(1-0.95c)^2`
    // one way and at `c` the other, 0.72 against 0.50 at half coverage), and
    // the edge is half of what antialiasing is for. So the mechanism is
    // asserted here, structurally, where it is unambiguous.
    import std.math : abs;

    auto d = ShaftedArrow.shaftSegmentData();
    assert(d.length == 12,
           "the shaft buffer must hold FOUR vertices — two copies of the unit "
           ~ "segment, which is what lets one draw call emit it twice");
    foreach (i; 0 .. 6)
        assert(abs(d[i] - d[i + 6]) < 1e-9f,
               "the shaft buffer's second segment is not identical to the "
               ~ "first; a doubled emission must retrace the SAME line, not "
               ~ "draw a second one somewhere near it");
    // ...and it is the unit segment along +Z, which is what `draw`'s model
    // matrix scales into the arm.
    assert(d[0] == 0f && d[1] == 0f && d[2] == 0f);
    assert(d[3] == 0f && d[4] == 0f && d[5] == 1f);

    // The selector. `Arrow`'s ctor only touches GL through `buildVao3f`, which
    // is a no-op under `version(unittest)`.
    auto arrow = new Arrow(Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,0));
    assert(arrow.shaftVertCount() == 2,
           "an arrow that has not opted in must draw ONE segment — this class "
           ~ "also serves the falloff endpoint handles and the create-tool "
           ~ "movers, whose stroke weight nothing has measured");
    arrow.doubledShaft = true;
    assert(arrow.shaftVertCount() == 4,
           "an opted-in arm must draw both copies of the segment");
}
