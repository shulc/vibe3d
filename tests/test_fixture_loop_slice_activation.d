// Loop Slice ACTIVATION model (task 0245): a POLYGON selection makes the tool
// act on the edge(s) BETWEEN the selected faces. Two adjacent selected quads
// seed their shared edge (the ring crossing it is cut); a lone / non-adjacent
// face selection seeds nothing. Analytic self-golden on the default cube.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_activation.json");
    runTopologyDiffSuite(json);
}
