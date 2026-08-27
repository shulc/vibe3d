// symmetry_delta_test — the BEHAVIOURAL half of task 1903 §L0-b.
//
// `mesh.transform` and `mesh.symmetrize` are the two position commands whose
// writes do not happen in their own file. Both go through `source/symmetry.d`
// (`applySymmetryMirror` at :302, `applySymmetryMirrorDelta` at :379), a module
// NEITHER census zone scans — the zones are `source/mesh_ops/**` and
// `source/commands/**` — and whose signature belongs to task 1905/T2, so this
// stage may not route it through the batch.
//
// THAT IS WHY THIS FILE EXISTS, and it is a sharper case than L0-d's:
//
//   * `symmetrize` makes ZERO forward position writes of its own. Delete its
//     recorder and the op-log is EMPTY, `revert()` still answers `true` off
//     the legacy array, the census row for the file is still 0, and the
//     forward geometry is still perfect. §5.3's "answers true, changes
//     nothing" — which is worse than a throw, because nothing reports it.
//   * `mesh.transform`'s legacy `touchedIdx`/`touchedPrev` capture ALREADY
//     covers the mirror partner. So deleting its pass-2 recorder leaves the
//     forward correct, the census at 0, the tracker-OFF undo correct, and only
//     the ARMED revert wrong — on a vertex the command never names.
//
// THE STAND IS THE WHOLE ARGUMENT (CLAUDE.md, "the fixture cannot exhibit the
// phenomenon"). The mirror partner must be OUTSIDE the selection:
//
//   * with symmetry OFF there is no partner write at all, and every assertion
//     below is green under any design — the control cell says so out loud;
//   * with BOTH sides selected the partner is in `vmask`, so pass 1 writes it
//     and pass 1's own `ed.setVertexPositions` records it. The pass-2 recorder
//     could be deleted and nothing would redden.
//
// Neither of those two stands may be used to pin this. The stand below selects
// exactly one vertex on the +X side and asserts, FIRST, that its partner is
// unselected and that the forward moved it anyway.
module tests.unit.commands.mesh.symmetry_delta_test;

import std.format : format;

import command;
import mesh;
import view;
import editmode : EditMode;
import math      : Vec3;
import params    : Param;
import http_json : meshPlanesJson;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, MeshEditScope,
                         undoTrackerEnabled, setUndoTrackerEnabled;
import operator  : VectorStack;
import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
import toolpipe.stages.symmetry : SymmetryStage;

import commands.mesh.transform  : MeshTransform;
import commands.mesh.symmetrize : MeshSymmetrize;

// ---------------------------------------------------------------------------
// The stand: two quads sharing an on-plane seam at X = 0, exactly symmetric.
//
//   0: seam (0, 0, 0)        1: seam (0, 1, 0)
//   2: +X   (1, 0.5, 0)      3: +X   (1.5, 1.2, 0)
//   4: -X   (-1, 0.5, 0)     5: -X   (-1.5, 1.2, 0)
//   faces:  [0,2,3,1] (+X quad), [0,1,5,4] (-X quad)
//
// `drift` displaces v2 along +X. `mesh.transform`'s cell wants drift = 0 (the
// pair table must find v4 from v2's mirror); `mesh.symmetrize`'s cell wants a
// drift, because a mesh that is already symmetric is a no-op there and the
// command refuses to record a history entry at all.
//
// NOT A CUBE, deliberately: a closed solid mirrored about its own symmetry
// plane cannot separate "the partner was recorded" from "the partner did not
// need to move" — every vertex has a partner at the position the mirror would
// write anyway, so the diff is empty and the cell is green over a deleted
// recorder (CLAUDE.md's facing-rule trap, in its position-write form).
// ---------------------------------------------------------------------------
private enum uint kDriver  = 2;   // +X, the vertex the cells select
private enum uint kPartner = 4;   // -X, its mirror — NEVER selected

