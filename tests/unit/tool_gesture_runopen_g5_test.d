// tool_gesture_runopen_g5_test — task 1905, lane G0-G5: the `runOpen` witness
// the HTTP plane fixture cannot be, for group G5 — and the NAMED census row
// that keeps this family's one legal non-recorder legible.
//
// WHAT IT PINS, and G5 is the group where that is two things rather than one.
//
//   (1) All THREE G5 record sites write through `CommandHistory.record` — the
//       primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
//       open run and leaves `_runOpen` false; `recordInSession` OPENS one and
//       leaves it true. The two are one token apart at the call site, and
//       swapping them changes the SHAPE of the history without changing
//       anything a user or an HTTP client can see through the surfaces
//       `tests/test_tool_gesture_g5.d` reads.
//
//   (2) `invalidateRedo` is called FOUR times in this family — three in
//       `edge_slice_tool.d` (`latchFirstPoint`, `armChain`, `rebuildPreview`),
//       one in `loop_slice_tool.d` (`rebuildCut`) — and it is DELIBERATE, the
//       task-0429 primitive: a standing preview writes into the real mesh
//       outside the history, so a redo stepping the stack under it would replay
//       onto a mesh nobody recorded. It STAYS, and it is carried here as a
//       roster row WITH ITS COUNT, per file. A bare "there are some
//       `invalidateRedo` calls in the slice family" is indistinguishable from
//       someone having added a fifth, or having deleted the fourth; a count per
//       file is not.
//
// WHY IT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface. And the consequences that DO reach the wire
// do not separate the two record primitives: both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why that row's "must stay green"
// column is `undoDelta` and every plane. Block 1 re-derives it on a live
// `CommandHistory` instead of quoting it.
//
// WHY THE CELL IS A SOURCE CENSUS AND NOT A DRIVEN COMMIT — measured, and the
// same answer the sibling lane G0-G4 reached. All three G5 commit bodies
// (`EdgeSliceTool.commitChain`, `LoopSliceTool.commitEdit`,
// `SliceTool.commitCurrentSlice`) sit after a `private:` label, and two of the
// three classes are `final` besides; D's `private` is MODULE-scope, so no test
// module and no derived class in another module can call them. Driving them
// would mean re-building the suite fixture in a unit test.
//
// WHAT THE COUNT ROW CANNOT DO, said plainly. It witnesses that the call
// EXISTS, not that it works. Block 1's second half supplies the behavioural
// half on a live history (`invalidateRedo` really empties a redo stack and
// really leaves the undo stack alone), and
// `tests/test_tool_gesture_g5.d`'s Block 2 supplies it at the earliest of the
// four SITES — the first interactive latch, which fires before the tool has
// written a vertex. The other three sites are not independently witnessable by
// behaviour: `armChain` has the shipped `tests/test_standing_preview_redo.d`
// scenario A' and `rebuildCut` its scenario A, while `rebuildPreview` cannot be
// isolated at all, because by the time any scrub runs the latch has already
// emptied the redo stack. That is why the SET is pinned by a count here.
//
// THE TWO MUTATIONS THIS FILE ANSWERS TO:
//     any of the three files, at its single history call:
//         history.record(cmd);  ->  history.recordInSession(cmd, history.currentRunId);
//     any of the four legal non-recorder calls:
//         if (history !is null) history.invalidateRedo();   ->  deleted
// Expected: Block 2 reddens naming the file, the primitive and both numbers;
// Block 1 stays green; the plane fixture stays green on every plane, on
// `undoDelta` and on both residuals for the first mutation, and (for the
// deletion of `latchFirstPoint`'s call) `tests/test_tool_gesture_g5.d`'s Block
// 2 reddens too.
//
// SCOPE, NAMED RATHER THAN IMPLIED. This is a NARROW pin — which primitives
// each G5 site uses, and how many times — not plan §5.1's per-family
// call-surface census (`tool_commit_seam_census_g5_test.d`), which keys on the
// whole multiset over the whole family with a reason beside every legal
// non-recorder. When that file lands it supersedes Block 2; Block 1 is
// independent of it.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g5_test;

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

/// One G5 file: its record count, and the ONE legal non-recorder it is allowed
/// to reach for, with the exact number of times.
private struct G5Site {
    string file;
    size_t record;
    string legalName;      // "" — this file may call nothing but `record`
    size_t legalCount;
    string reason;
}

