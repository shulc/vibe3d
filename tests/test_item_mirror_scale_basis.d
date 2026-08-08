// Task 0614 Phase 5 — R12: what a NEGATIVE item scale does to the gizmo basis.
//
// `axis.d`'s Mode.Pivot normalises the three columns of the item's
// `composedMatrix()`. A negative `scl` component therefore flips the
// corresponding column, and a single negative makes the triple LEFT-handed
// (det = -1). The risk row asked whether a later gesture then decomposes along
// a mirrored axis.
//
// L3 DOWNGRADED this, and the downgrade is the first thing tested here: the
// measured DEFAULT basis is world (capture-verified, phase0_findings.md case
// A'), and world reads no layer state at all, so a mirrored item cannot flip
// the default frame. The flip survives only under an explicitly item-anchored
// axis mode.
//
// THE TRAP THIS FILE WAS WRITTEN TO AVOID, quoted from the plan's R12 row:
// "`test_item_mirror_scale_basis.d` as originally specified would now run
// against the world default, pass vacuously, and pin nothing — it must set the
// item-anchored axis mode explicitly." So every case below that means to be
// item-anchored ASSERTS THE PRECONDITION FIRST: if the published basis is not
// actually mirrored at the point the case starts, the case fails there rather
// than sailing on to prove something about the world default.
//
// HOW THE MODE IS SET, and why it matters. The item-anchored mode is engaged
// through `actr.pivot` — the combined preset command, which goes through
// `AxisStage.setUserMode` and sets `userLocked` (commands/actr.d) — and NOT
// through the granular `tool.pipe.attr axis mode pivot`, which reaches
// `setAttr` and leaves `userLocked` false. That difference is load-bearing
// here, and the reason is a chain, not a staleness:
//
//   `layer.attr` is a Model-class command, so app.d's dispatcher used to drop
//   the armed tool for it → `setActiveTool(null)` calls
//   `resetTransientPipeStages()` → `AxisStage.resetTransient()` early-returns
//   ONLY when `userLocked` (toolpipe/stages/axis.d) → so the granular mode was
//   wiped back to the world default while the `actr.pivot` one survived.
//
// The historically measured difference, mode set FIRST and the mirror authored
// afterwards (the ordering case (b) below uses):
//
//     actr.pivot           then `layer.attr 0 scl.x -1`  ⇒ right = (-1, 0, 0)
//     tool.pipe.attr …     then `layer.attr 0 scl.x -1`  ⇒ right = ( 1, 0, 0)
//
// (A first reading of that pair called it "a staleness in what the granular
// path publishes". It was not: the granular mode was gone, not stale.)
//
// The Phase 5 review's B1 fix excludes `layer.attr` from that tool drop — a
// panel write CONTINUES the transform session — so with B1 in place the axis
// stage is no longer reset and the two forms agree again. Do NOT read the
// table above as a live property; it records why this file was written the way
// it is. The `actr.pivot` choice STAYS regardless: it is the form that survives
// every other tool drop too (tool.set, a tool switch, `scene.*`), so a future
// case that adds one of those in front of the mirror still reads a mirrored
// basis instead of quietly falling back to the world default and pinning
// nothing — which is exactly the vacuous-test failure mode R12 warns about.

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void script(string s) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/script", s));
    assert(j["status"].str == "ok", "script `" ~ s ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }
string show(Vec3 v) { return format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z); }

struct Basis { Vec3 right, up, fwd; }

Basis publishedBasis() {
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    Vec3 rd(string slot) {
        auto v = ev["axis"][slot].array;
        return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                    cast(float)v[2].floating);
    }
    return Basis(rd("right"), rd("up"), rd("fwd"));
}

