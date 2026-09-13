module ui.guard_modal_state;

/// Per-application storage for the quit-guard and command-notice popup
/// handshakes.  Application policy stays in GuardedActionController; this
/// owner only carries ImGui state across frames.
final class GuardModalState {
    bool discardConfirmOpen;
    bool discardConfirmPending;
    string noticeText;
    bool noticeOpen;
    bool noticePending;

    void requestDiscardOpen(bool testMode, bool awaitingAnswer) {
        if (testMode || !awaitingAnswer || discardConfirmOpen) return;
        discardConfirmOpen = true;
        discardConfirmPending = true;
    }

    bool consumeDiscardOpen() {
        if (!discardConfirmPending) return false;
        discardConfirmPending = false;
        return true;
    }

    void closeDiscard() {
        discardConfirmOpen = false;
        discardConfirmPending = false;
    }

    void publishNotice(string text) {
        noticeText = text;
        noticeOpen = true;
        noticePending = true;
    }

    bool consumeNoticeOpen() {
        if (!noticePending) return false;
        noticePending = false;
        return true;
    }

    void closeNotice() {
        noticeOpen = false;
        noticePending = false;
    }
}
