// tool_gesture_runopen_g7_test — task 1905, lane G0-G7: the two witnesses the
// HTTP plane fixture cannot be, for group G7 (the topology-pen family).
//
// WHAT BLOCK 2 PINS. Both G7 record sites — the RAW one in
// `TopologyPenTool.placeVertexAt` and the shared tail
// `TopologyPenTool.recordSnapshotUndo` — write through `CommandHistory.record`,
// the primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
// open run and leaves `_runOpen` false; `recordInSession` OPENS one and leaves
// it true. The two are one token apart at the call site, and swapping them
// changes the SHAPE of the history without changing anything a user or an HTTP
// client can see through the surfaces `tests/test_tool_gesture_g7.d` reads.
//
// WHY THAT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
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
// the same answer the sibling lanes G0-G3 and G0-G4 reached for their groups.
// Both G7 record sites are `private` members of `TopologyPenTool`, and D's
// `private` is MODULE-scope: no test module and no derived class in another
// module can call them. Driving them would mean re-building the suite fixture
// in a unit test. So Block 2 pins the PRIMITIVE at both sites by reading them,
// and Block 1 supplies the behavioural half the reading cannot.
//
// ---------------------------------------------------------------------------
// BLOCK 3 IS NEW TO THIS GROUP, AND IT IS THE REASON G7 IS A FAMILY OF ITS OWN
// ---------------------------------------------------------------------------
//
// `TopologyPenTool.setUndoBindings` takes the family's THIRTEEN
// `MeshSessionEdit delegate()` factories as thirteen structurally IDENTICAL
// defaulted parameters, and `source/registration.d` passes them BY POSITION.
// The declaration's own comment says what that costs: a mis-ordered argument
// "would compile and silently label one op as another". Nothing in the tree
// checked it. The blast radius is not hypothetical either — three of the
// thirteen (`remove`, `removeEdge`, `removeVertex`) differ ONLY in the wire
// name they were built with, and one factory (`build`) is bound to TWO
// gestures.
//
// The fixture can only reach the four factories it drives (`build`, `move`,
// `remove`, `dupLoop`). Block 3 closes the other nine by composing the chain
// the compiler cannot see:
//
//     registration argument position  ->  setUndoBindings parameter name
//                                     ->  `factories_.<field>` assignment
//                                     ->  the wire name `source/app.d` built
//                                         that factory identifier with
//
// and pinning all thirteen triples. A swap of two arguments at the registration
// site re-pairs two fields with two identifiers and reddens naming both.
//
// WHAT BLOCK 3 DELIBERATELY DOES NOT CLAIM. The factory carries the WIRE NAME
// (`MeshSessionEdit.name()` returns `wireName_` verbatim); it does NOT carry
// the label that reaches the history. `setSnapshots(before, after, label)`
// overrides the constructor's default label, and the pen passes its own label
// at every one of the thirteen call sites — which is why the Shift+LMB
// duplicate-edge gesture records under `mesh.topoPen_build` with the label
// "Topology Duplicate Edge". So a factory swap moves `entryNames` and leaves
// `entryLabels` GREEN, and the roster below pins the wire name only.
//
// THE MUTATIONS THIS FILE ANSWERS TO:
//   * either record site, at its single history call:
//         history_.record(cmd);
//     ->  history_.recordInSession(cmd, history_.currentRunId);
//     Expected: Block 2 reddens naming the offending name; Block 1 stays green;
//     `tests/test_tool_gesture_g7.d` stays green on every plane, on
//     `undoDelta`, on `entryNames`, on `entryLabels` and on both residuals.
//   * `source/registration.d`, two ADJACENT arguments swapped, e.g.
//         topoPenMoveEditFactory, topoPenRemoveEditFactory
//     ->  topoPenRemoveEditFactory, topoPenMoveEditFactory
//     Expected: Block 3 reddens naming BOTH fields; Blocks 1 and 2 stay green;
//     the fixture reddens on `entryNames` in exactly the two cells whose
//     factories moved, and on nothing else.
//
// SCOPE, NAMED RATHER THAN IMPLIED. Blocks 1-2 are a NARROW pin — which
// primitive each G7 record site uses — not plan §5.1's per-family call-surface
// census (`tool_commit_seam_census_g7_test.d`), which keys on the whole multiset
// with per-file counts and a reason beside every legal non-recorder. When that
// file lands it supersedes Block 2; Blocks 1 and 3 are independent of it.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g7_test;

