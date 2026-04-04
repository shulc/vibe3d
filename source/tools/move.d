module tools.move;

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

import std.math;

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
    bool     ctrlConstrain;        // Ctrl: axis TBD from initial movement (only for dragAxis==3)
    int      constrainStartMX, constrainStartMY;
    bool[]   toMove;         // Cache for vertices to move (avoid repeated allocation)
    bool[]*  vertexCacheValid;  // Pointer to vertexCache.valid
    bool[]*  edgeCacheValid;    // Pointer to edgeCache.valid
    bool[]*  faceCacheValid;    // Pointer to faceCache.valid
    bool     needsGpuUpdate;  // Flag to delay GPU upload until drag ends
    int[]    vertexIndicesToMove;  // Cached indices of vertices to move (avoid repeated lookup)
    int      vertexMoveCount;      // Cached count to avoid re-iterating toMove

public:
    // When the whole mesh moves (no selection), we accumulate the delta here and
    // apply it as a GPU-side translation uniform instead of re-uploading vertex data.
    // Caller (app.d) reads this every frame and sets u_model accordingly.
    // Reset to zero after final GPU upload on mouseUp.
    Vec3 gpuOffset;
    bool     vertexMoveCacheDirty;  // Flag to rebuild vertex cache when selection changes
    bool     centerCacheDirty;    // Flag to recompute gizmo center
    Vec3     cachedCenter;        // Cached gizmo center for performance
    int      lastSelectionHash;   // Hash to detect selection changes

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
        toMove.length = mesh.vertices.length;
        toMove[] = false;
        vertexCacheValid = null;
        edgeCacheValid = null;
        faceCacheValid = null;
        vertexMoveCacheDirty = true;
        vertexIndicesToMove = null;
        vertexMoveCount = 0;
        centerCacheDirty = true;
        cachedCenter = Vec3(0, 0, 0);
        lastSelectionHash = 0;
    }

    void destroy() {
        handler.destroy();
        toMove.length = 0;  // Clear cached array
    }

    // Set pointers to cache validity arrays for invalidation
    void setCachePointers(bool[]* vertexValid, bool[]* edgeValid, bool[]* faceValid) {
        vertexCacheValid = vertexValid;
        edgeCacheValid = edgeValid;
        faceCacheValid = faceValid;
    }

    override string name() const { return "Move"; }
    override void activate()   {
        active = true;
        needsGpuUpdate = false;
        vertexMoveCacheDirty = true;
        centerCacheDirty = true;
        lastSelectionHash = 0;
        gpuOffset = Vec3(0, 0, 0);
    }
    override void deactivate() {
        active = false;
        if (needsGpuUpdate || gpuOffset.x != 0 || gpuOffset.y != 0 || gpuOffset.z != 0) {
            gpu.upload(*mesh);
            needsGpuUpdate = false;
            gpuOffset = Vec3(0, 0, 0);
        }
        dragAxis = -1;
        centerManual = false;
    }

    // Simple hash of selection state
    uint computeSelectionHash() {
        uint hash = cast(uint)(*editMode);
        if (*editMode == EditMode.Vertices) {
            foreach (i, s; *selected) {
                if (s) hash = hash * 31 + cast(uint)i;
            }
        } else if (*editMode == EditMode.Edges) {
            foreach (i, s; *selectedEdges) {
                if (s) hash = hash * 31 + cast(uint)i;
            }
        } else if (*editMode == EditMode.Polygons) {
            foreach (i, s; *selectedFaces) {
                if (s) hash = hash * 31 + cast(uint)i;
            }
        }
        return hash;
    }

    // Recompute gizmo center from current selection / mesh state (with caching)
    override void update() {
        if (!active) return;

        // Skip hash computation entirely during drag — selection cannot change
        if (dragAxis >= 0) return;

        // Recalculate center when selection changes only (not during drag)
        uint currentHash = computeSelectionHash();
        if (currentHash != lastSelectionHash) {
            lastSelectionHash = currentHash;

            // Recompute center from mesh vertices
            Vec3 sum = Vec3(0, 0, 0);
            int count = 0;

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

            cachedCenter = count > 0 ? Vec3(sum.x / count, sum.y / count, sum.z / count) : Vec3(0, 0, 0);
        }

        // Only update centerPosition if not manually set and not dragging
        if (!centerManual && dragAxis == -1) {
            handler.setPosition(cachedCenter);
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Flush pending GPU upload once per frame (partial selection during drag).
        if (needsGpuUpdate) {
            flushPendingGpuUpdates();
            needsGpuUpdate = false;
        }

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

        handler.draw(shader, vp);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragAxis == -1) return false;

        ctrlConstrain = false;

        // Commit GPU offset (whole-mesh) or flush partial selection — one final upload.
        if (vertexMoveCount > 0) {
            gpu.upload(*mesh);
            gpuOffset = Vec3(0, 0, 0);  // model matrix returns to identity
        }

        dragAxis = -1;
        // Sync cachedCenter to the actual post-move gizmo position so update()
        // does not snap it back to the pre-move centroid on the next frame.
        cachedCenter = handler.center;
        lastSelectionHash = computeSelectionHash();
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
        bool ctrl = (mods & KMOD_CTRL) != 0;
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        ctrlConstrain = false;
        dragAxis = hitTestAxes(e.x, e.y);
        if (dragAxis >= 0) {
            // Ctrl constraint applies only to the most-facing plane (dragAxis==3)
            if (ctrl && dragAxis == 3) {
                ctrlConstrain = true;
                constrainStartMX = e.x; constrainStartMY = e.y;
            }
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
        if (ctrl) {
            ctrlConstrain = true;
            constrainStartMX = e.x; constrainStartMY = e.y;
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragAxis == -1) return false;

        // Ctrl-constrain: wait for initial movement to determine which of the two
        // in-plane axes to lock to, then switch dragAxis to that axis (0/1/2).
        if (ctrlConstrain) {
            int tdx = e.x - constrainStartMX;
            int tdy = e.y - constrainStartMY;
            if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }

            // Identify the two axes that lie in the most-facing plane.
            import std.math : abs;
            const ref float[16] vv = cachedVp.view;
            float avx = abs(vv[2]), avy = abs(vv[6]), avz = abs(vv[10]);
            int ax1, ax2;
            if      (avx >= avy && avx >= avz) { ax1 = 1; ax2 = 2; } // normal X → Y,Z
            else if (avy >= avx && avy >= avz) { ax1 = 0; ax2 = 2; } // normal Y → X,Z
            else                               { ax1 = 0; ax2 = 1; } // normal Z → X,Y

            // Project each candidate axis onto screen; pick best alignment.
            float cx, cy, dummy;
            float dmag = sqrt(cast(float)(tdx*tdx + tdy*tdy));
            float ndx = tdx / dmag, ndy = tdy / dmag;
            Vec3[3] axisEnds = [handler.arrowX.end, handler.arrowY.end, handler.arrowZ.end];
            dragAxis = ax1; // fallback
            if (projectToWindowFull(handler.center, cachedVp, cx, cy, dummy)) {
                float bestDot = -1.0f;
                foreach (a; [ax1, ax2]) {
                    float ax, ay, andcZ;
                    if (!projectToWindowFull(axisEnds[a], cachedVp, ax, ay, andcZ)) continue;
                    float sdx = ax - cx, sdy = ay - cy;
                    float slen = sqrt(sdx*sdx + sdy*sdy);
                    if (slen < 1.0f) continue;
                    float dot = abs(ndx * sdx/slen + ndy * sdy/slen);
                    if (dot > bestDot) { bestDot = dot; dragAxis = a; }
                }
            }
            ctrlConstrain = false;
            lastMX = e.x; lastMY = e.y;
            return true; // axis locked — movement starts on the next motion event
        }

        Vec3 center = handler.center;
        Vec3 worldDelta = Vec3(0, 0, 0);

        if (dragAxis <= 2) {
            // ---- Single-axis drag ----
            Vec3 axis = dragAxis == 0 ? Vec3(1,0,0)
                      : dragAxis == 1 ? Vec3(0,1,0)
                                      : Vec3(0,0,1);
            // Use the actual arrow end (scaled to gizmo size) instead of a unit
            // world vector — a unit offset can fall behind the camera when dist < 1.
            Vec3 axisEnd = dragAxis == 0 ? handler.arrowX.end
                         : dragAxis == 1 ? handler.arrowY.end
                                         : handler.arrowZ.end;
            float cx, cy, cndcZ, ax_, ay_, andcZ;
            if (!projectToWindowFull(center, cachedVp, cx, cy, cndcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            if (!projectToWindowFull(axisEnd, cachedVp, ax_, ay_, andcZ))
            { lastMX = e.x; lastMY = e.y; return true; }
            float sdx = ax_ - cx, sdy = ay_ - cy;
            float slen2 = sdx*sdx + sdy*sdy;
            if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }
            // d is in units of |axisEnd - center| (= gizmo size), convert to world units.
            Vec3 ae = vec3Sub(axisEnd, center);
            float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
            if (axisLen < 1e-9f) { lastMX = e.x; lastMY = e.y; return true; }
            float d = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2 * axisLen;
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

        // Update gizmo position immediately (always fast)
        handler.setPosition(vec3Add(handler.center, worldDelta));

        // Apply delta to CPU vertices (fast: simple float additions, no GPU work)
        applyDeltaWorldOnly(worldDelta);

        if (vertexMoveCount == cast(int)mesh.vertices.length) {
            // Whole-mesh move: accumulate GPU offset so app.d can set u_model as a
            // translation matrix. Zero GPU uploads during drag — only one on mouseUp.
            gpuOffset = vec3Add(gpuOffset, worldDelta);
        } else {
            // Partial selection: defer GPU upload to draw() — once per frame.
            needsGpuUpdate = true;
        }

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
        // Resize cache if needed
        if (toMove.length != mesh.vertices.length) {
            toMove.length = mesh.vertices.length;
        }

        // Clear the toMove array before using it
        toMove[] = false;

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

        // Apply delta to vertices
        foreach (i; 0 .. mesh.vertices.length) {
            if (!toMove[i]) continue;
            mesh.vertices[i].x += delta.x;
            mesh.vertices[i].y += delta.y;
            mesh.vertices[i].z += delta.z;
        }

        // Update GPU immediately
        updateGpuForSelection();
    }

    // Apply only to memory (no GPU update) - called during drag for smooth gizmo
    void applyDeltaWorldOnly(Vec3 delta) {
        buildVertexCacheIfNeeded();
        applyDeltaImmediate(delta);
    }

    // Build cache of vertex indices to move (expensive, do once per selection change)
    void buildVertexCacheIfNeeded() {
        if (!vertexMoveCacheDirty && vertexIndicesToMove !is null) return;

        // Create or clear the indices array
        int[] indices;
        indices.length = 0;

        if (*editMode == EditMode.Vertices) {
            bool any = false;
            foreach (s; *selected) if (s) { any = true; break; }
            if (any) {
                foreach (i, s; *selected) {
                    if (s && i < mesh.vertices.length) indices ~= cast(int)i;
                }
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        } else if (*editMode == EditMode.Edges) {
            bool any = false;
            foreach (s; *selectedEdges) if (s) { any = true; break; }
            if (any) {
                bool[] added = new bool[](mesh.vertices.length);
                foreach (i, edge; mesh.edges) {
                    if (i < (*selectedEdges).length && (*selectedEdges)[i]) {
                        if (!added[edge[0]]) {
                            added[edge[0]] = true;
                            indices ~= cast(int)edge[0];
                        }
                        if (!added[edge[1]]) {
                            added[edge[1]] = true;
                            indices ~= cast(int)edge[1];
                        }
                    }
                }
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        } else if (*editMode == EditMode.Polygons) {
            bool any = false;
            foreach (s; *selectedFaces) if (s) { any = true; break; }
            if (any) {
                bool[] added = new bool[](mesh.vertices.length);
                foreach (i, face; mesh.faces) {
                    if (i < (*selectedFaces).length && (*selectedFaces)[i]) {
                        foreach (vi; face) {
                            if (!added[vi]) {
                                added[vi] = true;
                                indices ~= cast(int)vi;
                            }
                        }
                    }
                }
            } else {
                foreach (i; 0 .. mesh.vertices.length) indices ~= cast(int)i;
            }
        }

        vertexIndicesToMove.length = cast(int)indices.length;
        foreach (i, idx; indices) vertexIndicesToMove[i] = idx;
        vertexMoveCount = cast(int)indices.length;
        vertexMoveCacheDirty = false;

        // Update toMove array for GPU functions
        // Ensure toMove is large enough
        if (toMove.length != mesh.vertices.length) {
            toMove.length = mesh.vertices.length;
        }
        toMove[] = false;
        foreach (vi; vertexIndicesToMove) {
            if (vi < cast(int)mesh.vertices.length) toMove[vi] = true;
        }
    }

    // Apply delta immediately to cached vertices (very fast)
    void applyDeltaImmediate(Vec3 delta) {
        foreach (vi; vertexIndicesToMove) {
            if (vi < mesh.vertices.length) {
                mesh.vertices[vi].x += delta.x;
                mesh.vertices[vi].y += delta.y;
                mesh.vertices[vi].z += delta.z;
            }
        }
    }

    // Update GPU for current selection (throttled during drag)
    void updateGpuForSelection() {
        if (vertexMoveCount <= 0) return;
        if (vertexMoveCount < mesh.vertices.length * 0.7) {
            gpu.uploadSelectedVertices(*mesh, toMove);
        } else {
            gpu.upload(*mesh);
        }
    }

    // Flush pending GPU updates (called at throttled intervals)
    void flushPendingGpuUpdates() {
        if (vertexMoveCount <= 0) return;
        if (vertexMoveCount < mesh.vertices.length * 0.8) {
            gpu.uploadSelectedVertices(*mesh, toMove);
        } else {
            gpu.upload(*mesh);
        }
    }

    // Check if mesh was modified and caches need invalidation
    bool meshModified() {
        // Return true if any vertices were moved in last operation
        // Simple heuristic: if we had any vertices to move, mesh was modified
        return toMove.length > 0 && dragAxis >= 0;
    }

    // Function to invalidate all picking caches after mesh modification
    void invalidatePickingCaches() {
        // This will be called to invalidate the picking caches in app.d
        // For now, we'll signal that caches need invalidation
    }
}
