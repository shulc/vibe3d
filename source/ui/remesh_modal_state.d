module ui.remesh_modal_state;

import remesh.remesh_job : MAX_REMESH_TARGET_QUADS,
    MIN_REMESH_TARGET_QUADS;

/// Per-application storage for the Quad Remesh popup handshake and parameters.
/// Task 6360 keeps registration, drawing, polling and diagnostics on this one
/// owner; its wiring is pinned by doc/w12_k_remesh_modal_state_plan.md.
final class RemeshModalState {
    bool open;
    bool pendingOpen;
    bool pendingClose;
    int targetQuads = 20_000;
    float adaptivity = 1.0f;
    float sharpEdge = 90.0f;
    string lastError;
    string lastSummary;

    void requestOpen() {
        // Task 6360 deliberately does NOT reset pendingClose here: this is a
        // recorded residual, not an omitted line. `mesh.remesh.start` can arm a
        // success-close while the modal is shut, and the next open then consumes
        // it on its first frame. Adding the reset changes that behaviour, so it
        // is pinned by a cell (remesh_modal_state_test.d, block 1).
        open = true;
        pendingOpen = true;
        lastError = null;
        lastSummary = null;
    }

    bool consumePendingOpen() {
        if (!pendingOpen) return false;
        pendingOpen = false;
        return true;
    }

    bool consumePendingClose() {
        if (!pendingClose) return false;
        pendingClose = false;
        return true;
    }

    void closeWindow() {
        open = false;
    }

    void noteSuccess(string summary) {
        lastError = null;
        lastSummary = summary;
        pendingClose = true;
    }

    void noteFailure(string message) {
        lastSummary = null;
        lastError = message;
    }

    void clampToBounds() {
        if (targetQuads < MIN_REMESH_TARGET_QUADS)
            targetQuads = MIN_REMESH_TARGET_QUADS;
        if (targetQuads > cast(int) MAX_REMESH_TARGET_QUADS)
            targetQuads = cast(int) MAX_REMESH_TARGET_QUADS;
        if (adaptivity < 0.0f) adaptivity = 0.0f;
        if (adaptivity > 10.0f) adaptivity = 10.0f;
        if (sharpEdge < 0.0f) sharpEdge = 0.0f;
        if (sharpEdge > 180.0f) sharpEdge = 180.0f;
    }
}
