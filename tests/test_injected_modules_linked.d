/// test_injected_modules_linked.d — every test binary still links EVERY
/// injected module (card gate-speedup).
///
/// run_test.d used to put `http_client.d`, each `tests/*_helpers.d` and
/// `tests/liveness_gate.d` on every test's compile line. Since the gate-speedup
/// card they are compiled ONCE per run into one object (`buildHelperObject`)
/// that each test links. The old line gave "all of them, in every binary,
/// imported or not" for free; now it rests on that object being linked WHOLE.
/// An archive, or a line that links only the helpers a test imports, would
/// drop the rest together with their module constructors and destructors --
/// and `liveness_gate`'s is the one that turns "this binary ran nothing" into
/// exit 3 (task 1111), so losing it is silent by construction.
///
/// This file imports NONE of those modules, on purpose: it is the binary an
/// archive would strip, and it reads its own module table as the real runner
/// built it. `run_test.d`'s own unittest checks the same helper on a throwaway
/// tree; this one checks the production arrangement.
module test_injected_modules_linked;

import std.algorithm : filter, map, sort;
import std.array     : array, join;
import std.file      : dirEntries, SpanMode;
import std.format    : format;
import std.path      : baseName, stripExtension;

void main() {}

unittest
{
    // The same set run_test.d's injectedTestModules() names, read from disk
    // (the cwd every test binary inherits is the repository root).
    string[] want = ["http_client", "liveness_gate"];
    foreach (e; dirEntries("tests", "*_helpers.d", SpanMode.shallow))
        want ~= baseName(e.name).stripExtension;
    sort(want);
    // Population floor: 18 helpers + http_client + liveness_gate on
    // 2026-09-25 (`ls tests/*_helpers.d | wc -l` -> 18). A floor, not an
    // identity, so adding a helper does not redden this; the membership
    // check below is the property.
    assert(want.length >= 20, format(
        "only %d injected modules found from %s -- wrong cwd?", want.length, "tests/"));

    bool[string] linked;
    foreach (m; ModuleInfo)
        if (m !is null) linked[m.name] = true;
    auto missing = want.filter!(w => (w in linked) is null).array;
    assert(missing.length == 0, format(
        "%d of %d injected modules are NOT linked into this test binary: %s. "
      ~ "run_test.d must link the shared helper object whole (see "
      ~ "buildHelperObject), not as an archive or per import.",
        missing.length, want.length, missing.join(", ")));
}
