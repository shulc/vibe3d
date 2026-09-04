// Task 0614 Phase 6 — the whole selected SET.
//
// Law L2 (doc/tasks/0614-evidence/phase0_findings.md case B, measured): a
// transform gesture in Item mode moves EVERY SELECTED ITEM, not only the
// primary — and the shared action centre follows the PRIMARY, not the set
// midpoint. Phases 3-5 shipped the apply path primary-only; this file is
// the widening's proof.
//
// THE RIG IS THE TEST. Three layers, deliberately unlike each other:
//
//   A = layer 0 — PRIMARY + selected. pos/rot/scl/pivot all non-default.
//   B = layer 1 —           selected, never primary. DIFFERENT position,
//                           DIFFERENT rotation, DIFFERENT non-uniform scale.
//   C = layer 2 —           NOT selected. The negative control.
//
// Every one of those three properties is load-bearing, and each rules out a
// specific wrong implementation that a friendlier rig would pass:
//
//   * B at a DIFFERENT POSITION from A is what makes the shared centre sit
//     OUTSIDE B (`P_B != c`), which is the only configuration in which the
//     R15 hazard below is observable at all — with A and B co-located the
//     rotate term vanishes for both and a live centre reads identically to a
//     frozen one.
//   * B with a DIFFERENT ROTATION and a DIFFERENT NON-UNIFORM SCALE is what
//     separates "the gesture was applied to B" from "A's resulting xform was
//     copied onto B". Two items that are translations of each other cannot
//     tell those apart — their post-gesture rot/scl agree by construction.
//   * C, unselected, separates "the moving set is the SELECTION" from "the
//     moving set is the DOCUMENT". Without it, an implementation that
//     transformed every layer would pass every other assertion here.
//
// R15 (the hazard L1 and L2 create TOGETHER, and the reason unit 3 exists):
// the shared centre is the PRIMARY's own world pivot (L1), and the primary is
// itself inside the moving set (L2) — so a composed translate-then-rotate run
// MOVES THE CENTRE mid-run. If `applyItemTRS` read the centre live from the
// action-centre packet instead of from the run-frozen `runFrameOrigin`, every
// SECONDARY item would rotate about a centre the translate term had already
// displaced. Invisible at Phase 3 (primary-only: `P - c == 0`, so the rotate
// term vanishes no matter where `c` drifts) — unit 3 is the first thing in
// the tree that can see it, and it asserts the discrimination explicitly
// rather than trusting the rig to provide it.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

JSONValue layers() { return parseJSON(cast(string)get(BASE ~ "/api/layers")); }

