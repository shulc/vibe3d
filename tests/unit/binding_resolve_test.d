// Module unittests for the scoped-binding resolver (task 1810).
//
// This is the heart of the feature and the only place its behaviour is
// separately observable. Everywhere else "which binding won" shows up only as
// its effect, and a chord that resolved to the WRONG row looks exactly like a
// chord that resolved to NOTHING — in both cases the thing you wanted did not
// happen. So the specificity law gets pinned here, on the pure function,
// rather than inferred from an end-to-end outcome.
module tests.unit.binding_resolve_test;

import std.file    : write, remove, tempDir;
import std.format  : format;
import std.process : thisProcessID;

import shortcuts;

private Binding mk(string canon, string zone, string mode, string whenTool,
                   string id, bool scoped_ = true, int rank = 0) {
    Binding b;
    b.canon = canon; b.zone = zone; b.mode = mode; b.whenTool = whenTool;
    b.id = id; b.scoped_ = scoped_; b.legacyRank = rank;
    b.kind = BindingKind.command;
    return b;
}

private string writeTmpYaml(string tag, string body_) {
    string p = format("%s/vibe3d_bind_%s_%d.yaml", tempDir(), tag, thisProcessID());
    write(p, body_);
    return p;
}

unittest {  // the weights are powers of two, so a tie means the SAME slot set
    assert(bindingWeight(mk("k", "",   "",       "",     "a")) == 0);
    assert(bindingWeight(mk("k", "",   "vertex", "",     "a")) == 1);
    assert(bindingWeight(mk("k", "",   "",       "move", "a")) == 2);
    assert(bindingWeight(mk("k", "z",  "",       "",     "a")) == 4);
    assert(bindingWeight(mk("k", "z",  "vertex", "move", "a")) == 7);

    // The property the whole design rests on: zone alone outranks mode AND
    // tool together, so a zone-scoped row can never tie with a
    // mode-plus-tool-scoped one. Ties along different axes — the ambiguity the
    // reference's own shipped map contains — are impossible by construction.
    assert(bindingWeight(mk("k", "z", "",       "",     "a"))
         > bindingWeight(mk("k", "",  "vertex", "move", "b")));
}

unittest {  // a more specific row beats the global one, in both directions
    auto bs = [
        mk("ctrl+space", "",          "", "", "pie.global"),
        mk("ctrl+space", "layerList", "", "", "pie.layers"),
    ];
    assert(bs[resolveBinding(bs, "ctrl+space", "layerList",  "vertex", "")].id
           == "pie.layers");
    assert(bs[resolveBinding(bs, "ctrl+space", "viewport3d", "vertex", "")].id
           == "pie.global", "outside the scoped zone the global row must win");
    // Order in the array must not decide it — reverse and re-ask.
    auto rev = [bs[1], bs[0]];
    assert(rev[resolveBinding(rev, "ctrl+space", "layerList", "vertex", "")].id
           == "pie.layers");
    assert(rev[resolveBinding(rev, "ctrl+space", "sidePanel", "vertex", "")].id
           == "pie.global");
}

unittest {  // an unmatched chord, and a chord matched by nothing in this context
    auto bs = [ mk("ctrl+space", "layerList", "", "", "pie.layers") ];
    assert(resolveBinding(bs, "ctrl+space", "viewport3d", "vertex", "") == -1,
           "a zone-only binding must NOT fall back to matching everywhere — "
           ~ "that is the difference between scoped and global");
    assert(resolveBinding(bs, "alt+q", "layerList", "vertex", "") == -1);
}

unittest {  // every slot filters, and an empty slot is a wildcard
    auto bs = [
        mk("b", "",           "",        "",         "bevel"),
        mk("b", "viewport3d", "",        "carve.*", "brushes"),
        mk("b", "",           "polygon", "",         "polyThing"),
    ];
    // The shape this exists for: one letter is "take the bevel tool"
    // everywhere, except while a carving tool is armed in the 3D viewport,
    // where the same letter opens that tool's own menu instead.
    assert(bs[resolveBinding(bs, "b", "viewport3d", "vertex", "carve.deep")].id
           == "brushes");
    assert(bs[resolveBinding(bs, "b", "viewport3d", "vertex", "move")].id
           == "bevel", "wrong tool ⇒ the scoped row must not match");
    assert(bs[resolveBinding(bs, "b", "sidePanel",  "vertex", "carve.deep")].id
           == "bevel", "wrong zone ⇒ the scoped row must not match");
    assert(bs[resolveBinding(bs, "b", "sidePanel",  "polygon", "")].id
           == "polyThing", "mode alone still beats the global row");
}

