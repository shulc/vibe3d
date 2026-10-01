// Topology pen session laws, slice S7b (wave plan 8640 §9.8 as filled by
// §9.17.6, the slide rows of §9.19.2 / §9.22.5 / §9.26.3 / §9.27 [A15-4], and
// L58): an interactive attribute write re-evaluates the LAST press by its
// kind (`kReapply`), and the Move family's drag kernel is the G-delta offset.
// Same rig as tests/test_session_laws_topology_pen.d; the laws are the
// capture's (session_capture fixtures c0..c6), every number below is OUR run's,
// and every background distance is measured against the rig FILE's own
// background facets — an oracle independent of the kernel.
//
//   offset-reapply             L7/L17/L23 a vertex move re-placed per write, each
//                                         component varied alone; undo/redo
//   reapply-edge/-poly/-loop   L17  the carried set at nearestBG(anchor + offset)
//   reapply-slide / -vertex    L17  the slid endpoints / the slid vertex
//   reapply-build-corner       L17  the new vertex, anchored at its SOURCE (C0-S5)
//   reapply-point              L17  the placed point (offset 0 after the click)
//   reapply-dup-edge           L30  the two new vertices, anchored at their sources
//   reapply-loop-weld          S7a  a welded landing leaves no carried set
//   reapply-dup-loop           D17  another kind: attribute-only (ours)
//   offset-script-door         the re-apply is the interactive write's
//   reapply-addloop / -fill    L20/L30  the press image comes back bit-exact
//   reapply-smooth-offset      L19  attribute-only, bit-exact
//   reapply-smooth-strength    L21  re-run from the press image at the new strength
//   reapply-smooth-passes      L21  ... keeping the press's pass count (a 5-pass drag)
//   reapply-remove / -split    L30  attribute-only, bit-exact
//   offset-zero-exact          L24  three writes: the third puts v5 back BIT-exact
//   offset-came-home           R1-7 the carried set, not a mesh diff
//   offset-after-command       L58  a recording command ends the gesture link (every write)
//   offsets-live-edge / -loop  L18  the G-delta offset of the pressed anchor
//   drag-poly-offcentre        L28  the polygon's centroid follows the drag DELTA
//   drag-slide-dir             L36/L47  one world channel, rotated and orbited rigs
//   drag-slide-f / -L / -tie   L50  the axis latches at 4.5 px of path, a tie -> Y
//   drag-slide-offsurface      [A12-1] the axis from the SURFACE delta (grid off the sphere)
//
// `VIBE3D_CELL=<id>` runs one cell alone; the last block pins the population.
//
// Run via: ./run_test.d test_session_laws_topology_pen_offset

import topology_pen_session_helpers;
import drag_helpers : Vec3, Viewport, viewportFromCameraMatrices, pixelRay, projectToWindow;
import http_client : getJson;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.json;
import std.math : abs, cos, sin, sqrt, round, lrint, PI, hypot;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writeln;

void main() {}

__gshared int cellsRun;

bool cell(string id) {
    const only = environment.get("VIBE3D_CELL", "");
    const on = only.length == 0 || only == id;
    if (on) ++cellsRun;
    return on;
}

string rigFile(string name) { return buildPath(dirName(__FILE_FULL_PATH__), "fixtures", name); }
PenRig rig() { return penRigLoad(rigFile("topology_pen_session_rig.v3d")); }

JSONValue lawsFx() {
    static JSONValue fx;
    static bool loaded;
    if (!loaded) {
        fx = parseJSON(readText(rigFile("topology_pen_session_laws.json")));
        loaded = true;
    }
    return fx;
}

// The capture rig's grid spacing on screen (v5 -> v6).
enum double kSp = 66.8;

void z(string what)  { penCtrlZ(what); }
void sz(string what) { penCtrlShiftZ(what); }

/// An interactive (panel-origin) attribute write on the armed pen.
void w(string attr, string value) {
    auto r = penPost("/api/script?interactive=true",
                     "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " " ~ value);
    assert(r["status"].str == "ok", "interactive write " ~ attr ~ " " ~ value ~ " failed: "
                                    ~ r.toString);
}

/// A script-door attribute write (no re-apply; the rig's own setup).
void sw(string attr, string value) {
    auto r = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " " ~ value);
    assert(r["status"].str == "ok", "script write " ~ attr ~ " " ~ value ~ " failed: " ~ r.toString);
}

double attrNum(string attr) {
    auto r = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "attribute query " ~ attr ~ " failed: " ~ r.toString);
    auto v = r["value"];
    return v.type == JSONType.string ? v.str.to!double : penNum(v);
}

double[3] offs() { return [attrNum("offsetX"), attrNum("offsetY"), attrNum("offsetZ")]; }
string fmt3(double[3] o) { return format("(%.7g, %.7g, %.7g)", o[0], o[1], o[2]); }
double[3] add3(double[3] a, double[3] b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
double[3] sub3(double[3] a, double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
double dot3(double[3] a, double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
double dist3(double[3] a, double[3] b) { const d = sub3(a, b); return sqrt(dot3(d, d)); }
double len3(double[3] a) { return sqrt(dot3(a, a)); }
double[3] mad3(double[3] a, double[3] b, double s) { return [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s]; }

long stepKindNow() { return getJson("/api/tool/state")["stepKind"].integer; }
long[] stepVertsNow() {
    long[] r;
    foreach (v; getJson("/api/tool/state")["stepVerts"].array) r ~= v.integer;
    return r;
}

void at(string id, string step, const PenMesh want, bool armed, long hist) {
    const m = penMesh();
    assert(m == want && penArmed() == armed && penHistoryLen() == hist,
           format("%s %s: mesh %s the expected %s, armed %s (expected %s), history %d (expected %d) %s",
                  id, step, m == want ? "==" : "!=", want.toString, penArmed(), armed,
                  penHistoryLen(), hist, penHistoryLabels()));
}

// ===========================================================================
// The background oracle: the rig file's layer 1, fanned into triangles.
// ===========================================================================

double[3][3][] bgTris() {
    static double[3][3][] tris;
    if (tris.length) return tris;
    auto bg = parseJSON(readText(rigFile("topology_pen_session_rig.v3d")))["layers"].array[1]["mesh"];
    double[3][] v;
    foreach (x; bg["vertices"].array) v ~= [penNum(x.array[0]), penNum(x.array[1]), penNum(x.array[2])];
    foreach (f; bg["faces"].array)
        foreach (k; 1 .. f.array.length - 1)
            tris ~= [v[f.array[0].integer], v[f.array[k].integer], v[f.array[k + 1].integer]];
    assert(v.length == 482 && tris.length == 448 * 2 + 64,
           format("offset rig: the background is not the 482v/512f sphere: %d v, %d tris", v.length,
                  tris.length));
    return tris;
}

/// Closest point on triangle (a, b, c) to p (the Voronoi-region walk).
double[3] closestOnTri(double[3] p, double[3] a, double[3] b, double[3] c) {
    const ab = sub3(b, a), ac = sub3(c, a), ap = sub3(p, a);
    const d1 = dot3(ab, ap), d2 = dot3(ac, ap);
    if (d1 <= 0 && d2 <= 0) return a;
    const bp = sub3(p, b);
    const d3 = dot3(ab, bp), d4 = dot3(ac, bp);
    if (d3 >= 0 && d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) return mad3(a, ab, d1 / (d1 - d3));
    const cp = sub3(p, c);
    const d5 = dot3(ab, cp), d6 = dot3(ac, cp);
    if (d6 >= 0 && d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) return mad3(a, ac, d2 / (d2 - d6));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return mad3(b, sub3(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)));
    const den = 1.0 / (va + vb + vc);
    return mad3(mad3(a, ab, vb * den), ac, vc * den);
}

double[3] nearestBG(double[3] p) {
    double best = double.infinity;
    double[3] r;
    foreach (t; bgTris()) {
        const q = closestOnTri(p, t[0], t[1], t[2]);
        const d = dist3(q, p);
        if (d < best) { best = d; r = q; }
    }
    return r;
}

/// The nearest background hit of window pixel (sx, sy) under the live camera
/// (Moller-Trumbore over the facets, both sides).
bool bgHit(double sx, double sy, out double[3] hit) {
    const vp = viewportFromCameraMatrices();
    Vec3 o, d;
    pixelRay(cast(float)sx, cast(float)sy, vp, o, d);
    const double[3] org = [o.x, o.y, o.z], dir = [d.x, d.y, d.z];
    double best = double.infinity;
    foreach (t; bgTris()) {
        const e1 = sub3(t[1], t[0]), e2 = sub3(t[2], t[0]);
        const double[3] pv = [dir[1] * e2[2] - dir[2] * e2[1], dir[2] * e2[0] - dir[0] * e2[2],
                              dir[0] * e2[1] - dir[1] * e2[0]];
        const det = dot3(e1, pv);
        if (abs(det) < 1e-14) continue;
        const tv = sub3(org, t[0]);
        const u = dot3(tv, pv) / det;
        if (u < 0 || u > 1) continue;
        const double[3] qv = [tv[1] * e1[2] - tv[2] * e1[1], tv[2] * e1[0] - tv[0] * e1[2],
                              tv[0] * e1[1] - tv[1] * e1[0]];
        const v = dot3(dir, qv) / det;
        if (v < 0 || u + v > 1) continue;
        const s = dot3(e2, qv) / det;
        if (s > 1e-9 && s < best) best = s;
    }
    if (best == double.infinity) return false;
    hit = mad3(org, dir, best);
    return true;
}

float[2] projectF(double[3] p) {
    const vp = viewportFromCameraMatrices();
    float x, y;
    assert(projectToWindow(Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]), vp, x, y),
           format("offset rig: %s projects behind the camera", p));
    return [x, y];
}