double[3] layerPos(int idx) {
    auto p = layers()["layers"].array[idx]["xform"]["pos"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
}
double[3] layerRot(int idx) {
    auto p = layers()["layers"].array[idx]["xform"]["rot"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
}
double[3] layerScl(int idx) {
    auto p = layers()["layers"].array[idx]["xform"]["scl"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
}
double[3] layerPivot(int idx) {
    auto p = layers()["layers"].array[idx]["xform"]["pivot"].array;
    return [p[0].floating, p[1].floating, p[2].floating];
}

/// The layer's composed world matrix, column-major, as `/api/layers` emits it.
double[16] layerMatrix(int idx) {
    auto m = layers()["layers"].array[idx]["xform"]["matrix"].array;
    double[16] out_;
    foreach (i; 0 .. 16) out_[i] = m[i].floating;
    return out_;
}

/// The layer's `vertices` array as raw JSON text — the byte-identity probe.
/// Deliberately NOT the whole /api/model body, which carries a fresh
/// `timestamp` on every call.
string verticesJson(int layer) {
    auto j = parseJSON(cast(string)get(BASE ~ format("/api/model?layer=%d", layer)));
    return j["vertices"].toString();
}

// ---------------------------------------------------------------------------
// Tiny 3x3 helpers, column-major to match `xform.matrix`'s 4x4 layout
// (m[0..2] = column 0, m[4..6] = column 1, m[8..10] = column 2).
//
// These exist so the ORACLE for a secondary item is built from the gesture as
// MEASURED ON THE PRIMARY, never from the item kernel's own formula. Unit 3's
// `R_g` is recovered as `L_A_after * inverse(L_A_before)` — the primary's own
// linear part before and after, both read off the wire — so a kernel that
// composed the rotation in the wrong order, or about the wrong centre, cannot
// also move the goalposts.
// ---------------------------------------------------------------------------

double[9] linearOf(const double[16] m) {
    return [m[0], m[1], m[2],  m[4], m[5], m[6],  m[8], m[9], m[10]];
}

double[3] applyLinear(const double[9] L, const double[3] v) {
    return [L[0]*v[0] + L[3]*v[1] + L[6]*v[2],
            L[1]*v[0] + L[4]*v[1] + L[7]*v[2],
            L[2]*v[0] + L[5]*v[1] + L[8]*v[2]];
}

double[9] mul3(const double[9] A, const double[9] B) {
    double[9] C;
    foreach (c; 0 .. 3) foreach (r; 0 .. 3) {
        double s = 0;
        foreach (k; 0 .. 3) s += A[k*3 + r] * B[c*3 + k];
        C[c*3 + r] = s;
    }
    return C;
}

double[9] inverse3(const double[9] M) {
    // at(r,c) == M[c*3 + r]
    double a = M[0], b = M[3], c = M[6];
    double d = M[1], e = M[4], f = M[7];
    double g = M[2], h = M[5], i = M[8];
    double det = a*(e*i - f*h) - b*(d*i - f*g) + c*(d*h - e*g);
    assert(fabs(det) > 1e-9,
        "inverse3: the rig's base linear part must be invertible — got det="
        ~ det.to!string);
    double id = 1.0 / det;
    double[9] R;
    R[0] = (e*i - f*h) * id;  R[3] = (c*h - b*i) * id;  R[6] = (b*f - c*e) * id;
    R[1] = (f*g - d*i) * id;  R[4] = (a*i - c*g) * id;  R[7] = (c*d - a*f) * id;
    R[2] = (d*h - e*g) * id;  R[5] = (b*g - a*h) * id;  R[8] = (a*e - b*d) * id;
    return R;
}

double dist3(const double[3] p, const double[3] q) {
    double dx = p[0]-q[0], dy = p[1]-q[1], dz = p[2]-q[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

string fmt3(const double[3] v) {
    return format("(%.5f, %.5f, %.5f)", v[0], v[1], v[2]);
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

// A / B / C authored values, kept as named constants so every assertion can
// say what it expected without re-deriving it from a live read.
enum double[3] A_POS   = [ 0.6, -0.25,  0.4 ];
enum double[3] A_ROT   = [ 0.0,  20.0,  0.0 ];
enum double[3] A_SCL   = [ 1.5,   0.8,  1.0 ];
enum double[3] A_PIVOT = [ 0.1,  0.05,  0.0 ];

enum double[3] B_POS   = [-2.5,   1.1, -0.8 ];
enum double[3] B_ROT   = [12.0, -35.0, 25.0 ];
enum double[3] B_SCL   = [ 0.6,   2.2,  1.3 ];
enum double[3] B_PIVOT = [ 0.0,  -0.3,  0.2 ];

enum double[3] C_POS   = [ 4.0,   0.0,  0.0 ];

/// A's world pivot — the shared action centre (L1), and therefore the
/// run-start centre `c0` unit 3 pins its oracle to.
double[3] aWorldPivot() {
    return [A_POS[0] + A_PIVOT[0], A_POS[1] + A_PIVOT[1], A_POS[2] + A_PIVOT[2]];
}
double[3] bWorldPivot() {
    return [B_POS[0] + B_PIVOT[0], B_POS[1] + B_PIVOT[1], B_POS[2] + B_PIVOT[2]];
}

/// Build [A(primary+selected), B(selected), C(unselected)] and clear history.
///
/// Selection order is load-bearing: `layer.select index:1 mode:set` first
/// (B alone, B primary), THEN `index:0 mode:add` — `SelMode.Add` moves
/// `primary` to the added layer when it `canBePrimary` (document.d), so this
/// lands A as primary with B still selected. The reverse order would leave
/// B primary and silently swap which item the shared centre follows.
void buildRig() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);

    cmd("layer.add name:B");
    cmd("prim.cube");
    cmd("layer.add name:C");
    cmd("prim.cube");

    static void author(int idx, const double[3] pos, const double[3] rot,
                       const double[3] scl, const double[3] pivot) {
        static immutable string[3] axis = ["x", "y", "z"];
        foreach (k; 0 .. 3) {
            cmd(format("layer.attr %d pos.%s %.6f",   idx, axis[k], pos[k]));
            cmd(format("layer.attr %d rot.%s %.6f",   idx, axis[k], rot[k]));
            cmd(format("layer.attr %d scl.%s %.6f",   idx, axis[k], scl[k]));
            cmd(format("layer.attr %d pivot.%s %.6f", idx, axis[k], pivot[k]));
        }
    }
    author(0, A_POS, A_ROT, A_SCL, A_PIVOT);
    author(1, B_POS, B_ROT, B_SCL, B_PIVOT);
    author(2, C_POS, [0.0,0.0,0.0], [1.0,1.0,1.0], [0.0,0.0,0.0]);

    // TASK 0671 — `set 0` then `add 1`, not the other way round. The edit
    // target is the HEAD of the selection queue, so the old order left it on
    // layer 1 and the rig's own premise (layer 0 is the target) stopped
    // holding. The SET is identical either way; only which of the two heads
    // the queue moved, and this rig has always wanted layer 0 there.
    // TASK 0671 — three steps where two used to do. The rig needs layer 0 to
    // be BOTH the edit target (the queue HEAD, hence the `set` first) and the
    // item-transform target (the FOCUS, hence the trailing `add` on an item
    // that is already selected — an `add` moves the focus whether or not it
    // changes the set). Before 0671 the two pointers moved in lockstep and
    // `set 1; add 0` put both on layer 0 in one step; they are separable now,
    // and this rig wants them together.
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:0 mode:add");

    auto ls = layers();
    assert(ls["layers"].array[0]["primary"].type == JSONType.TRUE
        && ls["layers"].array[0]["selected"].type == JSONType.TRUE,
        "rig: layer 0 must be primary AND selected — " ~ ls["layers"].array[0].toString);
    assert(ls["layers"].array[1]["selected"].type == JSONType.TRUE
        && ls["layers"].array[1]["primary"].type == JSONType.FALSE,
        "rig: layer 1 must be selected but NOT primary — "
        ~ ls["layers"].array[1].toString);
    assert(ls["layers"].array[2]["selected"].type == JSONType.FALSE,
        "rig: layer 2 must be UNSELECTED (the negative control) — "
        ~ ls["layers"].array[2].toString);

    auto selType = parseJSON(cast(string)get(BASE ~ "/api/selection"))["selType"].str;
    assert(selType == "item",
        "rig: layer.select must promote SelType.Item to current, got " ~ selType);

    // L1 self-check on THIS rig, not a restatement of the law: the item's
    // world pivot really is `pos + pivot` even under a non-identity rotation
    // and a non-uniform scale (the local pivot is a fixed point of R*S). If
    // this ever stops holding, unit 3's `c0` silently becomes the wrong
    // point and its oracle would be self-consistent but meaningless.
    foreach (idx, expect; [aWorldPivot(), bWorldPivot()]) {
        auto m  = layerMatrix(cast(int)idx);
        auto pv = layerPivot(cast(int)idx);
        auto lp = applyLinear(linearOf(m), pv);
        double[3] world = [lp[0] + m[12], lp[1] + m[13], lp[2] + m[14]];
        assert(dist3(world, expect) < 1e-4,
            format("rig: layer %d world pivot from the composed matrix is %s "
                 ~ "but pos+pivot is %s — the L1 identity this file's oracle "
                 ~ "relies on does not hold for this rig",
                   idx, fmt3(world), fmt3(expect)));
    }

    cmd(`{"id":"history.clear"}`);
}

// ---------------------------------------------------------------------------
// 1. One headless Move apply moves BOTH selected items by the SAME world
//    delta, leaves the UNSELECTED item alone, and touches no vertex anywhere.
//
//    Wrong implementations this discriminates, and what each would read here:
//      * primary-only (the Phase 3 shape)  -> B.pos stays at B_POS.
//      * "every layer in the document"     -> C.pos.x moves to 6.5.
//      * "copy the primary's xform to the
//         whole set"                       -> B.rot/B.scl become A's.
//      * writing mesh.vertices as well     -> the byte-identity compare fails.
//
//    Translate is CENTRE-INVARIANT, so this unit says nothing about R15 —
//    that is unit 3's job, and keeping the two apart is deliberate: a single
//    combined case could pass for the wrong reason.
// ---------------------------------------------------------------------------

unittest {
    buildRig();

    string[3] preVerts = [verticesJson(0), verticesJson(1), verticesJson(2)];

    enum double DX = 2.5;
    cmd("tool.set move on");
    cmd(format("tool.attr move TX %.6f", DX));
    cmd("tool.doApply");
    cmd("tool.set move off");

    auto pa = layerPos(0), pb = layerPos(1), pc = layerPos(2);

    assert(approx(pa[0], A_POS[0] + DX) && approx(pa[1], A_POS[1]) && approx(pa[2], A_POS[2]),
        "the PRIMARY must move by exactly TX — expected "
        ~ fmt3([A_POS[0] + DX, A_POS[1], A_POS[2]]) ~ " got " ~ fmt3(pa));

    assert(approx(pb[0], B_POS[0] + DX) && approx(pb[1], B_POS[1]) && approx(pb[2], B_POS[2]),
        "the SECONDARY selected item must move by the SAME world delta as the "
        ~ "primary (law L2: the gesture drives the whole selected SET) — "
        ~ "expected " ~ fmt3([B_POS[0] + DX, B_POS[1], B_POS[2]])
        ~ " got " ~ fmt3(pb)
        ~ " (unchanged " ~ fmt3(B_POS) ~ " means the apply path is still "
        ~ "primary-only)");

    assert(approx(pc[0], C_POS[0]) && approx(pc[1], C_POS[1]) && approx(pc[2], C_POS[2]),
        "the UNSELECTED item must NOT move — the moving set is the SELECTION, "
        ~ "not the document. expected " ~ fmt3(C_POS) ~ " got " ~ fmt3(pc));

    // A pure translate leaves the other three channels alone — and, because
    // A and B were authored with DIFFERENT rot/scl, this also rules out "the
    // primary's whole xform was copied over the set".
    auto rb = layerRot(1), sb = layerScl(1);
    foreach (k; 0 .. 3) {
        assert(approx(rb[k], B_ROT[k]),
            "a translate must leave the secondary's OWN rot untouched — "
            ~ "expected " ~ fmt3(B_ROT) ~ " got " ~ fmt3(rb)
            ~ " (matching the primary's " ~ fmt3(A_ROT) ~ " would mean the "
            ~ "primary's xform was copied, not the gesture applied)");
        assert(approx(sb[k], B_SCL[k]),
            "a translate must leave the secondary's OWN scl untouched — "
            ~ "expected " ~ fmt3(B_SCL) ~ " got " ~ fmt3(sb));
    }

    foreach (i; 0 .. 3)
        assert(preVerts[i] == verticesJson(cast(int)i),
            format("layer %d's LOCAL vertex coordinates must be BYTE-IDENTICAL "
                 ~ "after an item-mode apply — the mesh rides the item, it is "
                 ~ "not baked", i));
}

// ---------------------------------------------------------------------------
// 2. A HIDDEN but still-selected item stays in the moving set.
//
//    `Document.selectedItemsInto` filters on `selected` alone, deliberately
//    NOT on `visible` — pinned here because it is a judgement call, not a
//    measured law, and because "the moving set is the FOREGROUND set"
//    (visible && selected) is the plausible alternative a reader would
//    assume from `Document.foreground()`'s existence.
//
//    Rationale for the choice, and why the alternative is worse: hiding a
//    non-primary selected layer is a representable state, the layer stays in
//    the selection the user sees, and its `Layer.xform` is still what the
//    undo entry would restore. Dropping it from the set would move the
//    selection out from under the undo payload and strand the layer at a
//    stale pose the moment it is shown again.
//
//    Wrong implementation: a `visible &&` term in the accessor -> B.pos
//    stays at B_POS while A moves.
// ---------------------------------------------------------------------------

unittest {
    buildRig();
    cmd("layer.setVisible index:1 value:false");

    auto ls = layers();
    assert(ls["layers"].array[1]["visible"].type == JSONType.FALSE
        && ls["layers"].array[1]["selected"].type == JSONType.TRUE,
        "rig: hiding a non-primary layer must leave it SELECTED but invisible — "
        ~ ls["layers"].array[1].toString);

    enum double DX = 1.75;
    cmd("tool.set move on");
    cmd(format("tool.attr move TX %.6f", DX));
    cmd("tool.doApply");
    cmd("tool.set move off");

    auto pb = layerPos(1);
    assert(approx(pb[0], B_POS[0] + DX),
        "a HIDDEN but selected item must still be transformed (the moving set "
        ~ "is `selected`, not `visible && selected`) — expected pos.x "
        ~ (B_POS[0] + DX).to!string ~ " got " ~ pb[0].to!string);
    assert(approx(layerPos(0)[0], A_POS[0] + DX),
        "sanity: the primary must have moved too");
}

// ---------------------------------------------------------------------------
// 3. R15 — a composed translate-then-rotate in ONE run rotates the secondary
//    about the RUN-START centre, not about the centre the translate moved.
//
//    Mechanism: `applyTRS` samples the action centre (`queryActionCenter`)
//    BEFORE `restoreItemBaseline()`, i.e. against whatever the previous apply
//    in this run left on the primary. On the second apply of a composed run
//    that value has already been displaced by the translate term. The
//    frozen `runFrameOrigin` (captured on the run's FIRST apply) has not.
//
//    Two applies inside ONE tool activation, not two activations: the item
//    path holds its run baseline across bare `tool.doApply` calls (pinned by
//    test_item_drag_move.d unit 3), so the second apply re-folds the
//    RUN-ABSOLUTE `run.t` + `run.r` from the run-start baseline — exactly the
//    per-frame re-evaluate a live drag performs, without pixel hit-testing.
//    `xfrm.transform` is the one registered id with T/R/S all enabled;
//    `move`/`rotate` are separate tool INSTANCES, so switching between them
//    would be two runs, not one.
//
//    The oracle:
//      c0  = A's world pivot before the run           (== the frozen centre)
//      d   = the REQUESTED world translate            (an INPUT, not an
//                                                      output — checked
//                                                      against the measured
//                                                      displacement after
//                                                      apply 1, while the
//                                                      gesture rotation is
//                                                      still identity and the
//                                                      centre question is
//                                                      therefore moot)
//      R_g = L_A_after * inverse(L_A_before)          (the gesture rotation,
//                                                      read off the primary's
//                                                      LINEAR part — which is
//                                                      centre-independent, so
//                                                      an R15 violation
//                                                      cannot corrupt it)
//    and then      P_B_expected = c0 + R_g*(P_B0 - c0) + d.
//    Nothing in that chain restates the item kernel's formula.
//
//    Deliberately NOT `d = A's world pivot after the whole run - c0`: under a
//    live centre the rotate term stops vanishing for the PRIMARY too (its
//    offset from the live centre becomes -d, not 0), so an outcome-derived
//    `d` would move with the bug and the R15 assertion would never be the one
//    that fired. Measured: that shape went red on the sanity gate instead,
//    reporting a primary displacement of (2.26795, 0, 1.00000).
//
//    The wrong implementation, spelled out and asserted to be DISTINGUISHABLE
//    before the real assertion runs (R16): reading the centre live gives
//    c1 = c0 + d and lands B at  c1 + R_g*(P_B0 - c1) + d,  which differs
//    from the correct answer by exactly `d - R_g*d`. That is why the
//    translate axis (world X) and the rotation axis (world Y) are chosen
//    NON-PARALLEL: a rotation about the translate's own axis would make
//    `R_g*d == d` and the whole unit would be vacuous while still passing.
// ---------------------------------------------------------------------------

unittest {
    buildRig();

    auto c0        = aWorldPivot();
    auto pB0       = bWorldPivot();
    auto lABefore  = linearOf(layerMatrix(0));
    auto lBBefore  = linearOf(layerMatrix(1));

    enum double TX      = 2.0;
    enum double RY_DEG  = 30.0;

    cmd("tool.set xfrm.transform on");
    cmd(format("tool.attr xfrm.transform TX %.6f", TX));
    cmd("tool.doApply");                       // apply 1 — freezes runFrameOrigin

    // MID-RUN frame check, taken while `run.r` is still identity: with no
    // gesture rotation there is no rotate term for the centre to corrupt, so
    // this isolates "the frozen frame is the WORLD frame (L3) and TX means a
    // world-X translate" from everything unit 3 goes on to test. It is what
    // licenses using the REQUESTED translate as the oracle's `d`.
    double[3] d = [TX, 0.0, 0.0];
    {
        auto pa = layerPos(0), qa = layerPivot(0);
        auto pb = layerPos(1), qb = layerPivot(1);
        double[3] aMid = [pa[0]+qa[0], pa[1]+qa[1], pa[2]+qa[2]];
        double[3] bMid = [pb[0]+qb[0], pb[1]+qb[1], pb[2]+qb[2]];
        assert(dist3(aMid, [c0[0]+d[0],  c0[1]+d[1],  c0[2]+d[2]])  < 1e-3
            && dist3(bMid, [pB0[0]+d[0], pB0[1]+d[1], pB0[2]+d[2]]) < 1e-3,
            "mid-run: after the translate-only apply BOTH items must have "
            ~ "moved by exactly the requested world delta " ~ fmt3(d)
            ~ " — primary " ~ fmt3(aMid) ~ ", secondary " ~ fmt3(bMid)
            ~ ". A different value means the frozen frame is not the WORLD "
            ~ "frame (L3), and the oracle below would be unsound.");
    }

    cmd(format("tool.attr xfrm.transform RY %.6f", RY_DEG));
    cmd("tool.doApply");                       // apply 2 — live centre has drifted
    cmd("tool.set xfrm.transform off");

    auto rG = mul3(linearOf(layerMatrix(0)), inverse3(lABefore));

    // The gesture rotation must actually BE a rotation of the requested size,
    // or `d - R_g*d` could be small for a reason unrelated to the law.
    auto rotatedD = applyLinear(rG, d);
    assert(dist3(rotatedD, d) > 0.5,
        "sanity: the recovered gesture rotation must move the translate "
        ~ "vector appreciably, otherwise the correct and the live-centre "
        ~ "predictions coincide and this unit proves nothing — R_g*d="
        ~ fmt3(rotatedD) ~ " d=" ~ fmt3(d));

    double[3] rel      = [pB0[0] - c0[0], pB0[1] - c0[1], pB0[2] - c0[2]];
    auto      relRot   = applyLinear(rG, rel);
    double[3] expected = [c0[0] + relRot[0] + d[0],
                          c0[1] + relRot[1] + d[1],
                          c0[2] + relRot[2] + d[2]];

    // The live-centre (R15-violating) prediction, computed the same way.
    double[3] c1        = [c0[0] + d[0], c0[1] + d[1], c0[2] + d[2]];
    double[3] relLive   = [pB0[0] - c1[0], pB0[1] - c1[1], pB0[2] - c1[2]];
    auto      relLiveR  = applyLinear(rG, relLive);
    double[3] wrong     = [c1[0] + relLiveR[0] + d[0],
                           c1[1] + relLiveR[1] + d[1],
                           c1[2] + relLiveR[2] + d[2]];

    assert(dist3(expected, wrong) > 0.25,
        "R16: this rig must SEPARATE the frozen-centre answer from the "
        ~ "live-centre one, or the assertion below is satisfied by both. "
        ~ "frozen=" ~ fmt3(expected) ~ " live=" ~ fmt3(wrong)
        ~ " — move the two items further apart, or pick a rotation axis "
        ~ "less parallel to the translate.");

    auto posB = layerPos(1), pivB = layerPivot(1);
    double[3] pBAfter = [posB[0] + pivB[0], posB[1] + pivB[1], posB[2] + pivB[2]];

    assert(dist3(pBAfter, expected) < 5e-3,
        "R15: the SECONDARY item must rotate about the RUN-START centre "
        ~ fmt3(c0) ~ ", frozen in runFrameOrigin — expected " ~ fmt3(expected)
        ~ " got " ~ fmt3(pBAfter)
        ~ " (the live-centre answer is " ~ fmt3(wrong)
        ~ "; landing THERE means applyItemTRS read the action centre from the "
        ~ "live packet, which the translate term had already moved)");

    // The PRIMARY is the same law at `rel == 0`: it must land at exactly
    // c0 + d, with the rotate term contributing nothing. This is the second,
    // independent signal for a live centre — under one, the primary's offset
    // from the (moved) centre becomes -d instead of 0 and the rotate term
    // stops vanishing for it too.
    auto posA = layerPos(0), pivA = layerPivot(0);
    double[3] pAAfter = [posA[0] + pivA[0], posA[1] + pivA[1], posA[2] + pivA[2]];
    assert(dist3(pAAfter, [c0[0]+d[0], c0[1]+d[1], c0[2]+d[2]]) < 5e-3,
        "the PRIMARY sits AT the shared centre, so a composed T+R run must "
        ~ "land it at c0+d = " ~ fmt3([c0[0]+d[0], c0[1]+d[1], c0[2]+d[2]])
        ~ " with no rotate contribution — got " ~ fmt3(pAAfter));

    // The secondary got the SAME gesture rotation, composed onto its OWN base
    // orientation — not the primary's. A and B were authored with different
    // rotations precisely so this can tell the two apart.
    auto lBExpected = mul3(rG, lBBefore);
    auto lBAfter    = linearOf(layerMatrix(1));
    foreach (k; 0 .. 9)
        assert(approx(lBAfter[k], lBExpected[k], 5e-3),
            format("the secondary's linear part must be R_g * (its OWN base) "
                 ~ "— element %d expected %.6f got %.6f",
                   k, lBExpected[k], lBAfter[k]));

    auto pc = layerPos(2);
    assert(approx(pc[0], C_POS[0]) && approx(pc[1], C_POS[1]) && approx(pc[2], C_POS[2]),
        "the unselected control must be untouched by a composed run too — got "
        ~ fmt3(pc));
}

// ---------------------------------------------------------------------------
// 4. ONE gesture over a two-item selection is ONE undo entry that restores
//    BOTH.
//
//    Driven by a REAL gizmo drag, not `tool.doApply`: the headless path is
//    backed by ToolDoApplyCommand, whose MeshSnapshot undo never reads or
//    writes `Layer.xform` at all (a known, named follow-up — see
//    test_item_drag_undo.d's header). Only the interactive lifecycle
//    (begin*DragSession -> beginEdit -> commitEdit -> LayerXformEdit ->
//    RunMergeable) records the entry this unit is about.
//
//    This is also the ONLY unit here that exercises `beginRunGesture`'s
//    target list (a live drag) and `beginEdit`'s (the undo session); units
//    1-3 go through the headless one-shot fallback in `restoreItemBaseline`.
//    All three resolve the moving set, and the three arms of this file are
//    what keep them honest together:
//      * `beginRunGesture` primary-only  -> B does not move during the drag.
//      * `beginEdit` primary-only        -> B moves, one entry is recorded,
//                                           and undo leaves B stranded at the
//                                           dragged pose.
//
//    What the entry-COUNT assertion does and does NOT catch, measured rather
//    than assumed: emitting one `LayerXformEdit` PER TARGET instead of one
//    carrying both leaves this unit GREEN — `RunMergeable`/
//    `CommandHistory.consolidate` collapses same-type commands from one
//    tagged run back into a single entry that already carries both targets
//    (union by `Layer` identity, first-touch `before`, latest `after`). So
//    the count cannot distinguish "one command with N targets" from "N
//    commands that merged"; it reads 2 only when the run ALSO fails to
//    collapse (verified: per-target commands + a declining `mergeRunTail`
//    gives before=0 after=2). It is a regression guard on the gesture->run
//    ->one-entry pipeline as a whole, not a proof of the payload's shape —
//    the payload is what the undo-restores-BOTH assertion below proves.
// ---------------------------------------------------------------------------

unittest {
    buildRig();

    long undoBefore = parseJSON(cast(string)get(BASE ~ "/api/history"))["undo"].array.length;

    post(BASE ~ "/api/script", "tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto wp  = aWorldPivot();
    Vec3 pivot = Vec3(cast(float)wp[0], cast(float)wp[1], cast(float)wp[2]);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(50.0 * ux);
    int y1 = gy + cast(int)(50.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, x1, y1));

    post(BASE ~ "/api/script", "tool.set move off");   // tool drop = run boundary

    auto draggedA = layerPos(0), draggedB = layerPos(1);
    assert(!approx(draggedA[0], A_POS[0]),
        "sanity: the drag must have moved the primary — got " ~ fmt3(draggedA));
    assert(!approx(draggedB[0], B_POS[0]),
        "a REAL drag must move the SECONDARY selected item too (this is the "
        ~ "arm that covers beginRunGesture's target list — units 1-3 go "
        ~ "through the headless fallback instead) — got " ~ fmt3(draggedB)
        ~ ", authored " ~ fmt3(B_POS));
    assert(approx(draggedA[0] - A_POS[0], draggedB[0] - B_POS[0], 1e-5),
        "both items must move by the SAME world delta — primary moved "
        ~ (draggedA[0] - A_POS[0]).to!string ~ " on X, secondary moved "
        ~ (draggedB[0] - B_POS[0]).to!string);
    assert(approx(layerPos(2)[0], C_POS[0]),
        "the unselected control must not be dragged");

    auto h = parseJSON(cast(string)get(BASE ~ "/api/history"));
    long undoAfter = h["undo"].array.length;
    assert(undoAfter == undoBefore + 2,
        format("one arm plus ONE gesture over a TWO-item selection must surface "
             ~ "exactly TWO rows (one lifecycle row and one LayerXformEdit "
             ~ "carrying both targets), not one edit per target — before=%d after=%d",
               undoBefore, undoAfter));
    assert(h["undo"].array[$ - 1]["inSession"].type == JSONType.FALSE,
        "the surviving entry must not still be flagged inSession after the "
        ~ "tool-drop boundary — " ~ h["undo"].array[$ - 1].toString);

    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("history.undo")));
    assert(r["status"].str == "ok", "/api/undo failed: " ~ r.toString);

    auto undoneA = layerPos(0), undoneB = layerPos(1);
    assert(dist3(undoneA, A_POS) < 1e-5,
        "undo must restore the PRIMARY exactly — expected " ~ fmt3(A_POS)
        ~ " got " ~ fmt3(undoneA));
    assert(dist3(undoneB, B_POS) < 1e-5,
        "the SINGLE undo entry must restore the SECONDARY too — expected "
        ~ fmt3(B_POS) ~ " got " ~ fmt3(undoneB)
        ~ " (still at the dragged pose " ~ fmt3(draggedB) ~ " means the undo "
        ~ "session captured only the primary, even though the fold moved the "
        ~ "whole set)");

    r = parseJSON(cast(string)post(BASE ~ "/api/redo", ""));
    assert(r["status"].str == "ok", "/api/redo failed: " ~ r.toString);
    assert(dist3(layerPos(0), draggedA) < 1e-5 && dist3(layerPos(1), draggedB) < 1e-5,
        "redo must re-apply the gesture to BOTH targets");
}
