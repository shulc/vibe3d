/// OpenSubdiv integration for vibe3d's Catmull-Clark needs.
///
///   * `OsdAccel` is the production back-end for SubpatchPreview's
///     subdivision-surface preview — builds an OSD topology + stencil
///     table once per cage-topology change and refresh()es per drag
///     frame in one SpMV.
///
///   * `catmullClarkOsd` is the OSD-driven replacement for the
///     formerly-CPU `catmullClark` / `catmullClarkSelected` functions,
///     used by the permanent `mesh.subdivide` command. Single CC pass
///     over the cage (or its `faceMask` subset). For partial subsets
///     it preserves the standard "widened polygon" handling on the
///     boundary so the result stays manifold (no T-junctions across
///     refined/un-refined faces).
module subpatch_osd;

import math : Vec3;
import mesh : Mesh, SubpatchTrace, edgeKey, makeCube;
import osd.c;

/// One-shot startup verification of the OSD GL evaluator. Builds a
/// tiny cube cage, evaluates limit positions both on CPU and on GPU
/// via transform feedback, returns the max per-component delta.
/// Requires an active GL 3.3+ context on the calling thread.
///
/// Logs the result to stderr. Used during boot to fail fast if the
/// GPU evaluator is broken on the host's driver; production code
/// paths still drive subpatch through the CPU evaluator until the
/// Phase 3 VBO refactor lands (see doc/osd_gpu_evaluator_phase3.md).
float runGlEvaluatorSmokeTest() {
    import bindbc.opengl;
    import std.stdio : stderr;

    void warn(string s) {
        try { stderr.writeln("[osd_gl_smoke] ", s); stderr.flush(); }
        catch (Exception) {}
    }

    // 8 cage verts / 6 quad faces (unit cube).
    immutable int[6]  faceCounts  = [4, 4, 4, 4, 4, 4];
    immutable int[24] faceIndices = [
        0, 1, 3, 2,   4, 6, 7, 5,
        0, 2, 6, 4,   1, 5, 7, 3,
        0, 4, 5, 1,   2, 3, 7, 6,
    ];
    immutable float[24] cageXyz = [
        -1, -1, -1,   1, -1, -1,
        -1, -1,  1,   1, -1,  1,
        -1,  1, -1,   1,  1, -1,
        -1,  1,  1,   1,  1,  1,
    ];

    auto topo = osdc_topology_create(
        8, 6, faceCounts.ptr, faceIndices.ptr, 1);
    if (topo is null) { warn("topology create failed"); return -1.0f; }
    scope (exit) osdc_topology_destroy(topo);

    immutable int limitVerts = osdc_topology_limit_vert_count(topo);

    // CPU baseline
    float[] cpuOut = new float[](3 * limitVerts);
    osdc_evaluate(topo, cageXyz.ptr, cpuOut.ptr);

    // GPU eval — needs OSD's bundled glLoader to be initialised
    // (osdc_gl_create handles that lazily).
    auto glEval = osdc_gl_create(topo);
    if (glEval is null) { warn("GL evaluator create failed"); return -1.0f; }
    scope (exit) osdc_gl_destroy(glEval);

    GLuint srcVbo, dstVbo;
    glGenBuffers(1, &srcVbo);
    glGenBuffers(1, &dstVbo);
    scope (exit) {
        glDeleteBuffers(1, &srcVbo);
        glDeleteBuffers(1, &dstVbo);
    }

    glBindBuffer(GL_ARRAY_BUFFER, srcVbo);
    glBufferData(GL_ARRAY_BUFFER, cageXyz.length * float.sizeof,
                 cast(const void*)cageXyz.ptr, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, dstVbo);
    glBufferData(GL_ARRAY_BUFFER, 3 * limitVerts * float.sizeof,
                 null, GL_DYNAMIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    int ok = osdc_gl_evaluate(glEval, srcVbo, dstVbo);
    if (!ok) { warn("osdc_gl_evaluate returned 0"); return -1.0f; }

    float[] gpuOut = new float[](3 * limitVerts);
    glBindBuffer(GL_ARRAY_BUFFER, dstVbo);
    glGetBufferSubData(GL_ARRAY_BUFFER, 0,
                       3 * limitVerts * float.sizeof, gpuOut.ptr);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    float maxDelta = 0.0f;
    foreach (i; 0 .. cpuOut.length) {
        import std.math : abs;
        float d = abs(cpuOut[i] - gpuOut[i]);
        if (d > maxDelta) maxDelta = d;
    }
    try {
        stderr.writefln("[osd_gl_smoke] OK: %d limit verts, max "
                        ~ "|CPU - GPU| = %.6g", limitVerts, maxDelta);
        stderr.flush();
    } catch (Exception) {}
    return maxDelta;
}

/// One Catmull-Clark refinement of `cage` via OpenSubdiv. When
/// `faceMask` is empty (or all-true) every face is refined and the
/// result is OSD's level-1 limit mesh verbatim. When `faceMask` is
/// partial, only marked faces are refined; un-marked faces are
/// passed through with boundary-edge "widening" — any boundary edge
/// the marked subset bisects gets its OSD edge-point inserted into
/// the adjacent un-marked face's vert list so the result is still
/// manifold (no T-junction across the refinement boundary).
///
/// Returns `Mesh.init` when OSD can't build a topology (degenerate
/// input or empty subset).
Mesh catmullClarkOsd(ref const Mesh cage, const bool[] faceMask = null) {
    immutable int nv = cast(int)cage.vertices.length;
    immutable int nf = cast(int)cage.faces.length;
    if (nv == 0 || nf == 0) return Mesh.init;

    // Detect selection mode: are ALL faces (effectively) marked?
    bool anyUnmarked = false;
    foreach (fi; 0 .. nf) {
        immutable bool marked =
            (faceMask.length == 0)
            || ((fi < faceMask.length) && faceMask[fi]);
        if (!marked) { anyUnmarked = true; break; }
    }

    // ---- Build sub-cage from the marked subset (whole cage when
    // ----  faceMask is empty / all-true).
    int[] cageToSub = new int[](nv);
    cageToSub[] = -1;
    int[] subToCage;
    int[] markedFaceIndices;     // cage face idx of each sub-cage face
    int   subNumVerts    = 0;
    int   subTotalIndices = 0;
    foreach (fi; 0 .. nf) {
        immutable bool marked =
            (faceMask.length == 0)
            || ((fi < faceMask.length) && faceMask[fi]);
        if (!marked) continue;
        markedFaceIndices ~= cast(int)fi;
        subTotalIndices  += cast(int)cage.faces[fi].length;
        foreach (cvi; cage.faces[fi]) {
            if (cageToSub[cvi] == -1) {
                cageToSub[cvi] = subNumVerts++;
                subToCage ~= cvi;
            }
        }
    }
    immutable int subNumFaces = cast(int)markedFaceIndices.length;
    if (subNumFaces == 0) return Mesh.init;

    int[] sfvc = new int[](subNumFaces);
    int[] sfvi = new int[](subTotalIndices);
    {
        int faceCursor = 0, idxCursor = 0;
        foreach (fi; markedFaceIndices) {
            sfvc[faceCursor] = cast(int)cage.faces[fi].length;
            foreach (cvi; cage.faces[fi])
                sfvi[idxCursor++] = cageToSub[cvi];
            ++faceCursor;
        }
    }

    float[] cageXyz = new float[](3 * subNumVerts);
    foreach (svi, cvi; subToCage) {
        Vec3 v = cage.vertices[cvi];
        cageXyz[3*svi + 0] = v.x;
        cageXyz[3*svi + 1] = v.y;
        cageXyz[3*svi + 2] = v.z;
    }

    // ---- OSD topology at depth 1 + read back limit topology.
    auto osd = osdc_topology_create(
        subNumVerts, subNumFaces, sfvc.ptr, sfvi.ptr, 1);
    if (osd is null) return Mesh.init;
    scope (exit) osdc_topology_destroy(osd);

    immutable int limitV   = osdc_topology_limit_vert_count(osd);
    immutable int limitF   = osdc_topology_limit_face_count(osd);
    immutable int limitIdx = osdc_topology_limit_index_count(osd);

    int[] limitFC = new int[](limitF);
    int[] limitFI = new int[](limitIdx);
    int[] faceOriginsRaw = new int[](limitF);
    int[] vertOriginsRaw = new int[](limitV);
    osdc_topology_limit_topology(osd, limitFC.ptr, limitFI.ptr);
    osdc_topology_face_origins(osd, faceOriginsRaw.ptr);
    osdc_topology_vert_origins(osd, vertOriginsRaw.ptr);

    Vec3[] osdVerts = new Vec3[](limitV);
    osdc_evaluate(osd, cageXyz.ptr, cast(float*)osdVerts.ptr);

    Mesh result;

    if (!anyUnmarked) {
        // Full refinement — OSD's output IS the result mesh.
        result.vertices = osdVerts;
        result.faces.length = limitF;
        int cursor = 0;
        foreach (k; 0 .. limitF) {
            result.faces[k].length = limitFC[k];
            foreach (j; 0 .. limitFC[k])
                result.faces[k][j] = cast(uint)limitFI[cursor++];
        }
        // Edges direct from OSD.
        immutable int limitE = osdc_topology_limit_edge_count(osd);
        int[] limitEV = new int[](2 * limitE);
        osdc_topology_limit_edges(osd, limitEV.ptr);
        result.edges.length = limitE;
        foreach (k; 0 .. limitE) {
            result.edges[k] = [
                cast(uint)limitEV[2*k + 0],
                cast(uint)limitEV[2*k + 1],
            ];
        }
        // Per-face subpatch flag inherits from the parent cage face.
        result.isSubpatch = new bool[](limitF);
        foreach (k; 0 .. limitF) {
            int parent = faceOriginsRaw[k];
            int cageFi = markedFaceIndices[parent];
            if (cageFi < cast(int)cage.isSubpatch.length)
                result.isSubpatch[k] = cage.isSubpatch[cageFi];
        }
    } else {
        // ---- Selective: stitch OSD output with un-marked cage faces.
        //
        // 1. Build cage-vert → result-vert idx map:
        //      In-subset cage verts map to their OSD vert-point idx
        //      (corner-pinned, sitting at the original cage position
        //      because the shim configures EDGE_AND_CORNER boundary).
        //      Out-of-subset cage verts get appended after the OSD
        //      verts.
        int[] cageToNew = new int[](nv);
        cageToNew[] = -1;
        foreach (osdIdx, origin; vertOriginsRaw) {
            if (origin < 0) continue;
            int cageVi = subToCage[origin];
            if (cageToNew[cageVi] == -1)
                cageToNew[cageVi] = cast(int)osdIdx;
        }
        result.vertices = osdVerts.dup;
        foreach (cageVi; 0 .. nv) {
            if (cageToNew[cageVi] != -1) continue;
            cageToNew[cageVi] = cast(int)result.vertices.length;
            result.vertices ~= cage.vertices[cageVi];
        }

        // 2. Map each cage edge to its OSD edge-point (limit-vert
        //    idx) if it lies on the refined subset's boundary. We
        //    don't get this from OSD directly in cage-edge space —
        //    walk OSD's input-edge list (sub-cage edges), pair the
        //    endpoint cage verts via subToCage, look up the cage
        //    edge through cage.edgeIndexMap.
        immutable int inEdges = osdc_topology_input_edge_count(osd);
        int[] inEdgeVerts    = new int[](2 * inEdges);
        int[] inEdgeChildren = new int[](inEdges);
        osdc_topology_input_edges          (osd, inEdgeVerts.ptr);
        osdc_topology_input_edge_children  (osd, inEdgeChildren.ptr);

        uint[uint] cageEdgeToOsdEdgePt;   // cage edge idx → OSD limit vert
        foreach (se; 0 .. inEdges) {
            uint cv0 = subToCage[inEdgeVerts[2*se + 0]];
            uint cv1 = subToCage[inEdgeVerts[2*se + 1]];
            if (auto p = edgeKey(cv0, cv1) in cage.edgeIndexMap) {
                cageEdgeToOsdEdgePt[*p] = cast(uint)inEdgeChildren[se];
            }
        }

        // 3. Marked faces: OSD output, indices already in result-vert
        //    space (OSD limit-vert idx == result-vert idx for the
        //    leading limitV slots).
        result.faces.length = limitF;
        result.isSubpatch.length = limitF;
        int cursor = 0;
        foreach (k; 0 .. limitF) {
            result.faces[k].length = limitFC[k];
            foreach (j; 0 .. limitFC[k])
                result.faces[k][j] = cast(uint)limitFI[cursor++];
            int parent = faceOriginsRaw[k];
            int cageFi = markedFaceIndices[parent];
            if (cageFi < cast(int)cage.isSubpatch.length)
                result.isSubpatch[k] = cage.isSubpatch[cageFi];
        }

        // 4. Un-marked faces: walk each cage edge, insert the OSD
        //    edge-point if the adjacent marked face subdivided this
        //    edge (T-junction widening — keeps the mesh manifold).
        foreach (fi; 0 .. nf) {
            immutable bool marked =
                (fi < faceMask.length) && faceMask[fi];
            if (marked) continue;
            const(uint)[] face = cage.faces[fi];
            uint[] widened;
            foreach (i; 0 .. face.length) {
                uint v0 = face[i];
                uint v1 = face[(i + 1) % face.length];
                widened ~= cast(uint)cageToNew[v0];
                if (auto cei = edgeKey(v0, v1) in cage.edgeIndexMap) {
                    if (auto ep = *cei in cageEdgeToOsdEdgePt)
                        widened ~= *ep;
                }
            }
            result.faces ~= widened;
            result.isSubpatch ~= (fi < cage.isSubpatch.length)
                ? cage.isSubpatch[fi] : false;
        }

        // 5. Rebuild edges via dedup'd face-edge walk (vibe3d's
        //    addFace pattern). OSD's limit-edges array only covers
        //    the refined subset; widened un-marked faces add edges
        //    that aren't in OSD's view.
        uint[ulong] edgeLookup;
        foreach (face; result.faces) {
            foreach (i; 0 .. face.length) {
                uint a = face[i];
                uint b = face[(i + 1) % face.length];
                ulong key = edgeKey(a, b);
                if (key !in edgeLookup) {
                    result.edges ~= [a, b];
                    edgeLookup[key] = cast(uint)(result.edges.length - 1);
                }
            }
        }
    }

    // Selection masks sized to the new mesh; rebuild loops; bump
    // versions so downstream caches treat this as a fresh state
    // distinct from Mesh.init.
    result.selectedVertices.length = result.vertices.length;
    result.selectedEdges.length    = result.edges.length;
    result.selectedFaces.length    = result.faces.length;
    result.mutationVersion = 1;
    result.topologyVersion = 1;
    result.buildLoops();
    return result;
}

// ---------------------------------------------------------------------------
// OsdAccel — SubpatchPreview back-end built on OpenSubdiv.
//
// Drives both subpatch cases:
//
//   Uniform   — every cage face marked `isSubpatch`. OSD subdivides the
//               whole cage; the preview is the limit surface.
//
//   Selective — only some cage faces marked. We extract the marked
//               subset (faces + their incident verts) as a standalone
//               sub-cage, feed THAT to OSD, and the preview contains
//               only the subdivided subset. Non-subpatch faces don't
//               appear in the preview at all — this is the explicit
//               trade-off the user requested ("subdiv выделенных
//               полигонов, как будто других и не существует") to keep
//               the back-end uniform: OSD has no per-face skip mode,
//               and stitching refined / unrefined surfaces is what
//               vibe3d's old catmullClarkSelected did on CPU. Behaviour
//               will differ from that path.
//
// `buildPreview` owns the topology generation; `refresh` is the per-
// drag-frame call that only restamps positions. The OSD handle and
// the sub-cage → cage index map stay cached across drag events. Cage-
// topology change → SubpatchPreview drops the OsdAccel and re-runs
// `buildPreview` on the new mask.
// ---------------------------------------------------------------------------
struct OsdAccel {
    private osdc_topology_t* osd;
    private float[] cageScratchXyz;    // tightly-packed cage positions
    bool valid;

    /// Free the OSD handle and reset state. Idempotent.
    void clear() {
        if (osd !is null) {
            osdc_topology_destroy(osd);
            osd = null;
        }
        cageScratchXyz.length = 0;
        valid                 = false;
    }

    /// Free OSD resources at scope exit. The struct is owned by
    /// SubpatchPreview, which lives for the program's duration, so this
    /// fires once — but it keeps `dub test` (and any future short-lived
    /// SubpatchPreview instances) leak-clean.
    ~this() { clear(); }

    /// Build OSD topology + stencil table for `cage` at `level`, emit
    /// the limit Mesh (verts/edges/faces/loops) and SubpatchTrace.
    /// Selective subpatch (mixed isSubpatch flags) tags every edge /
    /// vert that touches an un-marked face with infinite sharpness —
    /// OSD then smooths the marked-region interior and keeps the
    /// un-marked region flat, with a sharp crease at the boundary.
    /// Matches the LightWave / MODO visual model.
    ///
    /// Returns false (and clears state) on degenerate input or OSD
    /// topology-creation failure.
    bool buildPreview(ref const Mesh cage, int level,
                       out Mesh outMesh, out SubpatchTrace outTrace)
    {
        clear();

        immutable int nv = cast(int)cage.vertices.length;
        immutable int nf = cast(int)cage.faces.length;
        if (nv == 0 || nf == 0 || level < 1) return false;

        // ---- Flatten cage topology -----------------------------------
        int[] faceVertCounts  = new int[](nf);
        int[] faceVertIndices;
        foreach (fi, face; cage.faces) {
            faceVertCounts[fi] = cast(int)face.length;
            foreach (vi; face) faceVertIndices ~= cast(int)vi;
        }
        cageScratchXyz.length = 3 * nv;
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }

        // ---- Selective-subpatch sharpness arrays ---------------------
        // For each cage edge that touches at least one un-marked face:
        // crease at SHARPNESS_INFINITE so OSD doesn't smooth across it.
        // For each cage vert that has at least one un-marked incident
        // face: corner-sharpen so the vert stays at the cage position.
        // Uniform-subpatch case (every face marked) → empty arrays,
        // standard smooth CC.
        bool anyMarked   = false;
        bool anyUnmarked = false;
        foreach (fi; 0 .. nf) {
            immutable bool marked =
                (fi < cage.isSubpatch.length) && cage.isSubpatch[fi];
            if (marked) anyMarked = true;
            else        anyUnmarked = true;
        }
        if (!anyMarked) { clear(); return false; }

        int[]   creasePairs;
        float[] creaseWeights;
        int[]   cornerVerts;
        float[] cornerWeights;
        enum float SHARP_INF = 10.0f;     // OSD treats >= 10 as infinity

        if (anyUnmarked) {
            // Tag verts that ANY un-marked face touches.
            bool[] vertHasUnmarked = new bool[](nv);
            // Per-edge: count marked vs un-marked adjacency to decide
            // crease vs smooth. Edge → (markedFaces, unmarkedFaces).
            int[2][] edgeFaces;
            edgeFaces.length = cage.edges.length;
            foreach (fi, face; cage.faces) {
                immutable bool marked =
                    (fi < cage.isSubpatch.length) && cage.isSubpatch[fi];
                foreach (i; 0 .. face.length) {
                    uint a = face[i];
                    uint b = face[(i + 1) % face.length];
                    if (!marked) {
                        vertHasUnmarked[a] = true;
                        vertHasUnmarked[b] = true;
                    }
                    if (auto p = edgeKey(a, b) in cage.edgeIndexMap) {
                        if (marked) ++edgeFaces[*p][0];
                        else        ++edgeFaces[*p][1];
                    }
                }
            }
            // Crease: any cage edge with at least one un-marked face.
            foreach (ei, e; cage.edges) {
                if (edgeFaces[ei][1] == 0) continue;
                creasePairs   ~= cast(int)e[0];
                creasePairs   ~= cast(int)e[1];
                creaseWeights ~= SHARP_INF;
            }
            // Corner: any cage vert touching an un-marked face.
            foreach (vi; 0 .. nv) {
                if (!vertHasUnmarked[vi]) continue;
                cornerVerts   ~= cast(int)vi;
                cornerWeights ~= SHARP_INF;
            }
        }

        // ---- Depth cap so OSD's stencil build stays in memory --------
        enum long MAX_LIMIT_FACES = 1_500_000;
        int effectiveLevel = level;
        long projected = cast(long)nf;
        long mul = 1L;
        foreach (k; 0 .. level) mul *= 4L;
        projected = cast(long)nf * mul;
        while (effectiveLevel > 1 && projected > MAX_LIMIT_FACES) {
            --effectiveLevel;
            projected /= 4L;
        }
        if (effectiveLevel != level) {
            import std.stdio : stderr;
            try {
                stderr.writefln(
                    "[subpatch_osd] capping subpatch depth %d -> %d "
                    ~ "(cage %d faces, projected %d limit faces exceeds %d)",
                    level, effectiveLevel, nf,
                    cast(long)nf * (1L << (2 * level)),
                    MAX_LIMIT_FACES);
            } catch (Exception) {}
        }

        // ---- Build OSD topology + stencil table ----------------------
        osd = osdc_topology_create_sharp(
            nv, nf,
            faceVertCounts.ptr, faceVertIndices.ptr,
            effectiveLevel,
            cast(int)(creasePairs.length / 2),
            creasePairs.length   ? creasePairs.ptr   : null,
            creaseWeights.length ? creaseWeights.ptr : null,
            cast(int)cornerVerts.length,
            cornerVerts.length    ? cornerVerts.ptr    : null,
            cornerWeights.length  ? cornerWeights.ptr  : null);
        if (osd is null) { clear(); return false; }

        immutable int limitVerts   = osdc_topology_limit_vert_count(osd);
        immutable int limitFaces   = osdc_topology_limit_face_count(osd);
        immutable int limitIndices = osdc_topology_limit_index_count(osd);
        immutable int limitEdges   = osdc_topology_limit_edge_count(osd);

        // ---- Read OSD limit topology + origin arrays -----------------
        int[] faceCounts     = new int[](limitFaces);
        int[] faceIndices    = new int[](limitIndices);
        int[] edgeVertsRaw   = new int[](2 * limitEdges);
        osdc_topology_limit_topology(osd, faceCounts.ptr, faceIndices.ptr);
        osdc_topology_limit_edges   (osd, edgeVertsRaw.ptr);

        int[] faceOriginsRaw = new int[](limitFaces);
        int[] vertOriginsRaw = new int[](limitVerts);
        int[] edgeOriginsRaw = new int[](limitEdges);
        osdc_topology_face_origins(osd, faceOriginsRaw.ptr);
        osdc_topology_vert_origins(osd, vertOriginsRaw.ptr);
        osdc_topology_edge_origins(osd, edgeOriginsRaw.ptr);

        // ---- Build preview Mesh.vertices via direct stencil eval -----
        outMesh.vertices = new Vec3[](limitVerts);
        osdc_evaluate(osd, cageScratchXyz.ptr,
                      cast(float*)outMesh.vertices.ptr);

        // ---- Build preview Mesh.edges --------------------------------
        outMesh.edges.length = limitEdges;
        foreach (i; 0 .. limitEdges) {
            outMesh.edges[i] = [
                cast(uint)edgeVertsRaw[2*i + 0],
                cast(uint)edgeVertsRaw[2*i + 1],
            ];
        }

        // ---- Build preview Mesh.faces --------------------------------
        outMesh.faces.length = limitFaces;
        int cursor = 0;
        foreach (fi; 0 .. limitFaces) {
            int cnt = faceCounts[fi];
            outMesh.faces[fi].length = cnt;
            foreach (k; 0 .. cnt)
                outMesh.faces[fi][k] = cast(uint)faceIndices[cursor++];
        }

        outMesh.mutationVersion = 1;
        outMesh.topologyVersion = 1;
        outMesh.buildLoops();

        // ---- SubpatchTrace ------------------------------------------
        // OSD's `*_origins[i]` are now cage indices directly (full cage
        // is the input). Map -1 → uint.max for the introduced-by-
        // subdivision case.
        outTrace.vertOrigin = new uint[](limitVerts);
        outTrace.edgeOrigin = new uint[](limitEdges);
        outTrace.faceOrigin = new uint[](limitFaces);
        foreach (i, o; vertOriginsRaw)
            outTrace.vertOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        foreach (i, o; edgeOriginsRaw)
            outTrace.edgeOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        foreach (i, o; faceOriginsRaw)
            outTrace.faceOrigin[i] = cast(uint)o;
        // Per-preview-face subpatch flag inherits from its cage parent.
        outTrace.subpatch = new bool[](limitFaces);
        outMesh.isSubpatch.length = limitFaces;
        foreach (i, o; faceOriginsRaw) {
            bool parentMarked =
                (o >= 0) && (o < cast(int)cage.isSubpatch.length)
                && cage.isSubpatch[o];
            outTrace.subpatch[i] = parentMarked;
            outMesh.isSubpatch[i] = parentMarked;
        }

        outMesh.selectedVertices.length = limitVerts;
        outMesh.selectedEdges.length    = limitEdges;
        outMesh.selectedFaces.length    = limitFaces;

        valid = true;
        return true;
    }

    /// Hot per-frame call: re-eval OSD's stencils against the current
    /// cage positions and write straight into `preview.vertices`.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(cage.vertices.length * 3 == cageScratchXyz.length,
               "cage vert count changed without buildPreview");

        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }
        osdc_evaluate(osd, cageScratchXyz.ptr,
                      cast(float*)preview.vertices.ptr);
    }
}

