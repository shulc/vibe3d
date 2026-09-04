module ui.mode_popup;

import buttonset : ActionKind, Checked, PopupItem, PopupItemKind;
import params : IntEnumEntry;

private PopupItem[] buildModeItems(const(IntEnumEntry)[] entries,
                                   const(string)[] tags,
                                   string statePath,
                                   string commandPrefix,
                                   string stageName)
{
    PopupItem[] rows;
    foreach (tag; tags) {
        foreach (ref entry; entries) {
            if (entry.wireTag != tag) continue;

            PopupItem row;
            row.kind = PopupItemKind.action;
            row.label = entry.userLabel;
            row.checked = Checked(true, statePath, entry.wireTag);
            if (commandPrefix.length > 0) {
                row.action.kind = ActionKind.command;
                row.action.id = commandPrefix ~ entry.wireTag;
            } else {
                row.action.kind = ActionKind.script;
                row.action.scriptLines = [
                    "tool.pipe.attr " ~ stageName ~ " mode " ~ entry.wireTag
                ];
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
    return buildModeItems(entries, tags, "actionCenter/mode", "actr.", "");
}

/// Build the axis-stage-only rows requested by a popup's curated tag list.
PopupItem[] axisModeItems(const(IntEnumEntry)[] entries,
                          const(string)[] tags)
{
    return buildModeItems(entries, tags, "axis/mode", "", "axis");
}

/// Expand the table-backed dynamic providers shared by popup rendering,
/// dynamic button labels, startup action validation and focused tests.
PopupItem[] dynamicModePopupItems(ref const(PopupItem) provider)
{
    import toolpipe.stages.actcenter : ActionCenterStage;
    import toolpipe.stages.axis : AxisStage;

    switch (provider.dynamicKind) {
        case "acenModes":
            return actionCenterModeItems(
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
