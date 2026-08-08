module commands.mesh.hide;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import seltype : SelType, isGeometryType, geometryEditMode;
import change_bus : MeshEditScope, SelDomain;

// doc/hide_geometry_plan.md Stage 2 (§1.2/§5) — mesh.hide / mesh.hideUnselected
// / mesh.hideInvert / mesh.unhideAll. Modeled on commands/mesh/subpatch_toggle.d.
//
// Two capture rounds back these commands, and the class citations below are
// deliberately kept apart because they measure DIFFERENT things:
//   * the C-series (C1/C2/C5/C6/C15/C16, §5.1) measured the PER-MODE target
//     sets and the vertex/edge derivation, each row starting from a clean
//     scene with nothing hidden;
//   * the accumulation series (M1CTRL/M1/M1ALT/M2CTRL/M2P/M2V/M3*) measured
//     what a hide does when something is ALREADY hidden — the one question a
//     clean-start row can never answer, because union and replace are
//     bit-identical there. Evidence lives in the task's private capture
//     tree (driver + per-case JSON), one fresh process per case, each
//     measurement paired with a clean-state control.
// Every citation below names a case that actually measured the claim next to
// it; a rule with no case is labelled DERIVED in so many words.
// All four write ONLY the face plane (the authoritative one, §1.2) and then
// call mesh.refreshHiddenDerived() — the derived vertex/edge planes and their
// OWN half of the Select ∧ Hide = ∅ invariant (§3.1) are already handled by
// Stage 0's refreshHiddenDerived()/setFaceHiddenFrom(); this stage owes only
// the FACE-plane half of that invariant, and setFaceHiddenFrom already clears
// it in the same word write (Stage 0, mesh.d ~5175-5197) — no extra code
// needed here for that half either. What IS this stage's job: the per-mode
// command semantics (measured, §1.2/§5.1) and undoing a hide + the selection
// drop it causes as ONE entry (§1.5, C9).

// --- shared target-set computation (§1.2/§5.1) ------------------------------

// The vertex set a Vertices/Edges-mode selection resolves to, for the
// face-touch tests below. Edges mode resolves each selected edge to its two
// endpoints — measured equivalent to selecting both endpoints directly
// (§5.1: hiding from an edge selection lands on the same faces as hiding
// from that edge's two endpoints). Polygons mode never calls this — its face set
// comes straight from the face selection, not through a vertex resolution.
private bool[] selectedVertexMaskForMode(Mesh* mesh, EditMode mode) {
    auto vmask = new bool[](mesh.vertices.length);
    if (mode == EditMode.Vertices) {
        foreach (vi; 0 .. mesh.vertices.length)
            vmask[vi] = mesh.isVertexSelected(vi);
    } else if (mode == EditMode.Edges) {
        foreach (ei; 0 .. mesh.edges.length) {
            if (!mesh.isEdgeSelected(ei)) continue;
            const e = mesh.edges[ei];
            if (e[0] < vmask.length) vmask[e[0]] = true;
            if (e[1] < vmask.length) vmask[e[1]] = true;
        }
    }
    return vmask;
}

