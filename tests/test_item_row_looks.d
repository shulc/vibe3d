// WHICH PIXELS an item row is drawn with, in each of the four states the
// owner's report put in play. (Task 0672, Ph3.)
// Fixture: tests/fixtures/item_row_appearance.json.
//
// ── WHY "THE ROLE IS COMPUTED CORRECTLY" IS NOT THE TEST ────────────────────
//
// It passes today. The model was never wrong: `Document` has always been able
// to say that a mesh is the edit target while a plane holds the selection.
// What broke is the DRAWING — `ui/item_rows.d` asked `isPrimary` before it
// asked `selected`, and `isCurrentRole` gave the edit target the same
// background and the same accent ink as a selected row. So the assertion has
// to be about the row's APPEARANCE, and it has to be able to fail on a
// document whose model answers are all correct.
//
// `ItemRow.role` + `ItemRow.look` are that appearance: the role picks the
// glyph (`ui/item_glyphs.d`) and the look carries the row fill and the ink for
// every mark on it. They are read here as one value, so a state that changed
// only the glyph would still be caught.
//
// ── THE FOUR STATES, AND WHY THEY ARE ALL ON ONE ROW ────────────────────────
//
// m1 — a mesh — visits four of the seven states with its own name, glyph,
// depth and neighbours unchanged, which is the discipline the capture used:
//
//   neither                        a fresh document where m2 was selected
//   selected_first_and_target      `set m1`
//   selected_not_first_and_target  `set plane; add m1`
//   edit_target_not_selected       `set m1; set plane`     ← the owner's case
//
// The remaining three need a second row by necessity, not by convenience:
//
//   selected_first_not_target           the plane in `set plane; add m1`
//   selected_not_first_not_target       m2 in `set m1; add m2`
//   foreground_not_target_not_selected  m2 in `set m1; add m2; set plane`
//
// `edit_target_not_selected` cannot coexist with a selected mesh in one frame:
// the edit target is the head of a walk that puts the CURRENT selection ahead
// of the deselect history (task 0671), so while any mesh is selected the
// target is a selected mesh.
//
// ── WHAT THE FIXTURE CONTRIBUTES, AND WHAT IT DOES NOT ──────────────────────
//
// The RGBs in the fixture belong to the reference's colour scheme and are
// provenance, not a target: our panel runs on a light backdrop where they are
// unreadable, and the fixture says so itself ("what must port is the
// partition"). What is read out of it and asserted here is the PARTITION —
// `assertions.must_render_identically`, `assertions.must_render_differently`
// and the `state_to_treatment` table — against our own three treatments.
//
// The one hand-written correspondence is `kTreatmentRole` below: which of our
// `RowRole` values plays each of the reference's three treatments. That
// mapping IS the port, so it is stated in one place rather than spread through
// the assertions.
//
// ── WHAT WRONG IMPLEMENTATIONS THIS DISCRIMINATES AGAINST ───────────────────
//
//   * the shipped one — `roleOf` asking `isPrimary` first: reads the
//     first-selected treatment on `edit_target_not_selected`, which the first
//     identity pair forbids;
//   * "the loud treatment marks the edit target": reads it on m1 rather than
//     on the plane in `set plane; add m1`, breaking BOTH the
//     selected_first pair and the selected_not_first pair;
//   * "the loud treatment marks the focus" (the newest touch, i.e. the other
//     end of the queue): reads it on m1 in `set plane; add m1`, same failure;
//   * "there is only one selected treatment": passes every identity pair and
//     fails `must_render_differently` on (selected_first, selected_not_first).

import std.json;
import std.format : format;
import std.conv   : to;

import mesh     : makeCube;
import seltype  : SelMode;
import document : Document, Layer, ItemKind, LayerRole;
import ui.item_rows : ItemRow, RowRole, RowLook, itemRowsInto, lookOf;

void main() {}

enum string fixtureJson = import("fixtures/item_row_appearance.json");

// ---------------------------------------------------------------------------
// The port statement: the reference's three treatments, and the `RowRole` each
// one is played by here. Nothing else in this file names a treatment, and a
// treatment with no role is a hard stop rather than a skipped assertion.
// ---------------------------------------------------------------------------
RowRole roleForTreatment(string id) {
    switch (id) {
        case "unselected":         return RowRole.None;
        case "selected_first":     return RowRole.SelectedFirst;
        case "selected_not_first": return RowRole.Selected;
        default:
            assert(false, "no RowRole plays fixture treatment '" ~ id ~ "'");
    }
}

