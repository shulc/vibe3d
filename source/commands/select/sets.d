module commands.select.sets;

import command;
import mesh;
import view;
import editmode;
import params   : Param;
import snapshot : MeshSnapshot, SelectionSnapshot;
import mesh_edit_delta : MeshEditScope;
import seltype  : SelType;
import document : Document, Layer;
import mesh_selsets;

// ---------------------------------------------------------------------------
// select.set.{store,apply,edit,rename,delete} — named, typed, per-mesh
// selection sets (task 1060). Reference law MEASURED (2026-08-16/17),
// evidence + the full design rationale in doc/selection_sets_plan.md; the
// storage kernel is source/mesh_selsets.d.
//
// Domain is NEVER an argument — it is `currentType()` (THE RULE, see
// source/command.d), the same authority every other select.* command reads.
// `SelType.Item`, and a name that exists only in another domain, both take
// the SAME exit: nothing changes, and the caller finds out — measured,
// `g6_mode_gate`. The MECHANISM for that exit is `baseRefusal_` + `return
// false` (the house refusal idiom, `commands/mesh/edge_crease.d`'s
// precedent), not a thrown Exception: every one of these five commands has
// a button (config/buttons.yaml), reached through the UI's plain runCommand
// dispatch (throwMsg = null) — a throw there unwinds past the args dialog's
// own popup-close call. `applyOrRefire` (source/app.d) still synthesizes an
// Exception off `refusalReason()` for HTTP/scripted callers, so the
// measured "nothing changes, caller finds out" law holds there unchanged;
// only a button's first click no longer crashes on an empty name field or
// on opening the dialog in item mode (review blocker, task 1060).
//
// Two creation surprises are the identity of two of these ids, not options:
//   - `select.set.edit` on a MISSING name CREATES it;
//   - `select.set.store` on an EXISTING name UNIONS into it (never replaces).
// `store` is literally `edit mode:add` behind a second id (so the UI can
// offer a plain "New Set…" affordance) — anyone tempted to make `store`
// replace has to redden a fixture case.
//
// Undo classes (mirrors `mesh.weightmap.*`, source/commands/mesh/weightmap.d):
// `store`/`edit`/`rename`/`delete` mutate mesh METADATA (the registry) ⇒
// `MeshSnapshot` + `MeshEditScope.Material`. `apply` mutates SELECTION only,
// across possibly several meshes ⇒ one `SelectionSnapshot` per touched layer.
//
// ALL FIVE OF THOSE CAPTURES ARE PERMANENT. Each class below says so at its
// own declaration and gives its own reason; what they share, and what is
// therefore written here once rather than five times, is the ARITHMETIC of the
// alternative. A new `MeshOpEntry.Kind` is not a local addition: the enum is
// consumed by SIX exhaustive `final switch`es in `source/mesh_edit_delta.d`
// (`kindHoldsIndexSpace`, `owesTopologyBump`, `displayTermFor`,
// `owesDisplayRefresh`, `applyForward`, `applyReverse`) plus a seventh in
// `tests/test_mesh_edit_delta.d`, and every one of them is `final` ON PURPOSE
// so that a new kind is a compile error rather than a silent `default:`. A
// sixteenth kind therefore owes seven branches for good — against a dense side
// which, for a set edit, is one `MeshSnapshot` and has never been anything
// else. That is the same sum that declined `PartDelta` (owner's Q2 ruling,
// 2026-08-27), reached here on a different plane.
//
// The registry is SIX fields (`mesh.d`, "Selection sets"): three `*SetNames`
// slot arrays, `vertexSetMask` and `faceSetMask` (one `ulong` of membership
// bits per element) and `edgeSetMask` — an `ulong[ulong]` keyed by the
// canonical vertex PAIR, which has no length and no index space at all. No
// `MeshOpEntry.Kind` carries any of those as a PAYLOAD, and the map-value kind
// added at Stage L1-P1 does not either: it carries "which MAP, which elements,
// what was, what is". A set registry is a DIFFERENT PLANE, not a
// differently-sized one, which is precisely the line the owner's L1 ruling
// (2026-08-27) drew when it gave the twenty-odd map-value classes one kind and
// gave these five none.
//
// AND SAY WHAT THAT IS NOT SAYING, because the delta machinery does touch
// these planes and reading the paragraph above backwards is easy:
// `faceSetMask` rides as a PASSENGER through face renumbering and
// `edgeSetMask` is re-keyed at four replay sites in `mesh_edit_delta.d`
// (`selSetRekeyEdges`), precisely so that a topology delta cannot silently
// reattach a set to the wrong element. Sets are CARRIED ACROSS a delta today.
// What does not exist — and is not going to — is a kind whose payload is
// "this set's membership changed".
//
// The gate that keeps these five declarations honest is
// `tests/unit/l1_declined_census_test.d`: it counts the dense capture in this
// file and refuses any `record*` call appearing in it, because those are the
// two things a migration would have to change. It deliberately does not count
// the words below.
// `cmdFlags()` is left at the default `Model` class (matches `select.byTag`
// / `select.invert` — deliberately NOT `mesh.select`'s `UiState`, since a
// selection SET, unlike a bare selection, is data the user would mind losing).
//
// Empty-selection scoping (measured, corrected from an earlier draft that
// gated every verb on it — see doc/selection_sets_plan.md §Q4): a no-op ONLY
// for the two verbs whose new state comes FROM the live selection.
//   - `store` / `edit`: empty selection ⇒ no-op (return false, no history
//     entry) — the `mesh.setMaterial` idiom.
//   - `apply` / `rename` / `delete`: act on their NAME ARGUMENT
//     unconditionally. This is load-bearing: `apply` on an empty selection
//     is the feature's primary path (open a file, select nothing, apply a
//     set to get it back), and gating `delete`/`rename` on selection would
//     make a set undeletable the moment the user presses Escape.
// ---------------------------------------------------------------------------

