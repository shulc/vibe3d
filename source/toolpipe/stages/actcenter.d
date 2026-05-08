module toolpipe.stages.actcenter;

import std.format : format;

import math    : Vec3, Viewport, screenRay, rayPlaneIntersect;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordAcen;
import toolpipe.pipeline : ToolState;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// ActionCenterStage — phase 7.2a. Sits at LXs_ORD_ACEN = 0x60. Replaces
// hard-coded `selectionCentroid*` in Move / Rotate / Scale with a pluggable
// origin produced by one of the MODO `actr.<mode>` modes.
//
// Modes (mirror MODO `cmdhelptools.cfg` `actr.<X>`):
//   - Auto       — selection centroid if anything selected, else
//                  geometry centroid. Click-outside-gizmo writes
//                  `userPlacedCenter` and `userPlaced=true` but mode
//                  STAYS Auto (matches MODO "Auto NOT fixed; click
//                  away → new center"). Re-selecting "Auto" in the
//                  popup clears userPlaced.
//   - Select     — strict selection centroid (no fallback to geometry).
//                  `selectSubMode` picks which side of the bounding
//                  box of the selection (center / top / bottom / back
//                  / front / left / right — bbox in world XYZ).
//   - SelectAuto — selection centroid, axis is realigned to the
//                  major world axis (the axis pick lives in AxisStage;
//                  ActionCenterStage just emits centroid).
//   - Origin     — world (0,0,0).
//   - Screen     — picture-plane center (camera-derived; 7.2b).
//   - Manual     — sticky `manualCenter`, ignores selection (7.2b).
//   - Element / Local / Border — see 7.2d / 7.2e.
//
// 7.2a implements Auto + Select + SelectAuto only — Origin is trivial
// (constant), the others land in subsequent subphases.
// ---------------------------------------------------------------------------
class ActionCenterStage : Stage {
    enum Mode {
        Auto       = 0,
        Select     = 1,
        SelectAuto = 2,
        Element    = 3,    // 7.2d
        Local      = 4,    // 7.2e
        Origin     = 5,    // 7.2b
        Screen     = 6,    // 7.2b
        Border     = 7,    // 7.2e
        Manual     = 8,    // 7.2b
        // MODO's "(none)" entry in the Action Center popup. In MODO this
        // is `tool.clearTask "axis" "center"` (drops both ACEN+AXIS from
        // the toolpipe — see resrc/701_frm_modomodes_forms.cfg:687). We
        // keep the stage installed but publish a fixed origin pivot and
        // mark the packet non-Auto, so transform tools can fall back to
        // world origin without a special-case.
        None       = 9,
    }
    enum SelectSubMode {
        Center = 0,
        Top    = 1, Bottom = 2,
        Back   = 3, Front  = 4,
        Left   = 5, Right  = 6,
    }

    // Default = None — matches MODO's pristine pulldown state (no
    // center.* / axis.* tools registered until the user picks a
    // preset). Tests that rely on a specific mode set it explicitly.
    Mode mode = Mode.None;
    Vec3 userPlacedCenter = Vec3(0, 0, 0);  // valid when userPlaced is true
    bool userPlaced = false;                // Auto-mode click-outside marker
    Vec3 manualCenter = Vec3(0, 0, 0);      // valid for Mode.Manual
    int  selectSubMode = SelectSubMode.Center;
    // Phase 7.2e (Local mode): cluster count + first-cluster centroid
    // are recomputed in evaluate() and exposed via listAttrs() so
    // tools or UI can iterate. The single-pivot
    // `state.actionCenter.center` always = clusters[0].
    int  clusterCount_ = 0;

private:
    // Stage holds direct refs to the live mesh + edit mode; re-evaluating
    // on each pipeline pass walks the current selection arrays. Cheap —
    // centroid is O(verts) and only runs when a tool actually consumes
    // state.actionCenter (typically Move/Rotate/Scale's per-frame update).
    Mesh*     mesh_;
    EditMode* editMode_;
    // Cached viewport from the last evaluate() — Screen mode needs it to
    // ray-cast the screen-center pixel onto the workplane. listAttrs()
    // doesn't run inside the pipeline, so it reads back the cache.
    Viewport  lastView_;
    // Cached upstream workplane state (origin + normal) for Screen mode.
    Vec3      lastWpCenter_  = Vec3(0, 0, 0);
    Vec3      lastWpNormal_  = Vec3(0, 1, 0);

public:
    this(Mesh* mesh, EditMode* editMode) {
        this.mesh_     = mesh;
        this.editMode_ = editMode;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "actionCenter"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }

