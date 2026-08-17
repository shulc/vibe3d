// The Statistics panel's ROW MODEL — `source/ui/stat_rows.d` (task 1100 Stage 2).
//
// Everything asserted here is ROW CONTENT: which rows exist, in what order, at
// what level, carrying which numbers, which availability class, which tone and
// which command. Nothing here claims to cover where a row lands on screen —
// that is `tests/unit/ui/stat_panel_widget_test.d` and the drawn-record test.

import document : Document, Layer, ItemKind;
import mesh;
import mesh_stats;
import mesh_selsets;
import seltype  : SelType;
import ui.stat_rows;
import math     : Vec3;
import std.algorithm : canFind, count, filter, map;
import std.conv  : to;
import std.string : startsWith;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
private Document cubeDoc() {
    Mesh m = makeCube();
    auto d = Document.bootstrap(m);
    d.primary.meshRef().syncSelection();
    return d;
}

/// A cube whose per-face tag arrays are genuinely SHORT — `syncSelection`
/// zero-FILLS `faceMaterial`/`facePart` to `faces.length`, and a zero-filled
/// array answers the same as a short one, so a synced fixture cannot tell
/// "derived through the accessor" from "derived from the stored entries". This
/// one can, which is what makes the Р1/D7 mutation reddenable.
private Document rawCubeDoc() {
    Mesh m = makeCube();
    return Document.bootstrap(m);
}

private StatContext ctxOf(ref Document d) {
    auto m = d.hasEditTarget() ? d.primary.meshOrNull() : null;
    return m is null ? StatContext.init : buildStatContext(*m);
}

/// Everything open — the state most assertions want, and NEVER the default
/// (the default is pinned separately, precisely so a change to it cannot
/// silently empty every other test here).
private StatExpand allOpen(ref Document d, SelType current) {
    StatExpand e;
    // Sections opened EXPLICITLY, never inherited from the first-open default:
    // that default is ours rather than measured, and a helper that leaned on it
    // would turn every test in this file red the day it changes. Its own pin is
    // the one place it is asserted.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        e.section[cast(size_t) t] = true;
    // Discover the category keys by emitting once with sections open and
    // categories closed, then open every key that came back.
    StatSection[] buf;
    auto ctx = ctxOf(d);
    statSectionsInto(&d, current, ctx, e, buf);
    foreach (ref s; buf)
        foreach (ref c; s.categories) e.category[c.key] = true;
    return e;
}

private StatSection[] emit(ref Document d, SelType current, ref StatExpand e) {
    StatSection[] buf;
    auto ctx = ctxOf(d);
    statSectionsInto(&d, current, ctx, e, buf);
    return buf;
}

private const(StatSection)* findSection(const StatSection[] buf, string label) {
    foreach (ref s; buf) if (s.label == label) return &s;
    return null;
}

private const(StatCategory)* findCategory(const StatSection[] buf, string sec,
                                          string cat) {
    auto s = findSection(buf, sec);
    if (s is null) return null;
    foreach (ref c; s.categories) if (c.label == cat) return &c;
    return null;
}

private const(StatLeaf)* findLeaf(const StatSection[] buf, string sec,
                                  string cat, string leaf) {
    auto c = findCategory(buf, sec, cat);
    if (c is null) return null;
    foreach (ref l; c.leaves) if (l.label == leaf) return &l;
    return null;
}

// ---------------------------------------------------------------------------
// Section order, and the zero row that must NOT be hidden.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Vertex);
    auto buf = emit(d, SelType.Vertex, e);

    assert(buf.length == 4, "four sections, always");
    assert(buf[0].label == "Vertices" && buf[1].label == "Edges"
        && buf[2].label == "Polygons" && buf[3].label == "Items",
        "the section order is a fixed traversal, not a sort");

    // A ZERO row is present and reads 0 — rows are never hidden for being
    // empty, which is the measured law and the strongest temptation to "fix".
    auto zero = findLeaf(buf, "Vertices", "By Edge", "0");
    assert(zero !is null, "the zero row must exist");
    assert(zero.num.known && zero.num.value == 0,
        "…and read a real 0, not a placeholder");

    // The cube's own answer, for contrast: every vertex has three edges.
    auto three = findLeaf(buf, "Vertices", "By Edge", "3");
    assert(three !is null && three.num.value == 8, "8 vertices with 3 edges");
}

