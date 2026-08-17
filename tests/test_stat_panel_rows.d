// THE ROWS THE FRAME DREW — `GET /api/stats` (task 1100 Stage 4, verification A).
//
// Everything here is asserted against the DRAWN record, not against the row
// model: a test that asked the model again would prove the model and say
// nothing about whether the panel rendered it. `ui/item_rows.d`'s header
// records this codebase shipping exactly that defect once — a panel whose
// declared contents were rendered nowhere, with the test that asserted the
// declaration passing the whole time.
//
// THE TREE IS EXPANDED EXPLICITLY, never inherited from the first-open default.
// That default is OURS rather than measured, so it is precisely the kind of
// constant that changes; a test that leaned on it would go red for a reason
// that has nothing to do with what it checks.

import std.net.curl;
import std.json;
import std.exception : enforce;
import std.algorithm : canFind, filter, map;
import std.array : array;
import std.conv : to;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue gj(string p) { return parseJSON(cast(string)get(baseUrl ~ p)); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void cmd(string line) {
    string resp = httpPost("/api/command", line);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command `" ~ line ~ "` failed: " ~ resp);
}

/// A state change is visible in the DRAWN record only once a frame has drawn
/// with it.
void settle() { Thread.sleep(400.msecs); }

void resetApp() { httpPost("/api/reset", "{}"); settle(); }

/// Open the panel and expand exactly what a test asserts on.
void openPanelWith(string[] targets) {
    cmd("ui.statistics show");
    // JSON, not an argstring: a category key contains a SPACE ("Vertices/By
    // Edge") and the argstring parser splits positionals on whitespace.
    foreach (t; targets)
        cmd(`{"id":"ui.statistics.expand","_positional":["` ~ t ~ `","open"]}`);
    settle();
}

/// Address a row by its PATH, not by its bare label: "3" is a row of
/// `Vertices → By Edge` and of `Polygons → By Vertex` both, and a lookup that
/// took the first match would silently assert about the wrong one.
JSONValue rowAt(JSONValue[] rs, string section, string category, string label) {
    string curSec, curCat;
    foreach (r; rs) {
        immutable string lvl = r["level"].str;
        if (lvl == "section")  { curSec = r["label"].str; curCat = ""; continue; }
        if (lvl == "category") { curCat = r["label"].str; continue; }
        if (curSec == section && curCat == category && r["label"].str == label)
            return r;
    }
    assert(false, "no drawn row: " ~ section ~ "/" ~ category ~ "/" ~ label);
}

JSONValue[] rows() { return gj("/api/stats")["rows"].array; }

JSONValue rowOf(JSONValue[] rs, string level, string label) {
    foreach (r; rs)
        if (r["level"].str == level && r["label"].str == label) return r;
    assert(false, "no drawn row: " ~ level ~ " " ~ label);
}

bool hasRow(JSONValue[] rs, string level, string label) {
    foreach (r; rs)
        if (r["level"].str == level && r["label"].str == label) return true;
    return false;
}

// --------------------------------------------------------------------------

unittest { // the four sections, in the fixed traversal order
    resetApp();
    openPanelWith([]);

    auto rs = rows();
    assert(rs.length > 0, "the panel drew nothing — is it open?");
    auto sections = rs.filter!(r => r["level"].str == "section")
                      .map!(r => r["label"].str).array;
    assert(sections == ["Vertices", "Edges", "Polygons", "Items"],
        "section order is a fixed traversal, got " ~ sections.to!string);
}

unittest { // a leaf's Num and Sel, and the ZERO row that is never hidden
    resetApp();
    cmd("select.typeFrom vertex");
    cmd("select.drop vertex");
    openPanelWith(["Vertices", "Vertices/By Edge"]);

    auto rs = rows();
    auto three = rowAt(rs, "Vertices", "By Edge", "3");
    assert(three["num"].str == "8", "a cube's 8 vertices each have 3 edges, got "
        ~ three["num"].str);

    // Rows are NEVER hidden for being empty, and a zero row reads a real `0` —
    // not a placeholder, because zero is a number we know.
    auto zero = rowAt(rs, "Vertices", "By Edge", "0");
    assert(zero["num"].str == "0", "the zero row reads 0, got " ~ zero["num"].str);
}

unittest { // the THREE cell states, each asserted by its EXACT text
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Polygons", "Polygons/By Type", "Vertices", "Vertices/By Edge"]);

    auto rs = rows();

    // (a) a structural zero reads `0`: our mesh model cannot hold a Bezier
    // polygon, so "none" is TRUE.
    auto bez = rowAt(rs, "Polygons", "By Type", "Bezier");
    assert(bez["num"].str == "0", "a structural zero is a real 0, got " ~ bez["num"].str);
    assert(bez["avail"].str == "structuralZero", bez["avail"].str);

    // (b) an unmeasured row reads EXACTLY "—": we do not know the predicate, so
    // a `0` there would be a lie. Owner decision 1 requires this glyph be
    // asserted rather than merely chosen.
    auto convex = rowAt(rs, "Polygons", "By Type", "Convex");
    // Spelled `\u2014` rather than as a literal em dash: the glyph is the
    // thing being asserted, and an escape cannot be re-encoded by anything
    // between this file and the compiler.
    assert(convex["num"].str == "\u2014",
        "an unmeasured cell must read exactly the em dash (U+2014), got '"
        ~ convex["num"].str ~ "'");
    assert(convex["avail"].str == "unmeasured", convex["avail"].str);

    // (c) a GATED cell reads EXACTLY "...". Polygons are current, so the
    // VERTEX rows' Sel is gated — and this is a different glyph answering a
    // different question ("there IS a number, but not for your current mode").
    auto vtx = rowAt(rs, "Vertices", "By Edge", "3");
    assert(vtx["sel"].str == "...",
        "a gated Sel must read exactly three dots, got '" ~ vtx["sel"].str ~ "'");
    assert(vtx["num"].str != "...",
        "…while its Num is computed regardless of the gate");
    assert(convex["num"].str != vtx["sel"].str,
        "the two placeholders must not be the same constant");
}

unittest { // the category LEVEL has no action cells; sections and leaves do
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Vertices", "Edges", "Polygons", "Items",
                   "Vertices/By Edge", "Polygons/By Vertex", "Polygons/Material"]);

    auto rs = rows();
    size_t cats = 0;
    foreach (r; rs) {
        if (r["level"].str != "category") continue;
        ++cats;
        assert(!r["hasActions"].boolean,
            "a category row has NO action cells at all: " ~ r["label"].str);
        assert(r["num"].str.length == 0 && r["sel"].str.length == 0,
            "…and no numbers: " ~ r["label"].str);
    }
    // EXACTLY eighteen — the tree's whole category level, counted rather than
    // floored. `>= 10` against eighteen emitters could not fail for the thing
    // this sweep exists to hold: a whole section's categories could stop being
    // DRAWN and the assertion would still pass. Measured: dropping the Edges
    // section's four categories reddens this line (and its twin in
    // `tests/unit/ui/stat_rows_test.d`).
    assert(cats == 18, "the sweep must cover the whole level — 18 categories, saw "
        ~ cats.to!string);

    auto polySec = rowOf(rs, "section", "Polygons");
    assert(polySec["hasActions"].boolean, "section headers act");
    auto quad = rowAt(rs, "Polygons", "By Vertex", "4");
    assert(quad["hasActions"].boolean && quad["actionsEnabled"].boolean,
        "a live leaf acts");
}

