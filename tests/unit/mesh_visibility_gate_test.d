// mesh_visibility_gate_test -- the by-value gate for `source/mesh_visibility.d`
// (task 3230, plan 2910 step 2).
//
// The gate mixin lives HERE rather than inside `mesh_visibility.d` itself,
// unlike step 1's nine test-file wirings. `mesh_visibility.d` carries only
// the anchor (`version(unittest) private void byValueGateAnchor() {}`, zero
// imports) — see its own comment for the measured reason: `run_test.d`'s
// HTTP-test lane prebuilds all of `source/**` into one `-unittest` static
// library from the `modeling` dub config's OWN file list, which does not
// include `tests/unit/**`, so a `source/*.d` module that imports
// `tests.unit.mesh_by_value_gate` — even behind `version(unittest)` — links
// clean under `dub test --config=tests` and fails under `./run_test.d` with
// `undefined reference to tests.unit.mesh_by_value_gate.__ModuleInfo`
// (measured, not assumed: the first draft did exactly this and broke that
// lane). Passing the MODULE by name (`MeshByValueGate!(mesh_visibility)`)
// works identically to `__traits(parent, byValueGateAnchor)` for the
// vacuity check — `scope_` just needs a member named `byValueGateAnchor`,
// and it does not care which file the mixin instantiating it lives in.
module tests.unit.mesh_visibility_gate_test;

import mesh_visibility;
import tests.unit.mesh_by_value_gate;

mixin MeshByValueGate!(mesh_visibility);
