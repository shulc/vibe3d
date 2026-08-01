// Camera BANK over the HTTP camera transfer.
//
// The reason this is an integration test and not only a module unittest:
// the cross-engine harness aligns vibe3d's camera with a reference engine's
// through POST /api/camera before replaying a drag, and a reference view
// publishes THREE rotational terms for itself (heading, pitch, bank). Until
// `roll` existed, the third one had nowhere to go and every transferred
// camera silently arrived with its horizon levelled. This pins that the
// wire carries it.
import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

private bool approxEqual(double a, double b, double epsilon = 1e-4) {
    return fabs(a - b) < epsilon;
}

private JSONValue camera() {
    return parseJSON(cast(string) get("http://localhost:8080/api/camera"));
}

private void postCamera(string body_) {
    auto http = HTTP();
    http.addRequestHeader("Content-Type", "application/json");
    post("http://localhost:8080/api/camera", body_, http);
}

unittest { // GET publishes the bank, and a fresh camera is level
    post("http://localhost:8080/api/reset", "");
    auto j = camera();
    assert("roll" in j, "GET /api/camera must publish a roll field");
    assert(approxEqual(j["roll"].floating, 0.0),
           "a reset camera must be level, got " ~ j["roll"].floating.to!string);
}

unittest { // POST round-trips a bank, and banking does not move the eye
    post("http://localhost:8080/api/reset", "");
    auto before = camera();

    // The bank one reference capture reported for its own view, in radians.
    postCamera(`{"roll":0.2055634}`);
    auto after = camera();

    assert(approxEqual(after["roll"].floating, 0.2055634),
           "POST roll must round-trip, got " ~ after["roll"].floating.to!string);

    // A bank is a rotation about the view axis: azimuth, elevation, distance
    // and the eye position are all invariant under it. If any of these move,
    // roll has been implemented as something other than a bank.
    assert(approxEqual(after["azimuth"].floating,   before["azimuth"].floating),
           "roll must not change azimuth");
    assert(approxEqual(after["elevation"].floating, before["elevation"].floating),
           "roll must not change elevation");
    assert(approxEqual(after["distance"].floating,  before["distance"].floating),
           "roll must not change distance");
    foreach (k; ["x", "y", "z"])
        assert(approxEqual(after["eye"][k].floating, before["eye"][k].floating),
               "roll must not move the eye (" ~ k ~ ")");
}

unittest { // a bank survives an unrelated camera edit, and reset clears it
    post("http://localhost:8080/api/reset", "");
    postCamera(`{"roll":-0.7}`);
    postCamera(`{"distance":5.5}`);
    auto j = camera();
    assert(approxEqual(j["roll"].floating, -0.7),
           "a camera POST that omits roll must leave the bank alone, got "
           ~ j["roll"].floating.to!string);
    assert(approxEqual(j["distance"].floating, 5.5), "distance must have been set");

    post("http://localhost:8080/api/reset", "");
    assert(approxEqual(camera()["roll"].floating, 0.0),
           "/api/reset must level the horizon");
}

unittest { // the full three-term transfer a reference view reports
    // heading / pitch / bank of one recorded reference camera. Azimuth is
    // the negated heading in our parameterisation; elevation is the pitch.
    post("http://localhost:8080/api/reset", "");
    postCamera(`{"azimuth":-0.5040186,"elevation":0.4138754,` ~
               `"distance":1.486323332,"roll":0.2055634}`);
    auto j = camera();
    assert(approxEqual(j["azimuth"].floating,   -0.5040186), "azimuth leg");
    assert(approxEqual(j["elevation"].floating,  0.4138754), "elevation leg");
    assert(approxEqual(j["distance"].floating,   1.486323332), "distance leg");
    assert(approxEqual(j["roll"].floating,       0.2055634),
           "bank leg — the term that could not be transferred before");

    // The eye that camera implies, which the bank must not perturb: the
    // reference recorded its own view direction as
    // (+0.442173, -0.402161, -0.801717) at distance 1.486323332 about the
    // origin, so the eye is that direction negated and scaled.
    auto eye = j["eye"];
    assert(approxEqual(eye["x"].floating, -0.442173 * 1.486323332, 1e-3),
           "eye.x must match the reference view direction");
    assert(approxEqual(eye["y"].floating,  0.402161 * 1.486323332, 1e-3),
           "eye.y must match the reference view direction");
    assert(approxEqual(eye["z"].floating,  0.801717 * 1.486323332, 1e-3),
           "eye.z must match the reference view direction");
    post("http://localhost:8080/api/reset", "");
}