private Mesh* twoQuadStand(float drift) {
    auto m = new Mesh;
    m.addVertex(Vec3( 0.0f,          0.0f, 0.0f));
    m.addVertex(Vec3( 0.0f,          1.0f, 0.0f));
    m.addVertex(Vec3( 1.0f + drift,  0.5f, 0.0f));
    m.addVertex(Vec3( 1.5f,          1.2f, 0.0f));
    m.addVertex(Vec3(-1.0f,          0.5f, 0.0f));
    m.addVertex(Vec3(-1.5f,          1.2f, 0.0f));
    m.addFace([0u, 2u, 3u, 1u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private View standView() { return new View(0, 0, 800, 600); }

private string planes(Mesh* m) { return meshPlanesJson(*m); }

// The live SymmetryStage `MeshTransform` reads through `captureLiveSymmetry`.
// `mesh.symmetrize` needs none of this — it builds its own packet and its own
// pairing, which is why it works headlessly over `/api/command`.
//
// The caller MUST pair this with `scope(exit) g_pipeCtx = null;`: the context
// is `__gshared`, so leaving it installed leaks a stage bound to a dead stand
// into every unittest module that runs after this one in the same binary.
private void installSymmetry(Mesh* m, EditMode* em) {
    auto sym = new SymmetryStage(() => m, em);
    auto ctx = new ToolPipeContext;
    // REGISTER FIRST, CONFIGURE SECOND, and the order is load-bearing:
    // `Pipeline.add` calls `op.reset()` on every Operator it registers, and
    // `SymmetryStage.reset()` sets `enabled = false` (it is SceneReset's hook,
    // so a "start fresh" scene wipes the plane). Configuring before the `add`
    // leaves the stage disabled, `captureLiveSymmetry` returns false, no
    // mirror write happens, and W-b1 below is green over ANY design — which is
    // how this rig was first written, and the stand's own non-vacuity assert
    // is what caught it.
    ctx.pipeline.add(sym);
    sym.enabled      = true;
    sym.axisIndex    = 0;        // mirror plane X = 0
    sym.offset       = 0.0f;
    sym.topology     = false;    // spatial pairing; the stand is exact
    sym.epsilonWorld = 1e-4f;
    g_pipeCtx = ctx;
}

private MeshTransform mkTranslate(Mesh* m, View v, EditMode* em) {
    m.selectVertex(kDriver);
    auto c = new MeshTransform(m, v, *em);
    c.setKind("translate");
    c.setDelta(Vec3(0.0f, 0.5f, 0.0f));
    return c;
}

private MeshSymmetrize mkSymmetrize(Mesh* m, View v) {
    auto c = new MeshSymmetrize(m, v, EditMode.Vertices);
    foreach (ref p; c.params()) {
        if (p.name == "axis")    *p.sptr = "X";
        if (p.name == "side")    *p.sptr = "positive";
        if (p.name == "epsilon") *p.fptr = 0.1f;
    }
    return c;
}

private const(MeshEditDelta)* recordedOf(Command c) {
    if (auto x = cast(MeshTransform)c)  return &x.recordedUndo().delta();
    if (auto x = cast(MeshSymmetrize)c) return &x.recordedUndo().delta();
    assert(false, "no recordedUndo accessor for " ~ c.name());
}
private bool armedOf(Command c) {
    if (auto x = cast(MeshTransform)c)  return x.recordedUndo().armed();
    if (auto x = cast(MeshSymmetrize)c) return x.recordedUndo().armed();
    assert(false, "no recordedUndo accessor for " ~ c.name());
}

/// Every index any `SetPos` entry in the log names, in log order. Both
/// commands can record MORE THAN ONE entry — `mesh.transform` records its
/// kind-switch pass and its mirror pass separately, per §L0.2's "record per
/// pass" arm — so a cell that read `log[0].vIdx` would be reading half the
/// answer and would be green over a deleted second recorder.
private uint[] setPosIndices(const(MeshEditDelta)* d) {
    uint[] all;
    foreach (ref e; d.log)
        if (e.kind == MeshOpEntry.Kind.SetPos)
            all ~= e.vIdx;
    return all;
}
private bool namesIndex(const(MeshEditDelta)* d, uint vi) {
    foreach (x; setPosIndices(d)) if (x == vi) return true;
    return false;
}

// ---------------------------------------------------------------------------
// W-b1 — THE DISCRIMINATING CELL, and the reason L0-b is a group of its own.
//
// symmetry ON, the mirror partner OUTSIDE the selection. After the translate:
// the op-log's SetPos index set contains BOTH driver and partner; after the
// revert the partner's position is BIT-identical to pre-op.
//
// Mutation: restrict `recordPositionDiff` to the driver set, or delete the
// `ed.recordPositionDiff(preMirror)` statement in `transform.d`'s pass 2. The
// partner comes back at its POST-op position and the assert names the vertex.
// Every other check in this repo stays green under that mutation: the forward
// geometry is unchanged, `countRawPositionWrites(transform.d)` is still 0,
// `armed()` is still true (pass 1 recorded), and the tracker-OFF revert still
// restores the partner off `touchedPrev`.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    auto m  = twoQuadStand(0.0f);
    auto v  = standView();
    auto em = EditMode.Vertices;
    installSymmetry(m, &em);
    scope(exit) g_pipeCtx = null;

    auto c = mkTranslate(m, v, &em);

    // ---- NON-VACUITY, ASSERTED FIRST -------------------------------------
    assert(m.isVertexSelected(kDriver),
        "the stand did not select the driver — the transform's operand mask "
      ~ "would be empty and `mesh.selectedVertexIndices*` would fall back to "
      ~ "the WHOLE MESH, putting the partner inside the moving set and making "
      ~ "every assertion below green under a deleted recorder.");
    assert(!m.isVertexSelected(kPartner),
        format("vertex %d (the mirror partner) IS selected. A stand where both "
             ~ "sides are selected cannot pin this: pass 1 writes the partner "
             ~ "through `ed.setVertexPositions`, which records it, so deleting "
             ~ "the pass-2 recorder reddens nothing.", kPartner));

    immutable pre = planes(m);
    const Vec3 preDriver  = m.vertices[kDriver];
    const Vec3 prePartner = m.vertices[kPartner];

    assert(c.apply(), "mesh.transform: the forward must apply on this stand");

    assert(m.vertices[kDriver] != preDriver,
        "the forward did not move the DRIVER — the operand mask is empty and "
      ~ "this cell is measuring nothing.");
    assert(m.vertices[kPartner] != prePartner,
        format("the forward did not move the PARTNER (vertex %d). Symmetry is "
             ~ "not active on this stand: either the SymmetryStage did not "
             ~ "register into `g_pipeCtx`, or the spatial pairing did not find "
             ~ "v%d from v%d's mirror. With no mirror write there is nothing "
             ~ "for the pass-2 recorder to record and the whole cell is "
             ~ "vacuous.", kPartner, kPartner, kDriver));

    // ---- THE OP-LOG HALF --------------------------------------------------
    assert(armedOf(c),
        "mesh.transform recorded NO delta and fell back to its legacy revert. "
      ~ "The legacy path already covers both passes, so the forward and the "
      ~ "undo are both still correct — this is the assert that sees past it.");
    auto d = recordedOf(c);
    foreach (i, ref e; d.log)
        assert(e.kind == MeshOpEntry.Kind.SetPos,
            format("mesh.transform: op-log entry %d is `%s`, expected SetPos. "
                 ~ "Any other kind makes `indexSpaceStable` answer false and "
                 ~ "the undo takes the SLOW finalize path.", i, e.kind));
    assert(namesIndex(d, kDriver),
        format("the op-log does not name the DRIVER (vertex %d); it names %s. "
             ~ "Pass 1 (the kind switch) is not recording.",
               kDriver, setPosIndices(d)));
    assert(namesIndex(d, kPartner),
        format("THE OP-LOG DOES NOT NAME THE MIRROR PARTNER (vertex %d); it "
             ~ "names %s. `applySymmetryMirror` wrote that vertex RAW — under "
             ~ "`alias mesh this` a raw `mesh.vertices[mi] = …` compiles inside "
             ~ "a recording batch and produces no op-log entry — so pass 2's "
             ~ "`ed.recordPositionDiff(preMirror)` is the only thing that can "
             ~ "put it in the delta. The forward mesh is CORRECT either way; "
             ~ "the census row for transform.d is 0 either way.",
               kPartner, setPosIndices(d)));

    // ---- THE ARMED-REVERT HALF, which is the plane a forward check misses --
    assert(c.revert(), "mesh.transform: the delta revert must answer true");
    assert(m.vertices[kPartner] == prePartner,
        format("THE MIRROR PARTNER (vertex %d) CAME BACK AT ITS POST-OP "
             ~ "POSITION: %s, expected %s. Two causes reach this line and the "
             ~ "assert above tells them apart: if the op-log did NOT name the "
             ~ "partner it never got here, so the delta is SHORT — it carries "
             ~ "what the command wrote and not what `symmetry.d` wrote on its "
             ~ "behalf; if it DID name it, the entry is INVERTED — "
             ~ "`recordPositionDiff` handed `recordSetPos` its before and "
             ~ "after the wrong way round, and the revert is replaying the "
             ~ "post-op value. Both were observed red here.",
               kPartner, m.vertices[kPartner], prePartner));
    // Bit-identity, not `==`: `sameBits` is the predicate both the recorder and
    // `setVertexPositions` skip on, so a `-0.0`/`+0.0` divergence between the
    // two paths is exactly what a float compare would wave through.
    immutable back = planes(m);
    assert(back == pre,
        "mesh.transform: the recorded undo did not restore the pre-op planes. "
      ~ "`/api/mesh/planes` is plane-COMPLETE and prints `%.9g`, so it carries "
      ~ "the sign of a zero.\n  pre : " ~ pre[0 .. pre.length > 400 ? 400 : pre.length]
      ~ "\n  back: " ~ back[0 .. back.length > 400 ? 400 : back.length]);
}

// ---------------------------------------------------------------------------
// W-b1c — THE CONTROL, and it is here to be READ, not to catch a regression.
//
// Same command, same stand, symmetry OFF. The forward moves the driver and
// NOTHING else, so the op-log names one vertex and the pass-2 recorder is
// never reached. This cell is green with the recorder and green without it —
// which is the point: it is the stand W-b1 must NOT be built on, written down
// so nobody "simplifies" W-b1 into it. What it DOES pin is that the partner
// write is symmetry's and not the kind switch's.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);
    // Symmetry ABSENT, and made so rather than assumed: `g_pipeCtx` is
    // `__gshared`, so a cell above (or another module in the same binary)
    // could have left a stage installed, and a leaked stage would silently
    // turn this control into a second copy of W-b1.
    auto savedCtx = g_pipeCtx;
    g_pipeCtx = null;
    scope(exit) g_pipeCtx = savedCtx;

    auto m  = twoQuadStand(0.0f);
    auto v  = standView();
    auto em = EditMode.Vertices;
    auto c  = mkTranslate(m, v, &em);

    const Vec3 prePartner = m.vertices[kPartner];
    assert(c.apply(), "mesh.transform: forward");
    assert(m.vertices[kPartner] == prePartner,
        format("with NO SymmetryStage registered, vertex %d moved anyway — the "
             ~ "kind switch is writing outside its operand mask.", kPartner));

    auto d = recordedOf(c);
    assert(armedOf(c), "mesh.transform: nothing recorded even for pass 1");
    assert(setPosIndices(d) == [kDriver],
        format("symmetry-off op-log names %s, expected exactly [%d].",
               setPosIndices(d), kDriver));
    assert(c.revert(), "mesh.transform: revert");
}

// ---------------------------------------------------------------------------
// W-b2 — `mesh.symmetrize`'s op-log kinds are exactly [SetPos], length >= 1.
//
// Mutation: delete `ed.recordPositionDiff(prevPositions)`. The log is EMPTY,
// `armed()` goes false, `revert()` STILL ANSWERS TRUE off the legacy array and
// still lands on the right mesh — §5.3's "answers true, changes nothing"
// shape, inverted: this command's forward writes nothing of its own, so the
// recorder is the only live thing the migration added and this is the cell
// that proves it was ever live.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    auto m = twoQuadStand(0.05f);      // drifted: an exact mesh is a no-op here
    auto v = standView();
    auto c = mkSymmetrize(m, v);

    immutable pre = planes(m);
    const Vec3 prePartner = m.vertices[kPartner];
    const Vec3 preDriver   = m.vertices[kDriver];

    assert(c.apply(), "mesh.symmetrize: the forward must apply on this stand");
    assert(m.vertices[kPartner] != prePartner,
        format("mesh.symmetrize moved nothing at vertex %d — the stand is not "
             ~ "drifted, or the pairing tolerance is below the drift, and the "
             ~ "command's own movement gate would have refused. Every "
             ~ "assertion below would then be vacuous.", kPartner));
    assert(m.vertices[kDriver] == preDriver,
        format("the DRIVER moved (%s -> %s): `side: positive` means the +X "
             ~ "side is PRESERVED and the -X side snaps to it. If the driver "
             ~ "moves, the cell is measuring the wrong direction of the "
             ~ "mirror and `kPartner` is not the vertex the delta owes.",
               preDriver, m.vertices[kDriver]));

    assert(armedOf(c),
        "mesh.symmetrize recorded NO delta. Its ENTIRE forward is the "
      ~ "`applySymmetryMirror` call — zero position writes in its own file — "
      ~ "so with the recorder gone the op-log is empty, `revert()` still "
      ~ "answers true off `prevPositions`, the forward geometry is still "
      ~ "right, and `countRawPositionWrites(symmetrize.d)` is still 0. There "
      ~ "is nothing else in the tree that reddens for this.");
    auto d = recordedOf(c);
    assert(d.log.length >= 1,
        "mesh.symmetrize: the op-log is empty while `armed()` is true — "
      ~ "`PositionUndo.arm`'s emptiness test and `MeshEditDelta.isEmpty` "
      ~ "disagree.");
    foreach (i, ref e; d.log)
        assert(e.kind == MeshOpEntry.Kind.SetPos,
            format("mesh.symmetrize: op-log entry %d is `%s`, expected SetPos.",
                   i, e.kind));
    assert(namesIndex(d, kPartner),
        format("the op-log does not name the vertex the mirror actually moved "
             ~ "(%d); it names %s.", kPartner, setPosIndices(d)));

    assert(c.revert(), "mesh.symmetrize: the delta revert must answer true");
    immutable back = planes(m);
    assert(back == pre,
        "mesh.symmetrize: the recorded undo did not restore the pre-op "
      ~ "planes.\n  pre : " ~ pre[0 .. pre.length > 400 ? 400 : pre.length]
      ~ "\n  back: " ~ back[0 .. back.length > 400 ? 400 : back.length]);
}

