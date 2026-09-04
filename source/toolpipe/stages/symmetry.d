module toolpipe.stages.symmetry;

import std.format : format;

import math    : Vec3, dot;
import mesh    : Mesh;
import mesh_dirty : MeshDirtyKey, g_settledGeomEpochs;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordSymm;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SymmetryPacket, SymmetryConfig;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import symmetry          : rebuildPairing, rebuildPairingTopological;
import perf_probe        : g_perf, Cat;
import params            : Param, IntEnumEntry;

/// How many times `evaluate()` has actually re-run `rebuildPairing` /
/// `rebuildPairingTopological` — the O(V log V) geometric mirror search plus
/// its three arrays, not the cache-gate check in front of it (task 2000).
///
/// The twin of `snap.g_snapGridBuilds`, and there for the same reason: the
/// pair table this rebuilds is CORRECT however often it is rebuilt, so the
/// only observable of a wrong key is a rate. Measured on 2026-08-25, keying
/// this cache on a watcher that carries a live gizmo drag's `Position`
/// deliveries turned one rebuild per gesture into one per drag STEP:
/// `move/symmetry=X` `pipeSymmetry` read 1 021.7 ms per 20-step drag against
/// a 0.6 ms kernel, and the stage's own timer MEDIAN stayed 0 because 20 of
/// its ~45 calls were hits. Monotone, never reset; `__gshared` and always-on
/// rather than `debug`, because the unit lane and the suite lane build with
/// different flags. Read over `/api/cache/rebuilds`; the `perf`-build twin is
/// `perf_probe.Cat.symPairingRebuild`.
__gshared ulong g_symPairingRebuilds;

