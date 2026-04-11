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

// Safe normalize — returns (0,1,0) when the vector is near-zero.
private Vec3 safeNorm(Vec3 v) {
    float len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    return len > 1e-6f ? Vec3(v.x/len, v.y/len, v.z/len) : Vec3(0, 1, 0);
}

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
    float ebWidth = 0.0f;

    // Per-edge data populated by applyEdgeBevelTopology().
    struct EdgeBevelEntry {
        uint va, vb;
        int nvA1, nvA2;      // new vertex indices at va (A1 slides toward capNbrA1, A2 toward capNbrA2)
        int nvB1, nvB2;      // new vertex indices at vb
        Vec3 origA, origB;   // va/vb positions at bevel time
        Vec3 dirA1, dirA2;   // normalized slide directions at va
        Vec3 dirB1, dirB2;   // normalized slide directions at vb
        // Slide-target vertex indices — the neighbours in F1/F2 that each new vert
        // slides toward.  Used to route replacements in ALL faces containing va/vb.
        //   A1 slides toward capNbrA1 (= prevA in F1)
        //   A2 slides toward capNbrA2 (= nextA in F2)
        //   B1 slides toward capNbrB1 (= nextB in F1)
        //   B2 slides toward capNbrB2 (= prevB in F2)
        uint capNbrA1, capNbrA2, capNbrB1, capNbrB2;
    }
    EdgeBevelEntry[] ebEntries;

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
        ebEntries         = [];
        ebFaceSnaps       = [];
        ebVertsBeforeBevel = [];
        shiftAmount  = 0.0f;
        insertScale  = 1.0f;
        ebWidth      = 0.0f;
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

    // First drag in edge mode: build chamfer topology.
    //
    // For each selected manifold edge (va, vb):
    //   F1 = face where va→vb is consecutive  (positions ia, ib)
    //   F2 = face where vb→va is consecutive  (positions jb, ja)
    //
    //   Four slide directions are computed from F1/F2:
    //     dirA1 toward prevA_in_F1, dirA2 toward nextA_in_F2
    //     dirB1 toward nextB_in_F1, dirB2 toward prevB_in_F2
    //
    //   General replacement rule applied to ALL faces containing va or vb:
    //     At position i of va in face F:
    //       if F[i-1] == capNbrA1: fromBefore = nvA1
    //       if F[i-1] == capNbrA2: fromBefore = nvA2
    //       if F[i+1] == capNbrA1: fromAfter  = nvA1
    //       if F[i+1] == capNbrA2: fromAfter  = nvA2
    //     (same pattern for vb with capNbrB1/B2)
    //   The original vertex is dropped; only fromBefore/fromAfter are emitted.
    void applyEdgeBevelTopology() {
        ebEntries          = [];
        ebFaceSnaps        = [];
        bevelApplied       = true;
        bevelFaceStart     = mesh.faces.length;

        edgesBeforeBevel     = mesh.edges.dup;
        selEdgesBeforeBevel  = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;
        ebVertsBeforeBevel   = mesh.vertices.dup;

        // Collect selected edge info.
        struct SelEdge {
            int  idx;
            uint va, vb;
            int  f1, ia, ib;   // F1: va→vb; ia=idx of va, ib=idx of vb
            int  f2, jb, ja;   // F2: vb→va; jb=idx of vb, ja=idx of va
        }
        SelEdge[] sel;

        foreach (ei; 0 .. mesh.edges.length) {
            if (ei >= mesh.selectedEdges.length || !mesh.selectedEdges[ei]) continue;
            uint va = mesh.edges[ei][0];
            uint vb = mesh.edges[ei][1];
            int f1 = -1, f2 = -1, ia, ib, jb, ja;

            foreach (fi, face; mesh.faces) {
                int N = cast(int)face.length;
                foreach (i; 0 .. N) {
                    int nxt = (i + 1) % N;
                    if (face[i] == va && face[nxt] == vb && f1 < 0) {
                        f1 = cast(int)fi; ia = i; ib = nxt;
                    }
                    if (face[i] == vb && face[nxt] == va && f2 < 0) {
                        f2 = cast(int)fi; jb = i; ja = nxt;
                    }
                }
            }

            if (f1 < 0 || f2 < 0) continue;  // boundary / non-manifold — skip
            sel ~= SelEdge(cast(int)ei, va, vb, f1, ia, ib, f2, jb, ja);
        }

        if (sel.length == 0) { bevelApplied = false; return; }

        // Find vertices shared by two or more selected edges (junction points).
        int[uint] vertSelCount;
        foreach (ref s; sel) {
            vertSelCount[s.va]++;
            vertSelCount[s.vb]++;
        }
        bool[uint] junctionVerts;
        foreach (v, cnt; vertSelCount)
            if (cnt >= 2) junctionVerts[v] = true;

        // Replacement table: key = (faceIdx << 32 | vertIdx)
        // value = (fromBefore, fromAfter) — new vertex indices (-1 = not set).
        // The original vertex is replaced by [fromBefore?, fromAfter?] in the face.
        struct Replace { int fromBefore = -1, fromAfter = -1; }
        Replace[ulong] repTable;

        foreach (si, ref s; sel) {
            auto f1face = mesh.faces[s.f1];
            auto f2face = mesh.faces[s.f2];
            int f1N = cast(int)f1face.length;
            int f2N = cast(int)f2face.length;

            Vec3 va_pos = mesh.vertices[s.va];
            Vec3 vb_pos = mesh.vertices[s.vb];

            // In F1 = [..., prevA, va, vb, nextB, ...]
            uint capNbrA1 = f1face[(s.ia - 1 + f1N) % f1N]; // A1 slides toward this
            uint capNbrB1 = f1face[(s.ib + 1) % f1N];       // B1 slides toward this
            // In F2 = [..., prevB, vb, va, nextA, ...]
            uint capNbrB2 = f2face[(s.jb - 1 + f2N) % f2N]; // B2 slides toward this
            uint capNbrA2 = f2face[(s.ja + 1) % f2N];       // A2 slides toward this

            Vec3 dirA1 = safeNorm(vec3Sub(mesh.vertices[capNbrA1], va_pos));
            Vec3 dirA2 = safeNorm(vec3Sub(mesh.vertices[capNbrA2], va_pos));
            Vec3 dirB1 = safeNorm(vec3Sub(mesh.vertices[capNbrB1], vb_pos));
            Vec3 dirB2 = safeNorm(vec3Sub(mesh.vertices[capNbrB2], vb_pos));

            // Create 4 new vertices at original positions (moved by updateEdgeBevelVertices).
            int nvA1 = cast(int)mesh.addVertex(va_pos);
            int nvA2 = cast(int)mesh.addVertex(va_pos);
            int nvB1 = cast(int)mesh.addVertex(vb_pos);
            int nvB2 = cast(int)mesh.addVertex(vb_pos);

            EdgeBevelEntry entry;
            entry.va = s.va; entry.vb = s.vb;
            entry.nvA1 = nvA1; entry.nvA2 = nvA2;
            entry.nvB1 = nvB1; entry.nvB2 = nvB2;
            entry.origA = va_pos; entry.origB = vb_pos;
            entry.dirA1 = dirA1; entry.dirA2 = dirA2;
            entry.dirB1 = dirB1; entry.dirB2 = dirB2;
            entry.capNbrA1 = capNbrA1;
            entry.capNbrA2 = capNbrA2;
            entry.capNbrB1 = capNbrB1;
            entry.capNbrB2 = capNbrB2;
            ebEntries ~= entry;

            // Build replacement table by scanning ALL faces for va or vb.
            // For each occurrence of va/vb in any face, check its prev and next
            // neighbours against capNbr* to decide which new vertex to insert.
            foreach (fi, face; mesh.faces) {
                int N = cast(int)face.length;
                foreach (i; 0 .. N) {
                    uint v = face[i];
                    if (v != s.va && v != s.vb) continue;
                    uint prev = face[(i - 1 + N) % N];
                    uint next = face[(i + 1) % N];

                    if (v == s.va) {
                        // For junction vertices only write into faces this edge owns.
                        if (s.va in junctionVerts)
                            if (cast(int)fi != s.f1 && cast(int)fi != s.f2) continue;
                        int fb = -1, fa = -1;
                        if      (prev == capNbrA1) fb = nvA1;
                        else if (prev == capNbrA2) fb = nvA2;
                        if      (next == capNbrA1) fa = nvA1;
                        else if (next == capNbrA2) fa = nvA2;
                        if (fb >= 0 || fa >= 0) {
                            ulong k = (cast(ulong)fi << 32) | s.va;
                            if (k !in repTable) repTable[k] = Replace();
                            if (fb >= 0) repTable[k].fromBefore = fb;
                            if (fa >= 0) repTable[k].fromAfter  = fa;
                        }
                    } else { // v == s.vb
                        // For junction vertices only write into faces this edge owns.
                        if (s.vb in junctionVerts)
                            if (cast(int)fi != s.f1 && cast(int)fi != s.f2) continue;
                        int fb = -1, fa = -1;
                        if      (prev == capNbrB1) fb = nvB1;
                        else if (prev == capNbrB2) fb = nvB2;
                        if      (next == capNbrB1) fa = nvB1;
                        else if (next == capNbrB2) fa = nvB2;
                        if (fb >= 0 || fa >= 0) {
                            ulong k = (cast(ulong)fi << 32) | s.vb;
                            if (k !in repTable) repTable[k] = Replace();
                            if (fb >= 0) repTable[k].fromBefore = fb;
                            if (fa >= 0) repTable[k].fromAfter  = fa;
                        }
                    }
                }
            }
        }

        // For junction vertices: replace each slide direction with the normalized
        // sum of all slide directions that share the same (polygon, vertex) pair.
        // This ensures that two entries touching the same vertex in the same face
        // get a consistent merged direction instead of two conflicting ones.
        if (junctionVerts.length > 0) {
            struct DirRef { int ei; int field; }  // field: 0=dirA1,1=dirA2,2=dirB1,3=dirB2
            Vec3[ulong]     dirSum;
            DirRef[][ulong] dirRefs;

            foreach (i; 0 .. ebEntries.length) {
                int f1 = sel[i].f1, f2 = sel[i].f2;

                if (ebEntries[i].va in junctionVerts) {
                    ulong ka1 = (cast(ulong)f1 << 32) | ebEntries[i].va;
                    ulong ka2 = (cast(ulong)f2 << 32) | ebEntries[i].va;
                    if (auto p = ka1 in dirSum) *p = vec3Add(*p, ebEntries[i].dirA1);
                    else dirSum[ka1] = ebEntries[i].dirA1;
                    if (auto p = ka2 in dirSum) *p = vec3Add(*p, ebEntries[i].dirA2);
                    else dirSum[ka2] = ebEntries[i].dirA2;
                    dirRefs[ka1] ~= DirRef(cast(int)i, 0);
                    dirRefs[ka2] ~= DirRef(cast(int)i, 1);
                }
                if (ebEntries[i].vb in junctionVerts) {
                    ulong kb1 = (cast(ulong)f1 << 32) | ebEntries[i].vb;
                    ulong kb2 = (cast(ulong)f2 << 32) | ebEntries[i].vb;
                    if (auto p = kb1 in dirSum) *p = vec3Add(*p, ebEntries[i].dirB1);
                    else dirSum[kb1] = ebEntries[i].dirB1;
                    if (auto p = kb2 in dirSum) *p = vec3Add(*p, ebEntries[i].dirB2);
                    else dirSum[kb2] = ebEntries[i].dirB2;
                    dirRefs[kb1] ~= DirRef(cast(int)i, 2);
                    dirRefs[kb2] ~= DirRef(cast(int)i, 3);
                }
            }

            foreach (k, refs; dirRefs) {
                if (refs.length < 2) continue;
                Vec3 nd = safeNorm(dirSum[k]);
                foreach (ref dr; refs) {
                    if      (dr.field == 0) ebEntries[dr.ei].dirA1 = nd;
                    else if (dr.field == 1) ebEntries[dr.ei].dirA2 = nd;
                    else if (dr.field == 2) ebEntries[dr.ei].dirB1 = nd;
                    else                   ebEntries[dr.ei].dirB2 = nd;
                }
            }
        }

        // Collect the set of faces that need modification.
        bool[int] modSet;
        foreach (k; repTable.byKey())
            modSet[cast(int)(k >> 32)] = true;

        // Save snapshots and apply modifications to ALL affected faces.
        foreach (fi; modSet.byKey()) {
            auto origFace = mesh.faces[fi];
            ebFaceSnaps ~= EbFaceSnap(fi, origFace.dup);

            uint[] newFace;
            newFace.reserve(origFace.length + 2);
            foreach (v; origFace) {
                ulong key = (cast(ulong)fi << 32) | v;
                if (auto rp = key in repTable) {
                    // Original vertex is dropped; emit new vertices in its place.
                    if (rp.fromBefore >= 0) newFace ~= cast(uint)rp.fromBefore;
                    if (rp.fromAfter  >= 0) newFace ~= cast(uint)rp.fromAfter;
                } else {
                    newFace ~= v;
                }
            }
            mesh.faces[fi] = newFace;
        }

        // Add bevel quad per edge: [B1, A1, A2, B2]
        // Use direct append (not addFace) — we rebuild all edges from scratch below.
        foreach (ref entry; ebEntries) {
            mesh.faces ~= [cast(uint)entry.nvB1, cast(uint)entry.nvA1,
                           cast(uint)entry.nvA2, cast(uint)entry.nvB2];
        }

        // ---- Compact vertex array: remove va/vb (now unreferenced by any face) ----
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

        // Remap every face's vertex indices.
        foreach (ref face; mesh.faces)
            foreach (ref v; face) v = cast(uint)remap[v];

        // Remap new vertex indices stored in entries (used by updateEdgeBevelVertices).
        foreach (ref entry; ebEntries) {
            entry.nvA1 = remap[entry.nvA1];
            entry.nvA2 = remap[entry.nvA2];
            entry.nvB1 = remap[entry.nvB1];
            entry.nvB2 = remap[entry.nvB2];
        }

        // ---- Rebuild edge list from current faces ----
        // This removes the original selected edge (va–vb) and any stale face edges,
        // and adds the correct edges for all modified faces + bevel quad.
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
        ebFaceSnaps        = [];
        ebVertsBeforeBevel = [];
        mesh.syncSelection();
    }

    // Reposition the 4 new vertices for every chamfered edge.
    // new_pos = orig_pos + slide_dir * ebWidth
    void updateEdgeBevelVertices() {
        foreach (ref entry; ebEntries) {
            mesh.vertices[entry.nvA1] = vec3Add(entry.origA, vec3Scale(entry.dirA1, ebWidth));
            mesh.vertices[entry.nvA2] = vec3Add(entry.origA, vec3Scale(entry.dirA2, ebWidth));
            mesh.vertices[entry.nvB1] = vec3Add(entry.origB, vec3Scale(entry.dirB1, ebWidth));
            mesh.vertices[entry.nvB2] = vec3Add(entry.origB, vec3Scale(entry.dirB2, ebWidth));
        }
    }
}
