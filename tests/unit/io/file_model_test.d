module tests.unit.io.file_model_test;

import io.file_model : browserFileModel, selectBrowserBackendForTest;
static import io.file_dialog;
import std.algorithm : canFind;
import std.path : dirName, buildPath;
import std.process : execute, Config;

// Compatibility imports name the same functions and therefore the same storage.
static assert(__traits(isSame, browserFileModel, io.file_dialog.browserFileModel));
static assert(__traits(isSame, selectBrowserBackendForTest,
                       io.file_dialog.selectBrowserBackendForTest));

unittest {
    scope (exit) selectBrowserBackendForTest(false);
    io.file_dialog.selectBrowserBackendForTest(false);
    assert(!browserFileModel(), "file model desktop mode");
    io.file_dialog.selectBrowserBackendForTest(true);
    assert(browserFileModel(), "file model compatibility setter shares storage");
    selectBrowserBackendForTest(false);
    assert(!io.file_dialog.browserFileModel(), "file model lower setter shares storage");
}

unittest {
    enum root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
    const sharedResult = execute(["python3", buildPath(root, "tools/test_standalone_boundary.py"),
                            "BoundaryControls.test_runtime_registry_ownership"],
                          null, Config.none, size_t.max, root);
    assert(sharedResult.status == 0 && sharedResult.output.canFind("Ran 1 test"),
           "shared boundary runtime ownership controls: " ~ sharedResult.output);
    const guards = execute(["python3", buildPath(root, "tools/test_native_file_model.py")],
                           null, Config.none, size_t.max, root);
    assert(guards.status == 0 && guards.output.canFind("Ran 5 tests"),
           "native production boundary negative fixtures: " ~ guards.output);
    const result = execute(["python3", buildPath(root, "tools/check_native_file_model.py"),
                           "--root", root], null, Config.none, size_t.max, root);
    assert(result.status == 0 && result.output.canFind("NATIVE-BOUNDARY-VERDICT=GREEN"),
           "native production file-model boundary: " ~ result.output);
}
