// Module unittests for `toolpipe.stage`, moved verbatim out of packages/common/source/toolpipe/stage.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.stage_test;

import vibe3d.editing.params.params : Param, ParamProvider, parseInto, stringifyParam;
import std.algorithm : canFind;
import vibe3d.editing.pipeline.runtime.toolpipe.stage;

