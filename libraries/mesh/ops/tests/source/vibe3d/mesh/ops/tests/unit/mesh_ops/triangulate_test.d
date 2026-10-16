module vibe3d.mesh.ops.tests.unit.mesh_ops.triangulate_test;

import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math;
import vibe3d.mesh.ops.mesh_ops.triangulate : triangulateFacesByMask;
import std.math : sqrt, abs, cos, sin, PI;
import std.format : format;
import tests.unit.fixtures : makeTaggedGrid;

version (unittest) {
private static Vec3 t_s1_centroid(ref Mesh m, size_t fi) {
    Vec3 c = Vec3(0, 0, 0);
    auto f = m.faces[fi];
    foreach (vi; f) c = c + m.vertices[vi];
    return Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
}
private static size_t t_s1_findByCentroid(ref Mesh m, Vec3 target) {
    foreach (fi; 0 .. m.faces.length)
        if ((t_s1_centroid(m, fi) - target).length < 1e-4) return fi;
    assert(false, "T-S1 fixture broke: no face survived at the expected centroid");
}
private static void t_s1_assertOnlyThatSurvivorHidden(ref Mesh m, Vec3 targetCentroid,
                                                       string label) {
    immutable size_t survivor = t_s1_findByCentroid(m, targetCentroid);
    assert(m.isFaceHidden(survivor),
        label ~ ": the face at f3's original centroid must still be hidden");
    foreach (fi; 0 .. m.faces.length)
        if (fi != survivor)
            assert(!m.isFaceHidden(fi),
                label ~ ": no OTHER face may have picked up the bit");
}
private static Mesh t_s1_grid() {
    Vec3[] verts = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0),
        Vec3(0, 1, 0), Vec3(1, 1, 0), Vec3(2, 1, 0),
        Vec3(0, 2, 0), Vec3(1, 2, 0), Vec3(2, 2, 0),
    ];
    uint[][] faceList = [
        [0, 1, 4, 3],   // f0, centroid (0.5, 0.5, 0)
        [1, 2, 5, 4],   // f1, centroid (1.5, 0.5, 0)
        [3, 4, 7, 6],   // f2, centroid (0.5, 1.5, 0)
        [4, 5, 8, 7],   // f3, centroid (1.5, 1.5, 0) — the one we hide
    ];
    return buildRawMesh(verts, faceList);
}
private enum Vec3 t_s1_f3Centroid = Vec3(1.5f, 1.5f, 0);
}

unittest { // T-S1 (triangulate) — triangulateFacesByMask. Triangulating
    // f0 GROWS the array (one quad -> two triangles): everything after f0
    // shifts UP by one instead of down — the complementary shift
    // direction to delete/dissolve/weld's shrink. f3 ends at index 4, not 3.
    auto m = t_s1_grid();
    m.setFaceHidden(3, true);
    bool[] mask = new bool[](4);
    mask[0] = true;
    immutable size_t changed = triangulateFacesByMask(m, mask);
    assert(changed == 1);
    assert(m.faces.length == 5, "T-S1 triangulate: f0 became 2 triangles");
    t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 triangulate");
}

unittest { // triangulateFacesByMask: cube (6 quads) → 12 tris, same verts
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    size_t changed = triangulateFacesByMask(m, mask);
    assert(changed == 6, "triple: expected 6 changed faces, got " ~ changed.to!string);
    assert(m.faces.length == 12, "triple: expected 12 faces");
    assert(m.vertices.length == 8, "triple: expected 8 verts (no new verts)");
    assert(m.edges.length == 18,   "triple: expected 18 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 3,
            "triple: face " ~ fi.to!string ~ " is not a triangle");
}

unittest { // triangulateFacesByMask: subpatch bit propagates to children
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    // Mark face 0 as subpatch before triangulating.
    m.resizeSubpatch();       // ensure faceMarks exists (was setFaceSubpatchFrom's job)
    m.setSubpatch(0, true);
    auto mask = new bool[](m.faces.length);
    mask[0] = true;  // only face 0
    triangulateFacesByMask(m, mask);
    // faces 0..n-1 are now 2 tris from old face 0; the rest are the 5 old quads.
    // The first two faces (children of old face 0) should be subpatch.
    assert(m.isFaceSubpatch(0), "child tri 0 should inherit parent subpatch bit");
    assert(m.isFaceSubpatch(1), "child tri 1 should inherit parent subpatch bit");
    // The old untouched faces start at index 2; none should be subpatch.
    foreach (fi; 2 .. m.faces.length)
        assert(!m.isFaceSubpatch(fi),
            "non-child face " ~ fi.to!string ~ " should not be subpatch");
}

unittest { // triangulateFacesByMask: faceOrigin maps children → parent
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    uint[] faceOrigin;
    triangulateFacesByMask(m, mask, &faceOrigin);
    assert(faceOrigin.length == 12,
        "faceOrigin length should match new face count");
    // Each original face produced 2 children; children 0,1 → parent 0,
    // children 2,3 → parent 1, etc. (fan always produces 2 tris from a quad).
    foreach (fi; 0 .. 12)
        assert(faceOrigin[fi] == fi / 2,
            "faceOrigin[" ~ fi.to!string ~ "] = " ~ faceOrigin[fi].to!string
            ~ ", expected " ~ (fi / 2).to!string);
}

