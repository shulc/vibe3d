module ui.stat_rows;

// ---------------------------------------------------------------------------
// Task 1100 — the Statistics panel's ROW MODEL.
//
// WHY THIS MODULE EXISTS, rather than the tree being built inline in the
// drawer: an ImGui panel body is not observable headlessly, so an assertion
// written against the draw call can only say "the function ran" — and this
// repository has shipped a panel whose declared contents were rendered nowhere
// while the test that asserted the declaration passed the whole time
// (`ui/item_rows.d:1-30`, whose contract this file follows line for line).
//
//   * this module answers "WHAT would the tree show" — pure, allocation-only,
//     no ImGui, and no globals: the current selection type, the expand bits and
//     the mesh context are all PARAMETERS;
//   * `ui/panels.d`'s `drawStatisticsPanel` answers "where on screen", which
//     nothing here claims to cover.
//
// ---------------------------------------------------------------------------
// THE FOUR THINGS THIS MODEL SEPARATES, AND WHY EACH IS ITS OWN FIELD
// ---------------------------------------------------------------------------
// Conflating any two of them is the defect this file is shaped to prevent:
//
//   1. `StatCell.known` — "do we know this number". `false` prints a
//      placeholder, and WHICH placeholder is decided by `StatAvail`
//      (`kGatedCell` for a shut `Sel` gate, `kUnknownCell` for "we cannot
//      compute this at all").
//   2. `StatAvail` — what the two ACTION cells are: live buttons, disabled
//      buttons (with a reason), or NO buttons at all. It says nothing about the
//      numbers.
//   3. `StatTone` — measured: exactly the rows whose selected count is non-zero
//      are drawn dimmed, the section header included, and the buttons dim WITH
//      the row while staying clickable. A ROW state, never expressed by
//      disabling anything.
//   4. `StatAction` — the command a click fires. One per column, per row.
//
// A dimmed row is fully clickable; a disabled button is not; a `noAffordance`
// cell has nothing to click.
//
// ---------------------------------------------------------------------------
// THE ABSENT MESH — a fault, not a wrong number, is what is at stake
// ---------------------------------------------------------------------------
// `Document.primary` is nullable and the null state is live: the `-` button on
// this panel's own `Items → By Type → Mesh` row empties the item selection
// (`Document.selectItem`'s Remove arm permits removing the last selected item),
// and the panel redraws in that state on the very next frame. `Layer` is a
// class, so `doc.primary.meshOrNull()` on a null primary reads `this.kind` and
// SEGFAULTS. The one legal path is therefore
//
//     doc.hasEditTarget() ? doc.primary.meshOrNull() : null
//
// — the guard is on `primary`, not on the mesh it returns.
//
// With no mesh the three geometry sections are still emitted WHOLE (every
// category, every leaf, every label) with `StatAvail.unmeasured` and both cells
// unknown, and the Items section is emitted WITH REAL NUMBERS: it reads
// `doc.layers` and touches no mesh, so blanking it would be its own lie.
//
// `document.noEditTargetMesh()` — the read-only empty stand-in the frame path
// usually takes — is deliberately NOT used here: an empty mesh answers every
// geometry row `0`, and `0` is a claim to know how many there are. We do not.
//
// The ABSENT context is spelled `ctx.mesh is null`, never `ctx.vertEdge.length
// == 0`: an empty mesh has empty arrays too, and those two states must render
// differently (`0` versus `—`).
//
// ---------------------------------------------------------------------------
// DECISIONS TAKEN HERE THAT ARE OURS, NOT MEASURED (each has a registry row)
// ---------------------------------------------------------------------------
//   * `StatExpand`'s default — sections open, categories closed. The owner's
//     first frame was not a freshly-opened panel, so it could not answer its
//     own question. Pinned below so it cannot drift silently.
//   * `Items → By Type` is sorted by DISPLAY NAME. The decode says this one
//     category is sorted and names a comparator whose key is not decoded.
//   * The Items SECTION row has no action: there is no command for "select
//     every item whatever its kind", and inventing one is out of scope. It is
//     `noAffordance` — the absence of an affordance, not a dead button.
//   * `Polygons → By Type` rows 0/1: our ONE subpatch concept is counted in
//     **Subdivs** and `Catmull-Clark` is a structural zero (owner decision
//     Р10). The evidence is the flag's provenance — it is set while parsing the
//     interchange format's patch chunk, and the measured frame counts exactly
//     such a mesh in Subdivs. One predicate never populates both rows.
// ---------------------------------------------------------------------------

import document  : Document, Layer, ItemKind, kindInfo, kNoEditTargetReason;
import mesh      : Mesh, MapKind, MapDomain;
import mesh_stats;
import seltype   : SelType;
import ui.channel_rows : kindHeading;

// ---------------------------------------------------------------------------
// The row vocabulary
// ---------------------------------------------------------------------------

/// The command one action column fires. Empty `commandId` means "this row has
/// no action" — which is what `noAffordance` and every disabled class carry.
struct StatAction {
    string commandId;
    string argsJson;

    bool empty() const { return commandId.length == 0; }
}

