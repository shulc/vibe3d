// test_viewport_gbuffer.d — the G-buffer writes and the composite stage
// (wave plan S2b, task 9190, model M4). The cavity kernels are absent, so the
// resolve is an IDENTITY: a frame with cavity on hashes equal to the frame
// with it off, which is the no-op proof of the whole stage — and the path is
// proved to have EXECUTED by the cell's own record (`compositeRuns`,
// `compositeBindings`), not inferred from the equal hash.
//
// Rig: a subdivided cube (layer 0, a near-sphere, background), the PRIMARY
// cube (layer 1) to its right, a back-facing quad (layer 2, background) to
// its left — neither the primary nor every background layer is layer 0, so a
// site that passed the wrong layer index is seen; orthographic Front view so
// the eye normal of the sphere's front point is (0,0,1); smooth normals.
module test_viewport_gbuffer;

import http_client : getJson, postJson, quiesce, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round, sqrt;

void main() {}

private void settle() { quiesce(); frameFence(null, 2); }
private void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}
private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }
private bool jb(JSONValue v) {
    assert(v.type == JSONType.true_ || v.type == JSONType.false_, "expected a bool: " ~ v.toString);
    return v.type == JSONType.true_;
}
private long ji(JSONValue v) {
    return v.type == JSONType.uinteger ? cast(long) v.uinteger : v.integer;
}

private JSONValue cell0() { return getJson("/api/viewport/display")["cells"].array[0]; }
private long runs() { return ji(cell0()["compositeRuns"]); }

private string hash() {
    // The probe returns the last COMPLETED frame: read until two agree.
    string prev = getJson("/api/viewport/probe?cell=0&hash=1")["hash"].str;
    foreach (_; 0 .. 8) {
        settle();
        auto j = getJson("/api/viewport/probe?cell=0&hash=1");
        assert(jb(j["renders"]), "the probed cell is not rendered; the hash is void");
        if (j["hash"].str == prev) return prev;
        prev = j["hash"].str;
    }
    assert(false, "cell 0 hash never settled");
}

/// One G-buffer texel: id, flags and the decoded eye normal.
private struct G { long id, flags; double[3] n; }

private G[] gbuf(int[2][] pts) {
    string s;
    foreach (k, p; pts) s ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    auto j = getJson("/api/viewport/probe?cell=0&buffer=gbuf&points=" ~ s);
    assert("error" !in j, "gbuf probe failed: " ~ j.toString);
    G[] o;
    foreach (e; j["points"].array) {
        auto a = e["gbuf"].array;   // [x, y, id, flags, nx, ny]
        G g;
        g.id = ji(a[2]); g.flags = ji(a[3]);
        // Octahedral decode of the two unorm16 values.
        double ex = ji(a[4]) / 65535.0 * 2 - 1, ey = ji(a[5]) / 65535.0 * 2 - 1;
        double nz = 1 - abs(ex) - abs(ey);
        double nx = ex, ny = ey;
        if (nz < 0) {
            nx = (1 - abs(ey)) * (ex >= 0 ? 1 : -1);
            ny = (1 - abs(ex)) * (ey >= 0 ? 1 : -1);
        }
        immutable double l = sqrt(nx * nx + ny * ny + nz * nz);
        g.n = [nx / l, ny / l, nz / l];
        o ~= g;
    }
    assert(o.length == pts.length);
    return o;
}

private Viewport frontOrtho() {
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0", `{"focus":{"x":0.6,"y":0,"z":0},"distance":6}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    return vp;
}

private int[2] toPx(double x, double y, double z, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) x, cast(float) y, cast(float) z), vp, px, py),
        "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private string cubeJson(double cx, double s) {
    JSONValue[] v;
    foreach (k; 0 .. 8)
        v ~= JSONValue([cx + ((k & 1) ? s : -s), (k & 2) ? s : -s, (k & 4) ? s : -s]);
    // Outward-facing quads (counter-clockwise seen from outside).
    auto f = JSONValue([[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3],
                        [0, 4, 6, 2], [1, 3, 7, 5]]);
    return JSONValue(["vertices": JSONValue(v), "faces": f]).toString;
}

/// Both layers sit `kLift` above the ground grid: seen edge-on in the Front
/// view the grid is a line through y = 0 that occludes (and so leaves gbuf 0
/// along) the centre row of anything at y = 0.
private enum double kLift = 0.5;