// ---------------------------------------------------------------------------
// W-b3 — the ARMED-REVERT plane diff, BOTH WAYS, for both commands. Measured
// on the REVERSE: a forward carry says nothing about the inverse (§L0.2).
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    // --- mesh.transform, symmetry ON ---
    {
        auto m  = twoQuadStand(0.0f);
        auto v  = standView();
        auto em = EditMode.Vertices;
        installSymmetry(m, &em);
        scope(exit) g_pipeCtx = null;
        auto c = mkTranslate(m, v, &em);

        immutable pre = planes(m);
        assert(c.apply(), "mesh.transform: forward");
        immutable post = planes(m);
        assert(post != pre, "mesh.transform: vacuous stand");
        assert(armedOf(c), "mesh.transform: nothing recorded");
        assert(c.revert(), "mesh.transform: revert");
        immutable back = planes(m);
        assert(back == pre, "mesh.transform: revert did not restore the planes");
        assert(back != post,
            "mesh.transform: the post-op and post-revert dumps are IDENTICAL, "
          ~ "so `back == pre` above is satisfied by a forward that did nothing.");
    }
    // --- mesh.symmetrize ---
    {
        auto m = twoQuadStand(0.05f);
        auto v = standView();
        auto c = mkSymmetrize(m, v);

        immutable pre = planes(m);
        assert(c.apply(), "mesh.symmetrize: forward");
        immutable post = planes(m);
        assert(post != pre, "mesh.symmetrize: vacuous stand");
        assert(armedOf(c), "mesh.symmetrize: nothing recorded");
        assert(c.revert(), "mesh.symmetrize: revert");
        immutable back = planes(m);
        assert(back == pre, "mesh.symmetrize: revert did not restore the planes");
        assert(back != post, "mesh.symmetrize: forward did nothing");
    }
}

