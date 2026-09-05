// Frozen-fixture cell for WHICH action-centre modes each of the three
// action-centre menus offers, and how our own three lists compare (task 4320,
// 2026-09-05). The composition was read statically off the reference's shipped
// menu configuration and its shipped libraries' string tables; zero engine
// boots for the law.
//
// WHY IT EXISTS. `config/statusline.yaml` said, in a comment, that our Center
// and Axis submenus mirror the reference's. They were 7-entry lists over an
// 11- and a 13-entry table, and two implemented modes -- `parent` and `pivot`
// -- were missing from both with no recorded reason. Two edits were equally
// plausible on paper (restore them / codify their absence), so the rule was:
// change nothing until the reference is read. Read, it says:
//
//   * each of the two submenus is the COMPLETE set of modes its half of the
//     pipe has -- nine centre, eight axis -- with nothing curated away;
//   * both carry `parent` and `pivot`;
//   * our centre list was the measured list with exactly those two DELETED and
//     nothing else moved, which is what a list copied before those two modes
//     existed looks like. The dating agrees: our lists were authored five
//     weeks before the modes were added to our own table.
//
// So the two submenus here are a stale measurement, and this cell pins the
// corrected composition. The combined menu is a different story and is pinned
// as a DIVERGENCE, not parity -- see block D.
//
// WHAT EACH BLOCK IS. They are not the same kind of claim:
//
//   A  the fixture's own shape and arithmetic          -- must stay green;
//   B  every tag we list is a real wire tag of the stage that owns it, with a
//      population floor so an empty walk cannot pass  -- must stay green;
//   C  PARITY: the YAML's three lists are exactly what the fixture records,
//      in order                                        -- reddens on drift;
//   D  the fixture's own divergence blocks are RECOMPUTED here from its two
//      compositions, so a half-edit (fix `ours`, forget `reference_menus`)
//      cannot pass. Also the two deliberate divergences we are NOT closing.
//
// ORDERING IS LOAD-BEARING. A and B sit above C and D, so a mutation that
// reddens C still demonstrates the earlier halves ran and passed: everything
// above the first red line executed.
//
// MUTATIONS THAT REDDEN IT -- FOUR, one per block, all run and quoted in the
// task card with the assert MESSAGE as the identity (line numbers only point).
// Every block below is covered, which is the point: a pin nobody has seen fail
// is indistinguishable from an absent one.
//   * A -- the fixture: one consumer row's mode count raised by one with its
//     omits list untouched => reddens naming the consumer, both numbers and
//     the universe they must total. The row is not read, it is RECOMPUTED.
//   * B -- `config/statusline.yaml`: delete `pivot` from the `acenStageModes`
//     tag list, i.e. put the stale list back => reddens B's population floor
//     ("validated 28 tag(s) ... not the 29"), not C, because a list that
//     changed SIZE is caught by the floor first. The in-source pin in
//     `source/toolpipe/stages/actcenter.d` reddens in the same run, which is
//     how that pin was shown to be alive too. A stays green.
//   * C -- `config/statusline.yaml`: SWAP two tags in the axis submenu, same
//     count, different order => reddens C naming the provider, the entry
//     index, both tags and both full lists. A and B stay green above it, so
//     one run buys all three halves.
//   * D -- the fixture: record a missing mode in
//     `divergences.center_submenu.missing_from_ours` that the recompute does
//     not find => reddens, because that set is DERIVED here, never read.
module tests.unit.action_center_menu_composition_test;

import std.algorithm : canFind, map, sort, uniq;
import std.array     : array;
import std.conv      : to;
import std.file      : readText;
import std.format    : format;
import std.json;

import buttonset : ActionKind, Button, Group, loadStatusLine, PopupItem,
                   PopupItemKind;

private enum string kFixture    = "tests/fixtures/action_center_menu_composition.json";
private enum string kStatusLine = "config/statusline.yaml";

// The YAML provider key for each menu. These are OUR names for the three
// consumers; the fixture's keys are the neutral menu names.
private enum string kCombinedProvider = "acenModes";
private enum string kCenterProvider   = "acenStageModes";
private enum string kAxisProvider     = "axisModes";

