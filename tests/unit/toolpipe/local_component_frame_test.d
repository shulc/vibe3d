module tests.unit.toolpipe.local_component_frame_test;

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
private class Product : XfrmTransformTool {
    this(Mesh* delegate() src, EditMode* mode) { super(src, null, mode, () => SelType.Polygon); }
    void arm(int flags) { active=true; flagT=(flags&1)!=0; flagR=(flags&2)!=0; flagS=(flags&4)!=0; }
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
    auto captured=parseJSON(readText("tests/fixtures/local_component_frame/captured.json"));
    assert(captured["cells"].array.length==12,"frozen cell population");
    auto savedSpace=primaryModelSpaceResolver; scope(exit) primaryModelSpaceResolver=savedSpace;
    primaryModelSpaceResolver=()=>ModelSpace.world();
    auto savedPipe=g_pipeCtx; scope(exit) g_pipeCtx=savedPipe;
    foreach(cell;captured["cells"].array) {
        Mesh mesh; load(mesh,cell["input"]); EditMode mode=EditMode.Polygons;
        auto center=new ActionCenterStage(()=>&mesh,&mode,null,()=>SelType.Polygon);
        auto axis=new AxisStage(()=>&mesh,&mode,null,()=>SelType.Polygon);
        g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
        center.mode=cell["centerMode"].str=="local" ? ActionCenterStage.Mode.Local : ActionCenterStage.Mode.Select;
        axis.mode=cell["axisMode"].str=="local" ? AxisStage.Mode.Local : cell["axisMode"].str=="world" ? AxisStage.Mode.World : AxisStage.Mode.Auto;
        SubjectPacket subj;subj.mesh=&mesh;subj.editMode=mode;subj.selType=SelType.Polygon;
        VectorStack stack;stack.put(&subj);assert(center.evaluate(stack)&&axis.evaluate(stack),"real producer evaluations");
        auto cp=stack.get!ActionCenterPacket();auto ap=stack.get!AxisPacket();
        const groups=cell["golden"]["groups"].array;
        const bool old=cell["name"].str=="old-rig-local"||cell["name"].str=="old-rig-auto"||cell["name"].str=="old-rig-vertex-seed";
        const bool single=cell["name"].str=="single-component";
        assert(mesh.vertices.length==(old?26:162)&&mesh.faces.length==(old?24:146),"frozen frame input population");
        if(!old) assert(mesh.edges.length==306,"original frame edge population");
        assert(mesh.countSelectedFaces()==(old?3:single?1:6),"frozen frame polygon population");
        Vec3[] serviceCenters;int[] serviceMembership;
        assert(center.queryLocalComponentPartition(&mesh,mode,serviceCenters,serviceMembership),"same production partition independently of center mode");
        assert(serviceCenters.length==(old?2:single?1:6),"frozen connected component population");
        size_t incident;foreach(c;serviceMembership) if(c>=0) ++incident;
        assert(incident==(old?10:single?4:24),"frozen frame selected incident population");
        foreach(cid,g;groups) near(serviceCenters[cid],vector(g["center"]),cell["name"].str~" service membership center");
        assert(groups.length>0,"frozen signed group population");
        if(center.mode==ActionCenterStage.Mode.Local && groups.length>=2) {
            assert(cp.clusterCenters.length==groups.length,"component partition population");
            foreach(cid,g;groups) {
                near(cp.clusterCenters[cid],vector(g["center"]),cell["name"].str~" membership center");
                if("vertexIndices" in g.object) foreach(vi;g["vertexIndices"].array)
                    assert(cp.clusterOf[cast(size_t)vi.integer]==cid,"stored vertex seed membership order");
            }
        }
        auto tool=new Product(()=>&mesh,&mode);
        foreach(flags;[cast(ubyte)1,2,4,7]) {
            tool.arm(flags);auto pose=tool.buildPreparedUpdateTail(stack);
            assert(pose.valid&&pose.flags==flags,"real registered family prepared pose");
            auto m=cell["golden"]["matrixRowMajor"].array;
            near(pose.basisX,Vec3(cast(float)number(m[0]),cast(float)number(m[3]),cast(float)number(m[6])),cell["name"].str~" prepared right");
            near(pose.basisY,Vec3(cast(float)number(m[1]),cast(float)number(m[4]),cast(float)number(m[7])),cell["name"].str~" prepared up");
            near(pose.basisZ,Vec3(cast(float)number(m[2]),cast(float)number(m[5]),cast(float)number(m[8])),cell["name"].str~" prepared normal");
        }
        if(axis.mode==AxisStage.Mode.Local) {
            near(ap.right,vector(groups[0]["right"]),cell["name"].str~" packet representative");
            auto expectedM=frameMatrix(vector(groups[0]["right"]),vector(groups[0]["up"]),vector(groups[0]["normal"]));
            auto expectedInv=frameMatrixInverse(vector(groups[0]["right"]),vector(groups[0]["up"]),vector(groups[0]["normal"]));
            foreach(k;0..16) assert(abs(ap.m[k]-expectedM[k])<2e-6&&abs(ap.mInv[k]-expectedInv[k])<2e-6,"signed packet matrices");
            Vec3 r,u,f;axis.currentBasis(r,u,f);near(r,ap.right,"live representative right");near(u,ap.up,"live representative up");near(f,ap.fwd,"live representative normal");
            if(cp.clusterCenters.length>=2) {
                assert(ap.clusterRight.length==groups.length,"shared component axes population");
                foreach(cid,g;groups) {near(ap.clusterRight[cid],vector(g["right"]),"signed component right");near(ap.clusterUp[cid],vector(g["up"]),"signed component up");near(ap.clusterFwd[cid],vector(g["normal"]),"signed component normal");}
            } else assert(ap.clusterRight.length==0,"independent center has global axes only");
        } else assert(ap.clusterRight.length==0,"explicit axis override has no Local arrays");
    }
}

