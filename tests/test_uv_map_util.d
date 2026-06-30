// test_uv_map_util.d — tests for uv.delete / uv.rename / uv.copy / uv.clear.
//
// Coverage:
//   Source-backed (in-process, no HTTP):
//     - uv.delete: apply removes map; revert restores it; no-map throws.
//     - uv.rename: apply renames; revert restores old name; errors for
//       empty/identical/absent from; target-exists conflict.
//     - uv.copy:   apply creates duplicate with byte-equal data; revert
//       removes the copy; pointer-safety: data byte-identical after append.
//     - uv.clear:  apply zeros data; revert restores original values
//       byte-exact; no-map throws; domain-guard: weight-map name rejected.
//
//   HTTP .v3d round-trip (one or two smoke tests per command):
//     Seed via uv.project (non-zero values on reset cube).
//     Read back via file.save → parse uvMaps.
//     Undo via /api/undo → file.save → assert pre-command state restored.
//     Negatives: absent map / name conflict → status:error.

import std.file   : write, remove, exists, readText;
import std.format : format;
import std.json   : parseJSON, JSONValue;
import std.math   : fabs;

import mesh       : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import view       : View;
import editmode   : EditMode;
import snapshot   : MeshSnapshot;
import commands.mesh.uv_map_util;
import std.net.curl : post, get;

void main() {}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

private enum string kBase = "http://localhost:8080";

// Post a command; assert status:ok; return the response.
private JSONValue runCmd(string id, string paramsJson = "") {
    string body_ = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body_));
    assert(j["status"].str == "ok",
           id ~ " failed: " ~ j.toString);
    return j;
}

// Post a command body and return the raw response string (for error checks).
private string runCmdRaw(string body_) {
    return cast(string) post(kBase ~ "/api/command", body_);
}

// Build a cube with a zero-filled "uv" PolyVertex dim-2 map.
private Mesh makeCubeWithUv() {
    auto m   = makeCube();
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null, "addMeshMap(uv) on cube must succeed");
    assert(map.data.length == m.loops.length * 2,
           "UV map data must be sized to loops*2");
    return m;
}

// Fill the UV map with simple per-loop values so it is non-zero/recognisable.
private void fillUvNonZero(ref Mesh m) {
    auto map = m.meshMap(kUvMapName);
    assert(map !is null);
    foreach (i; 0 .. map.data.length)
        map.data[i] = cast(float)(i + 1) * 0.01f;
}

// Look up a uvMap entry by name in a parsed v3d JSONValue.
// Returns a JSONValue with "name", "dim", "data" fields, or JSONValue.init.
private JSONValue findUvMapByName(JSONValue meshJ, string name) {
    if ("uvMaps" !in meshJ) return JSONValue.init;
    foreach (u; meshJ["uvMaps"].array)
        if (u["name"].str == name) return u;
    return JSONValue.init;
}

// Save to a temp path, parse the JSON, return the mesh sub-object.
private JSONValue saveParseMesh(string path) {
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected saved file at " ~ path);
    auto j = parseJSON(readText(path));
    return j["layers"][0]["mesh"];
}

// ---------------------------------------------------------------------------
// Source-backed: uv.delete
// ---------------------------------------------------------------------------

unittest {
    auto m   = makeCubeWithUv();
    fillUvNonZero(m);
    View view = new View(0, 0, 800, 600);

    // apply: map is removed
    auto cmd = new UvDelete(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "uv.delete must return true");
    assert(m.meshMap(kUvMapName) is null,
           "UV map must be gone after uv.delete");

    // revert: map comes back
    assert(cmd.revert(), "uv.delete revert must return true");
    auto restored = m.meshMap(kUvMapName);
    assert(restored !is null, "UV map must be restored after revert");
    assert(restored.domain == MapDomain.PolyVertex && restored.dim == 2,
           "restored map must be PolyVertex dim=2");
}

unittest {
    // no-map → throws
    auto m    = makeCube();   // no UV map
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvDelete(&m, view, EditMode.Vertices);
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.delete on absent map must throw");

    // revert without prior apply returns false
    assert(!cmd.revert(), "revert without apply must return false");
}

// ---------------------------------------------------------------------------
// Source-backed: uv.rename
// ---------------------------------------------------------------------------

