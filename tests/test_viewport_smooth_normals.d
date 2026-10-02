// The face VBO's normal source (viewport shading S1a, task 9070): every face
// corner carries [pos | flat normal | smooth normal]; the lit program picks the
// stream per cell from `DrawPlan.smoothNormals`; normals go through the
// inverse-transpose normal matrix. Smoothing law (captured): on by default,
// split above the smoothing angle between face normals, uniform weighting,
// hidden faces still contribute.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, sqrt;
import http_client : frameFence;
import std.stdio : writefln;

void main() {}

/// `VIBE3D_CELL=<id>` runs one cell (druntime stops a module at its first
/// failed assert, so a mutation that must redden two cells runs them apart).
bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok",
           "/api/command failed for " ~ script ~ ": " ~ r.toString);
}

void runCmd(string id, string paramsJson) {
    auto r = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

void select(string mode, int[] indices) {
    string body = `{"mode":"` ~ mode ~ `","indices":[`;
    foreach (i, idx; indices) {
        if (i) body ~= ",";
        body ~= idx.to!string;
    }
    body ~= "]}";
    auto r = postJson("/api/command", commandBody("mesh.select", body));
    assert(r["status"].str == "ok", "mesh.select failed: " ~ r.toString);
}

double[3] triple(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

bool near3(double[3] a, double[3] b, double eps) {
    return abs(a[0] - b[0]) <= eps && abs(a[1] - b[1]) <= eps
        && abs(a[2] - b[2]) <= eps;
}

double dist3(double[3] a, double[3] b) {
    return sqrt((a[0]-b[0])^^2 + (a[1]-b[1])^^2 + (a[2]-b[2])^^2);
}

// ---------------------------------------------------------------------------
// Rig helpers: a mesh loaded from a written .v3d (exact geometry, no tool),
// the live camera, the lit program's light function (S1a-era world rig) for
// predictions, and the pixel probe.
// ---------------------------------------------------------------------------

alias V3 = drag_helpers.Vec3;

V3 sub(V3 a, V3 b) { return V3(a.x - b.x, a.y - b.y, a.z - b.z); }
V3 crs(V3 a, V3 b) { return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x); }
double dt(V3 a, V3 b) { return cast(double)a.x*b.x + cast(double)a.y*b.y + cast(double)a.z*b.z; }
V3 unit(V3 a) { immutable double l = sqrt(dt(a, a)); return V3(a.x / l, a.y / l, a.z / l); }
V3 faceNormal(V3[] v, uint[] f) { return unit(crs(sub(v[f[1]], v[f[0]]), sub(v[f[2]], v[f[0]]))); }

private int g_rig = 0;

/// Replace the scene with ONE mesh layer holding `verts`/`faces`.
void loadMesh(V3[] verts, uint[][] faces) {
    import std.file : write, remove, exists, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    string vs, fs;
    foreach (i, v; verts) vs ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", v.x, v.y, v.z);
    foreach (i, f; faces) {
        fs ~= i ? ",[" : "[";
        foreach (j, x; f) fs ~= format("%s%d", j ? "," : "", x);
        fs ~= "]";
    }
    immutable path = buildPath(tempDir(), format("vibe3d-smooth-rig-%d-%d.v3d", thisProcessID(), g_rig++));
    write(path, `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"Rig","visible":true},"mesh":{"vertices":[` ~ vs
        ~ `],"faces":[` ~ fs ~ `]}}]}`);
    scope(exit) if (exists(path)) remove(path);
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed: " ~ rr.toString);
    runCmd("file.load", format(`{"path":"%s"}`, path));
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == verts.length && m["faces"].array.length == faces.length,
        format("rig: loaded %d verts / %d faces, wrote %d / %d", m["vertices"].array.length,
               m["faces"].array.length, verts.length, faces.length));
}

