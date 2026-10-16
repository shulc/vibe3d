module tests.unit.selection_projection_algorithm_cells_test;

import subpatch_factories : subdivideCube;

import core.memory : GC;
import vibe3d.documents.model.document : Document, Layer, beginPreparedLayerRead;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : makeCube;
import selection_projection : SelectionProjectionInput,
    SelectionProjectionReadModel, encodeSelectionProjection;
import vibe3d.editing.contracts.seltype : SelMode, SelType, SelTypeOrder;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : writefln;

private int[] ids(JSONValue value) {
    int[] result;
    foreach (entry; value.array) result ~= cast(int)entry.integer;
    return result;
}

private string[] tokens(JSONValue value) {
    string[] result;
    foreach (entry; value.array) result ~= entry.str;
    return result;
}

private JSONValue read(SelectionProjectionReadModel model) {
    return parseJSON(model.read());
}

private ulong measureEmptyProjection(ref Document doc, ref SelTypeOrder order) {
    auto input = SelectionProjectionInput(
        &doc, &order, EditMode.Vertices, doc.activeMesh());
    auto warm = encodeSelectionProjection(input);
    immutable before = GC.allocatedInCurrentThread;
    auto measured = encodeSelectionProjection(input);
    immutable bytes = GC.allocatedInCurrentThread - before;
    assert(measured == warm,
        "selection projection changed between the warm and measured calls");
    return bytes;
}

// Empty selection and one layer per document make the small and large wire
// outputs byte-identical, isolating work that scales with the mesh. A future
// reserve(marks.length) still reddens this cell; materialization gated behind a
// non-empty selection is outside its scope.
unittest { // selection projection allocation must not scale with mesh population
    auto smallMesh = subdivideCube(1);
    auto largeMesh = subdivideCube(5);
    smallMesh.syncSelection();
    largeMesh.syncSelection();
    auto small = Document.bootstrap(smallMesh);
    auto large = Document.bootstrap(largeMesh);

    auto smallMeshRef = small.activeMesh();
    auto largeMeshRef = large.activeMesh();
    assert(smallMeshRef !is null && largeMeshRef !is null,
        "selection projection allocation fixture requires two active meshes");
    assert(smallMeshRef.vertexMarks.length == smallMeshRef.vertices.length
        && smallMeshRef.edgeMarks.length == smallMeshRef.edges.length
        && smallMeshRef.faceMarks.length == smallMeshRef.faces.length
        && largeMeshRef.vertexMarks.length == largeMeshRef.vertices.length
        && largeMeshRef.edgeMarks.length == largeMeshRef.edges.length
        && largeMeshRef.faceMarks.length == largeMeshRef.faces.length,
        "selection projection traversal fixture requires marks and geometry "
        ~ "lengths to match in all three domains");
    assert(largeMeshRef.vertices.length > smallMeshRef.vertices.length * 4
        && largeMeshRef.edges.length > smallMeshRef.edges.length * 4
        && largeMeshRef.faces.length > smallMeshRef.faces.length * 4,
        format("selection projection population floor: large mesh must exceed "
             ~ "4x small in every domain; V %d -> %d, E %d -> %d, F %d -> %d",
               smallMeshRef.vertices.length, largeMeshRef.vertices.length,
               smallMeshRef.edges.length, largeMeshRef.edges.length,
               smallMeshRef.faces.length, largeMeshRef.faces.length));
    assert(!smallMeshRef.hasAnySelectedVertices()
        && !smallMeshRef.hasAnySelectedEdges()
        && !smallMeshRef.hasAnySelectedFaces()
        && !largeMeshRef.hasAnySelectedVertices()
        && !largeMeshRef.hasAnySelectedEdges()
        && !largeMeshRef.hasAnySelectedFaces(),
        "selection projection allocation fixture requires the same empty "
        ~ "selection on both meshes");

    SelTypeOrder smallOrder;
    SelTypeOrder largeOrder;
    immutable smallBytes = measureEmptyProjection(small, smallOrder);
    immutable largeBytes = measureEmptyProjection(large, largeOrder);
    /// One GC page; the 32640 B signal leaves an 8x margin. Never raise.
    enum ulong kMaxMeshGrowth = 4096;
    immutable growth = cast(long) largeBytes - cast(long) smallBytes;
    writefln("[selection-projection-alloc] small %d B, large %d B, "
           ~ "growth %d B, limit %d B",
             smallBytes, largeBytes, growth, kMaxMeshGrowth);
    assert(growth <= kMaxMeshGrowth,
        format("selection projection allocation grew with mesh population: "
             ~ "small %d B, large %d B, growth %d B (limit %d B). "
             ~ "Build selected index arrays from scalar mark predicates; do "
             ~ "not materialize whole-mesh bool[] selection views.",
               smallBytes, largeBytes, growth,
               kMaxMeshGrowth));
}

