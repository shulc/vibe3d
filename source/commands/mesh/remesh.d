module commands.mesh.remesh;

// ---------------------------------------------------------------------------
// Remesh — `mesh.remesh`, the undoable landing command for a completed
// RemeshJob (source/remesh/remesh_job.d). Mirrors commands/mesh/subdivide.d
// (whole-mesh replace via MeshSnapshot) and, for the redo-safety pattern,
// commands/ai3d/import_result.d: the FIRST apply() caches the job's result
// into instance fields (`cachedVertices_`/`cachedFaces_`) so a later redo
// (CommandHistory.redo() re-invokes apply()) rebuilds the SAME mesh even
// though the job itself has long since been cleared back to idle by then —
// this command never touches `job` again after that first read.
// ---------------------------------------------------------------------------

import std.algorithm.iteration : map;
import std.array : array;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import math : Vec3;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;
import params : Param;
import remesh.remesh_job : RemeshJob, RemeshParams,
                            MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;

final class Remesh : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate() onTopologyChange;
    private RemeshJob job;
    private MeshSnapshot snap;

    // Captured from `job` on the first apply() only — see module doc.
    private bool     captured_;
    private Vec3[]   cachedVertices_;
    private uint[][] cachedFaces_;

    // Set by evaluate() to reflect whether the LAST run actually swapped in a
    // new mesh (true) or rejected the result as a no-op (false). app.d's
    // tickRemeshJob reads this after runCommand so a GIGO reject (every face
    // dropped) reports an error instead of a false "Done".
    private bool     applied_;
    bool applied() const { return applied_; }

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange, RemeshJob job) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
        this.job = job;
    }

    override string name()  const { return "mesh.remesh"; }
    override string label() const { return "Remesh (Quad)"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    override Param[] params() { return []; } // driven entirely by the job result

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        applied_ = false;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        if (!captured_) {
            auto verts = job.resultVertices();
            auto faces = job.resultFaces();
            if (verts.length == 0 || faces.length == 0)
                return false; // nothing to apply — reject-is-a-no-op
            cachedVertices_ = verts.dup;
            cachedFaces_    = faces.map!(f => f.dup).array;
            captured_       = true;
        }

        // Full mesh snapshot — the kernel replaces the entire mesh (verts,
        // edges, faces, selection, etc.), same as mesh.subdivide.
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();

        Mesh result = Mesh.init;
        result.vertices = cachedVertices_.dup;
        uint[ulong] edgeLookup;
        foreach (face; cachedFaces_) {
            if (face.length < 3) continue;
            bool bad = false;
            foreach (idx; face)
                if (idx >= result.vertices.length) { bad = true; break; }
            if (bad) continue;
            result.addFaceFast(edgeLookup, face.dup);
        }
        result.buildLoops();

        // Defensive GIGO guard (mirrors mesh.subdivide's catmullClarkOsd
        // empty-result guard): every face was somehow degenerate/out of
        // range. Reject as a clean no-op rather than swap in an empty mesh.
        if (result.vertices.length == 0 || result.faces.length == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            refreshCaches();
            return false;
        }

        *mesh = result;
        mesh.resetSelection();
        // `*mesh = result` swap reset the fresh struct's version counters to
        // 0; noteChange (not commitChange) just needs the bus to know a
        // Geometry-scope change happened so caches rebuild.
        mesh.noteChange(MeshEditScope.Geometry);
        refreshCaches();
        applied_ = true;
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplayActive(mesh);
    }
}

// ---------------------------------------------------------------------------
// RemeshStart — `mesh.remesh.start`, the HTTP/menu-triggerable command that
// kicks off the async job (mirrors commands/ai3d/generate_test_hooks.d's
// Ai3dGenerateStartTestCommand, but production-usable rather than
// g_testMode-gated: unlike ai3d.generate, a remesh reads only the CURRENT
// mesh — there is no external network transfer to fake, so there is nothing
// test-unsafe about letting this run for real). CmdFlags.SideEffect: starting
// a background job is not itself a document mutation — the eventual
// `mesh.remesh` apply (fired by app.d once the job succeeds) is the one
// undoable entry.
// ---------------------------------------------------------------------------

final class RemeshStart : Command {
    private RemeshJob job;
    private int   targetQuadsArg = 20_000;
    private float adaptivityArg  = 1.0f;
    private float sharpEdgeArg   = 90.0f;

    this(Mesh* mesh, ref View view, EditMode editMode, RemeshJob job) {
        super(mesh, view, editMode);
        this.job = job;
    }

    override string name()  const { return "mesh.remesh.start"; }
    override string label() const { return "Remesh (Quad)…"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [
            // `.max(MAX_REMESH_TARGET_QUADS).enforceBounds()` matches the
            // kernel-side RemeshJob.start()/sanitizeParams() clamp — see
            // remesh_job.d. That clamp is the one that actually matters for
            // a headless argstring call; this Param bound is the UI-facing
            // mirror of it (slider + Ctrl-click text entry both stay sane).
            Param.int_("targetQuads", "Target Quads", &targetQuadsArg, 20_000)
                .min(MIN_REMESH_TARGET_QUADS).max(MAX_REMESH_TARGET_QUADS).enforceBounds(),
            Param.float_("adaptivity", "Adaptivity", &adaptivityArg, 1.0f)
                .min(0.0f).max(10.0f).enforceBounds(),
            Param.float_("sharpEdge", "Sharp Edge (deg)", &sharpEdgeArg, 90.0f)
                .min(0.0f).max(180.0f).enforceBounds(),
        ];
    }

    override bool apply() {
        if (job.busy())
            throw new Exception("mesh.remesh.start: a remesh job is already in flight");

        RemeshParams p;
        p.targetQuads = targetQuadsArg;
        p.adaptivity  = adaptivityArg;
        p.sharpEdge   = sharpEdgeArg;

        // Task 0385: a non-empty face selection switches RemeshJob into
        // region mode (remesh + boundary-pinned stitch of just the
        // selected faces); no selection keeps the existing whole-mesh
        // path. `hasAnySelectedFaces()` — not a raw `selectedFaces.length`
        // check — mirrors every other mesh command's "empty selection
        // means whole mesh" convention (see mesh.nothingSelected).
        const(bool)[] regionMask = mesh.hasAnySelectedFaces() ? mesh.selectedFaces : null;
        job.start(*mesh, p, regionMask);

        if (job.state() == RemeshJob.State.failed)
            throw new Exception("mesh.remesh.start: " ~ job.message());
        return true;
    }

    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// RemeshOpen — `mesh.remesh.open`, the `Remesh (Quad)…` menu action. Zero
// params (so app.d's tryOpenArgsDialog does NOT pop the generic args
// dialog — it runs directly on click, mirroring ai3d.generate.open). apply()
// only opens the modal via `onOpen`; app.d wires that to set
// remeshModalOpen/remeshModalPendingOpen and clear any stale error/summary
// text from a previous run. Never a document mutation — no undo entry.
// ---------------------------------------------------------------------------

final class RemeshOpen : Command {
    private void delegate() onOpen;

    this(Mesh* mesh, ref View view, EditMode editMode, void delegate() onOpen) {
        super(mesh, view, editMode);
        this.onOpen = onOpen;
    }

    override string name()  const { return "mesh.remesh.open"; }
    override string label() const { return "Remesh (Quad)…"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() { return []; }

    override bool apply() {
        if (onOpen !is null) onOpen();
        return false;
    }

    override bool revert() { return false; }
}
