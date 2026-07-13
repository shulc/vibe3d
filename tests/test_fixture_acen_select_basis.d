// Analytic golden fixture: ACEN-Select local-frame alignment.
//
// The selection local frame convention (axis-aligned faces):
//   fwd   = snapped face normal (outward, signed).
//   up    = per-normal-axis fixed vector, sign-independent:
//             normal on X-axis → up = world −Y
//             normal on Y-axis → up = world −Z
//             normal on Z-axis → up = world +Y
//   right = cross(up, fwd)  (right-handed).
//
// Implication for a driven SY=1.5 (scales along local-Y = up):
//   Top face  (+Y): up = world −Z  → SY=1.5 stretches Z about pivot.y=0
//   Right face (+X): up = world −Y  → SY=1.5 stretches Y about pivot.x=0
//   Bottom face (−Y): same per-axis rule as +Y: up = world −Z
//                      (sign-independent), fwd = −Y, right = −X.
//                      SY=1.5 stretches Z.
//
// Goldens are purely analytic: pivot = face centroid; scale along the
// identified world axis by factor 1.5 from the pivot. No external reference
// engine is consulted at test runtime.

import fixture_helpers;

void main() {}

unittest { // Top face (+Y, face 4): SY=1.5 → local-Y = world−Z → Z stretch.
    // Verts on top face: v3=(−0.5,0.5,−0.5), v7=(−0.5,0.5,0.5),
    //                    v6=(0.5,0.5,0.5),   v2=(0.5,0.5,−0.5).
    // Pivot = (0, 0.5, 0).  z_new = 0 + (z − 0) × 1.5.
    // Selected verts after: z=−0.5→−0.75, z=+0.5→+0.75. y,x unchanged.
    // Non-selected verts (bottom face, at y=−0.5): unchanged.
    enum string json = `{
      "name": "acen_select_basis/top_face_sy",
      "source": "analytic golden from the measured selection local frame (axis.d)",
      "provenance": {
        "schema": 1,
        "source": "analytic",
        "reference": "analytic",
        "method": "hand",
        "captured_utc": "unknown",
        "harness": null,
        "task": null,
        "notes": "analytic golden from the measured selection local frame (axis.d) -- top face (+Y) case."
      },
      "tolerance": 1e-4,
      "cases": [{
        "name": "top face SY=1.5",
        "input": [
          { "reset": true },
          { "select": { "mode": "polygons",
                        "coords": [
                          [[-0.5,0.5,-0.5],[0.5,0.5,-0.5],
                           [0.5,0.5,0.5],[-0.5,0.5,0.5]]
                        ] } }
        ],
        "op": [
          { "acen_transform": { "tool": "scale", "attr": "SY", "value": 1.5,
                                "acen": "select" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-0.5, -0.5, -0.5] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 0.5, -0.5, -0.5] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.5, -0.75] },
          { "before": [-0.5,  0.5, -0.5], "after": [-0.5,  0.5, -0.75] },
          { "before": [-0.5, -0.5,  0.5], "after": [-0.5, -0.5,  0.5] },
          { "before": [ 0.5, -0.5,  0.5], "after": [ 0.5, -0.5,  0.5] },
          { "before": [ 0.5,  0.5,  0.5], "after": [ 0.5,  0.5,  0.75] },
          { "before": [-0.5,  0.5,  0.5], "after": [-0.5,  0.5,  0.75] }
        ]
      }]
    }`;
    runParitySuite(json);
}

