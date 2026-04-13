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

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : sqrt, abs;

// ---------------------------------------------------------------------------
// BevelTool — polygon bevel (Polygons mode) + edge bevel/chamfer (Edges mode)
//
// Polygon mode (existing):
//   shiftHandle  (Arrow)      : MoveTool-style drag along face normal → shift
//   insertHandle (CubicArrow) : ScaleTool-style drag along face tangent → inset
//
// Edge mode (new):
//   shiftHandle  (Arrow)      : drag to control chamfer width
//   Algorithm (1-segment chamfer, inspired by Blender bmesh_bevel.cc):
//     For each selected manifold edge (va, vb) shared by faces F1 (va→vb) and F2 (vb→va):
//       A1 = va + normalize(prevA_in_F1 - va) * width   (slides toward F1's prev of va)
//       A2 = va + normalize(nextA_in_F2 - va) * width   (slides toward F2's next of va)
//       B1 = vb + normalize(nextB_in_F1 - vb) * width   (slides toward F1's next of vb)
//       B2 = vb + normalize(prevB_in_F2 - vb) * width   (slides toward F2's prev of vb)
//     • ALL faces containing va or vb are modified by replacing va/vb with
//       the appropriate new vertices (determined by checking each face's
//       neighbours against capNbrA1/A2 and capNbrB1/B2).
//     • New bevel quad: [B1, A1, A2, B2]
//     • No explicit cap faces are needed — the general replacement rule
//       handles the side faces (which become pentagons).
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
    float ebWidth    = 0.0f;
    int   ebSegments = 1;     // number of bevel quads per edge (Blender "segments")

    // Per-edge data populated by applyEdgeBevelTopology().
    struct EdgeBevelEntry {
        uint va, vb;
        int[] nvsA;    // N+1 vertex indices at va: nvsA[0]=F1 side, nvsA[N]=F2 side
        int[] nvsB;    // N+1 vertex indices at vb: nvsB[0]=F1 side, nvsB[N]=F2 side
        Vec3 origA, origB;
        Vec3 dirA1, dirA2;   // offsetInPlane directions (F1 / F2) at va
        Vec3 dirB1, dirB2;   // offsetInPlane directions (F1 / F2) at vb
    }
    EdgeBevelEntry[] ebEntries;

    // Gap vertex data for junction vertices — one entry per gap-face occurrence.
    // Computed in Phase 2 using offsetMeetDir so the shared vertex lands at the
    // intersection of the two per-edge offset lines (Blender's offset_meet result).
    struct GapVertEntry { int gvi; Vec3 orig; Vec3 dir; }
    GapVertEntry[] gapEntries;

    // Original face data saved for revert — covers ALL faces modified by the bevel.
    struct EbFaceSnap { int idx; uint[] orig; }
    EbFaceSnap[] ebFaceSnaps;

    // Full vertex snapshot for edge bevel revert (va/vb are compacted out during apply).
    Vec3[] ebVertsBeforeBevel;

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
        ebEntries          = [];
        gapEntries         = [];
        ebFaceSnaps        = [];
        ebVertsBeforeBevel = [];
        shiftAmount  = 0.0f;
        insertScale  = 1.0f;
        ebWidth      = 0.0f;
        ebSegments   = 1;
        dragHandle   = -1;
        freeDragAxis = -1;
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
        bool anyEdge = (*editMode == EditMode.Edges) && mesh.hasAnySelectedEdges();

        shiftHandle .setVisible(anyFace || anyEdge);
        insertHandle.setVisible(anyFace);

        if (anyFace || anyEdge) {
            float size = gizmoSize(gizmoCenter, vp);

            shiftHandle.start = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size / 6.0f));
            shiftHandle.end   = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size));
            shiftHandle.setForceHovered(dragHandle == 0);
            shiftHandle.setHoverBlocked(dragHandle == 1);

            if (anyFace) {
                insertHandle.start = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size / 6.0f));
                insertHandle.end   = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size));
                insertHandle.setForceHovered(false);
                insertHandle.setHoverBlocked(dragHandle >= 0);

                float cubeFixed = size * 0.03f;
                if (dragHandle != 1)
                    insertScaleArrow.start = insertHandle.start;
                insertScaleArrow.end           = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size * insertScale));
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
        if (polyMode && mesh.faces.length == 0) return false;
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
                // Both axes control edge bevel width (vertical: up=more, horizontal: right=more).
                float worldScale = gizmoSize(gizmoCenter, cachedVp) * 2.0f / cachedVp.height;
                float d = freeDragAxis == 0
                    ? -(e.y - lastMY) * worldScale
                    :  (e.x - lastMX) * worldScale;
                ebWidth += d;
                if (ebWidth < 0.0f) ebWidth = 0.0f;
            } else {
                if (freeDragAxis == 0) {
                    float worldScale = gizmoSize(gizmoCenter, cachedVp) * 2.0f / cachedVp.height;
                    float d          = -(e.y - lastMY) * worldScale;
                    shiftAmount += d;
                    gizmoCenter  = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, d));
                } else {
                    float scaleFactor = 1.0f + cast(float)(e.x - lastMX) / 200.0f;
                    if (insertScale * scaleFactor < 0.0f) scaleFactor = 0.0f;
                    insertScale *= scaleFactor;
                }
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
                    ebWidth += dot(delta, gizmoNormal);
                    if (ebWidth < 0.0f) ebWidth = 0.0f;
                } else {
                    shiftAmount += dot(delta, gizmoNormal);
                    gizmoCenter  = vec3Add(gizmoCenter, delta);
                }
                updateBevelVertices();
                gpu.upload(*mesh);
            }
        } else {
            // Insert (polygon mode only).
            float cx, cy, cndcZ, ax_, ay_, andcZ;
            if (!projectToWindowFull(gizmoCenter, cachedVp, cx, cy, cndcZ) ||
                !projectToWindowFull(vec3Add(gizmoCenter, gizmoRight), cachedVp, ax_, ay_, andcZ))
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
            ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, float.max, "%.4f");
            if (ImGui.IsItemActive()) {
                if (ebWidth < 0.0f) ebWidth = 0.0f;
                if (bevelApplied) { updateBevelVertices(); gpu.upload(*mesh); }
            }

            int prevSeg = ebSegments;
            ImGui.DragInt("Segments", &ebSegments, 0.1f, 1, 8);
            if (ebSegments < 1) ebSegments = 1;
            if (ebSegments != prevSeg && bevelApplied) {
                revertEdgeBevelTopology();
                applyEdgeBevelTopology();
                updateEdgeBevelVertices();
                gpu.upload(*mesh);
            }
            return;
        }

        // Polygon mode properties.
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
    // Dispatch: route to edge or polygon implementation based on edit mode.
    // ------------------------------------------------------------------

    void applyBevelTopology() {
        if (*editMode == EditMode.Edges) { applyEdgeBevelTopology(); return; }
        applyPolyBevelTopology();
    }

    void revertBevelTopology() {
        if (*editMode == EditMode.Edges) { revertEdgeBevelTopology(); return; }
        revertPolyBevelTopology();
    }

    void updateBevelVertices() {
        if (*editMode == EditMode.Edges) { updateEdgeBevelVertices(); return; }
        updatePolyBevelVertices();
    }

    // ------------------------------------------------------------------
    // Polygon bevel — unchanged logic, renamed for clarity.
    // ------------------------------------------------------------------

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

            Vec3 c = Vec3(0, 0, 0);
            foreach (vi; face) c = vec3Add(c, mesh.vertices[vi]);
            float inv = 1.0f / cast(float)face.length;
            c = Vec3(c.x * inv, c.y * inv, c.z * inv);
            centerSum = vec3Add(centerSum, c);

            Vec3 v0 = mesh.vertices[face[0]];
            Vec3 v1 = mesh.vertices[face[1]];
            Vec3 v2 = mesh.vertices[face[2]];
            Vec3 cr = cross(vec3Sub(v1, v0), vec3Sub(v2, v0));
            float len = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
            if (len > 1e-6f)
                normalSum = vec3Add(normalSum, Vec3(cr.x/len, cr.y/len, cr.z/len));

            count++;
        }

        if (count == 0) return;

        float inv = 1.0f / cast(float)count;
        gizmoCenter = Vec3(centerSum.x * inv, centerSum.y * inv, centerSum.z * inv);

        float nlen = sqrt(normalSum.x*normalSum.x + normalSum.y*normalSum.y + normalSum.z*normalSum.z);
        gizmoNormal = nlen > 1e-6f
            ? Vec3(normalSum.x/nlen, normalSum.y/nlen, normalSum.z/nlen)
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
            foreach (p; origPos) center = vec3Add(center, p);
            float invN = 1.0f / cast(float)N;
            center = Vec3(center.x*invN, center.y*invN, center.z*invN);

            Vec3 e1 = vec3Sub(origPos[1], origPos[0]);
            Vec3 e2 = vec3Sub(origPos[2], origPos[0]);
            Vec3 cr = cross(e1, e2);
            float clen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
            Vec3 faceNormal = clen > 1e-6f
                ? Vec3(cr.x/clen, cr.y/clen, cr.z/clen)
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

    // ------------------------------------------------------------------
    // Edge bevel — chamfer selected edges by sliding their endpoints
    // along the adjacent face edges.
    // ------------------------------------------------------------------

    // Recompute gizmoCenter / gizmoNormal / gizmoRight from selected edges.
    void recomputeEdgeCenter() {
        if (!mesh.hasAnySelectedEdges()) return;

        Vec3 centerSum = Vec3(0, 0, 0);
        Vec3 normalSum = Vec3(0, 0, 0);
        int  count = 0;

        foreach (ei; 0 .. mesh.edges.length) {
            if (ei >= mesh.selectedEdges.length || !mesh.selectedEdges[ei]) continue;
            uint va = mesh.edges[ei][0];
            uint vb = mesh.edges[ei][1];
            Vec3 a = mesh.vertices[va];
            Vec3 b = mesh.vertices[vb];
            centerSum = vec3Add(centerSum, vec3Scale(vec3Add(a, b), 0.5f));
            count++;

            // Average the normals of faces adjacent to this edge.
            foreach (face; mesh.faces) {
                int N = cast(int)face.length;
                if (N < 3) continue;
                foreach (i; 0 .. N) {
                    uint fa = face[i], fb = face[(i + 1) % N];
                    if ((fa == va && fb == vb) || (fa == vb && fb == va)) {
                        Vec3 v0 = mesh.vertices[face[0]];
                        Vec3 v1 = mesh.vertices[face[1]];
                        Vec3 v2 = mesh.vertices[face[2]];
                        Vec3 cr = cross(vec3Sub(v1, v0), vec3Sub(v2, v0));
                        float len = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
                        if (len > 1e-6f)
                            normalSum = vec3Add(normalSum, Vec3(cr.x/len, cr.y/len, cr.z/len));
                        break;
                    }
                }
            }
        }

        if (count == 0) return;

        float inv = 1.0f / cast(float)count;
        gizmoCenter = vec3Scale(centerSum, inv);

        float nlen = sqrt(normalSum.x*normalSum.x + normalSum.y*normalSum.y + normalSum.z*normalSum.z);
        gizmoNormal = nlen > 1e-6f
            ? Vec3(normalSum.x/nlen, normalSum.y/nlen, normalSum.z/nlen)
            : Vec3(0, 1, 0);

        Vec3 tmp   = (gizmoNormal.x < 0.9f && gizmoNormal.x > -0.9f)
                     ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        gizmoRight = normalize(cross(gizmoNormal, tmp));
    }

    // First drag in edge mode: build chamfer topology using half-edge loops.
    //
    // For each selected manifold edge (va, vb) the two adjacent faces F1 (va→vb)
    // and F2 (vb→va) are identified via mesh.loops.  Four slide directions are
    // computed and four new vertices created (one per endpoint per face).
    // Junction vertices (shared by ≥2 selected edges) reuse one shared "gap vertex"
    // per gap face (face where both prev and next of the junction are bevel neighbours)
    // — the same logic as Blender's offset_meet / gap-face handling.
    //
    // Face rebuild follows bev_rebuild_polygon: walk each affected face's loop ring;
    // where a loop is in loopNewVert substitute the new vertex, otherwise keep the
    // original.  The original va/vb vertices are then compacted out.
    void applyEdgeBevelTopology() {
        ebEntries          = [];
        ebFaceSnaps        = [];
        bevelApplied       = true;
        bevelFaceStart     = mesh.faces.length;

        edgesBeforeBevel     = mesh.edges.dup;
        selEdgesBeforeBevel  = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;
        ebVertsBeforeBevel   = mesh.vertices.dup;

        // ---- Build directed-loop map from current mesh loops ----
        uint[ulong] dirLoopMap;   // (u<<32|v) → loop index for directed edge u→v
        foreach (li; 0 .. mesh.loops.length) {
            uint u = mesh.loops[li].vert;
            uint v = mesh.loops[mesh.loops[li].next].vert;
            dirLoopMap[(cast(ulong)u << 32) | v] = cast(uint)li;
        }

        // ---- Collect selected manifold edges with their four loop indices ----
        struct SelEdge {
            uint va, vb;
            uint liF1_va;   // loop at va in F1 (dart va→vb)
            uint liF1_vb;   // loop at vb in F1 (= liF1_va.next)
            uint liF2_vb;   // loop at vb in F2 (dart vb→va)
            uint liF2_va;   // loop at va in F2 (= liF2_vb.next)
        }
        SelEdge[] sel;

        foreach (ei; 0 .. mesh.edges.length) {
            if (ei >= mesh.selectedEdges.length || !mesh.selectedEdges[ei]) continue;
            uint va = mesh.edges[ei][0];
            uint vb = mesh.edges[ei][1];
            auto p1 = (cast(ulong)va << 32 | vb) in dirLoopMap;
            auto p2 = (cast(ulong)vb << 32 | va) in dirLoopMap;
            if (!p1 || !p2) continue;   // boundary / non-manifold — skip
            uint l1 = *p1, l2 = *p2;
            sel ~= SelEdge(va, vb, l1, mesh.loops[l1].next, l2, mesh.loops[l2].next);
        }

        if (sel.length == 0) { bevelApplied = false; return; }

        // ---- Junction vertices (appear in ≥2 selected edges) ----
        int[uint] vertSelCount;
        foreach (ref s; sel) {
            vertSelCount[s.va]++;
            vertSelCount[s.vb]++;
        }
        bool[uint] junctionVerts;
        foreach (v, cnt; vertSelCount)
            if (cnt >= 2) junctionVerts[v] = true;

        // ---- Pre-pass: shared gap vertices for junction vertices ----
        // A gap loop is a loop li at junction vertex jv where both the prev vertex
        // and the next vertex in the face are bevel neighbours of jv.  All gap loops
        // of jv in the same face share one gap vertex.
        uint[uint]   gapLoopVert;  // loop_idx → gap vertex index
        uint[][uint] jCapOrder;    // jv → ordered cap polygon verts (N≥3 edges)

        foreach (jv; junctionVerts.byKey()) {
            bool[uint] bevelNbrs;
            foreach (ref s2; sel) {
                if (s2.va == jv) bevelNbrs[s2.vb] = true;
                if (s2.vb == jv) bevelNbrs[s2.va] = true;
            }
            if (bevelNbrs.length < 2) continue;

            uint[] capVerts;
            Vec3[] capDirs;        // offset-meet direction per cap vert (for winding check)
            Vec3 avgFaceNorm = Vec3(0, 0, 0);
            uint startLi = mesh.vertLoop[jv];
            if (startLi == ~0u) continue;
            uint li = startLi;
            for (int step = 0; step < 256; step++) {
                uint prevV = mesh.loops[mesh.loops[li].prev].vert;
                uint nextV = mesh.loops[mesh.loops[li].next].vert;
                if ((prevV in bevelNbrs) && (nextV in bevelNbrs)) {
                    Vec3 gfn = polyNormal(mesh.faces[mesh.loops[li].face], mesh.vertices);
                    avgFaceNorm = vec3Add(avgFaceNorm, gfn);
                    if ((li in gapLoopVert) == null) {
                        int gvi = cast(int)mesh.addVertex(mesh.vertices[jv]);
                        gapLoopVert[li] = cast(uint)gvi;
                        capVerts ~= cast(uint)gvi;
                        // e1, e2 — directions FROM jv along each bevel edge (Blender offset_meet convention)
                        Vec3 e1 = safeNormalize(vec3Sub(mesh.vertices[prevV], mesh.vertices[jv]));
                        Vec3 e2 = safeNormalize(vec3Sub(mesh.vertices[nextV], mesh.vertices[jv]));
                        Vec3 gDir = offsetMeetDir(e1, e2, gfn);
                        capDirs ~= gDir;
                        gapEntries ~= GapVertEntry(gvi, mesh.vertices[jv], gDir);
                    } else {
                        capVerts ~= gapLoopVert[li];
                        // Find existing gDir for this gap vert.
                        int gvIdx = cast(int)gapLoopVert[li];
                        Vec3 existDir = Vec3(0, 0, 0);
                        foreach (ref ge; gapEntries)
                            if (ge.gvi == gvIdx) { existDir = ge.dir; break; }
                        capDirs ~= existDir;
                    }
                }
                if (mesh.loops[li].twin == ~0u) break;
                li = mesh.loops[mesh.loops[li].twin].next;
                if (li == startLi) break;
            }
            if (capVerts.length >= 3) {
                // Check cap winding: cap polygon normal (from offset directions)
                // must agree with average face normal at jv.
                Vec3 d01 = vec3Sub(capDirs[1], capDirs[0]);
                Vec3 d02 = vec3Sub(capDirs[2], capDirs[0]);
                Vec3 capNorm = cross(d01, d02);
                if (dot(capNorm, avgFaceNorm) < 0.0f) {
                    // Reverse cap polygon winding.
                    for (int i = 0, j = cast(int)capVerts.length - 1; i < j; i++, j--) {
                        uint tv = capVerts[i]; capVerts[i] = capVerts[j]; capVerts[j] = tv;
                    }
                }
                jCapOrder[jv] = capVerts;
            }
        }

        // ---- Per-edge: compute slide directions, create new vertices ----
        // loopNewVerts[loop_idx] = chain of new vertices that replaces the original vertex.
        // For faces sharing the beveled edge (F1/F2): chain has 1 element.
        // For "span" faces (contain both cap neighbors of a bevel endpoint): chain has N+1 elements.
        // Blender bev_rebuild_polygon: ALL faces containing a beveled vertex are rebuilt.
        int[][uint] loopNewVerts;

        foreach (ref s; sel) {
            Vec3 va_pos = mesh.vertices[s.va];
            Vec3 vb_pos = mesh.vertices[s.vb];

            // Blender offset_in_plane: slide perpendicular to the bevel edge in each face plane.
            // edgeDir (va→vb) is used for F1; reversed for F2 (because F2 traverses vb→va).
            Vec3 faceNormF1 = polyNormal(mesh.faces[mesh.loops[s.liF1_va].face], mesh.vertices);
            Vec3 faceNormF2 = polyNormal(mesh.faces[mesh.loops[s.liF2_va].face], mesh.vertices);
            Vec3 edgeDir    = safeNormalize(vec3Sub(vb_pos, va_pos));

            Vec3 dirA1 = offsetInPlane(edgeDir,          faceNormF1);  // va in F1
            Vec3 dirB1 = offsetInPlane(edgeDir,          faceNormF1);  // vb in F1
            Vec3 dirA2 = offsetInPlane(vec3Neg(edgeDir), faceNormF2);  // va in F2
            Vec3 dirB2 = offsetInPlane(vec3Neg(edgeDir), faceNormF2);  // vb in F2

            // Cap neighbors: the vertices va/vb slide toward in F1 / F2.
            // capNbrA1 = prev of va in F1, capNbrA2 = next of va in F2.
            uint capNbrA1 = mesh.loops[mesh.loops[s.liF1_va].prev].vert;
            uint capNbrA2 = mesh.loops[mesh.loops[s.liF2_va].next].vert;
            uint capNbrB1 = mesh.loops[mesh.loops[s.liF1_vb].next].vert;
            uint capNbrB2 = mesh.loops[mesh.loops[s.liF2_vb].prev].vert;

            // Create N+1 profile vertices per endpoint (indices 0=F1-side, N=F2-side).
            int[] nvsA = new int[](ebSegments + 1);
            int[] nvsB = new int[](ebSegments + 1);

            nvsA[0] = (s.liF1_va in gapLoopVert)
                ? cast(int)gapLoopVert[s.liF1_va]
                : cast(int)mesh.addVertex(va_pos);
            nvsA[ebSegments] = (s.liF2_va in gapLoopVert)
                ? cast(int)gapLoopVert[s.liF2_va]
                : cast(int)mesh.addVertex(va_pos);
            nvsB[0] = (s.liF1_vb in gapLoopVert)
                ? cast(int)gapLoopVert[s.liF1_vb]
                : cast(int)mesh.addVertex(vb_pos);
            nvsB[ebSegments] = (s.liF2_vb in gapLoopVert)
                ? cast(int)gapLoopVert[s.liF2_vb]
                : cast(int)mesh.addVertex(vb_pos);

            // Middle profile vertices (only for ebSegments > 1).
            for (int k = 1; k < ebSegments; k++) {
                nvsA[k] = cast(int)mesh.addVertex(va_pos);
                nvsB[k] = cast(int)mesh.addVertex(vb_pos);
            }

            // Direct assignments: the two faces that share the bevel edge.
            // liF1_va → F1 side (nvsA[0]), liF2_va → F2 side (nvsA[N]).
            // Gap loops are already in gapLoopVert and their vertex is nvsA[0/N].
            loopNewVerts[s.liF1_va] = [nvsA[0]];
            loopNewVerts[s.liF2_va] = [nvsA[ebSegments]];
            loopNewVerts[s.liF1_vb] = [nvsB[0]];
            loopNewVerts[s.liF2_vb] = [nvsB[ebSegments]];

            // For non-junction vertices with N>1 segments: also update the "span" face
            // (the face at va/vb that contains BOTH cap neighbors but NOT the bevel edge).
            // Blender's bev_rebuild_polygon inserts the full profile chain there.
            // if (ebSegments > 1) {
                int[] nvsA_rev = nvsA.dup; {
                    for (int i=0, j=cast(int)nvsA_rev.length-1; i<j; i++, j--) {
                        int t = nvsA_rev[i]; nvsA_rev[i] = nvsA_rev[j]; nvsA_rev[j] = t;
                    }
                }
                int[] nvsB_rev = nvsB.dup; {
                    for (int i=0, j=cast(int)nvsB_rev.length-1; i<j; i++, j--) {
                        int t = nvsB_rev[i]; nvsB_rev[i] = nvsB_rev[j]; nvsB_rev[j] = t;
                    }
                }

                // Walk ALL faces around va / vb (non-junction only).
                // Faces before the span face → nvsA[0]; span face → full chain;
                // faces after the span face → nvsA[N].
                // This ensures every face that contains va (which will be compacted
                // away) is updated, not just the span face.
                if (!(s.va in junctionVerts)) {
                    uint startLi = s.liF1_va;
                    uint li = startLi;
                    bool pastSpan = false;
                    for (int step = 0; step < 256; step++) {
                        if ((li in loopNewVerts) == null && (li in gapLoopVert) == null) {
                            uint prevV = mesh.loops[mesh.loops[li].prev].vert;
                            uint nextV = mesh.loops[mesh.loops[li].next].vert;
                            if (prevV == capNbrA1 && nextV == capNbrA2) {
                                loopNewVerts[li] = nvsA;
                                pastSpan = true;
                            } else if (prevV == capNbrA2 && nextV == capNbrA1) {
                                loopNewVerts[li] = nvsA_rev;
                                pastSpan = true;
                            } else if (!pastSpan) {
                                loopNewVerts[li] = [nvsA[0]];
                            } else {
                                loopNewVerts[li] = [nvsA[ebSegments]];
                            }
                        }
                        if (mesh.loops[li].twin == ~0u) break;
                        li = mesh.loops[mesh.loops[li].twin].next;
                        if (li == startLi) break;
                    }
                }

                // Walk vb.
                if (!(s.vb in junctionVerts)) {
                    uint startLi = s.liF1_vb;
                    uint li = startLi;
                    bool pastSpan = false;
                    for (int step = 0; step < 256; step++) {
                        if ((li in loopNewVerts) == null && (li in gapLoopVert) == null) {
                            uint prevV = mesh.loops[mesh.loops[li].prev].vert;
                            uint nextV = mesh.loops[mesh.loops[li].next].vert;
                            if (prevV == capNbrB1 && nextV == capNbrB2) {
                                loopNewVerts[li] = nvsB;
                                pastSpan = true;
                            } else if (prevV == capNbrB2 && nextV == capNbrB1) {
                                loopNewVerts[li] = nvsB_rev;
                                pastSpan = true;
                            } else if (!pastSpan) {
                                loopNewVerts[li] = [nvsB[0]];
                            } else {
                                loopNewVerts[li] = [nvsB[ebSegments]];
                            }
                        }
                        if (mesh.loops[li].twin == ~0u) break;
                        li = mesh.loops[mesh.loops[li].twin].next;
                        if (li == startLi) break;
                    }
                }
            // }

            EdgeBevelEntry entry;
            entry.va   = s.va;  entry.vb   = s.vb;
            entry.nvsA = nvsA;  entry.nvsB = nvsB;
            entry.origA = va_pos; entry.origB = vb_pos;
            entry.dirA1 = dirA1; entry.dirA2 = dirA2;
            entry.dirB1 = dirB1; entry.dirB2 = dirB2;
            ebEntries ~= entry;
        }

        // ---- Collect affected faces (now ALL faces containing any beveled vertex) ----
        bool[uint] affectedFaces;
        foreach (li; loopNewVerts.byKey())
            affectedFaces[mesh.loops[li].face] = true;

        // ---- Rebuild each affected face (bev_rebuild_polygon style) ----
        // For each loop: substitute with chain if mapped, otherwise keep original vertex.
        foreach (fi; affectedFaces.byKey()) {
            ebFaceSnaps ~= EbFaceSnap(fi, mesh.faces[fi].dup);

            uint[] newFace;
            newFace.reserve(mesh.faces[fi].length + ebSegments + 1);
            uint li = mesh.faceLoop[fi];
            do {
                if (auto pchain = li in loopNewVerts)
                    foreach (v; *pchain) newFace ~= cast(uint)v;
                else
                    newFace ~= mesh.loops[li].vert;
                li = mesh.loops[li].next;
            } while (li != mesh.faceLoop[fi]);
            mesh.faces[fi] = newFace;
        }

        // ---- Add N bevel quads per edge: [B[k], A[k], A[k+1], B[k+1]] ----
        foreach (ref entry; ebEntries) {
            for (int k = 0; k < ebSegments; k++)
                mesh.faces ~= [cast(uint)entry.nvsB[k],   cast(uint)entry.nvsA[k],
                               cast(uint)entry.nvsA[k+1], cast(uint)entry.nvsB[k+1]];
        }

        // ---- Add outer cap polygons for M≥3 junction vertices (ring 0) ----
        foreach (jv2, capPoly; jCapOrder)
            mesh.faces ~= capPoly;

        // ---- Add inner cap rings for M≥3 junctions (rings 1..N-1) ----
        // Use profile[k] directly (consistent lerp t=k/N) — no reversal.
        if (ebSegments > 1) {
            bool[int] gapVertSet;
            foreach (ref ge; gapEntries) gapVertSet[ge.gvi] = true;

            // Map: gap vertex → raw profile (nvsA or nvsB as-is, index k = lerp t=k/N).
            int[][int] gapProfile;
            foreach (ref entry; ebEntries) {
                if (entry.nvsA[0] in gapVertSet)
                    gapProfile[entry.nvsA[0]] = entry.nvsA;
                else if (entry.nvsA[$-1] in gapVertSet)
                    gapProfile[entry.nvsA[$-1]] = entry.nvsA;

                if (entry.nvsB[0] in gapVertSet)
                    gapProfile[entry.nvsB[0]] = entry.nvsB;
                else if (entry.nvsB[$-1] in gapVertSet)
                    gapProfile[entry.nvsB[$-1]] = entry.nvsB;
            }

            foreach (jv2, capPoly; jCapOrder) {
                for (int k = 1; k < ebSegments; k++) {
                    uint[] innerCap;
                    foreach (gv; capPoly) {
                        auto pRef = cast(int)gv in gapProfile;
                        if (pRef) innerCap ~= cast(uint)(*pRef)[k];
                    }
                    if (innerCap.length == capPoly.length && innerCap.length >= 3)
                        mesh.faces ~= innerCap;
                }
            }
        }

        // ---- Compact: remove original va/vb (now unreferenced) ----
        bool[] referenced;
        referenced.length = mesh.vertices.length;
        foreach (ref face; mesh.faces)
            foreach (v; face) referenced[v] = true;

        int[] remap;
        remap.length = cast(int)mesh.vertices.length;
        Vec3[] newVerts;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!referenced[i]) {
                remap[i] = -1;
            } else {
                remap[i] = cast(int)newVerts.length;
                newVerts ~= mesh.vertices[i];
            }
        }
        mesh.vertices = newVerts;

        foreach (ref face; mesh.faces)
            foreach (ref v; face) v = cast(uint)remap[v];

        foreach (ref entry; ebEntries) {
            foreach (ref v; entry.nvsA) v = remap[v];
            foreach (ref v; entry.nvsB) v = remap[v];
        }
        foreach (ref ge; gapEntries)
            ge.gvi = remap[ge.gvi];

        // ---- Rebuild edge list from faces ----
        mesh.edges.length = 0;
        mesh.selectedEdges.length = 0;
        mesh.edgeSelectionOrder.length = 0;
        {
            bool[ulong] seen;
            foreach (ref face; mesh.faces) {
                int N = cast(int)face.length;
                for (int i = 0; i < N; i++) {
                    uint a = face[i], b = face[(i + 1) % N];
                    uint lo = a < b ? a : b, hi = a < b ? b : a;
                    ulong key = (cast(ulong)lo << 32) | hi;
                    if (key !in seen) {
                        seen[key] = true;
                        mesh.edges ~= [a, b];
                    }
                }
            }
        }

        mesh.syncSelection();
        mesh.buildLoops();
    }

    // Restore mesh to state before applyEdgeBevelTopology().
    void revertEdgeBevelTopology() {
        foreach (ref snap; ebFaceSnaps)
            mesh.faces[snap.idx] = snap.orig;   // restore original va/vb indices
        mesh.faces.length       = bevelFaceStart;
        mesh.vertices           = ebVertsBeforeBevel;   // restores va and vb
        mesh.edges              = edgesBeforeBevel;
        mesh.selectedEdges      = selEdgesBeforeBevel;
        mesh.edgeSelectionOrder = edgeOrderBeforeBevel;
        bevelApplied       = false;
        ebEntries          = [];
        gapEntries         = [];
        ebFaceSnaps        = [];
        ebVertsBeforeBevel = [];
        mesh.syncSelection();
        mesh.buildLoops();
    }

    // Reposition all profile vertices for every chamfered edge.
    // For a flat (straight) profile: lerp between the two endpoint positions (Blender).
    // new_pos(k) = lerp(origA + dirA1*w, origA + dirA2*w, k/N)
    void updateEdgeBevelVertices() {
        int ns = ebSegments;
        foreach (ref entry; ebEntries) {
            Vec3 posA0 = vec3Add(entry.origA, vec3Scale(entry.dirA1, ebWidth));
            Vec3 posAN = vec3Add(entry.origA, vec3Scale(entry.dirA2, ebWidth));
            Vec3 posB0 = vec3Add(entry.origB, vec3Scale(entry.dirB1, ebWidth));
            Vec3 posBN = vec3Add(entry.origB, vec3Scale(entry.dirB2, ebWidth));
            Vec3 dA = vec3Sub(posAN, posA0);
            Vec3 dB = vec3Sub(posBN, posB0);
            for (int k = 0; k <= ns; k++) {
                float t = ns > 0 ? cast(float)k / ns : 0.0f;
                mesh.vertices[entry.nvsA[k]] = vec3Add(posA0, vec3Scale(dA, t));
                mesh.vertices[entry.nvsB[k]] = vec3Add(posB0, vec3Scale(dB, t));
            }
        }
        // Override gap (junction) vertices: placed at the offsetMeetDir intersection.
        foreach (ref ge; gapEntries)
            mesh.vertices[ge.gvi] = vec3Add(ge.orig, vec3Scale(ge.dir, ebWidth));
    }
}