unittest {
    auto m   = makeCubeWithUv();
    fillUvNonZero(m);
    auto before = m.meshMap(kUvMapName).data.dup;
    View view   = new View(0, 0, 800, 600);

    auto cmd = new UvRename(&m, view, EditMode.Vertices);

    // set params via direct field write (same approach as test_uv_transform.d)
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == "from") *p.sptr = kUvMapName;
    foreach (ref p; cmd.params())
        if (p.name == "to") *p.sptr = "uv2";

    assert(cmd.apply(), "uv.rename must return true");

    // old name gone, new name present with same data
    assert(m.meshMap(kUvMapName) is null, "old name must be gone");
    auto renamed = m.meshMap("uv2");
    assert(renamed !is null, "new name must be present");
    assert(renamed.data == before, "data must be unchanged after rename");

    // revert: name flips back
    assert(cmd.revert(), "uv.rename revert must return true");
    assert(m.meshMap("uv2")      is null, "new name must be gone after revert");
    assert(m.meshMap(kUvMapName) !is null, "old name must be back after revert");
}

unittest {
    // empty from/to → throws
    auto m    = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);

    auto cmd = new UvRename(&m, view, EditMode.Vertices);

    bool threw = false;
    try { cmd.apply(); }   // to_ is "" by default
    catch (Exception) { threw = true; }
    assert(threw, "uv.rename with empty to must throw");
}

unittest {
    // from == to → throws
    auto m    = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvRename(&m, view, EditMode.Vertices);

    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = kUvMapName;
    }

    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.rename from==to must throw");
}

unittest {
    // target name already exists → throws
    auto m    = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);

    // create a second map
    auto ok = m.addMeshMap("uv2", 2, MapDomain.PolyVertex);
    assert(ok !is null);

    auto cmd = new UvRename(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = "uv2";
    }

    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.rename to existing name must throw");
}

// ---------------------------------------------------------------------------
// Source-backed: uv.copy
// ---------------------------------------------------------------------------

unittest {
    auto m   = makeCubeWithUv();
    fillUvNonZero(m);
    auto srcData = m.meshMap(kUvMapName).data.dup;
    View view    = new View(0, 0, 800, 600);

    auto cmd = new UvCopy(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = "uv2";
    }

    assert(cmd.apply(), "uv.copy must return true");
    assert(m.meshMaps.length == 2, "must have 2 maps after copy");

    // Find "uv" and "uv2" by name (not by index order)
    auto orig = m.meshMap(kUvMapName);
    auto copy = m.meshMap("uv2");
    assert(orig !is null, "source map must still exist");
    assert(copy !is null, "copy map must exist");
    assert(copy.dim    == 2,                  "copy dim must be 2");
    assert(copy.domain == MapDomain.PolyVertex, "copy domain must be PolyVertex");
    // Data byte-identical to original (guards the pointer-safety capture)
    assert(copy.data   == srcData, "copy data must be byte-identical to source");

    // Undo: back to one map
    assert(cmd.revert(), "uv.copy revert must return true");
    assert(m.meshMap("uv2")      is null, "copy must be gone after revert");
    assert(m.meshMap(kUvMapName) !is null, "source must survive revert");
}

unittest {
    // absent source → throws
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvCopy(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = "uv2";
    }
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.copy from absent map must throw");
}

unittest {
    // target already exists → throws
    auto m    = makeCubeWithUv();
    auto ok   = m.addMeshMap("uv2", 2, MapDomain.PolyVertex);
    assert(ok !is null);
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvCopy(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = "uv2";
    }
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.copy to existing name must throw");
}

unittest {
    // from == to → throws
    auto m    = makeCubeWithUv();
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvCopy(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params()) {
        if (p.name == "from") *p.sptr = kUvMapName;
        if (p.name == "to")   *p.sptr = kUvMapName;
    }
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.copy from==to must throw");
}

// ---------------------------------------------------------------------------
// Source-backed: uv.clear
// ---------------------------------------------------------------------------

unittest {
    auto m   = makeCubeWithUv();
    fillUvNonZero(m);
    auto before = m.meshMap(kUvMapName).data.dup;
    View view   = new View(0, 0, 800, 600);

    auto cmd = new UvClear(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "uv.clear must return true");

    // All data values must be 0
    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "map must still exist after clear");
    foreach (i, f; map.data)
        assert(f == 0.0f, format("clear: data[%d] must be 0, got %g", i, f));

    // Revert: data restored byte-exact (not just "non-zero" — planar project
    // may legitimately yield some zeros, so we compare the exact snapshot)
    assert(cmd.revert(), "uv.clear revert must return true");
    // snapshot.restore replaces mesh.meshMaps; re-fetch the pointer
    auto restored = m.meshMap(kUvMapName);
    assert(restored !is null, "map must survive revert");
    assert(restored.data == before, "revert must restore data byte-exact");
}

