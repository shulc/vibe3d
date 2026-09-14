// Task 5911, Phase 4a: short-face census plus the two emitted-origin walks.
// The default subdivision refusal remains the recorded baseline in this phase;
// Phase 4b owns the split and the subpatch-toggle skip.

import core.thread : Thread;
import core.time : msecs;
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : fabs;
import std.path : buildPath;
import std.process : thisProcessID;
import std.stdio : writeln;
import std.string : startsWith;
import std.uuid : randomUUID;

void main() {}

private enum string kHeader =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2,"type":"SDL_WINDOWEVENT","sub":3}`;

private JSONValue fixture() {
    return parseJSON(import("fixtures/subdivide_short_face.json"));
}

private JSONValue model() { return getJson("/api/model"); }

private int[] sel() {
    int[] r;
    foreach (v; getJson("/api/selection")["selectedFaces"].array)
        r ~= cast(int) v.integer;
    return r;
}

private struct Hist { long length; string[] labels; }

private Hist hist() {
    Hist h;
    foreach (e; getJson("/api/history")["undo"].array) {
        ++h.length;
        h.labels ~= e["label"].str;
    }
    return h;
}

private struct Preview { bool active; long faces; }

private Preview preview(string id) {
    foreach (_; 0 .. 150) {
        auto j = getJson("/api/subpatch/preview");
        if (j["pending"].type != JSONType.true_) {
            Preview p;
            p.active = j["active"].type == JSONType.true_;
            p.faces = j["previewFaces"].integer;
            return p;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, id ~ ": preview remained pending for more than 3 seconds");
}

private JSONValue cmdJson(string line, string suffix = "") {
    return postJson("/api/command" ~ suffix, line);
}

private JSONValue ok(string line, string id) {
    auto j = cmdJson(line);
    assert(j["status"].str == "ok", id ~ ": command failed: " ~ j.toString);
    return j;
}

private void waitPlayback(string id) {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.true_) {
            Thread.sleep(100.msecs);
            return;
        }
        Thread.sleep(30.msecs);
    }
    assert(false, id ~ ": event playback did not finish");
}

private void play(string log, string id) {
    auto j = postJson("/api/play-events", kHeader ~ "\n" ~ log);
    assert(j["status"].str == "success", id ~ ": playback refused: " ~ j.toString);
    waitPlayback(id);
}

private void key(int sym, int scan, string id) {
    play(format(
        `{"t":20,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}` ~ "\n"
      ~ `{"t":30,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
        sym, scan, sym, scan), id);
}

private string click(double t, int x, int y) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t, x, y, t + 5, x, y, t + 10, x, y);
}

private long number(JSONValue v) {
    return v.type == JSONType.integer ? v.integer : cast(long) v.uinteger;
}

private double decimal(JSONValue v) {
    switch (v.type) {
    case JSONType.float_: return v.floating;
    case JSONType.integer: return cast(double) v.integer;
    case JSONType.uinteger: return cast(double) v.uinteger;
    default: assert(false, "expected a number, got " ~ v.toString);
    }
}

private string counts(JSONValue m) {
    return format("%d/%d/%d", m["vertexCount"].integer,
                  m["edgeCount"].integer, m["faceCount"].integer);
}

private string modelSig(JSONValue m) {
    return m["vertices"].toString ~ "|" ~ m["edges"].toString ~ "|"
         ~ m["faces"].toString ~ "|" ~ m["isSubpatch"].toString;
}

private bool samePos(JSONValue v, double x, double y, double z) {
    auto a = v.array;
    return fabs(decimal(a[0]) - x) < 1e-6
        && fabs(decimal(a[1]) - y) < 1e-6
        && fabs(decimal(a[2]) - z) < 1e-6;
}

private bool[] flags(JSONValue m) {
    bool[] r;
    foreach (v; m["isSubpatch"].array) r ~= v.type == JSONType.true_;
    return r;
}

private size_t[int] cornerHistogram(JSONValue m) {
    size_t[int] r;
    foreach (f; m["faces"].array) ++r[cast(int) f.array.length];
    return r;
}

private size_t repeatedCornerFaces(JSONValue m) {
    size_t n;
    foreach (f; m["faces"].array) {
        long[] seen;
        bool repeated;
        foreach (v; f.array) {
            if (seen.canFind(v.integer)) repeated = true;
            seen ~= v.integer;
        }
        if (repeated) ++n;
    }
    return n;
}

private bool hasValueStartingWith(JSONValue v, string prefix) {
    switch (v.type) {
    case JSONType.string: return v.str.startsWith(prefix);
    case JSONType.array:
        foreach (x; v.array) if (hasValueStartingWith(x, prefix)) return true;
        return false;
    case JSONType.object:
        foreach (_, x; v.object) if (hasValueStartingWith(x, prefix)) return true;
        return false;
    default: return false;
    }
}

