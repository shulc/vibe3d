// The tool attribute door's gate (task 9428; captured K-A, findings_K-A.md).
//
// One rule in front of every `tool.attr` write, for every tool, with no
// per-tool flag: (1) an unknown attribute is refused for the write AND the
// query; (2) a row the tool reports disabled refuses the write — whatever the
// value, the current one included — with `status:error`, the value unchanged
// and no history row (the command no-op contract's refusal arm), while its
// query still answers; (3) otherwise the write lands. A tool supplies only
// data: which rows it disables in which state (`paramEnabled`).
//
// Cells: K-A A1d (unknown), A1a / A1a_pos (sphere order by method), A1b2
// (loop slice Reverse Direction with no profile, the same-value write too),
// A1b (loop slice Inset stays ENABLED with no profile and under Keep Aspect,
// PF-1), lsrows (loop slice quad / caps / gap behind their switches), ka3
// (K-A3 rows the reference keeps enabled: the write lands), and one
// disabled-row cell per family that reads `paramEnabled` (shared-policy
// readers), each with its enabled-row positive control where the tool has one.
// Families are collected and reported together so one run names every family
// a mutation of the shared refusal reddens.
//
// Run via: ./run_test.d test_tool_attr_gate   (one block: VIBE3D_CELL=A1d|A1a|A1b|lsrows|ka3|families|pf3)

import http_client : getJson, postRawAllowingErrorStatus;
import std.algorithm : canFind, splitter;
import std.format : format;
import std.json;
import std.process : environment;
import std.stdio : writeln;

void main() {}

/// `VIBE3D_CELL=<id>` runs one block alone (a mutation drill names the block
/// it must redden; druntime stops a module at its first failed assert).
bool cell(string id) {
    const want = environment.get("VIBE3D_CELL", "");
    return want.length == 0 || want == id;
}

JSONValue cmd(string line) {
    return parseJSON(postRawAllowingErrorStatus("/api/command", line));
}

void ok(string line) {
    auto r = cmd(line);
    assert(r["status"].str == "ok", line ~ " -> " ~ r.toString);
}

string read(string tool, string attr) {
    auto r = cmd("tool.attr " ~ tool ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ tool ~ " " ~ attr ~ " -> " ~ r.toString);
    return r["value"].toString;
}

size_t historyLen() {
    return getJson("/api/history")["undo"].array.length;
}

void arm(string tool) {
    ok("scene.reset");
    ok("tool.set " ~ tool ~ " on");
}

/// "" when the write was refused as a disabled row (error, the reason names
/// the attribute, value and history unchanged); otherwise what went wrong.
string refusedDisabled(string tool, string attr, string value) {
    const before = read(tool, attr);
    const h0 = historyLen();
    auto r = cmd("tool.attr " ~ tool ~ " " ~ attr ~ " " ~ value);
    const msg = "message" in r ? r["message"].str : "";
    if (r["status"].str != "error"
        || !msg.canFind("attribute '" ~ attr ~ "'")
        || !msg.canFind("disabled in its current state"))
        return format("%s %s %s answered %s", tool, attr, value, r.toString);
    if (read(tool, attr) != before)
        return format("%s %s %s changed the value %s -> %s", tool, attr, value, before,
                      read(tool, attr));
    if (historyLen() != h0)
        return format("%s %s %s added %d history rows", tool, attr, value, historyLen() - h0);
    return "";
}

/// "" when the write landed and reads back `expect`.
string lands(string tool, string attr, string value, string expect) {
    auto r = cmd("tool.attr " ~ tool ~ " " ~ attr ~ " " ~ value);
    if (r["status"].str != "ok")
        return format("%s %s %s refused: %s", tool, attr, value, r.toString);
    if (read(tool, attr) != expect)
        return format("%s %s %s reads %s, expected %s", tool, attr, value, read(tool, attr),
                      expect);
    return "";
}

// A1d — an unknown attribute: the write and the query are both refused. On
// the unmodified door the write answered ok (backlog 9479).
unittest {
    if (!cell("A1d")) return;
    arm("prim.sphere");
    const h0 = historyLen();
    foreach (v; ["3", "?"]) {
        auto r = cmd("tool.attr prim.sphere bogusAttr " ~ v);
        assert(r["status"].str == "error"
               && r["message"].str.canFind("unknown attribute 'bogusAttr'"),
               "A1d: tool.attr prim.sphere bogusAttr " ~ v ~ " answered " ~ r.toString);
    }
    assert(historyLen() == h0, "A1d: an unknown-attribute write added a history row");
    writeln("PASS A1d unknown attribute");
}

