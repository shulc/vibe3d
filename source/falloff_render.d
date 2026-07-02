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

/// Render the type-specific falloff overlay using ImGui's background
/// draw list — sits above the 3D scene but below ImGui windows, so
/// the Tool Properties panel (and other panels) occlude the overlay
/// instead of being painted over by it.
///
/// Task 0213: since each viewport cell is now an opaque `ImGui.Image`
/// window (task 0170), the background draw list is painted OVER by that
/// image and the overlay never shows. Callers should prefer the explicit-
/// `dl` overload below, passing that cell's `GetWindowDrawList()` so the
/// overlay records AFTER the image on the SAME window's draw list (above
/// the cell image, still below other panels). This no-`dl` overload is
/// kept only for source compatibility / any caller with no window
/// draw list handy; it still targets the (occluded, in a Viewport##k
/// cell) background list.
void drawFalloffOverlay(const ref FalloffPacket cfg, const ref Viewport vp) {
    drawFalloffOverlay(ImGui.GetBackgroundDrawList(), cfg, vp);
}

/// Same as above but the caller supplies the `ImDrawList*` to record
/// into — pass a cell's `GetWindowDrawList()` (task 0213) so the overlay
/// renders above that cell's `ImGui.Image` instead of being occluded by
/// it. The Screen branch still uses its own `GetForegroundDrawList()`
/// (transient gesture feedback that must stay above every panel).
void drawFalloffOverlay(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        const ref Viewport vp) {
    if (!cfg.enabled) return;

    // Cyan linear-falloff overlay (cyan boxes at the endpoints, faint
    // connecting line). Snap uses a similar cyan but
    // never co-occurs with a falloff overlay (snap visualises hover
    // candidates; falloff visualises an active stage attribute) so the
    // colour clash is acceptable. Selection orange is unaffected.
    enum uint outlineCol = IM_COL32(100, 220, 230, 230);

    // ImGui's background draw list spans the whole OS window — without
    // a clip rect the overlay can spill over the tab bar / status bar
    // / side panels surrounding the 3D viewport. Bound everything to
    // the viewport rect so on-screen falloff geometry can't escape it.
    dl.PushClipRect(ImVec2(cast(float)vp.x, cast(float)vp.y),
                    ImVec2(cast(float)(vp.x + vp.width),
                           cast(float)(vp.y + vp.height)),
                    /*intersect_with_current_clip_rect=*/true);
    scope(exit) dl.PopClipRect();

    final switch (cfg.type) {
        case FalloffType.None: return;
        case FalloffType.Linear: drawLinear(dl, cfg, vp, outlineCol); break;
        case FalloffType.Radial:
            // No center dot: the interactive FalloffGizmo centerHandle box
            // (drawn for Radial) already marks the center. The dot would
            // stack a fixed-size ImGui circle on top of that GL handle —
            // reading as a second, smaller center marker that doesn't track
            // the gizmo size.
            drawRadial(dl, cfg, vp, outlineCol, /*centerDot=*/false);
            break;
        case FalloffType.Screen: {
            // The Screen disc shows only while the user is actively
            // interacting — RMB radius-adjust gesture, or an LMB
            // pull driven by a tool that opted in via
            // `screenFalloffLMBBegin`. Outside both, the current
            // center/radius is implicit tool state, not something
            // the user is configuring, so the overlay would just be
            // visual noise on every frame of an idle soft-drag tool.
            //
            // Drawn on the FOREGROUND draw list (unlike the other
            // falloff overlays which live on background) — the disc
            // is transient gesture feedback that must remain visible
            // for the duration of the LMB pull / RMB radius drag
            // regardless of what panel the cursor happens to cross.
            import falloff_handles : screenFalloffOverlayVisible;
            if (!screenFalloffOverlayVisible()) return;
            auto fgDl = ImGui.GetForegroundDrawList();
            fgDl.PushClipRect(ImVec2(cast(float)vp.x, cast(float)vp.y),
                              ImVec2(cast(float)(vp.x + vp.width),
                                     cast(float)(vp.y + vp.height)),
                              /*intersect_with_current_clip_rect=*/true);
            drawScreen(fgDl, cfg, outlineCol);
            fgDl.PopClipRect();
            break;
        }
        case FalloffType.Lasso: drawLasso(dl, cfg, outlineCol); break;
        case FalloffType.Cylinder:
            // Reuse the radial overlay for now — the visual cue (an
            // ellipse on the workplane) is close enough to the
            // cylindrical cross-section for a first pass. A proper
            // rendering would draw the cylinder's axis line plus two
            // capping circles; deferred until a Vortex user surfaces a
            // need.
            drawRadial(dl, cfg, vp, outlineCol);
            break;
        case FalloffType.Element:
            // The Element sphere overlay is transient gesture
            // feedback for ONLY the RMB radius-adjust drag — that's
            // when the user is actively configuring the sphere
            // radius. Outside that, the center/radius is implicit
            // tool state and the ellipse would just be visual noise
            // (unlike Screen falloff which also tracks LMB pulls
            // because the disc itself follows the cursor — Element's
            // sphere is anchored to ACEN.center and doesn't move
            // with the drag, so showing it during the pull would be
            // misleading).
            import falloff_handles : elementFalloffOverlayVisible;
            if (!elementFalloffOverlayVisible()) return;
            // Reuse drawRadial — the visual cue (ellipse at the
            // anchor with the configured radius) reads as a sphere
            // cross-section. Build a scratch packet field-by-field
            // — FalloffPacket contains array slices (lassoPolyX/Y)
            // so D forbids `viewPkt = cfg` from a const ref.
            FalloffPacket viewPkt;
            viewPkt.enabled = cfg.enabled;
            viewPkt.type    = FalloffType.Radial;
            viewPkt.shape   = cfg.shape;
            viewPkt.center  = cfg.pickedCenter;
            viewPkt.size    = Vec3(cfg.pickedRadius,
                                   cfg.pickedRadius,
                                   cfg.pickedRadius);
            viewPkt.in_     = cfg.in_;
            viewPkt.out_    = cfg.out_;
            drawRadial(dl, viewPkt, vp, outlineCol);
            break;
        case FalloffType.Selection:
            // No screen-space overlay — the weight is a per-vert
            // BFS distance over mesh.edges, not a geometric shape
            // we can outline as a line/disc/sphere. The implicit
            // visual cue is the selection itself (already highlit
            // by the renderer); deferred to a possible "wireframe
            // gradient" overlay if a user surfaces a need.
            break;
        case FalloffType.Composite:
            // Multi-falloff combine packet — no single geometric shape
            // to outline (it is the Mix-Mode product of N sub-falloffs,
            // each with its own overlay). The per-contributor overlays
            // are drawn from their own stages; the composite itself has
            // nothing extra to render.
            break;
        case FalloffType.VertexMap:
            // Per-vertex weights from a named map — no geometric outline.
            // The mesh's vertex colour is the only meaningful visual cue
            // (reserved for a future "weight paint" overlay mode).
            break;
    }
}

