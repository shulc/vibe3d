module http_command_helpers;

/// Nest an existing endpoint payload under the generic command envelope.
/// Kept CTFE-capable because several HTTP test scenario tables are enums.
string commandBody(string id, string params = null) pure {
    if (params.length == 0)
        return `{"id":"` ~ id ~ `"}`;
    return `{"id":"` ~ id ~ `","params":` ~ params ~ `}`;
}
