module mesh_selsets;

// ---------------------------------------------------------------------------
// mesh_selsets — named, typed, per-mesh SELECTION SETS (task 1060).
//
// A selection set remembers a group of elements under a name so the user can
// come back to it later — "select the mouth cavity", "select the outer
// shell" — and re-apply it after the live selection has moved on or the
// document has been reloaded. One registry per geometry domain (vertex /
// edge / polygon); a set never spans two domains. Storage lives on `Mesh`
// (six public fields declared next to `meshMaps`); every VERB lives here as
// a free function over `ref Mesh`, kept out of mesh.d to respect its size
// ceiling (see the module doc on `meshMaps` for the sibling precedent —
// `mesh_corner_maps.d` / `mesh_edit_delta.d` follow the same split).
//
// Storage shape, and why it is not a `MeshMap`:
//   - `MeshMap` is `{name, dim, domain, float[] data}`, dense and keyed by
//     element index. A membership bit does not belong in a float channel
//     (every generic float-map consumer — weight-map listing, the falloff
//     panel, the `.v3d` weightMaps writer — would need a special case to
//     exclude it), and `MapDomain` has no Polygon member at all (task 1060
//     plan, §Q1). So sets get their own home.
//   - VERTEX and POLYGON sets are one `ulong` bitmask PER ELEMENT, parallel
//     to `vertices`/`faces`: bit `s` of an element's mask is membership in
//     the set occupying slot `s`. One mask array serves every set in that
//     domain — carrying a polygon set alongside `facePart` costs one extra
//     line at each site that already carries `facePart`, not one per set.
//   - EDGE sets are keyed by the CANONICAL VERTEX PAIR (`edgeKey`), not by
//     edge index. `Mesh.rebuildEdges()` renumbers every edge on any topology
//     edit while `resizeMeshMaps(MapDomain.Edge)` only fixes length — an
//     index-parallel edge channel is garbage after the very next edit. A
//     pair key survives `rebuildEdges()` by construction (no length hook, no
//     index remap needed) but is NOT free against vertex-index-renumbering
//     events (`compactUnreferenced`, a weld) — those still change the
//     numbers the key embeds, so every site that renumbers vertices must
//     RE-KEY the edge-set AA through `selSetRekeyEdges` below. See the six
//     call sites enumerated in doc/selection_sets_plan.md Stage 5b — missing
//     any of them fails SILENTLY (membership disappears, or reattaches to
//     the wrong edge, with no length mismatch and no assertion to trip).
//
// Slot indices are assignment order and are NOT stable across a save/load —
// nothing outside a mesh references a slot; every external reference is by
// NAME. An empty name string marks a free slot, reused by the next `ensure`
// before the registry grows.
// ---------------------------------------------------------------------------

import mesh : Mesh, edgeKey;
import std.algorithm : sort;
import std.conv : to;

/// Kernel cap: at most this many LIVE sets per domain per mesh. This is not a
/// policy knob — it IS the bitmask width (`ulong` = 64 bits), so exceeding it
/// cannot corrupt anything; it can only be refused. Enforced in `ensureSlot`
/// below, which is the single choke point every set-creating verb funnels
/// through (`store`, `edit` on a missing name) — a scripted/HTTP caller hits
/// the same cap the UI does.
enum size_t MAX_SELECTION_SETS = 64;

/// Kernel cap on a set NAME's byte length. Names are user strings reaching
/// this module straight off `/api/command` with no `Param.enforceBounds()`
/// backstop (that only clamps Int/Float — source/params.d:810-822), so the
/// bound lives here, in `validateSetName`, the one function every naming verb
/// calls before touching the registry.
enum size_t MAX_SET_NAME_LEN = 128;

/// Which geometry domain a selection set belongs to. A set never spans two —
/// the vertex/edge/polygon registries are independent namespaces, so the same
/// name may exist once per domain without colliding.
enum SetDomain { Vertex, Edge, Polygon }

/// `select.set.apply`'s three laws (measured, `toolcards/selection_sets/`):
/// union / set-difference / replace against the LIVE selection.
enum SetApplyMode { select, deselect, replace }

/// `select.set.edit`'s three laws (measured, `toolcards/selection_sets/`):
/// union / subtract / replace the SET's membership from the live selection.
enum SetEditMode { add, remove, replace }