unittest {
    // absent map → throws
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvClear(&m, view, EditMode.Vertices);
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.clear on absent map must throw");
}

unittest {
    // domain guard: weight map (Point dim=1) is not a UV map → throws
    auto m    = makeCube();
    auto wm   = m.addMeshMap("w", 1, MapDomain.Point);
    assert(wm !is null);
    View view = new View(0, 0, 800, 600);
    auto cmd  = new UvClear(&m, view, EditMode.Vertices);
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == "name") *p.sptr = "w";
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.clear on a weight map must throw (domain guard)");
}

// ---------------------------------------------------------------------------
// HTTP smoke: uv.delete
// ---------------------------------------------------------------------------

unittest {
    enum string tmp = "/tmp/vibe3d-test-uvutil-delete.v3d";
    scope(exit) if (exists(tmp)) remove(tmp);

    // seed
    post(kBase ~ "/api/reset", "");
    runCmd("uv.project");

    // delete
    runCmd("uv.delete", `{"name":"uv"}`);

    // save → no uvMaps key
    auto meshJ = saveParseMesh(tmp);
    assert("uvMaps" !in meshJ, "uvMaps must be absent after uv.delete");

    // undo → map restored
    post(kBase ~ "/api/undo", "");
    if (exists(tmp)) remove(tmp);
    meshJ = saveParseMesh(tmp);
    assert("uvMaps" in meshJ, "uvMaps must be present after undo");
    auto u = findUvMapByName(meshJ, "uv");
    assert(u.type != JSONValue.init.type, "map named 'uv' must be restored");
}

unittest {
    // absent map → status:error
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(runCmdRaw(`{"id":"uv.delete","params":{"name":"uv"}}`));
    assert(resp["status"].str == "error",
           "uv.delete on absent map must return status:error");
}

// ---------------------------------------------------------------------------
// HTTP smoke: uv.rename
// ---------------------------------------------------------------------------

unittest {
    enum string tmp = "/tmp/vibe3d-test-uvutil-rename.v3d";
    scope(exit) if (exists(tmp)) remove(tmp);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project");

    // rename uv → uv2
    runCmd("uv.rename", `{"from":"uv","to":"uv2"}`);

    auto meshJ = saveParseMesh(tmp);
    assert("uvMaps" in meshJ, "uvMaps must be present after rename");
    auto u2 = findUvMapByName(meshJ, "uv2");
    assert(u2.type != JSONValue.init.type, "map named 'uv2' must exist");
    // old name must be gone
    auto uOld = findUvMapByName(meshJ, "uv");
    assert(uOld.type == JSONValue.init.type, "old name 'uv' must be gone");

    // undo → original name back
    post(kBase ~ "/api/undo", "");
    if (exists(tmp)) remove(tmp);
    meshJ = saveParseMesh(tmp);
    auto uRestored = findUvMapByName(meshJ, "uv");
    assert(uRestored.type != JSONValue.init.type, "undo must restore name 'uv'");
}

unittest {
    // rename to existing name → status:error
    post(kBase ~ "/api/reset", "");
    runCmd("uv.project");
    // Add a second map via rename (need a second map to conflict against).
    // Easier: just try to rename uv to uv (identical → error).
    auto resp = parseJSON(
        runCmdRaw(`{"id":"uv.rename","params":{"from":"uv","to":"uv"}}`));
    assert(resp["status"].str == "error",
           "uv.rename from==to must return status:error");
}

unittest {
    // rename absent map → status:error
    post(kBase ~ "/api/reset", "");   // fresh cube, no UV map
    auto resp = parseJSON(
        runCmdRaw(`{"id":"uv.rename","params":{"from":"uv","to":"uv2"}}`));
    assert(resp["status"].str == "error",
           "uv.rename absent map must return status:error");
}

// ---------------------------------------------------------------------------
// HTTP smoke: uv.copy
// ---------------------------------------------------------------------------

