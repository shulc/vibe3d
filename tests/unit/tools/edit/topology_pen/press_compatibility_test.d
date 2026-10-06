module tools.edit.topology_pen.press_compatibility_test;

import tools.edit.topology_pen;
import hover_state;
import mesh : Mesh, makeGridPlane;
import math : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix,
    screenPointToRay, projectToWindowFull;
import std.math : abs;
import std.format : format;
import std.stdio : writefln;

private Viewport viewport() {
    return Viewport(lookAt(Vec3(0,5,0), Vec3(0,0,0), Vec3(0,0,-1)),
        orthographicMatrix(1.5f, 1, 0.01f, 100), 600,600,0,0,Vec3(0,5,0));
}
private Vec3 point(float x, float y, const ref Viewport vp) {
    Vec3 ro, rd;
    screenPointToRay(x,y,vp,ro,rd);
    return ro + rd * (-ro.y / rd.y);
}
private void projected(Vec3 p, float x, float y, const ref Viewport vp) {
    float px,py,pz;
    assert(projectToWindowFull(p,vp,px,py,pz));
    assert(abs(px-x)<1e-4 && abs(py-y)<1e-4,
        format("legacy-rig: projected (%s,%s), expected (%s,%s)",px,py,x,y));
}

unittest {
    const vp=viewport(); const ms=ModelSpace.world();
    Mesh isolated; isolated.vertices=[point(300,300,vp)];
    const iso=toolPressSupport(isolated,ms,vp);
    assert(iso.vertices.length==1 && !iso.vertices[0], "scope-isolated: no nonempty face support");
    Mesh loose; loose.vertices=[point(300,270,vp),point(300,330,vp)]; loose.edges=[[0u,1u]];
    const line=toolPressSupport(loose,ms,vp);
    assert(line.edges.length==1 && !line.edges[0] && !line.vertices[0] && !line.vertices[1],
        "scope-loose: raw wire has no FACE support");
    foreach (arity; [1,2]) {
        Mesh shortFace=loose; shortFace.faces=arity==1 ? [[0u]] : [[0u,1u]];
        const s=toolPressSupport(shortFace,ms,vp);
        assert(s.faces.length==1 && !s.faces[0] && !s.vertices[0] && !s.edges[0],
            "scope-short: short faces do not certify their components");
    }
    auto grid=makeGridPlane(2);
    const ordinary=toolPressSupport(grid,ms,vp);
    assert(ordinary.faces.length==4 && ordinary.vertices[4] && ordinary.edges[0],
        "scope-ordinary: populated FACE cage control");
    grid.vertices~=Vec3(0,0,2); grid.edges~=[4u,9u];
    const spur=toolPressSupport(grid,ms,vp);
    assert(spur.vertices.length==10 && spur.edges.length==13 && !spur.vertices[4] && !spur.edges[12],
        "scope-spur: raw loose incidence at an ordinary FACE vertex is retained");
    grid.resizeFaceSelection(); grid.setFaceSubpatch(0,true);
    assert(grid.isFaceSubpatch(0), "scope-rig: marked support is really present");
    const mixed=toolPressSupport(grid,ms,vp);
    assert(!mixed.faces[0] && mixed.faces[3] && !mixed.vertices[4] && !mixed.vertices[1],
        "scope-mixed: all raw support must be ordinary");
    grid.setFaceHidden(0,true);
    const hidden=toolPressSupport(grid,ms,vp);
    assert(!hidden.faces[0] && !hidden.vertices[1],
        "scope-hidden: hidden subdivision support remains unknown");
    Mesh fan;
    fan.vertices=[Vec3(0,0,0),Vec3(1,0,0),Vec3(0,0,1),Vec3(0,0,-1),Vec3(.5,1,0)];
    fan.faces=[[0u,1u,2u],[1u,0u,3u],[0u,1u,4u]]; fan.rebuildEdgesFromFaces(); fan.buildLoops();
    const nonmanifold=toolPressSupport(fan,ms,vp);
    int sharedEdge=-1;
    foreach (i,e; fan.edges) if ((e[0]==0 && e[1]==1) || (e[0]==1 && e[1]==0)) sharedEdge=cast(int)i;
    assert(sharedEdge>=0 && nonmanifold.edgeFaces[sharedEdge]==3 && !nonmanifold.edges[sharedEdge],
        "scope-nonmanifold: raw three-face incidence is not a border witness");
}

