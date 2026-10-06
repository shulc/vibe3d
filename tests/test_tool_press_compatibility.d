// Internal c35 compatibility observations, driven through actual event delivery.
import drag_helpers : Vec3, fetchCamera, playAndWait, kPaceLine;
import pen_rig_helpers : penCommand, penSceneEmpty, penCameraAt, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json : JSONValue, JSONType;
import std.file : write, remove, exists, tempDir;
import std.path : buildPath;
import std.process : thisProcessID, environment;
import std.format : format;
import std.math : abs;
import std.algorithm : canFind;
import std.array : split;

void main() {}
private bool runs(string id) {
    const filter=environment.get("VIBE3D_CELL","");
    return filter.length==0 || filter.split(",").canFind(id);
}
private string meshText(const Vec3[] vertices, const uint[][] faces=null,
                        const uint[][] wires=null, const bool[] subpatch=null) {
    string vs,fs,ws,ss;
    foreach(i,v; vertices) vs~=format("%s[%.9g,%.9g,%.9g]",i?",":"",v.x,v.y,v.z);
    foreach(i,f; faces) fs~=format("%s[%(%s,%)]",i?",":"",f);
    foreach(i,e; wires) ws~=format("%s[%s,%s]",i?",":"",e[0],e[1]);
    foreach(i,s; subpatch) ss~=format("%s%s",i?",":"",s?"true":"false");
    return format(`{"vertices":[%s],"faces":[%s],"wireEdges":[%s],"faceSubpatch":[%s]}`,vs,fs,ws,ss);
}
private int[2] rig(string primary,string secondary=null,string style="wireframe",string transform=null) {
    penSceneEmpty("Top");
    const path=buildPath(tempDir(),format("press-compatibility-%s.v3d",thisProcessID));
    scope(exit) if(exists(path)) remove(path);
    string layers=format(`{"type":"mesh","selected":true,"channels":{"name":"Primary","visible":true%s},"mesh":%s}`,
        transform.length?","~transform:"",primary);
    if(secondary.length) layers~=format(`,{"type":"mesh","selected":true,"channels":{"name":"Secondary","visible":true},"mesh":%s}`,secondary);
    write(path,format(`{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[%s]}`,layers));
    penCommand("file.load path:"~JSONValue(path).toString());
    penCommand("viewport.view Top"); penCameraAt(Vec3(0,0,0),200);
    penCommand("viewport.displayStyle "~style);
    penCommand("tool.set mesh.topoPen on"); penCommand("tool.attr mesh.topoPen mode move");
    penCommand("tool.pipe.attr constrain enabled false");
    penCommand(`tool.pipe.attr snap types ""`);
    penCommand("history.clear");
    const c=fetchCamera(); return [c.vpX+c.width/2,c.vpY+c.height/2];
}
private void event(int[2] at,string type,int buttons=0,int dx=0,int dy=0) {
    const c=fetchCamera();
    const tail=type=="SDL_MOUSEMOTION"?format(`"xrel":%s,"yrel":%s,"state":%s`,dx,dy,buttons):`"btn":1,"clicks":1`;
    playAndWait(format(`{"t":0,"type":"VIEWPORT","vpX":%s,"vpY":%s,"vpW":%s,"vpH":%s,"fovY":0.785398}`~"\n"~kPaceLine~
        `{"t":20,"type":"%s","x":%s,"y":%s,%s,"mod":0}`~"\n",c.vpX,c.vpY,c.width,c.height,type,at[0],at[1],tail));
}
private long history() {return cast(long)getJson("/api/history")["undo"].array.length;}
private void arm(int[2] at,string kind,long index) {
    event(at,"SDL_MOUSEBUTTONDOWN"); const s=getJson("/api/tool/state");
    assert(s["moveArmed"].type==JSONType.true_ && s["moveElem"].str==kind && s["placeArmed"].type==JSONType.false_,
        "compatibility-press: actual grab class "~kind~" got "~s.toString());
    if(kind=="vertex") assert(s["grabbedVert"].integer==index,"compatibility-press: actual vertex identity");
}
private void hover(int[2] at,string kind,long index) {
    const before=getJson("/api/model"); const rows=history();
    event(at,"SDL_MOUSEMOTION"); const s=getJson("/api/tool/state"); const h=s["hoverIndicator"];
    assert(h["grabElem"].str==kind && h["grabIndex"].integer==index,
        format("compatibility-hover: actual %s id%s expected %s id%s",h["grabElem"].str,h["grabIndex"].integer,kind,index));
    const after=getJson("/api/model");
    assert(s["moveArmed"].type==JSONType.false_ && s["placeArmed"].type==JSONType.false_ && history()==rows
        && after["vertices"]==before["vertices"] && after["faces"]==before["faces"] && after["edges"]==before["edges"],
        format("compatibility-hover: motion is passive; rows %s/%s move=%s place=%s before=%s after=%s",history(),rows,s["moveArmed"],s["placeArmed"],before,after));
}