/// What the two ACTION cells are. Says nothing about the numbers (that is
/// `StatCell.known`) and nothing about the tone (that is `StatTone`).
enum StatAvail : ubyte {
    live,            ///< both buttons fire
    inertActions,    ///< measured to do nothing; we draw them DISABLED (ours)
    noAffordance,    ///< no buttons at all — empty cells, no tooltip
    structuralZero,  ///< the count is a true 0; there is nothing to select
    unmeasured,      ///< we do not know the number; disabled, reason in the tip
}

/// Measured (frame B): exactly the rows with a non-zero selected count are
/// dimmed. The third state the static decode implies — fully selected — occurs
/// in neither frame and is UNMEASURED: it ships as `dimmed`, which is the same
/// "something is selected" fact, and is recorded in the gap registry. Do not
/// invent a third tone here.
enum StatTone : ubyte { normal, dimmed }

/// One numeric cell. `known == false` prints a placeholder; which one is the
/// drawer's decision from `StatAvail` (§3 of the plan).
struct StatCell {
    bool known;
    long value;
}

struct StatLeaf {
    string     label;
    StatCell   num;
    StatCell   sel;
    StatAvail  avail;
    StatTone   tone;
    string     reason;      ///< tooltip for a disabled row; "" when live
    StatAction add;
    StatAction remove;
}

/// A category row is a label, a disclosure triangle and NOTHING ELSE —
/// measured across ten categories in two frames. It carries the action fields
/// so that "give a category an action" is a writable mutation the tests catch,
/// and `makeCategory` is the one place they are set (to empty).
struct StatCategory {
    string      label;
    string      key;        ///< stable expand key, "<section>/<category>"
    bool        expanded;
    StatAvail   avail;      ///< always `noAffordance` — by LEVEL, not by case
    StatCell    num;        ///< always blank (L8)
    StatCell    sel;        ///< always blank (L8)
    StatAction  add;        ///< always empty
    StatAction  remove;     ///< always empty
    StatLeaf[]  leaves;     ///< empty when collapsed, and legitimately empty
                            ///< when the category's dynamic list is empty
}

struct StatSection {
    string         label;
    SelType        type;
    bool           expanded;
    StatCell       num;
    StatCell       sel;
    StatAvail      avail;
    StatTone       tone;
    string         reason;
    StatAction     add;
    StatAction     remove;
    StatCategory[] categories;   ///< empty when the section is collapsed
}

/// Which sections and categories are open. Owned by the PANEL layer (the
/// instance is `commands/ui/statistics.d`'s `g_statExpand`); the row model only
/// ever reads it, which is what keeps `statSectionsInto` a pure function of its
/// arguments.
///
/// The type lives here rather than beside the instance so that the row model —
/// and its unittests, which must construct expand states directly — do not have
/// to import the command layer.
///
/// Sections default OPEN and categories default CLOSED (an absent key reads
/// false). OURS, not measured; pinned by a unittest below.
struct StatExpand {
    bool[4]     section = true;
    bool[string] category;

    bool sectionOpen(SelType t) const { return section[cast(size_t) t]; }
    bool categoryOpen(string key) const {
        auto p = key in category;
        return p !is null && *p;
    }
}

// ---------------------------------------------------------------------------
// Labels — the measured strings, in the measured order.
// ---------------------------------------------------------------------------

/// `Polygons → By Type`, fifteen rows, order confirmed by pixel (frame B).
/// There is NO sixteenth row: the reference implements one and its own loop
/// bound hides it, so showing one here would be a deliberate divergence with a
/// registry row — see the unittest that pins this list.
immutable string[] kPolygonTypeRows = [
    "Faces", "Subdivs", "Curves", "Bezier", "B-Spline", "SplinePatch", "Text",
    "Catmull-Clark", "Polyline", "Curve Fill", "Non-Planar", "Co-Located",
    "Co-Planar", "Angle", "Convex",
];

private enum string kUnmeasuredPredicate =
    "the predicate for this row is unmeasured — see doc/behavior_gap_registry.md";
private enum string kNoSuchPolygonKind =
    "this mesh format has no such polygon kind";
private enum string kSubdivHome =
    "our one subpatch concept is counted in Subdivs; this row cannot be "
    ~ "populated by the same predicate";
private enum string kInertByMeasurement =
    "the + / - columns do nothing for this category";
private enum string kCountOnly =
    "this row can be counted but there is no command that selects it";

// ---------------------------------------------------------------------------
// JSON argument building.
//
// Written by hand rather than through `std.json` for ONE reason: a JSONValue
// object is an associative array and its `toString` key order is not defined,
// so a test asserting the exact argument string would be asserting a hash
// order. The escape below is the whole of what a name can carry.
// ---------------------------------------------------------------------------
private string jsonStr(string s) {
    string outp = "\"";
    foreach (char ch; s) {
        switch (ch) {
            case '"':  outp ~= "\\\""; break;
            case '\\': outp ~= "\\\\"; break;
            case '\n': outp ~= "\\n";  break;
            case '\r': outp ~= "\\r";  break;
            case '\t': outp ~= "\\t";  break;
            default:
                if (ch < 0x20) {
                    import std.format : format;
                    outp ~= format("\\u%04x", cast(int) ch);
                } else outp ~= ch;
        }
    }
    return outp ~ "\"";
}

