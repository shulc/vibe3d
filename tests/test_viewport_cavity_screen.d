// test_viewport_cavity_screen.d — the screen-curvature term of the composite
// resolve (wave plan S3a, task 9230, model M4). Every prediction is computed
// HERE from the formula, over the cell's own G-buffer read back through the
// probe: four taps one pixel up/down/right/left; none on a silhouette (the
// up/down or right/left ids differ) or over background; else the eye-normal
// divergence `(Nup.y - Ndown.y) + (Nright.x - Nleft.x)` through the soft
// limiter with controls `0.5/max(ridge^2,1e-4)` (ridge) and
// `0.7/max(valley^2,1e-4)` (valley); factor `clamp(1 + curv, 0, 4)` on pixels
// whose flags carry bit 0. The predicted pixel is `round(off × factor)`.
//
// Rig (sharp creases, so flat normals — never a cube under smooth normals):
// a 3×3×3 box whose top-centre polygon is bevelled INTO a pit (inset 0.05,
// shift −0.25), lifted off the grid, smooth shading OFF, Shaded, seen from
// above-front-right. Cells: (a) a convex edge pixel brighter by ≥ 4; (b) a
// concave pit pixel darker by ≥ 4; (c) a flat face-centre pixel equal ±0 —
// one test, so a flat-only probe cannot redden; every pixel of one column and
// one row equal to its prediction ±1 (population pinned); (d) the silhouette
// between two layers; (e) the wire overlay over a crease is unchanged, and
// the same pixel without the wire changes; (f) Solid + screen equals Solid;
// (g) a face pass whose flags lack bit 0 (a Flat/Solid backdrop) is untouched.
// `VIBE3D_CELL=<id>` runs one cell.
module test_viewport_cavity_screen;

import http_client : getJson, postJson, quiesce, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round, sqrt;

void main() {}

private bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

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