// ---------------------------------------------------------------------------
// A category whose dynamic list is empty keeps its HEADER.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);

    // Permanently empty for a data-MODEL reason: we have no smoothing groups
    // and no item-domain selection sets.
    auto sg = findCategory(buf, "Polygons", "Smoothing Groups");
    assert(sg !is null, "the header exists");
    assert(sg.leaves.length == 0, "…with no leaves");

    // …and it is there in the DEFAULT expand state too, where every category is
    // closed and therefore leafless. This is the arm that catches "skip a
    // category with no leaves" directly rather than through a later row.
    StatExpand closed;
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        closed.section[cast(size_t) t] = true;      // sections open, CATEGORIES closed
    auto shut = emit(d, SelType.Polygon, closed);
    foreach (ref sec; shut)
        assert(sec.categories.length > 0,
            "a collapsed category is still a ROW: " ~ sec.label);
    assert(findCategory(shut, "Polygons", "Smoothing Groups") !is null,
        "the empty category keeps its header with everything collapsed");
    auto isets = findCategory(buf, "Items", "By Selection Set");
    assert(isets !is null && isets.leaves.length == 0);

    // Empty for a DATA reason: a mesh with no faces has no material tags.
    Document empty;
    auto l = new Layer;
    l.name = "empty";
    empty.layers = [l];
    empty.setActive(0);
    auto e2 = allOpen(empty, SelType.Polygon);
    auto buf2 = emit(empty, SelType.Polygon, e2);
    auto matl = findCategory(buf2, "Polygons", "Material");
    assert(matl !is null, "the Material header exists on a faceless mesh");
    assert(matl.leaves.length == 0, "…with no leaves");
}

// ---------------------------------------------------------------------------
// THE `Sel` GATE — one section prints numbers, the other three do not.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();

    auto ep = allOpen(d, SelType.Polygon);
    auto poly = emit(d, SelType.Polygon, ep);
    auto vertLeafP = findLeaf(poly, "Vertices", "By Edge", "3");
    assert(vertLeafP !is null && !vertLeafP.sel.known,
        "in polygon mode the vertex rows' Sel is GATED");
    assert(vertLeafP.num.known, "…while Num is computed regardless");
    auto polyLeafP = findLeaf(poly, "Polygons", "By Vertex", "4");
    assert(polyLeafP !is null && polyLeafP.sel.known,
        "…and the polygon section's own rows are not gated");
    assert(findSection(poly, "Edges").sel.known == false,
        "the gate applies to the SECTION row too");
    assert(findSection(poly, "Polygons").sel.known,
        "…and opens for the current type's section row");

    auto ev = allOpen(d, SelType.Vertex);
    auto vert = emit(d, SelType.Vertex, ev);
    auto vertLeafV = findLeaf(vert, "Vertices", "By Edge", "3");
    assert(vertLeafV !is null && vertLeafV.sel.known,
        "in vertex mode the SAME row's Sel is open");

    // The two placeholders are distinguishable IN THE MODEL, which is what
    // lets the drawer pick "..." for one and "—" for the other.
    auto gated = vertLeafP;                                    // known == false, live
    auto unknown = findLeaf(poly, "Polygons", "By Type", "Convex");
    assert(unknown !is null);
    assert(!gated.num.known == false, "a gated row still KNOWS its Num");
    assert(!unknown.num.known, "an unmeasured row knows neither number");
    assert(gated.avail == StatAvail.live && unknown.avail == StatAvail.unmeasured,
        "the two states differ by StatAvail, not only by `known`");
}

