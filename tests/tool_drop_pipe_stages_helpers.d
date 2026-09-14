module tool_drop_pipe_stages_helpers;

import std.json : JSONType, JSONValue;

JSONValue applyHistoryDelta(string id, JSONValue before, JSONValue delta) {
    assert(delta.type == JSONType.object,
        id ~ ": historyDelta must be an object");
    JSONValue[string] wanted = before.object.dup;
    foreach (key, amount; delta.object) {
        assert((key in before.object) !is null,
            id ~ ": historyDelta names an unknown history field " ~ key);
        assert(amount.type == JSONType.integer,
            id ~ ": historyDelta values must be integers");
        wanted[key] = before[key].integer + amount.integer;
    }
    return JSONValue(wanted);
}
