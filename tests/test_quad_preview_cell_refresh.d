// Quad private-preview stamp witness (task 5340).
//
// This test cannot observe the interactive dirty-key decision: --test
// deliberately bypasses that comparison and renders every cell selected by
// viewport.testRendersCell. It instead asserts the per-cell toolPreviewKey
// stamped before the bypass. The struct-level discrimination and declaration/
// stamp census live in tests/unit; a separate non-test live rig observes the
// actual cellsRendered transition.
module test_quad_preview_cell_refresh;

import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

void main() {}

private enum toolId = "prim.cylinder";

private void command(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command '" ~ line ~ "' failed: " ~ r.toString);
}

private ulong jsonUlong(JSONValue value) {
    switch (value.type) {
        case JSONType.uinteger: return value.uinteger;
        case JSONType.integer:  return cast(ulong)value.integer;
        case JSONType.float_:   return cast(ulong)value.floating;
        default: assert(false, "expected integer JSON, got " ~ value.toString);
    }
}

private ulong[] previewKeys(JSONValue display) {
    ulong[] keys;
    foreach (cell; display["cells"].array) {
        assert("toolPreviewKey" in cell,
            "/api/viewport/display omitted toolPreviewKey: " ~ cell.toString);
        keys ~= jsonUlong(cell["toolPreviewKey"]);
    }
    return keys;
}

private double queryFloat(string name) {
    auto r = postJson("/api/command", "tool.attr " ~ toolId ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
    return r["value"].floating;
}

private void cleanup() {
    try command("tool.set " ~ toolId ~ " off"); catch (Exception) {}
    try command("viewport.layout Single"); catch (Exception) {}
}

unittest {
    scope(exit) cleanup();

    auto reset = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "empty reset failed: " ~ reset.toString);

    // Capture the full editor viewport before Quad divides it. The event log's
    // VIEWPORT row names this owner rect; mouse coordinates below land in the
    // bottom-right Perspective cell.
    auto full = fetchCamera();
    assert(full.width > 16 && full.height > 16,
        "viewport is too small to build a four-cell drag witness");

    command("viewport.layout Quad");
    Thread.sleep(150.msecs);
    auto display = getJson("/api/viewport/display");
    assert(jsonUlong(display["cellCount"]) == 4,
        "viewport.layout Quad did not take: cellCount="
        ~ display["cellCount"].toString);

    command("tool.set " ~ toolId);
    const halfW = full.width / 2;
    const halfH = full.height / 2;
    const cx = full.vpX + halfW + (full.width - halfW) / 2;
    const cy = full.vpY + halfH + (full.height - halfH) / 2;
    playAndWait(buildDragLog(full.vpX, full.vpY, full.width, full.height,
                             cx, cy, cx + 70, cy + 55, 12));
    Thread.sleep(150.msecs);

    immutable sizeBefore = queryFloat("sizeX");
    assert(sizeBefore > 0.01,
        "cylinder base drag produced no live preview; sizeX=" ~ sizeBefore.to!string);

    auto beforeDump = getJson("/api/viewport/display");
    auto before = previewKeys(beforeDump);
    assert(before.length == 4, "Quad stamp witness did not return four cells");
    foreach (key; before[1 .. $])
        assert(key == before[0],
            "toolPreviewKey must be shared across all four cells before the edit");

    command(format("tool.attr %s sizeX %.9g", toolId, sizeBefore + 0.5));

    ulong[] after;
    foreach (_; 0 .. 60) {
        after = previewKeys(getJson("/api/viewport/display"));
        if (after.length == 4 && after[0] != before[0]) break;
        Thread.sleep(50.msecs);
    }
    assert(after.length == 4 && after[0] != before[0],
        "toolPreviewKey did not move after a preview parameter change");
    foreach (key; after[1 .. $])
        assert(key == after[0],
            "toolPreviewKey must be identical across all four cells after the edit");
}

unittest { // a press in the bottom-right cell resolves under THAT cell, one per family (tasks 9473, 9498)
    // The router syncs the tool's viewport to the event's own cell before every
    // mouse handler. The previous owner cell is Top: its projection puts this
    // press far off the cell's own plane hit (behind the Perspective camera),
    // so a tool that reads a stale viewport draws nothing. The press at the
    // cell's centre lands on its focus, the origin. A primitive drags its base;
    // the vertex tool clicks. Every family runs; the failures are reported
    // together.
    string family(string tool, string size) {
        scope(exit) postJson("/api/command", "tool.set " ~ tool ~ " off");
        scope(exit) postJson("/api/command", "viewport.layout Single");
        auto reset = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
        assert(reset["status"].str == "ok", "empty reset failed: " ~ reset.toString);
        auto full = fetchCamera();
        command("viewport.layout Quad");
        Thread.sleep(150.msecs);
        command("tool.set " ~ tool);
        const halfW = full.width / 2, halfH = full.height / 2;
        const cx = full.vpX + halfW + (full.width - halfW) / 2;
        const cy = full.vpY + halfH + (full.height - halfH) / 2;
        const travel = size.length > 0;
        playAndWait(buildDragLog(full.vpX, full.vpY, full.width, full.height,
                                 cx, cy, travel ? cx + 70 : cx, travel ? cy + 55 : cy, 12));
        if (!travel) {
            auto vs = getJson("/api/model")["vertices"].array;
            if (vs.length != 1)
                return format("%s: the click in the Perspective cell made %d vertices, expected 1",
                              tool, vs.length);
            double r2 = 0;
            foreach (c; vs[0].array) {
                immutable double v = c.type == JSONType.float_ ? c.floating : cast(double)c.integer;
                r2 += v * v;
            }
            return r2 < 0.05 * 0.05 ? null
                 : format("%s: the click must land on the cell's focus, got %s", tool, vs[0].toString);
        }
        double attr(string a) {
            auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ a ~ " ?");
            assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
            return r["value"].floating;
        }
        immutable s = attr(size);
        if (!(s > 0.01))
            return format("%s: the base drag in the Perspective cell drew nothing (%s %s)", tool, size, s);
        if (tool != "prim.cube" && !(attr("cenX") * attr("cenX") + attr("cenZ") * attr("cenZ") < 0.05 * 0.05))
            return format("%s: the press must land on the cell's focus, got (%s, %s)",
                          tool, attr("cenX"), attr("cenZ"));
        return null;
    }
    string[] failed;
    foreach (t; [["prim.cube", "sizeX"], ["prim.torus", "majorRadius"], ["prim.tube", "outerRadius"],
                 ["prim.vertex", ""]])
        if (auto m = family(t[0], t[1])) failed ~= m;
    assert(failed.length == 0, format("%-(%s\n%)", failed));
}

