/// ai/exploration.d — ε-exploration controller for outcome-derived labeling.
///
/// Owned entirely by this module: seedable PRNG, ε-sample decision, pending-
/// record buffer, and outcome state machine.  No SDL / GL / file I/O — all
/// logic is pure, directly unit-testable.
///
/// Enabled via VIBE3D_AI_EXPLORE=<ε∈[0,1]> + VIBE3D_AI_EXPLORE_SEED=<int>.
/// When the flag is absent or ε=0 the controller is disabled and every
/// per-frame path is a strict no-op (byte-identical to the non-exploration
/// build path).
module ai.exploration;

import std.conv   : to;
import std.format : format;

import ai.interaction_log : AiInteractionLogRecord;
import ai.interaction     : AiCandidate;

// ---------------------------------------------------------------------------
// Source-tag helper — mirrors defaultLiveSource() in interaction_log_writer.d.
// Distinguishes exploration records so they can be filtered from passive ones.
// ---------------------------------------------------------------------------
string defaultExploreSource() {
    import std.process : thisProcessID;
    return "live-explore:" ~ thisProcessID().to!string;
}

// ---------------------------------------------------------------------------
// Resolution — what the state machine emits per frame.
// ---------------------------------------------------------------------------
enum ResolutionKind { None, Emit, Discard }

struct Resolution {
    ResolutionKind kind = ResolutionKind.None;
    AiInteractionLogRecord record;   // valid only when kind == Emit

    static Resolution none()            { return Resolution(ResolutionKind.None); }
    static Resolution discard()         { return Resolution(ResolutionKind.Discard); }
    static Resolution emit(AiInteractionLogRecord rec) {
        return Resolution(ResolutionKind.Emit, rec);
    }
}

// ---------------------------------------------------------------------------
// OptionalGrab — a re-grab event forwarded to step().
// present=false ⇒ no re-grab this tick.
// ---------------------------------------------------------------------------
struct OptionalGrab {
    bool   present    = false;
    string sortedKey  = "";   // sorted join of candidate ids (same form as staged)
    int    partInt    = -1;   // the raw part number re-grabbed (parsed from the id)
}

// ---------------------------------------------------------------------------
// Build the canonical "same-set key" from a candidate array:
// sorted, joined candidate ids.  Camera-invariant (part ids are geometry IDs).
// ---------------------------------------------------------------------------
string buildCandidateKey(const(AiCandidate)[] candidates) {
    import std.algorithm : sort;
    import std.array     : array;

    string[] ids;
    ids.reserve(candidates.length);
    foreach (ref c; candidates)
        ids ~= c.id;
    sort(ids);
    string key;
    foreach (i, id; ids) {
        if (i) key ~= "|";
        key ~= id;
    }
    return key;
}

// ---------------------------------------------------------------------------
// Parse the integer part from "handle:<n>".  Returns -1 on parse failure.
// ---------------------------------------------------------------------------
int parseHandlePart(string id) {
    import std.string    : startsWith;
    import std.exception : ifThrown;
    if (!id.startsWith("handle:")) return -1;
    return id["handle:".length .. $].to!int.ifThrown(-1);
}

// ---------------------------------------------------------------------------
// AiExplorationController
// ---------------------------------------------------------------------------
final class AiExplorationController {
    // ---- PRNG -----------------------------------------------------------------
    // std.random.Mt19937 is the canonical 32-bit Mersenne Twister from Phobos.
    // Seeded once at construction; scoped exclusively to this module — the
    // project has no general seedable-PRNG convention, so we own the engine here.
    import std.random : Mt19937, uniform;
    private Mt19937 prng_;
    private float   epsilon_ = 0.0f;

    // ---- Pending buffer state machine ----------------------------------------
    private enum SMState { Idle, AwaitingUndo, AwaitingRegrab }

    private SMState  smState_   = SMState.Idle;
    private AiInteractionLogRecord pendingRecord_;
    private string   pendingKey_;           // sorted candidate-id set of staged grab
    private int      pendingGrabbedIndex_;  // index in pendingRecord_.candidates
    private ulong    pendingUndoEpoch_;     // epoch snapshot at stage time
    private float[16] pendingView_;         // view matrix snapshot at stage time

