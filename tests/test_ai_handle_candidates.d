// Pure tests for handle candidate collection in the shared handle arbiter.

import std.json : parseJSON;

import ai.advisor : AiAdvisor;
import ai.debug_trace : clearLatestHandleDebugTrace, latestHandleDebugTrace,
    latestHandleDebugTraceJson;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import handler : Handler, ToolHandles, setHandleAiAdvisor;
import math : Viewport;

void main() {}

private class TestHandle : Handler {
    bool shouldHit;
    float screenDistance;
    int hitCalls;

    this(bool shouldHit, float screenDistance = 0.0f) {
        this.shouldHit = shouldHit;
        this.screenDistance = screenDistance;
    }

    override protected bool hitTest(int mx, int my, const ref Viewport vp) {
        ++hitCalls;
        return shouldHit;
    }

    override protected float aiScreenDistance(int mx, int my,
                                              const ref Viewport vp) {
        return shouldHit ? screenDistance : float.infinity;
    }
}

private int spyCalls;
private AiInteractionContext spyContext;
private string[] spyCandidateIds;

private void resetSpyAdvisor() {
    spyCalls = 0;
    spyContext = AiInteractionContext();
    spyCandidateIds.length = 0;
}

private class SpyAdvisor : AiAdvisor {
    override AiAdvisorDecision advise(const ref AiInteractionContext context,
                                      const(AiCandidate)[] candidates) const {
        ++spyCalls;
        spyContext.phase = context.phase;
        spyContext.defaultIntent = context.defaultIntent;
        spyContext.mouseX = context.mouseX;
        spyContext.mouseY = context.mouseY;
        spyContext.isDragging = context.isDragging;

        spyCandidateIds.length = 0;
        foreach (ref c; candidates)
            spyCandidateIds ~= c.id;

        AiAdvisorDecision decision;
        decision.intent = AiIntent.dragAxisZ;
        decision.confidence = 0.9f;
        if (candidates.length > 1) {
            decision.candidateIndex = 1;
            decision.candidateId = candidates[1].id;
        }
        return decision;
    }
}

unittest { // first-hit winner is preserved while all hit candidates are exposed
    clearLatestHandleDebugTrace();
    auto first = new TestHandle(true);
    auto miss = new TestHandle(false);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(miss, 20);
    handles.add(later, 30);
    handles.hot = 7;
    handles.captured = 8;

    int winner = handles.test(123, 456, vp);
    assert(winner == 10);
    assert(handles.hot == 7);
    assert(handles.captured == 8);
    assert(first.hitCalls == 1);
    assert(miss.hitCalls == 1);
    assert(later.hitCalls == 1);

    auto candidates = handles.handleCandidates();
    assert(candidates.length == 2);
    assert(candidates[0].id == "handle:10");
    assert(candidates[0].kind == AiCandidateKind.handle);
    assert(candidates[0].intent == AiIntent.handle);
    assert(candidates[0].screenDist == 0.0f);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].hasScreenPosition);
    assert(candidates[0].screenPosition == [123.0f, 456.0f]);

    assert(candidates[1].id == "handle:30");
    assert(candidates[1].kind == AiCandidateKind.handle);
    assert(candidates[1].intent == AiIntent.handle);
    assert(candidates[1].screenDist == 0.0f);
    assert(candidates[1].priorityFromCurrentRules == 2.0f);
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[1].screenPosition == [123.0f, 456.0f]);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 2);
    assert(trace.candidates[0].id == "handle:10");
    assert(trace.candidates[1].id == "handle:30");
    assert(trace.defaultWinnerIndex == 0);
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerIndex == 0);
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
    assert(trace.advisor.confidence == 0.0f);
    assert(trace.advisor.candidateIndex == -1);
}

unittest { // real ToolHandles + real advisor can apply a valid advisory winner
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(new AiAdvisor(true));
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true, 42.0f);
    auto later = new TestHandle(true, 6.0f);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    handles.hot = 7;

    int winner = handles.test(123, 456, vp, AiInteractionPhase.mouseDown);
    assert(winner == 30);
    assert(handles.hot == 7);
    assert(handles.captured == -1);

    auto candidates = handles.handleCandidates();
    assert(candidates.length == 2);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].screenDist == 42.0f);
    assert(candidates[1].screenDist == 6.0f);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(!trace.advisor.keepDefault);
    assert(trace.advisor.intent == AiIntent.handle);
    assert(trace.advisor.confidence >= 0.75f);
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:30");
    assert(trace.appliedWinnerIndex == 1);
    assert(trace.appliedWinnerId == "handle:30");
}

unittest { // disabled real advisor keeps default even for clear handle candidates
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(new AiAdvisor(false));
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true, 42.0f);
    auto later = new TestHandle(true, 6.0f);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
    assert(trace.advisor.confidence == 0.0f);
    assert(trace.advisor.candidateIndex == -1);
}

