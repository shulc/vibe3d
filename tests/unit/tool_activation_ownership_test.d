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
// gesture. The one on record is tests/test_rs_insession_cancel.d:517, which
// went red the moment `explicitDrop` moved to the prepared door and named the
// exact divergence ("drop consolidates the two-gesture run into ONE surviving
// entry; floor=1 now=3"). What this module buys is that neither the table nor
// its call sites can drift silently.
//
// Every count below is a LEDGER: it may change, but only in the commit that
// argues for it. Converting a drop to the prepared door lowers
// `kLegacyDrops` and raises `kPreparedDrops` in the same edit.
module tests.unit.tool_activation_ownership_test;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.conv : to;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : dirName;
import std.string : indexOf;
import std.traits : EnumMembers;

import tool_activation_ownership;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The recorded partition. Read at 2026-09-05: four arms, two converted drops,
// ten drops still on the legacy door — each of the ten with its measured
// reason at its case label in the table.
private enum size_t kTransitions   = 16;
private enum size_t kArms          = 4;
private enum size_t kPreparedDrops = 2;
private enum size_t kLegacyDrops   = 10;

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
    size_t arms, preparedDrops, legacyDrops;
    foreach (t; EnumMembers!ToolTransition) {
        final switch (activationDoorFor(t)) {
            case ActivationDoor.preparedArm:      ++arms;          break;
            case ActivationDoor.preparedDrop:     ++preparedDrops; break;
            case ActivationDoor.legacyDeactivate: ++legacyDrops;   break;
        }
    }
    assert(arms + preparedDrops + legacyDrops == kTransitions);
    assert(arms == kArms,
        format("task 4053: arm rows moved: %s, recorded %s", arms, kArms));
    assert(preparedDrops == kPreparedDrops,
        format("task 4053: a drop changed door: %s prepared, recorded %s — "
               ~ "converting one is a deliberate edit here AND a driven cell — "
               ~ "tests/test_rs_insession_cancel.d is the one that caught the "
               ~ "last conversion",
               preparedDrops, kPreparedDrops));
    assert(legacyDrops == kLegacyDrops,
        format("task 4053: a drop changed door: %s legacy, recorded %s",
               legacyDrops, kLegacyDrops));
    // The rule the two counts above exist to state: a table whose rows all
    // carry one door would satisfy "every transition has an owner" and mean
    // nothing.
    assert(preparedDrops > 0 && legacyDrops > 0 && arms > 0,
        "task 4053: the partition must use every door it declares");

    // ---- isArm agrees with the table --------------------------------------
    foreach (t; EnumMembers!ToolTransition)
        assert(isArm(t) == (activationDoorFor(t) == ActivationDoor.preparedArm));
}

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

    auto missing = appender!(string[]);
    foreach (t; EnumMembers!ToolTransition)
        if ((t.to!string in named) is null)
            missing ~= t.to!string;
    assert(missing.data.length == 0,
        format("task 4053: transition(s) with no production site: %s — a row "
               ~ "nobody names is a row nobody consults", missing.data));
}

unittest {
    // ---- the arm door is single, and this is the mechanical form of it ----
    // The card's ready criterion was `override void activate()` reaching zero.
    // That grep is the wrong instrument: those overrides are still reached by
    // internal tool composition (a transform wrapper activating its sub-tools)
    // and by tests. What the cutover actually claims is that no ACTIVATION
    // DOOR calls the legacy virtual pair — so pin the door, not the method.
    auto files = productionSources();
    auto offenders = appender!(string[]);
    foreach (f; files) {
        auto text = readText(f);
        foreach (needle; ["activeTool.activate()", "activeTool.deactivate()"]) {
            ptrdiff_t at = 0;
            for (;;) {
                const i = text[at .. $].indexOf(needle);
                if (i < 0) break;
                at += i + needle.length;
                offenders ~= f ~ " :: " ~ needle;
            }
        }
    }
    // Two survive, both on the legacy-door side of the table and both
    // enumerated: the `final switch`'s own `legacyDeactivate` arm in
    // `dropActiveTool`, and the shutdown `scope(exit)` that cannot call it.
    // `activeTool.activate()` must have ZERO — the arm door is prepared-only.
    assert(offenders.data.length == 2,
        format("task 4053: live legacy-door calls changed: %s", offenders.data));
    foreach (o; offenders.data)
        assert(o.canFind("activeTool.deactivate()"),
            format("task 4053: a production door calls the legacy ARM: %s — "
                   ~ "every arm goes through prepareArm since 7844bfee", o));
}
