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
    enum frameFinish = "frameRunner.finishFrame(";

    assert(app.count(timingBegin) == 1
        && app.count(bridgeDrain) == 1
        && app.count(allocationBegin) == 1
        && app.count(frameFinish) == 1,
        "frame allocation ordering witness requires one timing begin, bridge "
        ~ "drain, allocation begin, and frame finish call in app.d");

    const timingAt = app.indexOf(timingBegin);
    const drainAt = app.indexOf(bridgeDrain);
    const allocationAt = app.indexOf(allocationBegin);
    const finishAt = app.indexOf(frameFinish);
    assert(timingAt < drainAt,
        "main-thread bridge drain escaped the whole-frame timing window");
    assert(drainAt < allocationAt,
        "frame allocation probe begins before the main-thread bridge drain; "
        ~ "request timing can make lastScene.allocBytes bimodal");
    assert(allocationAt < finishAt,
        "frame allocation probe must begin before FrameRunner closes it");
}
