module toolpipe.stages.axis;

import std.format : format;
import std.math   : abs, sqrt;

import math    : Vec3, Viewport, cross, dot, normalize, frameMatrix, frameMatrixInverse,
                 applyAffine, ModelSpace;
import mesh    : Mesh;
import editmode : EditMode;
import seltype : SelType;
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
//   - Select      — the selection's own frame (computeSelectionBboxBasis);
//                  world/workplane when nothing is selected.
//   - Local       — the same selection frame globally, plus a per-cluster
//                  frame when ACEN.Local splits the selection.
//   - SelectAuto  — selection ACTION CENTRE, AUTO axis. Deliberately NOT the
//                  selection frame: centre and frame are separate inputs and
//                  this is the mode that separates them.
//   - Element / Origin / Screen / Manual / Pivot / Parent — see computeBasis.
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
        //
        // Item mode 0614 / review Blocker 2: the subject's SelType is
        // deliberately NOT cached into a field (see actcenter.d's evaluate()
        // for the full rationale — the pipeline is a process-wide singleton
        // and different evaluate() callers legitimately publish different,
        // each-correct-for-itself SelTypes). `subjType` is a local, read
        // from THIS packet, at the point of use below. No redirect lives
        // here (L3: the measured default is already world,
        // doc/item_mode_transform_plan.md §(a)), only a guard on the three
        // selection-derived modes below plus the `tracksSelection` capability
        // published on the packet (should-fix 1 — the real consumer,
        // xfrm_transform.d's renderBasis, reads the packet, not the
        // instance method).
        SelType subjType = SelType.Vertex;
        if (auto subj = vts.get!SubjectPacket()) {
            lastView_ = subj.viewport;
            subjType  = subj.selType;
        }
        if (auto wp = vts.get!WorkplanePacket()) {
            lastWpAxis1_  = wp.axis1;
            lastWpNormal_ = wp.normal;
            lastWpAxis2_  = wp.axis2;
            lastWpIsAuto_ = wp.isAuto;
        }
        AxisPacket pkt;
        Vec3 r, u, f;
        computeBasis(r, u, f, subjType);
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
        // Should-fix 1 (0614 review): the declared "does this basis
        // co-rotate with the gesture" capability, narrowed by the SAME
        // subjType this evaluation just used for the Element/Select/Local
        // guard above — NOT re-derived by a consumer from `pkt.type` alone
        // (that was the bug: `type` still names e.g. Select even when the
        // guard made THIS evaluation fall back to the Auto/world basis).
        pkt.tracksSelection = modeTracksSelection(mode) && subjType != SelType.Item;
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
    //
    // SelectAuto is NOT in the list, and the reason is the whole point of that
    // mode: its action centre follows the selection but its AXIS is the auto
    // one (see computeBasis). A basis that is world-fixed must not co-rotate
    // with a gesture, so the declared capability has to follow the frame's
    // source and not the mode's name — it was listed here while the mode still
    // computed the selection basis.
    static bool modeTracksSelection(Mode m) pure nothrow @nogc @safe {
        return m == Mode.Select || m == Mode.Local;
    }
    // Item mode 0614: under the item guard (computeBasis's Element/Select/
    // Local arms below), Select/Local no longer deliver a selection-derived
    // basis in item mode — they fall back to Auto — so the declared
    // capability must follow the frame's ACTUAL source, not the mode's name
    // (the exact failure class axis.d's own comment above names).
    //
    // Review should-fix 1: THIS method has zero production callers — the
    // real consumer (xfrm_transform.d's renderBasis) cannot reach an
    // AxisStage instance (it only sees published packets), so it now reads
    // `AxisPacket.tracksSelection` instead, computed in evaluate() from the
    // packet's own subject type at the point of use. It has no *production*
    // caller left; it stays only because this file's own unittest below
    // calls it directly against a live `AxisStage` instance, as a same-
    // module cross-check that the instance-level formula agrees with the
    // packet-published capability the real consumer reads — not because any
    // external/API caller holds a stage instance. Delete it if that
    // cross-check is ever dropped.
    //
    // Not `pure nothrow @nogc @safe` like `modeTracksSelection` above: the
    // `liveSelType()` call is a plain (unannotated) delegate invocation, so
    // the compiler cannot infer purity/safety through it — the same
    // structural reason `currentBasis()` (which also calls `liveSelType()`)
    // carries no attributes either. Not a silent regression to chase; a
    // consequence of the delegate field's type.
    bool axisTracksSelection() const {
        return modeTracksSelection(mode) && liveSelType() != SelType.Item;
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
    // Item mode 0614 / review Blocker 2: the LIVE external source for "what
    // SelType is the CURRENT subject", used only by callers that reach
    // computeBasis() WITHOUT a packet in hand (currentBasis() — listAttrs(),
    // axisTracksSelection() above). Queried fresh on every call, never
    // cached (see actcenter.d's twin field for the full rationale). Null in
    // tests that don't wire item-mode awareness; liveSelType() then falls
    // back to Vertex, matching SubjectPacket's own R4 default.
    SelType delegate() selTypeSrc_;
    private SelType liveSelType() const { return selTypeSrc_ ? selTypeSrc_() : SelType.Vertex; }
    // Direct mesh refs for Element / Local modes (face/edge/vertex
    // normals). Optional — the stage works without when only World /
    // Workplane / Auto modes are used.
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh_() const { return meshSrc_ ? meshSrc_() : null; }
    EditMode* editMode_;
    // Task 0082: delegate supplying the primary Layer for Pivot/Parent modes.
    Layer delegate() primarySrc_;
    @property Layer primary_() const { return primarySrc_ ? primarySrc_() : null; }

    /// THE SPACE THIS STAGE PUBLISHES IN (task 0649) — see
    /// `ActionCenterStage.itemSpace()`, which this mirrors exactly and for the
    /// same reason. The centre and the frame are one seam: a frame derived in
    /// the layer's own coordinates paired with a centre in world coordinates
    /// describes no pose at all.
    ///
    /// SOURCE is `document.primaryModelSpace()`, not `primary_()` — the space
    /// that maps `mesh_` into the world, which is what a SELECTION-derived
    /// frame needs. `Mode.Pivot` / `Mode.Parent` keep reading `primary_()`:
    /// those publish an ITEM's own orientation, and the item in question is
    /// the item-transform target, which is a different question.
    ModelSpace itemSpace() const {
        import document : primaryModelSpace;
        return primaryModelSpace();
    }

public:
    this(Mesh* delegate() meshSrc = null, EditMode* editMode = null,
         Layer delegate() primarySrc = null,
         SelType delegate() selTypeSrc = null) {
        this.meshSrc_    = meshSrc;
        this.editMode_   = editMode;
        this.primarySrc_ = primarySrc;
        this.selTypeSrc_ = selTypeSrc;
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

    // Authoritative settable-attr universe (task 0678 P4). This stage has no
    // params()/fullParams(), so the base knownAttrs() derivation returned
    // null — and the forms-engine startup-strict validator (forms.d) throws
    // on ANY attr of a stage whose universe is empty, so the first form bound
    // to "axis" would fail at boot. applySetAttr's switch accepts exactly
    // `mode`; keep this list in lock-step with it (pinned by unittest below).
    override string[] knownAttrs() {
        return ["mode"];
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
    /// values when called between evaluate() passes, and the LIVE
    /// `liveSelType()` source (not a field cached from evaluate() — review
    /// Blocker 2) for the item-mode guard.
    void currentBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        computeBasis(right, up, fwd, liveSelType());
    }

private:
    // `subjType` is the subject's SelType AT THE POINT OF USE — the caller's
    // packet (evaluate()) or a freshly-queried live value (currentBasis()),
    // never a field cached from some earlier, possibly unrelated evaluate()
    // call.
    // Review nit: `subjType` has NO default — unlike `computeBasis`'s twin,
    // `ActionCenterStage.computeCenter(SelType subjType)`, which also takes
    // it as a plain required parameter. A caller that omitted it here would
    // silently get geometry (Vertex) behaviour instead of the live subject;
    // both call sites below already pass it explicitly, so this costs
    // nothing today and only forecloses that failure mode for later ones.
    void computeBasis(out Vec3 r, out Vec3 u, out Vec3 f,
                       SelType subjType) const {
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
                // Item mode 0614: a vertex/edge/face selection surviving a
                // mode switch (EditMode persists under SelType.Item,
                // seltype.d) must NOT orient the item gizmo off stale
                // geometry — skip straight to the Auto fallback WITHOUT
                // consulting the mesh selection at all (§Q3 AXIS guard).
                if (subjType != SelType.Item && computeElementBasis(r, u, f))
                    return;
                goto case Mode.Auto;       // fall back to workplane basis
            case Mode.SelectAuto:
                // THE CENTRE AND THE FRAME ARE SEPARATE INPUTS, AND THIS MODE
                // IS THE PROOF. `selectauto` hands over the SAME action centre
                // as `select` — bit-identical to nine digits on the recorded
                // rig — and still orients differently, because the reference's
                // preset pairs the selection ACTION CENTRE with the *auto* AXIS
                // tool, not the selection one. Measured: with a cube's +Y face
                // selected, `select` installs (+X, −Z, +Y) while `selectauto`
                // installs the identity, and the two elect different indices
                // off the identical centre. So this mode must NOT run the
                // selection basis; it takes Auto's, which is the workplane when
                // one is set manually and world XYZ otherwise.
                //
                // It shared `computeSelectionBboxBasis` with Select from 7.2d
                // (both were stubs of one another) until that pairing was read
                // out of the shipped presets.
                goto case Mode.Auto;
            case Mode.Select:
                // Item mode 0614: same guard as Element above — a stale
                // vertex/edge/face selection must not orient the item
                // gizmo, so skip the mesh-selection read entirely.
                if (subjType != SelType.Item && computeSelectionBboxBasis(r, u, f))
                    return;
                goto case Mode.Auto;
            case Mode.Local:
                // Local's GLOBAL frame is the SELECTION's frame, the same
                // computation Select runs. Measured on a cube with its +Y face
                // selected: `local` and `select` install a bit-identical
                // (+X, −Z, +Y) — the reference reaches it through a different
                // axis tool, but on a component selection the two agree and the
                // frame is emphatically not the world axes, which is what this
                // branch used to return.
                //
                // WHAT SEPARATES THEM IS NOT MEASURED HERE. The reference runs
                // `local` and `select` as different code; a subject whose ITEM
                // transform is rotated would separate them and no such rig has
                // been recorded. Our item-oriented frame is Mode.Pivot, so
                // routing Local at the selection is the reading that fits this
                // stage; revisit if a rotated-item measurement lands.
                //
                // No selection ⇒ fall through to Auto (workplane / world),
                // exactly what this branch did before, so the whole-mesh
                // subject is untouched. That fallback is deliberate: the
                // reference takes a separate no-box path when the selection is
                // empty and that path has NOT been read, so we do not guess it.
                //
                // The per-cluster Local basis is published separately in
                // evaluate() (clusterRight/Up/Fwd when ACEN.Local has ≥2
                // clusters) and is unchanged; this is the frame the gizmo uses
                // when there is one cluster, which until now disagreed with the
                // per-cluster one on the very same selection.
                //
                // Item mode 0614: same guard as Element/Select above.
                if (subjType != SelType.Item && computeSelectionBboxBasis(r, u, f))
                    return;
                goto case Mode.Auto;
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

    // Selection-derived basis — the ORIENTED bounding box of the selection.
    //
    // This used to build a world-axis-ALIGNED box: per-world-axis min/max, the
    // averaged face normal snapped to the nearest world axis, and a fixed
    // per-axis lookup for the second row. That agrees with an oriented box
    // exactly on a world-aligned subject — every rig ever recorded — and
    // answers a signed world permutation on a rotated one. The law is now in
    // `toolpipe.obbox`; this function's job is only ENUMERATION: which points,
    // which reference direction, and which of the four constructions the count
    // selects.
    //
    // SPACE (task 0649 — this is the paragraph that changed).
    //
    // Every term here is now in WORLD space. The reference stores its
    // enumerated positions already in world space and applies the layer's 3x3
    // to the NORMALS only — an asymmetry a port must not flatten by
    // transforming BOTH THE SAME WAY. The previous revision preserved the
    // asymmetry by transforming NEITHER, which is exact only while the layer
    // transform is the identity, and that limitation is the one this stage's
    // own comment declared "a separate, pre-existing divergence, deliberately
    // not opened here". 0648 opened it: on a stand whose selected face has
    // local extents (X 1.7, Z 1.2) and world extents (X 3.4, Z 3.6) under the
    // item scale (2, 0.5, 3), the reference's `right` is Z-dominant (the
    // WORLD extent order) and ours was X-dominant (the LOCAL one).
    //
    // So: POSITIONS through `toWorldPoint`, NORMALS through `toWorldNormal`
    // (the inverse-transpose — a normal is not a direction under a
    // non-uniform scale), which is each term transformed exactly as often as
    // it needs to be, in a space that is no longer the identity.
    //
    // Reconstructing this stand offline from the world points reproduces the
    // reference's own box ROWS to ~1e-6 in all five of 0648's item
    // transforms, which is the evidence that the reference's box is the box
    // of the WORLD points. That reconstruction ALSO measured the covariance
    // divisor, which was left open here and is now closed by task 0658:
    // `toolpipe.obbox` divides by `2n` and scales the first moments by the
    // same factor, which is worth ~3e-3 on the rotated stands and ~8e-5 at
    // identity. `tests/test_obb_covariance_divisor.d` asserts the
    // reproduction on all five.
    //
    // ONE residual divergence is still NOT closed here and is recorded rather
    // than fitted: the box-row-to-packet-slot TAIL in `axisFrameFromBox`,
    // which is unread on the reference side and which 0648's numbers do not
    // settle either.
    bool computeSelectionBboxBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        import toolpipe.obbox : ObbFrame, obbFromPoints, obbFromVertexNormal,
                                obbFromEdge, axisFrameFromBox;
        if (mesh_ is null || editMode_ is null) return false;

        const auto ms = itemSpace();
        Vec3[] pts;
        uint[] vids;
        bool[] visited = new bool[](mesh_.vertices.length);
        Vec3 normalAcc = Vec3(0, 0, 0);
        void touchVert(uint vi) {
            if (visited[vi]) return;
            visited[vi] = true;
            pts  ~= ms.isIdentity ? mesh_.vertices[vi]
                                  : ms.toWorldPoint(mesh_.vertices[vi]);
            vids ~= vi;
        }
        // The sign-fix reference direction. The reference sums POLYGON normals
        // and falls back to `normalize(boxCentre - aabbCentre)` when the sum is
        // degenerate. Which polygons it sums is the one place the read is not
        // decisive — the static read says a vertex-only selection contributes
        // none, while the recorded 25-vertex lattice rig came back with its box
        // NEGATED, which needs a non-zero reference. So this is a DECLARED
        // choice where the evidence is split: sum the normals of the faces the
        // selection TOUCHES, which is exactly what this stage summed before the
        // port and therefore keeps every shipped sign, and reduces to the read
        // verbatim in Polygons mode.
        void touchFaceNormal(uint fi) {
            Vec3 n = mesh_.faceNormal(fi);
            normalAcc = normalAcc + (ms.isIdentity ? n : ms.toWorldNormal(n));
        }
        final switch (*editMode_) {
            case EditMode.Polygons:
                if (!mesh_.hasAnySelectedFaces()) return false;
                foreach (i, face; mesh_.faces) {
                    if (!mesh_.isFaceSelected(i)) continue;
                    touchFaceNormal(cast(uint)i);
                    foreach (vi; face) touchVert(vi);
                }
                break;
            case EditMode.Edges:
                if (!mesh_.hasAnySelectedEdges()) return false;
                foreach (i, edge; mesh_.edges) {
                    if (!mesh_.isEdgeSelected(i)) continue;
                    foreach (vi; edge) touchVert(vi);
                }
                foreach (fi, face; mesh_.faces) {
                    bool touches = false;
                    foreach (fvi; face) if (visited[fvi]) { touches = true; break; }
                    if (touches) touchFaceNormal(cast(uint)fi);
                }
                break;
            case EditMode.Vertices:
                if (!mesh_.hasAnySelectedVertices()) return false;
                foreach (vi; 0 .. mesh_.vertices.length)
                    if (mesh_.isVertexSelected(vi)) touchVert(cast(uint)vi);
                foreach (fi, face; mesh_.faces) {
                    bool touches = false;
                    foreach (fvi; face) if (visited[fvi]) { touches = true; break; }
                    if (touches) touchFaceNormal(cast(uint)fi);
                }
                break;
        }
        if (pts.length == 0) return false;

        // THE COUNT SELECTS THE CONSTRUCTION.
        ObbFrame box;
        if (pts.length == 1) {
            // The vertex's geometric normal — the uniform average of its
            // incident face normals. `normalAcc` already holds exactly that
            // sum for a one-vertex selection.
            //
            // The up-hint when the normal is world-Y dominant: the reference
            // asks the viewport's work plane there, and that query has not
            // been read, so it is NOT invented here. World Z is used, declared
            // as ours. It is also the reference's ONLY view-dependent term in
            // this whole computation, so keeping it constant is what makes our
            // selection frame camera-independent everywhere.
            enum int UP_HINT_WHEN_Y_DOMINANT = 2;
            box = obbFromVertexNormal(pts[0], normalAcc,
                                      UP_HINT_WHEN_Y_DOMINANT);
        } else if (pts.length == 2) {
            Vec3 eNrm; bool haveENrm = false;
            if (edgeAverageNormal(vids[0], vids[1], eNrm)) haveENrm = true;
            box = obbFromEdge(pts[0], pts[1], eNrm, haveENrm);
        } else {
            box = obbFromPoints(pts, normalAcc);
        }
        if (!box.ok) return false;
        axisFrameFromBox(box, right, up, fwd);
        return true;
    }

    // The average polygon normal of the edge bounded by two vertices, if they
    // bound one. The two-point construction uses it as its second row; when
    // the pair does NOT bound a polygon edge the reference degrades to a world
    // basis vector instead, which is what `false` here selects.
    /// The result is in the space `computeSelectionBboxBasis` enumerates in
    /// (WORLD, task 0649) — the reference transforms exactly this term by the
    /// layer's 3x3 while leaving the two-point arm's DIRECTION alone, and the
    /// direction is already world here because `pts` are.
    private bool edgeAverageNormal(uint a, uint b, out Vec3 nrm) const {
        const auto ms = itemSpace();
        Vec3 acc = Vec3(0, 0, 0);
        int n = 0;
        foreach (fi, face; mesh_.faces) {
            foreach (k; 0 .. face.length) {
                uint u = face[k];
                uint v = face[(k + 1) % face.length];
                if ((u == a && v == b) || (u == b && v == a)) {
                    Vec3 fn = mesh_.faceNormal(cast(uint)fi);
                    acc = acc + (ms.isIdentity ? fn : ms.toWorldNormal(fn));
                    ++n;
                    break;
                }
            }
        }
        if (n == 0) return false;
        nrm = acc * (1.0f / n);
        return nrm.length > 1e-12f;
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
        // SPACE (0649): the per-cluster frame is published in the same space
        // as the per-cluster CENTRES (ActionCenterStage.clusterBBoxCenter) —
        // WORLD. The two are consumed together by the fold's per-cluster arm,
        // so converting one without the other would put each cluster's pivot
        // and its axes in different spaces.
        const auto ms = itemSpace();
        Vec3 vertAt(size_t vi) const {
            return ms.isIdentity ? mesh_.vertices[vi]
                                 : ms.toWorldPoint(mesh_.vertices[vi]);
        }
        float[3] mn = [float.infinity, float.infinity, float.infinity];
        float[3] mx = [-float.infinity, -float.infinity, -float.infinity];
        Vec3 normalAcc = Vec3(0, 0, 0);
        bool any = false;
        foreach (vi, c; clusterOf) {
            if (c != cid) continue;
            Vec3 v = vertAt(vi);
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
                if (inCluster) {
                    Vec3 fn = mesh_.faceNormal(cast(uint)fi);
                    normalAcc = normalAcc
                              + (ms.isIdentity ? fn : ms.toWorldNormal(fn));
                }
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
                    Vec3 pv = vertAt(vi2);
                    meanY += pv.y;
                    meanZ += pv.z;
                    n++;
                }
                if (n > 0) { meanY /= n; meanZ /= n; }
                float covYY = 0, covZZ = 0, covYZ = 0;
                foreach (vi2, c2; clusterOf) {
                    if (c2 != cid) continue;
                    Vec3 pv = vertAt(vi2);
                    float dy = pv.y - meanY;
                    float dz = pv.z - meanZ;
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
        // SPACE (0649): world, like every other frame this stage publishes.
        // The element MODE's law is out of 0649's scope (the reference derives
        // it from the pointer and 0648 scored it "not comparable"); its SPACE
        // is not — a stage that published eleven world frames and one layer-
        // local one would be exactly the half conversion the task refuses.
        // Normals take the inverse-transpose, tangents the linear part.
        const auto ms = itemSpace();
        Vec3 nrmAt(uint fi) const {
            Vec3 n = mesh_.faceNormal(fi);
            return ms.isIdentity ? n : ms.toWorldNormal(n);
        }
        Vec3 dirOf(uint a, uint b) const {
            Vec3 d = mesh_.vertices[b] - mesh_.vertices[a];
            return ms.isIdentity ? d : ms.toWorldDir(d);
        }
        Vec3 nUp;
        Vec3 nRight;
        bool got = false;
        final switch (*editMode_) {
            case EditMode.Polygons: {
                if (!mesh_.hasAnySelectedFaces()) return false;
                foreach (i, _; mesh_.faces) {
                    if (mesh_.isFaceSelected(i)) {
                        nUp = nrmAt(cast(uint)i);
                        // Tangent: first edge of the face, projected
                        // perpendicular to the face normal.
                        const uint[] face = mesh_.faces[i];
                        Vec3 e0 = dirOf(face[0], face[1]);
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
                        Vec3 t = dirOf(edge[0], edge[1]);
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
                                acc += nrmAt(cast(uint)fi);
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

// ---------------------------------------------------------------------------
// Item mode 0614, Phase 2 — the AXIS "non-change" pin
// (doc/item_mode_transform_plan.md §Q3 / §(a)). L3 OVERTURNED the plan's
// original design: there is no item-basis redirect here at all — the
// measured default (Mode.None, world identity, Phase 0 case A′) already
// matches the capture with zero code, and adding a redirect would have
// INTRODUCED a divergence from behaviour vibe3d already had right. This
// test exists solely to guard that fact: "we changed nothing and it is
// already right" is only true until someone adds the redirect back.
// ---------------------------------------------------------------------------
unittest {
    import document : Layer;
    import seltype  : SelType;

    bool vecEq(Vec3 a, Vec3 b) {
        return isClose(a.x, b.x, 1e-6f, 1e-6f) && isClose(a.y, b.y, 1e-6f, 1e-6f)
            && isClose(a.z, b.z, 1e-6f, 1e-6f);
    }

    // The exact rig Phase 0 case A′ measured: item rotated 45° about world Y.
    auto itemLayer = new Layer();
    itemLayer.xform.rot = Vec3(0, 45, 0);
    Layer itemRef = itemLayer;

    // `currentSel` + the `() => currentSel` ctor delegate stand in for the
    // LIVE external selType source app.d wires (review Blocker 2 —
    // computeBasis() no longer reads a field cached from evaluate()).
    SelType currentSel = SelType.Vertex;
    auto st = new AxisStage(null, null, () => itemRef, () => currentSel);
    st.mode = AxisStage.Mode.None;   // the stage's own default (axis.d:166ish)

    Vec3 r, u, f;

    currentSel = SelType.Vertex;
    st.currentBasis(r, u, f);
    assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
        "Vertex subject, default mode: world identity (unchanged baseline)");

    currentSel = SelType.Item;
    st.currentBasis(r, u, f);
    assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
        "Item subject, default mode, ROTATED item: basis must STILL read "
        ~ "world identity — an item-basis redirect (r ≈ (0.707,0,-0.707)) "
        ~ "would be the overturned design (L3, phase0_findings.md case A′)");

    // Companion: Mode.Pivot IS the explicit route to the item's own basis,
    // and it stays reachable — the item's rotated frame shows up there,
    // proving L3 removed a DEFAULT, not a CAPABILITY.
    st.mode = AxisStage.Mode.Pivot;
    st.currentBasis(r, u, f);
    assert(!vecEq(r, Vec3(1, 0, 0)),
        "Mode.Pivot must still reflect the item's own (rotated) basis — "
        ~ "L3 only removed the DEFAULT redirect, not this explicit mode");
}

// ---------------------------------------------------------------------------
// Item mode 0614, Phase 2 — the Select/Local/Element guard
// (doc/item_mode_transform_plan.md §Q3 / §(a) step 2, R6-adjacent). A
// vertex/edge/face selection that survives a mode switch (EditMode persists
// under SelType.Item, seltype.d) must not orient the item gizmo. In item
// mode these three modes must fall onto their existing Auto fallback
// WITHOUT consulting the mesh selection at all, and axisTracksSelection()
// must report false so a flex-gizmo consumer does not believe a
// world-fixed item frame co-rotates with the gesture.
//
// Should-fix 1 (0614 review): `axisTracksSelection()` had ZERO production
// callers — the real consumer (xfrm_transform.d's renderBasis) reads
// `AxisPacket.tracksSelection` off the VectorStack, which it cannot reach
// without driving a real `evaluate()`. The second half of this test does
// exactly that, so the assertions pin the path production actually runs,
// not just the instance-method mirror of it.
// ---------------------------------------------------------------------------
unittest {
    import mesh     : makeCube;
    import seltype  : SelType;
    import std.conv : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return isClose(a.x, b.x, 1e-6f, 1e-6f) && isClose(a.y, b.y, 1e-6f, 1e-6f)
            && isClose(a.z, b.z, 1e-6f, 1e-6f);
    }

    // A real, non-trivial face selection — if the guard failed to skip it,
    // computeSelectionBboxBasis would install a NON-identity basis here.
    Mesh cube = makeCube();
    cube.resetSelection();
    cube.selectFace(4);   // +Y face
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Polygons;

    SelType currentSel = SelType.Vertex;
    auto st = new AxisStage(() => meshPtr, &em, null, () => currentSel);

    foreach (m; [AxisStage.Mode.Select, AxisStage.Mode.Local, AxisStage.Mode.Element]) {
        st.mode = m;

        currentSel = SelType.Vertex;
        Vec3 r, u, f;
        st.currentBasis(r, u, f);
        assert(!vecEq(r, Vec3(1, 0, 0)) || !vecEq(u, Vec3(0, 1, 0)) || !vecEq(f, Vec3(0, 0, 1)),
            m.to!string ~ ": with a real selection and a Vertex subject, the "
            ~ "selection basis must be read (non-identity) — sanity check "
            ~ "that the rig actually discriminates");

        currentSel = SelType.Item;
        st.currentBasis(r, u, f);
        assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
            m.to!string ~ ": Item subject must skip the stale selection "
            ~ "entirely and fall onto the Auto (world) fallback");

        assert(!st.axisTracksSelection(),
            m.to!string ~ ": axisTracksSelection() must report false in item "
            ~ "mode — under the guard this mode no longer delivers a "
            ~ "selection-derived basis");
    }

    // Cross-check: the SAME modes with a Vertex subject still track.
    currentSel = SelType.Vertex;
    foreach (m; [AxisStage.Mode.Select, AxisStage.Mode.Local]) {
        st.mode = m;
        assert(st.axisTracksSelection(),
            m.to!string ~ ": Vertex subject must keep tracking the selection "
            ~ "(the guard is item-mode-only, R6/axis.d:152-156 unaffected)");
    }

    // The REAL production path: drive evaluate() with an explicit
    // SubjectPacket (no reliance on the live `currentSel` source — this is
    // exactly how xfrm_transform.d's renderBasis reaches the value, via
    // `vts.get!AxisPacket().tracksSelection`) and check the published
    // packet field for Select (tracks) and its item-mode guard (does not).
    import operator         : VectorStack;
    import toolpipe.packets : SubjectPacket, AxisPacket;
    st.mode = AxisStage.Mode.Select;

    SubjectPacket subjVertex;
    subjVertex.mesh     = meshPtr;
    subjVertex.editMode = em;
    subjVertex.selType  = SelType.Vertex;
    VectorStack vtsVertex;
    vtsVertex.put(&subjVertex);
    assert(st.evaluate(vtsVertex), "evaluate() must succeed (Vertex subject)");
    auto pktVertex = vtsVertex.get!AxisPacket();
    assert(pktVertex !is null);
    assert(pktVertex.tracksSelection,
        "AxisPacket.tracksSelection must be true for Select+Vertex — the "
        ~ "exact field xfrm_transform.d's renderBasis reads");

    SubjectPacket subjItem;
    subjItem.mesh     = meshPtr;
    subjItem.editMode = em;
    subjItem.selType  = SelType.Item;
    VectorStack vtsItem;
    vtsItem.put(&subjItem);
    assert(st.evaluate(vtsItem), "evaluate() must succeed (Item subject)");
    auto pktItem = vtsItem.get!AxisPacket();
    assert(pktItem !is null);
    assert(!pktItem.tracksSelection,
        "AxisPacket.tracksSelection must be false for Select+Item — `type` "
        ~ "still reports Select (mode name unchanged) but the basis this "
        ~ "same evaluate() call published is the Auto/world fallback, so a "
        ~ "consumer keyed off `type` alone would wrongly believe it "
        ~ "co-rotates with the gesture");
}

// task 0678 P4 — knownAttrs must mirror applySetAttr's switch: every listed
// name is settable with a canonical sample value.  Before the fix this stage
// had NO attr universe at all (no params/fullParams/knownAttrs), so the
// forms-engine startup-strict validator (forms.d) would throw for the first
// form bound to "axis".
unittest {
    auto st = new AxisStage();
    auto names = st.knownAttrs();
    assert(names.length > 0, "axis knownAttrs must not be empty");
    string[string] sample = ["mode": "auto"];
    foreach (n; names) {
        assert((n in sample) !is null,
               "no sample value for axis attr '" ~ n ~ "' — extend the test");
        assert(st.setAttr(n, sample[n]),
               "axis knownAttrs name '" ~ n ~ "' rejected by setAttr");
    }
}
