module ai.copilot_gate;

// Task 0422: single reversible kill-switch for the AI Modeling Copilot
// (task 0402/0386's findings panel, ghost overlay, deterministic
// handle-advisor hook, and the ai.toggle / copilot.* / ui.copilotPanel
// commands). The owner is pausing the copilot to resume later; flipping
// this one enum back to `true` restores every gated site byte-for-byte —
// see doc/tasks/done/0422-disable-copilot-hooks.md for the full boundary.
//
// Deliberately does NOT gate anything on the ONNX experimentation path:
// ai.onnx_backend / ai.model_adapter / setHandleDecisionProvider (the
// model-backed handle-decision provider, task 0028) and the interaction-log
// capture / exploration plumbing (ai.interaction_log_writer, ai.exploration,
// setHandleApplyCaptureSink, setHandleExploreHook, task 0027/0033) all stay
// fully live regardless of this flag — the owner continues ONNX experiments
// independently of the copilot UI loop.
//
// A plain `enum bool` (not `version`) so it is usable both in `static if`
// (production wiring, fully dead-code-eliminates the copilot construction/
// registration when false) and as an ordinary runtime value (test files'
// early-skip guards). Lives in its own tiny module (rather than folding into
// `ai.state`, which holds the unrelated RUNTIME `EditorAiState.enabled`
// master switch) so it stays a zero-weight import for the three HTTP-driver
// copilot tests that need only the flag, not the rest of ai.state's surface.
enum bool kCopilotEnabled = false;
