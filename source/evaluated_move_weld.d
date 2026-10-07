module evaluated_move_weld;

import mesh : Mesh, MeshEditBatch;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshOpEntry;
import change_bus : MeshEditScope;
import math : Vec3, Viewport, ModelSpace, dot, cross;
import toolpipe.packets : SnapType, SymmetryPacket;
import symmetry : symmetricWeldPairs, writeMovePositions, mirrorPosition, moveMirrorCenter;

// 9504: a frame searches the live welded subject, then evaluates against its
// unwelded press image. Kernel reindex records preserve source identity without
// duplicating compaction. An unchanged handle and release retain the last frame.
final class EvaluatedMoveWeld {
    private MeshSnapshot basis_;
    private uint[] source_, liveSource_, marked_;
    private bool interior_, occlusion_;
    private Vec3[] previous_, lagged_, points_;
    private bool snapped_;
    private SymmetryPacket symmetry_;
    private Vec3 handle_;
    private bool evaluated_;
    private bool welded_;
    private ulong generation_;

    this(ref Mesh mesh, const(uint)[] source, bool interior, bool occlusion) {
        interior_=interior; occlusion_=occlusion;
        basis_ = MeshSnapshot.capture(mesh);
        source_ = source.dup;
        foreach(vi;source_) previous_~=mesh.vertices[vi];
        liveSource_ = source.dup;
    }
    bool occlusion() const nothrow @nogc { return occlusion_; }
    ulong generation() const nothrow @nogc { return generation_; }
    bool evaluated() const nothrow @nogc { return evaluated_; }
    bool welded() const nothrow @nogc { return welded_; }
    const(uint)[] liveSource() const { return liveSource_; }
    void freezeSymmetry(SymmetryPacket* symmetry) {
        if (evaluated_) return;
        if(symmetry is null) { markSources(); return; }
        symmetry_ = *symmetry;
        symmetry_.pairOf = symmetry.pairOf.dup;
        symmetry_.onPlane = symmetry.onPlane.dup;
        symmetry_.vertSign = symmetry.vertSign.dup;
        markSources();
    }
    const(uint)[] marked() const { return marked_; }
    private void markSources() {
        marked_=source_.dup;
        foreach(vi;source_) if(vi<symmetry_.pairOf.length && symmetry_.pairOf[vi]>=0)
            marked_~=cast(uint)symmetry_.pairOf[vi];
        auto seeds=marked_.dup;
        if(!interior_ && source_.length>1) foreach(face;basis_.faces) foreach(i,vi;face) foreach(seed;seeds)
            if(vi==seed) marked_~=[face[(i+1)%face.length],face[(i+face.length-1)%face.length]];
        liveSource_=marked_.dup;
    }
    SymmetryPacket* symmetry() { return &symmetry_; }
    bool beginFrame(ref Mesh mesh, Vec3 handle) {
        if (evaluated_ && handle == handle_) return false;
        handle_ = handle;
        basis_.restore(mesh);
        liveSource_ = marked_.dup;
        welded_ = false;
        evaluated_ = true;
        ++generation_;
        return true;
    }
    bool mirrorCenter(Vec3 point,ModelSpace space,const ref Viewport view,
            float reach,ref Vec3 handle) {
        return source_.length==1 && moveMirrorCenter(symmetry_,source_[0],point,space,view,reach,handle);
    }
    void write(ref Mesh mesh,const(Vec3)[] raw,const(Vec3)[] points,bool snapped) {
        if(source_.length==1 && symmetry_.pairOf.length==mesh.vertices.length) {
            if(snapped && !snapped_) {
                lagged_=[mirrorPosition(symmetry_,previous_[0])
                    + (mirrorPosition(symmetry_,points[0])-mirrorPosition(symmetry_,basis_.vertices[source_[0]]))];
            }
            if(!snapped) lagged_=null;
        } else lagged_=null;
        points_=points.dup;
        writeMovePositions(mesh,&symmetry_,source_,points,lagged_);
        previous_=raw.dup;
        snapped_=snapped;
    }
    Vec3 offset() const { return points_.length ? points_[0]-basis_.vertices[source_[0]] : Vec3(0,0,0); }
    void weld(ref Mesh mesh, const(uint[2])[] pairs) {
        if (pairs.length == 0) return;
        uint[2][] expanded;
        foreach (p; pairs) expanded ~= symmetricWeldPairs(mesh, &symmetry_, p[0], p[1]);
        auto edit = MeshEditBatch(mesh, MeshEditScope.Geometry | MeshEditScope.Marks);
        welded_ = edit.weldVertexPairs(expanded) != 0;
        auto delta = edit.close();
        uint[] retained;
        foreach(vi;liveSource_) {
            bool absorbed;
            foreach(p;expanded) if(p[1]==vi) absorbed=true;
            if(!absorbed) retained~=vi;
        }
        liveSource_=retained;
        foreach (entry; delta.log) if (entry.kind == MeshOpEntry.Kind.Reindex) {
            uint[] survivors;
            foreach (vi; liveSource_)
                if (vi < entry.perm.length && entry.perm[vi] != ~0u)
                    survivors ~= entry.perm[vi];
            liveSource_ = survivors;
        }
    }
}

struct MoveElementHit {
    int index = -1;
    uint[2] side;
    Vec3 point;
    float distance = float.infinity;
}

Vec3 evaluatedMoveHandle(MoveElementHit hit,Vec3 raw) {
    return hit.index>=0 && hit.distance<24 ? hit.point : raw;
}
bool heldMoveEngages(MoveElementHit hit) {
    return hit.index>=0 && hit.distance<=24;
}

