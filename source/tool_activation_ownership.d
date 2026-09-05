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

/// The doors. One arm door, one drop door — and the drop door is the LEGACY
/// one for every transition, which task 4053 measured rather than inherited.
enum ActivationDoor : ubyte {
    /// `prepared_tool_transition.prepareArm` + `commitPreparedArm`. Owns the
    /// incoming candidate AND, on a switch, the outgoing tool's deactivation.
    preparedArm,
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

        // ---- EVERY drop is still on the legacy door, and this task MEASURED
        // ---- why rather than assuming it ----------------------------------
        // `explicitDrop` and `sameIdToggleDrop` were converted and reverted in
        // this same task. They hold the layer invariant, the switch already
        // runs every one of those doors with exactly that layer, and the
        // conversion still broke TWO driven cells, because the prepared
        // deactivation is not a faithful twin of `deactivate()`:
        //
        //   tests/test_item_drag_undo.d(288) — "a panel rotate edit must
        //   surface one arm plus exactly ONE edit … before=1 after=2". The
        //   prepared consolidate reads `history.currentRunId` off the LIVE
        //   history while it consolidates the DETACHED image the record went
        //   into, so it gathers the wrong run.
        //
        //   tests/test_tool_gesture_g2.d(388) — the mirror drop "ticked 0
        //   unbatched geometry commits" on the DOCUMENT mesh. The prepared
        //   door installs a stamped mesh IMAGE where `deactivate()` writes
        //   through the live mesh primitives, so the change-bus counter the
        //   measured delivery law is stated in never moves.
        //
        // Both divergences exist on the SWITCH transition today, where nothing
        // measures them. Tasks 4240 (cells first, then conversion) and 4243
        // (the two divergences themselves) own the rest.
        case ToolTransition.explicitDrop:
        case ToolTransition.sameIdToggleDrop:
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
        // The remaining six have no driven cell of their own at all, which is
        // a weaker position than the two above rather than a stronger one:
        // for them a door change would be green before, green after, and green
        // again when reverted. Cells first, then conversion: task 4240; the
        // two rows just above, which need the DOOR fixed: 4241 and 4243.
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