    override void evaluate(ref ToolState state) {
        // Cache live view + upstream workplane so listAttrs (called
        // outside evaluation) and Screen mode can re-derive the same
        // value the pipeline just produced.
        lastView_     = state.view;
        lastWpCenter_ = state.workplane.center;
        lastWpNormal_ = state.workplane.normal;
        state.actionCenter.center = computeCenter();
        state.actionCenter.isAuto = (mode == Mode.Auto && !userPlaced);
        state.actionCenter.type   = cast(int)mode;

        // Phase 3 of doc/acen_modo_parity_plan.md: Local mode publishes
        // per-cluster pivots so transform tools can scale/rotate each
        // cluster around its own centroid (matches MODO's actr.local).
        // Other modes leave the per-element fields empty — tools then
        // fall back to the single `center` pivot.
        state.actionCenter.clusterCenters = null;
        state.actionCenter.clusterOf      = null;
        if (mode == Mode.Local && mesh_ !is null) {
            Vec3[] centers;
            int[]  clusterOf;
            computeLocalClustersFull(centers, clusterOf);
            if (centers.length >= 2) {
                // Single-cluster Local degrades to single-pivot — no
                // need to ship the per-element arrays.
                state.actionCenter.clusterCenters = centers;
                state.actionCenter.clusterOf      = clusterOf;
            }
        }
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        Vec3 c = currentCenter();
        // Local mode exposes cluster count alongside the first-cluster
        // pivot. Other modes report 0 (no per-cluster semantics).
        int clusters = 0;
        if (mode == Mode.Local) {
            Vec3 dummy;
            computeLocalClusters(dummy, clusters);
        }
        return [
            ["mode",          modeLabel()],
            ["cenX",          format("%g", c.x)],
            ["cenY",          format("%g", c.y)],
            ["cenZ",          format("%g", c.z)],
            ["userPlaced",    userPlaced ? "true" : "false"],
            ["selectSubMode", selectSubModeLabel()],
            ["clusterCount",  format("%d", clusters)],
        ];
    }

    /// `tool.set actr.auto` semantics — reset Auto sub-state to "follow
    /// selection". Switching mode to Auto via setAttr also goes through
    /// here so the popup re-click clears any previous click-outside.
    void resetAuto() {
        mode = Mode.Auto;
        userPlaced = false;
        publishState();
    }

    /// Click-outside-gizmo entrypoint for transform tools. Move/Rotate
    /// /Scale call this when the user clicks on the empty viewport
    /// while in Auto mode (sets a sticky center without leaving Auto).
    /// Outside Auto mode this is a no-op — Manual mode has its own
    /// `setManualCenter` which switches mode explicitly.
    void setAutoUserPlaced(Vec3 worldHit) {
        userPlacedCenter = worldHit;
        userPlaced       = true;
        publishState();
    }

    /// Switch into Manual mode and pin the center. Mirror of
    /// `setAutoUserPlaced` for callers that want strict "stay here"
    /// semantics regardless of selection changes.
    void setManualCenter(Vec3 worldPos) {
        mode         = Mode.Manual;
        manualCenter = worldPos;
        publishState();
    }

private:
    // Returns the actual Vec3 the next pipeline.evaluate would publish.
    // Used both by evaluate() and by listAttrs() so the panel's cenX/Y/Z
    // displays the live computed center, not a stale cache.
    Vec3 currentCenter() const {
        return computeCenter();
    }