// Compatibility observations execute the original c35 helpers with a subset
// callback before reduction; the shared query then consumes their datums.
unittest {
    const vp=viewport(); const ms=ModelSpace.world();
    auto t=new TopologyPenTool(); Mesh m; t.meshSrc_=()=>&m;
    const primary=ToolPressSource(&m,ms);
    foreach (edge; [false,true]) foreach (offset; [-7.75f,8.25f]) {
        m=Mesh.init;
        if (edge) { m.vertices=[point(300+offset,270,vp),point(300+offset,330,vp)]; m.edges=[[0u,1u]]; }
        else m.vertices=[point(300+offset,300,vp)];
        projected(m.vertices[0],300+offset,edge?270:300,vp);
        const old=t.legacyPressGather(300,300,vp,false,primary);
        const accepted=offset<0;
        const distance=edge?old.distances.edge:old.distances.vertex;
        assert((distance<float.infinity)==accepted,edge?"LEGACY_E_REACH: integer reach":"LEGACY_V_REACH: integer reach");
        int index;
        const result=t.resolveGrabTarget(300,300,vp,index,false);
        assert(result==(accepted?(edge?MoveElem.Edge:MoveElem.Vertex):MoveElem.None) && index==(accepted?0:-1),
            edge?"LEGACY_E_REACH: actual query identity":"LEGACY_V_REACH: actual query identity");
        const hover=t.resolveGrabTarget(300,300,vp,index,false,null,ToolQueryIntent.legacyHover);
        assert(hover==result && index==(accepted?0:-1), "LEGACY_HOVER_REACH: actual resolver identity");
        writefln("LEGACY-BASELINE kind=%s offset=%s id=%s distance=%s",edge?"edge":"vertex",offset,index,distance);
    }
    foreach (edge; [false,true]) foreach (reverse; [false,true]) foreach (tie; [false,true]) {
        m=Mesh.init;
        const left=-3.0f, right=tie?3.0f:3.25f;
        const offsets=reverse?[right,left]:[left,right];
        foreach (x; offsets) {
            const i=cast(uint)m.vertices.length;
            if (edge) { m.vertices~=[point(300+x,270,vp),point(300+x,330,vp)]; m.edges~=[i,i+1]; }
            else m.vertices~=point(300+x,300,vp);
        }
        int index;
        const old=t.legacyPressGather(300,300,vp,false,primary);
        const winner=tie?0:(reverse?1:0);
        assert((edge?old.edge.index:old.vertex.index)==winner,
            edge?"LEGACY_E_ORDER: integer nearest and first exact tie":"LEGACY_V_ORDER: integer nearest and first exact tie");
        const result=t.resolveGrabTarget(300,300,vp,index,false);
        assert(result==(edge?MoveElem.Edge:MoveElem.Vertex) && index==winner,
            edge?"LEGACY_E_ORDER: actual query identity":"LEGACY_V_ORDER: actual query identity");
        assert(t.resolveGrabTarget(300,300,vp,index,false,null,ToolQueryIntent.legacyHover)==result && index==winner,
            "LEGACY_HOVER_ORDER: actual resolver identity");
    }
    foreach (edge; [false,true]) {
        m=Mesh.init;
        if (edge) { m.vertices=[point(301,270,vp),point(301,330,vp),point(305,270,vp),point(305,330,vp)]; m.edges=[[0u,1u],[2u,3u]]; }
        else m.vertices=[point(301,300,vp),point(305,300,vp)];
        const mask=[true,false];
        const old=t.legacyPressGather(300,300,vp,false,primary,edge?null:mask,edge?mask:null);
        assert((edge?old.edge.index:old.vertex.index)==1,
            edge?"LEGACY_SUBSET_E: subset reduction preserves second candidate":"LEGACY_SUBSET_V: subset reduction preserves second candidate");
        assert(abs((edge?old.distances.edge:old.distances.vertex)-(edge?4.5f:4.5276926f))<1e-4,
            "LEGACY_SUBSET: half-pixel datum follows old subset winner");
    }
}

