// Module unittests for the pie-menu config loader (task 1800).
//
// Two halves, and the second is the point of the file:
//   1. the SHIPPED config/pies.yaml parses, and its wedge ORDER is the compass
//      order the geometry law assumes (index 2 is east, so "Right" must be
//      there — a reorder of the YAML silently re-aims every wedge, and this is
//      the only place that notices);
//   2. every refusal the loader promises actually refuses. A loader that
//      quietly took "the first 8" of nine items, or accepted a nested popup it
//      cannot draw, would be green on both a good config and a broken one.
module tests.unit.pies_config_test;

import std.file   : write, remove, tempDir;
import std.format : format;
import std.process : thisProcessID;

import buttonset;

private string writeTmpYaml(string tag, string body_) {
    // Per-process name: the suite runs workers in parallel and a shared
    // fixture path would have two writers.
    string p = format("%s/vibe3d_pies_%s_%d.yaml", tempDir(), tag, thisProcessID());
    write(p, body_);
    return p;
}

unittest {  // the shipped config loads, and the compass order is what it claims
    auto menus = loadPies("config/pies.yaml");
    assert(menus.length >= 1);

    PieMenu* vp = null;
    foreach (ref m; menus) if (m.id == "viewport") vp = &m;
    assert(vp !is null, "config/pies.yaml must ship the 'viewport' menu — "
                      ~ "config/shortcuts.yaml binds Ctrl+Space to it by name");
    assert(vp.items.length == 8, "the viewport pie is a full eight wedges");

    // Index IS direction (pie_geometry: 0 = noon, clockwise). These four are
    // the ones whose name states where they must sit.
    assert(vp.items[0].label == "Top",    "slot 0 is north");
    assert(vp.items[2].label == "Right",  "slot 2 is east");
    assert(vp.items[4].label == "Bottom", "slot 4 is south");
    assert(vp.items[6].label == "Left",   "slot 6 is west");

    // Slot 7 is a RESERVED EMPTY one: it holds the compass and does nothing.
    // Asserted explicitly rather than left to "the other seven are fine",
    // because the failure it guards against is the slot quietly acquiring a
    // command — which would work, and would be wrong.
    assert(vp.items[7].label.length == 0, "slot 7 (NW) is the reserved empty slot");
    assert(vp.items[7].disabled, "...and it must be inert, not merely unlabelled");

    // Every OTHER wedge carries a real, dispatchable action — not a popup
    // (refused below) and not a blank label.
    foreach (i, ref it; vp.items) {
        if (i == 7) continue;
        assert(it.label.length > 0);
        assert(!it.disabled);
        assert(it.action.kind != ActionKind.popup);
    }
}

unittest {  // an empty slot needs no label and no action — and refuses both
    auto p = writeTmpYaml("emptyslot",
        "menus:\n  - id: holed\n    title: T\n    items:\n"
        ~ "      - { label: A, action: { kind: command, id: viewport.fit } }\n"
        ~ "      - { empty: true }\n");
    scope(exit) remove(p);
    auto m = loadPies(p)[0];
    assert(m.items.length == 2, "the empty slot still OCCUPIES a slot — that is "
                              ~ "its whole purpose; dropping it would re-aim "
                              ~ "every wedge after it");
    assert(m.items[1].label.length == 0 && m.items[1].disabled);

    // Declaring both is a mixed intent, not a shorthand.
    foreach (body_; [
        "menus:\n  - id: x\n    title: T\n    items:\n      - { empty: true, label: Camera }\n",
        "menus:\n  - id: x\n    title: T\n    items:\n      - { empty: true, action: { kind: command, id: viewport.fit } }\n",
    ]) {
        auto q = writeTmpYaml("emptymix", body_);
        scope(exit) remove(q);
        bool threw = false;
        try { loadPies(q); } catch (Exception e) { threw = true; }
        assert(threw, "`empty: true` alongside a label or an action must throw");
    }
}

unittest {  // a BLANK label on a normal item is refused — the empty slot has a
            // spelling of its own, and a typo must not silently become one
    auto p = writeTmpYaml("blanklabel",
        "menus:\n  - id: x\n    title: T\n    items:\n"
        ~ "      - { label: \"\", action: { kind: command, id: viewport.fit } }\n");
    scope(exit) remove(p);
    bool threw = false;
    try { loadPies(p); } catch (Exception e) { threw = true; }
    assert(threw, "a blank label must throw rather than render an unnamed wedge "
                ~ "that DOES fire");
}

unittest {  // a ninth item is refused, not silently dropped
    string items;
    foreach (i; 0 .. 9)
        items ~= format("      - { label: I%d, action: { kind: command, id: viewport.fit } }\n", i);
    auto p = writeTmpYaml("nine", "menus:\n  - id: too_big\n    title: T\n    items:\n" ~ items);
    scope(exit) remove(p);

    bool threw = false;
    try { loadPies(p); } catch (Exception e) { threw = true; }
    assert(threw, "9 items must throw — the reference silently keeps the first "
                ~ "8, which is indistinguishable from a wedge that was never "
                ~ "written");
}

unittest {  // exactly eight is accepted (the boundary the previous test needs)
    string items;
    foreach (i; 0 .. 8)
        items ~= format("      - { label: I%d, action: { kind: command, id: viewport.fit } }\n", i);
    auto p = writeTmpYaml("eight_ok", "menus:\n  - id: full\n    title: T\n    items:\n" ~ items);
    scope(exit) remove(p);
    auto menus = loadPies(p);
    assert(menus.length == 1 && menus[0].items.length == 8);
}

unittest {  // a nested popup is refused — a pie has nowhere to open one
    auto p = writeTmpYaml("popup",
        "menus:\n"
        ~ "  - id: nested\n"
        ~ "    title: T\n"
        ~ "    items:\n"
        ~ "      - label: \"More\"\n"
        ~ "        action:\n"
        ~ "          kind: popup\n"
        ~ "          items:\n"
        ~ "            - { label: X, action: { kind: command, id: viewport.fit } }\n");
    scope(exit) remove(p);

    bool threw = false;
    try { loadPies(p); } catch (Exception e) { threw = true; }
    assert(threw, "action kind 'popup' inside a pie must throw");
}

unittest {  // structural refusals: no menus, no items, duplicate id
    {
        auto p = writeTmpYaml("empty", "menus: []\n");
        scope(exit) remove(p);
        bool threw = false;
        try { loadPies(p); } catch (Exception e) { threw = true; }
        assert(threw, "a file that declares no menus is a mistake, not a default");
    }
    {
        auto p = writeTmpYaml("noitems", "menus:\n  - id: bare\n    title: T\n    items: []\n");
        scope(exit) remove(p);
        bool threw = false;
        try { loadPies(p); } catch (Exception e) { threw = true; }
        assert(threw, "a menu with no wedges must throw");
    }
    {
        auto p = writeTmpYaml("dup",
            "menus:\n"
            ~ "  - id: same\n    title: A\n    items:\n"
            ~ "      - { label: X, action: { kind: command, id: viewport.fit } }\n"
            ~ "  - id: same\n    title: B\n    items:\n"
            ~ "      - { label: Y, action: { kind: command, id: viewport.fit } }\n");
        scope(exit) remove(p);
        bool threw = false;
        try { loadPies(p); } catch (Exception e) { threw = true; }
        assert(threw, "two menus with one id — `ui.pie <id>` would be ambiguous");
    }
}
