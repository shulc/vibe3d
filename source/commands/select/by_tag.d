module commands.select.by_tag;

import command;
import mesh;
import view;
import editmode;
import params   : Param;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// select.byTag — re-select the polygons carrying a surface / part tag.
//
// The read half of `mesh.setMaterial` / `mesh.setPart`. The dogfood chapter
// paints a region precisely so it can come back to it later — the mouth
// cavity, the lower teeth, the shirt's outer shell — and without this the way
// back is clicking every polygon again.
//
// Which tag:
//   name: "OuterShell"    a surface looked up by name in `Mesh.surfaces`
//   id:   3               a surface / part index, used when `name` is empty
//   neither               the tags carried by the CURRENT polygon selection —
//                         "give me the rest of the region I am standing on",
//                         which is the gesture the chapter actually performs
//
// mode: set (default) replaces the selection, add unions, remove subtracts.
// `add` / `remove` are the reference's Statistics `+` and `−` columns; `set`
// is ours, and it is the default because "click one polygon, get its whole
// region" wants a replace, not a union.
//
// ---------------------------------------------------------------------------
// Why this is not a port of a reference COMMAND (task 1051)
// ---------------------------------------------------------------------------
// There isn't one. All three command ids the audit named were probed against
// the live reference: two of them do not exist at all ("command could not be
// found" / "argument parsing failed"), and the third succeeds but produces no
// polygon selection whatsoever. It selects the TAG — the reference carries a
// fifth selection mode for materials, alongside vertex/edge/polygon/item — and
// a tag-assignment command issued straight after it changed nothing, so that
// selection does not even drive polygon commands. The reference's own route
// from a tag to a polygon selection is a statistics-viewport row, a UI widget.
//
// So what parity is claimed here is the REGION, not the command: the set of
// polygons carrying a tag. That was measured — assigning a named surface to
// two selected faces of a cube tags exactly those two, and the other four read
// as the default — and is frozen in `tests/fixtures/select_by_tag.json`.
//
// One measured DIVERGENCE, deliberately not adopted: with nothing selected,
// the reference's tag-assignment retags the WHOLE MESH, while our
// `mesh.setMaterial` is a no-op on an empty selection. Ours is the safer of
// the two and changing it is a behaviour change well outside this command;
// recorded in the task file so the next reader does not rediscover it as a bug.
// ---------------------------------------------------------------------------
class SelectByTag : Command {
    private SelectionSnapshot snap;
    private string type_ = "material";
    private string name_ = "";
    private int    id_   = -1;
    private string mode_ = "set";

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "select.byTag"; }
    override string label() const { return "Select By Tag"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.enum_("type", "Tag Type", &type_,
                        [["material", "Material"], ["part", "Part"]], "material"),
            Param.string_("name", "Name", &name_, ""),
            Param.int_("id", "Id", &id_, -1),
            Param.enum_("mode", "Mode", &mode_,
                        [["set", "Set"], ["add", "Add"], ["remove", "Remove"]],
                        "set"),
        ];
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // A BUTTON MAY NOT THROW (task 1100 Stage 0b, owner decision 6).
    //
    // Every rejection below used to be a `throw`. That was defensible while
    // this command was reached from a form and from HTTP; the Statistics panel
    // gives it a BUTTON — the `+`/`-` cells on the Material and Part rows —
    // and the panel always draws all four component sections regardless of the
    // current selection type (`rules.always_four_sections`), so a click in the
    // wrong mode is one of the ordinary things a user does. A throw out of a
    // button's dispatch unwinds past the UI's own popup-close, which is the
    // measured reason `select.set.*` uses `baseRefusal_` + `return false`
    // (`commands/select/sets.d:20-33`) rather than an exception.
    //
    // ALL FIVE sites are converted, not the two a row can reach today.
    // Enumerating reachability is the fragile move: `name`-on-a-part is
    // unreachable exactly while Part rows emit `id` (D5) and nothing pins that
    // coupling, and "no surface named X" becomes reachable the moment the row
    // model is one frame stale — a surface renamed between row build and click.
    //
    // The HTTP surface is UNCHANGED: `applyOrRefire` synthesizes an Exception
    // from `refusalReason()` for scripted callers, so a refused command still
    // answers an error body there.
    // -----------------------------------------------------------------------
    override bool apply() {
        // The reason describes the LATEST call — a command object can be
        // applied more than once (redo, re-dispatch).
        baseRefusal_ = "";

        // Per-face operation — same gate as mesh.setMaterial, so a stale face
        // selection carried over from another mode cannot silently answer.
        if (editMode != EditMode.Polygons) {
            baseRefusal_ = "select.byTag requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)";
            return false;
        }

        const bool isPart = type_ == "part";
        if (!isPart && type_ != "material") {
            baseRefusal_ = "select.byTag: unknown type '" ~ type_
                ~ "' — expected material or part";
            return false;
        }
        if (mode_ != "set" && mode_ != "add" && mode_ != "remove") {
            baseRefusal_ = "select.byTag: unknown mode '" ~ mode_
                ~ "' — expected set, add or remove";
            return false;
        }

        mesh.syncSelection();
        snap = SelectionSnapshot.capture(*mesh);

        const size_t nf = mesh.faces.length;
        if (nf == 0) return true;

        // `faceAttrOr`'s contract: the per-face tag arrays may legitimately be
        // SHORTER than faces[] (a mesh that never had an explicit assignment),
        // and a short entry reads as 0. Do not "fix" that by growing them here
        // — this command is read-only over the tags.
        uint tagOf(size_t fi) {
            auto arr = isPart ? mesh.facePart : mesh.faceMaterial;
            return fi < arr.length ? arr[fi] : 0u;
        }

        // ---- which tags are we after -----------------------------------
        bool[uint] wanted;
        if (name_.length > 0) {
            if (isPart) {
                baseRefusal_ =
                    "select.byTag: `name` is material-only — parts carry no "
                    ~ "name registry in this mesh format; select them by `id`";
                return false;
            }
            bool found = false;
            foreach (si, ref s; mesh.surfaces)
                if (s.name == name_) { wanted[cast(uint) si] = true; found = true; }
            if (!found) {
                baseRefusal_ = "select.byTag: no surface named '" ~ name_ ~ "'";
                return false;
            }
        } else if (id_ >= 0) {
            wanted[cast(uint) id_] = true;
        } else {
            // Neither given: take the tags of what is selected right now. An
            // empty selection here is a genuine no-op — NOT "select the whole
            // mesh", which would be a spectacular answer to a mis-typed
            // command.
            if (!mesh.hasAnySelectedFaces()) return true;
            foreach (fi; 0 .. nf)
                if (mesh.isFaceSelected(fi)) wanted[tagOf(fi)] = true;
        }

        // ---- apply ------------------------------------------------------
        auto want = new bool[](nf);
        foreach (fi; 0 .. nf) {
            const bool hit = (tagOf(fi) in wanted) !is null;
            final switch (mode_) {
                case "set":    want[fi] = hit;                            break;
                case "add":    want[fi] = hit || mesh.isFaceSelected(fi); break;
                case "remove": want[fi] = !hit && mesh.isFaceSelected(fi); break;
            }
        }

        // selectFacesFrom, not setFacesSelectedFrom — these faces are selected
        // on the user's behalf and must carry a selection-history value (see
        // the primitive's doc comment in mesh.d), the same choice select.fill.*
        // and select.boundary make.
        mesh.selectFacesFrom(want);
        return true;
    }
}

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
