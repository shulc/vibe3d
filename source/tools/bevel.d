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

import std.math : sqrt;

// ---------------------------------------------------------------------------
// BevelTool — polygon bevel (Polygons mode) and edge bevel (Edges mode).
//
// Polygon mode handles:
//   shiftHandle  (Arrow)      : extrude along face normal
//   insertHandle (CubicArrow) : inset from face center
//
// Edge mode handle:
//   widthHandle  (Arrow)      : widen each selected edge into a bevel strip
//
// On the first drag the tool modifies topology and records new vertex indices
// for live preview.  Subsequent drag events only reposition those vertices.
// ---------------------------------------------------------------------------

class BevelTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    bool active;

    // ---- Polygon-mode gizmo handles ----------------------------------------
    Arrow      shiftHandle;
    CubicArrow insertHandle;
    CubicArrow insertScaleArrow;

    // ---- Edge-mode gizmo handle --------------------------------------------
    Arrow widthHandle;

    // ---- Shared gizmo orientation ------------------------------------------
    Vec3 gizmoCenter;
    Vec3 gizmoNormal;    // polygon mode: average face normal
    Vec3 gizmoRight;     // polygon mode: insert axis
    Vec3 gizmoWidthDir;  // edge mode: average side direction

    // ---- Polygon-mode parameters -------------------------------------------
    float shiftAmount   = 0.0f;
    float insertScale   = 1.0f;
    bool  groupPolygons = false;

    Vec3 groupCenter;
    Vec3 groupNormal;

    // ---- Edge-mode parameters ----------------------------------------------
    float bevelWidth = 0.0f;

    // ---- Topology snapshots ------------------------------------------------
    bool bevelApplied = false;

    // Polygon-bevel face data
    struct BevelFaceData {
        Vec3[]  origPos;
        int[]   newVerts;
        Vec3    center;
        Vec3    normal;
        int     origFaceIdx;
        uint[]  origFaceVerts;
    }
    BevelFaceData[] bevelFaces;

    // Edge-bevel face data
    struct BevelEdgeSide {
        int  faceIdx;
        int  newVertA;   // new mesh vertex for origA (mesh.edges[ei][0])
        int  newVertB;   // new mesh vertex for origB (mesh.edges[ei][1])
        Vec3 sideDir;    // unit vector pointing into the face (for live update)
    }
    struct BevelEdgeData {
        uint  origA, origB;
        Vec3  origPosA, origPosB;
        BevelEdgeSide[] sides;
    }
    BevelEdgeData[] bevelEdges;

    struct ModifiedFace {
        int    idx;
        uint[] origVerts;
    }
    ModifiedFace[] modifiedFaces;

    // ---- Revert state ------------------------------------------------------
    size_t    bevelVertStart;
    size_t    bevelFaceStart;
    uint[2][] edgesBeforeBevel;
    bool[]    selEdgesBeforeBevel;
    int[]     edgeOrderBeforeBevel;

    // ---- Drag state --------------------------------------------------------
    // dragHandle: 0=shift, 1=insert, 2=free(polygon), 3=width(edge), -1=none
    int      dragHandle = -1;
    int      lastMX, lastMY;
    Viewport cachedVp;

    int  freeDragAxis    = -1;
    int  freeDragStartMX, freeDragStartMY;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;

        gizmoCenter   = Vec3(0, 0, 0);
        gizmoNormal   = Vec3(0, 1, 0);
        gizmoRight    = Vec3(1, 0, 0);
        gizmoWidthDir = Vec3(0, 1, 0);

        shiftHandle      = new Arrow     (gizmoCenter, gizmoCenter, Vec3(0.2f, 0.2f, 0.9f));
        insertHandle     = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(0.9f, 0.2f, 0.2f));
        insertScaleArrow = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(1.0f, 0.95f, 0.15f));
        insertScaleArrow.fixedDir = gizmoRight;
        widthHandle      = new Arrow     (gizmoCenter, gizmoCenter, Vec3(0.2f, 0.9f, 0.2f));
    }

    void destroy() {
        shiftHandle.destroy();
        insertHandle.destroy();
        insertScaleArrow.destroy();
        widthHandle.destroy();
    }

    override string name() const { return "Bevel"; }

    override void activate() {
        active        = true;
        bevelApplied  = false;
        bevelFaces    = [];
        bevelEdges    = [];
        modifiedFaces = [];
        shiftAmount   = 0.0f;
        insertScale   = 1.0f;
        bevelWidth    = 0.0f;
        dragHandle    = -1;
        freeDragAxis  = -1;
        if (*editMode == EditMode.Edges)
            recomputeEdgeGizmo();
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
            recomputeEdgeGizmo();
        else
            recomputeCenter();
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        if (!active) return;
        cachedVp = vp;

        // ---- Polygon mode handles ------------------------------------------
        bool anyFace = (*editMode == EditMode.Polygons) && mesh.faces.length > 0;
        shiftHandle .setVisible(anyFace);
        insertHandle.setVisible(anyFace);

        if (anyFace) {
            float size = gizmoSize(gizmoCenter, vp);

            shiftHandle.start  = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size / 6.0f));
            shiftHandle.end    = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size));

            insertHandle.start = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size / 6.0f));
            insertHandle.end   = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size));

            shiftHandle .setForceHovered(dragHandle == 0);
            shiftHandle .setHoverBlocked(dragHandle == 1);
            insertHandle.setForceHovered(false);
            insertHandle.setHoverBlocked(dragHandle >= 0);

            float cubeFixed = size * 0.03f;
            if (dragHandle != 1)
                insertScaleArrow.start = insertHandle.start;
            insertScaleArrow.end           = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size * insertScale));
            insertScaleArrow.fixedDir      = gizmoRight;
            insertScaleArrow.fixedCubeHalf = cubeFixed;
        }

        shiftHandle .draw(shader, vp);
        insertHandle.draw(shader, vp);
        if (dragHandle == 1 && insertScale != 0.0f)
            insertScaleArrow.draw(shader, vp);

        // ---- Edge mode handle ---------------------------------------------
        bool anyEdge = (*editMode == EditMode.Edges) && mesh.edges.length > 0;
        widthHandle.setVisible(anyEdge);

        if (anyEdge) {
            float size = gizmoSize(gizmoCenter, vp);
            widthHandle.start = vec3Add(gizmoCenter, vec3Scale(gizmoWidthDir, size / 6.0f));
            widthHandle.end   = vec3Add(gizmoCenter, vec3Scale(gizmoWidthDir, size));
            widthHandle.setForceHovered(dragHandle == 3);
            widthHandle.setHoverBlocked(false);
        }

        widthHandle.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        if (*editMode == EditMode.Edges) {
            if (mesh.edges.length == 0) return false;
            dragHandle = 3;
            lastMX = e.x;
            lastMY = e.y;
            return true;
        }

        if (*editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0)         return false;

        if (shiftHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 0;
        else if (insertHandle.hitTest(e.x, e.y, cachedVp))
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

        // ---- Edge width drag (dragHandle == 3) ----------------------------
        if (dragHandle == 3) {
            if (!bevelApplied) applyEdgeBevelTopology();
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY,
                                         gizmoCenter, gizmoWidthDir, cachedVp, skip);
            if (!skip) {
                float d = dot(delta, gizmoWidthDir);
                bevelWidth += d;
                if (bevelWidth < 0.0f) bevelWidth = 0.0f;
                updateEdgeBevelVertices();
                gpu.upload(*mesh);
            }
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // ---- Polygon free drag (dragHandle == 2) --------------------------
        if (dragHandle == 2) {
            if (freeDragAxis < 0) {
                int tdx = e.x - freeDragStartMX;
                int tdy = e.y - freeDragStartMY;
                if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }
                import std.math : abs;
                freeDragAxis = (abs(tdx) >= abs(tdy)) ? 1 : 0;
                if (!bevelApplied) applyBevelTopology();
                lastMX = e.x; lastMY = e.y; return true;
            }

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

            updateBevelVertices();
            gpu.upload(*mesh);
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // ---- Polygon handle drags (dragHandle == 0 or 1) ------------------
        if (!bevelApplied) applyBevelTopology();

        if (dragHandle == 0) {
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY,
                                         gizmoCenter, gizmoNormal, cachedVp, skip);
            if (!skip) {
                shiftAmount += dot(delta, gizmoNormal);
                gizmoCenter  = vec3Add(gizmoCenter, delta);
                updateBevelVertices();
                gpu.upload(*mesh);
            }
        } else {
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
            bool changed = false;
            ImGui.DragFloat("Width", &bevelWidth, 0.005f, 0.0f, float.max, "%.4f");
            if (ImGui.IsItemActive()) {
                if (bevelWidth < 0.0f) bevelWidth = 0.0f;
                changed = true;
            }
            if (changed && bevelApplied) {
                updateEdgeBevelVertices();
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

    // ------------------------------------------------------------------------
    // Revert — undo topology from either polygon or edge bevel.
    // ------------------------------------------------------------------------
    void revertBevelTopology() {
        if (bevelEdges.length > 0) {
            foreach (ref mf; modifiedFaces)
                mesh.faces[mf.idx] = mf.origVerts;
            modifiedFaces = [];
            bevelEdges    = [];
        } else {
            foreach (ref bfd; bevelFaces)
                mesh.faces[bfd.origFaceIdx] = bfd.origFaceVerts;
            bevelFaces = [];
        }
        mesh.vertices.length    = bevelVertStart;
        mesh.faces.length       = bevelFaceStart;
        mesh.edges              = edgesBeforeBevel;
        mesh.selectedEdges      = selEdgesBeforeBevel;
        mesh.edgeSelectionOrder = edgeOrderBeforeBevel;
        bevelApplied = false;
        mesh.syncSelection();
    }

    // ------------------------------------------------------------------------
    // Polygon mode — gizmo recompute
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // Polygon mode — apply topology
    // ------------------------------------------------------------------------
    void applyBevelTopology() {
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
                    keptSel ~= ei < mesh.selectedEdges.length     ? mesh.selectedEdges[ei]     : false;
                    keptOrd ~= ei < mesh.edgeSelectionOrder.length ? mesh.edgeSelectionOrder[ei]: 0;
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

    void updateBevelVertices() {
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

    // ------------------------------------------------------------------------
    // Edge mode — gizmo recompute
    // ------------------------------------------------------------------------
    void recomputeEdgeGizmo() {
        if (*editMode != EditMode.Edges || mesh.edges.length == 0) return;

        bool allEdges = !mesh.hasAnySelectedEdges();

        bool[] isSelEdge = new bool[](mesh.edges.length);
        if (allEdges) {
            isSelEdge[] = true;
        } else {
            foreach (ei, sel; mesh.selectedEdges)
                if (ei < isSelEdge.length) isSelEdge[ei] = sel;
        }

        // Build edge-key → index map for face adjacency scan
        int[ulong] edgeIdxMap;
        foreach (ei, e; mesh.edges)
            edgeIdxMap[edgeKey(e[0], e[1])] = cast(int)ei;

        // Average edge midpoint → gizmoCenter
        Vec3 centerSum = Vec3(0,0,0);
        int  count     = 0;
        foreach (ei, e; mesh.edges) {
            if (!isSelEdge[ei]) continue;
            centerSum = vec3Add(centerSum,
                vec3Scale(vec3Add(mesh.vertices[e[0]], mesh.vertices[e[1]]), 0.5f));
            count++;
        }
        if (count == 0) return;
        float inv = 1.0f / cast(float)count;
        gizmoCenter = Vec3(centerSum.x*inv, centerSum.y*inv, centerSum.z*inv);

        // Average side direction across all (face, selected-edge) pairs
        Vec3 sideDirSum = Vec3(0,0,0);
        foreach (fi, face; mesh.faces) {
            int N = cast(int)face.length;
            float cx = 0, cy = 0, cz = 0;
            foreach (vi; face) { cx += mesh.vertices[vi].x; cy += mesh.vertices[vi].y; cz += mesh.vertices[vi].z; }
            float fInv = 1.0f / cast(float)N;
            Vec3 center = Vec3(cx*fInv, cy*fInv, cz*fInv);

            foreach (i; 0..N) {
                uint a = face[i], b = face[(i+1)%N];
                ulong k = edgeKey(a, b);
                if (auto p = k in edgeIdxMap) {
                    int ei = cast(int)*p;
                    if (!isSelEdge[ei]) continue;
                    Vec3 posA = mesh.vertices[mesh.edges[ei][0]];
                    Vec3 posB = mesh.vertices[mesh.edges[ei][1]];
                    Vec3 ed   = normalize(vec3Sub(posB, posA));
                    Vec3 mid  = vec3Scale(vec3Add(posA, posB), 0.5f);
                    Vec3 toc  = vec3Sub(center, mid);
                    Vec3 sRaw = vec3Sub(toc, vec3Scale(ed, dot(toc, ed)));
                    float sl  = sqrt(sRaw.x*sRaw.x + sRaw.y*sRaw.y + sRaw.z*sRaw.z);
                    if (sl > 1e-6f)
                        sideDirSum = vec3Add(sideDirSum,
                            Vec3(sRaw.x/sl, sRaw.y/sl, sRaw.z/sl));
                }
            }
        }
        // sideDir points inward (edge midpoint → face center); negate so the
        // arrow points outward — toward the bevel strip that appears at the edge.
        float sl = sqrt(sideDirSum.x*sideDirSum.x + sideDirSum.y*sideDirSum.y + sideDirSum.z*sideDirSum.z);
        gizmoWidthDir = sl > 1e-6f
            ? Vec3(-sideDirSum.x/sl, -sideDirSum.y/sl, -sideDirSum.z/sl)
            : Vec3(0, 1, 0);
    }

    // ------------------------------------------------------------------------
    // Edge mode — apply topology
    //
    // Algorithm:
    //   Phase 1 — for each (face, selected-edge) pair: compute the side
    //             direction into the face and create two new vertices (one for
    //             each edge endpoint).
    //   Phase 2 — rebuild each affected face, replacing edge-endpoint vertices
    //             with the new ones.  At a junction (two selected edges meeting
    //             at one vertex inside the same face) both new vertices are
    //             inserted, growing the face by one.
    //   Phase 3 — add the bevel-strip quad between the two sides of each
    //             selected edge.
    // ------------------------------------------------------------------------
    void applyEdgeBevelTopology() {
        bevelEdges    = [];
        modifiedFaces = [];
        bevelApplied  = true;
        bevelVertStart = mesh.vertices.length;
        bevelFaceStart = mesh.faces.length;

        edgesBeforeBevel     = mesh.edges.dup;
        selEdgesBeforeBevel  = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;

        // Edge-key → edge-index
        int[ulong] edgeIdxMap;
        foreach (ei, e; mesh.edges)
            edgeIdxMap[edgeKey(e[0], e[1])] = cast(int)ei;

        // Selected edge mask
        bool[] isSelEdge = new bool[](mesh.edges.length);
        if (mesh.hasAnySelectedEdges()) {
            foreach (ei, sel; mesh.selectedEdges)
                if (ei < isSelEdge.length) isSelEdge[ei] = sel;
        } else {
            isSelEdge[] = true;
        }

        // Seed edgeDataMap with origA/B and positions
        BevelEdgeData[int] edgeDataMap;
        foreach (ei, e; mesh.edges) {
            if (!isSelEdge[ei]) continue;
            BevelEdgeData bed;
            bed.origA    = e[0];
            bed.origB    = e[1];
            bed.origPosA = mesh.vertices[e[0]];
            bed.origPosB = mesh.vertices[e[1]];
            edgeDataMap[cast(int)ei] = bed;
        }

        // ---- Phase 1: scan faces, create new vertices, fill side data ------
        struct FaceEdgeEntry { int slot; int ei; }
        FaceEdgeEntry[][int] faceEdgeMap;

        foreach (fi, face; mesh.faces) {
            int   N  = cast(int)face.length;
            float cx = 0, cy = 0, cz = 0;
            foreach (vi; face) { cx += mesh.vertices[vi].x; cy += mesh.vertices[vi].y; cz += mesh.vertices[vi].z; }
            float fInv = 1.0f / cast(float)N;
            Vec3 center = Vec3(cx*fInv, cy*fInv, cz*fInv);

            foreach (i; 0..N) {
                uint a = face[i], b = face[(i+1)%N];
                ulong k = edgeKey(a, b);
                if (auto p = k in edgeIdxMap) {
                    int ei = cast(int)*p;
                    if (!isSelEdge[ei]) continue;

                    faceEdgeMap[cast(int)fi] ~= FaceEdgeEntry(i, ei);

                    Vec3 posA = edgeDataMap[ei].origPosA;
                    Vec3 posB = edgeDataMap[ei].origPosB;
                    Vec3 ed   = normalize(vec3Sub(posB, posA));
                    Vec3 mid  = vec3Scale(vec3Add(posA, posB), 0.5f);
                    Vec3 toc  = vec3Sub(center, mid);
                    Vec3 sRaw = vec3Sub(toc, vec3Scale(ed, dot(toc, ed)));
                    float sl  = sqrt(sRaw.x*sRaw.x + sRaw.y*sRaw.y + sRaw.z*sRaw.z);
                    Vec3 sideDir = sl > 1e-6f
                        ? Vec3(sRaw.x/sl, sRaw.y/sl, sRaw.z/sl)
                        : Vec3(0,1,0);

                    BevelEdgeSide side;
                    side.faceIdx  = cast(int)fi;
                    side.newVertA = cast(int)mesh.addVertex(posA);
                    side.newVertB = cast(int)mesh.addVertex(posB);
                    side.sideDir  = sideDir;
                    edgeDataMap[ei].sides ~= side;
                }
            }
        }

        // Collect bevelEdges in original edge order
        foreach (ei_sz, e; mesh.edges) {
            int ei = cast(int)ei_sz;
            if (!isSelEdge[ei]) continue;
            if (auto p = ei in edgeDataMap)
                bevelEdges ~= *p;
        }

        // ---- Phase 2: rebuild affected faces --------------------------------
        foreach (int fi, entries; faceEdgeMap) {
            auto origFace = mesh.faces[fi];
            int  N        = cast(int)origFace.length;
            modifiedFaces ~= ModifiedFace(fi, origFace.dup);

            // Return the new vertex for original vertex `v` in edge `ei`
            // for this face (fi is captured from the enclosing foreach).
            int getNewVert(int ei, uint v) {
                uint origA = edgeDataMap[ei].origA;
                foreach (ref side; edgeDataMap[ei].sides)
                    if (side.faceIdx == fi)
                        return (origA == v) ? side.newVertA : side.newVertB;
                return cast(int)v;
            }

            uint[] newFace;
            foreach (i; 0..N) {
                uint v      = origFace[i];
                uint v_prev = origFace[(i - 1 + N) % N];
                uint v_next = origFace[(i + 1)     % N];

                // Selected edge incoming to v: v_prev → v
                int ei_in = -1;
                {
                    ulong k = edgeKey(v_prev, v);
                    if (auto p = k in edgeIdxMap) {
                        int c = cast(int)*p;
                        if (isSelEdge[c] && (c in edgeDataMap))
                            foreach (ref ent; entries)
                                if (ent.ei == c) { ei_in = c; break; }
                    }
                }

                // Selected edge outgoing from v: v → v_next
                int ei_out = -1;
                {
                    ulong k = edgeKey(v, v_next);
                    if (auto p = k in edgeIdxMap) {
                        int c = cast(int)*p;
                        if (isSelEdge[c] && (c in edgeDataMap))
                            foreach (ref ent; entries)
                                if (ent.ei == c) { ei_out = c; break; }
                    }
                }

                if (ei_in >= 0 && ei_out >= 0) {
                    // Junction: insert both new vertices
                    newFace ~= cast(uint)getNewVert(ei_in,  v);
                    newFace ~= cast(uint)getNewVert(ei_out, v);
                } else if (ei_in >= 0) {
                    newFace ~= cast(uint)getNewVert(ei_in, v);
                } else if (ei_out >= 0) {
                    newFace ~= cast(uint)getNewVert(ei_out, v);
                } else {
                    newFace ~= v;
                }
            }
            mesh.faces[fi] = newFace;
        }

        // ---- Phase 2.5: expand side faces (share only a vertex with the selected
        //      edge, not the edge itself) → replace that vertex with the two new
        //      split vertices so each such face gains one extra vertex. ----------
        {
            bool[int] modFaceSet;
            foreach (ref mf; modifiedFaces) modFaceSet[mf.idx] = true;

            foreach (ref bed; bevelEdges) {
                if (bed.sides.length < 2) continue;
                int fi0 = bed.sides[0].faceIdx;
                int fi1 = bed.sides[1].faceIdx;

                foreach (doA; [true, false]) {
                    uint origV = doA ? bed.origA : bed.origB;
                    int  nv0   = doA ? bed.sides[0].newVertA : bed.sides[0].newVertB;
                    int  nv1   = doA ? bed.sides[1].newVertA : bed.sides[1].newVertB;

                    foreach (fi, face; mesh.faces) {
                        if (fi >= bevelFaceStart) break;
                        if (cast(int)fi in modFaceSet) continue;

                        int vidx = -1;
                        foreach (i, v; face)
                            if (v == origV) { vidx = cast(int)i; break; }
                        if (vidx < 0) continue;

                        int  N      = cast(int)face.length;
                        uint v_prev = face[(vidx - 1 + N) % N];

                        // The new vertex whose adjacent face contains v_prev
                        // should come first (immediately after v_prev).
                        bool prevInFace0 = false;
                        foreach (v; mesh.faces[fi0])
                            if (v == v_prev) { prevInFace0 = true; break; }

                        int first_nv  = prevInFace0 ? nv0 : nv1;
                        int second_nv = prevInFace0 ? nv1 : nv0;

                        uint[] newFace;
                        foreach (i, v; face) {
                            if (i == vidx) {
                                newFace ~= cast(uint)first_nv;
                                newFace ~= cast(uint)second_nv;
                            } else {
                                newFace ~= v;
                            }
                        }
                        modifiedFaces ~= ModifiedFace(cast(int)fi, face.dup);
                        modFaceSet[cast(int)fi] = true;
                        mesh.faces[fi] = newFace;
                    }
                }
            }
        }

        // ---- Phase 3: add bevel strip quads ---------------------------------
        // Winding: normal of the strip must face outward.
        // Normal ∝ ed × (sideDir1 − sideDir0).  Outward ≈ −(sideDir0 + sideDir1).
        // Condition simplifies to: dot(cross(ed, sideDir0), sideDir1) > 0
        //   → winding [s0.A, s0.B, s1.B, s1.A] is outward-facing.
        // If < 0: swap sides so the quad winds the other way.
        foreach (ref bed; bevelEdges) {
            if (bed.sides.length < 2) continue;
            auto s0 = bed.sides[0];
            auto s1 = bed.sides[1];
            Vec3 ed = normalize(vec3Sub(bed.origPosB, bed.origPosA));
            float handedness = dot(cross(ed, s0.sideDir), s1.sideDir);
            if (handedness >= 0.0f)
                mesh.addFace([cast(uint)s0.newVertA, cast(uint)s0.newVertB,
                              cast(uint)s1.newVertB, cast(uint)s1.newVertA]);
            else
                mesh.addFace([cast(uint)s1.newVertA, cast(uint)s1.newVertB,
                              cast(uint)s0.newVertB, cast(uint)s0.newVertA]);
        }

        // ---- Remove stale edges: origA/origB vertices are no longer in any face
        //      after Phase 2 + 2.5 replaced them everywhere. --------------------
        {
            bool[uint] origEndpoints;
            foreach (ref bed; bevelEdges) {
                origEndpoints[bed.origA] = true;
                origEndpoints[bed.origB] = true;
            }
            uint[2][] keptEdges;
            bool[]    keptSel;
            int[]     keptOrd;
            foreach (ei, e; mesh.edges) {
                if ((e[0] in origEndpoints) || (e[1] in origEndpoints)) continue;
                keptEdges ~= e;
                keptSel   ~= (ei < mesh.selectedEdges.length)
                             ? mesh.selectedEdges[ei] : false;
                keptOrd   ~= (ei < mesh.edgeSelectionOrder.length)
                             ? mesh.edgeSelectionOrder[ei] : 0;
            }
            mesh.edges              = keptEdges;
            mesh.selectedEdges      = keptSel;
            mesh.edgeSelectionOrder = keptOrd;
        }

        // ---- Add edges implied by all modified faces (Phase 2 + 2.5) ----------
        foreach (ref mf; modifiedFaces) {
            auto face = mesh.faces[mf.idx];
            int  N    = cast(int)face.length;
            foreach (i; 0..N)
                mesh.addEdge(face[i], face[(i+1)%N]);
        }

        mesh.syncSelection();
        updateEdgeBevelVertices();
    }

    void updateEdgeBevelVertices() {
        foreach (ref bed; bevelEdges) {
            foreach (ref side; bed.sides) {
                mesh.vertices[side.newVertA] = vec3Add(bed.origPosA,
                    vec3Scale(side.sideDir, bevelWidth));
                mesh.vertices[side.newVertB] = vec3Add(bed.origPosB,
                    vec3Scale(side.sideDir, bevelWidth));
            }
        }
    }
}