/// Layer 0: the near-sphere (background). Layer 1: the primary cube centred
/// at x = 2.2. Layer 2: the back-facing quad (background). Shaded.
private Viewport rig() {
    cmdOk(commandBody("scene.reset", `{"type":"subdivcube","levels":3}`));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh", cubeJson(2.2, 0.4)));
    // Layer 2: a quad FACING AWAY (-Z) left of the sphere: its eye normal
    // is (0,0,-1), the lower octahedral hemisphere.
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh", `{"vertices":[[-2.0,-0.3,0],[-1.2,-0.3,0],[-1.2,0.3,0],`
        ~ `[-2.0,0.3,0]],"faces":[[0,3,2,1]]}`));
    cmdOk(format("layer.attr 0 pos.y %s", kLift));
    cmdOk(format("layer.attr 1 pos.y %s", kLift));
    cmdOk(format("layer.attr 2 pos.y %s", kLift));
    cmdOk(`{"id":"layer.select","index":1,"mode":"set"}`);
    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    auto vp = frontOrtho();
    auto L = getJson("/api/layers");
    assert(L["active"].integer == 1 && jb(L["layers"].array[0]["background"])
        && jb(L["layers"].array[2]["background"]),
        "rig: layer 1 must be the primary, layers 0 and 2 background: " ~ L.toString);
    auto b = cell0()["plan"]["backdrop"];
    assert(jb(b["drawFaces"]), "rig premise: the backdrop draws its faces: " ~ b.toString);
    return vp;
}

// ===========================================================================
// (i) identity + the path executed + bindings; (ii) the G-buffer contents
// ===========================================================================
unittest {
    auto vp = rig();
    cmd("viewport.cavity", `{"value":"off"}`);
    auto p0 = cell0()["plan"]["active"];
    assert(jb(p0["composite"]["empty"]), "premise: cavity off resolves an empty composite");
    immutable string hOff = hash();
    immutable long r0 = runs();

    cmd("viewport.cavity", `{"value":"screen"}`);
    auto pa = cell0()["plan"]["active"];
    assert(!jb(pa["composite"]["empty"]) && pa["composite"]["cavity"].str == "Screen",
        "premise: cavity screen under Shaded resolves a composite: " ~ pa.toString);
    immutable string hOn = hash();
    immutable long r1 = runs();
    // Positive control first [E10]: the stage RAN between the two hashes.
    assert(r1 >= r0 + 1, format("(i) compositeRuns must advance with cavity on: %d -> %d", r0, r1));
    auto c = cell0();
    // Bindings: floor first [E4] (Screen = copy + resolve), then per row.
    auto rows = c["compositeBindings"].array;
    assert(rows.length == 2, format("(i) compositeBindings: %d rows, expected 2 (copy + resolve): %s",
                                    rows.length, c["compositeBindings"].toString));
    immutable long scene = ji(c["fboIds"]["scene"]), effects = ji(c["fboIds"]["effects"]),
                   color = ji(c["fboIds"]["color"]);
    assert(effects != 0 && effects != scene, "(i) the effects fbo must exist and differ from the scene fbo");
    foreach (k, r; rows) {
        assert(ji(r["bound"]) == effects,
            format("(i) pass %d drew into fbo %d, not the effects fbo %d", k, ji(r["bound"]), effects));
        assert(ji(r["bound"]) != scene, format("(i) pass %d drew into the scene fbo", k));
    }
    assert(jb(c["compositeChecked"]),
        "(i) premise: a debug build checks the stage's GL contract (compositeChecked)");
    assert(ji(c["compositeFaults"]) == 0,
        format("(i) the stage's GL contract was violated %d time(s); first: %s",
               ji(c["compositeFaults"]), c["firstCompositeFault"].toString));
    assert(ji(rows[1]["attached"]) == color,
        format("(i) the resolve must write colorTex %d, attached %d", color, ji(rows[1]["attached"])));
    // The identity: the kernels are absent, so the frame is unchanged.
    assert(hOn == hOff, format("(i) cavity on must hash equal to cavity off (identity resolve): %s vs %s",
                               hOn, hOff));

    // (ii) the G-buffer: background, sphere front (backdrop site), the primary
    // cube (primary site), the back-facing quad (backdrop site), sphere rim.
    auto front = toPx(0, kLift, 0, vp), bd = toPx(2.2, kLift, 0, vp), bg = toPx(0.6, 1.6, 0, vp);
    auto g = gbuf([bg, front, bd]);
    assert(g[0].id == 0 && g[0].flags == 0, format("(ii) background: id %d flags %d, expected 0/0", g[0].id, g[0].flags));
    assert(g[1].id == 1 && (g[1].flags & 1) == 1,
        format("(ii) sphere front %s: id %d flags %d, expected id 1 (layer 0 + 1), flag bit 0",
               front, g[1].id, g[1].flags));
    assert(abs(g[1].n[0]) < 0.02 && abs(g[1].n[1]) < 0.02 && abs(g[1].n[2] - 1) < 0.02,
        format("(ii) sphere front: eye normal %s, expected (0,0,1) within 0.02", g[1].n));
    assert(g[2].id == 2 && (g[2].flags & 1) == 1,
        format("(ii) primary cube: id %d flags %d, expected its own id 2 (layer 1 + 1), flag bit 0",
               g[2].id, g[2].flags));
    // The back-facing quad (layer 2): its own id, eye normal (0,0,-1).
    auto gb = gbuf([toPx(-1.6, kLift + 0.1, 0, vp)]);
    assert(gb[0].id == 3 && abs(gb[0].n[2] + 1) < 0.02,
        format("(ii) back-facing quad: id %d n %s, expected id 3 and n (0,0,-1)", gb[0].id, gb[0].n));
    // The rim: the last sphere pixel along the row through the front point.
    int[2][] row;
    foreach (dx; 0 .. 200) row ~= [front[0] - dx, front[1]];
    auto gr = gbuf(row);
    ptrdiff_t last = -1;
    foreach (k, t; gr) if (t.id == 1) last = k; else break;
    assert(last > 10, format("(ii) rim: the sphere spans only %d pixels left of its front point", last));
    assert(abs(gr[last].n[2]) < 0.3,
        format("(ii) sphere rim pixel %s: |n.z| %s, expected < 0.3", row[last], abs(gr[last].n[2])));

    // C1 is cleared every frame: a pixel the sphere vacates reads id 0.
    cmdOk("layer.attr 0 pos.y 3");
    settle(); settle();
    auto gv = gbuf([front]);
    cmdOk(format("layer.attr 0 pos.y %s", kLift));
    assert(gv[0].id == 0 && gv[0].flags == 0,
        format("(ii) the pixel the sphere vacated must read id 0 flags 0, got %d/%d (C1 not cleared)",
               gv[0].id, gv[0].flags));
}

