// THE ROW↔COMMAND INVARIANT (task 1100 Stage 3.1 + 3.3).
//
// The panel and the command it fires may not disagree about what a row IS. The
// invariant, for one row of every category that has actions:
//
//     clear the selection → press the row's `+` → the row reads Sel == Num
//
// It is stated with the three fixes owner decision Р7 required after the first
// version of it turned out to pass vacuously three different ways:
//
//   1. `num > 0` is asserted FIRST. Every category has a zero row — Stage 2
//      REQUIRES one — and `0 == 0` holds under any implementation, so picking a
//      zero row by accident is easy and proves nothing.
//   2. `sel.known` is asserted BEFORE the comparison. With the gate shut the
//      comparison reads a default-initialised field.
//   3. The row's own equality is paired with the MESH-WIDE TOTAL, and with a
//      disjoint neighbouring row reading 0. Without the total, a `+` that
//      selected a SUPERSET still gives `Sel == Num` on its own row: on a tagged
//      cube a Material row whose click wrongly selected all six faces reads
//      `2 == 2` and only the total exposes it.
//
// This lives in the unit lane and not over HTTP because `Num`, `Sel` and above
// all `sel.known` are row-model FIELDS, and no wire carries them.

import document : Document, Layer, ItemKind;
import editmode : EditMode;
import mesh;
import mesh_selsets;
import mesh_stats;
import seltype  : SelType, SelMode;
import ui.stat_rows;
import tests.unit.ui.stat_dispatch : dispatchStatAction;
import math     : Vec3;
import std.algorithm : canFind;
import std.conv  : to;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
private StatContext ctxOf(ref Document d) {
    auto m = d.hasEditTarget() ? d.primary.meshOrNull() : null;
    return m is null ? StatContext.init : buildStatContext(*m);
}

private StatExpand allOpen(ref Document d, SelType current) {
    StatExpand e;
    // Sections opened EXPLICITLY, never inherited from the first-open default:
    // that default is ours rather than measured, and a helper that leaned on it
    // would turn every test in this file red the day it changes. Its own pin is
    // the one place it is asserted.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        e.section[cast(size_t) t] = true;
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

private StatLeaf leafOf(ref Document d, SelType current, ref StatExpand e,
                        string sec, string cat, string leaf) {
    auto buf = emit(d, current, e);
    foreach (ref s; buf) {
        if (s.label != sec) continue;
        foreach (ref c; s.categories) {
            if (c.label != cat) continue;
            foreach (ref l; c.leaves) if (l.label == leaf) return l;
        }
    }
    assert(false, "no such row: " ~ sec ~ "/" ~ cat ~ "/" ~ leaf);
}

private Document taggedCubeDoc() {
    Mesh m = makeCube();
    auto d = Document.bootstrap(m);
    auto mm = &d.primary.meshRef();
    mm.syncSelection();
    mm.faceMaterial.length = mm.faces.length;
    mm.facePart.length     = mm.faces.length;
    mm.faceMaterial[0] = 1;
    mm.faceMaterial[2] = 1;
    mm.faceMaterial[4] = 2;
    mm.facePart[3]     = 7;
    mm.surfaces = [Surface("Default"), Surface("Red"), Surface("Blue")];
    return d;
}

// ---------------------------------------------------------------------------
// THE INVARIANT, per category. Each arm: arm the mode, clear, press `+`,
// re-read the row, and check all four things.
// ---------------------------------------------------------------------------

// (1) byStat — Polygons → By Vertex. A stand with BOTH quads and triangles, so
// the neighbouring row is disjoint AND non-empty.
unittest {
    auto m = new Mesh;
    foreach (i; 0 .. 20) m.addVertex(Vec3(cast(float) i, 0, 0));
    m.addFace([0u, 1u, 2u]);              // 2 triangles …
    m.addFace([3u, 4u, 5u]);
    m.addFace([6u, 7u, 8u, 9u]);          // … and 3 quads
    m.addFace([10u, 11u, 12u, 13u]);
    m.addFace([14u, 15u, 16u, 17u]);
    m.buildLoops();
    m.syncSelection();
    auto d = Document.bootstrap(*m);
    auto mm = &d.primary.meshRef();
    mm.clearFaceSelection();

    auto e = allOpen(d, SelType.Polygon);
    auto row = leafOf(d, SelType.Polygon, e, "Polygons", "By Vertex", "4");
    assert(row.num.value > 0, "a zero row proves nothing — pick one with rows");
    assert(row.sel.known, "the gate must be OPEN before comparing anything");
    assert(row.num.value == 3, "three quads");

    auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Polygon,
                                row.add.commandId, row.add.argsJson);
    assert(r.ran, "the row's own command must run: " ~ r.reason);

    auto after = leafOf(d, SelType.Polygon, e, "Polygons", "By Vertex", "4");
    assert(after.sel.value == after.num.value,
        "Sel == Num after the row's own `+`: " ~ after.sel.value.to!string
        ~ " vs " ~ after.num.value.to!string);
    assert(mm.countSelectedFaces() == after.num.value,
        "…and the MESH-WIDE total agrees — this is the half that catches a `+` "
        ~ "which selected a superset");
    auto tris = leafOf(d, SelType.Polygon, e, "Polygons", "By Vertex", "3");
    assert(tris.num.value == 2 && tris.sel.value == 0,
        "a disjoint neighbour in the same category must stay unselected");
}