/// G5's three record sites, one per file — the membership plan §6 gives the
/// group. `edge_slide.d` sits in the same directory and is NOT here: it is a
/// `CommandWrapperTool` and belongs to G6, and it reaches `CommandHistory` not
/// at all (measured: its history surface is empty).
private enum G5Site[] kG5Sites = [
    G5Site("edge_slice_tool.d", 1, "invalidateRedo", 3,
        "task 0429: latchFirstPoint (the session opens, before any mesh write), "
      ~ "armChain (the headless arm bakes directly) and rebuildPreview (every "
      ~ "other standing-preview write) each kill the redo timeline"),
    G5Site("loop_slice_tool.d", 1, "invalidateRedo", 1,
        "task 0429: rebuildCut is this tool's single standing-preview "
      ~ "write-point"),
    G5Site("slice_tool.d", 1, "", 0,
        "its preview never touches the history — the whole cut is re-run from "
      ~ "the session baseline and committed once at deactivate"),
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
// 1. POSITIVE CONTROL, and it is load-bearing three times over.
//
//    (a) Block 2 asserts all three G5 sites spell `record`. That is worth
//        nothing unless `record` and `recordInSession` actually differ in a way
//        no wire surface shows — so drive BOTH here, on one live history, and
//        require `runOpen()` to answer differently.
//    (b) A `runOpen()` that could never answer `true` — an accessor over a
//        field nobody sets — would make the whole row vacuous. The
//        `recordInSession` arm forbids that.
//    (c) Block 2 also carries a COUNT of `invalidateRedo`. A count row over a
//        primitive that does nothing would be a spelling gate, so the third
//        arm drives `invalidateRedo` on a live history and requires it to empty
//        the redo stack AND to leave the undo stack untouched.
//
//    The depth assertions sit beside them deliberately: depth is the field plan
//    §5.4's `runOpen` row predicts stays GREEN under the record-primitive
//    mutation, and having both in one block is what lets a mutation run read
//    the green half off the same output as the red one.
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

    // --- the primitive all three G5 sites are supposed to use.
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
      ~ "stack depth and every plane of the G5 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");

    // --- the LEGAL NON-RECORDER, on a live history: it must have a consequence
    //     or the count row in Block 2 is a spelling gate.
    auto h2 = new CommandHistory();
    h2.record(mk("ToUndo"));
    assert(!h2.canRedo(),
        "control: a history with nothing undone already reports canRedo — the "
      ~ "field cannot then witness an invalidation");
    assert(h2.undo(),
        "control: undo() refused the entry just recorded, so the redo timeline "
      ~ "this arm needs was never created");
    assert(h2.canRedo(),
        "control: after an undo the redo timeline is EMPTY. Then "
      ~ "`invalidateRedo()` has nothing to kill and the assertion below is "
      ~ "satisfied for free");
    immutable size_t undoDepthBefore = h2.undoEntriesVisible().length;
    h2.invalidateRedo();
    assert(!h2.canRedo(),
        "CONTROL: `invalidateRedo()` left the redo timeline ALIVE. The four "
      ~ "counted calls in Block 2 would then be a spelling with no "
      ~ "consequence, and the row would pin nothing");
    assert(h2.undoEntriesVisible().length == undoDepthBefore,
        "control: `invalidateRedo()` also moved the UNDO stack (from "
      ~ undoDepthBefore.to!string ~ " to "
      ~ h2.undoEntriesVisible().length.to!string ~ "). It is a redo-only "
      ~ "primitive; if that changed, every slice-family gesture silently loses "
      ~ "undo entries and the plane fixture's `undoDelta` is the wrong oracle");
}

// ---------------------------------------------------------------------------
// 2. THE CELL. Each of G5's three files reaches `CommandHistory` exactly once
//    through `record`, and reaches `invalidateRedo` exactly as many times as
//    its roster row says — no more (a fifth standing-preview write-point that
//    nobody argued for) and no fewer (a deliberate primitive quietly deleted).
//
//    ACCUMULATE-THEN-RAISE, so a mutation run reads every offender at once
//    rather than the alphabetically-first one (agent memory: a roster gate that
//    asserts inside the loop names only the first).
//
//    Comments and strings are stripped first: a census that reddens when
//    someone renames a symbol INSIDE A COMMENT teaches people to bump its
//    number without looking, and a number bumped without looking is not a
//    witness (plan §5.1, Б16). Measured here: `edge_slice_tool.d` and
//    `loop_slice_tool.d` both mention `history.undo()` in prose, and without
//    the strip this census would carry two phantom rows.
// ---------------------------------------------------------------------------
private string stripComments(string src) {
    return src.replaceAll(regex(`/\*[\s\S]*?\*/`), "")
              .replaceAll(regex(`//[^\n]*`), "");
}

