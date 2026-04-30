# Bevel: refactor to Blender's edge-based BoundVert model

## Goal

Replace vibe3d's wedge-based `BoundVert` allocation in `populateBoundVerts`
(`source/bevel.d:764`) with Blender's edge-based model (one BV per incident
EdgeHalf, owning that EH's left/right side via `e->leftv`/`e->rightv`). Match
upstream `bmesh_bevel.cc` geometry — at `selCount=1, valence ≥ 4` the bevel
must wrap smoothly along the opposite-side EH (`EH_b`) instead of being closed
by an extra triangular `materializeBackCapEvenValence` cap. Reduce divergence
from `bmesh_bevel.cc` so future ports land cleanly.

## Status snapshot (2026-04-30)

| Phase | Status | Result |
|---|---|---|
| 0 — Inventory + invariant trap | ✅ done | dormant trap silent across all tests |
| 1 — Populate `eh.leftBV/rightBV` from wedge | ✅ done | additive only, no test drift |
| 2 — Edge-BVs at `selCount=1, valence=4` | ✅ done | `cc_valence4_single_edge` XPASS, bit-for-bit Blender match |
| 3 — TRI_FAN endpoint at `valence=2` | ✅ done | `weld_split_then_bevel_one_half` PASS |
| 4 — `selCount ≥ 2` propagation | ✅ done | `test_bevel_capseg_rebevel` PASS, `cube_corner2_seg6_rebevel_polyline` topology matches Blender (geometry drift only ~0.005-0.01) |
| 5 — vid-based non-degenerate-profile selection | ✅ done | `test_bevel_capseg_rebevel_seg2` PASS, `cube_corner2_seg3_rebevel_polyline_seg2` topology matches Blender bit-for-bit (27V/20F arity {4:16, 7:2, 6:2}); residual is geometric drift only |
| 6 — Cleanup / rename | ✅ done | renames + dead-code removal + module docstring; suite still 25/25 |

**Tests**: 25 / 25 PASS (full suite incl. `test_bevel_capseg_rebevel_seg2`).
**Blender diff**: 24 / 28 PASS, 1 FAIL (pre-existing unrelated `diamond_weld_two_edges`), 3 XFAIL
(`cube_corner2_seg6_rebevel_polyline` geometric drift, `cube_corner2_seg3_rebevel_polyline_seg2`
geometric drift, `octahedron_tip` topology drift).

## Updates from Blender geometry diff (2026-04-29)

Direct comparison via `tools/blender_diff/` (cases
`cc_valence4_single_edge` and `cube_corner2_seg6_rebevel_polyline`) gave
three concrete corrections to the original plan:

1. **`materializeBackCapEvenValence` is NOT a workaround that disappears.**
   Blender emits an equivalent cap-at-v triangle for every `selCount=1,
   even valence` endpoint. Phase 2 re-routes its third vertex from the
   cube neighbour (current behaviour) to the new edge-BV; Phase 5
   renames/relocates the function but does NOT delete it.

2. **Strip face stays a 4-vertex quad.** Earlier "Phase 2 REVISED v1"
   guess that the strip becomes a hexagon `[leftBV, edgeBV, rightBV, …]`
   was wrong. The cap-at-v triangle alone shares `(BV0, edgeBV)` and
   `(edgeBV, BV1)` with the F_OTHER pentagons, closing the topology.
   `applyEdgeBevelTopology`'s strip emission needs ZERO changes for
   Phase 2.

3. **Splice convention is keyed by face walking direction, not BvVert
   ring index.** Blender's `vstart = eprev->rightv, vend = e->leftv`
   (`bmesh_bevel.cc:6850`) walks the face at `bv.vert`, picks the EHs on
   the incoming/outgoing sides, and reads their owning BV. Vibe3d's
   ring-index `k`/`knext` does NOT correspond to face walking — that's
   what broke the failed narrow attempt. Two F_OTHERs sharing a
   non-bev edge through `bv.vert` only get a manifold splice if both
   read the SAME EH's `leftv`/`rightv`, which only happens when the
   lookup is keyed by walking direction (both faces' `e` (or `eprev`)
   for the shared edge resolves to the same EH).

These corrections are reflected in the Phase 2 REVISED v2 section below.

## Non-goals

- No new bevel features (no chamfer, no harden-normals, no UV smoothing).
- No change to BevelOp public API, BevelTool UX, or HTTP `/api/bevvert`
  envelope (we MAY extend the JSON with new fields but must not remove
  `selCount`, `boundVerts`, `isOnEdge`, `slideDir`, `origPos`).
- No change to `MiterPattern.Arc` geometry beyond what's required to keep
  `materializeArcMiterPatch` working under the new BV indexing.
- No change to seg=1 strip topology: the bevel quad of every selected edge
  remains a single 4-vertex face joining four BVs. Only the BV count per
  vertex and the wedge-vs-edge ownership change.

---

## Background — what changes structurally

**Today (wedge-based)**, for a `selCount=1, valence=4` BevVert:
- `populateBoundVerts` (`source/bevel.d:793-797`) skips wedges where neither
  flanking EH is beveled, so the BV ring has only 2 entries (the BVs flanking
  the bev edge). Two of the four wedges contribute no BV.
- `materializeBevVert` (`source/bevel.d:1275-1338`) handles those wedge gaps
  by either single-side-replacement (valence ≥ 4 F_OTHERs) or full-cap-splice
  (valence=3, single F_OTHER spanning both sides). The single-side path
  leaves an open edge along `EH_b`, closed by `materializeBackCapEvenValence`
  (`source/bevel.d:1465-1508`).
- `applyEdgeBevelTopology` strip emission (`source/bevel.d:437-440`) uses
  `boundVertIdxForEh{,To}` — wedge-flanking lookup.

**Blender (edge-based)**, same `selCount=1, valence=4`:
- `build_boundary_terminal_edge` (`bmesh_bevel.cc:2974`, else branch
  `3020-3075`) allocates **one BV per incident EH = 4 BVs**. Two flank the
  bev edge at `offset_meet` of bev with each non-bev neighbor. The other two
  sit ON their non-bev edges at slide-distance from `v_orig`.
- Each EH carries `leftv`, `rightv` pointing to its owning BVs:
  `e->leftv == e->rightv == bndv` for non-bev EHs.
- `bev_rebuild_polygon` (`bmesh_bevel.cc:6801`) walks each F_OTHER and
  replaces `v_orig` at the corner between `eprev` and `e` with
  `eprev->rightv` and `e->leftv`. Both faces sharing a non-bev edge see the
  SAME BV via that edge's `leftv`/`rightv` field — the topology is manifold
  by construction. **No back-cap face is emitted.**
- The strip emission reads `e->leftv->nv.v` and `e->rightv->nv.v` to find
  the bev quad's corners.