private JSONValue cell(JSONValue fx, string id) {
    foreach (c; fx["cells"].array)
        if (c["id"].str == id) return c;
    assert(false, "fixture cell missing: " ~ id);
}

private struct Mismatch {
    string cell;
    string key;
    string want;
    string got;
}

private size_t leafCount(JSONValue value) {
    if (value.type == JSONType.object) {
        size_t count;
        foreach (_, child; value.object) count += leafCount(child);
        return count;
    }
    return 1;
}

private void compareExpected(string id, JSONValue want, JSONValue got,
                             ref Mismatch[] rows, ref size_t comparedLeaves,
                             string prefix = "") {
    if (want.type == JSONType.object) {
        if (got.type != JSONType.object) {
            comparedLeaves += leafCount(want);
            rows ~= Mismatch(id, prefix, want.toString, got.toString);
            return;
        }
        foreach (key, value; want.object) {
            const path = prefix.length ? prefix ~ "." ~ key : key;
            auto found = key in got.object;
            if (found is null) {
                comparedLeaves += leafCount(value);
                rows ~= Mismatch(id, path, value.toString, "<missing>");
                continue;
            }
            compareExpected(id, value, *found, rows, comparedLeaves, path);
        }
        return;
    }
    ++comparedLeaves;
    if (want != got)
        rows ~= Mismatch(id, prefix, want.toString, got.toString);
}

private JSONValue activeExpected(JSONValue c) {
    JSONValue[string] out_;
    const status = c["port_status"].str;
    assert(status == "census" || status == "implemented",
           c["id"].str ~ ": active cell has unsupported port_status " ~ status);
    const baseKey = status == "census" ? "census" : "expect";
    assert(baseKey in c && c[baseKey].type == JSONType.object,
           c["id"].str ~ ": missing active " ~ baseKey ~ " object");
    foreach (key, value; c[baseKey].object) out_[key] = value;

    if ("key_kinds" in c) foreach (key, kind; c["key_kinds"].object) {
        if (status == "census" && kind.str != "census") {
            assert("expect" in c && key in c["expect"],
                   c["id"].str ~ ": key_kinds parity key missing from expect: " ~ key);
            out_[key] = c["expect"][key];
        } else if (status == "implemented" && kind.str == "census") {
            const censusKey = "census4a" in c ? "census4a" : "census";
            assert(censusKey in c && key in c[censusKey],
                   c["id"].str ~ ": key_kinds census key missing: " ~ key);
            out_[key] = c[censusKey][key];
        }
    }
    return JSONValue(out_);
}

private void compareCell(ref string[] bad, JSONValue fx, string id,
                         JSONValue got) {
    Mismatch[] rows;
    size_t comparedLeaves;
    compareExpected(id, activeExpected(cell(fx, id)), got, rows, comparedLeaves);
    assert(comparedLeaves > 0, id ~ ": fixture comparison read no leaves");
    foreach (row; rows)
        bad ~= format("%s | %s | want %s | got %s",
                      row.cell, row.key, row.want, row.got);
}

private void check(ref string[] bad, bool yes, string id, string detail) {
    if (!yes) bad ~= id ~ " | " ~ detail;
}

private JSONValue meshRead(JSONValue m) {
    JSONValue[string] out_;
    out_["v"] = m["vertexCount"];
    out_["e"] = m["edgeCount"];
    out_["f"] = m["faceCount"];
    return JSONValue(out_);
}

private JSONValue selectedRead(int[] selected) {
    JSONValue[] out_;
    foreach (fi; selected) out_ ~= JSONValue(cast(long) fi);
    return JSONValue(out_);
}

private JSONValue flagsRead(bool[] values) {
    JSONValue[] out_;
    foreach (value; values) out_ ~= JSONValue(value);
    return JSONValue(out_);
}

private JSONValue histogramRead(JSONValue m) {
    JSONValue[string] out_;
    foreach (corners, count; cornerHistogram(m))
        out_[corners.to!string] = JSONValue(cast(long) count);
    return JSONValue(out_);
}

private JSONValue shortFacesRead(JSONValue m) {
    JSONValue[] out_;
    foreach (face; m["faces"].array) {
        if (face.array.length >= 3) continue;
        JSONValue[] positions;
        foreach (vi; face.array)
            positions ~= m["vertices"].array[cast(size_t) number(vi)];
        positions.sort!((a, b) => a.toString < b.toString);
        out_ ~= JSONValue(positions);
    }
    out_.sort!((a, b) => a.toString < b.toString);
    return JSONValue(out_);
}

private JSONValue indexedPositions(JSONValue m, JSONValue keys) {
    JSONValue[string] out_;
    foreach (key, _; keys.object)
        out_[key] = m["vertices"].array[key.to!size_t];
    return JSONValue(out_);
}

