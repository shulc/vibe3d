// `.lwo` morph round trip (task 1069, plan Stage 6) — the interchange half.
//
// Before this task the reader PARSED these channels and threw them away: the
// file carried them, the log said "skip VMAP", and the data was gone. So the
// load-bearing assertion here is not "the round trip is lossless" but "the
// data survives at all".
//
// Runs on the DEFAULT (assert-live) build deliberately: the writer library's
// `values.length == points.length * dimension` invariant is an `assert` and
// vanishes under `-release`, so this is the configuration in which a
// mis-sized emission is caught.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.file   : remove, exists, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;

void main() {}

alias kBase = testBaseUrl;

void runCmd(string id, string paramsJson) {
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}
void resetCube() {
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}
bool approxEq(double a, double b, double eps = 1e-5) { return fabs(a - b) < eps; }

private int g_seq = 0;
JSONValue saveAndReadMesh(string tag) {
    string path = format("/tmp/vibe3d-test-morphlwo-%s-%d.v3d", tag, g_seq++);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    return parseJSON(readText(path))["layers"][0]["mesh"];
}

struct MorphBlock {
    string   kind;
    long[]   verts;
    double[] values;
    size_t entryCount() const { return verts.length; }
    bool valueOf(long vi, out double[3] v) const {
        foreach (k, w; verts) {
            if (w != vi) continue;
            v = [values[k * 3], values[k * 3 + 1], values[k * 3 + 2]];
            return true;
        }
        return false;
    }
}
MorphBlock morphOf(JSONValue meshJson, string name) {
    assert(("vertexMorphs" in meshJson) !is null,
        "mesh JSON carries no \"vertexMorphs\" key -- the .lwo round trip lost "
      ~ "every morph map");
    foreach (m; meshJson["vertexMorphs"].array) {
        if (m["name"].str != name) continue;
        MorphBlock b;
        b.kind = m["kind"].str;
        foreach (v; m["verts"].array)  b.verts  ~= v.integer;
        foreach (v; m["values"].array) b.values ~= v.floating;
        return b;
    }
    assert(false, "no morph map named '" ~ name ~ "' after the round trip");
}

// ==========================================================================

unittest { // save .lwo -> load .lwo -> the morph channels are still there,
           // with their NAMES, their KINDS, their sparsity and their values.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"blink","kind":"relative"}`);
    runCmd("mesh.morph.create", `{"name":"pose","kind":"absolute"}`);
    runCmd("mesh.morph.set", `{"name":"blink","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
    runCmd("mesh.morph.set", `{"name":"blink","vert":0,"x":0,"y":0,"z":0}`);

    string lwo = "/tmp/vibe3d-test-morph.lwo";
    if (exists(lwo)) remove(lwo);
    scope(exit) if (exists(lwo)) remove(lwo);
    runCmd("file.save", `{"path":"` ~ lwo ~ `"}`);
    runCmd("file.load", `{"path":"` ~ lwo ~ `"}`);

    auto mesh = saveAndReadMesh("after-lwo");

    auto rel = morphOf(mesh, "blink");
    assert(rel.kind == "relative",
        "the map KIND must survive the round trip -- both kinds are "
      ~ "point-domain dim 3, so only the wire tag can carry it");
    assert(rel.entryCount == 2,
        format("2 entries expected after the round trip, got %d -- SPARSITY is "
             ~ "part of the payload: a dense emission would report 8",
               rel.entryCount));
    double[3] v;
    assert(rel.valueOf(6, v));
    assert(approxEq(v[0], 0.25) && approxEq(v[1], -0.1) && approxEq(v[2], 0.05),
        format("value survived as (%.6f,%.6f,%.6f)", v[0], v[1], v[2]));
    // A stored ZERO is an entry and must come back as one, not vanish.
    assert(rel.valueOf(0, v) && approxEq(v[0], 0) && approxEq(v[1], 0)
        && approxEq(v[2], 0),
        "a zero-valued entry must survive as an ENTRY");
    double[3] w;
    assert(!rel.valueOf(3, w),
        "a vertex with no entry must still have none -- the round trip must "
      ~ "not densify");

    // The second map is there too, under its OWN name: the reader used to
    // scan past the S0 name without capturing it, which put every channel
    // under one key.
    auto abs = morphOf(mesh, "pose");
    assert(abs.kind == "absolute");
    assert(abs.entryCount == 8, "the absolute map was dense and stays dense");
    assert(rel.entryCount != abs.entryCount,
        "the two maps must not have collapsed into one another");
}
