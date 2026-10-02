// `mesh.surfaceAttr` (S1e): every refusal leaves the surface table AND the
// mutation version unchanged (evaluate false ⇒ status:error, no history entry —
// the command no-op contract); apply/revert restores the table exactly,
// including a slot materialised past the table.
module tests.unit.commands.mesh.surface_attr_test;

import std.format : format;

import editmode : EditMode;
import math     : Vec3;
import mesh     : Mesh, Surface, kSurfaceSlots;
import view     : View;
import commands.mesh.surface_attr : MeshSurfaceAttr, surfaceSlotCount, kSurfaceAttrs;

/// Two quads; `faceMaterial` as given.
private Mesh* plate(uint[] mats) {
    auto m = new Mesh;
    foreach (i; 0 .. 6) m.addVertex(Vec3(i % 3, i / 3, 0));
    m.addFace([0u, 1, 4, 3]);
    m.addFace([1u, 2, 5, 4]);
    m.buildLoops();
    m.faceMaterial = mats.dup;
    return m;
}

private MeshSurfaceAttr cmd(Mesh* m, int surface, string attr, float value) {
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshSurfaceAttr(m, v, EditMode.Polygons);
    foreach (p; c.params()) {
        if (p.name == "surface") *p.iptr = surface;
        else if (p.name == "attr") *p.sptr = attr;
        else if (p.name == "value") *p.fptr = value;
    }
    return c;
}

/// `c` refuses and leaves the table and the version as they were.
private void refuses(Mesh* m, int surface, string attr, float value, string why) {
    immutable Surface[] before = m.surfaces.idup;
    immutable ulong v0 = m.mutationVersion;
    auto c = cmd(m, surface, attr, value);
    assert(!c.apply(), format("%s: {surface:%d, attr:%s, value:%s} was accepted", why, surface, attr, value));
    assert(m.surfaces == before, format("%s: the refusal changed the surface table", why));
    assert(m.mutationVersion == v0, format("%s: the refusal moved mutationVersion", why));
}

unittest { // the attribute table names exactly the two S1e rows
    assert(kSurfaceAttrs.length == 2 && kSurfaceAttrs[0].name == "smoothing"
        && kSurfaceAttrs[1].name == "smoothingAngle", "kSurfaceAttrs rows moved");
}

unittest { // every kSurfaceAttrs row has a Surfaces widget, and the panel draws the table
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.algorithm : canFind;
    import std.string : indexOf;
    import commands.mesh.surface_attr : surfaceAttrWidget, SurfaceAttrWidget;
    size_t rows;
    foreach (r; kSurfaceAttrs) {
        // The final switch in `surfaceAttrWidget` is the compile-time half; this
        // is the row half: a known widget and a non-empty label per row.
        immutable w = surfaceAttrWidget(r.kind);
        assert(w == SurfaceAttrWidget.Checkbox || w == SurfaceAttrWidget.DragFloat,
            format("row %s: no Surfaces widget", r.name));
        assert(r.label.length > 0, format("row %s: no widget label", r.name));
        ++rows;
    }
    assert(rows == 2, format("population: %d rows walked, the table has two", rows));
    // Production wiring: the section iterates the table and picks the widget
    // by kind — no per-attribute widget code.
    immutable root = __FILE_FULL_PATH__.dirName.dirName.dirName.dirName.dirName;
    immutable src = readText(buildPath(root, "source", "ui", "panels.d"));
    immutable long b = src.indexOf("private void drawSurfacesSection(");
    assert(b >= 0, "panels.d: drawSurfacesSection not found");
    immutable long e = src.indexOf("\nvoid drawStatusBar(", b);
    assert(e > b, "panels.d: the end of drawSurfacesSection not found");
    immutable body_ = src[b .. e];
    assert(body_.canFind("foreach (ri, r; kSurfaceAttrsUi)")
        && body_.canFind("final switch (surfaceAttrWidget(r.kind))"),
        "drawSurfacesSection no longer draws kSurfaceAttrs by widget kind");
    foreach (r; kSurfaceAttrs)
        assert(!body_.canFind(`"` ~ r.name ~ `"`),
            format("drawSurfacesSection names the attribute %s literally — a per-row widget", r.name));
}

unittest { // surfaceSlotCount: the table, the face tags, at least 1, at most kSurfaceSlots
    assert(surfaceSlotCount(*plate([])) == 1, "an untagged mesh offers the implicit slot only");
    assert(surfaceSlotCount(*plate([0, 3])) == 4, "a tag 3 does not offer slots 0..3");
    assert(surfaceSlotCount(*plate([0, 5000])) == kSurfaceSlots, "a huge tag is not capped at kSurfaceSlots");
    auto m = plate([]);
    m.surfaces = [Surface(), Surface(), Surface()];
    assert(surfaceSlotCount(*m) == 3, "a 3-entry table does not offer 3 slots");
}

unittest { // every refusal: one assert each [E14]
    auto m = plate([0, 1]);
    m.surfaces = [Surface("A"), Surface("B")];
    refuses(m, 2, "smoothing", 0, "surface >= n");
    refuses(m, -1, "smoothing", 0, "negative surface");
    refuses(m, 0, "smoothing", 0.5f, "bool value 0.5");
    refuses(m, 0, "smoothingAngle", -1, "angle -1");
    refuses(m, 0, "smoothingAngle", 181, "angle 181");
    refuses(m, 0, "smoothingAngle", float.nan, "angle NaN");
    refuses(m, 0, "smoothing", 1, "the same value (smoothing already on)");
    refuses(m, 1, "smoothingAngle", 40, "the same value (angle already 40)");
    auto big = plate([0, 5000]);
    refuses(big, 64, "smoothing", 0, "surface 64 with a faceMaterial of 5000 (n capped at 64)");
}

unittest { // apply / revert: the table restored exactly, incl. the materialised slot
    auto m = plate([]);
    assert(m.surfaces.length == 0, "rig: the table is not empty");
    auto c = cmd(m, 0, "smoothing", 0);
    immutable ulong v0 = m.mutationVersion;
    assert(c.apply(), "smoothing off on the implicit slot was refused");
    assert(m.surfaces.length == 1 && !m.surfaces[0].smoothing,
        format("apply: table %s, expected one materialised slot with smoothing off", m.surfaces));
    Surface want = Surface.init;
    want.smoothing = false;
    assert(m.surfaces[0] == want, "the materialised slot is not Surface.init (but for the edit)");
    assert(m.mutationVersion != v0, "apply did not move mutationVersion");
    c.revert();
    assert(m.surfaces.length == 0, format("revert: table length %d, expected 0", m.surfaces.length));

    auto n = plate([0, 1]);
    n.surfaces = [Surface("A"), Surface("B")];
    immutable Surface[] before = n.surfaces.idup;
    auto d = cmd(n, 1, "smoothingAngle", 25.5f);
    assert(d.apply() && n.surfaces[1].smoothingAngleDeg == 25.5f, "angle 25.5 on slot 1 not applied");
    d.revert();
    assert(n.surfaces == before, "revert did not restore the table exactly");
}
