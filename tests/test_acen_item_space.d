// The action centre, its basis, and the geometry they move — in the space the
// mesh is DRAWN in, not the space it is STORED in.  (Task 0649.)
//
// ── WHAT IS PINNED ─────────────────────────────────────────────────────────
//
// A layer carries an item transform.  Its mesh is stored in the layer's own
// coordinates and drawn through that transform, so there are two spaces, and
// the transform pipe has to be explicit about which one it is in.  The
// measured answer (task 0648, frozen into `tests/fixtures/acen_item_space.json`)
// is:
//
//   * the action centre is published as a WORLD point, and the bounding box it
//     comes from is taken AFTER the item matrix, over world vertices;
//   * the axis frame is derived from those same world points;
//   * the apply path converts the world centre into the LAYER's coordinates
//     before it moves a vertex.
//
// ── WHY THE PUBLISHED TRIPLE IS NOT ENOUGH, AND WHAT CARRIES THE CLAIM ─────
//
// `origin` prints (0,0,0) on both engines and means the WORLD origin on one
// and the ITEM origin on the other; `pivot` prints the item's world pivot on
// both and is consumed as a layer-space point on one of them.  Any assertion
// on those two published triples scores a match and measures nothing.  So the
// space claim is carried by the INDIRECT leg — a numeric uniform scale, and
// the pivot it actually used, solved out of the moved LAYER-SPACE vertices.
// Those three modes are each other's controls: `select`, `origin` and `pivot`
// pivot about three different points by construction, so "the apply ignores
// the centre" cannot pass as three identical rows.
//
// The published triple IS asserted for the modes where the two candidate
// readings print DIFFERENT numbers (`select` / `border` / `selectauto` /
// `local`), and there it also has to refuse a second, plausible-but-wrong
// reading by name: "take our layer-space bbox mid and lift it into world".
// That answers (-0.426891, 2.542190, -0.239870) on the rotated stand where the
// measurement says (-0.400741, 2.457024, -0.236448) — 0.0852 apart, which is
// forty times the tolerance below.  (The capture recorded this candidate as
// (-0.9381, 1.4861, -1.9010); that number came from the ORIGINAL euler triple
// rather than the equivalence-solved one the compared cells used.  See
// `correctionToTheCapture` in the fixture: the capture's CONCLUSION stands,
// its margin was an order of magnitude too large.)
//
// ── WHAT IS DELIBERATELY NOT PINNED HERE ───────────────────────────────────
//
// The basis assertion is on the FRAME, not on the slot assignment: it asserts
// that the reference's `right` and `up` directions are the two in-plane axes
// we publish, without asserting WHICH of our two slots each landed in.  One
// thing remains unsettled and is recorded rather than fitted: which box row
// becomes the packet's `right`.  The reference's tail is not read
// (`toolpipe.obbox.axisFrameFromBox` says so in its own header), and the
// frozen numbers do not decide it either.
//
// The other item that used to stand here — the covariance DIVISOR — was
// closed by task 0658, and the tolerance below is deliberately NOT tightened
// to chase it.  This test is about the SPACE the box is built in; the divisor
// is arithmetic inside the box and is asserted at 1e-5, two orders tighter,
// by `tests/test_obb_covariance_divisor.d`.  Conflating the two would make a
// failure here ambiguous between "the frame moved to the wrong space" and
// "a digit of the covariance moved".
//
// So the tolerance below is 2e-3, and it is not slack: the two readings this
// test separates are ~68 degrees apart (measured: 0.895 vs 0.99993 on the
// discriminating stand), which is four hundred times the tolerance.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, fabs, sqrt;
import std.format : format;
import std.file   : readText;
import std.algorithm : max;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert("status" !in r || r["status"].str != "error",
           format("command %s failed: %s", argstring, r.toString()));
}

// --------------------------------------------------------------------------
// The frozen fixture.
// --------------------------------------------------------------------------
JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/acen_item_space.json"));
        loaded = true;
    }
    return cached;
}

double[3] vec3Of(JSONValue j) {
    double[3] v;
    foreach (i; 0 .. 3) {
        auto e = j.array[i];
        v[i] = (e.type == JSONType.integer) ? cast(double) e.integer
             : (e.type == JSONType.uinteger) ? cast(double) e.uinteger
                                             : e.floating;
    }
    return v;
}

