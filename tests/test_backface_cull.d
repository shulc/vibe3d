// Back-face culling + double-sided surfaces (viewport shading S1d, model M6;
// captures C5/C7 incl. C7l). A lit face pass culls the back faces of a
// single-sided surface; a double-sided surface draws its back side, lit with
// the flipped normal; the unlit fills (Solid, Weight) never cull; the
// retopology mode hard-culls the FOREGROUND only; a shaded backdrop culls by
// surface, also under the mode; a mirrored item culls the outward side of the
// DRAWN surface. Picking is unchanged (P1–P4 are green before and after S1d).
//
// Rig (never a cube: facing and occlusion coincide on a closed solid): ONE
// mesh of open quads, orthographic Front view (eye on +Z, the view rotation is
// the identity — asserted), every quad laterally apart from the others:
//   F0 (s0, eye normal (−0.6,0,0.8), facing)   B0 (s0, the same quad reversed)
//   F1 / B1 (the same pair on s1)
//   Ft (s0, facing, z = −1) with Bo (s0, reversed, z = +1) over Ft's corner.
// s0 is single-sided (Kd 0.7), s1 double-sided (Kd 0.3); no specular. Every
// prediction is computed here from the S1b light rig (an in-test copy).
// `VIBE3D_CELL=<id>` runs one cell.
module test_backface_cull;

import http_client : getJson, postJson, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow, playAndWait,
                      Viewport, DHVec3 = Vec3;

import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, sqrt;
import std.stdio : writefln;

void main() {}

bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

JSONValue cmdRaw(string body_) { return postJson("/api/command", body_); }
void cmd(string body_) {
    auto r = cmdRaw(body_);
    assert(r["status"].str == "ok", "/api/command failed for " ~ body_ ~ ": " ~ r.toString);
}
void settle() { frameFence(null, 2); }

string attrBody(int surface, string attr, int value) {
    return format(`{"id":"mesh.surfaceAttr","params":{"surface":%d,"attr":"%s","value":%d}}`,
                  surface, attr, value);
}
size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

// ---------------------------------------------------------------------------
// The light rig (S1b), in doubles: Kd·(0.15 + 0.7·max(N·key,0) + 0.3·max(N·fill,0)),
// no specular (the rig's surfaces carry specular 0).
// ---------------------------------------------------------------------------
alias D3 = double[3];
D3 nrm(D3 v) { immutable l = sqrt(v[0]^^2 + v[1]^^2 + v[2]^^2); return [v[0]/l, v[1]/l, v[2]/l]; }
double dot3(D3 a, D3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
immutable D3 kKey  = [-0.654509, 0.587785, 0.475528];
immutable D3 kFill = [1.0, 0.0, 0.0];
double lit(double kd, D3 n) {
    immutable N = nrm(n);
    immutable double nk = dot3(N, kKey), nf = dot3(N, kFill);
    double c = kd * (0.15 + 0.7 * (nk > 0 ? nk : 0) + 0.3 * (nf > 0 ? nf : 0));
    return 255.0 * (c > 1 ? 1 : c);
}
enum double kKd0 = 0.7, kKd1 = 0.3;
immutable D3 nF = [-0.6, 0.0, 0.8];     // the facing quads' eye normal
immutable D3 nB = [0.6, 0.0, -0.8];     // the reversed quads' (raw) eye normal

// ---------------------------------------------------------------------------
// Geometry.
// ---------------------------------------------------------------------------
enum double kH = 0.3;                   // quad half-size
struct Quad { string name; D3 c; D3 n; uint surf; }
// Quad centres are lifted off the grid line (y = 0 in the Front view).
immutable Quad[] kQuads = [
    Quad("F0", [-1.8, 2.0,  0.0], [-0.6, 0.0,  0.8], 0),
    Quad("B0", [-0.9, 2.0,  0.0], [ 0.6, 0.0, -0.8], 0),
    Quad("F1", [ 0.9, 2.0,  0.0], [-0.6, 0.0,  0.8], 1),
    Quad("B1", [ 1.8, 2.0,  0.0], [ 0.6, 0.0, -0.8], 1),
    Quad("Ft", [ 0.0, 1.0, -1.0], [ 0.0, 0.0,  1.0], 0),
    Quad("Bo", [ 0.3, 1.3, 1.0], [ 0.0, 0.0, -1.0], 0),   // centred on Ft's corner
];
enum { iF0, iB0, iF1, iB1, iFt, iBo }
immutable D3 kBgPt = [0.0, 2.0, 0.0];   // empty: between B0 and F1

/// The quad's four corners, wound so that its geometric normal is `q.n`
/// (counter-clockwise seen from the side `n` points to).
D3[4] corners(const Quad q) {
    // u ⟂ n in the plane spanned with Y (every rig normal is ⟂ Y).
    D3 v = [0.0, 1.0, 0.0];
    D3 u = nrm([v[1]*q.n[2] - v[2]*q.n[1], v[2]*q.n[0] - v[0]*q.n[2], v[0]*q.n[1] - v[1]*q.n[0]]);
    D3 at(double a, double b) {
        return [q.c[0] + kH*(a*u[0] + b*v[0]), q.c[1] + kH*(a*u[1] + b*v[1]), q.c[2] + kH*(a*u[2] + b*v[2])];
    }
    return [at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)];
}

