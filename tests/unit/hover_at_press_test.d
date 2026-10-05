// Task 9439 (HOV1): a press never acts on a hover HELD over a stale index
// space. Each reader cell presses twice on the same held id, flag down (the
// control: the press takes the hover) then flag up (nothing hovered).
module tests.unit.hover_at_press_test;

import bindbc.sdl;
import editmode : EditMode;
import hover_state;
import math;
import mesh;
import mesh_gpu : GpuMesh;
import operator : VectorStack;

private SDL_MouseButtonEvent leftPress(int x = 0, int y = 0) {
    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_LEFT;
    e.x = x; e.y = y;
    return e;
}

private void clearHover() {
    g_hoveredVertex = g_hoveredEdge = g_hoveredFace = -1;
    g_hoverIndexSpaceStale = false;
}

unittest { // hoverAtPress: the published ids, or none while they are held stale
    scope(exit) clearHover();
    g_hoveredVertex = 1; g_hoveredEdge = 2; g_hoveredFace = 3;
    g_hoverIndexSpaceStale = false;
    assert(hoverAtPress() == HoverIds(1, 2, 3), "hoverAtPress lost a fresh hover");
    g_hoverIndexSpaceStale = true;
    assert(hoverAtPress() == HoverIds(-1, -1, -1), "hoverAtPress answered a stale hover");
}

unittest { // publishHover: HOLDS the ids while stale (task 1730); V > E > F under a tool
    import core.time : MonoTime;
    import input_frame_state : InputFrameState;
    import subpatch_preview : SubpatchPreview;
    scope(exit) clearHover();
    SubpatchPreview sp;
    bool uploaded = true;
    auto ifs = new InputFrameState;
    ifs.app.subpatchPreviewPtr = &sp;
    ifs.app.gpuUploadedPreviewPtr = &uploaded;
    foreach (stale; [false, true]) foreach (tool; [false, true]) {
        sp.buildPending = stale;
        sp.buildStarted = MonoTime.currTime;
        ifs.hoveredVertex = 4; ifs.hoveredEdge = 5; ifs.hoveredFace = 6;
        publishHover(ifs, tool, 0, 0);
        assert(g_hoverIndexSpaceStale == stale, "publishHover did not publish the stale flag");
        assert(HoverIds(g_hoveredVertex, g_hoveredEdge, g_hoveredFace)
               == (tool ? HoverIds(4, -1, -1) : HoverIds(4, 5, 6)),
               stale ? "publishHover dropped the held ids while stale"
                     : "publishHover broke the V > E > F precedence");
    }
    ifs.hoveredVertex = -1; ifs.hoveredEdge = 5; ifs.hoveredFace = 6;
    publishHover(ifs, true, 0, 0);
    assert(g_hoveredEdge == 5 && g_hoveredFace == -1, "publishHover: E did not beat F");
}

unittest { // magnet: a stale held vertex starts no drag
    import tools.deform.magnet : MagnetTool;
    scope(exit) clearHover();
    auto e = leftPress();
    VectorStack vts;
    foreach (stale; [false, true]) {
        Mesh m = makeCube();
        EditMode em = EditMode.Vertices;
        auto tool = new MagnetTool(() => &m, null, &em);
        tool.activate();
        g_hoveredVertex = 2;
        g_hoverIndexSpaceStale = stale;
        const took = tool.onMouseButtonDown(e, vts);
        if (!stale) assert(took, "magnet control: a fresh hover did not start a drag");
        else assert(!took, "magnet started a drag from a stale hover index space");
    }
}

unittest { // element pick: a stale held vertex pins nothing
    import toolpipe.packets : SubjectPacket;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.stages.actcenter : ActionCenterStage;
    import tools.transform.xfrm_transform : XfrmTransformTool;
    auto savedPipe = g_pipeCtx;
    scope(exit) { g_pipeCtx = savedPipe; clearHover(); }
    auto e = leftPress(5, 5);
    foreach (stale; [false, true]) {
        Mesh m = makeCube();
        GpuMesh gpu;
        gpu.suppressCageUpload = true;
        EditMode em = EditMode.Vertices;
        g_pipeCtx = new ToolPipeContext;
        auto ac = new ActionCenterStage(() => &m, &em);
        g_pipeCtx.pipeline.add(ac);
        auto tool = new XfrmTransformTool(() => &m, &gpu, &em);
        tool.flagT = true;
        tool.activate();
        ac.mode = ActionCenterStage.Mode.Element;
        SubjectPacket subj;
        subj.mesh = &m;
        subj.editMode = em;
        subj.viewport.view = lookAt(Vec3(0, 0, 6), Vec3(0, 0, 0), Vec3(0, 1, 0));
        subj.viewport.proj = perspectiveMatrix(0.8f, 1.0f, 0.1f, 100.0f);
        subj.viewport.width = subj.viewport.height = 400;
        VectorStack vts;
        vts.put(&subj);
        g_hoveredVertex = 3;
        g_hoverIndexSpaceStale = stale;
        tool.onMouseButtonDown(e, vts);
        const pinned = ac.holdsElementPin(m.vertices[3]);
        if (!stale) assert(pinned, "element pick control: a fresh hover did not pin");
        else assert(!pinned, "element pick pinned a vertex from a stale hover index space");
    }
}
