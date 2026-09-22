// The browser seam key is ONE identifier, and this census exists because it was TWO for six
// slices of wave 15 and nothing could see it.
//
// What happened, measured 2026-09-21. Forty-eight sites carried `version (web)` and five
// carried `version (WebAssembly)`. Those are not equivalent: the compiler predefines the
// second on any wasm triple and NOTHING defines the first unless a build configuration does.
// So a wasm build without that configuration was HALF-gated -- two seams fired, two took the
// native arm and failed on an error that looks unrelated to gating. Two slices' own wasm
// controls were green only because their harness passed `-d-version=web` by hand, which
// witnesses the FLAG and not the BUILD.
//
// The direction of the fix was chosen by measurement and is the opposite of the intuition
// that a compiler-predefined key is safer: predefined is exactly what produces the partial
// state, because it fires regardless of configuration. With ONE key, no configuration gates
// nothing and the build fails uniformly -- and a uniform failure can be diagnosed while a
// partial one cannot. Derivation: doc/measurements/w15/phase0_findings.md 14.25 and 14.26.
//
// This census is a POPULATION check with a floor, not a spelling check: a floor first, so it
// cannot pass over an empty scan, then the exclusive count. One target guard is deliberately
// different: `version (WebAssembly)` immediately followed by a failing `static assert` rejects
// a wasm build that missed the configured browser key. It grants no capability and is counted
// exactly, so another capability gate cannot hide beside it.
module tests.unit.web_seam_key_census_test;

import std.algorithm : canFind, filter, map, sum;
import std.array     : array;
import std.file      : dirEntries, SpanMode, readText, exists;
import std.path      : buildPath;
import std.regex     : matchAll, regex;
import std.string    : indexOf;

private string repoRoot()
{
    string dir = ".";
    foreach (_; 0 .. 6)
    {
        if (exists(buildPath(dir, "dub.json")) && exists(buildPath(dir, "source")))
            return dir;
        dir = buildPath(dir, "..");
    }
    assert(false, "6910 web seam key census: no repository root above the test's cwd");
}

unittest // the browser seam key is exactly one identifier, and the alternative is absent
{
    const root = repoRoot();
    auto webRe  = regex(`version\s*\(\s*web\s*\)`);
    auto wasmRe = regex(`version\s*\(\s*WebAssembly\s*\)`);
    auto wasmGuardRe = regex(
        `version\s*\(\s*WebAssembly\s*\)\s*static\s+assert\s*\(`);

    size_t files, webSites, wasmSites, wasmGuardSites;
    string[] offenders;
    foreach (entry; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
    {
        ++files;
        const text = readText(entry.name);
        const w = text.matchAll(webRe).array.length;
        const a = text.matchAll(wasmRe).array.length;
        const g = text.matchAll(wasmGuardRe).array.length;
        webSites += w;
        wasmSites += a;
        wasmGuardSites += g;
        if (a != g) offenders ~= entry.name;
    }

    // FLOOR FIRST. Without it "no WebAssembly sites" is also true of a scan that read nothing,
    // which is the vacuous-predicate shape this project pays for most.
    assert(files >= 500,
        "6910 web seam key census: scanned only a handful of source files; the scan is the "
      ~ "subject here, and a small population makes every count below meaningless");
    assert(webSites >= 50,
        "6910 web seam key census: the browser key has nearly vanished from source/; either "
      ~ "the seams were removed or this scan is looking in the wrong place");

    // THE PROPERTY. `WebAssembly` may reject a target that missed `web`, but may not grant a
    // capability. Pin both halves so a vanished guard and a second capability key are red.
    assert(wasmGuardSites == 1,
        "6910 web seam key census: expected exactly one `version (WebAssembly)` target guard "
      ~ "immediately followed by `static assert`, found " ~ wasmGuardSites.to!string);
    assert(wasmSites == wasmGuardSites,
        "6910 web seam key census: source/ carries `version (WebAssembly)` as a capability "
      ~ "gate instead of the one failing target guard. The compiler predefines it on any wasm "
      ~ "triple while `web` comes only from a build configuration, so mixing the capability "
      ~ "keys makes a build without that configuration HALF-gated. Offenders: "
      ~ offenders.idup.to!string);
}

private import std.conv : to;