private string byStatArgs(string test, string compare, int value, bool hasValue,
                          bool add) {
    import std.conv : to;
    string a = `{"test":` ~ jsonStr(test) ~ `,"compare":` ~ jsonStr(compare);
    // `compare:all` must NOT carry a `value` key: the command rejects it
    // outright (a value alongside `all` is a silently-ignored argument), and
    // `injectParamsInto` leaves an absent key at its default.
    if (hasValue) a ~= `,"value":` ~ value.to!string;
    return a ~ `,"mode":` ~ (add ? `"add"` : `"remove"`) ~ `}`;
}

private string byTagArgsId(string type, uint id, bool add) {
    import std.conv : to;
    return `{"type":` ~ jsonStr(type) ~ `,"id":` ~ id.to!string
         ~ `,"mode":` ~ (add ? `"add"` : `"remove"`) ~ `}`;
}

private string byTagArgsName(string type, string name, bool add) {
    return `{"type":` ~ jsonStr(type) ~ `,"name":` ~ jsonStr(name)
         ~ `,"mode":` ~ (add ? `"add"` : `"remove"`) ~ `}`;
}

private string setApplyArgs(string name, bool add) {
    // `select.set.apply`'s vocabulary is select/deselect/replace — the `+`/`-`
    // columns are the first two and never the third.
    return `{"name":` ~ jsonStr(name) ~ `,"mode":`
         ~ (add ? `"select"` : `"deselect"`) ~ `}`;
}

private string layerSelectArgs(string kindToken, bool add) {
    return `{"kind":` ~ jsonStr(kindToken) ~ `,"mode":`
         ~ (add ? `"add"` : `"remove"`) ~ `}`;
}

// ---------------------------------------------------------------------------
// Leaf constructors. Every leaf in the tree goes through exactly one of these,
// so the tone rule and the placeholder rule have ONE implementation each.
// ---------------------------------------------------------------------------

/// THE TONE RULE, in one place. Measured (frame B): a non-zero selected count
/// dims the row.
///
/// `sel.known` is part of the rule and is PUBLIC and directly tested for a
/// reason worth stating, because it is not visible from the tree: no caller
/// today can produce a gated cell with a non-zero `value` — the kernel leaves
/// `sel` at 0 when the gate is shut, and the section shells write an explicit
/// 0 — so dropping the `known` term changes NOTHING about any row this model
/// currently emits. That was measured (the mutation came back green). The term
/// is kept because it is the rule the frames show (a gated section is drawn
/// normal), and because the day a caller fills `value` regardless of the gate,
/// its absence would dim every gated row in the panel. The unittest that pins
/// it therefore asks this function directly, with a cell the tree cannot build.
StatTone toneFor(StatCell sel) {
    return (sel.known && sel.value > 0) ? StatTone.dimmed : StatTone.normal;
}

private alias toneOf = toneFor;

private StatLeaf liveLeaf(string label, StatCount c, string cmdId,
                          string addArgs, string remArgs) {
    StatLeaf l;
    l.label  = label;
    l.num    = StatCell(true, c.num);
    l.sel    = StatCell(c.selKnown, c.sel);
    l.avail  = StatAvail.live;
    l.tone   = toneOf(l.sel);
    l.add    = StatAction(cmdId, addArgs);
    l.remove = StatAction(cmdId, remArgs);
    return l;
}

/// A row we can COUNT but cannot act on — there is no command that selects it.
/// Not a greyed button: the absence of an affordance.
private StatLeaf countOnlyLeaf(string label, StatCount c) {
    StatLeaf l;
    l.label = label;
    l.num   = StatCell(true, c.num);
    l.sel   = StatCell(c.selKnown, c.sel);
    l.avail = StatAvail.noAffordance;
    l.tone  = toneOf(l.sel);
    l.reason = kCountOnly;
    return l;
}

/// A row whose count is a TRUE zero — there can be none of these in our mesh
/// model. `0`, not `—`: the number is knowable and it is zero.
private StatLeaf structuralZeroLeaf(string label, bool gateOpen, string reason) {
    StatLeaf l;
    l.label  = label;
    l.num    = StatCell(true, 0);
    l.sel    = StatCell(gateOpen, 0);
    l.avail  = StatAvail.structuralZero;
    l.tone   = StatTone.normal;
    l.reason = reason;
    return l;
}

/// A row we cannot compute. `—`, never `0`: zero would be a claim.
private StatLeaf unmeasuredLeaf(string label, string reason) {
    StatLeaf l;
    l.label  = label;
    l.num    = StatCell(false, 0);
    l.sel    = StatCell(false, 0);
    l.avail  = StatAvail.unmeasured;
    l.tone   = StatTone.normal;
    l.reason = reason;
    return l;
}

/// A row whose actions are MEASURED to do nothing. Rendering that as a
/// disabled button is ours; the inertness is not.
private StatLeaf inertLeaf(string label, long num, bool gateOpen) {
    StatLeaf l;
    l.label  = label;
    l.num    = StatCell(true, num);
    // Measured: this category's Sel is always 0.
    l.sel    = StatCell(gateOpen, 0);
    l.avail  = StatAvail.inertActions;
    l.tone   = StatTone.normal;
    l.reason = kInertByMeasurement;
    return l;
}

