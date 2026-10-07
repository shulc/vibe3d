module tools.edit.topology_pen.move_protocol_test;
import mesh : Mesh;
import math : Vec3, Viewport, ModelSpace;
import toolpipe.packets : SnapType, SymmetryPacket;
import tools.edit.topology_pen.snap_guide : admitsMoveElement;
import evaluated_move_weld : EvaluatedMoveWeld, searchMoveElement, pairedMoveEnds, moveFaceNormal, MoveElementHit, evaluatedMoveHandle, heldMoveEngages;

private Mesh rig() {
    Mesh m;
    foreach(v;[Vec3(0,0,0),Vec3(0.2,0,0),Vec3(0.2,0.8,0),Vec3(0,0.8,0),
               Vec3(0.7,0.3,0),Vec3(1.2,0.34,0),Vec3(0.9,0.1,0)]) m.addVertex(v);
    m.addFace([0u,1,2,3]); m.addFace([4u,5,6]); m.rebuildEdges(); m.buildLoops(); m.resizeVertexSelection(); m.resizeEdgeSelection(); m.resizeFaceSelection(); m.resizeAllMeshMaps();
    return m;
}
private uint target(ref Mesh m) { return m.edgeIndex(4,5); }
private bool admits(ref Mesh m,SnapType type,int i,const(uint)[] source=[1u,2],
                    bool held=false,bool interior=false,bool backFace=true,
                    const(SymmetryPacket)* sp=null,const(uint)[] marks=null) {
    return admitsMoveElement(m,type,i,source,held,interior,backFace,Vec3(0,0,1),sp,marks);
}
unittest {
    auto m=rig(); const e=target(m);
    assert(m.vertices.length==7 && m.faces.length==2 && e<m.edges.length,"admission population");
    assert(admits(m,SnapType.Edge,e),"same-type edge positive");
    assert(!admits(m,SnapType.Vertex,e),"same-type vertex negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e),"one-polygon positive");
    m.addVertex(Vec3(1,0.8,0)); m.addFace([5u,4,7]); m.rebuildEdges(); m.buildLoops();
    assert(m.edgePolygonCounts()[target(m)]==2,"two-polygon population");
    assert(!admits(m,SnapType.Edge,target(m)),"two-polygon edge negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e),"visible edge positive");
    m.edgeMarks[e]|=Mesh.Marks.Hide;
    assert(!admits(m,SnapType.Edge,e),"hidden edge negative");
}
unittest {
    auto m=rig();
    assert(admits(m,SnapType.Polygon,1),"visible polygon positive");
    m.faceMarks[1]|=Mesh.Marks.Hide;
    assert(m.isFaceHidden(1) && !m.isVertexHidden(4),"polygon hide without derived corner marks");
    assert(!admits(m,SnapType.Polygon,1),"hidden polygon negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e),"unlocked corner positive");
    m.vertexMarks[4]|=Mesh.Marks.Lock;
    assert(!admits(m,SnapType.Edge,e),"locked corner negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e),"unshared corner positive");
    assert(!admits(m,SnapType.Edge,e,[1u,4]),"shared corner negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e),"unmarked corner positive");
    assert(!admits(m,SnapType.Edge,e,[1u,2],false,false,true,null,[4u]),"source-neighbor mark negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e,[1u,2],true,false),"held ordinary positive");
    assert(!admits(m,SnapType.Edge,e,[1u,2],true,true),"held disconnected connectors negative");
    const opposite=m.edgeIndex(0,3);
    assert(admits(m,SnapType.Edge,opposite,[1u,2],true,true),"held paired connectors positive");
}
unittest {
    auto m=rig(); const e=target(m);
    SymmetryPacket sp; sp.pairOf=[-1,-1,-1,-1,-1,-1,-1]; sp.onPlane=new bool[](7);
    assert(admits(m,SnapType.Edge,e,[1u,2],true,false,true,&sp),"held off-plane source positive");
    sp.onPlane[1]=true;
    assert(!admits(m,SnapType.Edge,e,[1u,2],true,false,true,&sp),"held on-plane source negative");
}
unittest {
    auto m=rig(); const e=target(m);
    SymmetryPacket sp; sp.pairOf=[-1,-1,-1,-1,-1,-1,-1]; sp.onPlane=new bool[](7);
    assert(admits(m,SnapType.Edge,e,[1u,2],true,false,true,&sp),"held independent mirror positive");
    sp.pairOf[1]=2; sp.pairOf[2]=1;
    assert(!admits(m,SnapType.Edge,e,[1u,2],true,false,true,&sp),"held own-mirror source negative");
}
unittest {
    auto m=rig(); const e=target(m);
    assert(admits(m,SnapType.Edge,e,[1u,2],false,false,true),"back-face option positive");
    // Flip target winding so its normal points along the incoming ray.
    m.faces[1]=[4u,6,5]; m.buildLoops();
    assert(moveFaceNormal(m,1).z>0,"back-face population");
    assert(!admits(m,SnapType.Edge,e,[1u,2],false,false,false),"back-facing edge negative");
}
unittest {
    auto m=rig();
    m.vertices[6]=m.vertices[4];
    assert(moveFaceNormal(m,1)==Vec3(0,0,0),"zero-area normal must stay zero");
    assert(admits(m,SnapType.Polygon,1,[1u,2],false,false,false),"zero-area facing bypass positive");
}
unittest {
    auto m=rig(); const e=target(m);
    auto pairs=pairedMoveEnds([Vec3(0,0,0),Vec3(0,0.8,0)],[1u,2],m,[5u,4]);
    assert(pairs==[[4u,1],[5u,2]],"direction-dot pairing aligns skew ends");
    auto reverse=pairedMoveEnds([Vec3(0,0.8,0),Vec3(0,0,0)],[1u,2],m,[5u,4]);
    assert(reverse==[[5u,1],[4u,2]],"direction-dot reverse positive");
}
unittest {
    auto m=rig(); auto frame=new EvaluatedMoveWeld(m,[1u,2],false,false);
    frame.freezeSymmetry(null);
    const topologyVersion=m.mutationVersion;
    assert(frame.beginFrame(m,Vec3(0.3,0.4,0)),"first evaluated handle positive");
    assert(m.mutationVersion==topologyVersion,"position-only first frame preserves topology version");
    m.vertices[1]=Vec3(8,8,8);
    const generation=frame.generation;
    assert(!frame.beginFrame(m,Vec3(0.3,0.4,0)),"unchanged handle retains frame");
    assert(m.vertices[1]==Vec3(8,8,8) && frame.generation==generation,"unchanged handle retains geometry and generation");
    assert(frame.beginFrame(m,Vec3(0.4,0.4,0)),"changed handle positive");
    assert(m.vertices[1]==Vec3(0.2,0,0),"changed handle restores unwelded press image");
    assert(m.mutationVersion==topologyVersion,"position-only changed frame preserves topology version");
}

unittest {
    import std.format : format;
    foreach(surface;0..4) {
        Mesh m;
        const swappedSource=surface>=2, swappedTarget=surface%2==1;
        auto a=Vec3(0,0,0),b=Vec3(0,1,0),x=Vec3(-2,-2,-2),y=Vec3(-2,-2,-1);
        foreach(v;[swappedSource?b:a,swappedSource?a:b,
                   swappedTarget?y:x,swappedTarget?x:y,Vec3(3,3,3),Vec3(4,3,3),Vec3(5,4,3)]) m.addVertex(v);
        m.addFace([0u,1,4]); m.addFace([2u,3,5]); m.rebuildEdges(); m.buildLoops();
        const e=m.edgeIndex(2,3);
        assert(m.faces.length==2 && m.vertices.length==7,"connector veto population");
        assert(admits(m,SnapType.Edge,e,[0u,1],true,false),"disconnected geometry positive");
        m.addFace([cast(uint)(surface/2),cast(uint)(2+surface%2),6u]); m.rebuildEdges(); m.buildLoops();
        assert(!admits(m,SnapType.Edge,m.edgeIndex(2,3),[0u,1],true,false),format("connector veto surface[%s] negative",surface));
        m.vertices[2]=swappedTarget?Vec3(1,1,0):Vec3(1,0,0); m.vertices[3]=swappedTarget?Vec3(1,0,0):Vec3(1,1,0);
        assert(admits(m,SnapType.Edge,m.edgeIndex(2,3),[0u,1],true,false),format("connector veto surface[%s] coplanar positive",surface));
    }
}

unittest {
    MoveElementHit hit;
    hit.index=1; hit.point=Vec3(2,3,0); hit.distance=24;
    const raw=Vec3(1,1,0);
    assert(evaluatedMoveHandle(hit,raw)==raw,"RAW engage excludes exact 24px");
    assert(heldMoveEngages(hit),"HANDLE engage includes exact 24px");
    hit.distance=23;
    assert(evaluatedMoveHandle(hit,raw)==hit.point,"RAW engage 23px positive");
    hit.distance=25;
    assert(!heldMoveEngages(hit),"HANDLE engage 25px negative");
    hit.index=-1; hit.distance=0;
    assert(evaluatedMoveHandle(hit,raw)==raw,"RAW absent target negative");
    assert(!heldMoveEngages(hit),"HANDLE absent target negative");
}
unittest {
    auto m=rig(); m.vertices[4]=Vec3(.5,-.5,0);m.vertices[5]=Vec3(.5,.5,0);
    const e=target(m);
    Viewport vp; vp.width=160;vp.height=160;
    vp.view[]=0; vp.proj[]=0;
    foreach(i;[0,5,10,15]) {vp.view[i]=1;vp.proj[i]=1;}
    auto inside=searchMoveElement(m,ModelSpace.init,vp,Vec3(1,0,0),SnapType.Edge,
        (SnapType t,int i)=>i==e);
    assert(inside.index==e && inside.distance==40,"40px gather boundary positive");
    auto outside=searchMoveElement(m,ModelSpace.init,vp,Vec3(1.025,0,0),SnapType.Edge,
        (SnapType t,int i)=>i==e);
    assert(outside.index==-1,"42px gather negative");
    auto vertex=searchMoveElement(m,ModelSpace.init,vp,Vec3(.5,0,0),SnapType.Vertex,
        (SnapType t,int i)=>true);
    assert(vertex.index==-1,"vertex query cannot trigger edge phase");
}
unittest {
    auto m=rig();const e=target(m);
    assert(admits(m,SnapType.Edge,e),"visible endpoint positive");
    m.vertexMarks[4]|=Mesh.Marks.Hide;
    assert(!m.isEdgeHidden(e) && m.isVertexHidden(4),"endpoint hide population without derived edge cache");
    assert(!admits(m,SnapType.Edge,e),"hidden endpoint negative");
}

private Viewport identityMoveViewport() {
    Viewport vp; vp.width=160; vp.height=160;
    vp.view[]=0; vp.proj[]=0;
    foreach(i;[0,5,10,15]) { vp.view[i]=1; vp.proj[i]=1; }
    return vp;
}
unittest {
    Mesh m;
    foreach(v;[Vec3(.5,-.5,0),Vec3(.5,.5,0),Vec3(0,-.5,0),Vec3(0,.5,0)]) m.addVertex(v);
    m.edges=[[0u,1u],[2u,3u]];
    auto vp=identityMoveViewport();
    assert(m.vertices.length==4 && m.edges.length==2,"nearest query population");
    auto hit=searchMoveElement(m,ModelSpace.init,vp,Vec3(.1,0,0),SnapType.Edge,
        (SnapType t,int i)=>true);
    assert(hit.index==1,"nearest search beats enumeration order");
    auto filtered=searchMoveElement(m,ModelSpace.init,vp,Vec3(.1,0,0),SnapType.Edge,
        (SnapType t,int i)=>i==0);
    assert(filtered.index==0,"edge query invokes client admission");
    auto visible=searchMoveElement(m,ModelSpace.init,vp,Vec3(.1,0,0),SnapType.Edge,
        (SnapType t,int i)=>true,(Vec3 p)=>true);
    assert(visible.index==1,"visible query positive");
    auto covered=searchMoveElement(m,ModelSpace.init,vp,Vec3(.1,0,0),SnapType.Edge,
        (SnapType t,int i)=>true,(Vec3 p)=>false);
    assert(covered.index==-1,"covered query invokes visibility admission");
    vp.proj[15]=-1;
    assert(searchMoveElement(m,ModelSpace.init,vp,Vec3(.1,0,0),SnapType.Edge,
        (SnapType t,int i)=>true).index==-1,"behind-camera query rejected");
}
unittest {
    auto m=rig(); auto vp=identityMoveViewport();
    assert(searchMoveElement(m,ModelSpace.init,vp,Vec3(.5,0,0),SnapType.Polygon,
        (SnapType t,int i)=>true).index>=0,"polygon query positive");
    assert(searchMoveElement(m,ModelSpace.init,vp,Vec3(.5,0,0),SnapType.Polygon,
        (SnapType t,int i)=>false).index==-1,"polygon query invokes client admission");
}
unittest {
    import evaluated_move_weld : moveConnectorVeto;
    const a=Vec3(0,0,0),b=Vec3(0,1,0),x=Vec3(-2,-2,-2);
    assert(moveConnectorVeto(a,b,x,Vec3(-2,-2,-1)),"connector veto rejection positive");
    assert(!moveConnectorVeto(a,b,x,Vec3(-2,-2,0)),"connector first-half negative control");
    assert(!moveConnectorVeto(a,b,x,Vec3(-1,-1,-1)),"connector second-half negative control");
}
unittest {
    import evaluated_move_weld : movePolygonNeighbors;
    auto m=rig();
    assert(m.faces.length==2,"polygon neighbor population");
    assert(movePolygonNeighbors(m,0,1),"forward polygon neighbor positive");
    assert(movePolygonNeighbors(m,1,0),"reverse polygon neighbor positive");
    assert(!movePolygonNeighbors(m,0,2),"polygon diagonal is not a neighbor");
}
unittest {
    import std.algorithm : canFind;
    auto m=rig(); SymmetryPacket sp;
    sp.pairOf=[-1,4,5,-1,1,2,-1]; sp.onPlane=new bool[](7); sp.vertSign=[0,1,1,0,-1,-1,0];
    auto frame=new EvaluatedMoveWeld(m,[1u,2u],true,true);
    frame.freezeSymmetry(&sp);
    assert(frame.marked.length==4 && frame.marked.canFind(4u) && frame.marked.canFind(5u),
        "frozen marks include both source mirrors");
    assert(frame.occlusion,"frozen display occlusion option positive");
    sp.pairOf[1]=-1;sp.onPlane[1]=true;sp.vertSign[1]=-1;
    assert(frame.symmetry.pairOf[1]==4,"pairing snapshot is owned");
    assert(!frame.symmetry.onPlane[1],"on-plane snapshot is owned");
    assert(frame.symmetry.vertSign[1]==1,"side-sign snapshot is owned");
    assert(frame.beginFrame(m,Vec3(.1,0,0)) && frame.evaluated && frame.generation==1,
        "first frame records evaluated generation");
    frame.freezeSymmetry(&sp);
    assert(frame.symmetry.pairOf[1]==4,"evaluated frame keeps frozen symmetry");
    assert(frame.beginFrame(m,Vec3(.2,0,0)) && frame.generation==2,
        "changed frame advances generation");
}
unittest {
    import symmetry : writeMovePositions, moveMirrorCenter;
    auto m=rig(); SymmetryPacket sp;
    sp.pairOf=[-1,4,5,-1,1,2,-1]; sp.onPlane=new bool[](7);
    m.vertexMarks[4]|=Mesh.Marks.Hide;
    const hidden=m.vertices[4];
    writeMovePositions(m,&sp,[1u,2u],[Vec3(2,3,0),Vec3(4,5,0)]);
    assert(m.vertices[1]==Vec3(2,3,0) && m.vertices[2]==Vec3(4,5,0),"shared position producer writes both sources");
    assert(m.vertices[5]==Vec3(-4,5,0),"shared position producer writes visible mirror");
    assert(m.vertices[4]==hidden,"shared position producer retains hidden mirror");
    auto vp=identityMoveViewport(); Vec3 center;
    assert(moveMirrorCenter(sp,1,Vec3(.05,.2,0),ModelSpace.init,vp,15,center),"own mirror within configured reach positive");
    assert(center==Vec3(0,.2,0),"own mirror resolves to plane center");
    assert(!moveMirrorCenter(sp,1,Vec3(.2,.2,0),ModelSpace.init,vp,15,center),"own mirror outside configured reach negative");
    sp.pairOf[1]=-1;
    assert(!moveMirrorCenter(sp,1,Vec3(.05,.2,0),ModelSpace.init,vp,15,center),"unpaired source has no mirror center");
}
unittest {
    auto m=rig();auto frame=new EvaluatedMoveWeld(m,[1u,2u],false,false);frame.freezeSymmetry(null);
    assert(frame.beginFrame(m,Vec3(.1,0,0)),"weld frame positive");
    frame.write(m,[Vec3(.7,.3,0),Vec3(1.2,.34,0)],[Vec3(.7,.3,0),Vec3(1.2,.34,0)],false);
    frame.weld(m,[[4u,1u],[5u,2u]]);
    assert(frame.welded && m.vertices.length==5,"evaluated pair weld positive population");
    assert(frame.liveSource==[0u,1u],"kernel permutation alone retains live source neighbors");
    assert(frame.beginFrame(m,Vec3(.2,0,0)),"post-weld next frame positive");
    assert(!frame.welded && m.vertices.length==7,"new frame resets welded status and population");
    assert(m.faces==[[0u,1u,2u,3u],[4u,5u,6u]],"changed frame restores original corner order after weld");
}

unittest {
    import std.algorithm : canFind;
    auto m=rig(); auto frame=new EvaluatedMoveWeld(m,[1u,2u],false,false);
    frame.freezeSymmetry(null);
    assert(frame.marked.length==6 && frame.marked.canFind(0u) && frame.marked.canFind(3u),
        "ordinary edge freeze marks both polygon neighbors");
}
unittest {
    auto m=rig(); SymmetryPacket sp; sp.pairOf=[-1,4,-1,-1,1,-1,-1];sp.onPlane=new bool[](7);
    auto frame=new EvaluatedMoveWeld(m,[1u],false,false);frame.freezeSymmetry(&sp);
    assert(frame.beginFrame(m,Vec3(.6,.1,0)),"lag raw prefix positive");
    frame.write(m,[Vec3(.6,.1,0)],[Vec3(.5,.1,0)],false);
    assert(frame.beginFrame(m,Vec3(.7,.2,0)),"lag snap prefix positive");
    frame.write(m,[Vec3(.7,.2,0)],[Vec3(.7,.2,0)],true);
    import std.math : abs;
    assert(abs(m.vertices[4].x+1.1f)<1e-6 && abs(m.vertices[4].y-.3f)<1e-6,
        "lag formula consumes previous raw frame, not previous constrained points");
}

unittest {
    import evaluated_move_weld : moveEndpointSearch;
    auto m=rig(); const support=m.vertexPolygonCounts();
    assert(support[1]==1,"single-polygon source population");
    assert(moveEndpointSearch(SnapType.Edge,support[1]),"single-polygon edge endpoint search positive");
    m.addVertex(Vec3(.3,-.3,0));m.addFace([0u,1u,7u]);m.rebuildEdges();m.buildLoops();
    assert(m.vertexPolygonCounts()[1]==2,"two-polygon source population");
    assert(!moveEndpointSearch(SnapType.Edge,m.vertexPolygonCounts()[1]),"two-polygon edge endpoint search negative");
    assert(moveEndpointSearch(SnapType.Vertex,2),"vertex endpoint search independent of support");
    assert(!moveEndpointSearch(SnapType.Polygon,1),"polygon has no per-vertex fallback");
}

unittest {
    import tools.edit.topology_pen.tool : TopologyPenTool;
    import toolpipe.packets : SubjectPacket, SnapPacket;
    import operator : VectorStack;
    import bindbc.sdl;
    loadSDL(); SDL_SetModState(cast(SDL_Keymod)0);
    import math : lookAt, perspectiveMatrix, projectToWindowFull;
    import std.math : PI;
    auto m=rig(); Viewport vp; vp.width=800;vp.height=800;vp.eye=Vec3(0,0,5);
    vp.view=lookAt(vp.eye,Vec3(0,0,0),Vec3(0,1,0));
    vp.proj=perspectiveMatrix(PI/2,1,0.1,100);
    auto pen=new TopologyPenTool(); pen.meshSrc_=()=>&m; pen.backFace_=true;
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;
    SnapPacket snap;snap.enabled=true;
    VectorStack stack;stack.put(&subject);stack.put(&snap);
    float x,y,z;assert(projectToWindowFull(m.vertices[1],vp,x,y,z),"move fingerprint source projection positive");
    SDL_MouseButtonEvent down;down.button=SDL_BUTTON_LEFT;down.x=cast(int)x;down.y=cast(int)y;
    assert(pen.onMouseButtonDown(down,stack),"move fingerprint press positive");
    auto image=pen.buildPreparedDeactivate(null);
    assert(image.expectedMoveFrame !is null && image.expectedMoveGeneration==0,
        "move fingerprint captures armed frame before evaluation");
    assert(pen.preparedDeactivateLocalMatches(image),"move fingerprint unchanged positive");
    auto wrong=image;
    wrong.expectedMoveFrame=new EvaluatedMoveWeld(m,[1u],false,false);
    assert(!pen.preparedDeactivateLocalMatches(wrong),"move fingerprint rejects different frame owner");
    assert(image.expectedMoveFrame.beginFrame(m,Vec3(.3,0,0)),"move fingerprint frame evaluation positive");
    assert(!pen.preparedDeactivateLocalMatches(image),"move fingerprint rejects advanced frame generation");
    auto refreshed=pen.buildPreparedDeactivate(null);
    assert(refreshed.expectedMoveGeneration==1 && pen.preparedDeactivateLocalMatches(refreshed),
        "move fingerprint captures current evaluated generation");
    wrong=refreshed;
    wrong.clear();
    assert(wrong.expectedMoveFrame is null && wrong.expectedMoveGeneration==0,
        "cleared move fingerprint releases frame and generation");
    assert(pen.onMouseButtonUp(down,stack),"move fingerprint release positive");
    auto released=pen.buildPreparedDeactivate(null);
    assert(released.expectedMoveFrame is null && released.expectedMoveGeneration==0,
        "released move has no retained frame fingerprint");
    assert(pen.onMouseButtonDown(down,stack),"move fingerprint re-arm positive");
    auto deactivate=pen.buildPreparedDeactivate(null);
    assert(deactivate.expectedMoveFrame !is null,"move deactivation frame population");
    pen.installPreparedDeactivate(deactivate);
    auto installed=pen.buildPreparedDeactivate(null);
    assert(installed.expectedMoveFrame is null && installed.expectedMoveGeneration==0,
        "installed deactivation releases evaluated move frame");
}

unittest {
    import evaluated_move_weld : moveConnectorVeto;
    const a=Vec3(0,0,0),b=Vec3(0,1,0);
    assert(moveConnectorVeto(a,b,Vec3(-2,-2,-2),Vec3(-2,-2,-1)),"connector term population positive");
    assert(!moveConnectorVeto(a,b,Vec3(-8.07214190f,-4.04037330f,-9.30574559f),Vec3(4.90952007f,-9.78107288f,-9.83057532f)),"connector term[0] negative control");
    assert(!moveConnectorVeto(a,b,Vec3(1.12413285f,2.02522104f,-0.46265830f),Vec3(1.17142724f,5.52094268f,-6.76249975f)),"connector term[1] negative control");
    assert(!moveConnectorVeto(a,b,Vec3(0.72051147f,4.96856186f,-4.13775280f),Vec3(-9.09391505f,-8.66845257f,8.34198302f)),"connector term[2] negative control");
    assert(!moveConnectorVeto(a,b,Vec3(4.93318060f,-5.68015795f,-0.40053177f),Vec3(1.10710867f,-1.68013888f,-1.02883487f)),"connector term[3] negative control");
}

unittest {
    Mesh m;
    foreach(v;[Vec3(.1,0,0),Vec3(.4,0,0),Vec3(.4,.8,0),Vec3(.1,.8,0),
        Vec3(-.1,.8,0),Vec3(-.4,.8,0),Vec3(-.4,0,0),Vec3(-.1,0,0),
        Vec3(.8,0,0),Vec3(.8,.8,0),Vec3(1,.4,0),
        Vec3(-.8,0,0),Vec3(-.8,.8,0),Vec3(-1,.4,0)]) m.addVertex(v);
    m.addFace([0u,1,2,3]);m.addFace([4u,5,6,7]);m.addFace([8u,9,10]);m.addFace([11u,12,13]);
    m.rebuildEdges();m.buildLoops();
    SymmetryPacket sp;sp.pairOf=[7,6,5,4,3,2,1,0,11,12,13,8,9,10];sp.onPlane=new bool[](14);
    auto frame=new EvaluatedMoveWeld(m,[1u,2u],true,false);frame.freezeSymmetry(&sp);
    assert(m.vertices.length==14 && m.faces.length==4,"reciprocal weld source and target population");
    assert(frame.beginFrame(m,Vec3(.8,.4,0)),"reciprocal weld frame positive");
    frame.write(m,[Vec3(.8,0,0),Vec3(.8,.8,0)],[Vec3(.8,0,0),Vec3(.8,.8,0)],false);
    frame.weld(m,[[8u,1u],[9u,2u]]);
    assert(frame.welded && m.vertices.length==10 && m.faces.length==4,
        "evaluated weld absorbs source endpoints and both reciprocal partners");
}

import tools.edit.topology_pen.defs : PenMode;

private void ordinaryPolygonMove(PenMode mode,float extent, bool closed = false, uint stale = 0) {
    import tools.edit.topology_pen.tool : TopologyPenTool;
    import toolpipe.packets : SubjectPacket, SnapPacket;
    import operator : VectorStack;
    import bindbc.sdl;
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    loadSDL(); SDL_SetModState(cast(SDL_Keymod)0);
    import display_sync : activeMeshResolver;
    Mesh offscreen;auto savedResolver=activeMeshResolver;activeMeshResolver=()=>&offscreen;
    scope(exit) activeMeshResolver=savedResolver;
    Mesh m;
    foreach(v;[Vec3(2.5,-.5,0),Vec3(2.5,.5,0),Vec3(3,0,0),
        Vec3(-extent,-extent,0),Vec3(extent,-extent,0),Vec3(extent,extent,0),Vec3(-extent,extent,0)]) m.addVertex(v);
    m.addFace([0u,1,2]);m.addFace([3u,4,5,6]);
    if (closed) m.addFace([6u,5,4,3]);
    m.rebuildEdges();m.buildLoops();
    m.resizeVertexSelection();m.resizeEdgeSelection();m.resizeFaceSelection();m.resizeAllMeshMaps();
    Viewport vp;vp.width=800;vp.height=800;vp.eye=Vec3(0,0,5);
    vp.view=lookAt(vp.eye,Vec3(0,0,0),Vec3(0,1,0));vp.proj=perspectiveMatrix(PI/2,1,.1,100);
    import tools.edit.topology_pen.defs : PenMode;
    auto pen=new TopologyPenTool();pen.penMode_=mode;pen.meshSrc_=()=>&m;pen.backFace_=true;
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;subject.pickFacesDrawn=true;
    SnapPacket snap;snap.enabled=true;VectorStack stack;stack.put(&subject);stack.put(&snap);
    SDL_MouseButtonEvent down;down.button=SDL_BUTTON_LEFT;down.x=400;down.y=400;
    assert(pen.onMouseButtonDown(down,stack),"ordinary polygon press consumed");
    assert(pen.moveArmed_ && pen.moveVerts_==[3u,4u,5u,6u],"ordinary polygon press population");
    if (stale) {
        import change_bus : changeBus;
        const before = m.vertices.dup, faces = m.faces.dup;
        const deliveries = changeBus.deliveryCount, topology = m.mutationVersion;
        const image = pen.buildPreparedDeactivate(null);
        if (stale == 1) pen.moveVerts_[0] = 0;
        else if (stale == 2) pen.moveBase_ = pen.moveBase_[0..3];
        else pen.moveBase_[0] = Vec3(9,9,9);
        bool failed;
        try { pen.applyMoveTargets([Vec3(1,0,0),Vec3(2,0,0),Vec3(3,0,0),Vec3(4,0,0)],stack); }
        catch (Throwable) { failed=true; }
        assert(!failed,"missing source mapping must not index incomplete press positions");
        assert(m.vertices==before && m.faces==faces,
            "missing source mapping refuses before geometry writes");
        assert(changeBus.deliveryCount==deliveries && m.mutationVersion==topology,
            "missing source mapping publishes neither Position nor topology");
        const after = pen.buildPreparedDeactivate(null);
        assert(after.expectedMoveGeneration==image.expectedMoveGeneration && !pen.moveDirty_,
            "missing source mapping retains unevaluated recorder state");
        return;
    }
    SDL_MouseMotionEvent motion;motion.x=600;motion.y=400;
    bool failed;
    try { pen.onMouseMotion(motion,stack); } catch(Throwable e) {
        import std.stdio : writeln;writeln("REVIEW-CAUGHT ",e.toString());failed=true;
    }
    assert(!failed,"ordinary polygon movement must not index an absent source side");
    if (closed) {
        assert(m.vertices.length==7 && m.faces.length==3,
            "polygon without border sides remains a free move");
        import std.math : abs;
        foreach (i,vi;[3u,4u,5u,6u])
            assert((m.vertices[vi]-(pen.moveBase_[i]+Vec3(2.5,0,0))).length<1e-5,
                "polygon without side pair writes the complete free frame");
        return;
    }
    assert(m.vertices.length==5 && m.faces.length==2,
        "ordinary polygon side weld absorbs exactly two source corners");
    import std.math : abs;
    const shift=Vec3(2.5f-extent,0,0);
    uint translated;
    foreach(p;m.vertices) if(abs(p.x-(-extent+shift.x))<1e-5 && abs(abs(p.y)-extent)<1e-5) ++translated;
    assert(translated==2,"ordinary polygon non-side corners retain side mean shift");
    auto retained=m.vertices.dup;
    assert(pen.onMouseButtonUp(down,stack),"ordinary polygon release consumed");
    assert(m.vertices==retained,"ordinary polygon release retains last evaluated frame");

}
unittest {
    import tools.edit.topology_pen.defs : PenMode;
    version (PolygonPointOnly) {} else {
        version (PolygonLargeOnly) {} else ordinaryPolygonMove(PenMode.Move,.3f);
        ordinaryPolygonMove(PenMode.Move,1f);
        ordinaryPolygonMove(PenMode.Move,1f,true);
        ordinaryPolygonMove(PenMode.Move,1f,false,1);
        ordinaryPolygonMove(PenMode.Move,1f,false,2);
        ordinaryPolygonMove(PenMode.Move,1f,false,3);
    }
}
unittest {
    import tools.edit.topology_pen.defs : PenMode;
    version (PolygonMoveOnly) {} else {
        version (PolygonLargeOnly) {} else ordinaryPolygonMove(PenMode.Point,.3f);
        ordinaryPolygonMove(PenMode.Point,1f);
        ordinaryPolygonMove(PenMode.Point,1f,true);
        ordinaryPolygonMove(PenMode.Point,1f,false,1);
        ordinaryPolygonMove(PenMode.Point,1f,false,2);
        ordinaryPolygonMove(PenMode.Point,1f,false,3);
    }
}

unittest {
    import evaluated_move_weld : polygonMoveSides;
    Mesh m;
    foreach (v;[Vec3(-2,0,0),Vec3(2,0,0),Vec3(2,.8,0),Vec3(-2,.8,0),
        Vec3(2.5,-.1,0),Vec3(2.5,.9,0),Vec3(3,.4,0)]) m.addVertex(v);
    m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
    uint[2] corners,ends;
    assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(2.5,.4,0),corners,ends),
        "polygon border-side pair positive");
    assert(corners==[1u,2] && ends==[4u,5],
        "polygon side pair minimizes centered endpoint cost with orientation vetoes");
    m.addFace([0u,1,2,3]);m.rebuildEdges();m.buildLoops();
    assert(!polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(2.5,.4,0),corners,ends),
        "polygon source without border sides has no pair");
    m.faces=m.faces[0..2];m.addFace([6u,5,4]);m.rebuildEdges();m.buildLoops();
    assert(!polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(2.5,.4,0),corners,ends),
        "polygon target without border sides has no pair");
    m.faces=m.faces[0..2];m.rebuildEdges();m.buildLoops();
    bool safeNoPair(const(uint)[] source,const(Vec3)[] positions,uint face) {
        try { return !polygonMoveSides(m,source,positions,face,Vec3(2.5,.4,0),corners,ends); }
        catch (Throwable) { return false; }
    }
    assert(safeNoPair([0u,1],m.vertices[0..2],1),
        "polygon side selection rejects an incomplete source outline");
    assert(safeNoPair([0u,1,2,3],m.vertices[0..3],1),
        "polygon side selection rejects incomplete press positions");
    assert(safeNoPair([0u,1,2,3],m.vertices[0..4],3),
        "polygon side selection rejects an absent target polygon");
}

// Unequal endpoint costs and nonplanar adjacent corners independently expose
// both orientation vetoes; reversed stored edges retain the same side geometry.
unittest {
    import evaluated_move_weld : polygonMoveSides;
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,1),Vec3(2,1,0),Vec3(-2,1,0),Vec3(4,0,1),Vec3(2,-1,0),Vec3(3,1,1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "reverse endpoint cost accepted population");
        assert(corners==[3u,0] && ends==[6u,5],
            "polygon reverse endpoint cost retains the accepted minimum pair");
    }
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,1),Vec3(2,1,0),Vec3(-2,1,0),Vec3(4,0,1),Vec3(2,-1,0),Vec3(3,1,1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "handle-centered source side accepted population");
        assert(corners==[3u,0] && ends==[6u,5],
            "polygon handle-centered source side retains the accepted minimum pair");
    }
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,-1),Vec3(2,1,0),Vec3(-2,1,2),Vec3(2,-1,0),Vec3(5,2,2),Vec3(3,-1,-1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "after-corner orientation veto accepted population");
        assert(corners==[3u,0] && ends==[5u,6],
            "polygon after-corner orientation veto retains the accepted minimum pair");
    }
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,-1),Vec3(2,1,0),Vec3(-2,1,0),Vec3(5,1,-2),Vec3(4,2,1),Vec3(2,2,1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "before-corner orientation veto accepted population");
        assert(corners==[2u,3] && ends==[4u,6],
            "polygon before-corner orientation veto retains the accepted minimum pair");
    }
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,-1),Vec3(2,1,0),Vec3(-2,1,2),Vec3(2,-1,0),Vec3(5,2,2),Vec3(3,-1,-1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        foreach (ref edge;m.edges) edge=[edge[1],edge[0]];
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "reversed-side previous neighbor accepted population");
        assert(corners==[0u,3] && ends==[6u,5],
            "polygon reversed-side previous neighbor retains the accepted minimum pair");
    }
    {
        Mesh m;
        foreach (v;[Vec3(-2,-1,0),Vec3(2,-1,-1),Vec3(2,1,0),Vec3(-2,1,0),Vec3(5,1,-2),Vec3(4,2,1),Vec3(2,2,1)]) m.addVertex(v);
        m.addFace([0u,1,2,3]);m.addFace([4u,5,6]);m.rebuildEdges();m.buildLoops();
        foreach (ref edge;m.edges) edge=[edge[1],edge[0]];
        uint[2] corners,ends;
        assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
            "reversed-side next neighbor accepted population");
        assert(corners==[3u,2] && ends==[6u,4],
            "polygon reversed-side next neighbor retains the accepted minimum pair");
    }
}

