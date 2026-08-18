// Material inheritance through a topology change, frozen from the reference
// (task 1160).
//
// Nothing in this suite asked this before: tag a face, then rewrite the
// topology under it -- merge, split, spin, vertex split, paste -- and see
// which faces still share a material afterwards.
//
// The material VALUES are never compared across the seam. The reference names
// surfaces by string and we by index, so the values are not comparable and are
// deliberately not compared; what is frozen is the PARTITION they induce,
// expressed as indices into the fixture's own frozen face list and therefore
// keyed on coordinates all the way down.
//
// The reversed-order cell is the control that settled the law: tagging the far
// face first and then merging with the near face selected first still yields
// the same answer, which is what says selection order decides nothing.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/material_inheritance_parity.json"));
}
