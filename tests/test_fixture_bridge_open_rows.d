// Bridge tool (mesh.bridgeTool, task 0395) golden parity — OPEN edge-row
// bridging: proximity pairing, unequal-length fan/triangulate, Segments law
// on open rows, and the single-open-chain no-op. See
// tests/fixtures/bridge_open_rows.json for the full derivation note per
// case (frozen live reference-editor capture, 6 cases including the
// PRIMARY owner-repro regression `reported_bug_two_open_arcs_equal`).
//
// Deliberately SEPARATE from tests/test_fixture_bridge.d (closed-loop/
// polygon-mode Bridge, task 0357, unaffected by this change) and from
// tests/test_bridge.d (the pre-existing one-shot mesh.bridge COMMAND,
// exercised via play-events-style HTTP calls).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/bridge_open_rows.json");
    runTopologyDiffSuite(json);
}