// (2) Part rows — `select.byTag type:part id:N`, labelled by id.
unittest {
    auto d = taggedCubeDoc();
    auto mm = &d.primary.meshRef();
    mm.clearFaceSelection();

    auto e = allOpen(d, SelType.Polygon);
    auto row = leafOf(d, SelType.Polygon, e, "Polygons", "Part", "Part 7");
    assert(row.num.value > 0 && row.sel.known);
    assert(row.num.value == 1, "one face carries part 7");

    auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Polygon,
                                row.add.commandId, row.add.argsJson);
    assert(r.ran, r.reason);

    auto after = leafOf(d, SelType.Polygon, e, "Polygons", "Part", "Part 7");
    assert(after.sel.known && after.sel.value == after.num.value);
    assert(mm.countSelectedFaces() == after.num.value,
        "the total must agree — a superset would pass the row's own check");
    auto other = leafOf(d, SelType.Polygon, e, "Polygons", "Part", "Part 0");
    assert(other.num.value == 5 && other.sel.value == 0,
        "the neighbouring part row is untouched");
}

// (3) Material rows — the NAME arm, and the row list that comes from the tags
// actually present.
unittest {
    auto d = taggedCubeDoc();
    auto mm = &d.primary.meshRef();
    mm.clearFaceSelection();

    auto e = allOpen(d, SelType.Polygon);
    auto row = leafOf(d, SelType.Polygon, e, "Polygons", "Material", "Red");
    assert(row.num.value == 2 && row.sel.known);

    auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Polygon,
                                row.add.commandId, row.add.argsJson);
    assert(r.ran, r.reason);

    auto after = leafOf(d, SelType.Polygon, e, "Polygons", "Material", "Red");
    assert(after.sel.value == after.num.value);
    assert(mm.countSelectedFaces() == after.num.value,
        "Red is 2 of 6 — the total is what catches a `+` that took all six");
    auto blue = leafOf(d, SelType.Polygon, e, "Polygons", "Material", "Blue");
    assert(blue.num.value == 1 && blue.sel.value == 0);
}

// (3b) THE PRECONDITION IS LOAD-BEARING. `select.byTag` demands Polygons mode
// and, unlike `select.byStat.*`, does NOT promote — so the same row fired in
// the wrong mode refuses and selects nothing. Dropping the precondition from
// the arm above is one of Р7's three vacuous passes, made visible here.
unittest {
    auto d = taggedCubeDoc();
    auto mm = &d.primary.meshRef();
    mm.clearFaceSelection();
    auto e = allOpen(d, SelType.Polygon);
    auto row = leafOf(d, SelType.Polygon, e, "Polygons", "Material", "Red");

    auto r = dispatchStatAction(&d, mm, EditMode.Vertices, SelType.Vertex,
                                row.add.commandId, row.add.argsJson);
    assert(!r.ran, "the wrong mode must REFUSE (and not throw — it has a button)");
    assert(r.reason.canFind("Polygons"), r.reason);
    assert(mm.countSelectedFaces() == 0, "…and change nothing");
}

// (4) Selection-set rows — `select.set.apply`, whose modes are
// select/deselect, never add/remove.
unittest {
    auto d = taggedCubeDoc();
    auto mm = &d.primary.meshRef();
    mm.clearFaceSelection();
    mm.selectFace(0); mm.selectFace(1);
    selSetEditPolygon(*mm, "A", SetEditMode.replace, mm.selectedFaces);
    mm.clearFaceSelection();
    mm.selectFace(4);
    selSetEditPolygon(*mm, "B", SetEditMode.replace, mm.selectedFaces);
    mm.clearFaceSelection();

    auto e = allOpen(d, SelType.Polygon);
    auto row = leafOf(d, SelType.Polygon, e, "Polygons", "By Selection Set", "A");
    assert(row.num.value == 2 && row.sel.known);

    auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Polygon,
                                row.add.commandId, row.add.argsJson);
    assert(r.ran, r.reason);

    auto after = leafOf(d, SelType.Polygon, e, "Polygons", "By Selection Set", "A");
    assert(after.sel.value == after.num.value);
    assert(mm.countSelectedFaces() == after.num.value);
    auto b = leafOf(d, SelType.Polygon, e, "Polygons", "By Selection Set", "B");
    assert(b.num.value == 1 && b.sel.value == 0);
}

