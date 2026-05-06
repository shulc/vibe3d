module tools.rotate;

import bindbc.opengl;
import bindbc.sdl;

import tools.transform;
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

class RotateTool : TransformTool {
    RotateHandler handler;

private:
    float    cachedSize;      // gizmo radius in world units (from last draw)
    Vec3     dragStartDir;    // direction from center to click point in arc plane
    float    totalAngle = 0;       // accumulated raw angle during drag (radians)
    float    lastSnappedAngle = 0; // last snapped angle value (kept in sync for display)
    Vec3     viewDragAxis;    // camera forward captured at start of view-plane drag
    Vec3     dragAxisVec;     // axis vector for current drag (cached to avoid recomputation)
    Vec3     angleAccum = Vec3(0, 0, 0);  // total rotation per axis since tool activated (radians)
    Vec3     propDeg = Vec3(0, 0, 0);     // persistent value shown in Tool Properties (degrees)
    Vec3[]   origVertices;                // snapshot of vertex positions at activate()

    // Phase C.3: Tool Properties state at the START of the current edit
    // session, captured by snapshotEditState() and restored on undo via
    // hooks attached to the recorded MeshVertexEdit. Lets undo of a single
    // slider release peel back ONLY that drag's contribution to propDeg /
    // angleAccum without zeroing the other axes.
    Vec3     preEditAngleAccum;
    Vec3     preEditPropDeg;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        handler = new RotateHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Rotate"; }

    override void activate() {
        super.activate();
        angleAccum = Vec3(0, 0, 0);
        propDeg = Vec3(0, 0, 0);
        origVertices = mesh.vertices.dup;
    }

    override void update() {
        if (!active) return;

        // Selection / mesh cannot change during a drag — skip checks entirely.
        if (dragAxis >= 0) return;

        uint  currentHash   = computeSelectionHash();
        ulong currentMutVer = mesh.mutationVersion;
        bool selChanged = (currentHash   != lastSelectionHash);
        bool mutChanged = (currentMutVer != lastMutationVersion);
        if (!selChanged && !mutChanged) return;

        lastSelectionHash   = currentHash;
        lastMutationVersion = currentMutVer;
        vertexCacheDirty    = true;

        // Geometry-only change: the per-edit hook on the (un)applied
        // MeshVertexEdit has already restored angleAccum / propDeg to the
        // value they held at that edit's boundary. origVertices stays at
        // its activate-time value — the (origVertices, angleAccum)
        // contract is invariant: applying angleAccum to origVertices
        // always reproduces the current mesh state, even across undo/redo.

        // Selection change: zero the accumulators and refresh everything.
        // The per-edit hooks for now-stale entries on the stack still
        // reference the OLD (origVertices, angleAccum) tuple — they'll
        // misfire if undone after re-selection, but that's an acceptable
        // edge case (cross-selection undo rarely makes sense anyway).
        if (selChanged) {
            angleAccum   = Vec3(0, 0, 0);
            propDeg      = Vec3(0, 0, 0);
            origVertices = mesh.vertices.dup;
            centerManual = false;
            // Phase 7.2a: pivot via ACEN stage.
            cachedCenter = queryActionCenter();
        }

        if (!centerManual)
            handler.setPosition(cachedCenter);
    }

    // Snapshot Tool-Properties state at the start of an edit session, so
    // the matching commitEdit can attach an undo-restore hook holding
    // these values. Called from beginEdit-adjacent sites (mouseButtonDown,
    // first slider-active frame).
    private void snapshotEditState() {
        preEditAngleAccum = angleAccum;
        preEditPropDeg    = propDeg;
    }