private JSONValue holdersOfShortPair(JSONValue m) {
    long a = -1, b = -1;
    foreach (face; m["faces"].array) if (face.array.length == 2) {
        a = number(face.array[0]);
        b = number(face.array[1]);
        break;
    }
    JSONValue[] holders;
    if (a < 0) return JSONValue(holders);
    foreach (face; m["faces"].array) {
        if (face.array.length < 3 || !face.array.canFind(JSONValue(a))
            || !face.array.canFind(JSONValue(b))) continue;
        bool adjacent;
        foreach (i, vi; face.array) if (number(vi) == a) {
            adjacent = number(face.array[(i + 1) % $]) == b
                    || number(face.array[(i + $ - 1) % $]) == b;
            break;
        }
        JSONValue[string] holder;
        holder["vertices"] = face;
        holder["corners"] = JSONValue(cast(long) face.array.length);
        holder["vertexBetweenEndpointsIsEndpoint"] = JSONValue(adjacent);
        holders ~= JSONValue(holder);
    }
    return JSONValue(holders);
}

private void checkMesh(ref string[] bad, JSONValue m, JSONValue want,
                       string id) {
    const got = counts(m);
    const exp = format("%d/%d/%d", number(want["v"]),
                       number(want["e"]), number(want["f"]));
    check(bad, got == exp, id, "mesh " ~ got ~ " != " ~ exp);
}

private void checkHistDelta(ref string[] bad, Hist before, Hist after,
                            long want, string id) {
    check(bad, after.length - before.length == want, id,
          format("undo delta %d != %d", after.length - before.length, want));
}

private void resetCube(string id) {
    ok(commandBody("scene.reset"), id);
    ok("select.typeFrom polygon", id);
    ok("select.drop polygon", id);
    ok(`{"id":"history.clear"}`, id);
    assert(counts(model()) == "8/12/6", id ~ ": cube floor failed");
    assert(sel().length == 0, id ~ ": cube selection floor failed");
}

private void free2(string id) {
    ok(commandBody("scene.reset"), id);
    ok(`{"id":"mesh.addVertex","params":{"pos":[2,0,0]}}`, id);
    assert(counts(model()) == "9/12/6", id ~ ": first add floor failed");
    ok(`{"id":"mesh.addVertex","params":{"pos":[3,0,0]}}`, id);
    assert(counts(model()) == "10/12/6", id ~ ": second add floor failed");
    ok("select.typeFrom vertex", id);
    ok("select.element vertex set 8 9", id);
    ok(`{"id":"mesh.makePolygon"}`, id);
    auto m = model();
    assert(counts(m) == "10/13/7", id ~ ": free2 topology floor failed");
    auto f = m["faces"].array[$ - 1].array;
    assert(f.length == 2 && f[0].integer == 8 && f[1].integer == 9,
           id ~ ": free2 face floor failed: " ~ f.to!string);
    ok("select.typeFrom polygon", id);
    ok("select.drop polygon", id);
    assert(sel().length == 0, id ~ ": free2 selection floor failed");
    ok(`{"id":"history.clear"}`, id);
}

private void diagonal2(string id, bool drop = true) {
    ok(commandBody("scene.reset"), id);
    ok("select.typeFrom vertex", id);
    ok("select.element vertex set 0 6", id);
    ok(`{"id":"mesh.makePolygon"}`, id);
    auto m = model();
    assert(counts(m) == "8/13/7", id ~ ": diag2 topology floor failed");
    auto f = m["faces"].array[6].array;
    assert(f.length == 2 && f[0].integer == 0 && f[1].integer == 6,
           id ~ ": diag2 face floor failed: " ~ f.to!string);
    assert(sel() == [6], id ~ ": diag2 product selection floor failed");
    if (drop) {
        ok("select.drop polygon", id);
        ok(`{"id":"history.clear"}`, id);
    }
}

private void edge2(string id, bool drop = true) {
    ok(commandBody("scene.reset"), id);
    ok("select.typeFrom vertex", id);
    ok("select.element vertex set 0 3", id);
    ok(`{"id":"mesh.makePolygon"}`, id);
    auto m = model();
    assert(counts(m) == "8/12/7", id ~ ": edge2 topology floor failed");
    auto f = m["faces"].array[6].array;
    assert(f.length == 2 && f[0].integer == 0 && f[1].integer == 3,
           id ~ ": edge2 face floor failed: " ~ f.to!string);
    if (drop) {
        ok("select.drop polygon", id);
        ok(`{"id":"history.clear"}`, id);
    }
}

private __gshared string gTmpRoot;

private string tmp(string name) {
    if (!gTmpRoot.length) {
        gTmpRoot = buildPath(tempDir(), format("vibe3d-shortface-%s-%d",
            randomUUID().toString, thisProcessID));
        mkdirRecurse(gTmpRoot);
    }
    return buildPath(gTmpRoot, name);
}

