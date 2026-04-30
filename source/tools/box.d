module tools.box;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import handler : MoveHandler, BoxHandler, getGizmoScreenFraction, gizmoSize;
import drag;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : abs, sqrt;

// Reuses the BevelTool factory type — both tools record a generic
// (pre, post) MeshSnapshot pair via MeshBevelEdit, just with a different
// label. The class is bevel-named for legacy reasons; rename once a third
// caller appears.
alias BoxEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// BoxTool — two-drag 3-D cuboid creation
//
//   Drag 1  (LMB down → move → up)  : draw base rectangle on most-facing plane
//   Drag 2  (LMB down → move → up)  : extrude height along plane normal → cuboid
//   RMB / deactivate                 : cancel current operation
// ---------------------------------------------------------------------------

private enum BoxState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class BoxTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    LitShader litShader;

    Mesh    previewMesh;
    GpuMesh previewGpu;

    BoxState state;

    // Base rectangle (axis-aligned on the most-facing plane)
    Vec3    startPoint;
    Vec3    currentPoint;
    Vec3[4] baseCorners;

    // Height extrusion
    float height;
    Vec3  hpn;
    Vec3  hpOrigin;       // base centroid, origin of height plane
    Vec3  heightDragStart; // world hit at second LMB press

    // Plane chosen at first click
    Vec3  planeNormal;
    Vec3  planeAxis1;
    Vec3  planeAxis2;

    Viewport cachedVp;

    // Move gizmo (axis-only, no plane circles)
    MoveHandler mover;
    int         moverDragAxis = -1;   // 0/1/2 = X/Y/Z, -1 = none
    int         moverLastMX, moverLastMY;

    // Edge midpoint handles (BaseSet only)
    // 0 = edge 0-1, 1 = edge 1-2, 2 = edge 2-3, 3 = edge 3-0
    BoxHandler[4] edgeH;
    int           edgeDragIdx    = -1;
    int           edgeHoveredIdx = -1;
    int           edgeLastMX, edgeLastMY;

    BoxHandler[2] heightH;           // [0] = bottom face, [1] = top face
    int           heightHDragIdx  = -1;  // -1 = none, 0/1 = which handle is dragging
    bool          heightHHovered  = false;

    // Phase C-followup: undo plumbing. Pre-commit mesh state is captured
    // in deactivate() right before commitBase / commitCuboid mutates the
    // cage; post-state is captured immediately after, and one
    // MeshBevelEdit lands on history. Both nullable for legacy / tests.
    CommandHistory  history;
    BoxEditFactory  boxEditFactory;