// (5) Items — one command, one undo entry, and the same invariant on the item
// domain (owner decision Р5).
unittest {
    Mesh a = makeCube();
    auto d = Document.bootstrap(a);
    foreach (i; 0 .. 2) {
        auto l = new Layer;
        l.name = "M" ~ i.to!string;
        l.meshRef() = makeCube();
        d.layers ~= l;
    }
    auto empty = new Layer;
    empty.name = "E";
    empty.kind = ItemKind.Empty;
    d.layers ~= empty;
    d.selectItem(empty, SelMode.Add);           // the neighbour row starts selected
    d.selectItem(empty, SelMode.Remove);        // …and is cleared again
    assert(d.layers.length == 4);

    auto mm = &d.primary.meshRef();
    auto e = allOpen(d, SelType.Item);
    auto row = leafOf(d, SelType.Item, e, "Items", "By Type", "Mesh");
    assert(row.num.value == 3 && row.sel.known);

    auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                                row.add.commandId, row.add.argsJson);
    assert(r.ran, r.reason);

    auto after = leafOf(d, SelType.Item, e, "Items", "By Type", "Mesh");
    assert(after.sel.value == after.num.value,
        "every mesh item is selected by ONE click: " ~ after.sel.value.to!string);
    assert(d.selectedItemCount() == after.num.value,
        "…and the document-wide total agrees — a `+` that also took the "
        ~ "non-mesh item would pass the row's own check");
    auto other = leafOf(d, SelType.Item, e, "Items", "By Type", "Empty");
    assert(other.num.value == 1 && other.sel.value == 0,
        "the other kind's row is untouched");

    // ONE undo entry, and the exact prior set restored — the command batches
    // inside its own apply()/revert() over the single snapshot it already took.
    assert(r.cmd.isUndoable(), "a UiState command is one undo entry");
    assert(r.cmd.revert(), "revert must report success");
    auto back = leafOf(d, SelType.Item, e, "Items", "By Type", "Mesh");
    assert(back.sel.value == 1,
        "the exact prior selection comes back — the bootstrap's single "
        ~ "selected layer, not all three, got " ~ back.sel.value.to!string);
}

