// mesh_gpu.d — GpuMesh: the OpenGL upload/draw target for a cage Mesh
// (VAO/VBO handles + upload/refresh/draw over a `const Mesh`).
//
// Extracted verbatim from mesh.d (task 0425, campaign 0407 — last mesh.d
// structural split). One-way dependency mesh_gpu → mesh: GpuMesh consumes
// the `const Mesh` PUBLIC API only (vertices/edges/faces/faceMaterial/
// mutationVersion), so no visibility widening was needed. mesh.d re-exports
// GpuMesh via `public import` so every existing `import mesh;` /
// `import mesh : GpuMesh;` call site resolves unchanged — same facade
// pattern as source/handler.d (task 0423).
module mesh_gpu;

import bindbc.opengl;
import std.math : sqrt;
import math;    // Vec3
import shader;  // LitShader
import mesh;    // Mesh, FaceList
import change_bus : MeshEditScope;  // Position class for the preview-refresh publish
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters

// ---------------------------------------------------------------------------
// The HIDE skip predicate (task 0613 S3, doc/hide_geometry_plan.md)
// ---------------------------------------------------------------------------
//
// Hidden geometry leaves the GPU buffers ONCE, at BUILD time. Everything
// downstream is then free: the viewport draw calls submit prebuilt buffers,
// and gpu_select.renderMode renders the very same VBOs — so one filter here
// takes hidden geometry out of the picture, out of the ID buffer AND out of
// the ID buffer's depth pre-pass (which is what stops the hidden front of a
// model occluding the back of it).
//
// Three named predicates rather than three inline `mesh.isXHidden(i)` calls,
// because the SAME predicate has to hold in FOUR builders — `upload`,
// `refreshPositions`, `refreshNonFacePositions` and `uploadSelectedVertices`
// — and any pair of them disagreeing corrupts a live VBO mid-drag (R2). A
// name is greppable; an inlined condition is a thing the fifth builder
// forgets.
//
// `mesh` is whichever mesh this GpuMesh was handed — the cage, or the subpatch
// preview, whose Hide planes subpatch_osd.d stamps from the cage at build
// time. So there is no new parameter and no new call-site obligation across
// upload's 81 call sites.
//
// Faces do NOT use `continue`: a hidden face KEEPS its VBO slot with
// faceTriCount == 0 (R3), exactly like the degenerate-face branch, because
// faceTriStart.length == mesh.faces.length is the invariant the picker's
// `maxId` and faceOriginGpu both rest on.
private bool hideSkipFace(ref const Mesh mesh, size_t fi) {
    return mesh.isFaceHidden(fi);
}
private bool hideSkipEdge(ref const Mesh mesh, size_t ei) {
    return mesh.isEdgeHidden(ei);
}
private bool hideSkipVertex(ref const Mesh mesh, size_t vi) {
    return mesh.isVertexHidden(vi);
}

// ---------------------------------------------------------------------------
// BaseWire — how `GpuMesh.drawEdges` should render its BASE line pass
// ---------------------------------------------------------------------------

/// The base-wireframe knobs for `drawEdges`, task 0559.
///
/// `drawEdges` draws up to three things: a depth-tested pass over the plain
/// (unselected, unhovered) segments, then two depth-disabled passes for the
/// selected and hovered ones. Only the FIRST of those is the wireframe
/// overlay. The other two are selection and hover feedback — separate display
/// axes that must keep working when the overlay is switched off.
///
/// This struct therefore addresses the base pass alone. Defaults reproduce
/// the historical behaviour exactly (drawn, fully opaque, no blending), so
/// every existing call site is unchanged by omitting the argument.
struct BaseWire {
    /// Draw the base line pass at all.
    bool  draw     = true;
    /// Location of the flat shader's `u_alpha`. Negative means the bound
    /// program has no opacity uniform, in which case `alpha` is ignored
    /// rather than silently writing to uniform slot -1.
    GLint locAlpha = -1;
    /// Base-line opacity, 0..1. Anything below 1.0 turns blending on for the
    /// duration of the base pass only.
    float alpha    = 1.0f;
}

// ---------------------------------------------------------------------------
// GpuMesh
// ---------------------------------------------------------------------------

struct GpuMesh {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    GLuint vertVao, vertVbo;   // vertex points
    int    faceVertCount;
    int    edgeVertCount;
    int    vertCount;
    int[]  faceTriStart;   // first vertex index in faceVbo for each face
    int[]  faceTriCount;   // vertex count for each face
    // When true the main loop owns GPU uploads (because a subpatch preview
    // is currently displayed). Tool-side cage uploads become no-ops that
    // only bump the mesh's mutation version so the preview is rebuilt.
    bool   suppressCageUpload;
    // Maps each VBO line-segment to a source (cage) edge index when a
    // subpatch preview was uploaded. Empty for cage uploads, in which case
    // drawEdges assumes VBO segment i == cage edge i.
    uint[] edgeOriginGpu;
    // Maps each VBO face (position in faceTriStart/Count) to its cage face
    // index. Populated for subpatch uploads; empty in cage mode.
    uint[] faceOriginGpu;
    // Maps each vertex VBO entry to a source (cage) vertex index. In cage
    // mode VBO index == cage vertex index. In subpatch mode entries with
    // `vertOrigin[vi] == uint.max` were skipped during upload, so this
    // map translates back. Used by gpu_select.d for vertex picking.
    uint[] vertOriginGpu;
    // Per-triangle-vertex source face index, parallel to faceVbo (one
    // uint per face-VBO vertex). All three corners of a face's triangle
    // fan get the same face index. Drives gpu_select.d's face-ID pass.
    GLuint faceIdVbo;
    // Material Groups (MG3): per-triangle-vertex material index, parallel
    // to faceVbo. All three corners of a face's triangle fan get
    // mesh.faceMaterial[fi] (with a defensive 0 fallback). The lit
    // shader binds this at attrib location 2 with `flat in uint` so the
    // provoking-vertex value applies to the whole triangle.
    GLuint matIdVbo;