// ---------------------------------------------------------------------------
// Round-trip correctness: build a preview from a cube cage at depth 2,
// verify OSD-emitted topology counts match Catmull-Clark expectations,
// then edit a cage vert and ensure refresh() actually moves preview
// verts. Catches regressions in topology emission, trace derivation,
// and the per-frame scatter.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    // makeCube leaves isSubpatch empty; grow it before setSubpatch can
    // actually flip bits (setSubpatch returns early on out-of-range idx).
    cage.isSubpatch.length = cage.faces.length;
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 2, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed on uniform cube");

    // Cube → uniform CC depth 2 → 98 verts, 96 quads. Each quad has
    // 4 edges, but every interior edge is shared by 2 quads, so
    // num_edges = (4 * num_faces) / 2 = 192.
    assert(preview.vertices.length == 98);
    assert(preview.faces.length    == 96);
    assert(preview.edges.length    == 192);

    // Vert-origin layout: face/edge points carry uint.max, vert-points
    // (descendants of cage corners) carry their cage vert index. After
    // two CC passes the count of vert-points equals the cage vert
    // count = 8 (each cage vert produces exactly one vert-child per
    // level, recursively).
    int withOrigin = 0;
    foreach (o; trace.vertOrigin)
        if (o != uint.max) ++withOrigin;
    assert(withOrigin == 8,
           "expected 8 vert-points tracing back to cage corners");

    // Face origins are always in [0, num_cage_faces) — every refined
    // face descends from exactly one cage face.
    foreach (o; trace.faceOrigin) assert(o < 6, "face origin out of cage range");

    // Edit a cage vert and refresh — preview should mutate.
    Vec3[] before = preview.vertices.dup;
    cage.vertices[0] = cage.vertices[0] + Vec3(0.5f, 0, 0);
    accel.refresh(cage, preview);

    int moved = 0;
    foreach (i; 0 .. preview.vertices.length) {
        if (preview.vertices[i].x != before[i].x ||
            preview.vertices[i].y != before[i].y ||
            preview.vertices[i].z != before[i].z) ++moved;
    }
    assert(moved > 0, "refresh did not move any preview vert");
}

