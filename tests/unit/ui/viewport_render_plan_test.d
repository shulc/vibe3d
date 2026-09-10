module ui.viewport_render_plan_test;

import display_state : DrawPlan;
import editor_app : OverlayMode;
import math : Viewport;
import operator : VectorStack;
import shader : Shader;
import tool : Tool;
import toolpipe.packets : SubjectPacket;
import ui.viewport_render : ToolOverlayInputs, ViewportSceneRenderer;

private final class PlanCaptureTool : Tool {
    bool called;
    DrawPlan received;
    bool receivedVisualOnly;

    override void draw(const ref Shader shader, const ref Viewport viewport,
                       ref VectorStack vts, const ref DrawPlan plan,
                       bool visualOnly = false) {
        called = true;
        received = plan;
        receivedVisualOnly = visualOnly;
    }
}

unittest {
    auto captured = new PlanCaptureTool();
    DrawPlan expected = DrawPlan.init;
    expected.drawFaces = false;
    expected.drawWire = false;
    expected.wireAlpha = 0.375f;
    expected.dim = 0.625f;

    ToolOverlayInputs inputs;
    inputs.activeTool = captured;
    inputs.plan = expected;
    inputs.buildSubject = (out SubjectPacket subject, ref VectorStack vts) {};

    auto renderer = new ViewportSceneRenderer();
    Viewport viewport;
    Shader shader;
    renderer.drawToolOverlays(inputs, OverlayMode.Visual, viewport, shader);

    assert(captured.called,
           "drawToolOverlays must invoke the active tool in a live overlay mode");
    assert(captured.receivedVisualOnly,
           "the Visual overlay control must reach Tool.draw");
    assert(captured.received == expected,
           "drawToolOverlays must pass its cell DrawPlan unchanged to Tool.draw");
}