    protected override void commitEdit(string label) {
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        // Closure-capture the before/after Tool-Properties state. After
        // recording, history.undo() runs revert (vert positions revert,
        // then angleAccum/propDeg snap back to the pre-edit values);
        // history.redo() does the opposite.
        Vec3 accBefore  = preEditAngleAccum;
        Vec3 propBefore = preEditPropDeg;
        Vec3 accAfter   = angleAccum;
        Vec3 propAfter  = propDeg;
        cmd.setHooks(
            () { angleAccum = accAfter;  propDeg = propAfter;  },
            () { angleAccum = accBefore; propDeg = propBefore; }
        );
        history.record(cmd);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Orient gizmo into the active workplane basis (auto ⇒ identity).
        // arcX rotates around axisX, arcY around axisY, arcZ around axisZ.
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ);
        handler.setOrientation(bX, bY, bZ);

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
            // Click outside gizmo: teleport rotation center to the clicked
            // point. Most-facing plane is picked from the gizmo's basis so
            // workplane-aligned tools land hits on the workplane plane.
            import std.math : abs;
            const ref float[16] v = cachedVp.view;
            Vec3 camBack = Vec3(v[2], v[6], v[10]);
            float aX = abs(dot(camBack, handler.axisX));
            float aY = abs(dot(camBack, handler.axisY));
            float aZ = abs(dot(camBack, handler.axisZ));
            Vec3 n = aX >= aY && aX >= aZ ? handler.axisX
                   : aY >= aX && aY >= aZ ? handler.axisY
                                          : handler.axisZ;
            Vec3 hit;
            if (!rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
                                   handler.center, n, hit))
                return false;
            handler.setPosition(hit);
            centerManual = true;
            notifyAcenUserPlaced(hit);
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
        snapshotEditState();   // capture pre-drag Tool-Properties state.
        beginEdit();           // Phase C.3: snapshot pre-drag positions for undo.

        // Cache the axis vector for the duration of this drag — basis-
        // aware (workplane axis1/normal/axis2 when non-auto).
        if (dragAxis == 3) {
            viewDragAxis = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
            dragAxisVec = viewDragAxis;
        } else {
            dragAxisVec = dragAxis == 0 ? handler.axisX
                        : dragAxis == 1 ? handler.axisY
                                        : handler.axisZ;
        }

        // Compute drag start direction in the arc plane.
        Vec3 hit;
        if (rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
                              handler.center, dragAxisVec, hit)) {
            Vec3 d = hit - handler.center;
            float dlen = sqrt(d.x*d.x + d.y*d.y + d.z*d.z) * 1.05f;
            dragStartDir = dlen > 1e-6f ? d / dlen
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
            // angleAccum.{x,y,z} are rotations around the gizmo's basis
            // (axisX/Y/Z). Decompose the view-aligned rotation onto those
            // axes via dot products — identity basis collapses to the
            // legacy world-XYZ behaviour.
            angleAccum.x += effectiveAngle * dot(viewDragAxis, handler.axisX);
            angleAccum.y += effectiveAngle * dot(viewDragAxis, handler.axisY);
            angleAccum.z += effectiveAngle * dot(viewDragAxis, handler.axisZ);
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
        commitEdit("Rotate");   // Phase C.3: land this drag as one undo entry.
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

        Vec3 d1 = hitPrev - center;
        Vec3 d2 = hitCurr - center;
        float l1 = sqrt(d1.x*d1.x + d1.y*d1.y + d1.z*d1.z);
        float l2 = sqrt(d2.x*d2.x + d2.y*d2.y + d2.z*d2.z);
        if (l1 < 1e-6f || l2 < 1e-6f) { lastMX = e.x; lastMY = e.y; return true; }
        d1 = d1 / l1;
        d2 = d2 / l2;
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
            // For view-axis drag (==3) the in-progress angle is decomposed
            // onto the basis triple (matches onMouseButtonUp's accumulation).
            float vx = dragAxis == 3 ? dot(viewDragAxis, handler.axisX) : 0;
            float vy = dragAxis == 3 ? dot(viewDragAxis, handler.axisY) : 0;
            float vz = dragAxis == 3 ? dot(viewDragAxis, handler.axisZ) : 0;
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

        // Phase C.3: snapshot pre-drag positions on first active frame so
        // commitEdit at slider release has a baseline. beginEdit is
        // idempotent within an open edit; snapshotEditState too if we
        // gate it on the same edit-not-yet-open check.
        if (anyActive && !editIsOpen()) {
            snapshotEditState();
            beginEdit();
        } else if (anyActive) {
            beginEdit();   // idempotent
        }

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
            commitEdit("Rotate");   // Phase C.3: land slider drag on undo stack.
        }
    }

