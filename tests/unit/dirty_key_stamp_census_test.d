// DirtyKey declaration/stamp census (task 5340).
//
// Every field declared on viewport.DirtyKey must be populated by app.d's
// `_newKey` block. The prior omissions were locally reasonable fields added
// without their matching stamp; this set comparison makes that boundary
// mechanical. `cam` is intentionally populated through `.update(...)`, while
// every other field uses assignment.
module tests.unit.dirty_key_stamp_census_test;

import tests.unit.census_symbols : blankNonCode;

import std.algorithm : canFind, sort;
import std.array     : join;
import std.file      : readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, split, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool identChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private string[] dirtyKeyFields(string sourceText) {
    const code = blankNonCode(sourceText);
    immutable headerAt = code.indexOf("struct DirtyKey");
    assert(headerAt >= 0, "DirtyKey declaration not found in source/viewport.d");
    immutable relativeOpen = code[cast(size_t)headerAt .. $].indexOf('{');
    assert(relativeOpen >= 0, "DirtyKey opening brace not found");
    immutable openAt = cast(size_t)headerAt + cast(size_t)relativeOpen;

    size_t closeAt = size_t.max;
    int depth;
    foreach (i; openAt .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) {
            closeAt = i;
            break;
        }
    }
    assert(closeAt != size_t.max, "DirtyKey closing brace not found");

    string[] fields;
    foreach (rawStatement; code[openAt + 1 .. closeAt].split(";")) {
        const statement = rawStatement.strip;
        if (statement.length == 0) continue;

        size_t typeEnd;
        while (typeEnd < statement.length && !(
                statement[typeEnd] == ' ' || statement[typeEnd] == '\t'
                || statement[typeEnd] == '\r' || statement[typeEnd] == '\n'))
            ++typeEnd;
        assert(typeEnd < statement.length,
            "DirtyKey field declaration has no declarator: " ~ statement);

        foreach (rawDecl; statement[typeEnd .. $].split(",")) {
            auto decl = rawDecl.strip;
            immutable eqAt = decl.indexOf('=');
            if (eqAt >= 0) decl = decl[0 .. cast(size_t)eqAt].strip;
            assert(decl.length > 0,
                "DirtyKey field declaration has an empty declarator: " ~ statement);
            foreach (c; decl)
                assert(identChar(c),
                    "DirtyKey census cannot parse declarator '" ~ decl ~ "'");
            fields ~= decl.idup;
        }
    }
    fields.sort;
    return fields;
}

private string[] dirtyKeyStamps(string sourceText) {
    const code = blankNonCode(sourceText);
    enum needle = "_newKey.";
    string[] stamps;
    size_t from;
    while (from < code.length) {
        immutable relative = code[from .. $].indexOf(needle);
        if (relative < 0) break;
        immutable nameAt = from + cast(size_t)relative + needle.length;
        size_t nameEnd = nameAt;
        while (nameEnd < code.length && identChar(code[nameEnd])) ++nameEnd;
        auto name = code[nameAt .. nameEnd];
        size_t opAt = nameEnd;
        while (opAt < code.length && (code[opAt] == ' ' || code[opAt] == '\t'
                || code[opAt] == '\r' || code[opAt] == '\n'))
            ++opAt;

        immutable assignment = opAt < code.length && code[opAt] == '=';
        immutable camUpdate = name == "cam"
            && code[opAt .. $].length >= ".update(".length
            && code[opAt .. opAt + ".update(".length] == ".update(";
        if (name.length > 0 && (assignment || camUpdate)) stamps ~= name.idup;
        from = nameEnd > from ? nameEnd : from + needle.length;
    }
    stamps.sort;
    return stamps;
}

private string[] duplicates(const string[] names) {
    string[] result;
    foreach (i; 1 .. names.length)
        if (names[i] == names[i - 1] && !result.canFind(names[i]))
            result ~= names[i];
    return result;
}

unittest {
    const viewportSource = readText(buildPath(repoRoot, "source", "viewport.d"));
    const appSource = readText(buildPath(repoRoot, "source", "app.d"));
    const fields = dirtyKeyFields(viewportSource);
    const stamps = dirtyKeyStamps(appSource);

    assert(fields.length >= 14,
        format("DirtyKey field census collapsed: found %d, floor is 14", fields.length));
    assert(stamps.length >= 14,
        format("DirtyKey stamp census collapsed: found %d, floor is 14", stamps.length));

    string[] problems;
    foreach (name; duplicates(fields))
        problems ~= "DirtyKey field declared more than once: " ~ name;
    foreach (name; duplicates(stamps))
        problems ~= "DirtyKey field stamped more than once: " ~ name;
    foreach (name; fields)
        if (!stamps.canFind(name))
            problems ~= "field declared but never stamped: " ~ name;
    foreach (name; stamps)
        if (!fields.canFind(name))
            problems ~= "stamp has no declared DirtyKey field: " ~ name;

    assert(problems.length == 0,
        "DirtyKey declaration/stamp census failed:\n" ~ problems.join("\n"));
}

unittest {
    // Scanner contract: comments/literals cannot forge a stamp, and the
    // CameraStamp mutator is the one accepted non-assignment form.
    const probe = q{
        _newKey.a = 1;
        _newKey.cam.update(v, p);
        // _newKey.commentOnly = 2;
        auto s = "_newKey.literalOnly = 3;";
    };
    assert(dirtyKeyStamps(probe) == ["a", "cam"]);
}