/// A UV sphere of radius 1 at the origin, poles on Y, faces wound outward.
void uvSphere(int segs, int rings, out V3[] v, out uint[][] f) {
    import std.math : PI, cos, sin;
    v ~= V3(0, 1, 0);
    foreach (k; 1 .. rings) {
        immutable double lat = PI / 2 - PI * k / rings;
        foreach (j; 0 .. segs) {
            immutable double lon = 2 * PI * j / segs;
            v ~= V3(cast(float)(cos(lat) * sin(lon)), cast(float)sin(lat),
                    cast(float)(cos(lat) * cos(lon)));
        }
    }
    v ~= V3(0, -1, 0);
    uint at(int k, int j) { return cast(uint)(1 + (k - 1) * segs + (j % segs)); }
    immutable uint bottom = cast(uint)(v.length - 1);
    foreach (j; 0 .. segs) f ~= [0u, at(1, j), at(1, j + 1)];
    foreach (k; 1 .. rings - 1)
        foreach (j; 0 .. segs) f ~= [at(k, j), at(k + 1, j), at(k + 1, j + 1), at(k, j + 1)];
    foreach (j; 0 .. segs) f ~= [bottom, at(rings - 1, j + 1), at(rings - 1, j)];
    foreach (ref face; f) {   // wind outward: normal along the centroid
        V3 c = V3(0, 0, 0);
        foreach (x; face) c = V3(c.x + v[x].x, c.y + v[x].y, c.z + v[x].z);
        if (dt(faceNormal(v, face), c) < 0) {
            import std.algorithm : reverse;
            face.reverse();
        }
    }
}

void setCamera(double az, double el, double dist, double fx = 0, double fy = 0, double fz = 0) {
    auto r = postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        az, el, dist, fx, fy, fz));
    frameFence(null, 2);
}

/// World point -> cell pixel through the live camera matrices.
int[2] cellPx(V3 world) {
    auto vp = viewportFromCameraMatrices();
    float px, py;
    assert(projectToWindow(world, vp, px, py), format("rig: %s is behind the camera", world));
    immutable int x = cast(int)(px + 0.5f) - vp.x, y = cast(int)(py + 0.5f) - vp.y;
    assert(x >= 4 && y >= 4 && x < vp.width - 4 && y < vp.height - 4,
        format("rig: %s projects to (%d,%d) outside the %dx%d cell", world, x, y, vp.width, vp.height));
    return [x, y];
}

/// Red channel at each `pts` of `cell`, with the cell's `renders` flag.
int[] probeR(int cell, int[2][] pts, out bool renders) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=%d&points=%s", cell, q));
    renders = j["renders"].type == JSONType.true_;
    int[] r;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        r ~= cast(int)e["r"].integer;
    }
    return r;
}

/// The lit program's Material arm at unit world normal `n`, surface point `p`,
/// eye `eye`, in 0..255 levels: `litTerm` with the light_rig constants and the
/// default material base 0.8 (no gamma).
double litLevel(V3 n, V3 p, V3 eye) {
    import std.math : pow;
    immutable V3 l = unit(V3(0.6f, 1.0f, 0.5f));
    immutable V3 v = unit(sub(eye, p));
    immutable V3 h = unit(V3(l.x + v.x, l.y + v.y, l.z + v.z));
    immutable double dif = dt(n, l) > 0 ? dt(n, l) : 0;
    immutable double spc = pow(dt(n, h) > 0 ? dt(n, h) : 0, 32.0);
    double c = 0.8 * (0.2 + dif * 0.8) + spc * 0.25;
    if (c > 1) c = 1;
    return 255.0 * c;
}

V3 liveEye() { return viewportFromCameraMatrices().eye; }

/// The sphere rig shared by (i), (ii), (iv): a 32x16 sphere, wire overlay off,
/// the latitude edge between rings 2 and 3 (+22.5°, away from the grid's
/// horizon row) at the front band centre. Returns the two probe pixels (2 px
/// above / below the edge), the predicted FLAT step and the predicted SMOOTH
/// step bound (the flat step scaled by 4 px over the face height in px — the
/// smooth stream is continuous across the edge, so only its gradient remains).
struct SphereRig { int[2][] pts; double flatStep, smoothStep; }