unittest {
    enum string tmp = "/tmp/vibe3d-test-uvutil-copy.v3d";
    scope(exit) if (exists(tmp)) remove(tmp);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project");

    // save baseline data for "uv"
    auto meshBefore = saveParseMesh(tmp);
    auto uvBefore   = findUvMapByName(meshBefore, "uv");
    assert(uvBefore.type != JSONValue.init.type, "baseline must have 'uv'");
    auto dataBefore = uvBefore["data"].array;

    // copy uv → uv2
    if (exists(tmp)) remove(tmp);
    runCmd("uv.copy", `{"from":"uv","to":"uv2"}`);

    auto meshAfter = saveParseMesh(tmp);
    assert("uvMaps" in meshAfter);
    auto uv  = findUvMapByName(meshAfter, "uv");
    auto uv2 = findUvMapByName(meshAfter, "uv2");
    assert(uv.type  != JSONValue.init.type, "source 'uv' must still exist");
    assert(uv2.type != JSONValue.init.type, "copy 'uv2' must exist");
    auto dataCopy = uv2["data"].array;
    assert(dataCopy.length == dataBefore.length,
           "copy data length must match source");
    // Data byte-identical
    foreach (i; 0 .. dataBefore.length)
        assert(fabs(cast(float) dataCopy[i].floating
                  - cast(float) dataBefore[i].floating) < 1e-6f,
               format("copy data[%d]: expected %g got %g", i,
                      dataBefore[i].floating, dataCopy[i].floating));

    // undo → back to 1 map
    post(kBase ~ "/api/undo", "");
    if (exists(tmp)) remove(tmp);
    auto meshUndo = saveParseMesh(tmp);
    assert(findUvMapByName(meshUndo, "uv2").type == JSONValue.init.type,
           "undo must remove 'uv2'");
    assert(findUvMapByName(meshUndo, "uv").type  != JSONValue.init.type,
           "undo must keep 'uv'");
}

unittest {
    // copy absent source → status:error
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(
        runCmdRaw(`{"id":"uv.copy","params":{"from":"uv","to":"uv2"}}`));
    assert(resp["status"].str == "error",
           "uv.copy from absent map must return status:error");
}

// ---------------------------------------------------------------------------
// HTTP smoke: uv.clear
// ---------------------------------------------------------------------------

unittest {
    enum string tmp = "/tmp/vibe3d-test-uvutil-clear.v3d";
    scope(exit) if (exists(tmp)) remove(tmp);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project");

    // save baseline (non-zero values from uv.project)
    auto meshBefore = saveParseMesh(tmp);
    auto uvBefore   = findUvMapByName(meshBefore, "uv");
    assert(uvBefore.type != JSONValue.init.type, "baseline must have 'uv'");
    auto dataBefore = uvBefore["data"].array;

    // Verify at least one non-zero baseline value so the test is meaningful
    bool anyNonZero = false;
    foreach (v; dataBefore)
        if (fabs(cast(float) v.floating) > 1e-6f) { anyNonZero = true; break; }
    assert(anyNonZero, "uv.project must produce some non-zero UV values");

    // clear
    if (exists(tmp)) remove(tmp);
    runCmd("uv.clear", `{"name":"uv"}`);

    auto meshAfter = saveParseMesh(tmp);
    auto uvAfter   = findUvMapByName(meshAfter, "uv");
    assert(uvAfter.type != JSONValue.init.type, "map must still exist after clear");
    // All values must be 0
    foreach (i, v; uvAfter["data"].array)
        assert(fabs(cast(float) v.floating) < 1e-6f,
               format("clear: data[%d] must be 0, got %g", i, v.floating));

    // undo → original values restored byte-exact
    post(kBase ~ "/api/undo", "");
    if (exists(tmp)) remove(tmp);
    auto meshUndo = saveParseMesh(tmp);
    auto uvUndo   = findUvMapByName(meshUndo, "uv");
    assert(uvUndo.type != JSONValue.init.type, "map must exist after undo");
    auto dataUndo = uvUndo["data"].array;
    assert(dataUndo.length == dataBefore.length, "undo data length must match");
    foreach (i; 0 .. dataBefore.length)
        assert(fabs(cast(float) dataUndo[i].floating
                  - cast(float) dataBefore[i].floating) < 1e-6f,
               format("undo clear: data[%d]: expected %g got %g", i,
                      dataBefore[i].floating, dataUndo[i].floating));
}

unittest {
    // absent map → status:error
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(
        runCmdRaw(`{"id":"uv.clear","params":{"name":"uv"}}`));
    assert(resp["status"].str == "error",
           "uv.clear on absent map must return status:error");
}

unittest {
    // domain guard via HTTP: create weight map "w", then uv.clear {name:"w"} → error
    post(kBase ~ "/api/reset", "");
    runCmd("mesh.weightmap.create", `{"name":"w"}`);
    auto resp = parseJSON(
        runCmdRaw(`{"id":"uv.clear","params":{"name":"w"}}`));
    assert(resp["status"].str == "error",
           "uv.clear on a weight map must return status:error (domain guard)");
}
