module tools.box;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import shader : Shader, LitShader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : abs, sqrt;

// ---------------------------------------------------------------------------
// BoxTool — two-drag 3-D cuboid creation
//
//   Drag 1  (LMB down → move → up)  : draw base rectangle on most-facing plane
//   Drag 2  (LMB down → move → up)  : extrude height along plane normal → cuboid
//   RMB / deactivate                 : cancel current operation
// ---------------------------------------------------------------------------

private enum BoxState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class BoxTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    LitShader litShader;

    Mesh    previewMesh;
    GpuMesh previewGpu;

    BoxState state;

    // Base rectangle (axis-aligned on the most-facing plane)
    Vec3    startPoint;
    Vec3    currentPoint;
    Vec3[4] baseCorners;

    // Height extrusion
    float height;
    Vec3  hpn;
    Vec3  hpOrigin;       // base centroid, origin of height plane
    Vec3  heightDragStart; // world hit at second LMB press

    // Plane chosen at first click
    Vec3  planeNormal;
    Vec3  planeAxis1;
    Vec3  planeAxis2;

    Viewport cachedVp;

public:
    bool meshChanged;

    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
    }

    override string name() const { return "Box"; }

    override void activate() {
        state       = BoxState.Idle;
        meshChanged = false;
        previewGpu.init();
    }

    override void deactivate() {
        if (state == BoxState.BaseSet)
            commitBase();
        else if ((state == BoxState.DrawingHeight || state == BoxState.HeightSet) && abs(height) > 1e-5f)
            commitCuboid();
        state = BoxState.Idle;
        previewGpu.destroy();
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != BoxState.Idle) {
            state = BoxState.Idle;
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        if (state == BoxState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0,0,0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            state        = BoxState.DrawingBase;
            uploadBase();
            return true;
        }

        if (state == BoxState.BaseSet) {
            height = 0.0f;
            setupHeightPlane();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = BoxState.DrawingHeight;
            uploadCuboid();
            return true;
        }

        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (state == BoxState.DrawingBase) {
            computeBaseCorners();
            Vec3 d = vec3Sub(currentPoint, startPoint);
            if (abs(dot(d, planeAxis1)) < 1e-5f || abs(dot(d, planeAxis2)) < 1e-5f) {
                state = BoxState.Idle;
                return true;
            }
            state = BoxState.BaseSet;
            uploadBase();
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            state = BoxState.HeightSet;
            return true;
        }

        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (state == BoxState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0,0,0), planeNormal, hit))
            {
                currentPoint = hit;
                uploadBase();
            }
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                height = dot(vec3Sub(hit, heightDragStart), planeNormal);
                uploadCuboid();
            }
            return true;
        }

        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == BoxState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        // --- Solid faces ---
        glUseProgram(litShader.program);
        glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
        glUniform1f(litShader.locAmbient,  0.20f);
        glUniform1f(litShader.locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,  32.0f);

        previewGpu.drawFaces(litShader);

        // --- Wireframe edges ---
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        previewGpu.drawEdges(shader.locColor, -1, []);
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        if (state == BoxState.Idle) {
            ImGui.TextDisabled("No active shape");
            return;
        }
        computeBaseCorners();
        Vec3  cen = baseCentroid();
        float d1  = dot(vec3Sub(currentPoint, startPoint), planeAxis1);
        float d2  = dot(vec3Sub(currentPoint, startPoint), planeAxis2);

        // World-space size: axis1/axis2 cover the base; planeNormal covers height.
        Vec3 sizeVec = vec3Add(vec3Scale(planeAxis1, abs(d1)),
                               vec3Scale(planeAxis2, abs(d2)));
        if (state == BoxState.DrawingHeight || state == BoxState.HeightSet)
            sizeVec = vec3Add(sizeVec, vec3Scale(planeNormal, abs(height)));

        // ---- Center ----
        float cx = cen.x, cy = cen.y, cz = cen.z;
        ImGui.Text("Center");
        bool cChanged = false;
        cChanged |= ImGui.DragFloat("X##cenX", &cx, 0.01f, 0, 0, "%.3f");
        cChanged |= ImGui.DragFloat("Y##cenY", &cy, 0.01f, 0, 0, "%.3f");
        cChanged |= ImGui.DragFloat("Z##cenZ", &cz, 0.01f, 0, 0, "%.3f");
        if (cChanged) {
            Vec3 delta  = Vec3(cx - cen.x, cy - cen.y, cz - cen.z);
            startPoint   = vec3Add(startPoint,   delta);
            currentPoint = vec3Add(currentPoint, delta);
            if (state == BoxState.DrawingHeight || state == BoxState.HeightSet) uploadCuboid();
            else                                                                uploadBase();
        }

        // ---- Size ----
        float sx = sizeVec.x, sy = sizeVec.y, sz = sizeVec.z;
        ImGui.Text("Size");
        bool sxC = ImGui.DragFloat("X##szX", &sx, 0.01f, 0.001f, float.max, "%.3f");
        bool syC = ImGui.DragFloat("Y##szY", &sy, 0.01f, 0.001f, float.max, "%.3f");
        bool szC = ImGui.DragFloat("Z##szZ", &sz, 0.01f, 0.001f, float.max, "%.3f");
        if (sxC || syC || szC) {
            float sign1 = d1 < 0 ? -1.0f : 1.0f;
            float sign2 = d2 < 0 ? -1.0f : 1.0f;
            float signH = height < 0 ? -1.0f : 1.0f;
            if (sxC) {
                if      (abs(planeAxis1.x)  > 0.5f) d1     = sx * sign1;
                else if (abs(planeAxis2.x)  > 0.5f) d2     = sx * sign2;
                else if (abs(planeNormal.x) > 0.5f) height = sx * signH;
            }
            if (syC) {
                if      (abs(planeAxis1.y)  > 0.5f) d1     = sy * sign1;
                else if (abs(planeAxis2.y)  > 0.5f) d2     = sy * sign2;
                else if (abs(planeNormal.y) > 0.5f) height = sy * signH;
            }
            if (szC) {
                if      (abs(planeAxis1.z)  > 0.5f) d1     = sz * sign1;
                else if (abs(planeAxis2.z)  > 0.5f) d2     = sz * sign2;
                else if (abs(planeNormal.z) > 0.5f) height = sz * signH;
            }
            // Reconstruct startPoint/currentPoint from center + new d1/d2.
            startPoint   = vec3Sub(vec3Sub(cen, vec3Scale(planeAxis1, d1 * 0.5f)),
                                               vec3Scale(planeAxis2, d2 * 0.5f));
            currentPoint = vec3Add(vec3Add(cen, vec3Scale(planeAxis1, d1 * 0.5f)),
                                               vec3Scale(planeAxis2, d2 * 0.5f));
            if (state == BoxState.DrawingHeight || state == BoxState.HeightSet) uploadCuboid();
            else                                                                uploadBase();
        }
    }

