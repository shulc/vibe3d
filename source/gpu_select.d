module gpu_select;

import bindbc.opengl;
import std.string : toStringz;

import math   : Viewport;
import mesh   : GpuMesh, Mesh;
import shader : compileShader;

// ---------------------------------------------------------------------------
// GpuSelectBuffer — offscreen ID-buffer picker for vertices, edges, faces.
// Mirrors Blender's DRW_select_buffer
// (source/blender/editors/mesh/editmesh_select.cc:EDBM_*_find_nearest_ex).
//
// Why: per-element heuristic visibility tests (project-and-bbox / midpoint /
// "both endpoints visible" / centroid raycast) all reject elements the user
// can clearly see in some configuration and accept ones they can't. Per-
// pixel GPU depth-test sidesteps all of these.
//
// What this does: for the requested edit mode, render every cage element
// into an offscreen R32UI texture with its index encoded as the colour
// value (id = elementIndex + 1; 0 means "no element"). A depth pre-pass
// over faces (vertex/edge passes only — the face pass IS the surface)
// gives GPU-correct occlusion with polygon-offset matching drawFaces. To
// pick, read back a small window around the cursor and choose the nearest
// non-zero ID by manhattan distance.
//
// Subpatch preview mode: GpuMesh's VBOs hold PREVIEW geometry, not cage.
// gl_VertexID / per-vertex face-id attribute yields a preview index; CPU
// translates back to a cage element via gpu.vertOriginGpu /
// gpu.edgeOriginGpu / gpu.faceOriginGpu after readback.
//
// Cache key: (mode, mesh.mutationVersion, view, proj, FBO size). One
// cache slot per mode so flipping edit modes 1/2/3 doesn't churn the
// buffer; camera and mesh changes invalidate all three slots.
// ---------------------------------------------------------------------------

enum SelectMode {
    Vertex,
    Edge,
    Face,
}

