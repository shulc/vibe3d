// Tests for prim.arc headless command.
//
// Exercises the HTTP API surface for ArcTool / buildArc:
//   - Default segments=24 axis=Y    → 25 verts / 24 edges / 0 faces
//   - segments formula grid         → verts==segments+1, edges==segments, faces==0
//   - On-circle + plane             → every vert at radius r from cen in axis plane
//   - Angular range                 → first vert at startAngle, last at endAngle
//   - Axis variations               → topology invariant, axis coord constant
//   - Off-centre centroid           → centroid shifts, count unchanged
//   - JSON vs argstring parity      → identical counts
//   - Undo after prim.arc           → restores empty scene

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, atan2, PI;

void main() {}

string baseUrl = "http://localhost:8080";

string apiUrl(string path) { return baseUrl ~ path; }

JSONValue postJson(string path, string body_)
{
    return parseJSON(cast(string) post(apiUrl(path), body_));
}

JSONValue getModel()
{
    return parseJSON(cast(string) get(apiUrl("/api/model")));
}

void resetEmpty()
{
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

JSONValue primArcArg(string params_)
{
    return postJson("/api/command", "prim.arc " ~ params_);
}

JSONValue primArcJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.arc","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default segments=24 axis=Y → 25 verts / 24 edges / 0 faces
// -------------------------------------------------------------------------

unittest { // default arc counts
    resetEmpty();
    auto resp = primArcArg("segments:24 startAngle:0 endAngle:180 radius:0.5 axis:1");
    assert(resp["status"].str == "ok", "default arc failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 25,
        "default arc: expected 25 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["edges"].array.length == 24,
        "default arc: expected 24 edges, got " ~ m["edges"].array.length.to!string);
    assert(m["faces"].array.length == 0,
        "default arc: expected 0 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. segments formula grid: verts==segments+1, edges==segments, faces==0
// -------------------------------------------------------------------------

unittest { // segments formula across grid
    static immutable int[] segGrid = [1, 2, 3, 8, 24];
    foreach (s; segGrid) {
        resetEmpty();
        auto resp = primArcArg(
            "segments:" ~ s.to!string
            ~ " startAngle:0 endAngle:180 radius:0.5 axis:1");
        assert(resp["status"].str == "ok",
            "segments=" ~ s.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == s + 1,
            "segments=" ~ s.to!string ~ ": expected " ~ (s + 1).to!string ~ " verts, got "
            ~ m["vertices"].array.length.to!string);
        assert(m["edges"].array.length == s,
            "segments=" ~ s.to!string ~ ": expected " ~ s.to!string ~ " edges, got "
            ~ m["edges"].array.length.to!string);
        assert(m["faces"].array.length == 0,
            "segments=" ~ s.to!string ~ ": expected 0 faces");
    }
}

// -------------------------------------------------------------------------
// 3. On-circle geometry: every vert at radius r from cen in the axis plane,
//    axis coord == cen[axis], in-plane angle within [startAngle, endAngle].
//    First vert at startAngle, last at endAngle.
//
// axis=Y(1) → bIdx=2(Z), cIdx=0(X).
// At θ=0°:   Z = radius*cos(0) = radius,  X = radius*sin(0) = 0.
// At θ=180°: Z = radius*cos(π) = -radius, X = radius*sin(π) ≈ 0.
// -------------------------------------------------------------------------

unittest { // on-circle geometry and angular range (axis=Y)
    resetEmpty();
    auto resp = primArcArg(
        "segments:12 startAngle:0 endAngle:180 radius:0.5 axis:1 cenX:0 cenY:0 cenZ:0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    auto verts = m["vertices"].array;
    assert(verts.length == 13, "expected 13 verts");

    foreach (v; verts) {
        double x = v.array[0].floating;
        double y = v.array[1].floating;
        double z = v.array[2].floating;
        // axis coord Y == 0
        assert(fabs(y) < 1e-4, "vert off axis plane: y=" ~ y.to!string);
        // radius in XZ plane
        double r = sqrt(x * x + z * z);
        assert(fabs(r - 0.5) < 1e-4, "vert off radius: r=" ~ r.to!string);
        // in-plane angle within [0°, 180°].
        // atan2 returns values in (-180°, 180°]; the last vertex has
        // sin(π) ≈ -ε (float) so atan2(-ε, -radius) ≈ -180° — normalize
        // by adding 360° when the result is unambiguously the 180° endpoint
        // (angle < -90°) rather than a genuinely out-of-range vertex.
        double angle = atan2(x, z) * (180.0 / PI);  // θ=atan2(sin,cos)=atan2(X,Z)
        if (angle < -90.0) angle += 360.0;           // -180° → +180°
        assert(angle >= -1e-3 && angle <= 180.0 + 1e-3,
            "vert angle out of [0,180]: " ~ angle.to!string);
    }

    // First vert at startAngle=0° → Z=+0.5, X=0
    double x0 = verts[0].array[0].floating;
    double z0 = verts[0].array[2].floating;
    assert(fabs(z0 - 0.5) < 1e-4, "first vert Z expected 0.5, got " ~ z0.to!string);
    assert(fabs(x0)       < 1e-4, "first vert X expected 0.0, got " ~ x0.to!string);

    // Last vert at endAngle=180° → Z=-0.5, X≈0
    double x12 = verts[12].array[0].floating;
    double z12 = verts[12].array[2].floating;
    assert(fabs(z12 - (-0.5)) < 1e-4, "last vert Z expected -0.5, got " ~ z12.to!string);
    assert(fabs(x12)           < 1e-4, "last vert X expected  0.0, got " ~ x12.to!string);
}

// -------------------------------------------------------------------------
// 4. Axis variations: topology invariant; axis coord == cen[axis] for all verts.
// -------------------------------------------------------------------------

unittest { // axis variations preserve counts; plane coord constant
    foreach (ax; [0, 1, 2]) {
        resetEmpty();
        auto resp = primArcArg(
            "segments:6 startAngle:0 endAngle:90 radius:1.0 axis:" ~ ax.to!string);
        assert(resp["status"].str == "ok", "axis=" ~ ax.to!string ~ ": " ~ resp.toString);
        auto m = getModel();
        assert(m["vertices"].array.length == 7,
            "axis=" ~ ax.to!string ~ ": expected 7 verts");
        assert(m["edges"].array.length == 6,
            "axis=" ~ ax.to!string ~ ": expected 6 edges");
        assert(m["faces"].array.length == 0,
            "axis=" ~ ax.to!string ~ ": expected 0 faces");

        foreach (v; m["vertices"].array) {
            double[3] p = [v.array[0].floating,
                           v.array[1].floating,
                           v.array[2].floating];
            // Coord along axis == 0 (cen=0)
            assert(fabs(p[ax]) < 1e-4,
                "axis=" ~ ax.to!string ~ ": axis coord not 0, got " ~ p[ax].to!string);
            // Perp coords on unit circle
            int bIdx2 = (ax + 1) % 3;
            int cIdx2 = (ax + 2) % 3;
            double r = sqrt(p[bIdx2] * p[bIdx2] + p[cIdx2] * p[cIdx2]);
            assert(fabs(r - 1.0) < 1e-3,
                "axis=" ~ ax.to!string ~ ": perp radius not 1, got " ~ r.to!string);
        }
    }
}

// -------------------------------------------------------------------------
// 5. Off-centre: axis coord of all verts == cen[axis]; perp centroid shifts.
// -------------------------------------------------------------------------

unittest { // off-centre centroid
    resetEmpty();
    auto resp = primArcArg(
        "segments:8 startAngle:0 endAngle:180 radius:0.5 axis:1"
        ~ " cenX:2.0 cenY:3.0 cenZ:-1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    auto verts = m["vertices"].array;
    assert(verts.length == 9, "off-centre: expected 9 verts");

    // All Y == cenY = 3.0
    foreach (v; verts) {
        double y = v.array[1].floating;
        assert(fabs(y - 3.0) < 1e-4,
            "off-centre: Y expected 3.0, got " ~ y.to!string);
    }

    // All verts on radius 0.5 from (cenX=2, cenZ=-1) in XZ plane
    foreach (v; verts) {
        double dx = v.array[0].floating - 2.0;
        double dz = v.array[2].floating - (-1.0);
        double r = sqrt(dx * dx + dz * dz);
        assert(fabs(r - 0.5) < 1e-4,
            "off-centre: radius expected 0.5, got " ~ r.to!string);
    }
}

// -------------------------------------------------------------------------
// 6. JSON vs argstring parity
// -------------------------------------------------------------------------

unittest { // JSON vs argstring give identical counts
    resetEmpty();
    primArcArg("segments:12 startAngle:30 endAngle:150 radius:1.0 axis:1");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t eA = ma["edges"].array.length;
    size_t fA = ma["faces"].array.length;

    resetEmpty();
    primArcJson(`"segments":12,"startAngle":30.0,"endAngle":150.0,"radius":1.0,"axis":1`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t eJ = mj["edges"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ, "JSON vs argstring vert count: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(eA == eJ, "JSON vs argstring edge count: " ~ eA.to!string ~ " vs " ~ eJ.to!string);
    assert(fA == fJ, "JSON vs argstring face count: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    // segments=12 → 13 verts, 12 edges, 0 faces
    assert(vA == 13, "expected 13 verts, got " ~ vA.to!string);
    assert(eA == 12, "expected 12 edges, got " ~ eA.to!string);
    assert(fA == 0,  "expected 0 faces,  got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 7. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo restores empty
    resetEmpty();
    auto r1 = primArcArg("segments:8 startAngle:0 endAngle:90 radius:1.0 axis:1");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 9, "before undo: expected 9 verts");
    assert(m1["edges"].array.length == 8,    "before undo: expected 8 edges");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
    assert(m2["edges"].array.length == 0,
        "after undo: expected 0 edges, got " ~ m2["edges"].array.length.to!string);
}