// A1a / A1a_pos — sphere `order` is disabled under Globe and enabled under
// Quad Ball: the refusal comes from the row's state, not the attribute.
unittest {
    if (!cell("A1a")) return;
    arm("prim.sphere");
    ok("tool.attr prim.sphere method qball");
    ok("tool.attr prim.sphere order 2");
    ok("tool.attr prim.sphere method globe");
    foreach (v; ["5", "2"]) {     // a write of the current value is refused too (PF-4)
        const why = refusedDisabled("prim.sphere", "order", v);
        assert(why == "", "A1a: " ~ why);
    }
    assert(read("prim.sphere", "order") == "2", "A1a: the disabled row's query moved");
    ok("tool.attr prim.sphere method qball");
    const why = lands("prim.sphere", "order", "5", "5");
    assert(why == "", "A1a_pos: " ~ why);
    writeln("PASS A1a / A1a_pos sphere order");
}

// A1b2 / A1b — loop slice with no profile: Reverse Direction refuses true and
// the current false; Inset (depth) lands, and still lands under Keep Aspect.
unittest {
    if (!cell("A1b")) return;
    arm("mesh.loopSliceTool");
    ok("tool.attr mesh.loopSliceTool profile flat");
    foreach (v; ["true", "false"]) {
        const why = refusedDisabled("mesh.loopSliceTool", "reversex", v);
        assert(why == "", "A1b2: " ~ why);
    }
    foreach (attr; ["reversey", "aspect"]) {
        const why = refusedDisabled("mesh.loopSliceTool", attr, "true");
        assert(why == "", "A1b2: " ~ why);
    }
    string why = lands("mesh.loopSliceTool", "depth", "0.25", "0.25");
    assert(why == "", "A1b (PF-1, no profile): " ~ why);
    ok("tool.attr mesh.loopSliceTool profile round");
    ok("tool.attr mesh.loopSliceTool aspect true");
    why = lands("mesh.loopSliceTool", "depth", "0.5", "0.5");
    assert(why == "", "A1b (PF-1, Keep Aspect on): " ~ why);
    why = lands("mesh.loopSliceTool", "reversex", "true", "true");
    assert(why == "", "A1b2 positive (profile loaded): " ~ why);
    writeln("PASS A1b2 / A1b loop slice");
}

