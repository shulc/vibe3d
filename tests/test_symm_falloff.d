// Falloff-under-symmetry tests — fixed-base position-copy symmetry.
//
// The transform fold carries exactly ONE symmetry model: a fixed-base
// position-copy. The positive-axis side drives and is reflected onto the other
// side, copying the driver's FINAL position. The fixed base side is the
// symmetry packet's baseSide (default +1, the positive axis), so the result is
// symmetric about the plane REGARDLESS of which side the falloff sits on. An
// asymmetric falloff on the non-base side is discarded: the base (+X) side's
// weight drives BOTH halves.
//
// Reading: with symmetry ON, every column's ΔY equals the +X (positive-axis)
// side's OWN falloff weight × move. A falloff sitting on the −X (non-base) side
// is NOT honoured on its own side — the small +X weight, mirrored, appears on
// both halves. This is the discriminator: a one-sided −X falloff yields the
// SMALL +X-side weight on both halves, NOT the −X-side weight.
//
// All cases drive the deterministic HEADLESS apply path
// (tool.set + tool.attr + tool.doApply → applyHeadless → applyTRS →
// applyFold → driver pass + the single position-copy mirror).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}
bool approxEq(double a, double b, double eps = 1e-3) {
    return fabs(a - b) < eps;
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

// Is the vertex cloud symmetric about the X=0 plane? (For every vert there
// is a vert at its X-reflection (−x, y, z).) Proves a rotate/scale drag
// under X-symmetry mirrored correctly.
bool symmetricAboutX(double[3][] verts, double eps = 1e-3) {
    foreach (v; verts) {
        bool found = false;
        foreach (w; verts) {
            if (approxEq(w[0], -v[0], eps) && approxEq(w[1], v[1], eps)
                && approxEq(w[2], v[2], eps)) { found = true; break; }
        }
        if (!found) return false;
    }
    return true;
}

// A-priori Linear-falloff weight (shape=linear ⇒ w = 1 − t, clamped to
// [0,1]) for a point at world X = x along a gradient start.x → end.x. Used to
// compute the +X (positive-axis) base-side weight WITHOUT reading the run.
double linearWeightAtX(double x, double startX, double endX) {
    double t = (x - startX) / (endX - startX);
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    double w = 1.0 - t;
    if (w < 0) w = 0;
    if (w > 1) w = 1;
    return w;
}

// ---------------------------------------------------------------------------
// (a) SYMMETRIC-FALLOFF REGRESSION. A Radial falloff centred on the X=0 plane
//     is symmetric about that plane, so the mirror vert's weight equals the
//     driver's; fixed-base position-copy reproduces a symmetric result: the
//     mesh stays symmetric about X=0 after a TY drag.
// ---------------------------------------------------------------------------
unittest {
    // Default 8-vert cube (NO duplicate verts → clean, involutive X-pairing;
    // a segmented cube duplicates corner verts and the closest-match pairing
    // becomes ambiguous, an orthogonal pre-existing concern — test_symm_during_drag
    // uses the 8-vert cube for the same reason).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // empty sel ⇒ whole mesh
    auto before = dumpVerts();

    cmd("tool.set move on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    // Radial falloff centred on the plane (origin), large radius so every
    // vert gets a non-trivial, plane-symmetric weight.
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff center \"0,0,0\"");
    cmd("tool.pipe.attr falloff size \"2,2,2\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr move TY 0.5");
    cmd("tool.doApply");

    auto verts = dumpVerts();
    // The whole mesh must remain mirror-symmetric about X=0 — a symmetric
    // falloff gives both sides equal weight, so the TY ramp is identical on
    // each side and the X-reflection still maps the cloud onto itself.
    assert(symmetricAboutX(verts),
        "symmetric radial falloff + X-symm: mesh must stay symmetric about X=0");
    // And the plane wasn't dragged off: at least one vert actually moved (the
    // falloff isn't a no-op).
    bool moved = false;
    foreach (i; 0 .. verts.length)
        if (verts[i][1] - before[i][1] > 1e-3) { moved = true; break; }
    assert(moved, "TY drag with radial falloff should move some verts");
}

// ---------------------------------------------------------------------------
// (b) ONE-SIDED DISTANCE FALLOFF — fixed-base position-copy. A Linear falloff
//     whose gradient runs start=(−0.5,0,0)→end=(1.5,0,0) (entirely on the +X
//     half) is NOT plane-symmetric. Under X-symmetry + TY drag on the whole
//     cube the +X (positive-axis) side DRIVES and is reflected:
//       • driver vert at x=+0.5: linear weight t=(0.5−(−0.5))/2=0.5 ⇒ w=0.5
//         (shape=linear ⇒ 1−t) ⇒ ΔY = 0.5·0.5 = +0.25.
//       • mirror vert at x=−0.5: position-copied from the +X driver ⇒ the SAME
//         ΔY=+0.25 (NOT its own w=1.0). Fixed base: both halves take the
//         +X-side weight.
//     (TY is unaffected by an X-plane reflection, so the Y delta is copied
//     intact across the mirror.)
// ---------------------------------------------------------------------------
unittest {
    // Default 8-vert cube (clean, involutive X-pairing; a segmented cube
    // duplicates corner verts and the closest-match pairing becomes ambiguous).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // empty sel ⇒ whole mesh
    auto before = dumpVerts();

    cmd("tool.set move on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr falloff type linear");
    cmd("tool.pipe.attr falloff start \"-0.5,0,0\"");   // weight 1 at x=-0.5
    cmd("tool.pipe.attr falloff end \"1.5,0,0\"");       // weight 0 at x=+1.5
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr move TY 0.5");
    cmd("tool.doApply");

    auto after = dumpVerts();
    assert(after.length == before.length, "vert count changed");

    // A-priori: the +X (positive-axis, base) side drives BOTH halves. The
    // +X-side weight at x=+0.5 is w=0.5 ⇒ ΔY = 0.5·0.5 = +0.25. Position-copy
    // gives the −X column the SAME +0.25 (NOT its own w=1.0 → +0.5).
    const double move = 0.5;
    const double wPlus = linearWeightAtX(0.5, -0.5, 1.5);   // 0.5
    const double dYexpected = wPlus * move;                  // 0.25
    assert(approxEq(wPlus, 0.5),
        "sanity: +X-side linear weight must be 0.5, got " ~ wPlus.to!string);
    assert(dYexpected > 0, "expected a non-zero base-side delta");

    bool sawPlus = false, sawMinus = false;
    foreach (i; 0 .. after.length) {
        double dx0 = before[i][0];
        double dY  = after[i][1] - before[i][1];
        if (approxEq(dx0, 0.5)) {
            sawPlus = true;
            assert(approxEq(dY, dYexpected, 2e-3),
                "+X driver (own weight 0.5) must move ΔY=+0.25, got "
                ~ dY.to!string);
        } else if (approxEq(dx0, -0.5)) {
            sawMinus = true;
            // Fixed base: the −X column is position-copied from the +X driver,
            // so it takes the +X-side weight (0.5), NOT its own (1.0).
            assert(approxEq(dY, dYexpected, 2e-3),
                "−X column is fixed-base position-copied from +X ⇒ ΔY=+0.25 "
                ~ "(the +X-side weight, NOT its own 0.5). got " ~ dY.to!string);
        }
        // X must be untouched (TY drag, X-reflection leaves Y delta only).
        assert(approxEq(after[i][0], before[i][0], 2e-3),
            "TY drag must not move X");
    }
    assert(sawPlus && sawMinus, "expected both ±0.5 X columns present");
    assert(symmetricAboutX(after),
        "one-sided falloff under X-symm must STILL be symmetric about X=0 "
        ~ "(fixed-base position-copy)");
}

// ---------------------------------------------------------------------------
// (b2) MEMBERSHIP FALLOFF — fixed base. An Element falloff with a one-vid
//      anchor-ring (vid 6) + a ≈0 sphere radius is vid-keyed: ONLY vid 6 gets
//      weight 1. vid 6 is the +X+Y+Z corner (the positive base side). Under
//      fixed-base position-copy the +X member drives; vid 7 (vid 6's −X mirror)
//      inherits the driver's reflected position and STILL MOVES.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // whole mesh
    auto before = dumpVerts();                          // default 8-vert cube

    cmd("tool.set move on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff dist 0.0001");          // ≈0 sphere ⇒ non-anchor w=0
    cmd("tool.pipe.attr falloff anchorRing \"6\"");     // vid 6 ⇒ weight 1
    cmd("tool.attr move TY 0.5");
    cmd("tool.doApply");

    auto after = dumpVerts();
    // vid 6 (+X+Y+Z corner) is the anchored driver on the positive base side —
    // it moves +0.5 in Y.
    double dY6 = after[6][1] - before[6][1];
    assert(approxEq(dY6, 0.5, 2e-3),
        "anchored +X driver vid6 should move ΔY=+0.5, got " ~ dY6.to!string);
    // vid 7 (−X+Y+Z corner) is vid 6's X-mirror. Fixed-base position-copy
    // reflects the +X driver's final position onto it ⇒ it STILL MOVES with the
    // driver's full transform (NOT frozen at its own ≈0 weight).
    double dY7 = after[7][1] - before[7][1];
    assert(approxEq(dY7, 0.5, 2e-3),
        "fixed-base mirror vid7 must STILL MOVE (copied from the +X driver) ⇒ "
        ~ "ΔY=+0.5, not frozen. got " ~ dY7.to!string);
    // The mirror invariant survives: vid6.x + vid7.x = 0 (TY leaves X alone).
    assert(approxEq(after[6][0] + after[7][0], 0.0, 2e-3),
        "vid6.x + vid7.x must stay 0 under a TY symmetry mirror");
}