// mesh.hide's per-face target set: Polygons mode = the selected faces;
// Vertices/Edges mode = every face touching ANY vertex in the resolved
// selection (propagation UP, never down — hiding two faces of a cube never
// hides a vertex that still touches a third visible face, §1.2). An empty
// selection in ANY mode hides everything (C6, the project's existing
// nothingSelected convention — no separate branch needed).
// Task 0621: `Item` is current ⇒ NO geometry type is ⇒ there is no CURRENT
// geometry selection, which is the SAME case as "nothing selected" and shares
// its branch below rather than adding a second one. (Two reasons it is one
// branch and not two: it is one rule — see THE RULE on Command.currentType()
// — and the operand-mask gate, tests/test_operand_mask_gate.d, allows this
// file exactly ONE whole-mesh fill and expects it within three lines of the
// sizing, so a second fill or a comment wedged between the two would either
// trip the gate or, worse, hide this one from it.) Under Item this is the
// answer the command already gave by ACCIDENT whenever the stale selection
// happened to be empty; what changes is that a selection left over from
// before the item switch no longer scopes the hide to geometry the user
// cannot see selected.
private bool[] hideSelectedTargets(Mesh* mesh, SelType type) {
    auto fmask = new bool[](mesh.faces.length);
    if (!isGeometryType(type) || mesh.nothingSelected(geometryEditMode(type))) {
        fmask[] = true;   // whole-mesh: gate-visible, sized 2 lines above
        return fmask;
    }
    const mode = geometryEditMode(type);
    if (mode == EditMode.Polygons) {
        foreach (fi; 0 .. mesh.faces.length)
            fmask[fi] = mesh.isFaceSelected(fi);
        return fmask;
    }
    auto vsel = selectedVertexMaskForMode(mesh, mode);
    foreach (fi, face; mesh.faces)
        foreach (vi; face)
            if (vi < vsel.length && vsel[vi]) { fmask[fi] = true; break; }
    return fmask;
}

// --- mesh.hideInvert's two operands (task 0628) -----------------------------
//
// The invert is COMPONENT-TYPED: it flips the plane the CURRENT SELECTION TYPE
// names. Polygons mode flips the face plane directly (below, in the command).
// Vertices/Edges mode flips the VERTEX plane and propagates UP — these two
// helpers are that half.

// The vertex plane, FLIPPED. Read through `isVertexHidden`, which for a
// face-bound vertex is the value `Mesh.refreshHiddenDerived()` last derived
// (every incident face hidden) and for a loose point is its own stored bit.
// Both are the vertex plane, so both flip.
private bool[] invertedVertexPlane(Mesh* mesh) {
    auto vhid = new bool[](mesh.vertices.length);
    foreach (vi; 0 .. mesh.vertices.length) vhid[vi] = !mesh.isVertexHidden(vi);
    return vhid;
}

// Propagate a vertex-plane state UP onto faces: a face is hidden iff ANY of
// its vertices is hidden. Same ANY rule `hideSelectedTargets` uses for a
// Vertices/Edges-mode hide, and MEASURED for the invert specifically: from a
// 3x3 grid with the corner polygon hidden, the vertex plane holds exactly that
// corner's valence-1 vertex, so the flip holds the other 15 of 16 — and every
// one of the 9 polygons touches at least one of those 15, which is why the
// reference reads EVERY polygon hidden. Under an ALL rule the corner polygon
// (one of its four vertices is the un-flipped one) would read VISIBLE, and the
// measured set says hidden. The frozen fixture pins the same discriminator:
// tests/fixtures/hide_invert_vertex_mark.json's post-invert set contains the
// probe vertex's own polygon while the probe vertex itself is not in the
// flipped set.
//
// REPLACE, not union — the propagation result IS the new face plane. Measured
// by the same fixture: a polygon hidden BEFORE the invert whose vertices all
// leave the flipped set (the disconnected spare) comes back VISIBLE. Together
// with unhide, this is the only command that CLEARS Hide bits.
private bool[] facesTouchingHiddenVertices(Mesh* mesh, const bool[] vhid) {
    auto fmask = new bool[](mesh.faces.length);
    foreach (fi, face; mesh.faces)
        foreach (vi; face)
            if (vi < vhid.length && vhid[vi]) { fmask[fi] = true; break; }
    return fmask;
}