unittest { // the DIMMED tone is a ROW state and does NOT disable the buttons
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    cmd(`{"id":"select.byStat.polygon","test":"vertexCount","compare":"equal","value":4,"mode":"add"}`);
    openPanelWith(["Polygons", "Polygons/By Vertex"]);

    auto rs = rows();
    auto quad = rowAt(rs, "Polygons", "By Vertex", "4");
    assert(quad["sel"].str == "6", "every quad is selected, got " ~ quad["sel"].str);
    assert(quad["tone"].str == "dimmed",
        "a row with a non-zero selected count is drawn dimmed");
    // THE POINT OF THE ASSERTION BELOW: dimming and disabling are different
    // things, and expressing the first with the second is the mistake a coder
    // reaches for, because greying is what BeginDisabled already does two lines
    // up in the same drawer.
    assert(quad["hasActions"].boolean && quad["actionsEnabled"].boolean,
        "a dimmed row stays fully clickable");

    auto polySec = rowOf(rs, "section", "Polygons");
    assert(polySec["tone"].str == "dimmed",
        "the section header dims with its own selected count");

    // A gated section is drawn NORMAL — its Sel is not computed at all.
    auto vsec = rowOf(rs, "section", "Vertices");
    assert(vsec["tone"].str == "normal",
        "a gated section is not dimmed, whatever is selected elsewhere");
}

unittest { // the panel draws LEAVES, not only section rows
    resetApp();
    openPanelWith(["Polygons", "Polygons/By Vertex"]);
    auto rs = rows();
    auto leaves = rs.filter!(r => r["level"].str == "leaf").array;
    assert(leaves.length >= 5,
        "the draw loop must emit leaf rows, saw " ~ leaves.length.to!string);
}

// --------------------------------------------------------------------------
// THE PANEL-CLOSED ZERO, with a POSITIVE CONTROL (task 1100 Stage 5).
//
// `totals.statRebuilds`, never `lastScene`: `lastScene` is one frame's record,
// so a settled frame can legitimately rebuild nothing and the read races.
// `totals` is cumulative since the reset, and the first drawn frame after a
// reset rebuilds from a cold cache whatever the refresh policy is — so this
// control passes on a correct implementation either way.
//
// THE TWO STEPS ORDER THEIR RESET OPPOSITELY, and each order is forced:
//
//   * OPEN — the reset comes FIRST, before the panel opens, because a reset
//     taken on a warm open panel can legitimately read zero.
//   * CLOSED — the reset comes LAST, after the hide has taken effect and
//     settled. Resetting while the panel is still open leaves a window in
//     which it is still drawing, entirely correctly, and every frame that
//     lands there is counted against the closed state. That is not a
//     hypothetical: under `-j` this failed with `got 1` — one frame, drawn
//     between the counter reset and the hide arriving. The window exists at
//     any load; contention only widens it.
// --------------------------------------------------------------------------
unittest {
    long totalRebuilds() {
        return gj("/api/frames/counts")["totals"]["statRebuilds"].integer;
    }

    resetApp();

    // 1. reset → open → step → read: the panel is drawing, so it rebuilds.
    httpPost("/api/frames/counts/reset", "{}");
    cmd("ui.statistics show");
    settle();
    immutable long open = totalRebuilds();
    assert(open > 0,
        "an OPEN panel must rebuild its row model at least once, got "
        ~ open.to!string);

    // 2. close → settle → reset → step → read: it costs nothing while closed.
    // Without step 1 this assertion would pass on a panel that never worked at
    // all. The reset is AFTER the settle so that the frames the panel drew
    // while it was still legitimately open are not counted against it.
    cmd("ui.statistics hide");
    settle();
    httpPost("/api/frames/counts/reset", "{}");
    settle();
    immutable long closed = totalRebuilds();
    assert(closed == 0,
        "a CLOSED panel must rebuild nothing, got " ~ closed.to!string);
}
