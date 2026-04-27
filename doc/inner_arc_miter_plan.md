# Inner Arc Miter Implementation Plan (Stage 9e — final)

Closes the last XFAIL in `tools/blender_diff`: `lshape_reflex_inner_arc`.

## Goal

Match Blender's `bpy.ops.mesh.bevel(miter_inner='ARC', ...)` geometry at
reflex selCount=2 corners. Default (sharp) miter is already implemented;
arc miter inserts a (seg+1)² patch grid in the BEV-BEV face plane,
replacing the sharp meeting point with a curved 2D patch.

## Current state

Already done (commit `d6ecee0`):
- `MiterPattern { Sharp, Arc }` enum in `source/bevel.d`
- `BevVert.miterInner` field
- `MeshBevel.setMiterInner` + HTTP `"miter_inner": "arc"` param
- `populateBoundVerts` skips sharp-miter aliasing when `miterInner == Arc`

With API plumbing alone, vibe3d output for the test case:
`19v/13f` vs Blender's `24v/16f` (5 verts + 3 faces missing).

## Reference geometry (test case)

L-shape, bevel `[v3-v9, v3-v2]`, width=0.1, seg=2, miter_inner=ARC.
At v3 = (0, 0, +0.5):
- e1 = (1, 0, 0) (toward v2 = +X bev edge direction)
- e2 = (0, 0, -1) (toward v9 = -Z bev edge direction)
- BEV-BEV face = inner-bottom (y=0 plane, normal +Y)

### Patch in (e1, e2)·w coordinates from v3

```
        (0,1)  ──────  (0.5,0.5)  ──────  (1,0)
          │              │                  │
          │              │                  │
       (0.5,1.5) ──── (center) ─────── (1.5,0.5)
          │              │                  │
          │              │                  │
        (1,2)  ──────  (1.5,1.5)  ──────  (2,1)
```

3×3 grid, 9 verts, 4 quads. Grid in (a, b) ∈ {0, 1, 2} index space:

| (a, b) | unit-frame (e1, e2)·w | world coord | Blender vert |
|---|---|---|---|
| (0, 0) | (0, 1)·w | (0, 0, 0.4) | v[14] (= "BV inner-side along bev v3-v9") |
| (1, 0) | (0.5, 0.5)·w **on arc** | (0.029, 0, 0.471) | v[19] |
| (2, 0) | (1, 0)·w | (0.1, 0, 0.5) | v[15] (= "BV front-cap along bev v3-v2") |
| (0, 1) | (0.5, 1.5)·w **linear** | (0.05, 0, 0.35) | v[18] |
| (1, 1) | center (?) | (0.061, 0, 0.439) | v[17] |
| (2, 1) | (1.5, 0.5)·w **on arc** | (0.129, 0, 0.471) | v[20] |
| (0, 2) | (1, 2)·w | (0.1, 0, 0.3) | v[13] |
| (1, 2) | (1.5, 1.5)·w **on arc** | (0.129, 0, 0.371) | v[16] |
| (2, 2) | (2, 1)·w | (0.2, 0, 0.4) | v[12] |

### Geometry derivation

**4 grid corners** (verified exact):
- (a=0, b=0): v3 + 0·e1·w + 1·e2·w  ← non-BEV-BEV BV on inner-side, repositioned
- (a=2, b=0): v3 + 1·e1·w + 0·e2·w  ← non-BEV-BEV BV on front-cap, repositioned
- (a=0, b=2): v3 + 1·e1·w + 2·e2·w  ← far corner, "extended" along e2
- (a=2, b=2): v3 + 2·e1·w + 1·e2·w  ← BEV-BEV BV pushed to 2× offset along e1

**Inner arc** (a varies, b=0): quarter-circle radius w, **centered at**
`v3 + 1·e1·w + 1·e2·w` (= the standard perpendicular meet position):
- (0, 0): angle π     → v3 + 0·e1·w + 1·e2·w = (0,0,0.4)
- (1, 0): angle 5π/4  → v3 + (1 - cos π/4)·e1·w + (1 - sin π/4)·e2·w
  ≈ v3 + 0.293·e1·w + 0.293·e2·w
  = (0.029, 0, 0.471) ✓
