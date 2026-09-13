// Every registered command id has a configured UI token or an explicit
// reason in the named remainder ledger (task 5250).
//
// This is the reverse of startup validation: startup proves that configured
// actions resolve to known factories, while this census starts at every
// `commandFactories` id and refuses one that disappears from every configured
// surface without being named. The scan covers buttons, status-line actions,
// pie actions, both shortcut maps, forms, and tool presets. YAML comments are
// blanked so prose cannot manufacture a surface.
//
// The broad surface floor was measured over that complete source set, not the
// older three-file subset. Regenerate the remainder mechanically with the
// command documented beside command_surface_ledger.txt, then read the diff.
module tests.unit.command_surface_census_test;

import std.algorithm : canFind, sort;
import std.array : appender, join;
import std.file : dirEntries, exists, isFile, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.regex : ctRegex, matchAll;
import std.string : count, indexOf, split, splitLines, startsWith, strip;

import buttonset : ActionKind, allButtons, loadButtons;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum registeredIdRe = ctRegex!(`reg\.commandFactories\["([^"]+)"\]`);
private enum configTokenRe = ctRegex!(`[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+`);
private enum quotedValueRe = ctRegex!(`"([^"]+)"`);
private enum actrPresetRe = ctRegex!(`Preset\("([^"]+)"`);

// Four registration loops construct ids from a literal prefix and a closed
// literal value list. A regex that stops at the first quote reports fake ids
// such as `file.import` and misses every real suffixed command. Keep their
// expansions named, and pin each construction expression below.
private static immutable string[] dynamicRegistrationExpressions = [
    `reg.commandFactories["actr." ~ p.name]`,
    `reg.commandFactories["falloff." ~ ty]`,
    `reg.commandFactories["file.import" ~ importExt]`,
    `reg.commandFactories["file.export" ~ exportExt]`,
];

private string[] quotedValuesBetween(string src, string anchor, string terminator)
{
    const start = src.indexOf(anchor);
    assert(start >= 0, "dynamic command registration anchor changed: " ~ anchor);
    const tail = src[cast(size_t) start + anchor.length .. $];
    const finish = tail.indexOf(terminator);
    assert(finish >= 0,
        "dynamic command registration terminator changed after: " ~ anchor);
    string[] result;
    foreach (m; matchAll(tail[0 .. cast(size_t) finish], quotedValueRe))
        result ~= m[1].idup;
    assert(result.length != 0,
        "dynamic command registration value list is empty after: " ~ anchor);
    return result;
}

private string[] dynamicRegisteredCommandIds(string registrationText)
{
    string[] result;
    foreach (m; matchAll(registrationText, actrPresetRe))
        result ~= "actr." ~ m[1].idup;
    assert(result.length >= 11,
        format("only %d action-center command registrations were expanded; expected at least 11",
               result.length));

    foreach (value; quotedValuesBetween(registrationText,
            "static immutable string[] falloffTypes =", "];"))
        result ~= "falloff." ~ value;
    foreach (value; quotedValuesBetween(registrationText,
            "foreach (importExt; [", "])"))
        result ~= "file.import" ~ value;
    foreach (value; quotedValuesBetween(registrationText,
            "foreach (exportExt; [", "])"))
        result ~= "file.export" ~ value;
    return result;
}

private string withoutYamlComments(string src)
{
    auto result = src.dup;
    bool inSingle;
    bool inDouble;
    bool escaped;
    foreach (i, c; src)
    {
        if (c == '\n')
        {
            inSingle = false;
            inDouble = false;
            escaped = false;
            continue;
        }
        if (escaped)
        {
            escaped = false;
            continue;
        }
        if (inDouble && c == '\\')
        {
            escaped = true;
            continue;
        }
        if (!inDouble && c == '\'')
        {
            inSingle = !inSingle;
            continue;
        }
        if (!inSingle && c == '"')
        {
            inDouble = !inDouble;
            continue;
        }
        if (c != '#' || inSingle || inDouble)
            continue;
        for (size_t j = i; j < result.length && result[j] != '\n'; ++j)
            result[j] = ' ';
    }
    return result.idup;
}

private string registrationText()
{
    string result;
    foreach (name; ["registration.d", "file_io_registration.d"]) {
        const path = buildPath(repoRoot, "source", name);
        assert(exists(path) && isFile(path),
            "command surface census cannot find source/" ~ name);
        result ~= readText(path);
    }
    return result;
}

private string[] registeredCommandIds()
{
    const registration = registrationText();
    bool[string] seen;
    foreach (m; matchAll(registration, registeredIdRe))
        seen[m[1].idup] = true;
    foreach (expression; dynamicRegistrationExpressions)
        assert(registration.count(expression) == 1,
            "dynamic command registration expression changed; update its named "
          ~ "id expansion: " ~ expression);
    foreach (id; dynamicRegisteredCommandIds(registration))
        seen[id] = true;
    string[] result;
    foreach (id; seen.byKey)
        result ~= id;
    result.sort;
    return result;
}

