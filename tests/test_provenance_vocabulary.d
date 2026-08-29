// test_provenance_vocabulary.d — task 3340, item C (backlog 3302): the fixture
// runner's `provenance` vocabulary, driven on the REAL corpus entries that
// used to be a mine under it.
//
// WHAT WAS WRONG. `provenance.method` had THREE vocabularies for one field:
// the private authority `tools/local/fixture_gen/provenance.py` (11 values),
// `tests/unit/fixture_provenance_census_test.d` (11, in step) and
// `tests/fixture_helpers.d`'s `requireProvenance` (8, three behind for eleven
// days). Measured on this branch, the corpus already carried all three of the
// missing values — `static-read` x3, `gui-gesture` x1, `debug-live` x1 out of
// 191 `method` values in tests/fixtures/**. It was not red only because none
// of those five fixtures happens to be read through `runFixture` /
// `runStage`, i.e. through `requireProvenance`. The first one that was would
// have reddened on a VALID value, with a message advising `"unknown"` —
// erasing the distinction somebody measured, to satisfy a stale list.
//
// WHY THIS FILE AND NOT A UNIT CELL. `requireProvenance` lives in
// `tests/fixture_helpers.d`, which is compiled by `run_test.d` (injected into
// every test binary) and is NOT in the `dub test --config=tests` source set.
// The unit lane can therefore pin the LIST; only this lane can drive the
// FUNCTION. Both now read one module, `tests/provenance_vocab.d`.
//
// THE FIXTURES ARE READ THROUGH `import()`, NOT OFF DISK, for the reason
// `test_tool_gesture_g1.d` states: the suite lane compiles a per-worker
// scratch COPY of `tests/`, so `__FILE_FULL_PATH__` names the copy while
// `-J=tests` resolves a string import in either tree.
//
// WHAT PINS THE LIST ITSELF is a different lane and a different instrument:
// `tests/unit/fixture_provenance_census_test.d` PARSES
// `kProvenanceMethodValues` out of `tests/fixture_helpers.d` (so the census
// and the runner cannot disagree by construction) and compares it by value
// name with the private authority `tools/local/fixture_gen/provenance.py`.
// That header records why a shared compiled module is not available across
// these two build systems.
//
// MUTATIONS THAT REDDEN IT:
//   * delete `"static-read"` (or `"gui-gesture"`, or `"debug-live"`) from
//     `kProvenanceMethodValues` in `tests/fixture_helpers.d` => flow A reddens
//     naming the FIXTURE and the value — this is the exact state the tree was
//     in before task 3340 — AND the unit lane's cross-language pin reddens
//     naming the value. Run them in isolation;
//   * make `requireProvenance` accept anything => flow B reddens (the bogus
//     value is admitted);
//   * revert the message to the old single-advice text => flow B's message
//     assertion reddens.
//
// LANE: `./run_test.d --no-build test_provenance_vocabulary`.

import std.format    : format;
import std.json      : JSONValue, parseJSON;
import std.stdio     : writefln, writeln;
import std.string    : indexOf;

import fixture_helpers : requireProvenance, kProvenanceMethodValues;
import liveness_gate   : scenario;

// The five corpus entries that carry a value the stale list refused. Named
// individually, with the value each one is here to witness: if a fixture is
// ever re-provenanced, this list must be re-pointed and the change is visible.
private struct Witness { string name; string json; string wantMethod; }

private immutable Witness[] kWitnesses = [
    Witness("kernel_solve_reads.json",
            import("fixtures/kernel_solve_reads.json"), "static-read"),
    Witness("morph_routing_laws.json",
            import("fixtures/morph_routing_laws.json"), "static-read"),
    Witness("stat_predicates_read.json",
            import("fixtures/stat_predicates_read.json"), "static-read"),
    Witness("action_center_freeze_and_source_baseline.json",
            import("fixtures/action_center_freeze_and_source_baseline.json"), "debug-live"),
    Witness("gesture_zero_delta_undo.json",
            import("fixtures/gesture_zero_delta_undo.json"), "gui-gesture"),
];

/// A fixture carrying an INCUMBENT value, so flow A cannot be satisfied by a
/// `requireProvenance` that stopped checking anything at all.
private enum string kIncumbent = import("fixtures/softrotate.json");

private JSONValue provOf(string json) { return parseJSON(json)["provenance"]; }

/// `requireProvenance` refuses with `assert`, so its failure is an `Error`,
/// not an `Exception` — `std.exception.collectExceptionMsg` does NOT see it
/// and every "it refused" row would have passed by never running. Measured the
/// hard way on the first run of this file. Returns the refusal text, or null
/// when the call was accepted.
private string refusal(string json, string name) {
    try { requireProvenance(parseJSON(json), name); }
    catch (Throwable t) { return t.msg; }
    return null;
}

