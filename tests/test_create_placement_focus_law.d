// A placement gesture takes its depth from camera focus. The tolerance is
// wider than one 0.05 m step because this test pins the coupling, not rounding.

import create_law_helpers;
import drag_helpers : fetchCamera;
import http_client : testBaseUrl;
import std.format : format;
import std.json : parseJSON;
import std.math : abs;

void main() {}

double placeAtFocus(double focus, bool pinned, V3 planeOrigin,
                    V3 planeEuler, size_t vertexFloor) {
    resetCreateCell(V3(0, 0, focus), pinned, planeOrigin, planeEuler);
    auto camera = fetchCamera(testBaseUrl);
    immutable int cx = camera.vpX + camera.width / 2;
    immutable int cy = camera.vpY + camera.height / 2;
    dragPixels(cx + 64, cy - 64, cx + 128, cy - 128);
    immutable double depth = attribute("cenZ");
    auto vertices = commitAndVertexCount();
    assert(vertices >= vertexFloor,
        format("focus %.3f pinned=%s: population floor %d, got %d vertices",
               focus, pinned, vertexFloor, vertices));
    return depth;
}

unittest {
    auto fixture = parseJSON(import("fixtures/create_placement_focus_law.json"));
    immutable double tolerance = number(fixture["tolerance"]);
    immutable double planeZ = number(fixture["pinned_plane_z"]);
    immutable size_t vertexFloor = cast(size_t)number(fixture["vertex_floor"]);

    auto pinned = fixture["pinned_controls"].array;
    assert(pinned.length == 2,
        format("pinned control population must be 2, got %d", pinned.length));

    // This cell remains green if focus is wrongly replaced by world origin.
    immutable double zeroFocus = number(pinned[0]["focus"]);
    immutable double zeroExpected = number(pinned[0]["depth"]);
    immutable double zeroActual = placeAtFocus(
        zeroFocus, true, V3(0, 0, planeZ), V3(0, 0, 0), vertexFloor);
    assert(abs(zeroActual - zeroExpected) <= tolerance,
        format("pinned focus %.3f: expected depth %.3f, actual %.3f",
               zeroFocus, zeroExpected, zeroActual));

    auto sweep = fixture["focus_depths"].array;
    assert(sweep.length == 5,
        format("focus sweep population must be 5, got %d", sweep.length));
    foreach (cell; sweep) {
        immutable double focus = number(cell);
        immutable double actual = placeAtFocus(
            focus, false, V3(0, 0, 0), V3(0, 0, 0), vertexFloor);
        assert(abs(actual - focus) <= tolerance,
            format("focus %.3f: expected equal depth, actual %.3f", focus, actual));
    }

    // Same pinned plane, moved focus: this separates focus from both origins.
    immutable double movedFocus = number(pinned[1]["focus"]);
    immutable double movedExpected = number(pinned[1]["depth"]);
    immutable double movedActual = placeAtFocus(
        movedFocus, true, V3(0, 0, planeZ), V3(0, 0, 0), vertexFloor);
    assert(abs(movedActual - movedExpected) <= tolerance,
        format("pinned focus %.3f: expected depth %.3f, actual %.3f",
               movedFocus, movedExpected, movedActual));

    auto oblique = fixture["oblique_pinned_controls"].array;
    assert(oblique.length == 3,
        format("oblique pinned population must be 3, got %d", oblique.length));
    foreach (i, cell; oblique) {
        immutable double focus = number(cell["focus"]);
        immutable double expected = number(cell["depth"]);
        immutable double actual = placeAtFocus(
            focus, true, vector(cell["plane_origin"]),
            vector(cell["plane_euler_deg"]), vertexFloor);
        assert(abs(actual - expected) <= tolerance,
            format("oblique pinned cell %d focus %.3f: expected depth %.3f, actual %.3f",
                   i, focus, expected, actual));
    }
}
