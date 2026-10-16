// The prepared-protocol census must have a LIVE CALLER, and the caller is
// `run_test.d` (task 3691 follow-up).
//
// THE HOLE THIS CLOSES. The census — `tools/check_prepared_protocol.py` —
// used to hang off `preBuildCommands` of dub.json's `tests` configuration. It
// was moved out of there for cost (38.4 s on every `dub test --config=tests`
// that rebuilt anything) and into `run_test.d`'s main, as a barrier beside the
// test-liveness one. The move is right and the measurement is recorded at both
// sites. What the move LOST is the thing that made the old placement safe:
// dub could not silently stop running a preBuildCommand, whereas a call in a
// D source file can be deleted by anyone, in one line, and BOTH routine lanes
// stay green while doing it. That is the exact failure this project pays for
// most — a check that is satisfied by the broken tree too — and it would be
// invisible: a whole-tree property that has drifted produces a PASS, not a
// red. So the call site itself is pinned here.
//
// WHAT THE CENSUS IS NOW (task 4052). Its compile-fail half is gone: the 73
// fixtures under `tests/compile_fail/` were 72 compiler launches and 21.6 s of
// its 39.9 s, and both properties they stated are `static assert`s, now in
// `tests/unit/prepared_tool_transition_test.d`. What survives here is the part
// that has no assert-shaped substitute — statement ORDER inside another
// module's function body, caller sets across files no test binary imports,
// occurrence counts, body digests — plus the half of that new D census a
// compiler cannot see: that its module list still matches the .d files on
// disk. So this pin protects a smaller, cheaper scanner, and exactly the
// scanner that could not have been written as a test.
//
// WHY THIS CANNOT BE A SUBSTRING SEARCH. `run_test.d` MENTIONS
// `protocolCensus()` in prose more often than it calls it: at the time of
// writing, five raw occurrences, of which only three are code (the definition,
// the `--check-protocol` diagnostic, and the wide-path call) and two are
// comments explaining the move. A census that greps the raw file is therefore
// satisfied by a tree in which the call has been deleted and only its
// obituary remains — and equally by a commented-out call, or by the call's own
// name inside a `stderr.writeln` error message. So this file blanks comments
// and string literals to spaces FIRST (offsets preserved, so it can still name
// a line) and asks its question of the code that is left. The discrimination
// is not asserted by claim: `decoyMentionsOnly` below is a source fragment
// whose only occurrences are a comment and a string, and the predicate must
// REJECT it in the same run in which it accepts `run_test.d`.
//
// WHAT IS PINNED, and it is a position rather than a mere presence. The live
// call must sit in the window between the FIRST barrier's refusal
// (`HarnessStage.gateRefused`, the test-liveness gate) and the build
// (`dubBuild()`), and that window must also carry the census's own refusal
// (`HarnessStage.protocolRefused`) and the one sanctioned escape from it
// (`args.length > 1`, a narrow run naming a test). A call moved after the
// build, a call whose refusal was softened to a warning, or a skip widened
// past "the caller named a test" all redden here. Presence alone would not
// have caught any of them.
//
// MUTATION (run 2026-09-02): delete the `} else if (!protocolCensus())` arm
// from run_test.d's main and this file's first assert names it. Comment the
// same arm out instead — leaving the text in the file — and it still reddens,
// which is the half a grep would have missed.
module tests.unit.run_test_protocol_census_pin_test;

import std.exception : enforce;
import std.file : tempDir, mkdirRecurse, rmdirRecurse;
import tests.unit.census_symbols : exists = wave15Exists, readText = wave15ReadText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : execute, environment, thisProcessID;
import std.string    : indexOf;

import tests.unit.census_symbols : sharedBlankNonCode = blankNonCode;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

// The needles, all of them CODE tokens rather than prose.
private enum kCall       = "protocolCensus()";
private enum kFirstGate  = "HarnessStage.gateRefused";      // the liveness barrier's refusal
private enum kRefusal    = "HarnessStage.protocolRefused";  // this census's refusal
private enum kBuild      = "dubBuild()";
private enum kNarrowEsc  = "args.length > 1";               // the one sanctioned skip

/// Blank every comment and every string/char literal to spaces, in place, so
/// that what remains is code AND every surviving offset still indexes the
/// original text (newlines are kept, so a hit can be reported as a line).
private alias blankNonCode = sharedBlankNonCode;

