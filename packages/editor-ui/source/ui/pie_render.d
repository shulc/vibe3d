module ui.pie_render;

// Fixed compass boxes and hub mirror input state; task/evidence: doc/tasks/work/6208-pie-menu-reference-parity.md.
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : ceil;

import buttonset : Button, ActionKind;
import pie_geometry : PIE_SLOTS, pieBoxTopLeft, pieSlotDir;
import pie_menus : findPieMenu, isPieHole;
import pie_state : g_pie;
import ui.availability : ButtonUnavailable, recordDrawnButton;
import ui.button_face : ButtonFace, buttonFaceColours, drawButtonFace,
    kButtonBarPadding;
import ui.pie_record : DrawnPieBox, beginPieFrame, setPieBoxWidth,
    recordPieBox, endPieFrame;

private string faceName(ButtonFace face) {
    final switch (face) {
        case ButtonFace.normal: return "normal";
        case ButtonFace.hover: return "hover";
        case ButtonFace.on: return "on";
        case ButtonFace.disabled: return "disabled";
    }
}

void drawPieMenu(scope ButtonUnavailable delegate(ref Button) unavailableOf = null) {
    beginPieFrame(g_pie.open, g_pie.menuId, g_pie.cx, g_pie.cy,
                  g_pie.unitH, g_pie.hover);
    scope(exit) endPieFrame();
    if (!g_pie.open) return;

    auto menu = findPieMenu(g_pie.menuId);
    if (menu is null) return;

    int boxW;
    foreach (i, ref item; menu.items) {
        if (i >= PIE_SLOTS || isPieHole(item)) continue;
        immutable int w = cast(int)ceil(ImGui.CalcTextSize(item.label).x)
                        + cast(int)(2.0f * kButtonBarPadding.x);
        if (w > boxW) boxW = w;
    }
    setPieBoxWidth(boxW);

    auto dl = ImGui.GetForegroundDrawList();
    immutable ImVec2 c = ImVec2(cast(float)g_pie.cx, cast(float)g_pie.cy);
    immutable float outerR = 20.0f / 32.0f * g_pie.unitH;
    immutable float innerR = 18.0f / 32.0f * g_pie.unitH;
    immutable uint black = IM_COL32(0, 0, 0, 255);
    auto hubFace = g_pie.hover < 0 ? ButtonFace.hover : ButtonFace.normal;
    immutable uint hubFill = buttonFaceColours(hubFace, true).fill;
    dl.AddCircleFilled(c, outerR, black, 32);
    dl.AddCircleFilled(c, innerR, hubFill, 32);
    if (g_pie.hover >= 0) {
        float ux, uy;
        pieSlotDir(g_pie.hover, ux, uy);
        immutable float s = g_pie.unitH / 32.0f;
        immutable float px = -uy, py = ux;
        immutable float tipD = 13.5f * s;
        immutable float baseD = 7.5f * s;
        immutable float halfW = 2.5f * s;
        dl.AddTriangleFilled(
            ImVec2(c.x + ux * tipD, c.y + uy * tipD),
            ImVec2(c.x + ux * baseD + px * halfW,
                   c.y + uy * baseD + py * halfW),
            ImVec2(c.x + ux * baseD - px * halfW,
                   c.y + uy * baseD - py * halfW), black);
    }

    foreach (i, ref item; menu.items) {
        if (i >= PIE_SLOTS || isPieHole(item)) continue;
        auto unavailable = unavailableOf is null
            ? ButtonUnavailable(item.disabled, "") : unavailableOf(item);
        ButtonFace face = unavailable.disabled ? ButtonFace.disabled
            : (cast(int)i == g_pie.hover ? ButtonFace.hover : ButtonFace.normal);
        auto tl = pieBoxTopLeft(cast(int)i, g_pie.unitH, boxW);
        ImVec2 rmin = ImVec2(c.x + tl.x, c.y + tl.y);
        ImVec2 rmax = ImVec2(rmin.x + boxW, rmin.y + g_pie.unitH);
        immutable bool isCommand = item.action.kind == ActionKind.command
                                || item.action.kind == ActionKind.script;
        drawButtonFace(dl, rmin, rmax, item.label, 0.5f, face, isCommand);
        recordPieBox(DrawnPieBox(cast(int)i, item.label, tl.x, tl.y,
                                boxW, g_pie.unitH, faceName(face)));
        recordDrawnButton("pie", item.label, item.action.kind, item.action.id,
                          unavailable.disabled, unavailable.why);
    }
}
