// Module unittests for `argstring`, moved verbatim out of source/argstring.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.argstring_test;

import std.json    : JSONValue, JSONType, parseJSON;
import std.ascii   : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv    : to, ConvException;
import std.string  : strip;
import std.format  : format;
import std.array   : join;
import params      : Param, IntEnumEntry, isUserSet, fmtFloatWire;
import math : Vec3;
import std.math : fabs;
import params : fmtFloatWire, stringifyParam;
import std.exception : assertThrown;
import argstring;


unittest { // a number with an exponent is one float token (task 9492: `1e30` read as 1)
    auto pos = parseArgstring("tool.attr prim.cube radius 5e2").params[kPositionalKey].array;
    assert(pos.length == 3 && pos[2].type == JSONType.float_ && pos[2].floating == 500,
           "5e2 -> " ~ pos.to!string);
    auto big = parseArgstring("a 1e30 -2.5E-3 7e+1 x:3e2").params;
    assert(big[kPositionalKey].array[0].floating == 1e30
        && big[kPositionalKey].array[1].floating == -2.5e-3
        && big[kPositionalKey].array[2].floating == 70
        && big["x"].floating == 300, "exponent forms -> " ~ big.toString);
}
