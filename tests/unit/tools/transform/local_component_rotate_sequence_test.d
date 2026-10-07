module tests.unit.tools.transform.local_component_rotate_sequence_test;

import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : abs, PI, cos, sin;
import std.format : format;
import std.stdio : writeln, stderr;
import std.process : environment;
import math;
import mesh : Mesh;
import document : primaryModelSpaceResolver, Layer, ItemXform;
import seltype : SelMode;
import editmode : EditMode;
import seltype : SelType;
import operator : VectorStack;
import toolpipe.packets;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import tools.transform.xfrm_transform : XfrmTransformTool, PreparedXfrmUpdatePreProjection;
import prepared_record_context : PreparedRecordContext;
import prepared_xfrm_replay : PreparedXfrmReplayOwner;
import record_observer_hub : RecordObserverHub;
import params : injectParamsInto;
import edit_session : ParameterChangeBatch, ParameterChangeSource;
import session_owner : Session;
import registry : Registry;
import live_registration_roles : LiveSessionRole, LiveViewModeRole, LiveView;
import transform_tool_registration : TransformToolDeps, registerTransformToolCommands;
import mesh_gpu : GpuMesh;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.layer.xform_edit : LayerXformEdit;
import pipe_gizmo_host : PipeGizmoHost;
import view : View;
import bindbc.sdl;
import handles.gizmo_metrics : gizmoSize;

