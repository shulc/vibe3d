module ai.element_candidates;

import std.conv : to;

import ai.debug_trace : publishElementDebugTrace;
import ai.interaction : AiCandidate, AiCandidateKind, AiElementCandidateKind,
    AiIntent;

private AiCandidate makeElementCandidate(AiElementCandidateKind kind,
                                         int elementId,
                                         int mx,
                                         int my,
                                         size_t priority,
                                         bool isDefault) {
    AiCandidate c;
    final switch (kind) {
        case AiElementCandidateKind.vertex:
            c.id = "element:vertex:" ~ elementId.to!string;
            break;
        case AiElementCandidateKind.edge:
            c.id = "element:edge:" ~ elementId.to!string;
            break;
        case AiElementCandidateKind.face:
            c.id = "element:face:" ~ elementId.to!string;
            break;
        case AiElementCandidateKind.background:
            c.id = "element:background";
            break;
        case AiElementCandidateKind.none:
            c.id = "element:none";
            break;
    }
    c.kind = AiCandidateKind.element;
    c.elementKind = kind;
    c.intent = kind == AiElementCandidateKind.background
        ? AiIntent.keepDefault : AiIntent.hoverElement;
    c.screenDist = kind == AiElementCandidateKind.background
        ? float.infinity : 0.0f;
    c.priorityFromCurrentRules = cast(float)priority;
    c.isDefaultWinner = isDefault;
    c.hasScreenPosition = true;
    c.screenPosition = [cast(float)mx, cast(float)my];
    return c;
}

AiCandidate[] collectElementCandidates(int mx,
                                       int my,
                                       int vertex,
                                       int edge,
                                       int face) {
    AiCandidate[] candidates;

    if (vertex >= 0)
        candidates ~= makeElementCandidate(AiElementCandidateKind.vertex,
                                           vertex, mx, my,
                                           candidates.length,
                                           candidates.length == 0);
    if (edge >= 0)
        candidates ~= makeElementCandidate(AiElementCandidateKind.edge,
                                           edge, mx, my,
                                           candidates.length,
                                           candidates.length == 0);
    if (face >= 0)
        candidates ~= makeElementCandidate(AiElementCandidateKind.face,
                                           face, mx, my,
                                           candidates.length,
                                           candidates.length == 0);

    if (candidates.length == 0)
        candidates ~= makeElementCandidate(AiElementCandidateKind.background,
                                           -1, mx, my, 0, true);
    return candidates;
}

void publishElementCandidates(int mx,
                              int my,
                              int vertex,
                              int edge,
                              int face) {
    publishElementDebugTrace(collectElementCandidates(mx, my, vertex, edge, face));
}

unittest {
    auto candidates = collectElementCandidates(12, 34, 5, 7, 9);
    assert(candidates.length == 3);
    assert(candidates[0].id == "element:vertex:5");
    assert(candidates[0].kind == AiCandidateKind.element);
    assert(candidates[0].elementKind == AiElementCandidateKind.vertex);
    assert(candidates[0].intent == AiIntent.hoverElement);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].hasScreenPosition);
    assert(candidates[0].screenPosition == [12.0f, 34.0f]);

    assert(candidates[1].id == "element:edge:7");
    assert(candidates[1].elementKind == AiElementCandidateKind.edge);
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);

    assert(candidates[2].id == "element:face:9");
    assert(candidates[2].elementKind == AiElementCandidateKind.face);
    assert(candidates[2].priorityFromCurrentRules == 2.0f);
    assert(!candidates[2].isDefaultWinner);
}

unittest {
    auto candidates = collectElementCandidates(1, 2, -1, -1, -1);
    assert(candidates.length == 1);
    assert(candidates[0].id == "element:background");
    assert(candidates[0].kind == AiCandidateKind.element);
    assert(candidates[0].elementKind == AiElementCandidateKind.background);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].screenDist == float.infinity);
}