    Vec3 computeCenter() const {
        final switch (mode) {
            case Mode.Auto:
                if (userPlaced) return userPlacedCenter;
                return centroidWithGeometryFallback();
            case Mode.Select:
                return selectionCentroid(/*sub*/ selectSubMode);
            case Mode.SelectAuto:
                // Same center as Select; AxisStage realigns the basis.
                return selectionCentroid(SelectSubMode.Center);
            case Mode.Origin:
                return Vec3(0, 0, 0);
            case Mode.Manual:
                return manualCenter;
            case Mode.Screen:
                return screenCenter();
            case Mode.Element:
                return elementCenter();
            case Mode.Local: {
                Vec3 first;
                int  count;
                computeLocalClusters(first, count);
                return count > 0 ? first : centroidWithGeometryFallback();
            }
            case Mode.None:
                // No designated action center — for visual placement
                // (gizmo position) and translate-drag plane reference,
                // fall back to the same centroid Auto would give.
                // Rotate / Scale that need a real pivot can detect this
                // mode (state.actionCenter.type) and fall back further
                // to world origin.
                return centroidWithGeometryFallback();
            case Mode.Border:
                // Bbox center of selection-border verts — those on edges
                // with one selected and one unselected adjacent face.
                // For closed/symmetric selections the border == the full
                // selection (cube top face: every edge is bounded by
                // unselected faces below it), so the result equals
                // `centroidWithGeometryFallback`. For open/partial
                // selections (sphere top hemisphere: only the equator
                // ring is on a border edge) the result differs and
                // matches MODO `actr.border`.
                if (mesh_ is null) return Vec3(0, 0, 0);
                final switch (*editMode_) {
                    case EditMode.Vertices: return centroidWithGeometryFallback();
                    case EditMode.Edges:    return centroidWithGeometryFallback();
                    case EditMode.Polygons: return mesh_.selectionBorderBBoxCenterFaces();
                }
        }
    }

    // Phase 3 follow-up to computeLocalClusters: enumerate ALL clusters
    // and assign every selected vertex to its cluster id. Used by
    // evaluate() to populate ActionCenterPacket.{clusterCenters,
    // clusterOf} so tools can apply per-cluster pivots. Cluster centers
    // are bounding-box midpoints (consistent with Phase 2's bbox-Select
    // choice). `clusterOf[vi] == -1` for verts not in the selection.
    void computeLocalClustersFull(out Vec3[] clusterCenters,
                                  out int[]  clusterOf) const {
        if (mesh_ is null) return;
        clusterOf = new int[](mesh_.vertices.length);
        foreach (ref c; clusterOf) c = -1;
        final switch (*editMode_) {
            case EditMode.Polygons:
                computeLocalFaceClustersFull(clusterCenters, clusterOf);
                break;
            case EditMode.Edges:
                computeLocalEdgeClustersFull(clusterCenters, clusterOf);
                break;
            case EditMode.Vertices:
                computeLocalVertClustersFull(clusterCenters, clusterOf);
                break;
        }
    }