unittest {
    import evaluated_move_weld : polygonMoveSides;
    Mesh m;
    foreach(v;[Vec3(-1,-1,0),Vec3(1,-1,0),Vec3(1,1,0),Vec3(-1,1,0),
        Vec3(2,-1,0),Vec3(2,1,0),Vec3(4,1,0),Vec3(4,-1,0)]) m.addVertex(v);
    m.addFace([0u,1,2,3]);m.addFace([4u,5,6,7]);m.rebuildEdges();m.buildLoops();
    uint[2] corners,ends;
    assert(polygonMoveSides(m,[0u,1,2,3],m.vertices[0..4],1,Vec3(3,0,0),corners,ends),
        "equal-cost polygon sides have an admitted population");
    assert(corners==[0u,1] && ends==[5u,6],
        "equal-cost polygon sides retain the first accepted pair");
}

// Probe migration: the virtual pointer and the resolved element are deliberately
// separated. Fixed world inputs make both the source slot and local conversion observable.
unittest {
    import tools.edit.topology_pen.tool : TopologyPenTool;
    import tools.edit.topology_pen.defs : MoveElem;
    import document : ItemXform, primaryModelSpaceResolver;
    import snap : setBackgroundSnapSources;
    import math : lookAt, orthographicMatrix, projectToWindowFull;
    import tool : ToolFlag;
    ItemXform xf; xf.pos=Vec3(.3,0,0); xf.scl=Vec3(2,1,1);
    const ms=xf.modelSpace();
    const saved=primaryModelSpaceResolver; scope(exit) primaryModelSpaceResolver=saved;
    primaryModelSpaceResolver=()=>ms;
    Mesh m,bg; m.addVertex(Vec3(.4,0,0)); bg.addVertex(Vec3(3.24,0,0));bg.resizeVertexSelection();
    ItemXform bx; bx.pos=Vec3(-2,0,0);const bs=bx.modelSpace();
    setBackgroundSnapSources([&bg],[bs]);scope(exit)setBackgroundSnapSources(null,null);
    Viewport vp;vp.width=800;vp.height=800;vp.eye=Vec3(0,0,5);
    vp.view=lookAt(vp.eye,Vec3(0,0,0),Vec3(0,1,0));
    vp.proj=orthographicMatrix(2,1,.1,100);
    auto pen=new TopologyPenTool();pen.meshSrc_=()=>&m;
    pen.presetFlags=cast(uint)ToolFlag.NoBackgroundConstraint;
    pen.moveElem_=MoveElem.Vertex;pen.moveVerts_=[0u];pen.moveBase_=[Vec3(.4,0,0)];
    pen.moveAnchor_=Vec3(.4,0,0);pen.moveStartX_=200;pen.moveStartY_=400;
    pen.dragSnap_.enabled=true;pen.dragSnap_.enabledTypes=SnapType.Vertex;
    pen.dragSnap_.innerRangePx=15;pen.dragSnap_.outerRangePx=40;
    float sx,sy,sz;
    assert(projectToWindowFull(Vec3(1.2,0,0),vp,sx,sy,sz) && sx-220>40,
        "resolved center is outside virtual cursor reach");
    auto targets=pen.moveTargets(220,400,vp);
    const answer=pen.buildPreparedDeactivate(null).expectedPlacementSnap;
    assert(answer.snapped && answer.targetSource==1 && answer.targetIndex==0
        && answer.targetType==SnapType.Vertex && (answer.worldPos-Vec3(1.24,0,0)).length<1e-5,
        "resolved center elects and retains transformed background vertex");
    assert(targets.length==1 && (targets[0]-Vec3(.47,0,0)).length<1e-5,
        "resolved center converts retained world answer into primary local target");
    pen.dragSnap_.enabled=false;
    targets=pen.moveTargets(220,400,vp);
    assert(!pen.buildPreparedDeactivate(null).expectedPlacementSnap.snapped
        && (targets[0]-Vec3(.45,0,0)).length<1e-5,
        "resolved center disabled snap keeps raw target");
    pen.dragSnap_.enabled=true;pen.dragSnap_.enabledTypes=SnapType.Edge;
    targets=pen.moveTargets(220,400,vp);
    assert(!pen.buildPreparedDeactivate(null).expectedPlacementSnap.snapped,
        "resolved center refuses a vertex when only edges are enabled");
    pen.dragSnap_.enabledTypes=SnapType.Vertex;m.addVertex(Vec3(.47,0,0));
    setBackgroundSnapSources(null,null);
    targets=pen.moveTargets(220,400,vp);
    const primary=pen.buildPreparedDeactivate(null).expectedPlacementSnap;
    assert(primary.snapped && primary.targetSource==0 && primary.targetIndex==1
        && (primary.worldPos-Vec3(1.24,0,0)).length<1e-5
        && (targets[0]-Vec3(.47,0,0)).length<1e-5,
        "resolved center reaches transformed primary source independently");
}

