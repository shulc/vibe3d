// The pen's re-evaluation data and the edge slide's axis kernel (wave plan
// 8640 S7b, §9.8 / §9.17.6 / §9.26.3 / §9.27 [A15-4]). Named into the pen's
// package for its `package` members (gestures_test.d's header has why). The
// suite half is tests/test_session_laws_topology_pen_offset.d.
module tools.edit.topology_pen.reapply_test;

import tools.edit.topology_pen;
import math : Vec3;

// kReapply — the table IS the plan's: per kind, what it reads and its shape.
// A row moved between shapes (Add Loop or Fill to carriedT, Smooth reading
// the offsets, Fill attribute-only) reddens here as well as in the suite.
unittest {
    import std.algorithm.searching : canFind;
    enum O = ["offsetX", "offsetY", "offsetZ"];
    struct Want { PenStepKind kind; string[] reads; ReapplyShape shape; }
    const Want[] want = [
        Want(PenStepKind.None,        null,               ReapplyShape.attributeOnly),
        Want(PenStepKind.VertexMove,  O,                  ReapplyShape.carriedT),
        Want(PenStepKind.EdgeMove,    O,                  ReapplyShape.carriedT),
        Want(PenStepKind.PolygonMove, O,                  ReapplyShape.carriedT),
        Want(PenStepKind.MoveLoop,    O,                  ReapplyShape.carriedT),
        Want(PenStepKind.Slide,       O,                  ReapplyShape.carriedT),
        Want(PenStepKind.CornerBuild, O,                  ReapplyShape.carriedT),
        Want(PenStepKind.PointPlace,  O,                  ReapplyShape.carriedT),
        Want(PenStepKind.AddLoop,     O,                  ReapplyShape.basisOnly),
        Want(PenStepKind.Smooth,      ["smoothStrength"], ReapplyShape.rerunFromBasis),
        Want(PenStepKind.Fill,        O,                  ReapplyShape.basisOnly),
        Want(PenStepKind.DupEdge,     O,                  ReapplyShape.carriedT),
    ];
    // Population: one row per kind, every kind covered.
    assert(want.length == kReapply.length && kReapply.length == PenStepKind.max + 1);
    foreach (w; want) {
        const row = kReapply[w.kind];
        assert(row.shape == w.shape && row.reads == w.reads);
    }
    // The offsets are read by no smooth, and strength by no carried kind.
    assert(!kReapply[PenStepKind.Smooth].reads.canFind("offsetX"));
    assert(!kReapply[PenStepKind.VertexMove].reads.canFind("smoothStrength"));
}

// edgeSlideAxis — the largest |component|; a tie within the RELATIVE eps goes
// to the LATER axis (X/Y -> Y is captured, L50); eps 0 is a strict compare.
// Constructed inputs, so the tie is not a float coin flip ([A15-4] note).
unittest {
    alias ax = TopologyPenTool.edgeSlideAxis;
    enum double eps = TopologyPenTool.kEdgeSlideTieEps;
    assert(eps == 1e-3);
    // |dX| = |dY| (1 + 1e-6): a tie under eps -> Y; strictly X without it.
    assert(ax(Vec3(1.000001f, 1.0f, 0.0f), eps) == 1);
    assert(ax(Vec3(1.000001f, 1.0f, 0.0f), 0.0) == 0);
    // Outside the tolerance the larger wins, either order.
    assert(ax(Vec3(1.01f, 1.0f, 0.0f), eps) == 0);
    assert(ax(Vec3(-1.0f, 1.01f, 0.2f), eps) == 1);
    // Y/Z (ours): the later axis again.
    assert(ax(Vec3(0.1f, 0.5f, -0.5f), eps) == 2);
    assert(ax(Vec3(0.1f, 0.5f, -0.4f), eps) == 1);
    // A zero or non-finite delta latches nothing.
    assert(ax(Vec3(0, 0, 0), eps) == -1);
    assert(ax(Vec3(float.nan, 1, 0), eps) == -1);
    // The latch point sits inside the measured window (2.24, 5.9] px (L50).
    assert(TopologyPenTool.kEdgeSlideLatchPx > 2.24f && TopologyPenTool.kEdgeSlideLatchPx <= 5.9f);
}
