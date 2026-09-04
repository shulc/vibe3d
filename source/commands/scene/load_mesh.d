module commands.scene.load_mesh;

import command;
import math : Vec3;
import mesh;
import view;
import editmode;
// GpuMesh lives in mesh.d, already imported above.
import snapshot : MeshSnapshot;
import change_bus : MeshChangeAll;
import params : Param, wireArgs;
import std.json : JSONValue, JSONType, parseJSON;

/// Replace the current mesh with a caller-supplied raw mesh (test-only,
/// driven by the generic command endpoint). Mirrors `SceneReset`: snapshots the
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

    // The wire form of the two geometry slots: their RAW JSON TEXT (task 4062).
    private string newVertsJson_;
    private string newFacesJson_;

    // TASK 4062 — THE ARGUMENTS, DECLARED. These two used to be decoded by a
    // hand-written arm in the HTTP dispatcher (the retired `/api/load-mesh`
    // route's decode, moved there and then here).
    //
    // WHY RAW-JSON SLOTS AND NOT `Vec3Array` + an index-array kind. `vertices`
    // would fit `Param.Kind.Vec3Array`; `faces` is a RAGGED array of index
    // arrays, and `Param.Kind` has no spelling for that — a quad face and a
    // triangle in the same payload is the normal case, not an edge case. Split
    // across two mechanisms the PAIR GATE below could not be written at all:
    // an absent `vertices` and a supplied `[]` are the same `null` slice once
    // `Vec3Array` has written it, so `{"vertices":[],"faces":[]}` (a live
    // payload — `test_copilot_cycle.d`) would be indistinguishable from
    // `{"faces":[…]}` (which must stay an error — `test_load_mesh.d`). The raw
    // text distinguishes them, so both slots take it and `decodeWireGeometry`
    // below carries the injector's decode over message for message.
    override Param[] params() {
        return wireArgs(
            Param.jsonArg_("vertices", "Vertices", &newVertsJson_),
            Param.jsonArg_("faces",    "Faces",    &newFacesJson_),
        );
    }

    /// Supply the raw geometry to load. Caller owns/builds these arrays;
    /// they are validated against each other (index range) in apply().
    void setData(Vec3[] verts, uint[][] faces) {
        this.newVerts = verts;
        this.newFaces = faces;
    }

    /// Decode the two declared raw-JSON slots into `newVerts` / `newFaces`.
    ///
    /// A FIELD IS VALIDATED ONLY WHEN THE PAYLOAD SUPPLIES IT (task 4131), and
    /// the two are validated as a PAIR: an argument-less `scene.loadMesh` is a
    /// load of the empty mesh and must reach `apply()`, while half a payload
    /// (`{"faces":[[0,1,2]]}` with no `vertices`) is the error
    /// `test_load_mesh.d` froze. Every message below is the one the dispatcher
    /// arm raised, unchanged.
    ///
    /// Called from the TOP of `applyImpl`, before its own validation and so
    /// before any live state is touched: a bad payload leaves the scene exactly
    /// as it was, which is where the dispatcher arm ran too.
    private void decodeWireGeometry() {
        if (newVertsJson_.length == 0 && newFacesJson_.length == 0) return;

        JSONValue vj = newVertsJson_.length ? parseJSON(newVertsJson_)
                                            : JSONValue(null);
        JSONValue fj = newFacesJson_.length ? parseJSON(newFacesJson_)
                                            : JSONValue(null);
        if (vj.type != JSONType.array)
            throw new Exception("missing 'vertices' array field");
        if (fj.type != JSONType.array)
            throw new Exception("missing 'faces' array field");

        double numFrom(JSONValue n) {
            switch (n.type) {
                case JSONType.integer:  return cast(double)n.integer;
                case JSONType.uinteger: return cast(double)n.uinteger;
                case JSONType.float_:   return n.floating;
                default: throw new Exception("vertex components must be numbers");
            }
        }

        auto vArr = vj.array;
        Vec3[] decodedVerts = new Vec3[](vArr.length);
        foreach (i, vv; vArr) {
            if (vv.type != JSONType.array || vv.array.length != 3)
                throw new Exception("each vertex must be [x,y,z]");
            decodedVerts[i] = Vec3(cast(float)numFrom(vv.array[0]),
                                   cast(float)numFrom(vv.array[1]),
                                   cast(float)numFrom(vv.array[2]));
        }

        // `decodedFaces`, not `faces`: these are the PAYLOAD being decoded into
        // a fresh local, and the live mesh is replaced wholesale by `*mesh = m`
        // afterwards. A bare `faces[i] = …` in `source/commands/**` is the shape
        // `command_winding_write_census_test` refuses, and refuses rightly —
        // there it means a live winding rewritten by hand under an open batch,
        // which reaches no op-log hook. Naming the local for what it is keeps
        // that census sharp instead of teaching it an exception.
        auto fArr = fj.array;
        uint[][] decodedFaces = new uint[][](fArr.length);
        foreach (i, ff; fArr) {
            if (ff.type != JSONType.array)
                throw new Exception("each face must be an array of vertex indices");
            auto idxArr = ff.array;
            uint[] face = new uint[](idxArr.length);
            foreach (k, ij; idxArr) {
                if (ij.type != JSONType.integer && ij.type != JSONType.uinteger)
                    throw new Exception("face indices must be integers");
                long v = ij.integer;
                if (v < 0)
                    throw new Exception("face index must be non-negative");
                face[k] = cast(uint)v;
            }
            decodedFaces[i] = face;
        }

        setData(decodedVerts, decodedFaces);
    }

    /// Install the funnel hook so apply/revert route the editMode write through
    /// promoteGeometryType (touches selTypeOrder before the field write). Returns
    /// `this` for chaining. Null (default) = raw-pointer fallback for headless.
    MeshLoadRaw setPromoteHook(void delegate(EditMode) hook) {
        this.promoteType = hook;
        return this;
    }

    protected override bool applyImpl() {
        // ---- The declared wire slots become arrays BEFORE anything else ----
        decodeWireGeometry();

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
            import tool_disarm : DisarmMode,
                disarmActiveToolBeforeDocumentReplace;
            disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
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
