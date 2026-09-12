module application_command_binding_ownership_test;

import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.algorithm.searching : canFind;
import std.string : indexOf;

private string repoFile(string relative) {
    auto root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    auto path = buildPath(root, relative);
    assert(exists(path), "application binding ownership: missing " ~ relative);
    return readText(path);
}

private size_t occurrences(string source, string needle) {
    size_t count;
    size_t offset;
    while (offset < source.length) {
        auto found = source[offset .. $].indexOf(needle);
        if (found < 0) break;
        ++count;
        offset += cast(size_t)found + needle.length;
    }
    return count;
}

unittest {
    auto binding = repoFile("source/application_command_binding.d");
    auto controller = repoFile("source/guarded_action_controller.d");
    auto executor = repoFile("source/command_executor.d");
    auto http = repoFile("source/http_providers.d");
    auto app = repoFile("source/app.d");

    assert(binding.length > 4_000,
        "application binding ownership: binding population is implausibly small");
    assert(binding.canFind("Registry* registry")
        && binding.canFind("CommandExecutor executor")
        && binding.canFind("EditSession session")
        && binding.canFind("CommandInvocationContext")
        && binding.canFind("GuardedActionController uiPolicy"),
        "application binding ownership: required binding inputs disappeared");
    assert(!binding.canFind("import http_server"),
        "application binding ownership: common binding must not depend on HTTP");
    assert(!executor.canFind("import editor_app"),
        "application binding ownership: CommandExecutor regained EditorApp");
    assert(controller.canFind("Command pendingCommand_")
        && controller.canFind("RecordMode pendingMode_")
        && controller.canFind("GuardSettle settle_"),
        "guard action ownership: controller lost owned pending state");
    immutable string[] forbiddenControllerImports = [
        "import editor_app", "import http_server", "import bindbc.sdl",
        "import d_imgui",
    ];
    foreach (needle; forbiddenControllerImports)
        assert(!controller.canFind(needle),
            "guard action ownership: controller gained forbidden dependency '"
            ~ needle ~ "'");

    immutable string[] retiredHttpOwners = [
        "formsInteractiveLatch",
        "setInteractiveLatchHook",
        "formsPanel.setTweakEndHook",
        "replayUndoEntry =",
        "uiCommandDelegate =",
        "formsInteractiveDispatch =",
        "new ApplicationCommandBinding",
    ];
    foreach (needle; retiredHttpOwners)
        assert(!http.canFind(needle),
            "application binding ownership: HTTP still owns '" ~ needle ~ "'");

    assert(occurrences(app, "    uiCommandDelegate = (") == 1
        && occurrences(app, "    formsInteractiveDispatch = (") == 1
        && occurrences(app, "    replayUndoEntry = (") == 1,
        "application binding ownership: application delegates are not each bound once");
    assert(occurrences(app, "wireHttpProviders(httpServer, app, ifs, executor, commandBinding)") == 1,
        "application binding ownership: HTTP adapter is not consuming the application binding");

    immutable string[] retiredGuardLocals = [
        "pendingGuardedCmd", "pendingGuardedMode", "guardSettle",
        "void guardAnswerSave()", "void guardAnswerDiscard()",
        "void guardAnswerCancel()", "void settleGuardedAction()",
    ];
    foreach (needle; retiredGuardLocals)
        assert(!app.canFind(needle),
            "guard action ownership: app.d retained '" ~ needle ~ "'");
    assert(occurrences(app, "guardController.dropPending();") == 1,
        "primary switch forgot the pending guarded action");

    const syncAt = app.indexOf("syncDocRevision(changeBus.docRevision());");
    const settleAt = app.indexOf("guardController.settle();");
    assert(syncAt >= 0 && settleAt > syncAt,
        "guard action ownership: settle must remain after syncDocRevision");
}
