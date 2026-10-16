module vibe3d.mesh.edit_replay.mesh_edit_replay_roundtrip_test;
import vibe3d.mesh.core.mesh;
import vibe3d.mesh.edit_log.mesh_edit_delta;
import vibe3d.mesh.edit_replay.mesh_edit_replay : apply, revert;
import vibe3d.mesh.core.mesh_planes : rewriteFaces, FaceSource;
import vibe3d.util.math.math : Vec3;

unittest {
    Mesh m;
    foreach (i; 0 .. 12) m.addVertex(Vec3(i, i % 3, 0));
    foreach (i; 0 .. 4) m.addFace([cast(uint)i*3, cast(uint)i*3+1, cast(uint)i*3+2]);
    m.buildLoops();
    m.syncSelection();
    m.faceMaterial = [11u,22u,33u,44u];
    m.facePart = [51u,52u,53u,54u];
    m.faceSetMask = [1UL,2UL,4UL,8UL];
    m.faceSelectionOrder = [9,8,7,6];
    m.setFaceSubpatch(0, true);
    m.vertexSetMask = [1UL,2UL,4UL,8UL,16UL,32UL,64UL,128UL,256UL,512UL,1024UL,2048UL];
    m.edgeSetMask[edgeKey(8,9)] = 1UL;
    m.addMeshMapOfKind(MapKind.morphAbsolute, "spot");
    m.setMorphValue("spot", 1, Vec3(21,22,23));
    m.setMorphValue("spot", 8, Vec3(31,32,33));
    const beforePos = m.vertices.dup;
    const beforeMaps = m.meshMap("spot").data.dup;
    const beforePresence = m.meshMap("spot").present.dup;
    const beforeSets = m.vertexSetMask.dup;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        m.deleteFacesByMask([true,true,false,false]);
        d = ed.close();
    }
    const afterPos = m.vertices.dup;
    const afterMaps = m.meshMap("spot").data.dup;
    const afterPresence = m.meshMap("spot").present.dup;
    assert(d.log.length > 0 && m.faces.length == 2 && m.vertices.length == 6,
        "free replay fixture has two dropped faces and six dropped vertices");
    d.revert(m);
    assert(m.vertices == beforePos, "free revert restores removed positions and vertex index space");
    assert(m.faces[0] == [0u,1u,2u] && m.faces[1] == [3u,4u,5u],
        "free revert restores both dropped faces in original order");
    assert(m.faceMaterial == [11u,22u,33u,44u] && m.facePart == [51u,52u,53u,54u],
        "free revert restores dropped material and part planes");
    assert(m.faceSetMask == [1UL,2UL,4UL,8UL] && m.faceSelectionOrder == [9,8,7,6] && m.isFaceSubpatch(0),
        "free revert restores dropped set, order and Subpatch planes");
    assert(m.vertexSetMask == beforeSets && (edgeKey(8,9) in m.edgeSetMask) !is null,
        "free revert restores vertex sets and nonempty endpoint registry preimage");
    assert(m.meshMap("spot").data == beforeMaps && m.meshMap("spot").present == beforePresence,
        "free revert restores point values and presence");
    assert(m.loops.length == 12 && m.edgeMapUsable(), "free revert completes loops and edge map");
    d.apply(m);
    assert(m.vertices == afterPos && m.faces.length == 2,
        "free apply repeats the multi-drop geometry");
    assert(m.meshMap("spot").data == afterMaps && m.meshMap("spot").present == afterPresence,
        "free apply repeats point values and presence carry");
    assert(m.loops.length == 6 && m.edgeMapUsable(), "free apply completes loops and edge map");
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.faceMarks[0] = Mesh.Marks.Select | Mesh.Marks.Subpatch;
    m.faceMaterial = [17u]; // the other planes deliberately remain lazy
    m.facePart = [23u];
    m.faceSelectionOrder[0] = 31;
    m.faceSetMask[0] = 41;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        ed.rec.wantsFaceReindex = true;
        uint[][] faces;
        foreach (f; m.faces[2 .. $]) faces ~= f.dup;
        rewriteFaces(m, faces, FaceSource([2u,3u,4u,5u]));
        d = ed.close();
    }
    assert(d.log.length == 1 && d.log[0].kind == MeshOpEntry.Kind.FaceReindex,
        "capture fixture records one opt-in face rewrite");
    const e = d.log[0];
    assert(e.faceSub == [1u,0u], "capture-before-rewrite preserves only the Subpatch bit");
    assert(e.faceMat == [17u,0u], "capture-before-rewrite material includes lazy zero");
    assert(e.facePrt == [23u,0u], "capture-before-rewrite part includes lazy zero");
    assert(e.faceOrd == [31,0], "capture-before-rewrite order is in old face space");
    assert(e.faceSetMsk == [41UL,0UL], "capture-before-rewrite set is in old face space");
    d.revert(m);
    assert(m.faces.length == 6 && m.faceMaterial[0] == 17 && m.facePart[0] == 23,
        "face-reindex restoration doors recover dropped old planes");
    d.apply(m);
    assert(m.faces.length == 4 && m.loops.length == 16,
        "face-reindex restoration doors complete both replay directions");
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.faceMaterial.length = m.faces.length;
    MeshOpEntry e;
    MeshEditDelta d;
    d.scope_ = MeshEditScope.Position | MeshEditScope.Marks;
    e.kind = MeshOpEntry.Kind.SetPos;
    e.vIdx = [0u]; e.posBefore = [m.vertices[0]]; e.posAfter = [Vec3(9,8,7)];
    d.log = [e]; d.apply(m);
    assert(m.vertices[0] == Vec3(9,8,7), "position restoration forward door");
    d.revert(m);
    assert(m.vertices[0] == e.posBefore[0], "position restoration reverse door");

    e = MeshOpEntry.init;
    e.kind = MeshOpEntry.Kind.SelectionDelta;
    e.selDomain = MeshOpEntry.SelDomain.Vertex;
    e.markIdx = [0u]; e.markBefore = [0u]; e.markAfter = [1u];
    d.log = [e]; d.apply(m);
    assert(m.isVertexSelected(0), "selection restoration forward door");
    d.revert(m);
    assert(!m.isVertexSelected(0), "selection restoration reverse door");

    e.kind = MeshOpEntry.Kind.HideDelta;
    e.markIdx = [1u]; d.log = [e];
    const hideEpoch = m.topologyVersion;
    d.apply(m);
    assert(m.isFaceHidden(1), "hide restoration forward door");
    assert(m.topologyVersion - hideEpoch == 1, "stable hide restoration topology epoch door");
    d.revert(m);
    assert(!m.isFaceHidden(1), "hide restoration reverse door");

    e.kind = MeshOpEntry.Kind.MaterialDelta;
    e.markIdx = [0u]; e.markAfter = [71u]; d.log = [e];
    d.apply(m);
    assert(m.faceMaterial[0] == 71, "material restoration forward door");
    d.revert(m);
    assert(m.faceMaterial[0] == 0, "material restoration reverse door");
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    MeshOpEntry e;
    MeshEditDelta d;
    d.scope_ = MeshEditScope.Geometry;
    e.kind = MeshOpEntry.Kind.AddVerts;
    e.vIdx = [8u]; e.pos = [Vec3(4,5,6)];
    d.log = [e]; d.apply(m);
    assert(m.vertices.length == 9 && m.vertices[8] == Vec3(4,5,6), "append-vertices restoration door");
    assert(m.vertexMarks.length == 9 && m.vertexSetMask.length == 9,
        "parallel vertex plane completion door");
    d.revert(m);
    assert(m.vertices.length == 8 && m.vertexMarks.length == 8, "vertex-tail restoration door");

    e = MeshOpEntry.init;
    e.kind = MeshOpEntry.Kind.AddFaces;
    e.fIdx = [FaceIdx.assumeFaceSpace(6)]; e.faceLists = [[0u,1u,2u]];
    d.log = [e]; d.apply(m);
    assert(m.faces.length == 7 && m.faces[6] == [0u,1u,2u], "append-faces restoration door");
    assert(m.faceSetMask.length == 7 && m.faceMaterial.length == 7,
        "parallel face plane completion door");
    d.revert(m);
    assert(m.faces.length == 6 && m.faceSetMask.length == 6, "face-tail restoration door");

    e = MeshOpEntry.init;
    e.kind = MeshOpEntry.Kind.ReshapeFaces;
    e.fIdx = [FaceIdx.assumeFaceSpace(0)];
    e.faceListsBefore = [m.faces[0].dup];
    e.faceListsAfter = [[0u,1u,2u]];
    d.log = [e]; d.apply(m);
    assert(m.faces[0] == [0u,1u,2u], "winding restoration forward door");
    d.revert(m);
    assert(m.faces[0] == e.faceListsBefore[0], "winding restoration reverse door");
}

