module mesh_edit_log_protocol_test;
import mesh_edit_delta;
import vibe3d.mesh.contracts.mesh_types;
import vibe3d.mesh.contracts.mesh_plane_types;
import math : Vec3;

unittest {
    MeshEditTracker t;
    t.declare(MeshEditScope.Position);
    t.recordAddVert(0, Vec3(1,2,3));
    auto c = t.checkpoint();
    t.recordAddVert(1, Vec3(4,5,6));
    t.declare(MeshEditScope.Geometry);
    t.wantsFaceReindex = true;
    t.restore(c);
    auto d = t.finish();
    assert(d.log.length == 1, "accepted-prefix vertex entry population");
    assert(d.log[0].pos.length == 1 && d.log[0].pos[0] == Vec3(1,2,3),
        "accepted-prefix AddVerts tail restored");
    assert(d.scope_ == MeshEditScope.Position && !t.wantsFaceReindex,
        "accepted-prefix scope and face-reindex latch restored");
}

unittest {
    MeshEditTracker t;
    t.recordAddFace(FaceIdx.assumeFaceSpace(0), [0u,1u,2u]);
    auto c = t.checkpoint();
    t.recordAddFace(FaceIdx.assumeFaceSpace(1), [2u,3u,0u]);
    t.restore(c);
    auto d = t.finish();
    assert(d.log.length == 1, "accepted-prefix face entry population");
    assert(d.log[0].faceLists.length == 1 && d.log[0].faceLists[0] == [0u,1u,2u],
        "accepted-prefix AddFaces tail restored");
    FaceReindexRecord payload;
    payload.oldFaceCount = 1;
    assert(!t.wantsFaceReindex && MapKind.creaseWeight != MapKind.unclassified,
        "pure recorder nominal payload positive control");
}
