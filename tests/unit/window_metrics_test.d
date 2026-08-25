// The window-resize metrics law (task 0781 step 2e, plan §6.1).
//
// WHY THIS FILE EXISTS. `InputRouter.handleWindowEvent` had ZERO coverage and
// could not be given any from an event log, which is worth stating precisely
// because "add a fixture" is the obvious wrong answer:
//
//   * `EventLogger` records `w`/`h` for `SDL_WINDOWEVENT_SIZE_CHANGED` and
//     `EventPlayer` parses them back, so a `sub:6` line in a `tests/events/*.log`
//     really does reach the handler;
//   * but the handler feeds that payload to `SDL_SetWindowSize` ONLY under
//     `playbackMode`, which is true for `--playback` and FALSE under
//     `/api/play-events` — the way every suite test drives the app;
//   * everything downstream then comes from `SDL_GetWindowSize`, i.e. from the
//     real, unresized window.
//
// So a `sub:6` fixture would run the handler and assert nothing: a check that
// cannot come out differently. The SDL-free half is extracted instead
// (`input_router.applyWindowMetrics`) and driven directly here.
//
// WHAT IS STILL UNWITNESSED, named rather than implied: the SDL half
// (`SDL_SetWindowSize` / `SDL_GetWindowSize` / `SDL_GL_GetDrawableSize`,
// `glViewport`, `initThickLineProgram`, `setReplayCurrentViewport`). No test in
// either lane can reach it while `--test` never resizes the window.
module tests.unit.window_metrics_test;

import editor_app   : Layout;
import input_router : applyWindowMetrics;
import viewport     : ViewportManager, LayoutPreset;

unittest {
    // ── THE LAYOUT LAW ──
    //
    // Two sizes, so no constant satisfies it. `Layout.resize`'s own arithmetic
    // is `vpW = winW - sideW` and `vpH = winH - 2 * statusH` over the shipped
    // defaults `sideW = 150` / `statusH = 28`; the numbers are spelled out
    // rather than recomputed from the fields, so a change to either default has
    // to be a deliberate edit here too.
    //
    // First of three blocks on purpose: druntime stops a module at its first
    // failed assertion, and the three mutations this file is meant to catch are
    // different (drop the `layout.resize` call; drop a `vpm.l*` write; delete
    // the per-cell reflow loop). Ordering them innermost-first keeps each
    // mutation's own message the one that prints.
    foreach (wh; [[1280, 800], [1024, 768]]) {
        immutable int w = wh[0], h = wh[1];

        Layout layout;
        auto vpm = new ViewportManager(0, 0, 640, 480);
        vpm.lx = 0; vpm.ly = 0; vpm.lw = 640; vpm.lh = 480;

        applyWindowMetrics(layout, vpm, w, h);

        assert(layout.vpX == 150,
               "the viewport starts right of the 150 px side panel");
        assert(layout.vpY == 28,
               "the viewport starts below the 28 px tab bar");
        assert(layout.vpW == w - 150,
               "vpW must be the window width less the side panel; expected "
               ~ istr(w - 150) ~ ", got " ~ istr(layout.vpW));
        assert(layout.vpH == h - 56,
               "vpH must be the window height less the tab bar AND the status "
               ~ "bar (2 x 28); expected " ~ istr(h - 56) ~ ", got "
               ~ istr(layout.vpH));
    }
}

unittest {
    // ── THE PICKING REGION FOLLOWS THE LAYOUT ──
    //
    // `vpm.l*` is what `viewportUnderCursor` and `applyLayout` read, and this
    // handler is its single event-driven writer. Asserted for BOTH presets: a
    // Single-only check would be satisfied by a Quad tree that forgot the copy,
    // since nothing else in this function depends on the preset.
    foreach (preset; [LayoutPreset.Single, LayoutPreset.Quad]) {
        foreach (wh; [[1280, 800], [1024, 768]]) {
            immutable int w = wh[0], h = wh[1];

            Layout layout;
            auto vpm = new ViewportManager(0, 0, 640, 480);
            vpm.lx = 0; vpm.ly = 0; vpm.lw = 640; vpm.lh = 480;
            vpm.applyLayout(preset);

            applyWindowMetrics(layout, vpm, w, h);

            assert(vpm.lx == layout.vpX && vpm.ly == layout.vpY
                && vpm.lw == layout.vpW && vpm.lh == layout.vpH,
                   "vpm.l* must equal the layout's viewport rect after a "
                   ~ "resize; layout says ("
                   ~ istr(layout.vpX) ~ "," ~ istr(layout.vpY) ~ ","
                   ~ istr(layout.vpW) ~ "," ~ istr(layout.vpH) ~ ") and vpm says ("
                   ~ istr(vpm.lx) ~ "," ~ istr(vpm.ly) ~ ","
                   ~ istr(vpm.lw) ~ "," ~ istr(vpm.lh) ~ ")");
        }
    }
}