import std.algorithm : canFind;
import std.conv      : to;
import std.file      : readText, exists;
import std.path      : buildPath, dirName;
import std.array     : split;
import std.regex     : regex, matchAll, replaceAll;
import std.string    : indexOf, strip;

import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope;
import snapshot : MeshSnapshot;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// G7's package, one line per file. The tool is a package split across six
/// modules and only ONE of them may reach `CommandHistory`; a file appearing
/// here that the package does not contain is a roster edit, not a discovery.
private enum string[] kG7Files = [
    "defs.d", "json.d", "package.d", "render.d", "snap_guide.d", "tool.d",
];

/// The one file in the package that holds record sites, and how many.
/// TWO, not one, and that is the whole shape of this group: `placeVertexAt`
/// records a `MeshVertexNew` raw, `recordSnapshotUndo` is the shared tail
/// thirteen gesture commits funnel through.
private enum string kG7RecordFile  = "tool.d";
private enum size_t kG7RecordCount = 2;

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

private string stripComments(string src) {
    return src.replaceAll(regex(`/\*[\s\S]*?\*/`), "")
              .replaceAll(regex(`//[^\n]*`), "");
}

// ---------------------------------------------------------------------------
// 1. POSITIVE CONTROL, and it is load-bearing twice over.
//
//    (a) Block 2 asserts both G7 sites spell `record`. That is worth nothing
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

    // --- the primitive both G7 sites are supposed to use.
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
      ~ "stack depth and every plane of the G7 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}

// ---------------------------------------------------------------------------
// 2. THE RECORD-PRIMITIVE CENSUS. The whole topology-pen package reaches
//    `CommandHistory` exactly twice, both times through `record`, both times
//    from `tool.d`.
//
//    ACCUMULATE-THEN-RAISE, so a mutation run reads every offender at once
//    rather than the alphabetically-first one (agent memory: a roster gate that
//    asserts inside the loop names only the first).
//
//    Comments and strings are stripped first: a census that reddens when
//    someone renames a symbol INSIDE A COMMENT teaches people to bump its
//    number without looking, and a number bumped without looking is not a
//    witness (plan §5.1, Б16). This package's comments name `history_.record`
//    several times over, so the stripping is load-bearing here, not defensive.
// ---------------------------------------------------------------------------
unittest {
    string[] bad;
    size_t   totalRecord = 0;

    foreach (f; kG7Files) {
        immutable path = buildPath(repoRoot, "source", "tools", "edit",
                                   "topology_pen", f);
        assert(exists(path),
            "G7 census: `" ~ path ~ "` does not exist. The roster names a file "
          ~ "that moved or was renamed — fix the roster deliberately, because a "
          ~ "census over a file it cannot read proves nothing about the site it "
          ~ "was meant to pin");

        immutable src = stripComments(readText(path));
        size_t[string] surface;
        foreach (mt; src.matchAll(regex(`history_?\s*\.\s*(\w+)\s*\(`)))
            ++surface[mt[1]];

        immutable size_t rec = ("record" in surface) ? surface["record"] : 0;
        totalRecord += rec;

        immutable size_t want = (f == kG7RecordFile) ? kG7RecordCount : 0;
        if (rec != want)
            bad ~= "    · " ~ f ~ ": " ~ rec.to!string ~ " call(s) to "
                 ~ "`history.record(`, expected " ~ want.to!string
                 ~ ". G7 holds exactly two record sites, BOTH in `tool.d` "
                 ~ "(`placeVertexAt` raw, `recordSnapshotUndo` shared by "
                 ~ "thirteen gesture commits) — a site that vanished has no "
                 ~ "witness anywhere else in the two lanes, and a site that "
                 ~ "appeared in another module of the package is a second seam "
                 ~ "nobody named";

        foreach (name, n; surface) {
            if (name == "record") continue;
            bad ~= "    · " ~ f ~ ": history surface carries `" ~ name ~ "` × "
                 ~ n.to!string ~ ". Every G7 site's contract is `record`, and "
                 ~ "this group holds NO legal non-recorder — unlike G5, whose "
                 ~ "roster names `invalidateRedo` with its reason. "
                 ~ "`recordInSession` and `replaceInSessionTail` leave a run "
                 ~ "OPEN, so the next foreign record is CONSOLIDATED into this "
                 ~ "tool's run instead of standing as its own entry — and "
                 ~ "nothing on the HTTP surface (not the stack depth, not the "
                 ~ "wire names, not the labels, not one plane of the mesh) says "
                 ~ "so. If this is deliberate, name it here with its reason";
        }
    }

    // The total goes into the SAME accumulator, never in front of it. A guard
    // that refuses first hides the findings behind it — and the per-file lines
    // are the ones that name the offending file AND the offending primitive,
    // which is the whole point of running the mutation (the sibling lane
    // measured exactly that: as a separate assert placed above, this line
    // swallowed the `recordInSession` finding it was supposed to accompany).
    if (totalRecord != kG7RecordCount)
        bad ~= "    · TOTAL: " ~ totalRecord.to!string ~ " `history.record(` "
             ~ "site(s) over the topology-pen package, expected "
             ~ kG7RecordCount.to!string ~ ". A site added or removed changes "
             ~ "what `tests/test_tool_gesture_g7.d` is an oracle FOR, and must "
             ~ "be re-frozen deliberately";

    if (bad.length == 0) return;
    string msg = "G7 record-primitive census: " ~ bad.length.to!string
               ~ " finding(s) over `source/tools/edit/topology_pen/**`:\n";
    foreach (b; bad) msg ~= b ~ "\n";
    assert(false, msg);
}