// ---- Vertex pass --------------------------------------------------------
// gl_VertexID + 1 is the ID. GL_POINTS rasterises one pixel per point.
private immutable string vertVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    flat out uint vID;
    void main() {
        vID = uint(gl_VertexID) + 1u;
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

// ---- Edge pass ----------------------------------------------------------
// GL_LINES: each pair of consecutive verts is one segment, gl_VertexID/2
// is the segment index.
private immutable string edgeVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    flat out uint vID;
    void main() {
        vID = uint(gl_VertexID / 2) + 1u;
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

// ---- Face pass ----------------------------------------------------------
// Per-vertex face-index attribute (gpu.faceIdVbo). Same value across all
// triangle-fan vertices of a face → rasterised polygon fills with one ID.
private immutable string faceVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in uint aFaceId;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    flat out uint vID;
    void main() {
        vID = aFaceId + 1u;
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

// Depth-only face pass for vertex / edge passes: fills depth, writes 0
// into colour so picking inside a face surface returns nothing.
private immutable string depthVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

private immutable string commonFragSrc = q{
    #version 330 core
    flat in uint vID;
    out uint fragID;
    void main() {
        fragID = vID;
    }
};

private immutable string zeroFragSrc = q{
    #version 330 core
    out uint fragID;
    void main() {
        fragID = 0u;
    }
};

class GpuSelectBuffer {
private:
    GLuint fbo;
    GLuint colorTex;
    GLuint depthRbo;
    int    fboW, fboH;

    GLuint vertProgram, edgeProgram, faceProgram, depthProgram;
    GLint  vertLocView,  vertLocProj;
    GLint  edgeLocView,  edgeLocProj;
    GLint  faceLocView,  faceLocProj;
    GLint  depthLocView, depthLocProj;

    // Selection-only VAOs that combine GpuMesh's VBOs into the attribute
    // layout our shaders expect. faceSelVao binds faceVbo at attr 0
    // (skipping the interleaved normal attr 1 used by the main render)
    // and faceIdVbo at attr 1.
    GLuint vertSelVao, edgeSelVao, faceSelVao;

    // Per-mode cache slot. Mode-keyed so flipping 1/2/3 doesn't
    // invalidate; mesh/camera changes invalidate all three.
    struct Slot {
        bool      valid;
        ulong     mutVer;
        float[16] view;
        float[16] proj;
        int       w, h;
    }
    Slot[3] slots;

public:
    void init() {
        vertProgram  = linkProgram(vertVertSrc,  commonFragSrc);
        edgeProgram  = linkProgram(edgeVertSrc,  commonFragSrc);
        faceProgram  = linkProgram(faceVertSrc,  commonFragSrc);
        depthProgram = linkProgram(depthVertSrc, zeroFragSrc);

        vertLocView  = glGetUniformLocation(vertProgram,  "u_view");
        vertLocProj  = glGetUniformLocation(vertProgram,  "u_proj");
        edgeLocView  = glGetUniformLocation(edgeProgram,  "u_view");
        edgeLocProj  = glGetUniformLocation(edgeProgram,  "u_proj");
        faceLocView  = glGetUniformLocation(faceProgram,  "u_view");
        faceLocProj  = glGetUniformLocation(faceProgram,  "u_proj");
        depthLocView = glGetUniformLocation(depthProgram, "u_view");
        depthLocProj = glGetUniformLocation(depthProgram, "u_proj");

        glGenFramebuffers(1, &fbo);
        glGenTextures(1, &colorTex);
        glGenRenderbuffers(1, &depthRbo);
        glGenVertexArrays(1, &vertSelVao);
        glGenVertexArrays(1, &edgeSelVao);
        glGenVertexArrays(1, &faceSelVao);
        fboW = 0; fboH = 0;
        foreach (ref s; slots) s.valid = false;
    }

    void destroy() {
        glDeleteFramebuffers(1, &fbo);
        glDeleteTextures(1, &colorTex);
        glDeleteRenderbuffers(1, &depthRbo);
        glDeleteVertexArrays(1, &vertSelVao);
        glDeleteVertexArrays(1, &edgeSelVao);
        glDeleteVertexArrays(1, &faceSelVao);
        glDeleteProgram(vertProgram);
        glDeleteProgram(edgeProgram);
        glDeleteProgram(faceProgram);
        glDeleteProgram(depthProgram);
    }

    /// Render `mode`'s ID buffer if the per-mode cache is stale, then
    /// read back a window of radius `r` around the cursor and return
    /// the nearest non-zero ID translated back to a cage element index.
    /// Returns -1 when the cursor is outside the viewport, the FBO has
    /// zero size, or nothing is within reach.
    int pick(SelectMode mode, int mx, int my, int r,
             ref const Mesh mesh, ref const GpuMesh gpu, ref const Viewport vp)
    {
        if (vp.width <= 0 || vp.height <= 0) return -1;
        ensureSize(vp.width, vp.height);

        Slot* slot = &slots[mode];
        if (!slot.valid
            || slot.mutVer != mesh.mutationVersion
            || slot.w != fboW || slot.h != fboH
            || !matricesEqual(slot.view, vp.view)
            || !matricesEqual(slot.proj, vp.proj))
        {
            renderMode(mode, gpu, vp);
            slot.valid  = true;
            slot.mutVer = mesh.mutationVersion;
            slot.view   = vp.view;
            slot.proj   = vp.proj;
            slot.w      = fboW;
            slot.h      = fboH;
        }

        int gpuId = readbackNearest(mx, my, r, vp);
        if (gpuId < 0) return -1;

        // VBO index → cage element index. Cage uploads → identity for
        // verts (vertOriginGpu[k] == k) and empty edge/face maps (we
        // pass-through). Subpatch uploads populate the maps.
        //
        // Final bounds check against the current `mesh` is the safety
        // net for stale-VBO picks: this code path can fire from a
        // mid-event-batch pickFaces (handleMouseMotion → doSelectPickAt)
        // after a tool already mutated `mesh` but BEFORE the once-per-
        // frame gpu.upload at app.d's main loop catches up. The cache
        // slot here is keyed by mesh.mutationVersion, so it dutifully
        // re-renders the FBO — but the source VBOs (faceIdVbo,
        // faceOriginGpu, edgeOriginGpu, vertOriginGpu) still describe
        // the previous topology, so the translated ID can exceed the
        // shrunken mesh. Out-of-range → -1.
        int cage;
        final switch (mode) {
            case SelectMode.Vertex:
                if (gpuId < gpu.vertOriginGpu.length) {
                    uint v = gpu.vertOriginGpu[gpuId];
                    if (v == uint.max) return -1;
                    cage = cast(int)v;
                } else {
                    cage = gpuId;
                }
                return (cage >= 0 && cage < cast(int)mesh.vertices.length)
                       ? cage : -1;
            case SelectMode.Edge:
                if (gpu.edgeOriginGpu.length > 0
                    && gpuId < gpu.edgeOriginGpu.length)
                {
                    uint c = gpu.edgeOriginGpu[gpuId];
                    if (c == uint.max) return -1;
                    cage = cast(int)c;
                } else {
                    cage = gpuId;
                }
                return (cage >= 0 && cage < cast(int)mesh.edges.length)
                       ? cage : -1;
            case SelectMode.Face:
                if (gpu.faceOriginGpu.length > 0
                    && gpuId < gpu.faceOriginGpu.length)
                {
                    uint c = gpu.faceOriginGpu[gpuId];
                    if (c == uint.max) return -1;
                    cage = cast(int)c;
                } else {
                    cage = gpuId;
                }
                return (cage >= 0 && cage < cast(int)mesh.faces.length)
                       ? cage : -1;
        }
    }

    /// Force all three cache slots to re-render on the next pick. The
    /// main loop doesn't need to call this — slots auto-invalidate on
    /// (mutVer, view, proj, size) changes — but the FBO resize path
    /// uses it internally.
    void invalidate() {
        foreach (ref s; slots) s.valid = false;
    }

private:
    void renderMode(SelectMode mode, ref const GpuMesh gpu, ref const Viewport vp)
    {
        // Save state we touch so the main renderer survives unchanged.
        // pickXxx is called mid-frame between shader.useProgram and
        // gpu.drawEdges — the latter assumes the program bound when
        // pick() was invoked is still active when it returns, so we
        // MUST restore glUseProgram here. Same for VAO bindings.
        GLint prevFbo;
        GLint[4] prevVp;
        GLint prevProgram;
        GLint prevVao;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
        glGetIntegerv(GL_VIEWPORT, prevVp.ptr);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prevVao);
        GLboolean prevDepthTest = glIsEnabled(GL_DEPTH_TEST);
        GLboolean prevPolyOff   = glIsEnabled(GL_POLYGON_OFFSET_FILL);

        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glViewport(0, 0, fboW, fboH);
        glEnable(GL_DEPTH_TEST);

        GLuint clearId = 0;
        glClearBufferuiv(GL_COLOR, 0, &clearId);
        glClear(GL_DEPTH_BUFFER_BIT);

        // Depth pre-pass for vertex / edge: writes 0 to colour + face
        // depth, so verts / edges behind a face fail the depth test
        // and stay 0. Face mode skips this — the face pass itself fills
        // the depth + colour buffers with one draw call.
        if (mode != SelectMode.Face && gpu.faceVertCount > 0) {
            glUseProgram(depthProgram);
            glUniformMatrix4fv(depthLocView, 1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(depthLocProj, 1, GL_FALSE, vp.proj.ptr);
            glEnable(GL_POLYGON_OFFSET_FILL);
            glPolygonOffset(1.0f, 1.0f);
            glBindVertexArray(gpu.faceVao);
            glDrawArrays(GL_TRIANGLES, 0, gpu.faceVertCount);
            glDisable(GL_POLYGON_OFFSET_FILL);
        }

        // Element pass writes IDs into the colour buffer wherever the
        // depth test passes against the pre-pass face surface.
        final switch (mode) {
            case SelectMode.Vertex:
                if (gpu.vertCount > 0) {
                    setupVertSelVao(gpu);
                    glUseProgram(vertProgram);
                    glUniformMatrix4fv(vertLocView, 1, GL_FALSE, vp.view.ptr);
                    glUniformMatrix4fv(vertLocProj, 1, GL_FALSE, vp.proj.ptr);
                    glDrawArrays(GL_POINTS, 0, gpu.vertCount);
                }
                break;
            case SelectMode.Edge:
                if (gpu.edgeVertCount > 0) {
                    setupEdgeSelVao(gpu);
                    glUseProgram(edgeProgram);
                    glUniformMatrix4fv(edgeLocView, 1, GL_FALSE, vp.view.ptr);
                    glUniformMatrix4fv(edgeLocProj, 1, GL_FALSE, vp.proj.ptr);
                    glDrawArrays(GL_LINES, 0, gpu.edgeVertCount);
                }
                break;
            case SelectMode.Face:
                if (gpu.faceVertCount > 0) {
                    setupFaceSelVao(gpu);
                    glUseProgram(faceProgram);
                    glUniformMatrix4fv(faceLocView, 1, GL_FALSE, vp.view.ptr);
                    glUniformMatrix4fv(faceLocProj, 1, GL_FALSE, vp.proj.ptr);
                    glDrawArrays(GL_TRIANGLES, 0, gpu.faceVertCount);
                }
                break;
        }

        glBindVertexArray(cast(GLuint)prevVao);
        glUseProgram(cast(GLuint)prevProgram);
        glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)prevFbo);
        glViewport(prevVp[0], prevVp[1], prevVp[2], prevVp[3]);
        if (!prevDepthTest) glDisable(GL_DEPTH_TEST);
        if (prevPolyOff)    glEnable(GL_POLYGON_OFFSET_FILL);
        else                glDisable(GL_POLYGON_OFFSET_FILL);
    }

    void setupVertSelVao(ref const GpuMesh gpu) {
        glBindVertexArray(vertSelVao);
        glBindBuffer(GL_ARRAY_BUFFER, gpu.vertVbo);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
    }

    void setupEdgeSelVao(ref const GpuMesh gpu) {
        glBindVertexArray(edgeSelVao);
        glBindBuffer(GL_ARRAY_BUFFER, gpu.edgeVbo);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
    }

    void setupFaceSelVao(ref const GpuMesh gpu) {
        glBindVertexArray(faceSelVao);
        // Position from interleaved faceVbo — stride 6, offset 0. The
        // normal at offset 3 is irrelevant for selection, so attr 1
        // points at the parallel faceIdVbo instead.
        glBindBuffer(GL_ARRAY_BUFFER, gpu.faceVbo);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              6 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, gpu.faceIdVbo);
        glVertexAttribIPointer(1, 1, GL_UNSIGNED_INT,
                               uint.sizeof, cast(void*)0);
        glEnableVertexAttribArray(1);
    }

    int readbackNearest(int mx, int my, int r, ref const Viewport vp) {
        int vx = mx - vp.x;
        int vyTop = my - vp.y;
        if (vx < 0 || vx >= fboW || vyTop < 0 || vyTop >= fboH) return -1;
        int fbY = fboH - 1 - vyTop;

        int x0 = vx  - r; if (x0 < 0)         x0 = 0;
        int y0 = fbY - r; if (y0 < 0)         y0 = 0;
        int x1 = vx  + r; if (x1 >= fboW)     x1 = fboW - 1;
        int y1 = fbY + r; if (y1 >= fboH)     y1 = fboH - 1;
        int rw = x1 - x0 + 1;
        int rh = y1 - y0 + 1;
        if (rw <= 0 || rh <= 0) return -1;

        uint[] buf = new uint[](rw * rh);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glReadPixels(x0, y0, rw, rh, GL_RED_INTEGER, GL_UNSIGNED_INT, buf.ptr);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        // The (2r+1)² readback window includes corner pixels with
        // manhattan distance up to 2r — without a cap, an element at
        // (r, r) gets picked from `2r` pixels away even though the
        // search radius is `r`. Cap the manhattan distance to `r`
        // (so the effective hit-region is a diamond, not the bounding
        // square) to match the screen-space tolerance the per-pick
        // call site asked for. r == 0 (face pick) still works — only
        // the exact pixel is considered.
        int  bestDist = r + 1;
        uint bestId   = 0;
        foreach (j; 0 .. rh) foreach (i; 0 .. rw) {
            uint id = buf[j * rw + i];
            if (id == 0) continue;
            int px = x0 + i;
            int py = y0 + j;
            int d  = abs(px - vx) + abs(py - fbY);
            if (d > r) continue;
            if (d < bestDist) { bestDist = d; bestId = id; }
        }
        if (bestId == 0) return -1;
        return cast(int)(bestId - 1);
    }

    void ensureSize(int w, int h) {
        if (w == fboW && h == fboH && fboW > 0) return;
        fboW = w; fboH = h;
        glBindTexture(GL_TEXTURE_2D, colorTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, w, h, 0, GL_RED_INTEGER,
                     GL_UNSIGNED_INT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glBindTexture(GL_TEXTURE_2D, 0);

        glBindRenderbuffer(GL_RENDERBUFFER, depthRbo);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
        glBindRenderbuffer(GL_RENDERBUFFER, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, colorTex, 0);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                  GL_RENDERBUFFER, depthRbo);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            import std.conv : to;
            throw new Exception(
                "GpuSelectBuffer: FBO incomplete (status=0x"
                ~ to!string(status, 16) ~ ")");
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        invalidate();
    }
}

private GLuint linkProgram(string vertSrc, string fragSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("gpu_select: link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(frag);
    return prog;
}

private bool matricesEqual(const ref float[16] a, const ref float[16] b) {
    foreach (i; 0 .. 16) if (a[i] != b[i]) return false;
    return true;
}

private int abs(int x) { return x < 0 ? -x : x; }
