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

version (PerspectivePenFocused) {} else unittest {
    import toolpipe.packets : SubjectPacket;
    import std.algorithm : reverse;
    const vp=viewport();auto m=makeGridPlane(2);auto t=new TopologyPenTool();t.meshSrc_=()=>&m;
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacing=true;subject.pickFacesDrawn=false;
    int index;assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.None && index==-1,
        "ordinary-control: captured back-FACE interior refuses before legacy probes");
    foreach(ref f;m.faces)reverse(f);m.buildLoops();
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Vertex && index==4,
        "ordinary-control: captured front-FACE interior admits before legacy probes");
}

version (PerspectivePenFocused) {} else unittest {
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

version(TieFocused) {} else {
// Compatibility observations execute the original c35 helpers with a subset
// callback before reduction; the shared query then consumes their datums.
version (PerspectivePenFocused) {} else unittest {
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

version (PerspectivePenFocused) {} else unittest {
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

version (PerspectivePenFocused) {} else unittest {
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

version (PerspectivePenFocused) {} else unittest {
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

version (PerspectivePenFocused) {} else unittest {
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

version (PerspectivePenFocused) {} else unittest {
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


version (PerspectivePenFocused) {} else unittest {
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
    // All three ordinary face normals point away; raw nonmanifold support retains old eligibility.
    const raw=toolPressSupport(m,ModelSpace.world(),vp);int rawEdge=-1;
    foreach(i,e;m.edges)if((e[0]==0&&e[1]==1)||(e[0]==1&&e[1]==0))rawEdge=cast(int)i;
    assert(rawEdge>=0 && raw.edgeFaces[rawEdge]==3 && !raw.edges[rawEdge],"scope-nonmanifold-outcome: real raw three-face support");
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Edge && index==rawEdge,"scope-nonmanifold-outcome: original raw edge survives ordinary back-FACE refusal");
}

version (PerspectivePenFocused) {} else unittest {
    import document : ItemXform, primaryModelSpaceResolver;
    import toolpipe.packets : SubjectPacket;
    const vp=viewport();ItemXform xf;xf.pos=Vec3(.3,0,.2);xf.rot=Vec3(0,90,0);xf.scl=Vec3(2,3,.5);
    const ms=xf.modelSpace();const saved=primaryModelSpaceResolver;scope(exit)primaryModelSpaceResolver=saved;primaryModelSpaceResolver=()=>ms;
    auto t=new TopologyPenTool();Mesh m;t.meshSrc_=()=>&m;
    const savedSources=toolPressSourcesResolver;scope(exit)toolPressSourcesResolver=savedSources;
    Mesh secondary;secondary.vertices=[point(305,270,vp),point(340,270,vp),point(340,330,vp),point(305,330,vp)];
    secondary.faces=[[0u,1u,2u,3u]];secondary.rebuildEdgesFromFaces();secondary.buildLoops();
    toolPressSourcesResolver=()=>[ToolPressSource(&m,ms,11),ToolPressSource(&secondary,ModelSpace.world(),22)];
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacesDrawn=false;subject.pickFacing=false;
    foreach(edge;[false,true]) {
        m=Mesh.init;
        if(edge){m.vertices=[ms.toLocalPoint(point(297,270,vp)),ms.toLocalPoint(point(297,330,vp))];m.edges=[[0u,1u]];}
        else m.vertices=[ms.toLocalPoint(point(297,300,vp))];
        const primary=ToolPressSource(&m,ms,11);const old=t.legacyPressGather(300,300,vp,false,primary);
        assert(abs((edge?old.distances.edge:old.distances.vertex)-(edge?3.5f:3.5355339f))<1e-4,
            "LEGACY_TRANSFORM_DATUM: original primary ModelSpace projects the final half-pixel datum");
        int index;assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==(edge?MoveElem.Edge:MoveElem.Vertex)&&index==0,
            "LEGACY_TRANSFORM_DATUM: transformed primary beats populated ordinary secondary, preserving bound identity");
        assert(t.resolveGrabTarget(300,300,vp,index,false,null,ToolQueryIntent.legacyHover)==(edge?MoveElem.Edge:MoveElem.Vertex)&&index==0,
            "LEGACY_TRANSFORM_DATUM: transformed primary hover keeps its old datum and identity");
    }
}

version (PerspectivePenFocused) {} else unittest {
    const vp=viewport();Mesh m;m.vertices=[point(297,300,vp),point(303.25f,270,vp),point(303.25f,330,vp)];m.edges=[[1u,2u]];
    auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const primary=ToolPressSource(&m,ModelSpace.world());
    const old=t.legacyPressGather(300,300,vp,false,primary);
    assert(old.vertex.index==0 && old.edge.index==0,"LEGACY_MIDPOINT: nonempty old same-query V/E gather");
    assert(abs(old.distances.vertex-3.5355339f)<1e-4 && abs(old.distances.edgeMid-2.79508497f)<1e-4 && electElement(old.distances)==kCascadeEdge,
        "LEGACY_MIDPOINT: half-pixel midpoint veto differs from integer final cascade");
    int index;assert(t.resolveGrabTarget(300,300,vp,index,false)==MoveElem.Edge && index==0,"LEGACY_MIDPOINT: actual shared query retains old edge identity");
}

version (PerspectivePenFocused) {} else unittest {
    import document : ItemXform, primaryModelSpaceResolver;
    import math : closestPointOnSegmentToRay, dot;
    const vp=viewport();ItemXform xf;xf.rot=Vec3(0,0,45);xf.scl=Vec3(3,.3,.1);const ms=xf.modelSpace();
    const saved=primaryModelSpaceResolver;scope(exit)primaryModelSpaceResolver=saved;primaryModelSpaceResolver=()=>ms;
    Mesh m;m.vertices=[ms.toLocalPoint(Vec3(-.5,-.7,-.2)),ms.toLocalPoint(Vec3(.5,.7,.2))];m.edges=[[0u,1u]];
    Vec3 ro,rd;screenPointToRay(300.5f,305.5f,vp,ro,rd);auto ld=ms.toLocalDir(rd);ld=ld/ld.length;
    const local=closestPointOnSegmentToRay(m.vertices[0],m.vertices[1],ms.toLocalPoint(ro),ld),world=ms.toWorldPoint(local);
    assert(world.y>.09 && local.y<.07,"LEGACY_LOCAL_WORLD_DATUM: actual projected point/depth separates local and world y");
    foreach(w;[Vec3(world.x-.008,.08,world.z-.008),Vec3(world.x+.008,.08,world.z-.008),Vec3(world.x+.008,.08,world.z+.008),Vec3(world.x-.008,.08,world.z+.008)])m.vertices~=ms.toLocalPoint(w);
    m.faces=[[2u,3u,4u,5u]];m.rebuildEdgesFromFaces();m.addEdge(0,1);m.buildLoops();
    auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const old=t.legacyPressGather(300,305,vp,true,ToolPressSource(&m,ms));
    assert(old.edge.index==4,"LEGACY_LOCAL_WORLD_DATUM: original local visibility projects and compares the world point ahead of its cover");
    int index;assert(t.resolveGrabTarget(300,305,vp,index,true)==MoveElem.Edge && index==4,"LEGACY_LOCAL_WORLD_DATUM: actual press preserves admitted edge identity");
    assert(t.resolveGrabTarget(300,305,vp,index,true,null,ToolQueryIntent.legacyHover)==MoveElem.Edge && index==4,"LEGACY_LOCAL_WORLD_DATUM: actual legacy hover preserves admitted edge identity");
}

version (PerspectivePenFocused) {} else unittest {
    const vp=viewport();Mesh m;m.vertices=[Vec3(-.5,0,-.5),Vec3(.5,0,-.5),Vec3(.5,0,.5),Vec3(-.5,0,.5)];
    m.faces=[[0u,3u,2u,1u]];m.rebuildEdgesFromFaces();m.buildLoops();auto t=new TopologyPenTool();t.meshSrc_=()=>&m;
    int index;assert(t.resolveGrabTarget(300,300,vp,index,true,null,ToolQueryIntent.legacyHover)==MoveElem.None && index==-1,
        "LEGACY_GPU_AVAILABILITY: original primary face gather is unavailable without its GPU provider");
}

version (PerspectivePenFocused) {} else unittest {
    import toolpipe.packets : SubjectPacket;
    const vp=viewport();auto t=new TopologyPenTool();Mesh m;t.meshSrc_=()=>&m;
    const saved=toolPressSourcesResolver;scope(exit)toolPressSourcesResolver=saved;toolPressSourcesResolver=()=>cast(ToolPressSource[])null;
    SubjectPacket subject;subject.pickFacing=true;subject.pickFacesDrawn=false;subject.mesh=&m;subject.viewport=vp;
    int index;assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.None,"press-preparation: empty bound primary and absent foreground remain empty");
    m=makeGridPlane(2);
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.None && index==-1,"press-preparation: absent foreground ordinary back-FACE cannot fall through to legacy eligibility");
    m=Mesh.init;m.vertices=[Vec3(0,0,0)];
    assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Vertex && index==0,"press-preparation: c35 primary compatibility eligibility survives absent foreground sources");
}

version (PerspectivePenFocused) {} else unittest {
    import toolpipe.packets : SubjectPacket;
    // Raw face incidence remains authoritative when an input has no edge array.
    const vp=viewport();Mesh m;m.vertices=[Vec3(0,0,0),Vec3(.15,0,-.05),Vec3(.15,0,.05)];m.faces=[[0u],[0u,1u,2u]];
    const s=toolPressSupport(m,ModelSpace.world(),vp);
    assert(m.faces.length==2 && m.edges.length==0 && !s.vertices[0] && s.vertices[1],"scope-all-vertex-raw-faces: earlier short support cannot be overwritten by later ordinary support");
    auto t=new TopologyPenTool();t.meshSrc_=()=>&m;SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacing=true;subject.pickFacesDrawn=false;
    int index;assert(t.resolveGrabTarget(300,300,vp,index,false,&subject)==MoveElem.Vertex && index==0,"scope-all-vertex-raw-faces: actual primary compatibility point survives ordinary back-FACE refusal");
}

}

private Mesh mixedTieRig(bool edge, bool compatibilityFirst, float ordinaryX,
                         float compatibilityX, float y, const ref Viewport vp,
                         out int ordinary, out int compatibility) {
    import std.algorithm : reverse;
    Mesh m;
    if(edge) {
        m.vertices=[point(ordinaryX,270,vp),point(ordinaryX,330,vp),point(ordinaryX+100,330,vp),point(ordinaryX+100,270,vp)];
        m.faces=[[0u,3u,2u,1u]];m.rebuildEdgesFromFaces();m.buildLoops();
        ordinary=-1;
        foreach(i,e;m.edges)if(e==[0u,1u] || e==[1u,0u])ordinary=cast(int)i;
        assert(ordinary>=0,"MIXED_RIG_E: ordinary segment exists");
        m.vertices~=[point(compatibilityX,270,vp),point(compatibilityX,330,vp)];
        if(compatibilityFirst){uint[2][] loose=[[4u,5u]];m.edges=loose~m.edges;++ordinary;compatibility=0;}
        else{compatibility=cast(int)m.edges.length;m.edges~=[4u,5u];}
    } else {
        auto grid=makeGridPlane(2);
        foreach(ref v;grid.vertices)v=point(ordinaryX+v.x*60,y+v.z*60,vp);
        foreach(ref f;grid.faces)reverse(f);
        grid.buildLoops();
        ordinary=4;
        if(compatibilityFirst) {
            m.vertices=[point(compatibilityX,y,vp)]~grid.vertices;
            foreach(f;grid.faces){auto shifted=f.dup;foreach(ref vi;shifted)++vi;m.faces~=shifted;}
            m.rebuildEdgesFromFaces();m.buildLoops();ordinary=5;compatibility=0;
        } else {m=grid;compatibility=cast(int)m.vertices.length;m.vertices~=point(compatibilityX,y,vp);}
    }
    const s=toolPressSupport(m,ModelSpace.world(),vp);
    assert(edge ? s.edges[ordinary]&&!s.edges[compatibility] : s.vertices[ordinary]&&!s.vertices[compatibility],
        "MIXED_RIG: actual ordinary and compatibility populations discriminate");
    return m;
}

version(TieDatum) {} else version(TieTransformed) {} else version (PerspectivePenFocused) {} else unittest {
    import toolpipe.packets : SubjectPacket;
    const vp=viewport();auto t=new TopologyPenTool();Mesh m;t.meshSrc_=()=>&m;
    size_t population;
    version(TieOrdinaryFirst)const orders=[false,true];else const orders=[true,false];
    version(TieReciprocal)const reciprocals=[true,false];else const reciprocals=[false,true];
    foreach(edge;[false,true])if(tieClass(edge))foreach(mode;0..3)foreach(first;orders)foreach(reciprocal;reciprocals) {
        const ox=mode==0?302.0f:reciprocal?297.0f:mode==1?304.0f:303.0f;
        const cx=mode==0?302.0f:reciprocal?(mode==1?304.0f:303.0f):297.0f;
        const y=mode==1?300.5f:300.0f;
        int ordinary,compatibility;m=mixedTieRig(edge,first,ox,cx,y,vp,ordinary,compatibility);
        const s=toolPressSupport(m,ModelSpace.world(),vp);const primary=ToolPressSource(&m,ModelSpace.world());
        const full=t.legacyPressGather(300,300,vp,false,primary);
        const subset=t.legacyPressGather(300,300,vp,false,primary,s.vertices,s.edges,s.faces);
        SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacing=true;subject.pickFacesDrawn=false;
        const now=t.queryPressTarget(300,300,vp,false,&subject);
        float ax,ay,az;const oi=edge?m.edges[ordinary][0]:cast(uint)ordinary;const ci=edge?m.edges[compatibility][0]:cast(uint)compatibility;
        assert(projectToWindowFull(m.vertices[oi],vp,ax,ay,az));const oMetric=edge?abs(ax-300):(ax-300)*(ax-300)+(ay-300)*(ay-300);
        assert(projectToWindowFull(m.vertices[ci],vp,ax,ay,az));const cMetric=edge?abs(ax-300):(ax-300)*(ax-300)+(ay-300)*(ay-300);
        writefln("TIE-PHASE0 class=%s first=%s mode=%s reciprocal=%s ordinary=%s compat=%s full=%s/%s subset=%s/%s metrics=%s/%s current=%s/%s",
            edge?"E":"V",first,mode,reciprocal,ordinary,compatibility,edge?full.edge.index:full.vertex.index,edge?full.distances.edge:full.distances.vertex,
            edge?subset.edge.index:subset.vertex.index,edge?subset.distances.edge:subset.distances.vertex,oMetric,cMetric,now.kind,now.index);
        ++population;
        float[2] op;float[2][2] oe;float px,py,pz;
        if(edge) {
            foreach(j;0..2){assert(projectToWindowFull(m.vertices[m.edges[ordinary][j]],vp,px,py,pz));oe[j]=[px,py];}
        } else {assert(projectToWindowFull(m.vertices[ordinary],vp,px,py,pz));op=[px,py];}
        const ordinaryDistances=pickDistances(300,300,edge?null:&op,edge?&oe:null,false);
        const fd=edge?ordinaryDistances.edge:ordinaryDistances.vertex;
        const cd=edge?subset.distances.edge:subset.distances.vertex;
        assert(mode==2 ? fd!=cd && oMetric==cMetric : fd==cd,
            "MIXED_PREMISE: exact final tie or integer-only tie before outcomes");
        if(mode==1)assert(oMetric!=cMetric,"MIXED_FINAL_ONLY_PREMISE: actual integer metrics differ");
        if(mode==0)assert(oMetric==cMetric,"MIXED_TIE_PREMISE: actual integer metrics coincide");
        const oldTarget=edge?subset.edge:subset.vertex;
        const expected=mode==0?(first?compatibility:ordinary):mode==1?ordinary:reciprocal?compatibility:ordinary;
        assert(now.kind==(edge?kCascadeEdge:kCascadeVertex) && now.index==expected && now.source==0 && now.owner.mesh is &m,
            format("%s_%s_%s: actual query identity %s expected %s",mode==0?"MIXED_TIE":mode==1?"MIXED_FINAL_ONLY_TIE":"MIXED_UNEQUAL",edge?"E":"V",first?"COMPAT_FIRST":"ORDINARY_FIRST",now.index,expected));
        assert(oldTarget.index==compatibility && oldTarget.reductionMetric==cMetric,
            edge?"MIXED_E: actual helper metric transport":"MIXED_V: actual helper metric transport");
        const ordinaryOnly=toolPressAt(300,300,vp,[primary],true,false,false);
        assert(ordinaryOnly.index==ordinary && ordinaryOnly.reductionMetric==oMetric,
            edge?"MIXED_E: actual ordinary metric transport":"MIXED_V: actual ordinary metric transport");

        import operator : VectorStack;
        import bindbc.sdl;
        loadSDL();auto eventTool=new TopologyPenTool();eventTool.meshSrc_=()=>&m;
        import display_sync : activeMeshResolver;
        Mesh offscreen;const savedDisplay=activeMeshResolver;scope(exit)activeMeshResolver=savedDisplay;
        activeMeshResolver=()=>&offscreen;
        VectorStack vts;vts.put(&subject);
        SDL_MouseButtonEvent press;press.button=SDL_BUTTON_LEFT;press.x=300;press.y=300;
        const saved=toolPressSourcesResolver;scope(exit)toolPressSourcesResolver=saved;
        toolPressSourcesResolver=()=>[ToolPressSource(&m,ModelSpace.world())];
        eventTool.onMouseButtonDown(press,vts);
        const selected=edge?m.edges[expected][]:[cast(uint)expected];
        assert(eventTool.moveArmed_ && eventTool.moveVerts_==selected,
            edge?"MIXED_E_MOVE: actual selected endpoints":"MIXED_V_MOVE: actual selected vertex");
        const before=m.vertices.dup;
        SDL_MouseMotionEvent motion;motion.x=340;motion.y=300;motion.state=SDL_BUTTON_LMASK;
        eventTool.onMouseMotion(motion,vts);
        foreach(i,p;before) {
            import std.algorithm : canFind;
            assert((m.vertices[i]!=p)==selected.canFind(cast(uint)i),
                edge?"MIXED_E_MOVE: actual moved subset":"MIXED_V_MOVE: actual moved subset");
        }

    }
    version(TieVertex)assert(population==12,"tie-population: twelve V reciprocal query/Move cells");
    else version(TieEdge)assert(population==12,"tie-population: twelve E reciprocal query/Move cells");
    else assert(population==24,"tie-population: twenty-four reciprocal query/Move cells");
}

private bool tieClass(bool edge) {
    version(TieVertex)return !edge;
    else version(TieEdge)return edge;
    else return true;
}

version (PerspectivePenFocused) {} else unittest {
    const vp=viewport();Mesh m;auto t=new TopologyPenTool();t.meshSrc_=()=>&m;
    float vMetric=123,eMetric=456;
    assert(t.findSourceVertex(300,300,vp,8,null,&vMetric)==-1 && t.findRingSeedEdge(300,300,vp,8,null,&eMetric)==-1,
        "MISSING_METRIC: empty helpers decline");
    import std.math : isNaN;
    assert(isNaN(vMetric) && isNaN(eMetric),"MISSING_METRIC: declined optional outputs explicitly absent");
}

version (PerspectivePenFocused) {} else unittest {
    import document : ItemXform, primaryModelSpaceResolver;
    import toolpipe.packets : SubjectPacket;
    import math : aimSpace;
    const vp=viewport();ItemXform transform;transform.pos=Vec3(.5f,1,-.5f);transform.scl=Vec3(2,4,.5f);
    const ms=transform.modelSpace();const saved=primaryModelSpaceResolver;scope(exit)primaryModelSpaceResolver=saved;
    primaryModelSpaceResolver=()=>ms;
    foreach(edge;[false,true])if(tieClass(edge)) {
        int ordinary,compatibility;auto m=mixedTieRig(edge,true,302,302,300,vp,ordinary,compatibility);
        foreach(ref p;m.vertices)p=ms.toLocalPoint(p);
        auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const primary=ToolPressSource(&m,ms,11);
        const support=toolPressSupport(m,ms,vp);const old=t.legacyPressGather(300,300,vp,false,primary,support.vertices,support.edges,support.faces);
        const ordinaryHit=toolPressAt(300,300,vp,[primary],true,false,false);
        SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacing=true;subject.pickFacesDrawn=false;
        const now=t.queryPressTarget(300,300,vp,false,&subject);
        writefln("TRANSFORMED-TIE class=%s old=%s/%s/%s ordinary=%s/%s final=%s source=%s local0=%s",edge?"E":"V",
            edge?old.edge.index:old.vertex.index,edge?old.distances.edge:old.distances.vertex,edge?old.edge.reductionMetric:old.vertex.reductionMetric,
            ordinaryHit.index,ordinaryHit.reductionMetric,now.index,now.source,m.vertices[0]);
        assert(!ms.isIdentity && ordinaryHit.index==ordinary && ordinaryHit.reductionMetric==(edge?2:4),
            edge?"TRANSFORMED_E: actual composed-local auxiliary metric":"TRANSFORMED_V: actual composed-local auxiliary metric");
        assert((edge?old.edge.reductionMetric:old.vertex.reductionMetric)==ordinaryHit.reductionMetric,
            "TRANSFORMED_TIE: independent producer metrics exactly coincide");
        assert(now.index==compatibility && now.source==0 && now.owner.mesh is &m,
            edge?"TRANSFORMED_E: actual mixed tie identity":"TRANSFORMED_V: actual mixed tie identity");
    }
}

version(TieMixedSource) {} else version (PerspectivePenFocused) {} else unittest {
    import document : ItemXform;
    const vp=viewport();ItemXform translated;translated.pos=Vec3(-.5f,0,0);
    foreach(edge;[false,true])if(tieClass(edge)) {
        Mesh m;const top=edge?270:300,bottom=edge?330:400;
        foreach(x;[402.0f,302.0f])m.vertices~=[point(x,top,vp),point(x,bottom,vp),point(x+100,bottom,vp),point(x+100,top,vp)];
        m.faces=[[0u,1u,2u,3u],[4u,5u,6u,7u]];m.rebuildEdgesFromFaces();m.buildLoops();
        const sources=[ToolPressSource(&m,ModelSpace.world(),11),ToolPressSource(&m,translated.modelSpace(),22)];
        const first=toolPressAt(300,300,vp,sources[0..1],false,false,false);
        const second=toolPressAt(300,300,vp,sources[1..2],false,false,false);
        const both=toolPressAt(300,300,vp,sources,false,false,false);
        assert(first.index>second.index && first.reductionMetric==second.reductionMetric && first.owner.mesh is second.owner.mesh,
            "SOURCE_SLOT_ALIAS: actual different transforms/local indices and integer tie");
        assert(both.source==0 && both.index==first.index && both.owner.layer==11,
            edge?"SOURCE_SLOT_ALIAS_E: earlier source slot retained":"SOURCE_SLOT_ALIAS_V: earlier source slot retained");
        auto other=m;auto distinct=[ToolPressSource(&m,ModelSpace.world(),11),ToolPressSource(&other,ModelSpace.world(),22)];
        foreach(reverse;[false,true]) {
            if(reverse){auto temp=distinct[0];distinct[0]=distinct[1];distinct[1]=temp;}
            const hit=toolPressAt(300,300,vp,distinct,false,false,false);
            assert(hit.source==0 && hit.owner.mesh is distinct[0].mesh && hit.owner.layer==distinct[0].layer,
                "SOURCE_TIE_ORDINARY: actual traversal incumbent in either source order");
        }
    }
}

version (PerspectivePenFocused) {} else unittest {
    import std.math : isNaN;
    const vp=viewport();foreach(edge;[false,true])if(tieClass(edge)) {
        int ordinary,compatibility;auto m=mixedTieRig(edge,true,302,302,300,vp,ordinary,compatibility);
        auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const primary=ToolPressSource(&m,ModelSpace.world(),11);
        const s=toolPressSupport(m,ModelSpace.world(),vp);
        auto old=t.legacyPressGather(300,300,vp,false,primary,s.vertices,s.edges,s.faces);
        if(edge)old.edge.reductionMetric=float.nan;else old.vertex.reductionMetric=float.nan;
        assert(isNaN(edge?old.edge.reductionMetric:old.vertex.reductionMetric),"MISSING_METRIC: controlled provider declares absence");
        ToolPressPolicy policy;policy.sources=[primary];policy.facing=true;policy.legacySource=primary;
        policy.legacy=(const(bool)[] v,const(bool)[] e,const(bool)[] f)=>old;
        const hit=toolPressAt(300,300,vp,policy);
        assert(hit.index==ordinary && hit.source==0,
            edge?"MIXED_TIE_METRIC_ABSENT_E: strict incumbent retained":"MIXED_TIE_METRIC_ABSENT_V: strict incumbent retained");
        // Cross-source exact dual tie: compatibility lower index cannot replace secondary ordinary.
        auto secondary=m;policy.sources=[ToolPressSource(&secondary,ModelSpace.world(),22)];
        old=t.legacyPressGather(300,300,vp,false,primary,s.vertices,s.edges,s.faces,1);
        policy.legacy=(const(bool)[] v,const(bool)[] e,const(bool)[] f)=>old;
        const cross=toolPressAt(300,300,vp,policy);
        assert(cross.index==ordinary && cross.source==0 && cross.owner.mesh is &secondary,
            edge?"SOURCE_TIE_MIXED_E: secondary ordinary retains dual tie":"SOURCE_TIE_MIXED_V: secondary ordinary retains dual tie");
    }
}

version (PerspectivePenFocused) {} else unittest {
    import math : closestOnSegment2D;
    const vp=viewport();int ordinary,compatibility;auto m=mixedTieRig(true,true,303.5f,303.5f,300,vp,ordinary,compatibility);
    m.vertices[4]=point(303.5f,290,vp);m.vertices[5]=point(303.5f,311,vp);
    // V final3.02 is between old/new midpoint sqrt9.25 and3.
    m.vertices~=point(303.52f,300.5f,vp);
    const primary=ToolPressSource(&m,ModelSpace.world(),11);auto t=new TopologyPenTool();t.meshSrc_=()=>&m;
    const support=toolPressSupport(m,ModelSpace.world(),vp);
    const old=t.legacyPressGather(300,300,vp,false,primary,support.vertices,support.edges,support.faces);
    assert(old.edge.reductionMetric==3.5f && old.distances.edge==3 && old.distances.edgeMid==3,
        "MIXED_EDGE_MID_DATUM: actual compatibility projected segment pair");
    ToolPressPolicy policy;policy.sources=[primary];policy.facing=true;policy.legacySource=primary;
    policy.legacy=(const(bool)[] v,const(bool)[] e,const(bool)[] f)=>old;
    const hit=toolPressAt(300,300,vp,policy);
    assert(hit.kind==kCascadeEdge && hit.index==compatibility && hit.reductionMetric==3.5f,
        "MIXED_EDGE_MID_DATUM: winning edge carries its paired midpoint through final election");
}

version (PerspectivePenFocused) {} else unittest {
    const vp=viewport();foreach(edge;[false,true])if(tieClass(edge)) {
        int ordinary,compatibility;auto m=mixedTieRig(edge,true,edge?308.5f:307.5f,edge?308.0f:305.5f,300.5f,vp,ordinary,compatibility);
        if(edge) {
            const base=cast(uint)m.vertices.length;
            foreach(p;[point(250,250,vp),point(350,250,vp),point(350,350,vp),point(250,350,vp)]) {
                auto below=p;below.y=-1;m.vertices~=below;
            }
            m.faces~=[base,base+3,base+2,base+1];
            // Preserve the loose target's original edge slot while adding actual surface support.
            foreach(i;0..4)m.edges~=[base+cast(uint)i,base+cast(uint)((i+1)%4)];m.buildLoops();
        } else {
            foreach(i,ref p;m.vertices)if(i!=compatibility) {
                float x,y,z;assert(projectToWindowFull(p,vp,x,y,z));
                p=point(307.5f+(x-307.5f)/120,300.5f+(y-300.5f)/120,vp);
            }
            const base=cast(uint)m.vertices.length;
            m.vertices~=[point(306.5f,270.5f,vp),point(306.5f,330.5f,vp)];m.edges~=[base,base+1];
        }
        auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const primary=ToolPressSource(&m,ModelSpace.world(),11);
        const support=toolPressSupport(m,ModelSpace.world(),vp);
        const old=t.legacyPressGather(300,300,vp,false,primary,support.vertices,support.edges,support.faces);
        assert(edge?old.distances.edge==7.5f:old.distances.vertex==5 && old.distances.edgeMid==6,
            "MIXED_DISTANCE_PREMISE: supplied winner/paired distances from actual geometry");
        ToolPressPolicy policy;policy.sources=[primary];policy.facing=false;policy.facesDrawn=edge;policy.legacySource=primary;
        policy.legacy=(const(bool)[] v,const(bool)[] e,const(bool)[] f)=>old;
        const incumbent=toolPressAt(300,300,vp,[primary],false,edge,false);
        if(!edge) {
            float x,y,z;assert(projectToWindowFull(incumbent.pointWorld,vp,x,y,z));float[2] p=[x,y];
            const d=pickDistances(300,300,&p,null,false);
            assert(d.vertex>old.distances.edgeMid && old.distances.vertex<old.distances.edgeMid,
                "MIXED_DISTANCE_PREMISE_V: actual incumbent/replacement straddle supplied midpoint");
            writefln("DISTANCE-DATUM-V ordinary_distance=%s replacement=%s midpoint=%s",d.vertex,old.distances.vertex,old.distances.edgeMid);
        }
        const hit=toolPressAt(300,300,vp,policy);
        writefln("DISTANCE-DATUM class=%s ordinary_class=%s ordinary_index=%s compatibility=%s/%s/%s final=%s/%s",edge?"E":"V",
            incumbent.kind,incumbent.index,old.distances.vertex,old.distances.edge,old.distances.edgeMid,hit.kind,hit.index);
        assert(hit.kind==(edge?kCascadeEdge:kCascadeVertex) && hit.index==compatibility,
            edge?"MIXED_DISTANCE_DATUM_E: new edge distance preserves final class":"MIXED_DISTANCE_DATUM_V: new vertex distance avoids midpoint veto");
    }
}

version (PerspectivePenFocused) {} else unittest {
    import std.algorithm : reverse;
    const vp=viewport();foreach(edge;[false,true])if(tieClass(edge))foreach(reversed;[false,true]) {
        Mesh m;const top=edge?270:300,bottom=edge?330:400;
        foreach(i;0..2)m.vertices~=[point(302,top,vp),point(302,bottom,vp),point(402,bottom,vp),point(402,top,vp)];
        m.faces=[[0u,1u,2u,3u],[4u,5u,6u,7u]];m.rebuildEdgesFromFaces();m.buildLoops();
        if(reversed)reverse(m.edges);
        int expected=0;
        if(edge){expected=-1;foreach(i,e;m.edges)if((e==[0u,1u]||e==[1u,0u]||e==[4u,5u]||e==[5u,4u])&&expected<0)expected=cast(int)i;}
        assert(expected>=0,"ORDINARY_TIE: reciprocal original target exists");
        const hit=toolPressAt(300,300,vp,[ToolPressSource(&m,ModelSpace.world())],false,false,false);
        assert(hit.kind==(edge?kCascadeEdge:kCascadeVertex) && hit.index==expected,
            edge?"ORDINARY_TIE_E: original first-array identity":"ORDINARY_TIE_V: original first-array identity");
    }
}

version (PerspectivePenFocused) {} else unittest {
    import std.math : isNaN;
    const vp=viewport();foreach(edge;[false,true])if(tieClass(edge)) {
        int ordinary,compatibility;auto m=mixedTieRig(edge,true,300,300,300,vp,ordinary,compatibility);
        auto t=new TopologyPenTool();t.meshSrc_=()=>&m;const primary=ToolPressSource(&m,ModelSpace.world());
        const support=toolPressSupport(m,ModelSpace.world(),vp);
        auto old=t.legacyPressGather(300,300,vp,false,primary,support.vertices,support.edges,support.faces);
        if(edge)old.edge=ToolPressTarget(old.edge.kind,old.edge.index,old.edge.source,old.edge.pointWorld,old.edge.owner);
        else old.vertex=ToolPressTarget(old.vertex.kind,old.vertex.index,old.vertex.source,old.vertex.pointWorld,old.vertex.owner);
        ToolPressPolicy policy;policy.sources=[primary];policy.facing=true;policy.legacySource=primary;
        policy.legacy=(const(bool)[] v,const(bool)[] e,const(bool)[] f)=>old;
        const hit=toolPressAt(300,300,vp,policy);
        assert(hit.index==ordinary && isNaN(edge?old.edge.reductionMetric:old.vertex.reductionMetric),
            "MISSING_METRIC_DEFAULT: query-only datum absence cannot become a synthetic zero tie");
    }
}

// Shared provider policy reaches the actual pen call, including old fallback.
unittest {
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import toolpipe.stages.constrain : ConstrainStage;
    import toolpipe.packets : ConstrainGeom;
    import snap : setBackgroundSnapSources, backgroundSourcesFull;
    import view : View;
    import math : Orientation, translationMatrix;
    import drag : HandleDrag, DragFrame, DragKind;
    import bvh_pick : SurfaceHit;
    import std.file : readText;
    import std.json : parseJSON;
    auto data=parseJSON(readText("tests/fixtures/topology_pen_session_rig.v3d"))["layers"][1]["mesh"];
    Mesh background;
    foreach(v;data["vertices"].array)background.vertices~=Vec3(cast(float)v[0].floating,cast(float)v[1].floating,cast(float)v[2].floating);
    foreach(f;data["faces"].array){uint[] face;foreach(i;f.array)face~=cast(uint)i.integer;background.faces~=face;}
    assert(background.vertices.length==482&&background.faces.length==512,"PEN_GUIDE_POPULATION: original actual source");
    auto camera=new View(0,0,1152,974);camera.distance=4;camera.focus=Vec3(0,0,0);camera.setFovY(.9026584025557545);
    camera.setOrientation(Orientation.fromBasis(Vec3(.2004414573f,.5011036434f,-.8418541208f),
        Vec3(-.9284766909f,.3713906764f,0),Vec3(.3126567713f,.7816419283f,.5397051410f)));
    const vp=camera.viewport();const h=Vec3(-.1f,.3f,.9486833215f);
    auto saved=g_pipeCtx;scope(exit)g_pipeCtx=saved;
    import constraint : BackgroundSource;
    class CountingConstrain : ConstrainStage {
        size_t queries;
        override bool rayHit(Vec3 org,Vec3 dir,out SurfaceHit hit,const(BackgroundSource)[] sources,bool productPoint=false) {
            ++queries;
            return super.rayHit(org,dir,hit,sources,productPoint);
        }
    }
    auto ctx=new ToolPipeContext();auto cs=new CountingConstrain();ctx.pipeline.add(cs);g_pipeCtx=ctx;
    scope(exit)setBackgroundSnapSources(null,null);
    Mesh foreground;foreground.vertices=[h];
    auto pen=new TopologyPenTool();pen.meshSrc_=()=>&foreground;
    version (GuideCostObservation) {
        import core.memory : GC;
        import std.datetime.stopwatch : StopWatch, AutoStart;
        cs.enabled=true;cs.handle=true;cs.geom=ConstrainGeom.Point;pen.moveAxisLock_=true;
        setBackgroundSnapSources([cast(const(Mesh)*)&background],[ModelSpace.world()]);
        Vec3 off;bool accepted;
        assert(pen.grabOffset(h,70,0,vp,off,accepted));
        cs.queries=0;const allocated=GC.stats().allocatedInCurrentThread;auto clock=StopWatch(AutoStart.yes);
        size_t events;foreach(i;1..36) {assert(pen.grabOffset(h,2*i,0,vp,off,accepted));++events;}
        const elapsed=clock.peek.total!"usecs";const bytes=GC.stats().allocatedInCurrentThread-allocated;
        assert(events==35&&cs.queries==35,"GUIDE_COST_POPULATION: original 35 evaluated events issue 35 surface queries");
        writefln("GUIDE-COST bg_vertices=%s bg_faces=%s events=%s queries=%s bytes=%s elapsed_us=%s final_offset=%s accepted=%s",background.vertices.length,background.faces.length,events,cs.queries,bytes,elapsed,off,accepted);
        return;
    }
    size_t population;
    foreach(which;0..7) {
        cs.enabled=which!=2;cs.handle=which!=3;cs.geom=which==4?ConstrainGeom.Screen:ConstrainGeom.Point;
        pen.moveAxisLock_=which!=1;
        setBackgroundSnapSources(which==5?null:[cast(const(Mesh)*)&background],which==5?null:[ModelSpace.world()]);
        if(which==6) {
            ModelSpace remote;remote.m=translationMatrix(Vec3(30,0,0));remote.mInv=translationMatrix(Vec3(-30,0,0));remote.isIdentity=false;
            setBackgroundSnapSources([cast(const(Mesh)*)&background],[remote]);
        }
        Vec3 off;bool accepted;cs.queries=0;
        assert(pen.grabOffset(h,70,0,vp,off,accepted),"PEN_GUIDE_MAP: actual translator valid");
        assert(cs.queries==(which>=5?2:1),"PEN_GUIDE_QUERY_COUNT: one supported success or preserved recast; failed perspective attempt adds one query");
        if(which==0) {
            assert(accepted&&(off-Vec3(.1082690091f,.2456922878f,-.1127482767f)).length<2e-6f,"PEN_GUIDE_ACCEPTED: actual production provider before election");
        } else {
            HandleDrag grab;grab.press(h,0,0);bool skip;
            auto old=grab.client(70,0,DragFrame(DragKind.viewPlane),vp,skip);
            float x,y,z;Vec3 org,dir;SurfaceHit hit;
            assert(projectToWindowFull(old,vp,x,y,z),"PEN_FALLBACK_PROJECTION: old client valid");
            screenPointToRay(x,y,vp,org,dir);if(cs.rayHit(org,dir,hit,backgroundSourcesFull()))old=hit.point;
            assert(!accepted&&(off-(old-h)).length<2e-6f,
                format("PEN_FALLBACK_%s: ordinary/disabled/handle/geometry/absent/remote retain old recast, got %s expected %s",which,off,old-h));
        }
        ++population;
    }
    assert(population==7,"PEN_GUIDE_POPULATION: positive plus six independent exclusions");
}