public:
    bool meshChanged;

    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0,0,0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        foreach (i; 0 .. 4)
            edgeH[i] = new BoxHandler(Vec3(0,0,0), Vec3(0.9f, 0.2f, 0.2f));
        foreach (i; 0 .. 2)
            heightH[i] = new BoxHandler(Vec3(0,0,0), Vec3(0.9f, 0.9f, 0.2f));
    }

    void destroy() {
        mover.destroy();
        foreach (h; edgeH) h.destroy();
        foreach (h; heightH) h.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    /// commitBoxEdit() is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, BoxEditFactory factory) {
        this.history        = h;
        this.boxEditFactory = factory;
    }

    override string name() const { return "Box"; }

    override void activate() {
        state           = BoxState.Idle;
        meshChanged     = false;
        moverDragAxis   = -1;
        edgeDragIdx     = -1;
        heightHDragIdx  = -1;
        heightHHovered  = false;
        height          = 0.0f;
        previewGpu.init();
    }

    override void deactivate() {
        // Decide what (if anything) is going to be committed; capture the
        // pre-commit snapshot ONLY when we're about to mutate the cage,
        // so an empty Idle deactivate doesn't pollute the undo stack.
        bool willCommit = (state == BoxState.BaseSet)
                       || (state >= BoxState.DrawingHeight && abs(height) > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == BoxState.BaseSet)
            commitBase();
        else if (state >= BoxState.DrawingHeight && abs(height) > 1e-5f)
            commitCuboid();
        state = BoxState.Idle;
        previewGpu.destroy();

        if (willCommit) commitBoxEdit(pre);
    }

    private void commitBoxEdit(MeshSnapshot pre) {
        if (history is null || boxEditFactory is null) return;
        if (!pre.filled) return;
        auto cmd  = boxEditFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Box");
        history.record(cmd);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != BoxState.Idle) {
            state = BoxState.Idle;
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        // Edge handle hit-test (BaseSet / HeightSet)
        if (state == BoxState.BaseSet || state == BoxState.HeightSet) {
            foreach (i, h; edgeH) {
                if (h.hitTest(e.x, e.y, cachedVp)) {
                    edgeDragIdx = cast(int)i;
                    edgeLastMX  = e.x;
                    edgeLastMY  = e.y;
                    return true;
                }
            }
        }

        // Height handles (BaseSet / HeightSet) — priority over mover centerBox
        // BaseSet: only bottom [0]; HeightSet: both [0] and [1]
        int heightHHitIdx = -1;
        if (heightH[0].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 0;
        else if (state == BoxState.HeightSet && heightH[1].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 1;
        if ((state == BoxState.BaseSet || state == BoxState.HeightSet) && heightHHitIdx >= 0) {
            heightHDragIdx = heightHHitIdx;
            setupHeightPlane();
            Vec3 hhit;
            bool hhitOk = rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                            hpOrigin, hpn, hhit);
            if (heightHHitIdx == 1) {
                // Top handle: non-incremental drag; anchor so current height is preserved.
                heightDragStart = hhitOk
                    ? hhit - planeNormal * height
                    : hpOrigin;
            } else {
                // Bottom handle: incremental drag; anchor at the current hit point.
                heightDragStart = hhitOk ? hhit : hpOrigin;
            }
            if (state == BoxState.BaseSet) {
                height = 0.0f;
                state  = BoxState.DrawingHeight;
            }
            uploadCuboid();
            return true;
        }

        // Move gizmo hit-test only once the base is finalized
        if (state >= BoxState.BaseSet) {
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis  = hit;
                moverLastMX    = e.x;
                moverLastMY    = e.y;
                return true;
            }
        }

        if (state == BoxState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0,0,0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            state        = BoxState.DrawingBase;
            uploadBase();
            return true;
        }

        if (state == BoxState.BaseSet) {
            height = 0.0f;
            setupHeightPlane();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = BoxState.DrawingHeight;
            uploadCuboid();
            return true;
        }

        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (edgeDragIdx >= 0) { edgeDragIdx = -1; return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) { heightHDragIdx = -1; return true; }

        if (state == BoxState.DrawingBase) {
            computeBaseCorners();
            Vec3 d = currentPoint - startPoint;
            float dd1 = dot(d, planeAxis1);
            float dd2 = dot(d, planeAxis2);
            // Also rejects NaN (NaN comparisons are false, so !(dd1 > 1e-5f) catches NaN).
            if (!(abs(dd1) > 1e-5f) || !(abs(dd2) > 1e-5f)) {
                state = BoxState.Idle;
                return true;
            }
            state = BoxState.BaseSet;
            uploadBase();
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            state = BoxState.HeightSet;
            heightHDragIdx = -1;
            return true;
        }

        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (edgeDragIdx >= 0) {
            Vec3 moveAxis = (edgeDragIdx == 0 || edgeDragIdx == 2) ? planeAxis2 : planeAxis1;
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, edgeLastMX, edgeLastMY,
                                         edgeH[edgeDragIdx].pos, moveAxis, cachedVp, skip);
            if (!skip) applyEdgeDelta(edgeDragIdx, delta);
            edgeLastMX = e.x;
            edgeLastMY = e.y;
            return true;
        }

        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip);
            if (!skip) applyMoverDelta(delta);
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }

        // heightH drag in HeightSet (re-drag without changing state)
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                if (heightHDragIdx == 1) {
                    // Top handle: move top face, base stays.
                    height = dot(hit - heightDragStart, planeNormal);
                } else {
                    // Bottom handle: move base, top face stays.
                    // Incremental delta so the top face world position is preserved.
                    float delta = dot(hit - heightDragStart, planeNormal);
                    Vec3  d     = planeNormal * delta;
                    startPoint   += d;
                    currentPoint += d;
                    hpOrigin     += d;
                    foreach (ref c; baseCorners) c += d;
                    height      -= delta;
                    heightDragStart = hit; // incremental: advance anchor each frame
                }
                uploadCuboid();
            }
            return true;
        }

        // Track hover over edge/height handles when nothing is being dragged
        if (state == BoxState.BaseSet || state == BoxState.HeightSet) {
            edgeHoveredIdx = -1;
            heightHHovered = false;
            foreach (i, h; edgeH)
                if (h.hitTest(e.x, e.y, cachedVp)) { edgeHoveredIdx = cast(int)i; break; }
            if (edgeHoveredIdx < 0) {
                heightHHovered = heightH[0].hitTest(e.x, e.y, cachedVp) ||
                                 (state == BoxState.HeightSet && heightH[1].hitTest(e.x, e.y, cachedVp));
            }
        } else {
            edgeHoveredIdx = -1;
            heightHHovered = false;
        }

        if (state == BoxState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0,0,0), planeNormal, hit))
            {
                currentPoint = hit;
                uploadBase();
            }
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                height = dot(hit - heightDragStart, planeNormal);
                uploadCuboid();
            }
            return true;
        }

        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == BoxState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        // --- Solid faces ---
        glUseProgram(litShader.program);
        glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
        glUniform1f(litShader.locAmbient,  0.20f);
        glUniform1f(litShader.locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,  32.0f);

        previewGpu.drawFaces(litShader);

        // --- Wireframe edges ---
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        previewGpu.drawEdges(shader.locColor, -1, []);

        // Draw edge and height handles (BaseSet and above)
        if (state >= BoxState.BaseSet) {
            updateEdgeHandlers(vp);
            updateHeightHandler(vp);
            bool moverBusy  = moverDragAxis >= 0;
            bool anyEdgeBusy = edgeDragIdx >= 0;
            foreach (i, h; edgeH) {
                h.setForceHovered(edgeDragIdx == cast(int)i);
                h.setHoverBlocked(moverBusy || (anyEdgeBusy && edgeDragIdx != cast(int)i));
                h.draw(shader, vp);
            }
            bool heightBlocked  = moverBusy || anyEdgeBusy || edgeHoveredIdx >= 0;
            bool anyHeightBusy  = heightHDragIdx >= 0 || state == BoxState.DrawingHeight;
            // In DrawingHeight the top face moves with the mouse — heightH[1] is active.
            // In HeightSet it depends on which handle was grabbed.
            bool h0Force = (state == BoxState.HeightSet) && (heightHDragIdx == 0);
            bool h1Force = (state == BoxState.DrawingHeight) || ((state == BoxState.HeightSet) && (heightHDragIdx == 1));
            heightH[0].setForceHovered(h0Force);
            heightH[0].setHoverBlocked(heightBlocked || (anyHeightBusy && !h0Force));
            heightH[0].draw(shader, vp);
            if (state >= BoxState.DrawingHeight) {
                heightH[1].setForceHovered(h1Force);
                heightH[1].setHoverBlocked(heightBlocked || (anyHeightBusy && !h1Force));
                heightH[1].draw(shader, vp);
            }
        }

        // Draw move gizmo only once the base is finalized
        if (state >= BoxState.BaseSet) {
            mover.setPosition(boxCenter());
            mover.arrowX.setForceHovered(moverDragAxis == 0);
            mover.arrowY.setForceHovered(moverDragAxis == 1);
            mover.arrowZ.setForceHovered(moverDragAxis == 2);
            mover.centerBox.setForceHovered(moverDragAxis == 3);
            bool edgePriority = edgeDragIdx >= 0 || edgeHoveredIdx >= 0 || heightHHovered || heightHDragIdx >= 0;
            mover.arrowX.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 0));
            mover.arrowY.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 1));
            mover.arrowZ.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 2));
            mover.centerBox.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 3));
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        if (state == BoxState.Idle) {
            ImGui.TextDisabled("No active shape");
            return;
        }
        computeBaseCorners();
        Vec3  cen = baseCentroid();
        float d1  = dot(currentPoint - startPoint, planeAxis1);
        float d2  = dot(currentPoint - startPoint, planeAxis2);

        // World-space size: axis1/axis2 cover the base; planeNormal covers height.
        Vec3 sizeVec = planeAxis1 * abs(d1) + planeAxis2 * abs(d2);
        if (state >= BoxState.DrawingHeight)
            sizeVec = sizeVec + planeNormal * abs(height);

        // ---- Center ----
        float cx = cen.x, cy = cen.y, cz = cen.z;
        ImGui.Text("Center");
        bool cChanged = false;
        cChanged |= ImGui.DragFloat("X##cenX", &cx, 0.01f, 0, 0, "%.3f");
        cChanged |= ImGui.DragFloat("Y##cenY", &cy, 0.01f, 0, 0, "%.3f");
        cChanged |= ImGui.DragFloat("Z##cenZ", &cz, 0.01f, 0, 0, "%.3f");
        if (cChanged) {
            Vec3 delta  = Vec3(cx - cen.x, cy - cen.y, cz - cen.z);
            startPoint   = startPoint   + delta;
            currentPoint = currentPoint + delta;
            uploadPreview();
        }

        // ---- Size ----
        float sx = sizeVec.x, sy = sizeVec.y, sz = sizeVec.z;
        ImGui.Text("Size");
        bool sxC = ImGui.DragFloat("X##szX", &sx, 0.01f, 0.001f, float.max, "%.3f");
        bool syC = ImGui.DragFloat("Y##szY", &sy, 0.01f, 0.001f, float.max, "%.3f");
        bool szC = ImGui.DragFloat("Z##szZ", &sz, 0.01f, 0.001f, float.max, "%.3f");
        if (sxC || syC || szC) {
            float sign1 = d1 < 0 ? -1.0f : 1.0f;
            float sign2 = d2 < 0 ? -1.0f : 1.0f;
            float signH = height < 0 ? -1.0f : 1.0f;
            if (sxC) {
                if      (abs(planeAxis1.x)  > 0.5f) d1     = sx * sign1;
                else if (abs(planeAxis2.x)  > 0.5f) d2     = sx * sign2;
                else if (abs(planeNormal.x) > 0.5f) height = sx * signH;
            }
            if (syC) {
                if      (abs(planeAxis1.y)  > 0.5f) d1     = sy * sign1;
                else if (abs(planeAxis2.y)  > 0.5f) d2     = sy * sign2;
                else if (abs(planeNormal.y) > 0.5f) height = sy * signH;
            }
            if (szC) {
                if      (abs(planeAxis1.z)  > 0.5f) d1     = sz * sign1;
                else if (abs(planeAxis2.z)  > 0.5f) d2     = sz * sign2;
                else if (abs(planeNormal.z) > 0.5f) height = sz * signH;
            }
            // Reconstruct startPoint/currentPoint from center + new d1/d2.
            startPoint   = cen - planeAxis1 * (d1 * 0.5f) - planeAxis2 * (d2 * 0.5f);
            currentPoint = cen + planeAxis1 * (d1 * 0.5f) + planeAxis2 * (d2 * 0.5f);
            uploadPreview();
        }
    }