SphereRig sphereRig(void delegate() afterLoad = null, int cell = -1) {
    import std.math : PI, cos, sin;
    V3[] v; uint[][] f;
    uvSphere(32, 16, v, f);
    loadMesh(v, f);
    if (afterLoad !is null) afterLoad();
    if (cell == -1) cmd("viewport.wireOverlay none");
    else if (cell == -2) {
        foreach (c; 0 .. 4)
            cmd(format(`{"id":"viewport.wireOverlay","params":{"_positional":["none"],"viewport":%d}}`, c));
    }
    else cmd(format(`{"id":"viewport.wireOverlay","params":{"_positional":["none"],"viewport":%d}}`, cell));
    if (cell == -2) setCamera(0, 0, 1.7, 0, 0.38, 0);   // a Quad cell is half the size: closer
    else setCamera(0, 0, 2.6);
    // Rings k = 1..15 sit at latitude 90 - 11.25k, so k = 6 is +22.5°.
    immutable int k = 6, segs = 32;
    uint at(int kk, int j) { return cast(uint)(1 + (kk - 1) * segs + (j % segs)); }
    // Faces above / below the edge (at(6,0)-at(6,1)) in the front band (j = 0).
    size_t up = size_t.max, dn = size_t.max;
    foreach (i, face; f) {
        import std.algorithm : canFind;
        if (face.length != 4 || !face.canFind(at(k, 0)) || !face.canFind(at(k, 1))) continue;
        if (face.canFind(at(k - 1, 0))) up = i; else dn = i;
    }
    assert(up != size_t.max && dn != size_t.max, "rig: the two faces across the edge were not found");
    immutable V3 a = v[at(k, 0)], b = v[at(k, 1)];
    immutable V3 mid = V3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2);
    immutable int[2] e = cellPx(mid);
    immutable int[2] top = cellPx(v[at(k - 1, 0)]), bot = cellPx(v[at(k + 1, 0)]);
    immutable double facePx = (abs(top[1] - e[1]) < abs(bot[1] - e[1]) ? abs(top[1] - e[1]) : abs(bot[1] - e[1]));
    assert(facePx >= 30, format("rig: the faces across the edge are only %.0f px tall", facePx));
    SphereRig r;
    r.pts = [[e[0], e[1] - 2], [e[0], e[1] + 2]];
    immutable V3 eye = liveEye();
    r.flatStep = abs(litLevel(faceNormal(v, f[up]), mid, eye) - litLevel(faceNormal(v, f[dn]), mid, eye));
    r.smoothStep = r.flatStep * 4.0 / facePx;
    // Discrimination floor: the two predictions are far apart.
    assert(r.flatStep - 2 > r.smoothStep + 2 + 6,
        format("rig: flat step %.2f vs smooth bound %.2f cannot discriminate", r.flatStep, r.smoothStep));
    return r;
}

// ---------------------------------------------------------------------------
// (i) smooth ON (the default): the step across a latitude edge is only the
// continuous stream's gradient. (ii) `viewport.smooth off`: the flat step.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("i")) return;
    auto rig = sphereRig();
    bool renders;
    auto on = probeR(0, rig.pts, renders);
    assert(renders, "(i) cell 0 must be rendering");
    immutable double dOn = abs(on[0] - on[1]);
    writefln("[smooth (i)] step %.0f (pixels %s), predicted smooth bound %.2f, flat %.2f",
             dOn, on, rig.smoothStep, rig.flatStep);
    assert(dOn <= rig.smoothStep + 2,
        format("(i) smooth ON: the step across the latitude edge is %.0f levels, the smooth "
             ~ "stream predicts <= %.2f (+2); the flat step would be %.2f", dOn, rig.smoothStep, rig.flatStep));
    cmd("viewport.smooth off");
    frameFence(null, 2);
    auto off = probeR(0, rig.pts, renders);
    immutable double dOff = abs(off[0] - off[1]);
    writefln("[smooth (ii)] step %.0f (pixels %s), predicted flat %.2f", dOff, off, rig.flatStep);
    assert(dOff >= rig.flatStep - 2,
        format("(ii) smooth OFF: the step is %.0f levels, the flat stream predicts %.2f (-2)",
               dOff, rig.flatStep));
    cmd("viewport.smooth on");
}

