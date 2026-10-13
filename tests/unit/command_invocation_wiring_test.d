module tests.unit.command_invocation_wiring_test;

import tests.unit.census_symbols : readText = wave15ReadText;
import std.path : dirName, buildPath;
import std.string : count;

private string repoFile(string path) {
    return readText(buildPath(dirName(dirName(dirName(__FILE_FULL_PATH__))), path));
}
private size_t occurrences(string text, string needle) { return text.count(needle); }

unittest { // Production seams, with scanner-blanked comments and literals.
    import tests.unit.census_symbols : blankNonCode;
    auto binding = blankNonCode(repoFile("source/application_command_binding.d"));
    auto owner = blankNonCode(repoFile("source/registry.d"));
    auto invocation = blankNonCode(repoFile("packages/command-runtime/source/command_invocation.d"));
    auto meshFamily = blankNonCode(repoFile("source/mesh_command_registration.d"));
    auto historyFamily = blankNonCode(repoFile("source/history_macro_registration.d"));
    auto pilot = blankNonCode(repoFile("packages/application-core/source/pilot_command_registration.d"));
    assert(occurrences(binding, "registry.createCommandInvocationService(executor, history,") == 1
        && occurrences(binding, "new CommandInvocationService(") == 0
        && occurrences(owner, "new CommandInvocationService(commandRegistry_, executor, history,") == 1
        && occurrences(binding, "return invocation.invokeLine(id, paramsJson, context);") == 1
        && occurrences(binding, "bindArgs(") == 0
        && occurrences(binding, "applyOrRefire(") == 0,
        "1D production binding must use the one lower invocation service");
    assert(occurrences(invocation, "private:\n    CommandRegistry* registry;") == 1
        && occurrences(invocation, "this(ref CommandRegistry registry,") == 1
        && occurrences(invocation, "this.registry = &registry;") == 1
        && occurrences(invocation, "ref CommandRegistry") == 1
        && occurrences(invocation, "CommandRegistry*") == 1
        && occurrences(invocation, "return registry;") == 0,
        "1D lower service must privately borrow one owner without exposing it");
    assert(occurrences(invocation,
        "executor.applyOrRefire(command, RecordMode.Coalescing, null)") == 1,
        "1D production script dispatch must retain null throw message");
    assert(occurrences(meshFamily, "registerTripleCommand(reg, pilot)") == 1
        && occurrences(meshFamily, "registerMeshSelectionCommand(reg, pilot)") == 1
        && occurrences(historyFamily, "registerHistoryNavigationCommands(reg,") == 1,
        "1D production families must consume common pilot registrar");
    foreach (type; ["MeshTriple", "MeshSelect", "HistoryUndo", "HistoryRedo"]) {
        assert(occurrences(meshFamily ~ historyFamily, "new " ~ type ~ "(") == 0,
            "1D desktop retained a second pilot factory: " ~ type);
        assert(occurrences(pilot, "new " ~ type ~ "(") == 1,
            "1D common registrar must own exactly one factory: " ~ type);
    }
    assert(occurrences(binding, "attr.setInteractive(interactive)") == 1
        && occurrences(binding, "session.tryRefireDispatch(command, id)") == 1,
        "1D desktop capabilities lost interactive or live session policy");
}