private size_t lineOf(string src, size_t off)
{
    size_t line = 1;
    foreach (ch; src[0 .. off]) if (ch == '\n') line++;
    return line;
}

private enum preparedProtocolIdentityControls = q"PY
token_source = read_source_text(root / "packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d")
token_rows = d_string_rows(token_source, "kTokenModules")
copyable_rows = d_string_rows(token_source, "kCopyableByDesign")
if (len(token_rows) != 46 or token_rows.count("prepared_tool_effect") != 1
        or len(copyable_rows) != 3
        or copyable_rows.count("prepared_tool_effect.PreparedSubjectToken") != 1):
    raise SystemExit("prepared-protocol actual two-table identity projection")
qualified = "vibe3d.editing.contracts.prepared_tool_effect"
for name, expected in (
        ("kTokenModules", ["prepared_tool_effect", "prepared_tool_effect.Child", qualified + "_neighbor"]),
        ("kCopyableByDesign", ["prepared_tool_effect", "prepared_tool_effect.Child", qualified + "_neighbor"]),
        ("unrelatedTable", [qualified, qualified + ".Child", qualified + "_neighbor"])):
    fixture = ('private enum string[] ' + name + ' = [\n'
               + ',\n'.join(json.dumps(row) for row in
                             (qualified, qualified + ".Child", qualified + "_neighbor")) + '\n];')
    if d_string_rows(fixture, name) != expected:
        raise SystemExit("prepared-protocol bounded identity projection: " + name)
print('PREPARED-PROTOCOL-IDENTITY-CONTROLS passed=1')
PY";

// Tasks 20261990/20262570: call the production reader, then omit enough real
// inputs from each full synthetic owner to fall below its independent floor.
// See doc/library_layout_wave12_prerequisite_source_2026-10-12.md for evidence.
unittest
{
    import std.stdio : write;
    version (PreparedProtocolIdentityWitness)
    const probe = q"PY
from pathlib import Path
import ast
import json
import re
import sys
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "tools/dspans"))
from census_contracts import read_source_text
scanner = ast.parse((root / "tools/check_prepared_protocol.py").read_text())
exec(compile(ast.Module(body=[node for node in scanner.body
    if isinstance(node, ast.FunctionDef) and node.name == "d_string_rows"],
    type_ignores=[]), "check_prepared_protocol.py", "exec"))
PY" ~ preparedProtocolIdentityControls;
    else
    const probe = q"PY
from pathlib import Path
import sys
import tempfile
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "tools/dspans"))
import census_contracts
# Task 20263050: exercise the real fixture builder without running the full
# compiler-backed scanner again inside the module gate.
import ast
import json
import shutil
import re
sys.path.insert(0, str(root / "tools"))
from prepared_writer_census import (scan as scan_writer_graph,
    canonical as canonical_writer_graph, module_path,
    REGISTRATION_SOURCE_NAMES as writer_registration_source_names)
from census_contracts import read_source_text, logical_source_paths
ROOT = root
WRITER_MANIFEST = json.loads((root / "tools/prepared_writer_manifest.json").read_text())
scanner = ast.parse((root / "tools/check_prepared_protocol.py").read_text())
fixture_functions = {"fail", "writer_keys", "bypass_keys", "validate_writer_graph",
                     "mutation_rejected", "d_string_rows"}
exec(compile(ast.Module(body=[node for node in scanner.body
    if isinstance(node, ast.FunctionDef) and node.name in fixture_functions],
    type_ignores=[]), "check_prepared_protocol.py", "exec"))
if mutation_rejected(lambda fixture: None, ""):
    raise SystemExit("prepared-protocol complete writer mutation fixture changed its census")