/// `currentType()` -> `SetDomain` via `dom`; returns `null` on success or a
/// human-readable refusal for `SelType.Item` — the ONE place every command
/// below asks this question. Returns a STRING rather than throwing (review
/// blocker, task 1060: all five commands below now have buttons, so this
/// path runs through the UI's plain runCommand dispatch, which passes
/// throwMsg = null — an uncaught throw there unwinds past the args dialog's
/// own popup-close call, same hazard `commands/mesh/edge_crease.d` already
/// documents and fixes for `mesh.edgeCrease.*`). Every caller below feeds
/// the result into `baseRefusal_` + `return false`; the HTTP path still
/// errors on it, because `applyOrRefire` (source/app.d) raises its OWN
/// Exception off `refusalReason()` when a command refuses — this changes
/// the MECHANISM, not the measured "throw, change nothing" law for
/// `SelType.Item` (`g6_mode_gate`).
private string domainOf(SelType t, out SetDomain dom) {
    final switch (t) {
        case SelType.Vertex:  dom = SetDomain.Vertex;  return null;
        case SelType.Edge:    dom = SetDomain.Edge;    return null;
        case SelType.Polygon: dom = SetDomain.Polygon; return null;
        case SelType.Item:
            return "select.set: there is no selection set for the current type "
                 ~ "(switch to a geometry mode first)";
    }
}

// ---------------------------------------------------------------------------
// Domain-dispatch wrappers — thin, so every command body reads the same
// regardless of which of the three `mesh_selsets` engines it lands in.
// ---------------------------------------------------------------------------

private bool domainOwns(ref const Mesh m, SetDomain d, string name) {
    final switch (d) {
        case SetDomain.Vertex:  return selSetOwnsVertex(m, name);
        case SetDomain.Edge:    return selSetOwnsEdge(m, name);
        case SetDomain.Polygon: return selSetOwnsPolygon(m, name);
    }
}

