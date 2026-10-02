module commands.mesh.surface_attr;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import params : Param;

/// What a surface attribute's value means (and how the command validates it).
enum SurfaceAttrKind {
    Bool,       // 0 or 1, exactly
    AngleDeg,   // finite, in [0, 180]
}

/// One editable `Surface` attribute: its command/UI name, kind and field.
struct SurfaceAttrRow {
    string          name;
    SurfaceAttrKind kind;
    string          field;   // member of `Surface`
}

/// THE list of surface attributes `mesh.surfaceAttr` edits — the command, the
/// Mesh Info "Surfaces" section and the census read it; a new attribute is a
/// ROW here, not a second command.
immutable SurfaceAttrRow[] kSurfaceAttrs = [
    SurfaceAttrRow("smoothing",      SurfaceAttrKind.Bool,     "smoothing"),
    SurfaceAttrRow("smoothingAngle", SurfaceAttrKind.AngleDeg, "smoothingAngleDeg"),
];

/// The surface slots a mesh offers for editing: every slot a face renders
/// with or the table holds, at least one (the implicit slot 0), never more
/// than `kSurfaceSlots` (a tag ≥ `kSurfaceSlots` renders as slot 0, and a
/// stray huge `faceMaterial` cannot drive an allocation).
size_t surfaceSlotCount(const ref Mesh m) @safe pure nothrow @nogc {
    size_t n = m.surfaces.length > 1 ? m.surfaces.length : 1;
    foreach (fi; 0 .. m.faces.length) {
        immutable size_t mid = fi < m.faceMaterial.length ? m.faceMaterial[fi] : 0;
        if (mid >= kSurfaceSlots) { n = kSurfaceSlots; break; }
        if (mid + 1 > n) n = mid + 1;
    }
    return n < kSurfaceSlots ? n : kSurfaceSlots;
}

/// The value of attribute `attr` of `s` as a float (Bool → 0/1); NaN for an
/// unknown attribute.
float surfaceAttrValue(const ref Surface s, string attr) @safe pure nothrow @nogc {
    static foreach (r; kSurfaceAttrs)
        if (attr == r.name) {
            static if (r.kind == SurfaceAttrKind.Bool)
                return __traits(getMember, s, r.field) ? 1.0f : 0.0f;
            else
                return __traits(getMember, s, r.field);
        }
    return float.nan;
}

/// Whether `v` is a valid value for `attr` (Bool: exactly 0 or 1; AngleDeg:
/// finite, in [0, 180]).
bool surfaceAttrValid(string attr, float v) @safe pure nothrow @nogc {
    import std.math : isFinite;
    static foreach (r; kSurfaceAttrs)
        if (attr == r.name) {
            static if (r.kind == SurfaceAttrKind.Bool)
                return v == 0.0f || v == 1.0f;
            else
                return isFinite(v) && v >= 0.0f && v <= 180.0f;
        }
    return false;
}

private void setSurfaceAttr(ref Surface s, string attr, float v) @safe pure nothrow @nogc {
    static foreach (r; kSurfaceAttrs)
        if (attr == r.name) {
            static if (r.kind == SurfaceAttrKind.Bool)
                __traits(getMember, s, r.field) = v != 0.0f;
            else
                __traits(getMember, s, r.field) = v;
            return;
        }
}

/// Sets ONE attribute of ONE surface slot (`mesh.surfaceAttr {surface, attr,
/// value}`). A slot past the table is materialised as `Surface.init` (the
/// implicit slot it rendered as). Every refusal — a slot outside
/// `surfaceSlotCount`, an invalid value, or the value the slot already has —
/// is `evaluate` false (status:error, no history entry). Undo restores the
/// whole table (attribute-agnostic).
class MeshSurfaceAttr : Command, Operator {
    mixin OperatorActrCommon;
    private int      surface_ = 0;
    private string   attr_    = "smoothing";
    private float    value_   = 1.0f;
    private Surface[] origSurfaces;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.surfaceAttr"; }
    override string label() const { return "Surface Attribute"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    override Param[] params() {
        string[2][] attrs;
        foreach (r; kSurfaceAttrs) attrs ~= [r.name, r.name];
        // `surface` is an INDEX: an out-of-range one is refused by the kernel
        // (never clamped onto another slot), so the bounds are UI hints only.
        return [
            Param.int_("surface", "Surface", &surface_, 0)
                .min(0).max(cast(int)kSurfaceSlots - 1),
            Param.enum_("attr", "Attribute", &attr_, attrs, kSurfaceAttrs[0].name),
            Param.float_("value", "Value", &value_, 1.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (surface_ < 0) return false;
        immutable size_t slot = cast(size_t)surface_;
        if (slot >= surfaceSlotCount(*mesh)) return false;
        if (!surfaceAttrValid(attr_, value_)) return false;
        if (surfaceAttrValue(surfaceOfSlot(*mesh, slot), attr_) == value_) return false;

        origSurfaces = mesh.surfaces.dup;
        noteUndoRecorded();
        if (mesh.surfaces.length <= slot) mesh.surfaces.length = slot + 1;   // Surface.init
        setSurfaceAttr(mesh.surfaces[slot], attr_, value_);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        mesh.surfaces = origSurfaces.dup;
        mesh.commitChange(MeshEditScope.Material);
    }
}
