// The camera's ROTATION over the wire, as the 3x3 the camera actually stores.
//
// The headline is the round trip: an ARBITRARY orientation must survive
// View -> serialise -> parse -> View bit-exactly. "Arbitrary" is the load-
// bearing word. The camera used to be two angles plus a scalar bank, and there
// are rotations no such triple can name at all -- the composition of turns
// about different axes, and anything at a pole, where heading and bank are the
// same motion. A test that only round-trips a camera the old model could
// express would pass on the old model too and prove nothing.
//
// It is also bit-EXACT rather than approximate, which the six-decimal `%f` the
// other camera fields use cannot be. A lossy round trip is not a rounding
// curiosity here: the stored matrix IS the camera, so a save/load cycle that
// loses mantissa bits tilts the horizon a little every time, and the drift is
// cumulative over a session of opening and closing a document.
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs, sin, cos, PI;
import std.conv : to;
import std.format : format;

void main() {}

private bool approxEqual(double a, double b, double epsilon = 1e-4) {
    return fabs(a - b) < epsilon;
}

private JSONValue camera() {
    return parseJSON(cast(string) get(testBaseUrl() ~ "/api/camera"));
}

private void postCamera(string body_) {
    auto http = HTTP();
    http.addRequestHeader("Content-Type", "application/json");
    post(testBaseUrl() ~ "/api/camera", body_, http);
}

private double[9] orientationOf(JSONValue j) {
    assert("orientation" in j, "GET /api/camera must publish the orientation");
    auto arr = j["orientation"].array;
    assert(arr.length == 9, "the orientation must be nine numbers, got "
                            ~ arr.length.to!string);
    double[9] o;
    foreach (i, ref e; arr)
        o[i] = e.type == JSONType.integer ? cast(double) e.integer : e.floating;
    return o;
}

/// A rotation NO azimuth/elevation/bank camera could be driven to by the old
/// model: start level, then turn about two different, non-vertical world axes.
/// Built here in double precision and rounded to float exactly as the camera
/// would hold it, so the value posted is a legal orientation rather than a
/// hand-typed near-rotation.
private double[9] obliqueOrientation() {
    // Column-major, columns = right / up / back.
    double[9] m = [1, 0, 0,  0, 1, 0,  0, 0, 1];
    static double[9] rotAbout(double[9] m, double[3] k, double a) {
        immutable double c = cos(a), s = sin(a);
        double[9] o;
        foreach (col; 0 .. 3) {
            immutable double vx = m[col*3+0], vy = m[col*3+1], vz = m[col*3+2];
            immutable double kv = k[0]*vx + k[1]*vy + k[2]*vz;
            o[col*3+0] = vx*c + (k[1]*vz - k[2]*vy)*s + k[0]*kv*(1-c);
            o[col*3+1] = vy*c + (k[2]*vx - k[0]*vz)*s + k[1]*kv*(1-c);
            o[col*3+2] = vz*c + (k[0]*vy - k[1]*vx)*s + k[2]*kv*(1-c);
        }
        return o;
    }
    m = rotAbout(m, [1.0, 0.0, 0.0], 0.7);
    m = rotAbout(m, [0.0, 0.0, 1.0], -1.1);
    m = rotAbout(m, [0.4082482905, 0.8164965809, 0.4082482905], 0.55);
    // Round through float so what we post is exactly representable.
    foreach (ref v; m) v = cast(double)(cast(float) v);
    return m;
}

unittest { // GET publishes the orientation, and it is the camera it describes
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    auto j = camera();
    auto o = orientationOf(j);

    // Columns are right / up / back: orthonormal, right-handed, and the BACK
    // column is the direction from the focus toward the eye — so it must agree
    // with the published eye, which is derived independently of the matrix
    // fields in the JSON.
    foreach (col; 0 .. 3) {
        immutable double len = o[col*3]*o[col*3] + o[col*3+1]*o[col*3+1]
                             + o[col*3+2]*o[col*3+2];
        assert(approxEqual(len, 1.0, 1e-5),
               "orientation column " ~ col.to!string ~ " must be unit, got "
               ~ len.to!string);
    }
    immutable double d = j["distance"].floating;
    foreach (i, k; ["x", "y", "z"])
        assert(approxEqual(o[6 + i] * d, j["eye"][k].floating, 1e-4),
               "the back column times the distance must be the published eye "
               ~ "(component " ~ k ~ ")");
}

