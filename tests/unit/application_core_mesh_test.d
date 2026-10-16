module tests.unit.application_core_mesh_test;

import vibe3d.documents.model.document : Document, Layer, NoEditTargetException;
import vibe3d.mesh.core.mesh : Mesh, makeCube;
import vibe3d.mesh.preview.active_mesh_resolver : activeMeshResolver;
import std.stdio : writeln;
import std.exception : assertThrown;

unittest {
    auto cube = makeCube();
    assert(cube.faces.length == 6, "mesh-cube: production cube has six faces");
    assert(cube.vertices.length == 8 && cube.edges.length == 12,
        "mesh-cube: production topology population");
    assert(cube.loops.length == 24, "mesh-cube: all face corners have loops");
    foreach (loop; cube.loops) {
        assert(loop.vert < cube.vertices.length
            && loop.face < cube.faces.length, "mesh-cube: valid loop domains");
        assert(loop.next < cube.loops.length && loop.prev < cube.loops.length
            && loop.twin < cube.loops.length, "mesh-cube: closed cube loop links");
    }
    writeln("CORE-CELL passed=mesh-cube");
}

unittest {
    const savedResolver = activeMeshResolver;
    {
    scope(exit) activeMeshResolver = savedResolver;
    auto doc = Document.bootstrap(makeCube());
    assert(doc.layers.length == 1 && doc.primary is doc.layers[0],
        "document-primary: bootstrap owns the selected primary");
    auto first = &doc.activeMeshRef();
    assert(first is doc.layers[0].meshOrNull(),
        "document-primary: active reference is primary storage");
    auto other = new Layer;
    other.meshRef() = makeCube();
    other.meshRef().vertices[0].x += 3;
    assert(other.meshRef().vertices[0] != first.vertices[0],
        "document-primary: fixture meshes have distinct geometry");
    doc.layers ~= other;
    doc.noteLayerListChanged();
    activeMeshResolver = () => doc.activeMesh();
    doc.setActive(1);
    assert(doc.primary is other && &doc.activeMeshRef() is other.meshOrNull()
        && &doc.activeMeshRef() !is first && activeMeshResolver() is other.meshOrNull(),
        "document-primary: live resolver follows distinct primary storage");
    doc.setActive(0);
    assert(&doc.activeMeshRef() is first && activeMeshResolver() is first,
        "document-primary: switching back restores first storage identity");
    doc.layers = null;
    doc.noteLayerListChanged();
    assert(doc.primary is null && !doc.hasEditTarget() && doc.activeMesh() is null
        && activeMeshResolver() is null, "document-primary: genuinely absent primary");
    assertThrown!NoEditTargetException(doc.activeMeshRef());
    }
    assert(activeMeshResolver is savedResolver, "document-primary: global resolver restored at scope close");
    writeln("CORE-CELL passed=document-primary");
}
