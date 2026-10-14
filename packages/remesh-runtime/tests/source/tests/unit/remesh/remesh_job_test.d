// Module unittests for `remesh.remesh_job`, moved verbatim out of source/remesh/remesh_job.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.remesh.remesh_job_test;

import std.algorithm.iteration : map;
import std.algorithm.sorting   : sort;
import std.array   : array, split;
import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse, readText, thisExePath;
import std.path    : buildPath, expandTilde, dirName;
import std.process : Pid, spawnProcess, tryWait, kill, wait, environment, thisProcessID;
import std.stdio   : File, stdin;
import std.string  : strip;
import core.time   : MonoTime, Duration;
import mesh : Mesh;
import math : Vec3;
import remesh.region_stitch : stitchRegion, StitchResult;
import std.file : remove;
import std.algorithm.iteration : splitter;
import std.array : appender;
import core.thread : Thread;
import core.time   : msecs;
import std.file : write, setAttributes;
import std.conv : octal;
import remesh.remesh_job;

