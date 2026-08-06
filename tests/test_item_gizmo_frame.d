// Task 0614, Phase 2 — the item-mode ACEN centre + AXIS basis.
//
// When the current selection type is Item, the gizmo must land on the
// item's WORLD PIVOT (`pos + pivot`, measured L1 — capture-verified,
// doc/tasks/0614-evidence/phase0_findings.md case A) with WORLD-ALIGNED
// handles (measured L3, case A' — an item rotated 45 degrees about Y still
// reports the exact world identity basis, NOT its own rotated frame). The
// second half is the load-bearing one: the plan's original design assumed
// the axis stage should redirect to the item's own basis by default, and
// the capture overturned that. `AxisStage.Mode.None` already returned world
// XYZ before this task touched anything — this file exists so a future
// change cannot silently reintroduce the redirect and have it go unnoticed.
//
// A Vertex-current selection type must NOT engage either redirect — that is
// the R4 default-safety property (SubjectPacket.selType defaults to
// Vertex), checked here end to end over the live HTTP surface rather than
// only in the toolpipe.packets unittest.

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

void ok(char[] resp, string what) {
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           what ~ " failed: " ~ cast(string)resp);
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

struct Frame { Vec3 right, up, fwd, center; }

Frame readPipe() {
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    Vec3 rd(string slot) {
        auto v = ev["axis"][slot].array;
        return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                    cast(float)v[2].floating);
    }
    auto c = ev["actionCenter"]["center"].array;
    return Frame(rd("right"), rd("up"), rd("fwd"),
                 Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                      cast(float)c[2].floating));
}

string show(Vec3 v) { return format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z); }

bool vecEq(Vec3 a, Vec3 b, double tol = 1e-4) {
    return fabs(a.x - b.x) < tol && fabs(a.y - b.y) < tol && fabs(a.z - b.z) < tol;
}

