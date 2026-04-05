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

private:
    Mesh*     mesh;
    bool[]*   selected;
    bool[]*   selectedEdges;
    bool[]*   selectedFaces;
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

public:
    this(Mesh* mesh, bool[]* selected, bool[]* selectedEdges, bool[]* selectedFaces,
         GpuMesh* gpu, EditMode* editMode) {
        this.mesh          = mesh;
        this.selected      = selected;
        this.selectedEdges = selectedEdges;
        this.selectedFaces = selectedFaces;
        this.gpu           = gpu;
        this.editMode      = editMode;
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
    }
    override void deactivate() { active = false; dragAxis = -1; centerManual = false; }

    override void update() {
        if (!active) return;
        Vec3 sum   = Vec3(0, 0, 0);
        int  count = 0;
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; *selected) if (s) { anySelected = true; break; }
            foreach (i, v; mesh.vertices) {
                if (!anySelected || (i < (*selected).length && (*selected)[i])) {
                    sum = vec3Add(sum, v); count++;
                }
            }
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; *selectedEdges) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, edge; mesh.edges) {
                if (anySelected && !(i < (*selectedEdges).length && (*selectedEdges)[i])) continue;
                foreach (vi; edge) {
                    if (!visited[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; visited[vi] = true; }
                }
            }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; *selectedFaces) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, face; mesh.faces) {
                if (anySelected && !(i < (*selectedFaces).length && (*selectedFaces)[i])) continue;
                foreach (vi; face) {
                    if (!visited[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; visited[vi] = true; }
                }
            }
        }
        if (!centerManual && dragAxis == -1)
            handler.setPosition(count > 0
                ? Vec3(sum.x / count, sum.y / count, sum.z / count)
                : Vec3(0, 0, 0));
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

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
            // Uniform scale: horizontal mouse movement.
            // Moving left by full viewport width brings scale to 0.
            // Project handler.size along the screen-right vector to get pixel length
            Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4], cachedVp.view[8]);
            Vec3 rightEnd = Vec3(center.x + camRight.x * handler.size,
                                 center.y + camRight.y * handler.size,
                                 center.z + camRight.z * handler.size);
            float cx, cy, cndcZ, rx, ry, rndcZ;
            if (!projectToWindowFull(center,   cachedVp, cx, cy, cndcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            if (!projectToWindowFull(rightEnd, cachedVp, rx, ry, rndcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            float gizmoScreenPx = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
            if (gizmoScreenPx < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            float dx = cast(float)(e.x - lastMX);
            float scaleFactor = 1.0f + dx / gizmoScreenPx;
            // Clamp so no component goes negative (0 is allowed)
            float minAccum = scaleAccum.x < scaleAccum.y ? scaleAccum.x : scaleAccum.y;
            if (scaleAccum.z < minAccum) minAccum = scaleAccum.z;
            if (minAccum * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.x    *= scaleFactor;
            scaleAccum.y    *= scaleFactor;
            scaleAccum.z    *= scaleFactor;
            dragScaleAccum.x *= scaleFactor;
            dragScaleAccum.y *= scaleFactor;
            dragScaleAccum.z *= scaleFactor;
            applyScaleUniform(scaleFactor);
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // Plane drags: 4=XY, 5=YZ, 6=XZ — scale two axes via horizontal movement
        if (dragAxis >= 4) {
            Vec3 camRight = Vec3(cachedVp.view[0], cachedVp.view[4], cachedVp.view[8]);
            Vec3 rightEnd = Vec3(center.x + camRight.x * handler.size,
                                 center.y + camRight.y * handler.size,
                                 center.z + camRight.z * handler.size);
            float cx, cy, cndcZ, rx, ry, rndcZ;
            if (!projectToWindowFull(center,   cachedVp, cx, cy, cndcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            if (!projectToWindowFull(rightEnd, cachedVp, rx, ry, rndcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            float gizmoScreenPx = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
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
            applyScale2(scaleX, scaleY, scaleZ, scaleFactor);
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        Vec3 axis = dragAxis == 0 ? Vec3(1,0,0)
                  : dragAxis == 1 ? Vec3(0,1,0)
                                  : Vec3(0,0,1);

        // Project axis to screen to get pixels-per-world-unit
        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(vec3Add(center, axis), cachedVp, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx   = ax_ - cx;
        float sdy   = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        float delta       = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
        float scaleFactor = 1.0f + delta;
        if (dragAxis == 0) {
            if (scaleAccum.x * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.x    *= scaleFactor;
            dragScaleAccum.x *= scaleFactor;
        } else if (dragAxis == 1) {
            if (scaleAccum.y * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.y    *= scaleFactor;
            dragScaleAccum.y *= scaleFactor;
        } else if (dragAxis == 2) {
            if (scaleAccum.z * scaleFactor < 0.0f) scaleFactor = 0.0f;
            scaleAccum.z    *= scaleFactor;
            dragScaleAccum.z *= scaleFactor;
        }

        applyScale(dragAxis, scaleFactor);

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
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (propScale.x < 0.0f) propScale.x = 0.0f;
            applyScaleFromActivation(0, propScale.x);
            scaleAccum.x = propScale.x;
        }
        ImGui.DragFloat("Y", &propScale.y, 0.01f, 0.0f, float.max, "%.4f");
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (propScale.y < 0.0f) propScale.y = 0.0f;
            applyScaleFromActivation(1, propScale.y);
            scaleAccum.y = propScale.y;
        }
        ImGui.DragFloat("Z", &propScale.z, 0.01f, 0.0f, float.max, "%.4f");
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (propScale.z < 0.0f) propScale.z = 0.0f;
            applyScaleFromActivation(2, propScale.z);
            scaleAccum.z = propScale.z;
        }
    }

private:
    void applyScaleUniform(float factor) {
        Vec3 center = handler.center;
        bool[] toScale = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toScale[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toScale[edge[0]] = true; toScale[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toScale[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toScale[i]) continue;
            mesh.vertices[i].x = center.x + (mesh.vertices[i].x - center.x) * factor;
            mesh.vertices[i].y = center.y + (mesh.vertices[i].y - center.y) * factor;
            mesh.vertices[i].z = center.z + (mesh.vertices[i].z - center.z) * factor;
        }
        gpu.upload(*mesh);
        update();
    }

    void applyScale(int axisIdx, float factor) {
        Vec3 axis = axisIdx == 0 ? Vec3(1,0,0)
                  : axisIdx == 1 ? Vec3(0,1,0)
                                 : Vec3(0,0,1);
        Vec3 center = handler.center;
        bool[] toScale = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toScale[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toScale[edge[0]] = true; toScale[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toScale[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toScale[i]) continue;
            mesh.vertices[i].x += axis.x * (mesh.vertices[i].x - center.x) * (factor - 1.0f);
            mesh.vertices[i].y += axis.y * (mesh.vertices[i].y - center.y) * (factor - 1.0f);
            mesh.vertices[i].z += axis.z * (mesh.vertices[i].z - center.z) * (factor - 1.0f);
        }
        gpu.upload(*mesh);
        update();
    }

    private void applyScaleFromActivation(int axisIdx, float targetScale) {
        if (activationVertices.length == 0) return;
        Vec3 center = activationCenter;
        bool[] toScale = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toScale[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toScale[edge[0]] = true; toScale[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toScale[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toScale[i]) continue;
            // Restore from activation snapshot, then apply current propScale on all axes
            mesh.vertices[i].x = center.x + (activationVertices[i].x - center.x) * (axisIdx == 0 ? targetScale : scaleAccum.x);
            mesh.vertices[i].y = center.y + (activationVertices[i].y - center.y) * (axisIdx == 1 ? targetScale : scaleAccum.y);
            mesh.vertices[i].z = center.z + (activationVertices[i].z - center.z) * (axisIdx == 2 ? targetScale : scaleAccum.z);
        }
        gpu.upload(*mesh);
        update();
    }

    private void applyScale2(bool sx, bool sy, bool sz, float factor) {
        Vec3 center = handler.center;
        bool[] toScale = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toScale[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toScale[edge[0]] = true; toScale[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toScale[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toScale[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toScale[i]) continue;
            if (sx) mesh.vertices[i].x += (mesh.vertices[i].x - center.x) * (factor - 1.0f);
            if (sy) mesh.vertices[i].y += (mesh.vertices[i].y - center.y) * (factor - 1.0f);
            if (sz) mesh.vertices[i].z += (mesh.vertices[i].z - center.z) * (factor - 1.0f);
        }
        gpu.upload(*mesh);
        update();
    }

    private int hitTestAxes(int mx, int my) {
        // Center disk checked first — it's on top visually.
        if (handler.centerDisk.hitTest(mx, my, cachedVp)) return 3;

        // Plane circles: 4=XY, 5=YZ, 6=XZ
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