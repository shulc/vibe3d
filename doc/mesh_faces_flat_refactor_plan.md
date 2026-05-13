# `Mesh.faces` — flat storage refactor plan

## Motivation

`Mesh.faces` is currently `uint[][]` — an outer slice-header array of
slice-headers, each pointing at an independently-GC-allocated `uint[]`.
On heavy meshes that pattern hurts in two ways:

1. **GC pressure on construction.** Every `addFace([…])` and every
   `outMesh.faces[fi].length = cnt` is a fresh `uint[]` allocation that
   takes the GC spinlock. On a 24576-cage subpatch preview rebuild that's
   393 K small allocations through one global lock.
2. **Pointer-chase per face.** Reads of `mesh.faces[fi][k]` go through
   two pointer indirections (outer slot → inner slice → indices). A flat
   `uint[] facesFlat` lets the same iteration stay in L1/L2 cache.

After the P0-P5 wins in `doc/subpatch_tab_perf_plan.md` (Tab median
638 → 256 ms, −60 %) the residual hot path on a 24K cage has two stubborn
contributors that this refactor addresses:

- **`Mesh.buildLoops` Pass 1 / 2** still spends time walking
  `faces[fi][k]` for every loop. Sequential access into flat storage
  removes the per-face pointer chase.
- **`OsdAccel.buildPreview`'s outer `outMesh.faces.length = limitFaces`**
  is a 6.3 MB outer-slice-header buffer resize on every preview rebuild.
  Halves to 3.1 MB with CSR offsets (`uint[]` vs `uint[][]`).

Estimated additional Tab-path win once landed: **~30-50 ms median** on
the 24K-cage harness. Gets us into the ≤ 200 ms target zone the perf
plan aimed at.

## Current state — `Mesh.faces` usage in vibe3d

Counted via `grep -rn "\.faces\[" source/` and friends:

| Pattern | Count | Notes |
|---|---|---|
| `mesh.faces[fi]` reads | ~78 sites | mostly `auto face = mesh.faces[fi];` followed by `face.length` / `face[k]` reads |
| `mesh.faces.length = N` | 32 sites | top-level resize, mostly inside `mesh.d` topology rebuilds (`rebuildEdgesFromFaces`, `catmullClark` legacy paths) + subpatch_osd preview / subdivide |
| `mesh.faces ~= newFace` | 9 sites | `addFace`, bevel cap-face additions, subpatch_osd's `catmullClarkOsd` (subdivide command path) |
| `mesh.faces[fi] = slice` | 5 sites | `poly_bevel.d:332,467`, `subpatch_osd.d:894`, plus a couple of asserts |
| `mesh.faces[fi][k] = x` *(in-place vert write)* | **2 sites** | both in `subpatch_osd.catmullClarkOsd` (the **subdivide command**, NOT the Tab preview path) |
| `mesh.faces[fi].length = N` | 2 sites | also in `subpatch_osd.catmullClarkOsd` only |
| `mesh.faces[fi].dup` | 4 sites | snapshots in `poly_bevel`, `bevel`, `symmetry`, the HTTP `/api/model` provider |
| `foreach (.. ; faces)` / `foreach (fi, f; faces)` | ~20 sites | sequential walks |

**Key constraint** — the only places that mutate INDIVIDUAL face contents
in-place are `subpatch_osd.catmullClarkOsd` (subdivide command). The
hot Tab path (`buildPreview`) NEVER mutates a face after writing it
once. That's why a flat storage with "replace whole face" semantics is
viable.

## Target state — CSR storage

```d
struct Mesh {
    // ...
    uint[] facesFlat;     // concatenated vertex indices of all faces
    uint[] faceOffset;    // length = N + 1; face fi spans
                          // facesFlat[faceOffset[fi] .. faceOffset[fi + 1]]
    // ...
    @property size_t faceCount() const { return faceOffset.length - 1; }

    const(uint)[] face(uint fi) const {
        return facesFlat[faceOffset[fi] .. faceOffset[fi + 1]];
    }
}
```

- `Mesh.faces` as a public field is replaced by accessor methods.
  Indexing `mesh.face(fi)` returns a read-only slice into `facesFlat`.
- Writing happens through three methods only:
  - `addFace(const(uint)[] verts)` — append.
  - `setFace(uint fi, const(uint)[] verts)` — replace face fi
    (handles size-change by shifting the tail of `facesFlat`).
  - `setFacesFromFlat(uint[] flat, uint[] offsets)` — bulk install
    (preview build's hot path: a single pointer swap, no shifting,
    no per-face copy).