private void cleanupTmp() nothrow {
    auto p = gTmpRoot;
    gTmpRoot = null;
    if (p.length && exists(p)) try rmdirRecurse(p); catch (Exception) {}
}

shared static ~this() { cleanupTmp(); }

private void loadV3d(JSONValue fx, string rig, string id) {
    auto path = tmp(rig ~ "-" ~ randomUUID().toString ~ ".v3d");
    auto envelope = parseJSON(`{"formatVersion":8,"primaryLayer":0,"layers":[]}`);
    auto layer = parseJSON(`{"type":"mesh","selected":true,"channels":{"name":"Short","visible":true},"mesh":{}}`);
    layer["mesh"] = fx["rig_v3d"][rig];
    envelope["layers"] = JSONValue([layer]);
    write(path, envelope.toString);
    ok(format(`{"id":"file.load","path":%s}`, JSONValue(path).toString), id);
    ok("select.typeFrom polygon", id);
    ok("select.drop polygon", id);
    auto loaded = model();
    assert(counts(loaded) == "8/13/7", id ~ ": v3d rig topology floor failed");
    assert(flagsRead(flags(loaded)) == fx["rig_v3d"][rig]["faceSubpatch"],
           id ~ ": v3d rig isSubpatch floor failed: "
           ~ flagsRead(flags(loaded)).toString);
    ok(`{"id":"history.clear"}`, id);
}

private void walkRig(string id) {
    diagonal2(id, false);
    ok("select.typeFrom vertex", id);
    ok("select.element vertex set 1 4 5", id);
    ok(`{"id":"mesh.makePolygon"}`, id);
    auto m = model();
    assert(counts(m) == "8/14/8", id ~ ": walk topology floor failed");
    auto f = m["faces"].array[7].array;
    assert(f.length == 3 && f[0].integer == 5 && f[1].integer == 4
           && f[2].integer == 1, id ~ ": walk triangle floor failed: " ~ f.to!string);
    ok("select.typeFrom polygon", id);
    ok("select.element polygon set 0 6", id);
    assert(sel() == [0, 6], id ~ ": walk selection floor failed");
    ok(`{"id":"history.clear"}`, id);
}

private void pen3(string id) {
    resetCube(id);
    ok("tool.set \"pen\" on 0", id);
    play(click(100, 425, 250) ~ "\n" ~ click(200, 525, 250) ~ "\n"
       ~ click(300, 475, 350), id);
    assert(counts(model()) == "8/12/6", id ~ ": live pen wrote before its door");
    assert(hist().length == 0, id ~ ": live pen wrote history before its door");
}

private void selectFace(int fi, string id) {
    ok("select.element polygon set " ~ fi.to!string, id);
    assert(sel() == [fi], id ~ ": face-selection floor failed");
    ok(`{"id":"history.clear"}`, id);
}

private void verifyFixture(JSONValue fx) {
    string[] executed, planned;
    foreach (c; fx["cells"].array) {
        assert("pending_capture" !in c, c["id"].str ~ ": pending capture shipped");
        if (c["port_status"].str == "planned") planned ~= c["id"].str;
        else executed ~= c["id"].str;
        if (c["port_status"].str == "implemented") {
            assert("expect" in c && c["expect"].type != JSONType.null_,
                   c["id"].str ~ ": implemented without an expectation");
            assert(!hasValueStartingWith(c["expect"], "<"),
                   c["id"].str ~ ": placeholder expectation shipped");
        }
    }
    auto wantExecuted = [
        "SD-R/api", "SD-R/api-diag", "SD-R/key", "SD-R/ui", "SD-C",
        "SD-T", "SD-T/flat", "SD-2c", "SD-2c/flat", "SD-2g",
        "SD-2g/flat", "SD-flat", "SD-smooth", "SD-adj", "SD-adj/flat",
        "SD-U30", "SD-U30/flat", "SD-W/flat", "SD-W/smooth", "SD-P",
        "SD-P/tab", "SD-Ps", "SD-Ps/tab", "SD-Psb", "SD-X"];
    auto wantPlanned = ["SD-5last", "SD-5first", "SD-5last/flat",
        "SD-5first/flat", "SD-5last/smooth", "SD-5first/smooth", "SD-5"];
    executed.sort; planned.sort; wantExecuted.sort; wantPlanned.sort;
    assert(executed == wantExecuted, "executed fixture id set changed");
    assert(planned == wantPlanned, "planned fixture id set changed");
    assert(executed.length == 25 && planned.length == 7
           && fx["cells"].array.length == 32,
           "fixture population must be 25 executed + 7 planned = 32");
}

