// ===========================================================================
// Task 1903 L0.P1 — witness W4a: the CONTROL direction, at the pixel tier.
//
// The carve-out's whole risk is an OVER-BROAD predicate: a log that really does
// move an index space taking the fast path, where `edges`, the loops family and
// `edgeIndexMap` are all left describing the previous topology. This file
// drives that direction with an instrument that can see it.
//
// ===========================================================================
// THE PLAN'S OWN W4a WAS INERT, AND THIS FILE IS THE CORRECTED CELL
// ===========================================================================
// §P1.4 specified W4a as: live subpatch preview + `mesh.delete` + undo + the
// probe on a FACE pixel, on the reasoning that a fast-path topology undo would
// leave the preview holding a stale layout key. MEASURED 2026-08-27: that cell
// is GREEN under its own mutation (`fast = true` for every log, with the
// always-on backstops silenced so the process survives to render). The reason
// is structural, not luck — `mesh.delete`'s delta declares
// `scope_ == Polygons`, `Polygons` IS a Geometry class, so
// `commitRestored(scope_)` bumps `topologyVersion` on the fast path too, the
// preview's index-space key moves, and the limit surface is rebuilt and drawn
// correctly. The face pixel cannot see the damage because `faces` and
// `vertices` ARE restored correctly by the patchers; what is stale is `edges`.
//
// So the cell is re-aimed at where the damage actually is: the WIREFRAME. The
// edge pass draws GL_LINES straight out of `mesh.edges`, and after a fast-path
// delete-undo that array still holds the POST-delete edge pairs — indices into
// a vertex space the revert has since re-expanded — so the lines are drawn
// between the wrong vertices.
//
// AND IT MUST BE PIXELS, not a count. `/api/model`'s `edges` array and
// `test_frame_counts`' `2 x edgeCount` submission check both read the SAME
// stale array, so both agree with each other under the bug and stay green:
// that is CLAUDE.md's "the assertion holds on the failure as well", and it is
// why a frame-count cell would be worthless here.
//
// WHAT IS STILL DEBT. The mirror-image cell — a fast-path POSITION undo with
// pixels UNCHANGED — cannot be written yet (plan W4b): at landing no
// production delta log is index-space stable, so the suite lane has no way to
// reach the fast branch at all. Recorded as debt owed by L0-d rather than
// faked green; the CLASS tier of the fast path is pinned meanwhile by
// `tests/unit/mesh_edit_delta_carveout_delivery_test.d`.
//
// NOT A CUBE: the patch is an OPEN 4x4 grid, so the deleted half leaves a real
// hole with background behind it.
// ===========================================================================
import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : fabs, abs;
import std.stdio   : writefln;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      DHVec3 = Vec3;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

/// A state change is visible only once a frame has RENDERED with it, and a
/// probe reads the last COMPLETED frame — so this has to cover two.
void settle() { Thread.sleep(450.msecs); }

struct Px {
    int r, g, b, a;
    string toString() const { return format("(%d,%d,%d,a=%d)", r, g, b, a); }
}

/// A horizontal RUN of pixels, in ONE probe call.
///
/// Sampling a single pixel on a wireframe line does not work at this scale: a
/// GL_LINES edge is one pixel wide and half a pixel of projection rounding
/// misses it. MEASURED on this rig — only 2 of 8 single-pixel samples aimed at
/// grid lines actually landed on one. A run of 9 pixels crossing the line
/// CONTAINS it wherever the rounding puts it, and comparing the run as a whole
/// is a strictly stronger claim than comparing one pixel: it says the line is
/// in the same place, not merely that some pixel is unchanged.
Px[] probeRun(int x0, int y, int n) {
    string pts;
    foreach (i; 0 .. n) {
        if (i) pts ~= ";";
        pts ~= format("%d,%d", x0 + i, y);
    }
    auto j = getJson("/api/viewport/probe?cell=0&points=" ~ pts);
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_,
        "the probed cell is not rendered under --test; every reading in this "
      ~ "file would be void");
    Px[] out_;
    foreach (e; j["points"].array) {
        assert("error" !in e, "a pixel of the run could not be read: " ~ e.toString);
        out_ ~= Px(cast(int)e["r"].integer, cast(int)e["g"].integer,
                   cast(int)e["b"].integer, cast(int)e["a"].integer);
    }
    return out_;
}

string runSig(Px[] run) {
    string s;
    foreach (p; run) s ~= p.toString;
    return s;
}

Px probe1(int x, int y) {
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", x, y));
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_,
        "the probed cell is not rendered under --test; every reading in this "
      ~ "file would be void");
    auto e = j["points"].array[0];
    assert("error" !in e, format("pixel (%d,%d) could not be read: %s",
                                 x, y, e.toString));
    return Px(cast(int)e["r"].integer, cast(int)e["g"].integer,
              cast(int)e["b"].integer, cast(int)e["a"].integer);
}