// ---------------------------------------------------------------------------
// THE ROW TONE (measured, frame B) — three arms of one rule, one fixture.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto m = d.primary.meshOrNull();
    m.selectFace(0);
    m.selectFace(2);                       // 2 of 6 faces
    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);

    // (a) the section header dims with its own Sel …
    auto polySec = findSection(buf, "Polygons");
    assert(polySec.sel.known && polySec.sel.value == 2);
    assert(polySec.tone == StatTone.dimmed,
        "the section header dims when its selected count is non-zero");

    // (b) … a leaf with sel > 0 dims, a leaf with sel == 0 does not …
    auto quads = findLeaf(buf, "Polygons", "By Vertex", "4");
    assert(quads.num.value == 6 && quads.sel.value == 2);
    assert(quads.tone == StatTone.dimmed, "0 < sel < num is dimmed");
    auto tris = findLeaf(buf, "Polygons", "By Vertex", "3");
    assert(tris.num.value == 0 && tris.sel.value == 0);
    assert(tris.tone == StatTone.normal, "sel == 0 is normal");

    // (c) … and a GATED row is normal, because its Sel is not computed at all.
    // This is the arm that reddens when `sel.known` is dropped from the rule:
    // a gated cell's `value` is whatever the field was initialised to.
    foreach (ref s; buf) {
        if (s.type == SelType.Polygon) continue;
        assert(s.tone == StatTone.normal,
            "a gated section header must be drawn normal: " ~ s.label);
        foreach (ref c; s.categories)
            foreach (ref l; c.leaves)
                assert(l.tone == StatTone.normal,
                    "a gated leaf must be drawn normal: " ~ s.label ~ "/" ~ l.label);
    }

    // The tone is NEVER expressed by an availability class: a dimmed row is
    // fully live.
    assert(quads.avail == StatAvail.live,
        "dimming must not become disabling — they are different fields");

    // (d) THE RULE ITSELF, asked directly, with a cell the tree cannot build.
    // Measured: dropping `sel.known` from the rule changes no row this model
    // emits today (the kernel leaves a gated `sel` at 0), so the sweep above
    // cannot pin that term — only this can. It is the term that stops every
    // gated row in the panel from dimming the day a caller fills `value`
    // regardless of the gate.
    assert(toneFor(StatCell(false, 5)) == StatTone.normal,
        "a cell whose Sel is NOT KNOWN is drawn normal whatever its value");
    assert(toneFor(StatCell(true, 5)) == StatTone.dimmed);
    assert(toneFor(StatCell(true, 0)) == StatTone.normal);
}

// ---------------------------------------------------------------------------
// THE CATEGORY LEVEL HAS NO AFFORDANCE — swept over EVERY category, because
// the measurement is about the LEVEL, not about a category.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);

    size_t seen = 0;
    foreach (ref s; buf) {
        foreach (ref c; s.categories) {
            ++seen;
            assert(c.avail == StatAvail.noAffordance,
                "category rows carry no affordance: " ~ c.key);
            assert(c.add.empty && c.remove.empty,
                "…and therefore no action: " ~ c.key);
            assert(!c.num.known && !c.sel.known,
                "…and no numbers at all: " ~ c.key);
        }
        // Section rows and leaves DO carry actions where they can act — the
        // other half of the same measurement.
        if (s.label != "Items")
            assert(!s.add.empty, "section headers act: " ~ s.label);
    }
    assert(seen >= 10, "the sweep must cover every category, saw " ~ seen.to!string);

    auto live = findLeaf(buf, "Polygons", "By Vertex", "4");
    assert(!live.add.empty && !live.remove.empty, "leaves act");
}

// ---------------------------------------------------------------------------
// Р1 / D7 — the row list is derived from THE SAME predicate the button fires.
// ---------------------------------------------------------------------------
unittest {
    auto d = rawCubeDoc();       // a FRESH cube: facePart and faceMaterial EMPTY
    auto m = d.primary.meshOrNull();
    assert(m.facePart.length == 0 && m.faceMaterial.length == 0,
        "setup: the tag arrays are SHORT, so this fixture can tell the "
        ~ "accessor-derived row list from a stored-entry-derived one");

    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);

    auto part = findCategory(buf, "Polygons", "Part");
    assert(part.leaves.length == 1, "exactly one part row on a fresh cube, got "
        ~ part.leaves.length.to!string);
    assert(part.leaves[0].label == "Part 0", part.leaves[0].label);
    assert(part.leaves[0].num.value == 6, "…covering all six faces");

    auto matl = findCategory(buf, "Polygons", "Material");
    assert(matl.leaves.length == 1, "exactly one material row on a fresh cube");
    assert(matl.leaves[0].label == "Material 0", matl.leaves[0].label);
    assert(matl.leaves[0].num.value == 6);

    // A named surface takes its NAME, and the row list still comes from the
    // tags actually present.
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[0] = 1;
    m.faceMaterial[2] = 1;
    m.surfaces = [Surface("Default"), Surface("Red")];
    auto buf2 = emit(d, SelType.Polygon, e);
    auto matl2 = findCategory(buf2, "Polygons", "Material");
    assert(matl2.leaves.length == 2, "two tags present now");
    assert(matl2.leaves[0].label == "Default" && matl2.leaves[1].label == "Red",
        "named surfaces are labelled by name");
    assert(matl2.leaves[1].num.value == 2, "…and count their own faces");
    assert(matl2.leaves[1].add.argsJson.canFind(`"name":"Red"`),
        "…and fire by name: " ~ matl2.leaves[1].add.argsJson);
}

