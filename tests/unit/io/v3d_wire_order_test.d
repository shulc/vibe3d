module tests.unit.io.v3d_wire_order_test;

import std.file : exists, readText, remove, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.random : uniform;

import io.native : readV3d, writeV3d;
import math : Vec3;
import mesh : MapDomain, Mesh;

private float edgeValueAtPair(in Mesh m, string name, uint a, uint b) {
    const ei = m.edgeIndex(a, b);
    assert(ei != uint.max, format("wire order: pair (%s,%s) exists", a, b));
    foreach (ref mm; m.meshMaps)
        if (mm.name == name) {
            assert(ei < mm.data.length, "wire order: map covers the live edge");
            return mm.data[ei];
        }
    assert(false, "wire order: named Edge map survived");
}

private void assertCanonicalIdentity(in Mesh m, string where) {
    const order = m.canonicalEdgeOrder();
    assert(order.length == m.edges.length, where ~ ": canonical order is complete");
    foreach (i, ei; order)
        assert(i == ei, where ~ ": loaded live edge order must be canonical");
}

unittest { // test 8: file order cannot attach Edge-map values to foreign pairs
    auto p1 = buildPath(tempDir(), format("vibe3d_3910_order_a_%d.v3d",
                                         uniform(0, int.max)));
    auto p2 = buildPath(tempDir(), format("vibe3d_3910_order_b_%d.v3d",
                                         uniform(0, int.max)));
    scope(exit) {
        if (exists(p1)) remove(p1);
        if (exists(p2)) remove(p2);
    }

    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0),
                 Vec3(1, 1, 0), Vec3(0, 1, 0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addEdge(0, 2);
    m.addEdge(1, 3);
    assert(m.edges.length == 6, "wire order fixture: 4 face edges + 2 wires");
    auto map = m.addMeshMap("wire_order_3910", 1, MapDomain.Edge);
    assert(map !is null && map.data.length == 6, "wire order fixture: six map values");
    foreach (i; 0 .. map.data.length) map.data[i] = 10.0f + cast(float)i;
    const float v02 = edgeValueAtPair(m, "wire_order_3910", 0, 2);
    const float v13 = edgeValueAtPair(m, "wire_order_3910", 1, 3);
    assert(v02 != v13, "wire order fixture: the two subject values differ");
    writeV3d(m, p1);

    // Positive control first: a writer-produced file loads its map and floor.
    Mesh control;
    assert(readV3d(p1, control), "wire order control: writer file must load");
    assert(control.meshMaps.length == 1, "wire order control: map was not discarded");
    assert(control.edges.length == 6, "wire order control: population floor");
    assert(edgeValueAtPair(control, "wire_order_3910", 0, 2) == v02 &&
           edgeValueAtPair(control, "wire_order_3910", 1, 3) == v13,
           "wire order control: values stay on their pairs");
    assertCanonicalIdentity(control, "wire order control");

    // Subject: reverse only the two wireEdges entries in the file text. The
    // Edge-map array remains canonical, so the loader must sort before append.
    auto root = parseJSON(readText(p1));
    auto layers = root["layers"].array;
    auto meshJ = layers[0]["mesh"];
    auto wires = meshJ["wireEdges"].array;
    assert(wires.length == 2, "wire order subject: file carries two wires");
    auto tmp = wires[0];
    wires[0] = wires[1];
    wires[1] = tmp;
    meshJ["wireEdges"] = JSONValue(wires);
    layers[0]["mesh"] = meshJ;
    root["layers"] = JSONValue(layers);
    write(p2, root.toString());

    Mesh subject;
    assert(readV3d(p2, subject), "wire order subject: edited file must load");
    assert(subject.meshMaps.length == 1,
           "wire order subject: map length still matches and must not be discarded");
    assert(edgeValueAtPair(subject, "wire_order_3910", 0, 2) == v02,
           "wire order subject: value for pair (0,2) arrived on a foreign edge");
    assert(edgeValueAtPair(subject, "wire_order_3910", 1, 3) == v13,
           "wire order subject: value for pair (1,3) arrived on a foreign edge");
    assertCanonicalIdentity(subject, "wire order subject");
}