// A measured ordinary-FACE positive precedes every filtered compatibility cell.
unittest {
    Vec3[] vs;uint[][] fs;
    foreach(z;0..3)foreach(x;0..3)vs~=Vec3((x-1)*.5,0,(z-1)*.5);
    foreach(z;0..2)foreach(x;0..2){const a=cast(uint)(z*3+x);fs~=[a,a+3,a+4,a+1];}
    const at=rig(meshText(vs,fs),null,"shaded");arm(at,"vertex",4);event(at,"SDL_MOUSEBUTTONUP");
    assert(readVerts()==vs && history()==1,"ordinary-control: real front-FACE stationary Move retains measured arm/geometry/row before legacy probes");
}

unittest {
    if(!runs("boundary_order")) return;
    size_t population;
    foreach(edge;[false,true]) foreach(offset;[-7.75f,8.25f]) {
        Vec3[] vs=edge?[Vec3(offset/200,0,-.15),Vec3(offset/200,0,.15)]:[Vec3(offset/200,0,0)];
        const at=rig(meshText(vs,null,edge?[[0u,1u]]:null));
        assert(readVerts().length==(edge?2:1),"compatibility-rig: raw primary population");
        const accepted=offset<0;
        hover(at,accepted?(edge?"edge":"vertex"):"none",accepted?0:-1);
        const rows=history();
        if(accepted) {
            arm(at,edge?"edge":"vertex",0);
            event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);
            event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
            const after=readVerts();
            foreach(i,v; after) assert(abs(v.x-vs[i].x-.1f)<1e-4,"compatibility-release: old grab moved its actual source");
            assert(history()==rows+1,"compatibility-history: one accepted Move row");
        } else {
            event(at,"SDL_MOUSEBUTTONDOWN");
            assert(getJson("/api/tool/state")["moveArmed"].type==JSONType.false_,"compatibility-reach: out-of-integer-reach press refuses");
            event(at,"SDL_MOUSEBUTTONUP");
            assert(readVerts()==vs,"compatibility-reach: refusal leaves geometry");
        }
        ++population;
    }
    assert(population==4,"compatibility-rig: four populated boundary controls");
}

unittest {
    if(!runs("representations")) return;
    size_t population;
    foreach(which;0..4) {
        const vs=[Vec3(-.15,0,0),Vec3(.15,0,0),Vec3(.15,0,.3),Vec3(-.15,0,.3)];
        const fs=which==0?cast(uint[][])null:which==1?[[0u,1u]]:which==2?[[0u,1u,2u,3u]]:[[0u,1u,2u,3u],[0u,3u,2u,1u]];
        const at=rig(meshText(vs,fs,which==0?[[0u,1u]]:null,which==2?[true]:which==3?[false,true]:null));
        const model=getJson("/api/model");
        assert(model["vertexCount"].integer==4 && model["edgeCount"].integer>0,"compatibility-representation: populated raw source");
        assert(model["faceCount"].integer==(which==0?0:which==3?2:1),"compatibility-representation: exact face support population");
        arm(at,"edge",0); event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20); event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
        const after=readVerts();
        assert(abs(after[0].x-vs[0].x-.1f)<1e-4 && abs(after[1].x-vs[1].x-.1f)<1e-4,
            "compatibility-representation: actual loose/short/subpatch edge carries both ends");
        ++population;
    }
    assert(population==4,"compatibility-representation: four public-door controls");
}