// ---------------------------------------------------------------------------
// Name validation — every creating/renaming verb calls this first.
// ---------------------------------------------------------------------------

/// Returns `null` when `name` is an acceptable selection-set name, or a
/// human-readable rejection reason otherwise. Rejects: empty, longer than
/// `MAX_SET_NAME_LEN` bytes, any control byte (`< 0x20`), and `;` — reserved
/// as the polygon-tag join separator our own `.v3d` codec / any future
/// interchange writer would use (capture-verified: set names may contain
/// spaces, e.g. `"B B"`; `;` is the one character that cannot round-trip
/// through a joined tag string).
string validateSetName(string name) pure @safe {
    if (name.length == 0)
        return "selection-set name must not be empty";
    if (name.length > MAX_SET_NAME_LEN)
        return "selection-set name exceeds " ~ to!string(MAX_SET_NAME_LEN) ~ " bytes";
    foreach (c; name) {
        if (c < 0x20)
            return "selection-set name must not contain control characters";
        if (c == ';')
            return "selection-set name must not contain ';' (reserved separator)";
    }
    return null;
}

// ---------------------------------------------------------------------------
// Name-registry primitives — identical shape across all three domains, so
// they operate on a bare `string[]` (the free-slot / cap / find-by-name
// bookkeeping) rather than being written three times.
// ---------------------------------------------------------------------------

private int findSlotIdx(const(string)[] names, string name) pure @safe {
    foreach (i, n; names) if (n == name) return cast(int) i;
    return -1;
}

private int freeSlotIdx(const(string)[] names) pure @safe {
    foreach (i, n; names) if (n.length == 0) return cast(int) i;
    return -1;
}

/// Find-or-create a slot named `name`. Reuses a freed (deleted) slot before
/// growing; throws once the domain is at `MAX_SELECTION_SETS` LIVE names and
/// none are free — the kernel cap, enforced here so every caller (UI dialog
/// or a direct `/api/command` POST) hits the identical refusal.
private size_t ensureSlot(ref string[] names, string name) {
    int i = findSlotIdx(names, name);
    if (i >= 0) return cast(size_t) i;
    int f = freeSlotIdx(names);
    if (f >= 0) { names[f] = name; return cast(size_t) f; }
    if (names.length >= MAX_SELECTION_SETS)
        throw new Exception("selection set: at most " ~ to!string(MAX_SELECTION_SETS)
                             ~ " sets per domain per mesh");
    names ~= name;
    return names.length - 1;
}

/// Compact list of the LIVE (non-freed) names in assignment order.
private string[] liveNames(const(string)[] names) pure @safe {
    string[] r;
    foreach (n; names) if (n.length) r ~= n;
    return r;
}

private bool anyLive(const(string)[] names) pure @safe {
    foreach (n; names) if (n.length) return true;
    return false;
}

/// True iff `m` owns at least one selection set, in ANY domain. The
/// interchange (LWO / assimp) writers use this for a warn-once-on-drop —
/// selection sets have no interchange codec (deferred, doc/selection_sets_plan.md
/// §Q3), so this is what turns a silent loss into a logged one.
bool selSetsAnyLive(const ref Mesh m) pure @safe {
    return anyLive(m.vertexSetNames) || anyLive(m.edgeSetNames)
        || anyLive(m.polygonSetNames);
}

// ---------------------------------------------------------------------------
// Array-mask engine — shared shape for VERTEX and POLYGON sets (one `ulong`
// bitmask per element, parallel to the element array).
// ---------------------------------------------------------------------------

private void clearBitEverywhere(ref ulong[] mask, size_t slot) {
    const ulong keep = ~(1UL << slot);
    foreach (ref w; mask) w &= keep;
}

private bool memberOf(const(ulong)[] mask, size_t slot, size_t i) pure @safe {
    if (i >= mask.length) return false;
    return (mask[i] & (1UL << slot)) != 0;
}

