/// Selection projection reads the active mesh through Document.activeMesh
/// (source/document_selection.d), which differs from Layer.meshRef only inside
/// a prepared lifecycle read. Task 0950's production read scope is contained
/// in prepareArm and cannot span HttpServer.tickAll, so that divergence is not
/// reachable by a production reply; the unit witness constructs the overlap
/// deliberately so main-thread servicing is visible in the payload bytes.
module selection_projection;

import document : Document, tokenOf;
import editmode : EditMode;
import mesh : Mesh;
import seltype : SelTypeOrder, geometryEditMode, selTypeToken;
import std.json : JSONValue;

/// Everything the selection read-model may observe. The mesh is nullable:
/// no edit target means no geometry selection payload, even when the document
/// still contains populated layers (task 5690).
struct SelectionProjectionInput {
    const(Document)* document;
    const(SelTypeOrder)* order;
    EditMode geometryMode;
    const(Mesh)* activeMesh;
}

alias SelectionProjectionAccessor = SelectionProjectionInput delegate();

private string geometryModeToken(EditMode mode) pure nothrow @safe @nogc {
    final switch (mode) {
        case EditMode.Vertices: return "vertices";
        case EditMode.Edges:    return "edges";
        case EditMode.Polygons: return "polygons";
    }
}

private JSONValue selectedIndices(scope const bool[] selected) {
    JSONValue[] result;
    foreach (i, flag; selected)
        if (flag) result ~= JSONValue(i);
    return JSONValue(result);
}

private JSONValue emptyIndices() {
    JSONValue[] result;
    return JSONValue(result);
}

/// Encode one explicit selection projection. This function has no HTTP, UI or
/// application context dependency; callers decide when and where to acquire
/// the input.
string encodeSelectionProjection(scope const ref SelectionProjectionInput input) {
    assert(input.document !is null,
        "selection projection requires a document");
    assert(input.order !is null,
        "selection projection requires a selection order");

    // Task 1906 §3.5 row 26: this provider polls no counter and MUST NOT
    // subscribe to or read `mesh_dirty.g_*Epochs`. Task 0950 moved the whole
    // live acquisition + encode onto the main thread; it did not turn this
    // one-shot request projection into an epoch-keyed cache with a second
    // freshness contract.

    ref const Document document = *input.document;
    ref const SelTypeOrder order = *input.order;

    // Keep the pre-extraction funnel guard at the read boundary. A raw write to
    // the materialized geometry mode must not drift from the order that owns it.
    debug assert(input.geometryMode == geometryEditMode(order.mostRecentGeometry()),
        "editMode drifted from selTypeOrder — a writer bypassed the funnel");

    JSONValue[] orderItems;
    foreach (type; order.order)
        orderItems ~= JSONValue(selTypeToken(type));

    JSONValue[] items;
    foreach (layer; document.layers) {
        auto item = JSONValue.emptyObject;
        item["selected"] = JSONValue(layer.selected);
        item["primary"] = JSONValue(document.isPrimary(layer));
        item["type"] = JSONValue(tokenOf(layer.kind));
        item["focused"] = JSONValue(document.isFocused(layer));
        items ~= item;
    }

    auto root = JSONValue.emptyObject;
    root["mode"] = JSONValue(geometryModeToken(input.geometryMode));
    root["selType"] = JSONValue(selTypeToken(order.current()));
    root["selTypeOrder"] = JSONValue(orderItems);
    root["items"] = JSONValue(items);
    if (input.activeMesh is null) {
        root["selectedVertices"] = emptyIndices();
        root["selectedEdges"] = emptyIndices();
        root["selectedFaces"] = emptyIndices();
    } else {
        root["selectedVertices"] = selectedIndices(
            (*input.activeMesh).selectedVertices);
        root["selectedEdges"] = selectedIndices(
            (*input.activeMesh).selectedEdges);
        root["selectedFaces"] = selectedIndices(
            (*input.activeMesh).selectedFaces);
    }
    return root.toString();
}

/// A live read-model: acquisition happens for every read, so a document swap
/// or primary switch cannot leave a captured Document or Mesh* behind.
final class SelectionProjectionReadModel {
private:
    SelectionProjectionAccessor access_;

public:
    this(SelectionProjectionAccessor access) {
        assert(access !is null,
            "SelectionProjectionReadModel requires a live accessor");
        access_ = access;
    }

    string read() {
        auto input = access_();
        return encodeSelectionProjection(input);
    }
}
