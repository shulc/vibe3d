// Transform history ownership witness (task 1905).
//
// This is deliberately a runtime state census. The bank population is derived
// from the live XfrmTransformTool object's TransformTool-typed fields, then
// every bank is asked whether history/factory capability reached it. Receiver
// spelling, loops, helpers, and neighboring mixins are therefore all observed
// through the state they produce instead of guessed from source text.
module tests.unit.transform_history_ownership_census_test;

import command_history : CommandHistory;
import editmode : EditMode;
import mesh : Mesh;
import std.conv : to;
import tools.transform.xfrm_transform : XfrmTransformTool;

unittest // executes in the module-unittest gate, before any HTTP driver starts
{
    Mesh mesh;
    EditMode mode = EditMode.Vertices;
    auto history = new CommandHistory();
    auto tool = new XfrmTransformTool(() => &mesh, null, &mode);

    tool.flagT = tool.flagR = tool.flagS = true;
    tool.setUndoBindings(history, null);
    assert(tool.hasUndoBindings(),
        "transform history ownership census: wrapper binding did not install");
    auto state = tool.embeddedHistoryBindingState();

    // NON-DEGENERACY FIRST: absence below is evidence only after the derived
    // live population proves that all three embedded banks were inspected.
    assert(state[0] == 3,
        "transform history ownership census: expected three live embedded "
        ~ "banks, found " ~ state[0].to!string);
    assert(state[1] == 0,
        "transform history ownership census: embedded banks with history/undo "
        ~ "capability=" ~ state[1].to!string);

    // Activation is the other natural wiring boundary. Re-querying afterward
    // catches deferred or mixin-hosted propagation as well as direct binding.
    tool.activate();
    state = tool.embeddedHistoryBindingState();
    assert(state[0] == 3,
        "transform history ownership census: activation changed live bank "
        ~ "population to " ~ state[0].to!string);
    assert(state[1] == 0,
        "transform history ownership census: activation propagated history "
        ~ "into " ~ state[1].to!string ~ " banks");
}