private string[] configuredSurfacePaths()
{
    string[] result = [
        buildPath(repoRoot, "config", "buttons.yaml"),
        buildPath(repoRoot, "config", "statusline.yaml"),
        buildPath(repoRoot, "config", "pies.yaml"),
        buildPath(repoRoot, "config", "tool_presets.yaml"),
    ];
    foreach (de; dirEntries(buildPath(repoRoot, "config"), "shortcuts*.yaml",
                            SpanMode.shallow))
        result ~= de.name;
    foreach (de; dirEntries(buildPath(repoRoot, "config", "forms"), "*.yaml",
                            SpanMode.shallow))
        result ~= de.name;
    result.sort;
    return result;
}

private bool[string] configuredSurfaceTokens()
{
    bool[string] result;
    bool hasCombinedActionCenterProvider;
    foreach (path; configuredSurfacePaths())
    {
        assert(exists(path) && isFile(path),
            "command surface census cannot find configured source " ~ path);
        const configText = withoutYamlComments(readText(path));
        if (configText.canFind("dynamicKind: acenModes"))
            hasCombinedActionCenterProvider = true;
        foreach (m; matchAll(configText, configTokenRe))
            result[m[0].idup] = true;
    }
    // `acenModes` expands into command actions at runtime. The provider's
    // composition has its own closed, ordered census; this reverse census only
    // needs to treat those generated command ids as surfaced.
    if (hasCombinedActionCenterProvider)
        foreach (id; dynamicRegisteredCommandIds(
                registrationText()))
            if (id.startsWith("actr."))
                result[id] = true;
    return result;
}

private string[string] loadRemainderLedger()
{
    const path = buildPath(repoRoot, "tests", "unit",
                           "command_surface_ledger.txt");
    assert(exists(path) && isFile(path),
        "command surface census cannot find command_surface_ledger.txt");
    string[string] result;
    string previous;
    foreach (lineNo, raw; readText(path).splitLines)
    {
        const line = raw.strip;
        if (line.length == 0 || line.startsWith("#"))
            continue;
        const fields = line.split("|");
        assert(fields.length == 2,
            format("command_surface_ledger.txt:%d must be `id | reason`",
                   lineNo + 1));
        const id = fields[0].strip;
        const reason = fields[1].strip;
        assert(id.length != 0 && reason.length != 0,
            format("command_surface_ledger.txt:%d needs both id and reason",
                   lineNo + 1));
        immutable categories = ["api-only: ", "code-ui: ", "no-ui-yet: ",
                                "unclassified: "];
        bool knownCategory;
        foreach (category; categories)
            if (reason.startsWith(category) && reason.length > category.length)
                knownCategory = true;
        assert(knownCategory,
            format("command_surface_ledger.txt:%d needs a known category and "
                 ~ "an individual reason: %s", lineNo + 1, id));
        assert(previous.length == 0 || previous < id,
            format("command_surface_ledger.txt:%d is not strictly sorted: %s after %s",
                   lineNo + 1, id, previous));
        assert(id !in result,
            format("command_surface_ledger.txt:%d duplicates %s", lineNo + 1, id));
        result[id] = reason;
        previous = id;
    }
    return result;
}

unittest
{
    const registered = registeredCommandIds();
    const surface = configuredSurfaceTokens();
    const ledger = loadRemainderLedger();

    // Removing the new button retains the measured pre-change floor (152) and
    // reaches the named finding below. Narrowing the broad traversal to the old
    // three files falls below the floor and names the broken population.
    assert(registered.length >= 270,
        format("registered command population fell to %d; expected at least 270",
               registered.length));
    size_t surfaced;
    foreach (id; registered)
        if (id in surface)
            ++surfaced;
    assert(surfaced >= 152,
        format("configured command surface population fell to %d; expected at least "
             ~ "152 across buttons/statusline/pies/shortcuts/forms/tool_presets",
               surfaced));

    auto problems = appender!(string[]);
    bool[string] registeredSet;
    foreach (id; registered)
    {
        registeredSet[id] = true;
        if (id !in surface && id !in ledger)
            problems.put("registered command has neither a configured surface nor "
                       ~ "a ledger entry: " ~ id);
    }
    foreach (id, reason; ledger)
    {
        if (id !in registeredSet)
            problems.put("ledger entry is not a registered command: " ~ id);
        else if (id in surface)
            problems.put("ledger entry now has a configured surface; remove it: " ~ id);
    }
    auto sortedProblems = problems.data;
    sortedProblems.sort;
    assert(sortedProblems.length == 0,
        "command surface census:\n" ~ sortedProblems.join("\n"));
}

unittest
{
    auto panels = loadButtons(buildPath(repoRoot, "config", "buttons.yaml"));
    bool foundVertex;
    bool foundSetPosition;
    size_t vertexButtonCount;
    foreach (ref panel; panels)
    {
        if (panel.title != "Vertex")
            continue;
        foundVertex = true;
        const buttons = allButtons(panel);
        vertexButtonCount = buttons.length;
        foreach (ref button; buttons)
            if (button.label == "Set Position"
                && button.action.kind == ActionKind.command
                && button.action.id == "mesh.setPosition")
                foundSetPosition = true;
    }
    assert(foundVertex, "config/buttons.yaml has no Vertex panel");
    assert(vertexButtonCount >= 8,
        format("Vertex panel has only %d buttons across all groups; expected at least 8",
               vertexButtonCount));
    assert(foundSetPosition,
        "Vertex panel has no Set Position command button for mesh.setPosition");
}
