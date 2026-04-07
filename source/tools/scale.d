module tools.scale;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import handler;
import mesh;
import editmode;
import math;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt;


// ---------------------------------------------------------------------------
// ScaleTool : Tool — shows ScaleHandler at selection/mesh center; scales
//             selected vertices along the dragged axis relative to the center.
// ---------------------------------------------------------------------------

class ScaleTool : Tool {
    ScaleHandler handler;
    bool         active;

    // app.d reads this every frame and sets u_model accordingly.
    // Reset to identity when not in a whole-mesh drag.
    float[16] gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    int      dragAxis = -1;
    int      lastMX, lastMY;
    Viewport cachedVp;
    Vec3     scaleAccum     = Vec3(1, 1, 1);  // cumulative scale factor per axis since tool activated
    Vec3     dragScaleAccum = Vec3(1, 1, 1);  // scale within current drag (for yellow arrows)
    Vec3     propScale      = Vec3(1, 1, 1);  // persistent value shown in Tool Properties
    Vec3[]   activationVertices;              // mesh snapshot at tool activation (for props apply)
    Vec3     activationCenter;               // gizmo center at activation
    bool     centerManual;                   // true = update() must not recompute handler.center

    // Vertex index cache — rebuilt once per selection change, reused every event.
    int[]  vertexIndicesToProcess;
    bool[] toProcess;
    int    vertexProcessCount;
    bool   vertexCacheDirty = true;
    int    lastSelectionHash;

    // Deferred GPU upload for partial-selection drags (flushed in draw() once per frame).
    bool   needsGpuUpdate;

    // Whole-mesh GPU bypass: snapshot at drag start; commit on mouseUp.
    Vec3[] dragStartVertices;
    Vec3   dragStartScaleAccum;  // scaleAccum at the start of the current drag
    bool   wholeMeshDrag;
    bool   propsDragging;   // true when DragFloat props drag bypasses GPU uploads

    // Cached gizmo center (recomputed only when selection hash changes).
    Vec3   cachedCenter;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;
        handler = new ScaleHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Scale"; }

    override void activate() {
        active = true;
        scaleAccum = Vec3(1, 1, 1);
        propScale  = Vec3(1, 1, 1);
        centerManual = false;
        activationVertices = mesh.vertices.dup;
        activationCenter   = handler.center;
        vertexCacheDirty = true;
        lastSelectionHash = uint.max;
        needsGpuUpdate = false;
        wholeMeshDrag = false;
        propsDragging = false;
        gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    }