// ---------------------------------------------------------------------------
// (c-rotate) ROTATE + SYMMETRIC FALLOFF. A Radial falloff centred on the X=0
//     plane is symmetric, so both sides get equal weight; a rotate about the
//     world Y axis under fixed-base position-copy must leave the cloud
//     symmetric about X=0 (the +X-driven rotated cluster, reflected).
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // 8-vert cube (clean pairs)
    auto before = dumpVerts();

    cmd("tool.set rotate on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff center \"0,0,0\"");
    cmd("tool.pipe.attr falloff size \"2,2,2\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr rotate RY 30");
    cmd("tool.doApply");

    auto verts = dumpVerts();
    assert(symmetricAboutX(verts),
        "rotate RY + symmetric falloff under X-symm must keep the mesh "
        ~ "symmetric about X=0 (fixed-base position-copy)");
    // Sanity: geometry actually rotated (some vert's Z moved off ±0.5).
    bool moved = false;
    foreach (i; 0 .. verts.length)
        if (!approxEq(verts[i][2], before[i][2])) { moved = true; break; }
    assert(moved, "RY=30 rotate should actually move geometry");
}

// ---------------------------------------------------------------------------
// (c-scale) SCALE + SYMMETRIC FALLOFF. A symmetric radial falloff + a
//     non-uniform scale about the (on-plane) centre must keep the cloud
//     symmetric about X=0 under fixed-base position-copy.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // 8-vert cube (clean pairs)
    auto before = dumpVerts();

    cmd("tool.set scale on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff center \"0,0,0\"");
    cmd("tool.pipe.attr falloff size \"2,2,2\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.attr scale SY 2.0");
    cmd("tool.doApply");

    auto verts = dumpVerts();
    assert(symmetricAboutX(verts),
        "scale SY + symmetric falloff under X-symm must keep the mesh "
        ~ "symmetric about X=0 (fixed-base position-copy)");
    bool moved = false;
    foreach (i; 0 .. verts.length)
        if (!approxEq(verts[i][1], before[i][1])) { moved = true; break; }
    assert(moved, "SY=2 scale should actually move geometry");
}

