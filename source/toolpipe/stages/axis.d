module toolpipe.stages.axis;

import std.format : format;
import std.math   : abs, sqrt;

import math    : Vec3, Viewport, cross, dot, normalize, frameMatrix, frameMatrixInverse,
                 applyAffine;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordAxis;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : AxisPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import document          : Layer;

// ---------------------------------------------------------------------------
// AxisStage — phase 7.2c. Sits at ordinal 0x70 (after ACEN).
// Replaces TransformTool.currentBasis() — Move/Rotate/Scale read their
// gizmo orientation from state.axis instead of querying WorkplaneStage
// directly. Default mode=Auto reproduces the same basis as before
// (workplane when non-auto, pickMostFacingPlane fallback otherwise),
// so existing tool behaviour is preserved.
//
// Modes (the `axis.<X>` and `actr.<X>` presets):
//   - Auto       — same as Workplane if WorkplaneStage non-auto, else
//                  pickMostFacingPlane(view) (camera-snapped world axis
//                  triple). "Axis aligned to World OR Work Plane".
//   - World      — identity (right=+X, up=+Y, fwd=+Z).
//   - Workplane  — workplane.axis1/normal/axis2 from upstream WORK
//                  stage. Mapping: right=axis1, up=normal, fwd=axis2
//                  (per phase7_2_plan §6 — Y-up convention).
//   - Select / SelectAuto / Element / Local / Origin / Screen / Manual
//                  stubbed (degrade to Auto until 7.2d/7.2e/7.2f land).
//
// AxisPacket layout: right / up / fwd (forward); axIndex hint stays at
// -1 in 7.2 — populated when an axis-locked tool needs the principal
// axis index (out of scope for 7.2).
// ---------------------------------------------------------------------------
class AxisStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md.
    private AxisPacket _publishedPacket;

    Task task() const { return Task.Axis; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        import toolpipe.packets : SubjectPacket, WorkplanePacket,
                                  ActionCenterPacket;
        // Cache upstream state — both the viewport (subject) and the
        // workplane (its packet) are needed by computeBasis().
        if (auto subj = vts.get!SubjectPacket()) lastView_ = subj.viewport;
        if (auto wp = vts.get!WorkplanePacket()) {
            lastWpAxis1_  = wp.axis1;
            lastWpNormal_ = wp.normal;
            lastWpAxis2_  = wp.axis2;
            lastWpIsAuto_ = wp.isAuto;
        }
        AxisPacket pkt;
        Vec3 r, u, f;
        computeBasis(r, u, f);
        pkt.right   = r;
        pkt.up      = u;
        pkt.fwd     = f;
        // Cache the orthonormal frame matrix + inverse from the SAME
        // right/up/fwd just computed (single source of truth, so the
        // matrix and the basis vectors can never disagree). `m` puts the
        // basis in columns 0/1/2; `mInv` is the transpose (== inverse for
        // an orthonormal frame). GLOBAL frame only — no per-cluster m/mInv
        // (no consumer). Forward-compat: nothing reads these yet.
        pkt.m       = frameMatrix(r, u, f);
        pkt.mInv    = frameMatrixInverse(r, u, f);
        pkt.axIndex = axIndex;
        pkt.type    = cast(int)mode;
        pkt.isAuto  = (mode == Mode.Auto);
        pkt.clusterRight = null;
        pkt.clusterUp    = null;
        pkt.clusterFwd   = null;

        // Phase 4 of the action-center parity plan: Local mode publishes
        // per-cluster basis when ACEN.Local has multiple clusters.
        // AxisStage runs after ActionCenterStage (ordAxis > ordAcen).
        if (mode == Mode.Local
            && mesh_ !is null && editMode_ !is null)
        {
            if (auto acen = vts.get!ActionCenterPacket()) {
                if (acen.clusterCenters.length >= 2) {
                    int n = cast(int)acen.clusterCenters.length;
                    pkt.clusterRight = new Vec3[](n);
                    pkt.clusterUp    = new Vec3[](n);
                    pkt.clusterFwd   = new Vec3[](n);
                    foreach (cid; 0 .. n) {
                        Vec3 cr, cu, cf;
                        if (computeClusterBasis(acen.clusterOf,
                                                cid, cr, cu, cf)) {
                            pkt.clusterRight[cid] = cr;
                            pkt.clusterUp[cid]    = cu;
                            pkt.clusterFwd[cid]   = cf;
                        } else {
                            pkt.clusterRight[cid] = r;
                            pkt.clusterUp[cid]    = u;
                            pkt.clusterFwd[cid]   = f;
                        }
                    }
                }
            }
        }

        _publishedPacket = pkt;
        vts.put(&_publishedPacket);
        return true;
    }

    enum Mode {
        Auto       = 0,
        World      = 1,
        Workplane  = 2,
        Select     = 3,    // 7.2d
        SelectAuto = 4,    // 7.2d
        Element    = 5,    // 7.2d
        Local      = 6,    // 7.2e
        Origin     = 7,    // alias of World — rotates around (0,0,0) axes
        Screen     = 8,    // camera-aligned (7.2 follow-up)
        Manual     = 9,    // user-pinned right/up/fwd (7.2 follow-up)
        // Companion of ActionCenterStage.Mode.None —
        // tool.clearTask("axis","center") drops both. We keep the stage
        // installed but publish world XYZ as a sane default basis.
        None       = 10,
        // Task 0082 — new item-hierarchy modes.
        Pivot      = 11,  // basis = primary item's orientation (capture-inferred)
        Parent     = 12,  // basis = parent item's world rotation
    }

    // flex_border_handles_plan.md Model C — the ONE general boolean the gizmo
    // reads to decide whether the rendered basis follows the gesture rotation.
    // True for the SELECTION-DERIVED axis modes (their basis is anchored to the
    // selected geometry, so it co-rotates with a flex rotate); false for the
    // world-/screen-/origin-fixed modes (which stay put under any gesture).
    // Border maps to axis=select (presets.cfg), so it's covered by Select. This
    // is a PURE function of the mode — no drag/mutable state — so the idle /
    // listAttrs deterministic path is untouched (Risk 6). The gizmo never names
    // a mode; it asks this single declared capability of the axis sub-tool.
    static bool modeTracksSelection(Mode m) pure nothrow @nogc @safe {
        return m == Mode.Select || m == Mode.SelectAuto || m == Mode.Local;
    }
    bool axisTracksSelection() const pure nothrow @nogc @safe {
        return modeTracksSelection(mode);
    }

    // Default = None — companion of ActionCenterStage's default (see
    // its comment). Tests that need a specific mode set it explicitly.
    Mode mode = Mode.None;
    Vec3 manualRight = Vec3(1, 0, 0);
    Vec3 manualUp    = Vec3(0, 1, 0);
    Vec3 manualFwd   = Vec3(0, 0, 1);
    int  axIndex     = -1;
    // userLocked: true when mode was set by an explicit `actr.*` command
    // (ActrPresetCommand). resetTransientPipeStages skips locked stages.
    bool userLocked  = false;