private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded;
    if (!loaded) { cached = parseJSON(readText(kFixture)); loaded = true; }
    return cached;
}

private string[] jsonStrings(const JSONValue v)
{
    string[] out_;
    foreach (e; v.array) out_ ~= e.str;
    return out_;
}

/// Walk every popup in the statusline and collect `dynamicKind -> tags`.
/// Recursion covers submenus AND nested popup actions, because the two menus
/// under test live one level down from the button that opens them -- a walk
/// that only visited the top level would find one provider of three and the
/// per-list asserts would then be testing nothing.
private string[][string] liveProviders()
{
    string[][string] found;

    void walkItems(const(PopupItem)[] items)
    {
        foreach (ref it; items)
        {
            if (it.kind == PopupItemKind.dynamic && it.dynamicKind.length)
                found[it.dynamicKind] = it.dynamicTags.dup;
            if (it.subItems.length)
                walkItems(it.subItems);
            if (it.action.kind == ActionKind.popup && it.action.popupItems.length)
                walkItems(it.action.popupItems);
        }
    }

    foreach (ref g; loadStatusLine(kStatusLine))
        foreach (ref b; g.buttons)
        {
            if (b.action.kind == ActionKind.popup)
                walkItems(b.action.popupItems);
            foreach (ref v; [b.ctrl, b.alt, b.shift])
                if (v.present && v.action.kind == ActionKind.popup)
                    walkItems(v.action.popupItems);
        }
    return found;
}

/// `ours` tags mapped into the fixture's vocabulary. One of our axis tags names
/// the same basis the measured list labels differently; the map lives in the
/// fixture so the rename is data, not a rule buried in a reader.
private string[] aliased(const string[] tags, string menuKey)
{
    auto fx = fixture();
    string[] out_;
    const hasMap = "tag_aliases" in fx.object
                   && menuKey in fx.object["tag_aliases"].object;
    foreach (t; tags)
    {
        if (hasMap)
        {
            auto m = fx.object["tag_aliases"].object[menuKey].object;
            if (t in m) { out_ ~= m[t].str; continue; }
        }
        out_ ~= t;
    }
    return out_;
}

private string[] setMinus(const string[] a, const string[] b)
{
    string[] out_;
    foreach (x; a) if (!b.canFind(x)) out_ ~= x;
    return out_;
}

// ---------------------------------------------------------------------------
// A — the frozen composition's own shape. If these move, the fixture was
//     edited rather than the code, and every later block is judging a
//     different document.
unittest
{
    auto fx = fixture();
    auto ref_ = fx.object["reference_menus"];

    struct Row { string key; size_t n; }
    immutable Row[3] rows = [
        Row("combined_menu",  12),
        Row("center_submenu",  9),
        Row("axis_submenu",    8),
    ];
    size_t seen;
    foreach (r; rows)
    {
        auto blk = ref_.object[r.key];
        auto modes = jsonStrings(blk.object["modes"]);
        assert(modes.length == r.n,
               format("action_center_menu_composition: the measured %s carries "
                      ~ "%d mode(s), not the %d this cell was frozen with -- "
                      ~ "%s", r.key, modes.length, r.n, modes));
        assert(blk.object["count"].integer == cast(long) r.n,
               format("action_center_menu_composition: %s.count says %d but the "
                      ~ "list holds %d -- the fixture disagrees with itself",
                      r.key, blk.object["count"].integer, modes.length));
        // No duplicates: a menu that offered the same mode twice would make
        // every set comparison below quietly weaker.
        auto uniqued = modes.dup.sort.uniq.array;
        assert(uniqued.length == modes.length,
               format("action_center_menu_composition: %s repeats a mode -- %s",
                      r.key, modes));
        seen++;
    }
    assert(seen == 3, "action_center_menu_composition: block A checked "
                      ~ seen.to!string ~ " menus, not 3");

    // The load-bearing claim of the whole capture: each submenu is COMPLETE,
    // so "our 7 of 11" was never mirroring a curated list.
    foreach (k; ["center_submenu", "axis_submenu"])
        assert(ref_.object[k].object["is_complete_set"].boolean,
               format("action_center_menu_composition: %s is no longer marked "
                      ~ "complete -- that claim is why a shorter list of ours "
                      ~ "counts as staleness rather than a mirrored subset", k));

    // The reference is NOT uniform across its own consumers of the COMBINED
    // set; that is why "our list is a subset of the table" is by itself
    // evidence of nothing. Both numbers are RECOMPUTED, never read: each row's
    // modes + omits must total the universe, and the distinct-composition count
    // is derived from the rows. A row edited on one side alone reddens here.
    auto nu = fx.object["reference_is_not_uniform"];
    auto consumers = nu.object["consumers_of_the_combined_set"].array;
    const universe = cast(size_t) nu.object["universe"].integer;
    string[] sigs;
    size_t rowsChecked;
    foreach (c; consumers)
    {
        auto omits = jsonStrings(c.object["omits"]);
        const modes = cast(size_t) c.object["modes"].integer;
        assert(modes + omits.length == universe,
               format("action_center_menu_composition: consumer '%s' lists %d "
                      ~ "mode(s) and omits %d, which totals %d, not the %d-mode "
                      ~ "universe -- the row was edited on one side only",
                      c.object["consumer"].str, modes, omits.length,
                      modes + omits.length, universe));
        sigs ~= format("%d:%s", modes, omits.dup.sort.array);
        rowsChecked++;
    }
    assert(rowsChecked == 5,
           format("action_center_menu_composition: the consumer table holds %d "
                  ~ "row(s); it was frozen with the 5 shipped consumers of the "
                  ~ "combined set. A sixth needs its own argument, and an empty "
                  ~ "table would make the arithmetic above vacuous",
                  rowsChecked));
    const distinct = sigs.dup.sort.uniq.array.length;
    assert(distinct == cast(size_t) nu.object["distinct_compositions"].integer,
           format("action_center_menu_composition: the consumer table yields %d "
                  ~ "distinct compositions, the fixture claims %d",
                  distinct, nu.object["distinct_compositions"].integer));
}

