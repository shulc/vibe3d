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
// The PROBE HAD TO MOVE FROM SX TO SY, AND THAT IS ITSELF THE FINDING.
//
// The probe is a single-axis scale, and a single-axis scale only sees the pivot
// at all along the axis it scales. When the selection frame became the ORIENTED
// bounding box (`source/toolpipe/obbox.d`) this three-point L-shape stopped
// answering a world axis: three points of a right isoceles triangle have their
// principal in-plane axis along the HYPOTENUSE, at 45 degrees, and that is
// exactly PERPENDICULAR to the difference between the two candidate pivots
// (bbox centre minus per-vertex average = (1/6, 1/6, 0)). An SX probe on the
// new frame gives the SAME answer for both pivots — not a wrong answer, a
// BLIND one, and a blind probe would have kept passing while proving nothing.
//
// So the probe scales along local-Y instead, which IS parallel to the pivot
// difference, and it discriminates on all THREE selected vertices where the
// SX form discriminated on three too — same count, but a probe that can see
// the pivot at all. The rig, the claim and the rejected alternative are
// unchanged; only the axis the claim is read along moved.
//
// Selection local frame (axis.d computeSelectionBboxBasis, vertex mode):
//   the three selected points are planar at z = −0.5 and their covariance's
//   principal axis is the hypotenuse direction; the thinnest axis is the plane
//   normal, oriented against the summed incident face normals (−1,−1,−3):
//   fwd   = (0, 0, −1)
//   right = (−0.70711, +0.70711, 0)     principal in-plane axis
//   up    = fwd × right = (+0.70711, +0.70711, 0)
//
// Operation: SY = 2 (scale along local-Y = `up`).
//
//   new_v = P + d + (2−1)·(d·up)·up,  where d = v − P, P = (0, 0, −0.5)
//   v0: d = (−0.5,−0.5,0), d·up = −0.70711 → (−1.0, −1.0, −0.5)
//   v1: d = ( 0.5,−0.5,0), d·up = 0        → unchanged
//   v3: d = (−0.5, 0.5,0), d·up = 0        → unchanged
//   Non-selected verts are unchanged.
//
// Under the REJECTED avg pivot (−1/6, −1/6, −0.5) every one of the three
// selected verts lands somewhere else:
//   v0 → (−0.8333, −0.8333, −0.5)   (vs (−1.0, −1.0, −0.5))   ← WOULD FAIL
//   v1 → ( 0.6667, −0.3333, −0.5)   (vs ( 0.5, −0.5, −0.5))    ← WOULD FAIL
//   v3 → (−0.3333,  0.6667, −0.5)   (vs (−0.5,  0.5, −0.5))    ← WOULD FAIL
//
// SelectAuto shares the same center path (actcenter.d:737
// selectionCentroid(SelectSubMode.Center)) but pairs it with the AUTO axis
// tool, i.e. the WORLD identity — which is why the second case below keeps its
// SX probe unchanged: on the identity frame local-X is world X, the pivot
// difference has an x component of 1/6, and the probe still discriminates.
// That the two cases now scale along different axes is the separability the
// axis stage is built on, not an inconsistency.

import fixture_helpers;

void main() {}

unittest { // ACEN-Select, asymmetric L-shape: bbox center (0,0,−0.5), SY=2.
    // Verts that MOVE (selected — only v0; v1 and v3 sit on the scale axis'
    // own zero and stay put, which is what makes v0's landing point the whole
    // claim):
    //   v0 (−0.5,−0.5,−0.5) → (−1.0, −1.0, −0.5)
    // Verts that do NOT move: everything else.
    enum string json = `{
      "name": "acen_select_center/l_shape_sy2",
      "source": "analytic golden — selection bbox center pivot, vertex mode",
      "provenance": {
        "schema": 1,
        "source": "analytic",
        "reference": "analytic",
        "method": "hand",
        "captured_utc": "unknown",
        "harness": null,
        "task": null,
        "notes": "analytic golden -- selection bbox center pivot, vertex mode; source-grounded against actcenter.d/mesh.d and the oriented selection frame in toolpipe/obbox.d (see file header derivation)."
      },
      "tolerance": 1e-4,
      "cases": [{
        "name": "acen.select L-shape SY=2 (bbox pivot discriminates avg)",
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
          { "acen_transform": { "tool": "scale", "attr": "SY", "value": 2.0,
                                "acen": "select" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-1.0, -1.0, -0.5] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 0.5, -0.5, -0.5] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.5, -0.5] },
          { "before": [-0.5,  0.5, -0.5], "after": [-0.5,  0.5, -0.5] },
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
    // (actcenter.d:737) — same centroidWithGeometryFallback() path as Select,
    // and this case asserts THE CENTRE, which is the only thing the two modes
    // share. Their FRAMES differ by construction (selectauto pairs the
    // selection centre with the AUTO axis tool), so this case keeps the SX
    // probe: on the world identity local-X is world X and the two candidate
    // pivots differ by 1/6 along it.
    enum string json = `{
      "name": "acen_select_center/selectauto_lockstep",
      "source": "analytic golden — SelectAuto center lockstep with Select",
      "provenance": {
        "schema": 1,
        "source": "analytic",
        "reference": "analytic",
        "method": "hand",
        "captured_utc": "unknown",
        "harness": null,
        "task": null,
        "notes": "SelectAuto center lockstep with Select -- same derivation chain as :63 (selectionCentroid(SelectSubMode.Center), actcenter.d:737)."
      },
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