// ---------------------------------------------------------------------------
// SymmetryStage — phase 7.6 of doc/phase7_plan.md / doc/phase7_6_symm_plan.md.
// Sits at ordinal 0x31 (between WORK 0x30 and SNAP 0x40).
//
// Publishes a SymmetryPacket describing the mirror plane (X / Y / Z plus
// an optional offset, or the active workplane when `useWorkplane` is on)
// and — once 7.6b lands — a per-vertex pairing snapshot the consumer
// tools use to mirror per-vertex deltas during drag.
//
// 7.6a (this commit) ships only the master toggle + plane resolution —
// the pair table stays empty (`enabled = false` ⇒ no pairing work at
// all; `enabled = true` exposes a length-0 pairOf / onPlane until the
// 7.6b pairing algorithm lands). Tools have no integration yet, so the
// rest of the editor sees a no-op packet either way.
//
// HTTP setAttr keys:
//   `enabled`      : "true" / "false"
//   `axis`         : "x" / "y" / "z" (lowercase; case-insensitive parse)
//   `offset`       : float, world units along the chosen axis
//   `useWorkplane` : "true" / "false"
//   `topology`     : "true" / "false" — WIRED (stale comment fixed, task 1060
//                    side-errand): routes to `rebuildPairingTopological`
//                    (a connectivity walk seeded from on-plane seam
//                    vertices), not merely schema — see `evaluate` below
//   `epsilon`      : float, world-space pairing tolerance
// ---------------------------------------------------------------------------
class SymmetryStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md.
    private SymmetryPacket _publishedPacket;

    Task task() const { return Task.Symm; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        if (!this.enabled) return false;
        import toolpipe.packets : WorkplanePacket;
        SymmetryPacket pkt;
        pkt.config = config;

        // Resolve plane. `useWorkplane` overrides axisIndex+offset.
        // WORK stage has already run (ord 0x30 < SYMM 0x31).
        if (enabled && useWorkplane) {
            pkt.axisIndex = -1;
            if (auto wp = vts.get!WorkplanePacket()) {
                pkt.planePoint  = wp.center;
                pkt.planeNormal = wp.normal;
            }
        } else {
            int ax = enabled ? axisIndex : -1;
            pkt.axisIndex   = ax;
            pkt.planeNormal = axisVec(axisIndex);
            pkt.planePoint  = axisVec(axisIndex) * offset;
        }

        // Phase 7.6b: rebuild the pair table on cache miss.
        if (enabled && mesh_ !is null && mesh_.vertices.length > 0) {
            bool planeChanged =
                cachedPlanePoint_  != pkt.planePoint  ||
                cachedPlaneNormal_ != pkt.planeNormal ||
                cachedEpsilon_     != epsilonWorld;
            // TASK 1906 STAGE 2c — the mesh half of the key is
            // (address, change-bus GEOMETRY epoch), sampled ONCE so the
            // compare and the stamp below cannot straddle a change.
            //
            // TASK 2000 — THE WATCHER IS THE SETTLED ONE. `g_geomEpochs`
            // advances on every step of a gizmo drag (task 1906 stage 1
            // delivers `Position` per step, a measured law), which rebuilt
            // this table twenty times per twenty-step drag: measured
            // 1 021.7 ms of `pipeSymmetry` against a 0.6 ms kernel, ~2 MB per
            // step, and the stage timer's MEDIAN did not move because most of
            // its calls were still hits.
            //
            // A drag under an ENABLED symmetry stage is exactly the case where
            // that work is provably wasted: the apply mirrors every processed
            // vertex to its partner, so the mesh stays symmetric and the pair
            // table at step 20 is the one computed at step 1. What must still
            // drop it is any change the mirror did NOT make symmetric — a
            // command, an undo, a load — and every one of those publishes
            // UNCONFINED and advances this watcher. So does the gesture's own
            // commit (`TransformTool.recordCommit`), which is what keeps a
            // table from outliving the gesture that justified holding it.
            //
            // Unlike the snap grid, this stage has no query-time exclusion to
            // lean on, so the commit re-arm is not an optimisation here — it
            // is the whole of the correctness argument's second half.
            // Pinned by RATE (`g_symPairingRebuilds`, `/api/cache/rebuilds`),
            // because every VALUE this table produces is identical either way:
            // `tests/test_symmetry_pairing_drag_rate.d`.
            const size_t meshAddr  = cast(size_t)mesh_;
            const ulong  meshEpoch = g_settledGeomEpochs.epochFor(meshAddr);
            bool meshChanged = !cachedMeshKey_.matches(meshAddr, meshEpoch);
            bool topologyChanged = cachedTopology_ != topology;
            if (!cachedReady_ || planeChanged || meshChanged || topologyChanged) {
                // The rate instrument (task 2000) — see `g_symPairingRebuilds`.
                ++g_symPairingRebuilds;
                g_perf.count(Cat.symPairingRebuild, 1);
                if (topology)
                    rebuildPairingTopological(*mesh_, pkt,
                                             cachedPairOf_, cachedOnPlane_, cachedVertSign_);
                else
                    rebuildPairing(*mesh_, pkt,
                                   cachedPairOf_, cachedOnPlane_, cachedVertSign_);
                cachedMeshKey_.stamp(meshAddr, meshEpoch);
                cachedPlanePoint_      = pkt.planePoint;
                cachedPlaneNormal_     = pkt.planeNormal;
                cachedEpsilon_         = epsilonWorld;
                cachedTopology_        = topology;
                cachedReady_           = true;
            }
            pkt.pairOf   = cachedPairOf_;
            pkt.onPlane  = cachedOnPlane_;
            pkt.vertSign = cachedVertSign_;
        } else {
            pkt.pairOf   = null;
            pkt.onPlane  = null;
            pkt.vertSign = null;
        }
        pkt.axisFlags[0] = enabled && axisIndex == 0;
        pkt.axisFlags[1] = enabled && axisIndex == 1;
        pkt.axisFlags[2] = enabled && axisIndex == 2;
        pkt.pivot        = pkt.planePoint;

        _publishedPacket = pkt;
        vts.put(&_publishedPacket);
        return true;
    }

    /// The stage's user-facing config — the SAME seven fields
    /// `SymmetryPacket` carries. `alias this` keeps all existing field readers
    /// and Param pointers on the config's storage.
    SymmetryConfig config;
    alias config this;

