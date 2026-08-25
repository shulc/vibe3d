module commands.mesh.stroke_extrude;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import snapshot : MeshSnapshot;

/// One-shot, headlessly-testable path-follow extrude (task 0323 "Sketch
/// Extrude" port — basic/captured scope only; curved paths, the exact
/// screen-Precision→span-count law, and Scale/Spin per-band modulation are
/// explicit non-goals for this pass, TODO — not invented). Extrudes the
/// currently selected polygon set along an explicit WORLD-SPACE path-point
/// list.
///
/// The interactive tool (`tool.strokeExtrude`) samples this list live from
/// a drawn viewport stroke and feeds it through the generic record-flavor
/// `MeshSessionEdit` (wire name "mesh.strokeExtrude_edit") on commit; a
/// caller driving THIS command
/// directly (HTTP `/api/command`, `dub test`) supplies the path list
/// verbatim — decoupling the topology kernel from the drag/raycast
/// heuristics (see StrokeExtrudeTool's doc comment for what there is
/// captured-exact vs. a documented default).
///
/// Parameters:
///   - path        — Vec3Array. World-space path points, length >= 2.
///                    `path[0]` is the anchor (nominally the selection's
///                    own position when the stroke began); N =
///                    path.length-1 new bands are created.
///   - alignToPath — bool. Reference "Align to Path" default ON (captured
///                    toolcard spec default) — see
///                    `mesh_ops.revolve.extrudeAlongPath`'s doc comment for what this
///                    does and its curved-path TODO/unverified scope.
///
/// Undo: snapshot-based (MeshSnapshot), consistent with mesh.sweep /
///       mesh.bridge / mesh.radial_array.
class MeshStrokeExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private Vec3[] path_;
    private bool   alignToPath_ = true;

    // DoS backstop (same class as the Radial Array count clamp — a huge
    // JSON-supplied path list over HTTP must not explode geometry).
    // `extrudeAlongPath` also clamps internally at 4096 spans
    // (defense-in-depth for the shared kernel); this bound agrees with it
    // (4097 points = 4096 spans, the kernel's own cap).
    private enum size_t maxPathPoints = 4097;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.strokeExtrude"; }
    override string label() const { return "Stroke Extrude"; }

    override Param[] params() {
        return [
            Param.vec3Array_("path",        "Path",          &path_),
            Param.bool_     ("alignToPath", "Align to Path",  &alignToPath_, true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        if (path_.length < 2 || path_.length > maxPathPoints) return false;

        // Reference precondition: "select a polygon, and then click the
        // tool" — the tool/command does not pick one for you.
        bool[] mask = new bool[](mesh.faces.length);
        bool   any  = false;
        foreach (i, b; mesh.selectedFaces) if (b) { mask[i] = true; any = true; }
        if (!any) return false;

        snap = MeshSnapshot.capture(*mesh);

        // TASK 1903 Stage E2 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). This is the family's biggest single win:
        // `extrudeAlongPath` runs `extrudePathStep_` once per PATH SPAN and
        // each step ends in its own `commitChange`, so an N-span stroke used
        // to stamp, re-derive hidden geometry and deliver N times. It now does
        // all three ONCE, at `close()`.
        //
        // UNRECORDED, deliberately: undo here is still the whole-mesh `snap`
        // captured just above (plan §5.1 — the conversion axis and the undo
        // axis are separate commits), so a RECORDING batch would build a full
        // op-log that nothing reads and `close()` would drop.
        //
        // No `scope(failure)`: `MeshEditBatch.~this` pops the frame during
        // unwinding without asserting and ticks `changeBus.batchLeaks`, which
        // the suite asserts stays 0 (§2.2c).
        size_t added;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kRevolveEditScope);
            added = ed.extrudeAlongPath(mask, path_, alignToPath_);
            ed.close();
        }
        if (added == 0) {
            snap = MeshSnapshot.init;
            return false;
        }

        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
