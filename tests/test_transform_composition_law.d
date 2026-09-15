// Captured transform composition law, checked from the formula rather than
// copied application output. Production-path witnesses live in the sibling
// transform, element-falloff, sampling, handle-pose, and item-parity tests.

import std.file : readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, cos, fabs, sin, sqrt;

void main() {}

private double number(JSONValue value)
{
    return value.type == JSONType.integer
        ? cast(double)value.integer : value.floating;
}

private double[3] vector(JSONValue value)
{
    auto a = value.array;
    return [number(a[0]), number(a[1]), number(a[2])];
}

private double distance(double[3] a, double[3] b)
{
    return sqrt((a[0] - b[0])^^2 + (a[1] - b[1])^^2
              + (a[2] - b[2])^^2);
}

// Formula: p' = c + S*R*(p-c) + T. The Y-angle convention is the one used by
// the transform channel: x'=cos(a)x+sin(a)z, z'=-sin(a)x+cos(a)z.
private double[3] composed(double[3] point, double[3] centre,
                           double[3] translation, double angleDegrees,
                           double[3] scale)
{
    immutable double a = angleDegrees * PI / 180.0;
    immutable double x = point[0] - centre[0];
    immutable double y = point[1] - centre[1];
    immutable double z = point[2] - centre[2];
    immutable double[3] rotated = [cos(a)*x + sin(a)*z,
                                    y,
                                   -sin(a)*x + cos(a)*z];
    return [centre[0] + scale[0]*rotated[0] + translation[0],
            centre[1] + scale[1]*rotated[1] + translation[1],
            centre[2] + scale[2]*rotated[2] + translation[2]];
}

unittest // Six captured compositions obey one channel-order-independent law.
{
    const fixture = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"));
    auto cases = fixture["composition"].array;
    assert(cases.length == 6,
        "6207 composition witness requires all six captured cases");

    double minimumRivalSeparation = double.max;
    foreach (entry; cases) {
        const centre = vector(entry["centre"]);
        const translation = vector(entry["translation"]);
        const scale = vector(entry["scale"]);
        const angle = number(entry["rotation_y_degrees"]);
        auto points = entry["points"].array;
        auto expected = entry["expected"].array;
        assert(points.length == expected.length && points.length == 2,
            "6207 each composition cell needs two off-centre points");
        foreach (i; 0 .. points.length) {
            const point = vector(points[i]);
            assert(distance(point, centre) > 1.0,
                "6207 rotation/scale witness must stay off-centre");
            const fromLaw = composed(point, centre, translation, angle, scale);
            const captured = vector(expected[i]);
            assert(distance(fromLaw, captured) <= 1e-5,
                "6207 captured position must equal c+S*R*(p-c)+T");

            // Rival puts translation inside the linear fold.
            immutable double[3] translatedPoint = [point[0] + translation[0],
                                                   point[1] + translation[1],
                                                   point[2] + translation[2]];
            const rival = composed(translatedPoint, centre,
                                   cast(double[3])[0.0, 0.0, 0.0],
                                   angle, scale);
            const separation = distance(fromLaw, rival);
            if (separation > 1e-8 && separation < minimumRivalSeparation)
                minimumRivalSeparation = separation;
        }
    }
    assert(minimumRivalSeparation >= 0.25 - 1e-6,
        "6207 fixture must separate translation outside the linear fold");

    assert(cases[0]["expected"] == cases[2]["expected"],
        "6207 equal T/R channels must be independent of gesture order");
    assert(cases[3]["expected"] == cases[4]["expected"],
        "6207 equal T/S channels must be independent of gesture order");
}

unittest // Item C16 uses the same formula and S does not scale T.
{
    const fixture = parseJSON(readText(
        "tests/fixtures/transform_handle_after_release.json"));
    auto entry = fixture["item_translate_then_scale"];
    const point = vector(entry["point"]);
    const centre = vector(entry["centre"]);
    const translation = vector(entry["translation"]);
    const scale = vector(entry["scale"]);
    const expected = vector(entry["expected_position"]);
    const handle = vector(entry["expected_handle"]);
    const fromLaw = composed(point, centre, translation, 0, scale);
    assert(distance(fromLaw, expected) <= 1e-5,
        "6207 item position must equal c+S*(p-c)+T");
    immutable double[3] scaleTranslationRival = [
        centre[0] + scale[0]*(point[0]-centre[0]+translation[0]),
        centre[1] + scale[1]*(point[1]-centre[1]+translation[1]),
        centre[2] + scale[2]*(point[2]-centre[2]+translation[2])];
    assert(distance(fromLaw, scaleTranslationRival) >= 0.2,
        "6207 item fixture must distinguish scaled translation");
    assert(distance(handle, [centre[0]+translation[0],
                             centre[1]+translation[1],
                             centre[2]+translation[2]]) <= 1e-5,
        "6207 item handle must equal c+T");
}
