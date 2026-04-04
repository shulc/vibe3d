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
    Vec3     scaleAccum = Vec3(1, 1, 1);  // cumulative scale factor per axis since tool activated
    Vec3     propScale = Vec3(1, 1, 1);  // persistent value shown in Tool Properties

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
    override void activate()   { active = true; scaleAccum = Vec3(1, 1, 1); propScale = Vec3(1, 1, 1); }
    override void deactivate() { active = false; dragAxis = -1; }

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
            bool isActive = (dragAxis == cast(int)i);
            arrow.setForceHovered(isActive);
            arrow.setHoverBlocked(dragAxis >= 0 && !isActive || anyHovered);
            anyHovered |= arrow.isHovered();
        }
        handler.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis < 0) return false;
        lastMX = e.x; lastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;
        dragAxis = -1;
        propScale = scaleAccum;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        Vec3 axis = dragAxis == 0 ? Vec3(1,0,0)
                  : dragAxis == 1 ? Vec3(0,1,0)
                                  : Vec3(0,0,1);

        // Project axis to screen to get pixels-per-world-unit
        Vec3  center = handler.center;
        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(vec3Add(center, axis), cachedVp, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx   = ax_ - cx;
        float sdy   = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        // Mouse delta projected onto screen-space axis → scale factor
        float delta      = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
        float scaleFactor = 1.0f + delta;
        if (dragAxis == 0) scaleAccum.x *= scaleFactor;
        else if (dragAxis == 1) scaleAccum.y *= scaleFactor;
        else if (dragAxis == 2) scaleAccum.z *= scaleFactor;

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
        float x = scaleAccum.x, y = scaleAccum.y, z = scaleAccum.z;
        if (dragAxis >= 0) propScale = scaleAccum;
        ImGui.DragFloat("X", &propScale.x, 0.01f, 0, 0, "%.4f");
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (scaleAccum.x != 0 && propScale.x != scaleAccum.x) { applyScale(0, propScale.x / scaleAccum.x); scaleAccum.x = propScale.x; }
        }
        ImGui.DragFloat("Y", &propScale.y, 0.01f, 0, 0, "%.4f");
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (scaleAccum.y != 0 && propScale.y != scaleAccum.y) { applyScale(1, propScale.y / scaleAccum.y); scaleAccum.y = propScale.y; }
        }
        ImGui.DragFloat("Z", &propScale.z, 0.01f, 0, 0, "%.4f");
        if (ImGui.IsItemActive() || ImGui.IsItemDeactivatedAfterEdit()) {
            if (scaleAccum.z != 0 && propScale.z != scaleAccum.z) { applyScale(2, propScale.z / scaleAccum.z); scaleAccum.z = propScale.z; }
        }
    }

private:
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

    private int hitTestAxes(int mx, int my) {
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