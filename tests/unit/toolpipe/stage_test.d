// Module unittests for `toolpipe.stage`, moved verbatim out of source/toolpipe/stage.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stage_test;

import params : Param, ParamProvider, parseInto, stringifyParam;
import std.algorithm : canFind;
import toolpipe.stage;

