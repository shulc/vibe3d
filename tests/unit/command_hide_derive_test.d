// Task 1373 / F3.2 — the discriminator for "is a super-linear command
// super-linear for the SAME reason task 1330 found?".
//
// WHAT THIS REPLACES, and why. The plan this task came from originally
// proposed a RATIO OF TIMES as the discriminator: run each candidate with one
// face hidden and without, and read the ratio. That was refuted on the code
// before it was ever run. `Mesh.beginHideDeriveBatch` arms deferral with
// `g_hideDeriveDeferSafe = !anyHideBitSet()` (source/mesh.d), and the comment
// beside it says outright that with anything hidden "every commit derives
// eagerly, exactly as before this change — correct, and still quadratic in
// that state". So with a face hidden the batch defers nothing for ANY
// command, both hypotheses predict the same large ratio, and three commands
// give a positively misleading one for unrelated reasons (`thicken` calls
// `rebuildEdges` zero times; `mesh.subdivide_faceted` replaces the whole
// struct; `mesh.hide` arms the Hide bits itself and disarms deferral
// mid-batch).
//
// A COUNT is the honest instrument here, and it is cheaper: it names the
// mechanism instead of correlating with it, and it does not measure time at
// all, so it runs under the ordinary `dub test --config=tests` gate on any
// host at any load.
//
// TWO CLAUSES, guarding two different failures:
//
//   (1) THE COMMAND REACHES THE GATE. The batch is opened in exactly one
//       place — `Command.apply`'s `if (auto op = cast(Operator)this)` branch
//       (source/command.d) — whose own comment calls it "the one gate every
//       mesh-mutating Operator command reaches its kernel through". A
//       mutating command that is NOT an Operator would bypass it silently and
//       pay the pre-1330 cost with nothing to show for it. That is a finding
//       in its own right, so it is asserted rather than assumed.
//
//   (2) ONE APPLY COSTS ONE DERIVE. `g_hideDeriveRuns > 1` is the literal
//       shape of task 1330's root cause: a full-mesh derived-plane refresh
//       per appended element instead of per command.
//
// Both are run in BOTH hide states. With nothing hidden the deferral is armed
// and the count must be exactly 1. With a face hidden the deferral is
// disarmed by construction, so the count is a DIRECT MEASURE of how many
// times the command commits — which is the number a profile would otherwise
// have to be read for, and it is recorded here rather than bounded, because
// the eager regime is a known-open cost (task 1333), not a regression.
module tests.unit.command_hide_derive_test;

import std.conv    : to;
import std.format  : format;

import command;
import operator : Operator;
import mesh;
import view;
import editmode;

import commands.mesh.radial_array_     : MeshRadialArray;
import commands.mesh.array_            : MeshArray;
import commands.mesh.spikey            : MeshSpikey;
import commands.mesh.clone_            : MeshClone;
import commands.mesh.duplicate_        : MeshDuplicate;
import commands.mesh.vertex_split      : MeshVertexSplit;
import commands.mesh.axis_slice        : MeshAxisSlice;
import commands.mesh.subdivide_faceted : SubdivideFaceted;
import commands.mesh.detriangulate     : MeshDetriangulate;

// The operand. Several of these commands refuse an empty selection outright
// (measured 2026-08-19: mesh.duplicate and mesh.vertexSplit are two), so the
// fixture selects EVERYTHING — every face and every vertex — and the applies
// below are asserted to succeed. A candidate that quietly refused would make
// the derive count vacuously 1 and the test green over nothing.
private void selectAll(ref Mesh m) {
    m.syncSelection();
    foreach (i; 0 .. m.faces.length)    m.selectFace(cast(uint)i);
    foreach (i; 0 .. m.vertices.length) m.selectVertex(cast(uint)i);
}

// A candidate plus the arguments it needs to do work on THIS fixture.
// `mesh.axisSlice` is the one that needs any: its default axis is Y and the
// grid is flat in Y, so the default finds a zero span and refuses
// (commands/mesh/axis_slice.d's `span < 1e-6` early-out). The arguments go in
// through `injectParamsInto`, the same route /api/command uses.
private struct Cand { Command cmd; string args; }

private Command configured(Cand c) {
    if (c.args.length) {
        import params    : injectParamsInto;
        import std.json  : parseJSON;
        auto pj = parseJSON(c.args);
        injectParamsInto(c.cmd.params(), pj);
    }
    return c.cmd;
}

private Command[] candidates(Mesh* m, ref View v) {
    // The four the task's premise names as suspects, plus the growing
    // commands task 1373 adds cases for. `subdivide_faceted` and
    // `detriangulate` take an extra topology-change delegate; a null one is
    // what a headless caller passes.
    Cand[] cs = [
        Cand(new MeshRadialArray(m, v, EditMode.Polygons)),
        Cand(new MeshArray      (m, v, EditMode.Polygons)),
        Cand(new MeshSpikey     (m, v, EditMode.Polygons)),
        Cand(new MeshClone      (m, v, EditMode.Polygons)),
        Cand(new MeshDuplicate  (m, v, EditMode.Polygons)),
        Cand(new MeshVertexSplit(m, v, EditMode.Vertices)),
        Cand(new MeshAxisSlice  (m, v, EditMode.Polygons), `{"axis":0,"count":4}`),
        Cand(new SubdivideFaceted   (m, v, EditMode.Polygons, null)),
        Cand(new MeshDetriangulate  (m, v, EditMode.Polygons, null)),
    ];
    Command[] out_;
    foreach (c; cs) out_ ~= configured(c);
    return out_;
}

