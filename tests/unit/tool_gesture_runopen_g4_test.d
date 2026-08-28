// tool_gesture_runopen_g4_test — task 1905, lane G0-G4: the `runOpen` witness
// the HTTP plane fixture cannot be, for group G4.
//
// WHAT IT PINS. All ELEVEN G4 record sites write through `CommandHistory.record`
// — the primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
// open run and leaves `_runOpen` false; `recordInSession` OPENS one and leaves
// it true. The two are one token apart at the call site, and swapping them
// changes the SHAPE of the history without changing anything a user or an HTTP
// client can see through the surfaces `tests/test_tool_gesture_g4.d` reads.
//
// WHY IT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface, so no fixture driven over the wire can read
// it. And the consequences that DO reach the wire do not separate the two
// branches: `record` and `recordInSession` both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why the row's "must stay green"
// column is `undoDelta` and every plane. Block 1 below re-derives that claim on
// a live `CommandHistory` instead of quoting it.
//
// WHY THE CELL IS A SOURCE CENSUS AND NOT A DRIVEN COMMIT — measured, and it is
// a real difference from the sibling lane G0-G1. There, the create family's
// commit body (`PrimitiveCreateTool.commitEdit`) is `protected`, so a derived
// probe class could call it. In G4 every one of the eight `commitEdit()` bodies
// sits after a `private:` label (`edge_bevel.d:322`, `poly_bevel.d`,
// `poly_extrude.d`, `poly_inset_tool.d`, `vertex_bevel_tool.d`,
// `vertex_extrude_tool.d`, `vert_merge_tool.d:248`, `reduce.d:168`), and D's
// `private` is MODULE-scope: no test module and no derived class in another
// module can call them. The remaining three sites are a `private`
// `commitBridgeEdit`, a `private` `commitTackEdit`, and a record INLINED in
// `DragWeldTool.onMouseButtonUp`. Driving them would mean reaching each tool's
// kernel through its own private preview state — i.e. re-building the suite
// fixture in a unit test. So this file pins the PRIMITIVE at all eleven sites
// by reading them, and Block 1 supplies the behavioural half the reading cannot:
// that `record` and `recordInSession` really do differ in `runOpen()`, and
// really do agree on the stack depth.
//
// THE MUTATION THIS FILE ANSWERS TO:
//     any of the eleven files below, at its single history call:
//         history.record(cmd);
//     ->  history.recordInSession(cmd, history.currentRunId);
// Expected: Block 2 reddens naming that file and the offending name; Block 1
// stays green; `tests/test_tool_gesture_g4.d` stays green on every plane, on
// `undoDelta` and on both residuals.
//
// SCOPE, NAMED RATHER THAN IMPLIED. This is a NARROW pin — which primitive each
// G4 record site uses — not plan §5.1's per-family call-surface census
// (`tool_commit_seam_census_g4_test.d`), which keys on the whole multiset with
// per-file counts and a reason beside every legal non-recorder. When that file
// lands it supersedes Block 2; Block 1 is independent of it.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g4_test;

import std.conv    : to;
import std.file    : readText, exists;
import std.path    : buildPath, dirName;
import std.regex   : regex, matchAll, replaceAll;

import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope;
import snapshot : MeshSnapshot;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// G4's eleven record sites, one per file — the membership plan §6 gives the
/// group (the eight `edit` tools plus Bridge, DragWeld and Tack). The twins
/// `edge_extend` / `edge_extrude` are deliberately ABSENT: they belong to G1.
private enum string[] kG4Files = [
    "edge_bevel.d", "poly_bevel.d", "poly_extrude.d", "poly_inset_tool.d",
    "vertex_bevel_tool.d", "vertex_extrude_tool.d", "vert_merge_tool.d",
    "reduce.d", "bridge_tool.d", "drag_weld.d", "tack.d",
];

