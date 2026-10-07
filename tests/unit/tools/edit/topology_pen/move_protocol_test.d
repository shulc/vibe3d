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
    m.setFaceHidden(1,true);
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
    assert(frame.beginFrame(m,Vec3(0.3,0.4,0)),"first evaluated handle positive");
    m.vertices[1]=Vec3(8,8,8);
    const generation=frame.generation;
    assert(!frame.beginFrame(m,Vec3(0.3,0.4,0)),"unchanged handle retains frame");
    assert(m.vertices[1]==Vec3(8,8,8) && frame.generation==generation,"unchanged handle retains geometry and generation");
    assert(frame.beginFrame(m,Vec3(0.4,0.4,0)),"changed handle positive");
    assert(m.vertices[1]==Vec3(0.2,0,0),"changed handle restores unwelded press image");
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
