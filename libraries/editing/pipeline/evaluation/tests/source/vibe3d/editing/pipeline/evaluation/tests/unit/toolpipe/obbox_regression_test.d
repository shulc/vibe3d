module vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.obbox_regression_test;

import std.math : abs, sqrt;
import vibe3d.util.math.math : Vec3, cross, dot, normalize;
import vibe3d.editing.pipeline.evaluation.toolpipe.obbox;


// ---------------------------------------------------------------------------
// Tests. The subject of most of them is the ONE artefact a reference recording
// exists for: the box a cube's +Y face produces, whose rows, extents and
// centre were all recorded. Reproducing a recorded artefact row for row is a
// stronger statement than reproducing a published frame, because the frame
// survives several row permutations that the rows themselves do not.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.format : format;
    import std.math   : fabs;

    private string sv(Vec3 v) {
        return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z);
    }
    private bool nr(Vec3 a, Vec3 b, float eps = 1e-5f) {
        return fabs(a.x - b.x) < eps && fabs(a.y - b.y) < eps
            && fabs(a.z - b.z) < eps;
    }
    private string sm(const ref ObbFrame f) {
        return sv(f.m[0]) ~ " / " ~ sv(f.m[1]) ~ " / " ~ sv(f.m[2]);
    }
    // A unit cube's +Y face, in mesh order.
    private Vec3[] topFace() {
        return [Vec3(-0.5f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, -0.5f),
                Vec3( 0.5f, 0.5f,  0.5f), Vec3(-0.5f, 0.5f, 0.5f)];
    }
}

unittest { // THE RECORDED BOX, row for row, extent for extent, centre included
    auto box = obbFromPoints(topFace(), Vec3(0, 1, 0));
    assert(box.ok && box.source == ObbSource.Covariance,
           "a four-point selection must take the covariance path");
    assert(nr(box.m[0], Vec3(0, 0, 1)) && nr(box.m[1], Vec3(1, 0, 0))
           && nr(box.m[2], Vec3(0, 1, 0)),
           "the reference's RECORDED box for a cube's +Y face is the rows "
           ~ "(0,0,1) / (1,0,0) / (0,1,0); this port answers " ~ sm(box)
           ~ ". Row 2 is the face normal. Rows 0 and 1 do NOT come from the "
           ~ "eigensolver: this face's two in-plane eigenvalues are bit-equal, "
           ~ "so the in-plane pair the solver and the sort produce is "
           ~ "discarded and `fillDegenerateSubspace` fills it — the two world "
           ~ "axes least aligned with row 2, in DESCENDING world index, which "
           ~ "is Z before X. That convention is what this assert pins, and it "
           ~ "is the first place to look when it fires. The eigenpair sort's "
           ~ "tie-break is NOT pinned here and flipping it does not move this "
           ~ "box; see the sort's header before changing it.");
    assert(fabs(box.size[0] - 1.0) < 1e-5 && fabs(box.size[1] - 1.0) < 1e-5
           && fabs(box.size[2]) < 1e-5,
           format("recorded extents are (1, 1, 0); got (%g, %g, %g)",
                  box.size[0], box.size[1], box.size[2]));
    assert(nr(box.center, Vec3(0, 0.5f, 0)),
           "the recorded box centre for this rig is (0, 0.5, 0); got "
           ~ sv(box.center));
}


unittest { // the ONE post-processing step: a conditional negation of all nine
    // The -Y face has the same covariance as the +Y face — the moments are
    // translation-invariant — so the ONLY thing that can distinguish them is
    // the sign test against the polygon-normal reference. Without it both
    // faces would publish the same outward direction and a bottom-face gizmo
    // would point up.
    Vec3[] bottom;
    foreach (p; topFace()) bottom ~= Vec3(p.x, -0.5f, p.z);
    auto up   = obbFromPoints(topFace(), Vec3(0,  1, 0));
    auto down = obbFromPoints(bottom,    Vec3(0, -1, 0));
    assert(nr(up.m[2], Vec3(0, 1, 0)) && nr(down.m[2], Vec3(0, -1, 0)),
           "the thinnest axis must follow the reference direction: got "
           ~ sv(up.m[2]) ~ " and " ~ sv(down.m[2]));
    assert(nr(down.m[0], Vec3(0, 0, -1)) && nr(down.m[1], Vec3(-1, 0, 0)),
           "the negation is of ALL NINE entries, not of row 2 alone — the "
           ~ "in-plane rows must flip with it. Got " ~ sm(down));
}