unittest { // triangulateFacesByMask: SOUNDNESS over adversarial rings at every
           // rotation, and the ORBIT the ported law actually produces —
           // tasks 1190 (soundness) and 1280 (the law it now guards).
    //
    // WHAT 1190 BUILT THIS FOR, and what still holds. A geometric fan anchor
    // makes the orbit invariant but says nothing about whether the triangles
    // are any good, and the reverse is also true. Measured against the old fan
    // from `ring[0]` on a 306-cell corpus of these same families: 126 cells
    // failed the area sum, 259 triangles fell outside the ring, 330 were
    // zero-area, and all 36 orbits were ring-order dependent.
    //
    // WHAT TASK 1280 CHANGED HERE, AND WHY IT IS NOT A WEAKENING. Two of the
    // four original checks were assertions about a law that has since been
    // replaced by the reference's, so they now assert the wrong thing:
    //
    //   * "rotating the ring gives the same triangle set" was 1190's DECISION,
    //     taken because the reference looked ring-invariant on the three shapes
    //     measured then. It is not: on a horseshoe it gives three
    //     decompositions over eight rotations. The check is replaced by the
    //     ORBIT PATTERN each family actually produces — which is a strictly
    //     tighter assertion than "all equal", because it reddens if any
    //     rotation moves in either direction, including toward invariance.
    //   * "every triangle wound the same way as the ring" ignored the `rev`
    //     term: a ring whose first corner is reflex has EVERY triangle wound
    //     the other way (divergence-ledger row 51). The check is replaced by
    //     recomputing `rev` from its own predicate and asserting the sign the
    //     predicate demands — so the winding law is pinned rather than assumed.
    //
    // The two checks that carry the soundness — the count, and the |area| the
    // triangles cover — are UNCHANGED and still hard zeros, and they are where
    // a fan dies: re-anchoring the clip to a merely geometric fan reddens the
    // coverage check on 29 of these 36 cells, with a worst error of 133%.
    //
    // EXACTLY ONE OF THE THREE COUNTERS IS NONZERO, AND IT IS STRUCTURAL. Read
    // this as a property of the law, not as a soundness check we failed to
    // hold. Of the three the old fan broke, the ported law scores:
    //
    //   triangles outside their own polygon .......... 0 of 36 cells
    //   cells whose triangles do not cover the ring ... 0 of 36 cells
    //   ZERO-AREA triangles .......................... 7, all on `comb`
    //
    // The seven are one triangle each on seven of the comb's eleven rotations,
    // and they are not a choice the pick rule makes. The comb has five
    // collinear base points; once the spikes are clipped the remainder is a
    // quad with three collinear corners, and BOTH of that quad's two possible
    // clips leave a degenerate triangle — by then it is decided, and the last
    // emit is unconditional. Coverage stays exact because a zero-area triangle
    // covers nothing, so the decomposition is still sound in the sense the two
    // hard counters measure; what is lost is only the guarantee that no face
    // comes out degenerate. Frozen below as an exact census: if it appears
    // anywhere else, or stops appearing here, this reddens.
    import std.conv : to;
    import std.math : fabs, cos, sin, PI;

    static double ringArea2(const Vec3[] r) {
        double s = 0;
        foreach (i; 0 .. r.length) {
            const a = r[i], b = r[(i + 1) % r.length];
            s += cast(double)a.x * b.z - cast(double)b.x * a.z;
        }
        return s;
    }
    static double tri2(Vec3 a, Vec3 b, Vec3 c) {
        return (cast(double)b.x - a.x) * (cast(double)c.z - a.z)
             - (cast(double)c.x - a.x) * (cast(double)b.z - a.z);
    }
    // The kernel's own frame for a planar-XZ ring is (u,v) = (z,x) — its
    // dominant axis is Y, and AXIS0/AXIS1 send that to (2,0). `rev` is computed
    // in THAT frame, so the test has to be too; doing it in (x,z) flips both
    // terms and silently agrees anyway, which would make this vacuous.
    static double detZX(Vec3 a, Vec3 b, Vec3 c) {
        return (cast(double)b.z - a.z) * (cast(double)c.x - a.x)
             - (cast(double)c.z - a.z) * (cast(double)b.x - a.x);
    }
    static int orientZX(Vec3 a, Vec3 b, Vec3 c) { return detZX(a, b, c) >= 0 ? 1 : 0; }
    static int shoelaceSignZX(const Vec3[] r) {
        double s = 0;
        foreach (i; 0 .. r.length) {
            const a = r[i], b = r[(i + 1) % r.length];
            s += cast(double)a.z * b.x - cast(double)b.z * a.x;
        }
        return s >= 0 ? 1 : 0;
    }
    // A triangle named by its three positions, order-free, so two rotations
    // can be compared without assuming anything about vertex numbering.
    static string triKeyOf(Vec3 a, Vec3 b, Vec3 c) {
        string[3] k = [format("%.4f,%.4f", a.x, a.z),
                       format("%.4f,%.4f", b.x, b.z),
                       format("%.4f,%.4f", c.x, c.z)];
        foreach (i; 0 .. 3) foreach (j; i + 1 .. 3)
            if (k[j] < k[i]) { auto t = k[i]; k[i] = k[j]; k[j] = t; }
        return k[0] ~ "|" ~ k[1] ~ "|" ~ k[2];
    }

    Vec3[][] corpus;
    string[] names;
    // The orbit each family produces under the ported law, one digit per
    // rotation: equal digits mean the same triangle SET (winding ignored).
    // These are PREDICTIONS — derived from the law offline before the kernel
    // was written, and reproduced by it — not a recording of whatever the
    // kernel happened to do.
    string[] wantOrbit;
    // Rotations that carry a zero-area triangle, and how many.
    size_t[][] wantDegenerate;

    // eight-pointed star: four reflex corners, four congruent tips (an exact
    // tie, which is what makes its orbit split at all)
    {
        Vec3[] r;
        foreach (i; 0 .. 8) {
            immutable double a = 2.0 * PI * i / 8.0;
            immutable double rad = (i % 2 == 0) ? 1.0 : 0.35;
            r ~= Vec3(cast(float)(cos(a) * rad), 0, cast(float)(sin(a) * rad));
        }
        corpus ~= r; names ~= "star8";
        wantOrbit ~= "00110011"; wantDegenerate ~= new size_t[](8);
    }
    // a square with three EXTRA collinear points on one edge — the family the
    // old fan turned into zero-area triangles
    {
        Vec3[] r = [Vec3(0,0,0), Vec3(0.75f,0,0), Vec3(1.5f,0,0), Vec3(2.25f,0,0),
                    Vec3(3,0,0), Vec3(3,0,3), Vec3(0,0,3)];
        corpus ~= r; names ~= "collinear_run";
        wantOrbit ~= "0000001"; wantDegenerate ~= new size_t[](7);
    }
    // deep notches: thin ears and many reflex corners
    {
        Vec3[] r;
        foreach (i; 0 .. 4) {
            r ~= Vec3(cast(float)i, 0, 0);
            r ~= Vec3(cast(float)i + 0.5f, 0, 1.6f);
        }
        r ~= Vec3(4, 0, 0); r ~= Vec3(4, 0, -1); r ~= Vec3(0, 0, -1);
        corpus ~= r; names ~= "comb";
        wantOrbit ~= "00011111112";
        wantDegenerate ~= [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0];
    }
    // the dart — the smallest ring the old fan got wrong
    {
        corpus ~= [Vec3(0,0,0), Vec3(2,0,1.2f), Vec3(4,0,0), Vec3(2,0,3)];
        names ~= "dart";
        wantOrbit ~= "0000"; wantDegenerate ~= new size_t[](4);
    }
    // one reflex AND one exactly-collinear corner on the same ring
    {
        corpus ~= [Vec3(0,0,0), Vec3(2,0,0), Vec3(4,0,0),
                   Vec3(4,0,4), Vec3(2,0,1.4f), Vec3(0,0,4)];
        names ~= "reflex_and_flat_hex";
        wantOrbit ~= "000000"; wantDegenerate ~= new size_t[](6);
    }

    foreach (ci, base; corpus) {
        immutable size_t n = base.length;
        immutable double want = fabs(ringArea2(base));
        immutable double tol  = 1e-4 * (want > 1.0 ? want : 1.0);
        string[] orbitKeys;
        size_t[] orbitOf;
        foreach (rot; 0 .. n) {
            Vec3[] r;
            foreach (k; 0 .. n) r ~= base[(rot + k) % n];
            immutable double sgn = ringArea2(r) > 0 ? 1.0 : -1.0;

            // `rev`, recomputed from its own predicate rather than taken on
            // trust: the corner at ring index 0 disagreeing with the ring's
            // own orientation is what turns every emitted triangle over.
            immutable bool rev =
                orientZX(r[n - 1], r[0], r[1]) != shoelaceSignZX(r);
            immutable double wantSign = rev ? -sgn : sgn;

            Mesh m;
            m.vertices = r.dup;
            uint[] ring;
            foreach (k; 0 .. n) ring ~= cast(uint)k;
            m.addFace(ring);
            m.buildLoops();
            m.resetSelection();
            auto mask = new bool[](m.faces.length);
            mask[] = true;
            triangulateFacesByMask(m, mask);

            immutable string who = names[ci] ~ " rot" ~ rot.to!string;
            assert(m.faces.length == n - 2,
                who ~ ": expected " ~ (n - 2).to!string ~ " triangles, got "
                ~ m.faces.length.to!string);

            double sum = 0;
            size_t degenerate = 0;
            string[] keys;
            foreach (fi; 0 .. m.faces.length) {
                assert(m.faces[fi].length == 3, who ~ ": face " ~ fi.to!string
                    ~ " is not a triangle");
                const a = m.vertices[m.faces[fi][0]];
                const b = m.vertices[m.faces[fi][1]];
                const c = m.vertices[m.faces[fi][2]];
                immutable double s = tri2(a, b, c);
                if (fabs(s) <= tol * 1e-3) {
                    ++degenerate;
                } else {
                    assert(s * wantSign > 0,
                        who ~ ": triangle " ~ fi.to!string ~ " has signed area "
                        ~ s.to!string ~ " but the ring's own winding and the `rev`"
                        ~ " predicate (rev=" ~ rev.to!string ~ ") demand sign "
                        ~ wantSign.to!string ~ " — a fan from a fixed ring index"
                        ~ " produced inverted triangles on this shape, and so"
                        ~ " does a clip that drops the rev term");
                }
                sum += fabs(s);
                keys ~= triKeyOf(a, b, c);
            }
            assert(fabs(sum - want) <= tol,
                who ~ ": the triangles cover " ~ sum.to!string
                ~ " but the ring encloses " ~ want.to!string
                ~ " — they overlap, leave a gap, or one of them strayed outside"
                ~ " the polygon. THIS is the check a geometric fan anchor fails:"
                ~ " it is invariant and still wrong, on 29 of these 36 cells");

            assert(degenerate == wantDegenerate[ci][rot],
                who ~ ": " ~ degenerate.to!string ~ " zero-area triangle(s),"
                ~ " the frozen census says " ~ wantDegenerate[ci][rot].to!string
                ~ ". The comb's seven are the collinear remainder the ported law"
                ~ " cannot avoid; anywhere else this is a new defect");

            foreach (i; 0 .. keys.length)
                foreach (j; i + 1 .. keys.length)
                    if (keys[j] < keys[i]) { auto t = keys[i]; keys[i] = keys[j]; keys[j] = t; }
            string joined;
            foreach (k; keys) joined ~= k ~ ";";
            size_t slot = size_t.max;
            foreach (oi, ok; orbitKeys) if (ok == joined) { slot = oi; break; }
            if (slot == size_t.max) { slot = orbitKeys.length; orbitKeys ~= joined; }
            orbitOf ~= slot;
        }

        string got;
        foreach (o; orbitOf) got ~= cast(char)('0' + o);
        assert(got == wantOrbit[ci],
            names[ci] ~ ": orbit is " ~ got ~ ", the ported law gives "
            ~ wantOrbit[ci] ~ ". Since task 1280 our triangulation DOES follow"
            ~ " where the ring starts, on purpose — a run that comes back all"
            ~ " zeroes here has reverted to the ring-invariant law, and one that"
            ~ " splits further has drifted off the ported one");
    }
}