// Loop slice rows gated by another switch (captured K-U2 ls-* refusal
// messages; K-A F1): Keep Quads needs Slice Selected, Cap Sections and Gap
// need Split. Each row refuses true and its current value, then lands once its
// switch is on; all three rows are collected so one run names every term.
unittest {
    if (!cell("lsrows")) return;
    struct Row { string attr, value, current, enable, expect; }
    static immutable Row[] rows = [
        Row("quad", "true", "false", "select true", "true"),
        Row("caps", "false", "true", "split true", "false"),
        Row("gap", "0.25", "0.0", "split true", "0.25"),
    ];
    string[] failed;
    size_t visited;
    foreach (r; rows) {
        arm("mesh.loopSliceTool");
        ++visited;
        string why = refusedDisabled("mesh.loopSliceTool", r.attr, r.value);
        if (why == "") why = refusedDisabled("mesh.loopSliceTool", r.attr, r.current);
        if (why == "") {
            ok("tool.attr mesh.loopSliceTool " ~ r.enable);
            why = lands("mesh.loopSliceTool", r.attr, r.value, r.expect);
        }
        if (why != "") failed ~= r.attr ~ ": " ~ why;
    }
    assert(visited == 3, format("loop slice rows visited %d, expected 3", visited));
    assert(failed.length == 0, format("loop slice gated rows failed in %d rows:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS loop slice quad / caps / gap rows");
}

// K-A3 rows the reference keeps ENABLED where ours used to grey them: box
// Sharp at a non-zero radius with more than 3 radius segments, mirror Mode in
// any state, the pen's point fields at idle. Each write lands; collected so
// one run names every row.
unittest {
    if (!cell("ka3")) return;
    struct Row { string tool, setup, attr, value, expect; }
    static immutable Row[] rows = [
        Row("prim.cube", "radius 0.1|segmentsR 4", "sharp", "true", "true"),
        Row("mesh.mirrorTool", "", "mode", "axis", "\"axis\""),
        Row("pen", "", "posX", "1", "1.0"),
        Row("pen", "", "currentPoint", "0", "0"),
    ];
    string[] failed;
    size_t visited;
    foreach (r; rows) {
        arm(r.tool);
        foreach (w; r.setup.splitter('|'))
            if (w.length) ok("tool.attr " ~ r.tool ~ " " ~ w);
        ++visited;
        const why = lands(r.tool, r.attr, r.value, r.expect);
        if (why != "") failed ~= why;
    }
    assert(visited == 4, format("K-A3 rows visited %d, expected 4", visited));
    assert(failed.length == 0, format("K-A3 enabled rows refused in %d rows:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS K-A3 enabled rows");
}

// One disabled-row cell per family reading `paramEnabled` (the two pens have
// their own files: test_topopen_attr_availability, test_pen_types). `enable`
// is the write that turns the row on ("" when the row is never enabled).
unittest {
    if (!cell("families")) return;
    struct Cell { string family, tool, disable, attr, value, enable, expect; }
    static immutable Cell[] cells = [
        Cell("clone", "mesh.clone", "merge false", "dist", "0.25", "merge true", "0.25"),
        Cell("array", "mesh.arrayTool", "merge false", "dist", "0.25", "merge true", "0.25"),
        Cell("mirror", "mesh.mirrorTool", "mergeVerts false", "distance", "0.25",
             "mergeVerts true", "0.25"),
        Cell("command_wrapper", "xfrm.jitter", "enableX false", "rangeX", "0.25",
             "enableX true", "0.25"),
        Cell("box", "prim.cube", "radius 0", "sharp", "true", "radius 0.1", "true"),
        Cell("slice", "mesh.sliceTool", "split false", "caps", "false", "split true", "false"),
    ];
    string[] failed;
    size_t visited;
    foreach (c; cells) {
        arm(c.tool);
        if (c.disable.length) ok("tool.attr " ~ c.tool ~ " " ~ c.disable);
        ++visited;
        auto why = refusedDisabled(c.tool, c.attr, c.value);
        if (why == "" && c.enable.length) {
            ok("tool.attr " ~ c.tool ~ " " ~ c.enable);
            why = lands(c.tool, c.attr, c.value, c.expect);
        }
        if (why != "") failed ~= c.family ~ ": " ~ why;
    }
    assert(visited == 6, format("families visited %d, expected 6", visited));
    assert(failed.length == 0, format("disabled-row gate failed in %d families:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS disabled-row refusal, 6 families");
}

// pf3 — rows the reference disables and ours enabled before task 9492 (K-A3
// PF-3): box Radius Segments at a zero radius; Slice and Clone Angle Snap while
// global snapping is off, and their Angle unless both are on. Each row is
// refused in the disabling state and lands once the enabling line runs.
unittest {
    if (!cell("pf3")) return;
    enum off = "tool.pipe.attr snap enabled false", on = "tool.pipe.attr snap enabled true";
    struct Row { string tool, disable, attr, value, enable, expect; }
    static immutable Row[] rows = [
        Row("prim.cube", "tool.attr prim.cube radius 0", "segmentsR", "4",
            "tool.attr prim.cube radius 0.1", "4"),
        Row("mesh.sliceTool", off, "snap", "true", on, "true"),
        Row("mesh.sliceTool", on ~ "|tool.attr mesh.sliceTool snap true|" ~ off,
            "snapAngle", "30", on, "30.0"),
        Row("mesh.clone", off, "snap", "true", on, "true"),
        Row("mesh.clone", on ~ "|tool.attr mesh.clone snap true|" ~ off,
            "snapAngle", "30", on, "30.0"),
    ];
    string[] failed;
    size_t visited;
    foreach (r; rows) {
        arm(r.tool);
        foreach (line; r.disable.splitter('|')) ok(line);
        ++visited;
        auto why = refusedDisabled(r.tool, r.attr, r.value);
        if (why == "") {
            ok(r.enable);
            why = lands(r.tool, r.attr, r.value, r.expect);
        }
        if (why != "") failed ~= why;
    }
    ok(off);
    assert(visited == 5, format("PF-3 rows visited %d, expected 5", visited));
    assert(failed.length == 0, format("PF-3 rows failed in %d rows:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS K-A3 PF-3 disabled rows");
}
