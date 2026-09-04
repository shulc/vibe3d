// HTTP tests for morph maps (task 1069): the command surface over
// /api/command, and the `.v3d` `vertexMorphs` codec round trip
// (source/io/native.d).
//
// **The readback vehicle for the whole feature.** `/api/model` exposes no
// mesh maps and this task deliberately adds no endpoint — a second readback
// path would itself be untested. So every assertion here drives commands,
// `file.save`s a `.v3d`, and reads the JSON back. That tests serialisation
// for free, and it is the same vehicle the routing and interchange tests use.
//
// Deterministic cube layout (tests/test_select_aliases.d's header):
//   verts: 0:(-,-,-)  1:(+,-,-)  2:(+,+,-)  3:(-,+,-)
//          4:(-,-,+)  5:(+,-,+)  6:(+,+,+)  7:(-,+,+)

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.file   : remove, exists, readText, write;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;

void main() {}

alias kBase = testBaseUrl;

void resetCube() {
    auto resp = post(kBase ~ "/api/command", commandBody("scene.reset"));
    assert(parseJSON(cast(string) resp)["status"].str == "ok",
        "/api/reset failed: " ~ cast(string) resp);
}

void runCmd(string id, string paramsJson = "") {
    string body = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}

/// Run a command that is EXPECTED to fail, and return the response.
JSONValue runCmdExpectingFailure(string id, string paramsJson = "") {
    string body = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return parseJSON(cast(string) post(kBase ~ "/api/command", body));
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(kBase ~ "/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(parseJSON(cast(string) resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string) resp);
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

// --- readback -------------------------------------------------------------

private int g_tmpSeq = 0;

/// Save the document and return layer 0's mesh JSON.
JSONValue saveAndReadMesh(string tag) {
    string path = format("/tmp/vibe3d-test-morph-%s-%d.v3d", tag, g_tmpSeq++);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    return parseJSON(readText(path))["layers"][0]["mesh"];
}

struct MorphBlock {
    string    kind;
    long[]    verts;
    double[]  values;
    size_t entryCount() const { return verts.length; }
    /// The stored triple for vertex `vi`, or `hasEntry == false`.
    bool valueOf(long vi, out double[3] v) const {
        foreach (k, w; verts) {
            if (w != vi) continue;
            v = [values[k * 3], values[k * 3 + 1], values[k * 3 + 2]];
            return true;
        }
        return false;
    }
}

bool hasMorphBlock(JSONValue meshJson) {
    return ("vertexMorphs" in meshJson) !is null;
}

MorphBlock morphOf(JSONValue meshJson, string name) {
    assert(hasMorphBlock(meshJson),
        "mesh JSON carries no \"vertexMorphs\" key at all");
    foreach (m; meshJson["vertexMorphs"].array) {
        if (m["name"].str != name) continue;
        MorphBlock b;
        b.kind = m["kind"].str;
        foreach (v; m["verts"].array)  b.verts  ~= v.integer;
        foreach (v; m["values"].array) b.values ~= v.floating;
        assert(b.values.length == b.verts.length * 3,
            format("morph '%s': values length %d != verts %d * 3",
                   name, b.values.length, b.verts.length));
        return b;
    }
    assert(false, "no morph map named '" ~ name ~ "' in vertexMorphs");
}

double[3] vertexAt(JSONValue meshJson, size_t vi) {
    auto v = meshJson["vertices"].array[vi].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVec(double[3] got, double[3] want, string what) {
    assert(approxEq(got[0], want[0]) && approxEq(got[1], want[1])
        && approxEq(got[2], want[2]),
        format("%s: got (%.6f,%.6f,%.6f) want (%.6f,%.6f,%.6f)",
               what, got[0], got[1], got[2], want[0], want[1], want[2]));
}

// ==========================================================================

unittest { // L5 — the two creation defaults are DIFFERENT, and that is the
           // whole reason there are two kinds.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"blink","kind":"relative"}`);
    runCmd("mesh.morph.create", `{"name":"pose","kind":"absolute"}`);

    auto mesh = saveAndReadMesh("create");

    auto rel = morphOf(mesh, "blink");
    assert(rel.kind == "relative");
    assert(rel.entryCount == 0,
        format("the RELATIVE kind is created EMPTY -- got %d entries",
               rel.entryCount));

    auto abs = morphOf(mesh, "pose");
    assert(abs.kind == "absolute");
    assert(abs.entryCount == 8,
        format("the ABSOLUTE kind is created DENSE -- got %d entries of 8",
               abs.entryCount));
    // ...and dense means a snapshot of every base POSITION, not zeros.
    foreach (vi; 0 .. 8) {
        double[3] stored;
        assert(abs.valueOf(vi, stored),
            format("absolute creation left vertex %d with no entry", vi));
        assertVec(stored, vertexAt(mesh, vi),
            format("vertex %d's fresh absolute entry", vi));
    }
}

unittest { // an unknown kind is refused rather than guessed at
    resetCube();
    auto j = runCmdExpectingFailure("mesh.morph.create",
        `{"name":"x","kind":"sideways"}`);
    assert(j["status"].str != "ok",
        "mesh.morph.create must refuse an unrecognised kind -- guessing would "
      ~ "silently mis-place every vertex the map touches");
    auto mesh = saveAndReadMesh("badkind");
    assert(!hasMorphBlock(mesh), "the refused create must not have registered a map");
}

unittest { // L3 — a stored ZERO is a real entry, and it is NOT the same state
           // as an absent one. This is the case a dense wire format cannot
           // express, and the reason `vertexMorphs` is sparse.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0,"y":0,"z":0}`);

    auto b = morphOf(saveAndReadMesh("zero"), "m");
    assert(b.entryCount == 1,
        format("a zero-valued write must create an ENTRY -- got %d", b.entryCount));
    double[3] v;
    assert(b.valueOf(6, v) && approxEq(v[0], 0) && approxEq(v[1], 0)
        && approxEq(v[2], 0));

    // Every other vertex is absent, not zero: the block lists exactly one.
    foreach (vi; 0 .. 8) {
        double[3] w;
        assert((vi == 6) == b.valueOf(vi, w),
            format("vertex %d: presence disagrees with the write", vi));
    }
}

unittest { // the round trip preserves count, presence, VALUE and KIND
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.create", `{"name":"s","kind":"absolute"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":0,"x":-0.3,"y":0.4,"z":0.2}`);

    string path = "/tmp/vibe3d-test-morph-roundtrip.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);

    // Reload from disk, then re-save and compare — a save-only check cannot
    // see a reader that drops presence or mis-reads the kind.
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto mesh = saveAndReadMesh("roundtrip");

    auto rel = morphOf(mesh, "m");
    assert(rel.kind == "relative", "the KIND must survive the round trip -- it "
        ~ "cannot be inferred from (name, domain, dim)");
    assert(rel.entryCount == 2, format("2 entries expected, got %d", rel.entryCount));
    double[3] v;
    assert(rel.valueOf(6, v)); assertVec(v, [0.25, -0.1, 0.05], "vertex 6 after reload");
    assert(rel.valueOf(0, v)); assertVec(v, [-0.3, 0.4, 0.2], "vertex 0 after reload");
    double[3] w;
    assert(!rel.valueOf(3, w), "vertex 3 had no entry and must still have none");

    auto abs = morphOf(mesh, "s");
    assert(abs.kind == "absolute",
        "an absolute map read back as relative would re-interpret every stored "
      ~ "position as a displacement");
    assert(abs.entryCount == 8);
}

unittest { // L6 / L4 — apply is linear and UNCLAMPED, and leaves the MAP alone
    // Cube vertex 6 is (0.5,0.5,0.5) in the test scene.
    foreach (amount, want; [ "0.5":  [0.625, 0.45,  0.525],
                             "1.5":  [0.875, 0.35,  0.575],
                             "-0.5": [0.375, 0.55,  0.475],
                             "2.0":  [1.0,   0.3,   0.6  ] ]) {
        resetCube();
        runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
        runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
        runCmd("mesh.morph.apply", `{"name":"m","amount":` ~ amount ~ `}`);

        auto mesh = saveAndReadMesh("apply" ~ amount);
        assertVec(vertexAt(mesh, 6), [want[0], want[1], want[2]],
            "apply at amount " ~ amount
          ~ " -- a clamp to [0,1] reddens the 1.5 / -0.5 / 2.0 legs");

        // The map itself is untouched by an apply.
        auto b = morphOf(mesh, "m");
        assert(b.entryCount == 1);
        double[3] v;
        assert(b.valueOf(6, v));
        assertVec(v, [0.25, -0.1, 0.05],
            "apply must NOT re-snapshot or consume the stored value");

        // Nothing else moved.
        assertVec(vertexAt(mesh, 0), [-0.5, -0.5, -0.5],
            "a vertex with no entry must not move under apply");
    }
}

unittest { // the ABSOLUTE kind applies as lerp(base, target, a), not as a delta
    resetCube();
    runCmd("mesh.morph.create", `{"name":"s","kind":"absolute"}`);
    // Retarget vertex 6 to (1.0, 0.5, 0.5); base is (0.5,0.5,0.5).
    runCmd("mesh.morph.set", `{"name":"s","vert":6,"x":1.0,"y":0.5,"z":0.5}`);
    runCmd("mesh.morph.apply", `{"name":"s","amount":0.5}`);

    auto mesh = saveAndReadMesh("absapply");
    // lerp: 0.5 + 0.5*(1.0-0.5) = 0.75. Treating it as a DELTA would give
    // 0.5 + 0.5*1.0 = 1.0 -- the two predictions differ, so this discriminates.
    assertVec(vertexAt(mesh, 6), [0.75, 0.5, 0.5],
        "absolute apply is lerp(base, target, a); a delta reading gives 1.0");
    // Every other vertex's stored target EQUALS its base, so it does not move.
    assertVec(vertexAt(mesh, 0), [-0.5, -0.5, -0.5],
        "a vertex whose absolute target is its own base must not move");
    // ...and the stored target is not re-snapshotted by the apply.
    double[3] v;
    assert(morphOf(mesh, "s").valueOf(6, v));
    assertVec(v, [1.0, 0.5, 0.5], "the stored ABSOLUTE target survives an apply");
}

unittest { // two morphs ADD: applying M then N composes rather than overrides
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.create", `{"name":"n","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
    runCmd("mesh.morph.set", `{"name":"n","vert":6,"x":0,"y":0,"z":0.4}`);
    runCmd("mesh.morph.apply", `{"name":"m","amount":1.0}`);
    runCmd("mesh.morph.apply", `{"name":"n","amount":1.0}`);

    auto mesh = saveAndReadMesh("add");
    // 0.5+0.25, 0.5-0.1, 0.5+0.05+0.4
    assertVec(vertexAt(mesh, 6), [0.75, 0.4, 0.95],
        "two morphs must ADD -- an override would land at (0.5,0.5,0.9)");
}

unittest { // clear is SELECTION-scoped: it drops the selected vertices'
           // entries and leaves the rest alone
    resetCube();
    runCmd("mesh.morph.create", `{"name":"s","kind":"absolute"}`);
    assert(morphOf(saveAndReadMesh("clear-pre"), "s").entryCount == 8);

    postSelect("vertices", [0, 1, 2, 3]);
    runCmd("mesh.morph.clear", `{"name":"s"}`);

    auto b = morphOf(saveAndReadMesh("clear-post"), "s");
    assert(b.entryCount == 4,
        format("clear must drop exactly the 4 SELECTED entries -- got %d left",
               b.entryCount));
    double[3] v;
    foreach (vi; 0 .. 4) assert(!b.valueOf(vi, v),
        format("vertex %d was selected and must have lost its entry", vi));
    foreach (vi; 4 .. 8) assert(b.valueOf(vi, v),
        format("vertex %d was NOT selected and must keep its entry", vi));
}

unittest { // remove / rename / select lifecycle
    resetCube();
    runCmd("mesh.morph.create", `{"name":"a","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"a","vert":2,"x":1,"y":2,"z":3}`);
    runCmd("mesh.morph.rename", `{"from":"a","to":"b"}`);

    auto mesh = saveAndReadMesh("rename");
    auto b = morphOf(mesh, "b");
    assert(b.entryCount == 1, "rename must not disturb the entries");
    double[3] v;
    assert(b.valueOf(2, v)); assertVec(v, [1, 2, 3], "renamed map's value");

    runCmd("mesh.morph.remove", `{"name":"b"}`);
    auto after = saveAndReadMesh("remove");
    assert(!hasMorphBlock(after),
        "the last morph map's removal must drop the whole optional key");

    // select on a non-existent map refuses (a baseRefusal_, not a throw).
    auto j = runCmdExpectingFailure("mesh.morph.select", `{"name":"nope"}`);
    assert(j["status"].str != "ok", "select must refuse an unknown map name");
    // ...and the empty name is the legal "no target" state.
    runCmd("mesh.morph.select", `{"name":""}`);
}

unittest { // undo restores a morph write, including its PRESENCE
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
    assert(morphOf(saveAndReadMesh("undo-pre"), "m").entryCount == 1);

    runCmd("history.undo");
    auto b = morphOf(saveAndReadMesh("undo-post"), "m");
    assert(b.entryCount == 0,
        format("undo must remove the ENTRY, not merely zero its value -- got %d",
               b.entryCount));

    runCmd("history.redo");
    auto c = morphOf(saveAndReadMesh("redo"), "m");
    assert(c.entryCount == 1, "redo restores the entry");
    double[3] v;
    assert(c.valueOf(6, v)); assertVec(v, [0.25, -0.1, 0.05], "redone value");
}

unittest { // a MALFORMED `.v3d` — an out-of-range vertex index — must warn and
           // load, never throw and never corrupt. A `.v3d` is untrusted input
           // and these indices address a dense array directly.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);

    string good = "/tmp/vibe3d-test-morph-good.v3d";
    string bad  = "/tmp/vibe3d-test-morph-bad.v3d";
    if (exists(good)) remove(good);
    if (exists(bad))  remove(bad);
    scope(exit) { if (exists(good)) remove(good); if (exists(bad)) remove(bad); }
    runCmd("file.save", `{"path":"` ~ good ~ `"}`);

    // Rewrite the block with one in-range and one wildly out-of-range index.
    auto doc = parseJSON(readText(good));
    auto blocks = doc["layers"][0]["mesh"]["vertexMorphs"];
    blocks.array[0]["verts"]  = JSONValue([JSONValue(6), JSONValue(9999)]);
    blocks.array[0]["values"] = JSONValue([
        JSONValue(0.25), JSONValue(-0.1), JSONValue(0.05),
        JSONValue(7.0),  JSONValue(7.0),  JSONValue(7.0)]);
    doc["layers"][0]["mesh"]["vertexMorphs"] = blocks;
    write(bad, doc.toString);

    // The load must SUCCEED.
    runCmd("file.load", `{"path":"` ~ bad ~ `"}`);
    auto mesh = saveAndReadMesh("malformed");
    auto b = morphOf(mesh, "m");
    assert(b.entryCount == 1,
        format("the in-range entry must load and the out-of-range one must be "
             ~ "skipped -- got %d entries", b.entryCount));
    double[3] v;
    assert(b.valueOf(6, v)); assertVec(v, [0.25, -0.1, 0.05],
        "the surviving entry must be intact, not shifted by the skip");
    assert(!b.valueOf(9999, v));

    // Geometry survived untouched: 8 vertices, none at (7,7,7).
    assert(mesh["vertices"].array.length == 8);
    foreach (vi; 0 .. 8)
        assert(!approxEq(vertexAt(mesh, vi)[0], 7.0),
            "an out-of-range morph index must not have written into geometry");
}

unittest { // a pre-1069 `.v3d` (no vertexMorphs key at all) still loads, and
           // its weight maps are still visible to the weight-map surface --
           // the negative-filter property, checked end to end.
    resetCube();
    runCmd("mesh.weightmap.create", `{"name":"legacyw"}`);
    runCmd("mesh.weightmap.set", `{"name":"legacyw","vert":3,"weight":0.75}`);

    string path = "/tmp/vibe3d-test-morph-legacy.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    auto doc = parseJSON(readText(path));
    assert(("vertexMorphs" in doc["layers"][0]["mesh"]) is null,
        "a document with no morph map must not emit the key at all");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto mesh = saveAndReadMesh("legacy");
    bool found = false;
    foreach (w; mesh["weightMaps"].array)
        if (w["name"].str == "legacyw") {
            found = true;
            assert(approxEq(w["data"].array[3].floating, 0.75));
        }
    assert(found, "the weight map must survive a reload -- if the kind filters "
        ~ "went POSITIVE, an unclassified legacy map would vanish from every "
        ~ "weight-map surface");

    // ...and it is still offered to select.byStat, whose `weightMap` test
    // gates on `weightMapNames().canFind(map)` and THROWS "no such weight
    // map" when the name is not listed. This is the end-to-end form of
    // mutation 1c: a positive kind filter empties `weightMapNames()` for
    // every legacy map, and this command starts refusing a map that exists.
    runCmd("select.byStat.vertex",
        `{"test":"weightMap","map":"legacyw","mode":"add"}`);
}