unittest { // triangulateFacesByMask: a per-CORNER map value must travel with
           // the corner the ear clip actually named — task 1190.
    //
    // The kernel used to hardcode the fan's mapping (old corners 0, i, i+1).
    // Now the diagonals are chosen geometrically, so a triangle's corners can
    // be any three ring positions, and `declareCornerProvenance` has to be
    // told the REAL ones. Get this wrong and UVs land on foreign corners in
    // silence — the geometry is identical either way, which is exactly why
    // this needs its own check.
    //
    // The ring is the reflex pentagon from ledger row 25, chosen because the
    // clip does NOT fan from corner 0 on it (it fans from the reflex corner,
    // ring index 3). On a convex quad the two mappings would coincide and this
    // test would prove nothing.
    import std.conv : to;
    import vibe3d.mesh.core.mesh : kUvMapName, MapDomain;

    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0
        Vec3(4, 0, 0),   // 1
        Vec3(4, 0, 4),   // 2
        Vec3(2, 0, 1),   // 3  — the reflex corner
        Vec3(0, 0, 4),   // 4
    ];
    m.addFace([0u, 1u, 2u, 3u, 4u]);
    m.buildLoops();
    m.resetSelection();

    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "failed to register the UV map");
    assert(uv.data.length == 10, "UV map must be sized to 5 corners * dim 2");
    // One unmistakable value per corner: u = vertex id, v = 100 + vertex id.
    foreach (c; 0 .. 5) {
        uv.data[2*c]     = cast(float)c;
        uv.data[2*c + 1] = 100.0f + cast(float)c;
    }

    auto mask = new bool[](m.faces.length);
    mask[] = true;
    const changed = triangulateFacesByMask(m, mask);
    assert(changed == 1, "expected 1 triangulated face, got " ~ changed.to!string);
    assert(m.faces.length == 3, "a pentagon must give 3 triangles, got "
        ~ m.faces.length.to!string);

    auto after = m.meshMap(kUvMapName);
    assert(after !is null, "UV map lost by triangulation");
    assert(after.data.length == m.loops.length * 2,
        "UV map length " ~ after.data.length.to!string ~ " != loops "
        ~ m.loops.length.to!string ~ " * 2");

    // No vertex is created or moved here, and every vertex appears in exactly
    // one corner of the source pentagon — so the authored value for a corner
    // is recoverable from its vertex id, and a corner that ended up with a
    // DIFFERENT vertex's value is a mis-mapped corner, not a lost one.
    size_t slot = 0;
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            immutable uint v = m.faces[fi][c];
            assert(after.data[2*slot] == cast(float)v
                && after.data[2*slot + 1] == 100.0f + cast(float)v,
                "face " ~ fi.to!string ~ " corner " ~ c.to!string
                ~ " (vertex " ~ v.to!string ~ ") carries UV ("
                ~ after.data[2*slot].to!string ~ ", "
                ~ after.data[2*slot + 1].to!string
                ~ ") — it belongs to vertex "
                ~ (cast(uint)after.data[2*slot]).to!string
                ~ ". The corner provenance declared by triangulateFacesByMask "
                ~ "does not name the corners the ear clip actually used.");
            ++slot;
        }
    }
}

