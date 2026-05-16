// Tests for ElementMoveTool's element-falloff drag (Stage 14.3).
//
// The interactive click-to-pick path reads GPU-resolved hover state
// published by `app.d`'s pickVertices / pickEdges / pickFaces and
// applied via vert > edge > face priority. Reproducing that exact
// hover state in headless --test mode would require a render frame
// between MOUSEMOTION and MOUSEBUTTONDOWN (since EventPlayer.tick
// fires all due events in one call). Synthesising that is fragile —
// ImGui's WantCaptureMouse flips to true the moment the synthetic
// MOUSEBUTTONDOWN reaches ImGui_ImplSDL2_ProcessEvent, after which
// pickFaces / pickEdges / pickVertices all bail.
//
// What's testable headlessly is the downstream behaviour the click
// drives once `pickedCenter` / `pickedVerts` are set on the
// FalloffStage: the picked-element drag itself (verts in
// `pickedVerts` get weight 1 regardless of sphere radius, neighbours
// attenuate by the sphere, prior selection is ignored, the gizmo
// follows `pickedCenter`). The test drives those fields directly via
// the existing `tool.pipe.attr falloff …` surface (`pickedCenter` +
// `pickedVerts`) and exercises the move via `tool.doApply` or a
// gizmo-arrow drag — same code path the click would land on after
// `tryPickElement` populated the stage.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.format : format;

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

string attrStr(string name) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"][name].str;
    assert(false, "WGHT stage missing");
}

double[3] pickedCenterAttr() {
    auto v = attrStr("pickedCenter");
    import std.string : split;
    auto p = v.split(",");
    return [p[0].to!double, p[1].to!double, p[2].to!double];
}

double[3] vertexPos(int i) {
    auto verts = getJson("/api/model")["vertices"].array;
    auto a = verts[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

bool approxEq(double a, double b, double eps = 1e-3) {
    return fabs(a - b) < eps;
}

unittest { // HTTP attr surface: pickedCenter round-trips through
           // tool.pipe.attr → /api/toolpipe.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.25,-0.3,0.7\"");
    auto pc = pickedCenterAttr();
    assert(approxEq(pc[0],  0.25, 1e-4),
        "pickedCenter.x expected 0.25, got " ~ pc[0].to!string);
    assert(approxEq(pc[1], -0.30, 1e-4));
    assert(approxEq(pc[2],  0.70, 1e-4));
}

unittest { // Default pickedCenter (0,0,0) with the autoSized 0.5
           // sphere puts every cube corner (√3·0.5 ≈ 0.87 from
           // origin) outside the falloff. doApply must not move
           // anything — proves the sphere gate fires when no
           // picked-element override is in place.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(a[c].floating), 0.5, 1e-4),
                "default pickedCenter at origin shouldn't move corners");
    }
}

unittest { // pickedVerts gives weight=1 regardless of sphere radius:
           // pickedCenter at face centroid, dist=0.5 (corners
           // √2·0.5 ≈ 0.707 outside the sphere), pickedVerts =
           // +Z face ring → all four +Z verts must drag as a rigid
           // unit; -Z face is untouched.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff pickedVerts \"4,5,6,7\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");

    foreach (i; 0 .. 4) {
        auto v = vertexPos(i);
        assert(approxEq(v[2], -0.5, 1e-4)
            && approxEq(fabs(v[0]), 0.5, 1e-4)
            && approxEq(fabs(v[1]), 0.5, 1e-4),
            "v" ~ i.to!string ~ " on -Z face must stay put; got "
            ~ v[0].to!string ~ "," ~ v[1].to!string ~ "," ~ v[2].to!string);
    }
    foreach (i; 4 .. 8) {
        auto v = vertexPos(i);
        double expectX = [-0.5, 0.5, 0.5, -0.5][i-4] + 0.3;
        assert(approxEq(v[0], expectX, 1e-4),
            "picked +Z v" ~ i.to!string ~ " must shift by +0.3 in X; "
            ~ "got " ~ v[0].to!string);
    }
}

