module tests.unit.mesh_ops.revolve_seam_test;
// The COMMIT SEAM of the revolve family, per profile arm (task 1903 Stage E2,
// `doc/mesh_edit_seam_plan.md` §4.1, §4.4a, §3.2 L2).
//
// WHAT THIS FILE USED TO SAY, AND WHY THAT LAW IS GONE. Stage D3 converted the
// Bridge family while `revolveProfileEx` was still a `mixin` inside
// `struct Mesh`, so the kernel had to open a TRANSITIONAL `MeshEditBatch` of
// its own around the one arm that calls `bridgeLoopsPaired` — the CLOSED
// profile. D3's review narrowed it to that arm alone (MAJOR-3), and this file
// pinned the resulting asymmetry: under an outer batch the closed arm nested
// exactly once and the open arm not at all, because the open arm held no batch
// and kept committing once per `addFace`.
//
// E2 removes the transitional block. The kernel takes `ref MeshEditBatch` and
// the CALLERS open it — `commands/mesh/sweep.d`, `RadialSweepTool`'s three
// sites, `commands/mesh/stroke_extrude.d`, `StrokeExtrudeTool`'s drag frame.
// So "the closed arm nests, the open arm does not" is no longer true of either
// arm: there is ONE batch, it belongs to the caller, and nothing inside opens a
// second. That is the law below, and it is asserted for BOTH profile kinds
// because the open one is the arm that changed.
//
// THE COUNTER THIS FILE HAD TO WAKE UP. `changeBus.unbatchedGeometryCommits`
// is gated by `mesh.g_isDocumentMesh`, which reads UNINSTALLED as "not a
// document mesh" — so in the unit lane it never ticks and every `== 0` on it is
// vacuous in both directions (its own declaration in change_bus.d says so).
// This file installs the predicate against its own heap-allocated meshes,
// exactly as the 1330/1333/1361 derive-count block in `source/mesh.d` does, and
// carries a POSITIVE CONTROL — a bare `addFace` on a second such mesh — that
// makes the same counter move before anything asserts it did not.
//
// THE MUTATIONS THAT REDDEN IT:
//   * reinstate the transitional batch inside `revolveProfileEx`
//     (`auto ringEd = MeshEditBatch.unrecorded(ed.mesh, kRevolveEditScope);`
//     around the closed arm's ring loop) → the CLOSED cell's `nested` becomes 1;
//   * open the caller's batch with the RECORDING constructor
//     (`MeshEditBatch(*m, kRevolveEditScope)`) → the `opLog` cell reddens: the
//     preview path re-runs this kernel per drag frame and must record nothing
//     (plan §9);
//   * break `Mesh.commitChange`'s deferral
//     (`if (auto f = currentBatchFrame(&this))` → `if (false) if (…)`) → both
//     `unbatched` cells redden with the per-face count the batch was hiding.
import mesh;
import math;
import mesh_ops.revolve;
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
// HEAP-allocated, because `g_isDocumentMesh` below recognises addresses and a
// `Layer`'s mesh is on the heap for the same reason — a stack `Mesh` would make
// the predicate name a frame that unwinds.
private Mesh* profileMesh(size_t n, bool asFace, bool sub) {
    import std.math : cos, sin, PI;
    auto m = new Mesh;
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

unittest { // one batch per sweep, opened by the caller, for BOTH profile arms
    foreach (profileClosed; [false, true]) {
        RevolveParams p;
        p.count = 6; p.axis = Vec3(0, 1, 0); p.angle = 6.2831853f;
        uint[] prof = [0u, 1u, 2u, 3u];

        auto m   = profileMesh(4, profileClosed, false);
        auto ctl = profileMesh(4, profileClosed, false);   // the control's own mesh

        // Wake the document-mesh predicate for THESE TWO meshes only, and put
        // it back afterwards. Without this the `unbatched` assertions below are
        // green whatever the code does.
        auto prevResolver = g_isDocumentMesh;
        scope(exit) g_isDocumentMesh = prevResolver;
        const(void)* subjAddr = cast(const(void)*)m;
        const(void)* ctlAddr  = cast(const(void)*)ctl;
        g_isDocumentMesh = (const(Mesh)* q) =>
            cast(const(void)*)q is subjAddr || cast(const(void)*)q is ctlAddr;

        // POSITIVE CONTROL first, on the same counter: one bare `addFace`
        // outside any batch must tick it. A dead counter — the predicate
        // uninstalled, these meshes moved to the stack — satisfies every
        // `== 0` below for free. It runs on `ctl`, not on the subject, so the
        // control cannot perturb the geometry the deltas are measured across.
        immutable ulong ctl0 = changeBus.unbatchedGeometryCommits;
        ctl.addFace([0u, 1u, 2u]);
        immutable ulong ctrl = changeBus.unbatchedGeometryCommits - ctl0;
        assert(ctrl > 0,
            format("positive control: a bare addFace outside any batch must "
                 ~ "tick changeBus.unbatchedGeometryCommits, and it ticked %d. "
                 ~ "A dead counter passes the assertions below for free "
                 ~ "(task 1903 §3.2 L2, change_bus.d's own note on "
                 ~ "g_isDocumentMesh).", ctrl));

        immutable size_t preF = m.faces.length;
        immutable ulong n0 = changeBus.nestedBatchOpens;
        immutable ulong u0 = changeBus.unbatchedGeometryCommits;
        immutable ulong l0 = changeBus.opLogEntriesRecorded;
        immutable ulong b0 = changeBus.batchLeaks;

        size_t added;
        {
            auto ed = MeshEditBatch.unrecorded(*m, kRevolveEditScope);
            added = ed.revolveProfileEx(prof, profileClosed, p);
            ed.close();
        }

        immutable ulong nested    = changeBus.nestedBatchOpens          - n0;
        immutable ulong unbatched = changeBus.unbatchedGeometryCommits  - u0;
        immutable ulong opLog     = changeBus.opLogEntriesRecorded      - l0;
        immutable ulong leaks     = changeBus.batchLeaks                - b0;

        // Non-vacuity FIRST: a delta measured across a refused kernel says
        // nothing, and this kernel refuses on five different guards.
        assert(added > 0 && m.faces.length > preF,
            format("revolve closed=%s added %d faces (F %d -> %d) — the kernel "
                 ~ "refused, so every delta below was measured across nothing",
                   profileClosed, added, preF, m.faces.length));

        assert(nested == 0,
            format("revolve closed=%s opened %d NESTED batch(es) inside the "
                 ~ "caller's, expected 0. Since Stage E2 the kernel takes a "
                 ~ "`ref MeshEditBatch` and opens none of its own — the "
                 ~ "transitional block D3 had to put around the closed arm's "
                 ~ "ring loop is gone, and a kernel opening a batch is what "
                 ~ "plan §2.3 rule 2 forbids in the finished design.",
                   profileClosed, nested));

        assert(unbatched == 0,
            format("revolve closed=%s made %d UNBATCHED geometry commit(s) on "
                 ~ "a document mesh, expected 0: every commit the kernel makes "
                 ~ "must defer into the caller's frame and stamp once at "
                 ~ "close(). This is the assertion the OPEN arm could not pass "
                 ~ "before Stage E2 — D3's transitional batch covered the "
                 ~ "closed arm only, so the open strip committed once per "
                 ~ "addFace (task 1903 Stage E2, plan §3.2 L2).",
                   profileClosed, unbatched));

        assert(opLog == 0,
            format("revolve closed=%s recorded %d op-log entr(ies) under an "
                 ~ "UNRECORDED batch, expected 0. `close()` on an unrecorded "
                 ~ "batch returns MeshEditDelta.init and every tracker hook "
                 ~ "keeps its `if (editRecorder_ is null) return;` first line — "
                 ~ "which is what lets RadialSweepTool re-run this kernel per "
                 ~ "drag frame without building an op-log at 60 Hz (plan §9).",
                   profileClosed, opLog));

        assert(leaks == 0,
            format("revolve closed=%s leaked %d batch handle(s) — a "
                 ~ "MeshEditBatch was destroyed while still open, i.e. an "
                 ~ "exception escaped between the open and the close "
                 ~ "(task 1903 §2.2c).", profileClosed, leaks));
    }
}

unittest { // the batch changes no geometry: a sweep under one is the old sweep
    // The seam is a publishing change, not a modelling one. Two identical
    // meshes, two DIFFERENT batch shapes over the same kernel call — one batch
    // scoped to the call, one that also spans a `buildLoops()` before and after
    // it — must land on byte-identical state. If they ever diverge, the batch
    // is doing something to the mesh, and the whole "conversion is
    // byte-identical" claim behind track 1 is wrong.
    foreach (profileClosed; [false, true]) {
        RevolveParams p;
        p.count = 6; p.axis = Vec3(0, 1, 0); p.angle = 6.2831853f;
        p.startAngle = 0.6f; p.offset = 0.35f; p.cap0 = true; p.cap1 = true;
        uint[] prof = [0u, 1u, 2u, 3u];

        auto a = profileMesh(4, profileClosed, true);
        auto b = profileMesh(4, profileClosed, true);

        size_t ra, rb;
        {
            auto ed = MeshEditBatch.unrecorded(*a, kRevolveEditScope);
            ra = ed.revolveProfileEx(prof, profileClosed, p);
            ed.close();
        }
        {
            auto ed = MeshEditBatch.unrecorded(*b, kRevolveEditScope);
            ed.buildLoops();
            rb = ed.revolveProfileEx(prof, profileClosed, p);
            ed.buildLoops();
            ed.close();
        }
        assert(ra == rb && st(*a) == st(*b),
            format("revolve closed=%s: the same sweep under two batch shapes "
                 ~ "produced different meshes (returned %d vs %d)\n a: %s\n b: %s",
                   profileClosed, ra, rb, st(*a), st(*b)));
    }
}
