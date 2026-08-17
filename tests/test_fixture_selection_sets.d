// select.set.{store,apply,edit,rename,delete} membership golden (task 1060).
// See tests/fixtures/selection_sets.json for provenance + case-by-case
// commentary. Round-trip and current-type/multi-layer gate cases live in
// tests/test_selection_sets.d instead — this suite has no dynamic
// file-path or thrown-error primitive.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/selection_sets.json");
    runSelectionSuite(json);
}
