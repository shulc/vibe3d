module tests.unit.tools.transform.local_component_frame_production_test;

import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : abs;
import std.format : format;
import math : Vec3, ModelSpace, frameMatrix, frameMatrixInverse;
import mesh : Mesh;
import document : primaryModelSpaceResolver;
import editmode : EditMode;
import seltype : SelType;
import operator : VectorStack;
import toolpipe.packets : SubjectPacket, ActionCenterPacket, AxisPacket;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import tools.transform.xfrm_transform : XfrmTransformTool;
import params : injectParamsInto;

private double number(JSONValue j) { return j.type == JSONType.integer ? cast(double)j.integer : j.floating; }
private Vec3 vector(JSONValue j) { return Vec3(cast(float)number(j[0]), cast(float)number(j[1]), cast(float)number(j[2])); }
private void near(Vec3 a, Vec3 b, string label) {
    assert(abs(a.x-b.x)<2e-6 && abs(a.y-b.y)<2e-6 && abs(a.z-b.z)<2e-6,
           format("%s signed vector: actual=%s expected=%s", label, a, b));
}
private void load(ref Mesh mesh, JSONValue input) {
    foreach(v; input["positions"].array) mesh.vertices ~= vector(v);
    foreach(f; input["faces"].array) {
        uint[] ring; foreach(v; f.array) ring ~= cast(uint)v.integer;
        mesh.faces._store ~= ring;
    }
    if ("edges" in input.object) {
        foreach(e; input["edges"].array) mesh.edges ~= [cast(uint)e[0].integer, cast(uint)e[1].integer];
    } else mesh.rebuildEdgesFromFaces();
    mesh.resetSelection();
    foreach(f; input["selectedFaces"].array) mesh.selectFace(cast(int)f.integer);
    if ("selectedEdges" in input.object) foreach(e; input["selectedEdges"].array) mesh.selectEdge(cast(int)e.integer);
    assert(mesh.countSelectedFaces()==input["selectedFaces"].array.length, "explicit selected polygon population");
    foreach(fi,f;input["faces"].array) foreach(k,v;f.array) assert(mesh.faces[fi][k]==v.integer, "exact ordered input rings");
    foreach(vi,v;input["positions"].array) assert(mesh.vertices[vi]==vector(v),"exact float32 input");
}

unittest {
    import session_owner : Session;
    import registry : Registry;
    import live_registration_roles : LiveSessionRole, LiveViewModeRole, LiveView;
    import transform_tool_registration : TransformToolDeps, registerTransformToolCommands;
    import mesh_gpu : GpuMesh;
    import command_history : CommandHistory;
    import pipe_gizmo_host : PipeGizmoHost;
    import view : View;
    auto captured=parseJSON(readText("tests/fixtures/local_component_frame/captured.json"));
    auto savedSpace=primaryModelSpaceResolver;scope(exit) primaryModelSpaceResolver=savedSpace;
    primaryModelSpaceResolver=()=>ModelSpace.world();
    auto savedPipe=g_pipeCtx;scope(exit) g_pipeCtx=savedPipe;
    size_t outputs;
    foreach(cell;captured["cells"].array) {
        if(cell["outputPositions"].type==JSONType.null_) continue;
        foreach(id;[cell["name"].str=="scale"?"scale":"move","xfrm.transform"]) {
        ++outputs;Mesh initial;load(initial,cell["input"]);
        auto session=Session.bootstrap(initial);session.switchGeometryType(EditMode.Polygons);
        ref Mesh mesh=session.editMesh();auto mode=session.editModePtr();
        const bool old=mesh.vertices.length==26;
        assert(mesh.vertices.length==(old?26:162)&&mesh.faces.length==(old?24:146),"full output input population");
        if(!old) assert(mesh.edges.length==306&&mesh.countSelectedFaces()==6,"original 306 edges / six selected polygons");
        bool[] selected=new bool[](mesh.vertices.length);foreach(fi;cell["input"]["selectedFaces"].array) foreach(vi;mesh.faces[cast(size_t)fi.integer]) selected[vi]=true;
        size_t incident;foreach(s;selected) if(s) ++incident;
        assert(incident==(old?10:24),"selected incident vertex population");
        auto center=new ActionCenterStage(()=>&mesh,mode,null,()=>SelType.Polygon);
        auto axis=new AxisStage(()=>&mesh,mode,null,()=>SelType.Polygon);
        g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
        center.mode=ActionCenterStage.Mode.Local;
        axis.mode=cell["axisMode"].str=="local"?AxisStage.Mode.Local:cell["axisMode"].str=="world"?AxisStage.Mode.World:AxisStage.Mode.Auto;
        SubjectPacket subj;subj.mesh=&mesh;subj.editMode=*mode;subj.selType=SelType.Polygon;
        VectorStack stack;stack.put(&subj);assert(center.evaluate(stack)&&axis.evaluate(stack),"production output producers");
        auto cp=stack.get!ActionCenterPacket();assert(cp.clusterCenters.length==(old?2:6),format("%s full output component population: %s",cell["name"].str,cp.clusterCenters.length));
        foreach(cid,g;cell["golden"]["groups"].array) near(cp.clusterCenters[cid],vector(g["center"]),"full output component centers");
        Registry registry;GpuMesh gpu;gpu.suppressCageUpload=true;
        View camera=new View(0,0,1098,966);ref View liveView(){return camera;}
        registerTransformToolCommands(registry,LiveSessionRole(session),LiveViewModeRole(cast(LiveView)&liveView,mode),
            TransformToolDeps(&gpu,new CommandHistory,()=>null,()=>null,()=>null,new PipeGizmoHost,()=>false));
        auto tool=cast(XfrmTransformTool)registry.toolFactory(id)();assert(tool !is null,"full-output registered factory");tool.activate();
        auto pose=tool.buildPreparedUpdateTail(stack);assert(pose.valid,"full-output prepared pose");
        tool.installPreparedUpdateTail(pose);
        injectParamsInto(tool.params(),cell["channels"]);assert(tool.applyHeadless(),"real headless operation accepted");
        size_t untouched;
        foreach(vi,v;cell["outputPositions"].array) {
            if(!selected[vi]) {++untouched;assert(mesh.vertices[vi]==vector(cell["input"]["positions"][vi]),"unselected output exact");}
        }
        assert(untouched==(old?16:138),"untouched output population");
        foreach(vi,v;cell["outputPositions"].array) near(mesh.vertices[vi],vector(v),cell["name"].str~" full output "~id);
        }
    }
    assert(outputs==10,"independent full output oracle population");
}

