module tools.move;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import handler;
import mesh;
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