/// THE one place a category row is built. Every field that makes it a
/// no-affordance blank row is set here, by LEVEL — there is no per-category
/// decision to get wrong.
/// The category keys whose leaves read a DERIVED array. Named constants rather
/// than literals at two sites, because `statNeedOf` below and `makeCategory`
/// here must agree about the key EXACTLY — a typo in one of them would build a
/// context missing an array the tree then reads.
enum string kCatVertByEdge   = "Vertices/By Edge";
enum string kCatVertByPoly   = "Vertices/By Polygon";
enum string kCatEdgeByPoly   = "Edges/By Polygon";
enum string kCatEdgeBoundary = "Edges/By Boundary";

/// WHICH derived arrays the tree will read in this expand state.
///
/// The "compute only what is on screen" rule, as one function next to the tree
/// that decides it: a collapsed category emits no leaves, and a leaf that is
/// not emitted reads nothing. MEASURED (Stage 5): on a 99 856-face grid this
/// takes the panel's ordinary-state rebuild from 8.4 ms to under 0.1 ms,
/// because in that state every array was being built for nobody.
///
/// Kept honest by construction rather than by care: `stat_rows_test.d` emits
/// every expand state twice — once with a context built from THIS answer and
/// once with a full one — and compares every row of both.
StatNeed statNeedOf(ref const StatExpand exp) {
    uint need = StatNeed.none;
    if (exp.sectionOpen(SelType.Vertex)) {
        if (exp.categoryOpen(kCatVertByEdge)) need |= StatNeed.vertEdge;
        if (exp.categoryOpen(kCatVertByPoly)) need |= StatNeed.vertPoly;
    }
    if (exp.sectionOpen(SelType.Edge)) {
        if (exp.categoryOpen(kCatEdgeByPoly)) need |= StatNeed.edgePoly;
        // `By Boundary` carries the Geometry row (an edge polygon COUNT) and
        // the two tag-boundary rows (per-edge face IDENTITY) — two different
        // arrays behind one disclosure triangle.
        if (exp.categoryOpen(kCatEdgeBoundary))
            need |= StatNeed.edgePoly | StatNeed.edgeFaces;
    }
    return cast(StatNeed) need;
}

private StatCategory makeCategory(string sectionLabel, string label,
                                  ref const StatExpand exp) {
    StatCategory c;
    c.label    = label;
    c.key      = sectionLabel ~ "/" ~ label;
    c.expanded = exp.categoryOpen(c.key);
    c.avail    = StatAvail.noAffordance;
    c.num      = StatCell(false, 0);
    c.sel      = StatCell(false, 0);
    return c;
}

// ---------------------------------------------------------------------------
// The tag-value enumeration (owner decision Р1, and D7's principle).
//
// THE ROW LIST MUST BE DERIVED FROM THE SAME PREDICATE THE BUTTON FIRES. The
// command reads a face's tag through an accessor whose contract is that a
// SHORT array reads as 0 (a mesh that never had an explicit assignment), so a
// fresh cube semantically has every face in part 0 / material 0 — and
// `select.byTag id:0` there selects all six faces. Enumerating the STORED
// entries instead would list zero rows while the button selected everything,
// which is exactly the panel/command divergence the row↔command invariant
// exists to catch.
// ---------------------------------------------------------------------------
private uint tagOf(const(uint)[] arr, size_t fi) {
    return fi < arr.length ? arr[fi] : 0u;
}

private uint[] presentTags(const(Mesh)* m, bool isPart) {
    import std.algorithm : sort;
    if (m is null) return null;
    const(uint)[] arr = isPart ? m.facePart : m.faceMaterial;
    bool[uint] seen;
    foreach (fi; 0 .. m.faces.length) seen[tagOf(arr, fi)] = true;
    uint[] outp;
    foreach (t; seen.byKey) outp ~= t;
    outp.sort();
    return outp;
}

private StatCount tagCount(const(Mesh)* m, bool isPart, uint tag, bool wantSel) {
    StatCount c;
    c.selKnown = wantSel;
    if (m is null) { c.selKnown = false; return c; }
    const(uint)[] arr = isPart ? m.facePart : m.faceMaterial;
    foreach (fi; 0 .. m.faces.length) {
        if (tagOf(arr, fi) != tag) continue;
        ++c.num;
        if (wantSel && m.isFaceSelected(fi)) ++c.sel;
    }
    return c;
}

/// A vertex/polygon selection set's row. `num` counts the members that are
/// IN RANGE for the current geometry, which is exactly the set the button
/// would select — a stored member past the end of the mesh selects nothing,
/// so counting it would put the row and its own command out of step.
private StatCount setCount(const(Mesh)* m, const(uint)[] members, size_t n,
                           bool wantSel, bool delegate(size_t) isSelected) {
    StatCount c;
    c.selKnown = wantSel;
    if (m is null) { c.selKnown = false; return c; }
    foreach (idx; members) {
        if (idx >= n) continue;
        ++c.num;
        if (wantSel && isSelected(idx)) ++c.sel;
    }
    return c;
}

