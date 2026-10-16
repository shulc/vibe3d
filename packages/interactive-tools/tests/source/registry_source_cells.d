module registry_source_cells;

import mesh;
import mesh_gpu : GpuMesh;
import view;
import vibe3d.editing.contracts.editmode;
import shader;
import tool;
import command;
import command_registry : CommandFactory;
import command_registry : CommandRegistry;
import command_executor : CommandExecutor;
import command_history : CommandHistory;
import command_invocation : CommandInvocationService, RefireDispatch, UiInvocation,
    InteractiveConfiguration, RefusalNotice;
import live_registration_roles : LiveSessionRole;
import vibe3d.editing.contracts.seltype : SelType;
import registry;

unittest {
    // The prepared descriptor owns every variable buffer.  A shallow AA dup
    // passes value-only tests, so mutate all three producer buffers after the
    // copy; this is the discriminating lifetime cell for stage/key/value.
    char[] stage = "falloff".dup;
    char[] name = "type".dup;
    char[] value = "radial".dup;
    PreparedPipeAttrs borrowed;
    borrowed[cast(string)stage][cast(string)name] = cast(string)value;
    auto owned = ownPreparedPipeAttrs(borrowed);
    stage[] = 'x';
    name[] = 'y';
    value[] = 'z';
    assert(owned["falloff"]["type"] == "radial",
           "prepared pipe descriptor borrowed producer storage");
}