// ---------------------------------------------------------------------------
// (iii) a hinge at θ + 10 (θ = the 40° smoothing angle): the edge stays hard
// with smooth ON — the angle split.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("iii")) return;
    import std.math : PI, cos, sin;
    immutable double half = (40.0 + 10.0) / 2 * PI / 180;   // each face tilts by half the dihedral
    immutable float y0 = 0.5f;                               // off the grid's horizon row
    V3[] v = [V3(-1, y0, 0), V3(1, y0, 0),
              V3(1, cast(float)(y0 + cos(half)), cast(float)(-sin(half))),
              V3(-1, cast(float)(y0 + cos(half)), cast(float)(-sin(half))),
              V3(1, cast(float)(y0 - cos(half)), cast(float)(-sin(half))),
              V3(-1, cast(float)(y0 - cos(half)), cast(float)(-sin(half)))];
    uint[][] f = [[0u, 1, 2, 3], [5u, 4, 1, 0]];
    foreach (ref face; f) if (faceNormal(v, face).z < 0) { import std.algorithm : reverse; face.reverse(); }
    loadMesh(v, f);
    cmd("viewport.wireOverlay none");
    setCamera(0, 0, 4.0, 0, y0, 0);
    immutable double dih = acosDeg(dt(faceNormal(v, f[0]), faceNormal(v, f[1])));
    assert(abs(dih - 50.0) < 0.01, format("(iii) premise: the hinge dihedral is %.3f°, expected 50", dih));
    immutable int[2] e = cellPx(V3(0, y0, 0));
    int[2][] pts = [[e[0], e[1] - 3], [e[0], e[1] + 3]];
    immutable V3 eye = liveEye();
    immutable double flatStep = abs(litLevel(faceNormal(v, f[0]), V3(0, y0, 0), eye)
                                  - litLevel(faceNormal(v, f[1]), V3(0, y0, 0), eye));
    assert(flatStep >= 20, format("(iii) floor: the predicted flat step is only %.2f", flatStep));
    bool renders;
    auto px = probeR(0, pts, renders);
    immutable double d = abs(px[0] - px[1]);
    writefln("[smooth (iii)] hinge 50°: step %.0f (pixels %s), predicted flat %.2f", d, px, flatStep);
    assert(d >= flatStep - 2,
        format("(iii) a 50° hinge with smooth ON steps %.0f levels; above the smoothing angle "
             ~ "it must stay hard (%.2f predicted)", d, flatStep));
}

double acosDeg(double c) {
    import std.math : acos, PI;
    return acos(c > 1 ? 1 : c < -1 ? -1 : c) * 180 / PI;
}

