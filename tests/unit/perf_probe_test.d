// Focused: dmd -unittest -version=PerfProbe -i -I. -Isource -Itests/unit
//          -of=<out> tests/unit/perf_probe_test.d <main.d>
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

static assert([__traits(allMembers, FrameProbeSnapshot)] ==
              ["frames", "stats", "hitchGc16", "sumCacheNs"],
              "6511 FrameProbeSnapshot must remain detached data only");

private enum bool frameStatsIsNothrow = (() {
    import std.meta : staticIndexOf;
    return staticIndexOf!("nothrow",
        __traits(getFunctionAttributes, FrameProbe.stats)) >= 0;
})();
private enum bool frameResetIsNothrow = (() {
    import std.meta : staticIndexOf;
    return staticIndexOf!("nothrow",
        __traits(getFunctionAttributes, FrameProbe.reset)) >= 0;
})();
static assert(frameStatsIsNothrow,
    "6511 FrameProbe.stats must remain nothrow in both module versions");
static assert(frameResetIsNothrow,
    "6511 FrameProbe.reset must remain nothrow in both module versions");

private enum size_t kFrameFixtureN = 25;
private static immutable size_t[2][18] kFrameFixturePerm = [
    [2, 0], [3, 0], [4, 0], [6, 0], [7, 0], [8, 0], [9, 0], [2, 20],
    [11, 0], [12, 0], [13, 0], [14, 0], [16, 0], [17, 0], [18, 0],
    [19, 0], [21, 0], [22, 0],
];

private size_t frameFixtureIndex(size_t field, size_t row) {
    return (row * kFrameFixturePerm[field][0]
            + kFrameFixturePerm[field][1]) % kFrameFixtureN;
}

private FrameProbeSnapshot frameProbeWireFixture() {
    FrameProbeSnapshot snapshot;
    snapshot.frames = new FrameRec[kFrameFixtureN];
    foreach (row; 0 .. kFrameFixtureN) {
        long value(size_t field) {
            return cast(long)((field + 1) * 100_000
                + frameFixtureIndex(field, row) * 100 + 7);
        }
        auto r = &snapshot.frames[row];
        r.totalNs = value(0); r.eventNs = value(1); r.toolNs = value(2);
        r.cacheNs = value(3); r.drawNs = value(4); r.uploadNs = value(5);
        r.uiNs = value(6); r.gcAllocBytes = value(7);
        r.gcCollections = value(8); r.gcMaxPauseNs = value(9);
        r.gcPauseNs = value(10); r.gcCollectNs = value(11);
        r.eventAlloc = value(12); r.toolAlloc = value(13);
        r.cacheAlloc = value(14); r.drawAlloc = value(15);
        r.uploadAlloc = value(16); r.uiAlloc = value(17);
    }
    snapshot.stats = FrameStatsSnapshot(9_100_001, 9_200_002, 9_300_003,
        9_400_004, 9_500_005, 9_600_006, 9_700_007, 9_800_008);
    snapshot.hitchGc16 = 9_900_009;
    snapshot.sumCacheNs = 10_000_010;
    return snapshot;
}

