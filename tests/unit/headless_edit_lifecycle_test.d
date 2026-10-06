module tests.unit.headless_edit_lifecycle_test;

import command : Command;
import command_history;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.headless : ToolHeadlessCommand;
import commands.mesh.mesh_edit_payload : MeshEditPayload, MeshRestorePolicy;
import mesh : Mesh, MeshInvocation, MeshEditBatch, makeCube, editBatchStackLength;
import mesh_edit_delta : MeshEditTracker, MeshEditDelta, MeshEditScope;
import math : Vec3;
import snapshot : MeshSnapshot;
import tool : Tool, ToolSessionPolicy, HeadlessSourcePolicy;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import application_command_binding : CommandInvocationContext, CommandInvocationOutcome;
import std.json : JSONValue;
import command : CommandOrigin;
import change_bus : changeBus;


private final class SourceTool : Tool {
    LiveRegistrationRig rig;
    float amount = 2;
    int failure;
    bool appendFace, appendVertex;
    size_t calls;
    bool retain;
    this(LiveRegistrationRig rig, bool retain = false) {
        this.rig = rig;
        this.retain = retain;
    }
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        auto p = super.sessionPolicy();
        p.headlessSource = retain ? HeadlessSourcePolicy.retainedPositions
                                 : HeadlessSourcePolicy.current;
        return p;
    }
    override bool applyHeadless() {
        ++calls;
        auto m = &rig.session.editMesh();
        auto input = headlessSourcePositions(m.vertices);
        if (appendVertex) m.addVertex(Vec3(9, 8, 7));
        else if (appendFace) m.addFace([0u, 1u, 2u]);
        else m.vertices[0].x = input[0].x + amount;
        m.commitChange(cast(uint)(appendVertex || appendFace
            ? MeshEditScope.Geometry : MeshEditScope.Position));
        if (failure == 1) return false;
        if (failure == 2) throw new Exception("headless kernel failure");
        if (failure == 3) m.endEditBatch();
        return true;
    }
}

private LiveRegistrationRig sourceRig(bool retain = false) {
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    rig.session.editMesh().syncSelection();
    rig.activeTool = new SourceTool(rig, retain);
    rig.editSession.noteArm(rig.activeToolId, rig.editSession.issueToken());
    return rig;
}

private Command invocation(LiveRegistrationRig rig, bool ephemeral = false) {
    if (!ephemeral) return rig.registry.makeCommand("tool.doApply");
    auto selected = rig.activeTool;
    return new ToolHeadlessCommand(&rig.session.editMesh(), rig.liveView(),
        rig.session.editMode, "probe.headless", () => selected);
}

private bool applyRegistered(LiveRegistrationRig rig, Command c) {
    return rig.executor.applyOrRefire(c, command_history.RecordMode.Record, null);
}

unittest { // Retained input and immediate inverse are independent images.
    auto rig = sourceRig(true);
    auto t = cast(SourceTool)rig.activeTool;
    auto m = &rig.session.editMesh();
    const x = m.vertices[0].x;
    const topology = m.topologyVersion;
    auto first = invocation(rig);
    assert(applyRegistered(rig, first) && m.vertices[0].x == x + 2);
    t.retain = false; // the session pinned this policy at arm
    t.amount = 5;
    assert(m.vertices[0].x == x + 2, "raw values must leave geometry inert");
    auto second = invocation(rig);
    assert(applyRegistered(rig, second));
    assert(m.vertices[0].x == x + 5, "retained source must survive the first output");
    assert(m.topologyVersion == topology, "source borrowing must be structure silent");
    assert(t.headlessSourcePositions(m.vertices).ptr == m.vertices.ptr,
        "source borrow escaped successful invocation");
    const undoneSecond = rig.history.undo();
    assert(m.vertices[0].x == x + 2, "actual Undo must restore visible first output");
    assert(undoneSecond);
    rig.activeTool = null;
    rig.host.getActiveTool = () { throw new Exception("closed replay consulted tool"); return cast(Tool)null; };
    assert(rig.history.redo(), "closed replay must use the retained payload");
    assert(m.vertices[0].x == x + 5 && t.calls == 2, "closed replay reevaluated the tool");
    assert(rig.history.undo() && rig.history.undo());
    assert(m.vertices[0].x == x, "actual Undo must restore the original input");
}