/// The carried law at one vertex: p is A nearest background point of the
/// query q = anchor + off — on the background (1e-6) and no further from q
/// than the oracle's foot (1e-6; a query on the rig's x = 0 mirror plane has
/// two). Returns its distance from the raw sum: the caller floors the largest
/// over the carried set at 1e-3 (a re-snap is what separates them; a vertex
/// whose raw sum lands near the surface cannot, one per set must).
double carriedAt(string id, const PenMesh m, long v, double[3] anchor, double[3] off) {
    const q = add3(anchor, off);
    const want = nearestBG(q);
    const p = m.pos[cast(size_t)v];
    const onBg = dist3(nearestBG(p), p), extra = dist3(p, q) - dist3(want, q);
    assert(onBg <= 1e-6 && abs(extra) <= 1e-6,
           format("%s: v%d %s is %.3g off the background and %.3g further from anchor %s + offset %s "
                  ~ "than its foot %s (max 1e-6 each)", id, v, p, onBg, extra, anchor, fmt3(off), want));
    return dist3(p, q);
}

void rawFloor(string id, double worst) {
    assert(worst >= 1e-3, format("%s: the carried set lies within %.3g of the raw sum anchor + offset "
                                 ~ "(min 1e-3): the cell cannot tell a re-snap from the raw sum", id, worst));
}

