module commands.mesh.gesture_payload;

// ---------------------------------------------------------------------------
// GesturePayload — the ONE thing the gesture recorder needs to know about an
// undo carrier (task 1905, phase B / group G1).
//
// WHY A QUERY AND NOT AN INSTALL SET. Revision 2 of the plan proposed the seam
// as a set of INSTALLERS — `installGesture(before, after, label)` plus
// `installGestureDelta(delta, label)` — and round 2 measured that shape against
// the four payload forms actually in the tree. Two of them are not expressible
// by it:
//
//   * `MeshVertexEdit.setEdit(uint[], Vec3[], Vec3[], string)` — a THIRD
//     install form (`commands/mesh/vertex_edit.d`), the one `xfrm.magnet` uses;
//   * `BoxLiveEditCommand` — built from the TOOL'S OWN STATE by a four-argument
//     constructor (`tools/create/box.d`), not by any setter at all.
//
// An installer set therefore has to grow a member per carrier class, which is
// the defect it was meant to remove: the fifth payload form widens the frozen
// interface again. So the seam is inverted. The TOOL fills its own carrier with
// whichever method that carrier has (`setSnapshots` / `setDelta` / `setEdit` /
// a constructor) and hands the recorder a command that is ALREADY COMPLETE. The
// only thing the recorder still has to ask is "is there anything to roll back",
// and that is one `const` query. A fifth payload form implements one method and
// breaks nothing.
//
// THE ANSWER IS PER CLASS, and it is not "is some array non-empty":
//
//   MeshSessionEdit      `useDelta_ || after.filled` — TWO arms, because the
//                        delta path never sets `after` at all. The predicate is
//                        extracted so `evaluate()` and this query read ONE
//                        expression; two copies of it would drift into the
//                        worst state available here, a command that RECORDED
//                        and then refuses on redo.
//   MeshVertexEdit       `!isEmpty()` — the existing index-count predicate.
//   BoxLiveEditCommand   the before/after params+state pair actually differ —
//                        the same comparison `BoxTool.sameLiveEdit` makes
//                        before it decides to open a live run.
//
// WHY AN INTERFACE AND NOT A BASE-CLASS METHOD. The three carriers have no
// common base but `Command`, and `Command` is shared with ~100 command classes
// that are not gesture payloads and have no business answering this. The cast
// that discovers it is the recorder's, and a carrier that does NOT implement it
// is a COUNTED refusal there, never a silent "treat null as empty" — the mesh
// is already mutated by the time the recorder is called, so a silent drop is
// the one outcome worse than a loud one.
// ---------------------------------------------------------------------------
interface GesturePayload {
    /// Is there anything in this carrier for undo to restore?
    ///
    /// FALSE means the tool built a carrier and put nothing in it — a
    /// programming error the recorder's belt refuses and counts, NOT the
    /// answer to "the gesture moved nothing". That second question is decided
    /// by the TOOL, which is the only side still holding the pre-image (see
    /// `tools/edit/edge_extend.d`'s delta / snapshot fork).
    bool hasGesturePayload() const;
}