def protocol_fixture_route_controls(fixture):
    # Wave19: these original non-writer inputs need a separate presence control.
    for relative in (
            "packages/tool-state/source/tools/common/session_mesh_key.d",
            "packages/tool-state/source/tools/edit/preview_rebuild.d",
            "packages/transform-ops/source/tools/transform/arcball.d",
            "packages/transform-ops/source/tools/transform/cluster_values.d",
            "packages/transform-ops/source/tools/transform/item_xform_kernels.d",
            "packages/transform-ops/source/tools/transform/morph_route.d",
            "packages/transform-ops/source/tools/transform/relocate_plane.d",
            "packages/transform-ops/source/tools/transform/scale_input.d",
            "packages/transform-ops/source/tools/transform/xform_kernels.d",
            "packages/creation-ops/source/tools/create/pen_geometry.d",
            "packages/alignment-ops/source/tools/alignment/align_kernels.d"):
        if not (fixture / relative).is_file():
            raise SystemExit("prepared-protocol fixture original tool backing: " + relative)
    recipe = json.loads((fixture / "dub.json").read_text())
    if (recipe.get("sourcePaths"), "importPaths" in recipe,
            recipe.get("mainSourceFile")) != (["source"], False, "source/app.d"):
        raise SystemExit("prepared-protocol fixture historical root role")
    # Independent C input inventory plus the adopted three whole backings;
    # catalogs are the historical root role and its original 56 leaf roles.
    if len(list(fixture.rglob("*.d"))) != 98:
        raise SystemExit("prepared-protocol fixture complete source population 98")
    if len(list(fixture.rglob("dub.json"))) != 57:
        raise SystemExit("prepared-protocol fixture catalog population 57")
if mutation_rejected(protocol_fixture_route_controls, ""):
    raise SystemExit("prepared-protocol fixture route controls changed its writer census")
PY" ~ preparedProtocolIdentityControls ~ q"PY
failures = census_contracts.production_lexer_census(root)
if failures:
    raise SystemExit("prepared-protocol production lexer census: " + "; ".join(failures))
# These are the approved complete current units, not generated lexer fixtures.
import hashlib
stat_origin = "tests/unit/ui/stat_rows_test.d"
stat_physical = read_source_text(census_contracts.physical_source_path(
    root / "packages/editor-ui/tests/source/tests/unit/ui/stat_rows_test.d", root=root), root=root).encode()
stat_header = b"module tests.unit.ui.stat_rows_test;\n\n"
if len(stat_physical) != 42593 or stat_physical[407:445] != stat_header:
    raise SystemExit("prepared-protocol stat physical whole-unit control")
stat_original = stat_physical[:407] + stat_physical[445:]
if len(stat_original) != 42555 or hashlib.sha256(stat_original).hexdigest() != "25e0025e79f39974afceb111205f5710a32a7d82cfa95916e8249e68302997ee":
    raise SystemExit("prepared-protocol stat original whole-unit control")
def stat_inverse_control(physical, original, accepted):
    first = census_contracts.source_input_start()
    restored = census_contracts._restore_source_text(stat_origin, physical.decode(), root)
    if (restored.encode() == original and census_contracts.source_inputs_intact(first)) != accepted:
        raise SystemExit("prepared-protocol stat complete inverse admission control")
stat_inverse_control(stat_physical, stat_original, True)
for invalid in (stat_original, stat_physical[:407] + stat_header + stat_physical[407:],
                stat_physical[:-1] + (b" " if stat_physical[-1:] != b" " else b"\n")):
    first = census_contracts.source_input_start()
    if (census_contracts._restore_source_text(stat_origin, invalid.decode(), root)
            or census_contracts._source_validity[first] or census_contracts.source_inputs_intact(first)):
        raise SystemExit("prepared-protocol stat missing/duplicate/wrong-body input must be refused")
stat_inverse_control(stat_physical, stat_original, True)
editor_path = census_contracts.physical_source_path(root / "source/editor_app.d", root=root)
editor_current = editor_path.read_bytes()
editor_physical = read_source_text(editor_path, root=root).encode()
first = census_contracts.source_input_start()
editor_original = census_contracts._restore_source_text("source/editor_app.d", editor_physical.decode(), root).encode()
if (len(editor_physical) != 52269 or len(editor_original) != 48220
        or editor_original != editor_physical[:48220]
        or hashlib.sha256(editor_original).hexdigest() != "59febb4cbc81bfbaf20d8065e9d28618c411c10f475a10a8857998a7f5ebe63c"
        or not census_contracts.source_inputs_intact(first)):
    raise SystemExit("prepared-protocol editor complete inverse control")
editor_wrong_body = (b" " if editor_physical[:1] != b" " else b"\n") + editor_physical[1:]
editor_wrong_current = (b" " if editor_current[:1] != b" " else b"\n") + editor_current[1:]
if census_contracts._wave19_original(
        census_contracts._wave19_import_original(editor_path, editor_wrong_current.decode(), root),
        census_contracts._wave19_coordinate(editor_path, root)[1]).encode() != editor_wrong_body:
    raise SystemExit("prepared-protocol current wrong-body fixture retains only approved import tokens")