private string hash() {
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

// ---------------------------------------------------------------------------
// Probes. Coordinates are cell-local, y DOWN: screen-up is y - 1.
// ---------------------------------------------------------------------------
private struct G { long id, flags; double[3] n; }
alias P = int[2];

private string ptsArg(const P[] pts) {
    string s;
    foreach (k, p; pts) s ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    return s;
}

private G[P] gbufAt(const P[] pts) {
    G[P] o;
    for (size_t k = 0; k < pts.length; k += 1000) {
        immutable size_t e = k + 1000 < pts.length ? k + 1000 : pts.length;
        auto j = getJson("/api/viewport/probe?cell=0&buffer=gbuf&points=" ~ ptsArg(pts[k .. e]));
        assert("error" !in j, "gbuf probe failed: " ~ j.toString);
        foreach (pt; j["points"].array) {
            auto a = pt["gbuf"].array;   // [x, y, id, flags, nx, ny]
            G g;
            g.id = ji(a[2]); g.flags = ji(a[3]);
            immutable double ex = ji(a[4]) / 65535.0 * 2 - 1, ey = ji(a[5]) / 65535.0 * 2 - 1;
            double nx = ex, ny = ey, nz = 1 - abs(ex) - abs(ey);
            if (nz < 0) {
                nx = (1 - abs(ey)) * (ex >= 0 ? 1 : -1);
                ny = (1 - abs(ex)) * (ey >= 0 ? 1 : -1);
            }
            immutable double l = sqrt(nx * nx + ny * ny + nz * nz);
            g.n = [nx / l, ny / l, nz / l];
            o[[cast(int) ji(a[0]), cast(int) ji(a[1])]] = g;
        }
    }
    assert(o.length == pts.length, format("gbuf probe returned %d of %d points", o.length, pts.length));
    return o;
}

private int[4][P] colourAt(const P[] pts) {
    int[4][P] o;
    for (size_t k = 0; k < pts.length; k += 1000) {
        immutable size_t e = k + 1000 < pts.length ? k + 1000 : pts.length;
        auto j = getJson("/api/viewport/probe?cell=0&points=" ~ ptsArg(pts[k .. e]));
        assert("error" !in j, "colour probe failed: " ~ j.toString);
        foreach (pt; j["points"].array) {
            assert("error" !in pt, "colour probe point failed: " ~ pt.toString);
            o[[cast(int) ji(pt["x"]), cast(int) ji(pt["y"])]] =
                [cast(int) ji(pt["r"]), cast(int) ji(pt["g"]), cast(int) ji(pt["b"]), cast(int) ji(pt["a"])];
        }
    }
    assert(o.length == pts.length, format("colour probe returned %d of %d points", o.length, pts.length));
    return o;
}

/// `pts` plus their four one-pixel neighbours.
private P[] withTaps(const P[] pts) {
    bool[P] seen;
    P[] o;
    foreach (p; pts)
        foreach (d; [[0, 0], [0, -1], [0, 1], [1, 0], [-1, 0]]) {
            P q = [p[0] + d[0], p[1] + d[1]];
            if (q !in seen) { seen[q] = true; o ~= q; }
        }
    return o;
}

// ---------------------------------------------------------------------------
// The formula, independent of the shader text.
// ---------------------------------------------------------------------------
private double softLimit(double x, double ctl) {
    return x < 0.5 / ctl ? x * (1.0 - x * ctl) : 0.25 / ctl;
}

/// The resolve factor at `p`. `idTest = false` is the formula WITHOUT the
/// silhouette term (the discrimination floor of cell (d)).
private double factorAt(G[P] g, P p, double ridge = 1, double valley = 1, bool idTest = true) {
    immutable G c = g[p];
    if ((c.flags & 1) == 0) return 1.0;
    immutable G u = g[[p[0], p[1] - 1]], d = g[[p[0], p[1] + 1]],
                r = g[[p[0] + 1, p[1]]], l = g[[p[0] - 1, p[1]]];
    if (idTest && (u.id != d.id || r.id != l.id)) return 1.0;
    if (u.id == 0 && r.id == 0) return 1.0;
    immutable double diff = (u.n[1] - d.n[1]) + (r.n[0] - l.n[0]);
    immutable double rc = 0.5 / (ridge * ridge > 1e-4 ? ridge * ridge : 1e-4);
    immutable double vc = 0.7 / (valley * valley > 1e-4 ? valley * valley : 1e-4);
    immutable double curv = diff < 0 ? -2.0 * softLimit(-diff, vc) : 2.0 * softLimit(diff, rc);
    immutable double k = 1 + curv;
    return k < 0 ? 0 : (k > 4 ? 4 : k);
}

private int predict(int off, double k) {
    immutable double v = round(off * k);
    return v > 255 ? 255 : cast(int) v;
}

// ---------------------------------------------------------------------------
// The crease rig.
// ---------------------------------------------------------------------------
private enum double kLift = 0.6;

private Viewport creaseRig() {
    cmdOk(commandBody("scene.reset", `{"empty":true}`));
    cmdOk("prim.cube segmentsX:3 segmentsY:3 segmentsZ:3 radius:0");
    // The top-centre polygon: the one face whose centroid is (0, 0.5, 0).
    auto m = getJson("/api/model");
    auto V = m["vertices"].array, F = m["faces"].array;
    long top = -1;
    size_t hits;
    foreach (i, f; F) {
        double[3] c = 0;
        foreach (vi; f.array)
            foreach (a; 0 .. 3) {
                auto x = V[ji(vi)].array[a];
                c[a] += x.type == JSONType.float_ ? x.floating : cast(double) ji(x);
            }
        foreach (a; 0 .. 3) c[a] /= f.array.length;
        if (abs(c[0]) < 1e-6 && abs(c[1] - 0.5) < 1e-6 && abs(c[2]) < 1e-6) { top = i; ++hits; }
    }
    assert(hits == 1 && F.length == 54,
        format("rig: a 3x3x3 box has 54 faces and one top-centre face; got %d faces, %d hits", F.length, hits));
    cmdOk(format(`{"id":"mesh.select","params":{"mode":"polygons","indices":[%d]}}`, top));
    cmdOk("tool.set poly.bevel on");
    cmdOk("tool.attr poly.bevel inset 0.05");
    cmdOk("tool.attr poly.bevel shift -0.25");
    cmdOk("tool.doApply");
    cmdOk("tool.set poly.bevel off");
    cmdOk(`{"id":"mesh.select","params":{"mode":"polygons","indices":[]}}`);
    assert(ji(getJson("/api/model")["faceCount"]) == 58, "rig: the bevel must add the pit's four walls (58 faces)");
    cmdOk("history.clear");
    cmdOk(format("layer.attr 0 pos.y %s", kLift));
    cmd("viewport.layout", `"Single"`);
    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.smooth", `{"value":"off"}`);
    cmd("viewport.wireOverlay", `{"value":"none"}`);
    cmd("viewport.wireAlpha", `{"value":"1"}`);
    cmd("viewport.cavityParams", `{"screenRidge":1,"screenValley":1}`);
    auto cr = postJson("/api/camera?viewport=0",
        format(`{"focus":{"x":0,"y":%s,"z":0},"distance":2.4,"azimuth":0.5,"elevation":0.85}`, kLift));
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    return viewportFromCameraMatrices();
}

private P toPx(double x, double y, double z, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) x, cast(float) y, cast(float) z), vp, px, py),
        "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

