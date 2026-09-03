module tests.unit.io.v3d_wire_roundtrip_test;

import std.file : exists, read, readText, remove, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.random : uniform;

import io.native : readV3d, writeV3d;
import math : Vec3;
import mesh : MapDomain, Mesh;

private bool hasWire(in Mesh m, uint a, uint b) {
    foreach (ref e; m.edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return true;
    return false;
}

private string tempV3d(string tag) {
    return buildPath(tempDir(), format("vibe3d_3910_%s_%d.v3d",
                                      tag, uniform(0, int.max)));
}

private float edgeValueAtPair(in Mesh m, string name, uint a, uint b) {
    const ei = m.edgeIndex(a, b);
    assert(ei != uint.max, format("edge-map fixture: pair (%s,%s) exists", a, b));
    foreach (ref mm; m.meshMaps)
        if (mm.name == name) {
            assert(ei < mm.data.length, "edge-map fixture: pair is inside map data");
            return mm.data[ei];
        }
    assert(false, "edge-map fixture: named map exists after reload");
}

unittest { // mutation A: a bare wire in the middle survives the native round trip
    auto path = tempV3d("wire");
    scope(exit) if (exists(path)) remove(path);

    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0),
                 Vec3(3, 0, 0), Vec3(4, 0, 0), Vec3(4, 1, 0), Vec3(3, 1, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(4, 5);
    m.addFace([6u, 7u, 8u, 9u]);
    assert(m.edges.length == 9, "A fixture: 4 + wire + 4 edges");
    assert(m.edgeIndex(4, 5) == 4, "A fixture: wire is exactly in the middle");
    assert(hasWire(m, 4, 5), "A fixture: wire exists before write");

    writeV3d(m, path);
    Mesh back;
    assert(readV3d(path, back), "A parse gate: file must load");
    assert(back.edges.length == 9,
        format("A loss: expected 9 edges after reload, got %s", back.edges.length));
    assert(hasWire(back, 4, 5),
        "A loss: native writer did not preserve the bare wire");
}

unittest { // a file wire already covered by a face records authorship without a duplicate
    auto path = tempV3d("covered_duplicate");
    scope(exit) if (exists(path)) remove(path);

    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u]);
    writeV3d(m, path);

    auto root = parseJSON(readText(path));
    auto layers = root["layers"].array;
    auto meshJ = layers[0]["mesh"];
    meshJ["wireEdges"] = JSONValue([
        JSONValue([JSONValue(0L), JSONValue(1L)])
    ]);
    layers[0]["mesh"] = meshJ;
    root["layers"] = JSONValue(layers);
    write(path, root.toString());

    Mesh back;
    assert(readV3d(path, back), "covered duplicate: edited file must load");
    assert(back.edges.length == 3,
           "covered duplicate: a file wire must not append a second face edge");
    assert(back.wireEdgeKeys.length == 1,
           "covered duplicate: covered authorship must still enter the registry");
}

unittest { // mutation C: edge-map values follow vertex pairs, not live edge order
    auto path = tempV3d("edge_map");
    scope(exit) if (exists(path)) remove(path);

    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addEdge(0, 2);
    m.addFace([0u, 1u, 2u]);
    assert(m.edges.length == 3, "C fixture: covered authored edge, no bare wire");
    auto map = m.addMeshMap("edge_order_3910", 1, MapDomain.Edge);
    assert(map !is null && map.data.length == 3, "C fixture: edge map exists");
    map.data[m.edgeIndex(0, 2)] = 7;
    map.data[m.edgeIndex(0, 1)] = 8;
    map.data[m.edgeIndex(1, 2)] = 9;

    writeV3d(m, path);
    Mesh back;
    assert(readV3d(path, back), "C parse gate: file must load");
    const ei = back.edgeIndex(0, 2);
    assert(ei != uint.max, "C fixture: pair (0,2) survived");
    float got = float.nan;
    foreach (ref mm; back.meshMaps)
        if (mm.name == "edge_order_3910") got = mm.data[ei];
    assert(got == 7,
        format("C edge-map pair (0,2): expected 7, got %s", got));
}