// ---------------------------------------------------------------------------
// (iv) per cell: in a Quad layout the active cell's own `smooth` decides its
// pixels — another cell's toggle does not reach it.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("iv")) return;
    scope(exit) cmd("viewport.layout Single");
    int act = -1;
    auto rig = sphereRig({
        cmd("viewport.layout Quad");
        frameFence(null, 2);
        act = cast(int)getJson("/api/viewport/display")["activeId"].integer;
        cmd("viewport.view Perspective");
        // The cell's OWN camera: a Quad shares centre/scale/rotation by default.
        foreach (id; ["viewport.indCenter", "viewport.indScale", "viewport.indRotate"])
            cmd(format(`{"id":"%s","params":{"value":true}}`, id));
        cmd(format(`{"id":"viewport.displayStyle","params":{"_positional":["shaded"],"viewport":%d}}`, act));
    }, -2);
    immutable int other = act == 0 ? 1 : 0;
    auto disp = getJson("/api/viewport/display");
    // A: the active cell flat, the other smooth.
    cmd(format(`{"id":"viewport.smooth","params":{"_positional":["off"],"viewport":%d}}`, act));
    cmd(format(`{"id":"viewport.smooth","params":{"_positional":["on"],"viewport":%d}}`, other));
    frameFence(null, 2);
    disp = getJson("/api/viewport/display");
    foreach (c; disp["cells"].array)
        assert(c["renders"].type == JSONType.true_, "(iv) every Quad cell must be rendering");
    auto cells = disp["cells"].array;
    assert(cells[act]["plan"]["active"]["smoothNormals"].type == JSONType.false_
        && cells[other]["plan"]["active"]["smoothNormals"].type == JSONType.true_,
        "(iv) the plans do not follow the per-cell state: " ~ disp.toString);
    assert(cells[act]["state"]["active"]["smooth"].type == JSONType.false_
        && cells[other]["state"]["active"]["smooth"].type == JSONType.true_,
        "(iv) the reported state does not follow the per-cell write: " ~ disp.toString);
    bool renders;
    auto a = probeR(act, rig.pts, renders);
    assert(renders, "(iv) the active cell must be rendering");
    // B: swapped.
    cmd(format(`{"id":"viewport.smooth","params":{"_positional":["on"],"viewport":%d}}`, act));
    cmd(format(`{"id":"viewport.smooth","params":{"_positional":["off"],"viewport":%d}}`, other));
    frameFence(null, 2);
    auto b = probeR(act, rig.pts, renders);
    immutable double dA = abs(a[0] - a[1]), dB = abs(b[0] - b[1]);
    writefln("[smooth (iv)] cell %d: own off -> step %.0f, own on (cell %d off) -> step %.0f",
             act, dA, other, dB);
    assert(dA >= rig.flatStep - 2,
        format("(iv) cell %d set flat draws a %.0f-level step, expected the flat %.2f", act, dA, rig.flatStep));
    assert(dB <= rig.smoothStep + 2,
        format("(iv) cell %d set smooth draws a %.0f-level step while cell %d is flat — "
             ~ "another cell's toggle reached it (smooth bound %.2f)", act, dB, other, rig.smoothStep));
    cmd(format(`{"id":"viewport.smooth","params":{"_positional":["on"],"viewport":%d}}`, other));
}