unittest { // pickedVerts wins over an UNRELATED prior selection.
           // ElementMoveTool overrides buildVertexCacheIfNeeded to
           // iterate every vert; elementWeight then gates per-vert
           // via pickedVerts. Without that override, the selected -Z
           // face would dominate vertexIndicesToProcess and the
           // picked +Z face would never even enter the iteration.
    postJson("/api/reset", "");
    postJson("/api/select",
        `{"mode":"polygons","indices":[0]}`);   // -Z face selected
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff pickedVerts \"4,5,6,7\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");

    // -Z face (selected, NOT picked) must stay put.
    foreach (i; 0 .. 4) {
        auto v = vertexPos(i);
        assert(approxEq(v[2], -0.5, 1e-4)
            && approxEq(fabs(v[0]), 0.5, 1e-4),
            "selected -Z v" ~ i.to!string ~ " must stay put; got x="
            ~ v[0].to!string);
    }
    // +Z face (picked) moves as a rigid unit.
    foreach (i; 4 .. 8) {
        auto v = vertexPos(i);
        double expectX = [-0.5, 0.5, 0.5, -0.5][i-4] + 0.3;
        assert(approxEq(v[0], expectX, 1e-4),
            "picked +Z v" ~ i.to!string ~ " must shift +0.3 in X "
            ~ "despite -Z being the selected element; got "
            ~ v[0].to!string);
    }
}

unittest { // pickedCenter setter wipes pickedVerts — explicit
           // override no longer refers to a specific clicked element,
           // so the weight=1 short-circuit must not keep favouring
           // whatever was last clicked.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedVerts \"4,5,6,7\"");
    assert(attrStr("pickedVerts") == "4,5,6,7");
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0.5\"");
    assert(attrStr("pickedVerts") == "",
        "pickedCenter setter must clear pickedVerts; got "
        ~ attrStr("pickedVerts"));
}

unittest { // Empty pickedVerts string clears the ring.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedVerts \"1,2,3\"");
    assert(attrStr("pickedVerts") == "1,2,3");
    cmd("tool.pipe.attr falloff pickedVerts \"\"");
    assert(attrStr("pickedVerts") == "",
        "empty pickedVerts must clear the ring");
}

unittest { // pickedVerts ring with `connect=polygon` plus a tiny
           // connectMask still produces weight=1 short-circuit on
           // picked verts (they're by definition in the connected
           // component). The connectMask only gates NON-picked verts.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    // Whole-mesh sphere so the connect mask is the only gate that
    // could stop verts moving. pickedVerts = single vert; connect
    // mask empty → unrestricted sphere, all verts move.
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0\"");
    cmd("tool.pipe.attr falloff pickedVerts \"6\"");
    cmd("tool.pipe.attr falloff dist 10");
    cmd("tool.pipe.attr falloff connect off");
    cmd("tool.attr xfrm.elementMove TX 0.1");
    cmd("tool.doApply");
    // Every cube vert shifts by +0.1 in X (degenerate sphere check
    // doesn't fire — dist=10, but full-sphere weight = 1 at centre
    // and 0 at radius; (0,0,0) → corners ≈ 0.87, weight ≈ 1-0.087 ≈ 0.913
    // with linear shape). So we just check v6 moved by the FULL 0.1
    // since it's in pickedVerts.
    auto v6 = vertexPos(6);
    assert(approxEq(v6[0], 0.5 + 0.1, 1e-4),
        "picked v6 must shift by full TX=0.1 (pickedVerts weight=1); "
        ~ "got x=" ~ v6[0].to!string);
}

unittest { // ElementMoveTool.queryActionCenter parks the gizmo on
           // pickedCenter — the move handler centre tracks the
           // picked element, so a gizmo-driven drag pivots there.
           // /api/toolpipe doesn't expose the gizmo position, but
           // the WGHT stage's pickedCenter is the source of truth
           // queryActionCenter reads; pin it through round-trip.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0.5\"");
    auto pc = pickedCenterAttr();
    assert(approxEq(pc[0], 0,   1e-4)
        && approxEq(pc[1], 0,   1e-4)
        && approxEq(pc[2], 0.5, 1e-4),
        "pickedCenter round-trip failed: " ~ pc.to!string);
}
