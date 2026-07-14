// test_ai3d_install_script.d — offline test for
// tools/ai3d_worker/install_linux.sh (task 0403): --help and --dry-run must
// work without any network or filesystem side effects. The editor's
// Generate 3D panel "Install" confirmation popup / streamed-log flow calls
// this script for a REAL install; the automated suite only ever exercises
// --dry-run, per task 0403's "never run a real install here" instruction —
// a real run needs torch + a multi-GB TRELLIS clone, which is owner-only.

import std.algorithm.searching : canFind;
import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse;
import std.path    : buildPath;
import std.process : execute;
import std.random  : uniform;
import std.stdio   : stderr;

private enum installScript = "tools/ai3d_worker/install_linux.sh";

// D disallows a try/catch directly inside a scope(exit) statement, so
// best-effort cleanup goes through this nothrow helper instead (same
// pattern as remesh_job.d's own tryRemove).
private void tryRmdirRecurse(string dir) nothrow {
    try rmdirRecurse(dir); catch (Exception) {}
}

unittest {
    if (!exists(installScript)) {
        stderr.writeln("SKIP test_ai3d_install_script (install_linux.sh not found — cwd not repo root?)");
        return;
    }

    // --help exits 0 and documents every flag, without touching anything.
    auto help = execute([installScript, "--help"]);
    assert(help.status == 0, help.output);
    assert(help.output.canFind("--dry-run"));
    assert(help.output.canFind("--location"));
    assert(help.output.canFind("--trellis-root"));

    // --dry-run: prints the full plan, creates/downloads/writes NOTHING,
    // exits 0. XDG_DATA_HOME is overridden to a scratch dir so this test
    // can never touch a real user's ~/.local/share/vibe3d, even though
    // --dry-run itself is documented to write nothing there either way.
    const scratch = buildPath(tempDir(),
        "vibe3d_ai3d_install_test_" ~ uniform(0, int.max).to!string);
    const loc = buildPath(scratch, "install-here");
    scope(exit) tryRmdirRecurse(scratch);

    string[string] env;
    env["XDG_DATA_HOME"] = buildPath(scratch, "xdg-data");

    auto dry = execute(
        [installScript, "--dry-run", "--location", loc,
         "--trellis-root", "/tmp/vibe3d-test-nonexistent-trellis-root"],
        env);
    assert(dry.status == 0, dry.output);
    assert(dry.output.canFind("no changes made"), dry.output);
    assert(dry.output.canFind(loc), dry.output);
    assert(dry.output.canFind("~4 GB"), "plan must call out the separate model download size");

    assert(!exists(loc), "--dry-run must not create the install location");
    assert(!exists(env["XDG_DATA_HOME"]), "--dry-run must not write the config file");
}

void main() {}
