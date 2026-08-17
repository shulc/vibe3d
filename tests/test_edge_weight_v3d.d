// HTTP tests for edge weight / semi-sharp subdivision creases (task 1062):
// commands over /api/command, and the `.v3d` `edgeMaps` codec round-trip
// (source/io/native.d), including out-of-range values kept verbatim and the
// П4 pair-resolution pin (edge_weight_plan.md §0/§Testing).
//
// Deterministic cube layout, from tests/test_select_aliases.d's own header
// (used unchanged here for continuity with the rest of the fixture suite):
//   verts: 0:(-,-,-)  1:(+,-,-)  2:(+,+,-)  3:(-,+,-)
//          4:(-,-,+)  5:(+,-,+)  6:(+,+,+)  7:(-,+,+)
//   edges (addEdge order):
//     0:[0,3]  1:[3,2]  2:[2,1]  3:[1,0]   (back face perimeter)
//     4:[4,5]  5:[5,6]  6:[6,7]  7:[7,4]   (front face perimeter)
//     8:[0,4]  9:[7,3]  10:[2,6] 11:[5,1]  (cross edges)
// Edge 6 == [6,7] is exactly the fixture's `rig.creased_edge`
// ((-0.5,0.5,0.5)-(0.5,0.5,0.5)).

import std.net.curl;
import std.json;
import std.file   : remove, exists, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;

void main() {}

enum string kBase = "http://localhost:8080";

void resetCube() {
    auto resp = post(kBase ~ "/api/reset", "");
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

// select.convert has no Param[] wiring -- it is driven by the plain
// "id arg" argstring form (precedent: tests/test_select_aliases.d), not the
// {"id":...,"params":{...}} JSON shape runCmd() uses.
void runRawCmd(string body) {
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body));
    assert(j["status"].str == "ok", body ~ " failed: " ~ j.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(kBase ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string) resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string) resp);
}