unittest { // earClipRingCorners: the PORTED choice law, frozen against every
           // cell the reference was measured on — task 1280.
    //
    // Nineteen rings, each with the reference's own output in EMISSION ORDER
    // and with the winding it stored. This is the whole of what the law was
    // ported from, so it is the whole of what a change to the law has to keep:
    // the metric (2*Area / longest side squared), the ring-order scan, the
    // early-out, the tie-break to the earlier ring index, the `rev` winding
    // term, and the containment-by-vertex-identity that makes `keyhole18` — an
    // 18-entry ring over 16 vertices, walking a bridge edge twice — come out
    // right with no repeated-vertex branch anywhere.
    //
    // WHAT SEPARATES WHAT, measured offline over these same cells before any of
    // it was written (see the task 1280 card):
    //   * the METRIC is separated hard — largest-AREA scores 4/19 here and 0/8
    //     on the horseshoe rotations; first-valid-ear scores 2/19.
    //   * the TIE-BREAK is separated — it is the entire reason the horseshoe
    //     gives three decompositions over its eight rotations.
    //   * the EARLY-OUT is bounded from BELOW by the wider 39-cell capture, and
    //     the bound is exactly 0.5 — under it, two of those cells break. Above
    //     it behaviour says nothing, so the constructed ring two blocks down is
    //     what pins `kTripleQualityEarlyOut` from the other side.
    //   * ONE cell needs the mode switch, and which one is the point. Task 1320
    //     ported the strip, so a bare call on a CONVEX ring no longer reaches
    //     the clip at all. Eighteen of these nineteen rings are concave, fail
    //     the strip's convexity gate and land here exactly as before — which is
    //     itself an assertion worth having, since it is what kept every
    //     concave fixture in agreement while only the clip was ported. The
    //     nineteenth, `oct_quality`, is a convex octagon that the strip would
    //     now take, and it was measured down the clip: it is driven with
    //     `TriangulateMode.EarClip` and is the reason that switch exists.
    import std.conv : to;
    static struct C { string name; Vec3[] verts; uint[] ring; uint[3][] want;
                      Mesh.TriangulateMode mode = Mesh.TriangulateMode.Strip; }
    auto cells = [
        C("horse_rot0", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u], [[2u,3u,4u], [5u,6u,7u], [1u,2u,4u], [0u,1u,4u], [5u,7u,0u], [0u,4u,5u]]),
        C("horse_rot1", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [1u, 2u, 3u, 4u, 5u, 6u, 7u, 0u], [[2u,3u,4u], [5u,6u,7u], [1u,2u,4u], [0u,1u,4u], [5u,7u,0u], [4u,5u,0u]]),
        C("horse_rot2", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [2u, 3u, 4u, 5u, 6u, 7u, 0u, 1u], [[2u,3u,4u], [5u,6u,7u], [1u,2u,4u], [5u,7u,0u], [5u,0u,1u], [4u,5u,1u]]),
        C("horse_rot3", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [3u, 4u, 5u, 6u, 7u, 0u, 1u, 2u], [[2u,3u,4u], [5u,6u,7u], [5u,7u,0u], [5u,0u,1u], [1u,2u,4u], [4u,5u,1u]]),
        C("horse_rot4", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [4u, 5u, 6u, 7u, 0u, 1u, 2u, 3u], [[5u,7u,6u], [2u,4u,3u], [5u,0u,7u], [5u,1u,0u], [1u,4u,2u], [4u,1u,5u]]),
        C("horse_rot5", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [5u, 6u, 7u, 0u, 1u, 2u, 3u, 4u], [[5u,7u,6u], [2u,4u,3u], [5u,0u,7u], [5u,1u,0u], [1u,4u,2u], [5u,4u,1u]]),
        C("horse_rot6", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [6u, 7u, 0u, 1u, 2u, 3u, 4u, 5u], [[5u,6u,7u], [2u,3u,4u], [5u,7u,0u], [5u,0u,1u], [1u,2u,4u], [1u,4u,5u]]),
        C("horse_rot7", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [7u, 0u, 1u, 2u, 3u, 4u, 5u, 6u], [[2u,3u,4u], [5u,6u,7u], [5u,7u,0u], [5u,0u,1u], [1u,2u,4u], [1u,4u,5u]]),
        C("keyhole18", [Vec3(0.0f, 0.0f, 0.0f), Vec3(3.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 3.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(3.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 3.0f), Vec3(1.5f, 0.0f, 1.5f), Vec3(3.0f, 0.0f, 1.5f), Vec3(4.5f, 0.0f, 1.5f), Vec3(4.5f, 0.0f, 3.0f), Vec3(4.5f, 0.0f, 4.5f), Vec3(3.0f, 0.0f, 4.5f), Vec3(1.5f, 0.0f, 4.5f), Vec3(1.5f, 0.0f, 3.0f)], [0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 0u, 8u, 15u, 14u, 13u, 12u, 11u, 10u, 9u, 8u], [[8u,0u,1u], [7u,0u,8u], [7u,8u,15u], [7u,15u,14u], [6u,7u,14u], [5u,6u,14u], [5u,14u,13u], [5u,13u,12u], [4u,5u,12u], [3u,4u,12u], [3u,12u,11u], [3u,11u,10u], [2u,3u,10u], [1u,2u,10u], [1u,10u,9u], [1u,9u,8u]]),
        C("mode_quality", [Vec3(0.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 4.0f), Vec3(2.0f, 0.0f, 1.4f), Vec3(0.0f, 0.0f, 4.0f)], [0u, 1u, 2u, 3u, 4u, 5u], [[2u,3u,4u], [4u,5u,0u], [4u,0u,1u], [1u,2u,4u]]),
        C("mode_strip", [Vec3(0.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 4.0f), Vec3(2.0f, 0.0f, 1.4f), Vec3(0.0f, 0.0f, 4.0f)], [0u, 1u, 2u, 3u, 4u, 5u], [[2u,3u,4u], [4u,5u,0u], [4u,0u,1u], [1u,2u,4u]]),
        C("oct_quality", [Vec3(3.0f, 0.0f, 0.0f), Vec3(2.12132f, 0.0f, 2.12132f), Vec3(0.0f, 0.0f, 3.0f), Vec3(-2.12132f, 0.0f, 2.12132f), Vec3(-3.0f, 0.0f, 0.0f), Vec3(-2.12132f, 0.0f, -2.12132f), Vec3(-0.0f, 0.0f, -3.0f), Vec3(2.12132f, 0.0f, -2.12132f)], [0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u], [[7u,0u,1u], [7u,1u,2u], [7u,2u,3u], [7u,3u,4u], [6u,7u,4u], [4u,5u,6u]], Mesh.TriangulateMode.EarClip),
        C("paths_dart", [Vec3(0.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 1.2f), Vec3(4.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 3.0f)], [0u, 1u, 2u, 3u], [[3u,0u,1u], [1u,2u,3u]]),
        C("paths_hex", [Vec3(0.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 4.0f), Vec3(2.0f, 0.0f, 1.4f), Vec3(0.0f, 0.0f, 4.0f)], [0u, 1u, 2u, 3u, 4u, 5u], [[2u,3u,4u], [4u,5u,0u], [4u,0u,1u], [1u,2u,4u]]),
        C("paths_horse", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u], [[2u,3u,4u], [5u,6u,7u], [1u,2u,4u], [0u,1u,4u], [5u,7u,0u], [0u,4u,5u]]),
        C("paths_pent", [Vec3(0.0f, 0.0f, 0.0f), Vec3(3.0f, 0.0f, 0.0f), Vec3(3.0f, 0.0f, 3.0f), Vec3(1.5f, 0.0f, 1.1f), Vec3(0.0f, 0.0f, 3.0f)], [0u, 1u, 2u, 3u, 4u], [[1u,2u,3u], [3u,4u,0u], [0u,1u,3u]]),
        C("rev_hex", [Vec3(0.0f, 0.0f, 0.0f), Vec3(2.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 0.0f), Vec3(4.0f, 0.0f, 4.0f), Vec3(2.0f, 0.0f, 1.4f), Vec3(0.0f, 0.0f, 4.0f)], [5u, 4u, 3u, 2u, 1u, 0u], [[0u,5u,4u], [4u,3u,2u], [4u,2u,1u], [4u,1u,0u]]),
        C("rev_horse", [Vec3(0.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 0.0f), Vec3(6.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 6.0f), Vec3(4.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 2.0f), Vec3(2.0f, 0.0f, 6.0f), Vec3(0.0f, 0.0f, 6.0f)], [7u, 6u, 5u, 4u, 3u, 2u, 1u, 0u], [[7u,6u,5u], [4u,3u,2u], [0u,7u,5u], [4u,2u,1u], [4u,1u,0u], [5u,4u,0u]]),
        C("rev_pent", [Vec3(0.0f, 0.0f, 0.0f), Vec3(3.0f, 0.0f, 0.0f), Vec3(3.0f, 0.0f, 3.0f), Vec3(1.5f, 0.0f, 1.1f), Vec3(0.0f, 0.0f, 3.0f)], [4u, 3u, 2u, 1u, 0u], [[0u,4u,3u], [3u,2u,1u], [3u,1u,0u]]),
    ];

    foreach (c; cells) {
        Mesh m;
        m.vertices = c.verts.dup;
        m.addFace(c.ring.dup);
        m.buildLoops();
        m.resetSelection();
        auto mask = new bool[](m.faces.length);
        mask[] = true;
        triangulateFacesByMask(m, mask, null, c.mode);

        assert(m.faces.length == c.want.length,
            c.name ~ ": expected " ~ c.want.length.to!string ~ " triangles, got "
            ~ m.faces.length.to!string);
        foreach (i; 0 .. c.want.length) {
            assert(m.faces[i].length == 3, c.name ~ ": face " ~ i.to!string ~ " is not a triangle");
            assert(m.faces[i][0] == c.want[i][0] && m.faces[i][1] == c.want[i][1]
                && m.faces[i][2] == c.want[i][2],
                c.name ~ ": triangle " ~ i.to!string ~ " is " ~ m.faces[i].to!string
                ~ ", the reference emitted " ~ c.want[i].to!string
                ~ " — this is the ported choice law, its emission ORDER and its "
                ~ "winding, all three at once");
        }
    }
}

