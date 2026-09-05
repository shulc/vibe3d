module tool_activation_ownership;

// TASK 4053 — the single ownership table for tool-activation transitions.
//
// INVARIANT: every way the active tool can change is a member of
// `ToolTransition`, and `activationDoorFor` names the ONE door that owns it.
// Production dispatches on this function; it does not re-derive the answer at
// the call site. A new way to change the active tool is a new enum member, and
// the `final switch` below refuses to compile until that member is given an
// owner — which is the whole point of the table.
//
// WHAT THIS REPLACES, and why a grep could not have found it. Two doors were
// live at the same time: the prepared transaction (`prepared_tool_transition`)
// and the legacy virtual pair `Tool.activate()` / `Tool.deactivate()`. They
// were never DUPLICATED on one transition — they were PARTITIONED by it, so no
// transition ever ran both and no double-fire was observable. Since commit
// 7844bfee every ARM is prepared and `Tool.activate()` became unreachable from
// production; the drops stayed legacy. The discriminating check for this file
// is therefore a driven TRANSITION, never the presence or absence of a method.
//
// The legacy rows below are not leftovers: each is a drop whose measured state
// breaks an invariant the prepared deactivation doors are written against, and
// each carries its reason. Evidence, and what each still needs:
// doc/tasks/done/4053-prepared-one-activation-door.md.

/// Every transition that can change the active tool, named after the gesture
/// or seam that drives it rather than after the function it lands in — several
/// share one funnel, and the funnel is exactly what cannot tell them apart.
enum ToolTransition : ubyte {
    /// `tool.set <id> on` through the command bridge.
    commandArm,
    /// `activateToolById` — a tool button, a shortcut, the tool panel.
    interactiveArm,
    /// A lifecycle undo/redo restoring a previously armed tool.
    replayArm,
    /// `tool.reset` (Ctrl+D) rebuilding the same id at declared defaults.
    resetRearm,
    /// `tool.set <id> off`, and Space with a tool armed — the user drops the
    /// tool outright, with the document and the primary layer untouched.
    explicitDrop,
    /// `activateToolById` with the id that is already active (the toggle).
    sameIdToggleDrop,
    /// A lifecycle redo re-dropping a tool it had restored.
    replayDrop,
    /// A selection-type switch that FLIPS the front type (B2 tool-drop).
    selTypeFlipDrop,
    /// The active-layer / primary change hook.
    activeLayerChangedDrop,
    /// The document-replace disarm seam (`tool_disarm`).
    documentReplaceDisarm,
    /// A scene reset / raw mesh load dropping whatever was armed.
    sceneResetDrop,
    /// A mesh-rebuilding command (subdivide, triple, remesh, …) dropping the
    /// tool before it rewrites the geometry under it.
    meshRebuildDrop,
    /// The command funnel's pre-apply drop for commands that can move or
    /// remove the tool's own edit target (`dropsActiveToolBeforeApply`).
    commandPreApplyDrop,
    /// `EditSession`'s cancel-then-drop during interactive undo.
    editCancelDrop,
    /// A UI panel dropping the tool because the action it ran changes the
    /// edit mode.
    panelDrop,
    /// The `scope(exit)` drop at shutdown.
    shutdownDrop,
}

/// The doors. There is exactly one arm door and, after this task, two drop
/// doors — one converted, one not yet.
enum ActivationDoor : ubyte {
    /// `prepared_tool_transition.prepareArm` + `commitPreparedArm`. Owns the
    /// incoming candidate AND, on a switch, the outgoing tool's deactivation.
    preparedArm,
    /// `prepared_tool_transition.prepareDrop` + `commitPreparedDrop`. The same
    /// `PreparedToolDoorClient.prepareDoorDeactivate` the switch uses, with no
    /// incoming candidate.
    preparedDrop,
    /// `Tool.deactivate()` called live, then `destroy()`.
    legacyDeactivate,
}

/// The table. One `final switch`, no default, so an unowned transition is a
/// compile error rather than a silent fall-through to the old door.
ActivationDoor activationDoorFor(ToolTransition t) pure nothrow @safe @nogc {
    final switch (t) {
        // ---- the arm door -------------------------------------------------
        // `resetRearm` re-arms the SAME id, so it is a switch A->A and enters
        // the same transaction; it is listed separately because it is the one
        // arm that is not a user asking for a different tool.
        case ToolTransition.commandArm:
        case ToolTransition.interactiveArm:
        case ToolTransition.replayArm:
        case ToolTransition.resetRearm:
            return ActivationDoor.preparedArm;

        // ---- converted drops ----------------------------------------------
        // Both hold the invariant every prepared deactivation door is written
        // against: `document.primary` is non-null and its mesh is the mesh the
        // tool was armed on. A tool SWITCH already runs every one of those
        // doors with exactly that layer, so these two transitions add no door
        // that was not already production.
        case ToolTransition.explicitDrop:
        case ToolTransition.sameIdToggleDrop:
            return ActivationDoor.preparedDrop;

        // ---- drops still on the legacy door, each for a measured reason ----
        // `activeLayerChangedDrop` fires exactly WHEN the primary moved or went
        // away, so `document.primary` is either null or a different layer than
        // the tool's mesh — and the prepared doors guard on
        // `layer !is null && &layer.meshRef() is mesh` (mirror.d, box.d,
        // pen.d, …), which would REFUSE and throw out of a drop that must not
        // fail.
        case ToolTransition.activeLayerChangedDrop:
        // `shutdownDrop` runs from a `scope(exit)` declared ABOVE the
        // PipeGizmoHost's own, so the GL owner the prepared resource effects
        // are validated against is already torn down when it fires.
        case ToolTransition.shutdownDrop:
        // The remaining three run under a suspended / replacing history or a
        // half-replaced document, and none of them has a driven cell yet.
        // Converting one without its own cell would be a change nothing sees.
        case ToolTransition.replayDrop:
        case ToolTransition.selTypeFlipDrop:
        case ToolTransition.documentReplaceDisarm:
        case ToolTransition.sceneResetDrop:
        case ToolTransition.meshRebuildDrop:
        case ToolTransition.commandPreApplyDrop:
        case ToolTransition.editCancelDrop:
        case ToolTransition.panelDrop:
            return ActivationDoor.legacyDeactivate;
    }
}

/// True when the transition publishes a NEW active tool. Kept beside the table
/// so "is this an arm?" has one answer too.
bool isArm(ToolTransition t) pure nothrow @safe @nogc {
    return activationDoorFor(t) == ActivationDoor.preparedArm;
}
