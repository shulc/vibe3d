module gizmo;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : abs;

void DrawGizmo(float x, float y, float[16] view) {
    enum float SIZE = 20.0f;

    ImDrawList* gdl = ImGui.GetForegroundDrawList();

    // Project a gizmo-space world point (wx,wy,wz) to screen.
    ImVec2 proj(float wx, float wy, float wz) {
        return ImVec2(x + view[0]*wx + view[4]*wy + view[8]*wz,
                      y - view[1]*wx - view[5]*wy - view[9]*wz);
    }

    // ---- Most-facing plane quad ----
    // view[2], view[6], view[10] = camera backward vector in world space;
    // abs gives alignment of each world axis with the view direction.
    float ax = abs(view[2]);
    float ay = abs(view[6]);
    float az = abs(view[10]);

    enum float H = SIZE * 0.9f;  // half-extent of the quad
    uint  planeCol, edgeCol;
    ImVec2[4] quad;
    planeCol = IM_COL32(255, 255, 255, 30);
    edgeCol = IM_COL32(255, 255, 255, 128);
    if (ax >= ay && ax >= az) {
        // YZ plane
        quad = [proj(0, 0, 0), proj(0, H, 0), proj(0, H, H), proj(0, 0, H)];
        gdl.AddLine(proj(0, H, 0), proj(0, H, H), edgeCol, 1.0f);
        gdl.AddLine(proj(0, H, H), proj(0, 0, H), edgeCol, 1.0f);
    } else if (ay >= ax && ay >= az) {
        // XZ plane
        quad = [proj(0, 0, 0), proj(0, 0, H), proj(H, 0, H), proj( H, 0, 0)];
        gdl.AddLine(proj(H, 0, 0), proj(H, 0, H), edgeCol, 1.0f);
        gdl.AddLine(proj(H, 0, H), proj(0, 0, H), edgeCol, 1.0f);
    } else {
        // XY plane
        quad = [proj(0, 0, 0), proj(0, H, 0), proj(H, H, 0), proj( H, 0, 0)];
        gdl.AddLine(proj(0, H, 0), proj(H, H, 0), edgeCol, 1.0f);
        gdl.AddLine(proj(H, H, 0), proj(H, 0, 0), edgeCol, 1.0f);
    }
    gdl.AddQuadFilled(quad[0], quad[1], quad[2], quad[3], planeCol);

    // ---- Axis lines ----
    struct GizmoAxis { float sx, sy, depth; uint col; string label; }
    GizmoAxis[3] gaxes = [
        GizmoAxis(x + view[0]*SIZE, y - view[1]*SIZE, view[2],  IM_COL32(220,60,60,255),  "X"),
        GizmoAxis(x + view[4]*SIZE, y - view[5]*SIZE, view[6],  IM_COL32(60,220,60,255),  "Y"),
        GizmoAxis(x + view[8]*SIZE, y - view[9]*SIZE, view[10], IM_COL32(60,60,220,255),  "Z"),
    ];

    import std.algorithm : sort;
    sort!((a, b) => a.depth < b.depth)(gaxes[]);

    foreach (ref ax2; gaxes) {
        gdl.AddLine(ImVec2(x, y), ImVec2(ax2.sx, ax2.sy), ax2.col, 1.0f);
        gdl.AddText(ImVec2(ax2.sx + 1, ax2.sy - 15), ax2.col, ax2.label);
    }
}
