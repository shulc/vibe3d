module tools.rotate;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import handler;
import mesh;
import editmode;
import math;
import shader;

import std.math;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// RotateTool : Tool — shows RotateHandler at selection/mesh center;
//              rotates selected vertices around the dragged axis.
// ---------------------------------------------------------------------------

class RotateTool : Tool {
    RotateHandler handler;
    bool          active;

    // app.d reads this every frame and sets u_model accordingly.
    // Reset to identity when not in a whole-mesh drag.
    float[16] gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    int      dragAxis = -1;   // 0=X 1=Y 2=Z 3=View  -1=none
    bool     centerManual;    // true = update() must not recompute handler.center
    int      lastMX, lastMY;
    Viewport cachedVp;
    float    cachedSize;      // gizmo radius in world units (from last draw)
    Vec3     dragStartDir;    // direction from center to click point in arc plane
    float    totalAngle = 0;       // accumulated raw angle during drag (radians)
    float    lastSnappedAngle = 0; // last snapped angle value (kept in sync for display)
    Vec3     viewDragAxis;    // camera forward captured at start of view-plane drag
    Vec3     dragAxisVec;     // axis vector for current drag (cached to avoid recomputation)
    Vec3     angleAccum = Vec3(0, 0, 0);  // total rotation per axis since tool activated (radians)
    Vec3     propDeg = Vec3(0, 0, 0);     // persistent value shown in Tool Properties (degrees)
    Vec3[]   origVertices;                // snapshot of vertex positions at activate()

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
    bool   wholeMeshDrag;   // true when mouse drag bypasses GPU uploads entirely
    bool   propsDragging;   // true when DragFloat props drag bypasses GPU uploads

    // Cached gizmo center (recomputed only when selection hash changes).
    Vec3   cachedCenter;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;
        handler = new RotateHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Rotate"; }

    override void activate() {
        active = true;
        centerManual = false;
        angleAccum = Vec3(0, 0, 0);
        propDeg = Vec3(0, 0, 0);
        origVertices = mesh.vertices.dup;
        vertexCacheDirty = true;
        lastSelectionHash = uint.max;
        needsGpuUpdate = false;
        wholeMeshDrag = false;
        propsDragging = false;
        gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    }

    override void deactivate() {
        active = false;
        // Commit any pending state to GPU.
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

        if (*editMode == EditMode.Vertices)
            cachedCenter = mesh.selectionCentroidVertices();
        else if (*editMode == EditMode.Edges)
            cachedCenter = mesh.selectionCentroidEdges();
        else if (*editMode == EditMode.Polygons)
            cachedCenter = mesh.selectionCentroidFaces();
        else
            cachedCenter = Vec3(0, 0, 0);

        if (!centerManual)
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

        SemicircleHandler[3] arcs = [handler.arcX, handler.arcY, handler.arcZ];
        bool anyHovered = false;
        foreach (i, arc; arcs) {
            bool isActive = (dragAxis == cast(int)i);
            arc.setForceHovered(isActive);
            arc.setHoverBlocked(dragAxis >= 0 && !isActive || anyHovered);
            anyHovered |= arc.isHovered();
        }
        handler.arcView.setForceHovered(dragAxis == 3);
        handler.arcView.setHoverBlocked(dragAxis >= 0 && dragAxis != 3 || anyHovered);

        handler.draw(shader, vp);
        cachedSize = handler.size;

        if (dragAxis >= 0 && (dragStartDir.x != 0 || dragStartDir.y != 0 || dragStartDir.z != 0))
            drawRotationSector(vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis < 0) {
            // Click outside gizmo: teleport rotation center to the clicked point.
            import std.math : abs;
            const ref float[16] v = cachedVp.view;
            float avx = abs(v[2]), avy = abs(v[6]), avz = abs(v[10]);
            Vec3 n = avx >= avy && avx >= avz ? Vec3(1,0,0)
                   : avy >= avx && avy >= avz ? Vec3(0,1,0)
                                              : Vec3(0,0,1);
            Vec3 hit;
            if (!rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
                                   handler.center, n, hit))
                return false;
            handler.setPosition(hit);
            centerManual = true;
            origVertices = mesh.vertices.dup;
            angleAccum = Vec3(0, 0, 0);
            propDeg    = Vec3(0, 0, 0);
            propsDragging = false;
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            return true;
        }
        lastMX = e.x; lastMY = e.y;
        totalAngle = 0;
        lastSnappedAngle = 0;

        // Build vertex cache now so we know whether this is a whole-mesh drag.
        buildVertexCacheIfNeeded();
        wholeMeshDrag = (vertexProcessCount == cast(int)mesh.vertices.length);
        if (wholeMeshDrag) {
            // Snapshot current vertex positions — GPU is in sync with these.
            dragStartVertices = mesh.vertices.dup;
        }