double maxAbsDiff(double[3] a, double[3] b) {
    double m = 0;
    foreach (i; 0 .. 3) m = max(m, fabs(a[i] - b[i]));
    return m;
}
double dot3(double[3] a, double[3] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
string fmt3(double[3] v) {
    return format("(%.6f, %.6f, %.6f)", v[0], v[1], v[2]);
}

// --------------------------------------------------------------------------
// The stand, driven over HTTP exactly as the capture drove it.
// --------------------------------------------------------------------------
void buildStand(string itemTransform) {
    auto fx = fixture();
    postJson("/api/reset", "{}");

    string verts = "[";
    foreach (i, v; fx["stand"]["vertices"].array) {
        auto p = vec3Of(v);
        verts ~= (i ? "," : "") ~ format("[%g,%g,%g]", p[0], p[1], p[2]);
    }
    verts ~= "]";
    string faces = "[";
    foreach (i, f; fx["stand"]["faces"].array) {
        faces ~= (i ? ",[" : "[");
        foreach (k, vi; f.array) faces ~= (k ? "," : "") ~ vi.integer.to!string;
        faces ~= "]";
    }
    faces ~= "]";
    auto lm = postJson("/api/command", commandBody("scene.loadMesh", format(`{"vertices":%s,"faces":%s}`, verts, faces)));
    assert(lm["status"].str == "ok", "load-mesh failed: " ~ lm.toString());

    auto xf = fx["itemTransforms"][itemTransform];
    static immutable string[3] axes = ["x", "y", "z"];
    foreach (chan; ["pos", "rot", "scl"]) {
        auto vals = vec3Of(xf[chan]);
        foreach (i; 0 .. 3)
            cmd(format("layer.attr 0 %s.%s %.10g", chan, axes[i], vals[i]));
    }
    postJson("/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`,
                    fx["stand"]["selectedFace"].integer)));
}

struct Frame { double[3] center, right, up, fwd; }

Frame readFrame() {
    auto j = getJson("/api/toolpipe");
    string[string] acen, axis;
    foreach (st; j["stages"].array) {
        if (st["task"].str == "ACEN")
            foreach (k, v; st["attrs"].object) acen[k] = v.str;
        else if (st["task"].str == "AXIS")
            foreach (k, v; st["attrs"].object) axis[k] = v.str;
    }
    assert(acen.length > 0 && axis.length > 0,
           "ACEN / AXIS stage missing from /api/toolpipe");
    Frame f;
    f.center = [acen["cenX"].to!double, acen["cenY"].to!double,
                acen["cenZ"].to!double];
    f.right  = [axis["rightX"].to!double, axis["rightY"].to!double,
                axis["rightZ"].to!double];
    f.up     = [axis["upX"].to!double, axis["upY"].to!double,
                axis["upZ"].to!double];
    f.fwd    = [axis["fwdX"].to!double, axis["fwdY"].to!double,
                axis["fwdZ"].to!double];
    return f;
}

Frame armAndRead(string itemTransform, string mode) {
    buildStand(itemTransform);
    cmd("tool.set move");
    cmd("actr." ~ mode);
    return readFrame();
}

double[][] modelVertices() {
    auto j = getJson("/api/model");
    double[][] outV;
    foreach (v; j["vertices"].array) {
        auto p = vec3Of(v);
        outV ~= [p[0], p[1], p[2]];
    }
    return outV;
}