private bool domainHasAnySelected(ref Mesh m, SetDomain d) {
    final switch (d) {
        case SetDomain.Vertex:  return m.hasAnySelectedVertices();
        case SetDomain.Edge:    return m.hasAnySelectedEdges();
        case SetDomain.Polygon: return m.hasAnySelectedFaces();
    }
}

private void domainEdit(ref Mesh m, SetDomain d, string name, SetEditMode mode) {
    final switch (d) {
        case SetDomain.Vertex:  selSetEditVertex(m, name, mode, m.selectedVertices);  break;
        case SetDomain.Edge:    selSetEditEdge(m, name, mode, m.selectedEdges);       break;
        case SetDomain.Polygon: selSetEditPolygon(m, name, mode, m.selectedFaces);    break;
    }
}

private bool domainApply(ref Mesh m, SetDomain d, string name, SetApplyMode mode) {
    final switch (d) {
        case SetDomain.Vertex:  return selSetApplyVertex(m, name, mode);
        case SetDomain.Edge:    return selSetApplyEdge(m, name, mode);
        case SetDomain.Polygon: return selSetApplyPolygon(m, name, mode);
    }
}

private bool domainDelete(ref Mesh m, SetDomain d, string name) {
    final switch (d) {
        case SetDomain.Vertex:  return selSetDeleteVertex(m, name);
        case SetDomain.Edge:    return selSetDeleteEdge(m, name);
        case SetDomain.Polygon: return selSetDeletePolygon(m, name);
    }
}

private int domainRename(ref Mesh m, SetDomain d, string from, string to_) {
    final switch (d) {
        case SetDomain.Vertex:  return selSetRenameVertex(m, from, to_);
        case SetDomain.Edge:    return selSetRenameEdge(m, from, to_);
        case SetDomain.Polygon: return selSetRenamePolygon(m, from, to_);
    }
}

/// `null` on success (with `mode` filled) or a refusal string — same
/// non-throwing shape as `domainOf` above, and for the same reason: reached
/// through a button's args dialog, not just HTTP.
private string parseEditMode(string s, out SetEditMode mode) {
    switch (s) {
        case "add":     mode = SetEditMode.add;     return null;
        case "remove":  mode = SetEditMode.remove;  return null;
        case "replace": mode = SetEditMode.replace; return null;
        default: return "select.set: unknown edit mode '" ~ s ~ "' — expected add, remove or replace";
    }
}

private string parseApplyMode(string s, out SetApplyMode mode) {
    switch (s) {
        case "select":   mode = SetApplyMode.select;   return null;
        case "deselect": mode = SetApplyMode.deselect; return null;
        case "replace":  mode = SetApplyMode.replace;  return null;
        default: return "select.set: unknown apply mode '" ~ s ~ "' — expected select, deselect or replace";
    }
}