unittest { // Partition constructions, cache domains and validated independent service.
    import toolpipe.stages.actcenter : g_acenClusterRebuilds;
    import mesh_dirty : noteMeshChange;
    import mesh_edit_delta : MeshEditScope;
    Mesh mesh;
    mesh.vertices=[Vec3(0,0,0),Vec3(3,0,0),Vec3(0,1,0),Vec3(-2,0,0),Vec3(0,-1,0),Vec3(8,0,0),Vec3(9,0,0),Vec3(8,1,0)];
    mesh.faces._store=[[0u,1,2],[0u,3,4],[5u,6,7],[2u,5,6]];
    mesh.rebuildEdgesFromFaces();mesh.resetSelection();mesh.selectFace(0);mesh.selectFace(1);mesh.selectFace(2);
    EditMode mode=EditMode.Polygons;
    auto center=new ActionCenterStage(()=>&mesh,&mode);
    Vec3[] cc;int[] co;
    const before=g_acenClusterRebuilds;
    assert(center.queryLocalComponentPartition(&mesh,mode,cc,co),"independent AC mode partition service");
    assert(mesh.vertices.length==8&&mesh.faces.length==4&&mesh.countSelectedFaces()==3,"point touch / unselected bridge input population");
    assert(cc.length==2,"point-touch polygons merge; unselected-only bridge stays separate");
    assert(co==[0,0,0,0,0,1,1,1],"unique point ownership / selected boundary graph");
    assert(g_acenClusterRebuilds==before+1,"one shared partition rebuild");
    near(cc[0],Vec3(0.5f,0,0),"point-touch AABB center");near(cc[1],Vec3(8.5f,0.5f,0),"bridge island center");
    mesh.vertices[1].x=5;noteMeshChange(cast(size_t)&mesh,MeshEditScope.Position);
    assert(center.queryLocalComponentPartition(&mesh,mode,cc,co),"position-only service");
    assert(g_acenClusterRebuilds==before+1,"position must not rebuild membership");
    near(cc[0],Vec3(1.5f,0,0),"current position center recompute");
    mesh.selectFace(3);
    assert(center.queryLocalComponentPartition(&mesh,mode,cc,co)&&cc.length==1,"selected bridge merges");
    assert(g_acenClusterRebuilds==before+2,"selection rebuild exactly once");
    mesh.faces._store[3]=[5u,6,7];mesh.rebuildEdgesFromFaces();
    noteMeshChange(cast(size_t)&mesh,MeshEditScope.Polygons);
    assert(center.queryLocalComponentPartition(&mesh,mode,cc,co)&&cc.length==2,"topology refresh separates selected bridge");
    assert(g_acenClusterRebuilds==before+3,"topology rebuild exactly once");
    Mesh other;
    assert(!center.queryLocalComponentPartition(&other,mode,cc,co)&&cc.length==0&&co.length==0,"mismatched mesh service rejected");
    assert(!center.queryLocalComponentPartition(&mesh,EditMode.Edges,cc,co),"mismatched mode service rejected");
}

