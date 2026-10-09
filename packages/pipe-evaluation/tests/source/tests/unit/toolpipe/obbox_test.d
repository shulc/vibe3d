// Module unittests for `toolpipe.obbox`, moved verbatim out of source/toolpipe/obbox.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.obbox_test;

import std.math : abs, sqrt;
import math : Vec3, cross, dot, normalize;
import std.format : format;
import std.math   : fabs;
import toolpipe.obbox;

unittest { // the tie order — a property of this routine, not a port behaviour
    // Two candidate sorts agree on every distinct spectrum and disagree on
    // exactly this one: eigenvalues (c, 0, c) with the two c's BIT-IDENTICAL,
    // which is what a square face produces. A stable descending sort leaves
    // column 0 first; the sort published alongside the Jacobi routine compares
    // with `>=` so the LAST maximum wins and column 2 goes first.
    //
    // READ THE HEADER BEFORE ACTING ON A FAILURE HERE. This is the only place
    // the choice is observable at all — `obbFromPoints` discards it, because
    // the same bit-equality that lets the tie fire also trips the degeneracy
    // test that overwrites the permuted rows. Nothing we have measured picks
    // between the two, so a failure here means the ROUTINE drifted from the
    // published shape; it does not mean a box changed.
    double[3] d = [0.25, 0.0, 0.25];
    double[3][3] v = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
    sortEigenpairsDescending(d, v);
    assert(v[0][0] == 0 && v[1][0] == 0 && v[2][0] == 1,
           format("column 0 must be the ORIGINAL column 2 = (0,0,1); got "
                  ~ "(%g,%g,%g). (1,0,0) is what a STABLE descending sort "
                  ~ "answers — and it would publish the SAME box, since the "
                  ~ "degenerate-subspace fill overwrites both of these rows. "
                  ~ "This assert guards the routine's shape, not the port's "
                  ~ "output.",
                  v[0][0], v[1][0], v[2][0]));
    assert(v[0][1] == 1 && v[1][1] == 0 && v[2][1] == 0,
           "column 1 must be the original column 0 = (1,0,0)");
    assert(v[0][2] == 0 && v[1][2] == 1 && v[2][2] == 0,
           "column 2 must be the original column 1 = (0,1,0)");
    assert(d[0] == 0.25 && d[1] == 0.25 && d[2] == 0.0,
           "and the eigenvalues follow their columns, descending");
}