/// A row's drawn appearance: the glyph token and the colours. Compared as one
/// value so a difference in EITHER is a difference in the row.
struct Drawn {
    RowRole role;
    RowLook look;
    string  toStringForMsg() const {
        return format("role=%s bg=(%d,%d,%d,%d) ink=(%d,%d,%d,%d)",
            role, look.background.r, look.background.g, look.background.b,
            look.background.a, look.ink.r, look.ink.g, look.ink.b, look.ink.a);
    }
}

struct Rig {
    Document doc;
    Layer m1, m2, plane;
}

Layer addLayer(ref Rig r, string name, ItemKind k) {
    auto l = new Layer;
    l.name    = name;
    l.kind    = k;
    l.visible = true;
    r.doc.layers ~= l;
    return l;
}

/// A FRESH document per cell. The deselect history latches (task 0671), so a
/// cell run on the previous cell's document would inherit an edit target the
/// commands in front of it never asked for.
Rig makeRig() {
    Rig r;
    r.doc = Document.bootstrap(makeCube());
    r.m1  = r.doc.layers[0];
    r.m1.name = "m1";
    r.m2    = addLayer(r, "m2",    ItemKind.Mesh);
    r.plane = addLayer(r, "plane", ItemKind.ImagePlane);
    // `resetSelectionState`, NOT `clearItemSelection`: clearing is a user
    // operation and MOVES the selected items into their history buckets, so
    // the mesh `bootstrap` selects would come back as a latched edit target
    // and the "neither" cell would not be "neither" at all. This throws the
    // buckets away too, which is what a stated baseline means here.
    r.doc.resetSelectionState();
    return r;
}

ItemRow rowOf(ref Rig r, Layer l) {
    ItemRow[] rows;
    itemRowsInto(&r.doc, "", false, true, rows);
    foreach (row; rows) if (row.layer is l) return row;
    assert(false, "layer '" ~ l.name ~ "' has no row");
}

// ---------------------------------------------------------------------------
// The seven states, each measured off a real document, with the state itself
// READ BACK from the document rather than assumed from the commands.
// ---------------------------------------------------------------------------

struct State {
    Drawn drawn;
    bool  selected;
    bool  firstSelected;
    bool  editTarget;
    bool  foreground;
}

State[string] measureStates() {
    State[string] s;

    void record(string name, ref Rig r, Layer l) {
        auto row = rowOf(r, l);
        assert(!row.dimmed,
            "rig precondition: no row in this stand is DIMMED ('" ~ name
            ~ "' is) — dimming re-inks a row for a reason that has nothing to "
            ~ "do with this test, and would make an identity pair fail or "
            ~ "pass for the wrong reason");
        State st;
        st.drawn         = Drawn(row.role, row.look);
        st.selected      = l.selected;
        st.firstSelected = r.doc.isFirstSelected(l);
        st.editTarget    = r.doc.isPrimary(l);
        st.foreground    = r.doc.roleOf(l) == LayerRole.Foreground;
        assert(name !in s, "duplicate state '" ~ name ~ "'");
        s[name] = st;
    }

    // ---- neither: m1 was never selected, and something else is ------------
    {
        auto r = makeRig();
        r.doc.selectItem(r.m2, SelMode.Set);
        assert(!r.m1.selected && !r.doc.isPrimary(r.m1)
            && r.doc.roleOf(r.m1) != LayerRole.Foreground,
            "rig: m1 is outside the selection, is not the edit target and is "
            ~ "not even foreground");
        record("neither", r, r.m1);
    }

    // ---- selected_first_and_target: `set m1` ------------------------------
    {
        auto r = makeRig();
        r.doc.selectItem(r.m1, SelMode.Set);
        assert(r.m1.selected && r.doc.isFirstSelected(r.m1)
            && r.doc.isPrimary(r.m1), "rig: sole selection, first, and target");
        record("selected_first_and_target", r, r.m1);
    }

    // ---- `set plane; add m1` — the discriminating cell ---------------------
    // The plane heads the selection and can NEVER be a mesh edit target; m1
    // is the target and is second. The capture's D1, and the cell that told
    // "the loud treatment marks the target" apart from "it marks the first
    // element of the selection".
    {
        auto r = makeRig();
        r.doc.selectItem(r.plane, SelMode.Set);
        r.doc.selectItem(r.m1,    SelMode.Add);
        assert(r.doc.isFirstSelected(r.plane) && !r.doc.isPrimary(r.plane),
            "rig: the first-selected row is one that cannot be an edit target");
        assert(r.doc.isPrimary(r.m1) && r.m1.selected
            && !r.doc.isFirstSelected(r.m1),
            "rig: the edit target is selected and is NOT first");
        record("selected_first_not_target",     r, r.plane);
        record("selected_not_first_and_target", r, r.m1);
    }

    // ---- selected_not_first_not_target: `set m1; add m2` -------------------
    {
        auto r = makeRig();
        r.doc.selectItem(r.m1, SelMode.Set);
        r.doc.selectItem(r.m2, SelMode.Add);
        assert(r.m2.selected && !r.doc.isFirstSelected(r.m2)
            && !r.doc.isPrimary(r.m2),
            "rig: selected, later in the selection, not the edit target");
        record("selected_not_first_not_target", r, r.m2);
    }

    // ---- edit_target_not_selected: `set m1; set plane` ---------------------
    // The owner's case, reached the way the owner reached it: creating (here,
    // selecting) a reference plane drops the mesh from the selection while the
    // edit target latches onto it.
    {
        auto r = makeRig();
        r.doc.selectItem(r.m1,    SelMode.Set);
        r.doc.selectItem(r.plane, SelMode.Set);
        assert(!r.m1.selected && r.doc.isPrimary(r.m1)
            && r.doc.roleOf(r.m1) == LayerRole.Foreground,
            "rig: the edit target is latched onto a DESELECTED mesh — if this "
            ~ "fails the state under test is not reachable and the whole "
            ~ "identity pair below is vacuous");
        record("edit_target_not_selected", r, r.m1);
    }

    // ---- foreground_not_target_not_selected: two latched meshes ------------
    // Both meshes land in the mesh history bucket, so both are foreground;
    // the walk's head is the earlier one, so m2 is foreground WITHOUT being
    // the target — the reference's C7/C7b lever, which moved 0 px.
    {
        auto r = makeRig();
        r.doc.selectItem(r.m1,    SelMode.Set);
        r.doc.selectItem(r.m2,    SelMode.Add);
        r.doc.selectItem(r.plane, SelMode.Set);
        assert(!r.m2.selected && !r.doc.isPrimary(r.m2)
            && r.doc.roleOf(r.m2) == LayerRole.Foreground,
            "rig: foreground, not the edit target, not selected");
        assert(r.doc.isPrimary(r.m1),
            "rig: …and the OTHER mesh is the target, so the two rows differ "
            ~ "in exactly the fact under test");
        record("foreground_not_target_not_selected", r, r.m2);
    }

    return s;
}

