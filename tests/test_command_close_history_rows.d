// Golden history rows around a command that meets a live tool edit (slice M2 of
// the tool session model, doc/tool_session_model_plan_2026-09-24.md R4.2
// witness 1, R5 item 1; opponent R3 condition C5).
//
// Twelve cells: tool {TransformMove, poly.bevel, edge.extend} x path {script
// `mesh.subpatch_toggle` (the pre-apply commit branch), script
// `mesh.subdivide` (a Model command: the pre-apply drop branch), script
// `mesh.select` (UiState: neither branch), `tool.set <id> off` (the drop
// door)}. Each cell arms the tool on an empty history, makes a live edit by
// real input (a haul with release; TransformMove hauls twice off the handle,
// and each haul records its own non-session row, so the run is CLOSED between
// the hauls — `runOpen` false in the recording; which is why moving the
// 6250 close ahead of the drop door (mutation m2-rows-a) cannot move a row
// here, card M2 PF-7), runs the path and dumps {undo rows, active tool,
// vertex digest, the tool's published state}. Every path here is a SCRIPT door
// or the drop door, which M2 must leave exactly as it was: the file is the
// witness that moving the close into `EditSession.closeOperation` changed no
// row on them.
//
// The fixture tests/fixtures/command_close_history_rows.json was RECORDED on
// the slice's parent (main daefbc0f, the M1 tip) before any code change, by
// VIBE3D_RECORD_GOLDEN=1. That mode writes the file and then FAILS ("recorded,
// not verified"), so a stray variable cannot turn this witness into a no-op; a
// missing fixture fails too, it is never created by a verifying run.
//
// Lifetime (which later slice may re-record which cell — on that slice's
// PARENT, with the read diff in its card; any other change is a regression):
//   * the four `poly.bevel` cells — M3b (Bevel's activation row and gesture
//     steps join the session);
//   * the four `edge.extend` cells — M4 (Edge Extend's run record and token
//     move into the session);
//   * the four `TransformMove` cells — no slice of this wave.
//
// Canonical form, so the comparison is byte-for-byte over what the law is
// about and not over process history: `runId` / `tweakGen` are renumbered by
// first appearance within the cell (they are process-global counters), and
// every number is printed at 4 decimals (hauls are pixel-derived).

import http_client : getJson, postJson;
import ssh = symmetry_selection_helpers;
import eeh = edge_extend_gesture_helpers;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : sort;
import std.array : array, join;
import std.conv : to;
import std.digest.crc : crc32Of, toHexString;
import std.file : exists, readText, write;
import std.format : format;
import std.json;
import std.path : buildPath, dirName;
import std.process : environment;
import std.regex : regex, replaceAll;
import std.stdio : writeln, stdout;

void main() {}

private enum string kFixture = "fixtures/command_close_history_rows.json";
private string fixturePath() {
    return buildPath(dirName(__FILE_FULL_PATH__), kFixture);
}

private void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "golden rows: `" ~ line ~ "` failed: " ~ r.toString);
}

private void settle(int ms = 150) { Thread.sleep(ms.msecs); }

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        case JSONType.float_:   return v.floating;
        default: assert(false, "golden rows: expected a number, got " ~ v.toString);
    }
}

private string f4(double d) {
    auto s = format("%.4f", d);
    return s == "-0.0000" ? "0.0000" : s;
}

private string toolId() {
    auto s = getJson("/api/tool/state");
    return (s.type == JSONType.object && "tool" in s.object) ? s["tool"].str : "";
}

// ---- the dump -----------------------------------------------------------------

private string canonArgs(string args) {
    // Round every decimal literal to 4 places.
    static rx = regex(`-?[0-9]+\.[0-9]+(e-?[0-9]+)?`);
    import std.regex : Captures;
    return args.replaceAll!((Captures!string m) => f4(m.hit.to!double))(rx);
}

