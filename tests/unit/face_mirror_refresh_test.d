// The face VBO's CPU mirror under the incremental refresh
// (`GpuMesh.refreshFaceDataCpu`, the one CPU half of the full upload and both
// positions refreshes; model M3). A drag frame re-fans only the faces around
// moved vertices and submits the mirror whole, so the mirror must stay
// BIT-identical to a fresh full upload at the same positions — after any
// sequence of partial moves, a reset of the GL names, or a new face layout.
// GL-free: full uploads go through the fake prepared-upload owner.
module tests.unit.face_mirror_refresh_test;

import std.format : format;

import math : Vec3;
import mesh : Mesh;
import mesh_gpu : GpuMesh, GpuUploadOwner, GpuResourceOwner, PreparedGpuUploadToken,
    ValidatedGpuUploadToken, PreparedGpuResourceToken, ValidatedGpuResourceToken;
import tests.unit.vertex_normals_test : hingedPatch;

/// A full upload of `m` into `gpu` through the fake prepared owner.
private void fullUpload(ref GpuMesh gpu, ref Mesh m) {
    auto owner = GpuUploadOwner.fakeForTest(&gpu);
    PreparedGpuUploadToken prepared;
    assert(owner.beginPreparedUpload(m, null, null, null, prepared), "rig: prepared upload refused");
    ValidatedGpuUploadToken validated;
    assert(owner.validatePreparedUpload(prepared, 7, 11, validated), "rig: upload validation refused");
    owner.installPreparedUpload(validated);
}

/// The oracle: a fresh GpuMesh fully uploaded at `m`'s current positions.
private float[] oracleData(ref Mesh m) {
    GpuMesh fresh;
    fullUpload(fresh, m);
    auto d = fresh.refreshFaceDataCpu(m, m.vertices).dup;
    assert(fresh.lastFaceRefresh.faces == 0 && !fresh.lastFaceRefresh.full,
        "oracle: an idle refresh after a full upload must re-fan nothing");
    return d;
}

/// First float where `got` and `want` differ in bits (or in length), or -1.
private ptrdiff_t firstDiff(const(float)[] got, const(float)[] want) {
    if (got.length != want.length) return 0;
    foreach (i; 0 .. want.length) if (got[i] !is want[i]) return cast(ptrdiff_t)i;
    return -1;
}

/// The rig: the hinged patch with face 11 (a quad on the hinge) hidden, so
/// a refresh must also skip a slot-less face.
private Mesh rig() {
    auto m = hingedPatch();
    m.faceMarks = new uint[](m.faces.length);
    m.faceMarks[11] = Mesh.Marks.Hide;
    return m;
}

private void move(ref Mesh m, const uint[] verts, Vec3 d) {
    foreach (v; verts) {
        m.vertices[v].x += d.x;
        m.vertices[v].y += d.y;
        m.vertices[v].z += d.z;
    }
}

unittest { // partial drags: the mirror equals a fresh full upload, bit for bit
    auto m = rig();
    GpuMesh gpu;
    fullUpload(gpu, m);
    // Floor [E4]: 19 visible faces fan to 2·3 + 16·6 + 1·12 = 114 corners.
    immutable size_t floats = gpu.refreshFaceDataCpu(m, m.vertices).length;
    assert(floats == 114 * 9, format("rig: the mirror holds %d floats, expected 114 corners of 9", floats));
    immutable uint[][] subsets = [[7u], [3u, 4u], [21u, 22u], [0u], [28u]];
    immutable Vec3[] deltas = [Vec3(0, 0.3f, 0), Vec3(0.05f, -0.2f, 0.1f), Vec3(0, 0.25f, -0.1f),
                               Vec3(0, 0.4f, 0), Vec3(0, -0.3f, 0.05f)];
    size_t checked;
    foreach (k, sub; subsets) {
        move(m, sub, deltas[k]);
        const data = gpu.refreshFaceDataCpu(m, m.vertices);
        // Path control [E10]: the refresh took the incremental path over a
        // face subset — else this cell cannot witness the dirty set.
        immutable st = gpu.lastFaceRefresh;
        assert(!st.full && st.faces > 0 && st.faces < m.faces.length,
            format("step %d: expected an incremental refresh over a face subset, got full=%s faces=%d",
                   k, st.full, st.faces));
        const want = oracleData(m);
        immutable d = firstDiff(data, want);
        assert(d < 0, format("step %d: mirror float %d (corner %d) is %s, a full upload writes %s",
                             k, d, d / 9, d < 0 ? 0 : data[d], d < 0 ? 0 : want[d]));
        ++checked;
    }
    assert(checked == subsets.length);
}

unittest { // a GL-name reset (destroy) then re-upload: the mirror is rebuilt whole
    auto m = rig();
    GpuMesh gpu;
    fullUpload(gpu, m);
    move(m, [7u], Vec3(0, 0.3f, 0));
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    // Destroy through the resource owner (`takeGpuMeshNames` resets the
    // header, the layout generation back to 0 and the mirror to null) …
    auto res = GpuResourceOwner.fakeForTest(&gpu);
    PreparedGpuResourceToken t;
    assert(res.beginPreparedDestroy(t), "rig: destroy refused");
    ValidatedGpuResourceToken ready;
    assert(res.validatePrepared(t, 7, 11, ready), "rig: destroy validation refused");
    res.installPrepared(ready);
    assert(gpu.faceLayoutGen == 0, "rig: the destroy did not reset the layout generation");
    // … then the same mesh, one vertex moved, uploads again: the new layout
    // reuses generation 1, so only a reset cache keeps the mirror whole.
    move(m, [21u], Vec3(0, 0.2f, 0));
    fullUpload(gpu, m);
    assert(gpu.faceLayoutGen == 1, format("rig: re-upload layout generation %d, expected 1", gpu.faceLayoutGen));
    const data = gpu.refreshFaceDataCpu(m, m.vertices);
    const want = oracleData(m);
    immutable d = firstDiff(data, want);
    assert(d < 0, format("after a destroy + re-upload, mirror float %d is %s, a full upload writes %s",
                         d, d < 0 ? 0 : data[d], d < 0 ? 0 : want[d]));
}

unittest { // a new face layout mid-session (same counts, same arrays): rebuilt whole
    import std.algorithm.mutation : reverse;
    auto m = rig();
    GpuMesh gpu;
    fullUpload(gpu, m);
    move(m, [7u], Vec3(0, 0.3f, 0));
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    // In-place winding flip of face 5: nothing but the layout generation the
    // full upload bumps says the topology moved.
    reverse(m.faces[5]);
    fullUpload(gpu, m);
    assert(gpu.lastFaceRefresh.full, "a full upload must re-fan every face");
    const data = gpu.refreshFaceDataCpu(m, m.vertices);
    const want = oracleData(m);
    immutable d = firstDiff(data, want);
    assert(d < 0, format("after a layout change mid-session, mirror float %d is %s, a full upload writes %s",
                         d, d < 0 ? 0 : data[d], d < 0 ? 0 : want[d]));
}