// ---------------------------------------------------------------------------
// (d) TWO-SIDED REGRESSION — falloff on the +X (base) side. THE user's bug,
//     positive case. Default 8-vert cube (clean X-pairing, x∈{−0.5,+0.5});
//     X-symmetry ON; whole-mesh +Y move of +0.5; Linear falloff weighting the
//     +X side full (w(+0.5)=1, w(−0.5)=0). Under fixed-base position-copy the
//     +X side drives at FULL weight, so BOTH halves move ΔY = 1.0·0.5 = +0.5,
//     symmetric about X=0. The +X-side weight is computed a priori.
// ---------------------------------------------------------------------------
unittest {
    twoSidedRegression(/*falloffOnPlus=*/ true);
}

// ---------------------------------------------------------------------------
// (e) TWO-SIDED REGRESSION — falloff on the −X (NON-base) side. THE user's bug,
//     the discriminator. SAME magnitude falloff as (d) but flipped to the −X
//     side (w(−0.5)=1, w(+0.5)=0). Fixed base STILL drives from the +X side, so
//     the −X falloff is DISCARDED: the +X-side weight is 0 ⇒ BOTH halves move
//     ΔY = 0.0·0.5 = 0.0 (frozen), symmetric about X=0.
//
//     This is the discriminator. A mass-per-side driver would let the −X side
//     (its heavy w=1 mass) drive ⇒ ΔY=+0.5 on both halves. Fixed base gives
//     0.0 instead — the +X-side (zero) weight. The (d)/(e) pair (same falloff,
//     flipped side ⇒ 0.5 vs 0.0) is the proof: only the positive axis drives.
// ---------------------------------------------------------------------------
unittest {
    twoSidedRegression(/*falloffOnPlus=*/ false);
}