unittest {
    auto fx = fixture();
    verifyFixture(fx);
    string[] bad;

    auto selfWant = parseJSON(`{"isSubpatch1":[true]}`);
    auto selfGot = parseJSON(`{"isSubpatch1":[false]}`);
    Mismatch[] selfRows;
    size_t selfLeaves;
    compareExpected("SD-FIXTURE-EDIT-SELF-CHECK", selfWant, selfGot,
                    selfRows, selfLeaves);
    assert(selfRows.length == 1 && selfRows[0].cell == "SD-FIXTURE-EDIT-SELF-CHECK"
           && selfRows[0].key == "isSubpatch1" && selfLeaves == 1,
           "fixture-edit self-check must name the changed fixture key");

    foreach (spec; [["SD-R/api", "free"], ["SD-R/api-diag", "diag"]]) {
        if (spec[1] == "free") free2(spec[0]); else diagonal2(spec[0]);
        auto before = modelSig(model()); auto h0 = hist();
        auto r = cmdJson(`{"id":"mesh.subdivide"}`); auto h1 = hist();
        auto after = model();
        JSONValue[string] got;
        got["status"] = r["status"];
        got["message"] = r["message"];
        got["modelUnchanged"] = JSONValue(modelSig(after) == before);
        got["undoDelta"] = JSONValue(h1.length - h0.length);
        got["mesh"] = meshRead(after);
        got["cornerHistogram"] = histogramRead(after);
        got["shortFaces"] = shortFacesRead(after);
        got["selected"] = selectedRead(sel());
        compareCell(bad, fx, spec[0], JSONValue(got));
        writeln(spec[0], " census status=", r["status"].str,
                " answer=", r.toString, " undoDelta=", h1.length - h0.length,
                " mesh=", counts(after));
    }

    resetCube("SD-R/key/control");
    auto keyControlH0 = hist();
    key(100, 7, "SD-R/key/control");
    auto keyControlH1 = hist();
    JSONValue[string] keyControl;
    keyControl["mesh"] = meshRead(model());
    keyControl["undoDelta"] = JSONValue(keyControlH1.length - keyControlH0.length);
    Mismatch[] keyControlRows; size_t keyControlLeaves;
    compareExpected("SD-R/key/control", cell(fx, "SD-R/key")["control"],
                    JSONValue(keyControl), keyControlRows, keyControlLeaves);
    foreach (row; keyControlRows)
        bad ~= format("%s | %s | want %s | got %s",
                      row.cell, row.key, row.want, row.got);
    writeln("SD-R/key control mesh=", counts(model()),
            " undoDelta=", keyControlH1.length - keyControlH0.length);

    free2("SD-R/key");
    auto keyBefore = modelSig(model()); auto keyH0 = hist();
    key(100, 7, "SD-R/key"); auto keyH1 = hist();
    JSONValue[string] keyGot;
    keyGot["modelUnchanged"] = JSONValue(modelSig(model()) == keyBefore);
    keyGot["undoDelta"] = JSONValue(keyH1.length - keyH0.length);
    keyGot["mesh"] = meshRead(model());
    compareCell(bad, fx, "SD-R/key", JSONValue(keyGot));
    writeln("SD-R/key census modelUnchanged=", modelSig(model()) == keyBefore,
            " undoDelta=", keyH1.length - keyH0.length);

    resetCube("SD-R/ui/control");
    auto uiControlH0 = hist();
    auto uiControlR = cmdJson("mesh.subdivide", "?origin=ui");
    auto uiControlH1 = hist();
    JSONValue[string] uiControl;
    uiControl["answer"] = uiControlR;
    uiControl["mesh"] = meshRead(model());
    uiControl["undoDelta"] = JSONValue(uiControlH1.length - uiControlH0.length);
    Mismatch[] uiControlRows; size_t uiControlLeaves;
    compareExpected("SD-R/ui/control", cell(fx, "SD-R/ui")["control"],
                    JSONValue(uiControl), uiControlRows, uiControlLeaves);
    foreach (row; uiControlRows)
        bad ~= format("%s | %s | want %s | got %s",
                      row.cell, row.key, row.want, row.got);
    writeln("SD-R/ui synchronous control answer=", uiControlR.toString,
            " mesh=", counts(model()),
            " undoDelta=", uiControlH1.length - uiControlH0.length);

    free2("SD-R/ui");
    auto uiBefore = modelSig(model()); auto uiH0 = hist();
    auto uiR = cmdJson("mesh.subdivide", "?origin=ui"); auto uiH1 = hist();
    JSONValue[string] uiGot;
    uiGot["answer"] = uiR;
    uiGot["status"] = uiR["status"];
    uiGot["modelUnchanged"] = JSONValue(modelSig(model()) == uiBefore);
    uiGot["undoDelta"] = JSONValue(uiH1.length - uiH0.length);
    uiGot["mesh"] = meshRead(model());
    compareCell(bad, fx, "SD-R/ui", JSONValue(uiGot));
    writeln("SD-R/ui synchronous refusal answer=", uiR.toString,
            " (uiPolicy.invoke applied synchronously; refusal became a notice)",
            " undoDelta=", uiH1.length - uiH0.length, " mesh=", counts(model()));

    resetCube("SD-C");
    auto cR = cmdJson(`{"id":"mesh.subdivide"}`); auto cM = model();
    JSONValue[string] cGot;
    cGot["status"] = cR["status"];
    cGot["mesh"] = meshRead(cM);
    compareCell(bad, fx, "SD-C", JSONValue(cGot));
    writeln("SD-C control status=", cR["status"].str, " mesh=", counts(cM));

    foreach (id; ["SD-T", "SD-T/flat"]) {
        pen3(id); auto h0 = hist();
        auto r = cmdJson(id == "SD-T" ? `{"id":"mesh.subdivide"}`
            : `{"id":"mesh.subdivide","params":{"mode":"flat"}}`);
        auto m = model(); auto h1 = hist();
        JSONValue[string] got;
        got["status"] = r["status"];
        got["mesh"] = meshRead(m);
        JSONValue[] labels;
        foreach (label; h1.labels) labels ~= JSONValue(label);
        got["undoLabels"] = JSONValue(labels);
        got["cornerHistogram"] = histogramRead(m);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " census mesh=", counts(m), " labels=", h1.labels);
    }

    foreach (id; ["SD-2c", "SD-2c/flat"]) {
        free2(id); selectFace(0, id); auto h0 = hist();
        auto r = cmdJson(id == "SD-2c" ? `{"id":"mesh.subdivide"}`
            : `{"id":"mesh.subdivide","params":{"mode":"flat"}}`);
        auto m = model(); auto h1 = hist(); auto selected = sel();
        bool shortSelected;
        foreach (fi; selected)
            if (m["faces"].array[fi].array.length < 3) shortSelected = true;
        JSONValue[string] got;
        got["status"] = r["status"];
        got["mesh"] = meshRead(m);
        got["undoDelta"] = JSONValue(h1.length - h0.length);
        got["cornerHistogram"] = histogramRead(m);
        got["shortFaces"] = shortFacesRead(m);
        got["selectedCount"] = JSONValue(cast(long) selected.length);
        got["shortFaceSelected"] = JSONValue(shortSelected);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " parity mesh=", counts(m), " histogram=", cornerHistogram(m),
                " selected=", selected, " undoDelta=", h1.length-h0.length);
    }

    free2("SD-2g"); selectFace(6, "SD-2g");
    auto gBefore = modelSig(model()); auto gH0 = hist();
    auto gR = cmdJson(`{"id":"mesh.subdivide"}`); auto gH1 = hist();
    JSONValue[string] gGot;
    gGot["status"] = gR["status"];
    gGot["modelUnchanged"] = JSONValue(modelSig(model()) == gBefore);
    gGot["undoDelta"] = JSONValue(gH1.length - gH0.length);
    gGot["mesh"] = meshRead(model());
    gGot["cornerHistogram"] = histogramRead(model());
    gGot["shortFaces"] = shortFacesRead(model());
    gGot["selected"] = selectedRead(sel());
    compareCell(bad, fx, "SD-2g", JSONValue(gGot));
    writeln("SD-2g census status=", gR["status"].str, " undoDelta=", gH1.length-gH0.length);

    free2("SD-2g/flat"); selectFace(6, "SD-2g/flat");
    auto gfBefore = modelSig(model()); auto gfH0 = hist();
    auto gfR = cmdJson(`{"id":"mesh.subdivide","params":{"mode":"flat"}}`);
    auto gfM = model(); auto gfH1 = hist();
    JSONValue[string] gfGot;
    gfGot["status"] = gfR["status"];
    gfGot["modelUnchanged"] = JSONValue(modelSig(gfM) == gfBefore);
    gfGot["undoDelta"] = JSONValue(gfH1.length - gfH0.length);
    gfGot["mesh"] = meshRead(gfM);
    gfGot["cornerHistogram"] = histogramRead(gfM);
    gfGot["selected"] = selectedRead(sel());
    compareCell(bad, fx, "SD-2g/flat", JSONValue(gfGot));
    writeln("SD-2g/flat census mesh=", counts(model()), " selected=", sel(),
            " undoDelta=", gfH1.length-gfH0.length);

    foreach (id; ["SD-flat", "SD-smooth"]) {
        free2(id); auto h0 = hist();
        auto r = cmdJson(id == "SD-flat"
            ? `{"id":"mesh.subdivide","params":{"mode":"flat"}}`
            : `{"id":"mesh.subdivide","params":{"mode":"smooth"}}`);
        auto m = model(); auto h1 = hist();
        JSONValue[string] got;
        got["status"] = r["status"];
        got["mesh"] = meshRead(m);
        got["undoDelta"] = JSONValue(h1.length - h0.length);
        got["shortFaces"] = shortFacesRead(m);
        got["cornerHistogram"] = histogramRead(m);
        if (id == "SD-smooth") {
            got["endpointsStay"] = indexedPositions(m,
                cell(fx, id)["expect"]["endpointsStay"]);
            writeln(id, " law endpoints=", m["vertices"].array[8], ",",
                    m["vertices"].array[9], " mesh=", counts(m));
        } else writeln(id, " census mesh=", counts(m));
        compareCell(bad, fx, id, JSONValue(got));
    }

    foreach (id; ["SD-adj", "SD-adj/flat"]) {
        edge2(id); selectFace(0, id); auto h0 = hist();
        auto r = cmdJson(id == "SD-adj" ? `{"id":"mesh.subdivide"}`
            : `{"id":"mesh.subdivide","params":{"mode":"flat"}}`);
        auto m = model(); auto h1 = hist(); auto selected = sel();
        bool shortSelected;
        foreach (fi; selected)
            if (m["faces"].array[fi].array.length < 3) shortSelected = true;
        JSONValue[string] got;
        got["status"] = r["status"];
        got["mesh"] = meshRead(m);
        got["undoDelta"] = JSONValue(h1.length - h0.length);
        got["cornerHistogram"] = histogramRead(m);
        got["repeatedCorner"] = JSONValue(cast(long) repeatedCornerFaces(m));
        got["shortFaces"] = shortFacesRead(m);
        got["holdersOfPair"] = holdersOfShortPair(m);
        got["selected"] = selectedRead(selected);
        got["selectedCount"] = JSONValue(cast(long) selected.length);
        got["shortFaceSelected"] = JSONValue(shortSelected);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " ", id == "SD-adj" ? "census" : "parity",
                " mesh=", counts(m), " histogram=", cornerHistogram(m),
                " repeatedCorner=", repeatedCornerFaces(m),
                " shortFaces=", shortFacesRead(m).toString,
                " holders=", holdersOfShortPair(m).toString,
                " selected=", selected);
    }

    foreach (id; ["SD-U30", "SD-U30/flat"]) {
        edge2(id); selectFace(6, id); auto before = modelSig(model()); auto h0 = hist();
        auto r = cmdJson(id == "SD-U30" ? `{"id":"mesh.subdivide"}`
            : `{"id":"mesh.subdivide","params":{"mode":"flat"}}`);
        auto m = model(); auto h1 = hist();
        JSONValue[string] got;
        got["status"] = r["status"];
        got["modelUnchanged"] = JSONValue(modelSig(m) == before);
        got["undoDelta"] = JSONValue(h1.length - h0.length);
        got["mesh"] = meshRead(m);
        got["cornerHistogram"] = histogramRead(m);
        got["selected"] = selectedRead(sel());
        got["holdersOfPair"] = holdersOfShortPair(m);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " census status=", r["status"].str, " mesh=", counts(m),
                " selected=", sel(), " undoDelta=", h1.length-h0.length);
    }

    foreach (id; ["SD-W/flat", "SD-W/smooth"]) {
        walkRig(id); auto r = cmdJson(id == "SD-W/flat"
            ? `{"id":"mesh.subdivide_faceted"}`
            : `{"id":"mesh.subdivide","params":{"mode":"smooth"}}`);
        auto m = model(); auto selected = sel();
        int triangle = -1; size_t triangleCount;
        foreach (i, f; m["faces"].array) {
            auto a = f.array;
            if (a.length == 3 && a[0].integer == 5 && a[1].integer == 4
                && a[2].integer == 1) { triangle = cast(int)i; ++triangleCount; }
        }
        JSONValue[string] got;
        got["status"] = r["status"];
        got["triangleSelected"] = JSONValue(selected.canFind(triangle));
        got["trianglePopulation"] = JSONValue(cast(long) triangleCount);
        const selectedFloor = number(cell(fx, id)["expect"]["selectedFloor"]);
        got["selectedFloor"] = JSONValue(selected.length >= selectedFloor
            ? selectedFloor : cast(long) selected.length);
        if (id == "SD-W/flat") {
            int centroid = -1;
            foreach (i, v; m["vertices"].array)
                if (samePos(v, 0,0,-0.5)) centroid = cast(int)i;
            size_t selectedChildren;
            foreach (fi; selected)
                if (m["faces"].array[fi].array.canFind(JSONValue(centroid)))
                    ++selectedChildren;
            got["face0ChildrenSelected"] = JSONValue(cast(long) selectedChildren);
        } else {
            got["cornerStays"] = indexedPositions(m,
                cell(fx, id)["expect"]["cornerStays"]);
            got["selectedCornerMoved"] = JSONValue(
                !samePos(m["vertices"].array[0], -.5,-.5,-.5));
        }
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " law triangleFace=", triangle, " selected=", selected,
                id == "SD-W/smooth" ? " corner6=" ~ m["vertices"].array[6].toString : "");
    }

    long cubePreviewFaces;
    resetCube("SD-P/control"); ok(`{"id":"mesh.subpatch_toggle"}`, "SD-P/control");
    auto cubeP = preview("SD-P/control"); cubePreviewFaces = cubeP.faces;
    auto previewControl = fx["controls"]["cubePreview"];
    assert(cubeP.active == previewControl["active"].boolean,
           "SD-P/control: fixture preview active floor failed");
    assert((cubeP.faces > 0) == previewControl["facesPositive"].boolean,
           format("SD-P/control: fixture preview population floor failed: %d",
                  cubeP.faces));
    ok(`{"id":"mesh.subpatch_toggle"}`, "SD-P/control");
    foreach (id; ["SD-P", "SD-P/tab"]) {
        free2(id);
        if (id == "SD-P") ok(`{"id":"mesh.subpatch_toggle"}`, id); else key(9,43,id);
        auto p = preview(id); auto f1 = flags(model());
        if (id == "SD-P") ok(`{"id":"mesh.subpatch_toggle"}`, id); else key(9,43,id);
        auto f2 = flags(model());
        JSONValue[string] got;
        got["previewActive"] = JSONValue(p.active);
        got["previewFacesAbove"] = JSONValue(p.faces > cubePreviewFaces);
        got["isSubpatch1"] = flagsRead(f1);
        got["isSubpatch2"] = flagsRead(f2);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " census active=", p.active, " previewFaces=", p.faces,
                " cubePreviewFaces=", cubePreviewFaces, " flags1=", f1, " flags2=", f2);
    }

    foreach (id; ["SD-Ps", "SD-Ps/tab"]) {
        loadV3d(fx, "sub2", id);
        if (id == "SD-Ps") ok(`{"id":"mesh.subpatch_toggle"}`, id); else key(9,43,id);
        auto f1 = flags(model());
        if (id == "SD-Ps") ok(`{"id":"mesh.subpatch_toggle"}`, id); else key(9,43,id);
        auto f2 = flags(model());
        JSONValue[string] got;
        got["isSubpatch1"] = flagsRead(f1);
        got["isSubpatch2"] = flagsRead(f2);
        compareCell(bad, fx, id, JSONValue(got));
        writeln(id, " census flags1=", f1, " flags2=", f2);
    }

    loadV3d(fx, "sub2all", "SD-Psb");
    ok(`{"id":"mesh.subpatch_toggle"}`, "SD-Psb"); auto sb1 = flags(model());
    ok(`{"id":"mesh.subpatch_toggle"}`, "SD-Psb"); auto sb2 = flags(model());
    JSONValue[string] sbGot;
    sbGot["isSubpatch1"] = flagsRead(sb1);
    sbGot["isSubpatch2"] = flagsRead(sb2);
    compareCell(bad, fx, "SD-Psb", JSONValue(sbGot));
    writeln("SD-Psb census flags1=", sb1, " flags2=", sb2);

    foreach (ext; ["obj", "lwo", "glb"]) {
        auto id = "SD-X/" ~ ext; free2(id);
        auto path = tmp(randomUUID().toString ~ "." ~ ext);
        ok(format(`{"id":"file.save","path":%s}`, JSONValue(path).toString), id);
        ok(commandBody("scene.reset", `{"empty":true}`), id);
        assert(counts(model()) == "0/0/0", id ~ ": empty reload floor failed");
        ok(format(`{"id":"file.load","path":%s}`, JSONValue(path).toString), id);
        auto m = model(); auto want = cell(fx,"SD-X")["census"][ext];
        JSONValue[string] got;
        got[ext] = meshRead(m);
        Mismatch[] rows; size_t leaves;
        JSONValue[string] expected;
        expected[ext] = want;
        compareExpected(id, JSONValue(expected), JSONValue(got), rows, leaves);
        foreach (row; rows)
            bad ~= format("%s | %s | want %s | got %s",
                          row.cell, row.key, row.want, row.got);
        writeln(id, " census mesh=", counts(m));
    }

    writeln("SD-FIXTURE executed=25 planned=7 total=32");
    foreach (id; ["SD-5last", "SD-5first", "SD-5last/flat",
                  "SD-5first/flat", "SD-5last/smooth", "SD-5first/smooth", "SD-5"])
        writeln("SKIP planned ", id);
    foreach (line; bad) writeln("RED ", line);
    assert(bad.length == 0,
        format("short-face table has %d red row(s); see RED lines above", bad.length));
}