// ---------------------------------------------------------------------------
// P1 — provenance, and the fixture really is the one this test was written
// against.
// ---------------------------------------------------------------------------
unittest {
    auto fx = parseJSON(fixtureJson);
    assert(fx["schema"].str == "item_row_appearance/1",
        "fixture schema moved: " ~ fx["schema"].str);
    assert(fx["distinct_state_treatments"].integer == 3,
        "the fixture found THREE state treatments; this test ports three");
    assert(fx["treatments"].array.length == 3);
    bool[RowRole] played;
    foreach (t; fx["treatments"].array)
        played[roleForTreatment(t["id"].str)] = true;   // asserts inside on a miss
    assert(played.length == 3,
        "the three treatments are played by three DIFFERENT roles — two "
        ~ "sharing one would collapse the partition this fixture is about");
}

// ---------------------------------------------------------------------------
// P2 — THE LOAD-BEARING ONE: every pair the fixture says must render
// identically, does.
//
// The first pair is the owner's bug. It is the pair that fails on the shipped
// code, where `roleOf` asks `isPrimary` before it asks `selected` and the
// latched target is drawn with the selection's own background and ink.
// ---------------------------------------------------------------------------
unittest {
    auto states = measureStates();
    auto fx = parseJSON(fixtureJson);

    foreach (pair; fx["assertions"]["must_render_identically"].array) {
        immutable a = pair.array[0].str, b = pair.array[1].str;
        assert(a in states, "no rig builds state '" ~ a ~ "'");
        assert(b in states, "no rig builds state '" ~ b ~ "'");
        assert(states[a].drawn == states[b].drawn,
            format("'%s' and '%s' must render identically, and do not:\n"
                   ~ "    %s : %s\n    %s : %s",
                   a, b, a, states[a].drawn.toStringForMsg(),
                   b, states[b].drawn.toStringForMsg()));
    }

    // The pairs above are only a claim about the DRAWING while the two states
    // really are different states. Assert the difference the fixture names, on
    // the document, for the load-bearing pair.
    assert(states["edit_target_not_selected"].editTarget
        && !states["neither"].editTarget,
        "vacuity guard: the two rows compared as identical differ in exactly "
        ~ "the fact under test — one IS the edit target and the other is not");
    assert(!states["edit_target_not_selected"].selected
        && !states["neither"].selected,
        "…and neither of them is selected, or the pair would be about "
        ~ "something else entirely");
    assert(states["selected_first_and_target"].editTarget
        && !states["selected_first_not_target"].editTarget,
        "vacuity guard: the selected pair differs in target-ness too");
    assert(states["selected_first_and_target"].firstSelected
        && states["selected_first_not_target"].firstSelected,
        "…while BOTH head the selection, which is the fact that may show");
}

