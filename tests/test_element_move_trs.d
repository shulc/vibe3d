// xfrm.elementMove TRS attr surface tests:
//   - xfrm.elementMove preset = xfrm.transform with T=1/R=0/S=0.
//     Only TX/TY/TZ apply
//     via tool.doApply; RX/RY/RZ/SX/SY/SZ are no-ops on this
//     preset — the user activates Transform (T=R=S=1) or
//     TransformRotate / TransformScale for rotate/scale around a
//     picked centre.
//   - Pivot follows pickedCenter (queryActionCenter on
//     XfrmTransformTool reads the FalloffStage when Element falloff
//     is active).

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, cos, sin, PI;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

unittest { // Translate-only: TX=0.3 with pickedCenter at +X+Y+Z
           // corner and dist=0.5. Empty selection ⇒ all verts in
           // moving set; only the +X+Y+Z corner sits inside the
           // sphere (distance 0 → weight 1), so it shifts by +0.3
           // in X. Other corners are at √(0.25·3) ≈ 0.87 from
           // pickedCenter > 0.5 → weight 0.
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // v6 = +X+Y+Z corner (index 6 on the default cube).
    assert(approxEq(verts[6][0], 0.8, 1e-3),
        "v6 at pickedCenter should shift by full TX; got x="
        ~ verts[6][0].to!string);
    foreach (i; 0 .. 8) {
        if (i == 6) continue;
        // Other corners untouched (outside the sphere).
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(verts[i][c]), 0.5, 1e-3),
                "non-picked v" ~ i.to!string ~ " stays put; got "
                ~ verts[i][c].to!string);
    }
}

unittest { // RX/RY/RZ attrs on xfrm.elementMove are NO-OPS — the
           // preset is T-only (R=0/S=0). Set RY=90 and verify the
           // mesh is untouched.
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove RY 90");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts)
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "R-flag off ⇒ RY=90 no-op; got " ~ v[c].to!string);
}

unittest { // SX/SY/SZ likewise no-ops on the T-only preset.
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove SX 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts)
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "S-flag off ⇒ SX=2 no-op; got " ~ v[c].to!string);
}

unittest { // T+R+S under Element falloff, with six off-centre fractional weights.
           // Formula: F(p)=c+S*R*(p-c)+T; p'=p+w(p)*(F(p)-p).
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 1.5");
    cmd("tool.attr Transform TX 0.3");
    cmd("tool.attr Transform RY 90");
    cmd("tool.attr Transform SX 2.0");
    cmd("tool.attr Transform SY 2.0");
    cmd("tool.attr Transform SZ 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    immutable double[3] centre = [0.5, 0.5, 0.5];
    immutable double[3] translate = [0.3, 0.0, 0.0];
    immutable double scale = 2.0, range = 1.5;
    immutable double[3][8] base = [
        [-0.5,-0.5,-0.5], [0.5,-0.5,-0.5], [0.5,0.5,-0.5], [-0.5,0.5,-0.5],
        [-0.5,-0.5, 0.5], [0.5,-0.5, 0.5], [0.5,0.5, 0.5], [-0.5,0.5, 0.5]
    ];
    int partialWeights;
    double maxRivalSeparation = 0.0;
    double[3][8] expectedAll;
    foreach (vi; 0 .. 8) {
        const point = base[vi];
        immutable double[3] d = [point[0]-centre[0], point[1]-centre[1],
                                  point[2]-centre[2]];
        double weight = 1.0 - sqrt(d[0]^^2 + d[1]^^2 + d[2]^^2) / range;
        if (weight < 0) weight = 0;
        if (weight > 1e-3 && weight < 1.0-1e-3) ++partialWeights;

        immutable double[3] rotatedScaled = [scale*d[2], scale*d[1], -scale*d[0]];
        immutable double[3] full = [centre[0]+rotatedScaled[0]+translate[0],
                                     centre[1]+rotatedScaled[1]+translate[1],
                                     centre[2]+rotatedScaled[2]+translate[2]];
        immutable double[3] expected = [point[0]+weight*(full[0]-point[0]),
                                         point[1]+weight*(full[1]-point[1]),
                                         point[2]+weight*(full[2]-point[2])];
        expectedAll[vi] = expected;

        // Rival: translation inside R/S, where S scales T.
        immutable double[3] rivalLinear = [scale*d[2], scale*d[1],
                                            -scale*(d[0]+translate[0])];
        immutable double[3] rival = [point[0]+weight*(centre[0]+rivalLinear[0]-point[0]),
                                      point[1]+weight*(centre[1]+rivalLinear[1]-point[1]),
                                      point[2]+weight*(centre[2]+rivalLinear[2]-point[2])];
        immutable double separation = sqrt((expected[0]-rival[0])^^2
                                           +(expected[1]-rival[1])^^2
                                           +(expected[2]-rival[2])^^2);
        if (separation > maxRivalSeparation) maxRivalSeparation = separation;
    }
    assert(partialWeights == 6,
        "6207 witness needs six vertices with 0<w<1");
    assert(maxRivalSeparation > 0.1,
        "6207 witness must separate translation from the linear fold");

    foreach (vi; 0 .. 8)
        foreach (k; 0 .. 3)
            assert(approxEq(verts[vi][k], expectedAll[vi][k], 1e-5),
                "6207 weighted composition law: v" ~ vi.to!string
                ~ " expected " ~ expectedAll[vi].to!string
                ~ "; got " ~ verts[vi].to!string);

    immutable double v1Weight = 1.0 - sqrt(2.0) / 1.5;
    assert(approxEq(v1Weight, 0.057191, 1e-6)
        && approxEq(verts[1][0], 0.402775, 1e-5)
        && approxEq(verts[1][1], -0.557191, 1e-5)
        && approxEq(verts[1][2], -0.442809, 1e-5),
        "6207 off-centre v1 must follow the formula-derived weighted result");
}
