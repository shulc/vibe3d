module tests.unit.commands.select.by_tag_source_public_test;

import commands.select.by_tag;

import command;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params   : Param;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// Unit tests (task 1051). The region-parity numbers are frozen in
// tests/fixtures/select_by_tag.json; pinned here are the resolution order and
// the three modes, which the fixture exercises only one path of.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.conv : to;

    private Mesh* taggedCube() {
        auto m = new Mesh;
        *m = makeCube();
        m.syncSelection();
        m.faceMaterial.length = m.faces.length;
        m.facePart.length     = m.faces.length;
        m.faceMaterial[0] = 1;          // two faces on surface 1 ...
        m.faceMaterial[2] = 1;
        m.faceMaterial[4] = 2;          // ... one on surface 2, rest on 0
        m.surfaces = [Surface("Default"), Surface("Red"), Surface("Blue")];
        return m;
    }

    private size_t[] runByTag(Mesh* m, string type, string nm, int id,
                              string mode) {
        View v = new View(0, 0, 1, 1);
        auto c = new SelectByTag(m, v, EditMode.Polygons);
        foreach (ref p; c.params()) {
            if (p.name == "type") *p.sptr = type;
            if (p.name == "name") *p.sptr = nm;
            if (p.name == "id")   *p.iptr = id;
            if (p.name == "mode") *p.sptr = mode;
        }
        // Task 1100 Stage 0b: `apply()` REFUSES instead of throwing, so a
        // helper that ignored the result would turn a refusal into "the tag
        // selected nothing" — the exact confusion the loud refusal exists to
        // prevent. Every caller below passes legal arguments, so this assert
        // only ever fires on a regression.
        assert(c.apply(), "runByTag: refused — " ~ c.refusalReason());
        size_t[] outp;
        foreach (fi; 0 .. m.faces.length)
            if (m.isFaceSelected(fi)) outp ~= fi;
        return outp;
    }
}

// By name, by id, and the two agree.
unittest {
    auto m = taggedCube();
    assert(runByTag(m, "material", "Red", -1, "set") == [0UL, 2UL],
        "by name must return the surface's faces");
    m.clearFaceSelection();
    assert(runByTag(m, "material", "", 1, "set") == [0UL, 2UL],
        "by id must return the same faces as by name");
}

// Neither name nor id: the tags of the CURRENT selection — one clicked face
// brings its whole region. This is the gesture the chapter performs.
unittest {
    auto m = taggedCube();
    m.selectFace(2);                    // one face of the Red region
    assert(runByTag(m, "material", "", -1, "set") == [0UL, 2UL],
        "with no name/id the current selection's tags drive the answer");
}

// ... and with NOTHING selected that arm is a no-op, not "select everything".
unittest {
    auto m = taggedCube();
    assert(runByTag(m, "material", "", -1, "set").length == 0,
        "an empty selection with no name/id must select nothing");
}

// add unions, remove subtracts — both against a pre-existing selection that
// the tag does not cover, so a mode that ignored the prior selection would be
// visible.
unittest {
    auto m = taggedCube();
    m.selectFace(5);                    // not in the Red region
    assert(runByTag(m, "material", "Red", -1, "add") == [0UL, 2UL, 5UL],
        "add must keep the prior selection");

    m.clearFaceSelection();
    m.selectFace(0); m.selectFace(2); m.selectFace(5);
    assert(runByTag(m, "material", "Red", -1, "remove") == [5UL],
        "remove must subtract the tag's faces from the prior selection");
}

// Parts are selected by id and reject a name — there is no part-name registry
// to look one up in, and answering something anyway would be a lie.
unittest {
    import std.algorithm : canFind;
    auto m = taggedCube();
    m.facePart[3] = 7;
    assert(runByTag(m, "part", "", 7, "set") == [3UL],
        "part selection by id");

    auto v = new View(0, 0, 1, 1);
    auto c = new SelectByTag(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) {
        if (p.name == "type") *p.sptr = "part";
        if (p.name == "name") *p.sptr = "Anything";
    }
    assert(!c.apply(), "a part with a name must REFUSE, not select something");
    assert(c.refusalReason().canFind("name"),
        "the reject must name the offending arg: " ~ c.refusalReason());
}

// An unknown surface name REFUSES rather than quietly selecting nothing — the
// two outcomes look identical on screen and only one of them is a typo. Task
// 1100 Stage 0b changed the MECHANISM (a named `refusalReason()` the caller
// reads, instead of a thrown Exception, because this command now has a button)
// and deliberately not the argument: the refusal is still LOUD. A silent
// `return true` here would be exactly the "quietly selecting nothing" this case
// exists to forbid.
unittest {
    import std.algorithm : canFind;
    auto m = taggedCube();
    auto v = new View(0, 0, 1, 1);
    auto c = new SelectByTag(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) if (p.name == "name") *p.sptr = "Nope";
    assert(!c.apply(), "an unknown surface name must REFUSE");
    assert(c.refusalReason().canFind("Nope"),
        "the reject must quote the name: " ~ c.refusalReason());
    assert(!m.hasAnySelectedFaces(), "a refusal must change nothing");
}

// Task 1100 Stage 0b — the three converted sites that had NO case at all, so
// that restoring any of the five throws reddens something. `apply()` throwing
// escapes the unittest directly; a silent `return true` fails the
// `refusalReason()` assert.
//
// 1. The edit-mode gate. This is the one a Statistics row reaches by ordinary
//    use: the panel draws all four sections whatever the current selection
//    type, so a Material row is clickable in vertex mode.
unittest {
    import std.algorithm : canFind;
    auto m = taggedCube();
    auto v = new View(0, 0, 1, 1);
    auto c = new SelectByTag(m, v, EditMode.Vertices);
    foreach (ref p; c.params()) if (p.name == "name") *p.sptr = "Red";
    assert(!c.apply(), "the wrong edit mode must REFUSE");
    assert(c.refusalReason().canFind("Polygons"),
        "the reject must name the mode it needs: " ~ c.refusalReason());
    assert(!m.hasAnySelectedFaces(), "a refusal must change nothing");
}

// 2. An unknown `type`.
unittest {
    import std.algorithm : canFind;
    auto m = taggedCube();
    auto v = new View(0, 0, 1, 1);
    auto c = new SelectByTag(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) if (p.name == "type") *p.sptr = "bogus";
    assert(!c.apply(), "an unknown type must REFUSE");
    assert(c.refusalReason().canFind("bogus"),
        "the reject must quote the bad type: " ~ c.refusalReason());
}

// 3. An unknown `mode`.
unittest {
    import std.algorithm : canFind;
    auto m = taggedCube();
    auto v = new View(0, 0, 1, 1);
    auto c = new SelectByTag(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) if (p.name == "mode") *p.sptr = "bogus";
    assert(!c.apply(), "an unknown mode must REFUSE");
    assert(c.refusalReason().canFind("bogus"),
        "the reject must quote the bad mode: " ~ c.refusalReason());
}
