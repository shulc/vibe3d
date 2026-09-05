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

    // RAW on purpose — this scan counts MENTIONS, and `shutdownDrop`'s two
    // hits are a comment and an assert. Masking here would drop the comment
    // half and break the very row that records the drop with no call. The
    // CALL counts further down are the masked ones; the difference between
    // the two scans is the point of having both.
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

    // And the total DECOMPOSES, which is what keeps 28 from being a number
    // with no structure:
    //     22  dropActiveTool(ToolTransition.…) calls
    //   +  4  armPreparedTool(ToolTransition.…) calls
    //   +  2  shutdownDrop mentions — a comment and the door assert, the one
    //         drop with no call at all, because its scope(exit) is declared
    //         above the verb
    //   = 28
    // This is not a restatement of the scan above: that one counts MENTIONS,
    // so a transition named only in a comment would satisfy it. These two
    // count CALLS, and the arithmetic closing is what says the 26 wired rows
    // are wired rather than merely written down.
    //
    // WHICH IS WHY THEY SCAN THE MASKED TEXT, and the scan above does not.
    // The first form of this block read the raw file, so "counts CALLS" was
    // false as written: task 4053's re-reviewer commented out a real call
    // (`// dropActiveTool(ToolTransition.panelDrop);`) and the count did not
    // move, because a commented-out call is still the same bytes. Masking is
    // what makes the sentence above true. It is deliberately NOT applied to
    // the MENTION scan, whose `shutdownDrop` row is TWO hits of which one IS a
    // comment — masking there would break the row it is meant to count.
    //
    // Read 2026-09-05: masking moves no number on this tree — 22 and 4 both
    // ways — so it is a change of INSTRUMENT, not of ledger.
    size_t dropCalls, armCalls;
    foreach (f; files) {
        if (f.canFind("tool_activation_ownership.d")) continue;
        auto text = maskComments(readText(f));
        dropCalls += occurrences(text, "dropActiveTool(ToolTransition.");
        armCalls  += occurrences(text, "armPreparedTool(ToolTransition.");
    }
    assert(dropCalls == 22 && armCalls == 4,
        format("task 4053: wired call sites moved — %s drops and %s arms, "
               ~ "recorded 22 and 4. With the 2 shutdownDrop mentions (no call) "
               ~ "these must sum to the ledger's %s.",
               dropCalls, armCalls, total));
    assert(dropCalls + armCalls + 2 == total,
        format("task 4053: %s calls + 2 shutdownDrop mentions != ledger total "
               ~ "%s — a row was recorded that nothing calls, or a call exists "
               ~ "under a transition the ledger does not count",
               dropCalls + armCalls, total));
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