    // ---- Construction --------------------------------------------------------

    /// Build from explicit values (also used by unit tests).
    this(float epsilon, uint seed) {
        epsilon_ = (epsilon >= 0.0f && epsilon <= 1.0f) ? epsilon : 0.0f;
        prng_.seed(seed);
    }

    /// Read ε and seed from environment variables:
    ///   VIBE3D_AI_EXPLORE=<ε>          (absent / invalid ⇒ ε=0 ⇒ disabled)
    ///   VIBE3D_AI_EXPLORE_SEED=<int>   (absent ⇒ fixed default 42)
    static AiExplorationController fromEnv() {
        import std.process   : environment;
        import std.exception : ifThrown;

        string epsilonStr = environment.get("VIBE3D_AI_EXPLORE", "");
        float  epsilon    = 0.0f;
        if (epsilonStr.length > 0)
            epsilon = epsilonStr.to!float.ifThrown(0.0f);

        string seedStr = environment.get("VIBE3D_AI_EXPLORE_SEED", "");
        uint seed = 42u;
        if (seedStr.length > 0)
            seed = cast(uint)seedStr.to!long.ifThrown(42L);

        return new AiExplorationController(epsilon, seed);
    }

    // ---- Queries -------------------------------------------------------------

    bool enabled() const { return epsilon_ > 0.0f; }

    // ---- ε-sampling ----------------------------------------------------------

    /// With probability ε, return a RANDOM non-default candidate index in
    /// [0, candidateCount); otherwise return -1 (= do not override).
    /// Returns -1 when candidateCount < 2 (no alternative exists).
    /// Never returns the default index.
    int sampleOverrideIndex(size_t candidateCount, size_t defaultIndex) {
        if (candidateCount < 2) return -1;

        // Bernoulli draw: sample uniform(0,1) and compare to epsilon.
        float draw = uniform(0.0f, 1.0f, prng_);
        if (draw >= epsilon_) return -1;  // (1 - ε) of the time: no override

        // Pick a uniformly random index from {0,..,candidateCount-1} \ {defaultIndex}.
        // Achieved by picking in [0, candidateCount-2] then shifting past defaultIndex.
        size_t r = cast(size_t)uniform(0, cast(uint)(candidateCount - 1), prng_);
        if (r >= defaultIndex) r += 1;
        return cast(int)r;
    }

    // ---- Pending buffer ------------------------------------------------------

    /// Stage a pending record.  Called by the capture sink when exploring and
    /// a genuine handle apply fires.  `sortedIdKey` is the sorted joined
    /// candidate ids (build via buildCandidateKey); `grabbedIndex` is the
    /// index in record.candidates that was actually hauled (may differ from
    /// the default when ε-sampling overrode it); `undoEpochAtStage` and
    /// `viewAtStage` are snapshots for undo-detection and camera-change guard.
    void stagePending(AiInteractionLogRecord rec,
                      string sortedIdKey,
                      int    grabbedIndex,
                      ulong  undoEpochAtStage,
                      float[16] viewAtStage) {
        // Discard any prior pending (should not happen in practice — stagePending
        // is only called on a mouseDown which can't happen while a drag is in
        // flight, but be defensive).
        smState_           = SMState.AwaitingUndo;
        pendingRecord_     = rec;
        pendingKey_        = sortedIdKey;
        pendingGrabbedIndex_ = grabbedIndex;
        pendingUndoEpoch_  = undoEpochAtStage;
        pendingView_       = viewAtStage;
    }

    bool hasPending() const { return smState_ != SMState.Idle; }