/// Off and screen colours of `line`, the G-buffer under it, each pixel's
/// predicted factor; asserts every pixel equal to its prediction ±1 and
/// returns the count of pixels whose factor differs from 1 by > 0.05.
private struct Scan { P[] line; int[4][P] off, on; G[P] g; double[] k; size_t creased; }

private Scan scan(P[] line, string what) {
    Scan s;
    s.line = line;
    cmd("viewport.cavity", `{"value":"screen"}`);
    hash();
    s.on = colourAt(line);
    s.g = gbufAt(withTaps(line));
    cmd("viewport.cavity", `{"value":"off"}`);
    hash();
    s.off = colourAt(line);
    foreach (p; line) {
        immutable double k = factorAt(s.g, p);
        s.k ~= k;
        if (abs(k - 1) > 0.05) ++s.creased;
        foreach (ch; 0 .. 3) {
            immutable int want = predict(s.off[p][ch], k);
            assert(abs(s.on[p][ch] - want) <= 1,
                format("%s %s ch %d: screen cavity reads %d, predicted %d (off %d × factor %.4f; id %d flags %d)",
                       what, p, ch, s.on[p][ch], want, s.off[p][ch], k, s.g[p].id, s.g[p].flags));
        }
    }
    return s;
}

// ===========================================================================
// (a) convex brighter, (b) concave darker, (c) flat equal — one test; and the
// whole column / row equal to the formula.
// ===========================================================================
unittest {
    if (!cellOn("abc")) return;
    auto vp = creaseRig();
    auto sz = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable int W = cast(int) sz["w"].integer, H = cast(int) sz["h"].integer;

    // The column through the pit centre: top, far pit wall, pit floor, near
    // top, front face. The row across the box's vertical front-right corner.
    immutable P pit = toPx(0, kLift + 0.25, 0, vp);
    immutable P corner = toPx(0.5, kLift, 0.5, vp);
    P[] column, row;
    foreach (y; 2 .. H - 2) column ~= [pit[0], y];
    foreach (x; 2 .. W - 2) row ~= [x, corner[1]];
    auto c = scan(column, "column");
    auto r = scan(row, "row");
    // Population floors (measured, 2026-10-02): the column crosses three
    // creases (pit mouth, pit floor, top-front edge), two pixels each; the row
    // crosses the vertical corner (two pixels) and one silhouette pixel
    // against a back face drawn behind the right face's rim.
    assert(c.creased == 6, format("(abc) population: the column must hold 6 creased pixels, got %d", c.creased));
    assert(r.creased == 3, format("(abc) population: the row must hold 3 creased pixels, got %d", r.creased));

    // The named cells, located from the G-buffer along the column: the LAST
    // normal change (top -> front face) is the convex edge, the one before it
    // (far wall -> floor) the concave pit crease.
    size_t[] changes;
    foreach (i; 1 .. column.length) {
        immutable G a = c.g[column[i - 1]], b = c.g[column[i]];
        if (a.id != 0 && b.id != 0 && abs(a.n[0] - b.n[0]) + abs(a.n[1] - b.n[1]) > 0.2) changes ~= i;
    }
    // Measured: 4 changes — the three creases, then the front face meeting a
    // back face drawn at the lower silhouette.
    assert(changes.length == 4, format("(abc) rig: the column must cross 4 normal changes, crossed %d at %s",
                                       changes.length, changes));
    immutable P convex = column[changes[2]];       // first front-face pixel under the top edge
    immutable P concave = column[changes[1] - 1];  // last far-wall pixel above the floor
    immutable P flat = column[(changes[1] + changes[2]) / 2];
    immutable int cOff = c.off[convex][0], cOn = c.on[convex][0];
    assert(cOn >= cOff + 4, format("(a) convex edge %s: screen %d must be ≥ 4 brighter than off %d", convex, cOn, cOff));
    immutable int vOff = c.off[concave][0], vOn = c.on[concave][0];
    assert(vOn <= vOff - 4, format("(b) concave pit %s: screen %d must be ≥ 4 darker than off %d", concave, vOn, vOff));
    assert(c.on[flat] == c.off[flat], format("(c) flat face %s: screen %s must equal off %s", flat, c.on[flat], c.off[flat]));
}

