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

private:
    Mesh*     mesh;
    bool[]*   selected;
    bool[]*   selectedEdges;
    bool[]*   selectedFaces;
    GpuMesh*  gpu;
    EditMode* editMode;

    int      dragAxis = -1;   // 0=X 1=Y 2=Z  -1=none
    int      lastMX, lastMY;
    Viewport cachedVp;
    float    cachedSize;      // gizmo radius in world units (from last draw)
    Vec3     dragStartDir;    // direction from center to click point in arc plane
    float    totalAngle = 0;  // accumulated rotation angle during drag (radians)

public:
    this(Mesh* mesh, bool[]* selected, bool[]* selectedEdges, bool[]* selectedFaces,
         GpuMesh* gpu, EditMode* editMode) {
        this.mesh          = mesh;
        this.selected      = selected;
        this.selectedEdges = selectedEdges;
        this.selectedFaces = selectedFaces;
        this.gpu           = gpu;
        this.editMode      = editMode;
        handler = new RotateHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Rotate"; }
    override void activate()   { active = true; }
    override void deactivate() { active = false; dragAxis = -1; }

    override void update() {
        if (!active) return;
        Vec3 sum   = Vec3(0, 0, 0);
        int  count = 0;
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i, v; mesh.vertices)
                if (!any || (i < (*selected).length && (*selected)[i]))
                    { sum = vec3Add(sum, v); count++; }
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i, edge; mesh.edges) {
                if (any && !(i < (*selectedEdges).length && (*selectedEdges)[i])) continue;
                foreach (vi; edge)
                    if (!vis[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; vis[vi]=true; }
            }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i, face; mesh.faces) {
                if (any && !(i < (*selectedFaces).length && (*selectedFaces)[i])) continue;
                foreach (vi; face)
                    if (!vis[vi]) { sum = vec3Add(sum, mesh.vertices[vi]); count++; vis[vi]=true; }
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

        SemicircleHandler[3] arcs = [handler.arcX, handler.arcY, handler.arcZ];
        bool anyHovered = false;
        foreach (i, arc; arcs) {
            bool isActive = (dragAxis == cast(int)i);
            arc.setForceHovered(isActive);
            arc.setHoverBlocked(dragAxis >= 0 && !isActive || anyHovered);
            anyHovered |= arc.isHovered();
        }

        handler.draw(shader, vp);
        cachedSize = handler.size;

        if (dragAxis >= 0 && (dragStartDir.x != 0 || dragStartDir.y != 0 || dragStartDir.z != 0))
            drawRotationSector(vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis < 0) return false;
        lastMX = e.x; lastMY = e.y;
        totalAngle = 0;
        // Compute drag start direction: project click into the arc plane.
        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                                     : Vec3(0,0,1);
        const ref float[16] v = cachedVp.view;
        Vec3 camOrigin = Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
        Vec3 hit;
        if (rayPlaneIntersect(camOrigin, screenRay(e.x, e.y, cachedVp),
                              handler.center, axisVec, hit)) {
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
        dragAxis = -1;
        totalAngle = 0;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                                     : Vec3(0,0,1);

        Vec3 center = handler.center;

        // Cast rays for current and previous mouse positions into the arc plane.
        const ref float[16] v = cachedVp.view;
        Vec3 camOrigin = Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
        Vec3 hitCurr, hitPrev;
        if (!rayPlaneIntersect(camOrigin, screenRay(e.x,    e.y,    cachedVp), center, axisVec, hitCurr) ||
            !rayPlaneIntersect(camOrigin, screenRay(lastMX, lastMY, cachedVp), center, axisVec, hitPrev))
        { lastMX = e.x; lastMY = e.y; return true; }

        // Signed angle from hitPrev to hitCurr around axisVec.
        Vec3 d1 = vec3Sub(hitPrev, center);
        Vec3 d2 = vec3Sub(hitCurr, center);
        float l1 = sqrt(d1.x*d1.x + d1.y*d1.y + d1.z*d1.z);
        float l2 = sqrt(d2.x*d2.x + d2.y*d2.y + d2.z*d2.z);
        if (l1 < 1e-6f || l2 < 1e-6f) { lastMX = e.x; lastMY = e.y; return true; }
        d1 = Vec3(d1.x/l1, d1.y/l1, d1.z/l1);
        d2 = Vec3(d2.x/l2, d2.y/l2, d2.z/l2);
        Vec3  cr    = cross(d1, d2);
        float angle = atan2(dot(cr, axisVec), dot(d1, d2));
        totalAngle += angle;

        // Collect vertices to rotate.
        bool[] toRotate = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toRotate[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toRotate[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toRotate[edge[0]] = true; toRotate[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toRotate[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toRotate[vi] = true;
        }

        // Rodrigues rotation around axisVec through center.
        import std.math : cos, sin;
        float c = cos(angle), s = sin(angle);
        Vec3  pivot = center;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toRotate[i]) continue;
            Vec3 p = vec3Sub(mesh.vertices[i], pivot);
            float d = p.x*axisVec.x + p.y*axisVec.y + p.z*axisVec.z;
            Vec3  pcr = cross(axisVec, p);
            mesh.vertices[i] = vec3Add(pivot, Vec3(
                p.x*c + pcr.x*s + axisVec.x*d*(1.0f - c),
                p.y*c + pcr.y*s + axisVec.y*d*(1.0f - c),
                p.z*c + pcr.z*s + axisVec.z*d*(1.0f - c),
            ));
        }

        gpu.upload(*mesh);
        update();

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

private:
    void drawRotationSector(const ref Viewport vp) {
        import std.math : cos, sin, sqrt, abs, PI;

        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                                     : Vec3(0,0,1);
        Vec3 center = handler.center;

        float cx, cy, cndcZ;
        if (!projectToWindowFull(center, vp, cx, cy, cndcZ)) return;

        // Color keyed to axis
        uint fillCol = dragAxis == 0 ? IM_COL32(220, 60,  60,  50)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60,  50)
                                     : IM_COL32( 60,  60, 220,  50);
        uint lineCol = dragAxis == 0 ? IM_COL32(220, 60,  60, 200)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60, 200)
                                     : IM_COL32( 60,  60, 220, 200);

        // Rodrigues rotation of p around axisVec by angle a
        Vec3 rodrig(Vec3 p, float a) {
            float rc = cos(a), rs = sin(a);
            float rd = p.x*axisVec.x + p.y*axisVec.y + p.z*axisVec.z;
            Vec3 rcr = cross(axisVec, p);
            return Vec3(p.x*rc + rcr.x*rs + axisVec.x*rd*(1-rc),
                        p.y*rc + rcr.y*rs + axisVec.y*rd*(1-rc),
                        p.z*rc + rcr.z*rs + axisVec.z*rd*(1-rc));
        }

        ImDrawList* dl = ImGui.GetForegroundDrawList();

        // Filled sector as a single polygon (no internal edges / anti-alias seams).
        // Always go from smaller angle to larger for consistent screen-space winding.
        float aFrom = totalAngle < 0 ? totalAngle : 0.0f;
        float aTo   = totalAngle > 0 ? totalAngle : 0.0f;
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

        // Arc outline via Path API
        for (int i = 0; i <= N; i++) {
            float a = totalAngle * i / N;
            Vec3 w = vec3Add(center, vec3Scale(rodrig(dragStartDir, a), cachedSize));
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { dl.PathClear(); break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        dl.PathStroke(lineCol, ImDrawFlags.None, 1.0f);

        // 2 radius lines: center → start, center → end
        float ssx, ssy, sex, sey, ndcZ;
        Vec3 startWorld = vec3Add(center, vec3Scale(dragStartDir, cachedSize));
        Vec3 endWorld   = vec3Add(center, vec3Scale(rodrig(dragStartDir, totalAngle), cachedSize));
        if (projectToWindowFull(startWorld, vp, ssx, ssy, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(ssx, ssy), lineCol, 1.0f);
        if (projectToWindowFull(endWorld,   vp, sex, sey, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(sex, sey), lineCol, 1.0f);

        // Angle label
        import std.format : format;
        float deg = totalAngle * 180.0f / PI;
        string label = format("%.1f°", deg);
        dl.AddText(ImVec2(cx + 8, cy - 20), IM_COL32(255, 255, 255, 220), label);
    }

    int hitTestAxes(int mx, int my) {
        SemicircleHandler[3] arcs = [handler.arcX, handler.arcY, handler.arcZ];
        foreach (i, arc; arcs)
            if (arc.hitTest(mx, my, cachedVp))
                return cast(int)i;
        return -1;
    }
}

