module test_layout_reset_command;

import http_client : postJson;
import http_command_helpers : commandBody;

void main() {}

unittest {
    // HTTP exposes command acceptance; the injected unit cell owns the reset
    // count and non-undoable history effects, which have no HTTP projection.
    auto reset = postJson("/api/command", commandBody("layout.reset"));
    assert(reset["status"].str == "ok",
        "6245 F4d suite: layout.reset command failed");
}