unittest {
    // ── THE LIVE CELLS TILE THE NEW RECT EXACTLY ──
    //
    // The discriminating half, and the reason the manager is CONSTRUCTED at
    // 640x480 and then resized to something else: the ctor and `applyLayout`
    // already leave every cell tiling the OLD rect, so a reflow loop that never
    // runs leaves plausible-looking rects behind. Only a resize to a different
    // size can tell "the loop ran" from "the cells were already right".
    //
    // Edge-to-edge is asserted as a SUM (`views[0].winW + views[1].winW ==
    // vpm.lw`) rather than per-cell against a recomputed half, so an odd width
    // — 1130 and 874 below are both even, but the law must not depend on that —
    // cannot be satisfied by a gap or an overlap of one pixel.
    foreach (wh; [[1280, 800], [1024, 768]]) {
        immutable int w = wh[0], h = wh[1];

        // ---- Single: the one live cell IS the rect ----
        {
            Layout layout;
            auto vpm = new ViewportManager(0, 0, 640, 480);
            vpm.lx = 0; vpm.ly = 0; vpm.lw = 640; vpm.lh = 480;
            vpm.applyLayout(LayoutPreset.Single);

            applyWindowMetrics(layout, vpm, w, h);

            assert(vpm.cellCount == 1, "precondition: Single gives one cell");
            assert(vpm.views[0].winX == vpm.lx && vpm.views[0].winY == vpm.ly
                && vpm.views[0].winW == vpm.lw && vpm.views[0].winH == vpm.lh,
                   "Single's only cell must cover the whole picking region; "
                   ~ "expected (" ~ istr(vpm.lx) ~ "," ~ istr(vpm.ly) ~ ","
                   ~ istr(vpm.lw) ~ "," ~ istr(vpm.lh) ~ "), got ("
                   ~ istr(vpm.views[0].winX) ~ "," ~ istr(vpm.views[0].winY) ~ ","
                   ~ istr(vpm.views[0].winW) ~ "," ~ istr(vpm.views[0].winH) ~ ")");
        }

        // ---- Quad: four tiles, no gap, no overlap ----
        {
            Layout layout;
            auto vpm = new ViewportManager(0, 0, 640, 480);
            vpm.lx = 0; vpm.ly = 0; vpm.lw = 640; vpm.lh = 480;
            vpm.applyLayout(LayoutPreset.Quad);

            applyWindowMetrics(layout, vpm, w, h);

            assert(vpm.cellCount == 4, "precondition: Quad gives four cells");
            assert(vpm.views[0].winW + vpm.views[1].winW == vpm.lw,
                   "the top row must span the picking region edge to edge; "
                   ~ istr(vpm.views[0].winW) ~ " + " ~ istr(vpm.views[1].winW)
                   ~ " != " ~ istr(vpm.lw)
                   ~ " (the per-cell reflow never ran, or it ran on the old rect)");
            assert(vpm.views[0].winH + vpm.views[2].winH == vpm.lh,
                   "the left column must span the picking region top to bottom; "
                   ~ istr(vpm.views[0].winH) ~ " + " ~ istr(vpm.views[2].winH)
                   ~ " != " ~ istr(vpm.lh));
            assert(vpm.views[3].winX == vpm.lx + vpm.lw / 2,
                   "the right column must start at the vertical split; expected "
                   ~ istr(vpm.lx + vpm.lw / 2) ~ ", got " ~ istr(vpm.views[3].winX));
            assert(vpm.views[2].winY == vpm.ly + vpm.lh / 2,
                   "the bottom row must start at the horizontal split; expected "
                   ~ istr(vpm.ly + vpm.lh / 2) ~ ", got " ~ istr(vpm.views[2].winY));
            assert(vpm.views[0].winX == vpm.lx && vpm.views[0].winY == vpm.ly,
                   "the top-left cell must sit at the picking region's origin");
        }
    }
}

// Kept out of the assertions so a failing message stays readable, and named
// short because every message above interpolates several of them.
private string istr(int v) {
    import std.conv : to;
    return v.to!string;
}
