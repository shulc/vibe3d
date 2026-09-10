module tests.unit.handle_pass_scope_test;

import perf_probe : DrawPass, FrameWorkProbe, kMaxHandleReceipts;
import std.algorithm : canFind;

unittest {
    FrameWorkProbe p;
    assert(p.currentHandlePassGeneration() == 0,
           "a registration outside a handle pass must carry generation 0");

    p.beginFrame();
    {
        auto pass = p.handlePass();
        assert(p.currentHandlePassGeneration() == 1,
               "the first open handle pass must carry generation 1");
        {
            auto draw = p.handleDraw(0xAA);
            p.draw(DrawPass.handles, 3);
        }
        {
            auto draw = p.handleDraw(0xAA);
            p.draw(DrawPass.handles, 3);
        }
        {
            auto draw = p.handleDraw(0xBB);
            p.draw(DrawPass.handles, 3);
            p.draw(DrawPass.handles, 3);
        }
    }
    assert(p.currentHandlePassGeneration() == 0,
           "a closed handle pass must stop stamping registrations");

    auto r = p.lastHandlePass();
    assert(r.generation == 1, "first handle-pass generation was not published");
    assert(r.writes == 4, "four raw handle submissions must remain four writes");
    assert(r.submitted == 2, "AA/AA/BB/BB must deduplicate to two identities");
    assert(r.receiptsDropped == 0, "two identities must fit the receipt buffer");
    assert(r.ids[0 .. 2].canFind(0xAA) && r.ids[0 .. 2].canFind(0xBB),
           "the completed pass lost AA or BB");

    p.draw(DrawPass.handles, 3);
    assert(p.lastHandlePass().writes == 4,
           "a submission outside pass and identity scopes must be ignored");

    {
        auto pass = p.handlePass();
        auto draw = p.handleDraw(0xCC);
        p.draw(DrawPass.handles, 3);
    }
    auto r2 = p.lastHandlePass();
    assert(r2.generation == 2, "second pass did not advance generation");
    assert(r2.writes == 1, "second pass accumulated the first pass's writes");
    assert(r2.submitted == 1 && r2.ids[0] == 0xCC,
           "second pass accumulated the first pass's identities");

    p.beginFrame();
    auto sticky = p.lastHandlePass();
    assert(sticky.generation == 2 && sticky.writes == 1,
           "beginFrame cleared the last completed handle pass");

    {
        auto pass = p.handlePass();
        foreach (i; 0 .. kMaxHandleReceipts + 3) {
            auto draw = p.handleDraw(i + 1);
            p.draw(DrawPass.handles, 1);
        }
    }
    auto full = p.lastHandlePass();
    assert(full.submitted == kMaxHandleReceipts,
           "the receipt buffer did not stop at its fixed capacity");
    assert(full.receiptsDropped == 3,
           "receipt overflow was not reported exactly");

    // `/api/frames/counts/reset` can run while the main thread owns this
    // scope. Its destructor must not drive depth negative and poison the next
    // pass; this is the construction defect caught by task 5480's final review.
    {
        auto interrupted = p.handlePass();
        p.reset();
    }
    assert(p.currentHandlePassGeneration() == 0,
           "reset inside a pass left a negative/nonzero handle-pass depth");
    {
        auto afterReset = p.handlePass();
        assert(p.currentHandlePassGeneration() == 1,
               "the first pass after an interrupted reset did not reopen");
        auto draw = p.handleDraw(0xDD);
        p.draw(DrawPass.handles, 1);
    }
    auto after = p.lastHandlePass();
    assert(after.generation == 1 && after.writes == 1
           && after.submitted == 1 && after.ids[0] == 0xDD,
           "the first pass after an interrupted reset lost its receipt");
}