/// Write a set's membership from `selection` (parallel bool array) into
/// `mask`'s `slot` bit, per `mode`. Grows `mask` to cover `selection` first —
/// POLYGON masks are lazy-sized (no resize hook, matching `facePart`), so a
/// write must extend the array itself rather than assume a hook already did.
private void writeMembersFromSelection(ref ulong[] mask, size_t slot,
                                        const(bool)[] selection, SetEditMode mode) {
    if (mask.length < selection.length) mask.length = selection.length;
    const ulong bit = 1UL << slot;
    final switch (mode) {
        case SetEditMode.add:
            foreach (i, s; selection) if (s) mask[i] |= bit;
            break;
        case SetEditMode.remove:
            foreach (i, s; selection) if (s) mask[i] &= ~bit;
            break;
        case SetEditMode.replace:
            clearBitEverywhere(mask, slot);
            foreach (i, s; selection) if (s) mask[i] |= bit;
            break;
    }
}

/// Combine a set's membership (`mask`/`slot`) with the CURRENT selection per
/// `mode`, producing the new selection to hand to `selectXFrom`.
private bool[] combineWithSelection(const(ulong)[] mask, size_t slot,
                                     const(bool)[] current, SetApplyMode mode) {
    auto want = new bool[](current.length);
    final switch (mode) {
        case SetApplyMode.select:
            foreach (i, c; current) want[i] = c || memberOf(mask, slot, i);
            break;
        case SetApplyMode.deselect:
            foreach (i, c; current) want[i] = c && !memberOf(mask, slot, i);
            break;
        case SetApplyMode.replace:
            foreach (i; 0 .. current.length) want[i] = memberOf(mask, slot, i);
            break;
    }
    return want;
}

// ---------------------------------------------------------------------------
// Vertex domain
// ---------------------------------------------------------------------------

string[] selSetNamesVertex(const ref Mesh m) { return liveNames(m.vertexSetNames); }
bool     selSetOwnsVertex(const ref Mesh m, string name) { return findSlotIdx(m.vertexSetNames, name) >= 0; }

/// `store` / `edit` on a missing name: creates it, then applies `mode`
/// against `selection`. Returns the slot (informational only — callers key
/// everything else by name).
size_t selSetEditVertex(ref Mesh m, string name, SetEditMode mode, const(bool)[] selection) {
    const size_t slot = ensureSlot(m.vertexSetNames, name);
    if (m.vertexSetMask.length < m.vertices.length) m.vertexSetMask.length = m.vertices.length;
    writeMembersFromSelection(m.vertexSetMask, slot, selection, mode);
    return slot;
}

/// `apply`: returns `false` (mutates nothing) when this mesh does not own
/// `name` in the vertex domain — the per-mesh "no owner" signal the
/// multi-layer command walks foreground layers to resolve.
bool selSetApplyVertex(ref Mesh m, string name, SetApplyMode mode) {
    const int i = findSlotIdx(m.vertexSetNames, name);
    if (i < 0) return false;
    auto want = combineWithSelection(m.vertexSetMask, cast(size_t) i, m.selectedVertices, mode);
    m.selectVerticesFrom(want);
    return true;
}

bool selSetDeleteVertex(ref Mesh m, string name) {
    const int i = findSlotIdx(m.vertexSetNames, name);
    if (i < 0) return false;
    m.vertexSetNames[i] = "";
    clearBitEverywhere(m.vertexSetMask, cast(size_t) i);
    return true;
}

/// 0 = renamed; 1 = `from` not found; 2 = `to` already exists.
int selSetRenameVertex(ref Mesh m, string from, string to_) {
    const int i = findSlotIdx(m.vertexSetNames, from);
    if (i < 0) return 1;
    if (findSlotIdx(m.vertexSetNames, to_) >= 0) return 2;
    m.vertexSetNames[i] = to_;
    return 0;
}

/// Member vertex indices, ascending — the read accessor `/api/model` and the
/// `.v3d` writer both use (neither wants to go through a live-selection
/// round trip just to list a set's contents).
uint[] selSetMembersVertex(const ref Mesh m, string name) {
    const int i = findSlotIdx(m.vertexSetNames, name);
    uint[] r;
    if (i < 0) return r;
    const ulong bit = 1UL << i;
    foreach (vi, w; m.vertexSetMask) if (w & bit) r ~= cast(uint) vi;
    return r;
}

// ---------------------------------------------------------------------------
// Polygon domain — identical shape to Vertex, over `faceSetMask`/`faces`.
// ---------------------------------------------------------------------------