/// The edge-domain set's row. Its storage is keyed by VERTEX PAIR rather than
/// by edge index, and the command resolves membership per live edge — so this
/// walks the live edges too, rather than trusting the stored pair count.
private StatCount edgeSetCount(const(Mesh)* m, string name, bool wantSel) {
    import mesh_selsets : selSetMembersEdge;
    import mesh : edgeKey;
    StatCount c;
    c.selKnown = wantSel;
    if (m is null) { c.selKnown = false; return c; }
    bool[ulong] keys;
    foreach (pr; selSetMembersEdge(*m, name)) keys[edgeKey(pr[0], pr[1])] = true;
    foreach (ei; 0 .. m.edges.length) {
        if (edgeKey(m.edges[ei][0], m.edges[ei][1]) !in keys) continue;
        ++c.num;
        if (wantSel && m.isEdgeSelected(ei)) ++c.sel;
    }
    return c;
}

/// Faces that carry (or do not carry) our subpatch flag — the two rows of
/// `By Type` we can answer. ONE predicate, and it populates ONE row: Р10.
private StatCount subpatchCount(const(Mesh)* m, bool wantSubpatch, bool wantSel) {
    StatCount c;
    c.selKnown = wantSel;
    if (m is null) { c.selKnown = false; return c; }
    foreach (fi; 0 .. m.faces.length) {
        if (m.isFaceSubpatch(fi) != wantSubpatch) continue;
        ++c.num;
        if (wantSel && m.isFaceSelected(fi)) ++c.sel;
    }
    return c;
}

// ---------------------------------------------------------------------------
// statSectionsInto — the whole tree.
// ---------------------------------------------------------------------------

/// Fill `outBuf` with the four sections, in the fixed traversal order
/// Vertices, Edges, Polygons, Items. NOT a sort: all four are emitted every
/// time regardless of the current selection type, which only decides whose
/// `Sel` column carries a number.
///
/// Fills in place (the `itemRowsInto` / `selectedItemsInto` idiom) so a panel
/// holding one static buffer does not churn an array per frame.
void statSectionsInto(const(Document)* doc, SelType current,
                      ref const StatContext ctx, ref const StatExpand exp,
                      ref StatSection[] outBuf) {
    outBuf.length = 0;
    outBuf.assumeSafeAppend();

    const(Mesh)* m = ctx.mesh;

    outBuf ~= verticesSection(m, ctx, current, exp);
    outBuf ~= edgesSection(m, ctx, current, exp);
    outBuf ~= polygonsSection(doc, m, ctx, current, exp);
    outBuf ~= itemsSection(doc, current, exp);
}

private StatSection sectionShell(string label, SelType type, const(Mesh)* m,
                                 long total, long selected, SelType current,
                                 string cmdId, string test,
                                 ref const StatExpand exp) {
    StatSection s;
    s.label    = label;
    s.type     = type;
    s.expanded = exp.sectionOpen(type);
    const bool gate = (current == type);
    if (m is null) {
        // No edit target: the section row is emitted with its label and its
        // disclosure, and both numbers are honestly unknown.
        s.num    = StatCell(false, 0);
        s.sel    = StatCell(false, 0);
        s.avail  = StatAvail.unmeasured;
        s.reason = kNoEditTargetReason;
        s.tone   = StatTone.normal;
        return s;
    }
    s.num   = StatCell(true, total);
    s.sel   = StatCell(gate, gate ? selected : 0);
    s.avail = StatAvail.live;
    s.tone  = toneOf(s.sel);
    // The section row's own action selects EVERYTHING of its component —
    // `compare:all`, and deliberately no `value` key.
    s.add    = StatAction(cmdId, byStatArgs(test, "all", 0, false, true));
    s.remove = StatAction(cmdId, byStatArgs(test, "all", 0, false, false));
    return s;
}