unittest { // live accessor follows primary, front, item set and document swap
    auto doc = Document.bootstrap(makeCube());
    auto layerA = doc.layers[0];
    layerA.name = "A";
    layerA.meshRef().syncSelection();
    layerA.meshRef().selectVertex(1);
    layerA.meshRef().selectVertex(4);
    layerA.meshRef().selectFace(2);

    auto layerB = new Layer;
    layerB.name = "B";
    layerB.meshRef() = makeCube();
    layerB.meshRef().syncSelection();
    layerB.meshRef().selectEdge(0);
    layerB.meshRef().selectEdge(5);
    layerB.meshRef().selectFace(4);
    doc.layers ~= layerB;

    SelTypeOrder order;
    EditMode mode = EditMode.Vertices;
    auto model = new SelectionProjectionReadModel(() {
        return SelectionProjectionInput(
            &doc, &order, mode, doc.activeMesh());
    });

    auto first = read(model);
    assert(first["items"].array.length == 2,
        "selection projection fixture population floor: expected two layers");
    assert(layerA.meshRef().vertices.length == 8
        && layerB.meshRef().vertices.length == 8,
        "selection projection fixture population floor: both layers are populated cubes");
    assert(ids(first["selectedVertices"]) == [1, 4]
        && ids(first["selectedFaces"]) == [2],
        "initial projection must read A's distinct vertex/face marks");
    assert(ids(first["selectedVertices"]).length == 2
        && ids(first["selectedFaces"]).length == 1,
        "initial selected-id comparisons must be populated");
    assert(tokens(first["selTypeOrder"])
        == ["vertex", "edge", "polygon", "item"],
        "initial parsed selection order changed");
    assert(first["selTypeOrder"].array.length == 4,
        "selection-order comparison population floor: expected all four types");

    doc.setActive(1);
    order.touch(SelType.Edge);
    mode = EditMode.Edges;
    auto afterSwitch = read(model);
    assert(ids(afterSwitch["selectedEdges"]) == [0, 5]
        && ids(afterSwitch["selectedFaces"]) == [4],
        "next read after primary switch must read B's distinct marks, not cached A");
    assert(ids(afterSwitch["selectedEdges"]).length == 2
        && ids(afterSwitch["selectedFaces"]).length == 1,
        "switched selected-id comparisons must be populated");
    assert(tokens(afterSwitch["selTypeOrder"])
        == ["edge", "vertex", "polygon", "item"],
        "next read after front switch must read the live parsed order");
    assert(afterSwitch["items"].array.length == 2,
        "switched item comparison population floor: expected two rows");
    assert(afterSwitch["items"][0]["selected"].type == JSONType.false_
        && afterSwitch["items"][1]["selected"].type == JSONType.true_,
        "next read after primary switch must read the live item selection");

    doc.selectItem(layerA, SelMode.Add);
    order.touch(SelType.Item);
    auto afterItemAdd = read(model);
    assert(afterItemAdd["items"].array.length == 2,
        "item-add comparison population floor: expected two rows");
    assert(afterItemAdd["items"][0]["selected"].type == JSONType.true_
        && afterItemAdd["items"][1]["selected"].type == JSONType.true_,
        "next read after item add must contain both selected rows");
    assert(tokens(afterItemAdd["selTypeOrder"])
        == ["item", "edge", "vertex", "polygon"],
        "item promotion must lead the parsed order while geometry mode remains edges");
    assert(afterItemAdd["mode"].str == "edges",
        "derived geometry mode must remain the most-recent geometry type");

    auto loaded = Document.bootstrap(makeCube());
    loaded.layers[0].name = "Loaded";
    loaded.activeMesh().syncSelection();
    loaded.activeMesh().selectFace(3);
    doc = loaded;
    order.touch(SelType.Polygon);
    mode = EditMode.Polygons;
    auto afterLoad = read(model);
    assert(afterLoad["items"].array.length == 1,
        "next read after document load must see the replacement layer count");
    assert(ids(afterLoad["selectedFaces"]) == [3],
        "next read after document load must see the replacement mesh marks");
    assert(ids(afterLoad["selectedFaces"]).length == 1,
        "loaded selected-id comparison population floor: expected one face id");
    assert(ids(afterLoad["selectedVertices"]).length == 0
        && ids(afterLoad["selectedEdges"]).length == 0,
        "replacement mesh must not inherit marks from either old layer");
    assert(tokens(afterLoad["selTypeOrder"])
        == ["polygon", "item", "edge", "vertex"],
        "next read after document load must retain the live parsed order");
}

unittest { // no target never substitutes an arbitrary populated layer
    Document doc;
    auto layerA = new Layer;
    layerA.name = "A";
    layerA.meshRef() = makeCube();
    layerA.meshRef().syncSelection();
    layerA.meshRef().selectVertex(2);
    auto layerB = new Layer;
    layerB.name = "B";
    layerB.meshRef() = makeCube();
    layerB.meshRef().syncSelection();
    layerB.meshRef().selectEdge(6);
    doc.layers = [layerA, layerB];

    SelTypeOrder order;
    order.touch(SelType.Item);
    EditMode mode = EditMode.Vertices;
    auto input = SelectionProjectionInput(
        &doc, &order, mode, doc.activeMesh());
    auto payload = parseJSON(encodeSelectionProjection(input));

    assert(doc.layers.length == 2
        && layerA.meshRef().vertices.length == 8
        && layerB.meshRef().vertices.length == 8,
        "no-target fixture population floor: two populated layers must remain available");
    assert(doc.activeMesh() is null,
        "no-target fixture must not accidentally install an edit target");
    assert(payload["items"].array.length == 2,
        "no-target item comparison population floor: expected two rows");
    foreach (item; payload["items"].array)
        assert(item["selected"].type == JSONType.false_
            && item["primary"].type == JSONType.false_,
            "no-target projection must report no selected or primary row");
    assert(ids(payload["selectedVertices"]).length == 0
        && ids(payload["selectedEdges"]).length == 0
        && ids(payload["selectedFaces"]).length == 0,
        "no-target projection must emit empty ids, not A's vertex or B's edge marks");
    assert(tokens(payload["selTypeOrder"])
        == ["item", "vertex", "edge", "polygon"],
        "no-target projection must still report the live parsed order");
    assert(payload["mode"].str == "vertices",
        "item front must preserve the derived geometry mode invariant");
}