string[] selSetNamesPolygon(const ref Mesh m) { return liveNames(m.polygonSetNames); }
bool     selSetOwnsPolygon(const ref Mesh m, string name) { return findSlotIdx(m.polygonSetNames, name) >= 0; }

size_t selSetEditPolygon(ref Mesh m, string name, SetEditMode mode, const(bool)[] selection) {
    const size_t slot = ensureSlot(m.polygonSetNames, name);
    writeMembersFromSelection(m.faceSetMask, slot, selection, mode);
    return slot;
}

bool selSetApplyPolygon(ref Mesh m, string name, SetApplyMode mode) {
    const int i = findSlotIdx(m.polygonSetNames, name);
    if (i < 0) return false;
    auto want = combineWithSelection(m.faceSetMask, cast(size_t) i, m.selectedFaces, mode);
    m.selectFacesFrom(want);
    return true;
}

bool selSetDeletePolygon(ref Mesh m, string name) {
    const int i = findSlotIdx(m.polygonSetNames, name);
    if (i < 0) return false;
    m.polygonSetNames[i] = "";
    clearBitEverywhere(m.faceSetMask, cast(size_t) i);
    return true;
}

int selSetRenamePolygon(ref Mesh m, string from, string to_) {
    const int i = findSlotIdx(m.polygonSetNames, from);
    if (i < 0) return 1;
    if (findSlotIdx(m.polygonSetNames, to_) >= 0) return 2;
    m.polygonSetNames[i] = to_;
    return 0;
}

/// Member face indices, ascending — see `selSetMembersVertex`'s doc comment.
uint[] selSetMembersPolygon(const ref Mesh m, string name) {
    const int i = findSlotIdx(m.polygonSetNames, name);
    uint[] r;
    if (i < 0) return r;
    const ulong bit = 1UL << i;
    foreach (fi, w; m.faceSetMask) if (w & bit) r ~= cast(uint) fi;
    return r;
}

// ---------------------------------------------------------------------------
// Edge domain — keyed by canonical vertex pair (`edgeKey`), not edge index.
// ---------------------------------------------------------------------------

string[] selSetNamesEdge(const ref Mesh m) { return liveNames(m.edgeSetNames); }
bool     selSetOwnsEdge(const ref Mesh m, string name) { return findSlotIdx(m.edgeSetNames, name) >= 0; }

private ulong edgeMaskOf(const(ulong[ulong]) mask, ulong key) {
    if (auto p = key in mask) return *p;
    return 0UL;
}

size_t selSetEditEdge(ref Mesh m, string name, SetEditMode mode, const(bool)[] selection) {
    const size_t slot = ensureSlot(m.edgeSetNames, name);
    const ulong bit = 1UL << slot;
    final switch (mode) {
        case SetEditMode.add:
            foreach (ei, s; selection) {
                if (!s || ei >= m.edges.length) continue;
                const key = edgeKey(m.edges[ei][0], m.edges[ei][1]);
                m.edgeSetMask[key] = edgeMaskOf(m.edgeSetMask, key) | bit;
            }
            break;
        case SetEditMode.remove:
            foreach (ei, s; selection) {
                if (!s || ei >= m.edges.length) continue;
                const key = edgeKey(m.edges[ei][0], m.edges[ei][1]);
                if (auto p = key in m.edgeSetMask) {
                    *p &= ~bit;
                    if (*p == 0) m.edgeSetMask.remove(key);
                }
            }
            break;
        case SetEditMode.replace:
            foreach (key; m.edgeSetMask.keys) {
                m.edgeSetMask[key] &= ~bit;
                if (m.edgeSetMask[key] == 0) m.edgeSetMask.remove(key);
            }
            foreach (ei, s; selection) {
                if (!s || ei >= m.edges.length) continue;
                const key = edgeKey(m.edges[ei][0], m.edges[ei][1]);
                m.edgeSetMask[key] = edgeMaskOf(m.edgeSetMask, key) | bit;
            }
            break;
    }
    return slot;
}

/// `ei`'s set-membership bit, or `false` when `ei` is out of range for
/// `m.edges` (NIT, review round 2 — mirrors the guard `selSetEditEdge`
/// above already applies at its own three `ei >= m.edges.length` checks;
/// this is the same relation on the apply/read side, which indexed
/// `m.edges[ei]` unguarded).
private bool edgeIsMember(const ref Mesh m, size_t ei, ulong bit) {
    if (ei >= m.edges.length) return false;
    const key = edgeKey(m.edges[ei][0], m.edges[ei][1]);
    return (edgeMaskOf(m.edgeSetMask, key) & bit) != 0;
}

