// mesh_edge_slice_gate_test -- the by-value gate for `source/mesh_edge_slice.d`
// (task 3240, plan 2910 step 3).
//
// Same split as `mesh_edge_slice_gate_test`'s predecessor
// `tests/unit/mesh_visibility_gate_test.d`, and for the same MEASURED reason
// (task 3230's finding Н4): `source/mesh_edge_slice.d` carries only the anchor
// (`version(unittest) private void byValueGateAnchor() {}`), because a module
// under `source/` that imports anything under `tests/unit/` links clean under
// `dub test --config=tests` and dies under `./run_test.d`, whose HTTP lane
// prebuilds `source/**` from the `modeling` config's file list -- a list that
// does not contain `tests/unit/**` -- into one shared `-unittest` library.
//
// WHY THIS GATE EARNS ITS LINE HERE MORE THAN ANYWHERE ELSE SO FAR. Step 2
// moved two functions; this step moves eleven, ten of which take a receiver
// and SEVEN of which write the mesh (`insertEdgePoint`, `addEdgePoint`,
// `rebuildFacesWithChordSplits`, `edgeSliceEx`, `edgeSlice`,
// `splitFaceByVertices`, plus `edgeIndexOfVerts`/`edgeIndexOf` which are
// non-const only because they were non-const members). A single `ref` dropped
// from any of the seven compiles everywhere and loses every vertex append and
// every face rewrite, while writes through already-live slice elements still
// land -- so a real subset of the suite stays green. That is the exact defect
// shape CLAUDE.md calls the one this project pays for most, and it has no
// behavioural witness; it has this.
//
// The gate is imported WHOLESALE, not selectively: `import
// tests.unit.mesh_by_value_gate : MeshByValueGate;` fails inside the mixin's
// own instantiation with `template meshByValueOffenders is not defined`
// (task 3230, Н2 -- the working spelling matches the ten existing precedents).
module tests.unit.mesh_edge_slice_gate_test;

import mesh_edge_slice;
import tests.unit.mesh_by_value_gate;

mixin MeshByValueGate!(mesh_edge_slice);
