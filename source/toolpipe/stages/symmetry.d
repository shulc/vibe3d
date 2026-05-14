module toolpipe.stages.symmetry;

import std.format : format;

import math    : Vec3, dot;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordSymm;
import toolpipe.pipeline : ToolState;
import toolpipe.packets  : SymmetryPacket;
import popup_state       : setStatePath;
import symmetry          : rebuildPairing;
import params            : Param, IntEnumEntry;

// ---------------------------------------------------------------------------
// SymmetryStage — phase 7.6 of doc/phase7_plan.md / doc/phase7_6_symm_plan.md.
// Sits at LXs_ORD_SYMM = 0x31 (between WORK 0x30 and SNAP 0x40).
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
//   `topology`     : "true" / "false" — schema-only in v1 (always
//                    falls back to position pairing in the evaluator)
//   `epsilon`      : float, world-space pairing tolerance
// ---------------------------------------------------------------------------
class SymmetryStage : Stage {
    bool  enabled       = false;
    int   axisIndex     = 0;          // 0=X 1=Y 2=Z (meaningful when enabled)
    float offset        = 0.0f;
    bool  useWorkplane  = false;
    bool  topology      = false;      // reserved
    float epsilonWorld  = 1e-4f;

    // MODO's `BaseSide` — which side of the plane the user last
    // anchored on. Updated by `anchorAt(pos)` after every pick that
    // happens with symmetry enabled. Default +1 so unset state
    // produces predictable behaviour (positive side drives).
    int   baseSide      = +1;

private:
    // Injected refs (mirrors FalloffStage / ActionCenterStage shape).
    // `mesh_` is required for pairing — null-mesh callers skip the
    // rebuild and publish an empty pair table (the editor never has a
    // null mesh; unit tests that bypass app.d's pipe init do).
    Mesh*     mesh_;
    EditMode* editMode_;

    // Pairing cache. Rebuilt when (mesh.mutationVersion, plane,
    // epsilon) change. `cachedReady_` toggles to true after the first
    // successful rebuild so a stage that's enabled mid-session can
    // publish a stale-empty packet for one frame before the cache
    // catches up on the next evaluate.
    ulong  cachedMutationVersion_ = ulong.max;
    Vec3   cachedPlanePoint_      = Vec3(0, 0, 0);
    Vec3   cachedPlaneNormal_     = Vec3(0, 0, 0);
    float  cachedEpsilon_         = float.nan;
    int[]  cachedPairOf_;
    bool[] cachedOnPlane_;
    int[]  cachedVertSign_;
    bool   cachedReady_           = false;

public:
    this(Mesh* mesh = null, EditMode* editMode = null) {
        this.mesh_     = mesh;
        this.editMode_ = editMode;
        publishState();
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
        enabled       = false;
        axisIndex     = 0;
        offset        = 0.0f;
        useWorkplane  = false;
        topology      = false;
        epsilonWorld  = 1e-4f;
        baseSide      = +1;
        // Drop the pairing cache too so the next evaluate rebuilds from
        // the post-reset mesh / plane rather than reusing stale pairs.
        cachedMutationVersion_ = ulong.max;
        cachedPlanePoint_      = Vec3(0, 0, 0);
        cachedPlaneNormal_     = Vec3(0, 0, 0);
        cachedEpsilon_         = float.nan;
        cachedPairOf_.length   = 0;
        cachedOnPlane_.length  = 0;
        cachedVertSign_.length = 0;
        cachedReady_           = false;
        publishState();
    }

