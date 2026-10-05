// test_preview_rebuild_topology_tools.d — wave-2 PV2, the wire half of the
// five tools that joined `tools/edit/preview_rebuild.d` (edge extrude, polygon
// extrude, vertex bevel, vertex extrude, polygon inset).
//
// THE LAW. A position-only scrub keeps the created topology standing: after
// the arming write (one full rebuild), N more writes deliver N changes and NOT
// ONE of them is a Polygons-class delivery (`totalPolygons`, the counter a full
// rebuild moves — a moved topology is what drops the subpatch preview to the
// cage). Before PV2 each write tore the topology down and rebuilt it: the
// same scrub read `totalPolygons` += N.
//
// HOW THE PREVIEW IS DRIVEN: `/api/script?interactive=true`, the one wire
// spelling that reaches `notifyInteractiveParamChanged` (see
// tests/test_edge_extend_preview_seam.d for why `/api/command` cannot).
// ANTI-VACUITY: the arming write grew the mesh, the N writes delivered exactly
// N changes and moved the vertices, and the vertex count did not move.

import http_client : testBaseUrl, getJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;
enum int kWrites = 8;

JSONValue postTo(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}
void cmd(string s) {
    auto r = postTo("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}
void interactiveAttr(string line) {
    auto r = postTo("/api/script?interactive=true", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "interactive script line `" ~ line ~ "` failed: " ~ r.toString);
}
long counter(JSONValue a, JSONValue b, string key) {
    return b[key].integer - a[key].integer;
}

/// A motionless click near the cell's corner: the run of a tool whose
/// operation opens at its first press starts here (a panel value written
/// before it only sets the attribute).
void firstPress() {
    auto c = getJson("/api/camera");
    immutable long x = c["vpX"].integer + 30, y = c["vpY"].integer + 30;
    string ev = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                       c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer) ~ "\n"
        ~ format(`{"t":20,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, x, y) ~ "\n"
        ~ format(`{"t":40,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, x, y) ~ "\n"
        ~ format(`{"t":60,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, x, y) ~ "\n";
    auto r = postTo("/api/play-events", ev);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) break;
        Thread.sleep(50.msecs);
    }
    quiesce();
}

void scrubCell(string id, string mode, string[2][] fixed, string param,
               bool pressFirst = false) {
    cmd(commandBody("scene.reset", `{"type":"cube"}`));
    cmd(commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":[0]}`));
    cmd("tool.set " ~ id ~ " on");
    quiesce();
    if (pressFirst) firstPress();
    foreach (f; fixed) interactiveAttr(format("tool.attr %s %s %s", id, f[0], f[1]));
    interactiveAttr(format("tool.attr %s %s 0.1000", id, param));
    quiesce();
    auto armed = getJson("/api/model");
    immutable long verts = armed["vertexCount"].integer;
    assert(verts > 8, id ~ ": the arming write built nothing (V=" ~ verts.to!string ~ ")");

    auto b = getJson("/api/changes");
    foreach (i; 1 .. kWrites + 1)
        interactiveAttr(format("tool.attr %s %s %.4f", id, param, 0.10 + 0.01 * i));
    quiesce();
    auto a = getJson("/api/changes");
    auto after = getJson("/api/model");

    assert(after["vertexCount"].integer == verts,
        id ~ ": a position-only scrub changed the vertex count");
    assert(after["vertices"] != armed["vertices"],
        id ~ ": the scrub moved no vertex — every zero below would be free");
    assert(counter(b, a, "deliveryCount") == kWrites,
        format("%s: %d writes delivered %d change(s), expected one each", id,
               kWrites, counter(b, a, "deliveryCount")));
    assert(counter(b, a, "totalPolygons") == 0,
        format("%s: a position-only scrub of %d writes took %d full rebuild(s); "
             ~ "the topology key held, so every write must be a placement", id,
               kWrites, counter(b, a, "totalPolygons")));
    assert(counter(b, a, "opLogEntriesRecorded") == 0,
        id ~ ": the preview recorded op-log entries (it must stay unrecorded)");
    cmd("tool.set " ~ id ~ " off");
}

unittest { scrubCell("edge.extrude", "edges", [["width", "0.1"]], "extrude"); }
unittest { scrubCell("poly.extrude", "polygons", [], "distance", true); }
unittest { scrubCell("mesh.vertexBevel", "vertices", [], "inset"); }
unittest { scrubCell("mesh.vertexExtrude", "vertices", [["width", "0.1"]], "shift"); }
unittest { scrubCell("mesh.polyInsetTool", "polygons", [], "inset", true); }
