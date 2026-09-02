// Frozen measured law for the transform gizmo's ported axis arm (task 3820).
//
// ORDER IS PART OF THE CONTRACT. Druntime stops a module at its first failed
// assert, so blocks 1..6 deliberately put the stand, flat gain, quantum,
// composition, perpendicular cells, and legacy contrast in that order. Inside
// block 6 the scale contrast runs before the per-camera perspective contrast,
// in separate passes; reaching the latter proves the former (and its explicit
// population floor) ran and passed.
//
// `Fine` here is INFERRED, not read. The capture never read the rounding
// preference back; the mode is pinned because the three observed steps match
// `stepLadderCeil(pixel_size)` and no other ladder branch. If the reference is
// later shown to have been on another mode, this block's argument moves and the
// fixture's numbers do not.
//
// The camera checks reconstruct an oblique perspective viewport and read it
// back. The foreshortening and screen-direction checks are independent of the
// production drag conversion. The `viewWorldPerPixel` check is cyclic by
// construction because focalPx is chosen from pixel_size; it catches gross
// stand errors (projection kind, unset eye/focus, sign), not the measured law.
module tests.unit.drag_gain_oblique_test;

import coord_rounding : CoordinateRounding;
import drag : axisArmDelta, axisArmDeltaUnsnapped,
              axisDragRoundingStep, screenAxisDelta, viewWorldPerPixel;
import handler : getGizmoPixels, gizmoSize, setGizmoPixels;
import math : Vec3, Viewport, dot, lookAt, perspectiveMatrix;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, atan, sqrt;
import std.path : buildPath, dirName;
import std.string : endsWith, startsWith;

private enum string kFixtureName = "drag_gain_oblique.json";

private double asDouble(JSONValue v)
{
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        default:
            assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private int asInt(JSONValue v)
{
    switch (v.type) {
        case JSONType.integer:  return cast(int)v.integer;
        case JSONType.uinteger: return cast(int)v.uinteger;
        default:
            assert(false, "fixture: expected an integer, got " ~ v.toString);
    }
}

private Vec3 asVec3(JSONValue v)
{
    assert(v.type == JSONType.array && v.array.length == 3,
           "fixture: expected a three-component vector");
    return Vec3(cast(float)asDouble(v.array[0]),
                cast(float)asDouble(v.array[1]),
                cast(float)asDouble(v.array[2]));
}

private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded;
    if (!loaded) {
        immutable path = buildPath(dirName(dirName(__FILE_FULL_PATH__)),
                                   "fixtures", kFixtureName);
        cached = parseJSON(readText(path));
        loaded = true;
    }
    return cached;
}

private Vec3 axisOf(JSONValue cell)
{
    switch (cell["axis"].str) {
        case "x": return Vec3(1, 0, 0);
        case "y": return Vec3(0, 1, 0);
        case "z": return Vec3(0, 0, 1);
        default: assert(false, cell["name"].str ~ ": invalid axis");
    }
}

private double expectedScalar(JSONValue cell)
{
    auto expected = cell["expected_world_delta"].array;
    switch (cell["axis"].str) {
        case "x": return asDouble(expected[0]);
        case "y": return asDouble(expected[1]);
        case "z": return asDouble(expected[2]);
        default: assert(false, cell["name"].str ~ ": invalid axis");
    }
}

private double screenDot(JSONValue cell)
{
    auto drag = cell["drag_px"].array;
    auto dir = cell["screen_dir"].array;
    return asDouble(drag[0]) * asDouble(dir[0])
         + asDouble(drag[1]) * asDouble(dir[1]);
}

private string cameraName(JSONValue cell)
{
    immutable name = cell["name"].str;
    assert(name.length >= 3 && name[0] == 'c' && name[2] == '_',
           name ~ ": camera prefix must be cN_");
    return name[0 .. 2];
}