// ---------------------------------------------------------------------------
// THE NULL-PRIMARY PIN (owner decision Р8, as corrected).
//
// The state is one click away from the user: this panel's own
// `Items → By Type → Mesh` minus button empties the item selection. `Layer` is
// a class, so the wrong guard here is a SEGFAULT in a panel that draws every
// frame — not a wrong number.
// ---------------------------------------------------------------------------
unittest {
    Document doc;
    auto a = new Layer; a.name = "A";
    auto b = new Layer; b.name = "B";
    doc.layers = [a, b];
    assert(doc.primary is null && !doc.hasEditTarget(),
        "setup: nothing has a selection state, so there is no edit target");

    auto e = allOpen(doc, SelType.Item);       // must not fault either
    auto buf = emit(doc, SelType.Item, e);

    assert(buf.length == 4, "all four sections are still emitted");
    assert(buf[0].label == "Vertices" && buf[3].label == "Items");

    // Every geometry row is UNKNOWN — `—`, never a confident 0. Using the
    // read-only empty stand-in mesh here would answer 0 everywhere, which is
    // the second way this line gets "fixed" and the reason this assert reads
    // `known == false` rather than `value == 0`.
    foreach (ref s; buf[0 .. 3]) {
        assert(!s.num.known && !s.sel.known,
            "the section row cannot know a count with no edit target: " ~ s.label);
        assert(s.avail == StatAvail.unmeasured);
        foreach (ref c; s.categories) {
            // ONE category inside the geometry sections is DOCUMENT-scoped:
            // `Polygons → Layer` counts polygons across foreground / background
            // LAYERS and never touches the edit target, so it keeps real
            // numbers here for exactly the reason the Items section does.
            // Blanking it would be the same lie in a smaller place. (The plan's
            // Stage-2 wording says "every leaf of Vertices/Edges/Polygons" — it
            // collides with this category the same way owner decision Р8's own
            // first wording collided with Items.)
            if (c.label == "Layer") {
                foreach (ref l; c.leaves)
                    assert(l.num.known && l.num.value == 0,
                        "the document-scoped Layer rows still count: " ~ l.label);
                continue;
            }
            foreach (ref l; c.leaves) {
                assert(!l.num.known && !l.sel.known,
                    "geometry leaf must be unknown: " ~ s.label ~ "/" ~ l.label);
                assert(l.avail == StatAvail.unmeasured,
                    "…and say so: " ~ s.label ~ "/" ~ l.label);
            }
        }
    }

    // …and the Items section counts for real: it reads `doc.layers` and touches
    // no mesh, so blanking it would be its own lie.
    auto items = findSection(buf, "Items");
    assert(items.num.known && items.num.value == 2, "two items are two items");
    auto meshRow = findLeaf(buf, "Items", "By Type", "Mesh");
    assert(meshRow !is null, "the Mesh kind row exists");
    assert(meshRow.num.known && meshRow.num.value == 2,
        "…and counts both layers, got " ~ meshRow.num.value.to!string);
}