// ---------------------------------------------------------------------------
// A. THE GREEN SIDE, AND IT IS THE HALF THAT IS EASY TO FORGET. A valid
//    fixture carrying one of the three late-added values must PASS. Before
//    task 3340 every row here failed.
// ---------------------------------------------------------------------------
void flowA() {
    scenario("A: a fixture carrying a late-added method passes requireProvenance");

    foreach (w; kWitnesses) {
        // The fixture really carries the value this row exists to witness.
        // Without this, a re-provenanced fixture would silently turn the row
        // into a second test of `command` and stop witnessing anything.
        auto prov = provOf(w.json);
        assert("method" in prov && prov["method"].str == w.wantMethod,
            format("%s no longer carries provenance.method %s (it has %s). This "
                 ~ "row then witnesses nothing about backlog 3302 — re-point it "
                 ~ "at a fixture that does carry %s, or say in the header that "
                 ~ "the value has left the corpus.",
                   w.name, w.wantMethod,
                   "method" in prov ? prov["method"].toString : "<missing>",
                   w.wantMethod));

        // THE ROW ITSELF: the shipped function, on the shipped fixture.
        immutable msg = refusal(w.json, w.name);
        assert(msg is null,
            format("requireProvenance REFUSED the valid fixture %s, whose "
                 ~ "provenance.method is %s:\n  %s\nThat is backlog 3302: a "
                 ~ "runner-side vocabulary shorter than the one the corpus is "
                 ~ "written against, reddening on a measured value and advising "
                 ~ "that it be erased. Add the value to "
                 ~ "kProvenanceMethodValues in tests/fixture_helpers.d AND to "
                 ~ "tools/local/fixture_gen/provenance.py.",
                   w.name, w.wantMethod, msg));
    }

    // Control: an INCUMBENT value still passes too. If it did not, the rows
    // above would be measuring a broken helper rather than a caught-up list.
    immutable ctl = refusal(kIncumbent, "softrotate.json");
    assert(ctl is null,
        "CONTROL: requireProvenance refused a fixture carrying an INCUMBENT "
      ~ "method value: " ~ ctl);

    // The size floor comes LAST, on purpose. It is a belt for a shrink that
    // no fixture happens to witness; put FIRST it would pre-empt the rows
    // above and answer "the list got shorter" where they answer "THIS fixture,
    // carrying THIS value, was refused" — measured, on the M-C1 mutation.
    assert(kProvenanceMethodValues.length >= 11,
        format("the shared vocabulary has %d value(s); it had 11 when this "
             ~ "cell was written, and every one of the 11 is in live use in "
             ~ "tests/fixtures/**. A shrinking list is how backlog 3302 "
             ~ "happened.", kProvenanceMethodValues.length));

    writefln("  A: %d fixture(s) with a late-added method + 1 incumbent accepted",
             kWitnesses.length);
}

// ---------------------------------------------------------------------------
// B. THE RED SIDE — anti-vacuity. A vocabulary that accepts everything would
//    pass flow A perfectly, so the refusal has to be witnessed too, and the
//    ADVICE it gives has to be the corrected one.
// ---------------------------------------------------------------------------
void flowB() {
    scenario("B: a value outside the vocabulary is still refused, with both fixes named");

    static string withMethod(string m) {
        return `{"name":"probe","provenance":{"schema":1,`
             ~ `"source":"analytic","reference":"analytic",`
             ~ `"method":"` ~ m ~ `","captured_utc":"unknown"}}`;
    }

    immutable bogus = refusal(withMethod("guessed-from-the-diff"), "probe");
    assert(bogus !is null,
        "requireProvenance ACCEPTED `guessed-from-the-diff` as a provenance "
      ~ "method. The vocabulary check is inert, and flow A's greens then mean "
      ~ "nothing — a check that refuses nothing is satisfied by every fixture");
    assert(bogus.indexOf("guessed-from-the-diff") >= 0,
        "the refusal did not name the offending value:\n  " ~ bogus);

    // The advice is the load-bearing part of backlog 3302: the OLD text said
    // only "write \"unknown\"", which on a real-but-late value destroys a
    // measured distinction. Both fixes must be on offer.
    assert(bogus.indexOf("fixture_helpers.d") >= 0
        && bogus.indexOf("provenance.py") >= 0,
        "the refusal still offers only `\"unknown\"` and does not name the two "
      ~ "files a genuinely NEW measured method must be added to. That advice is "
      ~ "actively harmful on the second of the two faults — it erases the "
      ~ "distinction the capture was made for:\n  " ~ bogus);

    // A missing field is a different fault and must also refuse.
    immutable missing = refusal(
        `{"name":"probe","provenance":{"schema":1,"source":"analytic",`
      ~ `"reference":"analytic","captured_utc":"unknown"}}`, "probe");
    assert(missing !is null && missing.indexOf("method") >= 0,
        "a provenance block with NO `method` was accepted (or refused without "
      ~ "naming the field): " ~ (missing is null ? "<accepted>" : missing));

    // And a fixture with no block at all — the task 0366 rule this helper was
    // originally written for, kept live so a rewrite cannot drop it.
    immutable none = refusal(`{"name":"probe"}`, "probe");
    assert(none !is null,
        "a fixture with NO provenance block was accepted — task 0366's rule is "
      ~ "gone");

    writeln("  B: bogus value, missing field and missing block all refused");
}

void main() {
    flowA();
    flowB();
    writeln("PASS test_provenance_vocabulary");
}
