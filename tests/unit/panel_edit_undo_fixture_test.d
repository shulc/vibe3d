/// tests/unit/panel_edit_undo_fixture_test.d — task 4290.
///
/// The APP-FREE half of the panel-edit capture. Its sibling
/// `tests/test_arm_record_fixture_divergence.d` drives vibe3d over HTTP and
/// compares the observed trajectory; this file checks the things that can be
/// wrong in the FIXTURE ITSELF, in the lane that needs no running editor, so
/// the two routine gates each carry one reader and neither needs the
/// reference.
///
/// WHAT CAN BE WRONG HERE, and why each check exists rather than being
/// obvious. Every one of these failures leaves the suite reader GREEN, which
/// is the shape this project pays for most:
///
///   * the two sides record DIFFERENT trajectories after the law is closed —
///     the fixture then claims parity while its recorded local side still
///     describes the defect;
///   * `r0` and `r40` carry the same literal on some side — every trajectory
///     comparison is then satisfied by every candidate, VACUOUSLY;
///   * the `edit` row equals the `armed` row — a zero-valued edit, and a
///     zero-valued edit is undone correctly by a defect too;
///   * a row names a symbol its side's table does not hold — the suite reader
///     would refuse, but only on a host that can run the app;
///   * the rival named in `rival_mutation` is already the recorded value, so
///     the mutation harness mutates nothing and the rival is INERT.
module panel_edit_undo_fixture_test;

version (unittest):

import std.algorithm : count, filter, map;
import std.array     : array;
import std.file      : readText;
import std.format    : format;
import std.json      : JSONValue, parseJSON;

private enum string kFixture = "tests/fixtures/tool_arm_undo_trajectory.json";

/// The two laws this file owns, with the row index and the value the
/// `rival_mutation` string promises to write there. Keeping the pair here —
/// rather than only in the suite reader's `rival()` switch — is what lets this
/// lane prove the rival is LIVE without an app.
private struct LawSpec { string id; size_t rivalRow; string rivalValue; size_t doorRows; }
/// ONE law, deliberately. A second law ("the edit is revertable while the tool
/// is still armed") was measured and WITHDRAWN before it shipped: its reference
/// row came only from the headless channel, and that channel's DROP-door
/// reading was then shown to be a channel artefact by a live run. The press
/// index is exactly the quantity that moved, so freezing it would have frozen
/// the artefact. Task 4520 owns it.
private enum LawSpec[] kLaws = [
    LawSpec("panel_edit_owns_its_undo_step", 3, "r0", 1),
];

private JSONValue law(JSONValue fx, string id) {
    foreach (v; fx["laws"].array)
        if (v["id"].str == id)
            return v;
    assert(0, id ~ ": missing from " ~ kFixture);
}

private string[] symbolsOf(JSONValue rows) {
    string[] out_;
    foreach (r; rows.array)
        out_ ~= r["item_rot"].str;
    return out_;
}

unittest {
    auto fx = parseJSON(readText(kFixture));

    // POPULATION FLOOR for the file as a whole: a census that is true over
    // nothing is not a census. If a rename drops both laws, every loop below
    // iterates zero times and passes.
    assert(kLaws.length == 1, "the spec table itself lost a law");
    size_t seen;

    foreach (spec; kLaws) {
        auto l = law(fx, spec.id);
        ++seen;
        assert(l["status"].str == "closed",
            format("%s: status is %s — card 4300 closed this law, so both readers "
                ~ "must compare the driven trajectory with the reference side",
                spec.id, l["status"].str));

        auto refRows = l["reference"];
        auto ourRows = l["vibe3d_current"];
        assert(refRows.array.length >= 3, spec.id ~ ": reference trajectory too short to discriminate");
        assert(refRows.array.length == ourRows.array.length, spec.id ~ ": the two sides record different row counts");

        // --- the symbol tables must SEPARATE, per side ---------------------
        foreach (side; ["reference", "vibe3d"]) {
            auto tbl = l["symbols"][side];
            assert("r0" in tbl.object && "r40" in tbl.object, format("%s %s: missing a symbol", spec.id, side));
            assert(tbl["r0"] != tbl["r40"],
                format("%s %s: r0 and r40 carry the SAME literal (%s) — every trajectory "
                    ~ "comparison in this fixture is then vacuously satisfied",
                    spec.id, side, tbl["r0"].toString));
        }

        // --- every row resolves, on its own side ---------------------------
        foreach (pair; [["reference", "reference"], ["vibe3d_current", "vibe3d"]]) {
            auto rows = l[pair[0]];
            auto tbl  = l["symbols"][pair[1]];
            foreach (r; rows.array) {
                auto tok = r["item_rot"].str;
                assert(tok in tbl.object,
                    format("%s %s %s: names symbol %s, which its side's table does not hold",
                        spec.id, r["at"].str, pair[1], tok));
                assert(r["item_rot_literal"] == tbl[tok],
                    format("%s %s %s: literal %s does not match symbol %s (%s)",
                        spec.id, r["at"].str, pair[1], r["item_rot_literal"].toString,
                        tok, tbl[tok].toString));
            }
        }

        // --- the cell is not DEGENERATE: the edit actually moved something --
        foreach (rows; [refRows, ourRows]) {
            auto syms = symbolsOf(rows);
            assert(rows.array[0]["at"].str == "armed" && rows.array[1]["at"].str == "edit",
                spec.id ~ ": the first two rows must be armed then edit");
            assert(syms[0] != syms[1],
                spec.id ~ ": the `edit` row equals the `armed` row — a ZERO-VALUED edit, "
                ~ "and a zero-valued edit is undone correctly by a defect too");
        }

        // --- population floor on the cell's own acts -----------------------
        assert(refRows.array.count!(r => r["at"].str == "edit") == 1, spec.id ~ ": not exactly one edit row");
        assert(refRows.array.count!(r => r["at"].str == "door") == spec.doorRows,
            format("%s: expected %d door rows", spec.id, spec.doorRows));

        // --- the closed fixture must record the same symbolic law -----------
        assert(symbolsOf(refRows) == symbolsOf(ourRows),
            spec.id ~ ": the law is `closed` but reference and vibe3d_current "
            ~ "still record different rotation trajectories");

        // --- the rival the suite reader applies must be LIVE ----------------
        assert(spec.rivalRow < refRows.array.length, spec.id ~ ": rival row out of range");
        assert(refRows.array[spec.rivalRow]["item_rot"].str != spec.rivalValue,
            format("%s: the rival writes %s into row %d, which ALREADY holds it — the "
                ~ "mutation harness would mutate nothing and the rival is INERT",
                spec.id, spec.rivalValue, spec.rivalRow));
    }

    assert(seen == kLaws.length, format("only %d of %d laws were checked", seen, kLaws.length));
}