// ---------------------------------------------------------------------------
// P3 — every pair the fixture says must render differently, does.
//
// Without this, P2 passes on a panel that draws every row identically. The
// third pair is the treatment we did not have before this task: the first
// element of the selection, drawn apart from the rest of it.
// ---------------------------------------------------------------------------
unittest {
    auto fx = parseJSON(fixtureJson);

    Drawn treatment(string id) {
        immutable role = roleForTreatment(id);
        return Drawn(role, lookOf(role, false));
    }

    foreach (pair; fx["assertions"]["must_render_differently"].array) {
        immutable a = pair.array[0].str, b = pair.array[1].str;
        // The COLOURS, specifically, and not merely `Drawn`: the three roles
        // are distinct by construction, so comparing the whole row would let
        // two treatments painted the same colour pass on their glyphs alone.
        // What the capture measured differing is the background and the ink —
        // the mode icon is on BOTH selected treatments.
        assert(treatment(a).look != treatment(b).look,
            format("'%s' and '%s' must render differently, and their colours "
                   ~ "are identical: %s",
                   a, b, treatment(a).toStringForMsg()));
        assert(treatment(a).role != treatment(b).role,
            format("'%s' and '%s' are played by the same RowRole", a, b));
    }
}

// ---------------------------------------------------------------------------
// P4 — the whole `state_to_treatment` table, driven by the fixture.
//
// P2 and P3 are the partition's edges; this is the partition. Each measured
// state's OWN readings (selected / first / edit target / foreground, all read
// back off the document) select exactly one row of the fixture's table, and
// the treatment that row names must be the one the panel drew.
// ---------------------------------------------------------------------------
unittest {
    auto states = measureStates();
    auto fx = parseJSON(fixtureJson);

    /// The fixture row matching a measured state, or "" if none.
    string treatmentFor(const State st) {
        string found;
        size_t hits = 0;
        foreach (row; fx["state_to_treatment"].array) {
            if (row["selected"].boolean != st.selected) continue;
            if (row["edit_target"].boolean != st.editTarget) continue;
            if (st.selected) {
                // `selection_index` 0 is "heads the selection"; every larger
                // index is the same state as far as this test can build.
                immutable bool rowFirst = row["selection_index"].integer == 0;
                if (rowFirst != st.firstSelected) continue;
            } else {
                if (row["foreground"].boolean != st.foreground) continue;
            }
            // SEVERAL rows can match, and legitimately: the table lists
            // selection index 1 and index 2 separately while this stand can
            // only build "heads the selection" versus "does not". What is not
            // allowed is for them to name DIFFERENT treatments — that would
            // mean the keys matched on here do not determine the drawing.
            ++hits;
            assert(found.length == 0 || found == row["treatment"].str,
                "the fixture rows matching one state name two different "
                ~ "treatments ('" ~ found ~ "' and '" ~ row["treatment"].str
                ~ "') — the keys matched on do not determine the drawing");
            found = row["treatment"].str;
        }
        return hits == 0 ? "" : found;
    }

    size_t checked = 0;
    foreach (name, st; states) {
        immutable t = treatmentFor(st);
        assert(t.length,
            "no row of the fixture's state_to_treatment table describes state '"
            ~ name ~ "' — the stand builds a state the capture never measured");
        immutable want = roleForTreatment(t);
        assert(st.drawn.role == want,
            format("state '%s' is treatment '%s' in the fixture, which we play "
                   ~ "with %s — the panel drew %s (%s)",
                   name, t, want, st.drawn.role, st.drawn.toStringForMsg()));
        assert(st.drawn.look == lookOf(want, false),
            format("state '%s' drew %s, not the '%s' treatment's own colours",
                   name, st.drawn.toStringForMsg(), t));
        ++checked;
    }
    assert(checked == 7,
        "seven states are built and every one of them is checked; got "
        ~ to!string(checked));

    // Vacuity guard for the whole table: the seven states really do land on
    // more than one treatment, and on all three of them.
    bool[RowRole] seen;
    foreach (_, st; states) seen[st.drawn.role] = true;
    assert(seen.length == 3,
        "the stand exercises all three treatments; got "
        ~ to!string(seen.length));
}