// ---------------------------------------------------------------------------
// (v) non-uniform item scale: the normal goes through the inverse-transpose.
// A slanted quad (local normal (1,1,0)/√2), `scl.y 4`; its centre pixel must
// read the TRUE world normal, not `mat3(model)`'s. Calibration control first:
// the unscaled quad reads its own prediction.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("v")) return;
    import std.math : SQRT2;
    immutable float s = cast(float)(0.5 / SQRT2);
    // Centred off the origin: the ground grid's axis lines cross there.
    immutable V3 c = V3(0.3f, 0.6f, 0.2f);
    V3[] v = [V3(c.x - s, c.y + s, c.z - 0.5f), V3(c.x + s, c.y - s, c.z - 0.5f),
              V3(c.x + s, c.y - s, c.z + 0.5f), V3(c.x - s, c.y + s, c.z + 0.5f)];
    uint[][] f = [[0u, 1, 2, 3]];
    if (faceNormal(v, f[0]).x < 0) { import std.algorithm : reverse; f[0].reverse(); }
    loadMesh(v, f);
    cmd("viewport.wireOverlay none");
    setCamera(0.9, 0.35, 3.0, c.x, c.y, c.z);
    V3 eye = liveEye();
    // Control: unscaled, the predicted level of the local normal.
    immutable V3 n0 = faceNormal(v, f[0]);
    assert(dt(n0, sub(eye, c)) > 0, "(v) rig: the quad faces away from the camera");
    bool renders;
    immutable double want0 = litLevel(n0, c, eye);
    auto p0 = probeR(0, [cellPx(c)], renders);
    writefln("[smooth (v)] control: unscaled centre %d, predicted %.2f", p0[0], want0);
    assert(abs(p0[0] - want0) <= 2,
        format("(v) control: the unscaled quad reads %d, the light function predicts %.2f — "
             ~ "the prediction itself is off, the scale cell cannot judge", p0[0], want0));
    cmd("layer.attr 0 scl.y 4");
    // The item scales about the origin: the centre moves to y * 4.
    immutable V3 cw = V3(c.x, c.y * 4, c.z);
    setCamera(0.9, 0.35, 3.0, cw.x, cw.y, cw.z);
    eye = liveEye();
    V3[] w;
    foreach (x; v) w ~= V3(x.x, x.y * 4, x.z);
    immutable V3 nTrue = faceNormal(w, f[0]);
    immutable V3 nMat3 = unit(V3(n0.x, n0.y * 4, n0.z));
    immutable double want = litLevel(nTrue, cw, eye), wrong = litLevel(nMat3, cw, eye);
    // Discrimination floor first.
    assert(abs(want - wrong) >= 10,
        format("(v) floor: the true-normal (%.2f) and mat3(model) (%.2f) predictions are "
             ~ "under 10 levels apart", want, wrong));
    auto p = probeR(0, [cellPx(cw)], renders);
    writefln("[smooth (v)] scl.y 4: centre %d, true normal %.2f, mat3(model) %.2f", p[0], want, wrong);
    assert(abs(p[0] - want) <= 2,
        format("(v) scl.y 4: the centre reads %d; the inverse-transpose normal predicts %.2f, "
             ~ "mat3(model) %.2f", p[0], want, wrong));
}

// ---------------------------------------------------------------------------
// (vii) a prepared upload (the Edge Bevel `tool.attr` parameter door, through
// `GpuUploadOwner`) then a vertex drag on the refresh path: the smooth stream
// written mid-drag equals the one a full rebuild writes at the same positions.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("vii")) return;
    V3[] v; uint[][] f;
    uvSphere(32, 16, v, f);
    loadMesh(v, f);
    setCamera(0, 0.3, 4.0);
    // The prepared param update: select one edge, arm the bevel, edit width.
    select("edges", [40]);
    cmd("tool.set edge.bevel on");
    cmd("tool.attr edge.bevel width 0.05");
    frameFence(null, 2);
    cmd("tool.doApply");
    cmd("tool.set edge.bevel off");
    frameFence(null, 2);
    // Premise: the bevel applied (the layout the drag refreshes is a new one).
    immutable size_t facesAfter = getJson("/api/model")["faces"].array.length;
    assert(facesAfter > f.length,
        format("(vii) premise: the edge bevel left %d faces (sphere %d) — it did not apply", facesAfter, f.length));
    // A vertex move drag on a front vertex (not the pole: the gizmo).
    select("vertices", [cast(int)(1 + 5 * 32)]);
    cmd("tool.set move");
    frameFence(null, 2);
    double hx, hy;
    bool found;
    fetchHandlePart(0, hx, hy, found);
    assert(found, "(vii) gizmo part 0 missing");
    auto cam = fetchCamera();
    immutable int x0 = cast(int)(hx + 0.5), y0 = cast(int)(hy + 0.5);
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0));
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0, x0 + 40, y0, 6));
    immutable string writer = getJson("/api/subpatch/preview")["displayWriter"].str;
    assert(writer == "selectedVertexUpload" || writer == "positionRefresh",
        "(vii) path control: the mid-drag writer is " ~ writer ~ ", not a refresh path");
    auto mid = getJson("/api/gpu/face-vbo?normals=1");
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height, x0 + 40, y0));
    cmd("tool.set move off");
    // Force a full rebuild: hide + unhide one face far from the drag.
    select("polygons", [cast(int)(f.length - 1)]);
    cmd(`{"id":"mesh.hide"}`);
    cmd(`{"id":"mesh.unhideAll"}`);
    frameFence(null, 2);
    auto full = getJson("/api/gpu/face-vbo?normals=1");
    immutable size_t n = cast(size_t)mid["faceVertCount"].integer;
    // Population floor first.
    assert(n > 0 && mid["smoothNormals"].array.length == n && full["smoothNormals"].array.length == n
        && mid["flatNormals"].array.length == n,
        format("(vii) floor: faceVertCount %d, smoothNormals %d / %d", n,
               mid["smoothNormals"].array.length, full["smoothNormals"].array.length));
    size_t moved;
    foreach (i; 0 .. n) {
        immutable double[3] pm = triple(mid["positions"].array[i]), pf = triple(full["positions"].array[i]);
        assert(near3(pm, pf, 1e-5), format("(vii) premise: corner %d position %s mid-drag vs %s rebuilt", i, pm, pf));
    }
    foreach (i; 0 .. n) {
        immutable double[3] sm = triple(mid["smoothNormals"].array[i]), sf = triple(full["smoothNormals"].array[i]);
        assert(near3(sm, sf, 1e-5),
            format("(vii) corner %d: smooth normal %s written mid-drag, %s by a full rebuild — the "
                 ~ "refresh path smoothed with an adjacency from another layout", i, sm, sf));
        if (!near3(sm, triple(mid["flatNormals"].array[i]), 1e-4)) ++moved;
    }
    assert(moved > n / 2, format("(vii) floor: only %d of %d corners are smooth != flat", moved, n));
    writefln("[smooth (vii)] %d corners agree mid-drag vs rebuilt (%d smooth != flat)", n, moved);
}