double distTo(Vec3 a, Vec3 b) {
    double dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

Vec3[] dumpVerts() {
    auto verts = parseJSON(cast(string)get(BASE ~ "/api/model"))["vertices"].array;
    Vec3[] out_;
    out_.length = verts.length;
    foreach (i, v; verts) {
        auto a = v.array;
        out_[i] = Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    return out_;
}

// -----------------------------------------------------------------------
// 1. The default item redirect: gizmo centre = pos + pivot, world axes.
// -----------------------------------------------------------------------

unittest { // Item current, unrotated item: centre = pos+pivot, axes = world.
    resetCube();
    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 0 pivot.x 0.5");
    cmd("layer.select index:0");   // promotes SelType.Item to current

    auto sel = parseJSON(cast(string)get(BASE ~ "/api/selection"));
    assert(sel["selType"].str == "item",
        "layer.select must promote item to current, got " ~ sel["selType"].str);

    auto f = readPipe();
    assert(vecEq(f.center, Vec3(1.5f, 0, 0)),
        "item-mode centre must be pos+pivot = (1.5,0,0), got " ~ show(f.center));
    assert(vecEq(f.right, Vec3(1, 0, 0)) && vecEq(f.up, Vec3(0, 1, 0))
           && vecEq(f.fwd, Vec3(0, 0, 1)),
        "item-mode default axis basis must be world identity, got right="
        ~ show(f.right) ~ " up=" ~ show(f.up) ~ " fwd=" ~ show(f.fwd));
}

// -----------------------------------------------------------------------
// 2. The load-bearing case: a ROTATED item still gets world-aligned handles
//    and a rotation-invariant centre (L1 + L3 together, case A').
// -----------------------------------------------------------------------

unittest { // Item current, item rotated 45 about Y: centre unchanged, axes still world.
    resetCube();
    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 0 pivot.x 0.5");
    cmd("layer.attr 0 rot.y 45.0");
    cmd("layer.select index:0");

    auto f = readPipe();
    assert(vecEq(f.center, Vec3(1.5f, 0, 0)),
        "the item's world pivot is rotation-invariant (document.d:68 — the "
        ~ "local pivot is a fixed point of T(pivot)*R*S*T(-pivot)); got "
        ~ show(f.center));
    assert(vecEq(f.right, Vec3(1, 0, 0)) && vecEq(f.up, Vec3(0, 1, 0))
           && vecEq(f.fwd, Vec3(0, 0, 1)),
        "a rotated item must STILL report the world-identity basis by "
        ~ "default (measured L3, phase0_findings.md case A') — a "
        ~ "right != (1,0,0) here would mean the overturned item-basis "
        ~ "redirect crept back in. Got right=" ~ show(f.right));
}

unittest { // Mode.Pivot stays the explicit route to the item's own basis.
    resetCube();
    cmd("layer.attr 0 rot.y 45.0");
    cmd("layer.select index:0");
    cmd("tool.pipe.attr axis mode pivot");

    auto f = readPipe();
    assert(!vecEq(f.right, Vec3(1, 0, 0)),
        "explicit axis.pivot must still reflect the item's own rotated "
        ~ "basis — L3 removed only the DEFAULT redirect, not this mode. "
        ~ "Got right=" ~ show(f.right));
}

// -----------------------------------------------------------------------
// 3. A Vertex-current selection must NOT engage either redirect (R4).
// -----------------------------------------------------------------------

unittest { // fresh reset: default selType is Vertex, item redirect must be inert.
    resetCube();
    // NIT (0614 review): displace the cube's geometry OFF the origin first —
    // mirrors the in-module actcenter.d unittest's `v + Vec3(3,0,0)`.
    // Without this, the geometry-fallback centre and a hypothetical
    // fixed-origin default both read (0,0,0), so this test could not tell
    // "the redirect stayed inert" from "the redirect fired but happened to
    // land on the same point". Nothing is selected, so the whole-mesh
    // fallback (mesh.selectedVertexIndicesVertices' documented "nothing
    // selected -> all") moves every vertex.
    cmd("tool.set move on");
    cmd("tool.attr move TX 3");
    cmd("tool.doApply");
    cmd("tool.set move off");

    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 0 pivot.x 0.5");
    // No layer.select — selType stays at its boot default (Vertex).
    auto sel = parseJSON(cast(string)get(BASE ~ "/api/selection"));
    assert(sel["selType"].str == "vertex",
        "sanity: boot default selType must be vertex, got " ~ sel["selType"].str);

    auto f = readPipe();
    // The cube's geometry centroid is now (3,0,0) in LOCAL coordinates (the
    // item transform never touches mesh.vertices) — discriminates from BOTH
    // the world origin (0,0,0) and the item's world pivot (1.5,0,0).
    assert(vecEq(f.center, Vec3(3, 0, 0)),
        "Vertex-current selection must read the geometry fallback, NOT the "
        ~ "item pivot — got " ~ show(f.center) ~ " (item pivot would be "
        ~ "(1.5,0,0), world origin would be (0,0,0))");
}

// -----------------------------------------------------------------------
// 4. `/api/tool/state`'s live `pivot`, with an actual transform tool armed
//    (xfrm_transform.d:5705) — the end-to-end path a real Move session uses.
// -----------------------------------------------------------------------

unittest { // tool.set move + item-current: /api/tool/state pivot == pos+pivot.
    resetCube();
    cmd("layer.attr 0 pos.x 2.0");
    cmd("layer.attr 0 pivot.z -1.0");
    cmd("layer.select index:0");
    ok(post(BASE ~ "/api/script", "tool.set move"), "tool.set move");

    auto st = parseJSON(cast(string)get(BASE ~ "/api/tool/state"));
    auto p = st["pivot"].array;
    Vec3 pivot = Vec3(cast(float)p[0].floating, cast(float)p[1].floating,
                       cast(float)p[2].floating);
    assert(vecEq(pivot, Vec3(2.0f, 0, -1.0f)),
        "/api/tool/state pivot must equal pos+pivot = (2,0,-1), got "
        ~ show(pivot));
}

// -----------------------------------------------------------------------
// 5. Blocker 1 (0614 review): the GIZMO pivot and the APPLIED pivot must
//    be the SAME point. Before this diff's fix, `buildLocalVts` (the
//    apply path — transform.d, reached by every applyHeadless / panel-
//    replay call site: xfrm_transform.d's applyTRS/recaptureLivePipePackets
//    /applyHeadless/captureBaselinePacketsNoSession, and scale.d's /
//    rotate.d's own applyHeadless + property-panel replay) left
//    `SubjectPacket.selType` at its Vertex default, while app.d's
//    `buildToolVts` (the RENDER path — what test 4 above reads) correctly
//    read the live selection type. So the gizmo was drawn at the item's
//    world pivot while a drag/apply rotated the geometry about the
//    geometry centroid instead — two different points for the SAME
//    gesture. Item-select does not drop the active tool (app.d's
//    switchToItemType), so a tool armed BEFORE the item-select stays armed
//    through it — this reproduces that exact ordering.
// -----------------------------------------------------------------------

unittest { // tool.set rotate armed, THEN item-select: gizmo pivot == applied pivot.
    resetCube();
    cmd("layer.attr 0 pos.x 2.0");
    cmd("layer.attr 0 pivot.x 1.0");
    ok(post(BASE ~ "/api/script", "tool.set rotate on"), "tool.set rotate on");
    cmd("layer.select index:0");   // item current; the armed tool is NOT dropped

    immutable Vec3 itemPivot    = Vec3(3.0f, 0, 0);   // pos.x + pivot.x
    immutable Vec3 geomCentroid = Vec3(0, 0, 0);       // untouched default cube

    // The gizmo's reported pivot — the RENDER path (app.d's buildToolVts).
    auto f = readPipe();
    assert(vecEq(f.center, itemPivot),
        "sanity: gizmo pivot must read the item's world pivot, got "
        ~ show(f.center));
    // The rig must actually discriminate the two candidate pivots, or a
    // wrong apply-path pivot could coincidentally agree with the right one.
    assert(!vecEq(itemPivot, geomCentroid),
        "test rig must discriminate the two candidate pivots");

    auto pre = dumpVerts();

    cmd("tool.attr rotate RY 90");
    cmd("tool.doApply");

    auto post_ = dumpVerts();
    assert(pre.length == post_.length, "vertex count must not change");

    // The APPLIED pivot must be the gizmo's OWN reported pivot, not the
    // geometry centroid — checked via the rigid-rotation invariant
    // "distance to the TRUE pivot is preserved under a rotation about it",
    // which needs no assumption about the exact matrix/sign convention RY
    // uses (any pure rotation about P preserves |X - P|).
    double errAtItemPivot = 0, errAtGeomCentroid = 0;
    foreach (i; 0 .. pre.length) {
        double dPre  = distTo(pre[i],  itemPivot);
        double dPost = distTo(post_[i], itemPivot);
        errAtItemPivot += (dPre - dPost) * (dPre - dPost);

        double gPre  = distTo(pre[i],  geomCentroid);
        double gPost = distTo(post_[i], geomCentroid);
        errAtGeomCentroid += (gPre - gPost) * (gPre - gPost);
    }
    assert(errAtItemPivot < 1e-6,
        "the applied rotation must preserve distance-to-item-pivot (i.e. it "
        ~ "must actually rotate about the gizmo's own reported pivot, not "
        ~ "the geometry centroid) — sum of squared radius drift = "
        ~ errAtItemPivot.to!string);
    assert(errAtGeomCentroid > 1e-3,
        "sanity: the geometry centroid must NOT be distance-preserving here "
        ~ "— proves the two candidate pivots are numerically distinguishable "
        ~ "(otherwise a passing errAtItemPivot check alone could be "
        ~ "coincidence) — sum of squared radius drift = "
        ~ errAtGeomCentroid.to!string);

    ok(post(BASE ~ "/api/script", "tool.set rotate off"), "tool.set rotate off");
}