// Shared body for (d)/(e). `falloffOnPlus` selects which side the one-sided
// Linear gradient weights FULL. The result is ALWAYS driven by the +X side
// under fixed-base position-copy: the +X column takes its OWN weight (full when
// falloffOnPlus, zero otherwise) and the −X column is position-copied to the
// SAME value. Clean 8-vert cube so the X-pairing is involutive.
void twoSidedRegression(bool falloffOnPlus) {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");                     // empty sel ⇒ whole mesh
    auto before = dumpVerts();                          // default 8-vert cube

    cmd("tool.set move on");
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
    cmd("tool.pipe.attr falloff type linear");
    cmd("tool.pipe.attr falloff shape linear");

    // Gradient over the X span [-0.5,+0.5]. shape=linear ⇒ w=1 at start, 0 at
    // end (w = 1 − t, t = (x−start)/(end−start)).
    //   • falloffOnPlus: start=(+0.5)→end=(−0.5) ⇒ w(+0.5)=1, w(−0.5)=0.
    //   • !falloffOnPlus: start=(−0.5)→end=(+0.5) ⇒ w(−0.5)=1, w(+0.5)=0.
    double startX, endX;
    if (falloffOnPlus) { startX = 0.5; endX = -0.5; }
    else               { startX = -0.5; endX = 0.5; }
    cmd("tool.pipe.attr falloff start \"" ~ startX.to!string ~ ",0,0\"");
    cmd("tool.pipe.attr falloff end \"" ~ endX.to!string ~ ",0,0\"");

    const double move = 0.5;
    cmd("tool.attr move TY " ~ move.to!string);
    cmd("tool.doApply");

    auto after = dumpVerts();
    assert(after.length == before.length, "vert count changed");

    // A-priori: fixed base ⇒ BOTH halves take the +X (positive axis) side's OWN
    // weight × move. +X weight at x=+0.5 is the gradient weight there.
    const double wPlus    = linearWeightAtX(+0.5, startX, endX);   // 1.0 or 0.0
    const double expected = wPlus * move;                          // 0.5 or 0.0
    if (falloffOnPlus) {
        assert(approxEq(wPlus, 1.0), "sanity: +X full weight = 1.0");
        assert(approxEq(expected, 0.5), "table: falloff +X ⇒ both ΔY=0.500");
    } else {
        // Discriminator: −X falloff DISCARDED ⇒ +X-side weight is 0.
        assert(approxEq(wPlus, 0.0),
            "discriminator: +X-side weight is 0 when the falloff sits on −X "
            ~ "(the −X falloff is discarded, NOT honoured)");
        assert(approxEq(expected, 0.0),
            "discriminator: falloff −X ⇒ both ΔY=0.000 (+X-side weight), "
            ~ "NOT 0.5 (the −X-side weight a mass-per-side driver would give)");
    }

    // Per-column equality across the mirror + match to the a-priori prediction.
    double dYplus = double.nan, dYminus = double.nan;
    bool sawPlus = false, sawMinus = false;
    foreach (i; 0 .. after.length) {
        double x0 = before[i][0];
        double dY = after[i][1] - before[i][1];
        if (approxEq(x0, +0.5)) { dYplus = dY; sawPlus = true; }
        if (approxEq(x0, -0.5)) { dYminus = dY; sawMinus = true; }
        // X must be untouched (TY drag, X-reflection leaves Y delta only).
        assert(approxEq(after[i][0], before[i][0], 2e-3),
            "TY drag must not move X");
    }
    assert(sawPlus && sawMinus, "expected both ±0.5 X columns present");
    // (a) both sides moved the SAME ΔY.
    assert(approxEq(dYplus, dYminus, 2e-3),
        "+x and −x columns must move the same ΔY (fixed-base symmetry); got "
        ~ dYplus.to!string ~ " vs " ~ dYminus.to!string);
    // (c) that shared ΔY equals the a-priori +X-side prediction.
    assert(approxEq(dYplus, expected, 2e-3),
        "column ΔY must equal the +X-side weight prediction "
        ~ expected.to!string ~ ", got " ~ dYplus.to!string);
    // (b) ΔY > 0 where the table is non-zero (only the +X-falloff case moves).
    if (expected > 1e-3) {
        assert(dYplus > 1e-3,
            "falloff +X: both halves must MOVE (ΔY>0), got " ~ dYplus.to!string);
        assert(dYminus > 1e-3,
            "falloff +X: −X mirror must MOVE too, got " ~ dYminus.to!string);
    }

    // Whole-cloud symmetry invariant.
    assert(symmetricAboutX(after),
        "two-sided one-sided-falloff drag must be symmetric about X=0 "
        ~ "(fixed-base position-copy)");
}