unittest { // tools without their own viewport field resolve a bottom-right press under THAT cell (task 9524)
    // The Quad bottom-right cell is the Single camera at half size, so a gesture
    // at half the Single offsets from the cell's corner must give the Single
    // result. A tool reading the last-drawn cell (Top) misses the handle or
    // places far off. The pen clicks the cell's centre, which lands on its
    // focus, the origin. Every family runs; failures are reported together.
    double num(JSONValue v) {
        return v.type == JSONType.float_ ? v.floating : cast(double)v.integer;
    }
    double[] attr(string tool, string a) {
        auto r = postJson("/api/command", "tool.attr " ~ tool ~ " " ~ a ~ " ?");
        assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
        if (r["value"].type != JSONType.array) return [num(r["value"])];
        double[] v;
        foreach (c; r["value"].array) v ~= num(c);
        return v;
    }
    // Reset, select, activate `tool`; in Single press the handle `part` (or the
    // viewport centre + `at`) and drag (dx, dy); with `quad` the same gesture
    // at half scale from the bottom-right cell's corner. Returns the `reads`.
    double[] gesture(bool quad, string tool, string reset, string select, int part, int[2] at,
                     int dx, int dy, string[] reads...) {
        scope(exit) postJson("/api/command", "viewport.layout Single");
        scope(exit) postJson("/api/command", "tool.set " ~ tool ~ " off");
        command("viewport.layout Single");
        auto r = postJson("/api/command", commandBody("scene.reset", reset));
        assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
        if (select.length) {
            r = postJson("/api/command", commandBody("mesh.select", select));
            assert(r["status"].str == "ok", "select failed: " ~ r.toString);
        }
        auto full = fetchCamera();
        command("tool.set " ~ tool);
        Thread.sleep(150.msecs);
        double sx = full.vpX + full.width / 2 + at[0], sy = full.vpY + full.height / 2 + at[1];
        if (part >= 0) {   // the handle's Single pixel (the tool draws Single now)
            bool found;
            foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
                if (p["part"].integer == part && p["screen"].type == JSONType.array) {
                    sx = num(p["screen"].array[0]); sy = num(p["screen"].array[1]); found = true;
                }
            assert(found, format("%s rig: handle part %d is not on screen", tool, part));
        }
        int x = cast(int)(sx + 0.5), y = cast(int)(sy + 0.5);
        if (quad) {
            command("viewport.layout Quad");
            Thread.sleep(150.msecs);
            x = full.vpX + full.width / 2 + cast(int)((sx - full.vpX) / 2 + 0.5);
            y = full.vpY + full.height / 2 + cast(int)((sy - full.vpY) / 2 + 0.5);
            dx /= 2; dy /= 2;
        }
        playAndWait(buildDragLog(full.vpX, full.vpY, full.width, full.height, x, y, x + dx, y + dy, 12));
        double[] v;
        foreach (a; reads) v ~= attr(tool, a);
        return v;
    }
    string[] failed;
    {   // the pen: a click at the cell's centre lands on its focus
        auto p = gesture(true, "pen", `{"empty":true}`, "", -1, [0, 0], 0, 0,
                         "currentPoint", "posX", "posY", "posZ");
        // A refused click keeps the reset state (point -1 at zeros): the point must exist.
        if (!(p[0] >= 0))
            failed ~= format("pen: the click in the cell placed no point (currentPoint %s)", p[0]);
        else if (!(p[1] * p[1] + p[2] * p[2] + p[3] * p[3] < 0.05 * 0.05))
            failed ~= format("pen: the click must land on the cell's focus, got %s", p);
    }
    // The Single result first (the rig's own check), then the bottom-right cell.
    void family(string tool, string select, int part, int[2] at, int dx, int dy, string read,
                double floor) {
        auto s = gesture(false, tool, `{"type":"cube"}`, select, part, at, dx, dy, read);
        double mag = 0, d = 0;
        foreach (c; s) mag += c * c;
        assert(mag > floor * floor, format("%s rig: the Single gesture left %s at %s", tool, read, s));
        auto q = gesture(true, tool, `{"type":"cube"}`, select, part, at, dx, dy, read);
        foreach (i, c; s) d += (q[i] - c) * (q[i] - c);
        if (!(d < 0.1 * 0.1 * mag))
            failed ~= format("%s: the bottom-right press gave %s %s, Single %s", tool, read, q, s);
    }
    family("poly.extrude", `{"mode":"polygons","indices":[2]}`, 0, [0, 0], 0, -40, "distance", 0.01);
    family("mesh.mirrorTool", "", -1, [120, 0], 0, 0, "center", 0.1);
    assert(failed.length == 0, format("%-(%s\n%)", failed));
}
