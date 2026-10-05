/// The topology-step client body shared by the session's topology tools
/// (`tool.TopologyStepClient`; task 9429, wave-2 plan §9.4). A tool supplies
/// its label, its basis field and — for the gizmo rebase — an optional
/// `afterTopologyRebase()` for its own derived state; nothing tool-specific
/// lives here. The mixin site resolves every name (the client module imports
/// `Mesh`, `MeshSnapshot`, `Command`, `AttrImage`, `GestureRecordMode`).
/// The topology pen keeps its own block (a captured fold law).
module tools.topology_step;

/// The interface members over `basisField`. A class member of the same name
/// (Mirror's and the short rebases, Polygon Extrude's `setTopologyDormant`)
/// hides the mixin's.
mixin template TopologyStepClientBody(string label, alias basisField) {
    override Mesh* topologyStepMesh() { return mesh; }
    override MeshSnapshot topologyStepBasis() { return basisField; }
    override Command topologyStepCarrier() {
        return gestureFactory is null ? null : gestureFactory();
    }
    override bool recordTopologyStep(Command cmd) {
        return recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
    override string topologyStepLabel() { return label; }
    override void setTopologyDormant(bool dormant) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot basis) {
        restoreRecordedAttrs(attrs);
        rebaseTopologyStep(basis);
    }
}

/// The rebase of a gizmo topology tool: the gizmo frame is computed on the
/// basis mesh (the visible mesh is put back), `built` follows the basis, the
/// drag state clears. A tool's own derived state goes in its declared
/// `afterTopologyRebase()` (the one allowed hook, plan §3.3).
mixin template GizmoTopologyRebase() {
    override void rebaseTopologyStep(MeshSnapshot basis) {
        before = basis;
        if (!before.matches(*mesh)) {
            auto visible = MeshSnapshot.capture(*mesh);
            before.restore(*mesh);
            computeGizmoFrame();
            visible.restore(*mesh);
        } else computeGizmoFrame();
        built = !before.matches(*mesh);
        static if (__traits(hasMember, typeof(this), "afterTopologyRebase"))
            afterTopologyRebase();
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }
}

/// Completed rows are already history-owned, so the framework's apply-and-
/// continue door has nothing pending; the command close re-bases in place.
mixin template SessionCommitHooks() {
    override bool commitUncommittedEdit() { return false; }
    override bool commitOperation() {
        if (!active) return false;
        resyncSession();
        return true;
    }
}