// ---------------------------------------------------------------------------
// B — every tag in every one of our three lists is a real wire tag of the
//     stage that owns it. A typo would otherwise render as a silently missing
//     row rather than a failure. The counter is a POPULATION FLOOR: without it
//     a walk that found no providers would pass this block by iterating
//     nothing, which is the defect this repository pays for most.
unittest
{
    import toolpipe.stages.actcenter : ActionCenterStage;
    import toolpipe.stages.axis      : AxisStage;

    auto live = liveProviders();
    assert(kCombinedProvider in live && kCenterProvider in live
           && kAxisProvider in live,
           format("action_center_menu_composition: the statusline walk found "
                  ~ "providers %s -- all three of %s / %s / %s must be present "
                  ~ "or the per-list asserts below judge nothing",
                  live.keys, kCombinedProvider, kCenterProvider, kAxisProvider));

    size_t checked;
    void verify(string provider, const(char)[] which, bool axis)
    {
        foreach (tag; live[provider])
        {
            bool known;
            if (axis)
            {
                foreach (ref e; AxisStage.popupModeEntries())
                    if (e.wireTag == tag) { known = true; break; }
            }
            else
            {
                foreach (ref e; ActionCenterStage.popupModeEntries())
                    if (e.wireTag == tag) { known = true; break; }
            }
            assert(known,
                   format("action_center_menu_composition: %s lists tag '%s', "
                          ~ "which is not a wire tag of the %s stage -- that "
                          ~ "row would silently not render", provider, tag,
                          which));
            checked++;
        }
    }
    verify(kCombinedProvider, "action-centre", false);
    verify(kCenterProvider,   "action-centre", false);
    verify(kAxisProvider,     "axis",          true);

    assert(checked == 29,
           format("action_center_menu_composition: block B validated %d tag(s) "
                  ~ "across the three lists, not the 29 it was frozen with "
                  ~ "(11 combined + 9 centre + 9 axis). A count that moved "
                  ~ "means a list changed size; fix the fixture and this floor "
                  ~ "together, deliberately", checked));
}

