// A POLYGON REGION LASSO UNDER THE WIREFRAME STYLE TAKES BACK-FACING AND
// OCCLUDED POLYGONS TOO (wave-plan item 19).
//
// Captured law (`tests/fixtures/lasso_polygon_facing_by_style.json`): with the
// default selection-visibility policy a loop enclosing the whole eight-quad rig
// selects FOUR polygons under a style that fills faces and ALL EIGHT under the
// wireframe style. Our polygon lasso culls back-facing polygons unconditionally
// (`InputRouter`'s lasso block, `if (!frontFacing(...)) continue;`), while the
// resolver's `facingTerm` (`source/select_visibility.d`) is already false under
// wireframe and read by nobody.
//
// WHY THE RIG IS OPEN QUADS: on a closed solid facing and occlusion coincide,
// so every candidate rule agrees. The rig separates them: `back_solo` is
// back-facing and unoccluded, `occl_ff.far` front-facing and occluded, and
// `occl_bf.far` is front-facing behind a BACK-facing occluder.
//
// The capture was orthographic; ours is a perspective eye far enough out
// (distance 90 on the rig's centre line) that every far quad stays behind its
// near quad — asserted below from the projected corners, not assumed.
//
// Order: floor (8 quads) -> solid control (the fixture's 4) -> wireframe (the
// fixture's 8) -> solid again (4: the style is re-read per gesture) -> the same
// pair under a live subpatch preview, which is the lasso's second polygon
// branch with its own cull.

import http_client : testBaseUrl, getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.algorithm : sort, map, countUntil;
import std.array  : array, join;
import std.math   : lround;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

enum string kFixture = import("fixtures/lasso_polygon_facing_by_style.json");

// Card test-sleep-removal: quiesce (frame fence + no pending preview build) replaces the fixed sleep (300.msecs).

void settle() { quiesce(); }

void cmdOk(string body_) {
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ body_ ~ " -> " ~ r.toString);
}

void setStyle(string s) {
    cmdOk(format(`{"id":"viewport.displayStyle","params":"%s"}`, s));
    settle();
}

string lassoLog(ref CameraState c, int x0, int y0, int x1, int y1) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    int px = x0, py = y0;
    void go(int x, int y) {
        t += 25.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
            t, x, y, x - px, y - py);
        px = x; py = y;
    }
    foreach (i; 1 .. 5) go(x0 + (x1 - x0) * i / 4, y0);
    foreach (i; 1 .. 5) go(x1, y0 + (y1 - y0) * i / 4);
    foreach (i; 1 .. 5) go(x1 - (x1 - x0) * i / 4, y1);
    foreach (i; 1 .. 5) go(x0, y1 - (y1 - y0) * i / 4);
    t += 25.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    return log;
}