private immutable frameProbeWireBytes = `{"frameCount":9100001,"total":{"p50_ns":101207,"p95_ns":102207,"p99_ns":102307,"max_ns":102407},"phases":{"eventNs":{"p95_ns":202207},"toolNs":{"p95_ns":302207},"cacheNs":{"p95_ns":402207},"drawNs":{"p95_ns":502207},"uploadNs":{"p95_ns":602207},"uiNs":{"p95_ns":702207}},"hitch_16ms":9200002,"hitch_33ms":9300003,"meshCacheRebuilds":9600006,"gcAllocBytes":9400004,"gcCollections":9500005,"gcPauseNs":9700007,"gcMaxPauseNs":9800008,"gcHitch_16ms":9900009,"steadyMaxAllocBytes":802307,"sumCacheNs":10000010,"worst":{"totalNs":102407,"eventNs":201107,"toolNs":302307,"cacheNs":402207,"drawNs":500907,"uploadNs":602107,"uiNs":700807,"gcAllocBytes":801907,"gcCollections":900707,"gcMaxPauseNs":1001907,"gcPauseNs":1100607,"gcCollectNs":1201807,"eventAlloc":1301707,"toolAlloc":1400407,"cacheAlloc":1501607,"drawAlloc":1600307,"uploadAlloc":1700207,"uiAlloc":1801407},"worstN":[{"totalNs":102407,"eventNs":201107,"toolNs":302307,"cacheNs":402207,"drawNs":500907,"uploadNs":602107,"uiNs":700807,"gcAllocBytes":801907,"gcCollections":900707,"gcMaxPauseNs":1001907,"gcPauseNs":1100607,"gcCollectNs":1201807,"eventAlloc":1301707,"toolAlloc":1400407,"cacheAlloc":1501607,"drawAlloc":1600307,"uploadAlloc":1700207,"uiAlloc":1801407},{"totalNs":102307,"eventNs":202207,"toolNs":302107,"cacheNs":401907,"drawNs":501807,"uploadNs":601707,"uiNs":701607,"gcAllocBytes":801807,"gcCollections":901407,"gcMaxPauseNs":1001307,"gcPauseNs":1101207,"gcCollectNs":1201107,"eventAlloc":1300907,"toolAlloc":1400807,"cacheAlloc":1500707,"drawAlloc":1600607,"uploadAlloc":1700407,"uiAlloc":1800307},{"totalNs":102207,"eventNs":200807,"toolNs":301907,"cacheNs":401607,"drawNs":500207,"uploadNs":601307,"uiNs":702407,"gcAllocBytes":801707,"gcCollections":902107,"gcMaxPauseNs":1000707,"gcPauseNs":1101807,"gcCollectNs":1200407,"eventAlloc":1300107,"toolAlloc":1401207,"cacheAlloc":1502307,"drawAlloc":1600907,"uploadAlloc":1700607,"uiAlloc":1801707},{"totalNs":102107,"eventNs":201907,"toolNs":301707,"cacheNs":401307,"drawNs":501107,"uploadNs":600907,"uiNs":700707,"gcAllocBytes":801607,"gcCollections":900307,"gcMaxPauseNs":1000107,"gcPauseNs":1102407,"gcCollectNs":1202207,"eventAlloc":1301807,"toolAlloc":1401607,"cacheAlloc":1501407,"drawAlloc":1601207,"uploadAlloc":1700807,"uiAlloc":1800607},{"totalNs":102007,"eventNs":200507,"toolNs":301507,"cacheNs":401007,"drawNs":502007,"uploadNs":600507,"uiNs":701507,"gcAllocBytes":801507,"gcCollections":901007,"gcMaxPauseNs":1002007,"gcPauseNs":1100507,"gcCollectNs":1201507,"eventAlloc":1301007,"toolAlloc":1402007,"cacheAlloc":1500507,"drawAlloc":1601507,"uploadAlloc":1701007,"uiAlloc":1802007},{"totalNs":101907,"eventNs":201607,"toolNs":301307,"cacheNs":400707,"drawNs":500407,"uploadNs":600107,"uiNs":702307,"gcAllocBytes":801407,"gcCollections":901707,"gcMaxPauseNs":1001407,"gcPauseNs":1101107,"gcCollectNs":1200807,"eventAlloc":1300207,"toolAlloc":1402407,"cacheAlloc":1502107,"drawAlloc":1601807,"uploadAlloc":1701207,"uiAlloc":1800907},{"totalNs":101807,"eventNs":200207,"toolNs":301107,"cacheNs":400407,"drawNs":501307,"uploadNs":602207,"uiNs":700607,"gcAllocBytes":801307,"gcCollections":902407,"gcMaxPauseNs":1000807,"gcPauseNs":1101707,"gcCollectNs":1200107,"eventAlloc":1301907,"toolAlloc":1400307,"cacheAlloc":1501207,"drawAlloc":1602107,"uploadAlloc":1701407,"uiAlloc":1802307},{"totalNs":101707,"eventNs":201307,"toolNs":300907,"cacheNs":400107,"drawNs":502207,"uploadNs":601807,"uiNs":701407,"gcAllocBytes":801207,"gcCollections":900607,"gcMaxPauseNs":1000207,"gcPauseNs":1102307,"gcCollectNs":1201907,"eventAlloc":1301107,"toolAlloc":1400707,"cacheAlloc":1500307,"drawAlloc":1602407,"uploadAlloc":1701607,"uiAlloc":1801207}]}`;