private:
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

    void computeBaseCorners() {
        Vec3  d  = vec3Sub(currentPoint, startPoint);
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        baseCorners[0] = startPoint;
        baseCorners[1] = vec3Add(startPoint, vec3Scale(planeAxis1, d1));
        baseCorners[2] = vec3Add(baseCorners[1], vec3Scale(planeAxis2, d2));
        baseCorners[3] = vec3Add(startPoint,     vec3Scale(planeAxis2, d2));
    }

    void uploadBase() {
        computeBaseCorners();
        previewMesh.clear();
        foreach (c; baseCorners) previewMesh.addVertex(c);
        Vec3 n     = cross(vec3Sub(baseCorners[1], baseCorners[0]),
                           vec3Sub(baseCorners[2], baseCorners[0]));
        Vec3 toEye = vec3Sub(cachedVp.eye, baseCentroid());
        if (dot(n, toEye) >= 0)
            previewMesh.addFace([0u, 1u, 2u, 3u]);
        else
            previewMesh.addFace([0u, 3u, 2u, 1u]);
        previewGpu.upload(previewMesh);
    }

    Vec3 baseCentroid() const {
        return Vec3(
            (baseCorners[0].x + baseCorners[1].x + baseCorners[2].x + baseCorners[3].x) * 0.25f,
            (baseCorners[0].y + baseCorners[1].y + baseCorners[2].y + baseCorners[3].y) * 0.25f,
            (baseCorners[0].z + baseCorners[1].z + baseCorners[2].z + baseCorners[3].z) * 0.25f,
        );
    }

    void setupHeightPlane() {
        hpOrigin = baseCentroid();
        Vec3 toCamera = vec3Sub(cachedVp.eye, hpOrigin);
        Vec3 inPlane  = vec3Sub(toCamera, vec3Scale(planeNormal, dot(toCamera, planeNormal)));
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f
            ? Vec3(inPlane.x/len, inPlane.y/len, inPlane.z/len)
            : planeAxis1;
    }

    void uploadCuboid() {
        Vec3 H = vec3Scale(planeNormal, height);
        Vec3[8] pts = [
            baseCorners[0], baseCorners[1], baseCorners[2], baseCorners[3],
            vec3Add(baseCorners[0], H), vec3Add(baseCorners[1], H),
            vec3Add(baseCorners[2], H), vec3Add(baseCorners[3], H),
        ];
        Vec3 cen = Vec3(0,0,0);
        foreach (p; pts) cen = vec3Add(cen, vec3Scale(p, 0.125f));

        static immutable int[24] faceIdx = [
            0,1,2,3,   // bottom
            4,7,6,5,   // top
            0,4,5,1,   // side 0-1
            1,5,6,2,   // side 1-2
            2,6,7,3,   // side 2-3
            3,7,4,0,   // side 3-0
        ];

        previewMesh.clear();
        uint[8] vi;
        foreach (i; 0..8) vi[i] = previewMesh.addVertex(pts[i]);

        for (int fi = 0; fi < 6; fi++) {
            int b  = fi * 4;
            int i0 = faceIdx[b], i1 = faceIdx[b+1],
                i2 = faceIdx[b+2], i3 = faceIdx[b+3];
            Vec3 n  = cross(vec3Sub(pts[i1], pts[i0]), vec3Sub(pts[i2], pts[i0]));
            Vec3 fc = vec3Scale(
                vec3Add(vec3Add(pts[i0], pts[i1]), vec3Add(pts[i2], pts[i3])),
                0.25f);
            if (dot(n, vec3Sub(fc, cen)) > 0)
                previewMesh.addFace([vi[i0], vi[i1], vi[i2], vi[i3]]);
            else
                previewMesh.addFace([vi[i0], vi[i3], vi[i2], vi[i1]]);
        }
        previewGpu.upload(previewMesh);
    }

    void commitBase() {
        computeBaseCorners();
        uint[4] vi;
        foreach (i; 0 .. 4) vi[i] = mesh.addVertex(baseCorners[i]);
        Vec3 n     = cross(vec3Sub(baseCorners[1], baseCorners[0]),
                           vec3Sub(baseCorners[2], baseCorners[0]));
        Vec3 toEye = vec3Sub(cachedVp.eye, baseCentroid());
        if (dot(n, toEye) >= 0)
            mesh.addFace([vi[0], vi[1], vi[2], vi[3]]);
        else
            mesh.addFace([vi[0], vi[3], vi[2], vi[1]]);
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCuboid() {
        Vec3 H = vec3Scale(planeNormal, height);
        Vec3[8] pts = [
            baseCorners[0], baseCorners[1], baseCorners[2], baseCorners[3],
            vec3Add(baseCorners[0], H), vec3Add(baseCorners[1], H),
            vec3Add(baseCorners[2], H), vec3Add(baseCorners[3], H),
        ];
        Vec3 cen = Vec3(0,0,0);
        foreach (p; pts) cen = vec3Add(cen, vec3Scale(p, 0.125f));

        static immutable int[24] faceIdx = [
            0,1,2,3,   // bottom
            4,7,6,5,   // top
            0,4,5,1,   // side 0-1
            1,5,6,2,   // side 1-2
            2,6,7,3,   // side 2-3
            3,7,4,0,   // side 3-0
        ];

        uint[8] vi;
        foreach (i; 0..8) vi[i] = mesh.addVertex(pts[i]);

        for (int fi = 0; fi < 6; fi++) {
            int b  = fi * 4;
            int i0 = faceIdx[b], i1 = faceIdx[b+1],
                i2 = faceIdx[b+2], i3 = faceIdx[b+3];
            Vec3 n  = cross(vec3Sub(pts[i1], pts[i0]), vec3Sub(pts[i2], pts[i0]));
            Vec3 fc = vec3Scale(
                vec3Add(vec3Add(pts[i0], pts[i1]), vec3Add(pts[i2], pts[i3])),
                0.25f);
            if (dot(n, vec3Sub(fc, cen)) > 0)
                mesh.addFace([vi[i0], vi[i1], vi[i2], vi[i3]]);
            else
                mesh.addFace([vi[i0], vi[i3], vi[i2], vi[i1]]);
        }

        gpu.upload(*mesh);
        meshChanged = true;
    }
}