private Viewport viewportFor(JSONValue cell)
{
    auto camera = cell["camera"];
    auto rows = camera["rot_matrix"].array;
    assert(rows.length == 3, cell["name"].str ~ ": camera needs three rows");
    immutable Vec3 r1 = asVec3(rows[1]);
    immutable Vec3 r2 = asVec3(rows[2]);
    immutable Vec3 center = asVec3(camera["center"]);
    immutable float distance = cast(float)asDouble(camera["distance"]);
    immutable float pixelSize = cast(float)asDouble(camera["pixel_size"]);
    immutable Vec3 eye = center + r2 * distance;

    auto stand = fixture()["stand"];
    immutable int paneW = asInt(stand["pane_w"]);
    immutable int paneH = asInt(stand["pane_h"]);
    immutable float focalPx = 0.8f * distance / pixelSize;
    immutable float fovy = cast(float)(2.0 * atan(0.5 * paneH / focalPx));

    Viewport vp;
    vp.view = lookAt(eye, center, r1);
    vp.proj = perspectiveMatrix(fovy, cast(float)paneW / paneH,
                                0.01f, 1000.0f);
    vp.width = paneW;
    vp.height = paneH;
    vp.eye = eye;
    vp.focus = center;
    return vp;
}

private void addDistinct(ref double[] values, double value)
{
    foreach (seen; values)
        if (abs(seen - value) <= 1e-12)
            return;
    values ~= value;
}

private struct FloatBits
{
    union {
        float value;
        uint bits;
    }
}

private uint floatBits(float value)
{
    FloatBits converted;
    converted.value = value;
    return converted.bits;
}

private double legacyScalar(JSONValue cell, const ref Viewport vp, float arm)
{
    enum int pressX = 600;
    enum int pressY = 400;
    auto dragPx = cell["drag_px"].array;
    immutable Vec3 center = asVec3(cell["camera"]["center"]);
    immutable Vec3 axis = axisOf(cell);
    bool skip;
    Vec3 delta = screenAxisDelta(pressX + asInt(dragPx[0]),
                                 pressY + asInt(dragPx[1]),
                                 pressX, pressY, center, axis * arm, vp, skip);
    assert(!skip, "block 6: legacy contrast unexpectedly skipped "
                  ~ cell["name"].str);
    return cast(double)dot(delta, axis) / arm;
}

// Block 1 — stand reconstruction and anti-degeneracy.
unittest
{
    auto cells = fixture()["cells"].array;
    assert(cells.length == 22,
           format("block 1: expected 22 cells, found %d", cells.length));

    double[] pixelSizes;
    double[] c1Foreshortening;
    foreach (cell; cells) {
        immutable string name = cell["name"].str;
        immutable Vec3 axis = axisOf(cell);
        auto vp = viewportFor(cell);

        immutable double ax = vp.view[0] * axis.x
                            + vp.view[4] * axis.y
                            + vp.view[8] * axis.z;
        immutable double ay = vp.view[1] * axis.x
                            + vp.view[5] * axis.y
                            + vp.view[9] * axis.z;
        immutable double f = sqrt(ax * ax + ay * ay);
        assert(f <= 0.999,
               format("block 1: %s degenerate camera, f=%.9f", name, f));
        assert(abs(f - asDouble(cell["foreshortening"])) <= 1e-6,
               format("block 1: %s foreshortening %.9f != fixture %.9f",
                      name, f, asDouble(cell["foreshortening"])));

        immutable double fixturePixelSize =
            asDouble(cell["camera"]["pixel_size"]);
        immutable double readPixelSize = viewWorldPerPixel(vp);
        assert(abs(readPixelSize - fixturePixelSize) / fixturePixelSize <= 1e-6,
               format("block 1: %s world-per-pixel %.12g != fixture %.12g",
                      name, readPixelSize, fixturePixelSize));

        immutable double sx = ax / f;
        immutable double sy = -ay / f;
        immutable double wantSx = asDouble(cell["screen_dir"].array[0]);
        immutable double wantSy = asDouble(cell["screen_dir"].array[1]);
        immutable double screenError =
            sqrt((sx - wantSx) * (sx - wantSx)
               + (sy - wantSy) * (sy - wantSy));
        assert(screenError <= 1e-6,
               format("block 1: %s screen direction error %.3g", name,
                      screenError));

        addDistinct(pixelSizes, fixturePixelSize);
        if (startsWith(name, "c1_"))
            addDistinct(c1Foreshortening, f);
    }

    assert(pixelSizes.length >= 3,
           format("block 1: need at least 3 pixel sizes, found %d",
                  pixelSizes.length));
    assert(c1Foreshortening.length >= 3,
           format("block 1: c1 needs at least 3 foreshortenings, found %d",
                  c1Foreshortening.length));
    double fMin = double.max;
    double fMax = 0.0;
    foreach (f; c1Foreshortening) {
        if (f < fMin) fMin = f;
        if (f > fMax) fMax = f;
    }
    assert(fMax / fMin >= 1.2,
           format("block 1: c1 foreshortening spread %.4f < 1.2",
                  fMax / fMin));
}