// ---------------------------------------------------------------------------
// Stage 3.1 — `layer.select kind:` on its own: the batch, the exact restore,
// and the two refusals.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import commands.layer.commands : LayerSelect;
    import params : injectParamsInto;
    import std.json : parseJSON;

    Document build() {
        Mesh a = makeCube();
        auto d = Document.bootstrap(a);
        foreach (i; 0 .. 2) {
            auto l = new Layer;
            l.name = "M" ~ i.to!string;
            l.meshRef() = makeCube();
            d.layers ~= l;
        }
        auto e = new Layer;
        e.name = "E";
        e.kind = ItemKind.Empty;
        d.layers ~= e;
        return d;
    }

    // The batch: exactly the three mesh layers, and NOT the non-mesh one.
    {
        auto d = build();
        auto mm = &d.primary.meshRef();
        auto before = d.primary;
        auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                                    "layer.select", `{"kind":"mesh","mode":"add"}`);
        assert(r.ran, r.reason);
        size_t sel = 0;
        foreach (l; d.layers) if (l.selected) ++sel;
        assert(sel == 3, "all three mesh layers, got " ~ sel.to!string);
        assert(!d.layers[3].selected, "…and not the non-mesh item");

        // …and revert puts the exact prior set back, primary identity included.
        assert(r.cmd.revert());
        size_t after = 0;
        foreach (l; d.layers) if (l.selected) ++after;
        assert(after == 1, "one selected layer again, got " ~ after.to!string);
        assert(d.primary is before, "…and the same primary object");
    }

    // `remove` is the `-` column, and it subtracts the whole kind.
    {
        auto d = build();
        auto mm = &d.primary.meshRef();
        auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                                    "layer.select", `{"kind":"mesh","mode":"remove"}`);
        assert(r.ran, r.reason);
        foreach (l; d.layers) assert(!l.selected, "every mesh item deselected");

        // MEASURED HERE, and it CORRECTS the plan (risk 12): emptying the item
        // selection does NOT null the edit target. `Document.selectItem`'s
        // Remove arm moves the item to its kind's history bucket and the target
        // is the head of [current ++ history], so the last mesh removed stays
        // LATCHED — "ctrl-clicking the last selected mesh empties the selection
        // and keeps editing that mesh" is that arm's own comment. So this
        // panel's `-` button reaches the LATCHED state, not the absent one.
        //
        // The null guard in the row model is not thereby optional: the absent
        // state is live and `document.d` builds and asserts it (a document in
        // which no primary-eligible item ever had a selection state — a load,
        // or an assembly by direct field writes). What is wrong is only the
        // ROUTE the plan named. `stat_rows_test.d` pins the guard against the
        // real state; this pins what the button actually does.
        assert(d.hasEditTarget(),
            "the edit target is LATCHED, not lost, when the last mesh item "
            ~ "leaves the selection");
        assert(d.primary !is null && !d.primary.selected,
            "…so `primary` is non-null and not selected — the state the panel "
            ~ "draws in after its own `-`");
        assert(d.selectedItemCount() == 0, "…with nothing selected at all");
    }

    // An unknown kind token is rejected TWICE, by two different layers, and
    // the test says which is which because they answer differently.
    {
        // (a) Through the ARGUMENT layer — the path a panel click and HTTP both
        // take. `Param.enum_` validates the token and `injectParamsInto`
        // THROWS before `apply()` is ever called. The panel cannot reach this:
        // its tokens are `kindInfo(k).token`, i.e. the enum's own choices.
        import std.exception : collectExceptionMsg;
        auto d = build();
        auto mm = &d.primary.meshRef();
        auto msg = collectExceptionMsg(
            dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                               "layer.select", `{"kind":"bogus","mode":"add"}`));
        assert(msg.canFind("bogus") && msg.canFind("kind"),
            "the argument layer rejects the token by name: " ~ msg);
        size_t sel = 0;
        foreach (l; d.layers) if (l.selected) ++sel;
        assert(sel == 1, "nothing changed");
    }
    {
        // (b) Inside `apply()`, reached by poking the param directly — the same
        // double-check `select.byStat` documents, and the arm that matters if a
        // caller ever bypasses the Param layer. Here it is a REFUSAL, never a
        // throw, because this command has a button.
        auto d = build();
        auto mm = &d.primary.meshRef();
        View v = new View(0, 0, 1, 1);
        auto c = new LayerSelect(mm, v, EditMode.Polygons, &d, null);
        foreach (ref pp; c.params()) {
            if (pp.name == "kind") *pp.sptr = "bogus";
            if (pp.name == "mode") *pp.sptr = "add";
        }
        assert(!c.apply(), "an unknown kind must REFUSE, not throw");
        assert(c.refusalReason().canFind("bogus"), c.refusalReason());
        size_t sel = 0;
        foreach (l; d.layers) if (l.selected) ++sel;
        assert(sel == 1, "nothing changed");
    }

    // `set`/`toggle` over a whole kind are refused DELIBERATELY: the `+`/`-`
    // law is measured as "never a replace, never a toggle".
    foreach (mode; ["set", "toggle", "clear"]) {
        auto d = build();
        auto mm = &d.primary.meshRef();
        auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                                    "layer.select",
                                    `{"kind":"mesh","mode":"` ~ mode ~ `"}`);
        if (mode == "clear") {
            // `clear` names no target at all and is answered by its own arm,
            // ahead of the kind branch — recorded so the narrowing above is not
            // mistaken for a claim about `clear`.
            assert(r.ran, "mode:clear keeps its own meaning");
            continue;
        }
        assert(!r.ran, "kind + mode:" ~ mode ~ " must refuse");
        assert(r.reason.canFind(mode), r.reason);
        size_t sel = 0;
        foreach (l; d.layers) if (l.selected) ++sel;
        assert(sel == 1, "a refusal changes nothing");
    }

    // An OMITTED kind is today's behaviour, exactly — the property that makes
    // this argument safe to add to a command with existing callers.
    {
        auto d = build();
        auto mm = &d.primary.meshRef();
        auto r = dispatchStatAction(&d, mm, EditMode.Polygons, SelType.Item,
                                    "layer.select", `{"index":2,"mode":"set"}`);
        assert(r.ran, r.reason);
        size_t sel = 0;
        foreach (l; d.layers) if (l.selected) ++sel;
        assert(sel == 1 && d.layers[2].selected,
            "an omitted kind selects by index, as it always did");
    }
}
