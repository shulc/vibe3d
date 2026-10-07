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
