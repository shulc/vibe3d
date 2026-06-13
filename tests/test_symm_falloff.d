// Falloff-under-symmetry tests — Stage 3 of doc/symmetry_deform_plan.md.
//
// These are the JUSTIFICATION tests for the Stage-2 mechanism change: the
// global transform fold now mirrors a drag as a TWO-PASS apply (a driver
// pass with M/pivot, then a mirror pass with M'=Slin·M·Slin about S·pivot
// over the paired sub-set) instead of the old position-copy tail. The
// behavioural delta is in HOW the mirror side is weighted:
//
//   • DISTANCE-based falloffs (Linear/Radial/...) weight each mirror vert
//     at its OWN mirrored position. A SYMMETRIC distance falloff reproduces
//     the old position-copy exactly (no regression); an ASYMMETRIC one gives
//     each side its own attenuation (the correctness divergence the old
//     position-copy got wrong).
//   • MEMBERSHIP / vid-keyed falloffs (Selection, Element with anchor-ring /
//     connect-mask) keep the position-copy mirror — the mirror pair moves
//     with the driver's full transform, NOT its own (≈0) vid-weight, so it
//     is NOT frozen.
//
// All cases drive the deterministic HEADLESS apply path
// (tool.set + tool.attr + tool.doApply → applyHeadless → applyTRS →
// applyFold → Pass A + Pass B), the exact path Stage 2 changed.

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
// under X-symmetry mirrored correctly (S·M·S beyond translate).
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

// ---------------------------------------------------------------------------
// (a) SYMMETRIC-FALLOFF REGRESSION. A Radial falloff centred on the X=0 plane
//     is symmetric about that plane, so the mirror vert's own weight equals
//     the driver's. The new two-pass path must reproduce the old position-copy
//     exactly: the mesh stays symmetric about X=0 after a TY drag, and each
//     mirror pair's Y delta is identical.
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
// (b) ASYMMETRIC DISTANCE FALLOFF CORRECTNESS — the test the OLD position-copy
//     FAILS and the new path PASSES. A Linear falloff whose gradient runs
//     start=(−0.5,0,0)→end=(1.5,0,0) (entirely on the +X half) is NOT
//     plane-symmetric. Under X-symmetry + TY drag on the whole cube:
//       • driver vert at x=+0.5: linear weight t=(0.5−(−0.5))/2=0.5 ⇒ w=0.5
//         (shape=linear ⇒ 1−t) ⇒ ΔY = 0.5·0.5 = +0.25.
//       • mirror vert at x=−0.5: OWN weight t=(−0.5−(−0.5))/2=0 ⇒ w=1.0
//         ⇒ ΔY = 0.5·1.0 = +0.5.   ← uses ITS OWN position, not the driver's.
//     The OLD position-copy would have given the mirror the DRIVER's +0.25.
//     (TY is unaffected by an X-plane reflection, so the conjugated matrix
//     leaves the Y delta sign/scale intact — the only change is the weight.)
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0");
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

    // Group by x-sign and assert each side's Y delta. ALL +0.5 verts share
    // w=0.5 (ΔY=+0.25); ALL −0.5 verts share OWN-w=1.0 (ΔY=+0.5).
    bool sawPlus = false, sawMinus = false;
    foreach (i; 0 .. after.length) {
        double dx0 = before[i][0];
        double dY  = after[i][1] - before[i][1];
        if (approxEq(dx0, 0.5)) {
            sawPlus = true;
            assert(approxEq(dY, 0.25, 2e-3),
                "+X driver (own weight 0.5) must move ΔY=+0.25, got "
                ~ dY.to!string);
        } else if (approxEq(dx0, -0.5)) {
            sawMinus = true;
            // The crux: mirror used its OWN weight (1.0), NOT the driver's
            // (0.5). Old position-copy would assert +0.25 here and FAIL.
            assert(approxEq(dY, 0.5, 2e-3),
                "−X mirror must use its OWN weight (1.0) ⇒ ΔY=+0.5, "
                ~ "NOT the driver's 0.25 (old position-copy). got "
                ~ dY.to!string);
        }
        // X must be untouched (TY drag, X-reflection leaves Y delta only).
        assert(approxEq(after[i][0], before[i][0], 2e-3),
            "TY drag must not move X");
    }
    assert(sawPlus && sawMinus, "expected both ±0.5 X columns present");
}

// ---------------------------------------------------------------------------
// (b2) MEMBERSHIP FALLOFF NON-REGRESSION — guards the objection-4 trap. An
//      Element falloff with a one-vid anchor-ring (vid 6) + a ≈0 sphere radius
//      is vid-keyed: ONLY vid 6 gets weight 1; every other vert (incl. vid 6's
//      mirror, vid 7) gets weight 0. A naive "evaluate the mirror's own weight"
//      implementation would FREEZE vid 7. The membership branch position-copies
//      the driver, so vid 7 STILL MOVES (member, full transform).
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
    // vid 6 (+X+Y+Z corner) is the anchored driver — it moves +0.5 in Y.
    double dY6 = after[6][1] - before[6][1];
    assert(approxEq(dY6, 0.5, 2e-3),
        "anchored driver vid6 should move ΔY=+0.5, got " ~ dY6.to!string);
    // vid 7 (−X+Y+Z corner) is vid 6's X-mirror. Its OWN element weight is 0
    // (not anchored, ≈0 radius) — own-weight would FREEZE it. The membership
    // position-copy mirror moves it with the driver's full transform.
    double dY7 = after[7][1] - before[7][1];
    assert(approxEq(dY7, 0.5, 2e-3),
        "membership mirror vid7 must STILL MOVE (member, weight 1) ⇒ ΔY=+0.5, "
        ~ "not frozen. got " ~ dY7.to!string);
    // The mirror invariant survives: vid6.x + vid7.x = 0 (TY leaves X alone).
    assert(approxEq(after[6][0] + after[7][0], 0.0, 2e-3),
        "vid6.x + vid7.x must stay 0 under a TY symmetry mirror");
}

// ---------------------------------------------------------------------------
// (c-rotate) ROTATE + SYMMETRIC FALLOFF — guards Slin·R·Slin beyond translate.
//     A Radial falloff centred on the X=0 plane is symmetric, so both sides
//     get equal weight; a rotate about the world Y axis must leave the cloud
//     symmetric about X=0 (the conjugated rotation mirrors the driver's twist
//     onto the other side with the reflected chirality).
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
        ~ "symmetric about X=0 (Slin·R·Slin correctness)");
    // Sanity: geometry actually rotated (some vert's Z moved off ±0.5).
    bool moved = false;
    foreach (i; 0 .. verts.length)
        if (!approxEq(verts[i][2], before[i][2])) { moved = true; break; }
    assert(moved, "RY=30 rotate should actually move geometry");
}

// ---------------------------------------------------------------------------
// (c-scale) SCALE + SYMMETRIC FALLOFF — guards Slin·Scale·Slin. A symmetric
//     radial falloff + a non-uniform scale about the (on-plane) centre must
//     keep the cloud symmetric about X=0.
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
        ~ "symmetric about X=0 (Slin·Scale·Slin correctness)");
    bool moved = false;
    foreach (i; 0 .. verts.length)
        if (!approxEq(verts[i][1], before[i][1])) { moved = true; break; }
    assert(moved, "SY=2 scale should actually move geometry");
}