    // Helper: bbox center of vertices in a cluster (verts identified by
    // clusterOf == cid). Mirrors mesh.selectionBBoxCenterFaces() but
    // restricted to one cluster.
    Vec3 clusterBBoxCenter(const(int)[] clusterOf, int cid) const {
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (vi, c; clusterOf) {
            if (c != cid) continue;
            Vec3 v = mesh_.vertices[vi];
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    void computeLocalFaceClustersFull(out Vec3[] clusterCenters,
                                      ref int[]  clusterOf) const {
        if (!mesh_.hasAnySelectedFaces()) return;
        size_t nF = mesh_.faces.length;
        int[]  clusterOfFace = new int[](nF);
        foreach (ref c; clusterOfFace) c = -1;
        bool faceShareEdge(uint a, uint b) {
            const(uint)[] fa = mesh_.faces[a];
            const(uint)[] fb = mesh_.faces[b];
            foreach (i; 0 .. fa.length) {
                uint v0 = fa[i];
                uint v1 = fa[(i + 1) % fa.length];
                foreach (j; 0 .. fb.length) {
                    uint w0 = fb[j];
                    uint w1 = fb[(j + 1) % fb.length];
                    if ((v0 == w0 && v1 == w1) || (v0 == w1 && v1 == w0))
                        return true;
                }
            }
            return false;
        }
        bool selectedFace(size_t i) {
            return i < mesh_.selectedFaces.length && mesh_.selectedFaces[i];
        }
        int cid = 0;
        foreach (start; 0 .. nF) {
            if (!selectedFace(start) || clusterOfFace[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOfFace[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (other; 0 .. nF) {
                    if (!selectedFace(other) || clusterOfFace[other] != -1) continue;
                    if (faceShareEdge(cur, cast(uint)other)) {
                        clusterOfFace[other] = cid;
                        queue ~= cast(uint)other;
                    }
                }
            }
            cid++;
        }
        // Project face cluster ids onto verts. A vertex shared between
        // two disjoint clusters keeps the lowest cid (deterministic).
        foreach (fi; 0 .. nF) {
            int c = clusterOfFace[fi];
            if (c == -1) continue;
            foreach (vi; mesh_.faces[fi]) {
                if (clusterOf[vi] == -1 || c < clusterOf[vi])
                    clusterOf[vi] = c;
            }
        }
        clusterCenters = new Vec3[](cid);
        foreach (i; 0 .. cid) clusterCenters[i] = clusterBBoxCenter(clusterOf, cast(int)i);
    }

    void computeLocalEdgeClustersFull(out Vec3[] clusterCenters,
                                      ref int[]  clusterOf) const {
        if (!mesh_.hasAnySelectedEdges()) return;
        size_t nV = mesh_.vertices.length;
        bool[] inSel = new bool[](nV);
        foreach (i, edge; mesh_.edges) {
            if (i < mesh_.selectedEdges.length && mesh_.selectedEdges[i]) {
                inSel[edge[0]] = true;
                inSel[edge[1]] = true;
            }
        }
        int cid = 0;
        foreach (start; 0 .. nV) {
            if (!inSel[start] || clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (i, edge; mesh_.edges) {
                    if (!(i < mesh_.selectedEdges.length
                          && mesh_.selectedEdges[i])) continue;
                    uint other = uint.max;
                    if      (edge[0] == cur) other = edge[1];
                    else if (edge[1] == cur) other = edge[0];
                    if (other == uint.max || clusterOf[other] != -1) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
        clusterCenters = new Vec3[](cid);
        foreach (i; 0 .. cid) clusterCenters[i] = clusterBBoxCenter(clusterOf, cast(int)i);
    }

    void computeLocalVertClustersFull(out Vec3[] clusterCenters,
                                      ref int[]  clusterOf) const {
        if (!mesh_.hasAnySelectedVertices()) return;
        size_t nV = mesh_.vertices.length;
        int cid = 0;
        foreach (start; 0 .. nV) {
            if (!(start < mesh_.selectedVertices.length
                  && mesh_.selectedVertices[start])) continue;
            if (clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (edge; mesh_.edges) {
                    uint other = uint.max;
                    if      (edge[0] == cur) other = edge[1];
                    else if (edge[1] == cur) other = edge[0];
                    if (other == uint.max || clusterOf[other] != -1) continue;
                    if (!(other < mesh_.selectedVertices.length
                          && mesh_.selectedVertices[other])) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
        clusterCenters = new Vec3[](cid);
        foreach (i; 0 .. cid) clusterCenters[i] = clusterBBoxCenter(clusterOf, cast(int)i);
    }

    // Local mode: enumerate connected components inside the current
    // selection (face graph for face mode — faces sharing an edge are
    // one cluster; vertex graph for vert / edge mode — verts sharing
    // an edge are one cluster). For each cluster, compute its centroid.
    // Output: `firstCenter` = clusters[0]; `count` = total clusters.
    // `state.actionCenter.center` reads firstCenter; per-cluster pivots
    // for tools that iterate (Rotate, Scale) come in a follow-up
    // subphase via ElementCenterPacket.
    void computeLocalClusters(out Vec3 firstCenter, out int count) const {
        firstCenter = Vec3(0, 0, 0);
        count = 0;
        if (mesh_ is null) return;
        final switch (*editMode_) {
            case EditMode.Polygons:
                computeLocalFaceClusters(firstCenter, count);
                break;
            case EditMode.Edges:
                computeLocalEdgeClusters(firstCenter, count);
                break;
            case EditMode.Vertices:
                computeLocalVertClusters(firstCenter, count);
                break;
        }
    }

    void computeLocalFaceClusters(out Vec3 firstCenter, out int count) const {
        // Face-graph BFS: faces sharing an edge are connected.
        if (!mesh_.hasAnySelectedFaces()) return;
        size_t nF = mesh_.faces.length;
        bool[] visited = new bool[](nF);
        // Build face-adjacency on the fly: for each pair of selected
        // faces, check if they share at least one edge (= a vertex
        // pair). O(F²·avg_face_size); cheap at typical mesh sizes.
        bool faceShareEdge(uint a, uint b) {
            const(uint)[] fa = mesh_.faces[a];
            const(uint)[] fb = mesh_.faces[b];
            foreach (i; 0 .. fa.length) {
                uint v0 = fa[i];
                uint v1 = fa[(i + 1) % fa.length];
                foreach (j; 0 .. fb.length) {
                    uint w0 = fb[j];
                    uint w1 = fb[(j + 1) % fb.length];
                    if ((v0 == w0 && v1 == w1) || (v0 == w1 && v1 == w0))
                        return true;
                }
            }
            return false;
        }
        bool selectedFace(size_t i) {
            return i < mesh_.selectedFaces.length && mesh_.selectedFaces[i];
        }
        Vec3 faceCentroid(uint fi) {
            Vec3 c = Vec3(0, 0, 0);
            const(uint)[] face = mesh_.faces[fi];
            foreach (vi; face) c += mesh_.vertices[vi];
            return face.length > 0 ? c / cast(float)face.length : c;
        }
        foreach (start; 0 .. nF) {
            if (!selectedFace(start) || visited[start]) continue;
            // BFS.
            uint[] queue;
            queue ~= cast(uint)start;
            visited[start] = true;
            Vec3 sum = Vec3(0, 0, 0);
            int  n = 0;
            while (queue.length > 0) {
                uint cur = queue[0];
                queue = queue[1 .. $];
                sum += faceCentroid(cur);
                n++;
                foreach (other; 0 .. nF) {
                    if (!selectedFace(other) || visited[other]) continue;
                    if (faceShareEdge(cur, cast(uint)other)) {
                        visited[other] = true;
                        queue ~= cast(uint)other;
                    }
                }
            }
            Vec3 cen = n > 0 ? sum / cast(float)n : Vec3(0, 0, 0);
            if (count == 0) firstCenter = cen;
            count++;
        }
    }

    void computeLocalEdgeClusters(out Vec3 firstCenter, out int count) const {
        // Vertex-graph BFS over the verts touched by selected edges.
        if (!mesh_.hasAnySelectedEdges()) return;
        size_t nV = mesh_.vertices.length;
        bool[] inSel = new bool[](nV);
        foreach (i, edge; mesh_.edges) {
            if (i < mesh_.selectedEdges.length && mesh_.selectedEdges[i]) {
                inSel[edge[0]] = true;
                inSel[edge[1]] = true;
            }
        }
        // Adjacency only via SELECTED edges.
        bool[] visited = new bool[](nV);
        foreach (start; 0 .. nV) {
            if (!inSel[start] || visited[start]) continue;
            uint[] queue;
            queue ~= cast(uint)start;
            visited[start] = true;
            Vec3 sum = Vec3(0, 0, 0);
            int  n = 0;
            while (queue.length > 0) {
                uint cur = queue[0];
                queue = queue[1 .. $];
                sum += mesh_.vertices[cur];
                n++;
                foreach (i, edge; mesh_.edges) {
                    if (!(i < mesh_.selectedEdges.length
                          && mesh_.selectedEdges[i])) continue;
                    uint other = uint.max;
                    if      (edge[0] == cur) other = edge[1];
                    else if (edge[1] == cur) other = edge[0];
                    if (other == uint.max || visited[other]) continue;
                    visited[other] = true;
                    queue ~= other;
                }
            }
            Vec3 cen = n > 0 ? sum / cast(float)n : Vec3(0, 0, 0);
            if (count == 0) firstCenter = cen;
            count++;
        }
    }

    void computeLocalVertClusters(out Vec3 firstCenter, out int count) const {
        // Vertex-graph BFS via mesh edges among SELECTED verts.
        if (!mesh_.hasAnySelectedVertices()) return;
        size_t nV = mesh_.vertices.length;
        bool[] visited = new bool[](nV);
        foreach (start; 0 .. nV) {
            if (!(start < mesh_.selectedVertices.length
                  && mesh_.selectedVertices[start])) continue;
            if (visited[start]) continue;
            uint[] queue;
            queue ~= cast(uint)start;
            visited[start] = true;
            Vec3 sum = Vec3(0, 0, 0);
            int  n = 0;
            while (queue.length > 0) {
                uint cur = queue[0];
                queue = queue[1 .. $];
                sum += mesh_.vertices[cur];
                n++;
                foreach (edge; mesh_.edges) {
                    uint other = uint.max;
                    if      (edge[0] == cur) other = edge[1];
                    else if (edge[1] == cur) other = edge[0];
                    if (other == uint.max || visited[other]) continue;
                    if (!(other < mesh_.selectedVertices.length
                          && mesh_.selectedVertices[other])) continue;
                    visited[other] = true;
                    queue ~= other;
                }
            }
            Vec3 cen = n > 0 ? sum / cast(float)n : Vec3(0, 0, 0);
            if (count == 0) firstCenter = cen;
            count++;
        }
    }

    // Element mode: average of per-element centroids of the selected
    // elements (NOT the bbox of all their vertices). Differs from
    // Select sub-mode=Center for face/edge selection — here we treat
    // each selected face / edge as one logical "element" and average
    // its own centroid. With a single face selected this gives the
    // face centroid (matches MODO's "click on a polygon → center to
    // its centroid"). Vertex mode collapses to per-vertex average,
    // which equals the regular selection centroid.
    Vec3 elementCenter() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                bool any = mesh_.hasAnySelectedVertices();
                foreach (i, v; mesh_.vertices) {
                    if (!any || (i < mesh_.selectedVertices.length
                                 && mesh_.selectedVertices[i])) {
                        sum += v;
                        count++;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                bool any = mesh_.hasAnySelectedEdges();
                foreach (i, edge; mesh_.edges) {
                    if (any && !(i < mesh_.selectedEdges.length
                                 && mesh_.selectedEdges[i])) continue;
                    Vec3 mid = (mesh_.vertices[edge[0]] + mesh_.vertices[edge[1]]) * 0.5f;
                    sum += mid;
                    count++;
                }
                break;
            }
            case EditMode.Polygons: {
                bool any = mesh_.hasAnySelectedFaces();
                foreach (i, face; mesh_.faces) {
                    if (any && !(i < mesh_.selectedFaces.length
                                 && mesh_.selectedFaces[i])) continue;
                    Vec3 c = Vec3(0, 0, 0);
                    foreach (vi; face) c += mesh_.vertices[vi];
                    if (face.length > 0) c = c / cast(float)face.length;
                    sum += c;
                    count++;
                }
                break;
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    // Screen mode: cast a ray from the camera's eye through the screen
    // center pixel and intersect with the workplane plane. Matches MODO
    // "the action center and axis to be based on the frame of the
    // viewport, or screen space" — picture-plane center projected to the
    // construction plane. If the workplane is parallel to the camera
    // ray the projection degenerates; fall back to the camera focus
    // point so we never publish a NaN center.
    Vec3 screenCenter() const {
        // No view captured yet (stage just constructed) — use the
        // workplane center as a sane default.
        if (lastView_.width == 0 || lastView_.height == 0)
            return lastWpCenter_;
        Vec3 ray = screenRay(cast(int)(lastView_.width / 2),
                             cast(int)(lastView_.height / 2),
                             lastView_);
        Vec3 hit;
        if (rayPlaneIntersect(lastView_.eye, ray,
                              lastWpCenter_, lastWpNormal_, hit))
            return hit;
        // Degenerate (ray ⟂ plane normal). Fall back to camera focus.
        // In practice this hits when the camera looks along the
        // workplane plane edge-on; use the perpendicular projection of
        // eye onto the workplane.
        Vec3 d = lastView_.eye - lastWpCenter_;
        float h = d.x * lastWpNormal_.x + d.y * lastWpNormal_.y + d.z * lastWpNormal_.z;
        return lastView_.eye - lastWpNormal_ * h;
    }

    // Auto mode: selection centroid if any selection, else geometry-bbox
    // centroid (matches MODO "handles at center of selection / geometry").
    //
    // Phase 2 of doc/acen_modo_parity_plan.md: this returns the BBOX
    // CENTER of the selected verts, not the per-vertex average. MODO 9's
    // empirical drag-derived pivot for actr.select / .selectauto / .auto
    // / .border is bbox center; the docs say "average vertex position"
    // but the artifact disagrees (see tools/modo_diff/run_acen_drag.sh
    // asymmetric pattern). For symmetric selections (default cube,
    // single full face) bbox == avg, so existing unit tests are
    // unaffected.
    Vec3 centroidWithGeometryFallback() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        // mesh.selectionBBoxCenter* falls back to the whole geometry
        // when no selection bits are set, matching MODO's "no selection
        // ⇒ all geometry" behaviour.
        final switch (*editMode_) {
            case EditMode.Vertices: return mesh_.selectionBBoxCenterVertices();
            case EditMode.Edges:    return mesh_.selectionBBoxCenterEdges();
            case EditMode.Polygons: return mesh_.selectionBBoxCenterFaces();
        }
    }

    // Strict selection centroid — falls back to all-geometry only if
    // there genuinely is no selection AND no geometry (empty mesh).
    // Sub-mode picks one of the 7 bbox positions in WORLD axis-aligned
    // space, decision per phase7_2_plan.md §1 (resolved).
    Vec3 selectionCentroid(int sub) const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        if (sub == SelectSubMode.Center)
            return centroidWithGeometryFallback();
        // For non-center sub-modes, walk the same vert set as the
        // centroid path and track per-axis min/max.
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool any = false;
        void touch(Vec3 v) {
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            any = true;
        }
        // Determine which verts contribute (matches selectionCentroid* logic).
        bool hasSelV = mesh_.hasAnySelectedVertices();
        bool hasSelE = mesh_.hasAnySelectedEdges();
        bool hasSelF = mesh_.hasAnySelectedFaces();
        bool[] visited = new bool[](mesh_.vertices.length);
        final switch (*editMode_) {
            case EditMode.Vertices:
                foreach (i, v; mesh_.vertices) {
                    if (!hasSelV || (i < mesh_.selectedVertices.length
                                  && mesh_.selectedVertices[i])) touch(v);
                }
                break;
            case EditMode.Edges:
                foreach (i, edge; mesh_.edges) {
                    if (hasSelE && !(i < mesh_.selectedEdges.length
                                  && mesh_.selectedEdges[i])) continue;
                    foreach (vi; edge)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i, face; mesh_.faces) {
                    if (hasSelF && !(i < mesh_.selectedFaces.length
                                  && mesh_.selectedFaces[i])) continue;
                    foreach (vi; face)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
        }
        if (!any) return Vec3(0, 0, 0);
        Vec3 cen = (mn + mx) * 0.5f;
        final switch (cast(SelectSubMode)sub) {
            case SelectSubMode.Center: return cen;
            case SelectSubMode.Top:    return Vec3(cen.x, mx.y, cen.z);
            case SelectSubMode.Bottom: return Vec3(cen.x, mn.y, cen.z);
            case SelectSubMode.Back:   return Vec3(cen.x, cen.y, mn.z);
            case SelectSubMode.Front:  return Vec3(cen.x, cen.y, mx.z);
            case SelectSubMode.Left:   return Vec3(mn.x, cen.y, cen.z);
            case SelectSubMode.Right:  return Vec3(mx.x, cen.y, cen.z);
        }
    }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "mode": {
                Mode m;
                if      (value == "auto")       m = Mode.Auto;
                else if (value == "select")     m = Mode.Select;
                else if (value == "selectauto") m = Mode.SelectAuto;
                else if (value == "element")    m = Mode.Element;
                else if (value == "local")      m = Mode.Local;
                else if (value == "origin")     m = Mode.Origin;
                else if (value == "screen")     m = Mode.Screen;
                else if (value == "border")     m = Mode.Border;
                else if (value == "manual")     m = Mode.Manual;
                else if (value == "none")       m = Mode.None;
                else return false;
                // Switching mode (including Auto→Auto re-pick) clears the
                // Auto-userPlaced sub-state — matches MODO popup re-click.
                mode = m;
                userPlaced = false;
                return true;
            }
            case "cenX": case "cenY": case "cenZ": {
                import std.conv : to;
                float v;
                try v = value.to!float;
                catch (Exception) return false;
                if      (name == "cenX") manualCenter.x = v;
                else if (name == "cenY") manualCenter.y = v;
                else                     manualCenter.z = v;
                // Setting a coord component implies the user wants a
                // sticky pin — promote to Manual unless already there.
                if (mode != Mode.Manual) mode = Mode.Manual;
                return true;
            }
            case "selectSubMode": {
                if      (value == "center") selectSubMode = SelectSubMode.Center;
                else if (value == "top")    selectSubMode = SelectSubMode.Top;
                else if (value == "bottom") selectSubMode = SelectSubMode.Bottom;
                else if (value == "back")   selectSubMode = SelectSubMode.Back;
                else if (value == "front")  selectSubMode = SelectSubMode.Front;
                else if (value == "left")   selectSubMode = SelectSubMode.Left;
                else if (value == "right")  selectSubMode = SelectSubMode.Right;
                else return false;
                return true;
            }
            default: return false;
        }
    }

    string modeLabel() const {
        final switch (mode) {
            case Mode.Auto:       return "auto";
            case Mode.Select:     return "select";
            case Mode.SelectAuto: return "selectauto";
            case Mode.Element:    return "element";
            case Mode.Local:      return "local";
            case Mode.Origin:     return "origin";
            case Mode.Screen:     return "screen";
            case Mode.Border:     return "border";
            case Mode.Manual:     return "manual";
            case Mode.None:       return "none";
        }
    }

    string selectSubModeLabel() const {
        final switch (cast(SelectSubMode)selectSubMode) {
            case SelectSubMode.Center: return "center";
            case SelectSubMode.Top:    return "top";
            case SelectSubMode.Bottom: return "bottom";
            case SelectSubMode.Back:   return "back";
            case SelectSubMode.Front:  return "front";
            case SelectSubMode.Left:   return "left";
            case SelectSubMode.Right:  return "right";
        }
    }

    void publishState() {
        setStatePath("actionCenter/mode", modeLabel());
        setStatePath("actionCenter/userPlaced", userPlaced ? "true" : "false");
        setStatePath("actionCenter/selectSubMode", selectSubModeLabel());
    }
}
