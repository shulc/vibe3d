module tools.bevel;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import handler;
import mesh;
import editmode;
import math;
import shader;
import drag;
import bevel;
import poly_bevel;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt;

// Factory: builds a fresh MeshBevelEdit pre-wired to the same gpu/caches
// the tool mutates (the registry creates BevelTool with a closure that
// has access to those globals).
alias BevelEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// BevelTool — polygon bevel (Polygons mode) + edge bevel (Edges mode)
//
// Polygon mode:
//   shiftHandle  (Arrow)      : MoveTool-style drag along face normal → shift
//   insertHandle (CubicArrow) : ScaleTool-style drag along face tangent → inset
//
// Edge mode:
//   shiftHandle  (Arrow)      : drag along edge-adjacent normal → width
// ---------------------------------------------------------------------------


class BevelTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    bool active;

    // Gizmo handles
    Arrow      shiftHandle;       // cone arrow  — shift/width
    CubicArrow insertHandle;      // cube arrow  — insert (polygon mode only)
    CubicArrow insertScaleArrow;  // yellow feedback arrow

    // Cached gizmo orientation (recomputed each frame when not dragging)
    Vec3 gizmoCenter;
    Vec3 gizmoNormal;   // unit vector: average face/edge-adjacent normal
    Vec3 gizmoRight;    // unit vector: perpendicular to normal

    // ---- Polygon bevel parameters ----
    // MODO Bevel Polygon: shift extrudes along normal, inset is the
    // perpendicular distance each face boundary edge moves inward in the
    // face plane (identity = 0). Negative inset → outset.
    float       shiftAmount   = 0.0f;
    float       insetAmount   = 0.0f;
    bool        groupPolygons = false;
    PolyBevelOp polyOp;

    // ---- Topology snapshot (shared by polygon and edge bevel) ----
    bool bevelApplied = false;

    // ---- Edge bevel parameters ----
    float          ebWidth      = 0.0f;
    float          ebWidthR     = 0.0f;
    bool           ebAsymmetric = false;
    int            ebSeg        = 1;
    float          ebSuperR     = 2.0f;
    BevelWidthMode ebMode       = BevelWidthMode.Offset;
    MiterPattern   ebMiterInner = MiterPattern.Sharp;
    BevelOp        ebOp;

    // ---- Drag state ----
    int      dragHandle = -1;   // 0=shift/width handle, 1=insert handle, -1=none
    int      lastMX, lastMY;
    Viewport cachedVp;

    // ---- Phase C.4: undo plumbing ----
    // history is the global stack; bevelEditFactory builds a MeshBevelEdit
    // pre-wired to the same caches the tool mutates. Both nullable for
    // legacy / test callers — commitBevelEdit() is a no-op then.
    // preBevelSnap is captured at the moment bevel topology is first built
    // (bevelApplied: false → true); held until deactivate() pairs it with
    // a fresh post-snap and records the edit on history.
    CommandHistory   history;
    BevelEditFactory bevelEditFactory;
    MeshSnapshot     preBevelSnap;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;

        gizmoCenter = Vec3(0, 0, 0);
        gizmoNormal = Vec3(0, 1, 0);
        gizmoRight  = Vec3(1, 0, 0);

        shiftHandle      = new Arrow     (gizmoCenter, gizmoCenter, Vec3(0.2f, 0.2f, 0.9f));
        insertHandle     = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(0.9f, 0.2f, 0.2f));
        insertScaleArrow = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(1.0f, 0.95f, 0.15f));
        insertScaleArrow.fixedDir = gizmoRight;
    }

    void destroy() {
        shiftHandle.destroy();
        insertHandle.destroy();
        insertScaleArrow.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction. Tools
    /// built without this skip undo recording (commitBevelEdit becomes
    /// a no-op).
    void setUndoBindings(CommandHistory h, BevelEditFactory factory) {
        this.history          = h;
        this.bevelEditFactory = factory;
    }

    override string name() const { return "Bevel"; }

    override void activate() {
        active       = true;
        bevelApplied = false;
        polyOp       = PolyBevelOp.init;
        shiftAmount  = 0.0f;
        insetAmount  = 0.0f;
        dragHandle   = -1;
        ebWidth      = 0.0f;
        ebOp         = BevelOp.init;
        if (*editMode == EditMode.Edges)
            recomputeEdgeCenter();
        else
            recomputeCenter();
    }

    override void deactivate() {
        active = false;
        if (bevelApplied) {
            gpu.upload(*mesh);
            mesh.syncSelection();
            // Phase C.4: land the entire bevel session as one undo entry.
            // preBevelSnap was captured when bevel topology was first built;
            // pair it with the current mesh state as the "after" snapshot.
            commitBevelEdit();
        }
        dragHandle = -1;
    }

    override void update() {
        if (!active || dragHandle >= 0) return;
        if (*editMode == EditMode.Edges)
            recomputeEdgeCenter();
        else
            recomputeCenter();
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        if (!active) return;
        cachedVp = vp;

        bool anyFace = (*editMode == EditMode.Polygons) && mesh.faces.length > 0;
        bool anyEdge = (*editMode == EditMode.Edges)    && mesh.hasAnySelectedEdges();

        shiftHandle .setVisible(anyFace || anyEdge);
        insertHandle.setVisible(anyFace);

        if (anyFace || anyEdge) {
            float size = gizmoSize(gizmoCenter, vp);

            shiftHandle.start = gizmoCenter + gizmoNormal * (size / 6.0f);
            shiftHandle.end   = gizmoCenter + gizmoNormal * size;
            shiftHandle.setForceHovered(dragHandle == 0);
            shiftHandle.setHoverBlocked(dragHandle == 1);

            if (anyFace) {
                insertHandle.start = gizmoCenter + gizmoRight * (size / 6.0f);
                insertHandle.end   = gizmoCenter + gizmoRight * size;
                insertHandle.setForceHovered(false);
                insertHandle.setHoverBlocked(dragHandle >= 0);

                float cubeFixed = size * 0.03f;
                if (dragHandle != 1)
                    insertScaleArrow.start = insertHandle.start;
                // Visualise the inset amount on the in-plane axis. Identity
                // (inset=0) keeps the arrow at gizmoCenter; positive inset
                // shows the arrow pointing inward. Scale arbitrary; the
                // arrow is just feedback during the drag.
                insertScaleArrow.end           = gizmoCenter + gizmoRight * (size + insetAmount);
                insertScaleArrow.fixedDir      = gizmoRight;
                insertScaleArrow.fixedCubeHalf = cubeFixed;
            }
        }

        shiftHandle.draw(shader, vp);
        if (anyFace) {
            insertHandle.draw(shader, vp);
            if (dragHandle == 1 && insetAmount != 0.0f)
                insertScaleArrow.draw(shader, vp);
        }
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        bool polyMode = (*editMode == EditMode.Polygons);
        bool edgeMode = (*editMode == EditMode.Edges);

        if (!polyMode && !edgeMode) return false;
        if (mesh.faces.length == 0) return false;

        if (edgeMode && !mesh.hasAnySelectedEdges()) return false;

        // Only consume the click when it actually hits one of the gizmo
        // handles. The previous "free drag anywhere" fallback would steal
        // clicks from ImGui widgets (Width slider, Mode radios) whenever the
        // global WantCaptureMouse filter raced with the click — losing the
        // very first frame of interaction. Users who want to scrub width can
        // still drag the shift handle.
        if (shiftHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 0;
        else if (polyMode && insertHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 1;
        else
            return false;

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT || dragHandle < 0) return false;
        if (bevelApplied) {
            gpu.upload(*mesh);
            mesh.syncSelection();
        }
        dragHandle = -1;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragHandle < 0) return false;

        bool edgeMode = (*editMode == EditMode.Edges);

        // Handle drags (dragHandle 0 or 1) — commit topology on first motion.
        if (!bevelApplied) applyBevelTopology();

        if (dragHandle == 0) {
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY,
                                         gizmoCenter, gizmoNormal, cachedVp, skip);
            if (!skip) {
                if (edgeMode) {
                    float d = dot(delta, gizmoNormal);
                    ebWidth += d;
                    if (ebWidth < 0.0f) ebWidth = 0.0f;
                } else {
                    shiftAmount += dot(delta, gizmoNormal);
                    gizmoCenter  += delta;
                }
                updateBevelVertices();
                gpu.upload(*mesh);
            }
        } else {
            // Inset (polygon mode only). Additive — drag toward gizmoCenter
            // increases inset (moves boundary edges INWARD by perpendicular
            // distance). Drag outward decreases (or goes negative → outset).
            // The unit direction is gizmoRight projected to screen; the
            // signed scalar projection of (delta_mouse) onto that direction
            // (in world units) is added to insetAmount.
            float cx, cy, cndcZ, ax_, ay_, andcZ;
            if (!projectToWindowFull(gizmoCenter, cachedVp, cx, cy, cndcZ) ||
                !projectToWindowFull(gizmoCenter + gizmoRight, cachedVp, ax_, ay_, andcZ))
            { lastMX = e.x; lastMY = e.y; return true; }

            float sdx   = ax_ - cx, sdy = ay_ - cy;
            float slen2 = sdx*sdx + sdy*sdy;
            if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

            // Inverse sign — dragging the handle outward (positive screen
            // projection along gizmoRight) reduces inset; dragging inward
            // (toward gizmoCenter) increases it. Matches MODO interaction.
            float deltaWorld = -((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
            insetAmount += deltaWorld;

            updateBevelVertices();
            gpu.upload(*mesh);
        }

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override void drawProperties() {
        if (*editMode == EditMode.Edges) {
            bool widthChanged  = false;
            bool topologyDirty = false;

            // NOTE: every label here must be globally unique within this
            // window — ImGui derives widget IDs from the label hash. Mode
            // radios use `##mode` suffixes so the visible label can match
            // the DragFloat/SliderInt names without colliding (in particular,
            // RadioButton "Width" once collided with DragFloat "Width" and
            // silently broke the slider's active state).

            if (ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, 0.0f, "%.4f")) {
                if (ebWidth < 0.0f) ebWidth = 0.0f;
                widthChanged = true;
            }

            if (ImGui.Checkbox("Asymmetric", &ebAsymmetric)) {
                // Initialize R to match L so toggling ON keeps the current
                // geometry intact; the user can then dial widthR independently.
                ebWidthR = ebWidth;
                topologyDirty = true;
            }
            if (ebAsymmetric) {
                if (ImGui.DragFloat("Width R", &ebWidthR, 0.005f, 0.0f, 0.0f, "%.4f")) {
                    if (ebWidthR < 0.0f) ebWidthR = 0.0f;
                    topologyDirty = true;
                }
            }

            if (ImGui.SliderInt("Segments", &ebSeg, 1, 16)) {
                if (ebSeg < 1)  ebSeg = 1;
                if (ebSeg > 16) ebSeg = 16;
                topologyDirty = true;
            }
            if (ebSeg >= 2) {
                if (ImGui.DragFloat("Super R", &ebSuperR, 0.05f, 0.3f, 8.0f, "%.2f"))
                    topologyDirty = true;
            }

            int modeIdx = cast(int)ebMode;
            ImGui.Text("Mode:");
            BevelWidthMode prevMode = ebMode;
            bool modeJustChanged = false;
            void pickMode(BevelWidthMode m) {
                if (ebMode == m) return;
                prevMode        = ebMode;
                ebMode          = m;
                topologyDirty   = true;
                modeJustChanged = true;
            }
            if (ImGui.RadioButton("Offset##mode",  modeIdx == 0)) pickMode(BevelWidthMode.Offset);
            ImGui.SameLine();
            if (ImGui.RadioButton("Width##mode",   modeIdx == 1)) pickMode(BevelWidthMode.Width);
            ImGui.SameLine();
            if (ImGui.RadioButton("Depth##mode",   modeIdx == 2)) pickMode(BevelWidthMode.Depth);
            ImGui.SameLine();
            if (ImGui.RadioButton("Percent##mode", modeIdx == 3)) pickMode(BevelWidthMode.Percent);

            int miterIdx = cast(int)ebMiterInner;
            ImGui.Text("Miter Inner:");
            if (ImGui.RadioButton("Sharp##miter", miterIdx == 0)) {
                if (ebMiterInner != MiterPattern.Sharp) {
                    ebMiterInner = MiterPattern.Sharp;
                    topologyDirty = true;
                }
            }
            ImGui.SameLine();
            if (ImGui.RadioButton("Arc##miter",   miterIdx == 1)) {
                if (ebMiterInner != MiterPattern.Arc) {
                    ebMiterInner = MiterPattern.Arc;
                    topologyDirty = true;
                }
            }

            // Apply lazily on first user input from the property panel: any
            // width / mode / topology change implies "I want this bevel". If
            // the topology hasn't been built yet we build it now; otherwise
            // any topology-affecting change reverts and re-applies with the
            // new parameters.
            bool needBuild = (widthChanged || topologyDirty) && !bevelApplied
                              && mesh.hasAnySelectedEdges();
            if (needBuild) {
                applyEdgeBevelTopology();
            } else if (topologyDirty && bevelApplied) {
                revertEdgeBevelTopology();
                // After revert the original mesh is restored — remap ebWidth so
                // the physical bevel size stays constant across mode switches:
                //   ebWidth_new * c(newMode) = ebWidth_old * c(oldMode).
                if (modeJustChanged && ebWidth > 0.0f) {
                    uint repEdge = ~0u;
                    foreach (i, sel; mesh.selectedEdges)
                        if (sel) { repEdge = cast(uint)i; break; }
                    if (repEdge != ~0u) {
                        import bevel : widthCoefficient;
                        float cOld = widthCoefficient(mesh, repEdge, prevMode);
                        float cNew = widthCoefficient(mesh, repEdge, ebMode);
                        if (cNew > 1e-6f && cOld > 1e-6f)
                            ebWidth = ebWidth * cOld / cNew;
                    }
                }
                applyEdgeBevelTopology();
            }
            if ((widthChanged || topologyDirty) && bevelApplied) {
                updateBevelVertices();
                gpu.upload(*mesh);
            }
            return;
        }

        bool changed = false;

        ImGui.DragFloat("Shift",  &shiftAmount, 0.005f, -float.max, float.max, "%.4f");
        if (ImGui.IsItemActive()) changed = true;

        // Inset = perpendicular distance each face boundary edge moves
        // inward. Negative → outset. Identity = 0.
        ImGui.DragFloat("Inset", &insetAmount, 0.005f, -float.max, float.max, "%.4f");
        if (ImGui.IsItemActive()) changed = true;

        if (ImGui.Checkbox("Group Polygon", &groupPolygons)) {
            if (bevelApplied) {
                revertBevelTopology();
                applyBevelTopology();
                changed = true;
            }
        }

        if (changed && bevelApplied) {
            updateBevelVertices();
            gpu.upload(*mesh);
        }
    }

private:
    // ------------------------------------------------------------------
    // Dispatch by edit mode.
    // ------------------------------------------------------------------

    void applyBevelTopology() {
        // Phase C.4: snapshot pre-bevel mesh state at the moment topology
        // is first built. Subsequent revert+rebuild cycles within the
        // session (param tweaks) recapture nothing — the snapshot is
        // anchored to the original state. commitBevelEdit() at deactivate
        // pairs this with the post-state as one undo entry.
        if (!bevelApplied)
            preBevelSnap = MeshSnapshot.capture(*mesh);

        if (*editMode == EditMode.Edges)
            applyEdgeBevelTopology();
        else
            applyPolyBevelTopology();
    }

    void commitBevelEdit() {
        if (history is null || bevelEditFactory is null) return;
        if (!preBevelSnap.filled) return;
        auto cmd = bevelEditFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(preBevelSnap, post,
                         (*editMode == EditMode.Edges) ? "Edge Bevel" : "Polygon Bevel");
        history.record(cmd);
        preBevelSnap = MeshSnapshot.init;   // disarm, in case deactivate runs twice
    }

    void revertBevelTopology() {
        if (*editMode == EditMode.Edges)
            revertEdgeBevelTopology();
        else
            revertPolyBevelTopology();
    }

    void updateBevelVertices() {
        if (*editMode == EditMode.Edges)
            updateEdgeBevelVertices();
        else
            updatePolyBevelVertices();
    }

    // ------------------------------------------------------------------
    // Edge bevel: recomputeEdgeCenter
    // ------------------------------------------------------------------

    void recomputeEdgeCenter() {
        if (*editMode != EditMode.Edges) return;
        if (!mesh.hasAnySelectedEdges()) return;

        Vec3 centerSum = Vec3(0, 0, 0);
        Vec3 normalSum = Vec3(0, 0, 0);
        int  count = 0;

        foreach (ei, sel; mesh.selectedEdges) {
            if (!sel || ei >= mesh.edges.length) continue;
            uint a = mesh.edges[ei][0];
            uint b = mesh.edges[ei][1];
            Vec3 pa = mesh.vertices[a];
            Vec3 pb = mesh.vertices[b];
            // midpoint of edge
            Vec3 mid = (pa + pb) * 0.5f;
            centerSum += mid;

            // accumulate normals of adjacent faces
            foreach (fi; mesh.facesAroundEdge(cast(uint)ei))
                normalSum += mesh.faceNormal(fi);
            count++;
        }

        if (count == 0) return;

        float inv = 1.0f / cast(float)count;
        gizmoCenter = centerSum * inv;

        float nlen = normalSum.length;
        gizmoNormal = nlen > 1e-6f
            ? normalSum / nlen
            : Vec3(0, 1, 0);

        Vec3 tmp   = (gizmoNormal.x < 0.9f && gizmoNormal.x > -0.9f)
                     ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        gizmoRight = normalize(cross(gizmoNormal, tmp));
    }

    // ------------------------------------------------------------------
    // Edge bevel: apply / revert / update — delegated to source/bevel.d.
    // ------------------------------------------------------------------

    void applyEdgeBevelTopology() {
        bevelApplied = true;
        // For interactive drag we anchor slideDir at unit user widths (or
        // 1 ↔ ratio when asymmetric). The Width slider then linearly scales
        // both sides via updateEdgeBevelPositions(ebWidth).
        float wRRatio = (ebAsymmetric && ebWidth > 0.0f) ? (ebWidthR / ebWidth)
                                                          : 1.0f;
        ebOp = bevel.applyEdgeBevelTopology(mesh, mesh.selectedEdges, ebMode,
                                             1.0f, wRRatio, ebSeg, ebSuperR,
                                             ebMiterInner);

        // Selection: bevel-quad edges replace the previously selected edge ring.
        mesh.clearEdgeSelection();
        foreach (eidx; ebOp.bevelQuadEdges)
            if (eidx >= 0 && eidx < cast(int)mesh.edges.length)
                mesh.selectEdge(eidx);
    }

    void revertEdgeBevelTopology() {
        bevel.revertEdgeBevelTopology(mesh, ebOp);
        ebOp = BevelOp.init;
        bevelApplied = false;
    }

    // ------------------------------------------------------------------
    // Edge bevel: update vertex positions from ebWidth
    // ------------------------------------------------------------------

    void updateEdgeBevelVertices() {
        bevel.updateEdgeBevelPositions(mesh, ebOp, ebWidth);
    }

    void revertPolyBevelTopology() {
        poly_bevel.revertPolyBevel(mesh, polyOp);
        polyOp       = PolyBevelOp.init;
        bevelApplied = false;
    }

    void recomputeCenter() {
        if (*editMode != EditMode.Polygons || mesh.faces.length == 0) return;

        bool allFaces = !mesh.hasAnySelectedFaces();

        Vec3 centerSum = Vec3(0, 0, 0);
        Vec3 normalSum = Vec3(0, 0, 0);
        int  count = 0;

        foreach (fi, face; mesh.faces) {
            if (!allFaces && (fi >= mesh.selectedFaces.length || !mesh.selectedFaces[fi])) continue;
            if (face.length < 3) continue;

            centerSum += mesh.faceCentroid(cast(uint)fi);

            normalSum += mesh.faceNormal(cast(uint)fi);

            count++;
        }

        if (count == 0) return;

        float inv = 1.0f / cast(float)count;
        gizmoCenter = centerSum * inv;

        float nlen = sqrt(normalSum.x*normalSum.x + normalSum.y*normalSum.y + normalSum.z*normalSum.z);
        gizmoNormal = nlen > 1e-6f
            ? normalSum / nlen
            : Vec3(0, 1, 0);

        Vec3 tmp   = (gizmoNormal.x < 0.9f && gizmoNormal.x > -0.9f)
                     ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        gizmoRight = normalize(cross(gizmoNormal, tmp));
    }

    void applyPolyBevelTopology() {
        bevelApplied = true;

        // Use mesh's faceSelectionOrder so the user's selection order
        // controls which face "wins" at shared corners under group=true
        // (first-face-wins via groupVertMap inside applyPolyBevel).
        import std.algorithm.sorting : sort;
        int[] selFaceIdx;
        if (mesh.hasAnySelectedFaces()) {
            foreach (fi, sel; mesh.selectedFaces)
                if (sel && fi < mesh.faces.length) selFaceIdx ~= cast(int)fi;
            int orderOf(int fi) {
                return (fi < cast(int)mesh.faceSelectionOrder.length)
                    ? mesh.faceSelectionOrder[fi] : 0;
            }
            sort!((a, b) => orderOf(a) < orderOf(b))(selFaceIdx);
        } else {
            foreach (fi; 0 .. mesh.faces.length)
                selFaceIdx ~= cast(int)fi;
        }

        // Anchor topology at identity (inset=0, shift=0 → new verts coincide
        // with originals); subsequent updatePolyBevelVertices calls slide
        // them to the user-selected (insetAmount, shiftAmount).
        polyOp = poly_bevel.applyPolyBevel(mesh, selFaceIdx, 0.0f, 0.0f,
                                            groupPolygons);

        // Apply current scrubber values immediately (no-op when freshly
        // applied at identity).
        poly_bevel.updatePolyBevelPositions(mesh, polyOp,
                                             insetAmount, shiftAmount);
    }

    void updatePolyBevelVertices() {
        poly_bevel.updatePolyBevelPositions(mesh, polyOp,
                                             insetAmount, shiftAmount);
    }

}