private:
    // Cached upstream view + workplane — Auto mode in absence of an
    // active workplane needs the camera direction; Screen mode (when
    // it lands) needs the same.
    Viewport lastView_;
    Vec3     lastWpAxis1_  = Vec3(1, 0, 0);
    Vec3     lastWpNormal_ = Vec3(0, 1, 0);
    Vec3     lastWpAxis2_  = Vec3(0, 0, 1);
    bool     lastWpIsAuto_ = true;
    // Direct mesh refs for Element / Local modes (face/edge/vertex
    // normals). Optional — the stage works without when only World /
    // Workplane / Auto modes are used.
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh_() const { return meshSrc_ ? meshSrc_() : null; }
    EditMode* editMode_;
    // Task 0082: delegate supplying the primary Layer for Pivot/Parent modes.
    Layer delegate() primarySrc_;
    @property Layer primary_() const { return primarySrc_ ? primarySrc_() : null; }

public:
    this(Mesh* delegate() meshSrc = null, EditMode* editMode = null,
         Layer delegate() primarySrc = null) {
        this.meshSrc_    = meshSrc;
        this.editMode_   = editMode;
        this.primarySrc_ = primarySrc;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Axis; }
    override string   id()       const                          { return "axis"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAxis; }

    /// Restore declaration-time defaults — invoked from SceneReset
    /// (= `/api/reset`). Also clears userLocked — unconditional full reset.
    override void reset() {
        mode        = Mode.None;
        manualRight = Vec3(1, 0, 0);
        manualUp    = Vec3(0, 1, 0);
        manualFwd   = Vec3(0, 0, 1);
        axIndex     = -1;
        userLocked  = false;
        publishState();
    }

    /// resetTransient: same as reset() but respects userLocked.
    /// Called by resetTransientPipeStages (tool.set / tool switch) so
    /// an explicit `actr.*` user setting survives switching tools.
    void resetTransient() {
        if (userLocked) return;
        reset();
    }

    /// Set the axis mode explicitly (called by ActrPresetCommand).
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
        Vec3 r, u, f;
        currentBasis(r, u, f);
        return [
            ["mode",   modeLabel()],
            ["rightX", format("%g", r.x)], ["rightY", format("%g", r.y)], ["rightZ", format("%g", r.z)],
            ["upX",    format("%g", u.x)], ["upY",    format("%g", u.y)], ["upZ",    format("%g", u.z)],
            ["fwdX",   format("%g", f.x)], ["fwdY",   format("%g", f.y)], ["fwdZ",   format("%g", f.z)],
        ];
    }

    /// Snapshot-friendly basis read for callers outside the pipeline
    /// (e.g. listAttrs / property panel). Uses last-cached upstream
    /// values when called between evaluate() passes.
    void currentBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        computeBasis(right, up, fwd);
    }