// Block 2 — flat unsnapped gain, deliberately blind to the quantum.
unittest
{
    size_t n;
    foreach (cell; fixture()["cells"].array) {
        immutable double projectedPixels = screenDot(cell);
        if (abs(projectedPixels) < 10.0)
            continue;

        auto vp = viewportFor(cell);
        auto dragPx = cell["drag_px"].array;
        bool skip;
        immutable float raw = axisArmDeltaUnsnapped(
            600 + asInt(dragPx[0]), 400 + asInt(dragPx[1]), 600, 400,
            asVec3(cell["camera"]["center"]), axisOf(cell), vp, skip);
        assert(!skip, "block 2: ported gain unexpectedly skipped "
                      ~ cell["name"].str);
        immutable double denominator =
            asDouble(cell["camera"]["pixel_size"]) * projectedPixels;
        immutable double ratio = raw / denominator;
        assert(abs(ratio - 1.0) <= 1e-6,
               format("block 2: %s flat gain ratio %.9f != 1",
                      cell["name"].str, ratio));
        ++n;
    }
    assert(n == 16, format("block 2: expected 16 populated cells, found %d", n));
}

// Block 3 — the 1-2-5 quantum, deliberately blind to axis gain.
unittest
{
    static immutable string[3] cameras = ["c1", "c2", "c3"];
    static immutable double[3] expectedSteps = [0.002, 0.001, 0.005];
    auto cells = fixture()["cells"].array;
    foreach (i, camera; cameras) {
        bool found;
        double pixelSize;
        foreach (cell; cells) {
            if (cameraName(cell) != camera)
                continue;
            pixelSize = asDouble(cell["camera"]["pixel_size"]);
            found = true;
            break;
        }
        assert(found, "block 3: missing camera " ~ camera);
        immutable double got = axisDragRoundingStep(
            CoordinateRounding.Fine, pixelSize, 0.01);
        assert(abs(got / expectedSteps[i] - 1.0) <= 1e-12,
               format("block 3: %s quantum expected %.4f, got %.9g",
                      camera, expectedSteps[i], got));
    }
}

// Block 4 — snapped composition and the one-camera/three-axis discriminator.
unittest
{
    uint[3] c1Bits;
    bool[3] c1Seen;
    size_t n;
    foreach (cell; fixture()["cells"].array) {
        if (cell["role"].str != "law")
            continue;
        auto vp = viewportFor(cell);
        auto dragPx = cell["drag_px"].array;
        bool skip;
        immutable float got = axisArmDelta(
            600 + asInt(dragPx[0]), 400 + asInt(dragPx[1]), 600, 400,
            asVec3(cell["camera"]["center"]), axisOf(cell), vp, skip,
            CoordinateRounding.Fine, 0.01f);
        assert(!skip, "block 4: ported composition unexpectedly skipped "
                      ~ cell["name"].str);
        assert(abs(cast(double)got - expectedScalar(cell)) <= 1e-6,
               format("block 4: %s expected %.9g, got %.9g",
                      cell["name"].str, expectedScalar(cell), got));
        ++n;

        switch (cell["name"].str) {
            case "c1_x_par200": c1Bits[0] = floatBits(got); c1Seen[0] = true; break;
            case "c1_y_par200": c1Bits[1] = floatBits(got); c1Seen[1] = true; break;
            case "c1_z_par200": c1Bits[2] = floatBits(got); c1Seen[2] = true; break;
            default: break;
        }
    }
    assert(n == 20, format("block 4: expected 20 law cells, found %d", n));
    immutable bool[3] expectedSeen = [true, true, true];
    assert(c1Seen == expectedSeen,
           "block 4: missing c1 x/y/z parallel discriminator");
    assert(c1Bits[0] == c1Bits[1] && c1Bits[1] == c1Bits[2],
           format("block 4: c1 x/y/z results differ in bits: %08x/%08x/%08x",
                  c1Bits[0], c1Bits[1], c1Bits[2]));
}