        // Cache the axis vector for the duration of this drag.
        if (dragAxis == 3) {
            viewDragAxis = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
            dragAxisVec = viewDragAxis;
        } else {
            dragAxisVec = dragAxis == 0 ? Vec3(1,0,0)
                        : dragAxis == 1 ? Vec3(0,1,0)
                                        : Vec3(0,0,1);
        }

        // Compute drag start direction in the arc plane.
        Vec3 hit;
        if (rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
                              handler.center, dragAxisVec, hit)) {
            Vec3 d = vec3Sub(hit, handler.center);
            float dlen = sqrt(d.x*d.x + d.y*d.y + d.z*d.z) * 1.05f;
            dragStartDir = dlen > 1e-6f ? Vec3(d.x/dlen, d.y/dlen, d.z/dlen)
                                        : Vec3(0,0,0);
        } else {
            dragStartDir = Vec3(0,0,0);
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;
        float effectiveAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
        if (dragAxis == 0) angleAccum.x += effectiveAngle;
        else if (dragAxis == 1) angleAccum.y += effectiveAngle;
        else if (dragAxis == 2) angleAccum.z += effectiveAngle;
        else if (dragAxis == 3) {
            angleAccum.x += effectiveAngle * viewDragAxis.x;
            angleAccum.y += effectiveAngle * viewDragAxis.y;
            angleAccum.z += effectiveAngle * viewDragAxis.z;
        }

        if (wholeMeshDrag) {
            // Apply the final rotation to CPU vertices from the drag-start snapshot.
            commitWholeMeshRotation(effectiveAngle);
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
        } else if (needsGpuUpdate) {
            uploadToGpu();
            needsGpuUpdate = false;
        }

        dragAxis   = -1;
        totalAngle = 0;
        import std.math : PI;
        propDeg = Vec3(angleAccum.x * 180.0f / PI,
                       angleAccum.y * 180.0f / PI,
                       angleAccum.z * 180.0f / PI);
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        Vec3 center = handler.center;

        Vec3 camOrigin = viewCamOrigin();
        Vec3 hitCurr, hitPrev;
        if (!rayPlaneIntersect(camOrigin, screenRay(e.x,    e.y,    cachedVp), center, dragAxisVec, hitCurr) ||
            !rayPlaneIntersect(camOrigin, screenRay(lastMX, lastMY, cachedVp), center, dragAxisVec, hitPrev))
        { lastMX = e.x; lastMY = e.y; return true; }

        Vec3 d1 = vec3Sub(hitPrev, center);
        Vec3 d2 = vec3Sub(hitCurr, center);
        float l1 = sqrt(d1.x*d1.x + d1.y*d1.y + d1.z*d1.z);
        float l2 = sqrt(d2.x*d2.x + d2.y*d2.y + d2.z*d2.z);
        if (l1 < 1e-6f || l2 < 1e-6f) { lastMX = e.x; lastMY = e.y; return true; }
        d1 = Vec3(d1.x/l1, d1.y/l1, d1.z/l1);
        d2 = Vec3(d2.x/l2, d2.y/l2, d2.z/l2);
        Vec3  cr    = cross(d1, d2);
        float angle = atan2(dot(cr, dragAxisVec), dot(d1, d2));
        totalAngle += angle;

        bool ctrlHeld = (SDL_GetModState() & KMOD_CTRL) != 0;
        float effectiveAngle;
        if (ctrlHeld) {
            import std.math : round, PI;
            enum float step = PI / 12.0f; // 15°
            lastSnappedAngle = round(totalAngle / step) * step;
            effectiveAngle = lastSnappedAngle;
        } else {
            effectiveAngle = totalAngle;
            import std.math : round, PI;
            lastSnappedAngle = round(totalAngle / (PI / 12.0f)) * (PI / 12.0f);
        }

        if (wholeMeshDrag) {
            // Whole mesh: no CPU vertex work, no GPU upload — just update the matrix.
            gpuMatrix = pivotRotationMatrix(center, dragAxisVec, effectiveAngle);
        } else {
            // Partial selection: apply incremental delta to CPU vertices, defer GPU upload.
            // We recompute the delta from the previous effectiveAngle.
            // For ctrl: delta is the change in snapped angle.
            // For free: delta is the raw incremental angle.
            if (ctrlHeld) {
                import std.math : round, PI;
                enum float step2 = PI / 12.0f;
                float prevSnapped = round((totalAngle - angle) / step2) * step2;
                float delta = lastSnappedAngle - prevSnapped;
                if (delta != 0.0f)
                    applyRotationVec(dragAxisVec, delta);
            } else {
                applyRotationVec(dragAxisVec, angle);
            }
        }

        lastMX = e.x; lastMY = e.y;
        return true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Rotate           E");
        if (active)
            ImGui.PopStyleColor();
        return clicked;
    }

    override void drawProperties() {
        import std.math : PI;
        if (dragAxis >= 0) {
            float dispAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
            float vx = dragAxis == 3 ? viewDragAxis.x : 0;
            float vy = dragAxis == 3 ? viewDragAxis.y : 0;
            float vz = dragAxis == 3 ? viewDragAxis.z : 0;
            propDeg.x = (angleAccum.x + (dragAxis == 0 ? dispAngle : dispAngle * vx)) * 180.0f / PI;
            propDeg.y = (angleAccum.y + (dragAxis == 1 ? dispAngle : dispAngle * vy)) * 180.0f / PI;
            propDeg.z = (angleAccum.z + (dragAxis == 2 ? dispAngle : dispAngle * vz)) * 180.0f / PI;
        }
        ImGui.DragFloat("X", &propDeg.x, 0.1f, 0, 0, "%.2f");
        bool xActive = ImGui.IsItemActive(), xDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propDeg.y, 0.1f, 0, 0, "%.2f");
        bool yActive = ImGui.IsItemActive(), yDone = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propDeg.z, 0.1f, 0, 0, "%.2f");
        bool zActive = ImGui.IsItemActive(), zDone = ImGui.IsItemDeactivatedAfterEdit();

        bool anyActive = xActive || yActive || zActive;
        bool anyDone   = xDone   || yDone   || zDone;
        if (!(anyActive || anyDone)) return;

        angleAccum.x = propDeg.x * PI / 180.0f;
        angleAccum.y = propDeg.y * PI / 180.0f;
        angleAccum.z = propDeg.z * PI / 180.0f;
        buildVertexCacheIfNeeded();
        bool wholeMesh = (vertexProcessCount == cast(int)mesh.vertices.length);

        // Update CPU vertices from origVertices (fast, no GPU).
        applyAbsoluteFromOrigCpuOnly();

        if (anyActive) {
            if (wholeMesh) {
                // Whole-mesh: GPU bypass — upload base once at drag start, then only update matrix.
                if (!propsDragging) {
                    uploadPropsBase(origVertices);
                    propsDragging = true;
                }
                gpuMatrix = computePropsRotationMatrix();
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

    Vec3 viewCamOrigin() {
        const ref float[16] v = cachedVp.view;
        return Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
    }

    Vec3 rotateVec(Vec3 v, Vec3 pivot, Vec3 axis, float angle) {
        float c = cos(angle), s = sin(angle);
        Vec3 p = vec3Sub(v, pivot);
        float d = p.x*axis.x + p.y*axis.y + p.z*axis.z;
        Vec3 pcr = cross(axis, p);
        return vec3Add(pivot, Vec3(
            p.x*c + pcr.x*s + axis.x*d*(1.0f - c),
            p.y*c + pcr.y*s + axis.y*d*(1.0f - c),
            p.z*c + pcr.z*s + axis.z*d*(1.0f - c),
        ));
    }

    // Apply final rotation from dragStartVertices to mesh.vertices at mouseUp.
    void commitWholeMeshRotation(float angle) {
        if (dragStartVertices.length != mesh.vertices.length) return;
        Vec3 pivot = handler.center;
        float c = cos(angle), s = sin(angle);
        float ax = dragAxisVec.x, ay = dragAxisVec.y, az = dragAxisVec.z;
        float t = 1.0f - c;
        foreach (i; 0 .. mesh.vertices.length) {
            Vec3 p = vec3Sub(dragStartVertices[i], pivot);
            float dd = p.x*ax + p.y*ay + p.z*az;
            Vec3 pcr = cross(dragAxisVec, p);
            mesh.vertices[i] = vec3Add(pivot, Vec3(
                p.x*c + pcr.x*s + ax*dd*t,
                p.y*c + pcr.y*s + ay*dd*t,
                p.z*c + pcr.z*s + az*dd*t,
            ));
        }
    }

    // Apply X→Y→Z Euler rotation from origVertices to CPU vertices only (no GPU).
    void applyAbsoluteFromOrigCpuOnly() {
        if (origVertices.length != mesh.vertices.length) return;
        Vec3 pivot = handler.center;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toProcess[i]) { mesh.vertices[i] = origVertices[i]; continue; }
            Vec3 v = origVertices[i];
            if (angleAccum.x != 0) v = rotateVec(v, pivot, Vec3(1,0,0), angleAccum.x);
            if (angleAccum.y != 0) v = rotateVec(v, pivot, Vec3(0,1,0), angleAccum.y);
            if (angleAccum.z != 0) v = rotateVec(v, pivot, Vec3(0,0,1), angleAccum.z);
            mesh.vertices[i] = v;
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

    // Compose the current angleAccum into a single 4x4 rotation matrix around the pivot.
    float[16] computePropsRotationMatrix() {
        Vec3 pivot = handler.center;
        float[16] m = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        if (angleAccum.x != 0) m = matMul4(m, pivotRotationMatrix(pivot, Vec3(1,0,0), angleAccum.x));
        if (angleAccum.y != 0) m = matMul4(m, pivotRotationMatrix(pivot, Vec3(0,1,0), angleAccum.y));
        if (angleAccum.z != 0) m = matMul4(m, pivotRotationMatrix(pivot, Vec3(0,0,1), angleAccum.z));
        return m;
    }

    // Apply incremental rotation to cached vertex indices — used for partial selection.
    void applyRotationVec(Vec3 axisVec, float angle) {
        Vec3 pivot = handler.center;
        float c = cos(angle), s = sin(angle);
        foreach (vi; vertexIndicesToProcess) {
            Vec3 p = vec3Sub(mesh.vertices[vi], pivot);
            float dd = p.x*axisVec.x + p.y*axisVec.y + p.z*axisVec.z;
            Vec3 pcr = cross(axisVec, p);
            mesh.vertices[vi] = vec3Add(pivot, Vec3(
                p.x*c + pcr.x*s + axisVec.x*dd*(1.0f - c),
                p.y*c + pcr.y*s + axisVec.y*dd*(1.0f - c),
                p.z*c + pcr.z*s + axisVec.z*dd*(1.0f - c),
            ));
        }
        needsGpuUpdate = true;
    }

    void drawRotationSector(const ref Viewport vp) {
        import std.math : cos, sin, sqrt, abs, PI;

        Vec3 axisVec = dragAxisVec;
        Vec3 center = handler.center;

        float cx, cy, cndcZ;
        if (!projectToWindowFull(center, vp, cx, cy, cndcZ)) return;

        uint fillCol = dragAxis == 0 ? IM_COL32(220, 60,  60,  50)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60,  50)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220,  50)
                                     : IM_COL32(160, 160, 160,  50);
        uint lineCol = dragAxis == 0 ? IM_COL32(220, 60,  60, 200)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60, 200)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220, 200)
                                     : IM_COL32(180, 180, 180, 200);

        Vec3 rodrig(Vec3 p, float a) {
            float rc = cos(a), rs = sin(a);
            float rd = p.x*axisVec.x + p.y*axisVec.y + p.z*axisVec.z;
            Vec3 rcr = cross(axisVec, p);
            return Vec3(p.x*rc + rcr.x*rs + axisVec.x*rd*(1-rc),
                        p.y*rc + rcr.y*rs + axisVec.y*rd*(1-rc),
                        p.z*rc + rcr.z*rs + axisVec.z*rd*(1-rc));
        }

        ImDrawList* dl = ImGui.GetForegroundDrawList();

        float dispAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
        float aFrom = dispAngle < 0 ? dispAngle : 0.0f;
        float aTo   = dispAngle > 0 ? dispAngle : 0.0f;
        enum N = 32;
        dl.PathLineTo(ImVec2(cx, cy));
        bool sectorOk = true;
        for (int i = 0; i <= N; i++) {
            float a = aFrom + (aTo - aFrom) * i / N;
            Vec3 w = vec3Add(center, vec3Scale(rodrig(dragStartDir, a), cachedSize));
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { sectorOk = false; break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        if (sectorOk) dl.PathFillConvex(fillCol);
        else          dl.PathClear();

        for (int i = 0; i <= N; i++) {
            float a = dispAngle * i / N;
            Vec3 w = vec3Add(center, vec3Scale(rodrig(dragStartDir, a), cachedSize));
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { dl.PathClear(); break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        dl.PathStroke(lineCol, ImDrawFlags.None, 1.0f);

        float ssx, ssy, sex, sey, ndcZ;
        Vec3 startWorld = vec3Add(center, vec3Scale(dragStartDir, cachedSize));
        Vec3 endWorld   = vec3Add(center, vec3Scale(rodrig(dragStartDir, dispAngle), cachedSize));
        if (projectToWindowFull(startWorld, vp, ssx, ssy, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(ssx, ssy), lineCol, 1.0f);
        if (projectToWindowFull(endWorld,   vp, sex, sey, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(sex, sey), lineCol, 1.0f);

        import std.format : format;
        float deg = dispAngle * 180.0f / PI;
        string label = format("%.1f°", deg);
        dl.AddText(ImVec2(cx + 8, cy - 20), IM_COL32(255, 255, 255, 220), label);
    }

    int hitTestAxes(int mx, int my) {
        SemicircleHandler[3] arcs = [handler.arcX, handler.arcY, handler.arcZ];
        foreach (i, arc; arcs)
            if (arc.hitTest(mx, my, cachedVp))
                return cast(int)i;
        if (handler.arcView.hitTest(mx, my, cachedVp))
            return 3;
        return -1;
    }
}