bool selSetApplyEdge(ref Mesh m, string name, SetApplyMode mode) {
    const int i = findSlotIdx(m.edgeSetNames, name);
    if (i < 0) return false;
    const ulong bit = 1UL << cast(size_t) i;
    const current = m.selectedEdges;
    auto want = new bool[](current.length);
    final switch (mode) {
        case SetApplyMode.select:
            foreach (ei, c; current) want[ei] = c || edgeIsMember(m, ei, bit);
            break;
        case SetApplyMode.deselect:
            foreach (ei, c; current) want[ei] = c && !edgeIsMember(m, ei, bit);
            break;
        case SetApplyMode.replace:
            foreach (ei; 0 .. current.length) want[ei] = edgeIsMember(m, ei, bit);
            break;
    }
    m.selectEdgesFrom(want);
    return true;
}

bool selSetDeleteEdge(ref Mesh m, string name) {
    const int i = findSlotIdx(m.edgeSetNames, name);
    if (i < 0) return false;
    m.edgeSetNames[i] = "";
    const ulong keep = ~(1UL << i);
    foreach (key; m.edgeSetMask.keys) {
        m.edgeSetMask[key] &= keep;
        if (m.edgeSetMask[key] == 0) m.edgeSetMask.remove(key);
    }
    return true;
}

int selSetRenameEdge(ref Mesh m, string from, string to_) {
    const int i = findSlotIdx(m.edgeSetNames, from);
    if (i < 0) return 1;
    if (findSlotIdx(m.edgeSetNames, to_) >= 0) return 2;
    m.edgeSetNames[i] = to_;
    return 0;
}

/// Member vertex-index PAIRS (canonical `[min,max]`, per the storage decision
/// — see this module's doc comment) — the `.v3d` writer's edge encoding, and
/// `/api/model`'s read accessor. Ascending by KEY (review SHOULD-FIX 5): the
/// vertex/polygon siblings (`selSetMembersVertex`/`selSetMembersPolygon`)
/// walk a dense array in index order, so their result is ascending BY
/// CONSTRUCTION — this one walks `edgeSetMask`, an associative array whose
/// iteration order is unspecified and rehash-dependent. Feeding both the
/// document writer and `/api/model` straight off that walk meant
/// save→load→save was not stable and no byte comparison of a saved document
/// with edge sets could be trusted. Sort the keys first.
uint[2][] selSetMembersEdge(const ref Mesh m, string name) {
    const int i = findSlotIdx(m.edgeSetNames, name);
    uint[2][] r;
    if (i < 0) return r;
    const ulong bit = 1UL << i;
    auto keys = m.edgeSetMask.keys;
    sort(keys);
    foreach (key; keys) {
        if (!(m.edgeSetMask[key] & bit)) continue;
        r ~= [cast(uint)(key >> 32), cast(uint)(key & 0xFFFF_FFFFUL)];
    }
    return r;
}