first = census_contracts.source_input_start()
if (census_contracts._restore_source_text("source/editor_app.d", editor_wrong_body.decode(), root)
        or census_contracts._source_validity[first] or census_contracts.source_inputs_intact(first)):
    raise SystemExit("prepared-protocol editor wrong whole-file bytes must be refused")
owners = {'packages/camera-model/source': 1, 'packages/document-channels/source': 1, 'packages/image-codec/source': 1, 'packages/document-io/source': 3, 'source': 318, 'packages/alignment-ops/source': 1, 'packages/command-runtime/source': 22, 'packages/application-core/source': 7, 'packages/document-model/source': 5, 'packages/param-schema/source': 2, 'packages/pipe-runtime/source': 4, 'packages/creation-ops/source': 1, 'packages/display-policy/source': 12, 'packages/edit-contracts/source': 4, 'packages/input-events/source': 6, 'packages/interaction-query/source': 12, 'packages/interchange/source': 8, 'packages/mesh-change/source': 2, 'packages/mesh-contracts/source': 4, 'packages/mesh-edit-log/source': 1, 'packages/mesh-edit-replay/source': 1, 'packages/mesh-ops/source': 30, 'packages/mesh-snapshot/source': 1, 'packages/mesh-topology/source': 1, 'packages/mesh/source': 4, 'packages/pipe-evaluation/source': 12, 'packages/profiling/source': 1, 'packages/spatial/source': 5, 'packages/subpatch-preview/source': 5, 'packages/tool-state/source': 2, 'packages/transform-ops/source': 7, 'packages/viewport-gpu/source': 6, 'util/log/source': 1, 'util/math/source': 5, 'util/parallel/source': 1, 'util/plane-bytes/source': 1, 'util/screen-buckets/source': 1, 'packages/pipe-contracts/source': 2, 'packages/mesh-preview/source': 2, 'util/json-number/source': 1, 'packages/selection-model/source': 2, 'packages/scene-query/source': 2, 'packages/editor-commands/source': 100}
# Independently frozen owner floors, separate from the logical populations.
floors = {'packages/command-runtime/source': 22, 'packages/application-core/source': 7, 'packages/camera-model/source': 1, 'packages/document-channels/source': 1, 'packages/image-codec/source': 1, 'packages/document-io/source': 3, 'source': 318, 'packages/alignment-ops/source': 1, 'packages/document-model/source': 5, 'packages/param-schema/source': 2, 'packages/pipe-runtime/source': 4, 'packages/creation-ops/source': 1, 'packages/display-policy/source': 12, 'packages/edit-contracts/source': 4, 'packages/input-events/source': 6, 'packages/interaction-query/source': 12, 'packages/interchange/source': 8, 'packages/mesh-change/source': 2, 'packages/mesh-contracts/source': 4, 'packages/mesh-edit-log/source': 1, 'packages/mesh-edit-replay/source': 1, 'packages/mesh-ops/source': 21, 'packages/mesh-snapshot/source': 1, 'packages/mesh-topology/source': 1, 'packages/mesh/source': 4, 'packages/pipe-evaluation/source': 12, 'packages/profiling/source': 1, 'packages/spatial/source': 5, 'packages/subpatch-preview/source': 5, 'packages/tool-state/source': 2, 'packages/transform-ops/source': 7, 'packages/viewport-gpu/source': 6, 'util/log/source': 1, 'util/math/source': 5, 'util/parallel/source': 1, 'util/plane-bytes/source': 1, 'util/screen-buckets/source': 1, 'packages/pipe-contracts/source': 2, 'packages/mesh-preview/source': 2, 'util/json-number/source': 1, 'packages/selection-model/source': 2, 'packages/scene-query/source': 2, 'packages/editor-commands/source': 100}
owner_inputs = {owner: sorted(census_contracts.logical_source_paths(
    root / owner, "*.d", root=root)) for owner in owners}
# Materialize original logical inputs at their existing backing paths, plus
# fragment carriers. Every directory is owned by this temporary fixture;
# removing a file link cannot traverse a directory link into the real tree.
backing_paths = {census_contracts.physical_source_path(path, root=root)
                 for inputs in owner_inputs.values() for path in inputs}
backing_paths.update(census_contracts.physical_source_path(
    root / fragment["destination"], root=root)
    for fragment in census_contracts.SOURCE_FRAGMENTS)