private:
    // Injected refs (mirrors FalloffStage / ActionCenterStage shape).
    // `mesh_` is required for pairing — null-mesh callers skip the
    // rebuild and publish an empty pair table (the editor never has a
    // null mesh; unit tests that bypass app.d's pipe init do).
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh_() const { return meshSrc_ ? meshSrc_() : null; }
    EditMode* editMode_;

    // Pairing cache. Rebuilt when (mesh identity+freshness, plane, epsilon,
    // topology mode) change. `cachedReady_` toggles to true after the first
    // successful rebuild so a stage that's enabled mid-session can
    // publish a stale-empty packet for one frame before the cache
    // catches up on the next evaluate.
    //
    // TASK 1906 STAGE 2c — THE FRESHNESS HALF WAS `mesh_.mutationVersion`,
    // PROPPED UP BY A MANUAL `invalidatePairingCache()` FROM THE FRAME FLUSH,
    // AND BOTH ARE GONE. `rebuildPairing` is a GEOMETRIC mirror search — for
    // each vertex it looks for a partner within `epsilonWorld` of the
    // mirrored position — so the pair table is a pure function of vertex
    // POSITIONS, and an interactive gizmo drag moves those without bumping
    // `mutationVersion`, at the drag steps or at the commit (CLAUDE.md, "The
    // exception that breaks version-keying"). `mesh_dirty.g_geomEpochs` is fed
    // by the change bus, whose `Position` class IS published on that path.
    //
    // The narrowing is deliberate and it is what makes this cheaper than the
    // counter: `commitChange` bumps `mutationVersion` for EVERY class, so a
    // selection click used to throw the pair table away, while the epoch
    // watches `Position|Points|Polygons` — exactly what the search reads.
    //
    // The ADDRESS half is unchanged in meaning (layers Stage 2): the pair
    // table aliases across layers if the pointer rebinds to a mesh carrying an
    // equal stamp — trivially easy under the epoch, since a mesh nobody has
    // edited reads the table's never-changed value. A default `MeshDirtyKey`
    // carries `epoch == ulong.max`, which is never a real epoch, so the first
    // `evaluate` always rebuilds.
    MeshDirtyKey cachedMeshKey_;
    Vec3   cachedPlanePoint_      = Vec3(0, 0, 0);
    Vec3   cachedPlaneNormal_     = Vec3(0, 0, 0);
    float  cachedEpsilon_         = float.nan;
    int[]  cachedPairOf_;
    bool[] cachedOnPlane_;
    int[]  cachedVertSign_;
    bool   cachedTopology_         = false;
    bool   cachedReady_           = false;

