module tools.move;

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

import std.math;
import drag;

// ---------------------------------------------------------------------------
// MoveTool : TransformTool — shows MoveHandler at selection/mesh center
// ---------------------------------------------------------------------------

class MoveTool : TransformTool {
    MoveHandler handler;

private:
    Vec3     dragDelta;       // accumulated world-space offset since drag start
    Vec3     propInput;       // value shown in Tool Properties (persisted for ImGui)
    bool     ctrlConstrain;        // Ctrl: axis TBD from initial movement (only for dragAxis==3)
    int      constrainStartMX, constrainStartMY;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
        handler = new MoveHandler(Vec3(0, 0, 0));
        cachedCenter = Vec3(0, 0, 0);
    }

    void destroy() {
        handler.destroy();
    }

    override string name() const { return "Move"; }

    override void activate() {
        super.activate();
        dragDelta = Vec3(0, 0, 0);
        propInput = Vec3(0, 0, 0);
    }

    // Recompute gizmo center from current selection / mesh state (with caching).
    override void update() {
        if (!active) return;

        // Skip hash computation entirely during drag — selection cannot change.
        if (dragAxis >= 0) return;

        uint currentHash = computeSelectionHash();
        if (currentHash != lastSelectionHash) {
            lastSelectionHash = currentHash;
            vertexCacheDirty = true;  // selection changed — rebuild on next drag

            if (*editMode == EditMode.Vertices)
                cachedCenter = mesh.selectionCentroidVertices();
            else if (*editMode == EditMode.Edges)
                cachedCenter = mesh.selectionCentroidEdges();
            else if (*editMode == EditMode.Polygons)
                cachedCenter = mesh.selectionCentroidFaces();
            else
                cachedCenter = Vec3(0, 0, 0);
            dragDelta = Vec3(0, 0, 0);
            propInput = Vec3(0, 0, 0);
        }

        if (!centerManual && dragAxis == -1)
            handler.setPosition(cachedCenter);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Flush pending GPU upload once per frame (partial selection during drag).
        if (needsGpuUpdate) {
            uploadToGpu();
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

        // Commit GPU (whole-mesh) or flush partial selection — one final upload.
        if (wholeMeshDrag || needsGpuUpdate) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            needsGpuUpdate = false;
        }
        wholeMeshDrag = false;
        dragAxis = -1;
        propInput = dragDelta;
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
            dragDelta = Vec3(0, 0, 0);
            buildVertexCacheIfNeeded();
            wholeMeshDrag = (vertexProcessCount == cast(int)mesh.vertices.length);
            return true;
        }

        // Click outside gizmo: teleport to most-facing plane at click point.
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
        dragAxis = 3;
        lastMX = e.x; lastMY = e.y;
        dragDelta = Vec3(0, 0, 0);
        buildVertexCacheIfNeeded();
        wholeMeshDrag = (vertexProcessCount == cast(int)mesh.vertices.length);
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

        Vec3 worldDelta;
        bool skip;
        if (dragAxis <= 2)
            worldDelta = axisDragDelta(e.x, e.y, lastMX, lastMY,
                                       dragAxis, handler, cachedVp, skip);
        else
            worldDelta = planeDragDelta(e.x, e.y, lastMX, lastMY,
                                        dragAxis, handler.center, cachedVp, skip);
        if (skip) { lastMX = e.x; lastMY = e.y; return true; }

        // Update gizmo position immediately (always fast)
        dragDelta = vec3Add(dragDelta, worldDelta);
        handler.setPosition(vec3Add(handler.center, worldDelta));

        // Apply delta to CPU vertices (fast: simple float additions, no GPU work)
        applyDelta(worldDelta);

        if (wholeMeshDrag) {
            // Whole-mesh move: update gpuMatrix so app.d sets u_model each frame.
            // Zero GPU uploads during drag — only one on mouseUp.
            gpuMatrix = translationMatrix(dragDelta);
        } else {
            // Partial selection: defer GPU upload to draw() — once per frame.
            needsGpuUpdate = true;
        }

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override void drawProperties() {
        if (dragAxis >= 0) propInput = dragDelta;

        ImGui.DragFloat("X", &propInput.x, 0.01f, 0, 0, "%.4f");
        bool xActive = ImGui.IsItemActive();
        bool xDone   = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Y", &propInput.y, 0.01f, 0, 0, "%.4f");
        bool yActive = ImGui.IsItemActive();
        bool yDone   = ImGui.IsItemDeactivatedAfterEdit();
        ImGui.DragFloat("Z", &propInput.z, 0.01f, 0, 0, "%.4f");
        bool zActive = ImGui.IsItemActive();
        bool zDone   = ImGui.IsItemDeactivatedAfterEdit();

        if (xActive || yActive || zActive) {
            Vec3 delta = Vec3(propInput.x - dragDelta.x,
                              propInput.y - dragDelta.y,
                              propInput.z - dragDelta.z);
            if (delta.x != 0 || delta.y != 0 || delta.z != 0) {
                dragDelta = vec3Add(dragDelta, delta);
                buildVertexCacheIfNeeded();
                applyDeltaImmediate(delta);
                handler.setPosition(vec3Add(handler.center, delta));
                cachedCenter = handler.center;
                if (vertexProcessCount == cast(int)mesh.vertices.length) {
                    wholeMeshDrag = true;
                    gpuMatrix = translationMatrix(dragDelta);
                } else {
                    needsGpuUpdate = true;
                }
            }
        }

        if (xDone || yDone || zDone) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
        }
    }

private:
    // Apply delta to CPU vertices (no GPU upload).
    void applyDelta(Vec3 delta) {
        buildVertexCacheIfNeeded();
        applyDeltaImmediate(delta);
    }

    // Apply delta immediately to cached vertex indices (very fast inner loop).
    void applyDeltaImmediate(Vec3 delta) {
        foreach (vi; vertexIndicesToProcess) {
            mesh.vertices[vi].x += delta.x;
            mesh.vertices[vi].y += delta.y;
            mesh.vertices[vi].z += delta.z;
        }
    }
}
