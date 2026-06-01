module toolpipe.stages.actcenter;

import std.format : format;

import math    : Vec3, Viewport, screenRay, rayPlaneIntersect;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordAcen;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SymmetryPacket, ActionCenterPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// ActionCenterStage — phase 7.2a. Sits at ordinal 0x60. Replaces
// hard-coded `selectionCentroid*` in Move / Rotate / Scale with a pluggable
// origin produced by one of the `actr.<mode>` modes.
//
// Modes (the `actr.<X>` presets):
//   - Auto       — selection centroid if anything selected, else
//                  geometry centroid. Click-outside-gizmo writes
//                  `userPlacedCenter` and `userPlaced=true` but mode
//                  STAYS Auto ("Auto NOT fixed; click away → new
//                  center"). Re-selecting "Auto" in the
//                  popup clears userPlaced. The same click-outside
//                  hook also applies to None and Screen — see those
//                  modes below.
//   - Select     — strict selection centroid (no fallback to geometry).
//                  `selectSubMode` picks which side of the bounding
//                  box of the selection (center / top / bottom / back
//                  / front / left / right — bbox in world XYZ).
//   - SelectAuto — selection centroid, axis is realigned to the
//                  major world axis (the axis pick lives in AxisStage;
//                  ActionCenterStage just emits centroid).
//   - Origin     — world (0,0,0).
//   - Screen     — selection centroid (the "screen" aspect is the
//                  AXIS orientation handled by AxisStage; the action-
//                  center POSITION just tracks the selection like
//                  Auto). Click-outside relocates the gizmo onto a
//                  camera-perpendicular plane through the selection
//                  center; userPlaced wins until mode is switched.
//   - Manual     — sticky `manualCenter`, ignores selection (7.2b).
//   - Element / Local / Border — see 7.2d / 7.2e.
//
// 7.2a implements Auto + Select + SelectAuto only — Origin is trivial
// (constant), the others land in subsequent subphases.
// ---------------------------------------------------------------------------
class ActionCenterStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md: persistent packet for
    // VectorStack publishing. Updated in evaluate(VectorStack) from the
    // ToolState result of the legacy evaluate path.
    private ActionCenterPacket _publishedPacket;

    Task task() const { return Task.Acen; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        import toolpipe.packets : SubjectPacket, WorkplanePacket,
                                  SymmetryPacket;
        // Cache live viewport + upstream workplane so listAttrs
        // (called outside evaluation) and Screen mode can re-derive
        // the same value the pipeline just produced.
        if (auto subj = vts.get!SubjectPacket()) lastView_ = subj.viewport;
        if (auto wp = vts.get!WorkplanePacket()) {
            lastWpCenter_ = wp.center;
            lastWpNormal_ = wp.normal;
        }
        ActionCenterPacket pkt;
        // Local mode's per-frame center comes from the cached cluster
        // partition (see localCenterAndClustersCached) so the O(E·V) BFS is
        // not redone every drag frame. All other modes use the const
        // computeCenter() path (cheap centroid/bbox scans).
        Vec3[] localCenters;
        int[]  localClusterOf;
        if (mode == Mode.Local && mesh_ !is null) {
            pkt.center = localCenterAndClustersCached(localCenters, localClusterOf);
        } else {
            pkt.center = computeCenter();
        }

        // Phase 7.6 (BaseSide gizmo): when symmetry is on and the
        // selection contains BOTH sides of the plane (via 7.6c
        // auto-add or explicit multi-pick), the raw selection
        // centroid sits ON the symmetry plane — the gizmo lands at
        // the axis of symmetry instead of the user's clicked half.
        // Restrict the centroid to base-side verts so the gizmo
        // follows the side the user anchored on.
        if (auto sym = vts.get!SymmetryPacket()) {
            if (sym.enabled
             && sym.vertSign.length == sym.pairOf.length
             && sym.vertSign.length > 0
             && !userPlaced
             && mode != Mode.Origin && mode != Mode.Manual
             && mode != Mode.Element && mode != Mode.Local)
            {
                Vec3 baseCen;
                if (baseSideCentroid(*sym, baseCen))
                    pkt.center = baseCen;
            }
        }

        pkt.isAuto = (mode == Mode.Auto && !userPlaced);
        pkt.type   = cast(int)mode;

        // Phase 3 of the action-center parity plan: Local mode publishes
        // per-cluster pivots so transform tools can scale/rotate each
        // cluster around its own centroid (actr.local).
        if (mode == Mode.Local && mesh_ !is null) {
            if (localCenters.length >= 2) {
                pkt.clusterCenters = localCenters;
                pkt.clusterOf      = localClusterOf;
            }
        }
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);
        return true;
    }

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
        // The "(none)" entry in the Action Center popup —
        // `tool.clearTask "axis" "center"` (drops both ACEN+AXIS from
        // the toolpipe). We keep the stage installed but publish a
        // fixed origin pivot and
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

    // Default = None — a pristine pulldown state (no
    // center.* / axis.* tools registered until the user picks a
    // preset). Tests that rely on a specific mode set it explicitly.
    Mode mode = Mode.None;
    Vec3 userPlacedCenter = Vec3(0, 0, 0);  // valid when userPlaced is true
    bool userPlaced = false;                // click-outside marker for Auto / None / Screen
    Vec3 manualCenter = Vec3(0, 0, 0);      // valid for Mode.Manual
    int  selectSubMode = SelectSubMode.Center;
    // Phase 7.2e (Local mode): cluster count + first-cluster centroid
    // are recomputed in evaluate() and exposed via listAttrs() so
    // tools or UI can iterate. The single-pivot
    // `state.actionCenter.center` always = clusters[0].
    int  clusterCount_ = 0;
    // userLocked: true when the mode was set explicitly by the user via
    // `actr.<preset>` (ActrPresetCommand.apply), not by a tool preset.
    // resetTransientPipeStages skips stages with userLocked=true so
    // an explicit `actr.local` (or any other actr.*) survives tool.set.
    bool userLocked = false;

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

    // --- Local-mode cluster cache -----------------------------------------
    // During a transform drag the connected-component partition is INVARIANT
    // (selection frozen, topology frozen — transform tools mutate vertex
    // POSITIONS directly without bumping mesh.mutationVersion, on purpose),
    // so only per-cluster centers need recomputing each frame. The membership
    // partition (`_cachedClusterOf` + count) and the vertex adjacency it was
    // built from are cached and reused while the key holds.
    //
    // Cache key: (mutationVersion, editMode, selectionSignature). mutationVersion
    // bumps on every topology/geometry-structure edit (always paired with
    // topologyVersion) and is NOT bumped by selection writes NOR by drag-time
    // vertex moves — so it alone cannot detect a selection change. Selection
    // lives in the Marks.Select bit of vertexMarks/edgeMarks/faceMarks and has
    // no version counter, so we fold a cheap rolling hash of the relevant
    // marks array's Select bits into the key. Edit mode picks which cluster
    // variant runs, so it is part of the key too.
    bool   _cacheValid       = false;
    ulong  _cachedMutVer     = ulong.max;
    int    _cachedEditMode   = -1;
    ulong  _cachedSelSig     = 0;
    int    _cachedClusterCnt = 0;
    int[]  _cachedClusterOf;          // per-vertex cluster id (-1 = not in sel)
    int[]  _cachedFaceClusterOf;      // per-face cluster id (Polygons mode only)
    // Cached vertex→neighbor adjacency (CSR: flat neighbor list + per-vertex
    // [offset, offset+1] bounds). Topology-invariant, rebuilt only on a
    // mutationVersion change. Used by the vert/edge cluster BFS so neighbor
    // lookup is O(degree) instead of O(E) per dequeued vertex.
    ulong  _adjMutVer        = ulong.max;
    uint[] _adjNeighbors;             // flattened neighbor ids
    size_t[] _adjOffset;              // length nV+1; neighbors of v are
                                      // _adjNeighbors[_adjOffset[v] .. _adjOffset[v+1]]