The refactor migrates ownership semantics from wedges (`BoundVert.face`,
`ehFromIdx`/`ehToIdx`) to edges (each EH gets `leftBV`/`rightBV` indices
already declared on `EdgeHalf` at `source/bevel.d:174-175` but currently
unused).

---

## Phase breakdown

Each phase ends with `./run_test.d --no-build` green. Test edits required
to keep the tree green are part of the phase's deliverables.

### Phase 0 — Inventory + invariant trap (no behavior change)

Goal: Pin down the exact set of test assertions that must shift later, and
add an invariant inside `applyEdgeBevelTopology` that fires when wedge-side
and edge-side BV indexing disagree — so subsequent phases get loud failures
instead of silent regressions.

Deliverables:
- Read+annotate every assertion in
  `tests/test_bevel.d` (vertex/face count for selCount=1 valence=3),
  `tests/test_bevel_corner.d` (selCount=2,3 valence=3 + M_ADJ),
  `tests/test_bevel_valence4.d` (the back-cap workaround test),
  `tests/test_bevel_offset_meet.d` (`isOnEdge` bool from `/api/bevvert`),
  `tests/test_bevel_bevvert.d` (`selCount` only),
  `tests/test_bevel_profile.d` (selCount=1 valence=3 seg=2/4),
  `tests/test_bevel_asymmetric.d`,
  `tests/test_bevel_limit.d`,
  `tests/test_bevel_width_modes.d`,
  `tests/test_bevel_rebevel.d` (vertex/edge/face count post-double-bevel).
  Output: a per-test table appended at the bottom of THIS plan file
  (manual update during Phase 0 execution) noting which numeric assertions
  are sensitive to BV count.
- In `source/bevel.d:580-628` `debug { }` block, add an invariant:
  *if* the new edge-side fields (Phase 1) disagree with the wedge-side
  lookup for any `(BevVert, EH)` pair, log to stderr. (Off by default
  until Phase 1 populates the fields.)

Files touched:
- `doc/bevel_blender_refactor_plan.md` (this file — assertion table).
- `source/bevel.d` (debug block extension only — no behavior change).

Test impact: **none** (only debug logging added; all tests should remain
green without edits).

Validation: `./run_test.d --no-build` passes. Inspect stderr in
`vibe3d.log` to confirm no invariant fires (we haven't introduced the new
fields yet, so the trap is dormant).

Rollback: revert the debug block extension. Zero risk.

### Phase 1 — Populate `EdgeHalf.leftBV`/`rightBV` alongside the wedge BVs (additive)

Goal: Compute Blender-style edge ownership in parallel with the existing
wedge-based BV ring, but DO NOT consume the new fields yet — every
materialize and strip path keeps reading `BoundVert.face` /
`boundVertIdxForEh` exactly as today.

Deliverables:
- `source/bevel.d`: at the end of `populateBoundVerts`
  (`source/bevel.d:947`, before `vmesh.kind` is set), populate
  `eh.leftBV` / `eh.rightBV` for every EH using the rules:
  - **Bev EH**: `leftBV` = wedge BV between this EH and the next CCW EH
    (current `boundVertIdxForEh(bv, ehIdx)`); `rightBV` = wedge BV between
    the previous EH and this one (`boundVertIdxForEhTo(bv, ehIdx)`).
  - **Non-bev EH**: under wedge model only ONE wedge BV touches this EH per
    side; today both `leftBV` and `rightBV` end up the same wedge BV
    (current behavior). Mark the field; no new BV allocated yet.
- Phase 0's invariant trap activates: log if `eh.leftBV` ever resolves to a
  different BV than what `applyEdgeBevelTopology`'s strip code derived from
  `boundVertIdxForEh`.

Files touched:
- `source/bevel.d` (`populateBoundVerts` only).
- `source/http_server.d` `/api/bevvert` (lines around 403-416): extend each
  EH's JSON entry with `leftBV` / `rightBV` integers so future phases can
  test from the outside.

Test impact: **none** (additive). Add **one** new assertion in
`tests/test_bevel_bevvert.d`: for a fresh selCount=1 valence=3 cube vertex,
the bev EH's `leftBV` and `rightBV` both refer to valid `boundVerts`
indices. Ten lines.

Validation: `./run_test.d --no-build` green. Stderr clean (no invariant
fires).

Rollback: revert `populateBoundVerts` tail + JSON additions. The wedge
model is still load-bearing.

### Phase 2 — REVISED v2 (after Blender diff comparison, 2026-04-29)

After the failed narrow attempt and a direct geometry diff against
Blender (`tools/blender_diff/cases/cc_valence4_single_edge.json`,
XFAIL), the corrected target shape is concrete and small:

**Target geometry for `test_bevel_valence4` (CC(cube) + 1 edge bevel):**
- **30 V** (= vibe3d today 28 + 2 edge-BVs).
- **27 F** with arity `{4: 21, 5: 4, 3: 2}`:
  - 21 quads = 16 untouched CC quads + 4 bev-containing faces (corner
    replaced by single BV) + 1 strip face.
  - **4 pentagons** = the 4 F_OTHER faces, each spliced from 4-vert to
    5-vert by inserting `[edgeBV]` between the existing wedge-BV neighbour
    and the shared non-bev EH endpoint.
  - **2 triangles** = the cap-at-v polygon at each beveled endpoint
    `[rightBV, leftBV, edgeBV]`, identical in spirit to today's
    `materializeBackCapEvenValence` but with the third vertex re-routed
    from the cube neighbour to the new edge-BV.

**Strip face shape stays unchanged** — confirmed by Blender's output: the
bev-quad strip remains a 4-vert quad `[leftBV_A, rightBV_A, rightBV_B,
leftBV_B]`. The cap chain does NOT get the edge-BV inserted into it.
(My earlier "REVISED" hypothesis that strip becomes a hexagon was wrong;
the cap-at-v triangle gives `(BV0, edgeBV)` and `(edgeBV, BV1)` to the
F_OTHER pentagons WITHOUT the strip having to carry them.)

**Why the failed narrow attempt produced 12 boundary edges:** the splice
convention was indexed by BvVert ring (`bv.edges[k].rightBV` /
`bv.edges[knext].leftBV`) instead of by face walking direction
(`eprev->rightv` / `e->leftv` in Blender terms — `bmesh_bevel.cc:6850`).
At a F_OTHER corner the face walks IN through some EH (= eprev) and OUT
through another (= e); the BvVert ring index `k` of "the EH whose fnext
is this face" does NOT correspond to either eprev or e directly — it
points at the wedge BETWEEN them. For the splice to be symmetric across
two F_OTHERs sharing a non-bev edge, both faces must read the SAME EH's
leftv/rightv at that shared edge — and that requires the lookup to be
keyed by face walking, not ring k.

**Revised Phase 2 deliverables (atomic):**

