// Module unittests for `tools.transform.transform`, moved verbatim out of source/tools/transform/transform.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.transform_test;

import tool;
import operator : VectorStack;
import mesh;
import editmode;
import seltype : SelType;
import math : Vec3, Viewport, AimViewport, aimSpace;
import change_bus : MeshEditScope;
import command : Command;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import snap : SnapResult;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket, SnapPacket, SubjectPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import pipe_gizmo_host : PipeGizmoHost;
import document : primaryModelSpace;
import tools.transform.transform;

// ---------------------------------------------------------------------------
// THE MOVING SET IS THE EXCLUDED SET — `movingVertexIndices`.
//
// Snapping's exclusion has one job: a drag must not snap to its own geometry.
// It was built from `vertexIndicesToProcess`, and that list is short by
// exactly the mirror partners whenever a SYMM stage is live — `applyTRS`'s
// prologue already states that the mirror "touches `dragSymmetry.pairOf`
// indices OUTSIDE `vertexIndicesToProcess`", which is why it restores the
// whole baseline. So the two lists disagreed, and the disagreement is the
// defect: a partner moves with the gesture but was still offered to it.
//
// Three blocks, in the order the claim is built:
//
//   1. CROSS-CHECK against the mirror pass itself. Run `applySymmetryMirror`
//      on a fixture and diff the mesh: every index the pass actually WROTE
//      must be in `movingVertexIndices`. This is the invariant, and it is
//      checked against the code that does the writing rather than against a
//      hand-listed expectation that could drift with it.
//   2. BEHAVIOUR. Feed the set to the query snapping actually runs. The
//      mirror partner is the nearest candidate there is on a symmetric mesh,
//      so with the short list it WINS — the drag snaps to its own reflection.
//   3. SCALPEL. Symmetry off, or a vertex with no partner, must exclude
//      nothing extra; and a genuinely static vertex must still be a candidate.
// ---------------------------------------------------------------------------
unittest {
    import math             : lookAt, perspectiveMatrix, projectToWindowFull, ModelSpace;
    import snap             : snapCursor, SnapResult, invalidateSnapGrids;
    import toolpipe.packets : SnapPacket, SnapType, SnapMode;
    import std.math         : PI, round;
    import std.algorithm    : canFind;

    // The fixture: four vertices, mirrored in pairs about the X = 0 plane.
    //   0 <-> 1   the DRAGGED pair — vertex 0 is processed, 1 is its partner
    //   2 <-> 3   a static pair, neither processed
    static Mesh makeMesh() {
        Mesh m;
        m.vertices = [
            Vec3(-0.30f, 0, 0),   // 0 — processed by the drag
            Vec3( 0.30f, 0, 0),   // 1 — its mirror partner: MOVES, unprocessed
            Vec3(-0.90f, 0, 0),   // 2 — static
            Vec3( 0.90f, 0, 0),   // 3 — static
        ];
        return m;
    }

    SymmetryPacket sym;
    sym.enabled     = true;
    sym.axisIndex   = 0;
    sym.planePoint  = Vec3(0, 0, 0);
    sym.planeNormal = Vec3(1, 0, 0);
    sym.pairOf      = [1, 0, 3, 2];
    sym.onPlane     = [false, false, false, false];
    sym.vertSign    = [-1, +1, -1, +1];
    sym.baseSide    = -1;          // the processed side drives

    immutable int[] processed = [0];

    // --- 1. CROSS-CHECK: every index the mirror pass writes is in the set ---
    {
        auto m   = makeMesh();
        auto pre = m.vertices.dup;

        // The drag has already moved vertex 0; the mirror pass now reflects it.
        m.vertices[0] = Vec3(-0.45f, 0, 0);

        bool[] procMask;
        procMask.length = m.vertices.length;
        foreach (vi; processed) procMask[vi] = true;
        bool[] touched;
        touched.length = m.vertices.length;
        applySymmetryMirror(&m, sym, procMask, touched);

        auto moving = movingVertexIndices(processed, sym, m.vertices.length);

        bool wrote = false;
        foreach (i; 0 .. m.vertices.length) {
            immutable bool moved = m.vertices[i].x != pre[i].x
                                || m.vertices[i].y != pre[i].y
                                || m.vertices[i].z != pre[i].z;
            if (!moved) continue;
            wrote = true;
            assert(moving.canFind(cast(uint)i),
                "every vertex the drag's mirror pass MOVES must be in the set "
                ~ "snapping excludes — otherwise the query is offered a "
                ~ "candidate that is part of the gesture, and (because the "
                ~ "candidate grid is keyed on a mutationVersion the drag does "
                ~ "not bump) it is offered it at last frame's position");
        }
        assert(wrote,
            "fixture: the mirror pass must actually have written something, or "
            ~ "the loop above proves nothing");
        assert(moving.canFind(1u),
            "specifically: vertex 1 is vertex 0's partner. It is not in "
            ~ "`vertexIndicesToProcess` — that is the whole point — and it "
            ~ "moves on every frame of the drag");
    }

    // --- 2. BEHAVIOUR: the query must not offer the drag its own reflection -
    {
        invalidateSnapGrids();

        Viewport vp;
        vp.eye    = Vec3(0, 0, 5);
        vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
        vp.width  = 800;
        vp.height = 800;

        auto m = makeMesh();

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.enabledTypes = SnapType.Vertex;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 200.0f;
        cfg.outerRangePx = 200.0f;

        // The cursor sits nearest the PARTNER — the case a symmetric drag
        // meets as soon as the two halves approach each other.
        float qx, qy, qz;
        assert(projectToWindowFull(m.vertices[1], vp, qx, qy, qz),
            "fixture: the partner must project on-screen");
        immutable int sx = cast(int)round(qx), sy = cast(int)round(qy);

        // The short list — what shipped. It reaches the partner, which is what
        // makes the assertion after it meaningful rather than vacuous.
        uint[] shortList;
        foreach (vi; processed) shortList ~= cast(uint)vi;
        invalidateSnapGrids();
        SnapResult bad = snapCursor(Vec3(9, 9, 9), sx, sy, vp, m, ModelSpace.world(), cfg, shortList);
        assert(bad.snapped && bad.targetIndex == 1,
            "premise: excluding only the processed vert leaves the mirror "
            ~ "partner the nearest candidate, so the drag snaps to its own "
            ~ "reflection");

        invalidateSnapGrids();
        SnapResult good = snapCursor(Vec3(9, 9, 9), sx, sy, vp, m, ModelSpace.world(), cfg,
                                     movingVertexIndices(processed, sym,
                                                         m.vertices.length));
        assert(good.targetIndex != 1 && good.targetIndex != 0,
            "neither the dragged vertex nor the vertex the drag mirrors it "
            ~ "onto may win: both move with the gesture");
        assert(good.snapped && good.targetIndex == 3,
            "...and the nearest vertex that does NOT move still wins — the "
            ~ "exclusion removes the gesture's own geometry, not the mesh");

        invalidateSnapGrids();
    }

    // --- 3. SCALPEL: no symmetry, no partner, no extra exclusion -----------
    {
        auto off = SymmetryPacket.init;                 // enabled == false
        assert(movingVertexIndices(processed, off, 4) == [0u],
            "with no SYMM stage live the set is the processed list verbatim — "
            ~ "this path is every non-symmetric drag there is and must not "
            ~ "acquire a partner lookup's cost or its behaviour");

        auto stale = sym;
        stale.pairOf = [1, 0];                          // shorter than the mesh
        assert(movingVertexIndices(processed, stale, 4) == [0u],
            "a pairing snapshot that does not match the mesh is the one the "
            ~ "apply refuses to mirror with, so it must not drive an "
            ~ "exclusion either — the two gates have to agree");

        auto unpaired = sym;
        unpaired.pairOf = [-1, -1, -1, -1];
        assert(movingVertexIndices(processed, unpaired, 4) == [0u],
            "`pairOf == -1` is 'no mirror within epsilon': nothing else moves");

        auto onPlane = sym;
        onPlane.pairOf = [0, 1, 2, 3];                  // each vert is its own
        assert(movingVertexIndices(processed, onPlane, 4) == [0u],
            "an on-plane vertex is projected in place, and it is already in "
            ~ "the list — it must not be added twice under a different name");
    }
}