// ---------------------------------------------------------------------------
// Every command id the tree dispatches is a REAL command's `name()`.
// A typo in a dispatch string is otherwise a button that silently does nothing.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import commands.select.by_stat : SelectByStatVertex, SelectByStatEdge,
                                     SelectByStatPolygon;
    import commands.select.by_tag  : SelectByTag;
    import commands.select.sets    : SelectSetApply;
    import commands.layer.commands : LayerSelect;

    auto d = cubeDoc();
    auto m = d.primary.meshOrNull();
    // Give the fixture one of everything so every row family is emitted.
    auto mm = &d.primary.meshRef();
    mm.addWeightMap("W");
    mm.setVertexWeight("W", 0, 1.0f);
    mm.selectVertex(0);
    selSetEditVertex(*mm, "VSet", SetEditMode.replace, mm.selectedVertices);
    mm.selectFace(1);
    selSetEditPolygon(*mm, "PSet", SetEditMode.replace, mm.selectedFaces);
    mm.selectEdge(0);
    selSetEditEdge(*mm, "ESet", SetEditMode.replace, mm.selectedEdges);

    View v = new View(0, 0, 1, 1);
    string[] real_;
    real_ ~= (new SelectByStatVertex(mm, v, EditMode.Vertices, null)).name();
    real_ ~= (new SelectByStatEdge(mm, v, EditMode.Edges, null)).name();
    real_ ~= (new SelectByStatPolygon(mm, v, EditMode.Polygons, null)).name();
    real_ ~= (new SelectByTag(mm, v, EditMode.Polygons)).name();
    real_ ~= (new SelectSetApply(mm, v, EditMode.Polygons, &d)).name();
    real_ ~= (new LayerSelect(mm, v, EditMode.Polygons, &d, null)).name();

    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);
    size_t checked = 0;
    void check(StatAction a, string where) {
        if (a.empty) return;
        assert(real_.canFind(a.commandId),
            "no such command id '" ~ a.commandId ~ "' dispatched from " ~ where);
        ++checked;
    }
    foreach (ref s; buf) {
        check(s.add, s.label);  check(s.remove, s.label);
        foreach (ref c; s.categories)
            foreach (ref l; c.leaves) {
                check(l.add, c.key ~ "/" ~ l.label);
                check(l.remove, c.key ~ "/" ~ l.label);
            }
    }
    assert(checked > 40, "the sweep must see the whole tree, saw "
        ~ checked.to!string);

    // Every row family is represented — otherwise the sweep above could pass
    // while a whole family emitted nothing.
    assert(findLeaf(buf, "Vertices", "By Selection Set", "VSet") !is null);
    assert(findLeaf(buf, "Edges",    "By Selection Set", "ESet") !is null);
    assert(findLeaf(buf, "Polygons", "By Selection Set", "PSet") !is null);
    assert(findLeaf(buf, "Vertices", "By Vertex Map",    "W")    !is null);
}

// ---------------------------------------------------------------------------
// The exact argument shape — including that the SECTION row emits no `value`
// key. `compare:all` with any `value` set is a hard reject in the command, so
// this is not cosmetic.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Vertex);
    auto buf = emit(d, SelType.Vertex, e);

    auto vs = findSection(buf, "Vertices");
    assert(vs.add.commandId == "select.byStat.vertex");
    assert(vs.add.argsJson == `{"test":"edgeCount","compare":"all","mode":"add"}`,
        vs.add.argsJson);
    assert(!vs.add.argsJson.canFind("value"),
        "the section row must NOT emit a value key alongside compare:all");
    assert(vs.remove.argsJson == `{"test":"edgeCount","compare":"all","mode":"remove"}`,
        vs.remove.argsJson);

    auto l2 = findLeaf(buf, "Vertices", "By Edge", "2");
    assert(l2.add.argsJson
        == `{"test":"edgeCount","compare":"equal","value":2,"mode":"add"}`,
        l2.add.argsJson);
    auto more = findLeaf(buf, "Vertices", "By Edge", ">4");
    assert(more.add.argsJson
        == `{"test":"edgeCount","compare":"more","value":4,"mode":"add"}`,
        more.add.argsJson);

    auto ep = allOpen(d, SelType.Polygon);
    auto bp = emit(d, SelType.Polygon, ep);
    auto part = findLeaf(bp, "Polygons", "Part", "Part 0");
    assert(part.add.commandId == "select.byTag");
    assert(part.add.argsJson == `{"type":"part","id":0,"mode":"add"}`,
        part.add.argsJson);
    assert(part.remove.argsJson == `{"type":"part","id":0,"mode":"remove"}`,
        part.remove.argsJson);

    // `select.set.apply`'s vocabulary is select/deselect — NOT add/remove, and
    // never `replace`.
    auto ei = allOpen(d, SelType.Item);
    auto bi = emit(d, SelType.Item, ei);
    auto mesh = findLeaf(bi, "Items", "By Type", "Mesh");
    assert(mesh.add.commandId == "layer.select");
    assert(mesh.add.argsJson == `{"kind":"mesh","mode":"add"}`, mesh.add.argsJson);
    assert(mesh.remove.argsJson == `{"kind":"mesh","mode":"remove"}`,
        mesh.remove.argsJson);
}