// ---------------------------------------------------------------------------
// C — PARITY. The three lists in the YAML are exactly what the fixture records,
//     in order. This is the block a stale-list regression reddens.
unittest
{
    auto live = liveProviders();
    auto ours = fixture().object["ours"];

    struct Row { string provider; string key; }
    immutable Row[3] rows = [
        Row(kCombinedProvider, "combined_menu"),
        Row(kCenterProvider,   "center_submenu"),
        Row(kAxisProvider,     "axis_submenu"),
    ];
    foreach (r; rows)
    {
        auto want = jsonStrings(ours.object[r.key]);
        auto got  = live[r.provider];
        assert(got.length == want.length,
               format("action_center_menu_composition: %s (%s) has %d entr(ies) "
                      ~ "%s, the frozen composition has %d %s",
                      r.provider, r.key, got.length, got, want.length, want));
        foreach (i, w; want)
            assert(got[i] == w,
                   format("action_center_menu_composition: %s (%s) entry %d is "
                          ~ "'%s', the frozen composition says '%s' -- full "
                          ~ "list %s vs %s", r.provider, r.key, i, got[i], w,
                          got, want));
    }
}

// ---------------------------------------------------------------------------
// D — the fixture's divergence blocks, RECOMPUTED. A hand-written difference
//     list nobody recomputes is a claim that cannot come out differently; these
//     are derived from `reference_menus` and `ours` under `tag_aliases` and
//     compared against what the fixture recorded, so editing either half alone
//     reddens. Two of the three rows are DELIBERATE divergences we are not
//     closing, and they are pinned for the same reason a deliberate divergence
//     always is: without a pin it is indistinguishable from an accident.
unittest
{
    auto fx   = fixture();
    auto ref_ = fx.object["reference_menus"];
    auto ours = fx.object["ours"];
    auto div  = fx.object["divergences"];

    struct Row { string key; }
    immutable Row[3] rows = [
        Row("center_submenu"), Row("axis_submenu"), Row("combined_menu"),
    ];
    foreach (r; rows)
    {
        auto measured = jsonStrings(ref_.object[r.key].object["modes"]);
        auto mine     = aliased(jsonStrings(ours.object[r.key]), r.key);
        auto missing  = setMinus(measured, mine);
        auto extra    = setMinus(mine, measured);
        const ordered = (mine == measured);

        auto rec = div.object[r.key];
        assert(missing == jsonStrings(rec.object["missing_from_ours"]),
               format("action_center_menu_composition: %s -- computed "
                      ~ "missing_from_ours %s, fixture records %s. The fixture "
                      ~ "was edited on one side only", r.key, missing,
                      jsonStrings(rec.object["missing_from_ours"])));
        assert(extra == jsonStrings(rec.object["extra_in_ours"]),
               format("action_center_menu_composition: %s -- computed "
                      ~ "extra_in_ours %s, fixture records %s", r.key, extra,
                      jsonStrings(rec.object["extra_in_ours"])));
        assert(ordered == rec.object["order_matches"].boolean,
               format("action_center_menu_composition: %s -- our list %s %s "
                      ~ "the measured order %s, fixture says order_matches=%s",
                      r.key, mine, ordered ? "matches" : "does not match",
                      measured, rec.object["order_matches"].boolean));
    }

    // The two divergences left OPEN on purpose, named so a later change to
    // either is a deliberate act rather than a silent widening.
    assert(jsonStrings(div.object["axis_submenu"].object["extra_in_ours"])
           == ["workplane"],
           "action_center_menu_composition: the axis submenu's only recorded "
           ~ "extra was 'workplane' -- a mode we have and the reference does "
           ~ "not offer as a row. A second extra needs its own argument");
    assert(jsonStrings(div.object["combined_menu"].object["missing_from_ours"])
           == ["pivot_center_parent_axis"],
           "action_center_menu_composition: the combined menu's only recorded "
           ~ "gap was the pivot-centre/parent-axis COMBINATION, which our "
           ~ "two-enum model cannot express. A second gap is a different "
           ~ "finding");

    // The fourth consumer has no other side to compare against, and saying so
    // is the answer -- not an omission someone should later 'fix'.
    assert(fx.object["fourth_consumer"].object["answer"].str.length > 0,
           "action_center_menu_composition: the fourth-consumer answer went "
           ~ "missing; it records that the reference has NO mode dropdown, so "
           ~ "ours is a consequence of our model rather than a divergence");
}
