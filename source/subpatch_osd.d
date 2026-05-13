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

/// Global gate for the GPU stencil evaluator. App.d flips this to true
/// after SDL+OpenGL are loaded and the smoke test passes; it stays
/// false in headless contexts (`dub test`, future CLI tools) so
/// OsdAccel.buildPreview doesn't try to call GL functions without a
/// context and segfault.
__gshared bool g_osdGpuEnabled = false;

/// Phase 3c — caller bundle of GPU VBO targets the GPU fan-out can
/// write to. Each (vbo, count) pair gates the corresponding fan-out
/// dispatch; passing 0 for any vbo opts out of that one. The caller
/// (app.d main loop) constructs this from gpu.{face,edge,vert}Vbo +
/// the matching counts before calling SubpatchPreview.rebuildIfStale.
struct GpuFanOutTargets {
    import bindbc.opengl : GLuint;
    GLuint faceVbo;       int faceVertCount;
    GLuint edgeVbo;       int edgeSegCount;
    GLuint vertVbo;       int vertCount;
}

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

// Fan-out shader — Phase 3b. Pulls OSD's per-limit-vert position
// output and emits the (xyz, xyz)-interleaved face-corner stream
// vibe3d's gpu.faceVbo expects, with flat normals computed on GPU.
// One transform-feedback dispatch (GL_POINTS, one shader invocation
// per face-corner) replaces the CPU readback that Phase 3a kept.
//
//   gl_VertexID                  → face-corner index (0..faceVertCount)
//   u_cornerToLimit[corner]      → limit-vert index for that corner
//   u_cornerToFaceId[corner]     → face id this corner belongs to
//   u_faceFirstVerts[3*fid+k]    → limit-vert indices of the face's
//                                  triangle-0 verts (drives flat normal)
//   u_limitPositions[limit]      → xyz from OSD GPU eval
//
// Output captured via GL_INTERLEAVED_ATTRIBS — sequential (vPos, vNorm)
// matches gpu.faceVbo's stride-6 layout exactly.
private immutable string FAN_OUT_VERT_SRC = q{
    #version 330 core
    uniform  isamplerBuffer u_cornerToLimit;
    uniform usamplerBuffer  u_cornerToFaceId;
    uniform  isamplerBuffer u_faceFirstVerts;
    uniform  samplerBuffer  u_limitPositions; // R32F: 3 floats per vert
    out vec3 vPos;
    out vec3 vNorm;
    vec3 fetchPos(int vi) {
        int   o = vi * 3;
        float x = texelFetch(u_limitPositions, o    ).r;
        float y = texelFetch(u_limitPositions, o + 1).r;
        float z = texelFetch(u_limitPositions, o + 2).r;
        return vec3(x, y, z);
    }
    void main() {
        int corner   = gl_VertexID;
        int limitIdx = texelFetch(u_cornerToLimit, corner).r;
        vPos         = fetchPos(limitIdx);

        int fid = int(texelFetch(u_cornerToFaceId, corner).r);
        int a   = texelFetch(u_faceFirstVerts, fid * 3 + 0).r;
        int b   = texelFetch(u_faceFirstVerts, fid * 3 + 1).r;
        int c   = texelFetch(u_faceFirstVerts, fid * 3 + 2).r;
        vec3 p0 = fetchPos(a);
        vec3 p1 = fetchPos(b);
        vec3 p2 = fetchPos(c);
        vec3 n  = cross(p1 - p0, p2 - p0);
        float l = length(n);
        vNorm   = l > 1e-6 ? n / l : vec3(0, 1, 0);
    }
};
// Empty fragment — rasterisation is disabled via GL_RASTERIZER_DISCARD;
// fragment shader exists only so the program links.
private immutable string FAN_OUT_FRAG_SRC = q{
    #version 330 core
    in vec3 vPos;
    in vec3 vNorm;
    void main() {}
};

// Single-output fan-out — Phase 3c. Used to fill edge / vert VBOs
// from OSD's per-limit-vert output. Same shape as the face fan-out
// but emits one vec3 per dispatch (per edge endpoint or per kept
// vert) instead of an interleaved pair. `u_indexLookup[gl_VertexID]`
// indirects through the caller-supplied TBO into `u_limitPositions`.
private immutable string POS_FAN_OUT_VERT_SRC = q{
    #version 330 core
    uniform isamplerBuffer u_indexLookup;
    uniform  samplerBuffer u_limitPositions; // R32F: 3 floats per vert
    out vec3 vPos;
    void main() {
        int   idx = texelFetch(u_indexLookup, gl_VertexID).r;
        int   o   = idx * 3;
        float x   = texelFetch(u_limitPositions, o    ).r;
        float y   = texelFetch(u_limitPositions, o + 1).r;
        float z   = texelFetch(u_limitPositions, o + 2).r;
        vPos      = vec3(x, y, z);
    }
};
private immutable string POS_FAN_OUT_FRAG_SRC = q{
    #version 330 core
    in vec3 vPos;
    void main() {}
};

private import bindbc.opengl;