// ---------------------------------------------------------------------------
// The section TOTAL — the element count, equal to the sum of a partition
// category, and still there when the section is COLLAPSED (measured: a
// collapsed section carries its total).
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Vertex);
    auto buf = emit(d, SelType.Vertex, e);

    auto vs = findSection(buf, "Vertices");
    assert(vs.num.value == 8);
    long sum = 0;
    foreach (ref l; findCategory(buf, "Vertices", "By Edge").leaves)
        sum += l.num.value;
    assert(sum == vs.num.value, "By Edge partitions the vertices: "
        ~ sum.to!string ~ " vs " ~ vs.num.value.to!string);

    // Collapse the whole section: the header keeps its number and loses its
    // children.
    StatExpand collapsed;
    collapsed.section[cast(size_t) SelType.Vertex] = false;
    auto buf2 = emit(d, SelType.Vertex, collapsed);
    auto vs2 = findSection(buf2, "Vertices");
    assert(vs2.categories.length == 0, "a collapsed section emits no categories");
    assert(vs2.num.known && vs2.num.value == 8,
        "…and still carries its own total");
}

// ---------------------------------------------------------------------------
// EXPAND — a collapsed category emits its header and no leaves.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    StatExpand e;
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        e.section[cast(size_t) t] = true;           // sections open, CATEGORIES closed
    auto buf = emit(d, SelType.Vertex, e);
    auto cat = findCategory(buf, "Vertices", "By Edge");
    assert(cat !is null, "a collapsed category still has its header row");
    assert(cat.leaves.length == 0, "…and emits no leaves");

    e.category["Vertices/By Edge"] = true;
    auto buf2 = emit(d, SelType.Vertex, e);
    assert(findCategory(buf2, "Vertices", "By Edge").leaves.length == 6,
        "…and six of them when opened");
}

// ---------------------------------------------------------------------------
// THE FIRST-OPEN DEFAULT — OURS, not measured (the owner's first frame was not
// a freshly-opened panel). Pinned so it cannot drift silently; flipping the
// constant reddens THIS and nothing else, because every other test here sets
// the expand state explicitly.
// ---------------------------------------------------------------------------
unittest {
    StatExpand e;
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        assert(e.sectionOpen(t), "sections default OPEN");
    assert(!e.categoryOpen("Vertices/By Edge"), "categories default CLOSED");
    assert(!e.categoryOpen("anything at all"), "…including one never seen");
}

// ---------------------------------------------------------------------------
// `Polygons → By Type` — FIFTEEN rows, in the measured order, ending at
// Convex. There is no sixteenth row: the reference implements one and its own
// hard-coded loop bound hides it, so showing one would be a deliberate
// divergence with a registry row. MUTATION: append a Concave leaf → red.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);
    auto cat = findCategory(buf, "Polygons", "By Type");

    static immutable string[] want = [
        "Faces", "Subdivs", "Curves", "Bezier", "B-Spline", "SplinePatch",
        "Text", "Catmull-Clark", "Polyline", "Curve Fill", "Non-Planar",
        "Co-Located", "Co-Planar", "Angle", "Convex",
    ];
    assert(cat.leaves.length == 15,
        "fifteen type rows, got " ~ cat.leaves.length.to!string);
    foreach (i, w; want)
        assert(cat.leaves[i].label == w,
            "row " ~ i.to!string ~ " must be " ~ w ~ ", got " ~ cat.leaves[i].label);
    assert(!cat.leaves.map!(l => l.label).canFind("Concave"),
        "the sixteenth row is not ours to show");
}

// ---------------------------------------------------------------------------
// `By Type`'s three classes, and owner decision Р10: our ONE subpatch concept
// populates Subdivs; Catmull-Clark is a structural ZERO. One predicate never
// populates both.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto mm = &d.primary.meshRef();
    mm.setSubpatch(0, true);
    mm.setSubpatch(1, true);              // 2 of 6 faces are subpatches
    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);
    auto cat = findCategory(buf, "Polygons", "By Type");

    auto faces = &cat.leaves[0];
    auto subd  = &cat.leaves[1];
    auto cc    = &cat.leaves[7];
    assert(faces.num.known && faces.num.value == 4, "4 plain faces");
    assert(subd.num.known  && subd.num.value  == 2, "2 subpatch faces");
    assert(cc.num.known && cc.num.value == 0,
        "Catmull-Clark is a structural ZERO — a true 0, not a placeholder");
    assert(cc.avail == StatAvail.structuralZero);
    assert(subd.num.value + faces.num.value == cast(long) mm.faces.length,
        "the two rows partition the faces — one predicate, two complementary "
        ~ "rows, and NEVER the same faces counted twice");

    // Neither row can be acted on: there is no command that selects by our
    // subpatch flag. The absence of an affordance, not a greyed button.
    assert(faces.avail == StatAvail.noAffordance && faces.add.empty);
    assert(subd.avail  == StatAvail.noAffordance && subd.add.empty);

    // The structural zeros, and the unmeasured tail.
    foreach (i; [2, 3, 4, 5, 6, 8, 9])
        assert(cat.leaves[i].avail == StatAvail.structuralZero
            && cat.leaves[i].num.known && cat.leaves[i].num.value == 0,
            "row " ~ i.to!string ~ " is a true zero");
    foreach (i; [10, 11, 12, 13, 14])
        assert(cat.leaves[i].avail == StatAvail.unmeasured
            && !cat.leaves[i].num.known,
            "row " ~ i.to!string ~ " is unmeasured — `—`, never 0");
}