unittest {
    import document : ItemXform, primaryModelSpaceResolver;
    import math : closestPointOnSegmentToRay, dot;
    import bvh_pick : BvhPick, SurfaceHit;
    const vp=viewport();
    ItemXform xf; xf.rot=Vec3(0,0,45); xf.scl=Vec3(3,.3,.1);
    const ms=xf.modelSpace();
    const saved=primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver=saved;
    primaryModelSpaceResolver=()=>ms;
    const aw=Vec3(-.5,-.7,-.2), bw=Vec3(.5,.7,.2);
    Mesh m; m.vertices=[ms.toLocalPoint(aw),ms.toLocalPoint(bw)]; m.edges=[[0u,1u]];
    auto t=new TopologyPenTool(); t.meshSrc_=()=>&m;
    const primary=ToolPressSource(&m,ms);
    // Aim five integer pixels off the world midpoint, still within edge reach.
    enum mx=300, my=305;
    Vec3 ro,rd; screenPointToRay(mx+.5f,my+.5f,vp,ro,rd);
    const localOrigin=ms.toLocalPoint(ro), rawLocalDir=ms.toLocalDir(rd);
    const localDir=rawLocalDir/rawLocalDir.length;
    const lp=closestPointOnSegmentToRay(m.vertices[0],m.vertices[1],localOrigin,localDir);
    const wp=closestPointOnSegmentToRay(aw,bw,ro,rd);
    const oldWorld=ms.toWorldPoint(lp);
    const u=m.vertices[1]-m.vertices[0];
    const localT=dot(lp-m.vertices[0],u)/dot(u,u);
    const worldT=dot(wp-aw,bw-aw)/dot(bw-aw,bw-aw);
    assert(abs(localT-worldT)>.04f, "LEGACY_LOCAL_EDGE_VIS: local/world parameters discriminate");
    int index;
    assert(t.resolveGrabTarget(mx,my,vp,index,true)==MoveElem.Edge && index==0,
        "LEGACY_LOCAL_EDGE_VIS: transformed uncovered positive");
    // A narrow primary cover intersects only the old local point's eye ray;
    // its edges are outside the cursor reach, so it cannot win the gather.
    foreach (w; [Vec3(oldWorld.x-.008f,.5,oldWorld.z-.008f),Vec3(oldWorld.x+.008f,.5,oldWorld.z-.008f),
                 Vec3(oldWorld.x+.008f,.5,oldWorld.z+.008f),Vec3(oldWorld.x-.008f,.5,oldWorld.z+.008f)])
        m.vertices~=ms.toLocalPoint(w);
    m.faces=[[2u,3u,4u,5u]]; m.rebuildEdgesFromFaces(); m.addEdge(0,1); m.buildLoops();
    auto bvh=new BvhPick();
    bool visible(Vec3 world) {
        float x,y,z; assert(projectToWindowFull(world,vp,x,y,z));
        Vec3 o,d; screenPointToRay(x,y,vp,o,d); SurfaceHit hit;
        return !bvh.pickSurfaceRay(o,d,m,ms,hit) || hit.t>=dot(world-o,d)/dot(d,d)-1e-4f*(1+dot(world-o,d)/dot(d,d));
    }
    primaryModelSpaceResolver=()=>ModelSpace.world();
    Mesh worldMesh=m; worldMesh.vertices=m.vertices.dup;
    foreach(ref v;worldMesh.vertices) v=ms.toWorldPoint(v);
    t.meshSrc_=()=>&worldMesh;
    assert(t.resolveGrabTarget(mx,my,vp,index,true)==MoveElem.Edge && index==4,
        "LEGACY_LOCAL_EDGE_VIS: identity-space cover twin stays admitted");
    primaryModelSpaceResolver=()=>ms; t.meshSrc_=()=>&m;
    assert(!visible(oldWorld) && visible(wp), "LEGACY_LOCAL_EDGE_VIS: actual two-sided old-point visibility differs");
    const old=t.legacyPressGather(mx,my,vp,true,primary);
    assert(old.edge.index==-1, "LEGACY_LOCAL_EDGE_VIS: original helper refuses covered local point");
    assert(t.resolveGrabTarget(mx,my,vp,index,true)==MoveElem.None && index==-1,
        "LEGACY_LOCAL_EDGE_VIS: shared press preserves original refusal identity");
    assert(t.resolveGrabTarget(mx,my,vp,index,true,null,ToolQueryIntent.legacyHover)==MoveElem.None && index==-1,
        "LEGACY_LOCAL_EDGE_VIS: hover preserves original refusal identity");
    writefln("LEGACY-LOCAL-BASELINE local_t=%s world_t=%s local_world=%s world_point=%s local_visible=false world_visible=true",localT,worldT,oldWorld,wp);
}