unittest { // translation invariance
    Vec3[] shifted;
    foreach (p; topFace()) shifted ~= p + Vec3(7.25f, -3.5f, 11.75f);
    auto a = obbFromPoints(topFace(), Vec3(0, 1, 0));
    auto b = obbFromPoints(shifted,   Vec3(0, 1, 0));
    foreach (i; 0 .. 3)
        assert(nr(a.m[i], b.m[i]),
               format("row %d moved under a pure translation: %s vs %s",
                      i, sv(a.m[i]), sv(b.m[i])));
    assert(nr(b.center, a.center + Vec3(7.25f, -3.5f, 11.75f)),
           "the box CENTRE must translate with the subject: " ~ sv(b.center));
}

unittest { // THE DIVISOR AND THE SUBTRACTION ARE ONE LAW — all four readings split
    // This subject separates every candidate implementation of the moment
    // step, which is the only reason it is worth having: a right triangle
    // whose bbox centre (1.5, 0.5) and mean (1, 2/3) are DIFFERENT points, so
    // `mu = mean - aabbCentre` is nonzero and the divisor stops being a
    // scalar. On anything centrally symmetric all four readings below collapse
    // onto one answer and this test would assert nothing.
    //
    // The four, as the principal in-plane axis they answer:
    //
    //   A  s = 1/n   on both          10.278 deg   ordinary covariance about
    //                                              the MEAN. What this port
    //                                              computed before task 0658,
    //                                              and the reading a reviewer
    //                                              is most likely to "restore"
    //                                              as the textbook one.
    //   B  s = 1/(2n) on both          8.581 deg   THE REFERENCE. Asserted.
    //   C  s = 1/(2n) on the second
    //      moments, 1/n on the first  14.089 deg   the half-applied form — a
    //                                              behaviour NEITHER engine
    //                                              has. It overshoots past A
    //                                              in the opposite direction,
    //                                              because it subtracts mu*mu^T
    //                                              at DOUBLE weight instead of
    //                                              half.
    //   D  no first-moment subtraction 7.018 deg   moments genuinely about the
    //                                              bbox centre.
    //
    // The tolerance below is 1e-4 on the direction; the nearest wrong reading
    // (D) is 0.0165 away and A is 0.0049 away, so the margin over the closest
    // one is fifty-fold. Which of B's two neighbours is closer is not an
    // accident worth relying on, hence both are named in the message.
    Vec3[] tri = [Vec3(0, 0, 0), Vec3(3, 1, 0), Vec3(0, 1, 0)];
    auto box = obbFromPoints(tri, Vec3(0, 0, 1));
    assert(nr(box.m[0], Vec3(0.988806f, 0.149207f, 0), 1e-4f),
           "the principal axis must be the reference's — 8.581 deg, "
           ~ "(0.98881, 0.14921, 0); got " ~ sv(box.m[0])
           ~ ". The three wrong readings are named by their answer: "
           ~ "(0.98395, 0.17843, 0) = 10.278 deg is s = 1/n on both moments, "
           ~ "the ordinary covariance about the mean; "
           ~ "(0.96992, 0.24343, 0) = 14.089 deg is the divisor applied to the "
           ~ "SECOND moments only, which is half a law and belongs to no "
           ~ "engine; (0.99251, 0.12219, 0) = 7.018 deg is the first-moment "
           ~ "subtraction dropped entirely. See this module's header.");
}

unittest { // translation invariance survives the divisor — mu is a DIFFERENCE
    // `C = (1/2)[Cov + (1/2) mu mu^T]` is translation-invariant because both
    // terms are: `mu = mean - aabbCentre` is a difference of two points that
    // translate together. This is the same claim the symmetric-subject
    // translation test above makes, but on a subject where `mu != 0`, so the
    // added rank-1 term is actually exercised rather than being zero.
    Vec3[] tri = [Vec3(0, 0, 0), Vec3(3, 1, 0), Vec3(0, 1, 0)];
    Vec3[] moved;
    foreach (p; tri) moved ~= p + Vec3(-4.5f, 12.25f, 6.75f);
    auto a = obbFromPoints(tri,   Vec3(0, 0, 1));
    auto b = obbFromPoints(moved, Vec3(0, 0, 1));
    foreach (i; 0 .. 3)
        assert(nr(a.m[i], b.m[i]),
               format("row %d of an OFF-CENTRE subject moved under a pure "
                      ~ "translation: %s vs %s. The rank-1 term the divisor "
                      ~ "adds must be built from mean MINUS bbox centre; a "
                      ~ "port that built it from the mean alone would fail "
                      ~ "exactly here and nowhere else.",
                      i, sv(a.m[i]), sv(b.m[i])));
}

