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

    auto j = parseJSON(fc.snapshot().toJson());
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

unittest { // 6357: the detached snapshot keeps the established wire bytes
    import std.regex : regex, replaceAll;

    FrameWorkProbe fc;
    fc.beginFrame();
    foreach (_; 0 .. 3) fc.bumpCellConsidered();
    fc.bumpCellRendered();
    fc.draw(DrawPass.faces, 36);
    fc.draw(DrawPass.faceOverlay, 18);
    fc.draw(DrawPass.grid, 404);
    fc.draw(DrawPass.symmetry, 7);
    fc.draw(DrawPass.symmetry, 7);
    fc.upload(8);
    fc.bumpPipeEval();
    fc.bumpStageEval();
    fc.bumpStatRebuild();
    fc.endFrame();

    fc.beginFrame();
    fc.bumpHoverPick();
    fc.draw(DrawPass.idPick, 12);
    {
        auto pass = fc.handlePass();
        {
            auto leaf = fc.handleDraw(0x10);
            fc.draw(DrawPass.handles, 6);
            fc.noteHandleSubmission();
        }
        {
            auto leaf = fc.handleDraw(0x20);
            fc.draw(DrawPass.handles, 6);
        }
    }
    fc.endFrame();

    assert(fc.lastScene().seq == 1);
    assert(fc.last().seq == 2);
    assert(fc.totals().seq == 2);
    assert(fc.last().cellsRendered == 0);
    assert(fc.totals().cellsRendered == 1);
    assert(fc.lastScene().pass[DrawPass.handles].calls == 0);
    assert(fc.totals().pass[DrawPass.handles].calls == 2);
    assert(fc.lastHandlePass().generation == 1);
    assert(fc.lastHandlePass().submitted == 2);

    auto bytes = fc.snapshot().toJson().replaceAll(regex(`"allocBytes":\d+`),
                                                   `"allocBytes":0`);
    immutable expected = `{"frames":2,"lastScene":{"seq":1,"cellsConsidered":3,"cellsRendered":1,"handlePasses":0,"drawCalls":5,"drawVerts":472,"uploadCalls":1,"uploadVerts":8,"hoverPicks":0,"pipeEvals":1,"stageEvals":1,"statRebuilds":1,"allocBytes":0,"pass":{"faces":{"calls":1,"verts":36},"faceOverlay":{"calls":1,"verts":18},"edges":{"calls":0,"verts":0},"verts":{"calls":0,"verts":0},"bgFaces":{"calls":0,"verts":0},"bgEdges":{"calls":0,"verts":0},"imagePlane":{"calls":0,"verts":0},"grid":{"calls":1,"verts":404},"symmetry":{"calls":2,"verts":14},"handles":{"calls":0,"verts":0},"subpatch":{"calls":0,"verts":0},"idPick":{"calls":0,"verts":0}}},"last":{"seq":2,"cellsConsidered":0,"cellsRendered":0,"handlePasses":1,"drawCalls":3,"drawVerts":24,"uploadCalls":0,"uploadVerts":0,"hoverPicks":1,"pipeEvals":0,"stageEvals":0,"statRebuilds":0,"allocBytes":0,"pass":{"faces":{"calls":0,"verts":0},"faceOverlay":{"calls":0,"verts":0},"edges":{"calls":0,"verts":0},"verts":{"calls":0,"verts":0},"bgFaces":{"calls":0,"verts":0},"bgEdges":{"calls":0,"verts":0},"imagePlane":{"calls":0,"verts":0},"grid":{"calls":0,"verts":0},"symmetry":{"calls":0,"verts":0},"handles":{"calls":2,"verts":12},"subpatch":{"calls":0,"verts":0},"idPick":{"calls":1,"verts":12}}},"totals":{"seq":2,"cellsConsidered":3,"cellsRendered":1,"handlePasses":1,"drawCalls":8,"drawVerts":496,"uploadCalls":1,"uploadVerts":8,"hoverPicks":1,"pipeEvals":1,"stageEvals":1,"statRebuilds":1,"allocBytes":0,"pass":{"faces":{"calls":1,"verts":36},"faceOverlay":{"calls":1,"verts":18},"edges":{"calls":0,"verts":0},"verts":{"calls":0,"verts":0},"bgFaces":{"calls":0,"verts":0},"bgEdges":{"calls":0,"verts":0},"imagePlane":{"calls":0,"verts":0},"grid":{"calls":1,"verts":404},"symmetry":{"calls":2,"verts":14},"handles":{"calls":2,"verts":12},"subpatch":{"calls":0,"verts":0},"idPick":{"calls":1,"verts":12}}},"handlePass":{"generation":1,"writes":3,"submitted":2,"receiptsDropped":0,"ids":["0000000000000010","0000000000000020"]}}`;
    assert(bytes == expected, "6357 frame-count wire bytes changed");
}