unittest { // real advisor keeps default when handle margin is low
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(new AiAdvisor(true));
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true, 12.0f);
    auto later = new TestHandle(true, 6.0f);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
    assert(trace.advisor.confidence == 0.0f);
    assert(trace.advisor.candidateIndex == -1);
}

unittest { // advisor decision can switch only to a valid hit candidate
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    int winner = handles.test(123, 456, vp, AiInteractionPhase.mouseDown);
    assert(winner == 30);
    assert(handles.hot == -1);
    assert(handles.captured == -1);
    assert(handles.handleCandidates()[0].isDefaultWinner);
    assert(!handles.handleCandidates()[1].isDefaultWinner);

    assert(spyCalls == 1);
    assert(spyContext.phase == AiInteractionPhase.mouseDown);
    assert(spyContext.defaultIntent == AiIntent.keepDefault);
    assert(spyContext.mouseX == 123);
    assert(spyContext.mouseY == 456);
    assert(!spyContext.isDragging);
    assert(spyCandidateIds == ["handle:10", "handle:30"]);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerIndex == 0);
    assert(trace.defaultWinnerId == "handle:10");
    assert(!trace.advisor.keepDefault);
    assert(trace.advisor.intent == AiIntent.dragAxisZ);
    assert(trace.advisor.confidence == 0.9f);
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:30");
    assert(trace.appliedWinnerIndex == 1);
    assert(trace.appliedWinnerId == "handle:30");

    auto j = parseJSON(latestHandleDebugTraceJson(true));
    assert(j["advisor"]["intent"].str == "dragAxisZ");
    assert(j["advisor"]["confidence"].floating == 0.9);
    assert(j["advisor"]["candidateIndex"].integer == 1);
    assert(j["advisor"]["candidateId"].str == "handle:30");
    assert(j["handleTrace"]["defaultWinner"]["id"].str == "handle:10");
    assert(j["handleTrace"]["appliedWinner"]["id"].str == "handle:30");
}

private class InvalidAdvisor : AiAdvisor {
    int candidateIndex;
    string candidateId;

    this(int candidateIndex, string candidateId) {
        this.candidateIndex = candidateIndex;
        this.candidateId = candidateId;
    }

    override AiAdvisorDecision advise(const ref AiInteractionContext context,
                                      const(AiCandidate)[] candidates) const {
        AiAdvisorDecision decision;
        decision.intent = AiIntent.dragAxisZ;
        decision.confidence = 0.95f;
        decision.candidateIndex = candidateIndex;
        decision.candidateId = candidateId;
        return decision;
    }
}

unittest { // invalid advisory candidates fall back to the deterministic winner
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(new InvalidAdvisor(1, "handle:999"));
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:999");

    setHandleAiAdvisor(new InvalidAdvisor(12, "handle:30"));
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);
    auto secondTrace = latestHandleDebugTrace();
    assert(secondTrace.defaultWinnerId == "handle:10");
    assert(secondTrace.appliedWinnerId == "handle:10");
    assert(secondTrace.advisor.candidateIndex == 12);
    assert(secondTrace.advisor.candidateId == "handle:30");
}

unittest { // advisory choices are not applied outside the mouse-down gate
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    assert(handles.test(123, 456, vp, AiInteractionPhase.hover) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.candidateIndex == 1);
}

unittest { // captured drags preserve the latched handle and skip retesting
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    handles.captured = 30;

    handles.update(123, 456, vp);
    assert(handles.hot == 30);
    assert(handles.captured == 30);
    assert(first.hitCalls == 0);
    assert(later.hitCalls == 0);
    assert(spyCalls == 0);
}

unittest { // invisible hits are skipped exactly like default arbitration
    clearLatestHandleDebugTrace();
    auto hidden = new TestHandle(true);
    auto visible = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    hidden.setVisible(false);
    handles.begin();
    handles.add(hidden, 1);
    handles.add(visible, 2);

    assert(handles.test(10, 20, vp) == 2);
    assert(hidden.hitCalls == 0);
    assert(visible.hitCalls == 1);

    auto candidates = handles.handleCandidates();
    assert(candidates.length == 1);
    assert(candidates[0].id == "handle:2");
    assert(candidates[0].isDefaultWinner);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 1);
    assert(trace.candidates[0].id == "handle:2");
    assert(trace.defaultWinnerIndex == 0);
    assert(trace.defaultWinnerId == "handle:2");
    assert(trace.appliedWinnerIndex == 0);
    assert(trace.appliedWinnerId == "handle:2");
}

unittest { // suppressed updates publish an empty trace and do not test handles
    clearLatestHandleDebugTrace();
    auto visible = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(visible, 2);
    handles.suppress();
    handles.hot = 9;
    handles.update(10, 20, vp);

    assert(handles.hot == -1);
    assert(visible.hitCalls == 0);
    assert(handles.handleCandidates().length == 0);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 0);
    assert(trace.defaultWinnerIndex == -1);
    assert(trace.defaultWinnerId.length == 0);
    assert(trace.appliedWinnerIndex == -1);
    assert(trace.appliedWinnerId.length == 0);
}