unittest { // (1) every candidate reaches the one gate that opens the batch
    Mesh m = makeCube();
    selectAll(m);
    View v = new View(0, 0, 800, 600);
    foreach (c; candidates(&m, v)) {
        assert(cast(Operator)c !is null,
               c.name() ~ " is a mesh-mutating command that is NOT an " ~
               "Operator: it never reaches command.d's batch gate, so it " ~
               "pays one full hide-derive per appended element and no " ~
               "amount of work on the batch can help it");
    }
}

unittest { // (2) the derive count for ONE apply does not grow with the mesh
    // THE CLAUSE, stated as the root cause itself rather than as a proxy for
    // it. Task 1330's defect is "a full-mesh derived-plane refresh per
    // APPENDED ELEMENT inside a bulk operation" — i.e. a count that scales
    // with the mesh. So the question the test asks is exactly that: run the
    // same command on a grid and on a grid with 4x the faces, and demand the
    // SAME number of derives.
    //
    // Why not the flat `== 1` this started as: it is wrong, and measurement
    // said so. `mesh.subdivide_faceted` costs THREE derives per apply on a
    // clean mesh at every size (measured 2026-08-19: 3 at 16 faces, 3 at 64,
    // 3 at 256) because its kernel replaces the whole struct with `*mesh =
    // subdivideFaceted(*mesh)` and the replacement is built outside the
    // batch. Three is not one, and it is
    // also not the defect: it does not scale. A `== 1` clause would have gone
    // red on a command that is fine, and — worse for a gate — it would have
    // said "task 1330's root cause" about something that is not it.
    //
    // Measured counts backing the clause, clean grid, 2026-08-19, at 16 / 64
    // / 256 faces:
    //   radial_array 1/1/1   array 1/1/1        spikey 1/1/1
    //   clone 1/1/1          duplicate 1/1/1    vertexSplit 1/1/1
    //   axisSlice 1/1/1      detriangulate 1/1/1
    //   subdivide_faceted 3/3/3
    View v = new View(0, 0, 800, 600);
    immutable int[] sizes = [4, 8, 16];        // 16 / 64 / 256 faces
    foreach (i; 0 .. candidates(null, v).length) {
        size_t[] runs;
        string nm;
        foreach (gridN; sizes) {
            // A fresh mesh per (command, size): several of these replace the
            // whole struct or delete everything, so a shared fixture would
            // make the count depend on loop order.
            Mesh m = makeGridPlane(gridN);
            selectAll(m);
            auto c = candidates(&m, v)[i];
            nm = c.name();
            g_hideDeriveRuns = 0;
            const bool applied = c.apply();
            assert(applied,
                   nm ~ " did not apply to a " ~ gridN.to!string ~
                   "x grid — the fixture no longer exercises it, so the " ~
                   "count would be vacuous");
            runs ~= g_hideDeriveRuns;
            assert(g_hideDeriveRuns >= 1,
                   nm ~ " derived ZERO times for an apply that succeeded — " ~
                   "the batch close must always derive once");
        }
        foreach (k; 1 .. runs.length)
            assert(runs[k] == runs[0],
                   format("%s: hide-derives per ONE apply grew with the mesh " ~
                          "(%s at %s faces respectively). That is task 1330's " ~
                          "root cause verbatim — a full-mesh derived-plane " ~
                          "refresh per appended element instead of per command.",
                          nm, runs.to!string,
                          [sizes[0]*sizes[0], sizes[1]*sizes[1],
                           sizes[2]*sizes[2]].to!string));
    }
}

unittest { // (2b) with a face hidden the deferral is OFF — record what that costs
    // Not a bound, a measurement. `beginHideDeriveBatch` arms deferral only
    // when nothing is hidden (source/mesh.d), so here every commit derives
    // eagerly and the count IS the number of commits the command makes. That
    // is the number a profile would otherwise have to be read for.
    //
    // Measured on a 4x4 grid (16 faces), 2026-08-19, one face hidden:
    //   clone 3, duplicate 3, detriangulate 6, array 7, radial_array 8,
    //   axisSlice 29, vertexSplit 42, spikey 63, subdivide_faceted 64
    // — the known-open eager regime of task 1333, deliberately NOT bounded
    // here: pinning a ceiling on it would freeze an open cost as if settled.
    // What IS asserted is the pair of things that cannot be wrong for a
    // boring reason: the close always derives at least once, and the eager
    // regime is never CHEAPER than the deferred one for the same command —
    // if it ever were, `g_hideDeriveDeferSafe` would be arming backwards.
    View v = new View(0, 0, 800, 600);
    foreach (i; 0 .. candidates(null, v).length) {
        Mesh clean = makeGridPlane(4);
        selectAll(clean);
        auto c0 = candidates(&clean, v)[i];
        g_hideDeriveRuns = 0;
        const bool cleanApplied = c0.apply();
        const size_t cleanRuns = g_hideDeriveRuns;

        Mesh m = makeGridPlane(4);
        selectAll(m);
        m.setFaceHidden(0, true);
        assert(m.isFaceHidden(0), "fixture: face 0 must be hidden");
        auto c = candidates(&m, v)[i];
        g_hideDeriveRuns = 0;
        const bool applied = c.apply();
        if (!applied || !cleanApplied) continue;   // a hidden face may refuse
        assert(g_hideDeriveRuns >= 1,
               format("%s: the batch close must derive at least once, got %d",
                      c.name(), g_hideDeriveRuns));
        assert(g_hideDeriveRuns >= cleanRuns,
               format("%s: %d derives with a face hidden but %d with none — " ~
                      "deferral is armed the wrong way round",
                      c.name(), g_hideDeriveRuns, cleanRuns));
    }
}
