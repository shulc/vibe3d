module ui.button_face;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import ui.panel_chrome : kChromeText;
import std.math : lround;

// Shared panel/pie button face law; task/evidence: doc/tasks/work/6208-pie-menu-reference-parity.md.
enum ImVec2 kButtonBarPadding = ImVec2(6, 5);

int pieButtonUnitH() {
    return cast(int)lround(ImGui.GetFontSize() + 2.0f * kButtonBarPadding.y);
}

struct ButtonPalette {
    ImVec4 bgNormal;
    ImVec4 bgHover;
    uint bevelLightN;
    uint bevelDarkN;
    uint bevelLightH;
    uint bevelDarkH;
}

ButtonPalette styledButtonPalette(bool isCommand) pure nothrow @nogc {
    if (isCommand) {
        return ButtonPalette(
            ImVec4(0.635f, 0.686f, 0.749f, 1.0f),
            ImVec4(0.698f, 0.749f, 0.812f, 1.0f),
            IM_COL32(206, 219, 235, 255), IM_COL32(143, 156, 172, 255),
            IM_COL32(222, 235, 251, 255), IM_COL32(159, 172, 188, 255));
    }
    return ButtonPalette(
        ImVec4(0.710f, 0.710f, 0.655f, 1.0f),
        ImVec4(0.773f, 0.773f, 0.718f, 1.0f),
        IM_COL32(225, 225, 211, 255), IM_COL32(162, 162, 148, 255),
        IM_COL32(241, 241, 227, 255), IM_COL32(178, 178, 164, 255));
}

enum ButtonFace { normal, hover, on, disabled }

struct FaceColours {
    uint fill;
    bool bevel;
    uint bevelLight;
    uint bevelDark;
    bool engraved;
}

private uint packed(ImVec4 c) pure nothrow @nogc {
    uint r = cast(uint)(c.x * 255.0f + 0.5f);
    uint g = cast(uint)(c.y * 255.0f + 0.5f);
    uint b = cast(uint)(c.z * 255.0f + 0.5f);
    uint a = cast(uint)(c.w * 255.0f + 0.5f);
    return IM_COL32(r, g, b, a);
}

FaceColours buttonFaceColours(ButtonFace face, bool isCommand)
        pure nothrow @nogc {
    auto p = styledButtonPalette(isCommand);
    final switch (face) {
        case ButtonFace.normal:
            return FaceColours(packed(p.bgNormal), true,
                               p.bevelLightN, p.bevelDarkN, false);
        case ButtonFace.hover:
            return FaceColours(packed(p.bgHover), true,
                               p.bevelLightH, p.bevelDarkH, false);
        case ButtonFace.on:
            return FaceColours(IM_COL32(255, 255, 255, 255), false, 0, 0, false);
        case ButtonFace.disabled:
            return FaceColours(packed(p.bgNormal), true,
                               p.bevelLightN, p.bevelDarkN, true);
    }
}

void drawButtonOutlineRect(ImDrawList* dl, ImVec2 rmin, ImVec2 rmax) {
    uint c = IM_COL32(0, 0, 0, 255);
    dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmax.x, rmin.y), c);
    dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmin.x, rmax.y), c);
    dl.AddLine(ImVec2(rmin.x, rmax.y), ImVec2(rmax.x, rmax.y), c);
    dl.AddLine(ImVec2(rmax.x, rmin.y), ImVec2(rmax.x, rmax.y), c);
}

void drawRaisedBevelRect(ImDrawList* dl, ImVec2 rmin, ImVec2 rmax,
                         uint light, uint dark, bool pressed = false,
                         int thickness = 2) {
    uint tl = pressed ? dark : light;
    uint br = pressed ? light : dark;
    foreach (i; 0 .. thickness) {
        float x0 = rmin.x + 1.0f + i, y0 = rmin.y + 1.0f + i;
        float x1 = rmax.x - 2.0f - i, y1 = rmax.y - 2.0f - i;
        dl.AddLine(ImVec2(x0, y0), ImVec2(x1, y0), tl);
        dl.AddLine(ImVec2(x0, y0), ImVec2(x0, y1), tl);
        dl.AddLine(ImVec2(x0, y1), ImVec2(x1, y1), br);
        dl.AddLine(ImVec2(x1, y0), ImVec2(x1, y1), br);
    }
}

void drawEngravedLabel(ImDrawList* dl, ImVec2 tp, string label) {
    dl.AddText(ImVec2(tp.x + 1, tp.y + 1), IM_COL32(245, 245, 231, 200), label);
    dl.AddText(tp, IM_COL32(95, 90, 78, 255), label);
}

void drawButtonFace(ImDrawList* dl, ImVec2 rmin, ImVec2 rmax, string label,
                    float alignX, ButtonFace face, bool isCommand) {
    auto c = buttonFaceColours(face, isCommand);
    dl.AddRectFilled(rmin, rmax, c.fill, 0.0f);
    ImVec2 ts = ImGui.CalcTextSize(label);
    ImVec2 tp = ImVec2(rmin.x + (rmax.x - rmin.x - ts.x) * alignX,
                       rmin.y + (rmax.y - rmin.y - ts.y) * 0.5f);
    if (c.engraved)
        drawEngravedLabel(dl, tp, label);
    else
        dl.AddText(tp, packed(kChromeText), label);
    drawButtonOutlineRect(dl, rmin, rmax);
    if (c.bevel)
        drawRaisedBevelRect(dl, rmin, rmax, c.bevelLight, c.bevelDark);
}