- (2, 0): angle 3π/2  → v3 + 1·e1·w + 0·e2·w = (0.1,0,0.5)

**Outer arc** (a varies, b=2): quarter-circle radius w, **centered at**
`v3 + 2·e1·w + 2·e2·w` (= the "doubled meet" position):
- (0, 2): (1, 2)·w  ← endpoint, angle π from center
- (1, 2): center + radius w at angle 5π/4 = v3 + (2 - cos π/4)·e1·w + (2 - sin π/4)·e2·w
  ≈ v3 + 1.293·e1·w + 1.293·e2·w
  = (0.129, 0, 0.371) ✓
- (2, 2): (2, 1)·w  ← endpoint, angle 3π/2 from center

**Side b=1 (linear)** between (a=0, b=0) and (a=0, b=2): linear midpoint
- (0, 1): linear midpoint of (0, 1)·w and (1, 2)·w = (0.5, 1.5)·w = (0.05, 0, 0.35) ✓

**Side b=1 a=2 (on arc)** between (a=2, b=0) and (a=2, b=2): NOT linear!
Found empirically to be at distance w from corner (a=2, b=2) = (2, 1)·w:
- (2, 1): on circle radius w around (2, 1)·w
- Position at (1.29, 0.29)·w from v3 = ... TODO: derive exact parameterization

**Center (1, 1)**: NOT linear midpoint of corners. Blender has it at
(0.061, 0, 0.439) which is on the inner arc continuation.
- TODO: derive exact formula. Looks like it could be the result of one
  Catmull-Clark step on the boundary.

### Topology

4 quad faces around the center (each: corner + 2 mid-edges + center):

```
f_quad_a (corner = (0,0)): [(0,0), (1,0), (1,1), (0,1)]   = [v[14], v[19], v[17], v[18]]
f_quad_b (corner = (2,0)): [(2,0), (1,0), (1,1), (2,1)]   = [v[15], v[19], v[17], v[20]]
f_quad_c (corner = (2,2)): [(2,2), (2,1), (1,1), (1,2)]   = [v[12], v[20], v[17], v[16]]
f_quad_d (corner = (0,2)): [(0,2), (1,2), (1,1), (0,1)]   = [v[13], v[16], v[17], v[18]]
```

(Winding order needs verification — check Blender's f[3..6] for actual.)

## Surrounding-face splicing

The arc patch boundary replaces v3 in three surrounding faces. For each
face F containing v3:

- **Inner-side face** (BEV-NONBEV, contains bev v3-v9 + non-bev v3-v4):
  Replace v3 with grid corner (0, 0) = v[14]. Single-vert replacement.
- **Front-cap face** (BEV-NONBEV other, bev v3-v2 + non-bev v3-v4):
  Replace v3 with grid corner (2, 0) = v[15]. Plus the inner-arc point
  (1, 0) = v[19] needs to be inserted between v[15] and the next vert
  in winding order (toward v_4).
  - Blender's front cap: `[..., v[15], v[19], v_4, ...]` — 2 verts
    inserted on the bev-v3-v2 → v3 → v_4 path.
- **Inner-bottom face** (BEV-BEV): Replace v3 with the patch boundary on
  the b=2 side: `[(0, 2), (1, 2), (2, 2)]` = `[v[13], v[16], v[12]]` —
  3 verts inserted (linear in seg = 2; (seg+1) verts in general).
  - Blender's inner-bottom: `[..., v[13], v[16], v[12], ...]`.

Wait — which side of the patch (b=0 vs b=2) faces which surrounding face?
- b=0 side (inner arc, near v3) → faces inner-side and front-cap
- b=2 side (outer arc, away from v3) → faces inner-bottom

Re-examining:
- v[14] = (0, 0, 0.4) is on inner-side face boundary (x=0)
- v[15] = (0.1, 0, 0.5) is on front-cap face boundary (z=0.5)
- v[13] = (0.1, 0, 0.3) and v[12] = (0.2, 0, 0.4) are interior to
  inner-bottom face (NOT on any other face's plane)
- v[19] = (0.029, 0, 0.471) is in y=0 plane (inner-bottom plane), NOT on
  inner-side or front-cap planes

Hmm — so v[19] is INSIDE inner-bottom face. But Blender's f[12] (front cap)
contains v[19]? Let me re-check: f[12] = [0, 1, 10, 15, 19, 2, 3]. Yes
contains v[19] = (0.029, 0, 0.471).

So v[19] is on the BOUNDARY between inner-bottom and front-cap faces?
Geometrically it's at y=0 (inner-bottom plane) AND z=0.471 ≠ 0.5 (NOT on
front-cap plane). So it's NOT on the front-cap geometric plane.

But topologically it's on the front-cap edge (shared edge between front-cap
and inner-bottom after the bevel). The shared edge runs from v[15] to v[19]
to ??? (some boundary).

