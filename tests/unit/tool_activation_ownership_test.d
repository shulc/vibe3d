// Ownership-table ledger for tool activation (task 4053).
//
// `source/tool_activation_ownership.d` is the ONE place that says which door
// owns which transition. This module is its ledger: it pins the partition so a
// row cannot be flipped in passing, and it pins the table against the TREE so
// a transition cannot be invented with no call site, or a call site added
// under a transition the table does not have.
//
// It is deliberately NOT the discriminating check for the cutover. A text
// census cannot tell a prepared drop from a legacy one — that needs a driven
// gesture, and task 4053 ran three of them. All three went red when the drop
// was routed through the prepared door, and all three named a different
// divergence: test_rs_insession_cancel.d:517 (a two-gesture run left THREE
// surviving entries, not one), test_item_drag_undo.d:288 (a panel rotate
// surfaced ONE row where the arm plus its edit are two) and
// test_tool_gesture_g2.d:388 (the mirror drop ticked ZERO unbatched geometry
// commits on the document mesh). What this module buys is that neither the
// table nor its call sites can drift silently.
//
// Every count below is a LEDGER: it may change, but only in the commit that
// argues for it. Converting a drop to the prepared door lowers `kLegacyDrops`
// in the same edit — and, on this evidence, only after that drop has a cell.
module tests.unit.tool_activation_ownership_test;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.conv : to;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : dirName;
import std.string : indexOf, lastIndexOf;
import std.traits : EnumMembers;

import tool_activation_ownership;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The recorded partition. Read at 2026-09-05: four arms through the prepared
// transaction, twelve drops through the legacy `Tool.deactivate()` — with the
// measured reason at each group's case label in the table.
private enum size_t kTransitions = 16;
private enum size_t kArms        = 4;
private enum size_t kLegacyDrops = 12;

private string[] productionSources() {
    string[] files;
    foreach (e; dirEntries(repoRoot ~ "/source", "*.d", SpanMode.depth))
        files ~= e.name;
    sort(files);
    return files;
}

unittest {
    // ---- population floor FIRST -------------------------------------------
    // Everything below iterates this enum; without the floor, a table that
    // lost half its members would still pass every loop under it.
    static assert(EnumMembers!ToolTransition.length == kTransitions);
    assert(EnumMembers!ToolTransition.length == kTransitions,
        format("task 4053: the transition set is a ledger — %s members, expected %s",
               EnumMembers!ToolTransition.length, kTransitions));

    // ---- every transition has an owner, and the partition is not vacuous --
    size_t arms, legacyDrops;
    foreach (t; EnumMembers!ToolTransition) {
        final switch (activationDoorFor(t)) {
            case ActivationDoor.preparedArm:      ++arms;        break;
            case ActivationDoor.legacyDeactivate: ++legacyDrops; break;
        }
    }
    assert(arms + legacyDrops == kTransitions);
    assert(arms == kArms,
        format("task 4053: arm rows moved: %s, recorded %s", arms, kArms));
    assert(legacyDrops == kLegacyDrops,
        format("task 4053: a drop changed door: %s legacy, recorded %s — "
               ~ "moving one is a deliberate edit here AND a driven cell; "
               ~ "tests/test_rs_insession_cancel.d, test_item_drag_undo.d and "
               ~ "test_tool_gesture_g2.d each caught the last attempt",
               legacyDrops, kLegacyDrops));
    // The rule the two counts exist to state: a table whose rows all carried
    // ONE door would satisfy "every transition has an owner" and mean nothing.
    // This one uses both doors it declares, which is what makes the partition
    // a fact rather than a formality.
    assert(arms > 0 && legacyDrops > 0,
        "task 4053: the partition must use every door it declares");

    // ---- isArm agrees with the table --------------------------------------
    foreach (t; EnumMembers!ToolTransition)
        assert(isArm(t) == (activationDoorFor(t) == ActivationDoor.preparedArm));
}