unittest { // All incident normal, planar boundary, failed sum, subject and symmetry admission.
    import toolpipe.stages.axis : localVirtualVertexNormals;
    import toolpipe.stages.symmetry : SymmetryStage;
    import toolpipe.packets : SymmetryPacket;
    Mesh mesh;mesh.vertices=[Vec3(0,0,0),Vec3(3,0,0),Vec3(0,1,0)];mesh.faces._store=[[0u,1,2]];
    foreach(vi;0..3) foreach(copy;0..2) {
        const p=mesh.vertices[vi];const a=cast(uint)mesh.vertices.length;
        mesh.vertices~=p+Vec3(0,0.2f,0);mesh.vertices~=p+Vec3(0.3f,0,0);
        mesh.faces._store~=[cast(uint)vi,a,a+1];
    }
    mesh.rebuildEdgesFromFaces();mesh.resetSelection();mesh.selectFace(0);
    assert(mesh.vertices.length==15&&mesh.faces.length==7&&mesh.countSelectedFaces()==1,"opposite corner construction population");
    EditMode mode=EditMode.Polygons;SelType subject=SelType.Polygon;
    auto center=new ActionCenterStage(()=>&mesh,&mode,null,()=>subject);
    auto axis=new AxisStage(()=>&mesh,&mode,null,()=>subject);
    auto saved=g_pipeCtx;scope(exit) g_pipeCtx=saved;
    g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
    center.mode=ActionCenterStage.Mode.Local;axis.mode=AxisStage.Mode.Local;
    SubjectPacket subj;subj.mesh=&mesh;subj.editMode=mode;subj.selType=subject;
    VectorStack stack;stack.put(&subj);assert(center.evaluate(stack)&&axis.evaluate(stack),"opposite corner real producers");
    auto ap=stack.get!AxisPacket();
    near(ap.fwd,Vec3(0,0,-1),"all-incident sign reverses selected-face-only normal");
    auto ns=localVirtualVertexNormals(&mesh);foreach(vi;0..3) near(ns[vi],Vec3(0,0,-1),"virtual vertex unit corner accumulation");
    Vec3[] cc;int[] co;assert(center.queryLocalComponentPartition(&mesh,mode,cc,co),"single component service");
    assert(cc.length==1&&co[0..3]==[0,0,0],"unselected incident corners preserve partition");
    near(cc[0],Vec3(1.5f,0.5f,0),"unselected incident corners preserve center");
    // Live and packet symmetry each retain the old selection/global frame.
    auto sym=new SymmetryStage(()=>&mesh,&mode);g_pipeCtx.pipeline.add(sym);sym.enabled=true;
    Vec3 lr,lu,lf;axis.currentBasis(lr,lu,lf);
    axis.mode=AxisStage.Mode.Select;Vec3 sr,su,sf;axis.currentBasis(sr,su,sf);
    near(lr,sr,"live symmetry compatibility right");near(lu,su,"live symmetry compatibility up");near(lf,sf,"live symmetry compatibility normal");
    axis.mode=AxisStage.Mode.Local;SymmetryPacket sp;sp.enabled=true;stack.put(&sp);assert(axis.evaluate(stack),"packet symmetry producer");
    near(stack.get!AxisPacket().fwd,sf,"packet symmetry compatibility");
    sym.enabled=false;sp.enabled=false;stack.put(&sp);
    // Cancelling all-incident sums keep pre-change Select global construction.
    foreach(vi;0..3) mesh.faces._store[2+vi*2]=[cast(uint)vi,cast(uint)vi,cast(uint)vi];
    assert(axis.evaluate(stack),"cancelled reference evaluation");
    Vec3 cancelR=stack.get!AxisPacket().right,cancelU=stack.get!AxisPacket().up,cancelF=stack.get!AxisPacket().fwd;
    axis.mode=AxisStage.Mode.Select;assert(axis.evaluate(stack),"failed-normal compatibility control");
    near(cancelR,stack.get!AxisPacket().right,"failed-normal compatibility right");near(cancelU,stack.get!AxisPacket().up,"failed-normal compatibility up");near(cancelF,stack.get!AxisPacket().fwd,"failed-normal compatibility normal");
    subject=SelType.Item;subj.selType=subject;stack.put(&subj);axis.mode=AxisStage.Mode.Local;assert(axis.evaluate(stack),"Item producer");
    near(stack.get!AxisPacket().right,Vec3(1,0,0),"Item Local compatibility");
}