// ---------------------------------------------------------------------------
// Selective path: only the marked subset is fed to OSD, so the preview
// contains the OSD-subdivided subset and nothing else. Trace.faceOrigin
// must still point at CAGE face indices (the original 6 cube faces),
// not sub-cage indices.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    cage.buildLoops();
    cage.isSubpatch.length = cage.faces.length;

    // Mark a single face (cage face 0). The other 5 cage faces stay
    // un-marked and should keep their flat polygonal shape via OSD's
    // crease/corner sharpness.
    cage.setSubpatch(0, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 2, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed on selective cube");

    // Full cube fed to OSD at depth 2 → 6 cage faces × 4² = 96 limit
    // faces. Sharpness flag prevents the un-marked regions from
    // smoothing, but they DO get refined topologically.
    assert(preview.faces.length == 96,
           "selective L2 cube preview should keep all 6 cage faces, "
           ~ "subdivided into 16 quads each = 96 total");

    // trace.subpatch should be true for the 16 quads tracing back to
    // cage face 0, false for the other 80.
    int markedChildren = 0, unmarkedChildren = 0;
    foreach (i, b; trace.subpatch) {
        if (b) ++markedChildren; else ++unmarkedChildren;
    }
    assert(markedChildren   == 16);
    assert(unmarkedChildren == 80);

    // Refresh after a cage edit moves the preview.
    Vec3[] before = preview.vertices.dup;
    cage.vertices[0] = cage.vertices[0] + Vec3(0.5f, 0, 0);
    accel.refresh(cage, preview);
    int moved = 0;
    foreach (i; 0 .. preview.vertices.length) {
        if (preview.vertices[i] != before[i]) ++moved;
    }
    assert(moved > 0, "selective refresh did not move any preview vert");
}