int rgbDist(Px a, Px b) {
    return cast(int)(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b));
}

// The same two constants `test_bus_position_pixel.d` measured on this rig,
// where a lit patch reads (105,105,105) against a background of (92,102,107) —
// a separation of 18 — and every "same" pair reads exactly 0 because the
// rendering is deterministic. Fixed numbers with a 2x margin on the smaller
// side, never derived from the reading they judge. The PREMISE asserts below
// are what redden loudly if a theme change ever brings the two closer,
// instead of quietly making the cells undecidable.
enum int kDiffer = 9;
enum int kMatch  = 4;

void loadOpenPatch() {
    enum int N = 4;
    string verts = "[";
    foreach (j; 0 .. N + 1)
        foreach (i; 0 .. N + 1) {
            if (i || j) verts ~= ",";
            verts ~= format("[%.6f,%.6f,0.0]",
                            -1.0 + 2.0 * i / N, -1.0 + 2.0 * j / N);
        }
    verts ~= "]";
    string faces = "[";
    foreach (j; 0 .. N)
        foreach (i; 0 .. N) {
            if (i || j) faces ~= ",";
            const int a = j * (N + 1) + i;
            faces ~= format("[%d,%d,%d,%d]", a, a + 1, a + N + 2, a + N + 1);
        }
    faces ~= "]";
    auto j = postJson("/api/load-mesh",
                      format(`{"vertices":%s,"faces":%s}`, verts, faces));
    assert(j["status"].str == "ok", "load-mesh failed: " ~ j.toString);
}

/// World point -> CELL-LOCAL pixel through the LIVE camera. `projectToWindow`
/// answers in WINDOW coordinates and `/api/viewport/probe` wants cell
/// coordinates, so the viewport origin has to come off — the same conversion
/// `tests/test_bus_position_pixel.d :: fbo` makes.
int[2] fbo(DHVec3 world) {
    auto camS = fetchCamera(BASE);
    auto vp   = viewportFromCamera(camS);
    float fx, fy;
    assert(projectToWindow(world, vp, fx, fy),
        format("rig: the world point (%g,%g,%g) is behind the camera",
               world.x, world.y, world.z));
    const int x = cast(int)(fx + 0.5f) - camS.vpX;
    const int y = cast(int)(fy + 0.5f) - camS.vpY;
    assert(x >= 0 && y >= 0 && x < camS.width && y < camS.height,
        format("rig: (%g,%g,%g) projects to cell pixel (%d,%d), outside the "
             ~ "%dx%d cell", world.x, world.y, world.z, x, y,
               camS.width, camS.height));
    return [x, y];
}

/// Points that lie ON grid lines of the RIGHT half — the half the delete
/// removes and the undo must bring back. Four sit on the outer right boundary
/// (x = +1), four on interior grid lines inside that half. All are edge
/// MIDPOINTS, so none of them lands on a vertex dot.
DHVec3[] wireProbePoints() {
    DHVec3[] p;
    // Points ON the INTERIOR VERTICAL grid line x = 0.5, inside the half the
    // delete removes. Each is scanned as a HORIZONTAL run, which crosses that
    // vertical line.
    foreach (y; [-0.75f, -0.25f, 0.25f, 0.75f]) p ~= DHVec3(0.5f, y, 0.0f);
    return p;
    // The OUTER boundary (x = 1) is deliberately NOT probed: it is the
    // silhouette, so a half-pixel of projection rounding puts the sample off
    // the patch entirely and the premise reads background. Measured — the
    // first version of this rig probed it and four of eight points landed on
    // background.
}

/// A point INSIDE one face of the right half, on no grid line — the reference
/// for "this pixel is face fill, not a wireframe line".
enum DHVec3 kFaceInterior = DHVec3(0.65f, 0.65f, 0.0f);