// ===========================================================================
// (d) the silhouette between two layers: a smooth near-sphere in front of a
// box in another layer, front orthographic view. The sphere-side boundary
// pixel equals cavity off ±1; without the id test it would differ by ≥ 4.
// ===========================================================================
private string boxJson(double cx, double cy, double cz, double s) {
    JSONValue[] v;
    foreach (k; 0 .. 8)
        v ~= JSONValue([cx + ((k & 1) ? s : -s), cy + ((k & 2) ? s : -s), cz + ((k & 4) ? s : -s)]);
    auto f = JSONValue([[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3],
                        [0, 4, 6, 2], [1, 3, 7, 5]]);
    return JSONValue(["vertices": JSONValue(v), "faces": f]).toString;
}

unittest {
    if (!cellOn("d")) return;
    cmdOk(commandBody("scene.reset", `{"type":"subdivcube","levels":3}`));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh", boxJson(1.2, 0.5, -2.0, 1.0)));
    cmdOk("layer.attr 0 pos.y 0.5");
    cmdOk("history.clear");
    cmd("viewport.layout", `"Single"`);
    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmd("viewport.smooth", `{"value":"on"}`);
    cmd("viewport.wireOverlay", `{"value":"none"}`);
    cmd("viewport.cavityParams", `{"screenRidge":1,"screenValley":1}`);
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0", `{"focus":{"x":0.4,"y":0.5,"z":0},"distance":4}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    auto vp = viewportFromCameraMatrices();
    immutable P centre = toPx(0, 0.5, 0, vp);
    P[] row;
    foreach (dx; -160 .. 160) row ~= [centre[0] + dx, centre[1]];
    auto s = scan(row, "(d) row");
    // The sphere's right boundary: the last id-1 pixel right of the centre
    // whose right neighbour is the box (id 2).
    ptrdiff_t b = -1;
    foreach (i; 160 .. row.length - 1)
        if (s.g[row[i]].id == 1 && s.g[row[i + 1]].id == 2) { b = i; break; }
    assert(b > 0, "(d) rig: the sphere's right edge must meet the box (id 1 -> id 2) on the centre row");
    immutable P p = row[b];
    immutable double kMut = factorAt(s.g, p, 1, 1, false);
    immutable int mut = predict(s.off[p][0], kMut);
    assert(abs(mut - s.off[p][0]) >= 4,
        format("(d) discrimination floor: without the id test the boundary pixel %s would read %d vs off %d "
               ~ "(factor %.3f) — the cell cannot tell the silhouette term", p, mut, s.off[p][0], kMut));
    assert(abs(s.on[p][0] - s.off[p][0]) <= 1,
        format("(d) the sphere-side silhouette pixel %s must equal cavity off ±1: screen %d off %d",
               p, s.on[p][0], s.off[p][0]));
    // Positive control: inside the sphere the term is live.
    immutable P inner = row[b - 3];
    assert(abs(s.on[inner][0] - s.off[inner][0]) >= 2,
        format("(d) control: the sphere pixel %s three pixels inside must change (screen %d off %d)",
               inner, s.on[inner][0], s.off[inner][0]));
}

