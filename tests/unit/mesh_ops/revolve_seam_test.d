module tests.unit.mesh_ops.revolve_seam_test;
// REVIEW-ONLY round 2 (task 1903 Stage D3): (A) the revolve differential
// HEAD-vs-shipped over `revolveProfileEx`, (B) the transitional-batch nesting
// stands, re-derived by the reviewer after the MAJOR-3 narrowing.
import mesh;
import math;
import mesh_ops.bridge;
import change_bus : changeBus;
import std.format : format;
import std.conv : to;

private string st(ref Mesh m) {
    string s = format("V=%d F=%d E=%d", m.vertices.length, m.faces.length, m.edges.length);
    foreach (i, v; m.vertices) s ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
    foreach (i, f; m.faces)    s ~= format(" f%d%s", i, f.to!string);
    s ~= " fm" ~ m.faceMarks.to!string ~ " vm" ~ m.vertexMarks.to!string;
    foreach (i; 0 .. m.edges.length) s ~= format(" e%d[%d,%d]", i, m.edges[i][0], m.edges[i][1]);
    return s;
}

// A profile of `n` points in the XY plane at radius 1..2, optionally capped
// into a face so the closed-profile arm has real geometry to inherit from.
private Mesh profileMesh(size_t n, bool asFace, bool sub) {
    import std.math : cos, sin, PI;
    Mesh m;
    foreach (k; 0 .. n) {
        float a = 0.4f * PI * cast(float)k / cast(float)(n > 1 ? n - 1 : 1);
        m.addVertex(Vec3(1.0f + 0.5f * cos(a), 0.8f * sin(a), 0.0f));
    }
    if (asFace) {
        uint[] f; foreach (k; 0 .. n) f ~= cast(uint)k;
        m.addFace(f);
        m.resizeSubpatch();
        m.setFaceSubpatch(0, sub);
    }
    m.buildLoops();
    return m;
}

// Task 1903 Stage D3, plan §4.4a: `revolveProfileEx`'s transitional batch is
// scoped to the converted call — the closed-profile arm — and to nothing else.
// Under an outer batch the open-profile arm must NOT nest (it holds no batch)
// while the closed arm must nest exactly once; geometry is identical either
// way. Re-widening the batch over both arms reddens the open cell.
unittest {
    // revolve, per arm — after the MAJOR-3 narrowing the OPEN arm holds no
    // batch, so it must NOT nest; the CLOSED arm must.
    foreach (profileClosed; [false, true]) {
        Mesh.RevolveParams p;
        p.count = 6; p.axis = Vec3(0, 1, 0); p.angle = 6.2831853f;
        Mesh c = profileMesh(4, profileClosed, false);
        Mesh d = profileMesh(4, profileClosed, false);
        uint[] prof = [0u, 1u, 2u, 3u];
        const ulong m0 = changeBus.nestedBatchOpens, e0 = changeBus.deliveryCount;
        const rc = c.revolveProfileEx(prof, profileClosed, p);
        const ulong mA = changeBus.nestedBatchOpens - m0, eA = changeBus.deliveryCount - e0;
        const ulong m1 = changeBus.nestedBatchOpens, e1 = changeBus.deliveryCount;
        size_t rd;
        { auto ed = MeshEditBatch.unrecorded(d, kBridgeEditScope);
          rd = ed.revolveProfileEx(prof, profileClosed, p); ed.close(); }
        const ulong mB = changeBus.nestedBatchOpens - m1, eB = changeBus.deliveryCount - e1;
        assert(rc == rd && st(c) == st(d),
            format("revolve closed=%s geometry differs under an outer batch", profileClosed));
        assert(mA == 0, "bare revolve nests");
        immutable ulong want = profileClosed ? 1UL : 0UL;
        assert(mB == want,
            format("revolve closed=%s under an outer batch nested %d times, expected %d — "
                 ~ "only the CLOSED arm holds the transitional batch (plan §4.4a; task 1903 D3 review); the OPEN arm keeps its per-face commits until stage E2",
                   profileClosed, mB, want));
    }
}
