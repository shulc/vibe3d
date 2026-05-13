module gizmo;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : abs;
import math : Vec3;

// Corner orientation indicator. The three axis lines + most-facing plane
// quad are drawn relative to the basis (a1, n, a2) — defaults to world
// XYZ. Pass the WorkplaneStage basis (axis1, normal, axis2) to make the
// gizmo follow the active workplane: tools, numeric coord fields and
// transform-gizmos all use the same local frame, this is the visual cue.
void DrawGizmo(float x, float y, float[16] view,
               Vec3 a1 = Vec3(1, 0, 0),
               Vec3 n  = Vec3(0, 1, 0),
               Vec3 a2 = Vec3(0, 0, 1))
{
    enum float SIZE = 20.0f;

    // Background drawlist so ImGui windows (Tool Properties parked low
    // in the viewport, status bar tooltips, etc.) sit ON TOP of the
    // gizmo. Foreground would render it over panels — wrong z-order
    // for a corner orientation indicator.
    ImDrawList* gdl = ImGui.GetBackgroundDrawList();

    // Project a world-space offset (wx,wy,wz) to screen, anchored at (x,y).
    ImVec2 proj(float wx, float wy, float wz) {
        return ImVec2(x + view[0]*wx + view[4]*wy + view[8]*wz,
                      y - view[1]*wx - view[5]*wy - view[9]*wz);
    }
    // Sign of camera-back · v (positive ⇒ axis points away from camera).
    float backDot(Vec3 v) {
        return view[2]*v.x + view[6]*v.y + view[10]*v.z;
    }

    // ---- Most-facing plane quad (in basis (a1, n, a2)) ----
    // Quad lies in the plane spanned by the two axes most perpendicular
    // to the camera; the third axis (most aligned with camera-back) is
    // the plane normal. Selecting by |backDot| picks the right pair.
    float aA = abs(backDot(a1));
    float aN = abs(backDot(n));
    float aZ = abs(backDot(a2));

    enum float H = SIZE * 0.9f;
    uint  planeCol = IM_COL32(255, 255, 255, 30);
    uint  edgeCol  = IM_COL32(255, 255, 255, 128);
    Vec3 u, v;            // the two in-plane basis axes
    if (aA >= aN && aA >= aZ) {
        u = n;  v = a2;   // YZ-plane equivalent (in workplane local)
    } else if (aN >= aA && aN >= aZ) {
        u = a1; v = a2;   // XZ-plane equivalent
    } else {
        u = a1; v = n;    // XY-plane equivalent
    }
    ImVec2 q0 = proj(0,           0,           0);
    ImVec2 q1 = proj(u.x*H,       u.y*H,       u.z*H);
    ImVec2 q2 = proj((u.x+v.x)*H, (u.y+v.y)*H, (u.z+v.z)*H);
    ImVec2 q3 = proj(v.x*H,       v.y*H,       v.z*H);
    gdl.AddLine(q1, q2, edgeCol, 1.0f);
    gdl.AddLine(q2, q3, edgeCol, 1.0f);
    gdl.AddQuadFilled(q0, q1, q2, q3, planeCol);

    // ---- Axis lines (sorted back-to-front by depth) ----
    struct GizmoAxis { float sx, sy, depth; uint col; string label; }
    auto px = proj(a1.x*SIZE, a1.y*SIZE, a1.z*SIZE);
    auto py = proj(n.x*SIZE,  n.y*SIZE,  n.z*SIZE);
    auto pz = proj(a2.x*SIZE, a2.y*SIZE, a2.z*SIZE);
    GizmoAxis[3] gaxes = [
        GizmoAxis(px.x, px.y, backDot(a1), IM_COL32(220, 60, 60, 255), "X"),
        GizmoAxis(py.x, py.y, backDot(n),  IM_COL32(60, 220, 60, 255), "Y"),
        GizmoAxis(pz.x, pz.y, backDot(a2), IM_COL32(60, 60, 220, 255), "Z"),
    ];

    import std.algorithm : sort;
    sort!((a, b) => a.depth < b.depth)(gaxes[]);

    foreach (ref ax2; gaxes) {
        gdl.AddLine(ImVec2(x, y), ImVec2(ax2.sx, ax2.sy), ax2.col, 1.0f);
        gdl.AddText(ImVec2(ax2.sx + 1, ax2.sy - 15), ax2.col, ax2.label);
    }
}
