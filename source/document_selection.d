module document_selection;

// ---------------------------------------------------------------------------
// THE SELECTION STRATUM (task 0721, audit №4 item D10).
//
// Everything `Document` knows about WHO IS SELECTED: the two lists the edit
// target is derived from, the walk that derives it, the readers built on that
// walk, and the mutators. `document.d` keeps the item list itself and the
// membership helpers; payload classes live in leaf modules.
//
// A `mixin template`, not a second struct and not a base class, and the reason
// is the invariant rather than taste. `Document`'s guarantees — at least one
// item selected, `primary` always selected and visible and non-null when it
// exists, foreground/background DERIVED rather than stored — hold because the
// mutators below are the ONLY code that can move an item between the current
// list and the per-kind history buckets. Splitting the state into a separate
// object would have required opening `deselected_`, `selSeatBack_` and
// `selSeatFront_` to a second type; mixed in, they stay `private` members of
// `Document` exactly as they were, and the mutator set that can touch them is
// the same closed set as before this file existed.
//
// WHY THE BODIES NEED NO IMPORTS. A `mixin template`'s identifiers resolve at
// the INSTANTIATION site, not where the template is declared (tasks 0717 and
// 0719 measured this on four probes). So `Layer`, `ItemKind`, `SelState`,
// `LayerRole`, `SelMode`, `Mesh`, `kindInfo`, `NoEditTargetException` and the
// host's own `layers` / `focusedItem` all resolve through `document.d`'s
// import list, as they did when these bodies were written there. An import
// added to THIS file would not participate in that lookup at all.
//
// THE TRAP that comes with the mechanism, from 0719: a member declared
// DIRECTLY in the host silently shadows a same-named mixed-in one, with no
// diagnostic. So the check after this move is a grep for every moved name's
// DEFINITION in `document.d` — there must be none left, only calls.
// ---------------------------------------------------------------------------

version (unittest) {
    /// Task 4061 — how many times `nthEditTargetCandidate` actually ran.
    ///
    /// `version (unittest)` and NOT a `perf_probe.Cat`, following the call
    /// `mesh_visibility.d`'s `VisibilityCounters` already made and for the
    /// same reason: the perf counters are gated on `version(PerfProbe)`,
    /// which the `tests` build configuration does not define, so a pin
    /// written against `Cat.editTargetDerive` reads zero in the gate that
    /// actually runs it — a green that measured nothing. Gating on
    /// `unittest` puts the counter exactly where the pin is and costs the
    /// shipped build nothing: the increment is not compiled.
    ///
    /// `Cat.editTargetDerive` stays beside it and keeps answering the other
    /// question — cost per frame in a running `--build=perf-count` editor,
    /// which is where this task's before/after numbers come from.
    __gshared long g_editTargetDerives;

    /// Reset before a counted window. Not `= 0` at the call site, so the pin
    /// and the counter cannot disagree about which name is the live one.
    void resetEditTargetDerives() nothrow @nogc { g_editTargetDerives = 0; }
}