// ---------------------------------------------------------------------------
// W-b4 — tracker-on / tracker-off parity. The hand-rolled path is the ORACLE
// and neither command's version of it changed meaning in this stage, so a
// delta that lands on an intermediate state reddens here even when its own
// round-trip looks self-consistent.
//
// For `mesh.transform` this is the cell that would catch a pass-2 recorder
// whose before-image was the PRE-OP mesh instead of the post-pass-1 one on a
// vertex both passes touch.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    scope(exit) setUndoTrackerEnabled(wasOn);

    foreach (name; ["mesh.transform", "mesh.symmetrize"]) {
        string[2] pres, backs;
        foreach (k, on; [true, false]) {
            setUndoTrackerEnabled(on);
            auto v  = standView();
            auto em = EditMode.Vertices;
            Command c;
            Mesh*   m;
            if (name == "mesh.transform") {
                m = twoQuadStand(0.0f);
                installSymmetry(m, &em);
                c = mkTranslate(m, v, &em);
            } else {
                m = twoQuadStand(0.05f);
                c = mkSymmetrize(m, v);
            }
            scope(exit) g_pipeCtx = null;

            pres[k] = planes(m);
            assert(c.apply(), name ~ ": forward");
            assert(planes(m) != pres[k], name ~ ": vacuous stand");
            if (on) assert(armedOf(c),  name ~ ": nothing recorded");
            else    assert(!armedOf(c), name ~ ": the tracker-off arm ARMED a "
                                      ~ "delta — it opened a RECORDING batch, "
                                      ~ "so it is not an independent oracle "
                                      ~ "and this cell compares one path to "
                                      ~ "itself.");
            assert(c.revert(), name ~ ": revert");
            backs[k] = planes(m);
        }
        assert(pres[0] == pres[1],
            name ~ ": the two stands are not the same mesh — the parity "
          ~ "comparison would be measuring the stand, not the paths.");
        assert(backs[0] == backs[1],
            name ~ ": the DELTA revert and the HAND-ROLLED revert land on "
          ~ "different meshes. The hand-rolled path is the reference and it "
          ~ "did not change in this stage, so the recorded delta is what is "
          ~ "wrong — most likely a `posBefore` captured after part of the "
          ~ "forward had already run.");
        assert(backs[0] == pres[0], name ~ ": neither path restored the pre-op mesh.");
    }
}