private double number(JSONValue j) { return j.type==JSONType.integer?cast(double)j.integer:j.floating; }
private Vec3 vector(JSONValue j) { return Vec3(cast(float)number(j[0]),cast(float)number(j[1]),cast(float)number(j[2])); }
private void near(Vec3 a, Vec3 b, string label) {
    assert(abs(a.x-b.x)<2e-6&&abs(a.y-b.y)<2e-6&&abs(a.z-b.z)<2e-6,
        format("%s actual=%s expected=%s",label,a,b));
}
private class Rig {
    JSONValue fixture;
    Session* session;
    Mesh* mp;
    ActionCenterStage center;
    AxisStage axis;
    XfrmTransformTool tool;
    View camera;
    GpuMesh gpu;
    CommandHistory history;
    Viewport vp;
    SubjectPacket subject;
    VectorStack stack;
    bool itemMode;
    this(JSONValue data,string id,int step=0,bool item=false) {
        itemMode=item;
        fixture=data;Mesh initial;
        foreach(v;data["positionsByStep"][step].array) initial.vertices~=vector(v);
        foreach(f;data["input"]["faces"].array) {
            uint[] ring;foreach(v;f.array) ring~=cast(uint)v.integer;initial.faces._store~=ring;
        }
        initial.rebuildEdgesFromFaces();initial.resetSelection();
        foreach(f;data["input"]["selectedFaces"].array) initial.selectFace(cast(int)f.integer);
        session=Session.bootstrap(initial);session.switchGeometryType(EditMode.Polygons);mp=&session.editMesh();
        if (itemMode) {
            assert(session.switchItemType(),"genuine Item subject switch");
            auto layer=session.document().primary;
            session.document().selectItem(layer,SelMode.Set);
            layer.xform.pos=Vec3(.2f,-.1f,.3f);layer.xform.rot=Vec3(7,-11,13);
            layer.xform.scl=Vec3(1.1f,.9f,1.2f);layer.xform.pivot=Vec3(.03f,.02f,-.01f);
        }
        auto mode=session.editModePtr();
        center=new ActionCenterStage(()=>mp,mode,()=>session.document().primary,()=>itemMode?SelType.Item:SelType.Polygon);
        axis=new AxisStage(()=>mp,mode,()=>session.document().primary,()=>itemMode?SelType.Item:SelType.Polygon);
        g_pipeCtx=new ToolPipeContext();g_pipeCtx.pipeline.add(center);g_pipeCtx.pipeline.add(axis);
        center.mode=ActionCenterStage.Mode.Local;axis.mode=AxisStage.Mode.Local;
        camera=new View(0,0,1098,966);camera.width=1098;camera.height=966;camera.azimuth=.5f;camera.elevation=.4f;camera.distance=3;
        vp=camera.viewport();
        Registry reg;history=new CommandHistory;gpu.suppressCageUpload=true;
        ref View liveView(){return camera;}
        registerTransformToolCommands(reg,LiveSessionRole(session),LiveViewModeRole(cast(LiveView)&liveView,mode),
            TransformToolDeps(&gpu,history,()=>new MeshVertexEdit(mp,camera,*mode),()=>null,()=>new LayerXformEdit(mp,camera,*mode),new PipeGizmoHost,()=>false));
        tool=cast(XfrmTransformTool)reg.toolFactory(id)();assert(tool !is null,"actual registered product");tool.activate();tool.cachedVp=vp;
        refresh(step);
    }
    void refresh(int step=-1) {
        subject=SubjectPacket.init;subject.mesh=mp;subject.editMode=EditMode.Polygons;subject.selType=itemMode?SelType.Item:SelType.Polygon;subject.viewport=vp;
        stack=VectorStack.init;stack.put(&subject);
        assert(center.evaluate(stack)&&axis.evaluate(stack),"real Local producers");
        assert(mp.vertices.length==162&&mp.faces.length==146&&mp.edges.length==306&&mp.countSelectedFaces()==6,"162/146/306/6 population");
        auto cp=stack.get!ActionCenterPacket();auto ap=stack.get!AxisPacket();
        if (itemMode) {
            assert(cp.clusterCenters.length==0&&ap.clusterRight.length==0,"Item packets have no geometry components");
            auto pose=tool.buildPreparedUpdateTail(stack);assert(pose.valid,"Item prepared pose");
            near(pose.center,applyAffine(session.document().primary.xform.composedMatrix(),session.document().primary.xform.pivot),"nonidentity Item pivot pose");
            tool.installPreparedUpdateTail(pose);return;
        }
        assert(cp.clusterCenters.length==6&&ap.clusterRight.length==6,"six active components");
        size_t selected,untouched;
        foreach(vi,c;cp.clusterOf) {if(c>=0) ++selected;else ++untouched;}
        assert(selected==24&&untouched==138,"24 selected / 138 untouched");
        if(step>=0) foreach(cid,g;fixture["groupsByStep"][step].array) {
            near(cp.clusterCenters[cid],vector(g["center"]),"down centers");
            near(ap.clusterRight[cid],vector(g["right"]),"down signed right");
            near(ap.clusterUp[cid],vector(g["up"]),"down signed up");
            near(ap.clusterFwd[cid],vector(g["normal"]),"down signed normal");
            foreach(vi;g["vertexIndices"].array) assert(cp.clusterOf[cast(size_t)vi.integer]==cid,"exact membership");
        }
        auto pose=tool.buildPreparedUpdateTail(stack);assert(pose.valid,"prepared installed pose");
        near(pose.center,cp.clusterCenters[0],"prepared center");
        if(step>=0) near(pose.basisX,ap.clusterRight[0],"prepared representative");
        tool.installPreparedUpdateTail(pose);
    }
    int[2] press(int ax) {
        Vec3 right,up,fwd;tool.rotateRingFrame(right,up,fwd);
        Vec3 n=ax==0?right:ax==1?up:fwd;
        Vec3 tmp=abs(n.x)<.9f?Vec3(1,0,0):Vec3(0,1,0);
        Vec3 r=normalize(cross(n,tmp)),u=cross(r,n);
        float radius=gizmoSize(stack.get!ActionCenterPacket().center,vp);
        auto c=stack.get!ActionCenterPacket().center;
        bool found;int x,y;
        foreach(sample;0..72) {
            float a=cast(float)(sample*2*PI/72);float sx,sy,z;
            if(!projectToWindow(c+r*(cos(a)*radius)+u*(sin(a)*radius),vp,sx,sy,z)) continue;
            x=cast(int)sx;y=cast(int)sy;
            if(tool.pressHitPart(x,y,vp)==10+ax){found=true;break;}
        }
        assert(found,"finite prepared principal press preflight");
        SDL_MouseButtonEvent e;e.button=SDL_BUTTON_LEFT;e.x=x;e.y=y;
        assert(tool.onMouseButtonDown(e,stack),"real principal down accepted");
        return [x,y];
    }
    int[2] movePress() {
        Vec3 r,u,f;tool.moveRenderFrame(r,u,f);
        auto c=stack.get!ActionCenterPacket().center;float radius=gizmoSize(c,vp);
        foreach(axis;[r,u,f]) foreach(scale;[.6f,.8f,1.0f]) {
            float sx,sy,z;
            if(!projectToWindow(c+axis*(radius*scale),vp,sx,sy,z)) continue;
            int x=cast(int)sx,y=cast(int)sy;
            auto part=tool.pressHitPart(x,y,vp);if(part<0||part>2) continue;
            SDL_MouseButtonEvent e;e.button=SDL_BUTTON_LEFT;e.x=x;e.y=y;
            assert(tool.onMouseButtonDown(e,stack),"real mixed Move down");return [x,y];
        }
        assert(false,"finite mixed Move preflight");return [0,0];
    }
    void release(int[2] px) {
        SDL_MouseButtonEvent e;e.button=SDL_BUTTON_LEFT;e.x=px[0];e.y=px[1];
        tool.onMouseButtonUp(e,stack);
    }
    Vec3[] folded(const(Vec3)[] baseline, int ax, float degrees, AxisPacket ap, ActionCenterPacket cp) {
        Vec3[] expected=baseline.dup;
        foreach(vi,c;cp.clusterOf) if(c>=0) {
            auto axis=ax==0?ap.clusterRight[c]:ax==1?ap.clusterUp[c]:ap.clusterFwd[c];
            expected[vi]=applyAffine(pivotRotationMatrix(cp.clusterCenters[c],axis,cast(float)(degrees*PI/180)),baseline[vi]);
        }
        return expected;
    }
    Vec3[] numericFold(const(Vec3)[] base, Vec3 degrees, AxisPacket ap, ActionCenterPacket cp) {
        Vec3[] expected=base.dup;
        foreach(vi,c;cp.clusterOf) if(c>=0) {
            auto m=matMul4(pivotRotationMatrix(cp.clusterCenters[c],ap.clusterFwd[c],cast(float)(degrees.z*PI/180)),
                matMul4(pivotRotationMatrix(cp.clusterCenters[c],ap.clusterUp[c],cast(float)(degrees.y*PI/180)),
                    pivotRotationMatrix(cp.clusterCenters[c],ap.clusterRight[c],cast(float)(degrees.x*PI/180))));
            expected[vi]=applyAffine(m,base[vi]);
        }
        return expected;
    }
    void vertices(const(Vec3)[] expected,string label) {
        assert(expected.length==162,"full construction output population");
        foreach(vi,v;expected) near(mp.vertices[vi],v,label);
    }
    size_t depth() { size_t model,ui;history.undoDepthCounts(model,ui);return model+ui; }
    PreparedXfrmUpdatePreProjection projection() {
        PreparedXfrmUpdatePreProjection p;p.valid=true;p.panelRegrade=true;p.subject=itemMode?SelType.Item:SelType.Polygon;
        if(auto f=stack.get!FalloffPacket()) p.liveFalloff=*f;
        if(auto sy=stack.get!SymmetryPacket()) p.liveSymmetry=*sy;
        return p;
    }
    void orientation(float[16] expected,string label) {
        auto actual=matrixFromEulerZYX(tool.publishedRotate());
        foreach(i;0..16) assert(abs(actual[i]-expected[i])<2e-6,label);
    }
    Vec3 physicalAxis(int ax) {
        Vec3 r,u,f;tool.rotateRingFrame(r,u,f);return ax==0?r:ax==1?u:f;
    }
    void output(int step,string label) {
        foreach(v;fixture["unchangedVertexIndices"].array) {
            auto vi=cast(size_t)v.integer;assert(mp.vertices[vi]==vector(fixture["positionsByStep"][0][vi]),"138 unchanged EXACT");
        }
        foreach(vi,v;fixture["positionsByStep"][step].array) near(mp.vertices[vi],vector(v),label);
        foreach(fi,f;fixture["input"]["faces"].array) foreach(k,v;f.array) assert(mp.faces[fi][k]==v.integer,"rings unchanged");
    }
    void sample(int ax,float deg) { assert(tool.applyPrincipalRotateSample(ax,cast(float)(deg*PI/180),stack),"exact principal sample accepted"); }
}