// Block 5 — perpendicular drags become zero because the quantum is present.
unittest
{
    size_t n;
    foreach (cell; fixture()["cells"].array) {
        if (cell["role"].str != "law"
            || !endsWith(cell["name"].str, "_perp"))
            continue;
        auto vp = viewportFor(cell);
        auto dragPx = cell["drag_px"].array;
        bool skip;
        immutable float got = axisArmDelta(
            600 + asInt(dragPx[0]), 400 + asInt(dragPx[1]), 600, 400,
            asVec3(cell["camera"]["center"]), axisOf(cell), vp, skip,
            CoordinateRounding.Fine, 0.01f);
        assert(!skip, "block 5: perpendicular cell unexpectedly skipped "
                      ~ cell["name"].str);
        assert(abs(got) <= 1e-9,
               format("block 5: %s expected snapped zero, got %.9g",
                      cell["name"].str, got));
        ++n;
    }
    assert(n == 6, format("block 5: expected 6 perpendicular cells, found %d", n));
}

// Block 6 — current legacy contrast. The owner chose relational checks only:
// no stand-number fixture and no per-cell equality arm.
unittest
{
    auto fx = fixture();
    immutable float savedPx = getGizmoPixels();
    scope(exit) setGizmoPixels(savedPx);
    setGizmoPixels(cast(float)asDouble(fx["stand"]["gizmo_arm_px"]));

    // Pin the global in the only block that reads it, and read the resulting
    // arm back through production code on every cell.
    foreach (cell; fx["cells"].array) {
        auto vp = viewportFor(cell);
        immutable float ps = viewWorldPerPixel(vp);
        immutable float arm = gizmoSize(asVec3(cell["camera"]["center"]),
                                        vp, 1.0f);
        assert(abs(cast(double)(arm / ps) - 150.0) <= 1e-2,
               format("block 6: %s arm/pixel_size %.6f != 150",
                      cell["name"].str, arm / ps));
    }

    // (b) Scale contrast first. Its population floor makes a reached-and-
    // passed result non-vacuous under the later perspective mutation.
    size_t nB;
    foreach (cell; fx["cells"].array) {
        immutable double expected = abs(expectedScalar(cell));
        if (cell["role"].str != "law" || expected <= 1e-12)
            continue;
        auto vp = viewportFor(cell);
        immutable float arm = gizmoSize(asVec3(cell["camera"]["center"]),
                                        vp, 1.0f);
        immutable double ratio = abs(legacyScalar(cell, vp, arm)) / expected;
        assert(ratio >= 1.05,
               format("block 6(b): %s legacy ratio %.4f < 1.05",
                      cell["name"].str, ratio));
        ++nB;
    }
    assert(nB == 14,
           format("block 6(b): expected 14 populated cells, found %d", nB));

    // (c) Perspective contrast second. Gather every camera before asserting
    // spreads so the per-camera population floor runs above the first red.
    static immutable string[3] cameras = ["c1", "c2", "c3"];
    double[3] mins = [double.max, double.max, double.max];
    double[3] maxs = [0.0, 0.0, 0.0];
    size_t[3] nC;
    foreach (cell; fx["cells"].array) {
        immutable double expected = abs(expectedScalar(cell));
        if (cell["role"].str != "law" || expected <= 1e-12)
            continue;
        size_t cameraIndex;
        switch (cameraName(cell)) {
            case "c1": cameraIndex = 0; break;
            case "c2": cameraIndex = 1; break;
            case "c3": cameraIndex = 2; break;
            default: assert(false, "block 6(c): unknown camera");
        }
        auto vp = viewportFor(cell);
        immutable float arm = gizmoSize(asVec3(cell["camera"]["center"]),
                                        vp, 1.0f);
        immutable double ratio = abs(legacyScalar(cell, vp, arm)) / expected;
        if (ratio < mins[cameraIndex]) mins[cameraIndex] = ratio;
        if (ratio > maxs[cameraIndex]) maxs[cameraIndex] = ratio;
        ++nC[cameraIndex];
    }
    immutable size_t[3] expectedNC = [6, 4, 4];
    assert(nC == expectedNC,
           format("block 6(c): expected populations [6,4,4], found [%d,%d,%d]",
                  nC[0], nC[1], nC[2]));
    foreach (i, camera; cameras) {
        immutable double spread = maxs[i] / mins[i];
        assert(spread >= 1.15,
               format("block 6(c): %s perspective spread %.4f < 1.15",
                      camera, spread));
    }
}
