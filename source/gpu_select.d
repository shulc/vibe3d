module gpu_select;

import bindbc.opengl;
import std.string : toStringz;

import math   : Viewport;
import mesh   : GpuMesh, Mesh;
import shader : compileShader;

// ---------------------------------------------------------------------------
// GpuEdgeSelect — offscreen ID-buffer edge picker, MODO-style / Blender-style.
//
// Why: heuristic visibility tests on edge ENDPOINTS (or even the midpoint)
// reject edges the user can clearly see and pick edges they can't.
// Examples that broke "both endpoints visible":
//   - Two boxes overlapping. An edge of box A with one corner buried inside
//     box B has one endpoint occluded → the WHOLE edge becomes unpickable
//     even though most of it is on-screen.
//   - Midpoint heuristics fail the symmetric case: a long edge with the
//     middle behind a wall but both endpoints poking out.
//
// What this does: render every cage edge into an offscreen R32UI texture
// with its index encoded as the colour value (id = edgeIndex + 1; 0 means
// "no edge here"). A depth pre-pass over faces gives GPU-correct occlusion
// — exactly the pixels the user sees on screen end up in the buffer. To
// pick, read back a small window around the cursor and choose the nearest
// non-zero ID by manhattan distance.
//
// Subpatch preview mode: gpu.edgeVbo holds PREVIEW segments, not cage
// edges. gl_VertexID/2 inside the shader yields the preview segment
// index; CPU translates back to a cage edge via gpu.edgeOriginGpu after
// readback.
//
// Cache key: mesh mutation version + view matrix + projection matrix +
// FBO dimensions. Re-render only when one of those changes — mouse-only
// motion reuses the previous frame's buffer.
// ---------------------------------------------------------------------------

private immutable string idVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    flat out uint vID;
    void main() {
        // gl_VertexID is the per-draw vertex index. Each line segment is
        // two consecutive verts, so gl_VertexID / 2 is the segment index.
        // 0 is reserved for "no edge"; segments start at 1.
        vID         = uint(gl_VertexID / 2) + 1u;
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

private immutable string idFragSrc = q{
    #version 330 core
    flat in uint vID;
    out uint fragID;
    void main() {
        fragID = vID;
    }
};

private immutable string faceVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
    }
};

private immutable string faceFragSrc = q{
    #version 330 core
    out uint fragID;
    void main() {
        // Faces fill the depth buffer for edge occlusion but mark the
        // pixel as "no edge" so picking inside a face surface returns
        // nothing.
        fragID = 0u;
    }
};

class GpuEdgeSelect {
private:
    GLuint fbo;
    GLuint colorTex;
    GLuint depthRbo;
    int    fboW, fboH;

    GLuint idProgram;
    GLint  idLocView, idLocProj;
    GLuint faceProgram;
    GLint  faceLocView, faceLocProj;

    bool      cacheValid;
    ulong     cacheMutVer;
    float[16] cacheView;
    float[16] cacheProj;
    int       cacheW, cacheH;

public:
    void init() {
        idProgram   = linkProgram(idVertSrc,   idFragSrc);
        faceProgram = linkProgram(faceVertSrc, faceFragSrc);
        idLocView   = glGetUniformLocation(idProgram,   "u_view");
        idLocProj   = glGetUniformLocation(idProgram,   "u_proj");
        faceLocView = glGetUniformLocation(faceProgram, "u_view");
        faceLocProj = glGetUniformLocation(faceProgram, "u_proj");

        glGenFramebuffers(1, &fbo);
        glGenTextures(1, &colorTex);
        glGenRenderbuffers(1, &depthRbo);
        fboW = 0; fboH = 0;
        cacheValid = false;
    }

    void destroy() {
        glDeleteFramebuffers(1, &fbo);
        glDeleteTextures(1, &colorTex);
        glDeleteRenderbuffers(1, &depthRbo);
        glDeleteProgram(idProgram);
        glDeleteProgram(faceProgram);
    }

