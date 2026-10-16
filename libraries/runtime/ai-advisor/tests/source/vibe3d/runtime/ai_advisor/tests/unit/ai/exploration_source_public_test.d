module vibe3d.runtime.ai_advisor.tests.unit.ai.exploration_source_public_test;

import vibe3d.runtime.ai_advisor.ai.exploration;

version (unittest) {
    import vibe3d.editing.interaction.data.ai.interaction : AiInteractionContext;
    import vibe3d.runtime.ai_advisor.ai.interaction_log : makeAiInteractionLogRecord,
        AiInteractionLogRecord;
    import vibe3d.editing.interaction.data.ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind;

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
    import vibe3d.runtime.ai_advisor.ai.training_dataset : exportAiTrainingDatasetJsonl;

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