backing_paths.add(root / "dub.json")
# Every finite selected owner's physical coordinate is chosen by its recipe.
for _, old, new in census_contracts._WAVE19_OWNERS:
    backing_paths.add(root / (new if (root / new / "dub.json").is_file() else old) / "dub.json")
backing_paths.update(census_contracts.physical_source_path(root / old, root=root)
                     for _, old, _, _ in census_contracts._WAVE19_COORDINATES)
with tempfile.TemporaryDirectory(prefix="protocol-owners-") as scratch:
    partial = Path(scratch)
    for path in sorted(backing_paths):
        link = partial / path.relative_to(root)
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(path)
    got = census_contracts.production_lexer_census(partial)
    if got:
        raise SystemExit(f"prepared-protocol synthetic complete baseline: {got!r}")
    for owner, floor in floors.items():
        population = owners[owner]
        inputs = owner_inputs[owner]
        # The omission population is independently frozen, not derived
        # from the reader or the fixture it will judge.
        if len(inputs) != population:
            raise SystemExit(f"prepared-protocol omission input changed: {owner}")
        omitted = population - floor + 1
        for path in inputs[:omitted]:
            backing = census_contracts.physical_source_path(path, root=root)
            (partial / backing.relative_to(root)).unlink()
        def no_parse(*args, **kwargs):
            raise SystemExit("prepared-protocol incomplete inventory must refuse before parsing")
        original_spans = census_contracts.dspans_client.spans
        census_contracts.dspans_client.spans = no_parse
        try:
            got = census_contracts.production_lexer_census(partial)
        finally:
            census_contracts.dspans_client.spans = original_spans
        complement = f"dspans production complement read {608 - omitted} files; floor 608"
        owner_refusal = f"dspans lexer census owner {owner} read {floor - 1} files; floor {floor} (materialized 2026-10-10)"
        if complement not in got:
            raise SystemExit(f"prepared-protocol COMPLEMENT omission guard {owner}: got {got!r}, missing {complement!r}")
        if owner_refusal not in got:
            raise SystemExit(f"prepared-protocol OWNER omission guard {owner}: got {got!r}, missing {owner_refusal!r}")
        if got != [complement, owner_refusal]:
            raise SystemExit(f"prepared-protocol omission diagnostics {owner}: got {got!r}, want {[complement, owner_refusal]!r}")
        print(f"prepared-protocol omission {owner}: COMPLEMENT and OWNER refused independently", flush=True)
        for path in inputs[:omitted]:
            backing = census_contracts.physical_source_path(path, root=root)
            (partial / backing.relative_to(root)).symlink_to(backing)
        if any(not (partial / path.relative_to(root)).is_file() for path in backing_paths):
            raise SystemExit(f"prepared-protocol owner restoration {owner}")
    got = census_contracts.production_lexer_census(partial)
    if got:
        raise SystemExit(f"prepared-protocol restored complete baseline: {got!r}")
    carrier = partial / editor_path.relative_to(root)
    carrier.unlink()
    carrier.write_bytes(editor_wrong_current)
    got = census_contracts.production_lexer_census(partial)
    if not any("dspans lexer diagnostics on tree files" in message for message in got):
        raise SystemExit(f"prepared-protocol complete tree wrong-body refusal: {got!r}")
    carrier.unlink()
    carrier.symlink_to(editor_path)
PY";
    const scratch = buildPath(tempDir(), format("protocol-census-%d", thisProcessID));
    mkdirRecurse(scratch);
    scope(exit) rmdirRecurse(scratch);
    auto env = environment.toAA;
    env["VIBE3D_HARNESS_LOG"] = "off";
    env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = buildPath(scratch, "run.lock");
    const result = execute(["python3", "-c", probe, repoRoot], env);
    assert(result.status == 0, result.output);
    version (PreparedProtocolIdentityWitness)
        assert(result.output.indexOf("PREPARED-PROTOCOL-IDENTITY-CONTROLS passed=1") >= 0,
            "prepared-protocol identity cell did not reach its terminal control: " ~ result.output);
    write(result.output);
}

private size_t countOf(string hay, string needle)
{
    size_t n, at;
    while (at < hay.length)
    {
        const rel = hay[at .. $].indexOf(needle);
        if (rel < 0) break;
        n++;
        at += rel + needle.length;
    }
    return n;
}

private struct Verdict { bool live; size_t line; string why; }