// mesh.hideUnselected's KEEP-VISIBLE set — the complement of the set above,
// but NOT the face-by-face negation of the ANY rule (that reads the WRONG
// count in Vertices/Edges mode — §1.2, T-S2b: selecting one face's 4
// vertices and negating ANY leaves 5 faces visible; the measured rule keeps
// exactly 1, the face whose vertices are ALL selected). Polygons mode: keep
// exactly the selected faces (the plain complement, C5). Vertices/Edges
// mode: keep only faces whose vertices are ALL in the resolved selection.
// An empty selection keeps nothing in either branch (no face is selected /
// no face has all-empty-set-membership), so it hides everything too — same
// C6 convention as mesh.hide, falling out without a separate branch.
private bool[] keepVisibleTargets(Mesh* mesh, SelType type) {
    auto keep = new bool[](mesh.faces.length);
    // Item is current ⇒ no CURRENT geometry selection (task 0621), so the
    // keep set is empty and the isolate hides everything — the same landing
    // point the empty-selection case already had in both branches below, and
    // consistent with mesh.hide's Item answer above.
    if (!isGeometryType(type)) return keep;
    const mode = geometryEditMode(type);
    if (mode == EditMode.Polygons) {
        foreach (fi; 0 .. mesh.faces.length)
            keep[fi] = mesh.isFaceSelected(fi);
        return keep;
    }
    auto vsel = selectedVertexMaskForMode(mesh, mode);
    foreach (fi, face; mesh.faces) {
        bool all = face.length > 0;
        foreach (vi; face)
            if (!(vi < vsel.length && vsel[vi])) { all = false; break; }
        keep[fi] = all;
    }
    return keep;
}