/// The rig mesh JSON (vertices, faces, surfaces, faceMaterial).
/// `b0Tag`: B0's `faceMaterial` (its surface s0 when 0; a stale tag past the
/// slot table renders slot 0).
string rigMeshJson(bool s1Double, uint b0Tag = 0) {
    string vs, fs, ms;
    foreach (i, q; kQuads) {
        foreach (j, p; corners(q))
            vs ~= format("%s[%.9g,%.9g,%.9g]", (i || j) ? "," : "", p[0], p[1], p[2]);
        fs ~= format("%s[%d,%d,%d,%d]", i ? "," : "", 4*i, 4*i + 1, 4*i + 2, 4*i + 3);
        ms ~= format("%s%d", i ? "," : "", i == iB0 && b0Tag ? b0Tag : q.surf);
    }
    string surf(string name, double kd, bool dbl) {
        return format(`{"name":"%s","baseColor":[%.9g,%.9g,%.9g],"diffuse":1,"specular":0,`
            ~ `"glossiness":0.4,"opacity":1,"twoSided":%s}`, name, kd, kd, kd, dbl ? "true" : "false");
    }
    return `{"vertices":[` ~ vs ~ `],"faces":[` ~ fs ~ `],"surfaces":[` ~ surf("s0", kKd0, false)
        ~ "," ~ surf("s1", kKd1, s1Double) ~ `],"faceMaterial":[` ~ ms ~ `]}`;
}

private int g_rig = 0;