unittest { // Right face (+X, face 3): SY=1.5 → local-Y = world−Y → Y stretch.
    // Verts on right face: v1=(0.5,−0.5,−0.5), v2=(0.5,0.5,−0.5),
    //                      v6=(0.5,0.5,0.5),   v5=(0.5,−0.5,0.5).
    // Pivot = (0.5, 0, 0).  y_new = 0 + (y − 0) × 1.5.
    // Selected verts after: y=−0.5→−0.75, y=+0.5→+0.75. x,z unchanged.
    // Non-selected verts (left face at x=−0.5): unchanged.
    enum string json = `{
      "name": "acen_select_basis/right_face_sy",
      "source": "analytic golden from the measured selection local frame (axis.d)",
      "provenance": {
        "schema": 1,
        "source": "analytic",
        "reference": "analytic",
        "method": "hand",
        "captured_utc": "unknown",
        "harness": null,
        "task": null,
        "notes": "analytic golden from the measured selection local frame (axis.d) -- right face (+X) case."
      },
      "tolerance": 1e-4,
      "cases": [{
        "name": "right face SY=1.5",
        "input": [
          { "reset": true },
          { "select": { "mode": "polygons",
                        "coords": [
                          [[0.5,-0.5,-0.5],[0.5,0.5,-0.5],
                           [0.5,0.5,0.5],[0.5,-0.5,0.5]]
                        ] } }
        ],
        "op": [
          { "acen_transform": { "tool": "scale", "attr": "SY", "value": 1.5,
                                "acen": "select" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-0.5, -0.5, -0.5] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 0.5, -0.75, -0.5] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.75, -0.5] },
          { "before": [-0.5,  0.5, -0.5], "after": [-0.5,  0.5, -0.5] },
          { "before": [-0.5, -0.5,  0.5], "after": [-0.5, -0.5,  0.5] },
          { "before": [ 0.5, -0.5,  0.5], "after": [ 0.5, -0.75,  0.5] },
          { "before": [ 0.5,  0.5,  0.5], "after": [ 0.5,  0.75,  0.5] },
          { "before": [-0.5,  0.5,  0.5], "after": [-0.5,  0.5,  0.5] }
        ]
      }]
    }`;
    runParitySuite(json);
}

unittest { // Bottom face (−Y, face 5): SY=1.5 → local-Y = world−Z → Z stretch.
    // Negative-normal parity: up = −Z regardless of normal sign (Y-axis rule).
    // Verts on bottom face: v0=(−0.5,−0.5,−0.5), v1=(0.5,−0.5,−0.5),
    //                       v5=(0.5,−0.5,0.5),   v4=(−0.5,−0.5,0.5).
    // Pivot = (0, −0.5, 0).  z_new = 0 + (z − 0) × 1.5.
    // Selected verts after: z=−0.5→−0.75, z=+0.5→+0.75. x,y unchanged.
    // Non-selected verts (top face at y=+0.5): unchanged.
    enum string json = `{
      "name": "acen_select_basis/bottom_face_sy",
      "source": "analytic golden from the measured selection local frame (axis.d)",
      "provenance": {
        "schema": 1,
        "source": "analytic",
        "reference": "analytic",
        "method": "hand",
        "captured_utc": "unknown",
        "harness": null,
        "task": null,
        "notes": "analytic golden from the measured selection local frame (axis.d) -- bottom face (-Y) case."
      },
      "tolerance": 1e-4,
      "cases": [{
        "name": "bottom face SY=1.5",
        "input": [
          { "reset": true },
          { "select": { "mode": "polygons",
                        "coords": [
                          [[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],
                           [0.5,-0.5,0.5],[-0.5,-0.5,0.5]]
                        ] } }
        ],
        "op": [
          { "acen_transform": { "tool": "scale", "attr": "SY", "value": 1.5,
                                "acen": "select" } }
        ],
        "expected_pairs": [
          { "before": [-0.5, -0.5, -0.5], "after": [-0.5, -0.5, -0.75] },
          { "before": [ 0.5, -0.5, -0.5], "after": [ 0.5, -0.5, -0.75] },
          { "before": [ 0.5,  0.5, -0.5], "after": [ 0.5,  0.5, -0.5] },
          { "before": [-0.5,  0.5, -0.5], "after": [-0.5,  0.5, -0.5] },
          { "before": [-0.5, -0.5,  0.5], "after": [-0.5, -0.5,  0.75] },
          { "before": [ 0.5, -0.5,  0.5], "after": [ 0.5, -0.5,  0.75] },
          { "before": [ 0.5,  0.5,  0.5], "after": [ 0.5,  0.5,  0.5] },
          { "before": [-0.5,  0.5,  0.5], "after": [-0.5,  0.5,  0.5] }
        ]
      }]
    }`;
    runParitySuite(json);
}