unittest {
    import toolpipe.packets : SubjectPacket;
    const vp=viewport(); const ms=ModelSpace.world();
    SubjectPacket subject; subject.pickFacing=true; subject.pickFacesDrawn=false;
    auto t=new TopologyPenTool(); Mesh m; t.meshSrc_=()=>&m;
    m=makeGridPlane(2); subject.mesh=&m; subject.viewport=vp;
    int controlIndex;
    assert(t.resolveGrabTarget(300,300,vp,controlIndex,false,&subject)==MoveElem.None,
        "scope-control: captured ordinary back-facing interior refuses");
    import std.algorithm : reverse;
    foreach(ref f;m.faces) reverse(f); m.buildLoops();
    assert(t.resolveGrabTarget(300,300,vp,controlIndex,false,&subject)==MoveElem.Vertex && controlIndex==4,
        "scope-control: captured ordinary front-facing interior admits");
    size_t n;
    foreach(which;0..6) {
        m=makeGridPlane(2); m.resizeFaceSelection();
        if(which==0) {m=Mesh.init; m.vertices=[Vec3(0,0,0)];}
        if(which==1) {m=Mesh.init; m.vertices=[Vec3(0,0,-.15),Vec3(0,0,.15)];m.edges=[[0u,1u]];m.faces=[[0u,1u]];}
        if(which==2) foreach(fi;0..m.faces.length) m.setFaceSubpatch(fi,true);
        if(which==3 || which==5) m.setFaceSubpatch(0,true);
        if(which==4) {m.vertices~=Vec3(0,0,2);m.edges~=[4u,9u];}
        if(which==5) m.setFaceHidden(0,true);
        subject.mesh=&m; subject.viewport=vp;
        const scopeData=toolPressSupport(m,ms,vp);
        const expected=which==1?0:which==0?0:4;
        assert(which==1?!scopeData.edges[0]:!scopeData.vertices[expected],"scope-outcome: candidate is genuinely compatibility data");
        int index;
        const result=t.resolveGrabTarget(300,300,vp,index,false,&subject);
        assert(result==(which==1?MoveElem.Edge:MoveElem.Vertex) && index==expected,
            format("scope-outcome: compatibility case%s actual press identity %s/%s",which,result,index));
        ++n;
    }
    assert(n==6,"scope-outcome: six populated compatibility admissions");
    m=makeGridPlane(2); m.resizeFaceSelection();
    // An unrelated marked island cannot broaden a known ordinary interior.
    const first=cast(uint)m.vertices.length;
    m.vertices~=[Vec3(3,0,3),Vec3(4,0,3),Vec3(4,0,4),Vec3(3,0,4)];
    m.faces~=[first,first+1,first+2,first+3];m.resizeFaceSelection();m.setFaceSubpatch(4,true);
    m.rebuildEdgesFromFaces();m.buildLoops();
    const scopeData=toolPressSupport(m,ms,vp);
    assert(scopeData.vertices[4] && !scopeData.faces[4],"scope-island: known interior and remote unknown island coexist");
    int index;
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.None && index==-1,
        "scope-island: unrelated subdivision does not admit back-facing ordinary interior");
}