private JSONValue canonRows(JSONValue[] rows) {
    long[long] runIds, gens;
    long canon(ref long[long] map, long v) {
        if (v == 0) return 0;
        if (auto p = v in map) return *p;
        return map[v] = cast(long) map.length + 1;
    }
    JSONValue[] out_;
    foreach (r; rows) {
        auto o = JSONValue.emptyObject;
        o["label"]     = r["label"];
        o["command"]   = r["command"];
        o["args"]      = JSONValue(canonArgs(r["args"].str));
        o["flags"]     = r["flags"];
        o["ui"]        = r["ui"];
        o["inSession"] = r["inSession"];
        o["refire"]    = r["refire"];
        o["runId"]     = JSONValue(canon(runIds, r["runId"].integer));
        o["tweakGen"]  = JSONValue(canon(gens, r["tweakGen"].integer));
        o["opInverse"] = r["opInverse"];
        out_ ~= o;
    }
    return JSONValue(out_);
}

private string vertexDigest() {
    auto vs = getJson("/api/model")["vertices"].array;
    string s;
    foreach (v; vs) {
        auto a = v.array;
        s ~= f4(num(a[0])) ~ "," ~ f4(num(a[1])) ~ "," ~ f4(num(a[2])) ~ ";";
    }
    return format("%d:%s", vs.length, toHexString(crc32Of(s)));
}

private JSONValue panel(string tool) {
    auto s = getJson("/api/tool/state");
    auto o = JSONValue.emptyObject;
    if (s.type != JSONType.object || !("tool" in s.object)) return o;
    string[] keys;
    final switch (tool) {
        case "TransformMove": {
            // No TX/RX/SX readout exists on /api/tool/state (plan R4.2 named
            // them; PLAN-FINDING in the card): the run/session bits and the
            // handle pose are what the tool publishes.
            foreach (k; ["editOpen", "sessionOpen", "runOpen"]) o[k] = s[k];
            auto p = s["pivot"].array;
            o["pivot"] = JSONValue(f4(num(p[0])) ~ "," ~ f4(num(p[1])) ~ "," ~ f4(num(p[2])));
            return o;
        }
        case "poly.bevel":  keys = ["shift", "inset"]; break;
        case "edge.extend": keys = ["offsetX", "offsetY", "offsetZ"]; break;
    }
    foreach (k; keys) o[k] = JSONValue(f4(num(s[k])));
    return o;
}

private JSONValue dump(string tool) {
    auto d = JSONValue.emptyObject;
    d["undo"]  = canonRows(getJson("/api/history")["undo"].array);
    d["tool"]  = JSONValue(toolId());
    d["verts"] = JSONValue(vertexDigest());
    d["panel"] = panel(tool);
    return d;
}

// ---- rigs: arm on an empty history, then a live edit by real input ---------------

private void liveMove() {
    ssh.rig();                                  // cube, vertex mode, empty history
    ssh.selectVerts([6, 7]);
    cmd("history.clear");
    cmd("tool.set TransformMove on");
    settle(300);
    ssh.assertOffHandle([0.5, -0.3, 0.5], "golden Move haul");
    ssh.haul([0.5, -0.3, 0.5], 8, 0, 5);
    ssh.haul([0.5, -0.3, 0.5], 0, -8, 4);       // second gesture: the run stays open
    assert(toolId() == "xfrm", "golden rows rig: Move is not armed after its hauls");
}

private void liveBevel() {
    cmd(`{"id":"scene.reset"}`);
    cmd(`{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`);
    cmd("history.clear");
    cmd("tool.set poly.bevel on");
    settle(300);
    int sx, sy;
    bool found;
    foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
        if (p["part"].integer == 0) {
            sx = cast(int)(num(p["screen"].array[0]) + 0.5);
            sy = cast(int)(num(p["screen"].array[1]) + 0.5);
            found = true;
        }
    assert(found, "golden rows rig: the bevel Shift handle is not published");
    ssh.haulPx(sx, sy, -20, -35, 3);
    auto st = getJson("/api/tool/state");
    assert(st["tool"].str == "polyBevel" && num(st["shift"]) > 1e-4,
           "golden rows rig: the bevel haul did not write a shift: " ~ st.toString);
}

