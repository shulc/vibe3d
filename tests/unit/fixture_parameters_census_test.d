// fixture_parameters_census_test — every `parameters` block a golden fixture
// carries must be STRUCTURALLY VALID, and the corpus must actually contain
// some (task 3010).
//
// WHY THE FIXTURES NEED THIS FIELD AT ALL. A parallel audit asks, for every
// tool parameter with a far side — negative, zero, past a period — whether any
// frozen cell has ever been captured there. For a fixture that does not record
// the parameters it was driven with, that question is not answered "no"; it is
// UNANSWERABLE, and the two are different results. A corpus that cannot say
// where it sits in the parameter domain cannot be used to argue that a law was
// discriminated — which is this repository's most-paid-for defect one level up:
// not a check that cannot redden, but a CORPUS that cannot be shown to cover
// anything.
//
// WHY THIS CHECK IS A `tests/unit` MODULE AND NOT A PYTHON SCRIPT. Because two
// checkers in exactly this family are already correct, meaningful, and INERT:
// `tools/local/fixture_gen/provenance_check.py` (backlog 2860) and
// `tools/local/fixture_gen/tests/test_provenance_offline.py` (backlog 2970) —
// neither is called by `./run_test.d`, by `dub test --config=tests`, or by any
// CI step, so neither can come out any way at all. Backlog 2860's own point (2)
// names the fix: a module test that reads the fixture catalogue lands in the
// unit lane for free and needs no separate discipline. This is that.
//
// WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT. It checks the rule that is
// TRUE OF THE TREE TODAY:
//
//     a `parameters` block that is PRESENT must be structurally valid.
//
// It does NOT require the block to be present. That rule — every fixture must
// carry one — is the owner's requirement and it is real, but switching it on
// over a corpus that violates it in 73 places gets it switched back off by the
// first person who meets it on someone else's change. That is precisely how
// 2860 and 2970 became inert. The presence rule turns on when the census reads
// zero absent; the condition is written down in
// `doc/tasks/work/3010-fixture-parameters-schema.md`.
//
// THE ANTI-VACUITY HALF, and it is not decoration. Two ways this census could
// pass while looking at nothing: the glob matches no file, or it matches only
// fixtures with no block, so the validator never runs. Both are guarded — the
// scan floor, and a demand that the corpus exhibit BOTH a `recorded` block and
// a `none` block, so the two branches of the validator are known to have been
// exercised on real data rather than on the empty set.
//
// MUTATIONS THAT REDDEN IT (all three run and recorded in the task card):
//   * corrupt any present block (`"state": "recorded"` -> `"maybe"`) => item 3
//     names the file and the offending value;
//   * empty every `cells` list of a `recorded` block => item 3 fires the
//     anti-vacuity rule ("that is state 'none', not a recorded drive");
//   * delete `stat_predicates_read.json`'s block => item 2 fires, because the
//     corpus no longer exhibits a `none` block.
// Removing a block from a `recorded` fixture does NOT redden this module by
// design — it is the presence rule, which is off. It reddens the census report
// (`parameters_check.py`), by name, and that is the direction the census owns.
//
// The scan is `__FILE_FULL_PATH__`-rooted, never cwd-rooted: a lane runs the
// unit binary from several directories and a cwd-relative glob would quietly
// match nothing.
module tests.unit.fixture_parameters_census_test;

import std.algorithm : canFind, sort;
import std.array     : appender, array;
import std.conv      : to;
import std.file      : dirEntries, exists, isFile, readText, SpanMode;
import std.format    : format;
import std.json      : JSONException, JSONType, JSONValue, parseJSON;
import std.path      : baseName, buildPath, dirName, extension, relativePath;

private enum unitDir     = dirName(__FILE_FULL_PATH__);
private enum fixturesDir = buildPath(dirName(unitDir), "fixtures");

/// The vocabularies, kept in step with
/// `tools/local/fixture_gen/parameters.py` (private). A value added there and
/// not here reddens this module with the offending value printed, which is the
/// intended way to find out.
private enum int    kParametersSchema = 1;
private immutable string[] kStates = ["recorded", "none", "unrecoverable"];
private immutable string[] kDerivedFrom = ["generator", "replay-steps", "capture", "hand"];

private struct Scanned
{
    string[] problems;
    size_t files;          /// fixture JSON files read
    size_t withBlock;      /// files carrying a `parameters` key
    size_t recorded, none, unrecoverable;
}

