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

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, cos, sin, PI;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
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
    postJson("/api/reset", "");
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
    postJson("/api/reset", "");
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
    postJson("/api/reset", "");
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

unittest { // Full T+R+S chain via the unified `Transform` preset (T=R=S=1),
           // exercising the MS-4.3 canonical-matrix FOLD. pickedCenter at the
           // corner (0.5,0.5,0.5) + empty selection: v6 sits AT that corner and
           // is the only vertex inside the 0.5 element-falloff sphere, with
           // weight==1 at its BASELINE position.
           //
           // applyTRS now COMPOSES the whole chain into ONE pivot-relative matrix
           // M = S·R·T and applies it once with that single baseline weight
           // (MS-4.1/4.2: this is the reference model). v6 is AT the pivot, so
           // M·(v6-pivot)=0 and only M's composed translation moves it:
           //   t = S·R·delta,  delta = (0.3,0,0) (TX along world X)
           //   RY=90 sends (0.3,0,0) → (0,0,-0.3);  SX=2 leaves Z untouched
           //   ⇒ v6 = pivot + (0,0,-0.3) = (0.5, 0.5, 0.2).
           //
           // (The pre-fold per-pass chain translated v6 OFF the pivot FIRST at
           // full weight, then rotated/scaled the displaced point at a REDUCED
           // live weight, yielding +X — the divergence MS-4 corrects.)
    postJson("/api/reset", "");
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr Transform TX 0.3");
    cmd("tool.attr Transform RY 90");
    cmd("tool.attr Transform SX 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    assert(approxEq(verts[6][0], 0.5, 1e-4)
        && approxEq(verts[6][1], 0.5, 1e-4)
        && approxEq(verts[6][2], 0.2, 1e-4),
        "Transform T→R→S fold: v6 must be the composed-matrix result "
        ~ "(0.5,0.5,0.2); got " ~ verts[6].to!string);
}
