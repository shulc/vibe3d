// The frame-allocation probe excludes request-timed bridge work (task 5752).
module tests.unit.frame_probe_window_wiring_test;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : count, indexOf, lastIndexOf, strip;
import tests.unit.census_symbols : blankNonCode;

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

unittest { // 6357: frame-count service is the unique pre-probe owner boundary
    import std.file : dirEntries, SpanMode;
    import std.regex : matchAll, regex, replaceAll;

    immutable appPath = buildPath(repoRoot, "source", "app.d");
    immutable app = blankNonCode(readText(appPath));
    enum service = "httpServer.tickFrameCounts(g_fc);";
    enum timing = "g_frames.beginFrame();";
    enum allocation = "g_fc.beginFrame();";
    enum drain = "httpServer.tickAll();";
    assert(app.count(service) == 1,
        "6357 owner boundary requires exactly one frame-count call in app.d");
    immutable timingAt = app.indexOf(timing);
    immutable serviceAt = app.indexOf(service);
    immutable allocationAt = app.indexOf(allocation);
    immutable drainAt = app.indexOf(drain);
    immutable loopAt = app.lastIndexOf("while (running) {", timingAt);
    assert(loopAt >= 0 && serviceAt > loopAt && timingAt > serviceAt
        && allocationAt > timingAt && drainAt > allocationAt,
        "6357 frame-count owner service must precede both probe begins and the general drain");
    auto prefix = app[loopAt + "while (running) {".length .. timingAt]
        .replaceAll(regex(`\s+`), " ").strip;
    assert(prefix == "if (httpServer.running) httpServer.tickFrameCounts(g_fc);",
        "6357 tickFrameCounts must be the statement directly before the timing probe begins");

    size_t files;
    size_t allHits;
    size_t appHits;
    size_t serverHits;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d",
                               SpanMode.depth)) {
        ++files;
        immutable code = blankNonCode(readText(entry.name));
        size_t hits;
        foreach (_; code.matchAll(regex(`\btickFrameCounts\b`))) ++hits;
        allHits += hits;
        if (entry.name == appPath) appHits = hits;
        if (entry.name == buildPath(repoRoot, "source", "http_server.d"))
            serverHits = hits;
    }
    assert(files >= 500, "6357 source census population fell below 500 modules");
    assert(allHits == 2,
        "6357 tickFrameCounts identifier count must be 2 in source/**");
    assert(appHits == 1 && serverHits == 1,
        "6357 tickFrameCounts must have one app call and one server definition");
}
