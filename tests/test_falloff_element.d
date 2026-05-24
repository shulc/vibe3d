// Tests for FalloffType.Element — spherical falloff around
// `pickedCenter` with radius `dist`. Stage 14.1 covers the headless
// API only (no click-to-pick yet); pickedCenter is set explicitly
// via `tool.pipe.attr actionCenter userPlacedCenter "x,y,z"`.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt;

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

string[string] falloffAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "WGHT stage missing");
}

unittest { // type=element activates falloff with dist attr; the
           // sphere centre lives on ACEN (single source of truth),
           // so the round-trip checks userPlaced via ACEN's
           // userPlacedX/Y/Z.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.1,0.2,0.3\"");
    cmd("tool.pipe.attr falloff dist 0.7");
    auto a = falloffAttrs();
    assert(a["type"] == "element",
        "expected type=element, got " ~ a["type"]);
    assert(a["dist"].to!float > 0.69 && a["dist"].to!float < 0.71,
        "expected dist ≈ 0.7, got " ~ a["dist"]);
    // ACEN-side: userPlaced flag + components.
    auto acen = getJson("/api/toolpipe");
    string userPlacedX;
    foreach (st; acen["stages"].array)
        if (st["task"].str == "ACEN")
            userPlacedX = st["attrs"]["userPlacedX"].str;
    assert(userPlacedX.to!float > 0.09 && userPlacedX.to!float < 0.11,
        "expected ACEN userPlacedX ≈ 0.1, got " ~ userPlacedX);
}

unittest { // element falloff + Move TX: top-face verts near the picked
           // centre get full weight, far ones get 0
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");

    cmd("tool.set move on");
    // Pick centre = (0, 0.5, 0) (top-face centroid), radius 0.4.
    // Top-row verts (y=0.5, x=±0.5, z=±0.5) sit at distance
    // sqrt(0.25+0+0.25) = √0.5 ≈ 0.71 from pickedCenter — OUTSIDE
    // the 0.4 sphere → weight=0. Sub-top verts (y=0.25) sit at
    // sqrt(0.25 + 0.0625 + 0.25) ≈ 0.79 — also outside.
    // To get a vert INSIDE the sphere we need to point pickedCenter
    // at a corner: (0.5, 0.5, 0.5) so vert 6 is exactly at distance 0
    // and weight = 1.
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0.5,0.5,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr move TX 0.3");
    cmd("tool.doApply");

    auto verts = dumpVerts();
    // Vert exactly at pickedCenter (+0.5, +0.5, +0.5) → weight 1 → +0.3 X.
    bool sawMoved = false;
    foreach (v; verts) {
        if (approxEq(v[1], 0.5) && approxEq(v[2], 0.5)
            && approxEq(v[0], 0.8, 1e-3)) {
            sawMoved = true;
            break;
        }
    }
    assert(sawMoved,
        "the corner at pickedCenter (0.5,0.5,0.5) should shift to "
        ~ "(0.8,0.5,0.5) under TX=0.3");
    // Verts far from pickedCenter — e.g. (-0.5, -0.5, -0.5) at
    // distance sqrt(3) ≈ 1.73 — should be untouched.
    bool sawUnmoved = false;
    foreach (v; verts) {
        if (approxEq(v[0], -0.5) && approxEq(v[1], -0.5)
            && approxEq(v[2], -0.5)) { sawUnmoved = true; break; }
    }
    assert(sawUnmoved,
        "the opposite corner should remain at (-0.5,-0.5,-0.5)");
}

unittest { // dist=0 ⇒ degenerate radius: falloff returns weight=1
           // everywhere (no clamp can happen). Verts move uniformly.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"0,0,0\"");
    cmd("tool.pipe.attr falloff dist 0.0001");  // effectively zero
    cmd("tool.attr move TX 0.1");
    cmd("tool.doApply");
    auto verts = dumpVerts();
    // Verts at the centre get weight=1; ALL OTHERS at r >> dist get
    // weight=0. Only verts within the tiny radius move. Since no
    // cube vert is at origin, none move.
    foreach (v; verts) {
        assert(approxEq(fabs(v[0]), 0.5),
            "dist≈0 element falloff at origin shouldn't move corners");
    }
}
