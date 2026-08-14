// Module unittests for `ui.availability`, moved verbatim out of source/ui/availability.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.availability_test;

import buttonset : Action, ActionKind;
import registry  : Registry;
import ui.availability;

unittest {
    // The script-line id is the leading token, with no parse and no
    // allocation-visible difference from what the dispatcher resolves.
    assert(scriptLineCommandId("prim.cube cenX:0 sizeX:1") == "prim.cube");
    assert(scriptLineCommandId("   prim.sphere method:globe") == "prim.sphere");
    assert(scriptLineCommandId("select.typeFrom vertex") == "select.typeFrom");
    assert(scriptLineCommandId("history.undo") == "history.undo");
    assert(scriptLineCommandId("") == "");
    assert(scriptLineCommandId("   ") == "");
}