/// Re-key every edge-set entry through a vertex-index map `nu`.
///   * `nu(old)` returns the vertex's NEW index, or `uint.max` when that
///     vertex no longer exists (compaction dropped it, or `nu` is only
///     defined for a subset — a standalone insert's shift, say).
///   * Either endpoint mapping to `uint.max` drops the entry (its vertex is
///     gone — there is nothing left to attach the membership to).
///   * Both endpoints mapping to the SAME new index means a weld collapsed
///     this edge to a point — dropped; there is no edge left.
///   * Two DISTINCT old keys landing on the same new key (a weld merges two
///     edges into one survivor) MERGE their masks with `|=` — the survivor
///     joins every set either source edge belonged to. This is the one
///     unmeasured semantic here (no capture ever collapsed two tagged edges
///     under one weld) and the conservative arm: it cannot lose membership.
///     See doc/behavior_gap_registry.md row 3.
///
/// Builds a FRESH associative array and assigns it wholesale — never inserts
/// into the one being iterated (a live D `.byKeyValue` walk is safe against
/// `.remove` on the container being walked, but not against inserting a KEY
/// that read could later revisit under rehash, so a fresh table sidesteps
/// the question entirely rather than relying on that guarantee).
///
/// Call this at EVERY site that renumbers or drops vertices, before or after
/// the vertex array itself is rewritten (the key is a pure function of
/// vertex indices — it does not read `m.edges` or `m.vertices` at all, so
/// there is no ordering dependency against `rebuildEdges()`). Six call
/// sites: `Mesh.compactUnreferenced`, `Mesh.applyVertexRemapAndRebuild`, and
/// the four `mesh_edit_delta.d` replay functions
/// (`applyReindexForward`/`Reverse`, `removeVertsForward`/`Reverse`).
void selSetRekeyEdges(ref Mesh m, scope uint delegate(uint) nu) {
    if (m.edgeSetMask.length == 0) return;
    ulong[ulong] fresh;
    foreach (key, mask; m.edgeSetMask) {
        const uint a = cast(uint)(key >> 32);
        const uint b = cast(uint)(key & 0xFFFF_FFFFUL);
        const uint na = nu(a);
        const uint nb = nu(b);
        if (na == uint.max || nb == uint.max) continue;   // endpoint gone
        if (na == nb) continue;                            // collapsed to a point
        const ulong nk = edgeKey(na, nb);
        if (auto p = nk in fresh) *p |= mask;
        else fresh[nk] = mask;
    }
    m.edgeSetMask = fresh;
}

// ---------------------------------------------------------------------------
// Resize hook (Stage 2) — wired into `Mesh.resizeVertexSelection()`. The
// POLYGON mask is deliberately NOT here: it is lazy-sized like `facePart`
// (grows on write, reads 0 past its length via `memberOf`'s bounds check) —
// there is no per-face resize hook to hang a face-domain grow on
// (`resizeFaceSelection()` touches only `faceMarks`, mirroring the same gap
// `facePart` lives with). The EDGE mask needs no resize hook at all — an
// associative array has no length to keep in lock-step; its correctness
// obligation is entirely the re-key primitive above.
// ---------------------------------------------------------------------------

void selSetResizeVertex(ref Mesh m) {
    m.vertexSetMask.length = m.vertices.length;
}

// ---------------------------------------------------------------------------
// Vertex-mask carry primitives (Stage 5a) — the same three shapes
// `compactUnreferenced`/`mesh_edit_delta.d` already use for `vertexMarks` /
// the Point-domain `meshMaps`, extended to `vertexSetMask`. Kept here (not
// duplicated ad hoc at each site) because the SAME three shapes are needed at
// more than one call site each.
// ---------------------------------------------------------------------------

/// Forward reindex: `remap[old]` is the new index, or `uint.max` if dropped.
/// `newCount` is the post-reindex element count.
ulong[] selSetGatherVertexMaskForward(const(ulong)[] oldMask, const(uint)[] remap, size_t newCount) {
    auto nm = new ulong[](newCount);
    foreach (old, p; remap) {
        if (p == uint.max) continue;
        if (old < oldMask.length) nm[p] = oldMask[old];
    }
    return nm;
}

/// Reverse reindex: same `remap` (old->new), but `currentMask` is at the
/// post-reindex (`new`) index space and the result is rebuilt at the
/// pre-reindex (`old`) index space (`remap.length` long; dropped slots read
/// as an empty mask, the "not a restored capture" convention every sibling
/// array at this site already follows).
ulong[] selSetGatherVertexMaskReverse(const(ulong)[] currentMask, const(uint)[] remap) {
    auto nm = new ulong[](remap.length);
    foreach (old, p; remap) {
        if (p == uint.max) continue;
        if (p < currentMask.length) nm[old] = currentMask[p];
    }
    return nm;
}

/// Drop-filter: compact `mask`, keeping index `i` iff `!drop[i]` (an index
/// past `drop`'s length is treated as kept, matching every sibling array's
/// `i >= drop.length || !drop[i]` survive condition at these sites).
ulong[] selSetDropFilterVertexMask(const(ulong)[] mask, const(bool)[] drop) {
    ulong[] nm;
    nm.reserve(mask.length);
    foreach (i, v; mask) if (i >= drop.length || !drop[i]) nm ~= v;
    return nm;
}