unittest {
    // ---- rig ------------------------------------------------------------
    postJson("/api/reset", "{}");
    settle();
    loadOpenPatch();
    post(BASE ~ "/api/camera?viewport=0",
         `{"azimuth":0.0,"elevation":0.0,"distance":11.0}`);
    settle();
    auto camera = fetchCamera(BASE);
    assert(camera.eye.z > 1.0f && fabs(camera.eye.x) < 0.01f
        && fabs(camera.eye.y) < 0.01f,
        format("rig: the camera must sit on +z looking at the origin, it is at "
             ~ "(%g,%g,%g)", camera.eye.x, camera.eye.y, camera.eye.z));
    settle();

    // THE SELECTION IS MADE BEFORE THE REFERENCE FRAME IS CAPTURED, and that
    // is not tidiness. An undo restores the SELECTION as well as the geometry,
    // so the restored half comes back highlighted; capturing the reference on
    // an unselected patch and comparing it with a selected one reports a
    // difference on every scan for a reason that has nothing to do with this
    // step. MEASURED — that is exactly how this cell first failed, with the
    // whole wireframe reading the selection colour (255,168,41).
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select",
                        `{"mode":"polygons","indices":[2,3,6,7,10,11,14,15]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();

    enum int kRun = 9;                 // pixels per horizontal scan
    auto pts = wireProbePoints();
    int[2][] cells;
    foreach (w; pts) cells ~= fbo(w);

    Px[][] before;
    foreach (c; cells) before ~= probeRun(c[0] - kRun / 2, c[1], kRun);

    // PREMISE 1: the probes are on DRAWN geometry, not on background. Without
    // this the whole file could be comparing background to background — the
    // exact failure this rig hit on its first run.
    const Px bg = probe1(4, cells[0][1]);
    size_t onGeometry = 0;
    foreach (b; before) {
        bool any = false;
        foreach (px; b) if (rgbDist(px, bg) >= kDiffer) any = true;
        if (any) ++onGeometry;
    }
    assert(onGeometry == pts.length, format(
        "PREMISE 1: only %d of %d scans cross drawn geometry (background reads "
      ~ "%s) — the rig is not looking at the patch and nothing below is "
      ~ "decidable", onGeometry, pts.length, bg));

    // PREMISE 2, and it is the one that makes this a WIREFRAME cell rather
    // than a face cell: the probes must sit on drawn LINES, not merely on the
    // surface. A point on face fill reads the same before and after a
    // fast-path undo — `faces` and `vertices` ARE restored correctly — so a
    // rig whose points all landed on fill would be green under the mutation,
    // which is exactly how the plan's original W4a failed.
    const int[2] fc = fbo(kFaceInterior);
    const Px faceFill = probe1(fc[0], fc[1]);
    assert(rgbDist(faceFill, bg) >= kDiffer, format(
        "PREMISE 2a: the face-interior reference %s is indistinguishable from "
      ~ "the background %s — the reference itself missed the patch", faceFill, bg));
    size_t onLine = 0;
    foreach (b; before) {
        bool any = false;
        foreach (px; b) if (rgbDist(px, faceFill) >= kDiffer) any = true;
        if (any) ++onLine;
    }
    assert(onLine == pts.length, format(
        "PREMISE 2b: only %d of %d scans contain a pixel that reads "
      ~ "differently from the face fill %s, so they are sampling the SURFACE "
      ~ "and not the wireframe. This cell would then be green under its own "
      ~ "mutation.", onLine, pts.length, faceFill));

    // ---- the edit: a TOPOLOGY op, delta-backed, SLOW path ----------------
    cmd(`{"id":"mesh.delete"}`);
    settle();

    size_t moved = 0;
    foreach (i; 0 .. pts.length) {
        auto now = probeRun(cells[i][0] - kRun / 2, cells[i][1], kRun);
        if (runSig(now) != runSig(before[i])) ++moved;
    }
    assert(moved == pts.length, format(
        "PREMISE 3: deleting the half these scans cross moved only %d of %d "
      ~ "scans — the edit is not visible where the claim is made, so the undo "
      ~ "below cannot be either", moved, pts.length));

    // ---- the claim ------------------------------------------------------
    cmd(`{"id":"history.undo"}`);
    settle();

    string diff;
    size_t bad = 0;
    foreach (i; 0 .. pts.length) {
        auto now = probeRun(cells[i][0] - kRun / 2, cells[i][1], kRun);
        if (runSig(now) != runSig(before[i])) {
            ++bad;
            diff ~= format("\n    world (%g,%g), scan row %d from x=%d:"
                         ~ "\n        was %s\n        now %s",
                           pts[i].x, pts[i].y, cells[i][1], cells[i][0] - kRun / 2,
                           runSig(before[i]), runSig(now));
        }
    }
    assert(bad == 0, format(
        "W4a: undoing a TOPOLOGY delete did not put the WIREFRAME back where "
      ~ "it was — %d of %d scans differ.%s\n\n"
      ~ "The mutation this cell exists for is an over-broad "
      ~ "`indexSpaceStable`: a log carrying RemoveFaces taking the fast path "
      ~ "leaves `mesh.edges` holding the POST-delete vertex-index pairs while "
      ~ "the revert re-expands the vertex array under them, so the edge pass "
      ~ "draws GL_LINES between the wrong vertices. Note what stays GREEN "
      ~ "under that bug: `/api/model`'s edge array and test_frame_counts' "
      ~ "`2 x edgeCount` submission check, because both read the SAME stale "
      ~ "array and therefore agree with each other.",
        bad, pts.length, diff));

    writefln("W4a OK: %d wireframe scans restored exactly (%d moved on the delete)",
             pts.length, moved);
}
