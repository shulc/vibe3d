import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.file : read;

void main() {}

bool approxEqual(double a, double b, double epsilon = 1e-4) {
    return fabs(a - b) < epsilon;
}

struct CameraState {
    double azimuth, elevation, distance;
    double focusX, focusY, focusZ;
    double eyeX, eyeY, eyeZ;
    int width, height;
}

void assertCameraState(JSONValue json, CameraState expected, double epsilon = 1e-4) {
    auto focus = json["focus"];
    auto eye   = json["eye"];

    assert(approxEqual(json["azimuth"].floating,   expected.azimuth,   epsilon), "azimuth mismatch");
    assert(approxEqual(json["elevation"].floating, expected.elevation, epsilon), "elevation mismatch");
    assert(approxEqual(json["distance"].floating,  expected.distance,  epsilon), "distance mismatch");

    assert(approxEqual(focus["x"].floating, expected.focusX, epsilon), "focus.x mismatch");
    assert(approxEqual(focus["y"].floating, expected.focusY, epsilon), "focus.y mismatch");
    assert(approxEqual(focus["z"].floating, expected.focusZ, epsilon), "focus.z mismatch");

    assert(approxEqual(eye["x"].floating, expected.eyeX, epsilon), "eye.x mismatch");
    assert(approxEqual(eye["y"].floating, expected.eyeY, epsilon), "eye.y mismatch");
    assert(approxEqual(eye["z"].floating, expected.eyeZ, epsilon), "eye.z mismatch");

    assert(json["width"].integer  == expected.width,  "width mismatch");
    assert(json["height"].integer == expected.height, "height mismatch");
}

unittest { // Test the /api/camera endpoint
    auto response = get("http://localhost:8080/api/camera");

    auto json = parseJSON(response);

    // Check required fields exist
    assert("azimuth"   in json, "Missing azimuth field");
    assert("elevation" in json, "Missing elevation field");
    assert("distance"  in json, "Missing distance field");
    assert("focus"     in json, "Missing focus field");
    assert("eye"       in json, "Missing eye field");
    assert("width"     in json, "Missing width field");
    assert("height"    in json, "Missing height field");

    // focus and eye must be objects with x/y/z
    auto focus = json["focus"];
    assert("x" in focus, "Missing focus.x");
    assert("y" in focus, "Missing focus.y");
    assert("z" in focus, "Missing focus.z");

    auto eye = json["eye"];
    assert("x" in eye, "Missing eye.x");
    assert("y" in eye, "Missing eye.y");
    assert("z" in eye, "Missing eye.z");

    // Default camera state (View.reset() values)
    assert(approxEqual(json["azimuth"].floating,   0.5),  "azimuth should be 0.5");
    assert(approxEqual(json["elevation"].floating, 0.4),  "elevation should be 0.4");
    assert(approxEqual(json["distance"].floating,  3.0),  "distance should be 3.0");

    assert(approxEqual(focus["x"].floating, 0.0), "focus.x should be 0.0");
    assert(approxEqual(focus["y"].floating, 0.0), "focus.y should be 0.0");
    assert(approxEqual(focus["z"].floating, 0.0), "focus.z should be 0.0");

    // viewport dimensions must be positive
    assert(json["width"].integer  > 0, "width should be positive");
    assert(json["height"].integer > 0, "height should be positive");

    // distance must be positive
    assert(json["distance"].floating > 0.0, "distance should be positive");

    // eye must not coincide with focus (camera is not at origin when distance > 0)
    bool eyeAtFocus = approxEqual(eye["x"].floating, focus["x"].floating) &&
                      approxEqual(eye["y"].floating, focus["y"].floating) &&
                      approxEqual(eye["z"].floating, focus["z"].floating);
    assert(!eyeAtFocus, "eye and focus should not be the same point");
}

unittest { // ROTATE: Test camera state after playing rotate events
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/camera_rotate_events.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/camera"));
    assertCameraState(json, CameraState(
        -0.575, 0.53, 3.0,
        0.0, 0.0, 0.0,
        -1.407673, 1.516600, 2.172183,
        650, 544
    ));
}

unittest { // PAN: Test camera state after playing pan events
    post("http://localhost:8080/api/reset", "");

    auto events = cast(const(void)[])read("tests/events/camera_pan_events.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(playResponse)["status"].str == "success", "play-events failed: " ~ playResponse);

    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    auto json = parseJSON(get("http://localhost:8080/api/camera"));
    assertCameraState(json, CameraState(
        0.5, 0.4, 3.0,
        -0.862409, 0.513952, 0.223529,
        0.462332, 1.682207, 2.648450,
        650, 544
    ));
}

unittest { // ZOOM: Test camera state after playing events from events.log
    // Reset to known initial state before playing events
    post("http://localhost:8080/api/reset", "");

    // Play events — read as raw bytes to preserve newlines
    auto events = cast(const(void)[])read("tests/events/camera_zoom_events.log");
    auto playResponse = post("http://localhost:8080/api/play-events", events);
    auto playJson = parseJSON(playResponse);
    assert(playJson["status"].str == "success", "play-events failed: " ~ playResponse);

    // Wait until all events have been processed
    import core.thread : Thread;
    import core.time : dur;
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }

    // Check camera state
    auto json = parseJSON(get("http://localhost:8080/api/camera"));
    assertCameraState(json, CameraState(
        0.5, 0.4, 19.132467,
        0.0, 0.0, 0.0,
        8.448519, 7.450533, 15.464909,
        650, 544
    ));
}