unittest { // allocBytes tracks only allocations after an explicit rebase
    FrameWorkProbe fc;
    fc.beginFrame();
    // Escape the optimizer with heap arrays whose sizes are not compile-time
    // constants. The larger first allocation is bridge-shaped work to exclude;
    // the smaller second allocation proves the counter is still live.
    static size_t excludedN = 65536;
    static size_t includedN = 4096;
    auto excluded = new ubyte[excludedN];
    excluded[0] = 1;
    fc.rebaseAllocationWindow();
    auto included = new ubyte[includedN];
    included[0] = 2;
    fc.endFrame();
    assert(fc.last().allocBytes >= cast(long)includedN,
           "allocBytes must track main-thread GC allocation after the rebase");
    assert(fc.last().allocBytes < cast(long)excludedN,
           "allocBytes retained allocation from before the explicit rebase");
    assert(excluded[0] == 1 && included[0] == 2,
           "allocation-window fixture buffers did not remain live");
}

unittest { // 6330: a reset from ANOTHER thread must not re-base the GC window
    // `allocatedNow()` is `GC.allocatedInCurrentThread` — THREAD-LOCAL. When
    // `reset()` stamped `allocBase_`, a reset arriving from the HTTP thread
    // stored THAT thread's counter, and the main thread then subtracted it
    // from its own in `endFrame`. Two coordinate systems: the straddling frame
    // reported roughly the main thread's whole lifetime allocation volume, and
    // `endFrame` folds that into `total_.allocBytes` for good.
    //
    // The assertion is scale-free on purpose. A literal ceiling in bytes would
    // be a number nobody can defend on a different machine or a different day;
    // the lifetime counter is the only quantity the broken code can produce,
    // so the cell compares against IT.
    import core.memory : GC;
    import core.thread : Thread;

    FrameWorkProbe fc;

    // Make this thread's lifetime counter a real discriminator BEFORE anything
    // is measured, instead of hoping the modules that ran earlier left enough
    // behind. The first attempt relied on that and the population floor below
    // caught it: in an isolated binary the lifetime total was the same order
    // as one frame, so neither answer could be told from the other.
    ubyte[][] ballast;
    foreach (i; 0 .. 16) {
        auto chunk = new ubyte[](512 * 1024);
        chunk[0] = cast(ubyte)i;
        ballast ~= chunk;                       // kept live: the counter is
    }                                           // cumulative, not a high-water

    // Control first, so a green below cannot mean "this probe reports zero for
    // everything". A frame with a real main-thread allocation and no reset.
    fc.beginFrame();
    auto keepA = new ubyte[](64 * 1024);
    keepA[0] = 1;
    fc.endFrame();
    const clean = fc.last().allocBytes;
    assert(clean > 0, "control frame reported no allocation at all — the "
                    ~ "fixture cannot exhibit the phenomenon it is judging");

    const lifetime = cast(long)GC.allocatedInCurrentThread;
    assert(lifetime > clean * 4, "this thread has not allocated enough for the "
                               ~ "lifetime total to be a discriminator");

    // Now the real shape: the frame is open, the reset arrives from another
    // thread, and the main thread closes the frame.
    fc.beginFrame();
    auto keepB = new ubyte[](64 * 1024);
    keepB[0] = 2;
    auto t = new Thread({ fc.reset(); });
    t.start();
    t.join();
    fc.endFrame();

    const straddled = fc.last().allocBytes;
    assert(straddled < lifetime / 8,
        "a reset from another thread re-based the GC window: the straddling "
        ~ "frame reported this thread's lifetime allocation instead of its own");
    assert(keepA[0] == 1 && keepB[0] == 2, "fixture buffers did not stay live");
    assert(ballast.length == 16 && ballast[15][0] == 15,
        "the ballast that makes the lifetime counter a discriminator was "
        ~ "collected — the comparison above would be against nothing");
}