private void drawLinear(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        const ref Viewport vp, uint col)
{
    // Thin connecting line + endpoint markers + a perpendicular
    // weight-curve "profile" for the linear-falloff overlay. The
    // profile traces w(t) at sample points along the
    // segment, offset perpendicular to the segment in screen space
    // by w(t) × max_height. For shape=linear w(t)=1−t collapses to a
    // triangle (max offset at start, zero at end); curved shapes
    // (easeIn / easeOut / smooth / custom) trace the actual function.
    //
    // Rendered in screen space because: (a) the "perpendicular"
    // direction has no canonical 3D choice for an arbitrary segment
    // (any vector in the plane perpendicular to start→end works), and
    // (b) the profile's job is visual confirmation of the shape preset,
    // not a 3D measurement.
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
                        const ref Viewport vp, uint col, bool centerDot = true)
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

    // Centre dot for visual anchor — only where no interactive center
    // handle is drawn (Element / Cylinder reuse this overlay). Suppressed
    // for true Radial, whose FalloffGizmo draws a draggable center box.
    if (centerDot) {
        float cx, cy, cndcZ;
        if (projectToWindowFull(cfg.center, vp, cx, cy, cndcZ))
            dl.AddCircleFilled(ImVec2(cx, cy), 4.0f, col, 12);
    }
}

private void drawScreen(ImGui.ImDrawList* dl, const ref FalloffPacket cfg,
                        uint outline)
{
    auto pos = ImVec2(cfg.screenCx, cfg.screenCy);
    float r = cfg.screenSize > 1.0f ? cfg.screenSize : 1.0f;
    dl.AddCircle(pos, r, outline, 32, 2.0f);
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
