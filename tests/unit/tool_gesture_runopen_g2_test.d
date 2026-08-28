// tool_gesture_runopen_g2_test — task 1905, lane G0-G2: the `runOpen` witness
// the HTTP plane fixture cannot be, for group G2.
//
// WHAT IT PINS. All FIVE G2 record sites write through `CommandHistory.record`
// — the primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
// open run and leaves `_runOpen` false; `recordInSession` OPENS one and leaves
// it true. The two are one token apart at the call site, and swapping them
// changes the SHAPE of the history without changing anything a user or an HTTP
// client can see through the surfaces `tests/test_tool_gesture_g2.d` reads.
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
// WHY THE CELL IS A DIRECTORY CENSUS AND NOT A DRIVEN COMMIT. Two reasons, and
// the first is the same one the G0-G4 lane measured: every G2 commit body is
// unreachable from a test module. `ArrayTool.commitEdit`, `CloneTool.commitEdit`
// and `RadialArrayTool.commitEdit` all sit after a `private:` label, and
// `MirrorTool.commitMirrorEdit` / `RadialSweepTool.commitSweepEdit` are
// explicitly `private` — and D's `private` is MODULE scope, so neither a test
// module nor a derived class in another module can call them. Driving them
// would mean rebuilding the suite fixture inside a unit test.
//
// The second reason is specific to this group and makes the census STRONGER
// than a roster of five files would be: G2 is a whole DIRECTORY,
// `source/tools/alignment/`, and the census walks it rather than naming its
// members. So a record site that MOVES to a neighbouring file in the same
// directory — including the two alignment tools that are out of this task's
// scope and hold zero sites today — is red for free, with the file named,
// instead of slipping out of a hand-written list.
//
// THE TWO OUT-OF-SCOPE NEIGHBOURS, named rather than silently skipped.
// `linear_align_tool.d` and `radial_align_tool.d` live in this directory and
// belong to the TRANSFORM zone (plan §6, "вне объёма — зона трансформа"): both
// derive from `TransformTool` and commit through its shared `recordCommit`
// funnel, so both hold ZERO history calls of their own. That zero is pinned
// here on purpose. If the T2 redesign gives either of them its own record site,
// this census goes red and the number has to be re-argued — which is the right
// outcome, because a sixth record site in G2's directory changes what
// `tests/test_tool_gesture_g2.d` is an oracle FOR.
//
// THE MUTATION THIS FILE ANSWERS TO:
//     any of the five tool files below, at its single history call:
//         history.record(cmd);
//     ->  history.recordInSession(cmd, history.currentRunId);
// Expected: Block 2 reddens naming that file and the offending name; Block 1
// stays green; `tests/test_tool_gesture_g2.d` stays green on every plane, on
// `undoDelta`, on both wire-name lists, on all four counter fields and on both
// residuals.
//
// SCOPE, NAMED RATHER THAN IMPLIED. This is a NARROW pin — which primitive each
// G2 record site uses, and that no sixth site exists in the directory — not
// plan §5.1's per-family call-surface census
// (`tool_commit_seam_census_g2_test.d`), which keys on the whole multiset with
// per-file counts and a reason beside every legal non-recorder. When that file
// lands it supersedes Block 2; Block 1 is independent of it.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g2_test;

import std.algorithm : sort;
import std.array     : array;
import std.conv      : to;
import std.file      : dirEntries, SpanMode, readText, exists, isDir;
import std.path      : baseName, buildPath, dirName, extension;
import std.regex     : regex, matchAll, replaceAll;

import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope;
import snapshot : MeshSnapshot;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The directory G2 IS. Walked, not enumerated — see the header.
private enum string kG2Dir = "source/tools/alignment";

/// The five record sites, each expected to spell `record` exactly once. The
/// membership plan §6 gives the group: Array, Clone, RadialArray, Mirror,
/// RadialSweep.
private enum string[] kRecorders = [
    "array_tool.d", "clone_tool.d", "mirror.d",
    "radial_array_tool.d", "radial_sweep_tool.d",
];

