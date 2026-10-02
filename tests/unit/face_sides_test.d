// `faceSidesFor` (S1d, model M6): the GL sides a face pass submits, over every
// (cullBack, bySurface, anyTwoSided) combination. The pixels and the
// two-submission count are pinned by tests/test_backface_cull.d (cells "lit",
// "count"); this pins the table the pixels cannot enumerate.
module tests.unit.face_sides_test;

import std.format : format;

import mesh_gpu : FacePass, FaceSide, FaceSides, faceSidesFor;

unittest {
    size_t rows;
    foreach (cullBack; [false, true])
    foreach (bySurface; [false, true])
    foreach (anyDouble; [false, true]) {
        FacePass p;
        p.cullBack  = cullBack;
        p.bySurface = bySurface;
        immutable FaceSides s = faceSidesFor(p, anyDouble);
        FaceSide[] want;
        if (cullBack || (bySurface && !anyDouble)) want = [FaceSide.Front];
        else if (bySurface)                        want = [FaceSide.Front, FaceSide.BackOfTwoSided];
        else                                       want = [FaceSide.All];
        assert(s.count >= 1, format("cull %s bySurface %s anyDouble %s: no side submitted",
                                    cullBack, bySurface, anyDouble));
        assert(s.side[0 .. s.count] == want,
            format("cull %s bySurface %s anyDouble %s: sides %s, expected %s",
                   cullBack, bySurface, anyDouble, s.side[0 .. s.count], want));
        ++rows;
    }
    assert(rows == 8, format("faceSidesFor table: %d rows, expected 8", rows));
}

unittest { // the other members do not choose the sides
    FacePass p;
    p.bySurface    = true;
    p.mirrored     = true;
    p.reverseOrder = true;
    p.alpha        = 0.5f;
    immutable FaceSides s = faceSidesFor(p, true);
    assert(s.count == 2 && s.side[0] == FaceSide.Front && s.side[1] == FaceSide.BackOfTwoSided,
        format("mirror / order / alpha moved the sides: %s", s.side[0 .. s.count]));
}
