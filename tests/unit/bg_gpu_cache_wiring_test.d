/// Task 4680: background GPU residency has one owner and one frame phase.
module tests.unit.bg_gpu_cache_wiring_test;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : count, indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    const app = readText(buildPath(repoRoot, "source", "app.d"));
    const runner = readText(buildPath(repoRoot, "source", "frame_runner.d"));
    const editor = readText(buildPath(repoRoot, "source", "editor_app.d"));
    const renderer = readText(
        buildPath(repoRoot, "source", "ui", "viewport_render.d"));

    // The phase is unique and sits before the per-cell loop. It therefore runs
    // even when every cell takes the no-scene-draw path.
    enum reconcileCall = "frameRunner.reconcileBackgroundGpu(document);";
    enum cellLoop = "foreach (k; overlayDrawOrder(";
    enum contextShutdown = "scope(exit) SDL_GL_DeleteContext(ctx);";
    enum cacheShutdown = "scope(exit) frameRunner.shutdown();";
    assert(app.count(reconcileCall) == 1,
        "background GPU reconciliation must occur exactly once per frame");
    assert(app.count(cellLoop) == 1,
        "frame-phase witness requires exactly one per-cell loop");
    assert(app.indexOf(reconcileCall) < app.indexOf(cellLoop),
        "background GPU reconciliation must precede the per-cell loop");
    assert(app.count(contextShutdown) == 1 && app.count(cacheShutdown) == 1,
        "background cache and GL context each need one shutdown registration");
    assert(app.indexOf(contextShutdown) < app.indexOf(cacheShutdown),
        "LIFO cache shutdown must run before the GL context is deleted");

    // FrameRunner alone owns lifecycle. EditorApp and the renderer receive no
    // map pointer and the draw view exposes neither reconcile nor shutdown.
    assert(runner.count("private BgGpuCache bgGpuCache_;") == 1);
    assert(runner.count("bgGpuCache_ = new BgGpuCache;") == 1);
    assert(runner.count("bgGpuCache_.reconcile(document);") == 1);
    assert(runner.count("bgGpuCache_.shutdown();") == 1);
    assert(editor.count("bgGpuByLayer") == 0);
    assert(app.count("bgGpuByLayer") == 0);
    assert(renderer.count("bgGpuByLayer") == 0);
    assert(renderer.count("BgGpuDrawCache bgGpuCache") == 1);
    assert(renderer.count("bgGpuCache.reconcile") == 0);
    assert(renderer.count("bgGpuCache.shutdown") == 0);
}