unittest { // Default source and ephemeral FULL restoration/replay.
    foreach (ephemeral; [false, true]) {
        auto rig = sourceRig();
        auto t = cast(SourceTool)rig.activeTool;
        auto m = &rig.session.editMesh();
        const x = m.vertices[0].x;
        assert(applyRegistered(rig, invocation(rig, ephemeral)));
        rig.activeTool = t;
        assert(applyRegistered(rig, invocation(rig, ephemeral)));
        assert(m.vertices[0].x == x + 4, "default clients must use current positions");
        auto calls = t.calls;
        assert(rig.history.undo());
        rig.activeTool = null;
        assert(rig.history.redo());
        assert(m.vertices[0].x == x + 4 && t.calls == calls,
            "ephemeral replay must not call its factory/kernel");
    }
}

private void rollbackCell(bool ephemeral, int failure, bool faces) {
    version (HeadlessFacesOnly) if (!faces) return;
    version (HeadlessEphemeralOnly) if (!ephemeral) return;
    version (HeadlessThrowOnly) if (failure != 2) return;
    auto rig = sourceRig();
    auto t = cast(SourceTool)rig.activeTool;
    auto m = &rig.session.editMesh();
    MeshEditTracker tracker;
    Mesh expected = makeCube();
    MeshEditTracker oracle;
    m.beginEditBatch(&tracker, MeshEditScope.Geometry);
    expected.beginEditBatch(&oracle, MeshEditScope.Geometry);
    if (faces) {
        m.addFace([0u, 1u, 2u]); expected.addFace([0u, 1u, 2u]);
    } else {
        m.addVertex(Vec3(3, 4, 5)); expected.addVertex(Vec3(3, 4, 5));
    }
    m.syncSelection(); expected.syncSelection();
    auto accepted = MeshSnapshot.capture(*m);
    t.appendFace = faces;
    t.appendVertex = !faces;
    t.failure = failure;
    auto c = invocation(rig, ephemeral);
    bool threw;
    try { assert(!applyRegistered(rig, c)); }
    catch (Exception e) { threw = true; }
    assert(threw == (failure == 2));
    assert(accepted.matches(*m), "rollback did not restore immediate geometry");
    assert(!c.undoRecorded() && !rig.history.canUndo(), "failure published an undo payload");
    t.failure = 0;
    t.appendFace = false;
    t.appendVertex = false;
    // A later admitted write still belongs to the original caller frame.
    m.addVertex(Vec3(6, 5, 4)); expected.addVertex(Vec3(6, 5, 4));
    m.syncSelection(); expected.syncSelection();
    auto delta = m.endEditBatch();
    auto wanted = expected.endEditBatch();
    assert(delta.log == wanted.log && delta.scope_ == wanted.scope_,
        faces ? "rollback must restore accepted AddFaces tail and prefix"
              : "rollback must restore accepted AddVerts tail and prefix");
    auto image = MeshSnapshot.capture(*m);
    delta.revert(*m);
    assert(m.vertices == makeCube().vertices && m.faces == makeCube().faces,
        "accepted prefix inverse must restore its real preimage");
    delta.apply(*m);
    assert(image.matches(*m), "accepted prefix forward lost its real image");
}

unittest { rollbackCell(false, 1, false); }
unittest { rollbackCell(false, 2, false); }
unittest { rollbackCell(false, 1, true); }
unittest { rollbackCell(false, 2, true); }
unittest { rollbackCell(true, 1, false); }
unittest { rollbackCell(true, 2, false); }
unittest { rollbackCell(true, 1, true); }
unittest { rollbackCell(true, 2, true); }

unittest { // Caller-owned frame cannot be closed inside invocation.
    auto rig = sourceRig();
    auto t = cast(SourceTool)rig.activeTool;
    auto m = &rig.session.editMesh();
    MeshEditTracker tracker;
    m.beginEditBatch(&tracker, MeshEditScope.Position);
    auto before = MeshSnapshot.capture(*m);
    t.failure = 3;
    bool threw;
    try { applyRegistered(rig, invocation(rig)); }
    catch (Exception e) { threw = true; }
    assert(threw, "invocation must protect caller frame lifetime");
    assert(before.matches(*m), "caller-close failure did not roll back geometry");
    t.failure = 0;
    assert(applyRegistered(rig, invocation(rig)), "recorded caller frame remains admitted");
    m.endEditBatch();
}

