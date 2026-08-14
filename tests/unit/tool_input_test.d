// Module unittests for `tool_input`, moved verbatim out of source/tool_input.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tool_input_test;

import bindbc.sdl : SDL_Keymod, KMOD_SHIFT, KMOD_CTRL, KMOD_ALT,
                     SDL_BUTTON_LEFT, SDL_BUTTON_MIDDLE, SDL_BUTTON_RIGHT;
import tool_input;

// Empty table: everything is PassThrough — this is the default every
// unmigrated Tool subclass gets from the base's `bindings()` override.
unittest {
    const(InputBinding)[] empty;
    assert(resolveToolAction(empty, InputButton.Left, InputMod.None) == PassThrough);
    assert(resolveToolAction(empty, InputButton.Middle, InputMod.Shift) == PassThrough);
    assert(resolveToolAction(empty, InputButton.Right, InputMod.Alt) == PassThrough);
}
