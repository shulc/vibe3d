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
import snap : snapCursor, SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import toolpipe.packets : SnapPacket, FalloffPacket, FalloffType;
import falloff : evaluateFalloff;

// ---------------------------------------------------------------------------
// MoveTool : TransformTool — shows MoveHandler at selection/mesh center
// ---------------------------------------------------------------------------

class MoveTool : TransformTool {
    MoveHandler handler;

private:
    Vec3     dragDelta;       // accumulated world-space offset since drag start
    Vec3     propInput;       // value shown in Tool Properties (basis-local components,
                              //  i.e. dot(dragDelta, axisX/Y/Z) — see drawProperties)
    bool     ctrlConstrain;        // Ctrl: axis TBD from initial movement (only for dragAxis==3)
    int      constrainStartMX, constrainStartMY;
    // (lastSnap moved to TransformTool — same semantics, also drives
    // the live click-outside snap preview now.)

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

        // Skip hash computation entirely during drag — selection and mesh
        // can't change "outside" the tool's own input.
        if (dragAxis >= 0) return;

        uint  currentHash   = computeSelectionHash();
        ulong currentMutVer = mesh.mutationVersion;
        // Reset per-drag scratch on selection / geometry change.
        if (currentHash != lastSelectionHash || currentMutVer != lastMutationVersion) {
            lastSelectionHash   = currentHash;
            lastMutationVersion = currentMutVer;
            vertexCacheDirty    = true;
            centerManual        = false;
            dragDelta = Vec3(0, 0, 0);
            propInput = Vec3(0, 0, 0);
        }