unittest { // the divisor changes an OUTCOME, not only a number
    // The rotation the previous test measures is continuous, and a reader can
    // fairly ask whether the divisor ever changes anything CATEGORICAL. It
    // does: the added `(1/2) mu mu^T` is positive semidefinite ALONG mu, so it
    // raises the variance in that direction only, and when it is aimed at the
    // shorter of two close in-plane axes it lifts that eigenvalue past the
    // other and the rows swap ORDER.
    //
    // This subject is a rectangle mirror-symmetric in X — so both readings
    // answer exact world axes and no rotation can be confused for the swap —
    // with a small notch on one Z edge that drags the mean off the bbox centre
    // along Z. Half-width 1.16 against half-depth 1.0 makes X the longer axis
    // by variance under `1/n`; the notch's mu points along Z and the divisor's
    // rank-1 term hands the lead to Z.
    //
    // The swap also drives the row order and the EXTENT order apart, and that
    // is asserted second because it is the sharper statement: after the swap
    // row 0 is the SHORTER axis (Z spans 2.0, X spans 2.32). No ordering
    // derived from the extents could ever produce that, so it pins "the rows
    // are ordered by EIGENVALUE" — the law this module's header states — in a
    // way the symmetric rigs cannot, since on those two orders coincide.
    //
    // NOTE, and it is why this is a `unittest` on the BOX and not a test on
    // the published frame: `axisFrameFromBox` elects `right` by |x| across
    // rows 0 and 1, which is itself invariant under swapping them. So this
    // categorical change is observable in `ObbFrame` and is INVISIBLE
    // downstream. The divisor's effect that IS visible downstream is the
    // rotation, measured against the reference in
    // `tests/test_obb_covariance_divisor.d`.
    enum float AX = 1.16f, NOTCH = 0.15f;
    Vec3[] notched = [
        Vec3(-AX, 0, -1.0f), Vec3(AX, 0, -1.0f), Vec3(AX, 0, 1.0f),
        Vec3(-AX, 0, 1.0f),  Vec3(0, 0, 1.0f),   Vec3(0, 0, 1.0f - NOTCH),
    ];
    auto box = obbFromPoints(notched, Vec3(0, 1, 0));
    assert(nr(box.m[0], Vec3(0, 0, 1)) && nr(box.m[1], Vec3(1, 0, 0)),
           "row 0 must be world Z — the divisor's rank-1 term lifts the Z "
           ~ "variance past the X one on this subject. Got " ~ sm(box)
           ~ ". Rows (1,0,0) / (0,0,1) are the ORDER the plain 1/n covariance "
           ~ "answers here, i.e. the divisor reverted. Nothing else can "
           ~ "produce that swap: the subject is mirror-symmetric in X, so both "
           ~ "readings give exact world axes and only their ORDER differs.");
    assert(box.size[0] < box.size[1],
           format("after the swap the LEADING row must be the SHORTER axis — "
                  ~ "Z spans 2.0 against X's 2.32 — so the extents must come "
                  ~ "out (2, 2.32); got (%g, %g). (2.32, 2) is the plain 1/n "
                  ~ "order, and it is also the order any extent-driven sort "
                  ~ "would answer. This pins that the rows are ordered by "
                  ~ "EIGENVALUE and not by span.", box.size[0], box.size[1]));
}

unittest { // THE REFUSAL — an isotropic lattice answers world axes, not 45deg
    // A 5x5 grid on an off-lattice centre is the rig the reference was
    // recorded on, and it is the rig that lands on the wrong side of its own
    // cliff: its cross moment is one cancellation residue away from zero
    // (2^-56 in the recording) and the reference therefore rotates by EXACTLY
    // 45 degrees. Ours reaches a residue of its own, and the relative
    // degeneracy test throws it away.
    //
    // The spacing below is not decorative: a lattice on 0.1 boundaries
    // cancels EXACTLY in our arithmetic and reaches the eigensolver's
    // already-diagonal early-out, which would make this test pass without ever
    // running the stabiliser. This one leaves a residue of -2.2e-18 against
    // BIT-EQUAL diagonals — the reference's exact cliff condition — so the
    // relative degeneracy test is the only thing standing between it and a
    // 45-degree answer.
    Vec3[] grid;
    foreach (i; 0 .. 5)
        foreach (j; 0 .. 5)
            grid ~= Vec3(0.1f + i * 0.3f, 0.0f, 0.1f + j * 0.3f);
    auto box = obbFromPoints(grid, Vec3(0, 1, 0));
    assert(nr(box.m[0], Vec3(0, 0, 1)) && nr(box.m[1], Vec3(1, 0, 0))
           && nr(box.m[2], Vec3(0, 1, 0)),
           "an isotropic planar lattice must answer the WORLD axes — the "
           ~ "reference's own exact-zero branch, and the convention this port "
           ~ "declares. Got " ~ sm(box) ~ ". Rows near (0.7071, 0, 0.7071) "
           ~ "mean the degeneracy stabiliser stopped firing and a 45-degree "
           ~ "answer produced by OUR rounding is leaking out. That answer is a "
           ~ "fingerprint of a summation order, not a behaviour, and it is "
           ~ "deliberately not chased.");
}