// ---------------------------------------------------------------------------
// (vi) The selected-vertex upload path draws the DRAWN (morphed) positions,
// faces AND edges. Rig: a routed morph drag (tests/test_morph_drag_undo.d's
// first cell) — the drag edits the morph, so `mesh.vertices` stays at the base
// while the drawn positions move. The vertex VBO already reads the drawn
// positions; before S1a the face fan and the edge walk of
// `GpuMesh.uploadSelectedVertices` read the base.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("vi")) return;
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed: " ~ rr.toString);
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    select("vertices", [6]);
    cmd("tool.set move");
    Thread.sleep(200.msecs);

    // Fan corners at vertex 6, computed from the cube's faces (fan around
    // face[0]: triangles (f0, fi, fi+1)).
    auto model = getJson("/api/model");
    size_t expectFanCorners;
    foreach (f; model["faces"].array) {
        auto fv = f.array;
        foreach (i; 1 .. fv.length - 1) {
            if (fv[0].integer == 6) ++expectFanCorners;
            if (fv[i].integer == 6) ++expectFanCorners;
            if (fv[i + 1].integer == 6) ++expectFanCorners;
        }
    }
    immutable double[3] base = triple(model["vertices"].array[6]);

    auto pre = getJson("/api/gpu/face-vbo");
    size_t[] faceIdx, edgeIdx;
    foreach (i, p; pre["positions"].array)
        if (near3(triple(p), base, 1e-5)) faceIdx ~= i;
    foreach (i, p; pre["edgePositions"].array)
        if (near3(triple(p), base, 1e-5)) edgeIdx ~= i;
    // Floors: the cube's vertex 6 sits on 3 quads and 3 edges.
    assert(expectFanCorners > 0 && faceIdx.length == expectFanCorners,
        format("(vi) floor: %d face-VBO corners at vertex 6, the faces predict %d",
               faceIdx.length, expectFanCorners));
    assert(edgeIdx.length == 3,
        format("(vi) floor: %d edge-VBO endpoints at vertex 6, expected 3", edgeIdx.length));

    double hx, hy;
    bool found;
    fetchHandlePart(0, hx, hy, found);
    assert(found, "(vi) gizmo part 0 (first arm) missing");
    auto c = fetchCamera();
    immutable int x0 = cast(int)(hx + 0.5), y0 = cast(int)(hy + 0.5);
    playAndWait(buildDragDownLog(c.vpX, c.vpY, c.width, c.height, x0, y0));
    playAndWait(buildDragMotionLog(c.vpX, c.vpY, c.width, c.height,
                                   x0, y0, x0 + 60, y0, 8));

    // Path control FIRST: the selected-vertex upload is the recorded writer,
    // or this cell cannot witness that path.
    auto st = getJson("/api/subpatch/preview");
    if (st["displayWriter"].str != "selectedVertexUpload")
        assert(false, "selected-vertex path never ran: cell cannot witness (writer="
                      ~ st["displayWriter"].str ~ ")");
    auto mid = getJson("/api/gpu/face-vbo");
    immutable double[3] drawn = triple(mid["vertPositions"].array[6]);
    // Premise: the drawn vertex moved off the base.
    assert(dist3(drawn, base) >= 0.1,
        format("(vi) premise: the drawn vertex 6 moved only %.4f from the base",
               dist3(drawn, base)));
    auto mpos = mid["positions"].array;
    auto epos = mid["edgePositions"].array;
    foreach (i; faceIdx)
        assert(near3(triple(mpos[i]), drawn, 1e-5),
            format("(vi) face corner %d draws (%s) mid-drag, the drawn vertex is %s — "
                 ~ "the selected-vertex face fan went back to base positions",
                   i, triple(mpos[i]), drawn));
    foreach (i; edgeIdx)
        assert(near3(triple(epos[i]), drawn, 1e-5),
            format("(vi) edge endpoint %d draws (%s) mid-drag, the drawn vertex is %s — "
                 ~ "the selected-vertex edge walk went back to base positions",
                   i, triple(epos[i]), drawn));

    playAndWait(buildDragUpLog(c.vpX, c.vpY, c.width, c.height, x0 + 60, y0));
    writefln("[smooth (vi)] %d face corners + %d edge endpoints follow the drawn vertex",
             faceIdx.length, edgeIdx.length);
}