// ---------------------------------------------------------------------------
// 3. THE POSITIONAL BINDING. See this file's header for why it exists and for
//    the one thing it deliberately does not claim.
// ---------------------------------------------------------------------------

/// One row of the composed chain.
private struct Bind {
    string field;   // the `factories_.<field>` the parameter is assigned to
    string ident;   // the `source/app.d` factory identifier registration passes
    string wire;    // the wire name app.d built that identifier with
}

/// The FROZEN roster, position by position, as `source/registration.d` passes
/// them today. Thirteen rows; `build` is the one bound to two gestures, and
/// `remove` / `removeEdge` / `removeVertex` are the three that differ ONLY by
/// wire name — the pairs a mis-ordered argument would silently exchange.
private enum Bind[] kFrozenBinds = [
    Bind("build",        "topoPenBuildEditFactory",        "mesh.topoPen_build"),
    Bind("move",         "topoPenMoveEditFactory",         "mesh.topoPen_move"),
    Bind("remove",       "topoPenRemoveEditFactory",       "mesh.topoPen_remove"),
    Bind("addLoop",      "topoPenAddLoopEditFactory",      "mesh.topoPen_addloop"),
    Bind("slide",        "topoPenSlideEditFactory",        "mesh.topoPen_slide"),
    Bind("smooth",       "topoPenSmoothEditFactory",       "mesh.topoPen_smooth"),
    Bind("split",        "topoPenSplitEditFactory",        "mesh.topoPen_split"),
    Bind("moveLoop",     "topoPenMoveLoopEditFactory",     "mesh.topoPen_moveloop"),
    Bind("dupLoop",      "topoPenDupLoopEditFactory",      "mesh.topoPen_duploop"),
    Bind("smoothLoop",   "topoPenSmoothLoopEditFactory",   "mesh.topoPen_smoothloop"),
    Bind("fill",         "topoPenFillEditFactory",         "mesh.topoPen_fill"),
    Bind("removeEdge",   "topoPenRemoveEdgeEditFactory",   "mesh.topoPen_removeedge"),
    Bind("removeVertex", "topoPenRemoveVertexEditFactory", "mesh.topoPen_removevertex"),
];

/// The substring of `src` starting at `open` (which must index an opening
/// bracket) and ending at its match, brackets included. Counting rather than a
/// regex because the registration block and the parameter list both nest.
private string balanced(string src, size_t open, char lo, char hi) {
    int depth = 0;
    foreach (i; open .. src.length) {
        if (src[i] == lo) ++depth;
        else if (src[i] == hi) {
            --depth;
            if (depth == 0) return src[open .. i + 1];
        }
    }
    assert(false, "unbalanced '" ~ lo ~ "' at " ~ open.to!string
                ~ " — the parse below would silently read the rest of the file");
}