/// True for a JSON value that may stand as a parameter VALUE: a scalar, or a
/// flat list of scalars. A nested object hides the leaf a far-side query has to
/// read, so the schema forbids it and asks for a dotted name instead.
private bool isScalar(const JSONValue v)
{
    switch (v.type)
    {
        case JSONType.string, JSONType.integer, JSONType.uinteger,
             JSONType.float_, JSONType.true_, JSONType.false_, JSONType.null_:
            return true;
        default:
            return false;
    }
}

private void lintValues(const JSONValue values, string where, ref string[] errs)
{
    if (values.type != JSONType.object)
    {
        errs ~= format("%s.values is not an object", where);
        return;
    }
    foreach (k, v; values.object)
    {
        if (k.length == 0)
        {
            errs ~= format("%s.values has an empty parameter name", where);
            continue;
        }
        if (isScalar(v))
            continue;
        if (v.type == JSONType.array)
        {
            foreach (e; v.array)
                if (!isScalar(e))
                {
                    errs ~= format("%s.values[\"%s\"] is a list with a non-scalar "
                                   ~ "element (flatten it with a dotted name)", where, k);
                    break;
                }
            continue;
        }
        errs ~= format("%s.values[\"%s\"] is neither a scalar nor a flat list "
                       ~ "(flatten a structured parameter with a dotted name)", where, k);
    }
}

/// Structural lint of one block. Mirrors `parameters.lint_parameters`; returns
/// every problem rather than the first, so one run names every offender.
private string[] lintParameters(const JSONValue block)
{
    string[] errs;
    if (block.type != JSONType.object)
        return ["parameters block is not an object"];

    auto obj = block.object;

    if ("schema" !in obj || obj["schema"].type != JSONType.integer
        || obj["schema"].integer != kParametersSchema)
        errs ~= format("parameters.schema != %d", kParametersSchema);

    if ("state" !in obj || obj["state"].type != JSONType.string
        || !kStates.canFind(obj["state"].str))
    {
        errs ~= format("parameters.state %s not in %s",
                       "state" in obj ? obj["state"].toString() : "<missing>", kStates);
        return errs;   // every rule below is state-dependent; do not guess which
    }
    const state = obj["state"].str;

    if (state == "recorded")
    {
        if ("derived_from" !in obj || obj["derived_from"].type != JSONType.string
            || !kDerivedFrom.canFind(obj["derived_from"].str))
            errs ~= format("parameters.derived_from %s not in %s (required when "
                           ~ "state == 'recorded')",
                           "derived_from" in obj ? obj["derived_from"].toString()
                                                 : "<missing>", kDerivedFrom);

        if ("cells" !in obj || obj["cells"].type != JSONType.array
            || obj["cells"].array.length == 0)
        {
            errs ~= "parameters.state == 'recorded' but parameters.cells is "
                  ~ "missing/empty -- a block that records nothing must say state "
                  ~ "'none' or 'unrecoverable', not 'recorded'";
            return errs;
        }

        bool anyDrove = false;
        foreach (i, cell; obj["cells"].array)
        {
            const where = format("parameters.cells[%d]", i);
            if (cell.type != JSONType.object)
            {
                errs ~= format("%s is not an object", where);
                continue;
            }
            auto c = cell.object;
            if ("cell" !in c || c["cell"].type != JSONType.string || c["cell"].str.length == 0)
                errs ~= format("%s.cell is missing/empty (it must name the "
                               ~ "fixture's own case, so a domain hit can be traced "
                               ~ "back to a cell)", where);
            if ("drove" !in c || c["drove"].type != JSONType.array)
            {
                errs ~= format("%s.drove is not a list (a cell that drives nothing "
                               ~ "carries an EMPTY list, which is a statement, not "
                               ~ "an omission)", where);
                continue;
            }
            if (c["drove"].array.length)
                anyDrove = true;
            foreach (j, d; c["drove"].array)
            {
                const dw = format("%s.drove[%d]", where, j);
                if (d.type != JSONType.object)
                {
                    errs ~= format("%s is not an object", dw);
                    continue;
                }
                auto dd = d.object;
                if ("op" !in dd || dd["op"].type != JSONType.string || dd["op"].str.length == 0)
                    errs ~= format("%s.op is missing/empty", dw);
                if ("values" !in dd)
                    errs ~= format("%s.values is missing", dw);
                else
                    lintValues(dd["values"], dw, errs);
            }
        }
        // THE anti-vacuity rule of the schema itself. A `recorded` block whose
        // every cell drove nothing is a claim of coverage with nothing behind
        // it -- the exact shape the whole corpus was in before this task. Such
        // a fixture is `none`, and saying so is free.
        if (errs.length == 0 && !anyDrove)
            errs ~= "parameters.state == 'recorded' but not one cell has a "
                  ~ "non-empty 'drove' -- that is state 'none' (no tool "
                  ~ "parameters exist), not a recorded drive";
    }
    else
    {
        if ("why" !in obj || obj["why"].type != JSONType.string
            || obj["why"].str.length == 0)
            errs ~= format("parameters.why is required and must be non-empty when "
                           ~ "state == '%s' -- both 'none' and 'unrecoverable' are "
                           ~ "claims about the world that a reader has to be able "
                           ~ "to check", state);
        if ("cells" in obj && obj["cells"].type == JSONType.array
            && obj["cells"].array.length)
            errs ~= format("parameters.state == '%s' but parameters.cells is "
                           ~ "non-empty; a drive record and 'no drive record' "
                           ~ "cannot both be true", state);
    }
    return errs;
}

