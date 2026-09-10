// A placement drag replaces every typed Position channel. Applying the same
// non-zero Position without a drag is the control: the typed value must stand.

import create_law_helpers;
import http_client : getJson;
import std.format : format;
import std.json : parseJSON;

void main() {}

unittest {
    auto fixture = parseJSON(import("fixtures/create_typed_position_gesture_law.json"));
    immutable double tolerance = number(fixture["tolerance"]);
    immutable V3 typed = vector(fixture["typed_position"]);
    assert(typed.x != 0 && typed.y != 0 && typed.z != 0,
        "typed Position markers must all be non-zero");

    // Control first: without a gesture, applyHeadless must use the typed value.
    auto noGesture = fixture["no_gesture"];
    resetCreateCell(V3(0, 0, 0));
    setPosition(typed);
    setCubeSize(vector(noGesture["size"]));
    command("tool.doApply");
    auto modelVertexCount = getJson("/api/model")["vertices"].array.length;
    immutable size_t noGestureFloor = cast(size_t)number(noGesture["vertex_floor"]);
    assert(modelVertexCount >= noGestureFloor,
        format("no-gesture population floor %d, got %d vertices",
               noGestureFloor, modelVertexCount));
    V3 extent;
    V3 center = modelCenter(extent);
    assert(close(center, vector(noGesture["center"]), tolerance),
        format("no-gesture Position: expected %s, actual %s",
               vector(noGesture["center"]).toString(), center.toString()));
    assert(close(extent, vector(noGesture["extent"]), tolerance),
        format("no-gesture extent: expected %s, actual %s",
               vector(noGesture["extent"]).toString(), extent.toString()));
    command("tool.set prim.cube off");

    auto gestureCells = fixture["gesture_cells"].array;
    assert(gestureCells.length == 2,
        format("gesture cell population must be 2, got %d", gestureCells.length));
    immutable V3 expectedPosition = vector(fixture["position_after_gesture"]);
    immutable V3 expectedSize = vector(fixture["size_after_gesture"]);
    immutable size_t vertexFloor = cast(size_t)number(fixture["vertex_floor"]);

    foreach (i, cell; gestureCells) {
        resetCreateCell(V3(0, 0, 0));
        setPosition(typed);
        setCubeSize(vector(cell["size_before"]));

        V3 start = V3(expectedPosition.x - expectedSize.x * 0.5,
                      expectedPosition.y - expectedSize.y * 0.5, 0);
        V3 finish = V3(expectedPosition.x + expectedSize.x * 0.5,
                       expectedPosition.y + expectedSize.y * 0.5, 0);
        dragAtMetres(start, finish);
        V3 actualPosition = position();
        V3 actualSize = cubeSize();
        auto vertices = commitAndVertexCount();
        assert(vertices >= vertexFloor,
            format("gesture cell %d population floor %d, got %d vertices",
                   i, vertexFloor, vertices));
        assert(close(actualSize, expectedSize, tolerance),
            format("gesture cell %d size: expected %s, actual %s", i,
                   expectedSize.toString(), actualSize.toString()));
        assert(close(actualPosition, expectedPosition, tolerance),
            format("gesture cell %d Position: expected %s, actual %s", i,
                   expectedPosition.toString(), actualPosition.toString()));
    }
}
