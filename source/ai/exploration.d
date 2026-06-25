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
            // Camera-move guard: compare view element-wise (viewcache.d convention).
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

unittest { // fromEnv with no env var ⇒ disabled
    import std.process : environment;
    // Make sure VIBE3D_AI_EXPLORE is absent for this test.
    // We can't unset it reliably in a cross-platform way, so just test the
    // direct constructor instead, which fromEnv delegates to.
    auto ctrl = new AiExplorationController(0.0f, 42u);
    assert(!ctrl.enabled());
}

unittest { // ε=0 ⇒ sampleOverrideIndex always -1
    auto ctrl = new AiExplorationController(0.0f, 42u);
    foreach (_; 0 .. 100)
        assert(ctrl.sampleOverrideIndex(5, 0) == -1);
}

unittest { // candidateCount < 2 ⇒ always -1 regardless of ε
    auto ctrl = new AiExplorationController(1.0f, 42u);
    assert(ctrl.sampleOverrideIndex(0, 0) == -1);
    assert(ctrl.sampleOverrideIndex(1, 0) == -1);
}

unittest { // ε=1 ⇒ always overrides; override never equals defaultIndex
    auto ctrl = new AiExplorationController(1.0f, 12345u);
    foreach (defaultIdx; 0 .. 4) {
        foreach (_; 0 .. 50) {
            int idx = ctrl.sampleOverrideIndex(5, defaultIdx);
            assert(idx >= 0 && idx < 5);
            assert(idx != defaultIdx);
        }
    }
}

unittest { // seeded determinism: same seed ⇒ same sequence
    auto a = new AiExplorationController(0.5f, 99u);
    auto b = new AiExplorationController(0.5f, 99u);
    foreach (_; 0 .. 30) {
        int ia = a.sampleOverrideIndex(3, 0);
        int ib = b.sampleOverrideIndex(3, 0);
        assert(ia == ib);
    }
}

unittest { // buildCandidateKey is order-independent
    import ai.interaction : AiCandidate, AiCandidateKind;
    AiCandidate c1, c2, c3;
    c1.id = "handle:20"; c1.kind = AiCandidateKind.handle;
    c2.id = "handle:0";  c2.kind = AiCandidateKind.handle;
    c3.id = "handle:10"; c3.kind = AiCandidateKind.handle;
    string k1 = buildCandidateKey([c1, c2, c3]);
    string k2 = buildCandidateKey([c3, c1, c2]);
    assert(k1 == k2);
    assert(k1 == "handle:0|handle:10|handle:20");
}

unittest { // parseHandlePart
    assert(parseHandlePart("handle:0")  ==  0);
    assert(parseHandlePart("handle:12") == 12);
    assert(parseHandlePart("element:5") == -1);
    assert(parseHandlePart("handle:x")  == -1);
}

// Helper to build a minimal AiInteractionLogRecord with given candidate ids.
version (unittest) {
    import ai.interaction : AiInteractionContext;
    import ai.interaction_log : makeAiInteractionLogRecord,
        AiInteractionLogRecord;
    import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind;

    private AiInteractionLogRecord _makeTestRecord(string[] ids, int appliedIdx) {
        AiCandidate[] cands;
        cands.length = ids.length;
        foreach (i, id; ids) {
            cands[i].id   = id;
            cands[i].kind = AiCandidateKind.handle;
            if (i == 0) cands[i].isDefaultWinner = true;
        }
        AiInteractionContext ctx;
        return makeAiInteractionLogRecord(
            "live-explore:test", "handles", ctx, cands,
            AiAdvisorDecision(), appliedIdx);
    }

    private float[16] _identityView() {
        float[16] v;
        v[] = 0.0f;
        v[0] = v[5] = v[10] = v[15] = 1.0f;
        return v;
    }
}