version (PerfProbe) {
    private void seedFrame(ref FrameProbe probe, long drawNs) {
        probe.beginFrame();
        probe.addPhase(Phase.draw, drawNs);
        probe.endFrame();
    }

    unittest { // 6511 PP-1: the ring is detached from later writes
        import std.algorithm.searching : canFind;

        FrameProbe probe;
        foreach (i; 0 .. 5) seedFrame(probe, 100 + i);
        auto snapshot = probe.snapshot();
        probe.reset();
        foreach (i; 0 .. 5) seedFrame(probe, 900 + i);
        FrameRec[5] recent;
        assert(probe.copyRecent(recent[]) == 5 && recent[$ - 1].drawNs == 904,
            "6511 detach premise did not overwrite the live ring");
        assert(snapshot.frames.length == 5,
            "6511 detached snapshot population changed");
        foreach (i, ref frame; snapshot.frames)
            assert(frame.drawNs == 100 + i,
                "6511 snapshot aliased the live ring: frames[0].drawNs");
        assert(snapshot.toJson().canFind(`"drawNs":{"p95_ns":103}`),
            "6511 detached snapshot lost its original draw percentile");
    }

    unittest { // 6511 PP-2: aggregates belong to the captured snapshot
        import std.algorithm.searching : canFind;

        scope(exit) g_frames.reset();
        g_frames.reset();
        foreach (i; 0 .. 3) seedFrame(g_frames, 100 + i);
        auto snapshot = g_frames.snapshot();
        foreach (i; 0 .. 4) seedFrame(g_frames, 900 + i);
        assert(g_frames.stats().frameCount == 7,
            "6511 live aggregate premise did not advance to seven frames");
        assert(snapshot.frames.length == 3,
            "6511 aggregate fixture lost its three captured records");
        assert(snapshot.stats.frameCount == 3,
            "6511 snapshot copied the wrong aggregate: frameCount");
        assert(snapshot.toJson().canFind(`"frameCount":3`),
            "6511 snapshot served a live aggregate: frameCount");
    }

    unittest { // 6511 REVIEW FIX: seed the wire-only cache accumulator
        import std.algorithm.searching : canFind;

        FrameProbe probe;
        foreach (_; 0 .. 3) {
            probe.beginFrame();
            probe.addPhase(Phase.cache, 4242);
            probe.endFrame();
        }
        auto snapshot = probe.snapshot();
        assert(snapshot.frames.length == 3,
            "6511 cache-seed fixture lost its three records");
        assert(snapshot.sumCacheNs == 3 * 4242,
            "6511 snapshot dropped sumCacheNs, which /api/frames publishes as "
            ~ "sumCacheNs and tools/perf/lib/http.d reads");
        assert(snapshot.toJson().canFind(`"sumCacheNs":12726`),
            "6511 the wire lost the seeded sumCacheNs value");
    }

    unittest { // 6511 PP-3: running aggregates survive ring eviction
        FrameProbe probe;
        foreach (i; 0 .. 8195) seedFrame(probe, 100 + i);
        auto snapshot = probe.snapshot();
        assert(snapshot.frames.length == 8192,
            "6511 FrameProbe ring population must remain 8192");
        assert(snapshot.stats.frameCount == 8195,
            "6511 aggregates must survive ring eviction: frameCount");
    }

    unittest { // 6511 PP-4: owner service must precede the allocation window
        FrameProbe insideProbe;
        foreach (i; 0 .. 25) seedFrame(insideProbe, 100 + i);
        insideProbe.beginFrame();
        auto insideSnapshot = insideProbe.snapshot();
        insideProbe.endFrame();
        FrameRec[1] insideRecent;
        assert(insideSnapshot.frames.length == 25,
            "6511 inside-window allocation fixture lost its 25 records");
        assert(insideProbe.copyRecent(insideRecent[]) == 1);
        assert(insideRecent[0].gcAllocBytes >= 25 * FrameRec.sizeof,
            "6511 snapshot allocation did not enter the open frame window");

        FrameProbe outsideProbe;
        foreach (i; 0 .. 25) seedFrame(outsideProbe, 100 + i);
        auto outsideSnapshot = outsideProbe.snapshot();
        outsideProbe.beginFrame();
        outsideProbe.endFrame();
        FrameRec[1] outsideRecent;
        assert(outsideSnapshot.frames.length == 25,
            "6511 outside-window allocation fixture lost its 25 records");
        assert(outsideProbe.copyRecent(outsideRecent[]) == 1);
        assert(outsideRecent[0].gcAllocBytes == 0,
            "6511 owner snapshot allocation leaked into the next frame");
    }

    unittest { // 6511 PP-5: reset preserves the in-flight method contract
        FrameProbe probe;
        probe.beginFrame();
        probe.addPhase(Phase.draw, 777);
        probe.addPhaseAlloc(Phase.draw, 888);
        probe.bumpMeshCacheRebuild();
        probe.reset();
        probe.endFrame();
        FrameRec[1] recent;
        assert(probe.copyRecent(recent[]) == 1,
            "6511 reset contract fixture must commit exactly one frame");
        assert(recent[0].drawNs == 777,
            "6511 reset disturbed the in-flight frame: drawNs");
        assert(recent[0].drawAlloc == 888,
            "6511 reset disturbed the in-flight frame: drawAlloc");
        assert(recent[0].totalNs < 1_000_000_000,
            "6511 reset re-based frameStart: totalNs");
        assert(probe.stats().frameCount == 1
            && probe.stats().meshCacheRebuilds == 0,
            "6511 reset did not preserve the published-counter contract");
    }
}

