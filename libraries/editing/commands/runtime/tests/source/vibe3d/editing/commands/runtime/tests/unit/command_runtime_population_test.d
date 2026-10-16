module vibe3d.editing.commands.runtime.tests.unit.command_runtime_population_test;
import std.algorithm : canFind, sort;
import std.stdio : writeln;

// Wave13: owned enabled identities; lower-owner cells have separate rosters.
unittest {
    immutable string[] expected = ["vibe3d.editing.commands.runtime.command_history", "vibe3d.editing.commands.runtime.command_registry", "vibe3d.editing.commands.runtime.tests.unit.base_revert_flag_test", "vibe3d.editing.commands.runtime.tests.unit.command_apply_anchor_test", "vibe3d.editing.commands.runtime.tests.unit.command_bindargs_test", "vibe3d.editing.commands.runtime.tests.unit.command_history_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.command_registry_test", "vibe3d.editing.commands.runtime.tests.unit.command_runtime_population_test", "vibe3d.editing.commands.runtime.tests.unit.command_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.mesh.session_edit_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.commands.select.element_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.record_observer_hub_source_public_test", "vibe3d.editing.commands.runtime.tests.unit.session_edit_payload_test"];
    string[] actual;
    foreach (info; ModuleInfo)
        if (info.unitTest && expected.canFind(info.name)) actual ~= info.name;
    actual.sort;
    assert(actual == expected, "command-runtime owned execution population 13 changed");
    foreach (name; actual) writeln("COMMAND_RUNTIME-EXECUTION-MODULE ", name);
    writeln("COMMAND_RUNTIME-EXECUTION-ROSTER owned-modules=13");
}