unittest { // an Edge map spans a bare wire in the middle without being discarded
    auto path = tempV3d("edge_map_wire_middle");
    scope(exit) if (exists(path)) remove(path);

    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0),
                 Vec3(3, 0, 0), Vec3(4, 0, 0), Vec3(4, 1, 0), Vec3(3, 1, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(4, 5);
    m.addFace([6u, 7u, 8u, 9u]);
    auto map = m.addMeshMap("wire_middle_3910", 1, MapDomain.Edge);
    assert(map !is null && map.data.length == 9,
           "edge-map wire fixture: 4 + wire + 4 entries");
    foreach (i; 0 .. map.data.length) map.data[i] = 100.0f + cast(float)i;

    writeV3d(m, path);
    Mesh back;
    assert(readV3d(path, back), "edge-map wire fixture: file must load");
    assert(back.edges.length == 9, "edge-map wire fixture: population survives");
    foreach (ref e; m.edges)
        assert(edgeValueAtPair(back, "wire_middle_3910", e[0], e[1]) ==
               edgeValueAtPair(m, "wire_middle_3910", e[0], e[1]),
               format("edge-map wire fixture: value follows pair (%s,%s)", e[0], e[1]));
}

private void assertStable(Mesh m, string tag) {
    auto p1 = tempV3d(tag ~ "_a");
    auto p2 = tempV3d(tag ~ "_b");
    scope(exit) {
        if (exists(p1)) remove(p1);
        if (exists(p2)) remove(p2);
    }
    writeV3d(m, p1);
    Mesh back;
    assert(readV3d(p1, back), tag ~ ": first file must reload");
    writeV3d(back, p2);
    assert(read(p1) == read(p2), tag ~ ": save/load/save bytes must be stable");
}

unittest { // byte stability: wireEdges order is a pure sorted vertex-pair order
    Mesh middle;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                 Vec3(20, 0, 0), Vec3(21, 0, 0),
                 Vec3(3, 0, 0), Vec3(4, 0, 0), Vec3(4, 1, 0), Vec3(3, 1, 0)])
        middle.addVertex(p);
    middle.addFace([0u, 1u, 2u, 3u]);
    middle.addEdge(4, 5);
    middle.addFace([6u, 7u, 8u, 9u]);
    assert(middle.edgeIndex(4, 5) == 4, "stability fixture: wire is in the middle");
    assertStable(middle, "wire_middle_stability");

    Mesh covered;
    covered.addVertex(Vec3(0, 0, 0));
    covered.addVertex(Vec3(1, 0, 0));
    covered.addVertex(Vec3(0, 1, 0));
    covered.addEdge(0, 2);
    covered.addFace([0u, 1u, 2u]);
    assert(covered.edges.length == 3 && covered.wireEdgeKeys.length == 1,
           "covered stability fixture: no bare edge, one authored pair");
    assertStable(covered, "covered_wire_stability");
}

unittest { // size floor: an ordinary face-built cube emits no sparse wire key
    import mesh : makeCube;
    auto path = tempV3d("no_wire_key");
    scope(exit) if (exists(path)) remove(path);
    Mesh cube = makeCube(); // not a pen mesh: every edge comes only from faces
    writeV3d(cube, path);
    auto root = parseJSON(readText(path));
    assert("wireEdges" !in root["layers"].array[0]["mesh"],
           "a mesh with no authored edge must omit the optional wireEdges key");
}

unittest { // semantic control A: freshly face-derived edges do not become authored
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]); // shared diagonal (0,2), never passed to addEdge
    assert(m.wireEdgeKeys.length == 0, "semantic A fixture: no authored pairs");
    assert(m.deleteFacesByMask([true, true]) == 2, "semantic A: both faces removed");
    assert(!hasWire(m, 0, 2),
           "semantic A: keepFloatingEdges=false must not preserve a derived diagonal");
}

unittest { // semantic control B: loading faces must not make every edge authored
    auto path = tempV3d("loaded_face_semantics");
    scope(exit) if (exists(path)) remove(path);
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u]);
    writeV3d(m, path);
    Mesh back;
    assert(readV3d(path, back), "semantic B: face-only file must load");
    assert(back.deleteFacesByMask([true]) == 1, "semantic B: loaded face removed");
    assert(back.edges.length == 0,
           "semantic B: freshly orphaned loaded face edges must disappear");
}
