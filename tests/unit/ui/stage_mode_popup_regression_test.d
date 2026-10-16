module tests.unit.ui.stage_mode_popup_regression_test;

import std.format : format;
import vibe3d.editing.params.params : valueForWireTag;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter : ActionCenterStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis : AxisStage;






// Task 0678 A4 introduced status-line coverage after actr.pivot / actr.parent
// were registered but absent from the UI. Task 0713 replaces the duplicated
// YAML labels/actions/checks with dynamic providers and re-aims that coverage
// at the providers' concrete output. The YAML retains only its curation input:
// the ordered tag list.
//
// The pin enters through `dynamicModePopupItems` — the SAME kind-string
// dispatcher the panel renderer, the startup id-validator and
// tests/test_button_actions.d go through — never through a leaf builder.
// Calling the builder directly leaves the mapping untested: renaming the
// dispatcher's case labels made both menus render "(no modes configured)" and
// the startup validator validate zero ids, with the module lane still green.
//
// The Center submenu stays a CURATED SUBSET — 7 of the 11 panel modes — and
// WHICH modes it offers is a UI decision that is deliberately NOT pinned.
// What is pinned is that each tag it names resolves to exactly one generated
// row whose label, action and checked state come from the table, so the seven
// hand-copied labels that used to sit there cannot come back.
unittest {
    import std.file : exists;
    import vibe3d.ui.editor.buttonset : loadStatusLine, ActionKind, PopupItem, PopupItemKind;
    import vibe3d.ui.editor.ui.mode_popup : dynamicModePopupItems;

    enum yamlPath = "config/statusline.yaml";
    // A hard fail beats a silent skip for a gate test — but say what to DO
    // about it (task 0685 T8). The gate (`dub test --config=tests`) already
    // runs from the package root; a bare "config/ missing" only ever confused
    // someone running the unittest binary from elsewhere.
    assert(exists(yamlPath),
           "cannot read " ~ yamlPath ~ " — run this test from the package "
           ~ "root (the directory holding dub.json), e.g. "
           ~ "`dub test --config=tests`");

    // Task 0713 (and task 4320, which MEASURED what the curation should be):
    // the YAML now carries only the tag order. The provider
    // emits label, action and checked-state from modeEntries; pin its OUTPUT,
    // not the representation that asks for it.
    PopupItem[] rows;            // top-level combined presets  (acenModes)
    string[]    configuredTags;
    PopupItem[] centerRows;      // Center submenu, ACEN stage only
    string[]    centerTags;
    bool sawPopup  = false;
    bool sawCenter = false;
    foreach (g; loadStatusLine(yamlPath)) {
        foreach (ref b; g.buttons) {
            if (b.action.kind != ActionKind.popup || b.label != "Action Center")
                continue;
            sawPopup = true;
            foreach (ref pi; b.action.popupItems) {
                if (pi.kind == PopupItemKind.dynamic &&
                    pi.dynamicKind == "acenModes") {
                    configuredTags ~= pi.dynamicTags;
                    rows ~= dynamicModePopupItems(pi);
                } else if (pi.kind == PopupItemKind.submenu
                           && pi.label == "Center") {
                    sawCenter = true;
                    foreach (ref si; pi.subItems) {
                        if (si.kind != PopupItemKind.dynamic
                            || si.dynamicKind != "acenStageModes") continue;
                        centerTags ~= si.dynamicTags;
                        centerRows ~= dynamicModePopupItems(si);
                    }
                }
            }
        }
    }
    assert(sawPopup, "statusline must carry an 'Action Center' popup");
    assert(sawCenter, "the Action Center popup must carry a 'Center' submenu");

    string firstMissing = "<none>";
    foreach (tag; configuredTags) {
        bool found;
        foreach (ref row; rows)
            if (row.action.id == "actr." ~ tag) found = true;
        if (!found) { firstMissing = tag; break; }
    }
    assert(rows.length == 11,
           format("Action Center mode provider emitted %d rows; expected 11; "
                  ~ "first missing mode '%s'", rows.length, firstMissing));

    foreach (e; ActionCenterStage.popupModeEntries()) {
        PopupItem* row;
        size_t copies;
        foreach (ref candidate; rows) {
            if (candidate.action.id != "actr." ~ e.wireTag) continue;
            row = &candidate;
            ++copies;
        }
        assert(copies == 1,
               "panel mode '" ~ e.wireTag ~ "' has no actr." ~ e.wireTag
               ~ " unique provider row in the statusline Action Center popup");
        assert(row.label == e.userLabel,
               "statusline actr." ~ e.wireTag ~ " is labelled '" ~ row.label
               ~ "' but the panel calls the same mode '" ~ e.userLabel
               ~ "' — one UI, two names for one mode");
        assert(row.action.kind == ActionKind.command,
               "statusline actr." ~ e.wireTag ~ " is not a command row");
        assert(row.checked.path == "actionCenter/mode",
               "an Action Center row must tick off actionCenter/mode");
        assert(row.checked.equals_ == e.wireTag,
               "statusline actr." ~ e.wireTag ~ " ticks on state '"
               ~ row.checked.equals_ ~ "' — it would never tick, or would tick "
               ~ "for a different mode");
    }

    // --- Center submenu: same table, ACEN stage only -------------------------
    // Population floor first. Without it every per-row assert below is
    // vacuously true over an empty list — a renamed provider key, or a tag the
    // table does not carry, would report nothing at all.
    string firstCenterMissing = "<none>";
    foreach (tag; centerTags) {
        bool found;
        foreach (ref row; centerRows)
            if (row.checked.equals_ == tag) found = true;
        if (!found) { firstCenterMissing = tag; break; }
    }
    // NINE because the measured centre submenu is the COMPLETE set of nine
    // centre modes, `parent` and `pivot` included; this list was seven only
    // because it was copied five weeks before those two modes existed here.
    // Frozen in tests/fixtures/action_center_menu_composition.json.
    assert(centerRows.length == 9,
           format("Center submenu provider emitted %d rows; expected 9; "
                  ~ "first missing mode '%s'", centerRows.length,
                  firstCenterMissing));
    assert(centerTags.length == centerRows.length,
           "the Center submenu must emit one row for every configured tag");

    foreach (i, ref row; centerRows) {
        immutable tag = centerTags[i];
        string want;
        foreach (e; ActionCenterStage.popupModeEntries())
            if (e.wireTag == tag) want = e.userLabel;
        assert(want.length > 0,
               "Center submenu offers '" ~ tag ~ "', which is not a panel mode");
        assert(row.label == want,
               "Center submenu row '" ~ row.label ~ "' and the stage table's "
               ~ "label '" ~ want ~ "' name the same mode two different ways");
        assert(row.action.kind == ActionKind.script
               && row.action.scriptLines.length == 1
               && row.action.scriptLines[0] ==
                      "tool.pipe.attr actionCenter mode " ~ tag,
               "Center submenu row for '" ~ tag ~ "' emits the wrong action — "
               ~ "it must drive the action-centre stage alone, leaving axis "
               ~ "untouched");
        assert(row.checked.path == "actionCenter/mode",
               "a Center submenu row must tick off actionCenter/mode");
        assert(row.checked.equals_ == tag,
               "Center submenu row for '" ~ tag ~ "' ticks on '"
               ~ row.checked.equals_ ~ "' — it would never tick, or would tick "
               ~ "for a different mode");
    }
}