int[] selectedEdges() {
    auto j = parseJSON(get(kBase ~ "/api/selection"));
    int[] result;
    foreach (v; j["selectedEdges"].array) result ~= cast(int) v.integer;
    return result;
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

JSONValue creaseMapOf(JSONValue meshJson) {
    foreach (m; meshJson["edgeMaps"].array)
        if (m["name"].str == "crease") return m;
    assert(false, "no 'crease' entry in edgeMaps");
}

// --------------------------------------------------------------------------

unittest { // commands reachable over /api/command; absolute write to every
           // selected edge; empty selection throws (status != ok).
    resetCube();

    // Empty selection -> the command must refuse (not silently apply to
    // the whole mesh).
    postSelect("edges", []);
    auto errResp = parseJSON(cast(string) post(kBase ~ "/api/command",
        `{"id":"mesh.edgeCrease.set","params":{"weight":0.5}}`));
    assert(errResp["status"].str != "ok",
        "mesh.edgeCrease.set must refuse an empty edge selection");

    // Two edges selected -> both get the weight.
    postSelect("edges", [6, 9]);
    runCmd("mesh.edgeCrease.set", `{"weight":0.42}`);

    string path = "/tmp/vibe3d-test-edgeweight-cmd.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    auto mesh = parseJSON(readText(path))["layers"][0]["mesh"];
    auto data = creaseMapOf(mesh)["data"].array;
    assert(approxEq(data[6].floating, 0.42), "edge 6 weight not written");
    assert(approxEq(data[9].floating, 0.42),
        "edge 9 weight not written -- apply() must write EVERY selected edge");

    // mesh.edgeCrease.clear writes 0.0 (still a registered map, per the
    // command's own module unittest -- this HTTP leg only checks the
    // observable value).
    postSelect("edges", [6]);
    runCmd("mesh.edgeCrease.clear");
    if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    auto mesh2 = parseJSON(readText(path))["layers"][0]["mesh"];
    auto data2 = creaseMapOf(mesh2)["data"].array;
    assert(approxEq(data2[6].floating, 0.0));
    assert(approxEq(data2[9].floating, 0.42), "clear() must not touch other edges");

    // The zeroed entry must survive a RELOAD, not just be correctly WRITTEN
    // (checked above) -- task 1062 review, NIT 9. A stored 0.0 is a real
    // value (the map's own doc comment: "this codec never prunes a zero
    // entry"), and the save-only check above cannot see a bug that is
    // specific to the READ side (e.g. the loader silently dropping/
    // misaligning a zero entry while the writer emits it correctly).
    string path3 = "/tmp/vibe3d-test-edgeweight-cmd-reload.v3d";
    if (exists(path3)) remove(path3);
    scope(exit) if (exists(path3)) remove(path3);
    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    runCmd("file.save", `{"path":"` ~ path3 ~ `"}`);
    auto mesh3 = parseJSON(readText(path3))["layers"][0]["mesh"];
    auto data3 = creaseMapOf(mesh3)["data"].array;
    assert(approxEq(data3[6].floating, 0.0),
        "the zeroed entry (edge 6) must survive a save -> load -> save "
      ~ "round trip, not just the first save");
    assert(approxEq(data3[9].floating, 0.42),
        "edge 9 must survive the same round trip");
}

unittest { // edgeMaps key absent when no crease map exists
    enum string path = "/tmp/vibe3d-test-edgeweight-absent.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);

    auto mesh = parseJSON(readText(path))["layers"][0]["mesh"];
    assert(("edgeMaps" in mesh) is null,
        "edgeMaps must be absent when no edge map exists");
}

unittest { // .v3d round-trip, including out-of-range values VERBATIM, and
           // the П4 pair-resolution pin: after reload, the SAME vertex pair
           // (6,7) must still resolve to edge index 6 -- not merely that
           // "index 6 has weight 0.42" (which the dense-array codec would
           // preserve even if the loader scrambled edge order, since it
           // reads/writes by raw index, not by vertex pair). Mutation for
           // this pin: reverse the loader's face iteration or its corner
           // order (source/io/native.d).
    enum string path = "/tmp/vibe3d-test-edgeweight-roundtrip.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();

    // Independent confirmation of the deterministic edge numbering BEFORE
    // any save/reload: vertices 6,7 -> select.convert edge -> edge 6 alone.
    postSelect("vertices", [6, 7]);
    runRawCmd("select.convert edge");
    assert(selectedEdges() == [6],
        "vertex pair (6,7) must convert to edge 6 pre-save");

    // Set weights: in-range on edge 6 (the vertex-pair we'll re-resolve),
    // and out-of-range on two other edges -- these must round-trip
    // VERBATIM (the codec does not clamp; subpatch_osd.creaseSharpnessFromWeight
    // does, at evaluation time only).
    postSelect("edges", [6]);
    runCmd("mesh.edgeCrease.set", `{"weight":0.42}`);
    postSelect("edges", [0]);
    runCmd("mesh.edgeCrease.set", `{"weight":-1.0}`);
    postSelect("edges", [9]);
    runCmd("mesh.edgeCrease.set", `{"weight":5.0}`);

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    auto meshBefore = parseJSON(readText(path))["layers"][0]["mesh"];
    auto dataBefore = creaseMapOf(meshBefore)["data"].array;
    assert(approxEq(dataBefore[6].floating, 0.42));
    assert(approxEq(dataBefore[0].floating, -1.0),
        "negative weight must round-trip verbatim, not be clamped in the codec");
    assert(approxEq(dataBefore[9].floating, 5.0),
        "above-1 weight must round-trip verbatim, not be clamped in the codec");

    // Reload.
    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // The П4 pin: re-derive edge 6 from the SAME vertex pair, on the
    // RELOADED mesh, independently of any assumption about index stability.
    postSelect("vertices", [6, 7]);
    runRawCmd("select.convert edge");
    assert(selectedEdges() == [6],
        "vertex pair (6,7) must STILL convert to edge 6 after a save/reload "
      ~ "round trip with no intervening topology edit -- a scrambled loader "
      ~ "edge order would resolve this pair to a DIFFERENT index");

    // And the weight is on THAT edge, and the out-of-range values on the
    // other two edges are unchanged, verbatim, through a second save.
    enum string path2 = "/tmp/vibe3d-test-edgeweight-roundtrip2.v3d";
    if (exists(path2)) remove(path2);
    scope(exit) if (exists(path2)) remove(path2);
    runCmd("file.save", `{"path":"` ~ path2 ~ `"}`);
    auto meshAfter = parseJSON(readText(path2))["layers"][0]["mesh"];
    auto dataAfter = creaseMapOf(meshAfter)["data"].array;
    assert(approxEq(dataAfter[6].floating, 0.42),
        "weight must be on edge 6 (the resolved vertex pair) after reload");
    assert(approxEq(dataAfter[0].floating, -1.0));
    assert(approxEq(dataAfter[9].floating, 5.0));
}
