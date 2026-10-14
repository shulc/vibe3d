module ui.mode_popup;

import buttonset : ActionKind, Checked, PopupItem, PopupItemKind;
import params : IntEnumEntry;

// Which action a generated mode row fires. This used to be an empty-string
// sentinel on the command prefix, which left one of the two argument fields
// dead in each arm — a script row carried an unread `commandPrefix` and a
// command row carried an unread `stageName`. Name the choice, and let the two
// arms share one token whose meaning the enum fixes.
private enum ModeRowAction {
    // `action.id = <token> ~ wireTag` — a registered command that owns the
    // whole preset (e.g. `actr.element` sets the centre AND the axis).
    command,
    // `tool.pipe.attr <token> mode <wireTag>` — one pipe stage only, leaving
    // its sibling stages untouched.
    stageScript,
}

private PopupItem[] buildModeItems(const(IntEnumEntry)[] entries,
                                   const(string)[] tags,
                                   string statePath,
                                   ModeRowAction actionKind,
                                   string actionToken)
{
    PopupItem[] rows;
    foreach (tag; tags) {
        foreach (ref entry; entries) {
            if (entry.wireTag != tag) continue;

            PopupItem row;
            row.kind = PopupItemKind.action;
            row.label = entry.userLabel;
            row.checked = Checked(true, statePath, entry.wireTag);
            final switch (actionKind) {
                case ModeRowAction.command:
                    row.action.kind = ActionKind.command;
                    row.action.id = actionToken ~ entry.wireTag;
                    break;
                case ModeRowAction.stageScript:
                    row.action.kind = ActionKind.script;
                    row.action.scriptLines = [
                        "tool.pipe.attr " ~ actionToken ~ " mode " ~ entry.wireTag
                    ];
                    break;
            }
            rows ~= row;
            break;
        }
    }
    return rows;
}

/// Build the combined action-center preset rows requested by a popup's
/// curated tag list. Unknown tags produce no row, so the provider-output
/// population pins fail instead of rendering a plausible but inert action.
PopupItem[] actionCenterModeItems(const(IntEnumEntry)[] entries,
                                  const(string)[] tags)
{
    return buildModeItems(entries, tags, "actionCenter/mode",
                          ModeRowAction.command, "actr.");
}

/// Build the granular Center-submenu rows: the same table and the same
/// labels as the combined presets above, but each row drives ONLY the
/// action-centre stage and leaves the axis stage where it was.
PopupItem[] actionCenterStageModeItems(const(IntEnumEntry)[] entries,
                                       const(string)[] tags)
{
    return buildModeItems(entries, tags, "actionCenter/mode",
                          ModeRowAction.stageScript, "actionCenter");
}

/// Build the axis-stage-only rows requested by a popup's curated tag list.
PopupItem[] axisModeItems(const(IntEnumEntry)[] entries,
                          const(string)[] tags)
{
    return buildModeItems(entries, tags, "axis/mode",
                          ModeRowAction.stageScript, "axis");
}

/// Expand the table-backed dynamic providers shared by popup rendering,
/// dynamic button labels, startup action validation and focused tests.
///
/// This dispatcher is the ONLY route production takes — the panel renderer,
/// the startup id-validator and the action-resolver test all arrive here — so
/// the pins enter through it too, rather than calling a leaf builder that a
/// renamed case label would leave green.
PopupItem[] dynamicModePopupItems(ref const(PopupItem) provider)
{
    import toolpipe.stages.actcenter : ActionCenterStage;
    import toolpipe.stages.axis : AxisStage;

    switch (provider.dynamicKind) {
        case "acenModes":
            return actionCenterModeItems(
                ActionCenterStage.popupModeEntries(), provider.dynamicTags);
        case "acenStageModes":
            return actionCenterStageModeItems(
                ActionCenterStage.popupModeEntries(), provider.dynamicTags);
        case "axisModes":
            return axisModeItems(
                AxisStage.popupModeEntries(), provider.dynamicTags);
        default:
            return null;
    }
}

private string checkedModeLabel(const(IntEnumEntry)[] entries,
                                const(string)[] tags,
                                string statePath)
{
    import popup_state : getStatePath;

    immutable activeTag = getStatePath(statePath);
    foreach (tag; tags) {
        if (tag != activeTag) continue;
        foreach (ref entry; entries)
            if (entry.wireTag == tag) return entry.userLabel;
        break;
    }
    return "";
}

/// Resolve a dynamic mode provider's face label without constructing its full
/// popup rows on every closed-statusline frame.
string dynamicModeCheckedLabel(ref const(PopupItem) provider)
{
    import toolpipe.stages.actcenter : ActionCenterStage;
    import toolpipe.stages.axis : AxisStage;

    switch (provider.dynamicKind) {
        case "acenModes":
        case "acenStageModes":
            return checkedModeLabel(ActionCenterStage.popupModeEntries(),
                                    provider.dynamicTags,
                                    "actionCenter/mode");
        case "axisModes":
            return checkedModeLabel(AxisStage.popupModeEntries(),
                                    provider.dynamicTags, "axis/mode");
        default:
            return "";
    }
}