// ---------------------------------------------------------------------------
// W-b5 — the `posAfter` half. Nothing on the command path reads it (redo
// re-runs the kernel), so every cell above is green over a delta whose `after`
// values are garbage. This replays the recorded delta FORWARD.
//
// For `mesh.transform` it is also the only cell that pins the ORDER of the two
// entries: replaying [pass1, pass2] forward must land on the post-op mesh, and
// on a vertex both passes touch the two entries only chain in one order.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    foreach (name; ["mesh.transform", "mesh.symmetrize"]) {
        auto v  = standView();
        auto em = EditMode.Vertices;
        Command c;
        Mesh*   m;
        if (name == "mesh.transform") {
            m = twoQuadStand(0.0f);
            installSymmetry(m, &em);
            c = mkTranslate(m, v, &em);
        } else {
            m = twoQuadStand(0.05f);
            c = mkSymmetrize(m, v);
        }
        scope(exit) g_pipeCtx = null;

        immutable pre = planes(m);
        assert(c.apply(), name ~ ": forward");
        immutable post = planes(m);
        assert(armedOf(c), name ~ ": nothing recorded");
        auto d = recordedOf(c);

        assert(d.revert(*m), name ~ ": delta.revert");
        assert(planes(m) == pre, name ~ ": delta.revert must land on pre");
        assert(d.apply(*m), name ~ ": delta.apply");
        assert(planes(m) == post,
            name ~ ": replaying the recorded delta FORWARD does not land on "
          ~ "the post-op mesh. `posAfter` is wrong. No cell on the command "
          ~ "path can see this — redo re-runs the kernel — so without this "
          ~ "assert `posAfter` is a presence bit.");
        assert(d.revert(*m), name ~ ": delta.revert (second)");
        assert(planes(m) == pre,
            name ~ ": the delta is not idempotent under apply/revert.");
    }
}