unittest { // Real registration products and independent Rotate operation contract.
    import session_owner : Session;
    import registry : Registry;
    import live_registration_roles : LiveSessionRole, LiveViewModeRole, LiveView;
    import transform_tool_registration : TransformToolDeps, registerTransformToolCommands;
    import mesh_gpu : GpuMesh;
    import command_history : CommandHistory;
    import pipe_gizmo_host : PipeGizmoHost;
    import view : View;
    import math : pivotRotationMatrix, applyAffine;
    import std.math : PI;
    import std.string : count;
    auto captured=parseJSON(readText("tests/fixtures/local_component_frame/captured.json"));
    auto cell=captured["cells"][1]; // Full Move input and signed shared frame.
    auto savedSpace=primaryModelSpaceResolver;scope(exit) primaryModelSpaceResolver=savedSpace;
    primaryModelSpaceResolver=()=>ModelSpace.world();
    auto savedPipe=g_pipeCtx;scope(exit) g_pipeCtx=savedPipe;
    foreach(id;["move","rotate","scale","xfrm.transform"]) {
        Mesh initial;load(initial,cell["input"]);
        auto session=Session.bootstrap(initial);session.switchGeometryType(EditMode.Polygons);
        auto mp=&session.editMesh();auto mode=session.editModePtr();
        auto center=new ActionCenterStage(()=>mp,mode,null,()=>SelType.Polygon);
        auto axis=new AxisStage(()=>mp,mode,null,()=>SelType.Polygon);
        g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
        center.mode=ActionCenterStage.Mode.Local;axis.mode=AxisStage.Mode.Local;
        Registry reg;GpuMesh gpu;View camera;ref View liveView(){return camera;}
        registerTransformToolCommands(reg,LiveSessionRole(session),LiveViewModeRole(cast(LiveView)&liveView,mode),
            TransformToolDeps(&gpu,new CommandHistory,()=>null,()=>null,()=>null,new PipeGizmoHost,()=>false));
        auto tool=cast(XfrmTransformTool)reg.toolFactory(id)();
        assert(tool !is null,"all registered transform ids construct Xfrm product");
        tool.activate();
        SubjectPacket subj;subj.mesh=mp;subj.editMode=*mode;subj.selType=SelType.Polygon;
        VectorStack stack;stack.put(&subj);assert(center.evaluate(stack)&&axis.evaluate(stack),"registered product producers");
        auto pose=tool.buildPreparedUpdateTail(stack);
        const int flags=id=="move"?1:id=="rotate"?2:id=="scale"?4:7;
        assert(pose.valid&&pose.flags==flags,"registered T/R/S flags and production prepared pose");
        near(pose.basisX,vector(cell["golden"]["groups"][0]["right"]),"registered prepared right");
        near(pose.basisY,vector(cell["golden"]["groups"][0]["up"]),"registered prepared up");
        if(id=="rotate") {
            JSONValue channels=parseJSON(`{"RY":7}`);injectParamsInto(tool.params(),channels);
            auto cp=stack.get!ActionCenterPacket();auto ap=stack.get!AxisPacket();
            Vec3[] expected=mp.vertices.dup;
            foreach(vi,c;cp.clusterOf) if(c>=0)
                expected[vi]=applyAffine(pivotRotationMatrix(cp.clusterCenters[c],ap.clusterUp[c],7*PI/180),expected[vi]);
            assert(tool.applyHeadless(),"registered Rotate operation accepted");
            foreach(vi,v;expected) near(mp.vertices[vi],v,"independent production rotation compatibility; no captured numeric claim");
        }
    }
    const registration=readText("source/transform_tool_registration.d");
    foreach(id;["move","rotate","scale","xfrm.transform"])
        assert(registration.count(`reg.registerTool("`~id~`", typedToolFactory!XfrmTransformTool(`)==1,"shared factory registration source census");
    foreach(file;["move","rotate","scale"])
        assert(readText("source/tools/transform/"~file~".d").count("currentBasis(")>0,"legacy bank reads shared production basis");
    assert(readText("source/tools/edit/edge_extend.d").count("xfrm.update(")>0,"embedded EdgeExtend reads shared Xfrm producer");
    assert(readText("source/tools/transform/xfrm_apply.d").count("queryClusterAxes(vts)")==1,"real operation component packet wiring");
}