// ---------------------------------------------------------------------------
// catmullClarkOsd — full pass.  One CC on the whole cube cage.
// 8 cage verts / 6 quads → 26 verts / 24 quads / 48 edges, no
// unmarked faces, no widening.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    Mesh refined = catmullClarkOsd(cage);
    assert(refined.vertices.length == 26, "L1 cube → 26 verts");
    assert(refined.faces.length    == 24, "L1 cube → 24 quads");
    assert(refined.edges.length    == 48, "L1 cube → 48 edges");
    foreach (face; refined.faces) assert(face.length == 4, "all quads");
}

// ---------------------------------------------------------------------------
// catmullClarkOsd — selective.  Mark one cube face, refine.  Marked
// face splits into 4 quads (4 face-pt, 4 edge-pt, 4 vert-pt). The 4
// adjacent un-marked side faces each get one OSD edge-point inserted
// into their vert list (T-junction widening) → quads become pentagons.
// The 1 opposite un-marked face stays a quad.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    bool[] mask = new bool[](cage.faces.length);
    mask[0] = true;   // mark cube face 0 only

    Mesh refined = catmullClarkOsd(cage, mask);

    // Faces: 4 sub-quads from face 0 + 4 widened pentagons + 1 unchanged quad
    assert(refined.faces.length == 9,
           "selective L1 cube → 4 sub + 4 widened + 1 unchanged");

    // Count face-vert counts: expect 4 quads + 4 pentagons + 1 quad
    int quads = 0, pentas = 0;
    foreach (face; refined.faces) {
        if (face.length == 4) ++quads;
        else if (face.length == 5) ++pentas;
    }
    assert(quads == 5, "expected 5 quads (4 sub + 1 opposite-face), got "
                       ~ quads.stringof);
    assert(pentas == 4, "expected 4 widened pentagons (one per side face)");
}