/// Generic GLSL compile helper — returns 0 on failure, logging the
/// compile error to stderr.
private GLuint compileShaderStage(GLenum stage, string src) {
    import std.stdio  : stderr;
    import std.string : toStringz;
    import std.conv   : to;
    GLuint sh = glCreateShader(stage);
    const(char)* p = src.toStringz;
    GLint        len = cast(GLint)src.length;
    glShaderSource(sh, 1, &p, &len);
    glCompileShader(sh);
    GLint ok;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[1024] log;
        glGetShaderInfoLog(sh, 1024, null, log.ptr);
        try stderr.writeln("[osd fan-out] shader compile: ", log[].to!string);
        catch (Exception) {}
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

/// Link a vertex + fragment shader as a transform-feedback program
/// with the named varyings captured by the given buffer mode.
/// Returns 0 on failure.
private GLuint linkTfProgram(string vertSrc, string fragSrc,
                              const(char*)[] varyings,
                              GLenum bufferMode)
{
    import std.stdio : stderr;
    import std.conv  : to;
    GLuint vs = compileShaderStage(GL_VERTEX_SHADER,   vertSrc);
    if (!vs) return 0;
    GLuint fs = compileShaderStage(GL_FRAGMENT_SHADER, fragSrc);
    if (!fs) { glDeleteShader(vs); return 0; }
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glTransformFeedbackVaryings(prog, cast(GLsizei)varyings.length,
                                 varyings.ptr, bufferMode);
    glLinkProgram(prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[1024] log;
        glGetProgramInfoLog(prog, 1024, null, log.ptr);
        try stderr.writeln("[osd fan-out] program link: ", log[].to!string);
        catch (Exception) {}
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

/// Face-corner fan-out program — emits (vPos, vNorm) interleaved
/// matching gpu.faceVbo's stride-6 layout.
private GLuint compileFanOutProgram() {
    import std.string : toStringz;
    const(char)*[2] varyings = [ "vPos".toStringz, "vNorm".toStringz ];
    return linkTfProgram(FAN_OUT_VERT_SRC, FAN_OUT_FRAG_SRC,
                          varyings[], GL_INTERLEAVED_ATTRIBS);
}

/// Single-vec3 fan-out program — used for edge endpoint and kept-vert
/// position writes (Phase 3c). One output (vPos) captured per
/// dispatch.
private GLuint compilePosFanOutProgram() {
    import std.string : toStringz;
    const(char)*[1] varyings = [ "vPos".toStringz ];
    return linkTfProgram(POS_FAN_OUT_VERT_SRC, POS_FAN_OUT_FRAG_SRC,
                          varyings[], GL_INTERLEAVED_ATTRIBS);
}

struct OsdAccel {
    private osdc_topology_t*     osd;
    private osdc_gl_evaluator_t* glEval;        // null when no GL context

    // Phase 3a — readback path. cageGlVbo / limitGlVbo are also reused
    // by the Phase 3b fan-out path below (limitGlVbo is the source the
    // fan-out shader reads through limitTex).
    private GLuint               cageGlVbo;
    private GLuint               limitGlVbo;
    private float[]              cageScratchXyz;
    private float[]              limitScratchXyz;    // Phase 3a readback

    // Phase 3b — fan-out infrastructure. Built once at buildPreview;
    // refreshIntoFaceVbo dispatches a single TF draw per drag frame.
    private GLuint  cornerToLimitVbo;      // R32I  storage buffer
    private GLuint  cornerToLimitTex;      // TBO   view
    private GLuint  cornerToFaceIdVbo;     // R32UI storage
    private GLuint  cornerToFaceIdTex;
    private GLuint  faceFirstVertsVbo;     // R32I  storage (3 ints / face)
    private GLuint  faceFirstVertsTex;
    private GLuint  limitTex;              // R32F TBO over limitGlVbo (3 floats/vert)
    private GLuint  fanOutProgram;
    private GLint   locCornerToLimit;
    private GLint   locCornerToFaceId;
    private GLint   locFaceFirstVerts;
    private GLint   locLimitPositions;
    private int     faceVertCount;         // glDrawArrays count for TF

    // Phase 3c — edge VBO + vert VBO fan-out (single-vec3 capture).
    private GLuint  posFanOutProgram;
    private GLint   locPosIndexLookup;
    private GLint   locPosLimitPositions;
    private GLuint  edgeSegToLimitVbo;     // R32I storage
    private GLuint  edgeSegToLimitTex;     // TBO view
    private int     edgeSegCount;          // dispatch count for refreshEdgeVbo
    private GLuint  vertToLimitVbo;        // R32I storage
    private GLuint  vertToLimitTex;        // TBO view
    private int     keptVertCount;         // dispatch count for refreshVertVbo

    private int     limitVertCount;
    // Dedicated empty VAO for fan-out TF dispatches. We cannot reuse
    // the caller's VAO: that VAO typically has vertex attribs enabled
    // pointing AT gpu.faceVbo (for the normal rasterising draw), and
    // glDrawArrays during transform feedback raises GL_INVALID_OPERATION
    // when any enabled vertex-attrib buffer is also the TF write target
    // ("feedback loop"). A fresh VAO with no enabled attribs sidesteps
    // the loop check.
    private GLuint  tfVao;

    // ---- Scratch buffers re-used across rebuilds. ------------------
    // P0 of doc/subpatch_tab_perf_plan.md — every fresh `new T[]` in
    // buildPreview hit the global GC spinlock at 24K cage polys (top
    // sample at 10.5%). These slices keep their capacity across
    // clear() so a second rebuild at the same N does no allocation.
    // outMesh.faces[fi] is slice-aliased into scratchFaceIndices so the
    // per-face uint[] allocations disappear too.
    //
    // NOTE — outMesh.faces[fi] dangles if `scratchFaceIndices.length`
    // is set to 0 between buildPreview and the consumer's read. Don't
    // clear it in clear(); buildPreview is the only writer, and it
    // re-populates every fi before returning.
    private int[]  scratchFaceCounts;
    private int[]  scratchFaceIndicesI;     // OSD writes int; outMesh.faces views as uint
    private int[]  scratchEdgeVerts;
    private int[]  scratchFaceOrigins;
    private int[]  scratchVertOrigins;
    private int[]  scratchEdgeOrigins;
    private int[]  scratchOsdCageEdgeVerts;
    private uint[] scratchOsdToVibe3dCageEdge;
    private int[]  scratchCornerToLimit;
    private uint[] scratchCornerToFaceId;
    private int[]  scratchFaceFirstVerts;
    private int[]  scratchEdgeSegToLimit;
    private int[]  scratchVertToLimit;

    // P1: sorted (key, value) array replacing the uint[ulong]
    // vibe3dEdgeByVerts AA. With ~50K cage edges on a 24K-poly cage
    // the AA was 13% of CPU after P0 (top sample); a sorted-array +
    // binary search is ~3-5× faster per lookup and allocation-bounded.
    private struct EdgeKv { ulong key; uint value; }
    private EdgeKv[] scratchVibe3dEdgeKv;

    bool valid;

    /// Free everything. Idempotent.
    void clear() {
        if (glEval !is null) { osdc_gl_destroy(glEval); glEval = null; }
        if (cageGlVbo != 0)              { glDeleteBuffers (1, &cageGlVbo); cageGlVbo = 0; }
        if (limitGlVbo != 0)             { glDeleteBuffers (1, &limitGlVbo); limitGlVbo = 0; }
        if (cornerToLimitVbo != 0)       { glDeleteBuffers (1, &cornerToLimitVbo); cornerToLimitVbo = 0; }
        if (cornerToFaceIdVbo != 0)      { glDeleteBuffers (1, &cornerToFaceIdVbo); cornerToFaceIdVbo = 0; }
        if (faceFirstVertsVbo != 0)      { glDeleteBuffers (1, &faceFirstVertsVbo); faceFirstVertsVbo = 0; }
        if (cornerToLimitTex != 0)       { glDeleteTextures(1, &cornerToLimitTex); cornerToLimitTex = 0; }
        if (cornerToFaceIdTex != 0)      { glDeleteTextures(1, &cornerToFaceIdTex); cornerToFaceIdTex = 0; }
        if (faceFirstVertsTex != 0)      { glDeleteTextures(1, &faceFirstVertsTex); faceFirstVertsTex = 0; }
        if (limitTex != 0)               { glDeleteTextures(1, &limitTex); limitTex = 0; }
        if (tfVao != 0)                  { glDeleteVertexArrays(1, &tfVao); tfVao = 0; }
        if (fanOutProgram != 0)          { glDeleteProgram (fanOutProgram); fanOutProgram = 0; }
        if (posFanOutProgram != 0)       { glDeleteProgram (posFanOutProgram); posFanOutProgram = 0; }
        if (edgeSegToLimitVbo != 0)      { glDeleteBuffers (1, &edgeSegToLimitVbo); edgeSegToLimitVbo = 0; }
        if (edgeSegToLimitTex != 0)      { glDeleteTextures(1, &edgeSegToLimitTex); edgeSegToLimitTex = 0; }
        if (vertToLimitVbo != 0)         { glDeleteBuffers (1, &vertToLimitVbo); vertToLimitVbo = 0; }
        if (vertToLimitTex != 0)         { glDeleteTextures(1, &vertToLimitTex); vertToLimitTex = 0; }
        if (osd !is null) { osdc_topology_destroy(osd); osd = null; }
        cageScratchXyz.length  = 0;
        limitScratchXyz.length = 0;
        limitVertCount         = 0;
        faceVertCount          = 0;
        edgeSegCount           = 0;
        keptVertCount          = 0;
        valid                  = false;
    }

    /// Phase 3b only: true iff the fan-out path is set up and can be
    /// invoked via refreshIntoFaceVbo.
    @property bool canFanOut() const {
        return fanOutProgram != 0 && limitGlVbo != 0
            && cornerToLimitVbo != 0 && cornerToFaceIdVbo != 0
            && faceFirstVertsVbo != 0 && limitTex != 0;
    }

    /// Phase 3c: GPU fan-out for the edge / vert VBOs is available.
    /// Each independently gated — selective subpatch may produce an
    /// empty kept-edge or kept-vert set, in which case the dispatch
    /// count is 0 and the property reports false.
    @property bool canFanOutEdges() const {
        return posFanOutProgram != 0 && limitTex != 0
            && edgeSegToLimitTex != 0 && edgeSegCount > 0;
    }
    @property bool canFanOutVerts() const {
        return posFanOutProgram != 0 && limitTex != 0
            && vertToLimitTex != 0 && keptVertCount > 0;
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
        limitVertCount = limitVerts;

        // ---- Try to spin up the GL evaluator -------------------------
        // Gated on `g_osdGpuEnabled` — app.d sets it after GL init +
        // smoke-test succeeds. Without an active GL context (e.g.
        // `dub test` runs) osdc_gl_create would segfault, so we
        // simply skip and the refresh path stays on CPU eval.
        glEval = g_osdGpuEnabled ? osdc_gl_create(osd) : null;
        if (glEval !is null) {
            import bindbc.opengl;
            glGenBuffers(1, &cageGlVbo);
            glGenBuffers(1, &limitGlVbo);
            glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(3 * nv * float.sizeof),
                null, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, limitGlVbo);
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(3 * limitVerts * float.sizeof),
                null, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
            limitScratchXyz.length = 3 * limitVerts;
        }

        // ---- Read OSD limit topology + origin arrays -----------------
        // P0: scratch buffers live on OsdAccel; `.length = N` reuses
        // the underlying GC block when N ≤ historical max — eliminates
        // the per-rebuild `new int[]` allocations that dominated the
        // GC spinlock at 24K cage polys.
        scratchFaceCounts   .length = limitFaces;
        scratchFaceIndicesI .length = limitIndices;
        scratchEdgeVerts    .length = 2 * limitEdges;
        osdc_topology_limit_topology(osd,
            scratchFaceCounts   .ptr,
            scratchFaceIndicesI .ptr);
        osdc_topology_limit_edges   (osd, scratchEdgeVerts.ptr);

        scratchFaceOrigins  .length = limitFaces;
        scratchVertOrigins  .length = limitVerts;
        scratchEdgeOrigins  .length = limitEdges;
        osdc_topology_face_origins(osd, scratchFaceOrigins.ptr);
        osdc_topology_vert_origins(osd, scratchVertOrigins.ptr);
        osdc_topology_edge_origins(osd, scratchEdgeOrigins.ptr);

        // ---- Build preview Mesh.vertices via direct stencil eval -----
        // Preview Mesh.vertices is allocated fresh because it's
        // consumed by consumers outside OsdAccel (CPU readback into
        // preview.vertices via readLimitIntoPreview); aliasing into a
        // scratch buffer would surprise them.
        outMesh.vertices = new Vec3[](limitVerts);
        osdc_evaluate(osd, cageScratchXyz.ptr,
                      cast(float*)outMesh.vertices.ptr);

        // ---- Build preview Mesh.edges --------------------------------
        outMesh.edges.length = limitEdges;
        foreach (i; 0 .. limitEdges) {
            outMesh.edges[i] = [
                cast(uint)scratchEdgeVerts[2*i + 0],
                cast(uint)scratchEdgeVerts[2*i + 1],
            ];
        }

        // ---- Build preview Mesh.faces --------------------------------
        // P0: outMesh.faces[fi] slice-aliases into scratchFaceIndicesI.
        // Same bit layout (int vs uint, OSD always emits non-negative
        // vertex indices), zero per-face allocation. Readers of
        // outMesh.faces[fi] must not mutate via `[k] = ...` (would
        // overwrite scratch) — `~= x` is safe (it reallocates behind
        // the slice).
        outMesh.faces.length = limitFaces;
        auto scratchFacesAsUint = cast(uint[]) scratchFaceIndicesI;
        int cursor = 0;
        foreach (fi; 0 .. limitFaces) {
            int cnt = scratchFaceCounts[fi];
            outMesh.faces[fi] = scratchFacesAsUint[cursor .. cursor + cnt];
            cursor += cnt;
        }

        outMesh.mutationVersion = 1;
        outMesh.topologyVersion = 1;
        // Preview mesh is consumed by gpu.upload, drawEdges,
        // gpu_select, lasso — none of them query edgeIndexMap on the
        // preview, so we pass rebuildEdgeIndexMap=false to skip the
        // 786K-edge AA rebuild (was 10%+ of CPU before P2).
        outMesh.buildLoops(/*rebuildEdgeIndexMap=*/false);

        // ---- SubpatchTrace ------------------------------------------
        // OSD's `*_origins[i]` index INTO OSD's own cage enumeration,
        // not the caller's. For verts + faces the enumerations match
        // (we hand OSD vertex indices and face indices directly), but
        // OSD derives its edge list from the face-vertex topology and
        // assigns its own edge indices — those don't line up with
        // vibe3d's `cage.edges` (which is `addFace`-ordered). To make
        // edgeOrigin usable by the rest of vibe3d (drawEdges,
        // edgeOriginGpu lookup, the polygon-edge highlight cache) we
        // translate it via OSD's own input-edge vertex-pair table
        // plus a (min,max) vertex-pair → vibe3d-cage-edge map.
        outTrace.vertOrigin.length = limitVerts;
        outTrace.edgeOrigin.length = limitEdges;
        outTrace.faceOrigin.length = limitFaces;
        foreach (i; 0 .. limitVerts) {
            immutable int o = scratchVertOrigins[i];
            outTrace.vertOrigin[i] = (o < 0) ? uint.max : cast(uint)o;
        }
        foreach (i; 0 .. limitFaces)
            outTrace.faceOrigin[i] = cast(uint)scratchFaceOrigins[i];

        // Build OSD cage edge index → vibe3d cage edge index map.
        // Same key scheme as Mesh.edgeKey (min,max) → uint.
        immutable int osdCageEdges = osdc_topology_input_edge_count(osd);
        scratchOsdCageEdgeVerts.length = 2 * osdCageEdges;
        if (osdCageEdges > 0)
            osdc_topology_input_edges(osd, scratchOsdCageEdgeVerts.ptr);
        // P1: sorted (key, value) array instead of uint[ulong] AA.
        // build: O(n log n) sort over cage.edges (≈50K entries on a
        //        24K-poly cage). Single contiguous allocation in the
        //        scratch buffer, no per-entry GC hit.
        // lookup: 16-comparison binary search vs the AA's hash +
        //         pointer-chase + open-addressing probe.
        scratchVibe3dEdgeKv.length = cage.edges.length;
        foreach (ei, e; cage.edges) {
            uint a = e[0], b = e[1];
            ulong key = (cast(ulong)(a < b ? a : b) << 32)
                      |  cast(ulong)(a < b ? b : a);
            scratchVibe3dEdgeKv[ei] = EdgeKv(key, cast(uint)ei);
        }
        {
            import std.algorithm.sorting : sort;
            sort!"a.key < b.key"(scratchVibe3dEdgeKv);
        }

        scratchOsdToVibe3dCageEdge.length = osdCageEdges;
        scratchOsdToVibe3dCageEdge[0 .. osdCageEdges] = uint.max;
        foreach (oi; 0 .. osdCageEdges) {
            int a = scratchOsdCageEdgeVerts[2*oi + 0];
            int b = scratchOsdCageEdgeVerts[2*oi + 1];
            if (a < 0 || b < 0) continue;
            ulong key = (cast(ulong)(a < b ? a : b) << 32)
                      |  cast(ulong)(a < b ? b : a);
            // Manual lower-bound bsearch — std.range.assumeSorted
            // would do this but adds template overhead per call.
            size_t lo = 0, hi = scratchVibe3dEdgeKv.length;
            while (lo < hi) {
                size_t mid = (lo + hi) >> 1;
                if (scratchVibe3dEdgeKv[mid].key < key) lo = mid + 1;
                else                                    hi = mid;
            }
            if (lo < scratchVibe3dEdgeKv.length
                && scratchVibe3dEdgeKv[lo].key == key)
                scratchOsdToVibe3dCageEdge[oi] = scratchVibe3dEdgeKv[lo].value;
        }
        foreach (i; 0 .. limitEdges) {
            immutable int o = scratchEdgeOrigins[i];
            if (o < 0 || o >= osdCageEdges) {
                outTrace.edgeOrigin[i] = uint.max;
            } else {
                outTrace.edgeOrigin[i] = scratchOsdToVibe3dCageEdge[o];
            }
        }
        // Per-preview-face subpatch flag inherits from its cage parent.
        outTrace.subpatch         .length = limitFaces;
        outMesh.isSubpatch        .length = limitFaces;
        foreach (i; 0 .. limitFaces) {
            immutable int o = scratchFaceOrigins[i];
            bool parentMarked =
                (o >= 0) && (o < cast(int)cage.isSubpatch.length)
                && cage.isSubpatch[o];
            outTrace.subpatch [i] = parentMarked;
            outMesh .isSubpatch[i] = parentMarked;
        }

        outMesh.selectedVertices.length = limitVerts;
        outMesh.selectedEdges.length    = limitEdges;
        outMesh.selectedFaces.length    = limitFaces;

        // ---- Phase 3b: fan-out infrastructure -----------------------
        // Built only when the GL eval is alive (Phase 3a's glEval).
        // Three TBO storage buffers + one TBO view over limitGlVbo +
        // the compiled fan-out program. Iteration order MUST match
        // GpuMesh.upload's face-corner loop (face[0], face[i],
        // face[i+1] for i in 1..N-1) — that's what fanOut writes into.
        if (glEval !is null) {
            // P0: pre-compute total face-corner count so the corner
            // arrays are setLength()'d once instead of `~=`'d 3·N times
            // per face (393K faces × 3 corners × 2 arrays ≈ 2.4M
            // appends each rebuild).
            size_t cornerCount = 0;
            foreach (fi; 0 .. limitFaces) {
                immutable size_t fl = outMesh.faces[fi].length;
                if (fl >= 3) cornerCount += (fl - 2) * 3;
            }

            scratchCornerToLimit  .length =     cornerCount;
            scratchCornerToFaceId .length =     cornerCount;
            scratchFaceFirstVerts .length = 3 * limitFaces;

            size_t cw = 0;
            foreach (fi; 0 .. limitFaces) {
                const(uint)[] face = outMesh.faces[fi];
                scratchFaceFirstVerts[3*fi + 0] =
                    face.length >= 1 ? cast(int)face[0] : 0;
                scratchFaceFirstVerts[3*fi + 1] =
                    face.length >= 2 ? cast(int)face[1] : 0;
                scratchFaceFirstVerts[3*fi + 2] =
                    face.length >= 3 ? cast(int)face[2] : 0;
                if (face.length < 3) continue;
                for (uint i = 1; i + 1 < face.length; i++) {
                    scratchCornerToLimit [cw + 0] = cast(int)face[0];
                    scratchCornerToLimit [cw + 1] = cast(int)face[i];
                    scratchCornerToLimit [cw + 2] = cast(int)face[i + 1];
                    scratchCornerToFaceId[cw + 0] = cast(uint)fi;
                    scratchCornerToFaceId[cw + 1] = cast(uint)fi;
                    scratchCornerToFaceId[cw + 2] = cast(uint)fi;
                    cw += 3;
                }
            }
            faceVertCount = cast(int)cw;

            if (faceVertCount > 0) {
                // Allocate storage buffers + bind TBO views (one
                // texture-buffer texture per uniform sampler in the
                // fan-out shader).
                void uploadTbo(R, F)(ref GLuint vbo, ref GLuint tex,
                                      R[] data, F fmt)
                {
                    glGenBuffers(1, &vbo);
                    glBindBuffer(GL_TEXTURE_BUFFER, vbo);
                    glBufferData(GL_TEXTURE_BUFFER,
                        cast(GLsizeiptr)(data.length * R.sizeof),
                        data.ptr, GL_STATIC_DRAW);
                    glGenTextures(1, &tex);
                    glBindTexture(GL_TEXTURE_BUFFER, tex);
                    glTexBuffer(GL_TEXTURE_BUFFER, fmt, vbo);
                }

                uploadTbo(cornerToLimitVbo,   cornerToLimitTex,
                          scratchCornerToLimit[0 .. faceVertCount],
                                                           GL_R32I);
                uploadTbo(cornerToFaceIdVbo,  cornerToFaceIdTex,
                          scratchCornerToFaceId[0 .. faceVertCount],
                                                           GL_R32UI);
                uploadTbo(faceFirstVertsVbo,  faceFirstVertsTex,
                          scratchFaceFirstVerts[0 .. 3 * limitFaces],
                                                           GL_R32I);

                // limitGlVbo already exists (Phase 3a allocation).
                // Wrap it in a TBO view so the shader can texelFetch.
                glGenTextures(1, &limitTex);
                glBindTexture(GL_TEXTURE_BUFFER, limitTex);
                // R32F (not RGB32F) so the limit position buffer
                // works on any GL 3.3 driver — RGB32F texture-buffer
                // format requires ARB_texture_buffer_object_rgb32 and
                // wasn't reliably present on older Mesa stacks.
                // Shader does three texelFetch calls per position
                // (index*3 + 0/1/2) instead of one rgb fetch.
                glTexBuffer(GL_TEXTURE_BUFFER, GL_R32F, limitGlVbo);

                glBindBuffer (GL_TEXTURE_BUFFER, 0);
                glBindTexture(GL_TEXTURE_BUFFER, 0);

                // Empty VAO for the fan-out TF dispatch — see tfVao
                // field comment for why the caller's VAO can't be
                // reused.
                glGenVertexArrays(1, &tfVao);

                fanOutProgram = compileFanOutProgram();
                if (fanOutProgram != 0) {
                    locCornerToLimit   = glGetUniformLocation(
                        fanOutProgram, "u_cornerToLimit");
                    locCornerToFaceId  = glGetUniformLocation(
                        fanOutProgram, "u_cornerToFaceId");
                    locFaceFirstVerts  = glGetUniformLocation(
                        fanOutProgram, "u_faceFirstVerts");
                    locLimitPositions  = glGetUniformLocation(
                        fanOutProgram, "u_limitPositions");
                }
            }

            // ---- Phase 3c — edge + vert VBO fan-out lookups ----------
            // Two more TBOs and a one-output shader. Iteration order
            // MUST match GpuMesh.upload's edge / vert walks (kept-
            // entry sequence, filtered by trace.{edge,vert}Origin).
            {
                // P0: pre-count kept edges + kept verts so the lookup
                // arrays are setLength()'d once instead of `~=`'d
                // through 800K+ edges / 400K+ verts per rebuild.
                size_t keptEdges = 0;
                foreach (ei; 0 .. outMesh.edges.length) {
                    immutable uint eo = ei < outTrace.edgeOrigin.length
                                        ? outTrace.edgeOrigin[ei] : uint.max;
                    if (eo != uint.max) ++keptEdges;
                }
                size_t keptVerts = 0;
                foreach (pi; 0 .. limitVerts) {
                    immutable uint vo = pi < outTrace.vertOrigin.length
                                        ? outTrace.vertOrigin[pi] : uint.max;
                    if (vo != uint.max) ++keptVerts;
                }
                scratchEdgeSegToLimit.length = 2 * keptEdges;
                scratchVertToLimit   .length =     keptVerts;

                size_t ew = 0;
                foreach (ei, e; outMesh.edges) {
                    immutable uint eo = ei < outTrace.edgeOrigin.length
                                        ? outTrace.edgeOrigin[ei] : uint.max;
                    if (eo == uint.max) continue;
                    scratchEdgeSegToLimit[ew + 0] = cast(int)e[0];
                    scratchEdgeSegToLimit[ew + 1] = cast(int)e[1];
                    ew += 2;
                }
                size_t vw = 0;
                foreach (pi; 0 .. limitVerts) {
                    immutable uint vo = pi < outTrace.vertOrigin.length
                                        ? outTrace.vertOrigin[pi] : uint.max;
                    if (vo == uint.max) continue;
                    scratchVertToLimit[vw++] = cast(int)pi;
                }
                edgeSegCount  = cast(int)ew;
                keptVertCount = cast(int)vw;

                void uploadIntTbo(ref GLuint vbo, ref GLuint tex,
                                   int[] data)
                {
                    if (data.length == 0) return;
                    glGenBuffers(1, &vbo);
                    glBindBuffer(GL_TEXTURE_BUFFER, vbo);
                    glBufferData(GL_TEXTURE_BUFFER,
                        cast(GLsizeiptr)(data.length * int.sizeof),
                        data.ptr, GL_STATIC_DRAW);
                    glGenTextures(1, &tex);
                    glBindTexture(GL_TEXTURE_BUFFER, tex);
                    glTexBuffer(GL_TEXTURE_BUFFER, GL_R32I, vbo);
                }
                uploadIntTbo(edgeSegToLimitVbo, edgeSegToLimitTex,
                              scratchEdgeSegToLimit[0 .. edgeSegCount]);
                uploadIntTbo(vertToLimitVbo,    vertToLimitTex,
                              scratchVertToLimit[0 .. keptVertCount]);
                glBindBuffer (GL_TEXTURE_BUFFER, 0);
                glBindTexture(GL_TEXTURE_BUFFER, 0);

                posFanOutProgram = compilePosFanOutProgram();
                if (posFanOutProgram != 0) {
                    locPosIndexLookup    = glGetUniformLocation(
                        posFanOutProgram, "u_indexLookup");
                    locPosLimitPositions = glGetUniformLocation(
                        posFanOutProgram, "u_limitPositions");
                }
            }
        }

        valid = true;
        return true;
    }

    /// Phase 3b — replace gpu.faceVbo's positions+normals via GPU eval
    /// + transform-feedback fan-out. Single shader dispatch per drag
    /// frame; no CPU readback. `preview.vertices` is NOT updated.
    ///
    /// Caller passes vibe3d's gpu.faceVbo. The fan-out writes exactly
    /// `faceVertCount` interleaved (xyz pos + xyz normal) vertices
    /// starting at offset 0 — same layout the regular gpu.upload
    /// produces, so subsequent draws don't need anything else.
    ///
    /// `expectedFaceVertCount` MUST match the caller's gpu.faceVertCount
    /// — i.e. the same preview-topology pass that built this OsdAccel
    /// also produced the caller's face VBO. If they diverge we bail to
    /// the false return so the caller falls back to CPU + gpu.upload.
    ///
    /// Returns true iff the fan-out actually ran. false → caller MUST
    /// fall back (e.g. call refresh + the standard gpu.upload path).
    bool refreshIntoFaceVbo(ref const Mesh cage,
                             GLuint targetFaceVbo,
                             int expectedFaceVertCount)
    {
        if (!canFanOut) return false;
        if (targetFaceVbo == 0) return false;
        if (expectedFaceVertCount != faceVertCount) return false;
        if (cage.vertices.length * 3 != cageScratchXyz.length) return false;

        // Pack + upload current cage positions.
        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }
        glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(cageScratchXyz.length * float.sizeof),
            cageScratchXyz.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, 0);

        if (!osdc_gl_evaluate(glEval, cageGlVbo, limitGlVbo))
            return false;

        // Save GL state we touch. The TEXTURE_BUFFER target itself is
        // not queried — vibe3d's renderer doesn't bind it, so leakage
        // is benign and the query symbol isn't exposed in bindbc-
        // opengl's GL_33 surface anyway.
        GLint prevProgram, prevVao, prevArrayBuf;
        GLint prevActiveTex;
        GLint prevTex0, prevTex1, prevTex2, prevTex3;
        glGetIntegerv(GL_CURRENT_PROGRAM,             &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING,        &prevVao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,        &prevArrayBuf);
        glGetIntegerv(GL_ACTIVE_TEXTURE,              &prevActiveTex);

        glUseProgram(fanOutProgram);

        // Bind the four TBO views to texture units 0..3 and set the
        // sampler uniforms.
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex0);
        glBindTexture(GL_TEXTURE_BUFFER, cornerToLimitTex);
        glUniform1i(locCornerToLimit, 0);

        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex1);
        glBindTexture(GL_TEXTURE_BUFFER, cornerToFaceIdTex);
        glUniform1i(locCornerToFaceId, 1);

        glActiveTexture(GL_TEXTURE2);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex2);
        glBindTexture(GL_TEXTURE_BUFFER, faceFirstVertsTex);
        glUniform1i(locFaceFirstVerts, 2);

        glActiveTexture(GL_TEXTURE3);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex3);
        glBindTexture(GL_TEXTURE_BUFFER, limitTex);
        glUniform1i(locLimitPositions, 3);

        // No vertex attributes are read — TF dispatch is driven by
        // gl_VertexID. Bind a dedicated empty VAO: the caller's VAO
        // usually has attribs enabled pointing at gpu.faceVbo (for
        // the normal raster draw of the surface), but gpu.faceVbo is
        // also our TF write target on this dispatch — and GL raises
        // GL_INVALID_OPERATION on glDrawArrays under transform
        // feedback when any enabled attribute references the TF
        // output buffer (feedback loop). tfVao has no enabled
        // attribs, so the loop check passes.
        glBindVertexArray(tfVao);

        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetFaceVbo);
        glEnable(GL_RASTERIZER_DISCARD);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, faceVertCount);
        glEndTransformFeedback();
        glDisable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);

        // Restore GL state.
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex3);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex2);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex0);
        glActiveTexture(cast(GLuint)prevActiveTex);
        glBindBuffer(GL_ARRAY_BUFFER,   cast(GLuint)prevArrayBuf);
        glUseProgram(cast(GLuint)prevProgram);
        glBindVertexArray(cast(GLuint)prevVao);
        return true;
    }

    /// Phase 3c — shared single-vec3 TF dispatch. Used by
    /// refreshEdgeVbo and refreshVertVbo. Reads `indexLookupTex`'s
    /// per-output entry → fetches from limitTex → writes one vec3
    /// into `targetVbo` at offset 0. Assumes refreshIntoFaceVbo
    /// already ran in this frame (limitGlVbo populated).
    private bool runPosFanOut(GLuint indexLookupTex,
                               GLuint targetVbo,
                               int dispatchCount)
    {
        if (posFanOutProgram == 0 || limitTex == 0
            || indexLookupTex == 0 || targetVbo == 0
            || dispatchCount <= 0)
            return false;

        GLint prevProgram, prevVao, prevArrayBuf;
        GLint prevActiveTex, prevTex0, prevTex1;
        glGetIntegerv(GL_CURRENT_PROGRAM,       &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING,  &prevVao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,  &prevArrayBuf);
        glGetIntegerv(GL_ACTIVE_TEXTURE,        &prevActiveTex);

        glUseProgram(posFanOutProgram);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex0);
        glBindTexture(GL_TEXTURE_BUFFER, indexLookupTex);
        glUniform1i(locPosIndexLookup, 0);
        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_BUFFER, &prevTex1);
        glBindTexture(GL_TEXTURE_BUFFER, limitTex);
        glUniform1i(locPosLimitPositions, 1);

        // Empty VAO — same feedback-loop concern as refreshIntoFaceVbo;
        // gpu.edgeVao / gpu.vertVao both have attribs pointing at the
        // VBOs we'd be writing.
        glBindVertexArray(tfVao);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetVbo);
        glEnable(GL_RASTERIZER_DISCARD);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, dispatchCount);
        glEndTransformFeedback();
        glDisable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_BUFFER, cast(GLuint)prevTex0);
        glActiveTexture(cast(GLuint)prevActiveTex);
        glBindBuffer(GL_ARRAY_BUFFER, cast(GLuint)prevArrayBuf);
        glUseProgram(cast(GLuint)prevProgram);
        glBindVertexArray(cast(GLuint)prevVao);
        return true;
    }

    /// Phase 3c — fill caller's edge VBO directly from limitGlVbo.
    /// Requires refreshIntoFaceVbo (or any path that ran the GPU
    /// stencil eval) to have populated limitGlVbo this frame.
    /// `expectedSegmentCount` must match the kept-edge segment count
    /// (= 2 × num-kept-edges) recorded at buildPreview.
    bool refreshEdgeVbo(GLuint targetEdgeVbo, int expectedSegmentCount) {
        if (!canFanOutEdges) return false;
        if (expectedSegmentCount != edgeSegCount) return false;
        return runPosFanOut(edgeSegToLimitTex,
                             targetEdgeVbo, edgeSegCount);
    }

    /// Phase 3c — fill caller's vert VBO directly from limitGlVbo.
    /// `expectedVertCount` must match kept-vert count from buildPreview.
    bool refreshVertVbo(GLuint targetVertVbo, int expectedVertCount) {
        if (!canFanOutVerts) return false;
        if (expectedVertCount != keptVertCount) return false;
        return runPosFanOut(vertToLimitTex,
                             targetVertVbo, keptVertCount);
    }

    /// Hot per-frame call: re-eval OSD's stencils against the current
    /// cage positions and write the limit positions into
    /// `preview.vertices`. Routes through the GPU evaluator when one
    /// was built at `buildPreview` time; falls back to CPU otherwise.
    void refresh(ref const Mesh cage, ref Mesh preview) {
        assert(valid, "OsdAccel.refresh called on invalid accel");
        assert(cage.vertices.length * 3 == cageScratchXyz.length,
               "cage vert count changed without buildPreview");

        foreach (vi, v; cage.vertices) {
            cageScratchXyz[3*vi + 0] = v.x;
            cageScratchXyz[3*vi + 1] = v.y;
            cageScratchXyz[3*vi + 2] = v.z;
        }

        if (glEval !is null && cageGlVbo != 0 && limitGlVbo != 0) {
            refreshViaGpu(preview);
        } else {
            osdc_evaluate(osd, cageScratchXyz.ptr,
                          cast(float*)preview.vertices.ptr);
        }
    }

    /// GPU eval path. Pumps cage positions into the cage VBO, runs
    /// OSD's transform-feedback stencil kernel into the limit VBO,
    /// then reads the limit positions back into preview.vertices so
    /// existing consumers (gpu.upload, picking, drawing) see the
    /// new positions unchanged.
    private void refreshViaGpu(ref Mesh preview) {
        import bindbc.opengl;
        glBindBuffer(GL_ARRAY_BUFFER, cageGlVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(cageScratchXyz.length * float.sizeof),
            cageScratchXyz.ptr);

        int ok = osdc_gl_evaluate(glEval, cageGlVbo, limitGlVbo);
        if (!ok) {
            // GPU eval failed at runtime (shader compile lost between
            // create and now?). One-time fall back to CPU eval —
            // dropping the GL state so subsequent calls take the CPU
            // path until buildPreview re-runs.
            osdc_gl_destroy(glEval);
            glEval = null;
            osdc_evaluate(osd, cageScratchXyz.ptr,
                          cast(float*)preview.vertices.ptr);
            return;
        }

        readLimitIntoPreview(preview);
    }

    /// Phase 3b — readback limitGlVbo into preview.vertices WITHOUT
    /// re-running the GPU eval. Used after refreshIntoFaceVbo (which
    /// already populated limitGlVbo via osdc_gl_evaluate) to keep
    /// preview.vertices fresh for CPU-side consumers (edge / vert
    /// VBO refresh inside refreshNonFacePositions, lasso-vis test,
    /// debug overlays) — avoids the redundant second eval that
    /// `refresh(cage, preview)` would do.
    void readLimitIntoPreview(ref Mesh preview) {
        import bindbc.opengl;
        if (limitGlVbo == 0) return;
        if (preview.vertices.length != limitVertCount) return;
        glBindBuffer(GL_ARRAY_BUFFER, limitGlVbo);
        glGetBufferSubData(GL_ARRAY_BUFFER, 0,
            cast(GLsizeiptr)(preview.vertices.length * Vec3.sizeof),
            preview.vertices.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
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
// trace.edgeOrigin must index INTO THE CALLER'S cage edge table, not
// OSD's internal edge enumeration. The two can differ — OSD derives
// its edge list from the face-vertex topology and assigns its own
// indices, while vibe3d's cage.edges is `addFace`-ordered.
//
// drawEdges' polygon-edge highlight looks up
//   selectedEdges[edgeOriginGpu[segIdx]]
// where `selectedEdges` is indexed by vibe3d cage edge. If the
// origin chain hands OSD's index through, the wrong cage edges get
// highlighted. Verified topologically at depth 1, where each cage
// edge subdivides into exactly two preview edges that BOTH have
// the same edgeOrigin and BOTH share an endpoint with vertOrigin
// matching one of the cage edge's two cage vertices.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    cage.isSubpatch.length = cage.faces.length;
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    OsdAccel       accel;
    Mesh           preview;
    SubpatchTrace  trace;
    bool ok = accel.buildPreview(cage, 1, preview, trace);
    assert(ok && accel.valid, "OsdAccel.buildPreview failed");

    // Each cage edge X = (u, v) should produce exactly two preview
    // edges with edgeOrigin == X. Topology after one CC pass: the
    // edge splits at its midpoint M, giving (u, M) and (M, v).
    //   • Both halves have edgeOrigin = X.
    //   • One half's endpoint set contains u (in vertOrigin); the
    //     other half's contains v. M itself has vertOrigin = uint.max
    //     (newly introduced edge-point).
    int[uint] cagePreviewEdgeCount;
    bool[uint] sawCageVertU;   // saw an endpoint with vertOrigin == u
    bool[uint] sawCageVertV;   // saw an endpoint with vertOrigin == v

    foreach (pei, pe; preview.edges) {
        uint origin = pei < trace.edgeOrigin.length
                       ? trace.edgeOrigin[pei] : uint.max;
        if (origin == uint.max) continue;
        assert(origin < cage.edges.length,
               "trace.edgeOrigin out of range for the cage edge table");
        cagePreviewEdgeCount[origin] =
            cagePreviewEdgeCount.get(origin, 0) + 1;

        uint cu = cage.edges[origin][0];
        uint cv = cage.edges[origin][1];
        foreach (vpi; [pe[0], pe[1]]) {
            uint vo = vpi < trace.vertOrigin.length
                       ? trace.vertOrigin[vpi] : uint.max;
            if (vo == cu) sawCageVertU[origin] = true;
            if (vo == cv) sawCageVertV[origin] = true;
        }
    }

    assert(cagePreviewEdgeCount.length == cage.edges.length,
        "expected every cage edge to appear in some preview edge's "
        ~ "edgeOrigin");
    foreach (cei; 0 .. cage.edges.length) {
        uint k = cast(uint)cei;
        assert(cagePreviewEdgeCount[k] == 2,
            "cage edge with vibe3d index in [0..12) should have "
            ~ "exactly 2 preview halves at depth 1");
        assert(sawCageVertU.get(k, false) && sawCageVertV.get(k, false),
            "the two preview halves of a cage edge must between "
            ~ "them touch both of the cage edge's endpoints");
    }
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
