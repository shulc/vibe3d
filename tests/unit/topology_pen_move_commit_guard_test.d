module tests.unit.topology_pen_move_commit_guard_test;

// Task 8660 made the Topology Pen's Move commit guard ONE helper,
// `moveWouldRecord`, read by the release record, the prepared tool-switch record
// and the session hook. Plan 8646 (task 8730) removed every one of those: each
// press is one step the SESSION records whatever it changed (law L5), so there
// is no "would this drag record" question left to share. This census pins that
// the old judgment did not survive in a corner — no net-move helper, epsilon or
// per-drag record in tool.d, the hook reads the press image and nothing else,
// and the prepared switch prepares no history of its own. The behaviour is
// witnessed by tests/test_topopen_live_move_discard.d and the pen's bound rigs
// in tests/unit/tools/edit/topology_pen/gestures_test.d.

import tests.unit.census_symbols : balancedSpan, blankNonCode, countOccurrences;
import std.conv : to;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;

private string toolCode() {
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    return blankNonCode(readText(buildPath(root,
        "source", "tools", "edit", "topology_pen", "tool.d")));
}

// The body of the member declared by `head` (its text up to the name).
private string bodyOf(string code, string head) {
    const at = code.indexOf(head);
    assert(at >= 0, "census: `" ~ head ~ "` is not declared in tool.d");
    const open = code.indexOf('{', at);
    assert(open > at, "census: `" ~ head ~ "` has no body");
    return balancedSpan(code, open, '{', '}');
}

unittest {
    immutable code = toolCode();
    foreach (gone; ["moveWouldRecord", "kNetEps", "recordLiveMove", "commitLiveMoveIfDirty",
                    "recordSnapshotUndo", "moveBefore_"])
        assert(countOccurrences(code, gone) == 0,
            "census: `" ~ gone ~ "` is back in tool.d — every pen press is the session's "
            ~ "one step (plan 8646); a per-gesture record judgment must not return");
    immutable hook = bodyOf(code, "bool hasUncommittedEdit() const");
    assert(countOccurrences(hook, "basis_.matches(") == 1
        && countOccurrences(hook, "stepOpen_") == 1
        && countOccurrences(hook, "moveBase_[") == 0,
        "census: the hook must be `an open press whose mesh left its press image`");
    immutable prepared = bodyOf(code,
        "PreparedTopologyPenDeactivateImage buildPreparedDeactivate(");
    assert(countOccurrences(prepared, "context.prepare(") == 0,
        "census: the prepared switch must prepare no history: the session's close "
        ~ "records an open press before the door");
    assert(countOccurrences(prepared, "setSnapshots(") == 0,
        "census: the prepared switch must build no Move record of its own");
    // Population: the scanned bodies are non-empty.
    assert(hook.length > 20 && prepared.length > 20,
        "census: a scanned body is empty (" ~ hook.length.to!string ~ ", "
        ~ prepared.length.to!string ~ ")");
}