- Slice returned by `face(fi)` is **invalidated** the moment any of
  the three writers runs. Callers must `.dup` if they need to hold a
  reference across a mutation. Most existing callers already store
  `auto face = mesh.faces[fi]` for the duration of a single short
  block — that pattern stays correct.

## Refactor stages

Each stage compiles cleanly, passes all 47 HTTP + 10 inline tests,
and ends with a commit. Stage E measures perf.

### Stage A — wrap `uint[][] faces` in a `FaceList` struct *(no semantic change)*

- Replace the field declaration:

  ```d
  uint[][] faces;
  →
  FaceList faces;
  ```

- `FaceList` is a thin struct around the existing `uint[][]`:

  ```d
  struct FaceList {
      uint[][] _store;
      size_t length() const          { return _store.length; }
      void length(size_t n)          { _store.length = n; }
      inout(uint)[] opIndex(size_t i) inout { return _store[i]; }
      void opIndexAssign(uint[] v, size_t i) { _store[i] = v; }
      void opOpAssign(string op : "~")(uint[] v) { _store ~= v; }
      // foreach support: opSlice + opApply OR just expose the inner
      //   slice through `range()` and migrate `foreach`-sites to it.
  }
  ```

- This is purely scaffolding; performance is unchanged and so is every
  caller's code. Goal: cleanly introduce the type without forcing
  every call site through a migration in the same commit.
- **Audit pass:** run a grep for `mesh.faces[fi][k] =` and confirm
  only the 2 expected sites in `subpatch_osd.catmullClarkOsd` exist;
  same for `faces[fi].length =`. Flag any new site found.

### Stage B — migrate the 2 in-place face-element writes

`subpatch_osd.catmullClarkOsd` (lines ~227 and ~302) currently does:

```d
result.faces[k].length = limitFC[k];
foreach (j; 0 .. limitFC[k])
    result.faces[k][j] = cast(uint)limitFI[cursor++];
```

Replace with the "build a local `uint[]` then assign":

```d
uint[] verts = new uint[](limitFC[k]);
foreach (j; 0 .. limitFC[k])
    verts[j] = cast(uint)limitFI[cursor++];
result.faces[k] = verts;
```

Once this lands, no in-place per-element write into `faces[fi]`
exists in the project. Stage C can then safely give `face(fi)` a
read-only return type.

### Stage C — flip `FaceList` storage to CSR

- Add new fields inside `FaceList`:

  ```d
  uint[] _flat;
  uint[] _offset;   // length = _store.length + 1, kept in sync
  ```

- Initially keep `_store` (the `uint[][]`) AS A SHADOW that mirrors
  `_flat + _offset`. Every writer updates both.
- `opIndex(fi)` switches to returning `_flat[_offset[fi] .. _offset[fi+1]]`.
- Run the test suite. The shadow is wasted memory but guarantees we
  haven't regressed any caller that reads through `_store` via the old
  operator-overload path.

### Stage D — drop the shadow `_store`

- Remove `_store` from `FaceList`. `opIndex` is now CSR-backed only.
- `opIndexAssign(uint[] v, size_t i)` becomes "shift tail of `_flat`
  by the size delta and replace the slot." Detail:

  ```d
  void opIndexAssign(const(uint)[] v, size_t fi) {
      size_t old = _offset[fi+1] - _offset[fi];
      ptrdiff_t delta = cast(ptrdiff_t)v.length - cast(ptrdiff_t)old;
      if (delta != 0) {
          // shift the tail of _flat
          // adjust _offset[fi+1 .. $] by delta
      }
      _flat[_offset[fi] .. _offset[fi] + v.length] = v[];
  }
  ```

  The 5 existing call sites of `faces[fi] = ...` are all in
  high-level mesh edits (bevel, poly_bevel) — they fire a handful of
  times per user action, not in tight loops. O(N) shift is fine
  there.
- `opOpAssign!"~"(v)` appends to `_flat` and pushes a new entry on
  `_offset`. Both grow via P5-style grow-only setLength.

### Stage E — bulk-install in `OsdAccel.buildPreview`

- Add the bulk method:

  ```d
  // FaceList:
  void setFromFlat(uint[] flat, uint[] offset) {
      _flat = flat;
      _offset = offset;
  }
  ```

  (Or, to keep the FaceList owning its storage, copy via setLength +
  block copy; the win comes from avoiding per-face slice assignments
  either way.)

