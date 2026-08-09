// Task 0642 — the DELIBERATE door into Items mode.
//
// ---------------------------------------------------------------------------
// Why the obvious assertion is worthless here
// ---------------------------------------------------------------------------
// "`SelType.Item` exists" and "`/api/selection` can report `item`" were BOTH
// true for the entire life of the bug this task fixes: selecting a layer has
// always promoted `SelType.Item` to current. What did not exist was a way in
// that does not touch the item selection. So every row below drives the door
// ITSELF (`select.typeFrom item` / `select.item`) and never once calls
// `layer.select`.
//
// The three things that must hold, and the wrong implementation each one
// catches:
//
//  1. The command CHANGES the current type, visible through /api/selection.
//     Catches: the pre-0642 state, where `select.typeFrom item` threw
//     ("unknown type 'item' — expected vertex, edge, or polygon").
//
//  2. `editMode` does NOT change with it. Catches the headline trap: an
//     implementation that adds a fourth `EditMode`, or that clears/resets the
//     geometry view on entry. `/api/selection`'s `mode` field is the geometry
//     view; it must read exactly what it read before the switch.
//
//  3. Coming back gives the SAME geometry type, not an arbitrary one. A single
//     reading cannot tell "remembers" from "hardcodes polygons" — so the door
//     is driven TWICE, once with Polygons remembered and once with Edges, and
//     the two readings must DIFFER. An implementation that pins the geometry
//     view to any constant reads the same number both times and fails one row.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);
}

struct SelState {
    string   selType;      // the CURRENT selection type
    string   mode;         // the derived geometry view (editMode)
    string[] order;        // the full most-recent-first ordering
}

SelState selState() {
    auto j = getJson("/api/selection");
    SelState s;
    s.selType = j["selType"].str;
    s.mode    = j["mode"].str;
    foreach (e; j["selTypeOrder"].array) s.order ~= e.str;
    return s;
}

string describe(SelState s) {
    return format("selType=%s mode=%s order=%s", s.selType, s.mode, s.order);
}

// ---------------------------------------------------------------------------
// 1. The door opens, and the geometry view stays exactly where it was.
//
//    Driven from POLYGON mode. Discriminating values:
//      * selType: "item"      (pre-fix: the command threw, so this row never ran)
//      * mode:    "polygons"  (a fourth-EditMode implementation, or one that
//                              reset the view, reads "vertices" or "items")
//      * order[1]: "polygon"  (the remembered geometry type sits directly
//                              behind item, which is WHY mode still reads
//                              polygons — the memory, not a coincidence)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    auto before = selState();
    assert(before.selType == "polygon" && before.mode == "polygons",
        "fixture: must start in polygon mode — " ~ describe(before));

    cmd("select.typeFrom item");
    auto after = selState();

    assert(after.selType == "item",
        "select.typeFrom item must make the ITEM type current — " ~ describe(after));
    assert(after.mode == before.mode,
        "the geometry view must NOT move when Items becomes current: it is a "
        ~ "materialized view of the most-recent GEOMETRY type and stays "
        ~ "defined under Item so picking/drawing keep a mode. was="
        ~ before.mode ~ " now=" ~ after.mode);
    assert(after.mode == "polygons",
        "and the value it holds is the one that was current — " ~ describe(after));
    assert(after.order.length == 4 && after.order[0] == "item"
           && after.order[1] == "polygon",
        "item must be promoted to the FRONT with the remembered geometry type "
        ~ "directly behind it — " ~ describe(after));

    // No item selection was touched to get here — the whole point of the door.
    auto items = getJson("/api/selection")["items"].array;
    assert(items.length == 1 && items[0]["selected"].boolean
           && items[0]["primary"].boolean,
        "the door must not have changed the item selection set");
}

// ---------------------------------------------------------------------------
// 2. The SAME door read with a DIFFERENT remembered type must give a DIFFERENT
//    answer. This is the row that separates "remembers" from "hardcodes".
//
//    From EDGE mode the geometry view under Item must read "edges" — the
//    value row 1 proved is "polygons" for the polygon fixture. Any constant
//    answer fails exactly one of the two rows.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom edge");
    cmd("select.typeFrom item");
    auto s = selState();

    assert(s.selType == "item", "fixture: item must be current — " ~ describe(s));
    assert(s.mode == "edges",
        "the geometry view under Item must be the type that was current when "
        ~ "Items was entered (edges here, polygons in row 1). Reading "
        ~ "\"polygons\" or \"vertices\" here means the view is pinned to a "
        ~ "constant rather than remembered — " ~ describe(s));
    assert(s.order[0] == "item" && s.order[1] == "edge",
        "and the ordering must remember edge as the most-recent geometry type — "
        ~ describe(s));
}

// ---------------------------------------------------------------------------
// 3. Coming back out. Leaving Items restores the geometry type it remembered,
//    and Items is remembered in turn (so re-entering is a genuine re-flip
//    rather than a no-op against a stale front).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    cmd("select.typeFrom item");
    cmd("select.typeFrom polygon");
    auto back = selState();

    assert(back.selType == "polygon" && back.mode == "polygons",
        "leaving Items must land back on the geometry type — " ~ describe(back));
    assert(back.order[0] == "polygon" && back.order[1] == "item",
        "item must now be the SECOND-most-recent type, not dropped to the tail "
        ~ "— " ~ describe(back));

    // And the door still opens on the second use.
    cmd("select.typeFrom item");
    auto again = selState();
    assert(again.selType == "item" && again.mode == "polygons",
        "second entry must behave like the first — " ~ describe(again));
}

// ---------------------------------------------------------------------------
// 4. `select.item` — the id the status-line button fires — is the same door.
//    A button wired to a command that does something ELSE (or to nothing) is
//    exactly the failure this row catches; the button's YAML names this id.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom edge");
    cmd(`{"id":"select.item"}`);
    auto s = selState();
    assert(s.selType == "item",
        "select.item (the status-line button's command id) must open the same "
        ~ "door as `select.typeFrom item` — " ~ describe(s));
    assert(s.mode == "edges",
        "and leave the geometry view alone, exactly like the typed form — "
        ~ describe(s));
}

// ---------------------------------------------------------------------------
// 5. The door is a MODE switch, so a front-flip drops the active tool — the
//    same B2 rule keys 1/2/3 follow. Re-entering the type that is ALREADY
//    current is not a flip and must NOT drop the tool.
//
//    Both halves are needed: an implementation that drops the tool
//    unconditionally passes the first assert and fails the second, and one
//    that never drops passes the second and fails the first.
// ---------------------------------------------------------------------------

unittest {
    bool toolArmed() {
        auto j = getJson("/api/tool/handles");
        return j["handles"].type != JSONType.null_;
    }

    resetCube();
    cmd("select.typeFrom polygon");
    cmd("tool.set move on");
    assert(toolArmed(), "fixture: the move tool must be armed before the switch");

    cmd("select.typeFrom item");
    assert(!toolArmed(),
        "a front-FLIP into Items must drop the active tool (B2), like the "
        ~ "geometry mode keys do");

    // Already current -> no flip -> no drop.
    cmd("tool.set move on");
    assert(toolArmed(), "fixture: re-arm for the no-flip half");
    cmd("select.typeFrom item");
    assert(toolArmed(),
        "entering the type that is ALREADY current is not a flip and must NOT "
        ~ "drop the tool");
    cmd("tool.set move off");
}