// Task 0705 (audit 4, A5 second half), narrowed by task 0713 and CORRECTED by
// task 4320: this submenu is a SUBSET of the 13-mode table, but "curated" was
// the wrong word for why — 4320 measured the reference's own axis submenu and
// found the COMPLETE set of its eight modes, `parent` and `pivot` included,
// which ours was missing because the list predated them here. It is 9 of 13
// now, and the three differences that remain are recorded and argued in
// tests/fixtures/action_center_menu_composition.json rather than left to the
// word "curated". The YAML carries only the ordered tags; the provider derives
// label, action and checked state from this table.
//
// Pinned as a subset, not as equality: which modes the submenu offers is a
// UI curation decision and is expected to be smaller than the table. What may
// NOT drift is that every row it does offer names a real mode, agrees with the
// table on that mode's human label, and ticks on the state the stage actually
// publishes.
unittest {
    import std.file  : exists;
    import vibe3d.ui.editor.buttonset : loadStatusLine, ActionKind, PopupItem, PopupItemKind;
    // Through the kind-string dispatcher, not the leaf builder: the dispatcher
    // is what the renderer, the startup id-validator and test_button_actions
    // call, and renaming its case labels emptied every menu while a
    // builder-facing pin stayed green.
    import vibe3d.ui.editor.ui.mode_popup : dynamicModePopupItems;

    enum yamlPath = "config/statusline.yaml";
    assert(exists(yamlPath),
           "cannot read " ~ yamlPath ~ " — run this test from the package "
           ~ "root (the directory holding dub.json), e.g. "
           ~ "`dub test --config=tests`");

    PopupItem[] rows;
    string[] configuredTags;
    foreach (g; loadStatusLine(yamlPath)) {
        foreach (ref b; g.buttons) {
            if (b.action.kind != ActionKind.popup) continue;
            foreach (ref pi; b.action.popupItems) {
                if (pi.kind != PopupItemKind.submenu || pi.label != "Axis") continue;
                foreach (ref si; pi.subItems) {
                    if (si.kind != PopupItemKind.dynamic ||
                        si.dynamicKind != "axisModes") continue;
                    configuredTags ~= si.dynamicTags;
                    rows ~= dynamicModePopupItems(si);
                }
            }
        }
    }

    string firstMissing = configuredTags.length > 0 ? configuredTags[0] : "<none>";
    foreach (tag; configuredTags) {
        bool found;
        foreach (ref row; rows)
            if (row.checked.equals_ == tag) found = true;
        if (!found) { firstMissing = tag; break; }
    }
    // NINE because the measured axis submenu carries `parent` and `pivot`,
    // which this list was missing. Two of ours have no measured row
    // (`workplane`, and `world` is the row the measurement labels Origin) and
    // stay on purpose -- tests/fixtures/action_center_menu_composition.json
    // records both, and dropping either is a product decision, not this pin's.
    assert(rows.length == 9,
        format("Axis mode provider emitted %d rows; expected 9; first missing "
               ~ "configured mode '%s'", rows.length, firstMissing));
    assert(configuredTags.length == rows.length,
        "Axis mode provider must emit one row for every configured tag");

    foreach (i, ref row; rows) {
        immutable tag = configuredTags[i];
        int v;
        assert(valueForWireTag(AxisStage.popupModeEntries(), tag, v),
            "statusline Axis submenu offers '" ~ tag
            ~ "', which AxisStage.applySetAttr would refuse");
        string want;
        foreach (e; AxisStage.popupModeEntries())
            if (e.wireTag == tag) want = e.userLabel;
        assert(row.label == want,
            "statusline Axis row '" ~ row.label ~ "' and the stage table's "
            ~ "label '" ~ want ~ "' name the same mode two different ways");
        assert(row.action.kind == ActionKind.script &&
               row.action.scriptLines.length == 1 &&
               row.action.scriptLines[0] == "tool.pipe.attr axis mode " ~ tag,
            "statusline Axis row for '" ~ tag ~ "' emits the wrong action");
        assert(row.checked.path == "axis/mode",
            "an Axis row must tick off the axis/mode state path");
        assert(row.checked.equals_ == tag,
            "statusline Axis row for '" ~ tag ~ "' ticks on '"
            ~ row.checked.equals_ ~ "' — it would never tick, or would tick "
            ~ "for a different mode");
    }
}