unittest {
    import toolpipe.packets : SubjectPacket;
    const vp=viewport(); const ms=ModelSpace.world();
    auto t=new TopologyPenTool(); Mesh m; t.meshSrc_=()=>&m;
    SubjectPacket subject; subject.pickFacing=true; subject.pickFacesDrawn=false;
    foreach(edge;[false,true]) {
        m=makeGridPlane(2);
        foreach(ref v;m.vertices) v=point(301+v.x*50,300+(v.z-(edge?.5f:0))*50,vp);
        const id=edge?cast(int)m.edges.length:cast(int)m.vertices.length;
        if(edge) {const first=cast(uint)m.vertices.length;m.vertices~=[point(305,270,vp),point(305,330,vp)];m.edges~=[first,first+1];}
        else m.vertices~=point(305,300,vp);
        const s=toolPressSupport(m,ms,vp);
        assert(edge?!s.edges[id]:!s.vertices[id],"LEGACY_SUBSET: explicit compatibility member in mixed population");
        const primary=ToolPressSource(&m,ms);
        const full=t.legacyPressGather(300,300,vp,false,primary);
        const subset=t.legacyPressGather(300,300,vp,false,primary,s.vertices,s.edges,s.faces);
        assert((edge?full.edge.index:full.vertex.index)!=id && (edge?subset.edge.index:subset.vertex.index)==id,
            edge?"LEGACY_SUBSET_E: actual old full and subset identities differ":"LEGACY_SUBSET_V: actual old full and subset identities differ");
        subject.mesh=&m; subject.viewport=vp;
        int index;
        assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==(edge?MoveElem.Edge:MoveElem.Vertex) && index==id,
            edge?"LEGACY_SUBSET_E: actual press retains compatibility candidate after ordinary refusal":"LEGACY_SUBSET_V: actual press retains compatibility candidate after ordinary refusal");
    }
}

unittest {
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket;
    import bindbc.sdl;
    const vp=viewport(); auto m=makeGridPlane(2); auto secondary=makeGridPlane(64);
    auto t=new TopologyPenTool();t.meshSrc_=()=>&m;
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacing=false;subject.pickFacesDrawn=false;
    VectorStack vts;vts.put(&subject);
    const saved=toolPressSourcesResolver;scope(exit)toolPressSourcesResolver=saved;
    size_t foregroundQueries;
    toolPressSourcesResolver=(){++foregroundQueries;return [ToolPressSource(&m,ModelSpace.world(),11),ToolPressSource(&secondary,ModelSpace.world(),22)];};
    loadSDL();
    SDL_MouseMotionEvent motion;motion.x=300;motion.y=300;
    t.onMouseMotion(motion,vts);
    assert(foregroundQueries==0 && t.hoverGrabElem_==MoveElem.Vertex && t.hoverGrabIndex_==4,
        "LEGACY_HOVER_WIRING: actual unarmed motion uses only legacy primary and no foreground preparation");
    SDL_MouseButtonEvent press;press.button=SDL_BUTTON_LEFT;press.x=300;press.y=300;
    t.onMouseButtonDown(press,vts);
    assert(foregroundQueries==1 && t.moveArmed_ && t.moveElem_==MoveElem.Vertex && t.grabbedVert_==4,
        "PRESS_EVENT_WIRING: actual Move press queries foreground once and authors primary");
    writefln("PRESS-EVENT-BASELINE foreground_queries=1 queried_sources=2 support_preparations=2 idle_foreground_queries=0 idle_support_preparations=0");
}

