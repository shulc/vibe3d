module gizmo;

import ImGui = d_imgui;
import d_imgui.imgui_h;

void DrawGizmo(float x, float y, float[16] view) {
    enum float SIZE = 20.0f;

    ImDrawList* gdl = ImGui.GetForegroundDrawList();

    struct GizmoAxis { float sx, sy, depth; uint col; char label; }
    GizmoAxis[3] gaxes = [
        GizmoAxis(x + view[0]*SIZE, y - view[1]*SIZE, view[2],  IM_COL32(220,60,60,255),  'X'),
        GizmoAxis(x + view[4]*SIZE, y - view[5]*SIZE, view[6],  IM_COL32(60,220,60,255),  'Y'),
        GizmoAxis(x + view[8]*SIZE, y - view[9]*SIZE, view[10], IM_COL32(60,60,220,255),  'Z'),
    ];

    // Sort back-to-front so closer axes draw on top
    import std.algorithm : sort;
    sort!((a, b) => a.depth > b.depth)(gaxes[]);

    foreach (ref ax; gaxes) {
        gdl.AddLine(ImVec2(x, y), ImVec2(ax.sx, ax.sy), ax.col, 1.0f);
        gdl.AddText(ImVec2(ax.sx + 1, ax.sy - 15), ax.col, ax.label == 'X' ? "X" : ax.label == 'Y' ? "Y" : "Z");
    }
}