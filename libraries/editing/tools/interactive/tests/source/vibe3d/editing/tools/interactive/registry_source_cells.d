module vibe3d.editing.tools.interactive.registry_source_cells;

import vibe3d.mesh.core.mesh;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.viewport.gpu.shader;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.commands.runtime.command_registry : CommandFactory;
import vibe3d.editing.commands.runtime.command_registry : CommandRegistry;
import vibe3d.editing.commands.runtime.command_executor : CommandExecutor;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.runtime.command_invocation : CommandInvocationService, RefireDispatch, UiInvocation,
    InteractiveConfiguration, RefusalNotice;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.editing.tools.interactive.registry;

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