// ===========================================================================
// (e) the wire overlay is drawn AFTER the resolve: an opaque wire pixel on a
// crease reads its cavity-off value; with the wire off the same pixel changes.
// ===========================================================================
unittest {
    if (!cellOn("e")) return;
    auto vp = creaseRig();
    auto sz = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable int H = cast(int) sz["h"].integer;
    immutable P pit = toPx(0, kLift + 0.25, 0, vp);
    P[] column;
    foreach (y; 2 .. H - 2) column ~= [pit[0], y];
    // Without the wire: the crease pixels and their factors.
    auto bare = scan(column, "(e) bare column");
    cmd("viewport.wireOverlay", `{"value":"uniform"}`);
    cmd("viewport.cavity", `{"value":"off"}`);
    hash();
    auto wOff = colourAt(column);
    cmd("viewport.cavity", `{"value":"screen"}`);
    hash();
    auto wOn = colourAt(column);
    cmd("viewport.wireOverlay", `{"value":"none"}`);
    size_t checked;
    foreach (i, p; column) {
        // A wire pixel: the wire changed it (off frame) and the bare pixel's
        // factor is far from 1 (a crease under the wire).
        if (wOff[p] == bare.off[p] || abs(bare.k[i] - 1) < 0.25) continue;
        assert(bare.on[p] != bare.off[p],
            format("(e) control: without the wire the crease pixel %s must change (off %s screen %s)",
                   p, bare.off[p], bare.on[p]));
        immutable int wouldBe = predict(wOff[p][0], bare.k[i]);
        assert(abs(wouldBe - wOff[p][0]) >= 4,
            format("(e) discrimination floor: the wire pixel %s scaled by %.3f would read %d vs %d",
                   p, bare.k[i], wouldBe, wOff[p][0]));
        assert(wOn[p] == wOff[p],
            format("(e) the wire pixel %s over a crease must be unchanged by cavity: off %s screen %s",
                   p, wOff[p], wOn[p]));
        ++checked;
    }
    assert(checked == 3, format("(e) population: 3 wire pixels over creases on the column (pit mouth, pit floor, "
                                ~ "top-front edge), checked %d", checked));
}

// ===========================================================================
// (f) Solid + screen equals Solid (cavity is Shaded-only), on a rig where
// Shaded + screen differs from Shaded.
// ===========================================================================
unittest {
    if (!cellOn("f")) return;
    creaseRig();
    cmd("viewport.cavity", `{"value":"off"}`);
    immutable string shadedOff = hash();
    cmd("viewport.cavity", `{"value":"screen"}`);
    immutable string shadedOn = hash();
    assert(shadedOn != shadedOff, "(f) control: under Shaded the screen cavity must change the frame");
    cmd("viewport.displayStyle", `{"style":"solid"}`);
    immutable string solidOn = hash();
    cmd("viewport.cavity", `{"value":"off"}`);
    immutable string solidOff = hash();
    assert(solidOn == solidOff, "(f) Solid with screen cavity must hash equal to Solid without");
}

// ===========================================================================
// (g) a face pass whose flags lack bit 0 is untouched: the crease box as a
// Flat backdrop whose slot style is Solid (an unlit fill: its pixels carry an
// id but flags 0). Control: the same box as a Shaded backdrop changes.
// ===========================================================================
unittest {
    if (!cellOn("g")) return;
    auto vp = creaseRig();
    cmdOk(`{"id":"layer.add"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    auto sz = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable int H = cast(int) sz["h"].integer;
    immutable P pit = toPx(0, kLift + 0.25, 0, vp);
    P[] column;
    foreach (y; 2 .. H - 2) column ~= [pit[0], y];
    auto same = scan(column, "(g) Shaded backdrop column");
    assert(same.creased == 6, format("(g) control: the Shaded backdrop holds 6 creased pixels, got %d", same.creased));
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    cmd("viewport.displayStyle", `{"value":"solid","slot":1}`);   // the Flat slot: an unlit fill
    assert(ji(getJson("/api/viewport/display")["cells"].array[0]["plan"]["backdrop"]["effectFlags"]) == 0,
        "(g) premise: the Flat backdrop with a Solid slot is not cavity-eligible");
    cmd("viewport.cavity", `{"value":"screen"}`);
    hash();
    auto g = gbufAt(withTaps(column));
    auto fOn = colourAt(column);
    cmd("viewport.cavity", `{"value":"off"}`);
    hash();
    auto fOff = colourAt(column);
    size_t faced, wouldChange;
    foreach (i, p; column) {
        if (g[p].id == 0) continue;
        ++faced;
        assert(g[p].flags == 0, format("(g) premise: a Flat backdrop pixel %s carries flags %d", p, g[p].flags));
        g[p].flags = 1;   // what the formula would do if the flags were ignored
        if (predict(fOff[p][0], factorAt(g, p)) != fOff[p][0]) ++wouldChange;
        g[p].flags = 0;
        assert(fOn[p] == fOff[p], format("(g) Flat backdrop pixel %s must be untouched: off %s screen %s",
                                         p, fOff[p], fOn[p]));
    }
    assert(faced > 100, format("(g) population: the column must cross the backdrop box (%d face pixels)", faced));
    assert(wouldChange >= 2, format("(g) discrimination floor: ignoring the flags would change %d pixels", wouldChange));
}