    // Bumps on every VBO write (full upload, refreshPositions, partial
    // uploadSelectedVertices). Distinct from Mesh.mutationVersion: the
    // transform tools (Move / Rotate / Scale) mutate `mesh.vertices`
    // directly during drag WITHOUT bumping mutationVersion, on purpose
    // (symmetry pair-table / falloff caches must stay stable mid-drag,
    // see TransformTool.captureSymmetryForDrag). That leaves the picker
    // FBO cache stale w.r.t. the actual GPU buffers — gpu_select.d
    // keys on `uploadVersion` instead so it re-renders whenever the
    // VBO contents change, regardless of whether the structural mesh
    // version moved.
    ulong  uploadVersion;

    // P3: scratch buffers re-used across upload() calls. Pre-sized to
    // the exact final length via a counting pre-pass, then filled by
    // index write — kills the per-face / per-corner `~=` cascades
    // (was ~2.4 M float appends + 393 K uint appends on a 24 K cage
    // / depth-2 preview, dominated by literal-array allocations).
    private float[] scratchFaceData;
    private uint[]  scratchFaceIdData;
    private uint[]  scratchMatIdData;
    private float[] scratchEdgeData;
    private float[] scratchVertData;

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
        glGenBuffers(1, &faceIdVbo);
        glGenBuffers(1, &matIdVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
        glDeleteBuffers(1, &faceIdVbo);
        glDeleteBuffers(1, &matIdVbo);
    }