// ==========================================================================
// 1. THE CENTRE, where the two readings print different numbers.
// ==========================================================================
unittest { // ...and it refuses the OTHER plausible reading, computed here.
    // "Take our layer-space answer and lift it into world" is the obvious fix
    // and it is a DIFFERENT LAW, not a rounding difference: the box of the
    // transformed points is not the transform of the box. The candidate is
    // recomputed from the fixture's OWN matrix and stand rather than read as a
    // frozen constant, so it cannot drift away from the stand it describes —
    // which is exactly what happened to the capture's own record of it (see
    // `correctionToTheCapture` in the fixture).
    auto fx   = fixture();
    auto ref_ = fx["refutedCentreCandidate"];
    string xf = ref_["itemTransform"].str;

    // layer-space bbox mid of the selected face, then M applied to it.
    auto stand = fx["stand"];
    auto face  = stand["faces"].array[stand["selectedFace"].integer];
    double[3] mn = [ 1e30,  1e30,  1e30];
    double[3] mx = [-1e30, -1e30, -1e30];
    foreach (viJ; face.array) {
        auto v = vec3Of(stand["vertices"].array[viJ.integer]);
        foreach (c; 0 .. 3) {
            if (v[c] < mn[c]) mn[c] = v[c];
            if (v[c] > mx[c]) mx[c] = v[c];
        }
    }
    double[3] localMid;
    foreach (c; 0 .. 3) localMid[c] = (mn[c] + mx[c]) * 0.5;

    double[16] m;
    foreach (i, e; fx["itemTransforms"][xf]["matrix"].array)
        m[i] = (e.type == JSONType.integer) ? cast(double) e.integer
             : (e.type == JSONType.uinteger) ? cast(double) e.uinteger
                                             : e.floating;
    double[3] lifted;   // column-major: p_world = M * p_local
    foreach (r; 0 .. 3)
        lifted[r] = m[r] * localMid[0] + m[4 + r] * localMid[1]
                  + m[8 + r] * localMid[2] + m[12 + r];

    // The fixture's recorded value and the recomputation must agree — if they
    // ever stop, one of the two has been edited without the other.
    auto recorded = vec3Of(ref_["value"]);
    assert(maxAbsDiff(lifted, recorded) < 1e-5,
        format("the refuted candidate recorded in the fixture (%s) is not what "
             ~ "this file's own %s matrix produces from the layer-space bbox "
             ~ "mid (%s) — one of the two was edited alone",
               fmt3(recorded), xf, fmt3(lifted)));

    auto got = armAndRead(xf, ref_["mode"].str);
    assert(maxAbsDiff(got.center, lifted) > 0.02,
        format("ACEN centre landed on the REFUTED candidate %s (published %s).\n"
             ~ "  That is the item matrix applied to the LAYER-space "
             ~ "bounding-box mid. The measurement says the box itself is taken "
             ~ "over WORLD vertices; the two are %.4f apart on this stand, "
             ~ "which is what lets this assertion tell them apart. The fix is "
             ~ "in the ORDER of operations, not in a final transform.",
               fmt3(lifted), fmt3(got.center),
               ref_["separationFromMeasured"].floating));
}

unittest {
    auto fx  = fixture();
    double tol = fx["tolerance"].floating;
    int checked = 0;
    foreach (cell; fx["cells"].array) {
        string mode = cell["mode"].str;
        // `origin` / `pivot` / `parent` publish the same triple under both
        // readings on this stand — asserting them here would be inert. They
        // are carried by the indirect leg below instead.
        if (mode != "select" && mode != "border"
            && mode != "selectauto" && mode != "local") continue;
        string xf = cell["itemTransform"].str;
        auto got  = armAndRead(xf, mode);
        auto want = vec3Of(cell["center"]);
        assert(maxAbsDiff(got.center, want) < tol,
            format("ACEN centre, item=%s mode=%s: published %s, measured %s.\n"
                 ~ "  The centre is a WORLD point and its bounding box is taken "
                 ~ "AFTER the item matrix. A layer-space answer here means the "
                 ~ "producers in actcenter.d stopped carrying itemSpace().",
                   xf, mode, fmt3(got.center), fmt3(want)));
        ++checked;
    }
    assert(checked == 20,
        format("expected 20 comparable centre cells (4 modes x 5 item "
             ~ "transforms), walked %d — the fixture changed shape", checked));
}