/// Parameter names of `setUndoBindings`, in declaration order, minus the two
/// non-factory leaders (`h`, `f`).
private string[] factoryParams(string toolSrc) {
    immutable ptrdiff_t at = toolSrc.indexOf("void setUndoBindings(");
    assert(at >= 0,
        "G7 binding census: `void setUndoBindings(` not found in tool.d. The "
      ~ "declaration was renamed or reformatted; fix this parse deliberately "
      ~ "rather than letting the roster below compare against an empty list");
    immutable size_t open = cast(size_t) at + "void setUndoBindings".length;
    auto list = balanced(toolSrc, open, '(', ')');
    string[] names;
    foreach (p; list[1 .. $ - 1].split(",")) {
        auto lhs = p.split("=")[0].strip();
        auto tok = lhs.split();
        assert(tok.length >= 2,
            "G7 binding census: parameter `" ~ p.strip()
          ~ "` has no type+name pair — the parse is not reading a parameter list");
        names ~= tok[$ - 1].strip();
    }
    assert(names.length >= 2 && names[0] == "h" && names[1] == "f",
        "G7 binding census: `setUndoBindings` no longer opens with (h, f) — its "
      ~ "first two parameters are " ~ names[0 .. names.length < 2 ? $ : 2].to!string
      ~ ". The two leaders are skipped by POSITION below, so this must be "
      ~ "re-read before the roster means anything");
    return names[2 .. $];
}

