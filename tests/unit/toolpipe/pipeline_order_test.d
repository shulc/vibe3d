// pipeline_order_test.d — task 0980 / audit-4 P7 measurement.
//
// The audit recorded that `Pipeline`'s two internal indexes disagreed on
// order for exactly one pair of shipped stages: PathStage (ordinal 0x80)
// and FalloffStage/WGHT (ordinal 0x90). `stages_` (ordinal-sorted) places
// Path before Wght; the pre-0980 `evaluate(VectorStack)` walked a separate
// Task-slot-indexed structure in Task-enum DECLARATION order, which places
// Wght (Task.Wght = 6) before Path (Task.Path = 8) — the two disagree, and
// collapsing the two structures into one forces a choice between them.
//
// This is the measurement that licensed the collapse (in favour of ordinal
// order — see toolpipe/pipeline.d's `stages_` field doc): with the REAL
// production Operator bodies, not stand-ins, running FalloffStage and
// PathStage in one order and then the other over the same starting
// configuration must publish byte-identical packets either way, because
// neither stage's evaluate() reads a packet the other publishes (grepped:
// no `vts.get!PathPacket` in falloff.d; PathStage's only declared required
// packet is Subject and it reads nothing else off `vts`) and neither
// mutates shared state the other reads (both touch `Mesh` read-only). That
// is not a property of this particular input — it holds for every input,
// which is what makes swapping the order safe rather than merely
// untested — but the test below exercises a real config (Radial falloff +
// a 3-knot path source) rather than defaults, so it is not vacuously true
// of two stages that do nothing.
module tests.unit.toolpipe.pipeline_order_test;

import math   : Vec3;
import mesh   : Mesh;
import editmode : EditMode;
import path      : PathSource;
import operator  : VectorStack;
import toolpipe.packets  : SubjectPacket, FalloffPacket, FalloffType, PathPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.path    : PathStage;

private FalloffStage makeFalloff(Mesh* delegate() meshSrc) {
    auto fo = new FalloffStage(meshSrc);
    fo.pipeEnabled = true;
    fo.type        = FalloffType.Radial;
    fo.center      = Vec3(1, 1, 0);
    fo.size        = Vec3(3, 3, 3);
    return fo;
}

private PathStage makePath(Mesh* delegate() meshSrc, PathSource src) {
    auto ps = new PathStage(meshSrc);
    ps.pipeEnabled = true;
    ps.sources     = [src];
    ps.index       = 0;
    ps.start       = 0.1f;
    ps.end         = 0.9f;
    return ps;
}

unittest {
    Mesh mesh;
    mesh.vertices = [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(2, 2, 0)];

    SubjectPacket subj;
    subj.mesh     = &mesh;
    subj.editMode = EditMode.Vertices;

    PathSource src;
    src.verts  = [0, 1, 2];
    src.closed = false;

    // Order A: mirrors the PRE-0980 evaluate(VectorStack) — Wght (Task 6)
    // ran before Path (Task 8).
    auto foA = makeFalloff(() => &mesh);
    auto psA = makePath(() => &mesh, src);
    VectorStack vtsA;
    vtsA.put(&subj);
    foA.evaluate(vtsA);
    psA.evaluate(vtsA);

    // Order B: mirrors the ordinal order `stages_` already sorted by
    // (ordPath 0x80 < ordWght 0x90) — Path before Wght, the order
    // evaluate() walks in POST-0980.
    auto foB = makeFalloff(() => &mesh);
    auto psB = makePath(() => &mesh, src);
    VectorStack vtsB;
    vtsB.put(&subj);
    psB.evaluate(vtsB);
    foB.evaluate(vtsB);

    auto fpA = vtsA.get!FalloffPacket();
    auto fpB = vtsB.get!FalloffPacket();
    auto ppA = vtsA.get!PathPacket();
    auto ppB = vtsB.get!PathPacket();

    assert(fpA !is null && fpB !is null, "FalloffStage must always publish");
    assert(ppA !is null && ppB !is null, "PathStage must always publish");

    // Sanity: both stages are actually doing something, not merely
    // agreeing because they are both inert (type=None / no valid knots).
    assert(fpA.enabled, "sanity: the falloff type must actually be active");
    assert(ppA.enabled, "sanity: the path source must actually resolve");

    assert(*fpA == *fpB,
        "FalloffStage's published packet must not depend on whether "
        ~ "PathStage ran before or after it in the same pipe walk — "
        ~ "task 0980's ordinal-order collapse depends on this");
    assert(*ppA == *ppB,
        "PathStage's published packet must not depend on whether "
        ~ "FalloffStage ran before or after it in the same pipe walk — "
        ~ "task 0980's ordinal-order collapse depends on this");
}