Vec3 publishedCentre() {
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    auto c = ev["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

double[3] layerScl() {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    auto a = j["layers"].array[0]["xform"]["scl"].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

double layerPosX() {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    return j["layers"].array[0]["xform"]["pos"].array[0].floating;
}

// The rig: displaced off every axis so the item's world pivot (1.20, -0.50,
// 0.80) coincides with nothing — not the world origin, not the mesh centroid,
// not any single channel. Rotation is deliberately left at IDENTITY: this file
// is about what the SIGN of a scale does to the basis, and a rotation would
// mix all three columns and make the flip unreadable.
enum double PIV_X =  1.20;
enum double PIV_Y = -0.50;
enum double PIV_Z =  0.80;

void buildRig() {
    resetCube();
    cmd("layer.attr 0 pos.x 0.95");
    cmd("layer.attr 0 pos.y -0.1");
    cmd("layer.attr 0 pos.z 0.5");
    cmd("layer.attr 0 pivot.x 0.25");
    cmd("layer.attr 0 pivot.y -0.4");
    cmd("layer.attr 0 pivot.z 0.3");
    cmd("layer.select index:0");
}

// Grab pixel for the arrow that runs from the pivot along `dir` — the same
// 1/5-to-1-times-gizmo-size shaft `drag_helpers.axisGrabPx` assumes, but for an
// arbitrary direction, because a mirrored basis draws the X arrow along world
// -X and a +X-only helper would grab empty space.
void grabAlong(Vec3 pivot, Vec3 dir, ref Viewport vp,
               out int gx, out int gy, out double ux, out double uy)
{
    float size = gizmoSize(pivot, vp);
    Vec3 a = Vec3(pivot.x + dir.x * size / 5.0f,
                  pivot.y + dir.y * size / 5.0f,
                  pivot.z + dir.z * size / 5.0f);
    Vec3 b = Vec3(pivot.x + dir.x * size,
                  pivot.y + dir.y * size,
                  pivot.z + dir.z * size);
    float sx1, sy1, sx2, sy2;
    projectToWindow(a, vp, sx1, sy1);
    projectToWindow(b, vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// Grab the first-axis arrow (wherever the published basis puts it) and drag
// `px` pixels ALONG its own screen direction. Returns the resulting change in
// pos.x.
double dragAlongFirstAxis(double px = 70.0) {
    auto b = publishedBasis();
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = publishedCentre();
    int gx, gy; double ux, uy;
    grabAlong(pivot, b.right, vp, gx, gy, ux, uy);
    double pre = layerPosX();
    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            gx, gy,
                            gx + cast(int)(px * ux), gy + cast(int)(px * uy));
    playAndWait(log);
    return layerPosX() - pre;
}

// -----------------------------------------------------------------------
// (a) THE DOWNGRADE ITSELF. At the DEFAULT axis mode a mirrored item must
//     still publish the world identity — this is what makes "L3 makes the
//     flip unreachable by default" a tested claim instead of a remark.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    cmd("layer.attr 0 scl.x -1");
    script("tool.set move");

    assert(approx(layerScl()[0], -1.0),
        "precondition: the mirror actually landed (the R7 floor must not have "
        ~ "eaten it — |-1| is far outside the degenerate band). Got "
        ~ layerScl()[0].to!string);

    auto b = publishedBasis();
    assert(approx(b.right.x, 1) && approx(b.right.y, 0) && approx(b.right.z, 0),
        "at the DEFAULT axis mode a mirrored item must still publish the WORLD "
        ~ "identity — the default reads no layer state at all (L3, "
        ~ "phase0_findings.md case A'), so scl.x = -1 cannot reach it. A "
        ~ "right of (-1,0,0) here means the item-basis redirect L3 overturned "
        ~ "has crept back in. Got right=" ~ show(b.right));
    assert(approx(b.up.y, 1) && approx(b.fwd.z, 1),
        "…and the other two columns likewise, got up=" ~ show(b.up)
        ~ " fwd=" ~ show(b.fwd));

    script("tool.set move off");
}

// -----------------------------------------------------------------------
// (b) THE FLIP, now reachable only explicitly. Under `actr.pivot` the basis
//     is the item's own, so one negative scale flips its first column and
//     makes the triple left-handed.
//
//     ORDERING IS DELIBERATE: the mode is engaged FIRST and the mirror is
//     authored afterwards — the panel→gizmo direction, and the ordering that
//     actually discriminates the locked preset from the granular attr write
//     (see the header). Authoring the mirror first, as the other cases do,
//     passes either way and would leave that choice untested.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    script("tool.set move");
    script("actr.pivot");
    cmd("layer.attr 0 scl.x -1");

    auto b = publishedBasis();
    assert(approx(b.right.x, -1) && approx(b.right.y, 0) && approx(b.right.z, 0),
        "PRECONDITION — under actr.pivot the first basis column must actually "
        ~ "BE mirrored before anything below means anything. right="
        ~ show(b.right) ~ ". A right of (1,0,0) means the item-anchored basis "
        ~ "did not reach the published packet — the case is then running at "
        ~ "the world default and pins nothing, which is exactly the vacuous "
        ~ "test R12 warns about. If this fires after a change to how the mode "
        ~ "is set, read this file's header: the granular "
        ~ "`tool.pipe.attr axis mode pivot` does NOT publish a mirror authored "
        ~ "after it, and `actr.pivot` does.");
    assert(approx(b.up.y, 1) && approx(b.fwd.z, 1),
        "only the mirrored column flips, got up=" ~ show(b.up)
        ~ " fwd=" ~ show(b.fwd));

    // The centre is unaffected — a mirror is about orientation, and ACEN's
    // item value is pos+pivot whatever the scale is.
    auto c = publishedCentre();
    assert(approx(c.x, PIV_X) && approx(c.y, PIV_Y) && approx(c.z, PIV_Z),
        "a mirror must not move the action centre, got " ~ show(c));

    script("tool.set move off");
}

// -----------------------------------------------------------------------
// (c) TWO negatives. Handedness is restored (det = +1) — but each mirrored
//     column stays mirrored. The plan's sketch for this case said it "must
//     behave as unmirrored"; that is true of the HANDEDNESS and false of the
//     AXES, and the difference is the whole point of pinning it.
// -----------------------------------------------------------------------

unittest {
    buildRig();
    cmd("layer.attr 0 scl.x -1");
    cmd("layer.attr 0 scl.y -1");
    script("tool.set move");
    script("actr.pivot");

    auto b = publishedBasis();
    assert(approx(b.right.x, -1) && approx(b.up.y, -1) && approx(b.fwd.z, 1),
        "TWO negative scales flip TWO columns — restoring the HANDEDNESS "
        ~ "(det = +1) without un-flipping either axis. right=" ~ show(b.right)
        ~ " up=" ~ show(b.up) ~ " fwd=" ~ show(b.fwd));

    // det of (right, up, fwd) as columns — the handedness claim, computed
    // rather than asserted by eye.
    double det =
          b.right.x * (b.up.y * b.fwd.z - b.up.z * b.fwd.y)
        - b.up.x    * (b.right.y * b.fwd.z - b.right.z * b.fwd.y)
        + b.fwd.x   * (b.right.y * b.up.z  - b.right.z * b.up.y);
    assert(det > 0,
        "with two mirrors the frame is RIGHT-handed again, det=" ~ det.to!string);

    script("tool.set move off");
}

// -----------------------------------------------------------------------
// (b') The consequence, which is what R12 was actually worried about: with
//      the basis mirrored, a drag along the first-axis arrow moves the item
//      the OTHER way in world X than the same gesture does unmirrored.
//      Written as a DIFFERENTIAL — the two runs share one gesture recipe and
//      differ only in the sign of scl.x — so "nothing moved" fails it and no
//      absolute pixel-to-world constant is baked in.
// -----------------------------------------------------------------------

unittest {
    // Control: unmirrored, item-anchored axis.
    buildRig();
    script("tool.set move");
    script("actr.pivot");
    auto ctrlBasis = publishedBasis();
    assert(approx(ctrlBasis.right.x, 1),
        "control precondition: unmirrored item ⇒ first column is +X, got "
        ~ show(ctrlBasis.right));
    double dCtrl = dragAlongFirstAxis();
    script("tool.set move off");

    // Mirrored: same rig, same gesture recipe, scl.x negated.
    buildRig();
    cmd("layer.attr 0 scl.x -1");
    script("tool.set move");
    script("actr.pivot");
    auto mirBasis = publishedBasis();
    assert(approx(mirBasis.right.x, -1),
        "mirror precondition: the axis mode must have taken, got "
        ~ show(mirBasis.right));
    double dMir = dragAlongFirstAxis();
    script("tool.set move off");

    assert(fabs(dCtrl) > 1e-3,
        "the control drag must actually move the item — a differential "
        ~ "between two zeroes proves nothing. delta=" ~ dCtrl.to!string);
    assert(fabs(dMir) > 1e-3,
        "and so must the mirrored drag. delta=" ~ dMir.to!string);
    assert(dCtrl * dMir < 0,
        "dragging ALONG the first-axis arrow moves the item in OPPOSITE world-X "
        ~ "directions when that arrow is mirrored — that is the negative-scale "
        ~ "basis flip made observable, and it is a DECIDED behaviour, not an "
        ~ "accident (axis.d normalises the composed matrix's columns; a "
        ~ "negative scl negates one). control=" ~ dCtrl.to!string
        ~ " mirrored=" ~ dMir.to!string);
}