// ---------------------------------------------------------------------------
// W-b6 — redo lands where the first run landed.
//
// `mesh.transform`'s redo arm re-runs the kernel UNRECORDED, and that kernel
// re-reads the LIVE symmetry packet. So this cell also pins that the pair
// table survives the undo: a stage that rebuilt it against the reverted mesh
// still has to produce the same pairing, or the redo mirrors somewhere else.
// ---------------------------------------------------------------------------
unittest {
    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    foreach (name; ["mesh.transform", "mesh.symmetrize"]) {
        auto v  = standView();
        auto em = EditMode.Vertices;
        Command c;
        Mesh*   m;
        if (name == "mesh.transform") {
            m = twoQuadStand(0.0f);
            installSymmetry(m, &em);
            c = mkTranslate(m, v, &em);
        } else {
            m = twoQuadStand(0.05f);
            c = mkSymmetrize(m, v);
        }
        scope(exit) g_pipeCtx = null;

        immutable pre = planes(m);
        assert(c.apply(), name ~ ": forward");
        immutable post = planes(m);
        assert(c.revert(), name ~ ": undo");
        assert(planes(m) == pre, name ~ ": undo must land on pre");

        assert(c.apply(), name ~ ": redo must answer true");
        assert(planes(m) == post,
            name ~ ": REDO did not land where the first run landed. The redo "
          ~ "arm re-runs the kernel UNRECORDED from the restored pre-op mesh; "
          ~ "a `return true` that forgets to re-run leaves the mesh at the "
          ~ "PRE-op state.");
        assert(planes(m) != pre, name ~ ": the redo left the mesh at pre-op.");

        assert(c.revert(), name ~ ": the second undo");
        assert(planes(m) == pre,
            name ~ ": the second undo replayed the FIRST delta onto a mesh the "
          ~ "redo had moved, and did not land on pre.");
    }
}

