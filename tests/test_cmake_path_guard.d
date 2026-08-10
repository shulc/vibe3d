// test_cmake_path_guard.d — third_party/nfde/configure_guarded.cmake (task 0673).
//
// A CMake build directory records the absolute paths it was configured for.
// Reach the same files under a second absolute path — a container bind-mounting
// the workspace, a moved or copied checkout — and CMake refuses to reuse the
// directory and fails the build. That is what broke the nightly: the release job
// mounts the workspace at /src and builds there, over a directory the matrix
// build had just created under the runner's own path.
//
// The guard exists to survive that. It must do so WITHOUT going back to the
// unconditional `rm -rf out` that task 0662 removed — that wipe made the build
// path-indifferent, but at the cost of rebuilding the whole C++ backend for a
// one-line D change (8.6s → 6.4s once removed).
//
// So this test is about the PATH CHANGE, not about the build. "it compiles" is
// exactly what passed on the runner while the nightly died. Three assertions,
// and the last two matter as much as the first:
//
//   A. unchanged path        → the guard leaves the warm directory alone
//   B. changed path          → the guard recovers (and a plain `cmake -B` does not)
//   C. real error, same path → the guard leaves the warm directory alone and says so
//
// A and C are what pin "conditional, not a wipe": delete the condition and turn
// the guard back into `rm -rf`, and B still passes while A and C fail.
//
// The fixture is a `project(... NONE)` CMake project — no compiler, no sources,
// a few hundredths of a second per configure. Renaming its directory is a
// portable stand-in for the container's second mount point: it produces the
// identical pair of CMake errors (verified, task 0673), and works the same on
// Linux, macOS and Windows.

import std.algorithm.searching : canFind;
import std.array   : join, split;
import std.conv    : to;
import std.file    : exists, mkdirRecurse, rename, rmdirRecurse, tempDir, write;
import std.path    : absolutePath, buildPath;
import std.process : execute;
import std.random  : uniform;
import std.stdio   : stderr;

private enum guardScript = "third_party/nfde/configure_guarded.cmake";

// `message()` re-wraps its text to a fixed width, and because our messages
// embed absolute paths, WHERE it wraps depends on how long the scratch path
// happens to be. A multi-word needle can therefore straddle a newline on one
// machine and not another — a flake that would only ever show up on someone
// else's tempDir. Match against whitespace-collapsed output instead.
private string squashed(string s) { return s.split.join(" "); }

// D disallows try/catch directly inside a scope(exit) statement.
private void tryRmdirRecurse(string dir) nothrow {
    try rmdirRecurse(dir); catch (Exception) {}
}

private bool haveCmake() nothrow {
    try return execute(["cmake", "--version"]).status == 0;
    catch (Exception) return false;
}