unittest {
    immutable toolSrc = stripComments(
        readText(buildPath(repoRoot, "source", "tools", "edit", "topology_pen",
                           "tool.d")));
    immutable regSrc  = stripComments(
        readText(buildPath(repoRoot, "source", "registration.d")));
    immutable appSrc  = stripComments(
        readText(buildPath(repoRoot, "source", "app.d")));

    string[] bad;

    // (i) parameter name -> `factories_.<field>`, read out of the body.
    auto params = factoryParams(toolSrc);
    string[string] paramToField;
    {
        immutable ptrdiff_t at = toolSrc.indexOf("void setUndoBindings(");
        immutable size_t po = cast(size_t) at + "void setUndoBindings".length;
        auto plist = balanced(toolSrc, po, '(', ')');
        immutable size_t bo = po + plist.length;
        immutable ptrdiff_t brace = toolSrc[bo .. $].indexOf("{");
        assert(brace >= 0, "G7 binding census: no body after setUndoBindings(...)");
        auto body_ = balanced(toolSrc, bo + cast(size_t) brace, '{', '}');
        foreach (mt; body_.matchAll(regex(`factories_\.(\w+)\s*=\s*(\w+)\s*;`)))
            paramToField[mt[2]] = mt[1];
    }

    // (ii) `source/app.d` factory identifier -> the wire name it was built with.
    string[string] identToWire;
    foreach (mt; appSrc.matchAll(regex(
            `auto\s+(topoPen\w*EditFactory)\s*=\s*\(\)\s*=>\s*new\s+MeshSessionEdit\([^;]*?"([^"]+)"\s*,`)))
        identToWire[mt[1]] = mt[2];

    // (iii) the registration call's argument identifiers, IN ORDER.
    string[] idents;
    {
        immutable string key = `reg.toolFactories["mesh.topoPen"] = () {`;
        immutable ptrdiff_t at = regSrc.indexOf(key);
        assert(at >= 0,
            "G7 binding census: the `mesh.topoPen` registration block was not "
          ~ "found in source/registration.d. Every row below would then compare "
          ~ "an empty list against the frozen roster — fix the parse, do not "
          ~ "relax it");
        immutable size_t bo = cast(size_t) at + key.length - 1;
        auto block = balanced(regSrc, bo, '{', '}');
        foreach (mt; block.matchAll(regex(`topoPen\w*EditFactory`)))
            idents ~= mt.hit;
    }

    // Compose, then compare position by position.
    Bind[] fresh;
    foreach (i, ident; idents) {
        string field = "<no parameter at this position>";
        if (i < params.length) {
            auto pf = params[i] in paramToField;
            field = (pf is null)
                  ? "<param " ~ params[i] ~ " assigned to no field>" : *pf;
        }
        auto pw = ident in identToWire;
        immutable string wire = (pw is null)
            ? "<no `auto " ~ ident ~ " = () => new MeshSessionEdit(...)` in "
            ~ "source/app.d>" : *pw;
        fresh ~= Bind(field, ident, wire);
    }

    if (params.length != kFrozenBinds.length)
        bad ~= "    · setUndoBindings takes " ~ params.length.to!string
             ~ " factory parameter(s), the roster holds "
             ~ kFrozenBinds.length.to!string ~ ". A factory added or removed "
             ~ "re-numbers every position after it, which is exactly the "
             ~ "silent mis-labelling the declaration's own comment warns about";
    if (idents.length != kFrozenBinds.length)
        bad ~= "    · the `mesh.topoPen` registration passes "
             ~ idents.length.to!string
             ~ " factory argument(s), the roster holds "
             ~ kFrozenBinds.length.to!string;

    immutable size_t n = fresh.length < kFrozenBinds.length
                       ? fresh.length : kFrozenBinds.length;
    foreach (i; 0 .. n) {
        if (fresh[i] == kFrozenBinds[i]) continue;
        bad ~= "    · position " ~ i.to!string ~ ": frozen "
             ~ kFrozenBinds[i].field ~ " <- " ~ kFrozenBinds[i].ident
             ~ " (" ~ kFrozenBinds[i].wire ~ "), fresh "
             ~ fresh[i].field ~ " <- " ~ fresh[i].ident
             ~ " (" ~ fresh[i].wire ~ "). The thirteen factories are "
             ~ "structurally identical delegates passed BY POSITION, so this "
             ~ "compiles and silently labels one gesture's undo entry with "
             ~ "another gesture's wire name — in the history and in a replay. "
             ~ "If the re-order is deliberate, re-freeze this roster and "
             ~ "re-freeze `tests/fixtures/tool_gesture/g7.json`, whose "
             ~ "`entryNames` are the behavioural half of this same claim";
    }

    // ANTI-VACUITY, and it is not decoration. Everything above is "the parsed
    // list equals the frozen one" — which a parse that returned the roster by
    // accident, or a comparison that cannot see a difference, satisfies for
    // free. So swap two adjacent rows of the FRESH list in a copy and require
    // the comparison to notice, and require the parsed maps to be non-empty and
    // one-to-one.
    assert(paramToField.length == kFrozenBinds.length,
        "CONTROL: the body of `setUndoBindings` yielded "
      ~ paramToField.length.to!string ~ " `factories_.X = param;` assignment(s), "
      ~ "expected " ~ kFrozenBinds.length.to!string ~ ". With fewer, the `field` "
      ~ "column below is a placeholder string and the roster compares "
      ~ "placeholders to placeholders");
    assert(identToWire.length >= kFrozenBinds.length,
        "CONTROL: source/app.d yielded " ~ identToWire.length.to!string
      ~ " topoPen factory->wire-name pair(s), expected at least "
      ~ kFrozenBinds.length.to!string ~ " — the `wire` column would otherwise "
      ~ "be a constant placeholder on every row");
    if (fresh.length >= 2) {
        auto probe = fresh.dup;
        auto t = probe[0]; probe[0] = probe[1]; probe[1] = t;
        assert(probe[0] != kFrozenBinds[0] || probe[1] != kFrozenBinds[1],
            "CONTROL: swapping the first two parsed bindings produced a list "
          ~ "the roster still accepts. `Bind`'s comparison cannot see an "
          ~ "argument swap, so every row above is green under the mutation this "
          ~ "block exists for");
    }

    if (bad.length == 0) return;
    string msg = "G7 positional-binding census: " ~ bad.length.to!string
               ~ " finding(s) over source/registration.d -> "
               ~ "source/tools/edit/topology_pen/tool.d -> source/app.d:\n";
    foreach (b; bad) msg ~= b ~ "\n";
    assert(false, msg);
}
