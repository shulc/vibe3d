module tool;

import bindbc.sdl;
import bindbc.opengl;

import mesh;
import handler;
import editmode;
import math;

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

    int       dragAxis = -1;   // 0=X 1=Y 2=Z  -1=none
    int       lastMX, lastMY;
    float[16] cachedView;
    float[16] cachedProj;
    int       cachedWinW, cachedWinH;

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

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
    {
        if (!active) return;
        cachedView = view;
        cachedProj = proj;
        cachedWinW = winW;
        cachedWinH = winH;

        // During drag: keep active arrow yellow, block hover on the other two.
        Arrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        bool isHovered = false;
        foreach (i, arrow; arrows) {
            bool isActive = (dragAxis == cast(int)i);
            arrow.setForceHovered(isActive);
            arrow.setHoverBlocked(dragAxis >= 0 && !isActive || isHovered);
            isHovered |= arrow.isHovered();
        }

        handler.draw(program, locColor, view, proj, winW, winH);
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

    // Returns 0/1/2 for X/Y/Z if (mx,my) is within 8 px of that arrow, else -1.
    private int hitTestAxes(int mx, int my) {
        Arrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedView, cachedProj,
                                     cachedWinW, cachedWinH, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedView, cachedProj,
                                     cachedWinW, cachedWinH, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        // Axis direction in world space
        Vec3 axis = dragAxis == 0 ? Vec3(1,0,0)
                  : dragAxis == 1 ? Vec3(0,1,0)
                                  : Vec3(0,0,1);

        // Project center and center+axis to screen to get pixels-per-world-unit
        Vec3  center = handler.center;
        float cx, cy, cndcZ, ax_, ay_, andcZ;
        if (!projectToWindowFull(center, cachedView, cachedProj,
                                 cachedWinW, cachedWinH, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(vec3Add(center, axis), cachedView, cachedProj,
                                 cachedWinW, cachedWinH, ax_, ay_, andcZ))
        { lastMX = e.x; lastMY = e.y; return true; }

        float sdx   = ax_ - cx;
        float sdy   = ay_ - cy;
        float slen2 = sdx*sdx + sdy*sdy;
        if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

        // Project mouse delta onto screen-space axis → world delta
        float worldDelta = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;

        // Determine which vertices to move based on edit mode + selection.
        bool[] toMove = new bool[](mesh.vertices.length);
        if (*editMode == EditMode.Vertices) {
            bool anySelected = false;
            foreach (s; *selected) if (s) { anySelected = true; break; }
            foreach (i; 0 .. mesh.vertices.length)
                toMove[i] = !anySelected || (i < (*selected).length && (*selected)[i]);
        } else if (*editMode == EditMode.Edges) {
            bool anySelected = false;
            foreach (s; *selectedEdges) if (s) { anySelected = true; break; }
            if (!anySelected) {
                toMove[] = true;
            } else {
                foreach (i, edge; mesh.edges) {
                    if (i < (*selectedEdges).length && (*selectedEdges)[i]) {
                        toMove[edge[0]] = true;
                        toMove[edge[1]] = true;
                    }
                }
            }
        } else if (*editMode == EditMode.Polygons) {
            bool anySelected = false;
            foreach (s; *selectedFaces) if (s) { anySelected = true; break; }
            if (!anySelected) {
                toMove[] = true;
            } else {
                foreach (i, face; mesh.faces) {
                    if (i < (*selectedFaces).length && (*selectedFaces)[i]) {
                        foreach (vi; face) toMove[vi] = true;
                    }
                }
            }
        }
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toMove[i]) continue;
            mesh.vertices[i].x += axis.x * worldDelta;
            mesh.vertices[i].y += axis.y * worldDelta;
            mesh.vertices[i].z += axis.z * worldDelta;
        }

        gpu.upload(*mesh);
        update();   // recompute gizmo center

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override bool drawImGui() {
        if (active)
            ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
        bool clicked = ImGui.Button("Move [W]");
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

    int       dragAxis = -1;
    int       lastMX, lastMY;
    float[16] cachedView;
    float[16] cachedProj;
    int       cachedWinW, cachedWinH;

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

    override void draw(GLuint program, GLint locColor,
                       const ref float[16] view, const ref float[16] proj,
                       int winW, int winH)
    {
        if (!active) return;
        cachedView = view; cachedProj = proj;
        cachedWinW = winW; cachedWinH = winH;

        CubicArrow[3] arrows = [handler.arrowX, handler.arrowY, handler.arrowZ];
        bool anyHovered = false;
        foreach (i, arrow; arrows) {
            bool isActive = (dragAxis == cast(int)i);
            arrow.setForceHovered(isActive);
            arrow.setHoverBlocked(dragAxis >= 0 && !isActive || anyHovered);
            anyHovered |= arrow.isHovered();
        }
        handler.draw(program, locColor, view, proj, winW, winH);
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
        if (!projectToWindowFull(center, cachedView, cachedProj,
                                 cachedWinW, cachedWinH, cx, cy, cndcZ))
        { lastMX = e.x; lastMY = e.y; return true; }
        if (!projectToWindowFull(vec3Add(center, axis), cachedView, cachedProj,
                                 cachedWinW, cachedWinH, ax_, ay_, andcZ))
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
        bool clicked = ImGui.Button("Scale [R]");
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
            if (!projectToWindowFull(arrow.start, cachedView, cachedProj,
                                     cachedWinW, cachedWinH, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedView, cachedProj,
                                     cachedWinW, cachedWinH, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
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
    void draw(GLuint program, GLint locColor,
              const ref float[16] view, const ref float[16] proj,
              int winW, int winH) {}

    // Called once per frame inside the ImGui window to append tool UI.
    // Returns true if the user clicked the activation button.
    bool drawImGui() { return false; }
}