        // Pull the gizmo center from the ACEN stage every frame: mode /
        // userPlaced changes don't bump the selection hash or mesh
        // mutation, so they would otherwise not propagate to the
        // visible gizmo.
        cachedCenter = queryActionCenter();
        handler.setPosition(cachedCenter);
    }

    override void draw(const ref Shader shader, const ref Viewport vp)
    {
        if (!active) return;
        cachedVp = vp;

        // Pull the active workplane basis (auto ⇒ world XYZ) and orient the
        // gizmo into it: arrowX = workplane axis1, arrowY = workplane normal,
        // arrowZ = workplane axis2. Drag math reads these via the handler.
        Vec3 bX, bY, bZ;
        currentBasis(bX, bY, bZ);
        handler.setOrientation(bX, bY, bZ);

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

        // Phase 7.3d: snap visual feedback. Yellow ring (highlighted)
        // + filled disc (snapped) at the snap candidate's screen pixel,
        // plus a cyan highlight on the actual mesh element being
        // snapped to (vertex / edge / face). No-op when no recent snap
        // (init/cleared SnapResult has highlighted=false).
        drawSnapOverlay(lastSnap, vp, *mesh);
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
        // 7.3d: drag is over — drop the snap highlight so it doesn't
        // linger after the gizmo settles.
        lastSnap = SnapResult.init;
        clearLastSnap();
        // propInput holds basis-local components, so projecting via the
        // gizmo's basis. With identity basis this collapses to world XYZ.
        propInput = Vec3(dot(dragDelta, handler.axisX),
                         dot(dragDelta, handler.axisY),
                         dot(dragDelta, handler.axisZ));
        // Sync cachedCenter to the actual post-move gizmo position so update()
        // does not snap it back to the pre-move centroid on the next frame.
        cachedCenter = handler.center;
        // Sticky-pin follow: when ACEN.userPlaced is active (set by
        // click-outside-relocate at drag start), update the pin to the
        // post-drag handler position. Without this, the next update()
        // frame asks ACEN for the center and gets back the original
        // click point — snap-final position is lost and the gizmo
        // visually jumps back. With snap on the jump is dramatic
        // because the gizmo had locked onto a discrete snap target.
        if (acenIsUserPlaced())
            notifyAcenUserPlaced(handler.center);
        lastSelectionHash = computeSelectionHash();
        // Phase C.2: land this drag as one undo entry. No-op if the drag
        // didn't actually move any verts.
        commitEdit("Move");
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
            // Phase 7.5: capture the falloff packet before deciding on
            // wholeMeshDrag — when falloff is active, per-vertex weights
            // break the gpuMatrix single-uniform fast path, so we must
            // fall through to the per-vertex CPU + deferred-upload
            // route regardless of selection size.
            bool falloffActive = captureFalloffForDrag();
            wholeMeshDrag = !falloffActive
                && (vertexProcessCount == cast(int)mesh.vertices.length);
            beginEdit();   // Phase C.2: snapshot pre-drag positions for undo.
            return true;
        }

        // Click outside gizmo. Per MODO 9, only Auto / None / Screen
        // ACEN modes relocate the gizmo on click-outside; the others
        // (Select / SelectAuto / Element / Local / Origin / Manual /
        // Border) keep the gizmo pinned to a selection-derived or
        // fixed point and ignore the click entirely.
        //
        //   Auto / None : project click onto the most-facing world-axis
        //                 plane through (0,0,0).
        //   Screen      : project click onto a camera-perpendicular
        //                 plane through the current selection bbox
        //                 centre.
        //
        // After relocation the drag plane is the most-facing plane
        // THROUGH the new gizmo center — drag projection feels natural
        // across camera angles regardless of where the new center
        // landed.
        if (!acenAllowsClickRelocate())
            return false;
        Vec3 hit;
        if (!computeClickRelocateHit(e.x, e.y, hit))
            return false;
        handler.setPosition(hit);
        centerManual = true;
        // Notify ACEN so the user-placed point sticks across future
        // queries (other tools, history replay etc.). Only meaningful
        // in Auto mode — None / Screen don't currently consume
        // userPlaced, but the call is harmless there.
        notifyAcenUserPlaced(hit);
        dragAxis = 3;   // most-facing plane through gizmo center
        lastMX = e.x; lastMY = e.y;
        dragDelta = Vec3(0, 0, 0);
        buildVertexCacheIfNeeded();
        bool falloffActiveOutside = captureFalloffForDrag();
        wholeMeshDrag = !falloffActiveOutside
            && (vertexProcessCount == cast(int)mesh.vertices.length);
        if (ctrl) {
            ctrlConstrain = true;
            constrainStartMX = e.x; constrainStartMY = e.y;
        }
        beginEdit();   // Phase C.2: snapshot pre-drag positions for undo.
        return true;
    }

    // Phase 7.3a/c: route the would-be gizmo position through
    // SnapStage. Returns the (possibly-adjusted) world delta to apply
    // this frame. No-op when no pipeline is registered or snap is
    // disabled. The dragged element's own verts are excluded so a
    // single-vert drag can't snap to itself. 7.3d: also stashes the
    // SnapResult on the tool + global so draw() can render the
    // overlay and HTTP /api/snap/last can read it.
    private Vec3 applySnapToDelta(Vec3 gizmoCenter, Vec3 worldDelta,
                                  int sx, int sy)
    {
        import toolpipe.pipeline   : g_pipeCtx;
        import toolpipe.packets    : SubjectPacket;
        if (g_pipeCtx is null) return worldDelta;

        // pipeline.evaluate so SNAP picks up upstream WORK state
        // (workplane center / normal / axes used by Grid +
        // Workplane candidates).
        SubjectPacket subj;
        subj.mesh             = mesh;
        subj.editMode         = *editMode;
        subj.selectedVertices = mesh.selectedVertices.dup;
        subj.selectedEdges    = mesh.selectedEdges.dup;
        subj.selectedFaces    = mesh.selectedFaces.dup;
        auto state = g_pipeCtx.pipeline.evaluate(subj, cachedVp);
        if (!state.snap.enabled) {
            lastSnap = SnapResult.init;
            clearLastSnap();
            return worldDelta;
        }

        // Exclude verts the drag is moving — same set
        // buildVertexCacheIfNeeded already populated. Otherwise a
        // single-vert drag always snaps to its own (zero-distance)
        // projected pixel.
        uint[] exclude;
        exclude.length = vertexProcessCount;
        foreach (i; 0 .. vertexProcessCount)
            exclude[i] = cast(uint)vertexIndicesToProcess[i];

        Vec3 desired = gizmoCenter + worldDelta;
        SnapResult sr = snapCursor(desired, sx, sy, cachedVp,
                                   *mesh, state.snap, exclude);
        lastSnap = sr;
        publishLastSnap(sr);
        if (sr.snapped)
            return constrainSnapDelta(sr.worldPos - gizmoCenter);
        return worldDelta;
    }

    // Project a raw snap delta (snapTarget - gizmoCenter) onto the active
    // drag axis / plane so an off-axis snap candidate doesn't smear the
    // selection across axes. For an X-arrow drag with snap to a vertex
    // at (Tx, Ty, Tz), this returns ((Tx - Gx) * axisX) — i.e. the gizmo
    // moves only along X to the snap target's X coordinate. Mirrors
    // MODO's "axis-locked snap" semantics.
    //
    // The centerBox handle (dragAxis==3) is intentionally NOT constrained:
    // it's the "free move" handle, and the user expectation is that
    // grabbing it + snapping lands the gizmo exactly at the snap point in
    // 3D. The explicit plane circles (4/5/6) keep their plane lock — the
    // user picked that plane on purpose.
    private Vec3 constrainSnapDelta(Vec3 delta) {
        // Single-axis drag — keep only the component along the locked axis.
        if (dragAxis == 0) return handler.axisX * dot(delta, handler.axisX);
        if (dragAxis == 1) return handler.axisY * dot(delta, handler.axisY);
        if (dragAxis == 2) return handler.axisZ * dot(delta, handler.axisZ);
        // Plane circles — strip the component along the plane normal.
        if (dragAxis == 4) return delta - handler.axisZ * dot(delta, handler.axisZ);
        if (dragAxis == 5) return delta - handler.axisX * dot(delta, handler.axisX);
        if (dragAxis == 6) return delta - handler.axisY * dot(delta, handler.axisY);
        // dragAxis == 3 (centerBox) and any unrecognised value: pass
        // through the full 3D snap delta.
        return delta;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active) return false;
        if (dragAxis == -1) {
            // Idle hover: refresh the live click-outside snap preview
            // so the cyan overlay shows where the gizmo would land if
            // the user clicked right now. hitTestAxes returns >= 0
            // when the cursor is on a gizmo handle (would start a
            // drag, not a relocate) — preview is suppressed there.
            updateLiveSnapPreview(e.x, e.y, hitTestAxes(e.x, e.y));
            return false;
        }

        // Ctrl-constrain: wait for initial movement to determine which of the two
        // in-plane axes to lock to, then switch dragAxis to that axis (0/1/2).
        if (ctrlConstrain) {
            int tdx = e.x - constrainStartMX;
            int tdy = e.y - constrainStartMY;
            if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }

            // Identify the two basis axes that lie in the most-facing plane
            // (the third axis — the one most parallel to the camera ray — is
            // the plane normal).
            import std.math : abs;
            const ref float[16] vv = cachedVp.view;
            Vec3 camBack = Vec3(vv[2], vv[6], vv[10]);
            float aXdot = abs(dot(camBack, handler.axisX));
            float aYdot = abs(dot(camBack, handler.axisY));
            float aZdot = abs(dot(camBack, handler.axisZ));
            int ax1, ax2;
            if      (aXdot >= aYdot && aXdot >= aZdot) { ax1 = 1; ax2 = 2; } // normal=axisX → Y,Z
            else if (aYdot >= aXdot && aYdot >= aZdot) { ax1 = 0; ax2 = 2; } // normal=axisY → X,Z
            else                                       { ax1 = 0; ax2 = 1; } // normal=axisZ → X,Y

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
                                        dragAxis, handler.center, cachedVp, skip,
                                        handler.axisX, handler.axisY, handler.axisZ);
        if (skip) { lastMX = e.x; lastMY = e.y; return true; }

        // Phase 7.3a: snap. Bend the would-be gizmo position towards a
        // mesh element (vertex in 7.3a; edge / face / centre in 7.3b)
        // when SNAP is on. Adjust `worldDelta` so the gizmo lands at
        // the snapped point — selection moves by the same delta.
        // Per-cluster path keeps its own delta-per-cluster math and
        // doesn't go through snap (snap-with-multi-cluster has no
        // single target meaning; revisit if MODO parity demands it).
        worldDelta = applySnapToDelta(handler.center, worldDelta, e.x, e.y);

        // Phase 4 of doc/acen_modo_parity_plan.md: when ACEN.Local +
        // axis.local publish per-cluster basis, project the same screen
        // mouse delta onto EACH cluster's basis. Each cluster moves in
        // its own world direction, matching MODO's empirical actr.local
        // + xfrm.move behaviour.
        auto cp = queryClusterPivots();
        auto ap = queryClusterAxes();
        if (cp.active && ap.active && dragAxis <= 2) {
            applyPerClusterDelta(e.x, e.y, lastMX, lastMY, dragAxis, cp, ap);
        } else {
            // Apply delta to CPU vertices (fast inner loop)
            applyDelta(worldDelta);
        }

        // Update gizmo position immediately (uses world delta — gizmo
        // sits at the global ACEN center). Per-cluster verts have
        // already been moved above; this is just visual feedback.
        dragDelta += worldDelta;
        handler.setPosition(handler.center + worldDelta);

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
        // X/Y/Z fields show the cumulative drag in BASIS-local components
        // (dot of world dragDelta onto handler.axisX/Y/Z). With auto
        // workplane the basis is identity ⇒ the fields read as world XYZ;
        // with a non-auto workplane they read as workplane-local — same
        // semantics as MODO's tool properties form.
        Vec3 ax = handler.axisX, ay = handler.axisY, az = handler.axisZ;
        if (dragAxis >= 0) {
            propInput = Vec3(dot(dragDelta, ax),
                             dot(dragDelta, ay),
                             dot(dragDelta, az));
        }
        Vec3 propBefore = propInput;

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
            // Slider edits are in basis-local components; recompose into a
            // world delta along the gizmo's axes before applying.
            Vec3 localDiff = propInput - propBefore;
            if (localDiff.x != 0 || localDiff.y != 0 || localDiff.z != 0) {
                Vec3 delta = ax*localDiff.x + ay*localDiff.y + az*localDiff.z;
                dragDelta += delta;
                buildVertexCacheIfNeeded();
                // Phase 7.5: re-capture falloff at every props-slider
                // frame. A stable snapshot would diverge if the user
                // tweaks falloff attrs mid-drag; props sliders are
                // low-frequency input so the per-frame pipeline.evaluate
                // is cheap.
                captureFalloffForDrag();
                beginEdit();
                applyDeltaImmediate(delta);
                handler.setPosition(handler.center + delta);
                cachedCenter = handler.center;
                needsGpuUpdate = true;
            }
        }

        if (xDone || yDone || zDone) {
            gpu.upload(*mesh);
            gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            wholeMeshDrag = false;
            commitEdit("Move");
        }
    }