    // When `edgeOrigin`/`vertOrigin` are provided (same length as the mesh's
    // edges/vertices) entries equal to `uint.max` are skipped. This is how
    // the subpatch preview hides derived edges/points while still uploading
    // the full subdivided face surface. `faceOrigin` does not filter (every
    // preview face is rendered) but when supplied is cached in
    // `faceOriginGpu` so selection/hover can translate cage indices.
    //
    // A SECOND filter, independent of those parameters, runs on every path:
    // elements carrying `Mesh.Marks.Hide` are dropped (task 0613 S3 — see the
    // hideSkip* predicates at the top of this module). It reads the Hide plane
    // off whichever mesh it was handed, so a cage upload filters by the cage's
    // marks and a preview upload by the preview's, which subpatch_osd.d
    // stamped from the cage. Hidden edges/verts leave the buffer entirely;
    // hidden FACES keep their slot with `faceTriCount == 0`.
    void upload(ref const Mesh mesh,
                const uint[] edgeOrigin = null,
                const uint[] vertOrigin = null,
                const uint[] faceOrigin = null) {
        // Redirect tool-side cage refreshes: the GPU buffers currently hold
        // the preview, and the main loop owns re-uploads. A tool moved cage
        // positions and asked to refresh — PUBLISH that as a Position change
        // on the notification bus, not a bare mutationVersion bump (task 0462).
        //
        // Why a bare bump is wrong: the subpatch-preview rebuild is gated on
        // the bus FLAG (`meshChangedFlags & (Position|Geometry|Marks)`, see the
        // rebuildIfStale call in app.d), NOT on mutationVersion. A version-only
        // bump therefore triggers the main loop's GPU RE-UPLOAD
        // (`gpuUploadedVersion != mutationVersion`) of a preview that was never
        // REBUILT against the moved cage — the displayed surface goes stale /
        // shifts, and the debug build trips the `change_bus: MISSED PUBLISHER`
        // guard (mutationVersion advanced with no pending change flags).
        // commitChange(Position) sets the flag AND bumps mutationVersion, so
        // the preview rebuilds and the re-upload still fires.
        if (suppressCageUpload && edgeOrigin.length == 0 && vertOrigin.length == 0) {
            (cast(Mesh*)&mesh).commitChange(MeshEditScope.Position);
            return;
        }
        ++uploadVersion;
        // Counted AFTER the suppress/layout-mismatch early-returns above, so
        // `uploadCalls` means uploads that actually touched a buffer, not
        // upload REQUESTS. `uploadVerts` is the mesh's vertex count, i.e. the
        // size of the data this path is responsible for — not the byte count,
        // which differs per buffer and would need four separate sums to state
        // honestly.
        g_fc.upload(cast(long)mesh.vertices.length);
        enum FACE_STRIDE = 6;

        // P3 counting pre-pass: derive exact final sizes for the four
        // scratch buffers so the fill phase can index-write instead
        // of `~=`.
        size_t totalFaceCorners = 0;
        foreach (fi, face; mesh.faces)
            if (face.length >= 3 && !hideSkipFace(mesh, fi))
                totalFaceCorners += (face.length - 2) * 3;
        size_t totalEdgeKeep = 0;
        // "The edge VBO is no longer 1:1 with the mesh's edges." Drives the
        // CONDITIONAL edgeOriginGpu population below — see the long comment
        // there for why this must NOT become unconditional.
        bool anyEdgeSkipped = false;
        foreach (ei; 0 .. mesh.edges.length) {
            if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max) {
                anyEdgeSkipped = true;
                continue;
            }
            if (hideSkipEdge(mesh, ei)) {
                anyEdgeSkipped = true;
                continue;
            }
            ++totalEdgeKeep;
        }
        size_t totalVertKeep = 0;
        foreach (vi; 0 .. mesh.vertices.length) {
            if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max) continue;
            if (hideSkipVertex(mesh, vi)) continue;
            ++totalVertKeep;
        }

        // ── Faces — interleaved [pos(3)+normal(3)], flat shading. ──
        // P5: only call setLength when we need to grow on the float
        // buffers (D runtime's `_d_arraysetlength` was 7.88 % of CPU
        // after P3 — every call consults GC block metadata even when
        // capacity is sufficient). The 30-tab harness alternates
        // small (cage tear-down) and large (preview-on) uploads;
        // pinning the high-water capacity avoids the per-call
        // metadata round-trip. Writers index up to the exact required
        // length via the `*VertCount` fields below; GL upload sizes
        // are derived from those counts, not from `scratch*.length`.
        immutable size_t needFaceFloats = totalFaceCorners * FACE_STRIDE;
        if (scratchFaceData  .length < needFaceFloats)
            scratchFaceData  .length = needFaceFloats;
        if (scratchFaceIdData.length < totalFaceCorners)
            scratchFaceIdData.length = totalFaceCorners;
        if (scratchMatIdData.length < totalFaceCorners)
            scratchMatIdData.length = totalFaceCorners;
        faceTriStart.length = mesh.faces.length;
        faceTriCount.length = mesh.faces.length;
        faceOriginGpu    .length = 0;
        if (faceOrigin.length > 0) {
            faceOriginGpu.length = faceOrigin.length;
            faceOriginGpu[] = faceOrigin[];
        }
        {
            size_t fw = 0;
            foreach (fi, face; mesh.faces) {
                faceTriStart[fi] = cast(int)fw;
                // Degenerate OR hidden: keep the slot, contribute no
                // triangles. Same branch, deliberately (R3) — a hidden face
                // must stay addressable by its cage index for the ID picker.
                if (face.length < 3 || hideSkipFace(mesh, fi)) {
                    faceTriCount[fi] = 0;
                    continue;
                }
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[1]];
                Vec3 v2 = mesh.vertices[face[2]];
                float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                float cx = ay*bz - az*by;
                float cy = az*bx - ax*bz;
                float cz = ax*by - ay*bx;
                float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                float nx, ny, nz;
                if (nlen > 1e-6f) {
                    float inv = 1.0f / nlen;
                    nx = cx*inv; ny = cy*inv; nz = cz*inv;
                } else {
                    nx = 0; ny = 1; nz = 0;
                }
                immutable uint i0 = face[0];
                for (uint i = 1; i + 1 < face.length; i++) {
                    immutable uint ia = i0;
                    immutable uint ib = face[i];
                    immutable uint ic = face[i + 1];
                    Vec3 va = mesh.vertices[ia];
                    Vec3 vb = mesh.vertices[ib];
                    Vec3 vc = mesh.vertices[ic];
                    size_t k = fw * FACE_STRIDE;
                    scratchFaceData[k +  0] = va.x;
                    scratchFaceData[k +  1] = va.y;
                    scratchFaceData[k +  2] = va.z;
                    scratchFaceData[k +  3] = nx;
                    scratchFaceData[k +  4] = ny;
                    scratchFaceData[k +  5] = nz;
                    scratchFaceData[k +  6] = vb.x;
                    scratchFaceData[k +  7] = vb.y;
                    scratchFaceData[k +  8] = vb.z;
                    scratchFaceData[k +  9] = nx;
                    scratchFaceData[k + 10] = ny;
                    scratchFaceData[k + 11] = nz;
                    scratchFaceData[k + 12] = vc.x;
                    scratchFaceData[k + 13] = vc.y;
                    scratchFaceData[k + 14] = vc.z;
                    scratchFaceData[k + 15] = nx;
                    scratchFaceData[k + 16] = ny;
                    scratchFaceData[k + 17] = nz;
                    scratchFaceIdData[fw + 0] = cast(uint)fi;
                    scratchFaceIdData[fw + 1] = cast(uint)fi;
                    scratchFaceIdData[fw + 2] = cast(uint)fi;
                    // Material Groups (MG3): one matId per VBO vertex.
                    // Defaults to 0 (Default surface) for faces not yet
                    // assigned an entry in mesh.faceMaterial.
                    const uint mid = (fi < mesh.faceMaterial.length)
                        ? mesh.faceMaterial[fi] : 0u;
                    scratchMatIdData[fw + 0] = mid;
                    scratchMatIdData[fw + 1] = mid;
                    scratchMatIdData[fw + 2] = mid;
                    fw += 3;
                }
                faceTriCount[fi] = cast(int)(fw - faceTriStart[fi]);
            }
            faceVertCount = cast(int)fw;
        }
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
            scratchFaceData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              FACE_STRIDE * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE,
                              FACE_STRIDE * float.sizeof,
                              cast(void*)(3 * float.sizeof));
        glEnableVertexAttribArray(1);

        // Parallel face-ID VBO. Always upload at least one sentinel
        // uint so the buffer is non-zero-sized even for empty meshes.
        glBindBuffer(GL_ARRAY_BUFFER, faceIdVbo);
        if (faceVertCount > 0) {
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(faceVertCount * uint.sizeof),
                scratchFaceIdData.ptr, GL_DYNAMIC_DRAW);
        } else {
            uint zero = 0;
            glBufferData(GL_ARRAY_BUFFER, uint.sizeof, &zero, GL_DYNAMIC_DRAW);
        }

        // Material Groups (MG3): parallel matId VBO. Bound into the
        // faceVao at attrib location 2 with the integer pointer variant
        // so the lit shader reads it as `flat in uint aMatId`. Bind
        // happens here so the VAO state is captured alongside the
        // position + normal pointers.
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, matIdVbo);
        if (faceVertCount > 0) {
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(faceVertCount * uint.sizeof),
                scratchMatIdData.ptr, GL_DYNAMIC_DRAW);
        } else {
            uint zero = 0;
            glBufferData(GL_ARRAY_BUFFER, uint.sizeof, &zero, GL_DYNAMIC_DRAW);
        }
        glVertexAttribIPointer(2, 1, GL_UNSIGNED_INT,
                               cast(GLsizei)uint.sizeof, cast(void*)0);
        glEnableVertexAttribArray(2);
        glBindVertexArray(0);

        // ── Edges ─────────────────────────────────────────────────
        immutable size_t needEdgeFloats = totalEdgeKeep * 6;
        if (scratchEdgeData.length < needEdgeFloats)
            scratchEdgeData.length = needEdgeFloats;
        // `edgeOriginGpu.length > 0` IS THE SENTINEL FOR "this edge VBO is not
        // 1:1 with the mesh's edges" (task 0613 R11/R12). Three places read it
        // with exactly that meaning: `drawEdges`' `bool preview = …`, the
        // id-translation branch in gpu_select.d, and the cage-identity comment
        // in `uploadSelectedVertices` below.
        //
        // So it is populated when — and only when — that sentence becomes
        // true: the subpatch preview filtered edges (edgeOrigin non-empty), or
        // WE just filtered some out for being hidden. Populating it
        // unconditionally "because a lookup table is always nice" would
        // redefine the sentinel for every mesh in the program and permanently
        // stand down `drawEdges`' allEdgesSelected shortcut, which is gated on
        // `!preview` — a select-all-edges frame would trade one early-aborting
        // scan for two full ones, on every mesh, forever, in exchange for
        // nothing. With the condition: nothing hidden ⇒ length 0 ⇒
        // byte-identical to before this task.
        edgeOriginGpu  .length = (edgeOrigin.length > 0 || anyEdgeSkipped)
                                  ? totalEdgeKeep : 0;
        {
            size_t ew = 0;
            size_t oc = 0;
            foreach (ei, edge; mesh.edges) {
                if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max) continue;
                if (hideSkipEdge(mesh, ei)) continue;
                // Preview path: the trace's cage origin. Cage path: the
                // identity, exactly the shape vertOriginGpu already uses below.
                if (edgeOriginGpu.length > 0)
                    edgeOriginGpu[oc++] = (edgeOrigin.length > 0)
                                           ? edgeOrigin[ei]
                                           : cast(uint)ei;
                Vec3 a = mesh.vertices[edge[0]];
                Vec3 b = mesh.vertices[edge[1]];
                scratchEdgeData[ew + 0] = a.x;
                scratchEdgeData[ew + 1] = a.y;
                scratchEdgeData[ew + 2] = a.z;
                scratchEdgeData[ew + 3] = b.x;
                scratchEdgeData[ew + 4] = b.y;
                scratchEdgeData[ew + 5] = b.z;
                ew += 6;
            }
            edgeVertCount = cast(int)(ew / 3);
        }
        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
            scratchEdgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // ── Vertex points ─────────────────────────────────────────
        immutable size_t needVertFloats = totalVertKeep * 3;
        if (scratchVertData.length < needVertFloats)
            scratchVertData.length = needVertFloats;
        vertOriginGpu  .length = totalVertKeep;
        {
            size_t vw = 0;
            size_t oc = 0;
            foreach (vi, v; mesh.vertices) {
                if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max) continue;
                if (hideSkipVertex(mesh, vi)) continue;
                scratchVertData[vw + 0] = v.x;
                scratchVertData[vw + 1] = v.y;
                scratchVertData[vw + 2] = v.z;
                vertOriginGpu[oc++] = (vertOrigin.length > 0)
                                       ? vertOrigin[vi]
                                       : cast(uint)vi;
                vw += 3;
            }
            vertCount = cast(int)oc;
        }
        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
            scratchVertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    /// Refresh vertex POSITIONS only — assumes the face / edge / vert
    /// VBO layouts (vertex count, face triangulation, faceTriStart
    /// offsets, faceIdVbo, edgeOriginGpu, …) all match what the last
    /// full `upload()` produced. Walks the mesh and writes new
    /// pos + (face) normal into the existing buffers via glMapBuffer
    /// — zero array `~=`, zero CPU-side reallocation, zero topology
    /// metadata churn.
    ///
    /// Used by the subpatch preview path: when topologyVersion is
    /// unchanged (mesh moved but didn't change topology), the
    /// SubpatchPreview re-evaluates OpenSubdiv's stencil table into
    /// preview.vertices, and these GPU buffers can be refreshed the
    /// same way instead of rebuilding faceData / edgeData / vertData
    /// arrays from scratch. On the user's 6 K-vert cage sphere drag
    /// (~393 K preview verts) this drops the `upload` hot path from
    /// ~16 % of CPU + ~12 % memmove + ~10 % GC expandArrayUsed to a
    /// single mapped-buffer write per VBO.
    void refreshPositions(ref const Mesh mesh,
                          const uint[] edgeOrigin = null,
                          const uint[] vertOrigin = null) {
        if (faceTriStart.length != mesh.faces.length)
            return;   // layout mismatch — caller should fall back to upload().
        ++uploadVersion;
        // Counted AFTER the suppress/layout-mismatch early-returns above, so
        // `uploadCalls` means uploads that actually touched a buffer, not
        // upload REQUESTS. `uploadVerts` is the mesh's vertex count, i.e. the
        // size of the data this path is responsible for — not the byte count,
        // which differs per buffer and would need four separate sums to state
        // honestly.
        g_fc.upload(cast(long)mesh.vertices.length);

        enum FACE_STRIDE = 6;

        // Face VBO: re-fan each face's triangles from its first three
        // verts. Normal recomputed per face (one cross + one sqrt).
        // faceTriStart already maps fi → first vertex in the VBO.
        //
        // Map with INVALIDATE_BUFFER_BIT — explicit driver-side orphan,
        // we'll fill the entire buffer below. The two skipped-face
        // patterns (face.length < 3) still write zero into those slots
        // implicitly: we don't touch them, but the orphaned allocation
        // starts as uninitialised garbage. That's tolerable because the
        // skipped faces have faceTriCount[fi] == 0, so drawFaces never
        // dereferences those bytes — they're not referenced by any draw
        // call.
        if (faceVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    // Hidden faces are skipped for the same reason degenerate
                    // ones are, and it is not merely an optimisation: their
                    // faceTriCount is 0, so faceTriStart[fi] already points at
                    // the NEXT kept face's first triangle. Writing them here
                    // would overwrite that face's data.
                    if (face.length < 3 || hideSkipFace(mesh, fi)) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    // Fan-triangulate around face[0]; write [pos, normal]
                    // per vertex with hand-rolled inner loop — avoids the
                    // `foreach (idx; [..])` literal-array GC alloc and the
                    // Vec3 operator-overload temporaries that dominated
                    // an earlier profile.
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        immutable uint ia = i0;
                        immutable uint ib = face[i];
                        immutable uint ic = face[i+1];
                        Vec3 va = mesh.vertices[ia];
                        Vec3 vb = mesh.vertices[ib];
                        Vec3 vc = mesh.vertices[ic];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO: subpatch mode filters out edges whose
        // edgeOrigin[ei] == uint.max (derived edges that aren't shown).
        // VBO segment order matches the kept-edge walk in `upload`.
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    // Same skip as `upload`'s kept-edge walk, or this refresh
                    // shifts every segment after the first hidden edge (R2).
                    if (hideSkipEdge(mesh, ei)) continue;
                    if (seg * 2 >= edgeVertCount) break;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO: subpatch mode filters out verts whose
        // vertOrigin[vi] == uint.max (edge mids / face centroids).
        // VBO order matches the kept-vert walk in `upload`.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    // Same skip as `upload`'s kept-vert walk (R2).
                    if (hideSkipVertex(mesh, vi)) continue;
                    if (seg >= vertCount) break;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindVertexArray(0);
    }

    /// Edge + vertex VBO position refresh — the subset of
    /// `refreshPositions` that skips the face VBO. Used by Phase 3b's
    /// OSD GPU fan-out path, which writes the face VBO itself; the
    /// edge / vert VBOs still come from CPU `mesh.vertices` because
    /// OSD's stencil output is per-limit-vert only and vibe3d's
    /// edge / vert VBOs need their own layout.
    void refreshNonFacePositions(ref const Mesh mesh,
                                  const uint[] edgeOrigin = null,
                                  const uint[] vertOrigin = null) {
        // This path has no `++uploadVersion` (it deliberately leaves the face
        // VBO alone), so the counter bump is at entry rather than beside a
        // version bump like the other three.
        g_fc.upload(cast(long)mesh.vertices.length);
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    // Same skip as `upload`'s kept-edge walk, or this refresh
                    // shifts every segment after the first hidden edge (R2).
                    if (hideSkipEdge(mesh, ei)) continue;
                    if (seg * 2 >= edgeVertCount) break;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    // Same skip as `upload`'s kept-vert walk (R2).
                    if (hideSkipVertex(mesh, vi)) continue;
                    if (seg >= vertCount) break;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    // Drag-fast path: re-upload every VBO in full, but skip the GC churn
    // that the array-growth `~=` loops in `upload()` impose. Despite the
    // name + `toUpdate` mask, this no longer takes a partial-write
    // shortcut — `glMapBufferRange + GL_MAP_WRITE_BIT` alone (no invalidate)
    // sounds spec-safe but Mesa orphans the backing store anyway, leaving
    // un-touched faces as garbage. The map-with-invalidate path orphans
    // EXPLICITLY (the driver hands us a fresh allocation) and we fill it
    // from scratch — so every byte in the buffer ends up well-defined.
    //
    // `toUpdate` is retained in the signature for caller compatibility but
    // ignored here; the drag tools always pass the same mesh ref through
    // and we touch the full topology either way.
    void uploadSelectedVertices(ref const Mesh mesh, const bool[] toUpdate) {
        // Preview is currently displayed; cage-indexed scatter writes would
        // corrupt the VBO. Signal a mutation and let the main loop rebuild
        // the preview instead.
        if (suppressCageUpload) {
            ++(cast(Mesh*)&mesh).mutationVersion;
            return;
        }
        ++uploadVersion;
        // Counted AFTER the suppress/layout-mismatch early-returns above, so
        // `uploadCalls` means uploads that actually touched a buffer, not
        // upload REQUESTS. `uploadVerts` is the mesh's vertex count, i.e. the
        // size of the data this path is responsible for — not the byte count,
        // which differs per buffer and would need four separate sums to state
        // honestly.
        g_fc.upload(cast(long)mesh.vertices.length);
        enum FACE_STRIDE = 6;

        // Face VBO — flat-shaded fan triangulation, one normal per face.
        if (faceVertCount > 0 && faceTriStart.length == mesh.faces.length) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    // Hidden: skipped exactly as in `upload` and
                    // `refreshPositions`. faceTriCount is 0 for these and
                    // faceTriStart[fi] aliases the next kept face's first
                    // triangle, so writing here would corrupt that face (R2).
                    if (face.length < 3 || hideSkipFace(mesh, fi)) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        Vec3 va = mesh.vertices[i0];
                        Vec3 vb = mesh.vertices[face[i]];
                        Vec3 vc = mesh.vertices[face[i+1]];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO — this path is CAGE-ONLY: a preview upload would have gone
        // through the suppressCageUpload early-return above, so `edgeOrigin`
        // filtering never applies here.
        //
        // It is NOT unfiltered, though, and has not been since task 0613 S3:
        // hidden edges are skipped, in the same order and by the same
        // predicate as `upload`'s kept-edge walk. THE INVARIANT IS "VBO
        // segment k is the k-th NON-HIDDEN cage edge", not "segment k is cage
        // edge k" — those coincide only while nothing is hidden. Leaving this
        // walk unfiltered while `upload` filtered would desynchronise the two
        // fills, so the first drag after a hide would shift every segment past
        // the first hidden edge onto the wrong geometry (R2, on the edge
        // buffer). `edgeOriginGpu` carries the segment→cage map whenever the
        // two stop coinciding.
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int k = 0;
                foreach (ei, edge; mesh.edges) {
                    if (hideSkipEdge(mesh, ei)) continue;
                    if (k + 6 > edgeVertCount * 3) break;
                    Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO — same invariant, same reason: slot k is the k-th
        // non-hidden cage vertex. The old cage-index scatter (`k = vi * 3`)
        // was correct only while the two coincided; a sequential walk that
        // shares `upload`'s skip is correct in both cases.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (hideSkipVertex(mesh, vi)) continue;
                    if (seg >= vertCount) break;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        glBindVertexArray(0);
    }

    // ---- counted draw submission -------------------------------------
    //
    // EVERY glDrawArrays in this struct goes through here, and that is the
    // point: the alternative — sprinkling a counter bump beside each call —
    // is a thing you forget at the twentieth site and then quietly
    // under-report forever. A wrapper cannot be forgotten, because forgetting
    // it means calling glDrawArrays directly, which is greppable.
    //
    // That guarantee is LOCAL TO THIS STRUCT and does not generalise. The
    // line below is the only raw glDrawArrays in mesh_gpu.d, which is what
    // makes "did someone bypass the counter here" a grep. Every other draw
    // path in the codebase (handles/shapes.d, handles/gl_util.d,
    // ui/panels.d, gpu_select.d, subpatch_osd.d) is a raw glDrawArrays with a
    // g_fc.draw beside it, and there a forgotten bump is silent. See the
    // FrameWorkProbe header in perf_probe.d for the per-file check.
    //
    // Pure pass-through: no `count <= 0` guard, no reordering. A zero-vertex
    // submission is still a submission (the driver call happens either way),
    // so it is counted as one call with zero vertices rather than dropped —
    // dropping it would make "this pass ran but had nothing to draw"
    // indistinguishable from "this pass did not run".
    //
    // `g_fc.draw` is live in every build (see perf_probe.d's FrameWorkProbe
    // header): two integer adds per GL call, no allocation, no lock.
    private void dcArrays(DrawPass p, GLenum mode, int first, int count) {
        glDrawArrays(mode, first, count);
        g_fc.draw(p, count);
    }

    // Draw faces only (writes depth buffer). Material colour comes from
    // the Materials UBO (LitShader.setSurfaces); u_overrideMix is left
    // at its useProgram default of 0 so the shader uses mat_base[matId].
    void drawFaces(const ref LitShader shader) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        dcArrays(DrawPass.faces, GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw faces with per-face hover highlights (Polygons mode). When the
    // subpatch preview is uploaded, `faceOriginGpu` maps each VBO face to
    // its cage face so every preview child of a hovered cage face is tinted.
    // The "hover" branches flip u_overrideMix=1 + u_color=light-blue so the
    // hovered face shows the legacy highlight even on multi-material LWO
    // meshes; the non-hover branches restore u_overrideMix=0 so the rest
    // of the mesh keeps its surface colours.
    void drawFacesHighlighted(const ref LitShader shader,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        scope(exit) {
            glDisable(GL_POLYGON_OFFSET_FILL);
            glBindVertexArray(0);
            // Always leave overrideMix at the useProgram default so the
            // next caller doesn't inherit a hover-tint state.
            glUniform1f(shader.locOverrideMix, 0.0f);
        }

        int vboFaceCount = cast(int)faceTriStart.length;

        if (hoveredFace < 0) {
            dcArrays(DrawPass.faces, GL_TRIANGLES, 0, faceVertCount);
            return;
        }

        bool preview = faceOriginGpu.length > 0;
        int cageOf(int fi) {
            return preview ? cast(int)faceOriginGpu[fi] : fi;
        }

        // Cage-mode single-face fast path.
        if (!preview) {
            if (hoveredFace >= vboFaceCount) {
                dcArrays(DrawPass.faces, GL_TRIANGLES, 0, faceVertCount);
                return;
            }
            int hs = faceTriStart[hoveredFace];
            int hc = faceTriCount[hoveredFace];
            // Surrounding non-hover faces: material colour.
            if (hs > 0) dcArrays(DrawPass.faces, GL_TRIANGLES, 0, hs);
            if (hs + hc < faceVertCount)
                dcArrays(DrawPass.faces, GL_TRIANGLES, hs + hc, faceVertCount - hs - hc);
            // Hover face: hard override to the legacy highlight blue.
            if (hc > 0) {
                glUniform1f(shader.locOverrideMix, 1.0f);
                glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
                dcArrays(DrawPass.faces, GL_TRIANGLES, hs, hc);
            }
            return;
        }

        // Preview: batch contiguous VBO-face runs of the same hover state.
        void batchRun(bool hoverState) {
            int batchStart = -1;
            for (int i = 0; i < vboFaceCount; i++) {
                bool isHover = cageOf(i) == hoveredFace;
                if (isHover == hoverState) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    int s = faceTriStart[batchStart];
                    int e = faceTriStart[i];
                    if (e > s) dcArrays(DrawPass.faces, GL_TRIANGLES, s, e - s);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0) {
                int s = faceTriStart[batchStart];
                if (faceVertCount > s) dcArrays(DrawPass.faces, GL_TRIANGLES, s, faceVertCount - s);
            }
        }
        // Non-hover preview triangles: material colour.
        batchRun(false);
        // Hover preview triangles: legacy highlight blue.
        glUniform1f(shader.locOverrideMix, 1.0f);
        glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
        batchRun(true);
    }

    // Draw only the selected faces geometry (no color set — caller sets up shader).
    // Optimized: batch selected faces to minimize draw calls. In subpatch
    // mode each VBO face is mapped through `faceOriginGpu` so all children
    // of a selected cage face are included.
    void drawSelectedFacesOverlay(const bool[] selectedFaces) {
        glBindVertexArray(faceVao);

        bool preview = faceOriginGpu.length > 0;
        bool isSelected(int i) {
            int cage = preview ? cast(int)faceOriginGpu[i] : i;
            return cage >= 0 && cage < cast(int)selectedFaces.length && selectedFaces[cage];
        }

        int batchStart = -1;
        int vboFaceCount = cast(int)faceTriStart.length;
        for (int i = 0; i < vboFaceCount; i++) {
            if (!isSelected(i)) {
                if (batchStart >= 0) {
                    int startIdx = faceTriStart[batchStart];
                    int endIdx   = faceTriStart[i];
                    dcArrays(DrawPass.faceOverlay, GL_TRIANGLES, startIdx, endIdx - startIdx);
                    batchStart = -1;
                }
            } else if (batchStart < 0) {
                batchStart = i;
            }
        }

        // Draw final batch if exists
        if (batchStart >= 0) {
            int startIdx = faceTriStart[batchStart];
            dcArrays(DrawPass.faceOverlay, GL_TRIANGLES, startIdx, faceVertCount - startIdx);
        }

        glBindVertexArray(0);
    }

    // Draw edges with optional hover/selection highlights.
    // `selectedEdges` and `hoveredEdge` are indexed by CAGE edges. When the VBO
    // is not 1:1 with the cage's edges, `edgeOriginGpu` maps each VBO segment
    // back to its cage edge so highlights propagate across every segment of
    // the corresponding original edge. Two things make it non-1:1: a subpatch
    // preview upload (many segments per cage edge), and a cage upload that
    // dropped hidden edges (task 0613 S3). The local flag below is named
    // `preview` for the first and reads correctly for both — what it actually
    // asks is "must I translate?".
    //
    // `hoveredEdges` is an OPTIONAL cage-indexed hover SET (default empty).
    // A segment is hovered when its cage edge equals `hoveredEdge` OR its cage
    // edge is set in `hoveredEdges`. This lets a caller pre-highlight a whole
    // edge loop in the hover colour (ElementMove + falloff EdgeLoops): pass the
    // loop's edge mask and the single hovered edge index. With the default
    // empty mask the behaviour is identical to the single-edge form, so every
    // existing call site is unchanged.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges,
                   const bool[] hoveredEdges = [],
                   BaseWire base = BaseWire.init) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        bool preview = edgeOriginGpu.length > 0;
        int  cageOf(int segIdx) {
            return preview ? cast(int)edgeOriginGpu[segIdx] : segIdx;
        }
        bool segSelected(int segIdx) {
            int c = cageOf(segIdx);
            return c >= 0 && c < cast(int)selectedEdges.length && selectedEdges[c];
        }
        bool segHovered(int segIdx) {
            int c = cageOf(segIdx);
            if (hoveredEdge >= 0 && c == hoveredEdge) return true;
            return c >= 0 && c < cast(int)hoveredEdges.length && hoveredEdges[c];
        }

        // Is ANY segment in the hover colour? (single hovered edge OR any
        // loop-mask edge). Drives the gray-pass fast path + the all-selected
        // shortcut so a loop mask with hoveredEdge < 0 still skips its segments.
        bool anyHover = hoveredEdge >= 0;
        if (!anyHover)
            foreach (h; hoveredEdges) if (h) { anyHover = true; break; }

        // "All selected" shortcut is only safe when VBO segments are 1:1 with
        // cage edges. Skipped whenever they are not — a subpatch preview, or a
        // cage upload with hidden edges dropped. Preserving that "is not"
        // meaning is the whole reason `edgeOriginGpu` is populated
        // CONDITIONALLY in `upload` (task 0613 R12): populate it always and
        // this shortcut can never fire again, on any mesh.
        bool allEdgesSelected = !preview
            && selectedEdges.length >= edgeCount
            && !anyHover;
        if (allEdgesSelected)
            foreach (s; selectedEdges[0 .. edgeCount]) if (!s) { allEdgesSelected = false; break; }

        // Gray pass — depth-tested, skip hovered/selected segments.
        //
        // THIS PASS, AND ONLY THIS PASS, IS THE WIREFRAME OVERLAY (task 0559).
        // The two passes below it are selection and hover FEEDBACK, which are
        // their own display axes and must survive the overlay being switched
        // off — turning this whole function off instead is the obvious, and
        // wrong, way to implement an overlay mode of "none". The seam already
        // existed; `base.draw` just names it.
        if (base.draw) {
            // Opacity is likewise a property of the base overlay alone: a
            // faint wireframe must not drag the selection highlight faint
            // with it. Blending is enabled only when it would actually do
            // something, so the default path issues the exact same GL calls
            // it always did.
            immutable bool blend = base.alpha < 1.0f && base.locAlpha >= 0;
            if (blend) {
                glUniform1f(base.locAlpha, base.alpha);
                glEnable(GL_BLEND);
                // Colour blends; DESTINATION ALPHA IS LEFT ALONE. The cell
                // FBO's alpha channel is a real attachment, and punching
                // holes in it with a translucent line pass would leak into
                // anything that ever composites the cell texture.
                glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
                                    GL_ZERO, GL_ONE);
            }

            glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
            if (!anyHover && selectedEdges.length == 0) {
                dcArrays(DrawPass.edges, GL_LINES, 0, edgeVertCount);
            } else if (!allEdgesSelected) {
                int batchStart = -1;
                for (int i = 0; i < edgeCount; i++) {
                    bool skip = segHovered(i) || segSelected(i);
                    if (!skip) {
                        if (batchStart < 0) batchStart = i;
                    } else if (batchStart >= 0) {
                        dcArrays(DrawPass.edges, GL_LINES, batchStart * 2, (i - batchStart) * 2);
                        batchStart = -1;
                    }
                }
                if (batchStart >= 0)
                    dcArrays(DrawPass.edges, GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
            }

            if (blend) {
                glDisable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUniform1f(base.locAlpha, 1.0f);
            }
        }

        // Highlight pass — draw without depth so selection shows through.
        glDisable(GL_DEPTH_TEST);

        if (allEdgesSelected && hoveredEdge < 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            dcArrays(DrawPass.edges, GL_LINES, 0, edgeVertCount);
        } else if (selectedEdges.length > 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                if (segSelected(i) && !segHovered(i)) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    dcArrays(DrawPass.edges, GL_LINES, batchStart * 2, (i - batchStart) * 2);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0)
                dcArrays(DrawPass.edges, GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }

        if (anyHover) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            // Draw EVERY hovered segment (single hovered edge + any loop-mask
            // edges). In preview mode a cage edge fans out to several VBO
            // segments; in cage mode it is 1:1 — segHovered() handles both and
            // also folds in the hoveredEdges loop mask, so a single scan covers
            // the single-edge case and the whole-loop case uniformly.
            for (int i = 0; i < edgeCount; i++)
                if (segHovered(i))
                    dcArrays(DrawPass.edges, GL_LINES, i * 2, 2);
        }

        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
    }

    // Draw the WHOLE mesh's wireframe in one flat colour — the item-level
    // highlight (task 0647).
    //
    // Deliberately NOT a call into `drawEdges` with an all-true mask. Three
    // things differ and each one is measured:
    //
    //   * the COVERAGE is the whole cage, with no selection or hover set to
    //     partition it, so there is nothing for the batching scan to do;
    //   * the COLOUR is the caller's, not one of the two literals `drawEdges`
    //     holds — item state has three colours and geometry state has two, and
    //     folding them into one function is how the item's derived
    //     hovered-selected shade would end up as a fourth literal in here;
    //   * the BASE (grey) pass must not run. In item mode this pass is drawn
    //     OVER a wireframe that has already been laid down, and re-issuing the
    //     grey underneath it would be pure waste.
    //
    // Interior edges are included, not just the silhouette: the reference
    // paints a hovered item's interior edges (measured — 307 of the 956 pixels
    // it painted were on edges that are not on the outline), so a silhouette
    // extraction here would be a different, wrong shape.
    //
    // Depth test OFF, matching the selection/hover passes in `drawEdges`: an
    // item's highlight reads as feedback about the ITEM, and feedback that is
    // occluded by the item's own front faces would answer a question nobody
    // asked. (The reference rig measured flat grids, where the two conventions
    // are indistinguishable, so this half follows the house convention rather
    // than a measurement.)
    void drawItemHighlight(GLint locColor, float r, float g, float b) {
        if (edgeVertCount <= 0) return;
        glBindVertexArray(edgeVao);
        glDisable(GL_DEPTH_TEST);
        glUniform3f(locColor, r, g, b);
        dcArrays(DrawPass.edges, GL_LINES, 0, edgeVertCount);
        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    /// `hovered` and `selected` are CAGE-indexed. In cage mode the VBO
    /// is also cage-indexed (vertOriginGpu is the identity), so a slot
    /// lookup is direct. In subpatch mode the VBO holds only "vert-
    /// point" preview verts (cage origin recorded in vertOriginGpu)
    /// and most cage-vert indices have no VBO slot — translate
    /// through vertOriginGpu the same way drawEdges does. Without
    /// this, hovering on the subdivided surface highlighted the wrong
    /// preview vert because the cage index from picking was being
    /// used as a raw glDrawArrays offset.
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots, with depth test
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        dcArrays(DrawPass.verts, GL_POINTS, 0, vertCount);

        // Selected and hovered — drawn without depth test so they show through faces.
        glDisable(GL_DEPTH_TEST);

        int cageOf(int vboIdx) {
            if (vboIdx >= cast(int)vertOriginGpu.length) return -1;
            uint c = vertOriginGpu[vboIdx];
            return (c == uint.max) ? -1 : cast(int)c;
        }

        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        for (int i = 0; i < vertCount; i++) {
            int c = cageOf(i);
            if (c < 0) continue;
            if (c < cast(int)selected.length && selected[c])
                dcArrays(DrawPass.verts, GL_POINTS, i, 1);
        }

        if (hovered >= 0) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            for (int i = 0; i < vertCount; i++) {
                if (cageOf(i) == hovered)
                    dcArrays(DrawPass.verts, GL_POINTS, i, 1);
            }
        }

        glEnable(GL_DEPTH_TEST);
        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}
