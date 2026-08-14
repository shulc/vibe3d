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