/// The recorded per-transition SITE census, read 2026-09-05 over `source/**`
/// with the table's own file excluded. It is a COUNT and not an existence
/// check, and that distinction is the whole row: twelve drops share ONE door,
/// so relabelling a site from one drop transition to another leaves both names
/// present in the tree and both doors unchanged. Task 4053's reviewer proved
/// exactly that against the earlier existence-only form — one of the two
/// `panelDrop` sites in source/ui/panels.d was relabelled and this module
/// stayed green.
///
/// A count moving is not automatically wrong; it is automatically an EDIT to
/// argue for. `why` says what the sites are, so the argument has something to
/// be checked against.
private struct SiteCount { string transition; size_t count; string why; }
private immutable SiteCount[] kSites = [
    SiteCount("commandArm",             1, "toolHost.activatePrepared"),
    SiteCount("interactiveArm",         1, "toolHost.activate"),
    SiteCount("replayArm",              1, "the lifecycle restore delegate inside armPreparedTool"),
    SiteCount("resetRearm",             1, "tool.reset rebuilding the same id"),
    SiteCount("explicitDrop",           2, "toolHost.deactivate and the Space key"),
    SiteCount("sameIdToggleDrop",       1, "activateToolById's already-active toggle"),
    SiteCount("replayDrop",             1, "the lifecycle re-drop delegate inside armPreparedTool"),
    SiteCount("selTypeFlipDrop",        2, "both B2 front-flip funnels"),
    SiteCount("activeLayerChangedDrop", 1, "the primary-change hook"),
    SiteCount("documentReplaceDisarm",  1, "the tool_disarm seam body"),
    SiteCount("sceneResetDrop",         3, "scene reset plus the raw mesh-load pair"),
    SiteCount("meshRebuildDrop",        7, "the seven geometry-rewriting commands in registration.d"),
    SiteCount("commandPreApplyDrop",    1, "the command funnel's pre-apply drop"),
    SiteCount("editCancelDrop",         1, "EditSession's cancel-then-drop"),
    SiteCount("panelDrop",              2, "the two UI panel actions that change the edit mode"),
    SiteCount("shutdownDrop",           2, "the scope(exit) comment and its door assert — the "
                                          ~ "one drop with no dropActiveTool call"),
];

unittest {
    // ---- the table against the TREE ---------------------------------------
    // A transition with no call site is a row nobody consults; a call site is
    // what makes a row load-bearing. `shutdownDrop` has no `dropActiveTool`
    // call — its site asserts the row instead, because the app's shutdown
    // `scope(exit)` is declared above the verb — so it is named there and
    // still found by this scan.
    auto files = productionSources();
    assert(files.length > 400,
        format("task 4053: source scan found only %s files — the census would "
               ~ "pass over nothing", files.length));

    // The ledger covers the enum EXACTLY, checked before it is used: a new
    // transition with no row would otherwise be counted by nobody, and a stale
    // row naming a deleted transition would be compared against nothing. Both
    // are the vacuous shape this module exists to refuse.
    assert(kSites.length == kTransitions,
        format("task 4053: the site ledger has %s rows for %s transitions",
               kSites.length, kTransitions));
    foreach (t; EnumMembers!ToolTransition) {
        bool listed;
        foreach (r; kSites) if (r.transition == t.to!string) listed = true;
        assert(listed, format("task 4053: transition %s has no site row — add "
                              ~ "one in the commit that adds the transition",
                              t.to!string));
    }

    size_t[string] named;
    size_t scanned;
    foreach (f; files) {
        if (f.canFind("tool_activation_ownership.d")) continue;  // the table itself
        auto text = readText(f);
        ++scanned;
        foreach (t; EnumMembers!ToolTransition) {
            const name = t.to!string;
            const needle = "ToolTransition." ~ name;
            ptrdiff_t at = 0;
            for (;;) {
                const i = text[at .. $].indexOf(needle);
                if (i < 0) break;
                at += i + needle.length;
                ++named[name];
            }
        }
    }
    assert(scanned == files.length - 1,
        format("task 4053: expected to skip exactly the table, scanned %s of %s",
               scanned, files.length));

    // Population floor FIRST: "every recorded count matched" is also true of a
    // scan that read nothing at all and matched sixteen zeroes.
    size_t found;
    foreach (_, c; named) found += c;
    assert(found > 0,
        "task 4053: the tree scan found no transition at all — every compare "
        ~ "below would then be true over nothing");

    // Every deviation in ONE message: a relabel moves TWO rows, and reporting
    // only the first would name the destination or the source depending on
    // enum order and hide the other half of the same edit.
    auto drift = appender!(string[]);
    foreach (r; kSites) {
        const got = (r.transition in named) is null ? 0 : named[r.transition];
        if (got != r.count)
            drift ~= format("%s: found %s, recorded %s (%s)",
                            r.transition, got, r.count, r.why);
    }
    assert(drift.data.length == 0,
        format("task 4053: production site counts moved: %s — a count is not an "
               ~ "existence check on purpose: relabelling a site from one drop "
               ~ "transition to another keeps both names in the tree and both "
               ~ "doors unchanged, and only the counts see it", drift.data));

    // LAST, and only meaningful once the rows agree with the tree: the ledger's
    // own sum against a literal. Bumping a row AND the tree together — the
    // reflex edit a regenerated table invites — leaves the compare above green
    // and moves this. Placed below so a genuine tree change reports itself
    // through the per-row message rather than through a bare total.
    size_t total;
    foreach (r; kSites) total += r.count;
    assert(total == 28,
        format("task 4053: the site ledger now sums to %s, recorded 28 — say in "
               ~ "the commit which sites arrived or left", total));
}

