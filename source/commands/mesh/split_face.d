module commands.mesh.split_face;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import snapshot : MeshSnapshot;
import params : Param;

/// `mesh.splitFace` — split a polygon into two faces along a chord connecting
/// two of its existing, non-adjacent winding vertices.
///
/// Input modes (evaluated in order):
///   1. Explicit params: `a` and `b` are valid vertex indices.  If `face` is
///      also provided, that face is split; otherwise the first face containing
///      both `a` and `b` non-adjacently is used.
///   2. Selection mode: exactly two selected vertices that share at least one
///      face non-adjacently.  The first qualifying face is used.
///
/// Winding: the two child faces are `face[i..j+1]` and `face[j..]~face[0..i+1]`
/// (scan order, i < j); the ordering of `a` vs `b` does not affect geometry
/// since `rebuildFacesWithChordSplits` always scans the winding in order.
///
/// Rejections (no-op — no snapshot, no undo entry):
///   - Fewer or more than 2 selected vertices (selection mode).
///   - Specified / derived verts are the same, out-of-bounds, or absent from
///     the target face winding.
///   - Verts are adjacent in the face winding (chord == existing edge).
///   - No qualifying face can be found.
class MeshSplitFace : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    private int face_ = -1;
    private int a_    = -1;
    private int b_    = -1;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.splitFace"; }
    override string label() const { return "Split Face"; }

    override Param[] params() {
        return [
            Param.int_("face", "Face",     &face_, -1),
            Param.int_("a",    "Vertex A", &a_,    -1),
            Param.int_("b",    "Vertex B", &b_,    -1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        import std.algorithm : canFind;

        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        uint faceIdx = uint.max;
        uint vA      = uint.max;
        uint vB      = uint.max;

        if (a_ >= 0 && b_ >= 0) {
            // ----- Explicit params mode -----
            vA = cast(uint)a_;
            vB = cast(uint)b_;
            if (face_ >= 0) {
                faceIdx = cast(uint)face_;
            } else {
                // Derive the first face containing both vA and vB non-adjacently.
                faceIdx = findQualifyingFace(*mesh, vA, vB, uint.max);
            }
        } else {
            // ----- Selection mode -----
            if (!mesh.hasAnySelectedVertices()) return false;

            const sv = mesh.selectedVertices;
            uint[] sel;
            foreach (vi; 0 .. sv.length)
                if (sv[vi]) sel ~= cast(uint)vi;

            if (sel.length != 2) return false;
            vA = sel[0];
            vB = sel[1];

            faceIdx = findQualifyingFace(*mesh, vA, vB, uint.max);
        }

        if (faceIdx == uint.max) return false;
        if (vA == uint.max || vB == uint.max) return false;

        // Snapshot before mutation (caller-owned, discarded on kernel no-op).
        snap = MeshSnapshot.capture(*mesh);

        size_t n = mesh.splitFaceByVertices(faceIdx, vA, vB);
        if (n == 0) {
            snap.restore(*mesh);
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

// ---------------------------------------------------------------------------
// Helper: scan faces to find the first one that contains both vA and vB at
// non-adjacent winding positions.  `preferFace` is checked first when valid.
// Returns uint.max when no qualifying face exists.
// ---------------------------------------------------------------------------
private uint findQualifyingFace(ref const(Mesh) m, uint vA, uint vB, uint preferFace)
{
    if (vA >= m.vertices.length || vB >= m.vertices.length) return uint.max;
    if (vA == vB) return uint.max;

    // Inner helper: check a single face index.
    bool qualifies(uint fi) {
        if (fi >= m.faces.length) return false;
        const face = m.faces[fi];
        size_t posA = size_t.max, posB = size_t.max;
        foreach (k; 0 .. face.length) {
            if (face[k] == vA) posA = k;
            if (face[k] == vB) posB = k;
        }
        if (posA == size_t.max || posB == size_t.max) return false;
        // Adjacency check (same as rebuildFacesWithChordSplits:7741).
        size_t i = posA < posB ? posA : posB;
        size_t j = posA < posB ? posB : posA;
        bool adj = (j == i + 1) || (i == 0 && j == face.length - 1);
        return !adj;
    }

    if (preferFace != uint.max && qualifies(preferFace)) return preferFace;

    foreach (fi; 0 .. cast(uint)m.faces.length)
        if (qualifies(fi)) return fi;

    return uint.max;
}