unittest { // The convex octagon: BOTH of the reference's triangulators on one
           // ring, and the switch between them — tasks 1280 (the clip) and
           // 1320 (the strip, which is the default).
    //
    // This octagon is the only shape measured down both paths, and they
    // disagree outright on it. Task 1280 ported the clip alone and this cell
    // recorded the resulting gap; task 1320 ported the strip, so the gap is
    // closed and the cell now pins three things at once:
    //
    //   * a BARE call gives the strip's decomposition — that is what the
    //     reference's own default gives, so this is the parity assertion;
    //   * asking for the clip gives the clip's, unchanged from 1280 — so the
    //     older law is still pinned and did not quietly rot behind the new one;
    //   * the two are DIFFERENT, asserted rather than assumed. Without that
    //     third check a kernel that ignored the mode and ran one path for both
    //     would satisfy the first two only if they happened to agree, and on a
    //     QUAD they do agree as triangle sets — so a cell with eight corners,
    //     where the sets themselves diverge, is the one that can carry it.
    //
    // The earlier reading of this cell had a fourth gate declining the strip at
    // four corners. That was wrong, and the way it was wrong is worth keeping:
    // on a QUAD the two paths emit the same two triangles across the same
    // diagonal and differ only in tuple start, so a strip model whose walk was
    // pinned to ring index 0 — fitted to this very octagon, where all ears tie
    // and the chooser returns 0 — predicted the wrong tuples and looked like a
    // refusal. Both lists below are measured output, so neither is affected.
    import std.conv : to;
    Vec3[] verts = [Vec3(3.0f, 0.0f, 0.0f), Vec3(2.12132f, 0.0f, 2.12132f), Vec3(0.0f, 0.0f, 3.0f), Vec3(-2.12132f, 0.0f, 2.12132f), Vec3(-3.0f, 0.0f, 0.0f), Vec3(-2.12132f, 0.0f, -2.12132f), Vec3(-0.0f, 0.0f, -3.0f), Vec3(2.12132f, 0.0f, -2.12132f)];
    uint[]  ring = [0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u];
    uint[3][] stripWants = [[0u,1u,7u], [6u,7u,1u], [1u,2u,6u], [5u,6u,2u], [2u,3u,5u], [4u,5u,3u]];
    uint[3][] clipWants  = [[7u,0u,1u], [7u,1u,2u], [7u,2u,3u], [7u,3u,4u], [6u,7u,4u], [4u,5u,6u]];

    uint[3][] run(Mesh.TriangulateMode mode) {
        Mesh m;
        m.vertices = verts.dup;
        m.addFace(ring.dup);
        m.buildLoops();
        m.resetSelection();
        auto mask = new bool[](m.faces.length);
        mask[] = true;
        triangulateFacesByMask(m, mask, null, mode);
        uint[3][] got;
        foreach (f; m.faces) got ~= cast(uint[3])[f[0], f[1], f[2]];
        return got;
    }

    static void expect(string who, uint[3][] got, uint[3][] want, string what) {
        assert(got.length == want.length, who ~ ": expected "
            ~ want.length.to!string ~ " triangles, got " ~ got.length.to!string);
        foreach (i; 0 .. want.length)
            assert(got[i] == want[i], who ~ " triangle " ~ i.to!string ~ " is "
                ~ got[i].to!string ~ ", " ~ what ~ " emits " ~ want[i].to!string);
    }

    auto bare = run(Mesh.TriangulateMode.Strip);
    auto clip = run(Mesh.TriangulateMode.EarClip);
    expect("octagon, bare call", bare, stripWants, "the reference's default (the strip)");
    expect("octagon, clip asked for", clip, clipWants, "the ear clip");

    bool differ = false;
    foreach (i; 0 .. bare.length) if (bare[i] != clip[i]) { differ = true; break; }
    assert(differ,
        "the two triangulators gave the SAME answer on the convex octagon. They "
        ~ "are measured to disagree on it, so this means the mode argument is "
        ~ "being ignored and one path is answering for both — which every other "
        ~ "assertion here would still accept wherever the two happen to agree");
}

