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
import core.atomic : atomicOp;
import math;    // Vec3
import shader;  // LitShader
import mesh;    // Mesh, FaceList
import change_bus : MeshEditScope;  // Position class for the preview-refresh publish
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import viewport_scheme : schemeColor, SchemeColor, pointSizePx, kBasePointSize,
                         kOccludedSelectionAlpha;

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
// OccludedPass — the SECOND submission of the selection / pre-highlight
// ---------------------------------------------------------------------------

/// How the OCCLUDED half of a selection highlight is drawn (task 1860).
///
/// MEASURED (`doc/selection_display_parity.md` §2.1-§2.2, §3.3): a selected
/// element is submitted TWICE per frame. The first submission is depth-tested
/// normally and paints the part of the selection that is genuinely in front.
/// The second inverts the depth function, so it paints ONLY where the fragment
/// is behind what is already there, and blends at a low alpha. Two passes is
/// settled structurally rather than by appearance — one batch cannot be both
/// "nearer or equal" and "further", and the reference attaches the same
/// selection model to two stages that set exactly those two.
///
/// WHAT WE SHIPPED BEFORE, and why it is not the same thing: one pass with
/// `glDisable(GL_DEPTH_TEST)` at full strength. That draws the occluded half
/// and the visible half identically, so the user cannot tell a selected edge
/// in front of the model from one behind it. It is not a weaker version of the
/// law, it is a different law.
///
/// Sister struct to `BaseWire`, and the same idiom for the same reason: a
/// defaulted trailing parameter, so every existing call site keeps compiling
/// and a call site that does not wire it up draws the ORDINARY pass alone.
struct OccludedPass {
    /// Location of the flat shader's `u_alpha`.
    ///
    /// NEGATIVE MEANS THE OCCLUDED PASS DOES NOT RUN AT ALL, and that is a
    /// refusal rather than a fallback. A pass that cannot write its alpha is
    /// not the measured pass: it paints the occluded half at FULL strength,
    /// which is precisely the pre-1860 rendering this change removed, and its
    /// draw-call census is byte-identical to the correct one — so no counter,
    /// and no test built on one, could tell the difference.
    ///
    /// This struct is a DEFAULTED trailing parameter, so "run anyway at
    /// whatever alpha the program carries" would make that wrong rendering
    /// THE DEFAULT for every call site that omits the argument. Three do
    /// today (`shader.d`'s and `pen.d`'s preview wireframes, and the backdrop
    /// pass in `ui/viewport_render.d`); each is safe only because it passes
    /// no selection and no hover, so its highlight scan emits nothing either
    /// way. The refusal is what keeps them safe on the day one of them grows
    /// a selection argument.
    GLint locAlpha = -1;
    /// Alpha for the occluded submission.
    float alpha    = kOccludedSelectionAlpha;
}

// ---------------------------------------------------------------------------
// The two-pass GL state — written ONCE, called from both draw entry points
// ---------------------------------------------------------------------------
//
// `drawEdges` and `drawVertices` draw their highlights in exactly the passes
// `OccludedPass` describes, and the GL state those passes need is IDENTICAL at
// the two sites — only the primitives submitted between them differ. So it is
// written here once, for the same reason each site issues its batch scan once
// and calls it twice: the two passes are required to agree, and a textual copy
// stops agreeing the first time either half is touched. A drift between the
// SITES is the worse of the two, because the pixel checks probe one element
// type at a time and a mutation applied to both sites at once cannot separate
// them.
//
// Cost: two calls per frame per site, not per element. This is not the shape
// that was measured and rejected inside `drawVertices` (a `bool delegate(int)`
// evaluated PER VERTEX, which cost more than the draw calls it saved).

/// Pass A — the VISIBLE half of a highlight.
///
/// `GL_LEQUAL`, not the inherited default: `glDepthFunc` is called nowhere
/// else in `source/`, so `GL_LESS` is in force, and the base wire pass that
/// runs before this one WROTE depth at exactly the pixels a selected edge
/// would cover. Under `GL_LESS` a highlight lying on depth that is already
/// there fails the test and the selection would simply vanish.
/// `LEQUAL`/`GREATER` also partition the depth range with NO GAP, which is the
/// reference's own pair.
///
/// `glDepthMask(GL_FALSE)` on BOTH passes, which keeps the depth buffer
/// exactly as the caller found it — the same postcondition the old
/// `glDisable(GL_DEPTH_TEST)` had, since disabling the test disables depth
/// WRITES with it. Only the occluded pass's mask is named in the measured law;
/// making pass A depth-writing would be an unmeasured extra, and it would
/// newly let a selected edge occlude everything drawn after it (the vertex
/// dots, the gizmo).
private void beginVisibleHighlightPass() {
    glEnable(GL_DEPTH_TEST);
    glDepthMask(GL_FALSE);
    glDepthFunc(GL_LEQUAL);
}

/// Pass B — the OCCLUDED half. Same primitives, same colours; only the depth
/// comparison and the alpha differ.
///
/// Returns whether the pass may run. The caller MUST submit nothing when this
/// is false — see `OccludedPass.locAlpha` for why a pass without its alpha is
/// a different rendering rather than a slightly-off one.
///
/// UNCONDITIONAL OTHERWISE. Not "skip it when nothing is occluded": whether
/// the reference elides the stage for a fully visible selection is registered
/// as unknown (`doc/selection_display_parity.md` §5), and a scene-dependent
/// second pass would make the draw-call census scene-dependent too — which is
/// the census this change is pinned by. The `GL_GREATER` test discards it per
/// fragment either way.
///
/// `glBlendFuncSeparate`, set here rather than inherited: `drawEdges`' base
/// wire block establishes the separate form only inside its own `blend` branch
/// (which does not run at the default opacity) and resets to the NON-separate
/// form on the way out. Colour blends; DESTINATION ALPHA IS LEFT ALONE,
/// because the cell FBO's alpha channel is a real attachment and punching
/// holes in it would leak into anything that composites the cell texture.
private bool beginOccludedHighlightPass(OccludedPass occ) {
    if (occ.locAlpha < 0) return false;
    glDepthFunc(GL_GREATER);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
                        GL_ZERO, GL_ONE);
    glUniform1f(occ.locAlpha, occ.alpha);
    return true;
}

/// The depth bias the selected-face FILL is drawn under (task 1862).
///
/// WHAT WAS MEASURED is `glPolygonOffset(-2, -2)` on the reference's fill
/// pass — and the reference's SURFACE pass carries no offset at all. So the
/// number that was actually measured is a SEPARATION: the fill is depth-tested
/// two units (and two slopes) in FRONT of the surface it lies on, which is how
/// a coplanar overlay wins its own face's depth without a disabled depth test.
///
/// OUR SURFACE PASS IS NOT OFFSET-FREE. `drawFaces` and `drawFacesHighlighted`
/// both run under `glPolygonOffset(1, 1)`, so the depth STORED for a face is
/// already one unit BEHIND its true z (that offset exists so the wireframe
/// drawn on top of a face does not z-fight it). Reproducing the measured
/// separation therefore means -1 here, not -2:
///
///     fill_offset - surface_offset  ==  (-1) - (+1)  ==  -2
///
/// Shipping the literal -2 would give a separation of THREE, half again as
/// much as anything measured, and the direction it errs in is not harmless:
/// the bias moves the LEQUAL/GREATER boundary the occluded pass partitions on,
/// so geometry occluding the fill by less than the separation reads as VISIBLE
/// and paints at full strength — the pre-1862 rendering, silently retained for
/// coincident and near-coincident pairs (a subpatch cage face against its own
/// limit surface is the case in reach). A bigger number buys nothing and
/// widens that blind band.
///
/// This is not a free parameter to tune by eye: `app.d`'s depth-size request
/// records that `glPolygonOffset(1, 1)` on a 16-bit depth buffer is already
/// enough to push silhouette-adjacent faces far enough to matter.
private enum float kFillDepthBias = -1.0f;