unittest { // the degeneracy test is RELATIVE, and this is its threshold
    // The refusal above says "never a bit compare". A bit compare would mean a
    // subject that misses being square by one float32 ulp gets a data-driven
    // in-plane answer while a subject that hits it exactly gets a convention —
    // the same cliff, one level up. So the test is `|li - lj| <= 1e-6 * lmax`,
    // and these two rows are the two sides of it: the same rectangle, rotated
    // 30 degrees in its own plane, differing only in aspect ratio.
    static Vec3[] rect(float d) {
        enum float C = 0.8660254f, S = 0.5f;      // 30 degrees
        float a = 0.5f, b = 0.5f * (1.0f + d);
        Vec3[] r;
        foreach (sx; [-1.0f, 1.0f])
            foreach (sz; [-1.0f, 1.0f]) {
                float lx = sx * a, lz = sz * b;
                r ~= Vec3(lx * C + lz * S, 0.0f, -lx * S + lz * C);
            }
        return r;
    }
    // Square to within a fifth of a part per million: TREATED AS SQUARE, so
    // the in-plane pair is the declared convention and not the 30 degrees a
    // noise-driven eigensolver would report.
    auto near = obbFromPoints(rect(2e-7f), Vec3(0, 1, 0));
    assert(nr(near.m[0], Vec3(0, 0, 1)) && nr(near.m[1], Vec3(1, 0, 0)),
           "a subject square to within 2e-7 must take the declared degenerate "
           ~ "convention (world axes in its plane); got " ~ sm(near)
           ~ ". An answer near (0.5, 0, 0.866) is the eigensolver resolving a "
           ~ "difference that is float noise, which is what the RELATIVE test "
           ~ "exists to refuse.");
    // Two percent out of square: a real shape, and it keeps its own frame.
    auto far = obbFromPoints(rect(2e-2f), Vec3(0, 1, 0));
    assert(nr(far.m[0], Vec3(0.5f, 0, 0.8660254f), 1e-4f),
           "a 1 x 1.02 rectangle is NOT square and must keep its own 30-degree "
           ~ "in-plane axis; got " ~ sm(far) ~ ". World axes here would mean "
           ~ "the degeneracy threshold has swallowed a real shape.");
}

unittest { // a NON-degenerate planar subject: the eigenvectors, not a convention
    // A 1 x 3 rectangle rotated 30 degrees about X. Two well-separated
    // in-plane second moments, so nothing here comes from the degenerate
    // convention: row 0 is the long axis, row 1 the short one, row 2 the
    // normal, and all three are the covariance's own answer.
    enum float C = 0.8660254f, S = 0.5f;
    Vec3[] r;
    foreach (t; [-1.5f, 1.5f])
        foreach (u; [-0.5f, 0.5f])
            // (u, 0, t) rotated about X by 30 degrees
            r ~= Vec3(u, -t * S, t * C);
    Vec3 n = Vec3(0, C, S);
    auto box = obbFromPoints(r, n);
    // Row 2's SIGN is the one the post-processing decides, so it is asserted
    // exactly; rows 0 and 1 are asserted as directions, because an
    // eigenvector's sign is the eigensolver's business and the published frame
    // is rebuilt right-handed from row 2 regardless.
    assert(nr(box.m[2], n, 1e-4f),
           "row 2 must be the plane normal (0, 0.866, 0.5), oriented to agree "
           ~ "with the reference direction; got " ~ sv(box.m[2]));
    assert(fabs(fabs(dot(box.m[0], Vec3(0, -S, C))) - 1.0f) < 1e-4f,
           "row 0 must be the LONG in-plane axis (0, -0.5, 0.866) — the "
           ~ "descending order puts the largest second moment first; got "
           ~ sv(box.m[0]));
    assert(fabs(fabs(dot(box.m[1], Vec3(1, 0, 0))) - 1.0f) < 1e-4f,
           "row 1 must be the SHORT in-plane axis; got " ~ sv(box.m[1]));
    assert(fabs(box.size[0] - 3.0) < 1e-4 && fabs(box.size[1] - 1.0) < 1e-4,
           format("extents must be 3 then 1 — the rows are ordered by "
                  ~ "eigenvalue, which on this subject also orders the "
                  ~ "extents; got (%g, %g)", box.size[0], box.size[1]));
}