private StatSection verticesSection(const(Mesh)* m, ref const StatContext ctx,
                                    SelType current, ref const StatExpand exp) {
    enum string kSection = "Vertices";
    enum string kCmd     = "select.byStat.vertex";
    const bool gate = (current == SelType.Vertex);

    auto s = sectionShell(kSection, SelType.Vertex, m,
                          m is null ? 0 : cast(long) m.vertices.length,
                          m is null ? 0 : cast(long) m.countSelectedVertices(),
                          current, kCmd, "edgeCount", exp);
    if (!s.expanded) return s;

    // ---- By Edge / By Polygon: the two fixed-count partitions -------------
    static immutable string[] kCountRows = ["0", "1", "2", "3", "4", ">4"];
    foreach (which; 0 .. 2) {
        const bool isEdge = (which == 0);
        auto cat = makeCategory(kSection, isEdge ? "By Edge" : "By Polygon", exp);
        if (cat.expanded) {
            foreach (ri, label; kCountRows) {
                const bool more = (ri == kCountRows.length - 1);
                const int  val  = more ? 4 : cast(int) ri;
                const string cmp = more ? "more" : "equal";
                const string test = isEdge ? "edgeCount" : "polygonCount";
                if (m is null) {
                    cat.leaves ~= unmeasuredLeaf(label, kNoEditTargetReason);
                    continue;
                }
                auto c = vertexStatCount(ctx,
                    isEdge ? VertexStat.edgeCount : VertexStat.polygonCount,
                    more ? Compare.more : Compare.equal, val, "", gate);
                cat.leaves ~= liveLeaf(label, c, kCmd,
                    byStatArgs(test, cmp, val, true, true),
                    byStatArgs(test, cmp, val, true, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- By Boundary: one row, and we have no predicate for it ------------
    {
        auto cat = makeCategory(kSection, "By Boundary", exp);
        if (cat.expanded)
            cat.leaves ~= unmeasuredLeaf("Colinear",
                m is null ? kNoEditTargetReason : kUnmeasuredPredicate);
        s.categories ~= cat;
    }

    // ---- By Vertex Map: one row per weight map ----------------------------
    {
        auto cat = makeCategory(kSection, "By Vertex Map", exp);
        if (cat.expanded && m !is null) {
            foreach (name; m.weightMapNames()) {
                auto c = vertexStatCount(ctx, VertexStat.weightMap,
                                         Compare.all, -1, name, gate);
                cat.leaves ~= liveLeaf(name, c, kCmd,
                    `{"test":"weightMap","map":` ~ jsonStr(name) ~ `,"mode":"add"}`,
                    `{"test":"weightMap","map":` ~ jsonStr(name) ~ `,"mode":"remove"}`);
            }
        }
        s.categories ~= cat;
    }

    // ---- By Selection Set --------------------------------------------------
    {
        import mesh_selsets : selSetNamesVertex, selSetMembersVertex;
        auto cat = makeCategory(kSection, "By Selection Set", exp);
        if (cat.expanded && m !is null) {
            foreach (name; selSetNamesVertex(*m)) {
                auto members = selSetMembersVertex(*m, name);
                auto c = setCount(m, members, m.vertices.length, gate,
                                  (size_t i) => m.isVertexSelected(i));
                cat.leaves ~= liveLeaf(name, c, "select.set.apply",
                    setApplyArgs(name, true), setApplyArgs(name, false));
            }
        }
        s.categories ~= cat;
    }

    return s;
}

private StatSection edgesSection(const(Mesh)* m, ref const StatContext ctx,
                                 SelType current, ref const StatExpand exp) {
    enum string kSection = "Edges";
    enum string kCmd     = "select.byStat.edge";
    const bool gate = (current == SelType.Edge);

    auto s = sectionShell(kSection, SelType.Edge, m,
                          m is null ? 0 : cast(long) m.edges.length,
                          m is null ? 0 : cast(long) m.countSelectedEdges(),
                          current, kCmd, "polygonCount", exp);
    if (!s.expanded) return s;

    // ---- By Polygon: 1,2,3,4,>4 (an edge with no polygon is in no row) ----
    {
        static immutable string[] kRows = ["1", "2", "3", "4", ">4"];
        auto cat = makeCategory(kSection, "By Polygon", exp);
        if (cat.expanded) {
            foreach (ri, label; kRows) {
                const bool more = (ri == kRows.length - 1);
                const int  val  = more ? 4 : cast(int)(ri + 1);
                const string cmp = more ? "more" : "equal";
                if (m is null) {
                    cat.leaves ~= unmeasuredLeaf(label, kNoEditTargetReason);
                    continue;
                }
                auto c = edgeStatCount(ctx, EdgeStat.polygonCount,
                                       more ? Compare.more : Compare.equal,
                                       val, gate);
                cat.leaves ~= liveLeaf(label, c, kCmd,
                    byStatArgs("polygonCount", cmp, val, true, true),
                    byStatArgs("polygonCount", cmp, val, true, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- By Boundary: Part / Material / Geometry live, UVs / Coplanar not --
    {
        auto cat = makeCategory(kSection, "By Boundary", exp);
        if (cat.expanded) {
            if (m is null) {
                foreach (label; ["Part", "Material", "Geometry", "UVs", "Coplanar"])
                    cat.leaves ~= unmeasuredLeaf(label, kNoEditTargetReason);
            } else {
                auto part = edgeStatCount(ctx, EdgeStat.partBoundary,
                                          Compare.all, -1, gate);
                cat.leaves ~= liveLeaf("Part", part, kCmd,
                    `{"test":"partBoundary","compare":"all","mode":"add"}`,
                    `{"test":"partBoundary","compare":"all","mode":"remove"}`);

                auto matl = edgeStatCount(ctx, EdgeStat.materialBoundary,
                                          Compare.all, -1, gate);
                cat.leaves ~= liveLeaf("Material", matl, kCmd,
                    `{"test":"materialBoundary","compare":"all","mode":"add"}`,
                    `{"test":"materialBoundary","compare":"all","mode":"remove"}`);

                // "Geometry" is spelled as the COUNT it is — exactly one
                // adjacent polygon — measured identical to the tag-free
                // boundary row, and deliberately not a second thing named
                // "boundary" in this codebase.
                auto geo = edgeStatCount(ctx, EdgeStat.polygonCount,
                                         Compare.equal, 1, gate);
                cat.leaves ~= liveLeaf("Geometry", geo, kCmd,
                    byStatArgs("polygonCount", "equal", 1, true, true),
                    byStatArgs("polygonCount", "equal", 1, true, false));

                cat.leaves ~= unmeasuredLeaf("UVs", kUnmeasuredPredicate);
                cat.leaves ~= unmeasuredLeaf("Coplanar", kUnmeasuredPredicate);
            }
        }
        s.categories ~= cat;
    }

    // ---- By Vertex Map: rows from the map-kind registry, predicate absent --
    // Owner decision 4: enumerate one row per EDGE-domain map kind rather than
    // inventing a "can this map live on an edge" test. The rows are real; the
    // predicate that would count them is not written, so they read `—`.
    {
        auto cat = makeCategory(kSection, "By Vertex Map", exp);
        if (cat.expanded) {
            import std.traits : EnumMembers;
            import mesh : mapKindInfo = kindInfo;
            // Owner decision 4: the EDGE-domain rows come from the map-kind
            // REGISTRY, not from a "can this map live on an edge" test we would
            // have had to invent. `EnumMembers` means a kind added to the
            // registry appears here the day it is added.
            foreach (k; EnumMembers!MapKind) {
                const info = mapKindInfo(k);
                if (info.domain != MapDomain.Edge) continue;
                cat.leaves ~= unmeasuredLeaf(info.reservedName,
                    m is null ? kNoEditTargetReason : kUnmeasuredPredicate);
            }
        }
        s.categories ~= cat;
    }

    // ---- By Selection Set --------------------------------------------------
    {
        import mesh_selsets : selSetNamesEdge;
        auto cat = makeCategory(kSection, "By Selection Set", exp);
        if (cat.expanded && m !is null) {
            foreach (name; selSetNamesEdge(*m)) {
                auto c = edgeSetCount(m, name, gate);
                cat.leaves ~= liveLeaf(name, c, "select.set.apply",
                    setApplyArgs(name, true), setApplyArgs(name, false));
            }
        }
        s.categories ~= cat;
    }

    return s;
}

private StatSection polygonsSection(const(Document)* doc, const(Mesh)* m,
                                    ref const StatContext ctx, SelType current,
                                    ref const StatExpand exp) {
    enum string kSection = "Polygons";
    enum string kCmd     = "select.byStat.polygon";
    const bool gate = (current == SelType.Polygon);

    auto s = sectionShell(kSection, SelType.Polygon, m,
                          m is null ? 0 : cast(long) m.faces.length,
                          m is null ? 0 : cast(long) m.countSelectedFaces(),
                          current, kCmd, "vertexCount", exp);
    if (!s.expanded) return s;

    // ---- By Type: fifteen rows, three classes ------------------------------
    {
        auto cat = makeCategory(kSection, "By Type", exp);
        if (cat.expanded) {
            foreach (ri, label; kPolygonTypeRows) {
                if (m is null) {
                    cat.leaves ~= unmeasuredLeaf(label, kNoEditTargetReason);
                    continue;
                }
                switch (ri) {
                    case 0:   // Faces — our plain polygons
                        cat.leaves ~= countOnlyLeaf(label,
                            subpatchCount(m, false, gate));
                        break;
                    case 1:   // Subdivs — our subpatch faces (Р10)
                        cat.leaves ~= countOnlyLeaf(label,
                            subpatchCount(m, true, gate));
                        break;
                    case 7:   // Catmull-Clark — the OTHER subdivision row
                        cat.leaves ~= structuralZeroLeaf(label, gate, kSubdivHome);
                        break;
                    case 10: case 11: case 12: case 13: case 14:
                        cat.leaves ~= unmeasuredLeaf(label, kUnmeasuredPredicate);
                        break;
                    default:  // a polygon kind our mesh model cannot hold
                        cat.leaves ~= structuralZeroLeaf(label, gate, kNoSuchPolygonKind);
                        break;
                }
            }
        }
        s.categories ~= cat;
    }

    // ---- By Vertex: 1,2,3,4,>4 --------------------------------------------
    {
        static immutable string[] kRows = ["1", "2", "3", "4", ">4"];
        auto cat = makeCategory(kSection, "By Vertex", exp);
        if (cat.expanded) {
            foreach (ri, label; kRows) {
                const bool more = (ri == kRows.length - 1);
                const int  val  = more ? 4 : cast(int)(ri + 1);
                const string cmp = more ? "more" : "equal";
                if (m is null) {
                    cat.leaves ~= unmeasuredLeaf(label, kNoEditTargetReason);
                    continue;
                }
                auto c = polygonStatCount(ctx, PolygonStat.vertexCount,
                                          more ? Compare.more : Compare.equal,
                                          val, gate);
                cat.leaves ~= liveLeaf(label, c, kCmd,
                    byStatArgs("vertexCount", cmp, val, true, true),
                    byStatArgs("vertexCount", cmp, val, true, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- Part: labelled by ID (owner decision 5) ---------------------------
    {
        import std.conv : to;
        auto cat = makeCategory(kSection, "Part", exp);
        if (cat.expanded && m !is null) {
            foreach (tag; presentTags(m, /*isPart=*/true)) {
                auto c = tagCount(m, true, tag, gate);
                cat.leaves ~= liveLeaf("Part " ~ tag.to!string, c, "select.byTag",
                    byTagArgsId("part", tag, true), byTagArgsId("part", tag, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- Material: by surface name where there is one, else by id ----------
    {
        import std.conv : to;
        auto cat = makeCategory(kSection, "Material", exp);
        if (cat.expanded && m !is null) {
            foreach (tag; presentTags(m, /*isPart=*/false)) {
                auto c = tagCount(m, false, tag, gate);
                const bool named = tag < m.surfaces.length
                                && m.surfaces[tag].name.length > 0;
                if (named) {
                    const string nm = m.surfaces[tag].name;
                    cat.leaves ~= liveLeaf(nm, c, "select.byTag",
                        byTagArgsName("material", nm, true),
                        byTagArgsName("material", nm, false));
                } else {
                    cat.leaves ~= liveLeaf("Material " ~ tag.to!string, c,
                        "select.byTag",
                        byTagArgsId("material", tag, true),
                        byTagArgsId("material", tag, false));
                }
            }
        }
        s.categories ~= cat;
    }

    // ---- By Selection Set --------------------------------------------------
    {
        import mesh_selsets : selSetNamesPolygon, selSetMembersPolygon;
        auto cat = makeCategory(kSection, "By Selection Set", exp);
        if (cat.expanded && m !is null) {
            foreach (name; selSetNamesPolygon(*m)) {
                auto members = selSetMembersPolygon(*m, name);
                auto c = setCount(m, members, m.faces.length, gate,
                                  (size_t i) => m.isFaceSelected(i));
                cat.leaves ~= liveLeaf(name, c, "select.set.apply",
                    setApplyArgs(name, true), setApplyArgs(name, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- Smoothing Groups: permanently empty, header still shown -----------
    // We have no smoothing-group data model. A category whose dynamic list is
    // empty contributes no leaves and KEEPS its header — which is the
    // reference's own empty-list rendering, not something new.
    s.categories ~= makeCategory(kSection, "Smoothing Groups", exp);

    // ---- Layer (the renamed GL category, owner decision 2) -----------------
    // The one DOCUMENT-scoped category in the tree: it counts polygons across
    // foreground / background layers rather than in the edit target. That
    // creates no inconsistency with the primary-scoped rows precisely because
    // its buttons are inert — there is no click that could disagree.
    {
        auto cat = makeCategory(kSection, "Layer", exp);
        if (cat.expanded) {
            long fg = 0, bg = 0;
            if (doc !is null) {
                foreach (l; doc.layers) {
                    if (l is null || !l.hasMesh) continue;
                    auto lm = l.meshOrNull();
                    if (lm is null) continue;
                    if (doc.foreground(l))      fg += cast(long) lm.faces.length;
                    else if (doc.background(l)) bg += cast(long) lm.faces.length;
                }
            }
            cat.leaves ~= inertLeaf("Foreground", fg, gate);
            cat.leaves ~= inertLeaf("Background", bg, gate);
        }
        s.categories ~= cat;
    }

    return s;
}

private StatSection itemsSection(const(Document)* doc, SelType current,
                                 ref const StatExpand exp) {
    import std.algorithm : sort;
    enum string kSection = "Items";
    const bool gate = (current == SelType.Item);

    StatSection s;
    s.label    = kSection;
    s.type     = SelType.Item;
    s.expanded = exp.sectionOpen(SelType.Item);

    // The Items section reads `doc.layers` and touches NO mesh, so it counts
    // honestly even with no edit target — the state in which every geometry
    // row above reads `—`.
    long total = 0, selected = 0;
    if (doc !is null) {
        foreach (l; doc.layers) {
            if (l is null) continue;
            ++total;
            if (l.selected) ++selected;
        }
    }
    s.num   = StatCell(true, total);
    s.sel   = StatCell(gate, gate ? selected : 0);
    // No command selects "every item whatever its kind", so the section row has
    // no affordance rather than a dead button. OURS; registry row.
    s.avail  = StatAvail.noAffordance;
    s.reason = kCountOnly;
    s.tone   = toneOf(s.sel);
    if (!s.expanded) return s;

    // ---- By Type: one row per kind PRESENT, sorted by display name ---------
    {
        auto cat = makeCategory(kSection, "By Type", exp);
        if (cat.expanded && doc !is null) {
            long[ItemKind.max + 1] num;
            long[ItemKind.max + 1] sel;
            bool[ItemKind.max + 1] present;
            foreach (l; doc.layers) {
                if (l is null) continue;
                present[cast(size_t) l.kind] = true;
                ++num[cast(size_t) l.kind];
                if (l.selected) ++sel[cast(size_t) l.kind];
            }
            struct Row { string label; ItemKind k; }
            Row[] rows;
            foreach (ki; 0 .. ItemKind.max + 1)
                if (present[ki])
                    rows ~= Row(kindHeading(cast(ItemKind) ki), cast(ItemKind) ki);
            rows.sort!((a, b) => a.label < b.label);
            foreach (r; rows) {
                StatCount c;
                c.num      = num[cast(size_t) r.k];
                c.sel      = gate ? sel[cast(size_t) r.k] : 0;
                c.selKnown = gate;
                const string token = kindInfo(r.k).token;
                cat.leaves ~= liveLeaf(r.label, c, "layer.select",
                    layerSelectArgs(token, true), layerSelectArgs(token, false));
            }
        }
        s.categories ~= cat;
    }

    // ---- By Selection Set: no item-domain sets exist -----------------------
    s.categories ~= makeCategory(kSection, "By Selection Set", exp);

    return s;
}