unittest {
    if(!runs("primary_cover")) return;
    const primaryCover=meshText([Vec3(0,0,0),Vec3(-.5,1,-.5),Vec3(.5,1,-.5),Vec3(.5,1,.5),Vec3(-.5,1,.5)],[[1u,2u,3u,4u]]);
    const secondary=meshText([Vec3(-.4,2,-.4),Vec3(.4,2,-.4),Vec3(.4,2,.4),Vec3(-.4,2,.4)],[[0u,3u,2u,1u]]);
    foreach(withSecondary;[false,true]) {
        const at=rig(primaryCover,withSecondary?secondary:null,"shaded");
        hover(at,"face",0);
        const before=getJson("/api/model"); const selection=getJson("/api/selection"); const rows=history();
        event(at,"SDL_MOUSEBUTTONDOWN"); const state=getJson("/api/tool/state");
        assert(state["moveArmed"].type==JSONType.false_,"compatibility-source: covered loose primary and secondary authoring refuse");
        event(at,"SDL_MOUSEBUTTONUP");
        const after=getJson("/api/model");
        assert(after["vertices"]==before["vertices"] && after["faces"]==before["faces"] && after["edges"]==before["edges"]
            && getJson("/api/selection")==selection && history()==rows+1,
            format("compatibility-source: refusal preserves geometry/selection and existing press row; rows %s/%s before=%s after=%s",history(),rows,before,after));
    }
    const wire=rig(primaryCover,secondary,"wireframe"); hover(wire,"vertex",0); arm(wire,"vertex",0); event(wire,"SDL_MOUSEBUTTONUP");
    const bare=rig(meshText([Vec3(0,0,0)]),secondary,"shaded"); hover(bare,"vertex",0);
}

unittest {
    if(!runs("nearest_ties"))return;
    size_t population;
    foreach(edge;[false,true])foreach(reverse;[false,true])foreach(tie;[false,true]) {
        const left=-3.0f,right=tie?3.0f:3.25f;
        const offsets=reverse?[right,left]:[left,right]; Vec3[] vs;uint[][] wires;
        foreach(x;offsets) {
            const n=cast(uint)vs.length;
            if(edge){vs~=[Vec3(x/200,0,-.15),Vec3(x/200,0,.15)];wires~=[n,n+1];}
            else vs~=Vec3(x/200,0,0);
        }
        const winner=tie?0:reverse?1:0;const at=rig(meshText(vs,null,wires));
        hover(at,edge?"edge":"vertex",winner);
        arm(at,edge?"edge":"vertex",edge?winner*2:winner);
        event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
        const after=readVerts();assert(after.length==vs.length,"legacy-order-release: raw population pinned");
        foreach(i,v;after) {
            const moved=edge?i/2==winner:i==winner;
            assert(abs(v.x-vs[i].x-(moved?.1f:0))<1e-4 && abs(v.z-vs[i].z)<1e-4,
                format("legacy-order-release: old nearest/tie%s/%s/%s carries id%s only, v%s got %s",edge,reverse,tie,winner,i,v));
        }
        ++population;
    }
    assert(population==8,"legacy-order-release: V/E nearest plus both first-array ties");
}

unittest {
    if(!runs("local_visibility") && !runs("local_press_visibility"))return;
    const aw=Vec3(-.5,-.7,-.2),bw=Vec3(.5,.7,.2);
    const a=Vec3(-.2828427125,-.4714045208,-2),b=Vec3(.2828427125,.4714045208,2);
    const transform=`"rot.z":45,"scl.x":3,"scl.y":0.3,"scl.z":0.1`;
    Vec3 toLocal(Vec3 w) {enum float k=.7071067812f;return Vec3((w.x+w.y)*k/3,(w.y-w.x)*k/.3,w.z/.1);}
    const centre=Vec3(.067851,.5,.0271404);
    Vec3[] cover=[Vec3(centre.x-.008,centre.y,centre.z-.008),Vec3(centre.x+.008,centre.y,centre.z-.008),
                 Vec3(centre.x+.008,centre.y,centre.z+.008),Vec3(centre.x-.008,centre.y,centre.z+.008)];
    foreach(which;0..4) {
        const transformed=which!=1;Vec3[] vs=transformed?[a,b]:[aw,bw];
        if(which>0)foreach(w;cover) { auto position=w;if(which==3)position.y=.08;vs~=transformed?toLocal(position):position; }
        const at0=rig(meshText(vs,which>0?[[2u,3u,4u,5u]]:null,[[0u,1u]]),null,"shaded",transformed?transform:null);
        const int[2] at=[at0[0],at0[1]+5];
        if(which<2 || which==3) {
            if(runs("local_visibility"))hover(at,"edge",which==0?0:4);arm(at,"edge",0);
            event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
            const after=readVerts();const delta=transformed?toLocal(Vec3(.1,0,0)):Vec3(.1,0,0);
            foreach(i;0..2)assert(abs(after[i].x-vs[i].x-delta.x)<1e-4 && abs(after[i].y-vs[i].y-delta.y)<1e-4,
                "LEGACY_LOCAL_EDGE_VIS: actual uncovered/identity positive release");
        } else {
            if(runs("local_visibility"))hover(at,"none",-1);const before=readVerts();const rows=history();
            event(at,"SDL_MOUSEBUTTONDOWN");assert(getJson("/api/tool/state")["moveArmed"].type==JSONType.false_,
                "LEGACY_LOCAL_EDGE_VIS: transformed old local visibility refuses actual press");
            event(at,"SDL_MOUSEBUTTONUP");assert(readVerts()==before && history()==rows+1,
                "LEGACY_LOCAL_EDGE_VIS: refusal geometry and existing row preserved");
        }
    }
}