/// Mixed into `Document`. There is exactly one instantiation and there is
/// meant to be exactly one: this is a file boundary, not a reusable component.
mixin template DocumentSelection() {
    // -----------------------------------------------------------------------
    // Task 0671 — the SECOND LIST. See the struct's doc comment above for the
    // model; this is its whole storage.
    // -----------------------------------------------------------------------

    /// The cache of recently deselected items, bucketed by item KIND.
    ///
    /// BUCKETED, and that is the entire mechanism behind the latch — not an
    /// optimisation and not a tidiness. The reference keys its history nodes by
    /// (selection type, subtype), and the subtype of an item packet IS the item
    /// type, so a selection of kind K flushes bucket K and leaves every other
    /// bucket standing. One flat list would flush the mesh out of history the
    /// moment a plane was selected, which is precisely the behaviour this task
    /// exists to remove.
    ///
    /// Entries are appended on deselect and dropped WHOLESALE on the next
    /// selection of that kind (`noteSelected`). Nothing purges a bucket when a
    /// layer is deleted: the walk filters by MEMBERSHIP (it enumerates
    /// `layers`), so a deleted item is excluded for as long as it is gone and
    /// LIVE AGAIN by identity if an undo reinserts the same object — the same
    /// checked-resolution argument `ItemLink` makes for itself, with the same
    /// payoff of needing no cooperation from the delete path.
    private Layer[][ItemKind.max + 1] deselected_;

    /// Seat allocators for `Layer.selSeat` — back of the queue and front of it.
    /// Two counters rather than one, because the two operations they serve are
    /// genuinely different: joining the selection appends, and re-seating an
    /// item as the edit target (`setPrimary`) prepends. Monotone in opposite
    /// directions, so neither can ever collide with the other.
    private long selSeatBack_  = 0;
    private long selSeatFront_ = 0;

    // -----------------------------------------------------------------------
    // Task 4061 — a memo of the DERIVED edit target, never a second target
    // pointer. Two terms, and they cover two different KINDS of mutation.
    //
    // THE LIST TERM IS THE ARRAY'S OWN (block, length) PAIR, not a counter
    // somebody has to remember to bump. `layers` is a public field with 21
    // production writes, and every one of them is an append, a truncation or
    // a slice reconcatenation — `~=`, `layers[0 .. i]`, `a[0 .. i] ~ a[i+1 ..
    // $]`, or a whole-array assignment. An append either reallocates (new
    // block) or extends in place (same block, DIFFERENT length); the other
    // three always produce a different block or a different length. So the
    // pair moves at all 21 sites BY CONSTRUCTION, with nothing left for a
    // future 22nd site to remember. The generation counter this replaced was
    // remembered at 21 sites and witnessed at one: deleting the call from the
    // reorder path, and from the delete-revert path, left the whole module
    // lane green (review of this task, measured one mutation per run).
    //
    // `primaryMemoLayersBlock_` is a REAL pointer, deliberately, not a
    // `size_t`. The GC therefore scans it, so the block it names cannot be
    // collected and handed to a later allocation while the memo still refers
    // to it — a pointer match means the SAME allocation and not merely the
    // same address. That is what closes the ABA hazard the address-keyed
    // caches elsewhere in the tree need a birth id for (`Layer.birthId`).
    //
    // THE BELT is `noteLayerListChanged()`, kept for exactly one shape the
    // pair cannot see: an IN-PLACE element assignment (`layers[i] = x`, a
    // swap-based permutation). There is no such write in the tree today —
    // and if one is added, the pair is blind to it while the tie-break on
    // `layers` order is not. Pinned, with the pair held constant, by
    // `tests/unit/primary_memo_order_test.d`'s second cell.
    //
    // THE SELECTION TERM IS EXPLICIT INVALIDATION, because the state the walk
    // reads (`selected`, `selSeat`, `deselected_`) lives on the layers and in
    // this mixin, where no cheap structural key exists. Every mutator below
    // calls `invalidatePrimaryMemo()`, and each of those calls has its own
    // reddening cell in `tests/unit/primary_memo_selection_test.d`.
    //
    // ~~A front-seat stamp (`primaryMemoSeatFront_`) was a third term.~~
    // DROPPED (review): `selSeatFront_` moves in exactly two functions,
    // `setPrimary` and `latchEditTarget`, and both already invalidate on the
    // line above the move — so the term could never be the reason a memo was
    // dropped, and a key term that cannot fire is a key term nobody can test.
    // -----------------------------------------------------------------------
    private Layer         primaryMemo_;
    private const(void)*  primaryMemoLayersBlock_;
    private size_t        primaryMemoLayersLength_;
    private bool          primaryMemoValid_;

    private void invalidatePrimaryMemo() nothrow @nogc {
        primaryMemoValid_ = false;
    }

    /// Mark an IN-PLACE membership/order mutation of `layers` — one that
    /// leaves the array block and its length alone, which is the only shape
    /// `primary`'s own key cannot see (see the block comment above). Every
    /// append / truncation / reconcatenation is covered without this call;
    /// the 21 existing call sites are a belt and are cheap to keep.
    void noteLayerListChanged() nothrow @nogc {
        invalidatePrimaryMemo();
    }

    /// The selection STATE of `l` — the reader every other question here is
    /// asked through. Current is searched FIRST, so an item that is both
    /// current and still listed in a bucket (an undo that restored `selected`
    /// by raw field write) reads `Current`, exactly as the reference's own
    /// lookup resolves it.
    SelState selectionState(const(Layer) l) const nothrow @nogc {
        if (l is null) return SelState.None;
        if (l.selected) return SelState.Current;
        foreach (h; deselected_[l.kind]) if (h is l) return SelState.History;
        return SelState.None;
    }

    /// Classify `l` as a layer — the port of the reference's classifier, arm
    /// for arm. Read the `canBePrimary` arm carefully: it tests the whole
    /// selection STATE against zero, not membership of the current list, and
    /// that single comparison is the latch.
    ///
    /// `canBePrimary` rather than `hasMesh` stands in for the reference's
    /// "is a mesh" test, for the reason `assertDocInvariants` already gives:
    /// every refusal in this file keys on the capability, and a future kind
    /// with geometry but barred from being the edit target must take the
    /// ordinary arm.
    LayerRole roleOf(const(Layer) l) const nothrow @nogc {
        if (l is null) return LayerRole.None;
        // Not a scene item at all (a clip lives only in its own panel), so it
        // is not a layer — not a background one either.
        if (!kindInfo(l.kind).isSceneItem) return LayerRole.None;
        immutable st = selectionState(l);
        immutable bool targetable = kindInfo(l.kind).canBePrimary && st != SelState.None;
        // Hidden: only a targetable item survives, and it survives as
        // FOREGROUND — hiding the edit target does not hand it to anyone else
        // (measured; `edit_target_legality`, cell `hidden_mesh_keeps_the_target`).
        if (!l.visible) return targetable ? LayerRole.Foreground : LayerRole.None;
        if (targetable) return LayerRole.Foreground;
        return st == SelState.Current ? LayerRole.Foreground : LayerRole.Background;
    }

    /// THE WALK (task 0671), and the only definition of it. Returns the `n`-th
    /// item of the foreground layer list, or `null` when the list is shorter
    /// than that. `primary` is `nthEditTargetCandidate(0)` and
    /// `foregroundLayersInto` is this called until it answers null, so the
    /// edit target and the list it heads cannot drift apart — they are one
    /// enumeration asked two questions.
    ///
    /// The order is: **the current selection in seat order, then the deselect
    /// history in seat order**, filtered to items that classify `Foreground`
    /// and `canBePrimary`. Two stages, and current strictly precedes history no
    /// matter how the seats compare — that is what makes a freshly selected
    /// mesh outrank a latched one rather than merely outrank it by luck.
    ///
    /// MEMBERSHIP IS THE ENUMERATION. It walks `layers`, so an item that has
    /// left the document contributes nothing however it is still referenced;
    /// see `deselected_`.
    ///
    /// Ties on `selSeat` break on `layers` order, which makes the order TOTAL
    /// even for a document mid-assembly by direct field write (several loaders
    /// and three `revert()` paths do exactly that, and a never-seated item
    /// carries seat `0`). Without the tie-break, two seat-0 selected meshes
    /// would be mutually unordered and the walk could stall on the first.
    ///
    /// O(k·n) for the k-th answer, with no allocation. `primary` memoises only
    /// the n=0 result, keyed on the layer array's own `(block, length)` pair
    /// plus explicit invalidation from every selection mutator; this walk
    /// remains the sole computation of what the target IS.
    private inout(Layer) nthEditTargetCandidate(size_t n) inout nothrow @nogc {
        { import perf_probe : g_perf, Cat; g_perf.count(Cat.editTargetDerive, 1); }
        // Task 4061 — the same event, counted a second time for the gate that
        // actually runs. See `g_editTargetDerives`' own comment for why the
        // perf counter alone could not carry the pin.
        version (unittest) { import document_selection : g_editTargetDerives;
                             ++g_editTargetDerives; }
        size_t emitted = 0;
        foreach (stage; 0 .. 2) {
            immutable want = stage == 0 ? SelState.Current : SelState.History;
            long   lastSeat  = long.min;
            size_t lastIndex = 0;
            bool   haveLast  = false;
            for (;;) {
                // `bestIndex`, not a `Layer` local: D forbids assigning to an
                // `inout`-typed variable inside an `inout` function, and this
                // one function has to serve both the mutable and the const
                // caller. Indexing `layers` at the end reintroduces the
                // caller's own constness for free.
                size_t bestIndex = layers.length;
                long   bestSeat  = 0;
                foreach (i, l; layers) {
                    if (l is null) continue;
                    if (!kindInfo(l.kind).canBePrimary) continue;
                    if (selectionState(l) != want) continue;
                    if (roleOf(l) != LayerRole.Foreground) continue;
                    // strictly after the last emitted (seat, index) key
                    if (haveLast && (l.selSeat < lastSeat
                                 || (l.selSeat == lastSeat && i <= lastIndex))) continue;
                    if (bestIndex == layers.length || l.selSeat < bestSeat
                                     || (l.selSeat == bestSeat && i < bestIndex)) {
                        bestSeat = l.selSeat; bestIndex = i;
                    }
                }
                if (bestIndex == layers.length) break;
                if (emitted == n) return layers[bestIndex];
                ++emitted;
                lastSeat = bestSeat; lastIndex = bestIndex; haveLast = true;
            }
        }
        return null;
    }

    /// The MESH EDIT TARGET — the first survivor of the walk. Component tools
    /// and commands bind `Mesh*` off this; it is always `canBePrimary` (today:
    /// always mesh-kind) and always a member of `layers`.
    ///
    /// NULL when no item with a non-zero selection state can be the edit
    /// target (task 0654, narrowed by 0668, re-derived by 0671). That includes
    /// but is NOT implied by an empty item selection: dropping the whole
    /// selection moves every item into its kind's history bucket, and a mesh
    /// there is still the target.
    ///
    /// A FUNCTION, not a field, and the difference is the point of task 0671 —
    /// see the struct's doc comment. Nothing assigns the edit target; the
    /// mutators move items between the current list and the history buckets and
    /// this recomputes.
    /// MEMOISED, AND THE MEMO WRITES THROUGH A CONST CAST. Two consequences,
    /// both stated because each one falsifies something that used to be true:
    ///
    ///   * A `const(Document)*` no longer proves the document is byte-
    ///     unchanged across a call. It still proves what the drawers actually
    ///     rely on — that no mutating COMMAND can be built over it and no
    ///     selection/list mutator can be reached — but `ui/panels.d`'s
    ///     statistics-panel header used to spell it as a no-mutation proof
    ///     and now spells the narrower claim.
    ///   * MAIN THREAD ONLY. The memo is written without synchronisation, so
    ///     two threads reading `primary` concurrently is a data race, not
    ///     merely a redundant walk. That is a constraint this accessor now
    ///     DEPENDS on rather than one it introduces: every document-touching
    ///     HTTP route already marshals onto the main thread through its own
    ///     bridge (`http_server.d`'s header states the rule and gives
    ///     `/api/layers` as the case that had to be corrected to obey it),
    ///     because a splice between two reads of `layers` already produced
    ///     wrong answers. If a reader is ever moved off the main thread, this
    ///     memo has to be moved with it.
    inout(Layer) primary() inout nothrow @nogc {
        // Logical constness: the cached class reference is not document state
        // and never decides the answer. Cast only the Document storage used by
        // the memo, then return with the receiver's original qualification.
        auto self = cast(Document*) &this;
        if (!self.primaryMemoValid_
            || self.primaryMemoLayersBlock_  !is cast(const(void)*) self.layers.ptr
            || self.primaryMemoLayersLength_ != self.layers.length) {
            self.primaryMemo_ = cast(Layer) nthEditTargetCandidate(0);
            self.primaryMemoLayersBlock_  = cast(const(void)*) self.layers.ptr;
            self.primaryMemoLayersLength_ = self.layers.length;
            self.primaryMemoValid_ = true;
        }
        return cast(inout(Layer)) self.primaryMemo_;
    }

    /// The single FILTER `foregroundLayersInto`/`foregroundLayerCount` share
    /// below (task 0770): is `l` a foreground candidate at all, independent of
    /// order. Exactly the per-stage test inside `nthEditTargetCandidate`'s
    /// inner loop, hoisted so the list and the count cannot filter
    /// differently — the drift that walk's own doc comment warns about, one
    /// level down from where it warns about it.
    private bool isForegroundCandidate(const(Layer) l) const {
        if (l is null) return false;
        if (!kindInfo(l.kind).canBePrimary) return false;
        if (selectionState(l) == SelState.None) return false;
        return roleOf(l) == LayerRole.Foreground;
    }

    /// The foreground layer list, in walk order — ONE PASS (task 0770),
    /// where this used to restart `nthEditTargetCandidate` once per rank.
    ///
    /// THE COST THAT MOVED. `nthEditTargetCandidate`'s inner loop is a
    /// selection sort: each call re-scans `layers` for the smallest
    /// (selSeat, index) key strictly after the one it returned last, so
    /// pulling n answers out of it costs O(n·L). This function used to call
    /// it once to COUNT and once more to FILL — both loops doing that same
    /// O(n·L) climb — so a document with L layers all foreground paid O(L²)
    /// twice. Measured (task 0721): 1.57 ms at 64 selected layers, and
    /// `foregroundLayerCount` alone the same shape at half the constant.
    ///
    /// THE FIX is not a smarter walk, it is the walk's own inner loop turned
    /// the right way round: that loop **is** a selection sort of the
    /// candidates by (selSeat, index) — pulling one minimum at a time is what
    /// makes it quadratic, and asking for all of them at once is an ordinary
    /// sort. So: one filtering pass over `layers` collecting every candidate
    /// with its (stage, selSeat, index) key, then one `sort` call — current
    /// stage before history stage, exactly the order `nthEditTargetCandidate`
    /// documents. `index` is already unique per layer, so `(stage, selSeat,
    /// index)` is a strict total order and the sort never has to fall through
    /// to a fourth key or worry about stability.
    ///
    /// `primary`/`nthEditTargetCandidate` are UNTOUCHED, deliberately. That
    /// walk costs O(L) per call and is asked for ~103 times a frame at a
    /// fraction of a microsecond even at 256 layers (0721 measured 7.8 ns –
    /// 617 ns) — there is no quadratic there to fix, and giving it a second
    /// implementation of the same order here would only risk the two
    /// drifting apart for a win nothing measures.
    void foregroundLayersInto(ref Layer[] outBuf) {
        import std.algorithm : sort;
        static struct Cand { int stage; long seat; size_t idx; }
        Cand[] cands;
        cands.reserve(layers.length);
        foreach (i, l; layers)
            if (isForegroundCandidate(l))
                cands ~= Cand(selectionState(l) == SelState.Current ? 0 : 1, l.selSeat, i);
        sort!((a, b) => a.stage != b.stage ? a.stage < b.stage
                       : a.seat  != b.seat  ? a.seat  < b.seat
                       :                      a.idx   < b.idx)(cands);
        if (outBuf.length != cands.length) outBuf.length = cands.length;
        foreach (i, c; cands) outBuf[i] = layers[c.idx];
    }

    /// How many layers are foreground — the count the frozen fixture reads.
    /// ONE PASS (task 0770): the same filter as `foregroundLayersInto` above,
    /// with no order to compute, so no sort is needed either — this one was
    /// always answerable in O(L) and only inherited the quadratic cost by
    /// sharing the restart-per-rank walk.
    size_t foregroundLayerCount() const {
        size_t n = 0;
        foreach (l; layers) if (isForegroundCandidate(l)) ++n;
        return n;
    }

    /// The index of the active (foreground) layer — DERIVED (Stage 2b) from the
    /// `primary` object's position in `layers`. Read-only: there is no stored
    /// field and no assignment LHS; every former writer routes through
    /// `setActive` / `selectItem` / `setPrimary` (which move `primary`). Because
    /// it follows the primary by IDENTITY, reorder/delete renumbering can never
    /// drift it.
    ///
    /// ABSENT-SENTINEL IS `layers.length`, NOT `0` (task 0654 CHANGED this).
    /// It used to answer `0` when `primary` was not found, which was defensible
    /// only while "not found" was unreachable. Now that an empty selection is
    /// legal, `0` would be the single most damaging answer in the file: it
    /// names a REAL layer, so `resolveIndex(-1)` would silently edit
    /// `layers[0]`, `/api/layers` would mark it active and `.v3d` would save it
    /// as the primary — the exact "silently substitutes layer 0" failure this
    /// task exists to exclude. `layers.length` is out of range for every
    /// consumer, so a consumer that forgot to ask `hasEditTarget()` gets a
    /// bounds error rather than someone else's geometry.
    ///
    /// This makes the sentinel agree with `indexOf`'s, which the NIT below used
    /// to warn were different. They are the same scan and now the same sentinel.
    size_t activeIndex() const {
        auto p = primary;                       // task 0671: one walk, not one per layer
        if (p is null) return layers.length;
        foreach (i, l; layers) if (l is p) return i;
        return layers.length;
    }

    /// Is there a mesh edit target at all? (task 0654) The question every
    /// consumer of `activeMesh` / `activeMeshRef` / `activeIndex` has to ask
    /// first, and the non-throwing way to ask it. `false` when the item
    /// selection is empty AND (task 0668) when everything selected is of a
    /// kind that cannot be primary — e.g. a reference plane selected alone.
    /// Do NOT infer "nothing is selected" from a `false` here; ask
    /// `selectedItemCount`.
    bool hasEditTarget() const { return primary !is null; }

    /// How many items are selected. `0` is legal (task 0654).
    size_t selectedItemCount() const {
        size_t n = 0;
        foreach (l; layers) if (l !is null && l.selected) ++n;
        return n;
    }

    /// The active (foreground) layer object — i.e. the primary. NULL when the
    /// item selection is empty (task 0654).
    Layer     active()        { return primary; }

    /// Pointer to the primary layer's mesh (interior pointer, GC-traced), or
    /// **null when there is no edit target** (task 0654).
    ///
    /// This is the BINDING accessor: commands and tools capture the `Mesh*` at
    /// fire/arm time, and null is the one value a pointer can carry that no
    /// caller can mistake for a layer. A caller that binds it unchecked and
    /// writes through it faults immediately instead of editing a layer the user
    /// did not select.
    Mesh*     activeMesh() {
        auto p = primary;
        if (p is null) return null;
        return usesPreparedLifecycleRead(p) ? &p.enlistedShadow() : &p.meshRef();
    }

    /// Reference to the primary layer's mesh. **Throws `NoEditTargetException`
    /// when the item selection is empty** (task 0654).
    ///
    /// A `ref` return has no null, so "there is no answer" cannot be encoded in
    /// the value — the refusal has to be the control flow. Throwing is the
    /// DEFINED refusal the empty state demands: loud, named, and impossible to
    /// mistake for a layer. Callers on a path that must not throw (the frame
    /// draw, the per-frame caches) ask `hasEditTarget()` first and use
    /// `noEditTargetMesh()`; callers that genuinely require a target let it
    /// propagate.
    ref Mesh  activeMeshRef() {
        // ONE walk, not two (task 1760). `primary` is a DERIVED accessor —
        // `nthEditTargetCandidate(0)`, a scan of `layers` — so naming it twice
        // in four lines runs it twice. Measured before this change: 1 213 372
        // derivations in a single measured drag window of 20 kernel applies,
        // against a design comment that budgets "~100 times a frame". Three of
        // those walks were one `mesh()` call: one here for the null test, one
        // here for the dereference, one in the caller's `hasEditTarget()`.
        //
        // Hoisting is EXACTLY equivalent, not merely close: the walk is a pure
        // read of `layers` with no side effect and nothing between these two
        // statements can mutate the document.
        //
        // The reason is the shared enum, not a third copy of the sentence
        // (task 0668): the module already goes to the trouble of a
        // `static assert` to keep `command.d`'s duplicate byte-identical, and
        // a literal here was a silent way for the throw to say something else.
        auto p = primary;
        if (p is null) throw new NoEditTargetException(kNoEditTargetReason);
        return usesPreparedLifecycleRead(p) ? p.enlistedShadow() : p.meshRef();
    }

    /// True iff `l` is the primary (the single edit target).
    bool isPrimary(const(Layer) l) const { return l is primary; }

    /// True iff `l` holds the item-selection focus. Distinct from `isPrimary`
    /// only once a non-mesh item is selected (task 0615, §Q2) — on an
    /// all-mesh document `focusedItem is primary` always, so the two agree.
    bool isFocused(const(Layer) l) const { return l is focusedItem; }

    /// The FIRST element of the current item selection — lowest `selSeat`,
    /// ties on `layers` order. Null when nothing is selected.
    ///
    /// The OTHER END of the queue from `focusedItem`, which is the newest
    /// touch, and a DIFFERENT question from `primary`, which is the head of a
    /// walk that filters on `canBePrimary` and continues into the deselect
    /// history. Three distinct answers, and they part company on the ordinary
    /// two-item selection: `set plane; add mesh` puts the plane first, the mesh
    /// in focus, and the mesh — not the plane — is the edit target.
    ///
    /// NO KIND FILTER, deliberately. This is a fact about the selection LIST,
    /// so an item that can never be an edit target heads it whenever it was
    /// selected first (task 0672 measured exactly that row: the first-selected
    /// item takes the distinguishing treatment even when it is a kind that
    /// cannot be a mesh edit target at all).
    ///
    /// No visibility filter either: hiding an item does not remove it from the
    /// selection, and `visible` is its own cell in every surface that draws
    /// this.
    inout(Layer) firstSelectedItem() inout {
        // `bestIndex` rather than a `Layer` local for the reason
        // `nthEditTargetCandidate` gives: D forbids assigning to an
        // `inout`-typed variable inside an `inout` function, and indexing
        // `layers` at the end reintroduces the caller's own constness for free.
        size_t bestIndex = layers.length;
        long   bestSeat  = 0;
        foreach (i, l; layers) {
            if (l is null || !l.selected) continue;
            if (bestIndex == layers.length || l.selSeat < bestSeat) {
                bestSeat = l.selSeat; bestIndex = i;
            }
        }
        return bestIndex == layers.length ? null : layers[bestIndex];
    }

    /// True iff `l` is the first element of the current item selection.
    bool isFirstSelected(const(Layer) l) const {
        return l !is null && l.selected && l is firstSelectedItem;
    }

    /// The item-transform MOVING SET — every SELECTED item, in `layers`
    /// order. Task 0614 Phase 6, law L2 (`doc/tasks/0614-evidence/
    /// phase0_findings.md` case B): a transform gesture in Item mode moves
    /// the WHOLE selected set, not only the primary. This is the one place
    /// that answers "which items does the gizmo act on"; the transform tool
    /// resolves all three of its target lists (run baseline, headless
    /// one-shot baseline, undo session) through it so they cannot drift.
    ///
    /// Deliberately NOT `visible`-filtered. `foreground(l)` is
    /// `visible && selected`, and a hidden-but-selected layer is a
    /// representable state (`layer.setVisible` on a non-primary selected
    /// layer). Dropping it from the moving set would silently desync the
    /// undo payload from the selection the user sees in the layer list, and
    /// re-showing the layer would reveal it stranded at a stale pose. The
    /// primary is always visible (document invariant), so the shared action
    /// centre is unaffected either way.
    ///
    /// Fills `outBuf` IN PLACE (its `length` is the count) rather than
    /// returning a fresh array: the caller keeps long-lived buffers and
    /// re-resolves once per run / per session, so an allocating accessor
    /// would churn an array per gesture for nothing — and a `Document`-owned
    /// scratch buffer could not be shared by two callers without aliasing.
    ///
    /// `layers` order is DETERMINISTIC and stable, which
    /// `LayerXformEdit.mergeRunTail`'s first-touch union relies on for a
    /// reproducible multi-target undo payload.
    ///
    /// ~~`kindInfo(l.kind).hasXform` is deliberately NOT consulted: the
    /// `static assert` over `kItemKindTable` (above) proves every declared
    /// kind participates in the item transform, so a filter here would be a
    /// branch that can never be false. This is a site to gate when a
    /// `hasXform == false` kind first lands — alongside `layer_params.d`,
    /// per that assertion's own message.~~
    ///
    /// GATED (task 0612 Stage 2). That premise stopped being true when
    /// `ItemKind.Image` landed with `hasXform == false` — and image clips are
    /// selectable, so until this line existed, selecting a clip row and
    /// dragging wrote an `ItemXform` onto an item whose own kind declares it
    /// has none. The blanket `hasXform` assertion the paragraph above cites
    /// was RETIRED by that same task; this is the gate it told its successor
    /// to add, arriving one kind late. `layer_params.d`'s provider was gated
    /// at the time; this half was missed because nothing dragged an item yet.
    ///
    /// The gate is the CAPABILITY, never a kind check: the reference-image
    /// plane is `hasXform == true` and is therefore fully in the moving set,
    /// which is the entire point of the item being placed with the ordinary
    /// transform tools.
    void selectedItemsInto(ref Layer[] outBuf) {
        size_t n = 0;
        foreach (l; layers) if (movesWithGizmo(l)) ++n;
        if (outBuf.length != n) outBuf.length = n;
        size_t i = 0;
        foreach (l; layers) if (movesWithGizmo(l)) outBuf[i++] = l;
    }

    /// The capability predicate `selectedItemsInto` and `itemTransformTargets`
    /// share: a selected item whose KIND declares an `ItemXform`. Hoisted out
    /// of `selectedItemsInto`'s body (where it was a local `static`) so the
    /// narrowed set below cannot drift from the wide one — the two differ by
    /// exactly one term, and that term is visible in one place.
    static bool movesWithGizmo(const(Layer) l) {
        return l !is null && l.selected && kindInfo(l.kind).hasXform;
    }

    /// The single ITEM-TRANSFORM TARGET — the item the gizmo centres on, the
    /// item the properties form binds, and the item the moving set is narrowed
    /// around. Task 0612 Stage 8 (§7.1).
    ///
    /// One rule in one place. Before this existed there were two: the
    /// properties form followed `focusedItem` (`layer_params.d`'s
    /// `itemPropsTarget`, task 0616 Ph4) while `ActionCenterStage` and
    /// `AxisStage` were wired straight to `document.primary` — so selecting a
    /// mesh-less item put the gizmo on the MESH's pivot while the panel showed
    /// the plane's numbers. `itemPropsTarget` now delegates here; so do
    /// `actcenter.d`'s and `axis.d`'s `primarySrc_` bindings in `app.d`.
    ///
    /// NEUTRAL ON AN ALL-MESH DOCUMENT, as a proof and not a hope: every
    /// mesh-kind selection route leaves `focusedItem is primary` —
    /// `exclusiveSelect` sets both when the target `canBePrimary`,
    /// `selectItem`'s Add arm sets both, `setPrimary` sets both. The two can
    /// disagree only once a `canBePrimary == false` kind is selected, which is
    /// a state that did not exist when the gizmo-centre law (L2) was measured.
    ///
    /// `isMember` rather than a null check: `focusedItem` can go STALE
    /// (non-null, no longer in `layers`) while a loader replaces `layers` by
    /// direct field assignment — see `isMember`'s own comment.
    /// NOT `const`: it hands back a MUTABLE `Layer` (the caller writes
    /// `xform` through it), and a `const` overload would have to cast the
    /// constness off its own fields to do that — a hole, not a convenience.
    /// Every consumer already holds a mutable `Document`.
    Layer itemTransformTarget() {
        return isMember(focusedItem) ? focusedItem : primary;
    }

    /// The item-transform MOVING SET, task 0612 Stage 8 — `selectedItemsInto`
    /// narrowed by approximation **D** (plan §7.2).
    ///
    /// D in one line: **drop `primary` from the set when it is not the
    /// transform target.** Everything else about the set is unchanged.
    ///
    /// WHY THERE IS ANYTHING TO DROP — RESTATED FOR TASK 0668. This used to
    /// read: `Document` forces its mesh edit target to stay selected
    /// (`exclusiveSelect` leaves the selected set `{target} ∪ {primary-after}`),
    /// so selecting a mesh-less item alone is not representable, the set is
    /// `{plane, mesh}`, and an ungated moving set drags the model along with
    /// the reference image. **That forcing is gone from the exclusive path.**
    /// 0668 spent 0654's absent-primary allowance: an exclusive select of a
    /// kind that cannot be primary now leaves `{plane}` and no edit target, so
    /// the common case — clicking a plane — needs no approximation at all.
    ///
    /// D SURVIVES FOR THE OTHER ORDER, which 0668 deliberately left alone:
    /// select a mesh, then ctrl-ADD a plane. Now the mesh is in the selection
    /// because the USER put it there, the focus is on the plane, and an
    /// ungated set would still drag the model. Subtracting the primary is the
    /// same answer as before; only the reason it can be reached narrowed from
    /// "always" to "on a deliberate multi-select".
    ///
    /// THE ONE DECLARED DIVERGENCE, and it is asserted, not merely written
    /// down: select a mesh, then ctrl-ADD a plane, and the mesh stops moving
    /// (the reference moves both). It UNDER-moves, which one ctrl-click on the
    /// mesh recovers; the alternative available without model M over-moves,
    /// silently writing an `ItemXform` onto the character on the COMMON path.
    /// Wrong on the rare path beats wrong on the common one. `tests/
    /// test_item_transform_focus.d`'s T-X6 pins it so model M's task flips it
    /// deliberately rather than discovering it.
    ///
    /// THE CENTRE AND THE SET COME FROM THE SAME FUNNEL. `ActionCenterStage`
    /// keeps its own single-item source (the shared centre follows the target,
    /// not the set midpoint — L2, measured), and both now read
    /// `itemTransformTarget()`. Narrowing the set without moving the centre
    /// would leave the gizmo sitting on a layer it refuses to move.
    /// TASK 0671 — THE NARROWING CONDITION HAD TO MOVE, and it is a
    /// correction, not a follow-on cost.
    ///
    /// It read `target !is primary`. That was a faithful spelling of "the
    /// focus is on something the edit target is not" only while the two
    /// pointers moved in LOCKSTEP on an all-mesh document — which they did,
    /// because `Add` promoted the newest mesh to primary. `Add` does not
    /// promote any more (the target is the selection queue's head), so on the
    /// ordinary multi-mesh drag — select A, ctrl-add B — the focus is B and
    /// the target is A, and the old condition would have SUBTRACTED A from the
    /// moving set: half the user's selection silently stops moving.
    ///
    /// The condition D actually wants is the one its own doc comment states in
    /// prose: the focus is on an item that cannot be the edit target at all (a
    /// plane, a clip). Spelled that way it is exactly equivalent to the old
    /// formula on every state the old formula could reach, and it stops being
    /// wrong on the state this task adds.
    void itemTransformTargets(ref Layer[] outBuf) {
        auto target = itemTransformTarget();
        auto prim   = primary;
        immutable bool narrowed =
            target !is null && !kindInfo(target.kind).canBePrimary;
        bool keep(const(Layer) l) {
            return movesWithGizmo(l) && !(narrowed && l is prim);
        }
        size_t n = 0;
        foreach (l; layers) if (keep(l)) ++n;
        if (outBuf.length != n) outBuf.length = n;
        size_t i = 0;
        foreach (l; layers) if (keep(l)) outBuf[i++] = l;
    }

    /// Is `l` in the moving set? The derived per-layer bool `/api/layers`
    /// reports as `transformTarget` (§7.2 consequence 2: the Layers panel will
    /// highlight a layer that does not move, and the fix is to make that
    /// observable rather than to hide it). No stored state — this is
    /// `itemTransformTargets` membership, spelled without the buffer.
    bool isTransformTarget(const(Layer) l) {
        if (!movesWithGizmo(l)) return false;
        // Task 0671: the SAME condition as `itemTransformTargets`, restated
        // here for the same reason it was restated before — these two must not
        // drift, and a unittest below asserts they agree row for row.
        auto target = itemTransformTarget();
        immutable bool narrowed =
            target !is null && !kindInfo(target.kind).canBePrimary;
        return !(narrowed && l is primary);
    }

    /// Foreground / background DERIVATION (Stage 2b: the SOLE source of truth;
    /// task 0671: re-expressed over the selection STATE).
    ///
    /// ~~`foreground(l) == l.visible &&  l.selected`,
    /// `background(l) == l.visible && !l.selected`.~~ — `static`, and keyed on
    /// the current-list bool alone. That reading is what made a latched target
    /// draw as background, which is the objection the struct's doc comment
    /// records 0668 raising and 0671 answering: the answer needs the document,
    /// because it needs the deselect history, so these are INSTANCE methods now.
    ///
    /// Both are one arm of `roleOf` each, so there is one classifier and not
    /// three. ACTUAL readers (comment corrected, task 0678 D4 — the previous
    /// claim "both draw guards" was false and had been for a while): the snap
    /// source gate (`ui/panels.d` snapSrc loop) and `/api/layers` +
    /// `/api/selection` (`http_providers.d`). The background DRAW pass and its
    /// GPU-eviction twin deliberately test `visible && !isPrimary` instead:
    /// a Foreground-role non-primary layer (ctrl-added in Items) is drawn by
    /// NEITHER pass under `background()` — the foreground pass renders only
    /// the primary — and task 0654's rule is "dim, not disappear". Unifying
    /// the draw guards onto roleOf therefore requires first deciding how the
    /// foreground pass renders non-primary Foreground layers (backlog
    /// 0642/0672 territory), not a mechanical sweep. Until then: snap and the
    /// HTTP report follow roleOf; the draw dims everything visible that is
    /// not the edit target.
    /// `const` + `const(Layer)` so the read-only consumers (the `ref const
    /// Document` writers) can still call them.
    ///
    /// The only behaviour that moves for a document with no history is
    /// `foreground` of a HIDDEN selected mesh: false before, true now — the
    /// measured hidden-mesh law. Nothing draws off `foreground` (the draw
    /// guards test `background` and `visible`), so this changes what is
    /// REPORTED, not what is rendered.
    bool foreground(const(Layer) l) const { return roleOf(l) == LayerRole.Foreground; }
    bool background(const(Layer) l) const { return roleOf(l) == LayerRole.Background; }

    /// Set the active layer by index — routes through `exclusiveSelect` (task
    /// 0615, §L2), which keeps today's exact SET-of-one behaviour when `idx`
    /// names a mesh-kind layer, and otherwise SPARES the mesh primary from
    /// the exclusive deselect (a non-mesh target becomes `focusedItem` only).
    /// `activeIndex` follows `primary` by derivation (Stage 2b) — no index to
    /// write here. Callers MUST invoke this BEFORE any `fireSwitchIfChanged` /
    /// switch-hook call so the hook (which reads `activeMesh()` == primary's
    /// mesh) re-uploads the correct mesh — see the Stage-0 ordering rule.
    ///
    /// NIT (review round 2): this can be a TOTAL no-op. `exclusiveSelect`
    /// refuses silently when `target` is not a member — a state the ≥1-mesh
    /// invariant forbids on a well-formed `Document`, but callers must not
    /// assume `setActive` always changes something (e.g. mid-assembly of a
    /// `Document` via direct field writes, before its first
    /// invariant-restoring call).
    void setActive(size_t idx) {
        invalidatePrimaryMemo();
        // Task 0671: nothing to null out on an empty document — the edit
        // target is derived, and a walk over no layers already answers null.
        if (layers.length == 0) { focusedItem = null; return; }
        if (idx >= layers.length) idx = layers.length - 1;
        exclusiveSelect(layers[idx]);
    }

    /// L2 (task 0615): the single implementation of exclusive select.
    /// Computes `primary-after` FIRST, then leaves the selected set exactly
    /// `{target} ∪ {primary-after}`. On an all-mesh document `primary-after
    /// is target`, so this reduces — bit for bit — to "deselect everyone,
    /// select target, target becomes primary": today's exact behaviour, which
    /// is what keeps the existing suite green as the neutrality proof.
    ///
    /// TASK 0668 — WHEN `target` CANNOT BE PRIMARY, `primary-after` IS NULL.
    /// It used to be the CURRENT primary, so an exclusive select of a
    /// `canBePrimary == false` kind left the previous edit target standing and
    /// SELECTED: `{plane, mesh}`, not `{plane}`. That was not a preference,
    /// it was the only representable answer — the pre-0654 invariants demanded
    /// a non-null, selected, visible primary, so there was nothing to demote
    /// the mesh TO. [[0654]] made an absent primary legal, and this is the
    /// first mutator to spend that: an exclusive select is exclusive for every
    /// kind, and a document whose only selected item cannot be the edit target
    /// simply has no edit target.
    ///
    /// The property is the KIND TABLE's `canBePrimary`, not the image plane —
    /// clips (`ItemKind.Image`) take the same branch, and so will any future
    /// kind that declares it.
    ///
    /// What the caller must then expect, all of it defined by [[0654]]:
    /// `hasEditTarget()` false, `activeMesh()` null, `activeMeshRef()`
    /// throwing, `activeIndex()` at the absent-sentinel, every Operator
    /// command refusing with `kNoEditTargetReason`, and the former primary
    /// drawn as BACKGROUND (`visible && !selected`) — dimmed and read-only,
    /// which is exactly what "it is no longer the edit target" should look
    /// like. The scene does not go dark: the background pass runs whenever
    /// `!hasEditTarget()`.
    private void exclusiveSelect(Layer target) {
        // L1: never focus (or select) a layer that is not a member. This was
        // previously implied by the `rehomePrimary` fallback below, which
        // could only repair `primary` — `target` itself was installed as
        // `focusedItem` unchecked. Every production caller (`selectItem`,
        // `setActive`) already guards membership, so this is a restatement at
        // the one place that assigns the pointer, not a new refusal.
        if (!isMember(target)) return;
        // TASK 0671 — the whole body is now two list operations and a focus.
        // There is no `primaryAfter` to compute, because there is nothing to
        // assign it to: the edit target is derived. What used to be the entire
        // difficulty of this function — deciding whether to spare the previous
        // primary (pre-0668) or drop it (0668) — is not a decision any more.
        // Deselecting every other item moves them into THEIR OWN kind buckets,
        // and selecting `target` flushes only `target`'s. A mesh therefore
        // survives an exclusive select of a plane and does not survive an
        // exclusive select of another mesh, without either outcome being
        // written down here.
        foreach (l; layers) if (l !is target) noteDeselected(l);
        noteSelected(target);
        focusedItem = target;
    }

    /// PRIMITIVE 1 (task 0671) — `l` joins the CURRENT item selection.
    ///
    /// Two effects, and the second is the one that matters: the item takes the
    /// back seat of the current queue, and **its kind's history bucket is
    /// flushed**. The flush is per (selection type, subtype) in the reference
    /// and the subtype of an item packet is the item's type, so this is the
    /// per-kind flush spelled out — selecting a mesh forgets the previously
    /// latched mesh, selecting a plane does not.
    ///
    /// An item already in the current list keeps its seat. Re-selecting must
    /// not reorder the queue: with two meshes selected, clicking the second one
    /// again would otherwise hand it the edit target, which is neither measured
    /// nor sensible.
    private void noteSelected(Layer l) {
        if (l is null) return;
        deselected_[l.kind].length = 0;
        if (l.selected) return;
        l.selected = true;
        l.selSeat  = ++selSeatBack_;
    }

    /// PRIMITIVE 2 (task 0671) — `l` leaves the current item selection and
    /// enters its own kind's history bucket. Deselecting is not "clearing a
    /// bool"; it is a MOVE between two lists, and the second list is what the
    /// edit target survives on.
    ///
    /// The seat is deliberately left alone (see `Layer.selSeat`): the history
    /// bucket is ordered by the same number the current list is, so a batch
    /// that deselects several meshes at once leaves them in the order they were
    /// selected — and the walk's head is then the earliest, matching the
    /// current list's own head rule.
    private void noteDeselected(Layer l) {
        if (l is null || !l.selected) return;
        l.selected = false;
        foreach (h; deselected_[l.kind]) if (h is l) return;   // already listed
        deselected_[l.kind] ~= l;
    }

    // -----------------------------------------------------------------------
    // Stage 2a/2b multi-select mutators. They maintain the load-bearing
    // invariant contract (≥1 selected; primary selected+visible; hide-primary
    // promotes). `activeIndex` derives from `primary`, so no index bookkeeping
    // is needed and no stored `background` bool is touched (Stage 2b deleted it).
    // -----------------------------------------------------------------------

    /// The most-recent remaining selected+visible+`canBePrimary` layer OTHER
    /// than `exclude`, or null if none. v1 has no per-pick order counter
    /// (declared divergence B9), so "most recent" is approximated by scanning
    /// the list — adequate for the single-primary edit model. Used by
    /// hide-primary / remove-primary promotion — BOTH callers assign the
    /// result straight to `primary`, so the candidate must be `canBePrimary`
    /// (task 0615, renamed from `anotherSelectedVisible`).
    private Layer anotherPrimaryCandidate(Layer exclude) {
        foreach (l; layers)
            if (l !is exclude && l.selected && l.visible && kindInfo(l.kind).canBePrimary)
                return l;
        return null;
    }

    /// The single item-select mutator. Mirrors `mode:{set,add,remove,toggle}`.
    /// Invariants held on return (as of tasks 0654 + 0668 — the "always
    /// non-null" clauses this listed before those are gone, see the struct's
    /// own doc comment for the model): when `primary !is null` it is a member,
    /// selected and `canBePrimary`; when `focusedItem !is null` it is a member
    /// and selected; `focusedItem is null` exactly when nothing is selected;
    /// `primary is null` exactly when nothing SELECTED is `canBePrimary`.
    /// `background` is fully derived (Stage 2b) — there is no stored bool to
    /// keep in sync. Task 0615 (§L2): `primary` moves to `l` only when `l`
    /// `canBePrimary`; task 0668: an EXCLUSIVE (`Set`) select of a kind that
    /// cannot be primary now drops the previous edit target instead of sparing
    /// it — `Add` still spares it, because adding to a selection is not a
    /// claim about what the edit target should be.
    void selectItem(Layer l, SelMode mode) {
        // S5 / L1: guard membership, not just null — a `Layer` that is not
        // (or no longer) in `layers` must never become target/focus/primary.
        if (layers.length == 0 || l is null || indexOf(l) == layers.length) return;
        invalidatePrimaryMemo();

        final switch (mode) {
            case SelMode.Set:
                exclusiveSelect(l);
                break;

            case SelMode.Add:
                // TASK 0671 — `add` no longer PROMOTES. It used to end with
                // `primary = l`, which is the newest member taking the edit
                // target; measured, the target is the queue's HEAD, so with
                // `set B; add A` it stays on B, the earlier one. Nothing here
                // says so: `noteSelected` seats A at the back and the walk
                // reads the front. (`tests/fixtures/edit_target_legality.json`,
                // cell `flush_is_per_item_kind` step 3, is the row.)
                //
                // The `recoverStalePrimary()` arm that used to guard the
                // non-mesh case is gone with the field it repaired — a derived
                // target cannot be stale.
                noteSelected(l);
                focusedItem = l;                        // newest touch is focus
                break;

            case SelMode.Remove:
                if (!l.selected) break;       // not selected → nothing to do
                // TASK 0671 — one arm, not two. The old body branched on
                // `l is primary` and hand-promoted a successor, because the
                // target was a field that would otherwise have been left
                // naming a deselected layer. Removing an item now MOVES it to
                // its kind's history bucket, and the walk answers what the
                // target became — including "the item just removed", which is
                // the latch and is correct: ctrl-clicking the last selected
                // mesh empties the selection and keeps editing that mesh.
                noteDeselected(l);
                if (focusedItem is l) {
                    // The focus is the CURRENT list's pointer, so its fallback
                    // must be a current item or null — never the latched
                    // target, which may not be selected at all any more.
                    // Prefer the edit target when it is still current (that is
                    // what this arm has always done on the common path), else
                    // the newest remaining current item.
                    auto p = primary;
                    focusedItem = (p !is null && p.selected) ? p : newestCurrentItem();
                }
                break;

            case SelMode.Toggle:
                if (l.selected) selectItem(l, SelMode.Remove);
                else            selectItem(l, SelMode.Add);
                return;
        }
        // primary remains the mesh edit target; activeIndex derives from it.
    }

    /// Empty the item selection (task 0654) — the mutator behind
    /// `layer.select mode:clear` and the viewport miss in Items mode.
    ///
    /// Deselects EVERY layer and drops `primary` + `focusedItem` to null
    /// together, which is the only shape the biconditional allows. Idempotent:
    /// clearing an already-empty selection is a no-op, not an error.
    ///
    /// Deliberately NOT expressed as "Remove every selected layer in turn":
    /// that would run the promotion arm once per layer, moving the primary
    /// through a chain of intermediate layers before landing on null, and each
    /// hop fires the caller's switch hook (GPU re-upload, tool drop, cache
    /// invalidation). One transition, not N.
    /// TASK 0671 — AND IT DOES NOT DROP THE EDIT TARGET. Dropping the whole
    /// item selection deselects, and deselecting is a MOVE into the history
    /// buckets, not an erasure: every mesh that was selected is still
    /// non-zero, so the walk still has a head. Measured — `tests/fixtures/
    /// edit_target_legality.json`, cell `target_set_nothing_selected`: "an
    /// empty item selection with a live edit target is a legal state".
    ///
    /// That is the reversal task 0654 could not see. 0654 measured that the
    /// SELECTION empties (a viewport miss in item mode, removing the last
    /// selected item) and inferred the target went with it, because in our
    /// model of the time there was nowhere else for the target to live. There
    /// is now.
    void clearItemSelection() {
        invalidatePrimaryMemo();
        foreach (l; layers) noteDeselected(l);
        focusedItem = null;
    }

    // -----------------------------------------------------------------------
    // Task 0671 — SNAPSHOT / RESTORE of the whole item-selection state.
    //
    // WHY IT HAS TO BE THE WHOLE STATE. Five `revert()` paths snapshot the
    // selection as a per-layer bool map plus the edit target, restore the bools
    // by raw field write and re-install the target through `setPrimary`. That
    // was complete while `selected` was the whole story. It is not any more:
    // the deselect history is document state too, and a revert that put back
    // the bools alone would leave whatever the APPLY deselected sitting in a
    // bucket — an unselected mesh reading foreground, and the next deselect
    // resolving to an item from a command that has been undone.
    //
    // 0670 lists the history cache's behaviour under undo as one of the things
    // it did NOT settle. This does not invent an answer to that: it makes undo
    // EXACT, which is the one policy that needs no measurement — whatever the
    // state was, it is what comes back.
    // -----------------------------------------------------------------------

    /// An exact, opaque capture of the item-selection state: both lists, their
    /// order, and the focus. Keyed by layer OBJECT identity throughout, so a
    /// splice or a reorder between capture and restore cannot drift it (the
    /// reason every one of these snapshots was identity-keyed already).
    ///
    /// Deliberately NOT a `bool[Layer]` plus an edit target. The target is
    /// derived — capturing it would capture a CONSEQUENCE and then restore it
    /// as if it were a cause, which is the stored-pointer model creeping back
    /// in through the undo stack.
    static struct ItemSelectionState {
        private Layer[]   current;      ///< selected, in `layers` order
        private long[]    currentSeats; ///< parallel to `current`
        private Layer[][ItemKind.max + 1] history;
        /// Seats for the history entries, parallel to `history`. Recorded
        /// separately from the current ones because a seat is not a property
        /// of either LIST — it lives on the `Layer`, so an item that leaves the
        /// current list and rejoins it (a `setPrimary` between capture and
        /// restore is enough) carries a seat the capture never saw. Without
        /// this the restore would put the right items in the right lists in the
        /// wrong ORDER, which is the one way a "restore" can be silently
        /// partial: every membership assertion passes and the edit target is
        /// somebody else.
        private long[][ItemKind.max + 1]  historySeats;
        private Layer     focus;
        private long      seatBack;
        private long      seatFront;
    }

    /// Capture the current item-selection state.
    ItemSelectionState captureItemSelection() {
        ItemSelectionState s;
        foreach (l; layers) if (l !is null && l.selected) {
            s.current      ~= l;
            s.currentSeats ~= l.selSeat;
        }
        foreach (k; 0 .. ItemKind.max + 1) {
            s.history[k] = deselected_[k].dup;
            foreach (h; deselected_[k]) s.historySeats[k] ~= h.selSeat;
        }
        s.focus     = focusedItem;
        s.seatBack  = selSeatBack_;
        s.seatFront = selSeatFront_;
        return s;
    }

    /// Drop the WHOLE item-selection state: both lists, the focus, the seat
    /// allocators. For a WHOLESALE document replacement — a file load, a scene
    /// reset — where the old state names items that are not in this document
    /// at all (task 0671).
    ///
    /// Distinct from `clearItemSelection`, and the difference is the point:
    /// clearing the selection is a user OPERATION and it MOVES the selected
    /// items into their history buckets (which is why the edit target survives
    /// it). This throws the buckets away too. Calling `clearItemSelection` on
    /// a replaced document would be harmless only by accident — the walk
    /// filters by membership — but it would leave the previous document's
    /// items reachable from the new one's state, and that is the sort of
    /// accident that stops being harmless the first time something iterates
    /// the buckets for another reason.
    void resetSelectionState() {
        invalidatePrimaryMemo();
        foreach (l; layers) if (l !is null) l.selected = false;
        foreach (k; 0 .. ItemKind.max + 1) deselected_[k] = null;
        focusedItem   = null;
        selSeatBack_  = 0;
        selSeatFront_ = 0;
    }

    /// Put back exactly what `captureItemSelection` recorded.
    ///
    /// MEMBERSHIP IS RE-CHECKED, not assumed: a snapshot may name a layer that
    /// the very mutation being reverted removed and that the revert has not
    /// reinserted (or never will). A non-member is dropped from the current
    /// list — it could not be `selected` on a document it is not in — while the
    /// history buckets are restored verbatim, because the walk already filters
    /// them by membership and keeping the entry is what lets a later reinsert
    /// of the SAME object become live again by identity.
    void restoreItemSelection(ItemSelectionState s) {
        invalidatePrimaryMemo();
        foreach (l; layers) if (l !is null) l.selected = false;
        foreach (i, l; s.current) {
            if (!isMember(l)) continue;
            l.selected = true;
            l.selSeat  = s.currentSeats[i];
        }
        foreach (k; 0 .. ItemKind.max + 1) {
            deselected_[k] = s.history[k].dup;
            foreach (i, h; s.history[k])
                if (h !is null && !h.selected) h.selSeat = s.historySeats[k][i];
        }
        focusedItem   = isMember(s.focus) && s.focus.selected ? s.focus : null;
        selSeatBack_  = s.seatBack;
        selSeatFront_ = s.seatFront;
    }

    /// The newest item of the CURRENT selection — highest seat, ties on
    /// `layers` order. The focus fallback; null when nothing is current.
    private Layer newestCurrentItem() {
        Layer best = null;
        foreach (l; layers) {
            if (l is null || !l.selected) continue;
            if (best is null || l.selSeat >= best.selSeat) best = l;
        }
        return best;
    }

    /// Seat `l` at the FRONT of the current selection, making it the edit
    /// target without changing WHO is selected. Selects `l` first when it is
    /// not already current (Add semantics), so the `focusedItem.selected`
    /// invariant holds. Not exclusive today and must not become so.
    ///
    /// TASK 0671 — THIS IS THE ONE OPERATION THE REFERENCE HAS NO COMMAND FOR,
    /// and it is stated as an ordering operation for exactly that reason. The
    /// reference moves the edit target only by SELECTING a mesh; there is no
    /// "make this the target" verb, so a faithful port has nothing to copy
    /// here. What it does have is a queue whose head is the target, and this is
    /// the only well-defined way to put a given item at that head — hence
    /// `--selSeatFront_` rather than a write to a target pointer, which is the
    /// shortcut this task exists to not take.
    ///
    /// Its callers are all RESTORES (three `revert()` paths, the `.v3d`
    /// loader, scene reset), where `l` was the target in the state being
    /// restored — so "put it back at the head" is exactly the requested
    /// operation and no policy is being invented for it.
    ///
    /// A `canBePrimary == false` `l` cannot head the walk (the walk filters on
    /// the capability), so this reduces to selecting it and focusing it, with
    /// no separate arm needed — the filter is the arm.
    void setPrimary(Layer l) {
        // S5 / L1: same membership guard as `selectItem` — see there.
        if (layers.length == 0 || l is null || indexOf(l) == layers.length) return;
        invalidatePrimaryMemo();
        noteSelected(l);
        l.selSeat   = --selSeatFront_;
        focusedItem = l;
    }

    /// Make `l` the edit target WITHOUT selecting it — the reconstruction of a
    /// LATCHED target, for a reader restoring a document that was saved in that
    /// state (task 0671; `io/native.d`).
    ///
    /// WHY A READER NEEDS THIS AND NOTHING ELSE DOES. `.v3d` records the
    /// selected SET per item and the edit target as one index. In every state
    /// reachable before this task those two agreed — the target was always
    /// selected — so a loader could re-select the named item and be done. A
    /// latched target is the state where they disagree: `"primaryLayer": 2`
    /// with layer 2's `"selected": false`. Re-selecting it would round-trip a
    /// document into a DIFFERENT one, quietly, with the panel showing a
    /// selection the user did not leave behind.
    ///
    /// So this puts the item where the state that produced it would have: at
    /// the front of its kind's history bucket, which is precisely what "it was
    /// deselected most recently, and nothing has been selected of its kind
    /// since" means.
    ///
    /// It is NOT a general affordance and there is deliberately no command for
    /// it. Interactively the latch is always a CONSEQUENCE — of a deselect
    /// that happened — and a verb that produced one directly would be the
    /// stored pointer wearing a different name.
    void latchEditTarget(Layer l) {
        if (!isMember(l) || l.selected) return;
        invalidatePrimaryMemo();
        l.selSeat = --selSeatFront_;
        foreach (h; deselected_[l.kind]) if (h is l) return;   // already listed
        deselected_[l.kind] ~= l;
    }

    /// ~~Hide-primary promotion helper (called by the setVisible command path).
    /// Hiding the primary moves the primary to another selected+visible layer
    /// when one exists; returns false (refuse) when the primary is the only
    /// selected+visible layer (the caller then leaves it visible).~~
    ///
    /// RETIRED BY MEASUREMENT (task 0671). `tests/fixtures/
    /// edit_target_legality.json`, cell `hidden_mesh_keeps_the_target`: hiding
    /// the edit target does not hand the target to anyone else, and the
    /// reference's own classifier says why — the hidden arm keeps a targetable
    /// item FOREGROUND rather than dropping it. So there is nothing to promote
    /// away from and nothing to refuse, and `roleOf` carries the whole law.
    ///
    /// Kept as an always-true call so the `layer.setVisible` command keeps its
    /// shape (it asks, and now never has to take no for an answer); the
    /// alternative was deleting the question at its one call site and losing
    /// the record of what used to be answered there.
    bool promoteAwayFromHiddenPrimary() { return true; }

    /// L1 (task 0615): the promotion algorithm a structural mutation of
    /// `layers` (e.g. a layer delete) must run to keep `primary` inside the
    /// list. `at` is the slot the OLD primary vacated — read against the
    /// POST-mutation `layers` slice. Scans forward from `at` first, then
    /// backward over `[0 .. at)`, for the first `canBePrimary` layer. Lazy,
    /// no allocation — this may run on a delete mid-drag.
    ///
    /// Caller precondition (NIT, undocumented before this revision): only
    /// call this when the layer that vacated slot `at` actually WAS
    /// `primary` (or otherwise needs re-homing). This function does not
    /// check that itself — it unconditionally returns *a* `canBePrimary`
    /// candidate near `at`, so calling it when the current `primary` is
    /// still valid will silently propose moving `primary` to someone else.
    /// Callers must gate on identity first, e.g.
    /// `removed is prevPrimary ? doc.rehomePrimary(at) : prevPrimary`
    /// (Stage 6's `LayerDelete`).
    ///
    /// Degenerate on an all-mesh document: returns `layers[at]` when
    /// `at < layers.length`, else `layers[$-1]` — EXACTLY today's positional
    /// successor rule (`commands/layer/commands.d:420-421`). Any drift in
    /// that degenerate case against `test_layers.d` / `test_layers_undo.d` /
    /// `test_layer_duplicate.d` means this generalisation is wrong, not that
    /// those tests need changing.
    ///
    /// Returns `null` only in the state the ≥1-mesh document invariant
    /// forbids — unreachable once the delete guard (Stage 6) refuses to
    /// remove the last `canBePrimary` layer.
    Layer rehomePrimary(size_t at) {
        immutable size_t start = at <= layers.length ? at : layers.length;
        foreach (l; layers[start .. $])
            if (kindInfo(l.kind).canBePrimary) return l;
        foreach_reverse (l; layers[0 .. start])
            if (kindInfo(l.kind).canBePrimary) return l;
        return null;
    }

    /// ~~SF2 (task 0615, review round 2): repair `primary` IN PLACE when it is
    /// unusable — null OR STALE (`!isMember`, see `exclusiveSelect`'s
    /// comment) — for the two mutator arms that never route through
    /// `exclusiveSelect` (`selectItem`'s `Add` case and `setPrimary`) and
    /// therefore have no other chance to notice `primary` has gone bad. Only
    /// call this when the caller's own target could not itself become
    /// `primary` (i.e. `!canBePrimary`) — it does not touch `target` at all,
    /// only `this.primary`. Marks the recovered candidate `selected` (so the
    /// `primary.selected` invariant holds the moment this returns) and
    /// installs it. Returns the (possibly still null) result — null in the
    /// state the ≥1-mesh invariant forbids, and (task 0668) whenever the
    /// primary was legitimately absent to begin with.
    ///
    /// TASK 0668 — NULL IS NOT STALE. This used to treat `primary is null`
    /// as damage and repair it by scanning for a `canBePrimary` layer and
    /// SELECTING it. Measured before the fix: from an empty selection,
    /// ctrl-adding a plane came back with the mesh selected and primary —
    /// a layer the user never picked, arriving out of an `Add` on an
    /// unrelated item. Since [[0654]] an absent primary is a legal state, and
    /// since 0668 it is reachable with items still selected, so the two cases
    /// are told apart by NULLNESS, not by membership — exactly the
    /// distinction `selectItem`'s Remove arm already draws and documents.~~
    ///
    /// DELETED (task 0671) — with the whole hazard it repaired. A STALE
    /// primary was possible only because `primary` was a stored pointer that a
    /// direct `layers = …` write could orphan. The edit target became derived
    /// by ENUMERATING `layers`, so the walk simply stops seeing an item that
    /// left. Two mutator arms called this and both lost their reason to at the
    /// same time.
    ///
    /// ~~So "non-null but no longer a member" has no representation.~~
    /// CORRECTED (task 4061 review). That sentence stopped being true the
    /// moment `primary` grew a memo: `primaryMemo_` IS a stored pointer, and
    /// a stale one names exactly that state — the reviewer's mutation
    /// (invalidation deleted from the delete path) produced it, and commands
    /// bind a `Mesh*` off the answer, so it is dereferenced rather than
    /// caught. What is true now is narrower and is a property of the KEY, not
    /// of the model: the memo's `(block, length)` term moves at every one of
    /// the 21 production writes to `layers` by construction (see the memo's
    /// own block comment), so a spliced-out layer cannot survive as an
    /// answer. The DERIVATION still has no representation for it; the CACHE
    /// in front of the derivation does, and the key is what forbids it.
}
