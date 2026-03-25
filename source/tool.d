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
    override void deactivate() { active = false; dragAxis = -1; }

    // Recompute gizmo center from current selection / mesh state.
    override void update() {
        if (!active) return;
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

        // During drag: keep active arrow yellow, block hover on the other two.
        Arrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        bool isHovered = false;
        foreach (i, arrow; arrows) {
            bool isActive = (dragAxis == cast(int)i);
            arrow.setForceHovered(isActive);
            arrow.setHoverBlocked(dragAxis >= 0 && !isActive || isHovered);
            isHovered |= arrow.isHovered();
        }
        // centerBox: force-hover when plane drag is active, block when axis drag is active.
        handler.centerBox.setForceHovered(dragAxis == 3);
        handler.centerBox.setHoverBlocked(dragAxis >= 0 && dragAxis != 3);

        handler.draw(program, locColor, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        // Fresh hit-test at the actual click position — do not rely on the
        // previous-frame hover state (click and hover-enter can arrive in the
        // same event-poll iteration, before draw() has a chance to update it).
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis < 0) return false;
        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;
        dragAxis = -1;
        return true;
    }

    // Returns 0/1/2 for X/Y/Z axis drag, 3 for plane drag, -1 for miss.
    private int hitTestAxes(int mx, int my) {
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
        if (handler.centerBox.hitTest(mx, my, cachedVp))
            return 3;
        return -1;
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
            // ---- Plane drag (dragAxis == 3): ray-plane intersection ----
            // Most-facing plane normal (same logic as gizmo.d)
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

            Vec3 hitCurr, hitPrev;
            if (!rayPlaneIntersect(camOrigin, screenRay(e.x,    e.y,    cachedVp), center, n, hitCurr) ||
                !rayPlaneIntersect(camOrigin, screenRay(lastMX, lastMY, cachedVp), center, n, hitPrev))
            { lastMX = e.x; lastMY = e.y; return true; }

            worldDelta = vec3Sub(hitCurr, hitPrev);
        }

        // Collect vertices to move.
        bool[] toMove = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; *selected) if (s) { anySelected = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toMove[i] = !anySelected || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; *selectedEdges) if (s) { anySelected = true; break; }
            if (!anySelected) { toMove[] = true; }
            else foreach (i, edge; mesh.edges)
                if (i < (*selectedEdges).length && (*selectedEdges)[i])
                    { toMove[edge[0]] = true; toMove[edge[1]] = true; }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; *selectedFaces) if (s) { anySelected = true; break; }
            if (!anySelected) { toMove[] = true; }
            else foreach (i, face; mesh.faces)
                if (i < (*selectedFaces).length && (*selectedFaces)[i])
                    foreach (vi; face) toMove[vi] = true;
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toMove[i]) continue;
            mesh.vertices[i].x += worldDelta.x;
            mesh.vertices[i].y += worldDelta.y;
            mesh.vertices[i].z += worldDelta.z;
        }

        gpu.upload(*mesh);
        update();

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

        Vec3 axisVec = dragAxis == 0 ? Vec3(1,0,0)
                     : dragAxis == 1 ? Vec3(0,1,0)
                                     : Vec3(0,0,1);

        // Build the arc's local frame (same formula as SemicircleHandler.draw).
        Vec3 tmp   = abs(axisVec.x) < 0.9f ? Vec3(1,0,0) : Vec3(0,1,0);
        Vec3 right = normalize(cross(axisVec, tmp));
        Vec3 up    = cross(right, axisVec);

        // Project the 'up' rim point to get screen radius and tangent direction.
        Vec3  center = handler.center;
        float cx, cy, cndcZ, rx, ry, rndcZ;
        if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        Vec3 rimPt = vec3Add(center, vec3Scale(up, cachedSize));
        if (!projectToWindowFull(rimPt, cachedVp, rx, ry, rndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float screen_r = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
        if (screen_r < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        // Tangent at the rim point: perpendicular to the screen-space radius.
        float tdx = -(ry - cy) / screen_r;
        float tdy =  (rx - cx) / screen_r;

        // Angle in radians = - arc-length / radius = dot(mouse_delta, tangent) / screen_r
        float angle = - ((e.x - lastMX) * tdx + (e.y - lastMY) * tdy) / screen_r;

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
            Vec3  cr = cross(axisVec, p);
            mesh.vertices[i] = vec3Add(pivot, Vec3(
                p.x*c + cr.x*s + axisVec.x*d*(1.0f - c),
                p.y*c + cr.y*s + axisVec.y*d*(1.0f - c),
                p.z*c + cr.z*s + axisVec.z*d*(1.0f - c),
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