unittest {
    string[] bad;
    size_t   totalRecord = 0;
    size_t   totalLegal  = 0;

    foreach (site; kG5Sites) {
        immutable path = buildPath(repoRoot, "source", "tools", "slice", site.file);
        assert(exists(path),
            "G5 census: `" ~ path ~ "` does not exist. The roster names a file "
          ~ "that moved or was renamed — fix the roster deliberately, because a "
          ~ "census over a file it cannot read proves nothing about the site it "
          ~ "was meant to pin");

        immutable src = stripComments(readText(path));
        size_t[string] surface;
        foreach (mt; src.matchAll(regex(`history_?\s*\.\s*(\w+)\s*\(`)))
            ++surface[mt[1]];

        immutable size_t rec = ("record" in surface) ? surface["record"] : 0;
        totalRecord += rec;
        if (rec != site.record)
            bad ~= "    · " ~ site.file ~ ": " ~ rec.to!string ~ " call(s) to "
                 ~ "`history.record(`, expected " ~ site.record.to!string
                 ~ " — this file is one of G5's three record sites and a site "
                 ~ "that vanished has no witness anywhere else in the two lanes";

        immutable size_t legal = (site.legalName.length && site.legalName in surface)
                               ? surface[site.legalName] : 0;
        totalLegal += legal;
        if (site.legalName.length && legal != site.legalCount)
            bad ~= "    · " ~ site.file ~ ": `" ~ site.legalName ~ "` × "
                 ~ legal.to!string ~ ", expected exactly "
                 ~ site.legalCount.to!string ~ ". This is a LEGAL "
                 ~ "non-recorder, not a defect — " ~ site.reason ~ ". It stays; "
                 ~ "what must not happen is the number moving without an "
                 ~ "argument. Fewer means a deliberate primitive was deleted "
                 ~ "(the redo timeline then survives a standing preview, and a "
                 ~ "redo replays onto a mesh nobody recorded); more means a new "
                 ~ "standing-preview write-point nobody named";

        foreach (name, n; surface) {
            if (name == "record") continue;
            if (site.legalName.length && name == site.legalName) continue;
            bad ~= "    · " ~ site.file ~ ": history surface carries `" ~ name
                 ~ "` × " ~ n.to!string ~ ", which this file's roster row does "
                 ~ "not allow. `recordInSession` and `replaceInSessionTail` "
                 ~ "leave a run OPEN, so the next foreign record is "
                 ~ "CONSOLIDATED into this tool's run instead of standing as "
                 ~ "its own entry — and nothing on the HTTP surface (not the "
                 ~ "stack depth, not the wire names, not one plane of the mesh) "
                 ~ "says so. If this is deliberate, give it a roster row with "
                 ~ "its count and its reason";
        }
    }

    // Both totals go into the SAME accumulator, never in front of it. A guard
    // that refuses first hides the findings behind it — and the per-file lines
    // are the ones that name the offending file AND the offending primitive,
    // which is the whole point of running the mutation (the sibling lane
    // measured exactly that: as a separate assert placed above, this line
    // swallowed the `recordInSession` finding it was supposed to accompany).
    if (totalRecord != kG5Sites.length)
        bad ~= "    · TOTAL: " ~ totalRecord.to!string ~ " `history.record(` "
             ~ "site(s) over " ~ kG5Sites.length.to!string ~ " files, expected "
             ~ "one each. A site added or removed changes what "
             ~ "`tests/test_tool_gesture_g5.d` is an oracle FOR, and must be "
             ~ "re-frozen deliberately";

    if (totalLegal != 4)
        bad ~= "    · TOTAL: " ~ totalLegal.to!string ~ " `invalidateRedo(` "
             ~ "call(s) across the slice family, expected exactly 4. This is "
             ~ "the ONE group of task 1905 holding a legitimate non-recorder "
             ~ "mutation of the history, and the whole point of counting it "
             ~ "by name is that a bare '4' is otherwise indistinguishable from "
             ~ "someone having added a fifth";

    if (bad.length == 0) return;
    string msg = "G5 record-primitive census: " ~ bad.length.to!string
               ~ " finding(s) over `source/tools/slice/**`:\n";
    foreach (b; bad) msg ~= b ~ "\n";
    assert(false, msg);
}
