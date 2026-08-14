// Module unittests for `toolpipe.stages.falloff`, moved verbatim out of source/toolpipe/stages/falloff.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.falloff_test;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.math      : abs;
import math : Vec3, Viewport, dot, projectToWindowFull, aimSpace, ModelSpace;
import document : primaryModelSpace;
import std.math : sqrt;
import mesh : Mesh, MapDomain, MeshCacheKey;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordWght;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : FalloffConfig, FalloffPacket, FalloffType, FalloffShape,
                            FalloffMix, LassoStyle, ElementConnect, ElementMode;
import operator          : Operator, Task, VectorStack, PacketKind;
import toolpipe.stages.workplane : WorkplaneStage;
import popup_state       : setStatePath;
import params            : Param, ParamHints, IntEnumEntry, wireTagForValue, valueForWireTag;
import toolpipe.stages.falloff;

// ---------------------------------------------------------------------------
// Task 0185 — equivalence guard for resolveElementBuffers(). Element-falloff
// resolution used to be implemented twice: once here (headless, parity-
// tested) and once inline in the interactive drag-capture path (deleted).
// This test proves NO WEIGHT CHANGE resulted from collapsing to one resolver
// by reconstructing the DELETED drag-side bodies verbatim as free functions
// below and comparing their output against resolveElementBuffers()'s output
// per vertex. It deliberately does NOT build both packets from a single
// resolveElementBuffers() call (that would only prove dup(X)==X); the "old"
// side is wired from the stage's raw, unresolved fields exactly as the
// deleted TransformTool code read them.
//
// Mesh: two disjoint cubes (A = indices 0-7, B = 8-15, no shared edge) so a
// BFS connect-mask partition is actually observable — a single connected
// mesh would make every vertex reachable, hiding a broken BFS behind an
// all-true mask.
// ---------------------------------------------------------------------------
unittest {
    import mesh   : edgeLoopRing;
    import falloff : evaluateFalloff;

    // --- verbatim reconstructions of the DELETED drag-side resolution ------

    // Verbatim copy of the ring-selection logic that used to live inline in
    // TransformTool.captureFalloffForDrag's Element branch: EdgeLoops with a
    // 2-vert picked edge walks the quad edge-loop; every other case (vertex
    // pick, polygon pick, or EdgeLoops with an already-resolved ring) passes
    // anchorRing through unchanged.
    static uint[] oldRing(const ref Mesh m, ElementConnect connect,
                          const(uint)[] anchorRing) {
        if (connect == ElementConnect.EdgeLoops && anchorRing.length == 2)
            return edgeLoopRing(m, anchorRing[0], anchorRing[1]);
        return anchorRing.dup;
    }

    // Verbatim copy of the deleted TransformTool.resolveConnectMaskForDrag:
    // builds its OWN undirected adjacency from mesh.edges (NOT the shared
    // vertexAdjacencyCSR the stage's resolveConnectMask() uses below) and
    // BFS-floods from `ring`. This is the one real behavior change the dedup
    // makes (CSR-BFS replacing this mesh.edges-BFS) — asserted identical below.
    static bool[] oldConnectMask(const ref Mesh m, const(uint)[] ring) {
        if (ring.length == 0) return null;
        const size_t nV = m.vertices.length;
        if (nV == 0) return null;
        auto offset = new size_t[](nV + 1);
        foreach (e; m.edges) {
            if (e[0] >= nV || e[1] >= nV) continue;
            offset[e[0] + 1]++;
            offset[e[1] + 1]++;
        }
        foreach (i; 1 .. nV + 1) offset[i] += offset[i - 1];
        auto neighbors = new size_t[](offset[nV]);
        auto cursor = new size_t[](nV);
        foreach (i; 0 .. nV) cursor[i] = offset[i];
        foreach (e; m.edges) {
            if (e[0] >= nV || e[1] >= nV) continue;
            neighbors[cursor[e[0]]++] = e[1];
            neighbors[cursor[e[1]]++] = e[0];
        }
        auto visited = new bool[](nV);
        size_t[] stack;
        foreach (vi; ring) {
            if (cast(size_t)vi >= nV || visited[vi]) continue;
            visited[vi] = true;
            stack ~= cast(size_t)vi;
        }
        while (stack.length > 0) {
            size_t v = stack[$ - 1];
            stack.length -= 1;
            foreach (j; offset[v] .. offset[v + 1]) {
                size_t nb = neighbors[j];
                if (!visited[nb]) { visited[nb] = true; stack ~= nb; }
            }
        }
        return visited;
    }

    // Verbatim copy of the deleted per-vertex anchor-position loop.
    static Vec3[] oldAnchorPos(const ref Mesh m, const(uint)[] ring) {
        Vec3[] aPos;
        const size_t nV = m.vertices.length;
        foreach (vi; ring)
            if (cast(size_t)vi < nV) aPos ~= m.vertices[vi];
        return aPos;
    }

    // --- two-disjoint-cube mesh ---------------------------------------------
    Mesh mesh;
    mesh.vertices = [
        // Cube A (indices 0-7)
        Vec3(-0.5f, -0.5f, -0.5f), Vec3( 0.5f, -0.5f, -0.5f),
        Vec3( 0.5f,  0.5f, -0.5f), Vec3(-0.5f,  0.5f, -0.5f),
        Vec3(-0.5f, -0.5f,  0.5f), Vec3( 0.5f, -0.5f,  0.5f),
        Vec3( 0.5f,  0.5f,  0.5f), Vec3(-0.5f,  0.5f,  0.5f),
        // Cube B (indices 8-15) — cube A translated +3 on X. Well beyond any
        // radius used below; shares no edge with cube A.
        Vec3( 2.5f, -0.5f, -0.5f), Vec3( 3.5f, -0.5f, -0.5f),
        Vec3( 3.5f,  0.5f, -0.5f), Vec3( 2.5f,  0.5f, -0.5f),
        Vec3( 2.5f, -0.5f,  0.5f), Vec3( 3.5f, -0.5f,  0.5f),
        Vec3( 3.5f,  0.5f,  0.5f), Vec3( 2.5f,  0.5f,  0.5f),
    ];
    mesh.addFace([0, 3, 2, 1]);
    mesh.addFace([4, 5, 6, 7]);
    mesh.addFace([0, 4, 7, 3]);
    mesh.addFace([1, 2, 6, 5]);
    mesh.addFace([3, 7, 6, 2]);
    mesh.addFace([0, 1, 5, 4]);
    mesh.addFace([8, 11, 10, 9]);
    mesh.addFace([12, 13, 14, 15]);
    mesh.addFace([8, 12, 15, 11]);
    mesh.addFace([9, 10, 14, 13]);
    mesh.addFace([11, 15, 14, 10]);
    mesh.addFace([8, 9, 13, 12]);
    mesh.buildLoops();

    EditMode em = EditMode.Vertices;
    Mesh* meshPtr = &mesh;
    auto fs = new FalloffStage(() => meshPtr, &em);
    fs.type  = FalloffType.Element;
    fs.shape = FalloffShape.Linear;
    // Cube edge length is 1 (face/space diagonal ~1.41/1.73), so this radius
    // makes the weight genuinely vary across cube A, yet sits well short of
    // the >=2.0 minimum distance to any cube-B vertex — under Ignore the
    // pure geometric-distance term alone already zeroes cube B (no gate
    // needed there); the UseConnectivity/Rigid cases below separately prove
    // the connectivity GATE zeroes it too, checked BEFORE any distance math
    // runs (see elementWeight's gate-then-distance order in source/falloff.d).
    fs.pickedRadius = 1.2f;

    Viewport vpW;
    // Element falloff never projects, so the identity aim is the honest
    // value here — and `ModelSpace.world()` is only reachable from a
    // unittest (task 0619 §2.3.3 bans it in production in these files).
    auto vp = aimSpace(vpW, ModelSpace.world());

    // vertex / edge / face pick types, all anchored inside cube A.
    const(uint)[][] pickRings = [
        [0u],             // vertex pick
        [0u, 1u],         // edge pick (0-1 is a real cube edge)
        [0u, 3u, 2u, 1u], // polygon pick (face 0's vert ring)
    ];

    foreach (ring0; pickRings) {
        Vec3 centroid = Vec3(0, 0, 0);
        foreach (vi; ring0) centroid = centroid + mesh.vertices[vi];
        centroid = centroid * (1.0f / cast(float) ring0.length);

        foreach (connect; [ElementConnect.Ignore, ElementConnect.UseConnectivity,
                            ElementConnect.Rigid,  ElementConnect.EdgeLoops]) {
            fs.connect      = connect;
            fs.anchorRing   = ring0.dup;
            fs.connectMask  = null; // no click-pick mask -> both sides BFS

            // NEW: the resolver under test.
            auto er = fs.resolveElementBuffers();

            FalloffPacket newPkt;
            newPkt.config            = fs.config.dup;
            newPkt.enabled           = true;
            newPkt.pickedCenter      = centroid;
            newPkt.config.anchorRing = er.ring;
            newPkt.connectMask       = er.connectMask;
            newPkt.anchorPos         = er.anchorPos;

            // OLD: independently reconstructed from the deleted bodies,
            // reading the stage's RAW (unresolved) fields — resolveElementBuffers()
            // above never touches fs.anchorRing / fs.connect / fs.connectMask.
            uint[] ring = oldRing(mesh, fs.connect, fs.anchorRing);
            bool[] oldMask = (fs.connectMask.length > 0)
                ? fs.connectMask.dup
                : oldConnectMask(mesh, ring);

            FalloffPacket oldPkt;
            oldPkt.config            = fs.config.dup;
            oldPkt.enabled           = true;
            oldPkt.pickedCenter      = centroid;
            oldPkt.config.anchorRing = ring;
            oldPkt.connectMask       = oldMask;
            oldPkt.anchorPos         = oldAnchorPos(mesh, ring);

            // --- no-behavior-change gate: exact per-vertex weight equality --
            foreach (vi; 0 .. mesh.vertices.length) {
                float wNew = evaluateFalloff(newPkt, mesh.vertices[vi], cast(int) vi, vp);
                float wOld = evaluateFalloff(oldPkt, mesh.vertices[vi], cast(int) vi, vp);
                assert(wNew == wOld,
                    format("connect=%s ring=%s vert %d: new=%.6f old=%.6f",
                           connect, ring0, vi, wNew, wOld));
            }

            // --- mask-partition + BFS-source assertions ---------------------
            if (connect == ElementConnect.UseConnectivity
             || connect == ElementConnect.Rigid) {
                // The CSR-BFS mask actually gates on connectivity — cube A in,
                // cube B out. Structural, independent of the radius/distance
                // math above.
                assert(er.connectMask.length == mesh.vertices.length);
                foreach (k; 0 .. 8)
                    assert(er.connectMask[k],  "cube-A vert must be IN the component");
                foreach (k; 8 .. 16)
                    assert(!er.connectMask[k], "cube-B vert must be OUT of the component");
                // The one real behavior change this task makes: the shared
                // vertexAdjacencyCSR BFS (resolveConnectMask) must agree
                // exactly with the mesh.edges BFS it replaces.
                assert(er.connectMask == oldConnectMask(mesh, ring),
                    "vertexAdjacencyCSR-BFS mask must equal the mesh.edges-BFS mask");
                // Consequence: cube-B verts read weight 0 via the GATE (which
                // runs before any distance math), not merely because they are
                // far away.
                foreach (k; 8 .. 16) {
                    float w = evaluateFalloff(newPkt, mesh.vertices[k], cast(int) k, vp);
                    assert(w == 0.0f,
                        "cube-B vertex must get weight 0 under the connectivity gate");
                }
            } else {
                // Ignore / EdgeLoops: elementWeight never reads connectMask for
                // these modes, so the dedup's one visible buffer change — the
                // NEW resolver leaves the mask EMPTY here, where the OLD drag
                // path always built a full (but dead) mask regardless of
                // connect — is invisible in the weights checked above. Pin the
                // divergence explicitly so it stays a documented no-op rather
                // than an untested assumption.
                assert(er.connectMask.length == 0,
                    "resolver mask must stay empty for Ignore/EdgeLoops (dead buffer, never read)");
                assert(oldConnectMask(mesh, ring).length == mesh.vertices.length,
                    "old drag path built a full mask even though Ignore/EdgeLoops never reads it");
            }
        }
    }
}
