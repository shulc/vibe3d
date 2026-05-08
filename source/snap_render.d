module snap_render;

import math : Vec3, Viewport, projectToWindowFull;
import snap : SnapResult;
import toolpipe.packets : SnapType;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// Snap visual feedback — Phase 7.3d of doc/snap_plan.md.
//
// drawSnapOverlay() draws a yellow circle / filled disc at the snap
// candidate's projected screen pixel:
//   - Within `outerRangePx` (highlighted, NOT snapped) ⇒ outline only
//     (pre-snap pulse — "if you keep going, this is what you'll snap
//     to").
//   - Within `innerRangePx` (snapped) ⇒ filled disc + ring.
//
// Tools call this from their `draw()` after capturing the most recent
// SnapResult in their motion handler. The renderer is shared because
// every snap-aware tool (Move now, Pen / Create-tools in 7.3f) uses
// the same yellow-circle convention.
//
// `g_lastSnap` is the global "most recent snap result published by any
// tool" — a follow-up HTTP endpoint reads this for headless test
// runs (the test doesn't need a screenshot, just JSON probe).
// ---------------------------------------------------------------------------

__gshared SnapResult g_lastSnap;

/// Update the global last-snap state. Tools call this after every
/// motion event that ran snapCursor, snap-fired or not (so the
/// pre-snap highlight pulse stays current).
void publishLastSnap(SnapResult sr) {
    g_lastSnap = sr;
}

/// Reset the global last-snap. Tools call this at drag end so the
/// stale highlight from the last drag doesn't linger.
void clearLastSnap() {
    g_lastSnap = SnapResult.init;
}

/// Draw the snap overlay for `result`. No-op when `!result.highlighted`
/// (the cursor isn't near any snap target this frame). Picks the
/// pixel from `result.highlightPos` (which equals `worldPos` when
/// snapped, or the closest candidate when only highlighted).
void drawSnapOverlay(const ref SnapResult result, const ref Viewport vp) {
    if (!result.highlighted) return;
    float sx, sy, ndcZ;
    if (!projectToWindowFull(result.highlightPos, vp, sx, sy, ndcZ))
        return;

    auto dl = ImGui.GetForegroundDrawList();
    auto pos = ImVec2(sx, sy);

    // MODO-style yellow (matches the existing test-mode cursor
    // colour at app.d:3235).
    enum uint outlineCol = IM_COL32(255, 220,   0, 230);
    enum uint fillCol    = IM_COL32(255, 220,   0, 140);

    enum float outerR = 10.0f;   // ring radius
    enum float innerR =  4.0f;   // filled-disc radius (snapped only)

    if (result.snapped) {
        dl.AddCircleFilled(pos, innerR, fillCol, 16);
        dl.AddCircle(pos, outerR, outlineCol, 24, 2.0f);
    } else {
        // Pre-snap: outline only, slightly thinner.
        dl.AddCircle(pos, outerR, outlineCol, 24, 1.5f);
    }
}