1. **Allocate edge-BVs.** In `populateBoundVerts`, gated by `bv.selCount
   == 1 && valence == 4` (start narrow; extend to higher even valences
   in a follow-up phase). For each non-bev EH that is NOT one of the
   two flanking the bev, append a BoundVert at `origPos + slideDir(eh) *
   width`. Set `eh.leftBV = eh.rightBV = newBVidx` (non-bev EHs have
   `leftv == rightv` in Blender's invariant — `bmesh_bevel.cc:3013`).
2. **Propagate ownership to flanking EHs.** Phase 1 wedge population
   leaves flanking EHs with `leftBV/rightBV = -1` on their non-wedge
   side. Set those to point at the SAME wedge BV that owns the flanking
   side of the bev edge (Blender's `e->prev->leftv = e->prev->rightv =
   bndv`, `bmesh_bevel.cc:3037`/`3054`). Concretely: for v_21 with bev
   at EH 3, `eh[2].rightBV = bnd[0]` (= rightBV of bev) and
   `eh[0].leftBV = bnd[1]` (= leftBV of bev = reused). After this, every
   non-bev EH has both `leftBV` and `rightBV` set to a single BV.
3. **Switch F_OTHER replacement to splice-2 keyed by face walking
   direction.** At each F_OTHER corner identified by `bv.edges[k].fnext`:
   walk the face to find `eprev` (the EH on the face's incoming side at
   `bv.vert`) and `e` (outgoing side). vstart = the EH's owning BV on
   the incoming side; vend = the EH's owning BV on the outgoing side.
   Splice `[vstart.vertId, vend.vertId]` at the `bv.vert` slot. For
   non-bev EHs (where leftv==rightv) the lookup is unambiguous;
   shared-edge symmetry across two F_OTHERs is automatic because both
   read the same EH's BV.
4. **Re-route `materializeBackCapEvenValence`'s third vertex** from
   `mesh.edgeOtherVertex(oppEh.edgeIdx, bv.vert)` (cube neighbour) to
   `bv.boundVerts[oppEh.leftBV].vertId` (the edge-BV) when Phase 2 has
   set the field. The function stays — Blender emits an equivalent
   triangle at this position.

**Test impact:**
- `test_bevel_valence4.d`: assertion shifts from `vertexCount==28,
  faceCount==27, nTri==2, no faces with ≥5 verts` to `vertexCount==30,
  faceCount==27, nTri==2, exactly 4 pentagons + 21 quads`. The "no ≥5"
  assertion was anti-regression for the original 5-vert splice bug; with
  Phase 2 we EXPECT 4 pentagons by design, so that anti-regression check
  must invert. Manifold check stays.
- `test_bevel.d` (selCount=1 valence=3): zero drift — Phase 2 gate is
  `valence==4`.
- `test_bevel_corner.d` (selCount=2 valence=3): zero drift — gate is
  `selCount==1`.
- `test_bevel_rebevel.d`: needs re-measurement (cumulative changes from
  16 BvVerts × 2 endpoints in CC²). The invariant checks (no
  self-loops, no dup-vert faces, no coincident pairs) should continue
  to pass; boundary count may change.
- `test_bevel_capseg_rebevel.d`: still XFAIL; closing it is Phase 4.

**Validation:** `tools/blender_diff/cases/cc_valence4_single_edge.json`
flips from XFAIL → XPASS once Phase 2 lands. That's the canonical
"Phase 2 done" signal.

(Original Phase 2 description retained below as the historical narrow
plan that didn't survive contact with reality. My v1 REVISED is also
archived — both got the strip shape wrong.)

### Phase 2 (original, archived) — Allocate edge-owned BVs for non-bev EHs at `selCount=1 valence ≥ 4` only

Goal: First narrow case where Blender allocates an extra BV: at
`selCount=1, valence ≥ 4`, every non-bev EH gets its own BV ON the non-bev
edge at slide-distance from `v_orig`. This is the root cause of the
back-cap workaround, and it's the smallest topological change that lets us
remove `materializeBackCapEvenValence`.

Deliverables:
- `source/bevel.d` `populateBoundVerts` (after wedge BVs are appended,
  ~`source/bevel.d:847`): for every non-bev EH that is NOT one of the two
  flanking the bev EH (= EHs in indices `bevEdgeIdx ± 1` mod N), allocate a
  new `BoundVert`:
  - `pos` = `v_orig + slideDir(eh) * w`, where `w` is the slide distance
    consistent with neighbouring bev EHs (use the bev EH's
    `offsetLSpec`/`offsetRSpec` — same convention as `materializeTriFanEndpoint`
    at `source/bevel.d:1389`).
  - `slideDir` = unit vector from `v_orig` toward the EH's other endpoint,
    times that scalar slide distance (so position formula in
    `updateEdgeBevelPositions` at `source/bevel.d:646` stays linear in
    width).
  - `ehFromIdx = ehToIdx = ehIdx` (degenerate wedge → marker for "edge-BV").
  - `face = ~0u`, `isOnEdge = true`, `aliasOf = -1`.
  - `eh.leftBV = eh.rightBV = newBVidx`.
- `materializeBevVert` (`source/bevel.d:1209-1216`): allocate a fresh mesh
  vertex for each edge-BV (`!reusesOrig` path already covers it; verify no
  alias-merge collapses it).
- `materializeBevVert` F_OTHER replacement loop (`source/bevel.d:1275-1338`):
  for each F_OTHER face around `bv.vert`, replace `v_orig` with the corner
  BV. The corner is between EHs `k` and `(k+1)%N`. Resolve which BV via
  `bv.edges[k].leftBV` (Blender's `eprev->rightv` ↔ vibe's CCW direction:
  needs careful sign verification — write a unit-style comment on which
  index of `EdgeHalf.leftBV/rightBV` corresponds to which face side; pick
  ONE convention and assert it in the debug block).
- Delete the `materializeBackCapEvenValence` call site
  (`source/bevel.d:1363-1367`) — leave the function body in place but
  unreferenced for now (deleted in Phase 5). The `EH_b` hole is now closed
  by F_OTHER faces seeing the same edge-BV via shared `leftBV`/`rightBV`.

Files touched:
- `source/bevel.d` (allocation in `populateBoundVerts`, lookup in
  `materializeBevVert`'s F_OTHER replacement loop).
- `tests/test_bevel_valence4.d`: numeric assertion update.
  - Pre-refactor: 28V / 27F (24 quads + 1 strip + 2 back-cap tris).
  - Post-Phase-2: 30V / 29F? — depends on whether we still emit the strip
    quad on the bev edge plus the two new edge-BVs replacing the back-cap
    vertices. Recompute: each endpoint adds one more BV per non-flanking
    non-bev EH = 2 extra non-flanking non-bev EHs at valence-4 (4 EHs - 1
    bev - 2 flanking = 1) per endpoint = 1 per endpoint = 2 total extra
    BVs. Total V = 28 + 2 = **30V**. F count: -2 back-cap tris, no extra
    faces (the back-cap hole is now closed by F_OTHER replacement) = 24
    quads + 1 strip = **25F**.
  - The "no 5-vert face" and "manifold" assertions stay; the "exactly 2
    triangles" assertion **must be removed/inverted** (we now expect 0
    triangles).

Test impact: `test_bevel_valence4.d` numbers shift; rest of suite is
selCount=1 valence=3 (no extra non-flanking EHs → no new BVs → no change),
or selCount ≥ 2 (out of scope this phase, see invariant guard below).

**Invariant guard during this phase**: in `populateBoundVerts`, gate the
new BV allocation behind `bv.selCount == 1 && valence >= 4`. All other
configurations skip it. This is the explicit "phase still works" knob.

Validation: `./run_test.d --no-build` green after the
`test_bevel_valence4.d` edit.

Rollback: revert the gated allocation block + the F_OTHER lookup change +
re-enable the back-cap call. The diff is tightly scoped to one feature
flag.

### Phase 3 — Extend edge-owned BVs to `selCount=1 valence=2` (TRI_FAN)

Goal: The TRI_FAN endpoint case (`source/bevel.d:1346-1350,1384-1446`)
already allocates a `tipPos` vertex on the non-bev edge — that IS Blender's
edge-BV, just open-coded inline. Fold it into the unified edge-BV path so
Phase 5's deletions get bigger.

Deliverables:
- `populateBoundVerts`: extend the Phase 2 allocation to also fire at
  `selCount == 1 && valence == 2`. Both EHs are present; one is bev, one
  isn't. Allocate the edge-BV on the non-bev EH (this replaces what
  `materializeTriFanEndpoint` calls `tipVid`).
- `materializeTriFanEndpoint`: replace the inline `mesh.addVertex(tipPos)`
  + `tipVid` with a read of `bv.boundVerts[bv.edges[nonBevEh].leftBV].vertId`.
  The face-splice + fan-emission loops are unchanged.
- `updateEdgeBevelPositions`: the new edge-BV is a proper BoundVert so its
  `slideDir`-based update at `source/bevel.d:643-647` covers it
  automatically. Verify by inspecting `tipPos` formula
  (`source/bevel.d:1393`): `origPos + nonBevDir * w` matches
  `origPos + slideDir * 1.0` where `slideDir = nonBevDir * w`. Match.

Files touched:
- `source/bevel.d` (`populateBoundVerts`, `materializeTriFanEndpoint`).

Test impact: Cube doesn't have valence=2 vertices natively; the only
existing valence=2 tests are in `test_bevel_profile.d` for tetrahedron-like
geometry — confirm it doesn't exist in the suite (search for "valence=2"
assertions). If a count assertion shifts (because the `tip` vertex now
counts as a `BoundVert` exposed via `/api/bevvert`), update
`test_bevel_bevvert.d` accordingly. **Estimated impact: 0–1 file.**

Validation: `./run_test.d --no-build` green.

Rollback: revert `materializeTriFanEndpoint` change; the `tipVid`
allocation goes back inline.

### Phase 4 — `selCount ≥ 2`: edge-owned BVs at non-bev EHs (compose with alias-merging)

Goal: The most delicate phase. At `selCount ≥ 2`, the existing alias-merge
code (`source/bevel.d:854-880`) already collapses two corner BVs that
slide on the SAME non-bev edge into one mesh vertex — that's exactly the
Blender invariant `e->leftv == e->rightv == bndv` for a non-bev edge,
arrived at through a different path. We need to make the new edge-BV
allocation produce the same result without double-allocating.

Deliverables:
- `populateBoundVerts`: extend allocation gate to all `selCount ≥ 2` cases
  except `MiterPattern.Arc + reflex` (which has its own positioning logic
  in the Arc patch branch at `source/bevel.d:887-898`).
- For each non-bev EH at `selCount ≥ 2`:
  - If the alias-merge logic at `source/bevel.d:854-880` would already
    collapse the two flanking wedge BVs onto a single mesh vertex on this
    EH, REUSE that wedge BV as the edge-BV (set `eh.leftBV = eh.rightBV =
    that wedge BV idx`). No new allocation. The existing merge gives us
    exactly the Blender topology.
  - Otherwise (rare: when the two wedge BVs do NOT merge — e.g. a sharp
    miter at `source/bevel.d:901-937` where one BV is moved onto `bv.vert`
    and the other slides freely), choose the wedge BV that lives on the
    non-bev EH as the edge-BV. Document the case with a comment cross-
    referencing `bmesh_bevel.cc:3060` (Blender's terminal-edge analogue).
- For bev EH at `selCount ≥ 2`: `eh.leftBV` / `eh.rightBV` map to the two
  flanking corner wedge BVs (whichever face is on each side of the bev
  edge). Same as Phase 1, just verified to match each face's corner
  resolution.
- `applyEdgeBevelTopology` strip emission (`source/bevel.d:437-440`):
  switch from `boundVertIdxForEh{,To}` to `bv.edges[ehIdx].leftBV` /
  `bv.edges[ehIdx].rightBV`. This is a one-line semantic swap with the
  payoff: `qA_l/qA_r` now name the bev edge's left/right side directly,
  not "wedge CCW-after the EH" / "wedge CCW-before".
- `materializeBevVert` cap polygon (`source/bevel.d:355-414`): when
  collecting `capBvs` at line 357-360, the iteration over BVs is unchanged
  (alias-merged BVs still get skipped). Verify the cap polygon's vertex
  ordering still matches the bev-strip cross-section ordering — adding
  edge-BVs that are alias-targets of wedge BVs doesn't reorder the ring.

Files touched:
- `source/bevel.d` (`populateBoundVerts`, `applyEdgeBevelTopology` strip
  call, `materializeBevVert` cap polygon path verification only).
- Possibly `tests/test_bevel_corner.d`: `selCount=2 valence=3 seg=2`
  vertex count is currently 14 (line 274). With the Phase-4 change the
  alias-merge should produce IDENTICAL vertex count if reuse is correctly
  wired. **If the count drifts, the alias reuse logic is wrong** — that's
  the failure signal, not a test to update.
- `tests/test_bevel_corner.d`: `selCount=3 valence=3` (cube corner) tests
  — same reasoning. Cube-corner cap M_ADJ uses bev-only EHs (every EH is
  bev), so non-bev edge-BV allocation is a no-op. No expected drift.

Test impact: ideal case is **zero** test edits. Any drift = bug, fix it
before declaring the phase done.

Validation: `./run_test.d --no-build` green. Re-run with `-v
test_bevel_corner` and `-v test_bevel_rebevel` to spot-check stderr for
the Phase 0 invariant trap (which now MUST be silent — the wedge-side and
edge-side fields must agree).

Rollback: revert the `applyEdgeBevelTopology` lookup swap (single-line
change). The new edge-BVs still exist but only as data — no consumer
reads them. Tests pass with the wedge-side strip semantics.

### Phase 5 — vid-based non-degenerate-profile selection (2026-04-30, ✅ done)

**Outcome**: A 2-line semantic change to `materializeBevVert`'s
`leftBVidxAlloc` selection and `applyEdgeBevelTopology`'s `capSamples`
helper closes the residual `test_bevel_capseg_rebevel_seg2` XFAIL.
The full architectural port of `bev_rebuild_polygon` was NOT needed —
the underlying issue was simpler than Phase 4 left it looking.

**The bug**: at `selCount=2 valence=4` with alternating bev/non-bev
EHs (e.g., interior of a polyline rebevel where the cube corner from
1st bevel has been turned into selCount=2 valence=4 by the 2nd pass),
the BoundVert ring has 4 BVs that pair-collapse via `aliasOf` into 2
unique mesh vertices. The OLD `leftBVidxAlloc` selection skipped any
aliased BV and required `nextI` not aliased back to `i`. With all 4
BVs in alias chains this fell through to the wedge fallback
(`boundVertIdxForEh(bv, bevEdgeIdx)`), picking a BV whose forward
profile was geometrically degenerate (start.vertId == end.vertId)
because both endpoints alias-merged onto the same mesh vertex.

The strip emission then read this degenerate profile as the
cross-section at the v_6 end of bev edge `(v_2, v_6)`. The result was
a strip face that included `v_6` directly (instead of `v_6`'s corner
BVs), producing boundary edges `(v_2, v_6)` and `(v_6, v_17)` that
no other face shared.

**The fix** (atomic, ~10 lines):

1. **`materializeBevVert` `leftBVidxAlloc` selection** (`source/bevel.d:1414-1421`):
   replace the `aliasOf >= 0` skip rule with a vid-based degeneracy
   check. Allow aliased BVs as candidates; reject only when
   `bv.boundVerts[i].vertId == bv.boundVerts[(i+1)%M].vertId` (=
   the cap arc would collapse to a point).

   For `selCount=2 valence=4` alternating with aliases `[1→0, 3→2]`:
   BV[1].vid = BV[0].vid (alias) but BV[1].profile.end = BV[2].vid
   (fresh) → non-degenerate. The new check picks BV[1] (or BV[3]) as
   `leftBVidxAlloc`, allocating MIDs along the cross-corner arc.

2. **`applyEdgeBevelTopology` `capSamples`** (`source/bevel.d:500-538`):
   apply the same vid-based selection rule. Then resolve qL/qR
   matching against the chosen leftBV's profile by comparing
   `leftBV.profile.sampleVertIds[0]` and
   `leftBV.profile.sampleVertIds[$-1]` against `qL.vertId` and
   `qR.vertId` (not by index equality). When `leftBV` is aliased, its
   `profile[0]` may be the alias target's vid — so vid equivalence is
   the right join key.

**Why this works**: the cross-corner cap arc IS the geometric profile
that the strip needs at this endpoint. By making the alias-resolved
vertex-id the equivalence key (instead of strict aliasOf<0 + alias
chain rejection), we let the existing super-ellipse profile machinery
compute the correct cap arc. The MIDs land in the right plane, and
the strip ladder + F_OTHER absorbing share consistent interior verts.

**Test impact**:
- `test_bevel_capseg_rebevel_seg2.d`: XFAIL → PASS (asserts manifold
  closure, zero boundary edges).
- `cube_corner2_seg3_rebevel_polyline_seg2` Blender diff: topology now
  bit-for-bit matches Blender (27V/20F, arity {4:16, 7:2, 6:2}).
  Remaining XFAIL is geometric drift only (~0.005-0.012), the same
  residual as `cube_corner2_seg6_rebevel_polyline` — a separate
  non-topological bevel-position issue.
- All 25 unit tests + 24/28 Blender diff cases PASS.

**Validation**: `./run_test.d --no-build` → 25/25 PASS.

### Phase 5 (original, archived) — port `bev_rebuild_polygon`

The original Phase 5 plan (full architectural port of Blender's
`bev_rebuild_polygon`) was based on the assumption that the
splice-direction had to be face-walking-keyed — which Phase 2-4 had
already partially achieved. It turned out the residual issue was a
narrow alias-resolution detail in two helper functions, not a
structural mismatch. The architectural rewrite remains a possible
future direction (e.g., for `octahedron_tip` topology drift) but is
not required to close the capseg_seg2 case.

**Goal**: port Blender's `bev_rebuild_polygon` (walking-direction-keyed
face splice) to replace vibe3d's wedge-based F_OTHER fullSplice +
materialize face replacement. This closes the residual XFAIL'd cases
that Phase 4's non-bev EH ownership propagation alone can't reach.

**Why Phase 4 alone is not enough.** Phase 4 force-aliases two flanking
wedge BVs onto a single canonical when both flank the same non-bev EH
at `selCount ≥ 2`. That produces Blender's `e->leftv == e->rightv`
invariant for the non-bev EH at the wedge level. **But the splice that
materializeBevVert performs into F_OTHER faces still uses the
wedge-model insertion order** (`cap.sampleVertIds` reversed; pinned to
`leftBVidxAlloc`'s profile), which doesn't always match the face's CCW
walking direction. For multi-segment cap profile (`seg ≥ 2`) on a
1st-bevel-modified F_OTHER (e.g., a hepta inherited from a previous
bevel pass), the inserted interior cap samples produce edges whose
direction disagrees with the strip face's cap-chain ladder (or the
adjacent bev-containing face's corner replacement) — yielding boundary
edges that look like "missing cap-at-v triangles" between
`(endpoint_slid, mid_sample, OTHER_endpoint_slid)`.

**Reproducer.** `tests/test_bevel_capseg_rebevel_seg2.d` (XFAIL today):
cube → bevel `[5,6]` width=0.165 seg=3 → polyline rebevel
`[16,21,23,24]` width=0.05 **seg=2** leaves 6 boundary edges (2
triangles at polyline endpoints `v_2` and `v_8`). Compare with the
seg=1 sister `test_bevel_capseg_rebevel.d` which closes manifold.
Blender on the same case (`tools/blender_diff/cases/cube_corner2_seg3_rebevel_polyline_seg2.json`)
emits **+1V, +2F** relative to vibe3d — the missing cap structure.

**Blender's mechanism** (`bmesh_bevel.cc:6801-6994`):

```c
static bool bev_rebuild_polygon(BMesh *bm, BevelParams *bp, BMFace *f) {
    BM_ITER_ELEM (l, &liter, f, BM_LOOPS_OF_FACE) {
        if (BM_elem_flag_test(l->v, BM_ELEM_TAG)) {
            // l is at a beveled vertex; e is l->e, eprev is l->prev->e
            // Determine go_ccw by inspecting whether e->prev == eprev
            // (= face walks CCW around bv) or eprev->prev == e (= CW).
            if (go_ccw) { vstart = eprev->rightv; vend = e->leftv; }
            else        { vstart = eprev->leftv;  vend = e->rightv; }
            // Walk the BoundVert ring from vstart to vend, traversing
            // cap-arc interior samples mesh_vert(vm, i, 0, k) for each
            // BoundVert with a non-null ebev. Append all samples to vv[]
            // in walk order. Skip duplicates at junction points.
        } else {
            vv.append(l->v);  // unchanged corner
        }
    }
    // Replace face f with bev_create_ngon(vv, ee).
}
```

This **replaces the entire face** rather than splicing a single corner
in place. Crucially the walking direction is determined per-face
(go_ccw), so each F_OTHER picks up the cap chain in the orientation
that matches its CCW boundary — the strip face on the other side
necessarily picks up the SAME cap-arc samples in the opposite winding
because they read from the same `mesh_vert(vm, i, 0, k)` array.

Vibe3D's `materializeBevVert` (`source/bevel.d:1411-1459`) does in-place
face mutation via `replaceVertInFace` / `spliceInManyAtCorner` with the
splice direction hardcoded as `cap.sampleVertIds[seg - j]` (always
reversed). When the face's natural CCW walk happens to disagree with
that reversal (which it does for one of the two F_OTHERs sharing a
non-bev edge through `bv.vert` in multi-seg multi-edge polyline
scenarios), the inserted edges don't share with the strip's cap chain.

**Phase 5 deliverables (atomic refactor):**

1. **Add `bevRebuildPolygon(Mesh*, ref BevelOp, uint faceIdx)`** to
   `source/bevel.d`. Mirror of `bev_rebuild_polygon`. Walks `mesh.faces[faceIdx]`,
   detects beveled vertices via the snapshot-faces table or a fresh
   `bool[uint] beveledVerts` set, and at each beveled corner picks
   `vstart`/`vend` from `EdgeHalf.leftBV`/`rightBV` (which Phase 1-4
   have already populated correctly). Walks the BoundVert ring from
   vstart to vend collecting `bnd.profile.sampleVertIds` interior
   samples in walk order. Calls `mesh.faces[faceIdx] = newVerts`.

2. **Replace the `materializeBevVert` face-replacement loop**
   (`source/bevel.d:1402-1459`) with a single per-face dispatch into
   `bevRebuildPolygon`. The branchy `fullSplice` / `single-side BV` /
   `splice-2` paths all collapse to one walk.

3. **Rename `materializeBackCapEvenValence` → `materializeCapAtVPolygon`**
   and re-purpose it as the explicit `bevel_build_poly` / `M_TRI_FAN`
   analogue at vertices with `vm->count >= 3` where Blender emits the
   ngon connecting all BoundVerts CCW. For `selCount=1, valence=4`
   it's the existing back-cap triangle. For other `vm->count >= 3`
   configurations (Phase 2/3 territory once ported fully), it emits
   the (vm->count)-gon.

4. **Decide go_ccw per face** by checking whether `eprev->next == e`
   (Blender convention) using the BvVert's own EdgeHalf ring. The
   logic is short — see `bmesh_bevel.cc:6822-6846`.

5. **Drop the snapshot/restore mechanism**
   (`source/bevel.d:FaceSnap` infrastructure) once the rebuild is
   atomic. Phase 5 takes ~2 days of careful work; budget accordingly.

**Test impact.** Significant test churn expected:
- `test_bevel_valence4.d`: numbers may shift (currently 30V/27F; Blender
  is also 30V/27F so should stay).
- `test_bevel_capseg_rebevel_seg2.d`: XFAIL → PASS (the goal).
- `test_bevel_corner.d`, `test_bevel_offset_meet.d`: BoundVert positions
  are unchanged; face shapes might re-order vertices in the array (still
  same set, manifold). Update assertions to be set-based not order-based.
- `test_bevel_rebevel.d`: residual boundary count from
  `doc/bevel_rebevel_fix_plan.md` (16 boundary edges from 1st-pass
  overshoot) may close further.

**Validation cascades (in order).** Each line is a stop-on-fail gate:
1. `./run_test.d --no-build test_bevel` — single-edge cube must stay clean.
2. `./run_test.d --no-build test_bevel_corner` — selCount=2,3 valence=3.
3. `./run_test.d --no-build test_bevel_valence4` — selCount=1 valence=4.
4. `./run_test.d --no-build test_bevel_capseg_rebevel` — Phase 4 case must stay closed.
5. `./run_test.d --no-build test_bevel_capseg_rebevel_seg2` — the goal: XFAIL → PASS.
6. `tools/blender_diff/run.d --no-build` — full suite, no regressions on PASS cases.

**Rollback.** This is a structural rewrite — full revert is the only
clean rollback. Keep the wedge-based `replaceVertInFace` /
`spliceInManyAtCorner` paths in a separate commit so they can be
re-instated atomically.

### Phase 5 (original, archived) — Simplify F_OTHER branch and dead wedge code

(Original Phase 5 description below — superseded by Phase 5 REVISED
once the capseg_rebevel_seg2 investigation showed the splice direction
is the actual blocker. The cleanups below are now Phase 6 work.)

Original goal: Now that Phase 4 routes F_OTHER replacement through
`eh.leftBV` / `eh.rightBV` keyed by face walking, the branchy
"fullSplice vs single-side" logic at `source/bevel.d:1308-1323` (which
existed because wedge BVs are sparse) collapses to a single splice-2
path. `materializeBackCapEvenValence` STAYS — Blender's diff confirmed
the cap-at-v triangle is part of the canonical Phase-2 output, not a
workaround.

Original deliverables:
- `source/bevel.d`: simplify the F_OTHER replacement loop. With
  edge-BVs present at every non-bev EH and Phase 4's face-walking-keyed
  splice, the loop becomes "splice `[eprev.rightBV, e.leftBV]` at the
  corner".
- Rename `materializeBackCapEvenValence` → `materializeCapAtVPolygon`.
- Audit `boundVertIdxForEh` / `boundVertIdxForEhTo` usages.

### Phase 6 — Cleanup: rename, drop dead helpers, update docstrings (2026-04-30, ✅ done)

Goal: Cosmetic + final-documentation pass. Aligns naming with
`bmesh_bevel.cc` so future ports map directly.

What was done:
- `source/bevel.d`:
  - Renamed `boundVertIdxForEh` → `bvIdxFromEhLeft` and
    `boundVertIdxForEhTo` → `bvIdxFromEhRight` (mirror Blender's
    `e->leftv` / `e->rightv` convention).
  - Renamed `materializeBackCapEvenValence` → `materializeCapAtVPolygon`
    + updated docstring (Blender diff confirmed it is not a workaround,
    it is the canonical cap-at-v polygon Blender always emits here —
    `bevel_build_poly` analogue for the M_POLY case).
  - Removed dead helpers `leftEhIdx` / `rightEhIdx` / `spliceInTwoAtCorner`
    (no callers post-Phase-5).
  - Removed the dormant Phase-0 wedge-vs-edge-side disagreement trap
    (#4 in the debug invariant block) — Phase 4 deliberately overrides
    these fields, so the trap detected intended behavior, not bugs.
    The remaining 3 invariants (no repeated face verts, no self-loops,
    no two non-aliased BVs on same mesh vert) are kept.
  - Added module-level docstring with file:line cross-refs to
    `bmesh_bevel.cc` (`build_boundary` 2974, `bev_rebuild_polygon` 6801,
    `bevel_build_poly` 5946, etc.).

What was NOT done (deferred):
- `BoundVert.face`, `ehFromIdx`, `ehToIdx` are KEPT — they have many
  consumers (`materializeArcMiterPatch`, alias-merge slide-EH detection,
  `computeProfile` face normal, `materializeTriFanEndpoint`, JSON
  serialization in `app.d` for `/api/bevvert`). The Phase 6 plan
  speculated dropping them; the audit shows that's a separate larger
  refactor (move face derivation into a helper, change Arc miter
  c00/c20 lookup to use EH pairs, rebuild JSON schema with deprecation
  note). Out of scope for the cleanup pass.
- `tests/test_bevel_offset_meet.d` edge-BV slideDir-mag assertion
  addition — existing assertions hold; the suggested "perpDist > 0"
  assertion is additive nice-to-have, not a regression risk.

Validation: `./run_test.d --no-build` → 25/25 PASS, no test edits
required. `git diff --stat` for Phase 6 alone is small (renames +
dead-code removal); the full `bevel.d` post-refactor remains larger
than pre-refactor (Phase 0-4 added significant logic for edge-BV
allocation and Phase 4 propagation), as expected.

Files touched:
- `source/bevel.d`, `source/http_server.d`, `tests/test_bevel_offset_meet.d`.

Test impact: light, additive only.

Validation: full suite green. Stderr clean. `git diff --stat` between
HEAD and the start of Phase 0 should show `source/bevel.d` net **smaller**
by ~80 lines, with `tests/test_bevel_valence4.d` the only test with
shifted numeric assertions.

Rollback: pure rename / docstring revert. Zero functional risk.

---

## Risk register

1. **F_OTHER face winding sign error in Phase 2.** Replacing `v_orig` in a
   F_OTHER face with `eh.leftBV` vs `eh.rightBV` requires picking the
   right side. If we pick wrong, the face's CCW winding inverts, which
   breaks the manifold check in
   `tests/test_bevel_valence4.d:108` and `tests/test_bevel.d:78`.
   *Mitigation*: write a 6-line decision table mapping `(EH index in CCW
   ring, which face it bounds, which BV index)` to its `leftBV`/`rightBV`,
   verify against the cube edge-0 valence-3 case BY HAND before code, and
   keep Phase 0's invariant trap firing on disagreement.

2. **Alias-merge double-counts the new edge-BVs in Phase 4.** If the new
   edge-BV is allocated separately from the wedge BV that the alias-merge
   would have produced, vertex count drifts up at `selCount ≥ 2` and
   `tests/test_bevel_corner.d:274` (`expected 14 vertices`) fails.
   *Mitigation*: Phase 4's "REUSE that wedge BV" rule must come BEFORE
   any new allocation. Add a debug-only assertion in
   `applyEdgeBevelTopology` that no two distinct BVs at the same BevVert
   have coincident positions (similar to the existing invariant 3 at
   `source/bevel.d:612-625`).

3. **`MiterPattern.Arc` reads `BoundVert.face`** (`source/bevel.d:1674-1676`).
   If we drop `face` in Phase 6 the arc-miter patch breaks.
   *Mitigation*: Phase 6 explicitly audits this; either keep `face` or
   rewrite `materializeArcMiterPatch` to derive the face from the
   `c00Idx`/`c20Idx`/`bevBVidx` triple's flanking EHs. Defer rewrite to a
   follow-up if it expands Phase 6 too much.

4. **Re-bevel topology corruption.** `tests/test_bevel_rebevel.d` already
   exercises a path where the input mesh has bev-cap geometry from a
   previous pass. The Phase 4 alias-merge interaction with second-pass
   non-bev EHs (which used to be bev EHs!) could produce a different
   collapse pattern than today.
   *Mitigation*: run `./run_test.d -v test_bevel_rebevel` after every
   phase that touches `populateBoundVerts`. The numeric assertions at
   `tests/test_bevel_rebevel.d:148-150` are tight (98V/192E/96F) — any
   drift is a regression. The acceptable change is *zero*.

5. **`updateEdgeBevelPositions` overwrite of edge-BVs.** The new edge-BV's
   `slideDir` is `unitDir * w` (already pre-scaled), so the runtime
   formula `bv.origPos + bnd.slideDir * width` at `source/bevel.d:646`
   would scale by `width^2` if we don't divide out `w` first.
   *Mitigation*: pick a convention up front — store `slideDir` as a unit
   vector with a separate per-BV scale, OR include the per-edge
   `widthCoefficient` factor in `slideDir` so `width` is the linear
   scalar (matches what `materializeTriFanEndpoint`'s tipPos formula
   does at `source/bevel.d:1393`). Audit `updateEdgeBevelPositions`
   formula to ensure the convention is consistent across BVs of all
   provenances.

6. **HTTP `/api/bevvert` JSON drift.** Tests like
   `tests/test_bevel_offset_meet.d:101-102` enumerate `boundVerts` and
   filter on `isOnEdge`. Adding new edge-BVs (each with `isOnEdge=true`)
   changes how many BVs the filter matches — the test currently expects
   exactly one match for the BEV-BEV BV, which still holds (it filters
   for `!isOnEdge`). But test code that iterates over all BVs (e.g.
   slideDir-magnitude check at `tests/test_bevel_offset_meet.d:135-141`)
   needs to keep working — every isOnEdge BV's slideDir magnitude must
   stay 1.0 (or the test asserts a different invariant if we choose the
   pre-scaled convention from Risk 5). *Mitigation*: Risk 5 decision
   determines this. Document the chosen convention in the Risk 5 audit
   note and update the test's slideDir-magnitude expectation in Phase 6
   if needed (one assertion).

7. **BevelOp serialization in test fixtures (none today, but watch).**
   `BevelOp` isn't serialized over HTTP — no tests crack open the struct
   directly. Confirmed by grep: no test imports `bevel.d`. *Mitigation*:
   none required, just verified.

---

## Rollback plan (per phase)

Each phase is structured so its ENTIRE behavioral effect can be reverted
with `git revert <phase commit>` without touching subsequent phases that
depend on it — because each subsequent phase EITHER strictly extends the
previous OR is itself revertable (Phase 5 deletions are reintroduceable
from git history).

- **Phase 0**: revert debug log addition. No-op in release.
- **Phase 1**: revert `populateBoundVerts` tail + JSON additions; field
  values stay unread.
- **Phase 2**: revert the gated allocation + F_OTHER lookup change +
  re-wire `materializeBackCapEvenValence`. The function body still exists.
- **Phase 3**: revert `materializeTriFanEndpoint` to inline `tipVid`.
- **Phase 4**: revert the strip lookup swap + the `selCount ≥ 2`
  allocation gate. Edge-BV fields stay populated but ignored.
- **Phase 5**: re-add `materializeBackCapEvenValence` + the F_OTHER branch
  logic from git. The strip swap stays (Phase 4-rooted).
- **Phase 6**: pure cosmetic; revert renames if needed.

If Phase 4 produces stubborn manifold violations and root-causing exceeds
the allotted session, freeze at Phase 3 (which is already a coherent
intermediate state: `selCount=1` fully ported, `selCount ≥ 2` still
wedge-based). The back-cap is gone, vibe3d is closer to Blender, and
`selCount ≥ 2` continues to use the alias-merge model that works today.

---

## Acceptance criteria

The refactor is complete when ALL of the following hold:

1. `./run_test.d` (full suite, fresh build) green.
2. `materializeBackCapEvenValence` renamed to `materializeCapAtVPolygon`
   (Blender diff confirmed it's a real cap face, not a workaround) and
   reads its third vertex from the back-EH's edge-BV via
   `bv.edges[oppEhIdx].leftBV`.
3. `populateBoundVerts` allocates one BV per incident EH at all
   `selCount ≥ 1` configurations except `MiterPattern.Arc + reflex`.
   Verify by reading the function and checking gating predicates.
4. `applyEdgeBevelTopology` F_OTHER replacement reads
   `eh.leftBV`/`eh.rightBV` keyed by face walking direction (not BvVert
   ring k/knext). Strip emission stays unchanged (4-vert quad per
   beveled edge). Verify by `git grep boundVertIdxForEh source/bevel.d`
   returning 0 outside the Phase-0 invariant probe.
5. `tools/blender_diff/cases/cc_valence4_single_edge.json` flips from
   XFAIL to XPASS (= Blender geometry agreement on Phase 2).
6. `tools/blender_diff/cases/cube_corner2_seg6_rebevel_polyline.json`
   flips from XFAIL to XPASS (= Phase 4).
7. `tests/test_bevel_valence4.d` updated to expect 30V / 27F with
   arity {4: 21, 5: 4, 3: 2} (4 F_OTHER pentagons + 2 cap-at-v
   triangles + 21 quads).
8. The `/api/bevvert` JSON schema remains backward-compatible with all
   existing test consumers (no removed top-level keys; new keys are
   additive only).
9. Stderr (vibe3d.log) shows zero `[bevel-violation]` lines under the
   full test run.
10. `git diff --shortstat` (refactor branch vs. main) shows
    `source/bevel.d` net SMALLER (target: 50+ lines deleted, primarily
    from the F_OTHER branch simplification — back-cap function stays
    but gets shorter).

---

## Out of scope (do not touch)

- The `MiterPattern.Arc` patch geometry in `materializeArcMiterPatch`
  (`source/bevel.d:1510-1702`). It uses its own `c00Idx`/`c20Idx`/`bevBVidx`
  resolution; we adapt the BV allocation gate to skip it (Phase 4) but
  do not redesign it.
- The M_ADJ canonical cap pipeline (`source/bevel.d:1712-2467`,
  `materializeBevVertMAdj`/`overrideCubeCornerCap`/`materializeAdjCapGeneric`).
  M_ADJ runs only when `isAllBevAtVert(bv)` is true — every EH is bev,
  there are no non-bev EHs to allocate edge-BVs on, so the refactor is a
  no-op there by construction.
- `Mesh.weldCoincidentVertices` and the `apply()` post-pass in `mesh.d`
  (per `doc/bevel_rebevel_fix_plan.md` Step 4). The refactor must not
  rely on it for correctness; it remains as a defense-in-depth pass.
- The `BevelWidthMode` UX, `widthCoefficient`, `computeLimitOffset`. The
  refactor preserves their semantics 1:1.
- Any new bevel feature (custom profile presets, vertex bevel,
  harden-normals, UV blending, etc.).
- BevelTool / handler.d / app.d. Pure `bevel.d` + tests + http_server.d
  refactor.

---

## Test-assertion sensitivity table (filled during Phase 0)

*This table to be populated during Phase 0 by reading each test and
classifying each numeric assertion. Skeleton below; rows added in Phase 0.*

| Test file | Assertion (line) | Configuration | Sensitive to phase | Expected drift |
|---|---|---|---|---|
| test_bevel.d:51 | vertexCount == 10 | selCount=1 valence=3 | none | 0 |
| test_bevel.d:55 | faceCount == 7 | selCount=1 valence=3 | none | 0 |
| test_bevel_valence4.d:64 | vertexCount == 28 | selCount=1 valence=4 | Phase 2 | +2 → 30 |
| test_bevel_valence4.d:67 | faceCount == 27 | selCount=1 valence=4 | Phase 2/5 | -2 → 25 |
| test_bevel_valence4.d:87 | nTri == 2 | selCount=1 valence=4 | Phase 2/5 | → 0 |
| test_bevel_corner.d:182 | vertexCount == 13 | selCount=3 valence=3 cube corner | none | 0 |
| test_bevel_corner.d:204 | vertexCount == 20 | selCount=3 valence=3 seg=2 | none | 0 |
| test_bevel_corner.d:274 | vertexCount == 14 | selCount=2 valence=3 seg=2 | Phase 4 | 0 (alias-reuse must hold) |
| test_bevel_corner.d:299 | vertexCount == 38 | selCount=3 valence=3 seg=4 | none | 0 |
| test_bevel_offset_meet.d:101 | filter !isOnEdge → 1 match | selCount=2 valence=3 | Phase 4 | 0 (BEV-BEV BV unique) |
| test_bevel_offset_meet.d:140 | slideDir mag == 1 | isOnEdge BVs | Phase 5/Risk 5 | 0 if convention preserved |
| test_bevel_rebevel.d:148-150 | 98V/192E/96F | selCount=1 valence=4 ×16 + re-bevel | Phase 2/4 | 0 (target zero drift) |
| test_bevel_profile.d:47 | vertexCount == 16 | selCount=1 valence=3 seg=4 | none | 0 |
| test_bevel_profile.d:143-145 | 10V/15E/7F | selCount=1 valence=3 seg=1 | none | 0 |
| test_bevel_limit.d:60-63 | 10V/7F | selCount=1 valence=3 (clamp) | none | 0 |
| test_bevel_bevvert.d (selCount only) | selCount values | various | none | 0 |
| test_bevel_asymmetric.d | (re-audit Phase 0) | selCount=1 width asymmetry | none | 0 |
| test_bevel_width_modes.d | (re-audit Phase 0) | selCount=1 mode enum | none | 0 |

The Phase 0 deliverable is to walk each test and confirm the "Expected
drift" column. Any cell off by even ±1 vertex on a configuration we
weren't expecting to touch is a phase-blocking signal.