unittest { // Frozen compatibility globals; the Local solver only admits rank-two polygons.
    import mesh : makeCube;
    auto saved=g_pipeCtx;scope(exit) g_pipeCtx=saved;
    foreach(cell;0..6) {
        Mesh mesh=makeCube();mesh.resetSelection();EditMode mode=EditMode.Polygons;
        if(cell==0) {mode=EditMode.Vertices;mesh.selectVertex(0);}
        if(cell==1) {mode=EditMode.Edges;mesh.selectEdge(0);}
        if(cell==2) {mesh.selectFace(4);mesh.vertices[mesh.faces[4][0]].y+=0.2f;}
        if(cell==3) {mesh.selectFace(4);foreach(vi;mesh.faces[4]) mesh.vertices[vi]=Vec3(cast(float)vi,0,0);}
        if(cell==4) {mesh.selectFace(4);foreach(vi;mesh.faces[4]) mesh.vertices[vi]=Vec3(1,2,3);}
        auto center=new ActionCenterStage(()=>&mesh,&mode);auto axis=new AxisStage(()=>&mesh,&mode);
        g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
        axis.mode=AxisStage.Mode.Select;Vec3 r,u,f;axis.currentBasis(r,u,f);
        axis.mode=AxisStage.Mode.Local;Vec3 lr,lu,lf;axis.currentBasis(lr,lu,lf);
        near(lr,r,"bounded compatibility right");near(lu,u,"bounded compatibility up");near(lf,f,"bounded compatibility normal");
        axis.mode=AxisStage.Mode.Manual;axis.manualRight=Vec3(0,1,0);axis.manualUp=Vec3(0,0,1);axis.manualFwd=Vec3(1,0,0);
        axis.currentBasis(lr,lu,lf);near(lr,Vec3(0,1,0),"independent Manual axis");
    }
}

unittest { // Frozen normal operands independently read from the accepted capture.
    import toolpipe.stages.axis : localVirtualVertexNormals;
    import math : normalize;
    auto captured=parseJSON(readText("tests/fixtures/local_component_frame/captured.json"));
    auto cell=captured["cells"][0];Mesh mesh;load(mesh,cell["input"]);
    auto normals=localVirtualVertexNormals(&mesh);
    assert(captured["normalOperands"].array.length==6,"frozen normal operand group population");
    foreach(cid,op;captured["normalOperands"].array) {
        auto members=cell["golden"]["groups"][cid]["vertexIndices"].array;
        assert(members.length==4&&op["vertexNormals"].array.length==4,"four virtual vertex operands");
        Vec3 sum=Vec3(0,0,0);
        foreach(vi;members) {
            auto n=normals[cast(size_t)vi.integer];sum=sum+n;
            bool matched=false;
            foreach(v;op["vertexNormals"].array) {
                auto ex=vector(v);if(abs(n.x-ex.x)<2e-6&&abs(n.y-ex.y)<2e-6&&abs(n.z-ex.z)<2e-6) matched=true;
            }
            assert(matched,"all-incident virtual vertex operand matches captured group enumeration");
        }
        near(normalize(sum),vector(op["componentReference"]),"frozen all-incident component normal sum");
    }
}