This means after arc miter, the inner-bottom and front-cap faces SHARE an
edge that wasn't there before. The arc patch creates new shared edges.

Looking at f[12] front cap: ... v[15], v[19], v[2]=v_4 ...
Looking at f[13] inner-bottom: ... v[13], v[16], v[12], with the path
between continuing through the patch.

Actually I think I miscounted. The inner-bottom face after bevel includes
the b=2 side of the patch. The front-cap face splice doesn't include the
patch interior — it includes v[15] and then jumps to next non-patch vert.

Hmm wait, why is v[19] in f[12] (front cap)?

Looking at adjacency: in the new arc-patch topology, v[15] → v[19] is an
edge of patch f_quad_b (= [v[15], v[19], v[17], v[20]]). The OTHER face
sharing this edge would be ... front-cap (since v[15] is on front-cap
boundary and v[19] is created by the arc miter, sitting between front-cap
and the patch).

So f_quad_b has edges:
- v[15] - v[19]: shared with front-cap face (f[12])
- v[19] - v[17]: shared with f_quad_a (= [v[14], v[19], v[17], v[18]])
- v[17] - v[20]: shared with f_quad_c (= [v[12], v[20], v[17], v[16]])
- v[20] - v[15]: shared with ??? (must be another face)

The v[15] - v[20] edge: v[20] = (0.129, 0, 0.471). Hmm not on front-cap or
inner-side or inner-bottom plane. So shared with another patch quad? Or a
new face we haven't accounted for?

Looking at Blender's faces around v[20]:
- f[3] (n=4) [12, 16, 17, 20] = patch quad with corner (2,2)
- f[6] (n=4) [15, 20, 17, 19] = patch quad with corner (2,0)
- f[8] (n=4) [11, 20, 15, 10] = ??? a quad with v[11], v[20], v[15], v[10]
  - v[11] = (1, -0.029, 0.471) (BV at v_2 strip)
  - v[10] = (1, -0.1, 0.5) (BV at v_2 on front-cap)
  - This is the strip continuation between v_2 strip and the patch

Aha — there's an EXTRA bridging quad (f[8]) between the strip endcap and
the patch. The strip from v_2 along the bev edge to v3 used to terminate
at v3; now it terminates at v[15] and v[20] (the "extended" patch
corners).