// --- shared capture/revert (§1.5, C9) ---------------------------------------
// A hide and the selection drop it silently causes must undo as ONE Ctrl+Z,
// not two. All three marks arrays are captured WHOLE (not just the Hide
// bit), so revert() restores every bit a hide could have touched — Select on
// any of the three planes included — in a single word-array swap. No second
// command, no second undo entry: this command's own revert() is the whole
// mechanism (matches the precedent Stage 0 already set inside
// refreshHiddenDerived()/setFaceHiddenFrom(), which clear Select in the SAME
// write that sets Hide, rather than depending on a second, separate pass).
//
// The three *SelectionOrder arrays ride along, and that is NOT belt-and-
// braces (code review BLOCKER). The apply path zeroes an element's order
// STAMP in the same word write that drops its Select bit (mesh.d,
// setFaceHiddenFrom / refreshHiddenDerived). Restoring marks alone therefore
// hands back elements that read "selected" with order 0 — selected, but
// never picked — and every order-consuming command then silently does
// nothing with them: select.between and select.more find no ordered pair to
// extrapolate from, select.less finds no most-recent element to drop, and
// mesh.makePolygon derives the new polygon's WINDING from
// vertexSelectionOrder, so an undone hide would leave it building faces in
// arbitrary vertex order. Same capture set as snapshot.d's
// SelectionSnapshot, for exactly this reason.
//
// The three counters ride along too. Nothing on the hide path advances or
// resets one, so within a single apply/revert pair they are invariant — but
// this revert() is not guaranteed to run against the state it captured. A
// hide is UI-undo class (cmdFlags below), and command_history's class-aware
// stepping carries a UI entry INERT past a Model undo, so an intervening
// Model command can run clearFaceSelection() — which resets the counter to
// 0 — before this entry is ever reverted. Restoring the stamps but not the
// counter would then leave counter=0 underneath live stamps of 1..N, and the
// next selectFace() would hand out a stamp that COLLIDES with an existing
// one: two elements claiming the same pick position, which is precisely the
// ambiguity the stamps exist to resolve. Restoring the counter alongside the
// stamps it belongs to keeps "counter >= every live stamp" true by
// construction, in both directions.
private mixin template HideRevertCommon() {
    private uint[] origVertexMarks_;
    private uint[] origEdgeMarks_;
    private uint[] origFaceMarks_;
    private int[]  origVertexOrder_;
    private int[]  origEdgeOrder_;
    private int[]  origFaceOrder_;
    private int    origVertexOrderCounter_;
    private int    origEdgeOrderCounter_;
    private int    origFaceOrderCounter_;
    private bool   captured_;

    // Snapshot ONLY — this does not arm revert(). captured_ is set by
    // commitCapture_() after the mutation has actually landed (code review
    // NIT): an evaluate() that snapshots and then takes its no-op early-out
    // changed nothing, and must not leave revert() willing to write a stale
    // capture back over marks that a later command legitimately changed.
    private void captureMarks_() {
        origVertexMarks_ = mesh.vertexMarks.dup;
        origEdgeMarks_   = mesh.edgeMarks.dup;
        origFaceMarks_   = mesh.faceMarks.dup;
        origVertexOrder_ = mesh.vertexSelectionOrder.dup;
        origEdgeOrder_   = mesh.edgeSelectionOrder.dup;
        origFaceOrder_   = mesh.faceSelectionOrder.dup;
        origVertexOrderCounter_ = mesh.vertexSelectionOrderCounter;
        origEdgeOrderCounter_   = mesh.edgeSelectionOrderCounter;
        origFaceOrderCounter_   = mesh.faceSelectionOrderCounter;
    }

    // Arm revert(). Called as the last act of a successful evaluate().
    private void commitCapture_() { captured_ = true; }

    override bool revert() {
        if (!captured_) return false;
        mesh.vertexMarks = origVertexMarks_.dup;
        mesh.edgeMarks   = origEdgeMarks_.dup;
        mesh.faceMarks   = origFaceMarks_.dup;
        mesh.vertexSelectionOrder = origVertexOrder_.dup;
        mesh.edgeSelectionOrder   = origEdgeOrder_.dup;
        mesh.faceSelectionOrder   = origFaceOrder_.dup;
        mesh.vertexSelectionOrderCounter = origVertexOrderCounter_;
        mesh.edgeSelectionOrderCounter   = origEdgeOrderCounter_;
        mesh.faceSelectionOrderCounter   = origFaceOrderCounter_;
        // Every plane was captured/restored WHOLE — Select included — so
        // notify all three selection domains regardless of which one this
        // particular command actually touched. Cheap (edit-path, not
        // per-frame) and correct even for hideInvert's whole-mesh flip or
        // a Vertices/Edges-mode hide that only ever wrote faceMarks
        // directly but moved Select on the derived vertex/edge planes too.
        mesh.noteSelectionChange(SelDomain.Vertex);
        mesh.noteSelectionChange(SelDomain.Edge);
        mesh.noteSelectionChange(SelDomain.Face);
        // Visibility + the topologyVersion bump, for the same reasons the
        // FORWARD path carries them (Mesh.setFaceHiddenFrom / setFaceHidden,
        // S3): hidden geometry is filtered out of the GPU buffers at UPLOAD
        // time, so putting it back has to re-upload, and the marks-class
        // `Marks` alone is deliberately not a display-refresh trigger.
        //
        // Named HERE rather than inherited from a writer because this revert
        // restores all three marks arrays WHOLESALE — `mesh.faceMarks =
        // orig.dup` — and so goes through no Hide writer at all. That is the
        // same shape as MeshSnapshot.restore (which reaches the same place via
        // MeshChangeAll), and the same reason plan R13 says the Hide feature
        // may own no bookkeeping outside the three marks arrays.
        //
        // MEASURED: without this, hiding a cube face dropped the face VBO from
        // 36 to 30 verts and Ctrl+Z left it at 30 — the geometry came back in
        // the model and stayed invisible on screen.
        mesh.commitChange(MeshEditScope.Marks | MeshEditScope.Visibility);
        ++mesh.topologyVersion;
        return true;
    }

    // §1.5: Hide changes which part of the mesh the user is working
    // through, not the mesh's content — same reading that puts
    // layer.select in the UI-undo class. Lands on the stack, Ctrl+Z
    // undoes it, but a plain geometry undo (Model class) steps past it.
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }
}