unittest {
    if(!runs("ordinary_hover_cover"))return;
    Vec3[] vs;uint[][] fs;
    foreach(z;0..3)foreach(x;0..3)vs~=Vec3((x-1)*.5,0,(z-1)*.5);
    foreach(z;0..2)foreach(x;0..2){const a=cast(uint)(z*3+x);fs~=[a,a+3,a+4,a+1];}
    vs~=[Vec3(-1,1,-1),Vec3(1,1,-1),Vec3(1,1,1),Vec3(-1,1,1)];fs~=[9u,10u,11u,12u];
    foreach(edge;[false,true]) {
        auto at=rig(meshText(vs,fs),null,"shaded");if(edge)at[0]-=50;
        hover(at,"face",4);
        const before=readVerts();arm(at,edge?"edge":"vertex",4);
        event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
        const after=readVerts();
        foreach(i,v;after) {
            const moved=i==4 || (edge&&i==3);
            assert(abs(v.x-before[i].x-(moved?.1f:0))<1e-4,"LEGACY_HOVER_PRIMARY_COVER: ordinary press and primary legacy hover intentionally use their separate visibility datums");
        }
    }
}

unittest {
    if(!runs("secondary_rebind"))return;
    const secondary=meshText([Vec3(-.4,2,-.4),Vec3(.4,2,-.4),Vec3(.4,2,.4),Vec3(-.4,2,.4)],[[0u,3u,2u,1u]]);
    const at=rig(meshText(null),secondary,"shaded");penCommand("tool.attr mesh.topoPen mode point");const selection=getJson("/api/selection");
    event(at,"SDL_MOUSEBUTTONDOWN");assert(getJson("/api/tool/state")["moveArmed"].type==JSONType.false_ && getJson("/api/tool/state")["placeArmed"].type==JSONType.false_,"secondary-rebind: queried secondary is refused by bound empty primary");
    event(at,"SDL_MOUSEBUTTONUP");assert(readVerts().length==0 && getJson("/api/selection")==selection && history()==1,"secondary-rebind: existing refused row, empty geometry and selection preserved");
    penCommand("layer.select index:1");penCommand("history.clear");const before=readVerts();
    assert(before.length==4,"secondary-rebind: the same actual source is now primary");
    arm(at,"face",0);event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
    const after=readVerts();foreach(i,v;after)assert(abs(v.x-before[i].x-.1f)<1e-4 && abs(v.y-before[i].y)<1e-4,"secondary-rebind: bound source face authors its own populated mesh after rebinding");
    assert(history()==1,"secondary-rebind: one accepted Move row after rebind");
}

unittest {
    if(!runs("midpoint_veto"))return;
    const vs=[Vec3(-3.0f/200,0,0),Vec3(3.25f/200,0,-.15),Vec3(3.25f/200,0,.15)];
    const at=rig(meshText(vs,null,[[1u,2u]]));hover(at,"edge",0);arm(at,"edge",0);
    event([at[0]+20,at[1]],"SDL_MOUSEMOTION",1,20);event([at[0]+20,at[1]],"SDL_MOUSEBUTTONUP");
    const after=readVerts();assert(after.length==3,"LEGACY_MIDPOINT: exact old gathered population");
    assert(after[0]==vs[0] && abs(after[1].x-vs[1].x-.1f)<1e-4 && abs(after[2].x-vs[2].x-.1f)<1e-4,
        "LEGACY_MIDPOINT: half-pixel veto carries the old edge, isolated vertex remains unchanged");
}

unittest {
    if(!runs("face_availability"))return;
    const vs=[Vec3(-.5,0,-.5),Vec3(.5,0,-.5),Vec3(.5,0,.5),Vec3(-.5,0,.5)];
    foreach(front;[false,true])foreach(filled;[false,true]) {
        const at=rig(meshText(vs,front?[[0u,3u,2u,1u]]:[[0u,1u,2u,3u]]),null,filled?"shaded":"wireframe");
        hover(at,filled?"face":"none",filled?0:-1);
    }
}
