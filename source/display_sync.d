module display_sync;

import mesh : Mesh, GpuMesh;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

// Seam 2b — the display-refresh gate.
//
// Mutating commands run their apply()/revert() against the Mesh* they were
// bound to at fire time (the command base's `Mesh* mesh` field). That mesh
// is NOT necessarily the one currently on screen once multiple layers
// coexist: an undo that reverts a background layer must mutate that layer's
// mesh + publish change-bus flags as usual, but it must NOT write the active
// layer's GPU display buffer or resize the GLOBAL pick caches against the
// foreign mesh.
//
// All such command refresh paths funnel through `refreshDisplay` below. The
// gate compares the command's target mesh against the app-installed
// `activeMeshResolver` and no-ops the GPU upload + cache resize/invalidate
// when they differ. In Stage 0a there is exactly one mesh, so the resolver
// always matches the target ⇒ this is provably byte-neutral (every command
// still uploads + resizes + invalidates exactly as before).
//
// app.d installs `activeMeshResolver` once at init (Stage 0a: `() => &mesh`;
// Stage 0b: `() => document.activeMesh()`). The same delegate the resolver
// returns is the one currently rendered, so the gate is the single authority
// on "is this command's mesh the one on screen?".

/// Installed once by app.d at init. Returns the mesh currently displayed
/// (the active layer's mesh). Stage 0a: resolves to the one global mesh.
__gshared Mesh* delegate() activeMeshResolver;

/// Gated display refresh shared by every mutating command's apply()/revert().
///
/// When `target` is the active (on-screen) mesh, this performs the same
/// GPU upload + cache resize/invalidate the command bodies did inline. When
/// `target` is a non-active (background) mesh, it is a no-op — the active
/// layer's display buffer and the global pick caches are never written
/// against a foreign mesh. The active layer is re-uploaded by the
/// layer-switch hook when it becomes active, so nothing is left stale.
///
/// The `resize` calls are guarded inside the cache types (a resize to the
/// same length is a genuine no-op), so routing both the resize-and-invalidate
/// commands and the invalidate-only commands through this single helper is
/// byte-neutral: topology-preserving commands hit the same-length fast path.
///
/// Kept as the low-level primitive (also used directly by tests/tools that
/// own a standalone gpu/cache set outside app.d) — `refreshDisplayActive`
/// below is the seam every migrated command routes through instead of
/// carrying its own 4 pointers; see that function's doc comment.
void refreshDisplay(Mesh* target, GpuMesh* gpu,
                    VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
    // Resolver not installed (e.g. tools/tests that construct commands
    // without app init): fall back to the legacy unconditional refresh so
    // those paths behave exactly as before this seam landed.
    if (activeMeshResolver !is null && target !is activeMeshResolver())
        return; // recorded layer not on screen — display refresh is a no-op

    gpu.upload(*target);
    vc.resize(target.vertices.length);                          vc.invalidate();
    ec.resize(target.edges.length);                             ec.invalidate();
    fc.resize(target.vertices.length, target.faces.length);     fc.invalidate();
}

// ---------------------------------------------------------------------------
// Seam 3 (task 0413, campaign 0407 §A.D4-b) — the display-TARGET resolver.
//
// `refreshDisplay` above still makes every caller carry 4 raw pointers
// (GpuMesh*/VertexCache*/EdgeCache*/FaceBoundsCache*) to the currently
// displayed viewport cell. ~83 mesh-command classes stored those as ctor-
// injected fields purely to hand them back to `refreshDisplay` at
// apply()/revert() time — real duplication, since "which cell is on
// screen" is exactly the question `activeMeshResolver` above already
// answers for the MESH half of the pair. `displayTargetsResolver` is the
// target-side counterpart, and `refreshDisplayActive` is the helper built
// on it: a caller passes only the mesh it just mutated; the resolver
// supplies gpu/vc/ec/fc.
//
// Bonus-fix this seam buys for free: the old per-command pattern captured
// gpu/vc/ec/fc at the moment the command was CONSTRUCTED — app.d's factory
// closures resolve `&vertexCache()` etc. once, at fire time. An undo/redo
// delivered later, after the user switched the active viewport cell, would
// still refresh the cell that was active WHEN THE COMMAND WAS BUILT, not
// the one on screen now. `refreshDisplayActive` resolves fresh on every
// call instead, so it always targets the cell that is actually active at
// refresh time — the only cell `refreshDisplay`'s own `activeMeshResolver`
// gate above would let the upload/resize reach anyway.
// ---------------------------------------------------------------------------