private:
    // Center of the current box shape (base centroid shifted by half height).
    Vec3 boxCenter() const {
        Vec3 c = baseCentroid();
        if (state >= BoxState.DrawingHeight)
            c = c + planeNormal * (height * 0.5f);
        return c;
    }

    // Hit-test axis arrows (0/1/2) and centerBox (3).
    int moverHitTest(int mx, int my) {
        import handler : Arrow;
        if (mover.centerBox.hitTest(mx, my, cachedVp)) return 3;
        Arrow[3] arrows = [mover.arrowX, mover.arrowY, mover.arrowZ];
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

    // Apply world-space delta to all box geometry.
    void applyMoverDelta(Vec3 d) {
        startPoint      = startPoint      + d;
        currentPoint    = currentPoint    + d;
        hpOrigin        = hpOrigin        + d;
        heightDragStart = heightDragStart + d;
        foreach (ref c; baseCorners) c = c + d;
        uploadPreview();
    }

    // Color by world axis direction.
    static Vec3 axisColor(Vec3 axis) {
        if (abs(axis.x) > 0.5f) return Vec3(0.9f, 0.2f, 0.2f);
        if (abs(axis.y) > 0.5f) return Vec3(0.2f, 0.9f, 0.2f);
        return Vec3(0.2f, 0.2f, 0.9f);
    }

    // Update height handles.
    // [0] = bottom face center (baseCentroid), always.
    // [1] = top face center (baseCentroid + height), DrawingHeight/HeightSet only.
    void updateHeightHandler(const ref Viewport vp) {
        Vec3 bot = baseCentroid();
        Vec3 top = bot + planeNormal * height;
        Vec3[2] pts = [bot, top];
        foreach (i; 0 .. 2) {
            heightH[i].pos   = pts[i];
            heightH[i].size  = gizmoSize(pts[i], vp, 0.04f);
            heightH[i].color = axisColor(planeNormal);
        }
    }

    // Update edge handler positions, sizes and colors.
    // BaseSet            → midpoints of base edges.
    // DrawingHeight/HeightSet → centers of the 4 side faces (edge midpoints + half height).
    void updateEdgeHandlers(const ref Viewport vp) {
        Vec3 halfH = (state >= BoxState.DrawingHeight)
            ? planeNormal * (height * 0.5f)
            : Vec3(0, 0, 0);

        static immutable int[4][4] edgePairs = [[0,1],[1,2],[2,3],[3,0]];
        Vec3[4] mids;
        foreach (i, pair; edgePairs)
            mids[i] = (baseCorners[pair[0]] + baseCorners[pair[1]]) * 0.5f + halfH;

        Vec3[4] colors = [axisColor(planeAxis2), axisColor(planeAxis1),
                          axisColor(planeAxis2), axisColor(planeAxis1)];

        foreach (i; 0 .. 4) {
            edgeH[i].pos   = mids[i];
            edgeH[i].size  = gizmoSize(mids[i], vp, 0.04f);
            edgeH[i].color = colors[i];
        }
    }

    // Move one edge of the base rectangle along its perpendicular axis.
    // Edge 0 (corners 0,1): shift startPoint along axis2
    // Edge 1 (corners 1,2): extend currentPoint along axis1
    // Edge 2 (corners 2,3): extend currentPoint along axis2
    // Edge 3 (corners 3,0): shift startPoint along axis1
    void applyEdgeDelta(int idx, Vec3 delta) {
        switch (idx) {
            case 0: startPoint   = startPoint   + planeAxis2 * dot(delta, planeAxis2); break;
            case 1: currentPoint = currentPoint + planeAxis1 * dot(delta, planeAxis1); break;
            case 2: currentPoint = currentPoint + planeAxis2 * dot(delta, planeAxis2); break;
            case 3: startPoint   = startPoint   + planeAxis1 * dot(delta, planeAxis1); break;
            default: break;
        }
        uploadPreview();
    }

    void choosePlane(const ref Viewport vp) {
        float avx = abs(vp.view[2]);
        float avy = abs(vp.view[6]);
        float avz = abs(vp.view[10]);
        if (avx >= avy && avx >= avz) {
            planeNormal = Vec3(1, 0, 0);
            planeAxis1  = Vec3(0, 1, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else if (avy >= avx && avy >= avz) {
            planeNormal = Vec3(0, 1, 0);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else {
            planeNormal = Vec3(0, 0, 1);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 1, 0);
        }
    }

    void computeBaseCorners() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        baseCorners[0] = startPoint;
        baseCorners[1] = startPoint   + planeAxis1 * d1;
        baseCorners[2] = baseCorners[1] + planeAxis2 * d2;
        baseCorners[3] = startPoint     + planeAxis2 * d2;
    }

    void buildBase(Mesh* m) {
        computeBaseCorners();
        foreach (c; baseCorners) m.addVertex(c);
        Vec3 n     = cross(baseCorners[1] - baseCorners[0],
                           baseCorners[2] - baseCorners[0]);
        Vec3 toEye = cachedVp.eye - baseCentroid();
        if (dot(n, toEye) >= 0)
            m.addFace([0u, 1u, 2u, 3u]);
        else
            m.addFace([0u, 3u, 2u, 1u]);
    }

    void uploadBase() {
        previewMesh.clear();
        buildBase(&previewMesh);
        previewGpu.upload(previewMesh);
    }

    // Upload whichever preview is appropriate for the current state.
    void uploadPreview() {
        if (state >= BoxState.DrawingHeight)
            uploadCuboid();
        else
            uploadBase();
    }

    void commitBase() {
        buildBase(mesh);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    Vec3 baseCentroid() const {
        return Vec3(
            (baseCorners[0].x + baseCorners[1].x + baseCorners[2].x + baseCorners[3].x) * 0.25f,
            (baseCorners[0].y + baseCorners[1].y + baseCorners[2].y + baseCorners[3].y) * 0.25f,
            (baseCorners[0].z + baseCorners[1].z + baseCorners[2].z + baseCorners[3].z) * 0.25f,
        );
    }

    void setupHeightPlane() {
        hpOrigin = baseCentroid();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f
            ? inPlane / len
            : planeAxis1;
    }

    void buildCuboid(Mesh* m) {
        Vec3 H = planeNormal * height;
        Vec3[8] pts = [
            baseCorners[0], baseCorners[1], baseCorners[2], baseCorners[3],
            baseCorners[0] + H, baseCorners[1] + H,
            baseCorners[2] + H, baseCorners[3] + H,
        ];
        Vec3 cen = Vec3(0,0,0);
        foreach (p; pts) cen = cen + p * 0.125f;

        static immutable int[24] faceIdx = [
            0,1,2,3,   // bottom
            4,7,6,5,   // top
            0,4,5,1,   // side 0-1
            1,5,6,2,   // side 1-2
            2,6,7,3,   // side 2-3
            3,7,4,0,   // side 3-0
        ];

        uint[8] vi;
        foreach (i; 0..8) vi[i] = m.addVertex(pts[i]);

        for (int fi = 0; fi < 6; fi++) {
            int b  = fi * 4;
            int i0 = faceIdx[b], i1 = faceIdx[b+1],
                i2 = faceIdx[b+2], i3 = faceIdx[b+3];
            Vec3 n  = cross(pts[i1] - pts[i0], pts[i2] - pts[i0]);
            Vec3 fc = (pts[i0] + pts[i1] + pts[i2] + pts[i3]) * 0.25f;
            if (dot(n, fc - cen) > 0)
                m.addFace([vi[i0], vi[i1], vi[i2], vi[i3]]);
            else
                m.addFace([vi[i0], vi[i3], vi[i2], vi[i1]]);
        }
    }

    void uploadCuboid() {
        previewMesh.clear();
        buildCuboid(&previewMesh);
        previewGpu.upload(previewMesh);
    }

    void commitCuboid() {
        buildCuboid(mesh);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }
}
