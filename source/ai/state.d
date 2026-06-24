module ai.state;

import popup_state : setStatePath;

/// Editor-level AI master switch. Default is off; publishing mirrors the
/// status-line checked-state registry.
class EditorAiState {
    private bool enabled_;

    this() {
        publish();
    }

    bool enabled() const {
        return enabled_;
    }

    void setEnabled(bool on) {
        enabled_ = on;
        publish();
    }

    bool toggle() {
        setEnabled(!enabled_);
        return enabled_;
    }

    void publish() const {
        setStatePath("ai/enabled", enabled_ ? "true" : "false");
    }
}
