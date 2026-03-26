module tool;

import bindbc.sdl;
import bindbc.opengl;

import mesh;
import handler;
import editmode;
import math;
import std.math;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// MoveTool : Tool — shows MoveHandler at selection/mesh center
// ---------------------------------------------------------------------------

class MoveTool : Tool {
    MoveHandler handler;
    bool        active;

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
    bool     centerManual;   // true = update() must not recompute handler.center

public:
    this(Mesh* mesh, bool[]* selected, bool[]* selectedEdges, bool[]* selectedFaces,
         GpuMesh* gpu, EditMode* editMode) {
        this.mesh          = mesh;
        this.selected      = selected;
        this.selectedEdges = selectedEdges;
        this.selectedFaces = selectedFaces;
        this.gpu           = gpu;
        this.editMode      = editMode;
        handler = new MoveHandler(Vec3(0, 0, 0));
    }

    void destroy() { handler.destroy(); }

    override string name() const { return "Move"; }
    override void activate()   { active = true;              }
    override void deactivate() { active = false; dragAxis = -1; centerManual = false; }

    // Recompute gizmo center from current selection / mesh state.
    override void update() {
        if (!active || centerManual) return;
        Vec3 sum   = Vec3(0, 0, 0);
        int  count = 0;
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; *selected) if (s) { anySelected = true; break; }
            foreach (i, v; mesh.vertices) {
                if (!anySelected || (i < (*selected).length && (*selected)[i])) {
                    sum = vec3Add(sum, v);
                    count++;
                }
            }
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; *selectedEdges) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, edge; mesh.edges) {
                if (anySelected && !(i < (*selectedEdges).length && (*selectedEdges)[i]))
                    continue;
                foreach (vi; edge) {
                    if (!visited[vi]) {
                        sum = vec3Add(sum, mesh.vertices[vi]);
                        count++;
                        visited[vi] = true;
                    }
                }
            }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; *selectedFaces) if (s) { anySelected = true; break; }
            bool[] visited = new bool[](mesh.vertices.length);
            foreach (i, face; mesh.faces) {
                if (anySelected && !(i < (*selectedFaces).length && (*selectedFaces)[i]))
                    continue;
                foreach (vi; face) {
                    if (!visited[vi]) {
                        sum = vec3Add(sum, mesh.vertices[vi]);
                        count++;
                        visited[vi] = true;
                    }
                }
            }
        }
        handler.setPosition(count > 0
            ? Vec3(sum.x / count, sum.y / count, sum.z / count)
            : Vec3(0, 0, 0));
    }

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // During drag: keep active handler yellow, block hover on others.
        // Indices: 0=arrowX 1=arrowY 2=arrowZ 3=centerBox 4=circleXY 5=circleYZ 6=circleXZ
        Handler[7] handlers = [
            handler.arrowX, handler.arrowY, handler.arrowZ, handler.centerBox,
            handler.circleXY, handler.circleYZ, handler.circleXZ,
        ];
        bool isHovered = false;
        foreach (i, h; handlers) {
            bool isActive = (dragAxis == cast(int)i);
            h.setForceHovered(isActive);
            h.setHoverBlocked(dragAxis >= 0 && !isActive || isHovered);
            isHovered |= h.isHovered();
        }

        handler.draw(program, locColor, vp);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;
        dragAxis = -1;
        return true;
    }

    // Returns 0/1/2=axis  3=most-facing plane  4/5/6=XY/YZ/XZ plane  -1=miss
    private int hitTestAxes(int mx, int my) {
        // Circles checked first (larger hit area, drawn behind arrows)
        if (handler.circleXY.hitTest(mx, my, cachedVp)) return 4;
        if (handler.circleYZ.hitTest(mx, my, cachedVp)) return 5;
        if (handler.circleXZ.hitTest(mx, my, cachedVp)) return 6;

        if (handler.centerBox.hitTest(mx, my, cachedVp)) return 3;

        Arrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
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

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        // Don't interfere with pan/rotate/zoom modifier combos.
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) return false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // Click outside gizmo: teleport to most-facing plane at click point.
        import std.math : abs;
        const ref float[16] v = cachedVp.view;
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
        dragAxis = 3;
        lastMX = e.x; lastMY = e.y;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        Vec3 center = handler.center;
        Vec3 worldDelta = Vec3(0, 0, 0);

        if (dragAxis <= 2) {
            // ---- Single-axis drag ----
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
            float d = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
            worldDelta = vec3Scale(axis, d);
        } else {
            // ---- Plane drag: ray-plane intersection ----
            // dragAxis 3 = most-facing plane; 4=XY(Z) 5=YZ(X) 6=XZ(Y)
            Vec3 n;
            if      (dragAxis == 4) n = Vec3(0,0,1);
            else if (dragAxis == 5) n = Vec3(1,0,0);
            else if (dragAxis == 6) n = Vec3(0,1,0);
            else {
                import std.math : abs;
                const ref float[16] v2 = cachedVp.view;
                float avx = abs(v2[2]), avy = abs(v2[6]), avz = abs(v2[10]);
                n = avx >= avy && avx >= avz ? Vec3(1,0,0)
                  : avy >= avx && avy >= avz ? Vec3(0,1,0)
                                            : Vec3(0,0,1);
            }
            const ref float[16] v = cachedVp.view;
            Vec3 camOrigin = Vec3(
                -(v[0]*v[12] + v[1]*v[13] + v[2]*v[14]),
                -(v[4]*v[12] + v[5]*v[13] + v[6]*v[14]),
                -(v[8]*v[12] + v[9]*v[13] + v[10]*v[14]),
            );
            Vec3 hitCurr, hitPrev;
            if (!rayPlaneIntersect(camOrigin, screenRay(e.x,    e.y,    cachedVp), center, n, hitCurr) ||
                !rayPlaneIntersect(camOrigin, screenRay(lastMX, lastMY, cachedVp), center, n, hitPrev))
            { lastMX = e.x; lastMY = e.y; return true; }
            worldDelta = vec3Sub(hitCurr, hitPrev);
        }

        applyDelta(worldDelta);
        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Move             W");
        if (active)
            ImGui.PopStyleColor();
        return clicked;
    }

