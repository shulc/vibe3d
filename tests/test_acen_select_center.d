// Analytic golden: ACEN-Select / SelectAuto action-center = world-bbox center
// of the selection (NOT the per-vertex average).
//
// Source chain (source-grounded against actcenter.d, mesh.d):
//   computeCenter() Mode.Select → selectionCentroid(SelectSubMode.Center)
//   → centroidWithGeometryFallback()
//   → mesh_.selectionBBoxCenterVertices()  [in Vertex mode]
//   → (min + max) * 0.5  over selected verts
//
// The test uses an ASYMMETRIC 3-vertex L-shape on the back face (z = −0.5)
// of the default cube where the two candidate pivots are numerically distinct:
//
//   Selected verts (cube indices 0, 1, 3):
//     v0 = (−0.5, −0.5, −0.5)
//     v1 = ( 0.5, −0.5, −0.5)
//     v3 = (−0.5,  0.5, −0.5)
//
//   Bbox center  = ( (−0.5+0.5)/2, (−0.5+0.5)/2, (−0.5+−0.5)/2 )
//               = (0, 0, −0.5)            ← the expected pivot
//
//   Per-vertex avg = ( (−0.5+0.5−0.5)/3, (−0.5−0.5+0.5)/3, −0.5 )
//               = (−1/6, −1/6, −0.5) ≈ (−0.1667, −0.1667, −0.5)  ← REJECTED
//
// Operation: SX = 2 (scale along local-X of the selection frame).
//
// Selection local frame (axis.d computeSelectionBboxBasis, vertex mode):
//   normalAcc = sum of incident face normals of selected verts
//             = (−1,−1,−1) + (1,−1,−1) + (−1,1,−1) = (−1,−1,−3)
//   dominant axis: |z| = 3 > |x| = |y| = 1 → fwdIdx = 2, fwdSign = −1
//   fwd   = (0, 0, −1)  (world −Z, back-face normal outward)
//   up    = (0, +1,  0)  (Z-axis rule: upIdx=1, upSign=+1 → world +Y)
//   right = cross(up, fwd) = cross((0,1,0),(0,0,−1)) = (−1,0,0)  (world −X)
//
// Scale SX = 2 along local-X (right = (−1,0,0)) about pivot P = (0,0,−0.5):
//   new_v = P + d + (2−1)·(d·right)·right,  where d = v − P
//   d·right = −d_x  →  correction = (d_x, 0, 0)
//   → new_x = 2·v_x,  new_y = v_y,  new_z = v_z  (for selected verts)
//   Non-selected verts are unchanged.
//
// Under the REJECTED avg pivot (−1/6, −1/6, −0.5):
//   new_x = 2·v_x − (−1/6) = 2·v_x + 1/6
//   v0 → x = −0.8333  (vs −1.0 under bbox pivot)  ← WOULD FAIL the test
//   v1 → x =  1.1667  (vs  1.0)                   ← WOULD FAIL the test
//   v3 → x = −0.8333  (vs −1.0)                   ← WOULD FAIL the test
//
// SelectAuto shares the same center path (actcenter.d:737
// selectionCentroid(SelectSubMode.Center)) and this vertex selection's
// normalAcc dominant axis is Z for both modes, so the same frame + pivot
// applies. The second test case asserts SelectAuto produces the same result.

import fixture_helpers;

void main() {}

unittest { // ACEN-Select, asymmetric L-shape: bbox center (0,0,−0.5), SX=2.
    // Verts that MOVE (selected — v0, v1, v3):
    //   v0 (−0.5,−0.5,−0.5) → (−1.0, −0.5, −0.5)
    //   v1 ( 0.5,−0.5,−0.5) → ( 1.0, −0.5, −0.5)
    //   v3 (−0.5, 0.5,−0.5) → (−1.0,  0.5, −0.5)
    // Verts that do NOT move (v2, v4–v7): unchanged.
    enum string json = `{
      "name": "acen_select_center/l_shape_sx2",
      "source": "analytic golden — selection bbox center pivot, vertex mode",
      "tolerance": 1e-4,
      "cases": [{
        "name": "acen.select L-shape SX=2 (bbox pivot discriminates avg)",
        "input": [
          { "reset": true },
          { "select": { "mode": "vertices",
                        "coords": [
                          [-0.5, -0.5, -0.5],
                          [ 0.5, -0.5, -0.5],
                          [-0.5,  0.5, -0.5]
                        ] } }
        ],
        "op": [
          { "acen_transform": { "tool": "scale", "attr": "SX", "value": 2.0,
                                "acen": "select" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-1.0, -0.5, -0.5] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 1.0, -0.5, -0.5] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.5, -0.5] },
          { "before": [-0.5,  0.5, -0.5], "after": [-1.0,  0.5, -0.5] },
          { "before": [-0.5, -0.5,  0.5], "after": [-0.5, -0.5,  0.5] },
          { "before": [ 0.5, -0.5,  0.5], "after": [ 0.5, -0.5,  0.5] },
          { "before": [ 0.5,  0.5,  0.5], "after": [ 0.5,  0.5,  0.5] },
          { "before": [-0.5,  0.5,  0.5], "after": [-0.5,  0.5,  0.5] }
        ]
      }]
    }`;
    runParitySuite(json);
}

unittest { // ACEN-SelectAuto, same L-shape: center path is lockstep with Select.
    // SelectAuto calls selectionCentroid(SelectSubMode.Center) directly
    // (actcenter.d:737) — same centroidWithGeometryFallback() path as Select.
    // This vertex selection's normalAcc = (−1,−1,−3); dominant axis = Z → same
    // frame as Select. SX=2 about pivot (0,0,−0.5) gives identical results.
    enum string json = `{
      "name": "acen_select_center/selectauto_lockstep",
      "source": "analytic golden — SelectAuto center lockstep with Select",
      "tolerance": 1e-4,
      "cases": [{
        "name": "acen.selectauto L-shape SX=2 (same center as select)",
        "input": [
          { "reset": true },
          { "select": { "mode": "vertices",
                        "coords": [
                          [-0.5, -0.5, -0.5],
                          [ 0.5, -0.5, -0.5],
                          [-0.5,  0.5, -0.5]
                        ] } }
        ],
        "op": [
          { "acen_transform": { "tool": "scale", "attr": "SX", "value": 2.0,
                                "acen": "selectauto" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-1.0, -0.5, -0.5] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 1.0, -0.5, -0.5] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.5, -0.5] },
          { "before": [-0.5,  0.5, -0.5], "after": [-1.0,  0.5, -0.5] },
          { "before": [-0.5, -0.5,  0.5], "after": [-0.5, -0.5,  0.5] },
          { "before": [ 0.5, -0.5,  0.5], "after": [ 0.5, -0.5,  0.5] },
          { "before": [ 0.5,  0.5,  0.5], "after": [ 0.5,  0.5,  0.5] },
          { "before": [-0.5,  0.5,  0.5], "after": [-0.5,  0.5,  0.5] }
        ]
      }]
    }`;
    runParitySuite(json);
}
