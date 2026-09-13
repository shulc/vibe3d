// The frame-allocation probe excludes request-timed bridge work (task 5752).
module tests.unit.frame_probe_window_wiring_test;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : count, indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    const app = readText(buildPath(repoRoot, "source", "app.d"));
    enum timingBegin = "g_frames.beginFrame();";
    enum bridgeDrain = "httpServer.tickAll();";
    enum allocationBegin = "g_fc.beginFrame();";
    enum allocationRebase = "g_fc.rebaseAllocationWindow();";
    enum frameFinish = "frameRunner.finishFrame(";

    assert(app.count(timingBegin) == 1
        && app.count(bridgeDrain) == 1
        && app.count(allocationBegin) == 1
        && app.count(allocationRebase) == 1
        && app.count(frameFinish) == 1,
        "frame allocation ordering witness requires one timing begin, bridge "
        ~ "drain, allocation begin, allocation rebase, and frame finish call "
        ~ "in app.d");

    const timingAt = app.indexOf(timingBegin);
    const drainAt = app.indexOf(bridgeDrain);
    const allocationAt = app.indexOf(allocationBegin);
    const rebaseAt = app.indexOf(allocationRebase);
    const finishAt = app.indexOf(frameFinish);
    assert(timingAt < allocationAt && allocationAt < drainAt,
        "main-thread bridge drain must retain its original frame/event order "
        ~ "inside the open probes");
    assert(drainAt < rebaseAt,
        "frame allocation baseline was not retaken after the main-thread "
        ~ "bridge drain; request timing can make lastScene.allocBytes bimodal");
    assert(rebaseAt < finishAt,
        "frame allocation baseline must be retaken before FrameRunner closes "
        ~ "the probe");
}