    /// Per-frame state-machine tick.  Returns a Resolution (Emit / Discard / None).
    ///
    /// Parameters:
    ///   curUndoEpoch — current history.undoEpoch() value.
    ///   curView      — current cameraView.viewport().view (float[16]).
    ///   regrab       — if a handle grab occurred THIS tick, set present=true.
    Resolution step(ulong curUndoEpoch, float[16] curView, OptionalGrab regrab) {
        if (smState_ == SMState.Idle)
            return Resolution.none();

        // ---- AwaitingUndo: waiting for the user to undo the random drag ----
        if (smState_ == SMState.AwaitingUndo) {
            // Camera-move guard: compare view element-wise.
            //
            // KNOWING DIVERGENCE (task 1930). This is the one hand-written
            // matrix compare that did NOT fold into `CameraStamp`
            // (`camera_stamp.d`), and the reason is in the two lines below
            // and at `:203-209`: `pendingView_` is an INTENTIONALLY FROZEN
            // anchor from stage time, not "the pose I last derived under",
            // and this guard compares `view` ONLY — no `proj`. A stamp whose
            // whole contract is `changed(v, p)` over both halves does not fit
            // without an overload nobody else wants. Folding it in would
            // change what this state machine discards.
            if (!viewsEqual(curView, pendingView_)) {
                smState_ = SMState.Idle;
                return Resolution.discard();
            }

            if (curUndoEpoch > pendingUndoEpoch_) {
                // A genuine undo happened since stage — transition to AwaitingRegrab.
                // pendingView_ is intentionally NOT updated: the camera-move guard
                // above stays anchored to the stage-time view, so any orbit between
                // stage and re-grab conservatively discards the pending (the
                // candidate set is a screen-space hit-test and can't be trusted
                // across a view change).
                smState_ = SMState.AwaitingRegrab;
            }

            // If a re-grab arrived in the SAME tick as the undo detection, handle it.
            if (smState_ == SMState.AwaitingRegrab && regrab.present)
                return resolveRegrab(regrab);

            return Resolution.none();
        }

        // ---- AwaitingRegrab: undo confirmed, waiting for a re-grab ----------
        if (smState_ == SMState.AwaitingRegrab) {
            // Camera-move guard at resolve time.
            if (!viewsEqual(curView, pendingView_)) {
                smState_ = SMState.Idle;
                return Resolution.discard();
            }

            if (regrab.present)
                return resolveRegrab(regrab);

            // No re-grab this tick yet — keep waiting (bounded by the wall-clock
            // cap managed externally, or until the next stagePending clears us).
            return Resolution.none();
        }

        return Resolution.none();
    }

    /// Force-discard any pending record (e.g. on scene reset).
    void discardPending() {
        smState_ = SMState.Idle;
    }

    // ---- Private helpers -----------------------------------------------------

    private Resolution resolveRegrab(OptionalGrab regrab) {
        smState_ = SMState.Idle;

        // Same-set check: the re-grab must hit the same candidate set.
        if (regrab.sortedKey != pendingKey_)
            return Resolution.discard();

        // Find the re-grabbed candidate by its public id in the STAGED record.
        string regrabId = "handle:" ~ regrab.partInt.to!string;
        int j = -1;
        foreach (i, ref c; pendingRecord_.candidates) {
            if (c.id == regrabId) {
                j = cast(int)i;
                break;
            }
        }
        if (j < 0)
            return Resolution.discard();  // id not in staged set (shouldn't happen)

        // GOLD path: re-grabbed the SAME candidate — not informative (user
        // confirmed the random grab).  Filter (discard in v1).
        if (j == pendingGrabbedIndex_)
            return Resolution.discard();

        // GOLD path: re-grabbed a DIFFERENT candidate — this IS the ground truth.
        // Rewrite the applied winner in the staged record.
        pendingRecord_.withAppliedWinner(j, pendingRecord_.candidates[j].id);
        return Resolution.emit(pendingRecord_);
    }

    private static bool viewsEqual(const ref float[16] a, const ref float[16] b) {
        foreach (i; 0 .. 16)
            if (a[i] != b[i]) return false;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Module unit tests — pure logic, no SDL/GL/file I/O
// ---------------------------------------------------------------------------








// Helper to build a minimal AiInteractionLogRecord with given candidate ids.













