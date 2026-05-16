// Tests for ElementMoveTool's combined T/R/S attrs (Stage 14.5).
// Order of application: translate (TX/TY/TZ) → rotate (RX/RY/RZ) →
// scale (SX/SY/SZ), all around the ACEN pivot, weighted by the
// active falloff stage.

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

unittest { // SX=2.0 only, falloff.element centred at +X+Y+Z corner →
           // only that corner scales 2× along X about ACEN (origin
           // for ACEN.Auto on centered cube ⇒ centroid).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove SX 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // The +X+Y+Z corner should be at (1.0, 0.5, 0.5) after SX=2 about
    // origin (with falloff weight 1 at that corner).
    bool seenScaled = false;
    foreach (v; verts) {
        if (approxEq(v[1], 0.5) && approxEq(v[2], 0.5)
            && approxEq(v[0], 1.0)) seenScaled = true;
    }
    assert(seenScaled,
        "+X+Y+Z corner should scale 2× along X to (1.0, 0.5, 0.5)");
    // All other corners are outside the 0.5 sphere from (0.5,0.5,0.5);
    // they stay put.
    foreach (v; verts) {
        bool isScaled = approxEq(v[0], 1.0)
                     && approxEq(v[1], 0.5)
                     && approxEq(v[2], 0.5);
        if (isScaled) continue;
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "non-picked corner should stay on ±0.5 box");
    }
}

unittest { // RY=90 only, picked centre at corner (+0.5,+0.5,+0.5)
           // dist=0.5 → only that corner rotates 90° around Y axis
           // through ACEN.Auto (origin on centered cube).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove RY 90");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // (0.5, 0.5, 0.5) rotated 90° around Y axis through origin =
    // (0.5·cos90 + 0.5·sin90, 0.5, -0.5·sin90 + 0.5·cos90)
    //   = (+0.5, 0.5, -0.5).
    bool seenRotated = false;
    foreach (v; verts) {
        if (approxEq(v[0], 0.5) && approxEq(v[1], 0.5)
            && approxEq(v[2], -0.5)) seenRotated = true;
    }
    assert(seenRotated,
        "+X+Y+Z corner should rotate to (+0.5, 0.5, -0.5) under RY=90");
}

unittest { // T+S combined: TX=0.3 (corner to +0.8), then SX=2 around
           // origin. ElementMoveTool snapshots per-vert weights at
           // the BASELINE positions (matches MODO's xfrm.transform
           // single-weight semantic), so the scale step uses the
           // SAME weight=1 as translate. Final x = 0 + 0.8 · 2.0 =
           // 1.6, not 0.8 · 1.4 = 1.12 (which would be the "re-
           // evaluate weight at post-translate position" semantic).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.attr xfrm.elementMove SX 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    bool seenFinal = false;
    foreach (v; verts) {
        if (approxEq(v[1], 0.5, 1e-3) && approxEq(v[2], 0.5, 1e-3)
            && approxEq(v[0], 1.6, 1e-3)) seenFinal = true;
    }
    assert(seenFinal,
        "T+S chain: expected final (1.6, 0.5, 0.5); verts: "
        ~ verts.to!string);
}