    /// Render every edge of `gpu` into the offscreen ID buffer, using the
    /// same view/proj as the on-screen render so screen-space hit-testing
    /// lines up with the user's view. Re-renders only on a cache miss
    /// against (mutationVersion, view, proj, viewport size). `mesh` is
    /// passed for its mutationVersion; geometry comes from `gpu`.
    void update(ref const Mesh mesh, ref const GpuMesh gpu, ref const Viewport vp) {
        ensureSize(vp.width, vp.height);
        if (cacheValid
            && cacheMutVer == mesh.mutationVersion
            && cacheW == fboW && cacheH == fboH
            && matricesEqual(cacheView, vp.view)
            && matricesEqual(cacheProj, vp.proj))
            return;

        // Save current GL state we touch so the main renderer keeps
        // working unchanged after this call.
        GLint prevFbo;
        GLint[4] prevVp;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
        glGetIntegerv(GL_VIEWPORT, prevVp.ptr);
        GLboolean prevDepthTest = glIsEnabled(GL_DEPTH_TEST);
        GLboolean prevPolyOff   = glIsEnabled(GL_POLYGON_OFFSET_FILL);

        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glViewport(0, 0, fboW, fboH);

        // Clear: 0 = "no edge" in colour; far plane in depth.
        GLuint clearId = 0;
        glClearBufferuiv(GL_COLOR, 0, &clearId);
        glClear(GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);

        // Face depth pre-pass: writes face IDs of 0 + depth, so edges
        // behind a face fail the depth test and stay 0 in the colour
        // buffer. Polygon offset pushes faces a hair into Z so edges
        // sitting exactly on the surface (every cage edge does) survive
        // GL_LESS — matches the on-screen offset used by drawFaces.
        if (gpu.faceVertCount > 0) {
            glUseProgram(faceProgram);
            glUniformMatrix4fv(faceLocView, 1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(faceLocProj, 1, GL_FALSE, vp.proj.ptr);
            glEnable(GL_POLYGON_OFFSET_FILL);
            glPolygonOffset(1.0f, 1.0f);
            glBindVertexArray(gpu.faceVao);
            glDrawArrays(GL_TRIANGLES, 0, gpu.faceVertCount);
            glDisable(GL_POLYGON_OFFSET_FILL);
        }

        // Edge ID pass.
        if (gpu.edgeVertCount > 0) {
            glUseProgram(idProgram);
            glUniformMatrix4fv(idLocView, 1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(idLocProj, 1, GL_FALSE, vp.proj.ptr);
            glBindVertexArray(gpu.edgeVao);
            glDrawArrays(GL_LINES, 0, gpu.edgeVertCount);
        }

        glBindVertexArray(0);
        glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)prevFbo);
        glViewport(prevVp[0], prevVp[1], prevVp[2], prevVp[3]);
        if (!prevDepthTest) glDisable(GL_DEPTH_TEST);
        if (prevPolyOff)    glEnable(GL_POLYGON_OFFSET_FILL);
        else                glDisable(GL_POLYGON_OFFSET_FILL);

        cacheMutVer = mesh.mutationVersion;
        cacheView   = vp.view;
        cacheProj   = vp.proj;
        cacheW      = fboW;
        cacheH      = fboH;
        cacheValid  = true;
    }

    /// Read back a (2*r+1)×(2*r+1) window of the cached ID buffer around
    /// the cursor and return the nearest non-zero ID (= rendered edge),
    /// translated by -1 to drop the "0 = no edge" reservation. Returns
    /// -1 if the cursor sits outside the viewport, the buffer has nothing
    /// near it, or update() has never run.
    ///
    /// `mx`, `my` are window-space cursor coords (Y top-down, SDL
    /// convention); `vp.x`, `vp.y` give the viewport's top-left corner
    /// in the same convention so we can clip to the FBO. OpenGL's
    /// framebuffer Y is bottom-up, so the readback Y is flipped.
    int pick(int mx, int my, int r, ref const Viewport vp) {
        if (!cacheValid) return -1;
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

        // Find the nearest non-zero pixel to the cursor in manhattan
        // distance. Manhattan matches Blender's edge-picking metric and
        // keeps the diagonal-vs-axis bias consistent with the way the
        // user perceives "closest edge" on screen.
        int  bestDist = int.max;
        uint bestId   = 0;
        foreach (j; 0 .. rh) foreach (i; 0 .. rw) {
            uint id = buf[j * rw + i];
            if (id == 0) continue;
            int px = x0 + i;
            int py = y0 + j;
            int d  = abs(px - vx) + abs(py - fbY);
            if (d < bestDist) { bestDist = d; bestId = id; }
        }
        if (bestId == 0) return -1;
        return cast(int)(bestId - 1);
    }

    void invalidate() { cacheValid = false; }

private:
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
        // Sanity-check completeness so silent bugs (missing format /
        // unsupported attachment) become loud at startup.
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            import std.conv : to;
            throw new Exception(
                "GpuEdgeSelect: FBO incomplete (status=0x"
                ~ to!string(status, 16) ~ ")");
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        cacheValid = false;
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
