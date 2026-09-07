module frame_runner;

import ai.element_candidates : publishElementCandidates;
import editmode : EditMode;
import editor_app : EditorApp, OverlayMode;
import eventlog : queryMouse;
import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
import input_frame_state : InputFrameState;
import ImGui = d_imgui;
import imgui_impl_opengl3 : ImGui_ImplOpenGL3_RenderDrawData;
import math : Viewport;
import tool : Tool;
import ui.viewport_render : renderViewportSceneToFbo;
import viewport : Viewport3D;

/// Hover gates consumed by the later scene phase of the same frame.
struct HoverDrawState {
    bool vertex;
    bool edge;
    bool face;
}

/// Owns the covered frame phases extracted from main() (task 4630).
/// The outer loop remains the ordering root until events and present have
/// witnesses; tick therefore starts at the first covered seam, picking/hover.
final class FrameRunner {
    private InputFrameState ifs_;

    this(InputFrameState ifs) {
        assert(ifs !is null);
        ifs_ = ifs;
    }

    void tick(ref Viewport vp, bool doingCameraDrag) {
        ifs_.pickVertices(vp, doingCameraDrag);
        ifs_.pickEdges(vp, doingCameraDrag);
        ifs_.pickFaces(vp, doingCameraDrag);

        // Item hover is last and independent of the remembered geometry mode.
        ifs_.pickItems(vp, doingCameraDrag);
    }

    HoverDrawState resolveHover(Tool activeTool, EditMode editMode) {
        const int pickedVertex = ifs_.hoveredVertex;
        const int pickedEdge = ifs_.hoveredEdge;
        const int pickedFace = ifs_.hoveredFace;

        // A multi-type tool publishes exactly one highlighted candidate.
        if (activeTool !is null) {
            if (ifs_.hoveredVertex >= 0) {
                ifs_.hoveredEdge = -1;
                ifs_.hoveredFace = -1;
            } else if (ifs_.hoveredEdge >= 0) {
                ifs_.hoveredFace = -1;
            }
        }

        int mouseX, mouseY;
        queryMouse(mouseX, mouseY);
        publishElementCandidates(mouseX, mouseY,
                                 pickedVertex, pickedEdge, pickedFace);

        // Publish the resolved source-of-truth hover for tool consumers.
        g_hoveredVertex = ifs_.hoveredVertex;
        g_hoveredEdge = ifs_.hoveredEdge;
        g_hoveredFace = ifs_.hoveredFace;

        HoverDrawState result;
        result.vertex = editMode == EditMode.Vertices
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Vertices));
        result.edge = editMode == EditMode.Edges
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Edges));
        result.face = editMode == EditMode.Polygons
            || (activeTool !is null
                && activeTool.wantsHoverForType(EditMode.Polygons));
        return result;
    }

    void drawScene(EditorApp app, Viewport3D cell, ref Viewport vp,
                   OverlayMode overlayMode, bool showVertexHover,
                   bool showEdgeHover, bool showFaceHover) {
        renderViewportSceneToFbo(app, cell, vp, overlayMode,
                                 showVertexHover, showEdgeHover,
                                 showFaceHover);
    }

    void renderImGui() {
        ImGui.Render();
    }

    void submitImGui() {
        ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());
    }
}