// ---------------------------------------------------------------------------
// (viii) `viewport.smooth` slot 1 writes the BACKDROP slot (read by a `Flat`
// backdrop's plan), and a slot outside 0|1 is refused.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("viii")) return;
    auto rr = postJson("/api/command", commandBody("scene.reset"));
    assert(rr["status"].str == "ok", "scene.reset failed");
    cmd(`{"id":"viewport.backdropStyle","params":{"_positional":["flat"]}}`);
    cmd(`{"id":"viewport.smooth","params":{"_positional":["off"],"slot":1}}`);
    auto c0 = getJson("/api/viewport/display")["cells"].array[0];
    assert(c0["state"]["backdrop"]["smooth"].type == JSONType.false_
        && c0["state"]["active"]["smooth"].type == JSONType.true_,
        "(viii) slot 1 must write the backdrop slot only: " ~ c0.toString);
    assert(c0["plan"]["backdrop"]["smoothNormals"].type == JSONType.false_
        && c0["plan"]["active"]["smoothNormals"].type == JSONType.true_,
        "(viii) a Flat backdrop's plan must read the backdrop slot: " ~ c0.toString);
    auto bad = postJson("/api/command", `{"id":"viewport.smooth","params":{"_positional":["off"],"slot":2}}`);
    assert(bad["status"].str == "error", "(viii) slot 2 must be refused: " ~ bad.toString);
    cmd(`{"id":"viewport.smooth","params":{"_positional":["on"],"slot":1}}`);
    cmd(`{"id":"viewport.backdropStyle","params":{"_positional":["same"]}}`);
}