/// `src` with every COMMENT byte replaced by a space and every string / char
/// literal left intact, so a call that has been commented out stops counting
/// as a call. Newlines survive and nothing is inserted or removed, so the
/// result is byte-for-byte the same LENGTH as its input and every offset —
/// anchor indices, `bodyAt` brace matching — means the same thing in both.
/// That is the property the callers below rely on, and the reason masking
/// could be introduced without re-deriving a single recorded number.
///
/// It is one left-to-right pass rather than a regex because the two hazards
/// are mutual: a `//` inside a string must NOT open a comment, and a stray
/// quote or backtick inside a comment must NOT open a string. app.d alone
/// holds 871 backticks, nearly all of them Ddoc prose, so a masker that
/// looked for strings first would mis-lex the file wholesale. Consuming
/// whichever construct starts first settles both at once.
///
/// MEASURED LIMIT, and both halves of it belong here. The wysiwyg arm scans
/// to the next plain `"`, so a DELIMITED `q"(…)"` or a heredoc whose BODY
/// holds a `"` closes early and that literal's tail is then lexed as code.
/// The error direction is UNDER-masking, which can only make a count too high
/// — it cannot hide a call. And the corpus this masker is pointed at has ZERO
/// such sites: `source/**.d` holds no wysiwyg literal at all (2026-09-05 —
/// `grep -rhoE '(^|[^A-Za-z0-9_])q"([({\[<]|[A-Za-z_])' source/` counts 0,
/// against 92 under `tests/`, which this census does not read).
private string maskComments(string src) {
    auto masked = src.dup;
    void blank(size_t from, size_t to) {
        foreach (k; from .. to) if (masked[k] != '\n') masked[k] = ' ';
    }
    static bool identChar(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_';
    }
    size_t i;
    while (i < src.length) {
        const c = src[i];
        if (c == '/' && i + 1 < src.length) {
            if (src[i + 1] == '/') {                      // line comment
                size_t j = i;
                while (j < src.length && src[j] != '\n') ++j;
                blank(i, j); i = j; continue;
            }
            if (src[i + 1] == '*') {                      // block comment
                size_t j = i + 2;
                while (j + 1 < src.length && !(src[j] == '*' && src[j + 1] == '/')) ++j;
                j = (j + 1 < src.length) ? j + 2 : src.length;
                blank(i, j); i = j; continue;
            }
            if (src[i + 1] == '+') {                      // nesting comment
                size_t depth = 1, j = i + 2;
                while (j + 1 < src.length && depth > 0) {
                    if (src[j] == '/' && src[j + 1] == '+')      { ++depth; j += 2; }
                    else if (src[j] == '+' && src[j + 1] == '/') { --depth; j += 2; }
                    else ++j;
                }
                if (depth > 0) j = src.length;
                blank(i, j); i = j; continue;
            }
            ++i; continue;
        }
        // Wysiwyg `r"…"` / `q"…"`: no escape processing inside. Guarded on the
        // preceding byte so the `r` ending an identifier cannot open one.
        //
        // NO CELL COVERS THIS ARM, and that is deliberate rather than a hole:
        // delete the arm, or just its guard, and the masked `source/` corpus
        // is byte-identical — 514 files, 14 586 202 bytes, md5 7FF8C82F… all
        // three ways (2026-09-05). source/ has no wysiwyg literal to lex: the
        // five `q"` byte pairs are all `"seq"` inside another literal or a
        // `///` comment, and the four `r"` are the tail of an ordinary
        // string. So there is nothing here for a cell to discriminate, and
        // the green is honest. The rig that says so IS discriminating: on a
        // synthetic `seq"a\"b"` the guarded and unguarded builds differ
        // (md5 A174F5BB vs 945FD296). Task 4244 carries the numbers.
        if ((c == 'r' || c == 'q') && i + 1 < src.length && src[i + 1] == '"'
            && !(i > 0 && identChar(src[i - 1]))) {
            size_t j = i + 2;
            while (j < src.length && src[j] != '"') ++j;
            i = (j < src.length) ? j + 1 : src.length; continue;
        }
        if (c == '`') {                                   // backtick wysiwyg
            size_t j = i + 1;
            while (j < src.length && src[j] != '`') ++j;
            i = (j < src.length) ? j + 1 : src.length; continue;
        }
        if (c == '"' || c == '\'') {                      // escaped literals
            size_t j = i + 1;
            while (j < src.length) {
                if (src[j] == '\\') { j += 2; continue; }
                if (src[j] == c) { ++j; break; }
                ++j;
            }
            i = j; continue;
        }
        ++i;
    }
    return cast(string)masked;
}