/// Hide Selected. Per-mode target sets (§1.2/§5.1, C1/C2/C6): Polygons mode
/// hides the selected faces; Vertices/Edges mode hides every face touching
/// any selected vertex; an empty selection hides everything.
///
/// ADDITIVE — the target set is UNIONed onto whatever was already hidden,
/// never replacing it, so faces hidden by an earlier call stay hidden. This
/// is MEASURED, not derived, and the C-series above cannot show it (every
/// C row starts from a clean scene, where union and replace agree bit for
/// bit). The accumulation cases: M2P hides one corner polygon and then a
/// second in POLYGON mode and reads 2 hidden; M2V repeats it with the second
/// hide driven from VERTEX mode and also reads 2; the clean-state control
/// M2CTRL hides only the second corner and reads 1. A replace rule reads 1
/// in all three, so the pair separates them, and the same law holds in both
/// modes. Un-hiding is what Unhide All / Invert Hidden are for.
class MeshHide : Command, Operator {
    mixin OperatorActrCommon;
    mixin HideRevertCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "mesh.hide"; }
    override string label() const { return "Hide Selected"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        mesh.syncSelection();
        captureMarks_();

        auto target = hideSelectedTargets(mesh, subj.selType);
        auto merged = new bool[](mesh.faces.length);
        bool changed = false;
        foreach (fi; 0 .. mesh.faces.length) {
            bool was = mesh.isFaceHidden(fi);
            merged[fi] = was || target[fi];
            if (merged[fi] != was) changed = true;
        }
        if (!changed) return false;   // no-op rejection (Operator contract)

        mesh.setFaceHiddenFrom(merged);
        mesh.commitChange(MeshEditScope.Marks);
        mesh.refreshHiddenDerived();
        commitCapture_();
        return true;
    }
}

/// Hide Unselected — isolate. The KEEP-visible rule (§1.2/§5.1, C5) is
/// keepVisibleTargets() above; the accumulation control M1CTRL re-measured
/// it on a 3x3 grid from a clean scene — a 4-vertex selection isolates down
/// to exactly the one polygon those vertices bound, which is the ALL-
/// selected rule and not the negation of the ANY rule.
///
/// ADDITIVE, exactly like Hide Selected: the complement of the keep set is
/// UNIONed onto the already-hidden set, and an isolate NEVER clears a bit
/// that was already set — not even for a face that lands back in the keep
/// set. MEASURED by two cases with OPPOSITE numeric signatures, so neither
/// a stuck "always hide more" nor a stuck "always replace" can pass both:
///   * M1    — hide the grid's centre polygon, then isolate it via a vertex
///             selection whose keep set is exactly that centre. Replace
///             predicts 1 visible, union predicts 0. Measured 0.
///   * M1ALT — hide the centre, then isolate with EVERY vertex selected, so
///             the keep set is every polygon and the only question left is
///             whether the standing bit survives. Replace predicts 0 hidden,
///             union predicts 1. Measured 1.
///
/// Consequence, and deliberately NOT guarded against: isolating onto a
/// target that is already hidden blanks the mesh, because H ∪ ¬K then covers
/// everything. That is the measured behaviour, not an accident of this
/// implementation; the mitigation is a hidden-count readout in a later
/// stage, not a special case here.
class MeshHideUnselected : Command, Operator {
    mixin OperatorActrCommon;
    mixin HideRevertCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "mesh.hideUnselected"; }
    override string label() const { return "Hide Unselected"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        mesh.syncSelection();
        captureMarks_();

        auto keep = keepVisibleTargets(mesh, subj.selType);
        auto target = new bool[](mesh.faces.length);
        bool changed = false;
        foreach (fi; 0 .. mesh.faces.length) {
            // UNION, not replace (M1/M1ALT) — `was ||` is the whole law: a
            // face already hidden stays hidden even when keep[fi] is true.
            bool was = mesh.isFaceHidden(fi);
            target[fi] = was || !keep[fi];
            if (target[fi] != was) changed = true;
        }
        if (!changed) return false;   // no-op rejection (Operator contract)

        mesh.setFaceHiddenFrom(target);
        mesh.commitChange(MeshEditScope.Marks);
        mesh.refreshHiddenDerived();
        commitCapture_();
        return true;
    }
}