private Scanned scanCorpus()
{
    Scanned s;
    if (!exists(fixturesDir))
        return s;
    foreach (entry; dirEntries(fixturesDir, SpanMode.depth))
    {
        if (!entry.isFile || entry.name.extension != ".json")
            continue;
        const rel = relativePath(entry.name, fixturesDir);
        s.files++;
        JSONValue fx;
        try
            fx = parseJSON(readText(entry.name));
        catch (JSONException e)
        {
            s.problems ~= format("%s: fixture JSON does not parse: %s", rel, e.msg);
            continue;
        }
        if (fx.type != JSONType.object || "parameters" !in fx.object)
            continue;
        s.withBlock++;
        auto block = fx.object["parameters"];
        auto errs = lintParameters(block);
        foreach (e; errs)
            s.problems ~= format("%s: %s", rel, e);
        if (errs.length == 0 && block.type == JSONType.object
            && "state" in block.object && block.object["state"].type == JSONType.string)
        {
            final switch (block.object["state"].str)
            {
                case "recorded":      s.recorded++;      break;
                case "none":          s.none++;          break;
                case "unrecoverable": s.unrecoverable++; break;
            }
        }
    }
    return s;
}

// 1 — the scan reached the corpus at all.
unittest
{
    auto s = scanCorpus();
    // An anti-vacuity CANARY on the glob, not a threshold on the property under
    // test. The property (item 3) is exact and admits zero exceptions; this
    // number only refuses a run that looked at nothing. It is a floor rather
    // than an exact count on purpose: several lanes add fixtures concurrently,
    // and an exact count would be a rebase conflict per lane for no gain
    // (`tests/unit/unittest_census_gate.d`'s header records that lesson).
    assert(s.files >= 100,
           format("fixture_parameters_census: the scan found only %d fixture "
                  ~ "JSON file(s) under %s -- a census that passes because it "
                  ~ "looked at nothing is this repository's most-paid-for "
                  ~ "defect", s.files, fixturesDir));
}

// 2 — the validator has been exercised on real data, in BOTH directions.
unittest
{
    auto s = scanCorpus();
    assert(s.recorded >= 1,
           format("fixture_parameters_census: not one fixture carries a valid "
                  ~ "'recorded' parameters block (%d file(s) scanned, %d with a "
                  ~ "block) -- the recorded branch of the validator would be "
                  ~ "green over the empty set", s.files, s.withBlock));
    assert(s.none >= 1,
           format("fixture_parameters_census: not one fixture carries a valid "
                  ~ "'none' parameters block (%d file(s) scanned, %d with a "
                  ~ "block) -- a fixture that legitimately drives no tool must "
                  ~ "be able to SAY so, and if none does, nothing proves this "
                  ~ "census does not simply flag them all", s.files, s.withBlock));
}

// 3 — the rule itself: every PRESENT block is structurally valid. Exact term,
//     zero exceptions. Accumulated and asserted once, so one run names every
//     offender instead of only the first (druntime stops a module at its first
//     failed assert, and a roster gate that asserts inside its loop hides the
//     rest of the roster behind the first row).
unittest
{
    auto s = scanCorpus();
    string joined;
    foreach (p; s.problems)
        joined ~= "\n  - " ~ p;
    assert(s.problems.length == 0,
           format("fixture_parameters_census: %d problem(s) in the fixture "
                  ~ "corpus's `parameters` blocks (%d file(s) scanned, %d with a "
                  ~ "block: %d recorded / %d none / %d unrecoverable):%s",
                  s.problems.length, s.files, s.withBlock,
                  s.recorded, s.none, s.unrecoverable, joined));
}