unittest { // tripleRingCorners: THE DEFAULT PATH — the zig-zag strip, its three
           // decline gates, and the fallback into the clip — task 1320.
    //
    // Twenty-eight rings, each with the reference's own output in EMISSION
    // ORDER and with the winding it stored, driven through the BARE call — the
    // mode our command uses and the reference's own default. Together with the
    // nineteen clip cells above this is the whole of what the strip was ported
    // from, so it is the whole of what a change to it has to keep.
    //
    // THE LAW, in one line each:
    //   walk    two cursors from the PICKED corner, `lo` up and `hi` down,
    //           alternating: [s,s+1,s-1] [s-2,s-1,s+1] … , n-2 triangles.
    //   G1      every corner's edge-pair cross dotted with the ring's cached
    //           CORNER normal >= 0 — zero passes, so a collinear corner is
    //           admitted and that is what makes G2 reachable at all.
    //   G2      every triangle of the walk from RING POSITION 0 has area
    //           >= 1e-10 — absolute, in double, on the true area.
    //   G3      every triangle of the walk from the PICKED corner scores
    //           >= 0.01 on 2*Area/(longest side)^2.
    //   any gate declines -> the clip below runs on the same ring.
    //
    // WHAT SEPARATES WHAT. Each mutation was applied to the kernel, built, and
    // run against all 62 measured cells; these are the cells that actually
    // reddened, not "something broke":
    //
    //   the degeneracy floor read as `area == 0` (the reading before it was
    //   bracketed at run time) ......... strip_scale18, strip_scale19,
    //                                    strip_fine0..strip_fine3   — 6 cells
    //   the floor moved to 1e-9 ........ strip_scale16, strip_scale17,
    //                                    strip_fine4..strip_fine7   — 6 cells
    //   the degeneracy walk started at
    //   the picked corner instead of 0 . strip_collinear5, strip_scale18,
    //                                    strip_fine1..strip_fine3   — 5 cells
    //   the walk always started at 0 ... strip_pole_quad3, strip_np_one,
    //                                    strip_np_twist, collinear5_off/_eps,
    //                                    strip_scale14/16/17, fine4..7 — 12
    //   the convexity gate deleted ..... every concave ring in the corpus — 16
    //   the quality floor at 0.001 ..... strip_sliver_quad             — 1 cell
    //
    // TWO THINGS THE CORPUS DOES NOT SEPARATE, said out loud so nobody reads
    // this as pinning them. Computing the gate's area as |cross|/2 instead of
    // from the Gram determinant, and deciding G1 against the ring's NEWELL
    // normal instead of its cached corner normal, each reproduce all 62 cells.
    // Both are implemented as READ rather than as fitted, and a future lane
    // that changes either will not be caught here.
    //
    // WHY THE SMALL CELLS EXIST, and why they cannot be moved to unit scale.
    // `strip_scale*` and `strip_fine*` are 1e-5-sized on purpose: at
    // coordinates of order 1 the float32 spacing is ~6e-8, so a triangle's area
    // is either exactly 0 or far above 1e-10 and the floor is indistinguishable
    // from an exact-zero test. Rescaling these rings to something readable
    // would make six of them vacuous. The scale IS the assertion.
    //
    // The multi-face cells (`strip_pole_quad3`, `strip_np_twist`) are listed in
    // OUR face order. Each block is verbatim measured output; only the order of
    // the BLOCKS is ours, because the reference emitted its faces in an order
    // that differs between its own two modes on the same cell and so is not a
    // property of either triangulator.
    import std.conv : to;
    static struct S { string name; Vec3[] verts; uint[][] rings; uint[3][] want; }
    auto cells = [
        // a plain square: the cell that showed the strip does NOT decline at four corners
        S("strip_reg4", [Vec3(3f, 0f, 0f), Vec3(0f, 0f, 3f), Vec3(-3f, 0f, 0f), Vec3(-0f, 0f, -3f)], [[0u, 1u, 2u, 3u]],
           [[0u,1u,3u], [2u,3u,1u]]),
        // regular pentagon — the tie band where float32 and double pick DIFFERENT corners
        S("strip_reg5", [Vec3(3f, 0f, 0f), Vec3(0.927051008f, 0f, 2.85316992f), Vec3(-2.42705107f, 0f, 1.76335597f), Vec3(-2.42705107f, 0f, -1.76335597f), Vec3(0.927051008f, 0f, -2.85316992f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,4u], [3u,4u,1u], [1u,2u,3u]]),
        S("strip_reg6", [Vec3(3f, 0f, 0f), Vec3(1.5f, 0f, 2.59807611f), Vec3(-1.5f, 0f, 2.59807611f), Vec3(-3f, 0f, 0f), Vec3(-1.5f, 0f, -2.59807611f), Vec3(1.5f, 0f, -2.59807611f)], [[0u, 1u, 2u, 3u, 4u, 5u]],
           [[0u,1u,5u], [4u,5u,1u], [1u,2u,4u], [3u,4u,2u]]),
        S("strip_reg7", [Vec3(3f, 0f, 0f), Vec3(1.87046897f, 0f, 2.34549403f), Vec3(-0.667563021f, 0f, 2.92478395f), Vec3(-2.70290709f, 0f, 1.301651f), Vec3(-2.70290709f, 0f, -1.301651f), Vec3(-0.667563021f, 0f, -2.92478395f), Vec3(1.87046897f, 0f, -2.34549403f)], [[0u, 1u, 2u, 3u, 4u, 5u, 6u]],
           [[0u,1u,6u], [5u,6u,1u], [1u,2u,5u], [4u,5u,2u], [2u,3u,4u]]),
        // from five corners up the two paths differ as triangle SETS, not just tuple starts
        S("strip_reg8", [Vec3(3f, 0f, 0f), Vec3(2.12132001f, 0f, 2.12132001f), Vec3(0f, 0f, 3f), Vec3(-2.12132001f, 0f, 2.12132001f), Vec3(-3f, 0f, 0f), Vec3(-2.12132001f, 0f, -2.12132001f), Vec3(-0f, 0f, -3f), Vec3(2.12132001f, 0f, -2.12132001f)], [[0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u]],
           [[0u,1u,7u], [6u,7u,1u], [1u,2u,6u], [5u,6u,2u], [2u,3u,5u], [4u,5u,3u]]),
        // the bare call on the convex octagon: the reference's own default
        S("oct_default", [Vec3(3f, 0f, 0f), Vec3(2.12132001f, 0f, 2.12132001f), Vec3(0f, 0f, 3f), Vec3(-2.12132001f, 0f, 2.12132001f), Vec3(-3f, 0f, 0f), Vec3(-2.12132001f, 0f, -2.12132001f), Vec3(-0f, 0f, -3f), Vec3(2.12132001f, 0f, -2.12132001f)], [[0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u]],
           [[0u,1u,7u], [6u,7u,1u], [1u,2u,6u], [5u,6u,2u], [2u,3u,5u], [4u,5u,3u]]),
        // three convex quads round a shared pole
        S("strip_pole_quad3", [Vec3(0f, 0f, 0f), Vec3(1f, 0f, 0f), Vec3(0.310000002f, 0f, 0.536935985f), Vec3(-0.5f, 0f, 0.866024971f), Vec3(-0.620000005f, 0f, 0f), Vec3(-0.5f, 0f, -0.866024971f), Vec3(0.310000002f, 0f, -0.536935985f)], [[0u, 1u, 2u, 3u], [0u, 3u, 4u, 5u], [0u, 5u, 6u, 1u]],
           [[1u,2u,0u], [3u,0u,2u], [3u,4u,0u], [5u,0u,4u], [5u,6u,0u], [1u,0u,6u]]),
        // a NON-PLANAR quad — where the cached corner normal could part company with Newell
        S("strip_np_one", [Vec3(0f, 0f, 0f), Vec3(1f, 0f, 0f), Vec3(1f, 0f, 1f), Vec3(0f, 0.100000001f, 1f)], [[0u, 1u, 2u, 3u]],
           [[3u,0u,2u], [1u,2u,0u]]),
        // four non-planar quads, increasingly twisted
        S("strip_np_twist", [Vec3(0f, 0f, 0f), Vec3(0f, 0f, 1f), Vec3(1f, -0.119999997f, 0f), Vec3(1f, 0.119999997f, 1f), Vec3(2f, -0.239999995f, 0f), Vec3(2f, 0.239999995f, 1f), Vec3(3f, -0.360000014f, 0f), Vec3(3f, 0.360000014f, 1f), Vec3(4f, -0.479999989f, 0f), Vec3(4f, 0.479999989f, 1f)], [[0u, 2u, 3u, 1u], [2u, 4u, 5u, 3u], [4u, 6u, 7u, 5u], [6u, 8u, 9u, 7u]],
           [[2u,3u,0u], [1u,0u,3u], [4u,5u,2u], [3u,2u,5u], [6u,7u,4u], [5u,4u,7u], [8u,9u,6u], [7u,6u,9u]]),
        // G1's isolating cell: fails convexity ALONE (quality min 0.14, no degeneracy)
        S("strip_hex_concave", [Vec3(0f, 0f, 0f), Vec3(2f, 0f, 0f), Vec3(4f, 0f, 0f), Vec3(4f, 0f, 4f), Vec3(2f, 0f, 1.39999998f), Vec3(0f, 0f, 4f)], [[0u, 1u, 2u, 3u, 4u, 5u]],
           [[2u,3u,4u], [4u,5u,0u], [4u,0u,1u], [1u,2u,4u]]),
        // G3's isolating cell: 10 x 0.02, convex and non-degenerate, quality 0.002
        S("strip_sliver_quad", [Vec3(0f, 0f, 0f), Vec3(10f, 0f, 0f), Vec3(10f, 0f, 0.0199999996f), Vec3(0f, 0f, 0.0199999996f)], [[0u, 1u, 2u, 3u]],
           [[3u,0u,1u], [1u,2u,3u]]),
        // G2's isolating cell: convex, clears quality by 40x, one EXACTLY zero-area triangle that only the walk-from-0 sees
        S("strip_collinear5", [Vec3(2f, 0f, 3.5f), Vec3(0f, 0f, 0f), Vec3(4f, 0f, 0f), Vec3(8f, 0f, 0f), Vec3(5f, 0f, 6f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        // G2's DISCRIMINATOR: the same five points, ring rotated by one — same corner count, same convexity, same collinear corner, same three quality scores. Only which triangles the degeneracy walk sees changes, and it PASSES
        S("strip_collinear5_rot", [Vec3(2f, 0f, 3.5f), Vec3(0f, 0f, 0f), Vec3(4f, 0f, 0f), Vec3(8f, 0f, 0f), Vec3(5f, 0f, 6f)], [[1u, 2u, 3u, 4u, 0u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        // corner 2 pushed off the line by 1.0
        S("strip_collinear5_off", [Vec3(2f, 0f, 3.5f), Vec3(0f, 0f, 0f), Vec3(4f, 0f, -1f), Vec3(8f, 0f, 0f), Vec3(5f, 0f, 6f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        // pushed by 1/32 — the shape barely moves and it still passes
        S("strip_collinear5_eps", [Vec3(2f, 0f, 3.5f), Vec3(0f, 0f, 0f), Vec3(4f, 0f, -0.03125f), Vec3(8f, 0f, 0f), Vec3(5f, 0f, 6f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        // powers-of-two ladder: mantissas bit-identical, only the exponent moves, so ONLY the absolute area changes
        S("strip_scale14", [Vec3(0.000122070312f, 0f, 0.000213623047f), Vec3(0f, 0f, 0f), Vec3(0.000244140625f, 0f, -6.10351562e-05f), Vec3(0.00048828125f, 0f, 0f), Vec3(0.000305175781f, 0f, 0.000366210938f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        S("strip_scale16", [Vec3(3.05175781e-05f, 0f, 5.34057617e-05f), Vec3(0f, 0f, 0f), Vec3(6.10351562e-05f, 0f, -1.52587891e-05f), Vec3(0.000122070312f, 0f, 0f), Vec3(7.62939453e-05f, 0f, 9.15527344e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        S("strip_scale17", [Vec3(1.52587891e-05f, 0f, 2.67028809e-05f), Vec3(0f, 0f, 0f), Vec3(3.05175781e-05f, 0f, -7.62939453e-06f), Vec3(6.10351562e-05f, 0f, 0f), Vec3(3.81469727e-05f, 0f, 4.57763672e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        // first rung under the floor
        S("strip_scale18", [Vec3(7.62939453e-06f, 0f, 1.33514404e-05f), Vec3(0f, 0f, 0f), Vec3(1.52587891e-05f, 0f, -3.81469727e-06f), Vec3(3.05175781e-05f, 0f, 0f), Vec3(1.90734863e-05f, 0f, 2.28881836e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        S("strip_scale19", [Vec3(3.81469727e-06f, 0f, 6.67572021e-06f), Vec3(0f, 0f, 0f), Vec3(7.62939453e-06f, 0f, -1.90734863e-06f), Vec3(1.52587891e-05f, 0f, 0f), Vec3(9.53674316e-06f, 0f, 1.14440918e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        // the 1% ladder: 3.0e-11, under
        S("strip_fine0", [Vec3(6.6057828e-06f, 0f, 1.15601197e-05f), Vec3(0f, 0f, 0f), Vec3(1.32115656e-05f, 0f, -3.3028914e-06f), Vec3(2.64231312e-05f, 0f, 0f), Vec3(1.65144556e-05f, 0f, 1.98173475e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        S("strip_fine1", [Vec3(9.34198761e-06f, 0f, 1.63484783e-05f), Vec3(0f, 0f, 0f), Vec3(1.86839752e-05f, 0f, -4.6709938e-06f), Vec3(3.73679504e-05f, 0f, 0f), Vec3(2.3354969e-05f, 0f, 2.80259628e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        S("strip_fine2", [Vec3(1.14415507e-05f, 0f, 2.0022715e-05f), Vec3(0f, 0f, 0f), Vec3(2.28831013e-05f, 0f, -5.72077533e-06f), Vec3(4.57662027e-05f, 0f, 0f), Vec3(2.86038776e-05f, 0f, 3.43246538e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        // 9.9e-11, the last rung under the floor
        S("strip_fine3", [Vec3(1.20000004e-05f, 0f, 2.09999998e-05f), Vec3(0f, 0f, 0f), Vec3(2.40000008e-05f, 0f, -6.00000021e-06f), Vec3(4.80000017e-05f, 0f, 0f), Vec3(2.99999992e-05f, 0f, 3.60000013e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[0u,1u,2u], [2u,3u,4u], [0u,2u,4u]]),
        // 1.01e-10, the first rung over it
        S("strip_fine4", [Vec3(1.21206058e-05f, 0f, 2.12110608e-05f), Vec3(0f, 0f, 0f), Vec3(2.42412116e-05f, 0f, -6.06030289e-06f), Vec3(4.84824232e-05f, 0f, 0f), Vec3(3.03015149e-05f, 0f, 3.63618165e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        S("strip_fine5", [Vec3(1.26491104e-05f, 0f, 2.21359442e-05f), Vec3(0f, 0f, 0f), Vec3(2.52982209e-05f, 0f, -6.32455522e-06f), Vec3(5.05964417e-05f, 0f, 0f), Vec3(3.16227779e-05f, 0f, 3.79473313e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        S("strip_fine6", [Vec3(1.4270121e-05f, 0f, 2.49727127e-05f), Vec3(0f, 0f, 0f), Vec3(2.85402421e-05f, 0f, -7.13506051e-06f), Vec3(5.70804841e-05f, 0f, 0f), Vec3(3.56753044e-05f, 0f, 4.28103631e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
        // 2.0e-10, comfortably over
        S("strip_fine7", [Vec3(1.70560579e-05f, 0f, 2.98481009e-05f), Vec3(0f, 0f, 0f), Vec3(3.41121158e-05f, 0f, -8.52802896e-06f), Vec3(6.82242317e-05f, 0f, 0f), Vec3(4.26401421e-05f, 0f, 5.11681719e-05f)], [[0u, 1u, 2u, 3u, 4u]],
           [[1u,2u,0u], [4u,0u,2u], [2u,3u,4u]]),
    ];

    foreach (c; cells) {
        Mesh m;
        m.vertices = c.verts.dup;
        foreach (r; c.rings) m.addFace(r.dup);
        m.buildLoops();
        m.resetSelection();
        auto mask = new bool[](m.faces.length);
        mask[] = true;
        // No mode argument: this is the BARE call, which is the point.
        triangulateFacesByMask(m, mask);

        assert(m.faces.length == c.want.length,
            c.name ~ ": expected " ~ c.want.length.to!string ~ " triangles, got "
            ~ m.faces.length.to!string);
        foreach (i; 0 .. c.want.length) {
            assert(m.faces[i].length == 3,
                c.name ~ ": face " ~ i.to!string ~ " is not a triangle");
            assert(m.faces[i][0] == c.want[i][0] && m.faces[i][1] == c.want[i][1]
                && m.faces[i][2] == c.want[i][2],
                c.name ~ ": triangle " ~ i.to!string ~ " is " ~ m.faces[i].to!string
                ~ ", the reference emitted " ~ c.want[i].to!string
                ~ " — this is the ported default path, its emission ORDER and its"
                ~ " winding, all three at once");
        }
    }
}

unittest { // earClipRingCorners: a ring on which the quality EARLY-OUT actually
           // fires, so `kTripleQualityEarlyOut` is pinned in both directions —
           // task 1280.
    //
    // WHY THIS RING HAD TO BE CONSTRUCTED. The early-out was read under a
    // debugger, but it fires on none of the reference's measured cells: their
    // highest ear quality is exactly 0.5 and the comparison is strict. So the
    // capture bounds the constant from BELOW only — at 0.4698 or under, three
    // measured cells break — and says nothing above it. Without a ring where it
    // fires, raising 0.5 to 0.9, or deleting the early-out outright, would be
    // invisible to every test we have.
    //
    // WHAT THIS RING IS AND IS NOT. It is a hexagon whose first ear over 0.5
    // (q = 0.798851, at ring index 3) is NOT its best (q = 0.843750, at index
    // 4), so scanning in ring order and stopping early lands somewhere the
    // maximum does not. It was found by search over rings on a 0.1 grid, and it
    // has never been through the reference — this is NOT a parity assertion. It
    // pins our own constant against drift: the answer below is what the ported
    // law gives for any threshold in (0.16, 0.79], and it changes outside that
    // band. Together with the measured cells' lower bound the constant is
    // bracketed to (0.4698, 0.79], and 0.5 sits inside.
    import std.conv : to;
    Vec3[] verts = [Vec3(1.4f, 0, -1.5f), Vec3(1.0f, 0, 1.2f), Vec3(0.3f, 0, 1.1f),
                    Vec3(-1.0f, 0, -0.5f), Vec3(1.2f, 0, -1.0f), Vec3(0.6f, 0, 1.1f)];
    uint[3][] want = [[2u,3u,4u], [5u,0u,1u], [2u,4u,5u], [1u,2u,5u]];

    Mesh m;
    m.vertices = verts.dup;
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();
    m.resetSelection();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    triangulateFacesByMask(m, mask);

    assert(m.faces.length == want.length,
        "early-out ring: expected " ~ want.length.to!string ~ " triangles, got "
        ~ m.faces.length.to!string);
    foreach (i; 0 .. want.length)
        assert(m.faces[i][0] == want[i][0] && m.faces[i][1] == want[i][1]
            && m.faces[i][2] == want[i][2],
            "early-out ring: triangle " ~ i.to!string ~ " is " ~ m.faces[i].to!string
            ~ ", expected " ~ want[i].to!string
            ~ " — the corner chooser stopped at the first ear over "
            ~ "kTripleQualityEarlyOut. A run that answers "
            ~ "[[3,4,5],[5,0,1],[2,3,5],[1,2,5]] instead has the threshold at 0.8 "
            ~ "or higher, or no early-out at all; one that answers "
            ~ "[[0,2,1],[5,2,0],[2,4,3],[2,5,4]] has it at 0.16 or below");
}

unittest // triangulateFacesByMask (site 6): each triangle split off a masked
         // quad must inherit the SOURCE face's plane values via `faceOrigin`
         // (already newToOld, fed straight into `mesh_planes.rewriteFaces`).
         // `./run_test.d test_fixture_triangulate_convex_strip` stayed PASS
         // under the drop — it asserts triangle SHAPE/winding, never a plane
         // value.
{
    Mesh m = makeTaggedGrid();
    m.buildLoops();
    m.syncSelection();

    // Face 1: material=1, part=2 (both non-zero — see the removeEdgesByMask
    // drill above for why that matters). Not hidden/selected/subpatch-only
    // in a way that would interfere: face 1 IS marked Subpatch by the
    // fixture, which triangulateFacesByMask does not gate on.
    assert(m.faceMaterial[1] == 1 && m.facePart[1] == 2,
        "fixture: face 1 must carry a non-zero material/part for this drill "
      ~ "to discriminate a drop from the T.init default");

    bool[] mask = new bool[](m.faces.length);
    mask[1] = true;
    const changed = triangulateFacesByMask(m, mask);
    assert(changed == 1, "exactly one quad triangulated");
    assert(m.faces.length == 10,
        format("one quad -> two triangles: 9 -> 10 faces (got %d)", m.faces.length));

    // Faces pass through in original order; the masked quad at old index 1
    // is replaced IN PLACE by its two triangles, landing at new indices 1
    // and 2 (face 0 stays at 0; faces 3.. shift by +1 for the extra split).
    foreach (fi; [1, 2]) {
        assert(m.faces[fi].length == 3,
            format("split triangle at new index %d should have 3 corners, got %d",
                   fi, m.faces[fi].length));
        assert(m.faceMaterial[fi] == 1,
            format("triangulateFacesByMask: triangle at new index %d must keep "
                 ~ "source face 1's material via faceOrigin (got %d)",
                   fi, m.faceMaterial[fi]));
        assert(m.facePart[fi] == 2,
            format("triangulateFacesByMask: triangle at new index %d must keep "
                 ~ "source face 1's part via faceOrigin (got %d)",
                   fi, m.facePart[fi]));
    }
}