private:
    void computeBasis(out Vec3 r, out Vec3 u, out Vec3 f) const {
        final switch (mode) {
            case Mode.World:
            case Mode.Origin:
            case Mode.None:    // "(none)" pulldown — no dedicated axis
                               // basis; tools see world XYZ.
                r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                return;
            case Mode.Workplane: {
                // Manual workplane only — auto-workplane (camera-derived)
                // would let tool handles swap with orbit which we don't
                // want. Default to world XYZ when workplane is auto.
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) {
                    r = a1; u = n; f = a2;
                } else {
                    r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                }
                return;
            }
            case Mode.Auto: {
                // Manual workplane (non-auto) ⇒ tool handles follow it
                // explicitly. Auto workplane ⇒ pin to world XYZ — the
                // upstream WorkplaneStage's auto basis follows
                // pickMostFacingPlane(camera) which swaps every 45° of
                // orbit, but we don't want tool handles' X/Y/Z to jump
                // around as the user navigates. Manual workplane =
                // explicit user choice; auto = leave handles stable.
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) {
                    r = a1; u = n; f = a2;
                } else {
                    r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                }
                return;
            }
            case Mode.Manual:
                r = manualRight; u = manualUp; f = manualFwd;
                return;
            case Mode.Element:
                if (computeElementBasis(r, u, f)) return;
                goto case Mode.Auto;       // fall back to workplane basis
            case Mode.Select:
            case Mode.SelectAuto:
                if (computeSelectionBboxBasis(r, u, f)) return;
                goto case Mode.Auto;
            case Mode.Local: {
                // Local GLOBAL fallback = workplane (manual) or world XYZ. The real
                // per-cluster Local basis is published separately in evaluate()
                // (clusterRight/Up/Fwd when ACEN.Local has ≥2 clusters).
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) { r = a1; u = n; f = a2; }
                else { r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1); }
                return;
            }
            case Mode.Screen: {
                // Screen basis = camera frame remapped (capture-verified,
                // selection-independent):
                //   right = camera up,  up = camera right,  fwd = camera view-direction.
                // The view matrix (math.lookAt, column-major) stores the camera
                // basis in its rows:
                //   camRight = (m[0],m[4],m[8]),  camUp = (m[1],m[5],m[9]),
                //   camFwd   = -(m[2],m[6],m[10]).
                if (lastView_.width == 0 || lastView_.height == 0) {
                    // No live viewport yet (headless before first subject packet)
                    // → world XYZ, same safe default the other branches use.
                    r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                    return;
                }
                const float[16] m = lastView_.view;
                // Pole / gimbal guard: at elevation ±90° lookAt's cross product
                // for the right vector degenerates to zero and normalize() would
                // produce NaN (math.normalize has no zero-guard).
                // `!(rLenSq > eps)` catches both NaN (NaN comparisons are always
                // false) and near-zero magnitudes, falling back to world XYZ.
                float rLenSq = m[0]*m[0] + m[4]*m[4] + m[8]*m[8];
                if (!(rLenSq > 1e-6f)) {
                    r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                    return;
                }
                Vec3 camRight = normalize(Vec3( m[0],  m[4],  m[8]));
                Vec3 camUp    = normalize(Vec3( m[1],  m[5],  m[9]));
                Vec3 camFwd   = normalize(Vec3(-m[2], -m[6], -m[10]));
                r = camUp;     // screen-X  ← camera up
                u = camRight;  // screen-Y  ← camera right
                f = camFwd;    // screen-Z  ← camera view direction (into scene)
                return;
            }
            case Mode.Pivot: {
                // basis = primary item orientation (strips scale via normalize).
                // capture-inferred: pivot rotation was not independently varied;
                // identity observed because pivot rotation == item rotation for
                // unrotated items. The parent-case rotation evidence (v1/v2)
                // proves the axis stage does reflect item rotation, so a rotated
                // item (== rotated pivot) rotates this basis the same way.
                // Not in modeTracksSelection (item-fixed, not selection-derived).
                auto l = primary_();
                if (l is null) { r = Vec3(1,0,0); u = Vec3(0,1,0); f = Vec3(0,0,1); return; }
                float[16] m = l.xform.composedMatrix();
                r = normalize(Vec3(m[0], m[1], m[2]));
                u = normalize(Vec3(m[4], m[5], m[6]));
                f = normalize(Vec3(m[8], m[9], m[10]));
                return;
            }
            case Mode.Parent: {
                // basis = parent item's world rotation (normalize to strip scale).
                // Reads exactly ONE level. Capture-verified ~1e-4.
                // Not in modeTracksSelection (parent-fixed, not selection-derived).
                auto l = primary_();
                auto p = (l !is null) ? l.parent : null;
                if (p is null) { r = Vec3(1,0,0); u = Vec3(0,1,0); f = Vec3(0,0,1); return; }
                float[16] m = p.xform.composedMatrix();
                r = normalize(Vec3(m[0], m[1], m[2]));
                u = normalize(Vec3(m[4], m[5], m[6]));
                f = normalize(Vec3(m[8], m[9], m[10]));
                return;
            }
        }
    }

    // Selection-derived basis (Selection / Selection Center Auto Axis
    // algorithm):
    // - Polygons / Vertices mode: `up` = avg face normal (snapped to
    //   nearest world axis); `right` = world axis with the largest
    //   in-plane (perpendicular to up) bbox extent of the selection.
    //   For face / vertex selections handle Y always points along the
    //   face-normal direction.
    // - Edges mode: degrades to pure bbox-extent-sort (a more nuanced
    //   edge-tangent axis is handled in a follow-up).
    // fwd = cross(right, up) keeps the basis strictly right-handed.
    bool computeSelectionBboxBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        if (mesh_ is null || editMode_ is null) return false;
        // World-axis bbox of vertices touched by the selection.
        bool[] visited = new bool[](mesh_.vertices.length);
        float[3] mn = [float.infinity, float.infinity, float.infinity];
        float[3] mx = [-float.infinity, -float.infinity, -float.infinity];
        Vec3 normalAcc = Vec3(0, 0, 0);   // sum of face normals (face / vert)
        bool any = false;
        void touchVert(uint vi) {
            if (visited[vi]) return;
            visited[vi] = true;
            Vec3 v = mesh_.vertices[vi];
            float[3] p = [v.x, v.y, v.z];
            foreach (k; 0 .. 3) {
                if (p[k] < mn[k]) mn[k] = p[k];
                if (p[k] > mx[k]) mx[k] = p[k];
            }
            any = true;
        }
        final switch (*editMode_) {
            case EditMode.Polygons:
                if (!mesh_.hasAnySelectedFaces()) return false;
                foreach (i, face; mesh_.faces) {
                    if (!mesh_.isFaceSelected(i)) continue;
                    normalAcc = normalAcc + mesh_.faceNormal(cast(uint)i);
                    foreach (vi; face) touchVert(vi);
                }
                break;
            case EditMode.Edges:
                if (!mesh_.hasAnySelectedEdges()) return false;
                foreach (i, edge; mesh_.edges) {
                    if (!mesh_.isEdgeSelected(i)) continue;
                    foreach (vi; edge) touchVert(vi);
                }
                break;
            case EditMode.Vertices:
                if (!mesh_.hasAnySelectedVertices()) return false;
                foreach (vi; 0 .. mesh_.vertices.length) {
                    if (!mesh_.isVertexSelected(vi)) continue;
                    touchVert(cast(uint)vi);
                    // Per-vert normal = sum of incident face normals.
                    foreach (fi, face; mesh_.faces) {
                        foreach (fvi; face)
                            if (fvi == vi) {
                                normalAcc = normalAcc
                                          + mesh_.faceNormal(cast(uint)fi);
                                break;
                            }
                    }
                }
                break;
        }
        if (!any) return false;

        Vec3[3] worldAxes = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
        float[3] extents = [mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]];

        // Decide the selection local frame.
        bool haveNormal = normalAcc.x != 0 || normalAcc.y != 0 || normalAcc.z != 0;
        if (haveNormal && (*editMode_ == EditMode.Polygons
                           || *editMode_ == EditMode.Vertices))
        {
            // Selection local frame convention (axis-aligned faces):
            //   fwd  = snapped face normal (outward, keeps sign).
            //   up   = per-normal-AXIS fixed vector, sign-independent:
            //            normal on X-axis → up = world −Y
            //            normal on Y-axis → up = world −Z
            //            normal on Z-axis → up = world +Y
            //   right = cross(up, fwd)  — right-handed.
            //
            // For a non-axis-aligned normalAcc (e.g. a diagonal or mixed
            // selection where no single world axis dominates cleanly),
            // the frame falls through to the edge bbox-extent sort below.
            // This matches the observed identity/default frame the
            // reference returns for such cases (not a bisector).

            // Snap avg normal to the nearest world axis. Sign follows
            // the dominant component so fwd points outward.
            float ax = abs(normalAcc.x);
            float ay = abs(normalAcc.y);
            float az = abs(normalAcc.z);
            int fwdIdx = (ax >= ay && ax >= az) ? 0 : (ay >= az ? 1 : 2);
            float fwdSign = ((fwdIdx == 0 ? normalAcc.x
                            : fwdIdx == 1 ? normalAcc.y
                                          : normalAcc.z) >= 0) ? 1.0f : -1.0f;
            fwd = worldAxes[fwdIdx] * fwdSign;

            // Per-axis in-plane secondary (up/Y): fixed lookup, sign-
            // independent of the face normal's sign.
            //   X-axis → up = −Y   (upIdx=1, upSign=−1)
            //   Y-axis → up = −Z   (upIdx=2, upSign=−1)
            //   Z-axis → up = +Y   (upIdx=1, upSign=+1)
            int upIdx;
            float upSign;
            if (fwdIdx == 0) { upIdx = 1; upSign = -1.0f; }       // X→−Y
            else if (fwdIdx == 1) { upIdx = 2; upSign = -1.0f; }  // Y→−Z
            else { upIdx = 1; upSign = 1.0f; }                    // Z→+Y
            up = worldAxes[upIdx] * upSign;

            // right = cross(up, fwd) — right-handed (right × up = fwd).
            right = cross(up, fwd);
            return true;
        }
        // Edge mode (no robust normal) — fall back to pure bbox-extent
        // sort. Largest extent → right, middle → up, smallest → fwd.
        int[3] idx = [0, 1, 2];
        if (extents[idx[1]] > extents[idx[0]]) { int t = idx[0]; idx[0] = idx[1]; idx[1] = t; }
        if (extents[idx[2]] > extents[idx[0]]) { int t = idx[0]; idx[0] = idx[2]; idx[2] = t; }
        if (extents[idx[2]] > extents[idx[1]]) { int t = idx[1]; idx[1] = idx[2]; idx[2] = t; }
        right = worldAxes[idx[0]];
        up    = worldAxes[idx[1]];
        fwd   = cross(right, up);
        return true;
    }

    // Per-cluster basis (Phase 4 of the action-center parity plan). Same
    // algorithm as computeSelectionBboxBasis but restricted to vertices
    // marked with cluster id `cid` in the supplied `clusterOf` array
    // (built by ActionCenterStage.Local). Used when ACEN.Local has ≥2
    // disjoint clusters so each cluster gets its own world-axis-snapped
    // basis. Returns false when the cluster has no vertices, or in edit
    // modes (Edges) where the bbox-extent fallback alone is unhelpful.
    bool computeClusterBasis(const(int)[] clusterOf, int cid,
                             out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        if (mesh_ is null || editMode_ is null) return false;
        if (clusterOf.length != mesh_.vertices.length) return false;
        float[3] mn = [float.infinity, float.infinity, float.infinity];
        float[3] mx = [-float.infinity, -float.infinity, -float.infinity];
        Vec3 normalAcc = Vec3(0, 0, 0);
        bool any = false;
        foreach (vi, c; clusterOf) {
            if (c != cid) continue;
            Vec3 v = mesh_.vertices[vi];
            float[3] p = [v.x, v.y, v.z];
            foreach (k; 0 .. 3) {
                if (p[k] < mn[k]) mn[k] = p[k];
                if (p[k] > mx[k]) mx[k] = p[k];
            }
            any = true;
        }
        if (!any) return false;

        // Sum face normals for faces whose verts are all in this cluster
        // (face mode), or for any face touching a cluster-vertex (vertex
        // mode). Edge mode lacks normals so we fall through to bbox sort.
        if (*editMode_ == EditMode.Polygons || *editMode_ == EditMode.Vertices) {
            foreach (fi, face; mesh_.faces) {
                bool inCluster = false;
                if (*editMode_ == EditMode.Polygons) {
                    if (!mesh_.isFaceSelected(fi))
                        continue;
                    // A face is in the cluster if all its verts are
                    // assigned cid. (Mirrors how we project face cluster
                    // ids onto verts in ACEN's computeLocalFaceClustersFull.)
                    inCluster = true;
                    foreach (vi; face) {
                        if (clusterOf[vi] != cid) { inCluster = false; break; }
                    }
                } else {
                    foreach (vi; face) {
                        if (clusterOf[vi] == cid) { inCluster = true; break; }
                    }
                }
                if (inCluster)
                    normalAcc = normalAcc + mesh_.faceNormal(cast(uint)fi);
            }
        }

        Vec3[3] worldAxes = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
        float[3] extents = [mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]];
        bool haveNormal = normalAcc.x != 0 || normalAcc.y != 0 || normalAcc.z != 0;
        if (haveNormal && (*editMode_ == EditMode.Polygons
                           || *editMode_ == EditMode.Vertices))
        {
            // Per-cluster local frame matching the reference engine's
            // polygon convention:
            //   fwd  (index 2) = the SIGNED face normal (snapped to the
            //                    nearest world axis),
            //   right(index 0) = world +X projected onto the tangent plane
            //                    when that projection is non-degenerate
            //                    (i.e. for Y/Z-aligned fwd). For X-aligned
            //                    fwd the +X projection vanishes; instead
            //                    `right` is the major principal-component
            //                    axis of the cluster's verts in the YZ
            //                    tangent plane. Confirmed against the
            //                    reference engine on 5 X-aligned cluster
            //                    shapes (Z-dominant strip, Y-dominant strip,
            //                    L-shape, centered square, off-center
            //                    square) plus an asymmetric 2-cluster
            //                    Y-aligned re-capture pinning the world +X
            //                    projection for Y/Z-aligned.
            //   up   (index 1) = fwd × right   (right-handed: right×up=fwd).
            // This puts the normal on the Z/fwd axis (not Y/up) and derives
            // the tangent from a fixed world reference (or PCA, for the
            // X-aligned fallback) rather than the bbox extents, so
            // opposite-facing clusters get opposite fwd/up and a shared
            // drag axis transforms each cluster in its own frame.
            float ax = abs(normalAcc.x);
            float ay = abs(normalAcc.y);
            float az = abs(normalAcc.z);
            int nIdx = (ax >= ay && ax >= az) ? 0 : (ay >= az ? 1 : 2);
            float sign = ((nIdx == 0 ? normalAcc.x
                         : nIdx == 1 ? normalAcc.y
                                      : normalAcc.z) >= 0) ? 1.0f : -1.0f;
            fwd = worldAxes[nIdx] * sign;
            if (nIdx == 0) {
                // X-aligned fwd: world +X projects to zero on the YZ
                // tangent plane, so the historical "+Z fallback" rule
                // diverged from the reference engine on correlated
                // (e.g. L-shaped) clusters. Use the principal-component
                // axis of cluster verts in YZ instead; fall back to the
                // +Z axis when the distribution is isotropic (square
                // patches, single-cell selections, etc.) so the
                // pre-PCA behavior is preserved for those clusters.
                float meanY = 0, meanZ = 0;
                int n = 0;
                foreach (vi2, c2; clusterOf) {
                    if (c2 != cid) continue;
                    meanY += mesh_.vertices[vi2].y;
                    meanZ += mesh_.vertices[vi2].z;
                    n++;
                }
                if (n > 0) { meanY /= n; meanZ /= n; }
                float covYY = 0, covZZ = 0, covYZ = 0;
                foreach (vi2, c2; clusterOf) {
                    if (c2 != cid) continue;
                    float dy = mesh_.vertices[vi2].y - meanY;
                    float dz = mesh_.vertices[vi2].z - meanZ;
                    covYY += dy * dy;
                    covZZ += dz * dz;
                    covYZ += dy * dz;
                }
                float diff = covYY - covZZ;
                float discr = sqrt(diff * diff + 4.0f * covYZ * covYZ);
                if (discr < 1e-6f) {
                    // Isotropic: fall back to world +Z (matches the
                    // reference engine's tie behavior for centered
                    // squares and trivially-shaped clusters).
                    right = worldAxes[2];
                } else {
                    // Major-eigenvalue eigenvector of the 2x2 YZ
                    // covariance matrix [covYY, covYZ; covYZ, covZZ].
                    // λmax − covYY = (discr + diff) / 2; that drives
                    // the (eY, eZ) eigenvector direction.
                    float eY, eZ;
                    if (abs(covYZ) > 1e-6f) {
                        eY = covYZ;
                        eZ = (discr + diff) * 0.5f;
                    } else if (covYY >= covZZ) {
                        eY = 1; eZ = 0;
                    } else {
                        eY = 0; eZ = 1;
                    }
                    float invMag = 1.0f / sqrt(eY * eY + eZ * eZ);
                    eY *= invMag;
                    eZ *= invMag;
                    // Canonicalize sign: first non-fwd-aligned world
                    // component in order Y → Z must be positive.
                    if (abs(eY) > 1e-6f) {
                        if (eY < 0) { eY = -eY; eZ = -eZ; }
                    } else if (eZ < 0) {
                        eZ = -eZ;
                    }
                    right = Vec3(0, eY, eZ);
                }
            } else {
                // Y- or Z-aligned fwd: world +X projects cleanly onto
                // the tangent plane. Matches the reference engine
                // (re-confirmed by the asymmetric_local Y-handle
                // re-capture) and keeps existing fixtures byte-stable.
                Vec3 refAxis = worldAxes[0];
                right = normalize(refAxis - fwd * dot(refAxis, fwd));
            }
            up = cross(fwd, right);
            return true;
        }
        // Edge mode: pure bbox-extent sort.
        int[3] idx = [0, 1, 2];
        if (extents[idx[1]] > extents[idx[0]]) { int t = idx[0]; idx[0] = idx[1]; idx[1] = t; }
        if (extents[idx[2]] > extents[idx[0]]) { int t = idx[0]; idx[0] = idx[2]; idx[2] = t; }
        if (extents[idx[2]] > extents[idx[1]]) { int t = idx[1]; idx[1] = idx[2]; idx[2] = t; }
        right = worldAxes[idx[0]];
        up    = worldAxes[idx[1]];
        fwd   = cross(right, up);
        return true;
    }

    // Element mode basis: uses the first selected element's normal as
    // `up`. For face mode, reads the face normal directly via Newell's
    // method (mesh.faceNormal). For edge mode, uses edge tangent as
    // `right` with up = world Y. For vertex mode, averages incident
    // face normals as `up`. Returns false when no selection is active
    // (caller falls back to Auto).
    bool computeElementBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        if (mesh_ is null || editMode_ is null) return false;
        Vec3 nUp;
        Vec3 nRight;
        bool got = false;
        final switch (*editMode_) {
            case EditMode.Polygons: {
                if (!mesh_.hasAnySelectedFaces()) return false;
                foreach (i, _; mesh_.faces) {
                    if (mesh_.isFaceSelected(i)) {
                        nUp = mesh_.faceNormal(cast(uint)i);
                        // Tangent: first edge of the face, projected
                        // perpendicular to the face normal.
                        const uint[] face = mesh_.faces[i];
                        Vec3 e0 = mesh_.vertices[face[1]] - mesh_.vertices[face[0]];
                        Vec3 proj = e0 - nUp * dot(e0, nUp);
                        nRight = normalize(proj);
                        got = true;
                        break;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                if (!mesh_.hasAnySelectedEdges()) return false;
                foreach (i, edge; mesh_.edges) {
                    if (mesh_.isEdgeSelected(i)) {
                        Vec3 t = mesh_.vertices[edge[1]] - mesh_.vertices[edge[0]];
                        nRight = normalize(t);
                        // Up = workplane normal projected perpendicular to
                        // edge tangent. Falls back to world Z when the
                        // workplane normal is parallel to the edge tangent
                        // (dot = ±1 → proj = zero-vector → NaN otherwise).
                        Vec3 wpUp = lastWpNormal_;
                        Vec3 proj = wpUp - nRight * dot(wpUp, nRight);
                        if (proj.x == 0 && proj.y == 0 && proj.z == 0) {
                            // Edge is parallel to workplane normal; pick
                            // world Z as secondary, fall back to world X.
                            Vec3 worldZ = Vec3(0, 0, 1);
                            proj = worldZ - nRight * dot(worldZ, nRight);
                            if (proj.x == 0 && proj.y == 0 && proj.z == 0) {
                                Vec3 worldX = Vec3(1, 0, 0);
                                proj = worldX - nRight * dot(worldX, nRight);
                            }
                        }
                        nUp = normalize(proj);
                        got = true;
                        break;
                    }
                }
                break;
            }
            case EditMode.Vertices: {
                if (!mesh_.hasAnySelectedVertices()) return false;
                // Sum incident face normals across selected verts to
                // form an averaged "vertex normal". Imperfect (no
                // weighting by face area), but a coarse vertex-normal
                // heuristic is close enough for gizmo alignment.
                Vec3 acc = Vec3(0, 0, 0);
                foreach (vi; 0 .. mesh_.vertices.length) {
                    if (!mesh_.isVertexSelected(vi)) continue;
                    foreach (fi, face; mesh_.faces)
                        foreach (vj; face)
                            if (vj == vi) {
                                acc += mesh_.faceNormal(cast(uint)fi);
                                break;
                            }
                }
                if (acc.x == 0 && acc.y == 0 && acc.z == 0) return false;
                nUp = normalize(acc);
                // Right = world X projected perpendicular to up.
                Vec3 worldX = Vec3(1, 0, 0);
                Vec3 proj = worldX - nUp * dot(worldX, nUp);
                if (proj.x == 0 && proj.y == 0 && proj.z == 0) {
                    // Up is parallel to world X; use world Z instead.
                    Vec3 worldZ = Vec3(0, 0, 1);
                    proj = worldZ - nUp * dot(worldZ, nUp);
                }
                nRight = normalize(proj);
                got = true;
                break;
            }
        }
        if (!got) return false;
        right = nRight;
        up    = nUp;
        fwd   = cross(right, up);
        // Re-orthogonalise: cross gives an exact perpendicular even
        // if right wasn't strictly perpendicular to up.
        right = cross(up, fwd);
        return true;
    }

    // Look up WorkplaneStage from the global pipe context and read its
    // current basis directly. Returns false if no WorkplaneStage is
    // registered OR it's in auto-mode (auto-mode basis is camera-derived
    // — only available during evaluate()). True path lets listAttrs and
    // out-of-pipeline callers see the live workplane basis without
    // running a full pipe.evaluate().
    bool queryWorkplaneBasis(out Vec3 axis1, out Vec3 normal, out Vec3 axis2) const {
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stages.workplane : WorkplaneStage;
        if (g_pipeCtx is null) return false;
        auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work);
        if (wp is null || wp.isAuto) return false;
        wp.currentBasis(normal, axis1, axis2);
        return true;
    }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "mode": {
                Mode m;
                if      (value == "auto")       m = Mode.Auto;
                else if (value == "world")      m = Mode.World;
                else if (value == "workplane")  m = Mode.Workplane;
                else if (value == "select")     m = Mode.Select;
                else if (value == "selectauto") m = Mode.SelectAuto;
                else if (value == "element")    m = Mode.Element;
                else if (value == "local")      m = Mode.Local;
                else if (value == "origin")     m = Mode.Origin;
                else if (value == "screen")     m = Mode.Screen;
                else if (value == "manual")     m = Mode.Manual;
                else if (value == "none")       m = Mode.None;
                else if (value == "pivot")      m = Mode.Pivot;
                else if (value == "parent")     m = Mode.Parent;
                else return false;
                mode = m;
                return true;
            }
            default: return false;
        }
    }

    string modeLabel() const {
        final switch (mode) {
            case Mode.Auto:       return "auto";
            case Mode.World:      return "world";
            case Mode.Workplane:  return "workplane";
            case Mode.Select:     return "select";
            case Mode.SelectAuto: return "selectauto";
            case Mode.Element:    return "element";
            case Mode.Local:      return "local";
            case Mode.Origin:     return "origin";
            case Mode.Screen:     return "screen";
            case Mode.Manual:     return "manual";
            case Mode.None:       return "none";
            case Mode.Pivot:      return "pivot";
            case Mode.Parent:     return "parent";
        }
    }

    void publishState() {
        setStatePath("axis/mode", modeLabel());
    }
}