private void liveExtend() {
    cmd(`{"id":"scene.reset"}`);
    eeh.loadPlaneRig();
    eeh.setSymmetryX(false);
    eeh.selectEdges(eeh.edgesOf([[6, 7], [7, 8]]));
    cmd("viewport.view Top");
    auto r = postJson("/api/camera", `{"focus":{"x":0.5,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "golden rows rig: camera focus failed: " ~ r.toString);
    cmd("history.clear");
    cmd("tool.set edge.extend on");
    settle(250);
    eeh.haul(eeh.haulPx(), eeh.kIncrementPx, 0, 10);
    assert(toolId() == "edgeExtend", "golden rows rig: Edge Extend is not armed after its haul");
}

private string armedId(string tool) {
    final switch (tool) {
        case "TransformMove": return "TransformMove";
        case "poly.bevel":    return "poly.bevel";
        case "edge.extend":   return "edge.extend";
    }
}

private void runPath(string tool, string path) {
    final switch (path) {
        case "subpatch_toggle": cmd("mesh.subpatch_toggle"); break;
        case "subdivide":       cmd("mesh.subdivide"); break;
        case "select":
            final switch (tool) {
                case "TransformMove":
                    cmd(`{"id":"mesh.select","params":{"mode":"vertices","indices":[0]}}`); break;
                case "poly.bevel":
                    cmd(`{"id":"mesh.select","params":{"mode":"polygons","indices":[1]}}`); break;
                case "edge.extend":
                    cmd(`{"id":"mesh.select","params":{"mode":"edges","indices":[0]}}`); break;
            }
            break;
        case "off": cmd("tool.set " ~ armedId(tool) ~ " off"); break;
    }
    settle(250);
}

unittest {
    immutable string[] tools = ["TransformMove", "poly.bevel", "edge.extend"];
    immutable string[] paths = ["subpatch_toggle", "subdivide", "select", "off"];
    JSONValue got = JSONValue.emptyObject;
    size_t cells;
    foreach (tool; tools)
        foreach (path; paths) {
            final switch (tool) {
                case "TransformMove": liveMove();   break;
                case "poly.bevel":    liveBevel();  break;
                case "edge.extend":   liveExtend(); break;
            }
            runPath(tool, path);
            got[tool ~ " x " ~ path] = dump(tool);
            ++cells;
        }
    assert(cells == 12, format("golden rows: cell population changed: %d, expected 12", cells));

    if (environment.get("VIBE3D_RECORD_GOLDEN", "") == "1") {
        // The provenance block is carried over from the file being replaced.
        if (exists(fixturePath())) {
            auto old = parseJSON(readText(fixturePath()));
            if (auto p = "provenance" in old.object) got["provenance"] = *p;
        }
        write(fixturePath(), got.toPrettyString ~ "\n");
        assert(false, "golden rows: RECORDED " ~ fixturePath() ~ " (" ~ cells.to!string
               ~ " cells), not verified — unset VIBE3D_RECORD_GOLDEN and run again");
    }
    assert(exists(fixturePath()),
           "golden rows: fixture " ~ fixturePath() ~ " is missing; it is recorded on the slice's "
           ~ "parent with VIBE3D_RECORD_GOLDEN=1, never created by a verifying run");
    auto want = parseJSON(readText(fixturePath()));
    assert("provenance" in want.object, "golden rows: the fixture lost its provenance block");
    want.object.remove("provenance");
    assert(want.object.length == 12,
           format("golden rows: the fixture holds %d cells, expected 12", want.object.length));
    string[] red;
    foreach (key; got.object.keys.sort.array) {
        auto w = key in want.object;
        if (w is null) { red ~= key ~ ": not in the fixture"; continue; }
        if ((*w).toString != got[key].toString)
            red ~= key ~ ":\n    want " ~ (*w).toString ~ "\n    got  " ~ got[key].toString;
    }
    writeln(format("[test_command_close_history_rows] cells %d, differing %d", cells, red.length));
    stdout.flush();
    assert(red.length == 0, format("golden rows: %d of 12 cells differ from the recording:\n  %s",
                                   red.length, red.join("\n  ")));
}