unittest { // Late label allocation/collaborator failure is inside rollback extent.
    auto rig = sourceRig(true);
    auto m = &rig.session.editMesh();
    auto t = cast(SourceTool)rig.activeTool;
    const x = m.vertices[0].x;
    assert(applyRegistered(rig, invocation(rig)));
    MeshEditTracker tracker;
    m.beginEditBatch(&tracker, MeshEditScope.Geometry);
    tracker.recordSetPosOwned([1u], [m.vertices[1]], [m.vertices[1]]);
    auto before = MeshSnapshot.capture(*m);
    rig.host.getActiveToolId = () { throw new Exception("late label failure"); return ""; };
    auto c = invocation(rig);
    bool threw;
    try { applyRegistered(rig, c); } catch (Exception e) { threw = true; }
    assert(threw && before.matches(*m), "late preparation must restore immediate geometry");
    assert(!c.undoRecorded(), "late preparation published payload before success");
    auto delta = m.endEditBatch();
    assert(delta.log.length == 1 && delta.log[0].vIdx == [1u],
        "late preparation corrupted accepted recorder prefix");
    assert(t.headlessSourcePositions(m.vertices).ptr == m.vertices.ptr,
        "source borrow escaped throw");
    rig.host.getActiveToolId = () => rig.activeToolId;
    t.amount = 7;
    assert(applyRegistered(rig, invocation(rig)));
    assert(m.vertices[0].x == x + 7, "failed preparation must preserve retained source");
}

unittest { // Failed cold source is not retained; successful rebind starts fresh.
    foreach (failure; [1, 2]) {
        auto rig = sourceRig(true);
        auto t = cast(SourceTool)rig.activeTool;
        auto m = &rig.session.editMesh();
        auto before = MeshSnapshot.capture(*m);
        t.failure = failure;
        try { assert(!applyRegistered(rig, invocation(rig))); }
        catch (Exception e) { assert(failure == 2); }
        assert(before.matches(*m));
        assert(t.headlessSourcePositions(m.vertices).ptr == m.vertices.ptr,
            "failed cold invocation retained borrow");
        m.vertices[0].x = 20;
        t.failure = 0;
        assert(applyRegistered(rig, invocation(rig)));
        assert(m.vertices[0].x == 22, "failed cold source became a published source");
        rig.editSession.noteArm(rig.activeToolId, rig.editSession.issueToken());
        assert(applyRegistered(rig, invocation(rig)));
        assert(m.vertices[0].x == 24, "rebind did not invalidate retained source");
    }
}

unittest { // Pending words/frame accumulator and other subjects survive failure.
    import mesh : g_isDocumentMesh, beginDeliveryBatchGlobal,
        endDeliveryBatchGlobal, deliveryPendingSetLength;
    auto rig = sourceRig();
    auto m = &rig.session.editMesh();
    auto t = cast(SourceTool)rig.activeTool;
    Mesh other = makeCube();
    auto filter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = filter;
    g_isDocumentMesh = (const(Mesh)* candidate) => candidate is m || candidate is &other;
    const subscribers = changeBus.meshSubscriberCheckpointForTest();
    scope(exit) changeBus.restoreMeshSubscribersForTest(subscribers);
    uint subjectFlags, otherFlags;
    changeBus.onMeshChanged((size_t subject, uint flags) nothrow {
        if (subject == cast(size_t)m) subjectFlags |= flags;
        if (subject == cast(size_t)&other) otherFlags |= flags;
    });
    beginDeliveryBatchGlobal();
    bool deliveryOpen = true;
    scope(exit) if (deliveryOpen) endDeliveryBatchGlobal();
    MeshEditTracker tracker;
    m.beginEditBatch(&tracker, MeshEditScope.Position);
    m.commitChange(MeshEditScope.Position);
    other.commitChange(MeshEditScope.Material);
    const queued = deliveryPendingSetLength();
    const topology = m.topologyVersion;
    const pending = m.undeliveredChanges_;
    const domains = m.undeliveredSelDomains_;
    t.appendVertex = true;
    t.failure = 1;
    assert(!applyRegistered(rig, invocation(rig)));
    assert(m.undeliveredChanges_ == pending && m.undeliveredSelDomains_ == domains,
        "rollback must restore preexisting pending delivery words");
    assert(queued == 1 && deliveryPendingSetLength() == queued + 1,
        "Command tail must queue earlier Position while retaining the other subject");
    assert(subjectFlags == 0 && otherFlags == 0,
        "no delivery before the outer closing brace");
    assert(m.endEditBatch().log.length == 0);
    assert(m.topologyVersion == topology, "rollback must restore caller frame accumulator");
    endDeliveryBatchGlobal();
    deliveryOpen = false;
    assert(subjectFlags == MeshEditScope.Position && otherFlags == MeshEditScope.Material,
        "failure delivery must retain earlier Position and the other subject only");
}

