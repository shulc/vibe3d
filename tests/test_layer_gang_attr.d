// Task 1880 — `layer.attr` writes one absolute value to a LIST of items, as
// ONE undo entry, and an undo puts each of them back to ITS OWN prior value.
//
// ---------------------------------------------------------------------------
// The assertion that would be worth nothing here
// ---------------------------------------------------------------------------
// "after a gang write the targets hold the new value" is satisfied by an
// implementation that writes the value to EVERY layer in the document, and by
// one that writes it to the active layer N times. Both look right in a
// screenshot of a fully-selected scene. So the rig always keeps a layer OUT of
// the gang and asserts its value is untouched, in the same breath as the two
// that changed.
//
// The undo half has a sharper trap. The whole reason a gang write exists is
// that the items DISAGREED beforehand — that is what puts the placeholder in
// the field. So an undo that replays one restore value across the gang looks
// perfectly correct on a rig where they started equal, and silently flattens
// them on any rig where they did not. Every layer here starts at a DIFFERENT
// value for exactly that reason.
//
// ---------------------------------------------------------------------------
// Why the list is quoted on the wire
// ---------------------------------------------------------------------------
// `layer.attr "0,2" pos.x 9.5`, not `layer.attr 0,2 …`: the argstring
// tokenizer treats a bare comma as significant and refuses the line. The forms
// engine already quotes any token containing one (`forms.quoteIfNeeded`), so
// the panel's own dispatch needs no special case — but a test writing the line
// by hand does, and G0 below asserts the unquoted form is REFUSED rather than
// silently landing on the active layer alone.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — run one at a time (druntime stops a module at its
// first failed assert).
// ---------------------------------------------------------------------------
//   * the gang loop dropped, so only the first target is written
//       -> W1 "every target of the gang takes the value — layer 2 is 3.000".
//   * `revert` replays ONE prior value across the gang instead of each
//     target's own
//       -> W2 "an undo must put each target back to ITS OWN prior — layer 2
//          came back as 1.000, not 3.000".
//   * `resolveTargets` skips an unparseable token instead of refusing
//       -> W3 "a target that names no layer must REFUSE the whole write".
//   * the comma check in the injector removed, so `to!int` throws and the
//     catch leaves index at -1 (the active layer)
//       -> W1 again, and it is the reason that check is written before the
//          parse rather than after it.
//   * `compareOp` compares only the first target, so two writes covering
//     different sets coalesce into one entry
//       -> W5 "two gang writes over DIFFERENT sets are two undo entries".

import http_client : getJson, testBaseUrl;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : abs;

void main() {}

alias BASE = testBaseUrl;

private JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

private string cmdRefused(string argstring, string what) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "error",
        format("%s: `%s` reported %s. Landing quietly on some other layer is "
               ~ "the failure this refusal exists to prevent.",
               what, argstring, j["status"].str));
    return j["message"].str;
}

/// Every layer's `pos.x`, in document order.
private double[] posX() {
    double[] xs;
    foreach (l; getJson("/api/layers")["layers"].array)
        xs ~= l["xform"]["pos"].array[0].get!double;
    return xs;
}

private string show(double[] xs) {
    string s = "[";
    foreach (i, x; xs) { if (i) s ~= ", "; s ~= format("%.3f", x); }
    return s ~ "]";
}

private void assertPos(double[] want, string what) {
    auto got = posX();
    assert(got.length == want.length, format("%s — layer count %d, want %d",
                                             what, got.length, want.length));
    foreach (i, w; want)
        assert(abs(got[i] - w) < 1e-4,
            format("%s — got %s, want %s", what, show(got), show(want)));
}

/// THREE layers at THREE DIFFERENT values. Both parts are load-bearing: three
/// so one can stay outside the gang, different so an undo that flattens them is
/// visible rather than a no-op.
private void rig() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd("layer.add");
    cmd("layer.add");
    cmd("layer.attr 0 pos.x 1.0");
    cmd("layer.attr 1 pos.x 2.0");
    cmd("layer.attr 2 pos.x 3.0");
    cmd("history.clear");
    assertPos([1.0, 2.0, 3.0], "rig premise: three layers at three DIFFERENT "
        ~ "values — equal starts would make a flattening undo invisible");
}