// ---------------------------------------------------------------------------
// W-b7 — the fast path is taken, and the version counters are BLIND to this
// migration. Same scoping as L0-d's W-d11, re-measured here because
// `mesh.transform` records TWO entries and a two-entry log is a different
// input to `indexSpaceStable` than a one-entry one.
// ---------------------------------------------------------------------------
unittest {
    import mesh : g_hideDeriveRuns, g_rebuildEdgesRuns, g_buildLoopsRuns;

    const bool wasOn = undoTrackerEnabled();
    setUndoTrackerEnabled(true);
    scope(exit) setUndoTrackerEnabled(wasOn);

    foreach (name; ["mesh.transform", "mesh.symmetrize"]) {
        auto v  = standView();
        auto em = EditMode.Vertices;
        Command c;
        Mesh*   m;
        if (name == "mesh.transform") {
            m = twoQuadStand(0.0f);
            installSymmetry(m, &em);
            c = mkTranslate(m, v, &em);
        } else {
            m = twoQuadStand(0.05f);
            c = mkSymmetrize(m, v);
        }
        scope(exit) g_pipeCtx = null;

        assert(c.apply(), name ~ ": forward");
        assert(armedOf(c), name ~ ": nothing recorded");

        const ulong mv0 = m.mutationVersion;
        const ulong tv0 = m.topologyVersion;
        g_hideDeriveRuns   = 0;
        g_rebuildEdgesRuns = 0;
        g_buildLoopsRuns   = 0;

        assert(c.revert(), name ~ ": undo");

        assert(g_rebuildEdgesRuns == 0,
            format("%s: the undo ran `rebuildEdges` %d time(s). A SetPos-only "
                 ~ "log is index-space stable and takes L0-P1's fast path; a "
                 ~ "non-zero here means `indexSpaceStable` answered false — "
                 ~ "i.e. the log carries a kind other than SetPos — or the "
                 ~ "carve-out was defeated.", name, g_rebuildEdgesRuns));
        assert(g_buildLoopsRuns == 0,
            format("%s: the undo ran `buildLoops` %d time(s) — same cause as "
                 ~ "the row above; they are skipped as a PAIR.",
                   name, g_buildLoopsRuns));
        assert(g_hideDeriveRuns == 1,
            format("%s: the undo ran the hide derive %d time(s), expected 1. "
                 ~ "TWO means the SLOW path ran. ZERO means the revert never "
                 ~ "reached `finalize` — the command fell back to its legacy "
                 ~ "loop, which runs no derive. THIS is the counter that "
                 ~ "separates the DELTA path from the LEGACY one; the two "
                 ~ "version rows below cannot.", name, g_hideDeriveRuns));

        // BLIND TO THIS MIGRATION, and said out loud: the hand-rolled revert
        // also reads +1 / +0, so a version-counter cell is green before AND
        // after L0-b and green under every mutation that deletes a recorder.
        // What they DO see is a defeated carve-out (`+2 / +2`).
        assert(m.mutationVersion == mv0 + 1,
            format("%s: the undo moved mutationVersion by %d, expected 1. A "
                 ~ "`+2` is the SLOW finalize path; it is NOT evidence about "
                 ~ "whether anything was recorded.",
                   name, m.mutationVersion - mv0));
        assert(m.topologyVersion == tv0,
            format("%s: the undo moved topologyVersion by %d, expected 0. A "
                 ~ "SetPos-only log owes no topology bump and rebuilds no "
                 ~ "edges.", name, m.topologyVersion - tv0));
    }
}