    override void deactivate() {
        active = false;
        if (wholeMeshDrag || propsDragging) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
            propsDragging = false;
        } else if (needsGpuUpdate) {
            gpu.upload(*mesh);
            needsGpuUpdate = false;
        }
        dragAxis = -1;
        centerManual = false;
    }

    override void update() {
        if (!active) return;

        // Selection cannot change during drag — skip hash check entirely.
        if (dragAxis >= 0) return;

        uint currentHash = computeSelectionHash();
        if (currentHash == lastSelectionHash) return;
        lastSelectionHash = currentHash;
        vertexCacheDirty = true;

        Vec3 sum  = Vec3(0, 0, 0);
        int  count = 0;
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; mesh.selectedVertices) if (s) { anySelected = true; break; }
            foreach (i, v; mesh.vertices) {
                if (!anySelected || (i < mesh.selectedVertices.length && mesh.selectedVertices[i])) {
                    sum = vec3Add(sum, v); count++;
                }
            }
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; mesh.selectedEdges) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, edge; mesh.edges) {
                if (anySelected && !(i < mesh.selectedEdges.length && mesh.selectedEdges[i])) continue;
                foreach (vi; edge) {
                    if (!visited[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; visited[vi] = true; }
                }
            }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; mesh.selectedFaces) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, face; mesh.faces) {
                if (anySelected && !(i < mesh.selectedFaces.length && mesh.selectedFaces[i])) continue;
                foreach (vi; face) {
                    if (!visited[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; visited[vi] = true; }
                }
            }
        }
        cachedCenter = count > 0
            ? Vec3(sum.x / count, sum.y / count, sum.z / count)
            : Vec3(0, 0, 0);

        if (!centerManual && dragAxis == -1)
            handler.setPosition(cachedCenter);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Flush pending partial-selection GPU upload once per frame.
        if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        bool anyHovered = false;
        foreach (i, arrow; arrows) {
            arrow.setForceHovered(false);
            arrow.setHoverBlocked(dragAxis >= 0 || anyHovered);
            anyHovered |= arrow.isHovered();
        }
        handler.centerDisk.setForceHovered(false);
        handler.centerDisk.setHoverBlocked(dragAxis >= 0 || anyHovered);
        handler.circleXY.setHoverBlocked(dragAxis >= 0 || anyHovered);
        handler.circleYZ.setHoverBlocked(dragAxis >= 0 || anyHovered);
        handler.circleXZ.setHoverBlocked(dragAxis >= 0 || anyHovered);

        handler.setScaleAccum(dragScaleAccum);
        handler.activeDragAxis = dragAxis;
        handler.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        if (SDL_GetModState() & (KMOD_ALT | KMOD_SHIFT)) return false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            lastMX = e.x; lastMY = e.y;
            dragScaleAccum = Vec3(1, 1, 1);

            buildVertexCacheIfNeeded();
            wholeMeshDrag = (vertexProcessCount == cast(int)mesh.vertices.length);
            if (wholeMeshDrag) {
                dragStartVertices  = mesh.vertices.dup;
                dragStartScaleAccum = scaleAccum;
            }
            return true;
        }

        // Click outside gizmo: teleport to most-facing plane at click point.
        const ref float[16] v = cachedVp.view;
        import std.math : abs;
        float avx = abs(v[2]), avy = abs(v[6]), avz = abs(v[10]);
        Vec3 n = avx >= avy && avx >= avz ? Vec3(1,0,0)
               : avy >= avx && avy >= avz ? Vec3(0,1,0)
                                          : Vec3(0,0,1);
        Vec3 camOrigin = Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
        Vec3 hit;
        if (!rayPlaneIntersect(camOrigin, screenRay(e.x, e.y, cachedVp),
                               handler.center, n, hit))
            return false;
        handler.setPosition(hit);
        centerManual = true;
        activationVertices = mesh.vertices.dup;
        activationCenter   = hit;
        return false;  // don't start a drag
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;

        if (wholeMeshDrag) {
            // Apply final scale from drag-start snapshot and upload once.
            commitWholeMeshScale();
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
        } else if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        dragAxis = -1;
        propScale = scaleAccum;
        activationVertices = mesh.vertices.dup;
        activationCenter   = handler.center;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        Vec3 center = handler.center;

        if (dragAxis == 3) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            float dx = cast(float)(e.x - lastMX);
            float scaleFactor = 1.0f + dx / gizmoScreenPx;
            float minAccum = scaleAccum.x < scaleAccum.y ? scaleAccum.x : scaleAccum.y;
            if (scaleAccum.z < minAccum) minAccum = scaleAccum.z;
            if (minAccum * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.x *= scaleFactor; scaleAccum.y *= scaleFactor; scaleAccum.z *= scaleFactor;
            dragScaleAccum.x *= scaleFactor; dragScaleAccum.y *= scaleFactor; dragScaleAccum.z *= scaleFactor;
            if (wholeMeshDrag) {
                float lx = scaleAccum.x / dragStartScaleAccum.x;
                gpuMatrix = pivotScaleMatrix(center, lx, lx, lx);
            } else {
                applyScaleAxesFactor(true, true, true, scaleFactor);
            }
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        if (dragAxis >= 4) {
            float gizmoScreenPx = gizmoScreenWidth(center);
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            float dx = cast(float)(e.x - lastMX);
            float scaleFactor = 1.0f + dx / gizmoScreenPx;
            bool scaleX = (dragAxis == 4 || dragAxis == 6);
            bool scaleY = (dragAxis == 4 || dragAxis == 5);
            bool scaleZ = (dragAxis == 5 || dragAxis == 6);
            if (scaleX) { if (scaleAccum.x * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleY) { if (scaleAccum.y * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleZ) { if (scaleAccum.z * scaleFactor < 0.0f) scaleFactor = 0.0f; }
            if (scaleX) { scaleAccum.x *= scaleFactor; dragScaleAccum.x *= scaleFactor; }
            if (scaleY) { scaleAccum.y *= scaleFactor; dragScaleAccum.y *= scaleFactor; }
            if (scaleZ) { scaleAccum.z *= scaleFactor; dragScaleAccum.z *= scaleFactor; }
            if (wholeMeshDrag) {
                float lx = scaleX ? scaleAccum.x / dragStartScaleAccum.x : 1.0f;
                float ly = scaleY ? scaleAccum.y / dragStartScaleAccum.y : 1.0f;
                float lz = scaleZ ? scaleAccum.z / dragStartScaleAccum.z : 1.0f;
                gpuMatrix = pivotScaleMatrix(center, lx, ly, lz);
            } else {
                applyScaleAxesFactor(scaleX, scaleY, scaleZ, scaleFactor);
            }
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        Vec3 axis = dragAxis == 0 ? Vec3(1,0,0)
                  : dragAxis == 1 ? Vec3(0,1,0)
                                  : Vec3(0,0,1);

        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(vec3Add(center, axis), cachedVp, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx = ax_ - cx, sdy = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        float delta       = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
        float scaleFactor = 1.0f + delta;
        bool  axX = (dragAxis == 0), axY = (dragAxis == 1), axZ = (dragAxis == 2);
        if (axX) { if (scaleAccum.x * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.x *= scaleFactor; dragScaleAccum.x *= scaleFactor; }
        if (axY) { if (scaleAccum.y * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.y *= scaleFactor; dragScaleAccum.y *= scaleFactor; }
        if (axZ) { if (scaleAccum.z * scaleFactor < 0.0f) scaleFactor = 0.0f; scaleAccum.z *= scaleFactor; dragScaleAccum.z *= scaleFactor; }
        if (wholeMeshDrag) {
            float lx = axX ? scaleAccum.x / dragStartScaleAccum.x : 1.0f;
            float ly = axY ? scaleAccum.y / dragStartScaleAccum.y : 1.0f;
            float lz = axZ ? scaleAccum.z / dragStartScaleAccum.z : 1.0f;
            gpuMatrix = pivotScaleMatrix(center, lx, ly, lz);
        } else {
            applyScaleAxesFactor(axX, axY, axZ, scaleFactor);
        }

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Scale            R");
        if (active)
            ImGui.PopStyleColor();
        return clicked;
    }

    override void drawProperties() {
        if (dragAxis >= 0) propScale = scaleAccum;
        ImGui.DragFloat("X", &propScale.x, 0.01f, 0.0f, float.max, "%.4f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propScale.y, 0.01f, 0.0f, float.max, "%.4f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propScale.z, 0.01f, 0.0f, float.max, "%.4f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        bool anyActive = xActive || yActive || zActive;
        bool anyDone   = xDone   || yDone   || zDone;
        if (!(anyActive || anyDone)) return;

        // Clamp and update scaleAccum from propScale.
        if (xActive || xDone) { if (propScale.x < 0) propScale.x = 0; scaleAccum.x = propScale.x; }
        if (yActive || yDone) { if (propScale.y < 0) propScale.y = 0; scaleAccum.y = propScale.y; }
        if (zActive || zDone) { if (propScale.z < 0) propScale.z = 0; scaleAccum.z = propScale.z; }

        buildVertexCacheIfNeeded();
        bool wholeMesh = (vertexProcessCount == cast(int)mesh.vertices.length);

        // Update CPU vertices from activationVertices (fast, no GPU).
        applyScaleFromActivationCpuOnly();

        if (anyActive) {
            if (wholeMesh) {
                // Whole-mesh: GPU bypass — upload base once at drag start, then only update matrix.
                if (!propsDragging) {
                    uploadPropsBase(activationVertices);
                    propsDragging = true;
                }
                gpuMatrix = pivotScaleMatrix(activationCenter, scaleAccum.x, scaleAccum.y, scaleAccum.z);
            } else {
                // Partial selection: deferred GPU upload in draw().
                needsGpuUpdate = true;
            }
        } else {
            // Drag ended: commit final CPU state to GPU.
            if (propsDragging) {
                gpu.upload(*mesh);
                gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
                propsDragging = false;
            } else {
                needsGpuUpdate = true;
            }
        }
    }

private:
    uint computeSelectionHash() {
        uint hash = cast(uint)(*editMode);
        if (*editMode == EditMode.Vertices) {
            foreach (i, s; mesh.selectedVertices) if (s) hash = hash * 31 + cast(uint)i;
        } else if (*editMode == EditMode.Edges) {
            foreach (i, s; mesh.selectedEdges) if (s) hash = hash * 31 + cast(uint)i;
        } else if (*editMode == EditMode.Polygons) {
            foreach (i, s; mesh.selectedFaces) if (s) hash = hash * 31 + cast(uint)i;
        }
        return hash;
    }

    void buildVertexCacheIfNeeded() {
        if (!vertexCacheDirty) return;

        int[] indices;

        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; mesh.selectedVertices) if (s) { any = true; break; }
            if (any) {
                foreach (i, s; mesh.selectedVertices)
                    if (s && i < mesh.vertices.length) indices ~= cast(int)i;
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; mesh.selectedEdges) if (s) { any = true; break; }
            if (any) {
                bool[] added = new bool[](mesh.vertices.length);
                foreach (i, edge; mesh.edges) {
                    if (i < mesh.selectedEdges.length && mesh.selectedEdges[i]) {
                        if (!added[edge[0]]) { added[edge[0]] = true; indices ~= cast(int)edge[0]; }
                        if (!added[edge[1]]) { added[edge[1]] = true; indices ~= cast(int)edge[1]; }
                    }
                }
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; mesh.selectedFaces) if (s) { any = true; break; }
            if (any) {
                bool[] added = new bool[](mesh.vertices.length);
                foreach (i, face; mesh.faces) {
                    if (i < mesh.selectedFaces.length && mesh.selectedFaces[i]) {
                        foreach (vi; face)
                            if (!added[vi]) { added[vi] = true; indices ~= cast(int)vi; }
                    }
                }
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        }

        vertexIndicesToProcess = indices;
        vertexProcessCount = cast(int)indices.length;
        vertexCacheDirty = false;

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;
        foreach (vi; vertexIndicesToProcess)
            toProcess[vi] = true;
    }

    void uploadToGpu() {
        if (vertexProcessCount <= 0) return;
        if (vertexProcessCount < cast(int)(mesh.vertices.length * 0.8))
            gpu.uploadSelectedVertices(*mesh, toProcess);
        else
            gpu.upload(*mesh);
    }

    float gizmoScreenWidth(Vec3 center) {
        Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4], cachedVp.view[8]);
        Vec3 rightEnd = Vec3(center.x + camRight.x * handler.size,
                             center.y + camRight.y * handler.size,
                             center.z + camRight.z * handler.size);
        float cx, cy, cndcZ, rx, ry, rndcZ;
        if (!projectToWindowFull(center,   cachedVp, cx, cy, cndcZ)) return -1.0f;
        if (!projectToWindowFull(rightEnd, cachedVp, rx, ry, rndcZ)) return -1.0f;
        return sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    }

    // Apply an incremental scale factor to cached vertex indices (partial selection path).
    void applyScaleAxesFactor(bool sx, bool sy, bool sz, float factor) {
        Vec3 center = handler.center;
        foreach (vi; vertexIndicesToProcess) {
            if (sx) mesh.vertices[vi].x = center.x + (mesh.vertices[vi].x - center.x) * factor;
            if (sy) mesh.vertices[vi].y = center.y + (mesh.vertices[vi].y - center.y) * factor;
            if (sz) mesh.vertices[vi].z = center.z + (mesh.vertices[vi].z - center.z) * factor;
        }
        needsGpuUpdate = true;
    }

    // Apply scale from drag-start snapshot to mesh.vertices at mouseUp (whole-mesh).
    void commitWholeMeshScale() {
        if (dragStartVertices.length != mesh.vertices.length) return;
        Vec3 center = handler.center;
        float lx = scaleAccum.x / dragStartScaleAccum.x;
        float ly = scaleAccum.y / dragStartScaleAccum.y;
        float lz = scaleAccum.z / dragStartScaleAccum.z;
        foreach (i; 0 .. mesh.vertices.length) {
            mesh.vertices[i].x = center.x + (dragStartVertices[i].x - center.x) * lx;
            mesh.vertices[i].y = center.y + (dragStartVertices[i].y - center.y) * ly;
            mesh.vertices[i].z = center.z + (dragStartVertices[i].z - center.z) * lz;
        }
    }

    // Apply scale from activationVertices to CPU vertices only (no GPU).
    // Uses current scaleAccum for all three axes.
    void applyScaleFromActivationCpuOnly() {
        if (activationVertices.length == 0) return;
        Vec3 center = activationCenter;
        foreach (vi; vertexIndicesToProcess) {
            mesh.vertices[vi].x = center.x + (activationVertices[vi].x - center.x) * scaleAccum.x;
            mesh.vertices[vi].y = center.y + (activationVertices[vi].y - center.y) * scaleAccum.y;
            mesh.vertices[vi].z = center.z + (activationVertices[vi].z - center.z) * scaleAccum.z;
        }
    }

    // Upload a vertex snapshot to GPU without modifying mesh.vertices.
    // Used once at the start of a props drag to establish the GPU base for gpuMatrix.
    void uploadPropsBase(Vec3[] base) {
        Vec3[] saved = mesh.vertices;
        mesh.vertices = base;
        gpu.upload(*mesh);
        mesh.vertices = saved;
    }

    int hitTestAxes(int mx, int my) {
        if (handler.centerDisk.hitTest(mx, my, cachedVp)) return 3;
        if (handler.circleXY.hitTest(mx, my, cachedVp)) return 4;
        if (handler.circleYZ.hitTest(mx, my, cachedVp)) return 5;
        if (handler.circleXZ.hitTest(mx, my, cachedVp)) return 6;

        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}