// ---------------------------------------------------------------------------
// select.set.store — create from the current selection; unions into an
// existing name. Literally `edit mode:add` behind a second id.
//
// PERMANENTLY DENSE (owner's L1 ruling, 2026-08-27). The `MeshSnapshot` below
// is this command's undo for good; it is not an unfinished migration.
//
// ITS OWN REASON: `store` writes membership. `domainEdit(…, SetEditMode.add)`
// may ALLOCATE A SLOT in `vertexSetNames` / `edgeSetNames` / `polygonSetNames`
// (reusing a free one, which is an empty name string, before growing) and then
// ORs one bit into every selected element's mask word — or, in the edge
// domain, inserts keys into an associative array. A recorded undo for that
// would have to carry a slot index that is NOT stable (slot indices are
// assignment order and are not preserved across save/load, which is why every
// reference outside a mesh is by NAME), plus a per-element bit plane in two
// different shapes. Nothing in `MeshOpEntry` expresses either half; see the
// module header for the price of a kind that would.
// ---------------------------------------------------------------------------
class SelectSetStore : Command {
    private string       name_ = "";
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "select.set.store"; }
    override string label() const { return "New Selection Set"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        SetDomain dom;
        auto domErr = domainOf(currentType(), dom);
        if (domErr !is null) { baseRefusal_ = domErr; return false; }
        auto err = validateSetName(name_);
        if (err !is null) { baseRefusal_ = "select.set.store: " ~ err; return false; }
        if (!domainHasAnySelected(*mesh, dom)) return false;   // empty selection: no-op
        snap = MeshSnapshot.capture(*mesh);
        domainEdit(*mesh, dom, name_, SetEditMode.add);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.set.edit — add/remove/replace a set's membership from the live
// selection. A missing name CREATES the set (measured).
//
// PERMANENTLY DENSE (owner's L1 ruling, 2026-08-27).
//
// ITS OWN REASON, and it is the sharpest of the four: this command's THREE
// modes are three different registry edits behind one id. `add` ORs bits;
// `remove` clears them, and in the edge domain DELETES the associative-array
// key once its mask word reaches zero, so the undo has to distinguish "this
// pair was absent" from "this pair was present with other sets' bits";
// `replace` overwrites the whole membership plane of that set. A delta kind
// would need all three shapes, and the one that deletes a key has no length
// to compare against — the failure would be a set that comes back with a
// missing element and no assertion anywhere to trip. The dense capture gets
// all three right by construction, and it is one `MeshSnapshot` per set edit.
// ---------------------------------------------------------------------------
class SelectSetEdit : Command {
    private string       name_ = "";
    private string       mode_ = "add";
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "select.set.edit"; }
    override string label() const { return "Edit Selection Set"; }

    override Param[] params() {
        return [
            Param.string_("name", "Name", &name_, ""),
            Param.enum_("mode", "Mode", &mode_,
                        [["add", "Add"], ["remove", "Remove"], ["replace", "Replace"]],
                        "add"),
        ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        SetDomain dom;
        auto domErr = domainOf(currentType(), dom);
        if (domErr !is null) { baseRefusal_ = domErr; return false; }
        auto err = validateSetName(name_);
        if (err !is null) { baseRefusal_ = "select.set.edit: " ~ err; return false; }
        SetEditMode em;
        auto modeErr = parseEditMode(mode_, em);
        if (modeErr !is null) { baseRefusal_ = modeErr; return false; }
        if (!domainHasAnySelected(*mesh, dom)) return false;   // empty selection: no-op
        snap = MeshSnapshot.capture(*mesh);
        domainEdit(*mesh, dom, name_, em);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.set.apply — union / subtract / replace the LIVE selection against a
// set's membership. Multi-layer (task 1060 §Q6): searches every FOREGROUND
// layer, selects only inside the owner(s); no owner anywhere ⇒ throw. This is
// the one command in this family that follows `LayerCommandBase`'s
// `Document*`-binding pattern instead of a single `Mesh*` — it is genuinely
// not a single-mesh operation (measured: an owner selected while NOT primary
// still fires, `cap/fin3.json` `f3_set_scope_primary`).
//
// PERMANENTLY DENSE, and for TWO INDEPENDENT REASONS (owner's L1 ruling,
// 2026-08-27). Both are written out because FIXING EITHER ONE LEAVES THE OTHER
// STANDING — a reader who removes one and reads the decision as settled has
// re-opened nothing.
//
// BLOCKER 1 — the payload is the selection OBJECT, not a set, and that object
// was declined at Q6. `domainApply` writes the Select bit of a mark array AND
// stamps that domain's `*SelectionOrder` AND moves its `*SelectionOrderCounter`
// (three planes × three domains, which is why `SelectionSnapshot` captures all
// nine and not the one domain the command was invoked in). `Kind.SelectionDelta`
// — the nearest existing kind — carries mark WORDS ONLY: no order array, no
// counter. Routed onto it, an undo would restore membership, lose the ORDER,
// and answer `true`; the sibling family has that failure MEASURED, not
// supposed (the `hide` capture of 2026-08-27, cell `D2_CROSS`: one undo
// restores the selection, its position in the order, and a domain the command
// never worked in). A Marks publisher that could carry the object is the
// object the owner declined to own at Q6, and it is still nobody's.
//
// BLOCKER 2 — N MESHES, AND A `MeshEditDelta` BINDS ONE. `applyImpl` walks
// every FOREGROUND layer, selects inside every owner it finds, and keeps one
// `SelectionSnapshot` per touched mesh; a `MeshEditDelta` is produced by a
// batch over a single `Mesh` and replayed into a single `Mesh`. No decision
// about Q6 and no new kind changes that — it is a property of the delta's
// BINDING, not of its payload, and it is the half that cannot be argued away.
//
// The visible consequence, named rather than hidden: the frozen L1 parity
// oracle (`tests/fixtures/undo_parity/uv_maps_sets.json`) has 26 cells and
// none of them is this command, because `meshPlanesJson` reads ONE mesh. A
// one-layer rig would let it construct and would then measure exactly the case
// in which neither blocker arises, which is a decoy and not a cell.
// ---------------------------------------------------------------------------
class SelectSetApply : Command {
    private string   name_ = "";
    private string   mode_ = "select";
    private Document* doc;

    private struct Touched { Mesh* m; SelectionSnapshot snap; }
    private Touched[] touched_;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc) {
        super(mesh, view, editMode);
        this.doc = doc;
    }

    override string name()  const { return "select.set.apply"; }
    override string label() const { return "Apply Selection Set"; }

    override Param[] params() {
        return [
            Param.string_("name", "Name", &name_, ""),
            Param.enum_("mode", "Mode", &mode_,
                        [["select", "Select"], ["deselect", "Deselect"], ["replace", "Replace"]],
                        "select"),
        ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        if (name_.length == 0) {
            baseRefusal_ = "select.set.apply: name must not be empty";
            return false;
        }
        SetDomain dom;
        auto domErr = domainOf(currentType(), dom);
        if (domErr !is null) { baseRefusal_ = domErr; return false; }
        SetApplyMode am;
        auto modeErr = parseApplyMode(mode_, am);
        if (modeErr !is null) { baseRefusal_ = modeErr; return false; }

        Layer[] fg;
        doc.foregroundLayersInto(fg);

        Touched[] touched;
        bool anyOwner = false;
        foreach (l; fg) {
            if (!l.hasMesh) continue;
            auto mp = &l.meshRef();
            if (!domainOwns(*mp, dom, name_)) continue;
            anyOwner = true;
            auto snap = SelectionSnapshot.capture(*mp);
            domainApply(*mp, dom, name_, am);
            touched ~= Touched(mp, snap);
        }
        if (!anyOwner) {
            baseRefusal_ = "select.set.apply: no foreground layer owns a set named '" ~ name_ ~ "'";
            return false;
        }
        touched_ = touched;
        return true;
    }

    override bool revert() {
        if (touched_.length == 0) return false;
        // `Layer` is a class (stable heap identity, GC-traced), so a `Mesh*`
        // captured here stays valid even if the owning layer is deleted
        // between apply and undo — undoing onto a deleted layer is then
        // invisible rather than corrupting (task 1060 §Q6; the same hazard
        // every other cross-command `Mesh*` capture in this tree already
        // carries).
        foreach (t; touched_) t.snap.restore(*t.m);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.set.rename — unconditional on selection (acts on its `from`/`to`
// arguments). Split out as its own id rather than an `edit` mode, matching
// `mesh.weightmap.rename`'s precedent and keeping `edit`'s mode enum closed
// over membership verbs.
//
// PERMANENTLY DENSE (owner's L1 ruling, 2026-08-27).
//
// ITS OWN REASON, and it is the one that looks most like a false decline, so
// it is spelled out: `Kind.MapValueDelta` HAS a `Rename` arm, carrying two
// strings, added at Stage L1-P1 precisely because a rename expressed as
// remove+create costs a whole map. This command's rename is NOT that arm.
// It moves a name inside `vertexSetNames` / `edgeSetNames` /
// `polygonSetNames` — a SLOT array whose index is the bit position in the
// membership masks — while the map arm moves `MeshMap.name`, a field on an
// entry in `meshMaps`. The two are the same English word over two different
// registries, and the map arm's bind terms (`dim`, `domain`, `kind`, and a
// uniqueness check over `meshMaps`) have no meaning here. Reusing it would be
// a kind whose payload does not describe the thing it edits.
// ---------------------------------------------------------------------------
class SelectSetRename : Command {
    private string       from_ = "";
    private string       to_   = "";
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "select.set.rename"; }
    override string label() const { return "Rename Selection Set"; }

    override Param[] params() {
        return [
            Param.string_("from", "From", &from_, ""),
            Param.string_("to",   "To",   &to_,   ""),
        ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        if (from_.length == 0) {
            baseRefusal_ = "select.set.rename: 'from' must not be empty";
            return false;
        }
        auto err = validateSetName(to_);
        if (err !is null) { baseRefusal_ = "select.set.rename: " ~ err; return false; }
        SetDomain dom;
        auto domErr = domainOf(currentType(), dom);
        if (domErr !is null) { baseRefusal_ = domErr; return false; }
        snap = MeshSnapshot.capture(*mesh);
        const rc = domainRename(*mesh, dom, from_, to_);
        if (rc == 1) {
            snap = MeshSnapshot.init;
            baseRefusal_ = "select.set.rename: no set named '" ~ from_ ~ "'";
            return false;
        }
        if (rc == 2) {
            snap = MeshSnapshot.init;
            baseRefusal_ = "select.set.rename: a set named '" ~ to_ ~ "' already exists";
            return false;
        }
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.set.delete — unconditional on selection. Purges the name AND every
// element's membership (measured: `ptag 'A;B B;C'` -> delete A -> `'B B;C'`
// — our vertex/polygon bitmask and edge AA are cleared the equivalent way).
//
// PERMANENTLY DENSE (owner's L1 ruling, 2026-08-27).
//
// ITS OWN REASON: this is the widest write of the five and the one whose undo
// is least like a payload. `domainDelete` frees the NAME SLOT (the entry
// becomes an empty string, which `ensureSlot` will later hand to an unrelated
// set) and clears that slot's bit in EVERY element — `clearBitEverywhere` over
// the whole vertex or face mask, and over every key of `edgeSetMask`, dropping
// each key whose word reaches zero. So its undo has to restore a slot INDEX
// (unstable by design), an element-count-wide bit plane, and a set of
// associative-array keys that no longer exist to be diffed against. That is
// three shapes, none of them in `MeshOpEntry`, to undo an operation whose
// dense capture is one `MeshSnapshot` — the arithmetic in the module header,
// at its worst ratio.
// ---------------------------------------------------------------------------
class SelectSetDelete : Command {
    private string       name_ = "";
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name()  const { return "select.set.delete"; }
    override string label() const { return "Delete Selection Set"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
        baseRefusal_ = "";
        if (name_.length == 0) {
            baseRefusal_ = "select.set.delete: name must not be empty";
            return false;
        }
        SetDomain dom;
        auto domErr = domainOf(currentType(), dom);
        if (domErr !is null) { baseRefusal_ = domErr; return false; }
        snap = MeshSnapshot.capture(*mesh);
        if (!domainDelete(*mesh, dom, name_)) {
            snap = MeshSnapshot.init;
            baseRefusal_ = "select.set.delete: no set named '" ~ name_ ~ "'";
            return false;
        }
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
