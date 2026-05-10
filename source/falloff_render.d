module falloff_render;

import std.math : sin, cos, sqrt, PI;

import math : Vec3, Viewport, projectToWindowFull;
import toolpipe.packets : FalloffPacket, FalloffType, LassoStyle;
import falloff : applyShape;

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

    // Cyan to match MODO 9's linear-falloff overlay (cyan boxes at the
    // endpoints, faint connecting line). Snap uses a similar cyan but
    // never co-occurs with a falloff overlay (snap visualises hover
    // candidates; falloff visualises an active stage attribute) so the
    // colour clash is acceptable. Selection orange is unaffected.
    enum uint outlineCol = IM_COL32(100, 220, 230, 230);
    enum uint fillCol    = IM_COL32(100, 220, 230,  60);

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
    // Thin connecting line + endpoint markers + a perpendicular
    // weight-curve "profile" — matches MODO 9's linear-falloff
    // overlay. The profile traces w(t) at sample points along the
    // segment, offset perpendicular to the segment in screen space
    // by w(t) × max_height. For shape=linear w(t)=1−t collapses to a
    // triangle (max offset at start, zero at end); curved shapes
    // (easeIn / easeOut / smooth / custom) trace the actual function.
    //
    // Rendered in screen space because: (a) the "perpendicular"
    // direction has no canonical 3D choice for an arbitrary segment
    // (any vector in the plane perpendicular to start→end works), and
    // (b) MODO renders it screen-space too — the profile's job is
    // visual confirmation of the shape preset, not a 3D measurement.
    float ax, ay, anz, bx, by, bnz;
    if (!projectToWindowFull(cfg.start, vp, ax, ay, anz)) return;
    if (!projectToWindowFull(cfg.end,   vp, bx, by, bnz)) return;
    dl.AddCircleFilled(ImVec2(ax, ay), 4.0f, col, 16);   // start = full influence
    dl.AddCircleFilled(ImVec2(bx, by), 4.0f, col, 16);   // end   = zero

    // Profile: mirrored perpendicular offset w(t) × max_h on both
    // sides of the segment — for shape=linear this draws a thin
    // double-sided isoceles triangle (max width at start, zero at
    // end); curved shapes (easeIn / easeOut / smooth / custom) trace
    // the actual w(t) function. The start→end connecting line is
    // omitted on purpose — the triangle's two slanted edges already
    // imply the segment direction, and the empty middle reads as the
    // falloff axis.
    float dxs = bx - ax;
    float dys = by - ay;
    float L   = sqrt(dxs*dxs + dys*dys);
    if (L < 4.0f) return;          // degenerate; segment is a dot on screen
    float pxd = -dys / L;          // perpendicular unit (rotate +90° CCW)
    float pyd =  dxs / L;
    float maxH = 0.25f * L;
    if (maxH < 12.0f) maxH = 12.0f;
    if (maxH > 80.0f) maxH = 80.0f;
    enum int N = 32;               // sample count — smooth enough for any shape
    ImVec2[N + 1] top;
    ImVec2[N + 1] bot;
    foreach (i; 0 .. N + 1) {
        float t = cast(float)i / N;
        float w = applyShape(t, cfg.shape, cfg.in_, cfg.out_);
        float xa = ax + dxs * t;
        float ya = ay + dys * t;
        top[i] = ImVec2(xa + pxd * maxH * w, ya + pyd * maxH * w);
        bot[i] = ImVec2(xa - pxd * maxH * w, ya - pyd * maxH * w);
    }
    dl.AddPolyline(top.ptr, N + 1, col, ImDrawFlags.None, 1.0f);
    dl.AddPolyline(bot.ptr, N + 1, col, ImDrawFlags.None, 1.0f);
    // Closing perpendicular at start — connects top profile's first
    // point to bot profile's first point, sealing the lens/triangle
    // shape at the full-influence end.
    dl.AddLine(top[0], bot[0], col, 1.0f);
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
