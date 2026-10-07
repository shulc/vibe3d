// Current typed Local contracts plus complete immutable historical diagnostics.
// Historical manual input metadata is unresolved; no historical parity claim.
import fixture_helpers;
void main() {}
unittest {
    enum string json = import("fixtures/acen_local.json");
    runLocalContractSuite(json);
}
