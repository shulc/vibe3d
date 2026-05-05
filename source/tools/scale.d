module tools.scale;

import bindbc.opengl;
import bindbc.sdl;

import tools.transform;
import handler;
import mesh;
import editmode;
import math;
import shader;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt;


// ---------------------------------------------------------------------------
// ScaleTool : TransformTool — shows ScaleHandler at selection/mesh center; scales
//             selected vertices along the dragged axis relative to the center.
// ---------------------------------------------------------------------------

class ScaleTool : TransformTool {
    ScaleHandler handler;

private:
    Vec3     scaleAccum     = Vec3(1, 1, 1);  // cumulative scale factor per axis since tool activated
    Vec3     dragScaleAccum = Vec3(1, 1, 1);  // scale within current drag (for yellow arrows)
    Vec3     propScale      = Vec3(1, 1, 1);  // persistent value shown in Tool Properties
    Vec3[]   activationVertices;              // mesh snapshot at tool activation (for props apply)
    Vec3     activationCenter;               // gizmo center at activation

    Vec3   dragStartScaleAccum;  // scaleAccum at the start of the current drag

    // Phase C.3: Tool Properties state at the start of the current edit
    // session, restored by hooks on undo of the matching MeshVertexEdit.
    Vec3   preEditScaleAccum;
    Vec3   preEditPropScale;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        handler = new ScaleHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Scale"; }

    override void activate() {
        super.activate();
        scaleAccum = Vec3(1, 1, 1);
        propScale  = Vec3(1, 1, 1);
        activationVertices = mesh.vertices.dup;
        activationCenter   = handler.center;
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

        // Geometry-only change: per-edit hooks have already restored
        // scaleAccum / propScale. activationVertices stays at the
        // activate-time baseline — applying scaleAccum to activationVertices
        // around activationCenter always reproduces current mesh state.

        // Selection change: zero accumulators and refresh everything.
        if (selChanged) {
            scaleAccum         = Vec3(1, 1, 1);
            propScale          = Vec3(1, 1, 1);
            activationVertices = mesh.vertices.dup;
            centerManual       = false;
            if (*editMode == EditMode.Vertices)
                cachedCenter = mesh.selectionCentroidVertices();
            else if (*editMode == EditMode.Edges)
                cachedCenter = mesh.selectionCentroidEdges();
            else if (*editMode == EditMode.Polygons)
                cachedCenter = mesh.selectionCentroidFaces();
            else
                cachedCenter = Vec3(0, 0, 0);
            activationCenter = cachedCenter;
        }
        // On geometry-only change, cachedCenter / activationCenter stay
        // at the same pivot the user grabbed.

        if (!centerManual && dragAxis == -1)
            handler.setPosition(cachedCenter);
    }

    private void snapshotEditState() {
        preEditScaleAccum = scaleAccum;
        preEditPropScale  = propScale;
    }

