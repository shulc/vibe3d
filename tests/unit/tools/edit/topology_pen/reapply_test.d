// The pen's re-evaluation data and the edge slide's axis kernel (wave plan
// 8640 S7b, §9.8 / §9.17.6 / §9.26.3 / §9.27 [A15-4]). Named into the pen's
// package for its `package` members (gestures_test.d's header has why). The
// suite half is tests/test_session_laws_topology_pen_offset.d.
module tools.edit.topology_pen.reapply_test;

import tools.edit.topology_pen;
import math : Vec3;

// kReapply — the table IS the plan's: per kind, what it reads and its shape.
// A row moved between shapes (Add Loop or Fill to carriedT, Smooth reading
// the offsets, Fill attribute-only) reddens here as well as in the suite.
unittest {
    import std.algorithm.searching : canFind;
    enum O = ["offsetX", "offsetY", "offsetZ"];
    struct Want { PenStepKind kind; string[] reads; ReapplyShape shape; }
    const Want[] want = [
        Want(PenStepKind.None,        null,               ReapplyShape.attributeOnly),
        Want(PenStepKind.VertexMove,  O,                  ReapplyShape.carriedT),
        Want(PenStepKind.EdgeMove,    O,                  ReapplyShape.carriedT),
        Want(PenStepKind.PolygonMove, O,                  ReapplyShape.carriedT),
        Want(PenStepKind.MoveLoop,    O,                  ReapplyShape.carriedT),
        Want(PenStepKind.Slide,       O,                  ReapplyShape.carriedT),
        Want(PenStepKind.CornerBuild, O,                  ReapplyShape.carriedT),
        Want(PenStepKind.PointPlace,  O,                  ReapplyShape.carriedT),
        Want(PenStepKind.AddLoop,     O,                  ReapplyShape.basisOnly),
        Want(PenStepKind.Smooth,      ["smoothStrength"], ReapplyShape.rerunFromBasis),
        Want(PenStepKind.Fill,        O,                  ReapplyShape.basisOnly),
        Want(PenStepKind.DupEdge,     O,                  ReapplyShape.carriedT),
    ];
    // Population: one row per kind, every kind covered.
    assert(want.length == kReapply.length && kReapply.length == PenStepKind.max + 1);
    foreach (w; want) {
        const row = kReapply[w.kind];
        assert(row.shape == w.shape && row.reads == w.reads);
    }
    // The offsets are read by no smooth, and strength by no carried kind.
    assert(!kReapply[PenStepKind.Smooth].reads.canFind("offsetX"));
    assert(!kReapply[PenStepKind.VertexMove].reads.canFind("smoothStrength"));
}

// edgeSlideAxis — the largest |component|; a tie within the RELATIVE eps goes
// to the LATER axis (X/Y -> Y is captured, L50); eps 0 is a strict compare.
// Constructed inputs, so the tie is not a float coin flip ([A15-4] note).
unittest {
    alias ax = TopologyPenTool.edgeSlideAxis;
    enum double eps = TopologyPenTool.kEdgeSlideTieEps;
    assert(eps == 1e-3);
    // |dX| = |dY| (1 + 1e-6): a tie under eps -> Y; strictly X without it.
    assert(ax(Vec3(1.000001f, 1.0f, 0.0f), eps) == 1);
    assert(ax(Vec3(1.000001f, 1.0f, 0.0f), 0.0) == 0);
    // Outside the tolerance the larger wins, either order.
    assert(ax(Vec3(1.01f, 1.0f, 0.0f), eps) == 0);
    assert(ax(Vec3(-1.0f, 1.01f, 0.2f), eps) == 1);
    // Y/Z (ours): the later axis again.
    assert(ax(Vec3(0.1f, 0.5f, -0.5f), eps) == 2);
    assert(ax(Vec3(0.1f, 0.5f, -0.4f), eps) == 1);
    // A zero or non-finite delta latches nothing.
    assert(ax(Vec3(0, 0, 0), eps) == -1);
    assert(ax(Vec3(float.nan, 1, 0), eps) == -1);
    // The latch point sits inside the measured window (2.24, 5.9] px (L50).
    assert(TopologyPenTool.kEdgeSlideLatchPx > 2.24f && TopologyPenTool.kEdgeSlideLatchPx <= 5.9f);
}