unittest { // the round trip is BIT-EXACT for an orientation no chart can name
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    auto want = obliqueOrientation();

    string body_ = "{\"orientation\":[";
    foreach (i, v; want) body_ ~= (i ? "," : "") ~ format("%.9g", v);
    body_ ~= "]}";
    postCamera(body_);

    auto got = orientationOf(camera());

    // Compared at FLOAT precision, which is the claim: the camera stores
    // floats, the wire carries nine significant digits, and nine digits is
    // exactly what pins a float. (Comparing the parsed doubles would fail on
    // every value for a reason that has nothing to do with the camera — the
    // decimal that uniquely identifies a float is not the decimal that
    // uniquely identifies the double nearest it.)
    foreach (i; 0 .. 9)
        assert(cast(float) got[i] == cast(float) want[i],
               format("orientation[%d] must survive the round trip exactly: "
                      ~ "sent %.9g, got back %.9g", i, want[i], got[i]));

    // ...and it really is an orientation the old model could not hold. The
    // pre-matrix camera forced screen-right into the world XZ plane whenever
    // the bank was zero, and could only leave it by a bank about the VIEW
    // axis. Here both the screen-right y AND a second independent term are
    // non-zero, which no (azimuth, elevation) pair reproduces on its own.
    assert(fabs(want[1]) > 0.05,
           "the test orientation must carry a non-level horizon, else it says "
           ~ "nothing the two-angle camera could not already say");

    // A second, independent read: post it again and the camera must not move
    // at all. A reader that lands on a NEARBY rotation instead of a fixed
    // point would creep on every repeat.
    postCamera(body_);
    auto again = orientationOf(camera());
    foreach (i; 0 .. 9)
        assert(cast(float) again[i] == cast(float) got[i],
               format("re-posting the same orientation must be a no-op at "
                      ~ "index %d: %.9g then %.9g", i, got[i], again[i]));
}

unittest { // a NON-orthonormal matrix is repaired, not rejected and not kept
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    // A visibly drifted matrix — the shape a measured orientation from another
    // instrument arrives in. It must be accepted and cleaned, because refusing
    // it would make the field useless for the thing it exists for.
    postCamera(`{"orientation":[0.98,0.03,-0.02, -0.01,1.04,0.05, 0.03,-0.06,0.97]}`);
    auto o = orientationOf(camera());
    foreach (col; 0 .. 3) {
        immutable double len = o[col*3]*o[col*3] + o[col*3+1]*o[col*3+1]
                             + o[col*3+2]*o[col*3+2];
        assert(approxEqual(len, 1.0, 1e-5),
               "a drifted orientation must be normalised on the way in, column "
               ~ col.to!string ~ " length " ~ len.to!string);
    }
    // Right . up must be zero — the input's was not.
    immutable double ru = o[0]*o[3] + o[1]*o[4] + o[2]*o[5];
    assert(fabs(ru) < 1e-5,
           "the repaired basis must be orthogonal, right.up = " ~ ru.to!string);
}

unittest { // a malformed orientation leaves the camera where it was
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    postCamera(`{"azimuth":1.25,"elevation":0.3}`);
    auto before = orientationOf(camera());
    // Wrong arity: must be refused as a unit, not partially applied.
    try {
        postCamera(`{"orientation":[1,0,0,0,1,0]}`);
    } catch (Exception) {
        // An error status is the expected outcome; what matters is the camera.
    }
    auto after = orientationOf(camera());
    foreach (i; 0 .. 9)
        assert(cast(float) after[i] == cast(float) before[i],
               "a malformed orientation must not move the camera, index "
               ~ i.to!string);
}

unittest { // the angles are a READ of the matrix, and agree with it
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    postCamera(`{"azimuth":-0.5040186,"elevation":0.4138754,"roll":0.2055634}`);
    auto j = camera();
    auto o = orientationOf(j);

    assert(approxEqual(j["azimuth"].floating,   -0.5040186, 1e-5),
           "azimuth must read back what was written");
    assert(approxEqual(j["elevation"].floating,  0.4138754, 1e-5),
           "elevation must read back what was written");
    assert(approxEqual(j["roll"].floating,       0.2055634, 1e-5),
           "roll must read back what was written");

    // The published matrix is the SAME camera the published angles name: this
    // is the recorded reference basis for that heading/pitch/bank triple.
    assert(approxEqual(o[0],  0.817569, 1e-4), "screen-right.x");
    assert(approxEqual(o[1], -0.186885, 1e-4), "screen-right.y");
    assert(approxEqual(o[2],  0.544661, 1e-4), "screen-right.z");
    assert(approxEqual(o[3],  0.368870, 1e-4), "screen-up.x");
    assert(approxEqual(o[4],  0.896293, 1e-4), "screen-up.y");
    assert(approxEqual(o[5], -0.246158, 1e-4), "screen-up.z");
    // back == -forward
    assert(approxEqual(o[6], -0.442173, 1e-4), "back.x");
    assert(approxEqual(o[7],  0.402161, 1e-4), "back.y");
    assert(approxEqual(o[8],  0.801717, 1e-4), "back.z");
}