private:

    Vec3 rotateVec(Vec3 v, Vec3 pivot, Vec3 axis, float angle) {
        float c = cos(angle), s = sin(angle);
        Vec3 p = v - pivot;
        float d = dot(p, axis);
        Vec3 pcr = cross(axis, p);
        return pivot + p * c + pcr * s + axis * (d * (1.0f - c));
    }

    // Apply final rotation from dragStartVertices to mesh.vertices at mouseUp.
    void commitWholeMeshRotation(float angle) {
        if (dragStartVertices.length != mesh.vertices.length) return;
        Vec3 pivot = handler.center;
        foreach (i; 0 .. mesh.vertices.length)
            mesh.vertices[i] = rotateVec(dragStartVertices[i], pivot, dragAxisVec, angle);
    }

    // Apply X→Y→Z Euler rotation from origVertices to CPU vertices only (no GPU).
    // angleAccum.x/.y/.z are interpreted around the gizmo's basis (workplane
    // axis1/normal/axis2 when non-auto, world XYZ when auto).
    void applyAbsoluteFromOrigCpuOnly() {
        if (origVertices.length != mesh.vertices.length) return;
        Vec3 pivot = handler.center;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toProcess[i]) { mesh.vertices[i] = origVertices[i]; continue; }
            Vec3 v = origVertices[i];
            if (angleAccum.x != 0) v = rotateVec(v, pivot, handler.axisX, angleAccum.x);
            if (angleAccum.y != 0) v = rotateVec(v, pivot, handler.axisY, angleAccum.y);
            if (angleAccum.z != 0) v = rotateVec(v, pivot, handler.axisZ, angleAccum.z);
            mesh.vertices[i] = v;
        }
    }

    // Compose the current angleAccum into a single 4x4 rotation matrix around the pivot.
    float[16] computePropsRotationMatrix() {
        Vec3 pivot = handler.center;
        float[16] m = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        if (angleAccum.x != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisX, angleAccum.x));
        if (angleAccum.y != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisY, angleAccum.y));
        if (angleAccum.z != 0) m = matMul4(m, pivotRotationMatrix(pivot, handler.axisZ, angleAccum.z));
        return m;
    }

    // Apply incremental rotation to cached vertex indices — used for partial selection.
    void applyRotationVec(Vec3 axisVec, float angle) {
        Vec3 pivot = handler.center;
        foreach (vi; vertexIndicesToProcess)
            mesh.vertices[vi] = rotateVec(mesh.vertices[vi], pivot, axisVec, angle);
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
            return rotateVec(p, Vec3(0,0,0), axisVec, a);
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
            Vec3 w = center + rodrig(dragStartDir, a) * cachedSize;
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { sectorOk = false; break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        if (sectorOk) dl.PathFillConvex(fillCol);
        else          dl.PathClear();

        for (int i = 0; i <= N; i++) {
            float a = dispAngle * i / N;
            Vec3 w = center + rodrig(dragStartDir, a) * cachedSize;
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { dl.PathClear(); break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        dl.PathStroke(lineCol, ImDrawFlags.None, 1.0f);

        float ssx, ssy, sex, sey, ndcZ;
        Vec3 startWorld = center + dragStartDir * cachedSize;
        Vec3 endWorld   = center + rodrig(dragStartDir, dispAngle) * cachedSize;
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
