module ui.pie_render;

// ---------------------------------------------------------------------------
// Draw the open pie menu (task 1800).
//
// Emits into `GetForegroundDrawList()` — the ring must sit over every docked
// panel and every viewport cell, and it belongs to no window: it is anchored
// at the pixel where the chord was pressed, which may be anywhere.
//
// Nothing here hit-tests. Aiming is decided in the event pump
// (`pie_state.aimPie`) off raw SDL motion, BEFORE ImGui or any viewport sees
// the event, so what is drawn is a readout of `g_pie.hover` and can never
// disagree with what a release will fire.
//
// Colours are `imgui_style`'s popup chrome (grey plate, beige hover, flat
// black border) so a pie reads as the same object as the status-bar dropdowns
// its items are shared with.
// ---------------------------------------------------------------------------

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : PI, sin, cos;

import buttonset       : PieMenu, Button, ActionKind;
import pie_state       : g_pie;
import pie_menus       : findPieMenu;
import pie_geometry    : PIE_DEAD_ZONE_PX, slotCenterAngle;
import popup_state     : resolveChecked;

// Ring geometry, window pixels.
private enum float RING_INNER = PIE_DEAD_ZONE_PX;   // == the aiming dead zone,
                                                    // so the hole you see IS
                                                    // the region that selects
                                                    // nothing
private enum float RING_OUTER = 124.0f;
// Labels sit past the halfway mark rather than on it: a wedge widens with
// radius, so the outer third is where a long word like "Perspective" fits
// between its two seams.
private enum float LABEL_R    = RING_INNER + (RING_OUTER - RING_INNER) * 0.62f;
private enum int   ARC_SEGS   = 24;

private enum ImU32 COL_PLATE   = IM_COL32(143, 143, 143, 235);
private enum ImU32 COL_HOVER   = IM_COL32(197, 197, 183, 245);
private enum ImU32 COL_EDGE    = IM_COL32(0, 0, 0, 255);
private enum ImU32 COL_TEXT    = IM_COL32(20, 20, 20, 255);
private enum ImU32 COL_TEXT_HI = IM_COL32(0, 0, 0, 255);
private enum ImU32 COL_TEXT_OFF= IM_COL32(90, 90, 90, 255);
private enum ImU32 COL_TITLE   = IM_COL32(235, 235, 235, 230);
private enum ImU32 COL_HUB     = IM_COL32(60, 60, 60, 220);

/// Draw the ring if one is open. `refusalOf` answers "why can this item not
/// run right now" (empty = it can) — the same policy the side panel and the
/// status bar use, passed in as a delegate so this module stays free of the
/// app's registry and document.
void drawPieMenu(scope string delegate(ref Button) refusalOf = null) {
    if (!g_pie.open) return;

    auto m = findPieMenu(g_pie.menuId);
    if (m is null) return;

    immutable int n = cast(int) m.items.length;
    if (n <= 0) return;

    auto dl = ImGui.GetForegroundDrawList();
    immutable ImVec2 c = ImVec2(cast(float) g_pie.cx, cast(float) g_pie.cy);
    immutable float  w = 2.0f * PI / n;

    foreach (i, ref item; m.items) {
        // A wedge that cannot fire does not take the hover colour, and that is
        // `Button.disabled`'s own contract ("does not react to hover or
        // click"), not a rule invented here: the highlight means "let go, or
        // click, and THIS runs". On a reserved empty slot it would promise
        // something that is not there.
        immutable bool hot = (cast(int) i == g_pie.hover) && !item.disabled;

        // Slot i is centred on `i * 2π/n` CLOCKWISE FROM NOON
        // (pie_geometry's law). ImGui's arc angles run from due east and grow
        // clockwise on screen (y points down), so noon is -π/2.
        immutable float mid = -cast(float)(PI * 0.5) + slotCenterAngle(cast(int) i, n);
        immutable float a0  = mid - w * 0.5f;
        immutable float a1  = mid + w * 0.5f;

        // A wedge drawn from the CENTRE is convex, so PathFillConvex is
        // correct for it; the hub disc punched afterwards is what turns the
        // fan into a ring. Filling an annulus sector directly would hand
        // PathFillConvex a non-convex polygon and render garbage.
        //
        // The arc is walked by hand: this binding exposes the path API but not
        // `PathArcTo`, and a wedge is a fan of ARC_SEGS+1 rim points either way.
        dl.PathClear();
        dl.PathLineTo(c);
        foreach (s; 0 .. ARC_SEGS + 1) {
            immutable float a = a0 + (a1 - a0) * (cast(float) s / ARC_SEGS);
            dl.PathLineTo(ImVec2(c.x + cos(a) * RING_OUTER,
                                 c.y + sin(a) * RING_OUTER));
        }
        dl.PathFillConvex(hot ? COL_HOVER : COL_PLATE);

        // Separator spoke — one line per boundary, drawn at the wedge's
        // leading edge so adjacent wedges share exactly one.
        dl.AddLine(ImVec2(c.x + cos(a0) * RING_INNER, c.y + sin(a0) * RING_INNER),
                   ImVec2(c.x + cos(a0) * RING_OUTER, c.y + sin(a0) * RING_OUTER),
                   COL_EDGE, 1.0f);
    }

    // Outer rim + the hub that makes the dead zone visible.
    dl.AddCircle(c, RING_OUTER, COL_EDGE, ARC_SEGS * 4, 1.0f);
    dl.AddCircleFilled(c, RING_INNER, COL_HUB, 32);
    dl.AddCircle(c, RING_INNER, COL_EDGE, 32, 1.0f);

    // Labels, after every wedge is filled so no fill can cover a neighbour's
    // text.
    foreach (i, ref item; m.items) {
        immutable bool hot = (cast(int) i == g_pie.hover) && !item.disabled;
        immutable float mid = -cast(float)(PI * 0.5) + slotCenterAngle(cast(int) i, n);

        string label = item.label;
        // `checked:` marks the wedge that is already the current state — the
        // same read the popup rows do, so "which view am I in" is answerable
        // without leaving the ring.
        if (item.checked.present && resolveChecked(item.checked))
            label = "• " ~ label;

        // The availability record is taken for EVERY slot, including a
        // reserved empty one, and BEFORE the text is skipped below: the slot
        // exists, it occupies a compass direction, and a reader asking "what
        // does this menu offer" must be able to see that the eighth is
        // deliberately blank rather than missing. Skipping the record here is
        // what made the ring report seven wedges and broke the input-grab
        // case's own setup assertion.
        string why = (refusalOf is null) ? "" : refusalOf(item);
        immutable bool off = item.disabled || why.length > 0;

        // A reserved empty slot has drawn its plate and its seams above and
        // stops here — no text, and no greyed placeholder text either, because
        // the slot names nothing.
        if (label.length == 0) continue;

        auto ts = ImGui.CalcTextSize(label);
        immutable float lx = c.x + cos(mid) * LABEL_R - ts.x * 0.5f;
        immutable float ly = c.y + sin(mid) * LABEL_R - ts.y * 0.5f;
        dl.AddText(ImVec2(lx, ly),
                   off ? COL_TEXT_OFF : (hot ? COL_TEXT_HI : COL_TEXT),
                   label);
    }

    // Menu title under the hub — small, and outside the ring so it never
    // competes with a wedge label.
    if (m.title.length > 0) {
        auto ts = ImGui.CalcTextSize(m.title);
        dl.AddText(ImVec2(c.x - ts.x * 0.5f, c.y + RING_OUTER + 6.0f),
                   COL_TITLE, m.title);
    }
}