/// The balanced body a `{` opens, or `""` when the anchor is absent. FAIL
/// CLOSED is the point: a renamed door must make the census say "gone", never
/// make it silently scan an empty string and pass.
private string bodyAt(string text, ptrdiff_t open) {
    if (open < 0 || open >= text.length || text[open] != '{') return "";
    size_t depth;
    foreach (i; cast(size_t)open .. text.length) {
        if (text[i] == '{') ++depth;
        else if (text[i] == '}') {
            --depth;
            if (depth == 0) return text[cast(size_t)open + 1 .. i];
        }
    }
    return "";
}

private size_t occurrences(string hay, string needle) {
    size_t n; ptrdiff_t at = 0;
    for (;;) {
        const i = hay[at .. $].indexOf(needle);
        if (i < 0) return n;
        at += i + needle.length;
        ++n;
    }
}

unittest {
    // ---- the arm door is single, and this is the mechanical form of it ----
    // The card's ready criterion was `override void activate()` reaching zero.
    // That grep is the wrong instrument: those overrides are still reached by
    // internal tool composition (a transform wrapper activating its sub-tools)
    // and by tests. What the cutover actually claims is that no ACTIVATION
    // DOOR calls the legacy virtual pair — so pin the DOOR.
    //
    // AND PIN IT BY ITS BODY, not by a spelled receiver. The first form of
    // this block searched for the literal `activeTool.activate()`, which is
    // the NAME of the variable the door happens to use today; task 4053's
    // reviewer resurrected the legacy arm inside `dropActiveTool` under a
    // different receiver (`legacyDoor.activate()`) and this module stayed
    // green. Matching `.activate()` INSIDE the door bodies has no such hole:
    // whatever the call is spelled on, it is still a call.
    //
    // The three doors are all in app.d and all nested inside `main`, where
    // `activeTool` is a local — no other module can tear the tool down except
    // through one of them (`toolHost.deactivate` forwards to `dropActiveTool`).
    // That is what bounds this census to one file.
    const app = readText(repoRoot ~ "/source/app.d");

    const dropAnchor = app.indexOf("void dropActiveTool(ToolTransition why) {");
    const armAnchor  = app.indexOf("void armPreparedTool(ToolTransition why, string id,");
    const shutAssert = app.indexOf("assert(activationDoorFor(ToolTransition.shutdownDrop)");
    assert(dropAnchor >= 0 && armAnchor >= 0 && shutAssert >= 0,
        format("task 4053: a door anchor vanished (drop %s, arm %s, shutdown %s)"
               ~ " — rename the anchor here in the same commit, or this census "
               ~ "scans nothing and passes", dropAnchor, armAnchor, shutAssert));
    const shutAnchor = app[0 .. shutAssert].lastIndexOf("scope(exit) {");
    assert(shutAnchor >= 0, "task 4053: the shutdown scope(exit) door vanished");

    struct Door { string name; string body_; size_t activates; size_t deactivates; }
    const Door[] doors = [
        // The ARM door: the whole prepared transaction, no legacy call at all.
        Door("armPreparedTool",
             bodyAt(app, app.indexOf("{", armAnchor)), 0, 0),
        // The DROP door: exactly ONE `deactivate()`, in the `legacyDeactivate`
        // arm of the ownership `final switch`, and never an `activate()`.
        Door("dropActiveTool",
             bodyAt(app, app.indexOf("{", dropAnchor)), 0, 1),
        // The shutdown `scope(exit)`, which cannot call the verb above.
        Door("shutdown scope(exit)",
             bodyAt(app, app.indexOf("{", shutAnchor)), 0, 1),
    ];

    foreach (d; doors) {
        // Non-vacuity first: an empty body satisfies every count below.
        assert(d.body_.length > 100,
            format("task 4053: door body '%s' came back %s chars — the counts "
                   ~ "under it would be true of nothing", d.name, d.body_.length));
        assert(occurrences(d.body_, ".deactivate()") == d.deactivates,
            format("task 4053: door '%s' calls the legacy DROP %s times, "
                   ~ "recorded %s", d.name,
                   occurrences(d.body_, ".deactivate()"), d.deactivates));
        assert(occurrences(d.body_, ".activate()") == d.activates,
            format("task 4053: door '%s' calls the legacy ARM %s times, "
                   ~ "recorded %s — every arm goes through prepareArm since "
                   ~ "7844bfee, whatever the receiver is called", d.name,
                   occurrences(d.body_, ".activate()"), d.activates));
    }

    // And nothing in app.d outside those bodies: the two recorded
    // `.deactivate()` calls ARE the two doors, so a fourth door added beside
    // them — or a legacy arm added anywhere in the file — reddens here even if
    // it never touches a body above.
    assert(occurrences(app, ".activate()") == 0,
        format("task 4053: app.d calls the legacy ARM %s times; the arm door "
               ~ "is prepared-only", occurrences(app, ".activate()")));
    assert(occurrences(app, ".deactivate()") == 2,
        format("task 4053: app.d holds %s legacy DROP calls, recorded 2 — the "
               ~ "ownership switch's arm and the shutdown scope(exit)",
               occurrences(app, ".deactivate()")));
}