unittest {  // the trailing-* family match, and what it must NOT swallow
    assert(slotMatches("carve.*", "carve.deep"));
    assert(slotMatches("carve.*", "carve."));         // the prefix itself
    assert(!slotMatches("carve.*", "carv"));          // shorter than the prefix
    assert(!slotMatches("carve.*", "paint.deep"));
    assert(slotMatches("", "anything"), "empty pattern is the wildcard");
    assert(slotMatches("move", "move"));
    assert(!slotMatches("move", "moveX"), "an exact pattern is not a prefix one");
}

unittest {  // equal weight ⇒ identical slots ⇒ the documented tie-break
    // scoped beats legacy...
    auto a = [ mk("w", "", "", "", "legacy", /*scoped=*/false, /*rank=*/1),
               mk("w", "", "", "", "scoped", /*scoped=*/true) ];
    assert(a[resolveBinding(a, "w", "viewport3d", "vertex", "")].id == "scoped");

    // ...and among legacy rows, handleKeyDown's historical order —
    // tool(0) before command(1) before editmode(2) — still decides, so a
    // config that relied on it keeps behaving the same.
    auto b = [ mk("w", "", "", "", "cmd",  false, 1),
               mk("w", "", "", "", "tool", false, 0) ];
    assert(b[resolveBinding(b, "w", "viewport3d", "vertex", "")].id == "tool");
}

// ---------------------------------------------------------------------------
// Loader refusals. Each of these would otherwise produce a binding that never
// fires and never complains.
// ---------------------------------------------------------------------------

unittest {  // an unknown zone name is refused, a known one is accepted
    {
        auto p = writeTmpYaml("badzone",
            "bindings:\n  - { key: \"Ctrl+Space\", zone: layerlist, command: \"ui.pie layers\" }\n");
        scope(exit) remove(p);
        bool threw = false;
        try { loadShortcuts(p); } catch (Exception e) { threw = true; }
        assert(threw, "a misspelt zone must throw — a binding scoped to a zone "
                    ~ "nobody publishes never matches and never says so");
    }
    {
        auto p = writeTmpYaml("goodzone",
            "bindings:\n  - { key: \"Ctrl+Space\", zone: layerList, command: \"ui.pie layers\" }\n");
        scope(exit) remove(p);
        auto tbl = loadShortcuts(p);
        assert(tbl.bindings.length == 1);
        assert(tbl.bindings[0].zone == "layerList");
        assert(tbl.bindings[0].id   == "ui.pie");
        assert(tbl.bindings[0].args == "layers", "the inline argstring is split off the command");
    }
}

unittest {  // two rows with the same chord AND the same scope are a load error
    auto p = writeTmpYaml("dupscope",
        "bindings:\n"
        ~ "  - { key: \"Ctrl+Space\", zone: layerList, command: \"ui.pie layers\" }\n"
        ~ "  - { key: \"Ctrl+Space\", zone: layerList, command: \"ui.pie viewport\" }\n");
    scope(exit) remove(p);
    bool threw = false;
    try { loadShortcuts(p); } catch (Exception e) { threw = true; }
    assert(threw, "nothing can choose between them, so the config must be "
                ~ "refused rather than silently resolved first-wins");
}

unittest {  // a row must name exactly one action, and must have a key
    foreach (body_; [
        "bindings:\n  - { zone: layerList, command: \"ui.pie layers\" }\n",
        "bindings:\n  - { key: \"Ctrl+Space\" }\n",
        "bindings:\n  - { key: \"Ctrl+Space\", command: \"a\", tool: b }\n",
    ]) {
        auto p = writeTmpYaml("badrow", body_);
        scope(exit) remove(p);
        bool threw = false;
        try { loadShortcuts(p); } catch (Exception e) { threw = true; }
        assert(threw, "malformed `bindings:` row must throw: " ~ body_);
    }
}

unittest {  // the SHIPPED config still resolves the two pie rows as intended
    auto tbl = loadShortcuts("config/shortcuts.yaml");

    // The legacy sections are in the table too, as all-wildcard rows — this is
    // what keeps every existing shortcut working unchanged.
    int wIdx = resolveBinding(tbl.bindings, "w", "viewport3d", "vertex", "");
    assert(wIdx >= 0 && tbl.bindings[wIdx].kind == BindingKind.tool
           && tbl.bindings[wIdx].id == "move",
           "W must still be the Move tool, from any zone");
    assert(resolveBinding(tbl.bindings, "w", "layerList", "vertex", "") == wIdx,
           "...including from a panel: an unscoped binding is zone-blind");

    int a = resolveBinding(tbl.bindings, "ctrl+space", "viewport3d", "vertex", "");
    int b = resolveBinding(tbl.bindings, "ctrl+space", "layerList",  "vertex", "");
    assert(a >= 0 && b >= 0 && a != b, "the chord must resolve differently per zone");
    assert(tbl.bindings[a].args == "viewport");
    assert(tbl.bindings[b].args == "layers");
}