private Mesh makeQuad() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1));
    m.addVertex(Vec3(0, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// 1. POSITIVE CONTROL, and it is load-bearing twice over.
//
//    (a) Block 2 asserts every G4 site spells `record`. That is worth nothing
//        unless `record` and `recordInSession` actually differ in a way no
//        wire surface shows — so drive BOTH here, on one live history, and
//        require `runOpen()` to answer differently.
//    (b) A `runOpen()` that could never answer `true` — an accessor over a
//        field nobody sets — would make the whole row vacuous. The
//        `recordInSession` arm below is what forbids that.
//
//    The depth assertions sit beside them deliberately: depth is the field
//    plan §5.4's row predicts stays GREEN under the mutation, and having both
//    in one block is what lets a mutation run read the green half off the same
//    output as the red one.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeQuad();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();

    assert(!h.runOpen(),
        "control: a fresh CommandHistory reports an OPEN run — the accessor is "
      ~ "not reading the flag this file pins");

    MeshSessionEdit mk(string label) {
        auto cmd = new MeshSessionEdit(&m, v, EditMode.Polygons,
                                       "probe.session_edit", label,
                                       MeshEditScope.Geometry);
        auto pre = MeshSnapshot.capture(m);
        m.addVertex(Vec3(2, 0, 0));
        auto post = MeshSnapshot.capture(m);
        cmd.setSnapshots(pre, post, label);
        return cmd;
    }

    // --- the primitive every G4 site is supposed to use.
    immutable size_t d0 = h.undoEntriesVisible().length;
    h.record(mk("Plain"));
    immutable size_t d1 = h.undoEntriesVisible().length;
    assert(d1 == d0 + 1,
        "control: `record` pushed " ~ (d1 - d0).to!string ~ " entr(ies), "
      ~ "expected exactly 1");
    assert(!h.runOpen(),
        "control: `record` left an OPEN run. Then Block 2's whole premise is "
      ~ "gone: the two primitives would be indistinguishable on the property "
      ~ "this file pins, and the census below would be pinning a spelling with "
      ~ "no consequence");

    // --- the primitive a one-token slip would substitute.
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G4 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}

// ---------------------------------------------------------------------------
// 2. THE CELL. Each of G4's eleven files reaches `CommandHistory` exactly once,
//    and through `record`.
//
//    ACCUMULATE-THEN-RAISE, so a mutation run reads every offender at once
//    rather than the alphabetically-first one (agent memory: a roster gate that
//    asserts inside the loop names only the first).
//
//    Comments and strings are stripped first: a census that reddens when
//    someone renames a symbol INSIDE A COMMENT teaches people to bump its
//    number without looking, and a number bumped without looking is not a
//    witness (plan §5.1, Б16).
// ---------------------------------------------------------------------------
private string stripComments(string src) {
    return src.replaceAll(regex(`/\*[\s\S]*?\*/`), "")
              .replaceAll(regex(`//[^\n]*`), "");
}

unittest {
    string[] bad;
    size_t   totalRecord = 0;

    foreach (f; kG4Files) {
        immutable path = buildPath(repoRoot, "source", "tools", "edit", f);
        assert(exists(path),
            "G4 census: `" ~ path ~ "` does not exist. The roster names a file "
          ~ "that moved or was renamed — fix the roster deliberately, because a "
          ~ "census over a file it cannot read proves nothing about the site it "
          ~ "was meant to pin");

        immutable src = stripComments(readText(path));
        size_t[string] surface;
        foreach (mt; src.matchAll(regex(`history_?\s*\.\s*(\w+)\s*\(`)))
            ++surface[mt[1]];

        immutable size_t rec = ("record" in surface) ? surface["record"] : 0;
        totalRecord += rec;

        if (rec != 1)
            bad ~= "    · " ~ f ~ ": " ~ rec.to!string ~ " call(s) to "
                 ~ "`history.record(`, expected exactly 1 — this file is one of "
                 ~ "G4's eleven record sites and a site that vanished has no "
                 ~ "witness anywhere else in the two lanes";

        foreach (name, n; surface) {
            if (name == "record") continue;
            bad ~= "    · " ~ f ~ ": history surface carries `" ~ name ~ "` × "
                 ~ n.to!string ~ ". Every G4 site's contract is `record`; "
                 ~ "`recordInSession` and `replaceInSessionTail` leave a run "
                 ~ "OPEN, so the next foreign record is CONSOLIDATED into this "
                 ~ "tool's run instead of standing as its own entry — and "
                 ~ "nothing on the HTTP surface (not the stack depth, not the "
                 ~ "wire names, not one plane of the mesh) says so. If this is "
                 ~ "deliberate, name it here with its reason";
        }
    }

    // The total goes into the SAME accumulator, never in front of it. A guard
    // that refuses first hides the findings behind it — and the per-file lines
    // are the ones that name the offending file AND the offending primitive,
    // which is the whole point of running the mutation (measured: as a separate
    // assert placed above, this line swallowed the `recordInSession` finding it
    // was supposed to accompany).
    if (totalRecord != kG4Files.length)
        bad ~= "    · TOTAL: " ~ totalRecord.to!string ~ " `history.record(` "
             ~ "site(s) over " ~ kG4Files.length.to!string ~ " files, expected "
             ~ "one each. A site added or removed changes what "
             ~ "`tests/test_tool_gesture_g4.d` is an oracle FOR, and must be "
             ~ "re-frozen deliberately";

    if (bad.length == 0) return;
    string msg = "G4 record-primitive census: " ~ bad.length.to!string
               ~ " finding(s) over `source/tools/edit/**`:\n";
    foreach (b; bad) msg ~= b ~ "\n";
    assert(false, msg);
}
