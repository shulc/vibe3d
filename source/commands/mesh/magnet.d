module commands.mesh.magnet;

import std.array : uninitializedArray;
import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, ElementConnect, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import deform_magnet : applyMagnet;

/// Convergent attraction deformer — pulls each vertex in the moving set
/// toward `target`, weighted by an Element-sphere falloff centred at
/// `center` (radius `dist`).
///
/// Moving set: selected geometry (empty selection ⇒ whole mesh),
/// same rule as mesh.jitter / mesh.transform.
///
/// Returns false (→ HTTP status:error) when:
///   - strength == 0, OR
///   - no vertex falls inside the falloff sphere (all weights == 0).
///
/// Interactive surface: `xfrm.magnet` tool.
class MeshMagnet : Command, Operator, IFalloffAware {
private:

    Vec3         target_   = Vec3(0, 0, 0);
    float        strength_ = 1.0f;
    float        dist_     = 1.0f;
    Vec3         center_   = Vec3(0, 0, 0);
    int          anchor_   = -1;

    // Optional injected falloff (IFalloffAware path — from the tool pipe).
    FalloffPacket falloff_;
    bool          hasFalloff_;

    // Undo delta.
    uint[] touchedIdx_;
    Vec3[] touchedPrev_;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d1). The two arrays above stay
    // — `applyMagnet` fills them and they are ALSO the values this command
    // records — and the loop in `revert()` stays as the EMPTY-DELTA arm: a
    // forward that moved nothing bitwise leaves the holder disarmed. It was
    // the `VIBE3D_UNDO_TRACKER=off` oracle too until task 1903 Stage N.
    PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing falls back to its legacy revert and
        /// restores the right positions anyway, so every result-shaped
        /// assertion — the plane diff, the redo cell, the parity cell — is
        /// GREEN over a deleted recorder. Only reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

public:
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.magnet"; }
    override string label() const { return "Magnet"; }

    override Param[] params() {
        return [
            Param.vec3_ ("target",   "Target",   &target_,   Vec3(0,0,0)),
            Param.float_("strength", "Strength", &strength_, 1.0f),
            Param.float_("dist",     "Dist",     &dist_,     1.0f),
            Param.vec3_ ("center",   "Center",   &center_,   Vec3(0,0,0)),
            Param.int_  ("anchor",   "Anchor",   &anchor_,  -1),
        ];
    }

    // IFalloffAware — lets the tool pipe inject a pre-computed falloff.
    void setFalloff(FalloffPacket fp) {
        falloff_    = fp;
        hasFalloff_ = true;
    }

    // Operator
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (auto fp = vts.get!FalloffPacket())
            setFalloff(*fp);
        // Task 0619: the injected packet above can be Screen/Lasso, and the
        // subject packet carries the viewport it must be projected with.
        const auto aim = aimSpace(subj.viewport, primaryModelSpace());

        // §2.4 — EVERY guard resolved BEFORE the batch is opened. A `return`
        // (or a `throw`) out of an open batch leaves `~MeshEditBatch` to pop
        // the frame, and that pop ticks `changeBus.batchLeaks`, which the suite
        // asserts is 0. These two are magnet's whole guard set; they read only
        // params, so hoisting them changes no answer.
        if (strength_ <= 0.0f) return false;
        if (!hasFalloff_ && dist_ <= 1e-9f) return false;

        // REDO (CommandHistory.redo): re-run the kernel UNRECORDED and keep the
        // first delta. `applyMagnet` is a pure function of the params and the
        // restored pre-op mesh, so the replay lands where the first run landed
        // and the delta's `posBefore` still inverts it exactly.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, aim);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, aim);
        undo_.arm(ed.close());
        if (!ok) { undo_.disarm(); return false; }
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // THE EMPTY-DELTA ARM. `RecordedUndo.arm` leaves the holder DISARMED
        // when the batch came back with an empty log, so this is the live
        // answer for a forward that succeeded and moved nothing a bitwise diff
        // could see — not dead code, and not a fallback for a path that no
        // longer exists. Until task 1903 Stage N it was also the tracker-off
        // ORACLE the plane-diff cells measured the recorded revert against
        // (W-d3c); that reading died with the hatch, this one did not.
        if (touchedIdx_.length == 0) return false;
        // TASK 1903 L0-d — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO.
        // The plan's §2.5 template left this loop "untouched"; that is
        // incompatible with its own §1/§3/W-d1, which require this file to read
        // `countRawPositionWrites == 0` — §1's measured table counts THIS LOOP
        // among the file's raw writes. Resolved the way §2.5 already resolved
        // the forward: the same write, through the same primitive, on an
        // UNRECORDED batch. It stays a genuine oracle for W-d3c because it
        // restores from the command's own stored pre-op array while the delta
        // path replays the op-log's `posBefore` — two independent data paths
        // that share only the write primitive, which is what a mutation of the
        // RECORDING has to be measured against. Byte-identical to the loop it
        // replaces: `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one, and writing identical bits back was
        // what the loop did there; the bounds guard is the same `continue`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(touchedIdx_, touchedPrev_);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }

