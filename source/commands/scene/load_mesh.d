module commands.scene.load_mesh;

import command;
import math : Vec3;
import mesh;
import view;
import editmode;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;
import change_bus : MeshChangeAll;

/// Replace the current mesh with a caller-supplied raw mesh (test-only,
/// driven by `POST /api/load-mesh`). Mirrors `SceneReset`: snapshots the
/// pre-load mesh for undo, swaps in the new geometry, rebuilds every
/// derived structure (edges, half-edge loops, selection/mark/material
/// arrays), clears the selection, and refreshes the GPU + screen-space
/// caches — i.e. the same consistent post-load state `/api/reset` leaves
/// behind, just with a caller-supplied mesh instead of a primitive.
///
/// Validation (degree >= 3, indices in range) happens in `apply()` BEFORE
/// the live mesh is touched, so a bad payload leaves the scene untouched.
class MeshLoadRaw : Command {
    private EditMode*        editModePtr;
    private View*            viewPtr;
    private void delegate()  onResetTool;

    private Vec3[]   newVerts;
    private uint[][] newFaces;

    private MeshSnapshot snap;
    private EditMode     prevEditMode;
    // Funnel hook: when installed (app factory), apply/revert route the editMode
    // write through promoteGeometryType so selTypeOrder stays in lockstep.
    // Null in headless/unit construction — the raw-pointer fallback is used then.
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode,
         EditMode* editModePtr, View* viewPtr,
         void delegate() onResetTool) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
        this.viewPtr     = viewPtr;
        this.onResetTool = onResetTool;
    }

    override string name() const { return "scene.loadMesh"; }

    // Task 1521: a raw mesh load REPLACES `*mesh` wholesale.
    override bool discardsUnsavedWork() const { return true; }
    override string label() const { return "Load mesh"; }

    /// Supply the raw geometry to load. Caller owns/builds these arrays;
    /// they are validated against each other (index range) in apply().
    void setData(Vec3[] verts, uint[][] faces) {
        this.newVerts = verts;
        this.newFaces = faces;
    }

    /// Install the funnel hook so apply/revert route the editMode write through
    /// promoteGeometryType (touches selTypeOrder before the field write). Returns
    /// `this` for chaining. Null (default) = raw-pointer fallback for headless.
    MeshLoadRaw setPromoteHook(void delegate(EditMode) hook) {
        this.promoteType = hook;
        return this;
    }

    protected override bool applyImpl() {
        // ---- Validate BEFORE mutating any live state ----
        immutable uint vcount = cast(uint)newVerts.length;
        foreach (fi, ref f; newFaces) {
            if (f.length < 3)
                throw new Exception("face " ~ itoa(fi) ~
                    " has fewer than 3 vertices");
            foreach (vi; f)
                if (vi >= vcount)
                    throw new Exception("face " ~ itoa(fi) ~
                        " references vertex index " ~ itoa(vi) ~
                        " out of range (vertexCount=" ~ itoa(vcount) ~ ")");
        }

        // ---- Disarm the active tool BEFORE anything reads or writes the mesh
        // (task 3130). Identical shape and identical reason to
        // `SceneReset.applyImpl`: `*mesh = m` below replaces the geometry in
        // place and `onResetTool()` — the tool drop, i.e. the session commit
        // point — only fires afterwards, so an armed gesture used to run its
        // kernel against the just-loaded mesh. Validation above deliberately
        // stays first: a load that REFUSES must not disarm the user's tool.
        {
            import tool_disarm : disarmActiveToolBeforeDocumentReplace;
            disarmActiveToolBeforeDocumentReplace();
        }
        // ---- Snapshot for undo, then swap geometry in ----
        snap         = MeshSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        prevEditMode = *editModePtr;

        Mesh m;
        m.vertices = newVerts.dup;
        // FaceList.alias-this accepts a uint[][]; dup so the command owns
        // independent storage from the caller's parsed arrays.
        uint[][] facesCopy = new uint[][](newFaces.length);
        foreach (i, ref f; newFaces) facesCopy[i] = f.dup;
        m.faces = facesCopy;
        // Same finalization the mesh factories (makeCube etc.) use:
        // buildLoops() rebuilds the half-edge structure and the
        // deduplicated edge list; resetSelection() (re)sizes + clears the
        // per-element selection / mark / subpatch / material arrays.
        m.rebuildEdgesFromFaces();
        m.buildLoops();
        m.resetSelection();
        // Corner-provenance (task 0901): verified NOT APPLICABLE. `m` is a
        // fresh `Mesh` (declared a few lines above, never had a PolyVertex
        // map) and `*mesh = m` REPLACES the whole value — same whole-mesh
        // replace shape as `commands/mesh/subdivide.d`. The old map
        // disappears with the old mesh; nothing here zeroes it.
        *mesh = m;

        // reset() now also normalizes the projection (Perspective + default
        // preset), so a raw mesh load lands on the default view even if the
        // viewport was in Ortho — fresh-scene framing.
        viewPtr.reset();
        mesh.resetSelection();
        if (promoteType) promoteType(EditMode.Vertices);
        else *editModePtr = EditMode.Vertices;
        if (onResetTool !is null) onResetTool();
        // Bulk transition: the whole mesh was REPLACED (test-only raw load) —
        // every cache must invalidate. The All class is published after the
        // `*mesh = m` swap reset the fresh struct's pending + counters to 0.
        // TASK 1906 STAGE 2 PRECONDITION — `publishChange`, not `noteChange`.
        // `noteChange` accumulates and NEVER delivers (that is its contract:
        // safe inside loops, safe mid-drag), so a command whose LAST mesh
        // publisher is a note delivers only if some EARLIER call happened to
        // register the mesh with the open delivery batch — incidental, not
        // structural. Stage 2a moved the display family off the frame-drain
        // pull and onto the bus, and a wholesale replace that delivers nothing
        // would leave the mid-batch pull guard (`ensureDisplayCurrent`) with
        // no reason to re-upload before the next VBO reader. `publishChange`
        // accumulates identically and delivers at depth 0 / at the batch
        // close, so the delivery COUNT per command is unchanged (one) while
        // the delivery itself is now guaranteed.
        mesh.publishChange(MeshChangeAll);
        return true;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        if (promoteType) promoteType(prevEditMode);
        else *editModePtr = prevEditMode;
    }

    // Tiny @safe int-to-string for error messages without dragging
    // std.conv into the hot path of this test-only command.
    private static string itoa(T)(T v) {
        import std.conv : to;
        return to!string(v);
    }
}
