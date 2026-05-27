// Reference-parity: actr.local per-cluster transforms on a CLEAN segments-2
// cube (empty reset so prim.cube is the only geometry — appending onto the
// default reset cube would double the shared corners). Each disjoint cluster
// transforms about its OWN center along its OWN local frame (fwd=normal).
import fixture_helpers;
void main() {}
unittest {
    enum string json = import("fixtures/acen_local.json");
    runParitySuite(json);
}