void penZoomToSpacing(double targetPx, string what) {
    double dist = 4.0;
    foreach (i; 0 .. 4) {
        const sp = penSpacingPx();
        if (abs(sp - targetPx) < 0.1) break;
        const zz = penMesh().pos[5][2];
        dist = zz + (dist - zz) * sp / targetPx;
        penPost("/api/camera", format(`{"azimuth":0.0,"elevation":0.0,"distance":%.9f,`
                                      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`, dist));
    }
    assert(abs(penSpacingPx() - targetPx) < 0.5,
           format("%s rig: the grid spacing reads %.2f px, expected %.1f", what, penSpacingPx(), targetPx));
}

// ===========================================================================
// offset-reapply — L7/L17 (C0 H2f), L23: a released vertex Move, then
// interactive Offset writes, each varying ONE component.
// ===========================================================================
unittest {
    if (!cell("offset-reapply")) return;
    const r = rig();
    penArmUi(r);
    const u5 = r.a0.pos[5];
    penGesture(penVertexPx(5, "offset-reapply v5"), 20 / kSp, 12 / kSp, 1, 0, "offset-reapply g1");
    const g1 = penMesh();
    const o1 = offs();
    assert(penMoved(g1, r.a0) == [5L] && len3(o1) > 1e-3 && o1[0] != 0 && o1[1] != 0 && o1[2] != 0,
           format("offset-reapply g1: moved %s, offsets %s (each channel non-zero)", penIdx(penMoved(g1, r.a0)),
                  fmt3(o1)));
    // D19's vertex arm, unchanged in effect: the vertex lands ON the background
    // at u5 + offset, so nearestBG(u5 + offset) is where it already is.
    assert(dist3(g1.pos[5], nearestBG(add3(u5, o1))) <= 1e-6,
           format("offset-reapply g1: v5 %s is not nearestBG(u5 + offset) %s", g1.pos[5],
                  nearestBG(add3(u5, o1))));
    w("offsetX", "0.1");
    const w1 = penMesh();
    const ow1 = offs();
    assert(abs(ow1[0] - 0.1) < 1e-6 && ow1[1] == o1[1] && ow1[2] == o1[2]
           && penMoved(w1, r.a0) == [5L] && penHistoryLen() == r.hp + 3,
           format("offset-reapply w1: offsets %s (expected X 0.1, Y/Z %s), moved %s, history %s",
                  fmt3(ow1), fmt3(o1), penIdx(penMoved(w1, r.a0)), penHistoryLabels()));
    rawFloor("offset-reapply w1", carriedAt("offset-reapply w1", w1, 5, u5, ow1));
    w("offsetY", "0.05");
    const w2 = penMesh();
    const ow2 = offs();
    assert(ow2[0] == ow1[0] && abs(ow2[1] - 0.05) < 1e-6 && ow2[2] == ow1[2] && w2 != w1,
           format("offset-reapply w2: offsets %s (only Y may change from %s)", fmt3(ow2), fmt3(ow1)));
    rawFloor("offset-reapply w2", carriedAt("offset-reapply w2", w2, 5, u5, ow2));
    z("offset-reapply z1");
    at("offset-reapply", "z1", w1, true, r.hp + 3);
    assert(offs() == ow1, format("offset-reapply z1: offsets %s, expected %s", fmt3(offs()), fmt3(ow1)));
    z("offset-reapply z2");
    at("offset-reapply", "z2", g1, true, r.hp + 2);
    assert(offs() == o1, format("offset-reapply z2: offsets %s, expected g1's %s", fmt3(offs()), fmt3(o1)));
    sz("offset-reapply r1");
    at("offset-reapply", "r1", w1, true, r.hp + 3);
    writeln("PASS offset-reapply");
}

// ===========================================================================
// reapply-* — L17: one cell per carriedT row; the moved set is the kind's
// carried set (the descriptor's, population asserted).
// ===========================================================================

/// A write of offsetX 0.07 after the gesture already played: the carried set
/// `verts` (each at its `anchors` entry) re-placed, nothing else moved, one row.
/// Not the capture's 0.1: on this rig 0.1 is half the spacing, so v5 + 0.1 is
/// e56's midpoint and a loop or edge offset anchored there lands the raw sum
/// ON the background, where it cannot be told from the re-snap.
void reapplyCarried(string id, const PenMesh g1, long kind, const long[] verts,
                    const double[3][] anchors, long hist) {
    assert(stepKindNow() == kind && stepVertsNow().length == verts.length,
           format("%s g1: descriptor kind %d verts %s (expected kind %d over %s)", id, stepKindNow(),
                  penIdx(stepVertsNow()), kind, penIdx(verts)));
    auto sv = stepVertsNow().dup; sort(sv);
    auto want = verts.dup; sort(want);
    assert(sv == want, format("%s g1: the carried set %s is not %s", id, penIdx(sv), penIdx(want)));
    w("offsetX", "0.07");
    const w1 = penMesh();
    const o = offs();
    auto mv = penMoved(w1, g1).dup; sort(mv);
    assert(abs(o[0] - 0.07) < 1e-6 && mv == want && penHistoryLen() == hist + 1,
           format("%s w1: offsets %s, moved %s (expected the carried set %s), history %s", id, fmt3(o),
                  penIdx(mv), penIdx(want), penHistoryLabels()));
    double raw = 0;
    foreach (i, v; verts) {
        const d = carriedAt(id ~ " w1", w1, v, anchors[i], o);
        if (d > raw) raw = d;
    }
    rawFloor(id ~ " w1", raw);
    z(id ~ " z1");
    at(id, "z1", g1, true, hist);
    writeln("PASS ", id);
}

unittest {
    if (!cell("reapply-edge")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(5, 6, "reapply-edge e56"), 20 / kSp, 12 / kSp, 1, 0, "reapply-edge g1");
    reapplyCarried("reapply-edge", penMesh(), 2, [5, 6], [r.a0.pos[5], r.a0.pos[6]], r.hp + 2);
}

unittest {
    if (!cell("reapply-poly")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penFacePx(4), 20 / kSp, 12 / kSp, 1, 0, "reapply-poly g1");
    reapplyCarried("reapply-poly", penMesh(), 3, [5, 6, 9, 10],
                   [r.a0.pos[5], r.a0.pos[6], r.a0.pos[9], r.a0.pos[10]], r.hp + 2);
}

unittest {
    if (!cell("reapply-loop")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(5, 6, "reapply-loop e56"), 0, -15 / kSp, 3, 0, "reapply-loop g1");
    const g1 = penMesh();
    const moved = penMoved(g1, r.a0);
    assert(moved.length == 4, format("reapply-loop g1: the loop moved %s (expected 4)", penIdx(moved)));
    double[3][] anchors;
    foreach (v; moved) anchors ~= r.a0.pos[cast(size_t)v];
    reapplyCarried("reapply-loop", g1, 4, moved, anchors, r.hp + 2);
}

unittest {
    if (!cell("reapply-slide")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(5, 6, "reapply-slide e56"), 0, -20 / kSp, 1, PEN_KMOD_LCTRL, "reapply-slide g1");
    const g1 = penMesh();
    assert(penMoved(g1, r.a0) == [5L, 6L], format("reapply-slide g1: moved %s", penIdx(penMoved(g1, r.a0))));
    reapplyCarried("reapply-slide", g1, 5, [5, 6], [r.a0.pos[5], r.a0.pos[6]], r.hp + 2);
}

unittest {
    if (!cell("reapply-slide-vertex")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penVertexPx(5, "reapply-slide-vertex v5"), 20 / kSp, -10 / kSp, 1, PEN_KMOD_LCTRL,
               "reapply-slide-vertex g1");
    const g1 = penMesh();
    assert(penMoved(g1, r.a0) == [5L], format("reapply-slide-vertex g1: moved %s", penIdx(penMoved(g1, r.a0))));
    // The offset the slide reports, pinned at g1 (not read back into the
    // expectation): one world channel, and v5's own landing nearestBG(u5 + off).
    const o = offs();
    size_t nz;
    foreach (c; o) if (c != 0) ++nz;
    assert(nz == 1, format("reapply-slide-vertex g1: offsets %s (expected exactly one channel)", fmt3(o)));
    carriedAt("reapply-slide-vertex g1", g1, 5, r.a0.pos[5], o);
    reapplyCarried("reapply-slide-vertex", g1, 5, [5], [r.a0.pos[5]], r.hp + 2);
}

unittest {
    if (!cell("reapply-build-corner")) return;
    const r = rig();
    penArmUi(r);
    penZoomToSpacing(kSp, "reapply-build-corner");
    const from = penVertexPx(0, "reapply-build-corner v0");
    const s = penSpacingPx() / kSp;
    penPlay(penGestureEvents(from[0], from[1], from[0] + cast(int)round(-40 * s),
                             from[1] + cast(int)round(40 * s), 1, PEN_KMOD_LSHIFT, 8),
            "reapply-build-corner g1");
    const g1 = penMesh();
    assert(g1.nv == 17 && penHistoryLabels()[$ - 1] == "Topology Build",
           format("reapply-build-corner g1: %s, history %s", g1.toString, penHistoryLabels()));
    // The offset the build reports: the new vertex minus its source.
    const o = offs();
    assert(dist3(add3(r.a0.pos[0], o), g1.pos[16]) <= 1e-6,
           format("reapply-build-corner g1: offsets %s, v16 - v0 = %s", fmt3(o),
                  fmt3(sub3(g1.pos[16], r.a0.pos[0]))));
    reapplyCarried("reapply-build-corner", g1, 6, [16], [r.a0.pos[0]], r.hp + 2);
}

unittest {
    if (!cell("reapply-point")) return;
    const r = rig();
    penArmUi(r);
    sw("mode", "point");
    const hp = penHistoryLen();
    penTap(penEmptyBackgroundPx(), 1, 0, "reapply-point place");
    const g1 = penMesh();
    assert(g1.nv == 17 && offs() == [0.0, 0.0, 0.0],
           format("reapply-point g1: %s, offsets %s (a placement reads 0)", g1.toString, fmt3(offs())));
    reapplyCarried("reapply-point", g1, 7, [16], [g1.pos[16]], hp + 1);
}

unittest {
    if (!cell("reapply-dup-edge")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(0, 1, "reapply-dup-edge e01"), 0, 36 / kSp, 1, PEN_KMOD_LSHIFT,
               "reapply-dup-edge g1");
    const g1 = penMesh();
    assert(g1.nv == 18, format("reapply-dup-edge g1: %s (expected 18 vertices)", g1.toString));
    // Each new vertex's source is the old endpoint it is bridged to.
    double[3][] anchors;
    foreach (v; [16L, 17L]) {
        const s0 = penEdgeId(0, v) >= 0, s1 = penEdgeId(1, v) >= 0;
        assert(s0 != s1, format("reapply-dup-edge g1: v%d bridges to v0 %s, v1 %s", v, s0, s1));
        anchors ~= r.a0.pos[s0 ? 0 : 1];
    }
    reapplyCarried("reapply-dup-edge", g1, 11, [16, 17], anchors, r.hp + 2);
}

// reapply-loop-weld — a Move Loop whose landing WELDS (the loop dropped onto
// the next row) compacts the indices, so its carried set is gone (S7a's Move
// rule): a write after it re-places nothing.
unittest {
    if (!cell("reapply-loop-weld")) return;
    const r = rig();
    penArmUi(r);
    // Stopped short of row 0 (0.8 spacing, inside the 24 px acceptance): a
    // landing exactly ON its targets leaves zero-area faces whose fallback
    // normal the orientation admission refuses (gestures_test, task 0555).
    penGesture(penEdgePx(5, 6, "reapply-loop-weld e56"), 0, 0.8, 3, 0, "reapply-loop-weld g1");
    const g1 = penMesh();
    assert(g1.nv < r.a0.nv && stepKindNow() == 4 && stepVertsNow().length == 0,
           format("reapply-loop-weld g1: %s (expected a weld), kind %d verts %s; v4 %s v0 %s", g1.toString,
                  stepKindNow(), penIdx(stepVertsNow()), g1.pos[4], r.a0.pos[0]));
    writeGives("reapply-loop-weld", g1, g1, r.hp + 2);
}

// reapply-dup-loop — ours (D17, uncaptured): a Duplicate LOOP is another kind,
// so a write after it is attribute-only.
unittest {
    if (!cell("reapply-dup-loop")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(0, 1, "reapply-dup-loop e01"), 0, 36 / kSp, 3, PEN_KMOD_LSHIFT,
               "reapply-dup-loop g1");
    const g1 = penMesh();
    assert(g1.nv > r.a0.nv && stepKindNow() == 0,
           format("reapply-dup-loop g1: %s, kind %d", g1.toString, stepKindNow()));
    writeGives("reapply-dup-loop", g1, g1, r.hp + 2);
}

// offset-script-door — the re-apply is the INTERACTIVE write's: a script-door
// `tool.attr` after a gesture moves nothing (the plan's `interactiveParamEdit`
// gate; captured only with no gesture: H3/L7).
unittest {
    if (!cell("offset-script-door")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penVertexPx(5, "offset-script-door v5"), 20 / kSp, 12 / kSp, 1, 0, "offset-script-door g1");
    const g1 = penMesh();
    sw("offsetX", "0.1");
    assert(penMesh() == g1 && abs(attrNum("offsetX") - 0.1) < 1e-6,
           format("offset-script-door: the script write moved %s (expected nothing)",
                  penIdx(penMoved(penMesh(), g1))));
    // Control: the interactive door re-applies.
    w("offsetX", "0.1");
    assert(penMoved(penMesh(), g1) == [5L], format("offset-script-door control: moved %s",
                                                  penIdx(penMoved(penMesh(), g1))));
    writeln("PASS offset-script-door");
}

// ===========================================================================
// basisOnly / attribute-only / rerunFromBasis rows.
// ===========================================================================

/// offsetX 0.1 after the gesture: the mesh becomes `want` bit-exact, one row;
/// Ctrl+Z gives the gesture back bit-exact.
void writeGives(string id, const PenMesh g1, const PenMesh want, long hist) {
    w("offsetX", "0.1");
    at(id, "w1", want, true, hist + 1);
    z(id ~ " z1");
    at(id, "z1", g1, true, hist);
    writeln("PASS ", id);
}

unittest {
    if (!cell("reapply-addloop")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(5, 6, "reapply-addloop e56"), 10 / kSp, 0, 2, PEN_KMOD_LSHIFT,
               "reapply-addloop g1");
    const g1 = penMesh();
    assert([g1.nv, g1.nf, g1.edges] == [20L, 12, 31] && stepKindNow() == 8,
           format("reapply-addloop g1: %s, kind %d", g1.toString, stepKindNow()));
    // An attribute the kind does not read is attribute-only (D17): its row
    // leaves the loop in place; Ctrl+Z pops it alone.
    w("showEdge", "false");
    at("reapply-addloop", "unread write", g1, true, r.hp + 3);
    z("reapply-addloop unread z");
    at("reapply-addloop", "unread z", g1, true, r.hp + 2);
    writeGives("reapply-addloop", g1, r.a0, r.hp + 2);
}

unittest {
    if (!cell("reapply-fill")) return;
    auto c = lawsFx()["cells"]["fill-consume"];
    PenRig r = penRigLoad(rigFile("topology_pen_session_rig_r4.v3d"), [16, 7, 23]);
    penArmUi(r);
    sw("mode", "fill");
    sw("range", c["range"].str);
    const s = penSpacingPx() / penNum(c["spacingPx"]);
    const e = penEdgePx(5, 6, "reapply-fill e56");
    const int[2] from = [e[0], e[1] + cast(int)round(-5 * s)];
    const r0 = penMesh();
    const hp = penHistoryLen();
    penPlay(penGestureEvents(from[0], from[1], from[0], from[1] + cast(int)round(-10 * s), 1, 0, 4),
            "reapply-fill g1");
    const g1 = penMesh();
    assert(g1.nf == r0.nf + 1 && stepKindNow() == 10 && penHistoryLen() == hp + 1,
           format("reapply-fill g1: %s from %s, kind %d, history %s", g1.toString, r0.toString,
                  stepKindNow(), penHistoryLabels()));
    writeGives("reapply-fill", g1, r0, hp + 1);
}

unittest {
    if (!cell("reapply-remove")) return;
    const r = rig();
    penArmUi(r);
    penTap(penFacePx(0), 2, PEN_KMOD_LCTRL, "reapply-remove g1");
    const g1 = penMesh();
    assert(g1.nf == r.a0.nf - 1, format("reapply-remove g1: %s", g1.toString));
    writeGives("reapply-remove", g1, g1, r.hp + 2);
}

unittest {
    if (!cell("reapply-split")) return;
    const r = rig();
    penArmUi(r);
    const from = penVertexPx(5, "reapply-split v5"), to = penVertexPx(10, "reapply-split v10");
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 2, 0, 8), "reapply-split g1");
    const g1 = penMesh();
    assert(g1.nf == r.a0.nf + 1, format("reapply-split g1: %s", g1.toString));
    writeGives("reapply-split", g1, g1, r.hp + 2);
}

/// One Smoothing click on the rig at strength `strength` (script door before
/// the press, so the press reads it); returns the history length after it.
long smoothClick(string id, string strength) {
    sw("mode", "smooth");
    sw("smoothStrength", strength);
    const hp = penHistoryLen();
    penTap(penFacePx(4), 1, PEN_KMOD_LSHIFT | PEN_KMOD_LCTRL, id ~ " smooth click");
    assert(penHistoryLen() == hp + 1 && stepKindNow() == 9,
           format("%s: the smooth click wrote %s, kind %d", id, penHistoryLabels(), stepKindNow()));
    return hp + 1;
}

unittest {
    if (!cell("reapply-smooth-offset")) return;
    const r = rig();
    penArmUi(r);
    const hist = smoothClick("reapply-smooth-offset", "1");
    const g1 = penMesh();
    assert(penMoved(g1, r.a0).length == 16, "reapply-smooth-offset rig: the smooth moved "
           ~ penIdx(penMoved(g1, r.a0)));
    writeGives("reapply-smooth-offset", g1, g1, hist);
}

unittest {
    if (!cell("reapply-smooth-strength")) return;
    // Fresh smooths at strengths 2 and 3, the references for the re-runs below.
    PenMesh fresh(string strength) {
        const r = rig();
        penArmUi(r);
        smoothClick("reapply-smooth-strength fresh " ~ strength, strength);
        return penMesh();
    }
    const fresh2 = fresh("2"), fresh3 = fresh("3");
    const r = rig();
    penArmUi(r);
    const hist = smoothClick("reapply-smooth-strength", "1");
    const g1 = penMesh();
    assert(penMoved(g1, r.a0).length == 16 && fresh2 != g1 && fresh3 != fresh2,
           format("reapply-smooth-strength rig: moved %s; strengths 1/2/3 must differ", penIdx(penMoved(g1, r.a0))));
    w("smoothStrength", "2");
    const w1 = penMesh();
    // The re-run IS a strength-2 smooth of the press image (L21). Further on
    // the whole: the mean displacement grows (the capture: every vertex, ratio
    // 1.29; ours moves 12 of 16 further — our relax kernel, not this re-run;
    // gap row, card 8780).
    double m1 = 0, m2 = 0;
    size_t further;
    foreach (i; 0 .. 16) {
        m1 += dist3(g1.pos[i], r.a0.pos[i]);
        m2 += dist3(w1.pos[i], r.a0.pos[i]);
        if (dist3(w1.pos[i], r.a0.pos[i]) > dist3(g1.pos[i], r.a0.pos[i])) ++further;
    }
    assert(w1 == fresh2 && m2 > m1 && penHistoryLen() == hist + 1,
           format("reapply-smooth-strength w1: the mesh %s a fresh strength-2 smooth, mean displacement "
                  ~ "%.4g vs %.4g at strength 1, history %s", w1 == fresh2 ? "==" : "!=", m2 / 16, m1 / 16,
                  penHistoryLabels()));
    writeln(format("reapply-smooth-strength: %d of 16 vertices further, mean ratio %.3f", further, m2 / m1));
    z("reapply-smooth-strength z1");
    at("reapply-smooth-strength", "z1", g1, true, hist);
    // Write 2 then 3: the result is a fresh 3 from the press image, not 3 on 2.
    w("smoothStrength", "2");
    w("smoothStrength", "3");
    assert(penMesh() == fresh3 && penHistoryLen() == hist + 2,
           format("reapply-smooth-strength w2,w3: the mesh %s a fresh strength-3 smooth, history %s",
                  penMesh() == fresh3 ? "==" : "!=", penHistoryLabels()));
    writeln("PASS reapply-smooth-strength");
}

/// One Smoothing DRAG `dxPx` to the right on the rig at strength `strength`
/// (several passes, `smoothPassesForDragDx`); returns the history length after.
long smoothDrag(string id, string strength, int dxPx) {
    sw("mode", "smooth");
    sw("smoothStrength", strength);
    const hp = penHistoryLen();
    const f = penFacePx(4);
    penPlay(penGestureEvents(f[0], f[1], f[0] + dxPx, f[1], 1, PEN_KMOD_LSHIFT | PEN_KMOD_LCTRL, 8),
            id ~ " smooth drag");
    assert(penHistoryLen() == hp + 1 && stepKindNow() == 9 && stepVertsNow() == [5L],
           format("%s: the smooth drag wrote %s, kind %d, passes %s (expected 5)", id,
                  penHistoryLabels(), stepKindNow(), stepVertsNow()));
    return hp + 1;
}

// reapply-smooth-passes — L21: the re-run keeps the press's PASS COUNT. A
// 20 px drag is 5 passes; a Strength write gives a fresh 5-pass smooth at the
// written strength, which a 1-pass re-run cannot reach (the click cells above
// are all 1 pass, so they cannot see the count).
unittest {
    if (!cell("reapply-smooth-passes")) return;
    PenMesh fresh(string strength, bool drag) {
        const r = rig();
        penArmUi(r);
        if (drag) smoothDrag("reapply-smooth-passes fresh " ~ strength, strength, 20);
        else smoothClick("reapply-smooth-passes fresh click " ~ strength, strength);
        return penMesh();
    }
    const drag2 = fresh("2", true), click2 = fresh("2", false);
    const r = rig();
    penArmUi(r);
    const hist = smoothDrag("reapply-smooth-passes", "1", 20);
    const g1 = penMesh();
    assert(g1 != r.a0 && drag2 != g1 && drag2 != click2,
           "reapply-smooth-passes rig: the 5-pass strength-2 smooth must differ from g1 and from one pass");
    w("smoothStrength", "2");
    assert(penMesh() == drag2 && penHistoryLen() == hist + 1,
           format("reapply-smooth-passes w1: the mesh %s a fresh 5-pass strength-2 smooth (%s the 1-pass "
                  ~ "one), history %s", penMesh() == drag2 ? "==" : "!=",
                  penMesh() == click2 ? "==" : "!=", penHistoryLabels()));
    writeln("PASS reapply-smooth-passes");
}

// ===========================================================================
// offset-zero-exact — L24 (C0-N3): writes that bring the offset to 0 put the
// vertex back BIT-exact; each partial write re-snaps.
// ===========================================================================
unittest {
    if (!cell("offset-zero-exact")) return;
    const r = rig();
    penArmUi(r);
    const u5 = r.a0.pos[5];
    penGesture(penVertexPx(5, "offset-zero-exact v5"), 20 / kSp, 12 / kSp, 1, 0, "offset-zero-exact g1");
    const o1 = offs();
    assert(o1[0] != 0 && o1[1] != 0 && o1[2] != 0,
           format("offset-zero-exact g1: offsets %s (each channel must be non-zero)", fmt3(o1)));
    assert(dist3(nearestBG(u5), u5) > 1e-3,
           format("offset-zero-exact rig: u5 sits %.3g from the background (a re-snap must move it)",
                  dist3(nearestBG(u5), u5)));
    size_t n;
    foreach (k, a; ["offsetX", "offsetY"]) {
        w(a, "0");
        const m = penMesh();
        rawFloor("offset-zero-exact", carriedAt("offset-zero-exact w" ~ (k + 1).to!string, m, 5, u5, offs()));
        ++n;
    }
    w("offsetZ", "0");
    assert(offs() == [0.0, 0.0, 0.0] && penMesh() == r.a0 && penHistoryLen() == r.hp + 5,
           format("offset-zero-exact w3: offsets %s, v5 %s (expected u5 %s bit-exact), history %s",
                  fmt3(offs()), penMesh().pos[5], u5, penHistoryLabels()));
    assert(n == 2, "offset-zero-exact: partial writes checked " ~ n.to!string);
    writeln("PASS offset-zero-exact");
}

// ===========================================================================
// offset-came-home — §4.7 m0 / R1-7: an edge drag that comes back to the press
// pixel leaves the mesh as it was (a mesh diff is EMPTY), yet the press
// carried its set: the write re-places both endpoints.
// ===========================================================================
unittest {
    if (!cell("offset-came-home")) return;
    const r = rig();
    penArmUi(r);
    const e = penEdgePx(5, 6, "offset-came-home e56");
    const sp = penSpacingPx();
    string log = penMotion(20, e[0], e[1], 0, 0) ~ "\n" ~ penButton(40, true, 1, e[0], e[1], 0) ~ "\n";
    foreach (i; 1 .. 5)
        log ~= penMotion(40 + 40 * i, e[0] + cast(int)(0.3 * sp * i / 4), e[1], 1, 0) ~ "\n";
    log ~= penMotion(240, e[0] + 1, e[1], 1, 0) ~ "\n" ~ penButton(260, false, 1, e[0] + 1, e[1], 0);
    penPlay(log, "offset-came-home drag out and back");
    const g1 = penMesh();
    assert(g1 == r.a0 && penHistoryLen() == r.hp + 2 && stepKindNow() == 2 && offs() == [0.0, 0.0, 0.0],
           format("offset-came-home g1: mesh %s a0 (came home), history %s, kind %d, offsets %s (a "
                  ~ "click reads 0)", g1 == r.a0 ? "==" : "!=", penHistoryLabels(), stepKindNow(),
                  fmt3(offs())));
    reapplyCarried("offset-came-home", g1, 2, [5, 6], [r.a0.pos[5], r.a0.pos[6]], r.hp + 2);
}

// ===========================================================================
// offset-after-command — L58 (C6): a recording command ends the pen's gesture
// link. The Offset still reads the gesture's value; EVERY write after the
// command moves nothing and is one row — the second one too, though the first
// wrote a row of this session above the command (the link is cleared on first
// observation, not merely skipped). `mesh.flip` opens with a write of an
// attribute no step kind reads, so a guard that clears only on a READ name
// re-applies at the Offset write after it. Undoing the writes restores the
// gesture's descriptor (the clear is the write's own row). Our ladder differs
// from the reference's after the writes: the reference's restart writes its
// own activation step (popping it disarms with the command applied), ours keeps
// the pen armed with no row (L57), so our next Ctrl+Z pops the command — gap
// row (hh'').
// ===========================================================================
unittest {
    if (!cell("offset-after-command")) return;
    size_t ran;
    foreach (cmd; ["select.invert", "mesh.flip"]) {
        const id = "offset-after-command " ~ cmd;
        const r = rig();
        penArmUi(r);
        penGesture(penVertexPx(5, id ~ " v5"), 20 / kSp, 12 / kSp, 1, 0, id ~ " g1");
        const g1 = penMesh();
        const o1 = offs();
        const k1 = stepKindNow();
        penLineUi(cmd);
        const c = penMesh();
        assert(penArmed() && penHistoryLen() == r.hp + 3 && offs() == o1 && k1 == 1,
               format("%s: armed %s, history %s, offsets %s (expected g1's %s), g1 kind %d", id,
                      penArmed(), penHistoryLabels(), fmt3(offs()), fmt3(o1), k1));
        long h = r.hp + 3;
        string[] writes;
        if (cmd == "mesh.flip") writes ~= "showEdge false";
        writes ~= ["offsetX 0.1", "offsetX 0.15"];
        foreach (i, wr; writes) {
            import std.string : split;
            const kv = wr.split(" ");
            w(kv[0], kv[1]);
            at(id, format("w%d %s (moves nothing)", i + 1, wr), c, true, ++h);
            assert(stepKindNow() == 0, format("%s w%d: descriptor kind %d (expected cleared)",
                                              id, i + 1, stepKindNow()));
        }
        assert(abs(attrNum("offsetX") - 0.15) < 1e-6, id ~ ": offsetX did not read the writes");
        foreach_reverse (i, wr; writes) {
            z(format("%s z-w%d", id, i + 1));
            at(id, format("z-w%d", i + 1), c, true, --h);
        }
        assert(offs() == o1 && stepKindNow() == k1,
               format("%s writes undone: offsets %s kind %d, expected g1's %s kind %d", id,
                      fmt3(offs()), stepKindNow(), fmt3(o1), k1));
        z(id ~ " z-cmd (ours: the command)");
        at(id, "z-cmd", g1, true, r.hp + 2);
        z(id ~ " z-g1");
        at(id, "z-g1", r.a0, true, r.hp + 1);
        ++ran;
    }
    assert(ran == 2, "offset-after-command: commands run " ~ ran.to!string);
    writeln("PASS offset-after-command");
}

// ===========================================================================
// drag-poly-offcentre — L28 (C1-O2b): a polygon pressed OFF its centroid; the
// centroid follows the cursor's screen DELTA (G-delta), not the cursor.
// ===========================================================================
unittest {
    if (!cell("drag-poly-offcentre")) return;
    const r = rig();
    penArmUi(r);
    double[3] c = [0, 0, 0];
    foreach (v; [5, 6, 9, 10]) c = add3(c, r.a0.pos[v]);
    c = [c[0] / 4, c[1] / 4, c[2] / 4];
    const pc = projectF(c), p5 = projectF(r.a0.pos[5]);
    const int[2] press = [cast(int)round(pc[0] + 0.35 * (p5[0] - pc[0])),
                          cast(int)round(pc[1] + 0.35 * (p5[1] - pc[1]))];
    const s = penSpacingPx() / kSp;
    const double ddx = round(20 * s), ddy = round(12 * s);
    const int[2] rel = [press[0] + cast(int)ddx, press[1] + cast(int)ddy];
    penPlay(penGestureEvents(press[0], press[1], rel[0], rel[1], 1, 0, 8), "drag-poly-offcentre g1");
    const g1 = penMesh();
    const o = offs();
    assert(penMoved(g1, r.a0) == [5L, 6, 9, 10] && stepKindNow() == 3,
           format("drag-poly-offcentre g1: moved %s, kind %d (expected the polygon)",
                  penIdx(penMoved(g1, r.a0)), stepKindNow()));
    const t = add3(c, o);
    const pt = projectF(t);
    const dDelta = hypot(pt[0] - (pc[0] + ddx), pt[1] - (pc[1] + ddy));
    const dCursor = hypot(pt[0] - rel[0], pt[1] - rel[1]);
    assert(dist3(nearestBG(t), t) <= 1e-5 && dDelta <= 1.0 && dCursor >= 8.0,
           format("drag-poly-offcentre: centroid + offset %s is %.3g off the background, %.2f px from "
                  ~ "proj(centroid) + drag (G-delta, max 1) and %.2f px from the release (G-cursor, "
                  ~ "min 8)", t, dist3(nearestBG(t), t), dDelta, dCursor));
    double raw = 0;
    foreach (v; [5L, 6, 9, 10]) {
        const d = carriedAt("drag-poly-offcentre", g1, v, r.a0.pos[cast(size_t)v], o);
        if (d > raw) raw = d;
    }
    rawFloor("drag-poly-offcentre", raw);
    writeln(format("drag-poly-offcentre: G-delta %.2f px, G-cursor %.2f px", dDelta, dCursor));
    writeln("PASS drag-poly-offcentre");
}

// ===========================================================================
// offsets-live-edge / -loop — L18 (moved here from the S7a file): an edge or a
// loop Move reports the G-delta offset of the PRESSED element's anchor (the
// edge's midpoint; the pressed edge's, not the loop's): anchor + offset is ON
// the background under proj(anchor) + drag, and every carried vertex sits at
// nearestBG(u_i + offset). The loop writes it live while held and the release
// re-derives it at its own pixel.
// ===========================================================================

/// anchor + o: on the background (1e-5) and under proj(anchor) + (dx, dy) (1 px).
void gDeltaAt(string id, double[3] anchor, double[3] o, double dx, double dy, float[2] pa) {
    const t = add3(anchor, o);
    const pt = projectF(t);
    const d = hypot(pt[0] - (pa[0] + dx), pt[1] - (pa[1] + dy));
    assert(len3(o) > 1e-3 && dist3(nearestBG(t), t) <= 1e-5 && d <= 1.0,
           format("%s: anchor + offset %s is %.3g off the background and %.2f px from proj(anchor) + drag "
                  ~ "(max 1e-5, 1 px)", id, t, dist3(nearestBG(t), t), d));
}

unittest {
    if (!cell("offsets-live-edge")) return;
    const r = rig();
    penArmUi(r);
    const double[3] mid = [(r.a0.pos[5][0] + r.a0.pos[6][0]) / 2, (r.a0.pos[5][1] + r.a0.pos[6][1]) / 2,
                           (r.a0.pos[5][2] + r.a0.pos[6][2]) / 2];
    const pa = projectF(mid);
    const e = penEdgePx(5, 6, "offsets-live-edge e56");
    const sp = penSpacingPx() / kSp;
    const int dx = cast(int)round(20 * sp), dy = cast(int)round(12 * sp);
    penPlay(penGestureEvents(e[0], e[1], e[0] + dx, e[1] + dy, 1, 0, 8), "offsets-live-edge drag");
    const g1 = penMesh();
    const o = offs();
    assert(penMoved(g1, r.a0) == [5L, 6L], format("offsets-live-edge: moved %s", penIdx(penMoved(g1, r.a0))));
    gDeltaAt("offsets-live-edge", mid, o, dx, dy, pa);
    double raw = 0;
    foreach (v; [5L, 6]) {
        const d = carriedAt("offsets-live-edge", g1, v, r.a0.pos[cast(size_t)v], o);
        if (d > raw) raw = d;
    }
    rawFloor("offsets-live-edge", raw);
    writeln("PASS offsets-live-edge");
}

unittest {
    if (!cell("offsets-live-loop")) return;
    const r = rig();
    penArmUi(r);
    const double[3] mid = [(r.a0.pos[5][0] + r.a0.pos[6][0]) / 2, (r.a0.pos[5][1] + r.a0.pos[6][1]) / 2,
                           (r.a0.pos[5][2] + r.a0.pos[6][2]) / 2];
    const pa = projectF(mid);
    const from = penEdgePx(5, 6, "offsets-live-loop e56");
    const sp = penSpacingPx() / kSp;
    string log = penMotion(20, from[0], from[1], 0, 0) ~ "\n"
               ~ penButton(40, true, 3, from[0], from[1], 0) ~ "\n";
    int y = from[1];
    foreach (i; 1 .. 7) {
        y = from[1] - cast(int)(15 * sp * i / 6);
        log ~= penMotion(40 + 40 * i, from[0], y, penButtonMask(3), 0) ~ "\n";
    }
    penPlay(log, "offsets-live-loop: held loop drag");
    const oHeld = offs();
    assert(penMesh() == r.a0, "offsets-live-loop held: the deferred loop moved before its release");
    gDeltaAt("offsets-live-loop held", mid, oHeld, 0, y - from[1], pa);
    penPlay(penButton(20, false, 3, from[0], y - 6, 0), "offsets-live-loop release");
    const g1 = penMesh();
    const o = offs();
    const moved = penMoved(g1, r.a0);
    assert(moved.length == 4 && moved.canFind(5L) && moved.canFind(6L) && o != oHeld,
           format("offsets-live-loop: the loop moved %s, offsets %s (held %s)", penIdx(moved), fmt3(o),
                  fmt3(oHeld)));
    gDeltaAt("offsets-live-loop", mid, o, 0, y - 6 - from[1], pa);
    double raw = 0;
    foreach (v; moved) {
        const d = carriedAt("offsets-live-loop", g1, v, r.a0.pos[cast(size_t)v], o);
        if (d > raw) raw = d;
    }
    rawFloor("offsets-live-loop", raw);
    writeln("PASS offsets-live-loop");
}

// ===========================================================================
// The edge slide over a background (L47/L50, §9.26.3): one world channel,
// latched once the cursor path reaches 4.5 px, a tie -> the later axis.
// ===========================================================================

/// The capture harness's 2-px increments of a drag (accumulated rounding,
/// round-half-even as Python's `round`): the cumulative points.
int[2][] bresenham(int dx, int dy) {
    const n = cast(int)lrint(hypot(cast(double)dx, cast(double)dy) / 2.0) < 1
        ? 1 : cast(int)lrint(hypot(cast(double)dx, cast(double)dy) / 2.0);
    int[2][] pts;
    foreach (i; 1 .. n + 1)
        pts ~= [cast(int)lrint(cast(double)dx * i / n), cast(int)lrint(cast(double)dy * i / n)];
    assert(pts[$ - 1] == [dx, dy]);
    return pts;
}

struct SlidePrediction { int latch, wTotal, wFirst, latchAnchorForm; double latchMargin; }

/// The axis of `d` with the kernel's rule (eps relative, a tie -> later axis).
int axisOf(double[3] d, double eps) {
    int best = 0;
    foreach (k; 1 .. 3) {
        const a = abs(d[k]), b = abs(d[best]);
        if (a > b || abs(a - b) <= eps * (a > b ? a : b)) best = k;
    }
    return best;
}

/// Predict the slide's axis under OUR viewport from the cumulative points:
/// the latch (first point at >= 4.5 px of path), W-total and W-first.
SlidePrediction predict(double[3] anchor, const int[2][] pts) {
    const q = projectF(anchor);
    double[3] h0;
    assert(bgHit(q[0], q[1], h0), "slide prediction: the anchor's pixel misses the background");
    double[3] dAt(int[2] p) {
        double[3] h;
        assert(bgHit(q[0] + p[0], q[1] + p[1], h), format("slide prediction: %s misses", p));
        return sub3(h, h0);
    }
    SlidePrediction r;
    r.latch = -1;
    double path = 0;
    int[2] prev = [0, 0];
    foreach (p; pts) {
        path += hypot(cast(double)(p[0] - prev[0]), cast(double)(p[1] - prev[1]));
        prev = p;
        if (path >= 4.5) {
            const d = dAt(p);
            r.latch = axisOf(d, 1e-3);
            // The rival delta convention ([A12-1] rejects it for the axis):
            // hit(proj(anchor) + drag) - anchor.
            r.latchAnchorForm = axisOf(add3(d, sub3(h0, anchor)), 1e-3);
            const a = abs(d[0]), b = abs(d[1]);
            r.latchMargin = abs(a - b) / (a > b ? a : b);
            break;
        }
    }
    r.wTotal = axisOf(dAt(pts[$ - 1]), 0);
    r.wFirst = axisOf(dAt(pts[0]), 0);
    return r;
}

/// Ctrl+LMB on the edge (a, b) midpoint, one motion per cumulative point, the
/// release at the last; returns the offset (WORLD, via the layer's rotation
/// about Z by `rotZ` degrees) after asserting the moved endpoints.
double[3] slideAlong(string id, const PenMesh a0, long a, long b, const int[2][] pts, double rotZ = 0,
                     int[2] overshoot = [0, 0]) {
    const e = penEdgePx(a, b, id ~ " edge");
    string log = penMotion(20, e[0], e[1], 0, PEN_KMOD_LCTRL) ~ "\n"
               ~ penButton(40, true, 1, e[0], e[1], PEN_KMOD_LCTRL) ~ "\n";
    double t = 40;
    foreach (p; pts) {
        t += 10;
        log ~= penMotion(t, e[0] + p[0], e[1] + p[1], 1, PEN_KMOD_LCTRL) ~ "\n";
    }
    log ~= penButton(t + 10, false, 1, e[0] + pts[$ - 1][0] + overshoot[0],
                     e[1] + pts[$ - 1][1] + overshoot[1], PEN_KMOD_LCTRL);
    const hp = penHistoryLen();
    penPlay(log, id);
    const m = penMesh();
    assert(penMoved(m, a0) == [a, b] && penHistoryLen() == hp + 1 && stepKindNow() == 5,
           format("%s: moved %s (expected [%d,%d]), history %s, kind %d", id, penIdx(penMoved(m, a0)),
                  a, b, penHistoryLabels(), stepKindNow()));
    const ol = offs();
    const c = cos(rotZ * PI / 180), sn = sin(rotZ * PI / 180);
    const double[3] ow = [c * ol[0] - sn * ol[1], sn * ol[0] + c * ol[1], ol[2]];
    return ow;
}

/// One non-zero WORLD channel, the axis `axis`.
void oneChannel(string id, double[3] ow, int axis) {
    size_t big;
    foreach (k; 0 .. 3) if (abs(ow[k]) > 1e-6) ++big;
    assert(big == 1 && abs(ow[axis]) > 1e-3,
           format("%s: the world offset %s is not one channel along axis %d", id, fmt3(ow), axis));
}

unittest {
    if (!cell("drag-slide-dir")) return;
    // The turned rig (C2-S1dir-r): the grid turned 30 degrees about world Z,
    // e56 at 30 degrees; drag (-7, -39) capture px, world 100 degrees -> Y.
    {
        const r = rig();
        penArmUi(r);
        auto lt = penPost("/api/command", "layer.attr 0 rot.z 30");
        assert(lt["status"].str == "ok", "drag-slide-dir turned: layer.attr failed: " ~ lt.toString);
        const s = penSpacingPx() / kSp;
        const ow = slideAlong("drag-slide-dir turned", r.a0, 5, 6,
                              bresenham(cast(int)round(-7 * s), cast(int)round(-39 * s)), 30);
        oneChannel("drag-slide-dir turned", ow, 1);
        // Both endpoints at nearestBG(u_i + offset), in world.
        const m = penMesh();
        const c = cos(PI / 6), sn = sin(PI / 6);
        double[3] wld(double[3] l) { return [c * l[0] - sn * l[1], sn * l[0] + c * l[1], l[2]]; }
        foreach (v; [5, 6]) {
            const want = nearestBG(add3(wld(r.a0.pos[v]), ow));
            assert(dist3(wld(m.pos[v]), want) <= 1e-6,
                   format("drag-slide-dir turned: v%d %s is not nearestBG(u + offset) %s", v,
                          wld(m.pos[v]), want));
        }
    }
    // The orbited camera (C3-S1dir-o): e(13,14), screen-right -> world Y.
    {
        const r = rig();
        penArmUi(r);
        auto cam = lawsFx()["cells"]["chord-slide-vertex-orbit"]["gesture"]["camera"];
        double[] o;
        foreach (k; ["right", "up", "back"]) foreach (x; cam[k].array) o ~= penNum(x);
        penPost("/api/camera", format(`{"orientation":[%(%.17g,%)],"distance":%.17g,`
                                      ~ `"focus":{"x":0,"y":0,"z":0}}`, o, penNum(cam["distance"])));
        const vp = viewportFromCameraMatrices();
        const s = vp.proj[5] * vp.height / 2 / penNum(cam["focalPx"]);
        const ow = slideAlong("drag-slide-dir orbited", r.a0, 13, 14, bresenham(cast(int)round(70 * s), 0));
        oneChannel("drag-slide-dir orbited", ow, 1);
        assert(ow[1] > 0, format("drag-slide-dir orbited: Y %s, expected positive", ow[1]));
    }
    writeln("PASS drag-slide-dir");
}

/// The front-grid slide cells at the capture's spacing (so its pixel paths
/// replay as driven): e56's midpoint, the per-candidate predictions printed.
void frontSlide(string id, const int[2][] pts, int expect, int mustDifferFrom, string rival,
                int[2] overshoot = [0, 0], string rigPath = "") {
    const r = rigPath.length ? penRigLoad(rigPath) : rig();
    penArmUi(r);
    penZoomToSpacing(kSp, id);
    const double[3] anchor = [(r.a0.pos[5][0] + r.a0.pos[6][0]) / 2, (r.a0.pos[5][1] + r.a0.pos[6][1]) / 2,
                              (r.a0.pos[5][2] + r.a0.pos[6][2]) / 2];
    const pr = predict(anchor, pts);
    writeln(format("%s: our viewport predicts latch %s (X/Y margin %.3g), W-total %s, W-first %s, E-perp Y",
                   id, "XYZ"[pr.latch], pr.latchMargin, "XYZ"[pr.wTotal], "XYZ"[pr.wFirst]));
    const int rv = rival == "W-total" ? pr.wTotal : rival == "W-first" ? pr.wFirst
                 : rival == "anchor-form" ? pr.latchAnchorForm : 1;
    assert(pr.latch == expect && rv == mustDifferFrom,
           format("%s rig: the latch predicts %s (expected %s) and the rival %s %s (expected %s) — the "
                  ~ "cell would not discriminate", id, "XYZ"[pr.latch], "XYZ"[expect], rival, "XYZ"[rv],
                  "XYZ"[mustDifferFrom]));
    const ow = slideAlong(id, r.a0, 5, 6, pts, 0, overshoot);
    oneChannel(id, ow, expect);
    // The magnitude: the L28 offset at the RELEASE's own pixel (M-hit, gap row
    // (q)), hit(proj(anchor) + drag) - anchor, on the latched axis.
    const q = projectF(anchor);
    double[3] hr;
    assert(bgHit(q[0] + pts[$ - 1][0] + overshoot[0], q[1] + pts[$ - 1][1] + overshoot[1], hr),
           id ~ ": the release pixel misses the background");
    const want = hr[expect] - anchor[expect];
    assert(abs(ow[expect] - want) <= 1e-5,
           format("%s: the offset %s on axis %d is not the release's G-delta %.7g", id, fmt3(ow), expect, want));
    writeln("PASS ", id);
}

unittest {
    // C4-S1dir-f: a straight (30, -10): X by the latch, E-perp's Y refuted.
    // The release lands 6 px past the last motion: its own pixel decides.
    if (cell("drag-slide-f")) frontSlide("drag-slide-f", bresenham(30, -10), 0, 1, "E-perp", [6, 0]);
}

unittest {
    // C4-S1dir-L: 20 x (+2, 0) then 63 x (0, +2); W-total reads Y, the latch X.
    if (!cell("drag-slide-L")) return;
    int[2][] pts;
    foreach (i; 1 .. 21) pts ~= [2 * i, 0];
    foreach (i; 1 .. 64) pts ~= [40, 2 * i];
    frontSlide("drag-slide-L", pts, 0, 1, "W-total");
}

unittest {
    // C4-S1dir-tie: (30, -27) by the harness's 2-px steps — (2,-1), (3,-3),
    // (4,-4): the latch fires at (4,-4), 5.886 px of path, an X/Y tie -> Y;
    // a latch at the first sample (2,-1) reads X.
    if (cell("drag-slide-tie")) frontSlide("drag-slide-tie", bresenham(30, -27), 1, 0, "W-first");
}

unittest {
    // [A12-1]: the axis comes from the SURFACE delta hit(proj(anchor) + drag) -
    // hit(proj(anchor)), never from hit(...) - anchor. On the capture rig the
    // grid lies ON the sphere, where the two forms agree; here the grid is
    // lifted 0.3 off it toward the camera, so the anchor form reads the lift
    // (Z) while the surface delta of C4-S1dir-f's drag reads X.
    if (!cell("drag-slide-offsurface")) return;
    import std.file : tempDir, write, remove;
    import std.process : thisProcessID;
    auto doc = parseJSON(readText(rigFile("topology_pen_session_rig.v3d")));
    foreach (ref v; doc["layers"].array[0]["mesh"]["vertices"].array)
        v.array[2] = JSONValue(penNum(v.array[2]) + 0.3);
    const path = buildPath(tempDir, format("pen_offsurface_rig_%d.v3d", thisProcessID));
    write(path, doc.toString);
    scope (exit) remove(path);
    frontSlide("drag-slide-offsurface", bresenham(30, -10), 0, 2, "anchor-form", [0, 0], path);
}

// The population: every cell above ran when none was selected.
unittest {
    if (environment.get("VIBE3D_CELL", "").length) return;
    assert(cellsRun == 30, format("offset laws: %d cells ran, expected 30", cellsRun));
}