unittest {
    // The masker's own floor, because everything it is used for below is a
    // count that reads as "unchanged" when the instrument is broken. Each
    // cell is one of the two hazards named at the declaration.
    assert(maskComments("a(); // b();").length == "a(); // b();".length,
        "task 4053: the masker must preserve offsets");
    assert(maskComments("a(); // b();").canFind("a();"));
    assert(!maskComments("a(); // b();").canFind("b();"),
        "task 4053: a line comment must not survive masking");
    assert(!maskComments("a(); /* b();\n c(); */ d();").canFind("b();"));
    assert(!maskComments("a(); /* b();\n c(); */ d();").canFind("c();"),
        "task 4053: a block comment must be masked across its newline");
    assert(maskComments("a(); /* b();\n c(); */ d();").canFind("d();"),
        "task 4053: code after a block comment must survive");
    assert(!maskComments("/+ a(); /+ b(); +/ c(); +/ d();").canFind("c();"),
        "task 4053: a nesting comment must not close on its inner +/");
    assert(maskComments("/+ a(); /+ b(); +/ c(); +/ d();").canFind("d();"));
    // The mutual hazard: a `//` inside a literal is not a comment, and a
    // quote inside a comment does not open one.
    assert(maskComments(`s = "// b();"; c();`).canFind("c();"),
        "task 4053: a // inside a string must not eat the rest of the line");
    assert(maskComments(`s = "// b();"; c();`).canFind("b();"),
        "task 4053: string contents are left intact on purpose");
    assert(maskComments("// it's fine\nc();").canFind("c();"),
        "task 4053: an apostrophe in a comment must not open a char literal");
    assert(maskComments("// a `b\nc();").canFind("c();"),
        "task 4053: a backtick in a comment must not open a wysiwyg string");

    // ---- and the SAME two hazards in CODE position ------------------------
    // The four cells above put the apostrophe and the backtick inside a
    // COMMENT, so the comment arm consumes them before the arm under test is
    // ever reached: a second, unnamed guard refuses first, and neither cell
    // can fail for its own arm. Measured 2026-09-05 — with the char arm
    // deleted, and again with the backtick arm deleted, this module still
    // said `1 modules passed unittests`, while the masked source/ corpus
    // differed in 20 414 and 5 929 of its 14 586 202 bytes respectively —
    // the LENGTH is invariant by construction, so the mutant is caught by a
    // byte compare, never by a size. The four cells below put the
    // literal where the arm actually has to lex it, and each pair goes red
    // exactly when its arm goes. Task 4053 §Мутация quotes the two reds
    // verbatim.
    //
    // The two `.length` asserts are BY-CONSTRUCTION guards, not the green
    // half of a one-run pair: `maskComments` rewrites a `.dup` in place, so
    // `.length == src.length` holds under every mutation of its body and
    // cannot distinguish anything. The half that really rides above the red
    // is the CHAR pair below, which IS arm-sensitive and passed in the same
    // run that reddened the backtick assert.
    enum charInCode = `char q = '"'; k(); // z();`;
    assert(maskComments(charInCode).length == charInCode.length,
        "task 4053: masking a char literal must preserve offsets");
    assert(!maskComments(charInCode).canFind("z();"),
        "task 4053: a quote inside a CHAR literal must not open a string. "
      ~ `Delete the char arm — the "|| c == '\''" half of the escaped-`
      ~ "literal test — and that quote opens a literal which never closes, "
      ~ "so every comment after it in the file stops being masked and every "
      ~ "commented-out call from there on counts as a call.");
    enum tickInCode = "s = `// b();`; c();";
    assert(maskComments(tickInCode).length == tickInCode.length,
        "task 4053: masking a backtick string must preserve offsets");
    assert(maskComments(tickInCode).canFind("c();"),
        "task 4053: a // inside a BACKTICK string must not eat the rest of "
      ~ "the line. Delete the backtick arm and the comment arm opens at that "
      ~ "//, masking the code that follows the literal. app.d alone holds "
      ~ "871 backticks, so this arm is load-bearing on the real corpus.");
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
    //
    // AND IT READS THE MASKED FILE. The raw form of this block was green over
    // a drop door whose own `activeTool.deactivate();` had been commented out
    // — the reviewer's cell R9, and the worst of the two, because seeing
    // exactly that is why the block exists. Masking is applied to the WHOLE
    // file, once, so the anchors, the brace matching inside `bodyAt` and the
    // outside-the-doors counts all read code rather than prose; the masker
    // preserves offsets, so this changed no recorded number (verified
    // 2026-09-05, every count and every anchor offset identical either way).
    const app = maskComments(readText(repoRoot ~ "/source/app.d"));

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