    override void evaluate(ref ToolState state) {
        state.symmetry.enabled      = enabled;
        state.symmetry.topology     = topology;
        state.symmetry.epsilonWorld = epsilonWorld;
        state.symmetry.useWorkplane = useWorkplane;
        state.symmetry.offset       = offset;

        // Resolve plane. `useWorkplane` overrides axisIndex+offset; WORK
        // stage has already run (ord 0x30 < SYMM 0x31) so workplane is
        // populated. Disabled symmetry still publishes a sane plane
        // (axis-aligned, offset=0) so downstream code can read it
        // without an "is the plane valid?" guard.
        if (enabled && useWorkplane) {
            state.symmetry.axisIndex   = -1;
            state.symmetry.planePoint  = state.workplane.center;
            state.symmetry.planeNormal = state.workplane.normal;
        } else {
            int ax = enabled ? axisIndex : -1;
            state.symmetry.axisIndex   = ax;
            state.symmetry.planeNormal = axisVec(axisIndex);
            state.symmetry.planePoint  = axisVec(axisIndex) * offset;
        }

        // Phase 7.6b: rebuild the pair table on cache miss. Caches keyed
        // on (mutationVersion, plane, epsilon). When disabled we publish
        // empty slices — keeps the per-frame fast path allocation-free.
        if (enabled && mesh_ !is null && mesh_.vertices.length > 0) {
            bool planeChanged =
                cachedPlanePoint_  != state.symmetry.planePoint  ||
                cachedPlaneNormal_ != state.symmetry.planeNormal ||
                cachedEpsilon_     != epsilonWorld;
            bool meshChanged =
                cachedMutationVersion_ != mesh_.mutationVersion;
            if (!cachedReady_ || planeChanged || meshChanged) {
                rebuildPairing(*mesh_, state.symmetry,
                               cachedPairOf_, cachedOnPlane_, cachedVertSign_);
                cachedMutationVersion_ = mesh_.mutationVersion;
                cachedPlanePoint_      = state.symmetry.planePoint;
                cachedPlaneNormal_     = state.symmetry.planeNormal;
                cachedEpsilon_         = epsilonWorld;
                cachedReady_           = true;
            }
            state.symmetry.pairOf   = cachedPairOf_;
            state.symmetry.onPlane  = cachedOnPlane_;
            state.symmetry.vertSign = cachedVertSign_;
        } else {
            state.symmetry.pairOf   = null;
            state.symmetry.onPlane  = null;
            state.symmetry.vertSign = null;
        }
        state.symmetry.baseSide = baseSide;

        // Backwards-compat fields the phase-7.0 stub already declared.
        // Derived from axisIndex / offset so any code still reading
        // axisFlags[] or pivot keeps working through the migration.
        state.symmetry.axisFlags[0] = enabled && axisIndex == 0;
        state.symmetry.axisFlags[1] = enabled && axisIndex == 1;
        state.symmetry.axisFlags[2] = enabled && axisIndex == 2;
        state.symmetry.pivot        = state.symmetry.planePoint;
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    /// MODO `SetBase` analogue. Update `baseSide` from a world-space
    /// anchor point — typically the centroid of the element the user
    /// just clicked while symmetry was active. Off-plane anchors set
    /// `baseSide` to the side they land on; on-plane anchors leave the
    /// existing `baseSide` untouched (the user clicked something
    /// straddling the plane; previous anchor stays canonical).
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

    // Tool Properties panel — exposes the user-facing knobs whenever
    // symmetry is on. Hidden when off (same convention as FalloffStage
    // hides its config when type=None). The status-bar pulldown stays
    // the canonical place to flip enabled / axis; the property panel
    // is for fine-tuning offset and epsilon.
    override Param[] params() {
        if (!enabled) return [];
        IntEnumEntry[] axisEntries = [
            IntEnumEntry(0, "x", "X"),
            IntEnumEntry(1, "y", "Y"),
            IntEnumEntry(2, "z", "Z"),
        ];
        Param[] ps;
        ps ~= Param.intEnum_("axis", "Axis", &axisIndex, axisEntries, 0);
        ps ~= Param.float_  ("offset", "Offset", &offset, 0.0f);
        ps ~= Param.bool_   ("useWorkplane", "Workplane", &useWorkplane, false);
        ps ~= Param.float_  ("epsilon", "Epsilon", &epsilonWorld, 1e-4f);
        return ps;
    }

    override void onParamChanged(string name) {
        // Mirror setAttr's side-effect: refresh the status-bar state
        // paths so the pulldown highlights re-sync after a Tool
        // Properties edit.
        publishState();
    }

private:
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
            case "offset":
                try {
                    import std.conv : to;
                    import std.string : strip;
                    offset = value.strip.to!float;
                    return true;
                } catch (Exception) { return false; }
            case "useWorkplane":
                if      (value == "true"  || value == "1") { useWorkplane = true;  return true; }
                else if (value == "false" || value == "0") { useWorkplane = false; return true; }
                return false;
            case "topology":
                if      (value == "true"  || value == "1") { topology = true;  return true; }
                else if (value == "false" || value == "0") { topology = false; return true; }
                return false;
            case "epsilon":
                try {
                    import std.conv : to;
                    import std.string : strip;
                    float v = value.strip.to!float;
                    if (v <= 0.0f) return false;
                    epsilonWorld = v;
                    return true;
                } catch (Exception) { return false; }
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