unittest { // state machine: retry-different → Emit with re-grabbed label
    auto ctrl = new AiExplorationController(1.0f, 1u);

    // Build a record with 2 candidates; grabbed index 1 (the ε-sampled one).
    auto rec = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view  = _identityView();

    ctrl.stagePending(rec, key, 1, 0UL, view);
    assert(ctrl.hasPending());

    // Tick: no undo yet — should stay idle.
    auto r0 = ctrl.step(0UL, view, OptionalGrab());
    assert(r0.kind == ResolutionKind.None);

    // Tick: undo happened (epoch bumped from 0 → 1).
    OptionalGrab noGrab;
    auto r1 = ctrl.step(1UL, view, noGrab);
    assert(r1.kind == ResolutionKind.None);  // awaiting regrab

    // Tick: user re-grabs handle:0 (the DEFAULT — a different candidate from index 1).
    OptionalGrab grab;
    grab.present   = true;
    grab.sortedKey = key;
    grab.partInt   = 0;
    auto r2 = ctrl.step(1UL, view, grab);
    assert(r2.kind == ResolutionKind.Emit);
    assert(r2.record.appliedWinnerId == "handle:0");
    assert(r2.record.appliedWinnerIndex == 0);
    assert(!ctrl.hasPending());
}

unittest { // state machine: same-handle retry → discard
    auto ctrl = new AiExplorationController(1.0f, 2u);

    auto rec  = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view  = _identityView();

    ctrl.stagePending(rec, key, 1, 0UL, view);
    ctrl.step(1UL, view, OptionalGrab());  // undo detected

    // Re-grab the SAME candidate (handle:10 = index 1).
    OptionalGrab grab;
    grab.present   = true;
    grab.sortedKey = key;
    grab.partInt   = 10;
    auto r = ctrl.step(1UL, view, grab);
    assert(r.kind == ResolutionKind.Discard);
    assert(!ctrl.hasPending());
}

unittest { // state machine: camera-move → discard
    auto ctrl = new AiExplorationController(1.0f, 3u);

    auto rec  = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view1 = _identityView();

    ctrl.stagePending(rec, key, 1, 0UL, view1);

    // Undo detected first.
    ctrl.step(1UL, view1, OptionalGrab());

    // Camera moved (element 0 differs).
    auto view2 = _identityView();
    view2[0] = 1.1f;  // change one element

    auto r = ctrl.step(1UL, view2, OptionalGrab());
    assert(r.kind == ResolutionKind.Discard);
    assert(!ctrl.hasPending());
}

unittest { // state machine: abandon (no regrab, discard explicitly)
    auto ctrl = new AiExplorationController(1.0f, 4u);

    auto rec  = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view  = _identityView();

    ctrl.stagePending(rec, key, 1, 0UL, view);
    ctrl.step(1UL, view, OptionalGrab());  // undo detected
    ctrl.discardPending();
    assert(!ctrl.hasPending());
}

unittest { // state machine: camera move BEFORE undo → discard
    auto ctrl = new AiExplorationController(1.0f, 5u);

    auto rec  = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view1 = _identityView();
    ctrl.stagePending(rec, key, 1, 0UL, view1);

    // Camera moves before any undo.
    auto view2 = _identityView();
    view2[12] = 0.5f;
    auto r = ctrl.step(0UL, view2, OptionalGrab());
    assert(r.kind == ResolutionKind.Discard);
    assert(!ctrl.hasPending());
}

unittest { // Emit record passes exportAiTrainingDatasetJsonl with labeled==1
    import ai.training_dataset : exportAiTrainingDatasetJsonl;

    auto ctrl = new AiExplorationController(1.0f, 6u);

    auto rec   = _makeTestRecord(["handle:0", "handle:10"], 1);
    string key = buildCandidateKey(rec.candidates);
    auto view  = _identityView();

    ctrl.stagePending(rec, key, 1, 0UL, view);
    ctrl.step(1UL, view, OptionalGrab());  // undo detected

    OptionalGrab grab;
    grab.present   = true;
    grab.sortedKey = key;
    grab.partInt   = 0;  // re-grab handle:0
    auto resolved = ctrl.step(1UL, view, grab);
    assert(resolved.kind == ResolutionKind.Emit);

    // Feed through the REAL exporter — schema must be untouched.
    auto result = exportAiTrainingDatasetJsonl([resolved.record]);
    assert(result.stats.labeled   == 1, "must be labeled");
    assert(result.stats.unlabeled == 0, "must not be unlabeled");
    assert(result.lines.length    == 1);

    // The label.id in the JSONL should equal the re-grabbed candidate id.
    import std.string : indexOf;
    assert(result.lines[0].indexOf(`"handle:0"`) >= 0,
           "label id must be handle:0 in the emitted JSONL");
}
