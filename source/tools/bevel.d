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
    float ebWidth = 0.0f;

    // Per-endpoint data: original pos + N BoundVert indices + N slide directions
    struct EbEndpoint {
        uint   origVert;
        Vec3   origPos;
        int[]  boundVerts;   // indices in mesh.vertices (length = valence)
        Vec3[] slideDirs;    // offsetInPlane directions (length = valence)
        uint[] capPoly;      // ordered cap polygon (same order as boundVerts, CCW)
    }

    struct EbEntry {
        EbEndpoint endA, endB;  // a = edges[ei][0], b = edges[ei][1]
    }
    EbEntry[] ebEntries;

    // Snapshot for revert
    struct EbFaceSnap { int idx; uint[] orig; }
    EbFaceSnap[] ebFaceSnaps;
    Vec3[]  ebVertsBeforeBevel;
    size_t  ebBevelVertStart;
    size_t  ebBevelFaceStart;

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
        ebEntries    = [];
        ebFaceSnaps  = [];
        ebVertsBeforeBevel = [];
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
            Vec3 mid = Vec3((pa.x + pb.x) * 0.5f,
                            (pa.y + pb.y) * 0.5f,
                            (pa.z + pb.z) * 0.5f);
            centerSum = vec3Add(centerSum, mid);

            // accumulate normals of adjacent faces
            foreach (fi; mesh.facesAroundEdge(cast(uint)ei))
                normalSum = vec3Add(normalSum, mesh.faceNormal(fi));
            count++;
        }

        if (count == 0) return;

        float inv = 1.0f / cast(float)count;
        gizmoCenter = Vec3(centerSum.x * inv, centerSum.y * inv, centerSum.z * inv);

        float nlen = vec3Length(normalSum);
        gizmoNormal = nlen > 1e-6f
            ? Vec3(normalSum.x/nlen, normalSum.y/nlen, normalSum.z/nlen)
            : Vec3(0, 1, 0);

        Vec3 tmp   = (gizmoNormal.x < 0.9f && gizmoNormal.x > -0.9f)
                     ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        gizmoRight = normalize(cross(gizmoNormal, tmp));
    }

    // ------------------------------------------------------------------
    // Edge bevel: apply topology
    // ------------------------------------------------------------------

    void applyEdgeBevelTopology() {
        bevelApplied       = true;
        ebEntries          = [];
        ebFaceSnaps        = [];
        ebBevelVertStart   = mesh.vertices.length;
        ebBevelFaceStart   = mesh.faces.length;
        ebVertsBeforeBevel = mesh.vertices.dup;

        edgesBeforeBevel     = mesh.edges.dup;
        selEdgesBeforeBevel  = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;

        // Build half-edge structure.
        mesh.buildLoops();

        // Build directed-loop map: (u<<32|v) → loop index.
        uint[ulong] dirLoopMap;
        foreach (li, ref lp; mesh.loops) {
            uint u = lp.vert;
            uint v = mesh.loops[lp.next].vert;
            dirLoopMap[(cast(ulong)u << 32) | v] = cast(uint)li;
        }

        // We need a face → snap record map to avoid double-snapping.
        bool[int] faceSnapped;

        // Process each selected manifold edge.
        foreach (ei, sel; mesh.selectedEdges) {
            if (!sel || ei >= mesh.edges.length) continue;

            uint va = mesh.edges[ei][0];
            uint vb = mesh.edges[ei][1];

            // Require both directed loops to exist (manifold edge).
            ulong keyAB = (cast(ulong)va << 32) | vb;
            ulong keyBA = (cast(ulong)vb << 32) | va;
            auto pAB = keyAB in dirLoopMap;
            auto pBA = keyBA in dirLoopMap;
            if (!pAB || !pBA) continue;

            uint loopAB = *pAB; // loop: va→vb  (face F1, contains directed edge a→b)
            uint loopBA = *pBA; // loop: vb→va  (face F2, contains directed edge b→a)

            EbEntry entry;
            entry.endA.origVert = va;
            entry.endA.origPos  = mesh.vertices[va];
            entry.endB.origVert = vb;
            entry.endB.origPos  = mesh.vertices[vb];

            // Gather BoundVerts for each endpoint.
            // idxF1 is always 0 (we start the ring at loopAB = F1).
            // idxF2 is the k-index of F2 in the faceDarts ring for each endpoint.
            int idxF2_A, idxF2_B;
            buildEbEndpoint(entry.endA, va, vb, loopAB, loopBA,
                            faceSnapped, idxF2_A);
            buildEbEndpoint(entry.endB, vb, va, loopBA, loopAB,
                            faceSnapped, idxF2_B);

            // Add bevel quad: [bvA_F1, bvB_F1, bvB_F2, bvA_F2]
            //
            // endA ring starts at loopAB (dart va→vb, face F1) → boundVerts[0] = bvA_F1
            //                                                    → boundVerts[idxF2_A] = bvA_F2
            // endB ring starts at loopBA (dart vb→va, face F2) → boundVerts[0] = bvB_F2
            //                                                    → boundVerts[idxF2_B] = bvB_F1
            //   (for endB, buildEbEndpoint's "loopPeerOv" = loopAB = F1, so outIdxF2 = F1 index)
            if (entry.endA.boundVerts.length > 0 && entry.endB.boundVerts.length > 0 &&
                idxF2_A >= 0 && idxF2_B >= 0 &&
                idxF2_A < cast(int)entry.endA.boundVerts.length &&
                idxF2_B < cast(int)entry.endB.boundVerts.length)
            {
                uint bvA_F1 = cast(uint)entry.endA.boundVerts[0];
                uint bvA_F2 = cast(uint)entry.endA.boundVerts[idxF2_A];
                uint bvB_F2 = cast(uint)entry.endB.boundVerts[0];        // endB ring[0] = F2
                uint bvB_F1 = cast(uint)entry.endB.boundVerts[idxF2_B];  // endB idxF2 = F1 index
                // Quad winding: CCW looking from outside the bevel.
                mesh.faces ~= [bvA_F1, bvB_F1, bvB_F2, bvA_F2];
            }

            ebEntries ~= entry;
        }

        // Rebuild edges from scratch from all current faces.
        mesh.edges = [];
        bool[ulong] seenEdge;
        foreach (face; mesh.faces) {
            int M = cast(int)face.length;
            foreach (i; 0 .. M) {
                uint u = face[i];
                uint w = face[(i + 1) % M];
                ulong key = edgeKey(u, w);
                if (key !in seenEdge) {
                    seenEdge[key] = true;
                    mesh.edges ~= [u, w];
                }
            }
        }

        mesh.buildLoops();
        mesh.syncSelection();
    }

    // Build the BoundVert ring for one endpoint `ep` (orig vertex = `ov`).
    // `ov_peer` is the other end of the bevel edge.
    // `loopOvPeer` = directed loop ov→ov_peer (face F1, ring index 0).
    // `loopPeerOv` = directed loop ov_peer→ov (face F2, ring index = outIdxF2).
    // `outIdxF2`   = output: index into ep.boundVerts that belongs to face F2.
    private void buildEbEndpoint(ref EbEndpoint ep,
                                  uint ov, uint /*ov_peer*/,
                                  uint loopOvPeer,   // ov→ov_peer dart (F1, ring[0])
                                  uint loopPeerOv,   // ov_peer→ov dart
                                  ref bool[int] faceSnapped,
                                  out int outIdxF2)
    {
        outIdxF2 = -1;

        // Walk all faces around ov via the half-edge ring.
        // In each face the dart for ov has .vert == ov.
        // Ring traversal: from dart li (.vert==ov), next dart around ov =
        //   twin(prev(li)).
        // twin(prev(li)).vert == ov because:
        //   prev(li).vert == some X  →  directed edge X→ov in face Fi
        //   twin(X→ov) = dart ov→X in adjacent face Fj  →  .vert == ov ✓

        uint startLi = loopOvPeer; // dart ov→ov_peer in F1 (ring index 0)

        // F2 dart for ov: in face F2, the directed edge ov_peer→ov exists as loopPeerOv.
        // The dart for ov in F2 is loops[loopPeerOv].next (since .vert of next == ov,
        // because loopPeerOv.vert==ov_peer and loopPeerOv.next.vert==ov).
        uint dartOvInF2 = (loopPeerOv != ~0u) ? mesh.loops[loopPeerOv].next : ~0u;

        uint[] faceDarts; // dart index for ov in each face, in ring order
        foreach (li; mesh.dartsAroundVertex(ov, startLi)) {
            faceDarts ~= li;
            // Track when we hit F2's dart
            if (li == dartOvInF2)
                outIdxF2 = cast(int)(faceDarts.length - 1);
        }

        int N = cast(int)faceDarts.length;
        if (N == 0) return;

        // If we never encountered dartOvInF2 in the ring, find it by face index.
        if (outIdxF2 < 0 && dartOvInF2 != ~0u) {
            uint f2 = (dartOvInF2 < mesh.loops.length) ? mesh.loops[dartOvInF2].face : ~0u;
            foreach (k; 0 .. N) {
                if (mesh.loops[faceDarts[k]].face == f2) {
                    outIdxF2 = cast(int)k;
                    break;
                }
            }
        }

        ep.boundVerts.length = N;
        ep.slideDirs .length = N;

        Vec3 aPos = ep.origPos;

        foreach (k; 0 .. N) {
            uint dart    = faceDarts[k];
            uint faceIdx = mesh.loops[dart].face;
            uint nextVi  = mesh.loops[mesh.loops[dart].next].vert; // neighbor along ov→nextVi

            // edgeDir: from ov toward the neighbor vertex in this face
            Vec3 nbr     = mesh.vertices[nextVi];
            Vec3 edgeDir = safeNormalize(vec3Sub(nbr, aPos));

            // face normal
            Vec3 fNorm = mesh.faceNormal(faceIdx);

            // slideDir = offsetInPlane(edgeDir, fNorm)
            Vec3 sd = offsetInPlane(edgeDir, fNorm);
            ep.slideDirs[k] = sd;

            // Create the BoundVert at origPos (updated later by updateEdgeBevelVertices)
            int bvi = cast(int)mesh.addVertex(aPos);
            ep.boundVerts[k] = bvi;

            // Snapshot the face (once), then replace ov with bvi
            if (faceIdx < cast(uint)mesh.faces.length) {
                if (!(cast(int)faceIdx in faceSnapped)) {
                    EbFaceSnap snap;
                    snap.idx  = cast(int)faceIdx;
                    snap.orig = mesh.faces[faceIdx].dup;
                    ebFaceSnaps ~= snap;
                    faceSnapped[cast(int)faceIdx] = true;
                }
                foreach (ref vi; mesh.faces[faceIdx])
                    if (vi == ov) { vi = cast(uint)bvi; break; }
            }
        }

        // Build cap polygon (CCW winding check using slide directions as proxies).
        uint[] capPoly = new uint[](N);
        foreach (k; 0 .. N) capPoly[k] = cast(uint)ep.boundVerts[k];

        // Cap normal: sum of cross products of consecutive slide directions
        Vec3 capNorm = Vec3(0, 0, 0);
        for (int k = 0; k < N; k++) {
            Vec3 d0 = ep.slideDirs[k];
            Vec3 d1 = ep.slideDirs[(k + 1) % N];
            capNorm = vec3Add(capNorm, cross(d0, d1));
        }
        // Average face normal around ov
        Vec3 avgFN = Vec3(0, 0, 0);
        foreach (dart; faceDarts) {
            uint fi = mesh.loops[dart].face;
            avgFN = vec3Add(avgFN, mesh.faceNormal(fi));
        }
        // If cap normal opposes the average face normal, reverse the ring.
        if (dot(capNorm, avgFN) < 0.0f) {
            for (int lo = 0, hi = N - 1; lo < hi; lo++, hi--) {
                uint tmp2 = capPoly[lo];
                capPoly[lo] = capPoly[hi];
                capPoly[hi] = tmp2;
            }
            // Also keep outIdxF2 consistent with the reversed order.
            if (outIdxF2 > 0)
                outIdxF2 = N - outIdxF2;
        }

        ep.capPoly = capPoly;

        // Append cap polygon directly (edge rebuild happens at the end of apply).
        mesh.faces ~= capPoly.dup;
    }

    // ------------------------------------------------------------------
    // Edge bevel: revert topology
    // ------------------------------------------------------------------

    void revertEdgeBevelTopology() {
        // Restore patched faces from snapshots.
        foreach (ref snap; ebFaceSnaps)
            mesh.faces[snap.idx] = snap.orig;

        // Trim appended vertices and faces.
        mesh.vertices.length = ebBevelVertStart;
        mesh.faces.length    = ebBevelFaceStart;

        // Restore edges and selection.
        mesh.edges              = edgesBeforeBevel.dup;
        mesh.selectedEdges      = selEdgesBeforeBevel.dup;
        mesh.edgeSelectionOrder = edgeOrderBeforeBevel.dup;

        bevelApplied = false;
        ebEntries    = [];
        ebFaceSnaps  = [];

        mesh.buildLoops();
        mesh.syncSelection();
    }

    // ------------------------------------------------------------------
    // Edge bevel: update vertex positions from ebWidth
    // ------------------------------------------------------------------

    void updateEdgeBevelVertices() {
        foreach (ref entry; ebEntries) {
            updateEbEndpointVerts(entry.endA);
            updateEbEndpointVerts(entry.endB);
        }
    }

    private void updateEbEndpointVerts(ref EbEndpoint ep) {
        foreach (k; 0 .. ep.boundVerts.length)
            mesh.vertices[ep.boundVerts[k]] =
                vec3Add(ep.origPos, vec3Scale(ep.slideDirs[k], ebWidth));
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

            centerSum = vec3Add(centerSum, mesh.faceCentroid(cast(uint)fi));

            normalSum = vec3Add(normalSum, mesh.faceNormal(cast(uint)fi));

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

}