// ===========================================================================
// (iii) cavity applies only under Shaded and never under retopology
// ===========================================================================
unittest {
    rig();
    cmd("viewport.cavity", `{"value":"screen"}`);
    cmd("viewport.displayStyle", `{"style":"solid"}`);
    auto pa = cell0()["plan"]["active"];
    assert(jb(pa["composite"]["empty"]),
        "(iii) Solid + cavity screen must resolve an empty composite (cavity is Shaded-only): " ~ pa.toString);
    assert(ji(pa["effectFlags"]) == 0, "(iii) Solid is not cavity-eligible");
    immutable string hSolidOn = hash();
    immutable long r0 = runs();
    settle(); settle();
    immutable long r1 = runs();
    assert(r1 == r0, format("(iii) Solid + cavity: compositeRuns must not advance over two frames: %d -> %d", r0, r1));
    cmd("viewport.cavity", `{"value":"off"}`);
    immutable string hSolidOff = hash();
    assert(hSolidOn == hSolidOff, "(iii) Solid with cavity must hash equal to Solid without");

    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.cavity", `{"value":"screen"}`);
    immutable long r2 = runs();
    settle();
    assert(runs() > r2, "(iii) control: back under Shaded the stage runs again");
    cmd("viewport.retopology", `{"value":"on"}`);
    auto pr = cell0()["plan"]["active"];
    assert(jb(pr["clearDepthFirst"]) && jb(pr["composite"]["empty"]),
        "(iii) retopology must resolve an empty composite: " ~ pr.toString);
    immutable long r3 = runs();
    settle(); settle();
    assert(runs() == r3, format("(iii) retopology: compositeRuns must stay %d, got %d", r3, runs()));
    cmd("viewport.retopology", `{"value":"off"}`);
}

// ===========================================================================
// (iv) after a cell resize the G-buffer still decodes (S2a's re-spec, live)
// ===========================================================================
unittest {
    rig();
    cmd("viewport.cavity", `{"value":"screen"}`);
    hash();
    auto before = cell0();
    immutable long gbufId = ji(before["fboIds"]["gbuf"]);
    auto s0 = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable long[2] w0 = [s0["w"].integer, s0["h"].integer];
    assert(gbufId != 0, "(iv) premise: the G-buffer is allocated");
    cmd("viewport.layout", `"SplitV"`);
    cmd("viewport.displayStyle", `{"style":"shaded","viewport":0}`);
    cmd("viewport.cavity", `{"value":"screen","viewport":0}`);
    auto d = getJson("/api/viewport/display");
    assert(d["activeId"].integer == 0, "(iv) premise: cell 0 is the active (rendered) cell");
    auto vp = frontOrtho();
    hash();
    auto s1 = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable long[2] w1 = [s1["w"].integer, s1["h"].integer];
    assert(w1 != w0, format("(iv) premise: the cell resized (%s -> %s)", w0, w1));
    assert(ji(cell0()["fboIds"]["gbuf"]) == gbufId, "(iv) the G-buffer id must survive the resize");
    auto g = gbuf([toPx(0, kLift, 0, vp)]);
    assert(g[0].id == 1 && abs(g[0].n[2] - 1) < 0.02,
        format("(iv) after the resize the sphere front must decode id 1, n (0,0,1): id %d n %s", g[0].id, g[0].n));
    cmd("viewport.layout", `"Single"`);
}