unittest { // A newly queued rejected subject is removed, without global reset.
    import mesh : g_isDocumentMesh, beginDeliveryBatchGlobal,
        endDeliveryBatchGlobal, deliveryPendingSetLength;
    auto rig = sourceRig();
    auto m = &rig.session.editMesh();
    auto t = cast(SourceTool)rig.activeTool;
    Mesh other = makeCube();
    auto filter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = filter;
    g_isDocumentMesh = (const(Mesh)* candidate) => candidate is m || candidate is &other;
    beginDeliveryBatchGlobal();
    bool deliveryOpen = true;
    scope(exit) if (deliveryOpen) endDeliveryBatchGlobal();
    other.commitChange(MeshEditScope.Position);
    const queued = deliveryPendingSetLength();
    t.appendVertex = true;
    t.failure = 2;
    bool threw;
    try { applyRegistered(rig, invocation(rig)); } catch (Exception e) { threw = true; }
    assert(threw && deliveryPendingSetLength() == queued,
        "rollback must remove only newly queued rejected subject");
    assert(other.undeliveredChanges_ == MeshEditScope.Position,
        "rollback must not erase another mesh pending words");
    endDeliveryBatchGlobal();
    deliveryOpen = false;
}

unittest { // Hide-derive pending membership is also per subject.
    import mesh : g_isDocumentMesh, hideDerivePendingSetContains;
    Mesh m = makeCube(), other = makeCube();
    auto filter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = filter;
    g_isDocumentMesh = (const(Mesh)* candidate) => candidate is &m || candidate is &other;
    other.beginHideDeriveBatch();
    assert(hideDerivePendingSetContains(&other));
    {
        auto transaction = MeshInvocation(m);
        m.addVertex(Vec3(4, 5, 6));
        assert(hideDerivePendingSetContains(&m), "hide queue positive control must admit subject");
    }
    assert(!hideDerivePendingSetContains(&m) && hideDerivePendingSetContains(&other),
        "rollback must remove new hide subject and retain earlier other subject");
    other.endHideDeriveBatch();
}

unittest { // Unrecorded/batchless, balanced inner batches remain admitted.
    foreach (recorded; [false, true]) {
        Mesh m = makeCube();
        MeshEditTracker tracker;
        m.beginEditBatch(recorded ? &tracker : null, MeshEditScope.Position);
        const depth = editBatchStackLength();
        {
            auto invocation = MeshInvocation(m);
            {
                auto inner = MeshEditBatch.unrecorded(m, MeshEditScope.Position);
                inner.setVertexPos(0, Vec3(2, 3, 4));
                inner.close();
            }
            invocation.validate();
            invocation.release();
        }
        assert(editBatchStackLength() == depth && m.vertices[0] == Vec3(2, 3, 4),
            "balanced inner batch must preserve caller frame and accepted output");
        auto delta = m.endEditBatch();
        assert((delta.log.length != 0) == recorded,
            "success must preserve original recording admission");
    }
}

unittest { // Selection and explicit close/navigation release the source receipt.
    import tool_activation_ownership : CloseReason, CommandDoor;
    foreach (boundary; [0, 1, 2]) {
        auto rig = sourceRig(true);
        auto m = &rig.session.editMesh();
        assert(applyRegistered(rig, invocation(rig)));
        if (boundary == 0) {
            rig.editSession.closeOperation(CloseReason.drop, CommandDoor.script);
            rig.editSession.finishClose();
        } else if (boundary == 1) {
            assert(rig.editSession.navigate(true));
        } else {
            m.selectVertex(0);
        }
        m.vertices[0].x = 30;
        assert(applyRegistered(rig, invocation(rig)));
        assert(m.vertices[0].x == 32, "source boundary must establish a fresh evaluation source");
    }
}

unittest { // Both snapshot directions keep live selection, with count fallback.
    Mesh m = makeCube();
    m.syncSelection();
    m.selectVertex(0);
    auto before = MeshSnapshot.capture(m);
    m.vertices[1].x = 8;
    auto after = MeshSnapshot.capture(m);
    auto payload = MeshEditPayload.snapshots(before, after, MeshRestorePolicy.geometryKeepSelection);
    m.clearVertexSelection(); m.selectVertex(2);
    payload.reverse(m);
    assert(m.isVertexSelected(2) && !m.isVertexSelected(0),
        "geometry inverse must keep live selection");
    payload.forward(m);
    assert(m.vertices[1].x == 8 && m.isVertexSelected(2) && !m.isVertexSelected(0),
        "geometry forward must keep live selection");
    m.addVertex(Vec3(7, 8, 9));
    m.syncSelection();
    payload.reverse(m);
    assert(m.vertices.length == 8 && m.isVertexSelected(0) && !m.isVertexSelected(2),
        "geometry restore must fall back to snapshot selection when counts differ");
}