unittest {
    auto fx = parseJSON(kFixture);
    auto rig = fx["rig"].array;
    // Population floor on the FIXTURE: eight quads, and the two cells.
    assert(rig.length == 8, format("fixture rig has %d quads, want 8", rig.length));
    string[] ids = rig.map!(r => r["id"].str).array;
    int[] expectIds(string style) {
        int[] o;
        foreach (s; fx["cells"][style]["selected"].array) {
            immutable k = ids.countUntil(s.str);
            assert(k >= 0, "fixture cell names an unknown quad " ~ s.str);
            o ~= cast(int)k;
        }
        o.sort();
        return o;
    }
    immutable int[] wantSolid = expectIds("solid").idup;
    immutable int[] wantWire  = expectIds("wireframe").idup;
    assert(wantSolid.length == 4 && wantWire.length == 8,
           format("fixture cells drifted: solid %s wireframe %s", wantSolid, wantWire));

    // Build the mesh from the wound rings, face i = rig[i].
    string v, f;
    foreach (i, r; rig) {
        auto ring = r["ring"].array;
        assert(ring.length == 4, "rig quad " ~ r["id"].str ~ " is not a quad");
        foreach (j, p; ring) {
            if (v.length) v ~= ",";
            v ~= format("[%s,%s,%s]", p[0].floating, p[1].floating, p[2].floating);
        }
        if (f.length) f ~= ",";
        f ~= format("[%d,%d,%d,%d]", 4*i, 4*i+1, 4*i+2, 4*i+3);
    }
    cmdOk(commandBody("scene.reset"));
    settle();
    cmdOk(commandBody("scene.loadMesh", `{"vertices":[` ~ v ~ `],"faces":[` ~ f ~ `]}`));
    // AFTER the load: loading re-frames the camera.
    auto cr = postJson("/api/camera",
        `{"azimuth":0,"elevation":0,"distance":90,"focus":{"x":12,"y":0,"z":0}}`);
    assert(cr["status"].str == "ok", "camera failed: " ~ cr.toString);
    settle();

    // ---- floor: the rig loaded as eight quads ------------------------------
    auto model = getJson("/api/model");
    assert(model["faces"].array.length == 8 && model["vertices"].array.length == 32,
           format("rig: loaded %d faces / %d vertices, want 8 / 32",
                  model["faces"].array.length, model["vertices"].array.length));

    auto cam = fetchCamera();
    assert(cam.eye.z > 80.0f && cam.eye.z < 100.0f,
           format("rig: the eye is not on +Z at distance 90: (%s,%s,%s)",
                  cam.eye.x, cam.eye.y, cam.eye.z));
    auto vp = viewportFromCamera(cam);
    int[2] pix(Vec3 w) {
        float sx, sy;
        assert(projectToWindow(w, vp, sx, sy), "rig point behind the eye");
        return [cast(int)lround(sx), cast(int)lround(sy)];
    }
    // Every far quad must project INSIDE its near quad (perspective stands in
    // for the capture's orthographic view), or "occluded" is not true here.
    float[2] pixf(JSONValue p) {
        float sx, sy;
        assert(projectToWindow(Vec3(p[0].floating, p[1].floating, p[2].floating),
                               vp, sx, sy), "rig point behind the eye");
        return [sx, sy];
    }
    foreach (st; ["occl_ff", "occl_fb", "occl_bf"]) {
        auto nr = rig[ids.countUntil(st ~ ".near")]["ring"].array;
        auto fr = rig[ids.countUntil(st ~ ".far")]["ring"].array;
        float nx0 = float.max, ny0 = float.max, nx1 = -float.max, ny1 = -float.max;
        foreach (p; nr) {
            auto q = pixf(p);
            if (q[0] < nx0) nx0 = q[0]; if (q[0] > nx1) nx1 = q[0];
            if (q[1] < ny0) ny0 = q[1]; if (q[1] > ny1) ny1 = q[1];
        }
        foreach (p; fr) {
            auto q = pixf(p);
            assert(q[0] > nx0 && q[0] < nx1 && q[1] > ny0 && q[1] < ny1,
                   format("rig: %s.far corner (%s,%s) is not behind its near "
                          ~ "quad [%s..%s]x[%s..%s] from this eye", st, q[0], q[1],
                          nx0, nx1, ny0, ny1));
        }
    }
    // One band enclosing every corner with a margin.
    int x0 = int.max, y0 = int.max, x1 = int.min, y1 = int.min;
    foreach (r; rig) foreach (p; r["ring"].array) {
        auto q = pix(Vec3(p[0].floating, p[1].floating, p[2].floating));
        if (q[0] < x0) x0 = q[0]; if (q[0] > x1) x1 = q[0];
        if (q[1] < y0) y0 = q[1]; if (q[1] > y1) y1 = q[1];
    }
    x0 -= 20; y0 -= 20; x1 += 20; y1 += 20;
    assert(x0 > cam.vpX && y0 > cam.vpY
           && x1 < cam.vpX + cam.width && y1 < cam.vpY + cam.height,
           format("rig: the band [%d..%d]x[%d..%d] leaves the viewport", x0, x1, y0, y1));

    cmdOk(`select.typeFrom polygon`);
    int[] lassoFaces() {
        cmdOk(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
        playAndWait(lassoLog(cam, x0, y0, x1, y1));
        settle();
        auto sel = getJson("/api/selection");
        assert(sel["mode"].str == "polygons",
               "the lasso ran outside polygon mode: " ~ sel["mode"].str);
        int[] o;
        foreach (e; sel["selectedFaces"].array) o ~= cast(int)e.integer;
        o.sort();
        return o;
    }

    // ---- control, must stay GREEN: a filling style takes the fixture's 4 ---
    setStyle("solid");
    scope(exit) setStyle("shaded");
    auto gotSolid = lassoFaces();
    assert(gotSolid == wantSolid,
           format("solid-style polygon lasso selected %s, reference %s",
                  gotSolid, wantSolid));

    // ---- the witness: wireframe takes all 8 --------------------------------
    setStyle("wireframe");
    auto gotWire = lassoFaces();
    assert(gotWire == wantWire,
           format("wireframe lasso culled back-facing polygons: selected %s, "
                  ~ "reference %s", gotWire, wantWire));

    // ---- the style is re-read per gesture: back to solid, back to 4 --------
    // Pins the other direction: a cull resolved once and kept (or a term
    // latched off by the wireframe gesture) would answer 8 here.
    setStyle("solid");
    auto gotSolidAgain = lassoFaces();
    assert(gotSolidAgain == wantSolid,
           format("solid-style lasso after a wireframe lasso selected %s, "
                  ~ "reference %s (the style was not re-read)",
                  gotSolidAgain, wantSolid));

    // ---- the PREVIEW branch: the same rig under subpatch --------------------
    // The lasso block has two polygon branches (cage and subpatch preview);
    // each carries its own facing cull, so each needs its own red line.
    cmdOk(commandBody("mesh.select",
                      `{"mode":"polygons","indices":[0,1,2,3,4,5,6,7]}`));
    cmdOk(`{"id":"mesh.subpatch_toggle"}`);
    JSONValue pv;
    foreach (_; 0 .. 1500) {
        pv = getJson("/api/subpatch/preview");
        if (pv["pending"].type != JSONType.true_) break;
        Thread.sleep(20.msecs);
    }
    assert(pv["pending"].type != JSONType.true_ && pv["active"].type == JSONType.true_,
           "rig: the subpatch preview is not live and settled: " ~ pv.toString);

    auto gotSubSolid = lassoFaces();
    assert(gotSubSolid == wantSolid,
           format("subpatch solid-style polygon lasso selected %s, reference %s",
                  gotSubSolid, wantSolid));
    setStyle("wireframe");
    auto gotSubWire = lassoFaces();
    assert(gotSubWire == wantWire,
           format("subpatch wireframe lasso culled back-facing polygons: "
                  ~ "selected %s, reference %s", gotSubWire, wantWire));
}