private:
    // Apply delta to CPU vertices (no GPU upload).
    void applyDelta(Vec3 delta) {
        buildVertexCacheIfNeeded();
        applyDeltaImmediate(delta);
    }

    // Apply delta immediately to cached vertex indices (very fast inner loop).
    // Phase 7.5: when falloff is active on the captured drag packet,
    // multiply each per-vertex displacement by the falloff weight.
    // Falloff-off path stays a tight 3-add loop with no extra work.
    void applyDeltaImmediate(Vec3 delta) {
        if (!dragFalloff.enabled) {
            foreach (vi; vertexIndicesToProcess) {
                mesh.vertices[vi].x += delta.x;
                mesh.vertices[vi].y += delta.y;
                mesh.vertices[vi].z += delta.z;
            }
            return;
        }
        foreach (vi; vertexIndicesToProcess) {
            float w = falloffWeight(vi);
            if (w == 0.0f) continue;
            mesh.vertices[vi].x += delta.x * w;
            mesh.vertices[vi].y += delta.y * w;
            mesh.vertices[vi].z += delta.z * w;
        }
    }

    // Per-cluster delta: project the screen-mouse motion onto each
    // cluster's basis axis (right/up/fwd, picked by dragAxis) and apply
    // that per-cluster delta to the cluster's verts. Phase 4 of
    // doc/acen_modo_parity_plan.md.
    void applyPerClusterDelta(int mx, int my, int lastMX, int lastMY,
                              int axisIdx,
                              ClusterPivots cp, ClusterAxes ap)
    {
        import drag : screenAxisDelta;
        import math : projectToWindowFull;
        size_t n = ap.right.length;
        Vec3[] deltas = new Vec3[](n);
        foreach (cid; 0 .. n) {
            Vec3 axis;
            if      (axisIdx == 0) axis = ap.right[cid];
            else if (axisIdx == 1) axis = ap.up[cid];
            else                   axis = ap.fwd[cid];
            Vec3 origin = cp.centers[cid];
            bool skip;
            deltas[cid] = screenAxisDelta(mx, my, lastMX, lastMY,
                                          origin, axis, cachedVp, skip);
            if (skip) deltas[cid] = Vec3(0, 0, 0);
        }
        buildVertexCacheIfNeeded();
        foreach (vi; vertexIndicesToProcess) {
            int cid = (vi < cp.clusterOf.length) ? cp.clusterOf[vi] : -1;
            Vec3 d = (cid >= 0 && cid < cast(int)n) ? deltas[cid] : Vec3(0, 0, 0);
            mesh.vertices[vi].x += d.x;
            mesh.vertices[vi].y += d.y;
            mesh.vertices[vi].z += d.z;
        }
        needsGpuUpdate = true;
    }
}