unittest {
    Mesh m;
    m.vertices = [Vec3(1,2,3), Vec3(4,5,6)];
    m.syncSelection();
    MeshOpEntry e;
    e.kind = MeshOpEntry.Kind.RemoveVerts;
    e.vIdx = [1u]; e.pos = [m.vertices[1]];
    MeshEditDelta d;
    d.log = [e];
    d.apply(m);
    assert(m.vertices == [Vec3(1,2,3)], "standalone tail vertex-removal restoration door");
    d.revert(m);
    assert(m.vertices == [Vec3(1,2,3), Vec3(4,5,6)], "standalone tail vertex-insertion restoration door");
}

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    MeshOpEntry e;
    e.kind = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp = MeshOpEntry.MapOp.Create;
    e.mapName = "weight"; e.mapDim = 1; e.mapDomain = MapDomain.Point;
    e.mapKind = MapKind.vertexWeight;
    e.mapAddr = MeshOpEntry.MapAddressing.DefaultInit;
    MeshEditDelta d;
    d.scope_ = MeshEditScope.Maps;
    d.log = [e]; d.apply(m);
    assert(m.meshMap("weight") !is null, "map registration forward door");
    d.revert(m);
    assert(m.meshMap("weight") is null, "map unregistration reverse door");

    m.addMeshMapOfKind(MapKind.vertexWeight, "weight");
    e.mapOp = MeshOpEntry.MapOp.Values;
    e.mapAddr = MeshOpEntry.MapAddressing.Listed;
    e.mapElemIdx = [0u]; e.mapValsBefore = [0.0f]; e.mapValsAfter = [0.75f];
    d.log = [e]; d.apply(m);
    assert(m.meshMap("weight").data[0] == 0.75f, "map values forward door");
    d.revert(m);
    assert(m.meshMap("weight").data[0] == 0.0f, "map values reverse door");

    e.mapOp = MeshOpEntry.MapOp.Rename; e.mapNameTo = "renamed";
    d.log = [e]; d.apply(m);
    assert(m.meshMap("weight") is null && m.meshMap("renamed") !is null, "map rename forward door");
    d.revert(m);
    assert(m.meshMap("weight") !is null && m.meshMap("renamed") is null, "map rename reverse door");

    m.addMeshMapOfKind(MapKind.vertexWeight, "other");
    e.mapOp = MeshOpEntry.MapOp.Remove; e.mapSlot = 0;
    e.mapAddr = MeshOpEntry.MapAddressing.WholeArray;
    e.mapValsBefore = m.meshMap("weight").data.dup;
    d.log = [e]; d.apply(m);
    assert(m.meshMap("weight") is null && m.meshMaps[0].name == "other", "map unregistration forward door");
    d.revert(m);
    assert(m.meshMaps[0].name == "weight" && m.meshMaps[1].name == "other", "map registration reverse and slot restoration doors");
}

unittest {
    Mesh m = makeCube();
    MeshOpEntry e;
    e.kind = MeshOpEntry.Kind.AddVerts;
    e.vIdx = [8u]; e.pos = [Vec3(4,5,6)];
    MeshEditDelta d;
    d.log = [e]; // no Geometry scope: the slow completion owes its original extra epoch
    const before = m.topologyVersion;
    d.apply(m);
    assert(m.topologyVersion - before == 2, "slow restoration topology epoch door");
}
