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

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt, abs;

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
    float shiftAmount   = 0.0f;
    float insertScale   = 1.0f;
    bool  groupPolygons = false;

    Vec3 groupCenter;
    Vec3 groupNormal;

    // ---- Topology snapshot (shared by polygon and edge bevel) ----
    bool bevelApplied = false;

    struct BevelFaceData {
        Vec3[]  origPos;
        int[]   newVerts;
        Vec3    center;
        Vec3    normal;
        int     origFaceIdx;
        uint[]  origFaceVerts;
    }
    BevelFaceData[] bevelFaces;

    size_t    bevelVertStart;
    size_t    bevelFaceStart;
    uint[2][] edgesBeforeBevel;
    bool[]    selEdgesBeforeBevel;
    int[]     edgeOrderBeforeBevel;

    // ---- Edge bevel parameters ----
    float   ebWidth = 0.0f;
    BevelOp ebOp;

    // ---- Drag state ----
    int      dragHandle = -1;   // 0=shift/width, 1=insert, 2=free, -1=none
    int      lastMX, lastMY;
    Viewport cachedVp;

    int  freeDragAxis    = -1;
    int  freeDragStartMX, freeDragStartMY;

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

    override string name() const { return "Bevel"; }

    override void activate() {
        active       = true;
        bevelApplied = false;
        bevelFaces   = [];
        shiftAmount  = 0.0f;
        insertScale  = 1.0f;
        dragHandle   = -1;
        freeDragAxis = -1;
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
                insertScaleArrow.end           = gizmoCenter + gizmoRight * (size * insertScale);
                insertScaleArrow.fixedDir      = gizmoRight;
                insertScaleArrow.fixedCubeHalf = cubeFixed;
            }
        }

        shiftHandle.draw(shader, vp);
        if (anyFace) {
            insertHandle.draw(shader, vp);
            if (dragHandle == 1 && insertScale != 0.0f)
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

        if (shiftHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 0;
        else if (polyMode && insertHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 1;
        else {
            dragHandle      = 2;
            freeDragAxis    = -1;
            freeDragStartMX = e.x;
            freeDragStartMY = e.y;
        }

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
        dragHandle   = -1;
        freeDragAxis = -1;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (!active || dragHandle < 0) return false;

        bool edgeMode = (*editMode == EditMode.Edges);

        if (dragHandle == 2) {
            // Free drag: wait for enough movement to determine axis.
            if (freeDragAxis < 0) {
                int tdx = e.x - freeDragStartMX;
                int tdy = e.y - freeDragStartMY;
                if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }
                freeDragAxis = (abs(tdx) >= abs(tdy)) ? 1 : 0;
                if (!bevelApplied) applyBevelTopology();
                lastMX = e.x; lastMY = e.y; return true;
            }

            if (edgeMode) {
                // In edge mode, both axes increase width (use the larger absolute delta).
                float worldScale = gizmoSize(gizmoCenter, cachedVp) * 2.0f / cachedVp.height;
                float dx = cast(float)(e.x - lastMX);
                float dy = -(cast(float)(e.y - lastMY));
                float d  = (abs(dx) >= abs(dy)) ? dx * worldScale : dy * worldScale;
                ebWidth += d;
                if (ebWidth < 0.0f) ebWidth = 0.0f;
            } else if (freeDragAxis == 0) {
                float worldScale = gizmoSize(gizmoCenter, cachedVp) * 2.0f / cachedVp.height;
                float d          = -(e.y - lastMY) * worldScale;
                shiftAmount += d;
                gizmoCenter  += gizmoNormal * d;
            } else {
                float scaleFactor = 1.0f + cast(float)(e.x - lastMX) / 200.0f;
                if (insertScale * scaleFactor < 0.0f) scaleFactor = 0.0f;
                insertScale *= scaleFactor;
            }

            updateBevelVertices();
            gpu.upload(*mesh);
            lastMX = e.x; lastMY = e.y;
            return true;
        }

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
            // Insert (polygon mode only).
            float cx, cy, cndcZ, ax_, ay_, andcZ;
            if (!projectToWindowFull(gizmoCenter, cachedVp, cx, cy, cndcZ) ||
                !projectToWindowFull(gizmoCenter + gizmoRight, cachedVp, ax_, ay_, andcZ))
            { lastMX = e.x; lastMY = e.y; return true; }

            float sdx   = ax_ - cx, sdy = ay_ - cy;
            float slen2 = sdx*sdx + sdy*sdy;
            if (slen2 < 1.0f) { lastMX = e.x; lastMY = e.y; return true; }

            float delta       = ((e.x - lastMX) * sdx + (e.y - lastMY) * sdy) / slen2;
            float scaleFactor = 1.0f + delta;
            if (insertScale * scaleFactor < 0.0f) scaleFactor = 0.0f;
            insertScale *= scaleFactor;

            updateBevelVertices();
            gpu.upload(*mesh);
        }

        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    override void drawProperties() {
        if (*editMode == EditMode.Edges) {
            bool changed = false;
            ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, float.max, "%.4f");
            if (ImGui.IsItemActive()) {
                if (ebWidth < 0.0f) ebWidth = 0.0f;
                changed = true;
            }
            if (changed && bevelApplied) {
                updateBevelVertices();
                gpu.upload(*mesh);
            }
            return;
        }

        bool changed = false;

        ImGui.DragFloat("Shift",  &shiftAmount, 0.005f, -float.max, float.max, "%.4f");
        if (ImGui.IsItemActive()) changed = true;

        ImGui.DragFloat("Insert", &insertScale, 0.005f, 0.0f, float.max, "%.4f");
        if (ImGui.IsItemActive()) {
            if (insertScale < 0.0f) insertScale = 0.0f;
            changed = true;
        }

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
        if (*editMode == EditMode.Edges)
            applyEdgeBevelTopology();
        else
            applyPolyBevelTopology();
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
        ebOp = bevel.applyEdgeBevelTopology(mesh, mesh.selectedEdges);

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
        foreach (ref bfd; bevelFaces)
            mesh.faces[bfd.origFaceIdx] = bfd.origFaceVerts;
        mesh.vertices.length    = bevelVertStart;
        mesh.faces.length       = bevelFaceStart;
        mesh.edges              = edgesBeforeBevel;
        mesh.selectedEdges      = selEdgesBeforeBevel;
        mesh.edgeSelectionOrder = edgeOrderBeforeBevel;
        bevelApplied = false;
        bevelFaces   = [];
        mesh.syncSelection();
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
        bevelFaces     = [];
        bevelApplied   = true;
        groupCenter    = gizmoCenter;
        groupNormal    = gizmoNormal;
        bevelVertStart = mesh.vertices.length;
        bevelFaceStart = mesh.faces.length;

        edgesBeforeBevel     = mesh.edges.dup;
        selEdgesBeforeBevel  = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;

        int[] selFaceIdx;
        if (mesh.hasAnySelectedFaces()) {
            foreach (fi, sel; mesh.selectedFaces)
                if (sel && fi < mesh.faces.length) selFaceIdx ~= cast(int)fi;
        } else {
            foreach (fi; 0 .. mesh.faces.length)
                selFaceIdx ~= cast(int)fi;
        }

        bool[ulong] internalEdgeSet;
        int[uint]   groupVertMap;

        if (groupPolygons) {
            bool[ulong] selEdges;
            foreach (fi; selFaceIdx) {
                auto face = mesh.faces[fi];
                int M = cast(int)face.length;
                foreach (i; 0 .. M) {
                    ulong key = (cast(ulong)face[i] << 32) | face[(i + 1) % M];
                    selEdges[key] = true;
                }
            }
            foreach (key; selEdges.byKey()) {
                uint a = cast(uint)(key >> 32);
                uint b = cast(uint)(key & 0xFFFF_FFFF);
                ulong rev = (cast(ulong)b << 32) | a;
                if (rev in selEdges)
                    internalEdgeSet[key] = true;
            }

            if (internalEdgeSet.length > 0) {
                bool[ulong] internalPairs;
                foreach (key; internalEdgeSet.byKey()) {
                    uint a = cast(uint)(key >> 32);
                    uint b = cast(uint)(key & 0xFFFF_FFFF);
                    uint mn = a < b ? a : b, mx = a < b ? b : a;
                    internalPairs[(cast(ulong)mn << 32) | mx] = true;
                }
                uint[2][] kept;
                bool[]    keptSel;
                int[]     keptOrd;
                foreach (ei, e; mesh.edges) {
                    uint mn = e[0] < e[1] ? e[0] : e[1];
                    uint mx = e[0] < e[1] ? e[1] : e[0];
                    if (((cast(ulong)mn << 32) | mx) in internalPairs) continue;
                    kept    ~= e;
                    keptSel ~= ei < mesh.selectedEdges.length     ? mesh.selectedEdges[ei]      : false;
                    keptOrd ~= ei < mesh.edgeSelectionOrder.length ? mesh.edgeSelectionOrder[ei] : 0;
                }
                mesh.edges              = kept;
                mesh.selectedEdges      = keptSel;
                mesh.edgeSelectionOrder = keptOrd;
            }
        }

        foreach (origFi; selFaceIdx) {
            uint[] origFaceVerts = mesh.faces[origFi].dup;
            int N = cast(int)origFaceVerts.length;
            if (N < 3) continue;

            Vec3[] origPos = new Vec3[](N);
            foreach (i; 0 .. N)
                origPos[i] = mesh.vertices[origFaceVerts[i]];

            Vec3 center = Vec3(0, 0, 0);
            foreach (p; origPos) center += p;
            float invN = 1.0f / cast(float)N;
            center = center * invN;

            Vec3 e1 = origPos[1] - origPos[0];
            Vec3 e2 = origPos[2] - origPos[0];
            Vec3 cr = cross(e1, e2);
            float clen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
            Vec3 faceNormal = clen > 1e-6f
                ? cr / clen
                : Vec3(0, 1, 0);

            int[] newVerts = new int[](N);
            foreach (i; 0 .. N) {
                if (groupPolygons) {
                    uint ov = origFaceVerts[i];
                    if (auto p = ov in groupVertMap) {
                        newVerts[i] = *p;
                    } else {
                        int nv = cast(int)mesh.addVertex(origPos[i]);
                        newVerts[i]      = nv;
                        groupVertMap[ov] = nv;
                    }
                } else {
                    newVerts[i] = cast(int)mesh.addVertex(origPos[i]);
                }
            }

            uint[] topFace = new uint[](N);
            foreach (i; 0 .. N) topFace[i] = cast(uint)newVerts[i];
            mesh.faces[origFi] = topFace;

            foreach (i; 0 .. N) {
                int next = (i + 1) % N;
                if (groupPolygons) {
                    ulong key = (cast(ulong)origFaceVerts[i] << 32) | origFaceVerts[next];
                    if (key in internalEdgeSet) continue;
                }
                mesh.addFace([origFaceVerts[i],        origFaceVerts[next],
                              cast(uint)newVerts[next], cast(uint)newVerts[i]]);
            }

            BevelFaceData bfd;
            bfd.origPos       = origPos;
            bfd.newVerts      = newVerts;
            bfd.center        = center;
            bfd.normal        = faceNormal;
            bfd.origFaceIdx   = origFi;
            bfd.origFaceVerts = origFaceVerts;
            bevelFaces       ~= bfd;
        }

        mesh.syncSelection();
    }

    void updatePolyBevelVertices() {
        foreach (ref bfd; bevelFaces) {
            Vec3 useCenter = groupPolygons ? groupCenter : bfd.center;
            Vec3 useNormal = groupPolygons ? groupNormal : bfd.normal;
            int N = cast(int)bfd.newVerts.length;
            foreach (i; 0 .. N) {
                Vec3 orig = bfd.origPos[i];
                mesh.vertices[bfd.newVerts[i]] = Vec3(
                    useCenter.x + (orig.x - useCenter.x) * insertScale + useNormal.x * shiftAmount,
                    useCenter.y + (orig.y - useCenter.y) * insertScale + useNormal.y * shiftAmount,
                    useCenter.z + (orig.z - useCenter.z) * insertScale + useNormal.z * shiftAmount,
                );
            }
        }
    }

}
