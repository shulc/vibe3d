// Pure tests for read-only Smart Tool / Mode / Intent candidates.

import ai.debug_trace : clearLatestAiDebugTraces,
    latestModeToolContextDebugTrace;
import ai.interaction : AiCandidateKind, AiInteractionContext, AiIntent;
import ai.mode_candidates : collectContextCandidates, collectModeCandidates,
    collectModeToolContextCandidates, collectToolCandidates,
    publishModeToolContextCandidates;

void main() {}

unittest { // current edit mode becomes the deterministic mode default
    AiInteractionContext context;
    context.editModeId = "vertices";

    auto candidates = collectModeCandidates(context);
    assert(candidates.length == 1);
    assert(candidates[0].id == "mode:vertex");
    assert(candidates[0].kind == AiCandidateKind.mode);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
}

unittest { // alternative edit modes are stable, ordered, and not winners
    AiInteractionContext context;
    context.editModeId = "edges";

    auto candidates = collectModeCandidates(
        context, ["vertices", "polygons", "items", "edges"]);
    assert(candidates.length == 4);
    assert(candidates[0].id == "mode:edge");
    assert(candidates[0].isDefaultWinner);
    assert(candidates[1].id == "mode:vertex");
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[2].id == "mode:polygon");
    assert(candidates[3].id == "mode:item");
}

unittest { // active tool becomes a context-kind tool default
    AiInteractionContext context;
    context.activeToolId = "xfrm.transform";

    auto candidates = collectToolCandidates(context);
    assert(candidates.length == 1);
    assert(candidates[0].id == "tool:xfrm.transform");
    assert(candidates[0].kind == AiCandidateKind.context);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].isDefaultWinner);
}

unittest { // tool alternatives are explicit inputs, not registry lookups
    AiInteractionContext context;
    context.activeToolId = "move";

    auto candidates = collectToolCandidates(
        context, ["rotate", "scale", "tool:move", ""]);
    assert(candidates.length == 3);
    assert(candidates[0].id == "tool:move");
    assert(candidates[0].isDefaultWinner);
    assert(candidates[1].id == "tool:rotate");
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[2].id == "tool:scale");
}

unittest { // context candidates use the existing context kind
    auto candidates = collectContextCandidates(
        "selection", ["action-center", "context:falloff"]);
    assert(candidates.length == 3);
    assert(candidates[0].id == "context:selection");
    assert(candidates[0].kind == AiCandidateKind.context);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[1].id == "context:action-center");
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[2].id == "context:falloff");
}

unittest { // empty active tool yields no default but keeps safe alternatives
    AiInteractionContext context;

    auto none = collectToolCandidates(context);
    assert(none.length == 0);

    auto alternatives = collectToolCandidates(context, ["move", "rotate"]);
    assert(alternatives.length == 2);
    assert(alternatives[0].id == "tool:move");
    assert(alternatives[0].priorityFromCurrentRules == 0.0f);
    assert(!alternatives[0].isDefaultWinner);
    assert(alternatives[1].id == "tool:rotate");
    assert(!alternatives[1].isDefaultWinner);
}

unittest { // combined collection preserves mode/tool/context order
    AiInteractionContext context;
    context.editModeId = "polygons";
    context.activeToolId = "bevel";

    auto candidates = collectModeToolContextCandidates(
        context, ["vertices"], ["move"], "selection", ["snap"]);
    assert(candidates.length == 6);
    assert(candidates[0].id == "mode:polygon");
    assert(candidates[0].kind == AiCandidateKind.mode);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[1].id == "mode:vertex");
    assert(candidates[2].id == "tool:bevel");
    assert(candidates[2].kind == AiCandidateKind.context);
    assert(candidates[2].isDefaultWinner);
    assert(candidates[3].id == "tool:move");
    assert(candidates[4].id == "context:selection");
    assert(candidates[4].isDefaultWinner);
    assert(candidates[5].id == "context:snap");
}

unittest { // debug readback seam exposes ids/order/default/applied
    clearLatestAiDebugTraces();

    AiInteractionContext context;
    context.editModeId = "vertices";
    context.activeToolId = "move";

    publishModeToolContextCandidates(context, ["edges"], ["rotate"],
                                     "selection", ["snap"]);
    auto trace = latestModeToolContextDebugTrace();
    assert(trace.candidates.length == 6);
    assert(trace.candidates[0].id == "mode:vertex");
    assert(trace.candidates[1].id == "mode:edge");
    assert(trace.candidates[2].id == "tool:move");
    assert(trace.candidates[3].id == "tool:rotate");
    assert(trace.candidates[4].id == "context:selection");
    assert(trace.candidates[5].id == "context:snap");
    assert(trace.defaultWinnerId == "mode:vertex");
    assert(trace.appliedWinnerId == "mode:vertex");

    clearLatestAiDebugTraces();
    assert(latestModeToolContextDebugTrace().candidates.length == 0);
}

unittest { // production neutrality: helper is separate from app.d wiring
    version (Vibe3dAiModeCandidatesAppDWired) {
        static assert(false, "mode/tool/context candidates must stay read-only");
    }
}
