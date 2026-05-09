module falloff_render;

import std.math : sin, cos, sqrt, PI;

import math : Vec3, Viewport, projectToWindowFull;
import toolpipe.packets : FalloffPacket, FalloffType, LassoStyle;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// Falloff visual feedback — Phase 7.5g of doc/falloff_plan.md.
//
// Passive overlay only — no drag handles in this commit (deferred). The
// goal is visual confirmation: the user sees WHERE the falloff
// influence ramps from full to zero. They tune via the property panel
// or `tool.pipe.attr falloff <name> <value>`.
//
// Tools that consume falloff (Move / Rotate / Scale via TransformTool)
// call drawFalloffOverlay(packet, vp) from their draw() AFTER their
// own gizmo draw. The overlay short-circuits when packet.enabled is
// false so non-falloff sessions pay nothing.
// ---------------------------------------------------------------------------

/// Render the type-specific falloff overlay using ImGui's foreground
/// draw list (renders on top of all 3D geometry, no depth test).
void drawFalloffOverlay(const ref FalloffPacket cfg, const ref Viewport vp) {
    if (!cfg.enabled) return;

    auto dl = ImGui.GetForegroundDrawList();

    // Cyan-with-purple-tint for falloff overlays so they don't conflict
    // with snap (cyan) or selection (orange). Two intensities — the
    // ring/outline at full alpha, the fill semi-transparent.
    enum uint outlineCol = IM_COL32(160, 110, 220, 230);
    enum uint fillCol    = IM_COL32(160, 110, 220,  60);

    final switch (cfg.type) {
        case FalloffType.None: return;
        case FalloffType.Linear: drawLinear(dl, cfg, vp, outlineCol);     break;
        case FalloffType.Radial: drawRadial(dl, cfg, vp, outlineCol);     break;
        case FalloffType.Screen: drawScreen(dl, cfg, outlineCol, fillCol); break;
        case FalloffType.Lasso:  drawLasso (dl, cfg, outlineCol);         break;
    }
}

private void drawLinear(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        const ref Viewport vp, uint col)
{
    float ax, ay, anz, bx, by, bnz;
    if (!projectToWindowFull(cfg.start, vp, ax, ay, anz)) return;
    if (!projectToWindowFull(cfg.end,   vp, bx, by, bnz)) return;
    dl.AddLine(ImVec2(ax, ay), ImVec2(bx, by), col, 2.0f);
    dl.AddCircleFilled(ImVec2(ax, ay), 6.0f, col, 16);   // start = full influence
    dl.AddCircle      (ImVec2(bx, by), 6.0f, col, 16, 2.0f); // end = zero
}

private void drawRadial(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        const ref Viewport vp, uint col)
{
    // Three great-circle outlines in the YZ / XZ / XY planes of the
    // ellipsoid's local frame. Each circle samples 36 points; degenerate
    // axes (size component ≤ 0) draw as a flat line.
    void greatCircle(int axisA, int axisB) {
        enum N = 36;
        ImVec2[N] pts;
        bool ok = true;
        foreach (i; 0 .. N) {
            float ang = cast(float)i * 2.0f * cast(float)PI / cast(float)N;
            float ca = cos(ang);
            float sa = sin(ang);
            Vec3 r = cfg.center;
            float[3] sz = [cfg.size.x, cfg.size.y, cfg.size.z];
            float[3] off = [0.0f, 0.0f, 0.0f];
            off[axisA] = ca * sz[axisA];
            off[axisB] = sa * sz[axisB];
            r.x += off[0];
            r.y += off[1];
            r.z += off[2];
            float sx, sy, ndcZ;
            if (!projectToWindowFull(r, vp, sx, sy, ndcZ)) { ok = false; break; }
            pts[i] = ImVec2(sx, sy);
        }
        if (ok) dl.AddPolyline(pts.ptr, N, col, ImDrawFlags.Closed, 1.5f);
    }
    greatCircle(1, 2);   // YZ
    greatCircle(0, 2);   // XZ
    greatCircle(0, 1);   // XY

    // Centre dot for visual anchor.
    float cx, cy, cndcZ;
    if (projectToWindowFull(cfg.center, vp, cx, cy, cndcZ))
        dl.AddCircleFilled(ImVec2(cx, cy), 4.0f, col, 12);
}

private void drawScreen(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        uint outline, uint fill)
{
    auto pos = ImVec2(cfg.screenCx, cfg.screenCy);
    float r = cfg.screenSize > 1.0f ? cfg.screenSize : 1.0f;
    dl.AddCircleFilled(pos, r, fill, 32);
    dl.AddCircle      (pos, r, outline, 32, 2.0f);
    dl.AddCircleFilled(pos, 4.0f, outline, 12);
}

private void drawLasso(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                       uint col)
{
    auto xs = cfg.lassoPolyX;
    auto ys = cfg.lassoPolyY;
    if (xs.length < 3 || xs.length != ys.length) return;
    ImVec2[] pts;
    pts.length = xs.length;
    foreach (i; 0 .. xs.length) pts[i] = ImVec2(xs[i], ys[i]);
    dl.AddPolyline(pts.ptr, cast(int)pts.length, col,
                   ImDrawFlags.Closed, 2.0f);
}