// ---------------------------------------------------------------------------
// Tests — cached orthonormal frame matrix m / mInv on the published packet.
//
// AxisStage's behaviour tests live in tests/test_toolpipe_axis.d (HTTP, which
// can only observe the basis VECTORS via /api/toolpipe attrs — not the packet
// matrix). The forward-compat m/mInv fields aren't surfaced over HTTP, so we
// verify them here by driving evaluate() directly with a Manual basis (Manual
// mode reads manualRight/Up/Fwd and needs neither a mesh nor the global pipe
// context). This justifies the otherwise-unread fields.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.math : isClose, sin, cos, PI;
    import math : matMul4, applyAffine, identityMatrix;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, AxisPacket;
}

unittest {
    // Non-trivial right-handed orthonormal frame: 30° about +Y.
    immutable float a = cast(float) PI / 6;
    immutable float c = cos(a), s = sin(a);
    Vec3 r = Vec3(c, 0, -s);
    Vec3 u = Vec3(0, 1, 0);
    Vec3 f = Vec3(s, 0,  c);

    auto st = new AxisStage();          // no mesh/editmode needed for Manual
    st.mode        = AxisStage.Mode.Manual;
    st.manualRight = r;
    st.manualUp    = u;
    st.manualFwd   = f;

    SubjectPacket subj;                 // viewport unused by Manual mode
    VectorStack vts;
    vts.put(&subj);
    assert(st.evaluate(vts));

    AxisPacket* pkt = vts.get!AxisPacket();
    assert(pkt !is null);

    enum float tol = 1e-5f;

    // Sanity: published basis is the non-trivial frame we set.
    assert(isClose(pkt.fwd.x, s, tol, tol) && !isClose(pkt.fwd.z, 1.0f, tol, tol));

    // 1) m's basis columns equal right/up/fwd (column-major, m[row + col*4]:
    //    column 0 = m[0..2], column 1 = m[4..6], column 2 = m[8..10]).
    assert(isClose(pkt.m[0], pkt.right.x, tol, tol));
    assert(isClose(pkt.m[1], pkt.right.y, tol, tol));
    assert(isClose(pkt.m[2], pkt.right.z, tol, tol));
    assert(isClose(pkt.m[4], pkt.up.x,    tol, tol));
    assert(isClose(pkt.m[5], pkt.up.y,    tol, tol));
    assert(isClose(pkt.m[6], pkt.up.z,    tol, tol));
    assert(isClose(pkt.m[8],  pkt.fwd.x,  tol, tol));
    assert(isClose(pkt.m[9],  pkt.fwd.y,  tol, tol));
    assert(isClose(pkt.m[10], pkt.fwd.z,  tol, tol));

    // 2) m * mInv ≈ identity (via the project's matMul4).
    auto prod = matMul4(pkt.m, pkt.mInv);
    foreach (i; 0 .. 16)
        assert(isClose(prod[i], identityMatrix[i], tol, tol));

    // 3) applyAffine(m, unit-x) == right — confirms the multiply convention
    //    is NOT transposed (a transposed m would yield mInv·x = a row, not right).
    auto mx = applyAffine(pkt.m, Vec3(1, 0, 0));
    assert(isClose(mx.x, pkt.right.x, tol, tol));
    assert(isClose(mx.y, pkt.right.y, tol, tol));
    assert(isClose(mx.z, pkt.right.z, tol, tol));
}