// ---------------------------------------------------------------------------
// The Layer category: live counts, MEASURED-inert actions.
// ---------------------------------------------------------------------------
unittest {
    Mesh a = makeCube();
    auto d = Document.bootstrap(a);
    auto b = new Layer;
    b.name = "B";
    b.meshRef() = makeCube();
    d.layers ~= b;                        // visible, not selected => background

    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);
    auto cat = findCategory(buf, "Polygons", "Layer");
    assert(cat.leaves.length == 2);
    assert(cat.leaves[0].label == "Foreground" && cat.leaves[0].num.value == 6);
    assert(cat.leaves[1].label == "Background" && cat.leaves[1].num.value == 6);
    foreach (ref l; cat.leaves) {
        assert(l.avail == StatAvail.inertActions,
            "the actions are measured to do nothing");
        assert(l.add.empty && l.remove.empty,
            "…so no command is dispatched at all");
        assert(l.sel.value == 0, "…and Sel is always 0 here (measured)");
    }
}

// ---------------------------------------------------------------------------
// THE EQUIVALENCE SWEEP OVER THE EMITTED TREE.
//
// `mesh_stats_test.d` proves count == mask for a TABLE of tuples. This proves
// the table is the tree: every leaf that dispatches a `select.byStat.*` command
// carries a `Num` equal to the popcount of that command's own mask. A row
// family added with a tuple nobody tested is caught here rather than shipping
// a number no test ever compared against the predicate.
// ---------------------------------------------------------------------------
unittest {
    import std.json : parseJSON;

    auto d = cubeDoc();
    auto mm = &d.primary.meshRef();
    mm.addWeightMap("W");
    foreach (vi; 0 .. mm.vertices.length)
        mm.setVertexWeight("W", vi, vi % 2 == 0 ? 1.0f : 0.0f);
    mm.faceMaterial.length = mm.faces.length;
    mm.faceMaterial[0] = 1;

    auto e = allOpen(d, SelType.Polygon);
    auto buf = emit(d, SelType.Polygon, e);
    auto ctx = ctxOf(d);

    Compare cmpOf(string s) {
        switch (s) {
            case "all":   return Compare.all;
            case "equal": return Compare.equal;
            case "less":  return Compare.less;
            default:      return Compare.more;
        }
    }

    size_t checked = 0;
    foreach (ref s; buf) {
        foreach (ref c; s.categories) {
            foreach (ref l; c.leaves) {
                if (l.add.empty) continue;
                auto j = parseJSON(l.add.argsJson);
                if ("test" !in j) continue;    // byTag / sets / layer rows
                const int val = ("value" in j) ? cast(int) j["value"].integer : -1;
                const string test = j["test"].str;
                long popcount;
                switch (l.add.commandId) {
                    case "select.byStat.vertex": {
                        auto vt = test == "edgeCount"    ? VertexStat.edgeCount
                                : test == "polygonCount" ? VertexStat.polygonCount
                                                         : VertexStat.weightMap;
                        const string map = ("map" in j) ? j["map"].str : "";
                        const Compare cp = ("compare" in j)
                                         ? cmpOf(j["compare"].str) : Compare.all;
                        popcount = cast(long) vertexStatMask(ctx, vt, cp, val, map)
                                                .count!(x => x);
                        break;
                    }
                    case "select.byStat.edge": {
                        auto et = test == "polygonCount"     ? EdgeStat.polygonCount
                                : test == "materialBoundary" ? EdgeStat.materialBoundary
                                                             : EdgeStat.partBoundary;
                        popcount = cast(long) edgeStatMask(ctx, et,
                                        cmpOf(j["compare"].str), val).count!(x => x);
                        break;
                    }
                    case "select.byStat.polygon":
                        popcount = cast(long) polygonStatMask(ctx,
                                        PolygonStat.vertexCount,
                                        cmpOf(j["compare"].str), val).count!(x => x);
                        break;
                    default: continue;      // byTag / sets / layer: other tests
                }
                assert(l.num.value == popcount,
                    "row " ~ c.key ~ "/" ~ l.label ~ " reports " ~ l.num.value.to!string
                    ~ " but its own command's mask selects " ~ popcount.to!string);
                ++checked;
            }
        }
    }
    assert(checked >= 20, "the sweep must reach every byStat row, saw "
        ~ checked.to!string);
}

