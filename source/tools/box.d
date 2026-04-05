module tools.box;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : abs;

// ---------------------------------------------------------------------------
// BoxTool — click-drag to create a rectangular polygon on the most-facing plane
// ---------------------------------------------------------------------------

class BoxTool : Tool {
private:
    Mesh*    mesh;
    GpuMesh* gpu;

    GLuint previewVao, previewVbo;

    bool  dragging;
    Vec3  startPoint;
    Vec3  currentPoint;
    Vec3  planeNormal;
    Vec3  planeAxis1;
    Vec3  planeAxis2;
    Viewport cachedVp;

public:
    bool meshChanged;   // set to true when a face is committed; app.d reacts to this

    this(Mesh* mesh, GpuMesh* gpu) {
        this.mesh = mesh;
        this.gpu  = gpu;
    }

    override string name() const { return "Box"; }

    override void activate() {
        dragging     = false;
        meshChanged  = false;

        glGenVertexArrays(1, &previewVao);
        glGenBuffers(1, &previewVbo);
        glBindVertexArray(previewVao);
        glBindBuffer(GL_ARRAY_BUFFER, previewVbo);
        // 4 vertices × 3 floats — updated dynamically
        glBufferData(GL_ARRAY_BUFFER, 12 * float.sizeof, null, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    override void deactivate() {
        dragging = false;
        if (previewVao) { glDeleteVertexArrays(1, &previewVao); previewVao = 0; }
        if (previewVbo) { glDeleteBuffers(1, &previewVbo);      previewVbo = 0; }
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Don't interfere with camera navigation shortcuts.
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        choosePlane(cachedVp);

        Vec3 hit;
        if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                               Vec3(0, 0, 0), planeNormal, hit))
            return false;

        startPoint   = hit;
        currentPoint = hit;
        dragging     = true;
        uploadPreview();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!dragging) return false;

        Vec3 hit;
        if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                              Vec3(0, 0, 0), planeNormal, hit))
        {
            currentPoint = hit;
            uploadPreview();
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || !dragging) return false;
        dragging = false;

        Vec3[4] corners;
        computeCorners(corners);

        // Skip degenerate rectangles (zero width or height).
        Vec3 d = vec3Sub(currentPoint, startPoint);
        if (abs(dot(d, planeAxis1)) < 1e-5f || abs(dot(d, planeAxis2)) < 1e-5f)
            return true;

        // Ensure the face normal points toward the camera.
        // Face normal = cross(c1-c0, c3-c0). If it faces away, reverse winding.
        Vec3 faceNormal = cross(vec3Sub(corners[1], corners[0]),
                                vec3Sub(corners[3], corners[0]));
        bool facingCamera = dot(faceNormal, vec3Sub(cachedVp.eye, corners[0])) > 0;

        uint v0 = mesh.addVertex(corners[0]);
        uint v1 = mesh.addVertex(corners[1]);
        uint v2 = mesh.addVertex(corners[2]);
        uint v3 = mesh.addVertex(corners[3]);
        // Reverse: swap v1↔v3 to flip the normal without moving any vertex.
        if (facingCamera)
            mesh.addFace([v0, v1, v2, v3]);
        else
            mesh.addFace([v0, v3, v2, v1]);

        gpu.upload(*mesh);
        meshChanged = true;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (!dragging) return;

        // Draw yellow preview rectangle using the basic shader.
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(shader.locColor, 1.0f, 0.85f, 0.0f);

        glDisable(GL_DEPTH_TEST);
        glBindVertexArray(previewVao);
        glDrawArrays(GL_LINE_LOOP, 0, 4);
        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
    }

    override bool drawImGui() {
        bool on = true;  // button highlight handled in app.d
        return false;
    }

private:
    // Pick the world plane whose normal best aligns with the camera view direction.
    // Uses the same convention as MoveTool (view[2,6,10] = -forward components).
    void choosePlane(const ref Viewport vp) {
        float avx = abs(vp.view[2]);
        float avy = abs(vp.view[6]);
        float avz = abs(vp.view[10]);
        if (avx >= avy && avx >= avz) {
            planeNormal = Vec3(1, 0, 0);
            planeAxis1  = Vec3(0, 1, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else if (avy >= avx && avy >= avz) {
            planeNormal = Vec3(0, 1, 0);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else {
            planeNormal = Vec3(0, 0, 1);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 1, 0);
        }
    }

    // Build the 4 rectangle corners from startPoint, currentPoint, and plane axes.
    void computeCorners(out Vec3[4] corners) {
        Vec3 d  = vec3Sub(currentPoint, startPoint);
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        corners[0] = startPoint;
        corners[1] = vec3Add(startPoint, vec3Scale(planeAxis1, d1));
        corners[2] = vec3Add(corners[1],  vec3Scale(planeAxis2, d2));
        corners[3] = vec3Add(startPoint,  vec3Scale(planeAxis2, d2));
    }

    void uploadPreview() {
        Vec3[4] corners;
        computeCorners(corners);
        float[12] verts = [
            corners[0].x, corners[0].y, corners[0].z,
            corners[1].x, corners[1].y, corners[1].z,
            corners[2].x, corners[2].y, corners[2].z,
            corners[3].x, corners[3].y, corners[3].z,
        ];
        glBindBuffer(GL_ARRAY_BUFFER, previewVbo);
        glBufferSubData(GL_ARRAY_BUFFER, 0, verts.sizeof, verts.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }
}
