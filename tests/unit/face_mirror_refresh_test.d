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
    // The destroy drops the incremental cache with the mirror it describes:
    // generation 1 comes back on re-upload, so a kept cache would pass its
    // stamp and patch a few faces into an empty mirror.
    assert(!gpu.lastFaceRefresh.cached, "a destroy must drop the incremental smooth cache");
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

unittest { // a degenerate face's corners carry the (0,1,0) fallback in BOTH streams
    // The differential cells above compare the writer with itself, so they
    // cannot see the fallback; this cell pins it absolutely. The quad's
    // first three corners are collinear (`faceNormalFirst3` is degenerate).
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(1, 1, 0)];
    m.faces ~= [0u, 1, 2, 3];
    GpuMesh gpu;
    fullUpload(gpu, m);
    const data = gpu.refreshFaceDataCpu(m, m.vertices);
    assert(data.length == 6 * 9, format("rig: the quad fans to %d floats, expected 6 corners of 9", data.length));
    foreach (c; 0 .. 6)
        foreach (k; 3 .. 9)
            assert(data[c * 9 + k] == (k % 3 == 1 ? 1.0f : 0.0f),
                format("corner %d: %s normal %s, expected the (0,1,0) fallback", c,
                       k < 6 ? "flat" : "smooth", data[c * 9 + (k < 6 ? 3 : 6) .. c * 9 + (k < 6 ? 6 : 9)]));
}

unittest { // the fan law: (f0, fi, fi+1) per triangle, positions and the face normal in order
    // Absolute, like the fallback cell: the differential cells cannot see a
    // reordered fan (the oracle shares the writer). A CCW unit quad in XY.
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    m.faces ~= [0u, 1, 2, 3];
    GpuMesh gpu;
    fullUpload(gpu, m);
    const data = gpu.refreshFaceDataCpu(m, m.vertices);
    immutable uint[6] order = [0, 1, 2, 0, 2, 3];
    assert(data.length == order.length * 9,
        format("rig: the quad fans to %d floats, expected 6 corners of 9", data.length));
    foreach (c, v; order) {
        immutable Vec3 p = Vec3(data[c * 9], data[c * 9 + 1], data[c * 9 + 2]);
        assert(p == m.vertices[v], format("fan corner %d is %s, the fan (f0, fi, fi+1) puts vertex %d (%s) there",
                                          c, p, v, m.vertices[v]));
        assert(data[c * 9 + 3 .. c * 9 + 6] == [0.0f, 0.0f, 1.0f],
            format("fan corner %d: flat normal %s, a CCW quad in XY faces +Z", c, data[c * 9 + 3 .. c * 9 + 6]));
    }
}

unittest { // the submit decision: an idle refresh submits nothing; a fan-out write forces a whole submit
    import mesh_gpu : DisplayPayloadWriter;
    auto m = rig();
    GpuMesh gpu;
    fullUpload(gpu, m);
    // Idle after a full upload: the VBO already holds the mirror.
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    assert(!gpu.faceMirrorSubmitNeeded(), "an idle refresh must submit no face data");
    // A moved vertex: the patched mirror must reach the VBO.
    move(m, [7u], Vec3(0, 0.2f, 0));
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    assert(gpu.faceMirrorSubmitNeeded(), "a refresh that re-fanned faces must submit the mirror");
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    assert(!gpu.faceMirrorSubmitNeeded(), "the idle refresh after a drag frame must submit nothing");
    // The GPU fan-out wrote the VBO behind the mirror: the next CPU refresh,
    // idle as it is, re-fans and submits every face.
    gpu.noteFaceVboFannedOut();
    assert(gpu.displayPayload.writer == DisplayPayloadWriter.gpuFanOut,
        "the fan-out write must be recorded as the payload's writer");
    cast(void)gpu.refreshFaceDataCpu(m, m.vertices);
    assert(gpu.lastFaceRefresh.full && gpu.faceMirrorSubmitNeeded(),
        "after a fan-out write an idle CPU refresh must re-fan and submit every face "
        ~ "(the VBO no longer holds the mirror)");
    assert(firstDiff(gpu.refreshFaceDataCpu(m, m.vertices), oracleData(m)) < 0,
        "after a fan-out write the mirror must equal a fresh full upload");
}