/// Undo both passes. `ranOccluded` is what `beginOccludedHighlightPass`
/// returned, so the blend state and the alpha uniform are unwound exactly when
/// they were wound up.
///
/// The DEPTH state is restored unconditionally. `gpu_select.renderMode` runs
/// mid-frame and saves/restores the program, the VAO, the FBO, the viewport,
/// GL_DEPTH_TEST, GL_POLYGON_OFFSET_FILL and GL_CULL_FACE — but NOT the depth
/// func and NOT the depth mask. A leaked `GL_GREATER` would invert its face
/// depth pre-pass, so elements BEHIND a face become pickable and those in
/// front do not, with no pixel changing; a leaked `glDepthMask(GL_FALSE)`
/// would make its `glClear(GL_DEPTH_BUFFER_BIT)` a no-op, because a depth
/// clear is masked by the depth mask, and the pick FBO would silently reuse
/// the previous pick's depth.
private void endHighlightPasses(OccludedPass occ, bool ranOccluded) {
    if (ranOccluded) {
        glUniform1f(occ.locAlpha, 1.0f);
        glDisable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    }
    glDepthFunc(GL_LESS);
    glDepthMask(GL_TRUE);
    glEnable(GL_DEPTH_TEST);
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

    // ---- Weight display (task 1090) ----------------------------------
    //
    // Per face-VBO vertex, the SOURCE-MESH vertex index that corner came
    // from. Filled by `upload()` inside the existing fill loop, from the
    // ia/ib/ic it already has in hand.
    //
    // THIS IS THE WHOLE ANTI-DRIFT MECHANISM, and it is why the weight
    // uploader does not walk faces itself. Walking them again would mean a
    // second implementation of the fan triangulation, of the hidden-face
    // skip (`hideSkipFace` — a hidden face keeps its slot with
    // `faceTriCount == 0` and contributes no corners) and of the degenerate
    // skip; a colour buffer built from a triangulation that disagreed with
    // the position buffer's by even one corner mis-colours the surface with
    // no error anywhere.
    uint[] faceCornerVert;
    // Per face-VBO vertex, the weight COLOUR (vec3), bound into faceVao at
    // attrib location 3. Only ever filled while the weight display style is
    // on; `disableWeightColors` turns the array off and the lit shader's
    // parked generic attribute supplies the neutral instead.
    GLuint weightColorVbo;
    // Validity stamp for `weightColorVbo`.
    //
    // KEYED ON THE MESH ADDRESS AND THE MAP NAME, AND ON NOTHING ELSE —
    // deliberately not on a version. What this buffer must agree with is the
    // face VBO's LAYOUT, and neither available version tracks that:
    // `uploadSelectedVertices` bumps `uploadVersion` without touching the
    // face layout at all (so keying on it would rebuild the colours every
    // frame of a drag), while a positions-only re-upload rebuilds the layout
    // WITHOUT bumping `Mesh.mutationVersion`. The invariant is
    // "`faceCornerVert` has not been rebuilt since", and the exact way to
    // express that is to have the one function that rebuilds it say so —
    // which is why `upload()` calls `disableWeightColors()` at its tail.
    const(Mesh)* weightStampMesh;
    string       weightStampName;
    bool         weightStampValid;

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
    private float[] scratchWeightColor;   // task 1090, filled on demand
    private float[] scratchEdgeData;
    private float[] scratchVertData;

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
        glGenBuffers(1, &faceIdVbo);
        glGenBuffers(1, &matIdVbo);
        glGenBuffers(1, &weightColorVbo);   // task 1090
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
        glDeleteBuffers(1, &faceIdVbo);
        glDeleteBuffers(1, &matIdVbo);
        glDeleteBuffers(1, &weightColorVbo);   // task 1090
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
        // bump therefore triggers the main loop's GPU RE-UPLOAD (app.d's
        // cage/preview block, `gpuUploadedKey_` — since task 1906 stage 2a an
        // (address, bus-epoch) key, before that `mutationVersion`) of a preview
        // that was never REBUILT against the moved cage — the displayed surface
        // goes stale / shifts, and the debug build trips the
        // `change_bus: MISSED PUBLISHER` guard (mutationVersion advanced with
        // no pending change flags). commitChange(Position) sets the flag AND
        // bumps mutationVersion, so the preview rebuilds and the re-upload
        // still fires. NOTE for 1906 readers: this commit is a PUBLISHER on the
        // upload path, so both epoch stamps in app.d re-read the epoch AFTER
        // calling `upload` — see their comments.
        if (suppressCageUpload && edgeOrigin.length == 0 && vertOrigin.length == 0) {
            (cast(Mesh*)&mesh).commitChange(MeshEditScope.Position);
            return;
        }
        // Task 1069 — the DRAWN positions. Phase 0 measured the reference's
        // viewport at base+delta with a morph selected, so the upload is the
        // first consumer of that. `null` whenever nothing is bound, and the
        // fallback below is `mesh.vertices` — so a document with no morph
        // target uploads byte-identical bytes to before this task.
        //
        // Resolved HERE rather than threaded through every caller: there are
        // several upload sites and one of them forgetting would draw a stale
        // surface with no symptom other than "the morph does not show".
        const(Vec3)[] vpos;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&mesh);
            vpos = (dv.length == mesh.vertices.length) ? dv : mesh.vertices;
        }
        ++uploadVersion;
        // Counted AFTER the suppress/layout-mismatch early-returns above, so
        // `uploadCalls` means uploads that actually touched a buffer, not
        // upload REQUESTS. `uploadVerts` is the mesh's vertex count, i.e. the
        // size of the data this path is responsible for — not the byte count,
        // which differs per buffer and would need four separate sums to state
        // honestly.
        g_fc.upload(cast(long)mesh.vertices.length);
        buildUploadCpu(mesh, vpos, edgeOrigin, vertOrigin, faceOrigin);
        submitUploadGl();
    }

    /// Allocation-only half of a full upload. `vpos` is resolved by the caller
    /// before entering this builder so morph display selection is not hidden in
    /// the prepared owner and fake backends see the exact bytes production uses.
    private void buildUploadCpu(ref const Mesh mesh, const(Vec3)[] vpos,
                                const uint[] edgeOrigin,
                                const uint[] vertOrigin,
                                const uint[] faceOrigin) {
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
        // Task 1090: parallel to scratchFaceIdData, same length, same
        // grow-only discipline.
        if (faceCornerVert.length < totalFaceCorners)
            faceCornerVert.length = totalFaceCorners;
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
                Vec3 v0 = vpos[face[0]];
                Vec3 v1 = vpos[face[1]];
                Vec3 v2 = vpos[face[2]];
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
                    Vec3 va = vpos[ia];
                    Vec3 vb = vpos[ib];
                    Vec3 vc = vpos[ic];
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
                    // Task 1090: which SOURCE vertex each corner came from.
                    // Written here, beside the position write that uses the
                    // same three indices, so the two cannot describe
                    // different triangulations.
                    faceCornerVert[fw + 0] = ia;
                    faceCornerVert[fw + 1] = ib;
                    faceCornerVert[fw + 2] = ic;
                    fw += 3;
                }
                faceTriCount[fi] = cast(int)(fw - faceTriStart[fi]);
            }
            faceVertCount = cast(int)fw;
        }
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
                Vec3 a = vpos[edge[0]];
                Vec3 b = vpos[edge[1]];
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
        // ── Vertex points ─────────────────────────────────────────
        immutable size_t needVertFloats = totalVertKeep * 3;
        if (scratchVertData.length < needVertFloats)
            scratchVertData.length = needVertFloats;
        vertOriginGpu  .length = totalVertKeep;
        {
            size_t vw = 0;
            size_t oc = 0;
            foreach (vi, v; vpos) {
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
        // ── Weight colours: INVALIDATE (task 1090) ────────────────
        //
        // TWO things go wrong without this, and the second one is a memory
        // error rather than a stale picture.
        //
        // 1. `faceCornerVert` has just been rebuilt, so any colour buffer
        //    built from the previous one now describes a different
        //    triangulation. The stamp is what says otherwise, and this is the
        //    one function that can honestly clear it.
        // 2. The block above rebound `faceVao` and rewrote locations 0, 1 and
        //    2 — but it never touches location 3. So after a re-upload that
        //    changed the corner count, loc 3 would STILL be enabled and still
        //    pointing at a `weightColorVbo` sized for the PREVIOUS
        //    `faceVertCount`: an out-of-range attribute fetch on every
        //    subsequent face draw, whatever style is current.
        //
        // The next weight draw re-uploads, because the stamp was cleared.
        // Deliberately NOT also on the `suppressCageUpload` early return at
        // the top: that path returns before `++uploadVersion`, touches
        // neither `faceVao` nor `faceVertCount`, and publishes a Position
        // change which drives a later real upload through here.
        weightStampValid = false;
        weightStampMesh  = null;
        weightStampName  = null;
    }

    /// GL-only half. All sizes and backing storage were fixed by
    /// `buildUploadCpu`; this method performs no allocation or callbacks.
    private void submitUploadGl() nothrow @nogc {
        enum FACE_STRIDE = 6;
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
        glBindBuffer(GL_ARRAY_BUFFER, faceIdVbo);
        uint zero = 0;
        glBufferData(GL_ARRAY_BUFFER,
            faceVertCount > 0 ? cast(GLsizeiptr)(faceVertCount * uint.sizeof)
                              : cast(GLsizeiptr)uint.sizeof,
            faceVertCount > 0 ? scratchFaceIdData.ptr : &zero, GL_DYNAMIC_DRAW);
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, matIdVbo);
        glBufferData(GL_ARRAY_BUFFER,
            faceVertCount > 0 ? cast(GLsizeiptr)(faceVertCount * uint.sizeof)
                              : cast(GLsizeiptr)uint.sizeof,
            faceVertCount > 0 ? scratchMatIdData.ptr : &zero, GL_DYNAMIC_DRAW);
        glVertexAttribIPointer(2, 1, GL_UNSIGNED_INT,
                               cast(GLsizei)uint.sizeof, cast(void*)0);
        glEnableVertexAttribArray(2);
        glBindVertexArray(0);

        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
            scratchEdgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
            scratchVertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(faceVao);
        glDisableVertexAttribArray(3);
        glBindVertexArray(0);
    }

    // ---- Weight display: the per-corner colour buffer (task 1090) --------

    /// Turn the weight-colour attribute OFF and drop the validity stamp.
    ///
    /// After this the lit shader's location 3 reads the CURRENT GENERIC
    /// VERTEX ATTRIBUTE, which `LitShader.useProgram` parks at the ramp's
    /// neutral — so "no colours uploaded" renders the measured neutral rather
    /// than the (0,0,0,1) black GL would otherwise supply. The park lives
    /// there and not here on purpose: the generic value is CONTEXT state, so
    /// setting it next to every disable would be N places to lose it.
    ///
    /// PRIVATE: every caller is in this module (`upload`'s tail and
    /// `uploadWeightColors`'s three give-up paths). "Render the neutral" is
    /// reached from outside by asking `uploadWeightColors` for a name that
    /// does not resolve — which is the same door the dangling-selection case
    /// already comes through — not by turning the attribute off directly and
    /// leaving the stamp's invariants to the caller.
    private void disableWeightColors() {
        glBindVertexArray(faceVao);
        glDisableVertexAttribArray(3);
        glBindVertexArray(0);
        weightStampValid = false;
        weightStampMesh  = null;
        weightStampName  = null;
    }

    /// Fill and bind the per-corner weight colours for `mapName` on `m`.
    ///
    /// Idempotent within a frame: the stamp makes the second, third and
    /// fourth cell of a Quad layout free.
    ///
    /// Takes the DISABLE path — which renders the neutral — in every case
    /// where a colour cannot honestly be produced. Each of those is a
    /// measured or memory-safety reason, not a shrug:
    void uploadWeightColors(ref const Mesh m, string mapName) {
        import weightmap_view : resolveWeightMap, weightSurfaceColor;

        // (a) PREVIEW LAYOUT — a memory-safety guard, not a scope note.
        //
        // `faceOriginGpu.length > 0` is this module's existing sentinel for
        // "the face VBO is not 1:1 with the mesh handed to me": the buffers
        // were built from the SUBPATCH PREVIEW mesh, so `faceCornerVert`
        // holds PREVIEW vertex indices — while the caller hands us the CAGE,
        // because that is the mesh the render pass draws and the mesh that
        // carries `meshMaps`. Indexing the cage's weight array (one float per
        // cage vertex) by a preview index (up to hundreds of thousands) is an
        // out-of-range read.
        //
        // Colouring a subdivided surface by a subdivided weight channel is a
        // real feature and a separate one; until it exists, a preview renders
        // the neutral.
        if (faceOriginGpu.length > 0) { disableWeightColors(); return; }

        // (b) The name does not resolve — nothing selected, the map was
        //     removed or renamed out from under the selection, or this is a
        //     mesh that never had it. All three render the neutral, which is
        //     also what a zero weight renders. Measured.
        const(MeshMap)* wm = resolveWeightMap(m, mapName);
        if (wm is null) { disableWeightColors(); return; }

        // (c) Nothing to draw.
        if (faceVertCount <= 0) { disableWeightColors(); return; }

        // Already current for exactly this (mesh, map). See the stamp's own
        // comment for why it keys on those two and on no version.
        if (weightStampValid && weightStampMesh is &m && weightStampName == mapName)
            return;

        immutable size_t need = cast(size_t)faceVertCount * 3;
        if (scratchWeightColor.length < need)
            scratchWeightColor.length = need;

        foreach (i; 0 .. cast(size_t)faceVertCount) {
            immutable uint vi = faceCornerVert[i];
            // Defensive, and it should never fire: `faceCornerVert` came from
            // this mesh's own faces and `resolveWeightMap` guarantees one
            // float per vertex. A face index out of range would mean the mesh
            // and its map disagree about the vertex count, which the resize
            // path maintains — so falling back to 0 (the neutral) is right
            // and silent-corruption is not.
            immutable float w = (vi < wm.data.length) ? wm.data[vi] : 0.0f;
            immutable Vec3 c = weightSurfaceColor(w);
            scratchWeightColor[i * 3 + 0] = c.x;
            scratchWeightColor[i * 3 + 1] = c.y;
            scratchWeightColor[i * 3 + 2] = c.z;
        }

        // Bound INTO faceVao, exactly as matIdVbo is above, so the pointer is
        // captured in the same VAO state the position and normal pointers are.
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, weightColorVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(need * float.sizeof),
            scratchWeightColor.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(3, 3, GL_FLOAT, GL_FALSE,
                              cast(GLsizei)(3 * float.sizeof), cast(void*)0);
        glEnableVertexAttribArray(3);
        glBindVertexArray(0);

        weightStampMesh  = &m;
        weightStampName  = mapName;
        weightStampValid = true;
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
        // Task 1069 — the positions-only refresh reads the DRAWN positions
        // too, or the fast path would silently un-morph the surface that the
        // full upload just morphed.
        const(Vec3)[] vpos;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&mesh);
            vpos = (dv.length == mesh.vertices.length) ? dv : mesh.vertices;
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
                    Vec3 v0 = vpos[i0];
                    Vec3 v1 = vpos[face[1]];
                    Vec3 v2 = vpos[face[2]];
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
                        Vec3 va = vpos[ia];
                        Vec3 vb = vpos[ib];
                        Vec3 vc = vpos[ic];
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
                    Vec3 a = vpos[edge[0]];
                    Vec3 b = vpos[edge[1]];
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
                foreach (vi, v; vpos) {
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
        // Task 1069 — the DRAWN positions (see `upload` above).
        const(Vec3)[] vpos;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&mesh);
            vpos = (dv.length == mesh.vertices.length) ? dv : mesh.vertices;
        }
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
                    Vec3 a = vpos[edge[0]];
                    Vec3 b = vpos[edge[1]];
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
                foreach (vi, v; vpos) {
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
        //
        // TASK 1906 STAGE 3 (plan §Stage 3 item 5) — this was a BARE
        // `++mutationVersion`, i.e. a version bump with no publish, which is
        // exactly the shape `changeBus.missedPublishers` exists to count. It
        // never tripped the guard only because the sibling arm in `upload()`
        // publishes on the same frame path and the OLD guard was maskable by
        // any publisher in the frame. The re-pointed guard is per-mesh and not
        // maskable, so the choice was "convert or exempt": converted, matching
        // the sibling verbatim, since `commitChange(Position)` sets the class
        // AND bumps the version and the sibling's own comment argues at length
        // that the bare bump is the wrong half of that pair.
        if (suppressCageUpload) {
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
        // Task 1069 — the DRAWN positions (see `upload` above).
        const(Vec3)[] vpos;
        {
            import morph_target : displayVertices;
            auto dv = displayVertices(&mesh);
            vpos = (dv.length == mesh.vertices.length) ? dv : mesh.vertices;
        }
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
                    Vec3 v0 = vpos[i0];
                    Vec3 v1 = vpos[face[1]];
                    Vec3 v2 = vpos[face[2]];
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
                foreach (vi, v; vpos) {
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
    void drawFacesHighlighted(const ref LitShader shader, int hoveredFace) {
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
    //
    // TWO PASSES, and a DEPTH BIAS instead of a disabled depth test (task
    // 1862). Until then this was one submission under `glDisable(GL_DEPTH_TEST)`
    // at full strength, which after task 1860 made the fill the only selection
    // feedback still painting an occluded element exactly like a visible one.
    // The law is `OccludedPass`' — the same one `drawEdges` and `drawVertices`
    // obey, and the same three state helpers implement it here, because what
    // differs between the sites is only the primitives submitted between them.
    //
    // TWO BEHAVIOURS CHANGE HERE, NOT ONE, and the second is not optional.
    // Partitioning the depth range into LEQUAL (visible) and GREATER
    // (occluded) requires the depth test ENABLED, so the moment the occluded
    // half exists, a VISIBLE selected face stops being painted unconditionally
    // over whatever is in front of it and becomes depth-tested-and-biased.
    // That is the measured behaviour, but it rides along with the occlusion
    // fix rather than being separable from it; only the bias VALUE is a free
    // parameter, and `kFillDepthBias` carries its derivation.
    //
    // WHAT THIS DOES UNDER A STYLE THAT DRAWS NO FACES: nothing occludes, so
    // pass A passes everywhere and pass B nowhere, and the fill draws at full
    // strength through the model. That is the honest answer rather than an
    // oversight — there IS no surface in that cell for the fill to be behind,
    // and `drawFaces == false` is exactly the cell where task 1830 ruled that
    // the PICKER must stop testing against faces for the same reason. If a
    // future capture says the fill should still be halved there, it needs the
    // cell's `DrawPlan`, not a change here.
    void drawSelectedFacesOverlay(MarkView selectedFaces,
                                  OccludedPass occ = OccludedPass.init) {
        glBindVertexArray(faceVao);

        bool preview = faceOriginGpu.length > 0;
        bool isSelected(int i) {
            int cage = preview ? cast(int)faceOriginGpu[i] : i;
            return cage >= 0 && cage < cast(int)selectedFaces.length && selectedFaces[cage];
        }

        // The batch scan, issued ONCE and CALLED TWICE — the same idiom, for
        // the same reason, as `drawEdges.emitHighlights`: the two passes are
        // required to submit the same primitives in the same order, and two
        // textual copies stop agreeing the first time either is touched.
        void emitFill() {
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
        }

        // ONE bias for BOTH passes, deliberately. LEQUAL and GREATER partition
        // the depth range with no gap only when they compare the same value;
        // biasing one pass and not the other would leave a band that neither
        // paints (or that both do).
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(kFillDepthBias, kFillDepthBias);

        beginVisibleHighlightPass();
        emitFill();

        immutable bool ranOccluded = beginOccludedHighlightPass(occ);
        if (ranOccluded) emitFill();
        endHighlightPasses(occ, ranOccluded);

        glDisable(GL_POLYGON_OFFSET_FILL);
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
    void drawEdges(GLint locColor, int hoveredEdge, MarkView selectedEdges,
                   const bool[] hoveredEdges = [],
                   BaseWire base = BaseWire.init,
                   OccludedPass occ = OccludedPass.init) {
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
        // Index loop rather than a slice: `MarkView` is a borrowed one-bit
        // view, not a range. The `selectedEdges.length >= edgeCount` guard
        // above is kept verbatim, so this reads exactly the same elements the
        // slice did.
        if (allEdgesSelected)
            foreach (i; 0 .. edgeCount)
                if (!selectedEdges[i]) { allEdgesSelected = false; break; }

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

            immutable Vec3 wireCol = schemeColor(SchemeColor.wireframe);
            glUniform3f(locColor, wireCol.x, wireCol.y, wireCol.z);
            if (!anyHover && selectedEdges.empty) {
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

        // ---- Highlight: the selection and pre-highlight, in TWO passes ----
        //
        // See `OccludedPass` for the measured law. The batch scans below are
        // issued ONCE as a nested function and CALLED TWICE rather than
        // written out twice: the two passes are required to submit the same
        // primitives in the same order (the reference attaches one model to
        // both stages), and two textual copies would drift the first time
        // either scan is touched.
        immutable Vec3 selCol = schemeColor(SchemeColor.selection);
        immutable Vec3 preCol = schemeColor(SchemeColor.preHighlight);

        void emitHighlights() {
            if (allEdgesSelected && hoveredEdge < 0) {
                glUniform3f(locColor, selCol.x, selCol.y, selCol.z);
                dcArrays(DrawPass.edges, GL_LINES, 0, edgeVertCount);
            } else if (!selectedEdges.empty) {
                glUniform3f(locColor, selCol.x, selCol.y, selCol.z);
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
                glUniform3f(locColor, preCol.x, preCol.y, preCol.z);
                // Draw EVERY hovered segment (single hovered edge + any
                // loop-mask edges). In preview mode a cage edge fans out to
                // several VBO segments; in cage mode it is 1:1 — segHovered()
                // handles both and also folds in the hoveredEdges loop mask,
                // so a single scan covers the single-edge case and the
                // whole-loop case uniformly.
                for (int i = 0; i < edgeCount; i++)
                    if (segHovered(i))
                        dcArrays(DrawPass.edges, GL_LINES, i * 2, 2);
            }
        }

        // Pass A, then pass B. NEITHER the GL state nor the batch scan is
        // spelled out here: the state lives in `beginVisibleHighlightPass` /
        // `beginOccludedHighlightPass` / `endHighlightPasses` (shared with
        // `drawVertices`, which must not drift from this), the scan lives in
        // `emitHighlights` (shared between the two passes, which must not
        // drift from each other). Each doc comment carries its own reasoning.
        //
        // Pass B submits NOTHING when it refuses to run — an occluded pass
        // with no alpha uniform is the old full-strength rendering, not a
        // slightly-off new one.
        beginVisibleHighlightPass();
        emitHighlights();

        immutable bool ranOccluded = beginOccludedHighlightPass(occ);
        if (ranOccluded) emitHighlights();
        endHighlightPasses(occ, ranOccluded);

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
    //   * the COLOUR is the caller's, not one of the two scheme rows
    //     `drawEdges` reads — item state has three colours and geometry state
    //     has two, and folding them into one function is how the item's
    //     derived hovered-selected shade would end up resolved in here;
    //   * the BASE (grey) pass must not run. In item mode this pass is drawn
    //     OVER a wireframe that has already been laid down, and re-issuing the
    //     grey underneath it would be pure waste.
    //
    // Interior edges are included, not just the silhouette: the reference
    // paints a hovered item's interior edges (measured — 307 of the 956 pixels
    // it painted were on edges that are not on the outline), so a silhouette
    // extraction here would be a different, wrong shape.
    //
    // DEPTH TEST OFF, and DELIBERATELY NOT the two-pass occlusion shape the
    // selection passes moved to in task 1860.
    //
    // The measured two-pass law is a law about the SELECTION model: it is that
    // model the reference attaches to both an ordinary stage and an occluded
    // one. An item's wireframe is painted by a DIFFERENT callback, and that
    // callback does not appear in the viewport's model table at all — nothing
    // ever put it on an occluded stage. So the reference's own evidence says
    // nothing about which depth convention an item highlight takes.
    //
    // Its rig could not have said, either: 0647 measured flat grids, where
    // "occluded" and "visible" are the same set, and its items were laid out
    // deliberately disjoint. Adopting the two-pass shape here would therefore
    // replace one unmeasured convention with another unmeasured one and call
    // the result parity — which is the substitution `CLAUDE.md` forbids under
    // "Unknowns are CAPTURED, not invented".
    //
    // The house convention it keeps: an item's highlight reads as feedback
    // about the ITEM, and feedback occluded by the item's own front faces
    // would answer a question nobody asked. The rig that would settle it — two
    // OVERLAPPING items, the back one lit — is a separate card.
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
    void drawVertices(GLint locColor, int hovered, MarkView selected,
                      OccludedPass occ = OccludedPass.init) {
        glBindVertexArray(vertVao);

        // All vertices — small dots in the WIREFRAME colour, with depth test.
        // One scheme row serves both; see `SchemeColor.wireframe`.
        glPointSize(pointSizePx(kBasePointSize, false));
        immutable Vec3 wireCol = schemeColor(SchemeColor.wireframe);
        glUniform3f(locColor, wireCol.x, wireCol.y, wireCol.z);
        dcArrays(DrawPass.verts, GL_POINTS, 0, vertCount);

        int cageOf(int vboIdx) {
            if (vboIdx >= cast(int)vertOriginGpu.length) return -1;
            uint c = vertOriginGpu[vboIdx];
            return (c == uint.max) ? -1 : cast(int)c;
        }

        // RUN-MERGED (task 1770). These two loops used to issue ONE
        // glDrawArrays PER MATCHING VERTEX. Measured by `frames vert-select`
        // at n=316 with the whole mesh selected: 100 490 calls in the vertex
        // pass, 100 495 in the entire scene — that pass was 99.99 % of every
        // draw call the frame made.
        //
        // Nothing about WHAT is drawn changes: the same VBO indices, submitted
        // in the same order, same point size, same uniform colour. Only the
        // call COUNT changes — a contiguous run becomes one call.
        //
        // WHY THE ORDER SURVIVES THE MERGE, restated for task 1860. This used
        // to read "the depth test is off for both passes so even ordering is
        // immaterial", and that premise is now FALSE: these two loops run
        // inside the two highlight passes below, which are depth-TESTED
        // (`GL_LEQUAL`, then `GL_GREATER`) and the second of which BLENDS. The
        // merge is still exact, but for the reason it always really had: a run
        // collapsed into one `glDrawArrays` submits the same points in the
        // same index order the per-point calls did, and GL orders fragments
        // within a call the way it orders calls, so not one fragment moves.
        // Depth WRITES are masked off in both passes as well, so no submission
        // can change the depth another is tested against. The one ordering
        // that carries meaning — the hover loop running after the selected one
        // so a vertex that is both comes out pre-highlighted — is between the
        // loops, not inside a run, and is untouched.
        //
        // The loops run to `vertCount` INCLUSIVE so the final run is flushed by
        // the same branch that flushes every other one. Without that the last
        // run — which on a whole-mesh selection is the ONLY run — is dropped
        // and the selection stops rendering entirely.
        //
        // WRITTEN TWICE RATHER THAN SHARED THROUGH A PREDICATE, and that is a
        // measurement rather than a style choice. The first draft factored the
        // run-merge into a local taking a `scope bool delegate(int)`; a
        // delegate is an INDIRECT CALL PER VERTEX, and at this vertex count it
        // cost more than the draw calls it saved — frame p50 went 0.390 ->
        // 0.422 ms, an optimisation that was a slowdown. Two explicit loops
        // inline their predicate and keep the win.
        // EARLY-OUT BEFORE THE WALK (task 1790). With nothing selected the
        // loop below still visited every vertex — a bounds check, a load from
        // `vertOriginGpu` and a sentinel compare each — only to draw nothing.
        // That is the shape of every whole-mesh drag, because an empty
        // selection means "all visible" through the fallback rather than
        // "none", so the drag cases never mark a vertex and this walked
        // 100 489 entries per frame for no submission at all.
        //
        // `anySet`, not `empty`: `empty` is only true for a null view. A live
        // view over an unselected mesh is full-length and bitless, which is
        // exactly the case being skipped.
        immutable Vec3 selCol = schemeColor(SchemeColor.selection);
        immutable Vec3 preCol = schemeColor(SchemeColor.preHighlight);

        // Issued once, called twice — see the twin block in `drawEdges` and
        // the `OccludedPass` header for the law. The point SIZE is set inside,
        // so both passes draw the same dot.
        void emitHighlights() {
            glPointSize(pointSizePx(kBasePointSize, true));
            glUniform3f(locColor, selCol.x, selCol.y, selCol.z);
            if (selected.anySet()) {
                int runStart = -1;
                for (int i = 0; i <= vertCount; i++) {
                    bool hit = false;
                    if (i < vertCount) {
                        immutable int c = cageOf(i);
                        hit = c >= 0 && c < cast(int)selected.length && selected[c];
                    }
                    if (hit) {
                        if (runStart < 0) runStart = i;
                    } else if (runStart >= 0) {
                        dcArrays(DrawPass.verts, GL_POINTS, runStart, i - runStart);
                        runStart = -1;
                    }
                }
            }

            if (hovered >= 0) {
                // The SELECTED size, stated rather than inherited. It happens
                // to be what the line above already left in the GL state, and
                // that coincidence is exactly the problem: the measured law is
                // that a pre-highlighted dot is drawn at the selected size
                // (the reference's rollover pass asks for the selected size
                // explicitly), and a law that holds only because of the order
                // of two statements stops holding when they are reordered.
                glPointSize(pointSizePx(kBasePointSize, true));
                glUniform3f(locColor, preCol.x, preCol.y, preCol.z);
                int runStart = -1;
                for (int i = 0; i <= vertCount; i++) {
                    immutable bool hit = (i < vertCount) && cageOf(i) == hovered;
                    if (hit) {
                        if (runStart < 0) runStart = i;
                    } else if (runStart >= 0) {
                        dcArrays(DrawPass.verts, GL_POINTS, runStart, i - runStart);
                        runStart = -1;
                    }
                }
            }
        }

        // Pass A, then pass B — the SAME three calls `drawEdges` makes, not a
        // second copy of them. The reasoning for GL_LEQUAL, for the depth mask
        // being off in both passes, for the second pass being unconditional
        // once it has its alpha, for glBlendFuncSeparate and for restoring the
        // depth func and mask lives on those three functions.
        beginVisibleHighlightPass();
        emitHighlights();

        immutable bool ranOccluded = beginOccludedHighlightPass(occ);
        if (ranOccluded) emitHighlights();
        endHighlightPasses(occ, ranOccluded);

        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}

// ---------------------------------------------------------------------------
// Prepared GL resource lifetime owner (P1.0b.4a, dormant infrastructure)
// ---------------------------------------------------------------------------

private shared ulong nextGpuCreateOwnerId;
struct PreparedGpuCreateToken { @disable this(this); private ulong ownerId, generation; }
struct ValidatedGpuCreateToken { @disable this(this); private ulong ownerId, generation; }

/// Owns names created during fallible preparation until a validated header
/// transfer. No GL call occurs in install; abort deletes every prepared name.
final class GpuCreateOwner {
private:
    enum Backend : ubyte { openGl, fake }
    GpuMesh* target;
    immutable ulong ownerId;
    ulong generation, requiredThread, requiredContext;
    bool pending, validated;
    GpuMeshNames created;
    PreparedGpuCreateToken enlistedPrepared;
    ValidatedGpuCreateToken enlistedValidated;
    Backend backend;
    version (unittest) {
        GLuint nextFake = 101;
        bool failCreateForTest_;
        size_t fakeCleanupCount_;
        GLuint[32] fakeCreated_, fakeDeleted_;
        size_t fakeCreatedLength_, fakeDeletedLength_;
    }
public:
    this(GpuMesh* target, ulong threadIdentity, ulong contextIdentity) {
        this.target = target; requiredThread = threadIdentity;
        requiredContext = contextIdentity;
        ownerId = atomicOp!"+="(nextGpuCreateOwnerId, 1UL);
    }
    version (unittest) static GpuCreateOwner fakeForTest(GpuMesh* target) {
        auto owner = new GpuCreateOwner(target, 7, 11);
        owner.backend = Backend.fake; return owner;
    }
    version (unittest) void failNextCreateForTest() nothrow @nogc {
        failCreateForTest_ = true;
    }
    version (unittest) size_t fakeCleanupCountForTest() const nothrow @nogc {
        return fakeCleanupCount_;
    }
    version (unittest) const(GLuint)[] fakeCreatedForTest() const nothrow @nogc {
        return fakeCreated_[0 .. fakeCreatedLength_];
    }
    version (unittest) const(GLuint)[] fakeDeletedForTest() const nothrow @nogc {
        return fakeDeleted_[0 .. fakeDeletedLength_];
    }
    bool owns(GpuMesh* candidate) const nothrow @nogc { return target is candidate; }
    bool beginEnlistedCreate() nothrow @nogc {
        if (pending || target is null || peekGpuMeshNames(*target) != GpuMeshNames.init)
            return false;
        ++generation;
        version (unittest) {
            if (backend == Backend.fake) {
                GLuint next() nothrow @nogc { return nextFake++; }
                created = GpuMeshNames(next(), next(), next(), next(), next(), next(),
                                       next(), next(), next());
                recordFakeCreated();
                if (failCreateForTest_) {
                    failCreateForTest_ = false; deleteFakeCreated();
                    ++fakeCleanupCount_; return false;
                }
            } else {
                createOpenGlNames();
            }
        } else {
            createOpenGlNames();
        }
        pending = true; validated = false;
        enlistedPrepared.ownerId = ownerId;
        enlistedPrepared.generation = generation;
        return true;
    }
private:
    version (unittest) void recordFakeCreated() nothrow @nogc {
        foreach (name; [created.faceVao, created.faceVbo, created.edgeVao,
                        created.edgeVbo, created.vertVao, created.vertVbo,
                        created.faceIdVbo, created.matIdVbo,
                        created.weightColorVbo])
            fakeCreated_[fakeCreatedLength_++] = name;
    }
    version (unittest) void deleteFakeCreated() nothrow @nogc {
        foreach (name; [created.faceVao, created.faceVbo, created.edgeVao,
                        created.edgeVbo, created.vertVao, created.vertVbo,
                        created.faceIdVbo, created.matIdVbo,
                        created.weightColorVbo])
            fakeDeleted_[fakeDeletedLength_++] = name;
        created = GpuMeshNames.init;
    }
    void createOpenGlNames() nothrow @nogc {
            glGenVertexArrays(1, &created.faceVao); glGenBuffers(1, &created.faceVbo);
            glGenVertexArrays(1, &created.edgeVao); glGenBuffers(1, &created.edgeVbo);
            glGenVertexArrays(1, &created.vertVao); glGenBuffers(1, &created.vertVbo);
            glGenBuffers(1, &created.faceIdVbo); glGenBuffers(1, &created.matIdVbo);
            glGenBuffers(1, &created.weightColorVbo);
    }
public:
    bool validateEnlisted(ulong threadIdentity, ulong contextIdentity) nothrow @nogc {
        if (!pending || validated || !(threadIdentity == requiredThread) ||
            !(contextIdentity == requiredContext) || target is null ||
            peekGpuMeshNames(*target) != GpuMeshNames.init) return false;
        validated = true; enlistedValidated.ownerId = ownerId;
        enlistedValidated.generation = generation; return true;
    }
    void installEnlisted() nothrow @nogc {
        if (pending == false || validated == false || enlistedValidated.ownerId != ownerId ||
            enlistedValidated.generation != generation) return;
        target.faceVao = created.faceVao; target.faceVbo = created.faceVbo;
        target.edgeVao = created.edgeVao; target.edgeVbo = created.edgeVbo;
        target.vertVao = created.vertVao; target.vertVbo = created.vertVbo;
        target.faceIdVbo = created.faceIdVbo; target.matIdVbo = created.matIdVbo;
        target.weightColorVbo = created.weightColorVbo;
        created = GpuMeshNames.init; pending = validated = false;
        enlistedValidated.ownerId = enlistedValidated.generation = 0;
    }
    void abortEnlisted() nothrow @nogc {
        if (!pending) return;
        version (unittest) {
            if (backend == Backend.fake) {
                deleteFakeCreated(); ++fakeCleanupCount_;
            }
            else { deleteGpuMeshNames(created); }
        } else { deleteGpuMeshNames(created); }
        pending = validated = false;
    }
}

version (unittest) unittest {
    GpuMesh target;
    auto owner = GpuCreateOwner.fakeForTest(&target);
    owner.failNextCreateForTest();
    assert(!owner.beginEnlistedCreate());
    assert(owner.fakeCleanupCountForTest() == 1 && target.faceVao == 0);
    assert(owner.fakeCreatedForTest() == [101,102,103,104,105,106,107,108,109]);
    assert(owner.fakeDeletedForTest() == owner.fakeCreatedForTest());
    assert(owner.beginEnlistedCreate());
    assert(target.faceVao == 0, "prepared names leaked into live header");
    assert(!owner.validateEnlisted(8, 11));
    owner.abortEnlisted();
    assert(owner.fakeCleanupCountForTest() == 2 && target.faceVao == 0);
    assert(owner.beginEnlistedCreate());
    assert(owner.validateEnlisted(7, 11));
    owner.installEnlisted();
    assert(target.faceVao != 0 && target.weightColorVbo != 0);
    auto installed = target.faceVao;
    owner.installEnlisted();
    assert(target.faceVao == installed);
    GpuMesh other;
    assert(!owner.owns(&other));
}

/// Closed description of the GL names owned by a GpuMesh.  This value never
/// leaves GpuResourceOwner: prepared effects carry only scalar identity.
private struct GpuMeshNames {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    GLuint vertVao, vertVbo;
    GLuint faceIdVbo, matIdVbo, weightColorVbo;
}

private GpuMeshNames takeGpuMeshNames(ref GpuMesh gpu) nothrow @nogc {
    GpuMeshNames names = GpuMeshNames(
        gpu.faceVao, gpu.faceVbo, gpu.edgeVao, gpu.edgeVbo,
        gpu.vertVao, gpu.vertVbo, gpu.faceIdVbo, gpu.matIdVbo,
        gpu.weightColorVbo);
    gpu.faceVao = gpu.faceVbo = 0;
    gpu.edgeVao = gpu.edgeVbo = 0;
    gpu.vertVao = gpu.vertVbo = 0;
    gpu.faceIdVbo = gpu.matIdVbo = gpu.weightColorVbo = 0;
    gpu.faceVertCount = gpu.edgeVertCount = gpu.vertCount = 0;
    gpu.faceTriStart = null;
    gpu.faceTriCount = null;
    gpu.edgeOriginGpu = null;
    gpu.faceOriginGpu = null;
    gpu.vertOriginGpu = null;
    gpu.faceCornerVert = null;
    gpu.weightStampMesh = null;
    gpu.weightStampName = null;
    gpu.weightStampValid = false;
    gpu.suppressCageUpload = false;
    gpu.uploadVersion = 0;
    gpu.scratchFaceData = null;
    gpu.scratchFaceIdData = null;
    gpu.scratchMatIdData = null;
    gpu.scratchWeightColor = null;
    gpu.scratchEdgeData = null;
    gpu.scratchVertData = null;
    return names;
}

private GpuMeshNames peekGpuMeshNames(ref GpuMesh gpu) nothrow @nogc {
    return GpuMeshNames(gpu.faceVao, gpu.faceVbo, gpu.edgeVao, gpu.edgeVbo,
        gpu.vertVao, gpu.vertVbo, gpu.faceIdVbo, gpu.matIdVbo,
        gpu.weightColorVbo);
}

private void deleteGpuMeshNames(ref GpuMeshNames n) nothrow @nogc {
    // Keep the legacy GpuMesh.destroy order exactly.
    glDeleteVertexArrays(1, &n.faceVao); glDeleteBuffers(1, &n.faceVbo);
    glDeleteVertexArrays(1, &n.edgeVao); glDeleteBuffers(1, &n.edgeVbo);
    glDeleteVertexArrays(1, &n.vertVao); glDeleteBuffers(1, &n.vertVbo);
    glDeleteBuffers(1, &n.faceIdVbo);
    glDeleteBuffers(1, &n.matIdVbo);
    glDeleteBuffers(1, &n.weightColorVbo);
    n = GpuMeshNames.init;
}

private shared ulong nextGpuResourceOwnerId;

struct PreparedGpuResourceToken {
    private ulong ownerId;
    private ulong generation;
}

struct ValidatedGpuResourceToken {
    @disable this(this);
    private ulong ownerId;
    private ulong generation;
}

/// Stable owner for prepared GpuMesh lifetime changes.  It deliberately is a
/// class rather than state embedded in GpuMesh: GpuMesh remains a copied value
/// in background-layer maps, whereas this owner identity must never follow a
/// copied header.  No production caller exists before the unified-door phase.
final class GpuResourceOwner {
    private enum Backend : ubyte { openGl, fake }
    private GpuMesh* target;
    private immutable ulong ownerId;
    private ulong generation;
    private ulong requiredThread;
    private ulong requiredContext;
    private bool pending;
    private bool validated;
    private ValidatedGpuResourceToken enlistedValidated;
    private PreparedGpuResourceToken enlistedPrepared;
    private GpuMeshNames pendingDestroy;
    private Backend backend;
    version (unittest) {
        private GLuint[18] fakeDeleted;
        private size_t fakeDeleteCount;
    }

    this(GpuMesh* target, ulong threadIdentity, ulong contextIdentity) {
        this.target = target;
        requiredThread = threadIdentity;
        requiredContext = contextIdentity;
        ownerId = atomicOp!"+="(nextGpuResourceOwnerId, 1UL);
    }

    version (unittest) private this(GpuMesh* target) {
        this(target, 7, 11);
        backend = Backend.fake;
    }
    version (unittest) static GpuResourceOwner fakeForTest(GpuMesh* target) {
        return new GpuResourceOwner(target);
    }
    version (unittest) size_t fakeDeletionCountForTest() const nothrow @nogc {
        return fakeDeleteCount;
    }
    version (unittest) const(GLuint)[] fakeDeletionsForTest() const nothrow @nogc {
        return fakeDeleted[0 .. fakeDeleteCount];
    }
    bool owns(GpuMesh* candidate) const nothrow @nogc { return target is candidate; }

    bool beginPreparedDestroy(out PreparedGpuResourceToken token) nothrow @nogc {
        if (pending || target is null) return false;
        ++generation;
        pendingDestroy = GpuMeshNames(
            target.faceVao, target.faceVbo, target.edgeVao, target.edgeVbo,
            target.vertVao, target.vertVbo, target.faceIdVbo,
            target.matIdVbo, target.weightColorVbo);
        pending = true;
        validated = false;
        token.ownerId = ownerId;
        token.generation = generation;
        return true;
    }

    bool validatePrepared(PreparedGpuResourceToken token,
                          ulong threadIdentity, ulong contextIdentity,
                          out ValidatedGpuResourceToken validatedToken)
                          nothrow @nogc {
        if (!pending || validated || token.ownerId != ownerId ||
            token.generation != generation ||
            threadIdentity != requiredThread ||
            contextIdentity != requiredContext ||
            peekGpuMeshNames(*target) != pendingDestroy)
            return false;
        validated = true;
        validatedToken.ownerId = ownerId;
        validatedToken.generation = generation;
        return true;
    }

    /// Consumes a prevalidated scalar handle.  All refusal is earlier; a
    /// repeated/stale consume mechanically does nothing and cannot re-delete.
    void installPrepared(ref ValidatedGpuResourceToken token) nothrow @nogc {
        if (!pending || !validated || token.ownerId != ownerId ||
            token.generation != generation) return;
        auto names = takeGpuMeshNames(*target);
        // The live header must still own exactly the names captured at prepare.
        // Door-level joint validation pins this invariant before P1.0c; this
        // dormant seam has no production caller meanwhile.
        pendingDestroy = names;
        version (unittest) {
            if (backend == Backend.fake) {
                immutable size_t at = fakeDeleteCount;
                if (at + 9 <= fakeDeleted.length) {
                    fakeDeleted[at + 0] = names.faceVao;
                    fakeDeleted[at + 1] = names.faceVbo;
                    fakeDeleted[at + 2] = names.edgeVao;
                    fakeDeleted[at + 3] = names.edgeVbo;
                    fakeDeleted[at + 4] = names.vertVao;
                    fakeDeleted[at + 5] = names.vertVbo;
                    fakeDeleted[at + 6] = names.faceIdVbo;
                    fakeDeleted[at + 7] = names.matIdVbo;
                    fakeDeleted[at + 8] = names.weightColorVbo;
                    fakeDeleteCount = at + 9;
                }
                pendingDestroy = GpuMeshNames.init;
            } else deleteGpuMeshNames(pendingDestroy);
        } else deleteGpuMeshNames(pendingDestroy);
        pending = false;
        validated = false;
        token.ownerId = token.generation = 0;
    }

    void discardPrepared(PreparedGpuResourceToken token) nothrow @nogc {
        if (!pending || token.ownerId != ownerId || token.generation != generation)
            return;
        pendingDestroy = GpuMeshNames.init;
        pending = false;
        validated = false;
    }

    bool validateEnlisted(PreparedGpuResourceToken token, ulong threadIdentity,
                          ulong contextIdentity) nothrow @nogc {
        return validatePrepared(token, threadIdentity, contextIdentity,
                                enlistedValidated);
    }

    bool beginEnlistedDestroy() nothrow @nogc {
        return beginPreparedDestroy(enlistedPrepared);
    }
    bool validateEnlisted(ulong threadIdentity, ulong contextIdentity)
                          nothrow @nogc {
        return validateEnlisted(enlistedPrepared, threadIdentity,
                                contextIdentity);
    }

    void installEnlisted() nothrow @nogc {
        installPrepared(enlistedValidated);
    }
    void abortEnlisted() nothrow @nogc {
        pendingDestroy = GpuMeshNames.init;
        pending = false; validated = false;
    }
}

// ---------------------------------------------------------------------------
// Prepared full-upload owner (P1.0b.4b, dormant infrastructure)
// ---------------------------------------------------------------------------

private shared ulong nextGpuUploadOwnerId;
version (unittest) private bool failPreparedGpuUploadAfterBuild;

struct PreparedGpuUploadToken {
    @disable this(this);
private:
    ulong ownerId;
    ulong generation;
}

struct ValidatedGpuUploadToken {
    @disable this(this);
private:
    ulong ownerId;
    ulong generation;
}

private GpuMesh cloneUploadState(ref GpuMesh src) {
    GpuMesh dst;
    // GL identities are borrowed for submission and checked again at validate;
    // the prepared owner never creates, transfers or destroys them.
    dst.faceVao = src.faceVao; dst.faceVbo = src.faceVbo;
    dst.edgeVao = src.edgeVao; dst.edgeVbo = src.edgeVbo;
    dst.vertVao = src.vertVao; dst.vertVbo = src.vertVbo;
    dst.faceIdVbo = src.faceIdVbo; dst.matIdVbo = src.matIdVbo;
    dst.weightColorVbo = src.weightColorVbo;
    dst.faceVertCount = src.faceVertCount;
    dst.edgeVertCount = src.edgeVertCount;
    dst.vertCount = src.vertCount;
    dst.faceTriStart = src.faceTriStart.dup;
    dst.faceTriCount = src.faceTriCount.dup;
    dst.suppressCageUpload = src.suppressCageUpload;
    dst.edgeOriginGpu = src.edgeOriginGpu.dup;
    dst.faceOriginGpu = src.faceOriginGpu.dup;
    dst.vertOriginGpu = src.vertOriginGpu.dup;
    dst.faceCornerVert = src.faceCornerVert.dup;
    dst.weightStampMesh = src.weightStampMesh;
    dst.weightStampName = src.weightStampName.idup;
    dst.weightStampValid = src.weightStampValid;
    dst.uploadVersion = src.uploadVersion;
    dst.scratchFaceData = src.scratchFaceData.dup;
    dst.scratchFaceIdData = src.scratchFaceIdData.dup;
    dst.scratchMatIdData = src.scratchMatIdData.dup;
    dst.scratchWeightColor = src.scratchWeightColor.dup;
    dst.scratchEdgeData = src.scratchEdgeData.dup;
    dst.scratchVertData = src.scratchVertData.dup;
    return dst;
}

// recorded remainder (1906 §3.6): uploadVersion owns the detached GpuMesh
// CPU-image generation; no Mesh change class proves this target was not
// uploaded again after preparation.
private bool sameGpuUploadVersion(const(GpuMesh)* target, ulong expected)
        nothrow @nogc {
    return target !is null && target.uploadVersion == expected;
}

private bool isDefaultEmptyGpuMesh(ref GpuMesh gpu) nothrow @nogc {
    return peekGpuMeshNames(gpu) == GpuMeshNames.init &&
        gpu.faceVertCount == 0 && gpu.edgeVertCount == 0 && gpu.vertCount == 0 &&
        gpu.faceTriStart.length == 0 && gpu.faceTriCount.length == 0 &&
        !gpu.suppressCageUpload && gpu.edgeOriginGpu.length == 0 &&
        gpu.faceOriginGpu.length == 0 && gpu.vertOriginGpu.length == 0 &&
        gpu.faceCornerVert.length == 0 && gpu.weightStampMesh is null &&
        gpu.weightStampName.length == 0 && !gpu.weightStampValid &&
        sameGpuUploadVersion(&gpu, 0) && gpu.scratchFaceData.length == 0 &&
        gpu.scratchFaceIdData.length == 0 && gpu.scratchMatIdData.length == 0 &&
        gpu.scratchWeightColor.length == 0 && gpu.scratchEdgeData.length == 0 &&
        gpu.scratchVertData.length == 0;
}

private void installUploadState(ref GpuMesh dst, ref GpuMesh src) nothrow @nogc {
    dst.faceVertCount = src.faceVertCount;
    dst.edgeVertCount = src.edgeVertCount;
    dst.vertCount = src.vertCount;
    dst.faceTriStart = src.faceTriStart;
    dst.faceTriCount = src.faceTriCount;
    dst.edgeOriginGpu = src.edgeOriginGpu;
    dst.faceOriginGpu = src.faceOriginGpu;
    dst.vertOriginGpu = src.vertOriginGpu;
    dst.faceCornerVert = src.faceCornerVert;
    dst.weightStampMesh = src.weightStampMesh;
    dst.weightStampName = src.weightStampName;
    dst.weightStampValid = src.weightStampValid;
    dst.uploadVersion = src.uploadVersion;
    dst.scratchFaceData = src.scratchFaceData;
    dst.scratchFaceIdData = src.scratchFaceIdData;
    dst.scratchMatIdData = src.scratchMatIdData;
    dst.scratchWeightColor = src.scratchWeightColor;
    dst.scratchEdgeData = src.scratchEdgeData;
    dst.scratchVertData = src.scratchVertData;
    src.faceTriStart = null; src.faceTriCount = null;
    src.edgeOriginGpu = null; src.faceOriginGpu = null;
    src.vertOriginGpu = null; src.faceCornerVert = null;
    src.weightStampMesh = null; src.weightStampName = null;
    src.scratchFaceData = null; src.scratchFaceIdData = null;
    src.scratchMatIdData = null; src.scratchWeightColor = null;
    src.scratchEdgeData = null; src.scratchVertData = null;
}

/// Owns one detached CPU upload image for one stable GpuMesh. Preparation is
/// allocation-only; validation is scalar/identity-only; installation performs
/// the fixed GL call sequence and header transfer. No production caller exists
/// before P1.0c.
final class GpuUploadOwner {
private:
    enum Backend : ubyte { openGl, fake }
    GpuMesh* target;
    immutable ulong ownerId;
    ulong generation;
    ulong requiredThread, requiredContext;
    ulong baseUploadVersion;
    GpuMeshNames baseNames;
    GpuMesh prepared;
    long uploadedVertexCount;
    bool pending, validated;
    ValidatedGpuUploadToken enlistedValidated;
    PreparedGpuUploadToken enlistedPrepared;
    Backend backend;
    version (unittest) {
        uint[16] fakeCalls;
        size_t fakeCallCount;
    }

public:
    this(GpuMesh* target, ulong threadIdentity, ulong contextIdentity) {
        this.target = target;
        requiredThread = threadIdentity;
        requiredContext = contextIdentity;
        ownerId = atomicOp!"+="(nextGpuUploadOwnerId, 1UL);
    }

    version (unittest) private this(GpuMesh* target) {
        this(target, 7, 11);
        backend = Backend.fake;
    }
    version (unittest) static GpuUploadOwner fakeForTest(GpuMesh* target) {
        return new GpuUploadOwner(target);
    }
    version (unittest) const(uint)[] fakeCallsForTest() const nothrow @nogc {
        return fakeCalls[0 .. fakeCallCount];
    }
    version (unittest) static void failPreparedUploadForTest(bool value)
            nothrow @nogc { failPreparedGpuUploadAfterBuild = value; }
    bool owns(GpuMesh* candidate) const nothrow @nogc { return target is candidate; }

    bool beginPreparedUpload(ref const Mesh mesh,
                       const uint[] edgeOrigin,
                       const uint[] vertOrigin,
                       const uint[] faceOrigin,
                       out PreparedGpuUploadToken token) {
        if (pending || target is null ||
            (target.suppressCageUpload && edgeOrigin.length == 0 &&
             vertOrigin.length == 0)) return false;
        import morph_target : displayVertices;
        auto dv = displayVertices(&mesh);
        const(Vec3)[] vpos = (dv.length == mesh.vertices.length)
                          ? dv : mesh.vertices;
        auto next = cloneUploadState(*target);
        next.uploadVersion = target.uploadVersion + 1;
        next.buildUploadCpu(mesh, vpos, edgeOrigin, vertOrigin, faceOrigin);
        version (unittest) if (failPreparedGpuUploadAfterBuild)
            throw new Exception("injected prepared GPU upload failure");
        ++generation;
        prepared = next;
        baseUploadVersion = target.uploadVersion;
        baseNames = peekGpuMeshNames(*target);
        uploadedVertexCount = cast(long)mesh.vertices.length;
        pending = true;
        validated = false;
        token.ownerId = ownerId;
        token.generation = generation;
        return true;
    }

    bool validatePreparedUpload(ref PreparedGpuUploadToken token,
                          ulong threadIdentity, ulong contextIdentity,
                          out ValidatedGpuUploadToken result) nothrow @nogc {
        // recorded remainder (1906 §3.6): uploadVersion owns the detached
        // GpuMesh CPU-image generation; no Mesh change class can establish
        // that this same GPU target was not uploaded again after preparation.
        if (!pending || validated || target is null ||
            token.ownerId != ownerId || token.generation != generation ||
            requiredThread != threadIdentity ||
            requiredContext != contextIdentity ||
            !sameGpuUploadVersion(target, baseUploadVersion) ||
            peekGpuMeshNames(*target) != baseNames) return false;
        validated = true;
        result.ownerId = token.ownerId;
        result.generation = token.generation;
        token.ownerId = token.generation = 0;
        return true;
    }

    void installPreparedUpload(ref ValidatedGpuUploadToken token) nothrow @nogc {
        if (!pending || !validated || token.ownerId != ownerId ||
            token.generation != generation) return;
        g_fc.upload(uploadedVertexCount);
        version (unittest) {
            if (backend == Backend.fake) {
                // The fake sequence names the same seven submission groups as
                // submitUploadGl: face, face-id, material, edge, vertex,
                // weight-disable, unbind.
                fakeCalls[fakeCallCount++] = 1;
                fakeCalls[fakeCallCount++] = 2;
                fakeCalls[fakeCallCount++] = 3;
                fakeCalls[fakeCallCount++] = 4;
                fakeCalls[fakeCallCount++] = 5;
                fakeCalls[fakeCallCount++] = 6;
                fakeCalls[fakeCallCount++] = 7;
            } else prepared.submitUploadGl();
        } else prepared.submitUploadGl();
        installUploadState(*target, prepared);
        pending = false;
        validated = false;
        token.ownerId = token.generation = 0;
    }

    void discardPreparedUpload(ref PreparedGpuUploadToken token) nothrow @nogc {
        if (!pending || token.ownerId != ownerId ||
            token.generation != generation) return;
        GpuMesh empty;
        prepared = empty;
        pending = false;
        validated = false;
        token.ownerId = token.generation = 0;
    }

    bool validateEnlisted(ref PreparedGpuUploadToken token,
                          ulong threadIdentity, ulong contextIdentity)
                          nothrow @nogc {
        return validatePreparedUpload(token, threadIdentity, contextIdentity,
                                      enlistedValidated);
    }

    bool beginEnlistedUpload(ref const Mesh mesh, const uint[] edgeOrigin,
                             const uint[] vertOrigin, const uint[] faceOrigin) {
        return beginPreparedUpload(mesh, edgeOrigin, vertOrigin, faceOrigin,
                                   enlistedPrepared);
    }
    bool validateEnlisted(ulong threadIdentity, ulong contextIdentity)
                          nothrow @nogc {
        return validateEnlisted(enlistedPrepared, threadIdentity,
                                contextIdentity);
    }

    void installEnlisted() nothrow @nogc {
        installPreparedUpload(enlistedValidated);
    }
    void abortEnlisted() nothrow @nogc {
        GpuMesh empty; prepared = empty;
        pending = false; validated = false;
    }
}

// ---------------------------------------------------------------------------
// Prepared combined GL create + first upload owner (dormant infrastructure)
// ---------------------------------------------------------------------------

private shared ulong nextGpuCreateUploadOwnerId;
struct PreparedGpuCreateUploadToken {
    @disable this(this);
private: ulong ownerId, generation;
}
struct ValidatedGpuCreateUploadToken {
    @disable this(this);
private: ulong ownerId, generation;
}

/// One closed transaction for an empty GpuMesh's first upload. Preparation
/// owns both the newly generated names and the detached CPU upload image;
/// install submits through those off-target names and publishes the complete
/// header only after submission. There is no observable create-only state.
final class GpuCreateUploadOwner {
private:
    enum Backend : ubyte { openGl, fake }
    GpuMesh* target;
    immutable ulong ownerId;
    ulong generation, requiredThread, requiredContext, baseUploadVersion;
    GpuMeshNames created;
    GpuMesh prepared;
    long uploadedVertexCount;
    bool pending, validated, consumed;
    PreparedGpuCreateUploadToken enlistedPrepared;
    ValidatedGpuCreateUploadToken enlistedValidated;
    Backend backend;
    version(unittest) {
        GLuint nextFake = 301;
        GLuint[32] fakeCreated, fakeDeleted;
        size_t fakeCreatedLength, fakeDeletedLength;
        uint[16] fakeCalls;
        GLuint[16] fakeUsedNames;
        size_t fakeCallLength;
        bool failAfterBuild;
    }
public:
    this(GpuMesh* target, ulong threadIdentity, ulong contextIdentity) {
        this.target = target; requiredThread = threadIdentity;
        requiredContext = contextIdentity;
        ownerId = atomicOp!"+="(nextGpuCreateUploadOwnerId, 1UL);
    }
    version(unittest) static GpuCreateUploadOwner fakeForTest(GpuMesh* target) {
        auto result = new GpuCreateUploadOwner(target, 7, 11);
        result.backend = Backend.fake; return result;
    }
    version(unittest) void failAfterBuildForTest() nothrow @nogc { failAfterBuild = true; }
    version(unittest) const(GLuint)[] fakeCreatedForTest() const nothrow @nogc {
        return fakeCreated[0 .. fakeCreatedLength];
    }
    version(unittest) const(GLuint)[] fakeDeletedForTest() const nothrow @nogc {
        return fakeDeleted[0 .. fakeDeletedLength];
    }
    version(unittest) const(uint)[] fakeCallsForTest() const nothrow @nogc {
        return fakeCalls[0 .. fakeCallLength];
    }
    version(unittest) const(GLuint)[] fakeUsedNamesForTest() const nothrow @nogc {
        return fakeUsedNames[0 .. fakeCallLength];
    }
    bool owns(GpuMesh* candidate) const nothrow @nogc { return target is candidate; }

    bool beginEnlisted(ref const Mesh mesh) {
        if (pending || consumed || target is null || !isDefaultEmptyGpuMesh(*target))
            return false;
        baseUploadVersion = target.uploadVersion;
        scope(failure) cleanupPrepared();
        version(unittest) {
            if (backend == Backend.fake) {
                GLuint next() nothrow @nogc { return nextFake++; }
                created = GpuMeshNames(next(), next(), next(), next(), next(), next(),
                    next(), next(), next());
                recordCreated();
            } else createNames();
        } else createNames();
        auto next = cloneUploadState(*target);
        setNames(next, created);
        import morph_target : displayVertices;
        auto dv = displayVertices(&mesh);
        const(Vec3)[] vpos = dv.length == mesh.vertices.length ? dv : mesh.vertices;
        next.uploadVersion = baseUploadVersion + 1;
        next.buildUploadCpu(mesh, vpos, null, null, null);
        version(unittest) if (failAfterBuild) {
            failAfterBuild = false;
            throw new Exception("injected combined create-upload build failure");
        }
        prepared = next; uploadedVertexCount = cast(long)mesh.vertices.length;
        ++generation; pending = true; validated = false;
        enlistedPrepared.ownerId = ownerId;
        enlistedPrepared.generation = generation; return true;
    }
    bool validateEnlisted(ulong threadIdentity, ulong contextIdentity) nothrow @nogc {
        if (!pending || validated || target is null ||
            enlistedPrepared.ownerId != ownerId ||
            enlistedPrepared.generation != generation ||
            (threadIdentity ^ requiredThread) != 0 ||
            (contextIdentity ^ requiredContext) != 0 ||
            !sameGpuUploadVersion(target, baseUploadVersion) ||
            !isDefaultEmptyGpuMesh(*target)) return false;
        validated = true; enlistedValidated.ownerId = ownerId;
        enlistedValidated.generation = generation;
        enlistedPrepared.ownerId = enlistedPrepared.generation = 0; return true;
    }
    void installEnlisted() nothrow @nogc {
        if (!pending || !validated || target is null ||
            enlistedValidated.ownerId != ownerId ||
            enlistedValidated.generation != generation) return;
        g_fc.upload(uploadedVertexCount);
        version(unittest) {
            if (backend == Backend.fake) {
                immutable GLuint[7] used = [created.faceVao, created.faceIdVbo,
                    created.matIdVbo, created.edgeVao, created.vertVao,
                    created.faceVao, 0];
                foreach (i; 0 .. 7) {
                    fakeCalls[fakeCallLength] = cast(uint)(i + 1);
                    fakeUsedNames[fakeCallLength++] = used[i];
                }
            }
            else prepared.submitUploadGl();
        } else prepared.submitUploadGl();
        setNames(*target, created);
        installUploadState(target[0], prepared);
        created = GpuMeshNames.init;
        pending = validated = false; consumed = true;
        enlistedValidated.ownerId = enlistedValidated.generation = 0;
    }
    void abortEnlisted() nothrow @nogc { if (pending) cleanupPrepared(); }
private:
    static void setNames(ref GpuMesh gpu, GpuMeshNames names) nothrow @nogc {
        gpu.faceVao=names.faceVao; gpu.faceVbo=names.faceVbo;
        gpu.edgeVao=names.edgeVao; gpu.edgeVbo=names.edgeVbo;
        gpu.vertVao=names.vertVao; gpu.vertVbo=names.vertVbo;
        gpu.faceIdVbo=names.faceIdVbo; gpu.matIdVbo=names.matIdVbo;
        gpu.weightColorVbo=names.weightColorVbo;
    }
    void createNames() nothrow @nogc {
        glGenVertexArrays(1,&created.faceVao); glGenBuffers(1,&created.faceVbo);
        glGenVertexArrays(1,&created.edgeVao); glGenBuffers(1,&created.edgeVbo);
        glGenVertexArrays(1,&created.vertVao); glGenBuffers(1,&created.vertVbo);
        glGenBuffers(1,&created.faceIdVbo); glGenBuffers(1,&created.matIdVbo);
        glGenBuffers(1,&created.weightColorVbo);
    }
    version(unittest) void recordCreated() nothrow @nogc {
        foreach (name; [created.faceVao,created.faceVbo,created.edgeVao,
                created.edgeVbo,created.vertVao,created.vertVbo,
                created.faceIdVbo,created.matIdVbo,created.weightColorVbo])
            fakeCreated[fakeCreatedLength++] = name;
    }
    void cleanupPrepared() nothrow @nogc {
        version(unittest) {
            if (backend == Backend.fake) foreach (name; [created.faceVao,
                    created.faceVbo,created.edgeVao,created.edgeVbo,created.vertVao,
                    created.vertVbo,created.faceIdVbo,created.matIdVbo,
                    created.weightColorVbo]) fakeDeleted[fakeDeletedLength++] = name;
            else deleteGpuMeshNames(created);
        } else deleteGpuMeshNames(created);
        created = GpuMeshNames.init; GpuMesh empty; prepared = empty;
        pending = validated = false; consumed = true;
        enlistedPrepared.ownerId = enlistedPrepared.generation = 0;
        enlistedValidated.ownerId = enlistedValidated.generation = 0;
    }
}

version(unittest) unittest {
    static assert(!__traits(compiles, {
        PreparedGpuCreateUploadToken a; auto b = a;
    }));
    static assert(!__traits(compiles, {
        ValidatedGpuCreateUploadToken a; auto b = a;
    }));
    Mesh source = makeCube(); GpuMesh target;
    GpuMesh namesDirty; namesDirty.faceVao = 77;
    auto namesRefused = GpuCreateUploadOwner.fakeForTest(&namesDirty);
    assert(!namesRefused.beginEnlisted(source) && namesDirty.faceVao == 77);
    GpuMesh suppressDirty; suppressDirty.suppressCageUpload = true;
    auto suppressRefused = GpuCreateUploadOwner.fakeForTest(&suppressDirty);
    assert(!suppressRefused.beginEnlisted(source) &&
        suppressDirty.suppressCageUpload && suppressDirty.faceVao == 0);
    GpuMesh projectionDirty; projectionDirty.faceVertCount = 4;
    auto projectionRefused = GpuCreateUploadOwner.fakeForTest(&projectionDirty);
    assert(!projectionRefused.beginEnlisted(source) && projectionDirty.faceVertCount == 4);
    auto failed = GpuCreateUploadOwner.fakeForTest(&target);
    failed.failAfterBuildForTest(); bool threw;
    try failed.beginEnlisted(source); catch (Exception) threw = true;
    assert(threw && target.faceVao == 0 &&
        failed.fakeCreatedForTest() == failed.fakeDeletedForTest());
    auto owner = GpuCreateUploadOwner.fakeForTest(&target);
    assert(owner.beginEnlisted(source)); source.vertices.length = 0;
    GpuMesh other;
    assert(owner.owns(&target) && !owner.owns(&other));
    assert(target.faceVao == 0 && !owner.validateEnlisted(8,11) &&
        !owner.validateEnlisted(7,12));
    owner.abortEnlisted();
    assert(!owner.beginEnlisted(source));
    auto retry = GpuCreateUploadOwner.fakeForTest(&target);
    source = makeCube(); assert(retry.beginEnlisted(source));
    auto uploadsBefore = g_fc.uploadCallsForTest();
    assert(retry.validateEnlisted(7,11)); retry.installEnlisted();
    assert(target.faceVao == 301 && target.weightColorVbo == 309);
    assert(target.uploadVersion == 1 && target.faceVertCount == 36 &&
        target.edgeVertCount == 24 && target.vertCount == 8);
    assert(target.faceTriStart.length == 6 && target.faceTriCount.length == 6 &&
        target.faceCornerVert.length == 36);
    assert(target.edgeOriginGpu.length == 0 && target.faceOriginGpu.length == 0 &&
        target.vertOriginGpu.length == 8 && target.vertOriginGpu[7] == 7);
    assert(target.weightStampMesh is null && target.weightStampName.length == 0 &&
        !target.weightStampValid);
    assert(!target.suppressCageUpload);
    assert(target.scratchFaceData.length == 216 &&
        target.scratchFaceIdData.length == 36 && target.scratchMatIdData.length == 36 &&
        target.scratchWeightColor.length == 0 && target.scratchEdgeData.length == 72 &&
        target.scratchVertData.length == 24);
    assert(retry.fakeCallsForTest() == [1,2,3,4,5,6,7] &&
        retry.fakeUsedNamesForTest() == [301,307,308,303,305,301,0] &&
        g_fc.uploadCallsForTest() == uploadsBefore + 1);
    retry.installEnlisted();
    assert(retry.fakeCallsForTest() == [1,2,3,4,5,6,7] &&
        g_fc.uploadCallsForTest() == uploadsBefore + 1 &&
        !retry.beginEnlisted(source));
}

version (unittest) unittest {
    GpuMesh gpu;
    gpu.faceVao = 1; gpu.faceVbo = 2; gpu.edgeVao = 3; gpu.edgeVbo = 4;
    gpu.vertVao = 5; gpu.vertVbo = 6; gpu.faceIdVbo = 7;
    gpu.matIdVbo = 8; gpu.weightColorVbo = 9;
    auto owner = new GpuResourceOwner(&gpu);
    PreparedGpuResourceToken token;
    assert(owner.beginPreparedDestroy(token));
    PreparedGpuResourceToken overlap;
    assert(!owner.beginPreparedDestroy(overlap));
    ValidatedGpuResourceToken wrong;
    assert(!owner.validatePrepared(token, 8, 11, wrong));
    assert(gpu.faceVao == 1 && gpu.weightColorVbo == 9);
    ValidatedGpuResourceToken ready;
    assert(owner.validatePrepared(token, 7, 11, ready));
    owner.installPrepared(ready);
    assert(gpu.faceVao == 0 && gpu.weightColorVbo == 0);
    assert(owner.fakeDeleted[0 .. 9] == [1,2,3,4,5,6,7,8,9]);
    owner.installPrepared(ready);
    assert(owner.fakeDeleteCount == 9);

    // Every fallible validation refusal is zero-live and recoverable.
    GpuMesh otherGpu;
    auto otherOwner = new GpuResourceOwner(&otherGpu);
    PreparedGpuResourceToken otherToken;
    assert(otherOwner.beginPreparedDestroy(otherToken));
    gpu.faceVao = 21; gpu.faceVbo = 22;
    gpu.edgeVao = 23; gpu.edgeVbo = 24;
    gpu.vertVao = 25; gpu.vertVbo = 26;
    gpu.faceIdVbo = 27; gpu.matIdVbo = 28; gpu.weightColorVbo = 29;
    gpu.faceVertCount = 31; gpu.edgeVertCount = 32; gpu.vertCount = 33;
    gpu.faceTriStart = [34]; gpu.faceTriCount = [35];
    gpu.suppressCageUpload = true;
    gpu.edgeOriginGpu = [36]; gpu.faceOriginGpu = [37];
    gpu.vertOriginGpu = [38]; gpu.faceCornerVert = [39];
    gpu.weightStampMesh = cast(const(Mesh)*)0x1234;
    gpu.weightStampName = "prepared-gpu-sentinel";
    gpu.weightStampValid = true; gpu.uploadVersion = 40;
    gpu.scratchFaceData = [41.0f]; gpu.scratchFaceIdData = [42];
    gpu.scratchMatIdData = [43]; gpu.scratchWeightColor = [44.0f];
    gpu.scratchEdgeData = [45.0f]; gpu.scratchVertData = [46.0f];
    GpuMesh fullProjection = gpu;
    PreparedGpuResourceToken fresh;
    assert(owner.beginPreparedDestroy(fresh));
    otherToken.generation = fresh.generation; // isolate owner-id rejection
    ValidatedGpuResourceToken refused;
    assert(!owner.validatePrepared(otherToken, 7, 11, refused));
    assert(gpu == fullProjection && owner.fakeDeleteCount == 9);
    otherOwner.discardPrepared(otherToken);

    auto stale = fresh;
    ++stale.generation;
    assert(!owner.validatePrepared(stale, 7, 11, refused));
    assert(gpu == fullProjection && owner.fakeDeleteCount == 9);
    assert(!owner.validatePrepared(fresh, 7, 12, refused));
    assert(gpu == fullProjection && owner.fakeDeleteCount == 9);
    gpu.faceVao = 23; // resource identity changed after capture
    assert(!owner.validatePrepared(fresh, 7, 11, refused));
    auto changedProjection = fullProjection;
    changedProjection.faceVao = 23;
    assert(gpu == changedProjection && owner.fakeDeleteCount == 9);
    gpu.faceVao = 21;
    owner.discardPrepared(fresh);
    assert(gpu == fullProjection && owner.fakeDeleteCount == 9);
    assert(!owner.validatePrepared(fresh, 7, 11, refused));
    assert(gpu == fullProjection && owner.fakeDeleteCount == 9);

    PreparedGpuResourceToken recovered;
    assert(owner.beginPreparedDestroy(recovered));
    ValidatedGpuResourceToken recoveredReady;
    assert(owner.validatePrepared(recovered, 7, 11, recoveredReady));
    owner.installPrepared(recoveredReady);
    assert(gpu.faceVao == 0 && gpu.faceVbo == 0);
    assert(owner.fakeDeleteCount == 18);
    assert(owner.fakeDeleted[9 .. 18] == [21,22,23,24,25,26,27,28,29]);
}

version (unittest) static assert(!__traits(compiles, {
    void copyValidatedToken(ValidatedGpuResourceToken source) {
        auto copy = source;
    }
}));

version (unittest) unittest {
    auto mesh = makeCube();
    mesh.faceMaterial.length = mesh.faces.length;
    foreach (i, ref material; mesh.faceMaterial)
        material = cast(uint)(i + 17);

    GpuMesh gpu;
    gpu.faceVao = 101; gpu.faceVbo = 102;
    gpu.edgeVao = 103; gpu.edgeVbo = 104;
    gpu.vertVao = 105; gpu.vertVbo = 106;
    gpu.faceIdVbo = 107; gpu.matIdVbo = 108;
    gpu.weightColorVbo = 109;
    gpu.uploadVersion = 12;
    gpu.weightStampMesh = &mesh;
    gpu.weightStampName = "old weights";
    gpu.weightStampValid = true;

    // The direct builder is the byte-for-byte legacy oracle. Preparation must
    // produce the same owned image without changing the live target.
    auto oracle = cloneUploadState(gpu);
    oracle.uploadVersion++;
    oracle.buildUploadCpu(mesh, mesh.vertices, null, null, null);
    auto liveBefore = cloneUploadState(gpu);
    auto owner = new GpuUploadOwner(&gpu);
    PreparedGpuUploadToken token;
    assert(owner.beginPreparedUpload(mesh, null, null, null, token));
    assert(gpu.uploadVersion == liveBefore.uploadVersion);
    assert(gpu.weightStampValid && gpu.weightStampName == "old weights");
    assert(owner.prepared.faceVertCount == oracle.faceVertCount);
    assert(owner.prepared.edgeVertCount == oracle.edgeVertCount);
    assert(owner.prepared.vertCount == oracle.vertCount);
    assert(owner.prepared.scratchFaceData == oracle.scratchFaceData);
    assert(owner.prepared.scratchFaceIdData == oracle.scratchFaceIdData);
    assert(owner.prepared.scratchMatIdData == oracle.scratchMatIdData);
    assert(owner.prepared.scratchEdgeData == oracle.scratchEdgeData);
    assert(owner.prepared.scratchVertData == oracle.scratchVertData);
    assert(owner.prepared.faceTriStart == oracle.faceTriStart);
    assert(owner.prepared.faceTriCount == oracle.faceTriCount);
    assert(owner.prepared.faceCornerVert == oracle.faceCornerVert);

    // Prepared bytes own their source lifetime: later source mutation cannot
    // alias the detached image.
    auto firstPreparedPosition = owner.prepared.scratchFaceData[0];
    mesh.vertices[0].x += 500;
    assert(owner.prepared.scratchFaceData[0] == firstPreparedPosition);

    ValidatedGpuUploadToken refused;
    assert(!owner.validatePreparedUpload(token, 8, 11, refused));
    assert(!owner.validatePreparedUpload(token, 7, 12, refused));
    assert(gpu.uploadVersion == 12 && owner.fakeCallCount == 0);
    ValidatedGpuUploadToken ready;
    assert(owner.validatePreparedUpload(token, 7, 11, ready));
    owner.installPreparedUpload(ready);
    assert(gpu.uploadVersion == 13);
    assert(!gpu.weightStampValid && gpu.weightStampMesh is null);
    assert(gpu.faceVao == 101 && gpu.weightColorVbo == 109);
    assert(gpu.scratchFaceData == oracle.scratchFaceData);
    assert(owner.fakeCalls[0 .. owner.fakeCallCount] == [1,2,3,4,5,6,7]);
    owner.installPreparedUpload(ready);
    assert(owner.fakeCallCount == 7); // consumed installs are potent no-ops

    // Suppression remains the wrapper's live Position-publish branch; this
    // dormant owner deliberately refuses to prepare it.
    GpuMesh suppressed;
    suppressed.suppressCageUpload = true;
    auto suppressedOwner = new GpuUploadOwner(&suppressed);
    PreparedGpuUploadToken suppressedToken;
    assert(!suppressedOwner.beginPreparedUpload(mesh, null, null, null,
                                                 suppressedToken));

    // An allocation-path failure leaves both target and owner reusable.
    GpuMesh faultTarget;
    faultTarget.uploadVersion = 44;
    auto faultOwner = new GpuUploadOwner(&faultTarget);
    PreparedGpuUploadToken faultToken;
    failPreparedGpuUploadAfterBuild = true;
    bool threw;
    try faultOwner.beginPreparedUpload(mesh, null, null, null, faultToken);
    catch (Exception) threw = true;
    failPreparedGpuUploadAfterBuild = false;
    assert(threw && faultTarget.uploadVersion == 44 && !faultOwner.pending);
    assert(faultOwner.beginPreparedUpload(mesh, null, null, null, faultToken));
    faultOwner.discardPreparedUpload(faultToken);

    // Resource and version identities are jointly rechecked after prepare.
    GpuMesh changed;
    changed.faceVao = 71;
    changed.uploadVersion = 5;
    auto changedOwner = new GpuUploadOwner(&changed);
    PreparedGpuUploadToken changedToken;
    assert(changedOwner.beginPreparedUpload(mesh, null, null, null,
                                             changedToken));
    changed.uploadVersion = 6;
    assert(!changedOwner.validatePreparedUpload(changedToken, 7, 11, refused));
    changed.uploadVersion = 5;
    changed.faceVao = 72;
    assert(!changedOwner.validatePreparedUpload(changedToken, 7, 11, refused));
    changed.faceVao = 71;
    changedOwner.discardPreparedUpload(changedToken);
}

version (unittest) static assert(!__traits(compiles, {
    void copyValidatedUploadToken(ValidatedGpuUploadToken source) {
        auto copy = source;
    }
}));