/// The rest of the directory, expected to reach `CommandHistory` ZERO times,
/// each with the reason it does not.
private enum string[2][] kSilent = [
    ["align_kernels.d",
     "pure kernels — no Tool, no history binding"],
    ["linear_align_tool.d",
     "TRANSFORM ZONE (plan §6, out of this task's scope): a TransformTool "
     ~ "subclass that commits through the shared TransformTool.recordCommit "
     ~ "funnel in source/tools/transform/transform.d"],
    ["radial_align_tool.d",
     "TRANSFORM ZONE (plan §6, out of this task's scope): same funnel as "
     ~ "linear_align_tool.d"],
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
//    (a) Block 2 asserts every G2 site spells `record`. That is worth nothing
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

    // --- the primitive every G2 site is supposed to use.
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
      ~ "stack depth and every plane of the G2 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}

// ---------------------------------------------------------------------------
// 2. THE CELL. Every `.d` file in `source/tools/alignment/` reaches
//    `CommandHistory` exactly as the roster says: five files once each, through
//    `record`, and the remaining three not at all.
//
//    ACCUMULATE-THEN-RAISE, so a mutation run reads every offender at once
//    rather than the alphabetically-first one (agent memory: a roster gate that
//    asserts inside the loop names only the first). The TOTAL goes into the
//    SAME accumulator and never in front of it — measured on the sibling lane:
//    as a separate assert placed above, the total swallowed the very finding it
//    was supposed to accompany, which is CLAUDE.md's "a second, unnamed guard
//    refuses first" inside a witness meant to catch exactly that.
//
//    Comments are stripped first: a census that reddens when someone renames a
//    symbol INSIDE A COMMENT teaches people to bump its number without looking,
//    and a number bumped without looking is not a witness (plan §5.1, Б16).
// ---------------------------------------------------------------------------
private string stripComments(string src) {
    return src.replaceAll(regex(`/\*[\s\S]*?\*/`), "")
              .replaceAll(regex(`//[^\n]*`), "");
}

private size_t[string] historySurface(string path) {
    immutable src = stripComments(readText(path));
    size_t[string] surface;
    foreach (mt; src.matchAll(regex(`history_?\s*\.\s*(\w+)\s*\(`)))
        ++surface[mt[1]];
    return surface;
}

unittest {
    string[] bad;
    size_t   totalRecord = 0;

    immutable dir = buildPath(repoRoot, kG2Dir);
    assert(exists(dir) && isDir(dir),
        "G2 census: `" ~ dir ~ "` is not a directory. The group is DEFINED by "
      ~ "this directory, so a census that cannot read it proves nothing about "
      ~ "the five record sites it was meant to pin");

    // What the directory actually holds, sorted so the findings are stable.
    string[] onDisk;
    foreach (e; dirEntries(dir, SpanMode.shallow))
        if (e.isFile && e.name.extension == ".d") onDisk ~= e.name.baseName;
    onDisk.sort();

    bool[string] rostered;
    foreach (f; kRecorders) rostered[f] = true;
    foreach (row; kSilent)  rostered[row[0]] = true;

    foreach (f; onDisk) {
        if (f in rostered) continue;
        bad ~= "    · " ~ f ~ ": a NEW file in `" ~ kG2Dir ~ "` that no roster "
             ~ "row names. G2 is defined by this directory, so a file added "
             ~ "here is either a sixth record site — which changes what "
             ~ "`tests/test_tool_gesture_g2.d` is an oracle FOR and needs the "
             ~ "fixture re-frozen — or a silent helper, which needs a row in "
             ~ "`kSilent` with its reason";
    }

    foreach (f; kRecorders) {
        immutable path = buildPath(dir, f);
        if (!exists(path)) {
            bad ~= "    · " ~ f ~ ": named as one of G2's five record sites but "
                 ~ "absent from `" ~ kG2Dir ~ "`. The file moved or was "
                 ~ "renamed — fix the roster deliberately, because a census "
                 ~ "over a file it cannot read proves nothing";
            continue;
        }
        auto surface = historySurface(path);

        immutable size_t rec = ("record" in surface) ? surface["record"] : 0;
        totalRecord += rec;

        if (rec != 1)
            bad ~= "    · " ~ f ~ ": " ~ rec.to!string ~ " call(s) to "
                 ~ "`history.record(`, expected exactly 1 — this file is one of "
                 ~ "G2's five record sites and a site that vanished has no "
                 ~ "witness anywhere else in the two lanes";

        auto names = surface.keys.array;
        names.sort();
        foreach (name; names) {
            if (name == "record") continue;
            bad ~= "    · " ~ f ~ ": history surface carries `" ~ name ~ "` × "
                 ~ surface[name].to!string ~ ". Every G2 site's contract is "
                 ~ "`record`; `recordInSession` and `replaceInSessionTail` "
                 ~ "leave a run OPEN, so the next foreign record is "
                 ~ "CONSOLIDATED into this tool's run instead of standing as "
                 ~ "its own entry — and nothing on the HTTP surface (not the "
                 ~ "stack depth, not the wire names, not one plane of the mesh) "
                 ~ "says so. If this is deliberate, name it here with its "
                 ~ "reason";
        }
    }

    foreach (row; kSilent) {
        immutable path = buildPath(dir, row[0]);
        if (!exists(path)) continue;   // a helper that went away is not a finding
        auto surface = historySurface(path);
        if (surface.length == 0) continue;
        auto names = surface.keys.array;
        names.sort();
        foreach (name; names)
            bad ~= "    · " ~ row[0] ~ ": expected ZERO CommandHistory calls, "
                 ~ "found `" ~ name ~ "` × " ~ surface[name].to!string
                 ~ ". Reason this file was expected silent: " ~ row[1]
                 ~ ". A record site here is a SIXTH member of G2's directory "
                 ~ "with no cell in `tests/fixtures/tool_gesture/g2.json` — "
                 ~ "decide deliberately whether it joins the group or belongs "
                 ~ "to the transform zone's own witness";
    }

    if (totalRecord != kRecorders.length)
        bad ~= "    · TOTAL: " ~ totalRecord.to!string ~ " `history.record(` "
             ~ "site(s) over " ~ kRecorders.length.to!string ~ " files, "
             ~ "expected one each. A site added or removed changes what "
             ~ "`tests/test_tool_gesture_g2.d` is an oracle FOR, and must be "
             ~ "re-frozen deliberately";

    if (bad.length == 0) return;
    string msg = "G2 record-primitive census: " ~ bad.length.to!string
               ~ " finding(s) over `" ~ kG2Dir ~ "/**`:\n";
    foreach (b; bad) msg ~= b ~ "\n";
    assert(false, msg);
}