public:
    this(Mesh* mesh, EditMode* editMode) {
        this.mesh_     = mesh;
        this.editMode_ = editMode;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "actionCenter"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }

    /// Restore declaration-time defaults. Triggered by SceneReset
    /// (= `/api/reset`) so an explicit reset wipes the ACEN mode +
    /// any sticky userPlaced / manualCenter pin alongside the mesh.
    /// Also clears userLocked — SceneReset is an unconditional full reset.
    override void reset() {
        mode             = Mode.None;
        userPlacedCenter = Vec3(0, 0, 0);
        userPlaced       = false;
        manualCenter     = Vec3(0, 0, 0);
        selectSubMode    = SelectSubMode.Center;
        clusterCount_    = 0;
        userLocked       = false;
        invalidateClusterCache();
        publishState();
    }

    /// Drop the Local-mode partition + adjacency cache. Called on reset and
    /// whenever the cache key is known to be stale. (The key check in
    /// computeLocalClustersFull also catches selection / topology changes
    /// mid-session, so this is a belt-and-braces hook for explicit resets.)
    private void invalidateClusterCache() {
        _cacheValid     = false;
        _cachedMutVer   = ulong.max;
        _cachedEditMode = -1;
        _cachedSelSig   = 0;
        _adjMutVer      = ulong.max;
    }

    /// resetTransient: same as reset() but respects userLocked.
    /// Called by resetTransientPipeStages (tool.set / tool switch) so
    /// an explicit `actr.*` user setting survives switching tools.
    void resetTransient() {
        if (userLocked) return;
        reset();
    }

    /// Set the action-center mode explicitly (called by ActrPresetCommand).
    /// Sets userLocked=true so the mode survives the next tool activation.
    void setUserMode(string modeStr) {
        bool ok = applySetAttr("mode", modeStr);
        if (ok) {
            userLocked = true;
            publishState();
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
            ["userPlacedX",   format("%g", userPlacedCenter.x)],
            ["userPlacedY",   format("%g", userPlacedCenter.y)],
            ["userPlacedZ",   format("%g", userPlacedCenter.z)],
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
    /// /Scale call this when the user clicks on empty viewport while
    /// in a relocate-allowed mode (Auto / None / Screen). Sets a sticky
    /// center without leaving the current mode — `computeCenter` then
    /// returns this point until either the mode is switched or the
    /// click is repeated. In modes that don't allow click-relocate
    /// (Select / Element / Local / Origin / Manual / Border) the call
    /// is harmless but the userPlaced flag is never read by their
    /// `computeCenter` branches.
    void setUserPlaced(Vec3 worldHit) {
        userPlacedCenter = worldHit;
        userPlaced       = true;
        publishState();
    }

    /// True iff a sticky click-outside pin is active (set via
    /// `setUserPlaced`, cleared by `resetAuto` or a mode switch).
    bool isUserPlaced() const { return userPlaced; }

    /// Switch into Manual mode and pin the center. Mirror of
    /// `setAutoUserPlaced` for callers that want strict "stay here"
    /// semantics regardless of selection changes.
    void setManualCenter(Vec3 worldPos) {
        mode         = Mode.Manual;
        manualCenter = worldPos;
        publishState();
    }

public:
    // Returns the actual Vec3 the next pipeline.evaluate would publish.
    // Used by evaluate() / listAttrs() so the panel's cenX/Y/Z displays
    // the live computed center, and by external consumers
    // (falloff_handles.d's RMB-radius gesture) that need the canonical
    // pivot without walking the full pipeline.
    Vec3 currentCenter() const {
        return computeCenter();
    }

private:

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
                // Selection centroid — Screen mode's distinguishing
                // feature is the AXIS orientation (camera-aligned),
                // handled by AxisStage. The action-center POSITION
                // tracks the selection like Auto does.
                if (userPlaced) return userPlacedCenter;
                return centroidWithGeometryFallback();
            case Mode.Element:
                // Click-pick (XfrmTransformTool.tryPickElement when
                // falloff.element is active) pushes the clicked
                // element's centroid through setUserPlaced — that
                // becomes the gizmo pivot AND the falloff sphere
                // anchor (FalloffStage.evaluate reads state.actionCenter.center).
                // No click yet → fall back to the selection-element
                // centroid (whole mesh per the universal "empty
                // selection = all" rule).
                if (userPlaced) return userPlacedCenter;
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
                // Click-outside-gizmo writes userPlaced (same hook as
                // Auto / Screen), so the gizmo + transform pivot stay
                // in sync after relocation.
                if (userPlaced) return userPlacedCenter;
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
                // matches `actr.border`.
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
                                  out int[]  clusterOf) {
        if (mesh_ is null) return;

        // --- Cache key check --------------------------------------------------
        // Membership is invariant while (mutationVersion, editMode, selSig) all
        // hold; only centers (read from live mesh_.vertices) change per frame.
        const ulong mutVer  = mesh_.mutationVersion;
        const int   edMode  = cast(int)(*editMode_);
        const ulong selSig  = selectionSignature();
        const bool  hit = _cacheValid
                       && _cachedMutVer   == mutVer
                       && _cachedEditMode == edMode
                       && _cachedSelSig   == selSig
                       && _cachedClusterOf.length == mesh_.vertices.length;

        if (!hit) {
            // MISS: rebuild membership (O(V+E) via cached adjacency) and the
            // partition, then stamp the new key.
            _cachedClusterOf.length = mesh_.vertices.length;
            foreach (ref c; _cachedClusterOf) c = -1;
            _cachedClusterCnt = 0;
            _cachedFaceClusterOf.length = 0;
            final switch (*editMode_) {
                case EditMode.Polygons:
                    buildFaceClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
                case EditMode.Edges:
                    buildEdgeClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
                case EditMode.Vertices:
                    buildVertClusterMembership(_cachedClusterOf, _cachedClusterCnt);
                    break;
            }
            _cachedMutVer   = mutVer;
            _cachedEditMode = edMode;
            _cachedSelSig   = selSig;
            _cacheValid     = true;
        }

        if (_cachedClusterCnt <= 0) return;   // nothing selected
        // Always recompute centers from the live positions (cheap, O(sel verts))
        // so a drag's per-frame motion is reflected, EXACTLY as before.
        clusterOf = _cachedClusterOf;
        clusterCenters = new Vec3[](_cachedClusterCnt);
        foreach (i; 0 .. _cachedClusterCnt)
            clusterCenters[i] = clusterBBoxCenter(clusterOf, cast(int)i);
    }

    // Per-frame Local-mode entry for evaluate(). Returns the SAME single-pivot
    // center the const computeCenter()/computeLocalClusters path produces
    // (cluster-0 AVERAGE centroid — NOT the bbox center), while also handing
    // back the per-cluster BBOX centers + partition for the published packet.
    // Both reuse the cross-frame membership cache so the O(E·V) BFS runs at
    // most once per (topology, selection, edit-mode) change instead of per
    // drag frame.
    Vec3 localCenterAndClustersCached(out Vec3[] clusterCenters,
                                      out int[]  clusterOf) {
        computeLocalClustersFull(clusterCenters, clusterOf);
        if (_cachedClusterCnt <= 0)
            return centroidWithGeometryFallback();
        // Average centroid of CLUSTER 0, replicating the per-mode single-pivot
        // formula exactly (face mode averages face centroids; vert/edge modes
        // average the cluster's verts).
        Vec3 sum = Vec3(0, 0, 0);
        int  n   = 0;
        final switch (*editMode_) {
            case EditMode.Polygons:
                // Average of the centroids of faces in cluster 0.
                foreach (fi, c; _cachedFaceClusterOf) {
                    if (c != 0) continue;
                    const(uint)[] face = mesh_.faces[fi];
                    Vec3 fc = Vec3(0, 0, 0);
                    foreach (vi; face) fc += mesh_.vertices[vi];
                    if (face.length > 0) fc = fc / cast(float)face.length;
                    sum += fc;
                    n++;
                }
                break;
            case EditMode.Edges:
            case EditMode.Vertices:
                // Average of the verts assigned to cluster 0.
                foreach (vi, c; _cachedClusterOf) {
                    if (c != 0) continue;
                    sum += mesh_.vertices[vi];
                    n++;
                }
                break;
        }
        return n > 0 ? sum / cast(float)n : centroidWithGeometryFallback();
    }

    // Cheap rolling hash of the Select bit across the marks array relevant to
    // the active edit mode. Two different selections collide with vanishingly
    // small probability; a collision would only ever cause a stale partition,
    // and selection changes during an interactive drag don't happen (the drag
    // freezes the selection), so this is safe for the cache-key use.
    ulong selectionSignature() const {
        if (mesh_ is null) return 0;
        ulong h = 1469598103934665603UL; // FNV-1a offset basis
        void mix(ulong x) { h ^= x; h *= 1099511628211UL; }
        const(uint)[] marks;
        final switch (*editMode_) {
            case EditMode.Vertices: marks = mesh_.vertexMarks; break;
            case EditMode.Edges:    marks = mesh_.edgeMarks;   break;
            case EditMode.Polygons: marks = mesh_.faceMarks;   break;
        }
        mix(marks.length);
        // Fold one bit per element (the Select bit) into the hash by index, so
        // both WHICH elements are selected and HOW MANY are captured.
        foreach (i, m; marks)
            if (m & 1 /*Marks.Select*/) mix(cast(ulong)i + 1);
        return h;
    }

    // Build (or reuse) the vertex→neighbor CSR adjacency from mesh_.edges.
    // Topology-invariant, so it is rebuilt only when mutationVersion moves.
    void ensureVertexAdjacency() {
        if (_adjMutVer == mesh_.mutationVersion
         && _adjOffset.length == mesh_.vertices.length + 1)
            return;
        const size_t nV = mesh_.vertices.length;
        // Counting pass → per-vertex degree, then prefix-sum into offsets.
        _adjOffset.length = nV + 1;
        _adjOffset[] = 0;
        foreach (edge; mesh_.edges) {
            _adjOffset[edge[0] + 1]++;
            _adjOffset[edge[1] + 1]++;
        }
        foreach (i; 1 .. nV + 1) _adjOffset[i] += _adjOffset[i - 1];
        _adjNeighbors.length = _adjOffset[nV];
        // Fill pass with a temporary cursor per vertex.
        auto cursor = new size_t[](nV);
        foreach (i; 0 .. nV) cursor[i] = _adjOffset[i];
        foreach (edge; mesh_.edges) {
            _adjNeighbors[cursor[edge[0]]++] = edge[1];
            _adjNeighbors[cursor[edge[1]]++] = edge[0];
        }
        _adjMutVer = mesh_.mutationVersion;
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

    // Membership-only builders (centers are computed by the caller from live
    // positions). They fill `clusterOf[vi]` with a cluster id per selected
    // vertex (-1 = not in selection) and set `cid` to the cluster count.
    // Topology adjacency is O(V+E) via the cached CSR / face-edge maps, NOT
    // O(E·V) per dequeued element as the old inline scans were.
    void buildFaceClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedFaces()) return;
        size_t nF = mesh_.faces.length;
        int[]  clusterOfFace = new int[](nF);
        foreach (ref c; clusterOfFace) c = -1;
        // Build face adjacency via a shared-edge map: each undirected vertex
        // pair (v0,v1) maps to the faces incident on it; two faces sharing a
        // key are edge-adjacent. O(total face corners) to build.
        uint[][ulong] facesByEdgeKey;
        ulong edgeKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32) | b
                         : (cast(ulong)b << 32) | a;
        }
        foreach (fi; 0 .. nF) {
            const(uint)[] f = mesh_.faces[fi];
            foreach (i; 0 .. f.length) {
                ulong k = edgeKey(f[i], f[(i + 1) % f.length]);
                facesByEdgeKey[k] ~= cast(uint)fi;
            }
        }
        foreach (start; 0 .. nF) {
            if (!mesh_.isFaceSelected(start) || clusterOfFace[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOfFace[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                const(uint)[] f = mesh_.faces[cur];
                foreach (i; 0 .. f.length) {
                    ulong k = edgeKey(f[i], f[(i + 1) % f.length]);
                    foreach (other; facesByEdgeKey[k]) {
                        if (other == cur) continue;
                        if (!mesh_.isFaceSelected(other) || clusterOfFace[other] != -1) continue;
                        clusterOfFace[other] = cid;
                        queue ~= other;
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
        // Stash the per-face partition so the single-pivot first-center
        // (average of face centroids in cluster 0) can be recomputed from
        // cache without redoing the BFS.
        _cachedFaceClusterOf = clusterOfFace;
    }

    void buildEdgeClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedEdges()) return;
        ensureVertexAdjacency();
        size_t nV = mesh_.vertices.length;
        // A vert participates iff it is an endpoint of some SELECTED edge; the
        // graph walked is the full vertex adjacency restricted to selected
        // edges. Build a per-(undirected-edge) selected lookup so neighbor
        // traversal can confirm the connecting edge is selected.
        bool[] inSel = new bool[](nV);
        bool[ulong] selEdgeKey;
        ulong edgeKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32) | b
                         : (cast(ulong)b << 32) | a;
        }
        foreach (i, edge; mesh_.edges) {
            if (mesh_.isEdgeSelected(i)) {
                inSel[edge[0]] = true;
                inSel[edge[1]] = true;
                selEdgeKey[edgeKey(edge[0], edge[1])] = true;
            }
        }
        foreach (start; 0 .. nV) {
            if (!inSel[start] || clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (other; _adjNeighbors[_adjOffset[cur] .. _adjOffset[cur + 1]]) {
                    if (clusterOf[other] != -1) continue;
                    if (edgeKey(cur, other) !in selEdgeKey) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
    }

    void buildVertClusterMembership(ref int[] clusterOf, ref int cid) {
        if (!mesh_.hasAnySelectedVertices()) return;
        ensureVertexAdjacency();
        size_t nV = mesh_.vertices.length;
        foreach (start; 0 .. nV) {
            if (!mesh_.isVertexSelected(start)) continue;
            if (clusterOf[start] != -1) continue;
            uint[] queue; queue ~= cast(uint)start;
            clusterOf[start] = cid;
            while (queue.length > 0) {
                uint cur = queue[0]; queue = queue[1 .. $];
                foreach (other; _adjNeighbors[_adjOffset[cur] .. _adjOffset[cur + 1]]) {
                    if (clusterOf[other] != -1) continue;
                    if (!mesh_.isVertexSelected(other)) continue;
                    clusterOf[other] = cid;
                    queue ~= other;
                }
            }
            cid++;
        }
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
        Vec3 faceCentroid(uint fi) {
            Vec3 c = Vec3(0, 0, 0);
            const(uint)[] face = mesh_.faces[fi];
            foreach (vi; face) c += mesh_.vertices[vi];
            return face.length > 0 ? c / cast(float)face.length : c;
        }
        foreach (start; 0 .. nF) {
            if (!mesh_.isFaceSelected(start) || visited[start]) continue;
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
                    if (!mesh_.isFaceSelected(other) || visited[other]) continue;
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
            if (mesh_.isEdgeSelected(i)) {
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
                    if (!mesh_.isEdgeSelected(i)) continue;
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
            if (!mesh_.isVertexSelected(start)) continue;
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
                    if (!mesh_.isVertexSelected(other)) continue;
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
    // face centroid ("click on a polygon → center to its centroid").
    // Vertex mode collapses to per-vertex average,
    // which equals the regular selection centroid.
    Vec3 elementCenter() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                bool any = mesh_.hasAnySelectedVertices();
                foreach (i, v; mesh_.vertices) {
                    if (!any || mesh_.isVertexSelected(i)) {
                        sum += v;
                        count++;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                bool any = mesh_.hasAnySelectedEdges();
                foreach (i, edge; mesh_.edges) {
                    if (any && !mesh_.isEdgeSelected(i)) continue;
                    Vec3 mid = (mesh_.vertices[edge[0]] + mesh_.vertices[edge[1]]) * 0.5f;
                    sum += mid;
                    count++;
                }
                break;
            }
            case EditMode.Polygons: {
                bool any = mesh_.hasAnySelectedFaces();
                foreach (i, face; mesh_.faces) {
                    if (any && !mesh_.isFaceSelected(i)) continue;
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
    // center pixel and intersect with the workplane plane. The action
    // center and axis are based on the frame of the viewport (screen
    // space) — picture-plane center projected to the
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
    // centroid (handles at center of selection / geometry).
    //
    // Phase 2 of the action-center parity plan: this returns the BBOX
    // CENTER of the selected verts, not the per-vertex average. The
    // empirical drag-derived pivot for actr.select / .selectauto / .auto
    // / .border is bbox center (rather than the "average vertex position"
    // form). For symmetric selections (default cube, single full face)
    // bbox == avg, so existing unit tests are unaffected.
    Vec3 centroidWithGeometryFallback() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        // mesh.selectionBBoxCenter* falls back to the whole geometry
        // when no selection bits are set ("no selection ⇒ all geometry").
        final switch (*editMode_) {
            case EditMode.Vertices: return mesh_.selectionBBoxCenterVertices();
            case EditMode.Edges:    return mesh_.selectionBBoxCenterEdges();
            case EditMode.Polygons: return mesh_.selectionBBoxCenterFaces();
        }
    }

    // Phase 7.6 (BaseSide gizmo): centroid of the current selection
    // restricted to base-side verts. Used to keep the gizmo on the
    // user-clicked half when 7.6c auto-adds the mirror counterpart
    // (raw centroid would sit on the plane otherwise).
    //
    // Returns false when there are no base-side verts in the active
    // selection — caller leaves the original centroid in place.
    bool baseSideCentroid(const ref SymmetryPacket sp, out Vec3 result) const
    {
        if (mesh_ is null || editMode_ is null) return false;
        if (sp.vertSign.length != mesh_.vertices.length) return false;

        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        bool[] visited = new bool[](mesh_.vertices.length);

        void touch(uint vi) {
            if (vi >= visited.length || visited[vi]) return;
            visited[vi] = true;
            if (sp.vertSign[vi] != sp.baseSide) return;
            sum   = sum + mesh_.vertices[vi];
            count += 1;
        }

        final switch (*editMode_) {
            case EditMode.Vertices:
                foreach (vi; 0 .. mesh_.vertices.length)
                    if (mesh_.isVertexSelected(vi))
                        touch(cast(uint)vi);
                break;
            case EditMode.Edges:
                foreach (ei; 0 .. mesh_.edges.length)
                    if (mesh_.isEdgeSelected(ei))
                        foreach (vi; mesh_.edges[ei]) touch(vi);
                break;
            case EditMode.Polygons:
                foreach (fi; 0 .. mesh_.faces.length)
                    if (mesh_.isFaceSelected(fi))
                        foreach (vi; mesh_.faces[fi]) touch(vi);
                break;
        }
        if (count == 0) return false;
        result = sum * (1.0f / cast(float)count);
        return true;
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
                    if (!hasSelV || mesh_.isVertexSelected(i)) touch(v);
                }
                break;
            case EditMode.Edges:
                foreach (i, edge; mesh_.edges) {
                    if (hasSelE && !mesh_.isEdgeSelected(i)) continue;
                    foreach (vi; edge)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i, face; mesh_.faces) {
                    if (hasSelF && !mesh_.isFaceSelected(i)) continue;
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
                // Auto-userPlaced sub-state, as a popup re-click does.
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
            case "userPlacedCenter": {
                // Vec3 convenience: "x,y,z" pushes all three components
                // + sets userPlaced=true in one HTTP call.
                import std.string : split, strip;
                import std.conv   : to;
                auto parts = value.split(",");
                if (parts.length != 3) return false;
                try {
                    userPlacedCenter.x = parts[0].strip.to!float;
                    userPlacedCenter.y = parts[1].strip.to!float;
                    userPlacedCenter.z = parts[2].strip.to!float;
                } catch (Exception) { return false; }
                userPlaced = true;
                return true;
            }
            case "userPlacedX": case "userPlacedY": case "userPlacedZ": {
                // Sticky click-outside / click-pick pin. Sets
                // userPlaced=true and the matching component without
                // switching mode — Auto / None / Screen / Element all
                // read userPlaced first when set. This is the HTTP
                // counterpart to setUserPlaced() and is what tests
                // use to simulate the post-click state for the Element
                // falloff pivot path without a real GPU-hover-driven
                // click.
                import std.conv : to;
                float v;
                try v = value.to!float;
                catch (Exception) return false;
                if      (name == "userPlacedX") userPlacedCenter.x = v;
                else if (name == "userPlacedY") userPlacedCenter.y = v;
                else                            userPlacedCenter.z = v;
                userPlaced = true;
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