unittest {
    assert(loadSDL()==sdlSupport,"CPU input SDL binding");
    SDL_SetModState(cast(SDL_Keymod)0);
    auto savedSpace=primaryModelSpaceResolver;scope(exit) primaryModelSpaceResolver=savedSpace;
    primaryModelSpaceResolver=()=>ModelSpace.world();
    auto savedPipe=g_pipeCtx;scope(exit) g_pipeCtx=savedPipe;
    auto fixture=parseJSON(readText("tests/fixtures/local_component_frame/rotation_sequence.json"));
    string cell=environment.get("VIBE3D_LOCAL_ROTATE_CELL","all");
    string product=environment.get("VIBE3D_LOCAL_ROTATE_PRODUCT","all");
    assert(cell=="all"||cell=="first"||cell=="second"||cell=="sequence","explicit cell selector valid");
    assert(product=="all"||product=="rotate"||product=="xfrm.transform","explicit product selector valid");
    size_t executed;
    foreach(id;["rotate","xfrm.transform"]) {
        if(product!="all"&&product!=id) continue;
        foreach(name;["first","second","sequence"]) {
            if(cell!="all"&&cell!=name) continue;
            writeln("LOCAL-ROTATE-CELL start ",name," ",id);
            auto rig=new Rig(fixture,id,name=="second"?1:0);
            auto px=rig.press(name=="second"?1:0);
            rig.sample(name=="second"?1:0,name=="second"?-27:-18);
            if(name!="sequence") {rig.output(name=="second"?2:1,name~" native full output "~id);rig.release(px);}
            else {
                rig.output(1,"sequence first native full output "~id);rig.release(px);
                rig.refresh(1);px=rig.press(1);rig.sample(1,-27);
                rig.output(2,"sequence final native full output "~id);rig.release(px);rig.refresh(2);
                auto base=rig.mp.vertices.dup;auto cp=*rig.stack.get!ActionCenterPacket();auto ap=*rig.stack.get!AxisPacket();
                px=rig.press(2);rig.sample(2,-5);rig.vertices(rig.folded(base,2,-5,ap,cp),"third current signed packet output");rig.release(px);
            }
            ++executed;writeln("LOCAL-ROTATE-CELL passed ",name," ",id);
        }
    }
    if(cell=="all") foreach(id;["rotate","xfrm.transform"]) {
        if(product!="all"&&product!=id) continue;
        void receipt(string name,scope void delegate() body) {
            writeln("LOCAL-ROTATE-CELL start ",name," ",id);body();++executed;
            writeln("LOCAL-ROTATE-CELL passed ",name," ",id);
        }
        receipt("refusal",{
            auto r=new Rig(fixture,id);auto before=r.mp.vertices.dup;auto display=r.tool.publishedRotate();
            assert(!r.tool.applyPrincipalRotateSample(0,.1f,r.stack),"idle principal refusal");
            auto px=r.press(0);
            foreach(ax;[-1,3,1]) assert(!r.tool.applyPrincipalRotateSample(ax,.1f,r.stack),"wrong principal index/latch refusal");
            foreach(value;[float.nan,float.infinity,-float.infinity])
                assert(!r.tool.applyPrincipalRotateSample(0,value,r.stack),"nonfinite principal refusal");
            r.vertices(before,"refusal preserves geometry");assert(r.tool.publishedRotate()==display,"refusal preserves display");
            r.sample(0,-18);r.output(1,"accepted paired principal output");r.release(px);
        });
        receipt("event",{
            auto r=new Rig(fixture,id);auto baseline=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto physical=r.physicalAxis(0);auto px=r.press(0);auto priorDepth=r.depth();
            SDL_MouseMotionEvent e;e.state=1;e.x=px[0]+24;e.y=px[1]+12;e.xrel=24;e.yrel=12;
            assert(r.tool.onMouseMotion(e,r.stack),"actual caller motion accepted");
            auto angle=r.tool.rotateBank().pendingRotateAngle;
            assert(abs(angle)> .01,"nonzero actual pending scalar");
            auto expected=r.folded(baseline,0,cast(float)(angle*180/PI),ap,cp);
            r.vertices(expected,"event physical-channel output");
            r.orientation(pivotRotationMatrix(Vec3(0,0,0),physical,angle),"event published world orientation");
            r.release([e.x,e.y]);assert(r.depth()==priorDepth+1,"one event history entry");
            const source=readText("source/tools/transform/xfrm_transform.d");
            import std.string : count;
            assert(source.count("public final bool applyPrincipalRotateSample(")==1&&
                source.count("applyPrincipalRotateSample(ax, ang, vts)")==1,"one real principal caller census");
        });
        receipt("same-axis",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto axis=r.physicalAxis(0);auto px=r.press(0);r.sample(0,-18);
            r.output(1,"same-axis first output");r.release(px);r.refresh();
            auto nextAxis=r.physicalAxis(0);px=r.press(0);
            r.sample(0,-4);r.sample(0,-9);r.sample(0,-9);
            auto expected=r.folded(base,0,-27,ap,cp);r.vertices(expected,"same-axis absolute accumulation without overcount");
            auto orientation=matMul4(pivotRotationMatrix(Vec3(0,0,0),nextAxis,cast(float)(-9*PI/180)),
                pivotRotationMatrix(Vec3(0,0,0),axis,cast(float)(-18*PI/180)));
            r.orientation(orientation,"same-axis retained world orientation");r.release(px);
            assert(r.depth()==2,"same-axis exactly two entries");
            auto projection=r.projection();auto replay=r.tool.buildPreparedReplay(projection,null);
            assert(replay.valid,"same-axis companion replay reachable");
            near(replay.expectedGestureStartComponentRotate,Vec3(-18,0,0),"nonidentity gesture-start companion capture");
            assert(r.tool.preparedReplayMatches(replay,*r.mp),"same-axis companion replay matches");

        });
        receipt("prepared-replay",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto axis=r.physicalAxis(0);auto px=r.press(0);r.sample(0,-18);r.release(px);
            auto live=r.mp.vertices.dup;auto display=r.tool.publishedRotate();auto p=r.projection();
            auto image=r.tool.buildPreparedReplay(p,null);
            assert(image.valid&&image.meshPrepared&&image.deliveryFlags!=0,"reachable prepared panel replay");
            assert(image.expectedComponentRotate==Vec3(-18,0,0)&&image.expectedComponentRotate!=display,"companion differs from world display");
            auto expected=r.folded(base,0,-18,ap,cp);
            foreach(vi,v;expected) near(image.candidate.vertices[vi],v,"prepared copied companion candidate full output");
            r.vertices(live,"prepared build detached");assert(r.tool.publishedRotate()==display,"prepared build display unchanged");
            assert(image.expectedLive.matches(*r.mp),"replay expected live snapshot matches");
            assert(r.tool.preparedReplayMatches(image,*r.mp),"original companion replay accepted before perturbation");
            auto layer=r.session.document().primary;auto itemPose=layer.xform;
            assert(image.expectedWrapperItemTargets.length==1&&image.expectedWrapperItemXforms.length==1,"wrapper snapshot population one");
            assert(image.expectedWrapperItemTargets[0] is layer&&image.expectedWrapperItemXforms[0]==itemPose,"wrapper snapshot identity and xform");
            assert(image.meshPrepared&&!image.itemPrepared&&image.itemTargets.length==0&&image.expectedItemXforms.length==0&&image.nextItemXforms.length==0,"geometry write arrays empty and domain exclusive");
            auto second=r.tool.buildPreparedReplay(p,null);
            assert(image.expectedWrapperItemTargets.ptr!=second.expectedWrapperItemTargets.ptr&&image.expectedWrapperItemXforms.ptr!=second.expectedWrapperItemXforms.ptr,"snapshot arrays own distinct storage");
            auto changed=image;changed.expectedWrapperItemTargets=null;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"wrapper target count refusal");
            changed=image;changed.expectedWrapperItemTargets=null;changed.expectedWrapperItemXforms=null;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"coherent empty wrapper snapshot count refusal");
            changed=image;changed.expectedWrapperItemXforms=image.expectedWrapperItemXforms.dup~itemPose;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"wrapper xform count refusal");
            changed=image;changed.expectedWrapperItemTargets=image.expectedWrapperItemTargets.dup;changed.expectedWrapperItemTargets[0]=new Layer;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"wrapper identity refusal");
            changed=image;changed.expectedWrapperItemTargets=image.expectedWrapperItemTargets.dup;changed.expectedWrapperItemTargets[0]=null;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"wrapper null refusal");
            changed=image;changed.expectedWrapperItemXforms=image.expectedWrapperItemXforms.dup;changed.expectedWrapperItemXforms[0].pos.x+=1;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"wrapper snapshot xform refusal");
            layer.xform.pos.x+=1;assert(!r.tool.preparedReplayMatches(image,*r.mp),"live wrapper stale xform refusal");layer.xform=itemPose;
            foreach(term;0..5) {
                changed=image;
                if(term==0) changed.itemTargets=[layer];
                if(term==1) changed.expectedItemXforms=[itemPose];
                if(term==2) changed.nextItemXforms=[itemPose];
                if(term==3) changed.itemPrepared=true;
                if(term==4) changed.meshPrepared=false;
                assert(!r.tool.preparedReplayMatches(changed,*r.mp),format("geometry domain/array refusal %s",term));
            }
            changed=image;changed.expectedComponentRotate.x+=1;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"perturbed live companion replay refusal");
            changed=image;changed.expectedGestureStartComponentRotate.x+=1;
            assert(!r.tool.preparedReplayMatches(changed,*r.mp),"perturbed gesture companion replay refusal");
            assert(r.tool.preparedReplayMatches(image,*r.mp),"original companion replay accepted");
            r.tool.installPreparedReplay(image);assert(!image.valid,"direct replay image consumed");
            r.tool.installPreparedReplay(image);r.vertices(live,"repeated direct replay inert");
            auto context=new PreparedRecordContext(null,new RecordObserverHub);
            auto owner=PreparedXfrmReplayOwner.prepare(r.tool,layer,p,context);
            assert(owner !is null&&owner.meshPrepared()&&owner.deliveryFlags()!=0,"real prepared owner accepted");
            assert(context.markNoHistoryInstall(),"real replay no-history enlistment");
            assert(context.prepareStampedMeshImage(layer,owner.candidate(),owner.deliveryFlags(),owner.deliveryDomains()),"real replay candidate enlistment");
            assert(context.prepareXfrmReplay(owner)&&context.validate(),"real replay owner validation");
            context.install();context.install();r.vertices(expected,"real prepared replay installed and repeated inert");
            assert(layer.xform==itemPose,"geometry installation does not write Item snapshot");
            r.refresh();auto nextAxis=r.physicalAxis(0);px=r.press(0);r.sample(0,-9);
            r.vertices(r.folded(base,0,-27,ap,cp),"post-install companion same-axis output");
            r.orientation(matMul4(pivotRotationMatrix(Vec3(0,0,0),nextAxis,cast(float)(-9*PI/180)),
                pivotRotationMatrix(Vec3(0,0,0),axis,cast(float)(-18*PI/180))),"post-install retained world orientation");r.release(px);
            assert(layer.xform==itemPose,"next geometry gesture preserves Item xform");
        });
        receipt("item-replay",{
            auto r=new Rig(fixture,id,0,true);auto layer=r.session.document().primary;
            auto before=layer.xform;auto meshBefore=r.mp.vertices.dup;
            auto px=r.press(0);r.sample(0,-18);r.release(px);
            assert(layer.xform!=before,"real Item gesture changes nonidentity pose");
            auto live=layer.xform;auto p=r.projection();auto image=r.tool.buildPreparedReplay(p,null);
            assert(image.valid&&image.itemPrepared&&!image.meshPrepared&&image.itemTargets.length==1,"Item replay population and exclusive routing");
            assert(image.expectedWrapperItemXforms.length==1&&image.expectedWrapperItemXforms[0]==live&&live!=ItemXform.init,"nonidentity Item exact snapshot");
            assert(image.expectedItemXforms.length==1&&image.nextItemXforms.length==1,"Item write pre/post population");
            assert(r.tool.preparedReplayMatches(image,*r.mp),"original Item replay matches");
            foreach(term;0..7) {
                auto changed=image;
                if(term==0) changed.itemTargets=null;
                if(term==1) {changed.itemTargets=image.itemTargets.dup;auto foreign=new Layer;foreign.xform=live;changed.itemTargets[0]=foreign;}
                if(term==2) {changed.itemTargets=image.itemTargets.dup;changed.itemTargets[0]=null;}
                if(term==3) {changed.expectedItemXforms=image.expectedItemXforms.dup;changed.expectedItemXforms[0].rot.x+=1;}
                if(term==4) changed.expectedItemXforms=image.expectedItemXforms.dup~live;
                if(term==5) changed.nextItemXforms=null;
                if(term==6) {changed.meshPrepared=false;changed.itemPrepared=false;}
                assert(!r.tool.preparedReplayMatches(changed,*r.mp),format("Item domain/array refusal %s",term));
            }
            assert(layer.xform==live,"Item negatives preserve live pose");r.vertices(meshBefore,"Item replay never writes geometry");
            r.tool.installPreparedReplay(image);assert(!image.valid,"Item image consumed");
            auto installed=layer.xform;r.tool.installPreparedReplay(image);assert(layer.xform==installed,"Item repeated install inert");
        });
        receipt("undo-redo",{
            auto r=new Rig(fixture,id);auto px=r.press(0);r.sample(0,-18);r.release(px);r.refresh(1);
            px=r.press(1);r.sample(1,-27);r.release(px);r.output(2,"undo-redo p2");
            assert(r.history.undo(),"second gesture undo");r.output(1,"undo restores p1");
            assert(r.history.redo(),"second gesture redo");r.output(2,"redo restores p2");
            r.tool.resyncSession();r.refresh();
            auto p=r.projection();auto image=r.tool.buildPreparedReplay(p,null);
            assert(image.valid,"redo replay image valid");
            near(image.expectedComponentRotate,Vec3(0,-27,0),"redo restores captured companion");
            r.refresh();auto base=r.mp.vertices.dup;auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto prior=matrixFromEulerZYX(r.tool.publishedRotate());auto axis=r.physicalAxis(1);
            px=r.press(1);r.sample(1,-3);
            Vec3[] segmentBase;foreach(v;fixture["positionsByStep"][1].array) segmentBase~=vector(v);
            cp.clusterCenters=cp.clusterCenters.dup;ap.clusterRight=ap.clusterRight.dup;ap.clusterUp=ap.clusterUp.dup;ap.clusterFwd=ap.clusterFwd.dup;
            foreach(c,g;fixture["groupsByStep"][1].array) {
                cp.clusterCenters[c]=vector(g["center"]);ap.clusterRight[c]=vector(g["right"]);
                ap.clusterUp[c]=vector(g["up"]);ap.clusterFwd[c]=vector(g["normal"]);
            }
            r.vertices(r.folded(segmentBase,1,-30,ap,cp),"redo next real gesture output");
            r.orientation(matMul4(pivotRotationMatrix(Vec3(0,0,0),axis,cast(float)(-3*PI/180)),prior),"redo next world orientation");r.release(px);
        });
        receipt("cancel",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;auto px=r.press(0);
            r.sample(0,-18);r.output(1,"cancel before nonidentity");
            assert(r.tool.hasUncommittedEdit(),"live cancel session open");r.tool.cancelUncommittedEdit();
            r.vertices(base,"cancel pregesture geometry");assert(r.depth()==0,"cancel no history");
            r.tool.activate();r.refresh(0);px=r.press(0);r.sample(0,-18);r.output(1,"fresh run after cancel");r.release(px);
        });
        receipt("stage-refire",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto px=r.press(0);r.sample(0,-18);auto display=r.tool.publishedRotate();
            r.tool.reEvaluate(ParameterChangeBatch(ParameterChangeSource.StageAttribute,["strength"]));
            r.vertices(r.folded(base,0,-18,ap,cp),"stage-only refire retains local companion");
            assert(r.tool.publishedRotate()==display,"stage-only refire preserves world display");r.release(px);
        });
        receipt("move-refire",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto px=r.press(0);r.sample(0,-18);auto display=r.tool.publishedRotate();
            auto channels=parseJSON("{\"TX\":0.037,\"TY\":0,\"TZ\":0}");injectParamsInto(r.tool.params(),channels);
            r.tool.reEvaluate(ParameterChangeBatch(ParameterChangeSource.InteractiveValue,["TX"]));
            assert(r.tool.publishedTranslate()==Vec3(.037f,0,0),"Move-only batch retains nonzero authored Move");
            auto expected=r.folded(base,0,-18,ap,cp);
            if(id=="xfrm.transform") foreach(vi,c;cp.clusterOf) if(c>=0) expected[vi]=expected[vi]+ap.clusterRight[c]*.037f;
            r.vertices(expected,"Move-only batch retains held local rotation");
            assert(r.tool.publishedRotate()==display,"Move-only batch preserves world display");r.release(px);
        });
        receipt("legacy-numeric",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            r.tool.applyRotateAbsoluteFromRun(Vec3(cast(float)(7*PI/180),cast(float)(-11*PI/180),cast(float)(13*PI/180)));
            r.vertices(r.numericFold(base,Vec3(7,-11,13),ap,cp),"legacy full-vector numeric companion");
        });
        receipt("batch-numeric",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            auto channels=parseJSON("{\"RX\":7,\"RY\":-11,\"RZ\":13}");injectParamsInto(r.tool.params(),channels);
            r.tool.reEvaluate(ParameterChangeBatch(ParameterChangeSource.ScriptedValue,["RX","RY","RZ"]));
            r.vertices(r.numericFold(base,Vec3(7,-11,13),ap,cp),"value full-vector numeric companion");
        });
        receipt("reset-drop",{
            auto r=new Rig(fixture,id);auto px=r.press(0);r.sample(0,-18);r.release(px);
            r.tool.deactivate();r.tool.activate();r.refresh();
            auto base=r.mp.vertices.dup;auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            px=r.press(1);r.sample(1,-6);r.vertices(r.folded(base,1,-6,ap,cp),"drop activation clears held companion");r.release(px);
        });
        receipt("numeric",{
            auto r=new Rig(fixture,id);auto base=r.mp.vertices.dup;
            auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
            Vec3[] expected=base.dup;
            foreach(vi,c;cp.clusterOf) if(c>=0) {
                auto m=matMul4(pivotRotationMatrix(cp.clusterCenters[c],ap.clusterFwd[c],cast(float)(13*PI/180)),
                    matMul4(pivotRotationMatrix(cp.clusterCenters[c],ap.clusterUp[c],cast(float)(-11*PI/180)),
                        pivotRotationMatrix(cp.clusterCenters[c],ap.clusterRight[c],cast(float)(7*PI/180))));
                expected[vi]=applyAffine(m,base[vi]);
            }
            auto channels=parseJSON(`{"RX":7,"RY":-11,"RZ":13}`);injectParamsInto(r.tool.params(),channels);
            assert(r.tool.applyHeadless(),"full vector numeric accepted");r.vertices(expected,"full vector numeric component ZYX");
            r.tool.activate();r.refresh( -1 );
            auto px=r.press(0);r.sample(0,-6);
            auto p=r.projection();auto image=r.tool.buildPreparedReplay(p,null);
            assert(image.expectedComponentRotate==Vec3(-6,0,0),"activation clears companion before fresh run");r.release(px);
        });
    }
    if(cell=="all"&&(product=="all"||product=="xfrm.transform")) {
        writeln("LOCAL-ROTATE-CELL start mixed-move xfrm.transform");
        auto r=new Rig(fixture,"xfrm.transform");auto base=r.mp.vertices.dup;
        auto cp=*r.stack.get!ActionCenterPacket();auto ap=*r.stack.get!AxisPacket();
        auto px=r.movePress();
        SDL_MouseMotionEvent e;e.state=1;e.x=px[0]+21;e.y=px[1]+13;e.xrel=21;e.yrel=13;
        assert(r.tool.onMouseMotion(e,r.stack),"mixed first Move motion");
        auto t1=r.tool.publishedTranslate();assert(dot(t1,t1)>.00001,"mixed Move nonidentity population");
        Vec3[] first=base.dup;
        foreach(vi,c;cp.clusterOf) if(c>=0) first[vi]=base[vi]+ap.clusterRight[c]*t1.x+ap.clusterUp[c]*t1.y+ap.clusterFwd[c]*t1.z;
        r.vertices(first,"mixed first Move full output");r.release([e.x,e.y]);
        Vec3 origin,fr,fu,ff;bool frameValid;r.tool.publishedRunFrame(frameValid,origin,fr,fu,ff);assert(frameValid,"mixed frozen Move frame");
        r.refresh();px=r.press(0);r.sample(0,-18);r.release(px);
        assert(r.tool.publishedTranslate()==t1,"mixed Rotate retains Move accumulation");
        Vec3 o2,r2,u2,f2;r.tool.publishedRunFrame(frameValid,o2,r2,u2,f2);assert(frameValid&&o2==origin&&r2==fr&&u2==fu&&f2==ff,"mixed Rotate retains frozen frame");
        auto rotated=r.folded(base,0,-18,ap,cp);
        foreach(vi,c;cp.clusterOf) if(c>=0) rotated[vi]=rotated[vi]+ap.clusterRight[c]*t1.x+ap.clusterUp[c]*t1.y+ap.clusterFwd[c]*t1.z;
        r.vertices(rotated,"mixed held Rotate full output");
        r.refresh();px=r.movePress();e.x=px[0]+15;e.y=px[1]+9;e.xrel=15;e.yrel=9;
        assert(r.tool.onMouseMotion(e,r.stack),"mixed second Move motion");
        auto t2=r.tool.publishedTranslate();assert(t2!=t1,"mixed second Move accumulation");
        auto expected=r.folded(base,0,-18,ap,cp);
        foreach(vi,c;cp.clusterOf) if(c>=0) expected[vi]=expected[vi]+ap.clusterRight[c]*t2.x+ap.clusterUp[c]*t2.y+ap.clusterFwd[c]*t2.z;
        r.vertices(expected,"mixed second Move retains held Rotate");
        r.tool.publishedRunFrame(frameValid,o2,r2,u2,f2);assert(frameValid&&o2==origin&&r2==fr&&u2==fu&&f2==ff,"mixed second Move frozen frame");r.release([e.x,e.y]);
        assert(r.depth()==3,"mixed three gesture entries");++executed;
        writeln("LOCAL-ROTATE-CELL passed mixed-move xfrm.transform");
    }
    if(cell=="all"&&product=="all") {
        assert(executed==33,"complete declared cell table population");
        writeln("LOCAL-ROTATE-ALL cells=",executed," products=2");
    }
}
