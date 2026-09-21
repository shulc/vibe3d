module io.file_dialog_browser;

import io.formats : FilterSpec;

// Task 6870: the first browser backend deliberately has no path-bearing
// outcome. A later document-addressing slice may widen this private backend
// contract; until then its type makes `chosen` and `cancelled` unrepresentable.
enum BrowserPickOutcome {
    unavailable,
    failed,
}

struct BrowserPickResult {
    BrowserPickOutcome outcome;
    string detail;
}

enum string noGestureReason =
    "no path given: browser file access requires a user gesture";

BrowserPickResult pickOpenPath(FilterSpec[] filters, string startDir = null) {
    return BrowserPickResult(BrowserPickOutcome.unavailable, noGestureReason);
}

BrowserPickResult pickSavePath(FilterSpec[] filters, string defaultName,
                               string startDir = null) {
    return BrowserPickResult(BrowserPickOutcome.unavailable, noGestureReason);
}