    protected override void commitEdit(string label) {
        auto cmd = buildEditCmd(label);
        if (cmd is null) return;

        Vec3 accBefore  = preEditScaleAccum;
        Vec3 propBefore = preEditPropScale;
        Vec3 accAfter   = scaleAccum;
        Vec3 propAfter  = propScale;
        cmd.setHooks(
            () { scaleAccum = accAfter;  propScale = propAfter;  },
            () { scaleAccum = accBefore; propScale = propBefore; }
        );
        history.record(cmd);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Orient gizmo into the active workplane basis.
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ);
        handler.setOrientation(bX, bY, bZ);

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
            snapshotEditState();   // capture pre-drag Tool-Properties state.
            beginEdit();           // Phase C.3: snapshot pre-drag positions for undo.
            return true;
        }

        // Click outside gizmo: teleport to most-facing plane at click point.
        // Plane normal picked from the gizmo's basis (workplane axes when
        // non-auto, world XYZ when auto).
        const ref float[16] v = cachedVp.view;
        import std.math : abs;
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
        commitEdit("Scale");   // Phase C.3: land this drag as one undo entry.
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
                gpuMatrix = pivotScaleMatrixBasis(center,
                    handler.axisX, handler.axisY, handler.axisZ,
                    lx, lx, lx);
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
                gpuMatrix = pivotScaleMatrixBasis(center,
                    handler.axisX, handler.axisY, handler.axisZ,
                    lx, ly, lz);
            } else {
                applyScaleAxesFactor(scaleX, scaleY, scaleZ, scaleFactor);
            }
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        Vec3 axis = dragAxis == 0 ? handler.axisX
                  : dragAxis == 1 ? handler.axisY
                                  : handler.axisZ;

        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(center + axis, cachedVp, ax_, ay_, andcZ))
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
            gpuMatrix = pivotScaleMatrixBasis(center,
                handler.axisX, handler.axisY, handler.axisZ,
                lx, ly, lz);
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

        // Phase C.3: snapshot pre-drag state on the FIRST active frame
        // only (before beginEdit() opens the session); subsequent frames
        // are no-ops on both calls.
        if (anyActive && !editIsOpen()) {
            snapshotEditState();
            beginEdit();
        } else if (anyActive) {
            beginEdit();   // idempotent
        }

        // Update CPU vertices from activationVertices (fast, no GPU).
        applyScaleFromActivationCpuOnly();

        if (anyActive) {
            if (wholeMesh) {
                // Whole-mesh: GPU bypass — upload base once at drag start, then only update matrix.
                if (!propsDragging) {
                    uploadPropsBase(activationVertices);
                    propsDragging = true;
                }
                gpuMatrix = pivotScaleMatrixBasis(activationCenter,
                    handler.axisX, handler.axisY, handler.axisZ,
                    scaleAccum.x, scaleAccum.y, scaleAccum.z);
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
            commitEdit("Scale");   // Phase C.3: land slider drag on undo stack.
        }
    }

private:
    float gizmoScreenWidth(Vec3 center) {
        Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4], cachedVp.view[8]);
        Vec3 rightEnd = center + camRight * handler.size;
        float cx, cy, cndcZ, rx, ry, rndcZ;
        if (!projectToWindowFull(center,   cachedVp, cx, cy, cndcZ)) return -1.0f;
        if (!projectToWindowFull(rightEnd, cachedVp, rx, ry, rndcZ)) return -1.0f;
        return sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    }

    // Apply an incremental scale factor to cached vertex indices (partial
    // selection path). Scaling happens along the gizmo's basis — workplane
    // axes when non-auto, world XYZ when auto.
    void applyScaleAxesFactor(bool sx, bool sy, bool sz, float factor) {
        Vec3 center = handler.center;
        Vec3 ax = handler.axisX, ay = handler.axisY, az = handler.axisZ;
        float fx = sx ? factor : 1.0f;
        float fy = sy ? factor : 1.0f;
        float fz = sz ? factor : 1.0f;
        foreach (vi; vertexIndicesToProcess)
            mesh.vertices[vi] = scaleAlongBasis(mesh.vertices[vi], center,
                                                ax, ay, az, fx, fy, fz);
        needsGpuUpdate = true;
    }

    // Apply scale from drag-start snapshot to mesh.vertices at mouseUp (whole-mesh).
    void commitWholeMeshScale() {
        if (dragStartVertices.length != mesh.vertices.length) return;
        Vec3 center = handler.center;
        Vec3 ax = handler.axisX, ay = handler.axisY, az = handler.axisZ;
        float lx = scaleAccum.x / dragStartScaleAccum.x;
        float ly = scaleAccum.y / dragStartScaleAccum.y;
        float lz = scaleAccum.z / dragStartScaleAccum.z;
        foreach (i; 0 .. mesh.vertices.length)
            mesh.vertices[i] = scaleAlongBasis(dragStartVertices[i], center,
                                               ax, ay, az, lx, ly, lz);
    }

    // Apply scale from activationVertices to CPU vertices only (no GPU).
    // Uses current scaleAccum for all three basis axes.
    void applyScaleFromActivationCpuOnly() {
        if (activationVertices.length == 0) return;
        Vec3 center = activationCenter;
        Vec3 ax = handler.axisX, ay = handler.axisY, az = handler.axisZ;
        foreach (vi; vertexIndicesToProcess)
            mesh.vertices[vi] = scaleAlongBasis(activationVertices[vi], center,
                                                ax, ay, az,
                                                scaleAccum.x, scaleAccum.y, scaleAccum.z);
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
