// Symmetry-during-drag test (Stage B2 of doc/test_coverage_plan.md).
//
// Enables X-axis symmetry, selects v6 (the +X+Y+Z corner whose mirror
// is v7 at -X+Y+Z), and drags v6's X-arrow. The pin:
//   • selecting only v6 — the symmetry pair v7 must move by the mirror
//     of v6's delta (no explicit selection bleed).
//   • the X-axis drag direction is REFLECTED across the YZ plane —
//     v6.x grows by Δ, v7.x shrinks by Δ.
//   • after the drag, v7 = mirror(v6) still holds (verts haven't drifted
//     off the symmetry plane).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // X-symm: drag v6.x → v6.x grows, v7.x shrinks by same Δ
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[6]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    string script =
        "tool.set move\n" ~
        "tool.pipe.attr symmetry enabled true\n" ~
        "tool.pipe.attr symmetry axis x\n" ~
        "tool.pipe.attr symmetry offset 0\n";
    auto setResp = post("http://localhost:8080/api/script", script);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set + symmetry config failed: " ~ cast(string)setResp);

    auto pre6 = vertexPos(6);
    auto pre7 = vertexPos(7);
    // Sanity: v6 and v7 sit on opposite sides of the YZ plane.
    assert(approx(pre6[0], 0.5)  && approx(pre7[0], -0.5),
        "default cube: v6.x must be +0.5 and v7.x must be -0.5");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = Vec3(0.5f, 0.5f, 0.5f);  // ACEN.Auto centroid = v6
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "arrowStart off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "arrowEnd off-camera");

    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(80.0 * sdx / sLen);
    int y1 = y0 + cast(int)(80.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto post6 = vertexPos(6);
    auto post7 = vertexPos(7);

    double dx6 = post6[0] - pre6[0];
    double dx7 = post7[0] - pre7[0];
    // Mirror relation: v7's X delta is the negation of v6's X delta.
    assert(dx6 > 0.05,
        "v6.x should grow with +X drag: dx6=" ~ dx6.to!string);
    assert(approx(dx7, -dx6, 1e-3),
        "v7.x should mirror v6.x: dx6=" ~ dx6.to!string ~
        " dx7=" ~ dx7.to!string ~ " (expected dx7=-dx6)");

    // Both verts stay in plane (Y, Z untouched on an X-axis drag).
    assert(approx(post6[1], pre6[1], 1e-3) &&
           approx(post6[2], pre6[2], 1e-3),
        "v6 Y/Z drifted: pre=(" ~ pre6[1].to!string ~ "," ~ pre6[2].to!string ~
        ") post=(" ~ post6[1].to!string ~ "," ~ post6[2].to!string ~ ")");
    assert(approx(post7[1], pre7[1], 1e-3) &&
           approx(post7[2], pre7[2], 1e-3),
        "v7 Y/Z drifted: pre=(" ~ pre7[1].to!string ~ "," ~ pre7[2].to!string ~
        ") post=(" ~ post7[1].to!string ~ "," ~ post7[2].to!string ~ ")");

    // Mirror invariant survives the drag: v6.x + v7.x = 0.
    assert(approx(post6[0] + post7[0], 0.0, 1e-3),
        "symmetry plane drift: v6.x + v7.x = " ~
        (post6[0] + post7[0]).to!string ~ " (expected 0)");
}