/// Is there a LIVE call to the protocol census on the wide path — after the
/// test-liveness barrier, before the build, refusing rather than warning?
private Verdict wideCensusCall(string src)
{
    const code = blankNonCode(src);

    const gate = code.indexOf(kFirstGate);
    if (gate < 0)
        return Verdict(false, 0, "no live `" ~ kFirstGate ~ "`: the test-liveness "
            ~ "barrier that anchors the window is gone, or survives only as prose");

    const rel = code[gate .. $].indexOf(kBuild);
    if (rel < 0)
        return Verdict(false, 0, "no live `" ~ kBuild ~ "` after the first barrier: "
            ~ "the window this census reasons about no longer closes");

    const lo = cast(size_t) gate, hi = lo + cast(size_t) rel;
    const window = code[lo .. hi];

    const call = window.indexOf(kCall);
    if (call < 0)
        return Verdict(false, 0, "no live call to `" ~ kCall ~ "` between the "
            ~ "test-liveness barrier and the build");
    if (window.indexOf(kRefusal) < 0)
        return Verdict(false, 0, "the call is there but `" ~ kRefusal ~ "` is not: "
            ~ "a census that does not refuse the run is a warning, and a warning "
            ~ "in a build log is how a whole-tree property rots unseen");
    if (window.indexOf(kNarrowEsc) < 0)
        return Verdict(false, 0, "no `" ~ kNarrowEsc ~ "` guard on the skip: the "
            ~ "ONLY sanctioned escape is a caller naming a test, and a skip "
            ~ "condition that widened past that has to be re-argued here");

    return Verdict(true, lineOf(src, lo + cast(size_t) call), "");
}

// A source fragment carrying every shape of MENTION and no call at all: a
// commented-out call, a commented-out refusal, and the names inside a string.
// The predicate must reject it — this is the substring census's false green,
// executed rather than described.
private enum decoyMentionsOnly =
      "    g_harness.stage = HarnessStage.gateRefused;\n"
    ~ "    // } else if (!protocolCensus()) {\n"
    ~ "    //     g_harness.stage = HarnessStage.protocolRefused;\n"
    ~ "    // skipped when args.length > 1\n"
    ~ "    stderr.writeln(\"protocolCensus() / HarnessStage.protocolRefused"
    ~ " / args.length > 1\");\n"
    ~ "    if (!noBuild && !dubBuild()) return 1;\n";

// The positive control: the same shape, actually called. Without this the
// rejection above would also be produced by a predicate that is simply always
// false, and the decoy would prove nothing.
private enum decoyLiveCall =
      "    g_harness.stage = HarnessStage.gateRefused;\n"
    ~ "    if (args.length > 1) { skip(); }\n"
    ~ "    else if (!protocolCensus()) {\n"
    ~ "        g_harness.stage = HarnessStage.protocolRefused;\n"
    ~ "        return 2;\n"
    ~ "    }\n"
    ~ "    if (!noBuild && !dubBuild()) return 1;\n";

