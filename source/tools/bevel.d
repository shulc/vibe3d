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
// BevelTool — polygon bevel with two handles:
//   shiftHandle  (Arrow)      : MoveTool-style drag along face normal → shift
//   insertHandle (CubicArrow) : ScaleTool-style drag along face tangent → inset
//
// On the first drag the tool detaches the selected face vertices, adds N side
// quads, and records the new vertex indices for live preview.  Subsequent drag
// events only reposition those vertices — no topology changes.
// ---------------------------------------------------------------------------

class BevelTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    EditMode* editMode;

    bool active;

    // Gizmo handles
    Arrow      shiftHandle;       // cone arrow  — shift (along normal)
    CubicArrow insertHandle;      // cube arrow  — insert (scale from face center)
    CubicArrow insertScaleArrow;  // yellow feedback arrow — length = size * insertScale

    // Cached gizmo orientation (recomputed each frame when not dragging)
    Vec3 gizmoCenter;
    Vec3 gizmoNormal;   // unit vector: average face normal
    Vec3 gizmoRight;    // unit vector: perpendicular to normal (insert axis)

    // Bevel parameters
    float shiftAmount   = 0.0f;   // world-space extrusion along normal
    float insertScale   = 1.0f;   // scale factor from face center (1 = no inset, 0 = collapsed)
    bool  groupPolygons = false;   // treat all selected faces as one group (shared center/normal)

    // Group-mode snapshot — saved at applyBevelTopology time
    Vec3 groupCenter;
    Vec3 groupNormal;

    // Topology snapshot — populated on first drag
    bool bevelApplied = false;

    struct BevelFaceData {
        Vec3[]  origPos;       // snapshot of original vertex positions at bevel time
        int[]   newVerts;      // mesh.vertices indices of the new top-face vertices
        Vec3    center;        // face centroid
        Vec3    normal;        // unit face normal
        int     origFaceIdx;   // index in mesh.faces (for revert)
        uint[]  origFaceVerts; // original face vertex array (for revert)
    }
    BevelFaceData[] bevelFaces;

    // Saved state for revertBevelTopology()
    size_t    bevelVertStart;
    size_t    bevelFaceStart;
    // Full edge snapshot — group mode removes internal edges before adding boundary ones,
    // so simple length-truncation doesn't work; we save and restore the whole edge state.
    uint[2][] edgesBeforeBevel;
    bool[]    selEdgesBeforeBevel;
    int[]     edgeOrderBeforeBevel;

    // Drag state
    int      dragHandle = -1;   // 0=shift, 1=insert, 2=free(pending), -1=none
    int      lastMX, lastMY;
    Viewport cachedVp;

    // Free-drag state (dragHandle == 2)
    int  freeDragAxis    = -1;   // -1=pending, 0=shift(Y), 1=insert(X)
    int  freeDragStartMX, freeDragStartMY;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        this.mesh     = mesh;
        this.gpu      = gpu;
        this.editMode = editMode;

        gizmoCenter = Vec3(0, 0, 0);
        gizmoNormal = Vec3(0, 1, 0);
        gizmoRight  = Vec3(1, 0, 0);

        // Placeholder positions — updated every frame in draw().
        shiftHandle      = new Arrow     (gizmoCenter, gizmoCenter, Vec3(0.2f, 0.2f, 0.9f));
        insertHandle     = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(0.9f, 0.2f, 0.2f));
        insertScaleArrow = new CubicArrow(gizmoCenter, gizmoCenter, Vec3(1.0f, 0.95f, 0.15f));
        insertScaleArrow.fixedDir = gizmoRight;  // keeps direction stable even when end < start
    }

    void destroy() {
        shiftHandle.destroy();
        insertHandle.destroy();
        insertScaleArrow.destroy();
    }

    override string name() const { return "Bevel"; }

    override void activate() {
        active        = true;
        bevelApplied  = false;
        bevelFaces    = [];
        shiftAmount   = 0.0f;
        insertScale   = 1.0f;
        dragHandle    = -1;
        freeDragAxis  = -1;
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
        recomputeCenter();
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        if (!active) return;
        cachedVp = vp;

        bool anyFace = (*editMode == EditMode.Polygons) && mesh.hasAnySelectedFaces();
        shiftHandle .setVisible(anyFace);
        insertHandle.setVisible(anyFace);

        if (anyFace) {
            // Recompute handle endpoints every frame (constant screen size, same as MoveTool).
            float size = gizmoSize(gizmoCenter, vp);

            shiftHandle.start  = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size / 6.0f));
            shiftHandle.end    = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, size));

            insertHandle.start = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size / 6.0f));
            insertHandle.end   = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size));

            shiftHandle .setForceHovered(dragHandle == 0);
            shiftHandle .setHoverBlocked(dragHandle == 1);
            insertHandle.setForceHovered(false);
            insertHandle.setHoverBlocked(dragHandle >= 0);

            // Feedback arrow: freeze start on drag begin, scale end by insertScale.
            float cubeFixed = size * 0.03f;
            if (dragHandle != 1)
                insertScaleArrow.start = insertHandle.start;  // track handle when idle
            insertScaleArrow.end           = vec3Add(gizmoCenter, vec3Scale(gizmoRight, size * insertScale));
            insertScaleArrow.fixedDir      = gizmoRight;
            insertScaleArrow.fixedCubeHalf = cubeFixed;
        }

        shiftHandle .draw(shader, vp);
        insertHandle.draw(shader, vp);
        if (dragHandle == 1 && insertScale != 0.0f)
            insertScaleArrow.draw(shader, vp);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (!active || e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Polygons)  return false;
        if (!mesh.hasAnySelectedFaces())     return false;

        if (shiftHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 0;
        else if (insertHandle.hitTest(e.x, e.y, cachedVp))
            dragHandle = 1;
        else {
            // Click outside handles — free drag: axis determined by initial movement.
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

        if (dragHandle == 2) {
            // Free drag: wait for enough movement to determine axis.
            if (freeDragAxis < 0) {
                int tdx = e.x - freeDragStartMX;
                int tdy = e.y - freeDragStartMY;
                if (tdx*tdx + tdy*tdy < 25) { lastMX = e.x; lastMY = e.y; return true; }
                import std.math : abs;
                freeDragAxis = (abs(tdx) >= abs(tdy)) ? 1 : 0;
                if (!bevelApplied) applyBevelTopology();
                lastMX = e.x; lastMY = e.y; return true;  // skip first post-lock event
            }

            if (freeDragAxis == 0) {
                // Shift: up (dy < 0) → positive shift.
                float worldScale = gizmoSize(gizmoCenter, cachedVp) * 2.0f / cachedVp.height;
                float d          = -(e.y - lastMY) * worldScale;
                shiftAmount += d;
                gizmoCenter  = vec3Add(gizmoCenter, vec3Scale(gizmoNormal, d));
            } else {
                // Insert: right (dx > 0) → scale up, left → scale down.
                float scaleFactor = 1.0f + cast(float)(e.x - lastMX) / 200.0f;
                if (insertScale * scaleFactor < 0.0f) scaleFactor = 0.0f;
                insertScale *= scaleFactor;
            }

            updateBevelVertices();
            gpu.upload(*mesh);
            lastMX = e.x; lastMY = e.y;
            return true;
        }

        // Create bevel topology on the very first motion event (handle drags).
        if (!bevelApplied) applyBevelTopology();

        if (dragHandle == 0) {
            // Shift — MoveTool style: world-space delta along face normal.
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY,
                                         gizmoCenter, gizmoNormal, cachedVp, skip);
            if (!skip) {
                shiftAmount += dot(delta, gizmoNormal);
                gizmoCenter  = vec3Add(gizmoCenter, delta);  // arrow follows the face
                updateBevelVertices();
                gpu.upload(*mesh);
            }
        } else {
            // Insert — ScaleTool style: dimensionless scale factor from face center.
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
    // Undo the topology added by applyBevelTopology() — restores modified faces,
    // truncates added vertices / faces, and fully restores the edge state.
    void revertBevelTopology() {
        foreach (ref bfd; bevelFaces)
            mesh.faces[bfd.origFaceIdx] = bfd.origFaceVerts;
        mesh.vertices.length         = bevelVertStart;
        mesh.faces.length            = bevelFaceStart;
        mesh.edges                   = edgesBeforeBevel;
        mesh.selectedEdges           = selEdgesBeforeBevel;
        mesh.edgeSelectionOrder      = edgeOrderBeforeBevel;
        bevelApplied = false;
        bevelFaces   = [];
        mesh.syncSelection();
    }

    // Recompute gizmoCenter / gizmoNormal / gizmoRight from selected faces.
    void recomputeCenter() {
        if (*editMode != EditMode.Polygons || !mesh.hasAnySelectedFaces()) return;

        Vec3 centerSum = Vec3(0, 0, 0);
        Vec3 normalSum = Vec3(0, 0, 0);
        int  count = 0;

        foreach (fi, face; mesh.faces) {
            if (fi >= mesh.selectedFaces.length || !mesh.selectedFaces[fi]) continue;
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

    // First drag: detach selected faces, create side quads, record new vertex indices.
    void applyBevelTopology() {
        bevelFaces     = [];
        bevelApplied   = true;
        groupCenter    = gizmoCenter;
        groupNormal    = gizmoNormal;
        bevelVertStart = mesh.vertices.length;
        bevelFaceStart = mesh.faces.length;

        // Always save edge state — revert restores it wholesale.
        edgesBeforeBevel    = mesh.edges.dup;
        selEdgesBeforeBevel = mesh.selectedEdges.dup;
        edgeOrderBeforeBevel = mesh.edgeSelectionOrder.dup;

        int[] selFaceIdx;
        foreach (fi, sel; mesh.selectedFaces)
            if (sel && fi < mesh.faces.length) selFaceIdx ~= cast(int)fi;

        // Group mode: build set of internal (shared-between-selected-faces) directed edges
        // and a map so shared-edge vertices get one new vertex instead of two.
        bool[ulong] internalEdgeSet;  // directed key (a<<32)|b whose reverse also exists
        int[uint]   groupVertMap;     // origVert index → new vertex index

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

            // Remove internal edges from mesh.edges (they become interior to the group).
            if (internalEdgeSet.length > 0) {
                bool[ulong] internalPairs;  // undirected: key = (min<<32)|max
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
                    keptSel ~= ei < mesh.selectedEdges.length      ? mesh.selectedEdges[ei]      : false;
                    keptOrd ~= ei < mesh.edgeSelectionOrder.length  ? mesh.edgeSelectionOrder[ei] : 0;
                }
                mesh.edges               = kept;
                mesh.selectedEdges       = keptSel;
                mesh.edgeSelectionOrder  = keptOrd;
            }
        }

        foreach (origFi; selFaceIdx) {
            uint[] origFaceVerts = mesh.faces[origFi].dup;
            int N = cast(int)origFaceVerts.length;
            if (N < 3) continue;

            Vec3[] origPos = new Vec3[](N);
            foreach (i; 0 .. N)
                origPos[i] = mesh.vertices[origFaceVerts[i]];

            // Face centroid.
            Vec3 center = Vec3(0, 0, 0);
            foreach (p; origPos) center = vec3Add(center, p);
            float invN = 1.0f / cast(float)N;
            center = Vec3(center.x*invN, center.y*invN, center.z*invN);

            // Face normal.
            Vec3 e1 = vec3Sub(origPos[1], origPos[0]);
            Vec3 e2 = vec3Sub(origPos[2], origPos[0]);
            Vec3 cr = cross(e1, e2);
            float clen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
            Vec3 faceNormal = clen > 1e-6f
                ? Vec3(cr.x/clen, cr.y/clen, cr.z/clen)
                : Vec3(0, 1, 0);

            // New top-face vertices.
            // In group mode: reuse the same new vertex for vertices shared across selected
            // faces (so adjacent top-faces stay connected along internal edges).
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

            // Replace this face with new vertex indices (keeps selection state at origFi).
            uint[] topFace = new uint[](N);
            foreach (i; 0 .. N) topFace[i] = cast(uint)newVerts[i];
            mesh.faces[origFi] = topFace;

            // Side quads: [orig_i, orig_{i+1}, new_{i+1}, new_i]
            // In group mode skip edges that are shared between two selected faces.
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
            bfd.origFaceVerts = origFaceVerts;  // already .dup'd above
            bevelFaces       ~= bfd;
        }

        mesh.syncSelection();
    }

    // Reposition top-face vertices: scale from face center + shift along normal.
    // Mirrors ScaleTool: new_pos = center + (orig - center) * insertScale + normal * shift
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
}
