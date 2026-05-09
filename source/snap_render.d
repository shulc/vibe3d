module snap_render;

import math : Vec3, Viewport, projectToWindowFull;
import mesh : Mesh;
import snap : SnapResult;
import toolpipe.packets : SnapType;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// Snap visual feedback — Phase 7.3d of doc/snap_plan.md.
//
// drawSnapOverlay() renders two layers:
//
//   1. CYAN element highlight — the actual mesh element snap is locked
//      onto (vertex dot / edge segment / face outline). Drawn first so
//      the cursor marker sits on top.
//
//   2. YELLOW cursor marker at the snap candidate's projected pixel:
//      - Within `outerRangePx` (highlighted, NOT snapped) ⇒ ring only
//        (pre-snap pulse — "if you keep going, this is what you'll
//        snap to").
//      - Within `innerRangePx` (snapped) ⇒ filled disc + ring.
//
// Tools call this from their `draw()` after capturing the most recent
// SnapResult in their motion handler. The renderer is shared because
// every snap-aware tool (Move now, Pen / Create-tools in 7.3f) uses
// the same convention.
//
// `g_lastSnap` is the global "most recent snap result published by any
// tool" — the /api/snap/last HTTP endpoint reads this for headless
// test runs (the test doesn't need a screenshot, just JSON probe).
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
/// (the cursor isn't near any snap target this frame).
void drawSnapOverlay(const ref SnapResult result, const ref Viewport vp,
                     const ref Mesh mesh)
{
    if (!result.highlighted) return;

    auto dl = ImGui.GetForegroundDrawList();

    drawTargetElementHighlight(dl, result, vp, mesh);
    drawCursorMarker(dl, result, vp);
}

private void drawTargetElementHighlight(ImGui.ImDrawList* dl,
                                        const ref SnapResult result,
                                        const ref Viewport vp,
                                        const ref Mesh mesh)
{
    // Brighter cyan when actually snapped, dimmer when only highlighted —
    // mirrors the yellow cursor marker's snapped-vs-pre-snap intensity.
    immutable uint elemCol = result.snapped
        ? IM_COL32(0, 220, 255, 230)
        : IM_COL32(0, 220, 255, 150);
    immutable uint elemFill = result.snapped
        ? IM_COL32(0, 220, 255,  60)
        : IM_COL32(0, 220, 255,  30);
    immutable float lineThick = result.snapped ? 2.5f : 1.8f;

    int idx = result.targetIndex;
    auto t = result.targetType;

    if (t == SnapType.Vertex) {
        if (idx < 0 || idx >= cast(int)mesh.vertices.length) return;
        ImVec2 pt;
        if (!project(mesh.vertices[idx], vp, pt)) return;
        dl.AddCircleFilled(pt, 5.0f, elemCol, 16);
    }
    else if (t == SnapType.Edge || t == SnapType.EdgeCenter) {
        if (idx < 0 || idx >= cast(int)mesh.edges.length) return;
        auto edge = mesh.edges[idx];
        ImVec2 a, b;
        if (!project(mesh.vertices[edge[0]], vp, a)) return;
        if (!project(mesh.vertices[edge[1]], vp, b)) return;
        dl.AddLine(a, b, elemCol, lineThick);
    }
    else if (t == SnapType.Polygon || t == SnapType.PolyCenter) {
        if (idx < 0 || idx >= cast(int)mesh.faces.length) return;
        auto face = mesh.faces[idx];
        if (face.length < 3) return;
        ImVec2[] pts;
        pts.length = face.length;
        foreach (i, vi; face) {
            if (vi >= mesh.vertices.length) return;
            if (!project(mesh.vertices[vi], vp, pts[i])) return;
        }
        // Outline. Fill is risky for non-convex faces — skip the fill on
        // anything but tris/quads where convexity is virtually
        // guaranteed.
        if (face.length <= 4)
            dl.AddConvexPolyFilled(pts.ptr, cast(int)pts.length, elemFill);
        dl.AddPolyline(pts.ptr, cast(int)pts.length, elemCol,
                       ImDrawFlags.Closed, lineThick);
    }
    // SnapType.Grid / SnapType.Workplane have no geometric element to
    // highlight — the cursor marker alone suffices.
}

private void drawCursorMarker(ImGui.ImDrawList* dl,
                              const ref SnapResult result,
                              const ref Viewport vp)
{
    ImVec2 pos;
    if (!project(result.highlightPos, vp, pos)) return;

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

private bool project(Vec3 worldPos, const ref Viewport vp, out ImVec2 pt) {
    float sx, sy, ndcZ;
    if (!projectToWindowFull(worldPos, vp, sx, sy, ndcZ)) return false;
    pt = ImVec2(sx, sy);
    return true;
}