/// Invert Hidden — COMPONENT-TYPED (task 0628). It flips the plane the CURRENT
/// SELECTION TYPE names, not always the polygon plane. What is SELECTED never
/// enters the rule in any mode (§5.1, M3C: it flips identically with nothing
/// selected at all) — only the selection TYPE does.
///
///   * Polygons — flip every face's Hide bit (M3B, M3E_polygon: from a clean
///     3x3 grid the invert hides all 9 polygons; with one already hidden it
///     leaves exactly that one visible and hides the other 8).
///   * Vertices / Edges — flip the VERTEX plane and propagate UP (M3, M3C,
///     M3E_vertex, M3E_edge: with one corner polygon hidden the flipped vertex
///     plane holds 15 of 16 vertices and EVERY polygon comes out hidden).
///     The two modes share one branch because they measured identical: an edge
///     mode invert lands on the vertex plane exactly as vertex mode does.
///   * Item — nothing at all (M3E_item). A no-op rejection, so it lands no
///     undo entry either; `subj.selType` is the authority (task 0621's rule on
///     `Command.currentType()`), not the derived `editMode`, which under Item
///     still reads the pre-switch geometry mode.
///
/// This is the ONLY command besides Unhide All that CLEARS Hide bits, in both
/// geometry branches.
///
/// WHAT THIS DOES *NOT* REPRODUCE, and why it is not an oversight -----------
/// The reference derives its vertex plane INCREMENTALLY, over the elements an
/// operation touches, so its invert writes the vertex plane directly and
/// leaves exactly the entries whose derived value it contradicts STALE: right
/// after a Vertices-mode invert, a vertex whose only polygon just became hidden
/// still reads NOT hidden, and stays that way until a hide touches that
/// specific vertex. Measured and frozen (fixture
/// tests/fixtures/hide_invert_vertex_mark.json — seven trigger rows; two of
/// them flip that vertex while changing no polygon bit at all, and a real hide
/// applied to an unrelated disconnected polygon leaves it stale).
///
/// Our vertex plane is derived TOTALLY: `Mesh.refreshHiddenDerived()` recomputes
/// it from the face plane after every mutation, so we have no stale window.
/// DECISION: keep it that way. The staleness is an artifact of how the
/// reference derives, not a behaviour anyone designed, and a user meeting it
/// would report it as a bug.
///
/// The consequences, stated so nobody has to rediscover them:
///   * the FACE set matches the reference in every mode — the typed branch is
///     what the face plane depends on, and it is expressible with no change to
///     who owns the vertex plane (see below);
///   * the VERTEX plane read immediately after a Vertices/Edges-mode invert
///     differs by exactly the contradicted entries: we read 1 (derived from
///     the now-hidden face) where the reference reads 0 (its own stale write);
///   * consequently a Vertices/Edges-mode invert is NOT an involution here,
///     while it is in the reference: pressing it twice does not return to the
///     starting hidden set, because the first invert's total re-derivation
///     loses the distinction its flipped vertex plane carried. Ctrl+Z is the
///     path back — `HideRevertCommon` restores all three marks planes exactly —
///     and Polygons mode, being a plain face flip, IS an involution.
///
/// EXPRESSIBILITY (the question this task was told to answer): the typed
/// invert needs NO independently-writable vertex plane. The flipped plane is a
/// LOCAL value — `invertedVertexPlane` reads it, `facesTouchingHiddenVertices`
/// propagates it up, and only the FACE plane is written. `refreshHiddenDerived`
/// then re-derives the vertex plane from those faces. So the model change Ph1
/// anticipated (make the vertex plane authoritative, propagate upward) is not
/// required to match the component typing; it would only be required to
/// reproduce the stale window, which is the part we are deliberately not
/// reproducing. The one exception is a LOOSE point, which has no face to
/// propagate to and whose own bit is already independently writable
/// (`Mesh.setVertexHidden`) — those are written directly.
class MeshHideInvert : Command, Operator {
    mixin OperatorActrCommon;
    mixin HideRevertCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "mesh.hideInvert"; }
    override string label() const { return "Invert Hidden"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Item mode: the invert touches no component marks (M3E_item). A no-op
        // rejection rather than an empty apply, so it records no undo entry —
        // the Operator contract's own "nothing happened" channel.
        if (!isGeometryType(subj.selType)) return false;
        const mode = geometryEditMode(subj.selType);

        // No-op rejection, per operand: the polygon branch needs a face to
        // flip, the vertex branch needs a vertex. They differ because the
        // vertex branch is defined on a mesh with no faces at all (a cloud of
        // loose points is a legal vertex plane, and flipping it is exactly
        // what a Vertices-mode invert means there).
        if (mode == EditMode.Polygons) { if (mesh.faces.length    == 0) return false; }
        else                           { if (mesh.vertices.length == 0) return false; }

        mesh.syncSelection();
        captureMarks_();

        bool[] target;
        if (mode == EditMode.Polygons) {
            target = new bool[](mesh.faces.length);
            foreach (fi; 0 .. mesh.faces.length)
                target[fi] = !mesh.isFaceHidden(fi);
        } else {
            auto vflip = invertedVertexPlane(mesh);
            target = facesTouchingHiddenVertices(mesh, vflip);
            // Loose points have no face to carry their half of the flip, so
            // their own bit IS the result and is written directly.
            // `setVertexHidden` refuses a vertex that has an incident face by
            // contract (its Hide bit is derived), which is exactly the split
            // wanted here — the returned bool says which half each vertex fell
            // in, and the face-bound half is already accounted for by `target`.
            foreach (vi; 0 .. vflip.length)
                cast(void) mesh.setVertexHidden(vi, vflip[vi]);
        }

        mesh.setFaceHiddenFrom(target);
        mesh.commitChange(MeshEditScope.Marks);
        mesh.refreshHiddenDerived();
        commitCapture_();
        return true;
    }
}

