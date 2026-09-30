module tests.unit.topology_pen_move_commit_guard_test;

// Task 8660: the Topology Pen's Move commit guard is ONE helper,
// `moveWouldRecord`, and every site that judges "would this drag record"
// reads it: the release record, the prepared tool-switch record and the
// session hook, whose base contract (tool.d, above `hasUncommittedEdit`) is to
// equal the real commit guard including its epsilon. The behaviour of each
// caller is witnessed by tests/test_topopen_live_move_discard.d cells 4-7;
// this census pins the SHARING, which no behaviour can see — an inline copy
// in one caller agrees with the helper until one of the two is edited.

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
    // The helper exists and holds the epsilon term: kNetEps is declared once
    // and read once, inside the helper.
    immutable helper = bodyOf(code, "bool moveWouldRecord() const");
    assert(countOccurrences(code, "kNetEps") == 2,
        "census: kNetEps must be declared once and read once, got "
        ~ countOccurrences(code, "kNetEps").to!string);
    assert(countOccurrences(helper, "> kNetEps") == 1,
        "census: the net epsilon term must live in moveWouldRecord");

    static immutable string[3] callers = [
        "bool hasUncommittedEdit() const",
        "void recordLiveMove()",
        "PreparedTopologyPenDeactivateImage buildPreparedDeactivate(",
    ];
    foreach (head; callers) {
        immutable b = bodyOf(code, head);
        assert(countOccurrences(b, "moveWouldRecord()") == 1,
            "census: `" ~ head ~ "` must judge the Move commit through "
            ~ "moveWouldRecord()");
        assert(countOccurrences(b, "moveBase_[") == 0,
            "census: `" ~ head ~ "` must not carry its own net-move loop");
    }
    // Population: exactly these three callers read the helper.
    assert(countOccurrences(code, "moveWouldRecord()") == 4,
        "census: moveWouldRecord() has one declaration and three callers, got "
        ~ countOccurrences(code, "moveWouldRecord()").to!string);
}