unittest {
    if (!exists(guardScript)) {
        stderr.writeln("SKIP test_cmake_path_guard (", guardScript,
                       " not found — cwd not repo root?)");
        return;
    }
    // cmake is a hard build requirement of this repo (third_party/nfde builds
    // its C++ backend with it), so this should never fire on a machine that
    // can build vibe3d at all. It is here so a stripped container reports a
    // skip rather than an inscrutable failure.
    if (!haveCmake()) {
        stderr.writeln("SKIP test_cmake_path_guard (no cmake on PATH)");
        return;
    }

    const guard = absolutePath(guardScript);
    const scratch = buildPath(tempDir(),
        "vibe3d_cmake_path_guard_" ~ uniform(0, int.max).to!string);
    scope(exit) tryRmdirRecurse(scratch);

    const dirA = buildPath(scratch, "at-first-path");
    const dirB = buildPath(scratch, "at-second-path");
    mkdirRecurse(dirA);

    enum trivialProject =
        "cmake_minimum_required(VERSION 3.13)\nproject(probe NONE)\n";
    enum failingProject =
        "cmake_minimum_required(VERSION 3.13)\nproject(probe NONE)\n"
        ~ "message(FATAL_ERROR \"stand-in for a missing system dependency\")\n";

    write(buildPath(dirA, "CMakeLists.txt"), trivialProject);

    // Invoke the guard exactly as third_party/nfde/dub.json's preBuildCommands
    // do, including the `--` separator that forwards the real flags through.
    auto runGuard(string srcDir) {
        return execute(["cmake",
                        "-DGUARD_SOURCE_DIR=" ~ srcDir,
                        "-DGUARD_BUILD_DIR=" ~ buildPath(srcDir, "out"),
                        "-P", guard, "--", "-DCMAKE_BUILD_TYPE=Release"]);
    }

    // A warm build directory is identified by a file the guard has no reason to
    // touch. If the guard ever goes back to clearing unconditionally, this
    // vanishes and cases A and C fail.
    string warmMark(string srcDir) { return buildPath(srcDir, "out", "warm.mark"); }

    // ---- first configure: creates the build directory at path A ------------
    auto first = runGuard(dirA);
    assert(first.status == 0, "guard failed on a fresh build directory:\n" ~ first.output);
    assert(exists(buildPath(dirA, "out", "CMakeCache.txt")),
           "guard did not produce a CMake cache:\n" ~ first.output);

    // ---- A. unchanged path: the warm directory must survive -----------------
    write(warmMark(dirA), "");
    auto again = runGuard(dirA);
    assert(again.status == 0, "guard failed on an unchanged path:\n" ~ again.output);
    assert(exists(warmMark(dirA)),
           "guard cleared a build directory that had not moved — that is the "
           ~ "unconditional wipe task 0662 removed, back again:\n" ~ again.output);

    // ---- B. the path changed --------------------------------------------
    rename(dirA, dirB);

    // First prove the fixture really reaches the failure mode, so a passing
    // case B can never be an artefact of a test that stopped discriminating.
    auto plain = execute(["cmake", "-B", buildPath(dirB, "out"),
                          "-DCMAKE_BUILD_TYPE=Release", dirB]);
    assert(plain.status != 0,
           "a plain `cmake -B` accepted a relocated build directory — this "
           ~ "CMake no longer refuses, so this test proves nothing:\n" ~ plain.output);

    auto moved = runGuard(dirB);
    assert(moved.status == 0,
           "guard did not recover a relocated build directory — this is the "
           ~ "nightly failure:\n" ~ moved.output);
    // The recovery must be announced, not silent: whoever reads a CI log has to
    // be able to tell a cleared directory from a warm one.
    assert(squashed(moved.output).canFind("configure_guarded.cmake")
           && squashed(moved.output).canFind("different location"),
           "guard recovered without naming what it did:\n" ~ moved.output);
    assert(!exists(warmMark(dirB)),
           "guard reported clearing the relocated directory but left it in place:\n"
           ~ moved.output);

    // Recovery must be stable, not a one-shot: the second call at the new path
    // is an ordinary warm configure again.
    write(warmMark(dirB), "");
    auto settled = runGuard(dirB);
    assert(settled.status == 0, "guard failed after recovering:\n" ~ settled.output);
    assert(exists(warmMark(dirB)),
           "guard cleared the build directory a second time at the same path:\n"
           ~ settled.output);

    // ---- C. a real configure error must NOT cost the warm directory --------
    write(buildPath(dirB, "CMakeLists.txt"), failingProject);
    auto broken = runGuard(dirB);
    assert(broken.status != 0,
           "guard reported success for a project that cannot configure:\n" ~ broken.output);
    assert(exists(warmMark(dirB)),
           "guard cleared the build directory over an error that had nothing to "
           ~ "do with its path — it must only clear a directory that moved:\n"
           ~ broken.output);
    assert(squashed(broken.output).canFind("is NOT stale"),
           "guard failed without naming why it kept the directory:\n" ~ broken.output);
}

void main() {}