/// Unhide All — after this, NOTHING in the mesh is hidden, on any plane.
///
/// Stage 0 left exactly one question open for this command (mesh.d,
/// clearHidden): a LOOSE vertex — one with no incident face — carries its
/// own settable Hide bit that the derivation deliberately never touches, and
/// clearHidden deferred the "does an unhide clear it?" call to here.
/// DECISION: yes, it clears it, and the no-op guard counts it. Two reasons:
///   (a) "Unhide All" is a total promise, and a bit this command skipped
///       would be unreachable — setVertexHidden is that bit's only writer
///       and refreshHiddenDerived steps over loose vertices by design, so
///       hidden state on a loose point would be a one-way trap with no
///       command anywhere able to undo it;
///   (b) a guard that asks only about FACES makes the command refuse to run
///       in precisely the state that needs it — a mesh whose only hidden
///       thing is a loose point.
/// The clearing itself lives in Mesh.clearHidden(), one masked pass per
/// plane (`&= ~Marks.Hide`, never `= 0` — Select and Subpatch share those
/// words), rather than being open-coded here reaching into another module's
/// mark planes.
///
/// This is a DERIVED decision, and labelled as such: the capture pinned that
/// a loose point survives a POLYGON hide (§5.1, C15) but never ran an unhide
/// with a loose point hidden, so there is no measurement to cite either way.
///
/// ONE command, not two — the reference's `mode` argument (0="sel", 1="all")
/// measured IDENTICAL across six rigs (§5, §9), so no distinction is
/// invented here.
class MeshUnhideAll : Command, Operator {
    mixin OperatorActrCommon;
    mixin HideRevertCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "mesh.unhideAll"; }
    override string label() const { return "Unhide All"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        // No-op rejection: nothing is hidden on ANY plane. Faces alone is
        // not enough (see the DECISION above) — a hidden loose vertex leaves
        // the face plane clean, and asking only about faces would refuse the
        // one command able to clear it. The edge plane is in the guard for
        // the same totality reason: it is derived, so a set edge bit with no
        // hidden vertex behind it is stale, and this command is what heals
        // it (clearHidden's own refresh recomputes the derived planes).
        if (!mesh.hasAnyHiddenFaces() &&
            !mesh.hasAnyHiddenVertices() &&
            !mesh.hasAnyHiddenEdges()) return false;

        mesh.syncSelection();
        captureMarks_();
        mesh.clearHidden();
        commitCapture_();
        return true;
    }
}