// ---------------------------------------------------------------------------
// W-b8 — `recordPositionDiff`'s no-op predicate is BIT identity, not `==`.
//
// The primitive shares `MeshEditBatch.sameBits` with `setVertexPositions`, so a
// mutation of THAT function reddens `tests/unit/mesh_edit_batch_test.d`'s
// signed-zero block. What that block cannot see is an inline `before[i] ==
// m_.vertices[i]` written into this new method — the two would then disagree
// on exactly the cell D2 measured (9 of 320 `reduceToTarget` cells where
// `-0.0` vs `+0.0` separates them), and the diverging vertex would be dropped
// from the delta with every other row in this file green.
//
// The write below is deliberately RAW: this cell is standing in for
// `symmetry.d`, whose writes the batch never observes, so routing it through
// `ed.setVertexPos` would be testing the other primitive.
// ---------------------------------------------------------------------------
unittest {
    import std.math : isIdentical;

    auto m = twoQuadStand(0.0f);
    m.vertices[kDriver] = Vec3(0.0f, 0.5f, 0.0f);     // +0.0 in x

    auto before = m.vertices.dup;
    {
        auto ed = MeshEditBatch(*m, MeshEditScope.Position);
        // The `-0.0` write an external writer makes, unobserved by the batch.
        ed.vertices[kDriver] = Vec3(-0.0f, 0.5f, 0.0f);
        assert(m.vertices[kDriver].x == before[kDriver].x,
            "the two values are not `==`-equal, so this cell is measuring an "
          ~ "ordinary change and not the signed-zero one.");
        assert(!isIdentical(m.vertices[kDriver].x, before[kDriver].x),
            "the two values ARE bit-identical — `-0.0f` was folded to `+0.0f` "
          ~ "and there is nothing here for the predicate to separate.");
        ed.recordPositionDiff(before);
        auto d = ed.close();
        assert(namesIndex(&d, kDriver),
            format("`recordPositionDiff` dropped a write whose new value is "
                 ~ "`==` but NOT bit-identical to the old one. Its no-op "
                 ~ "predicate has been widened from `MeshEditBatch.sameBits` "
                 ~ "to a float compare, so it and `setVertexPositions` now "
                 ~ "disagree about which writes exist. Recorded indices: %s.",
                   setPosIndices(&d)));
    }
}