public:
    this(Mesh* delegate() meshSrc = null, EditMode* editMode = null) {
        this.meshSrc_ = meshSrc;
        this.editMode_ = editMode;
        reset();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Symm; }
    override string   id()       const                          { return "symmetry"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordSymm; }

    /// Restore every mutable field to the default-constructed value.
    /// Triggered by SceneReset (= `/api/reset`) so a "start fresh"
    /// scene wipes the symmetry plane along with the mesh — otherwise
    /// `enabled=true` and any non-X axisIndex leak into the next user
    /// session.
    override void reset() {
        config = SymmetryConfig.init;
        // Behaviour-preserving placeholder pending the owner's default
        // decision: packets keep -1 (no axis), while a fresh/reset stage keeps
        // today's 0 (X). Do not fold this into SymmetryConfig silently.
        config.axisIndex = 0;
        // Drop the pairing cache too so the next evaluate rebuilds from
        // the post-reset mesh / plane rather than reusing stale pairs.
        cachedMeshKey_.clear();
        cachedPlanePoint_      = Vec3(0, 0, 0);
        cachedPlaneNormal_     = Vec3(0, 0, 0);
        cachedEpsilon_         = float.nan;
        cachedPairOf_.length   = 0;
        cachedOnPlane_.length  = 0;
        cachedVertSign_.length = 0;
        cachedTopology_        = false;
        cachedReady_           = false;
        publishState();
    }

    override bool setAttrImpl(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    /// Snapshot the stage's LIVE user-facing CONFIG fields into a
    /// SymmetryPacket — the inverse of `restoreConfigFromPacket`. Used by the
    /// wrapper's transform-session undo/redo hooks (P-C) so a mid-run symmetry
    /// toggle reverts the symmetry CONFIG together with the geometry. Mirrors
    /// FalloffStage.snapshotConfigToPacket: captures only the STAGE-owned config
    /// (the fields a round-trip restores), NOT the derived pairing cache
    /// (pairOf / onPlane / vertSign rebuild on the next evaluate).
    SymmetryPacket snapshotConfigToPacket() const {
        SymmetryPacket p;
        p.config = config;
        return p;
    }

    /// Restore the user-facing CONFIG fields from a previously-snapshotted
    /// SymmetryPacket and re-publish so the status-bar pulldown follows. Used by
    /// the wrapper's in-session symmetry-refire undo/redo hooks (P-C): an
    /// in-session Ctrl+Z of a transform-session symmetry change restores the
    /// symmetry config to its PRE-tweak value (revert hook); redo restores the
    /// POST-tweak config (apply hook). Mirrors FalloffStage.restoreConfigFromPacket
    /// — assign + invalidate the derived cache + publish, no session.
    ///
    /// Drops the pairing cache (cachedReady_) so the next evaluate() rebuilds
    /// pairOf / onPlane / vertSign from the restored plane; does NOT touch the
    /// injected mesh / editMode refs.
    void restoreConfigFromPacket(const ref SymmetryPacket p) {
        config = p.config;
        // The pairing cache is keyed on (mesh key, plane, epsilon); restoring
        // config that changes the plane / epsilon must invalidate it so the
        // next evaluate() rebuilds the mirror table.
        cachedReady_           = false;
        cachedMeshKey_.clear();
        publishState();
    }

    // TASK 1906 STAGE 2c — `invalidatePairingCache()` STOOD HERE AND IS GONE,
    // not merely unused. It existed for task 0401: the staleness check in
    // `evaluate()` keyed on raw `mesh_.mutationVersion`, which an interactive
    // gizmo drag never bumps, so `app.d`'s frame flush had to reach in and
    // drop `cachedReady_` on any `Position` frame. That was a second,
    // un-keyed invalidation channel — it dropped the table for a change to
    // ANY layer, and every future publisher had to remember it existed.
    // `evaluate`'s key now carries this mesh's own change-bus epoch, so the
    // signal arrives with a subject and needs no caller. Deleted rather than
    // left callerless: a public invalidator with no caller is the shape that
    // grows a caller back. The two config paths that must drop the table
    // (`reset`, `restoreConfigFromPacket`) do it directly, where the reason is
    // visible.

    /// Update `baseSide` from an anchor point **in the same space as
    /// `mesh.vertices[]`** — i.e. LOCAL to the layer, not world — typically
    /// the centroid of the element the user
    /// just clicked while symmetry was active. Off-plane anchors set
    /// `baseSide` to the side they land on; on-plane anchors leave the
    /// existing `baseSide` untouched (the user clicked something
    /// straddling the plane; previous anchor stays canonical).
    ///
    /// **Task 0619 — this comment used to say "world-space anchor point",
    /// and that was wrong.** It was inventoried as a defect to fix (convert
    /// the three `symmetry_pick.d` call sites with `ms.toWorldPoint`) and the
    /// investigation refuted it: `baseSide` is only ever compared against
    /// `SymmetryPacket.vertSign` (`symmetry.d` `applySymmetryMirror` and its
    /// sibling), and `vertSign` is computed in `rebuildPairing` /
    /// `rebuildPairingTopological` from raw `mesh.vertices[i]` against this
    /// same plane. The whole symmetry subsystem — the pairing search,
    /// `mirrorPosition`, `isOnPlane`, the appliers — is `ItemXform`-unaware,
    /// so the plane is de facto LAYER-LOCAL. Converting the anchor alone
    /// would compare a world point against a local plane and invert the
    /// mirror pairs on any layer whose transform moves geometry across it.
    ///
    /// If item-transform-aware symmetry is ever wanted, the seam is the
    /// PLANE (`currentPlane` / `evaluate`), not the anchor, and it moves the
    /// whole subsystem at once. Do not "fix" this call site in isolation.
    void anchorAt(Vec3 pos) {
        // Resolve the current plane the same way `evaluate` does so a
        // caller invoking `anchorAt` between evaluates picks up the
        // live axis / offset / workplane state.
        Vec3 planePt, planeN;
        currentPlane(planePt, planeN);
        float d = dot(pos - planePt, planeN);
        if (d >  epsilonWorld) baseSide = +1;
        else if (d < -epsilonWorld) baseSide = -1;
        // |d| <= epsilon ⇒ leave baseSide unchanged.
        publishState();
    }

    /// Resolve `(planePoint, planeNormal)` from the stage's current
    /// axis / offset / workplane state. Mirrors the head of `evaluate`
    /// — split out so `anchorAt` can compute the plane without
    /// requiring a full pipeline pass first.
    private void currentPlane(out Vec3 planePt, out Vec3 planeN) {
        if (enabled && useWorkplane) {
            // Without a fresh pipeline pass we can't reach the
            // upstream WorkplaneStage. Fall back to the cached
            // workplane snapshot from the last `evaluate`; if there
            // was none, default to world XZ.
            if (cachedReady_) {
                planePt = cachedPlanePoint_;
                planeN  = cachedPlaneNormal_;
            } else {
                planePt = Vec3(0, 0, 0);
                planeN  = Vec3(0, 1, 0);
            }
            return;
        }
        planeN  = axisVec(axisIndex);
        planePt = axisVec(axisIndex) * offset;
    }

    override string[2][] listAttrs() const {
        return [
            ["enabled",      enabled ? "true" : "false"],
            ["axis",         axisLabel(axisIndex)],
            ["offset",       format("%g", offset)],
            ["useWorkplane", useWorkplane ? "true" : "false"],
            ["topology",     topology ? "true" : "false"],
            ["epsilon",      format("%g", epsilonWorld)],
            ["baseSide",     format("%d", baseSide)],
        ];
    }

    override string displayName() const {
        import std.string : toUpper;
        if (!enabled) return "Symmetry";
        if (useWorkplane) return "Symmetry: Workplane";
        return format("Symmetry: %s", axisLabel(axisIndex).toUpper);
    }

    // Full attr universe (task 0678 P4): params() below is a VISIBILITY
    // filter — empty when the stage is off, and even when on it shows only
    // the fine-tuning knobs — so the base knownAttrs() derivation
    // under-reported the set applySetAttr accepts (empty when disabled, 4 of
    // 6 when enabled), which stage.d's fullParams doc comment forbids
    // outright. `baseSide` stays out deliberately: it is read-only
    // (listAttrs reports it; applySetAttr has no arm for it).
    // `static immutable` — not a local literal. `params()` is a FILTER over
    // fullParams(), so the Tool Properties panel calls this every frame the
    // symmetry section is open, and a local array literal allocated a fresh
    // 3-entry table each time (task 0685 T9). Same shape as ACEN's
    // `modeEntries`; a static immutable table passes into `intEnum_` without
    // a `.dup` (see params.d).
    private static immutable IntEnumEntry[] axisEntries = [
        IntEnumEntry(0, "x", "X"),
        IntEnumEntry(1, "y", "Y"),
        IntEnumEntry(2, "z", "Z"),
    ];

    override Param[] fullParams() {
        Param[] ps;
        ps ~= Param.bool_   ("enabled", "Enabled", &enabled, false);
        ps ~= Param.intEnum_("axis", "Axis", &axisIndex, axisEntries, 0);
        ps ~= Param.float_  ("offset", "Offset", &offset, 0.0f);
        ps ~= Param.bool_   ("useWorkplane", "Workplane", &useWorkplane, false);
        ps ~= Param.bool_   ("topology", "Topology", &topology, false);
        ps ~= Param.float_  ("epsilon", "Epsilon", &epsilonWorld, 1e-4f);
        return ps;
    }

    // Tool Properties panel — exposes the user-facing knobs whenever
    // symmetry is on. Hidden when off (same convention as FalloffStage
    // hides its config when type=None). The status-bar pulldown stays
    // the canonical place to flip enabled / axis; the property panel
    // is for fine-tuning offset and epsilon. A FILTER over fullParams()
    // (Constrain's safe pattern) — enabled/topology stay status-bar/
    // wire-owned and never appear in the panel.
    override Param[] params() {
        if (!enabled) return [];
        Param[] ps;
        foreach (p; fullParams()) {
            switch (p.name) {
                case "axis":
                case "offset":
                case "useWorkplane":
                case "epsilon":
                    ps ~= p;
                    break;
                default:
                    break;
            }
        }
        return ps;
    }

    override void onParamChanged(string name) {
        // Mirror setAttr's side-effect: refresh the status-bar state
        // paths so the pulldown highlights re-sync after a Tool
        // Properties edit.
        publishState();
    }

private:
    /// Task 0791 — symmetry does NOT split into activation and attribute the
    /// way the other slots do: measured on the reference, BOTH of its commands
    /// (the state toggle and the axis) end a held operation with the same
    /// activation bracket. So every accepted write here arms the slot.
    public override bool attrArmsSlot(string name) const { return true; }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "enabled":
                if      (value == "true"  || value == "1") { enabled = true;  return true; }
                else if (value == "false" || value == "0") { enabled = false; return true; }
                return false;
            case "axis":
                if      (value == "x" || value == "X") { axisIndex = 0; return true; }
                else if (value == "y" || value == "Y") { axisIndex = 1; return true; }
                else if (value == "z" || value == "Z") { axisIndex = 2; return true; }
                return false;
            case "offset": {
                // Task 3020 — through the shared wire gate, which refuses a
                // non-finite. `to!float` on its own accepts std.conv's textual
                // sentinels, so `offset nan` used to be answered `status ok`.
                import params : assignWireFloat;
                return assignWireFloat(value, offset);
            }
            case "useWorkplane":
                if      (value == "true"  || value == "1") { useWorkplane = true;  return true; }
                else if (value == "false" || value == "0") { useWorkplane = false; return true; }
                return false;
            case "topology":
                if      (value == "true"  || value == "1") { topology = true;  return true; }
                else if (value == "false" || value == "0") { topology = false; return true; }
                return false;
            case "epsilon": {
                // Task 3020 — the `v <= 0.0f` guard below is a COMPARISON, and
                // every comparison against a NaN is false, so it refused a
                // negative epsilon and waved a NaN one through: measured,
                // `tool.pipe.attr symmetry epsilon nan` answered `status ok`.
                // `assignWireFloat` refuses the non-finite first; the positivity
                // rule is unchanged and still this stage's own.
                import params : assignWireFloat;
                float v;
                if (!assignWireFloat(value, v)) return false;
                if (v <= 0.0f) return false;
                epsilonWorld = v;
                return true;
            }
            default: return false;
        }
    }

    void publishState() {
        // Drives the status-bar Symmetry pulldown (added in 7.6e) — same
        // checked-state convention as the SNAP / FALLOFF pulldowns.
        setStatePath("symmetry/enabled", enabled ? "true" : "false");
        setStatePath("symmetry/axis",    axisLabel(axisIndex));
        setStatePath("symmetry/useWorkplane",
                     useWorkplane ? "true" : "false");
        // Per-axis bits — drive the per-row checkmark in the popup.
        setStatePath("symmetry/axes/x", (enabled && axisIndex == 0) ? "true" : "false");
        setStatePath("symmetry/axes/y", (enabled && axisIndex == 1) ? "true" : "false");
        setStatePath("symmetry/axes/z", (enabled && axisIndex == 2) ? "true" : "false");
        setStatePath("symmetry/axes/off", enabled ? "false" : "true");

        // Drives the button-level `dynamicLabel` on the status-bar
        // Symmetry button. When symmetry is on, the button face flips
        // to "Symmetry: X" / "Symmetry: Y" / "Symmetry: Z" /
        // "Symmetry: Workplane"; empty string when off so the YAML
        // static label "Symmetry" stays.
        if (!enabled) {
            setStatePath("symmetry/displayName", "");
        } else if (useWorkplane) {
            setStatePath("symmetry/displayName", "Symmetry: Workplane");
        } else {
            import std.string : toUpper;
            setStatePath("symmetry/displayName",
                "Symmetry: " ~ axisLabel(axisIndex).toUpper);
        }
    }

    static Vec3 axisVec(int ax) {
        switch (ax) {
            case 0:  return Vec3(1, 0, 0);
            case 1:  return Vec3(0, 1, 0);
            case 2:  return Vec3(0, 0, 1);
            default: return Vec3(1, 0, 0);
        }
    }

    static string axisLabel(int ax) {
        switch (ax) {
            case 0:  return "x";
            case 1:  return "y";
            case 2:  return "z";
            default: return "x";
        }
    }
}
