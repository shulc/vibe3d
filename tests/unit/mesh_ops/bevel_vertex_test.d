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
// unlike extrude's sites — it is NOT independently observable here: this
// kernel's own tail unconditionally re-selects the WHOLE `capStart ..
// faces.length` range via `selectFace` immediately afterward, which
// overwrites `faceSelectionOrder` regardless of what the override left
// behind (`selectFace` assigns `++faceSelectionOrderCounter` whenever the
// Select bit was not already set — true here either way). Same class as
// loop_slice's Stage C gap: the override closes the LAW structurally, not
// visibly, from outside this function.
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

    // The cap (position 9) inherits its ONE donor's material/part (one of
    // the 4 faces incident to vertex 5).
    immutable uint capMat = m.faceMaterial[9];
    assert(capMat == 1000 || capMat == 1001 || capMat == 1003 || capMat == 1004,
        "grid vertex-bevel: cap must inherit material from one of its 4 "
        ~ "incident donor faces (got " ~ capMat.to!string ~ ")");
    assert(m.facePart[9] == capMat - 1000 + 2000,
        "grid vertex-bevel: cap part must come from the SAME donor face as its material");
}