unittest { // count == 1 — the vertex normal, orthonormalised
    auto box = obbFromVertexNormal(Vec3(1, 2, 3), Vec3(0, 0, 4), 2);
    assert(box.source == ObbSource.VertexNormal && box.count == 1,
           "a one-point subject must not take the covariance path");
    assert(nr(box.m[2], Vec3(0, 0, 1)), "row 2 is the normalised normal");
    // normal is Z-dominant, so the seed is world Y (the up hint only fires on
    // a Y-DOMINANT normal).
    assert(nr(box.m[0], Vec3(1, 0, 0)) && nr(box.m[1], Vec3(0, 1, 0)),
           "row 0 = seed x normal, row 1 = normal x row 0; got " ~ sm(box));
    // A Y-dominant normal takes the declared up hint instead of world Y.
    auto yb = obbFromVertexNormal(Vec3(0, 0, 0), Vec3(0, 5, 0), 2);
    assert(nr(yb.m[2], Vec3(0, 1, 0)) && fabs(yb.m[0].y) < 1e-5f
           && fabs(yb.m[1].y) < 1e-5f,
           "with a Y-dominant normal the seed must NOT be world Y — that is "
           ~ "the one place the reference consults the viewport work plane and "
           ~ "we substitute a declared constant. Got " ~ sm(yb));
    assert(box.center.x == 1 && box.center.y == 2 && box.center.z == 3,
           "the box centre is the vertex itself");
}

unittest { // count == 2 — the edge, and its sign convention
    // The direction's DOMINANT COMPONENT is forced positive. This is the one
    // rule on the two-point arm that is a convention rather than geometry, and
    // it means the frame does not depend on which end of the edge was
    // enumerated first.
    auto ab = obbFromEdge(Vec3(-1, 0, 0), Vec3(3, 0, 0), Vec3(0, 1, 0), true);
    auto ba = obbFromEdge(Vec3(3, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), true);
    assert(nr(ab.m[0], Vec3(1, 0, 0)) && nr(ba.m[0], Vec3(1, 0, 0)),
           "both orders must answer +X: got " ~ sv(ab.m[0]) ~ " and "
           ~ sv(ba.m[0]));
    assert(nr(ab.m[1], Vec3(0, 1, 0)) && nr(ab.m[2], Vec3(0, 0, 1)),
           "row 1 is the edge's average polygon normal, row 2 their cross; got "
           ~ sm(ab));
    assert(ab.source == ObbSource.EdgePair && ab.count == 2,
           "a two-point subject must not take the covariance path");
    // With no bounding polygon the second row degrades to the world axis AFTER
    // the direction's dominant component.
    auto free = obbFromEdge(Vec3(0, 0, 0), Vec3(0, 0, 2), Vec3(0, 0, 0), false);
    assert(nr(free.m[0], Vec3(0, 0, 1)) && nr(free.m[1], Vec3(1, 0, 0)),
           "dominant component is z (index 2), so the fallback seed is world "
           ~ "(2+1)%3 = 0 = +X; got " ~ sm(free));
}

unittest { // the box -> packet mapping reproduces the recorded published frame
    auto box = obbFromPoints(topFace(), Vec3(0, 1, 0));
    Vec3 r, u, f;
    axisFrameFromBox(box, r, u, f);
    assert(nr(r, Vec3(1, 0, 0)) && nr(u, Vec3(0, 0, -1)) && nr(f, Vec3(0, 1, 0)),
           "the recorded published frame for this rig is (+X, -Z, +Y); got "
           ~ sv(r) ~ " " ~ sv(u) ~ " " ~ sv(f));
    // and the frame the mapping publishes is ALWAYS right-handed, even though
    // the box's own rows need not be — the sign fix flips their determinant.
    Vec3 c = cross(r, u);
    assert(nr(c, f), "right x up must be fwd; got " ~ sv(c));
}

unittest { // count == 0 answers the identity and reports failure
    Vec3[] none;
    auto box = obbFromPoints(none, Vec3(0, 1, 0));
    assert(!box.ok && box.count == 0,
           "an empty enumeration reports failure");
    assert(nr(box.m[0], Vec3(1, 0, 0)) && nr(box.m[1], Vec3(0, 1, 0))
           && nr(box.m[2], Vec3(0, 0, 1)),
           "and leaves the preloaded IDENTITY behind, so a caller that "
           ~ "ignores the failure still gets world axes rather than garbage");
}
