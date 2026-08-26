// Module unittests for `perf_probe`, moved verbatim out of source/perf_probe.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.perf_probe_test;

import core.time : MonoTime, Duration;
import perf_probe;

unittest { // a committed frame folds its per-pass work into the totals
    FrameWorkProbe fc;
    fc.beginFrame();
    fc.draw(DrawPass.faces, 36);
    fc.draw(DrawPass.edges, 24);
    fc.draw(DrawPass.edges, 8);
    fc.bumpCellConsidered();
    fc.bumpCellRendered();
    fc.endFrame();

    auto w = fc.last();
    assert(w.seq == 1);
    assert(w.pass[DrawPass.faces].calls == 1 && w.pass[DrawPass.faces].verts == 36);
    assert(w.pass[DrawPass.edges].calls == 2 && w.pass[DrawPass.edges].verts == 32);
    // drawCalls/drawVerts are FOLDS of the per-pass slots, not independently
    // maintained counters — a mismatch here means a pass exists that the fold
    // does not walk.
    assert(w.drawCalls == 3, "drawCalls must be the sum over passes");
    assert(w.drawVerts == 68, "drawVerts must be the sum over passes");
    assert(w.cellsConsidered == 1 && w.cellsRendered == 1);
}

unittest { // the backdrop redirect moves faces/edges and nothing else
    FrameWorkProbe fc;
    fc.beginFrame();
    fc.draw(DrawPass.faces, 10);
    {
        auto z = fc.backdrop();
        fc.draw(DrawPass.faces, 100);
        fc.draw(DrawPass.edges, 200);
        // NOT a shading pass — must stay where it was put even inside the
        // redirect, or the backdrop slot silently absorbs unrelated work.
        fc.draw(DrawPass.grid, 400);
    }
    // Redirect must END with the scope.
    fc.draw(DrawPass.edges, 20);
    fc.endFrame();

    auto w = fc.last();
    assert(w.pass[DrawPass.faces].verts   == 10);
    assert(w.pass[DrawPass.edges].verts   == 20);
    assert(w.pass[DrawPass.bgFaces].verts == 100);
    assert(w.pass[DrawPass.bgEdges].verts == 200);
    assert(w.pass[DrawPass.grid].verts    == 400,
           "the redirect must only touch faces/edges");
}

unittest { // nested backdrop scopes: an inner scope cannot un-redirect its caller
    FrameWorkProbe fc;
    fc.beginFrame();
    auto outer = fc.backdrop();
    {
        auto inner = fc.backdrop();
        fc.draw(DrawPass.faces, 1);
    }
    // Still inside `outer` — this must STILL be a backdrop draw.
    fc.draw(DrawPass.faces, 2);
    fc.endFrame();
    auto w = fc.last();
    assert(w.pass[DrawPass.bgFaces].verts == 3);
    assert(w.pass[DrawPass.faces].verts == 0,
           "the inner scope closing must not clear the outer redirect");
}

unittest { // lastScene skips frames that rendered no cell; last does not
    FrameWorkProbe fc;

    fc.beginFrame();
    fc.bumpCellConsidered();
    fc.bumpCellRendered();
    fc.draw(DrawPass.faces, 36);
    fc.endFrame();

    // A frame that considered a cell and skipped it: real, and normal.
    fc.beginFrame();
    fc.bumpCellConsidered();
    fc.endFrame();

    assert(fc.last().seq == 2);
    assert(fc.last().drawVerts == 0, "the skipped frame really drew nothing");
    assert(fc.lastScene().seq == 1,
           "lastScene must hold the last frame that rendered a cell");
    assert(fc.lastScene().drawVerts == 36);
}

unittest { // totals accumulate across frames; seq counts committed frames
    FrameWorkProbe fc;
    foreach (i; 0 .. 5) {
        fc.beginFrame();
        fc.bumpCellConsidered();
        fc.bumpCellRendered();
        fc.draw(DrawPass.faces, 36);
        fc.upload(8);
        fc.bumpPipeEval();
        fc.bumpStageEval();
        fc.bumpStageEval();
        fc.bumpHoverPick();
        fc.endFrame();
    }
    auto t = fc.totals();
    assert(t.seq == 5);
    assert(t.drawCalls == 5 && t.drawVerts == 180);
    assert(t.pass[DrawPass.faces].calls == 5);
    assert(t.uploadCalls == 5 && t.uploadVerts == 40);
    assert(t.pipeEvals == 5 && t.stageEvals == 10);
    assert(t.hoverPicks == 5);
    assert(fc.lastScene().drawVerts == 36, "lastScene is per-frame, not a total");
}

unittest { // reset zeroes everything, and counting resumes afterwards
    FrameWorkProbe fc;
    fc.beginFrame();
    fc.draw(DrawPass.faces, 36);
    fc.bumpCellRendered();
    fc.endFrame();
    assert(fc.totals().seq == 1);

    fc.reset();
    assert(fc.totals().seq == 0);
    assert(fc.last().drawVerts == 0);
    assert(fc.lastScene().drawVerts == 0);

    fc.beginFrame();
    fc.draw(DrawPass.edges, 7);
    fc.bumpCellRendered();
    fc.endFrame();
    assert(fc.totals().seq == 1);
    assert(fc.lastScene().pass[DrawPass.edges].verts == 7);
}

unittest { // a zero-vertex submission is a CALL, not a nothing
    // A pass that ran with an empty mesh must be distinguishable from a pass
    // that did not run. Dropping zero-count draws would erase that.
    FrameWorkProbe fc;
    fc.beginFrame();
    fc.draw(DrawPass.faces, 0);
    fc.endFrame();
    assert(fc.last().pass[DrawPass.faces].calls == 1);
    assert(fc.last().pass[DrawPass.faces].verts == 0);
    assert(fc.last().drawCalls == 1);
}

unittest { // toJson emits every pass and the three published records
    import std.json : parseJSON, JSONType;
    FrameWorkProbe fc;
    fc.beginFrame();
    fc.bumpCellConsidered();
    fc.bumpCellRendered();
    fc.draw(DrawPass.faces, 36);
    fc.draw(DrawPass.grid, 404);
    fc.endFrame();

    auto j = parseJSON(fc.toJson());
    assert(j.type == JSONType.object);
    assert(j["frames"].integer == 1);
    foreach (rec; ["lastScene", "last", "totals"])
        assert(rec in j, "missing record: " ~ rec);
    // Every DrawPass member must have a key — a slot that exists in the enum
    // but not in the dump is a pass nobody can assert on.
    static foreach (member; __traits(allMembers, DrawPass))
        assert(member in j["lastScene"]["pass"], "missing pass key: " ~ member);
    assert(j["lastScene"]["pass"]["faces"]["verts"].integer == 36);
    assert(j["lastScene"]["pass"]["grid"]["verts"].integer == 404);
    assert(j["lastScene"]["drawVerts"].integer == 440);
}

unittest { // allocBytes is wired to the real GC counter, not left at zero
    // Deliberately the ONLY assertion made about allocBytes anywhere: that it
    // responds to allocation at all. No threshold is asserted here or in the
    // HTTP tests — see the FrameWorkProbe header on why it is a delta
    // instrument and not a gate.
    FrameWorkProbe fc;
    fc.beginFrame();
    // Escape the optimizer: a heap array whose size is not known statically.
    static size_t n = 4096;
    auto junk = new ubyte[n];
    junk[0] = 1;
    fc.endFrame();
    assert(fc.last().allocBytes >= cast(long)n,
           "allocBytes must track main-thread GC allocation");
}