So the arc miter doesn't just insert the patch — it also EXTENDS the
adjacent strips by one cross-section ring. Each bev strip gets an extra
"transition quad" (f[7], f[8] in Blender's output) connecting its
original endcap to the patch boundary.

## Full topology summary

For seg=2 inner arc miter at reflex selCount=2:

New verts:
1. 4 patch corners + 4 patch mid-edges + 1 center = 9 grid verts
2. 2 strip-extension verts per adjacent strip (one for each cross-section
   sample on the strip endcap, "extended" by one segment along the bev
   axis). But for seg=2 with cap profile of 3 samples, that's 3 extra
   verts per strip × 2 strips = 6. Wait but the patch corners SHARE 2 of
   these (v[14]=(0,0,0.4) is on the v3-v9 strip's extended endcap;
   v[15]=(0.1,0,0.5) is on v3-v2 strip's). So new verts beyond patch = 0
   for the "BV at strip endcap on flanking face" positions; but the ARC
   midpoints (v[19] for one arc, similar for the other) might be
   strip-side rather than patch-side.

Hmm actually re-counting: Blender has 24v vs original L-shape's 12. So 12
new verts. Of these:
- 4 strip BVs at v_2 (BVs on inner-bottom and front-cap, plus their
  cap-mid sample): v[9], v[10], v[11]. That's 3.
- Similar at v_9: v[22], v[23], v[21]. Wait those have y!=0. Actually:
  - v[21] = (0, 0.1, -0.5)
  - v[22] = (0.1, 0, -0.5)
  - v[23] = (0.029, 0.029, -0.5)
- 9 patch verts: v[12..20]
- Total new = 3 + 3 + 9 = 15? But L-shape has 12 verts so total should be
  12 + 15 = 27, not 24. Hmm.

Let me recount: at v_2 the bevel of v3-v2 puts BVs. v_2 has selCount=1
valence=3, so it produces:
- 2 BVs (one per face containing the bev edge)
- 1 cap-mid (for selCount=1 cap)
- v_2 itself is REPLACED by one of the BVs (reusesOrig)
So 3 - 1 = 2 new verts at v_2.

Similarly at v_9.

Total new verts = patch (9) + strip endcaps at v_2 (2) + at v_9 (2) -
maybe overlap with patch = let's just trust 24 - 12 = 12 new verts.

Hmm 12 = 9 patch + 3 endcap. So strips' endcap at v_2 and v_9 share some
verts with the patch corners (v[14] and v[15] aren't double-counted with
strip endcaps — they ARE at the strip endcap positions, but Blender
counts them once as patch corners).

OK this counting analysis isn't critical. The point is: implementation
needs to produce all these verts and faces, with careful sharing of
boundary verts between patch and surrounding faces.

## Implementation steps

### Step 1: Reposition non-BEV-BEV BVs (in populateBoundVerts)

When `miterInner == Arc && reflex && selCount==2`:

After computing standard BoundVert positions, OVERRIDE the 2 non-BEV-BEV
BVs to be at positions ON the bev edges:
- BV in non-BEV-BEV face A (containing bev edge eh_a + non-bev edge):
  set `bnd.pos = bv.origPos + dir(eh_b) * w` (along the OTHER bev edge)
- BV in non-BEV-BEV face B: set `bnd.pos = bv.origPos + dir(eh_a) * w`

(The "swap": BV in face containing eh_a is positioned along eh_b, and
vice versa. This is because the arc miter "extends" the strip from each
bev edge by one cross-section.)

For our test case:
- BV in front-cap (contains bev v3-v2 + non-bev v3-v4): position at
  v3 + dir(v3-v9) * w = (0, 0, 0.4)? But Blender has (0.1, 0, 0.5) here
  (= v[15]).
- Hmm so the swap rule isn't right. Let me re-derive.
- Blender's v[15] = on bev v3-v2 at offset w from v3. This is along the
  bev edge IN this face, NOT along the other bev edge.

So: BV in face F (containing bev_F + non-bev) → position at
v3 + dir(bev_F) * w (along the bev edge IN this face). Same direction as
the bev edge in this face.

OK that's the correction.

### Step 2: Generate patch verts (in materializeBevVert)

After the existing face-patching loop, when `miterInner == Arc &&
reflex && selCount==2`, call new `materializeArcMiterPatch(mesh, bv)`:

1. Find the 2 bev EHs and their directions e1, e2 (unit vectors from
   bv.vert toward each bev edge's far endpoint).
2. Find w (offsetLSpec of either bev EH).
3. Find the BEV-BEV face F_BB (containing both bev edges).
4. Allocate (seg+1)² grid of vertex IDs (call this `arcGridVids`).
5. Position each (a, b) ∈ [0, seg]² grid vert per the geometry table:
   - Corners: explicit formulas
   - Inner arc (b=0): quarter-circle around (1, 1)·w
   - Outer arc (b=seg): quarter-circle around (seg, seg)·w
   - Linear sides (a=0, b varies): linear interpolation in (e1, e2) frame
   - Last "arc side" (a=seg, b varies): on circle around (seg, seg)·w
   - Interior verts: TODO — figure out the right formula. Bilinear is
     wrong; might need 1-step CC subdivision or specific formula from
     Blender source.

For seg=2 specifically, only 1 interior vert (the center). Approximate
position: TODO.

### Step 3: Emit patch quad faces

For seg=2: 4 quads as in the topology table above.
For general seg: seg² quads, each `[(a, b), (a+1, b), (a+1, b+1), (a, b+1)]`.

(With proper winding so face normals point outward = same direction as
F_BB's normal.)

### Step 4: Splice patch boundary into surrounding faces

For each of the 3 faces around v.vert (front-cap, inner-side, inner-
bottom):
- Identify the relevant patch boundary side
- Replace v.vert in the face with the boundary verts (preserving CCW
  winding)

For inner-side face: replace v.vert with `[(0, 0)]` (just the corner).
Wait but that's only 1 vert replacing 1 vert. Looking at Blender's
inner-side face: `[19, 14, 21, 7, 2]`. Original was `[3, 9, 10, 4]`.
After bevel: v_3→[v[19], v[14]], v_9→v[21] (BV at v_9), v_10→v[7]
unchanged, v_4→v[2] unchanged.
- v_3 in inner-side replaced by 2 verts: v[19] AND v[14].
- v[19] = inner arc midpoint (a=1, b=0), v[14] = patch corner (0, 0)

So the inner-side face splice inserts BOTH the corner AND the inner-arc
mid. That's 2 verts replacing 1.

For seg=N inner-side: insert `[arc_a=N/2 - 1, b=0), ..., (a=0, b=0)]` —
the inner arc samples from "first non-corner" to corner = N/2 verts? Or
just 2 for seg=2?

This is getting really complex. Each surrounding face needs a different
splice pattern depending on which patch boundary it touches.

### Step 5: Bridging quads between strip endcaps and patch

Each of the 2 adjacent bev strips needs to extend by one transition
quad. The transition quad connects the strip's original endcap to the
patch's outer arc on that side.

For our case:
- v3-v2 strip transition: connects (BV_v2_inner_bottom, BV_v2_front_cap,
  cap_mid_v_2) to (patch (2, 2), patch (2, 1), patch (2, 0)). That's
  Blender's f[7] and f[8].
- v3-v9 strip transition: similar at v9 end.

These transition quads are NEW faces that don't exist in the sharp miter
case.

## Tests

- Existing: `lshape_reflex_inner_arc.json` (XFAIL → should turn PASS)
- Add: `lshape_reflex_inner_arc_seg1.json` (seg=1 case — patch is 1
  quad with 4 verts; simpler test)
- Add: `lshape_reflex_inner_arc_seg3.json` (seg=3 odd — exercises the
  general (seg+1)² grid generation)
- Add a non-cube non-L test (e.g. some other reflex angle ≠ 90° to
  verify the geometry generalizes)

## Risks / Open questions

1. **Interior vert formulas** — bilinear gives ~10% error from Blender;
   exact match likely requires Catmull-Clark step or a specific Blender
   formula. Without Blender source access, may settle for approximate
   geometry within `tolerance: 0.05`.
2. **Winding orientation** — patch quads need correct CCW winding so
   normals point with surrounding faces. For seg=N general, get the
   convention right.
3. **Face splicing complexity** — each surrounding face needs different
   splice depending on its relationship to the patch. Bug-prone.
4. **Bridging quads** — the transition between strip endcaps and patch
   boundary is implicit in Blender but needs explicit emission in
   vibe3d. May affect strip endcap topology.
5. **Generalization** — current analysis is for seg=2 valence=3
   selCount=2 specifically. For valence>3 or selCount>2 or different
   reflex configs, behavior may differ. Probably restrict initial
   implementation to selCount=2 valence=3.

## Estimated effort

- Step 1 (BV repositioning): ~30 lines
- Step 2 (patch verts): ~80 lines (incl. arc parameterization)
- Step 3 (patch quads): ~20 lines
- Step 4 (face splicing): ~80 lines (most error-prone)
- Step 5 (bridging quads): ~50 lines
- Tests + iteration: ~3–4 commits

**Total: ~250 lines of new code, 4–6 commits.**

The pragmatic approach: get topology right first (4 quads + correct
boundary splice), accept geometry approximation (bilinear interior),
relax case tolerance to 0.05. Then refine geometry in follow-up work
if/when needed.
