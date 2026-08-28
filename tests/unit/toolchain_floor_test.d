module tests.unit.toolchain_floor_test;

// toolchain_floor_test — dub.json's compiler floor cannot be quietly deleted
// or lowered (task 2004/2540).
//
// THE FAILURE THIS TASK CLOSED. This project's `ref`-local declarations
// (`const ref <type> <name> = <expr>;`, six files: source/drag.d,
// source/math.d, source/tools/create/box.d,
// source/tools/transform/{move,transform}.d, source/ui/image_rows.d) were
// stabilized at D frontend 2.111 (ldc 1.41.0 -- LDC's own minor version is
// NOT the frontend version it implements; ldc 1.40.0 is frontend 2.110).
// Before `toolchainRequirements` existed in dub.json, an old ldc2 picked up
// by a short PATH entry (`/usr/bin/ldc2` on the dev host, still 1.40.0) did
// not refuse by version -- it died mid-compile on that construct in whatever
// file the compiler reached first, e.g.
//   source/ui/image_rows.d(564,9): Error: variable `...elidedPathText.slot`
//     - only parameters, functions and `foreach` declarations can be `ref`
// which reads as an unrelated code regression, not a stale toolchain. This
// was predicted in prose in dub.json's own build-type comments and happened
// anyway (a "the release build is broken" card filed 2026-08-26, withdrawn
// after the owner objected).
//
// WHAT THIS GATE IS FOR, AND WHAT IT IS NOT. The actual mutation for task
// 2004/2540 -- build with the real system ldc 1.40.0, watch the message
// change from the `ref`-local error to a version refusal, remove the field,
// watch the old error come back -- needs an actual old compiler binary on
// PATH and is not repeatable inside `dub test`. What THIS unittest catches,
// on every `dub test --config=tests` run, with no old compiler required, is
// the narrower but more likely regression: someone deletes
// `toolchainRequirements` outright, or silently lowers its floor below the
// language feature it exists to gate, and nobody notices until the next
// person with an old compiler on PATH hits the arbitrary-error failure mode
// again.

import std.json;
import std.file   : readText;
import std.path   : dirName, buildPath;
import std.array  : split;
import std.conv   : to;
import std.string : startsWith;

/// tests/unit/toolchain_floor_test.d -> tests/unit -> tests -> repo root.
/// __FILE_FULL_PATH__ instead of cwd, matching census_gate.d's
/// `censusRepoRoot`: `dub test` is expected to run from the repo root, but
/// nothing here should quietly go blind if it is ever invoked from elsewhere.
private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Parse a dub `VersionRange` of the one shape this project's
/// `toolchainRequirements` ever writes, `">=MAJOR.MINOR.PATCH"`, into a
/// comparable triple. Any other shape (a caret range, an `~>`, a bare
/// number) is refused loudly rather than silently read as 0.0.0 -- a parse
/// that swallows an unexpected shape is a check that cannot fail on that
/// shape.
private int[3] parseFloor(string range) {
    assert(range.startsWith(">="),
        "expected a \">=X.Y.Z\" toolchain floor, got: " ~ range);
    auto parts = range[2 .. $].split(".");
    assert(parts.length == 3,
        "expected MAJOR.MINOR.PATCH after \">=\", got: " ~ range);
    return [parts[0].to!int, parts[1].to!int, parts[2].to!int];
}

unittest { // the parser is a witness pair, not just trusted
    assert(parseFloor(">=1.41.0") == [1, 41, 0]);
    assert(parseFloor(">=2.111.0") == [2, 111, 0]);
    assert(parseFloor(">=0.0.0") == [0, 0, 0]);
}

unittest { // dub.json still declares the floor, at least as high as measured
    auto manifest = parseJSON(readText(buildPath(repoRoot, "dub.json")));

    assert("toolchainRequirements" in manifest,
        "dub.json no longer declares `toolchainRequirements` -- an old "
        ~ "compiler picked up from a short PATH entry (e.g. a system "
        ~ "/usr/bin/ldc2 below the project floor) will die on an unrelated "
        ~ "semantic error again instead of refusing by version. See task "
        ~ "2004/2540.");
    auto req = manifest["toolchainRequirements"];

    assert("ldc" in req,
        "toolchainRequirements has no `ldc` floor -- the failure task "
        ~ "2004/2540 exists for was specifically an old ldc2 from PATH");
    auto ldcFloor = parseFloor(req["ldc"].str);
    assert(ldcFloor == [1, 41, 0],
        "ldc floor in dub.json is now " ~ req["ldc"].str ~ "; the measured "
        ~ "floor is >=1.41.0 (ldc 1.40.0 = D frontend 2.110, which rejects "
        ~ "the `const ref` locals this project ships in six files -- see "
        ~ "dub.json's _comment-toolchain-floor). If the floor genuinely "
        ~ "moved, update THIS constant alongside dub.json's comment; do not "
        ~ "widen the assertion to make it pass.");

    assert("dmd" in req,
        "toolchainRequirements has no `dmd` floor -- the same `ref`-local "
        ~ "construct needs D frontend >=2.111 regardless of which compiler "
        ~ "reaches it first");
    auto dmdFloor = parseFloor(req["dmd"].str);
    assert(dmdFloor == [2, 111, 0],
        "dmd floor in dub.json is now " ~ req["dmd"].str ~ "; the measured "
        ~ "floor is >=2.111.0 -- see dub.json's _comment-toolchain-floor. If "
        ~ "the floor genuinely moved, update THIS constant alongside "
        ~ "dub.json's comment; do not widen the assertion to make it pass.");
}
