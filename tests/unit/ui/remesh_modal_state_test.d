module tests.unit.ui.remesh_modal_state_test;

import remesh.remesh_job : MAX_REMESH_TARGET_QUADS,
    MIN_REMESH_TARGET_QUADS;
import ui.remesh_modal_state : RemeshModalState;

unittest { // all eight fields belong to one state instance
    auto state = new RemeshModalState();
    auto other = new RemeshModalState();

    assert(state.targetQuads == 20_000
        && state.adaptivity == 1.0f
        && state.sharpEdge == 90.0f,
        "RemeshModalState defaults changed");
    assert(!state.open && !state.pendingOpen && !state.pendingClose
        && state.lastError is null && state.lastSummary is null,
        "fresh RemeshModalState is not empty");

    state.lastError = "old error";
    state.lastSummary = "old summary";
    state.requestOpen();
    assert(state.open && state.pendingOpen,
        "requestOpen did not arm the popup handshake");
    assert(state.lastError is null && state.lastSummary is null,
        "requestOpen did not clear stale result text");
    assert(state.consumePendingOpen(),
        "the first pending-open handoff did not fire");
    assert(!state.consumePendingOpen(),
        "pending-open handoff fired more than once");

    state.noteSuccess("complete");
    assert(state.lastSummary == "complete" && state.lastError is null
        && state.pendingClose,
        "noteSuccess did not publish the summary and close request");
    assert(state.consumePendingClose(),
        "the first pending-close handoff did not fire");
    assert(!state.consumePendingClose(),
        "pending-close handoff fired more than once");

    state.noteFailure("failed");
    assert(state.lastError == "failed" && state.lastSummary is null,
        "noteFailure did not replace the prior result text");
    assert(!state.pendingClose,
        "noteFailure armed a success-only close request");

    state.pendingOpen = true;
    state.lastError = "keep error";
    state.closeWindow();
    assert(!state.open,
        "closeWindow left the modal owner open");
    assert(state.pendingOpen && state.lastError == "keep error",
        "closeWindow changed state outside the open latch");

    assert(!other.open && !other.pendingOpen && !other.pendingClose
        && other.targetQuads == 20_000
        && other.adaptivity == 1.0f && other.sharpEdge == 90.0f
        && other.lastError is null && other.lastSummary is null,
        "two RemeshModalState instances share storage");

    state.targetQuads = MAX_REMESH_TARGET_QUADS + 1;
    state.adaptivity = 11.0f;
    state.sharpEdge = 181.0f;
    state.clampToBounds();
    assert(state.targetQuads == MAX_REMESH_TARGET_QUADS
        && state.adaptivity == 10.0f && state.sharpEdge == 180.0f,
        "upper remesh modal bounds were not enforced");

    state.targetQuads = MIN_REMESH_TARGET_QUADS - 1;
    state.adaptivity = -1.0f;
    state.sharpEdge = -1.0f;
    state.clampToBounds();
    assert(state.targetQuads == MIN_REMESH_TARGET_QUADS
        && state.adaptivity == 0.0f && state.sharpEdge == 0.0f,
        "lower remesh modal bounds were not enforced");

    state.targetQuads = 20_000;
    state.adaptivity = 1.0f;
    state.sharpEdge = 90.0f;
    state.clampToBounds();
    assert(state.targetQuads == 20_000
        && state.adaptivity == 1.0f && state.sharpEdge == 90.0f,
        "in-range remesh modal values were changed");
}