unittest { // 6511 PP-6/PP-7: byte wire and idempotence
    import std.digest : toHexString;
    import std.digest.sha : sha256Of;
    import std.regex : regex, replaceAll;
    import std.algorithm.searching : canFind;

    auto snapshot = frameProbeWireFixture();
    assert(snapshot.frames.length == 25,
        "6511 frame-probe fixture must retain 25 distinct records");
    auto first = snapshot.toJson();

    // Narrow needles stay above the broad byte/length pins so the first red
    // line names the serializer defect rather than only the changed payload.
    {
        import std.json : parseJSON;
        auto j = parseJSON(first);
        auto tot = j["total"];
        long trueMax = 0;
        foreach (ref r; snapshot.frames)
            if (r.totalNs > trueMax) trueMax = r.totalNs;
        assert(tot["max_ns"].integer == trueMax,
            "6511 total.max_ns is not the largest totalNs: the totals sort "
            ~ "was lost");
        assert(tot["p50_ns"].integer <= tot["p95_ns"].integer
            && tot["p95_ns"].integer <= tot["p99_ns"].integer
            && tot["p99_ns"].integer <= tot["max_ns"].integer,
            "6511 total percentile channels are out of order: p50/p95/p99 "
            ~ "were swapped");
        assert(j["worstN"].array.length == 8,
            "6511 worstN population floor: the bounded list is not 8 long");
        foreach (i; 1 .. j["worstN"].array.length)
            assert(j["worstN"][i - 1]["totalNs"].integer
                 > j["worstN"][i]["totalNs"].integer,
                "6511 worstN is not descending: the byWorst sort was lost");
        assert(j["worstN"][0]["totalNs"].integer == j["worst"]["totalNs"].integer,
            "6511 worstN head is not the worst frame");
        assert(snapshot.frames[0].totalNs == 100_007
            && snapshot.frames[$ - 1].totalNs == 102_307,
            "6511 the serializer reordered the caller's ring in place");
        static immutable string[6] names =
            ["eventNs", "toolNs", "cacheNs", "drawNs", "uploadNs", "uiNs"];
        foreach (pi, name; names) {
            long[] col = new long[kFrameFixtureN];
            foreach (i, ref r; snapshot.frames) {
                final switch (pi) {
                    case 0: col[i] = r.eventNs;  break;
                    case 1: col[i] = r.toolNs;   break;
                    case 2: col[i] = r.cacheNs;  break;
                    case 3: col[i] = r.drawNs;   break;
                    case 4: col[i] = r.uploadNs; break;
                    case 5: col[i] = r.uiNs;     break;
                }
            }
            import std.algorithm : sort;
            col.sort();
            assert(j["phases"][name]["p95_ns"].integer
                 == col[(kFrameFixtureN - 1) * 95 / 100],
                "6511 phase p95 is not the sorted column's 95th percentile: "
                ~ name);
        }
    }
    assert(first.length == 3665,
        "6511 frame-probe fixture must retain its measured 3665-byte population");
    assert(first == frameProbeWireBytes, "6511 frame-probe wire bytes changed");
    assert(snapshot.frames.length == 25,
        "6511 serializer mutated the frame fixture population");
    assert(snapshot.toJson() == first,
        "6511 frame-probe serialization must be idempotent");
    auto shape = first.replaceAll(regex(`-?\d+`), "0");
    assert(shape.length == 2646 && shape.canFind(`"worstN":[`),
        "6511 phase-0 wire skeleton lost its measured population");
    assert(sha256Of(shape).toHexString ==
           "69F7CD7E3E4A5744AC4961B5D61648E7B358AD19614B7DE5E50A7E9154C755E2",
        "6511 frame-probe wire shape changed from the phase-0 golden");
}