private:
    bool applyKernel(ref MeshEditBatch ed, const ref AimViewport aim) {
        // `dist` is an EXPLICIT command param (a real spatial radius),
        // not the interactive tool-pipe's "not yet picked" sentinel.
        // falloff.d's elementWeight() has a degenerate-radius fallback
        // (`pickedRadius <= 1e-9f` → return weight=1.0 EVERYWHERE) meant
        // to keep an in-flight interactive drag from dividing by zero
        // before ACEN/FalloffStage have placed a real radius — that
        // fallback must stay in place for the tool-pipe (`hasFalloff_`)
        // path. But feeding it dist<=0 straight from this command's own
        // param inverted the meaning: instead of "no local effect", it
        // became "affect the whole mesh" (task 0318 fuzz report). Reject
        // it as invalid input instead, mirroring the strength_ guard
        // above; a genuinely tiny-but-positive dist (e.g. 0.001) still
        // falls through to the normal sphere math and correctly no-ops
        // when nothing is within radius. HOISTED to `evaluate` at task 1903
        // L0-d1 (§2.4) together with the `strength_` guard it mirrors — the
        // reasoning above is unchanged, only the site is.

        // Build moving set (same mask as mesh.jitter).
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        // L1 funnel (task 0613, S5): the modal fan-in this used to open-code,
        // with the whole-mesh fallback narrowed to the VISIBLE vertices.
        bool[] vmask = mesh.operandVertexMask(editMode);

        int[] indices;
        foreach (i; 0 .. cast(int)mesh.vertices.length)
            if (vmask[i]) indices ~= i;

        // Build Element FalloffPacket (or use injected one from tool pipe).
        FalloffPacket fp;
        if (hasFalloff_) {
            fp = falloff_;
        } else {
            fp.type         = FalloffType.Element;
            fp.enabled      = true;
            fp.pickedCenter = center_;
            fp.pickedRadius = dist_;
            fp.connect      = ElementConnect.Ignore;
            fp.shape        = FalloffShape.Smooth;
            fp.anchorPos    = [center_];
            if (anchor_ >= 0)
                fp.anchorRing = [cast(uint)anchor_];
        }

        // THE ONE FORWARD IN L0-d THAT DOES NOT CHANGE. `applyMagnet` writes
        // `mesh.vertices[i]` raw at source/deform_magnet.d:64 and its signature
        // is Stage M / task 1905's, not ours — so this command records
        // EXPLICITLY instead. Under a recording batch that raw write produces
        // no op-log entry (the known `alias mesh this` hole), which is exactly
        // why magnet is the discriminating piece of L0-d: it is the only one of
        // the nine where "the write happened and nothing was recorded" is
        // representable at all, and the only one whose forward writer lives in
        // a module NEITHER census zone scans. `commit_seam_census_test.d`
        // therefore carries a two-sided `kAllow` row for deform_magnet.d AND
        // the `recordSetPos(` pin below — deleting this statement leaves every
        // count row green and only that pin red.
        applyMagnet(mesh, indices, target_, strength_, fp, aim,
                    touchedIdx_, touchedPrev_);

        if (touchedIdx_.length == 0) return false;

        if (ed.recording()) {
            // PRE-SIZED, NOT `reserve` + append (task 2160) — see the note
            // in `MeshEditBatch.setVertexPositions`: `reserve` removes the
            // reallocation, not the per-element runtime call.
            auto after = uninitializedArray!(Vec3[])(touchedIdx_.length);
            foreach (k, vi; touchedIdx_) after[k] = mesh.vertices[vi];
            // No `sameBits` filter here, unlike `setVertexPositions`: a
            // `w`-tiny vertex whose new value is bit-identical produces a
            // no-op cell, whose revert writes the same bits back. That is
            // precisely what the legacy loop below does unconditionally, so
            // the two paths stay byte-identical.
            // OWNERSHIP IS EXPLICIT AND ASYMMETRIC (task 2160). `after` was
            // built two lines up for this entry and nothing else refers to it,
            // so it is handed over. `touchedIdx_` and `touchedPrev_` are CLASS
            // FIELDS that the next `applyMagnet` refills — a delta aliasing
            // them would rewrite an installed history entry — so those two are
            // copied, here, where the reason is visible, rather than inside a
            // publisher that cannot know which of its arguments is which.
            ed.rec().recordSetPosOwned(touchedIdx_.dup, touchedPrev_.dup, after);
        }

        ed.commitChange(MeshEditScope.Position);
        return true;
    }
}
