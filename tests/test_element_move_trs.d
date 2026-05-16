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

// ElementMoveTool now pivots its transforms around the picked
// element's centroid (Stage 14.10 — MODO ACEN.Element parity).
// That means SX / RY around a picked vert leave the vert in place
// (scale / rotate of a point about itself); only verts AWAY from
// the picked centre move.

unittest { // SX=2 with picked centre AT the +X+Y+Z corner. Pivot is
           // the corner, weight is 1 at the corner, 0 outside the
           // 0.5 sphere. Scaling a point about itself is a no-op, so
           // EVERY vert stays — picked corner pivots on itself,
           // others have weight 0.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove SX 2.0");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "scale-around-self should leave all cube corners "
                ~ "on the ±0.5 box; got " ~ v[c].to!string);
    }
}

unittest { // RY=90 with picked centre at the +X+Y+Z corner. Pivot is
           // the corner → rotating a point about itself is a no-op.
           // All verts stay on the box.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove RY 90");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(v[c]), 0.5, 1e-4),
                "rotate-around-self should leave all cube corners "
                ~ "on the ±0.5 box; got " ~ v[c].to!string);
    }
}

unittest { // T+S combined: TX=0.3 translates the picked corner to
           // (+0.8, +0.5, +0.5) (weight=1). Then SX=2 with pivot =
           // picked center (+0.5, +0.5, +0.5) and CACHED baseline
           // weight = 1: new_x = pivot.x + (curr_x − pivot.x) · sx
           // = 0.5 + (0.8 − 0.5) · 2 = 1.1. Other corners have
           // weight 0 and stay.
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
            && approxEq(v[0], 1.1, 1e-3)) seenFinal = true;
    }
    assert(seenFinal,
        "T+S chain (pivot=picked): expected (1.1, 0.5, 0.5); verts: "
        ~ verts.to!string);
}