// ==========================================================================
// 2. THE BASIS, on the stand built to make the two readings disagree.
// ==========================================================================
unittest {
    auto fx   = fixture();
    double tol = fx["tolerance"].floating;
    // Both stands where a layer-derived frame and a world-derived one elect
    // DIFFERENT axes: the non-uniform scale inverts the selected face's
    // largest-extent axis, and the rotation turns the whole frame.
    foreach (xf; ["S_scale", "R_rotate", "A_all"]) {
        JSONValue cell;
        bool found = false;
        foreach (c; fx["cells"].array)
            if (c["itemTransform"].str == xf && c["mode"].str == "select") {
                cell = c; found = true; break;
            }
        assert(found, "fixture has no select cell for " ~ xf);

        auto got  = armAndRead(xf, "select");
        auto wR   = vec3Of(cell["right"]);
        auto wU   = vec3Of(cell["up"]);
        auto wF   = vec3Of(cell["fwd"]);

        // The published frame must CONTAIN each measured in-plane direction.
        // Which of our two slots it landed in is the unread row-to-slot tail
        // (obbox.axisFrameFromBox) and is deliberately not asserted.
        double hitR = max(fabs(dot3(got.right, wR)), fabs(dot3(got.up, wR)));
        double hitU = max(fabs(dot3(got.right, wU)), fabs(dot3(got.up, wU)));
        assert(hitR > 1.0 - tol,
            format("AXIS basis, item=%s: the measured `right` %s is not one of "
                 ~ "the two in-plane axes we publish (r=%s, u=%s); best "
                 ~ "alignment %.6f.\n"
                 ~ "  A layer-derived frame reads ~0.895 here — that is the "
                 ~ "failure this number is shaped to catch. The frame is the "
                 ~ "oriented box of the WORLD points (axis.d "
                 ~ "computeSelectionBboxBasis).",
                   xf, fmt3(wR), fmt3(got.right), fmt3(got.up), hitR));
        assert(hitU > 1.0 - tol,
            format("AXIS basis, item=%s: the measured `up` %s is not one of the "
                 ~ "two in-plane axes we publish; best alignment %.6f",
                   xf, fmt3(wU), hitU));
        // `fwd` IS slot-pinned: it is the box's thinnest row on both sides,
        // and on a planar selection it is the face normal — which the
        // reference carries through the layer's 3x3 (inverse-transpose), not
        // through the point transform.
        assert(fabs(fabs(dot3(got.fwd, wF)) - 1.0) < 3e-3,
            format("AXIS fwd, item=%s: published %s, measured %s. The selection "
                 ~ "normal must be carried into world by the NORMAL rule, not "
                 ~ "the point rule.", xf, fmt3(got.fwd), fmt3(wF)));
    }
}

unittest { // The stand really does separate the two readings — anti-vacuity.
    // If the item scale did NOT invert the largest-extent axis, the basis
    // assertion above would hold for a layer-derived frame too and would be
    // measuring nothing. This asserts the property the stand was built for,
    // from the fixture's own numbers: the identity frame and the scaled frame
    // must be far apart.
    auto e = armAndRead("E_identity", "select");
    auto s = armAndRead("S_scale",    "select");
    double best = max(fabs(dot3(e.right, s.right)), fabs(dot3(e.right, s.up)));
    // e.right IS one of the identity frame's in-plane axes; under the scale
    // the world-derived pair rotates ~68 degrees away from it.
    assert(best < 0.99,
        format("the stand no longer discriminates: the identity frame's "
             ~ "`right` %s is still one of the scaled frame's in-plane axes "
             ~ "(alignment %.6f). The non-uniform item scale is supposed to "
             ~ "INVERT the selected face's largest-extent axis; without that, "
             ~ "the basis test above passes under either reading.",
               fmt3(e.right), best));
}