/// Load the rig. `asBackdrop`: the rig is layer 0 (a visible background
/// layer) and the primary is layer 1, one tiny triangle far off-screen.
Viewport loadRig(bool asBackdrop = false, bool s1Double = true, uint b0Tag = 0) {
    import std.file : write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID, environment;
    immutable dir = environment.get("TMPDIR", "/var/tmp");
    immutable path = buildPath(dir, format("vibe3d-s1d-rig-%d-%d.v3d", thisProcessID(), g_rig++));
    string layers = `{"type":"mesh","selected":` ~ (asBackdrop ? "false" : "true")
        ~ `,"channels":{"name":"Rig","visible":true},"mesh":` ~ rigMeshJson(s1Double, b0Tag) ~ `}`;
    if (asBackdrop)
        layers ~= `,{"type":"mesh","selected":true,"channels":{"name":"Far","visible":true},"mesh":`
            ~ `{"vertices":[[90,90,0],[90.1,90,0],[90,90.1,0]],"faces":[[0,1,2]]}}`;
    write(path, format(`{"formatVersion":8,"primaryLayer":%d,"focusedItem":%d,"layers":[%s]}`,
                       asBackdrop ? 1 : 0, asBackdrop ? 1 : 0, layers));
    scope(exit) if (exists(path)) remove(path);
    cmd(commandBody("scene.reset"));
    cmd(`{"id":"history.clear"}`);
    cmd(commandBody("viewport.layout", `"Single"`));
    cmd(format(`{"id":"file.load","params":{"path":%s}}`, JSONValue(path).toString));
    auto L = getJson("/api/layers");
    assert(L["layers"].array.length == (asBackdrop ? 2 : 1) && L["active"].integer == (asBackdrop ? 1 : 0),
        "rig: unexpected layer table: " ~ L.toString);
    auto m = getJson(asBackdrop ? "/api/model?layer=0" : "/api/model");
    assert(m["faces"].array.length == kQuads.length && m["surfaces"].array.length == 2,
        "rig: the loaded mesh does not carry the rig: " ~ m.toString);
    // The key is absent only on a pre-S1d binary (the merge-base run of cell
    // "lit", whose (ii) must be red there for its own reason).
    if ("twoSided" in m["surfaces"].array[1])
        assert((m["surfaces"].array[1]["twoSided"].type == JSONType.true_) == s1Double
            && m["surfaces"].array[0]["twoSided"].type == JSONType.false_,
            "rig: the surfaces' twoSided flags did not load: " ~ m["surfaces"].toString);
    cmd(commandBody("viewport.displayStyle", `{"value":"shaded"}`));
    cmd(commandBody("viewport.wireOverlay", `{"value":"none"}`));
    cmd(commandBody("viewport.backdropStyle", `{"value":"same"}`));
    cmd("select.typeFrom polygon");
    // The work plane pinned to the ground: the AUTO grid of a Front view faces
    // it (task 9451) and its lattice would cross the probes' clear background.
    cmd("tool.pipe.attr workplane mode worldY");
    cmd("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0", `{"focus":{"x":0,"y":1.6,"z":0},"distance":5}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    // The view rotation is the identity: world normals are eye normals.
    foreach (r; 0 .. 3) foreach (c; 0 .. 3)
        assert(abs(vp.view[c * 4 + r] - (r == c ? 1 : 0)) < 1e-5,
            format("rig: the Front view's rotation is not the identity: %s", vp.view));
    return vp;
}

// ---------------------------------------------------------------------------
// Probes.
// ---------------------------------------------------------------------------
int[2] px(const ref Viewport vp, D3 w) {
    float x, y;
    assert(projectToWindow(DHVec3(cast(float)w[0], cast(float)w[1], cast(float)w[2]), vp, x, y),
        format("rig: %s projects behind the camera", w));
    return [cast(int)(x + 0.5f) - vp.x, cast(int)(y + 0.5f) - vp.y];
}
int[2] winPx(const ref Viewport vp, D3 w) {
    int[2] p = px(vp, w);
    return [p[0] + vp.x, p[1] + vp.y];
}

int[3][] probeRGB(int[2][] pts) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
    assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
    int[3][] o;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        o ~= [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
    }
    assert(o.length == pts.length, "probe: point count");
    return o;
}

/// The mean RGB of the 5×5 window (2 px pitch) around world point `w`. Floor
/// first: 25 classified samples, all within 2 levels of each other (one
/// surface, no edge inside the window).
double[3] win(const ref Viewport vp, D3 w, string what) {
    immutable c = px(vp, w);
    int[2][] pts;
    foreach (dy; -2 .. 3) foreach (dx; -2 .. 3) pts ~= [c[0] + 2*dx, c[1] + 2*dy];
    auto s = probeRGB(pts);
    assert(s.length == 25, format("%s: window holds %d samples, expected 25", what, s.length));
    double[3] m = 0;
    foreach (p; s) foreach (k; 0 .. 3) m[k] += p[k] / 25.0;
    foreach (p; s) foreach (k; 0 .. 3)
        assert(abs(p[k] - m[k]) <= 2, format("%s: window at %s is not one surface: %s", what, c, s));
    return m;
}

double gap(double[3] a, double[3] b) {
    double g = 0;
    foreach (k; 0 .. 3) if (abs(a[k] - b[k]) > g) g = abs(a[k] - b[k]);
    return g;
}
double gapGrey(double[3] a, double v) { return gap(a, [v, v, v]); }

/// Read every quad's window and the background.
struct Reads { double[3][6] q; double[3] bg; }
Reads readAll(const ref Viewport vp, string cell) {
    Reads r;
    r.bg = win(vp, kBgPt, cell ~ " background");
    foreach (i, q; kQuads) if (i < iFt) r.q[i] = win(vp, q.c, cell ~ " " ~ q.name);
    writefln("[s1d %s] bg %s F0 %s B0 %s F1 %s B1 %s", cell, r.bg, r.q[iF0], r.q[iB0], r.q[iF1], r.q[iB1]);
    return r;
}

void isBg(double[3] v, double[3] bg, string what) {
    assert(gap(v, bg) <= 1, format("%s reads %s, expected the background %s ±1", what, v, bg));
}
void isDrawn(double[3] v, double[3] bg, string what) {
    assert(gap(v, bg) >= 6, format("%s reads %s, the background %s: expected a drawn surface (≥ 6)", what, v, bg));
}
void isGrey(double[3] v, double pred, double tol, string what) {
    assert(gapGrey(v, pred) <= tol, format("%s reads %s, predicted %.2f ±%s", what, v, pred, tol));
}

// ---------------------------------------------------------------------------
// D1 (i)–(iii): the front control, the culled single-sided back face, the
// double-sided back face lit with the flipped normal.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("lit")) return;
    auto vp = loadRig();
    immutable double pF0 = lit(kKd0, nF), pF1 = lit(kKd1, nF);
    immutable double raw1 = lit(kKd1, nB), amb1 = 255.0 * kKd1 * 0.15;
    // Discrimination floor: the candidates at B1 (flipped = F1, raw, ambient)
    // are ≥ 6 apart.
    assert(abs(pF1 - raw1) >= 6 && abs(pF1 - amb1) >= 6 && abs(raw1 - amb1) >= 6,
        format("floor: B1's candidates flipped %.2f raw %.2f ambient %.2f", pF1, raw1, amb1));
    auto r = readAll(vp, "lit");
    assert(gapGrey(r.bg, pF0) >= 6 && gapGrey(r.bg, pF1) >= 6,
        format("floor: the background %s is within 6 of a prediction (%.2f / %.2f)", r.bg, pF0, pF1));
    // (i) positive control for (ii): F0 is lit from the rig.
    isGrey(r.q[iF0], pF0, 2, "(i) F0 (front control)");
    // (ii) the single-sided back face is culled — red on the pre-S1d binary.
    isBg(r.q[iB0], r.bg, "(ii) B0 (single-sided back face)");
    // (iii) the double-sided back face: two-sided lighting, not raw.
    isGrey(r.q[iF1], pF1, 2, "(iii) F1");
    assert(gap(r.q[iB1], r.q[iF1]) <= 2,
        format("(iii) B1 reads %s, F1 %s: a double-sided back face is lit with the flipped normal", r.q[iB1], r.q[iF1]));
    assert(gapGrey(r.q[iB1], raw1) >= 6, format("(iii) B1 %s is lit with the RAW normal (%.2f)", r.q[iB1], raw1));
}

// ---------------------------------------------------------------------------
// D1 (iii-b): a STALE tag (≥ kSurfaceSlots = 64) reads slot 0 in the VERTEX
// stage too — the drop indexes `mat_flags[surfaceSlotOf(aMatId)]`, as the
// fragment stage and `mesh.effectiveSurfaceSlot` do. B0 is tagged 100; with s0
// double-sided B0's back side is drawn, lit like F0. Red when the drop indexes
// `mat_flags[aMatId]` (past the array: the flag reads 0 and B0 is dropped).
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("stale")) return;
    auto vp = loadRig(false, true, 100);
    auto fm = getJson("/api/model")["faceMaterial"].array;
    assert(fm.length == kQuads.length && fm[iB0].integer == 100 && fm[iF0].integer == 0,
        "(iii-b) premise: B0 must load with the stale tag 100: " ~ getJson("/api/model")["faceMaterial"].toString);
    immutable double pF0 = lit(kKd0, nF), raw0 = lit(kKd0, nB);
    assert(abs(pF0 - raw0) >= 6, format("(iii-b) floor: flipped %.2f and raw %.2f are < 6 apart", pF0, raw0));
    immutable r0 = readAll(vp, "stale-single");
    isBg(r0.q[iB0], r0.bg, "(iii-b) premise: B0 (tag 100 → slot 0, single-sided) culled");
    cmd(attrBody(0, "twoSided", 1));
    settle();
    auto r = readAll(vp, "stale-double");
    isGrey(r.q[iF0], pF0, 2, "(iii-b) F0 (front control)");
    isDrawn(r.q[iB0], r.bg, "(iii-b) B0 (tag 100, slot 0 double-sided): the vertex drop must read slot 0");
    assert(gap(r.q[iB0], r.q[iF0]) <= 2,
        format("(iii-b) B0 reads %s, F0 %s: the stale-tag back face is lit with slot 0's flipped normal", r.q[iB0], r.q[iF0]));
}

// ---------------------------------------------------------------------------
// D1 (iv): the second submission is the path — face vertices 2·N with a
// double-sided slot, N without.
// ---------------------------------------------------------------------------
long expectedFaceVerts(JSONValue model) {
    long n = 0;
    foreach (f; model["faces"].array) if (f.array.length >= 3) n += (f.array.length - 2) * 3;
    return n;
}
long faceVerts() { return getJson("/api/frames/counts")["lastScene"]["pass"]["faces"]["verts"].integer; }

unittest {
    if (!cellOn("count")) return;
    auto vp = loadRig();
    immutable long N = expectedFaceVerts(getJson("/api/model"));
    assert(N == 36, format("(iv) floor: the rig has %d face vertices, expected 36 (6 quads)", N));
    assert(faceVerts() == 2 * N, format("(iv) with s1 double-sided the face pass submitted %d, expected 2·N = %d",
                                        faceVerts(), 2 * N));
    cmd(attrBody(1, "twoSided", 0));
    settle();
    assert(faceVerts() == N, format("(iv) with no double-sided slot the face pass submitted %d, expected N = %d",
                                    faceVerts(), N));
    auto r = readAll(vp, "count");
    isBg(r.q[iB1], r.bg, "(iv) B1 after s1 turned single-sided");
}

// ---------------------------------------------------------------------------
// D1 (v): overlays are not culled.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("overlay")) return;
    auto vp = loadRig();
    auto r = readAll(vp, "overlay");
    isBg(r.q[iB0], r.bg, "(v) premise: B0 culled");
    immutable D3 b0Top = [kQuads[iB0].c[0], kQuads[iB0].c[1] + kH, kQuads[iB0].c[2]];
    int[2] P = px(vp, b0Top);
    cmd(commandBody("viewport.wireOverlay", `{"value":"uniform"}`));
    settle();
    {
        auto s = probeRGB([[P[0], P[1] - 1], P, [P[0], P[1] + 1]]);
        double best = 0;
        foreach (p; s) { double[3] d = [p[0], p[1], p[2]]; if (gap(d, r.bg) > best) best = gap(d, r.bg); }
        assert(best >= 6, format("(v) B0's top edge %s reads %s: the wire overlay of a culled face must be drawn", P, s));
    }
    cmd(commandBody("viewport.wireOverlay", `{"value":"none"}`));
    cmd("select.typeFrom vertex");
    settle();
    {
        immutable D3 corner = corners(kQuads[iB0])[0];
        int[2] C = px(vp, corner);
        auto s = probeRGB([C]);
        double[3] d = [s[0][0], s[0][1], s[0][2]];
        assert(gap(d, r.bg) >= 6, format("(v) B0's corner dot %s reads %s: a culled face's vertex dots must be drawn", C, d));
    }
}

// ---------------------------------------------------------------------------
// D1 (vi): the unlit styles never cull (C7a Solid, C7b Weight); Wireframe
// draws edges only.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("styles")) return;
    auto vp = loadRig();
    immutable bg = readAll(vp, "styles-shaded").bg;
    foreach (style; ["solid", "weight"]) {
        cmd(commandBody("viewport.displayStyle", `{"value":"` ~ style ~ `"}`));
        settle();
        auto p = getJson("/api/viewport/display")["cells"].array[0]["plan"]["active"];
        assert(p["cullBySurface"].type == JSONType.false_, style ~ ": the plan must not cull: " ~ p.toString);
        auto r = readAll(vp, style);
        isDrawn(r.q[iF0], bg, "(vi) " ~ style ~ " F0");
        assert(gap(r.q[iB0], r.q[iF0]) <= 1,
            format("(vi) %s: B0 %s must read the unlit fill of F0 %s (never culled)", style, r.q[iB0], r.q[iF0]));
    }
    cmd(commandBody("viewport.displayStyle", `{"value":"wireframe"}`));
    settle();
    auto r = readAll(vp, "wireframe");
    isBg(r.q[iB0], bg, "(vi) wireframe B0 interior");
    immutable D3 b0Top = [kQuads[iB0].c[0], kQuads[iB0].c[1] + kH, kQuads[iB0].c[2]];
    int[2] P = px(vp, b0Top);
    auto s = probeRGB([[P[0], P[1] - 1], P, [P[0], P[1] + 1]]);
    double best = 0;
    foreach (p; s) { double[3] d = [p[0], p[1], p[2]]; if (gap(d, bg) > best) best = gap(d, bg); }
    assert(best >= 6, format("(vi) wireframe: B0's top edge reads %s, expected an edge", s));
    cmd(commandBody("viewport.displayStyle", `{"value":"shaded"}`));
}

// ---------------------------------------------------------------------------
// D1 (vii): a mirrored item culls the outward side of the DRAWN surface
// (captured C7f): the same quad as at scale +1.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("mirror")) return;
    auto vp = loadRig();
    cmd("layer.attr 0 scl.x -1");
    settle();
    // x → −x: F0 now sits at x = +1.8, B0 at +0.9.
    immutable D3 f0 = [-kQuads[iF0].c[0], kQuads[iF0].c[1], kQuads[iF0].c[2]];
    immutable D3 b0 = [-kQuads[iB0].c[0], kQuads[iB0].c[1], kQuads[iB0].c[2]];
    immutable bg = win(vp, kBgPt, "mirror background");
    immutable vF = win(vp, f0, "mirror F0"), vB = win(vp, b0, "mirror B0");
    writefln("[s1d mirror] bg %s F0 %s B0 %s", bg, vF, vB);
    isDrawn(vF, bg, "(vii) mirrored F0 (outward side kept)");
    // Its drawn side is lit with the mirrored outward normal (0.6, 0, 0.8).
    isGrey(vF, lit(kKd0, [0.6, 0.0, 0.8]), 2, "(vii) mirrored F0");
    isBg(vB, bg, "(vii) mirrored B0 (the same quad culled as at scale +1)");
}

// ---------------------------------------------------------------------------
// D1 (viii): retopology hard-culls the foreground (C7g); (ix) subpatch.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("retopo")) return;
    auto vp = loadRig();
    immutable bg = readAll(vp, "retopo-off").bg;
    cmd(commandBody("viewport.retopology", `{"value":"on"}`));
    scope(exit) cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
    settle();
    auto p = getJson("/api/viewport/display")["cells"].array[0]["plan"]["active"];
    assert(p["cullBackFaces"].type == JSONType.true_ && p["cullBySurface"].type == JSONType.false_,
        "(viii) premise: the mode's active plan hard-culls and does not cull by surface: " ~ p.toString);
    immutable vB1 = win(vp, kQuads[iB1].c, "retopo B1"), vF1 = win(vp, kQuads[iF1].c, "retopo F1");
    isDrawn(vF1, bg, "(viii) F1 under the mode (translucent fill)");
    isBg(vB1, bg, "(viii) B1 (double-sided) under the mode: the hard cull wins (C7g)");
}

unittest {
    if (!cellOn("subpatch")) return;
    auto vp = loadRig();
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    settle();
    auto r = readAll(vp, "subpatch");
    isDrawn(r.q[iF0], r.bg, "(ix) subpatch F0");
    isBg(r.q[iB0], r.bg, "(ix) subpatch B0");
    assert(gap(r.q[iB1], r.q[iF1]) <= 2, format("(ix) subpatch B1 %s vs F1 %s", r.q[iB1], r.q[iF1]));
    isDrawn(r.q[iB1], r.bg, "(ix) subpatch B1");
}

// ---------------------------------------------------------------------------
// D1 (x) a shaded backdrop culls by surface (C7e); (viii-b) also under the
// retopology mode (C7l); a wire backdrop draws no faces.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("backdrop")) return;
    auto vp = loadRig(true);
    scope(exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
    }
    int rows = 0;
    foreach (retopo; ["off", "on"]) {
        cmd(commandBody("viewport.retopology", `{"value":"` ~ retopo ~ `"}`));
        foreach (bs; ["flat", "same"]) {
            cmd(commandBody("viewport.backdropStyle", `{"value":"` ~ bs ~ `"}`));
            settle();
            auto p = getJson("/api/viewport/display")["cells"].array[0]["plan"]["backdrop"];
            assert(p["cullBySurface"].type == JSONType.true_,
                format("(x) premise: retopology %s, backdrop %s: the backdrop plan culls by surface: %s", retopo, bs, p));
            immutable cell = format("backdrop %s/retopology %s", bs, retopo);
            auto r = readAll(vp, cell);
            isDrawn(r.q[iF0], r.bg, "(x) " ~ cell ~ " F0");
            isBg(r.q[iB0], r.bg, "(x) " ~ cell ~ " B0 (single-sided)");
            assert(gap(r.q[iB1], r.q[iF1]) <= 2,
                format("(x) %s: B1 %s must read F1 %s (double-sided, flipped normal)", cell, r.q[iB1], r.q[iF1]));
            isDrawn(r.q[iB1], r.bg, "(x) " ~ cell ~ " B1");
            ++rows;
        }
        cmd(commandBody("viewport.backdropStyle", `{"value":"wireframe"}`));
        settle();
        auto r = readAll(vp, "backdrop wire/retopology " ~ retopo);
        isBg(r.q[iF0], r.bg, "(x) wire backdrop F0 (no faces)");
        ++rows;
    }
    assert(rows == 6, format("(x) population: %d rows, expected 6", rows));
}

// ---------------------------------------------------------------------------
// D1 (xi): the G-buffer normal of a double-sided back face is the flipped one;
// a culled back face leaves the background id.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("gbuf")) return;
    auto vp = loadRig();
    cmd(commandBody("viewport.cavity", `{"value":"screen"}`));
    scope(exit) cmdRaw(commandBody("viewport.cavity", `{"value":"off"}`));
    settle();
    auto b1 = px(vp, kQuads[iB1].c), b0 = px(vp, kQuads[iB0].c), f1 = px(vp, kQuads[iF1].c);
    auto j = getJson(format("/api/viewport/probe?cell=0&buffer=gbuf&points=%d,%d;%d,%d;%d,%d",
                            f1[0], f1[1], b1[0], b1[1], b0[0], b0[1]));
    assert("error" !in j, "gbuf probe failed: " ~ j.toString);
    auto pts = j["points"].array;
    assert(pts.length == 3, "gbuf probe: point count");
    double nz(JSONValue e) {
        auto a = e["gbuf"].array;   // [x, y, id, flags, nx16, ny16]
        double ex = a[4].integer / 65535.0 * 2 - 1, ey = a[5].integer / 65535.0 * 2 - 1;
        double z = 1 - abs(ex) - abs(ey);
        double x = ex, y = ey;
        if (z < 0) { x = (1 - abs(ey)) * (ex >= 0 ? 1 : -1); y = (1 - abs(ex)) * (ey >= 0 ? 1 : -1); }
        return z / sqrt(x*x + y*y + z*z);
    }
    long id(JSONValue e) { return e["gbuf"].array[2].integer; }
    assert(id(pts[0]) == 1 && nz(pts[0]) > 0.3, format("(xi) control: F1 id %d n.z %.3f", id(pts[0]), nz(pts[0])));
    assert(id(pts[1]) == 1 && nz(pts[1]) > 0.3,
        format("(xi) B1 (double-sided back face): id %d n.z %.3f, expected id 1 and the flipped normal (n.z > 0.3)",
               id(pts[1]), nz(pts[1])));
    assert(id(pts[2]) == 0, format("(xi) B0 (culled): id %d, expected the background 0", id(pts[2])));
}

// ---------------------------------------------------------------------------
// D2: the attribute command — apply, undo, redo, refusals, materialisation.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("command")) return;
    auto vp = loadRig();
    immutable r0 = readAll(vp, "cmd-before");
    isBg(r0.q[iB0], r0.bg, "D2 premise: B0 culled");
    cmd(`{"id":"history.clear"}`);
    immutable size_t d0 = undoDepth();
    cmd(attrBody(0, "twoSided", 1));
    settle();
    assert(undoDepth() == d0 + 1, "D2: the command recorded no undo entry");
    auto r1 = readAll(vp, "cmd-on");
    assert(gap(r1.q[iB0], r1.q[iF0]) <= 2, format("D2: B0 %s must read F0 %s once s0 is double-sided", r1.q[iB0], r1.q[iF0]));
    cmd(commandBody("history.undo"));
    settle();
    isBg(readAll(vp, "cmd-undo").q[iB0], r0.bg, "D2 undo: B0");
    cmd(commandBody("history.redo"));
    settle();
    assert(gap(readAll(vp, "cmd-redo").q[iB0], r1.q[iF0]) <= 2, "D2 redo: B0 must read F0 again");
    immutable size_t d1 = undoDepth();
    auto again = cmdRaw(attrBody(0, "twoSided", 1));
    assert(again["status"].str == "error" && undoDepth() == d1,
        "D2: the same value must be refused with no history entry: " ~ again.toString);
    auto past = cmdRaw(attrBody(2, "twoSided", 1));
    assert(past["status"].str == "error" && undoDepth() == d1,
        "D2: surface 2 (n = 2) must be refused: " ~ past.toString);
}

unittest {
    if (!cellOn("materialise")) return;
    cmd(commandBody("scene.reset"));
    cmd(`{"id":"history.clear"}`);
    cmd(commandBody("viewport.layout", `"Single"`));
    cmd(commandBody("viewport.wireOverlay", `{"value":"none"}`));
    cmd("select.typeFrom polygon");
    settle();
    assert(getJson("/api/model")["surfaces"].array.length == 0, "D2 premise: the primitive has no surface table");
    auto vp = viewportFromCameraMatrices();
    // The face nearest the eye along the view axis is a front face: probe the
    // centre of the cell.
    auto sz = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable int W = cast(int)sz["w"].integer, H = cast(int)sz["h"].integer;
    int[2][] ctr = [[W / 2, H / 2]];
    immutable before = probeRGB(ctr)[0];
    cmd(attrBody(0, "twoSided", 1));
    settle();
    auto s = getJson("/api/model")["surfaces"].array;
    assert(s.length == 1 && s[0]["twoSided"].type == JSONType.true_,
        "D2: the implicit slot must be materialised with the flag: " ~ getJson("/api/model")["surfaces"].toString);
    immutable after = probeRGB(ctr)[0];
    foreach (k; 0 .. 3)
        assert(abs(after[k] - before[k]) <= 1,
            format("D2: the materialised slot changed the front colour %s -> %s (must be Surface.init)", before, after));
    cmd(commandBody("history.undo"));
    settle();
    assert(getJson("/api/model")["surfaces"].array.length == 0, "D2: undo must restore the empty table");
}

// ---------------------------------------------------------------------------
// Picking is UNCHANGED (stationary: green on the pre-S1d binary too).
// ---------------------------------------------------------------------------
JSONValue camera() { return getJson("/api/camera"); }
string vpLine() {
    auto c = camera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer);
}
void click(int[2] w) {
    playAndWait(vpLine() ~ format(
        `{"t":50.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":100.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":150.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        w[0], w[1], w[0], w[1], w[0], w[1]));
    settle();
}
void lasso(int[2] a, int[2] b) {
    string log = vpLine();
    double t = 50.0;
    log ~= format(`{"t":%.1f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, a[0], a[1]);
    int px0 = a[0], py0 = a[1];
    void go(int x, int y) {
        t += 25.0;
        log ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
                      t, x, y, x - px0, y - py0);
        px0 = x; py0 = y;
    }
    go(b[0], a[1]); go(b[0], b[1]); go(a[0], b[1]); go(a[0], a[1]);
    t += 25.0;
    log ~= format(`{"t":%.1f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, a[0], a[1]);
    playAndWait(log);
    settle();
}
long[] sel(string key) {
    long[] r;
    foreach (v; getJson("/api/selection")[key].array) r ~= v.integer;
    r.sort();
    return r;
}

unittest {
    if (!cellOn("picking")) return;
    auto vp = loadRig();
    // P1: a polygon click inside B0 (a background pixel after S1d) selects B0
    // — a click has no facing term (measured_laws §3).
    click(winPx(vp, kQuads[iB0].c));
    assert(sel("selectedFaces") == [cast(long)iB0],
        format("P1: a click inside B0 selected %s, expected [%d] (picking unchanged)", sel("selectedFaces"), iB0));
    cmd(commandBody("select.drop"));
    // P3: the polygon lasso has a facing term — positive control over F0 first.
    D3 lo(int i) { return [kQuads[i].c[0] - 0.4, kQuads[i].c[1] - 0.4, 0]; }
    D3 hi(int i) { return [kQuads[i].c[0] + 0.4, kQuads[i].c[1] + 0.4, 0]; }
    lasso(winPx(vp, lo(iF0)), winPx(vp, hi(iF0)));
    assert(sel("selectedFaces") == [cast(long)iF0], format("P3 control: a lasso over F0 selected %s", sel("selectedFaces")));
    cmd(commandBody("select.drop"));
    lasso(winPx(vp, lo(iB0)), winPx(vp, hi(iB0)));
    assert(sel("selectedFaces").length == 0, format("P3: a lasso over B0 selected %s, expected none", sel("selectedFaces")));
    // P2: a vertex click on B0's corner picks it.
    cmd("select.typeFrom vertex");
    cmd(commandBody("select.drop"));
    immutable D3 b0c = corners(kQuads[iB0])[0];
    click(winPx(vp, b0c));
    assert(sel("selectedVertices") == [4L * iB0],
        format("P2: a vertex click on B0's corner selected %s, expected [%d]", sel("selectedVertices"), 4 * iB0));
    // P4: Ft's corner behind the (culled) Bo is NOT picked: the vertex pre-pass
    // is two-sided (unchanged). The reference picks it (C7i) — gap row, 9041.
    cmd(commandBody("select.drop"));
    immutable D3 ftc = corners(kQuads[iFt])[2];
    click(winPx(vp, ftc));
    assert(sel("selectedVertices").length == 0,
        format("P4: Ft's corner behind Bo was picked (%s): the vertex pre-pass must stay two-sided "
               ~ "(C7i: the reference picks it — a picking change is backlog 9041)", sel("selectedVertices")));
}

// ---------------------------------------------------------------------------
// The hover walk runs once per side: the back side of a two-sided slot starts
// from the material colour, not from the hover tint the front side ended on.
// ---------------------------------------------------------------------------
unittest {
    if (!cellOn("hover")) return;
    auto vp = loadRig();
    immutable r0 = readAll(vp, "hover-before");
    immutable w = winPx(vp, kQuads[iF0].c);
    string log = vpLine();
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      50.0 + i * 20.0, w[0], w[1]);
    playAndWait(log);
    settle();
    auto r = readAll(vp, "hover-F0");
    // Positive control: F0 is hover-tinted.
    assert(gap(r.q[iF0], r0.q[iF0]) >= 6, format("hover control: F0 %s did not take the hover tint (was %s)",
                                                 r.q[iF0], r0.q[iF0]));
    assert(gap(r.q[iB1], r0.q[iB1]) <= 1 && gap(r.q[iF1], r0.q[iF1]) <= 1,
        format("hovering F0 tinted F1 %s / B1 %s (were %s / %s): the back side must start from the material colour",
               r.q[iF1], r.q[iB1], r0.q[iF1], r0.q[iB1]));
}
