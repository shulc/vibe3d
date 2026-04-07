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

    int      dragAxis = -1;   // 0=X 1=Y 2=Z 3=View  -1=none
    bool     centerManual;    // true = update() must not recompute handler.center
    int      lastMX, lastMY;
    Viewport cachedVp;
    float    cachedSize;      // gizmo radius in world units (from last draw)
    Vec3     dragStartDir;    // direction from center to click point in arc plane
    float    totalAngle = 0;       // accumulated raw angle during drag (radians)
    float    lastSnappedAngle = 0; // last angle actually applied to mesh (snapped or == totalAngle)
    Vec3     viewDragAxis;    // camera forward captured at start of view-plane drag
    Vec3     angleAccum = Vec3(0, 0, 0);  // total rotation per axis since tool activated (radians)
    Vec3     propDeg = Vec3(0, 0, 0);     // persistent value shown in Tool Properties (degrees)
    Vec3[]   origVertices;                // snapshot of vertex positions at activate()

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
    override void activate()   {
        active = true;
        centerManual = false;
        angleAccum = Vec3(0, 0, 0);
        propDeg = Vec3(0, 0, 0);
        origVertices = mesh.vertices.dup;
    }
    override void deactivate() { active = false; dragAxis = -1; centerManual = false; }

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
        if (!centerManual)
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
        // View-plane ring: axis index 3
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
            // Reset origVertices and accumulated rotation so DragFloat stays valid.
            origVertices = mesh.vertices.dup;
            angleAccum = Vec3(0, 0, 0);
            propDeg    = Vec3(0, 0, 0);
            return true;
        }
        lastMX = e.x; lastMY = e.y;
        totalAngle = 0;
        lastSnappedAngle = 0;
        // Compute drag start direction: project click into the arc plane.
        Vec3 axisVec;
        if (dragAxis == 3) {
            // Camera forward vector captured at drag start
            viewDragAxis = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
            axisVec = viewDragAxis;
        } else {
            axisVec = dragAxis == 0 ? Vec3(1,0,0)
                    : dragAxis == 1 ? Vec3(0,1,0)
                                    : Vec3(0,0,1);
        }
        Vec3 hit;
        if (rayPlaneIntersect(viewCamOrigin(), screenRay(e.x, e.y, cachedVp),
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
        float finalAngle = (SDL_GetModState() & KMOD_CTRL) ? lastSnappedAngle : totalAngle;
        if (dragAxis == 0) angleAccum.x += finalAngle;
        else if (dragAxis == 1) angleAccum.y += finalAngle;
        else if (dragAxis == 2) angleAccum.z += finalAngle;
        else if (dragAxis == 3) {
            angleAccum.x += finalAngle * viewDragAxis.x;
            angleAccum.y += finalAngle * viewDragAxis.y;
            angleAccum.z += finalAngle * viewDragAxis.z;
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

        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                     : dragAxis == 2 ? Vec3(0,0,1)
                                     : viewDragAxis;

        Vec3 center = handler.center;

        // Cast rays for current and previous mouse positions into the arc plane.
        Vec3 camOrigin = viewCamOrigin();
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

        bool ctrlHeld = (SDL_GetModState() & KMOD_CTRL) != 0;
        if (ctrlHeld) {
            import std.math : round, PI;
            enum float step = PI / 12.0f; // 15°
            float newSnapped = round(totalAngle / step) * step;
            float delta = newSnapped - lastSnappedAngle;
            if (delta != 0.0f) {
                if (dragAxis == 3) applyRotationVec(viewDragAxis, delta);
                else               applyRotation(dragAxis, delta);
                lastSnappedAngle = newSnapped;
            }
        } else {
            if (dragAxis == 3) applyRotationVec(viewDragAxis, angle);
            else               applyRotation(dragAxis, angle);
            // Keep lastSnappedAngle in sync so pressing Ctrl mid-drag causes no jump.
            import std.math : round, PI;
            lastSnappedAngle = round(totalAngle / (PI / 12.0f)) * (PI / 12.0f);
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

        if (xActive || xDone || yActive || yDone || zActive || zDone) {
            angleAccum.x = propDeg.x * PI / 180.0f;
            angleAccum.y = propDeg.y * PI / 180.0f;
            angleAccum.z = propDeg.z * PI / 180.0f;
            applyAbsoluteFromOrig();
        }
    }

private:
    Vec3 viewCamOrigin() {
        const ref float[16] v = cachedVp.view;
        return Vec3(
            -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
            -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
            -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
        );
    }

    bool[] buildSelectionMask() {
        bool[] mask = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                mask[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { mask[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { mask[edge[0]] = true; mask[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { mask[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) mask[vi] = true;
        }
        return mask;
    }

    // Rodrigues rotation of a single point around pivot+axis
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

    // Apply X→Y→Z Euler rotation from origVertices (exact, no accumulated error)
    void applyAbsoluteFromOrig() {
        if (origVertices.length != mesh.vertices.length) return;
        Vec3 pivot = handler.center;
        bool[] toRotate = buildSelectionMask();
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toRotate[i]) { mesh.vertices[i] = origVertices[i]; continue; }
            Vec3 v = origVertices[i];
            if (angleAccum.x != 0) v = rotateVec(v, pivot, Vec3(1,0,0), angleAccum.x);
            if (angleAccum.y != 0) v = rotateVec(v, pivot, Vec3(0,1,0), angleAccum.y);
            if (angleAccum.z != 0) v = rotateVec(v, pivot, Vec3(0,0,1), angleAccum.z);
            mesh.vertices[i] = v;
        }
        gpu.upload(*mesh);
        update();
    }

    // Rotate around an arbitrary world-space axis (used for view-plane drag).
    void applyRotationVec(Vec3 axisVec, float angle) {
        import std.math : cos, sin;
        Vec3 pivot = handler.center;
        bool[] toRotate = buildSelectionMask();
        float c = cos(angle), s = sin(angle);
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toRotate[i]) continue;
            Vec3 p = vec3Sub(mesh.vertices[i], pivot);
            float dd = p.x*axisVec.x + p.y*axisVec.y + p.z*axisVec.z;
            Vec3 pcr = cross(axisVec, p);
            mesh.vertices[i] = vec3Add(pivot, Vec3(
                p.x*c + pcr.x*s + axisVec.x*dd*(1.0f - c),
                p.y*c + pcr.y*s + axisVec.y*dd*(1.0f - c),
                p.z*c + pcr.z*s + axisVec.z*dd*(1.0f - c),
            ));
        }
        gpu.upload(*mesh);
        update();
    }

    void applyRotation(int axisIdx, float angle) {
        applyRotationVec(axisIdx == 0 ? Vec3(1,0,0)
                       : axisIdx == 1 ? Vec3(0,1,0)
                                      : Vec3(0,0,1), angle);
    }

    void drawRotationSector(const ref Viewport vp) {
        import std.math : cos, sin, sqrt, abs, PI;

        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                     : dragAxis == 2 ? Vec3(0,0,1)
                                     : viewDragAxis;
        Vec3 center = handler.center;

        float cx, cy, cndcZ;
        if (!projectToWindowFull(center, vp, cx, cy, cndcZ)) return;

        // Color keyed to axis
        uint fillCol = dragAxis == 0 ? IM_COL32(220, 60,  60,  50)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60,  50)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220,  50)
                                     : IM_COL32(160, 160, 160,  50);
        uint lineCol = dragAxis == 0 ? IM_COL32(220, 60,  60, 200)
                     : dragAxis == 1 ? IM_COL32( 60, 220,  60, 200)
                     : dragAxis == 2 ? IM_COL32( 60,  60, 220, 200)
                                     : IM_COL32(180, 180, 180, 200);

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

        // Arc outline via Path API
        for (int i = 0; i <= N; i++) {
            float a = dispAngle * i / N;
            Vec3 w = vec3Add(center, vec3Scale(rodrig(dragStartDir, a), cachedSize));
            float sx, sy, ndcZ;
            if (!projectToWindowFull(w, vp, sx, sy, ndcZ)) { dl.PathClear(); break; }
            dl.PathLineTo(ImVec2(sx, sy));
        }
        dl.PathStroke(lineCol, ImDrawFlags.None, 1.0f);

        // 2 radius lines: center → start, center → end
        float ssx, ssy, sex, sey, ndcZ;
        Vec3 startWorld = vec3Add(center, vec3Scale(dragStartDir, cachedSize));
        Vec3 endWorld   = vec3Add(center, vec3Scale(rodrig(dragStartDir, dispAngle), cachedSize));
        if (projectToWindowFull(startWorld, vp, ssx, ssy, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(ssx, ssy), lineCol, 1.0f);
        if (projectToWindowFull(endWorld,   vp, sex, sey, ndcZ))
            dl.AddLine(ImVec2(cx, cy), ImVec2(sex, sey), lineCol, 1.0f);

        // Angle label
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
