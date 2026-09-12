module tests.unit.selection_projection_test;

import document : Document, Layer;
import editmode : EditMode;
import mesh : makeCube;
import selection_projection : SelectionProjectionInput,
    SelectionProjectionReadModel, encodeSelectionProjection;
import seltype : SelMode, SelType, SelTypeOrder;
import std.json : JSONType, JSONValue, parseJSON;

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