// ==========================================================================
// 3. THE GEOMETRY — the leg the published triple cannot carry.
// ==========================================================================
//
// Apply a numeric uniform scale about each mode's centre and solve, from the
// moved LAYER-SPACE vertices, for the pivot it actually used. The three modes
// are each other's controls.
unittest {
    auto fx   = fixture();
    double tol = fx["tolerance"].floating;
    auto ind  = fx["indirect"];
    string xf = ind["itemTransform"].str;
    double k  = ind["effectiveFactor"].floating;

    double[3][] solved;
    foreach (row; ind["cells"].array) {
        string mode = row["mode"].str;
        buildStand(xf);
        auto before = modelVertices();
        cmd("tool.set TransformScale");
        foreach (a; ["SX", "SY", "SZ"])
            cmd(format("tool.attr TransformScale %s %g", a, k));
        cmd("actr." ~ mode);
        cmd("tool.doApply");
        auto after = modelVertices();
        assert(before.length == after.length && before.length > 0,
               "vertex count changed under a scale");

        // v' = p + k (v - p)  =>  p = (v' - k v) / (1 - k), per axis, from any
        // vertex that actually moved. Solved rather than asserted so a wrong
        // pivot is REPORTED as a point instead of as "some vertex differs".
        bool any = false;
        double[3] p;
        foreach (i; 0 .. before.length) {
            double d = 0;
            foreach (c; 0 .. 3) d = max(d, fabs(after[i][c] - before[i][c]));
            if (d < 1e-6) continue;
            foreach (c; 0 .. 3)
                p[c] = (after[i][c] - k * before[i][c]) / (1.0 - k);
            any = true;
            break;
        }
        assert(any,
            format("mode %s moved NOTHING — a vacuous pass. The scale must "
                 ~ "actually run for this row to say anything.", mode));

        // Every moved vertex must agree with that one pivot, or the motion was
        // not a scale about a single point at all.
        foreach (i; 0 .. before.length) {
            double d = 0;
            foreach (c; 0 .. 3) d = max(d, fabs(after[i][c] - before[i][c]));
            if (d < 1e-6) continue;
            foreach (c; 0 .. 3) {
                double want = p[c] + k * (before[i][c] - p[c]);
                assert(fabs(after[i][c] - want) < 1e-4,
                    format("mode %s, vertex %d axis %d: %.6f, expected %.6f "
                         ~ "for a uniform scale about %s",
                           mode, i, c, after[i][c], want, fmt3(p)));
            }
        }

        auto want = vec3Of(row["pivotInLayerSpace"]);
        assert(maxAbsDiff(p, want) < tol,
            format("apply pivot in LAYER space, item=%s mode=%s: used %s, "
                 ~ "measured %s.\n"
                 ~ "  This is the leg the published triple cannot carry: both "
                 ~ "engines print the same centre for `origin` and for `pivot` "
                 ~ "and mean different points. If `origin` reads (0,0,0) and "
                 ~ "`pivot` reads (5,-2,3) here, the apply path is consuming "
                 ~ "the WORLD centre as if it were layer-local — the "
                 ~ "conversion in XfrmTransformTool.applyFold is missing.",
                   xf, mode, fmt3(p), fmt3(want)));
        solved ~= p;
    }

    // The controls: three modes, three DIFFERENT pivots. If the apply ignored
    // the action centre entirely, every row above would still solve — to the
    // same point three times.
    assert(solved.length == 3, "expected three indirect rows");
    foreach (i; 0 .. solved.length)
        foreach (j; i + 1 .. solved.length)
            assert(maxAbsDiff(solved[i], solved[j]) > 0.5,
                format("indirect rows %d and %d solved to the SAME pivot %s — "
                     ~ "the three modes pivot about three different points by "
                     ~ "construction, so identical rows mean the apply path is "
                     ~ "not reading the action centre at all",
                       i, j, fmt3(solved[i])));
}

// ==========================================================================
// 4. D7 — does the gizmo move with the item now?
// ==========================================================================
//
// Task 0631 found, and 0648 measured, that the transform gizmo's handle screen
// positions were BIT-IDENTICAL across every item transform at one camera while
// the mesh was drawn through the item matrix. The reading under test is that
// this was a CONSEQUENCE of the centre being published in layer coordinates
// and the gizmo being drawn at that raw point. If it was, fixing the space
// fixes the gizmo; if the handles still do not move, there is a second cause.
unittest {
    double[2] handleAt(string itemTransform) {
        buildStand(itemTransform);
        cmd("tool.set move");
        cmd("actr.select");
        postJson("/api/camera",
                 `{"azimuth":35.0,"elevation":25.0,"distance":14.0,`
               ~ `"focus":{"x":0,"y":0,"z":0}}`);
        auto j = getJson("/api/tool/handles");
        foreach (p; j["handles"]["parts"].array)
            if (p["part"].integer == 0)
                return [p["screen"].array[0].floating,
                        p["screen"].array[1].floating];
        assert(false, "handle part 0 not present in /api/tool/handles");
    }

    auto e = handleAt("E_identity");
    // One camera, one selection, one tool — the ONLY thing that differs is the
    // layer's item transform, so any handle motion is the gizmo following it.
    foreach (xf; ["T_translate", "R_rotate", "S_scale", "A_all"]) {
        auto h = handleAt(xf);
        double d = sqrt((h[0]-e[0])*(h[0]-e[0]) + (h[1]-e[1])*(h[1]-e[1]));
        assert(d > 50.0,
            format("the gizmo did not follow the item transform %s: handle 0 "
                 ~ "is at (%.3f, %.3f) versus (%.3f, %.3f) at identity, %.3f "
                 ~ "px apart.\n"
                 ~ "  Bit-identical handle positions across item transforms is "
                 ~ "the 0631 shape. It should be gone: the gizmo draws at the "
                 ~ "published action centre, and that centre is now a world "
                 ~ "point. If this fires, the centre is world but something "
                 ~ "downstream re-anchors the handles — a SECOND cause, not "
                 ~ "this one.", xf, h[0], h[1], e[0], e[1], d));
    }
}