/// The GPU buffer + 3 screen-space pick caches of one viewport cell — the
/// "target" half of a display refresh (the mesh being refreshed is passed
/// separately, per-call, to `refreshDisplayActive`).
struct DisplayTargets {
    GpuMesh*         gpu;
    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;
}

/// Installed once by app.d at init, once `gpu` / `vertexCache()` /
/// `edgeCache()` / `faceCache()` all exist (necessarily later than
/// `activeMeshResolver` above, which is installed before the viewport
/// manager and GPU buffer are constructed). Returns the display targets of
/// the ACTIVE viewport cell, resolved at CALL time — see the module doc
/// comment above for why "at call time" (not "at closure-construction
/// time") is the point of this seam.
__gshared DisplayTargets delegate() displayTargetsResolver;

/// Gated display refresh keyed only on the mutated mesh — `target`'s
/// gpu/cache counterparts come from `displayTargetsResolver`, resolved
/// fresh on every call. This is what every migrated command's apply() /
/// revert() calls instead of storing its own GpuMesh*/VertexCache*/
/// EdgeCache*/FaceBoundsCache* fields.
///
/// No-ops when `displayTargetsResolver` is unset (e.g. a `unittest` block
/// or standalone tool that builds a command without app init): unlike
/// `refreshDisplay`, there is no caller-supplied gpu/cache set to fall back
/// to here — the command genuinely has nothing to refresh against. The
/// mesh mutation itself (already applied by the caller before this runs)
/// is unaffected; only the GPU upload + pick-cache resize/invalidate is
/// skipped, exactly as it would be for a background (non-active) layer.
void refreshDisplayActive(Mesh* target) {
    if (displayTargetsResolver is null) return;
    auto t = displayTargetsResolver();
    refreshDisplay(target, t.gpu, t.vc, t.ec, t.fc);
}

unittest {
    // Resolver-not-installed: no-op, doesn't crash even with a target that
    // has no live GPU/cache behind it (mirrors a `dub test` module
    // unittest that constructs a migrated command without app init).
    scope(exit) { activeMeshResolver = null; displayTargetsResolver = null; }
    activeMeshResolver     = null;
    displayTargetsResolver = null;
    Mesh m;
    refreshDisplayActive(&m); // must not throw / segfault
}

unittest {
    // The actual point of this seam: refreshDisplayActive(target) must
    // RE-RESOLVE displayTargetsResolver on every call, not bind to whatever
    // was live when some outer closure captured it once (the bug the 0413
    // bonus-fix removes — see the module doc comment above). Simulate an
    // "active cell switch between two refreshes" by flipping what the
    // resolver returns and checking it gets CONSULTED AGAIN, not reused.
    //
    // `activeMeshResolver` is deliberately pointed at a DIFFERENT mesh than
    // `target` below, so refreshDisplay's own mesh-gate no-ops on every
    // call — this test only needs to observe that displayTargetsResolver
    // itself runs fresh each time (via the counter), so it never has to
    // exercise `GpuMesh.upload`'s real GL calls, which need a live context
    // this headless `dub test` binary doesn't have (that path is exercised
    // by the HTTP suite instead, which always runs through a real app.d
    // init). `displayTargetsResolver` is consulted BEFORE refreshDisplay's
    // gate runs, so the counter still observes every call regardless of
    // the gate's outcome.
    scope(exit) { activeMeshResolver = null; displayTargetsResolver = null; }

    Mesh mTarget, mOther;
    activeMeshResolver = () => &mOther; // never matches `target` ⇒ gate always no-ops before touching a real GpuMesh

    // The resolver's RETURN VALUE doesn't matter here (refreshDisplay's own
    // gate no-ops before ever reading it) — only that it gets CALLED, fresh,
    // every time. The active viewport cell (and thus which gpu/caches the
    // resolver would return) can change between two refreshes of the SAME
    // command; per-call consultation is what makes undo/redo-after-cell-switch
    // resolve the CURRENT cell rather than the one captured at construction.
    int resolveCount = 0;
    displayTargetsResolver = () {
        ++resolveCount;
        return DisplayTargets.init;
    };

    refreshDisplayActive(&mTarget);
    assert(resolveCount == 1, "must consult the resolver on the first call");

    // A second refresh of the same target must consult the resolver AGAIN,
    // WITHOUT constructing a new command/closure — exactly the
    // undo/redo-after-cell-switch scenario the bonus-fix targets.
    refreshDisplayActive(&mTarget);
    assert(resolveCount == 2,
        "must consult the resolver AGAIN on the second call — a captured-once "
        ~ "value would leave this at 1");
}
