// Pure tests for handle candidate collection in the shared handle arbiter.

import std.conv : to;
import std.json : parseJSON;

import ai.advisor : AiAdvisor;
import ai.debug_trace : clearLatestHandleDebugTrace, latestHandleDebugTrace,
    latestHandleDebugTraceJson;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import bindbc.sdl : SDL_BUTTON_LEFT, SDL_MouseButtonEvent;
import editmode : EditMode;
import handler : Handler, HandleState, ToolHandles, setHandleAiAdvisor;
import math : Viewport;
import mesh : GpuMesh, Mesh, makeCube;
import operator : VectorStack;
import tools.transform.xfrm_transform : XfrmTransformTool,
    xfrmCompactScaleHeadFallbackForTest, xfrmLatchedHandlePartForTest;

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

private void registerFalloffThenTransform(ToolHandles handles,
                                          TestHandle falloffLike,
                                          TestHandle transformLike) {
    // Mirrors PipeGizmoHost::registerInto before XfrmTransformTool's gizmo
    // banks: falloff handles win the deterministic overlap by pool order.
    handles.add(falloffLike, 100);
    handles.add(transformLike, 10);
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

unittest { // AI-off hover remains the deterministic first hit
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

    handles.update(123, 456, vp);
    assert(handles.hot == 10);
    assert(handles.secondaryDefault == -1);
    assert(first.getState() == HandleState.Rollover);
    assert(later.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
}

unittest { // AI hover preview shows applied winner and ghosts the old default
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    handles.update(123, 456, vp);
    assert(handles.hot == 30);
    assert(handles.secondaryDefault == 10);
    assert(first.getState() == HandleState.SecondaryDefault);
    assert(later.getState() == HandleState.Rollover);
    assert(spyCalls == 1);
    assert(spyContext.phase == AiInteractionPhase.hover);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
    assert(trace.advisor.candidateIndex == 1);
}

unittest { // shared ToolHandles stay deterministic on hover unless opted in
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

    handles.update(123, 456, vp);
    assert(handles.hot == 10);
    assert(handles.secondaryDefault == -1);
    assert(first.getState() == HandleState.Rollover);
    assert(later.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.candidateIndex == 1);
}

unittest { // hover preview opt-in can exclude parts with deterministic click paths
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.setAiHoverPreviewPredicate((int part) const => part < 20);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    handles.update(123, 456, vp);
    assert(handles.hot == 10);
    assert(handles.secondaryDefault == -1);
    assert(first.getState() == HandleState.Rollover);
    assert(later.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.candidateIndex == 1);
}

unittest { // hover preview cannot promote from an excluded default scope
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto falloffLikeDefault = new TestHandle(true);
    auto transformLikeLater = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.setAiHoverPreviewPredicate((int part) const => part < 100);
    handles.begin();
    handles.add(falloffLikeDefault, 100);
    handles.add(transformLikeLater, 10);

    handles.update(123, 456, vp);
    assert(handles.hot == 100);
    assert(handles.secondaryDefault == -1);
    assert(falloffLikeDefault.getState() == HandleState.Rollover);
    assert(transformLikeLater.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:100");
    assert(trace.appliedWinnerId == "handle:100");
    assert(trace.advisor.candidateIndex == 1);
}

unittest { // falloff default cannot receive AI hover promotion to transform
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto falloffLikeDefault = new TestHandle(true);
    auto transformLikeLater = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.setAiHoverPreviewPredicate((int part) const => part >= 0 && part < 30);
    handles.begin();
    registerFalloffThenTransform(handles, falloffLikeDefault, transformLikeLater);

    handles.update(123, 456, vp);
    assert(handles.hot == 100);
    assert(handles.secondaryDefault == -1);
    assert(falloffLikeDefault.getState() == HandleState.Rollover);
    assert(transformLikeLater.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 2);
    assert(trace.defaultWinnerId == "handle:100");
    assert(trace.appliedWinnerId == "handle:100");
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:10");
}

unittest { // transform default cannot receive AI hover promotion to falloff
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto transformLikeDefault = new TestHandle(true);
    auto falloffLikeLater = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.setAiHoverPreviewPredicate((int part) const => part >= 0 && part < 30);
    handles.begin();
    handles.add(transformLikeDefault, 10);
    handles.add(falloffLikeLater, 100);

    handles.update(123, 456, vp);
    assert(handles.hot == 10);
    assert(handles.secondaryDefault == -1);
    assert(transformLikeDefault.getState() == HandleState.Rollover);
    assert(falloffLikeLater.getState() == HandleState.Normal);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 2);
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:100");
}

unittest { // transform default can still preview advisory transform winner
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto transformLikeDefault = new TestHandle(true);
    auto transformLikeLater = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.setAiHoverPreviewPredicate((int part) const => part >= 0 && part < 30);
    handles.begin();
    handles.add(transformLikeDefault, 10);
    handles.add(transformLikeLater, 20);

    handles.update(123, 456, vp);
    assert(handles.hot == 20);
    assert(handles.secondaryDefault == 10);
    assert(transformLikeDefault.getState() == HandleState.SecondaryDefault);
    assert(transformLikeLater.getState() == HandleState.Rollover);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 2);
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:20");
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:20");
}

unittest { // stable hover and mouse-down candidates resolve to the same handle
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    handles.update(123, 456, vp);
    assert(handles.hot == 30);
    assert(handles.secondaryDefault == 10);

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 30);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
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

unittest { // advisor-applied shared winner decodes to the production latch part
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto defaultMove = new TestHandle(true);
    auto laterScaleZ = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(defaultMove, 0);
    handles.add(laterScaleZ, 22);

    int winner = handles.test(123, 456, vp, AiInteractionPhase.mouseDown);
    assert(winner == 22);

    auto latch = xfrmLatchedHandlePartForTest(winner);
    assert(latch[0] == 3); // scale bank
    assert(latch[1] == 2); // local Z part consumed by ScaleTool.forceNextDragAxis
}

private int advisoryWinner(int defaultPart, int advisoryPart) {
    clearLatestHandleDebugTrace();
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(first, defaultPart);
    handles.add(later, advisoryPart);

    int winner = handles.test(123, 456, vp, AiInteractionPhase.mouseDown);
    assert(winner == advisoryPart);
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:" ~ defaultPart.to!string);
    assert(trace.appliedWinnerId == "handle:" ~ advisoryPart.to!string);
    return winner;
}

private XfrmTransformTool activeTransform(Mesh* mesh, GpuMesh* gpu,
                                          EditMode* editMode) {
    auto tool = new XfrmTransformTool(() => mesh, gpu, editMode);
    tool.handlePresentation = "compact";
    tool.activate();
    return tool;
}

private SDL_MouseButtonEvent leftDown() {
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_LEFT;
    e.x = 123;
    e.y = 456;
    return e;
}

unittest { // advisory shared winner reaches the wrapper-owned subtool dragAxis
    Mesh mesh = makeCube();
    mesh.resizeVertexSelection();
    mesh.selectVertex(6);
    GpuMesh gpu;
    EditMode editMode = EditMode.Vertices;
    VectorStack vts;

    auto e = leftDown();

    auto moveTool = activeTransform(&mesh, &gpu, &editMode);
    assert(moveTool.routeResolvedHandlePartForTest(e, vts, advisoryWinner(0, 2)));
    assert(moveTool.moveDragAxisPublic() == 2);
    assert(moveTool.rotateDragAxisPublic() == -1);
    assert(moveTool.scaleDragAxisPublic() == -1);

    auto rotateTool = activeTransform(&mesh, &gpu, &editMode);
    assert(rotateTool.routeResolvedHandlePartForTest(e, vts, advisoryWinner(0, 12)));
    assert(rotateTool.moveDragAxisPublic() == -1);
    assert(rotateTool.rotateDragAxisPublic() == 2);
    assert(rotateTool.scaleDragAxisPublic() == -1);

    auto scaleTool = activeTransform(&mesh, &gpu, &editMode);
    assert(scaleTool.routeResolvedHandlePartForTest(e, vts, advisoryWinner(0, 22)));
    assert(scaleTool.moveDragAxisPublic() == -1);
    assert(scaleTool.rotateDragAxisPublic() == -1);
    assert(scaleTool.scaleDragAxisPublic() == 2);
}

unittest { // compact scale-head fallback does not overwrite a resolved winner
    assert(xfrmCompactScaleHeadFallbackForTest(true, true, -1, 2) == 22);
    assert(xfrmCompactScaleHeadFallbackForTest(true, true, 12, 2) == 12);
    assert(xfrmCompactScaleHeadFallbackForTest(true, true, 22, 0) == 22);
    assert(xfrmCompactScaleHeadFallbackForTest(false, true, -1, 2) == -1);
    assert(xfrmCompactScaleHeadFallbackForTest(true, false, -1, 2) == -1);
    assert(xfrmCompactScaleHeadFallbackForTest(true, true, -1, -1) == -1);
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

unittest { // advisory choices are applied only to opted-in hover and mouse-down
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
    auto hoverTrace = latestHandleDebugTrace();
    assert(hoverTrace.defaultWinnerId == "handle:10");
    assert(hoverTrace.appliedWinnerId == "handle:10");
    assert(hoverTrace.advisor.candidateIndex == 1);

    handles.setAiHoverPreviewEnabled(true);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    assert(handles.test(123, 456, vp, AiInteractionPhase.hover) == 30);
    auto optedInHoverTrace = latestHandleDebugTrace();
    assert(optedInHoverTrace.defaultWinnerId == "handle:10");
    assert(optedInHoverTrace.appliedWinnerId == "handle:30");
    assert(optedInHoverTrace.advisor.candidateIndex == 1);

    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    assert(handles.test(123, 456, vp, AiInteractionPhase.dragUpdate) == 10);
    auto dragTrace = latestHandleDebugTrace();
    assert(dragTrace.defaultWinnerId == "handle:10");
    assert(dragTrace.appliedWinnerId == "handle:10");
    assert(dragTrace.advisor.candidateIndex == 1);
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
    assert(handles.secondaryDefault == -1);
    assert(handles.captured == 30);
    assert(first.getState() == HandleState.Normal);
    assert(later.getState() == HandleState.Rollover);
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
    resetSpyAdvisor();
    setHandleAiAdvisor(new SpyAdvisor());
    scope (exit) setHandleAiAdvisor(null);

    auto visible = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.begin();
    handles.add(visible, 2);
    handles.suppress();
    handles.hot = 9;
    handles.update(10, 20, vp);

    assert(handles.hot == -1);
    assert(handles.secondaryDefault == -1);
    assert(visible.hitCalls == 0);
    assert(spyCalls == 0);
    assert(handles.handleCandidates().length == 0);

    auto trace = latestHandleDebugTrace();
    assert(trace.candidates.length == 0);
    assert(trace.defaultWinnerIndex == -1);
    assert(trace.defaultWinnerId.length == 0);
    assert(trace.appliedWinnerIndex == -1);
    assert(trace.appliedWinnerId.length == 0);
}