unittest {
    import toolpipe.packets : SubjectPacket;
    const vp=viewport(); const ms=ModelSpace.world();
    auto t=new TopologyPenTool(); Mesh m; t.meshSrc_=()=>&m;
    SubjectPacket subject; subject.pickFacing=true; subject.pickFacesDrawn=false; subject.viewport=vp;
    size_t population;
    foreach(which;0..3) {
        m=makeGridPlane(2);m.resizeFaceSelection();
        // The shared interior horizontal edge is between faces 0 and 2.
        if(which==0) foreach(fi;0..m.faces.length)m.setFaceSubpatch(fi,true);
        else m.setFaceSubpatch(0,true);
        if(which==2)m.setFaceHidden(0,true);
        int ei=-1;foreach(i,e;m.edges)if((e[0]==3&&e[1]==4)||(e[0]==4&&e[1]==3))ei=cast(int)i;
        const s=toolPressSupport(m,ms,vp);assert(ei>=0 && !s.edges[ei],"scope-edge-outcome: raw mixed edge really belongs to compatibility subset");
        subject.mesh=&m;int index;
        assert(t.resolveGrabTarget(200,300,vp,index,false,&subject)==MoveElem.Edge && index==ei,
            format("scope-edge-outcome: marked/mixed/hidden-support edge%s actual identity %s",which,index));
        ++population;
    }
    assert(population==3,"scope-edge-outcome: three nonempty support contrasts");
    m=Mesh.init;m.vertices=[Vec3(0,0,0)];m.resizeVertexSelection();
    subject.mesh=&m;int index;
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Vertex && index==0,"legacy-hidden: isolated shown control");
    assert(m.setVertexHidden(0,true) && m.isVertexHidden(0),"legacy-hidden: isolated hide is actually applied");
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.None && index==-1,"legacy-hidden: compatibility hidden point refuses press");
    assert(t.resolveGrabTarget(300,300,vp,index,false,null,ToolQueryIntent.legacyHover)==MoveElem.None && index==-1,"legacy-hidden: compatibility hidden point refuses hover");
}


unittest {
    alias Marks = Mesh.Marks;
    import toolpipe.packets : SubjectPacket;
    const vp=viewport();auto t=new TopologyPenTool();Mesh m;t.meshSrc_=()=>&m;
    m.vertices=[Vec3(-.15,0,0),Vec3(.15,0,0)];m.edges=[[0u,1u]];m.resizeEdgeSelection();
    int index;assert(t.resolveGrabTarget(300,300,vp,index,false)==MoveElem.Edge && index==0,"legacy-hidden-edge: shown loose edge positive");
    m.edgeMarks[0]|=Marks.Hide;
    assert(m.isEdgeHidden(0),"legacy-hidden-edge: actual hide population");
    assert(t.resolveGrabTarget(300,300,vp,index,false)==MoveElem.None && index==-1,"legacy-hidden-edge: compatibility hidden edge refuses press");
    assert(t.resolveGrabTarget(300,300,vp,index,false,null,ToolQueryIntent.legacyHover)==MoveElem.None && index==-1,"legacy-hidden-edge: compatibility hidden edge refuses hover");
    m=Mesh.init;m.vertices=[Vec3(-.15,0,0),Vec3(.15,0,0),Vec3(.15,0,.3),Vec3(.15,0,-.3),Vec3(.15,0,.4)];
    m.faces=[[0u,1u,2u],[1u,0u,3u],[0u,1u,4u]];m.rebuildEdgesFromFaces();m.buildLoops();
    SubjectPacket subject;subject.pickFacing=true;subject.pickFacesDrawn=false;subject.mesh=&m;subject.viewport=vp;
    // Force all ordinary face normals away so only raw nonmanifold legacy support admits the shared edge.
    foreach(ref f;m.faces)if(f[0]==1){import std.algorithm : reverse;reverse(f);}
    m.buildLoops();
    const raw=toolPressSupport(m,ModelSpace.world(),vp);int rawEdge=-1;
    foreach(i,e;m.edges)if((e[0]==0&&e[1]==1)||(e[0]==1&&e[1]==0))rawEdge=cast(int)i;
    assert(rawEdge>=0 && raw.edgeFaces[rawEdge]==3 && !raw.edges[rawEdge],"scope-nonmanifold-outcome: real raw three-face support");
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Edge && index==rawEdge,"scope-nonmanifold-outcome: original raw edge survives ordinary back-FACE refusal");
}