// 9494: real typed property widget over a released carried Move. The frozen
// press image and pairing are produced before the panel writes its value.
unittest {
    import mesh : Mesh;
    import editmode : EditMode;
    import operator : VectorStack;
    import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
    import toolpipe.stages.symmetry : SymmetryStage;
    import property_panel : PropertyPanel;
    import tests.unit.ui.headless_panel : openPanel;
    import command_history : CommandHistory;
    import edit_session : EditSession;
    import tool : Tool;
    import std.math : abs;
    Mesh m;
    foreach(p;[Vec3(.1,0,0),Vec3(.4,0,0),Vec3(.4,.4,0),Vec3(.1,.4,0),
               Vec3(-.1,.4,0),Vec3(-.4,.4,0),Vec3(-.4,0,0),Vec3(-.1,0,0)]) m.addVertex(p);
    m.addFace([0u,1,2,3]); m.addFace([4u,5,6,7]); m.rebuildEdges();
    const rings=m.faces.dup;
    auto saved=g_pipeCtx; scope(exit) g_pipeCtx=saved;
    auto ctx=new ToolPipeContext(); g_pipeCtx=ctx;
    Mesh* mp=&m; EditMode mode=EditMode.Vertices;
    auto sym=new SymmetryStage(() => mp,&mode); ctx.pipeline.add(sym);
    sym.enabled=true; sym.axisIndex=0;
    VectorStack vts; assert(sym.evaluate(vts));
    auto pen=new TopologyPenTool(); pen.meshSrc_=()=>mp;
    pen.stepKind_=[PenStepKind.VertexMove];
    pen.stepVerts_=[1u]; pen.stepOrig_=[Vec3(.4,0,0)]; pen.offsetX_=.2;
    import symmetry : writeMovePositions;
    writeMovePositions(m,sym.publishedPacket(),[1u],[Vec3(.6,0,0)]);
    assert(abs(m.vertices[1].x-.6)<1e-6 && abs(m.vertices[6].x+.6)<1e-6,"9494 widget baseline source and partner");
    assert(sym.evaluate(vts));
    Tool active=pen;
    auto session=new EditSession(()=>active,new CommandHistory(),() { active=null; });
    auto panel=new PropertyPanel();
    import ImGui = d_imgui;
    import d_imgui.imgui_h : ImVec2;
    ImVec2 at;
    auto ui=openPanel(() {
        panel.draw(pen,session,"mesh.topoPen");
        // Offset X/Y/Z are the final three visible numeric rows. Measure the
        // last group: earlier checkbox heights need not equal numeric pitch.
        auto lo=ImGui.GetItemRectMin(), hi=ImGui.GetItemRectMax();
        at=ImVec2(lo.x+6,(lo.y+hi.y)*.5f-2*ImGui.GetFrameHeightWithSpacing());
    });
    scope(exit) ui.close();
    size_t row; bool found;
    foreach(par;pen.params()) { if(par.hidden_) continue; if(par.name=="offsetX") {found=true;break;} ++row; }
    assert(found && row>0,"9494 panel offset row population");
    ui.frame(); assert(ui.editAt(at,"0.3"),"9494 Offset X widget acquired text input");
    assert(abs(pen.offsetX_-.3)<1e-6,"9494 typed panel stores .3");
    assert(abs(m.vertices[1].x-.7)<1e-6,"9494 typed panel source from press baseline");
    assert(abs(m.vertices[6].x+.7)<1e-6,"9494 typed panel partner follows shared write");
    assert(m.vertices.length==8 && m.faces==rings,"9494 typed panel retains exact corner rings");
    foreach(i;0..30) ui.frame(); // let the prior text click leave the double-click window
    const before=pen.offsetX_;
    ui.pressAt(at);
    auto heldAt=at; heldAt.x+=20;
    ui.hoverAt(heldAt); ui.hoverAt(heldAt);
    assert(abs(pen.offsetX_-before)>1e-4,"9494 held widget changed offset");
    assert(abs(m.vertices[1].x-(.4+pen.offsetX_))<1e-6,"9494 preview retains press baseline");
    assert(abs(m.vertices[6].x+m.vertices[1].x)<1e-6,"9494 held preview partner follows source");
    ui.release();
    assert(ui.editAt(at,"0.3"),"9494 repeated typed write acquired input");
    assert(abs(m.vertices[1].x-.7)<1e-6 && abs(m.vertices[6].x+.7)<1e-6,"9494 repeated panel write does not compound");
    sym.enabled=false;
    assert(ui.editAt(at,"0.4"),"9494 disabled symmetry edit input");
    assert(abs(m.vertices[1].x-.8)<1e-6 && abs(m.vertices[6].x+.7)<1e-6,"9494 disabled symmetry leaves partner unchanged");
    g_pipeCtx=null;
    assert(ui.editAt(at,"0.5"),"9494 pipeline absent edit input");
    assert(abs(m.vertices[1].x-.9)<1e-6 && abs(m.vertices[6].x+.7)<1e-6,"9494 absent pipeline keeps source-only write");
}

// Production composition controls: the widget test must stay connected to the
// shipped interactive callback and re-apply must retain the shared write site.
unittest {
    import std.file : readText;
    import std.algorithm.searching : canFind;
    import std.string : count;
    const pen=readText("source/tools/edit/topology_pen/tool.d");
    assert(pen.count("writeMovePositions(*m, sp, stepVerts_, to);")==1,
        "9494 reapply production shared write site");
    assert(pen.count("if (interactiveParamEdit) reapplyLastStep(name);")==1,
        "9494 production interactive reapply wiring");
    const panel=readText("source/property_panel.d");
    assert(panel.canFind("? ParameterChangeSource.InteractiveValue") &&
        panel.canFind("session.orchestrateParameterChange("),
        "9494 production property panel interactive orchestration");
    const attr=readText("source/commands/tool/attr.d");
    assert(attr.canFind("auto source = interactive_") &&
        attr.canFind(": ParameterChangeSource.ScriptedValue;"),
        "9494 production script origin remains distinct");
}