unittest
{
    enforce(exists(runnerPath), "run_test.d not found at " ~ runnerPath);
    const src  = readText(runnerPath);
    const code = blankNonCode(src);

    // 1. THE PIN. run_test.d calls the census on the wide path.
    const v = wideCensusCall(src);
    assert(v.live, format(
        "run_test.d no longer calls the prepared-protocol census on the wide "
      ~ "path: %s.\n"
      ~ "That census is the ONLY caller of tools/check_prepared_protocol.py, "
      ~ "which pins properties no red assert can express — the ORDER of "
      ~ "statements inside another module's body, the caller set of a symbol "
      ~ "across files nothing imports, occurrence counts, body digests. With "
      ~ "this call gone both routine lanes stay green over a tree in which "
      ~ "every one of them has drifted. Restore the call in main (between the "
      ~ "test-liveness "
      ~ "barrier and dubBuild()), or, if it truly must move, move this pin "
      ~ "with it and say in the message where it went.", v.why));

    // 2. THE DISCRIMINATION IS LIVE, not claimed: the raw file really does
    //    mention the call more often than it makes it, so a grep-shaped census
    //    would be satisfied by strictly less than this one requires.
    const rawHits  = countOf(src,  kCall);
    const codeHits = countOf(code, kCall);
    assert(rawHits > codeHits, format(
        "expected run_test.d to MENTION `%s` in comments as well as call it "
      ~ "(raw %d, code %d). If the prose was removed, this census still works, "
      ~ "but the demonstration that it discriminates has gone with it — and "
      ~ "that demonstration is the reason it is not a grep.",
        kCall, rawHits, codeHits));
    assert(codeHits >= 2, format(
        "expected at least two LIVE occurrences of `%s` in run_test.d (the "
      ~ "definition and the wide-path call); found %d", kCall, codeHits));

    // 3. THE PREDICATE ITSELF, both ways, in this run.
    const dead = wideCensusCall(decoyMentionsOnly);
    assert(!dead.live,
        "the predicate accepted a source whose only occurrences are a "
      ~ "commented-out call and a string: it is behaving as a substring "
      ~ "search, which is exactly the census this file exists not to be");
    assert(wideCensusCall(decoyLiveCall).live,
        "the predicate rejected a source that really does call the census — "
      ~ "it is failing closed, so its rejection of the decoy proves nothing");

    // 4. THE CALL MUST STILL REACH THE SCANNER. A pinned call into a gutted
    //    `protocolCensus()` that returns true is the same hole with a call
    //    site, so brace-match the body and require both the scanner constant
    //    and a real process spawn inside it.
    const fn = code.indexOf("bool " ~ kCall);
    assert(fn >= 0, "run_test.d no longer defines `bool " ~ kCall ~ "`");
    size_t i = cast(size_t) fn;
    while (i < code.length && code[i] != '{') i++;
    size_t depth = 0, end = i;
    for (; end < code.length; end++)
    {
        if (code[end] == '{') depth++;
        else if (code[end] == '}' && --depth == 0) { end++; break; }
    }
    const body_ = code[i .. end];
    assert(body_.indexOf("kProtocolScanner") >= 0 && body_.indexOf("spawnProcess") >= 0,
        format("`%s` (run_test.d:%d) no longer spawns the scanner: its body "
             ~ "mentions neither kProtocolScanner nor spawnProcess, so the "
             ~ "pinned call site now calls nothing", kCall, lineOf(src, cast(size_t) fn)));

    // 5. And the scanner it names is on disk. "The file is not there" must not
    //    be indistinguishable from "the fixtures are fine".
    const decl = src.indexOf("enum string kProtocolScanner");
    assert(decl >= 0, "run_test.d no longer declares kProtocolScanner");
    const q1 = cast(size_t) decl + cast(size_t) src[decl .. $].indexOf('"') + 1;
    const q2 = q1 + cast(size_t) src[q1 .. $].indexOf('"');
    const scanner = src[q1 .. q2];
    assert(exists(buildPath(repoRoot, scanner)), format(
        "run_test.d names `%s` as the prepared-protocol scanner and no such "
      ~ "file exists in the tree", scanner));

    // 6. Anchor hygiene: the window's lower edge must be the unambiguous one
    //    it was chosen to be, so this census cannot start measuring some other
    //    stretch of main after a refactor moves a same-named token in.
    assert(countOf(code, kFirstGate) == 1, format(
        "`%s` occurs %d times in run_test.d's code; this census anchors its "
      ~ "window on it and needs it to be the single test-liveness refusal",
        kFirstGate, countOf(code, kFirstGate)));

    // Task 20263020: helper refusal controls must protect the actual CLI
    // observation path; see doc/ci_runner_failures_plan_2026-10-16.md.
    const cliPath = buildPath(repoRoot, "tests/test_standalone_cli.d");
    const cliCode = blankNonCode(readText(cliPath));
    const cliFn = cliCode.indexOf("private Run runCli(");
    assert(cliFn >= 0, "CLI readiness wiring: runCli definition missing");
    size_t cliStart = cast(size_t) cliFn;
    while (cliStart < cliCode.length && cliCode[cliStart] != '{') cliStart++;
    size_t cliDepth, cliEnd = cliStart;
    for (; cliEnd < cliCode.length; cliEnd++)
    {
        if (cliCode[cliEnd] == '{') cliDepth++;
        else if (cliCode[cliEnd] == '}' && --cliDepth == 0) { cliEnd++; break; }
    }
    assert(cliStart < cliEnd && cliDepth == 0,
        "CLI readiness wiring: runCli body missing or incomplete");
    const cliBody = cliCode[cliStart .. cliEnd];
    assert(countOf(cliBody, "awaitLoaded(pid, reaped, diagnostics, fifo)") == 1,
        "CLI readiness wiring: runCli must call awaitLoaded before process observation");
}
