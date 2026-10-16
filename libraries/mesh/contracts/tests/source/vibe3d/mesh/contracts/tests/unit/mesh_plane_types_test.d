module vibe3d.mesh.contracts.tests.unit.mesh_plane_types_test;

import vibe3d.mesh.contracts.mesh_plane_types;

unittest // FaceSource.identity: entry i names old face i, for every i
{
    auto src = FaceSource.identity(5);
    assert(src.oldOfNew.length == 5);
    foreach (i; 0 .. 5) assert(src.oldOfNew[i] == i);
}

unittest // FaceSource.fromOldToNew: -1 (dropped) becomes absent from oldOfNew; a kept index round-trips
{
    // Old faces 0,1,2,3; old face 1 dropped, the rest compact down by one.
    const int[] oldToNew = [0, -1, 1, 2];
    auto src = FaceSource.fromOldToNew(oldToNew, 3);
    assert(src.oldOfNew.length == 3);
    assert(src.oldOfNew[0] == 0, "new face 0 came from old face 0");
    assert(src.oldOfNew[1] == 2, "new face 1 came from old face 2");
    assert(src.oldOfNew[2] == 3, "new face 2 came from old face 3");
}

unittest // VertSource: same two contracts as FaceSource, independently instanced
{
    auto idSrc = VertSource.identity(3);
    assert(idSrc.oldOfNew == [0u, 1u, 2u]);

    const int[] oldToNew = [-1, 0, 1];
    auto src = VertSource.fromOldToNew(oldToNew, 2);
    assert(src.oldOfNew == [1u, 2u]);
}
