// Module unittests for `symmetry`, moved verbatim out of source/symmetry.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.symmetry_test;

import std.algorithm : sort, max;
import std.math      : abs;
import math : Vec3, dot;
import mesh : Mesh;
import toolpipe.packets : SymmetryPacket;
import std.conv : to;
import symmetry;