// ---------------------------------------------------------------------------
// THE NEED AND THE TREE MAY NOT DRIFT.
//
// `statNeedOf` says which derived arrays an expand state will read, and the
// drawer builds only those — the "compute only what is on screen" rule, which
// Stage 5 measured as the difference between an 8.4 ms rebuild and a 0.1 ms one
// on a 99 856-face mesh. Its failure mode is silent and severe: a category that
// grows a reader without growing its need would read an EMPTY array and report
// a confident zero.
//
// So it is not reviewed, it is compared BY VALUE: every expand state below is
// emitted twice — once with a need-derived context, once with a full one — and
// every row of both must match, number for number.
// ---------------------------------------------------------------------------
unittest {
    auto d = cubeDoc();
    auto mm = &d.primary.meshRef();
    mm.faceMaterial.length = mm.faces.length;
    mm.faceMaterial[0] = 1;                 // a real tag boundary to count
    mm.facePart.length = mm.faces.length;
    mm.facePart[1] = 3;
    mm.selectFace(0);

    void sameBothWays(ref StatExpand e, string what) {
        auto mp = d.primary.meshOrNull();
        auto lean = buildStatContext(*mp, statNeedOf(e));
        auto full = buildStatContext(*mp, StatNeed.all);
        StatSection[] a, b;
        statSectionsInto(&d, SelType.Polygon, lean, e, a);
        statSectionsInto(&d, SelType.Polygon, full, e, b);
        assert(a.length == b.length, what ~ ": section count differs");
        foreach (si; 0 .. a.length) {
            assert(a[si].categories.length == b[si].categories.length,
                what ~ ": category count differs in " ~ a[si].label);
            foreach (ci; 0 .. a[si].categories.length) {
                auto ca = a[si].categories[ci], cb = b[si].categories[ci];
                assert(ca.leaves.length == cb.leaves.length,
                    what ~ ": leaf count differs in " ~ ca.key);
                foreach (li; 0 .. ca.leaves.length)
                    assert(ca.leaves[li].num == cb.leaves[li].num
                        && ca.leaves[li].sel == cb.leaves[li].sel,
                        what ~ ": " ~ ca.key ~ "/" ~ ca.leaves[li].label
                        ~ " reads " ~ ca.leaves[li].num.value.to!string
                        ~ " with a lean context and "
                        ~ cb.leaves[li].num.value.to!string ~ " with a full one "
                        ~ "— `statNeedOf` is missing an array this row reads");
            }
        }
    }

    // (a) the first-open state: sections open, every category closed.
    {
        StatExpand e;
        foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
            e.section[cast(size_t) t] = true;
        assert(statNeedOf(e) == StatNeed.none,
            "with every category closed, nothing derived is read at all");
        sameBothWays(e, "first-open");
    }

    // (b) everything open — the worst case, and the one that must ask for all
    // four arrays.
    {
        auto e = allOpen(d, SelType.Polygon);
        assert(statNeedOf(e) == StatNeed.all,
            "with everything open the tree reads every derived array");
        sameBothWays(e, "all-open");
    }

    // (c) ONE category at a time. This is the arm that catches a need which is
    // right in aggregate and wrong per category.
    auto every = allOpen(d, SelType.Polygon);
    foreach (key; every.category.byKey) {
        StatExpand e;
        foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
            e.section[cast(size_t) t] = true;
        e.category[key] = true;
        sameBothWays(e, "only " ~ key);
    }
}
