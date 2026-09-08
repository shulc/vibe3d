// Input-bank ownership census (task 4700). The live factory witness remains
// in transform_history_ownership_census_test; this source projection closes
// the other half: a bank cannot regain a private edit/history branch while
// staying deliberately unbound at runtime.
module tests.unit.transform_input_bank_census_test;

import std.conv : to;
import std.file : readText;
import std.path : buildPath, dirName;
import tests.unit.census_symbols : blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest // migrated input banks contain no edit/history lifecycle branch
{
    enum migratedBanks = ["move", "rotate", "scale"];
    enum forbidden = [
        "wrapperRef", "beginStandaloneEdit", "beginEdit(", "commitEdit(",
        "cancelEdit(", "editIsOpen(", "prepareEditRecord(",
        "prepareDeactivate(", "snapshotEditState", "MeshSnapshot",
    ];

    // Population before predicate: each completed bank slice is named exactly
    // once, and every named source must contain a real class body.
    assert(migratedBanks.length == 3,
        "transform input-bank census: expected 3 migrated banks after S slice");
    size_t scanned;
    foreach (bank; migratedBanks) {
        const code = blankNonCode(readText(buildPath(repoRoot, "source", "tools",
            "transform", bank ~ ".d")));
        assert(code.length > 1_000,
            "transform input-bank census: empty source projection for " ~ bank);
        size_t lifecycleHits;
        string firstTerm;
        foreach (term; forbidden) {
            const n = countOccurrences(code, term);
            if (n != 0 && firstTerm.length == 0) firstTerm = term;
            lifecycleHits += n;
        }
        assert(lifecycleHits == 0,
            "transform input-bank census: " ~ bank ~
            " regained edit/history lifecycle via " ~ firstTerm ~ " (hits=" ~
            lifecycleHits.to!string ~ ")");
        ++scanned;
    }
    assert(scanned == 3,
        "transform input-bank census: T/R/S population was not traversed");
}