MoveElementHit searchMoveElement(ref Mesh mesh, ModelSpace space,
        const ref Viewport view, Vec3 at, SnapType type,
        scope bool delegate(SnapType, int) admit,
        scope bool delegate(Vec3) shown = null, Vec3 offset = Vec3(0,0,0)) {
    MoveElementHit best;
    // Compare distances before float window-coordinate rounding. Keep the raw
    // anchor and displacement separate at the strict 24px boundary (K-EE_1b).
    bool project(Vec3 p, Vec3 delta, out double x, out double y) {
        double[4] local=[cast(double)p.x+delta.x,cast(double)p.y+delta.y,cast(double)p.z+delta.z,1];
        double[4] world=0, eye=0, clip=0;
        foreach(r;0..4) foreach(c;0..4) world[r]+=cast(double)space.m[c*4+r]*local[c];
        foreach(r;0..4) foreach(c;0..4) eye[r]+=cast(double)view.view[c*4+r]*world[c];
        foreach(r;0..4) foreach(c;0..4) clip[r]+=cast(double)view.proj[c*4+r]*eye[c];
        if(!(clip[3]>0)) return false;
        x=(clip[0]/clip[3]*0.5+0.5)*view.width+view.x;
        y=(0.5-clip[1]/clip[3]*0.5)*view.height+view.y;
        return true;
    }
    double sx,sy;
    if (!project(at,offset,sx,sy)) return best;
    void side(uint a, uint b, int index) {
        double ax,ay,bx,by;
        if(!project(mesh.vertices[a],Vec3(0,0,0),ax,ay)
            || !project(mesh.vertices[b],Vec3(0,0,0),bx,by)) return;
        const dx=bx-ax,dy=by-ay,length2=dx*dx+dy*dy;
        import std.algorithm : clamp;
        import std.math : sqrt;
        const ratio=length2>0 ? clamp(((sx-ax)*dx+(sy-ay)*dy)/length2,0.0,1.0) : 0.0;
        const px=sx-(ax+ratio*dx),py=sy-(ay+ratio*dy);
        const distance=sqrt(px*px+py*py);
        const point=mesh.vertices[a] + (mesh.vertices[b]-mesh.vertices[a])*cast(float)ratio;
        if (shown !is null && !shown(point)) return;
        if (distance < best.distance && distance <= 40) {
            best.index = index; best.side = [a,b]; best.distance = cast(float)distance;
            best.point = mesh.vertices[a] + (mesh.vertices[b] - mesh.vertices[a]) * ratio;
        }
    }
    if (type == SnapType.Edge) {
        foreach (i, edge; mesh.edges)
            if (admit(type, cast(int)i)) side(edge[0], edge[1], cast(int)i);
    } else if (type == SnapType.Polygon) {
        foreach (i, face; mesh.faces) {
            if (!admit(type, cast(int)i)) continue;
            foreach (j, a; face) side(a, face[(j+1)%face.length], cast(int)i);
        }
    }
    return best;
}

uint[2][] pairedMoveEnds(const(Vec3)[] sourcePositions, uint[2] sourceSide,
        ref Mesh mesh, uint[2] targetSide) {
    if (dot(sourcePositions[1] - sourcePositions[0],
            mesh.vertices[targetSide[1]] - mesh.vertices[targetSide[0]]) < 0)
        targetSide = [targetSide[1], targetSide[0]];
    return [[targetSide[0],sourceSide[0]], [targetSide[1],sourceSide[1]]];
}

// The native facing predicate bypasses a zero normal. Mesh.faceNormal's
// display fallback (0,1,0) would reject a collapsed evaluated face.
Vec3 moveFaceNormal(ref Mesh mesh,uint fi) {
    Vec3 n=Vec3(0,0,0);
    auto face=mesh.faces[fi];
    foreach(i,vi;face) {
        auto a=mesh.vertices[vi], b=mesh.vertices[face[(i+1)%face.length]];
        n=n+Vec3((a.y-b.y)*(a.z+b.z),(a.z-b.z)*(a.x+b.x),(a.x-b.x)*(a.y+b.y));
    }
    const length=n.length;
    return length>0 ? n*(1.0f/length) : n;
}

// 10810: the four connector-conditioned veto blocks have the same cross-normal
// operands after ordering the connected source/target endpoint first.
bool movePolygonNeighbors(ref Mesh mesh,uint a,uint b) {
    foreach(face;mesh.faces) foreach(i,v;face)
        if((v==a && face[(i+1)%face.length]==b)
            || (v==b && face[(i+1)%face.length]==a)) return true;
    return false;
}
bool moveConnectorVeto(Vec3 a,Vec3 b,Vec3 x,Vec3 y) {
    Vec3 normal(Vec3 p,Vec3 q,Vec3 r) {
        const v=cross(q-p,r-p), length=v.length;
        return length>0 ? v*(1.0f/length) : v;
    }
    const first=dot(normal(y,a,b),normal(x,b,y))<0
        && dot(normal(x,a,b),normal(y,b,x))>=0;
    const second=dot(normal(x,b,a),normal(y,a,x))<0
        && dot(normal(y,b,a),normal(x,a,y))>=0;
    return first && second;
}
bool moveConnectedGeometryAdmits(ref Mesh mesh,const(uint)[] source,uint[2] target) {
    if(source.length!=2) return false;
    foreach(ends;[[0u,0u],[0u,1u],[1u,0u],[1u,1u]]) {
        const a=source[ends[0]],b=source[1-ends[0]];
        const x=target[ends[1]],y=target[1-ends[1]];
        if(movePolygonNeighbors(mesh,a,x)
            && moveConnectorVeto(mesh.vertices[a],mesh.vertices[b],mesh.vertices[x],mesh.vertices[y])) return false;
    }
    return true;
}
