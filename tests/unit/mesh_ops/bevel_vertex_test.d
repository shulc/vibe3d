module tests.unit.mesh_ops.bevel_vertex_test;

import mesh;
import math;
import mesh_ops.bevel_vertex;

// Site 10 (task 1902 Stage E) — bevelVerticesByMask's single rebuild pass:
// identity range (every survived/substituted face keeps its OWN old index,
// so its own material/part/setmask/order/marks ride through unchanged) +
// capSrc-sourced cap range (the cap N-gon inherits material/part/setmask/
// marks from its ONE donor face, task 1240's `capSrc`, not the chamfer 0u
// literal). No existing test (`tests/test_vertex_bevel.d`'s Subpatch-carry
// HTTP check is the closest) asserts material/part by value.
//
// faceSelectionOrder gets a post-`rewriteFaces` override too (plan §2.7a:
// a cap face must start at rank 0, not inherit its donor's stamp), but —
// unlike extrude's sites — it is USUALLY not independently observable here
// (task 1902 Step 0 review correction: the claim below used to say the tail
// "unconditionally" re-selects the WHOLE `capStart .. faces.length` range
// "regardless" of the override — that overstates it). The kernel's own tail
// (`faceSelectionOrderCounter = 0; foreach (fi; capStart .. faces.length)
// selectFace(cast(int)fi);`) re-selects every CREATED face that is NOT
// hidden — `selectFace` early-returns on `Marks.Hide` — which overwrites
// `faceSelectionOrder` for each one it touches regardless of what the
// override left behind. So the override is invisible from outside this
// function ONLY when the cap's donor is not hidden; when it is, the whole
// `faceMarks` word — Hide included — rides onto the cap through the same
// `oldOfNew` carry that would otherwise let the cap inherit the donor's
// order too, and the tail reselect then skips it, leaving this override as
// the sole writer of the cap's order. See
// `tests/unit/mesh_ops/edge_bevel_test.d`'s hub-cap witness (task 1902 Step
// 0) for a driven mutation exercising exactly this at a sibling kernel; the
// same mechanism applies here but is not separately witnessed in this file.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);   // 3x3 grid, 9 quads; vertex 5 is interior (valence 4)
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }

    bool[] mask = new bool[](m.vertices.length);
    mask[5] = true;   // interior vertex shared by faces 0, 1, 3, 4

    size_t n = m.bevelVerticesByMask(mask, 0.1f);
    assert(n == 1, "grid vertex-bevel: expected 1 accepted vertex, got " ~ n.to!string);
    // 9 survived/substituted originals + 1 cap N-gon (valence 4 -> quad cap).
    assert(m.faces.length == 9 + 1,
        "grid vertex-bevel: expected 9 substituted + 1 cap, got "
        ~ m.faces.length.to!string);

    // Survived/substituted range keeps its OWN material/part at its OWN old
    // index (the primitive's identity oldOfNew for this range).
    foreach (fi; 0 .. 9) {
        assert(m.faceMaterial[fi] == 1000 + fi,
            "grid vertex-bevel: original face " ~ fi.to!string ~ " lost its material");
        assert(m.facePart[fi] == 2000 + fi,
            "grid vertex-bevel: original face " ~ fi.to!string ~ " lost its part");
    }

    // The cap (position 9) inherits its ONE donor's material/part — the
    // kernel's own comment says the donor is "the first face of `vi`'s fan
    // walk" (`facesAroundVertex(vi)`, not the lowest-index incident face).
    // Measured directly (task 1902 Step 0), not guessed: a standalone probe
    // over this exact fixture prints `facesAroundVertex(5) == [3, 0, 1, 4]`,
    // so the donor is face 3 — deterministically, not "one of the 4".
    assert(m.faceMaterial[9] == 1003,
        "grid vertex-bevel: cap must inherit material from its ONE donor, "
        ~ "facesAroundVertex(5)'s first hit (face 3), got "
        ~ m.faceMaterial[9].to!string);
    assert(m.facePart[9] == 2003,
        "grid vertex-bevel: cap must inherit part from the SAME donor face "
        ~ "(face 3) as its material, got " ~ m.facePart[9].to!string);
}