// ===========================================================================

unittest {  // W0 — the wire form: a bare comma is refused, a quoted list is not
    rig();
    cmdRefused("layer.attr 0,2 pos.x 9.5",
        "an UNQUOTED list is not a legal argstring token");
    assertPos([1.0, 2.0, 3.0],
        "and a refused line must not have written anything");
    cmd(`layer.attr "0,2" pos.x 9.5`);
}

unittest {  // W1 — the write lands on the gang, and ONLY on the gang
    rig();
    cmd(`layer.attr "0,2" pos.x 9.5`);
    assertPos([9.5, 2.0, 9.5],
        "every target of the gang takes the value and the layer OUTSIDE it "
        ~ "keeps its own — a write that hit every layer answers "
        ~ "[9.5, 9.5, 9.5], and one that hit only the first answers "
        ~ "[9.5, 2.0, 3.000]");
}

unittest {  // W2 — undo restores each target to ITS OWN prior value
    rig();
    cmd(`layer.attr "0,2" pos.x 9.5`);
    assertPos([9.5, 2.0, 9.5], "precondition for the undo");
    cmd("history.undo");
    assertPos([1.0, 2.0, 3.0],
        "an undo must put each target back to ITS OWN prior. Replaying one "
        ~ "restore value across the gang answers [1, 2, 1] — and would look "
        ~ "perfectly correct on a rig whose layers started equal, which is why "
        ~ "this one's do not");
}

unittest {  // W3 — a target that names no layer refuses the WHOLE write
    rig();
    auto msg = cmdRefused(`layer.attr "0,99" pos.x 7.0`,
        "a target that names no layer");
    assert(msg.length > 0, "the refusal must carry a reason");
    assertPos([1.0, 2.0, 3.0],
        "and refuse ATOMICALLY: layer 0 must not keep a half-applied write. A "
        ~ "gang that silently skips the bad token lands on fewer items than "
        ~ "the user selected and says nothing about it");
}

unittest {  // W4 — a single index still behaves exactly as before
    rig();
    cmd("layer.attr 1 pos.x 7.0");
    assertPos([1.0, 7.0, 3.0],
        "a one-index call is a one-element gang, unchanged from before 1880");
    cmd("history.undo");
    assertPos([1.0, 2.0, 3.0], "and undoes the same way");
}

unittest {  // W5 — one entry per gang write, and different sets do not coalesce
    rig();
    immutable before = cast(int) getJson("/api/history")["undo"].array.length;
    cmd(`layer.attr "0,2" pos.x 9.5`);
    immutable afterOne = cast(int) getJson("/api/history")["undo"].array.length;
    assert(afterOne - before == 1,
        format("a gang write over two layers is ONE undo entry — the stack "
               ~ "grew by %d", afterOne - before));

    cmd(`layer.attr "0,1" pos.x 4.0`);
    immutable afterTwo = cast(int) getJson("/api/history")["undo"].array.length;
    assert(afterTwo - afterOne == 1,
        format("two gang writes over DIFFERENT sets are two entries, not one "
               ~ "coalesced — the stack grew by %d. Folding them would leave "
               ~ "layer 2, which only the FIRST write touched, holding a value "
               ~ "no remaining entry remembers", afterTwo - afterOne));

    cmd("history.undo");
    assertPos([9.5, 2.0, 9.5],
        "undoing the second write returns to the first write's state");
    cmd("history.undo");
    assertPos([1.0, 2.0, 3.0], "and undoing the first returns to the rig");
}

unittest {  // W6 — the same index twice is one target, not two
    // A repeated index would snapshot its own POST-write value as the second
    // prior, and the undo would then restore the new value over the old one —
    // an undo that changes nothing, which is the hardest kind to notice.
    rig();
    cmd(`layer.attr "0,0,2" pos.x 9.5`);
    assertPos([9.5, 2.0, 9.5], "the duplicate writes the same value");
    cmd("history.undo");
    assertPos([1.0, 2.0, 3.0],
        "and the duplicate must not corrupt the undo: a second snapshot of "
        ~ "layer 0 taken AFTER its own write restores 9.5, leaving the undo a "
        ~ "silent no-op for that layer");
}
