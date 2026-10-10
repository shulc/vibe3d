module camera_stamp;

// THE CAMERA STAMP — "has the camera moved since I last derived from it?", once.
//
// WHY IT IS A VALUE AND NOT A COUNTER (task 1930). Every other freshness key in
// this tree rides a version counter or the change bus, and both are wrong IN
// KIND here: the camera publishes no `MeshEditScope`, and an orbit changes no
// mesh, so a `mesh_dirty` epoch or a `mutationVersion` term would answer "not
// stale" while the picker reads an ID buffer rasterised under the previous
// matrices. The only honest key for a camera-derived artifact is THE MATRICES
// THEMSELVES, compared at the point of use. That is also the shape the
// reference SDK takes: its view interfaces expose `Matrix`/`Bounds`/`Type` as
// plain getters with no version, no serial and no "camera changed" notifier, so
// every consumer that wants a boolean compares for itself.
//
// WHY IT IS ITS OWN MODULE. `viewport.DirtyKey` (`viewport.d`, the
// `lastKey` compare) used to be one of two remaining places that spelled this
// compare out by hand with its own `float[16] view/proj` pair; task 1970
// folded it into a `CameraStamp cam` field instead, so the one place left is
// `ai/exploration.d`'s `viewsEqual`, a frozen stage-time anchor over `view`
// alone, deliberately left out. A stamp that lived inside `gpu_select` could
// not be taken to `DirtyKey` without a backwards import, so it lives alone
// and imports nothing.
//
// EXACTNESS IS PART OF THE CONTRACT. The compare is element-wise `!=` with no
// epsilon, which is what the three `viewcache` copies and `gpu_select`'s
// private `matricesEqual` all did before this module absorbed them. A tolerance
// would be a behaviour change smuggled into a refactor: it would let a slow
// orbit accumulate below the threshold and keep answering out of a stale
// buffer.
//
// DEFAULT INITIALISATION IS `0`, NOT D's NaN, AND THAT IS A CHOICE.
// `GpuSelectBuffer.Slot.view`/`.proj` used to be bare `float[16]`, i.e. NaN,
// and `NaN != NaN` is true — so two default slots would have compared as
// CHANGED. The difference is unobservable at the one consumer, because
// `slot.valid &&` short-circuits the compare until the first render
// (`gpu_select.d`, the `slot.valid &&` short-circuit); that is an argument, not an identity, and it is
// recorded here rather than left for a reader to re-derive. `= 0` is chosen for
// two reasons: it makes `changed` between two fresh stamps FALSE, which is the
// cell `tests/unit/camera_stamp_test.d` pins, and it matched what `DirtyKey`
// already declared before task 1970 (`float[16] view = 0;`) — so folding one
// into the other (`DirtyKey.cam`) was a pure representation change, two
// things that already agreed.
//
// NO `opEquals`, NO MUTABLE MEMO FIELD. `DirtyKey` is compared WHOLE
// (`app.d`'s per-cell `if (_newKey != _cv.lastKey)`); the moment this struct grows
// either, that comparison silently changes meaning. `DirtyKey.cam` depends on this
// line staying true.

/// A camera pose as the two matrices a derived artifact was built under.
struct CameraStamp {
    float[16] view = 0;
    float[16] proj = 0;

    /// True when `(v, p)` differs from what was last stamped — element-wise,
    /// exactly, both halves.
    bool changed(const ref float[16] v, const ref float[16] p) const {
        foreach (i; 0 .. 16) {
            if (view[i] != v[i]) return true;
            if (proj[i] != p[i]) return true;
        }
        return false;
    }

    /// Record `(v, p)` as the pose the caller has now derived under.
    void update(const ref float[16] v, const ref float[16] p) {
        view[] = v[];
        proj[] = p[];
    }
}
