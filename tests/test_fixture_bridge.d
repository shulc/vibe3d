// Bridge tool (mesh.bridgeTool, task 0357) golden parity — Segments/Twist/
// Remove Polygons laws, driven through the interactive tool's headless
// one-shot path (/api/command {"id":"mesh.bridgeTool","params":{...}}).
// See tests/fixtures/bridge.json for the full derivation note per case.
//
// This is deliberately SEPARATE from tests/test_bridge.d, which exercises
// the pre-existing one-shot mesh.bridge COMMAND (unchanged by task 0357 —
// additive kernel/tool only) via play-events-style HTTP calls.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/bridge.json");
    runTopologyDiffSuite(json);
}