unittest { // 6511 REVIEW FIX: percentile index arithmetic is observable
    import std.json : parseJSON;

    enum size_t n = 101;
    FrameProbeSnapshot snapshot;
    snapshot.frames = new FrameRec[n];
    foreach (i, ref r; snapshot.frames) {
        immutable v = cast(long)i;
        r.totalNs = 1_000 + v;
        r.eventNs = 2_000 + v;
        r.toolNs = 3_000 + v;
        r.cacheNs = 4_000 + v;
        r.drawNs = 5_000 + v;
        r.uploadNs = 6_000 + v;
        r.uiNs = 7_000 + v;
    }
    auto j = parseJSON(snapshot.toJson());
    assert(j["total"]["p50_ns"].integer == 1_050,
        "6511 total p50 index moved from 50 to 51");
    assert(j["total"]["p95_ns"].integer == 1_095,
        "6511 total p95 index moved from 95 to 94");
    assert(j["total"]["p99_ns"].integer == 1_099,
        "6511 total p99 index moved from 99 to 98");
    static immutable string[6] names =
        ["eventNs", "toolNs", "cacheNs", "drawNs", "uploadNs", "uiNs"];
    foreach (pi, name; names)
        assert(j["phases"][name]["p95_ns"].integer
               == cast(long)((pi + 2) * 1_000 + 95),
            "6511 phase p95 index moved from 95 to 94: " ~ name);
}

unittest { // 6511 REVIEW FIX: pin the lower edge of the steady window
    import std.json : parseJSON;

    FrameProbeSnapshot snapshot;
    snapshot.frames = new FrameRec[5];
    static immutable long[5] allocs = [9, 9, 9, 7, 5];
    foreach (i, ref r; snapshot.frames) {
        r.totalNs = cast(long)(100 + i);
        r.gcAllocBytes = allocs[i];
    }
    auto j = parseJSON(snapshot.toJson());
    assert(j["steadyMaxAllocBytes"].integer == 7,
        "6511 steady allocation window no longer starts at frame index 3");
}

unittest { // 6511 REVIEW FIX: constructor and strict warmup guard census
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.regex : matchAll, regex;
    import std.string : count;
    import tests.unit.census_symbols : blankNonCode;

    enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable source = blankNonCode(readText(
        buildPath(repoRoot, "source", "perf_probe.d")));
    size_t ctorHits;
    foreach (_; source.matchAll(regex(
        `return\s+FrameProbeSnapshot\s*\(\s*ring\[0\s*\.\.\s*ringLen\]\.dup\s*,` ~
        `\s*stats\(\)\s*,\s*hitchGc16\s*,\s*sumCacheNs\s*\)\s*;`)))
        ++ctorHits;
    assert(ctorHits == 1,
        "6511 snapshot ctor dropped a field the wire reads "
        ~ "(gcHitch_16ms/sumCacheNs)");
    assert(source.count("if (len > WarmupFrames)") == 1,
        "6511 steady-window guard lost its strict lower-edge spelling");
}