- In `subpatch_osd.OsdAccel.buildPreview`, replace the current
  per-face assignment loop:

  ```d
  // current:
  outMesh.faces.length = limitFaces;
  auto scratchFacesAsUint = cast(uint[]) scratchFaceIndicesI;
  int cursor = 0;
  foreach (fi; 0 .. limitFaces) {
      int cnt = scratchFaceCounts[fi];
      outMesh.faces[fi] = scratchFacesAsUint[cursor .. cursor + cnt];
      cursor += cnt;
  }
  ```

  with:

  ```d
  // new: derive offset[] from cumulative counts, install in one shot
  scratchFaceOffsets.length = limitFaces + 1;
  uint cum = 0;
  scratchFaceOffsets[0] = 0;
  foreach (fi; 0 .. limitFaces) {
      cum += cast(uint)scratchFaceCounts[fi];
      scratchFaceOffsets[fi + 1] = cum;
  }
  outMesh.faces.setFromFlat(cast(uint[]) scratchFaceIndicesI,
                              scratchFaceOffsets);
  ```

  Outcome on the Tab path: zero slice-header writes, one pointer
  swap. Plus the outer-array memory drops from 16 × N to 8 × N bytes.

### Stage F — measure & document

- Run `tools/perf_subpatch/run.d --no-build --tabs 30 --freq 4999 --capture 1`.
- Expected Tab median: **256 → ~200 ms** (−20 % from current, putting
  us at or below the perf plan's original ≤ 200 ms target).
- Update `doc/subpatch_tab_perf_plan.md` with the new row.
- Confirm `_d_arraysetlength!_HTAfTfZ` and `expandArrayUsed` stay low
  in the post-refactor profile.

## Risk assessment

| Risk | Mitigation |
|---|---|
| Reader assumes `faces[fi]` is mutable | Stage B removes the only known in-place mutators. Stage C lands `opIndex` returning `const(uint)[]` so the compiler catches further regressions. |
| Slice returned by `face(fi)` outlives a `_flat` resize | Audit Stage A; document the lifetime rule on `FaceList.opIndex`. Hot callers already store the slice for one block only. |
| `opIndexAssign` size-change shift slows down bevel | The 5 reassignment sites are user-action-rate (one per bevel apply), not per-frame. O(N) shift on ≤ 24K faces is sub-ms. Verified by the bevel + poly_bevel HTTP tests staying green. |
| Subpatch preview consumers indirectly call `Mesh.buildLoops` on the preview, which writes to per-face state | P4 (`subpatch_osd: skip Mesh.buildLoops on the preview mesh`) already removed that. Stage A's audit confirms no other writer fires on the preview path. |
| Inline tests reference `preview.faces.length` / `preview.faces[fi].length` | Both keep working through `FaceList`'s `length` property and `opIndex` returning a slice with its own `.length`. No test rewrites needed. |
| Tests in `tests/test_subpatch_move.d` read `/api/model` faces JSON | `/api/model` provider builds its own `facesCopy[i] = mesh.faces[i].dup;` — works with the new API. |

## Verification

After each stage:

- `dub build` is warning-free.
- `dub test` → 10/10 inline modules pass.
- `./run_test.d --no-build -j 4 --exclude test_selection --exclude test_toolpipe_axis --exclude test_http_endpoint --exclude test_bevel_rebevel --exclude test_toolpipe_falloff` → 47/47 HTTP tests pass.
- After Stage F:
  `rdmd tools/perf_subpatch/run.d --no-build --tabs 30 --freq 4999 --capture 1`
  → median Tab ms drops by ≥ 30 from the post-P5 baseline (256 ms).

## Out of scope

- **Mesh.edges flat storage.** `Mesh.edges` is `uint[2][]` — already
  flat (each element is a 2-uint inline struct). No outer pointer
  array, no per-edge allocation. Not a refactor target.
- **`Mesh.loops` / `faceLoop` / `vertLoop` / `loopEdge`.** Already flat
  `Loop[]` / `uint[]`. Not a refactor target.
- **OpenSubdiv-side topology refiner caching across topology-only
  toggles** (the perf plan's original P4). Orthogonal — that's a
  D-OpenSubdiv API change, not a vibe3d-side refactor.
- **CSR storage for in-progress / partial topology edits** (e.g.
  staged bevel that builds up a new mesh face by face). The current
  refactor handles bevel through its existing snapshot/replace
  pattern; an interactive editing layer above `Mesh` can keep using
  scratch `uint[][]` if needed.