private:
    void applyDelta(Vec3 delta) {
        bool[] toMove = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toMove[i] = !any || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (!any) { toMove[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toMove[edge[0]] = true; toMove[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (!any) { toMove[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toMove[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toMove[i]) continue;
            mesh.vertices[i].x += delta.x;
            mesh.vertices[i].y += delta.y;
            mesh.vertices[i].z += delta.z;
        }
        gpu.upload(*mesh);
        if (centerManual)
            handler.setPosition(vec3Add(handler.center, delta));
        else
            update();
    }
}

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
    override void activate()   { active = true;               }
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

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
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
        handler.draw(program, locColor, vp);
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

        // Collect vertices to scale
        bool[] toScale = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; *selected) if (s) { anySelected = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toScale[i] = !anySelected || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; *selectedEdges) if (s) { anySelected = true; break; }
            if (!anySelected) { toScale[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i]) {
                    toScale[edge[0]] = true; toScale[edge[1]] = true;
                }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; *selectedFaces) if (s) { anySelected = true; break; }
            if (!anySelected) { toScale[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toScale[vi] = true;
        }

        // Scale each vertex along the axis relative to the gizmo center
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toScale[i]) continue;
            mesh.vertices[i].x += axis.x * (mesh.vertices[i].x - center.x) * (scaleFactor - 1.0f);
            mesh.vertices[i].y += axis.y * (mesh.vertices[i].y - center.y) * (scaleFactor - 1.0f);
            mesh.vertices[i].z += axis.z * (mesh.vertices[i].z - center.z) * (scaleFactor - 1.0f);
        }

        gpu.upload(*mesh);
        update();

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

private:
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

    override void draw(GLuint program, GLint locColor, const ref Viewport vp)
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

        handler.draw(program, locColor, vp);
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

// ---------------------------------------------------------------------------
// Tool — base class for all editing tools
// ---------------------------------------------------------------------------

class Tool {
    // Human-readable name shown in the UI.
    string name() const { return "Tool"; }

    // Called when the tool becomes the active tool.
    void activate() {}

    // Called when another tool becomes active.
    void deactivate() {}

    // Called once per frame to recompute tool state (e.g. gizmo position).
    void update() {}

    // SDL event handlers.
    // Return true to mark the event as consumed (stops further processing).
    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseButtonUp  (ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseMotion    (ref const SDL_MouseMotionEvent  e) { return false; }
    bool onKeyDown        (ref const SDL_KeyboardEvent     e) { return false; }
    bool onKeyUp          (ref const SDL_KeyboardEvent     e) { return false; }

    // Called once per frame after the 3-D geometry has been drawn.
    // Override to render tool-specific overlays (gizmos, highlights, etc.).
    void draw(GLuint program, GLint locColor, const ref Viewport vp) {}

    // Called once per frame inside the ImGui window to append tool UI.
    // Returns true if the user clicked the activation button.
    bool drawImGui() { return false; }
}

// ---------------------------------------------------------------------------
// Ray helpers used by plane drag
// ---------------------------------------------------------------------------

// World-space ray direction through screen pixel (sx, sy).
// Uses the view+proj stored in vp; accounts for viewport offset.
private Vec3 screenRay(float sx, float sy, const ref Viewport vp)
{
    import std.math : sqrt;
    // NDC, Y-up
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;

    // View-space direction: invert perspective projection.
    // proj[0] = f/aspect, proj[5] = f  (diagonal of perspective matrix, row/col 0 and 1).
    // Using M[row][col] = m[row + col*4]: proj[0]=m[0], proj[5]=m[5].
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    // vz = -1 (camera looks along -Z in view space)

    // Rotate to world space: world = R^T * view_dir,
    // where R rows are view[0,4,8], view[1,5,9], view[2,6,10]  (M[row][col]=m[row+col*4]).
    // R^T col j = R row j, so world.x = R col0 · view_dir = view[0]*vx + view[1]*vy + view[2]*(-1)
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(
        v[0]*vx + v[1]*vy + v[2]*(-1.0f),
        v[4]*vx + v[5]*vy + v[6]*(-1.0f),
        v[8]*vx + v[9]*vy + v[10]*(-1.0f),
    );
    float len = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    return len > 1e-9f ? Vec3(d.x/len, d.y/len, d.z/len) : Vec3(0,0,-1);
}

// Intersect ray (origin + t*dir) with plane (point on plane + normal).
// Returns false when ray is parallel to the plane.
private bool rayPlaneIntersect(Vec3 origin, Vec3 dir, Vec3 planePoint, Vec3 n,
                               out Vec3 hit)
{
    import std.math : abs;
    float denom = n.x*dir.x + n.y*dir.y + n.z*dir.z;
    if (abs(denom) < 1e-6f) return false;
    Vec3 d = vec3Sub(planePoint, origin);
    float t = (n.x*d.x + n.y*d.y + n.z*d.z) / denom;
    hit = Vec3(origin.x + t*dir.x, origin.y + t*dir.y, origin.z + t*dir.z);
    return true;
}