private void symmetricConfinedFrames(PenMode mode) {
    import tools.edit.topology_pen.tool : TopologyPenTool;
    import toolpipe.packets : SubjectPacket, SnapPacket;
    import operator : VectorStack;
    import bindbc.sdl;
    import math : lookAt, orthographicMatrix;
    import snap : invalidateSnapGrids, g_snapGridBuilds, snapCursor;
    import mesh_dirty : noteMeshChange, g_settledGeomEpochs, g_geomEpochs;
    import change_bus : changeBus, MeshEditScope;
    import display_sync : activeMeshResolver;
    import std.algorithm : canFind;
    import std.math : abs;
    loadSDL();const mods=SDL_GetModState();scope(exit)SDL_SetModState(mods);
    SDL_SetModState(cast(SDL_Keymod)0);
    Mesh offscreen;const savedDisplay=activeMeshResolver;
    activeMeshResolver=()=>&offscreen;scope(exit)activeMeshResolver=savedDisplay;
    const checkpoint=changeBus.meshSubscriberCheckpointForTest();
    scope(exit)changeBus.restoreMeshSubscribersForTest(checkpoint);
    changeBus.onMeshChanged((size_t addr,uint flags) nothrow {noteMeshChange(addr,flags);});
    Mesh m;
    foreach(v;[Vec3(.1,0,0),Vec3(.4,0,0),Vec3(.4,.4,0),Vec3(.1,.4,0),
               Vec3(-.1,.4,0),Vec3(-.4,.4,0),Vec3(-.4,0,0),Vec3(-.1,0,0),
               Vec3(-.35,0,0),Vec3(-.35,-.4,0),Vec3(-.7,-.4,0)]) m.addVertex(v);
    m.addFace([0u,1,2,3]);m.addFace([4u,5,6,7]);m.addFace([8u,9,10]);
    m.rebuildEdges();m.buildLoops();m.resizeVertexSelection();m.resizeEdgeSelection();m.resizeFaceSelection();m.resizeAllMeshMaps();
    SymmetryPacket sp;sp.pairOf=[7,6,5,4,3,2,1,0,-1,-1,-1];sp.onPlane=new bool[](11);
    sp.enabled=true;sp.axisIndex=0;
    Viewport vp;vp.width=800;vp.height=800;vp.eye=Vec3(0,0,5);
    vp.view=lookAt(vp.eye,Vec3(0,0,0),Vec3(0,1,0));vp.proj=orthographicMatrix(2,1,.1,100);
    auto pen=new TopologyPenTool();pen.meshSrc_=()=>&m;pen.backFace_=true;pen.penMode_=mode;
    SubjectPacket subject;subject.mesh=&m;subject.viewport=vp;
    SnapPacket snap;snap.enabled=true;snap.enabledTypes=SnapType.Vertex;snap.innerRangePx=15;
    VectorStack vts;vts.put(&subject);vts.put(&snap);vts.put(&sp);
    SDL_MouseButtonEvent down;down.button=SDL_BUTTON_LEFT;down.x=480;down.y=400;
    assert(pen.onMouseButtonDown(down,vts) && pen.moveArmed_ && pen.moveVerts_==[1u],
        "symmetric frame real press owns one source");
    invalidateSnapGrids();
    assert(pen.resolveSnapTargetVert(320,400,vp)==6,
        "nearer moving partner positive control precedes exclusion");
    assert(pen.resolveSnapTargetVert(320,400,vp,[1u,6u])==8,
        "stationary target control is reachable while nearer partner is excluded");
    const epoch=g_settledGeomEpochs.epochFor(cast(size_t)&m);
    const geom=g_geomEpochs.epochFor(cast(size_t)&m), before=m.vertices.dup;
    SDL_MouseMotionEvent motion;motion.x=520;motion.y=400;motion.state=1;
    assert(pen.onMouseMotion(motion,vts),"symmetric frame real motion consumed");
    auto frame=pen.buildPreparedDeactivate(null).expectedMoveFrame;
    assert(frame !is null && frame.marked.canFind(1u) && frame.marked.canFind(6u)
        && frame.liveSource.canFind(1u) && frame.liveSource.canFind(6u),
        "symmetric frame moving population includes source and partner");
    assert(abs(m.vertices[1].x-.6)<1e-5 && abs(m.vertices[6].x+.6)<1e-5,
        "symmetric frame actual source and partner positions");
    foreach(i,p;before)if(i!=1 && i!=6)assert(m.vertices[i]==p,"symmetric frame preserves stationary vertices");
    assert(g_geomEpochs.epochFor(cast(size_t)&m)!=geom && g_settledGeomEpochs.epochFor(cast(size_t)&m)==epoch,
        "symmetric raw and final publications retain settled epoch");
    assert(pen.resolveSnapTargetVert(320,400,vp,frame.liveSource)==8,
        "symmetric cached query excludes nearer old partner and chooses stationary target");
    const builds=g_snapGridBuilds;
    assert(pen.resolveSnapTargetVert(320,400,vp,frame.liveSource)==8 && g_snapGridBuilds==builds,
        "symmetric same-exclusion query reuses the confined grid");
    motion.x=540;assert(pen.onMouseMotion(motion,vts));
    assert(abs(m.vertices[1].x-.7)<1e-5 && abs(m.vertices[6].x+.7)<1e-5,
        "symmetric repeated frame uses frozen source and partner positions");
    assert(g_settledGeomEpochs.epochFor(cast(size_t)&m)==epoch
        && pen.resolveSnapTargetVert(320,400,vp,frame.liveSource)==8,
        "symmetric repeated frame keeps excluded cached query stable");
    const repeatedBuilds=g_snapGridBuilds;
    assert(pen.resolveSnapTargetVert(320,400,vp,frame.liveSource)==8 && g_snapGridBuilds==repeatedBuilds,
        "symmetric repeated same-exclusion query reuses the confined grid");
    assert(pen.onMouseButtonUp(down,vts),"symmetric frame real release consumed");
    assert(g_settledGeomEpochs.epochFor(cast(size_t)&m)!=epoch,
        "symmetric settlement advances settled epoch");
    const settled=snapCursor(Vec3(-.7,0,0),260,400,vp,m,ModelSpace.init,snap);
    assert(settled.snapped && settled.targetSource==0 && settled.targetIndex==6
        && (settled.worldPos-Vec3(-.7,0,0)).length<1e-5 && g_snapGridBuilds>repeatedBuilds,
        "symmetric settled query rebuilds and reaches moved partner at new position");
}
version (ConfinedPointOnly) {} else unittest { symmetricConfinedFrames(PenMode.Move); }
version (ConfinedMoveOnly) {} else unittest { symmetricConfinedFrames(PenMode.Point); }
